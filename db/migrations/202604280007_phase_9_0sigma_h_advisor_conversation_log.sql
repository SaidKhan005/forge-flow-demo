-- Phase 9.0Σ.h — advisor_conversation_log (item 5 from
-- `phase_9_scalability_decisions_2026-04-27.md`, parcel B29 in
-- `phase_9_execution_backlog.md`).
--
-- Every advisor turn writes one provenance row through the proxy. Raw
-- question and recommendation text are encrypted at rest (application-
-- layer ciphertext + IV + KMS key reference; the row never carries the
-- actual key material) and gated by a restricted audit-privacy /
-- privacy-compliance permission. Non-sensitive hashes and metadata
-- remain queryable through the ordinary `service_role` path so audit
-- and replay surfaces can render summaries without decrypting raw
-- content.
--
-- Hard rules carried from CLAUDE.md and the 4-27 lock:
--   1. RLS performance discipline — every B-tree index leads with
--      `operator_id` so the per-tenant policy folds into the index
--      probe; bare `current_setting()` inside policy bodies is
--      forbidden by the lint in `tool/rls_policy_lint.dart`.
--   2. Storage rule — `TIMESTAMPTZ` everywhere; `TIMESTAMP WITHOUT
--      TIME ZONE` is banned in operator-scoped tables.
--   3. RLS uses the wrapper functions from 9.0Σ.b (
--      `public.app_current_operator()`); column-level grants enforce
--      the audit-privacy split below.
--   4. The advisor turn's content is encrypted by the proxy BEFORE
--      it reaches this layer; the migration does not call
--      `pgp_sym_encrypt(...)`. Producers bind `content_encrypted` /
--      `content_iv` / `content_key_ref` already-encrypted; the
--      `pgcrypto` extension is enabled defensively for any DB-side
--      digest helpers an audit-privacy reader needs (e.g. recomputing
--      `content_hash` for integrity verification).
--
-- Partitioning posture (item 5 + scalability "high-volume table
-- partitioning required"):
--   * `partition by range (created_at)`. Time partitioning aligns the
--     hot read path (recent advisor turns per operator) with partition
--     pruning and matches the locked posture for `usage_logs` in
--     `202604250005_advisor_cloud_foundation.sql`.
--   * PG requires the partition key to be part of every unique
--     constraint on a partitioned table. The PK is therefore
--     `(operator_id, created_at, id)` — tenant-leading + includes the
--     partition key + UUID tiebreaker. `id uuid` is preserved as the
--     trace id (returned to producers and used by Phase 11b advisor
--     replay), it is just no longer the bare PK.
--   * A `DEFAULT` partition catches writes that fall outside any
--     month-specific partition the post-launch maintenance job
--     creates ahead of time; without it, a write to an unprovisioned
--     month would fail.
--
-- Audit-privacy split (item 5 + B29 gate):
--   * `service_role` (the proxy's normal connection) gets INSERT on
--     the full row but SELECT only on a column-allowlist of safe
--     metadata. `content_encrypted`, `content_iv`, and
--     `content_key_ref` are deliberately omitted from that allowlist,
--     so a `SELECT *` from a service_role transaction errors at the
--     privilege layer before RLS even evaluates.
--   * `audit_privacy` (NOLOGIN role created here) gets SELECT on the
--     full row. The proxy assumes this role only on the documented
--     audit-privacy access path (lands alongside the audit-privacy
--     proxy gate in a future slice); every assumption pairs with an
--     `audit_logs` provenance row per the B29 acceptance.
--   * `forge_admin` keeps full DML as the BYPASSRLS escape hatch for
--     paired-super-admin GDPR redaction / break-glass paths.
--
-- This migration is local framework only — no live database mutation.
-- Live apply on staging + Production1 is queued under the Phase 9
-- live-mutation gate.

begin;

-- ─── Extensions ────────────────────────────────────────────────────
--
-- `pgcrypto` is required for `digest()` helpers used by audit-privacy
-- readers when they recompute `content_hash` for integrity checks. It
-- is also the extension that pairs with `cutover.0a` CMK once the proxy
-- starts encrypting at write time. Enabled idempotently so re-runs on
-- staging/Production1 (where the extension may already be present from
-- the installed-extensions list) are no-ops.

create extension if not exists pgcrypto;

-- ─── audit_privacy role ────────────────────────────────────────────
--
-- The audit-privacy / privacy-compliance role from item 5. NOLOGIN —
-- the role exists purely as a target for column-level GRANT SELECT on
-- the encrypted-content columns; the proxy assumes it via
-- `SET LOCAL ROLE audit_privacy` only inside the documented audit-
-- privacy access path. Idempotent so re-runs are no-ops; matches the
-- pattern in `202604250000_advisor_roles.sql`.

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_roles where rolname = 'audit_privacy'
  ) then
    create role audit_privacy nologin;
  end if;
end
$$;

-- ─── advisor_conversation_log table ────────────────────────────────

create table if not exists public.advisor_conversation_log (
  -- UUID trace id. NOT the PK because PG partitioned tables require
  -- the partition key to be part of every unique constraint;
  -- producers receive this id back via RETURNING so downstream
  -- replay/audit surfaces can address the row.
  id uuid not null default gen_random_uuid(),
  -- Tenant-leading scope columns. `operator_id` leads every B-tree
  -- index per RLS performance discipline.
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  location_id uuid not null,
  -- `user_id` is nullable for system-issued / scheduled advisor turns
  -- that have no human actor (matches `auth_events_audit.actor_user_id`
  -- nullability on system-issued audit rows).
  user_id uuid null,
  conversation_id uuid not null,
  turn_index integer not null check (turn_index >= 0),
  role text not null
    check (role in ('user', 'assistant', 'system', 'tool')),
  -- ─── Encrypted raw payload ─────────────────────────────────────
  -- The proxy encrypts the advisor-turn content BEFORE insert using
  -- the KMS-managed CMK referenced in `content_key_ref`. The DB never
  -- sees plaintext; the row never carries the actual key material.
  content_encrypted bytea not null,
  content_iv bytea not null,
  content_key_ref text not null
    check (char_length(content_key_ref) between 1 and 200),
  -- ─── Queryable non-sensitive metadata ──────────────────────────
  -- SHA-256 hex of the canonical advisor-turn payload. Computed by
  -- the proxy at write time; queryable for integrity / dedup checks
  -- without decrypting the raw content.
  content_hash text not null
    check (content_hash ~ '^[0-9a-f]{64}$'),
  -- Surface/query-class metadata. `surface` is which UI surface the
  -- turn originated from (advisor.phone / advisor.web /
  -- advisor.report.ask / etc.); `query_class` is the Modular Adaptive
  -- Agentic RAG classifier output. Both are queryable through
  -- service_role for audit/replay summaries.
  surface text not null
    check (char_length(surface) between 1 and 64),
  query_class text null
    check (
      query_class is null
      or char_length(query_class) between 1 and 64
    ),
  usage_class text not null
    check (char_length(usage_class) between 1 and 64),
  -- Provider / model / token / cost. Nullable because a system-issued
  -- 'tool' turn may have no provider attribution.
  provider text null,
  model_id text null,
  model_version text null,
  prompt_token_count integer null
    check (prompt_token_count is null or prompt_token_count >= 0),
  completion_token_count integer null
    check (completion_token_count is null or completion_token_count >= 0),
  cost_usd numeric(12, 6) null
    check (cost_usd is null or cost_usd >= 0),
  latency_ms integer null
    check (latency_ms is null or latency_ms >= 0),
  -- ─── Retention / legal-hold (item 5 retention/legal-hold gate) ──
  -- The high-volume-table partitioning gate from
  -- `phase_9_scalability_decisions_2026-04-27.md` requires every
  -- partitioned operator-scoped table to ship a tested
  -- retention/archive/legal-hold path. The schema hooks land here so
  -- the Phase 10a/11a Cloud Run scheduled purge job can issue safe
  -- batched DELETEs without re-shaping the table.
  --
  -- `legal_hold` is a per-row freeze flag. When TRUE, the row is
  -- excluded from automatic retention purges regardless of age. F&F
  -- internal admin / paired-super-admin paths flip this column via
  -- `forge_admin` BYPASSRLS to satisfy litigation holds, regulator
  -- requests, or paired-super-admin-approved investigation freezes.
  --
  -- `retention_class` is the tiered retention bucket. `'standard'`
  -- follows the launch retention window; `'extended'` is a
  -- contractual longer-than-standard window; `'legal'` is the soft
  -- form that pairs with `legal_hold = true`; `'permanent'` is the
  -- hard form that the purge predicate also excludes (Q9 audit-
  -- retention compatibility).
  legal_hold boolean not null default false,
  retention_class text not null default 'standard'
    check (
      retention_class in ('standard', 'extended', 'legal', 'permanent')
    ),
  -- ─── Anchor ────────────────────────────────────────────────────
  created_at timestamptz not null default now(),
  -- Composite PK includes the partition key (`created_at`) and is
  -- tenant-leading (`operator_id` first). The UUID `id` is the
  -- tiebreaker so concurrent inserts at the same instant resolve.
  primary key (operator_id, created_at, id),
  -- Composite FK rejects (operator_a, location_b) mismatches —
  -- matches the discipline used in `usage_logs` /
  -- `feature_flags` / `proxy_requests`.
  foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
) partition by range (created_at);

-- DEFAULT partition. Future scheduled jobs (Phase 11A maintenance)
-- attach monthly partitions ahead of time; without the default,
-- writes outside any provisioned month would fail.
create table if not exists public.advisor_conversation_log_default
  partition of public.advisor_conversation_log default;

comment on table public.advisor_conversation_log is
  'Phase 9.0Σ.h (item 5) — every advisor turn writes one provenance '
  'row. Raw question/recommendation text is encrypted at rest '
  '(application-layer ciphertext + IV + KMS key reference) and read '
  'access to the encrypted columns is gated by the audit_privacy '
  'role. Hashes and non-sensitive metadata remain queryable through '
  'service_role. Partitioned by time on created_at; tenant-leading '
  'PK + indexes preserve the locked RLS performance posture.';

comment on column public.advisor_conversation_log.id is
  'UUID trace id. Not the PK on its own (PG partitioned tables '
  'require the partition key in every unique constraint); the row is '
  'addressable via (operator_id, created_at, id).';

comment on column public.advisor_conversation_log.content_encrypted is
  'Phase 9.0Σ.h (item 5) — ciphertext of the advisor-turn content. '
  'Encrypted by the proxy before insert using the KMS-managed CMK '
  'referenced in content_key_ref. Read access restricted to '
  'audit_privacy + forge_admin via column-level GRANT SELECT.';

comment on column public.advisor_conversation_log.content_iv is
  'Phase 9.0Σ.h — initialization vector for content_encrypted. '
  'Read access restricted to audit_privacy + forge_admin via '
  'column-level GRANT SELECT.';

comment on column public.advisor_conversation_log.content_key_ref is
  'Phase 9.0Σ.h — KMS key reference (Key Vault path / version), not '
  'the raw key. Pairs with cutover.0a CMK at provisioning. Read '
  'access restricted to audit_privacy + forge_admin via column-level '
  'GRANT SELECT.';

comment on column public.advisor_conversation_log.content_hash is
  'Phase 9.0Σ.h — SHA-256 hex of the canonical advisor-turn payload. '
  'Queryable through service_role for integrity / dedup checks '
  'without decrypting the raw content.';

comment on column public.advisor_conversation_log.legal_hold is
  'Phase 9.0Σ.h (item 5 retention/legal-hold gate). Per-row freeze '
  'flag. When TRUE, the row is excluded from automatic retention '
  'purges regardless of age. Mutated only via forge_admin BYPASSRLS '
  'paths (paired-super-admin / litigation hold). service_role can '
  'READ the flag for legal-hold UX but cannot UPDATE it.';

comment on column public.advisor_conversation_log.retention_class is
  'Phase 9.0Σ.h — tiered retention bucket. standard = launch window, '
  'extended = contractual longer window, legal = soft hold paired '
  'with legal_hold=true, permanent = never-purge (excluded from the '
  'purge predicate alongside legal_hold rows).';

-- ─── Tenant-leading indexes ────────────────────────────────────────
--
-- Hot read path 1: render a conversation's turns in order. Operator
-- LEADS so the per-tenant RLS policy folds into the index probe,
-- conversation narrows the scan to one chat, turn_index resolves the
-- ORDER BY without a sort.

create index if not exists advisor_conversation_log_op_conv_turn_idx
  on public.advisor_conversation_log
  (operator_id, conversation_id, turn_index);

-- Hot read path 2: a user's recent advisor activity (admin + user
-- self-review surfaces). created_at DESC keeps the most-recent rows
-- at the front of the index so LIMIT-style queries walk a few pages.

create index if not exists advisor_conversation_log_op_user_created_idx
  on public.advisor_conversation_log
  (operator_id, user_id, created_at desc);

-- Hot read path 3: per-location / per-usage-class recent traffic for
-- usage cap reconciliation and billing rollups. Tenant-leading;
-- matches the (operator, location, usage_class) shape used in
-- usage_logs so cap-vs-actual joins stay single-pass.

create index if not exists advisor_conversation_log_op_loc_usage_idx
  on public.advisor_conversation_log
  (operator_id, location_id, usage_class, created_at desc);

-- Retention sweep support. Partial index excludes legal_hold rows
-- and permanent-retention rows from the purge scan so the periodic
-- DELETE only walks rows that are actually eligible. Tenant-leading
-- so the RLS policy folds into the scan when the Phase 10a/11a
-- purge worker runs inside `runAsSystem` (forge_admin BYPASSRLS) or
-- inside a tenant transaction.

create index if not exists advisor_conversation_log_op_purge_idx
  on public.advisor_conversation_log
  (operator_id, created_at)
  where legal_hold = false and retention_class <> 'permanent';

-- ─── Retention purge function (item 5 retention/legal-hold gate) ──
--
-- Phase 10a/11a Cloud Run scheduled job calls this function in a
-- batched loop (until it returns 0) to drain rows older than the
-- per-operator retention window. The function is the single source
-- of truth for the purge predicate so the batch loop, the runbook,
-- and this migration cannot disagree about which rows are eligible.
--
-- Predicate (NEVER deletes any of these):
--   * legal_hold = true                          — litigation / regulator hold
--   * retention_class = 'permanent'              — never-purge bucket
--   * created_at >= before_ts                    — outside the window
--
-- `SECURITY DEFINER` carries the migration owner's privileges
-- (forge_admin path) regardless of caller, AND `EXECUTE` is granted
-- only to forge_admin. The runtime `service_role` connection cannot
-- call the function — combined with the audit-privacy column-level
-- grant above, the runtime path has no DELETE surface at all.
--
-- The DELETE uses a PK-tuple `IN (...)` form rather than `ctid` so
-- it works correctly across the parent partitioned table and its
-- child partitions; `ctid` is per-physical-row and not stable across
-- partition pruning.

create or replace function public.advisor_conversation_log_purge(
  target_operator_id uuid,
  before_ts timestamptz,
  batch_size integer default 1000
) returns integer
language plpgsql
security definer
as $$
declare
  deleted_count integer := 0;
begin
  if batch_size <= 0 then
    raise exception
      'advisor_conversation_log_purge: batch_size must be positive '
      '(got %)',
      batch_size;
  end if;
  delete from public.advisor_conversation_log
   where (operator_id, created_at, id) in (
     select operator_id, created_at, id
       from public.advisor_conversation_log
      where operator_id = target_operator_id
        and created_at < before_ts
        and legal_hold = false
        and retention_class <> 'permanent'
      order by created_at
      limit batch_size
   );
  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

revoke execute on function
  public.advisor_conversation_log_purge(uuid, timestamptz, integer)
  from public;

grant execute on function
  public.advisor_conversation_log_purge(uuid, timestamptz, integer)
  to forge_admin;

comment on function
  public.advisor_conversation_log_purge(uuid, timestamptz, integer) is
  'Phase 9.0Σ.h (item 5 retention/legal-hold gate). Batched DELETE '
  'of advisor_conversation_log rows older than before_ts for the '
  'named operator. NEVER deletes rows where legal_hold = true or '
  'retention_class = ''permanent''. SECURITY DEFINER + EXECUTE to '
  'forge_admin only — the runtime service_role path cannot call it.';

-- ─── RLS scaffolding ───────────────────────────────────────────────
--
-- Per-tenant RLS from creation. All policies use the wrapper
-- functions from 202604280000 (item 4); bare `current_setting()` is
-- forbidden by the lint at `tool/rls_policy_lint.dart`.
--
-- Three policies cover the two ordinary access roles:
--   * service_role SELECT — tenant-scoped reads of safe metadata
--     (column-level grant below restricts which columns are visible).
--   * service_role INSERT — producers (the proxy) write rows in their
--     own tenant transaction.
--   * audit_privacy SELECT — the documented audit-privacy access
--     path; column-level grant below admits the encrypted columns.
--
-- F&F internal admin / dev access uses the `forge_admin` BYPASSRLS
-- escape hatch via `runAsSystem` and audits every bypass with a
-- non-blank reason string.

alter table public.advisor_conversation_log enable row level security;
alter table public.advisor_conversation_log_default enable row level security;

create policy "advisor_conversation_log_per_tenant_select"
  on public.advisor_conversation_log for select to service_role
  using (operator_id = public.app_current_operator());

create policy "advisor_conversation_log_per_tenant_insert"
  on public.advisor_conversation_log for insert to service_role
  with check (operator_id = public.app_current_operator());

create policy "advisor_conversation_log_audit_privacy_select"
  on public.advisor_conversation_log for select to audit_privacy
  using (operator_id = public.app_current_operator());

-- Default-partition policies. PG inherits parent policies for
-- partitioned tables, but RLS must be explicitly enabled on each
-- partition (see usage_logs_default in
-- `202604250005_advisor_cloud_foundation.sql`). Declaring matching
-- policies here keeps the per-partition posture deliberate so a
-- future detach/attach cannot silently drop the per-tenant filter.

create policy "advisor_conversation_log_default_per_tenant_select"
  on public.advisor_conversation_log_default for select to service_role
  using (operator_id = public.app_current_operator());

create policy "advisor_conversation_log_default_per_tenant_insert"
  on public.advisor_conversation_log_default for insert to service_role
  with check (operator_id = public.app_current_operator());

create policy "advisor_conversation_log_default_audit_privacy_select"
  on public.advisor_conversation_log_default for select to audit_privacy
  using (operator_id = public.app_current_operator());

comment on policy "advisor_conversation_log_per_tenant_select"
  on public.advisor_conversation_log is
  'Phase 9.0Σ.h (item 5) — tenant-scoped SELECT through the proxy''s '
  'service_role connection. The column-level GRANT SELECT below '
  'omits content_encrypted / content_iv / content_key_ref so a '
  'broad SELECT through this role reads only safe metadata.';

comment on policy "advisor_conversation_log_audit_privacy_select"
  on public.advisor_conversation_log is
  'Phase 9.0Σ.h (item 5) — the documented audit-privacy read path. '
  'Combined with the column-level GRANT SELECT ON ALL columns to '
  'audit_privacy below, this is the only ordinary path that can '
  'read the raw encrypted content. Tenant scope still applies via '
  'app_current_operator() wrapper. The proxy must pair every '
  'assumption of this role with an audit_logs provenance row.';

-- ─── Privileges (column-level for audit-privacy split) ─────────────
--
-- service_role gets INSERT on the full row, SELECT only on the
-- non-sensitive metadata column allowlist. PG enforces column-level
-- grants at the privilege layer (RLS comes after privileges), so a
-- `SELECT *` issued through service_role errors before RLS even
-- evaluates — the encrypted columns are simply unreadable on this
-- role's path.
--
-- The allowlist is explicit (each safe column listed by name) so a
-- future ALTER TABLE that adds a sensitive column does NOT silently
-- extend service_role's read footprint. New columns are unreadable
-- to service_role until they are explicitly added to this list.

grant insert on public.advisor_conversation_log to service_role;
grant insert on public.advisor_conversation_log_default to service_role;

grant select (
  id,
  operator_id,
  location_id,
  user_id,
  conversation_id,
  turn_index,
  role,
  content_hash,
  surface,
  query_class,
  usage_class,
  provider,
  model_id,
  model_version,
  prompt_token_count,
  completion_token_count,
  cost_usd,
  latency_ms,
  legal_hold,
  retention_class,
  created_at
) on public.advisor_conversation_log to service_role;

grant select (
  id,
  operator_id,
  location_id,
  user_id,
  conversation_id,
  turn_index,
  role,
  content_hash,
  surface,
  query_class,
  usage_class,
  provider,
  model_id,
  model_version,
  prompt_token_count,
  completion_token_count,
  cost_usd,
  latency_ms,
  legal_hold,
  retention_class,
  created_at
) on public.advisor_conversation_log_default to service_role;

-- audit_privacy: full SELECT (including the raw encrypted columns).
-- The proxy assumes this role only on the documented audit-privacy
-- path; every assumption pairs with an audit_logs provenance row.
grant select on public.advisor_conversation_log to audit_privacy;
grant select on public.advisor_conversation_log_default to audit_privacy;

-- forge_admin: full DML as the BYPASSRLS escape hatch (paired-super-
-- admin GDPR redaction, paired-super-admin break-glass).
grant select, insert, update, delete on public.advisor_conversation_log to forge_admin;
grant select, insert, update, delete on public.advisor_conversation_log_default to forge_admin;

-- ─── Wrapper EXECUTE grants for audit_privacy ──────────────────────
--
-- The audit-privacy RLS policies declared above call
-- `public.app_current_operator()`. The 9.0Σ.b wrapper migration
-- (`202604280000_phase_9_0sigma_b_rls_wrappers.sql`) granted EXECUTE
-- only to `service_role` and `forge_admin`; PostgreSQL's default
-- PUBLIC EXECUTE on the function masks this today, but a hardened
-- DB or a future REVOKE FROM PUBLIC would make policy evaluation on
-- the audit-privacy read path fail. Granting explicitly here makes
-- the wrapper-vs-role contract complete for every policy this slice
-- adds; future audit-privacy policies that reference additional
-- wrappers MUST add the matching grant here or in their own
-- migration.
grant execute on function public.app_current_operator() to audit_privacy;

commit;
