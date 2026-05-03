# Phase 9 Execution Backlog

Updated: 2026-04-29.

Purpose: keep only the accepted Phase 9 follow-ups visible. Completed result
reports and the full pre-lean backlog are archived under
`docs/archive/phases/phase_9/`.

Decision sources:

- `docs/phases/phase_9/phase_9_decision_lock_2026-04-26.md`
- `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`
- `docs/phases/phase_9/phase_9_scalability_performance_audit_2026-04-27.md`

Archived history:

- `docs/archive/phases/phase_9/phase_9_execution_backlog_2026-04-29_PRE_CLOSEOUT_LEAN.md`
- Completed Phase 9 result reports in `docs/archive/phases/phase_9/`
- Tracker snapshot in `docs/archive/trackers/PROJECT_TRACKER_2026-04-29_PRE_PHASE9_CLOSEOUT_LEAN.md`

## Current State

Accepted for next-phase handoff on 2026-04-29.

Closed and verified:

- Phase 9 auth schema/RLS/grants and 9.0a live database closeout are applied on
  staging and Production1.
- B17 custom role catalog CRUD is implemented locally for
  `GET/POST/PATCH/DELETE /v1/admin/auth/roles`, including scope-filtered
  listing, proxy route/client contracts, repository bindings, focused tests,
  and staging smoke on `forge-flow-staging-proxy-00018-ztq`.
- Staging Cloud Armor/reCAPTCHA edge exists in preview mode; HTTPS `/readyz`
  passes on `staging-api.feflow.org`. B17 role CRUD exposed SQLi preview false
  positives in the original WAF rule; the policy is now preview-only at
  sensitivity 2 with B17 false-positive SQLi signatures opted out. Normal B17
  CRUD has zero preview hits after tuning, while a controlled SQLi probe still
  logs a preview signal.
- GitHub Apple run `25087331405` passed macOS host tests and both ForgeFlow and
  Barrio iOS simulator builds on `master`.
- Staging and Production1 applied and verified `202604280000` through
  `202604280013`. Azure `ltree` allow-listing, Azure `pg_cron` maintenance DB
  scheduling, and first successful rollup cron runs are documented in
  `runbooks/phase_9_production1_migration_apply_runbook.md` and the archived
  apply result.
- B42 proxy `/health` v1 envelope is implemented locally with compatibility
  aliases, dependency checks, reserved metric keys, and reserved surface keys.
  Focused proxy tests pin the wire shape.
- B41 service-principal JWT issuance and B46 advisor audit-privacy are locally
  implemented, contracted, and tested. Their additive live migrations
  (`202604290000` and `202604280014`) still need explicit staging +
  Production1 apply evidence before live phases depend on them.
- B44/B45/B47 helper, runbook, and metric producer wiring now exist; remaining
  work is the 11A.5/11A.6 UX/observability surface and live evidence.
- Latest local baseline: `flutter analyze --fatal-infos`,
  `dart run tool/rls_policy_lint.dart`, focused B17 auth/proxy tests,
  `git diff --check`, and full `flutter test --reporter compact` passed
  (`2544/2544`).

Do not re-open stale findings unless the repo regresses:

- Tenant-leading auth indexes already lead with `operator_id`.
- Phase 9 auth-table RLS/grants are live on staging and Production1.
- Azure extension and preload requirements are captured in setup/runbook docs.
- The first Production1 migration apply is no longer queued. A second
  Production1 apply batch is now queued for `202604280014` through
  `202605021900`; use `runbooks/phase_9_production1_migration_apply_runbook.md`
  and `docs/POST_HARDENING_FOLLOWUPS.md` P0 as the live authority.

## Remaining Live-Closeout Gates

| Gate | Status | Next action |
| --- | --- | --- |
| Cloud Armor enforcement | Preview-only, tuned, heartbeat monitor active | Heartbeat `cloud-armor-preview-review` will update this session. Collect at least 3 clean days of post-tuning preview logs, confirm no false positives on `/readyz`, `/v1/auth/*`, or `/v1/admin/auth/*`, then ask for explicit enforcement approval. |
| iOS physical device matrix | Deferred by user | Automated GitHub Apple run `25087331405` is green on `master`; the user will come back to the physical ForgeFlow/Barrio matrix later with an Apple device/signing lane. |
| B17 staging smoke | Complete | Staging revision `forge-flow-staging-proxy-00018-ztq` passed list/create/patch/delete/cleanup through `staging-api.feflow.org`. |
| Maintenance baseline | Green | Re-run analyzer/RLS lint/focused tests/full tests after every merge or live-closeout change. |

## Open Follow-On B-Items

These remain as implementation or hardening work; they are not blockers for the
already-completed Production1 apply unless explicitly stated.

| B-item | Status | Owner phase / gate |
| --- | --- | --- |
| B33 usage/log reconciliation hardening | complete | Two-slot writer at `advisor_proxy.dart:2906`; `usage_logs_two_slot_rollup_uq` constraint flipped in `202604280006_c` |
| B34 audit attribution contract clarification | complete | `docs/contracts/audit_attribution_contract.md` (Active authority) pins `actor_kind` discriminator + `text` vs `uuid` divergence |
| B36 cross-tenant RLS isolation integration sweep | complete | `test/phase_9_0sigma_rls_isolation_sweep_test.dart` â€” passive-by-default 13-table sweep gated on `FORGE_FLOW_RUN_STAGING_RLS_SWEEP=true` |
| B37 audit hash-chain verifier E2E test | complete | `test/phase_9_0sigma_f_audit_chain_e2e_test.dart` â€” 100 rows Ã— 3 ops Ã— 2 dates; `tool/audit_anchor/test/anchor_e2e_test.dart` covers anchor surface |
| B38 Tier-M rollup load test | partial | Synth seed at `tool/rollups_load_test/synth_seed.dart` + focused test landed; perf-gate execution still owed for `cutover.0b` launch blocker |
| B39 recovery code attempt-store refactor | complete | `lib/infrastructure/persistence/postgres/repositories/user_scoped_repository.dart` base class; `RecoveryCodeAttemptStore` migrated |
| B40 `202604280013` hotfix cross-link | complete | Cross-linked in `docs/contracts/audit_attribution_contract.md:19` |
| B41 service-principal issuance route | local complete; live apply pending | Route/client/tests landed; apply `202604290000` to staging + Production1 before live Phase 12 dependence |
| B42 proxy `/health` expansion | complete | Contract/code/tests landed; B44/B45/B47 now fill reserved metric values |
| B43 Cloud Run audit anchor deploy | staging deployed (lock deferred); production owed | Binary at `tool/audit_anchor/main.dart`; live `AzureBlobAuditAnchorBlobClient` (WIF, REST-direct) at `tool/audit_anchor/azure_blob_client.dart`; image build at `tool/audit_anchor/Dockerfile` + `cloudbuild.yaml`; deploy script `scripts/deploy_audit_anchor_job.ps1` (now with `-SecretPrefix`, `-VpcConnector`, `-VpcEgress`); deploy + verification runbook `runbooks/audit_anchor_cloudrun_deploy_runbook.md`. Staging live (2026-05-01): Cloud Run Job `forge-flow-audit-anchor` (project `forge-flow-staging`, image `audit-anchor:7f95227`, VPC connector `ff-staging-proxy-egress` → static IP `34.130.85.86`); Cloud Scheduler `forge-flow-audit-anchor-daily` (`northeast1`, `55 23 * * *` UTC, **PAUSED**); Azure container `audit-chain-anchors-immutable` on `forgeflowstaging1` **EMPTY + UNLOCKED**; AD app `forge-flow-audit-anchor-staging` + federated credential + container-scoped RBAC. Manual sweep `forge-flow-audit-anchor-lxqgm` exit 0 (1 operator resolved, no eligible chains). 7-year immutability lock **intentionally deferred** until real staging audit_logs accumulate AND a verified anchor (DB row + blob) lands; conditions + procedure in the runbook's "Current staging state" section. Production target still owed (no production GCP project; production VPC/NAT/firewall pattern deferred to its own slice — see `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` "Dev UX prerequisite — cross-cloud egress" for the reusable pattern). |
| B44 graph health metrics and rebuild runbook | complete | Producer registry + graph producer tests landed; 11A.5 surface still owns UX |
| B45 rollup worker/freshness UI integration | producer wiring landed; route/UI pending | `rollup_producers.dart` + tests landed; 11A.5/11A.6 own UX/live evidence |
| B46 advisor conversation encryption/audit privacy | local complete; live apply pending | Apply `202604280014` to staging + Production1 before live 11b writes |
| B47 vector health + filtered-search benchmark | producer wiring landed; live benchmark evidence pending | `vector_producers.dart` + tests landed; 11A.5/11A.6 own UX/live evidence |
| B48 password reset email-link parity | local complete; live apply pending | The email-link reset path now posts to proxy route `POST /v1/auth/password/reset/confirm` instead of calling Firebase `confirmPasswordReset` directly. The route resolves `oobCode` to email/user, runs `PasswordChangeService.evaluate` server-side, enforces HIBP and last-5 history reuse checks, completes Firebase reset only after policy acceptance, writes `password_history`, and audits the reset. The Firebase action page reads `proxyBaseUri` from `web/firebase-config.js` so the reset confirm request reaches the proxy host instead of Firebase Hosting. Live deploy of the updated proxy/web action page remains the cutover requirement. |
| B49 MFA production hardening | local complete; live apply pending | `9.UX.1a` now moves 24-hour MFA removal completion to a backend worker, keeps self/admin removal on delayed initiation, lets users/admins cancel pending removal requests during the delay window, avoids storing raw ID tokens as step-up proof, requires fresh admin auth for team reset, rate-limits public MFA help requests, removes recovery-code display and challenge entry from the app UX, repairs Firebase-only self factors before delayed removal, and fixes help-request copy so it does not promise email delivery. Mandatory admin-tier MFA enforcement remains deferred until post-launch stability and approval. Phone/SMS MFA remains out of scope and killed for this launch track. |
| B50 auth notification delivery bridge | queued with Phase 10a unless 9.UX copy promises delivery | MFA recovery-request and factor-removed notifications should use the durable `event_outbox` bridge. Current 9.UX.1a code only queues event rows; true in-app/email notification delivery is not a background pipeline yet. If the 9.UX surface says "notification will be sent", Phase 10a must provide the provider/worker path and acceptance proof. Until then, user-facing copy must say the request was recorded or tell the user to contact the restaurant admin directly, not promise an email. |

## UX Hand-Off Notes

The B-items above land **backend** capability. Operator-facing UX that
surfaces these capabilities is tracked under the `9.UX.0-7` family plus
the `9.UX.1a` hardening sub-slice in
`phase_9_auth_plan.md` `Frontend Exposure` section. Mapping:

- B17 role catalog CRUD â†’ `9.UX.2` (custom role editor, role catalog viewer)
- B27 audit hash chain + B37 verifier â†’ `9.UX.6` (personal audit log viewer)
- B48 password reset email-link parity â†’ `9.UX.7`
- B49 MFA production hardening â†’ `9.UX.1a`
- B50 auth notification delivery bridge â†’ Phase 10a bridge plus `9.UX.1a`
  copy gate
- B41 service-principal JWT issuance â†’ no operator UX (admin-only;
  surfaces in `11A.7-10` audit log review)
- B42 / B44 / B45 / B47 health producers â†’ no operator UX (surface in
  `11A.5` health dashboard)
- B46 advisor conversation encryption â†’ operator UX lands with `11b`
  Coach Chatbot, gated by audit-privacy permission

Do not block a B-item's status on its consumer UX slice; the B-items are
backend acceptance, the `9.UX.<n>` slices are frontend acceptance, and
both ladders close before Phase 9 fully retires.

## Operating Rules

- Future Production1 mutations require a fresh live-mutation gate and explicit
  approval, even though the 2026-04-29 apply completed cleanly.
- Keep Cloud Armor enforcement separate from database apply/deploy work.
- Do not paste secrets, DSNs, tokens, recovery codes, or device identifiers into
  docs or chat.
- Keep archived docs historical. Update this live backlog and `PROJECT_TRACKER.md`
  when status changes.
