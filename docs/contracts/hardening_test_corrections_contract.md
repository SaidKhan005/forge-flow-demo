# Hardening — Test Corrections Contract

> **Status (2026-05-02):** Closed. Shipped commit `31854f4` (PR #49).
> Contract is retained as historical authority; no further implementation
> work owed.


Updated: 2026-05-02
Owner: HARD-H (test correctness sprint)
Status: Active authority

## Why This Exists

Three test issues are blocking accurate verification of recent slice
output: (1) `tx.parameters.last` in `user_lifecycle_live_binding_test.dart`
is fanout-fragile and may match the wrong table when audit fanout occurs;
(2) two recently merged surfaces — feature flags admin and per-location
boundary monitor — have unit/integration tests but no live-binding test
exercising real Postgres, leaving Phase 9 RLS guarantees under-verified;
(3) Windows checkouts hit CRLF mismatches in migration assertions per
`docs/KNOWN_FAILING_TESTS.md`. This contract resolves all three so the
gate matrix becomes deterministic and the audit-event matrix stays
fully covered.

Handoff between:

- `test/user_lifecycle_live_binding_test.dart` — Codex M-10 fix.
- new `test/feature_flags_admin_live_binding_test.dart`.
- new `test/current_state_boundary_monitor_live_binding_test.dart`.
- `docs/KNOWN_FAILING_TESTS.md` — entries closed by HARD-H.
- `test/` migration-content assertions touched by CRLF normalization.

Disagreement rule: this contract wins for assertion patterns and
required live-binding scope. The repo Phase 9 isolation sweep test
remains authoritative for RLS coverage; this contract adds *new* live
verifications, not replacements.

## In Scope

| Item | In | Out |
|------|-----|-----|
| Replace `tx.parameters.last` with statement-anchored lookup | yes | rewriting `_LifecyclePool` test double |
| Add live-binding test for feature-flags admin gateway | yes | UI-level widget tests (already covered) |
| Add live-binding test for per-location boundary monitor | yes | reviewing G.2 implementation |
| CRLF-normalize migration-content test assertions | yes | normalizing migration files themselves |
| Update `docs/KNOWN_FAILING_TESTS.md` entries that close | yes | broad triage of unrelated entries |

Out of scope: extending live-binding coverage to corpus admin /
integration admin / pricing tier admin (Phase 10+). Adding
property-based tests. Mutation testing. Flake-quarantine tooling.

## Required — Audit Binding Test Fix

`test/user_lifecycle_live_binding_test.dart:332` currently asserts on
`tx.parameters.last`. Replace with a statement-anchored lookup:

```dart
final tx = pool.transactions.single;
final insertIndex = tx.executedSql.indexWhere(
  (sql) =>
      sql.toLowerCase().contains('insert into auth_events_audit') &&
      sql.toLowerCase().contains('returning event_id'),
);
expect(insertIndex, isNonNegative,
    reason: 'auth_events_audit INSERT not observed in transaction');
final params = tx.parameters[insertIndex];
expect(params['event_type'], equals('auth.login_succeeded'));
expect(params['ip'], equals('1.2.3.4'));
expect(params['payload'], equals('{"method":"email_password"}'));
```

If `_LifecyclePool` does not currently expose `executedSql` aligned with
`parameters`, extend the test double minimally to expose both lists in
parallel. Do not change repository behavior. This is a test-only fix.

Apply the same pattern elsewhere in the file (and any sibling test) that
relies on `.last` against fanout transactions.

## Required — Feature Flags Admin Live-Binding Test

New file: `test/feature_flags_admin_live_binding_test.dart`.

Connects to a local Postgres (existing convention from
`auth_live_binding_test.dart`, `mfa_live_binding_test.dart`) and verifies:

1. **Toggle round-trip.** `POST /v1/admin/feature-flags/toggle` writes a
   flag state row and exactly one `audit_logs` row tagged
   `admin.feature_flag_toggled`.
2. **Idempotency.** Two calls with the same `Idempotency-Key` and identical
   payload produce one audit row (verifies HARD-D contract).
3. **RLS isolation.** Toggle as operator A, then as operator B; querying
   `audit_logs` with `app.operator_id = A` returns A's row only.
4. **Permission gating.** Calling toggle as a non-admin returns 403; no
   audit row written.
5. **Audit hash chain integrity.** After two toggles, `audit_logs.row_hash`
   chain validates from the prior anchor (uses existing helper from
   `phase_9_0sigma_f_audit_logs_test.dart`).

Test must skip with a clear message when `LIVE_BINDING_POSTGRES_URL` is
unset (matches existing live-binding pattern; do not invent a new
toggle).

## Required — Boundary Monitor Live-Binding Test

New file: `test/current_state_boundary_monitor_live_binding_test.dart`.

Connects to live Postgres and verifies the per-location boundary monitor
landed in G.2:

1. **Per-location instance isolation.** Two locations with different
   timezones (`America/Toronto`, `America/Mexico_City`) each get their
   own monitor instance; advancing system time across one location's
   business-day rollover triggers exactly that location's boundary
   event, not the other's.
2. **RLS filter.** Boundary events written under operator A are not
   visible to a session bound to operator B.
3. **Supervisor restart.** Killing one monitor instance triggers
   supervisor recreation without dropping events; durable backlog is
   read on restart.
4. **DST transition.** A location whose `business_day_rollover_hour`
   crosses a DST boundary still emits exactly one rollover event per
   business day (no duplicates, no skips).

Skip when `LIVE_BINDING_POSTGRES_URL` is unset.

## Required — CRLF Normalization

`docs/KNOWN_FAILING_TESTS.md` documents Windows CRLF failures in
migration-content assertions. Fix the **assertions**, not the migration
files (migrations are version-controlled with their committed line
endings):

In every test that reads a `db/migrations/*.sql` file and asserts on its
content, normalize CRLF to LF before comparison:

```dart
final raw = await File(path).readAsString();
final content = raw.replaceAll('\r\n', '\n');
expect(content, contains('expected substring'));
```

Or wrap in a helper `readMigrationLF(String path)` and use it everywhere
migration content is asserted.

After the fix, update `docs/KNOWN_FAILING_TESTS.md` to mark the CRLF
entry as closed (do not delete the entry — strike through with a
"resolved 2026-05-02 in HARD-H" annotation per existing doc convention).

## Out of Scope

- Extending live-binding coverage to other admin surfaces.
- Refactoring `_LifecyclePool` beyond exposing `executedSql` parallel to
  `parameters`.
- Live-binding harness performance optimization.
- Flake quarantine.

## Test Surface

- Repaired `user_lifecycle_live_binding_test.dart` passes against current
  repo behavior with fanout writes present.
- New live-binding tests pass when `LIVE_BINDING_POSTGRES_URL` is set;
  skip cleanly when unset.
- All other live-binding tests still pass (no shared-fixture regression).
- Migration-content tests pass on Windows checkouts (verify by running
  `dart test test/migrations/` on Windows or confirm CRLF replacement
  in the file content).
- `dart analyze --fatal-infos` clean.

## Codex Acceptance

- [ ] `tx.parameters.last` removed from `user_lifecycle_live_binding_test.dart`
      (`Grep "parameters.last" test/` returns zero hits in
      audit-binding context).
- [ ] `test/feature_flags_admin_live_binding_test.dart` exists and covers
      toggle, idempotency, RLS, permission, audit chain.
- [ ] `test/current_state_boundary_monitor_live_binding_test.dart` exists
      and covers per-location, RLS, supervisor restart, DST.
- [ ] All migration-content assertions normalize CRLF.
- [ ] `docs/KNOWN_FAILING_TESTS.md` CRLF entry annotated as resolved.
- [ ] All listed tests pass when live binding configured; skip cleanly
      otherwise.
- [ ] `dart analyze --fatal-infos` clean.
