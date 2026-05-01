# Database migrations summary

Auto-generated from `db/migrations/*.sql` by
`scripts/generate_migrations_summary.py` (daily 7am routine).

Architectural index of `db/migrations/` for the knowledge graph.
The `.sql` files are not extension-supported by graphify; this
summary stands in for them so the graph captures migration shape.

Migration count: **35**

## `202604250000_advisor_roles.sql`

- **Applied:** 2026-04-25 00:00
- **Title:** advisor roles
- **Description:**

  Phase 11a.11c.5 — Role bootstrap for generic Postgres deployments.

  Existing advisor migrations (202604250001 onward) attach RLS
  policies to two named roles: `service_role` and `authenticated`.
  These names are conventions Supabase ships pre-created; on a generic
  Postgres host (Azure Database for PostgreSQL, local Docker dev, or
  bare metal) they do not exist by default, so the very first advisor
  migration would fail at the `to service_role` / `to authenticated`
  clauses with `role "..." does not exist`.

  This migration creates them if missing, idempotently. It runs first
  because of its `0000` lexicographic prefix, so every later advisor
  migration finds the roles already in place. The roles are NOLOGIN
  and carry no inherent privileges — they exist purely as RLS policy
  targets. The deployment-specific authentication layer (Supabase
  gateway, Azure managed identity, bespoke auth proxy) is responsible
  for assuming the right role at request time.

  Hard rules:
  * No DDL outside role creation. No table, schema, extension, or
  policy DDL belongs in this file — those live in their own
  migrations so role creation can be audited independently.
  * Idempotent. Re-running this file on an environment that already
  has the roles is a no-op.
  * No privilege grants. Granting USAGE / SELECT / INSERT to these
  roles is the job of the table-owning migrations and (later)
  Phase 9 RLS hardening, not this one.

## `202604250001_advisor_corpus_storage_schema.sql`

- **Applied:** 2026-04-25 00:01
- **Title:** advisor corpus storage schema
- **Description:**

  Phase 11a.3 - Advisor corpus storage schema scaffold.

  This migration prepares storage for the deterministic records emitted by:

  dart run tool/advisor_corpus/main.dart materialize

  It intentionally does not load JSONL records, generate embeddings, create
  AGE vertices/edges, or expose MCP tools.

## `202604250002_advisor_embedding_contract.sql`

- **Applied:** 2026-04-25 00:02
- **Title:** advisor embedding contract
- **Description:**

  Phase 11a.6a - Advisor embedding contract, Claude-aligned revision.

  Anthropic does not offer a native Claude embedding model. For a Claude
  advisor stack, 11a uses the Anthropic-recommended Voyage embedding lane.
  Reranking is not persisted in schema; the 11a.6a runtime contract is
  pgvector cosine candidates -> Voyage rerank-2.5 -> Claude answer runtime.
  This migration does not generate embeddings or call a provider.

## `202604250003_advisor_vector_search.sql`

- **Applied:** 2026-04-25 00:03
- **Title:** advisor vector search
- **Description:**

  Phase 11a.8 - Advisor vector search: versioned embedding metadata,
  HNSW pgvector cosine index, and a stable scoped top-K search function.

  11a.6a locked the embedding contract to Voyage `voyage-4-large` at
  vector(1024) for Claude-aligned retrieval. 11a.7 loaded ready vectors
  into `public.advisor_source_chunks.embedding`. This migration makes
  those vectors searchable and provider-safe so a search query cannot
  accidentally mix rows produced by future provider/model/dimension
  combinations.

  Routing context:
  - This is candidate retrieval only. Voyage rerank-2.5 lands in 11a.9
  and the Claude answer runtime ships later.
  - AGE remains the launch graph path; pgvector-only retrieval is
  fallback insurance, not a replacement for AGE traversal.

  This migration does not call any vendor API, does not generate any
  embeddings, and does not mutate corpus content.

  ── Versioned embedding metadata columns ────────────────────────────────────

  The legacy `embedding_model` column from 11a.3 / 11a.6a stays in place
  so historical writers continue to work; the three columns below are the
  new provider-safe filters used by the HNSW index and the search function.

## `202604250004_advisor_proxy_usage_counters.sql`

- **Applied:** 2026-04-25 00:04
- **Title:** advisor proxy usage counters
- **Description:**

  Phase 11a.10b - Advisor proxy usage counters.

  The proxy reads this table before every protected provider call to
  check per-minute request rate and monthly cost cap, then increments
  the corresponding minute/month bucket on allow. The Dart side lives
  in `tool/advisor_proxy/advisor_proxy.dart::ProxyUsageGuard`; this
  migration only stages the schema. No provider call, no live API.

  Bucket model:
  - `minute_bucket` is the UTC minute the request lands in (the row
  covers one (operator, location, tier) at one minute). The
  proxy's per-minute cap is enforced against the row whose
  `minute_bucket` equals `date_trunc('minute', now() at time zone
  'UTC')`.
  - `month_bucket` is the first day of the same row's UTC month,
  denormalized so monthly cost rollups are a single sum across
  all minute rows in that month. The proxy's monthly cost cap is
  enforced by summing `cost_cents` over all rows where
  `month_bucket = date_trunc('month', now() at time zone 'UTC')`.

  Per-row uniqueness is on (operator, location, tier, minute_bucket)
  so concurrent writes for the same minute upsert into one row.

## `202604250005_advisor_cloud_foundation.sql`

- **Applied:** 2026-04-25 00:05
- **Title:** advisor cloud foundation
- **Description:**

  Phase 11a.11c.1 — Advisor cloud foundation schema (Tier 1 + Tier 1.5).

  Creates the foundational identity tables (`operators`, `locations`,
  `users`, `operator_admins`) and the support tables that every later
  proxy / advisor / billing surface keys off:

  * `usage_logs`       — partitioned per-period rollup of token /
  cost / request counts (proxy writes here
  starting in 11a.11d).
  * `usage_caps`       — per-(operator, location, usage_class) cap
  definition the proxy reads before allowing
  a provider call.
  * `proxy_requests`   — idempotency table; UNIQUE on
  `idempotency_key`, with `request_type` so
  Phase 12 tool-call writes reuse the same
  surface.
  * `feature_flags`    — global / operator / location scopes
  enforced via partial unique indexes; powers
  the Q12 retrieval-mode flag, per-operator
  full-content logging opt-in, and any other
  gating that needs to flip without redeploys.
  * `fx_rates`         — daily FX snapshots so internal USD cost
  accounting can render in the operator's
  `preferred_currency`.

  All operator-scoped tables carry `(operator_id, location_id)` as a
  COMPOSITE foreign key referencing `locations(operator_id,
  location_id)`. `locations` carries an explicit `unique (operator_id,
  location_id)` so the composite FK has a target. This rejects the
  `(operator_a, location_b)` cross-tenant mismatch at the database
  layer — a row whose `location_id` belongs to a different operator
  can never be inserted, even before RLS turns on in Phase 9. Time
  columns are `TIMESTAMPTZ` everywhere — the unzoned local-time
  variant is banned in operator-scoped tables (silent DST corruption
  is unrecoverable). Numeric counters and money columns carry `>= 0`
  checks; FX rates carry `> 0` checks.

  ON DELETE behavior: deleting a location cascades to every operator-
  scoped fact row that references it. Deleting an operator cascades to
  its locations (via `locations.operator_id` single-column FK), which
  in turn cascades to the fact rows. PIPEDA right-to-erasure is
  satisfied by the operator-delete cascade chain.

  RLS is enabled on every table with a service-role-only policy stub.
  Phase 9 turns on per-operator auth-bearing policies; until then only
  the proxy's service-role connection touches these tables. The stub
  pattern matches the corpus (`11a.3`) and counter (`11a.10b`)
  migrations so the cloud-foundation surface looks identical to the
  existing advisor surface.

  This migration does not load rows, does not call any provider, and
  does not modify the four prior advisor migrations (corpus storage,
  embedding contract, vector search, proxy usage counters).

## `202604250006_advisor_contextual_retrieval_telemetry.sql`

- **Applied:** 2026-04-25 00:06
- **Title:** advisor contextual retrieval telemetry
- **Description:**

  Phase 11a.11c.6a - Contextual Retrieval + usage telemetry hardening.

  Local schema-hardening migration. Adds the launch sparse-retrieval /
  cache-invalidation columns and expands usage rollups so cost telemetry
  dimensions do not collapse into one aggregate row.

  Contextual Retrieval: indexing-time Haiku context is stored separately
  from founder-authored chunk text, then included in sparse retrieval.

## `202604250007_advisor_rls_index_hardening.sql`

- **Applied:** 2026-04-25 00:07
- **Title:** advisor rls index hardening
- **Description:**

  Phase 11a.11c.6 live hardening - RLS-leading identity indexes.

  The first Azure RLS-leading-column audit caught three identity indexes whose
  leading key was not operator-scoped:
  * advisor_proxy_usage_counters(counter_id)
  * proxy_requests(request_id)
  * proxy_requests(idempotency_key)

  For multi-tenant RLS, hot fact/idempotency lookups must stay scoped by
  operator/location first so tenant filters do not degrade into broad scans.
  This migration changes the final live shape while preserving the UUID
  columns for response payloads and traceability.

## `202604250008_auth_schema_foundation.sql`

- **Applied:** 2026-04-25 00:08
- **Title:** auth schema foundation
- **Description:**

  Phase 9.0 - Auth schema foundation: identity, RBAC, sessions, audit, MFA.

  Single deterministic migration that turns the 11a cloud-foundation
  schema (operators, locations, users, operator_admins) into the full
  2026-industry-standard auth surface promised by phase_9_auth_plan.md:

  New tables:
  * roles                      - global + operator-scoped roles
  * permission_keys            - frozen catalog (seeded from this file)
  * role_permissions           - bundle definition (allow / deny; deny wins)
  * user_roles                 - grant + scope + time-bound; partial-unique
  on the active grant
  * auth_sessions              - own-ledger of Firebase session lifecycle
  * auth_events_audit          - APPEND-ONLY audit log
  * mfa_factors                - enrolled second factor inventory
  * tncs_acceptances           - never-overwrite T&Cs acceptance log
  * password_history           - last 5 password hashes per user
  * auth_invites               - invite-with-expiry
  * role_audit_log             - APPEND-ONLY role/permission diff history
  * external_identity_links    - Phase 8 vendor-employee bridge (NOT auth
  source-of-truth)

  Extensions to existing tables:
  * users           gains firebase_uid, external_id, status, deleted_at,
  roles_version, mfa_required, last_login_at,
  last_active_at, password_set_at, email_verified_at,
  first_name, last_name, display_name, primary_role_id,
  preferred_locale, avatar_url; legacy `role` column
  is migrated into `user_roles` and dropped.
  * operator_admins gains scope_type, scope_location_id, valid_from,
  valid_until.

  Hard rules carried from the active CLAUDE.md authority:

  1. TIMESTAMPTZ everywhere. The unzoned local-time variant is banned
  in operator-scoped tables (silent DST corruption).
  2. RLS performance discipline: every operator-scoped fact-table index
  leads with `operator_id` (or `(operator_id, location_id)`). Indexes
  that lead with anything else on operator-scoped tables are forbidden.
  The verification audit query in
  `db/verification/202604250006_advisor_schema_hardening_audits.sql`
  enforces this against the new auth tables.
  3. RLS enabled on every new table with a service-role-only policy stub.
  Phase 9.2 flips these stubs to real per-tenant policies; until then
  only the proxy's service-role connection touches these tables.
  4. Audit tables are append-only at the grant shape. UPDATE / DELETE are
  revoked from PUBLIC and from `service_role`; INSERT and SELECT are
  granted to `service_role`. PG enforces the grant shape; rows cannot
  be mutated or deleted by the proxy.
  5. Composite (operator_id, location_id) FKs reference
  `locations(operator_id, location_id)` for every operator + location
  scoped row, rejecting (operator_a, location_b) cross-tenant
  mismatches at the database layer.
  6. Permission keys are app-defined and frozen at code level. The
  catalog seeded here mirrors `lib/auth/permission_keys.dart` and
  `docs/contracts/auth_permission_key_catalog.md`. Operators may not
  invent new keys at runtime.

  This migration does not call any provider, does not write any user or
  session row, and does not change any runtime auth behavior. Phase 9.1
  wires the live JWT verifier; Phase 9.2 turns on real per-tenant RLS.

  ─── Trigger function for updated_at on auth tables ────────────────────

  Kept distinct from `public.advisor_set_updated_at` (corpus side, 11a.3)
  and `public.cloud_foundation_set_updated_at` (cloud side, 11a.11c.1) so
  the auth surface is self-contained: dropping it does not orphan corpus
  or cloud-foundation triggers and vice-versa.

## `202604260000_auth_rls_per_tenant_policies.sql`

- **Applied:** 2026-04-26 00:00
- **Title:** auth rls per tenant policies
- **Description:**

  Phase 9.2 - Auth RLS per-tenant policy flip + forge_admin BYPASSRLS role.

  Flips the 9.0 service-role-only RLS stubs on the auth surface to
  per-tenant policies that read tenant context from
  `current_setting('app.operator_id', true)::uuid` and (for per-user
  tables) `current_setting('app.user_id', true)::uuid`. The proxy
  injects these via `select set_config(..., true)` inside every
  tenant-scoped transaction (see
  `lib/infrastructure/persistence/postgres/tenant_transaction.dart`).

  Admin paths under `/v1/admin/*` use the new `forge_admin` role,
  which carries the `BYPASSRLS` attribute and is granted to
  `service_role` so the proxy can `SET LOCAL ROLE forge_admin`
  inside the system-scope transaction. Every BYPASSRLS use writes a
  `gdpr_erasure` / role-change / audit row in 9.6+.

  This migration intentionally covers ONLY the 12 Phase 9 auth
  tables. The cloud-foundation tables (operators, locations, users,
  operator_admins, usage_logs, usage_caps, proxy_requests,
  feature_flags) carry the same service-role-only stubs from 11a
  and are queued for a follow-up RLS flip — see Phase 9 checkpoint.
  The corpus tables (advisor_ingestion_runs, advisor_source_*,
  advisor_graph_*) stay F&F-global until 11b.1 introduces per-
  operator corpus scoping and are intentionally untouched here.

  Hard rules carried into this slice:

  1. `SET LOCAL` (transaction-scoped) tenant injection — never
  session-scoped `SET`. The repository pattern wrapper enforces
  this in Dart.
  2. RLS performance discipline — every operator-scoped index
  already leads with `operator_id`; this migration only adds
  policies, never indexes.
  3. Append-only audit shape preserved — `auth_events_audit` /
  `role_audit_log` UPDATE+DELETE grants stay revoked. Per-tenant
  SELECT layered on top.
  4. Repository pattern is the primary defense; RLS is the backup.
  The proxy still goes through OperatorScopedRepository on every
  call.

  This migration does NOT seed any operator data, does NOT call any
  live provider, and does NOT depend on `pgmq` (not exposed by Azure
  Flexible Server, see CLAUDE.md "Proxy & API Conventions").

  ─── forge_admin role with BYPASSRLS ────────────────────────────────

  Created LOGIN-less + BYPASSRLS so it can only be entered via
  `SET ROLE forge_admin` from a connection authenticated as
  service_role. service_role itself stays NOLOGIN (the proxy connects
  as a Postgres user that has been granted service_role; the same
  user is also granted forge_admin via the GRANT below so SET ROLE
  forge_admin succeeds).

  The `do $$ ... $$` block makes this idempotent. ALTER ROLE after
  the conditional CREATE keeps re-runs safe even if the role already
  existed without the BYPASSRLS attribute.

## `202604260001_auth_rls_service_role_grants.sql`

- **Applied:** 2026-04-26 00:01
- **Title:** auth rls service role grants
- **Description:**

  Phase 9.2 live-closeout - auth RLS service_role table grants.

  202604260000 flips the auth-table RLS policies from service-role-only
  stubs to per-tenant/per-user policies, but Postgres still requires
  table-level privileges before a policy can allow a row. This migration
  grants the minimum table privileges that match those policies:

  * permission_keys: SELECT only (frozen catalog; writes are migration /
  forge_admin BYPASSRLS paths, never tenant runtime).
  * mutable auth tables: SELECT / INSERT / UPDATE / DELETE to service_role,
  with row visibility constrained by the 202604260000 RLS policies.
  * forge_admin: matching table privileges so SET LOCAL ROLE forge_admin
  can actually use its BYPASSRLS attribute. Audit tables stay
  INSERT / SELECT only for forge_admin too.
  * audit tables: keep append-only shape from 9.0; INSERT / SELECT only,
  UPDATE / DELETE explicitly revoked from both service_role and
  forge_admin.

## `202604270000_phase_9_0a_scope_extensions.sql`

- **Applied:** 2026-04-27 00:00
- **Title:** phase 9 0a scope extensions
- **Description:**

  Phase 9.0a - Multi-location scale-flow extensions.

  Three small-but-cheap-now / expensive-later schema additions plus the
  team.* permission key category needed by 9.10 operator-facing
  Settings → Team UX. Runs anytime after 9.0 accepts; must run before
  cutover.4 (production schema flexibility ends there).

  Idempotent: safe to re-run on local + staging + Production1 (all
  still empty of operator data, so backfill is near-zero).

  Mirrors:
  * lib/auth/permission_keys.dart (the constants + PermissionKeys.all)
  * docs/contracts/auth_permission_key_catalog.md (operator-facing
  description per key)

## `202604270100_auth_sessions_token_hash_rename.sql`

- **Applied:** 2026-04-27 01:00
- **Title:** auth sessions token hash rename
- **Description:**

  Phase 9 audit-fix - rename auth_sessions.refresh_token_hash → token_hash.

  The 9.0 schema named the column `refresh_token_hash` but the value the
  writer actually stores is the SHA-256 hex digest of the live Firebase
  ID token (the raw refresh token never leaves the firebase_auth SDK).
  Calling it "refresh_token_hash" implies refresh-token-reuse detection
  the writer cannot deliver. Rename to `token_hash` to match what the
  column actually holds.

  Idempotent: safe to re-run on local + staging + Production1.
  * Production1 is empty of operator data, so no row migration cost.
  * Staging applied 9.0 + 9.2 RLS; the rename preserves all grants
  and policies via Postgres' implicit cascade.
  * If a future slice adds a real refresh-token-hash column, it can
  land alongside `token_hash` without a clash.

## `202604270200_phase_9_0a_super_admin_team_grants.sql`

- **Applied:** 2026-04-27 02:00
- **Title:** phase 9 0a super admin team grants
- **Description:**

  Phase 9.0a audit-fix - grant new team.* keys to super_admin.

  9.0 seeded super_admin with every permission key that existed at that time.
  9.0a added 12 team.* keys later, so the original cross-join seed cannot
  pick them up retroactively. Keep the baseline role contract true: super_admin
  has every key in the frozen catalog.

  Idempotent: safe to re-run on local + staging + Production1.

## `202604280000_phase_9_0sigma_b_rls_wrappers.sql`

- **Applied:** 2026-04-28 00:00
- **Title:** phase 9 0sigma b rls wrappers
- **Description:**

  Phase 9.0Σ.b — RLS UUID wrapper functions (item 4 from
  phase_9_scalability_decisions_2026-04-27.md).

  Creates four read-only SQL wrappers that every operator-scoped RLS
  policy must call instead of reading `current_setting('app.*', true)`
  inline. Rationale: bare `current_setting()` inside a policy body is
  not marked `LEAKPROOF`, which forces the planner to evaluate the
  policy at the row level rather than folding it into the index scan.
  Wrapping the call in a `STABLE LEAKPROOF PARALLEL SAFE` SQL function
  restores planner pushdown and (per item 4) is the locked posture for
  every Phase 9 policy — auth tables today, fact tables and the 9.0g
  usage_caps two-slot key rewrite next.

  Wrapper naming and read order — matches scalability decisions item 4
  and execution backlog B23 verbatim:

  `app_current_operator()`     reads `app.operator_id`
  `app_current_location()`     reads `app.location_id`
  `app_current_actor_user()`   reads `app.user_id`
  `app_acting_as_operator()`   reads `app.acting_as_operator_id`

  The first three GUCs are the existing names the proxy already
  injects via `set_config('app.<name>', @value, true)` inside
  `lib/infrastructure/persistence/postgres/tenant_transaction.dart`.
  The fourth (`app.acting_as_operator_id`) has no proxy injection
  today — the wrapper returns NULL until F&F internal cross-operator
  access lands. NULL is a fail-closed default: policies that compare
  `operator_id = app_acting_as_operator()` will not match while the
  GUC is unset, and only the existing per-tenant filter wins. Adding
  the wrapper now (rather than alongside the impersonation feature)
  means future policies do not need to be rewritten when the GUC is
  finally set.

  NULL-safe cast — `current_setting('app.<name>', true)` returns the
  empty string when the GUC is unset (the second `true` arg suppresses
  the missing-GUC error). Casting `''::uuid` raises
  `invalid_input_syntax_for_type_uuid`, which would propagate up
  through every policy evaluation. `nullif(...)::uuid` collapses both
  "missing" and "empty" into NULL so policies see a single absent
  value to compare against.

  Function posture per item 4:
  * `LANGUAGE sql`    — pure SQL, no plpgsql control flow needed.
  * `STABLE`          — same input → same output within a single
  statement; safe for index pushdown.
  * `LEAKPROOF`       — required for the planner to fold the policy
  into joins/index conditions. PG 16 still
  requires superuser to set this attribute;
  migration runs as the migration role which
  has the privilege on staging and Production1
  (same role that creates `forge_admin
  BYPASSRLS` in 202604260000).
  * `PARALLEL SAFE`   — readonly GUC reads are parallel-safe.

  This migration is local framework only — no live database mutation.
  The matching policy rewrite lands in 202604280001 (next file).

  ─── app_current_operator ──────────────────────────────────────────

## `202604280001_phase_9_0sigma_b_rewrite_existing_policies.sql`

- **Applied:** 2026-04-28 00:01
- **Title:** phase 9 0sigma b rewrite existing policies
- **Description:**

  Phase 9.0Σ.b — rewrite existing auth-table RLS policies through the
  wrapper functions defined in 202604280000.

  This migration is the policy-side half of item 4 from
  `phase_9_scalability_decisions_2026-04-27.md`. The 12 auth-table
  per-tenant policies created in 202604260000 still read tenant
  context via bare `current_setting('app.<name>', true)::uuid`; the
  planner cannot fold those calls into the tenant-leading index
  because `current_setting()` is not LEAKPROOF. Replacing the inline
  reads with `app_current_operator()` / `app_current_actor_user()`
  restores planner pushdown.

  Behavioral parity — every policy here matches the predicate shape
  the 202604260000 version had. No policy is widened, narrowed, or
  renamed; the only change is the function call. Negative tests
  (bogus tenant denied) and positive tests (forge_admin BYPASSRLS)
  continue to pass without modification.

  Drop+recreate inside a single migration file. The `db/migrations`
  runner applies each file with `psql --single-transaction` (per the
  202604260000 header comment), so the tables are never policy-less
  between statements. The drops use `if exists` for re-runnability.

  Cloud-foundation tables (operators, locations, users,
  operator_admins, usage_logs, usage_caps, proxy_requests,
  feature_flags, fx_rates) keep their service-role-only "all true"
  stubs from 11a.11c.1 and are intentionally untouched here — those
  stubs do not read `app.*` GUCs at all, so wrapper conversion is a
  no-op for them. The cloud-foundation RLS flip is queued as B10 in
  the Phase 9 execution backlog and will land its policies through
  the wrappers from creation, not via a second rewrite.

  This migration is local framework only — no live mutation.

  ─── Drop the bare-current_setting auth policies ───────────────────

  12 tables × 1-2 policies each = 16 policies (matching the staging
  closeout count in the execution backlog "Stale Findings Already
  Resolved" section).

## `202604280002_phase_9_0sigma_c_org_units.sql`

- **Applied:** 2026-04-28 00:02
- **Title:** phase 9 0sigma c org units
- **Description:**

  Phase 9.0Σ.c — org_units ltree + data_region (items 1, 19 from
  phase_9_scalability_decisions_2026-04-27.md).

  Two scale-foundation additions that are cheap-to-add-now and
  expensive-to-retrofit-later:

  1. `org_units` table (item 1, Q2): recursive corp/region/district/
  location_group hierarchy stored as Postgres `ltree` materialized
  paths. Subtree queries use `path <@ ancestor`. Permission grants
  at any node apply to descendants; explicit deny at a descendant
  overrides inherited access. Max depth 6 enforced via
  `CHECK (nlevel(path) <= 6)`.

  2. `operators.data_region` column (item 19, Q8): launch is
  single-region (`CA-CENTRAL`) but the column reserves the slot
  so multi-region routing in a future phase does not require a
  migration over real operator data. Default `'CA-CENTRAL'`
  backfills every existing row.

  Backfill: every existing operator gets exactly one root `corp`
  row in `org_units`. Operators created after this migration are
  responsible for creating their root through the proxy admin path
  (lands in 11A) — `OrgUnitsRepository.createRoot` is the single
  entrypoint.

  RLS: the table is per-tenant from creation. The four wrapper
  functions from 202604280000 (item 4) are the only readers of
  tenant context; bare `current_setting()` is forbidden by the lint.

  Tenant-leading-index discipline (item 4 + CLAUDE.md "RLS performance
  discipline"): every B-tree index leads with `operator_id`. The GiST
  index on `path` is the one exception PG allows because GiST cannot
  compose a tenant-leading column with an `ltree` operator class — the
  table-level RLS predicate filters tenants before the GiST scan, and
  the GiST index only ever serves subtree lookups already scoped to
  one operator's path prefix.

  Idempotent: safe to re-run on local + staging + Production1. All
  DDL uses `if not exists` / `create or replace`; the backfill is
  guarded by `not exists` so re-runs are no-ops.

  This migration is local framework only — no live database mutation.
  Live apply on staging + Production1 is queued under the Phase 9
  live-mutation gate (subject to user approval per Phase 9 lock).

## `202604280003_phase_9_0sigma_e_event_outbox.sql`

- **Applied:** 2026-04-28 00:03
- **Title:** phase 9 0sigma e event outbox
- **Description:**

  Phase 9.0Σ.e — durable event_outbox foundation (item 33 / Q22 from
  `phase_9_scalability_decisions_2026-04-27.md`, B26 in
  `phase_9_execution_backlog.md`).

  This slice creates the database side of the locked
  NOTIFY → outbox → Pub/Sub → WebSocket pattern. The transactional
  outbox row IS the source of truth: every business write that needs
  to fan out enqueues one `event_outbox` row in the same transaction
  as the business change. `pg_notify('event_outbox', ...)` fires from
  a row-level INSERT trigger and is treated only as a lightweight
  wake-up signal; the bridge worker (Phase 10a) reads `event_outbox`,
  publishes to Cloud Pub/Sub, and marks rows delivered only after
  Pub/Sub accepts. Q22 explicitly forbids treating NOTIFY as the
  truth, since notifications are dropped under Postgres connection
  failures and queue-pressure conditions.

  This migration is local framework only — no live mutation. The
  bridge worker, the WebSocket leg, and dead-letter handling all
  land in Phase 10a per the backlog gate. The repository in
  `lib/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart`
  exposes the enqueue + claim contract this slice locks; the contract
  doc at `docs/contracts/event_outbox_contract.md` documents the
  topic shape and the Phase 10a worker boundary.

  Hard rules carried from CLAUDE.md and the 4-27 lock:
  1. RLS performance discipline — the claim-scan index leads with
  `(operator_id, picked_up_at NULLS FIRST, id)`. Tenant context
  lands first so the policy can fold the predicate into the
  index probe; `picked_up_at NULLS FIRST` puts undelivered rows
  at the front so the worker's `WHERE picked_up_at IS NULL`
  filter walks contiguous index pages.
  2. RLS uses the wrapper functions from 9.0Σ.b
  (`public.app_current_operator()`); bare `current_setting()`
  is forbidden by the lint in `tool/rls_policy_lint.dart`.
  3. `TIMESTAMPTZ` everywhere; `TIMESTAMP WITHOUT TIME ZONE` is
  banned in operator-scoped tables.
  4. The trigger uses `pg_notify(channel, payload)` so the listening
  bridge can route by topic without parsing the row first. The
  payload carries `{operator_id, topic, id}` so the worker can
  decide whether to claim or skip based on its shard assignment;
  the full `payload jsonb` is read from the row on claim, not
  from the notification.

  Phase 10a worker contract (locked here so the schema does not
  evolve underneath the bridge):
  * Worker calls `EventOutboxRepository.claimBatch(...)` which
  issues `SELECT ... FOR UPDATE SKIP LOCKED` and stamps
  `picked_up_at = now()` in the same transaction.
  * On Pub/Sub ack, worker marks the row delivered (column lands
  in this slice as `delivered_at`; phase 10a fills it).
  * On Pub/Sub failure, worker increments `attempt_count` and
  records `last_error_at` / `last_error`. After a tunable
  attempt cap (Phase 10a) the bridge dead-letters the row.
  * Retention: a Phase 10a Cloud Run scheduled job deletes
  delivered rows older than 7 days; un-delivered rows are
  never auto-deleted (Q22 yellow/red tripwires alert before the
  table grows past safe size).

## `202604280004_phase_9_0sigma_d_service_principals.sql`

- **Applied:** 2026-04-28 00:04
- **Title:** phase 9 0sigma d service principals
- **Description:**

  Phase 9.0Σ.d — service_principals + auth_events_audit.actor_kind
  (item 14 from `phase_9_scalability_decisions_2026-04-27.md`, parcel
  B25 in `phase_9_execution_backlog.md`).

  Two scope-locked changes land here:

  1. `public.service_principals` — per-operator catalog of non-human
  actors (workflow runtime, vendor webhooks, scheduled jobs,
  system-health probes, F&F internal automation). Phase 9 schema
  reserves the slot now so workflow tool calls in Phase 12 attach
  to a stable identity. JWT issuance with `sp:` subject prefix
  and the proxy verifier path are explicitly OUT of scope for
  this slice — they land in a follow-up that touches
  `tool/advisor_proxy/**`. This migration only owns the schema
  so the repository contract and the actor_kind audit slot are
  stable from now on.

  2. `public.auth_events_audit.actor_kind text not null default
  'user' CHECK (actor_kind in ('user','service'))` — completes
  the audit attribution split: human actors keep `'user'`
  (default backfills every existing row); future service-
  principal-driven mutations write `'service'`. Without this
  column, machine-driven auth events would silently masquerade
  as their human owner and dispute reconstruction in Phase 9.8
  compliance review would not be able to tell the two apart.

  Hard rules carried from CLAUDE.md and the 4-27 lock:
  * Tenant-leading B-tree indexes (item 4 / RLS performance
  discipline). Every B-tree index here leads with `operator_id`.
  * RLS reads tenant context through the 9.0Σ.b wrapper functions
  (`public.app_current_operator()`); bare `current_setting()` in
  policy bodies is forbidden by `tool/rls_policy_lint.dart`.
  * `TIMESTAMPTZ` everywhere; `TIMESTAMP WITHOUT TIME ZONE` is
  banned in operator-scoped tables (silent DST corruption).
  * Same grant shape as the auth-table mutable surface — full DML
  to `service_role` (proxy runtime) and `forge_admin` (BYPASSRLS
  escape hatch via `runAsSystem`).

  audit_logs ownership split: this slice DOES NOT create or ALTER
  `audit_logs`. Phase 9.0Σ.f (B27) declares `audit_logs` and
  includes `actor_kind` inline at creation. Adding actor_kind to a
  not-yet-existing table here would either fail or pre-shape a table
  that 9.0Σ.f then has to reconcile with — both worse than letting
  9.0Σ.f land it in one place.

  This migration is local framework only — no live database mutation.
  Live apply on staging + Production1 is queued under the Phase 9
  live-mutation gate (subject to user approval per Phase 9 lock).

## `202604280005_phase_9_0sigma_f_audit_logs.sql`

- **Applied:** 2026-04-28 00:05
- **Title:** phase 9 0sigma f audit logs
- **Description:**

  Phase 9.0Σ.f — hash-chained audit_logs + per-operator/day chain
  scope + pg_partman daily partitioning + Azure Blob anchor table
  (item 13 from `phase_9_scalability_decisions_2026-04-27.md`,
  B27 from `phase_9_execution_backlog.md`).

  This slice creates the database side of the locked SOC 2 / forensic
  audit posture. Every audit-relevant action writes one row into
  `public.audit_logs`; the row's `row_hash` is `SHA-256(prev_row_hash
  || canonical_payload)` so any retroactive mutation in the chain is
  detectable from the next row's hash forward. Daily, the
  `tool/audit_anchor` Cloud Run job reads each completed
  `(operator_id, chain_date)` chain's terminal hash, writes a JSON
  evidence record to the F&F immutable Azure Blob container
  (configured separately, never in repo), and records the anchor in
  `public.audit_chain_anchors`. The verifier walks the in-DB chain,
  recomputes every row hash, and compares the terminal hash to the
  anchor row + the Blob evidence.

  This migration is local framework only — no live database mutation.
  Live apply on staging + Production1 is queued under the Phase 9
  live-mutation gate (subject to user approval per Phase 9 lock).
  The pg_partman registration call is wrapped in a re-runnable DO
  block so the same migration is safe to apply repeatedly.

  Hard rules carried from CLAUDE.md and the 4-27 lock:

  1. **Scale Pressure-Test Guardrail #1.** A single global
  `prev_row_hash → row_hash` chain serializes every audit write
  and becomes a launch-blocking bottleneck. Chains MUST be
  bounded; this slice scopes them to `(operator_id, chain_date)`.
  Concurrent inserts on different operators or different days do
  not contend; concurrent inserts on the SAME chain serialize
  through `pg_advisory_xact_lock(hashtext(operator_id || ':' ||
  chain_date))` so the trigger's "find prior row + hash" sequence
  is atomic.

  2. **RLS performance discipline (CLAUDE.md).** Every B-tree index
  leads with `operator_id` (or `(operator_id, chain_date, …)`).
  `tool/rls_policy_lint.dart` checks policy bodies for bare
  `current_setting('app.*')`; this migration uses the 9.0Σ.b
  wrapper functions exclusively (`app_current_operator()`).

  3. **Tz-naive timestamp columns are banned (CLAUDE.md time
  guardrail).** Every timestamp column is `timestamptz`;
  `chain_date` is a `date` derived from the audit row's UTC
  `occurred_at` instant (the operator's local business-date is
  irrelevant for chain partitioning — the chain is a hash
  artifact, not an operator-facing reporting surface).

  4. **service_principals attribution (B25 / item 14).**
  `actor_kind text NOT NULL CHECK (actor_kind in ('user',
  'service'))` is inline on the new table per the slice scope.
  The matching `actor_principal_id` slot is on this table only;
  the `service_principals` table itself and the `auth_events_audit`
  `actor_kind` column are 9.0Σ.d-owned surfaces and explicitly
  out of scope here.

  5. **Append-only by grant shape.** Runtime roles get `INSERT` and
  `SELECT` only; `UPDATE` and `DELETE` are revoked. Any
  retention-driven removal goes through the partition-drop
  cadence operated by the DBA via the runbook (the partitions
  themselves are physical tables that can be `DETACH` + `DROP`ped
  after the retention window). Mid-row redaction follows the
  `forge_admin` break-glass procedure documented in
  `runbooks/audit_chain_verify_runbook.md`.

  6. **Anchor evidence is the durability anchor, not the row hash
  itself.** The chain proves "no row in this operator/day was
  mutated retroactively"; the Azure Blob immutable anchor proves
  "the terminal hash F&F holds matches the one F&F published".
  Together they bound retroactive tampering to "tampered before
  the daily anchor ran" (a sub-24h window) instead of "could be
  tampered any time after creation".

## `202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql`

- **Applied:** 2026-04-28 00:06
- **Title:** a phase 9 0sigma g usage caps two slot add
- **Description:**

  Phase 9.0Σ.g (B28 in phase_9_execution_backlog.md / item 6 in
  phase_9_scalability_decisions_2026-04-27.md) — usage_caps + usage_logs
  two-slot key migration, step 1 of 3: ADD columns.

  Source decision (lock 2026-04-27, item 6 "Decision C usage_caps two-slot
  key"): `usage_caps` evolves to a logical key of

  (billing_owner_org_unit_id, scoped_org_unit_id,
  location_id, staff_id, workflow_id, usage_class)

  where `billing_owner_org_unit_id` is who pays (the franchisee /
  corporate / brand entity that the cap charges against) and
  `scoped_org_unit_id` is where the cap applies (the same node, a
  descendant brand, a region, etc.). Two slots in the key let the same
  table model:

  * company-wide caps (billing = scoped = corp root),
  * brand or sub-org caps (billing = corp, scoped = a child node),
  * location-specific caps (location_id pins down a single venue),
  * staff or workflow caps (staff_id / workflow_id narrow further).

  This slice is **online-friendly step 1 of 3**:

  step a (this file):       ADD columns, all nullable.
  step b (`..._b_backfill`): UPDATE existing rows so billing_owner +
  scoped point at each operator's root
  org_units row.
  step c (`..._c_constraint_flip`): SET NOT NULL on the two
  org-unit columns, swap the primary key
  to a tenant-leading surrogate, attach
  the logical-key UNIQUE constraint, the
  org_units FKs, and the tenant-leading
  cap-vs-actual indexes.

  Splitting the work across three migrations means the first two are
  safe to apply ahead of any code change — existing reads/writes
  against `usage_caps` and `usage_logs` keep working because the new
  columns are nullable and the old key is intact. The constraint flip
  only lands once the calling code (proxy upserts, accounting service,
  usage repositories) has been taught the new shape; until then the
  columns are dormant.

  Hard constraints (block 2 of the slice prompt):
  * Pre-assigned filenames `202604280006_a/b/c_*` — do not rename.
  * No edits to applied migrations (`202604250*.sql`,
  `202604280000_*.sql`, `202604280001_*.sql`, `202604280002_*.sql`,
  `202604280003_*.sql`).
  * No RLS policy bodies touched here — this slice is purely column
  additions; existing service-role-all stubs from
  202604250005 stay in place. Wrapper functions
  (`public.app_current_operator()` etc.) are introduced in 9.0Σ.b
  and used by the constraint-flip step's documentation only.
  * No actor_kind, sp:-prefixed JWT, audit_logs, service principals,
  or proxy hot-zone changes — those land in disjoint slices.

  Idempotent: every ALTER uses `add column if not exists`.

## `202604280006_b_phase_9_0sigma_g_usage_caps_two_slot_backfill.sql`

- **Applied:** 2026-04-28 00:06
- **Title:** b phase 9 0sigma g usage caps two slot backfill
- **Description:**

  Phase 9.0Σ.g (B28 / item 6) — usage_caps + usage_logs two-slot key
  migration, step 2 of 3: BACKFILL.

  Step a (`..._a_add`) added the four new columns nullable. This file
  resolves each operator's root `org_units` row (the one created by
  202604280002 with `parent_id IS NULL`) and writes its UUID into
  `billing_owner_org_unit_id` and `scoped_org_unit_id` on every
  existing `usage_caps` and `usage_logs` row that does not yet carry
  those values.

  The single-root-per-operator invariant is enforced in
  202604280002 by:

  * the partial unique index `org_units_one_root_per_operator_uq`
  (covers the (operator_id, parent_id IS NULL) lookup), and
  * the backfill block in 202604280002 itself (every operator
  already has exactly one root after that migration applies).

  Both guarantees mean the subqueries below resolve to exactly one
  row per operator. If a row pre-dates 202604280002 — impossible
  under the locked migration order, but defensive — the UPDATE
  skips it (no matching root row → no FROM match → no UPDATE).

  `staff_id` and `workflow_id` are explicitly NOT touched here. The
  locked design keeps them nullable forever (most caps and most log
  rows are not pinned to a single staff member or workflow); the
  step-c UNIQUE NULLS NOT DISTINCT collapses NULL = NULL so the
  logical-key uniqueness still holds.

  Idempotence: each UPDATE filters on
  `billing_owner_org_unit_id IS NULL OR scoped_org_unit_id IS NULL`
  so a re-run is a no-op once the rows are populated. The partial
  predicate also lets the backfill run before step c without
  racing the SET NOT NULL — once every row has a non-NULL value,
  the UPDATE matches nothing on subsequent runs.

  Hard constraints (block 2 of the slice prompt):
  * No edits to applied migrations.
  * No RLS policy bodies touched.
  * No actor_kind, sp:-prefixed JWT, audit_logs, service principals,
  or proxy hot-zone changes.
  * No `forge_admin` RLS policy added.

  This migration is local framework only — no live database mutation.

## `202604280006_c_phase_9_0sigma_g_usage_caps_two_slot_constraint_flip.sql`

- **Applied:** 2026-04-28 00:06
- **Title:** c phase 9 0sigma g usage caps two slot constraint flip
- **Description:**

  Phase 9.0Σ.g (B28 / item 6) — usage_caps + usage_logs two-slot key
  migration, step 3 of 3: CONSTRAINT FLIP.

  After step a (`..._a_add`) added the four cap-shape columns and
  step b (`..._b_backfill`) populated `billing_owner_org_unit_id` and
  `scoped_org_unit_id` on every existing row, this file:

  1. SET NOT NULL on the two org-unit columns (now safe — every
  existing row carries a non-NULL value).
  2. Drop the legacy primary keys
  (`usage_caps_pkey` on (operator_id, location_id, usage_class)
  and `usage_logs_pkey` on the eleven-column rollup tuple).
  3. Add a tenant-leading surrogate primary key on each table.
  Surrogate is needed because the locked logical key carries
  nullable axes (`staff_id`, `workflow_id`) — PostgreSQL forbids
  NULL columns in a PRIMARY KEY, so we cannot encode the lock 6
  shape directly as a PK and must use UNIQUE NULLS NOT DISTINCT
  alongside the surrogate. This choice is documented in SQL
  comments and asserted in the test
  `test/phase_9_0sigma_g_usage_caps_two_slot_test.dart`.
  4. Add `UNIQUE NULLS NOT DISTINCT` constraints that encode the
  locked logical keys:
  * usage_caps:  (operator_id,
  billing_owner_org_unit_id, scoped_org_unit_id,
  location_id, staff_id, workflow_id, usage_class)
  * usage_logs:  same prefix, plus period_start + the
  seven telemetry dimensions from 202604250006
  (rollup identity must stay 1:1 with the
  cap-vs-actual reconciliation tuple).
  `operator_id` is INCLUDED at the leading position so the index
  stays tenant-leading per CLAUDE.md "RLS performance discipline"
  and the lock 4 / item 4 audit. The lock 6 logical key carries
  `billing_owner_org_unit_id` as the leading axis at the domain
  level, but `org_units(operator_id, id)` is uniquely owned by a
  single operator, so prefixing with `operator_id` does not
  change the uniqueness contract — it just lets the planner fold
  RLS into the index probe.
  5. Add composite foreign keys to `org_units(operator_id, id)`
  from both `billing_owner_org_unit_id` and `scoped_org_unit_id`
  on each table. The composite shape — keyed on
  `(operator_id, <org_unit_col>)` — rejects cross-tenant
  mismatches at the database layer (an org_unit ID belonging to
  operator B can never land on a row whose `operator_id` is
  operator A). ON DELETE CASCADE matches the existing
  locations FK from 202604250005 so operator/org_unit teardown
  cleanly garbage-collects descendant cap and log rows.
  6. Add tenant-leading indexes for cap lookup and cap-vs-actual
  reconciliation. The UNIQUE constraints from step 4 already
  provide tenant-leading lookup indexes; the explicit
  reconciliation index on `usage_logs` (cap-shape only, no
  telemetry tail) is added so the join planner has a narrow
  index for the reconciliation aggregate without scanning the
  wider rollup-identity index.
  7. Grant `service_role` and `forge_admin` the DML privileges
  required to read/write through RLS — privileges are checked
  *before* RLS, so without grants the policies never get a
  chance to evaluate. NOT adding a `forge_admin` RLS policy
  per the slice constraint; `forge_admin` already has BYPASSRLS
  from 202604260000 and grants are sufficient.

  Hard constraints (block 2 of the slice prompt):
  * No edits to applied migrations.
  * No `forge_admin` RLS policy added (the existing
  `*_service_role_all` stubs from 202604250005 stay untouched —
  they predate the wrapper-function rule and are the subject of
  a separate cloud-foundation RLS flip in B10).
  * No bare `current_setting('app...')` calls anywhere — this
  migration adds no policy bodies, so the RLS lint
  (`tool/rls_policy_lint.dart`) trivially passes.
  * No actor_kind, sp:-prefixed JWT, audit_logs, service principals,
  or proxy hot-zone changes — those land in disjoint slices.

  The proxy upsert SQL (`ProxyUsageLogSql.atomicUpsert` in
  `tool/advisor_proxy/advisor_proxy.dart`) targets the OLD eleven-
  column primary key as its ON CONFLICT key. After this migration
  applies, that ON CONFLICT target no longer exists and the upsert
  must be retargeted to the new wide UNIQUE NULLS NOT DISTINCT key
  (`usage_logs_two_slot_rollup_uq`). The slice constraints forbid
  touching the proxy hot-zone files, so the upsert update is
  recorded as a follow-up. This migration is therefore safe for
  local schema testing but MUST NOT be applied to a live database
  until the proxy upsert + accounting service are taught the new
  shape (tracked alongside `lib/services/advisor/usage_*.dart`,
  which does not exist yet).

  Idempotent: every constraint/index DDL uses
  `drop constraint if exists` / `create ... if not exists`. SET NOT
  NULL is a no-op on a column that is already NOT NULL.

## `202604280007_phase_9_0sigma_h_advisor_conversation_log.sql`

- **Applied:** 2026-04-28 00:07
- **Title:** phase 9 0sigma h advisor conversation log
- **Description:**

  Phase 9.0Σ.h — advisor_conversation_log (item 5 from
  `phase_9_scalability_decisions_2026-04-27.md`, parcel B29 in
  `phase_9_execution_backlog.md`).

  Every advisor turn writes one provenance row through the proxy. Raw
  question and recommendation text are encrypted at rest (application-
  layer ciphertext + IV + KMS key reference; the row never carries the
  actual key material) and gated by a restricted audit-privacy /
  privacy-compliance permission. Non-sensitive hashes and metadata
  remain queryable through the ordinary `service_role` path so audit
  and replay surfaces can render summaries without decrypting raw
  content.

  Hard rules carried from CLAUDE.md and the 4-27 lock:
  1. RLS performance discipline — every B-tree index leads with
  `operator_id` so the per-tenant policy folds into the index
  probe; bare `current_setting()` inside policy bodies is
  forbidden by the lint in `tool/rls_policy_lint.dart`.
  2. Storage rule — `TIMESTAMPTZ` everywhere; `TIMESTAMP WITHOUT
  TIME ZONE` is banned in operator-scoped tables.
  3. RLS uses the wrapper functions from 9.0Σ.b (
  `public.app_current_operator()`); column-level grants enforce
  the audit-privacy split below.
  4. The advisor turn's content is encrypted by the proxy BEFORE
  it reaches this layer; the migration does not call
  `pgp_sym_encrypt(...)`. Producers bind `content_encrypted` /
  `content_iv` / `content_key_ref` already-encrypted; the
  `pgcrypto` extension is enabled defensively for any DB-side
  digest helpers an audit-privacy reader needs (e.g. recomputing
  `content_hash` for integrity verification).

  Partitioning posture (item 5 + scalability "high-volume table
  partitioning required"):
  * `partition by range (created_at)`. Time partitioning aligns the
  hot read path (recent advisor turns per operator) with partition
  pruning and matches the locked posture for `usage_logs` in
  `202604250005_advisor_cloud_foundation.sql`.
  * PG requires the partition key to be part of every unique
  constraint on a partitioned table. The PK is therefore
  `(operator_id, created_at, id)` — tenant-leading + includes the
  partition key + UUID tiebreaker. `id uuid` is preserved as the
  trace id (returned to producers and used by Phase 11b advisor
  replay), it is just no longer the bare PK.
  * A `DEFAULT` partition catches writes that fall outside any
  month-specific partition the post-launch maintenance job
  creates ahead of time; without it, a write to an unprovisioned
  month would fail.

  Audit-privacy split (item 5 + B29 gate):
  * `service_role` (the proxy's normal connection) gets INSERT on
  the full row but SELECT only on a column-allowlist of safe
  metadata. `content_encrypted`, `content_iv`, and
  `content_key_ref` are deliberately omitted from that allowlist,
  so a `SELECT *` from a service_role transaction errors at the
  privilege layer before RLS even evaluates.
  * `audit_privacy` (NOLOGIN role created here) gets SELECT on the
  full row. The proxy assumes this role only on the documented
  audit-privacy access path (lands alongside the audit-privacy
  proxy gate in a future slice); every assumption pairs with an
  `audit_logs` provenance row per the B29 acceptance.
  * `forge_admin` keeps full DML as the BYPASSRLS escape hatch for
  paired-super-admin GDPR redaction / break-glass paths.

  This migration is local framework only — no live database mutation.
  Live apply on staging + Production1 is queued under the Phase 9
  live-mutation gate.

## `202604280008_phase_9_0sigma_i_graph_canonical.sql`

- **Applied:** 2026-04-28 00:08
- **Title:** phase 9 0sigma i graph canonical
- **Description:**

  Phase 9.0Σ.i — canonical graph storage (item 30 / Q19 from
  `phase_9_scalability_decisions_2026-04-27.md`, B30 in
  `phase_9_execution_backlog.md`).

  Q19 lock: Apache AGE remains the launch graph query engine, but AGE
  is NOT the source of truth. Canonical graph data lives in ordinary
  Postgres `graph_nodes` and `graph_edges` tables; AGE label graphs
  are rebuildable projections. Without canonical storage the projection
  cannot be rebuilt without re-extracting from the source-of-truth
  corpus, and the AGE health/tripwire surface (yellow at 3M active
  edges, red at 4M) has nothing to count against.

  Hard rules carried from CLAUDE.md and the 4-27 lock:
  1. Operator-scoped from creation. Every fact-table row carries
  `operator_id`; tenant-leading B-tree indexes lead with
  `operator_id` so RLS policy evaluation folds into the index
  probe (CLAUDE.md "RLS performance discipline").
  2. RLS uses the wrapper functions from 9.0Σ.b
  (`public.app_current_operator()`); bare `current_setting()`
  is forbidden by the lint at `tool/rls_policy_lint.dart`.
  3. `TIMESTAMPTZ` for every datetime column — naive (non-tz)
  date-time types are banned in operator-scoped tables per the
  CLAUDE.md storage rule.
  4. Composite FKs to `public.locations(operator_id, location_id)`
  reject cross-operator location pointers at the database layer.
  5. Edge endpoints reference `public.graph_nodes` within the same
  `(operator_id, graph_scope, graph_version)` tuple — a self-FK
  with the composite uniqueness target below makes a
  cross-operator or cross-version edge a database error.
  6. No live mutation. Generated rebuild SQL (see
  `tool/graph_projection/`) may DROP/CREATE the AGE projection
  but must NEVER mutate `graph_nodes` or `graph_edges`.

  Tripwire surface (Q19):
  * `graph_health_metrics()` — set-returning function exposing
  active vertex count, active edge count, yellow at 3M active
  edges, red at 4M active edges, plus projection metadata
  (last build / last benchmark slots reserved for the Phase 11A
  graph health panel).
  * Filters out soft-deleted / archived rows so the count tracks
  "active" rows the AGE projection rebuild would replay.

  This migration is local framework only — no live database mutation.
  Live apply on staging + Production1 is queued under the Phase 9
  live-mutation gate.

## `202604280009_phase_9_0sigma_j_diskann_install.sql`

- **Applied:** 2026-04-28 00:09
- **Title:** phase 9 0sigma j diskann install
- **Description:**

  Phase 9.0Σ.j — install pg_diskann extension only (B31 in
  `phase_9_execution_backlog.md`, item 31 / Q20 in
  `phase_9_scalability_decisions_2026-04-27.md`).

  Q20 locked the HNSW → DiskANN switch posture on 2026-04-27: HNSW
  stays default for active corpora and remains the advisor retrieval
  hot path. DiskANN is installed but dormant until Vector Index Health
  triggers fire (yellow at 5M vectors per searchable embedding space,
  red at 8M with projected growth crossing 10M, sustained latency
  regression, rebuild windows blown, memory pressure, repeated
  timeouts, unacceptable recall, or operationally unsafe rebuilds —
  see `docs/phases/phase_9/phase_9_vector_index_switch_trigger.md`).

  Scope of THIS migration:
  * Install the `pg_diskann` extension if available, so the
  CREATE INDEX path is reachable when a non-destructive cutover
  is later approved.

  NOT in scope (explicit non-goals so future readers do not relax
  this slice):
  * No CREATE INDEX statement of any kind.
  * No throwaway / sample / smoke DiskANN index against a scratch
  table — Q20 cutover validation runs through shadow query +
  benchmark + canary routing on real corpus data, not in this
  migration.
  * No retrieval function changes. `public.advisor_search_chunks`
  and the HNSW partial index from
  `202604250003_advisor_vector_search.sql` continue to serve
  candidate retrieval unchanged.
  * No RLS policy changes. Wrapper-function policy rule
  (`app_current_operator()` etc.) stays intact for any future
  DiskANN index, exactly as for HNSW.
  * No live database commands. Live apply to staging /
  Production1 happens only through the approved Phase 9 migration
  path; this file is the artifact that path will run.

  The `pg_diskann` extension is in the Azure DB Flexible Server
  allow-list per CLAUDE.md "Proxy & API Conventions" extension list
  (alongside `AGE`, `pgvector`, `pg_cron`, `pg_partman`,
  `pg_stat_statements`, `pgcrypto`). Using `if not exists` keeps the
  migration idempotent across environments where the extension may
  already be enabled.

  Posture summary (kept here in -- comments so this migration is
  strictly extension-install-only — no executable SQL beyond the
  single CREATE EXTENSION below):
  * HNSW remains the default vector index and the advisor
  retrieval hot path.
  * DiskANN is dormant until Vector Index Health triggers fire and
  a non-destructive shadow / benchmark / canary cutover is
  approved.
  * See `docs/phases/phase_9/phase_9_vector_index_switch_trigger.md`
  for Q20 yellow / red thresholds, observability fields, and the
  14-day rollback window.

## `202604280010_a_phase_9_0sigma_k_aggregation_state.sql`

- **Applied:** 2026-04-28 00:10
- **Title:** a phase 9 0sigma k aggregation state
- **Description:**

  Phase 9.0Σ.k — aggregation_state foundation (item 32 of
  `phase_9_scalability_decisions_2026-04-27.md`; B32 in
  `phase_9_execution_backlog.md`).

  Locks the per-rollup-table watermark / lease / retry / observability
  table that every Q3.1 incremental refresh job updates atomically.
  The table is the single source of truth for "where is each rollup
  caught up to" — pg_cron jobs (202604280010_c) read
  `last_processed_seq`, claim a lease, batch-process raw facts up to
  the new high watermark, and advance `last_processed_seq` only after
  the batch commits. Q3.6 idempotency follows: re-running a window
  never advances past a previously-failed batch and never double-
  counts because UPSERT semantics on the rollup tables collapse
  repeated rows to the same key.

  Design source — Q3.1 + Q3.6 + Q3.9 + Q3.10:

  Q3.1 (Refresh Strategy)   sequence-watermarked
  aggregation_state(rollup_table, grain,
  last_processed_seq).
  Q3.6 (Idempotency)        deterministic keys on rollup tables
  (202604280010_b); this table records
  how far the worker advanced the
  watermark for each (table, grain).
  Q3.9 (Error Handling)     `last_run_status` lets the freshness UI
  distinguish ok / stale / failed; failures
  keep `last_processed_seq` pinned so the
  next run retries the same window.
  Q3.10 (Observability)     surfaces last-success/failure timing,
  attempt count, lease owner, and rebuild
  progress to the F&F Dev/Admin Health
  dashboard.

  Hard rules carried from CLAUDE.md:
  1. RLS performance discipline does not apply to this table —
  `aggregation_state` is internal infrastructure (no operator_id
  column, not operator-scoped). Direct DDL/DML lives behind
  `forge_admin` BYPASSRLS; the worker never reads or writes it
  from a tenant transaction. RLS is therefore not enabled.
  2. `TIMESTAMPTZ` everywhere; `TIMESTAMP WITHOUT TIME ZONE` is
  banned in operator-scoped tables and matched here for
  consistency (the worker compares lease/run timestamps across
  regions in a future multi-region world).
  3. The locked grain set (Q3.3 — daypart, business_day, week,
  accounting_period, month, quarter, year) is enforced at the
  DB layer via CHECK so a typo in the worker cannot silently
  create a phantom grain row.
  4. Idempotent / rerun-safe — every DDL uses
  `if not exists` / `create or replace`. No data backfill on
  first apply (the worker bootstraps a row on its first poll for
  each (rollup_table, grain) it owns, with `last_processed_seq
  = 0`).

  This migration is local framework only — no live database mutation.
  Live apply on staging + Production1 is queued under the Phase 9
  live-mutation gate and runs together with 202604280010_b/c.

## `202604280010_b_phase_9_0sigma_k_rollup_tables.sql`

- **Applied:** 2026-04-28 00:10
- **Title:** b phase 9 0sigma k rollup tables
- **Description:**

  Phase 9.0Î£.k â€” physical rollup tables for the locked grain set
  (item 34 / Q3.2 + item 35 / Q3.3-Q3.10 of
  `phase_9_scalability_decisions_2026-04-27.md`; B32 in
  `phase_9_execution_backlog.md`).

  Q3.2 Locked: physical rollup tables are the operator-facing default
  storage form. Materialized views are internal helpers only and
  MUST NOT be exposed as operator-facing truth (the test in
  `test/phase_9_0sigma_k_rollups_test.dart` asserts every grain in
  this slice is a real table, not a materialized view).

  Q3.3 Locked: the grain set is `daypart`, `business_day`, `week`,
  `accounting_period`, `month`, `quarter`, `year`. Hourly/minute
  summaries are explicitly excluded from the launch rollup
  architecture. This migration creates one physical table per grain.

  Common shape (every grain table carries the same columns):

  * Tenant scope:
  operator_id          â€” RLS leading column (item 4 / 9.0Î£.b
  wrappers).
  scoped_org_unit_id   â€” Q2 hierarchy scope (corp / region /
  district / location_group / location
  leaf node).
  location_id          â€” NULLABLE; NULL = hierarchy aggregate
  (region / corp), non-NULL = single
  location row. NULLS NOT DISTINCT on
  the deterministic UPSERT key
  collapses two NULL rows to one
  conflict target so Q3.6 idempotency
  survives location_id = NULL.
  * Period:
  period_start         â€” TIMESTAMPTZ window start (UTC stored,
  Q1 storage rule).
  period_end           â€” TIMESTAMPTZ window end (exclusive).
  business_date        â€” DATE the period belongs to in the
  location's local calendar (Q1 storage
  rule: computed once at write using
  `location.timezone +
  business_day_rollover_hour`).
  * Q3.4 dimensions:
  metric_family        â€” top-level metric grouping (sales,
  labor, variance, traffic, â€¦); the
  vendor-aggregation slices (post-7.58)
  fill the locked taxonomy.
  dimensions           â€” jsonb. Q3.4-locked dimension slices
  live here as a JSON object per row;
  `dimensions_fingerprint` (generated
  column below) gives the UPSERT key
  a deterministic representation.
  metrics              â€” jsonb. The actual aggregated values
  (sum_sales, labor_pct, variance_$,
  etc.). Producer-aggregator schema is
  vendor-specific and NOT defined in
  this slice (per task scope: "do not
  invent final aggregation formulas").
  * Q3.1 watermark provenance:
  source_watermark_seq â€” bigint sequence the worker had
  processed up to when this row was
  computed; matches the
  aggregation_state row that produced
  it.
  source_watermark_at  â€” when the worker observed the
  watermark.
  * Q3.4 + Q3.6 reproducibility:
  rule_version         â€” the labor / target / variance rule
  version in force when the row was
  computed. Q3.8 rebuilds tag the new
  `rule_version` so the dashboard can
  tell "old rule" vs "new rule" rows
  apart during rollover.
  computed_at          â€” when the worker wrote/updated the
  row.
  * Q3.7 + Q3.9 freshness/status:
  freshness_status     â€” fresh / stale / failed /
  last_known_good / rebuilding. Maps to
  the operator-facing UI labels in Q3.7.
  last_failure_at      â€” when the most recent failed write
  landed (Q3.9 last-known-good
  behavior).
  last_failure_reason  â€” short string for Dev/Admin Health
  rendering.

  Q3.6 Idempotency (deterministic UPSERT):
  The unique index named `<table>_uq` on
  `(operator_id, scoped_org_unit_id, location_id, period_start,
  metric_family, dimensions_fingerprint, [grain-specific cols])`
  uses `NULLS NOT DISTINCT` so location_id NULL collapses to one
  conflict target per other-key combination. Re-running the same
  aggregation window writes the same row.

  RLS performance discipline (item 4 / CLAUDE.md):
  * Every B-tree index leads with operator_id (or
  `(operator_id, scoped_org_unit_id)` where the index serves a
  hierarchy lookup).
  * RLS policy bodies use `public.app_current_operator()`; bare
  `current_setting()` is forbidden by the lint at
  `tool/rls_policy_lint.dart`.

  Partition hooks (scalability audit Rollups conditional-pass gate):
  Each grain table is created `partition by range (period_start)`
  with a single DEFAULT partition that catches every row at
  launch. The default partition is the Q3.8 / scalability-audit
  "partitioning by period/operator" hook â€” a follow-up Phase 9
  slice can carve out per-month / per-quarter partitions ahead of
  time without rewriting tenant data, because every write that
  currently lands in the default partition will be moved by
  `ATTACH PARTITION ... FOR VALUES FROM ... TO ...` + a one-time
  `INSERT ... ON CONFLICT DO NOTHING SELECT ... FROM
  <table>_default WHERE period_start ...` migration. The default
  partition also keeps small-tenant grains (e.g. `year`) on a
  single physical heap â€” partitioning a 12-row-per-year table is
  pure overhead. This migration deliberately stops at the hook;
  the Phase 9 partition-policy slice locks the windowing rules.

  This migration is local framework only â€” no live database mutation.

## `202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql`

- **Applied:** 2026-04-28 00:10
- **Title:** c phase 9 0sigma k pg cron jobs
- **Description:**

  Phase 9.0Σ.k — pg_cron schedules for the rollup hot/cold paths
  (item 32 / Q3.1 of `phase_9_scalability_decisions_2026-04-27.md`;
  B32 in `phase_9_execution_backlog.md`).

  Q3.1 Locked: incremental batch via pg_cron, NOT synchronous write
  triggers. Refresh interval is 60s for hot grains (today/this week
  = `daypart` + `business_day`) and 300s for colder grains (`week`,
  `accounting_period`, `month`, `quarter`, `year`). The split keeps
  the high-volume / latency-sensitive grains close to real time
  without burning cycles on `quarter` / `year` rollups that can
  safely lag five minutes.

  Schedule shape:
  * Hot path  → `'60 seconds'` interval, calls
  `public.rollup_run_hot_path()`.
  * Cold path → `'300 seconds'` interval, calls
  `public.rollup_run_cold_path()`.

  Both functions are SQL-callable, idempotent stubs that take a
  transaction-scoped lease on each `(rollup_table, grain)` row in
  `aggregation_state`, mark `last_run_status = 'leased'`, and exit.
  The Dart worker (`lib/services/rollups/rollup_worker.dart`)
  performs the actual fact-walking + UPSERT + watermark advance
  through the same primitives so the two paths stay in lockstep.

  Why a SQL stub and not the worker directly: pg_cron jobs can only
  call SQL inside the database; calling out to a Dart service would
  require a wrapper Cloud Run service that the database posts to.
  The SQL function is the lightweight kickoff — its job is to take
  the lease and stamp `last_run_started_at` / `last_run_status` so
  the worker (driven by the lease event or by its own poll) sees
  the new lease and processes the window. This keeps the database
  side simple and auditable without forcing the worker to also
  poll on a tight timer.

  Idempotency on rerun (B32 gate "rollups idempotent across
  retried runs"):

  * `cron.schedule(jobname, …)` is NOT idempotent on its own — a
  second call with the same `jobname` raises a duplicate-job
  error. The DO block below removes any existing schedule with
  the same name first using `cron.unschedule(jobname)`, then
  reschedules. Wrapped in a transaction so a partial failure
  leaves the prior schedule intact.

  * The functions themselves use `create or replace function` so
  re-running this migration after a function-body fix does not
  drop / recreate dependent triggers (there are none today, but
  the principle stands).

  * Lease acquisition uses `update … where leased_until is null
  or leased_until < now()` so two simultaneous cron firings on
  a misconfigured host do not both win the lease.

  This migration is local framework only — no live database
  mutation. Live apply is queued behind 202604280010_a/b under the
  Phase 9 live-mutation gate.

## `202604280011_phase_9_recovery_code_attempts.sql`

- **Applied:** 2026-04-28 00:11
- **Title:** phase 9 recovery code attempts
- **Description:**

  Phase 9 live-closeout B13 - recovery-code attempt ledger.

  Recovery-code attempts are rate-limited at 1/minute and 5/24h per user.
  The proxy records every attempt, valid or invalid, so attackers cannot
  distinguish wrong codes from already-used codes and cannot bypass rate
  limits by sending malformed input.

## `202604280012_phase_9_auth_ops_cloud_foundation_grants.sql`

- **Applied:** 2026-04-28 00:12
- **Title:** phase 9 auth ops cloud foundation grants
- **Description:**

  Phase 9 live-closeout - auth-ops grants for cloud-foundation identity rows.

  9.2 granted the auth tables themselves (`user_roles`, `auth_invites`,
  `auth_events_audit`, etc.) to `service_role` / `forge_admin`, but the
  production Team invite path also writes the cloud-foundation `users` table:
  Firebase Admin -> users -> user_roles -> auth_invites -> audit.

  Keep this grant shape narrow. Tenant runtime can read / touch only the
  `users` fields needed by login freshness and permission snapshots; system
  auth-ops can create and lifecycle-update `users` through the audited
  `forge_admin` BYPASSRLS path. Operator/location/admin tables remain
  read-only to these runtime roles.

## `202604280013_phase_9_audit_actor_kind_live_repair.sql`

- **Applied:** 2026-04-28 00:13
- **Title:** phase 9 audit actor kind live repair
- **Description:**

  Phase 9 live-closeout - auth_events_audit actor attribution repair.

  The live proxy audit writer now records whether an auth event was initiated
  by a human user or a service principal. Staging had the repository deployed
  before these attribution columns existed, which caused MFA confirm to fail
  at the audit insert boundary. Keep this migration intentionally narrow:
  it unblocks current user-auth flows without creating the future
  service_principals table.

## `202604280014_phase_9_0sigma_h2_audit_privacy_role.sql`

- **Applied:** 2026-04-28 00:14
- **Title:** phase 9 0sigma h2 audit privacy role
- **Description:**

  Phase 9.0Σ.h2 — advisor-conversation audit-privacy permission gate
  (parcel B46 in `phase_9_execution_backlog.md`, extends item 5 of
  `phase_9_scalability_decisions_2026-04-27.md`).

  B29 / 9.0Σ.h created the `advisor_conversation_log` table with the
  column-level GRANT SELECT split (raw encrypted columns visible only
  to the `audit_privacy` Postgres role) and the role itself. This
  additive slice closes the missing app-layer half of the gate:

  1. A frozen permission key (`admin.audit_privacy.read`) the
  audit-read code path must hold to call the repository's
  audit-read method. MFA-required so a stolen long-lived
  session cannot be replayed against the raw advisor-content
  surface.
  2. Default role grants for the new key — only `super_admin` and
  `ff_support` (the two seeded F&F-internal roles). The four
  operator-tier roles (`operator_owner`, `operator_manager`,
  `operator_supervisor`, `operator_staff`) deliberately do NOT
  receive the key by default; raw advisor-conversation content
  is F&F-internal until an operator explicitly grants it via
  9.6's role-management surface.
  3. A Postgres role-membership grant: `grant audit_privacy to
  service_role`. This is the privilege the proxy needs so the
  audit-read code path can issue `SET LOCAL ROLE audit_privacy`
  on its already-pooled `service_role` connection. Without the
  membership, `SET LOCAL ROLE audit_privacy` raises
  "permission denied to set role". Granting `audit_privacy` TO
  `service_role` (not the inverse) is the minimal privilege —
  members of `service_role` may assume `audit_privacy` for the
  lifetime of a single transaction; outside that transaction the
  connection runs as plain `service_role` and can only read the
  column-allowlisted metadata.

  Hard rules carried from CLAUDE.md and the 4-27 lock:

  * Permission keys are app-defined and frozen at code level. The
  catalog seeded here mirrors `lib/auth/permission_keys.dart` and
  `docs/contracts/auth_permission_key_catalog.md`. Operators may
  not invent new keys at runtime.

  * MFA-required keys carry `requires_mfa = true` in the seed and
  in `PermissionKeys.requiresMfa`. The runtime resolver (9.6)
  refuses to admit such a key unless the caller's session has a
  fresh `auth_time` MFA assertion.

  * The migration is additive only — it does NOT mutate
  `202604280007_phase_9_0sigma_h_advisor_conversation_log.sql`.
  Re-applying this migration is a no-op (`on conflict do nothing`
  for catalog rows, `do $$` guards on role grants).

  * No live database mutation. Live apply on staging + Production1
  is queued under the Phase 9 live-mutation gate.

## `202604290000_phase_9_b41_service_principal_issue_permission.sql`

- **Applied:** 2026-04-29 00:00
- **Title:** phase 9 b41 service principal issue permission
- **Description:**

  Phase 9 B41 - service-principal JWT issuance permission key.

  Adds the app-layer permission gate for POST
  `/v1/admin/service-principals/{id}/jwt`. The foundation migration
  now includes this row for fresh installs; this additive seed keeps
  already-applied staging/Production1 databases in sync without
  replaying the foundation migration.

## `202604290101_phase_9_hierarchy_access_wiring.sql`

- **Applied:** 2026-04-29 00:01 (local; live apply pending)
- **Title:** phase 9 hierarchy access wiring
- **Description:**

  Phase 9 hierarchy access wiring. Bridges the gap between
  `9.0Σ.c` (`org_units` ltree foundation) and the auth/team grant
  path, which was previously wired only for operator-wide and
  direct-location scopes.

  1. `locations` attaches to an `org_units` parent
     (`parent_org_unit_id`) and carries a denormalized ltree path
     (`org_unit_path`). A `before insert/update` trigger
     (`set_location_org_unit_path`) keeps the denormalized path in
     sync from the parent's `org_units.path`. A GIST index on
     `org_unit_path` supports subtree access checks.

  2. `user_roles` and `auth_invites` gain `scope_type` of
     `'operator_wide' | 'org_unit' | 'location'` plus a paired
     `org_unit_id` column. CHECK constraints enforce the payload
     shape per scope type. Active-grant and org-unit-scoped indexes
     lead with `operator_id` per the locked tenant-leading-index
     discipline.

  3. New table `public.user_effective_locations` materializes which
     locations each active grant reaches, including org-unit
     inheritance via the `loc.org_unit_path <@ ou.path` predicate.
     RLS uses `app_current_operator()` per the 9.0Σ.b wrapper lock.
     Triggers on `user_roles`, `locations`, and `org_units` keep
     the cache fresh.

  Operational shape:

  * The `user_roles` change path uses a narrow per-user refresh
    (`refresh_user_effective_locations(user_id, operator_id)`).
    This is the high-frequency path (hires, role changes,
    revocations).
  * The `locations` and `org_units` change paths use an operator-
    wide refresh. These are onboarding-rare admin operations
    (additive: new restaurant, new department) — re-parents are
    not part of normal operation.

  Idempotent and additive. Existing single-location/operator-wide
  rows are backfilled to the operator root org unit and continue to
  behave exactly as they did before this migration.

  Live apply note:

  * Phase 9 closeout evidence covers staging + Production1 through
    `202604280013`. Apply this migration alongside `202604280014`
    (B46 audit-privacy) and `202604290000` (B41 service-principal
    permission) under a fresh live-mutation gate before live
    consumers depend on `user_effective_locations` or org-unit
    scoped grants.

## `202604300000_phase_9_mfa_factor_removal_requests.sql`

- **Applied:** 2026-04-30 00:00 (local; live apply pending)
- **Title:** phase 9 mfa factor removal requests
- **Description:**

  Phase 9.UX.1a delayed MFA factor removal ledger.

  Creates `public.mfa_factor_removal_requests`, the durable 24-hour queue
  between a self/admin MFA removal request and backend completion. The table
  records operator/location/user scope, the target `mfa_factors.factor_id`,
  requester, opaque step-up proof id, requested/executable timestamps,
  processing lease metadata, completion timestamp, optional cancellation
  timestamp, and last error.

  Indexes cover active-request de-duplication, due worker scans, stale
  processing leases, and recent per-user Settings/Team status reads. RLS is
  tenant/user-scoped for `service_role`; `forge_admin` receives DML for the
  scheduled worker path.

## `202604300001_phase_9_mfa_recovery_request_attempts.sql`

- **Applied:** 2026-04-30 00:01 (local; live apply pending)
- **Title:** phase 9 mfa recovery request attempts
- **Description:**

  Phase 9.UX.1a public MFA recovery-request abuse ledger.

  Creates `public.mfa_recovery_request_attempts` for the public "contact
  restaurant admin" endpoint. It stores hashed email and IP identifiers with
  attempt timestamps, supporting a per-email cooldown and per-IP rolling
  window without retaining raw email or address values in the limiter table.

  Grants `service_role` and `forge_admin` read/insert/delete access plus
  sequence usage. The table is intentionally system-scoped; callers still
  receive generic responses so the endpoint cannot enumerate accounts.

## `202604300002_phase_9_mfa_hardening_launch_roles.sql`

- **Applied:** 2026-04-30 00:02 (local; live apply pending)
- **Title:** phase 9 mfa hardening launch roles
- **Description:**

  Phase 9.UX.1a MFA hardening and launch account role enforcement.

  Adds the dedicated `team.users.reset_mfa` permission key for delayed
  authenticator-app removal/reset actions and grants it only to
  `super_admin` and `operator_owner` by default. Reset-MFA stays outside
  the catalog-level mandatory-MFA set, but the proxy route still enforces
  fresh sign-in before starting admin removal.

  The migration also makes launch smoke-account roles durable: when the
  accounts exist in the target database, `saidumarkhan005@gmail.com` is
  granted the global `super_admin` role and operator-admin assignment for
  the regular account's operator, while `newoundlandlimited@gmail.com`
  has elevated/admin grants revoked and receives the seeded
  `operator_staff` role. If either account is absent in a non-production
  database, the role block emits a NOTICE and skips without failing the
  permission catalog seed.

## `202605010000_phase_11A_4_provider_credentials.sql`

- **Applied:** 2026-05-01 00:00 (local; live apply pending)
- **Title:** phase 11A.4 provider credentials
- **Description:**

  Phase 11A.4 — masked-display ledger for the F&F Operations Console
  Integrations surface.

  Creates `public.provider_credentials` (NOT operator-scoped — provider
  keys are platform-wide) with:

    * `key_kind` (CHECK constraint admits `anthropic`, `voyage`,
      `azure_db`),
    * `masked_value` (display string the admin console renders, e.g.
      `sk-a***Q9aB`; never the full key),
    * `kms_secret_name` (opaque KMS pointer the proxy hands to the KMS
      provider; pre-launch the stub returns `kms://stub/<uuid>`),
    * `created_by` / `updated_by` actor user id stamps,
    * `is_active` + `rotated_at` so the rotate path can append a new
      row and flip the prior row's `is_active` to false in one
      transaction.

  Rotation contract: `provider_credentials_active_uq` is a partial
  unique index on `(key_kind) where is_active`, so exactly one TRUE
  row per kind exists at rest. The repository's rotate path runs
  UPDATE-prior-then-INSERT-new inside the same transaction; if the
  insert fails the transaction rolls back and the prior key stays
  active. Plaintext is NEVER persisted in this table.

  Grants `forge_admin` SELECT/INSERT/UPDATE plus sequence usage. Audit
  rows for rotate-success and rotate-failure land on the existing
  `auth_events_audit` chain via the system-event writer; this
  migration adds no audit columns of its own.
