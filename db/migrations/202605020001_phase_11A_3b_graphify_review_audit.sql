-- Phase 11A.3b — graphify_review_audit append-only audit table.
--
-- Slice scope: when the F&F super_admin reviews Graphify-derived
-- graph candidates in the Corpus Admin "Graph candidates" tab, every
-- *rejected* (or edited-then-rejected) decision lands here. Approved
-- candidates are written to the canonical `public.graph_nodes` /
-- `public.graph_edges` tables (created in 9.0Σ.i, migration
-- `202604280008`); rejected candidates are NEVER written to those
-- canonical tables, so the AGE projection rebuild — which reads
-- canonical rows only — physically cannot surface a rejected
-- candidate to the advisor runtime.
--
-- Why a NEW table instead of reusing audit_logs:
--   * audit_logs (9.0Σ.f) is the global hash-chained system audit
--     trail. It carries one row per business action; that row's
--     `payload` is opaque to schema-level queries.
--   * graphify_review_audit captures the candidate payload itself
--     (node_key / edge_key shape, source provenance, confidence,
--     classification) so the F&F admin can re-render the rejected
--     candidate later for review or appeal without round-tripping
--     to the original graphify-out artifact (which is NOT shipped
--     as production truth, per the slice's hard constraint).
--   * The proxy still fans the rejection out to audit_logs via the
--     existing AuditLogsRepository so the global hash-chain stays
--     intact (the audit_logs payload references the audit_id from
--     this table for cross-walk).
--
-- Hard rules carried from CLAUDE.md and the 4-27 lock:
--
--   1. **Operator-scoped from creation.** Every row carries
--      `operator_id`; the tenant-leading B-tree index on
--      `(operator_id, decided_at desc)` folds the RLS policy probe
--      into the index lookup (CLAUDE.md "RLS performance discipline").
--
--   2. **RLS via wrapper functions.** The policy uses
--      `public.app_current_operator()` (9.0Σ.b); bare
--      `current_setting()` is forbidden by the lint at
--      `tool/rls_policy_lint.dart`.
--
--   3. **TIMESTAMPTZ for every datetime column.** Naive (non-tz)
--      types are banned in operator-scoped tables per CLAUDE.md
--      storage rule.
--
--   4. **Composite FK to `public.locations(operator_id, location_id)`.**
--      Same-operator location pointer; cross-operator location
--      reference is a database error.
--
--   5. **Append-only by grant shape.** service_role and forge_admin
--      both get INSERT and SELECT only; UPDATE and DELETE are
--      explicitly REVOKEd. Mirrors the auth_events_audit pattern
--      from 202604260001 (lines 42-50). A future grant change
--      cannot accidentally weaken the posture without an explicit
--      reviewer's notice.
--
--   6. **Zero foreign keys into `graph_nodes` / `graph_edges`.** The
--      audit table holds the rejection payload as JSONB — it does
--      NOT reference any canonical-graph row. This is the schema-
--      level guarantee that AGE traversal cannot reach audit data:
--      AGE projects from canonical FKs only. The
--      `age_unapproved_isolation_test` contract test asserts this
--      shape post-migration.
--
-- Live apply status:
--   * Will land on staging + Production1 alongside the rest of the
--     11A.3b slice. The migration is guarded by `create table if not
--     exists` + idempotent GRANT/REVOKE so a re-run is a no-op.

begin;

-- ─── graphify_review_audit ──────────────────────────────────────────

create table if not exists public.graphify_review_audit (
  audit_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null references public.operators(operator_id)
    on delete cascade,
  -- Optional location scoping. Rejections decided against an
  -- operator-global graph leave `location_id` NULL; rejections
  -- decided against a per-location graph carry the location.
  -- Composite FK below pins the value to a same-operator location
  -- so a cross-operator location pointer is a database error.
  location_id uuid null,
  decided_by uuid not null,
  decided_at timestamptz not null default now(),
  -- 'rejected' = candidate rejected outright (no edit attempt).
  -- 'edited_then_rejected' = admin opened the edit dialog, made
  --   changes, then rejected the edited candidate. Capturing the
  --   distinction lets the F&F support team see whether the admin
  --   was trying to salvage the candidate before giving up.
  decision text not null
    check (decision in ('rejected', 'edited_then_rejected')),
  reason text null
    check (reason is null or char_length(reason) <= 1024),
  -- 'node' or 'edge'. Hyperedges are imported as pairwise edges
  -- (with a shared `hyperedge_id` in the candidate payload), so
  -- this table sees nodes and edges only.
  candidate_kind text not null
    check (candidate_kind in ('node', 'edge')),
  candidate_payload jsonb not null
    check (jsonb_typeof(candidate_payload) = 'object'),
  -- Target the candidate would have written to had it been
  -- approved. Captured at decision time so a later support review
  -- knows which (graph_scope, graph_version) the rejection was
  -- scoped to.
  target_graph_scope text not null
    check (char_length(target_graph_scope) between 1 and 64),
  target_graph_version text not null
    check (char_length(target_graph_version) between 1 and 64),
  -- Source provenance from the Graphify importer (per spec line
  -- 254-255 in the 11A operations console plan).
  source_file text null,
  source_ref text null,
  -- Graphify-emitted bucket label ('EXTRACTED' / 'INFERRED' /
  -- 'AMBIGUOUS') — the producer's classification of why this was
  -- proposed. Captured so support can spot patterns in the
  -- rejection mix without re-running the importer.
  confidence_label text null
    check (confidence_label is null or
      confidence_label in ('EXTRACTED', 'INFERRED', 'AMBIGUOUS')),
  confidence_score numeric(4, 3) null
    check (confidence_score is null or
      (confidence_score >= 0.0 and confidence_score <= 1.0)),
  -- Idempotency-Key from the proxy commit-batch request. Lets a
  -- replayed rejection collapse to one audit row instead of
  -- stamping a duplicate (matches the auth_events_audit
  -- idempotency posture).
  idempotency_key text null
    check (idempotency_key is null or
      char_length(idempotency_key) between 1 and 256),
  -- Composite FK: location_id (when set) must belong to the same
  -- operator. NULL location_id passes (MATCH SIMPLE) so global
  -- rejections are accepted.
  --
  -- ON DELETE SET NULL (location_id) — a location going away must
  -- NOT erase audit history; only the location pointer is nulled,
  -- the audit row itself is retained. PG15+ column-list form pins
  -- the SET NULL to `location_id` so `operator_id` (NOT NULL) is
  -- preserved on the same-operator-cascade path.
  constraint graphify_review_audit_location_same_operator_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete set null (location_id)
);

comment on table public.graphify_review_audit is
  'Phase 11A.3b — append-only audit log of rejected (or '
  'edited-then-rejected) Graphify candidate decisions. Approved '
  'candidates are written to public.graph_nodes / public.graph_edges '
  'instead; rejected candidates land here ONLY. No FKs into the '
  'canonical graph tables — AGE projection cannot surface audit '
  'rows by construction. Operator-scoped, RLS-protected, append-only '
  'by grant shape (mirror of auth_events_audit, 202604260001).';

comment on column public.graphify_review_audit.candidate_payload is
  '11A.3b: full rejected candidate body (node_key / edge_key, '
  'properties, endpoints, etc.) so support can re-render the '
  'rejection later without round-tripping to the source graphify-out '
  'artifact. Object-only CHECK matches graph_nodes/graph_edges.';

comment on column public.graphify_review_audit.target_graph_scope is
  '11A.3b: the (graph_scope, graph_version) the candidate would '
  'have written to had it been approved. Captured at decision time '
  'so a later support review knows which scope the rejection was '
  'targeting.';

comment on column public.graphify_review_audit.confidence_label is
  '11A.3b: Graphify-emitted bucket label (EXTRACTED / INFERRED / '
  'AMBIGUOUS). The CHECK pins the values so a producer cannot '
  'silently invent a fourth class.';

comment on column public.graphify_review_audit.idempotency_key is
  '11A.3b: Idempotency-Key from the proxy commit-batch request. '
  'Lets a replayed rejection collapse to one row instead of stamping '
  'a duplicate. The proxy enforces uniqueness via the proxy_requests '
  'dedup table; this column is captured for forensic cross-walk.';

-- ─── Tenant-leading indexes ─────────────────────────────────────────
--
-- Every B-tree index leads with `operator_id` so the per-tenant RLS
-- policy folds into the index probe. Two indexes cover the two
-- query shapes the support review surface uses:
--
--   * Recent rejections panel:
--       WHERE operator_id = $1 ORDER BY decided_at DESC
--   * Per-target review:
--       WHERE operator_id = $1
--         AND target_graph_scope = $2
--         AND target_graph_version = $3
--       ORDER BY decided_at DESC

create index if not exists graphify_review_audit_recent_idx
  on public.graphify_review_audit (operator_id, decided_at desc);

create index if not exists graphify_review_audit_target_idx
  on public.graphify_review_audit
    (operator_id, target_graph_scope, target_graph_version, decided_at desc);

-- ─── RLS policies (wrapper-only per 9.0Σ.b) ─────────────────────────
--
-- Two policies, mirroring the audit_logs / event_outbox pattern:
--
--   * SELECT: tenants read only their own rows. Cross-operator
--     F&F admin reads go through `forge_admin BYPASSRLS` via
--     `OperatorScopedRepository.withSystem`.
--
--   * INSERT: rows may only attribute to the caller's tenant.
--     UPDATE / DELETE have no policy AND no grants below; both
--     axes must agree to keep the table append-only.

alter table public.graphify_review_audit enable row level security;

create policy "graphify_review_audit_per_tenant_select"
  on public.graphify_review_audit for select to service_role
  using (operator_id = public.app_current_operator());

create policy "graphify_review_audit_per_tenant_insert"
  on public.graphify_review_audit for insert to service_role
  with check (operator_id = public.app_current_operator());

comment on policy "graphify_review_audit_per_tenant_select"
  on public.graphify_review_audit is
  'Phase 11A.3b — tenants read only their own rejection audit rows. '
  'Cross-tenant F&F admin reads go through forge_admin BYPASSRLS '
  'via runAsSystem with a non-blank reason.';

comment on policy "graphify_review_audit_per_tenant_insert"
  on public.graphify_review_audit is
  'Phase 11A.3b — rejection rows may only attribute to the calling '
  'tenant. No UPDATE/DELETE policy and no UPDATE/DELETE grants.';

-- ─── Append-only grants ─────────────────────────────────────────────
--
-- service_role + forge_admin both get INSERT and SELECT only.
-- UPDATE and DELETE are explicitly REVOKEd so a future grant change
-- cannot accidentally weaken the posture without an explicit
-- reviewer's notice. Mirrors the auth_events_audit pattern from
-- migration 202604260001.

revoke all on public.graphify_review_audit from public;
grant select, insert on public.graphify_review_audit to service_role;
grant select, insert on public.graphify_review_audit to forge_admin;

-- Defensive REVOKE: re-asserts append-only posture so a future
-- migration's broad GRANT cannot quietly weaken it.
revoke update, delete on public.graphify_review_audit from service_role;
revoke update, delete on public.graphify_review_audit from forge_admin;

commit;
