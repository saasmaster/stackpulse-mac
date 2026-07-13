/*
 * stackpulse_core.h — C ABI for the StackPulse portable Rust core.
 *
 * This header MUST stay in sync with crates/stackpulse-ffi/src/lib.rs.
 * The surface is JSON-in / JSON-out plus a free function.
 *
 * Memory contract: every char* returned by these functions is heap-allocated
 * by Rust and must be released exactly once via sp_core_string_free(). Never
 * free it with C free(); never free twice.
 */
#ifndef STACKPULSE_CORE_H
#define STACKPULSE_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Returns the core version string (e.g. "0.1.0"). Caller frees. */
char *sp_core_version(void);

/*
 * Handles a JSON-encoded CoreRequest and returns a JSON-encoded CoreResponse.
 * A null or non-UTF-8 input yields a JSON error object rather than crashing.
 * Caller frees the result.
 */
char *sp_core_handle_request(const char *request_json);

/* Frees a string previously returned by this library. Null is a no-op. */
void sp_core_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* STACKPULSE_CORE_H */
