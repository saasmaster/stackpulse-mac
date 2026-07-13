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

use stackpulse_protocol::TokenTotals;

/// Human-readable provenance note attached to every snapshot.
pub const PRICING_AS_OF: &str = "2026-07";

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

// Approximate public list prices (USD / 1M tokens), as of PRICING_AS_OF.
const OPUS: ModelRates = ModelRates {
    input: 15.0,
    output: 75.0,
    cache_write: 18.75,
    cache_read: 1.50,
};
const SONNET: ModelRates = ModelRates {
    input: 3.0,
    output: 15.0,
    cache_write: 3.75,
    cache_read: 0.30,
};
const HAIKU: ModelRates = ModelRates {
    input: 1.0,
    output: 5.0,
    cache_write: 1.25,
    cache_read: 0.10,
};
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

/// Resolve a model string to a rate card via tolerant substring matching.
/// Returns `None` for models we cannot price (caller must exclude them from
/// cost totals and surface a note — never guess a price).
pub fn rates_for(model: &str) -> Option<ModelRates> {
    let m = model.to_ascii_lowercase();
    // Order matters: more specific families first.
    if m.contains("opus") {
        Some(OPUS)
    } else if m.contains("sonnet") {
        Some(SONNET)
    } else if m.contains("haiku") {
        Some(HAIKU)
    } else if m.contains("codex")
        || m.contains("gpt-5")
        || m.contains("gpt5")
        || m.contains("o4")
        || m.contains("o3")
    {
        Some(GPT5)
    } else if m.contains("gpt-4") || m.contains("gpt4") {
        Some(GPT41)
    } else {
        None
    }
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
