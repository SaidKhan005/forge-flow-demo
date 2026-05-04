-- Phase 8.0.lifecycle — vendor_lifecycle_notification table.
--
-- Backs the Operator Web vendor picker "Notify me when ready" capture
-- on `documented` / `sandbox_verified` vendor rows per
-- `docs/phases/phase_8/vendor_connections_admin_surface.md`
-- ("Backend UX exposure" → "Notify me when ready"). The fan-out cron
-- + email template wiring lands in the `9.8.email` follow-up; this
-- slice ships only the table the picker writes into.
--
-- Hard rules carried verbatim from CLAUDE.md / phase docs:
--
--   1. **HP #4 RLS-Ready Schema.** The table carries `operator_id`
--      from creation; the primary B-tree index leads with
--      `operator_id` (CLAUDE.md / 9.0Σ.b item 4); CI lint enforces.
--      Operator-scoped only — no `location_id` column. Notifications
--      are operator-level subscriptions ("when Toast is ready, email
--      this operator's admin"), not per-(operator, location) facts.
--
--   2. **Wrapper-only RLS posture (Phase 9.0Σ.b item 4 +
--      `docs/contracts/hardening_rls_and_repository_pattern_contract.md`).**
--      Every policy body calls the locked
--      `STABLE LEAKPROOF PARALLEL SAFE` wrappers
--      (`app_current_operator`); bare `current_setting()` is forbidden.
--
--   3. **Time guardrail (CLAUDE.md / 7.55 Rule 11).** UTC instants
--      stored as `TIMESTAMPTZ`; the bare-timestamp column type is
--      banned in operator-scoped tables.
--
--   4. **Idempotent migration.** `if not exists` on every CREATE,
--      `drop policy if exists` before `create policy`.

begin;

-- ─── vendor_lifecycle_notification ─────────────────────────────────
--
-- One row per (operator_id, vendor_id, email) "Notify me when this
-- vendor is ready" subscription. The Operator Web vendor picker
-- inserts a row when an operator admin taps **Notify me** on a vendor
-- row whose `VendorCapabilityProfile.lifecycle` is
-- `documented` or `sandbox_verified`. A `9.8.email` follow-up cron
-- fans out a `vendor_now_available` email when the vendor's
-- `*.live.prod` slice promotes lifecycle to
-- `production_credentialed`, and writes `notified_at` so subsequent
-- promotions do not double-send.

create table if not exists public.vendor_lifecycle_notification (
  notification_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null
    references public.operators(operator_id)
    on delete cascade,
  vendor_id text not null
    check (
      char_length(vendor_id) between 1 and 64
      and vendor_id = btrim(vendor_id)
    ),
  email text not null
    check (
      char_length(email) between 3 and 320
      and email = btrim(email)
      and position('@' in email) > 1
    ),
  requested_at timestamptz not null default now(),
  notified_at timestamptz
);

comment on table public.vendor_lifecycle_notification is
  'Phase 8.0.lifecycle — Operator Web vendor-picker "Notify me when '
  'ready" capture. One row per (operator_id, vendor_id, email) '
  'subscription against a vendor whose VendorCapabilityProfile.lifecycle '
  'is documented or sandbox_verified. The 9.8.email follow-up cron '
  'fans out vendor_now_available emails on lifecycle promotion to '
  'production_credentialed and stamps notified_at. See '
  'docs/phases/phase_8/vendor_connections_admin_surface.md '
  '("Backend UX exposure" → "Notify me when ready").';

-- Primary B-tree leads with operator_id per the RLS-Ready Schema rule
-- (`OperatorScopedRepository<T>`-aligned planner pushdown). Doubles as
-- the per-(operator, vendor, email) UNIQUE constraint surfaced in the
-- vendor adapter slice contract.
create unique index if not exists vendor_lifecycle_notification_uniq
  on public.vendor_lifecycle_notification (operator_id, vendor_id, email);

-- Cron lookup for "subscriptions that have not yet been notified for
-- this vendor".
create index if not exists vendor_lifecycle_notification_pending_idx
  on public.vendor_lifecycle_notification (operator_id, vendor_id)
  where notified_at is null;

-- ─── RLS policy stub (wrapper-only per 9.0Σ.b) ─────────────────────

alter table public.vendor_lifecycle_notification enable row level security;

drop policy if exists "vendor_lifecycle_notification_per_tenant"
  on public.vendor_lifecycle_notification;
create policy "vendor_lifecycle_notification_per_tenant"
  on public.vendor_lifecycle_notification for all to service_role
  using (operator_id = public.app_current_operator())
  with check (operator_id = public.app_current_operator());

-- ─── Grants ────────────────────────────────────────────────────────

revoke all on public.vendor_lifecycle_notification from public;
grant select, insert, update on public.vendor_lifecycle_notification
  to service_role;
grant select, insert, update on public.vendor_lifecycle_notification
  to forge_admin;

commit;
