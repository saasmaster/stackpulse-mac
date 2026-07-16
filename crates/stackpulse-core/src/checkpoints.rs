//! Checkpoints — non-destructive snapshots of a project's uncommitted work.
//!
//! The point of a checkpoint is to make "let an agent loose on my repo" a
//! reversible decision, *without* the safety net itself being risky. So the
//! capture path is *additive only*:
//!
//! 1. `git stash create` writes a commit object recording the working tree and
//!    index **without touching the working tree, the index, or HEAD**. Unlike
//!    `git stash push`, it rolls nothing back — the user's in-progress work is
//!    never disturbed, so this is safe to run while an agent is mid-edit.
//! 2. `git update-ref refs/stackpulse/checkpoints/<name>` keeps that object
//!    reachable, so git can't garbage-collect it and so it stays listable.
//!
//! Nothing in this module ever runs `git stash push`/`save`/`pop`/`apply`,
//! `checkout`, `reset`, or `clean`. Restoring is the one genuinely mutating
//! step, so the core refuses to own it: it only *reports*
//! [`Checkpoint::restore_command`], and the client runs it behind an explicit
//! confirmation.
//!
//! Honesty over convenience: `git stash create` captures **tracked** work only,
//! and prints nothing at all when there's nothing to capture. Both "the tree is
//! clean" and "everything dirty is untracked" look identical at that layer, so
//! we disambiguate against `git status` and say which one actually happened
//! rather than inventing an empty checkpoint that would restore nothing.
//!
//! Portable + offline (ADR-0005): local `git` only, never the network. Any git
//! failure degrades to a note plus whatever we could still read — never a panic,
//! never a false success.

use crate::datetime::civil_from_days;
use stackpulse_protocol::Checkpoint;

/// Ref namespace that keeps snapshot objects alive. Outside `refs/heads` and
/// `refs/tags` on purpose: checkpoints never show up as branches or tags, so
/// they can't be confused for the user's own work.
const REF_PREFIX: &str = "refs/stackpulse/checkpoints";

/// Upper bound on files reported per checkpoint (keeps the payload small),
/// mirroring `missions::GIT_CHANGED_FILES_CAP`.
const CHECKPOINT_FILES_CAP: usize = 20;

/// How many suffixed ref names to try before giving up on finding a free one.
/// Only reachable if distinct snapshots share a short-SHA in the same second.
const REF_NAME_ATTEMPTS: usize = 100;

/// Seconds in a day, for turning a Unix timestamp into a human label.
const SECS_PER_DAY: i64 = 86_400;

/// Capture a checkpoint of `project_path`'s uncommitted work and return the
/// refreshed list (newest first) plus an honest note when nothing was captured.
///
/// Non-destructive by construction: this only ever creates a git object and a
/// ref. The working tree, the index, and HEAD are left exactly as they were —
/// safe to call while an agent is actively editing.
///
/// Returns `(vec![], Some(note))` when `project_path` isn't a git repository,
/// and `(existing_list, Some(note))` when there was genuinely nothing to
/// capture. A clean tree is **not** an error, and never fabricates a checkpoint.
pub fn create(
    project_path: &str,
    label: Option<&str>,
    now_unix: i64,
) -> (Vec<Checkpoint>, Option<String>) {
    if !is_git_repo(project_path) {
        return (
            Vec::new(),
            Some(format!(
                "{project_path} isn't a git repository, so there's nothing to checkpoint — \
                 StackPulse checkpoints are git snapshots."
            )),
        );
    }

    // A stash object is a commit whose first parent is HEAD, so an unborn HEAD
    // has no base to snapshot against. Say so precisely instead of reporting the
    // resulting git failure as "clean".
    if !has_head(project_path) {
        return (
            Vec::new(),
            Some(
                "This repository has no commits yet, so there's no base commit to snapshot \
                 against. Make an initial commit first."
                    .to_string(),
            ),
        );
    }

    let label = resolve_label(label, now_unix);

    let sha = match stash_create(project_path, &label) {
        Some(sha) => sha,
        // Nothing captured. Which of the several reasons it was decides what we
        // are allowed to claim, so ask git rather than guessing.
        None => {
            let (list, _) = list(project_path);
            return (list, Some(nothing_captured_note(project_path)));
        }
    };

    let ref_name = match free_ref_name(project_path, now_unix, &sha) {
        Some(name) => name,
        None => {
            let (list, _) = list(project_path);
            return (
                list,
                Some(
                    "Captured a snapshot but couldn't find a free ref name for it, so it wasn't \
                     kept. Nothing in your working tree changed."
                        .to_string(),
                ),
            );
        }
    };

    // Until the ref exists the snapshot is unreachable and git may collect it,
    // so a failure here means we did not deliver a checkpoint. Say that plainly.
    if !update_ref(project_path, &ref_name, &sha) {
        let (list, _) = list(project_path);
        return (
            list,
            Some(
                "Captured a snapshot but couldn't write the ref that keeps it alive, so git may \
                 garbage-collect it. Nothing in your working tree changed."
                    .to_string(),
            ),
        );
    }

    // Re-read rather than synthesizing the new entry, so the client always sees
    // exactly what git now holds.
    let (list, note) = list(project_path);
    // A checkpoint that succeeded still has to say what it did NOT capture:
    // `git stash create` snapshots tracked work only. Staying silent here would
    // let someone trust the snapshot as a complete safety net and then lose
    // untracked files it never held — the one way this feature could hurt.
    (
        list,
        note.or_else(|| untracked_exclusion_note(project_path)),
    )
}

/// A warning naming the untracked files a successful capture left out, or `None`
/// when there were none (nothing to warn about).
fn untracked_exclusion_note(project_path: &str) -> Option<String> {
    let status = git_stdout(project_path, &["status", "--porcelain"])?;
    let untracked = status.lines().filter(|l| l.starts_with("??")).count();
    if untracked == 0 {
        return None;
    }
    let plural = if untracked == 1 { "" } else { "s" };
    Some(format!(
        "Snapshot saved — but it does not include {untracked} untracked file{plural}. A checkpoint \
         captures tracked work only, so `git add` anything new you'd want back."
    ))
}

/// List `project_path`'s checkpoints, newest first.
///
/// Read-only. Refs that no longer resolve, or whose metadata git won't produce,
/// are skipped rather than reported as partial garbage.
pub fn list(project_path: &str) -> (Vec<Checkpoint>, Option<String>) {
    if !is_git_repo(project_path) {
        return (
            Vec::new(),
            Some(format!(
                "{project_path} isn't a git repository, so it has no checkpoints."
            )),
        );
    }

    let stdout = match git_stdout(
        project_path,
        &[
            "for-each-ref",
            REF_PREFIX,
            // Subject last: it's the only field that could itself contain a tab.
            "--format=%(refname)%09%(objectname)%09%(committerdate:unix)%09%(contents:subject)",
        ],
    ) {
        Some(s) => s,
        None => return (Vec::new(), None),
    };

    let mut out: Vec<Checkpoint> = stdout
        .lines()
        .filter_map(|line| parse_ref_line(project_path, line))
        .collect();

    // Newest first. Ref names embed the creation second, so they break ties
    // deterministically when two snapshots share a committer timestamp.
    out.sort_by(|a, b| {
        b.created_at_unix
            .cmp(&a.created_at_unix)
            .then_with(|| b.ref_name.cmp(&a.ref_name))
    });

    (out, None)
}

/// Build one [`Checkpoint`] from a `for-each-ref` line, filling in the fields
/// that need a follow-up git read. `None` for a malformed line.
fn parse_ref_line(project_path: &str, line: &str) -> Option<Checkpoint> {
    let mut fields = line.splitn(4, '\t');
    let ref_name = fields.next()?.trim().to_string();
    let id = fields.next()?.trim().to_string();
    let created_at_unix: i64 = fields.next()?.trim().parse().ok()?;
    let subject = fields.next().unwrap_or("");
    if ref_name.is_empty() || id.is_empty() {
        return None;
    }

    let (branch, label) = parse_subject(subject);
    // The subject only records a branch for snapshots taken on one; fall back to
    // where the repo is now, which is the best honest guess available.
    let branch = branch.or_else(|| current_branch(project_path));

    Some(Checkpoint {
        restore_command: restore_command(project_path, &id),
        files: captured_files(project_path, &id),
        id,
        ref_name,
        label,
        project_path: project_path.to_string(),
        branch,
        created_at_unix,
    })
}

/// Split a stash commit subject into `(branch, label)`.
///
/// `git stash create "<label>"` writes `On <branch>: <label>`, so one read gives
/// us both back. Detached HEAD records the literal `(no branch)`, which is not a
/// branch name — that becomes `None`. A bare `git stash` (no message) writes
/// `WIP on <branch>: <sha> <subject>`; we don't produce those, but a
/// hand-written ref in our namespace could, so parse them rather than choke.
/// Anything else is treated as the label verbatim.
fn parse_subject(subject: &str) -> (Option<String>, String) {
    let subject = subject.trim();
    for prefix in ["On ", "WIP on "] {
        let Some(rest) = subject.strip_prefix(prefix) else {
            continue;
        };
        // ':' can't appear in a ref name, so the first ": " ends the branch and
        // everything after it is the label (which may itself contain ": ").
        let Some((branch, label)) = rest.split_once(": ") else {
            continue;
        };
        let branch = branch.trim();
        let named = branch != "(no branch)" && !branch.is_empty();
        return (named.then(|| branch.to_string()), label.trim().to_string());
    }
    (None, subject.to_string())
}

/// The label to record: the caller's (trimmed, flattened to one line so it can't
/// corrupt the commit subject we parse back), else a readable UTC timestamp.
fn resolve_label(label: Option<&str>, now_unix: i64) -> String {
    let cleaned = label.map(single_line).unwrap_or_default();
    if cleaned.is_empty() {
        default_label(now_unix)
    } else {
        cleaned
    }
}

/// Collapse all whitespace runs (including newlines) to single spaces and trim.
fn single_line(raw: &str) -> String {
    raw.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// A readable default label, e.g. `Checkpoint 2026-07-16 14:30 UTC`. UTC because
/// the core does all of its date math in UTC (see [`crate::datetime`]).
fn default_label(now_unix: i64) -> String {
    let date = civil_from_days(now_unix.div_euclid(SECS_PER_DAY));
    let secs_of_day = now_unix.rem_euclid(SECS_PER_DAY);
    format!(
        "Checkpoint {} {:02}:{:02} UTC",
        date.iso(),
        secs_of_day / 3600,
        (secs_of_day % 3600) / 60
    )
}

/// The exact command that restores `sha`, for the client to show and run behind
/// a confirmation. **Never executed here.** `apply` rather than `pop`: applying
/// doesn't consume the snapshot, so a failed restore leaves the checkpoint
/// intact and re-runnable.
fn restore_command(project_path: &str, sha: &str) -> String {
    format!("git -C {} stash apply {}", shell_quote(project_path), sha)
}

/// POSIX single-quote a string so it survives a shell verbatim. Everything
/// inside single quotes is literal, so the only case to handle is a `'` itself:
/// close the quote, emit an escaped quote, reopen (`'\''`).
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// Files whose uncommitted state the snapshot captured, capped at
/// [`CHECKPOINT_FILES_CAP`]. Empty when git won't describe the object (e.g. a
/// ref in our namespace that isn't a stash commit) — better to report no files
/// than to guess.
fn captured_files(project_path: &str, sha: &str) -> Vec<String> {
    // `stash show` diffs the snapshot against its base commit, which is exactly
    // "what was uncommitted". quotePath=false keeps non-ASCII paths readable.
    let stdout = match git_stdout(
        project_path,
        &[
            "-c",
            "core.quotePath=false",
            "stash",
            "show",
            "--name-only",
            sha,
        ],
    ) {
        Some(s) => s,
        None => return Vec::new(),
    };
    stdout
        .lines()
        .map(unquote)
        .filter(|p| !p.is_empty())
        .take(CHECKPOINT_FILES_CAP)
        .collect()
}

/// Strip the surrounding double quotes git wraps around paths it had to escape.
/// A non-quoted path is returned as-is (trimmed).
fn unquote(s: &str) -> String {
    let s = s.trim();
    if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') {
        s[1..s.len() - 1].to_string()
    } else {
        s.to_string()
    }
}

/// Explain why a capture produced nothing, grounded in what git actually
/// reports. `git stash create` is silent for several different reasons and we
/// must not collapse them into one comfortable-sounding claim.
fn nothing_captured_note(project_path: &str) -> String {
    let status = match git_stdout(project_path, &["status", "--porcelain"]) {
        Some(s) => s,
        None => {
            return "Couldn't capture a snapshot — git wouldn't report the repository's status. \
                    Nothing was changed."
                .to_string()
        }
    };

    if status.trim().is_empty() {
        return "Nothing to capture — the working tree is clean, so your last commit is already \
                the restore point."
            .to_string();
    }

    // Untracked files are dirty to the user but invisible to `stash create`,
    // which snapshots tracked work only. Claiming "clean" here would be a lie.
    let untracked = status.lines().filter(|l| l.starts_with("??")).count();
    if untracked > 0 && status.lines().all(|l| l.starts_with("??")) {
        let plural = if untracked == 1 { "" } else { "s" };
        return format!(
            "Nothing to capture — the only change{plural} here {} {untracked} untracked file{plural}, \
             and a checkpoint snapshots tracked work. `git add` them first to include them.",
            if untracked == 1 { "is" } else { "are" }
        );
    }

    "Couldn't capture a snapshot — git declined to build one from the current changes. \
     Nothing was changed."
        .to_string()
}

/// A ref name that won't clobber a different snapshot.
///
/// `<now_unix>-<short-sha>` is unique and sorts naturally, and embedding the SHA
/// means a *different* snapshot in the same second gets a different name. If the
/// name is already taken by this exact SHA, it's the same snapshot and reusing
/// it is idempotent; only a genuine short-SHA clash needs a suffix.
fn free_ref_name(project_path: &str, now_unix: i64, sha: &str) -> Option<String> {
    let short = sha.get(..7).unwrap_or(sha);
    let base = format!("{REF_PREFIX}/{now_unix}-{short}");
    for attempt in 1..=REF_NAME_ATTEMPTS {
        let candidate = if attempt == 1 {
            base.clone()
        } else {
            format!("{base}-{attempt}")
        };
        match ref_target(project_path, &candidate) {
            None => return Some(candidate),
            Some(existing) if existing == sha => return Some(candidate),
            Some(_) => continue,
        }
    }
    None
}

/// The SHA `ref_name` points at, or `None` if it doesn't exist.
fn ref_target(project_path: &str, ref_name: &str) -> Option<String> {
    git_stdout(
        project_path,
        &["rev-parse", "--verify", "--quiet", ref_name],
    )
    .filter(|s| !s.is_empty())
}

/// Point `ref_name` at `sha`, keeping the snapshot reachable. Additive: creates
/// or retargets a ref in our own namespace and touches nothing else.
fn update_ref(project_path: &str, ref_name: &str, sha: &str) -> bool {
    git_status_ok(project_path, &["update-ref", ref_name, sha])
}

/// Write a snapshot commit of the current working tree and index, returning its
/// SHA. **Non-destructive**: `stash create` builds the object and stops — it
/// does not stash, revert, or move anything. Prints nothing (⇒ `None`) when
/// there's nothing to capture.
fn stash_create(project_path: &str, label: &str) -> Option<String> {
    // `label` is one positional arg (git joins extra args into the message, so a
    // `--` separator would end up *inside* the label). No shell is involved, and
    // git accepts a leading-dash message here.
    git_stdout(project_path, &["stash", "create", label]).filter(|s| !s.is_empty())
}

/// Whether `project_path` is inside a git repository.
fn is_git_repo(project_path: &str) -> bool {
    git_status_ok(project_path, &["rev-parse", "--git-dir"])
}

/// Whether HEAD resolves — false in a fresh repo with no commits yet.
fn has_head(project_path: &str) -> bool {
    git_status_ok(project_path, &["rev-parse", "--verify", "--quiet", "HEAD"])
}

/// The current branch, or `None` when detached or unreadable.
fn current_branch(project_path: &str) -> Option<String> {
    git_stdout(project_path, &["rev-parse", "--abbrev-ref", "HEAD"])
        .filter(|b| !b.is_empty() && b != "HEAD")
}

/// Run `git -C <project_path> <args…>` and return trimmed stdout on success.
/// `None` for a failed command, a missing `git`, or non-UTF-8 output — callers
/// degrade rather than panic.
fn git_stdout(project_path: &str, args: &[&str]) -> Option<String> {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(project_path)
        .args(args)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Run `git -C <project_path> <args…>` for its exit status alone.
fn git_status_ok(project_path: &str, args: &[&str]) -> bool {
    std::process::Command::new("git")
        .arg("-C")
        .arg(project_path)
        .args(args)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A throwaway git repo that cleans itself up. Hand-rolled to keep the core
    /// free of dev-dependencies (`tempfile` isn't in the workspace).
    struct TempRepo {
        path: PathBuf,
    }

    impl TempRepo {
        /// A repo with one commit containing `a.txt`, on branch `main`.
        fn new() -> Self {
            static COUNTER: AtomicUsize = AtomicUsize::new(0);
            let unique = format!(
                "stackpulse-ckpt-{}-{}",
                std::process::id(),
                COUNTER.fetch_add(1, Ordering::SeqCst)
            );
            let path = std::env::temp_dir().join(unique);
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).expect("create temp dir");
            let repo = TempRepo { path };

            repo.git(&["init", "-q", "-b", "main", "."]);
            // Local identity so commits work on a machine/CI with no global config.
            repo.git(&["config", "user.email", "test@stackpulse.local"]);
            repo.git(&["config", "user.name", "StackPulse Test"]);
            repo.write("a.txt", "committed\n");
            repo.git(&["add", "a.txt"]);
            repo.git(&["commit", "-q", "-m", "initial"]);
            repo
        }

        /// A directory that is deliberately *not* a git repo.
        fn bare_dir() -> Self {
            static COUNTER: AtomicUsize = AtomicUsize::new(0);
            let unique = format!(
                "stackpulse-nonrepo-{}-{}",
                std::process::id(),
                COUNTER.fetch_add(1, Ordering::SeqCst)
            );
            let path = std::env::temp_dir().join(unique);
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).expect("create temp dir");
            TempRepo { path }
        }

        fn str_path(&self) -> &str {
            self.path.to_str().expect("utf-8 temp path")
        }

        fn write(&self, name: &str, contents: &str) {
            std::fs::write(self.path.join(name), contents).expect("write file");
        }

        fn read(&self, name: &str) -> String {
            std::fs::read_to_string(self.path.join(name)).unwrap_or_default()
        }

        fn git(&self, args: &[&str]) -> String {
            let out = std::process::Command::new("git")
                .arg("-C")
                .arg(&self.path)
                .args(args)
                .output()
                .expect("run git");
            String::from_utf8_lossy(&out.stdout).trim().to_string()
        }

        /// Everything about the tree a checkpoint must not disturb.
        fn observable_state(&self) -> (String, String, String, String) {
            (
                self.git(&["status", "--porcelain"]),
                self.git(&["rev-parse", "HEAD"]),
                self.git(&["diff"]),             // unstaged changes
                self.git(&["diff", "--cached"]), // the index
            )
        }
    }

    impl Drop for TempRepo {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    fn is_in_git_repo(p: &Path) -> bool {
        std::process::Command::new("git")
            .arg("-C")
            .arg(p)
            .args(["rev-parse", "--git-dir"])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }

    /// A successful capture must still disclose that untracked files were left
    /// out. Silence here is the one failure mode that could actually cost work:
    /// trusting the snapshot as complete and losing files it never held.
    #[test]
    fn successful_capture_warns_about_untracked_files_it_excluded() {
        let repo = TempRepo::new();
        repo.write("a.txt", "agent mid-edit"); // tracked + modified -> captured
        repo.write("scratch.md", "notes git never saw"); // untracked -> NOT captured

        let (checkpoints, note) = create(repo.str_path(), Some("mixed"), 1_700_000_100);

        // The capture itself succeeded...
        assert_eq!(
            checkpoints.len(),
            1,
            "tracked work should still be captured"
        );
        assert!(checkpoints[0].files.iter().any(|f| f == "a.txt"));
        assert!(
            !checkpoints[0].files.iter().any(|f| f == "scratch.md"),
            "stash create cannot capture untracked files"
        );

        // ...and it says what it left out.
        let note = note.expect("a capture leaving untracked files out must say so");
        assert!(note.contains("untracked"), "note was: {note}");
        assert!(note.contains('1'), "note should name the count: {note}");
    }

    /// The converse: with nothing untracked there is nothing to warn about, so a
    /// clean capture must not nag.
    #[test]
    fn successful_capture_with_no_untracked_files_has_no_note() {
        let repo = TempRepo::new();
        repo.write("a.txt", "agent mid-edit");

        let (checkpoints, note) = create(repo.str_path(), Some("tracked only"), 1_700_000_200);
        assert_eq!(checkpoints.len(), 1);
        assert!(note.is_none(), "unexpected note: {note:?}");
    }

    #[test]
    fn non_repo_returns_note_and_no_checkpoints() {
        let dir = TempRepo::bare_dir();
        // Guard the premise: if temp_dir were inside a repo, this proves nothing.
        assert!(!is_in_git_repo(&dir.path));

        let (checkpoints, note) = create(dir.str_path(), Some("x"), 1_700_000_000);
        assert!(checkpoints.is_empty());
        assert!(note.unwrap().contains("isn't a git repository"));

        let (listed, note) = list(dir.str_path());
        assert!(listed.is_empty());
        assert!(note.is_some());
    }

    #[test]
    fn missing_path_degrades_instead_of_panicking() {
        let (checkpoints, note) = create("/nonexistent/does/not/exist", None, 1_700_000_000);
        assert!(checkpoints.is_empty());
        assert!(note.is_some());
    }

    #[test]
    fn clean_repo_invents_no_checkpoint() {
        let repo = TempRepo::new();
        let (checkpoints, note) = create(repo.str_path(), Some("nothing to do"), 1_700_000_000);

        assert!(checkpoints.is_empty(), "must not fabricate a checkpoint");
        let note = note.expect("clean tree deserves an honest note");
        assert!(note.contains("clean"), "note was: {note}");
        // No stray refs left behind.
        assert!(repo.git(&["for-each-ref", REF_PREFIX]).is_empty());
    }

    #[test]
    fn untracked_only_is_not_reported_as_clean() {
        let repo = TempRepo::new();
        repo.write("brand-new.txt", "untracked\n");

        let (checkpoints, note) = create(repo.str_path(), Some("try"), 1_700_000_000);

        assert!(checkpoints.is_empty());
        let note = note.expect("must explain that nothing was captured");
        // `stash create` is silent here just like a clean tree — but the user
        // has real changes, so calling this "clean" would be a lie.
        assert!(note.contains("untracked"), "note was: {note}");
        assert!(!note.contains("clean"), "note was: {note}");
    }

    #[test]
    fn repo_without_commits_is_explained() {
        let repo = TempRepo::bare_dir();
        std::process::Command::new("git")
            .arg("-C")
            .arg(&repo.path)
            .args(["init", "-q", "-b", "main", "."])
            .output()
            .expect("git init");

        let (checkpoints, note) = create(repo.str_path(), None, 1_700_000_000);
        assert!(checkpoints.is_empty());
        assert!(note.unwrap().contains("no commits yet"));
    }

    /// The critical safety test: capturing must not disturb in-progress work.
    #[test]
    fn create_captures_dirty_work_and_leaves_working_tree_untouched() {
        let repo = TempRepo::new();
        repo.write("a.txt", "UNCOMMITTED EDIT\n");
        repo.write("staged.txt", "staged content\n");
        repo.git(&["add", "staged.txt"]);
        repo.write("untracked.txt", "untracked\n");

        let before_state = repo.observable_state();
        let before_a = repo.read("a.txt");
        let before_staged = repo.read("staged.txt");
        let before_untracked = repo.read("untracked.txt");

        let (checkpoints, note) = create(repo.str_path(), Some("before agent run"), 1_700_000_000);

        // The snapshot happened — and because this fixture also has an untracked
        // file, it must disclose that the snapshot doesn't cover it.
        assert!(
            note.as_deref().is_some_and(|n| n.contains("untracked")),
            "a capture leaving untracked work out must say so; got: {note:?}"
        );
        assert_eq!(checkpoints.len(), 1);
        let cp = &checkpoints[0];
        assert!(!cp.id.is_empty());
        assert!(cp.ref_name.starts_with(REF_PREFIX));
        assert_eq!(cp.label, "before agent run");
        assert_eq!(cp.branch.as_deref(), Some("main"));
        assert_eq!(cp.project_path, repo.str_path());
        assert!(
            cp.files.contains(&"a.txt".to_string()),
            "files: {:?}",
            cp.files
        );
        assert!(
            cp.files.contains(&"staged.txt".to_string()),
            "files: {:?}",
            cp.files
        );

        // …and it kept the object alive.
        assert_eq!(repo.git(&["rev-parse", "--verify", &cp.ref_name]), cp.id);

        // THE GUARANTEE: nothing the user was working on moved.
        assert_eq!(repo.read("a.txt"), before_a, "working file was modified");
        assert_eq!(repo.read("staged.txt"), before_staged);
        assert_eq!(repo.read("untracked.txt"), before_untracked);
        assert_eq!(
            repo.observable_state(),
            before_state,
            "status/HEAD/diff/index must be byte-identical after a checkpoint"
        );
        // The edit is still uncommitted — we snapshotted, we didn't commit it.
        assert!(repo.git(&["status", "--porcelain"]).contains("a.txt"));
    }

    #[test]
    fn restore_command_is_reported_but_never_run() {
        let repo = TempRepo::new();
        repo.write("a.txt", "edited\n");

        let (checkpoints, _) = create(repo.str_path(), Some("snap"), 1_700_000_000);
        let cp = &checkpoints[0];

        assert_eq!(
            cp.restore_command,
            format!("git -C '{}' stash apply {}", repo.str_path(), cp.id)
        );
        // `apply`, not `pop`/`push`: non-consuming and non-destructive.
        assert!(!cp.restore_command.contains("pop"));
        assert!(!cp.restore_command.contains("stash push"));
        // Reporting it must not have applied anything: the stash list is empty
        // (we never pushed) and the tree still holds the edit.
        assert!(repo.git(&["stash", "list"]).is_empty());
        assert_eq!(repo.read("a.txt"), "edited\n");
    }

    #[test]
    fn label_round_trips_and_defaults_are_readable() {
        let repo = TempRepo::new();
        repo.write("a.txt", "one\n");
        let (checkpoints, _) = create(repo.str_path(), Some("  my: fancy label  "), 1_700_000_000);
        assert_eq!(checkpoints[0].label, "my: fancy label");

        // No label ⇒ readable UTC timestamp derived from `now_unix`.
        repo.write("a.txt", "two\n");
        let (checkpoints, _) = create(repo.str_path(), None, 1_700_000_000);
        assert_eq!(checkpoints.len(), 2);
        assert!(
            checkpoints
                .iter()
                .any(|c| c.label == "Checkpoint 2023-11-14 22:13 UTC"),
            "labels: {:?}",
            checkpoints.iter().map(|c| &c.label).collect::<Vec<_>>()
        );
    }

    #[test]
    fn two_checkpoints_in_the_same_second_do_not_collide() {
        let repo = TempRepo::new();
        repo.write("a.txt", "first\n");
        let (first, _) = create(repo.str_path(), Some("first"), 1_700_000_000);
        assert_eq!(first.len(), 1);

        // Same `now_unix`, different content ⇒ different SHA ⇒ distinct ref.
        repo.write("a.txt", "second\n");
        let (second, _) = create(repo.str_path(), Some("second"), 1_700_000_000);
        assert_eq!(second.len(), 2, "the same second must not overwrite");
        assert_ne!(second[0].ref_name, second[1].ref_name);
        assert_ne!(second[0].id, second[1].id);
    }

    #[test]
    fn list_orders_newest_first() {
        let repo = TempRepo::new();
        // Build refs over commits with pinned committer dates so the ordering
        // assertion doesn't depend on wall-clock timing.
        for (stamp, msg, date) in [
            (981_173_106_i64, "On main: older", "2001-02-03T04:05:06"),
            (1_580_702_706_i64, "On main: newer", "2020-02-03T04:05:06"),
        ] {
            std::fs::write(repo.path.join("a.txt"), msg).expect("write");
            let out = std::process::Command::new("git")
                .arg("-C")
                .arg(&repo.path)
                .args(["commit", "-q", "-a", "-m", msg])
                .env("GIT_COMMITTER_DATE", date)
                .env("GIT_AUTHOR_DATE", date)
                .output()
                .expect("commit");
            assert!(out.status.success());
            let sha = repo.git(&["rev-parse", "HEAD"]);
            // Ref names can't contain ':', so use the same digits-and-hyphens
            // shape `free_ref_name` produces.
            let ref_name = format!("{REF_PREFIX}/{stamp}-{}", &sha[..7]);
            repo.git(&["update-ref", &ref_name, &sha]);
            assert_eq!(
                repo.git(&["rev-parse", "--verify", &ref_name]),
                sha,
                "test setup: ref must exist"
            );
        }

        let (checkpoints, note) = list(repo.str_path());
        assert_eq!(note, None);
        assert_eq!(checkpoints.len(), 2);
        assert_eq!(checkpoints[0].label, "newer");
        assert_eq!(checkpoints[1].label, "older");
        assert!(checkpoints[0].created_at_unix > checkpoints[1].created_at_unix);
    }

    #[test]
    fn list_is_empty_for_a_repo_without_checkpoints() {
        let repo = TempRepo::new();
        let (checkpoints, note) = list(repo.str_path());
        assert!(checkpoints.is_empty());
        assert_eq!(note, None);
    }

    // --- pure helpers -----------------------------------------------------

    #[test]
    fn parse_subject_recovers_branch_and_label() {
        assert_eq!(
            parse_subject("On main: before agent run"),
            (Some("main".to_string()), "before agent run".to_string())
        );
        // Labels may contain ": " themselves.
        assert_eq!(
            parse_subject("On feat/x: fix: the thing"),
            (Some("feat/x".to_string()), "fix: the thing".to_string())
        );
        // Detached HEAD isn't a branch name.
        assert_eq!(
            parse_subject("On (no branch): detached work"),
            (None, "detached work".to_string())
        );
        // Default `git stash` messages.
        assert_eq!(
            parse_subject("WIP on main: 6615b6f initial"),
            (Some("main".to_string()), "6615b6f initial".to_string())
        );
        // Anything else is the label verbatim.
        assert_eq!(
            parse_subject("just a label"),
            (None, "just a label".to_string())
        );
    }

    #[test]
    fn labels_are_flattened_to_one_line() {
        // A newline would forge a fake subject line and corrupt the round-trip.
        assert_eq!(resolve_label(Some("a\nb  c"), 0), "a b c");
        assert_eq!(
            resolve_label(Some("   "), 1_700_000_000),
            default_label(1_700_000_000)
        );
    }

    #[test]
    fn shell_quote_escapes_single_quotes() {
        assert_eq!(shell_quote("/tmp/plain"), "'/tmp/plain'");
        assert_eq!(shell_quote("/tmp/it's here"), r"'/tmp/it'\''s here'");
        // A path with a space stays one shell word.
        assert_eq!(shell_quote("/App Privadas/x"), "'/App Privadas/x'");
    }

    #[test]
    fn default_label_is_human_readable_utc() {
        assert_eq!(default_label(0), "Checkpoint 1970-01-01 00:00 UTC");
        assert_eq!(
            default_label(1_700_000_000),
            "Checkpoint 2023-11-14 22:13 UTC"
        );
    }
}
