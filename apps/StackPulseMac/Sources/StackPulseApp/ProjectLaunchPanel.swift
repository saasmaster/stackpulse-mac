import SwiftUI

/// The reusable one-tap launch panel for a web project — used by both the Projects
/// cards and the Launcher. **Launch** runs the full recipe in Terminal and opens
/// the browser when the port is up; **Copy command** puts the whole one-paste
/// recipe on the clipboard; the Local + shareable Network URLs sit below. When a
/// matching dev server is already running it collapses to an Open button. Renders
/// nothing for a non-web project (no recipe).
struct ProjectLaunchPanel: View {
    let project: Project
    /// When true, wrap the launch controls in their own low-glass card (Projects);
    /// the Launcher supplies its own card, so it passes false.
    var boxed: Bool = true

    @EnvironmentObject private var store: SnapshotStore
    @State private var copiedCommand = false
    @State private var lanIP: String?
    /// The launch recipe, resolved once (reads `node_modules` + `package.json`) and
    /// cached — never recomputed during scroll/relayout, which is what made a long
    /// Projects list stutter.
    @State private var recipe: WebPreview.Recipe?

    /// If a matching dev server is already running, its URL (open it directly).
    /// Cheap (in-memory filter), so it stays reactive to running servers.
    private var liveURL: String? { WebPreview.runningURL(for: project, among: store.services) }

    var body: some View {
        content
            // Resolve the recipe + LAN IP once per distinct project, off the main
            // thread, instead of on every body evaluation.
            .task(id: project.id) { await resolve() }
    }

    private func resolve() async {
        let proj = project
        let result = await Task.detached(priority: .utility) { () -> (WebPreview.Recipe?, String?) in
            let installed = FileManager.default.fileExists(
                atPath: (proj.path as NSString).appendingPathComponent("node_modules"))
            return (WebPreview.recipe(for: proj, installNeeded: !installed), LocalNetwork.primaryIPv4())
        }.value
        recipe = result.0
        lanIP = result.1
    }

    @ViewBuilder private var content: some View {
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
        } else if let recipe {
            let inner = VStack(alignment: .leading, spacing: 8) {
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

                    // Launching an uninstalled project installs its dependencies
                    // first — network access plus whatever the packages run on
                    // install. Say so on the face of the panel rather than only in
                    // the Launch tooltip nobody hovers.
                    if recipe.installsDependencies {
                        Chip(text: "installs deps first", systemImage: "arrow.down.circle", tint: .orange)
                            .help("No node_modules yet, so Launch runs \(recipe.steps.first ?? "the install step") before the dev server.")
                    }

                    Spacer(minLength: 0)
                }
                urlRow(recipe)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if boxed {
                inner.padding(10).liquidGlass(cornerRadius: 12, prominence: .low, padding: 0)
            } else {
                inner
            }
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
        Button { CommandRunner.copy(url) } label: {
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
}
