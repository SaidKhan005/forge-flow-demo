-- Hardening: re-key 5 fact-table B-tree indexes that lead with a
-- non-operator_id column so the operator-leading discipline (CLAUDE.md
-- "RLS-Ready Schema" section) is enforced repo-wide. Per-tenant index
-- probes degrade into per-row filters when the leading column is not
-- operator_id; the lint at tool/index_leading_column_lint.dart fails
-- the build until each violation is rekeyed.
--
-- Affected indexes (all 5 originate from Phase 8 / Phase 9.8 V1
-- migrations that landed before the lint was wired up):
--
--   1. vendor_credentials_expiring_idx
--      (db/migrations/202605040000_phase_8_0_integration_framework.sql:127)
--      Original: (token_expires_at) WHERE is_active AND token_expires_at IS NOT NULL.
--      Rekey:    (operator_id, token_expires_at) preserving the same WHERE.
--
--   2. connector_sync_watermark_unique_idx (UNIQUE)
--      (db/migrations/202605040000_phase_8_0_integration_framework.sql:234)
--      Original: UNIQUE (connection_id, resource).
--      Rekey:    UNIQUE (operator_id, connection_id, resource).
--      `connection_id` is itself globally unique (PK on
--      connector_connection), so prepending operator_id preserves the
--      uniqueness contract without weakening it.
--
--   3. connector_sync_log_connection_recent_idx
--      (db/migrations/202605040000_phase_8_0_integration_framework.sql:292)
--      Original: (connection_id, occurred_at desc).
--      Rekey:    (operator_id, connection_id, occurred_at desc).
--
--   4. inbound_webhook_idempotency_unique_idx (UNIQUE)
--      (db/migrations/202605040000_phase_8_0_integration_framework.sql:334)
--      Original: UNIQUE (vendor_id, operator_id, vendor_event_id).
--      Rekey:    UNIQUE (operator_id, vendor_id, vendor_event_id).
--      Same column set, operator_id promoted to leading position. The
--      uniqueness contract is identical because UNIQUE constraints are
--      defined by the set of columns, not their order.
--
--   5. email_outbox_provider_message_id_idx
--      (db/migrations/202605040200_phase_9_8_email_provider.sql:197)
--      Original: (provider_message_id) WHERE provider_message_id IS NOT NULL.
--      Rekey:    (operator_id, provider_message_id) WHERE provider_message_id IS NOT NULL.
--      The webhook handler that resolves provider_message_id back to
--      an email_outbox row already runs under runAsSystem (BYPASSRLS)
--      for system rows; for operator-scoped rows the operator_id
--      leading column matches the per-tenant claim path.
--
-- ─── ORDERING is load-bearing ────────────────────────────────────────
-- CONCURRENTLY index ops cannot run inside an enclosing BEGIN/COMMIT
-- block. Each statement below runs in its own implicit per-statement
-- transaction; live writers see neither a long lock nor a window in
-- which the table has no usable index for the relevant access pattern.
--
-- Re-applying is a no-op: every IF EXISTS / IF NOT EXISTS guard makes
-- subsequent runs neither error nor duplicate work. Pattern reference:
-- db/migrations/202605021800_hardening_auth_login_attempts_index_rekey.sql
-- (single-table version) and
-- db/migrations/202605010001_phase_9_b4_role_audit_log_operator_id.sql
-- (multi-index CONCURRENTLY swap).
--
-- The original migrations' CREATE INDEX text is exempted in
-- tool/index_leading_column_lint.dart `_defaultExemptions` so the
-- shipped-migration immutability rule and the lint coexist (see the
-- auth_login_attempts precedent, lines 107-120 of that tool).

-- ─── 1. vendor_credentials_expiring_idx ──────────────────────────────

drop index concurrently if exists public.vendor_credentials_expiring_idx;

create index concurrently if not exists vendor_credentials_expiring_idx
  on public.vendor_credentials (operator_id, token_expires_at)
  where is_active = true and token_expires_at is not null;

-- ─── 2. connector_sync_watermark_unique_idx (UNIQUE) ─────────────────

drop index concurrently if exists public.connector_sync_watermark_unique_idx;

create unique index concurrently if not exists connector_sync_watermark_unique_idx
  on public.connector_sync_watermark (operator_id, connection_id, resource);

-- ─── 3. connector_sync_log_connection_recent_idx ─────────────────────

drop index concurrently if exists public.connector_sync_log_connection_recent_idx;

create index concurrently if not exists connector_sync_log_connection_recent_idx
  on public.connector_sync_log (operator_id, connection_id, occurred_at desc);

-- ─── 4. inbound_webhook_idempotency_unique_idx (UNIQUE) ──────────────

drop index concurrently if exists public.inbound_webhook_idempotency_unique_idx;

create unique index concurrently if not exists inbound_webhook_idempotency_unique_idx
  on public.inbound_webhook_idempotency
    (operator_id, vendor_id, vendor_event_id);

-- ─── 5. email_outbox_provider_message_id_idx ─────────────────────────

drop index concurrently if exists public.email_outbox_provider_message_id_idx;

create index concurrently if not exists email_outbox_provider_message_id_idx
  on public.email_outbox (operator_id, provider_message_id)
  where provider_message_id is not null;
