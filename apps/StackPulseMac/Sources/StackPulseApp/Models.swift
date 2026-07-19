import Foundation

// Swift mirrors of the `stackpulse-protocol` JSON. Enums that may gain new
// values over time (health, provenance, provider id) are decoded as `String`
// and interpreted in the view layer, so a newer core never breaks decoding
// (forward compatibility — same principle as the Rust `#[serde(other)]`).
//
// All types are value types and `Sendable`, so a snapshot can cross the actor
// boundary from the background scan to the main actor safely under Swift 6.

struct SPVersion: Codable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    var text: String { "\(major).\(minor).\(patch)" }
}

/// Wraps a `Decodable` so a failure decodes to `nil` instead of throwing —
/// the building block for `decodeLossyArray`.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// Decode an array element-by-element, keeping the elements that decode and
    /// dropping only those that don't — so one malformed item can't collapse the
    /// whole array to empty. An absent key, an explicit null, or a non-array value
    /// all yield `[]` (same as `decodeIfPresent`). Use where an all-or-nothing
    /// decode would turn a single bad element into a dangerous empty result.
    func decodeLossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        guard let wrapped = try? decode([Lossy<T>].self, forKey: key) else { return [] }
        return wrapped.compactMap(\.value)
    }
}

struct TokenTotals: Codable, Sendable {
    var input_tokens: UInt64 = 0
    var output_tokens: UInt64 = 0
    var cache_creation_tokens: UInt64 = 0
    var cache_read_tokens: UInt64 = 0
    var reasoning_tokens: UInt64 = 0

    var grandTotal: UInt64 {
        input_tokens + output_tokens + cache_creation_tokens + cache_read_tokens + reasoning_tokens
    }

    /// read / (read + creation); nil when there was no cache activity.
    var cacheHitRate: Double? {
        let denom = Double(cache_read_tokens + cache_creation_tokens)
        return denom == 0 ? nil : Double(cache_read_tokens) / denom
    }
}

struct SpendWindow: Codable, Sendable, Identifiable {
    let label: String
    let tokens: TokenTotals
    let estimated_cost_usd: Double?
    let records: UInt64
    var id: String { label }
}

struct ModelUsage: Codable, Sendable, Identifiable {
    let model: String
    let tokens: TokenTotals
    let estimated_cost_usd: Double?
    let records: UInt64
    var id: String { model }
}

/// One day's usage in the 30-day analytics series (oldest → newest, zeros filled).
struct DailyUsage: Codable, Sendable, Identifiable {
    let date: String
    let tokens: TokenTotals
    let estimated_cost_usd: Double?
    let records: UInt64
    var id: String { date }
}

/// Derived 30-day analytics the core computes per provider. Absent (`nil`) for
/// detection-only providers; present for those with local session history.
struct ProviderAnalytics: Codable, Sendable {
    /// MEASURED $ saved by cache reads vs. paying the full input rate (30d).
    let cache_savings_usd: Double?
    /// Estimated average spend per ACTIVE day over 30 days.
    let burn_rate_usd_per_day: Double?
    /// Cache read fraction, 0…1.
    let cache_hit_rate: Double?
    /// Today's cost ÷ 30-day daily average — an anomaly/spike signal.
    let today_vs_avg_ratio: Double?
    /// Exactly 30 items, oldest → newest, zero-filled for inactive days.
    let daily: [DailyUsage]
}

struct LimitWindow: Codable, Sendable, Identifiable {
    /// A live reading older than this stops being "live" — the single source of
    /// that bound for every surface (age note, forecast note, the store's own
    /// staleness check), so they can't silently disagree about what "fresh" means.
    static let liveStaleAfter: TimeInterval = 60 * 60

    let label: String
    let used_percent: Double
    let window_minutes: Int
    let resets_at_unix: Int64?
    let provenance: String
    /// When this reading was taken (protocol ≥ 1.20.0). `nil` = the source didn't
    /// say — treat as **unknown**, never as fresh.
    let captured_at_unix: Int64?
    var id: String { label }

    init(label: String, used_percent: Double, window_minutes: Int,
         resets_at_unix: Int64?, provenance: String, captured_at_unix: Int64? = nil) {
        self.label = label
        self.used_percent = used_percent
        self.window_minutes = window_minutes
        self.resets_at_unix = resets_at_unix
        self.provenance = provenance
        self.captured_at_unix = captured_at_unix
    }

    /// How old this reading is, or `nil` when the source didn't timestamp it.
    func age(now: Date = Date()) -> TimeInterval? {
        captured_at_unix.map { now.timeIntervalSince1970 - TimeInterval($0) }
    }

    /// True when this reading is old enough that presenting it as current would be
    /// a lie.
    ///
    /// `resets_at_unix` deliberately plays no part. It answers a different question
    /// and comes from the same possibly-stale reading — a weekly window's reset is
    /// days out, so a stale weekly % never looks expired. Age is the only guard
    /// that works. An untimestamped reading is NOT assumed fresh.
    func isStale(now: Date = Date(), staleAfter: TimeInterval) -> Bool {
        guard let age = age(now: now) else { return false }
        return age > staleAfter
    }
}

/// A provider's credit balance (protocol ≥ 1.7.0). Optional on the wire and
/// **never set by the portable core** (which stays offline): the macOS Swift
/// layer fills it after a user connects an API key, mirroring the live-limits
/// pattern. Every amount is optional so partial provider responses degrade
/// gracefully; `note` carries a human message when no numeric balance is
/// available (e.g. a provider whose key is stored but has no balance endpoint).
///
/// A custom `init(from:)` defaults `currency` to `"USD"` and treats every field
/// as decode-if-present, so a leaner/partial payload never fails to decode —
/// the same forward/backward-compatible posture used across this file. All
/// amounts are local list-price estimates, never billed figures.
struct ProviderBalance: Codable, Sendable, Equatable {
    let remaining_usd: Double?
    let used_usd: Double?
    let limit_usd: Double?
    let currency: String
    let note: String?

    init(
        remaining_usd: Double? = nil,
        used_usd: Double? = nil,
        limit_usd: Double? = nil,
        currency: String = "USD",
        note: String? = nil
    ) {
        self.remaining_usd = remaining_usd
        self.used_usd = used_usd
        self.limit_usd = limit_usd
        self.currency = currency
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case remaining_usd, used_usd, limit_usd, currency, note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        remaining_usd = try c.decodeIfPresent(Double.self, forKey: .remaining_usd)
        used_usd = try c.decodeIfPresent(Double.self, forKey: .used_usd)
        limit_usd = try c.decodeIfPresent(Double.self, forKey: .limit_usd)
        currency = (try c.decodeIfPresent(String.self, forKey: .currency)) ?? "USD"
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    /// True when there's at least one real dollar figure to show (vs. a
    /// note-only placeholder for a connected-but-not-yet-readable provider).
    var hasAmounts: Bool {
        remaining_usd != nil || used_usd != nil || limit_usd != nil
    }
}

struct ProviderUsage: Codable, Sendable, Identifiable {
    let provider: String
    let display_name: String
    let health: String
    let installed: Bool
    let authenticated: Bool
    let detected_version: String?
    let plan_hint: String?
    let windows: [SpendWindow]
    let models: [ModelUsage]
    let limits: [LimitWindow]
    let capabilities: [[String]]   // [[capability, state], …]
    let notes: [String]
    let analytics: ProviderAnalytics?   // nil for detection-only providers
    /// Credit balance (protocol ≥ 1.7.0). `nil` by default — the core never sets
    /// it; the Swift layer folds one in after the user connects an API key (see
    /// `replacingBalance`). Decodes to `nil` when the key is absent (the custom
    /// decoder below uses `decodeIfPresent`).
    let balance: ProviderBalance?
    var id: String { provider }

    func window(_ label: String) -> SpendWindow? { windows.first { $0.label == label } }
    var today: SpendWindow? { window("today") }
    var last30: SpendWindow? { window("last_30_days") }

    /// Returns a copy with `limits` replaced. Used to fold provider-reported
    /// live limits into an otherwise-immutable snapshot without touching the
    /// decoder (the synthesized memberwise init is still available in-module
    /// because this type defines no custom `init`).
    func replacingLimits(_ newLimits: [LimitWindow]) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            display_name: display_name,
            health: health,
            installed: installed,
            authenticated: authenticated,
            detected_version: detected_version,
            plan_hint: plan_hint,
            windows: windows,
            models: models,
            limits: newLimits,
            capabilities: capabilities,
            notes: notes,
            analytics: analytics,
            balance: balance
        )
    }

    /// Returns a copy with `balance` replaced (everything else preserved). Used
    /// to fold a BYOK-fetched credit balance into an otherwise-immutable snapshot
    /// without touching the decoder — the same rebuild approach as
    /// `replacingLimits`, and relying on the same in-module synthesized
    /// memberwise init (this type defines no custom `init`).
    func replacingBalance(_ newBalance: ProviderBalance?) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            display_name: display_name,
            health: health,
            installed: installed,
            authenticated: authenticated,
            detected_version: detected_version,
            plan_hint: plan_hint,
            windows: windows,
            models: models,
            limits: limits,
            capabilities: capabilities,
            notes: notes,
            analytics: analytics,
            balance: newBalance
        )
    }

    /// True when the provider has real usage data (not just a detection state).
    var hasUsageData: Bool {
        !models.isEmpty || !limits.isEmpty || (last30?.records ?? 0) > 0
    }

    /// True when the core measured real token/cost usage **locally** (Claude,
    /// Codex). False for providers whose accounting happens server-side.
    ///
    /// This lives on the model, not on a view, because it is a fact about the
    /// data rather than a rendering preference — and because the one surface
    /// that owned a private copy of it (the popover) was the only surface that
    /// rendered Antigravity honestly. Every other card showed `$0.00 · 0 tokens`
    /// for a provider that had simply never reported tokens locally.
    var hasLocalSpend: Bool {
        let tokens = (today?.tokens.grandTotal ?? 0) + (last30?.tokens.grandTotal ?? 0)
        let cost = (today?.estimated_cost_usd ?? 0) + (last30?.estimated_cost_usd ?? 0)
        return tokens > 0 || cost > 0
    }

    /// True when there is local activity to show even without token accounting
    /// (e.g. Antigravity conversation counts).
    var hasLocalActivity: Bool {
        (last30?.records ?? 0) > 0 || (today?.records ?? 0) > 0
    }

    /// A detected provider that reports activity but whose tokens and dollars are
    /// accounted for server-side. Such a provider must **never** be given a spend
    /// row: `$0.00` would read as "you spent nothing", when the truth is "this
    /// number was never published to your Mac". Absence of evidence, reported as
    /// absence — not as zero.
    var isActivityOnly: Bool { installed && !hasLocalSpend && hasLocalActivity }

    /// Two-letter code for the compact menu-bar readout.
    var shortCode: String {
        switch provider {
        case "claude": return "Cl"
        case "codex": return "Cx"
        case "copilot": return "Co"
        case "cursor": return "Cu"
        case "antigravity": return "Ag"
        case "devin": return "Dv"
        case "grok": return "Gk"
        case "open_code": return "Oc"
        case "open_router": return "Or"
        case "zai": return "Za"
        case "gemini": return "Ge"
        default: return String(display_name.prefix(2))
        }
    }

    /// A small SF Symbol standing in for this provider in tight spots (the menu
    /// bar), where a two-letter code reads as noise — "Cl" is routinely misread as
    /// "CI".
    ///
    /// These are deliberately *evocative*, not brand marks: a cursor for Cursor, a
    /// terminal for OpenCode, a branch for OpenRouter. Shipping the vendors' actual
    /// logos would put trademarked artwork in the binary, which `NOTICE` is careful
    /// to avoid. Callers fall back to ``shortCode`` when a symbol is unavailable on
    /// the running OS.
    var symbolName: String {
        switch provider {
        case "claude": return "staroflife.fill"                        // Anthropic's burst
        case "codex": return "circle.hexagongrid.fill"                 // OpenAI's knot
        case "copilot": return "chevron.left.forwardslash.chevron.right"
        case "cursor": return "cursorarrow"
        case "antigravity": return "arrow.up.circle.fill"              // anti-gravity
        case "devin": return "hammer.fill"
        case "grok": return "bolt.fill"
        case "open_code": return "terminal.fill"
        case "open_router": return "arrow.triangle.branch"             // a router
        case "zai": return "z.circle.fill"                             // the brand IS "Z"
        case "gemini": return "sparkles"
        default: return "cpu"
        }
    }
}

extension ProviderUsage {
    /// Defensive decoder: a leaner or future core that omits one of the collection
    /// fields for a provider degrades **that provider** to "no data for that
    /// dimension" instead of throwing and failing the ENTIRE snapshot to "No data".
    ///
    /// This is the one collection type that lacked such tolerance — every sibling
    /// (`Project`, `Worktree`, `Checkpoint`, …) already defaults its arrays. It is
    /// safe here, and specifically NOT the mistake `SchemaCanary` warns against:
    /// an empty `windows`/`models`/`limits` is a *truthful absence* (this provider
    /// reported nothing), whereas a defaulted canary `status` would be a *false
    /// claim of health*. The load-bearing scalars — the provider id and its
    /// detection state — stay required, because a provider without them is
    /// genuinely malformed, not merely leaner.
    ///
    /// Declared in an extension so the memberwise initializer (used by
    /// `replacingLimits` / `replacingBalance` / `copy`) is still synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        display_name = try c.decode(String.self, forKey: .display_name)
        health = try c.decode(String.self, forKey: .health)
        installed = try c.decode(Bool.self, forKey: .installed)
        authenticated = try c.decode(Bool.self, forKey: .authenticated)
        detected_version = try c.decodeIfPresent(String.self, forKey: .detected_version)
        plan_hint = try c.decodeIfPresent(String.self, forKey: .plan_hint)
        windows = (try? c.decodeIfPresent([SpendWindow].self, forKey: .windows) ?? nil) ?? []
        models = (try? c.decodeIfPresent([ModelUsage].self, forKey: .models) ?? nil) ?? []
        limits = (try? c.decodeIfPresent([LimitWindow].self, forKey: .limits) ?? nil) ?? []
        capabilities = (try? c.decodeIfPresent([[String]].self, forKey: .capabilities) ?? nil) ?? []
        notes = (try? c.decodeIfPresent([String].self, forKey: .notes) ?? nil) ?? []
        analytics = try? c.decodeIfPresent(ProviderAnalytics.self, forKey: .analytics) ?? nil
        balance = try? c.decodeIfPresent(ProviderBalance.self, forKey: .balance) ?? nil
    }

    private enum CodingKeys: String, CodingKey {
        case provider, display_name, health, installed, authenticated
        case detected_version, plan_hint, windows, models, limits
        case capabilities, notes, analytics, balance
    }
}

/// A needs-attention item the core surfaces in the snapshot (protocol ≥ 1.2.0).
///
/// `severity` (`info|warning|critical`) and `kind`
/// (`usage_threshold|limit_reset_soon|integration_issue|spend_anomaly|other`)
/// are decoded as `String` and interpreted in the view layer, so a newer core
/// that adds a variant never breaks decoding. The array arrives **most severe
/// first** and may be empty (the common "all clear" case).
struct Alert: Codable, Sendable, Identifiable {
    let id: String
    let provider: String
    let severity: String
    let kind: String
    let title: String
    let detail: String
    let created_at_unix: Int64

    /// When the core raised this alert.
    var createdAt: Date { Date(timeIntervalSince1970: TimeInterval(created_at_unix)) }
}

/// A derived, actionable insight the core surfaces in the snapshot (protocol ≥ 1.8.0).
///
/// Unlike an ``Alert`` (a needs-attention condition), an insight is an observation
/// or recommendation — efficiency, cost, idle resources, a stalled session. The
/// array arrives **most-useful first** and may be empty. `impact` (`low|medium|
/// high`) and `kind` are decoded as `String` and interpreted in the view layer, so
/// a newer core that adds a variant never breaks decoding. `provider` and `metric`
/// are optional (decode-if-present), matching the core's `#[serde(default)]`.
struct Insight: Codable, Sendable, Identifiable {
    let id: String
    let impact: String
    let kind: String
    let provider: String?
    let title: String
    let detail: String
    let metric: String?
    let created_at_unix: Int64

    /// When the core generated this insight.
    var createdAt: Date { Date(timeIntervalSince1970: TimeInterval(created_at_unix)) }
}

/// An observed AI coding session the core surfaces in each snapshot (protocol ≥ 1.5.0).
///
/// `status` (`active|idle|recent|stalled|unknown`) is decoded as `String` and
/// interpreted in the view layer (see ``MissionStatus``) so a newer core that
/// adds a state never breaks decoding. Every field beyond `provider`,
/// `session_id`, and `status` may be null. The array arrives **most-recently-
/// active first** and is often empty (no coding sessions in the recent window).
/// A scope-guard flag on a mission: a risk category (`kind`) and the changed
/// files that triggered it (protocol ≥ 1.12.0). `kind`/`severity` are strings so
/// a newer core adding a variant never breaks decoding.
struct ScopeFlag: Codable, Sendable, Identifiable {
    let kind: String       // secrets | migrations | security | dependencies | lockfile | build_config | tests | other
    let severity: String   // info | notable | high
    let label: String
    /// A capped SAMPLE of the matching files — never the whole set. Use
    /// ``matchedFileCount`` for how many there were.
    let files: [String]
    /// How many files matched (protocol 1.17.0). `0` means the core didn't say.
    private let match_count: Int

    var id: String { kind }

    /// How many files this flag actually matched.
    ///
    /// `files` is capped at 8 by the core, so counting it under-reports: a session
    /// touching 40 auth files rendered "Security / auth code · 8". Falls back to
    /// the sample's length when the core didn't report a count (pre-1.17.0), which
    /// is the old floor — never worse than before, and honest above the cap.
    var matchedFileCount: Int { match_count > 0 ? match_count : files.count }

    /// True when `files` lists fewer than matched, so the UI can say "showing 8 of
    /// 40" instead of implying the list is complete.
    var filesAreSampled: Bool { matchedFileCount > files.count }

    private enum CodingKeys: String, CodingKey { case kind, severity, label, files, match_count }

    init(kind: String, severity: String, label: String, files: [String], match_count: Int = 0) {
        self.kind = kind
        self.severity = severity
        self.label = label
        self.files = files
        self.match_count = match_count
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "other"
        severity = (try? c.decode(String.self, forKey: .severity)) ?? "info"
        label = (try? c.decode(String.self, forKey: .label)) ?? "Change"
        files = ((try? c.decodeIfPresent([String].self, forKey: .files)) ?? nil) ?? []
        match_count = ((try? c.decodeIfPresent(Int.self, forKey: .match_count)) ?? nil) ?? 0
    }
}

struct Mission: Codable, Sendable, Identifiable {
    let provider: String
    let session_id: String
    let status: String
    let project_path: String?
    let project_name: String?
    let branch: String?
    let model: String?
    let started_at_unix: Int64?
    let last_activity_unix: Int64?
    let message_count: Int?
    let last_activity: String?
    let tokens_last_hour: UInt64?
    /// Files changed in the mission's project (relative paths, from `git status`),
    /// most-recently-changed first (protocol ≥ 1.10.0). Optional for decode
    /// robustness; use `changedFiles` for a non-nil array.
    let changed_files: [String]?
    /// A short local preview of the session's latest message/turn (protocol ≥ 1.10.0).
    let last_message_preview: String?
    /// Scope-guard flags: risk categories among the changed files (protocol ≥ 1.12.0).
    let scope_flags: [ScopeFlag]?

    /// The changed files as a non-nil array.
    var changedFiles: [String] { changed_files ?? [] }

    /// Scope-guard flags as a non-nil array (most-severe first, per the core).
    var scopeFlags: [ScopeFlag] { scope_flags ?? [] }

    /// Stable across a snapshot (provider-scoped so two providers can't collide).
    var id: String { provider + "\u{1}" + session_id }

    /// When the session last did something (nil when the core omitted it).
    var lastActivityAt: Date? {
        last_activity_unix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// When the session began (nil when the core omitted it).
    var startedAt: Date? {
        started_at_unix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// A friendly project label — the name, else the last path component, else the
    /// provider — so a card always has something readable to show.
    var projectLabel: String {
        if let name = project_name, !name.isEmpty { return name }
        if let path = project_path, !path.isEmpty { return (path as NSString).lastPathComponent }
        return providerDisplay
    }

    /// A human provider name for known ids, capitalized otherwise. Kept here (not
    /// resolved from the snapshot) so a mission row is self-contained and reusable.
    var providerDisplay: String {
        switch provider {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "copilot": return "Copilot"
        case "cursor": return "Cursor"
        case "antigravity": return "Antigravity"
        case "devin": return "Devin"
        case "grok": return "Grok"
        case "open_code": return "OpenCode"
        case "open_router": return "OpenRouter"
        case "zai": return "Z.ai"
        case "gemini": return "Gemini"
        default: return provider.capitalized
        }
    }
}

// MARK: - Schema canaries (protocol ≥ 1.18.0)

/// A model observed in real local logs that the core's pricing table can't price.
///
/// Its tokens **are** counted; its cost is omitted entirely, because the core
/// refuses to guess a rate it doesn't know. That silence is the point of
/// reporting it: a new model family can quietly vanish from every cost estimate
/// in the app while still inflating the token totals next to it.
///
/// Never render a dollar figure for one — not even `$0`. "$0" reads as "this was
/// free"; the truth is "we have no idea what this cost". The honest statement is
/// *counted in token totals, excluded from cost estimates*.
struct UnpricedModel: Codable, Sendable, Identifiable {
    /// The model id exactly as the logs record it.
    let model: String
    /// How many usage records named it, in the window scanned.
    let records: UInt64
    /// Tokens attributed to it — counted, but contributing zero cost.
    let tokens: TokenTotals

    var id: String { model }
}

/// One provider's check that the local data we read still looks like something
/// this core version actually understands (protocol ≥ 1.18.0).
///
/// `provider` and `status` are decoded as plain `String`s — the same open-enum
/// posture as ``ProviderUsage``/``Mission`` — and interpreted in the view layer
/// (see `CanaryState`), so a status a newer core invents **displays as unknown**
/// rather than breaking decoding or, far worse, being coerced into `ok`.
struct SchemaCanary: Codable, Sendable, Identifiable {
    let provider: String
    /// `ok | drifted | no_data | unknown` on the wire. Interpreted, never trusted
    /// as a raw label. Note `no_data` is explicitly **not** `ok`: it means there
    /// was nothing to verify, which is not the same as having verified something.
    let status: String
    let checked_at_unix: Int64
    /// Plain-language statement of what was observed, in the user's terms — the
    /// core guarantees it is safe to show verbatim (never a path or a stack trace).
    let detail: String
    /// Log files considered in this check.
    let files_seen: UInt64
    /// Usage records successfully parsed out of them.
    let records_parsed: UInt64
    /// Models found whose cost can't be estimated, worst (most tokens) first.
    let unpriced_models: [UnpricedModel]

    var id: String { provider }

    /// When the core ran this check.
    var checkedAt: Date { Date(timeIntervalSince1970: TimeInterval(checked_at_unix)) }

    private enum CodingKeys: String, CodingKey {
        case provider, status, checked_at_unix, detail
        case files_seen, records_parsed, unpriced_models
    }

    init(
        provider: String,
        status: String,
        checked_at_unix: Int64,
        detail: String,
        files_seen: UInt64 = 0,
        records_parsed: UInt64 = 0,
        unpriced_models: [UnpricedModel] = []
    ) {
        self.provider = provider
        self.status = status
        self.checked_at_unix = checked_at_unix
        self.detail = detail
        self.files_seen = files_seen
        self.records_parsed = records_parsed
        self.unpriced_models = unpriced_models
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Every field below is REQUIRED, deliberately — each is non-optional in the
        // core's own struct, so a payload missing one is not a canary, it's
        // something else wearing the shape of one.
        //
        // Do NOT "harden" this by giving them defaults. ``RadarReport`` at the
        // bottom of this file documents what that costs: when every field had a
        // default, the decoder could not fail, so a core *error* response decoded
        // into a perfectly valid empty result and the UI rendered a confident green
        // "all clear" for a scan that never ran.
        //
        // A canary is the worst possible place to repeat that. Its entire job is to
        // say "these numbers are incomplete". A defaulted `status` would let an
        // unreadable canary claim `ok` — the exact lie this type exists to prevent.
        // Throwing here instead means the snapshot reports no canaries at all, and
        // "nothing was checked" is a state the UI names out loud rather than
        // dressing up as reassurance.
        provider = try c.decode(String.self, forKey: .provider)
        status = try c.decode(String.self, forKey: .status)
        checked_at_unix = try c.decode(Int64.self, forKey: .checked_at_unix)
        detail = try c.decode(String.self, forKey: .detail)
        files_seen = try c.decode(UInt64.self, forKey: .files_seen)
        records_parsed = try c.decode(UInt64.self, forKey: .records_parsed)
        // The one genuinely additive field (`#[serde(default)]` in the core):
        // absent ⇒ no unpriced models, which is a real and common answer.
        unpriced_models = ((try? c.decodeIfPresent([UnpricedModel].self, forKey: .unpriced_models)) ?? nil) ?? []
    }
}

struct UsageSnapshot: Codable, Sendable {
    let protocol_version: SPVersion
    let core_version: String
    let generated_at_unix: Int64
    let bucket_date_utc: String
    let providers: [ProviderUsage]
    let pricing_note: String
    /// Needs-attention items, most severe first. Defaults to `[]` when a core
    /// older than protocol 1.2.0 omits the key (forward/backward compatible).
    let alerts: [Alert]
    /// Observed AI coding sessions, most-recently-active first (protocol ≥ 1.5.0).
    /// Defaults to `[]` when an older core omits the key, and is commonly empty.
    let missions: [Mission]
    /// Derived insights (efficiency/cost/idle observations), most-useful first
    /// (protocol ≥ 1.8.0). Defaults to `[]` when an older core omits the key.
    let insights: [Insight]
    /// Per-provider checks that what we read still matches what we understand,
    /// worst status first (protocol ≥ 1.18.0).
    ///
    /// Read this before trusting the totals above: a `drifted` canary means the
    /// numbers in this very snapshot are knowably incomplete. Defaults to `[]`
    /// when an older core omits the key — and `[]` means **"nothing was
    /// checked"**, never "everything checked out". The two are not the same
    /// claim, and only one of them is ours to make.
    let canaries: [SchemaCanary]

    private enum CodingKeys: String, CodingKey {
        case protocol_version, core_version, generated_at_unix
        case bucket_date_utc, providers, pricing_note, alerts, missions, insights
        case canaries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocol_version = try c.decode(SPVersion.self, forKey: .protocol_version)
        core_version = try c.decode(String.self, forKey: .core_version)
        generated_at_unix = try c.decode(Int64.self, forKey: .generated_at_unix)
        bucket_date_utc = try c.decode(String.self, forKey: .bucket_date_utc)
        providers = try c.decode([ProviderUsage].self, forKey: .providers)
        pricing_note = try c.decode(String.self, forKey: .pricing_note)
        // Absent (older core) or explicit null → empty, never a decode failure.
        // Element-tolerant, not all-or-nothing. The previous `try?` swallowed the
        // WHOLE array on a single malformed element — for alerts that turns one bad
        // field into an empty inbox, which the bell renders as "all clear": a decode
        // error dressed as a clean bill of health, the exact failure this app
        // refuses. Decoding element-by-element keeps every alert we CAN read and
        // drops only the unreadable one, so a real alert is never hidden by a
        // sibling's bad field.
        alerts = c.decodeLossyArray(Alert.self, forKey: .alerts)
        missions = c.decodeLossyArray(Mission.self, forKey: .missions)
        insights = c.decodeLossyArray(Insight.self, forKey: .insights)
        // Absent (pre-1.18.0 core) ⇒ this core runs no schema checks. That is a
        // real, honest answer and the UI says so; it is NOT an all-clear, and
        // nothing downstream may read it as one.
        canaries = ((try? c.decodeIfPresent([SchemaCanary].self, forKey: .canaries)) ?? nil) ?? []
    }

    /// Explicit memberwise initializer. The custom `init(from:)` above suppresses
    /// the synthesized one, so this is provided so the store can rebuild a
    /// snapshot after merging live limits (see `copy(providers:)`).
    init(
        protocol_version: SPVersion,
        core_version: String,
        generated_at_unix: Int64,
        bucket_date_utc: String,
        providers: [ProviderUsage],
        pricing_note: String,
        alerts: [Alert],
        missions: [Mission],
        insights: [Insight],
        canaries: [SchemaCanary]
    ) {
        self.protocol_version = protocol_version
        self.core_version = core_version
        self.generated_at_unix = generated_at_unix
        self.bucket_date_utc = bucket_date_utc
        self.providers = providers
        self.pricing_note = pricing_note
        self.alerts = alerts
        self.missions = missions
        self.insights = insights
        self.canaries = canaries
    }

    /// Returns a copy with `providers` replaced (everything else preserved).
    /// Lets the store rebuild the published snapshot with merged live limits
    /// without re-scanning the core or fighting the custom decoder.
    ///
    /// Note `canaries` is carried across explicitly, like every other field. The
    /// memberwise init above deliberately gives it no default: this rebuild runs
    /// on every live-limits and BYOK-balance merge, so a forgotten field here
    /// would silently erase the snapshot's own "these numbers are incomplete"
    /// disclosure moments after it arrived. A compile error is the cheaper bug.
    func copy(providers newProviders: [ProviderUsage]) -> UsageSnapshot {
        UsageSnapshot(
            protocol_version: protocol_version,
            core_version: core_version,
            generated_at_unix: generated_at_unix,
            bucket_date_utc: bucket_date_utc,
            providers: newProviders,
            pricing_note: pricing_note,
            alerts: alerts,
            missions: missions,
            insights: insights,
            canaries: canaries
        )
    }
}

// MARK: - Projects & discovered commands (protocol ≥ 1.4.0)

// The Rust core's project discovery. As with the usage types, string-valued
// enums (`safety`, `source`) are decoded as `String` and interpreted in the view
// layer so a newer core that adds a variant never breaks decoding. Arrays are
// decoded defensively (missing key → empty) for the same forward-compat reason.

/// One runnable command the core discovered for a project.
struct DiscoveredCommand: Codable, Sendable, Identifiable, Equatable {
    let label: String
    let command: String
    let cwd: String
    let source: String
    let safety: String
    let confidence: Double
    let raw_key: String?

    /// Stable within a project's command list (cwd + the literal command).
    var id: String { cwd + "\u{1}" + command }
}

/// A project the core found under an approved root, with its discovered commands.
struct Project: Codable, Sendable, Identifiable, Equatable {
    let name: String
    let path: String
    let markers: [String]
    let frameworks: [String]
    let package_manager: String?
    let git_branch: String?
    let git_remote: String?
    let last_modified_unix: Int64?
    let commands: [DiscoveredCommand]
    let warnings: [String]

    var id: String { path }

    private enum CodingKeys: String, CodingKey {
        case name, path, markers, frameworks, package_manager
        case git_branch, git_remote, last_modified_unix, commands, warnings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        // Absent arrays (older/leaner core) decode to empty, never a failure.
        markers = ((try? c.decodeIfPresent([String].self, forKey: .markers)) ?? nil) ?? []
        frameworks = ((try? c.decodeIfPresent([String].self, forKey: .frameworks)) ?? nil) ?? []
        package_manager = try c.decodeIfPresent(String.self, forKey: .package_manager)
        git_branch = try c.decodeIfPresent(String.self, forKey: .git_branch)
        git_remote = try c.decodeIfPresent(String.self, forKey: .git_remote)
        last_modified_unix = try c.decodeIfPresent(Int64.self, forKey: .last_modified_unix)
        commands = ((try? c.decodeIfPresent([DiscoveredCommand].self, forKey: .commands)) ?? nil) ?? []
        warnings = ((try? c.decodeIfPresent([String].self, forKey: .warnings)) ?? nil) ?? []
    }

    /// The command to wire to a project's prominent "Test Project" action: the one
    /// explicitly labelled "Test", else the first read-only command that looks
    /// test-ish, else any read-only command. `nil` when nothing safe fits.
    var testCommand: DiscoveredCommand? {
        if let exact = commands.first(where: { $0.label.caseInsensitiveCompare("Test") == .orderedSame }) {
            return exact
        }
        let readOnly = commands.filter { $0.safety == "read_only" }
        return readOnly.first(where: {
            $0.label.lowercased().contains("test") || $0.command.lowercased().contains("test")
        }) ?? readOnly.first
    }

    var lastModified: Date? {
        last_modified_unix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

// MARK: - Usage history (protocol ≥ 1.6.0)

/// One persisted day of usage for a provider. The core's durable history store
/// accumulates these beyond the ~30 days available in raw logs (seeded from the
/// 30-day analytics on first run, then grown on every refresh), so the Trends UI
/// can look back months. `provider` is a `String` for the same forward-compat
/// reason as ``ProviderUsage`` — a newer core adding a provider id never breaks
/// decoding. Costs remain local list-price estimates, never billed amounts.
///
/// `estimated_cost_usd` is optional and decodes to `nil` when the key is absent
/// (the synthesized decoder treats optionals as decode-if-present), matching the
/// core's `#[serde(default)]`.
struct HistoryPoint: Codable, Sendable, Identifiable {
    /// UTC calendar day, `YYYY-MM-DD`.
    let date: String
    let provider: String
    let tokens: TokenTotals
    let estimated_cost_usd: Double?
    let records: UInt64

    /// Stable per (date, provider) so two providers on the same day never collide.
    var id: String { date + "\u{1}" + provider }
}

// MARK: - Stack Health (protocol ≥ 1.9.0)

// The Rust core serializes every field (serde `default` only affects decoding),
// so simple synthesized `Codable` is sufficient here — no custom decoders needed.
// String-valued enums (`status`, `severity`) are interpreted in the view layer so
// a newer core adding a variant never breaks decoding.

/// One security advisory affecting a dependency.
struct Advisory: Codable, Sendable, Identifiable {
    let id: String
    let severity: String   // low | moderate | high | critical | unknown
    let title: String
    let url: String?
    let affected_range: String?
}

/// One dependency in a project's manifest, with its update + security status.
struct Dependency: Codable, Sendable, Identifiable {
    let name: String
    let ecosystem: String
    let required: String?
    let installed: String?
    let latest: String?
    let status: String     // up_to_date | minor_behind | major_behind | deprecated | unknown | other
    let is_dev: Bool
    let advisories: [Advisory]

    /// Row identity — name-scoped, so the same package reads as "one dependency"
    /// across the UI regardless of which version a project resolved.
    var id: String { ecosystem + "\u{1}" + name }

    /// **Enrichment-cache identity — version-scoped.** Network enrichment holds a
    /// package's `latest` (version-independent) but also its **advisories**, which
    /// OSV answers *per version*. Caching that record by `id` (name only) let a
    /// project reuse a different project's advisories, queried at a different
    /// installed version — a false positive (a patched project shows a fixed
    /// advisory) or, worse, a false negative (a vulnerable project shows "0
    /// advisories" because a patched sibling was checked first). The cache key must
    /// therefore match what the record is actually *about*: this exact resolved
    /// version. Deps with no lockfile version fall back to sharing by name — their
    /// status is `unknown` and they carry no version-specific claim anyway.
    var enrichmentKey: String { id + "\u{1}" + (installed ?? "") }
}

/// Roll-up counts for a project's stack health.
struct StackSummary: Codable, Sendable {
    let total: Int
    let minor_behind: Int
    let major_behind: Int
    let deprecated: Int
    let vulnerable: Int
    let max_severity: String?
    let checked_updates: Bool
}

/// One project's dependency/stack health.
struct ProjectStack: Codable, Sendable, Identifiable {
    let name: String
    let path: String
    let ecosystem: String
    let package_manager: String?
    let summary: StackSummary
    let dependencies: [Dependency]
    let notes: [String]

    var id: String { path }
}

// MARK: - Services & runtime (protocol ≥ 1.9.0)

/// A locally-running dev server / service detected by its listening TCP port.
struct RunningService: Codable, Sendable, Identifiable {
    let pid: Int
    let port: Int
    let command: String
    let cwd: String?
    let project_path: String?
    let project_name: String?
    let kind: String?
    let url: String?

    var id: String { "\(pid)\u{1}\(port)" }
}

// MARK: - Worktrees (protocol ≥ 1.15.0)

/// A git worktree — a second working directory for the same repo on its own
/// branch, so an agent can work without touching your main checkout. Creating one
/// is additive; `remove_command` is reported by the core but never run by it
/// (removal deletes a directory, so the UI gates it).
struct Worktree: Codable, Sendable, Identifiable {
    let path: String
    let branch: String?
    let head: String?
    let is_main: Bool
    let is_locked: Bool
    let is_stackpulse: Bool
    let remove_command: String?

    var id: String { path }

    private enum CodingKeys: String, CodingKey {
        case path, branch, head, is_main, is_locked, is_stackpulse, remove_command
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        head = try c.decodeIfPresent(String.self, forKey: .head)
        is_main = (try? c.decode(Bool.self, forKey: .is_main)) ?? false
        is_locked = (try? c.decode(Bool.self, forKey: .is_locked)) ?? false
        is_stackpulse = (try? c.decode(Bool.self, forKey: .is_stackpulse)) ?? false
        remove_command = try c.decodeIfPresent(String.self, forKey: .remove_command)
    }

    /// Last path component — a friendly label.
    var name: String { (path as NSString).lastPathComponent }
    /// Short SHA for display.
    var shortHead: String { String((head ?? "").prefix(7)) }
}

// MARK: - Checkpoints (protocol ≥ 1.14.0)

/// A non-destructive snapshot of a project's uncommitted work (`git stash create`
/// + a `refs/stackpulse/` ref — the working tree, index and HEAD are untouched).
/// `restore_command` is reported by the core but never run by it; restoring is
/// gated behind an explicit confirmation in the UI.
struct Checkpoint: Codable, Sendable, Identifiable {
    let id: String
    let ref_name: String
    let label: String
    let project_path: String
    let branch: String?
    let created_at_unix: Int64
    /// Files whose uncommitted state the snapshot captured.
    ///
    /// Empty means "no files" ONLY when ``files_unknown`` is false — prefer
    /// ``filesAreKnownEmpty`` over `files.isEmpty` at any call site that renders
    /// a claim about what was captured.
    let files: [String]
    /// True when git wouldn't tell us what the snapshot captured (protocol ≥
    /// 1.18.0). Defaults to `false`, which is the pre-1.18.0 reading.
    ///
    /// Without this, `files: []` meant both "this snapshot touched nothing" and
    /// "git failed and we have no idea" — absence of evidence rendered as a
    /// confident empty answer.
    let files_unknown: Bool
    let restore_command: String

    private enum CodingKeys: String, CodingKey {
        case id, ref_name, label, project_path, branch, created_at_unix
        case files, files_unknown, restore_command
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ref_name = (try? c.decode(String.self, forKey: .ref_name)) ?? ""
        label = (try? c.decode(String.self, forKey: .label)) ?? "Checkpoint"
        project_path = (try? c.decode(String.self, forKey: .project_path)) ?? ""
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        created_at_unix = (try? c.decode(Int64.self, forKey: .created_at_unix)) ?? 0
        files = ((try? c.decodeIfPresent([String].self, forKey: .files)) ?? nil) ?? []
        // Additive since 1.18.0; absent ⇒ false, i.e. "the list is trustworthy",
        // which is exactly how every pre-1.18.0 snapshot was already being read.
        files_unknown = (try? c.decode(Bool.self, forKey: .files_unknown)) ?? false
        restore_command = (try? c.decode(String.self, forKey: .restore_command)) ?? ""
    }

    var createdAt: Date { Date(timeIntervalSince1970: TimeInterval(created_at_unix)) }
    /// Short SHA for display.
    var shortID: String { String(id.prefix(7)) }

    /// True only when the core positively reported that this snapshot captured no
    /// files — i.e. an empty list we can actually stand behind.
    ///
    /// Use this instead of `files.isEmpty` anywhere the UI states what a
    /// checkpoint holds: `files.isEmpty && files_unknown` is "we don't know", and
    /// showing that as "no files" tells the user their checkpoint is empty when it
    /// may hold all of their uncommitted work.
    var filesAreKnownEmpty: Bool { files.isEmpty && !files_unknown }
}

// MARK: - Project usage (protocol ≥ 1.13.0)

/// Local AI spend attributed to one project (grouped by the working directory in
/// the session logs). Costs are local list-price estimates, never billed amounts.
struct ProjectUsage: Codable, Sendable, Identifiable {
    let project_path: String
    let project_name: String
    let providers: [String]
    let windows: [SpendWindow]
    let last_activity_unix: Int64?

    var id: String { project_path }

    private enum CodingKeys: String, CodingKey {
        case project_path, project_name, providers, windows, last_activity_unix
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        project_path = try c.decode(String.self, forKey: .project_path)
        project_name = (try? c.decode(String.self, forKey: .project_name))
            ?? (project_path as NSString).lastPathComponent
        providers = ((try? c.decodeIfPresent([String].self, forKey: .providers)) ?? nil) ?? []
        windows = ((try? c.decodeIfPresent([SpendWindow].self, forKey: .windows)) ?? nil) ?? []
        last_activity_unix = try c.decodeIfPresent(Int64.self, forKey: .last_activity_unix)
    }

    func window(_ label: String) -> SpendWindow? { windows.first { $0.label == label } }
    var today: SpendWindow? { window("today") }
    var last30: SpendWindow? { window("last_30_days") }

    var lastActivityAt: Date? {
        last_activity_unix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

// MARK: - Repository Radar (protocol ≥ 1.11.0)

// String-valued enums (`category`, `effort`, `risk`) are interpreted in the view
// layer so a newer core adding a variant never breaks decoding.

/// One explainable, project-grounded recommendation from the Repository Radar.
struct Recommendation: Codable, Sendable, Identifiable {
    let id: String
    let category: String   // ai_context | hygiene | testing | git | setup | efficiency | tooling | security | other
    let title: String
    let detail: String
    let affected_projects: [String]
    let evidence: [String]
    let effort: String     // trivial | small | moderate
    let risk: String       // none | low | medium
    let recommend_change: Bool
    let priority: Int

    private enum CodingKeys: String, CodingKey {
        case id, category, title, detail, affected_projects, evidence
        case effort, risk, recommend_change, priority
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decode(String.self, forKey: .category)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decode(String.self, forKey: .detail)
        affected_projects = ((try? c.decodeIfPresent([String].self, forKey: .affected_projects)) ?? nil) ?? []
        evidence = ((try? c.decodeIfPresent([String].self, forKey: .evidence)) ?? nil) ?? []
        effort = (try? c.decode(String.self, forKey: .effort)) ?? "small"
        risk = (try? c.decode(String.self, forKey: .risk)) ?? "low"
        recommend_change = (try? c.decode(Bool.self, forKey: .recommend_change)) ?? true
        priority = (try? c.decode(Int.self, forKey: .priority)) ?? 0
    }
}

/// The Repository Radar's report over the approved roots.
struct RadarReport: Codable, Sendable {
    let generated_at_unix: Int64?
    let projects_scanned: Int
    let recommendations: [Recommendation]

    private enum CodingKeys: String, CodingKey {
        case generated_at_unix, projects_scanned, recommendations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generated_at_unix = try c.decodeIfPresent(Int64.self, forKey: .generated_at_unix)
        // These two are REQUIRED on purpose. When every field had a default, this
        // decoder could not fail — so a core *error* response
        // (`{"kind":"error","code":"permission_denied",…}`) decoded into a
        // perfectly valid empty report, and Discover rendered a green
        // "scanned 0 projects and found no obvious gaps — all clear" for a scan
        // that never happened. Failing here makes the bridge return nil and the
        // view keep its loading state, which is the truth.
        projects_scanned = try c.decode(Int.self, forKey: .projects_scanned)
        recommendations = try c.decode([Recommendation].self, forKey: .recommendations)
    }

    var generatedAt: Date? {
        generated_at_unix.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}
