import SwiftUI

/// Home — the single "what's happening right now" surface. Answers the question
/// you open the app with: how much am I spending, where are my limits, what are
/// my agents doing, and does anything need me? It leads with a live strip of
/// active sessions and needs-attention, then the full spend/limits dashboard
/// (``OverviewDashboard``, shared with the Overview pane so it's defined once).
struct HomeSection: View {
    @EnvironmentObject var store: SnapshotStore
    /// Jump to another primary section (e.g. tapping "active now" opens Missions).
    var onOpen: (MainSection) -> Void = { _ in }

    var body: some View {
        SectionScaffold(section: .home) { snapshot in
            if isColdStart(snapshot) {
                // A stranger's very first run. Show a warm orientation instead of a
                // wall of "not detected" cards under an all-dashes scoreboard.
                ColdStartHero()
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    if !store.activeMissions.isEmpty || !store.activeAlerts.isEmpty {
                        liveStrip
                    }
                    budgetStrip
                    OverviewDashboard(snapshot: snapshot)
                }
            }
        }
    }

    /// The true cold start: nothing detected on this Mac and no folders added yet.
    /// Home would otherwise render a grid of "not detected" provider cards beneath a
    /// header of dashes — honest, but a dead end that never says what to do. When
    /// both are empty we replace that with a truthful, actionable welcome. As soon
    /// as one real signal exists (a detected tool, or an added folder) the normal
    /// dashboard takes over.
    private func isColdStart(_ snapshot: UsageSnapshot) -> Bool {
        snapshot.installedProviders.isEmpty && store.approvedRoots.isEmpty
    }

    /// Spend-budget meters, shown only once a budget is actually set (no budget →
    /// no nag). Each pairs the bar with the spent/limit figures and a percent, so
    /// the colour is never the only signal.
    @ViewBuilder private var budgetStrip: some View {
        let daily = store.dailyBudgetFraction
        let monthly = store.monthlyBudgetFraction
        if daily != nil || monthly != nil {
            HStack(alignment: .top, spacing: 14) {
                if let f = daily {
                    budgetMeter("Today", spent: store.snapshot?.totalTodayCost,
                                budget: store.dailyBudgetUSD, fraction: f)
                }
                if let f = monthly {
                    budgetMeter("30 days", spent: store.snapshot?.total30Cost,
                                budget: store.monthlyBudgetUSD, fraction: f)
                }
            }
        }
    }

    private func budgetMeter(_ label: String, spent: Double?, budget: Double?,
                             fraction: Double) -> some View {
        let pct = Int((fraction * 100).rounded())
        let tint: Color = fraction >= 1 ? .red : (fraction * 100 >= store.budgetWarnPercent ? .orange : .green)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(label.uppercased()) BUDGET")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Format.usd(spent)) of \(Format.usd(budget))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("· \(pct)%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
            }
            // Cap the bar at full; the percent text carries any overshoot.
            MeterBar(fraction: min(fraction, 1), tint: tint, glowsWhenHigh: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) budget: \(pct) percent of \(Format.usd(budget)) estimated spent")
    }

    /// A two-column "right now" strip: active AI sessions (→ Missions) and
    /// anything needing attention (→ the Needs-Attention pane). Either side is
    /// omitted when empty; the whole strip hides when both are.
    private var liveStrip: some View {
        HStack(alignment: .top, spacing: 14) {
            if !store.activeMissions.isEmpty {
                ActiveNowBlock(missions: store.activeMissions, maxItems: 3,
                               onTap: { onOpen(.missions) })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !store.activeAlerts.isEmpty {
                NeedsAttentionBlock(alerts: store.activeAlerts, maxItems: 3,
                                    onTap: { onOpen(.alerts) })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Cold-start welcome

/// The first-run orientation shown on Home when StackPulse has found no AI tools
/// and no folders yet. Its job is to turn a blank scoreboard into a clear next
/// step: it names the two truthful ways data arrives (use an AI tool → it reads
/// the local logs; add a folder → it fills the project surfaces) and offers the
/// one action worth taking now. It never shows a fabricated number — there is no
/// data yet, and it says so.
struct ColdStartHero: View {
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("StackPulse is ready — there's just nothing to show yet")
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("It hasn't found any AI coding tools on this Mac, and you haven't added a project folder. Here's how this page fills up — everything is read locally on this Mac, and nothing is uploaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                pathRow(
                    icon: "sparkle.magnifyingglass", tint: .cyan,
                    title: "Use an AI coding tool",
                    detail: "Claude Code, Codex, Copilot, Cursor and more. StackPulse reads the session logs they already write on this Mac and fills in Usage, Missions, and today's spend. Nothing to connect — it picks them up automatically as you work."
                )
                Divider().opacity(0.4)
                pathRow(
                    icon: "folder.badge.plus", tint: .accentColor,
                    title: "Add a project folder",
                    detail: "Point StackPulse at your code — a single project, or a parent folder with several inside — and it fills Launcher, Projects, and Advisor with your commands, runnable apps, and stack health."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(padding: 18)

            HStack(spacing: 10) {
                Button { store.addRoot() } label: {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.glass(tint: .accentColor, prominent: true))
                .help("Choose a folder — a single project, or a parent folder of several")

                // Let a curious first-run visitor SEE the product populated, with
                // sample data that is loudly labeled as such (DemoBanner) and one
                // tap to leave. Off by default; this is the only opt-in.
                Button { store.demoMode = true } label: {
                    Label("See it with sample data", systemImage: "wand.and.stars")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.glass)
                .help("Fill StackPulse with clearly-labeled sample data so you can see how it looks with activity. Turn it off any time.")
            }

            Label("Costs shown anywhere in StackPulse are estimates from public list prices, not the amount you were billed. This page updates itself the moment there's real activity to show.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pathRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A compact, truthful line for the deep spend surfaces (Overview / Usage) when no
/// AI tool is detected yet — so they read as "here's why this is empty and what
/// fills it" rather than a silent wall of "not detected" cards. Shown only when
/// zero providers are installed; the moment one is, real numbers replace it.
struct NoProvidersDetectedNote: View {
    var body: some View {
        Label("No AI coding tools detected on this Mac yet. Start a session in one — Claude Code, Codex, Cursor and more — and StackPulse fills these numbers from its local logs automatically. Nothing to connect.",
              systemImage: "sparkle.magnifyingglass")
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
