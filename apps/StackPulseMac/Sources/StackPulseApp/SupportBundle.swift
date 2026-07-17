import Foundation

/// A copy-paste support bundle: the diagnostics report as text you can paste into
/// an issue or a message, with a hard guarantee about what it does **not** contain.
///
/// The spec's rule is unambiguous: the bundle "must not contain prompts, source
/// code, credentials, raw tokens, or full session logs." This type is built so
/// that holds by construction, not by remembering to be careful:
///
/// - it is assembled **only** from a `Diagnostics.Report`, which itself carries no
///   secret — the report's details are human sentences the app already shows;
/// - `redact(_:)` collapses the home directory to `~` wherever a path slips into a
///   free-text detail, so a username never ships;
/// - there is no field through which a token, a prompt, or a log line could enter,
///   because none is passed in.
///
/// If a future field could carry sensitive text, it must be redacted here — this
/// is the one place the guarantee lives.
enum SupportBundle {

    /// Build the bundle text. Pure: `home` and `now` are passed in so the same
    /// report always renders the same bundle (and tests can pin redaction).
    static func build(report: Diagnostics.Report, home: String, now: Date) -> String {
        var out: [String] = []
        out.append("StackPulse diagnostics")
        out.append("generated: \(iso(now))")
        out.append("overall: \(report.worstStatus.token)")
        out.append("")
        out.append("This bundle contains versions, status tokens, and short status")
        out.append("messages only. It contains no credentials, tokens, prompts,")
        out.append("source code, or session-log contents. Paths are redacted to ~.")
        out.append("")

        if !report.issues.isEmpty {
            out.append("== Issues ==")
            for c in report.issues {
                out.append("[\(c.status.token)] \(c.label): \(redact(c.detail, home: home))")
                if let r = c.repair {
                    out.append("       fix: \(redact(r, home: home))")
                }
            }
            out.append("")
        }

        for g in report.groups {
            out.append("== \(g.title) ==")
            for c in g.checks {
                out.append("[\(c.status.token)] \(c.label): \(redact(c.detail, home: home))")
            }
            out.append("")
        }

        return out.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    /// Replace the user's home directory with `~` anywhere it appears. The details
    /// this runs over are meant to be path-free already; this is the belt to that
    /// suspenders, so a stray absolute path can never carry a username out.
    static func redact(_ text: String, home: String) -> String {
        guard !home.isEmpty else { return text }
        // Normalize a trailing slash so `/Users/j` and `/Users/j/` both collapse.
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        return text.replacingOccurrences(of: trimmed, with: "~")
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
