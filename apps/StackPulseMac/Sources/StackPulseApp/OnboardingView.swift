import SwiftUI

// MARK: - First-run onboarding
//
// StackPulse has three surfaces (menu-bar readout, main window, edge sidebar)
// and none of them announce themselves — and its best sections stay empty until
// the user points it at a folder. So this sheet does exactly two jobs and then
// gets out of the way: it states the trust story plainly (everything is read
// locally, costs are estimates), and it gets the first folder added while the
// user is still here to click the button.
//
// Deliberately skippable at every step. Nothing here is required for the app to
// work, so a user who'd rather poke around first must never feel trapped —
// Escape and Skip both leave immediately, from any step.
//
// The presenter owns dismissal; this view only reports via `onFinish`.

struct OnboardingView: View {
    /// Called when the flow finishes **and** when it's skipped, so the presenter
    /// can dismiss the sheet. `onboarding.completed` is already `true` by then —
    /// the caller doesn't have to remember to set it.
    var onFinish: () -> Void

    @EnvironmentObject var store: SnapshotStore
    @AppStorage("onboarding.completed") private var completed = false
    @State private var step: Step = .welcome

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The pages, in order. `rawValue` drives Back/Next, so the order here is the
    /// only place the sequence is defined.
    private enum Step: Int, CaseIterable, Identifiable {
        case welcome
        case projects
        case tour
        case done

        var id: Int { rawValue }
    }

    var body: some View {
        ZStack {
            WindowBackdrop().ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView(.vertical) {
                    stepContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 26)
                        .padding(.vertical, 6)
                }
                .frame(maxHeight: .infinity)
                footer
            }
        }
        .frame(width: 640, height: 480)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Skip") { skip() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Skip setup")
                .help("Close this and explore on your own — you can add folders any time in Projects.")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { back() } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.glass)
            .disabled(step == .welcome)

            Spacer(minLength: 8)
            stepIndicator
            Spacer(minLength: 8)

            Button { advance() } label: {
                Label(
                    step == .done ? "Get started" : "Next",
                    systemImage: step == .done ? "checkmark" : "chevron.right"
                )
                .font(.callout.weight(.semibold))
            }
            .buttonStyle(.glass(tint: .accentColor, prominent: true))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// Dots + a spelled-out count — the dots alone would make position a
    /// colour-only signal, so the text carries it too (and VoiceOver reads one
    /// element, not four anonymous circles).
    private var stepIndicator: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(Step.allCases) { s in
                    let isOn = s == step
                    Circle()
                        .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.32))
                        .frame(width: isOn ? 8 : 6, height: isOn ? 8 : 6)
                }
            }
            Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    // MARK: Pages

    @ViewBuilder
    private var stepContent: some View {
        Group {
            switch step {
            case .welcome: welcomePage
            case .projects: projectsPage
            case .tour: tourPage
            case .done: donePage
            }
        }
        .id(step)
        .transition(.opacity)
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageIcon("waveform.path.ecg", tint: .accentColor)

            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to StackPulse")
                    .font(.title2.weight(.semibold))
                Text("It watches the AI coding tools you already use on this Mac, and helps you run your projects.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                FactRow(
                    systemImage: "lock.shield",
                    tint: .green,
                    text: "**Everything is read locally on this Mac. Nothing is uploaded.** StackPulse reads the logs your AI tools already write here."
                )
                FactRow(
                    systemImage: "dollarsign.circle",
                    tint: .orange,
                    text: "**Costs are estimates**, worked out from public list prices — not the amounts you were actually billed. Treat them as a guide."
                )
                FactRow(
                    systemImage: "hand.raised",
                    tint: .blue,
                    text: "You choose which folders it may look at, and you can remove them later."
                )
            }
            .glassCard(padding: 16)

            HStack(spacing: 6) {
                Chip(text: "Local-only", systemImage: "lock.shield", tint: .green)
                Chip(text: "Estimates, not bills", systemImage: "dollarsign.circle", tint: .orange)
                Spacer(minLength: 0)
            }
        }
    }

    private var projectsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageIcon("folder.badge.plus", tint: .accentColor)

            VStack(alignment: .leading, spacing: 6) {
                Text("Add your projects")
                    .font(.title2.weight(.semibold))
                Text("Pick a single project, **or a parent folder with several projects inside it — StackPulse finds the projects in it.** This is what fills Launcher, Projects, and Advisor.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                Button { store.addRoot() } label: {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.glass(tint: .accentColor, prominent: true))
                .help("Choose a folder — a single project, or a parent folder of several")

                rootsConfirmation
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(padding: 16)

            Text("You can skip this and add folders any time from Projects.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Live proof that the picker did something — an empty state here is the most
    /// common place a first run silently stalls.
    @ViewBuilder
    private var rootsConfirmation: some View {
        if store.approvedRoots.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("No folders yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(rootsSummary)
                        .font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if store.isScanningProjects {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Looking inside…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var tourPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What's here")
                    .font(.title2.weight(.semibold))
                Text("Six sections in the sidebar. Each answers one question.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 11) {
                ForEach(MainSection.primary) { section in
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: section.systemImage)
                            .font(.callout)
                            .foregroundStyle(.tint)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.title)
                                .font(.subheadline.weight(.semibold))
                            Text(blurb(for: section))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .glassCard(padding: 16)
        }
    }

    private var donePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageIcon("checkmark.seal.fill", tint: .green)

            VStack(alignment: .leading, spacing: 6) {
                Text("That's it")
                    .font(.title2.weight(.semibold))
                Text("StackPulse lives in your menu bar and keeps reading locally while you work.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                ShortcutRow(
                    systemImage: "sidebar.right",
                    keys: "⌥⌘S",
                    text: "Opens the edge sidebar — a slim always-there panel at the side of your screen."
                )
                ShortcutRow(
                    systemImage: "gearshape",
                    keys: "⌘,",
                    text: "Settings — refresh cadence, notifications, how costs are estimated, and what's allowed to touch the network."
                )
            }
            .glassCard(padding: 16)

            Text("Nothing you saw here is permanent — folders, alerts, and cadence are all editable later.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pieces

    private func pageIcon(_ name: String, tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 34))
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }

    /// The tour's one-liners. Deliberately shorter and plainer than each
    /// section's own `summary`, which is written for someone already inside it.
    private func blurb(for section: MainSection) -> String {
        switch section {
        case .home: return "Today's spend, your live limits, and anything that needs you."
        case .launcher: return "Launch any web app in one tap, or copy a one-paste command."
        case .usage: return "Where your tokens and money go."
        case .missions: return "What your AI agents are working on right now."
        case .advisor: return "Things you could improve, gathered in one place."
        case .projects: return "Remembered commands, past runs, and live dev servers."
        default: return section.summary
        }
    }

    private var rootsSummary: String {
        let folders = store.approvedRoots.count
        let projects = store.projects.count
        return "\(folders) folder\(folders == 1 ? "" : "s") added — "
            + "\(projects) project\(projects == 1 ? "" : "s") found"
    }

    // MARK: Navigation

    private func advance() {
        if let next = Step(rawValue: step.rawValue + 1) {
            go(to: next)
        } else {
            finish()
        }
    }

    private func back() {
        if let previous = Step(rawValue: step.rawValue - 1) {
            go(to: previous)
        }
    }

    private func go(to next: Step) {
        if reduceMotion {
            step = next
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                step = next
            }
        }
    }

    /// Finishing and skipping are the same commitment: the user has seen this
    /// once, so don't show it again either way.
    private func finish() {
        completed = true
        onFinish()
    }

    private func skip() {
        completed = true
        onFinish()
    }
}

// MARK: - Rows

/// One plain-language fact with a leading icon. Takes a `LocalizedStringKey` so
/// call sites can bold the load-bearing clause inline.
private struct FactRow: View {
    let systemImage: String
    let tint: Color
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundStyle(tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A keyboard shortcut and what it opens. The keys are rendered as a chip so
/// they read as a key, not as prose.
private struct ShortcutRow: View {
    let systemImage: String
    let keys: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.callout)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Chip(text: keys, systemImage: "command", tint: .accentColor)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(keys). \(text)")
    }
}
