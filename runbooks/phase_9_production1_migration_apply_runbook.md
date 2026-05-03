# Phase 9 Production1 Migration Apply Runbook

Updated: 2026-05-02.

Purpose: govern the live Production1 apply of the second migration batch —
27 files spanning Phase 9 follow-ups, Phase 11A advisor surfaces, and the
HARD-B/HARD-F/HARD-H hardening pack — through cutoff
`202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql`. This runbook must be reviewed
before any Production1 mutation. The first batch (Phase 9.0 Sigma slices b–k
plus auth/recovery patches) was applied 2026-04-29; see the Apply History
section below for the prior result.

## Scope

Production1 target: `forge-flow-production1-pg-cmk` (Azure Flexible
Server, Canada Central, PG 16). The original
`forge-flow-production1-pg` server was deleted during `cutover.0a.pg`
and replaced by the CMK-enabled `-cmk` server on 2026-05-01.

In scope (27 pending migrations, lex order):

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

Out of scope:

- Cloud Armor enforcement mutation.
- Production proxy deploy.
- Operator data import.
- Any migration outside the cutoff range above (anything with a lex prefix
  earlier than `202604280014` is already in production from the first batch;
  anything later than `202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql` belongs to
  a future apply event and is gated by `tool/migration_cutoff_lint.dart`).

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
- [ ] Confirm the operator approving the apply.
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
    'recovery_code_attempts',
    'service_principals'
  )
order by table_name, grantee, privilege_type;
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

### Next batch — pending (cutoff `202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql`)

The 27 files inventoried under "Scope" above are queued for the next
Production1 apply event. Append the result here once the apply is run.

## Apply Report Template

```text
## Production1 Apply Report - second batch (Phase 9 + 11A + Hardening)

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
- Negative-tenant smoke:
- forge_admin smoke:
- RLS lint:

Backout:
- Needed: yes/no
- Action taken:

Status:
- complete / blocked / follow-up needed
```
