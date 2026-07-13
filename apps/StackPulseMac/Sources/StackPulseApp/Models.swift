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
    let label: String
    let used_percent: Double
    let window_minutes: Int
    let resets_at_unix: Int64?
    let provenance: String
    var id: String { label }
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
    /// `replacingBalance`). Decodes to `nil` when the key is absent because this
    /// type has no custom `init(from:)`, so the synthesized decoder treats the
    /// optional as decode-if-present.
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

    private enum CodingKeys: String, CodingKey {
        case protocol_version, core_version, generated_at_unix
        case bucket_date_utc, providers, pricing_note, alerts, missions, insights
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
        alerts = ((try? c.decodeIfPresent([Alert].self, forKey: .alerts)) ?? nil) ?? []
        missions = ((try? c.decodeIfPresent([Mission].self, forKey: .missions)) ?? nil) ?? []
        insights = ((try? c.decodeIfPresent([Insight].self, forKey: .insights)) ?? nil) ?? []
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
        insights: [Insight]
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
    }

    /// Returns a copy with `providers` replaced (everything else preserved).
    /// Lets the store rebuild the published snapshot with merged live limits
    /// without re-scanning the core or fighting the custom decoder.
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
            insights: insights
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

    var id: String { ecosystem + "\u{1}" + name }
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
