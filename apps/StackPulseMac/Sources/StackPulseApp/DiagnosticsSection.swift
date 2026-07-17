import AppKit
import SwiftUI

/// Diagnostics — "is StackPulse working, and if not, exactly why."
///
/// Unlike the other sections this must render **without** a snapshot: no data yet
/// is itself a diagnosable state, so it does not use `SectionScaffold` (which gates
/// on a snapshot) and builds its own scroll layout.
///
/// The report is computed on appear and on an explicit refresh, never in `body`:
/// `Diagnostics.build` needs `now`, and sampling the clock during render is the
/// one thing this codebase's lint forbids. The action captures `Date()`; the body
/// only reads the stored report.
struct DiagnosticsSection: View {
    @EnvironmentObject var store: SnapshotStore
    @State private var report: Diagnostics.Report?
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: MainSection.diagnostics.title,
                              summary: MainSection.diagnostics.summary)

                if let report {
                    overall(report)
                    if !report.issues.isEmpty { issuesCard(report) }
                    ForEach(report.groups) { group in
                        groupCard(group)
                    }
                    footer(report)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WindowBackdrop().ignoresSafeArea())
        .onAppear(perform: rebuild)
        // Rebuild when any signal the report reads changes, so it never shows a
        // verdict from before the last scan.
        .onChange(of: store.lastUpdated) { _, _ in rebuild() }
        .onChange(of: store.liveLimitsError) { _, _ in rebuild() }
        .onChange(of: store.notificationsAuthorized) { _, _ in rebuild() }
    }

    // MARK: Overall banner

    @ViewBuilder private func overall(_ report: Diagnostics.Report) -> some View {
        let worst = report.worstStatus
        HStack(spacing: 12) {
            Image(systemName: report.allClear ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(color(worst))
            VStack(alignment: .leading, spacing: 2) {
                Text(report.allClear ? "Everything checks out"
                     : "\(report.issues.count) thing\(report.issues.count == 1 ? "" : "s") to look at")
                    .font(.title3.weight(.semibold))
                Text(report.allClear
                     ? "Every check that could be verified passed."
                     : "The most important ones are listed first, each with a fix.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: rebuild) {
                Label("Re-run", systemImage: "arrow.clockwise").font(.caption.weight(.medium))
            }
            .buttonStyle(.glass)
            Button(action: copyBundle) {
                Label(copied ? "Copied" : "Copy support bundle",
                      systemImage: copied ? "checkmark" : "doc.on.clipboard")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.glass)
            .help("Copy a redacted text report — versions, statuses, and repair steps only. No credentials, tokens, prompts, source, or log contents; paths shown as ~.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 18, tint: report.allClear ? .green : color(worst), padding: 16)
    }

    // MARK: Issues

    private func issuesCard(_ report: Diagnostics.Report) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs attention", systemImage: "wrench.and.screwdriver.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            ForEach(report.issues) { check in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        StatusDot(color: color(check.status), size: 8)
                        Text(check.label).font(.subheadline.weight(.medium))
                        Text(check.status.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(color(check.status))
                    }
                    Text(check.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let repair = check.repair {
                        Label(repair, systemImage: "arrow.turn.down.right")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .labelStyle(.titleAndIcon)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 16, tint: .orange, padding: 14)
    }

    // MARK: Group cards

    private func groupCard(_ group: Diagnostics.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(group.checks) { check in
                HStack(alignment: .top, spacing: 8) {
                    StatusDot(color: color(check.status), size: 7)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(check.label).font(.subheadline.weight(.medium))
                            Text(check.status.label)
                                .font(.caption2)
                                .foregroundStyle(color(check.status))
                        }
                        Text(check.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(check.label): \(check.status.label). \(check.detail)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
    }

    private func footer(_ report: Diagnostics.Report) -> some View {
        Text("Checked \(Format.relative(report.generatedAt)) · this screen reads state the app already gathered — it starts no new network calls and reads no secrets.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Wiring

    private func color(_ status: Diagnostics.Status) -> Color {
        switch status {
        case .problem: return .red
        case .warning: return .orange
        case .ok: return .green
        case .info: return .secondary
        case .notApplicable: return .secondary
        }
    }

    /// Fold the store's current state into `Diagnostics.Inputs`. `Date()` is read
    /// HERE (an action, not `body`), satisfying the no-clock-in-render rule.
    private func rebuild() {
        report = Diagnostics.build(currentInputs(now: Date()))
    }

    private func copyBundle() {
        let report = self.report ?? Diagnostics.build(currentInputs(now: Date()))
        let text = SupportBundle.build(report: report, home: NSHomeDirectory(), now: Date())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }

    /// Health strings that mean "detected but not working right". Green
    /// (fully_supported), cyan (partial/untested), and gray (not_detected) are not
    /// degradation — the first two work, the last isn't installed.
    private static let degradedHealth: Set<String> = [
        "user_action_required", "authentication_changed",
        "metrics_unavailable", "session_schema_changed", "endpoint_changed",
        "temporarily_broken", "discontinued",
    ]

    private func currentInputs(now: Date) -> Diagnostics.Inputs {
        let snapshot = store.snapshot
        let providers = snapshot?.providers ?? []
        let installed = providers.filter(\.installed)
        let authed = installed.filter { $0.authenticated || store.isAuthenticated($0) }
        let degraded = installed.filter { Self.degradedHealth.contains($0.health) }

        let canaries = snapshot?.canaries ?? []
        let drifted = canaries.filter { $0.status == "drifted" }
        let okCanaries = canaries.filter { $0.status == "ok" }
        let noData = canaries.filter { $0.status == "no_data" }

        // Claude live limits currently have data if the Claude provider carries a
        // non-empty limits array in the snapshot the store merged.
        let claudeHasLimits = providers.first { $0.provider == "claude" }
            .map { !$0.limits.isEmpty } ?? false

        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"

        return Diagnostics.Inputs(
            appVersion: appVersion,
            coreVersion: CoreBridge.coreVersion(),
            protocolVersion: snapshot?.protocol_version.text ?? "—",
            lastUpdated: store.lastUpdated,
            lastError: store.lastError,
            refreshModeLabel: store.refreshMode.summary,
            providersDetected: installed.count,
            providersAuthenticated: authed.count,
            providersDegraded: degraded.count,
            liveLimitsEnabled: store.liveLimitsEnabled,
            liveLimitsHaveData: claudeHasLimits,
            liveLimitsError: store.liveLimitsError,
            liveLimitsFixIsRenewLogin: store.liveLimitsRecovery == .renewLoginInTerminal,
            canaryDrifted: drifted.count,
            canaryOk: okCanaries.count,
            canaryNoData: noData.count,
            driftDetail: drifted.first?.detail,
            notificationsEnabled: store.notificationsEnabled,
            notificationsAuthorized: store.notificationsAuthorized,
            keepAwake: store.keepAwake,
            approvedRootCount: store.approvedRoots.count,
            projectCount: store.projects.count,
            projectsError: store.projectsError,
            now: now
        )
    }
}
