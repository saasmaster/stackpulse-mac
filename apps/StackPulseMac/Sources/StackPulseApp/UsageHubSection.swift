import SwiftUI

/// Usage — the single "where my tokens and money go" surface. One sub-switcher
/// over three views that used to be separate nav rows: the per-model/-window
/// **Breakdown**, the long-run **Trends**, and a shareable **Report**. Each child
/// stays the single owner of its own rendering; this shell just picks which one
/// is showing (so the nav shrinks without moving any logic).
struct UsageHubSection: View {
    enum Tab: String, CaseIterable, Hashable {
        case breakdown, byProject, trends, report

        var label: String {
            switch self {
            case .breakdown: return "Breakdown"
            case .byProject: return "By Project"
            case .trends: return "Trends"
            case .report: return "Report"
            }
        }
        var icon: String {
            switch self {
            case .breakdown: return "chart.bar"
            case .byProject: return "folder"
            case .trends: return "chart.xyaxis.line"
            case .report: return "doc.text"
            }
        }
    }

    @AppStorage("usageHub.tab") private var tabRaw = Tab.breakdown.rawValue
    private var tab: Tab {
        get { Tab(rawValue: tabRaw) ?? .breakdown }
        nonmutating set { tabRaw = newValue.rawValue }
    }

    var body: some View {
        HubShell(
            segments: Tab.allCases.map { GlassSegment(value: $0, systemImage: $0.icon, label: $0.label) },
            selection: Binding(get: { tab }, set: { tab = $0 })
        ) {
            switch tab {
            case .breakdown: UsageSection()
            case .byProject: ProjectUsageSection()
            case .trends: TrendsSection()
            case .report: ReportsSection()
            }
        }
    }
}

// MARK: - Hub shell

/// A reusable "sub-switcher over a child section" container: a pinned frosted
/// segmented control on top, the selected child section (which brings its own
/// header/scroll/backdrop) filling the rest. Used by the Usage and Advisor hubs
/// to fold several former nav rows into one deep section.
struct HubShell<Value: Hashable, Content: View>: View {
    let segments: [GlassSegment<Value>]
    @Binding var selection: Value
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            GlassSegmentedControl(segments: segments, selection: $selection)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 10)
            content()
        }
        .background(WindowBackdrop().ignoresSafeArea())
    }
}
