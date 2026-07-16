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
            VStack(alignment: .leading, spacing: 18) {
                if !store.activeMissions.isEmpty || !store.activeAlerts.isEmpty {
                    liveStrip
                }
                budgetStrip
                OverviewDashboard(snapshot: snapshot)
            }
        }
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
