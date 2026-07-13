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
                OverviewDashboard(snapshot: snapshot)
            }
        }
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
