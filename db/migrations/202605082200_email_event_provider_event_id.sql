-- Phase 9.8 — SendGrid event-webhook idempotency column.
--
-- The 202605040200 migration created `public.email_event` without a
-- per-provider event id, so the row's only natural key was the
-- composite (`email_id`, `event_kind`, `occurred_at`, `event_payload`).
-- That tuple is not safe for dedupe: SendGrid's event webhook is
-- at-least-once, fan-outs to multiple regions can re-deliver the same
-- event, and the proxy's webhook handler MUST be able to recognise a
-- replay and return 200 without inserting a duplicate row.
--
-- This migration adds:
--
--   * `provider_event_id text null` — populated from SendGrid's
--     `sg_event_id` (per-event UUID, stable across retries). NULL is
--     allowed so the column is backfill-friendly and so a future
--     provider-swap (Postmark / SES) can leave it blank without
--     breaking the constraint.
--
--   * Partial UNIQUE index on the column (where `provider_event_id IS
--     NOT NULL`). The SendGrid webhook handler uses
--     `INSERT … ON CONFLICT (provider_event_id) DO NOTHING` so a
--     replayed event is a no-op.
--
-- No backfill is needed — `email_event` is empty in production
-- (the table ships with the dispatcher half of Phase 9.8 only; the
-- webhook half lands with this slice).
--
-- Authority:
--   * `db/migrations/202605040200_phase_9_8_email_provider.sql` —
--     original CREATE TABLE.
--   * `docs/phases/phase_9_8/phase_9_8_email_provider_slice.md` —
--     "Bounce / complaint webhook from SendGrid lands in `email_event`
--     and updates `email_outbox.status` accordingly."

begin;

alter table public.email_event
  add column if not exists provider_event_id text null;

create unique index if not exists email_event_provider_event_id_uq
  on public.email_event (provider_event_id)
  where provider_event_id is not null;

comment on column public.email_event.provider_event_id is
  'Provider-side event id used for webhook replay dedupe. SendGrid '
  'populates this from the `sg_event_id` field of the event payload. '
  'The webhook handler issues INSERT … ON CONFLICT (provider_event_id) '
  'DO NOTHING so a replayed event is a no-op. NULL when the source is '
  'a non-SendGrid provider that has no equivalent id.';

commit;
