-- Phase 9.0Σ.f B.2 — feature flag: audit_logs cutover gate.
--
-- Seeds a global-scope `feature_flags` row that gates the auth-event
-- fan-out into the hash-chained `public.audit_logs` table from the B.2
-- writer boundaries (the AuthEventsAuditRepository repository seam, the
-- B41 `PostgresServicePrincipalJwtIssuanceGateway` raw-SQL seam, and
-- the `InvitedUserActivationRepository` raw-SQL seam).
--
-- Default `enabled = true`. Toggle to `false` for a one-shot rollback
-- if a deploy surfaces an unexpected fan-out incident; the legacy
-- `auth_events_audit` writes continue unchanged on either side of the
-- flag, so the audit posture never has a gap.
--
-- Idempotent: a `not exists` guard skips the seed on re-apply so a
-- manual operator override (already-applied `false` for rollback)
-- survives the migration replay. Plain `on conflict` would not work
-- here — `feature_flags` enforces global-scope uniqueness through a
-- partial index (`feature_flags_global_scope_idx`), not a named
-- constraint, so `on conflict on constraint <name>` is unavailable.

begin;

insert into public.feature_flags (flag_name, operator_id, location_id, enabled)
select 'audit_logs_cutover_enabled', null, null, true
where not exists (
  select 1
    from public.feature_flags
   where flag_name = 'audit_logs_cutover_enabled'
     and operator_id is null
     and location_id is null
);

commit;
