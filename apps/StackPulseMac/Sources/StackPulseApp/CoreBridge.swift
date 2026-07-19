import Foundation
import CStackPulseCore

/// Swift front door to the Rust portable core over the C ABI.
///
/// All methods are `nonisolated` and safe to call off the main actor — the
/// snapshot scan is heavy (it reads the local session logs) and must never run
/// on the main thread. Every string returned by the core is freed here via
/// `sp_core_string_free`, honoring the FFI memory contract.
enum CoreBridge {
    /// Send a raw JSON `CoreRequest`, return the raw JSON `CoreResponse`.
    static func handle(_ requestJSON: String) -> String {
        requestJSON.withCString { reqPtr -> String in
            guard let out = sp_core_handle_request(reqPtr) else { return "" }
            defer { sp_core_string_free(out) }
            return String(cString: out)
        }
    }

    /// The Rust core crate version.
    static func coreVersion() -> String {
        guard let out = sp_core_version() else { return "?" }
        defer { sp_core_string_free(out) }
        return String(cString: out)
    }

    /// Full usage snapshot, decoded. `nil` if the core returned an error or the
    /// payload could not be decoded.
    ///
    /// Pass `recordHistoryDir` to have the core fold *this* snapshot into the
    /// durable history store while it already has it in hand. Doing that here
    /// rather than with a follow-up `record_history` call matters: that op builds
    /// its own snapshot, so the pair re-read every session log twice per refresh.
    static func snapshot(recordHistoryDir: String? = nil) -> UsageSnapshot? {
        struct Request: Encodable {
            let op = "get_usage_snapshot"
            let record_history_dir: String?
        }
        guard let reqData = try? JSONEncoder().encode(Request(record_history_dir: recordHistoryDir)),
              let reqJSON = String(data: reqData, encoding: .utf8)
        else { return nil }
        let json = handle(reqJSON)
        guard let data = json.data(using: .utf8) else { return nil }
        // The response carries an extra "kind":"usage_snapshot" tag which the
        // decoder simply ignores (unknown keys are skipped).
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    /// Discover projects and their runnable commands under `roots`. Heavy (walks
    /// the filesystem), so call off the main actor.
    ///
    /// Returns `[]` for a genuine "nothing to scan" (no roots) or a successful
    /// scan that found nothing, and **`nil` when the scan itself failed** (a bridge
    /// error or an error/undecodable response). Callers must keep the two apart —
    /// rendering a failure as an empty success is a false all-clear.
    static func projects(roots: [String], maxDepth: Int = 4) -> [Project]? {
        guard !roots.isEmpty else { return [] }

        struct Request: Encodable {
            let op = "get_projects"
            let roots: [String]
            let max_depth: Int
        }
        // Response is tagged `{"kind":"projects","projects":[…]}`; an error
        // response omits `projects`, so decoding fails → `nil` (a real failure),
        // distinct from a decoded-but-empty `[]`.
        struct Response: Decodable { let projects: [Project] }

        guard let reqData = try? JSONEncoder().encode(Request(roots: roots, max_depth: maxDepth)),
              let reqJSON = String(data: reqData, encoding: .utf8)
        else { return nil }

        let json = handle(reqJSON)
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(Response.self, from: data))?.projects
    }

    // MARK: Usage history (protocol ≥ 1.6.0)

    /// Fold today's usage into the durable history store under `dataDir` (seeding
    /// from the 30-day analytics on first run), then return the accumulated
    /// history — optionally limited to the most recent `days`. Reads the local
    /// logs and writes the store, so call off the main actor. Returns `[]` on any
    /// error, an error response, or an undecodable payload — never throws.
    static func recordHistory(dataDir: String, days: Int? = nil) -> [HistoryPoint] {
        history(op: "record_history", dataDir: dataDir, days: days)
    }

    /// Read the accumulated usage history from `dataDir` **without** recording,
    /// optionally limited to the most recent `days`. Cheap (a single file read),
    /// still `nonisolated`. Returns `[]` on any error or undecodable payload.
    static func getHistory(dataDir: String, days: Int? = nil) -> [HistoryPoint] {
        history(op: "get_history", dataDir: dataDir, days: days)
    }

    /// Shared encoder/decoder for the two history ops. The `days` optional is
    /// encoded as-if-present (nil → key omitted), matching the core's
    /// `#[serde(default)]`, so omitting it returns the full history.
    private static func history(op: String, dataDir: String, days: Int?) -> [HistoryPoint] {
        struct Request: Encodable {
            let op: String
            let data_dir: String
            let days: Int?
        }
        // Response is tagged `{"kind":"history","points":[…]}`; an error response
        // omits `points`, so decoding simply yields `[]`.
        struct Response: Decodable { let points: [HistoryPoint] }

        guard let reqData = try? JSONEncoder().encode(Request(op: op, data_dir: dataDir, days: days)),
              let reqJSON = String(data: reqData, encoding: .utf8)
        else { return [] }

        let json = handle(reqJSON)
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode(Response.self, from: data))?.points ?? []
    }

    // MARK: Stack Health (protocol ≥ 1.9.0)

    /// Analyze dependency/stack health for projects under the approved roots.
    /// `checkUpdates` gates the core's network access (registry latest + OSV);
    /// scans manifests/lockfiles + optional network, so call off the main actor.
    /// Returns `[]` on any error, empty roots, or an undecodable payload.
    /// `[]` = no roots / scanned-but-empty; **`nil` = the scan failed** (bridge or
    /// error/undecodable response). See `projects(roots:)` on why they must differ.
    static func stackHealth(roots: [String], checkUpdates: Bool, maxDepth: Int = 4) -> [ProjectStack]? {
        guard !roots.isEmpty else { return [] }
        struct Request: Encodable {
            let op = "get_stack_health"
            let roots: [String]
            let max_depth: Int
            let check_updates: Bool
        }
        struct Response: Decodable { let projects: [ProjectStack] }
        guard let reqData = try? JSONEncoder().encode(
            Request(roots: roots, max_depth: maxDepth, check_updates: checkUpdates)),
              let reqJSON = String(data: reqData, encoding: .utf8)
        else { return nil }
        let json = handle(reqJSON)
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(Response.self, from: data))?.projects
    }

    // MARK: Services (protocol ≥ 1.9.0)

    /// Detect locally-running dev servers/services, matched to the approved roots.
    /// Runs `lsof` + reads process cwds, so call off the main actor. Returns `[]`
    /// on any error or an undecodable payload.
    /// `[]` = scanned, nothing running; **`nil` = the detection failed** (bridge or
    /// error/undecodable response). See `projects(roots:)` on why they must differ.
    static func services(roots: [String]) -> [RunningService]? {
        struct Request: Encodable {
            let op = "get_services"
            let roots: [String]
        }
        struct Response: Decodable { let services: [RunningService] }
        guard let reqData = try? JSONEncoder().encode(Request(roots: roots)),
              let reqJSON = String(data: reqData, encoding: .utf8)
        else { return nil }
        let json = handle(reqJSON)
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(Response.self, from: data))?.services
    }

    // MARK: Worktrees (protocol ≥ 1.15.0)

    /// The result of a worktree op: the repo's worktrees and an honest note when
    /// nothing could be created/listed.
    struct WorktreeResult: Decodable {
        let worktrees: [Worktree]
        let note: String?
    }

    /// List the repository's worktrees. Shells out to git; call off the main actor.
    static func listWorktrees(projectPath: String) -> WorktreeResult? {
        struct Request: Encodable {
            let op = "list_worktrees"
            let project_path: String
        }
        guard let data = try? JSONEncoder().encode(Request(project_path: projectPath)),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return decodeWorktrees(handle(json))
    }

    /// Create an isolated worktree under `worktreesDir` on a new branch.
    static func createWorktree(projectPath: String, worktreesDir: String, name: String) -> WorktreeResult? {
        struct Request: Encodable {
            let op = "create_worktree"
            let project_path: String
            let worktrees_dir: String
            let name: String
        }
        guard let data = try? JSONEncoder().encode(
                Request(project_path: projectPath, worktrees_dir: worktreesDir, name: name)),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return decodeWorktrees(handle(json))
    }

    private static func decodeWorktrees(_ json: String) -> WorktreeResult? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorktreeResult.self, from: data)
    }

    // MARK: Checkpoints (protocol ≥ 1.14.0)

    /// The result of a checkpoint op: the project's checkpoints (newest first) and
    /// an honest note when nothing was captured (clean tree, not a git repo, …).
    struct CheckpointResult: Decodable {
        let checkpoints: [Checkpoint]
        let note: String?
    }

    /// Capture a non-destructive snapshot of `projectPath`'s uncommitted work.
    /// Shells out to git, so call off the main actor.
    static func createCheckpoint(projectPath: String, label: String?) -> CheckpointResult? {
        struct Request: Encodable {
            let op = "create_checkpoint"
            let project_path: String
            let label: String?
        }
        guard let data = try? JSONEncoder().encode(Request(project_path: projectPath, label: label)),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return decodeCheckpoints(handle(json))
    }

    /// List a project's checkpoints, newest first. Shells out to git.
    static func listCheckpoints(projectPath: String) -> CheckpointResult? {
        struct Request: Encodable {
            let op = "list_checkpoints"
            let project_path: String
        }
        guard let data = try? JSONEncoder().encode(Request(project_path: projectPath)),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return decodeCheckpoints(handle(json))
    }

    private static func decodeCheckpoints(_ json: String) -> CheckpointResult? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CheckpointResult.self, from: data)
    }

    // MARK: Project usage (protocol ≥ 1.13.0)

    /// Per-project spend attribution. Re-reads the session logs, so call off the
    /// main actor. `[]` = scanned, nothing attributable; **`nil` = the scan failed**
    /// (bridge or error/undecodable response) — callers must not render that as an
    /// empty success. See `projects(roots:)`.
    static func projectUsage() -> [ProjectUsage]? {
        struct Response: Decodable { let projects: [ProjectUsage] }
        let json = handle(#"{"op":"get_project_usage"}"#)
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(Response.self, from: data))?.projects
    }

    // MARK: Repository Radar (protocol ≥ 1.11.0)

    /// Run the Repository Radar over the approved roots. Discovers projects and
    /// runs deterministic, local-only rules (filesystem + git), so call off the
    /// main actor. Returns `nil` on error / empty roots / undecodable payload.
    static func radar(roots: [String], maxDepth: Int = 4) -> RadarReport? {
        guard !roots.isEmpty else { return nil }
        struct Request: Encodable {
            let op = "get_radar"
            let roots: [String]
            let max_depth: Int
        }
        guard let reqData = try? JSONEncoder().encode(Request(roots: roots, max_depth: maxDepth)),
              let reqJSON = String(data: reqData, encoding: .utf8)
        else { return nil }
        let json = handle(reqJSON)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RadarReport.self, from: data)
    }
}
