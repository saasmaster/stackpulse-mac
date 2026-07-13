//! Minimal date math with no external crates (avoids pulling in `chrono` so the
//! core stays tiny and portable).
//!
//! All bucketing is done in **UTC** in this version. The snapshot discloses the
//! bucket date so the UI can label windows as UTC-based; a future version can
//! apply the host's local offset.

use std::time::{SystemTime, UNIX_EPOCH};

/// A civil calendar date (proleptic Gregorian).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct CivilDate {
    pub year: i64,
    pub month: u32,
    pub day: u32,
}

impl CivilDate {
    /// Format as `YYYY-MM-DD`.
    pub fn iso(&self) -> String {
        format!("{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }
}

/// Days from the Unix epoch (1970-01-01) to `y-m-d`.
///
/// Howard Hinnant's `days_from_civil` algorithm. Correct for all dates.
pub fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400; // [0, 399]
    let m = i64::from(m);
    let d = i64::from(d);
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1; // [0, 365]
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
    era * 146097 + doe - 719468
}

/// Inverse of [`days_from_civil`]: civil date from days since the Unix epoch.
pub fn civil_from_days(z: i64) -> CivilDate {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32; // [1, 12]
    CivilDate {
        year: if m <= 2 { y + 1 } else { y },
        month: m,
        day: d,
    }
}

/// Current wall-clock time in Unix seconds. The single point where the core
/// reads the clock; everything else is pure given this value (testable).
pub fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// UTC civil date for a Unix-seconds instant.
pub fn utc_date(unix_seconds: i64) -> CivilDate {
    civil_from_days(unix_seconds.div_euclid(86_400))
}

/// Parse the `YYYY-MM-DD` prefix of an ISO-8601 timestamp into a [`CivilDate`].
/// Returns `None` if the prefix is malformed. We only need day granularity for
/// bucketing, so the time-of-day and offset are ignored (treated as UTC date).
pub fn parse_iso_date(ts: &str) -> Option<CivilDate> {
    let b = ts.as_bytes();
    if b.len() < 10 || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    let year: i64 = ts.get(0..4)?.parse().ok()?;
    let month: u32 = ts.get(5..7)?.parse().ok()?;
    let day: u32 = ts.get(8..10)?.parse().ok()?;
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    Some(CivilDate { year, month, day })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn epoch_roundtrips() {
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(
            civil_from_days(0),
            CivilDate {
                year: 1970,
                month: 1,
                day: 1
            }
        );
    }

    #[test]
    fn known_date_roundtrips() {
        let d = days_from_civil(2026, 7, 12);
        let back = civil_from_days(d);
        assert_eq!(
            back,
            CivilDate {
                year: 2026,
                month: 7,
                day: 12
            }
        );
    }

    #[test]
    fn parses_claude_timestamp() {
        let d = parse_iso_date("2026-07-12T18:03:59.123Z").unwrap();
        assert_eq!(
            d,
            CivilDate {
                year: 2026,
                month: 7,
                day: 12
            }
        );
    }

    #[test]
    fn rejects_garbage() {
        assert!(parse_iso_date("not-a-date").is_none());
        assert!(parse_iso_date("2026/07/12").is_none());
        assert!(parse_iso_date("2026-13-40T00:00:00Z").is_none());
    }

    #[test]
    fn utc_date_matches_known_instant() {
        // 2026-07-12T00:00:00Z
        let secs = days_from_civil(2026, 7, 12) * 86_400;
        assert_eq!(
            utc_date(secs),
            CivilDate {
                year: 2026,
                month: 7,
                day: 12
            }
        );
    }
}
