import SwiftUI
import AppKit

// MARK: - Services section (main window)
//
// Locally-running dev servers detected by the Rust core via listening TCP ports,
// matched to your projects. Grouped by project, each a glass card with a live
// green pulse, a kind glyph, the command + port, and — when a URL is known —
// Open / Copy affordances. Read-only in v1 (no process control).
//
// Data contract: `store.services` ([RunningService]), `store.rescanServices()`,
// `store.isScanningServices`, `store.servicesUpdatedAt`.

struct ServicesSection: View {
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        SectionScaffold(section: .services) { _ in
            if store.services.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    toolbar
                    ForEach(groups, id: \.0) { title, items in
                        groupBlock(title: title.name, icon: title.icon, items: items)
                    }
                }
            }
        }
        .onAppear { store.rescanServices() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label(
                "\(store.services.count) running",
                systemImage: "bolt.horizontal.circle"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

            if let updated = store.servicesUpdatedAt {
                Text("updated \(Format.relative(updated))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                store.rescanServices()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.glass(tint: .accentColor))
            .disabled(store.isScanningServices)
            .help("Scan local ports again")
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            if store.isScanningServices { ProgressView() }
            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(store.isScanningServices ? "Looking for running services…" : "No running dev servers found")
                .font(.headline)
            Text("StackPulse lists processes listening on local ports and matches them to your projects.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .glassCard(padding: 24)
    }

    // MARK: Grouping
    //
    // One group per distinct project (first-seen order preserved), then a trailing
    // "Other processes" group for services with no matched project.

    private struct GroupKey: Hashable {
        let name: String
        let icon: String
    }

    private var groups: [(GroupKey, [RunningService])] {
        var order: [String] = []
        var buckets: [String: [RunningService]] = [:]
        for svc in store.services {
            let key = svc.project_name ?? Self.otherKey
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(svc)
        }
        // Named projects first (in first-seen order), "Other processes" last.
        let named = order.filter { $0 != Self.otherKey }
        let ordered = named + (order.contains(Self.otherKey) ? [Self.otherKey] : [])
        return ordered.map { key in
            let isOther = key == Self.otherKey
            let g = GroupKey(
                name: isOther ? "Other processes" : key,
                icon: isOther ? "square.stack.3d.up" : "folder"
            )
            return (g, buckets[key] ?? [])
        }
    }

    private static let otherKey = "\u{1}__other__"

    private func groupBlock(title: String, icon: String, items: [RunningService]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(items.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { svc in
                ServiceCard(service: svc)
            }
        }
    }
}

// MARK: - Service card

/// One running service: a live green pulse, the kind glyph, the command with its
/// port chip and kind chip, a secondary line (cwd or pid), and — when the core
/// resolved a URL — Open (in the default browser) and Copy affordances.
struct ServiceCard: View {
    let service: RunningService

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ServicePulseDot()
                .padding(.top, 2)

            Image(systemName: Self.icon(for: service.kind))
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(service.command)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Chip(text: "port \(service.port)", systemImage: "number", tint: .accentColor)
                    if let kind = service.kind, !kind.isEmpty {
                        Chip(text: kind, systemImage: "tag", tint: .secondary)
                    }
                }

                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if let url = service.url, !url.isEmpty {
                VStack(alignment: .trailing, spacing: 6) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open", systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.glass(tint: .accentColor))
                    .help("Open \(url) in your browser")

                    Button {
                        copy(url)
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Copy \(url)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 16, tint: .green, padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Derived

    private var secondaryLine: String {
        if let cwd = service.cwd, !cwd.isEmpty {
            return (cwd as NSString).abbreviatingWithTildeInPath
        }
        return "pid \(service.pid)"
    }

    private var accessibilityText: String {
        var parts = ["\(service.command), running on port \(service.port)"]
        if let kind = service.kind, !kind.isEmpty { parts.append(kind) }
        parts.append(secondaryLine)
        if let url = service.url, !url.isEmpty { parts.append(url) }
        return parts.joined(separator: ". ")
    }

    // MARK: Actions

    private func openURL(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) { copied = false }
        }
    }

    // MARK: Kind → SF Symbol
    //
    // Maps the core's runtime `kind` string to a representative glyph, defaulting
    // to a generic server rack for anything unrecognized (forward-compatible).
    static func icon(for kind: String?) -> String {
        switch (kind ?? "").lowercased() {
        case "vite": return "bolt.fill"
        case "next", "nextjs", "next.js": return "n.square"
        case "node", "nodejs": return "shippingbox"
        case "python", "py": return "ladybug"
        case "ruby": return "diamond"
        case "php": return "chevron.left.forwardslash.chevron.right"
        case "docker": return "shippingbox.fill"
        case "postgres", "postgresql", "mysql", "redis": return "cylinder.split.1x2"
        default: return "server.rack"
        }
    }
}

// MARK: - Live pulse dot

/// A green "running" dot with a soft ring pulsing outward — a subtle heartbeat.
/// Falls back to a plain dot under Reduce Motion. Color is never the sole signal:
/// every call site pairs it with the "running" text in the card's a11y label.
private struct ServicePulseDot: View {
    var size: CGFloat = 9

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .stroke(Color.green.opacity(0.6), lineWidth: 1.5)
                    .frame(width: size, height: size)
                    .scaleEffect(pulsing ? 2.3 : 1)
                    .opacity(pulsing ? 0 : 0.7)
            }
            StatusDot(color: .green, size: size)
        }
        .frame(width: size + 12, height: size + 12)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
        .accessibilityHidden(true)
    }
}
