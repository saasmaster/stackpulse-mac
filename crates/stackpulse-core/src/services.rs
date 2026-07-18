//! Services & runtime — detect locally-running dev servers by listening TCP port.
//!
//! Enumerates processes listening on localhost TCP ports (via `lsof`), resolves
//! each process's working directory, and matches it to the user's approved
//! project roots. Read-only: the app offers open-URL and a *confirmed* stop, but
//! the core never controls processes.

use std::collections::{HashMap, HashSet};
use std::process::Command;

use stackpulse_protocol::RunningService;

/// Hard cap on how many services we report, to keep payloads sane.
const MAX_SERVICES: usize = 200;

/// Detect running dev servers/services, matched to the approved roots when given.
///
/// Runs `lsof` to enumerate listening TCP sockets, resolves each process's
/// working directory, matches it to `roots`, and infers a kind + URL. Never
/// panics: if `lsof` is missing or errors, returns an empty vector.
pub fn detect(roots: &[String]) -> Vec<RunningService> {
    // 1. Enumerate listening TCP sockets.
    // `+c 0` disables the COMMAND-column truncation macOS `lsof` applies by
    // default (9 chars). Without it `ControlCenter`→`ControlCe`, `mDNSResponder`
    // →`mDNSRespo`, `com.docker.backend`→`com.docke`, so the system-daemon noise
    // filter's longer needles never matched (leaking daemons into the dev-server
    // view) and Docker got no kind/URL. Full names make both correct.
    let stdout = match Command::new("lsof")
        .args(["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN"])
        .output()
    {
        Ok(out) => String::from_utf8_lossy(&out.stdout).into_owned(),
        Err(_) => return Vec::new(),
    };

    let listens = parse_lsof_listen(&stdout);

    // 2/3. Dedup by (pid, port); resolve cwd once per pid (cached).
    let mut seen: HashSet<(i32, u16)> = HashSet::new();
    let mut cwd_cache: HashMap<i32, Option<String>> = HashMap::new();
    let mut services: Vec<RunningService> = Vec::new();

    for (pid, command, port) in listens {
        if !seen.insert((pid, port)) {
            continue;
        }
        // Skip macOS system daemons — this is a dev-server view, not a port scan.
        if is_system_noise(&command) {
            continue;
        }

        let cwd = cwd_cache
            .entry(pid)
            .or_insert_with(|| resolve_cwd(pid))
            .clone();

        let (project_path, project_name) = match_project(cwd.as_deref(), roots);
        let kind = infer_kind(&command);
        let url = service_url(kind.as_deref(), port);

        services.push(RunningService {
            pid,
            port,
            command,
            cwd,
            project_path,
            project_name,
            kind,
            url,
        });

        if services.len() >= MAX_SERVICES {
            break;
        }
    }

    // 5. Sort by port ascending (stable; ties keep discovery order).
    services.sort_by_key(|s| s.port);
    services
}

/// Resolve a process's current working directory via `lsof -a -p <pid> -d cwd -Fn`.
fn resolve_cwd(pid: i32) -> Option<String> {
    let out = Command::new("lsof")
        .args(["-a", "-p", &pid.to_string(), "-d", "cwd", "-Fn"])
        .output()
        .ok()?;
    parse_cwd_output(&String::from_utf8_lossy(&out.stdout))
}

/// Parse `lsof -Fn` output, returning the first `n<path>` name field.
fn parse_cwd_output(text: &str) -> Option<String> {
    text.lines()
        .find_map(|l| l.strip_prefix('n'))
        .map(str::to_string)
        .filter(|p| !p.is_empty())
}

/// Decode lsof's `\xNN` hex escapes (spaces, control chars) back to their
/// characters. Anything that isn't a well-formed `\xNN` escape is passed through
/// verbatim, so a literal backslash in a name is never mangled.
fn unescape_lsof(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < bytes.len() {
        // `.get()` is bounds-safe, so a trailing `\x` or `\xN` just falls through.
        if bytes[i] == b'\\' && bytes.get(i + 1) == Some(&b'x') {
            if let (Some(h), Some(l)) = (
                bytes.get(i + 2).and_then(|b| (*b as char).to_digit(16)),
                bytes.get(i + 3).and_then(|b| (*b as char).to_digit(16)),
            ) {
                out.push(char::from((h * 16 + l) as u8));
                i += 4;
                continue;
            }
        }
        out.push(bytes[i] as char);
        i += 1;
    }
    out
}

/// Parse the default `lsof -iTCP -sTCP:LISTEN` table into `(pid, command, port)`.
///
/// Each LISTEN row looks like:
/// `node    12345 jorge   23u  IPv4 0x…  0t0  TCP 127.0.0.1:5173 (LISTEN)`
/// The COMMAND column may contain spaces, so PID is located as the first
/// numeric field and the command is everything before it. The listen address
/// is the field immediately before `(LISTEN)`; the port is its `:`-suffix.
/// Only loopback / wildcard / localhost addresses are kept.
fn parse_lsof_listen(text: &str) -> Vec<(i32, String, u16)> {
    let mut out = Vec::new();

    for line in text.lines() {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 3 {
            continue;
        }
        // Header row starts with "COMMAND".
        if fields[0] == "COMMAND" {
            continue;
        }
        // Must be a listening socket.
        let listen_idx = match fields.iter().position(|f| *f == "(LISTEN)") {
            Some(i) if i >= 1 => i,
            _ => continue,
        };

        // PID: first numeric field at or after index 1.
        let Some(pid_idx) = (1..fields.len()).find(|&i| fields[i].parse::<i32>().is_ok()) else {
            continue;
        };
        if pid_idx == 0 {
            continue;
        }
        let Ok(pid) = fields[pid_idx].parse::<i32>() else {
            continue;
        };
        // With `+c 0`, lsof escapes spaces and other non-printables in the COMMAND
        // field as `\xNN` (so a name with spaces stays a single whitespace-split
        // field). Decode them back, or the UI shows `GitHub\x20Desktop\x20Helper`.
        let command = unescape_lsof(&fields[..pid_idx].join(" "));
        if command.is_empty() {
            continue;
        }

        // Listen address is the field just before "(LISTEN)".
        let addr = fields[listen_idx - 1];
        let Some(port) = parse_local_port(addr) else {
            continue;
        };

        out.push((pid, command, port));
    }

    out
}

/// Extract the port from a listen address if it is loopback / wildcard / local.
///
/// Accepts `*:5173`, `127.0.0.1:5173`, `localhost:5173`, `[::1]:5173`,
/// `::1:5173`, `[::]:5173`, `0.0.0.0:5173`, and any `127.x.y.z:port`.
/// Rejects specific LAN/public addresses (e.g. `192.168.0.5:5173`).
fn parse_local_port(addr: &str) -> Option<u16> {
    let (host, port_str) = addr.rsplit_once(':')?;
    let port: u16 = port_str.parse().ok()?;

    let host_ok = host.is_empty()
        || host == "*"
        || host == "localhost"
        || host == "0.0.0.0"
        || host == "::1"
        || host == "[::1]"
        || host == "[::]"
        || host == "::"
        || host.starts_with("127.");

    if host_ok {
        Some(port)
    } else {
        None
    }
}

/// True for well-known macOS system daemons that listen on ports but aren't dev
/// servers — filtered so the Services view stays focused on the user's work.
fn is_system_noise(command: &str) -> bool {
    let c = command.to_ascii_lowercase();
    const SYSTEM: &[&str] = &[
        "controlce", // ControlCenter (AirPlay receiver on 5000/7000)
        "rapportd",  // Continuity / Handoff
        "sharingd",
        "remoted",
        "airplay",
        "mdnsresponder",
        "launchd",
        "rpcbind",
        "cupsd",
        "identityservi", // identityservicesd
        "apsd",          // Apple Push
        "netbiosd",
        "trustd",
        "nsurlsessiond",
        "coreauthd",
        "sshd",
        "ssh-agent",
    ];
    SYSTEM.iter().any(|s| c.contains(s))
}

/// Best-effort service kind from a command name.
fn infer_kind(command: &str) -> Option<String> {
    let c = command.to_ascii_lowercase();
    // Order matters: more-specific dev servers before the generic "node".
    let kind = if c.contains("vite") {
        "vite"
    } else if c.contains("next-server") || c.contains("next") {
        "next"
    } else if c.contains("webpack") {
        "webpack"
    } else if c.contains("node") {
        "node"
    } else if c.contains("python") {
        "python"
    } else if c.contains("rails") || c.contains("ruby") {
        "ruby"
    } else if c.contains("php") {
        "php"
    } else if c.contains("docker") {
        // covers "docker", "com.docker.backend", etc.
        "docker"
    } else if c.contains("postgres") {
        "postgres"
    } else if c.contains("mysql") {
        "mysql"
    } else if c.contains("redis") {
        "redis"
    } else {
        return None;
    };
    Some(kind.to_string())
}

/// A localhost URL for HTTP-ish dev servers; `None` for databases.
fn service_url(kind: Option<&str>, port: u16) -> Option<String> {
    match kind {
        // Databases: no browsable URL.
        Some("postgres") | Some("mysql") | Some("redis") | Some("docker") => None,
        // Known HTTP dev servers.
        Some("vite") | Some("next") | Some("node") | Some("webpack") | Some("python")
        | Some("ruby") | Some("php") => Some(format!("http://localhost:{port}")),
        // Unknown kind: only if it's on a typical dev port.
        None if is_dev_port(port) => Some(format!("http://localhost:{port}")),
        _ => None,
    }
}

/// Whether a port is a common local dev-server port.
fn is_dev_port(port: u16) -> bool {
    matches!(
        port,
        3000..=3010 | 4000 | 4200 | 5000 | 5173 | 5174 | 8000 | 8080 | 8081 | 8888 | 9000
    )
}

/// Match a working directory to the deepest (longest-prefix) approved root.
///
/// Returns `(project_path, project_name)` where `project_path` is the matched
/// root and `project_name` its last path component. When `cwd` is `None`, empty,
/// or matches no root, both are `None`.
fn match_project(cwd: Option<&str>, roots: &[String]) -> (Option<String>, Option<String>) {
    let cwd = match cwd {
        Some(c) if !c.is_empty() => c,
        _ => return (None, None),
    };

    let mut best: Option<&str> = None;
    for root in roots {
        let root = root.trim_end_matches('/');
        if root.is_empty() {
            continue;
        }
        let under = cwd == root || cwd.starts_with(&format!("{root}/"));
        if under && best.map_or(true, |b| root.len() > b.len()) {
            best = Some(root);
        }
    }

    match best {
        Some(path) => {
            let name = path.rsplit('/').next().filter(|s| !s.is_empty());
            (Some(path.to_string()), name.map(str::to_string))
        }
        None => (None, None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_pid_command_port_ipv4() {
        let text = "\
COMMAND   PID  USER   FD   TYPE  DEVICE SIZE/OFF NODE NAME
node    12345 jorge   23u  IPv4 0x1234      0t0  TCP 127.0.0.1:5173 (LISTEN)
";
        let got = parse_lsof_listen(text);
        assert_eq!(got, vec![(12345, "node".to_string(), 5173)]);
    }

    #[test]
    fn parses_ipv6_wildcard_and_localhost_forms() {
        let text = "\
node    100 jorge   1u  IPv6 0x1  0t0  TCP [::1]:3000 (LISTEN)
Python  200 jorge   2u  IPv4 0x2  0t0  TCP *:8000 (LISTEN)
ruby    300 jorge   3u  IPv4 0x3  0t0  TCP localhost:4000 (LISTEN)
";
        let got = parse_lsof_listen(text);
        assert_eq!(
            got,
            vec![
                (100, "node".to_string(), 3000),
                (200, "Python".to_string(), 8000),
                (300, "ruby".to_string(), 4000),
            ]
        );
    }

    #[test]
    fn skips_non_local_and_non_listen_lines() {
        let text = "\
node    100 jorge   1u  IPv4 0x1  0t0  TCP 192.168.0.5:5173 (LISTEN)
node    101 jorge   2u  IPv4 0x2  0t0  TCP 127.0.0.1:9999->1.2.3.4:80 (ESTABLISHED)
node    102 jorge   3u  IPv4 0x3  0t0  TCP 127.0.0.1:6000 (LISTEN)
";
        let got = parse_lsof_listen(text);
        // Only the loopback LISTEN row survives.
        assert_eq!(got, vec![(102, "node".to_string(), 6000)]);
    }

    #[test]
    fn handles_command_names_with_spaces() {
        let text = "com.docker.backend 555 jorge 1u IPv4 0x1 0t0 TCP 127.0.0.1:5432 (LISTEN)\n";
        let got = parse_lsof_listen(text);
        assert_eq!(got, vec![(555, "com.docker.backend".to_string(), 5432)]);
    }

    #[test]
    fn infers_kinds() {
        assert_eq!(infer_kind("vite").as_deref(), Some("vite"));
        assert_eq!(infer_kind("next-server").as_deref(), Some("next"));
        assert_eq!(infer_kind("node").as_deref(), Some("node"));
        assert_eq!(infer_kind("Python").as_deref(), Some("python"));
        assert_eq!(infer_kind("ruby").as_deref(), Some("ruby"));
        assert_eq!(infer_kind("php").as_deref(), Some("php"));
        assert_eq!(infer_kind("com.docker.backend").as_deref(), Some("docker"));
        assert_eq!(infer_kind("postgres").as_deref(), Some("postgres"));
        assert_eq!(infer_kind("mysqld").as_deref(), Some("mysql"));
        assert_eq!(infer_kind("redis-server").as_deref(), Some("redis"));
        assert_eq!(infer_kind("some-random-daemon"), None);
    }

    #[test]
    fn url_for_http_but_not_databases() {
        assert_eq!(
            service_url(Some("vite"), 5173).as_deref(),
            Some("http://localhost:5173")
        );
        assert_eq!(
            service_url(Some("node"), 3000).as_deref(),
            Some("http://localhost:3000")
        );
        // Databases: no URL.
        assert_eq!(service_url(Some("postgres"), 5432), None);
        assert_eq!(service_url(Some("mysql"), 3306), None);
        assert_eq!(service_url(Some("redis"), 6379), None);
        // Unknown kind on a dev port → URL; on an odd port → none.
        assert_eq!(
            service_url(None, 8080).as_deref(),
            Some("http://localhost:8080")
        );
        assert_eq!(service_url(None, 6379), None);
    }

    #[test]
    fn matches_deepest_project_root() {
        let roots = vec![
            "/Users/jorge/projects".to_string(),
            "/Users/jorge/projects/myapp".to_string(),
        ];
        // Nested cwd inside the deeper root → deeper root wins.
        let (path, name) = match_project(Some("/Users/jorge/projects/myapp/src/lib"), &roots);
        assert_eq!(path.as_deref(), Some("/Users/jorge/projects/myapp"));
        assert_eq!(name.as_deref(), Some("myapp"));

        // Exact match on a root.
        let (path, name) = match_project(Some("/Users/jorge/projects"), &roots);
        assert_eq!(path.as_deref(), Some("/Users/jorge/projects"));
        assert_eq!(name.as_deref(), Some("projects"));
    }

    #[test]
    fn no_match_when_outside_or_empty() {
        let roots = vec!["/Users/jorge/projects".to_string()];
        assert_eq!(match_project(Some("/tmp/other"), &roots), (None, None));
        assert_eq!(match_project(None, &roots), (None, None));
        assert_eq!(match_project(Some("/anything"), &[]), (None, None));
        // A sibling that shares a prefix but isn't under the root must not match.
        assert_eq!(
            match_project(Some("/Users/jorge/projects-old/x"), &roots),
            (None, None)
        );
    }

    #[test]
    fn parses_cwd_field() {
        let text = "p12345\nfcwd\nn/Users/jorge/projects/myapp\n";
        assert_eq!(
            parse_cwd_output(text).as_deref(),
            Some("/Users/jorge/projects/myapp")
        );
        assert_eq!(parse_cwd_output("p1\nfcwd\n"), None);
    }

    #[test]
    fn unescapes_lsof_hex_escapes() {
        // `+c 0` emits spaces as `\x20`; decode them so the UI shows real names.
        assert_eq!(
            unescape_lsof("GitHub\\x20Desktop\\x20Helper"),
            "GitHub Desktop Helper"
        );
        // A well-formed name is passed through unchanged.
        assert_eq!(unescape_lsof("com.docker.backend"), "com.docker.backend");
        // A stray/backslash that isn't a valid `\xNN` escape is left verbatim.
        assert_eq!(unescape_lsof("a\\xZZb"), "a\\xZZb");
        assert_eq!(unescape_lsof("trailing\\x"), "trailing\\x");
    }

    #[test]
    fn system_daemon_full_names_are_filtered() {
        // The bug: default lsof truncates COMMAND to 9 chars, so these 13-char
        // needles never matched. With `+c 0` the full name arrives and the filter
        // works — pin that so a truncation regression is caught.
        assert!(is_system_noise("mDNSResponder"));
        assert!(is_system_noise("identityservicesd"));
        assert!(is_system_noise("nsurlsessiond"));
        // A real dev server is NOT noise.
        assert!(!is_system_noise("node"));
        assert!(!is_system_noise("com.docker.backend"));
    }
}
