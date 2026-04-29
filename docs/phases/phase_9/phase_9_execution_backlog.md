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
- B44/B45/B47 helper and runbook work exists, but the metric producer wiring
  that fills the B42 reserved values remains follow-on work.
- Latest local baseline: `flutter analyze --fatal-infos`,
  `dart run tool/rls_policy_lint.dart`, focused B17 auth/proxy tests,
  `git diff --check`, and full `flutter test --reporter compact` passed
  (`2544/2544`).

Do not re-open stale findings unless the repo regresses:

- Tenant-leading auth indexes already lead with `operator_id`.
- Phase 9 auth-table RLS/grants are live on staging and Production1.
- Azure extension and preload requirements are captured in setup/runbook docs.
- The Production1 migration apply is no longer queued.

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
| B33 usage/log reconciliation hardening | queued | Rollup/accounting hardening |
| B34 audit attribution contract clarification | queued | Audit contract polish |
| B36 cross-tenant RLS isolation integration sweep | queued | Post-apply regression hardening |
| B37 audit hash-chain verifier E2E test | queued | Audit verification hardening |
| B38 Tier-M rollup load test | queued | `cutover.0b` launch blocker |
| B39 recovery code attempt-store refactor | queued | Code hygiene |
| B40 `202604280013` hotfix cross-link | queued | Docs polish |
| B41 service-principal issuance route | local complete; live apply pending | Route/client/tests landed; apply `202604290000` to staging + Production1 before live Phase 12 dependence |
| B42 proxy `/health` expansion | complete | Contract/code/tests landed; B44/B45/B47 fill reserved metric values |
| B43 Cloud Run audit anchor deploy | queued | Audit operations |
| B44 graph health metrics and rebuild runbook | helper/runbook landed; producer wiring pending | 11A.5 health surface |
| B45 rollup worker/freshness UI integration | freshness helper/runbook landed; route/UI pending | Rollup operations |
| B46 advisor conversation encryption/audit privacy | local complete; live apply pending | Apply `202604280014` to staging + Production1 before live 11b writes |
| B47 vector health + filtered-search benchmark | helper/benchmark artifact landed; producer wiring pending | 11A.5 vector health surface |

## Operating Rules

- Future Production1 mutations require a fresh live-mutation gate and explicit
  approval, even though the 2026-04-29 apply completed cleanly.
- Keep Cloud Armor enforcement separate from database apply/deploy work.
- Do not paste secrets, DSNs, tokens, recovery codes, or device identifiers into
  docs or chat.
- Keep archived docs historical. Update this live backlog and `PROJECT_TRACKER.md`
  when status changes.
