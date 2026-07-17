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

    /// Whether StackPulse **knows** this dependency needs attention — the rule that
    /// decides both whether the prompt may be offered and what may go in it.
    ///
    /// It lives here, next to the prompt, because it is a statement about what we
    /// are entitled to ask: everything else is a view detail. The distinction that
    /// matters is `unknown` vs. the rest. The offline core reports **every**
    /// dependency as `unknown`, so before a registry check the whole manifest looks
    /// "not up to date" — and a gate that only excluded `up_to_date` would offer to
    /// describe what's outdated while knowing nothing was.
    ///
    /// Takes the raw wire value, not an interpreted case, so a status a newer core
    /// invents is treated as unknown — never as a finding — until someone teaches
    /// this function what it means.
    static func isKnownOutdated(statusRaw: String, advisoryCount: Int) -> Bool {
        // An advisory is knowledge of a problem no matter what the version says,
        // including when `latest` never resolved.
        if advisoryCount > 0 { return true }
        switch statusRaw {
        case "minor_behind", "major_behind", "deprecated": return true
        // `up_to_date` has nothing to ask. `unknown` — and anything unrecognized —
        // is the absence of an answer, which is not the same as a finding.
        default: return false
        }
    }

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
        /// When the registry/OSV check ran.
        ///
        /// **Not optional, by construction.** A prompt can only be built once
        /// StackPulse knows something is outdated, and it can only know that from
        /// enrichment — the offline core reports every dependency as `unknown`. So
        /// there is always a real reading behind this, and no "we never checked"
        /// state to describe.
        let checkedAt: Date
        /// Dependencies the check could not resolve — the registry didn't answer
        /// for them. They are absent from `facts`, and their absence is stated:
        /// a package missing from this table is **not** a package known to be fine.
        let unresolvedCount: Int
    }

    /// Build the prompt. Pure: every input is passed in, including `now`, so the
    /// output is reproducible and testable.
    ///
    /// `facts` must be only what StackPulse actually knows to be outdated or
    /// vulnerable. Two things it must never contain: an up-to-date dependency
    /// (nothing to ask), and one whose status is unknown (asking an AI to advise
    /// on an upgrade StackPulse never established is needed is how a review turns
    /// into invented work — `unresolvedCount` carries those instead).
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
        out.append(
            "- `latest` and the advisories were read from the package registry and OSV "
                + "**\(age(from: project.checkedAt, to: now))** (\(stamp(project.checkedAt)))."
        )
        if project.unresolvedCount > 0 {
            let n = project.unresolvedCount
            out.append(
                "- **\(n) other dependenc\(n == 1 ? "y is" : "ies are") missing from this table**: "
                    + "the registry did not answer for \(n == 1 ? "it" : "them"), so whether "
                    + "\(n == 1 ? "it is" : "they are") current is unknown. "
                    + "Not listed ≠ known to be fine."
            )
        }
        out.append("")
        out.append(
            "> Those readings may already be stale, and registries move daily. "
                + "**Treat every version and advisory id below as a claim to verify, not a fact to repeat.** "
                + "If you can look them up, do; if you cannot, say which ones you could not confirm."
        )
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
