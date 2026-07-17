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

    private func project(
        checkedAt: Date? = nil,
        unresolved: Int = 0
    ) -> DependencyAdvicePrompt.Project {
        .init(
            name: "trencito",
            path: "/Users/j/Documents/App Privadas/trencito",
            ecosystem: "npm",
            packageManager: "npm",
            checkedAt: checkedAt ?? now,
            unresolvedCount: unresolved
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

    @Test("dependencies the registry never answered for are counted, not hidden")
    func unresolvedAreDeclared() {
        // They are absent from the table because their status is unknown — and an
        // absence reads as "fine" unless something says otherwise.
        let text = DependencyAdvicePrompt.build(
            project: project(unresolved: 3), facts: [lodash()], now: now
        )
        #expect(text.contains("**3 other dependencies are missing from this table**"))
        #expect(text.contains("Not listed ≠ known to be fine"))
    }

    @Test("nothing unresolved means no caveat about unresolved things")
    func noUnresolvedNoNote() {
        let text = DependencyAdvicePrompt.build(
            project: project(unresolved: 0), facts: [lodash()], now: now
        )
        #expect(!text.contains("missing from this table"))
    }

    @Test("one unresolved dependency reads as singular")
    func unresolvedSingular() {
        let text = DependencyAdvicePrompt.build(
            project: project(unresolved: 1), facts: [lodash()], now: now
        )
        #expect(text.contains("**1 other dependency is missing from this table**"))
    }

    // MARK: The boundary — what was never examined

    @Test("the prompt states that no source code was read")
    func statesTheBoundary() {
        let text = DependencyAdvicePrompt.build(
            project: project(), facts: [lodash()], now: now
        )
        #expect(text.contains("Nothing here read the source code"))
        #expect(text.contains("whether a vulnerable code path is reachable"))
    }

    @Test("the prompt forbids invented versions, CVEs and breaking changes")
    func forbidsFabrication() {
        let text = DependencyAdvicePrompt.build(
            project: project(), facts: [lodash()], now: now
        )
        #expect(text.contains("Never invent a version, a CVE, a date, or a breaking change"))
        #expect(text.contains("unverified"))
    }

    @Test("\"leave it\" is offered as a real answer")
    func offersLeaveItAsAnOutcome() {
        // Without this, every list of outdated deps reads as a to-do list, which is
        // how a dependency review turns into busywork.
        let text = DependencyAdvicePrompt.build(
            project: project(), facts: [lodash()], now: now
        )
        #expect(text.contains("**Leave it**"))
        #expect(text.contains("Don't recommend upgrading everything"))
    }

    // MARK: The facts

    @Test("dev scope is carried, because it usually decides whether it matters")
    func carriesDevScope() {
        let text = DependencyAdvicePrompt.build(
            project: project(),
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
            project: project(),
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
            project: project(),
            facts: [lodash(advisories: [.init(id: "OSV-2026-1", severity: "high", url: nil)])],
            now: now
        )
        #expect(text.contains("OSV-2026-1"))
    }

    @Test("a missing version reads as unknown, never as a version")
    func missingVersionIsNotInvented() {
        // The real shape of this: OSV matched an advisory, so the package IS known
        // to need attention, but the registry never returned a `latest`. Known
        // problem, unknown fix target — and the fix target must not be invented.
        let text = DependencyAdvicePrompt.build(
            project: project(),
            facts: [
                .init(name: "left-pad", ecosystem: "npm", isDev: false,
                      required: "^1.0.0", installed: nil, latest: nil,
                      status: "Minor behind",
                      advisories: [.init(id: "OSV-2026-9", severity: "high", url: nil)])
            ],
            now: now
        )
        #expect(text.contains("| `left-pad` | runtime | `^1.0.0` | — | — | Minor behind | OSV-2026-9 (high) |"))
    }

    // MARK: The gate — what may be asked about at all

    /// The bug this pins: the button was gated on "not up to date", but the
    /// offline core reports EVERY dependency as `unknown`, so an unchecked project
    /// put its whole manifest in that bucket. The prompt would have been a list of
    /// packages with `latest: —`, presented as findings.
    @Test("an unknown status is never a finding — the core reports unknown for everything")
    func unknownIsNotAFinding() {
        #expect(!DependencyAdvicePrompt.isKnownOutdated(statusRaw: "unknown", advisoryCount: 0))
        #expect(!DependencyAdvicePrompt.isKnownOutdated(statusRaw: "", advisoryCount: 0))
    }

    @Test("an up-to-date dependency is never a finding")
    func upToDateIsNotAFinding() {
        #expect(!DependencyAdvicePrompt.isKnownOutdated(statusRaw: "up_to_date", advisoryCount: 0))
    }

    @Test("a resolved outdated status is a finding")
    func outdatedStatusesAreFindings() {
        for s in ["minor_behind", "major_behind", "deprecated"] {
            #expect(DependencyAdvicePrompt.isKnownOutdated(statusRaw: s, advisoryCount: 0),
                    "\(s) is something we actually established")
        }
    }

    @Test("an advisory is a finding even when the version status never resolved")
    func advisoryOutranksUnknownStatus() {
        // OSV answered; the registry didn't. We still know there's a problem.
        #expect(DependencyAdvicePrompt.isKnownOutdated(statusRaw: "unknown", advisoryCount: 1))
    }

    @Test("a status invented by a newer core is treated as unknown, not as a finding")
    func unrecognizedStatusIsNotAFinding() {
        // The wire value is a String precisely so a newer core can add states. A
        // state this build has never heard of is an absence of an answer.
        #expect(!DependencyAdvicePrompt.isKnownOutdated(statusRaw: "yanked_pending_review", advisoryCount: 0))
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
            project: project(), facts: facts, now: now
        )
        // A silent truncation would mean the user asks about 25 and gets advice on
        // some subset, with nothing saying which.
        for i in 1...25 { #expect(text.contains("`pkg-\(i)`")) }
    }
}
