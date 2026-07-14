import SwiftUI

/// Launcher — a dedicated hub for getting a demo app up fast. It lists every web
/// app StackPulse found in your folders, each with one-tap **Launch**, **Copy
/// command** (the whole one-paste recipe), and its Local + shareable Network URLs.
/// Folder management (commands, runs, stack health) stays in Projects; this is
/// purely "pick an app and run it."
struct LauncherSection: View {
    @EnvironmentObject var store: SnapshotStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The projects that are actually web-servable. Uses the cheap check (no file
    /// I/O) so filtering a long list doesn't stutter; each card resolves its full
    /// recipe lazily.
    private var launchable: [Project] {
        store.projects.filter(WebPreview.isLaunchable)
    }

    var body: some View {
        SectionScaffold(section: .launcher) { _ in
            if store.approvedRoots.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    toolbar
                    if launchable.isEmpty {
                        noAppsState
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(launchable) { project in
                                LaunchCard(project: project)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if store.projects.isEmpty && !store.approvedRoots.isEmpty { store.rescanProjects() }
            store.rescanServices()
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 340, maximum: 560), spacing: 14, alignment: .top)]
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label("\(launchable.count) app\(launchable.count == 1 ? "" : "s")", systemImage: "rocket")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if store.isScanningProjects {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Button(action: { store.addRoot() }) {
                Label("Add Folder…", systemImage: "folder.badge.plus").font(.caption.weight(.semibold))
            }
            .buttonStyle(.glass(tint: .accentColor, prominent: true))
            .help("Choose a folder (or a parent folder of several projects)")
            Button(action: { store.rescanProjects() }) {
                Label("Rescan", systemImage: "arrow.clockwise").font(.caption.weight(.medium))
            }
            .buttonStyle(.glass)
            .disabled(store.isScanningProjects)
        }
    }

    // MARK: States

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rocket")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Add your apps to launch them")
                .font(.headline)
            Text("Point StackPulse at a folder — a single project or a parent folder with several inside — and every web app shows up here with a one-tap Launch, a copy-and-paste command, and a shareable URL.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { store.addRoot() }) {
                Label("Add Folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.glass(tint: .accentColor, prominent: true))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .glassCard(padding: 24)
    }

    private var noAppsState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("No web apps found yet")
                .font(.headline)
            Text("The folders you added don't contain a recognizable web project (Vite, Next, etc.). Add another folder, or manage what was found in Projects.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .glassCard(padding: 24)
    }
}

// MARK: - Launch card

/// A big, launch-focused card: project name + identity chips, its path, and the
/// shared ``ProjectLaunchPanel`` (Launch / Copy command / URLs).
struct LaunchCard: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill").foregroundStyle(.tint)
                Text(project.name).font(.headline).lineLimit(1)
                Spacer()
                if let fw = project.frameworks.first {
                    Chip(text: fw, systemImage: "square.stack.3d.up", tint: .blue)
                }
            }
            Text(project.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            ProjectLaunchPanel(project: project, boxed: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16)
    }
}
