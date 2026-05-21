# p3d_auth_lockout_cascade — Phase 3D auth lockout cascade

**Runner:** `test/pressure/p3d_auth_lockout_cascade_test.dart` (in-process
pressure against `InMemoryAuthLockoutEnforcer` in
`tool/advisor_proxy/advisor_proxy.dart`; DB-backed harness env-gated).

**What it pressures:** the auth login lockout rolling-window
contract — five failures per (email, ip) in a 15-minute window trip
a 15-minute lock. The in-process portion drives the same code path
the production route uses for evaluation; the live-Postgres backend
is reserved behind an env gate.

**Status at branch fork point:** PASS. All in-memory pressure runs
under the default `flutter test`; the env-gated DB cascade portion
skips with a clear reason.

## Inputs

- Env gate (DB portion): `FF_RUN_PRESSURE_P3D_AUTH_LOCKOUT=1` —
  without it the DB-backed test skips. Without a local Postgres +
  `auth_login_attempts` table, the env gate would still pass through
  to a `fail()` because this slice does not ship the DB harness; the
  env-gate path exists so a future slice can wire it in without
  changing this file's signature.
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

- Healthy run: all 5 in-memory test cases pass; the env-gate test
  skips with the documented message.
- Regression: any test failure surfaces a real correctness gap in
  the rolling-window math. Escalate per CLAUDE.md auth gate.

## Authority

`docs/_audits/code_health/code_hardening_plan_2026_05_21.md` §2.3 #1.

## Backlog

When the next pressure wave runs, swap the env-gate `fail()` for the
real DB-backed harness (50+ concurrent operators, real
`auth_login_attempts` partition).
