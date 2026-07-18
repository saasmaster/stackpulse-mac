import Foundation

/// Sample data for "see it with sample data" mode — so someone who clones and runs
/// StackPulse with no AI-tool logs yet can see the actual product, not a wall of
/// empty cards.
///
/// **The ethos guard:** this is FAKE, and the app must never let it be mistaken for
/// real. Demo mode is off by default, opt-in, persisted, and — wherever demo data
/// is shown — a prominent "Sample data — not from your Mac" banner is displayed
/// (`DemoBanner`). This type only builds the data; the store gates it behind
/// `demoMode` and the surfaces carry the banner.
///
/// The sample is built by decoding JSON through the **real** `UsageSnapshot`
/// decoder, so it can never drift into an invalid shape the rest of the app
/// wouldn't accept — if the model changes incompatibly, this fails loudly in tests
/// rather than rendering something malformed.
enum DemoData {

    /// A representative snapshot: Claude and Codex with real-looking spend, live
    /// limits (one of them on track to run out, to show the forecast), and
    /// Antigravity as an activity-only provider. Timestamps are relative to `now`
    /// so limits read as current and forecasts behave.
    static func snapshot(now: Date) -> UsageSnapshot {
        let t = Int(now.timeIntervalSince1970)
        let fiveHourReset = t + 2 * 3600
        let weeklyReset = t + 4 * 86_400
        let bucket = utcDay(now)

        let json = """
        {
          "protocol_version": {"major": 1, "minor": 20, "patch": 0},
          "core_version": "0.1.0-demo",
          "generated_at_unix": \(t),
          "bucket_date_utc": "\(bucket)",
          "pricing_note": "Sample data — costs are illustrative local estimates, not a bill.",
          "alerts": [],
          "insights": [
            {"id": "demo-cache", "kind": "low_cache_efficiency", "impact": "medium",
             "title": "lodash-heavy project could cache more",
             "detail": "Sample insight: your cache hit rate on one project is 41% — raising it would cut input cost.",
             "provider": "claude"}
          ],
          "canaries": [
            {"provider": "claude", "status": "ok", "checked_at_unix": \(t),
             "detail": "Sample: everything read from the logs was understood.",
             "files_seen": 128, "records_parsed": 4213, "unpriced_models": []}
          ],
          "missions": [
            {"provider": "claude", "session_id": "demo-1", "project_path": "/Users/you/code/acme-web",
             "project_name": "acme-web", "branch": "feat/checkout", "model": "claude-opus-4-8",
             "last_activity_unix": \(t - 40), "status": "active", "message_count": 37,
             "started_at_unix": \(t - 2400), "last_message_preview": "Wiring the Stripe webhook handler and adding a test.",
             "changed_files": ["src/api/webhook.ts", "src/api/webhook.test.ts"], "scope_flags": [],
             "tokens_last_hour": 184000},
            {"provider": "codex", "session_id": "demo-2", "project_path": "/Users/you/code/data-pipeline",
             "project_name": "data-pipeline", "branch": "main", "model": "gpt-5.5",
             "last_activity_unix": \(t - 900), "status": "idle", "message_count": 12,
             "started_at_unix": \(t - 3600), "last_message_preview": "Refactoring the ingest job into batches.",
             "changed_files": ["ingest/batch.py"], "scope_flags": [], "tokens_last_hour": 42000}
          ],
          "providers": [
            \(claudeJSON(fiveHourReset: fiveHourReset, weeklyReset: weeklyReset, capturedAt: t)),
            \(codexJSON(weeklyReset: weeklyReset, capturedAt: t)),
            \(antigravityJSON())
          ]
        }
        """
        // Decoding through the real path guarantees validity; a demo build that
        // can't decode is a bug we want to see immediately, hence the force.
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
    }

    /// Missions shown in demo mode (the popover / Missions section read these).
    static func missions(now: Date) -> [Mission] {
        snapshot(now: now).missions
    }

    // MARK: Providers

    private static func claudeJSON(fiveHourReset: Int, weeklyReset: Int, capturedAt: Int) -> String {
        """
        {
          "provider": "claude", "display_name": "Claude Code", "health": "fully_supported",
          "installed": true, "authenticated": true, "detected_version": "2.1.7",
          "plan_hint": "max", "capabilities": [], "notes": [], "analytics": null,
          "windows": [
            \(window("today", input: 210000, output: 74000, cacheRead: 1_900_000, cacheWrite: 240000, cost: 6.42, records: 41)),
            \(window("last_30_days", input: 5_400_000, output: 1_950_000, cacheRead: 61_000_000, cacheWrite: 7_100_000, cost: 168.30, records: 1_284))
          ],
          "models": [
            \(model("claude-opus-4-8", input: 4_100_000, output: 1_600_000, cost: 141.20, records: 820)),
            \(model("claude-sonnet-5", input: 1_300_000, output: 350000, cost: 27.10, records: 464))
          ],
          "limits": [
            {"label": "5h", "used_percent": 58.0, "window_minutes": 300, "resets_at_unix": \(fiveHourReset), "provenance": "provider_reported", "captured_at_unix": \(capturedAt)},
            {"label": "weekly", "used_percent": 34.0, "window_minutes": 10080, "resets_at_unix": \(weeklyReset), "provenance": "provider_reported", "captured_at_unix": \(capturedAt)}
          ]
        }
        """
    }

    private static func codexJSON(weeklyReset: Int, capturedAt: Int) -> String {
        """
        {
          "provider": "codex", "display_name": "Codex", "health": "fully_supported",
          "installed": true, "authenticated": true, "detected_version": "1.4.2",
          "plan_hint": "plus", "capabilities": [], "notes": [], "analytics": null,
          "windows": [
            \(window("today", input: 88000, output: 21000, cacheRead: 640000, cacheWrite: 0, cost: 2.05, records: 18)),
            \(window("last_30_days", input: 2_100_000, output: 540000, cacheRead: 18_000_000, cacheWrite: 0, cost: 61.40, records: 402))
          ],
          "models": [\(model("gpt-5.5", input: 1_800_000, output: 480000, cost: 55.20, records: 300))],
          "limits": [
            {"label": "weekly", "used_percent": 71.0, "window_minutes": 10080, "resets_at_unix": \(weeklyReset), "provenance": "provider_reported", "captured_at_unix": \(capturedAt)}
          ]
        }
        """
    }

    private static func antigravityJSON() -> String {
        """
        {
          "provider": "antigravity", "display_name": "Antigravity", "health": "fully_supported",
          "installed": true, "authenticated": true, "detected_version": null,
          "plan_hint": null, "capabilities": [], "analytics": null,
          "notes": ["Sample: Antigravity's token and cost usage is metered server-side by Gemini and isn't available locally."],
          "windows": [
            \(window("today", input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: nil, records: 2)),
            \(window("last_30_days", input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: nil, records: 14))
          ],
          "models": [\(model("gemini-3-flash-agent", input: 0, output: 0, cost: nil, records: 14))],
          "limits": []
        }
        """
    }

    // MARK: Builders

    private static func window(_ label: String, input: Int, output: Int, cacheRead: Int,
                               cacheWrite: Int, cost: Double?, records: Int) -> String {
        """
        {"label": "\(label)",
         "tokens": {"input_tokens": \(input), "output_tokens": \(output),
                    "cache_creation_tokens": \(cacheWrite), "cache_read_tokens": \(cacheRead),
                    "reasoning_tokens": 0},
         "estimated_cost_usd": \(cost.map { String($0) } ?? "null"), "records": \(records)}
        """
    }

    private static func model(_ name: String, input: Int, output: Int, cost: Double?, records: Int) -> String {
        """
        {"model": "\(name)",
         "tokens": {"input_tokens": \(input), "output_tokens": \(output),
                    "cache_creation_tokens": 0, "cache_read_tokens": 0, "reasoning_tokens": 0},
         "estimated_cost_usd": \(cost.map { String($0) } ?? "null"), "records": \(records)}
        """
    }

    private static func utcDay(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
    }
}
