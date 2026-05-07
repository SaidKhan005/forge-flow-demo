-- Phase 8 / A2 fix — persist demo-mode pending-insert counter so that the
-- flip evaluation is race-safe across multiple pods.
--
-- Problem (A2):
--   Each POS sink held an in-memory `_pendingInsertsByTenant` map.  The
--   watermark write committed inside `withTenant`, then the counter read
--   and `evaluateDemoFlip` call ran OUTSIDE the transaction.  Two failure
--   modes:
--     (a) a throw inside `evaluateDemoFlip` after the watermark committed
--         left the operator stuck in demo mode;
--     (b) multi-pod deployments double-counted and double-fired the flip.
--
-- Fix:
--   Add `pending_inserts_count` to `demo_mode_state`.  Each upsert
--   increments the counter inside the same `withTenant` transaction as the
--   cover-facts row.  The watermark writer reads the counter with
--   `SELECT … FOR UPDATE` and, if it is >= 1 and `is_demo = true`, flips
--   atomically (resetting `pending_inserts_count = 0`) — all in one
--   transaction.  The in-memory map is removed from every sink.
--
-- Migration is replay-safe: `ADD COLUMN IF NOT EXISTS` is idempotent.

alter table public.demo_mode_state
  add column if not exists pending_inserts_count integer not null default 0,
  add constraint demo_mode_state_pending_inserts_count_non_negative
    check (pending_inserts_count >= 0);

comment on column public.demo_mode_state.pending_inserts_count is
  'Phase 8 A2 — running total of cover-fact / labor-punch / reservation rows
  inserted for this (operator, location, category) since the last demo-flip
  evaluation.  Incremented inside the same withTenant transaction as the
  fact-row insert; read with SELECT FOR UPDATE inside the watermark-advance
  transaction so the flip is race-safe across pods.  Reset to 0 when the
  flip fires.  Counter persists across pod restarts, replacing the former
  in-memory _pendingInsertsByTenant map on each POS sink.';
