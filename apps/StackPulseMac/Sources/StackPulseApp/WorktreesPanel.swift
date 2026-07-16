import SwiftUI
import AppKit

/// The per-project **Worktrees** panel — the "give the agent its own copy of this
/// repo" surface, embedded in a project card.
///
/// ## What a worktree is (and why this panel exists)
/// A git worktree is a second working directory for the same repository, checked
/// out on its own branch. It lets an AI agent churn through a project in an
/// isolated copy while your main checkout stays exactly as you left it — no
/// stashing, no branch juggling, no "wait, what did it just do to my working
/// tree?". That isolation is the entire product story here, so the copy says it
/// out loud rather than assuming the user knows what `git worktree` is.
///
/// ## Safety model (the two actions are deliberately asymmetric)
/// - **Create** is purely *additive*: it makes a new directory next to nothing
///   you own and never touches your main checkout, so it needs no confirmation.
///   It's an inline field + button rather than a modal — naming a copy shouldn't
///   feel like a decision. StackPulse puts it in ``SnapshotStore/worktreesDir``,
///   outside your project folders, so it can't come back as a bogus project.
/// - **Remove** is the only destructive action: it **deletes a directory on
///   disk**. It's gated behind an explicit ``GlassConfirmDialog`` that names the
///   path and shows the literal command, and then runs **visibly in Terminal**
///   via ``CommandRunner/runInTerminal(command:cwd:)`` — never silently — so the
///   user watches it and can interrupt it. The main checkout is never removable:
///   the core withholds `remove_command` for it, and this panel refuses too.
///
/// ## Performance
/// This panel lives inside a lazy grid of 20+ project cards, so `body` only ever
/// reads values the store has **already published** — dictionary lookups, no git,
/// no file I/O, no expensive computed properties. The one git call is kicked off
/// in `onAppear`, and only when this project has never been loaded, so scrolling
/// the grid back and forth doesn't re-hit git.
struct WorktreesPanel: View {
    let project: Project

    @EnvironmentObject private var store: SnapshotStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The name being typed for a new isolated copy. Cleared once handed to the
    /// store, so the field is ready for the next one.
    @State private var newName: String = ""

    /// The worktree awaiting removal confirmation, held by **path** (its `id`)
    /// rather than by value: `Worktree` isn't `Equatable`, and an id keys
    /// `.animation(value:)` cleanly while surviving a list refresh underneath the
    /// dialog.
    @State private var pendingRemovalPath: String?

    // MARK: Already-published reads (cheap — safe in body)

    private var items: [Worktree] { store.worktrees[project.path] ?? [] }
    private var note: String? { store.worktreeNotes[project.path] }
    private var isBusy: Bool { store.worktreeBusy.contains(project.path) }
    /// True once a list/create op has come back for this project at least once.
    private var hasLoaded: Bool { store.worktrees[project.path] != nil }

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canCreate: Bool { !trimmedName.isEmpty && !isBusy }

    /// Don't teach the empty state during the very first load — it would flash
    /// before git answers.
    private var showsEmptyState: Bool {
        items.isEmpty && note == nil && !(isBusy && !hasLoaded)
    }
    /// Only the main checkout exists: explain what a second one would buy you.
    private var showsSoloHint: Bool { hasLoaded && items.count == 1 }

    private var pendingRemoval: Worktree? {
        guard let pendingRemovalPath else { return nil }
        return items.first { $0.id == pendingRemovalPath }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            createRow
            if let note = note {
                noteRow(note)
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { worktree in
                        WorktreeRow(worktree: worktree) {
                            pendingRemovalPath = worktree.id
                        }
                    }
                }
                if showsSoloHint {
                    soloHint
                }
            } else if showsEmptyState {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 12)
        .overlay {
            if let worktree = pendingRemoval {
                removeDialog(worktree)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85),
                   value: pendingRemovalPath)
        .accessibilityElement(children: .contain)
        .onAppear {
            // Only the first appearance pays for git; later ones reuse the store.
            if store.worktrees[project.path] == nil {
                store.loadWorktrees(for: project.path)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.on.square")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text("Worktrees")
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
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Create (additive — no confirmation, by design)

    /// Name-and-go, inline: a modal would overstate the weight of an action that
    /// only ever *adds* a directory. Return submits, matching the button.
    private var createRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "plus.square.on.square")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                TextField("Name this copy (e.g. agent-refactor)", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .onSubmit(create)
                    .disabled(isBusy)
                    .accessibilityLabel("Name for the new isolated copy")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .liquidGlass(cornerRadius: 8, prominence: .low, padding: 0)

            Button(action: create) {
                Label("New isolated copy", systemImage: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.glass(tint: .accentColor, prominent: true))
            .disabled(!canCreate)
            .help("Create a second working directory for \(project.name) on its own branch, so an agent can work there without touching your main checkout. This does not change your working tree — nothing is staged, stashed, reverted, or deleted.")
            .accessibilityLabel("New isolated copy")
            .accessibilityHint("Adds a separate working directory on its own branch. Does not change your main checkout.")
        }
        .accessibilityElement(children: .contain)
    }

    private func create() {
        guard canCreate else { return }
        store.createWorktree(for: project.path, name: trimmedName)
        newName = ""
    }

    // MARK: Note

    /// The store's honest note from the last op ("a worktree with that name
    /// already exists", "not a git repository"). This is information, not a
    /// failure — so it renders as a plain secondary line with a neutral glyph,
    /// never as an error.
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

    // MARK: Teaching states

    private var soloHint: some View {
        Text("Only your main checkout so far. An isolated copy gives an AI agent its own directory and branch to work in, so whatever it does there leaves the files you're working on untouched.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("No worktrees yet")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text("A worktree is a second working directory for this repo on its own branch — somewhere an AI agent can work without touching your main checkout. Creating one is safe: it only adds a directory and leaves your working tree exactly as it is.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Remove confirmation (the only destructive path)

    /// Removal is gated here. The copy states plainly that a directory is deleted
    /// from disk, names the exact path, and shows the literal command — then the
    /// work happens in a visible Terminal window rather than silently behind the
    /// UI. Renders nothing without a command, so there's no way to confirm an
    /// action that has nothing to run.
    @ViewBuilder
    private func removeDialog(_ worktree: Worktree) -> some View {
        if let command = worktree.remove_command, !worktree.is_main {
            GlassConfirmDialog(
                title: "Remove “\(worktree.name)”?",
                message: """
                This deletes a directory on disk. It removes this worktree and everything inside it:
                \(worktree.path)

                Any work in there that you haven't committed or pushed is gone. Your main checkout of \(project.name) is not touched.

                It runs in a Terminal window you can watch and stop:
                \(command)
                """,
                confirmTitle: "Remove in Terminal",
                confirmTint: .red,
                onCancel: { pendingRemovalPath = nil },
                onConfirm: {
                    CommandRunner.runInTerminal(command: command, cwd: project.path)
                    pendingRemovalPath = nil
                }
            )
        }
    }
}

// MARK: - Row

/// One worktree: what it is (name, path, branch, HEAD, status chips) and the
/// three inert ways to get to it. **Remove…** only raises the parent's
/// confirmation — this row never deletes anything itself, and never offers
/// removal for the main checkout.
private struct WorktreeRow: View {
    let worktree: Worktree
    /// Ask the parent to confirm a removal. Deliberately not a removal itself.
    let onRemove: () -> Void

    @State private var copied = false

    /// The main checkout is not ours to delete: the core withholds its
    /// `remove_command`, and we double-check `is_main` so a future core that
    /// reported one couldn't turn this into a foot-gun.
    private var canRemove: Bool {
        !worktree.is_main && !(worktree.remove_command ?? "").isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            identityRow
            pathRow
            actionsRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The main checkout sits a layer up with an accent rim: it's the one you
        // actually work in, and the one with no Remove button. The "main
        // checkout" chip carries the same meaning without relying on colour.
        .liquidGlass(cornerRadius: 12,
                     prominence: worktree.is_main ? .regular : .low,
                     tint: worktree.is_main ? .accentColor : nil,
                     padding: 10)
        .accessibilityElement(children: .contain)
    }

    // MARK: Identity

    private var identityRow: some View {
        HStack(spacing: 6) {
            Text(worktree.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            if !worktree.shortHead.isEmpty {
                Text(worktree.shortHead)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityIdentity)
    }

    private var accessibilityIdentity: String {
        var parts = [worktree.name]
        if let branch = worktree.branch, !branch.isEmpty {
            parts.append("branch \(branch)")
        } else {
            parts.append("detached, not on a branch")
        }
        if !worktree.shortHead.isEmpty { parts.append("commit \(worktree.shortHead)") }
        if worktree.is_main { parts.append("your main checkout") }
        if worktree.is_locked { parts.append("locked") }
        if worktree.is_stackpulse { parts.append("made by StackPulse") }
        return parts.joined(separator: ", ")
    }

    // MARK: Path + chips

    private var pathRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(worktree.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Path: \(worktree.path)")
            chips
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            if let branch = worktree.branch, !branch.isEmpty {
                Chip(text: branch, systemImage: "arrow.triangle.branch", tint: .secondary)
            } else {
                // Not a failure — just a worktree parked on a commit rather than
                // a branch. Worth naming, because commits made here are easy to
                // lose track of.
                Chip(text: "detached", systemImage: "arrow.triangle.branch", tint: .secondary)
            }
            if worktree.is_main {
                Chip(text: "main checkout", systemImage: "house.fill", tint: .accentColor)
            }
            if worktree.is_locked {
                Chip(text: "locked", systemImage: "lock.fill", tint: .secondary)
            }
            if worktree.is_stackpulse {
                Chip(text: "made by StackPulse", systemImage: "sparkles", tint: .blue)
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    // MARK: Actions

    private var actionsRow: some View {
        HStack(spacing: 8) {
            // The point of the whole panel: land a shell in the isolated copy so
            // the user can start an agent there. `pwd` runs nothing of
            // consequence — it just proves where you are.
            Button {
                CommandRunner.runInTerminal(command: "pwd", cwd: worktree.path)
            } label: {
                Label("Open in Terminal", systemImage: "terminal")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.glass)
            .help("Open a Terminal window in \(worktree.path) — this is where you'd start an agent. It runs nothing but `pwd`.")
            .accessibilityLabel("Open \(worktree.name) in Terminal")

            Button {
                revealInFinder(worktree.path)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.glass)
            .help("Show \(worktree.path) in Finder")
            .accessibilityLabel("Reveal \(worktree.name) in Finder")

            Button {
                copyPath()
            } label: {
                Label(copied ? "Copied" : "Copy path",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.glass)
            .help("Copy the path to the clipboard — copying runs nothing:\n\(worktree.path)")
            .accessibilityLabel(copied ? "Path copied" : "Copy path")

            if canRemove {
                Button(action: onRemove) {
                    Label("Remove…", systemImage: "trash")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.glass(tint: .red))
                .help("Delete this worktree directory. Asks you to confirm first, then runs in a visible Terminal window. This deletes files on disk.")
                .accessibilityLabel("Remove worktree \(worktree.name)")
                .accessibilityHint("Opens a confirmation. Removing deletes the directory from disk.")
            }

            Spacer(minLength: 0)
        }
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copyPath() {
        CommandRunner.copy(worktree.path)
        copied = true
        Task { try? await Task.sleep(nanoseconds: 1_400_000_000); copied = false }
    }
}
