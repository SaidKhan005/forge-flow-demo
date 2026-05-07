-- Phase 8 mobile core logic: reservation demand / walk-in settings.
--
-- Authority:
--   * docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md
--   * docs/contracts/data_accuracy_settings_contract.md
--
-- Adds durable server-owned walk-in handling fields to
-- public.data_accuracy_settings. The row remains operator/location scoped
-- and mobile reads it through the proxy as a cache only.

begin;

alter table public.data_accuracy_settings
  add column if not exists walk_in_handling_mode text
    not null default 'reservations_only';

alter table public.data_accuracy_settings
  add column if not exists walk_in_manual_entries jsonb
    not null default '{}'::jsonb;

alter table public.data_accuracy_settings
  drop constraint if exists data_accuracy_settings_walk_in_mode_check;

alter table public.data_accuracy_settings
  add constraint data_accuracy_settings_walk_in_mode_check
    check (
      walk_in_handling_mode in (
        'reservations_only',
        'walk_ins_added_to_reservations',
        'walk_ins_tracked_separately'
      )
    );

alter table public.data_accuracy_settings
  drop constraint if exists data_accuracy_settings_walk_in_entries_object_check;

alter table public.data_accuracy_settings
  add constraint data_accuracy_settings_walk_in_entries_object_check
    check (jsonb_typeof(walk_in_manual_entries) = 'object');

comment on column public.data_accuracy_settings.walk_in_handling_mode is
  'Operator-selected reservation demand mode for locations where the POS does not expose covers.';

comment on column public.data_accuracy_settings.walk_in_manual_entries is
  'Sparse JSONB map keyed by ISO business_date to operator-entered walk-in count.';

commit;
