import SwiftUI

/// User appearance preference. `system` follows macOS; the others force a scheme.
enum AppearancePref: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Icons mirror the reference pill: sun (light), moon (dark), horizon (auto).
    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    var segment: GlassSegment<AppearancePref> {
        GlassSegment(value: self, systemImage: systemImage, label: label)
    }
}

/// Holds the appearance preference and persists it. Apply its `colorScheme`
/// with `.preferredColorScheme(...)` on each root hosting view (popover, main
/// window, edge sidebar) so the whole app honors the choice.
@MainActor
final class ThemeManager: ObservableObject {
    private static let key = "stackpulse.appearance"

    @Published var pref: AppearancePref {
        didSet { UserDefaults.standard.set(pref.rawValue, forKey: Self.key) }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? ""
        pref = AppearancePref(rawValue: raw) ?? .system
    }

    var colorScheme: ColorScheme? { pref.colorScheme }

    static let allSegments: [GlassSegment<AppearancePref>] =
        AppearancePref.allCases.map(\.segment)
}
