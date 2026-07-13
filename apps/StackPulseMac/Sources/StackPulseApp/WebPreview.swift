import AppKit
import Network

/// One-tap **"launch the dev server, then open the preview in the browser."**
///
/// StackPulse already knows each project's framework, package manager, and the
/// commands the core discovered. `WebPreview` turns that into a launch plan:
/// pick the dev/preview command, infer the localhost port, run it visibly in
/// Terminal (via ``CommandRunner`` — the user watches it and can stop it), then
/// poll the port and open the browser the moment the server is actually
/// listening. No blind delay, no in-process execution, nothing destructive.
enum WebPreview {
    /// A resolved plan: the exact command to run, where, and the URL to open.
    struct Plan: Equatable {
        let command: String
        let cwd: String
        let port: Int
        /// Short display label for the command (e.g. `pnpm dev`).
        let label: String

        var url: String { "http://localhost:\(port)" }
    }

    // MARK: Plan

    /// Build a launch plan for a project, or `nil` when it isn't a web app we can
    /// serve (no dev command and no recognizable web framework).
    static func plan(for project: Project) -> Plan? {
        guard let command = devCommand(for: project) else { return nil }
        let port = parsePort(from: command) ?? defaultPort(for: project.frameworks)
        return Plan(command: command, cwd: project.path, port: port, label: shortLabel(command))
    }

    /// If a dev server for this project is already running (matched by the core),
    /// return its URL so we can open it directly instead of relaunching.
    static func runningURL(for project: Project, among services: [RunningService]) -> String? {
        services.first {
            ($0.project_name == project.name || $0.project_path == project.path)
                && ($0.url?.isEmpty == false)
        }?.url
    }

    // MARK: Launch

    /// Run the dev command in Terminal and open the browser once the port is up.
    @MainActor
    static func launch(_ plan: Plan) {
        CommandRunner.runInTerminal(command: plan.command, cwd: plan.cwd)
        PortWatcher.shared.watch(port: plan.port, url: plan.url)
    }

    /// Open an already-running preview URL directly (no relaunch).
    @MainActor
    static func open(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Command inference

    /// The best dev/preview command for a project: a discovered dev-ish command if
    /// one exists, otherwise a synthesized `<pm> dev` when the project looks like a
    /// web app. Returns `nil` for non-web projects (Rust CLIs, libraries, …).
    private static func devCommand(for project: Project) -> String? {
        if let discovered = project.commands.first(where: isDevServer)?.command {
            return discovered
        }
        guard looksWeb(project) else { return nil }
        switch (project.package_manager ?? "").lowercased() {
        case "pnpm": return "pnpm dev"
        case "yarn": return "yarn dev"
        case "bun": return "bun dev"
        default: return "npm run dev"
        }
    }

    /// A command that starts a long-running dev server (not a build/test/deploy).
    private static func isDevServer(_ c: DiscoveredCommand) -> Bool {
        let hay = (c.label + " " + c.command).lowercased()
        let starts = ["dev", "start", "serve", "preview"].contains { hay.contains($0) }
        let excluded = ["build", "test", "lint", "typecheck", "type-check",
                        "prod", "deploy", "storybook", "install"].contains { hay.contains($0) }
        return starts && !excluded
    }

    /// Whether the project has a framework/marker that implies a web dev server.
    private static func looksWeb(_ project: Project) -> Bool {
        let tokens = (project.frameworks + project.markers).map { $0.lowercased() }
        let web = ["vite", "next", "react", "vue", "svelte", "sveltekit", "nuxt",
                   "astro", "remix", "angular", "solid", "gatsby", "docusaurus",
                   "expo", "rails", "django", "flask", "node", "package.json"]
        return tokens.contains { t in web.contains { t.contains($0) } }
    }

    // MARK: Port inference

    /// Pull an explicit port out of a command string: `--port 3100`, `--port=3100`,
    /// `-p 3100`, or a `PORT=3100` env prefix. First match wins.
    private static func parsePort(from command: String) -> Int? {
        let patterns = [
            #"--port[ =](\d{2,5})"#,
            #"-p[ =](\d{2,5})"#,
            #"PORT=(\d{2,5})"#,
        ]
        for pattern in patterns {
            if let port = firstCapture(pattern, in: command),
               let value = Int(port), (1...65535).contains(value) {
                return value
            }
        }
        return nil
    }

    /// The conventional dev-server port for a framework, defaulting to 3000.
    private static func defaultPort(for frameworks: [String]) -> Int {
        let fw = frameworks.map { $0.lowercased() }
        func has(_ needle: String) -> Bool { fw.contains { $0.contains(needle) } }
        if has("astro") { return 4321 }
        if has("angular") { return 4200 }
        if has("gatsby") { return 8000 }
        if has("expo") { return 8081 }
        if has("django") || has("flask") { return has("flask") ? 5000 : 8000 }
        if has("vite") || has("svelte") || has("solid") { return 5173 }
        // next / nuxt / remix / react / rails / vue / node → 3000
        return 3000
    }

    // MARK: Helpers

    /// A compact label for a command: its first two tokens (`npm run` → `npm run`,
    /// `pnpm dev` → `pnpm dev`), capped so the button stays small.
    private static func shortLabel(_ command: String) -> String {
        let parts = command.split(separator: " ").prefix(3).joined(separator: " ")
        return parts.count > 24 ? String(parts.prefix(24)) + "…" : parts
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = re.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

// MARK: - Port watcher
//
// Polls a localhost TCP port until it accepts a connection (the dev server is
// listening), then opens the URL once — or gives up after a timeout. Uses the
// Network framework so there's no shelling out and no arbitrary sleep.

private final class PortWatcher: @unchecked Sendable {
    static let shared = PortWatcher()
    private let queue = DispatchQueue(label: "com.stackpulse.portwatcher")

    /// Begin watching `port`; open `url` when it's reachable (or stop at `timeout`).
    func watch(port: Int, url: String, timeout: TimeInterval = 45) {
        guard port > 0, port <= 65535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let deadline = DispatchTime.now() + timeout
        attempt(port: nwPort, url: url, deadline: deadline)
    }

    private func attempt(port: NWEndpoint.Port, url: String, deadline: DispatchTime) {
        guard DispatchTime.now() < deadline else { return }
        let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let state = AttemptState(conn)
        let finish: @Sendable (Bool) -> Void = { reachable in
            guard state.finishOnce() else { return }
            state.conn.cancel()
            if reachable {
                DispatchQueue.main.async {
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                }
            } else {
                self.queue.asyncAfter(deadline: .now() + 0.8) {
                    self.attempt(port: port, url: url, deadline: deadline)
                }
            }
        }
        conn.stateUpdateHandler = { nwState in
            switch nwState {
            case .ready: finish(true)
            case .failed, .cancelled: finish(false)
            default: break
            }
        }
        conn.start(queue: queue)
        // A .waiting connection (port not yet open) never fails on its own — bound
        // each attempt so we retry until the server binds or the deadline passes.
        queue.asyncAfter(deadline: .now() + 2.5) { finish(false) }
    }
}

/// Single-shot guard for one connection attempt: only the first of the racing
/// state-handler / timeout callbacks "wins" and acts. Holds the connection so the
/// `@Sendable` finish closure never has to capture a non-Sendable `NWConnection`.
private final class AttemptState: @unchecked Sendable {
    let conn: NWConnection
    private let lock = NSLock()
    private var done = false

    init(_ conn: NWConnection) { self.conn = conn }

    func finishOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
