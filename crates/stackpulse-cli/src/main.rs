//! `stackpulse` CLI.
//!
//! Usage:
//!   stackpulse snapshot                 Human-readable usage summary
//!   stackpulse snapshot --json          Full UsageSnapshot as JSON
//!   stackpulse status                   Cheap per-provider detection
//!   stackpulse missions [--json]        Recently-active AI coding sessions
//!   stackpulse projects <root>… [--json]  Discover projects + commands under roots
//!   stackpulse history <data_dir> [--days N] [--json]  Record + read durable usage history
//!   stackpulse ping                     Core / protocol versions
//!   stackpulse request '<json>'         Send a raw CoreRequest, print the JSON reply
//!
//! This binary is intentionally thin: all logic lives in `stackpulse-core`.

use stackpulse_core::Engine;
use stackpulse_protocol::{
    CommandSafety, CoreRequest, CoreResponse, HistoryPoint, Mission, MissionStatus, Project,
    UsageSnapshot,
};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(String::as_str).unwrap_or("snapshot");
    let engine = Engine::new();

    match cmd {
        "ping" => println!("{}", engine.handle_json(r#"{"op":"ping"}"#)),
        "status" => println!("{}", engine.handle_json(r#"{"op":"get_provider_status"}"#)),
        "request" => {
            let raw = args.get(1).map(String::as_str).unwrap_or("");
            println!("{}", engine.handle_json(raw));
        }
        "snapshot" => {
            let json_out = args.iter().any(|a| a == "--json");
            let out = engine.handle_json(r#"{"op":"get_usage_snapshot"}"#);
            if json_out {
                println!("{out}");
            } else {
                match serde_json::from_str::<CoreResponse>(&out) {
                    Ok(CoreResponse::UsageSnapshot(s)) => print_summary(&s),
                    _ => println!("{out}"),
                }
            }
        }
        "missions" => {
            let json_out = args.iter().any(|a| a == "--json");
            let out = engine.handle_json(r#"{"op":"get_usage_snapshot"}"#);
            match serde_json::from_str::<CoreResponse>(&out) {
                Ok(CoreResponse::UsageSnapshot(s)) => {
                    if json_out {
                        // Serializing our own snapshot's missions cannot fail.
                        println!(
                            "{}",
                            serde_json::to_string_pretty(&s.missions).unwrap_or_default()
                        );
                    } else {
                        print_missions(&s.missions, s.generated_at_unix);
                    }
                }
                _ => println!("{out}"),
            }
        }
        "projects" => {
            let json_out = args.iter().any(|a| a == "--json");
            let roots: Vec<String> = args
                .iter()
                .skip(1)
                .filter(|a| !a.starts_with("--"))
                .cloned()
                .collect();
            if roots.is_empty() {
                eprintln!("usage: stackpulse projects <root> [<root2> …] [--json]");
                std::process::exit(2);
            }
            let request = CoreRequest::GetProjects {
                roots,
                max_depth: None,
            };
            // Serializing our own request type cannot fail.
            let request_json = serde_json::to_string(&request).unwrap_or_default();
            let out = engine.handle_json(&request_json);
            if json_out {
                println!("{out}");
            } else {
                match serde_json::from_str::<CoreResponse>(&out) {
                    Ok(CoreResponse::Projects { projects }) => print_projects(&projects),
                    _ => println!("{out}"),
                }
            }
        }
        "history" => {
            let json_out = args.iter().any(|a| a == "--json");
            // First non-flag argument after the command is the data directory.
            let data_dir = args.iter().skip(1).find(|a| !a.starts_with("--")).cloned();
            let Some(data_dir) = data_dir else {
                eprintln!("usage: stackpulse history <data_dir> [--days N] [--json]");
                std::process::exit(2);
            };
            // Optional `--days N`.
            let days = args
                .iter()
                .position(|a| a == "--days")
                .and_then(|i| args.get(i + 1))
                .and_then(|n| n.parse::<u32>().ok());
            // Record (which also seeds from the 30-day analytics) then return the
            // accumulated history.
            let request = CoreRequest::RecordHistory { data_dir, days };
            // Serializing our own request type cannot fail.
            let request_json = serde_json::to_string(&request).unwrap_or_default();
            let out = engine.handle_json(&request_json);
            if json_out {
                println!("{out}");
            } else {
                match serde_json::from_str::<CoreResponse>(&out) {
                    Ok(CoreResponse::History { points }) => print_history(&points),
                    _ => println!("{out}"),
                }
            }
        }
        "--help" | "-h" | "help" => print_help(),
        other => {
            eprintln!("unknown command: {other}\n");
            print_help();
            std::process::exit(2);
        }
    }
}

fn print_help() {
    eprintln!(
        "stackpulse {} (core {}, protocol {})\n\n\
         COMMANDS:\n  \
         snapshot [--json]        usage summary (default)\n  \
         status                   per-provider detection\n  \
         missions [--json]        recently-active AI coding sessions\n  \
         projects <root>… [--json]  discover projects + commands under roots\n  \
         history <data_dir> [--days N] [--json]  record + read durable usage history\n  \
         ping                     versions\n  \
         request '<json>'         raw CoreRequest → JSON reply",
        env!("CARGO_PKG_VERSION"),
        stackpulse_core::version_string(),
        stackpulse_protocol::PROTOCOL_VERSION,
    );
}

fn fmt_usd(v: Option<f64>) -> String {
    match v {
        Some(c) => format!("${c:.2}"),
        None => "—".to_string(),
    }
}

fn fmt_tokens(n: u64) -> String {
    if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1_000_000.0)
    } else if n >= 1_000 {
        format!("{:.1}k", n as f64 / 1_000.0)
    } else {
        n.to_string()
    }
}

fn print_summary(s: &UsageSnapshot) {
    println!(
        "StackPulse — usage snapshot (UTC bucket {})",
        s.bucket_date_utc
    );
    println!("core {}  protocol {}", s.core_version, s.protocol_version);
    println!("{}\n", s.pricing_note);

    for p in &s.providers {
        let mark = if p.installed { "●" } else { "○" };
        let auth = if p.authenticated {
            "auth ✓"
        } else {
            "auth ✗"
        };
        let ver = p.detected_version.as_deref().unwrap_or("?");
        let plan = p
            .plan_hint
            .as_deref()
            .map(|x| format!(" plan:{x}"))
            .unwrap_or_default();
        println!(
            "{mark} {} ({:?})  {auth}  v{ver}{plan}",
            p.display_name, p.health
        );

        for w in &p.windows {
            let t = &w.tokens;
            println!(
                "    {:<13} {:>8}  in {:>7} out {:>7} cache-rd {:>7} ({} turns)",
                w.label,
                fmt_usd(w.estimated_cost_usd),
                fmt_tokens(t.input_tokens),
                fmt_tokens(t.output_tokens),
                fmt_tokens(t.cache_read_tokens),
                w.records,
            );
        }
        for l in &p.limits {
            let reset = l
                .resets_at_unix
                .map(|r| format!(" resets@{r}"))
                .unwrap_or_default();
            println!(
                "    limit {:<8} {:>5.1}% of {}m{reset}",
                l.label, l.used_percent, l.window_minutes
            );
        }
        if let Some(top) = p.models.first() {
            println!(
                "    top model     {} ({})",
                top.model,
                fmt_usd(top.estimated_cost_usd)
            );
        }
        for note in &p.notes {
            println!("    · {note}");
        }
        println!();
    }
}

fn mission_status_label(status: MissionStatus) -> &'static str {
    match status {
        MissionStatus::Active => "active",
        MissionStatus::Idle => "idle",
        MissionStatus::Recent => "recent",
        MissionStatus::Stalled => "stalled",
        MissionStatus::Unknown => "unknown",
    }
}

/// Compact "how long ago" from two Unix-seconds instants.
fn fmt_ago(now_unix: i64, then_unix: i64) -> String {
    let d = now_unix - then_unix;
    if d <= 0 {
        "now".to_string()
    } else if d < 90 {
        format!("{d}s ago")
    } else if d < 5400 {
        format!("{}m ago", (d + 30) / 60)
    } else {
        format!("{}h ago", (d + 1800) / 3600)
    }
}

fn print_missions(missions: &[Mission], now_unix: i64) {
    if missions.is_empty() {
        println!("No AI coding sessions active in the last 2 hours.");
        return;
    }
    println!("Agent Mission Control — {} session(s):\n", missions.len());
    for m in missions {
        let project = m.project_name.as_deref().unwrap_or("—");
        let branch = m
            .branch
            .as_deref()
            .map(|b| format!(" ({b})"))
            .unwrap_or_default();
        let model = m.model.as_deref().unwrap_or("—");
        let activity = m
            .last_activity
            .as_deref()
            .map(|a| format!("  · {a}"))
            .unwrap_or_default();
        println!(
            "{:<7} {:<26} {:<18} {:<8} {:<10} {:>4} msgs  {:>8} tok/hr{}",
            m.provider.display_name(),
            truncate(&format!("{project}{branch}"), 26),
            truncate(model, 18),
            mission_status_label(m.status),
            fmt_ago(now_unix, m.last_activity_unix),
            m.message_count,
            fmt_tokens(m.tokens_last_hour),
            activity,
        );
    }
}

/// Truncate a display string to `max` chars, adding an ellipsis when clipped.
fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let keep = max.saturating_sub(1);
        format!("{}…", s.chars().take(keep).collect::<String>())
    }
}

fn safety_label(safety: CommandSafety) -> &'static str {
    match safety {
        CommandSafety::ReadOnly => "read-only",
        CommandSafety::LocalDev => "local-dev",
        CommandSafety::ModifiesFiles => "modifies-files",
        CommandSafety::InstallsDeps => "installs-deps",
        CommandSafety::ChangesDatabase => "changes-database",
        CommandSafety::Network => "network",
        CommandSafety::Destructive => "destructive",
    }
}

fn print_projects(projects: &[Project]) {
    if projects.is_empty() {
        println!("No projects found under the given roots.");
        return;
    }
    println!("Found {} project(s):\n", projects.len());
    for p in projects {
        println!("{}  —  {}", p.name, p.path);

        let mut bits: Vec<String> = Vec::new();
        if !p.markers.is_empty() {
            bits.push(format!("markers: {}", p.markers.join(", ")));
        }
        if !p.frameworks.is_empty() {
            bits.push(format!("frameworks: {}", p.frameworks.join(", ")));
        }
        if let Some(pm) = &p.package_manager {
            bits.push(format!("pm: {pm}"));
        }
        if let Some(branch) = &p.git_branch {
            bits.push(format!("branch: {branch}"));
        }
        if !bits.is_empty() {
            println!("    {}", bits.join("  ·  "));
        }
        if let Some(remote) = &p.git_remote {
            println!("    remote: {remote}");
        }
        for w in &p.warnings {
            println!("    ! {w}");
        }
        for c in &p.commands {
            println!(
                "    {:<12} {:<30} [{}]",
                c.label,
                c.command,
                safety_label(c.safety)
            );
        }
        println!();
    }
}

fn print_history(points: &[HistoryPoint]) {
    if points.is_empty() {
        println!("No usage history recorded yet.");
        return;
    }
    println!(
        "StackPulse — durable usage history ({} day-point(s))\n",
        points.len()
    );

    // Group by provider (points arrive sorted by date, so per-provider rows stay
    // in chronological order). A BTreeMap keeps providers in a stable order.
    let mut by_provider: std::collections::BTreeMap<&str, Vec<&HistoryPoint>> =
        std::collections::BTreeMap::new();
    for p in points {
        by_provider
            .entry(p.provider.display_name())
            .or_default()
            .push(p);
    }

    for (provider, rows) in &by_provider {
        let total: f64 = rows.iter().filter_map(|r| r.estimated_cost_usd).sum();
        let total = if total > 0.0 { Some(total) } else { None };
        println!(
            "{provider}  ({} day(s), ~{} est.)",
            rows.len(),
            fmt_usd(total)
        );
        for r in rows {
            let t = &r.tokens;
            println!(
                "    {}  {:>8}  in {:>7} out {:>7} cache-rd {:>7} ({} turns)",
                r.date,
                fmt_usd(r.estimated_cost_usd),
                fmt_tokens(t.input_tokens),
                fmt_tokens(t.output_tokens),
                fmt_tokens(t.cache_read_tokens),
                r.records,
            );
        }
        println!();
    }
}
