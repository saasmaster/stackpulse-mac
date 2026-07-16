import AppKit

/// Runs discovered commands **visibly and never silently**.
///
/// Safety model (enforced by the call sites in ``ProjectsSection``): "Copy" only
/// places text on the pasteboard; "Run in Terminal" opens Terminal.app at the
/// command's working directory and types the command there, so the user always
/// sees exactly what runs and can stop it. Nothing is ever executed in-process,
/// and non-read-only commands are gated behind a confirmation dialog upstream.
///
/// Called from the main actor, but never *blocks* it: driving Terminal over
/// AppleScript is slow (measured >20s cold, and it stalls for as long as the
/// first-run Automation prompt is up), so that work is dispatched off-thread —
/// see ``runInTerminal``.
@MainActor
enum CommandRunner {
    /// Copy a command string to the general pasteboard.
    static func copy(_ command: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command, forType: .string)
    }

    /// Open Terminal.app, `cd` to `cwd`, and run `command` in a visible window.
    /// Uses AppleScript's `do script`, which spawns a real interactive shell the
    /// user can watch and interrupt. First use prompts for Automation permission
    /// (expected macOS behavior).
    ///
    /// **Returns immediately.** `NSAppleScript.executeAndReturnError` is fully
    /// synchronous and slow: it waits for Terminal to launch (seconds when cold),
    /// waits for the Apple Event round-trip, and on first use blocks for as long
    /// as the macOS Automation permission dialog is on screen. Running that on the
    /// main thread froze the whole UI every time you launched something — so it's
    /// dispatched to a background queue instead.
    ///
    /// That queue is **serial** deliberately: `NSAppleScript` is not thread-safe,
    /// so every execution is funnelled through one thread rather than racing.
    static func runInTerminal(command: String, cwd: String) {
        // Build the shell line first (single-quote the path), then embed the whole
        // line as an AppleScript string literal (escaping backslashes + quotes).
        let shellLine = "cd \(shellSingleQuoted(cwd)) && \(command)"
        let source = """
        tell application "Terminal"
            activate
            do script \(appleScriptLiteral(shellLine))
        end tell
        """
        appleScriptQueue.async {
            guard let script = NSAppleScript(source: source) else { return }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            // Nothing surfaces the failure today (every call site discarded the
            // old return value), and the user sees Terminal either open or not.
        }
    }

    /// Serializes all AppleScript execution off the main thread. One queue, because
    /// `NSAppleScript` must not be driven from several threads at once.
    private static let appleScriptQueue = DispatchQueue(label: "com.stackpulse.applescript")

    // MARK: Quoting

    /// POSIX single-quote a string for safe use in a shell command.
    private static func shellSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Wrap a string as an AppleScript double-quoted literal, escaping the two
    /// characters that are special inside one (`\` then `"`).
    private static func appleScriptLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
