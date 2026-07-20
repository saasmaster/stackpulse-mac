import AppKit
import Foundation
import SwiftUI

/// The user-selectable auto-refresh cadence. `Manual` runs no timer (refresh only
/// on demand); the rest map to a fixed interval in seconds. Persisted by raw value.
enum RefreshMode: String, CaseIterable, Sendable {
    case manual
    case m1
    case m2
    case m5
    case m15

    /// Timer interval, or `nil` for `Manual` (no timer at all).
    var seconds: TimeInterval? {
        switch self {
        case .manual: return nil
        case .m1: return 60
        case .m2: return 120
        case .m5: return 300
        case .m15: return 900
        }
    }

    var label: String {
        switch self {
        case .manual: return "Manual"
        case .m1: return "1m"
        case .m2: return "2m"
        case .m5: return "5m"
        case .m15: return "15m"
        }
    }

    /// Longer phrasing for the Settings "auto-refresh" summary line.
    var summary: String {
        switch self {
        case .manual: return "Manual only"
        case .m1: return "every 1 minute"
        case .m2: return "every 2 minutes"
        case .m5: return "every 5 minutes"
        case .m15: return "every 15 minutes"
        }
    }

    var systemImage: String {
        self == .manual ? "hand.raised" : "timer"
    }

    var segment: GlassSegment<RefreshMode> {
        GlassSegment(value: self, systemImage: systemImage, label: label)
    }

    static var allSegments: [GlassSegment<RefreshMode>] { allCases.map(\.segment) }
}

/// Observable holder for the latest usage snapshot.
///
/// The scan runs on a background task (it reads gigabytes of logs and can take
/// several seconds); only the published results are touched on the main actor.
/// A coalescing flag prevents overlapping refreshes.
@MainActor
final class SnapshotStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?

    /// Provider ids the macOS Keychain probe found credentials for.
    @Published private(set) var keychainAuthed: Set<String> = []

    /// The durable, ever-growing usage history the core persists (protocol ≥
    /// 1.6.0), most-recent-day last. Seeded from the last ~30 days of logs on the
    /// first record, then accumulated on every refresh. Drives the Trends UI and
    /// survives beyond the 30-day window raw logs expose. Empty until the first
    /// load/record completes (Trends shows its empty state).
    @Published private(set) var history: [HistoryPoint] = []

    /// Alert ids the user acknowledged this session. Filtered out of the active
    /// set; they stay hidden until the app restarts (kept intentionally simple —
    /// a recurring alert with the same id remains acknowledged).
    @Published private(set) var acknowledgedAlertIDs: Set<String> = []

    /// Whether an idle-system-sleep assertion is currently held. Setting it
    /// starts/stops the local `ProcessInfo` activity (no permission required).
    @Published var keepAwake: Bool = false {
        didSet {
            guard keepAwake != oldValue else { return }
            if keepAwake { keepAwakeAssertion.start() } else { keepAwakeAssertion.stop() }
        }
    }

    /// "See it with sample data" — off by default, opt-in, persisted. When on, the
    /// store publishes a fabricated `DemoData` snapshot instead of scanning, so a
    /// first-run user with no AI-tool logs can see the real product. **Every
    /// surface that shows data must display `DemoBanner` while this is on** — fake
    /// data must never be mistaken for real, which is this app's whole point.
    @Published var demoMode: Bool = SnapshotStore.loadBool(SnapshotStore.demoModeKey, default: false) {
        didSet {
            guard demoMode != oldValue else { return }
            UserDefaults.standard.set(demoMode, forKey: Self.demoModeKey)
            if demoMode { applyDemoData() } else { refresh() }
        }
    }
    private static let demoModeKey = "demoMode"

    /// Publish the sample snapshot. Re-applied on each refresh tick while demo mode
    /// is on, so its now-relative timestamps (limits, sessions) stay current.
    private func applyDemoData() {
        isLoading = false
        lastError = nil
        lastUpdated = Date()
        keychainAuthed = ["claude"] // so the sample Claude card reads "authenticated"
        snapshot = DemoData.snapshot(now: Date())
    }

    /// Which screen edge the floating edge-sidebar pins to. `false` = right
    /// (default, original behavior), `true` = left. Persisted; the
    /// `EdgeSidebarController` observes this and re-pins the panel live.
    @Published var sidebarOnLeft: Bool = SnapshotStore.loadBool(
        SnapshotStore.sidebarOnLeftKey, default: false
    ) {
        didSet {
            guard sidebarOnLeft != oldValue else { return }
            UserDefaults.standard.set(sidebarOnLeft, forKey: Self.sidebarOnLeftKey)
        }
    }
    private static let sidebarOnLeftKey = "stackpulse.sidebarOnLeft"

    // MARK: Live limits (opt-in Anthropic usage fetch)

    /// User-controlled: when on, StackPulse fetches Claude's session/weekly
    /// limits from Anthropic using the local Claude Code login. When off, the app
    /// is fully offline (no token is read, no request is made). Persisted in
    /// UserDefaults; **default on** since the user consented to the network path.
    @Published var liveLimitsEnabled: Bool = SnapshotStore.loadLiveLimitsPref() {
        didSet {
            guard liveLimitsEnabled != oldValue else { return }
            UserDefaults.standard.set(liveLimitsEnabled, forKey: Self.liveLimitsKey)
            if liveLimitsEnabled {
                fetchAndMergeLiveLimits()
                fetchAndMergeLiveProviders()
            } else {
                // Fully offline again: drop the fetched limits, cache, and any note.
                stripLiveLimits()
                stripLiveProviderReadings()
                liveReadings = [:]
                liveReadingAt = [:]
                liveAttemptAt = [:]
                injectedLiveLabels = [:]
                liveProviderErrors = [:]
                liveProviderPlans = [:]
                lastGoodLiveLimits = []
                lastGoodLiveLimitsAt = nil
                liveLimitsError = nil
                liveLimitsRecovery = nil
                liveLimitsUpdatedAt = nil
                try? FileManager.default.removeItem(at: liveLimitsCacheURL)
            }
        }
    }

    /// A short, user-facing note when the last live fetch couldn't produce data
    /// (offline, signed out, etc). Never contains the token or raw response.
    @Published private(set) var liveLimitsError: String?

    /// A provenance warning about limits we DID get — currently: they belong to
    /// the Claude Desktop login because the Claude Code one expired. Kept separate
    /// from `liveLimitsError` precisely because there IS a value on screen; the
    /// danger is that it looks like the user's Code usage when it isn't.
    @Published private(set) var liveLimitsCaveat: String?

    /// The concrete action that would fix `liveLimitsError`, when one exists.
    /// Carried as a value so the UI can offer a button without string-matching the
    /// message — the message is for humans, this is for code.
    @Published private(set) var liveLimitsRecovery: AnthropicUsageClient.Recovery?

    /// Run `claude` in Terminal to renew the expired CLI login.
    ///
    /// The app cannot do this silently and shouldn't: signing in is the user's act,
    /// and it needs a real interactive terminal. This just saves them retyping it —
    /// the command is visible in Terminal, exactly like every other command
    /// StackPulse offers to run.
    func renewClaudeLogin() {
        CommandRunner.runInTerminal(command: "claude", cwd: NSHomeDirectory())
    }

    /// When the last live-limits fetch completed (success or handled failure).
    @Published private(set) var liveLimitsUpdatedAt: Date?

    /// Coalesces overlapping live fetches.
    private var isFetchingLive = false

    /// The last successfully-fetched live limits + when. Persisted to disk (see
    /// `persistLiveLimits`/`loadPersistedLiveLimits`) so a momentary blip — a 429,
    /// a closed laptop, an app restart — doesn't blank the card.
    ///
    /// It buys **an hour**, not indefinite cover. This comment used to promise that
    /// an *expired token* would "keep showing it, labeled as of", and that is
    /// exactly the bug that shipped: the token expired, the fetch failed for 70
    /// hours, and an 82% from a window that had already reset stayed on screen.
    /// Past `liveLimitsStaleAfter` the value is dropped and the reason is shown
    /// instead — see `cachedLiveLimitsUsable`.
    private var lastGoodLiveLimits: [LimitWindow] = []
    private var lastGoodLiveLimitsAt: Date?
    /// When the last live-limits fetch was *attempted* (success or failure). Gates
    /// the request rate so a sustained failure backs off instead of hammering the
    /// API every refresh tick — `lastGoodLiveLimitsAt` only advances on success.
    private var lastLiveFetchAttemptAt: Date?
    /// Minimum time between actual network fetches — the cached value is reused in
    /// between, so frequent refreshes never rate-limit the provider.
    private let liveLimitsRefetchInterval: TimeInterval = 8 * 60
    /// How long a cached limit may still be shown when a fresh fetch can't be had,
    /// and how long a failing fetch stays unreported. **One bound for both**, and
    /// deliberately short.
    ///
    /// This was 3 DAYS, on the theory that a stale-but-labeled % beats a blank card
    /// reading as "signed out". That reasoning does not survive contact with the
    /// failure it caused: a fetch broke and the app displayed **82% for 70 hours**
    /// after that window had already reset. Worse, the check for "has this window
    /// reset?" reads the cached `resets_at` — which is itself part of the stale
    /// snapshot. Stale data cannot adjudicate its own freshness, so age is the only
    /// honest guard.
    ///
    /// A live limit is the number in this app a user acts on immediately. If we
    /// cannot refresh it, the answer is "we don't know" — never a number we can't
    /// stand behind. An hour still absorbs a rate-limit, a closed laptop, or a
    /// flaky network across ~7 refetch attempts.
    private let liveLimitsStaleAfter: TimeInterval = 60 * 60

    /// When the currently-shown live limits were actually captured (last
    /// successful fetch), or nil when there are none. Drives the "as of …" label.
    var liveLimitsCapturedAt: Date? { lastGoodLiveLimits.isEmpty ? nil : lastGoodLiveLimitsAt }

    /// True when the shown live limits are cached and no longer fresh (older than
    /// the refetch interval) — the card labels them rather than implying live.
    var liveLimitsAreStale: Bool {
        guard let at = liveLimitsCapturedAt else { return false }
        return Date().timeIntervalSince(at) > liveLimitsRefetchInterval
    }

    private static let liveLimitsKey = "liveLimitsEnabled"

    /// One persisted live-limits snapshot: the windows + the unix time captured.
    private struct LiveLimitsCache: Codable {
        let limits: [LimitWindow]
        let at: TimeInterval
        /// The provenance warning these values were captured with, if any. Stored
        /// WITH them because a caveat that doesn't survive relaunch is worse than
        /// none: the app comes back up, re-applies wrong-login percentages from
        /// the cache, and shows them clean until the next fetch happens to run.
        var caveat: String?
    }

    /// `~/Library/Application Support/StackPulse/live_limits_cache.json`.
    private var liveLimitsCacheURL: URL {
        URL(fileURLWithPath: historyDataDir).appendingPathComponent("live_limits_cache.json")
    }

    /// Writes the last-good limits to disk so they survive a relaunch. No-op when
    /// there's nothing good to save.
    private func persistLiveLimits() {
        guard !lastGoodLiveLimits.isEmpty, let at = lastGoodLiveLimitsAt else { return }
        let cache = LiveLimitsCache(limits: lastGoodLiveLimits, at: at.timeIntervalSince1970,
                                    caveat: liveLimitsCaveat)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: liveLimitsCacheURL, options: .atomic)
        }
    }

    /// Loads any persisted last-good limits on launch, so the card can show the
    /// last-known % immediately (labeled "as of …") even before/without a fresh
    /// fetch. Silent on absence or any decode failure.
    private func loadPersistedLiveLimits() {
        guard liveLimitsEnabled,
              let data = try? Data(contentsOf: liveLimitsCacheURL),
              let cache = try? JSONDecoder().decode(LiveLimitsCache.self, from: data),
              !cache.limits.isEmpty else { return }
        lastGoodLiveLimits = cache.limits
        lastGoodLiveLimitsAt = Date(timeIntervalSince1970: cache.at)
        // Restore the caveat with the values it belongs to, so a wrong-login
        // reading can't come back clean after a relaunch.
        liveLimitsCaveat = cache.caveat
        liveLimitsRecovery = cache.caveat == nil ? nil : .renewLoginInTerminal
    }

    // MARK: Limit forecasting (the %-trajectory over time)

    /// The observed history of each live limit's consumption, kept so the app can
    /// forecast when a limit will be hit — the only honest basis for that, since
    /// StackPulse can't see a hidden limit's internal accounting.
    @Published private(set) var limitSamples: [LimitSample] = []

    /// Samples kept **per window**. Pruning is per-window, not global, so a
    /// frequently-sampled short window (5h) can't evict a slow window's (weekly)
    /// early-cycle history and starve its forecast. At a ~2-minute cadence this is
    /// ~13 hours of readings — ample to fit a rate for either window.
    private static let limitSamplesPerWindowCap = 400

    private var limitSamplesURL: URL {
        URL(fileURLWithPath: historyDataDir).appendingPathComponent("limit_samples.json")
    }

    private func loadLimitSamples() {
        guard let data = try? Data(contentsOf: limitSamplesURL),
              let decoded = try? JSONDecoder().decode([LimitSample].self, from: data)
        else { return }
        limitSamples = decoded
    }

    private func persistLimitSamples() {
        if let data = try? JSONEncoder().encode(limitSamples) {
            try? data.write(to: limitSamplesURL, options: .atomic)
        }
    }

    /// Append a reading per live limit — but only a genuinely new one. The fetch
    /// runs every couple of minutes and often returns the same numbers; recording
    /// duplicates would fake a longer, denser history than actually exists and bias
    /// the slope. A sample is new when its window's percentage or its capture time
    /// changed from the last one we stored.
    private func recordLimitSamples(_ limits: [LimitWindow]) {
        // Called once per SUCCESSFUL fresh fetch (spaced by the refetch throttle),
        // so every reading here is a genuinely new observation — the same % at a
        // later time is real evidence the limit is flat, not a duplicate to drop.
        // (An earlier per-reading dedup keyed on capture time was inert anyway: the
        // fetch-completion time is re-stamped each fetch, so it never matched.)
        let capturedAt = (lastGoodLiveLimitsAt ?? Date()).timeIntervalSince1970
        var appended = false
        for limit in limits where limit.provenance == AnthropicUsageClient.liveProvenance {
            limitSamples.append(LimitSample(
                windowKey: limit.label, capturedAtUnix: capturedAt,
                usedPercent: limit.used_percent))
            appended = true
        }
        guard appended else { return }
        pruneLimitSamplesPerWindow()
        persistLimitSamples()
    }

    /// Keep only the most-recent `limitSamplesPerWindowCap` samples of each window,
    /// preserving overall chronological order. Per-window so one window's cadence
    /// never evicts another's history.
    private func pruneLimitSamplesPerWindow() {
        var counts: [String: Int] = [:]
        for s in limitSamples { counts[s.windowKey, default: 0] += 1 }
        guard counts.values.contains(where: { $0 > Self.limitSamplesPerWindowCap }) else { return }
        // Walk newest→oldest, keeping up to the cap per window, then restore order.
        var kept: [String: Int] = [:]
        var keep: [LimitSample] = []
        for s in limitSamples.reversed() {
            let n = kept[s.windowKey, default: 0]
            if n < Self.limitSamplesPerWindowCap {
                kept[s.windowKey] = n + 1
                keep.append(s)
            }
        }
        limitSamples = keep.reversed()
    }

    /// The forecast for one live limit, from its samples and current reading.
    func limitForecast(for limit: LimitWindow) -> LimitForecast.Result {
        LimitForecast.project(
            samples: limitSamples.filter { $0.windowKey == limit.label },
            currentPercent: limit.used_percent,
            resetAtUnix: limit.resets_at_unix.map(Double.init),
            windowMinutes: limit.window_minutes,
            now: Date().timeIntervalSince1970)
    }

    /// Windows (`label|resetAt`) for which a forecast warning is currently latched.
    ///
    /// A forecast is a *noisy* signal — the fitted rate wobbles as each reading
    /// lands, so `willHitBeforeReset` can flip true/false between refreshes. The
    /// alert list and the notification gate both react to an alert appearing and
    /// disappearing (the gate re-fires a cleared-then-returning alert), so an
    /// un-latched forecast alert would ping the user repeatedly. Once a window is
    /// judged on-track within a cycle, it stays latched until the cycle resets or
    /// the reading leaves the forecast band — so the warning fires once per cycle,
    /// not once per wobble. Ephemeral: a relaunch may warn once more, which is fine.
    private var forecastLatchedCycles: Set<String> = []

    /// Stable key for a limit's current reset cycle. When the window resets, its
    /// `resets_at_unix` changes, so the old key drops out and a new cycle can warn.
    private func forecastCycleKey(_ limit: LimitWindow) -> String {
        "\(limit.label)|\(limit.resets_at_unix ?? 0)"
    }

    /// Update the latch from the freshly-merged live limits. Called inside
    /// `applyLiveLimits`, after the current sample is recorded, before notifying.
    private func refreshForecastLatch(_ live: [LimitWindow]) {
        let liveWindows = live.filter { $0.provenance == AnthropicUsageClient.liveProvenance }
        for limit in liveWindows {
            let key = forecastCycleKey(limit)
            // Only the 40–80% band is the forecast's to own: below 40% it's too
            // speculative, at/above 80% the threshold alert takes over. Outside the
            // band, drop any latch so the two never both fire.
            guard limit.used_percent >= 40, limit.used_percent < 80 else {
                forecastLatchedCycles.remove(key)
                continue
            }
            let forecast = limitForecast(for: limit)
            if forecast.confidence == .ok, forecast.willHitBeforeReset == true {
                forecastLatchedCycles.insert(key)
            }
        }
        // Drop latches whose cycle is no longer present (window reset → new key, or
        // the window vanished). Keeps the set from growing across resets.
        let liveKeys = Set(liveWindows.map(forecastCycleKey))
        forecastLatchedCycles.formIntersection(liveKeys)
    }

    // MARK: BYOK provider connections (API-key balances)

    /// Provider ids with a saved API key (loaded from `APIKeyStore` on launch,
    /// updated as the user connects/clears keys). Gates all balance fetching —
    /// a provider not in this set is never contacted.
    @Published private(set) var apiKeyProviderIDs: Set<String> = []

    /// The most recent fetched balance per connected provider id. Kept here (in
    /// addition to being folded onto the matching snapshot provider) so the
    /// Settings connection rows can show status even for providers the core
    /// doesn't surface as a card, and so a fresh core snapshot can be re-decorated
    /// without a refetch.
    @Published private(set) var balances: [String: ProviderBalance] = [:]

    /// A short, user-facing note per provider when its last balance fetch
    /// couldn't produce data (offline, bad key, etc). Never the key or raw body.
    @Published private(set) var balanceError: [String: String] = [:]

    /// When each provider's last balance fetch completed (success or handled
    /// failure).
    @Published private(set) var balanceUpdatedAt: [String: Date] = [:]

    /// Coalesces overlapping balance fetches, per provider.
    private var fetchingBalances: Set<String> = []

    /// Loads the persisted preference. A fresh install defaults to **off**.
    ///
    /// This is the one feature that reads a secret: it fetches the user's Claude
    /// OAuth token from the Keychain and sends it to Anthropic. An app that claims
    /// to be offline by default must not start doing that on its own — so absent
    /// means off, and enabling it is a deliberate act.
    ///
    /// Installs before 0.27.0 defaulted to **on**, and silently switching the
    /// feature off under someone who was relying on it would be its own quiet lie.
    /// A live-limits cache on disk proves the fetch actually ran and succeeded on
    /// this machine, so that install inherits `on`. The answer is persisted either
    /// way, so this only ever decides once — after that the stored value wins and
    /// the file is irrelevant.
    private static func loadLiveLimitsPref() -> Bool {
        let defaults = UserDefaults.standard
        if let explicit = defaults.object(forKey: liveLimitsKey) as? Bool {
            return explicit
        }
        let inherited = FileManager.default.fileExists(atPath: liveLimitsCachePath())
        defaults.set(inherited, forKey: liveLimitsKey)
        return inherited
    }

    /// Path of the live-limits cache, resolved without an instance. Mirrors
    /// `liveLimitsCacheURL`, which can't be used here because the preference is
    /// read while the store is still being initialized.
    private static func liveLimitsCachePath() -> String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("StackPulse", isDirectory: true)
            .appendingPathComponent("live_limits_cache.json")
            .path
    }

    // MARK: Notifications (proactive alerts)

    /// The thin AppKit bridge that actually posts banners. Owned here so there's a
    /// single source of truth; the AppDelegate wires its `onOpen` on launch.
    let notifications = NotificationManager()

    /// App-level preference: deliver a macOS notification when a new needs-attention
    /// alert appears. Independent of the OS-level permission (see
    /// `notificationsAuthorized`). Persisted; **default on**.
    @Published var notificationsEnabled: Bool = SnapshotStore.loadBool(
        SnapshotStore.notificationsEnabledKey, default: true
    ) {
        didSet {
            guard notificationsEnabled != oldValue else { return }
            UserDefaults.standard.set(notificationsEnabled, forKey: Self.notificationsEnabledKey)
            if notificationsEnabled {
                notifications.requestAuthorization()
            } else {
                notifications.clearDelivered()
            }
        }
    }

    /// Minimum severity that triggers a notification. `.info` = everything,
    /// `.warning` = warnings + critical, `.critical` = critical only. Persisted by
    /// raw value; **default `.warning`** (info-level rarely warrants a banner).
    @Published var notifyMinSeverity: AlertSeverity = SnapshotStore.loadMinSeverity() {
        didSet {
            guard notifyMinSeverity != oldValue else { return }
            UserDefaults.standard.set(notifyMinSeverity.rawValue, forKey: Self.notifyMinSeverityKey)
        }
    }

    /// Quiet hours: when on, banners are suppressed between `quietStartHour` and
    /// `quietEndHour` (may wrap midnight). Alerts still appear in-app and in the
    /// menu bar — this only mutes the interruption.
    @Published var quietHoursEnabled: Bool = SnapshotStore.loadBool(
        SnapshotStore.quietHoursEnabledKey, default: false
    ) {
        didSet { UserDefaults.standard.set(quietHoursEnabled, forKey: Self.quietHoursEnabledKey) }
    }
    @Published var quietStartHour: Int = SnapshotStore.loadHour(SnapshotStore.quietStartKey, default: 22) {
        didSet { UserDefaults.standard.set(quietStartHour, forKey: Self.quietStartKey) }
    }
    @Published var quietEndHour: Int = SnapshotStore.loadHour(SnapshotStore.quietEndKey, default: 8) {
        didSet { UserDefaults.standard.set(quietEndHour, forKey: Self.quietEndKey) }
    }

    /// OS-level authorization, updated by the manager. When `false` while
    /// `notificationsEnabled` is on, Settings hints to enable banners in System
    /// Settings. Defaults to `false` until the first status check resolves.
    @Published private(set) var notificationsAuthorized = false

    /// Active-alert ids we've already delivered a banner for, pruned to still-active
    /// on every evaluation (so a cleared-then-returning condition re-notifies).
    private var notifiedAlertIDs: Set<String> = []
    /// False until the first snapshot seeds the notified set silently.
    private var notificationsSeeded = false

    private static let notificationsEnabledKey = "stackpulse.notificationsEnabled"
    private static let notifyMinSeverityKey = "stackpulse.notifyMinSeverity"
    private static let quietHoursEnabledKey = "stackpulse.quietHoursEnabled"
    private static let quietStartKey = "stackpulse.quietStartHour"
    private static let quietEndKey = "stackpulse.quietEndHour"

    /// Reads a persisted Bool, returning `default` when the key was never set.
    private static func loadBool(_ key: String, default def: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? def : UserDefaults.standard.bool(forKey: key)
    }

    /// Reads a persisted 0–23 hour, clamping out-of-range/unset values to `default`.
    private static func loadHour(_ key: String, default def: Int) -> Int {
        guard UserDefaults.standard.object(forKey: key) != nil else { return def }
        let v = UserDefaults.standard.integer(forKey: key)
        return (0...23).contains(v) ? v : def
    }

    /// Reads the persisted notification severity threshold, defaulting to `.warning`.
    private static func loadMinSeverity() -> AlertSeverity {
        guard UserDefaults.standard.object(forKey: notifyMinSeverityKey) != nil else { return .warning }
        return AlertSeverity(rawValue: UserDefaults.standard.integer(forKey: notifyMinSeverityKey)) ?? .warning
    }

    private let keepAwakeAssertion = KeepAwake()

    /// Optional demo alerts injected only when `STACKPULSE_DEMO_ALERTS` is set in
    /// the environment. Lets the needs-attention surfaces be previewed without a
    /// core new enough to emit real alerts. Never populated in normal runs.
    private let demoAlerts: [Alert] = SnapshotStore.loadDemoAlerts()

    /// Optional demo missions injected only when `STACKPULSE_DEMO_MISSIONS` is set
    /// in the environment. Lets the Missions surfaces be previewed without live AI
    /// coding sessions running. Never populated in normal runs.
    private let demoMissions: [Mission] = SnapshotStore.loadDemoMissions()

    /// A one-shot request to navigate the main window to a section (e.g. tapping
    /// the popover's "Active now" block jumps to Missions). The view consumes it
    /// and clears it back to `nil`.
    @Published var pendingSection: MainSection?

    /// Auto-refresh cadence, user-selectable in Settings. Changing it reschedules
    /// (or cancels, for `Manual`) the timer and persists the choice. Defaults to
    /// every 2 minutes — modest enough to avoid continuous CPU load (the scan is
    /// bounded to the last 35 days of logs).
    @Published var refreshMode: RefreshMode = SnapshotStore.loadRefreshMode() {
        didSet {
            guard refreshMode != oldValue else { return }
            UserDefaults.standard.set(refreshMode.rawValue, forKey: Self.refreshModeKey)
            rescheduleTimer()
        }
    }
    private var timer: Timer?

    private static let refreshModeKey = "stackpulse.refreshMode"

    private static func loadRefreshMode() -> RefreshMode {
        let raw = UserDefaults.standard.string(forKey: refreshModeKey) ?? ""
        return RefreshMode(rawValue: raw) ?? .m2
    }

    func start() {
        // Seed the connected-providers set before the first refresh completes so
        // its completion can fetch balances for already-saved keys.
        loadAPIKeyProviders()
        // Notifications: install the delegate + reflect OS authorization. Only
        // force the system prompt when the user has notifications enabled;
        // otherwise just read the current status for the Settings hint.
        notifications.onAuthorizationResolved = { [weak self] granted in
            self?.notificationsAuthorized = granted
        }
        notifications.configure()
        if notificationsEnabled {
            notifications.requestAuthorization()
        } else {
            notifications.refreshAuthorizationStatus()
        }
        // Load the last-known live limits from disk so the Claude card can show
        // the last % immediately (labeled "as of …"), even if the saved token is
        // now expired and today's fetch will fail.
        loadPersistedLiveLimits()
        refresh()
        rescheduleTimer()
        // Load any accumulated usage history once on launch so Trends has data
        // before the first refresh finishes (off the main thread).
        loadHistory()
        // Load captured command-run history so outcomes are there on launch.
        loadCommandRuns()
        // Load the limit %-trajectory so forecasts survive a relaunch.
        loadLimitSamples()
        // Auto-scan remembered project roots on launch (off the main thread).
        if !approvedRoots.isEmpty {
            rescanProjects()
            rescanStackHealth()
        }
        // Running dev servers are independent of approved roots (matched to them
        // when present), so always detect on launch.
        rescanServices()
    }

    /// Cancels any running timer and installs a new one for the current
    /// `refreshMode` (no timer for `Manual`). Idempotent.
    private func rescheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard let seconds = refreshMode.seconds else { return }
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: Projects (Command Memory)

    /// Absolute paths the user approved for command discovery. Persisted as plain
    /// paths in UserDefaults — the app is not sandboxed, so no security-scoped
    /// bookmarks are needed.
    @Published private(set) var approvedRoots: [String] = SnapshotStore.loadApprovedRoots()

    /// Projects discovered under `approvedRoots` on the last scan.
    @Published private(set) var projects: [Project] = []

    /// True while a project scan is in flight.
    @Published private(set) var isScanningProjects = false

    /// A short, user-facing note when the last scan found nothing (or failed).
    @Published private(set) var projectsError: String?

    /// When the last project scan completed.
    @Published private(set) var projectsUpdatedAt: Date?

    private static let approvedRootsKey = "stackpulse.approvedRoots"

    private static func loadApprovedRoots() -> [String] {
        UserDefaults.standard.stringArray(forKey: approvedRootsKey) ?? []
    }

    private func persistRoots() {
        UserDefaults.standard.set(approvedRoots, forKey: Self.approvedRootsKey)
    }

    // MARK: Favorite projects (pin-to-top)

    /// Favorited project paths — pinned to the top of the Launcher and the sidebar
    /// Apps tab. Persisted so pins survive relaunch.
    @Published private(set) var favoriteProjectPaths: Set<String> = SnapshotStore.loadFavorites()

    private static let favoritesKey = "stackpulse.favoriteProjects"

    private static func loadFavorites() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
    }

    func isFavorite(_ path: String) -> Bool { favoriteProjectPaths.contains(path) }

    func toggleFavorite(_ path: String) {
        if favoriteProjectPaths.contains(path) {
            favoriteProjectPaths.remove(path)
        } else {
            favoriteProjectPaths.insert(path)
        }
        UserDefaults.standard.set(Array(favoriteProjectPaths), forKey: Self.favoritesKey)
    }

    /// Projects ordered favorites-first, then case-insensitively by name.
    func favoritesFirst(_ projects: [Project]) -> [Project] {
        projects.sorted { a, b in
            let fa = isFavorite(a.path), fb = isFavorite(b.path)
            if fa != fb { return fa }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Presents an open panel for one or more folders and adds any new ones to the
    /// approved roots, then rescans. Directories only, multiple selection allowed.
    func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose a folder — a single project, or a parent folder that "
            + "contains several projects (StackPulse finds the projects inside it)."
        guard panel.runModal() == .OK else { return }

        var changed = false
        for path in panel.urls.map(\.path) where !approvedRoots.contains(path) {
            approvedRoots.append(path)
            changed = true
        }
        if changed {
            persistRoots()
            rescanProjects()
        }
    }

    /// Removes an approved root; drops projects under it immediately, then rescans.
    func removeRoot(_ path: String) {
        approvedRoots.removeAll { $0 == path }
        persistRoots()
        projects.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
        if approvedRoots.isEmpty {
            projects = []
            projectsError = nil
            projectsUpdatedAt = nil
        } else {
            rescanProjects()
        }
    }

    /// Rescans all approved roots for projects + commands on a background task and
    /// publishes the result. Coalesces overlapping scans. No-op with no roots.
    func rescanProjects() {
        guard !isScanningProjects else { return }
        guard !approvedRoots.isEmpty else {
            projects = []
            projectsError = nil
            return
        }
        isScanningProjects = true
        projectsError = nil
        let roots = approvedRoots

        Task.detached(priority: .utility) {
            let found = CoreBridge.projects(roots: roots, maxDepth: 4)
            await MainActor.run {
                self.isScanningProjects = false
                if let found {
                    self.projects = found
                    self.projectsUpdatedAt = Date()
                    self.projectsError = found.isEmpty
                        ? "No projects with recognizable commands were found in the selected folder\(roots.count == 1 ? "" : "s")."
                        : nil
                } else {
                    // Scan failed — distinct from "found nothing". Keep the prior
                    // list and its timestamp; report the failure, not a false empty.
                    self.projectsError = "Couldn't read the projects in the selected folder\(roots.count == 1 ? "" : "s") — the scan failed. Try rescanning."
                }
            }
        }
    }

    // MARK: Stack Health (dependency/security intelligence, protocol ≥ 1.9.0)

    /// Per-project dependency/stack health from the last scan (most-actionable
    /// first). Empty until a scan runs (needs approved roots).
    @Published private(set) var stackHealth: [ProjectStack] = []
    @Published private(set) var isScanningStack = false
    @Published private(set) var stackUpdatedAt: Date?
    /// True when the last scan *failed* (vs. ran and found no dependency data).
    @Published private(set) var stackScanFailed = false

    /// When on, Stack Health contacts official registries + OSV for latest
    /// versions and advisories; off = local-only inventory (no network). Persisted.
    @Published var stackCheckUpdates: Bool = SnapshotStore.loadBool(
        SnapshotStore.stackCheckUpdatesKey, default: true
    ) {
        didSet {
            guard stackCheckUpdates != oldValue else { return }
            UserDefaults.standard.set(stackCheckUpdates, forKey: Self.stackCheckUpdatesKey)
        }
    }
    private static let stackCheckUpdatesKey = "stackpulse.stackCheckUpdates"

    /// Scans dependency/stack health for the approved roots off the main actor.
    /// Coalesced; no-op with no roots. `check_updates` follows `stackCheckUpdates`.
    func rescanStackHealth() {
        guard !isScanningStack, !approvedRoots.isEmpty else { return }
        isScanningStack = true
        let roots = approvedRoots
        let check = stackCheckUpdates
        Task.detached(priority: .utility) {
            let result = CoreBridge.stackHealth(roots: roots, checkUpdates: check, maxDepth: 4)
            await MainActor.run {
                self.isScanningStack = false
                if let result {
                    self.stackHealth = result
                    self.stackUpdatedAt = Date()
                    self.stackScanFailed = false
                } else {
                    self.stackScanFailed = true   // keep prior data + timestamp
                }
            }
        }
    }

    // MARK: Services & runtime (running dev servers, protocol ≥ 1.9.0)

    /// Locally-running dev servers/services from the last detection.
    @Published private(set) var services: [RunningService] = []
    @Published private(set) var isScanningServices = false
    @Published private(set) var servicesUpdatedAt: Date?
    /// True when the last detection *failed* (vs. ran and found nothing running).
    @Published private(set) var servicesScanFailed = false

    /// Detects running dev servers/services off the main actor. Coalesced. Matches
    /// them to the approved project roots when any are set.
    func rescanServices() {
        guard !isScanningServices else { return }
        isScanningServices = true
        let roots = approvedRoots
        Task.detached(priority: .utility) {
            let result = CoreBridge.services(roots: roots)
            await MainActor.run {
                self.isScanningServices = false
                if let result {
                    self.services = result
                    self.servicesUpdatedAt = Date()
                    self.servicesScanFailed = false
                } else {
                    self.servicesScanFailed = true   // keep prior data + timestamp
                }
            }
        }
    }

    // MARK: Spend budget (guardrail)

    // Budgets are evaluated here rather than in the core on purpose: a budget is a
    // user preference and the check is "total vs threshold", not the hard shared
    // parsing/pricing logic the core exists to own. It also keeps `Alert.provider`
    // honest — a budget spans providers, so the core would have to invent one.
    // Same client-synthesis pattern as `liveLimitAlerts`.

    /// Optional daily spend guardrail, USD. `nil` = no budget.
    @Published var dailyBudgetUSD: Double? = SnapshotStore.loadBudget(SnapshotStore.dailyBudgetKey) {
        didSet { persistBudget() }
    }
    /// Optional 30-day spend guardrail, USD. `nil` = no budget.
    @Published var monthlyBudgetUSD: Double? = SnapshotStore.loadBudget(SnapshotStore.monthlyBudgetKey) {
        didSet { persistBudget() }
    }
    /// Percent of a budget that raises a warning; 100% always raises a critical.
    @Published var budgetWarnPercent: Double = SnapshotStore.loadBudget(SnapshotStore.budgetWarnKey) ?? 80 {
        didSet { persistBudget() }
    }

    private static let dailyBudgetKey = "stackpulse.budget.daily"
    private static let monthlyBudgetKey = "stackpulse.budget.monthly"
    private static let budgetWarnKey = "stackpulse.budget.warnPercent"

    /// A stored budget, or `nil` when unset (absent ⇒ no budget, not zero).
    private static func loadBudget(_ key: String) -> Double? {
        UserDefaults.standard.object(forKey: key) as? Double
    }

    private func persistBudget() {
        let d = UserDefaults.standard
        // Removing on nil keeps "unset" distinct from "set to 0".
        if let dailyBudgetUSD { d.set(dailyBudgetUSD, forKey: Self.dailyBudgetKey) }
        else { d.removeObject(forKey: Self.dailyBudgetKey) }
        if let monthlyBudgetUSD { d.set(monthlyBudgetUSD, forKey: Self.monthlyBudgetKey) }
        else { d.removeObject(forKey: Self.monthlyBudgetKey) }
        d.set(budgetWarnPercent, forKey: Self.budgetWarnKey)
    }

    /// How far today's estimated spend has eaten the daily budget (0–1+), or `nil`
    /// when no daily budget is set.
    var dailyBudgetFraction: Double? { fraction(spent: snapshot?.totalTodayCost, of: dailyBudgetUSD) }
    /// Same for the 30-day budget.
    var monthlyBudgetFraction: Double? { fraction(spent: snapshot?.total30Cost, of: monthlyBudgetUSD) }

    private func fraction(spent: Double?, of budget: Double?) -> Double? {
        guard let budget, budget > 0 else { return nil }
        return (spent ?? 0) / budget
    }

    /// Needs-attention alerts synthesized from the spend guardrails. Ids are stable
    /// per window so the notification gate dedups them like any core alert, and
    /// `created_at` uses the snapshot's own generation time (no per-render `Date()`).
    ///
    /// Deliberately honest: these are **local estimates**, and StackPulse can only
    /// warn — it does not control your agents and cannot stop a run.
    private var budgetAlerts: [Alert] {
        guard let snap = snapshot else { return [] }
        var out: [Alert] = []

        func evaluate(window: String, label: String, spent: Double?, budget: Double?) {
            guard let budget, budget > 0 else { return }
            let spent = spent ?? 0
            let pct = spent / budget * 100
            let severity: String
            if pct >= 100 { severity = "critical" }
            else if pct >= budgetWarnPercent { severity = "warning" }
            else { return }
            let rounded = Int(pct.rounded())
            out.append(Alert(
                id: "budget:\(window)",
                provider: "all",
                severity: severity,
                kind: "spend_anomaly",
                title: pct >= 100
                    ? "\(label) budget exceeded — \(Format.usd(spent)) of \(Format.usd(budget))"
                    : "\(label) budget at \(rounded)% — \(Format.usd(spent)) of \(Format.usd(budget))",
                detail: "Estimated \(label.lowercased()) spend across all providers is \(Format.usd(spent)) "
                    + "against your \(Format.usd(budget)) budget (\(rounded)%). "
                    + "This is a local list-price estimate, not a bill — and StackPulse only warns; "
                    + "it can't stop a running agent.",
                created_at_unix: snap.generated_at_unix
            ))
        }

        evaluate(window: "daily", label: "Daily", spent: snap.totalTodayCost, budget: dailyBudgetUSD)
        evaluate(window: "monthly", label: "30-day", spent: snap.total30Cost, budget: monthlyBudgetUSD)
        return out
    }

    // MARK: Stack Health enrichment (network: latest versions + advisories)

    /// Latest-version / advisory enrichment, keyed by `Dependency.id`.
    ///
    /// Cached on the store rather than in the view's `@State` on purpose: Stack
    /// Health is an Advisor *tab*, so the view is destroyed and recreated every
    /// time you switch tabs. With the cache in the view, each visit re-fetched one
    /// HTTP request per dependency (≈1,000 GETs to npm/crates.io for 25 projects,
    /// eight at a time) for data it had just downloaded.
    @Published private(set) var stackEnrichment: [String: StackHealthClient.DependencyEnrichment] = [:]
    @Published private(set) var isEnrichingStack = false

    /// Projects whose update check has finished, by project path.
    ///
    /// Tracked separately from `stackEnrichment` because that map is keyed by
    /// dependency, and "we checked this project" is not derivable from it: a
    /// project whose every dep was already fetched for a sibling would look
    /// checked without ever having been asked about.
    @Published private(set) var checkedProjects: Set<String> = []
    /// Projects with a check in flight, by project path.
    @Published private(set) var enrichingProjects: Set<String> = []

    /// Check ONE project's dependencies for updates + advisories.
    ///
    /// Per project, on demand — NOT the whole portfolio. Checking everything meant
    /// **249 registry requests across 35 projects (703 deps)** on every visit to
    /// Stack Health, which is slow enough that the section was effectively unusable
    /// and the network cost was paid for 34 projects the user wasn't asking about.
    /// You check the app you're working on.
    ///
    /// `stackEnrichment` stays keyed by dependency and accumulates: `latest` is a
    /// property of the PACKAGE, so a dep already fetched for another project is
    /// reused rather than re-requested.
    func enrichStack(projectPath: String, force: Bool = false) {
        guard stackCheckUpdates, !enrichingProjects.contains(projectPath) else { return }
        guard let project = stackHealth.first(where: { $0.path == projectPath }) else { return }
        let deps = project.dependencies
        guard !deps.isEmpty else {
            checkedProjects.insert(projectPath) // nothing to check IS a real answer
            return
        }
        // Already checked and not being forced ⇒ nothing to do.
        if !force, checkedProjects.contains(projectPath) { return }

        // Only ask about deps we don't already hold, unless forced. Keyed by the
        // version-scoped `enrichmentKey`, so a dep at a DIFFERENT resolved version
        // than a sibling project's is genuinely re-queried (its advisories differ)
        // rather than skipped and served a wrong-version record.
        let wanted = force ? deps : deps.filter { stackEnrichment[$0.enrichmentKey] == nil }
        guard !wanted.isEmpty else {
            checkedProjects.insert(projectPath)
            return
        }

        enrichingProjects.insert(projectPath)
        isEnrichingStack = true
        Task {
            let result = await StackHealthClient.enrich(wanted)
            self.stackEnrichment.merge(result) { _, new in new }
            self.enrichingProjects.remove(projectPath)
            self.checkedProjects.insert(projectPath)
            self.isEnrichingStack = !self.enrichingProjects.isEmpty
        }
    }

    /// Check every project. Explicit, never automatic — this is the expensive one
    /// (~249 requests here), so it stays a thing the user asks for.
    func enrichAllProjects(force: Bool = false) {
        for project in stackHealth {
            enrichStack(projectPath: project.path, force: force)
        }
    }

    /// Whether this project's updates have been checked.
    func isProjectChecked(_ path: String) -> Bool { checkedProjects.contains(path) }
    /// Whether this project has a check in flight.
    func isProjectEnriching(_ path: String) -> Bool { enrichingProjects.contains(path) }

    /// Drop enrichment (update-checking turned off, or the scan changed).
    ///
    /// Clears `checkedProjects` too: without that, a project would keep claiming it
    /// had been checked using data that no longer exists.
    func clearStackEnrichment() {
        stackEnrichment = [:]
        checkedProjects = []
        enrichingProjects = []
        isEnrichingStack = false
    }

    // MARK: Worktrees (protocol ≥ 1.15.0)

    /// Worktrees per project path, loaded on demand.
    @Published private(set) var worktrees: [String: [Worktree]] = [:]
    /// An honest per-project note from the last worktree op.
    @Published private(set) var worktreeNotes: [String: String] = [:]
    /// Project paths with a worktree op in flight.
    @Published private(set) var worktreeBusy: Set<String> = []

    /// Where StackPulse puts the worktrees it creates:
    /// `~/Library/Application Support/StackPulse/worktrees`.
    ///
    /// Deliberately **outside** the user's project folders — a worktree dropped
    /// next to a repo would be picked up by the project scan and show up as a
    /// bogus new project in Projects and the Launcher.
    var worktreesDir: String {
        let dir = URL(fileURLWithPath: historyDataDir).appendingPathComponent("worktrees", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// Load a project's worktrees off the main actor. Coalesced per project.
    func loadWorktrees(for projectPath: String) {
        guard !worktreeBusy.contains(projectPath) else { return }
        worktreeBusy.insert(projectPath)
        Task.detached(priority: .utility) {
            let result = CoreBridge.listWorktrees(projectPath: projectPath)
            await MainActor.run { self.applyWorktrees(result, for: projectPath) }
        }
    }

    /// Create an isolated worktree for a project (additive; never touches the main
    /// working tree) off the main actor.
    func createWorktree(for projectPath: String, name: String) {
        guard !worktreeBusy.contains(projectPath) else { return }
        worktreeBusy.insert(projectPath)
        let dir = worktreesDir
        Task.detached(priority: .utility) {
            let result = CoreBridge.createWorktree(
                projectPath: projectPath, worktreesDir: dir, name: name)
            await MainActor.run { self.applyWorktrees(result, for: projectPath) }
        }
    }

    private func applyWorktrees(_ result: CoreBridge.WorktreeResult?, for path: String) {
        worktreeBusy.remove(path)
        guard let result else { return }
        worktrees[path] = result.worktrees
        worktreeNotes[path] = result.note
    }

    // MARK: Checkpoints (protocol ≥ 1.14.0)

    /// Checkpoints per project path (newest first), loaded on demand.
    @Published private(set) var checkpoints: [String: [Checkpoint]] = [:]
    /// An honest per-project note from the last op (clean tree, not a repo, …).
    @Published private(set) var checkpointNotes: [String: String] = [:]
    /// Project paths with an op in flight.
    @Published private(set) var checkpointBusy: Set<String> = []

    /// Load a project's checkpoints off the main actor. Coalesced per project.
    func loadCheckpoints(for projectPath: String) {
        guard !checkpointBusy.contains(projectPath) else { return }
        checkpointBusy.insert(projectPath)
        Task.detached(priority: .utility) {
            let result = CoreBridge.listCheckpoints(projectPath: projectPath)
            await MainActor.run { self.applyCheckpoints(result, for: projectPath) }
        }
    }

    /// Capture a new checkpoint (non-destructive) off the main actor.
    func createCheckpoint(for projectPath: String, label: String?) {
        guard !checkpointBusy.contains(projectPath) else { return }
        checkpointBusy.insert(projectPath)
        Task.detached(priority: .utility) {
            let result = CoreBridge.createCheckpoint(projectPath: projectPath, label: label)
            await MainActor.run { self.applyCheckpoints(result, for: projectPath) }
        }
    }

    private func applyCheckpoints(_ result: CoreBridge.CheckpointResult?, for path: String) {
        checkpointBusy.remove(path)
        guard let result else { return }
        checkpoints[path] = result.checkpoints
        checkpointNotes[path] = result.note
    }

    // MARK: Project usage (protocol ≥ 1.13.0)

    /// Per-project spend attribution from the last scan, highest 30-day cost first.
    @Published private(set) var projectUsage: [ProjectUsage] = []
    @Published private(set) var isScanningProjectUsage = false
    @Published private(set) var projectUsageUpdatedAt: Date?
    /// True when the last scan *failed* (as opposed to succeeding with no data).
    /// A failure keeps the previous data and its timestamp — it must never read as
    /// a fresh, clean "nothing here".
    @Published private(set) var projectUsageScanFailed = false

    /// Recompute per-project spend off the main actor. Coalesced.
    func rescanProjectUsage() {
        guard !isScanningProjectUsage else { return }
        isScanningProjectUsage = true
        Task.detached(priority: .utility) {
            let result = CoreBridge.projectUsage()
            await MainActor.run {
                self.isScanningProjectUsage = false
                if let result {
                    self.projectUsage = result
                    self.projectUsageUpdatedAt = Date()
                    self.projectUsageScanFailed = false
                } else {
                    // Scan failed — keep the last good data + timestamp, flag it.
                    self.projectUsageScanFailed = true
                }
            }
        }
    }

    // MARK: Repository Radar (protocol ≥ 1.11.0)

    /// The last Repository Radar report over the approved roots.
    @Published private(set) var radar: RadarReport?
    @Published private(set) var isScanningRadar = false
    @Published private(set) var radarUpdatedAt: Date?
    /// True when the last radar run *failed* (vs. ran and had nothing to flag).
    @Published private(set) var radarScanFailed = false

    /// Run the Repository Radar off the main actor. Coalesced. No-op with no
    /// approved roots (there's nothing to scan yet).
    func rescanRadar() {
        guard !isScanningRadar, !approvedRoots.isEmpty else { return }
        isScanningRadar = true
        let roots = approvedRoots
        Task.detached(priority: .utility) {
            let result = CoreBridge.radar(roots: roots)
            await MainActor.run {
                self.isScanningRadar = false
                if let result {
                    self.radar = result
                    self.radarUpdatedAt = Date()   // stamp freshness only on success
                    self.radarScanFailed = false
                } else {
                    // Failed (roots are non-empty here) — keep the last report and
                    // its timestamp instead of stamping a false "just now".
                    self.radarScanFailed = true
                }
            }
        }
    }

    func refresh() {
        guard !isLoading else { return }
        // Demo mode publishes sample data and never scans or hits the network.
        if demoMode { applyDemoData(); return }
        isLoading = true
        lastError = nil

        let historyDir = historyDataDir

        Task.detached(priority: .utility) {
            // Probe the Keychain here rather than on the main actor: it's a few
            // synchronous XPC round-trips to securityd, and this is the only
            // synchronous XPC on the refresh path.
            let claudeAuthed = KeychainProbe.claudeCredentialsPresent()
            // ONE scan. The core folds this same snapshot into history while it
            // still has it — asking it to `record_history` afterwards would make
            // it build a second snapshot and re-read every log file again.
            let snap = CoreBridge.snapshot(recordHistoryDir: historyDir)
            await MainActor.run {
                self.isLoading = false
                self.lastUpdated = Date()
                if let snap {
                    self.snapshot = snap
                    self.keychainAuthed = claudeAuthed ? ["claude"] : []
                    // Overlay the live, provider-reported readings onto the fresh
                    // core snapshot: Claude's limits, and Cursor's meters (which
                    // exist nowhere else — the core can't see them at all).
                    if self.liveLimitsEnabled {
                        self.fetchAndMergeLiveLimits()
                        self.fetchAndMergeLiveProviders()
                    }
                    // Re-decorate + refresh BYOK provider balances (the fresh core
                    // snapshot carries balance=nil, so cached balances are folded
                    // back in immediately, then refetched).
                    if !self.apiKeyProviderIDs.isEmpty {
                        self.fetchAndMergeBalances()
                    }
                    // History was already recorded by the scan above; just re-read
                    // the accumulated series (cheap — reads the JSON store, no scan).
                    self.loadHistory()
                    // Decide whether anything new warrants a notification. Re-runs
                    // after the async live-limits merge too (see `applyLiveLimits`),
                    // so Claude live-limit alerts are considered once they arrive.
                    self.evaluateNotifications()
                } else {
                    self.lastError = "Could not read usage data from the core."
                }
            }
        }
    }

    // MARK: Usage history (durable Trends store)

    /// Writable directory backing the core's durable history store:
    /// `~/Library/Application Support/StackPulse`, created on first access. Not
    /// sandboxed, so a plain path is fine (no security-scoped bookmark needed).
    var historyDataDir: String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("StackPulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    // MARK: Command runs (captured outcomes / history)

    /// Captured command runs, most-recent first. Persisted to Application Support
    /// so outcomes survive relaunch. Capped to keep the file small.
    @Published private(set) var commandRuns: [CommandRun] = []

    private static let commandRunsCap = 100

    private var commandRunsURL: URL {
        URL(fileURLWithPath: historyDataDir).appendingPathComponent("command_runs.json")
    }

    /// Load persisted runs on launch. Any still marked `running` (the app quit
    /// mid-run) is downgraded to `stopped` so nothing shows a phantom spinner.
    func loadCommandRuns() {
        guard let data = try? Data(contentsOf: commandRunsURL),
              var runs = try? JSONDecoder().decode([CommandRun].self, from: data)
        else { return }
        for i in runs.indices where runs[i].status == .running {
            runs[i].status = .stopped
            runs[i].finishedAtUnix = runs[i].finishedAtUnix ?? runs[i].startedAtUnix
        }
        commandRuns = runs
    }

    /// Insert or update a run (matched by id), newest first, then persist.
    func upsertRun(_ run: CommandRun) {
        if let idx = commandRuns.firstIndex(where: { $0.id == run.id }) {
            commandRuns[idx] = run
        } else {
            commandRuns.insert(run, at: 0)
            if commandRuns.count > Self.commandRunsCap {
                commandRuns.removeLast(commandRuns.count - Self.commandRunsCap)
            }
        }
        persistCommandRuns()
    }

    /// Remove every run from the history and the on-disk store.
    func clearCommandRuns() {
        commandRuns = []
        try? FileManager.default.removeItem(at: commandRunsURL)
    }

    private func persistCommandRuns() {
        let url = commandRunsURL
        let runs = commandRuns
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(runs) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Loads the accumulated history from the durable store (no recording) on a
    /// background task and publishes it. Called once on launch. Silent on any
    /// failure — an empty result leaves `history` as-is.
    private func loadHistory() {
        let dir = historyDataDir
        Task.detached(priority: .utility) {
            let points = CoreBridge.getHistory(dataDir: dir)
            guard !points.isEmpty else { return }
            await MainActor.run { self.history = points }
        }
    }

    /// After a successful refresh, folds today's usage into the durable history
    /// store (seeding from the 30-day analytics on first run) and republishes the
    /// accumulated series. Runs off the main actor; the returned points are
    /// applied on the main actor. Silent on failure — a transient empty result is
    /// ignored so it can't wipe an already-loaded history.
    private func recordHistorySnapshot() {
        let dir = historyDataDir
        Task.detached(priority: .utility) {
            let points = CoreBridge.recordHistory(dataDir: dir)
            guard !points.isEmpty else { return }
            await MainActor.run { self.history = points }
        }
    }

    // MARK: Live-limits fetch + merge

    /// Kicks off an off-main-actor fetch of Claude's live limits and folds the
    /// result into the published snapshot. Silent on every failure. Safe to call
    /// repeatedly — a coalescing flag prevents overlapping requests, and the
    /// result is discarded if the user turns live limits off meanwhile.
    private func fetchAndMergeLiveLimits() {
        guard liveLimitsEnabled else { return }
        guard let snap = snapshot,
              let claude = snap.providers.first(where: { $0.provider == "claude" })
        else { return }

        // 1) Re-apply the last-good limits onto the fresh core snapshot right away,
        //    so a transient fetch failure (e.g. HTTP 429) never blanks the value.
        //    Only the windows that haven't reset yet: a cached percentage for a
        //    window that has already rolled over isn't stale, it's wrong.
        let usable = unexpiredCachedLimits()
        if !usable.isEmpty, cachedLiveLimitsUsable {
            applyLiveLimits(usable)
        }

        // 2) Only hit the network when the cache is stale (or empty) — reusing the
        //    cached value in between keeps StackPulse from rate-limiting the API.
        let cacheFresh = lastGoodLiveLimitsAt
            .map { Date().timeIntervalSince($0) < liveLimitsRefetchInterval } ?? false
        // Throttle on ATTEMPTS, not just successes. `cacheFresh` keys off
        // `lastGoodLiveLimitsAt`, which only advances on a *successful* fetch — so
        // under a sustained 429/offline it would stay false and fire a request
        // every refresh tick (once a minute on the fast cadence), the opposite of
        // backing off. Spacing attempts by the same interval bounds the request
        // rate whether or not the fetch succeeds.
        let attemptFresh = lastLiveFetchAttemptAt
            .map { Date().timeIntervalSince($0) < liveLimitsRefetchInterval } ?? false
        guard !cacheFresh, !attemptFresh, !isFetchingLive else { return }

        let claudeVersion = claude.detected_version
        isFetchingLive = true
        lastLiveFetchAttemptAt = Date()

        // A main-actor Task: the fetch itself is a `nonisolated async` call, so it
        // suspends onto the global executor (Keychain read + network happen off
        // the main thread), then resumes here on the main actor to apply results —
        // no `self` is ever sent across an isolation boundary (Swift 6 clean).
        Task { [weak self] in
            let outcome = await AnthropicUsageClient.fetchClaudeLimits(claudeVersion: claudeVersion)
            guard let self else { return }
            self.isFetchingLive = false
            guard self.liveLimitsEnabled else { return }
            self.liveLimitsUpdatedAt = Date()
            if !outcome.limits.isEmpty {
                self.lastGoodLiveLimits = outcome.limits
                self.lastGoodLiveLimitsAt = Date()
                self.liveLimitsError = nil
                // A caveat rides WITH a successful reading (wrong-login numbers),
                // so it is set here rather than on the failure path, and it keeps
                // the recovery action so the fix stays one click away.
                self.liveLimitsCaveat = outcome.caveat
                self.liveLimitsRecovery = outcome.caveat == nil ? nil : outcome.recovery
                // Persist so the % survives a relaunch / an expired saved token.
                self.persistLiveLimits()
                // Record the reading into the %-trajectory FIRST, so the forecast
                // computed inside applyLiveLimits (for its notification pass) sees
                // the reading just fetched rather than lagging one sample behind.
                self.recordLimitSamples(outcome.limits)
                self.applyLiveLimits(outcome.limits)
            } else {
                // Fetch failed. Stay quiet only while the failure is still
                // plausibly transient (a 429 or a moment offline).
                //
                // This used to suppress the error for as long as ANY cached value
                // was displayable — three days. So a real, persistent condition
                // (an expired login, a revoked Keychain grant) produced no error
                // at all, while the cached percentage kept rendering as if live.
                // Observed doing exactly that: 70 hours of silent failure behind a
                // stale "82%". Suppressing the one message that explains a wrong
                // number is worse than the wrong number.
                let quiet = self.liveLimitsFailureIsStillTransient
                self.liveLimitsError = quiet ? nil : outcome.error
                self.liveLimitsRecovery = quiet ? nil : outcome.recovery
            }
        }
    }

    /// Whether the cached live limits are present and recent enough to display.
    private var cachedLiveLimitsUsable: Bool {
        guard !lastGoodLiveLimits.isEmpty else { return false }
        return SnapshotStore.cachedLimitsAreTrustworthy(
            capturedAt: lastGoodLiveLimitsAt, now: Date(), staleAfter: liveLimitsStaleAfter)
    }

    /// Whether a failed fetch is still young enough to be worth ignoring — the same
    /// bound that governs showing the cached value, because they are the same
    /// question: are we still willing to stand behind the last number we got?
    private var liveLimitsFailureIsStillTransient: Bool {
        SnapshotStore.cachedLimitsAreTrustworthy(
            capturedAt: lastGoodLiveLimitsAt, now: Date(), staleAfter: liveLimitsStaleAfter)
    }

    /// The staleness policy for a cached live-limit value, as a pure function so it
    /// can be proven rather than reasoned about.
    ///
    /// This is the rule that failed in the field: the app showed **82% for 70
    /// hours** after that window had reset. Never captured ⇒ never trustworthy —
    /// `nil` must not read as "fresh".
    /// `nonisolated`: it reads nothing but its arguments, so binding it to the main
    /// actor would only make the rule harder to test than to trust.
    nonisolated static func cachedLimitsAreTrustworthy(capturedAt: Date?, now: Date,
                                                       staleAfter: TimeInterval) -> Bool {
        guard let capturedAt else { return false }
        return now.timeIntervalSince(capturedAt) < staleAfter
    }

    /// Headless proof of the staleness policy above. Pure — no store, no network,
    /// no Keychain. Run by `--selftest-parsers`.
    static func _selftestStaleness() -> Bool {
        let now = Date()
        let hour: TimeInterval = 60 * 60

        // THE regression: the exact failure Jorge hit. A 70-hour-old percentage
        // must never be shown, no matter what its own cached `resets_at` claims —
        // that reset time is part of the same stale snapshot.
        guard !cachedLimitsAreTrustworthy(capturedAt: now.addingTimeInterval(-70 * hour),
                                          now: now, staleAfter: hour) else { return false }
        // A value we've never captured is not fresh by default.
        guard !cachedLimitsAreTrustworthy(capturedAt: nil, now: now, staleAfter: hour)
        else { return false }
        // A momentary blip still rides on the last good value (refetch is 8 min).
        guard cachedLimitsAreTrustworthy(capturedAt: now.addingTimeInterval(-5 * 60),
                                         now: now, staleAfter: hour) else { return false }
        // Just inside / just outside the bound.
        guard cachedLimitsAreTrustworthy(capturedAt: now.addingTimeInterval(-59 * 60),
                                         now: now, staleAfter: hour),
              !cachedLimitsAreTrustworthy(capturedAt: now.addingTimeInterval(-61 * 60),
                                          now: now, staleAfter: hour)
        else { return false }
        return true
    }

    /// The cached limits that are still meaningful, dropping any whose **own reset
    /// time has already passed**.
    ///
    /// A cached percentage is an estimate of a *specific window*. Once that window
    /// resets, the number isn't merely old — it is **known to be wrong**: usage
    /// starts again from zero and a new window begins. Showing it anyway is what
    /// made the app report a stale weekly percentage after the limit had rolled
    /// over, and kept a 5-hour window on screen days after it expired. Age alone
    /// can't catch this: the weekly window legitimately outlives the refetch
    /// interval, while a 5-hour one expires long before the staleness cutoff.
    ///
    /// Dropping is the honest choice — we genuinely don't know the new percentage
    /// until a fetch succeeds, and no number beats a confidently wrong one.
    private func unexpiredCachedLimits(now: Date = Date()) -> [LimitWindow] {
        lastGoodLiveLimits.filter { limit in
            guard let resets = limit.resets_at_unix else { return true } // no window ⇒ can't expire
            return TimeInterval(resets) > now.timeIntervalSince1970
        }
    }

    /// Rebuilds the snapshot so Claude's `limits` = its core limits + the fetched
    /// live limits, deduped by label with the live values winning. Any live
    /// limits from a previous fetch are dropped first, so repeated refreshes
    /// don't stack.
    private func applyLiveLimits(_ live: [LimitWindow]) {
        guard let snap = snapshot else { return }
        let providers = snap.providers.map { p -> ProviderUsage in
            guard p.provider == "claude" else { return p }
            // INVARIANT: the offline core never emits a limit for Claude — Claude's
            // limits exist only here, fetched live over the network, so every
            // `liveProvenance` limit on the Claude provider is one WE added on a
            // previous merge. Dropping them before re-merging is therefore safe: it
            // discards our own stale copies, not a core reading. (Codex is the
            // opposite — its limits come FROM the core with this same provenance —
            // which is exactly why this is scoped to `provider == "claude"`.) If the
            // core ever did report a Claude limit, this filter would strip it; that
            // would be a protocol change, and this is the line to revisit.
            let core = p.limits.filter { $0.provenance != AnthropicUsageClient.liveProvenance }
            return p.replacingLimits(Self.mergeLimits(core: core, live: live))
        }
        snapshot = snap.copy(providers: providers)
        // Latch which windows are on track to run out this cycle, so the forecast
        // alert is sticky (fires once per cycle, not once per rate wobble) before
        // notifications are evaluated below.
        refreshForecastLatch(live)
        // Live limits just landed — reconsider notifications so a Claude weekly/
        // session limit crossing its threshold can alert (the offline core never
        // sees these, so its own alert set can't cover them).
        evaluateNotifications()
    }

    /// Removes any previously-merged live limits from Claude, restoring the
    /// core-only view (used when the user disables live limits).
    private func stripLiveLimits() {
        guard let snap = snapshot else { return }
        var changed = false
        let providers = snap.providers.map { p -> ProviderUsage in
            guard p.provider == "claude" else { return p }
            let core = p.limits.filter { $0.provenance != AnthropicUsageClient.liveProvenance }
            if core.count != p.limits.count { changed = true }
            return p.replacingLimits(core)
        }
        if changed { snapshot = snap.copy(providers: providers) }
    }

    // MARK: - Live provider readings
    //
    // Several providers publish no local usage at all — their real numbers exist
    // only behind an API. Claude keeps its own richer flow above (forecast latch,
    // persisted cache, login recovery); every other live provider shares this one
    // generic path, so adding a provider is a single table entry rather than
    // another copy of the same throttle / merge / strip logic.
    //
    // The shape is the same in all cases: read a LOCAL credential, fetch off the
    // main actor, throttle on ATTEMPTS as well as successes (so a sustained
    // failure backs off), keep the last good reading so a transient failure never
    // blanks a card, and stamp every window with its capture time. Gated on the
    // one `liveLimitsEnabled` network consent.

    /// One provider's live, provider-reported reading.
    struct LiveProviderReading: Sendable {
        var limits: [LimitWindow] = []
        var balance: ProviderBalance?
        var planName: String?
        var error: String?

        var isEmpty: Bool { limits.isEmpty && balance == nil }
        static let empty = LiveProviderReading()
    }

    /// Why a provider's live reading is missing, keyed by provider id. Surfaced on
    /// the card so an absence always carries its reason.
    @Published private(set) var liveProviderErrors: [String: String] = [:]
    /// Plan names the provider APIs reported, keyed by provider id.
    @Published private(set) var liveProviderPlans: [String: String] = [:]

    private var liveReadings: [String: LiveProviderReading] = [:]
    private var liveReadingAt: [String: Date] = [:]
    private var liveAttemptAt: [String: Date] = [:]
    private var inFlightLive: Set<String> = []
    /// The limit labels this store injected per provider — so a strip removes ours
    /// and leaves the core's (Codex reports its own limits with the same
    /// provenance, so provenance alone can't tell them apart).
    private var injectedLiveLabels: [String: Set<String>] = [:]
    /// Same spacing as the Claude fetch — bounds the request rate either way.
    private let liveProviderRefetchInterval: TimeInterval = 8 * 60

    /// Every provider whose reading comes from a live API, with its fetcher.
    /// Claude is deliberately absent — it owns the richer flow above.
    private static let liveFetchers: [(id: String, fetch: @Sendable () async -> LiveProviderReading)] = [
        ("cursor", {
            let o = await CursorUsageClient.fetch()
            return LiveProviderReading(
                limits: o.limits,
                // Cursor reports dollars *spent* beyond the plan; there is no
                // remaining balance to show, so only `used` is set.
                balance: o.extraUsageUSD.map {
                    ProviderBalance(used_usd: $0, currency: "USD", note: "Extra usage (on-demand)")
                },
                planName: o.planName,
                error: o.error
            )
        }),
        // Codex: the API's windows are authoritative and fresher than the ones the
        // core derives from the CLI's logs, so they replace them by label. A window
        // only the logs know about survives the merge.
        ("codex", {
            let o = await CodexLiveUsageClient.fetch()
            return LiveProviderReading(
                limits: o.limits,
                // Flex credits are counted in CREDITS, not dollars — priced at
                // $0.04 each (openusage's rate). Shown as remaining, never as spend.
                //
                // Only when there ARE credits: a plan without the credit system
                // reports a balance of 0, and rendering that as a green "$0.00 left"
                // reads as "you are out of money" when the truth is "this plan has
                // no credits at all". Absence of a credit system is not a zero
                // balance.
                balance: o.creditsBalance.flatMap { credits in
                    credits > 0
                        ? ProviderBalance(remaining_usd: credits * 0.04, currency: "USD",
                                          note: "\(Int(credits)) flex credits")
                        : nil
                },
                planName: o.planType,
                error: o.error
            )
        }),
        // Copilot: per-seat premium-request quota, using the token Copilot/gh
        // already stored locally — no PAT to create. An org-managed seat has no
        // per-user quota, which arrives here as a note, never as 0%.
        ("copilot", {
            let o = await CopilotUsageClient.fetch()
            return LiveProviderReading(
                limits: o.limits,
                balance: o.balance,
                planName: o.planName,
                error: o.error
            )
        }),
        // Antigravity: its own language server, over loopback. No OAuth, no cloud
        // call — and it complements the core's conversation scan with the real
        // 5h/weekly quota buckets the logs can't see.
        ("antigravity", {
            let o = await AntigravityQuotaClient.fetch()
            return LiveProviderReading(limits: o.limits, error: o.error)
        }),
        ("zai", {
            let o = await ZaiUsageClient.fetch()
            return LiveProviderReading(limits: o.limits, planName: o.planName, error: o.error)
        }),
        // Grok's on-demand cap is denominated in CREDITS, not dollars — converting
        // it would fabricate a price, so it stays out of the balance slot.
        ("grok", {
            let o = await GrokUsageClient.fetch()
            return LiveProviderReading(limits: o.limits, planName: o.planName, error: o.error)
        }),
        ("devin", {
            let o = await DevinUsageClient.fetch()
            return LiveProviderReading(
                limits: o.limits, balance: o.balance, planName: o.planName, error: o.error
            )
        }),
    ]

    /// Kick off (or re-apply) every live provider reading for the current snapshot.
    private func fetchAndMergeLiveProviders() {
        guard liveLimitsEnabled, let snap = snapshot else { return }
        for entry in Self.liveFetchers {
            guard snap.providers.contains(where: { $0.provider == entry.id }) else { continue }
            fetchLiveProvider(entry.id, entry.fetch)
        }
    }

    private func fetchLiveProvider(
        _ providerID: String,
        _ fetch: @escaping @Sendable () async -> LiveProviderReading
    ) {
        // 1) Re-apply the last good reading onto the fresh core snapshot at once,
        //    so a transient failure never blanks a card.
        if let cached = liveReadings[providerID], !cached.isEmpty {
            applyLiveReading(cached, to: providerID)
        }

        // 2) Only hit the network when both the cache AND the last attempt are old.
        let cacheFresh = liveReadingAt[providerID]
            .map { Date().timeIntervalSince($0) < liveProviderRefetchInterval } ?? false
        let attemptFresh = liveAttemptAt[providerID]
            .map { Date().timeIntervalSince($0) < liveProviderRefetchInterval } ?? false
        guard !cacheFresh, !attemptFresh, !inFlightLive.contains(providerID) else { return }

        inFlightLive.insert(providerID)
        liveAttemptAt[providerID] = Date()
        Task { [weak self] in
            let reading = await fetch()
            guard let self else { return }
            self.inFlightLive.remove(providerID)
            guard self.liveLimitsEnabled else { return }
            if !reading.isEmpty {
                self.liveReadings[providerID] = reading
                self.liveReadingAt[providerID] = Date()
                self.liveProviderErrors[providerID] = nil
                if let plan = reading.planName { self.liveProviderPlans[providerID] = plan }
                self.applyLiveReading(reading, to: providerID)
            } else {
                // No reading. Report the reason when we have one; keep whatever is
                // already on screen rather than blanking it.
                self.liveProviderErrors[providerID] = reading.error
            }
        }
    }

    /// Injects one provider's live reading (limits + optional balance) onto it.
    ///
    /// Deliberately does NOT strip existing limits by provenance the way the Claude
    /// path does. Codex is the counter-example: the offline core emits ITS limits
    /// with the same `provider_reported` provenance (read from the CLI's logs), so
    /// a provenance filter would delete a real core reading. `mergeLimits` dedups
    /// by label with live winning, which is exactly right — a live window replaces
    /// the log-derived one of the same name, and a window only the core knows about
    /// survives. Re-applying is idempotent, so nothing accumulates.
    private func applyLiveReading(_ reading: LiveProviderReading, to providerID: String) {
        guard let snap = snapshot else { return }
        let providers = snap.providers.map { p -> ProviderUsage in
            guard p.provider == providerID else { return p }
            let withLimits = p.replacingLimits(
                Self.mergeLimits(core: p.limits, live: reading.limits)
            )
            guard let balance = reading.balance else { return withLimits }
            return withLimits.replacingBalance(balance)
        }
        // Remember exactly which labels WE injected, so turning live fetching off
        // can remove ours without taking a core reading with it.
        injectedLiveLabels[providerID] = Set(reading.limits.map(\.label))
        snapshot = snap.copy(providers: providers)
        evaluateNotifications()
    }

    /// Removes every merged live-provider reading, restoring the core-only view
    /// (used when the user turns live fetching off). Strips only the labels this
    /// store actually injected — never a limit the core reported.
    private func stripLiveProviderReadings() {
        guard let snap = snapshot else { return }
        var changed = false
        let providers = snap.providers.map { p -> ProviderUsage in
            guard let injected = injectedLiveLabels[p.provider], !injected.isEmpty || p.balance != nil
            else { return p }
            let kept = p.limits.filter { !injected.contains($0.label) }
            if kept.count != p.limits.count || p.balance != nil { changed = true }
            return p.replacingLimits(kept).replacingBalance(nil)
        }
        injectedLiveLabels = [:]
        if changed { snapshot = snap.copy(providers: providers) }
    }

    /// Merges core + live limits, deduped by label, live winning, order stable
    /// (core labels first in their original order, then any new live labels).
    private static func mergeLimits(core: [LimitWindow], live: [LimitWindow]) -> [LimitWindow] {
        var byLabel: [String: LimitWindow] = [:]
        var order: [String] = []
        for limit in core {
            if byLabel[limit.label] == nil { order.append(limit.label) }
            byLabel[limit.label] = limit
        }
        for limit in live {
            if byLabel[limit.label] == nil { order.append(limit.label) }
            byLabel[limit.label] = limit   // live wins
        }
        return order.compactMap { byLabel[$0] }
    }

    // MARK: BYOK balances — storage + fetch + merge

    /// Seeds `apiKeyProviderIDs` from the Keychain (presence checks only — no
    /// secret is read). Called once on launch.
    private func loadAPIKeyProviders() {
        apiKeyProviderIDs = Set(APIKeyProviders.allIDs.filter { APIKeyStore.hasKey(for: $0) })
    }

    /// The stored base URL for a provider (LiteLLM), or `nil`. Not a secret — the
    /// Settings row prefills its field with this (never the key).
    func baseURL(for providerID: String) -> String? {
        APIKeyStore.readBaseURL(for: providerID)
    }

    /// Saves a provider's API key (and optional base URL), marks it connected,
    /// and immediately fetches its balance. A blank key is ignored.
    func saveAPIKey(_ key: String, for providerID: String, baseURL: String? = nil) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        APIKeyStore.save(key: trimmed, for: providerID)
        if let baseURL { APIKeyStore.saveBaseURL(baseURL, for: providerID) }
        apiKeyProviderIDs.insert(providerID)
        // Clear any stale status before the fresh fetch lands.
        balanceError[providerID] = nil
        fetchBalance(for: providerID)
    }

    /// Updates only the stored base URL for a connected provider (LiteLLM), then
    /// refetches. No-op for a provider without a saved key.
    func saveBaseURL(_ baseURL: String, for providerID: String) {
        guard apiKeyProviderIDs.contains(providerID) else { return }
        APIKeyStore.saveBaseURL(baseURL, for: providerID)
        fetchBalance(for: providerID)
    }

    /// Removes a provider's stored key + base URL, drops its balance state, and
    /// strips any balance already folded onto its snapshot card.
    func clearAPIKey(for providerID: String) {
        APIKeyStore.delete(for: providerID)
        apiKeyProviderIDs.remove(providerID)
        balances[providerID] = nil
        balanceError[providerID] = nil
        balanceUpdatedAt[providerID] = nil
        stripBalance(for: providerID)
    }

    /// Re-applies every cached balance to the (fresh) snapshot, then kicks a
    /// refetch for each connected provider. Called after a core refresh so a new
    /// snapshot — which always has `balance == nil` — keeps its BYOK decoration.
    private func fetchAndMergeBalances() {
        for (id, balance) in balances { applyBalance(balance, for: id) }
        for id in apiKeyProviderIDs { fetchBalance(for: id) }
    }

    /// Fetches one provider's balance off the main actor and folds the result in.
    /// Gated on a saved key and coalesced per provider. Silent, self-healing:
    /// a vanished key just drops the provider from the connected set.
    func fetchBalance(for providerID: String) {
        guard apiKeyProviderIDs.contains(providerID),
              !fetchingBalances.contains(providerID) else { return }
        // Read our OWN Keychain item — non-prompting; held only for this request.
        guard let key = APIKeyStore.read(for: providerID) else {
            apiKeyProviderIDs.remove(providerID)
            return
        }
        let baseURL = APIKeyStore.readBaseURL(for: providerID)
        fetchingBalances.insert(providerID)

        // Main-actor Task: the fetch is a `nonisolated async` call, so the network
        // happens off the main thread; it resumes here to apply results. `self` is
        // never sent across an isolation boundary (Swift 6 clean).
        Task { [weak self] in
            let outcome = await ProviderBalanceClient.fetchBalance(
                providerID: providerID, key: key, baseURL: baseURL
            )
            guard let self else { return }
            self.fetchingBalances.remove(providerID)
            // Ignore a late result if the key was cleared meanwhile.
            guard self.apiKeyProviderIDs.contains(providerID) else { return }
            self.balanceError[providerID] = outcome.error
            self.balanceUpdatedAt[providerID] = Date()
            if let balance = outcome.balance {
                self.balances[providerID] = balance
                self.applyBalance(balance, for: providerID)
            }
        }
    }

    /// Folds a balance onto the matching snapshot provider (if the core surfaces
    /// one). Providers the core doesn't list have no card — their status shows in
    /// Settings from `balances`/`balanceError` instead.
    private func applyBalance(_ balance: ProviderBalance, for providerID: String) {
        guard let snap = snapshot,
              snap.providers.contains(where: { $0.provider == providerID })
        else { return }
        let providers = snap.providers.map { p -> ProviderUsage in
            p.provider == providerID ? p.replacingBalance(balance) : p
        }
        snapshot = snap.copy(providers: providers)
    }

    /// Removes any balance previously folded onto a provider's card (used when
    /// the user clears the key).
    private func stripBalance(for providerID: String) {
        guard let snap = snapshot else { return }
        var changed = false
        let providers = snap.providers.map { p -> ProviderUsage in
            guard p.provider == providerID, p.balance != nil else { return p }
            changed = true
            return p.replacingBalance(nil)
        }
        if changed { snapshot = snap.copy(providers: providers) }
    }

    /// Effective auth state: the core's file-based detection OR the macOS
    /// Keychain probe.
    func isAuthenticated(_ provider: ProviderUsage) -> Bool {
        provider.authenticated || keychainAuthed.contains(provider.provider)
    }

    /// One provider's menu-bar cell: the mark that says *which* AI, plus its
    /// reading(s). Two readings are rendered STACKED (session over weekly), which
    /// is why they stay separate strings rather than one joined label.
    struct MenuBarItem: Identifiable, Equatable {
        let id: String            // provider id — also keys the brand mark
        let symbolName: String    // SF Symbol fallback when there's no vector mark
        let displayName: String   // for the VoiceOver description
        let values: [String]      // 1–2 readings, e.g. ["41%", "34%"] or ["248M"]
    }

    /// A compact, **per-provider** menu-bar readout: a provider icon plus its
    /// reading. Both limit windows are shown when the provider reports two (session
    /// then weekly, e.g. "41%·34%") — seeing only the hottest one hid the fact that
    /// a comfortable session can sit inside a nearly-spent week. Percentages are
    /// **remaining**, matching every card. Falls back to today's token volume for a
    /// provider with no limits. Up to three providers.
    var menuBarItems: [MenuBarItem] {
        guard let snapshot else { return [] }
        var items: [MenuBarItem] = []
        for p in snapshot.providers where p.installed {
            // Only show a percentage we can still call current. Every CARD ages its
            // limit with a `LimitAgeNote`; the menu bar is too small for that, so a
            // stale reading is dropped rather than shown as live. A core-provided
            // limit carries its own `captured_at_unix` and can be hours old
            // (measured at 18.5h on a real machine) — showing that as live in the
            // always-visible menu bar is the exact stale-as-live bug the rest of the
            // app guards against.
            let fresh = p.limits.filter { !$0.isStale(staleAfter: LimitWindow.liveStaleAfter) }
            // A caveated reading (Claude Desktop answering because the Code login
            // is dead) is still the user's OWN live Claude login, and it is the
            // only Claude limit that exists on such a machine — blanking it here
            // left the strip showing nothing at all, which is worse than showing a
            // real number whose source the card names. Only *stale* readings are
            // dropped, above.
            let values: [String]
            if !fresh.isEmpty {
                // Session on top, weekly below (the order people read them in);
                // anything else keeps the provider's own order behind those two.
                let rank: (LimitWindow) -> Int = { l in
                    switch l.label {
                    case "5h", "daily": return 0
                    case "weekly": return 1
                    default: return 2
                    }
                }
                values = fresh
                    .sorted { rank($0) < rank($1) }
                    .prefix(2)
                    .map { "\(Int(Format.limitFraction($0.used_percent) * 100))%" }
            } else if let tokens = p.today?.tokens.grandTotal, tokens > 0 {
                values = [Format.tokens(tokens)]
            } else {
                continue
            }
            items.append(MenuBarItem(id: p.provider,
                                     symbolName: p.symbolName,
                                     displayName: p.display_name,
                                     values: values))
            if items.count >= 3 { break }
        }
        return items
    }

    // MARK: Alerts

    /// Every alert the core reported this snapshot, plus alerts synthesized from
    /// Claude's *live* limits (which the offline core can't see), plus any demo
    /// alerts. Core alerts keep their most-severe-first order; synthesized ones
    /// follow. Drives every needs-attention surface and the notification gate.
    var allAlerts: [Alert] {
        (snapshot?.alerts ?? []) + liveLimitAlerts + limitForecastAlerts + budgetAlerts + demoAlerts
    }

    /// Early-warning alerts: a limit you are **not near yet** but are on pace to
    /// hit before it resets. This is the whole point of forecasting — the
    /// threshold alerts fire at 80%/95%, when it may already be too late to change
    /// course; this fires while there's still room to react.
    ///
    /// Deliberately narrow, so it warns rather than nags:
    /// - only for a window **latched** on-track this cycle (see
    ///   `forecastLatchedCycles`) — so a wobbling rate can't flap the alert and
    ///   re-fire the notification;
    /// - only in the 40–80% band — below 40% the projection is too speculative to
    ///   act on, and at/above 80% `liveLimitAlerts` already owns it, so the two
    ///   never double-fire for the same window.
    ///
    /// The latch is the presence gate; this only formats. Once latched the alert
    /// stays present even if a single reading's forecast dips, which is exactly
    /// what stops the notification gate from treating a wobble as a new event.
    private var limitForecastAlerts: [Alert] {
        guard let snap = snapshot,
              let claude = snap.providers.first(where: { $0.provider == "claude" })
        else { return [] }
        return claude.limits.compactMap { limit -> Alert? in
            guard limit.provenance == AnthropicUsageClient.liveProvenance,
                  limit.used_percent >= 40, limit.used_percent < 80,
                  forecastLatchedCycles.contains(forecastCycleKey(limit))
            else { return nil }
            let pct = Int(limit.used_percent.rounded())
            var detail = "Your Claude \(limit.label) limit is at \(pct)% and, at your current pace, is on track to reach the cap"
            // Use the current projection's hours when it still has one; when a
            // wobble briefly flattens the rate the latch keeps the alert, just
            // without a fresh number.
            if let hours = limitForecast(for: limit).hoursToLimit {
                detail += " in about \(LimitForecast.humanHours(hours))"
            }
            detail += " before it resets."
            if let reset = limit.resets_at_unix, let countdown = Format.resetCountdown(reset) {
                detail += " It \(countdown)."
            }
            return Alert(
                id: "forecast:claude:\(limit.label)",
                provider: "claude",
                severity: "warning",
                kind: "usage_threshold",
                title: "Claude \(limit.label) limit on track to run out",
                detail: detail,
                created_at_unix: snap.generated_at_unix
            )
        }
    }

    /// Needs-attention alerts derived from Claude's live limits. The core is
    /// offline and never sees these, so without this a Claude weekly/session cap
    /// approaching would silently pass. Warning at ≥ 80%, critical at ≥ 95%. Ids
    /// are stable per (provider, label) so the notification gate dedups them like
    /// any core alert, and `created_at` uses the snapshot's own generation time so
    /// the value is stable across renders (no per-render `Date()` churn). Empty
    /// unless live limits are present.
    private var liveLimitAlerts: [Alert] {
        guard let snap = snapshot,
              let claude = snap.providers.first(where: { $0.provider == "claude" })
        else { return [] }
        return claude.limits.compactMap { limit -> Alert? in
            guard limit.provenance == AnthropicUsageClient.liveProvenance else { return nil }
            let pct = Int(limit.used_percent.rounded())
            let severity: String
            if limit.used_percent >= 95 { severity = "critical" }
            else if limit.used_percent >= 80 { severity = "warning" }
            else { return nil }
            var detail = "Your Claude \(limit.label) usage is \(pct)% consumed."
            if let reset = limit.resets_at_unix {
                // `Format.relative` is a PAST-tense formatter ("3h ago"); a reset is
                // in the future, so it collapsed to "just now" for every reset —
                // telling the user their limit resets imminently when it might be
                // days out, in the alert *and* in the macOS notification body.
                // `resetCountdown` is the forward-looking one.
                if let countdown = Format.resetCountdown(reset) {
                    detail += " It \(countdown)."
                }
            }
            return Alert(
                id: "live:claude:\(limit.label)",
                provider: "claude",
                severity: severity,
                kind: "usage_threshold",
                title: "Claude \(limit.label) limit at \(pct)%",
                detail: detail,
                created_at_unix: snap.generated_at_unix
            )
        }
    }

    /// Alerts still needing attention: `allAlerts` minus the acknowledged ones.
    var activeAlerts: [Alert] {
        allAlerts.filter { !acknowledgedAlertIDs.contains($0.id) }
    }

    /// The most severe active alert's severity, or `nil` when all clear.
    var highestActiveSeverity: AlertSeverity? {
        activeAlerts.map(\.severityKind).max()
    }

    /// Count of alerts hidden because the user acknowledged them.
    var acknowledgedCount: Int {
        allAlerts.filter { acknowledgedAlertIDs.contains($0.id) }.count
    }

    func acknowledge(_ id: String) {
        acknowledgedAlertIDs.insert(id)
    }

    func acknowledgeAll() {
        acknowledgedAlertIDs.formUnion(allAlerts.map(\.id))
    }

    /// Un-dismiss everything acknowledged this session.
    func restoreAcknowledged() {
        acknowledgedAlertIDs.removeAll()
    }

    // MARK: Notification evaluation

    /// Runs after every snapshot change to decide which alerts warrant a banner.
    /// Delegates the newly-active/dedup decision to the pure ``NotificationGate``:
    /// the first evaluation seeds silently (no launch burst), then only genuinely
    /// new, high-enough-severity alerts notify. The gate state is kept current even
    /// while notifications are disabled, so re-enabling never fires a backlog.
    private func evaluateNotifications() {
        let eligible = activeAlerts.filter { $0.severityKind >= notifyMinSeverity }
        // Key on severity as well as id. Alert ids are deliberately stable across a
        // severity change (`budget:daily`, `live:claude:weekly`, `claude:usage:5h`
        // all keep one id at warning and at critical) so they dedup properly — but
        // that also meant an *escalation* looked like an already-notified alert and
        // stayed silent. You'd be warned at 85% of budget and never told you blew
        // it; warned at 80% of the weekly limit and never told you hit 96%. The
        // escalation is the notification that actually matters.
        let currentIDs = Set(eligible.map(notificationKey))
        let result = NotificationGate.transition(
            current: currentIDs, alreadyNotified: notifiedAlertIDs, seeded: notificationsSeeded
        )
        notifiedAlertIDs = result.notified
        notificationsSeeded = true

        guard notificationsEnabled, !result.toNotify.isEmpty else { return }
        // Quiet hours mute the banner (Do-Not-Disturb semantics) — the alerts are
        // already marked notified above, so they still surface in-app and won't
        // re-fire once quiet hours end.
        if quietHoursEnabled, isQuietNow() { return }
        for alert in eligible where result.toNotify.contains(notificationKey(alert)) {
            notifications.deliver(alert)
        }
    }

    /// The dedup key for the notification gate: the alert's identity **plus** its
    /// severity, so a warning→critical escalation reads as new rather than as the
    /// same already-notified alert. (Re-crossing the *same* threshold still dedups,
    /// which is the behaviour the id alone was there to give.)
    private func notificationKey(_ alert: Alert) -> String {
        "\(alert.id)#\(alert.severity)"
    }

    /// Whether the current local hour falls inside the configured quiet-hours
    /// window (may wrap midnight).
    private func isQuietNow() -> Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return NotificationGate.isQuiet(hour: hour, start: quietStartHour, end: quietEndHour)
    }

    /// Posts a one-off test banner (requesting permission on first use) so the
    /// user can confirm notifications reach them. Bypasses quiet hours and the
    /// dedup gate intentionally — it's an explicit, on-demand check.
    func sendTestNotification() {
        notifications.sendTest()
    }

    // MARK: Missions (observed AI coding sessions)

    /// Every observed AI coding session this snapshot reports (plus any demo
    /// missions), most-recently-active first as the core ordered them.
    var missions: [Mission] {
        (snapshot?.missions ?? []) + demoMissions
    }

    /// Missions the core currently marks as active.
    var activeMissions: [Mission] {
        missions.filter { $0.statusKind == .active }
    }

    /// Count of active missions — drives the menu-bar indicator and popover block.
    var activeMissionCount: Int {
        activeMissions.count
    }

    // MARK: Insights (derived intelligence)

    /// Every derived insight this snapshot reports, most-useful first as the core
    /// ordered them. Empty until a core new enough (protocol ≥ 1.8.0) emits them.
    var insights: [Insight] {
        snapshot?.insights ?? []
    }

    // MARK: Schema canaries (protocol ≥ 1.18.0)

    /// Every per-provider schema check this snapshot reports, worst status first
    /// as the core ordered them.
    ///
    /// Empty until a core new enough (protocol ≥ 1.18.0) emits them — and empty
    /// means **"nothing was checked"**, never "everything checked out". The
    /// canary surfaces state that difference out loud rather than defaulting to
    /// reassurance.
    ///
    /// A plain passthrough of the snapshot's own array, exactly like ``insights``
    /// and ``missions``: Swift arrays are copy-on-write, so this hands back the
    /// existing buffer instead of building a fresh one per access. That keeps it
    /// safe to read from a view body or an `onChange`/`task(id:)` path — the
    /// scalar helpers below exist so those paths never have to diff an array at
    /// all. (Deliberately *not* the `allAlerts` shape, which concatenates and so
    /// allocates on every read.)
    var canaries: [SchemaCanary] { snapshot?.canaries ?? [] }

    /// How many providers reported drift — i.e. how many are feeding knowably
    /// incomplete numbers into the totals shown everywhere else in the app.
    ///
    /// Counted lazily (no intermediate array) so badge/`onChange` reads stay cheap.
    var driftedCanaryCount: Int {
        canaries.lazy.filter { $0.canaryState == .drifted }.count
    }

    /// How many distinct models were found in the logs that the pricing table
    /// can't price. Their tokens are counted; their cost is absent from every
    /// estimate. Summed without building an intermediate array.
    var unpricedModelCount: Int {
        canaries.reduce(0) { $0 + $1.unpriced_models.count }
    }

    /// True when at least one check found something this app can't fully account
    /// for: drift, or a status this version doesn't recognize.
    ///
    /// Deliberately does **not** count `no_data` — "there was nothing to verify"
    /// is not a problem to escalate. Just as deliberately, a `false` here is not
    /// an all-clear either: it is also `false` when every canary is `no_data`,
    /// and when the core reported no canaries at all. Callers that want to make a
    /// positive claim must look at the canaries themselves (see `CanaryVerdict`
    /// in CanarySection.swift), never at the absence of a concern.
    var canariesNeedAttention: Bool {
        canaries.contains { $0.canaryState == .drifted || $0.canaryState == .unknown }
    }

    /// Reads `STACKPULSE_DEMO_MISSIONS` once; returns a small representative set of
    /// missions (one per status) for previewing, or `[]` when the var is unset.
    private static func loadDemoMissions() -> [Mission] {
        guard ProcessInfo.processInfo.environment["STACKPULSE_DEMO_MISSIONS"] != nil else {
            return []
        }
        let now = Int64(Date().timeIntervalSince1970)
        return [
            Mission(provider: "claude", session_id: "demo-active",
                    status: "active", project_path: "/Users/you/code/stackpulse",
                    project_name: "stackpulse", branch: "main", model: "claude-opus-4-8",
                    started_at_unix: now - 3600, last_activity_unix: now - 8,
                    message_count: 42, last_activity: "Using Edit", tokens_last_hour: 1_500_000,
                    changed_files: ["src/App.tsx", "src/api/client.ts"], last_message_preview: "Add the webhook retry handler",
                    scope_flags: nil),
            Mission(provider: "codex", session_id: "demo-idle",
                    status: "idle", project_path: "/Users/you/code/api",
                    project_name: "api", branch: "feat/webhooks", model: "gpt-5-codex",
                    started_at_unix: now - 5400, last_activity_unix: now - 240,
                    message_count: 17, last_activity: "Ran the test suite", tokens_last_hour: 320_000,
                    changed_files: ["routes/webhooks.ts", "package.json"], last_message_preview: "All tests pass",
                    scope_flags: [ScopeFlag(kind: "dependencies", severity: "notable", label: "Dependencies", files: ["package.json"])]),
            Mission(provider: "claude", session_id: "demo-recent",
                    status: "recent", project_path: "/Users/you/code/marketing-site",
                    project_name: "marketing-site", branch: nil, model: "claude-sonnet-4",
                    started_at_unix: now - 9000, last_activity_unix: now - 1800,
                    message_count: 8, last_activity: "Reading files", tokens_last_hour: 0,
                    changed_files: [], last_message_preview: nil, scope_flags: nil),
            Mission(provider: "cursor", session_id: "demo-stalled",
                    status: "stalled", project_path: "/Users/you/code/legacy-erp",
                    project_name: "legacy-erp", branch: "hotfix/login", model: nil,
                    started_at_unix: now - 12000, last_activity_unix: now - 5400,
                    message_count: 3, last_activity: nil, tokens_last_hour: nil,
                    changed_files: ["auth/login.ts", "auth/session.ts", "auth/middleware.ts"], last_message_preview: "Fixing the login redirect loop",
                    scope_flags: [ScopeFlag(kind: "security", severity: "high", label: "Security / auth code", files: ["auth/login.ts", "auth/session.ts", "auth/middleware.ts"])]),
        ]
    }

    /// Reads `STACKPULSE_DEMO_ALERTS` once; returns a small representative set of
    /// alerts (one per severity) for previewing, or `[]` when the var is unset.
    private static func loadDemoAlerts() -> [Alert] {
        guard ProcessInfo.processInfo.environment["STACKPULSE_DEMO_ALERTS"] != nil else {
            return []
        }
        let now = Int64(Date().timeIntervalSince1970)
        return [
            Alert(id: "demo:codex:usage:5h", provider: "codex", severity: "critical",
                  kind: "usage_threshold", title: "Codex 5h limit at 96%",
                  detail: "The 5h window is 96% consumed — resets in 1h 12m.",
                  created_at_unix: now - 90),
            Alert(id: "demo:claude:reset", provider: "claude", severity: "warning",
                  kind: "limit_reset_soon", title: "Claude weekly limit resets soon",
                  detail: "82% used with the weekly window resetting in under 3 hours.",
                  created_at_unix: now - 1800),
            Alert(id: "demo:gemini:integration", provider: "gemini", severity: "info",
                  kind: "integration_issue", title: "Gemini metrics unavailable",
                  detail: "Detected on this Mac but no local session history to read yet.",
                  created_at_unix: now - 7200),
        ]
    }
}
