-- Phase 8.0 — Inbound integration framework schema (V1 lean cut 2).
--
-- The framework slice for Phase 8 / 8R / 8.S. Adds the per-vendor
-- credential storage, connection state, watermark, sync log, webhook
-- idempotency + dead-letter, demo-mode state, and raw-payload
-- retention pattern. The first concrete vendor adapter (8.LSK,
-- 8R.LB, 8.S.QBT) plugs in via subsequent slices.
--
-- Hard rules carried verbatim from CLAUDE.md / phase docs:
--
--   1. **HP #1 transport-only.** No business-logic table is touched
--      here. We add a single `raw_payload JSONB` column to existing
--      canonical fact tables (sales / covers / punches /
--      reservations) and the new framework tables. No formula, no
--      read-service contract.
--
--   2. **HP #4 RLS-Ready Schema.** Every operator-scoped fact table
--      added here carries `(operator_id, location_id)` from creation.
--      Operator-leading B-tree indexes drive planner pushdown
--      (CLAUDE.md / 9.0Σ.b item 4); CI lint enforces.
--
--   3. **HP #7 server-side secrets.** `vendor_credentials` stores
--      the access/refresh-token envelope encrypted with `pgcrypto`
--      (`pgp_sym_encrypt`/`pgp_sym_decrypt`) using the symmetric key
--      stored in Cloud Run env. Production-grade KMS rollout is a
--      separate Production1 hardening lane, not part of Phase 8.0
--      V1 lean cut 2. Plaintext tokens never appear in the column or
--      in any read path; the Flutter clients never see them.
--
--   4. **Wrapper-only RLS posture (Phase 9.0Σ.b item 4).** Every
--      policy body calls the locked `STABLE LEAKPROOF PARALLEL SAFE`
--      wrappers (`app_current_operator`, `app_current_location`).
--
--   5. **Time guardrails (CLAUDE.md / 7.55 Rule 11).** UTC instants
--      are stored as `TIMESTAMPTZ`; denormalized `business_date`
--      `DATE` columns are computed at write from `location.timezone`
--      + `location.business_day_rollover_hour` via the IANA converter
--      in Dart. `TIMESTAMP WITHOUT TIME ZONE` is banned.
--
--   6. **3-state machine for `connector_connection.status`.** V1
--      lean cut: `connected` / `disconnected` / `error`. `connecting`
--      and `degraded` are explicit non-goals.
--
--   7. **V1 lean cut 2 (locked 2026-05-03,
--      `memory/project_v1_lean_cut_2_2026_05_03.md`).** No KMS
--      provider, no webhook signing-key rotation UI, no
--      `parse_warnings`/`parse_partial` columns, no per-(operator,
--      vendor) advisory lock on the OAuth cron, no 3-strike
--      `email_outbox` emit (cron writes audit_logs + flips status to
--      `error`), no SIGTERM graceful drain handler, no DLQ tile
--      surfaced in observability, single `raw_payload` JSONB column
--      with no per-month partitioning, no fixed-second
--      test-connection SLA. The `disconnect_reason` enum carries
--      only the four reasons that have a real-life trigger at V1.
--
--   8. **Idempotent migration.** `if not exists` on every CREATE,
--      `drop policy if exists` before `create policy`.

begin;

-- ─── vendor_credentials ────────────────────────────────────────────
--
-- Per-(operator, location, vendor, module) credential storage.
-- Plaintext NEVER lands in this table — pgcrypto envelope on
-- staging + production at V1.
--
-- `location_id` is nullable to support operator-wide OAuth grants
-- (Square / 7shifts / QuickBooks Time / ADP Workforce Now).

create table if not exists public.vendor_credentials (
  credential_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid,
  vendor_id text not null
    check (
      char_length(vendor_id) between 1 and 64
      and vendor_id = btrim(vendor_id)
    ),
  module text
    check (
      module is null
      or (char_length(module) between 1 and 64 and module = btrim(module))
    ),
  -- Encrypted at rest via `pgp_sym_encrypt(plaintext, env_secret)`.
  -- Production-grade KMS rollout is a separate Production1
  -- hardening lane. Plaintext NEVER appears on the read side:
  -- repository methods decrypt server-side only.
  access_token_ciphertext bytea,
  refresh_token_ciphertext bytea,
  token_expires_at timestamptz,
  metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metadata) = 'object')
    check (octet_length(metadata::text) <= 4096),
  -- Consecutive refresh failures. The OAuth refresh cron flips the
  -- related `connector_connection.status` to `'error'` and writes
  -- an `audit_logs` row once this hits 3. No email_outbox emit at
  -- V1 — operator sees the state in admin UI.
  consecutive_refresh_failures smallint not null default 0
    check (consecutive_refresh_failures >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text,
  updated_by text,
  constraint vendor_credentials_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
    deferrable initially deferred
);

comment on table public.vendor_credentials is
  'Phase 8.0 — per-(operator, location, vendor, module) credential '
  'storage for inbound integrations. Plaintext tokens never land in '
  'this table — pgcrypto envelope on staging + V1 production. '
  'Production-grade KMS rollout is a separate Production1 hardening '
  'lane.';

create unique index if not exists vendor_credentials_unique_idx
  on public.vendor_credentials
    (operator_id, coalesce(location_id, '00000000-0000-0000-0000-000000000000'::uuid),
     vendor_id, coalesce(module, ''));

create index if not exists vendor_credentials_operator_idx
  on public.vendor_credentials (operator_id, vendor_id, is_active);

create index if not exists vendor_credentials_expiring_idx
  on public.vendor_credentials (token_expires_at)
  where is_active = true and token_expires_at is not null;

-- ─── connector_connection ──────────────────────────────────────────
--
-- V1 lean cut 2: disconnect_reason enum carries only the four
-- reasons that map to a real-life trigger at V1.
-- `auto_disable_3_strike` was removed — the OAuth cron flips
-- `status = 'error'` on the third consecutive failure with no
-- separate enum value (operator-facing copy is the same regardless
-- of cause; the audit row carries the precise trigger).

create type public.connector_disconnect_reason as enum (
  'operator_action',
  'vendor_revoked',
  'vendor_endpoint_deprecated',
  'oauth_timeout'
);

create table if not exists public.connector_connection (
  connection_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  vendor_id text not null
    check (
      char_length(vendor_id) between 1 and 64
      and vendor_id = btrim(vendor_id)
    ),
  category text not null
    check (category in ('pos', 'labor', 'reservation')),
  status text not null
    check (status in ('connected', 'disconnected', 'error')),
  module text
    check (
      module is null
      or (char_length(module) between 1 and 64 and module = btrim(module))
    ),
  metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metadata) = 'object')
    check (octet_length(metadata::text) <= 4096),
  last_sync_at timestamptz,
  last_error_at timestamptz,
  last_error_message text,
  webhook_url_provisioned boolean not null default false,
  disconnect_reason public.connector_disconnect_reason,
  credential_id uuid
    references public.vendor_credentials(credential_id)
    on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text,
  updated_by text,
  constraint connector_connection_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade,
  constraint connector_connection_disconnect_reason_chk
    check (
      (status = 'connected' and disconnect_reason is null)
      or (status in ('disconnected', 'error') and disconnect_reason is not null)
    )
);

comment on table public.connector_connection is
  'Phase 8.0 — per-(operator, location, vendor) connection state. '
  '3-state V1 machine: connected / disconnected / error.';

create unique index if not exists connector_connection_unique_idx
  on public.connector_connection
    (operator_id, location_id, vendor_id, coalesce(module, ''));

create index if not exists connector_connection_operator_status_idx
  on public.connector_connection (operator_id, status, vendor_id);

create index if not exists connector_connection_operator_recent_idx
  on public.connector_connection (operator_id, last_sync_at desc);

-- ─── connector_sync_watermark ──────────────────────────────────────

create table if not exists public.connector_sync_watermark (
  watermark_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  connection_id uuid not null
    references public.connector_connection(connection_id)
    on delete cascade,
  resource text not null
    check (
      char_length(resource) between 1 and 32
      and resource = btrim(resource)
    ),
  last_synced_at timestamptz,
  last_modified_seen timestamptz,
  cursor_token text,
  updated_at timestamptz not null default now(),
  constraint connector_sync_watermark_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.connector_sync_watermark is
  'Phase 8.0 — per-(connection, resource) cursor. Updated AFTER every '
  'successful batch commit. Disconnect preserves these rows so '
  'reconnect resumes from where sync broke.';

create unique index if not exists connector_sync_watermark_unique_idx
  on public.connector_sync_watermark (connection_id, resource);

create index if not exists connector_sync_watermark_operator_idx
  on public.connector_sync_watermark (operator_id, connection_id);

-- ─── connector_sync_log ────────────────────────────────────────────
--
-- Append-only event log surfaced by the "View logs" modal. Retention
-- sweep is a follow-up; pg_partman registration lands when traffic
-- justifies it.

create table if not exists public.connector_sync_log (
  log_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  connection_id uuid not null
    references public.connector_connection(connection_id)
    on delete cascade,
  event_kind text not null
    check (event_kind in (
      'poll_success',
      'poll_error',
      'webhook_received',
      'webhook_rejected',
      'auth_refresh',
      'auth_refresh_failed',
      'rate_limit_retry',
      'connect',
      'disconnect',
      'test_connection',
      'sanity_drop'
    )),
  records_count integer,
  duration_ms integer,
  error_message text,
  payload_preview jsonb
    check (
      payload_preview is null
      or (
        jsonb_typeof(payload_preview) = 'object'
        and octet_length(payload_preview::text) <= 2048
      )
    ),
  occurred_at timestamptz not null default now(),
  constraint connector_sync_log_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.connector_sync_log is
  'Phase 8.0 — append-only sync event log. Retention sweep is a '
  'follow-up.';

create index if not exists connector_sync_log_operator_recent_idx
  on public.connector_sync_log (operator_id, occurred_at desc);

create index if not exists connector_sync_log_connection_recent_idx
  on public.connector_sync_log (connection_id, occurred_at desc);

-- ─── inbound_webhook_idempotency ───────────────────────────────────
--
-- V1 lean cut 2: no `parse_warnings` JSONB column, no
-- `parse_partial` flag. Malformed payload → drop + connector_sync_log
-- entry; do not poison the queue. No pg_partman per-month
-- partitioning at V1 — a follow-up slice can register pg_partman
-- when traffic justifies it.

create table if not exists public.inbound_webhook_idempotency (
  idempotency_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  vendor_id text not null
    check (
      char_length(vendor_id) between 1 and 64
      and vendor_id = btrim(vendor_id)
    ),
  vendor_event_id text not null
    check (
      char_length(vendor_event_id) between 1 and 256
      and vendor_event_id = btrim(vendor_event_id)
    ),
  received_at timestamptz not null default now(),
  processed boolean not null default false,
  attempt_count smallint not null default 0
    check (attempt_count >= 0),
  last_error_message text,
  constraint inbound_webhook_idempotency_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.inbound_webhook_idempotency is
  'Phase 8.0 — per-(vendor_id, operator_id, vendor_event_id) '
  'idempotency table. Second arrival of the same vendor_event_id '
  'short-circuits to no-op. No parse_warnings / parse_partial at V1 '
  '— malformed payloads drop + log via connector_sync_log.';

create unique index if not exists inbound_webhook_idempotency_unique_idx
  on public.inbound_webhook_idempotency
    (vendor_id, operator_id, vendor_event_id);

create index if not exists inbound_webhook_idempotency_operator_idx
  on public.inbound_webhook_idempotency (operator_id, received_at desc);

-- ─── inbound_webhook_dead_letter ───────────────────────────────────
--
-- V1 lean cut 2: the table stays; the operator-facing observability
-- tile does NOT ship at V1. Support reads via the proxy debug
-- console + audit logs.

create table if not exists public.inbound_webhook_dead_letter (
  dead_letter_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  vendor_id text not null
    check (
      char_length(vendor_id) between 1 and 64
      and vendor_id = btrim(vendor_id)
    ),
  vendor_event_id text not null
    check (
      char_length(vendor_event_id) between 1 and 256
      and vendor_event_id = btrim(vendor_event_id)
    ),
  payload_preview jsonb not null default '{}'::jsonb
    check (jsonb_typeof(payload_preview) = 'object')
    check (octet_length(payload_preview::text) <= 4096),
  failure_kind text not null
    check (failure_kind in (
      'signature_invalid',
      'replay_too_old',
      'binding_mismatch',
      'parse_error',
      'adapter_error',
      'idempotency_conflict',
      'sanity_drop'
    )),
  failure_message text,
  occurred_at timestamptz not null default now(),
  constraint inbound_webhook_dead_letter_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.inbound_webhook_dead_letter is
  'Phase 8.0 — webhook events that failed processing 3 times. '
  'Forensic record at V1; observability tile lands when operator '
  'volume justifies it.';

create index if not exists inbound_webhook_dead_letter_operator_recent_idx
  on public.inbound_webhook_dead_letter (operator_id, occurred_at desc);

create index if not exists inbound_webhook_dead_letter_failure_kind_idx
  on public.inbound_webhook_dead_letter (operator_id, failure_kind, occurred_at desc);

-- ─── demo_mode_state ───────────────────────────────────────────────

create table if not exists public.demo_mode_state (
  state_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  category text not null
    check (category in ('pos', 'labor', 'reservation')),
  is_demo boolean not null default true,
  flipped_to_live_at timestamptz,
  flipped_by_connection_id uuid
    references public.connector_connection(connection_id)
    on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint demo_mode_state_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.demo_mode_state is
  'Phase 8.0 — per-(operator, location, category) demo-mode flag. '
  'Default true; flips to false when first INTEGRATE connection '
  'reaches connected and first backfill commits >=1 record. '
  'Disconnect does NOT auto-revert.';

create unique index if not exists demo_mode_state_unique_idx
  on public.demo_mode_state (operator_id, location_id, category);

create index if not exists demo_mode_state_operator_idx
  on public.demo_mode_state (operator_id, category, is_demo);

-- ─── sanity_log (V1 lean cut 2) ────────────────────────────────────
--
-- Vendor timestamp sanity guard log. The adapter framework drops
-- events that fail `closed_at >= opened_at`,
-- `opened_at <= now() + 1 hour`, or
-- `opened_at >= now() - 90 days` (unless flagged as deliberate
-- backfill). The drop is logged here instead of being written as a
-- canonical fact + parse_partial flag (which iter1 did; V1 lean
-- cut 2 removes that pattern in favor of dropping at the boundary
-- + auditing here).

create table if not exists public.sanity_log (
  sanity_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  vendor_id text not null,
  vendor_event_id text not null,
  rule text not null
    check (rule in (
      'closed_before_opened',
      'opened_in_future',
      'opened_too_old'
    )),
  detected_at timestamptz not null default now(),
  payload_summary jsonb not null default '{}'::jsonb
    check (jsonb_typeof(payload_summary) = 'object')
    check (octet_length(payload_summary::text) <= 2048),
  constraint sanity_log_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.sanity_log is
  'Phase 8.0 (V1 lean cut 2) — adapter-boundary sanity-drop log. '
  'Vendor events that fail timestamp sanity rules land here and are '
  'NOT written as canonical facts.';

create index if not exists sanity_log_operator_recent_idx
  on public.sanity_log (operator_id, detected_at desc);

-- ─── raw_payload retention pattern ─────────────────────────────────
--
-- V1 lean cut 2: a single nullable `raw_payload JSONB` column on
-- canonical fact tables. No sibling `*_raw_payload` partitions, no
-- pg_partman per-month registration, no automatic retention sweep.
--
-- The `vendor_id` / `vendor_entity_id` / `vendor_modified_at`
-- columns drive fact-level idempotency. `parse_partial` was
-- removed in V1 lean cut 2 — partial payloads are logged + dropped
-- at the adapter boundary, not written as canonical facts with a
-- flag.

do $$
declare
  fact_table text;
begin
  for fact_table in select unnest(array[
      'shift_records',
      'cover_facts',
      'labor_punches',
      'reservation_facts'
    ])
  loop
    execute format(
      $f$
        do $check$
        begin
          if exists (
            select 1
              from information_schema.tables
             where table_schema = 'public'
               and table_name = %L
          ) then
            alter table public.%I
              add column if not exists vendor_id text,
              add column if not exists vendor_entity_id text,
              add column if not exists vendor_modified_at timestamptz,
              add column if not exists raw_payload jsonb;
          end if;
        end
        $check$;
      $f$,
      fact_table, fact_table
    );
    execute format(
      $f$
        do $check$
        begin
          if exists (
            select 1
              from information_schema.columns
             where table_schema = 'public'
               and table_name = %L
               and column_name = 'vendor_id'
          ) then
            create unique index if not exists %I
              on public.%I (operator_id, vendor_id, vendor_entity_id, vendor_modified_at)
              where vendor_id is not null
                and vendor_entity_id is not null
                and vendor_modified_at is not null;
          end if;
        end
        $check$;
      $f$,
      fact_table,
      fact_table || '_vendor_idempotency_idx',
      fact_table
    );
  end loop;
end
$$;

-- ─── RLS policies (wrapper-only per 9.0Σ.b) ────────────────────────

alter table public.vendor_credentials enable row level security;
alter table public.connector_connection enable row level security;
alter table public.connector_sync_watermark enable row level security;
alter table public.connector_sync_log enable row level security;
alter table public.inbound_webhook_idempotency enable row level security;
alter table public.inbound_webhook_dead_letter enable row level security;
alter table public.demo_mode_state enable row level security;
alter table public.sanity_log enable row level security;

drop policy if exists "vendor_credentials_per_tenant" on public.vendor_credentials;
create policy "vendor_credentials_per_tenant"
  on public.vendor_credentials for all to service_role
  using (operator_id = public.app_current_operator())
  with check (
    operator_id = public.app_current_operator()
    and (
      location_id is null
      or location_id = public.app_current_location()
    )
  );

drop policy if exists "connector_connection_per_tenant" on public.connector_connection;
create policy "connector_connection_per_tenant"
  on public.connector_connection for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

drop policy if exists "connector_sync_watermark_per_tenant"
  on public.connector_sync_watermark;
create policy "connector_sync_watermark_per_tenant"
  on public.connector_sync_watermark for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

drop policy if exists "connector_sync_log_per_tenant_select" on public.connector_sync_log;
drop policy if exists "connector_sync_log_per_tenant_insert" on public.connector_sync_log;
create policy "connector_sync_log_per_tenant_select"
  on public.connector_sync_log for select to service_role
  using (operator_id = public.app_current_operator());
create policy "connector_sync_log_per_tenant_insert"
  on public.connector_sync_log for insert to service_role
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

drop policy if exists "inbound_webhook_idempotency_per_tenant"
  on public.inbound_webhook_idempotency;
create policy "inbound_webhook_idempotency_per_tenant"
  on public.inbound_webhook_idempotency for all to service_role
  using (operator_id = public.app_current_operator())
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

drop policy if exists "inbound_webhook_dead_letter_per_tenant_select"
  on public.inbound_webhook_dead_letter;
drop policy if exists "inbound_webhook_dead_letter_per_tenant_insert"
  on public.inbound_webhook_dead_letter;
create policy "inbound_webhook_dead_letter_per_tenant_select"
  on public.inbound_webhook_dead_letter for select to service_role
  using (operator_id = public.app_current_operator());
create policy "inbound_webhook_dead_letter_per_tenant_insert"
  on public.inbound_webhook_dead_letter for insert to service_role
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

drop policy if exists "demo_mode_state_per_tenant" on public.demo_mode_state;
create policy "demo_mode_state_per_tenant"
  on public.demo_mode_state for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

drop policy if exists "sanity_log_per_tenant_select" on public.sanity_log;
drop policy if exists "sanity_log_per_tenant_insert" on public.sanity_log;
create policy "sanity_log_per_tenant_select"
  on public.sanity_log for select to service_role
  using (operator_id = public.app_current_operator());
create policy "sanity_log_per_tenant_insert"
  on public.sanity_log for insert to service_role
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

-- ─── Grants ────────────────────────────────────────────────────────

revoke all on public.vendor_credentials from public;
grant select, insert, update, delete on public.vendor_credentials to service_role;
grant select, insert, update, delete on public.vendor_credentials to forge_admin;

revoke all on public.connector_connection from public;
grant select, insert, update on public.connector_connection to service_role;
grant select, insert, update on public.connector_connection to forge_admin;

revoke all on public.connector_sync_watermark from public;
grant select, insert, update on public.connector_sync_watermark to service_role;
grant select, insert, update on public.connector_sync_watermark to forge_admin;

revoke all on public.connector_sync_log from public;
grant select, insert on public.connector_sync_log to service_role;
grant select, insert on public.connector_sync_log to forge_admin;
revoke update, delete on public.connector_sync_log from service_role;
revoke update, delete on public.connector_sync_log from forge_admin;

revoke all on public.inbound_webhook_idempotency from public;
grant select, insert, update on public.inbound_webhook_idempotency to service_role;
grant select, insert, update on public.inbound_webhook_idempotency to forge_admin;

revoke all on public.inbound_webhook_dead_letter from public;
grant select, insert on public.inbound_webhook_dead_letter to service_role;
grant select, insert on public.inbound_webhook_dead_letter to forge_admin;
revoke update, delete on public.inbound_webhook_dead_letter from service_role;
revoke update, delete on public.inbound_webhook_dead_letter from forge_admin;

revoke all on public.demo_mode_state from public;
grant select, insert, update on public.demo_mode_state to service_role;
grant select, insert, update on public.demo_mode_state to forge_admin;

revoke all on public.sanity_log from public;
grant select, insert on public.sanity_log to service_role;
grant select, insert on public.sanity_log to forge_admin;
revoke update, delete on public.sanity_log from service_role;
revoke update, delete on public.sanity_log from forge_admin;

-- ─── permission_keys seed for integrations.configure ───────────────
--
-- Mirrors `lib/auth/permission_keys.dart` and
-- `docs/contracts/auth_permission_key_catalog.md`. The schema is
-- (key, category, description, requires_mfa, frozen).

insert into public.permission_keys (key, category, description, requires_mfa, frozen)
values (
  'integrations.configure',
  'integrations',
  'Configure inbound vendor connections (POS / labor / reservation) '
  'on the per-(operator, location) Vendor Connections admin surface.',
  false,
  true
)
on conflict (key) do nothing;

insert into public.role_permissions (role_id, permission_key, effect)
select role_id, 'integrations.configure', 'allow'
  from public.roles
 where role_key in ('super_admin', 'operator_owner')
on conflict do nothing;

commit;
