//! Detection-only adapters (data-driven).
//!
//! Claude and Codex have full local cost scanners. The other nine supported
//! providers ship in this version as **detection-only**: they honestly report
//! whether the tool looks installed and/or authenticated on this machine and
//! advertise a capability matrix in which everything usage/cost/limit/control
//! related is `Unsupported` or `Unavailable`. They never scan usage, never
//! invent numbers, and never read a secret's contents (auth is presence-only).
//!
//! One [`DetectableProvider`] struct plus one `impl Provider` drives all nine;
//! each provider is a small constructor filling in its detection [`Markers`] and
//! two honesty toggles (`detects_install`, `detects_auth`).
//!
//! ## Honesty rules encoded here
//! - Prefer [`IntegrationHealth::NotDetected`] over a false positive. Providers
//!   that are inherently cloud / API-key based with nothing locally verifiable
//!   (Devin, OpenRouter, Z.ai) carry no markers and therefore always report
//!   NotDetected with an "add a key in Settings (planned)" note.
//! - Every marker path below is commented with a confidence note. Several are
//!   best-effort / unverified and are safe to extend once confirmed — a wrong
//!   guess simply yields NotDetected, never a fake "installed".
//! - `installed` = any install marker present (or credentials present, since
//!   credentials imply a local setup). `authenticated` = a designated
//!   credential marker present (presence only — the file is never opened).
//!
//! Everything here is platform-neutral (ADR-0005): paths resolve through
//! [`crate::paths`] and `$HOME`/`$PATH`; the only macOS-flavored check is the
//! `/Applications/<Name>.app` probe, which harmlessly misses on other OSes.

use super::Provider;
use crate::paths;
use stackpulse_protocol::{
    Capability as Cap, CapabilityState, IntegrationHealth, ProviderId, ProviderStatus,
    ProviderUsage,
};
use std::path::PathBuf;

/// Best-effort detection markers for one provider. All paths in `config_dirs`
/// and `credential_files` are relative to `$HOME`. Forward slashes are used as
/// separators and are accepted on every target OS by [`std::path::Path::join`].
struct Markers {
    /// Config directories under `$HOME`. Presence ⇒ the tool was set up locally.
    config_dirs: &'static [&'static str],
    /// Executable names to look for on `$PATH`.
    cli_names: &'static [&'static str],
    /// macOS `.app` bundle base names, probed under `/Applications` and
    /// `~/Applications`. Ignored (never matches) on non-macOS hosts.
    app_bundles: &'static [&'static str],
    /// Credential markers under `$HOME`. Presence ⇒ authenticated. The file is
    /// NEVER opened or parsed — presence is the entire signal.
    credential_files: &'static [&'static str],
}

/// A provider whose integration is detection-only in this version.
pub struct DetectableProvider {
    id: ProviderId,
    markers: Markers,
    /// True when we implement a local install probe for this provider, so
    /// [`Cap::InstalledAppDetection`] is honestly `Supported`. False for pure
    /// cloud/API providers with no local footprint.
    detects_install: bool,
    /// True when we have an honest, non-secret credential-presence marker, so
    /// [`Cap::AuthDetection`] is honestly `Supported`.
    detects_auth: bool,
}

/// Result of a detection pass.
struct Detected {
    installed: bool,
    authenticated: bool,
}

impl DetectableProvider {
    /// Run the (cheap, filesystem-only) detection pass.
    fn detect(&self) -> Detected {
        let authenticated = self
            .markers
            .credential_files
            .iter()
            .any(|rel| file_present_under_home(rel));
        // Credentials imply a local setup, so treat auth as sufficient for
        // "installed" even if no config dir / CLI / app bundle turned up.
        let installed = authenticated || self.install_markers_present();
        Detected {
            installed,
            authenticated,
        }
    }

    /// True if any install marker (config dir, CLI on `$PATH`, or app bundle)
    /// is present.
    fn install_markers_present(&self) -> bool {
        if self
            .markers
            .config_dirs
            .iter()
            .any(|rel| dir_present_under_home(rel))
        {
            return true;
        }
        if self
            .markers
            .app_bundles
            .iter()
            .any(|b| app_bundle_present(b))
        {
            return true;
        }
        self.markers.cli_names.iter().any(|c| cli_on_path(c))
    }

    fn health(&self, installed: bool) -> IntegrationHealth {
        if installed {
            // Detection works, but usage/cost scanning does not yet exist for
            // this provider — that is a partial, not full, integration.
            IntegrationHealth::PartiallySupported
        } else {
            IntegrationHealth::NotDetected
        }
    }

    fn notes(&self, d: &Detected) -> Vec<String> {
        let name = self.id.display_name();
        let note = if d.installed {
            let auth = if d.authenticated {
                ", authenticated"
            } else {
                ""
            };
            format!(
                "Detected {name} (installed{auth}). Usage and cost scanning for \
                 {name} is not implemented yet — detection only in this version."
            )
        } else if self.detects_install {
            format!(
                "{name} not detected on this machine. Detection is best-effort \
                 (config dir, CLI on PATH, or app bundle) and detection-only in \
                 this version."
            )
        } else {
            format!(
                "{name} is an API-key integration with no local footprint to \
                 detect — add a key in Settings (planned). Detection only in \
                 this version."
            )
        };
        vec![note]
    }
}

impl Provider for DetectableProvider {
    fn id(&self) -> ProviderId {
        self.id
    }

    fn capabilities(&self) -> Vec<(Cap, CapabilityState)> {
        build_capabilities(self.detects_install, self.detects_auth)
    }

    fn status(&self) -> ProviderStatus {
        let d = self.detect();
        ProviderStatus {
            provider: self.id,
            display_name: self.id.display_name().to_string(),
            installed: d.installed,
            authenticated: d.authenticated,
            health: self.health(d.installed),
            detected_version: None,
        }
    }

    fn scan(&self, _now_unix: i64) -> ProviderUsage {
        let d = self.detect();
        ProviderUsage {
            provider: self.id,
            display_name: self.id.display_name().to_string(),
            health: self.health(d.installed),
            installed: d.installed,
            authenticated: d.authenticated,
            detected_version: None,
            plan_hint: None,
            // Detection-only: no usage is measured, so these stay empty and the
            // UI shows only the detected state + capability matrix + note.
            windows: Vec::new(),
            models: Vec::new(),
            limits: Vec::new(),
            capabilities: self.capabilities(),
            notes: self.notes(&d),
            // Detection-only: no measured usage, so no analytics.
            analytics: None,
            balance: None,
        }
    }
}

/// The honest, fully-enumerated capability matrix shared by every
/// detection-only provider. Only [`Cap::InstalledAppDetection`] and
/// [`Cap::AuthDetection`] can be `Supported` (and only when we actually have a
/// probe for them); usage/cost/limit surfaces that a future authenticated API
/// could power are `Unavailable`; everything else is `Unsupported`.
fn build_capabilities(detects_install: bool, detects_auth: bool) -> Vec<(Cap, CapabilityState)> {
    use CapabilityState::{Supported, Unavailable, Unsupported};
    let install_state = if detects_install {
        Supported
    } else {
        Unsupported
    };
    let auth_state = if detects_auth { Supported } else { Unsupported };
    vec![
        (Cap::InstalledAppDetection, install_state),
        (Cap::AuthDetection, auth_state),
        // We do not parse a version string in detection-only mode.
        (Cap::VersionDetection, Unsupported),
        // No local log scanning is implemented for these providers.
        (Cap::LocalCostScan, Unsupported),
        (Cap::ModelBreakdown, Unsupported),
        (Cap::CacheMetrics, Unsupported),
        (Cap::LocalSessionHistory, Unsupported),
        (Cap::ProjectAssociation, Unsupported),
        // Live-task and remote-control surfaces are not wired for these.
        (Cap::LiveTaskDetection, Unsupported),
        (Cap::CompletionDetection, Unsupported),
        (Cap::WaitingForInputDetection, Unsupported),
        (Cap::ToolCallVisibility, Unsupported),
        (Cap::ConversationPreview, Unsupported),
        (Cap::Reply, Unsupported),
        (Cap::ApproveReject, Unsupported),
        (Cap::Stop, Unsupported),
        (Cap::Resume, Unsupported),
        (Cap::DeepLink, Unsupported),
        (Cap::RemoteTaskState, Unsupported),
        // Usage limits & spend are implementable via a future authenticated API
        // integration — possible in principle, but not available right now.
        (Cap::SessionLimits, Unavailable),
        (Cap::WeeklyLimits, Unavailable),
        (Cap::CreditsAndSpend, Unavailable),
    ]
}

// ---------------------------------------------------------------------------
// Filesystem / $PATH probes (platform-neutral, presence-only)
// ---------------------------------------------------------------------------

fn dir_present_under_home(rel: &str) -> bool {
    paths::home_dir()
        .map(|h| h.join(rel).is_dir())
        .unwrap_or(false)
}

fn file_present_under_home(rel: &str) -> bool {
    paths::home_dir()
        .map(|h| h.join(rel).is_file())
        .unwrap_or(false)
}

/// Probe `/Applications/<name>.app` and `~/Applications/<name>.app`. macOS-only
/// in effect; simply never matches on other platforms.
fn app_bundle_present(name: &str) -> bool {
    let bundle = format!("{name}.app");
    if PathBuf::from("/Applications").join(&bundle).is_dir() {
        return true;
    }
    paths::home_dir()
        .map(|h| h.join("Applications").join(&bundle).is_dir())
        .unwrap_or(false)
}

/// True if an executable named `name` is found in any `$PATH` directory. We
/// check for file presence (not the exec bit) to stay `cfg`-free and portable;
/// a `$PATH` bin directory is an unambiguous enough location that presence is a
/// good signal. Common Windows extensions are also probed.
fn cli_on_path(name: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    for dir in std::env::split_paths(&path) {
        if dir.as_os_str().is_empty() {
            continue;
        }
        if dir.join(name).is_file() {
            return true;
        }
        for ext in ["exe", "cmd", "bat"] {
            if dir.join(format!("{name}.{ext}")).is_file() {
                return true;
            }
        }
    }
    false
}

// ---------------------------------------------------------------------------
// Per-provider constructors
// ---------------------------------------------------------------------------
//
// Marker confidence is noted inline. "unverified" markers are educated guesses
// that are safe to keep: if wrong, they just fail to match (NotDetected) rather
// than producing a false positive.

/// Antigravity (Google's agentic IDE). Best-effort app/config/CLI probes; the
/// exact on-disk names are **unverified**, so absence yields an honest
/// NotDetected with the API-key note.
fn antigravity() -> DetectableProvider {
    DetectableProvider {
        id: ProviderId::Antigravity,
        markers: Markers {
            // unverified — likely IDE dotfiles once the tool is installed.
            config_dirs: &[".antigravity", ".config/antigravity"],
            cli_names: &["antigravity"],   // unverified
            app_bundles: &["Antigravity"], // unverified bundle name
            credential_files: &[],         // no non-secret auth marker known
        },
        detects_install: true,
        detects_auth: false,
    }
}

/// GitHub Copilot. `~/.config/github-copilot/` holds `hosts.json` / `apps.json`
/// written by the Copilot CLI and editor auth flow — medium-high confidence,
/// and their presence is a legitimate (presence-only) authentication signal.
fn copilot() -> DetectableProvider {
    DetectableProvider {
        id: ProviderId::Copilot,
        markers: Markers {
            config_dirs: &[".config/github-copilot"], // confident
            cli_names: &["copilot"],                  // GitHub Copilot CLI binary; confident
            app_bundles: &[], // Copilot ships as an editor extension, not a .app
            credential_files: &[
                ".config/github-copilot/apps.json",  // confident (oauth hosts)
                ".config/github-copilot/hosts.json", // confident (legacy name)
            ],
        },
        detects_install: true,
        detects_auth: true,
    }
}

/// Cursor (VS Code fork). `/Applications/Cursor.app`, `~/.cursor`, and the
/// `cursor` shell command are all confident install markers. Auth lives in the
/// app's encrypted storage with no clean non-secret marker, so we do not claim
/// auth detection.
fn cursor() -> DetectableProvider {
    DetectableProvider {
        id: ProviderId::Cursor,
        markers: Markers {
            config_dirs: &[".cursor"], // confident (~/.cursor holds extensions)
            cli_names: &["cursor"],    // confident (installed by the app)
            app_bundles: &["Cursor"],  // confident (/Applications/Cursor.app)
            credential_files: &[],     // no clean non-secret auth marker
        },
        detects_install: true,
        detects_auth: false,
    }
}

/// Devin (Cognition). Cloud web agent — no local install or CLI. Always
/// NotDetected; an API-key integration is planned.
fn devin() -> DetectableProvider {
    DetectableProvider {
        id: ProviderId::Devin,
        markers: Markers {
            config_dirs: &[],
            cli_names: &[],
            app_bundles: &[],
            credential_files: &[],
        },
        detects_install: false,
        detects_auth: false,
    }
}

/// Gemini (Google). Detected via the Gemini CLI's own markers: the `gemini`
/// binary on `$PATH` and its OAuth creds file `~/.gemini/oauth_creds.json`
/// (confident, per CodexBar). We deliberately do NOT treat the `~/.gemini`
/// directory itself as an install marker — Antigravity also writes there, so
/// that would false-positive. Full quota needs Google's OAuth usage API (future,
/// network); this is detection-only for now.
fn gemini() -> DetectableProvider {
    DetectableProvider {
        id: ProviderId::Gemini,
        markers: Markers {
            config_dirs: &[], // ~/.gemini is shared with Antigravity — avoid false positives
            cli_names: &["gemini"], // Gemini CLI binary (confident)
            app_bundles: &[],
            credential_files: &[".gemini/oauth_creds.json"], // Gemini CLI OAuth creds (confident)
        },
        detects_install: true,
        detects_auth: true,
    }
}

/// Grok (xAI). Primarily web/mobile; a local CLI or app is **unverified**, so
/// these probes are best-effort and default to NotDetected when absent.
fn grok() -> DetectableProvider {
    DetectableProvider {
        id: ProviderId::Grok,
        markers: Markers {
            config_dirs: &[".grok"], // unverified
            cli_names: &["grok"],    // unverified community/xAI CLI
            app_bundles: &["Grok"],  // unverified bundle name
            credential_files: &[],   // no non-secret auth marker known
        },
        detects_install: true,
        detects_auth: false,
    }
}

/// OpenCode (sst/opencode terminal agent). `~/.config/opencode` and the
/// `opencode` CLI are confident install markers; `~/.local/share/opencode/
/// auth.json` is where it stores provider auth — presence-only, medium
/// confidence.
fn opencode() -> DetectableProvider {
    DetectableProvider {
        id: ProviderId::OpenCode,
        markers: Markers {
            config_dirs: &[".config/opencode", ".opencode"], // confident / fallback
            cli_names: &["opencode"],                        // confident
            app_bundles: &[],
            credential_files: &[".local/share/opencode/auth.json"], // medium confidence
        },
        detects_install: true,
        detects_auth: true,
    }
}

/// OpenRouter. API aggregator — an API key only, no local footprint. Always
/// NotDetected; an API-key integration is planned.
fn openrouter() -> DetectableProvider {
    DetectableProvider {
        id: ProviderId::OpenRouter,
        markers: Markers {
            config_dirs: &[],
            cli_names: &[],
            app_bundles: &[],
            credential_files: &[],
        },
        detects_install: false,
        detects_auth: false,
    }
}

/// Z.ai (Zhipu GLM). API key only, no standard local install. Always
/// NotDetected; an API-key integration is planned.
fn zai() -> DetectableProvider {
    DetectableProvider {
        id: ProviderId::Zai,
        markers: Markers {
            config_dirs: &[],
            cli_names: &[],
            app_bundles: &[],
            credential_files: &[],
        },
        detects_install: false,
        detects_auth: false,
    }
}

/// The nine detection-only providers, returned in the [`ProviderId`] enum's
/// declared order (Antigravity, Copilot, Cursor, Devin, Gemini, Grok, OpenCode,
/// OpenRouter, Zai). The engine registers these after Claude and Codex.
pub fn detection_providers() -> Vec<DetectableProvider> {
    vec![
        antigravity(),
        copilot(),
        cursor(),
        devin(),
        gemini(),
        grok(),
        opencode(),
        openrouter(),
        zai(),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn covers_every_capability_variant_once() {
        // Guards against forgetting a Capability if the protocol grows.
        let caps = build_capabilities(true, true);
        assert_eq!(caps.len(), 22);
        // No duplicate capability keys.
        let mut keys: Vec<_> = caps.iter().map(|(c, _)| format!("{c:?}")).collect();
        keys.sort();
        keys.dedup();
        assert_eq!(keys.len(), 22);
    }

    #[test]
    fn cloud_only_providers_report_not_detected_without_markers() {
        // Devin/OpenRouter/Z.ai have no markers, so regardless of the host they
        // must report NotDetected and never claim install/auth detection.
        for p in [devin(), openrouter(), zai()] {
            let status = p.status();
            assert!(!status.installed);
            assert!(!status.authenticated);
            assert_eq!(status.health, IntegrationHealth::NotDetected);
            let caps = p.capabilities();
            let install = caps
                .iter()
                .find(|(c, _)| *c == Cap::InstalledAppDetection)
                .map(|(_, s)| *s);
            assert_eq!(install, Some(CapabilityState::Unsupported));
        }
    }

    #[test]
    fn app_based_providers_advertise_install_detection() {
        // These implement a local probe, so InstalledAppDetection is Supported
        // (whether or not the tool is actually present on this machine).
        for p in [
            antigravity(),
            copilot(),
            cursor(),
            gemini(),
            grok(),
            opencode(),
        ] {
            let caps = p.capabilities();
            let install = caps
                .iter()
                .find(|(c, _)| *c == Cap::InstalledAppDetection)
                .map(|(_, s)| *s);
            assert_eq!(install, Some(CapabilityState::Supported));
        }
    }

    #[test]
    fn scan_never_produces_usage_windows() {
        for p in detection_providers() {
            let usage = p.scan(0);
            assert!(usage.windows.is_empty());
            assert!(usage.models.is_empty());
            assert!(usage.limits.is_empty());
            assert!(!usage.notes.is_empty());
        }
    }

    #[test]
    fn returns_all_nine_in_declared_order() {
        let ids: Vec<ProviderId> = detection_providers().iter().map(|p| p.id()).collect();
        assert_eq!(
            ids,
            vec![
                ProviderId::Antigravity,
                ProviderId::Copilot,
                ProviderId::Cursor,
                ProviderId::Devin,
                ProviderId::Gemini,
                ProviderId::Grok,
                ProviderId::OpenCode,
                ProviderId::OpenRouter,
                ProviderId::Zai,
            ]
        );
    }
}
