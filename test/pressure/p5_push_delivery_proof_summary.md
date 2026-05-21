# p5_push_delivery_proof — two-device push delivery proof (deferred stub)

**Runner:** `test/pressure/p5_push_delivery_proof_test.dart`
(unit tests for `tool/pressure/p5_push_delivery_proof.dart` — Slice C-11)

**What it pressures:** the state-machine seam in front of the two-device
Patrol push-delivery proof. The full two-device proof body is deferred
(Patrol is not yet in `dev_dependencies`); this harness pins the
env-gated inert behavior, the URL allow-list, and the pinning test that
will fail loudly the moment Patrol lands so the wired branch gets a
code review.

**Status at f0bf2702:** PASS. The runner is a structural shim until
Patrol lands and the ready-state body is filled in.

## Inputs

- Harness env vars (read by `runPushDeliveryProof`):
  - `PATROL_DEVICE_A_ID`, `PATROL_DEVICE_B_ID`
  - `PROXY_URL` (must pass the preview/staging/localhost allow-list)
  - `PROXY_OPERATOR_TOKEN_A`, `PROXY_OPERATOR_TOKEN_B`
- Dev-dependencies probe: `kDeclaredDevDependencies` mirrors
  `pubspec.yaml`; the harness checks for the `patrol` entry.

## What it asserts

- `evaluatePushDeliveryState` 4-way state machine:
  - Patrol missing from `dev_dependencies` → `deferredPatrolMissing`
  - Patrol present but any required env var absent →
    `deferredEnvMissing`
  - Production-looking `PROXY_URL` → `deferredProxyValidationFailed`
  - All preconditions met → `ready`
- `buildSkippedLine` reason strings cite the cause (Patrol /
  dev_dependencies, the missing env var names, the allow-list +
  "production").
- `runPushDeliveryProof` emits exactly ONE structured log line per
  invocation and exits 0 in every deferred state.
- Ready state emits a `ready_but_unimplemented` line whose reason
  cites the follow-up (Patrol body is the next slice).
- Pinning guard: `kDeclaredDevDependencies` does NOT contain `patrol`
  — when it does, this test fails loudly so the wired branch gets
  a code review (instructions live in the test reason string).

## How to read the output

- Healthy run: all tests pass; emitted JSON decodes with the
  documented `metric: push_delivery.skipped`, `state`, `reason` shape.
- Regression: a state mis-route (e.g. Patrol-missing + env-missing both
  routing to one branch) would mask the actual blocker; relaxing the
  URL allow-list silently breaks the production-guard.
- No committed findings file — the harness emits one line per
  invocation; the ready-state path is intentionally stubbed.

## Related

- Authority: `docs/_audits/code_health/code_hardening_plan_2026_05_21.md`
  §2.4, backlog item #10
- Production code: `tool/pressure/p5_push_delivery_proof.dart`
- Companion harness: `p5_email_scenario_loopback_test.dart`
- Last touched: see `git log -- test/pressure/p5_push_delivery_proof_test.dart`
