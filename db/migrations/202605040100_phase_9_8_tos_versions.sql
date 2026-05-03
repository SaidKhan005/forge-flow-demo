-- Phase 9.8 — Inbound-vendor T&Cs schema (minimum two tables).
--
-- Backs the click-through flow specified in
-- `docs/phases/phase_9_8/phase_9_8_inbound_vendor_tcs_draft.md`. The
-- draft asks for two tables:
--
--   * `tos_versions`     — versioned legal text the operator agrees to.
--                          Scope-aware so the universal click-through
--                          (`inbound_vendor_universal`) and the
--                          per-vendor click-throughs
--                          (`inbound_vendor_<vendor_id>`) live in the
--                          same table.
--   * `tos_acceptances`  — append-only acceptance log keyed by
--                          (operator_id, user_id, version_id) with the
--                          IP + UA captured at the moment of click.
--
-- This slice (`11W.0` shell) only ships the schema so the click-through
-- screen has a write target. The T&Cs versioning admin UI lives behind
-- a later Phase 11A slice; this migration does not back-fill any
-- versions and does not add admin grants beyond the standard
-- `forge_admin` insert/select.
--
-- Existing `public.tncs_acceptances` (Phase 9.0 auth foundation) stays
-- in place — it tracks the legacy app-T&Cs acceptance shape (text
-- version string only). The Phase 9.8 inbound-vendor flow needs the
-- richer scope + version_id model the draft specifies, so we add a new
-- table rather than evolve the legacy one. A future Phase 9.8 slice
-- will reconcile the two; for `11W.0` we only need write targets.
--
-- Hard rules carried verbatim from CLAUDE.md (Authority Order item 5):
--
--   1. **RLS-Ready Schema (CLAUDE.md).** Operator-scoped fact tables
--      include `(operator_id, location_id)` from creation. T&Cs
--      acceptances are operator-scoped (no location dimension — T&Cs
--      acceptance is operator-wide), so `(operator_id)` leads.
--      `tos_versions` is corpus-scoped (operator-agnostic legal text)
--      and stays unscoped at the row level — it carries no
--      `operator_id` column; reads are public to authenticated roles.
--
--   2. **OperatorScopedRepository is the primary defense; RLS is the
--      backup.** This migration ships the secondary defense via
--      wrapper-only RLS policies on `tos_acceptances`.
--
--   3. **Wrapper-only RLS posture (Phase 9.0Σ.b item 4).** Every policy
--      body calls the locked
--      `STABLE LEAKPROOF PARALLEL SAFE` wrapper functions
--      (`app_current_operator()`, `app_current_actor_user()`).
--
--   4. **Tenant-leading B-tree indexes (CLAUDE.md / 9.0Σ.b item 4).**
--      Every B-tree index on `tos_acceptances` leads with
--      `operator_id` so the planner can fold the per-tenant policy
--      into the index probe.
--
--   5. **Append-only fact-table grants.** `service_role` and
--      `forge_admin` get INSERT and SELECT on `tos_acceptances`;
--      UPDATE/DELETE are explicitly REVOKEd. Acceptance is a legal
--      record — it must never be silently mutated. Corrections land
--      as a fresh acceptance row referencing a superseding version.

begin;

-- ─── tos_versions ────────────────────────────────────────────────────
--
-- Versioned legal text. Operator-agnostic; the same row is referenced
-- by every operator's acceptance. `scope` partitions universal vs
-- per-vendor T&Cs so the same table holds
-- `inbound_vendor_universal`, `inbound_vendor_toast`, etc.
--
-- `superseded_by_version_id` is null for the active version; when a
-- new version effective-dates, the previous row's column is updated to
-- point forward. The legacy text stays in the table forever (never
-- delete a version that has acceptances against it) so audit reads
-- can render the exact text the operator agreed to.

create table if not exists public.tos_versions (
  version_id uuid primary key default gen_random_uuid(),
  scope text not null
    check (
      char_length(scope) between 1 and 128
      and scope = btrim(scope)
    ),
  version_number text not null
    check (
      char_length(version_number) between 1 and 32
      and version_number = btrim(version_number)
    ),
  effective_date date not null,
  body_markdown text not null
    check (char_length(body_markdown) between 1 and 524288),
  superseded_by_version_id uuid
    references public.tos_versions(version_id) on delete set null,
  created_at timestamptz not null default now(),
  created_by uuid references public.users(user_id) on delete set null,
  unique (scope, version_number)
);

comment on table public.tos_versions is
  'Phase 9.8 — versioned legal text the operator agrees to during '
  'inbound-vendor onboarding. Scope partitions universal vs '
  'per-vendor T&Cs. Append-only by convention; superseded versions '
  'remain in place so an acceptance row always resolves to the exact '
  'text that was shown.';

comment on column public.tos_versions.scope is
  'Phase 9.8 — `inbound_vendor_universal` for the universal '
  'click-through; `inbound_vendor_<vendor_id>` for per-vendor '
  'click-throughs. Other product surfaces add new scope tokens '
  'rather than overloading existing ones.';

comment on column public.tos_versions.superseded_by_version_id is
  'Phase 9.8 — points at the next version when this one is replaced. '
  'Null for the active version. Never delete a superseded row; '
  'audit reads need to render the exact text the operator saw.';

-- Reads are operator-agnostic — the click-through screen pulls the
-- active version per scope. `forge_admin` and `service_role` may read.
revoke all on public.tos_versions from public;
grant select on public.tos_versions to service_role;
grant select on public.tos_versions to forge_admin;
-- Insert lives behind Phase 11A admin UI (later slice). For `11W.0`
-- only `forge_admin` may insert — manual seed via Phase 11A admin
-- console once the UI lands.
grant insert on public.tos_versions to forge_admin;

-- No RLS on tos_versions: the rows are operator-agnostic legal text.
-- Per-tenant scoping happens on `tos_acceptances` below.

-- ─── tos_acceptances ─────────────────────────────────────────────────
--
-- Append-only acceptance log. Each row captures one operator/user
-- agreement to one (scope, version_id) at one moment in time. The
-- click-through screen writes one row per acceptance event; an
-- operator who re-accepts a superseding version writes a new row
-- (the previous row stays in place).
--
-- (operator_id, user_id, version_id) is the audit key. ip_address +
-- user_agent capture the binding context. Schema mirrors the
-- per-tenant fact-table pattern from Phase 9.5.0 leaderboard.

create table if not exists public.tos_acceptances (
  acceptance_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null
    references public.operators(operator_id) on delete cascade,
  user_id uuid not null
    references public.users(user_id) on delete cascade,
  version_id uuid not null
    references public.tos_versions(version_id) on delete restrict,
  scope text not null
    check (
      char_length(scope) between 1 and 128
      and scope = btrim(scope)
    ),
  ip_address inet,
  user_agent text
    check (user_agent is null or char_length(user_agent) <= 1024),
  accepted_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

comment on table public.tos_acceptances is
  'Phase 9.8 — append-only acceptance log for inbound-vendor T&Cs. '
  'One row per (operator_id, user_id, version_id) acceptance event. '
  'Per-tenant RLS via wrapper functions (operator_id leading). '
  'Append-only at the grant shape — corrections write a new row.';

comment on column public.tos_acceptances.scope is
  'Phase 9.8 — denormalized from tos_versions.scope so per-scope '
  'queries (e.g. has-this-operator-accepted-universal) avoid a join '
  'in the hot path. Must match tos_versions.scope at write time; the '
  'repository asserts the invariant.';

comment on column public.tos_acceptances.user_agent is
  'Phase 9.8 — bounded to 1024 chars. The acceptance flow only '
  'captures the request UA; it does not collect anything beyond what '
  'the proxy already sees in HTTP request metadata.';

-- Operator-leading B-tree indexes — RLS folds into the index probe.
create index if not exists tos_acceptances_operator_user_idx
  on public.tos_acceptances (operator_id, user_id, accepted_at desc);

create index if not exists tos_acceptances_operator_scope_idx
  on public.tos_acceptances (operator_id, scope, accepted_at desc);

-- ─── RLS policies (wrapper-only per 9.0Σ.b) ─────────────────────────
--
-- Two policies: per-tenant SELECT and per-tenant INSERT. UPDATE/DELETE
-- have no policy AND no grants below — the table is append-only.
-- Mirrors `leaderboard_scores_per_tenant_*` from
-- 202605030000_phase_9_5_0_leaderboard_schema_rls.sql.

alter table public.tos_acceptances enable row level security;

drop policy if exists "tos_acceptances_per_tenant_select"
  on public.tos_acceptances;
drop policy if exists "tos_acceptances_per_tenant_insert"
  on public.tos_acceptances;

create policy "tos_acceptances_per_tenant_select"
  on public.tos_acceptances for select to service_role
  using (operator_id = public.app_current_operator());

create policy "tos_acceptances_per_tenant_insert"
  on public.tos_acceptances for insert to service_role
  with check (
    operator_id = public.app_current_operator()
    and user_id = public.app_current_actor_user()
  );

comment on policy "tos_acceptances_per_tenant_select"
  on public.tos_acceptances is
  'Phase 9.8 — tenants read only their own acceptance rows. '
  'Cross-operator audit reads (Phase 11A support paths) go through '
  'forge_admin BYPASSRLS via runAsSystem.';

comment on policy "tos_acceptances_per_tenant_insert"
  on public.tos_acceptances is
  'Phase 9.8 — acceptance rows may only be attributed to the '
  'tenant''s own operator AND the actor user from the GUC. The '
  'click-through screen runs inside the user''s tenant context, so '
  'the wrapper functions resolve to the values the row carries.';

-- ─── Append-only grants ─────────────────────────────────────────────
--
-- service_role + forge_admin get INSERT + SELECT only. UPDATE/DELETE
-- are explicitly REVOKEd; acceptance is a legal record.

revoke all on public.tos_acceptances from public;
grant select, insert on public.tos_acceptances to service_role;
grant select, insert on public.tos_acceptances to forge_admin;
revoke update, delete on public.tos_acceptances from service_role;
revoke update, delete on public.tos_acceptances from forge_admin;

commit;
