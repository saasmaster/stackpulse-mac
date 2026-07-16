import SwiftUI

// MARK: - Schema canaries (protocol ≥ 1.18.0)
//
// "Are the numbers everywhere else in this app actually complete?"
//
// StackPulse reads local AI logs whose format it does not control. When a
// provider changes that format, or ships a model the pricing table has never
// heard of, the failure is SILENT: tokens go uncounted, or get counted at no
// cost, and every total downstream quietly understates. The canary exists so the
// app can say "I might be under-reporting, and here is exactly where" instead of
// presenting a confidently wrong number.
//
// This surface therefore has one rule that outranks its looks: it may only make
// a claim it can actually support.
//
//   • `ok`      — files were found, parsed, and fully understood. The one state
//                 that has earned a green check.
//   • `drifted` — something was found we don't fully understand. The numbers are
//                 incomplete in a way we can name.
//   • `no_data` — nothing local to check. NOT a problem, and explicitly NOT `ok`:
//                 there was nothing to verify, so nothing was verified. It never
//                 renders as reassurance.
//   • unknown   — a status string this app version has never seen (a newer core).
//                 Displays as unknown. Never coerced into `ok`.
//   • empty     — the core reported no checks at all. That is "nothing was
//                 checked", not "everything checked out".
//
// The absence of a complaint is not an all-clear. Only a positive `ok` is.

// MARK: - State (icon + color are always paired with a text label)

/// Interpreted status of a ``SchemaCanary``. The wire value is a `String` so a
/// newer core can add a status without breaking decoding; anything unrecognized
/// maps to `.unknown` — deliberately never to `.ok`, because "we don't recognize
/// this answer" and "everything is fine" are opposite claims.
///
/// `Comparable` by *concern*, so `max()` finds the state that most deserves the
/// user's attention. Color is never the sole signal — every call site pairs it
/// with `icon` and `label`.
enum CanaryState: Int, Comparable, Sendable {
    /// Checked, and everything in the logs was understood.
    case ok = 0
    /// Nothing local to check. Not a problem; also not a verification.
    case noData = 1
    /// A status this version of StackPulse doesn't recognize.
    case unknown = 2
    /// Found something we don't understand — the numbers are knowably incomplete.
    case drifted = 3

    init(_ raw: String) {
        switch raw {
        case "ok": self = .ok
        case "drifted": self = .drifted
        case "no_data": self = .noData
        // Everything else — including a status a future core invents — is
        // unknown. This default is the whole forward-compatibility contract: it
        // must never silently become `.ok`.
        default: self = .unknown
        }
    }

    static func < (lhs: CanaryState, rhs: CanaryState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Semantic tint, always accompanied by the icon and a text label.
    ///
    /// Only `.ok` is green. `.noData` is deliberately neutral grey rather than a
    /// soft green: a card that looks calm reads as "fine", and "nothing to check"
    /// is not "fine", it is "unverified".
    var color: Color {
        switch self {
        case .ok: return .green
        case .noData: return .secondary   // Color.tertiary does not exist
        case .unknown: return .yellow
        case .drifted: return .orange
        }
    }

    /// Note `.noData` gets a hollow, dashed glyph — never a checkmark or a seal.
    var icon: String {
        switch self {
        case .ok: return "checkmark.seal.fill"
        case .noData: return "circle.dashed"
        case .unknown: return "questionmark.circle.fill"
        case .drifted: return "exclamationmark.triangle.fill"
        }
    }

    /// Short state label. Plain language over jargon — the user cares that their
    /// numbers are incomplete, not that a schema "drifted".
    var label: String {
        switch self {
        case .ok: return "Verified"
        case .noData: return "Nothing to check"
        case .unknown: return "Unrecognized"
        case .drifted: return "Incomplete"
        }
    }

    /// Group header for a set of canaries in this state.
    var groupTitle: String {
        switch self {
        case .ok: return "Verified"
        case .noData: return "Nothing to check"
        case .unknown: return "Not recognized by this version"
        case .drifted: return "Numbers are incomplete"
        }
    }

    /// One line of plain-language context under a group header, so each state's
    /// meaning is stated rather than implied by its color.
    var groupBlurb: String {
        switch self {
        case .ok:
            return "Every log file found was read and fully understood. These totals are complete."
        case .noData:
            return "There was no local data to read, so nothing here was verified — this is not a problem, "
                + "and it is not an all-clear either."
        case .unknown:
            return "This version of StackPulse doesn't recognize what the core reported, so it can't tell "
                + "you whether these numbers are complete. Updating the app may resolve it."
        case .drifted:
            return "Something was found that StackPulse doesn't fully understand. The totals it shows for "
                + "these providers are missing usage — the details below say exactly what."
        }
    }
}

extension SchemaCanary {
    /// Interpreted status (icon / color / label / ordering live on ``CanaryState``).
    var canaryState: CanaryState { CanaryState(status) }

    /// Records in this scan that named a model with no known price.
    var unpricedRecords: UInt64 {
        unpriced_models.reduce(0) { $0 + $1.records }
    }

    /// Tokens counted for unpriced models — real volume contributing zero cost.
    var unpricedTokens: UInt64 {
        unpriced_models.reduce(0) { $0 + $1.tokens.grandTotal }
    }

    /// Share of this scan's parsed records that named an unpriced model, 0…1.
    ///
    /// Honest because both sides come from the **same scan window**: the core
    /// reports `records_parsed` and each model's `records` from one pass. `nil`
    /// when nothing was parsed, rather than a fabricated zero.
    var unpricedRecordFraction: Double? {
        guard records_parsed > 0 else { return nil }
        return Double(unpricedRecords) / Double(records_parsed)
    }
}

// MARK: - Provider naming

/// Friendly names for known provider ids, kept here so a canary card/banner is
/// self-contained (a banner has no snapshot to resolve against). Mirrors the same
/// map used by Missions and Insights.
enum CanaryProvider {
    static func prettyName(_ id: String) -> String {
        switch id {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "copilot": return "Copilot"
        case "cursor": return "Cursor"
        case "antigravity": return "Antigravity"
        case "devin": return "Devin"
        case "grok": return "Grok"
        case "open_code": return "OpenCode"
        case "open_router": return "OpenRouter"
        case "zai": return "Z.ai"
        case "gemini": return "Gemini"
        default:
            return id.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }
}

// MARK: - Verdict

/// The single headline claim this surface is allowed to make about a set of
/// canaries. Modeled as an enum so that "all clear" is *unreachable* except from
/// the one branch that has actually earned it — rather than being whatever is
/// left over once no complaint was found.
enum CanaryVerdict: Sendable {
    /// The core reported no checks at all (older core). Nothing was checked.
    case nothingChecked
    /// At least one provider is knowably under-reporting.
    case incomplete(drifted: Int)
    /// No drift, but at least one status this version can't read.
    case unreadable(unknown: Int)
    /// Checks ran, but every one of them had nothing to look at.
    case nothingToVerify(providers: Int)
    /// At least one provider positively verified, and nothing drifted or
    /// unrecognized. `unverified` counts any that had nothing to check — carried
    /// so the headline can never round "3 of 5" up to "all".
    case verified(providers: Int, unverified: Int)

    /// Worst-first triage. Order matters: drift outranks everything, and the
    /// `verified` branch is reachable only after every other possibility is out.
    init(_ canaries: [SchemaCanary]) {
        if canaries.isEmpty { self = .nothingChecked; return }
        let drifted = canaries.lazy.filter { $0.canaryState == .drifted }.count
        if drifted > 0 { self = .incomplete(drifted: drifted); return }
        let unknown = canaries.lazy.filter { $0.canaryState == .unknown }.count
        if unknown > 0 { self = .unreadable(unknown: unknown); return }
        let ok = canaries.lazy.filter { $0.canaryState == .ok }.count
        // Everything left is `no_data`. Nothing was verified, so nothing may be
        // claimed — this is the branch that must never fall through to `verified`.
        if ok == 0 { self = .nothingToVerify(providers: canaries.count); return }
        self = .verified(providers: ok, unverified: canaries.count - ok)
    }

    var icon: String {
        switch self {
        case .nothingChecked: return "questionmark.circle"
        case .incomplete: return "exclamationmark.triangle.fill"
        case .unreadable: return "questionmark.circle.fill"
        case .nothingToVerify: return "circle.dashed"
        case .verified: return "checkmark.seal.fill"
        }
    }

    /// Green appears here exactly once, in the one case that earned it.
    var color: Color {
        switch self {
        case .nothingChecked: return .secondary
        case .incomplete: return .orange
        case .unreadable: return .yellow
        case .nothingToVerify: return .secondary
        case .verified: return .green
        }
    }

    var headline: String {
        switch self {
        case .nothingChecked:
            return "Nothing was checked"
        case let .incomplete(drifted):
            return "\(drifted) provider\(drifted == 1 ? "" : "s") reporting incomplete numbers"
        case let .unreadable(unknown):
            return "\(unknown) check\(unknown == 1 ? "" : "s") this version can't read"
        case .nothingToVerify:
            return "Nothing to verify"
        case let .verified(providers, unverified):
            let base = "\(providers) provider\(providers == 1 ? "" : "s") verified"
            // Never let "3 verified" stand in for "all verified" when 2 were
            // skipped. The skipped ones are named in the same breath.
            return unverified > 0 ? "\(base), \(unverified) unverified" : base
        }
    }

    var blurb: String {
        switch self {
        case .nothingChecked:
            return "This version of the StackPulse core doesn't check whether your logs still match what it "
                + "understands. That doesn't mean anything is wrong — it means the totals elsewhere in the "
                + "app haven't been confirmed complete."
        case .incomplete:
            return "StackPulse found usage it can't fully account for. The totals and cost estimates it shows "
                + "are missing some of your activity. The cards below name exactly what and where."
        case .unreadable:
            return "The core reported a result this version of StackPulse doesn't understand, so it can't tell "
                + "you whether your numbers are complete. Updating the app may resolve it."
        case let .nothingToVerify(providers):
            return "\(providers == 1 ? "The provider checked has" : "All \(providers) providers checked have") "
                + "no local data to read right now, so none of your totals have been verified. Nothing is "
                + "wrong — there was simply nothing to look at."
        case let .verified(_, unverified):
            let base = "Every log file StackPulse read was fully understood, so the usage it counted is complete."
            return unverified > 0
                ? base + " \(unverified) other provider\(unverified == 1 ? " had" : "s had") no local data to "
                    + "check, so \(unverified == 1 ? "it wasn't" : "they weren't") verified either way."
                : base
        }
    }
}

// MARK: - Section

/// The full Data Integrity surface: a verdict header, the honest totals for
/// anything counted-but-unpriced, and a card per provider grouped worst-first.
///
/// Takes its `section` rather than hardcoding one, because the `MainSection` case
/// belongs to the nav layer (MainWindowView.swift) and is wired up separately —
/// pass `CanarySection(section: .canaries)` once that case exists.
///
/// Using ``SectionScaffold`` is load-bearing here, not just cosmetic: it renders
/// the loading / error states for a snapshot that hasn't arrived, so a scan that
/// hasn't finished can never flash a green verdict on its way in.
struct CanarySection: View {
    let section: MainSection

    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        SectionScaffold(section: section) { snapshot in
            let canaries = store.canaries
            VStack(alignment: .leading, spacing: 18) {
                verdictCard(canaries)
                if store.unpricedModelCount > 0 {
                    unpricedTotals(canaries)
                }
                ForEach(groups(canaries), id: \.0) { state, items in
                    groupBlock(state, items, snapshot: snapshot)
                }
                footnote
            }
        }
    }

    // MARK: Verdict

    private func verdictCard(_ canaries: [SchemaCanary]) -> some View {
        let verdict = CanaryVerdict(canaries)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: verdict.icon)
                .font(.title2)
                .foregroundStyle(verdict.color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(verdict.headline)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(verdict.blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 18, prominence: .elevated, tint: verdict.color, padding: 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(verdict.headline). \(verdict.blurb)")
    }

    // MARK: Counted-but-unpriced totals

    /// The magnitude of the silence: real volume that lands in the token totals
    /// and contributes nothing to any cost figure. No dollar amount appears here,
    /// on purpose — the core refuses to guess a rate, and "$0" would read as
    /// "free" rather than "unknown".
    private func unpricedTotals(_ canaries: [SchemaCanary]) -> some View {
        let models = store.unpricedModelCount
        let tokens = canaries.reduce(UInt64(0)) { $0 + $1.unpricedTokens }
        let records = canaries.reduce(UInt64(0)) { $0 + $1.unpricedRecords }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Counted, but not priced")
                .font(.headline)
            HStack(alignment: .top, spacing: 14) {
                StatTile(
                    label: "Tokens not priced",
                    value: Format.tokens(tokens),
                    caption: "in your totals · not in any estimate",
                    systemImage: "questionmark.circle",
                    tint: .orange
                )
                StatTile(
                    label: "Records",
                    value: Format.tokens(records),
                    caption: "naming an unpriced model",
                    systemImage: "list.bullet.rectangle"
                )
                StatTile(
                    label: "Models",
                    value: "\(models)",
                    caption: "with no known price",
                    systemImage: "cube"
                )
            }
            Text("StackPulse has no list price for \(models == 1 ? "this model" : "these models") and won't "
                + "guess one. The tokens above are counted in your usage totals; their cost is absent from "
                + "every estimate the app shows.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(padding: 14)
    }

    // MARK: State groups

    /// Worst first: incomplete → unrecognized → nothing-to-check → verified.
    /// Within each, the core's own worst-first order is preserved (filter is stable).
    private func groups(_ all: [SchemaCanary]) -> [(CanaryState, [SchemaCanary])] {
        [CanaryState.drifted, .unknown, .noData, .ok].compactMap { state in
            let items = all.filter { $0.canaryState == state }
            return items.isEmpty ? nil : (state, items)
        }
    }

    private func groupBlock(
        _ state: CanaryState, _ items: [SchemaCanary], snapshot: UsageSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: state.icon)
                    .foregroundStyle(state.color)
                Text(state.groupTitle)
                    .font(.headline)
                Text("\(items.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(state.groupBlurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Lazy: one card per provider today, but the provider list grows and
            // each card carries its own unpriced-model list.
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(items) { canary in
                    CanaryCard(
                        canary: canary,
                        providerName: resolvedProviderName(canary.provider, in: snapshot)
                    )
                }
            }
        }
    }

    /// Prefers the live snapshot's own display name, falling back to the friendly
    /// map, then a title-cased id — so an unknown provider still reads as a name.
    private func resolvedProviderName(_ id: String, in snapshot: UsageSnapshot) -> String {
        snapshot.providers.first { $0.provider == id }?.display_name
            ?? CanaryProvider.prettyName(id)
    }

    // MARK: Footnote

    private var footnote: some View {
        Label(
            "These checks look at the local log files on this Mac. They can tell you when StackPulse's numbers "
                + "are incomplete — they can't confirm what a provider actually billed you.",
            systemImage: "info.circle"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Canary card

/// One provider's check: state glyph + name + state chip, the core's own
/// plain-language detail verbatim, what was scanned, and — when the pricing table
/// came up short — exactly which models are being counted for free.
struct CanaryCard: View {
    let canary: SchemaCanary
    let providerName: String

    private var state: CanaryState { canary.canaryState }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: state.icon)
                    .font(.title3)
                    .foregroundStyle(state.color)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(providerName)
                            .font(.callout.weight(.semibold))
                        Chip(text: state.label, systemImage: state.icon, tint: state.color)
                        Spacer(minLength: 0)
                    }
                    // Safe to show verbatim: the core guarantees plain language,
                    // never a path or a stack trace.
                    Text(canary.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    scanFooter
                }
                Spacer(minLength: 0)
            }

            if !canary.unpriced_models.isEmpty {
                unpricedBlock
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 16, tint: state.color, padding: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(providerName), \(state.label). \(canary.detail)")
    }

    /// What the scan actually looked at. Shown even when it's 0/0 — that is the
    /// evidence for "nothing to check", and it belongs on screen.
    private var scanFooter: some View {
        HStack(spacing: 8) {
            Chip(text: "\(canary.files_seen) log file\(canary.files_seen == 1 ? "" : "s")",
                 systemImage: "doc.text")
            Chip(text: "\(Format.tokens(canary.records_parsed)) records",
                 systemImage: "list.bullet")
            Label(Format.relative(canary.checkedAt), systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 0)
        }
    }

    // MARK: Unpriced models

    private var unpricedBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.5)

            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
                Text("Counted, but not priced")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }

            Text("These tokens are included in \(providerName)'s usage totals. StackPulse has no list price "
                + "for \(canary.unpriced_models.count == 1 ? "this model" : "these models") and won't guess "
                + "one, so \(canary.unpriced_models.count == 1 ? "it contributes" : "they contribute") "
                + "nothing to any cost estimate in the app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Same-window ratio: `records_parsed` and each model's `records` both
            // come from this one scan, so the share is a real comparison rather
            // than two different windows divided by each other.
            if let fraction = canary.unpricedRecordFraction, fraction > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    MeterBar(fraction: fraction, tint: .orange)
                    Text("\(Format.percent(fraction * 100)) of the records scanned for \(providerName) "
                        + "name a model with no known price.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }

            // Lazy: the core reports every unpriced model it finds, worst first,
            // and a provider mid-transition can name a lot of them.
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(canary.unpriced_models) { model in
                    UnpricedModelRow(model: model)
                }
            }
        }
    }
}

/// One unpriced model: its id as the logs record it, then the volume it
/// contributes to token totals and the fact that it contributes nothing to cost.
///
/// There is deliberately no dollar figure on this row — not even `$0`. The core
/// refuses to guess a rate it doesn't know, and a `$0` would tell the user this
/// model was free when the truth is that its cost is simply unknown.
struct UnpricedModelRow: View {
    let model: UnpricedModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "cube")
                .imageScale(.small)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.model)
                    .font(.caption.weight(.semibold).monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(Format.tokens(model.records)) records · \(Format.tokens(model.tokens.grandTotal)) "
                    + "tokens counted · excluded from cost estimates")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.model): \(Format.tokens(model.tokens.grandTotal)) tokens across "
            + "\(Format.tokens(model.records)) records, counted in usage totals but excluded from cost estimates.")
    }
}

// MARK: - Inline banner

/// A compact "your numbers are incomplete" banner for inline use on other
/// surfaces (Home, Overview, the popover). Tapping runs `onTap` — wire it to open
/// the full canary section.
///
/// Renders **nothing** unless at least one canary is `drifted` or unrecognized, so
/// callers can drop it in unconditionally (same contract as
/// ``NeedsAttentionBlock``).
///
/// It stays silent for `no_data` and for an all-`ok` set by design: a banner is an
/// interruption, and neither "nothing to check" nor "verified" warrants one. Note
/// what it therefore never does — it never renders a green "all verified" banner.
/// Silence here means "no complaint", which is not a claim; the full section is
/// where the positive claims live, and where `no_data` is stated out loud.
struct CanaryBanner: View {
    let canaries: [SchemaCanary]
    var onTap: (() -> Void)? = nil

    /// Only states that mean "we can't fully vouch for your numbers".
    private var concerning: [SchemaCanary] {
        canaries.filter { $0.canaryState == .drifted || $0.canaryState == .unknown }
    }

    var body: some View {
        if !concerning.isEmpty {
            let state = concerning.map(\.canaryState).max() ?? .drifted
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: state.icon)
                        .foregroundStyle(state.color)
                    Text(headline(state))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if onTap != nil {
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(detail(state))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlass(cornerRadius: 16, tint: state.color, padding: 12)
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .help(onTap == nil ? "" : "See what StackPulse couldn't account for")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(headline(state)). \(detail(state))")
        }
    }

    private func headline(_ state: CanaryState) -> String {
        state == .drifted ? "Some numbers are incomplete" : "Some checks couldn't be read"
    }

    private func detail(_ state: CanaryState) -> String {
        let providers = concerning.count
        let models = concerning.reduce(0) { $0 + $1.unpriced_models.count }
        var parts = ["\(providers) provider\(providers == 1 ? "" : "s")"]
        if models > 0 {
            let tokens = concerning.reduce(UInt64(0)) { $0 + $1.unpricedTokens }
            parts.append("\(models) model\(models == 1 ? "" : "s") · \(Format.tokens(tokens)) tokens "
                + "counted but excluded from cost estimates")
        } else if state == .unknown {
            parts.append("this version can't tell whether these totals are complete")
        }
        return parts.joined(separator: " · ")
    }
}
