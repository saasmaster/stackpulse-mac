import Foundation
import Testing
@testable import StackPulseApp

/// Pins the fix for the advisory-version-mismatch bug: enrichment (which carries
/// version-specific OSV advisories) must be cached by an identity that includes
/// the resolved version, so two projects using the same package at DIFFERENT
/// versions never share one project's advisory record.
@Suite("Dependency enrichment key")
struct EnrichmentKeyTests {

    private func dep(_ name: String, installed: String?) -> Dependency {
        let json = """
        {"name":"\(name)","ecosystem":"npm","required":"^1.0.0",
         "installed":\(installed.map { "\"\($0)\"" } ?? "null"),
         "latest":null,"status":"unknown","is_dev":false,"advisories":[]}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Dependency.self, from: Data(json.utf8))
    }

    @Test("the row id is name-scoped — same package reads as one dependency")
    func rowIdIgnoresVersion() {
        #expect(dep("react", installed: "18.3.1").id == dep("react", installed: "19.2.0").id)
    }

    @Test("the enrichment key is version-scoped — different versions don't collide")
    func enrichmentKeyDistinguishesVersions() {
        // This is the whole fix: keying the advisory cache by this instead of `id`
        // stops a patched project reusing a vulnerable sibling's advisories (and
        // vice-versa — the false-negative that hid a real vulnerability).
        #expect(dep("react", installed: "18.3.1").enrichmentKey
                != dep("react", installed: "19.2.0").enrichmentKey)
    }

    @Test("the same package at the same version shares one enrichment record")
    func sameVersionSharesKey() {
        // Dedup across projects is still preserved when the version matches — no
        // needless re-query.
        #expect(dep("lodash", installed: "4.17.21").enrichmentKey
                == dep("lodash", installed: "4.17.21").enrichmentKey)
    }

    @Test("a no-lockfile dep falls back to sharing by name")
    func missingVersionSharesByName() {
        // With no resolved version there's no version-specific claim to protect,
        // and the status is unknown regardless — sharing is acceptable and avoids
        // a pointless separate cache slot.
        let a = dep("x", installed: nil)
        let b = dep("x", installed: nil)
        #expect(a.enrichmentKey == b.enrichmentKey)
    }
}
