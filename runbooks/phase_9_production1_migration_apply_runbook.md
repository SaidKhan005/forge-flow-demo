# Phase 9 Production1 Migration Apply Runbook

Updated: 2026-05-13.

Purpose: govern and record Production1 migration applies. The second
migration batch covered 27 files spanning Phase 9 follow-ups, Phase 11A
advisor surfaces, and the HARD-B/HARD-F/HARD-H hardening pack through cutoff
`202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql`; it was
applied 2026-05-03. The current follow-up cutoff is
`202605150100_phase_r_followup_not_null_flip.sql`. This
runbook must be reviewed before any Production1 mutation. The first batch
(Phase 9.0 Sigma slices b-k plus auth/recovery patches) was applied
2026-04-29. See the Apply History section for results.

## Scope

Production1 target: `forge-flow-production1-pg-cmk` (Azure Flexible
Server, Canada Central, PG 16). The original
`forge-flow-production1-pg` server was deleted during `cutover.0a.pg`
and replaced by the CMK-enabled `-cmk` server on 2026-05-01.

In scope (27 migrations applied 2026-05-03, lex order):

- `db/migrations/202604280014_phase_9_0sigma_h2_audit_privacy_role.sql`
- `db/migrations/202604290000_phase_9_b41_service_principal_issue_permission.sql`
- `db/migrations/202604290100_phase_11A_1_operators_suspended_at.sql`
- `db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql`
- `db/migrations/202604300000_phase_9_mfa_factor_removal_requests.sql`
- `db/migrations/202604300001_phase_9_mfa_recovery_request_attempts.sql`
- `db/migrations/202604300002_phase_9_mfa_hardening_launch_roles.sql`
- `db/migrations/202605010000_phase_11A_3a_corpus_versions_ledger.sql`
- `db/migrations/202605010000_phase_11A_4_provider_credentials.sql`
- `db/migrations/202605010001_phase_9_b4_role_audit_log_operator_id.sql`
- `db/migrations/202605010100_phase_9_0sigma_f_audit_logs_cutover_flag.sql`
- `db/migrations/202605020000_phase_11A_b42_proxy_migrations_applied.sql`
- `db/migrations/202605020001_phase_11A_3b_graphify_review_audit.sql`
- `db/migrations/202605020001_phase_11A_4b_gemini_provider_kind.sql`
- `db/migrations/202605020100_phase_11A_b43_cache_telemetry_v2.sql`
- `db/migrations/202605020200_phase_11A_4c_kms_rollout_flags.sql`
- `db/migrations/202605020300_phase_9_firebase_uid_text.sql`
- `db/migrations/202605020400_phase_11A_7_feature_flags_admin_columns.sql`
- `db/migrations/202605020452_hardening_auth_login_attempts.sql`
- `db/migrations/202605020500_hardening_auth_rls_to_wrappers.sql`
- `db/migrations/202605021000_phase_hardh_admin_idempotency.sql`
- `db/migrations/202605021500_phase_9_0sigma_l_rls_depth.sql`
- `db/migrations/202605021600_phase_11A_7_feature_flags_forge_admin_grants.sql`
- `db/migrations/202605021700_phase_11A_health_age_graph_bootstrap.sql`
- `db/migrations/202605021710_phase_11A_health_age_runtime_grants.sql`
- `db/migrations/202605021800_hardening_auth_login_attempts_index_rekey.sql`
- `db/migrations/202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql`

Pending follow-up scope (49 migrations; staging status varies, Production1 pending):

- `db/migrations/202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql`
- `db/migrations/202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql`
- `db/migrations/202605060000_mobile_push_notifications.sql`
- `db/migrations/202605060000_phase_business_timing_live_schema.sql`
- `db/migrations/202605061100_phase_11A_14_admin_users_reset_mfa_factors_key.sql`
- `db/migrations/202605061500_hardening_phase_8_email_index_leading_column_rekey.sql`
- `db/migrations/202605061600_phase_11W_5_team_audit_log_export_key.sql`
- `db/migrations/202605061700_hardening_audit_anchor_daily_schedule.sql`
- `db/migrations/202605061700_phase_8_timing_provenance_shift_records.sql`
- `db/migrations/202605061701_phase_8_data_accuracy_service_period_settings.sql`
- `db/migrations/202605061800_phase_8_first_connection_backfill_jobs.sql`
- `db/migrations/202605070000_phase_11W_7_operator_account_fields.sql`
- `db/migrations/202605070100_password_history_salt_pepper.sql`
- `db/migrations/202605070200_audit_anchor_advisory_lock_infra.sql`
- `db/migrations/202605070400_phase_8_notification_preferences.sql`
- `db/migrations/202605080000_phase_8_timing_provenance_fk_posture.sql`
- `db/migrations/202605080100_admin_idempotency_expires_at.sql`
- `db/migrations/202605080100_phase_8_weekly_plan_server_truth.sql`
- `db/migrations/202605080200_phase_8_wage_role_rows_server_truth.sql`
- `db/migrations/202605080300_phase_8_data_accuracy_walk_in_settings.sql`
- `db/migrations/202605080400_phase_8_connector_oauth_state.sql`
- `db/migrations/202605080500_permission_cache_invalidation_channel.sql`
- `db/migrations/202605080600_ops_debt_vendor_credentials_webhook_signing_secret.sql`
- `db/migrations/202605080600_phase_8_demo_pending_counter_persisted.sql`
- `db/migrations/202605080600_phase_8_idempotency_location_id_rekey.sql`
- `db/migrations/202605080700_audit_anchor_cron_unpause.sql`
- `db/migrations/202605080800_auth_permission_version.sql`
- `db/migrations/202605080900_oauth_refresh_advisory_lock.sql`
- `db/migrations/202605081000_outbox_notify_channel_split.sql`
- `db/migrations/202605081100_partman_maintenance_hourly_cron.sql`
- `db/migrations/202605081300_seed_kms_rollout_flags_default_disabled.sql`
- `db/migrations/202605082000_user_pii_erasure_requests.sql`
- `db/migrations/202605082100_phase_10a_3_retention_sweep_in_db_followup.sql`
- `db/migrations/202605082200_admin_hierarchy_lifecycle.sql`
- `db/migrations/202605121200_admin_hierarchy_scoped_data_polling.sql`
- `db/migrations/202605131000_admin_audit_log_actor_reason_contract.sql`
- `db/migrations/202605131010_admin_audit_logs_business_date.sql`
- `db/migrations/202605131020_admin_hierarchy_lifecycle_access_hardening.sql`
- `db/migrations/202605131030_b11_1_auth_handoff_codes.sql`
- `db/migrations/202605131400_b11_2_auth_step_up_challenges.sql`
- `db/migrations/202605131500_b10_1_vendor_applicability.sql`
- `db/migrations/202605131500_b5_b_catalog_tri_mirror.sql`
- `db/migrations/202605131600_b2_1_default_role_catalog_versions.sql`
- `db/migrations/202605131700_c_1a_email_event_provider_id.sql`
- `db/migrations/202605131800_c_7a_recovery_codes_viewed_at.sql`
- `db/migrations/202605131900_c_2_d_vendor_sync_outage_state.sql`
- `db/migrations/202605140000_w_3_self_profile_perm_key.sql`
- `db/migrations/202605142100_phase_R_1L_roles_schema_rewrite.sql`
- `db/migrations/202605150000_phase_r2l_default_role_catalog_v2.sql`
- `db/migrations/202605150100_phase_r_followup_not_null_flip.sql`

Out of scope:

- Cloud Armor enforcement mutation.
- Production proxy deploy.
- Operator data import.
- Any migration outside the cutoff range above (anything with a lex prefix
  earlier than `202604280014` is already in production from the first batch;
  the pending follow-up migrations belong to the next follow-up batch;
  anything later than `202605150100_phase_r_followup_not_null_flip.sql`
  belongs to a future apply event and is gated by
  `tool/migration_cutoff_lint.dart`).

Current known post-cutoff staging additions:

- `db/migrations/202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql`
  restores read-only Debug Console request-log inspection for `forge_admin`.
  It is applied/verified on staging, was not part of the 27-file Production1
  apply, and belongs to the next Production1 migration batch unless superseded
  by later staging additions.
- `db/migrations/202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql`
  restores `forge_admin` DML for operator/location admin-console writes. It is
  applied/verified on staging from 2026-05-04 live-admin E2E evidence, was not
  part of the 27-file Production1 apply, and belongs to the next Production1
  migration batch unless superseded by later staging additions.
- `db/migrations/202605060000_mobile_push_notifications.sql` adds encrypted
  mobile FCM/APNs token storage plus the durable push delivery sidecar queue.
  It is code-ready in the mobile push branch and remains gated on staging
  apply, connected-device proof, and explicit Production1 approval before any
  production apply.
- `db/migrations/202605060000_phase_business_timing_live_schema.sql` adds
  business-timing profiles, audited service-period overrides, and server-side
  `open_shift_snapshots`. It requires staging/review apply before business
  timing runtime proof and then belongs in the next Production1 batch before
  production timing/live-shift claims.
- `db/migrations/202605061700_hardening_audit_anchor_daily_schedule.sql` adds
  the daily pg_cron tick `forge_audit_anchor_daily` at `0 2 * * *` UTC. The
  kickoff function `public.audit_anchor_run_daily()` is NOTIFY-only and does
  not perform anchor work; the Cloud Run binary at `tool/audit_anchor/main.dart`
  remains the production anchor executor. It is code-ready and remains
  staging/Production1 apply gated with the rest of the follow-up batch.
- `db/migrations/202605061700_phase_8_timing_provenance_shift_records.sql`
  adds the stable timing provenance columns for closed `shift_records` and the
  version key for `open_shift_snapshots`. It is code-ready and remains
  staging/Production1 apply gated with the rest of the follow-up batch.
- `db/migrations/202605061701_phase_8_data_accuracy_service_period_settings.sql`
  adds the keyed Hardening Wave B1 child table replacing the hardcoded
  `covers_source_lunch` / `_dinner` / `_late_night` columns on
  `public.data_accuracy_settings` with one row per
  `(operator_id, location_id, service_period_key, effective_at_business_date)`.
  Legacy columns remain as a read-only fallback until every read path migrates.
  It is code-ready and remains staging/Production1 apply gated with the rest
  of the follow-up batch. Originally added under the
  `202605061700_phase_8_data_accuracy_service_period_settings.sql` basename
  (commit `4655b484`); renumbered on 2026-05-06 to break the same-second
  prefix collision with the audit-anchor + timing-provenance migrations.
- `db/migrations/202605061800_phase_8_first_connection_backfill_jobs.sql`
  adds the additive, operator-scoped durable first-connection backfill job
  table. It is the server-side enqueue/claim/status seam for the bounded
  60-day mobile core backfill path. It is code-ready and remains
  staging/Production1 apply gated with the rest of the follow-up batch.
- `db/migrations/202605070000_phase_11W_7_operator_account_fields.sql`
  adds the editable business-identity columns the operator-web Account
  settings page (`PATCH /v1/operator/account`) writes: `logo_url`,
  `locale_tag`, `week_start_day`, `rollover_hour`, plus format CHECK
  constraints and a length CHECK on `business_name`. Additive +
  default-backed; existing rows preserved. RLS unchanged (operators is
  identity, already protected by per-operator policies). Code-ready and
  remains staging/Production1 apply gated with the rest of the follow-up
  batch.
- `db/migrations/202605070100_password_history_salt_pepper.sql`
  adds the schema seam for salted/peppered password-history hashes:
  nullable salt/pepper metadata, an algorithm discriminator, and the
  legacy-vs-salted invariant. It is code-ready and remains
  staging/Production1 apply gated with the rest of the follow-up batch.
- `db/migrations/202605070200_audit_anchor_advisory_lock_infra.sql`
  adds the global audit-anchor advisory-lock registry plus Blob breadcrumb
  columns on `public.audit_chain_anchors` so the daily anchor sweep can be
  serialized and crash-recovered by the follow-up code lane. It is
  code-ready and remains staging/Production1 apply gated with the rest of the
  follow-up batch.
- `db/migrations/202605080000_phase_8_timing_provenance_fk_posture.sql`
  flips the three Phase 8 timing-provenance foreign keys
  (`shift_records_business_timing_profile_fk`,
  `shift_records_business_timing_profile_version_fk`,
  `open_shift_snapshots_profile_version_fk`) from default `ON DELETE NO
  ACTION` to `ON DELETE SET NULL NOT VALID` so closed historical truth
  outlives `business_timing_profiles` deletion (the
  `core_app_architecture.md` "What never rewrites" non-negotiable matched
  to the Operator Web timing editor lifecycle). Drops + re-adds via name
  guards in a single transaction; no index, check, or column changes. Stays
  `NOT VALID` (validation deferred to a future maintenance window). Apply
  on staging first; carry into the next Production1 batch.
- `db/migrations/202605080100_admin_idempotency_expires_at.sql`
  adds `expires_at` to `public.admin_request_idempotency`, a partial
  in-flight expiry index, and the `admin_idempotency_sweep` pg_cron job so
  orphaned admin idempotency reservations are bounded. It is code-ready and
  remains staging/Production1 apply gated with the rest of the follow-up
  batch.
- `db/migrations/202605080100_phase_8_weekly_plan_server_truth.sql`
  adds server-owned forecast contexts, weekly plan snapshots, snapshot day
  rows, and the weekly-plan audit ledger for the Doc 1 mobile core contract.
  Mobile remains a cache/read model: no mobile table becomes the source of
  truth. Code-ready and remains staging/Production1 apply gated with the rest
  of the follow-up batch.
- `db/migrations/202605080200_phase_8_wage_role_rows_server_truth.sql`
  adds the server-owned wage-role row table for operator/admin-owned
  role/rate/job-code mapping. Mobile mirrors it as cache/read model input
  for wage-source calculations; the server remains the write authority.
  Code-ready and remains staging/Production1 apply gated with the rest of
  the follow-up batch.
- `db/migrations/202605080300_phase_8_data_accuracy_walk_in_settings.sql`
  adds durable walk-in handling mode and sparse walk-in count entries to
  `public.data_accuracy_settings`. Mobile reads these reservation-demand
  settings from the proxy as cache/read model input; server/admin/operator
  paths remain the write authority. Code-ready and remains
  staging/Production1 apply gated with the rest of the follow-up batch.

Migration drift automation:

- After any slice lands a new `db/migrations/*.sql` file, run
  `dart run tool/migration_drift_scanner.dart --fix --strict-docs`.
- The scanner updates the staging setup cutoff between the sentinel markers,
  writes `build/reports/migration_drift_report.md`, and flags watched
  authority docs whose queue/count wording still needs a manual refresh.

## Live-Mutation Gate

Before running any apply:

- [ ] Confirm this runbook was reviewed in the current session.
- [ ] Confirm the exact Production1 hostname/database target by name only.
- [ ] Confirm the operator approving the apply; while production setup is
      paused, do not run the apply unless the operator explicitly says
      "begin execution".
- [ ] Confirm a fresh backup or restore point exists.
- [ ] Confirm staging has already applied the same file set successfully.
- [ ] Confirm `flutter analyze --fatal-infos`, focused auth/proxy tests, and
      RLS lint are green on the applying commit.
- [ ] Confirm no secrets, DSNs, tokens, or passwords will be pasted into chat
      or docs.

Stop with `BLOCKED` if any item is missing.

## Apply Order

Run in this exact lex order:

1. `202604280014_phase_9_0sigma_h2_audit_privacy_role.sql`
2. `202604290000_phase_9_b41_service_principal_issue_permission.sql`
3. `202604290100_phase_11A_1_operators_suspended_at.sql`
4. `202604290101_phase_9_hierarchy_access_wiring.sql`
5. `202604300000_phase_9_mfa_factor_removal_requests.sql`
6. `202604300001_phase_9_mfa_recovery_request_attempts.sql`
7. `202604300002_phase_9_mfa_hardening_launch_roles.sql`
8. `202605010000_phase_11A_3a_corpus_versions_ledger.sql`
9. `202605010000_phase_11A_4_provider_credentials.sql`
10. `202605010001_phase_9_b4_role_audit_log_operator_id.sql`
11. `202605010100_phase_9_0sigma_f_audit_logs_cutover_flag.sql`
12. `202605020000_phase_11A_b42_proxy_migrations_applied.sql`
13. `202605020001_phase_11A_3b_graphify_review_audit.sql`
14. `202605020001_phase_11A_4b_gemini_provider_kind.sql`
15. `202605020100_phase_11A_b43_cache_telemetry_v2.sql`
16. `202605020200_phase_11A_4c_kms_rollout_flags.sql`
17. `202605020300_phase_9_firebase_uid_text.sql`
18. `202605020400_phase_11A_7_feature_flags_admin_columns.sql`
19. `202605020452_hardening_auth_login_attempts.sql`
20. `202605020500_hardening_auth_rls_to_wrappers.sql`
21. `202605021000_phase_hardh_admin_idempotency.sql`
22. `202605021500_phase_9_0sigma_l_rls_depth.sql`
23. `202605021600_phase_11A_7_feature_flags_forge_admin_grants.sql`
24. `202605021700_phase_11A_health_age_graph_bootstrap.sql`
25. `202605021710_phase_11A_health_age_runtime_grants.sql`
26. `202605021800_hardening_auth_login_attempts_index_rekey.sql`
27. `202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql`

Current pending follow-up order:

1. `202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql`
2. `202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql`
3. `202605060000_mobile_push_notifications.sql`
4. `202605060000_phase_business_timing_live_schema.sql`
5. `202605061100_phase_11A_14_admin_users_reset_mfa_factors_key.sql`
6. `202605061500_hardening_phase_8_email_index_leading_column_rekey.sql`
7. `202605061600_phase_11W_5_team_audit_log_export_key.sql`
8. `202605061700_hardening_audit_anchor_daily_schedule.sql`
9. `202605061700_phase_8_timing_provenance_shift_records.sql`
10. `202605061701_phase_8_data_accuracy_service_period_settings.sql`
11. `202605061800_phase_8_first_connection_backfill_jobs.sql`
12. `202605070000_phase_11W_7_operator_account_fields.sql`
13. `202605070100_password_history_salt_pepper.sql`
14. `202605070200_audit_anchor_advisory_lock_infra.sql`
15. `202605080000_phase_8_timing_provenance_fk_posture.sql`
16. `202605080100_admin_idempotency_expires_at.sql`
17. `202605080100_phase_8_weekly_plan_server_truth.sql`
18. `202605080200_phase_8_wage_role_rows_server_truth.sql`
19. `202605080300_phase_8_data_accuracy_walk_in_settings.sql`

Dependency notes:

- All 27 files are additive on the prior baseline (slices b–k plus auth /
  recovery patches). Re-running any file after a partial failure is safe;
  every `create table` / `create index` uses `if not exists`, every
  `alter table` is idempotent on the second pass.
- Two same-timestamp pairs need strict lex ordering: `...010000_…3a_corpus`
  must run before `...010000_…4_provider`, and `...020001_…3b_graphify`
  must run before `...020001_…4b_gemini`.
- `…4_provider_credentials` must run before `…4b_gemini_provider_kind` and
  `…4c_kms_rollout_flags`; both later files alter the `provider_credentials`
  table created by the first.
- `…0500_hardening_auth_rls_to_wrappers` depends on the wrapper functions
  installed by the first batch (`forge_*_uuid()` family) — Production1
  already has them from the 2026-04-29 apply.
- `…1500_phase_9_0sigma_l_rls_depth` re-asserts RLS on `proxy_requests` and
  `feature_flags` (created by `202604250005_advisor_cloud_foundation.sql`,
  already in production). It drops the permissive `*_service_role_all` stubs
  and adds wrapper-based per-tenant policies; the tenant-leading PK and the
  `(operator_id, location_id, idempotency_key)` UNIQUE on `proxy_requests`
  are unchanged from `202604250007_advisor_rls_index_hardening.sql`.
- `…0300_phase_9_firebase_uid_text` widens the auth `firebase_uid` column
  type; verify no in-flight writes from a stale schema cache before running.
- `…1000_phase_hardh_admin_idempotency` creates `admin_request_idempotency`
  (HARD-H). The L4 admin gateways already mint and forward
  `Idempotency-Key` headers; the proxy dedup helper engages once this table
  is in place.
- `…1600_phase_11A_7_feature_flags_forge_admin_grants` grants the
  `forge_admin` runtime role the explicit table privileges needed by
  feature-flag admin and startup checks.
- `…1430_phase_11A_5_debug_proxy_requests_forge_admin_grant` grants the
  `forge_admin` runtime role read-only access to `proxy_requests`; BYPASSRLS
  skips tenant row policies, but the Debug Console request-log gateway still
  needs explicit table privilege.
- `…1700_phase_11A_health_age_graph_bootstrap` ensures the canonical AGE graph
  namespace exists even before corpus projection has materialized vertices.
- `…1710_phase_11A_health_age_runtime_grants` grants `forge_admin` AGE schema,
  function, and graph-label read privileges so strict health probes can run.
- `…1800_hardening_auth_login_attempts_index_rekey` preserves the pre-tenant
  `(user_email_hash, ip_hash, attempted_at)` lockout index and rekeys the
  tenant-side IP-failure triage index to lead with `operator_id`.
- `…1900_phase_11A_3a_corpus_versions_seed_existing_chunks` creates exactly
  one baseline corpus version when the ledger is empty but active pre-11A.3a
  chunks already exist; it leaves empty environments and already-versioned
  ledgers unchanged.
- No `pg_cron` schedule changes in this batch; the existing
  `forge_rollup_hot_path` / `forge_rollup_cold_path` jobs from the prior
  batch continue unchanged.

## Pre-Apply Snapshot

Capture outputs to a local operator-held note, not chat:

```sql
select current_database(), current_user, now();

select schemaname, tablename, rowsecurity
from pg_tables
where schemaname = 'public'
order by tablename;

select table_name
from information_schema.tables
where table_schema = 'public'
order by table_name;

select relname as table_name, n_live_tup
from pg_stat_user_tables
order by relname;

select extname, extversion
from pg_extension
order by extname;
```

For operator-scoped tables, capture row counts grouped by `operator_id` where
the column exists.

## Verification Queries

Service principals and actor-kind repair:

```sql
select column_name, data_type
from information_schema.columns
where table_schema = 'public'
  and table_name in ('service_principals', 'auth_events_audit')
  and column_name in ('service_principal_id', 'actor_kind',
                      'actor_service_principal_id')
order by table_name, column_name;
```

Audit chain:

```sql
select to_regclass('public.audit_logs') as audit_logs_table;

select indexname
from pg_indexes
where schemaname = 'public'
  and tablename = 'audit_logs'
order by indexname;
```

Usage caps two-slot:

```sql
select column_name
from information_schema.columns
where table_schema = 'public'
  and table_name = 'usage_caps'
order by ordinal_position;
```

Advisor conversation log:

```sql
select column_name, data_type
from information_schema.columns
where table_schema = 'public'
  and table_name = 'advisor_conversation_log'
order by ordinal_position;
```

Graph canonical:

```sql
select to_regclass('public.graph_nodes') as graph_nodes,
       to_regclass('public.graph_edges') as graph_edges;
```

Vector extension:

```sql
select extname, extversion
from pg_extension
where extname in ('vector', 'diskann', 'pg_diskann')
order by extname;
```

Rollups and cron:

```sql
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name like 'rollup_%'
order by table_name;

select jobname, schedule, active
from cron.job
where jobname like 'forge_flow_%'
order by jobname;
```

Recovery attempts and grants:

```sql
select to_regclass('public.recovery_code_attempts') as recovery_code_attempts;

select grantee, table_name, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in (
    'auth_events_audit',
    'feature_flags',
    'proxy_requests',
    'recovery_code_attempts',
    'service_principals'
  )
order by table_name, grantee, privilege_type;
```

Debug Console request-log grant:

```sql
select to_regclass('public.proxy_requests') as proxy_requests;

select has_table_privilege(
  'forge_admin',
  'public.proxy_requests',
  'SELECT'
) as forge_admin_can_select_proxy_requests;

select grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name = 'proxy_requests'
  and grantee = 'forge_admin'
order by privilege_type;
```

AGE graph health bootstrap:

```sql
select extname
from pg_extension
where extname = 'age';

select name
from ag_catalog.ag_graph
where name = 'forgeflow';

select 'ag_catalog' as schema_name,
       has_schema_privilege('forge_admin', 'ag_catalog', 'USAGE') as has_usage
union all
select 'forgeflow' as schema_name,
       has_schema_privilege('forge_admin', 'forgeflow', 'USAGE') as has_usage;

select table_schema, table_name, privilege_type
from information_schema.role_table_grants
where grantee = 'forge_admin'
  and table_schema = 'forgeflow'
order by table_name, privilege_type;
```

RLS and tenant-leading discipline:

```sql
select schemaname, tablename, policyname, cmd, roles
from pg_policies
where schemaname = 'public'
  and tablename in (
    'audit_logs',
    'advisor_conversation_log',
    'event_outbox',
    'graph_edges',
    'graph_nodes',
    'service_principals'
  )
order by tablename, policyname;

select tablename, indexname, indexdef
from pg_indexes
where schemaname = 'public'
  and (
    indexdef like '%operator_id%'
    or tablename in ('audit_logs', 'advisor_conversation_log', 'event_outbox',
                     'graph_edges', 'graph_nodes', 'service_principals')
  )
order by tablename, indexname;
```

## Post-Apply Health Checks

- Negative-tenant read smoke: tenant A must not read tenant B rows on each new
  operator-scoped table.
- `forge_admin` BYPASSRLS smoke: emergency read path works and is named in the
  audit context.
- RLS lint:

```powershell
dart run tool/rls_policy_lint.dart
```

- Proxy readiness, if a production proxy is already deployed:

```powershell
# Name-only in chat; do not paste URL secrets.
# GET /readyz should return 200.
```

## Backout Notes

- Prefer restore point rollback for a failed multi-file apply.
- For additive tables/columns with no production writes yet, reverse by dropping
  the newly-created table/column only after confirming no dependent object or
  row exists.
- For `usage_caps` two-slot constraint flips, do not drop backfilled data.
  Revert the CHECK/constraint shape first, preserve rows, and document the
  downgraded uniqueness posture.
- For cron jobs, disable jobs before dropping rollup tables.
- For audit-chain tables, do not delete rows after writes begin; preserve the
  chain and create a follow-up repair migration instead.

## Cloud Armor Pairing

Cloud Armor enforcement is a separate gate. Before pairing enforcement with
Production1 apply or any launch-facing edge cutover:

- [ ] Review at least 3 clean days of post-tuning preview logs.
- [ ] Confirm false-positive risk is acceptable.
- [ ] Confirm `/readyz` and auth routes are not matched by preview-only WAF
      false positives.
- [ ] Obtain explicit approval for enforcement mutation.

Current staging note: `ff-staging-proxy-armor` remains preview-only. On
2026-04-29, B17 role CRUD smoke exposed false positives in the original SQLi
preview rule. The rule was tuned to sensitivity 2 with the B17 false-positive
SQLi signatures opted out. Post-tuning B17 CRUD had zero preview hits, while a
controlled SQLi probe still logged a preview signal. Do not flip enforcement
until the post-tuning monitor window is clean.

## Apply History

### 2026-04-29 — first batch (Phase 9.0 Sigma slices b–k + auth/recovery)

- Staging and Production1 applied the Phase 9.0 Sigma b-through-k slice set
  plus the recovery / auth-ops grants and the audit actor-kind live repair
  hotfix.
- Both servers were updated to allow-list `ltree` in `azure.extensions`.
- The 9.0 Sigma k pg_cron slice creates the rollup functions in
  `forgeflow`; rollup cron jobs are scheduled from the `postgres`
  maintenance database.
- Verified app-database objects: `org_units`, `event_outbox`,
  `service_principals`, `audit_logs`, `audit_chain_anchors`,
  `advisor_conversation_log`, graph tables, aggregation state, all seven rollup
  tables, `recovery_code_attempts`, usage two-slot columns/constraints, auth
  actor columns, wrapper functions, and required extensions.
- Verified cron jobs on staging and Production1:
  `forge_rollup_hot_path` every minute, `forge_rollup_cold_path` every five
  minutes, and the existing partman maintenance job.
- First observed `cron.job_run_details` entries for both rollup jobs succeeded
  on staging and Production1.
- No backout was needed. Local logs are under
  `build/phase_9_production1_apply/` and intentionally stay uncommitted.

### 2026-05-03 - second batch (Phase 9 + 11A + hardening)

- Staging prerequisite: direct schema sentinels initially found several batch
  effects missing even though `proxy_migrations_applied` had recorded the
  filenames. The exact 27-file batch was replayed on staging and direct
  sentinels then passed.
- Replay safety fix before Production1: the graphify review audit and
  auth-login-attempts migrations now drop existing policies before recreating
  them, matching the runbook's idempotency/backout promise for partial or
  replay applies.
- Production1 target: `forge-flow-production1-pg-cmk`, database `forgeflow`.
- Approval: operator instructed "Begin execution" on 2026-05-03.
- Backup posture: Azure automatic backups were present with 35-day retention;
  latest listed full backup was 2026-05-02T18:10:14Z.
- Local gates: `flutter analyze --fatal-infos`,
  `dart run tool/rls_policy_lint.dart`,
  `dart run tool/migration_cutoff_lint.dart`, focused auth/proxy/migration
  tests, and feature-flag admin screen tests passed after the replay-safety
  patch.
- Files applied: all 27 files in the Scope list, in order. The concurrent-index
  migration was applied without a global enclosing transaction.
- Production1 verification: table/column presence, RLS policies,
  tenant-leading indexes, AGE graph bootstrap/runtime grants, feature-flag
  grants, provider/corpus/admin idempotency tables, and auth lockout tables all
  passed direct sentinels.
- Production1 data posture after apply: `operators`, `users`,
  `advisor_source_chunks`, and `corpus_versions` all had zero rows. Negative
  tenant fixture smokes remain pending until a data-load gate creates fixtures.
- `proxy_migrations_applied` exists on Production1; rows remain empty until the
  first Production1 proxy startup records the runtime migration catalog.
- No backout was needed. Local logs are under
  `build/phase_9_production1_apply/2026-05-03_second_batch/` and intentionally
  stay uncommitted.

### Next follow-up - pending (cutoff `202605140000_w_3_self_profile_perm_key.sql`)

- `202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql` is
  applied and Browser Use verified on staging. Apply it to Production1 under
  the Live-Mutation Gate before calling Debug Console request-log inspection
  production-ready.
- `202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql` is
  applied and Browser Use verified on staging. Apply it to Production1 under
  the Live-Mutation Gate before calling operator/location admin writes
  production-ready.
- `202605060000_mobile_push_notifications.sql` is code-ready for mobile push
  token storage and durable push sidecar delivery state. Apply it to staging
  first, complete connected-device proof, then include it in Production1 only
  after explicit approval. After applying, set
  `MOBILE_PUSH_NOTIFICATIONS_ENABLED=true` on the proxy + ForgeFlow Cloud Run
  revisions and redeploy (mobile builds re-cut with
  `--dart-define=MOBILE_PUSH_NOTIFICATIONS_ENABLED=true`); until then
  `lib/services/auth/firebase_auth_runtime_bindings.dart` wires the
  `NoopMobilePushTokenGateway` so production phones never POST to
  `/v1/auth/mobile/push-token/register` against a missing
  `mobile_push_tokens` table.
- `202605060000_phase_business_timing_live_schema.sql` is queued by the
  Business Timing Live slice. Apply and verify it on staging before review
  runtime proof; then include it in the next Production1 apply batch before
  calling live business timing / open-shift snapshots production-ready.
- `202605061100_phase_11A_14_admin_users_reset_mfa_factors_key.sql` is the
  additive permission-key seed for `admin.users.reset_mfa_factors` plus default
  grants for `super_admin`/`ff_support`. Apply on staging before exercising the
  Reset-MFA admin path live; carry into the next Production1 apply.
- `202605061500_hardening_phase_8_email_index_leading_column_rekey.sql` rekeys
  five fact-table indexes (Phase 8 integration framework + Phase 9.8 email
  provider) to lead with `operator_id`. Uses `DROP INDEX CONCURRENTLY` /
  `CREATE INDEX CONCURRENTLY`; preserves UNIQUE constraints and partial WHERE
  clauses. Apply on staging first; carry into the next Production1 batch.
- `202605061600_phase_11W_5_team_audit_log_export_key.sql` seeds the new
  `team.audit_log.export` permission key plus default grants for
  `operator_owner`/`operator_admin` so the 11W.5 audit log export gate has
  catalog parity. Apply on staging first; carry into the next Production1 batch.
- `202605061700_hardening_audit_anchor_daily_schedule.sql` adds the daily
  pg_cron tick `forge_audit_anchor_daily` at `0 2 * * *` (02:00 UTC) so the
  audit-anchor cadence is observable from inside Postgres
  (`cron.job_run_details`) regardless of Cloud Scheduler state. The kickoff
  function `public.audit_anchor_run_daily()` is NOTIFY-only and does NOT
  perform anchor work; the Cloud Run binary at `tool/audit_anchor/main.dart`
  remains the production anchor executor. Replay-safe via
  unschedule-then-reschedule; NOTICE-and-return guard for the Azure split-DB
  case (schedule from `cron.database_name` with
  `cron.schedule_in_database(..., 'forgeflow')`). Apply on staging first; carry
  into the next Production1 batch.
- `202605061700_phase_8_timing_provenance_shift_records.sql` adds nullable
  timing provenance columns to closed `shift_records` and the live snapshot
  timing version key. Apply on staging first; carry into the next Production1
  batch with the rest of the follow-up migrations.
- `202605061701_phase_8_data_accuracy_service_period_settings.sql` adds the
  keyed Hardening Wave B1 child table for
  `(operator_id, location_id, service_period_key, effective_at_business_date)`
  Data Accuracy settings, replacing the hardcoded
  `covers_source_lunch`/`_dinner`/`_late_night` columns. RLS-enabled at table
  creation, wrapper-only policy body, tenant-leading B-tree indexes,
  `if not exists` everywhere so re-applies are no-ops. Originally added under
  the `202605061700_…` basename (commit `4655b484`); renumbered on 2026-05-06
  to break the same-second prefix collision with the audit-anchor +
  timing-provenance migrations. Apply on staging first; carry into the next
  Production1 batch with the rest of the follow-up migrations.
- `202605061800_phase_8_first_connection_backfill_jobs.sql` adds the
  operator-scoped durable first-connection backfill job table for the mobile
  core contract. It is the enqueue/claim/status seam only; mobile remains a
  cache and no worker/connect/projection logic is enabled by this migration
  alone. Apply on staging first; carry into the next Production1 batch with
  the rest of the follow-up migrations.
- `202605070000_phase_11W_7_operator_account_fields.sql` adds the editable
  business-identity columns (`logo_url`, `locale_tag`, `week_start_day`,
  `rollover_hour`) plus format CHECKs the operator-web `PATCH
  /v1/operator/account` route writes against. Additive + default-backed.
  RLS unchanged (operators is identity-keyed and already protected). Apply
  on staging first; carry into the next Production1 batch.
- `202605070100_password_history_salt_pepper.sql` adds the schema seam for
  salted/peppered password-history hashes: salt and pepper metadata columns,
  an algorithm discriminator, and the legacy-vs-salted CHECK invariant.
  Apply on staging first; carry into the next Production1 batch.
- `202605070200_audit_anchor_advisory_lock_infra.sql` adds the
  `audit_anchor_advisory_locks` constants table and Blob breadcrumb columns
  on `audit_chain_anchors` for serialized daily sweeps and crash
  roll-forward. Apply on staging first; carry into the next Production1
  batch.
- `202605080000_phase_8_timing_provenance_fk_posture.sql` is the V1.B
  Phase 8 timing-provenance FK posture flip. It drops + re-adds
  `shift_records_business_timing_profile_fk`,
  `shift_records_business_timing_profile_version_fk`, and
  `open_shift_snapshots_profile_version_fk` with `ON DELETE SET NULL NOT
  VALID` inside a single transaction so closed historical truth survives
  `business_timing_profiles` deletion (per `core_app_architecture.md`
  "What never rewrites"; supports the Operator Web timing editor
  lifecycle). Idempotent: each FK is name-guarded by a `pg_constraint`
  lookup. No column, index, or CHECK changes. Validation stays `NOT VALID`
  and is deferred to a future maintenance window. Apply on staging first;
  carry into the next Production1 batch with the rest of the follow-up
  migrations.
- `202605080100_admin_idempotency_expires_at.sql` adds the admin
  idempotency reservation TTL: `expires_at`, a partial in-flight expiry
  index, and the every-5-minute `admin_idempotency_sweep` pg_cron job.
  Apply on staging first; carry into the next Production1 batch.
- `202605080100_phase_8_weekly_plan_server_truth.sql` is the Phase 8
  weekly-plan server truth migration from the Doc 1 mobile core contract. It
  adds server-owned `forecast_contexts`, `weekly_plan_snapshots`,
  `weekly_plan_snapshot_days`, and `weekly_plan_audit_events` with RLS,
  operator-leading indexes, a one-active-week uniqueness guard, and
  target-cycle FK posture. Apply on staging first; carry into the next
  Production1 batch with the rest of the follow-up migrations.
- `202605080200_phase_8_wage_role_rows_server_truth.sql` is the Phase 8
  wage-role row server truth migration from the Doc 1 mobile core contract.
  It adds the tenant-scoped `wage_role_rows` table for server-owned
  role/rate/job-code mapping. Mobile mirrors active rows as SQLite cache
  only. Apply on staging first; carry into the next Production1 batch with
  the rest of the follow-up migrations.
- `202605080300_phase_8_data_accuracy_walk_in_settings.sql` is the Phase 8
  data-accuracy walk-in settings migration from the Doc 1 mobile core
  contract. It adds additive `walk_in_handling_mode` and
  `walk_in_manual_entries` fields on `data_accuracy_settings` so reservation
  demand settings are server-owned and mobile-readable. Apply on staging
  first; carry into the next Production1 batch with the rest of the follow-up
  migrations.
- `202605080400_phase_8_connector_oauth_state.sql` is the Phase 8 connector
  OAuth state migration for operator-facing vendor OAuth begin/callback CSRF
  and PKCE state. Apply on staging first; carry into the next Production1
  batch with the rest of the follow-up migrations.
- `202605080600_phase_8_idempotency_location_id_rekey.sql` is the A1
  idempotency rekey: drops and recreates the UNIQUE indexes on
  `shift_records`, `cover_facts`, `labor_punches`, `reservation_facts`, and
  `inbound_webhook_idempotency` to include `location_id` and remove
  `vendor_modified_at` from the key (replaced by a DO UPDATE WHERE
  `excluded.vendor_modified_at >= stored` guard in all 17 vendor sinks).
  Uses `DROP INDEX CONCURRENTLY` / `CREATE UNIQUE INDEX CONCURRENTLY`.
  Apply on staging first; carry into the next Production1 batch.
- One-shot apply plan once approved: confirm staging parity for the same files,
  confirm fresh backup/restore point, run analyzer/lints/focused tests, apply
  the approved files to Production1, verify the `forge_admin`
  `proxy_requests` `SELECT` privilege plus operator/location/admin-grant DML
  privileges directly, verify mobile push schema only after staging
  device proof is complete, verify business timing table/trigger/RLS
  presence directly, verify the rekeyed Phase 8 / Phase 9.8 indexes lead
  with `operator_id` via `pg_indexes`, and verify the
  `admin.users.reset_mfa_factors` and `team.audit_log.export` permission keys
  exist in `permission_keys` with the expected default role grants, verify
  `connector_backfill_jobs` exists with RLS enabled plus operator-leading
  claim/status indexes, verify the Phase 11W.7 operator account columns
  and CHECK constraints exist on `public.operators`, and verify the three
  Phase 8 timing-provenance FKs (`shift_records_business_timing_profile_fk`,
  `shift_records_business_timing_profile_version_fk`,
  `open_shift_snapshots_profile_version_fk`) report
  `confdeltype = 'n'` (`SET NULL`) in `pg_constraint`, and verify the weekly
  plan tables, RLS policies, one-active-week uniqueness guard, target-cycle FK,
  and operator-leading indexes exist. Also verify the password-history
  salt/pepper/algo columns + CHECK constraint, the
  `audit_anchor_advisory_locks` registry + Blob breadcrumb columns, and the
  admin idempotency `expires_at` column, partial expiry index, and cron sweep
  registration. Then run
  RLS lint, update this history and the production cutoff docs. Do not perform
  production runtime setup as part of this database apply.

## Apply Report Template

```text
## Production1 Apply Report - [batch name]

Target:
- Database: [name only]
- Commit SHA:
- Approved by:

Preflight:
- Backup/restore point:
- Staging parity:
- Local gates:

Files applied:
- [file]: [applied/skipped + reason]

Verification:
- RLS policies:
- Tenant-leading indexes:
- Column/table presence:
- Debug Console proxy_requests grant:
- Negative-tenant smoke:
- forge_admin smoke:
- RLS lint:

Backout:
- Needed: yes/no
- Action taken:

Status:
- complete / blocked / follow-up needed
```
