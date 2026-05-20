-- Data Accuracy reset delete grants.
--
-- Operator Web and the F&F admin console now have explicit reset flows
-- that clear a service-period override so the effective value can
-- inherit from the next scope. The keyed service-period table already
-- has tenant RLS and operator/location leading keys; this migration
-- only grants DELETE to the same roles that already insert/update rows.

begin;

grant delete on public.data_accuracy_service_period_settings to service_role;
grant delete on public.data_accuracy_service_period_settings to forge_admin;

commit;
