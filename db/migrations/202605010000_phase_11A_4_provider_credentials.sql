-- Phase 11A.4 — Provider credential ledger.
--
-- The F&F Operations Console rotates server-side keys (Anthropic,
-- Voyage, Azure DB) without ever exposing plaintext to the operator
-- app. Plaintext lives in Cloud Run env / KMS; this table is the
-- masked-display ledger that backs the admin Integrations surface.
-- Every rotation appends a new row and flips the prior row's
-- `is_active` to false in one transaction so a rotation failure can
-- never leave two active rows for the same `key_kind` and the
-- previous key stays in service until KMS confirms the new write.
--
-- Row shape:
--   * `key_kind`         — stable lane name (`anthropic`, `voyage`,
--                          `azure_db`). The proxy accepts only the
--                          locked set; UI surfaces match.
--   * `masked_value`     — display string the admin console renders
--                          (e.g. `sk-ant-***Q9aB`). Never the full key.
--   * `kms_secret_name`  — opaque pointer the proxy hands to the
--                          KMS provider (`kms://stub/<uuid>` for the
--                          stub provider; production swaps in the
--                          real Cloud Run / KMS scheme post-launch).
--   * `created_by`,      — actor user id stamps for audit-on-rotate.
--     `updated_by`         The full chain lives in
--                          `auth_events_audit` via the existing
--                          system-event writer.
--   * `rotated_at`       — explicit rotation timestamp. Distinct
--                          from `created_at` so future migrations can
--                          backfill historical rotation moments
--                          without rewriting `created_at`.
--   * `is_active`        — exactly one TRUE row per `key_kind` at
--                          rest. Enforced by the partial unique
--                          index below; the rotation path inserts
--                          the new row and updates the prior in one
--                          transaction so the constraint is never
--                          violated.
--
-- This table is NOT operator-scoped. Provider credentials are F&F
-- platform-wide (we hold one Anthropic key for the whole product).
-- No `operator_id` column, no RLS policy. Reads/writes run through
-- the admin pool only; the route handler enforces the
-- `super_admin` role gate.

begin;

create table if not exists public.provider_credentials (
  credential_id uuid primary key default gen_random_uuid(),
  key_kind text not null,
  masked_value text not null,
  kms_secret_name text not null,
  created_by uuid null,
  updated_by uuid null,
  is_active boolean not null default true,
  rotated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint provider_credentials_key_kind_chk check (
    key_kind in ('anthropic', 'voyage', 'azure_db')
  )
);

create index if not exists provider_credentials_kind_active_idx
  on public.provider_credentials (key_kind, is_active);

-- Exactly one active row per key_kind. The rotation path flips the
-- prior is_active to false BEFORE the new insert commits, so the
-- partial unique index only ever sees a single TRUE row for any
-- given kind once the transaction lands.
create unique index if not exists provider_credentials_active_uq
  on public.provider_credentials (key_kind)
  where is_active;

grant select, insert, update on public.provider_credentials
  to forge_admin;
grant usage on all sequences in schema public to forge_admin;

commit;
