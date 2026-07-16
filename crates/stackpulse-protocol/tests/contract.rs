//! Wire-contract tests.
//!
//! `stackpulse-protocol` is the one thing a future Windows client and the Chrome
//! native-messaging host both compile against, and they may ship on a *different
//! release cadence* than this app. Nothing else in the repo pins the actual bytes
//! on the wire, so a rename, a retag, or a dropped `#[serde(default)]` could break
//! those consumers silently — the Rust would still compile, and the macOS app
//! (which serializes and deserializes with the same code) would never notice.
//!
//! These tests encode the promises `docs/PROTOCOL.md` makes to those consumers:
//!
//! 1. **Tagging** — requests are tagged by `op`, responses by `kind`, and the
//!    documented string for each variant never moves.
//! 2. **Producers strict, consumers lenient** — an older reader must survive a
//!    newer payload: unknown enum values fall back to a catch-all, and additive
//!    fields are optional.
//! 3. **The docs don't drift** — `PROTOCOL_VERSION` and `docs/PROTOCOL.md` agree.
//!
//! They deliberately assert on **literal JSON**, not on round-tripping through
//! our own types: a round-trip passes even if every field were renamed, which is
//! exactly the break we're trying to catch.

use serde_json::{json, Value};
use stackpulse_protocol::*;

// ---------------------------------------------------------------------------
// 1. Envelope tagging
// ---------------------------------------------------------------------------

/// The `op` string for every request variant. A consumer hard-codes these, so a
/// change here is a breaking protocol change and must bump the major version.
#[test]
fn request_op_tags_are_stable() {
    let cases: Vec<(CoreRequest, &str)> = vec![
        (CoreRequest::Ping, "ping"),
        (CoreRequest::GetProviderStatus, "get_provider_status"),
        (
            CoreRequest::GetUsageSnapshot {
                providers: None,
                record_history_dir: None,
            },
            "get_usage_snapshot",
        ),
        (
            CoreRequest::GetProjects {
                roots: vec![],
                max_depth: None,
            },
            "get_projects",
        ),
        (
            CoreRequest::RecordHistory {
                data_dir: "/tmp".into(),
                days: None,
            },
            "record_history",
        ),
        (
            CoreRequest::GetHistory {
                data_dir: "/tmp".into(),
                days: None,
            },
            "get_history",
        ),
        (
            CoreRequest::GetStackHealth {
                roots: vec![],
                max_depth: None,
                check_updates: false,
            },
            "get_stack_health",
        ),
        (CoreRequest::GetServices { roots: vec![] }, "get_services"),
        (
            CoreRequest::GetRadar {
                roots: vec![],
                max_depth: None,
            },
            "get_radar",
        ),
        (CoreRequest::GetProjectUsage, "get_project_usage"),
        (
            CoreRequest::CreateCheckpoint {
                project_path: "/tmp".into(),
                label: None,
            },
            "create_checkpoint",
        ),
        (
            CoreRequest::ListCheckpoints {
                project_path: "/tmp".into(),
            },
            "list_checkpoints",
        ),
        (
            CoreRequest::ListWorktrees {
                project_path: "/tmp".into(),
            },
            "list_worktrees",
        ),
        (
            CoreRequest::CreateWorktree {
                project_path: "/tmp".into(),
                worktrees_dir: "/tmp".into(),
                name: "x".into(),
            },
            "create_worktree",
        ),
    ];

    for (request, expected) in cases {
        let v: Value = serde_json::to_value(&request).expect("serialize request");
        assert_eq!(
            v.get("op").and_then(Value::as_str),
            Some(expected),
            "op tag moved for {request:?} — this breaks every downstream consumer"
        );
    }
}

/// Every request variant a client sends must also parse back. Guards against a
/// variant that serializes but can't be read (e.g. a field renamed on one side).
#[test]
fn documented_request_json_parses() {
    let documented = [
        json!({"op": "ping"}),
        json!({"op": "get_provider_status"}),
        json!({"op": "get_usage_snapshot"}),
        json!({"op": "get_usage_snapshot", "providers": ["claude", "codex"]}),
        // record_history_dir is additive (1.16.0) — older clients omit it.
        json!({"op": "get_usage_snapshot", "record_history_dir": "/tmp/x"}),
        json!({"op": "get_projects", "roots": ["/Users/me/code"], "max_depth": 4}),
        json!({"op": "get_projects", "roots": []}), // max_depth is optional
        json!({"op": "record_history", "data_dir": "/tmp"}),
        json!({"op": "get_history", "data_dir": "/tmp", "days": 30}),
        json!({"op": "get_stack_health", "roots": ["/x"], "check_updates": true}),
        json!({"op": "get_services", "roots": []}),
        json!({"op": "get_radar", "roots": ["/x"]}),
        json!({"op": "get_project_usage"}),
        json!({"op": "create_checkpoint", "project_path": "/x"}),
        json!({"op": "list_checkpoints", "project_path": "/x"}),
        json!({"op": "list_worktrees", "project_path": "/x"}),
        json!({"op": "create_worktree", "project_path": "/x", "worktrees_dir": "/w", "name": "n"}),
    ];
    for value in documented {
        serde_json::from_value::<CoreRequest>(value.clone())
            .unwrap_or_else(|e| panic!("documented request failed to parse: {value} — {e}"));
    }
}

/// The `kind` string for every response variant.
#[test]
fn response_kind_tags_are_stable() {
    let pong = CoreResponse::Pong {
        protocol_version: PROTOCOL_VERSION,
        core_version: "0.1.0".into(),
    };
    assert_eq!(kind_of(&pong), "pong");

    assert_eq!(
        kind_of(&CoreResponse::ProviderStatus { providers: vec![] }),
        "provider_status"
    );
    assert_eq!(
        kind_of(&CoreResponse::Projects { projects: vec![] }),
        "projects"
    );
    assert_eq!(
        kind_of(&CoreResponse::History { points: vec![] }),
        "history"
    );
    assert_eq!(
        kind_of(&CoreResponse::StackHealth { projects: vec![] }),
        "stack_health"
    );
    assert_eq!(
        kind_of(&CoreResponse::Services { services: vec![] }),
        "services"
    );
    assert_eq!(
        kind_of(&CoreResponse::ProjectUsage { projects: vec![] }),
        "project_usage"
    );
    assert_eq!(
        kind_of(&CoreResponse::Checkpoints {
            checkpoints: vec![],
            note: None
        }),
        "checkpoints"
    );
    assert_eq!(
        kind_of(&CoreResponse::Worktrees {
            worktrees: vec![],
            note: None
        }),
        "worktrees"
    );
    assert_eq!(
        kind_of(&CoreResponse::Error(CoreError::new(
            ErrorCode::BadRequest,
            "x"
        ))),
        "error"
    );
}

/// Newtype response variants must **flatten** their payload next to `kind` rather
/// than nesting it. The Swift client decodes `UsageSnapshot`/`CoreError`/
/// `RadarReport` straight out of the response body and simply ignores `kind`;
/// nesting would break every one of those decoders at once.
#[test]
fn newtype_responses_flatten_next_to_kind() {
    let err = CoreResponse::Error(CoreError::new(ErrorCode::BadRequest, "nope"));
    let v = serde_json::to_value(&err).unwrap();
    assert_eq!(v["kind"], "error");
    assert_eq!(v["code"], "bad_request", "CoreError must flatten, not nest");
    assert_eq!(v["message"], "nope");
    assert!(v.get("0").is_none(), "must not serialize as a tuple");

    let radar = CoreResponse::Radar(RadarReport {
        generated_at_unix: 1,
        projects_scanned: 2,
        recommendations: vec![],
    });
    let v = serde_json::to_value(&radar).unwrap();
    assert_eq!(v["kind"], "radar");
    assert_eq!(v["projects_scanned"], 2, "RadarReport must flatten");
}

fn kind_of(response: &CoreResponse) -> String {
    serde_json::to_value(response).unwrap()["kind"]
        .as_str()
        .expect("every response carries a string `kind`")
        .to_string()
}

// ---------------------------------------------------------------------------
// 2. Forward compatibility — "producers strict, consumers lenient"
// ---------------------------------------------------------------------------

/// Open enums must degrade to their catch-all rather than failing the whole
/// payload. This is what lets a *newer* core talk to an *older* client: the
/// client renders "unknown" instead of dropping the message on the floor.
#[test]
fn unknown_enum_values_fall_back_instead_of_failing() {
    // A provider this build has never heard of.
    let p: ProviderId = serde_json::from_value(json!("some_future_provider")).unwrap();
    assert_eq!(p, ProviderId::Unknown);

    let k: AlertKind = serde_json::from_value(json!("some_future_alert")).unwrap();
    assert_eq!(k, AlertKind::Other);

    let c: RadarCategory = serde_json::from_value(json!("some_future_category")).unwrap();
    assert_eq!(c, RadarCategory::Other);

    let s: ScopeFlagKind = serde_json::from_value(json!("some_future_scope")).unwrap();
    assert_eq!(s, ScopeFlagKind::Other);

    let src: CommandSource = serde_json::from_value(json!("some_future_source")).unwrap();
    assert_eq!(src, CommandSource::Other);
}

/// `TokenTotals::cache_creation_1h_tokens` is additive (since 1.19.0) AND a
/// subset of `cache_creation_tokens`. Both halves matter to a consumer: absent
/// must decode, and the field must never be added to a total.
#[test]
fn cache_creation_1h_is_additive_and_a_subset() {
    let old: TokenTotals = serde_json::from_value(json!({
        "input_tokens": 10,
        "output_tokens": 20,
        "cache_creation_tokens": 100,
        "cache_read_tokens": 50,
        "reasoning_tokens": 0
    }))
    .expect("a pre-1.19.0 TokenTotals must still decode");
    assert_eq!(
        old.cache_creation_1h_tokens, 0,
        "absent ⇒ all writes read as 5-minute"
    );
    assert_eq!(old.grand_total(), 180);

    let new: TokenTotals = serde_json::from_value(json!({
        "input_tokens": 10,
        "output_tokens": 20,
        "cache_creation_tokens": 100,
        "cache_read_tokens": 50,
        "reasoning_tokens": 0,
        "cache_creation_1h_tokens": 80
    }))
    .unwrap();
    // THE trap: 1h tokens are already inside cache_creation_tokens. A total that
    // sums them double-counts 86% of real cache writes.
    assert_eq!(
        new.grand_total(),
        180,
        "the subset must not inflate the total"
    );
    assert_eq!(new.cache_write_split(), (80, 20));

    // An impossible split is clamped rather than underflowing a u64.
    let bogus = TokenTotals {
        cache_creation_tokens: 10,
        cache_creation_1h_tokens: 999,
        ..Default::default()
    };
    assert_eq!(bogus.cache_write_split(), (10, 0));
}

/// `Checkpoint::files_unknown` is additive (since 1.18.0) and must default to the
/// pre-1.18.0 reading — `files: []` meaning "captured nothing", not "git failed".
#[test]
fn checkpoint_files_unknown_is_additive_and_defaults_to_known() {
    let old: Checkpoint = serde_json::from_value(json!({
        "id": "abc123",
        "ref_name": "refs/stackpulse/checkpoints/x",
        "label": "before refactor",
        "project_path": "/tmp/p",
        "created_at_unix": 1_784_000_000,
        "files": [],
        "restore_command": "git -C '/tmp/p' stash apply abc123"
    }))
    .expect("a pre-1.18.0 Checkpoint must still decode");
    assert!(
        !old.files_unknown,
        "absent ⇒ the old reading, not 'unknown'"
    );

    let failed: Checkpoint = serde_json::from_value(json!({
        "id": "abc123",
        "ref_name": "refs/stackpulse/checkpoints/x",
        "label": "before refactor",
        "project_path": "/tmp/p",
        "created_at_unix": 1_784_000_000,
        "files": [],
        "files_unknown": true,
        "restore_command": "git -C '/tmp/p' stash apply abc123"
    }))
    .unwrap();
    // The whole point: an empty list is no longer self-explanatory.
    assert!(failed.files.is_empty() && failed.files_unknown);
}

/// Canaries are additive (since 1.18.0): a pre-1.18.0 snapshot has no `canaries`
/// key and must still decode to an empty list.
#[test]
fn canaries_are_additive_and_status_is_an_open_enum() {
    let s: CanaryStatus = serde_json::from_value(json!("some_future_status")).unwrap();
    assert_eq!(
        s,
        CanaryStatus::Unknown,
        "open enum: never fail on a new value"
    );

    assert_eq!(
        serde_json::to_value(CanaryStatus::Drifted).unwrap(),
        json!("drifted")
    );
    assert_eq!(
        serde_json::to_value(CanaryStatus::NoData).unwrap(),
        json!("no_data")
    );

    let c: SchemaCanary = serde_json::from_value(json!({
        "provider": "claude",
        "status": "drifted",
        "checked_at_unix": 1_784_000_000,
        "detail": "1 model has no pricing entry.",
        "files_seen": 12,
        "records_parsed": 8414
    }))
    .expect("unpriced_models is #[serde(default)]");
    assert!(c.unpriced_models.is_empty());

    let full: SchemaCanary = serde_json::from_value(json!({
        "provider": "claude",
        "status": "drifted",
        "checked_at_unix": 1_784_000_000,
        "detail": "1 model has no pricing entry.",
        "files_seen": 12,
        "records_parsed": 8414,
        "unpriced_models": [
            { "model": "claude-fable-5", "records": 8414,
              "tokens": { "input_tokens": 1, "output_tokens": 2,
                          "cache_creation_tokens": 3, "cache_read_tokens": 4,
                          "reasoning_tokens": 0 } }
        ]
    }))
    .unwrap();
    assert_eq!(full.unpriced_models[0].model, "claude-fable-5");
    assert_eq!(full.unpriced_models[0].tokens.grand_total(), 10);
}

/// `ScopeFlag::match_count` is additive (since 1.17.0): a pre-1.17.0 payload has
/// no such key and must still decode. It defaults to 0, which means "unknown" —
/// clients fall back to `files.len()` and must never show 0 as a real count.
#[test]
fn scope_flag_match_count_is_additive_and_defaults_to_unknown() {
    let old: ScopeFlag = serde_json::from_value(json!({
        "kind": "security",
        "severity": "high",
        "label": "Security / auth code",
        "files": ["auth/login.ts"]
    }))
    .expect("a pre-1.17.0 ScopeFlag must still decode");
    assert_eq!(old.match_count, 0, "absent ⇒ unknown, not a real count");

    let new: ScopeFlag = serde_json::from_value(json!({
        "kind": "security",
        "severity": "high",
        "label": "Security / auth code",
        "files": ["auth/login.ts"],
        "match_count": 40
    }))
    .unwrap();
    assert_eq!(new.match_count, 40);
    // The whole point: the count is NOT the length of the sampled list.
    assert_ne!(new.match_count, new.files.len());
}

/// Additive fields must be optional. Each payload below is the *minimum* an older
/// producer would emit; a newer reader must still accept it.
#[test]
fn additive_fields_are_optional() {
    // Mission without any of the fields added in 1.10.0 / 1.12.0.
    let m: Mission = serde_json::from_value(json!({
        "provider": "claude",
        "session_id": "s1",
        "status": "active",
        "last_activity_unix": 1,
        "message_count": 0
    }))
    .expect("Mission must parse without changed_files / scope_flags / preview");
    assert!(m.changed_files.is_empty());
    assert!(m.scope_flags.is_empty());
    assert!(m.last_message_preview.is_none());

    // Project without the optional arrays.
    let p: Project = serde_json::from_value(json!({"name": "x", "path": "/x"}))
        .expect("Project must parse with only its required fields");
    assert!(p.markers.is_empty());
    assert!(p.commands.is_empty());

    // Checkpoint / Worktree optionals.
    let w: Worktree = serde_json::from_value(json!({"path": "/x", "is_main": true}))
        .expect("Worktree must parse without branch/head/remove_command");
    assert!(w.branch.is_none());
    assert!(w.remove_command.is_none());

    // ProjectUsage without providers/windows.
    let pu: ProjectUsage =
        serde_json::from_value(json!({"project_path": "/x", "project_name": "x"}))
            .expect("ProjectUsage must parse without providers/windows");
    assert!(pu.windows.is_empty());
}

/// Unknown *keys* must be ignored, not rejected — that's the other half of a
/// newer core talking to an older client.
#[test]
fn unknown_keys_are_ignored() {
    let p: Project = serde_json::from_value(json!({
        "name": "x",
        "path": "/x",
        "a_field_from_the_future": {"nested": true}
    }))
    .expect("an unknown key must not fail the parse");
    assert_eq!(p.name, "x");
}

// ---------------------------------------------------------------------------
// 3. Documentation can't drift from the code
// ---------------------------------------------------------------------------

/// `docs/PROTOCOL.md` is what a downstream implementer reads. If it disagrees with
/// `PROTOCOL_VERSION`, they target the wrong contract — so the doc is part of the
/// contract and this test fails when the two drift.
#[test]
fn protocol_doc_states_the_current_version() {
    let doc = include_str!("../../../docs/PROTOCOL.md");
    let v = PROTOCOL_VERSION;
    let expected = format!(
        "**Current version:** `PROTOCOL_VERSION = {}.{}.{}`",
        v.major, v.minor, v.patch
    );
    assert!(
        doc.contains(&expected),
        "docs/PROTOCOL.md doesn't state the current version.\n\
         Expected to find: {expected}\n\
         Bump the doc's \"Current version\" line (and add a history entry) whenever \
         PROTOCOL_VERSION changes."
    );
}

/// Every op the code accepts should be findable in the doc, so an implementer
/// reading `PROTOCOL.md` isn't missing an op that exists. (Checks the op strings
/// appear somewhere in the document.)
#[test]
fn protocol_doc_mentions_every_op() {
    let doc = include_str!("../../../docs/PROTOCOL.md");
    for op in [
        "ping",
        "get_provider_status",
        "get_usage_snapshot",
        "get_projects",
        "record_history",
        "get_history",
        "get_stack_health",
        "get_services",
        "get_radar",
        "get_project_usage",
        "create_checkpoint",
        "list_checkpoints",
        "list_worktrees",
        "create_worktree",
    ] {
        assert!(
            doc.contains(op),
            "docs/PROTOCOL.md never mentions the `{op}` op — a downstream \
             implementer would not know it exists."
        );
    }
}

// ---------------------------------------------------------------------------
// 4. Encoding conventions
// ---------------------------------------------------------------------------

/// Enums are `snake_case` on the wire (documented rule). Spot-check the ones a
/// client switches on.
#[test]
fn enums_are_snake_case_on_the_wire() {
    assert_eq!(
        serde_json::to_value(ProviderId::Claude).unwrap(),
        json!("claude")
    );
    assert_eq!(
        serde_json::to_value(AlertKind::UsageThreshold).unwrap(),
        json!("usage_threshold")
    );
    assert_eq!(
        serde_json::to_value(RadarCategory::AiContext).unwrap(),
        json!("ai_context")
    );
    assert_eq!(
        serde_json::to_value(ScopeFlagKind::BuildConfig).unwrap(),
        json!("build_config")
    );
    assert_eq!(
        serde_json::to_value(DependencyStatus::MajorBehind).unwrap(),
        json!("major_behind")
    );
    assert_eq!(
        serde_json::to_value(CommandSafety::ReadOnly).unwrap(),
        json!("read_only")
    );
}

/// A `Version` must stay a plain `{major,minor,patch}` object — clients compare
/// these numerically to decide compatibility.
#[test]
fn version_shape_is_stable() {
    let v = serde_json::to_value(PROTOCOL_VERSION).unwrap();
    assert!(v["major"].is_number() && v["minor"].is_number() && v["patch"].is_number());
    assert_eq!(
        v["major"], 1,
        "a major bump is a breaking change — intended?"
    );
}
