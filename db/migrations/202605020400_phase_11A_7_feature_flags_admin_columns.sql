-- Phase 11A.7 — feature_flags admin columns.
--
-- The 11A.7 admin Feature Flags screen needs three additional columns
-- on `public.feature_flags` that the launch schema in
-- `db/migrations/202604250005_advisor_cloud_foundation.sql` did not
-- carry:
--
--   * `kind` text not null default 'standard'
--     Marks a flag as `standard` (default) or `destructive`. The admin
--     UX renders a DANGER chip for destructive flags and forces a
--     confirm-by-typing-flag-name dialog before letting a super_admin
--     toggle one. Examples: `circuit_breaker_open`, future Phase 12
--     workflow kill switches. The classification lives on the row so
--     the screen does not need a hard-coded allowlist that drifts.
--
--   * `description` text null
--     One-line operator-facing description for the flag list. Optional
--     so the existing seeded rows (which were created without a
--     description) keep working.
--
--   * `updated_by` text null
--     Stores the `user_id` (UUID-shaped string) of the actor who last
--     toggled the flag. Used by the screen to render the "last toggle"
--     metadata column. Plain `text` (not `uuid`) so service-principal
--     toggles can carry the `sp:<id>` shape used by item 14, and so
--     migration-only seeds can leave it null without a CHECK violation.
--     Full-fidelity attribution still flows through `audit_logs` /
--     `auth_events_audit` — this column is the cheap denormalized
--     read for the admin grid.
--
-- Idempotent: every column add uses `if not exists`, every column
-- comment uses `comment on column`, and the destructive-flag seed
-- update uses `where kind <> 'destructive'` so re-applies don't
-- bounce the column for an operator override (a super_admin who
-- intentionally re-classified a flag through the 11A.7 admin UX).

begin;

alter table public.feature_flags
  add column if not exists kind text not null default 'standard';

alter table public.feature_flags
  add column if not exists description text null;

alter table public.feature_flags
  add column if not exists updated_by text null;

-- The CHECK constraint pins `kind` to the two known values so a
-- typo in a future seed cannot create a `destructie` row that
-- silently drops the DANGER UX. Drop-and-recreate for idempotency.
alter table public.feature_flags
  drop constraint if exists feature_flags_kind_check;
alter table public.feature_flags
  add constraint feature_flags_kind_check
  check (kind in ('standard', 'destructive'));

comment on column public.feature_flags.kind is
  '11A.7 admin classification: standard (default) or destructive. '
  'Destructive flags surface a DANGER chip and require a '
  'confirm-by-typing dialog in the admin Feature Flags screen.';
comment on column public.feature_flags.description is
  '11A.7 admin metadata: one-line operator-facing description '
  'rendered in the admin Feature Flags grid.';
comment on column public.feature_flags.updated_by is
  '11A.7 admin metadata: actor of last toggle (users.user_id UUID '
  'or sp:<service_principal_id>). Denormalized read for the grid; '
  'audit_logs / auth_events_audit hold the durable attribution.';

-- Reclassify the launch flags whose semantics are destructive
-- (operator-visible kill switches and rollback gates). Per-write
-- guard: only flip rows that haven't already been re-classified
-- by an operator override through the admin UX.
update public.feature_flags
  set kind = 'destructive'
  where flag_name in (
    'audit_logs_cutover_enabled',
    'kms_real_provider_anthropic_enabled',
    'kms_real_provider_voyage_enabled',
    'kms_real_provider_gemini_enabled',
    'kms_real_provider_azure_db_enabled'
  )
  and kind <> 'destructive';

commit;
