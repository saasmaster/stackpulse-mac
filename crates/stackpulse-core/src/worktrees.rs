//! Worktrees — a second working directory so an agent never touches your own.
//!
//! A git worktree is an additional checkout of the same repository on its own
//! branch. That is the whole point here: "let an agent loose on my repo" becomes
//! "let an agent loose on *a copy of* my repo", so whatever it does happens
//! somewhere you weren't working.
//!
//! Creating one is **additive**. `git worktree add <path> -b <branch>` makes a
//! new directory and a new branch and changes nothing about the existing working
//! tree, the index, or HEAD — safe to run while you (or an agent) are mid-edit.
//! That guarantee is what makes this feature worth having, so it is pinned by a
//! test rather than trusted.
//!
//! Removing one deletes a directory of real work, so the core refuses to own it.
//! Nothing here ever runs `git worktree remove`/`prune`, `rm -rf`, `checkout`,
//! `reset`, or `clean`. We only *report* [`Worktree::remove_command`], and the
//! client runs it behind an explicit confirmation. The main worktree reports no
//! command at all: removing it is never a valid thing to want.
//!
//! `name` is caller-supplied and reaches both a filesystem path and a git ref, so
//! it is sanitized down to a single safe component before it is used — never
//! interpolated into a shell, never able to contain `/`, `..`, or a leading `-`
//! that git would read as a flag.
//!
//! Portable + offline (ADR-0005): local `git` only, never the network. Any git
//! failure degrades to a note plus whatever we could still read — never a panic,
//! never a false success.

use stackpulse_protocol::Worktree;
use std::path::{Path, PathBuf};

/// How we recognize a worktree as one of ours in [`list`], which — unlike
/// [`create`] — is not told where the client keeps them.
///
/// The honest rule is "it lives under StackPulse's own worktrees directory", and
/// the client builds that directory as `…/StackPulse/worktrees`. Matching the
/// path segment is a heuristic, not proof: a user could coincidentally nest a
/// repo this way. It only drives a label, never a destructive decision, so a
/// false positive costs nothing.
const STACKPULSE_PATH_MARKER: &str = "/StackPulse/worktrees/";

/// Ref namespace for branches we create. Namespaced so an agent branch can never
/// be mistaken for — or collide with — one of the user's own.
const BRANCH_PREFIX: &str = "stackpulse";

/// Upper bound on a sanitized name. Keeps directory names readable and stays
/// well clear of filesystem component limits. Safe to slice at a byte index:
/// sanitizing leaves ASCII only.
const MAX_NAME_LEN: usize = 40;

/// List the worktrees of `project_path`, main first.
///
/// Read-only: this only asks git what already exists.
///
/// Returns `(vec![], Some(note))` when `project_path` isn't a git repository or
/// git won't answer — never a panic, never a fabricated entry.
pub fn list(project_path: &str) -> (Vec<Worktree>, Option<String>) {
    if !is_git_repo(project_path) {
        return (
            Vec::new(),
            Some(format!(
                "{project_path} isn't a git repository, so it has no worktrees."
            )),
        );
    }

    let stdout = match git_stdout(project_path, &["worktree", "list", "--porcelain"]) {
        Some(s) => s,
        None => {
            return (
                Vec::new(),
                Some(
                    "Couldn't list worktrees — git declined to describe this repository."
                        .to_string(),
                ),
            )
        }
    };

    (parse_porcelain(project_path, &stdout), None)
}

/// Create an isolated worktree for `name` under `worktrees_dir` and return the
/// refreshed list.
///
/// Additive by construction: a new directory and a new branch appear, and the
/// existing working tree, index, and HEAD are left exactly as they were.
///
/// Never clobbers. If the directory or the branch already exists we stop and say
/// so — reusing either would silently hand an agent someone else's work.
pub fn create(
    project_path: &str,
    worktrees_dir: &str,
    name: &str,
) -> (Vec<Worktree>, Option<String>) {
    if !is_git_repo(project_path) {
        return (
            Vec::new(),
            Some(format!(
                "{project_path} isn't a git repository, so there's nothing to branch a worktree \
                 from."
            )),
        );
    }

    // A worktree is checked out at a commit, so an unborn HEAD has no base to
    // create one from. Say that precisely instead of surfacing git's failure.
    if !has_head(project_path) {
        return (
            Vec::new(),
            Some(
                "This repository has no commits yet, so there's no base commit to create a \
                 worktree from. Make an initial commit first."
                    .to_string(),
            ),
        );
    }

    // A relative `worktrees_dir` would resolve against the repository, planting
    // the worktree *inside* the project it's supposed to stay out of.
    if !Path::new(worktrees_dir).is_absolute() {
        return (
            Vec::new(),
            Some(
                "Couldn't create a worktree — the worktrees directory must be an absolute path."
                    .to_string(),
            ),
        );
    }

    let Some(safe) = sanitize_name(name) else {
        return (
            Vec::new(),
            Some(format!(
                "\"{name}\" doesn't leave any usable characters for a branch or folder name. Use \
                 letters, numbers, dots, dashes, or underscores."
            )),
        );
    };

    let branch = format!("{BRANCH_PREFIX}/{safe}");

    // Belt and braces: our own rules should already guarantee a legal ref, but
    // git is the authority on what it will accept. Ask it rather than find out
    // halfway through.
    if !is_valid_ref(&format!("refs/heads/{branch}")) {
        return (
            Vec::new(),
            Some(format!(
                "\"{name}\" doesn't work as a branch name (git rejects \"{branch}\"). Try a \
                 simpler name."
            )),
        );
    }

    let path = worktree_path(project_path, worktrees_dir, &safe);

    // Both checks are "does something already live here?", and the answer is
    // never "overwrite it": the directory could hold an agent's work in progress
    // and the branch could be the user's own.
    if path.exists() {
        let (list, _) = list(project_path);
        return (
            list,
            Some(format!(
                "{} already exists, so nothing was created or overwritten. Pick a different name.",
                path.display()
            )),
        );
    }
    if branch_exists(project_path, &branch) {
        let (list, _) = list(project_path);
        return (
            list,
            Some(format!(
                "Branch {branch} already exists, so nothing was created or overwritten. Pick a \
                 different name."
            )),
        );
    }

    if let Err(err) = worktree_add(project_path, &path, &branch) {
        let (list, _) = list(project_path);
        return (
            list,
            Some(format!(
                "Couldn't create the worktree — git said: {err}. Nothing in your working tree \
                 changed."
            )),
        );
    }

    // Re-read rather than synthesizing the new entry, so the client always sees
    // exactly what git now holds.
    list(project_path)
}

/// The directory to create the worktree in: `<worktrees_dir>/<repo>-<name>`.
/// Prefixing with the repository name keeps one flat worktrees directory legible
/// when several projects use it.
fn worktree_path(project_path: &str, worktrees_dir: &str, safe_name: &str) -> PathBuf {
    Path::new(worktrees_dir).join(format!("{}-{safe_name}", repo_name(project_path)))
}

/// A short, safe label for the repository. The toplevel is the real answer (the
/// caller may hand us a subdirectory), with the given path as a fallback and a
/// generic name when neither survives sanitizing — this only decorates a
/// directory name, so it must never be the thing that fails.
fn repo_name(project_path: &str) -> String {
    git_stdout(project_path, &["rev-parse", "--show-toplevel"])
        .filter(|s| !s.is_empty())
        .as_deref()
        .and_then(last_component)
        .or_else(|| last_component(project_path))
        .and_then(|n| sanitize_name(&n))
        .unwrap_or_else(|| "repo".to_string())
}

/// The final component of a path, if it has one.
fn last_component(path: &str) -> Option<String> {
    Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .map(str::to_string)
}

/// Reduce a caller-supplied name to one safe path component that is also a legal
/// git ref component, or `None` when nothing usable survives.
///
/// This is the security boundary of the module: `name` reaches a filesystem path
/// and a git ref. The rules, in order:
///
/// 1. Lowercase, and keep only `[a-z0-9._-]` — everything else (including `/`,
///    spaces, `~^:?*[\`, `@`, and control characters) becomes `-`. That alone
///    rules out escaping the directory and every character git forbids in a ref.
/// 2. Collapse runs of `-` and of `.`, which kills the `..` git refuses (and
///    which would mean "parent directory" on the filesystem).
/// 3. Trim leading/trailing `-._`, so the result can't start with `-` (which git
///    would read as a flag), can't start with `.` (hidden directory, illegal ref
///    component), and can't end with `.`.
/// 4. Drop any `.lock` suffix, which git reserves.
/// 5. Cap the length, then re-trim in case the cut exposed a new edge.
fn sanitize_name(raw: &str) -> Option<String> {
    let mut out = String::with_capacity(raw.len());
    for ch in raw.chars() {
        let c = ch.to_ascii_lowercase();
        let keep = c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-');
        let c = if keep { c } else { '-' };
        // Collapse runs of the two characters that are only dangerous repeated.
        if (c == '-' || c == '.') && out.ends_with(c) {
            continue;
        }
        out.push(c);
    }

    let trim = |s: &str| s.trim_matches(|c| matches!(c, '-' | '.' | '_')).to_string();

    let mut out = trim(&out);
    while let Some(stripped) = out.strip_suffix(".lock") {
        out = trim(stripped);
    }
    out.truncate(MAX_NAME_LEN);
    let out = trim(&out);

    (!out.is_empty()).then_some(out)
}

/// Build one [`Worktree`] per record of `git worktree list --porcelain`.
///
/// Records are blank-line separated and always open with a `worktree <path>`
/// line, so a new record starts there. Git lists the primary working tree first,
/// which is the only way to identify it.
fn parse_porcelain(project_path: &str, stdout: &str) -> Vec<Worktree> {
    let mut out: Vec<Worktree> = Vec::new();
    let mut current: Option<Record> = None;

    for line in stdout.lines() {
        let line = line.trim_end();
        if let Some(path) = line.strip_prefix("worktree ") {
            if let Some(record) = current.take() {
                push_record(project_path, &mut out, record);
            }
            current = Some(Record {
                path: path.to_string(),
                ..Record::default()
            });
            continue;
        }
        let Some(record) = current.as_mut() else {
            continue; // Attribute with no record to attach to; ignore it.
        };
        if let Some(sha) = line.strip_prefix("HEAD ") {
            record.head = Some(sha.to_string());
        } else if let Some(branch) = line.strip_prefix("branch ") {
            record.branch = Some(branch.to_string());
        } else if line == "detached" {
            record.detached = true;
        } else if line == "locked" || line.starts_with("locked ") {
            // `locked` may carry a reason; its presence is all we report.
            record.locked = true;
        }
    }
    if let Some(record) = current.take() {
        push_record(project_path, &mut out, record);
    }

    out
}

/// One parsed porcelain record, before it becomes a [`Worktree`].
#[derive(Default)]
struct Record {
    path: String,
    head: Option<String>,
    /// Full ref as git printed it, e.g. `refs/heads/main`.
    branch: Option<String>,
    detached: bool,
    locked: bool,
}

/// Turn a record into a [`Worktree`] and append it. The first one git lists is
/// the primary working tree. Records without a path are dropped rather than
/// reported as a worktree we can't name.
fn push_record(project_path: &str, out: &mut Vec<Worktree>, record: Record) {
    if record.path.is_empty() {
        return;
    }
    let is_main = out.is_empty();
    let remove_command = (!is_main).then(|| remove_command(project_path, &record.path));

    out.push(Worktree {
        is_stackpulse: record.path.contains(STACKPULSE_PATH_MARKER),
        // Detached is git's own word for "no branch here", so never invent one.
        branch: if record.detached {
            None
        } else {
            record.branch.as_deref().map(short_branch)
        },
        head: record.head,
        is_main,
        is_locked: record.locked,
        remove_command,
        path: record.path,
    });
}

/// The short branch name git shows users, e.g. `refs/heads/feat/x` → `feat/x`.
/// Anything outside `refs/heads/` is reported verbatim rather than mangled.
fn short_branch(full_ref: &str) -> String {
    full_ref
        .strip_prefix("refs/heads/")
        .unwrap_or(full_ref)
        .to_string()
}

/// The exact command that would remove `worktree_path`, for the client to show
/// and run behind a confirmation. **Never executed here.**
fn remove_command(project_path: &str, worktree_path: &str) -> String {
    format!(
        "git -C {} worktree remove {}",
        shell_quote(project_path),
        shell_quote(worktree_path)
    )
}

/// POSIX single-quote a string so it survives a shell verbatim. Everything
/// inside single quotes is literal, so the only case to handle is a `'` itself:
/// close the quote, emit an escaped quote, reopen (`'\''`).
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// Add a worktree at `path` on a new branch. Additive: git creates the directory
/// (and any missing parents) and the branch, and touches nothing that already
/// exists. `path` and `branch` are passed as separate bare arguments — no shell
/// is involved, so no quoting question arises.
///
/// `Err` carries git's own stderr, so the note we show says what actually failed.
fn worktree_add(project_path: &str, path: &Path, branch: &str) -> Result<(), String> {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(project_path)
        .arg("worktree")
        .arg("add")
        .arg(path)
        .arg("-b")
        .arg(branch)
        .output()
        .map_err(|e| format!("couldn't run git ({e})"))?;

    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    Err(if stderr.is_empty() {
        "it failed without explanation".to_string()
    } else {
        single_line(&stderr)
    })
}

/// Collapse whitespace runs (including newlines) to single spaces and trim, so
/// multi-line git output stays one readable sentence in a note.
fn single_line(raw: &str) -> String {
    raw.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Whether `branch` already exists locally.
fn branch_exists(project_path: &str, branch: &str) -> bool {
    git_status_ok(
        project_path,
        &[
            "rev-parse",
            "--verify",
            "--quiet",
            &format!("refs/heads/{branch}"),
        ],
    )
}

/// Whether git would accept `full_ref` as a ref name. Repository-independent, so
/// it runs without `-C`.
fn is_valid_ref(full_ref: &str) -> bool {
    std::process::Command::new("git")
        .args(["check-ref-format", full_ref])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Whether `project_path` is inside a git repository.
fn is_git_repo(project_path: &str) -> bool {
    git_status_ok(project_path, &["rev-parse", "--git-dir"])
}

/// Whether HEAD resolves — false in a fresh repo with no commits yet.
fn has_head(project_path: &str) -> bool {
    git_status_ok(project_path, &["rev-parse", "--verify", "--quiet", "HEAD"])
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
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// A throwaway git repo that cleans itself up. Hand-rolled to keep the core
    /// free of dev-dependencies (`tempfile` isn't in the workspace).
    struct TempRepo {
        path: PathBuf,
    }

    impl TempRepo {
        /// A repo with one commit containing `a.txt`, on branch `main`.
        fn new() -> Self {
            let repo = TempRepo::bare_dir();
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
                "stackpulse-wt-{}-{}",
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

        /// Where a client would keep worktrees: outside the repo, under the
        /// `StackPulse/worktrees` directory the `is_stackpulse` rule looks for.
        fn worktrees_dir(&self) -> String {
            format!("{}-wt/StackPulse/worktrees", self.str_path())
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

        /// Everything about the main tree that creating a worktree must not move.
        fn observable_state(&self) -> (String, String, String, String, String) {
            (
                self.git(&["status", "--porcelain"]),
                self.git(&["rev-parse", "HEAD"]),
                self.git(&["diff"]),             // unstaged changes
                self.git(&["diff", "--cached"]), // the index
                self.git(&["rev-parse", "--abbrev-ref", "HEAD"]), // still on our branch
            )
        }
    }

    impl Drop for TempRepo {
        fn drop(&mut self) {
            // Worktrees live in a sibling directory; take it with us.
            let _ = std::fs::remove_dir_all(format!("{}-wt", self.path.display()));
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

    // --- list -------------------------------------------------------------

    #[test]
    fn non_repo_returns_note_and_no_worktrees() {
        let dir = TempRepo::bare_dir();
        // Guard the premise: if temp_dir were inside a repo, this proves nothing.
        assert!(!is_in_git_repo(&dir.path));

        let (worktrees, note) = list(dir.str_path());
        assert!(worktrees.is_empty());
        assert!(note.unwrap().contains("isn't a git repository"));

        let (worktrees, note) = create(dir.str_path(), &dir.worktrees_dir(), "x");
        assert!(worktrees.is_empty());
        assert!(note.unwrap().contains("isn't a git repository"));
    }

    #[test]
    fn missing_path_degrades_instead_of_panicking() {
        let (worktrees, note) = list("/nonexistent/does/not/exist");
        assert!(worktrees.is_empty());
        assert!(note.is_some());

        let (worktrees, note) = create("/nonexistent/does/not/exist", "/tmp/nope", "x");
        assert!(worktrees.is_empty());
        assert!(note.is_some());
    }

    #[test]
    fn fresh_repo_lists_only_its_main_worktree() {
        let repo = TempRepo::new();
        let (worktrees, note) = list(repo.str_path());

        assert_eq!(note, None);
        assert_eq!(worktrees.len(), 1);
        let main = &worktrees[0];
        assert!(main.is_main);
        assert_eq!(main.branch.as_deref(), Some("main"));
        assert!(main.head.as_deref().is_some_and(|h| h.len() == 40));
        assert!(!main.is_locked);
        assert!(!main.is_stackpulse);
        // The one worktree that must never be removable.
        assert_eq!(main.remove_command, None);
    }

    #[test]
    fn repo_without_commits_is_explained() {
        let repo = TempRepo::bare_dir();
        repo.git(&["init", "-q", "-b", "main", "."]);

        let (worktrees, note) = create(repo.str_path(), &repo.worktrees_dir(), "x");
        assert!(worktrees.is_empty());
        assert!(note.unwrap().contains("no commits yet"));
    }

    // --- create -----------------------------------------------------------

    #[test]
    fn create_adds_a_worktree_on_its_own_branch() {
        let repo = TempRepo::new();
        let (worktrees, note) = create(repo.str_path(), &repo.worktrees_dir(), "agent run 1");

        assert_eq!(note, None, "a successful create has nothing to disclose");
        assert_eq!(worktrees.len(), 2);

        // Main is still main, and still not removable.
        assert!(worktrees[0].is_main);
        assert_eq!(worktrees[0].remove_command, None);

        let new = &worktrees[1];
        assert!(!new.is_main);
        assert_eq!(new.branch.as_deref(), Some("stackpulse/agent-run-1"));
        assert!(new.is_stackpulse, "path was {}", new.path);
        assert!(!new.is_locked);
        assert_eq!(new.head, worktrees[0].head, "branched from the same commit");
        assert_eq!(
            new.remove_command,
            Some(format!(
                "git -C '{}' worktree remove '{}'",
                repo.str_path(),
                new.path
            ))
        );
        // The directory really exists and holds a checkout of the repo.
        assert!(Path::new(&new.path).join("a.txt").exists());
        assert_eq!(
            std::fs::read_to_string(Path::new(&new.path).join("a.txt")).unwrap(),
            "committed\n"
        );
    }

    /// THE critical safety test: an additive create must leave the main working
    /// tree byte-identical, including work in progress. If this ever fails, the
    /// feature is actively dangerous rather than merely broken.
    #[test]
    fn create_leaves_the_main_working_tree_untouched() {
        let repo = TempRepo::new();
        repo.write("a.txt", "UNCOMMITTED EDIT\n");
        repo.write("staged.txt", "staged content\n");
        repo.git(&["add", "staged.txt"]);
        repo.write("untracked.txt", "untracked\n");

        let before_state = repo.observable_state();
        let before_a = repo.read("a.txt");
        let before_staged = repo.read("staged.txt");
        let before_untracked = repo.read("untracked.txt");

        let (worktrees, note) = create(repo.str_path(), &repo.worktrees_dir(), "isolated");
        assert_eq!(note, None);
        assert_eq!(worktrees.len(), 2, "the worktree was really created");

        // THE GUARANTEE: nothing the user was working on moved.
        assert_eq!(repo.read("a.txt"), before_a, "working file was modified");
        assert_eq!(repo.read("staged.txt"), before_staged);
        assert_eq!(repo.read("untracked.txt"), before_untracked);
        assert_eq!(
            repo.observable_state(),
            before_state,
            "status/HEAD/diff/index/branch must be byte-identical after create"
        );
        // Still on our own branch, with the edit still uncommitted.
        assert_eq!(repo.git(&["rev-parse", "--abbrev-ref", "HEAD"]), "main");
        assert!(repo.git(&["status", "--porcelain"]).contains("a.txt"));
    }

    #[test]
    fn duplicate_name_is_refused_without_clobbering() {
        let repo = TempRepo::new();
        let (first, _) = create(repo.str_path(), &repo.worktrees_dir(), "dup");
        assert_eq!(first.len(), 2);
        let created_path = first[1].path.clone();
        // Something the agent produced in there; a re-run must not lose it.
        std::fs::write(Path::new(&created_path).join("work.txt"), "agent output\n")
            .expect("write in worktree");

        let (second, note) = create(repo.str_path(), &repo.worktrees_dir(), "dup");

        let note = note.expect("a name collision must be disclosed");
        assert!(note.contains("already exists"), "note was: {note}");
        assert_eq!(second.len(), 2, "no second worktree was created");
        assert_eq!(
            std::fs::read_to_string(Path::new(&created_path).join("work.txt")).unwrap(),
            "agent output\n",
            "existing work must survive a refused create"
        );
    }

    /// The path is free but the branch is taken — the user's own branch must not
    /// be adopted, moved, or checked out.
    #[test]
    fn existing_branch_is_refused_without_clobbering() {
        let repo = TempRepo::new();
        repo.git(&["branch", "stackpulse/taken"]);
        let before = repo.git(&["rev-parse", "stackpulse/taken"]);

        let (worktrees, note) = create(repo.str_path(), &repo.worktrees_dir(), "taken");

        let note = note.expect("a branch collision must be disclosed");
        assert!(note.contains("already exists"), "note was: {note}");
        assert_eq!(worktrees.len(), 1, "only the main worktree exists");
        assert_eq!(repo.git(&["rev-parse", "stackpulse/taken"]), before);
        assert_eq!(repo.git(&["rev-parse", "--abbrev-ref", "HEAD"]), "main");
    }

    #[test]
    fn relative_worktrees_dir_is_refused() {
        let repo = TempRepo::new();
        // Would otherwise resolve inside the repository we're protecting.
        let (worktrees, note) = create(repo.str_path(), "relative/dir", "x");
        assert!(worktrees.is_empty());
        assert!(note.unwrap().contains("absolute path"));
        assert_eq!(list(repo.str_path()).0.len(), 1, "nothing was created");
    }

    #[test]
    fn unusable_name_is_refused() {
        let repo = TempRepo::new();
        for name in ["", "   ", "///", "..", "..."] {
            let (worktrees, note) = create(repo.str_path(), &repo.worktrees_dir(), name);
            assert!(worktrees.is_empty(), "name {name:?} must create nothing");
            assert!(
                note.unwrap().contains("usable characters"),
                "name {name:?} deserves an honest note"
            );
        }
        assert_eq!(list(repo.str_path()).0.len(), 1, "nothing was created");
    }

    /// A hostile name must land inside the worktrees directory as one component,
    /// and on a branch under our namespace — not `../` out of either.
    #[test]
    fn hostile_names_cannot_escape_the_worktrees_directory() {
        let repo = TempRepo::new();
        let dir = repo.worktrees_dir();

        for name in [
            "../evil",
            "-x",
            "a/../../b",
            "$(rm -rf /)",
            "..;/etc/passwd",
        ] {
            let (worktrees, note) = create(repo.str_path(), &dir, name);
            assert_eq!(note, None, "name {name:?} should still work: {note:?}");
            let new = worktrees.last().expect("a worktree was created");

            // Landed directly in the worktrees directory: one component, no
            // traversal, and the parent is exactly where we asked for it.
            // Compare canonicalized: git reports the resolved path, and on macOS
            // the temp dir reaches us through the /var -> /private/var symlink.
            let created = Path::new(&new.path);
            let parent = created.parent().expect("a created path has a parent");
            assert_eq!(
                std::fs::canonicalize(parent).ok(),
                std::fs::canonicalize(&dir).ok(),
                "name {name:?} escaped to {}",
                new.path
            );
            assert!(!new.path.contains(".."), "name {name:?} kept a traversal");

            let branch = new.branch.as_deref().expect("a named branch");
            assert!(
                branch.starts_with("stackpulse/"),
                "name {name:?} escaped the branch namespace: {branch}"
            );
            // git is the authority on what it will accept as a ref.
            assert!(is_valid_ref(&format!("refs/heads/{branch}")));

            // Clean up between iterations without the module ever removing
            // anything: the test owns these throwaway directories.
            repo.git(&["worktree", "remove", "--force", &new.path]);
            repo.git(&["branch", "-D", branch]);
        }
    }

    // --- pure helpers -----------------------------------------------------

    #[test]
    fn sanitize_name_reduces_to_one_safe_component() {
        assert_eq!(sanitize_name("agent run 1").as_deref(), Some("agent-run-1"));
        assert_eq!(
            sanitize_name("My_Feature.2").as_deref(),
            Some("my_feature.2")
        );
        // Traversal, separators, and flags are all disarmed.
        assert_eq!(sanitize_name("../evil").as_deref(), Some("evil"));
        assert_eq!(sanitize_name("-x").as_deref(), Some("x"));
        assert_eq!(sanitize_name("a/../b").as_deref(), Some("a-.-b"));
        assert_eq!(sanitize_name("feat/x").as_deref(), Some("feat-x"));
        // git-reserved shapes. Only a `.lock` *suffix* is reserved, so ".lock"
        // legitimately becomes the ordinary branch name "lock".
        assert_eq!(sanitize_name("wip.lock").as_deref(), Some("wip"));
        assert_eq!(sanitize_name("a.lock.lock").as_deref(), Some("a"));
        assert_eq!(sanitize_name(".lock").as_deref(), Some("lock"));
        assert_eq!(sanitize_name("a@{0}").as_deref(), Some("a-0"));
        assert_eq!(sanitize_name("x..y").as_deref(), Some("x.y"));
        // Nothing usable at all.
        assert_eq!(sanitize_name(""), None);
        assert_eq!(sanitize_name("   "), None);
        assert_eq!(sanitize_name("..."), None);
        assert_eq!(sanitize_name("---"), None);
    }

    /// Whatever goes in, what comes out is a legal ref component and a single
    /// path component — checked against git itself, not just our own rules.
    #[test]
    fn sanitize_name_output_is_always_a_legal_ref_and_component() {
        for raw in [
            "../../etc/passwd",
            "-rf",
            "a b\tc\nd",
            "héllo wörld",
            "🚀 rocket",
            "CAPS",
            "..",
            "@",
            "refs/heads/main",
            "x".repeat(200).as_str(),
            "a.lock.lock",
            "~^:?*[\\",
        ] {
            let Some(safe) = sanitize_name(raw) else {
                continue; // Refusing outright is always a safe answer.
            };
            assert!(
                safe.chars().all(|c| c.is_ascii_lowercase()
                    || c.is_ascii_digit()
                    || matches!(c, '.' | '_' | '-')),
                "{raw:?} -> {safe:?} kept an unexpected character"
            );
            assert!(!safe.contains(".."), "{raw:?} -> {safe:?} kept a traversal");
            assert!(
                !safe.starts_with('-'),
                "{raw:?} -> {safe:?} looks like a flag"
            );
            assert!(
                !safe.starts_with('.'),
                "{raw:?} -> {safe:?} is hidden/illegal"
            );
            assert!(
                safe.len() <= MAX_NAME_LEN,
                "{raw:?} -> {safe:?} is too long"
            );
            assert_eq!(
                Path::new(&safe).components().count(),
                1,
                "{raw:?} -> {safe:?} is not a single path component"
            );
            assert!(
                is_valid_ref(&format!("refs/heads/{BRANCH_PREFIX}/{safe}")),
                "{raw:?} -> {safe:?} is not a ref git accepts"
            );
        }
    }

    #[test]
    fn parse_porcelain_reads_main_detached_and_locked_records() {
        let stdout = "\
worktree /repo
HEAD 1111111111111111111111111111111111111111
branch refs/heads/main

worktree /StackPulse/worktrees/repo-agent
HEAD 2222222222222222222222222222222222222222
branch refs/heads/stackpulse/agent

worktree /elsewhere/detached
HEAD 3333333333333333333333333333333333333333
detached
locked under review
";
        let out = parse_porcelain("/repo", stdout);
        assert_eq!(out.len(), 3);

        // First record is the primary working tree, and it is never removable.
        assert!(out[0].is_main);
        assert_eq!(out[0].branch.as_deref(), Some("main"));
        assert_eq!(out[0].remove_command, None);
        assert!(!out[0].is_stackpulse);

        assert!(!out[1].is_main);
        assert_eq!(out[1].branch.as_deref(), Some("stackpulse/agent"));
        assert!(out[1].is_stackpulse, "lives under the StackPulse directory");
        assert_eq!(
            out[1].remove_command.as_deref(),
            Some("git -C '/repo' worktree remove '/StackPulse/worktrees/repo-agent'")
        );

        // Detached means no branch — never invent one.
        assert_eq!(out[2].branch, None);
        assert!(out[2].is_locked);
        assert!(!out[2].is_stackpulse);
        assert!(out[2].remove_command.is_some());
    }

    #[test]
    fn parse_porcelain_handles_bare_and_empty_output() {
        assert!(parse_porcelain("/repo", "").is_empty());
        // A bare main worktree has no HEAD or branch line.
        let out = parse_porcelain("/repo", "worktree /repo/.bare\nbare\n");
        assert_eq!(out.len(), 1);
        assert!(out[0].is_main);
        assert_eq!(out[0].branch, None);
        assert_eq!(out[0].head, None);
        assert_eq!(out[0].remove_command, None);
    }

    #[test]
    fn remove_command_is_reported_but_never_run() {
        let repo = TempRepo::new();
        let (worktrees, _) = create(repo.str_path(), &repo.worktrees_dir(), "reported");
        let new = &worktrees[1];

        let command = new
            .remove_command
            .as_deref()
            .expect("reported for non-main");
        assert!(command.contains("worktree remove"));
        // Reporting it must not have removed anything.
        assert!(Path::new(&new.path).exists(), "reporting removed the tree");
        assert_eq!(list(repo.str_path()).0.len(), 2);
    }

    #[test]
    fn shell_quote_escapes_single_quotes() {
        assert_eq!(shell_quote("/tmp/plain"), "'/tmp/plain'");
        assert_eq!(shell_quote("/tmp/it's here"), r"'/tmp/it'\''s here'");
        // A path with a space stays one shell word.
        assert_eq!(shell_quote("/App Privadas/x"), "'/App Privadas/x'");
    }

    #[test]
    fn short_branch_strips_only_the_heads_prefix() {
        assert_eq!(short_branch("refs/heads/main"), "main");
        assert_eq!(short_branch("refs/heads/feat/x"), "feat/x");
        assert_eq!(
            short_branch("refs/remotes/origin/main"),
            "refs/remotes/origin/main"
        );
    }
}
