-- Mobile OS push notification support.
--
-- Adds operator/user-scoped device token storage plus a channel-specific
-- durable push outbox. Business notification creation still goes through
-- public.event_outbox; this table records the mobile-delivery sidecar
-- state so the event_outbox single delivered_at marker is not used as a
-- multi-consumer acknowledgement.
--
-- Plain device tokens are encrypted by the server-side repository with
-- pgp_sym_encrypt(..., MOBILE_PUSH_TOKEN_ENVELOPE_KEY). The client never
-- receives server credentials or Firebase service keys, and payload rows
-- carry only notification display/data fields, not device tokens.

begin;

create extension if not exists pgcrypto;

-- Needed for a composite FK that proves the denormalized operator_id and
-- user_id belong to the same user row.
create unique index if not exists users_operator_user_idx
  on public.users (operator_id, user_id);

create table if not exists public.mobile_push_tokens (
  push_token_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  user_id uuid not null,
  platform text not null
    check (platform in ('ios', 'android')),
  provider text not null default 'fcm'
    check (provider in ('fcm', 'apns')),
  app_variant text not null
    check (app_variant ~ '^[a-z][a-z0-9_]{0,63}$'),
  app_environment text not null
    check (app_environment ~ '^[a-z][a-z0-9_]{0,63}$'),
  installation_id text not null
    check (char_length(installation_id) between 1 and 128
      and installation_id = btrim(installation_id)),
  token_hash text not null
    check (token_hash ~ '^[0-9a-f]{64}$'),
  token_ciphertext bytea not null,
  token_key_ref text not null default 'pgcrypto:mobile_push_token_v1',
  token_last_four text null
    check (token_last_four is null or char_length(token_last_four) <= 8),
  client_info jsonb not null default '{}'::jsonb
    check (jsonb_typeof(client_info) = 'object')
    check (octet_length(client_info::text) <= 4096),
  enabled_at timestamptz not null default now(),
  disabled_at timestamptz null,
  revoked_at timestamptz null,
  last_registered_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  last_sent_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint mobile_push_tokens_operator_user_fk
    foreign key (operator_id, user_id)
    references public.users(operator_id, user_id)
    on delete cascade
);

comment on table public.mobile_push_tokens is
  'Operator/user-scoped mobile OS push token ledger. Stores token_hash '
  'for lookup/deduplication and token_ciphertext encrypted server-side '
  'with MOBILE_PUSH_TOKEN_ENVELOPE_KEY; clients never see server keys.';

create unique index if not exists mobile_push_tokens_installation_uq
  on public.mobile_push_tokens (
    operator_id,
    user_id,
    app_variant,
    app_environment,
    installation_id
  );

create index if not exists mobile_push_tokens_active_user_idx
  on public.mobile_push_tokens (
    operator_id,
    user_id,
    app_variant,
    app_environment,
    enabled_at desc
  )
  where revoked_at is null and disabled_at is null;

create index if not exists mobile_push_tokens_hash_idx
  on public.mobile_push_tokens (operator_id, token_hash);

drop trigger if exists mobile_push_tokens_updated_at_trg
  on public.mobile_push_tokens;
create trigger mobile_push_tokens_updated_at_trg
before update on public.mobile_push_tokens
for each row execute function public.auth_set_updated_at();

alter table public.mobile_push_tokens enable row level security;

drop policy if exists "mobile_push_tokens_per_tenant"
  on public.mobile_push_tokens;
create policy "mobile_push_tokens_per_tenant"
  on public.mobile_push_tokens for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

create table if not exists public.mobile_push_outbox (
  message_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  user_id uuid not null,
  source_outbox_id bigint null
    references public.event_outbox(id)
    on delete set null,
  source_topic text null
    check (source_topic is null or char_length(source_topic) between 1 and 200),
  dedupe_key text not null
    check (char_length(dedupe_key) between 1 and 200
      and dedupe_key = btrim(dedupe_key)),
  app_variant text not null
    check (app_variant ~ '^[a-z][a-z0-9_]{0,63}$'),
  app_environment text not null
    check (app_environment ~ '^[a-z][a-z0-9_]{0,63}$'),
  title text not null
    check (char_length(title) between 1 and 120),
  body text not null
    check (char_length(body) between 1 and 500),
  deeplink text null
    check (deeplink is null or char_length(deeplink) <= 512),
  data jsonb not null default '{}'::jsonb
    check (jsonb_typeof(data) = 'object')
    check (octet_length(data::text) <= 4096),
  scheduled_for timestamptz not null default now(),
  status text not null default 'pending'
    check (status in (
      'pending',
      'sending',
      'sent',
      'partial_failed',
      'failed',
      'cancelled'
    )),
  attempt_count integer not null default 0
    check (attempt_count >= 0),
  target_count integer not null default 0
    check (target_count >= 0),
  sent_count integer not null default 0
    check (sent_count >= 0),
  failed_count integer not null default 0
    check (failed_count >= 0),
  claimed_at timestamptz null,
  sent_at timestamptz null,
  failed_at timestamptz null,
  last_error text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint mobile_push_outbox_operator_user_fk
    foreign key (operator_id, user_id)
    references public.users(operator_id, user_id)
    on delete cascade,
  constraint mobile_push_outbox_counts_chk
    check (sent_count + failed_count <= target_count)
);

comment on table public.mobile_push_outbox is
  'Durable mobile OS push delivery queue. Producers reference the '
  'business event_outbox row via source_outbox_id when available; the '
  'sender claims this queue and records retry/delivery state.';

create unique index if not exists mobile_push_outbox_dedupe_uq
  on public.mobile_push_outbox (operator_id, dedupe_key);

create index if not exists mobile_push_outbox_pending_idx
  on public.mobile_push_outbox (
    operator_id,
    status,
    scheduled_for,
    message_id
  )
  where status in ('pending', 'partial_failed');

drop trigger if exists mobile_push_outbox_updated_at_trg
  on public.mobile_push_outbox;
create trigger mobile_push_outbox_updated_at_trg
before update on public.mobile_push_outbox
for each row execute function public.auth_set_updated_at();

alter table public.mobile_push_outbox enable row level security;

drop policy if exists "mobile_push_outbox_per_tenant"
  on public.mobile_push_outbox;
create policy "mobile_push_outbox_per_tenant"
  on public.mobile_push_outbox for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

revoke all on public.mobile_push_tokens from public;
revoke all on public.mobile_push_outbox from public;

grant select, insert, update on public.mobile_push_tokens to service_role;
grant select, insert, update on public.mobile_push_tokens to forge_admin;

grant select, insert, update on public.mobile_push_outbox to service_role;
grant select, insert, update on public.mobile_push_outbox to forge_admin;

commit;
