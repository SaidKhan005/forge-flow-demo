# Phase 9 Execution Backlog

Updated: 2026-05-07.

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
  implemented, contracted, tested, and applied to staging + Production1 as of
  the 2026-05-03 Production1 second batch.
- B44/B45/B47 helper, runbook, and metric producer wiring now exist; `11A.5`
  Debug Console and `11A.6` observability dashboard are both accepted, with
  live producer evidence the remaining open follow-up.
- Latest local baseline: `flutter analyze --fatal-infos`,
  `dart run tool/rls_policy_lint.dart`, focused B17 auth/proxy tests,
  `git diff --check`, and full `flutter test --reporter compact` passed
  (`2544/2544`).

Do not re-open stale findings unless the repo regresses:

- Tenant-leading auth indexes already lead with `operator_id`.
- Phase 9 auth-table RLS/grants are live on staging and Production1.
- Azure extension and preload requirements are captured in setup/runbook docs.
- The first and second Production1 migration apply batches are no longer
  queued. Production1 is current through `202605021900`. The
  `202605031430` Debug Console request-log grant is applied/verified on
  staging and pending Production1; use the same runbook/drift scanner pattern
  for that follow-up, and do not mark the Production1 Debug Console
  request-log path ready until the grant is directly verified there. Staging
  live-admin E2E on 2026-05-04 also applied and verified
  `202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql` for
  operator/location admin writes; those writes stay staging-ready only until
  the grant is applied and verified on Production1. The mobile push branch adds
  `202605060000_mobile_push_notifications.sql` for encrypted FCM/APNs token
  storage and push sidecar delivery state; that migration remains queued for
  staging apply, connected-device proof, and later Production1 approval. The Business Timing Live slice adds
  `202605060000_phase_business_timing_live_schema.sql`; apply and verify it on
  staging/review before claiming live business timing schema parity, then carry
  it into the next Production1 batch. Phase 11A.14 adds
  `202605061100_phase_11A_14_admin_users_reset_mfa_factors_key.sql` (additive
  permission-key catalog row + default grants for `super_admin`/`ff_support`);
  apply on staging before exercising the Reset-MFA admin path live, then carry
  into the next Production1 batch. The 2026-05-06 audit follow-up adds
  `202605061500_hardening_phase_8_email_index_leading_column_rekey.sql`
  (CONCURRENTLY-rekeys five Phase 8 / Phase 9.8 fact-table indexes to lead with
  `operator_id`, preserving UNIQUE constraints + WHERE clauses) and
  `202605061600_phase_11W_5_team_audit_log_export_key.sql` (seeds the
  `team.audit_log.export` permission key + default grants for
  `operator_owner`/`operator_admin` so the 11W.5 audit-log export gate has
  catalog parity); apply both on staging before claiming index hygiene parity
  or live audit-log export readiness, then carry into the next Production1
  batch. The Hardening Wave B3 audit-anchor cron follow-up (punchlist §5) adds
  `202605061700_hardening_audit_anchor_daily_schedule.sql` (additive pg_cron
  schedule registration for `forge_audit_anchor_daily` at `0 2 * * *` UTC; the
  kickoff function `public.audit_anchor_run_daily()` is NOTIFY-only on channel
  `audit_anchor_tick` and does NOT perform the anchor work — the Cloud Run
  binary at `tool/audit_anchor/main.dart` remains the production executor;
  replay-safe via unschedule-then-reschedule and NOTICE-and-return guarded for
  the Azure pg_cron split-DB topology); apply on staging before claiming
  daily-cadence-from-Postgres observability parity, then carry into the next
  Production1 batch. Phase 8 timing provenance also queues
  `202605061700_phase_8_timing_provenance_shift_records.sql` for nullable
  closed `shift_records` timing keys plus the live snapshot version key.
  Hardening Wave B1 queues
  `202605061701_phase_8_data_accuracy_service_period_settings.sql`, an
  additive keyed child table per
  `(operator_id, location_id, service_period_key, effective_at_business_date)`
  that replaces the hardcoded `covers_source_lunch`/`_dinner`/`_late_night`
  columns on `public.data_accuracy_settings` (legacy columns retained as a
  read-only fallback until every read path migrates). Originally added under
  the `202605061700_…` basename (commit `4655b484`); renumbered on
  2026-05-06 to break the same-second prefix collision with the audit-anchor
  + timing-provenance migrations. Phase 8 mobile core then queues
  `202605061800_phase_8_first_connection_backfill_jobs.sql`, the additive
  operator-scoped durable first-connection backfill job table that later
  connect/worker/status lanes consume. Phase 11W.7 / Wave A2 then queues
  `202605070000_phase_11W_7_operator_account_fields.sql`, which adds the
  editable business-identity columns the operator-web `PATCH
  /v1/operator/account` route writes (`logo_url`, `locale_tag`,
  `week_start_day`, `rollover_hour`) plus format CHECK constraints and a
  length CHECK on `business_name`. Additive + default-backed; RLS on
  `public.operators` is unchanged. Code Health M2 then queues
  `202605070100_password_history_salt_pepper.sql` for the salted/peppered
  password-history schema seam, and Code Health M3 queues
  `202605070200_audit_anchor_advisory_lock_infra.sql` for audit-anchor
  advisory-lock and Blob breadcrumb infrastructure. Phase 8 timing-provenance
  FK posture then queues
  `202605080000_phase_8_timing_provenance_fk_posture.sql`, preserving closed
  historical timing truth under profile deletion. Code Health M1 queues
  `202605080100_admin_idempotency_expires_at.sql` for admin idempotency TTL
  cleanup. Phase 8 weekly-plan server truth then queues
  `202605080100_phase_8_weekly_plan_server_truth.sql` for server-owned
  forecast contexts and weekly plan snapshots. Phase 8 wage-role row server
  truth then queues
  `202605080200_phase_8_wage_role_rows_server_truth.sql` for the
  server-owned wage mix / role-job-code mapping table that mobile mirrors as
  cache. Phase 8 data-accuracy walk-in settings then queues
  `202605080300_phase_8_data_accuracy_walk_in_settings.sql` for server-owned
  reservation-demand walk-in handling fields that mobile mirrors as cache.
  Phase 8 connector OAuth state then queues
  `202605080400_phase_8_connector_oauth_state.sql` for tenant-scoped
  operator-facing vendor OAuth begin/callback state.
  A1 idempotency rekey then queues
  `202605080600_phase_8_idempotency_location_id_rekey.sql` to add
  `location_id` to the fact/webhook idempotency keys and switch all 17
  vendor sinks to a DO UPDATE WHERE `vendor_modified_at >=` guard. The
  follow-up queue now continues through
  `202605142100_phase_R_1L_roles_schema_rewrite.sql`, including permission-cache,
  webhook-secret, demo-counter, audit-anchor, auth-version,
  OAuth-refresh-lock, outbox NOTIFY split hardening, cron maintenance,
  KMS flag seeding, PII erasure, retention sweep, and admin hierarchy
  lifecycle/scoped settings, lifecycle access hardening, audit-log
  actor/reason/business-date gates, the Lane B B11.1 mobile→web
  redemption-code handoff (operator-scoped, 60s TTL, RLS via the
  `app_current_operator()` wrapper — replaces the legacy
  decision-#5 JWT-in-URL handoff per addendum A1), and the Lane B
  B11.2 RFC 9470 step-up challenge ledger (operator-scoped, 5-minute
  TTL, route+user-bound replay protection — emits 401 +
  `WWW-Authenticate: Bearer error="insufficient_user_authentication"`
  on sensitive proxy routes when caller's `auth_time` is stale), and
  the Lane B B10.1 vendor applicability table (global defaults plus
  operator overrides for wage/covers/polling vendor settings, RLS via
  `app_current_operator()`), and the Lane B B2.1 Default Role catalog
  versions table (global F&F-wide catalog with the
  `operators.default_role_catalog_version_id` pointer; admin-pool
  BYPASSRLS posture, no RLS), and the Lane C C-1a `email_event`
  prep migration (adds `provider_event_id text` plus a partial
  UNIQUE INDEX `WHERE provider_event_id IS NOT NULL` so the C-1
  SendGrid Event Webhook receiver can rely on Postgres-enforced
  dedupe via `ON CONFLICT (provider_event_id) DO NOTHING`; pure
  additive expand, no RLS change), and the Lane C C-7a `mfa_factors`
  prep migration (adds `recovery_codes_viewed_at timestamptz NULL` so
  Codex's C-7 Adaptive 2FA button can compute its label from
  `(session.mfaEnrolled, factor_count, recovery_codes_viewed_at)`;
  pure additive expand, no RLS change, no new index).
  Apply on staging first, then carry into the next Production1 batch.
  The current Production1 follow-up cutoff is therefore
  `202605150200_phase_u_fu_hp11_account_per_location_overrides.sql`,
  which is the Wave 2 U-FU-hp11-account per-location override schema
  for the three AccountScreen settings (region, business-day rollover,
  identity contact email + phone). Adds `public.location_account_overrides`
  keyed by `(operator_id, location_id)` with NULL columns inheriting
  the business defaults from `public.operators`. RLS via
  `app_current_operator()` wrapper + operator-leading B-tree index per
  HP #4; reuses the existing operator_owner / operator_admin role
  gate (no new permission key). Prior cutoff
  `202605150100_phase_r_followup_not_null_flip.sql` is the
  Wave 2 R-1L-FU + R-2L-FU contract migration: flips
  `permission_keys.product_label` + `category_label` + `scope_kind` +
  `human_label` from NULLABLE to NOT NULL after R-1L + R-2L inline
  backfills hydrated every row, and re-asserts `implies text[]`
  default + NOT NULL. Defensive pre-flight DO block raises with the
  offending row count if any of the five columns is still NULL before
  the flip (never silently tightens). Prior cutoff
  `202605150000_phase_r2l_default_role_catalog_v2.sql` is the Wave 2
  R-2L Default Role Catalog v2 redesign (adds
  `permission_keys.human_label` NULLABLE with inline backfill, seeds
  7 v2 role rows + Owner v2 wording, auto-migrates v1 user_roles,
  soft-deletes v1 retired roles); prior cutoff
  `202605142100_phase_R_1L_roles_schema_rewrite.sql` is the Wave 2
  R-1L Roles schema rewrite (`permission_keys.product_label` +
  `category_label` + `scope_kind` + `implies` columns, NULLABLE with
  inline backfill). Prior cutoff
  `202605140000_w_3_self_profile_perm_key.sql` adds the Wave 2 W-3
  `team.users.self_update` permission key + baseline grants backing
  the new `PATCH /v1/auth/self/profile` self-service profile editor on
  the operator-web and admin My Account surfaces.

  Lane C C-2-D (`202605131900_c_2_d_vendor_sync_outage_state.sql`)
  adds the per-(operator_id, location_id, connection_id) state surface
  for the first-failure-of-outage detector that gates the
  `vendor_sync_error_alert` email. One row per outage window;
  cleared (deleted) on the next `poll_success` for the same
  connection. Per-tenant RLS mirroring `connector_sync_log`; the
  detector lives at
  `lib/services/vendor_sync/vendor_sync_outage_detector.dart` with
  a Postgres-backed repository at
  `lib/infrastructure/persistence/postgres/repositories/vendor_sync_outage_state_repository.dart`.
  Pure additive expand; no existing table is mutated.

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
| B36 cross-tenant RLS isolation integration sweep | complete | `test/phase_9_0sigma_rls_isolation_sweep_test.dart` ? passive-by-default 13-table sweep gated on `FORGE_FLOW_RUN_STAGING_RLS_SWEEP=true` |
| B37 audit hash-chain verifier E2E test | complete | `test/phase_9_0sigma_f_audit_chain_e2e_test.dart` ? 100 rows ? 3 ops ? 2 dates; `tool/audit_anchor/test/anchor_e2e_test.dart` covers anchor surface |
| B38 Tier-M rollup load test | partial | Synth seed at `tool/rollups_load_test/synth_seed.dart` + focused test landed; perf-gate execution still owed for `cutover.0b` launch blocker |
| B39 recovery code attempt-store refactor | complete | `lib/infrastructure/persistence/postgres/repositories/user_scoped_repository.dart` base class; `RecoveryCodeAttemptStore` migrated |
| B40 `202604280013` hotfix cross-link | complete | Cross-linked in `docs/contracts/audit_attribution_contract.md:19` |
| B41 service-principal issuance route | local complete; live schema applied | Route/client/tests landed; `202604290000` applied to staging + Production1 in the 2026-05-03 second batch. Runtime/live issuance evidence remains for Phase 12. |
| B42 proxy `/health` expansion | complete | Contract/code/tests landed; B44/B45/B47 now fill reserved metric values |
| B43 Cloud Run audit anchor deploy | staging deployed (lock deferred); production owed | Binary at `tool/audit_anchor/main.dart`; live `AzureBlobAuditAnchorBlobClient` (WIF, REST-direct) at `tool/audit_anchor/azure_blob_client.dart`; image build at `tool/audit_anchor/Dockerfile` + `cloudbuild.yaml`; deploy script `scripts/deploy_audit_anchor_job.ps1` (now with `-SecretPrefix`, `-VpcConnector`, `-VpcEgress`); deploy + verification runbook `runbooks/audit_anchor_cloudrun_deploy_runbook.md`. Staging live (2026-05-01): Cloud Run Job `forge-flow-audit-anchor` (project `forge-flow-staging`, image `audit-anchor:7f95227`, VPC connector `ff-staging-proxy-egress` → static IP `34.130.85.86`); Cloud Scheduler `forge-flow-audit-anchor-daily` (`northeast1`, `55 23 * * *` UTC, **PAUSED**); Azure container `audit-chain-anchors-immutable` on `forgeflowstaging1` **EMPTY + UNLOCKED**; AD app `forge-flow-audit-anchor-staging` + federated credential + container-scoped RBAC. Manual sweep `forge-flow-audit-anchor-lxqgm` exit 0 (1 operator resolved, no eligible chains). 7-year immutability lock **intentionally deferred** until real staging audit_logs accumulate AND a verified anchor (DB row + blob) lands; conditions + procedure in the runbook's "Current staging state" section. Production target still owed (no production GCP project; production VPC/NAT/firewall pattern deferred to its own slice — see `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` "Dev UX prerequisite — cross-cloud egress" for the reusable pattern). |
| B44 graph health metrics and rebuild runbook | complete | Producer registry + graph producer tests landed; `11A.5` Debug Console + `11A.6` observability dashboard both accepted; live producer evidence remains |
| B45 rollup worker/freshness UI integration | producer wiring landed; `11A.6` UI accepted; live evidence pending | `rollup_producers.dart` + tests landed; live evidence remains |
| B46 advisor conversation encryption/audit privacy | local complete; live schema applied | `202604280014` applied to staging + Production1 in the 2026-05-03 second batch; live 11b writes still wait on runtime/cutover gates. |
| B47 vector health + filtered-search benchmark | producer wiring landed; live benchmark evidence pending | `vector_producers.dart` + tests landed; `11A.6` dashboard accepted; live benchmark evidence remains |
| B48 password reset email-link parity | local complete; live apply pending | The email-link reset path now posts to proxy route `POST /v1/auth/password/reset/confirm` instead of calling Firebase `confirmPasswordReset` directly. The route resolves `oobCode` to email/user, runs `PasswordChangeService.evaluate` server-side, enforces HIBP and last-5 history reuse checks, completes Firebase reset only after policy acceptance, writes `password_history`, and audits the reset. The Firebase action page reads `proxyBaseUri` from `web/firebase-config.js` so the reset confirm request reaches the proxy host instead of Firebase Hosting. Live deploy of the updated proxy/web action page remains the cutover requirement. |
| B49 MFA production hardening | local complete; DB schema applied; runtime/worker deploy pending | `9.UX.1a` now moves 24-hour MFA removal completion to a backend worker, keeps self/admin removal on delayed initiation, lets users/admins cancel pending removal requests during the delay window, avoids storing raw ID tokens as step-up proof, requires fresh admin auth for team reset, rate-limits public MFA help requests, removes recovery-code display and challenge entry from the app UX, repairs Firebase-only self factors before delayed removal, and fixes help-request copy so it does not promise email delivery. DB tables/grants applied to staging + Production1 in the 2026-05-03 second batch. Mandatory admin-tier MFA enforcement remains deferred until post-launch stability and approval. Phone/SMS MFA remains out of scope and killed for this launch track. |
| B50 auth notification delivery bridge | queued with Phase 10a unless 9.UX copy promises delivery | MFA recovery-request and factor-removed notifications should use the durable `event_outbox` bridge. Current 9.UX.1a code only queues event rows; true in-app/email notification delivery is not a background pipeline yet. If the 9.UX surface says "notification will be sent", Phase 10a must provide the provider/worker path and acceptance proof. Until then, user-facing copy must say the request was recorded or tell the user to contact the restaurant admin directly, not promise an email. |

## UX Hand-Off Notes

The B-items above land **backend** capability. Operator-facing UX that
surfaces these capabilities is tracked under the `9.UX.0-7` family plus
the `9.UX.1a` hardening sub-slice in
`phase_9_auth_plan.md` `Frontend Exposure` section. Mapping:

- B17 role catalog CRUD ? `9.UX.2` (custom role editor, role catalog viewer)
- B27 audit hash chain + B37 verifier ? `9.UX.6` (personal audit log viewer)
- B48 password reset email-link parity ? `9.UX.7`
- B49 MFA production hardening ? `9.UX.1a`
- B50 auth notification delivery bridge ? Phase 10a bridge plus `9.UX.1a`
  copy gate
- B41 service-principal JWT issuance ? no operator UX (admin-only;
  surfaces in `11A.7-10` audit log review)
- B42 / B44 / B45 / B47 health producers ? no operator UX (surface in
  `11A.6` observability dashboard; `11A.5` is the per-operator Debug Console
  request-log surface)
- B46 advisor conversation encryption ? operator UX lands with `11b`
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
