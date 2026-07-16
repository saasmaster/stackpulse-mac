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
            } else {
                // Fully offline again: drop the fetched limits, cache, and any note.
                stripLiveLimits()
                lastGoodLiveLimits = []
                lastGoodLiveLimitsAt = nil
                liveLimitsError = nil
                liveLimitsUpdatedAt = nil
                try? FileManager.default.removeItem(at: liveLimitsCacheURL)
            }
        }
    }

    /// A short, user-facing note when the last live fetch couldn't produce data
    /// (offline, signed out, etc). Never contains the token or raw response.
    @Published private(set) var liveLimitsError: String?

    /// When the last live-limits fetch completed (success or handled failure).
    @Published private(set) var liveLimitsUpdatedAt: Date?

    /// Coalesces overlapping live fetches.
    private var isFetchingLive = false

    /// The last successfully-fetched live limits + when. Persisted to disk (see
    /// `persistLiveLimits`/`loadPersistedLiveLimits`) so the last-known % survives
    /// an app restart AND a stale/expired Claude Code token — rather than the card
    /// blanking to a "sign in" message. Re-applied on every refresh; a transient
    /// failure (HTTP 429, offline, expired token) keeps showing it, labeled "as of".
    private var lastGoodLiveLimits: [LimitWindow] = []
    private var lastGoodLiveLimitsAt: Date?
    /// Minimum time between actual network fetches — the cached value is reused in
    /// between, so frequent refreshes never rate-limit the provider.
    private let liveLimitsRefetchInterval: TimeInterval = 8 * 60
    /// Keep showing the last-known limits (clearly labeled "as of …") for up to
    /// this long when a fresh fetch can't be had. Generous because Claude's
    /// dominant window is weekly (slow-moving) and a stale-but-labeled % beats a
    /// blank card that reads as "signed out".
    private let liveLimitsStaleAfter: TimeInterval = 3 * 24 * 60 * 60

    /// How long a *failing* fetch stays unreported. Shorter than
    /// `liveLimitsStaleAfter` on purpose: how long we'll SHOW a cached number and
    /// how long we'll stay SILENT about not being able to refresh it are different
    /// questions, and conflating them hid a 70-hour failure behind a stale "82%".
    private let liveLimitsErrorGrace: TimeInterval = 60 * 60

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
    }

    /// `~/Library/Application Support/StackPulse/live_limits_cache.json`.
    private var liveLimitsCacheURL: URL {
        URL(fileURLWithPath: historyDataDir).appendingPathComponent("live_limits_cache.json")
    }

    /// Writes the last-good limits to disk so they survive a relaunch. No-op when
    /// there's nothing good to save.
    private func persistLiveLimits() {
        guard !lastGoodLiveLimits.isEmpty, let at = lastGoodLiveLimitsAt else { return }
        let cache = LiveLimitsCache(limits: lastGoodLiveLimits, at: at.timeIntervalSince1970)
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
                self.projectsUpdatedAt = Date()
                self.projects = found
                self.projectsError = found.isEmpty
                    ? "No projects with recognizable commands were found in the selected folder\(roots.count == 1 ? "" : "s")."
                    : nil
            }
        }
    }

    // MARK: Stack Health (dependency/security intelligence, protocol ≥ 1.9.0)

    /// Per-project dependency/stack health from the last scan (most-actionable
    /// first). Empty until a scan runs (needs approved roots).
    @Published private(set) var stackHealth: [ProjectStack] = []
    @Published private(set) var isScanningStack = false
    @Published private(set) var stackUpdatedAt: Date?

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
                self.stackUpdatedAt = Date()
                self.stackHealth = result
            }
        }
    }

    // MARK: Services & runtime (running dev servers, protocol ≥ 1.9.0)

    /// Locally-running dev servers/services from the last detection.
    @Published private(set) var services: [RunningService] = []
    @Published private(set) var isScanningServices = false
    @Published private(set) var servicesUpdatedAt: Date?

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
                self.servicesUpdatedAt = Date()
                self.services = result
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

    /// Fetch latest versions + advisories for the current stack, unless we already
    /// have them or a fetch is in flight. `force` re-fetches after a fresh scan.
    func enrichStack(force: Bool = false) {
        guard stackCheckUpdates, !isEnrichingStack else { return }
        if force { stackEnrichment = [:] }
        guard stackEnrichment.isEmpty else { return } // already have it
        let deps = stackHealth.flatMap(\.dependencies)
        guard !deps.isEmpty else { return }
        isEnrichingStack = true
        Task {
            let result = await StackHealthClient.enrich(deps)
            self.stackEnrichment = result
            self.isEnrichingStack = false
        }
    }

    /// Drop enrichment (update-checking turned off, or the scan changed).
    func clearStackEnrichment() {
        stackEnrichment = [:]
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

    /// Recompute per-project spend off the main actor. Coalesced.
    func rescanProjectUsage() {
        guard !isScanningProjectUsage else { return }
        isScanningProjectUsage = true
        Task.detached(priority: .utility) {
            let result = CoreBridge.projectUsage()
            await MainActor.run {
                self.isScanningProjectUsage = false
                self.projectUsageUpdatedAt = Date()
                self.projectUsage = result
            }
        }
    }

    // MARK: Repository Radar (protocol ≥ 1.11.0)

    /// The last Repository Radar report over the approved roots.
    @Published private(set) var radar: RadarReport?
    @Published private(set) var isScanningRadar = false
    @Published private(set) var radarUpdatedAt: Date?

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
                self.radarUpdatedAt = Date()
                if let result { self.radar = result }
            }
        }
    }

    func refresh() {
        guard !isLoading else { return }
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
                    // Overlay Claude's live limits onto the fresh core snapshot.
                    if self.liveLimitsEnabled {
                        self.fetchAndMergeLiveLimits()
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
        guard !cacheFresh, !isFetchingLive else { return }

        let claudeVersion = claude.detected_version
        isFetchingLive = true

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
                self.applyLiveLimits(outcome.limits)
                // Persist so the % survives a relaunch / an expired saved token.
                self.persistLiveLimits()
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
                self.liveLimitsError = self.liveLimitsFailureIsStillTransient ? nil : outcome.error
            }
        }
    }

    /// Whether the cached live limits are present and recent enough to display.
    ///
    /// Displaying is a lower bar than staying silent: a stale value is fine to show
    /// **because ``LiveLimitsAgeNote`` states its age**, but it is never a reason to
    /// hide why it's stale. See `liveLimitsFailureIsStillTransient`.
    private var cachedLiveLimitsUsable: Bool {
        guard !lastGoodLiveLimits.isEmpty, let at = lastGoodLiveLimitsAt else { return false }
        return Date().timeIntervalSince(at) < liveLimitsStaleAfter
    }

    /// Whether a failed fetch is still young enough to be worth ignoring.
    ///
    /// The refetch interval is 8 minutes, so this grace covers several consecutive
    /// failures — enough to ride out a rate-limit or a closed laptop — without ever
    /// letting a persistent problem hide behind a cached number.
    private var liveLimitsFailureIsStillTransient: Bool {
        guard let at = lastGoodLiveLimitsAt else { return false }
        return Date().timeIntervalSince(at) < liveLimitsErrorGrace
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
            let core = p.limits.filter { $0.provenance != AnthropicUsageClient.liveProvenance }
            return p.replacingLimits(Self.mergeLimits(core: core, live: live))
        }
        snapshot = snap.copy(providers: providers)
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

    /// A compact, **per-provider** menu-bar readout: one labeled token per active
    /// provider — its hottest live-limit % when it has one (e.g. "Cx 9%"), else
    /// today's token volume (e.g. "Cl 248M"). Up to three providers, so the
    /// number is never ambiguous about which AI it belongs to.
    var menuBarText: String {
        guard let snapshot else { return "…" }
        var parts: [String] = []
        for p in snapshot.providers where p.installed {
            let code = p.shortCode
            if let hottest = p.limits.max(by: { $0.used_percent < $1.used_percent }) {
                parts.append("\(code) \(Int(hottest.used_percent.rounded()))%")
            } else if let tokens = p.today?.tokens.grandTotal, tokens > 0 {
                parts.append("\(code) \(Format.tokens(tokens))")
            } else {
                continue
            }
            if parts.count >= 3 { break }
        }
        return parts.joined(separator: "  ")
    }

    // MARK: Alerts

    /// Every alert the core reported this snapshot, plus alerts synthesized from
    /// Claude's *live* limits (which the offline core can't see), plus any demo
    /// alerts. Core alerts keep their most-severe-first order; synthesized ones
    /// follow. Drives every needs-attention surface and the notification gate.
    var allAlerts: [Alert] {
        (snapshot?.alerts ?? []) + liveLimitAlerts + budgetAlerts + demoAlerts
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
