//! Platform-neutral filesystem discovery.
//!
//! The core must build and run on non-macOS targets (ADR-0005). It therefore
//! never hardcodes `/Users/...`; it resolves roots from environment variables
//! with sensible fallbacks, mirroring how the provider CLIs themselves resolve
//! their config. macOS-specific niceties (Keychain, security-scoped bookmarks)
//! live in the Swift layer, not here.

use std::path::PathBuf;

/// The user's home directory, from `$HOME` (unix) or `%USERPROFILE%` (windows).
pub fn home_dir() -> Option<PathBuf> {
    if let Ok(h) = std::env::var("HOME") {
        if !h.is_empty() {
            return Some(PathBuf::from(h));
        }
    }
    if let Ok(h) = std::env::var("USERPROFILE") {
        if !h.is_empty() {
            return Some(PathBuf::from(h));
        }
    }
    None
}

/// Split a `PATH`-style, comma-separated env override into existing directories.
fn split_env_dirs(value: &str) -> Vec<PathBuf> {
    value
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .collect()
}

/// Candidate Claude config roots, in priority order, matching Claude Code's own
/// resolution: `$CLAUDE_CONFIG_DIR` (comma-separated) → `$XDG_CONFIG_HOME/claude`
/// → `~/.config/claude` → `~/.claude`. Only existing directories are returned.
pub fn claude_roots() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(v) = std::env::var("CLAUDE_CONFIG_DIR") {
        out.extend(split_env_dirs(&v));
    }
    if let Ok(x) = std::env::var("XDG_CONFIG_HOME") {
        if !x.is_empty() {
            out.push(PathBuf::from(x).join("claude"));
        }
    }
    if let Some(home) = home_dir() {
        out.push(home.join(".config").join("claude"));
        out.push(home.join(".claude"));
    }
    dedup_existing(out)
}

/// Candidate Codex home roots: `$CODEX_HOME` (comma-separated) → `~/.codex`.
pub fn codex_roots() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Ok(v) = std::env::var("CODEX_HOME") {
        out.extend(split_env_dirs(&v));
    }
    if let Some(home) = home_dir() {
        out.push(home.join(".codex"));
    }
    dedup_existing(out)
}

/// Keep only directories that exist, preserving order and removing duplicates.
fn dedup_existing(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for p in paths {
        let canon = p.canonicalize().unwrap_or_else(|_| p.clone());
        if p.is_dir() && seen.insert(canon) {
            out.push(p);
        }
    }
    out
}

/// Recursively collect files under `dir` whose name matches `pred`, bounded by
/// `max_depth` to avoid runaway traversal of a mis-pointed root. Symlinked
/// directories are **not** followed (path-traversal / symlink-loop guard).
pub fn collect_files<F>(dir: &PathBuf, max_depth: usize, pred: &F) -> Vec<PathBuf>
where
    F: Fn(&str) -> bool,
{
    let mut out = Vec::new();
    collect_files_inner(dir, max_depth, pred, &mut out);
    out
}

fn collect_files_inner<F>(dir: &PathBuf, depth: usize, pred: &F, out: &mut Vec<PathBuf>)
where
    F: Fn(&str) -> bool,
{
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        // Do not traverse symlinks — prevents symlink loops and escaping the
        // approved root (threat model: symlink/path traversal).
        let file_type = match entry.file_type() {
            Ok(t) => t,
            Err(_) => continue,
        };
        if file_type.is_symlink() {
            continue;
        }
        let path = entry.path();
        if file_type.is_dir() {
            if depth > 0 {
                collect_files_inner(&path, depth - 1, pred, out);
            }
        } else if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
            if pred(name) {
                out.push(path);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_handles_blank_and_spaces() {
        assert_eq!(split_env_dirs(" a , ,b ,").len(), 2);
        assert!(split_env_dirs("").is_empty());
    }
}
