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

    /// What ONE registry document says about a package. `repositoryURL` and
    /// `homepageURL` are already normalized to a browsable `https://` URL, or are
    /// `nil` — nothing here is ever derived from the package's *name*.
    struct RegistryFacts: Sendable, Equatable {
        let latest: String?
        let repositoryURL: String?
        let homepageURL: String?
    }

    /// The network-derived enrichment for one dependency, keyed by `Dependency.id`
    /// in the map `enrich(_:)` returns. Everything is optional/degradable: a failed
    /// fetch yields `latest == nil`, `status == "unknown"`, `advisories == []`.
    struct DependencyEnrichment: Sendable, Equatable {
        let latest: String?
        /// up_to_date | minor_behind | major_behind | unknown
        let status: String
        let advisories: [AdvisoryLite]
        /// Where the package itself says its source lives, per the registry.
        let repositoryURL: String?
        /// The package's own stated homepage, per the registry.
        let homepageURL: String?
        /// The instant the registry answered for this dependency. `nil` means no
        /// registry ever answered — which is why it isn't a `Date` with a default.
        let checkedAt: Date?

        /// Explicit (not synthesized) so the three fields above can default: this
        /// type is constructed by tests and by `enrich`, and a memberwise init has
        /// no defaults for `let`s.
        init(
            latest: String?,
            status: String,
            advisories: [AdvisoryLite],
            repositoryURL: String? = nil,
            homepageURL: String? = nil,
            checkedAt: Date? = nil
        ) {
            self.latest = latest
            self.status = status
            self.advisories = advisories
            self.repositoryURL = repositoryURL
            self.homepageURL = homepageURL
            self.checkedAt = checkedAt
        }
    }

    // MARK: - Change routes

    /// A route to where a package publishes what changed between versions.
    ///
    /// "react is major behind" is a semver label, not analysis: it says a number
    /// moved, not what moved with it. StackPulse does not read release notes and
    /// will not say what a bump breaks — so the only honest thing it can add is a
    /// *verified way to go find out*. Every case below is a URL the package's own
    /// registry metadata pointed at; none is derived from its name.
    ///
    /// Deliberately NOT built: a `…/compare/<a>…<b>` diff. A compare URL needs the
    /// two git TAG names, and a version is not a tag — `react` tags `v19.1.0`,
    /// some crates tag a bare `1.0.219`, and monorepos tag `next@15.0.0` for a
    /// package whose own version string is different again. Guessing the tag ships
    /// a 404 dressed as an answer, which is strictly worse than the releases page.
    struct ChangeLink: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            /// The repository is on GitHub, so `/releases` is that host's real,
            /// canonical route to the notes maintainers publish. (It can be empty
            /// — that's the maintainer's answer, not a wrong link.)
            case githubReleases
            /// A repo page on some other host. Browsable — but where, or whether,
            /// that host publishes releases is not something we know, so the link
            /// promises only the repository.
            case repository
            /// No repository in the metadata at all; only a stated homepage.
            case homepage
        }
        let kind: Kind
        let url: String
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

        // 1) Registry facts — bounded-concurrency, one GET per package. The same
        //    document that carries the latest version also carries the package's
        //    own repository/homepage, so the "what changed" route costs no extra
        //    request: it's a field we were already downloading and discarding.
        var factsByID: [String: RegistryFacts] = [:]
        var checkedAtByID: [String: Date] = [:]
        for chunk in chunk(fetchable, size: maxInFlight) {
            await withTaskGroup(of: (String, RegistryFacts?, Date?).self) { group in
                for dep in chunk {
                    group.addTask {
                        let facts = await fetchFacts(dep)
                        // Stamped ONLY when the registry actually answered. A
                        // request that timed out gets no time rather than "now".
                        let at: Date? = facts == nil ? nil : Date()
                        return (dep.id, facts, at)
                    }
                }
                for await (id, facts, at) in group {
                    if let facts { factsByID[id] = facts }
                    if let at { checkedAtByID[id] = at }
                }
            }
        }

        // 2) Advisories — ONE batched POST to OSV for every dep with a version.
        let advisoriesByID = await fetchAdvisories(fetchable)

        // 3) Merge into a per-dependency enrichment.
        var out: [String: DependencyEnrichment] = [:]
        out.reserveCapacity(fetchable.count)
        for dep in fetchable {
            let facts = factsByID[dep.id]
            let latest = facts?.latest
            let advisories = advisoriesByID[dep.id] ?? []
            let status = compareStatus(installed: installedVersion(dep), latest: latest)
            out[dep.id] = DependencyEnrichment(
                latest: latest,
                status: status,
                advisories: advisories,
                repositoryURL: facts?.repositoryURL,
                homepageURL: facts?.homepageURL,
                checkedAt: checkedAtByID[dep.id]
            )
        }
        return out
    }

    // MARK: - Registry fetchers

    private static func fetchFacts(_ dep: Dependency) async -> RegistryFacts? {
        switch normalizedEcosystem(dep.ecosystem) {
        case .npm: return await fetchNpmFacts(dep.name)
        case .crates: return await fetchCratesFacts(dep.name)
        case nil: return nil
        }
    }

    /// `GET https://registry.npmjs.org/<name>/latest` → the latest version's
    /// document (`version`, `repository`, `homepage` — the package's published
    /// package.json fields). Scoped names (`@scope/pkg`) percent-encode their `/`.
    static func fetchNpmFacts(_ name: String) async -> RegistryFacts? {
        let encoded = name.replacingOccurrences(of: "/", with: "%2F")
        guard let url = URL(string: "https://registry.npmjs.org/\(encoded)/latest") else { return nil }
        guard let data = await get(url) else { return nil }
        return parseNpmFacts(data)
    }

    /// `GET https://crates.io/api/v1/crates/<name>` → `{ "crate": { … } }` with
    /// `max_stable_version` / `newest_version`, `repository`, `homepage`.
    /// crates.io requires a descriptive `User-Agent`.
    static func fetchCratesFacts(_ name: String) async -> RegistryFacts? {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        guard let url = URL(string: "https://crates.io/api/v1/crates/\(encoded)") else { return nil }
        guard let data = await get(url) else { return nil }
        return parseCratesFacts(data)
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
        return npmLatest(root)
    }

    /// crates.io crate → `.crate.max_stable_version` (fallback `.crate.newest_version`).
    static func parseCratesLatest(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let crate = root["crate"] as? [String: Any] else { return nil }
        return cratesLatest(crate)
    }

    /// npm `.../latest` → version + the package's own repository/homepage.
    ///
    /// `repository` is either a string shorthand or `{ "type": …, "url": … }`, and
    /// may carry a `directory` for a monorepo package. The directory is ignored on
    /// purpose: releases are published at the repo root, so it would narrow the
    /// link without making it truer.
    static func parseNpmFacts(_ data: Data) -> RegistryFacts? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var repoRaw: String?
        if let s = root["repository"] as? String {
            repoRaw = s
        } else if let d = root["repository"] as? [String: Any] {
            repoRaw = d["url"] as? String
        }
        return RegistryFacts(
            latest: npmLatest(root),
            repositoryURL: normalizeRepositoryURL(repoRaw),
            homepageURL: normalizeHomepageURL(root["homepage"] as? String)
        )
    }

    /// crates.io crate → version + repository/homepage. crates.io stores plain URL
    /// strings, already in browsable form.
    static func parseCratesFacts(_ data: Data) -> RegistryFacts? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let crate = root["crate"] as? [String: Any] else { return nil }
        return RegistryFacts(
            latest: cratesLatest(crate),
            repositoryURL: normalizeRepositoryURL(crate["repository"] as? String),
            homepageURL: normalizeHomepageURL(crate["homepage"] as? String)
        )
    }

    /// The one npm latest-version formula, shared by both parsers above so the
    /// `latest` a row shows and the `latest` a facts fetch carries cannot drift.
    private static func npmLatest(_ root: [String: Any]) -> String? {
        (root["version"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The one crates.io latest-version formula: prefer the max *stable* version,
    /// fall back to the newest.
    private static func cratesLatest(_ crate: [String: Any]) -> String? {
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

    // MARK: - Repository / homepage resolution (pure)

    /// The best verified route to what changed for one dependency, or `nil` when
    /// the registry gave us nowhere to send the user.
    ///
    /// `nil` is an ORDINARY answer — plenty of packages publish no repository — and
    /// it must stay one. The alternative (composing `github.com/<name>`) is right
    /// often enough to look like it works and wrong often enough to send someone to
    /// a stranger's repo, so it is not attempted anywhere in this file.
    static func changeLink(for e: DependencyEnrichment) -> ChangeLink? {
        // A GitHub repo — from `repository`, or from a `homepage` that IS the repo
        // (`"homepage": "https://github.com/foo/bar#readme"` is an npm norm).
        if let slug = githubSlug(e.repositoryURL) ?? githubSlug(e.homepageURL) {
            return ChangeLink(kind: .githubReleases, url: "https://github.com/\(slug)/releases")
        }
        if let repo = e.repositoryURL { return ChangeLink(kind: .repository, url: repo) }
        if let home = e.homepageURL { return ChangeLink(kind: .homepage, url: home) }
        return nil
    }

    /// `owner/repo` when a URL resolves to a GitHub repository, else `nil`.
    static func githubSlug(_ raw: String?) -> String? {
        guard let norm = normalizeRepositoryURL(raw) else { return nil }
        let prefix = "https://github.com/"
        guard norm.hasPrefix(prefix) else { return nil }
        let slug = String(norm.dropFirst(prefix.count))
        guard slug.split(separator: "/").count == 2 else { return nil }
        return slug
    }

    /// A package's stated repository → a browsable `https://` URL, or `nil`.
    ///
    /// Handles the shapes registries actually contain: npm's `git+https://….git`,
    /// `git://`, `git+ssh://git@host/…`, scp-style `git@host:owner/repo.git`, the
    /// package.json shorthands, and plain `https://` pages. Anything else — most
    /// importantly a repo on a host we can't browse — returns `nil`, never a guess.
    static func normalizeRepositoryURL(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let short = shorthandRepositoryURL(s) { return short }
        // npm records the VCS as a URL prefix ("git+https://…"); drop it.
        if s.lowercased().hasPrefix("git+") { s = String(s.dropFirst(4)) }
        // scp-style "git@github.com:owner/repo.git" has no scheme to parse.
        if !s.contains("://"), let rewritten = scpStyleToURLString(s) { s = rewritten }

        guard let comps = URLComponents(string: s),
              let rawHost = comps.host, !rawHost.isEmpty else { return nil }
        let host = rawHost.lowercased()
        var segs = comps.percentEncodedPath.split(separator: "/").map(String.init)
        guard !segs.isEmpty else { return nil }
        segs[segs.count - 1] = stripDotGit(segs[segs.count - 1])

        // GitHub: the repo is exactly the first two segments, whatever else the URL
        // carries — `…/tree/canary/packages/next` is still the vercel/next.js repo.
        // The scheme is ignored here (and only here) because github.com over https
        // is known-true, not assumed.
        if host == "github.com" || host == "www.github.com" {
            guard segs.count >= 2, isRepoSegment(segs[0]) else { return nil }
            let repo = stripDotGit(segs[1])
            guard isRepoSegment(repo) else { return nil }
            return "https://github.com/\(segs[0])/\(repo)"
        }

        // Any other host: pass through only what is ALREADY browsable over https.
        // Upgrading a `git://` or `ssh://` URL on an unknown host to https assumes
        // that host serves the same path over the web — exactly the guess this
        // function exists to refuse.
        guard comps.scheme?.lowercased() == "https" else { return nil }
        return "https://\(host)/" + segs.joined(separator: "/")
    }

    /// A package's stated homepage → the URL, if it's a web page we can open.
    /// Not normalized further: a homepage is whatever the maintainer says it is.
    static func normalizeHomepageURL(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        guard let comps = URLComponents(string: s),
              let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = comps.host, !host.isEmpty else { return nil }
        return s
    }

    /// package.json's documented `repository` shorthands: `github:` / `gitlab:` /
    /// `bitbucket:` name their host, and a bare `"owner/repo"` means GitHub.
    ///
    /// The bare form is the SPEC's own default, not an inference from the package
    /// name — `repoPair` still rejects anything that isn't exactly two plausible
    /// path segments, so a name like `@babel/core` can never be mistaken for one.
    /// `gist:` is unhandled on purpose: a gist has no releases page.
    static func shorthandRepositoryURL(_ raw: String) -> String? {
        let hosts: [(String, String)] = [
            ("github:", "https://github.com/"),
            ("gitlab:", "https://gitlab.com/"),
            ("bitbucket:", "https://bitbucket.org/"),
        ]
        let lowered = raw.lowercased()
        for (prefix, base) in hosts where lowered.hasPrefix(prefix) {
            guard let pair = repoPair(String(raw.dropFirst(prefix.count))) else { return nil }
            return base + pair.0 + "/" + pair.1
        }
        // Bare "owner/repo". Anything carrying a scheme or host has a colon and is
        // not the shorthand — it falls through to full-URL parsing.
        guard !raw.contains(":"), let pair = repoPair(raw) else { return nil }
        return "https://github.com/" + pair.0 + "/" + pair.1
    }

    /// Splits exactly `owner/repo` (a trailing `.git` or `/` tolerated) into its two
    /// segments, or `nil` when it isn't that shape.
    static func repoPair(_ raw: String) -> (String, String)? {
        var s = raw
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        s = stripDotGit(s)
        let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, isRepoSegment(parts[0]), isRepoSegment(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    /// `git@github.com:owner/repo.git` → an https URL string.
    ///
    /// Restricted to GitHub deliberately. scp-style syntax carries no scheme, so
    /// rewriting it to `https://` assumes the host serves that path over the web:
    /// known-true for github.com, a guess anywhere else — so anywhere else gets no
    /// link at all.
    static func scpStyleToURLString(_ s: String) -> String? {
        guard let at = s.firstIndex(of: "@") else { return nil }
        let rest = s[s.index(after: at)...]
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let host = String(rest[..<colon]).lowercased()
        guard host == "github.com" || host == "www.github.com" else { return nil }
        let path = String(rest[rest.index(after: colon)...])
        guard !path.isEmpty else { return nil }
        return "https://github.com/\(path)"
    }

    /// A plausible owner/repo path segment: ASCII letters, digits, `.`, `-`, `_`.
    /// Strict on purpose — a segment we can't vouch for yields NO link rather than
    /// a link to somewhere else.
    static func isRepoSegment(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 100, s != ".", s != ".." else { return false }
        return s.allSatisfy { c in
            (c.isASCII && (c.isLetter || c.isNumber)) || c == "." || c == "-" || c == "_"
        }
    }

    private static func stripDotGit(_ s: String) -> String {
        s.hasSuffix(".git") ? String(s.dropLast(4)) : s
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

        // 7) Repository normalization. This is the ONLY thing separating a "what
        // changed" route from a fabricated one, so every shape a registry actually
        // returns is pinned here — including the shapes that must yield NOTHING.
        guard normalizeRepositoryURL("git+https://github.com/facebook/react.git") == "https://github.com/facebook/react",
              normalizeRepositoryURL("https://github.com/facebook/react") == "https://github.com/facebook/react",
              normalizeRepositoryURL("git://github.com/foo/bar.git") == "https://github.com/foo/bar",
              normalizeRepositoryURL("git+ssh://git@github.com/foo/bar.git") == "https://github.com/foo/bar",
              normalizeRepositoryURL("git@github.com:foo/bar.git") == "https://github.com/foo/bar",
              // A monorepo package points at a path inside its repo; the repo is
              // still the first two segments.
              normalizeRepositoryURL("https://github.com/vercel/next.js/tree/canary/packages/next") == "https://github.com/vercel/next.js",
              normalizeRepositoryURL("github:foo/bar") == "https://github.com/foo/bar",
              normalizeRepositoryURL("foo/bar") == "https://github.com/foo/bar",
              normalizeRepositoryURL("gitlab:foo/bar") == "https://gitlab.com/foo/bar",
              normalizeRepositoryURL("https://gitlab.com/foo/bar.git") == "https://gitlab.com/foo/bar",
              // Unknown host with no browsable scheme → no link, not a guessed one.
              normalizeRepositoryURL("git@example.com:foo/bar.git") == nil,
              normalizeRepositoryURL("git://example.com/foo/bar.git") == nil,
              normalizeRepositoryURL("https://github.com/onlyowner") == nil,
              // A package NAME must never resolve to a repo. Scoped npm names are
              // `owner/repo`-shaped, and this is the fabrication the file refuses.
              normalizeRepositoryURL("@babel/core") == nil,
              normalizeRepositoryURL("react") == nil,
              normalizeRepositoryURL("") == nil,
              normalizeRepositoryURL(nil) == nil
        else { return false }

        // 8) Change links follow the evidence, and no evidence → no link.
        let gh = DependencyEnrichment(
            latest: "19.1.0", status: "major_behind", advisories: [],
            repositoryURL: "https://github.com/facebook/react"
        )
        guard changeLink(for: gh)?.kind == .githubReleases,
              changeLink(for: gh)?.url == "https://github.com/facebook/react/releases"
        else { return false }

        // A homepage that IS the repo still resolves to releases.
        let homeIsRepo = DependencyEnrichment(
            latest: "1.0.0", status: "major_behind", advisories: [],
            homepageURL: "https://github.com/foo/bar#readme"
        )
        guard changeLink(for: homeIsRepo)?.kind == .githubReleases,
              changeLink(for: homeIsRepo)?.url == "https://github.com/foo/bar/releases"
        else { return false }

        // A non-GitHub repo links the repo and promises nothing more.
        let gl = DependencyEnrichment(
            latest: "1.0.0", status: "major_behind", advisories: [],
            repositoryURL: "https://gitlab.com/foo/bar"
        )
        guard changeLink(for: gl)?.kind == .repository,
              changeLink(for: gl)?.url == "https://gitlab.com/foo/bar"
        else { return false }

        // A homepage that isn't a repo is offered as a homepage, nothing more.
        let onlyHome = DependencyEnrichment(
            latest: "1.0.0", status: "major_behind", advisories: [],
            homepageURL: "https://example.com/docs"
        )
        guard changeLink(for: onlyHome)?.kind == .homepage else { return false }

        // A package that told us nothing gets NO link. This is the normal case for
        // plenty of packages and must never become an invented one.
        guard changeLink(for: DependencyEnrichment(latest: "1.0.0", status: "major_behind", advisories: [])) == nil
        else { return false }

        // 9) Facts carry the repository the package itself published (`directory`
        // present and ignored — releases live at the repo root).
        let npmDoc = #"{"name":"react","version":"19.1.0","homepage":"https://react.dev","repository":{"type":"git","url":"git+https://github.com/facebook/react.git","directory":"packages/react"}}"#
        let facts = parseNpmFacts(Data(npmDoc.utf8))
        guard facts?.latest == "19.1.0",
              facts?.repositoryURL == "https://github.com/facebook/react",
              facts?.homepageURL == "https://react.dev",
              parseNpmFacts(Data("not json".utf8)) == nil,
              // No repository field is ordinary, not an error.
              parseNpmFacts(Data(#"{"version":"1.0.0"}"#.utf8))?.repositoryURL == nil
        else { return false }

        let crateDoc = #"{"crate":{"max_stable_version":"1.0.219","newest_version":"1.0.220-beta","repository":"https://github.com/serde-rs/serde"}}"#
        let cFacts = parseCratesFacts(Data(crateDoc.utf8))
        guard cFacts?.latest == "1.0.219",
              cFacts?.repositoryURL == "https://github.com/serde-rs/serde",
              cFacts?.homepageURL == nil,
              parseCratesFacts(Data("{}".utf8)) == nil
        else { return false }

        return true
    }
}
