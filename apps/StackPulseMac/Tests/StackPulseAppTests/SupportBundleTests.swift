import Foundation
import Testing
@testable import StackPulseApp

/// The support bundle's one job beyond formatting is the guarantee that it leaks
/// nothing. These pin the redaction and the shape a reader (or a maintainer
/// pasting it into an issue) relies on.
@Suite("Support bundle")
struct SupportBundleTests {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)
    private let home = "/Users/jorge"

    private func report(_ groups: [Diagnostics.Group]) -> Diagnostics.Report {
        Diagnostics.Report(groups: groups, generatedAt: now)
    }

    // MARK: Redaction — a username must never ship

    @Test("the home directory is collapsed to ~")
    func homeIsRedacted() {
        let g = Diagnostics.Group(id: "g", title: "G", checks: [
            Diagnostics.Check("f", "Folders", .ok, "watching /Users/jorge/Documents/App Privadas"),
        ])
        let text = SupportBundle.build(report: report([g]), home: home, now: now)
        #expect(!text.contains("/Users/jorge"), "the absolute home path must not appear")
        #expect(text.contains("~/Documents/App Privadas"))
    }

    @Test("a trailing slash on home still redacts")
    func trailingSlashHome() {
        let out = SupportBundle.redact("at /Users/jorge/x", home: "/Users/jorge/")
        #expect(out == "at ~/x")
    }

    @Test("redaction with an empty home is a no-op, not a crash")
    func emptyHomeIsSafe() {
        #expect(SupportBundle.redact("/Users/jorge/x", home: "") == "/Users/jorge/x")
    }

    // MARK: Shape

    @Test("the bundle states its own no-secrets guarantee")
    func statesTheGuarantee() {
        let text = SupportBundle.build(report: report([]), home: home, now: now)
        #expect(text.localizedCaseInsensitiveContains("no credentials"))
        #expect(text.localizedCaseInsensitiveContains("prompts"))
    }

    @Test("issues are listed with their status token and fix")
    func issuesCarryTokenAndFix() {
        let g = Diagnostics.Group(id: "notif", title: "Notifications", checks: [
            Diagnostics.Check("notif", "Notifications", .problem,
                              "blocked by macOS", repair: "allow in System Settings"),
        ])
        let text = SupportBundle.build(report: report([g]), home: home, now: now)
        #expect(text.contains("[FAIL] Notifications: blocked by macOS"))
        #expect(text.contains("fix: allow in System Settings"))
    }

    @Test("the overall line reflects the worst status")
    func overallReflectsWorst() {
        let g = Diagnostics.Group(id: "g", title: "G", checks: [
            Diagnostics.Check("a", "A", .ok, "fine"),
            Diagnostics.Check("b", "B", .problem, "broken", repair: "fix it"),
        ])
        let text = SupportBundle.build(report: report([g]), home: home, now: now)
        #expect(text.contains("overall: FAIL"))
    }

    @Test("a clean report reports overall OK and lists no issues section")
    func cleanReportHasNoIssues() {
        let g = Diagnostics.Group(id: "g", title: "G", checks: [
            Diagnostics.Check("a", "A", .ok, "fine"),
        ])
        let text = SupportBundle.build(report: report([g]), home: home, now: now)
        #expect(text.contains("overall: OK"))
        #expect(!text.contains("== Issues =="))
    }
}
