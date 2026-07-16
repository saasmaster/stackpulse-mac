//! Decoding the paths git prints.
//!
//! Git does not hand back raw filenames. Depending on the command and on
//! `core.quotePath`, a path may arrive bare, wrapped in double quotes, and with
//! its bytes C-escaped. Every caller that reads a path out of git stdout needs
//! the same decoding, and each one that reimplemented it got a different subset
//! wrong — so it lives here once, pinned by tests built from real git output.
//!
//! ## What git actually emits (captured from git 2.x, macOS)
//!
//! `git status --porcelain` quotes any path containing a space:
//! ```text
//!  M "a -> b.txt"                  ← a FILE named `a -> b.txt`, not a rename
//! RM plain.txt -> "new spaced.txt" ← a rename, bare source, quoted destination
//!  M "uni-caf\303\251.txt"         ← literal backslashes: `é` as octal BYTES
//! ```
//!
//! `git stash show --name-only` does **not** quote spaces, but still quotes and
//! escapes genuinely special characters:
//! ```text
//! a -> b.txt        ← bare, despite the spaces
//! "quo\"te.txt"     ← quoted and escaped
//! ```
//!
//! Two consequences drive the code below:
//! - Quotes must be read **before** looking for a ` -> ` rename separator.
//!   Splitting first turns the real file `a -> b.txt` into `b.txt"`, a path that
//!   does not exist.
//! - Octal escapes are **bytes**, not characters. `é` arrives as `\303\251`, so
//!   escapes are collected as bytes and decoded as UTF-8 once at the end.

/// Decode a single git-printed path (no rename separator handling).
///
/// A quoted path is unquoted and unescaped; a bare path is returned trimmed and
/// untouched (with `core.quotePath=false`, non-ASCII arrives as raw UTF-8 and
/// must pass through unharmed).
pub fn decode(field: &str) -> String {
    let field = field.trim();
    match field.strip_prefix('"') {
        Some(rest) => match closing_quote(rest) {
            Some(end) => unescape_c(&rest[..end]),
            None => unescape_c(rest), // unterminated: best effort
        },
        None => field.to_string(),
    }
}

/// Decode the path a `git status --porcelain` line reports, honoring quoting and
/// keeping the **destination** of a `old -> new` rename/copy entry.
///
/// `field` is the line with its `XY ` status prefix already removed.
pub fn decode_porcelain_field(field: &str) -> String {
    let field = field.trim();
    if let Some(rest) = field.strip_prefix('"') {
        // The name ends at the first unescaped quote, so a ` -> ` inside it is
        // just text. A `->` *after* the closing quote is a rename separator.
        let Some(end) = closing_quote(rest) else {
            return unescape_c(rest);
        };
        let after = rest[end + 1..].trim_start();
        return match after.strip_prefix("->") {
            Some(dest) => decode_porcelain_field(dest),
            None => unescape_c(&rest[..end]),
        };
    }
    // `status --porcelain` quotes every path containing a space, so a bare
    // ` -> ` here is always the separator and never part of a filename.
    match field.find(" -> ") {
        Some(idx) => decode_porcelain_field(&field[idx + 4..]),
        None => field.to_string(),
    }
}

/// Byte index of the quote closing a git-quoted path, skipping escaped ones.
/// The result points at a `"`, which is ASCII and so a safe char boundary.
fn closing_quote(s: &str) -> Option<usize> {
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'\\' => i += 2, // the escaped byte cannot close the string
            b'"' => return Some(i),
            _ => i += 1,
        }
    }
    None
}

/// Decode git's C-style escapes: `\n`, `\t`, `\r`, `\"`, `\\`, and octal bytes.
///
/// Bytes are accumulated and decoded as UTF-8 at the end because one character
/// can span several escapes (`é` is `\303\251`); decoding per-escape would yield
/// two replacement characters instead.
fn unescape_c(s: &str) -> String {
    let b = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] != b'\\' {
            out.push(b[i]);
            i += 1;
            continue;
        }
        let Some(&next) = b.get(i + 1) else {
            out.push(b'\\'); // trailing backslash: keep it
            break;
        };
        i += 2;
        match next {
            b'n' => out.push(b'\n'),
            b't' => out.push(b'\t'),
            b'r' => out.push(b'\r'),
            b'0'..=b'7' => {
                let mut val = u32::from(next - b'0');
                for _ in 0..2 {
                    match b.get(i) {
                        Some(&d) if (b'0'..=b'7').contains(&d) => {
                            val = val * 8 + u32::from(d - b'0');
                            i += 1;
                        }
                        _ => break,
                    }
                }
                out.push((val & 0xFF) as u8);
            }
            other => out.push(other), // \" and \\ decode to themselves
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verbatim `git status --porcelain` output for a repo containing a file
    /// literally named `a -> b.txt`, captured from git itself. Splitting on
    /// ` -> ` before reading the quotes reported `b.txt"` — a nonexistent path.
    #[test]
    fn porcelain_keeps_filenames_containing_the_rename_arrow() {
        assert_eq!(decode_porcelain_field("\"a -> b.txt\""), "a -> b.txt");
    }

    #[test]
    fn porcelain_keeps_the_destination_of_a_rename() {
        assert_eq!(decode_porcelain_field("old.ts -> new.ts"), "new.ts");
        assert_eq!(
            decode_porcelain_field("plain.txt -> \"new spaced.txt\""),
            "new spaced.txt"
        );
        assert_eq!(
            decode_porcelain_field("\"spaced name.txt\" -> renamed.txt"),
            "renamed.txt"
        );
        assert_eq!(
            decode_porcelain_field("\"uni-caf\\303\\251.txt\" -> \"uni-renamed-\\303\\251.txt\""),
            "uni-renamed-é.txt"
        );
    }

    /// With the default `core.quotePath`, git escapes non-ASCII as literal octal
    /// bytes: `é` arrives as the six characters `\303\251`. Merely stripping the
    /// quotes surfaced that raw escape to the user as the filename.
    #[test]
    fn decodes_octal_escaped_bytes_as_utf8() {
        assert_eq!(decode("\"uni-caf\\303\\251.txt\""), "uni-café.txt");
        // A 3-byte character spans three escapes and must survive as one char.
        assert_eq!(decode("\"e\\342\\202\\254.txt\""), "e€.txt");
    }

    #[test]
    fn decodes_special_character_escapes() {
        assert_eq!(decode("\"quo\\\"te.txt\""), "quo\"te.txt");
        assert_eq!(decode("\"tab\\there.txt\""), "tab\there.txt");
        assert_eq!(decode("\"back\\\\slash.txt\""), "back\\slash.txt");
        assert_eq!(decode("\"nl\\nhere.txt\""), "nl\nhere.txt");
    }

    /// `core.quotePath=false` emits raw UTF-8 with no quoting, and
    /// `stash show --name-only` leaves spaces bare — both must pass through.
    #[test]
    fn passes_bare_paths_through_untouched() {
        assert_eq!(decode("uni-café.txt"), "uni-café.txt");
        assert_eq!(decode("a -> b.txt"), "a -> b.txt");
        assert_eq!(decode("new spaced.txt"), "new spaced.txt");
    }

    /// Malformed input must degrade, never panic.
    #[test]
    fn degrades_on_malformed_input() {
        assert_eq!(decode("\"unterminated.txt"), "unterminated.txt");
        assert_eq!(decode("\"trailing\\"), "trailing\\");
        assert_eq!(decode(""), "");
        assert_eq!(decode("\""), "");
        // A lone invalid byte escape can't produce valid UTF-8; it must not panic.
        assert!(!decode("\"bad\\377.txt\"").is_empty());
    }
}
