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
        content
            .onAppear { if lanIP == nil { lanIP = LocalNetwork.primaryIPv4() } }
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
        } else if let recipe = launchRecipe {
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
