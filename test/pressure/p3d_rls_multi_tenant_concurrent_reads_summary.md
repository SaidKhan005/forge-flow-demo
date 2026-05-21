# p3d_rls_multi_tenant_concurrent_reads — Phase 3D RLS wrappers under concurrency

**Runner:** `test/pressure/p3d_rls_multi_tenant_concurrent_reads_test.dart`
(structural posture check + env-gated DB harness reservation).

**What it pressures:** the four RLS UUID wrapper functions in
`db/migrations/202604280000_phase_9_0sigma_b_rls_wrappers.sql` —
`app_current_operator`, `app_current_location`,
`app_current_actor_user`, `app_acting_as_operator`. The contract:
each wrapper returns the correct UUID from its GUC under rapid
tenant-context flips, with the `STABLE LEAKPROOF PARALLEL SAFE`
posture intact.

**Status at branch fork point:** PASS. The migration-shape contract
runs under default `flutter test`; the live-Postgres concurrent
flip portion skips (no in-memory analogue — RLS lives only in PG).

## Inputs

- Env gate (DB portion): `FF_RUN_PRESSURE_P3D_RLS=1` AND a local
  Postgres connection with the 202604280000 series migrations
  applied. Without these, the env-gate test skips with a clear
  reason.
- Migration file: read-only inspection of
  `db/migrations/202604280000_phase_9_0sigma_b_rls_wrappers.sql`.

## What it asserts

- All four wrappers exist and carry the LEAKPROOF attribute (a
  rename or attribute downgrade is caught here).
- Each wrapper uses the null-safe `nullif(current_setting(...),
  '')::uuid` pattern (fail-closed default on unset GUC).
- `STABLE` is declared per wrapper; no wrapper accidentally claims
  `IMMUTABLE` (which would be incorrect — GUCs change per
  transaction).

## How to read the output

- Healthy run: 3 structural-posture tests pass; the env-gate test
  skips with the documented message.
- Regression: a posture-downgrade in the migration file (e.g.
  someone dropped LEAKPROOF) is caught immediately and surfaces in
  the failing assertion message.

## Authority

`docs/_audits/code_health/code_hardening_plan_2026_05_21.md` §2.3 #2.

## Backlog

DB-backed concurrent-flip harness — N concurrent operators
flipping (operator_id, location_id) on a shared pool, asserting
zero cross-tenant row visibility. The existing
`rls_isolation_p2_repos_test.dart` covers single-tenant; concurrency
fan-out lives here once the DB harness is written.
