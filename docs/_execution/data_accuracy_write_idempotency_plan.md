# Data Accuracy Write Idempotency Plan

Status: in progress
Branch: `codex/data-accuracy-write-idempotency`
Base: stacked on `codex/provenance-idempotency-gaps`
Date: 2026-05-19

## Plain English Summary

- Manual covers already has safe retry behavior.
- The broader Data Accuracy settings write routes still need the same behavior.
- This pass makes all three Data Accuracy writes behave the same way:
  - whole settings PATCH
  - service-period settings PATCH
  - manual covers PATCH
- A repeated request with the same key and same body returns the first response.
- A repeated key with a different body returns a conflict.
- A missing key is rejected before any gateway write.

## Scope

- `tool/advisor_proxy/advisor_proxy.dart`
- `test/proxy/mobile_operational_sync_routes_test.dart`
- this execution plan

## Out Of Scope

- No schema change.
- No UI change.
- No live cloud, Firebase, billing, provider, or database mutation.
- No tracker or migration queue update.
- No broad proxy refactor.

## Orchestrator Role

- Own the plan, code edit, tests, audit, commit, push, and PR.
- Keep the shared checkout on `master`.
- Keep implementation inside this Codex worktree.
- Serialize this patch because the main edit is the hot proxy file.
- Use parallel agents only for later read-only audit lanes where they will not collide with this patch.

## Fix Plan

1. Keep existing route order:
   - gateway configured check
   - token verification
   - owner or admin role check
   - operator and location scope check
   - JSON body parsing
   - route-specific body validation
2. After body validation, require `Idempotency-Key` for every Data Accuracy write route.
3. Reject a missing key with `400 idempotency_key_missing`.
4. Reject a key longer than 200 characters with `400 idempotency_key_too_long`.
5. Send all three write types through `_runAdminIdempotent`.
6. Use distinct request types so one key cannot cross-replay a different write:
   - `operator.data_accuracy.settings.patch`
   - `operator.data_accuracy.service_period.patch`
   - `operator.data_accuracy.manual_covers.patch`
7. Preserve the existing gateway calls and response shapes.
8. Add focused route tests:
   - whole settings PATCH rejects a missing key before gateway write
   - service-period settings PATCH rejects a missing key before gateway write
   - whole settings PATCH replays the same key and body without a second gateway write
   - service-period settings PATCH replays the same key and body without a second gateway write
   - whole settings PATCH rejects the same key with a different body
   - service-period settings PATCH rejects the same key with a different body
9. Update existing happy-path tests to send a key.

## Verification Plan

- `flutter test test/proxy/mobile_operational_sync_routes_test.dart`
- `dart analyze --fatal-infos tool/advisor_proxy/advisor_proxy.dart test/proxy/mobile_operational_sync_routes_test.dart`
- `dart run tool/advisor_proxy_size_lint.dart`
- `dart run tool/ux_em_dash_lint.dart`
- `git diff --check`

## Risk Controls

- Body validation stays before idempotency enforcement so bad payloads still return the most useful body error.
- Gateway writes stay behind the idempotency wrapper, not inside separate branch logic.
- The request type is specific per resource, so one route cannot accidentally replay another route's response.
- No client response keys change.

## Execution Result

- Whole Data Accuracy settings PATCH now requires `Idempotency-Key`.
- Service-period Data Accuracy settings PATCH now requires `Idempotency-Key`.
- Manual covers PATCH keeps its existing idempotency behavior.
- All three write routes now go through `_runAdminIdempotent`.
- Same key plus same body replays the cached response.
- Same key plus a different body returns `409 idempotency_key_conflict`.
- Missing keys return `400 idempotency_key_missing` before any gateway write.
- Existing auth, role, location-scope, and body-validation order is preserved.

## Verification Run

- `flutter test test/proxy/mobile_operational_sync_routes_test.dart`
- `dart analyze --fatal-infos tool/advisor_proxy/advisor_proxy.dart test/proxy/mobile_operational_sync_routes_test.dart`
- `dart run tool/advisor_proxy_size_lint.dart`
- `dart run tool/ux_em_dash_lint.dart`
- `git diff --check`
