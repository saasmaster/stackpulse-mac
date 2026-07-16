//! Embedded pricing catalog.
//!
//! **These are estimates.** Rates are approximate public list prices per
//! million tokens (USD) as of the date in [`PRICING_AS_OF`]. StackPulse never
//! presents an estimate as a provider-reported fact — costs derived here are
//! always tagged [`stackpulse_protocol::Provenance::LocalEstimate`].
//!
//! A future version will merge remote pricing (litellm / models.dev) and a
//! signed supplement; the lookup is deliberately structured so a richer catalog
//! can drop in behind [`estimate_cost`] without touching callers.
//!
//! ## Token accounting convention
//!
//! Providers normalize their raw counts into a single "exclusive input"
//! convention before pricing (see `providers/*`):
//! - `input_tokens`          → fresh, uncached prompt tokens (billed at input rate)
//! - `cache_creation_tokens` → tokens written to cache (billed at write rate)
//! - `cache_read_tokens`     → tokens served from cache (billed at read rate)
//! - `output_tokens`         → completion tokens (billed at output rate)
//! - `reasoning_tokens`      → reasoning tokens (billed at output rate)
//!
//! ## Known inaccuracies (stated, not hidden)
//!
//! 1. **Cache writes are priced at the 5-minute rate.** Anthropic bills a 5-minute
//!    cache write at 1.25× input and a **1-hour** write at 2× input. Claude's logs
//!    do distinguish them (`cache_creation.ephemeral_5m/1h_input_tokens`), but
//!    [`TokenTotals`] carries a single `cache_creation_tokens`, so the split is
//!    lost before it reaches this module and every write is priced as 5-minute.
//!    On a real machine 86% of cache writes were 1-hour, so this **understates**.
//!    Fixing it means carrying the split through the protocol and the adapters.
//! 2. **OpenAI rates are unverified.** The Claude rates below were read off
//!    Anthropic's published price list; the GPT/Codex cards were not, and are
//!    inherited from an earlier revision.
//! 3. **Sonnet 5 is on introductory pricing** through [`SONNET_5_INTRO_ENDS`],
//!    after which it rises to the standard Sonnet rate. `rates_for` has no clock,
//!    so on that date this table silently becomes wrong for Sonnet 5 until updated.

use stackpulse_protocol::TokenTotals;

/// Human-readable provenance note attached to every snapshot.
///
/// This is the *only* thing telling a user how stale these rates are, so it must
/// move whenever the table does. It sat at a month that predated the rates it
/// described while Opus was priced 3× high — the label said "current" and the
/// numbers weren't.
pub const PRICING_AS_OF: &str = "2026-07-16";

/// Rates in USD per **million** tokens.
#[derive(Debug, Clone, Copy)]
pub struct ModelRates {
    pub input: f64,
    pub output: f64,
    /// Cache-write rate (Claude prompt caching, ~1.25× input for 5-minute TTL).
    pub cache_write: f64,
    /// Cache-read rate (large discount).
    pub cache_read: f64,
}

impl ModelRates {
    /// Cost in USD for the given normalized token totals.
    pub fn cost(&self, t: &TokenTotals) -> f64 {
        let per = 1_000_000.0;
        (t.input_tokens as f64 * self.input
            + t.cache_creation_tokens as f64 * self.cache_write
            + t.cache_read_tokens as f64 * self.cache_read
            + (t.output_tokens + t.reasoning_tokens) as f64 * self.output)
            / per
    }
}

// Public list prices (USD / 1M tokens), from Anthropic's pricing page as of
// PRICING_AS_OF. `cache_write` uses the 5-MINUTE write rate (1.25× input); see
// the module docs for why that under-prices 1-hour writes.

/// Claude Fable 5 and Mythos 5 (identical published rates).
const FABLE: ModelRates = ModelRates {
    input: 10.0,
    output: 50.0,
    cache_write: 12.50,
    cache_read: 1.00,
};
/// Opus 4.5 through 4.8.
const OPUS: ModelRates = ModelRates {
    input: 5.0,
    output: 25.0,
    cache_write: 6.25,
    cache_read: 0.50,
};
/// Opus 4 and 4.1 — 3× the current Opus rate, and the reason model VERSION has
/// to be parsed rather than matching on the word "opus".
const OPUS_LEGACY: ModelRates = ModelRates {
    input: 15.0,
    output: 75.0,
    cache_write: 18.75,
    cache_read: 1.50,
};
/// Sonnet 5 introductory pricing, in effect through [`SONNET_5_INTRO_ENDS`].
const SONNET_5_INTRO: ModelRates = ModelRates {
    input: 2.0,
    output: 10.0,
    cache_write: 2.50,
    cache_read: 0.20,
};
/// Sonnet 4, 4.5, 4.6 — and Sonnet 5 once the introductory period ends.
const SONNET: ModelRates = ModelRates {
    input: 3.0,
    output: 15.0,
    cache_write: 3.75,
    cache_read: 0.30,
};
/// Haiku 4.5.
const HAIKU: ModelRates = ModelRates {
    input: 1.0,
    output: 5.0,
    cache_write: 1.25,
    cache_read: 0.10,
};
/// Haiku 3.5.
const HAIKU_35: ModelRates = ModelRates {
    input: 0.80,
    output: 4.0,
    cache_write: 1.00,
    cache_read: 0.08,
};

/// Sonnet 5's introductory rate runs through 2026-08-31; on 2026-09-01 it becomes
/// the standard [`SONNET`] rate. Recorded as a constant because `rates_for` has no
/// clock: the table is only claimed accurate as of [`PRICING_AS_OF`], and this is
/// a known, dated expiry rather than a surprise.
pub const SONNET_5_INTRO_ENDS: &str = "2026-08-31";
// OpenAI GPT-5 / Codex family. cached input priced at the read column.
const GPT5: ModelRates = ModelRates {
    input: 1.25,
    output: 10.0,
    cache_write: 1.25,
    cache_read: 0.125,
};
const GPT41: ModelRates = ModelRates {
    input: 2.0,
    output: 8.0,
    cache_write: 2.0,
    cache_read: 0.50,
};

/// Resolve a model string to a rate card. Returns `None` for models we cannot
/// price — the caller must exclude them from cost totals and surface a note
/// (see [`crate::canary`]). **Never guess a price.**
///
/// ## Why this parses the version instead of matching the family name
///
/// This used to be "tolerant substring matching": anything containing `opus` got
/// the Opus rate card. That tolerance was supposed to survive new model ids. What
/// it actually did was price **Opus 4.8 at Opus 4.1's rates — 3× the real price**
/// — silently, for as long as the card sat un-updated. On a real machine that was
/// a 2.7× overstatement of a month's spend, and nothing anywhere said so, because
/// a wrong rate looks exactly like a right one.
///
/// So: an unrecognized version of a KNOWN family now returns `None` rather than
/// borrowing a sibling's price. "We don't know" is a fact the canary can report;
/// a confidently wrong number is not. Strictness is only safe *because* the canary
/// surfaces the gap — the two are a pair.
pub fn rates_for(model: &str) -> Option<ModelRates> {
    let m = model.to_ascii_lowercase();
    // Order matters: more specific families first.
    if m.contains("fable") || m.contains("mythos") {
        return Some(FABLE);
    }
    if m.contains("opus") {
        // 4.5–4.8 are $5/$25; 4 and 4.1 are $15/$75. A bare "claude-opus-4" (no
        // minor, just a date stamp) is Opus 4 — legacy.
        return match family_version(&m, "opus") {
            Some((4, Some(5..=8))) => Some(OPUS),
            Some((4, Some(0..=1))) | Some((4, None)) => Some(OPUS_LEGACY),
            _ => None,
        };
    }
    if m.contains("sonnet") {
        return match family_version(&m, "sonnet") {
            Some((5, _)) => Some(SONNET_5_INTRO),
            Some((4, _)) => Some(SONNET),
            _ => None,
        };
    }
    if m.contains("haiku") {
        return match family_version(&m, "haiku") {
            Some((4, Some(5))) => Some(HAIKU),
            Some((3, Some(5))) => Some(HAIKU_35),
            _ => None,
        };
    }
    // OpenAI. Left as coarse family matching: unlike the Claude rates above,
    // these have NOT been verified against OpenAI's current price list, so
    // tightening them would only trade one unverified answer for another.
    if m.contains("codex")
        || m.contains("gpt-5")
        || m.contains("gpt5")
        || m.contains("o4")
        || m.contains("o3")
    {
        return Some(GPT5);
    }
    if m.contains("gpt-4") || m.contains("gpt4") {
        return Some(GPT41);
    }
    None
}

/// Parse `<family>-<major>[-<minor>]` out of a model id.
///
/// `"claude-opus-4-8-20260101"` → `(4, Some(8))`, `"claude-sonnet-5"` → `(5, None)`,
/// `"claude-opus-4-20250514"` → `(4, None)` — a 4+-digit group is a date stamp, not
/// a minor version, which is the whole reason this can't be a naive split.
fn family_version(model: &str, family: &str) -> Option<(u32, Option<u32>)> {
    let rest = model.split_once(&format!("{family}-"))?.1;
    let mut parts = rest.split('-');
    let major: u32 = parts.next()?.parse().ok()?;
    let minor = parts
        .next()
        .filter(|p| p.len() < 4) // else it's a date stamp
        .and_then(|p| p.parse().ok());
    Some((major, minor))
}

/// Estimate the cost for `tokens` produced by `model`. `None` when unpriceable.
pub fn estimate_cost(model: &str, tokens: &TokenTotals) -> Option<f64> {
    rates_for(model).map(|r| r.cost(tokens))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_model_families() {
        assert!(rates_for("claude-opus-4-8-20260101").is_some());
        assert!(rates_for("claude-sonnet-5").is_some());
        assert!(rates_for("claude-haiku-4-5-20251001").is_some());
        assert!(rates_for("gpt-5-codex").is_some());
        assert!(rates_for("gpt-5").is_some());
        assert!(rates_for("totally-unknown-model").is_none());
    }

    /// The published rates, pinned. Nothing else in the repo checked that a rate
    /// card matched reality, so Opus sat at 3× its real price indefinitely —
    /// every test passed the whole time, because they only ever asserted
    /// `is_some()`. Source: Anthropic's pricing page, PRICING_AS_OF.
    #[test]
    fn rate_cards_match_the_published_price_list() {
        // (model id as it appears in real logs, input, output, cache_write, cache_read)
        let cases = [
            ("claude-opus-4-8", 5.0, 25.0, 6.25, 0.50),
            ("claude-opus-4-8-20260101", 5.0, 25.0, 6.25, 0.50),
            ("claude-opus-4-7", 5.0, 25.0, 6.25, 0.50),
            ("claude-opus-4-5", 5.0, 25.0, 6.25, 0.50),
            // Opus 4.1 / 4 really are 3× — the legacy card is correct, it was just
            // being applied to every Opus.
            ("claude-opus-4-1-20250805", 15.0, 75.0, 18.75, 1.50),
            ("claude-opus-4-20250514", 15.0, 75.0, 18.75, 1.50),
            ("claude-fable-5", 10.0, 50.0, 12.50, 1.00),
            ("claude-sonnet-5", 2.0, 10.0, 2.50, 0.20), // introductory
            ("claude-sonnet-4-6", 3.0, 15.0, 3.75, 0.30),
            ("claude-haiku-4-5-20251001", 1.0, 5.0, 1.25, 0.10),
            ("claude-haiku-3-5-20241022", 0.80, 4.0, 1.00, 0.08),
        ];
        for (model, input, output, write, read) in cases {
            let r = rates_for(model).unwrap_or_else(|| panic!("{model} must be priceable"));
            assert_eq!(r.input, input, "{model} input");
            assert_eq!(r.output, output, "{model} output");
            assert_eq!(r.cache_write, write, "{model} cache_write");
            assert_eq!(r.cache_read, read, "{model} cache_read");
        }
    }

    /// The bug that made this rewrite necessary: "contains(\"opus\")" priced Opus
    /// 4.8 with Opus 4.1's card. The two must never resolve to the same rates.
    #[test]
    fn opus_versions_are_not_interchangeable() {
        let current = rates_for("claude-opus-4-8").unwrap();
        let legacy = rates_for("claude-opus-4-1-20250805").unwrap();
        assert_ne!(current.input, legacy.input);
        assert_eq!(
            legacy.input / current.input,
            3.0,
            "legacy Opus is exactly 3×"
        );
    }

    /// A model family we know, at a version we don't, must be UNPRICED rather than
    /// borrowing a sibling's rate — that silent borrow is what caused the 3× error.
    /// The canary reports these; a wrong number reports nothing.
    #[test]
    fn an_unknown_version_of_a_known_family_is_unpriced() {
        assert!(rates_for("claude-opus-9-0").is_none());
        assert!(rates_for("claude-sonnet-7").is_none());
        assert!(rates_for("claude-haiku-9-9").is_none());
        // ...and the real one that showed up in local logs with no version at all.
        assert!(rates_for("<synthetic>").is_none());
    }

    /// A date stamp is not a minor version: `claude-opus-4-20250514` is Opus 4
    /// (legacy), not "Opus 4.20250514".
    #[test]
    fn family_version_reads_dates_as_dates() {
        assert_eq!(
            family_version("claude-opus-4-8-20260101", "opus"),
            Some((4, Some(8)))
        );
        assert_eq!(
            family_version("claude-opus-4-20250514", "opus"),
            Some((4, None))
        );
        assert_eq!(family_version("claude-sonnet-5", "sonnet"), Some((5, None)));
        assert_eq!(
            family_version("claude-opus-4-1", "opus"),
            Some((4, Some(1)))
        );
        assert_eq!(family_version("nonsense", "opus"), None);
    }

    #[test]
    fn cost_is_deterministic_and_ordered() {
        let t = TokenTotals {
            input_tokens: 1_000_000,
            output_tokens: 1_000_000,
            ..Default::default()
        };
        let opus = estimate_cost("claude-opus-4", &t).unwrap();
        let sonnet = estimate_cost("claude-sonnet-4", &t).unwrap();
        // Opus is materially more expensive than Sonnet.
        assert!(opus > sonnet);
        // 1M input @ $15 + 1M output @ $75 = $90 for opus.
        assert!((opus - 90.0).abs() < 1e-9);
    }

    #[test]
    fn cache_read_is_cheap() {
        let fresh = TokenTotals {
            input_tokens: 1_000_000,
            ..Default::default()
        };
        let cached = TokenTotals {
            cache_read_tokens: 1_000_000,
            ..Default::default()
        };
        let a = estimate_cost("claude-sonnet-4", &fresh).unwrap();
        let b = estimate_cost("claude-sonnet-4", &cached).unwrap();
        assert!(b < a);
    }
}
