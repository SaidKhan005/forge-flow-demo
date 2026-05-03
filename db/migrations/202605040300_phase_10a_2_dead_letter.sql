-- Phase 10a.2 — event_outbox dead-letter table.
--
-- Closes the only "queue can grow unbounded" gap in the Phase 10a
-- bridge worker pipeline. Without a dead-letter, a row whose publish
-- to Cloud Pub/Sub fails permanently (corrupt payload, gone topic,
-- subscriber-side schema drift) is recycled forever by the lease /
-- attempt_count retry path: the bridge's claim loop picks the row
-- up every `claimReclaimAfter` window, the publish fails again,
-- `attempt_count` increments, repeat. Q22 / item 33 in
-- `phase_9_scalability_decisions_2026-04-27.md` calls this out
-- explicitly — the contract requires a tunable attempt cap that
-- moves runaway rows OUT of the live queue so the live queue stays
-- drainable while operators triage the failures.
--
-- Authority:
--   * `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md` —
--     Scope "Dead-letter" subsection.
--   * `docs/contracts/event_outbox_contract.md` — "Worker
--     Responsibilities" `Dead-letter rows whose attempt_count
--     exceeds the tunable cap (Phase 10a defines the value;
--     expected ≥ 5) by writing the row to an
--     `event_outbox_dead_letter` table and removing it from
--     `event_outbox`. Dead-letter handling is alarmed.`
--
-- Hard rules carried from CLAUDE.md and the 4-27 lock:
--
--   1. RLS performance discipline — the dead-letter index leads with
--      `(operator_id, dead_lettered_at desc)` so the admin tile's
--      "depth + last 10 rows for this operator" query folds into the
--      tenant-leading index probe. The `tool/index_leading_column_lint`
--      gate enforces this on every B-tree index that touches the
--      table.
--   2. RLS uses the wrapper functions from 9.0Σ.b
--      (`public.app_current_operator()`); bare `current_setting()`
--      is forbidden by the lint in `tool/rls_policy_lint.dart`.
--   3. `TIMESTAMPTZ` everywhere; `TIMESTAMP WITHOUT TIME ZONE` is
--      banned in operator-scoped tables.
--   4. The MOVE that drops a row from `event_outbox` and inserts the
--      row into `event_outbox_dead_letter` MUST be transactional —
--      either both writes commit or neither does. The bridge worker
--      runs the move via a single `WITH dead AS (DELETE … RETURNING *)
--      INSERT … SELECT …` CTE inside a `runInTenantContext` so RLS
--      admits both writes and the operator's tenant transaction
--      bounds the atomicity guarantee.
--   5. `pg_partman` partitions the table by `dead_lettered_at_month`
--      with 90-day retention. Rows whose dead-letter window has
--      passed are dropped via `DETACH` + `DROP` partition-cadence;
--      operators triage live rows during the 90-day window.
--
-- Phase 10a.2 worker contract (locked here so the bridge worker has
-- a stable schema):
--   * The bridge claim loop partitions claimed rows by `attempt_count
--     > EVENT_OUTBOX_DLQ_CAP`. Rows past the cap MOVE here in a
--     single transaction; the live publish loop continues unchanged.
--   * `dead_lettered_at` is server-set at MOVE time; the bridge
--     does NOT pass a producer-supplied timestamp.
--   * `last_error` carries the most-recent failure string for
--     operator triage. `dead_letter_reason` carries a short
--     machine-readable code (`'attempt_cap_exceeded'`, `'forced_dlq'`)
--     so the admin tile can group by reason without parsing
--     free-form error text.
--   * No auto-replay job at V1 — operators trigger replay manually
--     after triage. Replay UX is a post-V1 lane.

begin;

-- ─── event_outbox_dead_letter (partitioned by dead_lettered_at_month) ─
--
-- Schema mirrors `event_outbox` so the MOVE CTE can `INSERT … SELECT`
-- without a column projection. Three new columns:
--
--   * `dead_lettered_at` — when the bridge moved the row out of the
--     live queue. Server-set; partition key.
--   * `last_error` — duplicated from event_outbox at move time so the
--     admin tile renders the failure reason without joining back.
--   * `dead_letter_reason` — short code: `'attempt_cap_exceeded'`
--     today, `'forced_dlq'` reserved for the post-V1 manual-DLQ
--     operator action. Constrained to keep the column tractable.
--
-- The PK is `(operator_id, dead_lettered_at_month, id)` — partitioned
-- tables in PG 12+ require the partition key to be in every UNIQUE /
-- PRIMARY KEY index. Tenant-leading per CLAUDE.md "RLS performance
-- discipline".
--
-- `id bigint` (not bigserial) because the row keeps the original
-- `event_outbox.id` so operator triage can correlate the dead-letter
-- row to producer-side telemetry without schema changes. The bridge
-- worker is the only writer; it always carries the original id
-- forward.

create table if not exists public.event_outbox_dead_letter (
  id bigint not null,
  operator_id uuid not null
    references public.operators(operator_id) on delete cascade,
  topic text not null
    check (char_length(topic) between 1 and 200),
  payload jsonb not null default '{}'::jsonb
    check (octet_length(payload::text) <= 262144)
    -- Match the live table's CHECK posture so a stray non-object
    -- payload cannot land here either.
    check (jsonb_typeof(payload) = 'object'),
  created_at timestamptz not null,
  picked_up_at timestamptz null,
  delivered_at timestamptz null,
  attempt_count integer not null
    check (attempt_count >= 0),
  last_error_at timestamptz null,
  last_error text null,
  dead_lettered_at timestamptz not null default now(),
  dead_lettered_at_month date not null,
  dead_letter_reason text not null default 'attempt_cap_exceeded'
    check (dead_letter_reason in ('attempt_cap_exceeded', 'forced_dlq'))
    check (char_length(dead_letter_reason) between 1 and 64),
  -- The partition key must agree with `dead_lettered_at` so the
  -- partition pruner can plan from the row data alone (operators
  -- query by month range; the bridge writes the matching month).
  constraint event_outbox_dead_letter_month_matches_at check (
    dead_lettered_at_month
      = date_trunc('month', dead_lettered_at at time zone 'UTC')::date
  ),
  primary key (operator_id, dead_lettered_at_month, id)
) partition by range (dead_lettered_at_month);

comment on table public.event_outbox_dead_letter is
  'Phase 10a.2 — dead-letter table for event_outbox. The bridge '
  'worker MOVES rows whose attempt_count exceeded EVENT_OUTBOX_DLQ_CAP '
  'here in a single transaction; the live event_outbox stays drainable. '
  'Partitioned by dead_lettered_at_month with 90-day retention via '
  'pg_partman. Append-only by grant shape; no UPDATE/DELETE outside '
  'the partition-drop retention sweep or the forge_admin break-glass '
  'replay procedure.';

comment on column public.event_outbox_dead_letter.id is
  'Original event_outbox.id carried forward so operator triage can '
  'correlate to producer-side telemetry. The bridge MOVE preserves '
  'the id; PG semantics permit duplicate ids on the partitioned '
  'table because the PK is composite (operator_id, '
  'dead_lettered_at_month, id).';

comment on column public.event_outbox_dead_letter.dead_letter_reason is
  'Phase 10a.2 — short machine-readable code for the dead-letter '
  'cause. attempt_cap_exceeded = bridge auto-DLQ on '
  'attempt_count > EVENT_OUTBOX_DLQ_CAP. forced_dlq = post-V1 '
  'reserved for the manual-DLQ operator action.';

comment on column public.event_outbox_dead_letter.dead_lettered_at_month is
  'UTC month of dead_lettered_at. Partition key. CHECK constraint '
  'forbids a value that disagrees with dead_lettered_at — the '
  'partition pruner relies on this so a mis-routed row cannot strand '
  'in a wrong partition.';

-- ─── pg_partman registration (idempotent) ───────────────────────────
--
-- Monthly range partitioning, 3 months premade so a clock skew or
-- delayed maintenance run cannot leave the bridge without a
-- partition. The guard reads `public.part_config` so re-running this
-- migration is a no-op. Argument shape mirrors
-- `202604280005_phase_9_0sigma_f_audit_logs.sql` /
-- `202605020452_hardening_auth_login_attempts.sql`:
-- `public.create_parent(...)` with `p_default_table := false` and
-- `p_jobmon := false`.

do $$
begin
  if not exists (
    select 1 from public.part_config
     where parent_table = 'public.event_outbox_dead_letter'
  ) then
    perform public.create_parent(
      p_parent_table  := 'public.event_outbox_dead_letter',
      p_control       := 'dead_lettered_at_month',
      p_interval      := '1 month',
      p_premake       := 3,
      p_default_table := false,
      p_jobmon        := false
    );
  end if;
end;
$$;

-- 90-day retention. `retention_keep_table = true` so the DBA partition-
-- drop runbook decides exactly when to DROP rather than letting
-- pg_partman pull the table out from under live triage. The
-- `pg_partman` `run_maintenance` cadence (already wired by Phase
-- 9.0Σ.k) expires partitions whose end-of-month is older than 90 days.
update public.part_config
   set premake                  = 3,
       retention                = '90 days',
       retention_keep_table     = true,
       infinite_time_partitions = true
 where parent_table = 'public.event_outbox_dead_letter';

-- ─── Tenant-leading indexes ─────────────────────────────────────────
--
-- The admin tile's hot queries are:
--
--   * Depth (per operator):  count(*) WHERE operator_id = $1
--   * Last 10 rows:          ORDER BY dead_lettered_at DESC LIMIT 10
--                              WHERE operator_id = $1
--
-- Both fold into the same tenant-leading composite index. PG
-- propagates parent indexes to child partitions automatically.

create index if not exists event_outbox_dead_letter_recent_idx
  on public.event_outbox_dead_letter
     (operator_id, dead_lettered_at desc, id);

-- ─── RLS policies (wrapper-only per 9.0Σ.b) ─────────────────────────
--
-- Same shape as `event_outbox`:
--   * `event_outbox_dead_letter_per_tenant_select` — tenants read only
--     their own dead-letter rows.
--   * `event_outbox_dead_letter_per_tenant_modify` — bridge worker
--     INSERT/UPDATE filtered by app_current_operator(); cross-tenant
--     writes blocked at WITH CHECK. DELETE is also gated through this
--     policy so the partition-drop retention path stays inside the
--     forge_admin BYPASSRLS escape (see grants below).
--
-- F&F admin reads via the 11A.6 observability tile run through
-- `forge_admin BYPASSRLS` for the cross-operator depth aggregate;
-- per-operator drilldown re-enters the per-tenant policy.

alter table public.event_outbox_dead_letter enable row level security;

create policy "event_outbox_dead_letter_per_tenant_select"
  on public.event_outbox_dead_letter for select to service_role
  using (operator_id = public.app_current_operator());

create policy "event_outbox_dead_letter_per_tenant_modify"
  on public.event_outbox_dead_letter for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

comment on policy "event_outbox_dead_letter_per_tenant_select"
  on public.event_outbox_dead_letter is
  'Phase 10a.2 — tenants and the bridge worker (running inside a '
  'tenant transaction) see only their own dead-letter rows. '
  'Cross-tenant aggregates (admin tile depth count) require '
  'forge_admin BYPASSRLS via runAsSystem.';

comment on policy "event_outbox_dead_letter_per_tenant_modify"
  on public.event_outbox_dead_letter is
  'Phase 10a.2 — bridge worker INSERT through this policy when the '
  'MOVE CTE writes a runaway row. Cross-tenant writes blocked at '
  'WITH CHECK. UPDATE is reserved for the post-V1 manual-DLQ replay '
  'flow (operator-triggered, audited).';

-- ─── Grants ──────────────────────────────────────────────────────────
--
-- service_role and forge_admin both get SELECT/INSERT for the bridge
-- MOVE write path and the tenant + admin read paths. UPDATE is
-- granted because the post-V1 replay flow toggles a row's status
-- back; the V1 worker never UPDATEs a dead-letter row. DELETE is
-- granted on forge_admin only — the partition-drop retention sweep
-- runs in the system scope and tenants never delete their own
-- dead-letter rows (they triage and replay; deletion is the DBA's
-- partition cadence).

revoke all on public.event_outbox_dead_letter from public;

grant select, insert, update on public.event_outbox_dead_letter
  to service_role;
grant select, insert, update, delete on public.event_outbox_dead_letter
  to forge_admin;

-- Defensive REVOKE: re-assert that service_role cannot delete
-- dead-letter rows even if a future grant pattern adds the broader
-- DML set out of habit. The retention sweep runs as forge_admin per
-- the runbook.
revoke delete on public.event_outbox_dead_letter from service_role;

commit;
