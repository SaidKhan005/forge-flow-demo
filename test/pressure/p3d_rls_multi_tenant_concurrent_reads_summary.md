# p3d_rls_multi_tenant_concurrent_reads — Phase 3D RLS wrappers under concurrency

**Runner:** `test/pressure/p3d_rls_multi_tenant_concurrent_reads_test.dart`
(structural posture check against the migration file).

**What it pressures:** the four RLS UUID wrapper functions in
`db/migrations/202604280000_phase_9_0sigma_b_rls_wrappers.sql` —
`app_current_operator`, `app_current_location`,
`app_current_actor_user`, `app_acting_as_operator`. The contract:
all four wrappers are declared with the `STABLE LEAKPROOF PARALLEL
SAFE` posture and the null-safe GUC cast, so a rename or
posture-downgrade regression is caught.

**Status:** PASS. The migration-shape contract runs under default
`flutter test` (no env gate, no skips). RLS lives only in Postgres,
so the runnable portion is the structural posture check.

## Inputs

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

- Healthy run: 3 structural-posture tests pass.
- Regression: a posture-downgrade in the migration file (e.g.
  someone dropped LEAKPROOF) is caught immediately and surfaces in
  the failing assertion message.

## Authority

`docs/_audits/code_health/code_hardening_plan_2026_05_21.md` §2.3 #2.

## Deferred

DB-backed concurrency pressure (N concurrent operators flipping
(operator_id, location_id) on a shared pool, asserting zero
cross-tenant row visibility) needs a live Postgres and is deferred
to a future infra-gated slice — see POST_HARDENING_FOLLOWUPS.
Single-tenant isolation is already covered by
`rls_isolation_p2_repos_test.dart`.
