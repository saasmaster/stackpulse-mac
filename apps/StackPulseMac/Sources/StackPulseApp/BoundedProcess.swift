import Foundation

/// Runs a subprocess and captures its stdout, bounded by a hard deadline.
///
/// This exists to own — in exactly one place — a subtlety that is easy to get
/// wrong and was gotten wrong twice: **you cannot bound a subprocess read with a
/// poll loop over `FileHandle.availableData`.** `availableData` blocks until a byte
/// arrives or the writer closes the pipe, so a `while proc.isRunning && Date() <
/// deadline { availableData }` loop parks *inside* the read whenever the child is
/// silent (a pending Keychain "Allow" prompt, a `SQLITE_BUSY` lock) and the
/// deadline check at the top is never re-reached. The timeout becomes dead code
/// for the one case it was written for.
///
/// The correct shape, hidden here: a timer **terminates the process** at the
/// deadline — closing the write end so the streaming `readDataToEndOfFile` returns
/// EOF — and `readDataToEndOfFile` drains as the child writes, so a payload past
/// the ~64KB pipe buffer never deadlocks either. Callers describe *what* to run and
/// read the outcome; they never touch pipes, timers, or termination reasons.
enum BoundedProcess {

    /// The outcome of a bounded run. `timedOut` is true when the deadline fired and
    /// the process was killed rather than exiting on its own.
    struct Outcome {
        let stdout: Data
        let timedOut: Bool
        let exitStatus: Int32

        /// Convenience: the trimmed UTF-8 stdout, or `nil` when the run timed out,
        /// exited non-zero, or produced nothing usable.
        var trimmedText: String? {
            guard !timedOut, exitStatus == 0,
                  let text = String(data: stdout, encoding: .utf8)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return nil }
            return text
        }
    }

    /// Run `executable` with `arguments`, capturing stdout, killing it after
    /// `timeout` seconds if it hasn't finished. stderr is discarded. Returns `nil`
    /// only when the process could not be launched at all.
    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> Outcome? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }

        let handle = out.fileHandleForReading
        // Terminate at the deadline; the kill closes the pipe's write end, so the
        // blocking read below unblocks with EOF.
        let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = handle.readDataToEndOfFile() // streams; no >64KB-buffer deadlock
        killer.cancel()
        proc.waitUntilExit()
        // Killed by our SIGTERM ⇒ the deadline fired. (A child that crashes on its
        // own also lands here; both are "no usable answer", which is all a caller
        // acts on.)
        let timedOut = proc.terminationReason == .uncaughtSignal
        return Outcome(stdout: data, timedOut: timedOut, exitStatus: proc.terminationStatus)
    }
}
