# p4_session_record_predicate — soak session-record completeness predicate

**Runner:** `test/pressure/p4_session_record_predicate_test.dart`
(unit tests for `tool/pressure/p4_session_record_predicate.dart`)

**What it pressures:** the shared `SessionRecordCompleteness.assertComplete`
predicate the p4 soak harnesses (and the future production observability
gauge) use to decide whether a session record carries the expected
tenant-scoping fields. Two contracts live here: tenant-scoped (operator
+ location required) and global-admin (`ff_support` / `super_admin`
roles — operator/location MUST be empty).

**Status at f0bf2702:** PASS. Pure-function unit tests; deterministic.

## Inputs

- No env vars. Hermetic.
- Predicate inputs: a session-record map (`session_id`, `user_id`,
  `operator_id`, `location_id`) + a `roles` set.
- Helpers also tested: `parseSoakDurationSeconds`, `isSoakProxyUrlAllowed`.

## What it asserts

- Tenant-scoped path (no admin roles): all four fields non-empty →
  `complete`. Empty `operator_id` / `user_id` / `location_id` lands
  in `missingFields`.
- Global-admin path (`ff_support` or `super_admin` role present):
  `session_id` + `user_id` required, `operator_id` + `location_id`
  MUST be empty; non-empty operator/location flags into
  `unexpectedFields`.
- Mixed-role token (admin + tenant role) always maps to the admin
  branch.
- `session_id` empty is flagged regardless of role mode.
- `parseSoakDurationSeconds`: `30s` → 30, `5min` → 300, `2h` → 7200;
  garbage like `forever` throws `FormatException`.
- `isSoakProxyUrlAllowed`: accepts `localhost`, `127.0.0.1`,
  `forge-flow-preview-*`, `forge-flow-staging-*`; refuses production
  hosts and arbitrary domains.

## How to read the output

- Healthy run: all 13 unit tests pass; no committed findings file
  (pure predicate pinning).
- Regression: any role-mode mis-routing leaks tenant-scoped session
  records into the global-admin branch (or vice versa), which would
  poison the soak orchestrator's per-pod breakdown and the future
  production gauge.

## Related

- Authority: `docs/_audits/code_health/code_hardening_plan_2026_05_21.md`
  §2.4, backlog item #10
- Production code: `tool/pressure/p4_session_record_predicate.dart`
- Consumer: `tool/pressure/p4_soak_orchestrator.dart`
- Last touched: see `git log -- test/pressure/p4_session_record_predicate_test.dart`
