-- B10.1 - vendor_applicability.
--
-- One temporal, discriminated source for "which vendors can apply to
-- setting X" across wage, covers, polling, and future setting kinds.
-- Global F&F-admin defaults use operator_id = NULL; per-operator rows carry
-- operator_id and are readable only through app_current_operator() RLS.

begin;

create table if not exists public.vendor_applicability (
  id uuid primary key default gen_random_uuid(),
  operator_id uuid null references public.operators(operator_id)
    on delete cascade,
  setting_kind text not null
    check (
      char_length(setting_kind) between 1 and 64
      and setting_kind = lower(setting_kind)
      and setting_kind = btrim(setting_kind)
      and setting_kind ~ '^[a-z][a-z0-9_]*$'
    ),
  setting_key text not null
    check (
      char_length(setting_key) between 1 and 128
      and setting_key = lower(setting_key)
      and setting_key = btrim(setting_key)
      and setting_key ~ '^[a-z][a-z0-9_:.+-]*$'
    ),
  vendor_slug text not null
    check (
      char_length(vendor_slug) between 1 and 64
      and vendor_slug = lower(vendor_slug)
      and vendor_slug = btrim(vendor_slug)
      and vendor_slug ~ '^[a-z][a-z0-9_]*$'
    ),
  enabled boolean not null default true,
  metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metadata) = 'object'),
  effective_from timestamptz not null default now(),
  effective_until timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid not null,
  constraint vendor_applicability_temporal_order_ck
    check (effective_until is null or effective_until > effective_from)
);

comment on table public.vendor_applicability is
  'B10.1 temporal source for per-setting vendor applicability. '
  'operator_id NULL rows are global F&F-admin defaults; operator rows are '
  'tenant-readable through app_current_operator() RLS. Writes are temporal: '
  'new state INSERTs a row and ending state sets effective_until.';

comment on column public.vendor_applicability.setting_kind is
  'Discriminator such as wage, covers, polling. App-layer metadata schemas '
  'must admit each kind before writes land.';

comment on column public.vendor_applicability.metadata is
  'Kind-specific JSONB metadata. Must remain schema-validated in '
  'lib/services/settings/applicability_metadata_schemas.dart so JSONB does '
  'not become an EAV escape hatch.';

-- History uniqueness is split so operator-scoped B-trees lead with operator_id
-- while global defaults still keep NULL operator rows unique.
create unique index if not exists vendor_applicability_history_operator_uq
  on public.vendor_applicability (
    operator_id,
    setting_kind,
    setting_key,
    vendor_slug,
    effective_from
  )
  where operator_id is not null;

create unique index if not exists vendor_applicability_history_global_uq
  on public.vendor_applicability (
    setting_kind,
    setting_key,
    vendor_slug,
    effective_from
  )
  where operator_id is null;

-- At most one currently-effective row per scope/kind/key/vendor.
create unique index if not exists vendor_applicability_current_operator_uq
  on public.vendor_applicability (
    operator_id,
    setting_kind,
    setting_key,
    vendor_slug
  )
  where operator_id is not null and effective_until is null;

create unique index if not exists vendor_applicability_current_global_uq
  on public.vendor_applicability (
    setting_kind,
    setting_key,
    vendor_slug
  )
  where operator_id is null and effective_until is null;

create index if not exists vendor_applicability_current_tenant_lookup_idx
  on public.vendor_applicability (
    operator_id,
    setting_kind,
    setting_key,
    enabled,
    vendor_slug
  )
  where effective_until is null;

create index if not exists vendor_applicability_current_global_lookup_idx
  on public.vendor_applicability (setting_kind, setting_key, enabled, vendor_slug)
  where operator_id is null and effective_until is null;

create index if not exists vendor_applicability_history_lookup_idx
  on public.vendor_applicability (
    operator_id,
    setting_kind,
    setting_key,
    vendor_slug,
    effective_from desc
  );

alter table public.vendor_applicability enable row level security;

drop policy if exists "vendor_applicability_per_tenant_select"
  on public.vendor_applicability;
drop policy if exists "vendor_applicability_service_role_select"
  on public.vendor_applicability;
create policy "vendor_applicability_service_role_select"
  on public.vendor_applicability for select to service_role
  using (
    operator_id is null
    or operator_id = public.app_current_operator()
  );

revoke all on public.vendor_applicability from public;
grant select on public.vendor_applicability to service_role;
grant select, insert, update on public.vendor_applicability to forge_admin;

commit;
