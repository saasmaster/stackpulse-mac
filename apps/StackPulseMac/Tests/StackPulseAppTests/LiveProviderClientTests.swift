import Foundation
import Testing
@testable import StackPulseApp

/// Every live-provider client ships an embedded fixture suite. These run them
/// under `swift test` too — not just the `--selftest-parsers` CLI path — so a
/// broken parser fails CI rather than silently showing a wrong percentage.
///
/// These providers publish no local usage, so their numbers come from the same
/// endpoints each vendor's own dashboard/CLI calls, authenticated with the user's
/// own local credential. The fixtures pin the honesty rules that matter: a window
/// the API didn't report is dropped (never 0%), and every reading is timestamped.
@Suite("Live provider clients")
struct LiveProviderClientTests {

    @Test("Codex live-usage parser self-test passes")
    func codexLive() { #expect(CodexLiveUsageClient._selftest()) }

    @Test("Copilot per-seat quota parser self-test passes")
    func copilot() { #expect(CopilotUsageClient._selftest()) }

    @Test("Antigravity loopback quota parser self-test passes")
    func antigravity() { #expect(AntigravityQuotaClient._selftest()) }

    @Test("Z.ai quota parser self-test passes")
    func zai() { #expect(ZaiUsageClient._selftest()) }

    @Test("Grok billing parser self-test passes")
    func grok() { #expect(GrokUsageClient._selftest()) }

    @Test("Devin plan-status parser self-test passes")
    func devin() { #expect(DevinUsageClient._selftest()) }

    /// The one client in this batch that WRITES a credential, and the only one whose
    /// self-test the suite used to skip — it ran solely behind the
    /// `--selftest-parsers` flag, which `swift test` never invokes. A regression in
    /// the store that reads and rewrites the user's Claude login is the last thing
    /// that should be able to merge green.
    @Test("Claude auth store self-test passes")
    func claudeAuth() { #expect(ClaudeAuthStore._selftest()) }

    /// Every bundled brand mark must parse to a sane, non-degenerate shape — a
    /// mark that silently failed to parse would leave a provider's menu-bar cell
    /// showing a number with no identity.
    @Test("all provider brand marks parse to non-empty shapes")
    func brandMarksParse() { #expect(ProviderIconShape._selftest()) }

    @Test("every provider we ship a mark for is keyed by its StackPulse id")
    func markKeysMatchProviderIDs() {
        // openusage names these `opencode`/`openrouter`; ours are snake_cased.
        for id in ["claude", "codex", "copilot", "cursor", "antigravity",
                   "devin", "grok", "open_code", "open_router", "zai"] {
            #expect(ProviderMarks.mark(for: id) != nil, "no brand mark for \(id)")
        }
        // Gemini has no vector mark — it must fall back to a symbol, not crash.
        #expect(ProviderMarks.mark(for: "gemini") == nil)
        #expect(!ProviderMarks.symbolFallback(for: "gemini").isEmpty)
    }

    /// Guards the labels the UI maps to display names. A client emitting a window
    /// labelled something else would render as a raw key on every card.
    @Test("shared limit labels cover every window these clients emit")
    func labelsAreMapped() {
        #expect(Format.limitLabel("5h") == "Session (5h)")
        #expect(Format.limitLabel("weekly") == "Weekly")
        #expect(Format.limitLabel("cursor_total") == "Total usage")
        #expect(Format.limitLabel("cursor_auto") == "Auto usage")
        #expect(Format.limitLabel("cursor_api") == "API usage")
        // Devin's window is genuinely daily — it must NOT borrow the 5h label.
        #expect(Format.limitLabel("daily") == "Daily")
        #expect(Format.limitLabel("premium") == "Premium")
        // Z.ai's TIME_LIMIT window. It was the one label these clients emit that
        // nothing asserted, so nothing would have caught it rendering as a raw key.
        //
        // These three used to reach the display string through `limitLabel`'s
        // `default: raw.capitalized`, so they proved the fall-through still covered
        // them, NOT that the switch handled them — and title-casing put "Web
        // Searches" next to the sentence-case "Total usage". `limitLabel` now owns
        // all three explicitly, and these assertions pin the arms, not the default.
        #expect(Format.limitLabel("web searches") == "Web searches")
        #expect(Format.limitLabel("daily") == "Daily")
        #expect(Format.limitLabel("premium") == "Premium")
    }
}
