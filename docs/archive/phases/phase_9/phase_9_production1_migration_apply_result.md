# Phase 9 Production1 Migration Apply Result

Updated: 2026-04-29.

Status: complete for the Phase 9 `202604280000` through `202604280013`
migration set on staging and Production1.

## Target

- Staging database: `forge-flow-staging-pg` / `forgeflow`.
- Production1 database: `forge-flow-production1-pg` / `forgeflow`.
- No DSNs, tokens, passwords, or credential values were copied into chat or docs.

## Live Apply Notes

- Staging proved that `202604280000` through `202604280003` are prerequisites for
  the originally queued `202604280004` through `202604280013` scope.
- Azure Flexible Server rejected `ltree` until it was included in
  `azure.extensions`; staging and Production1 were both updated dynamically.
- `pg_cron` metadata lives in the `postgres` maintenance database on both Azure
  servers. The application migration creates rollup functions in `forgeflow`;
  jobs were registered from `postgres` with `cron.schedule_in_database`.
- Azure `pg_cron` rejected seconds-interval literals, so live schedules use
  standard cron equivalents: `* * * * *` for the hot path and `*/5 * * * *` for
  the cold path.

## Files Applied

- `202604280000_phase_9_0sigma_b_rls_wrappers.sql`
- `202604280001_phase_9_0sigma_b_rewrite_existing_policies.sql`
- `202604280002_phase_9_0sigma_c_org_units.sql`
- `202604280003_phase_9_0sigma_e_event_outbox.sql`
- `202604280004_phase_9_0sigma_d_service_principals.sql`
- `202604280005_phase_9_0sigma_f_audit_logs.sql`
- `202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql`
- `202604280006_b_phase_9_0sigma_g_usage_caps_two_slot_backfill.sql`
- `202604280006_c_phase_9_0sigma_g_usage_caps_two_slot_constraint_flip.sql`
- `202604280007_phase_9_0sigma_h_advisor_conversation_log.sql`
- `202604280008_phase_9_0sigma_i_graph_canonical.sql`
- `202604280009_phase_9_0sigma_j_diskann_install.sql`
- `202604280010_a_phase_9_0sigma_k_aggregation_state.sql`
- `202604280010_b_phase_9_0sigma_k_rollup_tables.sql`
- `202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql`
- `202604280011_phase_9_recovery_code_attempts.sql`
- `202604280012_phase_9_auth_ops_cloud_foundation_grants.sql`
- `202604280013_phase_9_audit_actor_kind_live_repair.sql`

## Verification

- Staging and Production1 both verified expected table, function, column,
  constraint, and extension presence after apply.
- Verified tables include `org_units`, `event_outbox`, `service_principals`,
  `audit_logs`, `audit_chain_anchors`, `advisor_conversation_log`,
  `graph_nodes`, `graph_edges`, `aggregation_state`, all seven `rollup_*`
  tables, and `recovery_code_attempts`.
- Verified columns/constraints include `auth_events_audit.actor_kind`,
  `auth_events_audit.actor_service_principal_id`, the usage two-slot columns,
  `usage_caps_two_slot_uq`, `usage_logs_two_slot_rollup_uq`, and
  `auth_events_audit_actor_kind_check`.
- Verified extensions include `ltree`, `pgcrypto`, `vector`, `pg_diskann`, and
  `pg_partman`.
- Verified cron jobs on both environments:
  `forge_rollup_hot_path @ forgeflow * * * * *`,
  `forge_rollup_cold_path @ forgeflow */5 * * * *`, and the existing
  `forgeflow_partman_maintenance_usage_logs @ forgeflow 0 * * * *`.
- First observed `cron.job_run_details` entries for the hot and cold rollup
  jobs succeeded on both staging and Production1.

## Backout

No backout was needed.

Local apply and verification logs are under `build/phase_9_production1_apply/`
and are intentionally not committed.
