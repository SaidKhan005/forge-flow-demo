# Canonical Fact Keyed Fixture Cleanup Plan

Status: complete
Date: 2026-05-20
Branch: `codex/canonical-keyed-fixture-cleanup`
Worktree: `.codex_worktrees/canonical-keyed-fixture-cleanup`
Base: `origin/master` at `fcaa0c16`

## Plain English Summary

- This is a test-fixture cleanup, not an API cleanup.
- The closed-shift integration test still seeded old
  `covers_source_lunch`, `covers_source_dinner`, and
  `covers_source_late_night` fields in fake Data Accuracy rows.
- Production code no longer reads those old fields. It reads
  `covers_source_per_service_period`.
- The cleanup replaces the stale fake fields with keyed maps, preserving the
  same test meaning.

## Scope

- In scope:
  - `test/services/integration/canonical_fact_to_closed_shift_input_test.dart`
- Out of scope:
  - Server request compatibility.
  - Server response compatibility.
  - Mobile sync compatibility.
  - Admin historical audit rendering.
  - Migrations.

## Execution

- Added keyed fixture maps for the common cases:
  - all periods use vendor covers.
  - dinner uses manual covers.
- Replaced every old scalar covers-source field in the test with the keyed
  `covers_source_per_service_period` map.
- Updated the fake read-path comment so it no longer says the model honors the
  old fallback fields.
- Verified the test file no longer contains the old covers-source field names.

## Guardrails

- Do not remove old API compatibility here.
- Do not change aggregator source-selection behavior.
- Do not rewrite historical migration or audit docs.
- Keep the fake aligned with `DataAccuracySettings.fromRow`: keyed map is the
  source of truth, absent periods default to vendor.

## Verification

- `flutter test test\services\integration\canonical_fact_to_closed_shift_input_test.dart`
  passed.
- `dart analyze test\services\integration\canonical_fact_to_closed_shift_input_test.dart`
  passed.
- `dart run tool\ux_em_dash_lint.dart` passed.
- `git diff --check` passed.
