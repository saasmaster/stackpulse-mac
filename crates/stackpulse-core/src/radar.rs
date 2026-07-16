//! Repository Radar — project-aware, explainable recommendations.
//!
//! Discovers projects under the approved roots (via [`crate::projects`]) and runs
//! a set of deterministic rules over concrete local facts (which files exist, git
//! state, discovered commands, detected frameworks). Every recommendation is
//! grounded in specific projects with specific evidence — the spec's exit
//! criterion is that this is *not* a generic, noisy popularity feed.
//!
//! Portable + offline (ADR-0005): filesystem reads and local `git` only, never
//! the network, never executes project code, never follows symlinks out of a
//! project. Rules aggregate across projects into one card each (with the list of
//! affected projects) rather than emitting one card per project, to keep signal
//! high and noise low.

use crate::datetime::now_unix;
use stackpulse_protocol::{
    Project, RadarCategory, RadarEffort, RadarReport, RadarRisk, Recommendation,
};
use std::path::Path;

/// A project is "stale" once untouched for this many seconds (~14 days). Used to
/// separate forgotten uncommitted work from work-in-progress.
const STALE_SECS: i64 = 14 * 24 * 60 * 60;

/// Agent-instruction filenames that make a project self-describing to AI tools.
const AGENT_DOC_FILES: &[&str] = &[
    "CLAUDE.md",
    "AGENTS.md",
    "GEMINI.md",
    ".cursorrules",
    ".github/copilot-instructions.md",
];

/// Generated/dependency directories that should never be committed or fed to a
/// model's context, checked against each project's `.gitignore`.
const GENERATED_DIRS: &[&str] = &["node_modules", "dist", "build", ".next", "target", ".venv"];

/// Run the radar over `roots`, returning an ordered report (highest priority
/// first). Never panics; unreadable projects simply contribute no findings.
pub fn analyze(roots: &[String], max_depth: u32) -> RadarReport {
    let projects = crate::projects::discover(roots, max_depth);
    let mut recs: Vec<Recommendation> = Vec::new();

    recs.extend(rule_missing_agent_docs(&projects));
    recs.extend(rule_generated_not_ignored(&projects));
    recs.extend(rule_no_test_command(&projects));
    recs.extend(rule_env_setup_gap(&projects));
    recs.extend(rule_stale_uncommitted(&projects));
    recs.extend(rule_no_git_remote(&projects));
    recs.extend(rule_typescript_no_typecheck(&projects));

    // Highest priority first, then by breadth (more affected projects), stable id.
    recs.sort_by(|a, b| {
        b.priority
            .cmp(&a.priority)
            .then(b.affected_projects.len().cmp(&a.affected_projects.len()))
            .then(a.id.cmp(&b.id))
    });

    RadarReport {
        generated_at_unix: now_unix(),
        projects_scanned: projects.len(),
        recommendations: recs,
    }
}

// ---------------------------------------------------------------------------
// Rules
// ---------------------------------------------------------------------------

/// Projects with real work (git repo or discovered commands) but no agent
/// instructions file → agents re-discover the layout every session.
fn rule_missing_agent_docs(projects: &[Project]) -> Option<Recommendation> {
    let affected: Vec<&Project> = projects
        .iter()
        .filter(|p| is_substantial(p) && !has_any_file(&p.path, AGENT_DOC_FILES))
        .collect();
    if affected.is_empty() {
        return None;
    }
    let names = names(&affected);
    Some(Recommendation {
        id: "ai_context:missing_agent_docs".into(),
        category: RadarCategory::AiContext,
        title: format!(
            "Add project instructions to {} project{}",
            names.len(),
            plural(names.len())
        ),
        detail: "These projects have no CLAUDE.md / AGENTS.md, so coding agents \
            rediscover the structure, stack, and conventions on every session — \
            burning context and time. A short, concise instructions file pays for \
            itself quickly."
            .into(),
        evidence: vec![format!(
            "{} of {} scanned projects have no agent-instructions file",
            names.len(),
            projects.len()
        )],
        affected_projects: names,
        effort: RadarEffort::Small,
        risk: RadarRisk::None,
        recommend_change: true,
        priority: 74,
    })
}

/// Git projects whose generated/dependency folders exist on disk but aren't in
/// `.gitignore` (or there is no `.gitignore`).
fn rule_generated_not_ignored(projects: &[Project]) -> Option<Recommendation> {
    let mut affected_names = Vec::new();
    let mut evidence = Vec::new();
    for p in projects.iter().filter(|p| is_git(p)) {
        let leaked: Vec<&str> = GENERATED_DIRS
            .iter()
            .copied()
            .filter(|d| dir_exists(&p.path, d) && !git_ignores(&p.path, d))
            .collect();
        if !leaked.is_empty() {
            affected_names.push(p.name.clone());
            evidence.push(format!("{}: {}", p.name, leaked.join(", ")));
        }
    }
    if affected_names.is_empty() {
        return None;
    }
    Some(Recommendation {
        id: "hygiene:generated_not_ignored".into(),
        category: RadarCategory::Hygiene,
        title: format!(
            "Ignore generated folders in {} project{}",
            affected_names.len(),
            plural(affected_names.len())
        ),
        detail: "Build/dependency folders are present but not covered by \
            .gitignore. Keeping them out of version control and out of an agent's \
            context avoids accidental commits and large, low-value file reads."
            .into(),
        evidence,
        affected_projects: affected_names,
        effort: RadarEffort::Trivial,
        risk: RadarRisk::None,
        recommend_change: true,
        priority: 66,
    })
}

/// Projects with discovered commands but none that runs tests, where the stack is
/// testable (has a package manager) → agents can't verify their own changes.
fn rule_no_test_command(projects: &[Project]) -> Option<Recommendation> {
    let affected: Vec<&Project> = projects
        .iter()
        .filter(|p| {
            p.package_manager.is_some()
                && !p.commands.is_empty()
                && !p.commands.iter().any(|c| {
                    let hay = format!("{} {}", c.label, c.command).to_lowercase();
                    hay.contains("test") || hay.contains("vitest") || hay.contains("pytest")
                })
        })
        .collect();
    if affected.is_empty() {
        return None;
    }
    let names = names(&affected);
    Some(Recommendation {
        id: "testing:no_test_command".into(),
        category: RadarCategory::Testing,
        title: format!(
            "No test command in {} project{}",
            names.len(),
            plural(names.len())
        ),
        detail: "No runnable test command was discovered, so there's no automatic \
            way to verify changes before shipping. Adding even a smoke test gives \
            agents (and you) a safety net."
            .into(),
        evidence: vec![format!(
            "{} project{} with commands but no test script",
            names.len(),
            plural(names.len())
        )],
        affected_projects: names,
        effort: RadarEffort::Small,
        risk: RadarRisk::None,
        recommend_change: true,
        priority: 58,
    })
}

/// Projects that ship an env template (`.env.example`) but have no local `.env`
/// → likely an incomplete setup.
fn rule_env_setup_gap(projects: &[Project]) -> Option<Recommendation> {
    let affected: Vec<&Project> = projects
        .iter()
        .filter(|p| {
            has_any_file(&p.path, &[".env.example", ".env.sample", ".env.template"])
                && !has_any_file(&p.path, &[".env", ".env.local"])
        })
        .collect();
    if affected.is_empty() {
        return None;
    }
    let names = names(&affected);
    Some(Recommendation {
        id: "setup:env_missing".into(),
        category: RadarCategory::Setup,
        title: format!(
            "Missing .env in {} project{}",
            names.len(),
            plural(names.len())
        ),
        detail: "An env template is present but no local .env — the app likely \
            won't run until it's filled in. Copy the template and set the values."
            .into(),
        evidence: vec![format!(
            "{} project{} have .env.example but no .env",
            names.len(),
            plural(names.len())
        )],
        affected_projects: names,
        effort: RadarEffort::Trivial,
        risk: RadarRisk::None,
        recommend_change: true,
        priority: 52,
    })
}

/// Projects that are stale (untouched for a while) yet still have uncommitted
/// changes → forgotten work at risk of being lost.
fn rule_stale_uncommitted(projects: &[Project]) -> Option<Recommendation> {
    let now = now_unix();
    let mut names = Vec::new();
    let mut evidence = Vec::new();
    for p in projects.iter().filter(|p| is_git(p)) {
        let stale = p
            .last_modified_unix
            .map(|m| now - m > STALE_SECS)
            .unwrap_or(false);
        if stale && git_is_dirty(&p.path) {
            names.push(p.name.clone());
            if let Some(days) = p.last_modified_unix.map(|m| (now - m) / 86_400) {
                evidence.push(format!(
                    "{}: uncommitted, last touched ~{} days ago",
                    p.name, days
                ));
            }
        }
    }
    if names.is_empty() {
        return None;
    }
    Some(Recommendation {
        id: "git:stale_uncommitted".into(),
        category: RadarCategory::Git,
        title: format!(
            "Uncommitted work sitting in {} idle project{}",
            names.len(),
            plural(names.len())
        ),
        detail: "These projects haven't been touched in a while but still have \
            uncommitted changes — easy to lose or forget. Commit or stash them so \
            the work is safe."
            .into(),
        evidence,
        affected_projects: names,
        effort: RadarEffort::Trivial,
        risk: RadarRisk::None,
        recommend_change: true,
        priority: 60,
    })
}

/// Git projects with no configured remote → not backed up anywhere off-machine.
fn rule_no_git_remote(projects: &[Project]) -> Option<Recommendation> {
    let affected: Vec<&Project> = projects
        .iter()
        .filter(|p| is_git(p) && p.git_remote.as_deref().unwrap_or("").is_empty())
        .collect();
    if affected.is_empty() {
        return None;
    }
    let names = names(&affected);
    Some(Recommendation {
        id: "git:no_remote".into(),
        category: RadarCategory::Git,
        title: format!(
            "{} project{} not backed up to a remote",
            names.len(),
            plural(names.len())
        ),
        detail: "These git repositories have no remote configured, so they exist \
            only on this Mac. If the work matters, add a remote (private is fine) \
            so a disk failure can't erase it."
            .into(),
        evidence: vec![format!(
            "{} local-only git repositor{}",
            names.len(),
            if names.len() == 1 { "y" } else { "ies" }
        )],
        affected_projects: names,
        effort: RadarEffort::Small,
        // Pushing is the user's call (could expose private code), so low, not none.
        risk: RadarRisk::Low,
        recommend_change: true,
        priority: 46,
    })
}

/// TypeScript projects with no discovered typecheck command → type errors only
/// surface at build/runtime, not on demand.
fn rule_typescript_no_typecheck(projects: &[Project]) -> Option<Recommendation> {
    let affected: Vec<&Project> = projects
        .iter()
        .filter(|p| {
            has_framework(p, "typescript")
                && !p.commands.iter().any(|c| {
                    let hay = format!("{} {}", c.label, c.command).to_lowercase();
                    hay.contains("typecheck")
                        || hay.contains("type-check")
                        || hay.contains("tsc --noemit")
                        || hay.contains("tsc --noEmit")
                })
        })
        .collect();
    if affected.is_empty() {
        return None;
    }
    let names = names(&affected);
    Some(Recommendation {
        id: "tooling:ts_no_typecheck".into(),
        category: RadarCategory::Tooling,
        title: format!(
            "Add a typecheck script to {} TypeScript project{}",
            names.len(),
            plural(names.len())
        ),
        detail: "These TypeScript projects have no on-demand typecheck command \
            (e.g. `tsc --noEmit`). A dedicated script lets agents catch type \
            errors before build — faster feedback than waiting for a full build."
            .into(),
        evidence: vec![format!(
            "{} TypeScript project{} without a typecheck script",
            names.len(),
            plural(names.len())
        )],
        affected_projects: names,
        effort: RadarEffort::Small,
        risk: RadarRisk::None,
        recommend_change: true,
        priority: 44,
    })
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A project worth nudging about: a git repo or one with discovered commands.
fn is_substantial(p: &Project) -> bool {
    is_git(p) || !p.commands.is_empty()
}

fn is_git(p: &Project) -> bool {
    p.markers.iter().any(|m| m == "git") || p.git_branch.is_some()
}

fn has_framework(p: &Project, name: &str) -> bool {
    p.frameworks.iter().any(|f| f == name)
}

fn names(projects: &[&Project]) -> Vec<String> {
    projects.iter().map(|p| p.name.clone()).collect()
}

fn plural(n: usize) -> &'static str {
    if n == 1 {
        ""
    } else {
        "s"
    }
}

/// Whether any of `files` exists directly under `root` (relative paths allowed).
fn has_any_file(root: &str, files: &[&str]) -> bool {
    files.iter().any(|f| Path::new(root).join(f).exists())
}

fn dir_exists(root: &str, name: &str) -> bool {
    Path::new(root).join(name).is_dir()
}

/// Whether a `.gitignore` body plausibly covers `dir` (bare name, `dir/`, or
/// `/dir` — a conservative substring/line match, not a full gitignore parser).
/// Whether git itself ignores `dir` inside `project_path`.
///
/// We used to read `.gitignore` and compare each line to the directory name. That
/// only recognised bare `node_modules` / `/target/` forms and missed the mainstream
/// glob spellings — `**/node_modules`, `dist/**` — so the radar told people with a
/// perfectly configured repo that their build folders "aren't covered by
/// .gitignore". Reimplementing gitignore semantics (globs, negation, precedence,
/// nested and global ignore files) is a losing game, so ask the authority.
///
/// `check-ignore` exits 0 when the path IS ignored, 1 when it isn't. Any other
/// failure (no git, not a repo) returns `false`, which at worst re-raises a
/// recommendation rather than inventing one.
///
/// The trailing slash matters. Asked about bare `dist`, git answers "not ignored"
/// for the very common `dist/**` pattern — that pattern covers the folder's
/// *contents*, not the name. But git tracks files, not directories, so `dist/**`
/// does keep the whole folder out of the repo, and flagging it would be wrong.
/// Asking about `dist/` is the real question ("is this directory kept out?") and
/// is answered correctly for `dist`, `/dist`, `dist/`, and `dist/**` alike.
fn git_ignores(project_path: &str, dir: &str) -> bool {
    std::process::Command::new("git")
        .arg("-C")
        .arg(project_path)
        .args(["check-ignore", "-q", "--"])
        .arg(format!("{dir}/"))
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Whether the working tree at `path` has uncommitted changes. Local `git` only;
/// any error (missing git, not a repo) reads as "not dirty".
fn git_is_dirty(path: &str) -> bool {
    std::process::Command::new("git")
        .arg("-C")
        .arg(path)
        .arg("status")
        .arg("--porcelain")
        .output()
        .map(|o| o.status.success() && !o.stdout.is_empty())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use stackpulse_protocol::DiscoveredCommand;

    fn project(name: &str) -> Project {
        Project {
            name: name.into(),
            path: "/nonexistent/does/not/exist".into(),
            markers: vec!["git".into()],
            frameworks: vec![],
            package_manager: None,
            git_branch: Some("main".into()),
            git_remote: Some("git@example.com:x.git".into()),
            last_modified_unix: Some(now_unix()),
            commands: vec![],
            warnings: vec![],
        }
    }

    fn cmd(label: &str, command: &str) -> DiscoveredCommand {
        DiscoveredCommand {
            label: label.into(),
            command: command.into(),
            cwd: "/x".into(),
            source: stackpulse_protocol::CommandSource::PackageScript,
            safety: stackpulse_protocol::CommandSafety::ReadOnly,
            confidence: 0.9,
            raw_key: None,
        }
    }

    #[test]
    fn missing_agent_docs_flags_git_projects() {
        // Path doesn't exist → no agent docs → flagged (project is a git repo).
        let recs = rule_missing_agent_docs(&[project("alpha")]);
        assert!(recs.is_some());
        let r = recs.unwrap();
        assert_eq!(r.category, RadarCategory::AiContext);
        assert_eq!(r.affected_projects, vec!["alpha".to_string()]);
        assert!(r.recommend_change);
    }

    #[test]
    fn no_remote_flagged_when_remote_empty() {
        let mut p = project("beta");
        p.git_remote = None;
        assert!(rule_no_git_remote(&[p]).is_some());
    }

    #[test]
    fn no_remote_not_flagged_when_present() {
        assert!(rule_no_git_remote(&[project("gamma")]).is_none());
    }

    #[test]
    fn ts_without_typecheck_is_flagged() {
        let mut p = project("delta");
        p.frameworks = vec!["typescript".into()];
        p.commands = vec![cmd("Build", "npm run build")];
        assert!(rule_typescript_no_typecheck(&[p]).is_some());
    }

    #[test]
    fn ts_with_typecheck_is_not_flagged() {
        let mut p = project("epsilon");
        p.frameworks = vec!["typescript".into()];
        p.commands = vec![cmd("Typecheck", "tsc --noEmit")];
        assert!(rule_typescript_no_typecheck(&[p]).is_none());
    }

    #[test]
    fn no_test_command_flagged_only_with_pm() {
        let mut p = project("zeta");
        p.package_manager = Some("npm".into());
        p.commands = vec![cmd("Build", "npm run build")];
        assert!(rule_no_test_command(&[p]).is_some());

        let mut has_test = project("eta");
        has_test.package_manager = Some("npm".into());
        has_test.commands = vec![cmd("Test", "npm test")];
        assert!(rule_no_test_command(&[has_test]).is_none());
    }

    #[test]
    fn git_ignores_understands_glob_forms_a_line_match_missed() {
        // A real repo, because the whole point is that git decides, not us.
        let dir = std::env::temp_dir().join(format!("sp-radar-gi-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("node_modules")).unwrap();
        std::fs::create_dir_all(dir.join("build")).unwrap();
        let run = |args: &[&str]| {
            std::process::Command::new("git")
                .arg("-C")
                .arg(&dir)
                .args(args)
                .output()
                .expect("git");
        };
        run(&["init", "-q", "."]);
        // Both glob spellings the old line-comparison could not see. `dist/**`
        // ignores the folder's contents rather than its name — git tracks files,
        // not directories, so it genuinely keeps `dist` out of the repo.
        std::fs::create_dir_all(dir.join("dist")).unwrap();
        std::fs::write(dir.join(".gitignore"), "**/node_modules\ndist/**\n").unwrap();

        let p = dir.to_string_lossy().to_string();
        assert!(
            git_ignores(&p, "node_modules"),
            "`**/node_modules` is ignored by git; claiming otherwise is a false report"
        );
        assert!(
            git_ignores(&p, "dist"),
            "`dist/**` keeps the whole folder out of the repo; flagging it is a false report"
        );
        assert!(!git_ignores(&p, "build"), "build is genuinely not ignored");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn analyze_is_ordered_and_never_panics() {
        // Empty roots → zero projects, empty report, no panic.
        let report = analyze(&[], 2);
        assert_eq!(report.projects_scanned, 0);
        assert!(report.recommendations.is_empty());
    }
}
