//! # stackpulse-protocol
//!
//! Platform-neutral, versioned contracts shared across the StackPulse
//! ecosystem: the Rust core, the macOS app (via FFI), the future Chrome
//! native-messaging host, and the future Windows client.
//!
//! **Stability rule:** every breaking change to a type in this crate MUST bump
//! [`PROTOCOL_VERSION`] and be recorded in `docs/PROTOCOL.md` and
//! `docs/CROSS_REPO_CHANGELOG.md`. Additive, backward-compatible fields do not
//! require a major bump but should be `#[serde(default)]` so older peers keep
//! parsing newer payloads (forward compatibility).
//!
//! Nothing platform-specific (no paths, no macOS APIs) belongs here.

use serde::{Deserialize, Serialize};

/// Semantic version of the wire protocol. Independent of the app version, the
/// core version, and the compatibility-manifest version (see ADR-0006).
pub const PROTOCOL_VERSION: Version = Version {
    major: 1,
    minor: 14,
    patch: 0,
};

/// A simple semantic version usable in `const` contexts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Version {
    pub major: u16,
    pub minor: u16,
    pub patch: u16,
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

// ---------------------------------------------------------------------------
// Providers & capabilities
// ---------------------------------------------------------------------------

/// Stable identifier for a supported AI provider. Serialized as a lowercase
/// string so new providers can be added without breaking older readers
/// (`#[serde(other)]` catches unknown values as [`ProviderId::Unknown`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderId {
    Antigravity,
    Claude,
    Codex,
    Copilot,
    Cursor,
    Devin,
    Gemini,
    Grok,
    OpenCode,
    OpenRouter,
    Zai,
    #[serde(other)]
    Unknown,
}

impl ProviderId {
    /// Human-readable display name.
    pub fn display_name(self) -> &'static str {
        match self {
            ProviderId::Antigravity => "Antigravity",
            ProviderId::Claude => "Claude",
            ProviderId::Codex => "Codex",
            ProviderId::Copilot => "GitHub Copilot",
            ProviderId::Cursor => "Cursor",
            ProviderId::Devin => "Devin",
            ProviderId::Gemini => "Gemini",
            ProviderId::Grok => "Grok",
            ProviderId::OpenCode => "OpenCode",
            ProviderId::OpenRouter => "OpenRouter",
            ProviderId::Zai => "Z.ai",
            ProviderId::Unknown => "Unknown",
        }
    }
}

/// A single fine-grained capability. Integrations advertise a *matrix* of these
/// rather than one boolean "supported" flag (spec: capability-based
/// integrations). A capability the adapter cannot provide is reported as
/// [`CapabilityState::Unsupported`] — never faked.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Capability {
    InstalledAppDetection,
    VersionDetection,
    AuthDetection,
    SessionLimits,
    WeeklyLimits,
    CreditsAndSpend,
    LocalCostScan,
    ModelBreakdown,
    CacheMetrics,
    LocalSessionHistory,
    LiveTaskDetection,
    CompletionDetection,
    WaitingForInputDetection,
    ToolCallVisibility,
    ProjectAssociation,
    ConversationPreview,
    Reply,
    ApproveReject,
    Stop,
    Resume,
    DeepLink,
    RemoteTaskState,
}

/// Whether a given capability is actually available right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CapabilityState {
    /// Implemented and currently working.
    Supported,
    /// The adapter can do this in principle, but a precondition is missing
    /// (e.g. not authenticated, network required and offline).
    Unavailable,
    /// The provider does not expose this; do not pretend otherwise.
    Unsupported,
}

/// Health of an integration, mapped from the spec's integration-health states.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IntegrationHealth {
    FullySupported,
    PartiallySupported,
    AppVersionUntested,
    AuthenticationChanged,
    SessionSchemaChanged,
    EndpointChanged,
    MetricsUnavailable,
    TemporarilyBroken,
    Discontinued,
    UserActionRequired,
    /// Provider app / data not found on this machine.
    NotDetected,
}

// ---------------------------------------------------------------------------
// Value provenance (measured vs estimated) — spec requires honest labeling
// ---------------------------------------------------------------------------

/// How a numeric value was obtained. Surfaced in the UI so users never mistake
/// a heuristic estimate for a provider-reported fact.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Provenance {
    /// Directly measured from local logs (e.g. summed token counts).
    Measured,
    /// Reported by the provider's own API/state.
    ProviderReported,
    /// Locally calculated from measured inputs and a pricing table (an estimate).
    LocalEstimate,
    /// A heuristic suggestion, not a hard number.
    Heuristic,
}

// ---------------------------------------------------------------------------
// Usage model
// ---------------------------------------------------------------------------

/// Token counts, kept separate so cache economics are visible.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TokenTotals {
    pub input_tokens: u64,
    pub output_tokens: u64,
    /// Tokens written into the prompt cache (billed at a write rate).
    pub cache_creation_tokens: u64,
    /// Tokens served from the prompt cache (billed at a large discount).
    pub cache_read_tokens: u64,
    /// Reasoning tokens where the provider reports them separately (Codex).
    pub reasoning_tokens: u64,
}

impl TokenTotals {
    pub fn add(&mut self, other: &TokenTotals) {
        self.input_tokens += other.input_tokens;
        self.output_tokens += other.output_tokens;
        self.cache_creation_tokens += other.cache_creation_tokens;
        self.cache_read_tokens += other.cache_read_tokens;
        self.reasoning_tokens += other.reasoning_tokens;
    }

    /// Grand total of all token categories.
    pub fn grand_total(&self) -> u64 {
        self.input_tokens
            + self.output_tokens
            + self.cache_creation_tokens
            + self.cache_read_tokens
            + self.reasoning_tokens
    }

    /// Cache hit rate over cache-eligible input: read / (read + creation).
    /// Returns `None` when there was no cache activity.
    pub fn cache_hit_rate(&self) -> Option<f64> {
        let denom = (self.cache_read_tokens + self.cache_creation_tokens) as f64;
        if denom == 0.0 {
            None
        } else {
            Some(self.cache_read_tokens as f64 / denom)
        }
    }
}

/// Aggregated spend + tokens over a named window (today / yesterday / 30 days).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SpendWindow {
    /// Window label, e.g. "today", "yesterday", "last_30_days".
    pub label: String,
    pub tokens: TokenTotals,
    /// Estimated cost in USD. `None` when no priceable model was found.
    pub estimated_cost_usd: Option<f64>,
    /// Number of usage records (assistant turns) counted in this window.
    pub records: u64,
}

/// Per-model breakdown within a window.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ModelUsage {
    pub model: String,
    pub tokens: TokenTotals,
    pub estimated_cost_usd: Option<f64>,
    pub records: u64,
}

/// One day of usage, for daily-history charts (oldest → newest).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct DailyUsage {
    /// UTC date, `YYYY-MM-DD`.
    pub date: String,
    pub tokens: TokenTotals,
    pub estimated_cost_usd: Option<f64>,
    pub records: u64,
}

/// Derived efficiency analytics for a provider over the 30-day window. All
/// values are computed locally from measured tokens; costs use the same
/// estimate table as the spend windows (provenance `LocalEstimate`), while
/// token-based figures (savings) are `Measured`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ProviderAnalytics {
    /// USD saved by cache reads vs. paying the full input rate, over 30 days.
    /// `None` when no priceable cache activity was seen.
    pub cache_savings_usd: Option<f64>,
    /// Average estimated spend per active day over the 30-day window.
    pub burn_rate_usd_per_day: Option<f64>,
    /// Cache hit rate over the 30-day window (read / (read + creation)).
    pub cache_hit_rate: Option<f64>,
    /// Today's estimated cost as a multiple of the 30-day daily average
    /// (e.g. 2.5 ⇒ today is 2.5× the average). `None` when the average is 0.
    /// A value well above 1.0 is a spend anomaly worth surfacing.
    pub today_vs_avg_ratio: Option<f64>,
    /// Per-day history for the last 30 days (all days present, zeros filled),
    /// oldest → newest, for sparklines / bar charts.
    #[serde(default)]
    pub daily: Vec<DailyUsage>,
}

/// A live limit window reported by the provider (e.g. Codex 5-hour / weekly),
/// captured from local logs without any network call where possible.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LimitWindow {
    /// e.g. "5h", "weekly".
    pub label: String,
    /// 0.0–100.0 percent of the window consumed.
    pub used_percent: f64,
    pub window_minutes: u32,
    /// Unix seconds when the window resets, if known.
    pub resets_at_unix: Option<i64>,
    pub provenance: Provenance,
}

/// A live credit/balance reading for an API-key provider (OpenRouter, LiteLLM,
/// …). Populated by the client layer (BYOK key + provider API), not the portable
/// core — so the core stays offline. Always provider-reported. Since 1.7.0.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderBalance {
    /// Remaining credit/balance, if the provider reports it.
    #[serde(default)]
    pub remaining_usd: Option<f64>,
    /// Amount used/spent this period, if reported.
    #[serde(default)]
    pub used_usd: Option<f64>,
    /// Total granted/limit, if reported.
    #[serde(default)]
    pub limit_usd: Option<f64>,
    /// ISO currency code (typically "USD").
    pub currency: String,
    /// Optional short note (e.g. "pay-as-you-go", plan name).
    #[serde(default)]
    pub note: Option<String>,
}

/// Everything known about one provider at snapshot time.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderUsage {
    pub provider: ProviderId,
    pub display_name: String,
    pub health: IntegrationHealth,
    /// True if the provider's app/CLI/data was detected on this machine.
    pub installed: bool,
    /// True if credentials were detected (presence only — never the secret).
    pub authenticated: bool,
    /// Detected app/CLI version string, if any.
    #[serde(default)]
    pub detected_version: Option<String>,
    /// Subscription plan hint, if the logs reveal one (e.g. "plus", "pro").
    #[serde(default)]
    pub plan_hint: Option<String>,
    /// Spend windows (today / yesterday / last 30 days).
    #[serde(default)]
    pub windows: Vec<SpendWindow>,
    /// Per-model breakdown for the last 30 days.
    #[serde(default)]
    pub models: Vec<ModelUsage>,
    /// Live limit windows captured from local data, if available.
    #[serde(default)]
    pub limits: Vec<LimitWindow>,
    /// Capability matrix: (capability, state) pairs.
    #[serde(default)]
    pub capabilities: Vec<(Capability, CapabilityState)>,
    /// Non-fatal notes for this provider (e.g. "no priceable models found").
    #[serde(default)]
    pub notes: Vec<String>,
    /// Derived efficiency analytics (cache savings, burn rate, daily history).
    /// `None` for detection-only providers with no measured usage. Additive
    /// since protocol 1.1.0 — older readers ignore it.
    #[serde(default)]
    pub analytics: Option<ProviderAnalytics>,
    /// Live credit/balance for an API-key provider, filled by the client layer
    /// (the portable core always emits `None`). Additive since protocol 1.7.0.
    #[serde(default)]
    pub balance: Option<ProviderBalance>,
}

// ---------------------------------------------------------------------------
// Alerts (needs-attention) — since 1.2.0
// ---------------------------------------------------------------------------

/// Severity of an alert. Drives ordering and menu-bar badge color.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AlertSeverity {
    Info,
    Warning,
    Critical,
}

/// The category of a needs-attention alert. Open enum: unknown values decode as
/// [`AlertKind::Other`] so newer cores don't break older readers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AlertKind {
    /// A live limit window crossed a usage threshold.
    UsageThreshold,
    /// A live limit window resets soon.
    LimitResetSoon,
    /// A provider integration is degraded / needs user action.
    IntegrationIssue,
    /// Today's spend is anomalously high vs. the 30-day average.
    SpendAnomaly,
    #[serde(other)]
    Other,
}

/// A single needs-attention item derived from a snapshot. Alerts are computed
/// locally by the core from the same scan (no network); the UI renders them in a
/// menu-bar badge, the popover, and a Needs-Attention inbox.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Alert {
    /// Stable key (provider + kind + discriminator) for dedup / acknowledgement.
    pub id: String,
    pub provider: ProviderId,
    pub severity: AlertSeverity,
    pub kind: AlertKind,
    /// Short headline, e.g. "Codex 5h limit at 96%".
    pub title: String,
    /// One-line explanation with the concrete numbers.
    pub detail: String,
    /// Unix seconds the alert was generated (snapshot time).
    pub created_at_unix: i64,
}

// ---------------------------------------------------------------------------
// Insights (derived intelligence) — since 1.8.0
// ---------------------------------------------------------------------------

/// How much an insight matters — drives ordering and accent. Distinct from
/// [`AlertSeverity`]: insights are observations/recommendations, not
/// needs-attention conditions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InsightImpact {
    Low,
    Medium,
    High,
}

/// The category of a derived insight. Open enum: unknown values decode as
/// [`InsightKind::Other`] so newer cores don't break older readers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InsightKind {
    /// A low cache-read fraction is leaving measurable savings unclaimed.
    LowCacheEfficiency,
    /// Today's spend is notably above the 30-day average.
    SpendAnomaly,
    /// A live/limit window is trending toward its cap.
    ApproachingLimit,
    /// A detected provider has had no usage in the trailing window.
    IdleProvider,
    /// Spend is concentrated in one expensive model.
    CostConcentration,
    /// An AI coding session appears stalled (idle mid-task).
    StalledSession,
    #[serde(other)]
    Other,
}

/// A derived, actionable insight computed locally from a scan. Unlike an
/// [`Alert`], an insight is an observation or recommendation (efficiency, cost,
/// idle resources) rather than a needs-attention condition. Ranked most-useful
/// first by the core. All monetary figures are local list-price estimates.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Insight {
    /// Stable key (kind + provider + discriminator) for dedup / ordering.
    pub id: String,
    pub impact: InsightImpact,
    pub kind: InsightKind,
    /// The provider this insight is about, when applicable.
    #[serde(default)]
    pub provider: Option<ProviderId>,
    /// Short headline, e.g. "Low cache efficiency on Claude".
    pub title: String,
    /// One-line explanation with concrete numbers and a suggested action.
    pub detail: String,
    /// An optional highlighted figure, e.g. "$3.20 / 30d" or "42% cache".
    #[serde(default)]
    pub metric: Option<String>,
    /// Unix seconds the insight was generated (snapshot time).
    pub created_at_unix: i64,
}

// ---------------------------------------------------------------------------
// Agent Mission Control — since 1.5.0
// ---------------------------------------------------------------------------

/// Activity state of an observed AI coding session, from local logs only.
/// Open enum so a future core can add states (e.g. `waiting_for_input`) without
/// breaking older readers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MissionStatus {
    /// Meaningful output within the last few minutes — running right now.
    Active,
    /// Quiet for a few-to-30 minutes — paused or waiting.
    Idle,
    /// Last touched within a couple of hours — recently finished.
    Recent,
    /// Looks stuck (repeated output / no progress) — surfaced for the user to
    /// judge, never auto-acted upon.
    Stalled,
    #[serde(other)]
    Unknown,
}

/// One observed AI coding session, normalized into a mission. Derived purely
/// from local session logs — no network, no process control.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Mission {
    pub provider: ProviderId,
    pub session_id: String,
    pub status: MissionStatus,
    /// Absolute path of the project the session is working in, if known.
    #[serde(default)]
    pub project_path: Option<String>,
    #[serde(default)]
    pub project_name: Option<String>,
    #[serde(default)]
    pub branch: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    /// First-observed and most-recent activity, unix seconds.
    #[serde(default)]
    pub started_at_unix: Option<i64>,
    pub last_activity_unix: i64,
    /// Number of assistant turns / events observed in the session.
    pub message_count: u64,
    /// Short human summary of the latest activity (e.g. "editing file", "running
    /// tests"), best-effort from the last log event.
    #[serde(default)]
    pub last_activity: Option<String>,
    /// Tokens consumed in roughly the last hour — a velocity indicator.
    #[serde(default)]
    pub tokens_last_hour: u64,
    /// Files changed in the mission's project working tree (relative paths, from
    /// `git status`), most-recently-changed first, capped. Empty when not a git
    /// repo or nothing changed (protocol ≥ 1.10.0). Local only.
    #[serde(default)]
    pub changed_files: Vec<String>,
    /// A short, sanitized preview of the session's most recent message/turn — the
    /// user's own local content, truncated (protocol ≥ 1.10.0).
    #[serde(default)]
    pub last_message_preview: Option<String>,
    /// Scope-guard flags: risk categories detected among `changed_files` (touched
    /// secrets, migrations, dependencies, tests, security-sensitive files, …).
    /// Read-only heads-up, derived locally from the changed-file paths (protocol
    /// ≥ 1.12.0). Empty when nothing notable changed.
    #[serde(default)]
    pub scope_flags: Vec<ScopeFlag>,
}

// ---------------------------------------------------------------------------
// Scope Guard — since 1.12.0
// ---------------------------------------------------------------------------

/// The kind of change a scope-guard flag represents. Open enum for forward-compat
/// (the Swift layer reads the wire value as a string).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScopeFlagKind {
    /// Dependency manifests changed (package.json, Cargo.toml, …).
    Dependencies,
    /// Lockfiles changed (package-lock.json, Cargo.lock, …).
    Lockfile,
    /// Environment/secret files touched (.env, *.pem, credentials).
    Secrets,
    /// Database migrations or raw SQL touched.
    Migrations,
    /// Security-/auth-sensitive code touched.
    Security,
    /// Test files touched (added, changed, or removed).
    Tests,
    /// CI / build / tooling config touched.
    BuildConfig,
    /// Anything a newer core adds.
    #[serde(other)]
    Other,
}

/// How much attention a scope-guard flag warrants.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScopeSeverity {
    Info,
    Notable,
    High,
}

/// One scope-guard flag: a risk category and the changed files that triggered it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScopeFlag {
    pub kind: ScopeFlagKind,
    pub severity: ScopeSeverity,
    /// Short human label (e.g. "Secrets / env files").
    pub label: String,
    /// The changed files that matched, capped for payload size.
    #[serde(default)]
    pub files: Vec<String>,
}

/// The top-level object every UI surface renders. One scan → one snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageSnapshot {
    pub protocol_version: Version,
    pub core_version: String,
    /// Unix seconds the snapshot was produced (set by the core).
    pub generated_at_unix: i64,
    /// UTC date (YYYY-MM-DD) used to bucket the "today" window. Surfaced so the
    /// UI can disclose that windows are UTC-based in this version.
    pub bucket_date_utc: String,
    pub providers: Vec<ProviderUsage>,
    /// Needs-attention alerts derived from this scan, most severe first.
    /// Additive since protocol 1.2.0 — older readers ignore it.
    #[serde(default)]
    pub alerts: Vec<Alert>,
    /// Observed AI coding sessions (missions), most-recently-active first.
    /// Additive since protocol 1.5.0.
    #[serde(default)]
    pub missions: Vec<Mission>,
    /// Derived insights (efficiency/cost/idle observations), most useful first.
    /// Additive since protocol 1.8.0 — older readers ignore it.
    #[serde(default)]
    pub insights: Vec<Insight>,
    /// Pricing table provenance note, e.g. "embedded estimate, as of 2026-07".
    pub pricing_note: String,
}

// ---------------------------------------------------------------------------
// Project Navigator & Command Memory — since 1.4.0
// ---------------------------------------------------------------------------

/// Where a discovered command came from. Open enum for forward-compatibility.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CommandSource {
    PackageScript,
    Makefile,
    Justfile,
    Taskfile,
    ComposeService,
    Readme,
    FrameworkConvention,
    #[serde(other)]
    Other,
}

/// Safety classification for a command, so the UI can warn before running and
/// never auto-executes anything risky (spec: command safety categories).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CommandSafety {
    /// Reads only; safe to run (e.g. `--version`, lint, type-check, test).
    ReadOnly,
    /// Local development server / build; writes build artifacts.
    LocalDev,
    /// Modifies project files (formatters, codegen).
    ModifiesFiles,
    /// Installs dependencies.
    InstallsDeps,
    /// Touches a database (migrations, seeds).
    ChangesDatabase,
    /// Network / deployment / publish.
    Network,
    /// Destructive (clean, reset, force). Requires explicit confirmation.
    Destructive,
}

/// A normalized, actionable command discovered for a project.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DiscoveredCommand {
    /// Normalized action label, e.g. "Test", "Build", "Dev", "Lint".
    pub label: String,
    /// The exact command string to run.
    pub command: String,
    /// Working directory (absolute) the command should run in.
    pub cwd: String,
    pub source: CommandSource,
    pub safety: CommandSafety,
    /// 0.0–1.0 confidence that this is the right command for `label`.
    pub confidence: f64,
    /// Original script/target key (e.g. the npm script name), if any.
    #[serde(default)]
    pub raw_key: Option<String>,
}

/// A discovered project (a directory matching known project markers).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Project {
    pub name: String,
    /// Absolute path to the project root.
    pub path: String,
    /// Marker kinds found (e.g. "git", "node", "rust", "python", "docker").
    #[serde(default)]
    pub markers: Vec<String>,
    /// Detected frameworks (e.g. "next", "vite", "tailwind").
    #[serde(default)]
    pub frameworks: Vec<String>,
    /// Package manager, if determinable ("npm", "pnpm", "yarn", "bun", "cargo").
    #[serde(default)]
    pub package_manager: Option<String>,
    /// Current git branch, if a repo.
    #[serde(default)]
    pub git_branch: Option<String>,
    /// Git remote URL, if any.
    #[serde(default)]
    pub git_remote: Option<String>,
    /// Unix seconds of the most recent file modification observed at the root.
    #[serde(default)]
    pub last_modified_unix: Option<i64>,
    /// Discovered, normalized commands (test/build/dev/lint/…), most useful first.
    #[serde(default)]
    pub commands: Vec<DiscoveredCommand>,
    /// Organizational warnings (e.g. "no git remote", "nested repository").
    #[serde(default)]
    pub warnings: Vec<String>,
}

// ---------------------------------------------------------------------------
// Usage history — since 1.6.0
// ---------------------------------------------------------------------------

/// One persisted day of usage for a provider. The history store accumulates
/// these beyond the ~30 days available in raw logs, so trend charts can look
/// back months. Costs remain `LocalEstimate`s.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HistoryPoint {
    /// UTC date, `YYYY-MM-DD`.
    pub date: String,
    pub provider: ProviderId,
    pub tokens: TokenTotals,
    #[serde(default)]
    pub estimated_cost_usd: Option<f64>,
    pub records: u64,
}

// ---------------------------------------------------------------------------
// Stack Health — development intelligence (since 1.9.0)
// ---------------------------------------------------------------------------

/// How an installed dependency compares to the latest available version. Open
/// enum for forward-compat.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DependencyStatus {
    /// Installed version matches the latest.
    UpToDate,
    /// Only patch/minor releases behind (non-breaking by semver).
    MinorBehind,
    /// A major version behind (potentially breaking).
    MajorBehind,
    /// The package is marked deprecated by its registry.
    Deprecated,
    /// Latest version couldn't be determined (offline, unknown registry).
    Unknown,
    #[serde(other)]
    Other,
}

/// Severity of a security advisory affecting a dependency.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AdvisorySeverity {
    Low,
    Moderate,
    High,
    Critical,
    #[serde(other)]
    Unknown,
}

/// One known security advisory affecting a dependency (from OSV / a registry).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Advisory {
    /// Advisory id (e.g. a GHSA / CVE / OSV id).
    pub id: String,
    pub severity: AdvisorySeverity,
    pub title: String,
    #[serde(default)]
    pub url: Option<String>,
    /// Human range of affected versions, when known.
    #[serde(default)]
    pub affected_range: Option<String>,
}

/// One dependency in a project's manifest, with its update + security status.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Dependency {
    pub name: String,
    /// Ecosystem/registry: "npm", "cargo", "pypi", …
    pub ecosystem: String,
    /// The version/constraint from the manifest (e.g. "^1.2.0", "1.4.0").
    #[serde(default)]
    pub required: Option<String>,
    /// The concrete installed version from the lockfile, when resolvable.
    #[serde(default)]
    pub installed: Option<String>,
    /// The latest published version, when a registry check succeeded.
    #[serde(default)]
    pub latest: Option<String>,
    pub status: DependencyStatus,
    /// True for a dev/build-only dependency.
    #[serde(default)]
    pub is_dev: bool,
    /// Security advisories affecting the installed version.
    #[serde(default)]
    pub advisories: Vec<Advisory>,
}

/// Roll-up counts for a project's stack health.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct StackSummary {
    pub total: u32,
    pub minor_behind: u32,
    pub major_behind: u32,
    pub deprecated: u32,
    /// Dependencies with at least one advisory.
    pub vulnerable: u32,
    /// Highest advisory severity present anywhere, when any.
    #[serde(default)]
    pub max_severity: Option<AdvisorySeverity>,
    /// Whether latest-version data is from a live registry check (vs. an offline,
    /// local-only inventory).
    pub checked_updates: bool,
}

/// One project's dependency/stack health (since 1.9.0). Computed locally from the
/// project's manifests + lockfiles; `latest`/`advisories` come from official
/// registries + OSV when a network check is allowed (else a local-only inventory).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProjectStack {
    pub name: String,
    pub path: String,
    /// Primary ecosystem detected ("npm", "cargo", "pypi", …).
    pub ecosystem: String,
    #[serde(default)]
    pub package_manager: Option<String>,
    pub summary: StackSummary,
    /// Dependencies, most-actionable first (advisories, then major-behind, …).
    #[serde(default)]
    pub dependencies: Vec<Dependency>,
    /// Human notes (e.g. "no lockfile — versions are from ranges only").
    #[serde(default)]
    pub notes: Vec<String>,
}

// ---------------------------------------------------------------------------
// Services & runtime — running dev servers/ports (since 1.9.0)
// ---------------------------------------------------------------------------

/// A locally-running dev server / service detected by its listening TCP port
/// (since 1.9.0). Read-only detection; the app offers open-URL and a confirmed
/// stop, never silent process control.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunningService {
    pub pid: i32,
    pub port: u16,
    /// The process's command name / argv0 (e.g. "node", "vite", "next-server").
    pub command: String,
    /// Working directory of the process, when resolvable.
    #[serde(default)]
    pub cwd: Option<String>,
    /// The approved project this service belongs to, matched by `cwd`.
    #[serde(default)]
    pub project_path: Option<String>,
    #[serde(default)]
    pub project_name: Option<String>,
    /// Best-effort service kind ("vite", "next", "node", "python", "docker", …).
    #[serde(default)]
    pub kind: Option<String>,
    /// A localhost URL when the service looks like an HTTP dev server.
    #[serde(default)]
    pub url: Option<String>,
}

// ---------------------------------------------------------------------------
// Request / response envelopes (the FFI + native-messaging surface)
// ---------------------------------------------------------------------------

/// A request from a client (Swift app, native host, CLI) to the core.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum CoreRequest {
    /// Report core + protocol versions and a liveness ping.
    Ping,
    /// Produce a full usage snapshot by scanning local provider data.
    GetUsageSnapshot {
        /// If set, only scan these providers; otherwise scan all detected ones.
        #[serde(default)]
        providers: Option<Vec<ProviderId>>,
    },
    /// Lightweight detection only (installed / authenticated / health), no
    /// expensive log scanning. Cheap enough for frequent menu-bar polling.
    GetProviderStatus,
    /// Discover projects under the given (user-approved) root directories and
    /// their commands. The core only reads inside these roots (since 1.4.0).
    GetProjects {
        /// Absolute paths the user explicitly approved for scanning.
        roots: Vec<String>,
        /// Max directory depth to descend when searching for project roots.
        #[serde(default)]
        max_depth: Option<u32>,
    },
    /// Fold today's usage into the durable history store under `data_dir`
    /// (seeding from the 30-day analytics on first run), then return the
    /// accumulated history. `data_dir` is a client-provided writable directory.
    RecordHistory {
        data_dir: String,
        /// How many days of history to return (default all).
        #[serde(default)]
        days: Option<u32>,
    },
    /// Read the accumulated usage history from `data_dir` without recording.
    GetHistory {
        data_dir: String,
        #[serde(default)]
        days: Option<u32>,
    },
    /// Analyze the dependency/stack health of projects under the approved roots
    /// (since 1.9.0). With `check_updates` the core may contact official package
    /// registries + OSV for latest versions and advisories; otherwise it returns
    /// a local-only inventory with no network.
    GetStackHealth {
        roots: Vec<String>,
        #[serde(default)]
        max_depth: Option<u32>,
        #[serde(default)]
        check_updates: bool,
    },
    /// Detect locally-running dev servers/services by listening TCP port, matched
    /// to the approved project roots when provided (since 1.9.0). Read-only.
    GetServices {
        #[serde(default)]
        roots: Vec<String>,
    },
    /// Run the Repository Radar over the approved roots (since 1.11.0): discover
    /// projects, then emit deterministic, explainable, project-grounded
    /// recommendations. Fully local (filesystem + git only), no network.
    GetRadar {
        roots: Vec<String>,
        #[serde(default)]
        max_depth: Option<u32>,
    },
    /// Attribute local AI spend to the projects the sessions ran in (since
    /// 1.13.0), by grouping session records on their recorded working directory.
    /// Offline; reads the same logs the provider scan reads.
    GetProjectUsage,
    /// Capture a non-destructive snapshot of a project's uncommitted work (since
    /// 1.14.0). Uses `git stash create` + a ref under `refs/stackpulse/`; never
    /// alters the working tree, the index, or HEAD. Returns the updated list.
    CreateCheckpoint {
        project_path: String,
        #[serde(default)]
        label: Option<String>,
    },
    /// List a project's StackPulse checkpoints, newest first (since 1.14.0).
    ListCheckpoints { project_path: String },
}

// ---------------------------------------------------------------------------
// Repository Radar — project-aware recommendations (since 1.11.0)
// ---------------------------------------------------------------------------

/// The coarse kind of a radar recommendation. Open enum for forward-compat: the
/// Swift layer treats the wire value as a string, so a newer core adding a
/// category never breaks decoding.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RadarCategory {
    /// Missing/weak agent instructions (CLAUDE.md, AGENTS.md, …).
    AiContext,
    /// Repo hygiene (generated folders in VCS/context, missing ignores).
    Hygiene,
    /// Test coverage / verifiability gaps.
    Testing,
    /// Git state (uncommitted work, no remote/backup).
    Git,
    /// Local setup gaps (env files, etc.).
    Setup,
    /// Context/tool efficiency opportunities.
    Efficiency,
    /// A tooling capability gap grounded in the stack.
    Tooling,
    /// Security posture.
    Security,
    /// Anything a newer core adds.
    #[serde(other)]
    Other,
}

/// Rough effort to act on a recommendation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RadarEffort {
    Trivial,
    Small,
    Moderate,
}

/// Rough risk of acting on a recommendation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RadarRisk {
    None,
    Low,
    Medium,
}

/// One explainable, project-grounded recommendation. Deterministic — derived from
/// concrete facts about the user's local projects, never a generic popularity
/// feed. Each field answers the spec's "must explain" questions.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Recommendation {
    /// Stable id for ordering/dismissal (`<category>:<subject-slug>`).
    pub id: String,
    pub category: RadarCategory,
    /// One-line, actionable title.
    pub title: String,
    /// Why it's relevant and what to do about it.
    pub detail: String,
    /// The projects this applies to (the "which projects benefit").
    #[serde(default)]
    pub affected_projects: Vec<String>,
    /// Concrete evidence observed locally (files present/absent, counts).
    #[serde(default)]
    pub evidence: Vec<String>,
    pub effort: RadarEffort,
    pub risk: RadarRisk,
    /// Whether change is actually advised (spec: "whether no change is safer").
    pub recommend_change: bool,
    /// 0–100 ordering weight, higher first.
    pub priority: u8,
}

/// The Repository Radar's report over the approved roots.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RadarReport {
    pub generated_at_unix: i64,
    pub projects_scanned: usize,
    #[serde(default)]
    pub recommendations: Vec<Recommendation>,
}

// ---------------------------------------------------------------------------
// Project usage — per-project spend attribution (since 1.13.0)
// ---------------------------------------------------------------------------

/// Local AI spend attributed to one project, derived by grouping session records
/// by the working directory recorded in the session logs. Answers "which project
/// is burning my budget?". Costs remain local list-price estimates, never billed
/// amounts. Fully offline (reads the same logs the provider scan already reads).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProjectUsage {
    /// Absolute working directory the sessions ran in.
    pub project_path: String,
    /// Last path component — a friendly label.
    pub project_name: String,
    /// Which providers contributed usage to this project.
    #[serde(default)]
    pub providers: Vec<ProviderId>,
    /// Spend windows for this project ("today", "last_30_days").
    #[serde(default)]
    pub windows: Vec<SpendWindow>,
    /// Most recent session activity seen for this project.
    #[serde(default)]
    pub last_activity_unix: Option<i64>,
}

// ---------------------------------------------------------------------------
// Checkpoints — safe automation (since 1.14.0)
// ---------------------------------------------------------------------------

/// A **non-destructive** snapshot of a project's uncommitted work.
///
/// Captured with `git stash create`, which builds a commit object **without
/// touching the working tree, the index, or HEAD** — nothing the user is doing is
/// disturbed. The resulting object is kept alive under
/// `refs/stackpulse/checkpoints/*` so git can't garbage-collect it and so it's
/// listable later. Creating and listing are therefore additive-only.
///
/// Restoring is the one genuinely mutating step, so the core never performs it:
/// it only reports [`Checkpoint::restore_command`] for the client to surface
/// behind an explicit confirmation.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Checkpoint {
    /// Commit SHA of the snapshot.
    pub id: String,
    /// The ref keeping it alive (`refs/stackpulse/checkpoints/<name>`).
    pub ref_name: String,
    pub label: String,
    pub project_path: String,
    #[serde(default)]
    pub branch: Option<String>,
    pub created_at_unix: i64,
    /// Files whose uncommitted state the snapshot captured.
    #[serde(default)]
    pub files: Vec<String>,
    /// The exact command that would restore this snapshot. Reported, never run.
    pub restore_command: String,
}

/// The core's reply. `request_echo` lets async clients correlate.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CoreResponse {
    Pong {
        protocol_version: Version,
        core_version: String,
    },
    UsageSnapshot(UsageSnapshot),
    ProviderStatus {
        providers: Vec<ProviderStatus>,
    },
    Projects {
        projects: Vec<Project>,
    },
    History {
        points: Vec<HistoryPoint>,
    },
    StackHealth {
        projects: Vec<ProjectStack>,
    },
    Services {
        services: Vec<RunningService>,
    },
    Radar(RadarReport),
    ProjectUsage {
        projects: Vec<ProjectUsage>,
    },
    Checkpoints {
        checkpoints: Vec<Checkpoint>,
        /// An honest note when a create captured nothing (e.g. the working tree
        /// is clean, so the last commit is already the restore point), or when
        /// the project isn't a git repository.
        #[serde(default)]
        note: Option<String>,
    },
    Error(CoreError),
}

/// Cheap per-provider status without a full scan.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderStatus {
    pub provider: ProviderId,
    pub display_name: String,
    pub installed: bool,
    pub authenticated: bool,
    pub health: IntegrationHealth,
    #[serde(default)]
    pub detected_version: Option<String>,
}

/// Structured, stable error codes for cross-repo interoperability.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoreError {
    pub code: ErrorCode,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    /// Request JSON could not be parsed.
    BadRequest,
    /// A provider scan failed but others may have succeeded.
    ProviderScanFailed,
    /// Permission to read a required path was denied.
    PermissionDenied,
    /// Catch-all internal error.
    Internal,
}

impl CoreError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        CoreError {
            code,
            message: message.into(),
        }
    }
}
