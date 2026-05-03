-- Phase 9.8 — Email provider durable queue + delivery event log.
--
-- Owns three tables and one pg_cron job:
--
--   * `public.email_credentials` — single-row, F&F-platform-wide
--     SendGrid API key. The plaintext is encrypted at rest with
--     pgcrypto envelope on staging; production swaps in Cloud KMS
--     when 8.0's KMS rollout lands. Mirrors the
--     `provider_credentials` pattern (Phase 11A.4) but keeps the
--     SendGrid key in its own table because the rotation contract is
--     identical and the F&F platform-wide scope rules out the
--     operator-scoped tables.
--
--   * `public.email_outbox` — durable transactional queue. Producers
--     enqueue rows in the same transaction as the business write
--     (operator invite, password reset, vendor sync alert, etc.).
--     The `email_outbox_dispatcher` (lib/services/email) drains
--     pending rows on a 1-minute cadence, advances the status state
--     machine, and stamps `provider_message_id` on success.
--
--   * `public.email_event` — webhook delivery log. SendGrid event
--     webhooks (delivered, opened, clicked, bounced, complaint,
--     unsubscribe) land here so the admin "Test connection" flow
--     can confirm a test email actually reached the recipient and
--     so the dispatcher's 3-strike alert path has audit context.
--
-- Hard rules carried from CLAUDE.md and the slice doc:
--   1. RLS performance discipline — operator-scoped fact-table
--      indexes lead with `(operator_id, …)`. `email_outbox` carries
--      a partial index keyed on `operator_id` for operator-scoped
--      rows (`operator_id IS NOT NULL`) and a system-only index for
--      F&F-internal rows (`operator_id IS NULL`).
--   2. RLS uses the wrapper functions from 9.0Σ.b
--      (`public.app_current_operator()`); bare `current_setting()`
--      is forbidden by the lint in `tool/rls_policy_lint.dart`.
--   3. `TIMESTAMPTZ` everywhere; `TIMESTAMP WITHOUT TIME ZONE` is
--      banned in operator-scoped tables.
--   4. Per Hard Promise #7 — server-side keys only — the plaintext
--      column is `bytea` and stores `pgp_sym_encrypt(plaintext,
--      <env-injected key>)`. The migration does NOT hard-code the
--      symmetric key; the proxy bootstrap reads it from
--      `EMAIL_CREDENTIALS_ENVELOPE_KEY` (Cloud Run env / Secret
--      Manager) at runtime and decrypts on read. Production swaps
--      in Cloud KMS when 8.0's KMS rollout lands.
--   5. The pg_cron tick is NOTIFY-only (matches the rollups pattern
--      from `phase_9_0sigma_k_pg_cron_jobs.sql`). The Dart
--      dispatcher subscribes to `email_outbox_tick` and drains the
--      queue; the SQL function never claims rows itself.
--
-- Live apply: lands on staging first; production cutover waits for
-- DNS records on `mail.forgeflow.app` (DKIM, SPF, DMARC) and a
-- production SendGrid key.

begin;

-- ─── pgcrypto extension ──────────────────────────────────────────────
--
-- Required for `pgp_sym_encrypt` / `pgp_sym_decrypt`. The Phase 9.0Σ.j
-- migration installs `pgcrypto`; this DDL is idempotent so re-running
-- the slice on a host that already has the extension is a no-op.

create extension if not exists pgcrypto;

-- ─── email_credentials ────────────────────────────────────────────────
--
-- Single-row table holding the active SendGrid API key. New rotations
-- INSERT a fresh row and flip the prior row's `is_active` to false in
-- one transaction so a rotation failure cannot leave two active rows.
-- The partial unique index enforces "exactly one active row" at rest.
--
-- F&F platform-wide scope; no `operator_id`, no RLS policy. Reads /
-- writes flow through the admin pool (`forge_admin` BYPASSRLS); the
-- proxy route handler enforces the `super_admin` role gate on rotation
-- POSTs.
--
-- `provider_kind` is locked to `sendgrid` for V1; widening admits a
-- future Postmark / SES swap without changing the table shape (mirrors
-- how `provider_credentials.key_kind` widened to admit `gemini` in
-- 11A.4b).

create table if not exists public.email_credentials (
  credential_id uuid primary key default gen_random_uuid(),
  provider_kind text not null,
  masked_value text not null,
  encrypted_api_key bytea not null,
  kms_secret_name text null,
  created_by uuid null,
  updated_by uuid null,
  is_active boolean not null default true,
  rotated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint email_credentials_provider_kind_chk check (
    provider_kind in ('sendgrid')
  )
);

create unique index if not exists email_credentials_active_uq
  on public.email_credentials (provider_kind)
  where is_active;

create index if not exists email_credentials_provider_active_idx
  on public.email_credentials (provider_kind, is_active);

grant select, insert, update on public.email_credentials
  to forge_admin;

comment on table public.email_credentials is
  'Phase 9.8 — F&F platform-wide email-provider credential ledger. '
  'Mirrors provider_credentials but keeps the SendGrid key in its own '
  'table because the rotation contract is identical and the platform-wide '
  'scope rules out the operator-scoped tables. Plaintext lives in '
  'encrypted_api_key (pgcrypto envelope on staging; Cloud KMS once '
  '8.0 KMS rollout lands). Exactly one row per provider_kind has '
  'is_active = true at rest.';

-- ─── email_outbox ─────────────────────────────────────────────────────
--
-- Durable transactional queue. Producers enqueue rows in the same
-- transaction as the business write so a rolled-back business
-- transaction never strands a queued email.
--
-- Status state machine:
--   pending  → sending  → sent
--                       → failed
--                       → bounced     (set by webhook handler)
--                       → complaint   (set by webhook handler)
--
-- The dispatcher (lib/services/email/email_outbox_dispatcher.dart)
-- claims rows with `SELECT … FOR UPDATE SKIP LOCKED` and drives the
-- pending → sending → sent / failed transitions. Webhooks own the
-- final bounced / complaint transitions.
--
-- 3-strike rule: `attempt_count >= 3` flips status to `failed` and
-- emits an admin alert (handled in the dispatcher).

create table if not exists public.email_outbox (
  email_id uuid primary key default gen_random_uuid(),
  operator_id uuid null,
  user_id uuid null,
  recipient_email text not null
    check (char_length(recipient_email) between 3 and 320),
  recipient_display_name text null,
  template_id text not null
    check (char_length(template_id) between 1 and 100),
  template_data jsonb not null default '{}'::jsonb
    check (jsonb_typeof(template_data) = 'object')
    check (octet_length(template_data::text) <= 65536),
  scheduled_for timestamptz not null default now(),
  status text not null default 'pending'
    check (status in (
      'pending', 'sending', 'sent', 'failed', 'bounced', 'complaint'
    )),
  attempt_count integer not null default 0
    check (attempt_count >= 0),
  last_attempt_at timestamptz null,
  last_error text null,
  provider_message_id text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ─── Operator-leading claim index ────────────────────────────────────
--
-- The dispatcher's claim query is:
--
--   SELECT email_id, … FROM email_outbox
--    WHERE status = 'pending'
--      AND scheduled_for <= now()
--    ORDER BY scheduled_for, email_id
--    FOR UPDATE SKIP LOCKED
--    LIMIT @batch_size;
--
-- For operator-scoped emails the RLS predicate is folded in:
--
--    AND operator_id = public.app_current_operator()
--
-- The partial composite index `(operator_id, status, scheduled_for)`
-- handles operator-scoped reads with the operator_id leading column,
-- matching the per-tenant index policy in CLAUDE.md and Q22.
--
-- F&F-internal rows (operator_id IS NULL) — operator-onboarding
-- invites for the first admin, vendor-sync alerts to platform staff —
-- get a separate partial index that does not lead with operator_id
-- because the column is null. The dispatcher's admin pool runs
-- `runAsSystem`, bypassing RLS, so these rows are reachable without a
-- tenant-leading index.

create index if not exists email_outbox_tenant_pending_idx
  on public.email_outbox (operator_id, status, scheduled_for)
  where operator_id is not null;

create index if not exists email_outbox_system_pending_idx
  on public.email_outbox (status, scheduled_for)
  where operator_id is null;

create index if not exists email_outbox_provider_message_id_idx
  on public.email_outbox (provider_message_id)
  where provider_message_id is not null;

-- ─── pg_notify trigger ────────────────────────────────────────────────
--
-- Fires AFTER INSERT for rows with `status='pending'` so the
-- dispatcher wakes immediately rather than waiting up to a minute for
-- the next pg_cron tick. The notification payload is intentionally
-- small — the dispatcher reads the full row from the table on claim,
-- not from the notification.

create or replace function public.email_outbox_notify()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'pending' then
    perform pg_notify(
      'email_outbox',
      json_build_object(
        'email_id', new.email_id,
        'operator_id', new.operator_id,
        'template_id', new.template_id,
        'scheduled_for', new.scheduled_for
      )::text
    );
  end if;
  return null;
end;
$$;

comment on function public.email_outbox_notify() is
  'Phase 9.8 — fires pg_notify(''email_outbox'', ...) after every '
  'pending email_outbox INSERT. Payload is a small JSON envelope; the '
  'dispatcher reads the full row from email_outbox on claim. NOTIFY '
  'is a wake-up signal only — durability lives in the table.';

drop trigger if exists email_outbox_notify_trg on public.email_outbox;
create trigger email_outbox_notify_trg
after insert on public.email_outbox
for each row execute function public.email_outbox_notify();

-- ─── RLS policies (wrapper-only per 9.0Σ.b) ─────────────────────────
--
-- Operator-scoped rows are visible only to the matching tenant; F&F
-- internal rows (operator_id IS NULL) are visible only via
-- `forge_admin` BYPASSRLS through `runAsSystem`, never through the
-- tenant pool. Service principals that need to enqueue cross-operator
-- rows (system templates) run through the admin pool, not service_role.

alter table public.email_outbox enable row level security;

create policy "email_outbox_per_tenant_select"
  on public.email_outbox for select to service_role
  using (
    operator_id is not null
    and operator_id = public.app_current_operator()
  );

create policy "email_outbox_per_tenant_modify"
  on public.email_outbox for all to service_role
  using (
    operator_id is not null
    and operator_id = public.app_current_operator()
  )
  with check (
    operator_id is not null
    and operator_id = public.app_current_operator()
  );

comment on policy "email_outbox_per_tenant_select" on public.email_outbox is
  'Phase 9.8 — tenants see only their own outbox rows. Cross-tenant '
  'reads (and F&F-internal rows with operator_id IS NULL) require '
  'forge_admin BYPASSRLS via runAsSystem.';

comment on policy "email_outbox_per_tenant_modify" on public.email_outbox is
  'Phase 9.8 — INSERT/UPDATE/DELETE filtered by '
  'app_current_operator() so producers cannot enqueue cross-tenant '
  'rows and the dispatcher cannot mutate another operator''s row '
  'state. Forbidden cross-tenant attempts fail at WITH CHECK.';

grant select, insert, update on public.email_outbox to service_role;
grant select, insert, update on public.email_outbox to forge_admin;

comment on table public.email_outbox is
  'Phase 9.8 — durable transactional email queue. Producers enqueue '
  'in the same transaction as the business write; dispatcher claims '
  'rows via SELECT … FOR UPDATE SKIP LOCKED, drives the pending → '
  'sending → sent / failed state machine on a 1-minute cadence, and '
  'webhooks own the bounced / complaint transitions. 3-strike retry '
  'limit; attempt_count >= 3 flips status to failed with admin alert.';

-- ─── email_event ──────────────────────────────────────────────────────
--
-- Webhook delivery log. SendGrid event webhooks land here so the
-- admin "Test connection" flow can confirm a test email actually
-- reached the recipient and so the dispatcher's 3-strike alert path
-- has audit context.
--
-- One row per webhook event; SendGrid emits multiple events per
-- email (processed, delivered, opened, clicked) so a single
-- email_outbox row can have many email_event rows.

create table if not exists public.email_event (
  event_id uuid primary key default gen_random_uuid(),
  email_id uuid null references public.email_outbox(email_id) on delete cascade,
  provider_message_id text null,
  event_kind text not null
    check (event_kind in (
      'processed', 'delivered', 'opened', 'clicked',
      'bounced', 'complaint', 'unsubscribed', 'dropped',
      'deferred', 'unknown'
    )),
  event_payload jsonb not null default '{}'::jsonb
    check (jsonb_typeof(event_payload) = 'object'),
  occurred_at timestamptz not null,
  received_at timestamptz not null default now()
);

create index if not exists email_event_email_id_idx
  on public.email_event (email_id, occurred_at);

create index if not exists email_event_provider_message_id_idx
  on public.email_event (provider_message_id, occurred_at)
  where provider_message_id is not null;

alter table public.email_event enable row level security;

create policy "email_event_per_tenant_select"
  on public.email_event for select to service_role
  using (
    exists (
      select 1
        from public.email_outbox o
       where o.email_id = email_event.email_id
         and o.operator_id is not null
         and o.operator_id = public.app_current_operator()
    )
  );

comment on policy "email_event_per_tenant_select" on public.email_event is
  'Phase 9.8 — tenants see only events for their own emails. F&F '
  'internal events (email_id linking to operator_id IS NULL or '
  'email_id IS NULL) reachable via forge_admin BYPASSRLS.';

grant select, insert on public.email_event to service_role;
grant select, insert on public.email_event to forge_admin;

comment on table public.email_event is
  'Phase 9.8 — SendGrid webhook delivery event log. One row per '
  'inbound webhook event (processed / delivered / opened / clicked / '
  'bounced / complaint / unsubscribed). Joined back to email_outbox '
  'via email_id (preferred) or provider_message_id (fallback when '
  'the row was already deleted / aged out).';

-- ─── pg_cron schedule (NOTIFY-only kickoff) ───────────────────────────
--
-- Mirrors the rollups pattern: the SQL function emits a
-- pg_notify('email_outbox_tick', …) envelope; the Dart dispatcher
-- subscribes via LISTEN and drains the queue with
-- `EmailOutboxDispatcher.drainBatch()`. The cron stub never claims
-- rows itself — that would starve the worker by holding the lease
-- past the next tick.
--
-- Schedule: every minute. Slice doc § "pg_cron worker": "1-min cadence".

create or replace function public.email_outbox_tick()
returns void
language plpgsql
as $$
begin
  perform pg_notify(
    'email_outbox_tick',
    json_build_object(
      'fired_at', now()
    )::text
  );
end;
$$;

comment on function public.email_outbox_tick() is
  'Phase 9.8 — cron-callable wake-up signal for the email dispatcher. '
  'Emits pg_notify(''email_outbox_tick'', …) only; the Dart '
  'EmailOutboxDispatcher claims rows via SELECT … FOR UPDATE SKIP '
  'LOCKED and drives the state machine. The cron stub MUST NOT claim '
  'rows itself — doing so would starve the dispatcher.';

grant execute on function public.email_outbox_tick() to forge_admin;

do $$
declare
  v_jobid bigint;
begin
  if to_regnamespace('cron') is null
     or to_regclass('cron.job') is null then
    raise notice
      'pg_cron metadata is not in this database; schedule from cron.database_name with cron.schedule_in_database(..., ''forgeflow'')';
    return;
  end if;

  for v_jobid in
    select jobid from cron.job where jobname = 'forge_email_outbox_tick'
  loop
    perform cron.unschedule(v_jobid);
  end loop;
  perform cron.schedule(
    'forge_email_outbox_tick',
    '* * * * *',
    'select public.email_outbox_tick();'
  );
end$$;

commit;
