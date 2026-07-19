import Foundation

// MARK: - Antigravity live quota (local language server only)

/// Reads Antigravity's real quota meters from the language server it already runs
/// on this Mac — no OAuth, no cloud call, works offline.
///
/// **Provenance, stated plainly.** Antigravity (Google's Codeium/Windsurf-derived
/// IDE) publishes no usage API. What it does expose is a Connect-RPC service on a
/// random loopback port, guarded by a CSRF token that the running process carries
/// in its own argv. `RetrieveUserQuotaSummary` on that service is the *only* source
/// that reports the merged pools **and** the weekly windows, and the numbers are
/// Antigravity's own — nothing here is inferred, priced, or extrapolated. The RPC
/// is undocumented and can change without notice, so every failure degrades to
/// "no reading"; we never fall back to a guess. Each window carries its capture
/// time, so a stale value can't pass as current.
///
/// **What it reports.** Two rolling pools — Gemini models, and everything else
/// ("3p": Claude, GPT-OSS…) — each with a 5-hour and a weekly bucket. This client
/// surfaces one meter per *window* (`"5h"`, `"weekly"`), preferring the Gemini pool
/// and mentioning the third-party pool in `note` when both are present, because the
/// app renders a single pair of window meters per provider.
///
/// **Scope.** Loopback only. Antigravity also answers the same RPC at
/// `cloudcode-pa.googleapis.com` with a Keychain OAuth token; that path is
/// deliberately *not* implemented here — this client is the offline, no-credential
/// one. If Antigravity isn't running there is nothing to read, and that is an
/// absence (`.empty`, no error), not a failure.
///
/// **Security.** The CSRF token is the running app's own, read from its argv, held
/// only for the duration of a fetch, sent only to `127.0.0.1`, and never logged,
/// persisted, or printed. Response bodies are parsed, never logged.
///
/// **TLS.** The language server serves HTTPS with a self-signed certificate on that
/// loopback port, so a default `URLSession` refuses it. The session below trusts a
/// server certificate **only when the host is `127.0.0.1`**; every other host and
/// every non-server-trust challenge falls through to normal validation, so this
/// never weakens trust for a real remote endpoint. HTTP is tried after HTTPS
/// because some builds serve the extension port in the clear.
enum AntigravityQuotaClient {

    /// Same provenance tag every live reading in this app uses: reported by the
    /// provider, not computed by us.
    static let liveProvenance = "provider_reported"

    /// Result of a live fetch. `error` is short and user-facing (never the CSRF
    /// token or a raw body); `nil` means "no problem to report".
    struct Outcome: Sendable {
        var limits: [LimitWindow]
        /// Non-fatal context — e.g. the third-party pool we did not promote to a meter.
        var note: String?
        var error: String?

        init(limits: [LimitWindow] = [], note: String? = nil, error: String? = nil) {
            self.limits = limits
            self.note = note
            self.error = error
        }

        static let empty = Outcome()
    }

    // MARK: Discovery (ps argv + lsof, read-only)

    /// The executable name Antigravity's bundled language server runs under.
    static let processName = "language_server"
    /// Values that identify *this* IDE's server, matched against `--ide_name` /
    /// `--override_ide_name` / `--app_data_dir` exactly (so "antigravity" can't
    /// match "antigravity-next"), else against a `/marker/` path segment.
    static let markers = ["antigravity", "antigravity-ide"]
    /// The argv flags carrying what we need. Copied verbatim from the running app.
    static let csrfFlag = "--csrf_token"
    static let portFlag = "--extension_server_port"

    /// What a live language server tells us about itself.
    struct Discovery: Sendable, Equatable {
        /// The `--csrf_token` value. Never logged.
        var csrf: String
        /// Ports the process is listening on (from `lsof`), ascending.
        var ports: [Int]
        /// `--extension_server_port` — an HTTP-only fallback port.
        var extensionPort: Int?

        /// Every endpoint worth trying, best first: HTTPS then HTTP on each
        /// listening port, then the plain-HTTP extension port.
        var endpoints: [(scheme: String, port: Int)] {
            var out: [(scheme: String, port: Int)] = []
            for port in ports {
                out.append(("https", port))
                out.append(("http", port))
            }
            if let extensionPort, !ports.contains(extensionPort) || out.isEmpty {
                out.append(("http", extensionPort))
            }
            return out
        }
    }

    /// Find the running language server, or `nil` when Antigravity isn't running.
    /// Blocking subprocess I/O — call off the main actor.
    static func discover() -> Discovery? {
        guard let ps = BoundedProcess.run(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "args="],
            timeout: 5
        )?.trimmedText else { return nil }

        guard var discovery = discovery(fromPSOutput: ps) else { return nil }
        discovery.ports = listeningPorts()
        return (discovery.ports.isEmpty && discovery.extensionPort == nil) ? nil : discovery
    }

    /// Listening TCP ports of any `language_server` process. `ps -o args=` gives no
    /// pid, so we match `lsof`'s COMMAND column by prefix instead of `-p <pid>`;
    /// lsof truncates that column, hence the prefix match.
    private static func listeningPorts() -> [Int] {
        let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof"]
            .first { FileManager.default.fileExists(atPath: $0) }
        guard let lsof,
              let text = BoundedProcess.run(
                executable: lsof,
                arguments: ["-nP", "-iTCP", "-sTCP:LISTEN"],
                timeout: 5
              )?.trimmedText
        else { return [] }
        return parseListeningPorts(text, commandPrefix: "language_")
    }

    // MARK: Discovery parsing (pure, headless-testable)

    /// Pick the CSRF token (and any extension port) out of `ps -ax -o args=` output.
    /// An exact IDE-flag marker match beats a `/antigravity/` path match; a process
    /// with no readable `--csrf_token` is skipped, never guessed at.
    static func discovery(fromPSOutput output: String) -> Discovery? {
        var ranked: [(rank: Int, discovery: Discovery)] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let command = rawLine.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty,
                  commandMatchesProcess(command),
                  let rank = markerRank(command),
                  let csrf = extractFlag(command: command, flag: csrfFlag), !csrf.isEmpty
            else { continue }
            let port = extractFlag(command: command, flag: portFlag).flatMap { Int($0) }
            ranked.append((rank, Discovery(csrf: csrf, ports: [], extensionPort: port)))
        }
        return ranked.min { $0.rank < $1.rank }?.discovery
    }

    /// Value of a CLI flag in a command string. Handles `--flag value` and `--flag=value`.
    static func extractFlag(command: String, flag: String) -> String? {
        let parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let flagEq = flag + "="
        for (index, part) in parts.enumerated() {
            if part == flag {
                if index + 1 < parts.count { return parts[index + 1] }
            } else if part.hasPrefix(flagEq) {
                return String(part.dropFirst(flagEq.count))
            }
        }
        return nil
    }

    /// True when argv0's last path component is (or begins with) our process name.
    /// `ps -o args=` doesn't quote paths, so an install path containing a space
    /// breaks argv0 apart; `language_server` is distinctive enough that a substring
    /// match on the whole command line is a safe fallback there.
    static func commandMatchesProcess(_ command: String) -> Bool {
        let argv0 = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let exe = (argv0 as NSString).lastPathComponent.lowercased()
        // Shipped builds append a platform suffix (`language_server_macos_arm`).
        if exe == processName || exe.hasPrefix(processName + "_") { return true }
        return command.lowercased().contains(processName)
    }

    /// 0 = an exact IDE-name/app-data-dir marker; 1 = a `/marker/` path segment;
    /// `nil` = not this IDE's server (e.g. Windsurf's, which must never be read).
    static func markerRank(_ command: String) -> Int? {
        let named = ["--ide_name", "--override_ide_name", "--app_data_dir"]
            .compactMap { extractFlag(command: command, flag: $0)?.lowercased() }
        if !named.isEmpty {
            return named.contains(where: { markers.contains($0) }) ? 0 : nil
        }
        let lower = command.lowercased()
        return markers.contains(where: { lower.contains("/\($0)/") }) ? 1 : nil
    }

    /// Listening ports from `lsof -nP -iTCP -sTCP:LISTEN` output, restricted to rows
    /// whose COMMAND begins with `commandPrefix`. Deduped, ascending.
    static func parseListeningPorts(_ output: String, commandPrefix: String) -> [Int] {
        var ports = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.contains("LISTEN") else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let command = fields.first,
                  command.lowercased().hasPrefix(commandPrefix.lowercased()) else { continue }
            // e.g. "... TCP 127.0.0.1:52168 (LISTEN)" — scan back for address:port.
            for token in fields.reversed() {
                if let colon = token.lastIndex(of: ":"),
                   let port = Int(token[token.index(after: colon)...]),
                   port > 0, port < 65_536 {
                    ports.insert(port)
                    break
                }
            }
        }
        return ports.sorted()
    }

    // MARK: Buckets

    /// The bucket ids `RetrieveUserQuotaSummary` reports, matched by **exact id
    /// only** — a future bucket (say `gemini-image-5h`) must never silently become
    /// one of these meters, and pool identity is never inferred from a display name.
    /// `label` is the app's window vocabulary; `minutes` is the window length.
    static let bucketSpecs: [(id: String, label: String, minutes: Int, isGemini: Bool)] = [
        ("gemini-5h", "5h", 300, true),
        ("gemini-weekly", "weekly", 10_080, true),
        ("3p-5h", "5h", 300, false),
        ("3p-weekly", "weekly", 10_080, false)
    ]

    // MARK: Fetch

    /// Read the live quota summary from the local language server. Returns `.empty`
    /// (no error) when Antigravity simply isn't running — that's an absence, not a
    /// failure.
    static func fetch(now: Date = Date()) async -> Outcome {
        guard let discovery = discover() else { return .empty }
        let capturedAt = Int64(now.timeIntervalSince1970)

        var sawAuthFailure = false
        var saw404 = false
        var sawResponse = false

        for endpoint in discovery.endpoints {
            guard let (status, body) = await postQuotaSummary(
                scheme: endpoint.scheme, port: endpoint.port, csrf: discovery.csrf
            ) else { continue } // transport failure — wrong port for this scheme

            sawResponse = true
            switch status {
            case 200..<300:
                // A parsed summary is authoritative, even an empty one: there is no
                // second source here to fall through to, and inventing 0% would be
                // a lie. A 2xx that isn't a summary is schema drift — keep looking.
                if let outcome = parseQuotaSummary(body, capturedAt: capturedAt) {
                    if outcome.limits.isEmpty {
                        return Outcome(error: "Antigravity reported no readable quota buckets.")
                    }
                    return outcome
                }
            case 401, 403:
                sawAuthFailure = true
            case 404:
                saw404 = true // a build without this RPC
            default:
                break
            }
        }

        if sawAuthFailure {
            return Outcome(error: "Antigravity refused the local quota request — restart Antigravity.")
        }
        if saw404 {
            return Outcome(error: "This Antigravity build doesn't expose the local quota RPC.")
        }
        if sawResponse {
            return Outcome(error: "Antigravity quota unavailable right now.")
        }
        // Nothing answered on any port: the server exited between the scan and the
        // call, or is still starting. Absence, not failure.
        return .empty
    }

    // MARK: Parsing (pure, headless-testable)

    /// Parse `RetrieveUserQuotaSummary`. Accepts both envelopes: the language
    /// server wraps the payload in `{"response": {"groups": …}}`, the remote form is
    /// bare `{"groups": …}`.
    ///
    /// `nil` means "not a summary" (undecodable body, or no `groups` anywhere). A
    /// non-`nil` result is the answer. A bucket whose `remainingFraction` is missing
    /// or unusable **drops its meter** — the window reads as absent, never as 0%
    /// used and never as 100% remaining.
    static func parseQuotaSummary(_ data: Data, capturedAt: Int64) -> Outcome? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let source = (root["response"] as? [String: Any]) ?? root
        guard let groups = source["groups"] as? [[String: Any]] else { return nil }

        var pooled: [String: (fraction: Double, resetsAt: Int64?)] = [:]
        for group in groups {
            for bucket in (group["buckets"] as? [[String: Any]]) ?? [] {
                guard let id = bucket["bucketId"] as? String,
                      bucketSpecs.contains(where: { $0.id == id }) else { continue }
                guard pooled[id] == nil else { continue } // duplicate id — first wins
                guard let fraction = coerceDouble(bucket["remainingFraction"]),
                      fraction.isFinite else { continue } // dropped, not zeroed
                pooled[id] = (fraction, parseResetsAt(bucket["resetTime"]))
            }
        }

        var limits: [LimitWindow] = []
        var deferredPools: [String] = []
        for label in ["5h", "weekly"] {
            let candidates = bucketSpecs.filter { $0.label == label }
            // Gemini first: it's the pool these meters are named for. The other
            // pool is reported in `note` rather than silently discarded.
            guard let chosen = candidates.first(where: { $0.isGemini && pooled[$0.id] != nil })
                    ?? candidates.first(where: { pooled[$0.id] != nil }),
                  let entry = pooled[chosen.id]
            else { continue }

            if chosen.isGemini,
               let other = candidates.first(where: { !$0.isGemini }),
               let otherEntry = pooled[other.id] {
                let used = Int((max(0, min(1, 1 - otherEntry.fraction)) * 100).rounded())
                deferredPools.append("\(label) \(used)%")
            }

            limits.append(LimitWindow(
                label: chosen.label,
                used_percent: usedPercent(remainingFraction: entry.fraction),
                window_minutes: chosen.minutes,
                resets_at_unix: entry.resetsAt,
                provenance: liveProvenance,
                captured_at_unix: capturedAt
            ))
        }

        let note = deferredPools.isEmpty
            ? nil
            : "Non-Gemini pool (Claude, GPT-OSS): " + deferredPools.joined(separator: ", ") + " used."
        return Outcome(limits: limits, note: note, error: nil)
    }

    /// `remainingFraction` (0…1, 1 = untouched) → percent used, clamped and whole so
    /// a fresh window reads exactly 0.
    static func usedPercent(remainingFraction: Double) -> Double {
        let clamped = max(0, min(1, remainingFraction))
        return ((1 - clamped) * 100).rounded()
    }

    /// `resetTime` is ISO-8601 on every build seen; a numeric epoch (s or ms) is
    /// accepted too rather than dropping the reset silently.
    static func parseResetsAt(_ any: Any?) -> Int64? {
        if let d = coerceDouble(any) {
            return d > 1_000_000_000_000 ? Int64(d / 1000.0) : Int64(d)
        }
        guard let s = any as? String, !s.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: s) { return Int64(date.timeIntervalSince1970) }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: s) { return Int64(date.timeIntervalSince1970) }
        return nil
    }

    private static func coerceDouble(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    // MARK: Networking (loopback only)

    /// The Connect-RPC service and the metadata every language-server call carries.
    private static let service = "exa.language_server_pb.LanguageServerService"
    private static let method = "RetrieveUserQuotaSummary"
    private static let metadata: [String: String] = [
        "ideName": "antigravity", "extensionName": "antigravity",
        "ideVersion": "unknown", "locale": "en"
    ]

    /// Ephemeral (no shared cookie/cache state), loopback-only session that accepts
    /// the language server's self-signed certificate. Built once.
    nonisolated(unsafe) private static let loopbackSession: URLSession = {
        URLSession(configuration: .ephemeral,
                   delegate: AntigravityLoopbackTrust(),
                   delegateQueue: nil)
    }()

    /// POST the quota RPC. `nil` on a transport failure (that port doesn't speak
    /// this scheme) so the caller can try the next endpoint.
    private static func postQuotaSummary(
        scheme: String, port: Int, csrf: String
    ) async -> (status: Int, body: Data)? {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)/\(service)/\(method)") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        // The CSRF token goes on this header and nowhere else.
        req.setValue(csrf, forHTTPHeaderField: "x-codeium-csrf-token")
        req.httpBody = (try? JSONSerialization.data(withJSONObject: ["metadata": metadata]))
            ?? Data("{}".utf8)
        do {
            let (data, response) = try await loopbackSession.data(for: req)
            guard let http = response as? HTTPURLResponse else { return nil }
            return (http.statusCode, data)
        } catch {
            return nil
        }
    }

    // MARK: Headless self-test

    /// Exercises the pure discovery + quota parsers against fixtures shaped like
    /// Antigravity's real output. Offline and side-effect-free — safe to run
    /// headlessly, like the sibling clients' self-tests.
    static func _selftest() -> Bool {
        // 1) argv discovery: the Antigravity server wins, Windsurf's is not read.
        let ps = """
        /Applications/Windsurf.app/Contents/Resources/language_server_macos_arm --ide_name windsurf --csrf_token WRONG
        /Users/x/.antigravity/bin/language_server_macos_arm --ide_name antigravity --csrf_token TOK123 --extension_server_port 42100
        /usr/bin/some_other_process --csrf_token NOPE
        """
        guard let found = discovery(fromPSOutput: ps),
              found.csrf == "TOK123", found.extensionPort == 42100
        else { return false }

        // `--flag=value` form, and a server identified only by its path.
        let pathOnly = "/Users/x/Library/Application Support/antigravity/language_server --csrf_token=EQ1"
        guard discovery(fromPSOutput: pathOnly)?.csrf == "EQ1",
              // No marker at all ⇒ not ours ⇒ nothing discovered (never a blind read).
              discovery(fromPSOutput: "/opt/language_server --csrf_token X") == nil,
              // Marker present but no CSRF ⇒ skipped, not guessed.
              discovery(fromPSOutput: "/x/antigravity/language_server --ide_name antigravity") == nil
        else { return false }

        // 2) lsof rows: only `language_*` processes, deduped and ascending.
        let lsof = """
        COMMAND     PID USER   FD   TYPE  DEVICE SIZE/OFF NODE NAME
        language_ 12345 x      21u  IPv4  0x1        0t0  TCP 127.0.0.1:52168 (LISTEN)
        language_ 12345 x      22u  IPv4  0x2        0t0  TCP 127.0.0.1:51000 (LISTEN)
        language_ 12345 x      23u  IPv4  0x3        0t0  TCP 127.0.0.1:52168 (LISTEN)
        Google    999   x      10u  IPv4  0x4        0t0  TCP 127.0.0.1:60000 (LISTEN)
        """
        guard parseListeningPorts(lsof, commandPrefix: "language_") == [51_000, 52_168] else {
            return false
        }

        // Endpoint order: HTTPS before HTTP on a live port, extension port last.
        let endpoints = Discovery(csrf: "T", ports: [52_168], extensionPort: 42_100).endpoints
        guard endpoints.count == 3,
              endpoints[0].scheme == "https", endpoints[0].port == 52_168,
              endpoints[1].scheme == "http", endpoints[1].port == 52_168,
              endpoints[2].scheme == "http", endpoints[2].port == 42_100
        else { return false }

        // 3) The full LS envelope: four buckets, Gemini promoted, 3p noted.
        let full = """
        { "response": { "groups": [
            { "buckets": [
              { "bucketId": "gemini-5h", "remainingFraction": 0.75,
                "resetTime": "2026-07-17T18:00:00Z" },
              { "bucketId": "gemini-weekly", "remainingFraction": 0.4,
                "resetTime": "2026-07-20T00:00:00Z" } ] },
            { "buckets": [
              { "bucketId": "3p-5h", "remainingFraction": 0.5 },
              { "bucketId": "3p-weekly", "remainingFraction": 0.9 },
              { "bucketId": "gemini-image-5h", "remainingFraction": 0.1 } ] } ] } }
        """
        guard let out = parseQuotaSummary(Data(full.utf8), capturedAt: 1_752_000_000),
              out.limits.count == 2,
              out.limits[0].label == "5h", out.limits[0].used_percent == 25,
              out.limits[0].window_minutes == 300,
              out.limits[0].resets_at_unix == 1_784_311_200,
              out.limits[0].captured_at_unix == 1_752_000_000,
              out.limits[0].provenance == liveProvenance,
              out.limits[1].label == "weekly", out.limits[1].used_percent == 60,
              out.limits[1].window_minutes == 10_080,
              // The unrecognized `gemini-image-5h` bucket never joins a pool.
              out.note?.contains("5h 50%") == true, out.note?.contains("weekly 10%") == true,
              out.error == nil
        else { return false }

        // 4) A bucket with no usable fraction is DROPPED, never rendered as 0%.
        let missing = """
        { "groups": [ { "buckets": [
            { "bucketId": "gemini-5h" },
            { "bucketId": "gemini-weekly", "remainingFraction": 1.0 } ] } ] }
        """
        guard let partial = parseQuotaSummary(Data(missing.utf8), capturedAt: 7),
              partial.limits.count == 1,
              partial.limits[0].label == "weekly",
              partial.limits[0].used_percent == 0, // a full week, honestly measured
              partial.limits[0].resets_at_unix == nil,
              partial.note == nil
        else { return false }

        // 5) Only the 3p pool present ⇒ it becomes the meter, with no note.
        let thirdParty = #"{"groups":[{"buckets":[{"bucketId":"3p-5h","remainingFraction":0.2}]}]}"#
        guard let tp = parseQuotaSummary(Data(thirdParty.utf8), capturedAt: 1),
              tp.limits.count == 1, tp.limits[0].label == "5h",
              tp.limits[0].used_percent == 80, tp.note == nil
        else { return false }

        // 6) Not-a-summary ⇒ nil (caller keeps looking); an empty summary parses to
        //    zero meters rather than a fabricated reading.
        guard parseQuotaSummary(Data("not json".utf8), capturedAt: 0) == nil,
              parseQuotaSummary(Data("{}".utf8), capturedAt: 0) == nil,
              parseQuotaSummary(Data(#"{"groups":[]}"#.utf8), capturedAt: 0)?.limits.isEmpty == true
        else { return false }

        // 7) Reset-time coercion: ISO-8601 (with and without fractional seconds),
        //    epoch seconds, epoch milliseconds, and junk.
        guard parseResetsAt("2026-07-17T18:00:00Z") == 1_784_311_200,
              parseResetsAt("2026-07-17T18:00:00.500Z") == 1_784_311_200,
              parseResetsAt(1_784_311_200) == 1_784_311_200,
              parseResetsAt(1_784_311_200_000) == 1_784_311_200,
              parseResetsAt("later") == nil, parseResetsAt(nil) == nil
        else { return false }

        // 8) Fraction → percent, clamped both ways.
        guard usedPercent(remainingFraction: 1) == 0,
              usedPercent(remainingFraction: 0) == 100,
              usedPercent(remainingFraction: 1.4) == 0,
              usedPercent(remainingFraction: -0.2) == 100
        else { return false }

        return true
    }
}

/// Accepts a self-signed server certificate **only** for loopback (`127.0.0.1`).
/// Every other host — and every non-server-trust challenge — falls through to
/// default validation, so this can never weaken trust for a real remote endpoint.
/// Holds no mutable state, so it is safe to share across the session.
private final class AntigravityLoopbackTrust: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
