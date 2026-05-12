-- Admin audit-log actor/reason contract.
--
-- The original Phase 9 audit ledger shipped with the historical
-- `user` / `service` actor_kind pair. The admin hierarchy and team parity
-- contracts now need explicit human-friendly actor classes:
-- `team_member`, `forge_admin`, and `service_principal`. Keep the legacy
-- labels valid during the transition because existing non-admin writers still
-- emit them, but require `admin_reason` on every forge_admin ledger row.

begin;

alter table public.auth_events_audit
  drop constraint if exists auth_events_audit_actor_kind_check;

alter table public.auth_events_audit
  add constraint auth_events_audit_actor_kind_check
  check (
    actor_kind in (
      'user',
      'team_member',
      'forge_admin',
      'service',
      'service_principal',
      'system'
    )
  ) not valid;

alter table public.auth_events_audit
  validate constraint auth_events_audit_actor_kind_check;

alter table public.audit_logs
  add column if not exists admin_reason text;

alter table public.audit_logs
  drop constraint if exists audit_logs_actor_kind_check;

alter table public.audit_logs
  add constraint audit_logs_actor_kind_check
  check (
    actor_kind in (
      'user',
      'team_member',
      'forge_admin',
      'service',
      'service_principal'
    )
  ) not valid;

alter table public.audit_logs
  validate constraint audit_logs_actor_kind_check;

alter table public.audit_logs
  drop constraint if exists audit_logs_actor_shape_check;

alter table public.audit_logs
  add constraint audit_logs_actor_shape_check check (
    (actor_kind in ('user', 'team_member', 'forge_admin')
      and actor_user_id is not null
      and actor_principal_id is null)
    or
    (actor_kind in ('service', 'service_principal')
      and actor_principal_id is not null
      and actor_user_id is null)
  ) not valid;

alter table public.audit_logs
  validate constraint audit_logs_actor_shape_check;

alter table public.audit_logs
  drop constraint if exists audit_logs_admin_reason_check;

alter table public.audit_logs
  add constraint audit_logs_admin_reason_check check (
    (actor_kind = 'forge_admin' and nullif(btrim(admin_reason), '') is not null)
    or
    (actor_kind <> 'forge_admin' and admin_reason is null)
  ) not valid;

alter table public.audit_logs
  validate constraint audit_logs_admin_reason_check;

comment on column public.audit_logs.actor_kind is
  'Actor kind for hash-chained audit rows: user/team_member, forge_admin, or service/service_principal. user/service are legacy aliases retained during migration.';

comment on column public.auth_events_audit.actor_kind is
  'Actor kind for auth-event audit rows: user/team_member, forge_admin, service/service_principal, or system. user/service are legacy aliases retained during migration.';

comment on column public.audit_logs.admin_reason is
  'Required human-entered reason for F&F admin (forge_admin) hash-chain audit rows; null for non-admin actors.';

commit;
