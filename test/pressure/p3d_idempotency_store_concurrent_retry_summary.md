# p3d_idempotency_store_concurrent_retry — Phase 3D idempotency concurrent retry

**Runner:** `test/pressure/p3d_idempotency_store_concurrent_retry_test.dart`
(in-process UNIQUE-key store model).

**What it pressures:** the idempotency contract shared by
`proxy_requests`, `handoff_codes`, `auth_step_up_challenges`, and
`mobile_push_outbox` — concurrent retries with the same idempotency
key produce exactly one side effect. The in-process model mirrors
the production `insert ... on conflict (operator_id, location_id,
idempotency_key) do nothing returning ...` shape used by
`tool/advisor_proxy/advisor_proxy.dart` `_reserveIdempotency`.

**Status:** PASS. The in-memory pressure runs under default
`flutter test` (no env gate, no skips).

## Inputs

- In-memory inputs: a deterministic UNIQUE-key store that uses
  Dart's single-threaded event-loop atomicity to mirror the Postgres
  UNIQUE-constraint + ON CONFLICT DO NOTHING guarantee.

## What it asserts

- N=100 concurrent reserve attempts on one key → exactly one winner,
  99 idempotent-replay losers.
- 100 retries across 10 keys → exactly 10 side effects (no
  cross-key collision).
- Tenant scoping holds — the same request key under two operators is
  two independent reservations.
- Losers never observe a torn intermediate payload (either null or
  the final value).

## How to read the output

- Healthy run: 4 in-memory test cases pass.
- Regression: a failure means the UNIQUE-key model's atomicity
  assumption is violated, which would signal a real concurrency bug
  in the production idempotency path. Escalate per the auth/proxy
  gate (idempotency tables include auth-adjacent surfaces).

## Authority

`docs/_audits/code_health/code_hardening_plan_2026_05_21.md` §2.3 #3.

## Deferred

DB-backed concurrency pressure (N=100 raw concurrent INSERTs against
each of the four real tables, asserting UNIQUE-constraint defense +
exactly one committed row per key) needs a live Postgres and is
deferred to a future infra-gated slice — see POST_HARDENING_FOLLOWUPS.
