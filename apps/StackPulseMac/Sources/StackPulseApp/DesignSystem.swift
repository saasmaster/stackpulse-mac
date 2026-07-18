import SwiftUI

// MARK: - Formatting

enum Format {
    static func tokens(_ n: UInt64) -> String {
        let d = Double(n)
        if d >= 1_000_000_000 { return String(format: "%.1fB", d / 1_000_000_000) }
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.1fk", d / 1_000) }
        return "\(n)"
    }

    static func usd(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v >= 1000 { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }

    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v) }

    /// A "times daily average" multiplier, e.g. `2.3×`.
    static func ratio(_ v: Double) -> String { String(format: "%.1f×", v) }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        let s = Int(Date().timeIntervalSince(date))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    /// Human countdown to a Unix reset time (e.g. "resets in 2h 14m").
    static func resetCountdown(_ unix: Int64?) -> String? {
        guard let unix else { return nil }
        let remaining = Int(TimeInterval(unix) - Date().timeIntervalSince1970)
        if remaining <= 0 { return "resetting…" }
        let h = remaining / 3600
        let m = (remaining % 3600) / 60
        if h > 24 { return "resets in \(h / 24)d \(h % 24)h" }
        if h > 0 { return "resets in \(h)h \(m)m" }
        return "resets in \(m)m"
    }
}

// MARK: - Status semantics (never color-only; always paired with a label)

enum SPStatus {
    /// Map an integration-health string to a semantic color.
    static func healthColor(_ health: String) -> Color {
        switch health {
        case "fully_supported": return .green
        case "partially_supported", "app_version_untested": return .cyan
        case "user_action_required", "authentication_changed": return .orange
        case "metrics_unavailable", "session_schema_changed", "endpoint_changed": return .yellow
        case "temporarily_broken", "discontinued": return .red
        case "not_detected": return .gray
        default: return .secondary
        }
    }

    /// Short human label for a health string.
    static func healthLabel(_ health: String) -> String {
        health
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Color for a live-limit usage fraction (green → amber → red).
    static func limitColor(_ percent: Double) -> Color {
        switch percent {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }
}

// MARK: - Command safety (never color-only; always paired with a text label)

/// Maps a discovered command's `safety` string to a semantic color, a short
/// human label, and an SF Symbol. The wire value is a `String` so a newer core
/// can add levels without breaking decoding; anything unknown falls back to a
/// neutral, non-alarming presentation. Every call site pairs the color with the
/// label, so safety is never communicated by color alone.
enum CommandSafety {
    static func label(_ safety: String) -> String {
        switch safety {
        case "read_only": return "Safe"
        case "local_dev": return "Dev"
        case "modifies_files": return "Writes files"
        case "installs_deps": return "Installs"
        case "changes_database": return "DB"
        case "network": return "Network"
        case "destructive": return "Destructive"
        default: return SPStatus.healthLabel(safety)   // title-cases the raw value
        }
    }

    static func color(_ safety: String) -> Color {
        switch safety {
        case "read_only": return .green
        case "local_dev": return .blue
        case "modifies_files": return .yellow
        case "installs_deps": return .orange
        case "changes_database": return .orange
        case "network": return .cyan
        case "destructive": return .red
        default: return .secondary
        }
    }

    static func icon(_ safety: String) -> String {
        switch safety {
        case "read_only": return "checkmark.shield"
        case "local_dev": return "hammer"
        case "modifies_files": return "pencil"
        case "installs_deps": return "shippingbox"
        case "changes_database": return "cylinder.split.1x2"
        case "network": return "network"
        case "destructive": return "exclamationmark.triangle.fill"
        default: return "questionmark.circle"
        }
    }

    /// Everything except a purely read-only command must be confirmed before it runs.
    static func requiresConfirmation(_ safety: String) -> Bool { safety != "read_only" }

    /// Destructive commands get the loudest, most explicit warning.
    static func isDestructive(_ safety: String) -> Bool { safety == "destructive" }
}

/// A small safety pill for a discovered command — the ``CommandSafety`` color,
/// icon, and label together (color is never the sole signal).
struct SafetyChip: View {
    let safety: String
    var body: some View {
        Chip(text: CommandSafety.label(safety),
             systemImage: CommandSafety.icon(safety),
             tint: CommandSafety.color(safety))
    }
}

// MARK: - Alert severity (icon + color are always paired with the alert title)

/// Interpreted severity of an ``Alert``. The wire value is a `String` so a newer
/// core can add levels without breaking decoding; anything unknown maps to `.info`.
/// `Comparable` by escalation, so `max()` finds the most severe alert in a set.
enum AlertSeverity: Int, Comparable, Sendable {
    case info = 0
    case warning = 1
    case critical = 2

    init(_ raw: String) {
        switch raw {
        case "critical": self = .critical
        case "warning": self = .warning
        default: self = .info
        }
    }

    static func < (lhs: AlertSeverity, rhs: AlertSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Semantic tint — always accompanied by the icon and the alert's own title,
    /// never used as the sole signal.
    var color: Color {
        switch self {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }

    var icon: String {
        switch self {
        case .critical: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .critical: return "Critical"
        case .warning: return "Warning"
        case .info: return "Info"
        }
    }
}

extension Alert {
    /// Interpreted severity (icon / color / ordering live on ``AlertSeverity``).
    var severityKind: AlertSeverity { AlertSeverity(severity) }

    /// Human label for the machine `kind` (e.g. `limit_reset_soon` → "Limit Reset Soon").
    var kindLabel: String { SPStatus.healthLabel(kind) }
}

// MARK: - Mission status (icon + color are always paired with a text label)

/// Interpreted lifecycle state of a ``Mission`` — an observed AI coding session.
/// The wire value is a `String` so a newer core can add a state without breaking
/// decoding; anything unknown maps to `.unknown`. `Comparable` by liveness so a
/// set of missions groups/sorts Active → Idle → Recent → Stalled → Unknown, and
/// `max()` finds the liveliest. Color is never the sole signal — every call site
/// pairs it with the `label` and the `icon`.
enum MissionStatus: Int, Comparable, Sendable {
    case unknown = 0
    case stalled = 1
    case recent = 2
    case idle = 3
    case active = 4

    init(_ raw: String) {
        switch raw {
        case "active": self = .active
        case "idle": self = .idle
        case "recent": self = .recent
        case "stalled": self = .stalled
        default: self = .unknown
        }
    }

    static func < (lhs: MissionStatus, rhs: MissionStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Semantic tint — always accompanied by the icon and a text label.
    var color: Color {
        switch self {
        case .active: return .green
        case .idle: return .yellow
        case .recent: return .secondary
        case .stalled: return .orange
        case .unknown: return .secondary
        }
    }

    var icon: String {
        switch self {
        case .active: return "bolt.fill"
        case .idle: return "pause.circle"
        case .recent: return "clock.arrow.circlepath"
        case .stalled: return "exclamationmark.triangle"
        case .unknown: return "questionmark.circle"
        }
    }

    var label: String {
        switch self {
        case .active: return "Active"
        case .idle: return "Idle"
        case .recent: return "Recent"
        case .stalled: return "Stalled"
        case .unknown: return "Unknown"
        }
    }
}

extension Mission {
    /// Interpreted status (icon / color / label / ordering live on ``MissionStatus``).
    var statusKind: MissionStatus { MissionStatus(status) }
}

// MARK: - Liquid glass surface

/// A frosted, layered card. Now a thin wrapper over the unified `.liquidGlass`
/// material so every existing `.glassCard()` call site inherits the refraction
/// sheen, rim light, layered shadows, and glow — while keeping the same
/// signature and Reduce-Transparency fallback.
extension View {
    func glassCard(padding: CGFloat = 12) -> some View {
        liquidGlass(cornerRadius: 16, prominence: .regular, padding: padding)
    }
}

/// A health / status indicator dot with a glossy top sheen and a soft colored
/// glow. Color is never the sole signal — call sites pair it with a label.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Circle()
            .fill(color)
            .overlay {
                if !reduceTransparency {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.55), .clear],
                                startPoint: .top, endPoint: .center
                            )
                        )
                        .blendMode(.plusLighter)
                }
            }
            .frame(width: size, height: size)
            .shadow(color: color.opacity(reduceTransparency ? 0 : 0.55), radius: 2.5)
    }
}

// MARK: - Demo-mode banner

/// The "this isn't real" guarantee for demo mode. Shown on every surface that
/// renders sample data, so fabricated numbers can never be mistaken for the
/// user's own — the one hard rule of a demo mode in an app whose whole value is
/// honest reporting. Includes a one-tap way out.
struct DemoBanner: View {
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        if store.demoMode {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sample data — not from your Mac")
                        .font(.caption.weight(.semibold))
                    Text("So you can see how StackPulse looks with activity. Nothing here is real.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Turn off") { store.demoMode = false }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.8)
                    )
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sample data, not from your Mac. Button: turn off.")
        }
    }
}

// MARK: - Finding one project in a long list

/// The rule for "does this project match what I typed".
///
/// One rule, shared, because three surfaces list the same 30 projects and a filter
/// that means something different on each is worse than no filter at all.
///
/// Matches against the name **and** the path: this portfolio keeps projects under
/// several roots (`App Privadas`, `Documents/Claude/Projects`, `Desktop`), so the
/// folder is often how you say which one you mean. Every whitespace-separated term
/// must match somewhere — `zeder erp` finds it, and typing more always narrows,
/// never widens.
enum ProjectFilter {
    /// `true` when `query` is blank — a blank filter hides nothing.
    static func matches(query: String, name: String, path: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return true }
        let hay = name + " " + path
        return terms.allSatisfy { hay.localizedCaseInsensitiveContains($0) }
    }
}

/// The one filter field.
///
/// Extracted from the Launcher, which owned the only copy. Two other surfaces list
/// the same projects with no way to find one, and a second hand-rolled copy is how
/// two fields end up with different clear-button behaviour and different
/// placeholder grammar.
struct FilterField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
                .accessibilityLabel("Clear the filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .liquidGlass(cornerRadius: 10, prominence: .low, padding: 0)
    }
}

/// "Showing 3 of 27" — the count a filtered list owes the reader.
///
/// A filtered list that only shows its matches looks exactly like a short list.
/// Without this, narrowing to 3 of 27 projects and reading the result as the whole
/// portfolio is a mistake the UI invited.
struct FilterCountNote: View {
    let shown: Int
    let total: Int
    var noun: String = "project"

    var body: some View {
        if shown < total {
            Text("Showing \(shown) of \(total) \(noun)\(total == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Refresh

/// The one refresh button in the app.
///
/// Four surfaces each hand-rolled this, all with the same defect:
///
/// ```swift
/// .rotationEffect(.degrees(isLoading ? 360 : 0))
/// .animation(isLoading ? .linear(duration: 1).repeatForever(…) : .default, value: isLoading)
/// ```
///
/// `.animation(_:value:)` fires on every *change* of `isLoading` — including the
/// true→false one. So when a refresh **finished**, the rotation animated from
/// 360° back to 0° with `.default`: a full turn **backwards**, every single
/// refresh, including the ones on the automatic cadence that nobody asked for.
/// That is the icon "dancing".
///
/// Here the angle is owned state, driven explicitly. Stopping cancels the
/// repeating animation inside a transaction with animations disabled, so the
/// icon halts instead of unwinding. Under Reduce Motion it never rotates at all.
struct RefreshButton: View {
    var isLoading: Bool
    var help: String = "Refresh now"
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(angle))
        }
        .disabled(isLoading)
        .help(help)
        .accessibilityLabel(help)
        // Announce work in progress; the spin alone is not an accessible signal.
        .accessibilityValue(isLoading ? "Refreshing" : "")
        .onAppear { apply(isLoading) }
        .onChange(of: isLoading) { _, now in apply(now) }
        .onChange(of: reduceMotion) { _, _ in apply(isLoading) }
    }

    private func apply(_ loading: Bool) {
        guard loading, !reduceMotion else { return stop() }
        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
            angle = 360
        }
    }

    /// Cancel the repeating animation. Assigning inside a transaction with
    /// animations disabled is what actually detaches `repeatForever` — a plain
    /// assignment would inherit it and keep spinning toward the new value.
    private func stop() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { angle = 0 }
    }
}

// MARK: - Command Center mark

/// The Command Center's own icon.
///
/// The window previously borrowed `gauge.with.dots.needle.67percent` — the same
/// glyph as the app's brand mark and the menu-bar item — so the button that
/// opened the Command Center looked exactly like the button that opened
/// StackPulse itself. An icon that is identical to another icon does not
/// identify anything.
///
/// This draws a distinct mark: concentric radar sweeps behind a bright center —
/// many signals, one place watching them. It reads at 12pt and inherits the
/// current foreground style, so it works tinted in a toolbar or as a template.
struct CommandCenterIcon: View {
    var size: CGFloat = 15

    var body: some View {
        Canvas { ctx, canvas in
            let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let r = min(canvas.width, canvas.height) / 2

            // Two sweep arcs, opening to the upper-right — a scope, not a dial.
            for scale in [0.92, 0.62] {
                var p = Path()
                p.addArc(center: c, radius: r * scale,
                         startAngle: .degrees(-35), endAngle: .degrees(215),
                         clockwise: false)
                ctx.stroke(p, with: .foreground,
                           style: StrokeStyle(lineWidth: r * 0.16, lineCap: .round))
            }

            // The watched signal at the center.
            let dot = r * 0.26
            ctx.fill(
                Path(ellipseIn: CGRect(x: c.x - dot, y: c.y - dot, width: dot * 2, height: dot * 2)),
                with: .foreground
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Activity-only providers

/// The activity summary for a provider whose tokens and dollars are accounted
/// for **server-side** (Antigravity: Google keeps the accounting; nothing about
/// quota, credits or percentage is written to this Mac — verified by searching
/// `~/.gemini` and `~/Library/Application Support/Antigravity`).
///
/// Such a provider gets this row *instead of* a spend row. `$0.00 · 0 tokens` is
/// not a smaller truth than "not published locally" — it is a different and
/// false claim, and it is the one every surface except the popover was making.
struct ProviderActivityRow: View {
    let provider: ProviderUsage
    /// `.compact` trades the model *chip* for plain inline text and a smaller
    /// type ramp — for the always-open edge sidebar, where vertical space is the
    /// scarce resource. It must not drop the model name: on a narrow surface the
    /// model is the single most identifying fact about the session, and dropping
    /// it to save a chip's padding would cost more information than height.
    var compact = false

    private var model: String? { provider.models.first?.model }

    var body: some View {
        let total = provider.last30?.records ?? 0
        let today = provider.today?.records ?? 0
        HStack(spacing: compact ? 5 : 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text("\(total) session\(total == 1 ? "" : "s") · \(today) today")
                .font(compact ? .system(size: 10, weight: .medium) : .subheadline.weight(.medium))
                .monospacedDigit()
            Spacer(minLength: 4)
            if let model {
                if compact {
                    Text(model)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Chip(text: model, systemImage: "cpu", tint: .cyan)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(total) session\(total == 1 ? "" : "s") in the last 30 days, \(today) today"
                + (model.map { ", model \($0)" } ?? "")
        )
    }
}

/// The one-line reason an activity-only provider shows no money.
/// Stated plainly, where the number would otherwise be.
struct NoLocalSpendNote: View {
    var body: some View {
        Text("Cost is metered server-side — not published to this Mac.")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A small labeled pill (used for auth / plan / installed chips). Glassier
/// capsule: a thin frosted base under a tint wash, with a bright rim.
struct Chip: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            let shape = Capsule(style: .continuous)
            ZStack {
                if reduceTransparency {
                    shape.fill(tint.opacity(scheme == .dark ? 0.24 : 0.16))
                } else {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(tint.opacity(scheme == .dark ? 0.20 : 0.14))
                }
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(scheme == .dark ? 0.28 : 0.6), tint.opacity(0.18)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.6
                )
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A one-line credit-balance readout for a BYOK-connected provider. Shows the
/// remaining balance (green) with a "· $X used of $Y" detail when the limit is
/// known, or a plain note when only a message is available (a connected provider
/// with no live balance endpoint yet). Renders nothing for an empty balance.
/// Color is paired with the "creditcard" icon and text, never the sole signal.
struct ProviderBalanceLabel: View {
    let balance: ProviderBalance

    var body: some View {
        if balance.hasAmounts {
            HStack(spacing: 5) {
                Image(systemName: "creditcard")
                    .imageScale(.small)
                    .foregroundStyle(.green)
                Text(primary)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)
                if let detail {
                    Text("· \(detail)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Balance \(primary)\(detail.map { ", \($0)" } ?? "")")
        } else if let note = balance.note {
            Label(note, systemImage: "creditcard")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The headline figure — remaining when known, else used, else the limit.
    private var primary: String {
        if let r = balance.remaining_usd { return "\(Format.usd(r)) left" }
        if let u = balance.used_usd { return "\(Format.usd(u)) used" }
        if let l = balance.limit_usd { return "\(Format.usd(l)) limit" }
        return "—"
    }

    /// A secondary breakdown shown only alongside a remaining figure.
    private var detail: String? {
        guard balance.remaining_usd != nil else { return nil }
        switch (balance.used_usd, balance.limit_usd) {
        case let (used?, limit?): return "\(Format.usd(used)) used of \(Format.usd(limit))"
        case let (_, limit?): return "of \(Format.usd(limit))"
        case let (used?, nil): return "\(Format.usd(used)) used"
        default: return nil
        }
    }
}

/// "as of …" for ANY provider's limit reading that is no longer current.
///
/// Works off the reading's own `captured_at_unix` (protocol 1.20.0), so it covers
/// every provider rather than just Claude. Codex's limits come from its logs and
/// are only as fresh as the last session that wrote them — 18.5 hours old on a
/// real machine, rendered as if measured now, because nothing on screen or on the
/// wire said when the number was taken.
///
/// Draws nothing when the reading is recent, and nothing when the source didn't
/// timestamp it (unknown is not a claim of staleness either — but note
/// `LimitWindow.isStale` also refuses to call an untimestamped reading fresh).
/// A one-line forecast under a live-limit meter: "at this pace, ~5 hr to the
/// limit — before it resets," or the honest "watching / need more readings" while
/// there isn't a trend yet.
///
/// Only shown for a **fresh** live reading — forecasting from a stale percentage
/// would compound one uncertain number with another. The tint escalates only when
/// the limit is actually on track to be hit before its reset; otherwise it stays
/// quiet (secondary), so a reassuring "you'll clear it" doesn't shout.
struct LimitForecastNote: View {
    let forecast: LimitForecast.Result
    /// Suppress when the underlying reading is stale (paired with `LimitAgeNote`,
    /// which explains the staleness instead).
    var isStale: Bool = false

    var body: some View {
        if !isStale, let text = LimitForecast.label(forecast) {
            HStack(spacing: 4) {
                Image(systemName: icon).imageScale(.small)
                Text(text)
            }
            .font(.system(size: 9))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(text)
        }
    }

    /// Orange only when it will actually hit before reset; a projected miss or a
    /// still-gathering state stays neutral.
    private var tint: Color {
        forecast.willHitBeforeReset == true ? .orange : .secondary
    }

    private var icon: String {
        switch forecast.confidence {
        case .none: return "hourglass"
        case .low, .ok:
            return forecast.willHitBeforeReset == true ? "gauge.with.needle" : "checkmark.circle"
        }
    }
}

struct LimitAgeNote: View {
    let limit: LimitWindow
    /// Anything older than this stops being "live". Matches the live-limits
    /// staleness bound in `SnapshotStore`.
    var staleAfter: TimeInterval = 60 * 60

    var body: some View {
        if limit.isStale(staleAfter: staleAfter), let captured = limit.captured_at_unix {
            let at = Date(timeIntervalSince1970: TimeInterval(captured))
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath").imageScale(.small)
                Text("measured \(Format.relative(at)) — not live")
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("This limit was measured \(Format.relative(at)) and is not live.")
        }
    }
}

/// The honest state of Claude's live limits: either "as of …" for a value we're
/// still willing to stand behind, or the reason there is no number.
///
/// A live limit is the one number in this app a user acts on immediately, and a
/// cached one looks exactly like a fresh one. This is the whole difference between
/// "you're at 82%" and "you were at 82%, and we haven't been able to check since".
///
/// Shared because it wasn't: the popover labelled the age and surfaced the error,
/// while Home and Overview — the surface actually opened — rendered the same
/// cached percentage with neither. Render this beside every live-limit readout.
/// It draws nothing when the value is fresh and correct.
struct LiveLimitsStatusNote: View {
    let capturedAt: Date?
    let isStale: Bool
    /// Why there is no live value, when there isn't one.
    let error: String?
    /// The one-click fix, when the failure has one. `nil` ⇒ no button.
    var onRenewLogin: (() -> Void)?

    var body: some View {
        if let error {
            VStack(alignment: .leading, spacing: 4) {
                row("exclamationmark.triangle", error, tint: .orange)
                // Telling someone to go type a command is a worse answer than
                // offering to type it for them. It still runs visibly in Terminal
                // and still needs their sign-in — this only saves the retyping.
                if let onRenewLogin {
                    Button(action: onRenewLogin) {
                        Label("Renew login in Terminal", systemImage: "terminal")
                            .font(.caption2.weight(.medium))
                    }
                    .buttonStyle(.glass(tint: .orange))
                    .help("Runs `claude` in Terminal so it can refresh its saved login. StackPulse never changes your login itself.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if isStale, let capturedAt {
            row("clock.arrow.circlepath",
                "as of \(Format.relative(capturedAt)) — not live right now",
                tint: .secondary)
        }
    }

    private func row(_ symbol: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbol).imageScale(.small)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 9))
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

/// A thin proportional bar (usage / cache / limit). Glossy gradient fill with a
/// top sheen; when `glowsWhenHigh` and the fill is ≥85% it gets a soft colored
/// glow (used for hot live limits). Includes an accessibility value so it is
/// never color-only.
struct MeterBar: View {
    var fraction: Double            // 0…1
    var tint: Color
    var height: CGFloat = 6
    /// Only live-limit meters set this; a hot fill then glows red/amber.
    var glowsWhenHigh: Bool = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var clamped: Double { min(1, max(0, fraction)) }
    private var isHot: Bool { glowsWhenHigh && clamped >= 0.85 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.72), tint],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .overlay {
                        if !reduceTransparency {
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [.white.opacity(scheme == .dark ? 0.35 : 0.55), .clear],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                                .blendMode(.plusLighter)
                        }
                    }
                    .frame(width: max(2, geo.size.width * clamped))
                    .glassGlow(tint, radius: 7, active: isHot && !reduceTransparency)
            }
        }
        .frame(height: height)
        .accessibilityValue(Format.percent(fraction * 100))
    }
}

/// A plain-SwiftUI 30-day daily bar chart (no Swift Charts dependency). Bars are
/// scaled to the max value in the series over a faint full-height track, with
/// "30 days ago → today" end labels and a single combined accessibility
/// description. Uses estimated cost when any day has one, else token volume.
struct DailyBarChart: View {
    let daily: [DailyUsage]
    var tint: Color = .blue
    var height: CGFloat = 60

    /// Cost when at least one day carries a cost; otherwise token volume.
    private var usesCost: Bool {
        daily.contains { $0.estimated_cost_usd != nil }
    }

    private func value(_ day: DailyUsage) -> Double {
        usesCost ? (day.estimated_cost_usd ?? 0) : Double(day.tokens.grandTotal)
    }

    private func label(_ v: Double) -> String {
        usesCost ? Format.usd(v) : "\(Format.tokens(UInt64(max(0, v)))) tok"
    }

    var body: some View {
        // Scaled once for the whole series: every bar below divides by this, so it
        // must not itself walk `daily`. As a computed property read inside the
        // ForEach it rescanned the series per bar — 30 bars ⇒ 900 `value(_:)` calls
        // and 30 array allocations per render. Floored so an all-zero chart can't
        // divide by zero. Mirrors TrendsDailyChart.
        let maxValue = max(daily.lazy.map(value).max() ?? 0, 0.0001)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(daily) { day in
                    let v = value(day)
                    let fraction = v / maxValue
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(tint.gradient)
                            .frame(height: v <= 0 ? 0 : max(3, height * fraction))
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(day.date): \(label(v))")
                }
            }
            .frame(height: height)

            HStack {
                Text("30 days ago")
                Spacer()
                Text("today")
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(usesCost
            ? "Daily estimated cost over the last 30 days"
            : "Daily token volume over the last 30 days")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let peak = daily.max(by: { value($0) < value($1) }), value(peak) > 0 else {
            return "No activity in the last 30 days."
        }
        let latest = daily.last
        let latestPart = latest.map { "Most recent day \(label(value($0)))." } ?? ""
        return "Peak \(label(value(peak))) on \(peak.date). \(latestPart)"
    }
}
