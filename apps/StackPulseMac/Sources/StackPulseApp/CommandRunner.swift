import AppKit

/// Runs discovered commands **visibly and never silently**.
///
/// Safety model (enforced by the call sites in ``ProjectsSection``): "Copy" only
/// places text on the pasteboard; "Run in Terminal" opens Terminal.app at the
/// command's working directory and types the command there, so the user always
/// sees exactly what runs and can stop it. Nothing is ever executed in-process,
/// and non-read-only commands are gated behind a confirmation dialog upstream.
///
/// All methods touch AppKit and are `@MainActor`.
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
    /// (expected macOS behavior). Returns `false` if Terminal couldn't be driven.
    @discardableResult
    static func runInTerminal(command: String, cwd: String) -> Bool {
        // Build the shell line first (single-quote the path), then embed the whole
        // line as an AppleScript string literal (escaping backslashes + quotes).
        let shellLine = "cd \(shellSingleQuoted(cwd)) && \(command)"
        let source = """
        tell application "Terminal"
            activate
            do script \(appleScriptLiteral(shellLine))
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }

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
