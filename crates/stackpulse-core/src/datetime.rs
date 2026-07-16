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

/// Parse an ISO-8601 timestamp into Unix seconds. No `chrono`.
///
/// Lives here because it was copy-pasted into two modules and was about to become
/// three. The duplication was not free: the byte-8 slicing panic that blanked an
/// entire snapshot had to be found and fixed in BOTH copies, and a third would
/// have silently kept it.
///
/// Degrades, never panics: an unparseable tail yields the date at midnight rather
/// than an error, and a malformed string yields `None`.
pub fn parse_iso_unix(ts: &str) -> Option<i64> {
    let date = parse_iso_date(ts)?;
    let mut secs = days_from_civil(date.year, date.month, date.day) * 86_400;

    // Optional "THH:MM:SS[.fff][±HH:MM|Z]" tail (byte index 10 is the 'T').
    let Some(time_part) = ts.get(11..) else {
        return Some(secs);
    };
    let b = time_part.as_bytes();
    if b.len() < 8 || b[2] != b':' || b[5] != b':' {
        return Some(secs); // date-only, or a shape we don't recognize
    }
    let part = |range: std::ops::Range<usize>| -> i64 {
        time_part
            .get(range)
            .and_then(|s| s.parse().ok())
            .unwrap_or(0)
    };
    let (hh, mm, ss) = (part(0..2), part(3..5), part(6..8));
    if hh > 23 || mm > 59 || ss > 60 {
        return Some(secs);
    }
    secs += hh * 3600 + mm * 60 + ss;

    // A trailing numeric offset shifts local → UTC.
    //
    // `.get`, not `[8..]`: the ':' checks above only prove bytes 2 and 5 are
    // ASCII, so a multi-byte char can straddle byte 8 and slicing there panics —
    // which the FFI turns into an error for the entire snapshot.
    let rest = time_part
        .get(8..)
        .unwrap_or("")
        .trim_start_matches(|c: char| c == '.' || c.is_ascii_digit());
    if let Some(pos) = rest.find(['+', '-']) {
        let off = &rest[pos..];
        let sign = if off.starts_with('-') { -1 } else { 1 };
        let digits: String = off.chars().filter(char::is_ascii_digit).collect();
        if digits.len() >= 2 {
            let oh: i64 = digits[0..2].parse().unwrap_or(0);
            let om: i64 = if digits.len() >= 4 {
                digits[2..4].parse().unwrap_or(0)
            } else {
                0
            };
            secs -= sign * (oh * 3600 + om * 60);
        }
    }
    Some(secs)
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
