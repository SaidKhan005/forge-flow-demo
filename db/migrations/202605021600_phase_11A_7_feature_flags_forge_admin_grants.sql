-- Phase 11A.7 follow-up -- feature_flags runtime grants.
--
-- The admin Feature Flags repository and the proxy startup/runtime flag
-- checks run through TenantTransactionWrapper.withSystem, which sets the
-- transaction role to forge_admin. BYPASSRLS skips row policies, but it does
-- not grant table privileges, so forge_admin still needs explicit
-- SELECT/UPDATE on public.feature_flags.

begin;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'forge_admin') then
    execute 'grant select, update on public.feature_flags to forge_admin';
  end if;
end;
$$;

commit;
