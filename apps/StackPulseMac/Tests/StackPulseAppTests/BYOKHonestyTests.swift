import Foundation
import Testing
@testable import StackPulseApp

/// The BYOK note used to say "balance coming soon" for every provider without a
/// balance endpoint — a promise the app had no plan to keep, standing forever.
/// These pin the honest replacement: state that the key is saved and that no
/// balance is available, and never imply one is on the way.
@Suite("BYOK balance honesty")
struct BYOKHonestyTests {

    @Test("the no-balance note says the key is saved and no balance is readable")
    func noteIsHonest() {
        let note = APIKeyProviders.noBalanceNote(for: "openai")
        #expect(note.contains("OpenAI"))
        #expect(note.localizedCaseInsensitiveContains("saved"))
        #expect(note.localizedCaseInsensitiveContains("no balance"))
    }

    @Test("no provider note ever promises a future balance")
    func neverPromisesComingSoon() {
        // The whole point: not one of the stored-but-unreadable providers may imply
        // a balance is coming. A promise that never resolves is the small lie this
        // app refuses.
        for info in APIKeyProviders.all where !info.hasLiveBalance {
            let note = APIKeyProviders.noBalanceNote(for: info.id)
            #expect(!note.localizedCaseInsensitiveContains("coming soon"), "\(info.id) still promises a balance")
            #expect(!note.localizedCaseInsensitiveContains("soon"), "\(info.id) still implies a future balance")
        }
    }

    @Test("the chip label is a plain fact, not a promise")
    func chipLabelIsFactual() {
        #expect(APIKeyProviders.noBalanceLabel == "No balance readout")
        #expect(!APIKeyProviders.noBalanceLabel.localizedCaseInsensitiveContains("soon"))
    }

    @Test("providers with a real fetcher are still marked as having live balance")
    func fetchersStillAdvertised() {
        // Guards against over-correcting: OpenRouter/LiteLLM/DeepSeek do have
        // verified endpoints and must keep offering a balance.
        for id in ["open_router", "litellm", "deepseek"] {
            #expect(APIKeyProviders.info(for: id)?.hasLiveBalance == true, "\(id) lost its live balance flag")
        }
    }

    @Test("the balance parsers self-test passes (OpenRouter /key + /credits, LiteLLM, DeepSeek)")
    func parsersSelftestPasses() {
        // Runs the embedded fixture suite under `swift test` too — not just the
        // `--selftest-parsers` CLI path — so a broken parser fails CI.
        #expect(ProviderBalanceClient._selftest())
    }
}
