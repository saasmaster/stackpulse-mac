import SwiftUI

/// Trends: long-run spend and token trends drawn from the core's durable usage
/// history (protocol ≥ 1.6.0). Unlike Usage — which reads the last 30 days of
/// raw logs — this looks back as far as the accumulated store goes. All charts
/// are plain SwiftUI (no Swift Charts dependency), matching ``DailyBarChart``.
///
/// Costs are the same local list-price estimates used everywhere else, never a
/// billed amount; the footnote makes that (and the ~30-day seed) explicit.
struct TrendsSection: View {
    @EnvironmentObject var store: SnapshotStore
    @State private var range: TrendsRange = .d30

    var body: some View {
        SectionScaffold(section: .trends) { _ in
            let model = TrendsModel(points: store.history, range: range)
            VStack(alignment: .leading, spacing: 18) {
                GlassSegmentedControl(segments: TrendsRange.allSegments, selection: $range)
                    .frame(maxWidth: 320, alignment: .leading)

                if model.isEmpty {
                    EmptyStateView(
                        icon: "chart.xyaxis.line",
                        title: "No trends yet",
                        message: "Trends will build up as StackPulse runs — seeded with your last 30 days."
                    )
                } else {
                    summaryTiles(model)
                    dailyChartCard(model)
                    providerBreakdown(model)
                    footnote
                }
            }
        }
    }

    // MARK: Summary tiles

    private func summaryTiles(_ model: TrendsModel) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)],
            alignment: .leading,
            spacing: 12
        ) {
            StatTile(
                label: "Est. cost (\(range.label))",
                value: Format.usd(model.totalCost),
                caption: "list-price estimate",
                systemImage: "dollarsign.circle",
                tint: .mint
            )
            StatTile(
                label: "Tokens",
                value: Format.tokens(model.totalTokens),
                caption: "all providers",
                systemImage: "number",
                tint: .blue
            )
            StatTile(
                label: "Active days",
                value: "\(model.activeDayCount)",
                caption: "days with usage",
                systemImage: "calendar",
                tint: .cyan
            )
            StatTile(
                label: "Daily average",
                value: model.dailyAverageDisplay,
                caption: "per active day",
                systemImage: "chart.bar",
                tint: .orange
            )
        }
        .glassCard(padding: 16)
    }

    // MARK: Daily total chart

    private func dailyChartCard(_ model: TrendsModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily \(model.usesCost ? "estimated cost" : "token volume")")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if model.peakValue > 0 {
                    Chip(text: "Peak \(model.peakLabel)",
                         systemImage: "arrow.up.to.line", tint: .orange)
                }
            }

            TrendsDailyChart(
                days: model.dayTotals,
                usesCost: model.usesCost,
                startLabel: model.startLabel
            )

            if model.peakValue > 0, let peak = model.peak {
                Text("Peak \(model.peakLabel) on \(HistoryDate.pretty(peak.date)) · \(model.dayTotals.count) days shown.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16)
    }

    // MARK: Per-provider breakdown

    private func providerBreakdown(_ model: TrendsModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By provider (sorted by estimated cost)")
                .font(.subheadline.weight(.semibold))
            ForEach(model.providers) { provider in
                providerRow(provider, usesCost: model.usesCost)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 16)
    }

    private func providerRow(_ provider: TrendsModel.ProviderTotal, usesCost: Bool) -> some View {
        let tint = TrendsPalette.tint(for: provider.provider)
        let name = displayName(for: provider.provider)
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                StatusDot(color: tint, size: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("\(Format.tokens(provider.tokens)) tok · \(provider.records) turns")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 168, alignment: .leading)

            Sparkline(values: provider.dailyValues, tint: tint)
                .frame(maxWidth: .infinity)

            Text(Format.usd(provider.cost))
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(provider.cost == nil ? .tertiary : .primary)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(name): \(Format.usd(provider.cost)) estimated, "
            + "\(Format.tokens(provider.tokens)) tokens over the \(range.label) range."
        )
    }

    /// Prefers the live snapshot's own display name for a provider, falling back
    /// to a title-cased id so history-only providers still read nicely.
    private func displayName(for provider: String) -> String {
        if let name = store.snapshot?.providers.first(where: { $0.provider == provider })?.display_name {
            return name
        }
        return provider.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: Footnote

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            EstimateFootnote()
            Label(
                "History is seeded from your last ~30 days of logs, then grows every time StackPulse runs — so trends deepen the longer you use it.",
                systemImage: "clock.arrow.circlepath"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Range selector

/// The look-back window for Trends. `all` returns the entire accumulated store.
enum TrendsRange: String, CaseIterable, Sendable {
    case d30
    case d90
    case all

    /// Number of days to include, or `nil` for the full history.
    var days: Int? {
        switch self {
        case .d30: return 30
        case .d90: return 90
        case .all: return nil
        }
    }

    var label: String {
        switch self {
        case .d30: return "30d"
        case .d90: return "90d"
        case .all: return "All"
        }
    }

    var systemImage: String {
        switch self {
        case .d30: return "calendar"
        case .d90: return "calendar.badge.clock"
        case .all: return "infinity"
        }
    }

    var segment: GlassSegment<TrendsRange> {
        GlassSegment(value: self, systemImage: systemImage, label: label)
    }

    static var allSegments: [GlassSegment<TrendsRange>] { allCases.map(\.segment) }
}

// MARK: - Provider palette

/// Stable, distinct tints per provider id for sparklines and dots. Color is
/// never the sole signal — every call site pairs it with the provider name.
enum TrendsPalette {
    static func tint(for provider: String) -> Color {
        switch provider {
        case "claude": return .orange
        case "codex": return .green
        case "copilot": return .blue
        case "cursor": return .purple
        case "gemini": return .teal
        case "grok": return .pink
        case "antigravity": return .indigo
        case "devin": return .mint
        case "open_code": return .cyan
        case "open_router": return .yellow
        case "zai": return .red
        default: return .gray
        }
    }
}

// MARK: - Aggregation model (pure, view-layer)

/// Pure aggregation of ``HistoryPoint``s over a selected range. Produces a
/// zero-filled continuous daily series (summed across providers) for the chart,
/// a per-provider rollup with an aligned per-day series for the sparklines, and
/// the range totals for the summary tiles. Holds no SwiftUI state.
struct TrendsModel {
    /// One day on the continuous (zero-filled) range axis.
    struct DayTotal: Identifiable {
        let date: String
        /// Summed estimated cost; `nil` only when no provider that day carried one.
        let cost: Double?
        let tokens: UInt64
        var id: String { date }
    }

    /// A provider's range rollup plus its per-day series aligned to `dayTotals`.
    struct ProviderTotal: Identifiable {
        let provider: String
        let cost: Double?
        let tokens: UInt64
        let records: UInt64
        /// Per-day values (cost when the range uses cost, else tokens), aligned
        /// one-to-one with the chart's date axis so the sparkline shares its shape.
        let dailyValues: [Double]
        var id: String { provider }
    }

    let usesCost: Bool
    let dayTotals: [DayTotal]
    let providers: [ProviderTotal]
    let totalCost: Double?
    let totalTokens: UInt64
    let activeDayCount: Int
    let startLabel: String

    var isEmpty: Bool { dayTotals.isEmpty }

    /// Peak day by the active metric (cost when available, else tokens).
    var peak: DayTotal? {
        dayTotals.max { dayValue($0) < dayValue($1) }
    }

    var peakValue: Double { peak.map(dayValue) ?? 0 }

    var peakLabel: String {
        usesCost ? Format.usd(peakValue) : "\(Format.tokens(UInt64(max(0, peakValue)))) tok"
    }

    /// Estimated spend (or token volume) per active day, for the summary tile.
    var dailyAverageDisplay: String {
        guard activeDayCount > 0 else { return "—" }
        if let totalCost {
            return Format.usd(totalCost / Double(activeDayCount))
        }
        return "\(Format.tokens(totalTokens / UInt64(activeDayCount))) tok"
    }

    private func dayValue(_ d: DayTotal) -> Double {
        usesCost ? (d.cost ?? 0) : Double(d.tokens)
    }

    init(points: [HistoryPoint], range: TrendsRange) {
        // 1. Filter to the range by UTC date string (dates sort lexicographically).
        let today = HistoryDate.todayString()
        let cutoff: String? = range.days.map { HistoryDate.daysAgo($0 - 1) }
        let inRange = points.filter { cutoff == nil || $0.date >= cutoff! }

        guard !inRange.isEmpty else {
            usesCost = false
            dayTotals = []
            providers = []
            totalCost = nil
            totalTokens = 0
            activeDayCount = 0
            startLabel = ""
            return
        }

        let usesCost = inRange.contains { $0.estimated_cost_usd != nil }
        self.usesCost = usesCost

        // 2. Continuous date axis: from the range start to today (or the latest
        //    point, whichever is later, to guard against UTC skew).
        let earliest = inRange.map(\.date).min() ?? today
        let latest = max(inRange.map(\.date).max() ?? today, today)
        let start = cutoff ?? earliest
        let axis = HistoryDate.range(from: start, to: latest)
        let axisIndex = Dictionary(uniqueKeysWithValues: axis.enumerated().map { ($1, $0) })

        // 3. Daily totals (summed across providers), zero-filled over the axis.
        var costByDate: [String: Double] = [:]
        var costPresentByDate: Set<String> = []
        var tokensByDate: [String: UInt64] = [:]
        for p in inRange {
            tokensByDate[p.date, default: 0] += p.tokens.grandTotal
            if let c = p.estimated_cost_usd {
                costByDate[p.date, default: 0] += c
                costPresentByDate.insert(p.date)
            }
        }
        dayTotals = axis.map { date in
            DayTotal(
                date: date,
                cost: costPresentByDate.contains(date) ? costByDate[date] : nil,
                tokens: tokensByDate[date] ?? 0
            )
        }

        // 4. Per-provider rollups with an axis-aligned per-day series.
        var byProvider: [String: [HistoryPoint]] = [:]
        for p in inRange { byProvider[p.provider, default: []].append(p) }

        providers = byProvider.map { provider, pts -> ProviderTotal in
            let costs = pts.compactMap(\.estimated_cost_usd)
            let cost: Double? = costs.isEmpty ? nil : costs.reduce(0, +)
            let tokens = pts.reduce(UInt64(0)) { $0 + $1.tokens.grandTotal }
            let records = pts.reduce(UInt64(0)) { $0 + $1.records }

            var series = [Double](repeating: 0, count: axis.count)
            for pt in pts {
                guard let i = axisIndex[pt.date] else { continue }
                series[i] += usesCost ? (pt.estimated_cost_usd ?? 0) : Double(pt.tokens.grandTotal)
            }
            return ProviderTotal(
                provider: provider, cost: cost, tokens: tokens,
                records: records, dailyValues: series
            )
        }
        .sorted {
            // Cost desc, then token volume desc as a stable tiebreaker.
            if ($0.cost ?? -1) != ($1.cost ?? -1) { return ($0.cost ?? -1) > ($1.cost ?? -1) }
            return $0.tokens > $1.tokens
        }

        // 5. Range totals.
        let providerCosts = providers.compactMap(\.cost)
        totalCost = providerCosts.isEmpty ? nil : providerCosts.reduce(0, +)
        totalTokens = providers.reduce(UInt64(0)) { $0 + $1.tokens }
        activeDayCount = dayTotals.filter { $0.tokens > 0 || ($0.cost ?? 0) > 0 }.count
        startLabel = HistoryDate.pretty(start)
    }
}

// MARK: - Daily total chart (plain SwiftUI)

/// A plain-SwiftUI daily bar chart over an arbitrary range — the same faint
/// track + glossy gradient-fill idiom as ``DailyBarChart``, but with a caller-
/// supplied start label (vs. the hardcoded "30 days ago") and adaptive bar
/// spacing so 30 / 90 / hundreds of days all read cleanly. Cost when the range
/// carries any cost, else token volume. One combined accessibility description.
struct TrendsDailyChart: View {
    let days: [TrendsModel.DayTotal]
    let usesCost: Bool
    let startLabel: String
    var tint: Color = .blue
    var height: CGFloat = 120

    private func value(_ d: TrendsModel.DayTotal) -> Double {
        usesCost ? (d.cost ?? 0) : Double(d.tokens)
    }

    private func label(_ v: Double) -> String {
        usesCost ? Format.usd(v) : "\(Format.tokens(UInt64(max(0, v)))) tok"
    }

    private var maxValue: Double { max(days.map(value).max() ?? 0, 0.0001) }

    /// Tighter spacing as the day count grows, so long ranges stay legible.
    private var barSpacing: CGFloat {
        switch days.count {
        case ..<45: return 3
        case ..<100: return 2
        default: return 1
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: barSpacing) {
                ForEach(days) { day in
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
                    .help("\(HistoryDate.pretty(day.date)): \(label(v))")
                }
            }
            .frame(height: height)

            HStack {
                Text(startLabel)
                Spacer()
                Text("today")
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(usesCost
            ? "Daily estimated cost over the selected range"
            : "Daily token volume over the selected range")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let peak = days.max(by: { value($0) < value($1) }), value(peak) > 0 else {
            return "No activity in the selected range."
        }
        let latest = days.last.map { "Most recent day \(label(value($0)))." } ?? ""
        return "Peak \(label(value(peak))) on \(HistoryDate.pretty(peak.date)). \(latest)"
    }
}

// MARK: - Sparkline (plain SwiftUI line + area)

/// A compact per-provider trend line with a soft area fill — plain SwiftUI
/// `Path`, no Swift Charts. Purely decorative: the row it sits in carries the
/// numeric totals as its accessibility label, so the sparkline is hidden from
/// assistive tech. Uses solid strokes/fills, so Reduce Transparency is a no-op.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = .blue
    var height: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 0, 0.0001)
            let w = geo.size.width
            let h = geo.size.height
            let n = values.count

            if n >= 2 {
                let stepX = w / CGFloat(n - 1)
                let points = values.enumerated().map { i, v in
                    CGPoint(x: CGFloat(i) * stepX, y: h * (1 - CGFloat(min(1, v / maxV))))
                }
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: h))
                        for p in points { path.addLine(to: p) }
                        path.addLine(to: CGPoint(x: w, y: h))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.28), tint.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    Path { path in
                        path.move(to: points[0])
                        for p in points.dropFirst() { path.addLine(to: p) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            } else if values.first != nil {
                // A single day → a flat baseline hint.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h * 0.5))
                    path.addLine(to: CGPoint(x: w, y: h * 0.5))
                }
                .stroke(tint.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - UTC date helpers

/// Small UTC-calendar helpers for the `YYYY-MM-DD` history dates. History days
/// are bucketed by UTC calendar day (like the spend windows), so all math here
/// uses a UTC calendar to stay aligned with "today".
enum HistoryDate {
    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.calendar = utc
        f.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let prettyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = utc
        f.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func date(_ s: String) -> Date? { iso.date(from: s) }
    static func string(_ d: Date) -> String { iso.string(from: d) }
    static func todayString() -> String { string(Date()) }

    /// The `YYYY-MM-DD` string for `n` UTC days before today.
    static func daysAgo(_ n: Int) -> String {
        let base = utc.date(byAdding: .day, value: -max(0, n), to: Date()) ?? Date()
        return string(base)
    }

    /// Inclusive list of `YYYY-MM-DD` strings from `start` to `end`. Bounded
    /// defensively so a malformed pair can never loop unboundedly.
    static func range(from start: String, to end: String) -> [String] {
        guard let s = date(start), let e = date(end), s <= e else { return [] }
        var out: [String] = []
        var cur = s
        while cur <= e && out.count < 4000 {
            out.append(string(cur))
            guard let next = utc.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = next
        }
        return out
    }

    /// Friendly label for a history date, e.g. "Apr 13" (adds the year when it
    /// isn't the current year, so long "All" ranges stay unambiguous).
    static func pretty(_ iso: String) -> String {
        guard let d = date(iso) else { return iso }
        let year = utc.component(.year, from: d)
        let currentYear = utc.component(.year, from: Date())
        prettyFormatter.dateFormat = (year == currentYear) ? "MMM d" : "MMM d, yyyy"
        return prettyFormatter.string(from: d)
    }
}
