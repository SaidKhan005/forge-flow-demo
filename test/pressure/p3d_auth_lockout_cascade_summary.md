# p3d_auth_lockout_cascade — Phase 3D auth lockout cascade

**Runner:** `test/pressure/p3d_auth_lockout_cascade_test.dart` (in-process
pressure against `InMemoryAuthLockoutEnforcer` in
`tool/advisor_proxy/advisor_proxy.dart`).

**What it pressures:** the auth login lockout rolling-window
contract — five failures per (email, ip) in a 15-minute window trip
a 15-minute lock. The in-process portion drives the same code path
the production route uses for evaluation.

**Status:** PASS. All in-memory pressure runs under the default
`flutter test` (no env gate, no skips).

## Inputs

- In-memory inputs: a deterministic `_FrozenClock` so window math
  is reproducible; synthetic email + IP fixtures.

## What it asserts

- 5 concurrent failed logins on (email, ip) trip lockout exactly
  once (no double-trip race).
- Post-lock evaluations all observe `locked=true` under burst.
- Lockout is keyed by (email, ip) — second IP for the same email is
  independent.
- Past the 15-minute window, the lock clears under concurrent
  re-attempts.
- A recorded success in the window resets the failure count for
  that (email, ip) — concurrent `recordSuccess` calls don't
  double-erase.

## How to read the output

- Healthy run: all 5 in-memory test cases pass.
- Regression: any test failure surfaces a real correctness gap in
  the rolling-window math. Escalate per CLAUDE.md auth gate.

## Authority

`docs/_audits/code_health/code_hardening_plan_2026_05_21.md` §2.3 #1.

## Deferred

DB-backed concurrency pressure (50+ concurrent operators against a
real `auth_login_attempts` partition) needs a live Postgres and is
deferred to a future infra-gated slice — see POST_HARDENING_FOLLOWUPS.
