import SwiftUI

/// Integrations (also the Diagnostics surface): per-provider identity, health,
/// detection chips, detected version, the capability matrix, and notes.
struct IntegrationsSection: View {
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        SectionScaffold(section: .integrations) { snapshot in
            VStack(alignment: .leading, spacing: 16) {
                capabilityLegend
                ForEach(snapshot.providers) { provider in
                    IntegrationCard(provider: provider)
                        .environmentObject(store)
                }
            }
        }
    }

    private var capabilityLegend: some View {
        HStack(spacing: 14) {
            legendDot(.green, "Supported")
            legendDot(.orange, "Unavailable")
            legendDot(.gray, "Unsupported")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}

struct IntegrationCard: View {
    let provider: ProviderUsage
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            identityRow
            detectionChips
            if let balance = provider.balance {
                ProviderBalanceLabel(balance: balance)
            }
            if !provider.capabilities.isEmpty {
                Divider().opacity(0.4)
                capabilityMatrix
            }
            if !provider.notes.isEmpty {
                Divider().opacity(0.4)
                notes
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16)
    }

    // MARK: Identity + health

    private var identityRow: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(color: SPStatus.healthColor(provider.health), size: 10)
                .padding(.top, 5)
                .accessibilityLabel(SPStatus.healthLabel(provider.health))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(provider.display_name)
                        .font(.title3.weight(.semibold))
                    Text(provider.provider)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(SPStatus.healthLabel(provider.health))
                    .font(.caption)
                    .foregroundStyle(SPStatus.healthColor(provider.health))
            }
            Spacer()
        }
    }

    // MARK: Detection chips

    private var detectionChips: some View {
        HStack(spacing: 6) {
            Chip(text: provider.installed ? "Installed" : "Not installed",
                 systemImage: provider.installed ? "checkmark.circle" : "xmark.circle",
                 tint: provider.installed ? .green : .secondary)

            if provider.balance != nil {
                Chip(text: "Connected", systemImage: "checkmark.seal.fill", tint: .green)
            } else {
                Chip(text: store.isAuthenticated(provider) ? "Authenticated" : "No auth",
                     systemImage: store.isAuthenticated(provider) ? "checkmark.seal" : "seal",
                     tint: store.isAuthenticated(provider) ? .green : .secondary)
            }

            if let plan = provider.plan_hint {
                Chip(text: "Plan: \(plan.capitalized)", systemImage: "creditcard", tint: .cyan)
            }

            if let version = provider.detected_version {
                Chip(text: "v\(version)", systemImage: "number", tint: .secondary)
            } else {
                Chip(text: "Version unknown", systemImage: "questionmark", tint: .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Capability matrix

    private var capabilityMatrix: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Capabilities")
                .font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 320),
                                         spacing: 6, alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(provider.capabilities, id: \.self) { pair in
                    CapabilityChip(name: pair.first ?? "",
                                   state: pair.count > 1 ? pair[1] : "")
                }
            }
        }
    }

    // MARK: Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(provider.notes, id: \.self) { note in
                Label(note, systemImage: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A single capability, colored by its state.
struct CapabilityChip: View {
    let name: String
    let state: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(tint)
            Text(SPStatus.healthLabel(name))
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(stateLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.12))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(SPStatus.healthLabel(name)): \(stateLabel)")
    }

    private var tint: Color {
        switch state {
        case "supported": return .green
        case "unavailable": return .orange
        case "unsupported": return .gray
        default: return .secondary
        }
    }

    private var symbol: String {
        switch state {
        case "supported": return "checkmark.circle.fill"
        case "unavailable": return "exclamationmark.circle.fill"
        case "unsupported": return "minus.circle.fill"
        default: return "questionmark.circle.fill"
        }
    }

    private var stateLabel: String {
        state.isEmpty ? "Unknown" : SPStatus.healthLabel(state)
    }
}
