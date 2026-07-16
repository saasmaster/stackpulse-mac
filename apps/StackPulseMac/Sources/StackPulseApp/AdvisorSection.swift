import SwiftUI

/// Advisor — the single "what could I improve?" surface. It unifies the three
/// recommendation views that used to be separate nav rows, because they're all
/// the same job (advice grounded in your own local data), just different domains:
/// **Efficiency** (cost/cache insights), **Projects** (the repository radar), and
/// **Dependencies** (stack health & security). One place to look instead of three.
struct AdvisorSection: View {
    enum Tab: String, CaseIterable, Hashable {
        case efficiency, projects, dependencies

        var label: String {
            switch self {
            case .efficiency: return "Efficiency"
            // Deliberately NOT "Projects": that word already names a primary
            // section (folder management). Reusing it here made the same label
            // mean two different things depending on where you were.
            case .projects: return "Repo Health"
            case .dependencies: return "Dependencies"
            }
        }
        var icon: String {
            switch self {
            case .efficiency: return "lightbulb.max"
            case .projects: return "sparkle.magnifyingglass"
            case .dependencies: return "shield.lefthalf.filled"
            }
        }
    }

    @AppStorage("advisor.tab") private var tabRaw = Tab.efficiency.rawValue
    private var tab: Tab {
        get { Tab(rawValue: tabRaw) ?? .efficiency }
        nonmutating set { tabRaw = newValue.rawValue }
    }

    var body: some View {
        HubShell(
            segments: Tab.allCases.map { GlassSegment(value: $0, systemImage: $0.icon, label: $0.label) },
            selection: Binding(get: { tab }, set: { tab = $0 })
        ) {
            switch tab {
            case .efficiency: InsightsSection()
            case .projects: DiscoverSection()
            case .dependencies: StackHealthSection()
            }
        }
    }
}
