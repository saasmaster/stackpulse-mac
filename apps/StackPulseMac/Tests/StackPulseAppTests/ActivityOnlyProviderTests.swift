import Foundation
import Testing
@testable import StackPulseApp

/// Pins the rule that keeps a server-metered provider from being described in
/// units it never reported.
///
/// Antigravity (Google's agent IDE) meters tokens and dollars **server-side**.
/// Nothing about quota, credits, or percentage is written to this Mac. What the
/// core can honestly report is activity: conversation counts, recency, model.
///
/// The rule existed before this suite — as a *private copy* inside one view. The
/// popover rendered Antigravity honestly and every other surface did not, which
/// is the failure mode these tests exist to prevent: the rule now lives on the
/// model, so a new surface inherits it instead of re-deriving it.
@Suite("Activity-only providers")
struct ActivityOnlyProviderTests {

    // MARK: Fixtures

    /// Decodes through the real `Codable` path — the same one the FFI snapshot
    /// takes — so a field rename breaks the test rather than sliding past a
    /// hand-written initializer.
    private func provider(
        id: String = "antigravity",
        installed: Bool = true,
        todayTokens: UInt64 = 0,
        todayCost: Double? = nil,
        todayRecords: UInt64 = 0,
        d30Tokens: UInt64 = 0,
        d30Cost: Double? = nil,
        d30Records: UInt64 = 0,
        models: [String] = []
    ) -> ProviderUsage {
        func window(_ label: String, _ tokens: UInt64, _ cost: Double?, _ records: UInt64) -> String {
            let costJSON: String = cost.map { String($0) } ?? "null"
            let totals = "{\"input_tokens\":\(tokens),\"output_tokens\":0,"
                + "\"cache_creation_tokens\":0,\"cache_read_tokens\":0,\"reasoning_tokens\":0}"
            return "{\"label\":\"\(label)\",\"tokens\":\(totals),"
                + "\"estimated_cost_usd\":\(costJSON),\"records\":\(records)}"
        }
        let modelRows: String = models.map { (name: String) -> String in
            let totals = "{\"input_tokens\":0,\"output_tokens\":0,"
                + "\"cache_creation_tokens\":0,\"cache_read_tokens\":0,\"reasoning_tokens\":0}"
            return "{\"model\":\"\(name)\",\"tokens\":\(totals),"
                + "\"estimated_cost_usd\":null,\"records\":1}"
        }.joined(separator: ",")
        let json = """
        {"provider":"\(id)","display_name":"\(id)","health":"fully_supported",
         "installed":\(installed),"authenticated":true,
         "detected_version":null,"plan_hint":null,
         "windows":[\(window("today", todayTokens, todayCost, todayRecords)),
                    \(window("last_30_days", d30Tokens, d30Cost, d30Records))],
         "models":[\(modelRows)],"limits":[],"capabilities":[],"notes":[],
         "analytics":null}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(ProviderUsage.self, from: Data(json.utf8))
    }

    // MARK: hasLocalSpend

    @Test("the Antigravity shape is activity-only, never spend")
    func testAntigravityShapeHasNoLocalSpend() {
        // Zero tokens + null cost is exactly what the core emits for Antigravity:
        // TokenTotals::default() and estimated_cost_usd: None.
        let p = provider(todayRecords: 3, d30Records: 27, models: ["gemini-3-flash-agent"])
        #expect(!(p.hasLocalSpend))
        #expect(p.hasLocalActivity)
        #expect(p.isActivityOnly)
    }

    @Test("measured tokens with an unknown rate are still spend")
    func testMeasuredTokensCountAsLocalSpendEvenWithoutCost() {
        // A priced-but-unpriceable model (the Opus 4.8 mispricing case): tokens
        // were really measured, cost is unknown. That is spend, not activity —
        // it must keep its spend row so the missing rate stays visible as "—".
        let p = provider(todayTokens: 1_200, todayCost: nil, todayRecords: 4)
        #expect(p.hasLocalSpend)
        #expect(!(p.isActivityOnly))
    }

    @Test("cost without tokens is still spend")
    func testCostWithoutTokensStillCountsAsLocalSpend() {
        let p = provider(d30Cost: 12.5, d30Records: 9)
        #expect(p.hasLocalSpend)
        #expect(!(p.isActivityOnly))
    }

    @Test("a provider that isn't installed is never activity-only")
    func testUninstalledProviderIsNeverActivityOnly() {
        // isActivityOnly gates rendering; a provider that isn't on this Mac has
        // nothing to render either way and must not claim activity.
        let p = provider(installed: false, d30Records: 5)
        #expect(!(p.isActivityOnly))
    }

    @Test("a detected but silent provider claims no activity")
    func testDetectedButSilentProviderIsNotActivityOnly() {
        // No spend AND no activity — there is nothing to say. This must not be
        // routed to the activity row, which would render "0 sessions · 0 today".
        let p = provider()
        #expect(!(p.hasLocalSpend))
        #expect(!(p.hasLocalActivity))
        #expect(!(p.isActivityOnly))
    }

    @Test("activity used today counts before a 30-day window exists")
    func testTodayOnlyActivityCounts() {
        // A provider first used today has no 30-day window rows yet in some
        // shapes; activity must not depend solely on last30.
        let p = provider(todayRecords: 2)
        #expect(p.hasLocalActivity)
        #expect(p.isActivityOnly)
    }

    // MARK: The silent-but-installed provider

    /// The gap this suite had: `testDetectedButSilentProviderIsNotActivityOnly`
    /// pinned the model property and passed, while three views branched on
    /// `isActivityOnly` and sent exactly this shape to the **spend grid** — the one
    /// branch it must never reach. A property assertion is not a rendering
    /// assertion. These pin the predicate the views actually switch on.
    ///
    /// MiniMax is the real instance: its agent runs in the cloud, so it reports no
    /// models, no records and no local limits, forever.
    @Test("a cloud provider with no local footprint never earns a spend grid")
    func testSilentInstalledProviderIsNeverGivenSpendCells() {
        let p = provider(id: "minimax")
        #expect(p.installed)
        // What every surface now branches on. False ⇒ no spend cells, so the card
        // can't print "$—" over "0 tok" for a figure this Mac was never told.
        #expect(!(p.hasLocalSpend))
        // And it must not be routed to the activity row either — there is no
        // activity to show, so "0 sessions" would be the same fabrication.
        #expect(!(p.hasLocalActivity))
    }

    @Test("being installed is enough to earn a card of its own")
    func testInstalledProviderWarrantsOwnCard() {
        // The popover used to require usage data or a balance, so a provider the
        // user is signed into rendered as one line among the eight they don't have
        // — indistinguishable from "not found", which reads as the app not seeing it.
        #expect(provider(id: "minimax").warrantsOwnCard)
        // A provider that genuinely isn't here still collapses.
        #expect(!provider(id: "grok", installed: false).warrantsOwnCard)
        // And the pre-existing reasons still stand on their own.
        #expect(provider(id: "codex", installed: false, d30Records: 5).warrantsOwnCard)
    }

    // MARK: The aggregate

    /// `records` is defined by the protocol as assistant turns. A provider with
    /// no local token accounting reuses the field for whatever it *can* count —
    /// Antigravity puts conversations there (see `antigravity.rs`). Summing both
    /// into a tile labelled "Turns (30d)" reports a number that is neither.
    @Test("conversations are never added into a turns total")
    func testTurnsAggregateExcludesActivityOnlyProviders() {
        let claude = provider(id: "claude", d30Tokens: 900_000, d30Cost: 42, d30Records: 310)
        let antigravity = provider(id: "antigravity", d30Records: 27,
                                   models: ["gemini-3-flash-agent"])
        let snapshot = snapshotWith([claude, antigravity])
        #expect(snapshot.total30Turns == 310, "conversations must not be added into turns")
    }

    @Test("every metered provider still counts toward turns")
    func testTurnsAggregateStillCountsEveryMeteredProvider() {
        let claude = provider(id: "claude", d30Tokens: 900_000, d30Cost: 42, d30Records: 310)
        let codex = provider(id: "codex", d30Tokens: 12_000, d30Cost: 3, d30Records: 40)
        #expect(snapshotWith([claude, codex]).total30Turns == 350)
    }

    private func snapshotWith(_ providers: [ProviderUsage]) -> UsageSnapshot {
        let encoded = try! JSONEncoder().encode(providers)  // swiftlint:disable:this force_try
        let json = """
        {"protocol_version":{"major":1,"minor":20,"patch":0},"core_version":"test",
         "generated_at_unix":0,"bucket_date_utc":"2026-07-16","pricing_note":"",
         "providers":\(String(decoding: encoded, as: UTF8.self)),
         "alerts":[],"missions":[],"insights":[],"canaries":[]}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
    }
}
