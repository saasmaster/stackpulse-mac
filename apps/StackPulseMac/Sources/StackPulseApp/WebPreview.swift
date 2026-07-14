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
        return Plan(command: command, cwd: project.path,
                    port: resolvedPort(for: project, devCommand: command),
                    label: shortLabel(command))
    }

    // MARK: Launch recipe (one paste → running app)

    /// A full "just launch it" recipe: the single line you can paste anywhere to
    /// bring the app up — `cd` into it, install deps if needed, and start the dev
    /// server with the host exposed so it also serves on your LAN IP. Plus the
    /// URLs it will serve on (localhost + the shareable network address).
    struct Recipe: Equatable {
        let projectName: String
        let cwd: String
        /// Steps after the `cd`, in order (e.g. `["npm install", "npm run dev -- --host"]`).
        let steps: [String]
        let port: Int

        /// The command run *inside* the project dir (what ``CommandRunner`` cd's to).
        var command: String { steps.joined(separator: " && ") }
        /// The full self-contained one-liner — copy this and paste it anywhere.
        var oneLiner: String { (["cd \(shellQuoted(cwd))"] + steps).joined(separator: " && ") }
        var localURL: String { "http://localhost:\(port)" }
        func networkURL(_ ip: String) -> String { "http://\(ip):\(port)" }
    }

    /// Build a one-paste launch recipe for a web project. `installNeeded` should be
    /// true when the project's dependencies aren't installed yet (no `node_modules`),
    /// so the recipe includes the install step; otherwise it's skipped for speed.
    static func recipe(for project: Project, installNeeded: Bool) -> Recipe? {
        guard let dev = devCommand(for: project) else { return nil }
        let port = resolvedPort(for: project, devCommand: dev)
        var steps: [String] = []
        if installNeeded, let install = installCommand(for: project) {
            steps.append(install)
        }
        steps.append(withHost(dev, frameworks: project.frameworks))
        return Recipe(projectName: project.name, cwd: project.path, steps: steps, port: port)
    }

    /// Run the full recipe in Terminal (so you see the dev server's own Network URL)
    /// and open the browser once the port is listening.
    @MainActor
    static func launch(_ recipe: Recipe) {
        CommandRunner.runInTerminal(command: recipe.command, cwd: recipe.cwd)
        PortWatcher.shared.watch(port: recipe.port, url: recipe.localURL)
    }

    /// The install step for a project's package manager (node only), or `nil`.
    private static func installCommand(for project: Project) -> String? {
        switch (project.package_manager ?? "").lowercased() {
        case "pnpm": return "pnpm install"
        case "yarn": return "yarn"
        case "bun": return "bun install"
        case "npm": return "npm install"
        default: return looksWeb(project) ? "npm install" : nil
        }
    }

    /// Append the right "expose on the network" flag for the framework, unless the
    /// command already sets a host. npm needs `--` to forward args to the script.
    private static func withHost(_ dev: String, frameworks: [String]) -> String {
        let lower = dev.lowercased()
        if lower.contains("--host") || lower.contains("-h 0.0.0.0") || lower.contains("--hostname") {
            return dev
        }
        let flag = hostFlag(for: frameworks)
        return lower.contains("npm run") ? "\(dev) -- \(flag)" : "\(dev) \(flag)"
    }

    private static func hostFlag(for frameworks: [String]) -> String {
        let fw = frameworks.map { $0.lowercased() }
        if fw.contains(where: { $0.contains("next") }) { return "-H 0.0.0.0" }
        if fw.contains(where: { $0.contains("angular") }) { return "--host 0.0.0.0" }
        return "--host"
    }

    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether a project is a launchable web app — a **cheap** check (no file I/O)
    /// suitable for filtering long lists every render. Full `plan`/`recipe` (which
    /// read `package.json` for the port) should be computed lazily, once.
    static func isLaunchable(_ project: Project) -> Bool {
        devCommand(for: project) != nil
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

    /// The port the app will actually serve on: parsed from the command if it's
    /// explicit, else from the resolved `package.json` script (e.g. a `dev` script
    /// of `next dev --port 3100`), else the framework default. This is what makes
    /// the shown URLs correct for projects whose port lives in package.json.
    private static func resolvedPort(for project: Project, devCommand: String) -> Int {
        if let p = parsePort(from: devCommand) { return p }
        if let script = scriptName(from: devCommand),
           let body = packageScriptBody(cwd: project.path, script: script),
           let p = parsePort(from: body) {
            return p
        }
        return defaultPort(for: project.frameworks)
    }

    /// The npm script name a dev command invokes (`npm run dev` → `dev`,
    /// `pnpm dev` → `dev`), or `nil` for a direct binary invocation.
    private static func scriptName(from command: String) -> String? {
        let tokens = command.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return nil }
        if let runIdx = tokens.firstIndex(of: "run"), runIdx + 1 < tokens.count {
            return tokens[runIdx + 1]           // npm run <script>
        }
        if ["pnpm", "yarn", "bun"].contains(first), tokens.count > 1 {
            return tokens[1]                     // pnpm/yarn/bun <script>
        }
        return nil
    }

    /// Read `<cwd>/package.json` and return the body of `scripts[script]`, if any.
    private static func packageScriptBody(cwd: String, script: String) -> String? {
        let url = URL(fileURLWithPath: cwd).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any],
              let body = scripts[script] as? String
        else { return nil }
        return body
    }

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
