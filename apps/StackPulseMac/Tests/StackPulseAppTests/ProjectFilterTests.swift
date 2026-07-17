import Foundation
import Testing
@testable import StackPulseApp

/// One filter rule, shared by Launcher, Projects and Stack Health.
///
/// Three surfaces list the same ~30 projects. The Launcher had the only filter and
/// matched the name alone; the other two had none. A filter that means something
/// different on each surface is worse than no filter — you learn what it does on
/// one screen and it lies to you on the next.
@Suite("Project filter")
struct ProjectFilterTests {

    private func matches(_ query: String, _ name: String, _ path: String = "/Users/j/Documents/App Privadas/x") -> Bool {
        ProjectFilter.matches(query: query, name: name, path: path)
    }

    // MARK: A blank filter hides nothing

    @Test("an empty query matches everything")
    func emptyMatchesAll() {
        #expect(matches("", "trencito"))
    }

    @Test("a whitespace-only query matches everything")
    func whitespaceMatchesAll() {
        // Otherwise a stray space empties the list and reads as "no projects".
        #expect(matches("   ", "trencito"))
        #expect(matches("\t", "trencito"))
    }

    // MARK: Matching

    @Test("a name substring matches")
    func nameSubstring() {
        #expect(matches("tren", "trencito"))
        #expect(!matches("zeder", "trencito"))
    }

    @Test("matching ignores case")
    func caseInsensitive() {
        #expect(matches("TREN", "trencito"))
        #expect(matches("tren", "Trencito"))
    }

    @Test("the folder matches too — it's how you say which one you mean")
    func pathMatches() {
        // This portfolio keeps projects under several roots, and two projects can
        // share a name. Name-only matching (the Launcher's old rule) can't tell
        // them apart.
        #expect(matches("Claude/Projects", "cabinet-designer",
                        "/Users/j/Documents/Claude/Projects/Cabinet Designer"))
        #expect(!matches("Desktop", "cabinet-designer",
                         "/Users/j/Documents/Claude/Projects/Cabinet Designer"))
    }

    @Test("every term must match — typing more always narrows")
    func allTermsMustMatch() {
        #expect(matches("zeder erp", "zeder-erp", "/Users/j/App Privadas/zeder-erp"))
        // "erp" is present, "cocina" is not: one hit is not a match.
        #expect(!matches("zeder cocina", "zeder-erp", "/Users/j/App Privadas/zeder-erp"))
    }

    @Test("terms may match across the name and the path")
    func termsSpanNameAndPath() {
        #expect(matches("privadas trencito", "trencito",
                        "/Users/j/Documents/App Privadas/trencito"))
    }

    @Test("terms are order-independent")
    func orderIndependent() {
        #expect(matches("trencito privadas", "trencito",
                        "/Users/j/Documents/App Privadas/trencito"))
    }

    @Test("extra spaces between terms don't break matching")
    func extraSpaces() {
        #expect(matches("zeder    erp", "zeder-erp", "/Users/j/App Privadas/zeder-erp"))
    }

    // MARK: Real portfolio shapes

    @Test("a query narrows a real 30-project list to the intended one")
    func narrowsARealList() {
        // Names taken from the live scan — several share prefixes, which is the
        // whole reason the list needs a filter.
        let names = ["meli-profit-command", "remotion-video", "veeme",
                     "propertysheet-clipper", "buildbrief-scout", "trencito",
                     "train-tots", "zeder-erp", "brillo", "washos"]
        let hits = names.filter { matches("tra", $0, "/Users/j/App Privadas/\($0)") }
        #expect(hits == ["train-tots"])
    }

    @Test("a shared prefix still returns both, rather than guessing")
    func sharedPrefixReturnsBoth() {
        // "tren"/"train" are distinct, but "t" is ambiguous — an ambiguous query
        // must not silently pick one.
        let names = ["trencito", "train-tots"]
        let hits = names.filter { matches("t", $0, "/Users/j/App Privadas/\($0)") }
        #expect(hits.count == 2)
    }
}
