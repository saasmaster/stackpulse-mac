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
//! - `cache_creation_tokens` → tokens written to cache (billed at a write rate)
//! - `cache_creation_1h_tokens` → the 1-hour-TTL SUBSET of the writes above
//! - `cache_read_tokens`     → tokens served from cache (billed at read rate)
//! - `output_tokens`         → completion tokens (billed at output rate)
//! - `reasoning_tokens`      → reasoning tokens (billed at output rate)
//!
//! Cache writes are priced by TTL: `cache_creation_tokens` minus
//! `cache_creation_1h_tokens` at the 5-minute rate (1.25× input), the rest at the
//! 1-hour rate (2× input). Pricing everything as 5-minute understated real cost —
//! 86% of writes on a real machine are 1-hour.
//!
//! ## A rate is a function of the record's date
//!
//! A published rate can have an expiry: Sonnet 5's introductory price runs
//! through [`SONNET_5_INTRO_ENDS`] and reverts to the standard Sonnet card the
//! next day. So every lookup takes the date of the **record being priced** — not
//! the wall clock, and not a single "current" answer. A 30-day window straddling
//! such a switch legitimately contains records at both rates, and pricing them
//! all alike is wrong on one side of the line no matter which side is chosen.
//!
//! The date is always injected by the caller (every record carries its own; see
//! [`crate::providers::UsageRecord`]). This module reads no clock: a rate table
//! that consults `SystemTime::now()` cannot be tested against the day its own
//! prices change.
//!
//! ## Known inaccuracies (stated, not hidden)
//!
//! 1. **OpenAI rates: the observed models are now verified; the long tail is not.**
//!    The GPT-5 tiers and `gpt-5.3-codex` — the models that actually appear in local
//!    Codex logs — were read off OpenAI's published list
//!    (developers.openai.com/api/docs/pricing) on 2026-07-17 and are matched
//!    strictly, so an *unrecognized* GPT/Codex model now returns `None` (the canary
//!    reports it) instead of borrowing the old flat card. This retired a real 3-4×
//!    understatement: every `gpt-5.x` had been priced at $1.25/$10 while `gpt-5.5`
//!    bills $5/$30. The internal `codex-*` tooling ids (`codex-auto-review`,
//!    `codex-security-scans-…`) are intentionally unpriced — they are not published
//!    API models and their rate is genuinely unknown.
//! 2. **Data-residency and fast-mode multipliers are not modelled** (`inference_geo:
//!    "us"` is 1.1×; fast mode has its own card). Nothing local says which a turn
//!    used, so applying either would be a guess.

use crate::datetime::CivilDate;
use stackpulse_protocol::TokenTotals;

/// Human-readable provenance note attached to every snapshot.
///
/// This is the *only* thing telling a user how stale these rates are, so it must
/// move whenever the table does. It sat at a month that predated the rates it
/// described while Opus was priced 3× high — the label said "current" and the
/// numbers weren't.
///
/// It dates when the price list was **read**, not how long the table stays right:
/// a change already published with a future effective date (see
/// [`SONNET_5_INTRO_ENDS`]) is encoded below and does not make this stale.
pub const PRICING_AS_OF: &str = "2026-07-17";

/// Rates in USD per **million** tokens.
#[derive(Debug, Clone, Copy)]
pub struct ModelRates {
    pub input: f64,
    pub output: f64,
    /// Cache-write rate for the **5-minute** TTL (1.25× input).
    pub cache_write: f64,
    /// Cache-write rate for the **1-hour** TTL (2× input). Providers without the
    /// concept set this equal to `cache_write`, so their totals are unaffected.
    pub cache_write_1h: f64,
    /// Cache-read rate (large discount).
    pub cache_read: f64,
}

impl ModelRates {
    /// Cost in USD for the given normalized token totals.
    ///
    /// Cache writes are split by TTL: a 1-hour write costs 2× input against a
    /// 5-minute write's 1.25×, so pricing them all as 5-minute understated every
    /// total — by 86% of the write volume on a real machine.
    pub fn cost(&self, t: &TokenTotals) -> f64 {
        let per = 1_000_000.0;
        let (write_1h, write_5m) = t.cache_write_split();
        (t.input_tokens as f64 * self.input
            + write_5m as f64 * self.cache_write
            + write_1h as f64 * self.cache_write_1h
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
    cache_write_1h: 20.0,
    cache_read: 1.00,
};
/// Opus 4.5 through 4.8.
const OPUS: ModelRates = ModelRates {
    input: 5.0,
    output: 25.0,
    cache_write: 6.25,
    cache_write_1h: 10.0,
    cache_read: 0.50,
};
/// Opus 4 and 4.1 — 3× the current Opus rate, and the reason model VERSION has
/// to be parsed rather than matching on the word "opus".
const OPUS_LEGACY: ModelRates = ModelRates {
    input: 15.0,
    output: 75.0,
    cache_write: 18.75,
    cache_write_1h: 30.0,
    cache_read: 1.50,
};
/// Sonnet 5 introductory pricing, in effect through [`SONNET_5_INTRO_ENDS`].
const SONNET_5_INTRO: ModelRates = ModelRates {
    input: 2.0,
    output: 10.0,
    cache_write: 2.50,
    cache_write_1h: 4.0,
    cache_read: 0.20,
};
/// Sonnet 4, 4.5, 4.6 — and Sonnet 5 once the introductory period ends.
const SONNET: ModelRates = ModelRates {
    input: 3.0,
    output: 15.0,
    cache_write: 3.75,
    cache_write_1h: 6.0,
    cache_read: 0.30,
};
/// Haiku 4.5.
const HAIKU: ModelRates = ModelRates {
    input: 1.0,
    output: 5.0,
    cache_write: 1.25,
    cache_write_1h: 2.0,
    cache_read: 0.10,
};
/// Haiku 3.5.
const HAIKU_35: ModelRates = ModelRates {
    input: 0.80,
    output: 4.0,
    cache_write: 1.00,
    cache_write_1h: 1.60,
    cache_read: 0.08,
};

/// Last day Sonnet 5 bills at [`SONNET_5_INTRO`]; from the following day it bills
/// at the standard [`SONNET`] rate.
///
/// A [`CivilDate`] rather than a label because [`rates_for`] compares against it.
/// It was previously a `&str` that nothing read: the expiry was documented, the
/// table was not going to apply it, and the only thing standing between a correct
/// number and a silently wrong one was someone remembering this date.
pub const SONNET_5_INTRO_ENDS: CivilDate = CivilDate {
    year: 2026,
    month: 8,
    day: 31,
};
// OpenAI GPT-5 family + Codex. Verified against OpenAI's published API price list
// (developers.openai.com/api/docs/pricing) on 2026-07-17 — see the module header's
// "Known inaccuracies", which this change retires for the models actually observed
// in local Codex logs (gpt-5.5, gpt-5.6-sol/terra, gpt-5.4, gpt-5.3-codex).
//
// OpenAI has no separate cache-*write* charge the way Anthropic does: automatic
// prompt caching bills fresh input at the input rate and cached input at a
// discounted "cached input" rate. So `cache_write` == `input` (writing costs
// nothing extra) and `cache_read` is the cached-input price. Codex's local records
// carry no cache-creation tokens anyway, so the write columns never bill.
//
// $5 / $30, cached $0.50 — GPT-5.5 flagship, GPT-5.6-sol.
const GPT5_HIGH: ModelRates = ModelRates {
    input: 5.0,
    output: 30.0,
    cache_write: 5.0,
    cache_write_1h: 5.0,
    cache_read: 0.50,
};
// $2.50 / $15, cached $0.25 — GPT-5.4, GPT-5.6-terra.
const GPT5_MID: ModelRates = ModelRates {
    input: 2.5,
    output: 15.0,
    cache_write: 2.5,
    cache_write_1h: 2.5,
    cache_read: 0.25,
};
// $1.00 / $6, cached $0.10 — GPT-5.6-luna.
const GPT5_LUNA: ModelRates = ModelRates {
    input: 1.0,
    output: 6.0,
    cache_write: 1.0,
    cache_write_1h: 1.0,
    cache_read: 0.10,
};
// $0.75 / $4.50, cached $0.075 — GPT-5.4-mini.
const GPT5_MINI: ModelRates = ModelRates {
    input: 0.75,
    output: 4.50,
    cache_write: 0.75,
    cache_write_1h: 0.75,
    cache_read: 0.075,
};
// $0.20 / $1.25, cached $0.02 — GPT-5.4-nano.
const GPT5_NANO: ModelRates = ModelRates {
    input: 0.20,
    output: 1.25,
    cache_write: 0.20,
    cache_write_1h: 0.20,
    cache_read: 0.02,
};
// $30 / $180 — GPT-5.5-pro, GPT-5.4-pro. No cached-input discount is published, so
// cache reads bill at the full input rate rather than inventing a discount.
const GPT5_PRO: ModelRates = ModelRates {
    input: 30.0,
    output: 180.0,
    cache_write: 30.0,
    cache_write_1h: 30.0,
    cache_read: 30.0,
};
// $1.75 / $14, cached $0.175 — GPT-5.3-codex (the Codex-specialized card).
const CODEX_53: ModelRates = ModelRates {
    input: 1.75,
    output: 14.0,
    cache_write: 1.75,
    cache_write_1h: 1.75,
    cache_read: 0.175,
};

/// Resolve a model string to the rate card in effect **on `date`** — the date of
/// the record being priced, not today. Returns `None` for models we cannot price
/// — the caller must exclude them from cost totals and surface a note (see
/// [`crate::canary`]). **Never guess a price.**
///
/// ## Why the date is a parameter and not a clock read
///
/// Rates change on announced dates. Tokens spent last Tuesday cost what they cost
/// last Tuesday, so the only defensible input is the record's own date — which
/// every caller already holds. Reading the clock here would instead re-price
/// history every time it ran, and would make the day the price changes the one
/// day that cannot be tested.
///
/// `None`-ness does not depend on `date`: a model is priceable or it isn't, and
/// the date only chooses between cards. [`crate::canary`] relies on that — it
/// reads "tokens counted, no cost" as the unpriced-model signal, which would be
/// incoherent if the same model were priceable on some days and not others.
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
pub fn rates_for(model: &str, date: CivilDate) -> Option<ModelRates> {
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
        // Sonnet 5 is the only card with a dated expiry today. `CivilDate` orders
        // chronologically, so the comparison is the whole rule.
        return match family_version(&m, "sonnet") {
            Some((5, _)) if date <= SONNET_5_INTRO_ENDS => Some(SONNET_5_INTRO),
            Some((5, _)) => Some(SONNET),
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
    // OpenAI GPT-5 family + Codex. Now matched to VERIFIED cards by tier, with the
    // same strictness as Claude: a model we don't recognize returns `None` (the
    // canary reports it) rather than borrowing a sibling's rate. This retired a
    // real 3-4× UNDERSTATEMENT — every gpt-5.x was priced at the old flat $1.25/$10
    // card while `gpt-5.5` (the most-used model in local Codex logs) actually bills
    // $5/$30.
    if let Some(card) = openai_rates(&m) {
        return Some(card);
    }
    None
}

/// Resolve an OpenAI model id to its verified rate card, or `None` for anything
/// unrecognized. Kept explicit (not a formula) because OpenAI's tier is a property
/// of the variant name (sol/terra/luna/mini/nano/pro/codex), not a clean function
/// of the version number.
///
/// The `codex-*` **tooling** ids that appear in logs (`codex-auto-review`,
/// `codex-security-scans-…`, `codex-primary-runtime`, …) are deliberately NOT
/// priced: they are not published API models, so their rate is genuinely unknown.
/// Guessing one would be the exact dishonesty this module refuses; the canary
/// surfaces "tokens counted, no known price" instead.
fn openai_rates(m: &str) -> Option<ModelRates> {
    // **Version-strict**, like the Claude path. Match ONLY the specific published
    // (version, variant) pairs verified on 2026-07-17. A later generation
    // (`gpt-6-sol`), an unverified point release (`gpt-5.7-mini`), or a variant we
    // haven't priced returns `None` so the canary reports it — never a same-named
    // tier's card. The first cut of this matched on the variant keyword ALONE
    // (`contains("sol")`), which would have priced a future `gpt-6-sol` at the 5.6
    // card with no drift signal: the exact version-blind mistake that mispriced
    // Opus 3×, reintroduced. Requiring the `gpt-<version>` prefix also stops a date
    // fragment like `2025-3` from being read as `5.3`.
    let gen = |v: &str| m.contains(&format!("gpt-{v}")) || m.contains(&format!("gpt{v}"));

    // 5.3 — Codex-specialized only.
    if (gen("5.3") || gen("5-3")) && m.contains("codex") {
        return Some(CODEX_53);
    }
    // Any other codex id — a codex point release we haven't priced, or the internal
    // `codex-*` tooling ids (codex-auto-review, codex-security-scans-…) — is
    // unpriced, never guessed.
    if m.contains("codex") {
        return None;
    }

    // 5.6 — sol / terra / luna only.
    if gen("5.6") || gen("5-6") {
        if m.contains("sol") {
            return Some(GPT5_HIGH);
        }
        if m.contains("terra") {
            return Some(GPT5_MID);
        }
        if m.contains("luna") {
            return Some(GPT5_LUNA);
        }
        return None; // an unknown 5.6 variant
    }
    // 5.5 — flagship, plus a -pro tier.
    if gen("5.5") || gen("5-5") {
        return Some(if m.contains("pro") {
            GPT5_PRO
        } else {
            GPT5_HIGH
        });
    }
    // 5.4 — mid, plus mini / nano / pro.
    if gen("5.4") || gen("5-4") {
        if m.contains("pro") {
            return Some(GPT5_PRO);
        }
        if m.contains("nano") {
            return Some(GPT5_NANO);
        }
        if m.contains("mini") {
            return Some(GPT5_MINI);
        }
        return Some(GPT5_MID);
    }
    // Any other GPT id (gpt-4*, gpt-5.0/5.7, gpt-6*, o-series) is unpriced rather
    // than mispriced — the canary reports the gap.
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

/// Estimate the cost for `tokens` produced by `model` on `date`, at the rates in
/// effect that day. `None` when unpriceable.
pub fn estimate_cost(model: &str, tokens: &TokenTotals, date: CivilDate) -> Option<f64> {
    rates_for(model, date).map(|r| r.cost(tokens))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The day the cards below were read off the published list ([`PRICING_AS_OF`]),
    /// which is inside Sonnet 5's introductory period.
    const AS_OF: CivilDate = CivilDate {
        year: 2026,
        month: 7,
        day: 16,
    };
    /// The two sides of Sonnet 5's switch, written as literal dates rather than
    /// derived from [`SONNET_5_INTRO_ENDS`]: a test that restates the constant it
    /// is checking would pass just as happily with the constant wrong.
    const LAST_INTRO_DAY: CivilDate = CivilDate {
        year: 2026,
        month: 8,
        day: 31,
    };
    const FIRST_STANDARD_DAY: CivilDate = CivilDate {
        year: 2026,
        month: 9,
        day: 1,
    };

    /// `(input, output, cache_write, cache_read)` for a model on a date.
    fn card(model: &str, date: CivilDate) -> (f64, f64, f64, f64) {
        let r = rates_for(model, date)
            .unwrap_or_else(|| panic!("{model} must be priceable on {}", date.iso()));
        (r.input, r.output, r.cache_write, r.cache_read)
    }

    #[test]
    fn matches_model_families() {
        assert!(rates_for("claude-opus-4-8-20260101", AS_OF).is_some());
        assert!(rates_for("claude-sonnet-5", AS_OF).is_some());
        assert!(rates_for("claude-haiku-4-5-20251001", AS_OF).is_some());
        // The GPT-5 models actually seen in local Codex logs are priceable…
        assert!(rates_for("gpt-5.5", AS_OF).is_some());
        assert!(rates_for("gpt-5.6-sol", AS_OF).is_some());
        assert!(rates_for("gpt-5.3-codex", AS_OF).is_some());
        // …but a bare/older/unverified GPT id is UNPRICED, not mispriced — the same
        // strictness as Claude, so the canary reports it instead of the app
        // borrowing a wrong sibling rate.
        assert!(rates_for("gpt-5", AS_OF).is_none());
        assert!(rates_for("gpt-5-codex", AS_OF).is_none());
        assert!(rates_for("gpt-4o", AS_OF).is_none());
        // Internal Codex tooling ids have no published rate → unpriced, never guessed.
        assert!(rates_for("codex-auto-review", AS_OF).is_none());
        assert!(rates_for("codex-security-scans-fox", AS_OF).is_none());
        assert!(rates_for("totally-unknown-model", AS_OF).is_none());
        // VERSION-STRICT: a variant name alone must not price a different
        // generation. A future gpt-6 / gpt-5.7 sharing a tier name is UNPRICED,
        // not silently priced at the 5.x card (the version-blind bug that
        // mispriced Opus 3×, guarded here for OpenAI too).
        assert!(rates_for("gpt-6-sol", AS_OF).is_none());
        assert!(rates_for("gpt-6-mini", AS_OF).is_none());
        assert!(rates_for("gpt-5.7-terra", AS_OF).is_none());
        assert!(rates_for("gpt-5.3-turbo", AS_OF).is_none()); // 5.3 is codex-only
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
            ("claude-mythos-5", 10.0, 50.0, 12.50, 1.00),
            ("claude-sonnet-5", 2.0, 10.0, 2.50, 0.20), // introductory, on this date
            ("claude-sonnet-4-6", 3.0, 15.0, 3.75, 0.30),
            ("claude-haiku-4-5-20251001", 1.0, 5.0, 1.25, 0.10),
            ("claude-haiku-3-5-20241022", 0.80, 4.0, 1.00, 0.08),
            // OpenAI GPT-5 family + Codex, verified 2026-07-17. Source:
            // developers.openai.com/api/docs/pricing. These are the models observed
            // in real local Codex logs; pinning them is what keeps the 3-4×
            // understatement (gpt-5.5 was billed $1.25/$10) from silently returning.
            // cache_write == input (OpenAI has no separate write charge).
            ("gpt-5.5", 5.0, 30.0, 5.0, 0.50),
            ("gpt-5.6-sol", 5.0, 30.0, 5.0, 0.50),
            ("gpt-5.4", 2.5, 15.0, 2.5, 0.25),
            ("gpt-5.6-terra", 2.5, 15.0, 2.5, 0.25),
            ("gpt-5.6-luna", 1.0, 6.0, 1.0, 0.10),
            ("gpt-5.4-mini", 0.75, 4.50, 0.75, 0.075),
            ("gpt-5.4-nano", 0.20, 1.25, 0.20, 0.02),
            ("gpt-5.5-pro", 30.0, 180.0, 30.0, 30.0),
            ("gpt-5.3-codex", 1.75, 14.0, 1.75, 0.175),
        ];
        for (model, input, output, write, read) in cases {
            assert_eq!(card(model, AS_OF), (input, output, write, read), "{model}");
        }
    }

    /// Sonnet 5's introductory rate is in effect through its last day — the
    /// boundary is inclusive, and an off-by-one here silently overcharges a day.
    #[test]
    fn sonnet_5_prices_at_the_introductory_rate_through_the_last_intro_day() {
        assert_eq!(
            card("claude-sonnet-5", LAST_INTRO_DAY),
            (2.0, 10.0, 2.50, 0.20)
        );
        assert_eq!(
            card("claude-sonnet-5-20260401", LAST_INTRO_DAY),
            (2.0, 10.0, 2.50, 0.20),
            "a date-stamped id is the same model"
        );
    }

    /// The failure this whole change exists to prevent: on 2026-09-01 Sonnet 5
    /// reverts to the standard Sonnet card. The old table had no clock, so it
    /// would have kept charging the introductory rate — wrong, silently, forever.
    #[test]
    fn sonnet_5_prices_at_the_standard_rate_once_the_intro_ends() {
        assert_eq!(
            card("claude-sonnet-5", FIRST_STANDARD_DAY),
            (3.0, 15.0, 3.75, 0.30)
        );
        // ...and stays there.
        let far_future = CivilDate {
            year: 2030,
            month: 1,
            day: 1,
        };
        assert_eq!(card("claude-sonnet-5", far_future), (3.0, 15.0, 3.75, 0.30));
        // Post-intro Sonnet 5 is exactly the standard Sonnet card, not a copy of it.
        assert_eq!(
            card("claude-sonnet-5", FIRST_STANDARD_DAY),
            card("claude-sonnet-4-6", FIRST_STANDARD_DAY)
        );
    }

    /// The capability the old signature could not express at all: one window,
    /// two rates. A 30-day window straddling 2026-09-01 holds records of both.
    #[test]
    fn the_same_record_prices_differently_on_each_side_of_the_switch() {
        let t = TokenTotals {
            input_tokens: 1_000_000,
            output_tokens: 1_000_000,
            ..Default::default()
        };
        let intro = estimate_cost("claude-sonnet-5", &t, LAST_INTRO_DAY).unwrap();
        let standard = estimate_cost("claude-sonnet-5", &t, FIRST_STANDARD_DAY).unwrap();
        assert_eq!(intro, 2.0 + 10.0);
        assert_eq!(standard, 3.0 + 15.0);
        assert!(intro < standard, "the introductory rate is the cheaper one");
    }

    /// Only Sonnet 5 has a dated expiry. Every other card must be indifferent to
    /// the date — a date-aware lookup that quietly moved another family's price
    /// would be the same silent-wrongness bug wearing a clock.
    #[test]
    fn other_families_are_unaffected_by_date() {
        let dates = [
            CivilDate {
                year: 2024,
                month: 1,
                day: 1,
            },
            AS_OF,
            LAST_INTRO_DAY,
            FIRST_STANDARD_DAY,
            CivilDate {
                year: 2030,
                month: 6,
                day: 30,
            },
        ];
        let cases = [
            ("claude-opus-4-8", (5.0, 25.0, 6.25, 0.50)),
            ("claude-opus-4-1-20250805", (15.0, 75.0, 18.75, 1.50)),
            ("claude-fable-5", (10.0, 50.0, 12.50, 1.00)),
            ("claude-mythos-5", (10.0, 50.0, 12.50, 1.00)),
            ("claude-sonnet-4-6", (3.0, 15.0, 3.75, 0.30)),
            ("claude-haiku-4-5-20251001", (1.0, 5.0, 1.25, 0.10)),
            ("claude-haiku-3-5-20241022", (0.80, 4.0, 1.00, 0.08)),
            // OpenAI cards carry no announced expiry (unlike Sonnet 5's intro), so a
            // real GPT model must price identically on every date.
            ("gpt-5.3-codex", (1.75, 14.0, 1.75, 0.175)),
            ("gpt-5.5", (5.0, 30.0, 5.0, 0.50)),
        ];
        for (model, expected) in cases {
            for date in dates {
                assert_eq!(card(model, date), expected, "{model} on {}", date.iso());
            }
        }
    }

    /// The bug that made this rewrite necessary: "contains(\"opus\")" priced Opus
    /// 4.8 with Opus 4.1's card. The two must never resolve to the same rates.
    #[test]
    fn opus_versions_are_not_interchangeable() {
        let current = rates_for("claude-opus-4-8", AS_OF).unwrap();
        let legacy = rates_for("claude-opus-4-1-20250805", AS_OF).unwrap();
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
    ///
    /// This holds on every date. Priceability is a property of the model id alone,
    /// and [`crate::canary`] reads "tokens but no cost" as the unpriced signal — a
    /// model that were priceable only on some days would make that signal a lie.
    #[test]
    fn an_unknown_version_of_a_known_family_is_unpriced_at_any_date() {
        let dates = [
            CivilDate {
                year: 2024,
                month: 1,
                day: 1,
            },
            AS_OF,
            LAST_INTRO_DAY,
            FIRST_STANDARD_DAY,
            CivilDate {
                year: 2030,
                month: 6,
                day: 30,
            },
        ];
        for date in dates {
            assert!(rates_for("claude-opus-9-0", date).is_none());
            assert!(rates_for("claude-sonnet-7", date).is_none());
            assert!(rates_for("claude-sonnet-6", date).is_none());
            assert!(rates_for("claude-haiku-9-9", date).is_none());
            // ...and the real one that showed up in local logs with no version at all.
            assert!(rates_for("<synthetic>", date).is_none());
        }
    }

    /// A 1-hour cache write bills at 2× input; a 5-minute one at 1.25×. Pricing
    /// every write as 5-minute understated real cost — 86% of writes on a real
    /// machine are 1-hour.
    #[test]
    fn one_hour_cache_writes_cost_more_than_five_minute_ones() {
        let rates = rates_for("claude-opus-4-8", AS_OF).unwrap();
        let all_5m = TokenTotals {
            cache_creation_tokens: 1_000_000,
            ..Default::default()
        };
        let all_1h = TokenTotals {
            cache_creation_tokens: 1_000_000,
            cache_creation_1h_tokens: 1_000_000,
            ..Default::default()
        };
        assert_eq!(rates.cost(&all_5m), 6.25); // published 5-min write
        assert_eq!(rates.cost(&all_1h), 10.0); // published 1-hour write
        assert!(rates.cost(&all_1h) > rates.cost(&all_5m));
    }

    /// The field is a SUBSET of `cache_creation_tokens`, so a mixed record must
    /// price each half once — never double-count, never lose a token.
    #[test]
    fn a_mixed_record_prices_each_half_exactly_once() {
        let rates = rates_for("claude-opus-4-8", AS_OF).unwrap();
        let mixed = TokenTotals {
            cache_creation_tokens: 1_000_000,
            cache_creation_1h_tokens: 800_000, // 80% 1-hour, like real logs
            ..Default::default()
        };
        // 0.8M @ $10 + 0.2M @ $6.25 = 8.00 + 1.25
        assert_eq!(rates.cost(&mixed), 9.25);
        // The subset must not inflate the token total.
        assert_eq!(mixed.grand_total(), 1_000_000);
    }

    /// A malformed record claiming more 1-hour writes than writes must not
    /// underflow or invent cost. Degrade, never panic.
    #[test]
    fn an_impossible_split_is_clamped() {
        let rates = rates_for("claude-opus-4-8", AS_OF).unwrap();
        let bogus = TokenTotals {
            cache_creation_tokens: 100,
            cache_creation_1h_tokens: 999_999,
            ..Default::default()
        };
        let (one_hour, five_min) = bogus.cache_write_split();
        assert_eq!((one_hour, five_min), (100, 0));
        assert_eq!(rates.cost(&bogus), 100.0 * 10.0 / 1_000_000.0);
    }

    /// Codex never sets the 1-hour-TTL field, so its cache-write split is a no-op
    /// and its cost is a plain input+output+read sum at the verified card.
    #[test]
    fn a_provider_without_the_ttl_concept_prices_unchanged() {
        let rates = rates_for("gpt-5.3-codex", AS_OF).unwrap();
        let t = TokenTotals {
            input_tokens: 1_000_000,
            output_tokens: 1_000_000,
            cache_read_tokens: 1_000_000,
            ..Default::default()
        };
        assert_eq!(rates.cost(&t), 1.75 + 14.0 + 0.175);
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
        let opus = estimate_cost("claude-opus-4", &t, AS_OF).unwrap();
        let sonnet = estimate_cost("claude-sonnet-4", &t, AS_OF).unwrap();
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
        let a = estimate_cost("claude-sonnet-4", &fresh, AS_OF).unwrap();
        let b = estimate_cost("claude-sonnet-4", &cached, AS_OF).unwrap();
        assert!(b < a);
    }
}
