import Foundation
import Testing
@testable import StackPulseApp

/// Routing an advisory to its own writeup.
///
/// The address was in the data all along — `AdvisoryLite.url` — and the UI rendered
/// only "N advisories" with no way to reach any of them. Advisories are the
/// highest-severity thing this section reports, so it was the worst place to have a
/// dead end.
@Suite("Advisory links")
struct AdvisoryLinkTests {
    /// OSV's batch response: `results` is positional against the ids we asked
    /// about, which is why the parser takes both.
    func batch(_ resultsJSON: String, ids: [String]) -> [String: [StackHealthClient.AdvisoryLite]] {
        StackHealthClient.parseOSVBatch(Data(#"{ "results": \#(resultsJSON) }"#.utf8), ids: ids)
    }

    /// The id comes from OSV's own response, and `/vulnerability/<id>` is that
    /// host's canonical route for its own ids. Verified live against real ids
    /// (GHSA-29mw-wpgm-hmr9 and two others → HTTP 200) — the difference between
    /// deriving a URL from real data and inventing one from a package name.
    @Test("an OSV id becomes that id's canonical osv.dev URL")
    func osvURLShape() {
        #expect(StackHealthClient.osvURL("GHSA-29mw-wpgm-hmr9")
                == "https://osv.dev/vulnerability/GHSA-29mw-wpgm-hmr9")
        #expect(StackHealthClient.osvURL("RUSTSEC-2021-0079")
                == "https://osv.dev/vulnerability/RUSTSEC-2021-0079")
    }

    /// Every advisory the parser emits carries a usable URL echoing its own id.
    @Test("parsed advisories carry a usable URL built from their own id")
    func parsedAdvisoriesHaveURLs() throws {
        let out = batch("""
        [ { "vulns": [ { "id": "GHSA-29mw-wpgm-hmr9", "database_specific": { "severity": "HIGH" } },
                       { "id": "GHSA-35jh-r3h4-6jhm", "database_specific": { "severity": "MODERATE" } } ] } ]
        """, ids: ["npm:lodash"])
        let lites = try #require(out["npm:lodash"])
        #expect(lites.count == 2)
        for l in lites {
            let url = try #require(l.url)
            #expect(url == "https://osv.dev/vulnerability/\(l.id)")
            #expect(URL(string: url) != nil)
        }
    }

    /// Results are positional: an advisory must land on the dep it was asked about,
    /// or the row would link a vulnerability belonging to another package.
    @Test("results map to the id they were requested for")
    func positionalMapping() throws {
        let out = batch("""
        [ { "vulns": [] },
          { "vulns": [ { "id": "GHSA-aaaa" } ] } ]
        """, ids: ["npm:safe", "npm:vulnerable"])
        #expect(out["npm:safe"] == nil, "a dep with no vulns gets no entry, not an empty claim")
        #expect(out["npm:vulnerable"]?.first?.id == "GHSA-aaaa")
    }

    /// The same id twice must not become two links (and would inflate the count).
    @Test("duplicate ids collapse")
    func duplicatesCollapse() throws {
        let out = batch("""
        [ { "vulns": [ { "id": "GHSA-x" }, { "id": "GHSA-x" }, { "id": "GHSA-y" } ] } ]
        """, ids: ["npm:p"])
        #expect(try #require(out["npm:p"]).count == 2)
    }

    /// A vuln with no id has no address — it must not become a link to
    /// `osv.dev/vulnerability/`, a page about nothing.
    @Test("a vuln with no usable id yields no advisory")
    func noIDNoAdvisory() {
        #expect(batch(#"[ { "vulns": [ { "id": "" } ] } ]"#, ids: ["npm:p"]).isEmpty)
        #expect(batch(#"[ { "vulns": [ {} ] } ]"#, ids: ["npm:p"]).isEmpty)
    }

    /// Malformed OSV output degrades to nothing — never a fabricated advisory, and
    /// never a claim of safety.
    @Test("garbage yields nothing")
    func garbage() {
        #expect(StackHealthClient.parseOSVBatch(Data("not json".utf8), ids: ["npm:p"]).isEmpty)
        #expect(StackHealthClient.parseOSVBatch(Data("{}".utf8), ids: ["npm:p"]).isEmpty)
        #expect(batch("[]", ids: ["npm:p"]).isEmpty)
    }

    /// More results than ids must not read off the end.
    @Test("a longer results array than ids is bounded")
    func boundedResults() {
        let out = batch(#"[ { "vulns": [ { "id": "A" } ] }, { "vulns": [ { "id": "B" } ] } ]"#,
                        ids: ["npm:only-one"])
        #expect(out.count == 1)
        #expect(out["npm:only-one"]?.first?.id == "A")
    }

    /// OSV's severity is OSV's. An unrecognized value must still read as a
    /// vulnerability, never get quietly downgraded to "fine".
    @Test("an unknown severity stays a vulnerability")
    func unknownSeverityIsStillReal() {
        #expect(StackHealthClient.normalizeSeverity("SEVERE-ISH") == "unknown")
        #expect(StackHealthClient.normalizeSeverity("critical") == "critical")
        #expect(StackHealthClient.normalizeSeverity("MEDIUM") == "moderate")
    }
}
