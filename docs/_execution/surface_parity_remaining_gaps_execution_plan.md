# Surface Parity Remaining Gaps Execution Plan

Status: closed/superseded after PR #1020-era cleanup. Preserve this file as
historical execution context; do not dispatch new lanes from it.
Created: 2026-05-19
Owner: executor-agnostic orchestrator
Worktree: `.codex_worktrees/per-daypart-server-parity`
Branch: `codex/surface-parity-remaining-gaps`

## Plain English Summary

- The prior surface-parity slice is already on `origin/master`.
- This slice continued in a worktree; the main checkout stayed on `master`.
- Three gaps remained at dispatch time:
  - Mobile covers edits must become real server truth.
  - Operator Web should use configured service periods, not free-text keys.
  - Data Accuracy provenance needs schema/API support before UI can show honest inheritance labels.
- The mobile decision is now locked: editable mobile covers means canonical proxy write, not local-only state.
- Provenance must not be guessed in Flutter. The server must expose the winning scope per setting key first.
- During execution, the audit found one extra blocker: multi-location mobile covers must route to the active restaurant/location, not the session's default location.
- It also found one non-blocking hardening follow-up: the manual covers PATCH sends an `Idempotency-Key`, but the proxy route does not yet ledger/replay that key.

## Gap 1 - Mobile Covers Setup Is Local-Only

Problem:

- Mobile Settings lets a manager enter covers for a business date and service period.
- Today that write lands in local SQLite only.
- Server-side closed-shift aggregation reads canonical `data_accuracy_settings.covers_manual_entries`.
- That means the phone can look like it saved truth while the server may never use it.

Decision:

- Keep mobile editable.
- Add a canonical proxy write path.
- The write must merge one `(business_date, service_period_key)` cover entry into server truth without overwriting wage source, walk-in settings, or service-period source settings.
- Mobile may still mirror the entry locally after the server write so the recent-entry list stays fast and offline-readable.

Execution:

- Add a narrow proxy route for manual covers merge.
- Add a mobile write-client method on the existing HTTP proxy client.
- Wire Settings Covers Setup to use the server writer when an authenticated proxy client exists.
- Fail closed for authenticated production sessions when the proxy write client is unavailable.
- Keep demo/widget-test local fallback only for non-auth/test paths.
- Add tests for route authorization, no-clobber merge shape, HTTP client body, and Settings writer behavior.
- Verify multi-location safety by testing that the active restaurant id becomes the route location id.

## Gap 2 - Operator Web Service-Period Override Uses Free-Text Keys

Problem:

- Operator Web already loads the configured service-period definitions.
- The override dialog still asks the user to type a raw key such as `breakfast`.
- That invites typos and lets UI drift from the restaurant's timing config.

Execution:

- Pass configured service periods into the keyed override card.
- For new overrides, use a dropdown of configured service periods.
- For existing rows with old/unknown keys, keep the row editable without losing the unknown key.
- Keep raw-key validation as a fallback guard only.
- Add widget tests proving new saves use the configured dropdown.

## Gap 3 - Effective Data Accuracy Values Lack Inheritance Provenance

Problem:

- `effective_data_accuracy_settings_v` resolves the final value map.
- It does not expose which scope won per service-period key.
- Admin and Operator Web cannot honestly show "set here" or "inherited from business/org/location" before mutation.

Execution:

- Defer UI labels until the server emits provenance.
- Add a follow-up schema/API lane:
  - Add an additive view migration with `covers_source_per_service_period_source`.
  - Preserve the existing value map unchanged.
  - Extend proxy/domain/admin/operator-web DTOs with null-safe provenance.
  - Render source chips only after the wire shape exists.

## Execution Lanes

### Lane A - Mobile Manual Covers Canonical Write

Owns:

- `tool/advisor_proxy/advisor_proxy.dart`
- `tool/advisor_proxy/proxy_bootstrap.dart`
- `lib/services/sync/sync_proxy_client.dart`
- `lib/services/sync/http_sync_proxy_client.dart`
- `lib/services/manual_covers_write_service.dart`
- `lib/screens/settings_screen.dart`
- mobile/proxy tests

Tasks:

- Add a merge-safe manual covers route.
- Add the mobile write client and Settings writer.
- Preserve local mirror after successful server write.
- Fail closed when signed-in production has no canonical writer.

### Lane B - Operator Web Configured Service-Period Picker

Owns:

- `lib/operator_web/widgets/keyed_service_period_accuracy_card.dart`
- `lib/operator_web/screens/data_accuracy_screen.dart`
- `test/operator_web/screens/data_accuracy_screen_test.dart`

Tasks:

- Replace Add dialog free-text key entry with configured-period dropdown.
- Preserve edit behavior for existing keys.
- Add coverage for a configured `brunch` period.

### Lane C - Provenance Follow-Up

Owns:

- Future migration/proxy/domain/UI slice.

Tasks:

- Do not fake labels in this slice.
- Document the exact schema/API requirement.
- Run migration drift/cutoff lint when that follow-up touches migrations.

## Verification Gates

- `dart analyze --fatal-infos` on touched Dart/proxy files.
- `flutter test test/screens/settings_covers_setup_section_test.dart`
- `flutter test test/services/sync/http_sync_proxy_client_test.dart`
- `flutter test test/proxy/mobile_operational_sync_routes_test.dart`
- `flutter test test/operator_web/screens/data_accuracy_screen_test.dart`
- `dart run tool/postgres_import_lint.dart`
- `dart run tool/permission_key_lint.dart`
- `dart run tool/ux_em_dash_lint.dart`
- `dart run tool/advisor_proxy_size_lint.dart`

## Guardrails

- Main checkout remains on `master`.
- Code edits happen only in the worktree branch.
- No live Firebase, provider, billing, or cloud mutations.
- No migration in this slice unless the provenance lane is explicitly started.

## Execution Result

- Mobile Covers Setup now writes signed-in saves through the canonical proxy before updating the local recent-entry mirror.
- Multi-location safety is fixed: the active restaurant/location id is the proxy route location id.
- The proxy merges one manual cover entry into `covers_manual_entries` without overwriting wage source, walk-in settings, or keyed service-period source settings.
- Operator Web's new keyed override flow uses a configured service-period dropdown for new rows and preserves legacy/unknown keys on existing rows.
- Data Accuracy provenance remains deferred because the server still needs to expose winning-scope metadata before UI labels can be honest.
- Follow-up to track: add a true idempotency ledger/replay for the manual covers PATCH route. The current write is value-idempotent for the same date/key/covers and the client sends `Idempotency-Key`, but the proxy does not yet consume it for replay.

## Verification Run

- `dart analyze --fatal-infos` on touched Dart/proxy/test files.
- `flutter test test/services/manual_covers_write_service_test.dart`
- `flutter test test/services/sync/http_sync_proxy_client_test.dart`
- `flutter test test/screens/settings_covers_setup_section_test.dart`
- `flutter test test/operator_web/screens/data_accuracy_screen_test.dart`
- `flutter test test/proxy/mobile_operational_sync_routes_test.dart`
- `flutter test test/proxy/wage_role_rows_write_routes_test.dart`
- `dart run tool/postgres_import_lint.dart`
- `dart run tool/permission_key_lint.dart`
- `dart run tool/ux_em_dash_lint.dart`
- `dart run tool/advisor_proxy_size_lint.dart`
- `git diff --check`
