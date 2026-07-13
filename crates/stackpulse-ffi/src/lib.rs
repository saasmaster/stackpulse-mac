//! C ABI bridge over `stackpulse-core`.
//!
//! The surface is deliberately tiny: JSON strings in, JSON strings out, plus a
//! free function. This keeps the ABI stable and the memory contract obvious,
//! and it means the Swift side never needs to mirror Rust structs — it decodes
//! the same [`stackpulse_protocol`] JSON the CLI prints.
//!
//! ## Memory contract
//!
//! Every `*mut c_char` returned by this library is heap-allocated by Rust and
//! **must** be released by passing it back to [`sp_core_string_free`]. Passing a
//! pointer from anywhere else, or freeing twice, is undefined behavior. Input
//! pointers are borrowed for the duration of the call and never freed here.
//!
//! All functions are panic-safe: a panic inside Rust is caught at the boundary
//! and converted into a JSON error string (unwinding across FFI is UB).

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::catch_unwind;

/// Convert a Rust `String` into an owned C string pointer for the caller.
fn to_c_string(s: String) -> *mut c_char {
    // `CString::new` fails only if `s` contains an interior NUL. Our JSON never
    // does, but guard anyway rather than panic.
    match CString::new(s) {
        Ok(c) => c.into_raw(),
        Err(_) => CString::new("{\"kind\":\"error\",\"message\":\"interior nul\"}")
            .unwrap()
            .into_raw(),
    }
}

fn error_json(message: &str) -> *mut c_char {
    to_c_string(format!(
        "{{\"kind\":\"error\",\"code\":\"internal\",\"message\":\"{}\"}}",
        message.replace('"', "'")
    ))
}

/// Return the core crate version (e.g. "0.1.0"). Caller must free.
#[no_mangle]
pub extern "C" fn sp_core_version() -> *mut c_char {
    match catch_unwind(stackpulse_core::version_string) {
        Ok(v) => to_c_string(v),
        Err(_) => error_json("panic in sp_core_version"),
    }
}

/// Handle a JSON `CoreRequest` and return a JSON `CoreResponse`. Caller must
/// free the result. A null input yields a JSON error rather than crashing.
///
/// # Safety
/// `request_json` must be a valid, NUL-terminated C string or null.
#[no_mangle]
pub unsafe extern "C" fn sp_core_handle_request(request_json: *const c_char) -> *mut c_char {
    if request_json.is_null() {
        return error_json("null request pointer");
    }
    let result = catch_unwind(|| {
        // SAFETY: caller guarantees a valid NUL-terminated string per the doc
        // contract; we validate UTF-8 below.
        let c_str = unsafe { CStr::from_ptr(request_json) };
        match c_str.to_str() {
            Ok(req) => stackpulse_core::handle_request_json(req),
            Err(_) => {
                "{\"kind\":\"error\",\"code\":\"bad_request\",\"message\":\"request was not valid UTF-8\"}"
                    .to_string()
            }
        }
    });
    match result {
        Ok(s) => to_c_string(s),
        Err(_) => error_json("panic while handling request"),
    }
}

/// Free a string previously returned by this library.
///
/// # Safety
/// `s` must be null or a pointer returned by one of this library's functions,
/// freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn sp_core_string_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    // SAFETY: reclaims a CString we allocated with `into_raw`.
    drop(unsafe { CString::from_raw(s) });
}
