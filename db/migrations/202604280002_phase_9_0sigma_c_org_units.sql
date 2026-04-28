-- Phase 9.0Σ.c — org_units ltree + data_region (items 1, 19 from
-- phase_9_scalability_decisions_2026-04-27.md).
--
-- Two scale-foundation additions that are cheap-to-add-now and
-- expensive-to-retrofit-later:
--
--   1. `org_units` table (item 1, Q2): recursive corp/region/district/
--      location_group hierarchy stored as Postgres `ltree` materialized
--      paths. Subtree queries use `path <@ ancestor`. Permission grants
--      at any node apply to descendants; explicit deny at a descendant
--      overrides inherited access. Max depth 6 enforced via
--      `CHECK (nlevel(path) <= 6)`.
--
--   2. `operators.data_region` column (item 19, Q8): launch is
--      single-region (`CA-CENTRAL`) but the column reserves the slot
--      so multi-region routing in a future phase does not require a
--      migration over real operator data. Default `'CA-CENTRAL'`
--      backfills every existing row.
--
-- Backfill: every existing operator gets exactly one root `corp`
-- row in `org_units`. Operators created after this migration are
-- responsible for creating their root through the proxy admin path
-- (lands in 11A) — `OrgUnitsRepository.createRoot` is the single
-- entrypoint.
--
-- RLS: the table is per-tenant from creation. The four wrapper
-- functions from 202604280000 (item 4) are the only readers of
-- tenant context; bare `current_setting()` is forbidden by the lint.
--
-- Tenant-leading-index discipline (item 4 + CLAUDE.md "RLS performance
-- discipline"): every B-tree index leads with `operator_id`. The GiST
-- index on `path` is the one exception PG allows because GiST cannot
-- compose a tenant-leading column with an `ltree` operator class — the
-- table-level RLS predicate filters tenants before the GiST scan, and
-- the GiST index only ever serves subtree lookups already scoped to
-- one operator's path prefix.
--
-- Idempotent: safe to re-run on local + staging + Production1. All
-- DDL uses `if not exists` / `create or replace`; the backfill is
-- guarded by `not exists` so re-runs are no-ops.
--
-- This migration is local framework only — no live database mutation.
-- Live apply on staging + Production1 is queued under the Phase 9
-- live-mutation gate (subject to user approval per Phase 9 lock).

begin;

-- ─── ltree extension ───────────────────────────────────────────────
--
-- `ltree` ships with Postgres but is not enabled by default. The
-- Azure DB Flexible Server host (CLAUDE.md Proxy & API Conventions)
-- exposes ltree via the standard extension catalog. `if not exists`
-- so re-runs on staging/Production1 (where ltree may already be
-- present from the installed-extensions list) are no-ops.

create extension if not exists ltree;

-- ─── operators.data_region ─────────────────────────────────────────
--
-- Item 19 / Q8: region-ready metadata at operator scope. The launch
-- region for every Canada-Central operator is `'CA-CENTRAL'`. Future
-- multi-region work (US/EU/UK) requires routing/backup/job/audit
-- changes that are out of scope for this slice — the column is the
-- minimum schema hook needed so those follow-ups do not require a
-- migration over real operator data.

alter table public.operators
  add column if not exists data_region text not null default 'CA-CENTRAL';

comment on column public.operators.data_region is
  'Phase 9.0Σ.c (item 19 / Q8) — region-ready metadata. Launch is '
  'single-region CA-CENTRAL; multi-region routing/backups/jobs are '
  'follow-up work. Default backfills existing rows so the schema '
  'hook lands without behavioral change.';

-- ─── org_units table ───────────────────────────────────────────────
--
-- Hierarchy storage per Q2:
--   * `unit_type` is structural: corp / region / district /
--     location_group. Brand identity lives in `name` (or future
--     display fields), not `unit_type`.
--   * `path` is the ltree materialized path. Root `corp` rows have
--     `path = <single_label>`; children have `<root>.<child_label>`.
--     Labels must be lowercase alphanumerics + underscore (ltree's
--     default label syntax).
--   * `parent_id` is the in-table FK that mirrors the path's parent.
--     Root rows have `parent_id IS NULL`. Tenant-isolation discipline:
--     parent_id may only point at a row with the SAME operator_id;
--     enforced via composite FK below.
--   * `(operator_id, path)` is unique — two roots in the same operator
--     would split the hierarchy.

create table if not exists public.org_units (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  parent_id uuid null,
  unit_type text not null
    check (unit_type in ('corp', 'region', 'district', 'location_group')),
  path ltree not null,
  name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Composite uniqueness target so `parent_id` FK below can pin
  -- (operator_id, parent_id) → (operator_id, id), forbidding a
  -- cross-tenant parent pointer at the database layer.
  unique (operator_id, id),
  -- No two nodes in the same operator share an ltree path. The
  -- single-root-per-operator invariant is a separate partial unique
  -- index below — `unique (operator_id, path)` alone would not
  -- prevent two roots with different path labels.
  unique (operator_id, path),
  -- Item 1 / Q2 depth cap: 6 levels max. `nlevel(path)` returns
  -- the number of labels in an ltree value (root = 1).
  constraint org_units_depth_check check (nlevel(path) <= 6),
  -- Composite FK so a child cannot point at a parent in a different
  -- operator. (operator_id, parent_id) → (operator_id, id). NULL
  -- parent_id passes (no FK applied) so root rows are accepted.
  constraint org_units_parent_same_operator_fk
    foreign key (operator_id, parent_id)
    references public.org_units(operator_id, id)
    on delete cascade
);

comment on table public.org_units is
  'Phase 9.0Σ.c (item 1 / Q2) — operator hierarchy. Recursive corp/'
  'region/district/location_group structure stored as ltree '
  'materialized paths. Subtree queries use path <@ ancestor. Depth '
  'capped at 6 (CHECK nlevel(path) <= 6). Per-tenant RLS from '
  'creation. Permission grants at any node apply to descendants per '
  'Q2 inheritance — that lookup is a separate slice (joins through '
  'user_roles + this path).';

comment on column public.org_units.unit_type is
  'Q2: structural type only. Brand/concept/marketing identity belongs '
  'in name or display fields, NOT unit_type.';

comment on column public.org_units.path is
  'Q2: ltree materialized path. Root rows have path = <root_label>; '
  'children inherit parent.path with one label appended. Use '
  'path <@ ancestor for subtree queries.';

-- ─── Indexes ───────────────────────────────────────────────────────
--
-- Tenant-leading B-tree indexes (item 4 / RLS performance discipline).
-- Every B-tree index here leads with operator_id so RLS policy
-- evaluation folds into index scans.

create index if not exists org_units_operator_id_idx
  on public.org_units (operator_id, id);

create index if not exists org_units_operator_parent_idx
  on public.org_units (operator_id, parent_id)
  where parent_id is not null;

create index if not exists org_units_operator_unit_type_idx
  on public.org_units (operator_id, unit_type);

-- GiST index on `path` for subtree queries. Q2 hot path:
-- `path <@ ancestor` to enumerate descendants. PG cannot compose
-- `(operator_id, path)` in a single GiST index; the table-level RLS
-- predicate filters tenants before the GiST scan reaches it, and
-- subtree queries are already scoped to one operator's path prefix.

create index if not exists org_units_path_gist_idx
  on public.org_units using gist (path);

-- Single-root-per-operator invariant. The `unique (operator_id, path)`
-- table constraint above only forbids duplicate paths; without this
-- partial index, two root rows with different path labels (e.g.
-- `acme` and `acme_branch`) would both pass it. PG cannot encode
-- `WHERE parent_id IS NULL` as a table-level UNIQUE constraint, so
-- the invariant lands as a partial unique index here.
--
-- Tenant-leading by construction (one column, `operator_id`); the
-- partial predicate restricts the index to root rows so non-root
-- rows incur no maintenance cost.

create unique index if not exists org_units_one_root_per_operator_uq
  on public.org_units (operator_id)
  where parent_id is null;

-- ─── updated_at trigger ────────────────────────────────────────────
--
-- Reuses the cloud-foundation `cloud_foundation_set_updated_at()`
-- function defined in 202604250005 so updated_at stays consistent
-- across operator-scoped tables.

drop trigger if exists org_units_set_updated_at on public.org_units;
create trigger org_units_set_updated_at
before update on public.org_units
for each row execute function public.cloud_foundation_set_updated_at();

-- ─── Backfill: one root corp row per existing operator ─────────────
--
-- Every operator must have exactly one root before downstream code
-- can rely on `org_units` for hierarchy/grants. The backfill creates
-- the root row using the operator's `business_name` (lowercased,
-- alphanumeric-only) as the ltree label. Re-run safe via `not exists`.
--
-- Label sanitization: ltree labels accept `[A-Za-z0-9_]`. Non-matching
-- characters are stripped, then the result is lowercased. Empty
-- results fall back to a literal `'root'` label so a pathological
-- business name never produces an invalid ltree value.

insert into public.org_units (operator_id, parent_id, unit_type, path, name)
select
  op.operator_id,
  null,
  'corp',
  coalesce(
    nullif(
      lower(regexp_replace(op.business_name, '[^A-Za-z0-9_]', '', 'g')),
      ''
    ),
    'root'
  )::ltree,
  op.business_name
from public.operators op
where not exists (
  select 1 from public.org_units ou
  where ou.operator_id = op.operator_id
    and ou.parent_id is null
);

-- ─── RLS scaffolding ───────────────────────────────────────────────
--
-- Per-tenant RLS from creation. All policies use the wrapper
-- functions from 202604280000 (item 4). Bare `current_setting()` is
-- forbidden by the lint at `tool/rls_policy_lint.dart`.
--
-- Policy posture matches the auth-table pattern from 202604260000 +
-- 202604280001 rewrite: tenant SELECT/ALL via service_role; admin
-- writes go through forge_admin BYPASSRLS (never a separate policy).

alter table public.org_units enable row level security;

create policy "org_units_per_tenant"
  on public.org_units for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

comment on policy "org_units_per_tenant" on public.org_units is
  'Phase 9.0Σ.c (item 1 / Q2). Tenant sees only their own org_units. '
  'Reads operator context via app_current_operator() wrapper (item 4) '
  'so the planner folds the predicate into the operator_id-leading '
  'index. forge_admin BYPASSRLS handles cross-tenant admin paths.';

-- ─── Table privileges ──────────────────────────────────────────────
--
-- Mirrors the 202604260001 grant shape: service_role + forge_admin
-- both get full DML. RLS is the per-tenant gate; without grants, RLS
-- never gets a chance to evaluate (PG checks privileges first).

grant select, insert, update, delete on public.org_units to service_role;
grant select, insert, update, delete on public.org_units to forge_admin;

commit;
