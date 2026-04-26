-- Phase 11a.11c.6a - operator-run verification / maintenance scaffold.
--
-- This file is intentionally separate from db/migrations. The live Azure
-- server has pg_partman + pg_cron installed, but extension function signatures
-- and partition-policy choices should be verified by the operator before
-- scheduling maintenance. Keep this file idempotent/read-only except for the
-- commented statements an operator deliberately copies into a live run.

-- pg_partman registration intent for public.usage_logs.
--
-- Review pg_partman settings on the target host, then run an adapted form.
-- Azure installed pg_partman into the `public` schema on the verified
-- staging/production servers, so the live function names are `public.*`.
--
--   SELECT public.create_parent(
--     p_parent_table := 'public.usage_logs',
--     p_control := 'period_start',
--     p_interval := '1 month',
--     p_premake := 3,
--     p_default_table := false,
--     p_jobmon := false
--   );
--
-- Hourly maintenance intent via pg_cron:
--
--   SELECT cron.schedule(
--     'partman_maintenance',
--     '0 * * * *',
--     $$SELECT public.run_maintenance(p_analyze := true)$$
--   );

select
  'pg_partman_create_parent_intent' as check_name,
  'SELECT public.create_parent(p_parent_table := ''public.usage_logs'', p_control := ''period_start'', p_interval := ''1 month'', p_premake := 3, p_default_table := false, p_jobmon := false);' as statement_to_review;

select
  'pg_cron_partman_maintenance_intent' as check_name,
  'SELECT cron.schedule(''partman_maintenance'', ''0 * * * *'', $$SELECT public.run_maintenance(p_analyze := true)$$);' as statement_to_review;

-- RLS performance audit. Operator-scoped fact-table indexes must lead with
-- operator_id or the pair (operator_id, location_id); otherwise RLS can force
-- broad scans under tenant filtering.
with index_keys as (
  select
    n.nspname as schema_name,
    tbl.relname as table_name,
    idx.relname as index_name,
    array_agg(
      coalesce(att.attname::text, '<expression>')
      order by key_pos.ordinality
    ) as key_columns
  from pg_index ix
  join pg_class tbl on tbl.oid = ix.indrelid
  join pg_namespace n on n.oid = tbl.relnamespace
  join pg_class idx on idx.oid = ix.indexrelid
  join lateral unnest(ix.indkey) with ordinality as key_pos(attnum, ordinality) on true
  left join pg_attribute att
    on att.attrelid = tbl.oid
   and att.attnum = key_pos.attnum
   and not att.attisdropped
  where n.nspname = 'public'
    and tbl.relkind in ('r', 'p')
    and tbl.relname in (
      'usage_logs',
      'usage_logs_default',
      'usage_caps',
      'proxy_requests',
      'advisor_proxy_usage_counters'
    )
  group by n.nspname, tbl.relname, idx.relname
),
violations as (
  select *
  from index_keys
  where not (
    key_columns[1] = 'operator_id'
    or key_columns[1:2] = array['operator_id', 'location_id']
  )
)
select
  schema_name,
  table_name,
  index_name,
  key_columns
from violations
order by schema_name, table_name, index_name;
