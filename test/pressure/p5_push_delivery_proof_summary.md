# p5_push_delivery_proof — two-device push delivery proof readiness gate

**Runner:** `test/pressure/p5_push_delivery_proof_test.dart`
(unit tests for `tool/pressure/p5_push_delivery_proof.dart` — Slice C-11)

**What it pressures:** the state-machine seam in front of the two-device
Patrol push-delivery proof. Patrol is now declared in `dev_dependencies`,
but the full two-device proof body is still deferred behind device/env
wiring. This harness pins the env-gated inert behavior, the URL allow-list,
and the non-zero ready-state placeholder so a fully-prepared run cannot look
green until the actual Patrol body exists.

**Status as of 2026-05-27:** PASS. The runner is a structural shim until
the ready-state body is filled in.

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
- Ready state emits `metric: push_delivery.not_implemented`,
  `state: ready_but_unimplemented`, and exits 2 so the proof cannot pass
  without running.
- Dependency guard: `kDeclaredDevDependencies` contains `patrol`, and the
  default dependency list reaches the `ready` state when all required env vars
  are present.

## How to read the output

- Healthy deferred run: all tests pass; emitted JSON decodes with the
  documented `metric: push_delivery.skipped`, `state`, `reason` shape.
- Fully prepared but still-unimplemented run: emits
  `metric: push_delivery.not_implemented` and exits 2.
- Regression: a state mis-route (e.g. Patrol-missing + env-missing both
  routing to one branch) would mask the actual blocker; relaxing the
  URL allow-list silently breaks the production-guard.
- No committed findings file — the harness emits one line per
  invocation; the ready-state path intentionally fails until implemented.

## Related

- Authority: `docs/_audits/code_health/code_hardening_plan_2026_05_21.md`
  §2.4, backlog item #10
- Production code: `tool/pressure/p5_push_delivery_proof.dart`
- Companion harness: `p5_email_scenario_loopback_test.dart`
- Last touched: see `git log -- test/pressure/p5_push_delivery_proof_test.dart`
