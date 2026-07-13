import Foundation

// MARK: - Stack Health network enrichment
//
// The portable Rust core returns an OFFLINE dependency *inventory* (installed
// versions only — it never touches the network). This client is the network
// boundary that enriches that inventory: it fetches each dependency's latest
// published version and any known security advisories, then computes an
// outdated/vulnerable status.
//
// SECURITY / PRIVACY (this whole type is the network boundary, mirroring
// `AnthropicUsageClient` / `ProviderBalanceClient`):
//   • Only public package registries are contacted — npm, crates.io, OSV. No
//     credentials, tokens, or secrets are ever sent. Only dependency *names*
//     and *versions* (already on disk in the user's manifests) leave the machine.
//   • Every request has a bounded timeout, and NOTHING here ever throws — a
//     failed fetch simply leaves that dependency "unknown". Offline is a no-op.
//   • Concurrency is bounded (≤ `maxInFlight` latest-version fetches at once)
//     and advisories are one single batched POST, so a big monorepo can't spray
//     hundreds of simultaneous requests.
//
// All entry points are `static` (nonisolated) and return `Sendable` values, so
// the SwiftUI layer can `await` this off the main actor and fold the result into
// `@State`. The parsers are pure and are exercised by `_selftest()`.
enum StackHealthClient {
    /// crates.io (and OSV, politely) require a descriptive User-Agent.
    static let userAgent = "StackPulse/0.5 (stackpulse.local)"

    /// Cap on concurrent latest-version fetches (npm/crates are per-package GETs).
    static let maxInFlight = 8

    /// Per-request network timeout.
    static let timeout: TimeInterval = 10

    // MARK: Public value types

    /// A trimmed advisory the UI renders (the core's `Advisory` carries more, but
    /// OSV's batch endpoint only returns ids + minimal metadata cheaply).
    struct AdvisoryLite: Sendable, Identifiable, Equatable {
        let id: String
        /// low | moderate | high | critical | unknown (best-effort from OSV).
        let severity: String
        let url: String?
    }

    /// The network-derived enrichment for one dependency, keyed by `Dependency.id`
    /// in the map `enrich(_:)` returns. Everything is optional/degradable: a failed
    /// fetch yields `latest == nil`, `status == "unknown"`, `advisories == []`.
    struct DependencyEnrichment: Sendable, Equatable {
        let latest: String?
        /// up_to_date | minor_behind | major_behind | unknown
        let status: String
        let advisories: [AdvisoryLite]
    }

    // MARK: - Ecosystem normalization

    /// The two ecosystems this client can enrich. A newer core that reports other
    /// ecosystems (pypi, go, …) simply isn't enriched — those deps degrade to the
    /// core's own offline status.
    enum Eco {
        case npm
        case crates

        /// OSV's ecosystem identifier for the advisory query.
        var osvName: String {
            switch self {
            case .npm: return "npm"
            case .crates: return "crates.io"
            }
        }
    }

    /// Maps the core's free-form `ecosystem` string onto a fetchable ecosystem, or
    /// `nil` when we can't enrich it. Tolerant of the various labels a manifest
    /// scanner might emit (npm/node/pnpm/yarn → npm; cargo/crate/rust → crates).
    static func normalizedEcosystem(_ raw: String) -> Eco? {
        let e = raw.lowercased()
        if e.contains("npm") || e.contains("node") || e.contains("pnpm")
            || e.contains("yarn") || e == "js" || e.contains("javascript")
            || e.contains("typescript") {
            return .npm
        }
        if e.contains("crate") || e.contains("cargo") || e.contains("rust") {
            return .crates
        }
        return nil
    }

    // MARK: - Public entry point

    /// Enriches a batch of dependencies with latest versions + advisories, keyed by
    /// `Dependency.id`. Only deps in a known ecosystem are contacted; the rest are
    /// omitted from the result so the UI can fall back to the core's offline data.
    /// Never throws — every failure degrades to "unknown" for that dependency.
    static func enrich(_ deps: [Dependency]) async -> [String: DependencyEnrichment] {
        // Only npm/crates deps are network-enrichable.
        let fetchable = deps.filter { normalizedEcosystem($0.ecosystem) != nil }
        guard !fetchable.isEmpty else { return [:] }

        // 1) Latest versions — bounded-concurrency, one GET per package.
        var latestByID: [String: String] = [:]
        for chunk in chunk(fetchable, size: maxInFlight) {
            await withTaskGroup(of: (String, String?).self) { group in
                for dep in chunk {
                    group.addTask { (dep.id, await fetchLatest(dep)) }
                }
                for await (id, latest) in group {
                    if let latest, !latest.isEmpty { latestByID[id] = latest }
                }
            }
        }

        // 2) Advisories — ONE batched POST to OSV for every dep with a version.
        let advisoriesByID = await fetchAdvisories(fetchable)

        // 3) Merge into a per-dependency enrichment.
        var out: [String: DependencyEnrichment] = [:]
        out.reserveCapacity(fetchable.count)
        for dep in fetchable {
            let latest = latestByID[dep.id]
            let advisories = advisoriesByID[dep.id] ?? []
            let status = compareStatus(installed: installedVersion(dep), latest: latest)
            out[dep.id] = DependencyEnrichment(
                latest: latest,
                status: status,
                advisories: advisories
            )
        }
        return out
    }

    // MARK: - Latest version fetchers

    private static func fetchLatest(_ dep: Dependency) async -> String? {
        switch normalizedEcosystem(dep.ecosystem) {
        case .npm: return await fetchNpmLatest(dep.name)
        case .crates: return await fetchCratesLatest(dep.name)
        case nil: return nil
        }
    }

    /// `GET https://registry.npmjs.org/<name>/latest` → `{ "version": "x.y.z" }`.
    /// Scoped names (`@scope/pkg`) have their `/` percent-encoded to `%2F`.
    static func fetchNpmLatest(_ name: String) async -> String? {
        let encoded = name.replacingOccurrences(of: "/", with: "%2F")
        guard let url = URL(string: "https://registry.npmjs.org/\(encoded)/latest") else { return nil }
        guard let data = await get(url) else { return nil }
        return parseNpmLatest(data)
    }

    /// `GET https://crates.io/api/v1/crates/<name>` →
    /// `{ "crate": { "max_stable_version": "x", "newest_version": "y" } }`.
    /// Prefers the max *stable* version, falling back to the newest. crates.io
    /// requires a descriptive `User-Agent`.
    static func fetchCratesLatest(_ name: String) async -> String? {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let url = URL(string: "https://crates.io/api/v1/crates/\(encoded)") else { return nil }
        guard let data = await get(url) else { return nil }
        return parseCratesLatest(data)
    }

    // MARK: - Advisories (OSV batch)

    /// One batched `POST https://api.osv.dev/v1/querybatch` for every dep that has
    /// a concrete version to check. Response `results[i].vulns[]` lines up with the
    /// queries by index. Never throws; a failure yields no advisories.
    private static func fetchAdvisories(_ deps: [Dependency]) async -> [String: [AdvisoryLite]] {
        // One query per dep that has a known ecosystem AND a concrete version.
        var ids: [String] = []
        var queries: [[String: Any]] = []
        for dep in deps {
            guard let eco = normalizedEcosystem(dep.ecosystem) else { continue }
            guard let version = installedVersion(dep), !version.isEmpty else { continue }
            ids.append(dep.id)
            queries.append([
                "package": ["name": dep.name, "ecosystem": eco.osvName],
                "version": version,
            ])
        }
        guard !queries.isEmpty else { return [:] }
        guard let body = try? JSONSerialization.data(withJSONObject: ["queries": queries]) else {
            return [:]
        }

        var req = URLRequest(url: URL(string: "https://api.osv.dev/v1/querybatch")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [:] }
            return parseOSVBatch(data, ids: ids)
        } catch {
            // Offline / TLS / timeout → simply no advisories.
            return [:]
        }
    }

    // MARK: - Networking

    /// A single GET with a bounded timeout. Returns the body only on HTTP 200,
    /// `nil` on any error/non-200. Never throws, never logs.
    private static func get(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Parsing (pure, headless-testable)

    /// npm `.../latest` → `.version`.
    static func parseNpmLatest(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["version"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// crates.io crate → `.crate.max_stable_version` (fallback `.crate.newest_version`).
    static func parseCratesLatest(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let crate = root["crate"] as? [String: Any] else { return nil }
        if let stable = crate["max_stable_version"] as? String, !stable.isEmpty { return stable }
        if let newest = crate["newest_version"] as? String, !newest.isEmpty { return newest }
        return nil
    }

    /// OSV `querybatch` → `results[i].vulns[]`, aligned to `ids` by index. Severity
    /// is best-effort (the batch endpoint is intentionally minimal, so most come
    /// back "unknown"). Pure and side-effect-free.
    static func parseOSVBatch(_ data: Data, ids: [String]) -> [String: [AdvisoryLite]] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [:] }

        var out: [String: [AdvisoryLite]] = [:]
        for (i, result) in results.enumerated() {
            guard i < ids.count else { break }
            guard let vulns = result["vulns"] as? [[String: Any]], !vulns.isEmpty else { continue }
            var lites: [AdvisoryLite] = []
            var seen = Set<String>()
            for v in vulns {
                guard let vid = v["id"] as? String, !vid.isEmpty, !seen.contains(vid) else { continue }
                seen.insert(vid)
                lites.append(AdvisoryLite(
                    id: vid,
                    severity: severity(from: v),
                    url: osvURL(vid)
                ))
            }
            if !lites.isEmpty { out[ids[i]] = lites }
        }
        return out
    }

    /// Best-effort severity from an OSV vuln object: prefer GHSA's
    /// `database_specific.severity` (LOW/MODERATE/HIGH/CRITICAL), else a numeric
    /// CVSS score band, else "unknown".
    static func severity(from vuln: [String: Any]) -> String {
        if let ds = vuln["database_specific"] as? [String: Any],
           let s = ds["severity"] as? String, !s.isEmpty {
            return normalizeSeverity(s)
        }
        if let sevs = vuln["severity"] as? [[String: Any]] {
            for entry in sevs {
                if let raw = entry["score"], let band = cvssBand(raw) { return band }
            }
        }
        return "unknown"
    }

    /// Canonical human URL for a vuln id (GHSA / OSV both resolve on osv.dev).
    static func osvURL(_ id: String) -> String { "https://osv.dev/vulnerability/\(id)" }

    // MARK: - Severity helpers

    static func normalizeSeverity(_ raw: String) -> String {
        switch raw.lowercased() {
        case "low": return "low"
        case "moderate", "medium": return "moderate"
        case "high": return "high"
        case "critical": return "critical"
        default: return "unknown"
        }
    }

    /// Maps a plain numeric CVSS base score to a band. OSV usually stores a CVSS
    /// *vector* string here (which we can't cheaply score), so this only fires when
    /// a bare number is present — otherwise the caller falls through to "unknown".
    static func cvssBand(_ any: Any) -> String? {
        let score: Double?
        switch any {
        case let n as NSNumber: score = n.doubleValue
        case let d as Double: score = d
        case let i as Int: score = Double(i)
        case let s as String: score = Double(s)   // nil for a "CVSS:3.1/…" vector
        default: score = nil
        }
        guard let v = score else { return nil }
        switch v {
        case ..<0.1: return "unknown"
        case ..<4.0: return "low"
        case ..<7.0: return "moderate"
        case ..<9.0: return "high"
        default: return "critical"
        }
    }

    // MARK: - Version resolution + semver comparison

    /// The concrete version to reason about: the installed (lockfile) version when
    /// present, else the required spec with its range operators stripped.
    static func installedVersion(_ dep: Dependency) -> String? {
        if let i = dep.installed, !i.isEmpty { return i }
        if let r = dep.required, !r.isEmpty { return strippedRequired(r) }
        return nil
    }

    /// Strips leading range operators / prefixes (`^ ~ >= <= = v` and spaces) so a
    /// required spec like `"^1.2.3"` or `">=1.0.0"` yields a comparable version.
    static func strippedRequired(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = trimmed.firstIndex(where: { $0.isNumber }) else { return nil }
        return String(trimmed[idx...])
    }

    /// Parses the leading `major.minor.patch` of a version, tolerating a `v`
    /// prefix, range operators, wildcards, and prerelease/build suffixes. Missing
    /// components default to 0. Returns `nil` when there's no numeric major.
    static func parseSemVer(_ raw: String?) -> (Int, Int, Int)? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        // Advance to the first digit (handles ^, ~, >=, =, v, whitespace).
        guard let start = s.firstIndex(where: { $0.isNumber }) else { return nil }
        s = String(s[start...])
        // Cut at the first prerelease/build/range separator.
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" || $0 == " " || $0 == "," }) {
            s = String(s[..<cut])
        }
        let comps = s.split(separator: ".", omittingEmptySubsequences: false)
        func intAt(_ i: Int) -> Int {
            guard i < comps.count else { return 0 }
            return Int(comps[i].prefix { $0.isNumber }) ?? 0   // "x"/"*" wildcards → 0
        }
        guard !comps.isEmpty, Int(comps[0].prefix { $0.isNumber }) != nil else { return nil }
        return (intAt(0), intAt(1), intAt(2))
    }

    /// Compares installed vs latest into a status string:
    /// latest ≤ installed → "up_to_date"; major differs → "major_behind";
    /// minor/patch differs → "minor_behind"; unparseable/missing → "unknown".
    static func compareStatus(installed: String?, latest: String?) -> String {
        guard let latest,
              let a = parseSemVer(installed),
              let b = parseSemVer(latest) else { return "unknown" }
        // latest (b) ≤ installed (a) → nothing to do.
        if b.0 < a.0
            || (b.0 == a.0 && (b.1 < a.1 || (b.1 == a.1 && b.2 <= a.2))) {
            return "up_to_date"
        }
        if b.0 != a.0 { return "major_behind" }
        return "minor_behind"
    }

    // MARK: - Utilities

    /// Splits an array into fixed-size chunks (a local helper to bound concurrency
    /// without adding a global `Array` extension that could collide across files).
    private static func chunk<T>(_ array: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [array] }
        var result: [[T]] = []
        result.reserveCapacity((array.count + size - 1) / size)
        var i = 0
        while i < array.count {
            result.append(Array(array[i..<min(i + size, array.count)]))
            i += size
        }
        return result
    }

    // MARK: - Headless self-test

    /// Exercises the pure parsers + semver logic against embedded fixtures,
    /// returning `true` when every assertion holds. Pure and offline — safe to run
    /// headlessly (never touches the network). Kept in the shipping binary (not
    /// behind `#if DEBUG`) so it can be compiled + run standalone for verification,
    /// exactly like `AnthropicUsageClient._selftest` / `ProviderBalanceClient._selftest`.
    static func _selftest() -> Bool {
        // 1) npm + crates latest parsing.
        guard parseNpmLatest(Data(#"{"name":"react","version":"19.1.0"}"#.utf8)) == "19.1.0",
              parseNpmLatest(Data("not json".utf8)) == nil,
              parseCratesLatest(Data(#"{"crate":{"max_stable_version":"1.0.219","newest_version":"1.0.220-beta"}}"#.utf8)) == "1.0.219",
              parseCratesLatest(Data(#"{"crate":{"newest_version":"0.9.0"}}"#.utf8)) == "0.9.0",
              parseCratesLatest(Data("{}".utf8)) == nil
        else { return false }

        // 2) Semver comparison.
        guard compareStatus(installed: "1.2.3", latest: "1.2.3") == "up_to_date",
              compareStatus(installed: "1.2.3", latest: "1.2.4") == "minor_behind",
              compareStatus(installed: "1.2.3", latest: "1.4.0") == "minor_behind",
              compareStatus(installed: "1.2.3", latest: "2.0.0") == "major_behind",
              compareStatus(installed: "^1.2.3", latest: "1.9.9") == "minor_behind",
              compareStatus(installed: "v2.0.0", latest: "1.0.0") == "up_to_date",   // newer installed
              compareStatus(installed: "1.2.3", latest: nil) == "unknown",
              compareStatus(installed: "garbage", latest: "1.0.0") == "unknown"
        else { return false }

        // 3) required-spec stripping.
        guard strippedRequired("^1.2.3") == "1.2.3",
              strippedRequired(">= 4.5.6") == "4.5.6",
              strippedRequired("~2.0") == "2.0",
              strippedRequired("workspace:*") == nil
        else { return false }

        // 4) Ecosystem normalization.
        guard normalizedEcosystem("npm") == .npm,
              normalizedEcosystem("Node.js") == .npm,
              normalizedEcosystem("cargo") == .crates,
              normalizedEcosystem("rust") == .crates,
              normalizedEcosystem("pypi") == nil
        else { return false }

        // 5) OSV batch parse (results align by index; severity best-effort).
        let osv = """
        { "results": [
            {},
            { "vulns": [ { "id": "GHSA-aaaa", "database_specific": { "severity": "HIGH" } } ] },
            { "vulns": [ { "id": "RUSTSEC-2024-0001" } ] }
        ] }
        """
        let parsed = parseOSVBatch(Data(osv.utf8), ids: ["a", "b", "c"])
        guard parsed["a"] == nil,
              parsed["b"]?.first?.id == "GHSA-aaaa",
              parsed["b"]?.first?.severity == "high",
              parsed["c"]?.first?.severity == "unknown",
              parsed["c"]?.first?.url == "https://osv.dev/vulnerability/RUSTSEC-2024-0001"
        else { return false }

        // 6) Severity + CVSS banding.
        guard normalizeSeverity("MEDIUM") == "moderate",
              cvssBand("9.8") == "critical",
              cvssBand("7.1") == "high",
              cvssBand("5.0") == "moderate",
              cvssBand("2.0") == "low",
              cvssBand("CVSS:3.1/AV:N/AC:L") == nil
        else { return false }

        return true
    }
}
