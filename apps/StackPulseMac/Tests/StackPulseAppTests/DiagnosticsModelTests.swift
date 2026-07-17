import Foundation
import Testing
@testable import StackPulseApp

/// The diagnostics report is only worth anything if its verdicts are honest — so
/// these pin the rules that keep it from lying in either direction: a `problem`
/// that isn't real, or an all-clear that papers over one.
@Suite("Diagnostics model")
struct DiagnosticsModelTests {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    /// A baseline where everything that can pass, passes. Individual tests break
    /// one thing so the failure is unambiguous.
    private func healthy() -> Diagnostics.Inputs {
        Diagnostics.Inputs(
            appVersion: "0.39.0", coreVersion: "0.1.0", protocolVersion: "1.20.0",
            lastUpdated: now.addingTimeInterval(-60), lastError: nil,
            refreshModeLabel: "every 2 minutes",
            providersDetected: 3, providersAuthenticated: 3, providersDegraded: 0,
            liveLimitsEnabled: true, liveLimitsHaveData: true,
            liveLimitsError: nil, liveLimitsFixIsRenewLogin: false,
            canaryDrifted: 0, canaryOk: 3, canaryNoData: 0, driftDetail: nil,
            notificationsEnabled: true, notificationsAuthorized: true,
            keepAwake: false,
            approvedRootCount: 4, projectCount: 30, projectsError: nil,
            now: now
        )
    }

    private func check(_ report: Diagnostics.Report, _ id: String) -> Diagnostics.Check? {
        report.groups.flatMap(\.checks).first { $0.id == id }
    }

    // MARK: The two failure directions

    @Test("a fully healthy machine reports all-clear with zero issues")
    func healthyIsAllClear() {
        let r = Diagnostics.build(healthy())
        #expect(r.allClear)
        #expect(r.issues.isEmpty)
        #expect(r.worstStatus >= .ok)
    }

    @Test("notApplicable and info never break all-clear")
    func offFeaturesAreNotProblems() {
        // Everything optional turned off. Nothing is *wrong* — it's just not on.
        var i = healthy()
        i.liveLimitsEnabled = false     // -> notApplicable
        i.notificationsEnabled = false  // -> notApplicable
        i.keepAwake = false             // -> info
        let r = Diagnostics.build(i)
        #expect(r.allClear, "an off feature is not a problem")
        #expect(r.issues.isEmpty)
        #expect(check(r, "claude-cred")?.status == .notApplicable)
    }

    // MARK: Credentials

    @Test("an expired Claude login is a problem with the renew-login repair")
    func expiredLoginIsAProblem() {
        var i = healthy()
        i.liveLimitsHaveData = false
        i.liveLimitsError = "Claude's saved login has expired."
        i.liveLimitsFixIsRenewLogin = true
        let r = Diagnostics.build(i)
        let c = check(r, "claude-cred")
        #expect(c?.status == .problem)
        #expect(c?.repair?.contains("claude") == true)
        #expect(!r.allClear)
        #expect(r.issues.contains { $0.id == "claude-cred" })
    }

    @Test("live limits off is not a problem — it's the offline state working as asked")
    func liveLimitsOffIsNotAProblem() {
        var i = healthy()
        i.liveLimitsEnabled = false
        let c = check(Diagnostics.build(i), "claude-cred")
        #expect(c?.status == .notApplicable)
        #expect(c?.repair == nil)
    }

    // MARK: Notifications — the classic silent failure

    @Test("notifications on but unauthorized is a problem, not a quiet OK")
    func notificationsBlockedIsAProblem() {
        var i = healthy()
        i.notificationsAuthorized = false
        let c = check(Diagnostics.build(i), "notif")
        #expect(c?.status == .problem)
        #expect(c?.repair?.localizedCaseInsensitiveContains("System Settings") == true)
    }

    @Test("notifications off is not a problem")
    func notificationsOffIsNotAProblem() {
        var i = healthy()
        i.notificationsEnabled = false
        #expect(check(Diagnostics.build(i), "notif")?.status == .notApplicable)
    }

    // MARK: Refresh

    @Test("a failed last scan is a problem")
    func failedScanIsAProblem() {
        var i = healthy()
        i.lastError = "the core returned an error"
        #expect(check(Diagnostics.build(i), "refresh")?.status == .problem)
    }

    @Test("a stale scan is a warning, not a failure")
    func staleScanIsAWarning() {
        var i = healthy()
        i.lastUpdated = now.addingTimeInterval(-3600) // an hour old, past staleAfter
        #expect(check(Diagnostics.build(i), "refresh")?.status == .warning)
    }

    // MARK: Data integrity

    @Test("a drifted canary is a warning that says the numbers are incomplete")
    func driftIsAWarning() {
        var i = healthy()
        i.canaryDrifted = 1
        i.driftDetail = "an unpriced model was seen"
        let c = check(Diagnostics.build(i), "canary")
        #expect(c?.status == .warning)
        #expect(c?.detail == "an unpriced model was seen")
    }

    @Test("nothing to verify reads as notApplicable, never as OK")
    func noCanaryDataIsNotOK() {
        // no_data is explicitly not ok — "nothing was checked" is a different claim
        // from "everything checked out", and only one earns a green.
        var i = healthy()
        i.canaryOk = 0
        i.canaryDrifted = 0
        i.canaryNoData = 2
        #expect(check(Diagnostics.build(i), "canary")?.status == .notApplicable)
    }

    // MARK: Folders

    @Test("no watched folders is a warning with an add-a-folder repair")
    func noFoldersIsAWarning() {
        var i = healthy()
        i.approvedRootCount = 0
        i.projectCount = 0
        let c = check(Diagnostics.build(i), "folders")
        #expect(c?.status == .warning)
        #expect(c?.repair?.localizedCaseInsensitiveContains("folder") == true)
    }

    // MARK: The derived value — issues, worst first

    @Test("issues are ranked problems-before-warnings")
    func issuesAreRankedWorstFirst() {
        var i = healthy()
        i.notificationsAuthorized = false   // problem
        i.canaryDrifted = 1                 // warning
        i.approvedRootCount = 0             // warning
        let issues = Diagnostics.build(i).issues
        #expect(issues.first?.status == .problem, "a problem must sort ahead of any warning")
        #expect(issues.count == 3)
        #expect(issues.filter { $0.status == .warning }.count == 2)
    }

    @Test("every problem and warning carries a repair step")
    func everyIssueHasARepair() {
        var i = healthy()
        i.lastError = "scan failed"
        i.notificationsAuthorized = false
        i.approvedRootCount = 0
        for issue in Diagnostics.build(i).issues {
            #expect(issue.repair != nil, "\(issue.id) is an issue with no way to fix it")
        }
    }

    @Test("a repair step on an ok or info check is dropped")
    func okChecksNeverCarryRepair() {
        // Guards the Check initializer's own rule: a fix on a passing check is a
        // contradiction and must not render.
        let c = Diagnostics.Check("x", "X", .ok, "fine", repair: "do something")
        #expect(c.repair == nil)
    }
}
