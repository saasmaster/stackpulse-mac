//! Fixture tests for the Project Navigator & Command Memory discovery engine.
//!
//! Each test builds a self-contained temp-dir tree under a fixed root, runs
//! [`stackpulse_core::projects::discover`] against it, and asserts on the
//! resulting [`Project`]s. Nothing here reads the host's real filesystem: the
//! root is a fresh unique temp directory and every marker/command file is
//! materialized by the test, so results are deterministic on any machine.

use std::path::{Path, PathBuf};

use stackpulse_core::projects::discover;
use stackpulse_protocol::{CommandSafety, CommandSource, DiscoveredCommand, Project};

/// A unique temp directory for one test run (no cross-test collisions).
fn unique_root(tag: &str) -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("sp-projects-{}-{tag}-{n}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn write(path: &Path, contents: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, contents).unwrap();
}

fn find<'a>(projects: &'a [Project], name: &str) -> &'a Project {
    projects
        .iter()
        .find(|p| p.name == name)
        .unwrap_or_else(|| panic!("missing project {name:?}; found {:?}", names(projects)))
}

fn names(projects: &[Project]) -> Vec<&str> {
    projects.iter().map(|p| p.name.as_str()).collect()
}

fn command<'a>(project: &'a Project, label: &str) -> &'a DiscoveredCommand {
    project
        .commands
        .iter()
        .find(|c| c.label == label)
        .unwrap_or_else(|| {
            panic!(
                "missing {label:?} command in {:?}; found {:?}",
                project.name,
                project
                    .commands
                    .iter()
                    .map(|c| (&c.label, &c.command))
                    .collect::<Vec<_>>()
            )
        })
}

/// One root holding four distinct project fixtures; discovered in a single pass.
fn build_fixture_root() -> PathBuf {
    let root = unique_root("multi");

    // 1) Node project: pnpm lockfile + scripts.
    write(
        &root.join("node-app").join("package.json"),
        r#"{
  "name": "node-app",
  "scripts": {
    "test": "vitest run",
    "build": "vite build",
    "dev": "vite",
    "lint": "eslint ."
  },
  "dependencies": { "next": "15.0.0", "react": "19.0.0" },
  "devDependencies": { "tailwindcss": "4.0.0", "typescript": "5.5.0" }
}"#,
    );
    write(
        &root.join("node-app").join("pnpm-lock.yaml"),
        "lockfileVersion: '9.0'\n",
    );

    // 2) Rust project: Cargo.toml only (framework conventions).
    write(
        &root.join("rust-app").join("Cargo.toml"),
        "[package]\nname = \"rust-app\"\nversion = \"0.1.0\"\n\n[dependencies]\ntokio = { version = \"1\", features = [\"full\"] }\n",
    );

    // 3) Makefile project (also a Cargo crate so it is a project root).
    write(
        &root.join("make-app").join("Cargo.toml"),
        "[package]\nname = \"make-app\"\nversion = \"0.1.0\"\n",
    );
    write(
        &root.join("make-app").join("Makefile"),
        ".PHONY: build test clean\nbuild:\n\tcargo build\ntest:\n\tcargo test\nclean:\n\trm -rf target\n",
    );

    // 4) Git repo without an origin remote.
    write(
        &root.join("git-repo").join(".git").join("HEAD"),
        "ref: refs/heads/main\n",
    );
    write(
        &root.join("git-repo").join(".git").join("config"),
        "[core]\n\trepositoryformatversion = 0\n\tbare = false\n",
    );

    root
}

#[test]
fn discovers_all_four_projects() {
    let root = build_fixture_root();
    let projects = discover(&[root.to_string_lossy().into_owned()], 3);

    let mut found = names(&projects);
    found.sort_unstable();
    assert_eq!(found, vec!["git-repo", "make-app", "node-app", "rust-app"]);

    std::fs::remove_dir_all(&root).ok();
}

#[test]
fn node_project_scripts_and_pm() {
    let root = build_fixture_root();
    let projects = discover(&[root.to_string_lossy().into_owned()], 3);
    let node = find(&projects, "node-app");

    assert!(
        node.markers.contains(&"node".to_string()),
        "markers: {:?}",
        node.markers
    );
    assert_eq!(node.package_manager.as_deref(), Some("pnpm"));
    // Frameworks parsed from package.json.
    assert!(node.frameworks.contains(&"next".to_string()));
    assert!(node.frameworks.contains(&"tailwind".to_string()));

    // Normalized labels, safety, and pnpm invocation.
    let test = command(node, "Test");
    assert_eq!(test.command, "pnpm test");
    assert_eq!(test.safety, CommandSafety::ReadOnly);
    assert_eq!(test.source, CommandSource::PackageScript);
    assert!(test.confidence > 0.8);

    assert_eq!(command(node, "Build").command, "pnpm build");
    assert_eq!(command(node, "Build").safety, CommandSafety::LocalDev);
    assert_eq!(command(node, "Dev").command, "pnpm dev");
    assert_eq!(command(node, "Dev").safety, CommandSafety::LocalDev);
    assert_eq!(command(node, "Lint").command, "pnpm lint");
    assert_eq!(command(node, "Lint").safety, CommandSafety::ReadOnly);

    // Every discovered command uses pnpm, and Test is surfaced first.
    assert!(node.commands.iter().all(|c| c.command.starts_with("pnpm ")));
    assert_eq!(
        node.commands.first().map(|c| c.label.as_str()),
        Some("Test")
    );

    std::fs::remove_dir_all(&root).ok();
}

#[test]
fn rust_project_framework_conventions() {
    let root = build_fixture_root();
    let projects = discover(&[root.to_string_lossy().into_owned()], 3);
    let rust = find(&projects, "rust-app");

    assert!(rust.markers.contains(&"rust".to_string()));
    assert_eq!(rust.package_manager.as_deref(), Some("cargo"));
    assert!(rust.frameworks.contains(&"tokio".to_string()));

    let test = command(rust, "Test");
    assert_eq!(test.command, "cargo test");
    assert_eq!(test.source, CommandSource::FrameworkConvention);
    assert_eq!(test.safety, CommandSafety::ReadOnly);
    assert!(test.confidence < 0.8, "conventions are lower-confidence");

    let build = command(rust, "Build");
    assert_eq!(build.command, "cargo build");
    assert_eq!(build.safety, CommandSafety::LocalDev);

    // `cargo run` is present as a Run command.
    assert!(rust.commands.iter().any(|c| c.command == "cargo run"));

    std::fs::remove_dir_all(&root).ok();
}

#[test]
fn makefile_targets_are_discovered() {
    let root = build_fixture_root();
    let projects = discover(&[root.to_string_lossy().into_owned()], 3);
    let make = find(&projects, "make-app");

    let mk: Vec<&DiscoveredCommand> = make
        .commands
        .iter()
        .filter(|c| c.source == CommandSource::Makefile)
        .collect();
    let mk_cmds: Vec<&str> = mk.iter().map(|c| c.command.as_str()).collect();
    assert!(mk_cmds.contains(&"make build"), "make cmds: {mk_cmds:?}");
    assert!(mk_cmds.contains(&"make test"), "make cmds: {mk_cmds:?}");
    assert!(mk_cmds.contains(&"make clean"), "make cmds: {mk_cmds:?}");

    // `make clean` runs `rm -rf` → Destructive.
    let clean = command(make, "Clean");
    assert_eq!(clean.source, CommandSource::Makefile);
    assert_eq!(clean.safety, CommandSafety::Destructive);

    // The explicit `make test` target covers Test, so no `cargo test`
    // convention is added, but the uncovered `cargo run` still is.
    assert_eq!(command(make, "Test").command, "make test");
    assert!(make.commands.iter().any(|c| c.command == "cargo run"));

    std::fs::remove_dir_all(&root).ok();
}

#[test]
fn git_repo_without_origin_is_flagged() {
    let root = build_fixture_root();
    let projects = discover(&[root.to_string_lossy().into_owned()], 3);
    let git = find(&projects, "git-repo");

    assert!(git.markers.contains(&"git".to_string()));
    assert_eq!(git.git_branch.as_deref(), Some("main"));
    assert_eq!(git.git_remote, None);
    assert!(
        git.warnings.contains(&"No git remote".to_string()),
        "warnings: {:?}",
        git.warnings
    );

    std::fs::remove_dir_all(&root).ok();
}

#[test]
fn does_not_follow_into_ignored_directories() {
    // A nested package.json buried in node_modules must not become a project.
    let root = unique_root("ignore");
    write(&root.join("app").join("package.json"), r#"{"name":"app"}"#);
    write(
        &root
            .join("app")
            .join("node_modules")
            .join("dep")
            .join("package.json"),
        r#"{"name":"dep"}"#,
    );

    let projects = discover(&[root.to_string_lossy().into_owned()], 5);
    assert_eq!(
        names(&projects),
        vec!["app"],
        "only the top-level app is a project"
    );

    std::fs::remove_dir_all(&root).ok();
}
