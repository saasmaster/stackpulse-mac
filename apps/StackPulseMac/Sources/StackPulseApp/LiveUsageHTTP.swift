import Foundation

/// The one place a vendor's JSON scalar becomes a `Double`, and the one place a
/// percentage is forced into 0…100.
///
/// Every live-usage client used to carry its own byte-identical copy of both. That
/// meant the honesty invariants this app rests on — "a number we didn't understand
/// is `nil`, never a silent zero" and "a percentage never leaves 0…100" — had eight
/// implementations and no single place to test or fix them. A tolerance change here
/// (locale decimal commas, `"1_000"`, a clamp that should log instead of saturate)
/// now reaches every provider at once.
///
/// Caseless enum: a namespace with no instances and no mutable state, so it is
/// trivially `Sendable` under strict concurrency.
enum LiveUsageJSON {
    /// `JSONSerialization` hands back `NSNumber` for every JSON number, but the
    /// other cases cover payloads that reached us through a typed decoder or that
    /// quote their numbers. A value we cannot read is `nil` — the callers all treat
    /// `nil` as "not reported" and drop the meter rather than render a fake 0.
    static func coerceDouble(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// Saturates rather than rejects: a vendor reporting 103% of a quota is over
    /// its limit, not lying, and the meter should read full instead of disappearing.
    static func clampPercent(_ value: Double) -> Double { max(0, min(100, value)) }

    /// A meter's label derived from the window it actually measures — never from the
    /// slot it arrived in.
    ///
    /// A 24-hour window presented as "5h" is a lie the user cannot see through, and
    /// it costs twice: `SnapshotStore.mergeLimits` dedups by label, so a mislabeled
    /// live row and the Rust core's correctly labeled row survive as two rows for one
    /// quota. This is a port of `window_label` in
    /// `crates/stackpulse-core/src/providers/codex.rs` and must keep its vocabulary
    /// exactly — the two sides agreeing is the whole point.
    static func windowLabel(minutes: Int) -> String {
        switch minutes {
        case ..<1: return "window"
        case 10_080: return "weekly"        // not "7d": the plans call this weekly
        case let m where m % 1440 == 0: return "\(m / 1440)d"
        case let m where m % 60 == 0: return "\(m / 60)h"
        case let m: return "\(m)m"
        }
    }
}

/// The shared request path for the live-usage clients.
///
/// The clients differ only in which headers they send and which body (if any) they
/// post; the status mapping, the 15s timeout and the `HTTPURLResponse` cast were
/// copied verbatim into seven files. Consolidating them means adding 429 handling
/// or changing the timeout is one edit, not seven with one client left behind.
///
/// Credential hygiene is the caller's: keys go in the `headers` dictionary (or, for
/// Devin, the body) and never in the URL, where they would land in logs and history.
/// Nothing here logs the request, the headers, or the response.
enum LiveUsageHTTP {
    enum Outcome {
        case ok(Data)
        case unauthorized       // 401 / 403
        case notFound           // 404
        case httpError(Int)     // any other non-success status
        case failure            // offline / TLS / timeout / non-HTTP
    }

    /// The headers four of these clients send verbatim: the credential on
    /// `Authorization: Bearer` and nothing else, plus a JSON `Accept`.
    ///
    /// The key goes on THIS header — never a query parameter, where it would land in
    /// logs, proxies and shell history. That rule was restated in a comment above
    /// each of the four copies, which is three more places for it to rot than it
    /// needs. (MiniMax is deliberately not a caller: its endpoint refuses a bearer
    /// header and wants a cookie.)
    static func bearerJSON(_ key: String) -> [String: String] {
        ["Authorization": "Bearer \(key)", "Accept": "application/json"]
    }

    /// `success` is a parameter because the endpoints genuinely disagree: most treat
    /// any 2xx as good, while Cursor's Connect-RPC and the balance endpoints only
    /// ever answer a bare 200 and a 2xx redirect-ish status there would be drift, not
    /// data. Flattening that would have changed behaviour for those callers.
    static func get(
        _ url: URL,
        headers: [String: String],
        success: Range<Int> = 200..<300
    ) async -> Outcome {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        for (field, value) in headers { req.setValue(value, forHTTPHeaderField: field) }
        return await send(req, success: success)
    }

    static func post(
        _ url: URL,
        headers: [String: String],
        body: Data,
        success: Range<Int> = 200..<300
    ) async -> Outcome {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        for (field, value) in headers { req.setValue(value, forHTTPHeaderField: field) }
        req.httpBody = body
        return await send(req, success: success)
    }

    private static func send(_ req: URLRequest, success: Range<Int>) async -> Outcome {
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .failure }
            switch http.statusCode {
            case success: return .ok(data)
            case 401, 403: return .unauthorized
            case 404: return .notFound
            default: return .httpError(http.statusCode)
            }
        } catch {
            // Report the category, never the details — the details can carry the key.
            return .failure
        }
    }
}
