import SwiftUI

/// The dedicated Settings window's content: a compact tab switcher between the
/// app's configuration ("Settings") and provider **Integrations**. Both are the
/// same views the main window used to host — they now live here, in their own
/// window, away from the data dashboards.
struct SettingsWindowView: View {
    @EnvironmentObject var store: SnapshotStore
    @EnvironmentObject var theme: ThemeManager
    @State private var tab: SettingsTab = .settings

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases) { t in
                    Label(t.title, systemImage: t.systemImage).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().opacity(0.5)

            switch tab {
            case .settings: SettingsSection()
            case .integrations: IntegrationsSection()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(theme.colorScheme)
        .background(WindowBackdrop().ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(for: .stackPulseSelectSettingsTab)) { note in
            if let t = note.object as? SettingsTab { tab = t }
        }
    }
}
