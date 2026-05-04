-- Phase 11A.1 follow-up -- operator/location admin runtime grants.
--
-- The F&F admin console runs operator, location, and operator-admin grant
-- writes through TenantTransactionWrapper.runAsSystem, which sets the
-- transaction role to forge_admin. BYPASSRLS skips tenant row policies, but it
-- does not grant table privileges, so live staging mutations fail before the
-- repository SQL can run unless forge_admin has explicit DML on these tables.

begin;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'forge_admin') then
    execute 'grant select, insert, update on public.operators to forge_admin';
    execute 'grant select, insert, update, delete on public.locations to forge_admin';
    execute 'grant select, insert, update, delete on public.operator_admins to forge_admin';
  end if;
end;
$$;

comment on table public.operators is
  'Cloud-foundation operator row. Tenant runtime keeps service_role read access; '
  '11A.1 admin-console operator lifecycle writes use forge_admin BYPASSRLS plus '
  'explicit SELECT/INSERT/UPDATE privilege.';

comment on table public.locations is
  'Cloud-foundation location row. Tenant runtime keeps service_role read access; '
  '11A.1 admin-console location lifecycle writes use forge_admin BYPASSRLS plus '
  'explicit SELECT/INSERT/UPDATE/DELETE privilege.';

comment on table public.operator_admins is
  'Cloud-foundation operator admin grant row. Tenant runtime keeps service_role '
  'read access; 11A.1 admin-console admin-grant lifecycle writes use forge_admin '
  'BYPASSRLS plus explicit SELECT/INSERT/UPDATE/DELETE privilege.';

commit;
