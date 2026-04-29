# Phase 9 Production1 Migration Apply Runbook

Updated: 2026-04-29.

Purpose: govern the live Production1 apply for the new Phase 9 `9.0 Sigma`
foundation migrations and hotfix slots. This runbook must be reviewed before
any Production1 mutation.

## Scope

Production1 target: `forge-flow-production1-pg`.

In scope:

- `db/migrations/202604280000_phase_9_0sigma_b_rls_wrappers.sql`
- `db/migrations/202604280001_phase_9_0sigma_b_rewrite_existing_policies.sql`
- `db/migrations/202604280002_phase_9_0sigma_c_org_units.sql`
- `db/migrations/202604280003_phase_9_0sigma_e_event_outbox.sql`
- `db/migrations/202604280004_phase_9_0sigma_d_service_principals.sql`
- `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`
- `db/migrations/202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql`
- `db/migrations/202604280006_b_phase_9_0sigma_g_usage_caps_two_slot_backfill.sql`
- `db/migrations/202604280006_c_phase_9_0sigma_g_usage_caps_two_slot_constraint_flip.sql`
- `db/migrations/202604280007_phase_9_0sigma_h_advisor_conversation_log.sql`
- `db/migrations/202604280008_phase_9_0sigma_i_graph_canonical.sql`
- `db/migrations/202604280009_phase_9_0sigma_j_diskann_install.sql`
- `db/migrations/202604280010_a_phase_9_0sigma_k_aggregation_state.sql`
- `db/migrations/202604280010_b_phase_9_0sigma_k_rollup_tables.sql`
- `db/migrations/202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql`
- `db/migrations/202604280011_phase_9_recovery_code_attempts.sql`
- `db/migrations/202604280012_phase_9_auth_ops_cloud_foundation_grants.sql`
- `db/migrations/202604280013_phase_9_audit_actor_kind_live_repair.sql`

Out of scope:

- Cloud Armor enforcement mutation.
- Production proxy deploy.
- Operator data import.
- Any migration outside the `202604280000` through `202604280013` files listed
  above.

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

Run in this exact order:

1. `202604280000_phase_9_0sigma_b_rls_wrappers.sql`
2. `202604280001_phase_9_0sigma_b_rewrite_existing_policies.sql`
3. `202604280002_phase_9_0sigma_c_org_units.sql`
4. `202604280003_phase_9_0sigma_e_event_outbox.sql`
5. `202604280004_phase_9_0sigma_d_service_principals.sql`
6. `202604280005_phase_9_0sigma_f_audit_logs.sql`
7. `202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql`
8. `202604280006_b_phase_9_0sigma_g_usage_caps_two_slot_backfill.sql`
9. `202604280006_c_phase_9_0sigma_g_usage_caps_two_slot_constraint_flip.sql`
10. `202604280007_phase_9_0sigma_h_advisor_conversation_log.sql`
11. `202604280008_phase_9_0sigma_i_graph_canonical.sql`
12. `202604280009_phase_9_0sigma_j_diskann_install.sql`
13. `202604280010_a_phase_9_0sigma_k_aggregation_state.sql`
14. `202604280010_b_phase_9_0sigma_k_rollup_tables.sql`
15. `202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql`
16. `202604280011_phase_9_recovery_code_attempts.sql`
17. `202604280012_phase_9_auth_ops_cloud_foundation_grants.sql`
18. `202604280013_phase_9_audit_actor_kind_live_repair.sql`

Dependency notes:

- `...0004` must run before `...0013`; `0013` is a live-repair hotfix that is
  idempotent after `0004`.
- `...0000` through `...0003` are prerequisites for `...0004` through
  `...0013`; fresh Production1 did not have the wrapper, org-unit, or
  event-outbox foundation yet.
- `...0006_a`, `...0006_b`, `...0006_c` must run in strict A/B/C order.
- `...0010_a`, `...0010_b`, `...0010_c` must run in strict A/B/C order.
- Do not skip `...0012`; it owns cloud-foundation grants for auth operations.
- Azure Flexible Server must allow-list `ltree` in `azure.extensions` before
  `...0002` can create the extension. This is dynamic on the current staging
  and Production1 servers and did not require a restart during the live apply.
- Azure keeps `pg_cron` metadata in the `postgres` maintenance database because
  `cron.database_name=postgres`. Apply `...0010_c` to `forgeflow`, then schedule
  the rollup jobs from `postgres` with `cron.schedule_in_database(...,
  'forgeflow')` using `* * * * *` for the hot path and `*/5 * * * *` for the
  cold path.

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
    'recovery_code_attempts',
    'service_principals'
  )
order by table_name, grantee, privilege_type;
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

## 2026-04-29 Apply Result

- Staging and Production1 applied `202604280000` through `202604280013`.
- Both servers were updated to allow-list `ltree` in `azure.extensions`.
- `202604280010_c` creates the rollup functions in `forgeflow`; rollup cron
  jobs are scheduled from the `postgres` maintenance database.
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

## Apply Report Template

```text
## Production1 Apply Report - Phase 9 9.0 Sigma slots

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
