import Foundation

/// Runs a discovered command **in-process but fully visible**, streaming its
/// combined stdout/stderr live and capturing the exit code — the "evidence" the
/// spec asks for (did the tests pass?). This is distinct from ``CommandRunner``'s
/// "Run in Terminal": both are always shown, never hidden. The safety gate at the
/// call site is unchanged — anything not `read_only` still needs confirmation
/// first, and destructive commands are extra-warned.
///
/// A session runs `zsh -lc "<command>"` in the command's working directory so it
/// behaves like the user's own login shell (PATH, nvm, etc.). It can be stopped,
/// times out after a bound, and reports its final state back through a completion
/// so the store can persist the ``CommandRun``.
final class CaptureSession: ObservableObject, Identifiable, @unchecked Sendable {
    let id = UUID()
    let label: String
    let command: String
    let cwd: String
    let safety: String
    let projectName: String?
    let startedAtUnix: Double

    @Published private(set) var lines: [String] = []
    @Published private(set) var status: CommandRun.Status = .running
    @Published private(set) var exitCode: Int32?
    @Published private(set) var finishedAtUnix: Double?

    /// Called on the main queue whenever the run's persisted snapshot should be
    /// saved (on start, and again when it finishes).
    var onUpdate: ((CommandRun) -> Void)?

    private var process: Process?
    private let lock = NSLock()
    private var buffer = ""
    private var didFinish = false

    /// Displayed line cap (memory bound); the persisted tail is smaller.
    private static let maxLines = 2000
    private static let persistedTail = 60
    /// Hard wall-clock bound so a hung command can't run forever.
    private static let timeout: TimeInterval = 15 * 60

    init(command: DiscoveredCommand) {
        self.label = command.label
        self.command = command.command
        self.cwd = command.cwd
        self.safety = command.safety
        self.projectName = (command.cwd as NSString).lastPathComponent
        self.startedAtUnix = Date().timeIntervalSince1970
    }

    /// Snapshot of this session as a persistable ``CommandRun``.
    var run: CommandRun {
        CommandRun(
            id: id, label: label, command: command, cwd: cwd, safety: safety,
            projectName: projectName, startedAtUnix: startedAtUnix,
            finishedAtUnix: finishedAtUnix, exitCode: exitCode, status: status,
            outputTail: Array(lines.suffix(Self.persistedTail))
        )
    }

    // MARK: Lifecycle

    func start() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", command]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.ingest(text)
        }
        proc.terminationHandler = { [weak self] p in
            self?.finish(exit: p.terminationStatus, stopped: false)
        }

        self.process = proc
        onUpdate?(run)

        do {
            try proc.run()
        } catch {
            appendLine("⚠︎ Could not start: \(error.localizedDescription)")
            finish(exit: -1, stopped: false)
            return
        }

        // Timeout guard.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            guard let self, self.status == .running else { return }
            self.appendLine("⚠︎ Timed out after \(Int(Self.timeout / 60)) min — stopping.")
            self.stop()
        }
    }

    /// Ask the process to stop (SIGTERM). Idempotent.
    func stop() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        // terminationHandler will fire; mark intent so it records as `stopped`.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didFinish else { return }
            self.finish(exit: self.exitCode ?? -1, stopped: true)
        }
    }

    // MARK: Output

    /// Split incoming bytes into whole lines (buffering a partial trailing line).
    private func ingest(_ text: String) {
        lock.lock()
        buffer += text
        var completed: [String] = []
        while let nl = buffer.firstIndex(of: "\n") {
            completed.append(String(buffer[buffer.startIndex..<nl]))
            buffer = String(buffer[buffer.index(after: nl)...])
        }
        lock.unlock()
        guard !completed.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lines.append(contentsOf: completed)
            if self.lines.count > Self.maxLines {
                self.lines.removeFirst(self.lines.count - Self.maxLines)
            }
        }
    }

    private func appendLine(_ line: String) {
        DispatchQueue.main.async { [weak self] in self?.lines.append(line) }
    }

    private func finish(exit code: Int32, stopped: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didFinish else { return }
            self.didFinish = true
            // Flush any buffered partial line.
            self.lock.lock()
            let tail = self.buffer
            self.buffer = ""
            self.lock.unlock()
            if !tail.isEmpty { self.lines.append(tail) }

            self.process?.terminationHandler = nil
            self.process?.standardOutput.map { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
            self.exitCode = code
            self.finishedAtUnix = Date().timeIntervalSince1970
            self.status = stopped ? .stopped : (code == 0 ? .passed : .failed)
            self.onUpdate?(self.run)
        }
    }
}
