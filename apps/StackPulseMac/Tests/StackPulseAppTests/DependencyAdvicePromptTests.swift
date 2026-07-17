import Foundation
import Testing
@testable import StackPulseApp

/// The prompt hands StackPulse's findings to something that can judge them.
/// StackPulse reads manifests and lockfiles; it never reads a changelog or the
/// project's source, so it cannot say whether a bump is safe or whether an
/// advisory reaches production here. That is the whole reason this exists.
///
/// These tests pin the parts that keep it from being confidently wrong: the age
/// of the readings, the boundary of what was not examined, and the absence of any
/// claim StackPulse didn't measure.
@Suite("Dependency advice prompt")
struct DependencyAdvicePromptTests {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func project(checkedAt: Date?) -> DependencyAdvicePrompt.Project {
        .init(
            name: "trencito",
            path: "/Users/j/Documents/App Privadas/trencito",
            ecosystem: "npm",
            packageManager: "npm",
            checkedAt: checkedAt
        )
    }

    private func lodash(advisories: [DependencyAdvicePrompt.Fact.Advisory] = []) -> DependencyAdvicePrompt.Fact {
        .init(
            name: "lodash", ecosystem: "npm", isDev: false,
            required: "^4.17.0", installed: "4.17.20", latest: "4.17.21",
            status: "Minor behind", advisories: advisories
        )
    }

    // MARK: Provenance — the readings have an age, and it is stated

    @Test("a checked project stamps how old the registry reading is")
    func statesTheAgeOfTheReading() {
        let text = DependencyAdvicePrompt.build(
            project: project(checkedAt: now.addingTimeInterval(-2 * 86_400)),
            facts: [lodash()],
            now: now
        )
        #expect(text.contains("2 days ago"))
        #expect(text.contains("claim to verify, not a fact to repeat"))
    }

    @Test("an unchecked project never presents itself as current")
    func uncheckedSaysSo() {
        let text = DependencyAdvicePrompt.build(
            project: project(checkedAt: nil),
            facts: [
                .init(name: "lodash", ecosystem: "npm", isDev: false,
                      required: "^4.17.0", installed: "4.17.20", latest: nil,
                      status: "Unknown", advisories: [])
            ],
            now: now
        )
        #expect(text.contains("No update check has run"))
        // The dangerous inference: no advisories listed because none were fetched,
        // read as "no advisories exist".
        #expect(text.contains("Do not assume a package is fine because no advisory is listed"))
        #expect(!text.contains("claim to verify, not a fact to repeat"),
                "there is no registry reading to caveat when nothing was read")
    }

    // MARK: The boundary — what was never examined

    @Test("the prompt states that no source code was read")
    func statesTheBoundary() {
        let text = DependencyAdvicePrompt.build(
            project: project(checkedAt: now), facts: [lodash()], now: now
        )
        #expect(text.contains("Nothing here read the source code"))
        #expect(text.contains("whether a vulnerable code path is reachable"))
    }

    @Test("the prompt forbids invented versions, CVEs and breaking changes")
    func forbidsFabrication() {
        let text = DependencyAdvicePrompt.build(
            project: project(checkedAt: now), facts: [lodash()], now: now
        )
        #expect(text.contains("Never invent a version, a CVE, a date, or a breaking change"))
        #expect(text.contains("unverified"))
    }

    @Test("\"leave it\" is offered as a real answer")
    func offersLeaveItAsAnOutcome() {
        // Without this, every list of outdated deps reads as a to-do list, which is
        // how a dependency review turns into busywork.
        let text = DependencyAdvicePrompt.build(
            project: project(checkedAt: now), facts: [lodash()], now: now
        )
        #expect(text.contains("**Leave it**"))
        #expect(text.contains("Don't recommend upgrading everything"))
    }

    // MARK: The facts

    @Test("dev scope is carried, because it usually decides whether it matters")
    func carriesDevScope() {
        let text = DependencyAdvicePrompt.build(
            project: project(checkedAt: now),
            facts: [
                .init(name: "vite", ecosystem: "npm", isDev: true,
                      required: "^5.0.0", installed: "5.1.0", latest: "7.0.0",
                      status: "Major behind", advisories: [])
            ],
            now: now
        )
        #expect(text.contains("| `vite` | dev |"))
        #expect(text.contains("not shipped to production"))
    }

    @Test("an advisory is passed as an id and a link, never as a summary")
    func advisoryIsALinkNotASummary() {
        let text = DependencyAdvicePrompt.build(
            project: project(checkedAt: now),
            facts: [lodash(advisories: [
                .init(id: "GHSA-29mw-wpgm-hmr9", severity: "moderate",
                      url: "https://osv.dev/vulnerability/GHSA-29mw-wpgm-hmr9")
            ])],
            now: now
        )
        #expect(text.contains("[GHSA-29mw-wpgm-hmr9](https://osv.dev/vulnerability/GHSA-29mw-wpgm-hmr9)"))
        #expect(text.contains("(moderate)"))
    }

    @Test("an advisory with no URL still names its id")
    func advisoryWithoutURLStillListed() {
        let text = DependencyAdvicePrompt.build(
            project: project(checkedAt: now),
            facts: [lodash(advisories: [.init(id: "OSV-2026-1", severity: "high", url: nil)])],
            now: now
        )
        #expect(text.contains("OSV-2026-1"))
    }

    @Test("a missing version reads as unknown, never as a version")
    func missingVersionIsNotInvented() {
        let text = DependencyAdvicePrompt.build(
            project: project(checkedAt: now),
            facts: [
                .init(name: "left-pad", ecosystem: "npm", isDev: false,
                      required: "^1.0.0", installed: nil, latest: nil,
                      status: "Unknown", advisories: [])
            ],
            now: now
        )
        #expect(text.contains("| `left-pad` | runtime | `^1.0.0` | — | — | Unknown | — |"))
    }

    @Test("every dependency given reaches the table")
    func everyFactIsListed() {
        let facts = (1...25).map { i in
            DependencyAdvicePrompt.Fact(
                name: "pkg-\(i)", ecosystem: "npm", isDev: false,
                required: "^1.0.0", installed: "1.0.0", latest: "2.0.0",
                status: "Major behind", advisories: []
            )
        }
        let text = DependencyAdvicePrompt.build(
            project: project(checkedAt: now), facts: facts, now: now
        )
        // A silent truncation would mean the user asks about 25 and gets advice on
        // some subset, with nothing saying which.
        for i in 1...25 { #expect(text.contains("`pkg-\(i)`")) }
    }
}
