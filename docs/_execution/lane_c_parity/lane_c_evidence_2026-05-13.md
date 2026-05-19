# Lane C — Evidence log (2026-05-13)

Created for C-11 (Wave Execution Ledger row 93). This is a **lane evidence log**, not a closure doc. It records what the C-11 pressure-test harnesses exercise, what they defer, and the architectural disclosures the operator should hold while reviewing.

Authority source: `docs/_execution/lane_c_parity/03_execution_slices.md` C-11 (lines 209-225). Inventory matrix: `docs/_audits/code_health/c_email_notification_scenario_inventory.md`. C-2 wire-or-delete decisions: `docs/archive/_decisions/c_2_email_template_wire_or_delete_decisions.md`.

## What landed

| File | Purpose | LoC |
| --- | --- | --- |
| `tool/pressure/p5_email_scenario_loopback.dart` | Mailosaur loopback for the admin SendGrid test-connection email + structured deferred-disclosure for every other inventory row. | ~680 |
| `tool/pressure/p5_push_delivery_proof.dart` | Env-gated stub for the Patrol two-device proof; emits one structured `push_delivery.skipped` line until Patrol is wired. | ~210 |
| `test/pressure/p5_email_scenario_loopback_test.dart` | Unit tests for harness math (`p95LatencyMs`, `subjectMatches`, `bodyMatches`), CLI parser, env-gated-inert posture, inventory consistency. | ~470 |
| `test/pressure/p5_push_delivery_proof_test.dart` | Unit tests for the harness state-machine + structured-log shape; pins the "patrol not yet wired" invariant. | ~210 |

Total: 2 production CLI binaries + 2 unit test files; **0 changes** to `lib/`, `tool/advisor_proxy/`, `db/migrations/`, or `lib/auth/`.

## Email loopback — what gets exercised

### Wired (self-driveable from the harness)

| Template id | Source route | Subject expectation | Notes |
| --- | --- | --- | --- |
| `operator_invite_first_admin` | `POST /v1/admin/integrations/email/test` (`tool/advisor_proxy/admin_email_routes.dart`) | `Welcome to Forge & Flow — set up your account` | The only path the harness can self-trigger over HTTP. Sample template data (`F&F Test Admin`, `Forge & Flow Demo`) is body-asserted. |

### Wired (exists in production, NOT self-driveable from this harness)

Reported as `status: deferred` with the reason `wired-but-not-self-trigger: this harness only drives the admin-test send route`. Operator triggers the upstream worker in parallel for a complete sweep.

| Template id | Trigger surface | Why not self-driven |
| --- | --- | --- |
| `vendor_now_available` | `tool/advisor_proxy/email_dispatch/vendor_lifecycle_notification_dispatcher.dart` | Requires populating `vendor_lifecycle_notification` rows + a vendor-lifecycle promotion event in Postgres. |
| `backfill_complete` | `tool/integration_sync_worker/backfill_dispatch.dart` `markSucceeded` | Requires running the first-connect backfill worker to terminal-success. |
| `backfill_failed` | `tool/first_connect_backfill_worker/main.dart` `RetryCappingBackfillJobStore.markFailed` | Requires injecting persistent backfill failures past the retry cap. |
| `audit_anchor_failure` | `tool/audit_anchor/main.dart` (`_runAnchorMode` / `_runSweepMode`) | Requires the daily audit-anchor cron to hit `chainHashMismatch` / `recoveredFailed` / Azure-blob-unavailable. |

### Deferred per C-2 matrix (template-only)

Each emits a `status: deferred` line citing the matrix row. Skipped cleanly.

| Template id | C-2 matrix row |
| --- | --- |
| `mfa_factor_changed_notice` | Draft C — server-side MFA-factor-changed emission site pending. |
| `vendor_sync_error_alert` | Draft D — first-failure-of-outage detector pending. |
| `vendor_webhook_signature_alert` | Draft E — centralized failed-signature counter pending. |
| `vendor_connection_auto_disabled` | Draft F — OAuth refresh worker fanout wiring pending. |
| `tos_version_updated_notice` | Draft G — TOS publish workflow pending. |

### Firebase-managed (NOT a SendGrid loopback target)

`firebase_password_reset`, `firebase_email_verification`, `firebase_invite_via_password_reset` are emitted by the Firebase Identity Platform action-link templates and never land in `email_outbox`. The slice spec calls out Playwright as the future probe shape for these (R4 §7A future work — not in scope for C-11).

## Push delivery proof — what gets exercised

**Nothing today.** Patrol is not in `pubspec.yaml`'s `dev_dependencies` block, no test devices are provisioned for the preview deployment, and no `PATROL_DEVICE_*` env vars are wired. The harness emits ONE `push_delivery.skipped` JSON line and exits 0.

The harness exposes a `PushDeliveryHarnessState` enum (`ready` / `deferredPatrolMissing` / `deferredEnvMissing` / `deferredProxyValidationFailed`) so the future Patrol slice can flip the state-machine to `ready` without rewriting the CLI entry point. Test pinning at `test/pressure/p5_push_delivery_proof_test.dart` asserts `kDeclaredDevDependencies.contains('patrol') == false` so the day Patrol lands in pubspec, the pinning test fails loudly and forces the body to be replaced.

## Architectural disclosures

### Pure HTTP via `dart:io` (NO `mailosaur` package import)

The harness talks to Mailosaur's REST API (`https://mailosaur.com/api/messages`) via `HttpClient.getUrl` with HTTP Basic auth (API key as the username half). This avoids expanding the dev-dependency graph for what is a 7-line REST contract. Mirrors the `dart:io`-based pattern in `tool/pressure/p4_heap_snapshot_uploader.dart`'s `GcsHeapSnapshotUploadTarget`.

### Env-gated-inert posture mirrors A11.2 heap-snapshot uploader

When `MAILOSAUR_API_KEY` OR `MAILOSAUR_SERVER_ID` is unset, `runEmailLoopback` emits ONE structured `email_loopback.skipped` line and exits 0. NEVER fabricates a green result. NEVER throws to the root zone. This is the same posture `tool/pressure/p4_heap_snapshot_uploader.dart` uses when `GCS_BUCKET_HEAP_SNAPSHOTS` / `GCS_BEARER_TOKEN` are unset.

### Allow-list defense against driving production

Both harnesses validate `PROXY_URL` against `{preview., staging., localhost, 127.0.0.1}` substrings before issuing any request. A misconfigured run exits 2 (email harness) or emits a `deferredProxyValidationFailed` skip (push harness). Mirrors `kSoakAllowedHostSubstrings` in `tool/pressure/p4_session_soak.dart`.

### `operator_invite_first_admin` is the only self-driveable wired email path

This is a deliberate scope choice. Driving the other wired surfaces (`vendor_now_available`, `backfill_complete`, `backfill_failed`, `audit_anchor_failure`) requires either:

1. A real Postgres-side state mutation (a vendor's lifecycle row promoting, a backfill job marking, an audit anchor failing) — which would either need a separate Postgres-aware harness or admin-route fixtures that don't exist on master today.
2. An operator-side parallel trigger (run the upstream worker in parallel; the harness observes any email Mailosaur receives during the poll window).

The harness records option 2 as the operator's owed parallel step in the structured log line (the `wired-but-not-self-trigger` deferred record). Operator can wire a follow-up slice that adds admin-route trigger surfaces if the parallel-trigger pattern proves too operationally heavy.

### R4 reference resolution

The slice spec cites "R4 §7A", "R4 §4B", "R4 §7C", and "R4 §3B" as authority for the harness shapes. A search of `docs/` did not surface a canonical "R4" reference document (only the SLO budget number embedded in the inventory rollup section 11.b — bell-badge invalidation ≤5s). The harness treats these references as scope hints with the implied semantics:

- **R4 §7A** → Mailosaur loopback for outbound SendGrid emails (and Playwright loopback for Firebase action-link emails as future work).
- **R4 §4B** → Patrol harness for FCM delivery proof.
- **R4 §7C** → push-delivery foreground / background / terminated branch proof.
- **R4 §3B** → bell-badge invalidation SLO ≤5s.

If a canonical R4 document surfaces, the harness's expectation copy can be tightened in a follow-up.

## What CI will see

When CI runs `dart run tool/pressure/p5_email_scenario_loopback.dart` and `dart run tool/pressure/p5_push_delivery_proof.dart` without env vars wired (the default state today):

```
{"ts":"<iso>","metric":"email_loopback.skipped","reason":"MAILOSAUR_API_KEY unset — harness skipped; wire MAILOSAUR_API_KEY + MAILOSAUR_SERVER_ID in CI env"}
```

```
{"ts":"<iso>","metric":"push_delivery.skipped","state":"deferredPatrolMissing","reason":"Patrol/Flutter mobile test infra not wired — add patrol + patrol_finders to dev_dependencies, wire test devices, and re-run"}
```

Both exit 0 — no CI red.

## Operator's owed actions to unlock the harness

1. **Mailosaur**: sign up for a Mailosaur account (free tier suffices for the admin-test loopback). Wire `MAILOSAUR_API_KEY` + `MAILOSAUR_SERVER_ID` into the preview CI environment's secret manager. Optional: customize `MAILOSAUR_INBOX` if a non-default inbox is preferred.
2. **Proxy admin token**: provision a `super_admin` Firebase token for the preview tenant. Wire `PROXY_ADMIN_TOKEN` + `PROXY_URL=https://preview.forgeflow.app` into CI env.
3. **(Optional) Patrol wiring**: when push-delivery proof becomes a priority, add `patrol` + `patrol_finders` to `pubspec.yaml`'s `dev_dependencies` block, append `'patrol'` to `kDeclaredDevDependencies` in `tool/pressure/p5_push_delivery_proof.dart`, replace the `ready_but_unimplemented` stub in the same file with the two-device proof body, wire `PATROL_DEVICE_A_ID` / `PATROL_DEVICE_B_ID` / `PROXY_OPERATOR_TOKEN_A` / `PROXY_OPERATOR_TOKEN_B` to CI env, and provision two test devices accessible to the preview FCM project. The pinning test at `test/pressure/p5_push_delivery_proof_test.dart` will fail loudly when step 1 of this lands, forcing steps 2-4 in the same PR.
4. **(Optional) Postgres trigger fixtures**: if the operator wants the harness to self-trigger `vendor_now_available` / `backfill_complete` / `backfill_failed` / `audit_anchor_failure` instead of relying on parallel worker runs, add admin-route fixtures (a follow-up slice). C-11 deliberately scoped to the admin-test path only to avoid scaffolding new auth surfaces.

## Non-goals (explicit)

- C-11 does NOT touch `tool/advisor_proxy/advisor_proxy.dart` (the monolith; bleed-stop at 19,812 lines — 88 line headroom).
- C-11 does NOT touch `tool/advisor_proxy/sendgrid_events_webhook.dart` (C-1 inbound webhook, just merged in PR #611).
- C-11 does NOT touch `lib/services/email/` or `lib/auth/**`.
- C-11 does NOT add any migration.
- C-11 does NOT write any `audit_logs UPDATE` rows.
- C-11 does NOT add any new permission key.
- C-11 does NOT bypass any local hook (`--no-verify` not used).
- C-11 does NOT update any tracker / lane index / ledger row.
- C-11 does NOT modify `pubspec.yaml`.
