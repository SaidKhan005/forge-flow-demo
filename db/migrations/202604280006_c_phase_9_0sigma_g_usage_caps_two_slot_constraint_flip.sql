-- Phase 9.0Σ.g (B28 / item 6) — usage_caps + usage_logs two-slot key
-- migration, step 3 of 3: CONSTRAINT FLIP.
--
-- After step a (`..._a_add`) added the four cap-shape columns and
-- step b (`..._b_backfill`) populated `billing_owner_org_unit_id` and
-- `scoped_org_unit_id` on every existing row, this file:
--
--   1. SET NOT NULL on the two org-unit columns (now safe — every
--      existing row carries a non-NULL value).
--   2. Drop the legacy primary keys
--      (`usage_caps_pkey` on (operator_id, location_id, usage_class)
--      and `usage_logs_pkey` on the eleven-column rollup tuple).
--   3. Add a tenant-leading surrogate primary key on each table.
--      Surrogate is needed because the locked logical key carries
--      nullable axes (`staff_id`, `workflow_id`) — PostgreSQL forbids
--      NULL columns in a PRIMARY KEY, so we cannot encode the lock 6
--      shape directly as a PK and must use UNIQUE NULLS NOT DISTINCT
--      alongside the surrogate. This choice is documented in SQL
--      comments and asserted in the test
--      `test/phase_9_0sigma_g_usage_caps_two_slot_test.dart`.
--   4. Add `UNIQUE NULLS NOT DISTINCT` constraints that encode the
--      locked logical keys:
--        * usage_caps:  (operator_id,
--                        billing_owner_org_unit_id, scoped_org_unit_id,
--                        location_id, staff_id, workflow_id, usage_class)
--        * usage_logs:  same prefix, plus period_start + the
--                       seven telemetry dimensions from 202604250006
--                       (rollup identity must stay 1:1 with the
--                       cap-vs-actual reconciliation tuple).
--      `operator_id` is INCLUDED at the leading position so the index
--      stays tenant-leading per CLAUDE.md "RLS performance discipline"
--      and the lock 4 / item 4 audit. The lock 6 logical key carries
--      `billing_owner_org_unit_id` as the leading axis at the domain
--      level, but `org_units(operator_id, id)` is uniquely owned by a
--      single operator, so prefixing with `operator_id` does not
--      change the uniqueness contract — it just lets the planner fold
--      RLS into the index probe.
--   5. Add composite foreign keys to `org_units(operator_id, id)`
--      from both `billing_owner_org_unit_id` and `scoped_org_unit_id`
--      on each table. The composite shape — keyed on
--      `(operator_id, <org_unit_col>)` — rejects cross-tenant
--      mismatches at the database layer (an org_unit ID belonging to
--      operator B can never land on a row whose `operator_id` is
--      operator A). ON DELETE CASCADE matches the existing
--      locations FK from 202604250005 so operator/org_unit teardown
--      cleanly garbage-collects descendant cap and log rows.
--   6. Add tenant-leading indexes for cap lookup and cap-vs-actual
--      reconciliation. The UNIQUE constraints from step 4 already
--      provide tenant-leading lookup indexes; the explicit
--      reconciliation index on `usage_logs` (cap-shape only, no
--      telemetry tail) is added so the join planner has a narrow
--      index for the reconciliation aggregate without scanning the
--      wider rollup-identity index.
--   7. Grant `service_role` and `forge_admin` the DML privileges
--      required to read/write through RLS — privileges are checked
--      *before* RLS, so without grants the policies never get a
--      chance to evaluate. NOT adding a `forge_admin` RLS policy
--      per the slice constraint; `forge_admin` already has BYPASSRLS
--      from 202604260000 and grants are sufficient.
--
-- Hard constraints (block 2 of the slice prompt):
--   * No edits to applied migrations.
--   * No `forge_admin` RLS policy added (the existing
--     `*_service_role_all` stubs from 202604250005 stay untouched —
--     they predate the wrapper-function rule and are the subject of
--     a separate cloud-foundation RLS flip in B10).
--   * No bare `current_setting('app...')` calls anywhere — this
--     migration adds no policy bodies, so the RLS lint
--     (`tool/rls_policy_lint.dart`) trivially passes.
--   * No actor_kind, sp:-prefixed JWT, audit_logs, service principals,
--     or proxy hot-zone changes — those land in disjoint slices.
--
-- The proxy upsert SQL (`ProxyUsageLogSql.atomicUpsert` in
-- `tool/advisor_proxy/advisor_proxy.dart`) targets the OLD eleven-
-- column primary key as its ON CONFLICT key. After this migration
-- applies, that ON CONFLICT target no longer exists and the upsert
-- must be retargeted to the new wide UNIQUE NULLS NOT DISTINCT key
-- (`usage_logs_two_slot_rollup_uq`). The slice constraints forbid
-- touching the proxy hot-zone files, so the upsert update is
-- recorded as a follow-up. This migration is therefore safe for
-- local schema testing but MUST NOT be applied to a live database
-- until the proxy upsert + accounting service are taught the new
-- shape (tracked alongside `lib/services/advisor/usage_*.dart`,
-- which does not exist yet).
--
-- Idempotent: every constraint/index DDL uses
-- `drop constraint if exists` / `create ... if not exists`. SET NOT
-- NULL is a no-op on a column that is already NOT NULL.

begin;

-- ─── usage_caps: SET NOT NULL on org-unit columns ──────────────────

alter table public.usage_caps
  alter column billing_owner_org_unit_id set not null;

alter table public.usage_caps
  alter column scoped_org_unit_id set not null;

-- ─── usage_logs: SET NOT NULL on org-unit columns ──────────────────
--
-- usage_logs is partitioned by `period_start`. PG 12+ propagates
-- `ALTER COLUMN ... SET NOT NULL` from the partitioned parent to
-- every partition (including `usage_logs_default`); no per-partition
-- repeat is needed.

alter table public.usage_logs
  alter column billing_owner_org_unit_id set not null;

alter table public.usage_logs
  alter column scoped_org_unit_id set not null;

-- ─── Surrogate PK columns ──────────────────────────────────────────
--
-- The locked logical keys carry nullable `staff_id` / `workflow_id`
-- axes; PostgreSQL forbids NULL columns in a PRIMARY KEY, so the
-- shape cannot be a literal PK. We add a UUID surrogate per table
-- and pair it with `UNIQUE NULLS NOT DISTINCT` to enforce the
-- logical key separately. The surrogate carries `default
-- gen_random_uuid()` so existing rows receive unique values during
-- the ADD COLUMN rewrite (`pgcrypto` is enabled by 202604250005).
--
-- The PK is `(operator_id, <surrogate>)` — tenant-leading so RLS
-- evaluation folds into the index probe, and unique because the
-- surrogate is itself a UUID. usage_logs adds `period_start` to
-- the PK because partitioned tables require the partition key in
-- every unique constraint.

alter table public.usage_caps
  add column if not exists cap_id uuid not null default gen_random_uuid();

comment on column public.usage_caps.cap_id is
  'Phase 9.0Σ.g (item 6) — surrogate primary key. The locked logical '
  'key carries nullable staff_id / workflow_id axes; PostgreSQL '
  'forbids NULL columns in a PRIMARY KEY, so the cap key shape lives '
  'on the UNIQUE NULLS NOT DISTINCT constraint usage_caps_two_slot_uq '
  'and cap_id is the tenant-leading PK companion. cap_id is also a '
  'stable trace identifier for response payloads / audit rows.';

alter table public.usage_logs
  add column if not exists log_id uuid not null default gen_random_uuid();

comment on column public.usage_logs.log_id is
  'Phase 9.0Σ.g (item 6) — surrogate primary-key companion. Same '
  'rationale as cap_id (nullable axes block a literal PK on the '
  'logical key). The full rollup identity lives on '
  'usage_logs_two_slot_rollup_uq (UNIQUE NULLS NOT DISTINCT, '
  'partition-key-included).';

-- ─── usage_caps: drop legacy PK, attach surrogate PK ──────────────

alter table public.usage_caps
  drop constraint if exists usage_caps_pkey;

alter table public.usage_caps
  add constraint usage_caps_pkey
  primary key (operator_id, cap_id);

-- ─── usage_logs: drop legacy PK, attach surrogate PK ──────────────
--
-- Partitioned-table PK must include the partition key column
-- (`period_start`); the new PK shape `(operator_id, log_id,
-- period_start)` honors that requirement and stays tenant-leading.

alter table public.usage_logs
  drop constraint if exists usage_logs_pkey;

alter table public.usage_logs
  add constraint usage_logs_pkey
  primary key (operator_id, log_id, period_start);

-- ─── usage_caps: logical-key UNIQUE (NULLS NOT DISTINCT) ──────────
--
-- The lock 6 logical key is
--
--   (billing_owner_org_unit_id, scoped_org_unit_id,
--    location_id, staff_id, workflow_id, usage_class)
--
-- Reasons for the column-order choice:
--   * `operator_id` leads so the index is tenant-leading (lock 4 /
--     item 4 / RLS performance discipline). Adding it does not
--     change uniqueness because each `org_units(id)` is owned by
--     exactly one operator (composite FK below).
--   * `staff_id` and `workflow_id` are nullable; NULLS NOT DISTINCT
--     means two rows that both have NULL on those axes still
--     collide on the constraint — exactly the semantics the cap
--     surface needs (one "all-staff" cap per (billing, scoped,
--     location, usage_class) tuple).

alter table public.usage_caps
  drop constraint if exists usage_caps_two_slot_uq;

alter table public.usage_caps
  add constraint usage_caps_two_slot_uq
  unique nulls not distinct (
    operator_id,
    billing_owner_org_unit_id,
    scoped_org_unit_id,
    location_id,
    staff_id,
    workflow_id,
    usage_class
  );

comment on constraint usage_caps_two_slot_uq on public.usage_caps is
  'Phase 9.0Σ.g (item 6) — locked logical key. NULLS NOT DISTINCT so '
  'NULL staff_id / workflow_id rows collide on the cap identity '
  '(one "all-staff" or "all-workflow" cap per scope). operator_id is '
  'the leading column for tenant-leading RLS pushdown; uniqueness '
  'across operators is unaffected because billing_owner / scoped '
  'org_unit IDs are owned by exactly one operator (composite FK).';

-- ─── usage_logs: rollup-identity UNIQUE (NULLS NOT DISTINCT) ──────
--
-- The locked reconciliation identity for usage_logs is
--
--   cap-shape columns + period_start + telemetry dimensions
--
-- The cap-shape prefix matches `usage_caps_two_slot_uq`; the suffix
-- preserves the seven telemetry dimensions from 202604250006
-- (query_class, cache_hit, llm_tier, model_used, batch_mode,
-- circuit_state, fallback_used) so a Haiku cache hit and a Sonnet
-- fallback miss never collapse into the same counter row. The
-- partition key (`period_start`) is included at the cap-shape
-- boundary because partitioned-table UNIQUE constraints must
-- contain the partition key.

alter table public.usage_logs
  drop constraint if exists usage_logs_two_slot_rollup_uq;

alter table public.usage_logs
  add constraint usage_logs_two_slot_rollup_uq
  unique nulls not distinct (
    operator_id,
    billing_owner_org_unit_id,
    scoped_org_unit_id,
    location_id,
    staff_id,
    workflow_id,
    usage_class,
    period_start,
    query_class,
    cache_hit,
    llm_tier,
    model_used,
    batch_mode,
    circuit_state,
    fallback_used
  );

comment on constraint usage_logs_two_slot_rollup_uq on public.usage_logs is
  'Phase 9.0Σ.g (item 6) — full rollup identity. Cap-shape prefix '
  'matches usage_caps_two_slot_uq for one-pass reconciliation joins; '
  'period_start + seven telemetry dimensions preserve the rollup '
  'split from 202604250006 (a Haiku cache hit and a Sonnet fallback '
  'miss must never aggregate into the same counter row). NULLS NOT '
  'DISTINCT covers the nullable staff/workflow axes; tenant-leading '
  'so the planner folds RLS into the index probe.';

-- ─── Composite FKs to org_units ────────────────────────────────────
--
-- Both columns reference `org_units(operator_id, id)` — the unique
-- pair declared in 202604280002. Composite FK (operator_id, org_unit)
-- → (operator_id, id) rejects cross-tenant mismatches: an org_unit ID
-- belonging to operator B cannot land on a row whose operator_id is
-- operator A, even if some bug bypassed application-layer checks.
-- ON DELETE CASCADE matches the existing locations FK from
-- 202604250005 so operator/org_unit teardown garbage-collects cap
-- and log rows in one cascade chain (operators → org_units → caps,
-- and operators → locations → caps independently).

alter table public.usage_caps
  drop constraint if exists usage_caps_billing_owner_org_unit_fk;

alter table public.usage_caps
  add constraint usage_caps_billing_owner_org_unit_fk
  foreign key (operator_id, billing_owner_org_unit_id)
  references public.org_units(operator_id, id)
  on delete cascade;

alter table public.usage_caps
  drop constraint if exists usage_caps_scoped_org_unit_fk;

alter table public.usage_caps
  add constraint usage_caps_scoped_org_unit_fk
  foreign key (operator_id, scoped_org_unit_id)
  references public.org_units(operator_id, id)
  on delete cascade;

alter table public.usage_logs
  drop constraint if exists usage_logs_billing_owner_org_unit_fk;

alter table public.usage_logs
  add constraint usage_logs_billing_owner_org_unit_fk
  foreign key (operator_id, billing_owner_org_unit_id)
  references public.org_units(operator_id, id)
  on delete cascade;

alter table public.usage_logs
  drop constraint if exists usage_logs_scoped_org_unit_fk;

alter table public.usage_logs
  add constraint usage_logs_scoped_org_unit_fk
  foreign key (operator_id, scoped_org_unit_id)
  references public.org_units(operator_id, id)
  on delete cascade;

-- ─── Reconciliation index on usage_logs ────────────────────────────
--
-- The cap-vs-actual aggregate join (sum log token/cost rows for each
-- cap) only needs the cap-shape columns; the telemetry tail and
-- `period_start` are scanned afterward inside the matched cap
-- partition. A narrow tenant-leading index keyed on the cap shape
-- alone gives the planner a compact lookup target without forcing it
-- to traverse the wider rollup-identity index. The
-- `usage_logs_two_slot_rollup_uq` UNIQUE constraint above already
-- provides one cap-shape-leading index, but its trailing eight
-- columns make it heavy for the aggregate-only join — keeping a
-- second narrow index is cheap and stable across PG versions /
-- planner choices.

create index if not exists usage_logs_cap_reconciliation_idx
  on public.usage_logs (
    operator_id,
    billing_owner_org_unit_id,
    scoped_org_unit_id,
    location_id,
    staff_id,
    workflow_id,
    usage_class
  );

comment on index public.usage_logs_cap_reconciliation_idx is
  'Phase 9.0Σ.g (item 6) — narrow cap-shape lookup for cap-vs-actual '
  'reconciliation joins. Tenant-leading on operator_id; mirrors the '
  'cap-side usage_caps_two_slot_uq prefix so the planner reaches '
  'matching log rows in a single indexed pass.';

-- ─── Privileges ────────────────────────────────────────────────────
--
-- service_role + forge_admin both need DML so the runtime + admin
-- paths can read and write usage rows. Privileges are checked before
-- RLS; without GRANTs the policies never get evaluated. forge_admin
-- already carries BYPASSRLS from 202604260000, so a forge_admin
-- policy is intentionally NOT added — grants alone suffice. Granting
-- on the partitioned parent does not automatically propagate to
-- existing partitions for every PG version, so the default partition
-- carries an explicit grant too.

grant select, insert, update, delete on public.usage_caps to service_role;
grant select, insert, update, delete on public.usage_caps to forge_admin;

grant select, insert, update, delete on public.usage_logs to service_role;
grant select, insert, update, delete on public.usage_logs to forge_admin;

grant select, insert, update, delete on public.usage_logs_default to service_role;
grant select, insert, update, delete on public.usage_logs_default to forge_admin;

commit;
