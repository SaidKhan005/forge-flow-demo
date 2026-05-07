-- Phase B6 (performance hardening, PF5) — NOTIFY channel split for per-category
-- listener fanout.
--
-- Current state (Phase 9.0Σ.e):
--   * All event_outbox rows fire NOTIFY on a single 'event_outbox' channel.
--   * The Phase 10a bridge worker LISTEN on 'event_outbox' and claims all rows
--     regardless of topic.
--
-- This slice:
--   * Splits the trigger so NOTIFY fires on a per-category channel based on
--     the row's `topic` prefix (e.g. 'pos.*' → 'event_outbox_pos',
--     'labor.*' → 'event_outbox_labor', etc.).
--   * Keeps the legacy 'event_outbox' channel as a fallback so a listener
--     that only LISTEN on the original channel continues to receive all events.
--   * Updates PackagePostgresOutboxListener to LISTEN on all four category
--     channels + the legacy channel so no events are lost.
--
-- Topic-to-channel mapping (locked in docs/contracts/event_outbox_contract.md):
--   * 'pos.*'         → 'event_outbox_pos'
--   * 'labor.*'       → 'event_outbox_labor'
--   * 'reservation.*' → 'event_outbox_reservation'
--   * 'admin.*'       → 'event_outbox_admin'
--   * All others      → 'event_outbox' (fallback)

begin;

-- Replace the trigger function to NOTIFY on per-category channels.
create or replace function public.event_outbox_notify()
returns trigger
language plpgsql
as $$
declare
  channel_name text;
begin
  -- Determine channel based on topic prefix.
  case
    when new.topic like 'pos.%' then
      channel_name := 'event_outbox_pos';
    when new.topic like 'labor.%' then
      channel_name := 'event_outbox_labor';
    when new.topic like 'reservation.%' then
      channel_name := 'event_outbox_reservation';
    when new.topic like 'admin.%' then
      channel_name := 'event_outbox_admin';
    else
      channel_name := 'event_outbox';
  end case;

  -- Notify on the category-specific channel.
  perform pg_notify(
    channel_name,
    json_build_object(
      'operator_id', new.operator_id,
      'topic', new.topic,
      'id', new.id
    )::text
  );

  -- Also notify on the legacy channel for backward compatibility.
  -- This ensures listeners that only LISTEN on 'event_outbox' still receive
  -- all events.
  perform pg_notify(
    'event_outbox',
    json_build_object(
      'operator_id', new.operator_id,
      'topic', new.topic,
      'id', new.id
    )::text
  );

  return null;
end;
$$;

comment on function public.event_outbox_notify() is
  'Phase B6 (PF5) — fires pg_notify on both per-category channel '
  '(event_outbox_pos, event_outbox_labor, event_outbox_reservation, '
  'event_outbox_admin based on topic prefix) and the legacy ''event_outbox'' '
  'channel for backward compatibility. Payload is a small JSON envelope '
  '(operator_id, topic, id); the Phase 10a bridge worker reads the full row '
  'from event_outbox on claim. NOTIFY is a wake-up signal only — durability '
  'lives in the table.';

commit;
