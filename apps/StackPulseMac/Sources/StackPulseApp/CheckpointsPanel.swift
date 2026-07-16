import SwiftUI

/// The per-project **Checkpoints** panel — the "take a snapshot before you let an
/// agent loose on this repo" surface, embedded in a project card.
///
/// ## Safety model (the whole point of this panel)
/// A checkpoint is a *non-destructive* snapshot of the project's uncommitted work.
/// The two actions are deliberately asymmetric:
///
/// - **Capture** (`Snapshot now`) never touches the working tree: nothing is staged,
///   stashed, reverted, or deleted, so it is safe to press at any time and needs no
///   confirmation. The copy says so out loud, because a button next to the word
///   "restore" reads as dangerous unless we tell the user it isn't.
/// - **Restore** is the only mutating action. It is gated behind an explicit
///   ``GlassConfirmDialog`` that names what changes on disk, and then runs
///   **visibly in Terminal** via ``CommandRunner/runInTerminal(command:cwd:)`` —
///   never silently in-process — so the user watches it and can interrupt it.
///   ``Checkpoint/restore_command`` already carries its own `-C '<path>'`; the cwd
///   is passed too so the visible Terminal window opens where the user expects.
///
/// ## Performance
/// This panel lives inside a lazy grid of 20+ project cards, so `body` only ever
/// reads values the store has **already published** — dictionary lookups, no git,
/// no file I/O, no expensive computed properties. The one git call is kicked off in
/// `onAppear`, and only when this project has never been loaded, so scrolling the
/// grid back and forth doesn't re-hit git.
struct CheckpointsPanel: View {
    let project: Project

    @EnvironmentObject private var store: SnapshotStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The checkpoint awaiting restore confirmation, held by **id** rather than by
    /// value: `Checkpoint` isn't `Equatable`, and an id keys `.animation(value:)`
    /// cleanly while surviving a list refresh underneath the dialog.
    @State private var pendingRestoreID: String?

    // MARK: Already-published reads (cheap — safe in body)

    private var items: [Checkpoint] { store.checkpoints[project.path] ?? [] }
    private var note: String? { store.checkpointNotes[project.path] }
    private var isBusy: Bool { store.checkpointBusy.contains(project.path) }
    /// True once a list/create op has come back for this project at least once.
    private var hasLoaded: Bool { store.checkpoints[project.path] != nil }
    /// Don't teach the empty state during the very first load — it would flash.
    private var showsEmptyState: Bool {
        items.isEmpty && note == nil && !(isBusy && !hasLoaded)
    }
    private var pendingRestore: Checkpoint? {
        guard let pendingRestoreID else { return nil }
        return items.first { $0.id == pendingRestoreID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let note = note {
                noteRow(note)
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { checkpoint in
                        CheckpointRow(checkpoint: checkpoint) {
                            pendingRestoreID = checkpoint.id
                        }
                    }
                }
            } else if showsEmptyState {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 12)
        .overlay {
            if let checkpoint = pendingRestore {
                restoreDialog(checkpoint)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85),
                   value: pendingRestoreID)
        .accessibilityElement(children: .contain)
        .onAppear {
            // Only the first appearance pays for git; later ones reuse the store.
            if store.checkpoints[project.path] == nil {
                store.loadCheckpoints(for: project.path)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text("Checkpoints")
                .font(.subheadline.weight(.semibold))
            if !items.isEmpty {
                Chip(text: "\(items.count)", tint: .secondary)
            }

            Spacer(minLength: 0)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }

            Button {
                store.createCheckpoint(for: project.path, label: nil)
            } label: {
                Label("Snapshot now", systemImage: "camera.viewfinder")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.glass(tint: .accentColor, prominent: true))
            .disabled(isBusy)
            .help("Save a snapshot of the uncommitted work in \(project.name). This does not touch your working tree — nothing is staged, stashed, reverted, or deleted.")
            .accessibilityLabel("Snapshot now")
            .accessibilityHint("Saves a snapshot of uncommitted work. Does not change your working tree.")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Note

    /// The store's honest note from the last op ("working tree is clean", "not a git
    /// repository"). This is information, not a failure — so it renders as a plain
    /// secondary line with a neutral glyph, never as an error.
    private func noteRow(_ note: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Note: \(note)")
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("No checkpoints yet")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text("A checkpoint saves your uncommitted work so you can get back to it after letting an AI agent loose on this project. Taking one is safe — it copies your changes and leaves your working tree exactly as it is.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Restore confirmation (the only mutating path)

    /// Restore is gated here. The copy names the project, the snapshot, its age, and
    /// states plainly that files on disk change — then the work happens in a visible
    /// Terminal window rather than silently behind the UI.
    private func restoreDialog(_ checkpoint: Checkpoint) -> some View {
        let fileCount = checkpoint.files.count
        let scope = fileCount == 0
            ? "the files saved in this checkpoint"
            : "\(fileCount) file\(fileCount == 1 ? "" : "s") in \(project.name)"
        return GlassConfirmDialog(
            title: "Restore “\(checkpoint.label)”?",
            message: """
            This changes files on disk. It overwrites \(scope) with the versions saved in checkpoint \(checkpoint.shortID) (\(Format.relative(checkpoint.createdAt))), replacing whatever those files contain right now.

            It runs in a Terminal window you can watch and stop:
            \(checkpoint.restore_command)

            If you want to keep the current state too, cancel and take a snapshot first.
            """,
            confirmTitle: "Restore in Terminal",
            confirmTint: .orange,
            onCancel: { pendingRestoreID = nil },
            onConfirm: {
                CommandRunner.runInTerminal(command: checkpoint.restore_command, cwd: project.path)
                pendingRestoreID = nil
            }
        )
    }
}

// MARK: - Row

/// One checkpoint: what it is (label, short SHA, branch, age), what it captured
/// (expandable file list), and its two actions. Copy is inert; **Restore…** only
/// raises the parent's confirmation — this row never mutates anything itself.
private struct CheckpointRow: View {
    let checkpoint: Checkpoint
    /// Ask the parent to confirm a restore. Deliberately not a restore itself.
    let onRestore: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filesExpanded = false
    @State private var copied = false

    /// A leaner core can hand back an empty command; don't offer actions that
    /// would copy or run nothing.
    private var hasCommand: Bool { !checkpoint.restore_command.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            identityRow
            if !checkpoint.files.isEmpty {
                filesBlock(checkpoint.files)
            }
            if hasCommand {
                actionsRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 12, prominence: .low, padding: 10)
        .accessibilityElement(children: .contain)
    }

    // MARK: Identity

    private var identityRow: some View {
        HStack(spacing: 6) {
            Text(checkpoint.label)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(checkpoint.shortID)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            if let branch = checkpoint.branch, !branch.isEmpty {
                Chip(text: branch, systemImage: "arrow.triangle.branch", tint: .secondary)
            }
            Spacer(minLength: 0)
            Text(Format.relative(checkpoint.createdAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(checkpoint.label), commit \(checkpoint.shortID)"
            + (checkpoint.branch.map { ", branch \($0)" } ?? "")
            + ", saved \(Format.relative(checkpoint.createdAt))"
        )
    }

    // MARK: Captured files

    /// The files this checkpoint saved: a count chip plus up to five middle-truncated
    /// monospace paths, expandable — mirrors the changed-files block on a mission
    /// card. Blue reads as "saved", but the count text carries the meaning on its own.
    private func filesBlock(_ files: [String]) -> some View {
        let limit = 5
        let shown = filesExpanded ? files : Array(files.prefix(limit))
        let overflow = files.count - shown.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc")
                    .imageScale(.small)
                    .foregroundStyle(.blue)
                Chip(text: "\(files.count) file\(files.count == 1 ? "" : "s") captured", tint: .blue)
                Spacer(minLength: 0)
            }
            ForEach(shown, id: \.self) { file in
                Text(file)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if overflow > 0 || (filesExpanded && files.count > limit) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        filesExpanded.toggle()
                    }
                } label: {
                    Text(filesExpanded ? "Show less" : "+\(overflow) more")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(files.count) captured file\(files.count == 1 ? "" : "s"): \(shown.joined(separator: ", "))")
    }

    // MARK: Actions

    private var actionsRow: some View {
        HStack(spacing: 8) {
            Button {
                copyRestoreCommand()
            } label: {
                Label(copied ? "Copied" : "Copy restore command",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.glass)
            .help("Copy the restore command to the clipboard — copying runs nothing:\n\(checkpoint.restore_command)")
            .accessibilityLabel(copied ? "Restore command copied" : "Copy restore command")

            Button(action: onRestore) {
                Label("Restore…", systemImage: "arrow.uturn.backward")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.glass(tint: .orange))
            .help("Put these files back as they were. Asks you to confirm first, then runs in a visible Terminal window. This changes files on disk.")
            .accessibilityLabel("Restore this checkpoint")
            .accessibilityHint("Opens a confirmation. Restoring changes files on disk.")

            Spacer(minLength: 0)
        }
    }

    private func copyRestoreCommand() {
        CommandRunner.copy(checkpoint.restore_command)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_400_000_000); copied = false }
    }
}
