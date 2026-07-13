import AppKit
import Foundation

/// Pure, view-free data export for StackPulse. Turns a ``UsageSnapshot`` or the
/// durable ``HistoryPoint`` series into CSV / JSON / a copyable text summary, and
/// provides two small `@MainActor` AppKit helpers (a user-driven Save panel and a
/// clipboard copy). Everything here stays local — the strings are handed to a
/// file the user picks or to the pasteboard; nothing is uploaded.
///
/// Kept deliberately free of any SwiftUI type so the formatting is trivially
/// testable and reusable from any view. Costs are the same local list-price
/// estimates used everywhere else, never a billed amount.
enum Exporter {

    // MARK: - CSV

    /// Full history as CSV: a header row then one row per ``HistoryPoint``,
    /// oldest-order-preserving (the caller passes `store.history` as-is).
    static func historyCSV(_ points: [HistoryPoint]) -> String {
        var rows: [String] = [
            "date,provider,input_tokens,output_tokens,cache_creation_tokens,cache_read_tokens,total_tokens,estimated_cost_usd,records"
        ]
        for p in points {
            rows.append([
                csvField(p.date),
                csvField(p.provider),
                String(p.tokens.input_tokens),
                String(p.tokens.output_tokens),
                String(p.tokens.cache_creation_tokens),
                String(p.tokens.cache_read_tokens),
                String(p.tokens.grandTotal),
                numberField(p.estimated_cost_usd),
                String(p.records),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Current snapshot as CSV: one row per provider with its "today" and
    /// "last_30_days" window token totals + estimated cost, plus install state.
    static func snapshotCSV(_ snapshot: UsageSnapshot) -> String {
        var rows: [String] = [
            "provider,display_name,today_total_tokens,today_cost_usd,last30_total_tokens,last30_cost_usd,installed"
        ]
        for p in snapshot.providers {
            rows.append([
                csvField(p.provider),
                csvField(p.display_name),
                String(p.today?.tokens.grandTotal ?? 0),
                numberField(p.today?.estimated_cost_usd),
                String(p.last30?.tokens.grandTotal ?? 0),
                numberField(p.last30?.estimated_cost_usd),
                String(p.installed),
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    // MARK: - JSON

    /// The whole snapshot as pretty-printed, key-sorted JSON. `"{}"` on failure.
    static func snapshotJSON(_ snapshot: UsageSnapshot) -> String {
        encodeJSON(snapshot)
    }

    /// The full history array as pretty-printed, key-sorted JSON. `"{}"` on failure.
    static func historyJSON(_ points: [HistoryPoint]) -> String {
        encodeJSON(points)
    }

    // MARK: - Human-readable summary (clipboard)

    /// A short multi-line report suitable for pasting into a note or a message:
    /// a title with the UTC bucket date, one line per provider that has usage,
    /// then the snapshot's pricing note. Example provider line:
    /// `Claude — today: 248M tokens (~$3.20) · 30d: 5.1B (~$61.40)`.
    static func textSummary(_ snapshot: UsageSnapshot) -> String {
        var lines: [String] = []
        lines.append("StackPulse usage — \(snapshot.bucket_date_utc) (UTC)")
        lines.append("")

        let active = snapshot.providers.filter {
            ($0.today?.tokens.grandTotal ?? 0) > 0 || ($0.last30?.tokens.grandTotal ?? 0) > 0
        }

        if active.isEmpty {
            lines.append("No usage recorded yet.")
        } else {
            for p in active {
                let todayTokens = p.today?.tokens.grandTotal ?? 0
                let last30Tokens = p.last30?.tokens.grandTotal ?? 0
                let todayCost = p.today?.estimated_cost_usd.map { " (~\(Format.usd($0)))" } ?? ""
                let last30Cost = p.last30?.estimated_cost_usd.map { " (~\(Format.usd($0)))" } ?? ""
                lines.append(
                    "\(p.display_name) — today: \(Format.tokens(todayTokens)) tokens\(todayCost)"
                    + " · 30d: \(Format.tokens(last30Tokens))\(last30Cost)"
                )
            }
        }

        lines.append("")
        lines.append(snapshot.pricing_note)
        return lines.joined(separator: "\n")
    }

    // MARK: - AppKit side effects (user-initiated)

    /// Presents a Save panel so the user picks the destination, then writes the
    /// text there. This is a user-driven save (the user chooses the location and
    /// filename) — nothing is written without the panel.
    @MainActor
    static func save(text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export StackPulse data"
        panel.prompt = "Export"
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Copies `text` to the general pasteboard (clears existing contents first).
    @MainActor
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Helpers

    /// Pretty-printed, deterministic JSON for any `Encodable`. Both exported types
    /// are `Codable`; sorted keys keep diffs/output stable. `"{}"` on failure.
    private static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    /// Escapes a CSV field: wraps in double quotes and doubles any internal quote
    /// when the value contains a comma, quote, or newline. Simple values pass
    /// through unquoted.
    private static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    /// A plain numeric CSV field for an optional cost — empty when absent, so a
    /// spreadsheet reads it as a blank cell rather than a literal "nil".
    private static func numberField(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.4f", value)
    }
}
