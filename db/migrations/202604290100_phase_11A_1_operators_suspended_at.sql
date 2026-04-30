-- Phase 11A.1 - Add `operators.suspended_at` column.
--
-- The F&F admin console Operators surface needs to suspend and
-- reactivate operators without dropping rows. The cloud-foundation
-- migration (`202604250005_advisor_cloud_foundation.sql`) declared
-- the `operators` table without a suspension marker; this slice
-- adds it as a nullable `timestamptz` so existing rows pass without
-- backfill.
--
-- The `OperatorsRepository.suspendOperator` / `reactivateOperator`
-- methods read and write this column directly; the admin console
-- renders a `suspended` pill when it is non-null. Tenant-wide runtime
-- enforcement, if desired, belongs to a future access-control slice
-- that can read the same marker.
--
-- Forward-only: no DROP COLUMN escape hatch on rollback. If a
-- rollback is ever needed the column can be left in place; nullable
-- columns do not constrain inserts.

alter table public.operators
  add column if not exists suspended_at timestamptz null;

comment on column public.operators.suspended_at is
  '11A.1: nullable suspension marker. Set to now() when an F&F admin '
  'suspends an operator via /v1/admin/operators/{id}/suspend; '
  'cleared on /reactivate. Tenant-wide runtime enforcement, if added, '
  'should read this marker from a future access-control slice.';
