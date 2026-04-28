-- Phase 9.0Σ.f — hash-chained audit_logs + per-operator/day chain
-- scope + pg_partman daily partitioning + Azure Blob anchor table
-- (item 13 from `phase_9_scalability_decisions_2026-04-27.md`,
-- B27 from `phase_9_execution_backlog.md`).
--
-- This slice creates the database side of the locked SOC 2 / forensic
-- audit posture. Every audit-relevant action writes one row into
-- `public.audit_logs`; the row's `row_hash` is `SHA-256(prev_row_hash
-- || canonical_payload)` so any retroactive mutation in the chain is
-- detectable from the next row's hash forward. Daily, the
-- `tool/audit_anchor` Cloud Run job reads each completed
-- `(operator_id, chain_date)` chain's terminal hash, writes a JSON
-- evidence record to the F&F immutable Azure Blob container
-- (configured separately, never in repo), and records the anchor in
-- `public.audit_chain_anchors`. The verifier walks the in-DB chain,
-- recomputes every row hash, and compares the terminal hash to the
-- anchor row + the Blob evidence.
--
-- This migration is local framework only — no live database mutation.
-- Live apply on staging + Production1 is queued under the Phase 9
-- live-mutation gate (subject to user approval per Phase 9 lock).
-- The pg_partman registration call is wrapped in a re-runnable DO
-- block so the same migration is safe to apply repeatedly.
--
-- Hard rules carried from CLAUDE.md and the 4-27 lock:
--
--   1. **Scale Pressure-Test Guardrail #1.** A single global
--      `prev_row_hash → row_hash` chain serializes every audit write
--      and becomes a launch-blocking bottleneck. Chains MUST be
--      bounded; this slice scopes them to `(operator_id, chain_date)`.
--      Concurrent inserts on different operators or different days do
--      not contend; concurrent inserts on the SAME chain serialize
--      through `pg_advisory_xact_lock(hashtext(operator_id || ':' ||
--      chain_date))` so the trigger's "find prior row + hash" sequence
--      is atomic.
--
--   2. **RLS performance discipline (CLAUDE.md).** Every B-tree index
--      leads with `operator_id` (or `(operator_id, chain_date, …)`).
--      `tool/rls_policy_lint.dart` checks policy bodies for bare
--      `current_setting('app.*')`; this migration uses the 9.0Σ.b
--      wrapper functions exclusively (`app_current_operator()`).
--
--   3. **Tz-naive timestamp columns are banned (CLAUDE.md time
--      guardrail).** Every timestamp column is `timestamptz`;
--      `chain_date` is a `date` derived from the audit row's UTC
--      `occurred_at` instant (the operator's local business-date is
--      irrelevant for chain partitioning — the chain is a hash
--      artifact, not an operator-facing reporting surface).
--
--   4. **service_principals attribution (B25 / item 14).**
--      `actor_kind text NOT NULL CHECK (actor_kind in ('user',
--      'service'))` is inline on the new table per the slice scope.
--      The matching `actor_principal_id` slot is on this table only;
--      the `service_principals` table itself and the `auth_events_audit`
--      `actor_kind` column are 9.0Σ.d-owned surfaces and explicitly
--      out of scope here.
--
--   5. **Append-only by grant shape.** Runtime roles get `INSERT` and
--      `SELECT` only; `UPDATE` and `DELETE` are revoked. Any
--      retention-driven removal goes through the partition-drop
--      cadence operated by the DBA via the runbook (the partitions
--      themselves are physical tables that can be `DETACH` + `DROP`ped
--      after the retention window). Mid-row redaction follows the
--      `forge_admin` break-glass procedure documented in
--      `runbooks/audit_chain_verify_runbook.md`.
--
--   6. **Anchor evidence is the durability anchor, not the row hash
--      itself.** The chain proves "no row in this operator/day was
--      mutated retroactively"; the Azure Blob immutable anchor proves
--      "the terminal hash F&F holds matches the one F&F published".
--      Together they bound retroactive tampering to "tampered before
--      the daily anchor ran" (a sub-24h window) instead of "could be
--      tampered any time after creation".

begin;

-- ─── pgcrypto (digest, gen_random_uuid) ─────────────────────────────
--
-- `pgcrypto` ships with PG and is on the Azure DB Flexible Server
-- extensions allowlist (CLAUDE.md Proxy & API Conventions). `digest()`
-- is the SHA-256 primitive the trigger uses; `gen_random_uuid()` is
-- already used by other operator-scoped tables but listed here to
-- make the dependency explicit.

create extension if not exists pgcrypto;

-- ─── pg_partman (daily range partitioning) ──────────────────────────
--
-- `pg_partman` ships in the Azure extensions allowlist and is the
-- locked partition-management tool for Phase 9 high-volume tables
-- (Phase 11a decision register Lock 2). Live verification on
-- staging + Production1 (2026-04-26) confirmed Azure installed the
-- extension into the `public` schema, so the verified function
-- names are `public.create_parent` and `public.run_maintenance`
-- and the config table is `public.part_config`. Calls below mirror
-- `db/verification/202604250006_advisor_schema_hardening_audits.sql`
-- byte-for-byte so the migration matches what the live hosts already
-- accept.
--
-- The registration call is wrapped in a re-runnable DO block: it
-- skips when `audit_logs` is already in `public.part_config`, so
-- re-runs are a no-op.

create extension if not exists pg_partman;

-- ─── audit_logs (partitioned by chain_date) ─────────────────────────
--
-- Partition key: `chain_date date not null` so pg_partman can rotate
-- daily child partitions (`audit_logs_p2026_04_28`, `…_2026_04_29`,
-- etc.) and the retention sweep can `DETACH` + `DROP` whole tables
-- past the 7-year retention floor (item 20 / Q9 — Tamper-evident
-- audit logs retain for 7 years by default; legal hold overrides
-- expiry).
--
-- Partitioned tables in PG 12+ require the partition key to be in
-- every UNIQUE / PRIMARY KEY index. The PK here is
-- `(operator_id, chain_date, id)` — tenant-leading per item 4, with
-- `chain_date` second so the partition pruning planner can fold the
-- date predicate, and `id` last to give each row a unique identifier
-- inside the chain.
--
-- `id bigserial` is shared across all partitions via a single sequence
-- on the parent (PG semantics). Within a partition the sequence values
-- are monotonic in insert order, which is what the chain's
-- `ORDER BY id` previous-row lookup relies on.
--
-- `actor_kind` is inline per item 14 (service_principals) and the
-- slice scope: NEW table only — the `auth_events_audit` rewrite to
-- add the same column is owned by 9.0Σ.d and explicitly forbidden
-- here.
--
-- `actor_user_id` carries the human-actor case; `actor_principal_id`
-- carries the service-principal subject (`sp:<id>` JWT subjects, per
-- CLAUDE.md "Service principals"). Exactly one of the two is set per
-- row, guarded by the `audit_logs_actor_shape_check` constraint.
--
-- `target_kind` / `target_id` describe the entity the action affected
-- (e.g. `target_kind = 'user'`, `target_id = '<user_uuid>'`). They are
-- NULL when the action has no target (e.g. a system-health probe).
--
-- `payload jsonb` carries the action-specific details. `jsonb_typeof`
-- is constrained to `'object'` so the trigger's canonical encoding is
-- well-defined (a top-level array / scalar would pass `jsonb` typing
-- but break the canonical text the verifier reconstructs).
--
-- `prev_row_hash bytea` is NULL on the first row of every chain; the
-- trigger sets it from the latest row in `(operator_id, chain_date)`.
--
-- `row_hash bytea` is the SHA-256 of `coalesce(prev_row_hash, ''::
-- bytea) || canonical_payload_bytes`. `canonical_payload_bytes` is
-- built deterministically from the row's identifying columns + the
-- jsonb text representation (jsonb's text cast normalizes key order
-- and whitespace, so two semantically equal payloads hash to the same
-- bytes).

create table if not exists public.audit_logs (
  id bigserial,
  operator_id uuid not null
    references public.operators(operator_id) on delete cascade,
  location_id uuid null,
  chain_date date not null,
  occurred_at timestamptz not null default now(),
  actor_kind text not null
    check (actor_kind in ('user', 'service')),
  actor_user_id uuid null,
  actor_principal_id text null,
  target_kind text null,
  target_id text null,
  action text not null
    check (char_length(action) between 1 and 200),
  payload jsonb not null default '{}'::jsonb
    check (jsonb_typeof(payload) = 'object')
    check (octet_length(payload::text) <= 262144),
  prev_row_hash bytea null,
  row_hash bytea not null,
  -- Exactly-one actor identifier per kind. `user` → actor_user_id
  -- must be set, actor_principal_id must be NULL. `service` → the
  -- inverse. Without this CHECK a producer could insert a service-
  -- attributed row with a stray actor_user_id and the audit trail
  -- would be ambiguous.
  constraint audit_logs_actor_shape_check check (
    (actor_kind = 'user'
      and actor_user_id is not null
      and actor_principal_id is null)
    or
    (actor_kind = 'service'
      and actor_principal_id is not null
      and actor_user_id is null)
  ),
  -- chain_date must match the UTC date of occurred_at so the chain
  -- partition is deterministic from the row data alone (the verifier
  -- relies on this to walk a chain by `(operator_id, chain_date)`
  -- without trusting an externally-supplied chain_date).
  constraint audit_logs_chain_date_matches_occurred_at check (
    chain_date = (occurred_at at time zone 'UTC')::date
  ),
  primary key (operator_id, chain_date, id)
) partition by range (chain_date);

comment on table public.audit_logs is
  'Phase 9.0Σ.f (item 13) — hash-chained, append-only audit log. '
  'Chain scope: (operator_id, chain_date) — bounded per Scale '
  'Pressure-Test Guardrail #1 so concurrent operators/days do not '
  'contend on a single global chain. Daily Azure Blob immutable '
  'anchor lives in audit_chain_anchors. service_role / forge_admin '
  'have INSERT/SELECT only; UPDATE/DELETE require the break-glass '
  'DBA procedure documented in runbooks/audit_chain_verify_runbook.md.';

comment on column public.audit_logs.chain_date is
  'UTC business date of occurred_at. Bounds the hash chain so '
  'concurrent chains run in parallel. CHECK constraint forbids a '
  'chain_date that disagrees with occurred_at — the verifier relies '
  'on this to walk a chain without trusting external chain_date.';

comment on column public.audit_logs.prev_row_hash is
  'SHA-256 of the previous row in (operator_id, chain_date), or NULL '
  'for the first row of a chain. Set by the BEFORE INSERT trigger; '
  'producer-supplied values are overwritten.';

comment on column public.audit_logs.row_hash is
  'SHA-256 of (prev_row_hash || canonical_payload). Computed by the '
  'BEFORE INSERT trigger so any retroactive mutation is detectable '
  'from the next row''s hash forward.';

-- ─── BEFORE INSERT trigger: hash chain ──────────────────────────────
--
-- The trigger function:
--
--   1. Acquires `pg_advisory_xact_lock` keyed on the
--      `(operator_id, chain_date)` chain. This serializes concurrent
--      inserts on the same chain WITHIN the same transaction lifetime;
--      different chains run in parallel without contention. Advisory
--      locks are transactional so the lock is released on commit/
--      rollback automatically.
--
--   2. Looks up the most-recent existing row for that chain via
--      `ORDER BY id DESC LIMIT 1`. Sets `NEW.prev_row_hash` to that
--      row's `row_hash`, or NULL when this is the first row.
--
--   3. Builds a canonical byte string from the row's identifying
--      columns and the jsonb text representation. The encoding is
--      deterministic: NUL-separated fields, NULL ↔ empty string. The
--      verifier (`tool/audit_anchor verify`) reconstructs the exact
--      same bytes when recomputing each row's hash.
--
--   4. Computes `NEW.row_hash = digest(coalesce(prev_row_hash,''::
--      bytea) || canonical, 'sha256')`. The CHECK constraint on
--      `row_hash NOT NULL` would reject a producer that bypassed the
--      trigger; the trigger always wins because it is BEFORE INSERT.

create or replace function public.audit_logs_set_chain()
returns trigger
language plpgsql
as $$
declare
  prev bytea;
  canonical bytea;
begin
  -- Lock the (operator_id, chain_date) chain for the duration of
  -- this transaction. hashtextextended takes a text and returns a
  -- bigint; combining operator_id + chain_date into a single key
  -- means different chains take different advisory locks and run
  -- in parallel.
  perform pg_advisory_xact_lock(
    hashtextextended(
      new.operator_id::text || ':' || new.chain_date::text,
      0
    )
  );

  -- Most-recent prior row in this chain. ORDER BY id DESC because
  -- the bigserial assigns monotonically within (operator_id,
  -- chain_date) for inserts the trigger has serialized.
  select row_hash
    into prev
    from public.audit_logs
   where operator_id = new.operator_id
     and chain_date  = new.chain_date
   order by id desc
   limit 1;

  new.prev_row_hash := prev;

  -- Canonical encoding: explicit NUL-separated fields. NULL columns
  -- collapse to empty strings so the verifier can reproduce the bytes
  -- without ambiguity. The jsonb text cast (`payload::text`)
  -- normalizes key order and whitespace per PG jsonb storage, so two
  -- semantically equal payloads hash identically.
  canonical := convert_to(
    coalesce(new.operator_id::text, '')           || E'\x00' ||
    coalesce(new.location_id::text, '')           || E'\x00' ||
    coalesce(new.chain_date::text, '')            || E'\x00' ||
    coalesce(
      to_char(new.occurred_at at time zone 'UTC',
              'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
      ''
    )                                             || E'\x00' ||
    coalesce(new.actor_kind, '')                  || E'\x00' ||
    coalesce(new.actor_user_id::text, '')         || E'\x00' ||
    coalesce(new.actor_principal_id, '')          || E'\x00' ||
    coalesce(new.target_kind, '')                 || E'\x00' ||
    coalesce(new.target_id, '')                   || E'\x00' ||
    coalesce(new.action, '')                      || E'\x00' ||
    coalesce(new.payload::text, '')               || E'\x00',
    'UTF8'
  );

  new.row_hash := digest(
    coalesce(new.prev_row_hash, ''::bytea) || canonical,
    'sha256'
  );

  return new;
end;
$$;

comment on function public.audit_logs_set_chain() is
  'Phase 9.0Σ.f (item 13) — sets prev_row_hash and computes row_hash '
  'on every audit_logs INSERT. Acquires pg_advisory_xact_lock on '
  '(operator_id, chain_date) so concurrent inserts on the same chain '
  'serialize without blocking different chains. Producer-supplied '
  'prev_row_hash / row_hash values are overwritten.';

drop trigger if exists audit_logs_set_chain_trg on public.audit_logs;
create trigger audit_logs_set_chain_trg
before insert on public.audit_logs
for each row execute function public.audit_logs_set_chain();

-- ─── pg_partman registration (idempotent) ───────────────────────────
--
-- Daily range partitioning, 7 days premade so a clock skew or a
-- delayed maintenance run cannot leave a producer without a
-- partition. The guard reads from `public.part_config` (verified
-- 2026-04-26: Azure installed pg_partman into the public schema).
-- Argument shape mirrors the verified live-Azure pattern in
-- `db/verification/202604250006_advisor_schema_hardening_audits.sql`
-- and `phase_11a_decision_register.md` Lock 2:
-- `public.create_parent(...)` with `p_default_table := false` and
-- `p_jobmon := false`. Daily interval is `'1 day'` (pg_partman v5
-- accepts a Postgres interval expression).

do $$
begin
  if not exists (
    select 1 from public.part_config
     where parent_table = 'public.audit_logs'
  ) then
    perform public.create_parent(
      p_parent_table  := 'public.audit_logs',
      p_control       := 'chain_date',
      p_interval      := '1 day',
      p_premake       := 7,
      p_default_table := false,
      p_jobmon        := false
    );
  end if;
end;
$$;

-- pg_partman maintenance is invoked from
-- `public.run_maintenance(p_analyze := true)` on a scheduled cadence
-- (lands with `pg_cron` in the rollups slice 9.0Σ.k; pattern matches
-- `cron.schedule('partman_maintenance', '0 * * * *', $$SELECT
-- public.run_maintenance(p_analyze := true)$$)`). The intent is
-- recorded here so the cadence wire-up reads the same configuration.
-- Daily premake = 7 keeps a week's worth of partitions ahead of the
-- producer; `retention_keep_table = true` so the DBA partition-drop
-- procedure (runbook) decides retention rather than pg_partman.
update public.part_config
   set premake                  = 7,
       retention_keep_table     = true,
       infinite_time_partitions = true
 where parent_table = 'public.audit_logs';

-- ─── Tenant-leading indexes ─────────────────────────────────────────
--
-- Every B-tree index leads with `operator_id` so the per-tenant RLS
-- policy folds into the index probe (item 4). The PK already covers
-- `(operator_id, chain_date, id)`; the indexes below cover the four
-- query shapes the verifier and downstream review surfaces use:
--
--   * Chain walk:    `WHERE operator_id = $1 AND chain_date = $2
--                       ORDER BY id` — covered by the PK.
--   * Actor lookup:  `WHERE operator_id = $1 AND actor_user_id = $2`
--                    or `actor_principal_id = $2`.
--   * Target lookup: `WHERE operator_id = $1 AND target_kind = $2
--                       AND target_id = $3`.
--   * Time lookup:   `WHERE operator_id = $1 AND occurred_at BETWEEN
--                       $2 AND $3`.
--
-- Partitioned-table indexes are auto-propagated to every child
-- partition by PG 11+; declaring them on the parent is sufficient.

create index if not exists audit_logs_actor_user_idx
  on public.audit_logs (operator_id, actor_user_id, occurred_at)
  where actor_user_id is not null;

create index if not exists audit_logs_actor_principal_idx
  on public.audit_logs (operator_id, actor_principal_id, occurred_at)
  where actor_principal_id is not null;

create index if not exists audit_logs_target_idx
  on public.audit_logs (operator_id, target_kind, target_id, occurred_at)
  where target_kind is not null;

create index if not exists audit_logs_time_idx
  on public.audit_logs (operator_id, occurred_at);

-- ─── RLS policies (wrapper-only per 9.0Σ.b) ─────────────────────────
--
-- Two policies, mirroring the auth-table + event_outbox pattern:
--
--   * `audit_logs_per_tenant_select` — tenants read only their own
--     rows. The audit-review surface in 11A uses this; cross-operator
--     F&F admin reads go through `forge_admin BYPASSRLS` via
--     `runAsSystem`.
--
--   * `audit_logs_per_tenant_insert` — INSERT-only, scoped to the
--     tenant's operator. UPDATE/DELETE have NO matching policy AND no
--     grants (see Grants section below); both axes must agree to
--     keep the table append-only.

alter table public.audit_logs enable row level security;

create policy "audit_logs_per_tenant_select"
  on public.audit_logs for select to service_role
  using (operator_id = public.app_current_operator());

create policy "audit_logs_per_tenant_insert"
  on public.audit_logs for insert to service_role
  with check (operator_id = public.app_current_operator());

comment on policy "audit_logs_per_tenant_select" on public.audit_logs is
  'Phase 9.0Σ.f — tenants and the verifier (running inside a tenant '
  'transaction) see only their own audit rows. Cross-tenant reads '
  'require forge_admin BYPASSRLS via runAsSystem with a non-blank '
  'audit reason.';

comment on policy "audit_logs_per_tenant_insert" on public.audit_logs is
  'Phase 9.0Σ.f — producers may only insert rows attributed to their '
  'own operator. No matching UPDATE/DELETE policy AND no UPDATE/'
  'DELETE grants (see grants block) so the table is append-only by '
  'two-axis enforcement.';

-- ─── Append-only grants ─────────────────────────────────────────────
--
-- service_role + forge_admin both get INSERT and SELECT only.
-- UPDATE and DELETE are explicitly REVOKEd so a future grant change
-- cannot accidentally weaken the posture without an explicit
-- reviewer's notice. The break-glass DBA procedure (runbook) issues a
-- transaction-scoped GRANT/REVOKE pair so elevated privilege exists
-- only for the lifetime of that one transaction.
--
-- bigserial sequence USAGE: producers need it to allocate ids on
-- insert. PG names the sequence after the parent table column
-- (audit_logs_id_seq); USAGE alone is sufficient since SELECT on the
-- sequence is not required for nextval().

revoke all on public.audit_logs from public;
grant select, insert on public.audit_logs to service_role;
grant select, insert on public.audit_logs to forge_admin;
grant usage on sequence public.audit_logs_id_seq to service_role;
grant usage on sequence public.audit_logs_id_seq to forge_admin;

-- Defensive REVOKE: in case a future migration pattern grants the
-- broader DML set out of habit, this re-asserts the append-only
-- posture. CI lint reads this block as the authoritative posture for
-- the slice.
revoke update, delete on public.audit_logs from service_role;
revoke update, delete on public.audit_logs from forge_admin;

-- ─── audit_chain_anchors (anchor-state ledger) ──────────────────────
--
-- One row per `(operator_id, chain_date)` once the
-- `tool/audit_anchor anchor` job has written the day's evidence to
-- the F&F immutable Azure Blob container. The row records:
--
--   * `terminal_row_hash`  — the row_hash of the last row in the
--                            chain at anchor time. Re-anchoring (e.g.
--                            after a verification run) MUST produce
--                            the same value or the verifier raises an
--                            anchor-mismatch alert.
--   * `terminal_row_id`    — the bigserial id of that last row. Lets
--                            the verifier walk the chain from row 1
--                            to terminal_row_id and stop deterministi-
--                            cally even if new rows land after the
--                            anchor (those belong to the next day's
--                            chain by chain_date scope).
--   * `row_count`          — count of rows in the chain at anchor
--                            time. Forensic cross-check against the
--                            verifier's recomputed count.
--   * `blob_uri`           — the immutable Blob URI (no SAS token, no
--                            account key). The runbook describes how
--                            to resolve the URI to the evidence
--                            object via the operator's Azure tenant.
--   * `blob_etag`          - the immutable Blob ETag at write time
--                            (Azure Blob immutability stamps an ETag
--                            on the immutable version; the verifier
--                            re-reads the Blob and compares ETags).
--   * `anchored_at`        — when the anchor row was written.
--
-- Append-only: SELECT/INSERT only for runtime roles, no UPDATE/DELETE.
-- Re-anchoring a chain requires a separate one-shot DBA procedure if
-- the original anchor row was wrong (legal-hold scenario only).

create table if not exists public.audit_chain_anchors (
  operator_id uuid not null
    references public.operators(operator_id) on delete cascade,
  chain_date date not null,
  terminal_row_hash bytea not null,
  terminal_row_id bigint not null,
  row_count bigint not null
    check (row_count >= 1),
  blob_uri text not null
    check (char_length(blob_uri) between 1 and 2048),
  blob_etag text not null
    check (char_length(blob_etag) between 1 and 256),
  anchored_at timestamptz not null default now(),
  primary key (operator_id, chain_date)
);

comment on table public.audit_chain_anchors is
  'Phase 9.0Σ.f (item 13) — daily Azure Blob immutable anchor ledger. '
  'One row per (operator_id, chain_date) once tool/audit_anchor has '
  'written that day''s evidence Blob. Append-only at the grant shape; '
  'forge_admin BYPASSRLS handles cross-operator anchor maintenance.';

-- Tenant-leading retrieval — anchored chains are typically pulled by
-- (operator_id, chain_date desc) for a "recent anchors" panel.
create index if not exists audit_chain_anchors_recent_idx
  on public.audit_chain_anchors (operator_id, chain_date desc);

alter table public.audit_chain_anchors enable row level security;

create policy "audit_chain_anchors_per_tenant_select"
  on public.audit_chain_anchors for select to service_role
  using (operator_id = public.app_current_operator());

create policy "audit_chain_anchors_per_tenant_insert"
  on public.audit_chain_anchors for insert to service_role
  with check (operator_id = public.app_current_operator());

comment on policy "audit_chain_anchors_per_tenant_select" on public.audit_chain_anchors is
  'Phase 9.0Σ.f — tenants read only their own anchor rows. Wrapper-'
  'only via app_current_operator() (item 4).';

comment on policy "audit_chain_anchors_per_tenant_insert" on public.audit_chain_anchors is
  'Phase 9.0Σ.f — anchor inserts may only attribute to the tenant''s '
  'operator. No UPDATE/DELETE policy and no UPDATE/DELETE grants.';

revoke all on public.audit_chain_anchors from public;
grant select, insert on public.audit_chain_anchors to service_role;
grant select, insert on public.audit_chain_anchors to forge_admin;
revoke update, delete on public.audit_chain_anchors from service_role;
revoke update, delete on public.audit_chain_anchors from forge_admin;

commit;
