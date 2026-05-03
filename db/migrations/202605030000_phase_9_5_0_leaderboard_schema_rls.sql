-- Phase 9.5.0 — El Podio leaderboard schema + per-tenant RLS.
--
-- Backend skeleton for the El Podio learning leaderboard. The phase 9.5
-- plan replaces the demo-only `el_podio_demo_data.dart` consumer with a
-- real authenticated multi-user board sourced from durable Postgres
-- truth. UX (operator/staff-facing leaderboard surfaces) lands in the
-- 9.5.UX slice; this slice owns ONLY the table + RLS posture + thin
-- repository skeleton so 9.5.x consumers have a stable shape to bind
-- against.
--
-- Hard rules carried verbatim from CLAUDE.md (Authority Order item 5):
--
--   1. **RLS-Ready Schema (CLAUDE.md).** The fact table includes
--      `(operator_id, location_id)` from creation; single-location
--      operators run with the operator's `primary_location_id` injected
--      as the default `location_id`. Scaffolding is NOT retrofitted
--      later.
--
--   2. **OperatorScopedRepository is the primary defense; RLS is the
--      backup.** This migration ships the secondary defense. The
--      repository (lib/infrastructure/persistence/postgres/repositories/
--      leaderboard_score_repository.dart) carries the SET LOCAL ordering
--      and the tenant-scoped INSERT/SELECT shape so a missing or
--      malformed RLS policy cannot leak rows even before the policy is
--      evaluated.
--
--   3. **Wrapper-only RLS posture (Phase 9.0Σ.b item 4).** Every policy
--      body calls the locked
--      `STABLE LEAKPROOF PARALLEL SAFE` wrapper functions
--      (`app_current_operator()`, `app_current_location()`,
--      `app_current_actor_user()`). No bare
--      `current_setting('app.<name>', true)::uuid` reads — the
--      `tool/rls_policy_lint.dart` rule rejects them.
--
--   4. **Tenant-leading B-tree indexes (CLAUDE.md / 9.0Σ.b item 4).**
--      Every B-tree index leads with `operator_id` (or `(operator_id,
--      location_id)`) so the planner can fold the per-tenant policy
--      into the index probe. CI lint enforces.
--
--   5. **Time guardrails (CLAUDE.md, phase_7_55_time_boundary_contract).**
--      `occurred_at` is `timestamptz` (UTC source-truth instant);
--      `business_date` is a denormalized `date` computed at write from
--      the operator's location timezone + `business_day_rollover_hour`.
--      The repository derives `business_date` from the same instant so
--      the DB does not need to read `locations` in the hot path; a
--      CHECK constraint guards against malformed dates (1900-01-01 or
--      later) without recomputing the projection in SQL.
--
--   6. **Append-only fact-table grants.** `service_role` and
--      `forge_admin` get INSERT and SELECT on `leaderboard_scores`;
--      UPDATE/DELETE are explicitly REVOKEd. Score events are
--      immutable history — re-ranking is a read-side projection over
--      the append log, not a row-level mutation. Retention sweeps are
--      a Phase 9.5.x follow-up (the Operations El Podio phase will
--      decide retention windows by score_event_type).
--
-- Live apply status:
--   * NOT YET APPLIED. The Phase 9.5 launch lane will apply this on
--     staging + Production1 once 9.5.UX has shipped enough surface to
--     justify a board-level migration apply window. The migration is
--     idempotent (`if not exists` on table + indexes; `drop policy if
--     exists` before `create policy`) so re-running it is safe.

begin;

-- ─── leaderboard_scores ─────────────────────────────────────────────
--
-- Append-only ledger of learning-derived score events per authenticated
-- user. The launch leaderboard projects this table by
-- `(operator_id, user_id, time_window)` to compute weekly / monthly /
-- all-time ranks; the projection lives in the repository / read service
-- (Phase 9.5.x), not in this migration.
--
-- Column rationale:
--
--   * `score_event_id` — surrogate UUID PK so re-emit detection is
--     possible at the consumer layer (Phase 9.75 Recognition badge
--     awards include an idempotency key that the producer maps to this
--     id).
--   * `operator_id` / `location_id` — RLS-Ready scaffolding. Composite
--     FK against `public.locations(operator_id, location_id)` so a row
--     attributed to a location that doesn't belong to the operator is
--     rejected at the DB layer. Single-location operators inject the
--     operator's `primary_location_id` from `OperatorContext`.
--   * `user_id` — the authenticated learner. FK against `public.users`
--     with `on delete cascade` so a wiped user (GDPR erasure) takes
--     their score history with them; the leaderboard projection
--     re-renders without the row on the next read. Note the FK alone
--     does NOT bind user→operator; the per-tenant INSERT WITH CHECK
--     (below) carries that defense via a `users.operator_id` subquery.
--   * `score_event_type` — bounded text classifier of what kind of
--     learning event awarded the points. Examples drawn from the 9.5
--     plan / 9.75 dependency: `'mastery_complete'`, `'streak_day'`,
--     `'recognition_badge'`. The CHECK constraint enforces a
--     reasonable shape (1..64 chars, no leading/trailing whitespace);
--     the runtime / repository owns the canonical enum so a misspelled
--     event type fails fast in Dart before reaching the database.
--   * `points` — signed integer so a future correction event can
--     subtract points (e.g. badge revocation by 9.75). Bounds
--     [-100000, +100000] keep a single event's footprint sane; the
--     projection layer aggregates millions of small rows, not a few
--     huge ones.
--   * `occurred_at` — UTC source-truth instant. Primary timing axis.
--   * `business_date` — denormalized `date` computed at write from
--     `location.timezone` + `business_day_rollover_hour`. Used by
--     weekly / daily aggregations so the projection does not need to
--     timezone-convert on every read. CHECK guards against pre-2000
--     dates (any earlier value is a producer bug — leaderboards
--     started shipping in 2026). The CHECK does NOT re-derive the
--     projection in SQL because the repository must call the same
--     business-date helper that other operator-scoped writers use; a
--     SQL re-derivation would require reading `locations` in the hot
--     path.
--   * `payload` — small JSONB blob for event-type-specific metadata
--     (e.g. badge id, mastery topic, streak length). Bounded to 4 KiB
--     so a runaway producer cannot bloat the row. Default `'{}'`
--     keeps NULL handling simple at the projection layer.
--   * `created_at` — when the row landed in the DB. Primary use is
--     append-cadence telemetry, not user-visible time.

create table if not exists public.leaderboard_scores (
  score_event_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  user_id uuid not null
    references public.users(user_id) on delete cascade,
  score_event_type text not null
    check (
      char_length(score_event_type) between 1 and 64
      and score_event_type = btrim(score_event_type)
    ),
  points integer not null
    check (points between -100000 and 100000),
  occurred_at timestamptz not null,
  business_date date not null
    check (business_date >= date '2000-01-01'),
  payload jsonb not null default '{}'::jsonb
    check (jsonb_typeof(payload) = 'object')
    check (octet_length(payload::text) <= 4096),
  created_at timestamptz not null default now(),
  -- Composite FK keeps a row from being attributed to a location that
  -- doesn't belong to its operator. `public.locations` exposes a
  -- composite uniqueness target on `(operator_id, location_id)` per
  -- 202604250005_advisor_cloud_foundation.sql; this FK binds against
  -- it.
  constraint leaderboard_scores_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

comment on table public.leaderboard_scores is
  'Phase 9.5.0 — append-only ledger of El Podio learning score events. '
  'Per-tenant RLS via wrapper functions (operator_id leading); the '
  'projection layer (Phase 9.5.x) computes weekly / monthly / all-time '
  'ranks from this table. Append-only at the grant shape — corrections '
  'land as a fresh row with negative points, not as UPDATE/DELETE.';

comment on column public.leaderboard_scores.business_date is
  'Operator-local business date computed at write from '
  'location.timezone + location.business_day_rollover_hour (CLAUDE.md '
  'Time Guardrails). Denormalized so the rank projection does not have '
  'to read locations in the hot path.';

comment on column public.leaderboard_scores.points is
  'Signed; corrections (e.g. revoked Recognition badge) land as a '
  'fresh row with negative points so the append-only posture holds.';

-- ─── Operator-leading B-tree indexes ────────────────────────────────
--
-- Every B-tree index leads with `operator_id` (or `(operator_id,
-- location_id)`) so the per-tenant RLS policy folds into the index
-- probe rather than evaluating row-by-row (CLAUDE.md / 9.0Σ.b item 4;
-- enforced by `tool/rls_policy_lint.dart` index lint sweep).
--
-- Query shapes the projection layer relies on:
--
--   * Per-user totals:    WHERE operator_id = $1 AND user_id = $2
--                         [AND business_date BETWEEN $3 AND $4]
--   * Top-N for window:   WHERE operator_id = $1
--                         [AND business_date BETWEEN $3 AND $4]
--                         ORDER BY ...
--   * Per-location split: WHERE operator_id = $1 AND location_id = $2
--                         [AND business_date BETWEEN $3 AND $4]
--   * Recent activity:    WHERE operator_id = $1 ORDER BY occurred_at
--                         DESC

create index if not exists leaderboard_scores_operator_user_date_idx
  on public.leaderboard_scores
    (operator_id, user_id, business_date desc);

create index if not exists leaderboard_scores_operator_location_date_idx
  on public.leaderboard_scores
    (operator_id, location_id, business_date desc);

create index if not exists leaderboard_scores_operator_recent_idx
  on public.leaderboard_scores
    (operator_id, occurred_at desc);

-- ─── RLS policies (wrapper-only per 9.0Σ.b) ─────────────────────────
--
-- Two policies, mirroring the audit_logs / event_outbox pattern, plus
-- a user-tenant ownership subquery on INSERT modeled after
-- `role_permissions_per_tenant_modify` /
-- `role_audit_log_per_tenant_select` in
-- 202605020500_hardening_auth_rls_to_wrappers.sql:
--
--   * `leaderboard_scores_per_tenant_select` — tenants read only their
--     own rows. The board projection runs inside the tenant
--     transaction so the GUC injection from `runInTenantContext` makes
--     the wrapper return the correct UUID.
--
--   * `leaderboard_scores_per_tenant_insert` — INSERT-only, scoped to
--     the tenant's operator + location AND the scored user. The
--     `user_id IN (SELECT user_id FROM public.users WHERE operator_id
--     = app_current_operator())` subquery proves the scored user
--     belongs to the same operator the SET LOCAL stamped — without it
--     a tenant-A caller could attribute a score to a user_id that
--     belongs to operator B (the FK on `users(user_id)` admits any
--     valid user UUID; only the per-tenant `users.operator_id`
--     filter rejects cross-operator attribution). The subquery folds
--     against `users.operator_id` which is indexed via the FK against
--     `public.operators`. UPDATE/DELETE have NO matching policy AND
--     no grants (see Grants block below); both axes must agree to
--     keep the table append-only.
--
-- Idempotent — `drop policy if exists` before `create policy` so
-- re-running this migration after a hand-edit on staging restores the
-- canonical posture.

alter table public.leaderboard_scores enable row level security;

drop policy if exists "leaderboard_scores_per_tenant_select"
  on public.leaderboard_scores;
drop policy if exists "leaderboard_scores_per_tenant_insert"
  on public.leaderboard_scores;

create policy "leaderboard_scores_per_tenant_select"
  on public.leaderboard_scores for select to service_role
  using (operator_id = public.app_current_operator());

create policy "leaderboard_scores_per_tenant_insert"
  on public.leaderboard_scores for insert to service_role
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
    and user_id in (
      select user_id from public.users
      where operator_id = public.app_current_operator()
    )
  );

comment on policy "leaderboard_scores_per_tenant_select"
  on public.leaderboard_scores is
  'Phase 9.5.0 — tenants read only their own leaderboard rows via '
  'app_current_operator(). Cross-operator reads (admin support paths) '
  'go through forge_admin BYPASSRLS via runAsSystem.';

comment on policy "leaderboard_scores_per_tenant_insert"
  on public.leaderboard_scores is
  'Phase 9.5.0 — score events may only be attributed to the tenant''s '
  'own operator + location AND a user that belongs to that operator. '
  'The user-tenant subquery prevents a cross-operator attribution '
  'where the FK on users(user_id) alone would admit the row. No '
  'matching UPDATE/DELETE policy AND no UPDATE/DELETE grants: '
  'corrections land as a fresh row with negative points so the '
  'append-only posture holds.';

-- ─── Append-only grants ─────────────────────────────────────────────
--
-- service_role + forge_admin get INSERT + SELECT only. UPDATE / DELETE
-- are explicitly REVOKEd so a future grant change cannot silently
-- weaken the posture without an explicit reviewer's notice. The same
-- two-axis posture (no policy AND no grant) the audit_logs slice uses.

revoke all on public.leaderboard_scores from public;
grant select, insert on public.leaderboard_scores to service_role;
grant select, insert on public.leaderboard_scores to forge_admin;
revoke update, delete on public.leaderboard_scores from service_role;
revoke update, delete on public.leaderboard_scores from forge_admin;

commit;
