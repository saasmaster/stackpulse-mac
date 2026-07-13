import SwiftUI

/// Projects (Command Memory): the user approves project folders, StackPulse asks
/// the core to discover their runnable commands, and this surface remembers them.
///
/// Safety is the whole point of the running model here: **Copy** only copies;
/// **Run in Terminal** opens Terminal at the command's `cwd` so the user watches
/// it run; and any command whose safety ≠ `read_only` is gated behind an explicit
/// glass confirmation dialog (destructive ones get a red, extra-loud warning).
/// Nothing ever runs automatically or in-process.
struct ProjectsSection: View {
    @EnvironmentObject var store: SnapshotStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A command awaiting confirmation, with how it should run once confirmed.
    /// Set only for non-read-only commands; read-only commands run immediately.
    @State private var pending: PendingRun?
    /// The live captured run whose console is on screen, if any.
    @State private var activeSession: CaptureSession?
    /// A past run whose captured output is being viewed, if any.
    @State private var viewingRun: CommandRun?

    /// A command plus how it should run once confirmed.
    private struct PendingRun: Identifiable {
        let command: DiscoveredCommand
        /// True = run in-app with captured output; false = open in Terminal.
        let capture: Bool
        var id: String { command.id + (capture ? "\u{1}cap" : "\u{1}term") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if store.approvedRoots.isEmpty {
                    emptyState
                } else {
                    rootsBar
                    runningServersBlock
                    recentRunsBlock
                    discoveredList
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WindowBackdrop().ignoresSafeArea())
        .onAppear { store.rescanServices() }
        .overlay {
            if let p = pending {
                CommandConfirmDialog(
                    command: p.command,
                    onCancel: { pending = nil },
                    onConfirm: {
                        perform(p.command, capture: p.capture)
                        pending = nil
                    }
                )
            }
        }
        .sheet(item: $activeSession) { session in
            RunConsoleView(session: session, onClose: { activeSession = nil })
        }
        .sheet(item: $viewingRun) { run in
            RunOutputSheet(run: run, onClose: { viewingRun = nil })
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85),
                   value: pending?.id)
    }

    // MARK: Command run gate

    /// Run in Terminal (visible external shell). Non-read-only commands are gated
    /// behind the confirmation dialog; read-only ones run immediately.
    private func requestRun(_ command: DiscoveredCommand) {
        if CommandSafety.requiresConfirmation(command.safety) {
            pending = PendingRun(command: command, capture: false)
        } else {
            perform(command, capture: false)
        }
    }

    /// Run in-app with captured output (the evidence flow). Same safety gate.
    private func requestCapture(_ command: DiscoveredCommand) {
        if CommandSafety.requiresConfirmation(command.safety) {
            pending = PendingRun(command: command, capture: true)
        } else {
            perform(command, capture: true)
        }
    }

    /// Execute a confirmed/allowed command either in Terminal or captured in-app.
    private func perform(_ command: DiscoveredCommand, capture: Bool) {
        if capture {
            let session = CaptureSession(command: command)
            session.onUpdate = { store.upsertRun($0) }
            activeSession = session
            session.start()
        } else {
            CommandRunner.runInTerminal(command: command.command, cwd: command.cwd)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Projects")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    Text("Approve project folders and StackPulse remembers their commands — copy them, or run them in Terminal with a safety check.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !store.approvedRoots.isEmpty {
                    Button(action: { store.rescanProjects() }) {
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(store.isScanningProjects && !reduceMotion ? 360 : 0))
                            .animation(store.isScanningProjects && !reduceMotion
                                ? .linear(duration: 1).repeatForever(autoreverses: false)
                                : .default, value: store.isScanningProjects)
                    }
                    .controlSize(.large)
                    .help("Rescan project folders")
                    .disabled(store.isScanningProjects)
                }
            }
            metaBar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metaBar: some View {
        HStack(spacing: 8) {
            let count = store.projects.count
            Label("\(count) project\(count == 1 ? "" : "s")", systemImage: "folder")
            Text("·").foregroundStyle(.tertiary)
            Label("Scanned \(Format.relative(store.projectsUpdatedAt))", systemImage: "clock.arrow.circlepath")
            if store.isScanningProjects {
                Text("·").foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("scanning")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Remember your commands")
                .font(.headline)
            Text("Add a project folder to let StackPulse remember your commands — test, build, lint, and more — ready to copy or run.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { store.addRoot() }) {
                Label("Add Folder…", systemImage: "plus")
            }
            .buttonStyle(.glass(tint: .accentColor, prominent: true))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .glassCard(padding: 24)
    }

    // MARK: Recent runs (captured command outcomes / history)

    /// The last few captured runs with their outcome — click to reopen the output,
    /// or re-run. Persisted across launches so "did the tests pass?" is one glance.
    @ViewBuilder private var recentRunsBlock: some View {
        if !store.commandRuns.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    Text("Recent runs")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { store.clearCommandRuns() } label: {
                        Text("Clear").font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Clear run history")
                }
                ForEach(store.commandRuns.prefix(6)) { run in
                    RecentRunRow(
                        run: run,
                        onView: { viewingRun = run },
                        onRerun: {
                            let cmd = DiscoveredCommand(
                                label: run.label, command: run.command, cwd: run.cwd,
                                source: "history", safety: run.safety, confidence: 1, raw_key: nil)
                            requestCapture(cmd)
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(padding: 16)
        }
    }

    // MARK: Running dev servers (merged from the former Services section)

    /// Locally-running dev servers, shown right where you launch them. Each has a
    /// one-tap Open (and Copy) via the shared ``ServiceCard``. Read-only here; the
    /// stop control still lives in the full detection flow.
    @ViewBuilder private var runningServersBlock: some View {
        if !store.services.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.circle")
                        .foregroundStyle(.secondary)
                    Text("Running now")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(store.services.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { store.rescanServices() } label: {
                        Label("Rescan", systemImage: "arrow.clockwise").font(.caption.weight(.medium))
                    }
                    .buttonStyle(.glass)
                    .disabled(store.isScanningServices)
                    .help("Scan local ports again")
                }
                ForEach(store.services) { service in
                    ServiceCard(service: service)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(padding: 16)
        }
    }

    // MARK: Approved roots

    private var rootsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Watched folders", systemImage: "folder.badge.gearshape")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { store.addRoot() }) {
                    Label("Add Folder…", systemImage: "plus")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.glass(tint: .accentColor))
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(store.approvedRoots, id: \.self) { root in
                    RootChip(path: root, onRemove: { store.removeRoot(root) })
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16)
    }

    // MARK: Body for the approved-roots case

    @ViewBuilder private var discoveredList: some View {
        if store.projects.isEmpty {
            if store.isScanningProjects {
                LoadingProjectsView()
            } else {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Nothing discovered yet",
                    message: store.projectsError
                        ?? "No projects with recognizable commands were found in the watched folders."
                )
            }
        } else {
            ForEach(store.projects) { project in
                ProjectCard(project: project, onRun: requestRun, onCapture: requestCapture)
            }
        }
    }
}

// MARK: - Loading

private struct LoadingProjectsView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Scanning your project folders…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .glassCard(padding: 24)
    }
}

// MARK: - Root chip

private struct RootChip: View {
    let path: String
    let onRemove: () -> Void

    private var name: String {
        (path as NSString).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .imageScale(.small)
                .foregroundStyle(.tint)
            Text(name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Stop watching \(path)")
            .accessibilityLabel("Remove \(name)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .liquidGlass(cornerRadius: 999, prominence: .low, padding: 0)
        .help(path)
    }
}

// MARK: - Project card

struct ProjectCard: View {
    let project: Project
    let onRun: (DiscoveredCommand) -> Void
    let onCapture: (DiscoveredCommand) -> Void

    @EnvironmentObject private var store: SnapshotStore
    @State private var copiedCommand = false
    @State private var lanIP: String?

    /// Whether dependencies are already installed (so the recipe can skip install).
    private var nodeModulesExists: Bool {
        FileManager.default.fileExists(atPath: (project.path as NSString).appendingPathComponent("node_modules"))
    }

    /// The one-paste launch recipe for this project, when it's a servable web app.
    private var launchRecipe: WebPreview.Recipe? {
        WebPreview.recipe(for: project, installNeeded: !nodeModulesExists)
    }

    /// If a matching dev server is already running, its URL (open it directly).
    private var liveURL: String? { WebPreview.runningURL(for: project, among: store.services) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            pathRow
            launchPanel
            if !metaChips.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(metaChips, id: \.0) { chip in
                        Chip(text: chip.0, systemImage: chip.1, tint: chip.2)
                    }
                }
            }
            if !project.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(project.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !project.commands.isEmpty {
                Divider().opacity(0.4)
                VStack(spacing: 6) {
                    ForEach(project.commands) { command in
                        CommandRow(command: command, onRun: onRun, onCapture: onCapture)
                    }
                }
            } else {
                Text("No runnable commands discovered for this project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16)
        .onAppear { if lanIP == nil { lanIP = LocalNetwork.primaryIPv4() } }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(.tint)
            Text(project.name)
                .font(.headline)
            Spacer()
            if let test = project.testCommand {
                Button(action: { onCapture(test) }) {
                    Label("Test Project", systemImage: "checkmark.seal")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass(tint: .green, prominent: true))
                .help("Run \"\(test.label)\" in StackPulse and capture the result: \(test.command)")
            }
        }
    }

    /// The one-tap launch panel: for a running app, an Open button; otherwise a
    /// prominent **Launch** (one paste behind the scenes: cd + install + start with
    /// the host exposed, then opens the browser), a **Copy command** that puts the
    /// whole recipe on the clipboard, and the Local + shareable Network URLs.
    @ViewBuilder private var launchPanel: some View {
        if let live = liveURL {
            HStack(spacing: 8) {
                Button { WebPreview.open(live) } label: {
                    Label("Open Preview", systemImage: "globe").font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass(tint: .accentColor, prominent: true))
                Text(live)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Chip(text: "running", systemImage: "bolt.fill", tint: .green)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let recipe = launchRecipe {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button { WebPreview.launch(recipe) } label: {
                        Label("Launch", systemImage: "play.fill").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass(tint: .blue, prominent: true))
                    .help("Run it (\(recipe.command)) and open the browser when it's ready")

                    Button { copyCommand(recipe.oneLiner) } label: {
                        Label(copiedCommand ? "Copied" : "Copy command",
                              systemImage: copiedCommand ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.glass)
                    .help("Copy the whole one-paste command:\n\(recipe.oneLiner)")

                    Spacer(minLength: 0)
                }
                urlRow(recipe)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .liquidGlass(cornerRadius: 12, prominence: .low, padding: 0)
        }
    }

    /// Local + Network URL chips (tap to copy). The Network one is the "temporary
    /// IP domain" you can open from your phone or another machine on the same Wi-Fi.
    @ViewBuilder private func urlRow(_ recipe: WebPreview.Recipe) -> some View {
        HStack(spacing: 8) {
            urlChip("Local", recipe.localURL)
            if let ip = lanIP {
                urlChip("Network", recipe.networkURL(ip))
            }
            Spacer(minLength: 0)
        }
    }

    private func urlChip(_ label: String, _ url: String) -> some View {
        Button { copyURL(url) } label: {
            HStack(spacing: 4) {
                Text(label.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(url.replacingOccurrences(of: "http://", with: ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
                Image(systemName: "doc.on.doc").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .liquidGlass(cornerRadius: 8, prominence: .low, padding: 0)
        }
        .buttonStyle(.plain)
        .help("Copy \(url)")
    }

    private func copyCommand(_ text: String) {
        CommandRunner.copy(text)
        copiedCommand = true
        Task { try? await Task.sleep(nanoseconds: 1_400_000_000); copiedCommand = false }
    }

    private func copyURL(_ text: String) {
        CommandRunner.copy(text)
    }

    private var pathRow: some View {
        Text(project.path)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// (text, systemImage, tint) for the identity chips row.
    private var metaChips: [(String, String, Color)] {
        var chips: [(String, String, Color)] = []
        if let branch = project.git_branch {
            chips.append((branch, "arrow.triangle.branch", .purple))
        }
        if let pm = project.package_manager {
            chips.append((pm, "cube.box", .cyan))
        }
        for marker in project.markers {
            chips.append((marker, "tag", .secondary))
        }
        for framework in project.frameworks {
            chips.append((framework, "square.stack.3d.up", .blue))
        }
        return chips
    }
}

// MARK: - Command row

struct CommandRow: View {
    let command: DiscoveredCommand
    let onRun: (DiscoveredCommand) -> Void
    let onCapture: (DiscoveredCommand) -> Void

    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(command.label)
                        .font(.callout.weight(.semibold))
                    SafetyChip(safety: command.safety)
                }
                Text(command.command)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button(action: doCopy) {
                Label(copied ? "Copied" : "Copy",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.glass)
            .help("Copy the command to the clipboard")

            Button(action: { onCapture(command) }) {
                Label("Run", systemImage: "play.fill")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.glass(tint: CommandSafety.isDestructive(command.safety) ? .red : .accentColor))
            .help(CommandSafety.requiresConfirmation(command.safety)
                ? "Confirm, then run in StackPulse and capture the output"
                : "Run in StackPulse and capture the output")

            Button(action: { onRun(command) }) {
                Image(systemName: "terminal")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.glass)
            .help(CommandSafety.requiresConfirmation(command.safety)
                ? "Confirm, then run in Terminal"
                : "Run in Terminal")
        }
        .padding(.vertical, 3)
    }

    private func doCopy() {
        CommandRunner.copy(command.command)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}

// MARK: - Recent run row

/// One captured run in the Recent-runs list: outcome chip, label + project, when
/// it ran and how long it took, and View-output / Re-run actions.
struct RecentRunRow: View {
    let run: CommandRun
    let onView: () -> Void
    let onRerun: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RunStatusChip(status: run.status)
                .frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.label)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let name = run.projectName, !name.isEmpty {
                        Text(name)
                    }
                    Text("· \(Format.relative(run.startedAt))")
                    if let d = run.duration {
                        Text("· \(d < 60 ? String(format: "%.1fs", d) : "\(Int(d)/60)m \(Int(d)%60)s")")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(action: onView) {
                Label("Output", systemImage: "text.alignleft").font(.caption2)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("View the captured output")

            Button(action: onRerun) {
                Label("Re-run", systemImage: "arrow.clockwise").font(.caption2.weight(.medium))
            }
            .buttonStyle(.glass)
            .help("Run this command again and capture the output")
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Command confirmation dialog (safety-critical)

/// A hand-crafted Liquid Glass confirmation gate for running a command — the same
/// scrim + centered frosted card + glass-buttons pattern as ``GlassConfirmDialog``,
/// but showing the exact command, its working directory, and its safety label.
/// Destructive commands get a red, explicit warning. Escape / Cancel always
/// aborts; the run button is never the default action, so Return can't run it.
struct CommandConfirmDialog: View {
    let command: DiscoveredCommand
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private var isDestructive: Bool { CommandSafety.isDestructive(command.safety) }
    private var accent: Color { isDestructive ? .red : CommandSafety.color(command.safety) }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.28))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: isDestructive ? "exclamationmark.octagon.fill" : "terminal.fill")
                        .foregroundStyle(accent)
                        .font(.title3)
                    Text(isDestructive ? "Run a destructive command?" : "Run this command?")
                        .font(.title3.weight(.semibold))
                }

                Text(command.command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )

                Label(command.cwd, systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .labelStyle(.titleAndIcon)

                HStack(spacing: 8) {
                    SafetyChip(safety: command.safety)
                    Text("Opens in Terminal — you'll see it run and can stop it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isDestructive {
                    Label("This can delete or reset files. Make sure you understand exactly what it does before running it.",
                          systemImage: "trash.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.red)
                        .labelStyle(.titleAndIcon)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                    Button(isDestructive ? "Run anyway" : "Run in Terminal", action: onConfirm)
                        .buttonStyle(.glass(tint: accent, prominent: true))
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: 440, alignment: .leading)
            .liquidGlass(cornerRadius: 24, prominence: .elevated, padding: 24)
            .padding(40)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - Flow layout (wrapping chips)

/// A minimal wrapping layout: lays children left→right, wrapping to a new line
/// when the row would overflow the proposed width. Used for the roots bar and the
/// per-project marker/framework chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                // wrap
                maxRowWidth = max(maxRowWidth, x - spacing)
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        maxRowWidth = max(maxRowWidth, x - spacing)
        let totalHeight = y + rowHeight
        let width = maxWidth.isFinite ? maxWidth : max(0, maxRowWidth)
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
