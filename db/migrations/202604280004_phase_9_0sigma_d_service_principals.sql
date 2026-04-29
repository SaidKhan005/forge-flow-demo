-- Phase 9.0Σ.d — service_principals + auth_events_audit.actor_kind
-- (item 14 from `phase_9_scalability_decisions_2026-04-27.md`, parcel
-- B25 in `phase_9_execution_backlog.md`).
--
-- Two scope-locked changes land here:
--
--   1. `public.service_principals` — per-operator catalog of non-human
--      actors (workflow runtime, vendor webhooks, scheduled jobs,
--      system-health probes, F&F internal automation). Phase 9 schema
--      reserves the slot now so workflow tool calls in Phase 12 attach
--      to a stable identity. JWT issuance with `sp:` subject prefix
--      and the proxy verifier path are explicitly OUT of scope for
--      this slice — they land in a follow-up that touches
--      `tool/advisor_proxy/**`. This migration only owns the schema
--      so the repository contract and the actor_kind audit slot are
--      stable from now on.
--
--   2. `public.auth_events_audit.actor_kind text not null default
--      'user' CHECK (actor_kind in ('user','service'))` — completes
--      the audit attribution split: human actors keep `'user'`
--      (default backfills every existing row); future service-
--      principal-driven mutations write `'service'`. Without this
--      column, machine-driven auth events would silently masquerade
--      as their human owner and dispute reconstruction in Phase 9.8
--      compliance review would not be able to tell the two apart.
--
-- Hard rules carried from CLAUDE.md and the 4-27 lock:
--   * Tenant-leading B-tree indexes (item 4 / RLS performance
--     discipline). Every B-tree index here leads with `operator_id`.
--   * RLS reads tenant context through the 9.0Σ.b wrapper functions
--     (`public.app_current_operator()`); bare `current_setting()` in
--     policy bodies is forbidden by `tool/rls_policy_lint.dart`.
--   * `TIMESTAMPTZ` everywhere; `TIMESTAMP WITHOUT TIME ZONE` is
--     banned in operator-scoped tables (silent DST corruption).
--   * Same grant shape as the auth-table mutable surface — full DML
--     to `service_role` (proxy runtime) and `forge_admin` (BYPASSRLS
--     escape hatch via `runAsSystem`).
--
-- audit_logs ownership split: this slice DOES NOT create or ALTER
-- `audit_logs`. Phase 9.0Σ.f (B27) declares `audit_logs` and
-- includes `actor_kind` inline at creation. Adding actor_kind to a
-- not-yet-existing table here would either fail or pre-shape a table
-- that 9.0Σ.f then has to reconcile with — both worse than letting
-- 9.0Σ.f land it in one place.
--
-- Live apply status:
--   * Applied and verified on staging + Production1 on 2026-04-29 as part of
--     the Phase 9 `202604280000` through `202604280013` migration set.

begin;

-- ─── service_principals ──────────────────────────────────────────────
--
-- Per-operator catalog of non-human actors. The shape covers the five
-- launch use-cases item 14 names (workflow runtime / vendor webhook /
-- scheduled job / system-health probe / F&F internal automation)
-- without taking on lifecycle features that belong to a follow-up:
--
--   * `id`             — stable opaque identifier; the `sp:` JWT
--                        subject prefix in the follow-up slice will
--                        be `sp:<id>`. The follow-up does NOT need
--                        to add a column here.
--   * `operator_id`    — per-operator isolation. CASCADE on operator
--                        delete so principals cannot outlive their
--                        owning tenant.
--   * `name`           — human-readable label for the admin UI
--                        (lands in 11A). Unique per operator so
--                        admins cannot create two service principals
--                        with the same display name in one tenant.
--   * `scopes`         — jsonb array of permission keys the principal
--                        is granted. Stored as a JSON array (not a
--                        join table) per item 14 — service-principal
--                        scopes are small (<= 32 keys typical), the
--                        proxy verifier loads them once per request,
--                        and the audit row for a service-driven
--                        mutation can carry the principal's scope set
--                        without an extra round trip. The
--                        `jsonb_typeof(scopes) = 'array'` CHECK
--                        guards against a producer (or a direct
--                        service_role / forge_admin INSERT) writing
--                        an object/string/number/null body the
--                        repository decoder would reject.
--   * `created_at`     — issuance timestamp. TIMESTAMPTZ per the
--                        storage rule.
--   * `updated_at`     — bumped via the cloud_foundation trigger;
--                        used by the admin UI to show "last modified".
--   * `revoked_at`     — soft-revocation marker. Nullable: NULL means
--                        active; a value means the principal is no
--                        longer issued tokens. Never deleted because
--                        audit rows reference the id.
--
-- A future "rotate secret" / "rotate key id" lifecycle column will
-- land alongside the JWT issuance slice; deliberately omitted here
-- so this slice cannot accidentally smuggle in a key-management
-- surface.

create table if not exists public.service_principals (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  name text not null
    check (char_length(name) between 1 and 200),
  scopes jsonb not null default '[]'::jsonb
    -- Service-principal scopes are a flat list of permission-key
    -- strings; the array CHECK is enforced at the DB layer so any
    -- future producer that bypasses the repository (a direct
    -- service_role / forge_admin INSERT, a one-off admin migration)
    -- still cannot store an object/string/number body the verifier
    -- would have to special-case.
    check (jsonb_typeof(scopes) = 'array'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revoked_at timestamptz null,
  -- Tenant-scoped name uniqueness: two service principals in the
  -- same operator cannot share a display name. Cross-operator name
  -- clashes are fine (different tenants, different surfaces).
  unique (operator_id, name)
);

comment on table public.service_principals is
  'Phase 9.0Σ.d (item 14 / B25) — per-operator catalog of non-human '
  'actors (workflow runtime, vendor webhooks, scheduled jobs, '
  'system-health probes, F&F internal automation). JWT issuance with '
  '`sp:<id>` subject prefix + proxy verifier routing land in a '
  'follow-up slice; this migration only owns the schema so the '
  'audit attribution slot (`auth_events_audit.actor_kind`) and the '
  'repository contract are stable from now on.';

comment on column public.service_principals.scopes is
  'jsonb ARRAY of permission-key strings. The CHECK enforces array '
  'shape at the DB layer so a direct INSERT cannot store a body the '
  'verifier or repository decoder would have to special-case.';

comment on column public.service_principals.revoked_at is
  'NULL when active. A revoked principal is never deleted because '
  'audit rows reference its id; downstream verifier path will refuse '
  'to mint tokens once revoked_at is set.';

-- ─── Tenant-leading indexes (item 4 / RLS performance discipline) ───
--
-- Every B-tree index here leads with `operator_id` so the per-tenant
-- RLS policy folds into the index probe. The active-only partial
-- index keeps lookups for the common "list active service principals"
-- admin UI path off the revoked rows.

create index if not exists service_principals_operator_id_idx
  on public.service_principals (operator_id, id);

create index if not exists service_principals_operator_active_idx
  on public.service_principals (operator_id, created_at desc)
  where revoked_at is null;

-- ─── updated_at trigger ─────────────────────────────────────────────
--
-- Reuses the cloud-foundation `cloud_foundation_set_updated_at()`
-- function defined in 202604250005, matching the org_units pattern.

drop trigger if exists service_principals_set_updated_at
  on public.service_principals;
create trigger service_principals_set_updated_at
before update on public.service_principals
for each row execute function public.cloud_foundation_set_updated_at();

-- ─── RLS scaffolding ────────────────────────────────────────────────
--
-- Per-tenant RLS from creation. All policies use the wrapper
-- function from 202604280000 (item 4). Bare `current_setting()` is
-- forbidden by the lint at `tool/rls_policy_lint.dart`.
--
-- Policy posture matches the org_units / event_outbox pattern:
-- tenant SELECT/ALL via service_role; admin writes go through
-- forge_admin BYPASSRLS (never a separate policy).

alter table public.service_principals enable row level security;

drop policy if exists "service_principals_per_tenant"
  on public.service_principals;

create policy "service_principals_per_tenant"
  on public.service_principals for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

comment on policy "service_principals_per_tenant"
  on public.service_principals is
  'Phase 9.0Σ.d (item 14 / B25). Tenants see and mutate only their '
  'own service principals. Reads operator context via '
  'app_current_operator() wrapper (item 4) so the planner folds the '
  'predicate into the operator_id-leading index. forge_admin '
  'BYPASSRLS handles cross-tenant admin paths via runAsSystem.';

-- ─── Table privileges ───────────────────────────────────────────────
--
-- Mirrors the org_units / auth-table mutable-surface grant shape:
-- service_role + forge_admin both get full DML. RLS is the
-- per-tenant gate; without grants, RLS never gets a chance to
-- evaluate (PG checks privileges first). PUBLIC stays revoked.

grant select, insert, update, delete on public.service_principals to service_role;
grant select, insert, update, delete on public.service_principals to forge_admin;

-- ─── auth_events_audit.actor_kind ───────────────────────────────────
--
-- Adds the audit attribution slot promised by item 14. Default
-- `'user'` so every existing row backfills as a human actor. The
-- CHECK locks the value set to ('user', 'service') so a producer
-- cannot smuggle in a third actor_kind without a paired migration.
--
-- The CHECK is declared inline with the column so re-running this
-- migration (idempotent guard via `add column if not exists`) leaves
-- the column shape intact: the inline CHECK is created exactly when
-- the column is, and PG records the constraint with the column.
--
-- Scope guard: actor_kind is added ONLY here. `audit_logs` (B27 /
-- 9.0Σ.f) will declare its own `actor_kind` column inline at table
-- creation; this migration must not reach into a table that does
-- not yet exist.

alter table public.auth_events_audit
  add column if not exists actor_kind text not null default 'user'
    check (actor_kind in ('user', 'service'));

comment on column public.auth_events_audit.actor_kind is
  'Phase 9.0Σ.d (item 14 / B25) — actor attribution split. '
  '`user` (default) for human-driven events; `service` for events '
  'driven by a service principal (workflow runtime, vendor webhook, '
  'scheduled job, system-health probe, F&F internal automation).';

commit;
