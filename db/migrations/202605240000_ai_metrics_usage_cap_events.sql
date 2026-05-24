-- AI Metrics — append-only cap-refusal event ledger (`usage_cap_events`).
--
-- One row per request the proxy REFUSED because it would have breached a
-- spend cap. The admin "AI Metrics" / Observability "Limit hits" panel
-- reads this table to show operators (and F&F support) when and how often
-- a cap stopped a provider call. This slice owns ONLY the table + RLS
-- posture + indexes; the producer write path (proxy refusal hook) and the
-- read panel land in later slices. No row is loaded here, no provider is
-- called, and no existing migration is modified.
--
-- Authority anchors
-- -----------------
--   * db/migrations/202604250005_advisor_cloud_foundation.sql — defines
--     `public.locations` (with the `unique (operator_id, location_id)`
--     composite target this table's FK binds against), `public.usage_caps`
--     (the cap definitions a refusal is measured against: `usage_class`
--     + per-invocation / monthly caps), and the shared
--     `public.cloud_foundation_set_updated_at()` trigger function.
--   * db/migrations/202605030000_phase_9_5_0_leaderboard_schema_rls.sql —
--     the append-only operator-scoped fact-table template this migration
--     mirrors verbatim (wrapper-only RLS, operator-leading B-tree index,
--     composite FK, occurred_at + denormalized business_date, explicit
--     REVOKE of UPDATE/DELETE for the append-only grant posture).
--   * db/migrations/202604280000_phase_9_0sigma_b_rls_wrappers.sql — the
--     four `STABLE LEAKPROOF PARALLEL SAFE` wrapper functions every
--     operator-scoped policy must call instead of bare current_setting().
--
-- Hard rules carried verbatim from CLAUDE.md (Authority Order item 6):
--
--   1. **RLS-Ready Schema (CLAUDE.md).** The fact table includes
--      `(operator_id, location_id)` from creation as a COMPOSITE FK
--      against `public.locations(operator_id, location_id)` so a refusal
--      row attributed to a location that doesn't belong to the operator
--      is rejected at the DB layer — the `(operator_a, location_b)`
--      cross-tenant mismatch can never be inserted, even before RLS is
--      auth-bearing. Single-location operators inject the operator's
--      `primary_location_id` from `OperatorContext`. Scaffolding is NOT
--      retrofitted later.
--
--   2. **OperatorScopedRepository is the primary defense; RLS is the
--      backup.** This migration ships the secondary defense. The producer
--      repository (a later slice) carries the SET LOCAL ordering and the
--      tenant-scoped INSERT shape so a missing or malformed RLS policy
--      cannot leak rows even before the policy is evaluated.
--
--   3. **Wrapper-only RLS posture (Phase 9.0Σ.b item 4).** Every policy
--      body calls the locked `STABLE LEAKPROOF PARALLEL SAFE` wrapper
--      functions (`public.app_current_operator()`,
--      `public.app_current_location()`). No bare
--      `current_setting('app.<name>', true)::uuid` reads — the
--      `tool/rls_policy_lint.dart` rule rejects them.
--
--   4. **Tenant-leading B-tree indexes (CLAUDE.md / 9.0Σ.b item 4).**
--      Every B-tree index leads with `operator_id` (or `(operator_id,
--      location_id)`) so the per-tenant policy folds into the index probe
--      rather than evaluating row-by-row. CI index lint enforces.
--
--   5. **Time guardrails (CLAUDE.md, phase_7_55_time_boundary_contract).**
--      `occurred_at` is `timestamptz` (UTC source-truth instant — when the
--      proxy refused). `business_date` is a denormalized `date` computed
--      at write from the operator's location timezone +
--      `business_day_rollover_hour`, so the "limit hits per business day"
--      rollup does not have to read `locations` or timezone-convert on
--      every read. `TIMESTAMP WITHOUT TIME ZONE` is banned on
--      operator-scoped tables (silent DST corruption is unrecoverable). A
--      CHECK guards against pre-2000 dates without recomputing the
--      projection in SQL.
--
--   6. **Append-only fact-table grants.** `service_role` and
--      `forge_admin` get INSERT + SELECT on `usage_cap_events`;
--      UPDATE / DELETE are explicitly REVOKEd. A refusal event is
--      immutable history — there is no edit path. Retention sweeps are a
--      later follow-up (the Observability phase will decide retention by
--      age), not a row-level mutation.
--
-- Live apply status:
--   * NOT YET APPLIED. The owning Observability/AI-Metrics lane will apply
--     this on staging + Production1 once the producer + read panel justify
--     an apply window. The migration is idempotent (`if not exists` on the
--     table + indexes; `drop policy if exists` before `create policy`) so
--     re-running it is safe.

begin;

-- ─── usage_cap_events ───────────────────────────────────────────────
--
-- Append-only ledger of cap-breach refusals. One row is written each
-- time the proxy declines a provider call because the call's projected
-- spend would exceed a configured cap in `public.usage_caps`.
--
-- Column rationale:
--
--   * `event_id` — surrogate UUID PK. The producer maps a refusal to a
--     stable id so a retried-then-refused request does not double-count
--     in the panel.
--   * `operator_id` / `location_id` — RLS-Ready scaffolding. Composite FK
--     against `public.locations(operator_id, location_id)` rejects a row
--     attributed to a location that doesn't belong to the operator.
--   * `usage_class` — which spend class the cap belongs to (mirrors
--     `public.usage_caps.usage_class`; e.g. the advisor vs embedding vs
--     rerank two-slot key). Bounded text; the runtime owns the canonical
--     enum so a misspelled class fails fast in Dart.
--   * `query_class` — the finer per-request classifier the cap decision
--     keyed off (the proxy's per-invocation query class). Kept distinct
--     from `usage_class` so the panel can break "limit hits" down by both
--     the cap bucket and the request kind that tripped it.
--   * `cap_usd` — the cap value (USD) that was in force at refusal time,
--     snapshotted onto the event so the panel renders the threshold the
--     operator actually hit without re-reading `usage_caps` (which may
--     have changed since). Non-negative.
--   * `attempted_usd` — the projected USD cost of the refused call. By
--     definition `attempted_usd` exceeded `cap_usd`; both are stored so
--     the panel can show "tried to spend X against a Y cap". Non-negative.
--   * `occurred_at` — UTC source-truth instant the refusal happened.
--     Primary timing axis for the panel's time series.
--   * `business_date` — denormalized operator-local business date computed
--     at write (Time Guardrails). Powers "limit hits per business day"
--     without a hot-path timezone conversion.
--   * `created_at` — when the row landed in the DB. Append-cadence
--     telemetry, not user-visible time.

create table if not exists public.usage_cap_events (
  event_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  usage_class text not null
    check (
      char_length(usage_class) between 1 and 64
      and usage_class = btrim(usage_class)
    ),
  query_class text not null
    check (
      char_length(query_class) between 1 and 64
      and query_class = btrim(query_class)
    ),
  cap_usd numeric(12, 4) not null
    check (cap_usd >= 0),
  attempted_usd numeric(12, 4) not null
    check (attempted_usd >= 0),
  occurred_at timestamptz not null,
  business_date date not null
    check (business_date >= date '2000-01-01'),
  created_at timestamptz not null default now(),
  -- Composite FK keeps a refusal from being attributed to a location
  -- that doesn't belong to its operator. `public.locations` exposes a
  -- composite uniqueness target on `(operator_id, location_id)` per
  -- 202604250005_advisor_cloud_foundation.sql; this FK binds against it.
  -- An operator delete cascades through `locations` and arrives here as
  -- the chained cascade; a direct location delete also cascades here.
  constraint usage_cap_events_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.usage_cap_events is
  'AI Metrics — append-only ledger of cap-breach refusals (one row per '
  'provider call the proxy declined for exceeding a usage_caps threshold). '
  'Per-tenant RLS via wrapper functions (operator_id leading); the admin '
  'AI Metrics / Observability "Limit hits" panel projects this table. '
  'Append-only at the grant shape — there is no edit path; UPDATE/DELETE '
  'are REVOKEd. Producer write path + read panel land in later slices.';

comment on column public.usage_cap_events.business_date is
  'Operator-local business date computed at write from '
  'location.timezone + location.business_day_rollover_hour (CLAUDE.md '
  'Time Guardrails). Denormalized so the limit-hits-per-day rollup does '
  'not have to read locations in the hot path.';

comment on column public.usage_cap_events.cap_usd is
  'The USD cap value in force at refusal time, snapshotted onto the event '
  'so the panel renders the threshold the operator hit even if the '
  'usage_caps row changed afterward.';

comment on column public.usage_cap_events.attempted_usd is
  'Projected USD cost of the refused call; by definition exceeded '
  'cap_usd. Stored so the panel can show "tried to spend X against Y cap".';

-- ─── Operator-leading B-tree indexes ────────────────────────────────
--
-- Every B-tree index leads with `operator_id` (or `(operator_id,
-- location_id)`) so the per-tenant RLS policy folds into the index probe
-- rather than evaluating row-by-row (CLAUDE.md / 9.0Σ.b item 4; enforced
-- by the index lint sweep).
--
-- Query shapes the "Limit hits" panel relies on:
--
--   * Operator time series:  WHERE operator_id = $1
--                            [AND business_date BETWEEN $2 AND $3]
--                            ORDER BY occurred_at DESC
--   * Per-location split:    WHERE operator_id = $1 AND location_id = $2
--                            [AND business_date BETWEEN $3 AND $4]

create index if not exists usage_cap_events_operator_occurred_idx
  on public.usage_cap_events
    (operator_id, occurred_at desc);

create index if not exists usage_cap_events_operator_location_date_idx
  on public.usage_cap_events
    (operator_id, location_id, business_date desc);

-- ─── RLS policies (wrapper-only per 9.0Σ.b) ─────────────────────────
--
-- Two policies, mirroring the leaderboard_scores / audit_logs append-only
-- pattern:
--
--   * `usage_cap_events_per_tenant_select` — tenants read only their own
--     refusal rows. The panel projection runs inside the tenant
--     transaction so the GUC injection from `runInTenantContext` makes
--     the wrapper return the correct UUID. Cross-operator reads (F&F
--     support paths) go through forge_admin BYPASSRLS via runAsSystem.
--
--   * `usage_cap_events_per_tenant_insert` — INSERT-only, scoped to the
--     tenant's operator + location. UPDATE/DELETE have NO matching policy
--     AND no grants (see Grants block below); both axes must agree to
--     keep the table append-only.
--
-- Idempotent — `drop policy if exists` before `create policy` so
-- re-running this migration after a hand-edit on staging restores the
-- canonical posture.

alter table public.usage_cap_events enable row level security;

drop policy if exists "usage_cap_events_per_tenant_select"
  on public.usage_cap_events;
drop policy if exists "usage_cap_events_per_tenant_insert"
  on public.usage_cap_events;

create policy "usage_cap_events_per_tenant_select"
  on public.usage_cap_events for select to service_role
  using (operator_id = public.app_current_operator());

create policy "usage_cap_events_per_tenant_insert"
  on public.usage_cap_events for insert to service_role
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

comment on policy "usage_cap_events_per_tenant_select"
  on public.usage_cap_events is
  'AI Metrics — tenants read only their own cap-refusal rows via '
  'app_current_operator(). Cross-operator reads (admin support paths) go '
  'through forge_admin BYPASSRLS via runAsSystem.';

comment on policy "usage_cap_events_per_tenant_insert"
  on public.usage_cap_events is
  'AI Metrics — refusal events may only be attributed to the tenant''s '
  'own operator + location. No matching UPDATE/DELETE policy AND no '
  'UPDATE/DELETE grants: a refusal is immutable history so the '
  'append-only posture holds.';

-- ─── Append-only grants ─────────────────────────────────────────────
--
-- service_role + forge_admin get INSERT + SELECT only. UPDATE / DELETE
-- are explicitly REVOKEd so a future grant change cannot silently weaken
-- the posture without an explicit reviewer's notice. The same two-axis
-- posture (no policy AND no grant) the leaderboard_scores / audit_logs
-- slices use.

revoke all on public.usage_cap_events from public;
grant select, insert on public.usage_cap_events to service_role;
grant select, insert on public.usage_cap_events to forge_admin;
revoke update, delete on public.usage_cap_events from service_role;
revoke update, delete on public.usage_cap_events from forge_admin;

commit;
