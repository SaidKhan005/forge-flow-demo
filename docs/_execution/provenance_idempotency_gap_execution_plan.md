# Provenance And Idempotency Gap Execution Plan

Status: active
Created: 2026-05-19
Owner: Codex orchestrator
Worktree: `.codex_worktrees/per-daypart-server-parity`
Branch: `codex/provenance-idempotency-gaps`

## Plain English Summary

- This continues the surface-parity work in the Codex worktree.
- The main checkout stays on `master`.
- Two gaps are in scope:
  - Manual covers writes must use the server idempotency ledger, not just a client-sent key.
  - Data Accuracy must expose provenance from the server so UI labels can say where values came from.
- The provenance fix must be full server truth first:
  - migration view output
  - proxy JSON output
  - domain parsing
  - UI labels only where the server actually sends source metadata
- No Flutter screen may guess inheritance labels from local state.
- No tracker edits are part of this slice.

## Gap 1 - Manual Covers Idempotency Is Not Enforced

Problem:

- Mobile now writes manual covers through the canonical proxy.
- The mobile client sends `Idempotency-Key`.
- The proxy route still validates and runs the gateway write directly.
- A retry can replay the write operation instead of replaying the first response.

Execution:

- Pass the admin idempotency store into the mobile data-accuracy write route.
- Require `Idempotency-Key` for the manual-covers PATCH route.
- Reject missing or over-length keys before any gateway write.
- Wrap the manual-covers write in the existing reserve, complete, and replay helper.
- Return the cached response for same key plus same body.
- Return a conflict for same key plus different body.
- Keep the body validation and permission checks exactly as they are.
- Add focused route tests for missing key, replay, and conflict.

## Gap 2 - Data Accuracy Provenance Is Missing

Problem:

- `effective_data_accuracy_settings_v` resolves the final setting values.
- It does not expose the winning source scope for those values.
- Operator Web and Admin cannot honestly show whether a value was set at location, inherited from org/business, came from keyed service-period storage, or fell back to default.

Execution:

- Add an additive migration that appends provenance columns to the effective view.
- Preserve the existing value columns and existing precedence:
  - keyed per-location service-period rows
  - business scoped overrides
  - org-unit scoped overrides
  - location scoped overrides
  - data-accuracy base row
  - defaults
- Add source metadata for:
  - per-service-period covers source map
  - wage source
  - walk-in handling mode
- Keep each source object small and wire-safe:
  - `scope_type`
  - `scope_id`
  - `source_kind`
  - `setting_id` or `override_id` when available
- Extend proxy reads to emit the new source fields.
- Extend Dart models to parse the source fields without breaking older responses.
- Show plain source labels only where metadata exists.
- Do not fabricate source labels for missing source metadata.

## Orchestrator Role

- Own the plan, audit, integration, verification, commit, and push.
- Keep `master` untouched.
- Keep shared docs and final audit in the orchestrator lane.
- Review every worker change before staging.
- Serialize any overlap in `tool/advisor_proxy/advisor_proxy.dart` or migrations.

## Worker Lanes

### Lane A - Manual Covers Idempotency

Owns:

- `tool/advisor_proxy/advisor_proxy.dart`
- `test/proxy/mobile_operational_sync_routes_test.dart`

Tasks:

- Thread `AdminRequestIdempotencyStore` into the manual-covers route.
- Enforce `Idempotency-Key` on manual-covers PATCH.
- Use `_runAdminIdempotent` for reserve, replay, and conflict behavior.
- Add route tests for missing key, replay, and body mismatch.

### Lane B - Provenance Server And DTO

Owns:

- `db/migrations/*data_accuracy*provenance*.sql`
- `tool/advisor_proxy/proxy_bootstrap.dart`
- `lib/domain/models/data_accuracy_settings.dart`
- sync/operator-web DTO tests
- migration tests

Tasks:

- Append provenance columns to `effective_data_accuracy_settings_v`.
- Emit provenance fields through proxy JSON.
- Parse provenance in the shared domain model.
- Preserve compatibility for older proxy responses.
- Run migration drift and cutoff checks.

### Lane C - Provenance UI Labels

Owns:

- `lib/operator_web/screens/data_accuracy_screen.dart`
- `lib/operator_web/widgets/covers_source_toggle.dart`
- `lib/operator_web/widgets/wage_source_toggle.dart`
- focused operator-web/admin widget tests

Tasks:

- Render labels only from parsed server metadata.
- Keep labels short and plain.
- Avoid changing the edit workflow beyond source visibility.
- If Admin already has selected-scope copy but not server-source metadata, wire the model first and only render honest labels where the row has source metadata.

## Verification Gates

- `flutter test test/proxy/mobile_operational_sync_routes_test.dart`
- migration provenance tests
- proxy keyed data-accuracy tests
- domain model data-accuracy tests
- operator-web data-accuracy tests touched by provenance labels
- `dart run tool/migration_drift_scanner.dart --fix --strict-docs`
- `dart run tool/migration_cutoff_lint.dart`
- `dart run tool/postgres_import_lint.dart`
- `dart run tool/permission_key_lint.dart`
- `dart run tool/ux_em_dash_lint.dart`
- `dart run tool/advisor_proxy_size_lint.dart`
- `git diff --check`

## Guardrails

- No live cloud, Firebase, billing, or provider mutations.
- No destructive git commands.
- No fake inheritance labels.
- No broad refactor of the proxy monolith.
- No worker edits to trackers or ledgers.
- Schema and proxy changes get a local audit before commit.
