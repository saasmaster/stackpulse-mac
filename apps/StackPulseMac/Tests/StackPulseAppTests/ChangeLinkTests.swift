import Foundation
import Testing
@testable import StackPulseApp

/// Resolving a package to its real release notes (Phase 4 "breaking-change
/// analysis").
///
/// The one rule that matters: every link must be grounded in what the REGISTRY
/// said. `github.com/<package-name>` is a fabrication — plausible, often even
/// right, and exactly the kind of confident guess this project keeps having to
/// undo. No data ⇒ no link.
@Suite("Change links")
struct ChangeLinkTests {
    func enrichment(repo: String? = nil, home: String? = nil) -> StackHealthClient.DependencyEnrichment {
        StackHealthClient.DependencyEnrichment(
            latest: "19.2.7", status: "major_behind", advisories: [],
            repositoryURL: StackHealthClient.normalizeRepositoryURL(repo),
            homepageURL: home
        )
    }

    /// THE rule. A registry that names no repository and no homepage gets no link.
    @Test("no registry data ⇒ no link, never a guess from the package name")
    func noDataNoLink() {
        #expect(StackHealthClient.changeLink(for: enrichment()) == nil)
    }

    /// npm records the VCS as a URL prefix and often a `.git` suffix.
    @Test("npm's git+https repository URL resolves to that repo's releases")
    func npmGitPlusHTTPS() {
        let link = StackHealthClient.changeLink(
            for: enrichment(repo: "git+https://github.com/facebook/react.git"))
        #expect(link?.kind == .githubReleases)
        #expect(link?.url == "https://github.com/facebook/react/releases")
    }

    /// A monorepo's `repository` points deep inside the tree; the repo is still the
    /// first two segments.
    @Test("a monorepo subpath still resolves to its repository")
    func monorepoSubpath() {
        let link = StackHealthClient.changeLink(
            for: enrichment(repo: "https://github.com/vercel/next.js/tree/canary/packages/next"))
        #expect(link?.url == "https://github.com/vercel/next.js/releases")
    }

    /// scp-style has no scheme to parse.
    @Test("scp-style git remotes resolve")
    func scpStyle() {
        #expect(StackHealthClient.githubSlug("git@github.com:sindresorhus/got.git") == "sindresorhus/got")
    }

    /// npm allows `"repository": "owner/repo"`.
    @Test("npm shorthand resolves")
    func shorthand() {
        #expect(StackHealthClient.githubSlug("facebook/react") == "facebook/react")
    }

    /// `"homepage": "https://github.com/foo/bar#readme"` is an npm norm — the
    /// homepage IS the repo.
    @Test("a homepage that is the repo is used as the repo")
    func homepageIsRepo() {
        let link = StackHealthClient.changeLink(
            for: enrichment(home: "https://github.com/foo/bar#readme"))
        #expect(link?.kind == .githubReleases)
        #expect(link?.url == "https://github.com/foo/bar/releases")
    }

    /// A non-GitHub host: we don't know whether or where it publishes releases, so
    /// the link promises only the repository — no invented `/releases` path.
    @Test("a non-GitHub repo links to the repo, not an invented releases path")
    func nonGitHub() {
        let link = StackHealthClient.changeLink(
            for: enrichment(repo: "https://gitlab.com/team/thing.git"))
        #expect(link?.kind == .repository)
        #expect(!(link?.url.contains("/releases") ?? true))
    }

    /// Garbage in the registry field must not become a link.
    @Test("unparseable repository metadata yields no link")
    func garbage() {
        for junk in ["", "   ", "not a url", "://", "https://"] {
            #expect(StackHealthClient.normalizeRepositoryURL(junk) == nil, "\(junk) must not parse")
        }
    }
}
