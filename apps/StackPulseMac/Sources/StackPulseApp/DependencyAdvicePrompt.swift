import Foundation

/// Builds a copy-paste prompt that asks an AI to advise on outdated dependencies.
///
/// StackPulse can say what is installed, what the registry reported, and which OSV
/// advisories matched. It cannot say whether an upgrade is *worth doing* — that
/// needs judgement about the code, and StackPulse never reads the code. So instead
/// of guessing, it hands the facts to something that can reason about them.
///
/// The prompt is built to resist the two ways this goes wrong:
///
/// 1. **The AI trusts our numbers.** Registry data ages, and a model asked "is
///    lodash 4.17.20 vulnerable?" will happily answer from memory. Every reading
///    below is therefore stamped with when it was taken and framed as a *claim to
///    verify*, not a fact to repeat.
/// 2. **The AI assumes what it can't see.** StackPulse reads manifests and
///    lockfiles — not source. It does not know whether a package is even imported,
///    let alone whether a vulnerable path is reachable. The prompt says so plainly
///    and asks for "unverified" over a confident guess.
///
/// `is_dev` is carried deliberately: a build-time-only package's advisory usually
/// does not reach production, and that single fact decides "required" more often
/// than severity does.
enum DependencyAdvicePrompt {

    /// One dependency, flattened to the facts a reviewer needs. Mirrors what the
    /// row already displays — the prompt must never claim more than the UI does.
    struct Fact {
        let name: String
        let ecosystem: String
        let isDev: Bool
        /// The range in the manifest (e.g. `^4.17.0`).
        let required: String?
        /// The resolved version from the lockfile.
        let installed: String?
        /// What the registry reported, or `nil` when no check has run.
        let latest: String?
        /// A human label: up to date / minor behind / major behind / deprecated /
        /// unknown. Deliberately the *interpreted* label, so the prompt and the
        /// screen cannot disagree.
        let status: String
        let advisories: [Advisory]

        struct Advisory {
            let id: String
            let severity: String
            let url: String?
        }
    }

    struct Project {
        let name: String
        let path: String
        let ecosystem: String
        let packageManager: String?
        /// When the registry/OSV check ran. `nil` = it never did, and the prompt
        /// says so rather than presenting unchecked rows as current.
        let checkedAt: Date?
    }

    /// Build the prompt. Pure: every input is passed in, including `now`, so the
    /// output is reproducible and testable.
    ///
    /// `facts` is expected to be pre-filtered to what the user wants advice on —
    /// an up-to-date dependency with no advisory has nothing to ask about, and
    /// padding the prompt with hundreds of clean rows buries the few that matter.
    static func build(project: Project, facts: [Fact], now: Date = Date()) -> String {
        var out: [String] = []

        out.append("# Dependency upgrade review — \(project.name)")
        out.append("")
        out.append(
            "Advise me on the dependencies below. For each one answer three questions: "
                + "is the problem **real**, is fixing it **required**, and is upgrading **safe**. "
                + "Do not answer any of them from memory alone."
        )
        out.append("")

        // MARK: Provenance

        out.append("## Where this came from")
        out.append("")
        out.append("- Project: `\(project.path)`")
        out.append(
            "- Ecosystem: \(project.ecosystem)"
                + (project.packageManager.map { " (\($0))" } ?? "")
        )
        out.append("- `required` = the range in the manifest. `installed` = the resolved version in the lockfile.")
        if let checkedAt = project.checkedAt {
            out.append(
                "- `latest` and the advisories were read from the package registry and OSV "
                    + "**\(age(from: checkedAt, to: now))** (\(stamp(checkedAt)))."
            )
            out.append("")
            out.append(
                "> Those readings may already be stale, and registries move daily. "
                    + "**Treat every version and advisory id below as a claim to verify, not a fact to repeat.** "
                    + "If you can look them up, do; if you cannot, say which ones you could not confirm."
            )
        } else {
            out.append(
                "- **No update check has run**, so `latest` is unknown and no advisories were "
                    + "looked up. The installed versions are real; everything about what is "
                    + "current or vulnerable is for you to find out. Do not assume a package "
                    + "is fine because no advisory is listed — none were fetched."
            )
        }
        out.append("")

        // MARK: The boundary

        out.append("## What this data does NOT tell you")
        out.append("")
        out.append("This came from manifests and lockfiles. **Nothing here read the source code.** So it does not know:")
        out.append("")
        out.append("- whether a package is actually imported, or is a leftover;")
        out.append("- which APIs of it are used, and whether an upgrade's breaking changes touch them;")
        out.append("- whether a vulnerable code path is reachable, or reachable with attacker-controlled input;")
        out.append("- what this application does, who can reach it, or what data it holds.")
        out.append("")
        out.append(
            "Where one of those decides the answer, **say what you'd need to check** "
                + "(and where to look) instead of assuming it."
        )
        out.append("")

        // MARK: The table

        out.append("## The dependencies")
        out.append("")
        out.append("| package | scope | required | installed | latest | status | advisories |")
        out.append("| --- | --- | --- | --- | --- | --- | --- |")
        for f in facts {
            let adv = f.advisories.isEmpty
                ? "—"
                : f.advisories.map { a in
                    let sev = a.severity.isEmpty || a.severity == "unknown" ? "" : " (\(a.severity))"
                    return a.url.map { "[\(a.id)](\($0))\(sev)" } ?? "\(a.id)\(sev)"
                }.joined(separator: ", ")
            out.append(
                "| `\(f.name)` | \(f.isDev ? "dev" : "runtime") | \(cell(f.required)) | "
                    + "\(cell(f.installed)) | \(cell(f.latest)) | \(f.status) | \(adv) |"
            )
        }
        out.append("")
        out.append("`scope: dev` = build/test only, not shipped to production. `—` = not known.")
        out.append("")

        // MARK: The ask

        out.append("## What I need, per package")
        out.append("")
        out.append("**1. Is it real?**")
        out.append(
            "Does the advisory actually apply to this version, and to this `scope`? "
                + "Advisories get filed against a package broadly and often affect one function, "
                + "one config, or one platform. A dev-only package's advisory usually does not "
                + "reach production — say so when that's the case. If \"major behind\" is just a "
                + "version-number jump with no real consequence, say that too."
        )
        out.append("")
        out.append("**2. Is it required?**")
        out.append("Put each package in exactly one bucket, and give the one-line reason:")
        out.append("")
        out.append("- **Must fix** — a real, reachable security problem, or it's already broken.")
        out.append("- **Should fix** — no emergency, but the cost of waiting is rising (EOL, drift, a stack of breaking changes accumulating).")
        out.append("- **Optional** — a genuine improvement, no pressure.")
        out.append("- **Leave it** — upgrading costs more than it returns. This is a real answer; use it.")
        out.append("")
        out.append("**3. Is it safe?**")
        out.append(
            "What actually breaks between installed and latest? Name the specific breaking "
                + "changes, migrations, and peer-dependency conflicts — not \"it's a major bump, "
                + "so read the changelog\". If the safe move is an intermediate version rather "
                + "than latest, say which. Give me the exact command to run."
        )
        out.append("")

        // MARK: Rules

        out.append("## Rules")
        out.append("")
        out.append(
            "- **Never invent a version, a CVE, a date, or a breaking change.** "
                + "If you are not sure, write \"unverified\" and say what you'd check. "
                + "An honest gap is useful; a confident wrong answer costs me a debugging session."
        )
        out.append("- Don't recommend upgrading everything. Rank by real risk, and say what to skip.")
        out.append("- If two of these must move together (peer deps, a framework and its plugins), group them.")
        out.append("- If something here looks wrong or contradictory, say so — the scan may be wrong.")
        out.append("")
        out.append("Start with the packages that matter. If nothing here is urgent, open by saying that plainly.")

        return out.joined(separator: "\n")
    }

    // MARK: Helpers

    private static func cell(_ v: String?) -> String {
        guard let v, !v.isEmpty else { return "—" }
        return "`\(v)`"
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// Coarse age, phrased the way a reader thinks about staleness.
    private static func age(from: Date, to: Date) -> String {
        let s = max(0, to.timeIntervalSince(from))
        if s < 90 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) minutes ago" }
        if s < 86_400 {
            let h = Int(s / 3600)
            return "\(h) hour\(h == 1 ? "" : "s") ago"
        }
        let d = Int(s / 86_400)
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }
}
