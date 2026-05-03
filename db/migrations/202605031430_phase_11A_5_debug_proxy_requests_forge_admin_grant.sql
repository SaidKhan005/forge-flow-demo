-- Phase 11A.5 follow-up -- debug console proxy_requests grant.
--
-- The Debug Console request-log gateway runs through
-- TenantTransactionWrapper.runAsSystem, which sets the transaction role to
-- forge_admin. BYPASSRLS skips tenant row policies, but it does not grant table
-- privileges. The live staging route was returning 503 because forge_admin
-- could not SELECT from public.proxy_requests after the Phase 9.0Sigma.l RLS
-- hardening policy flip.

begin;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'forge_admin') then
    execute 'grant select on public.proxy_requests to forge_admin';
  end if;
end;
$$;

comment on table public.proxy_requests is
  'Advisor proxy idempotency/request ledger. Tenant runtime access stays under '
  'service_role RLS; 11A.5 Debug Console read-only admin inspection uses '
  'forge_admin BYPASSRLS plus explicit SELECT privilege.';

commit;
