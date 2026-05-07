-- B2 async race fix — OAuth refresh advisory lock registry entry.
--
-- Findings reference: J4 — two Cloud Run pods both notice
-- `token_expires_at < now() + 24h` for the same (operator_id,
-- vendor_id) and both call the vendor's token endpoint; some
-- vendors auto-revoke the earlier token on a second refresh,
-- causing the first pod's subsequent API calls to 401.
--
-- Fix: wrap the per-(operator, vendor) refresh call in
-- `pg_advisory_xact_lock(<id>, hashtextextended(...))`. The lock
-- is transaction-scoped so it releases automatically on commit or
-- rollback — no explicit unlock needed.
--
-- This migration seeds the lock-id constant into the same
-- `audit_anchor_advisory_locks` constants table created by
-- `202605070200_audit_anchor_advisory_lock_infra.sql`.
-- That migration created the table; we only add a row here.
--
-- Lock id `8472002` is the next slot after the audit_anchor_sweep
-- id (`8472001`) from the infra migration. Both are deliberately-
-- distinctive integers in the low-8-digit range; collision with a
-- hashtext()-derived key is astronomically unlikely.
--
-- Authority:
--   * `db/migrations/202605070200_audit_anchor_advisory_lock_infra.sql`
--     (table creation + precedent for the pattern).
--   * `lib/services/integration/oauth_refresh_cron.dart`
--     (the runner that acquires this lock per (operator, vendor)).
--
-- Replay-safe: ON CONFLICT DO NOTHING makes re-running idempotent.

begin;

insert into public.audit_anchor_advisory_locks (lock_kind, lock_id)
  values ('oauth_refresh_lock', 8472002)
on conflict (lock_kind) do nothing;

comment on table public.audit_anchor_advisory_locks is
  'Code-Health Lane M3 — registry of stable advisory-lock ids used '
  'to serialize singleton background sweeps. Append-only by '
  'convention: rows may be added for future sweep kinds, but '
  'existing rows MUST NOT have their lock_id mutated (a live '
  'lock holder would silently lose its guarantee). Lane L9 reads '
  'the audit_anchor_sweep row; B2 race-fix reads oauth_refresh_lock.';

commit;
