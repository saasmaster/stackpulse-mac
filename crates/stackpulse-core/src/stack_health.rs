//! Stack Health — per-project dependency / version / security intelligence.
//!
//! Reads a project's manifests + lockfiles (npm, Cargo, PyPI, …) into a
//! dependency inventory, and — when a network check is allowed — compares each
//! against the official registry's latest version and OSV advisories. Everything
//! degrades gracefully: offline, it returns the local inventory with
//! `checked_updates = false`.
//!
//! **Portability (ADR-0005):** the core stays pure Rust, offline, and
//! cross-compiles to Windows/Linux in CI. So this module produces a *local
//! inventory only*: it parses manifests + lockfiles into dependencies with their
//! declared range (`required`) and, when a lockfile resolves it, their concrete
//! `installed` version. `latest`, `status`, and `advisories` are left empty for
//! the macOS Swift layer to fill in over the network. `check_updates` is accepted
//! for wire-compatibility but ignored here (the network step lives in Swift).
//!
//! v1 ecosystems: **npm** and **cargo** — the vast majority of this user's
//! projects. Everything is best-effort over static files: an unreadable or
//! malformed file degrades to "no data", never a panic.

use serde::Deserialize;
use stackpulse_protocol::{Dependency, DependencyStatus, ProjectStack, StackSummary};
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

/// Analyze the stack health of every project found under the approved roots.
/// `_check_updates` gates network access — which this portable core never does,
/// so it is ignored here; the Swift layer performs registry/OSV lookups.
pub fn analyze(roots: &[String], max_depth: u32, _check_updates: bool) -> Vec<ProjectStack> {
    let mut out = Vec::new();
    for project in crate::projects::discover(roots, max_depth) {
        let dir = Path::new(&project.path);
        if let Some(stack) = analyze_project(dir, &project) {
            out.push(stack);
        }
    }
    out
}

/// Build a [`ProjectStack`] for one discovered project, or `None` when it has no
/// supported (npm / cargo) manifest.
fn analyze_project(dir: &Path, project: &stackpulse_protocol::Project) -> Option<ProjectStack> {
    let has_npm = dir.join("package.json").is_file();
    let has_cargo = dir.join("Cargo.toml").is_file();
    if !has_npm && !has_cargo {
        return None;
    }

    let mut dependencies: Vec<Dependency> = Vec::new();
    let mut notes: Vec<String> = Vec::new();

    // Prefer whichever ecosystem the package manager points at; otherwise npm
    // leads (it's the more common case in this portfolio).
    let ecosystem = match project.package_manager.as_deref() {
        Some("cargo") if has_cargo => "cargo",
        Some(_) if has_npm => "npm",
        _ if has_npm => "npm",
        _ => "cargo",
    }
    .to_string();

    if has_npm {
        parse_npm(dir, &mut dependencies, &mut notes);
    }
    if has_cargo {
        parse_cargo(dir, &mut dependencies, &mut notes);
    }

    // Sort by (ecosystem, name) for a stable, readable inventory. Swift re-sorts
    // by actionability after it enriches `status`/`advisories`.
    dependencies.sort_by(|a, b| a.ecosystem.cmp(&b.ecosystem).then(a.name.cmp(&b.name)));

    let summary = StackSummary {
        total: dependencies.len() as u32,
        // All the "behind"/"vulnerable" fields stay 0 and `max_severity` None:
        // Swift fills these after the network enrichment. `checked_updates`
        // stays false — this is a local-only inventory.
        ..StackSummary::default()
    };

    Some(ProjectStack {
        name: project.name.clone(),
        path: project.path.clone(),
        ecosystem,
        package_manager: project.package_manager.clone(),
        summary,
        dependencies,
        notes,
    })
}

// ---------------------------------------------------------------------------
// npm
// ---------------------------------------------------------------------------

#[derive(Deserialize, Default)]
struct PackageJson {
    #[serde(default)]
    dependencies: BTreeMap<String, serde_json::Value>,
    #[serde(default, rename = "devDependencies")]
    dev_dependencies: BTreeMap<String, serde_json::Value>,
}

/// Parse `package.json` dependencies, resolving concrete installed versions from
/// the best available lockfile.
fn parse_npm(dir: &Path, out: &mut Vec<Dependency>, notes: &mut Vec<String>) {
    let pkg = match fs::read_to_string(dir.join("package.json"))
        .ok()
        .and_then(|s| serde_json::from_str::<PackageJson>(&s).ok())
    {
        Some(p) => p,
        None => return,
    };

    let installed = npm_installed_versions(dir);
    let have_lockfile = installed.is_some();
    let installed = installed.unwrap_or_default();

    let push = |name: &str, val: &serde_json::Value, is_dev: bool, out: &mut Vec<Dependency>| {
        let required = val.as_str().map(|s| s.to_string());
        out.push(Dependency {
            name: name.to_string(),
            ecosystem: "npm".to_string(),
            required,
            installed: installed.get(name).cloned(),
            latest: None,
            status: DependencyStatus::Unknown,
            is_dev,
            advisories: Vec::new(),
        });
    };

    for (name, val) in &pkg.dependencies {
        push(name, val, false, out);
    }
    for (name, val) in &pkg.dev_dependencies {
        push(name, val, true, out);
    }

    if !have_lockfile && (!pkg.dependencies.is_empty() || !pkg.dev_dependencies.is_empty()) {
        notes.push("no lockfile — install versions unknown; showing declared ranges".to_string());
    }
}

/// Resolve name → installed version from an npm lockfile. Returns `None` when no
/// lockfile is present (so the caller can note it); `Some(empty)` when a lockfile
/// exists but yielded nothing.
fn npm_installed_versions(dir: &Path) -> Option<BTreeMap<String, String>> {
    // Prefer package-lock.json (structured JSON, exact).
    if let Ok(text) = fs::read_to_string(dir.join("package-lock.json")) {
        return Some(parse_package_lock(&text));
    }
    // Best-effort line scans for the YAML/custom formats.
    if let Ok(text) = fs::read_to_string(dir.join("pnpm-lock.yaml")) {
        return Some(parse_pnpm_lock(&text));
    }
    if let Ok(text) = fs::read_to_string(dir.join("yarn.lock")) {
        return Some(parse_yarn_lock(&text));
    }
    None
}

/// Parse an npm `package-lock.json`. Handles both v7+ (`packages` keyed by
/// `"node_modules/<name>"`) and v6 (`dependencies.<name>.version`).
fn parse_package_lock(text: &str) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    let json: serde_json::Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(_) => return map,
    };

    // npm v7+: top-level "packages" map.
    if let Some(packages) = json.get("packages").and_then(|v| v.as_object()) {
        // Depth (count of `node_modules/` segments) of the entry currently chosen
        // for each name, so a shallower entry can replace a deeper one.
        let mut chosen_depth: BTreeMap<String, usize> = BTreeMap::new();
        for (key, meta) in packages {
            // Keys look like "node_modules/foo" or "node_modules/foo/node_modules/bar".
            // Take the last "node_modules/" segment as the package name so nested
            // deps resolve to their own name. The "" key is the root project.
            let name = match key.rsplit_once("node_modules/") {
                Some((_, n)) if !n.is_empty() => n,
                _ => continue,
            };
            if let Some(version) = meta.get("version").and_then(|v| v.as_str()) {
                // Prefer the top-level (shallowest) entry — the version the project
                // actually resolves. Keying "first seen" was wrong: the `packages`
                // object is a BTreeMap (serde_json has no preserve_order here)
                // iterated lexicographically, so a nested path
                // (`node_modules/a/node_modules/lodash`) can sort BEFORE the
                // top-level (`node_modules/lodash`) and shadow it with a transitive
                // version. Compare depth and keep the shallowest.
                let depth = key.matches("node_modules/").count();
                let replace = chosen_depth.get(name).map_or(true, |&d| depth < d);
                if replace {
                    map.insert(name.to_string(), version.to_string());
                    chosen_depth.insert(name.to_string(), depth);
                }
            }
        }
    }

    // npm v6 (and a fallback): top-level "dependencies" map.
    if let Some(deps) = json.get("dependencies").and_then(|v| v.as_object()) {
        for (name, meta) in deps {
            if let Some(version) = meta.get("version").and_then(|v| v.as_str()) {
                map.entry(name.clone())
                    .or_insert_with(|| version.to_string());
            }
        }
    }

    map
}

/// Best-effort scan of a `pnpm-lock.yaml`. pnpm keys packages under
/// `/name@version` or `name@version(peer…)`; we take the segment before the
/// last `@`. Not exhaustive — a miss just leaves `installed = None`.
fn parse_pnpm_lock(text: &str) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    for raw in text.lines() {
        let line = raw.trim();
        // Package entries are indented map keys ending in ':' under `packages:`
        // or `snapshots:`, e.g. `  /lodash@4.17.21:` or `  react@19.0.0:`.
        if !raw.starts_with(' ') || !line.ends_with(':') {
            continue;
        }
        let key = line
            .trim_end_matches(':')
            .trim_matches('\'')
            .trim_matches('"');
        let key = key.strip_prefix('/').unwrap_or(key);
        // Drop any peer-deps suffix like "(react@19.0.0)".
        let core = key.split('(').next().unwrap_or(key);
        if let Some((name, version)) = split_name_at_version(core) {
            map.entry(name).or_insert(version);
        }
    }
    map
}

/// Best-effort scan of a `yarn.lock` (v1 style). Header lines look like
/// `"lodash@^4.17.0", "lodash@^4.17.21":` and the following indented block has
/// `  version "4.17.21"`. We map every name in the header to that version.
fn parse_yarn_lock(text: &str) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    let mut pending: Vec<String> = Vec::new();
    for raw in text.lines() {
        if raw.starts_with(char::is_whitespace) {
            let line = raw.trim();
            if let Some(rest) = line.strip_prefix("version ") {
                let version = rest.trim().trim_matches('"').to_string();
                if !version.is_empty() {
                    for name in pending.drain(..) {
                        map.entry(name).or_insert_with(|| version.clone());
                    }
                }
            }
            continue;
        }
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        // A header line: comma-separated specifiers, terminated by ':'.
        if let Some(header) = line.strip_suffix(':') {
            pending.clear();
            for spec in header.split(',') {
                let spec = spec.trim().trim_matches('"');
                if let Some(name) = yarn_spec_name(spec) {
                    pending.push(name);
                }
            }
        }
    }
    map
}

/// The package name from a yarn specifier like `lodash@^4.17.0` or
/// `@scope/pkg@^1.0.0` (scoped names keep their leading `@`).
fn yarn_spec_name(spec: &str) -> Option<String> {
    let (scoped, rest) = if let Some(r) = spec.strip_prefix('@') {
        (true, r)
    } else {
        (false, spec)
    };
    let name = rest.split('@').next().unwrap_or("");
    if name.is_empty() {
        return None;
    }
    Some(if scoped {
        format!("@{name}")
    } else {
        name.to_string()
    })
}

/// Split a `name@version` key into (name, version), preserving a scoped leading
/// `@`. Splits on the *last* `@`, so `@scope/pkg@1.2.3` → (`@scope/pkg`, `1.2.3`).
fn split_name_at_version(key: &str) -> Option<(String, String)> {
    let (name, version) = key.rsplit_once('@')?;
    if name.is_empty() || version.is_empty() {
        return None;
    }
    Some((name.to_string(), version.to_string()))
}

// ---------------------------------------------------------------------------
// cargo
// ---------------------------------------------------------------------------

/// Parse `Cargo.toml` `[dependencies]`/`[dev-dependencies]` for declared
/// versions, resolving installed versions from `Cargo.lock`. No TOML parser
/// (the core is dependency-free) — hand-scanned, robust against malformed lines.
fn parse_cargo(dir: &Path, out: &mut Vec<Dependency>, notes: &mut Vec<String>) {
    let toml = match fs::read_to_string(dir.join("Cargo.toml")) {
        Ok(t) => t,
        Err(_) => return,
    };
    let declared = parse_cargo_toml(&toml);
    if declared.is_empty() {
        return;
    }

    let installed = fs::read_to_string(dir.join("Cargo.lock"))
        .ok()
        .map(|t| parse_cargo_lock(&t));
    let have_lock = installed.is_some();
    let installed = installed.unwrap_or_default();

    for (name, required, is_dev) in declared {
        out.push(Dependency {
            installed: installed.get(&name).cloned(),
            name,
            ecosystem: "cargo".to_string(),
            required,
            latest: None,
            status: DependencyStatus::Unknown,
            is_dev,
            advisories: Vec::new(),
        });
    }

    if !have_lock {
        notes.push("no Cargo.lock — install versions unknown; showing declared ranges".to_string());
    }
}

/// Hand-parse a `Cargo.toml`'s top-level `[dependencies]` / `[dev-dependencies]`
/// tables into (name, required, is_dev). Handles `name = "1.2"` and
/// `name = { version = "1.2", … }`. `[dependencies.foo]` sub-tables and
/// workspace/path/git deps without an inline version resolve to `required = None`
/// (best-effort — we still record the dependency). Never panics.
fn parse_cargo_toml(content: &str) -> Vec<(String, Option<String>, bool)> {
    let mut out: Vec<(String, Option<String>, bool)> = Vec::new();
    // Which table are we in? Some(is_dev) inside a deps table, None otherwise.
    let mut current: Option<bool> = None;
    for line in content.lines() {
        let t = line.trim();
        if t.starts_with('[') {
            let inner = t.trim_start_matches('[').trim_end_matches(']').trim();
            current = match inner {
                "dependencies" => Some(false),
                "dev-dependencies" | "dev_dependencies" => Some(true),
                _ => None, // skip build-deps, target.*, [dependencies.foo] sub-tables, etc.
            };
            continue;
        }
        let Some(is_dev) = current else { continue };
        if t.is_empty() || t.starts_with('#') {
            continue;
        }
        let Some(eq) = t.find('=') else { continue };
        let name = t[..eq].trim();
        // A dotted key like `serde.workspace = true` — take the crate name.
        let name = name.split('.').next().unwrap_or(name).trim();
        if name.is_empty() || !is_crate_name(name) {
            continue;
        }
        let value = t[eq + 1..].trim();
        let required = cargo_value_version(value);
        // Skip a duplicate name already captured (e.g. dotted then table form).
        if !out.iter().any(|(n, _, d)| n == name && *d == is_dev) {
            out.push((name.to_string(), required, is_dev));
        }
    }
    out
}

/// Extract the version string from the RHS of a `Cargo.toml` dependency line:
/// `"1.2"` → `Some("1.2")`; `{ version = "1.2", … }` → `Some("1.2")`;
/// anything else (workspace/path/git, bare `true`) → `None`.
fn cargo_value_version(value: &str) -> Option<String> {
    let v = value.trim();
    if let Some(rest) = v.strip_prefix('"') {
        // Simple `name = "1.2"` form.
        if let Some(end) = rest.find('"') {
            let ver = &rest[..end];
            if !ver.is_empty() {
                return Some(ver.to_string());
            }
        }
        return None;
    }
    if v.starts_with('{') {
        // Inline table: find `version = "…"`.
        if let Some(pos) = v.find("version") {
            let after = &v[pos + "version".len()..];
            let after = after.trim_start();
            if let Some(after) = after.strip_prefix('=') {
                let after = after.trim_start();
                if let Some(rest) = after.strip_prefix('"') {
                    if let Some(end) = rest.find('"') {
                        let ver = &rest[..end];
                        if !ver.is_empty() {
                            return Some(ver.to_string());
                        }
                    }
                }
            }
        }
    }
    None
}

/// Hand-parse a `Cargo.lock` into name → version. Entries are simple TOML
/// `[[package]]` blocks with quoted `name = "X"` / `version = "Y"` lines. We scan
/// linearly, pairing the `name` and `version` seen within the current block.
fn parse_cargo_lock(content: &str) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    let mut name: Option<String> = None;
    let mut version: Option<String> = None;
    let mut commit = |name: &mut Option<String>, version: &mut Option<String>| {
        if let (Some(n), Some(v)) = (name.take(), version.take()) {
            map.entry(n).or_insert(v);
        } else {
            *name = None;
            *version = None;
        }
    };
    for line in content.lines() {
        let t = line.trim();
        if t == "[[package]]" {
            // Starting a new package block flushes any complete previous one.
            commit(&mut name, &mut version);
            continue;
        }
        if let Some(v) = lock_quoted_field(t, "name") {
            name = Some(v);
        } else if let Some(v) = lock_quoted_field(t, "version") {
            version = Some(v);
        }
    }
    commit(&mut name, &mut version);
    map
}

/// Read `key = "value"` from a Cargo.lock line, returning the unquoted value.
fn lock_quoted_field(line: &str, key: &str) -> Option<String> {
    let rest = line.strip_prefix(key)?.trim_start();
    let rest = rest.strip_prefix('=')?.trim_start();
    let rest = rest.strip_prefix('"')?;
    let end = rest.find('"')?;
    let val = &rest[..end];
    if val.is_empty() {
        None
    } else {
        Some(val.to_string())
    }
}

/// A plausible crate/dependency identifier (letters, digits, `_`, `-`). Rejects
/// stray syntax so malformed lines are skipped rather than recorded.
fn is_crate_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    /// Create a unique temp project dir (mirrors the house style in
    /// `providers/*` and `tests/*`).
    fn temp_project(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("sp-stackhealth-{}-{tag}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn find<'a>(deps: &'a [Dependency], name: &str) -> &'a Dependency {
        deps.iter()
            .find(|d| d.name == name)
            .unwrap_or_else(|| panic!("dependency {name} not found"))
    }

    #[test]
    fn analyzes_npm_and_cargo_projects() {
        // --- npm project with package.json + package-lock.json (v7 style) ---
        let npm = temp_project("npm");
        std::fs::write(
            npm.join("package.json"),
            r#"{
                "name": "demo",
                "dependencies": { "react": "^19.0.0", "lodash": "4.17.21" },
                "devDependencies": { "typescript": "^5.4.0" }
            }"#,
        )
        .unwrap();
        std::fs::write(
            npm.join("package-lock.json"),
            r#"{
                "name": "demo",
                "lockfileVersion": 3,
                "packages": {
                    "": { "name": "demo" },
                    "node_modules/react": { "version": "19.0.2" },
                    "node_modules/lodash": { "version": "4.17.21" },
                    "node_modules/typescript": { "version": "5.4.5" }
                }
            }"#,
        )
        .unwrap();

        // --- cargo project with Cargo.toml + Cargo.lock ---
        let cargo = temp_project("cargo");
        std::fs::write(
            cargo.join("Cargo.toml"),
            r#"
[package]
name = "demo"
version = "0.1.0"

[dependencies]
serde = { version = "1.0", features = ["derive"] }
tokio = "1.38"

[dev-dependencies]
tempfile = "3"
"#,
        )
        .unwrap();
        std::fs::write(
            cargo.join("Cargo.lock"),
            r#"
version = 3

[[package]]
name = "serde"
version = "1.0.203"

[[package]]
name = "tokio"
version = "1.38.1"

[[package]]
name = "tempfile"
version = "3.10.1"
"#,
        )
        .unwrap();

        let roots = vec![
            npm.to_string_lossy().into_owned(),
            cargo.to_string_lossy().into_owned(),
        ];
        let stacks = analyze(&roots, 4, false);
        assert_eq!(stacks.len(), 2, "one ProjectStack per supported project");

        // npm assertions
        let npm_stack = stacks
            .iter()
            .find(|s| s.ecosystem == "npm")
            .expect("npm stack");
        assert_eq!(npm_stack.summary.total, 3);
        assert!(!npm_stack.summary.checked_updates);
        // sorted by name: lodash, react, typescript
        assert_eq!(
            npm_stack
                .dependencies
                .iter()
                .map(|d| d.name.as_str())
                .collect::<Vec<_>>(),
            vec!["lodash", "react", "typescript"]
        );
        let react = find(&npm_stack.dependencies, "react");
        assert_eq!(react.required.as_deref(), Some("^19.0.0"));
        assert_eq!(react.installed.as_deref(), Some("19.0.2"));
        assert_eq!(react.latest, None);
        assert_eq!(react.status, DependencyStatus::Unknown);
        assert!(!react.is_dev);
        assert!(react.advisories.is_empty());
        let ts = find(&npm_stack.dependencies, "typescript");
        assert!(ts.is_dev, "typescript is a devDependency");
        assert_eq!(ts.installed.as_deref(), Some("5.4.5"));

        // cargo assertions
        let cargo_stack = stacks
            .iter()
            .find(|s| s.ecosystem == "cargo")
            .expect("cargo stack");
        assert_eq!(cargo_stack.summary.total, 3);
        let serde = find(&cargo_stack.dependencies, "serde");
        assert_eq!(serde.required.as_deref(), Some("1.0"));
        assert_eq!(serde.installed.as_deref(), Some("1.0.203"));
        assert_eq!(serde.status, DependencyStatus::Unknown);
        assert!(!serde.is_dev);
        let tokio = find(&cargo_stack.dependencies, "tokio");
        assert_eq!(tokio.required.as_deref(), Some("1.38"));
        assert_eq!(tokio.installed.as_deref(), Some("1.38.1"));
        let tempfile = find(&cargo_stack.dependencies, "tempfile");
        assert!(tempfile.is_dev, "tempfile is a dev-dependency");
        assert_eq!(tempfile.installed.as_deref(), Some("3.10.1"));

        std::fs::remove_dir_all(&npm).ok();
        std::fs::remove_dir_all(&cargo).ok();
    }

    #[test]
    fn npm_without_lockfile_notes_and_leaves_installed_none() {
        let dir = temp_project("npm-nolock");
        std::fs::write(
            dir.join("package.json"),
            r#"{ "dependencies": { "react": "^19.0.0" } }"#,
        )
        .unwrap();

        let roots = vec![dir.to_string_lossy().into_owned()];
        let stacks = analyze(&roots, 4, false);
        assert_eq!(stacks.len(), 1);
        let s = &stacks[0];
        assert_eq!(s.dependencies.len(), 1);
        assert_eq!(s.dependencies[0].installed, None);
        assert!(s.notes.iter().any(|n| n.contains("no lockfile")));

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn parse_package_lock_handles_v6_and_v7() {
        let v7 = r#"{ "packages": { "node_modules/a": { "version": "1.0.0" } } }"#;
        let m = parse_package_lock(v7);
        assert_eq!(m.get("a").map(String::as_str), Some("1.0.0"));

        let v6 = r#"{ "dependencies": { "b": { "version": "2.0.0" } } }"#;
        let m = parse_package_lock(v6);
        assert_eq!(m.get("b").map(String::as_str), Some("2.0.0"));
    }

    /// A transitive (nested) copy of a package must NOT shadow the top-level
    /// resolved version, even when its BTreeMap key sorts first. Here
    /// `node_modules/left-pad/node_modules/lodash` (3.10.1) sorts before
    /// `node_modules/lodash` (4.17.21) lexicographically; the shallowest wins.
    #[test]
    fn nested_dep_does_not_shadow_top_level_version() {
        let v7 = r#"{ "packages": {
            "node_modules/left-pad": { "version": "1.3.0" },
            "node_modules/left-pad/node_modules/lodash": { "version": "3.10.1" },
            "node_modules/lodash": { "version": "4.17.21" }
        } }"#;
        let m = parse_package_lock(v7);
        assert_eq!(
            m.get("lodash").map(String::as_str),
            Some("4.17.21"),
            "top-level version must win over the nested one"
        );
        assert_eq!(m.get("left-pad").map(String::as_str), Some("1.3.0"));
    }

    #[test]
    fn yarn_and_pnpm_line_scans_resolve_versions() {
        // NB: real fixtures keep leading indentation, so use raw strings (a `\`
        // line-continuation would strip the indent the parsers depend on).
        let yarn = "lodash@^4.17.0, lodash@^4.17.21:\n  version \"4.17.21\"\n\n\"@scope/pkg@^1.0.0\":\n  version \"1.2.3\"\n";
        let m = parse_yarn_lock(yarn);
        assert_eq!(m.get("lodash").map(String::as_str), Some("4.17.21"));
        assert_eq!(m.get("@scope/pkg").map(String::as_str), Some("1.2.3"));

        let pnpm = "packages:\n  /lodash@4.17.21:\n    resolution: {integrity: sha512-x}\n  react@19.0.0(foo@1.0.0):\n    resolution: {integrity: sha512-y}\n";
        let m = parse_pnpm_lock(pnpm);
        assert_eq!(m.get("lodash").map(String::as_str), Some("4.17.21"));
        assert_eq!(m.get("react").map(String::as_str), Some("19.0.0"));
    }

    #[test]
    fn cargo_value_version_extracts_string_and_table() {
        assert_eq!(cargo_value_version("\"1.2\""), Some("1.2".to_string()));
        assert_eq!(
            cargo_value_version("{ version = \"1.2\", features = [\"x\"] }"),
            Some("1.2".to_string())
        );
        assert_eq!(cargo_value_version("{ workspace = true }"), None);
        assert_eq!(cargo_value_version("true"), None);
    }

    #[test]
    fn non_supported_project_is_skipped() {
        let dir = temp_project("empty");
        std::fs::write(dir.join("README.md"), "# nothing here").unwrap();
        // No package.json / Cargo.toml → not a supported manifest (and likely not
        // even a discovered project). analyze must not include it.
        let roots = vec![dir.to_string_lossy().into_owned()];
        let stacks = analyze(&roots, 4, false);
        assert!(stacks.iter().all(|s| s.path != dir.to_string_lossy()));
        std::fs::remove_dir_all(&dir).ok();
    }
}
