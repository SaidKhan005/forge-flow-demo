# Star Shift Stable Idempotency Plan

## Scope

- Worker branch: `codex/star-shift-stable-idempotency`
- Code surface: `lib/services/star_target_selection_write_service.dart`
- Test surface: `test/services/star_target_selection_write_service_test.dart`
- Proxy routes stay unchanged because the proxy already replays the same
  `Idempotency-Key`.

## Problem

Star selection and projection writes previously appended a microsecond clock
value to each mobile idempotency key. A retry of the same logical mobile action
could therefore mint a new key, bypass replay, and reach the once-per-cycle
guard as a later duplicate write.

## Plan

1. Build the request body before minting the idempotency key.
2. Canonicalize the action, operator/location/restaurant scope, and body with
   sorted JSON keys.
3. Hash that canonical payload with SHA-256.
4. Keep the existing key prefixes:
   - `mobile-star-select-`
   - `mobile-star-clear-`
   - `mobile-star-project-`
5. Store only the digest suffix in the key so large request bodies and record
   details are not leaked through the header.

## Verification

- Add focused tests proving repeated select, clear, and projection actions
  produce the same idempotency key when the logical body is unchanged.
- Add focused tests proving each key changes when the body changes.
- Run the focused service test, analyzer, UX em dash lint, and diff-check before
  publishing the PR.
