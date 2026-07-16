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

/// "as of …" for Claude's live limits when the shown percentage is NOT live.
///
/// A live limit is the one number in this app the user acts on immediately, and a
/// cached one looks exactly like a fresh one. This label is the whole difference
/// between "you're at 82%" and "you were at 82%, three days ago".
///
/// It exists as a shared component because it didn't used to be one: the popover
/// labelled the age, Home and Overview rendered the same cached percentage with
/// nothing at all — so the surface the user actually opens was the one that
/// implied a stale number was current. Render this beside every live-limit
/// readout; it draws nothing when the value is fresh.
struct LiveLimitsAgeNote: View {
    let capturedAt: Date?
    let isStale: Bool

    var body: some View {
        if isStale, let capturedAt {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath").imageScale(.small)
                Text("as of \(Format.relative(capturedAt)) — not live right now")
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("These limit percentages are from \(Format.relative(capturedAt)) and are not live.")
        }
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
