# Legacy Covers Wire-Key Cleanup Plan

Status: complete
Date: 2026-05-20
Branch: `codex/legacy-wire-key-cleanup`
Worktree: `.codex_worktrees/legacy-wire-key-cleanup`
Base: `origin/master` at `82059432`

## Plain English Summary

- The old database columns are already gone.
- The remaining old names are API names, not storage columns:
  `covers_source_lunch`, `covers_source_dinner`, and
  `covers_source_late_night`.
- Those old API names are still used as a compatibility bridge for older
  mobile/admin/proxy clients.
- Removing them now would be a breaking API change.
- This pass cleans stale live docs and records what must happen before the old
  API names can be retired.
- Live compatibility stays in place.

## What The Audit Found

- Server/admin write routes still accept the old names, then map them into the
  keyed per-service-period table:
  - `tool/advisor_proxy/advisor_proxy.dart:16700`
  - `tool/advisor_proxy/advisor_proxy.dart:16758`
  - `tool/advisor_proxy/proxy_bootstrap.dart:3391`
  - `tool/advisor_proxy/proxy_bootstrap.dart:5529`
- Server/mobile read routes still emit the old names from the keyed map for
  compatibility:
  - `tool/advisor_proxy/proxy_bootstrap.dart:10023`
  - `test/proxy/mobile_operational_sync_routes_test.dart:151`
- The current mobile sync parser uses keyed source metadata and does not need
  the old names for its main typed model:
  - `lib/services/sync/sync_proxy_client.dart:99`
  - `lib/services/sync/http_sync_proxy_client.dart:1050`
- Admin historical audit rows can still contain the old names, so audit display
  must keep rendering them:
  - `lib/admin/widgets/data_accuracy_audit_history_panel.dart:281`
  - `test/admin/data_accuracy_ux_framework_polish_test.dart:140`
- Operator Web is already keyed and explicitly avoids sending the old names:
  - `lib/operator_web/services/operator_web_data_accuracy_gateway.dart:330`
  - `test/operator_web/services/operator_web_data_accuracy_gateway_test.dart:215`
- Some active docs still described pre-fix behavior and needed cleanup:
  - `docs/_execution/surface_parity_gap_execution_plan.md`
  - `docs/_walkthroughs/8.spine-bridge.C.md`
- One test fixture area still has cleanable residue, but it is broad enough to
  keep as a later focused cleanup:
  - `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:506`
  - `test/services/integration/canonical_fact_to_closed_shift_input_test.dart:3638`

## Safe Changes In This Pass

- Marked the older surface-parity plan as closed/superseded so no one
  dispatches stale work from it.
- Updated its Data Accuracy section to say keyed proxy writes are now closed.
- Updated its Mobile Covers note to match the product decision: mobile is
  simple usage; full setup lives in Operator Web.
- Updated the Admin walkthrough text so current writes use
  `covers_source_per_service_period`, while old `covers_source_lunch` rows are
  described as historical audit compatibility.

## What Stays Untouched

- No server route compatibility was removed.
- No mobile sync compatibility was removed.
- No admin historical audit labels were removed.
- No migration history was rewritten.
- No fallback behavior changed.
- `canonical_fact_to_closed_shift_input_test.dart` still has old-field fixture
  residue. Cleaning it safely requires keeping equivalent keyed fixture rows in
  the integration setup, so it is documented instead of bundled into this doc
  cleanup.

## Retirement Plan If We Later Choose To Remove Old API Names

1. Add an explicit API deprecation decision.
2. Move any remaining old-name response tests to keyed map assertions.
3. Confirm no shipped mobile/admin clients need the old response names.
4. Keep historical audit display support even after old request/response names
   are removed.
5. Remove old request parsing from admin/mobile proxy routes in one gated PR.
6. Remove old response emission in a separate gated PR or a `/v2` response
   shape if backward compatibility matters.
7. Update contracts and walkthroughs after code lands.

## Verification

- `flutter test test\admin\walkthrough_doc_shape_test.dart` passed.
- `dart run tool\ux_em_dash_lint.dart` passed.
- `git diff --check` passed with only Git line-ending normalization warnings.
