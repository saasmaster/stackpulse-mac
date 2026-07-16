//! Scope Guard — a read-only heads-up about *what kind* of change a running AI
//! session is making.
//!
//! Given the relative paths a mission changed (already gathered from `git status`
//! for the Mission's `changed_files`), classify them into risk categories:
//! touched secrets/env, database migrations, dependency manifests, lockfiles,
//! security-sensitive code, tests, and build/CI config. Purely path-pattern based
//! (no diff content, no file reads) so it's deterministic, cheap, and honest — it
//! reports "these files were touched", never "a dependency was added".
//!
//! Nothing here mutates anything: it surfaces categories so the user can glance
//! at an autonomous session and notice "this touched .env and a migration".

use stackpulse_protocol::{ScopeFlag, ScopeFlagKind, ScopeSeverity};

/// Max files listed per flag (keeps the payload small).
///
/// `files` is a **sample**, never a total — nothing downstream may present it as
/// one. The true total rides along in `ScopeFlag::match_count` (protocol 1.17.0);
/// before that field existed a 40-match flag was indistinguishable on the wire
/// from an 8-match one, and the UI duly rendered "Security / auth code · 8".
const FILES_PER_FLAG_CAP: usize = 8;

/// Classify changed paths into scope-guard flags, ordered most-severe first.
pub fn flags_for(changed_files: &[String]) -> Vec<ScopeFlag> {
    // Category → matched files, preserving first-seen order via a Vec of buckets.
    let mut buckets: Vec<(ScopeFlagKind, Vec<String>)> = Vec::new();
    for path in changed_files {
        if let Some(kind) = classify(path) {
            match buckets.iter_mut().find(|(k, _)| *k == kind) {
                Some((_, files)) => files.push(path.clone()),
                None => buckets.push((kind, vec![path.clone()])),
            }
        }
    }

    let mut flags: Vec<ScopeFlag> = buckets
        .into_iter()
        .map(|(kind, mut files)| {
            // Count before truncating — after the cap the total is unrecoverable,
            // which is exactly how the UI came to render the sample as the total.
            let match_count = files.len();
            files.truncate(FILES_PER_FLAG_CAP);
            ScopeFlag {
                kind,
                severity: severity(kind),
                label: label(kind).to_string(),
                files,
                match_count,
            }
        })
        .collect();

    // Highest severity first; stable within a severity (declaration order).
    flags.sort_by_key(|f| std::cmp::Reverse(rank(f.severity)));
    flags
}

/// Classify a single path into at most one category (first match wins, most
/// specific first). Case-insensitive on the basename.
fn classify(path: &str) -> Option<ScopeFlagKind> {
    let lower = path.to_lowercase();
    let base = lower.rsplit('/').next().unwrap_or(&lower);
    let has_segment = |name: &str| lower.split('/').any(|s| s == name);

    // Secrets / env — most sensitive, check first.
    if base.starts_with(".env")
        || base.ends_with(".pem")
        || base.ends_with(".key")
        || base == "credentials"
        || base.contains("secret")
    {
        return Some(ScopeFlagKind::Secrets);
    }

    // Database migrations / raw SQL.
    if has_segment("migrations")
        || has_segment("migrate")
        || base.ends_with(".sql")
        || base.contains("migration")
    {
        return Some(ScopeFlagKind::Migrations);
    }

    // Lockfiles (before dependency manifests so a lockfile isn't mislabeled).
    if matches!(
        base,
        "package-lock.json"
            | "pnpm-lock.yaml"
            | "yarn.lock"
            | "bun.lockb"
            | "cargo.lock"
            | "poetry.lock"
            | "go.sum"
            | "composer.lock"
            | "gemfile.lock"
    ) {
        return Some(ScopeFlagKind::Lockfile);
    }

    // Dependency manifests.
    if matches!(
        base,
        "package.json"
            | "cargo.toml"
            | "pyproject.toml"
            | "requirements.txt"
            | "go.mod"
            | "gemfile"
            | "composer.json"
            | "pubspec.yaml"
            | "build.gradle"
            | "pom.xml"
    ) {
        return Some(ScopeFlagKind::Dependencies);
    }

    // Tests.
    if lower.contains("__tests__")
        || has_segment("tests")
        || has_segment("test")
        || base.contains(".test.")
        || base.contains(".spec.")
        || base.starts_with("test_")
        || base.ends_with("_test.go")
        || base.ends_with("_test.py")
    {
        return Some(ScopeFlagKind::Tests);
    }

    // Security / auth-sensitive code.
    if [
        "auth",
        "rbac",
        "permission",
        "middleware",
        "security",
        "session",
        "login",
        "password",
    ]
    .iter()
    .any(|kw| lower.contains(kw))
    {
        return Some(ScopeFlagKind::Security);
    }

    // CI / build / tooling config.
    if lower.contains(".github/workflows")
        || base == "dockerfile"
        || base.starts_with("docker-compose")
        || base.starts_with("tsconfig")
        || base.starts_with("next.config")
        || base.starts_with("vite.config")
        || base.starts_with("webpack.config")
        || base == ".gitlab-ci.yml"
        || base == "makefile"
    {
        return Some(ScopeFlagKind::BuildConfig);
    }

    None
}

fn severity(kind: ScopeFlagKind) -> ScopeSeverity {
    match kind {
        ScopeFlagKind::Secrets | ScopeFlagKind::Migrations | ScopeFlagKind::Security => {
            ScopeSeverity::High
        }
        ScopeFlagKind::Dependencies | ScopeFlagKind::Lockfile | ScopeFlagKind::BuildConfig => {
            ScopeSeverity::Notable
        }
        ScopeFlagKind::Tests | ScopeFlagKind::Other => ScopeSeverity::Info,
    }
}

fn rank(s: ScopeSeverity) -> u8 {
    match s {
        ScopeSeverity::High => 2,
        ScopeSeverity::Notable => 1,
        ScopeSeverity::Info => 0,
    }
}

fn label(kind: ScopeFlagKind) -> &'static str {
    match kind {
        ScopeFlagKind::Secrets => "Secrets / env files",
        ScopeFlagKind::Migrations => "Database migrations",
        ScopeFlagKind::Security => "Security / auth code",
        ScopeFlagKind::Dependencies => "Dependencies",
        ScopeFlagKind::Lockfile => "Lockfile",
        ScopeFlagKind::BuildConfig => "Build / CI config",
        ScopeFlagKind::Tests => "Tests",
        ScopeFlagKind::Other => "Other",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secrets_and_migrations_rank_high_and_first() {
        let files = vec![
            "src/app.ts".to_string(),
            ".env.local".to_string(),
            "db/migrations/001_init.sql".to_string(),
        ];
        let flags = flags_for(&files);
        assert_eq!(flags.len(), 2);
        // Both high severity; secrets or migrations lead (app.ts is unclassified).
        assert!(flags.iter().all(|f| f.severity == ScopeSeverity::High));
        assert!(flags.iter().any(|f| f.kind == ScopeFlagKind::Secrets));
        assert!(flags.iter().any(|f| f.kind == ScopeFlagKind::Migrations));
    }

    #[test]
    fn deps_and_lockfile_are_distinct() {
        let files = vec!["package.json".to_string(), "package-lock.json".to_string()];
        let flags = flags_for(&files);
        assert!(flags.iter().any(|f| f.kind == ScopeFlagKind::Dependencies));
        assert!(flags.iter().any(|f| f.kind == ScopeFlagKind::Lockfile));
    }

    #[test]
    fn tests_and_security_classified() {
        assert_eq!(classify("src/auth/login.ts"), Some(ScopeFlagKind::Security));
        assert_eq!(classify("src/foo.test.ts"), Some(ScopeFlagKind::Tests));
        assert_eq!(classify("__tests__/x.js"), Some(ScopeFlagKind::Tests));
    }

    #[test]
    fn plain_source_is_unflagged() {
        assert_eq!(classify("src/components/Button.tsx"), None);
        assert!(flags_for(&["src/components/Button.tsx".to_string()]).is_empty());
    }

    #[test]
    fn severity_ordering_high_before_info() {
        let files = vec!["a.test.ts".to_string(), ".env".to_string()];
        let flags = flags_for(&files);
        assert_eq!(flags.first().unwrap().severity, ScopeSeverity::High);
        assert_eq!(flags.last().unwrap().severity, ScopeSeverity::Info);
    }

    /// The list is a sample and the count is the truth: 20 matches must report 20
    /// while listing 8. The UI used to count the sample, so a session touching 40
    /// auth files announced 8 — a scope guard under-reporting scope.
    #[test]
    fn files_are_capped_but_the_true_count_survives() {
        let files: Vec<String> = (0..20).map(|i| format!("tests/t{i}.spec.ts")).collect();
        let flags = flags_for(&files);
        assert_eq!(flags.len(), 1);
        assert_eq!(flags[0].files.len(), FILES_PER_FLAG_CAP);
        assert_eq!(flags[0].match_count, 20);
        assert_eq!(flags[0].label, "Tests");
    }

    /// Under the cap, the count is just the length — no double-counting, and no
    /// pretending a 3-file flag is bigger than it is.
    #[test]
    fn match_count_equals_files_when_under_the_cap() {
        let files: Vec<String> = (0..3).map(|i| format!("tests/t{i}.spec.ts")).collect();
        let flags = flags_for(&files);
        assert_eq!(flags[0].match_count, 3);
        assert_eq!(flags[0].files.len(), 3);
    }
}
