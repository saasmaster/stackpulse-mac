import Foundation

/// The "is StackPulse actually working, and if not, exactly why" model.
///
/// It is deliberately **pure**: `build(_:)` takes a snapshot of what the app
/// already knows and returns a report, so the same inputs always produce the same
/// screen and every check can be tested without a running app. Nothing here
/// samples the clock, reads the Keychain, or touches the network — the signal was
/// gathered by the surfaces that own it, and this only interprets it.
///
/// Its rules are the same ones the rest of the project lives by:
/// - `notApplicable` is never folded into `ok`. "Live limits are off" and "live
///   limits work" are different claims, and only one is a clean bill of health.
/// - a check reports what was measured, never a guess. Where StackPulse cannot
///   verify something (a folder still being readable, a manifest that isn't built),
///   it says so rather than assuming the happy answer.
/// - every non-`ok` check carries a concrete repair step, because a diagnostics
///   screen that only says "something is wrong" is a dead end.
enum Diagnostics {

    /// A check's verdict. Ordered worst-first so `Known issues` can rank by it.
    enum Status: Int, Comparable, Sendable {
        case problem = 0     // broken now; a feature the user expects isn't working
        case warning = 1     // degraded or at risk; still functioning
        case ok = 2          // verified working
        case info = 3        // neither good nor bad — a fact worth showing
        case notApplicable = 4  // nothing to check here (a feature is off / not built)

        static func < (l: Status, r: Status) -> Bool { l.rawValue < r.rawValue }

        var label: String {
            switch self {
            case .problem: return "Problem"
            case .warning: return "At risk"
            case .ok: return "OK"
            case .info: return "Info"
            case .notApplicable: return "N/A"
            }
        }

        /// A short machine token for the support bundle, where color can't carry it.
        var token: String {
            switch self {
            case .problem: return "FAIL"
            case .warning: return "WARN"
            case .ok: return "OK"
            case .info: return "INFO"
            case .notApplicable: return "N/A"
            }
        }
    }

    /// One line item. `detail` is human, never a secret and never a path (paths are
    /// redacted before they reach here). `repair` is present exactly when a
    /// `problem`/`warning` has a concrete fix the user can take.
    struct Check: Identifiable, Equatable, Sendable {
        let id: String
        let label: String
        let status: Status
        let detail: String
        let repair: String?

        init(_ id: String, _ label: String, _ status: Status, _ detail: String, repair: String? = nil) {
            self.id = id
            self.label = label
            self.status = status
            self.detail = detail
            // A repair step on an `ok`/`info` line is a contradiction — nothing to fix.
            self.repair = (status == .problem || status == .warning) ? repair : nil
        }
    }

    struct Group: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let checks: [Check]
    }

    /// The whole report. `issues` is derived, not authored: it is every `problem`
    /// and `warning` across the groups, worst first — the one part of the screen a
    /// user in a hurry actually needs.
    struct Report: Equatable, Sendable {
        let groups: [Group]
        let generatedAt: Date

        /// Problems and warnings, worst first, then in the order they appear. This
        /// is the derived value — the screen leads with it so "what's wrong and how
        /// do I fix it" is answered before any healthy check is scrolled past.
        var issues: [Check] {
            groups.flatMap(\.checks)
                .filter { $0.status == .problem || $0.status == .warning }
                .sorted { $0.status < $1.status }
        }

        var worstStatus: Status {
            groups.flatMap(\.checks).map(\.status).min() ?? .ok
        }

        /// True only when every check is a clean bill — no problems, no warnings.
        /// `info`/`notApplicable` don't count against it; a `warning` does.
        var allClear: Bool { worstStatus >= .ok }
    }

    // MARK: Inputs

    /// A frozen view of everything the report reads. Passed in so the model stays
    /// pure and the surfaces that own each signal remain its single source.
    struct Inputs: Sendable {
        var appVersion: String
        var coreVersion: String
        var protocolVersion: String

        // Refresh
        var lastUpdated: Date?
        var lastError: String?
        var refreshModeLabel: String
        /// A snapshot older than this reads as stale (matches the app's own idea of
        /// "getting old" for the header meta).
        var snapshotStaleAfter: TimeInterval = 15 * 60

        // Providers (folded from the snapshot)
        var providersDetected: Int
        var providersAuthenticated: Int
        var providersDegraded: Int

        // Claude live limits / credential usability
        var liveLimitsEnabled: Bool
        var liveLimitsHaveData: Bool
        var liveLimitsError: String?
        /// True when the concrete fix is "run `claude` in Terminal".
        var liveLimitsFixIsRenewLogin: Bool

        // Data integrity (canaries)
        var canaryDrifted: Int
        var canaryOk: Int
        var canaryNoData: Int
        var driftDetail: String?

        // Notifications
        var notificationsEnabled: Bool
        var notificationsAuthorized: Bool

        // Background
        var keepAwake: Bool

        // Folders / projects
        var approvedRootCount: Int
        var projectCount: Int
        var projectsError: String?

        var now: Date
    }

    // MARK: Build

    static func build(_ i: Inputs) -> Report {
        Report(
            groups: [
                versionsGroup(i),
                refreshGroup(i),
                providersGroup(i),
                credentialsGroup(i),
                dataIntegrityGroup(i),
                notificationsGroup(i),
                accessGroup(i),
                platformGroup(i),
            ],
            generatedAt: i.now
        )
    }

    private static func versionsGroup(_ i: Inputs) -> Group {
        Group(id: "versions", title: "Versions", checks: [
            Check("app", "App", .info, "StackPulse \(i.appVersion)"),
            Check("core", "Portable core", .info, i.coreVersion),
            Check("protocol", "Protocol", .info, i.protocolVersion),
        ])
    }

    private static func refreshGroup(_ i: Inputs) -> Group {
        let refresh: Check
        if let err = i.lastError {
            refresh = Check("refresh", "Last scan", .problem,
                            "The most recent scan failed: \(err)",
                            repair: "Refresh again (⌘R or the refresh button); if it keeps failing, quit and reopen StackPulse.")
        } else if let at = i.lastUpdated {
            let age = i.now.timeIntervalSince(at)
            if age > i.snapshotStaleAfter {
                refresh = Check("refresh", "Last scan", .warning,
                                "The data on screen is \(coarseAge(age)) old.",
                                repair: "Refresh to re-read your logs, or raise the refresh cadence in Settings.")
            } else {
                refresh = Check("refresh", "Last scan", .ok, "Scanned \(coarseAge(age)) ago.")
            }
        } else {
            refresh = Check("refresh", "Last scan", .warning,
                            "No scan has completed yet.",
                            repair: "Open the app and let the first scan finish, or press refresh.")
        }
        return Group(id: "refresh", title: "Data refresh", checks: [
            refresh,
            Check("cadence", "Refresh cadence", .info, i.refreshModeLabel),
        ])
    }

    private static func providersGroup(_ i: Inputs) -> Group {
        var checks: [Check] = [
            Check("detected", "Providers detected", .info,
                  "\(i.providersDetected) detected · \(i.providersAuthenticated) authenticated on this Mac."),
        ]
        if i.providersDegraded > 0 {
            checks.append(Check(
                "degraded", "Provider health", .warning,
                "\(i.providersDegraded) provider\(i.providersDegraded == 1 ? " reports" : "s report") degraded integration health.",
                repair: "Open Integrations to see which provider and why."))
        } else if i.providersDetected > 0 {
            checks.append(Check("degraded", "Provider health", .ok, "Every detected provider reports healthy."))
        }
        return Group(id: "providers", title: "Providers", checks: checks)
    }

    private static func credentialsGroup(_ i: Inputs) -> Group {
        // Credential *usability* is reported as the actual outcome of trying to use
        // it (the live-limits fetch), not as "a file exists" — presence is not the
        // same as a working token, and this screen must not imply it is.
        let check: Check
        if !i.liveLimitsEnabled {
            check = Check("claude-cred", "Claude live limits", .notApplicable,
                          "Live limits are turned off — no credential is read, and the app stays fully offline.")
        } else if let err = i.liveLimitsError {
            check = Check("claude-cred", "Claude live limits", .problem, err,
                          repair: i.liveLimitsFixIsRenewLogin
                          ? "Run `claude` once in Terminal to renew its saved login. StackPulse never changes your login itself."
                          : "Open Settings → turn live limits off and on, or check your network. The token is only sent to api.anthropic.com.")
        } else if i.liveLimitsHaveData {
            check = Check("claude-cred", "Claude live limits", .ok,
                          "A valid token was read and live limits are current.")
        } else {
            check = Check("claude-cred", "Claude live limits", .warning,
                          "Live limits are on but no reading has arrived yet.",
                          repair: "Give the next refresh a moment; if it never fills in, run `claude` once in Terminal.")
        }
        return Group(id: "credentials", title: "Credentials", checks: [check])
    }

    private static func dataIntegrityGroup(_ i: Inputs) -> Group {
        let check: Check
        if i.canaryDrifted > 0 {
            check = Check("canary", "What we read vs. understood", .warning,
                          i.driftDetail ?? "\(i.canaryDrifted) provider's logs contained something this core doesn't fully understand — the numbers are incomplete in a way we can name.",
                          repair: "Open Data Checks for the specifics; the shown totals are knowably incomplete until this is resolved.")
        } else if i.canaryOk > 0 {
            check = Check("canary", "What we read vs. understood", .ok,
                          "Everything in the scanned logs was understood (\(i.canaryOk) checked).")
        } else {
            // No canary said OK and none drifted → nothing local to verify.
            check = Check("canary", "What we read vs. understood", .notApplicable,
                          "No recent local activity to verify — nothing was scanned.")
        }
        return Group(id: "integrity", title: "Data integrity", checks: [check])
    }

    private static func notificationsGroup(_ i: Inputs) -> Group {
        let check: Check
        if !i.notificationsEnabled {
            check = Check("notif", "Notifications", .notApplicable, "Turned off in Settings.")
        } else if i.notificationsAuthorized {
            check = Check("notif", "Notifications", .ok, "Enabled and permitted by macOS.")
        } else {
            check = Check("notif", "Notifications", .problem,
                          "Notifications are on in StackPulse but macOS hasn't granted permission, so none can be delivered.",
                          repair: "Allow StackPulse in System Settings → Notifications.")
        }
        return Group(id: "notifications", title: "Notifications", checks: [check])
    }

    private static func accessGroup(_ i: Inputs) -> Group {
        let folders: Check
        if i.approvedRootCount == 0 {
            folders = Check("folders", "Watched folders", .warning,
                            "No folders added — Projects, Launcher, Stack Health and Services have nothing to show.",
                            repair: "Add a folder (a project, or a parent folder of several) in Projects.")
        } else {
            // Honesty: we don't re-stat each root here (that's I/O this pure model
            // won't do), so this reports the count and defers a per-folder read
            // error to `projectsError` rather than claiming each root is readable.
            folders = Check("folders", "Watched folders", .ok,
                            "\(i.approvedRootCount) folder\(i.approvedRootCount == 1 ? "" : "s") watched · \(i.projectCount) project\(i.projectCount == 1 ? "" : "s") found.")
        }
        var checks = [folders]
        if let err = i.projectsError {
            checks.append(Check("scan", "Project scan", .warning,
                                "The last project scan reported: \(err)",
                                repair: "Confirm the folder still exists and StackPulse still has permission to read it."))
        }
        return Group(id: "access", title: "Folder access", checks: checks)
    }

    private static func platformGroup(_ i: Inputs) -> Group {
        Group(id: "platform", title: "Platform", checks: [
            Check("keepawake", "Keep awake", i.keepAwake ? .info : .info,
                  i.keepAwake ? "On — the display can sleep, but the system won't idle-sleep." : "Off."),
            // Reported honestly as not-built rather than faking a version: the
            // compatibility manifest is a designed-but-unbuilt feature, and a
            // diagnostics screen inventing a version for it would be the exact
            // dishonesty it exists to catch.
            Check("manifest", "Compatibility manifest", .notApplicable,
                  "Not used in this build — the app runs on compiled-in defaults."),
        ])
    }

    // MARK: Helpers

    /// Coarse, human age. Deliberately not precise — a diagnostics line wants
    /// "3 hours", not "2h 58m 11s".
    static func coarseAge(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 90 { return "moments" }
        if s < 3600 { return "\(Int(s / 60)) min" }
        if s < 86_400 {
            let h = Int(s / 3600)
            return "\(h) hour\(h == 1 ? "" : "s")"
        }
        let d = Int(s / 86_400)
        return "\(d) day\(d == 1 ? "" : "s")"
    }
}
