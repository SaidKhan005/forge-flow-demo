-- Phase 9 live-closeout - auth_events_audit actor attribution repair.
--
-- The live proxy audit writer now records whether an auth event was initiated
-- by a human user or a service principal. Staging had the repository deployed
-- before these attribution columns existed, which caused MFA confirm to fail
-- at the audit insert boundary. Keep this migration intentionally narrow:
-- it unblocks current user-auth flows without creating the future
-- service_principals table.

alter table public.auth_events_audit
  add column if not exists actor_kind text not null default 'user';

alter table public.auth_events_audit
  add column if not exists actor_service_principal_id uuid null;

alter table public.auth_events_audit
  drop constraint if exists auth_events_audit_actor_kind_check;

alter table public.auth_events_audit
  add constraint auth_events_audit_actor_kind_check
  check (actor_kind in ('user', 'service'));

create index if not exists auth_events_audit_service_principal_idx
  on public.auth_events_audit (
    operator_id,
    actor_service_principal_id,
    occurred_at desc
  )
  where actor_service_principal_id is not null;

comment on column public.auth_events_audit.actor_kind is
  'Phase 9 live-closeout actor attribution. user for human Firebase ID-token events; service reserved for future sp: service-principal JWT events.';

comment on column public.auth_events_audit.actor_service_principal_id is
  'Reserved service-principal actor UUID for future sp: JWT flows. Null for human user events.';
