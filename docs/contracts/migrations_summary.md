# Database migrations summary

Auto-generated from `db/migrations/*.sql` by
`scripts/generate_migrations_summary.py` (manual graph-refresh helper).

Architectural index of `db/migrations/` for the knowledge graph.
The `.sql` files are not extension-supported by graphify; this
summary stands in for them so the graph captures migration shape.

Migration count: **145**

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

  Live apply status:
  * Applied and verified on staging + Production1 on 2026-04-29 as part of
  the Phase 9 `202604280000` through `202604280013` migration set.
  * The matching policy rewrite lands in 202604280001 (next file).

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

  Live apply status:
  * Applied and verified on staging + Production1 on 2026-04-29 as part of
  the Phase 9 `202604280000` through `202604280013` migration set.

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

  Live apply status:
  * Applied and verified on staging + Production1 on 2026-04-29 as part of
  the Phase 9 `202604280000` through `202604280013` migration set.

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

  Live apply status:
  * Applied and verified on staging + Production1 on 2026-04-29 as part of
  the Phase 9 `202604280000` through `202604280013` migration set. The
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

  Live apply status:
  * Applied and verified on staging + Production1 on 2026-04-29 as part of
  the Phase 9 `202604280000` through `202604280013` migration set.

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

  Live apply status:
  * Applied and verified on staging + Production1 on 2026-04-29 as part of
  the Phase 9 `202604280000` through `202604280013` migration set.
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

  Live apply status:
  * Applied and verified on staging + Production1 on 2026-04-29 as part of
  the Phase 9 `202604280000` through `202604280013` migration set.

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

  Live apply status:
  * Applied and verified on staging + Production1 on 2026-04-29 as part of
  the Phase 9 `202604280000` through `202604280013` migration set.

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

  Live apply status:
  * Applied and verified on staging + Production1 on 2026-04-29 as part of
  the Phase 9 `202604280000` through `202604280013` migration set.

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

  Live apply status:
  * Applied and verified on staging + Production1 on 2026-04-29 as part of
  the Phase 9 `202604280000` through `202604280013` migration set.

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

  Live apply status:
  * Applied and verified on staging + Production1 on 2026-04-29 as part of
  the Phase 9 `202604280000` through `202604280013` migration set.

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

  Live apply status:
  * Applied and verified on staging + Production1 on 2026-04-29 as part of
  the Phase 9 `202604280000` through `202604280013` migration set.
  * First observed hot/cold rollup cron runs succeeded on both environments.

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

  Live apply note:
  * Phase 9 closeout evidence only covers staging + Production1 through
  `202604280013`. Apply this additive seed under a fresh live-mutation
  gate before Phase 12 depends on service-principal JWT issuance in live
  environments.

## `202604290100_phase_11A_1_operators_suspended_at.sql`

- **Applied:** 2026-04-29 01:00
- **Title:** phase 11A 1 operators suspended at
- **Description:**

  Phase 11A.1 - Add `operators.suspended_at` column.

  The F&F admin console Operators surface needs to suspend and
  reactivate operators without dropping rows. The cloud-foundation
  migration (`202604250005_advisor_cloud_foundation.sql`) declared
  the `operators` table without a suspension marker; this slice
  adds it as a nullable `timestamptz` so existing rows pass without
  backfill.

  The `OperatorsRepository.suspendOperator` / `reactivateOperator`
  methods read and write this column directly; the admin console
  renders a `suspended` pill when it is non-null. Tenant-wide runtime
  enforcement, if desired, belongs to a future access-control slice
  that can read the same marker.

  Forward-only: no DROP COLUMN escape hatch on rollback. If a
  rollback is ever needed the column can be left in place; nullable
  columns do not constrain inserts.

## `202604290101_phase_9_hierarchy_access_wiring.sql`

- **Applied:** 2026-04-29 01:01
- **Title:** phase 9 hierarchy access wiring
- **Description:**

  Phase 9 hierarchy access wiring.

  The Phase 9 scalability decision lock added `org_units` as the operator
  hierarchy foundation, but the auth/team grant path was still wired only for
  operator-wide and direct-location scopes. This migration bridges that gap:

  * locations attach to an org unit and carry a denormalized ltree path
  * user_roles/auth_invites can target an org unit scope
  * user_effective_locations materializes which locations each active grant
  reaches, including org-unit inheritance

  Idempotent and additive. Existing single-location/operator-wide rows are
  backfilled to the operator root org unit and continue to behave exactly as
  they did before this migration.

## `202604300000_phase_9_mfa_factor_removal_requests.sql`

- **Applied:** 2026-04-30 00:00
- **Title:** phase 9 mfa factor removal requests
- **Description:**

  Phase 9.UX.1 - delayed MFA factor removal requests.

  Removing MFA is delayed for 24 hours. This table is the durable request
  ledger between the user/admin action and the server-side completion pass.

## `202604300001_phase_9_mfa_recovery_request_attempts.sql`

- **Applied:** 2026-04-30 00:01
- **Title:** phase 9 mfa recovery request attempts
- **Description:**

  Phase 9.UX.1a - public MFA recovery-request abuse ledger.

  This table backs the public "contact restaurant admin" recovery endpoint
  with a durable per-email cooldown and per-IP rolling window. Values are
  SHA-256 hashes so the limiter does not store raw email addresses or IPs.

## `202604300002_phase_9_mfa_hardening_launch_roles.sql`

- **Applied:** 2026-04-30 00:02
- **Title:** phase 9 mfa hardening launch roles
- **Description:**

  Phase 9 MFA hardening and launch account role enforcement.

  Goals:
  * Add a dedicated team.users.reset_mfa permission for delayed 2FA
  removal/reset actions instead of piggybacking on password reset.
  * Grant that permission to super_admin and operator_owner only.
  * Make the launch smoke-account roles durable in database migrations:
  - saidumarkhan005@gmail.com is the highest admin account.
  - newoundlandlimited@gmail.com is a regular operator staff user.

  This migration is idempotent. If either launch account is absent in a
  non-production database, it emits a NOTICE and skips only the account
  repair block; the permission catalog change still applies.

## `202605010000_phase_11A_3a_corpus_versions_ledger.sql`

- **Applied:** 2026-05-01 00:00
- **Title:** phase 11A 3a corpus versions ledger
- **Description:**

  Phase 11A.3a — Corpus admin ledger.

  Adds a `corpus_versions` ledger plus a many-to-many membership
  table so the F&F admin Corpus screen can:

  * list every corpus version with its actor + summary,
  * fetch the chunks that belong to one version (membership is
  resolved through the join table, not by overwriting per-chunk
  pointers — the same chunk row may legitimately be a member of
  several versions when its content is unchanged),
  * stamp prior chunks `superseded_at` when a new version commits,
  * roll back to a prior version by writing a new row whose
  `rollback_of` points at the target.

  Per CLAUDE.md (Postgres host = Azure DB Flexible Server PG 16) and
  the cloud foundation migration `202604250001`, the corpus tables
  live in `public` and use UUIDs from `pgcrypto`.

## `202605010000_phase_11A_4_provider_credentials.sql`

- **Applied:** 2026-05-01 00:00
- **Title:** phase 11A 4 provider credentials
- **Description:**

  Phase 11A.4 — Provider credential ledger.

  The F&F Operations Console rotates server-side keys (Anthropic,
  Voyage, Azure DB) without ever exposing plaintext to the operator
  app. Plaintext lives in Cloud Run env / KMS; this table is the
  masked-display ledger that backs the admin Integrations surface.
  Every rotation appends a new row and flips the prior row's
  `is_active` to false in one transaction so a rotation failure can
  never leave two active rows for the same `key_kind` and the
  previous key stays in service until KMS confirms the new write.

  Row shape:
  * `key_kind`         — stable lane name (`anthropic`, `voyage`,
  `azure_db`). The proxy accepts only the
  locked set; UI surfaces match.
  * `masked_value`     — display string the admin console renders
  (e.g. `sk-ant-***Q9aB`). Never the full key.
  * `kms_secret_name`  — opaque pointer the proxy hands to the
  KMS provider (`kms://stub/<uuid>` for the
  stub provider; production swaps in the
  real Cloud Run / KMS scheme post-launch).
  * `created_by`,      — actor user id stamps for audit-on-rotate.
  `updated_by`         The full chain lives in
  `auth_events_audit` via the existing
  system-event writer.
  * `rotated_at`       — explicit rotation timestamp. Distinct
  from `created_at` so future migrations can
  backfill historical rotation moments
  without rewriting `created_at`.
  * `is_active`        — exactly one TRUE row per `key_kind` at
  rest. Enforced by the partial unique
  index below; the rotation path inserts
  the new row and updates the prior in one
  transaction so the constraint is never
  violated.

  This table is NOT operator-scoped. Provider credentials are F&F
  platform-wide (we hold one Anthropic key for the whole product).
  No `operator_id` column, no RLS policy. Reads/writes run through
  the admin pool only; the route handler enforces the
  `super_admin` role gate.

## `202605010001_phase_9_b4_role_audit_log_operator_id.sql`

- **Applied:** 2026-05-01 00:01
- **Title:** phase 9 b4 role audit log operator id
- **Description:**

  Phase 9 slice B.4 - role_audit_log gains operator_id; indexes
  re-keyed to lead with operator_id; RLS simplified.

  Background. `role_audit_log` was created in
  `202604250008_auth_schema_foundation.sql` without an operator_id
  column. The 9.0Σ.b RLS policy filtered tenant access via subqueries
  against `roles` / `user_roles`. CLAUDE.md "RLS performance discipline"
  locks the rule that every B-tree index on an operator-scoped fact
  table must lead with operator_id (or `(operator_id, location_id)`);
  the subquery-style policy also planned poorly under RLS.

  The simplified SELECT policy reads `operator_id IS NULL OR
  operator_id = public.app_current_operator()`. That is safe ONLY if
  a NULL operator_id genuinely means "global role mutation"
  (`roles.operator_id IS NULL`) — never "we couldn't resolve the
  source row". `role_audit_log.role_id` and `user_role_id` are not
  FK-constrained, so a row with a non-null but dangling source id
  would have been hidden from every tenant by the legacy subquery
  policy and would otherwise become globally visible after the swap.
  This slice closes that regression with a write gate (BEFORE
  INSERT trigger), a shape gate (CHECK + VALIDATE), and a pre-swap
  verification of all rows that pre-date the gates.

  ─── ORDERING is load-bearing ────────────────────────────────────
  Each block runs in an implicit per-statement transaction; the
  migration MUST be applied without an enclosing `BEGIN; … COMMIT;`
  wrapper because CONCURRENTLY index ops cannot run inside a
  transaction. Live writers are not blocked between statements.
  That means a step ordering that does backfill → verify → trigger
  has a window during which a legacy writer (one that doesn't set
  operator_id) can land a row with a dangling source id, slip past
  both backfill and verify, and only become a problem after the
  policy swap.

  The order below installs the BEFORE INSERT trigger BEFORE the
  backfill/verify window. From the moment CREATE TRIGGER returns,
  every new INSERT is either auto-resolved (trigger sets
  operator_id from roles / user_roles) or rejected (trigger raises
  23514). Backfill + verify then operate on a frozen set of
  pre-trigger rows; nothing can sneak in behind them.

  1. ADD COLUMN operator_id (nullable, instant metadata-only).
  2. Trigger function + BEFORE INSERT trigger.
  Closes the write gate. From this point on, no INSERT can
  land with a NULL or unresolved operator_id.
  3. CHECK constraint role_audit_log_source_not_null
  (ADD … NOT VALID). Shape gate for future writes; pre-existing
  rows are not yet validated. The trigger above already raises
  on both-NULL inserts, so this CHECK is redundant for INSERTs
  but matters for any future UPDATE path.
  4. Backfill operator_id from the source mutation. user_roles
  wins when set (its operator_id is NOT NULL); falls back to
  roles. Idempotent via `where operator_id is null`. Resolves
  every pre-trigger row whose source row exists.
  5. VERIFY no regression-bearing pre-trigger rows remain.
  Two classes: both-NULL (role_id AND user_role_id both NULL)
  and unresolved-source (non-null source id with no matching
  roles / user_roles row). Both were hidden by the legacy
  subquery policy and would become globally visible under the
  new operator_id-NULL-is-global policy. Raises EXCEPTION with
  a diagnostic query for whichever class is detected first.
  6. VALIDATE CONSTRAINT role_audit_log_source_not_null.
  Re-checks the CHECK against every pre-existing row. By this
  point the verify in step 5 has already raised on any
  both-NULL row; this is belt-and-suspenders.
  7. RLS policy swap. By now the write gate has been live since
  step 2, the shape gate has been live since step 3, the
  backfill has resolved every pre-trigger row that could be
  resolved, and the verify + validate have refused to proceed
  on any pre-trigger row that couldn't. The simplified
  direct-operator_id SELECT policy can take effect without
  regressing tenant isolation.
  8. Replace indexes (CONCURRENTLY). Drop the three legacy
  non-operator-leading indexes; create five operator-leading
  replacements (tenant + global partials, mirroring
  auth_events_audit). Out-of-band relative to the policy swap
  because CONCURRENTLY can't run inside a transaction.

  Re-applying is a no-op: every IF EXISTS / IF NOT EXISTS / WHERE
  operator_id IS NULL guard is set up so subsequent runs neither
  error nor duplicate work.

  Hard rules carried into this slice:

  * `public.app_current_operator()` wrapper (item 4); bare
  `current_setting()` is forbidden.
  * Repository pattern is the primary defense; RLS is the backup.
  This migration only changes RLS, never bypasses it.
  * Append-only grant shape preserved; INSERT policy unchanged;
  UPDATE / DELETE remain revoked from service_role.

  ─── 1. Add operator_id column ─────────────────────────────────────

## `202605010100_phase_9_0sigma_f_audit_logs_cutover_flag.sql`

- **Applied:** 2026-05-01 01:00
- **Title:** phase 9 0sigma f audit logs cutover flag
- **Description:**

  Phase 9.0Σ.f B.2 — feature flag: audit_logs cutover gate.

  Seeds a global-scope `feature_flags` row that gates the auth-event
  fan-out into the hash-chained `public.audit_logs` table from the B.2
  writer boundaries (the AuthEventsAuditRepository repository seam, the
  B41 `PostgresServicePrincipalJwtIssuanceGateway` raw-SQL seam, and
  the `InvitedUserActivationRepository` raw-SQL seam).

  Default `enabled = true`. Toggle to `false` for a one-shot rollback
  if a deploy surfaces an unexpected fan-out incident; the legacy
  `auth_events_audit` writes continue unchanged on either side of the
  flag, so the audit posture never has a gap.

  Idempotent: a `not exists` guard skips the seed on re-apply so a
  manual operator override (already-applied `false` for rollback)
  survives the migration replay. Plain `on conflict` would not work
  here — `feature_flags` enforces global-scope uniqueness through a
  partial index (`feature_flags_global_scope_idx`), not a named
  constraint, so `on conflict on constraint <name>` is unavailable.

## `202605020000_phase_11A_b42_proxy_migrations_applied.sql`

- **Applied:** 2026-05-02 00:00
- **Title:** phase 11A b42 proxy migrations applied
- **Description:**

  Phase 11A.B42 — proxy_migrations_applied registry + drift detection.

  The `migration_apply_drift_count` Tier-1 health producer needs a
  live source of truth for which migrations have been applied to the
  target database. Without a registry, drift detection has nothing to
  compare `db/migrations/` against and the producer renders unknown.

  This migration creates two artefacts:
  1. `public.proxy_migrations_applied` — append-only registry rows
  (`migration_filename`, `applied_at`). The proxy startup writes
  one row per file in `db/migrations/` it has observed since boot.
  2. `public.proxy_migration_apply_drift()` — set-returning function
  returning `(drift_count int, missing_migrations text[])`.
  `drift_count` = number of files the producer was told about at
  startup that the registry does not yet record. The producer maps
  `drift_count >= 1` → red.

  Hard rules:
  * Append-only — no rows are ever updated or deleted.
  * Operator-agnostic — this is a platform-wide registry, not
  operator-scoped, so RLS is intentionally disabled here.
  * No tenant identifiers stored.

## `202605020001_phase_11A_3b_graphify_review_audit.sql`

- **Applied:** 2026-05-02 00:01
- **Title:** phase 11A 3b graphify review audit
- **Description:**

  Phase 11A.3b — graphify_review_audit append-only audit table.

  Slice scope: when the F&F super_admin reviews Graphify-derived
  graph candidates in the Corpus Admin "Graph candidates" tab, every
  *rejected* (or edited-then-rejected) decision lands here. Approved
  candidates are written to the canonical `public.graph_nodes` /
  `public.graph_edges` tables (created in 9.0Σ.i, migration
  `202604280008`); rejected candidates are NEVER written to those
  canonical tables, so the AGE projection rebuild — which reads
  canonical rows only — physically cannot surface a rejected
  candidate to the advisor runtime.

  Why a NEW table instead of reusing audit_logs:
  * audit_logs (9.0Σ.f) is the global hash-chained system audit
  trail. It carries one row per business action; that row's
  `payload` is opaque to schema-level queries.
  * graphify_review_audit captures the candidate payload itself
  (node_key / edge_key shape, source provenance, confidence,
  classification) so the F&F admin can re-render the rejected
  candidate later for review or appeal without round-tripping
  to the original graphify-out artifact (which is NOT shipped
  as production truth, per the slice's hard constraint).
  * The proxy still fans the rejection out to audit_logs via the
  existing AuditLogsRepository so the global hash-chain stays
  intact (the audit_logs payload references the audit_id from
  this table for cross-walk).

  Hard rules carried from CLAUDE.md and the 4-27 lock:

  1. **Operator-scoped from creation.** Every row carries
  `operator_id`; the tenant-leading B-tree index on
  `(operator_id, decided_at desc)` folds the RLS policy probe
  into the index lookup (CLAUDE.md "RLS performance discipline").

  2. **RLS via wrapper functions.** The policy uses
  `public.app_current_operator()` (9.0Σ.b); bare
  `current_setting()` is forbidden by the lint at
  `tool/rls_policy_lint.dart`.

  3. **TIMESTAMPTZ for every datetime column.** Naive (non-tz)
  types are banned in operator-scoped tables per CLAUDE.md
  storage rule.

  4. **Composite FK to `public.locations(operator_id, location_id)`.**
  Same-operator location pointer; cross-operator location
  reference is a database error.

  5. **Append-only by grant shape.** service_role and forge_admin
  both get INSERT and SELECT only; UPDATE and DELETE are
  explicitly REVOKEd. Mirrors the auth_events_audit pattern
  from 202604260001 (lines 42-50). A future grant change
  cannot accidentally weaken the posture without an explicit
  reviewer's notice.

  6. **Zero foreign keys into `graph_nodes` / `graph_edges`.** The
  audit table holds the rejection payload as JSONB — it does
  NOT reference any canonical-graph row. This is the schema-
  level guarantee that AGE traversal cannot reach audit data:
  AGE projects from canonical FKs only. The
  `age_unapproved_isolation_test` contract test asserts this
  shape post-migration.

  Live apply status:
  * Will land on staging + Production1 alongside the rest of the
  11A.3b slice. The migration is guarded by `create table if not
  exists` + idempotent GRANT/REVOKE so a re-run is a no-op.

## `202605020001_phase_11A_4b_gemini_provider_kind.sql`

- **Applied:** 2026-05-02 00:01
- **Title:** phase 11A 4b gemini provider kind
- **Description:**

  Phase 11A.4b — widen provider_credentials.key_kind to admit 'gemini'.

  11A.4 (202605010000_phase_11A_4_provider_credentials.sql) locked the
  key_kind set to ('anthropic', 'voyage', 'azure_db'). Block 2 adds
  Gemini as a server-side LLM fallback (see Hard Promise #7 in
  CLAUDE.md), which adds a fourth rotatable lane to the masked-display
  ledger that backs the F&F Operations Console. The row shape, the
  partial unique index, and the rotation transaction shape are all
  unchanged — only the CHECK constraint widens.

  The constraint is dropped and recreated under the same name so future
  audits / dumps see a single named constraint per kind set, not a
  chain of historical aliases.

## `202605020100_phase_11A_b43_cache_telemetry_v2.sql`

- **Applied:** 2026-05-02 01:00
- **Title:** phase 11A b43 cache telemetry v2
- **Description:**

  Phase 11A.B43 — cache_telemetry_v2 / corpus_invalidation_events.

  One append-only row per corpus commit so the F&F operations dashboard
  can correlate prompt-cache hit-rate drops with corpus material changes.
  Lever 1 (Anthropic prompt caching) keys cache entries on
  `corpus_version`; when `OperatorScopedCorpusRepository.commitVersion`
  supersedes the prior version, every dependent prompt-cache entry is
  invalidated. Recording the event here lets dashboards answer
  "did cache hit-rate just drop because we shipped a corpus update?"
  without scraping repository commits.

  Hard rules:
  * Append-only — no rows are ever updated or deleted.
  * Fleet-scope — `corpus_versions` has no `operator_id` (the corpus is
  shared across the fleet), so this audit table also has no
  operator_id. RLS is intentionally NOT enabled; the table stores no
  tenant identifiers and is admin-only by GRANT posture.
  * Behind feature flag — repository writes only fire when the proxy's
  `cache_telemetry_v2` flag is true. The migration is unconditional
  so the table exists ahead of the flag flip.

## `202605020200_phase_11A_4c_kms_rollout_flags.sql`

- **Applied:** 2026-05-02 02:00
- **Title:** phase 11A 4c kms rollout flags
- **Description:**

  Phase 11A.4c — Per-lane feature flags for the GCP Secret Manager
  rollout. Every flag starts OFF; production rollout flips one lane
  at a time in this order: azure_db -> voyage -> gemini -> anthropic
  (lowest-risk first, primary lane last).

  When the flag for a given key_kind is OFF, [KmsLaneRouter] dispatches
  rotation writes to [KmsStubProvider] (the existing 11A.4 behavior —
  audit-only, kms://stub/<uuid> pointer). When ON, rotation writes
  land in [GcpSecretManagerKmsProvider] which:
  1. Adds a new version under projects/<P>/secrets/forge-flow-<kind>-api-key
  2. (For runtime-read lanes only) deploys a new Cloud Run revision so
  every instance picks up the new Secret Manager version.

  Rollback: flip the flag back to false. The `kms_stub_provider` is
  still wired and ready to serve. Already-rotated rows in
  provider_credentials with `kms://gcp-secret-manager/...` pointers
  stay valid — they're audit history, not active runtime references.

## `202605020300_phase_9_firebase_uid_text.sql`

- **Applied:** 2026-05-02 03:00
- **Title:** phase 9 firebase uid text
- **Description:**

  Phase 9 MFA production hardening - Firebase UID text repair.

  Earlier Phase 9 schema work assumed Firebase Identity Platform UIDs would
  always be pre-generated UUID strings. Live Firebase users can have arbitrary
  UID strings, and MFA removal workers must target that real Firebase UID, not
  the local app user_id. Convert the link column to text while preserving
  existing UUID-shaped placeholder values.

## `202605020400_phase_11A_7_feature_flags_admin_columns.sql`

- **Applied:** 2026-05-02 04:00
- **Title:** phase 11A 7 feature flags admin columns
- **Description:**

  Phase 11A.7 — feature_flags admin columns.

  The 11A.7 admin Feature Flags screen needs three additional columns
  on `public.feature_flags` that the launch schema in
  `db/migrations/202604250005_advisor_cloud_foundation.sql` did not
  carry:

  * `kind` text not null default 'standard'
  Marks a flag as `standard` (default) or `destructive`. The admin
  UX renders a DANGER chip for destructive flags and forces a
  confirm-by-typing-flag-name dialog before letting a super_admin
  toggle one. Examples: `circuit_breaker_open`, future Phase 12
  workflow kill switches. The classification lives on the row so
  the screen does not need a hard-coded allowlist that drifts.

  * `description` text null
  One-line operator-facing description for the flag list. Optional
  so the existing seeded rows (which were created without a
  description) keep working.

  * `updated_by` text null
  Stores the `user_id` (UUID-shaped string) of the actor who last
  toggled the flag. Used by the screen to render the "last toggle"
  metadata column. Plain `text` (not `uuid`) so service-principal
  toggles can carry the `sp:<id>` shape used by item 14, and so
  migration-only seeds can leave it null without a CHECK violation.
  Full-fidelity attribution still flows through `audit_logs` /
  `auth_events_audit` — this column is the cheap denormalized
  read for the admin grid.

  Idempotent: every column add uses `if not exists`, every column
  comment uses `comment on column`, and the destructive-flag seed
  update uses `where kind <> 'destructive'` so re-applies don't
  bounce the column for an operator override (a super_admin who
  intentionally re-classified a flag through the 11A.7 admin UX).

## `202605020452_hardening_auth_login_attempts.sql`

- **Applied:** 2026-05-02 04:52
- **Title:** hardening auth login attempts
- **Description:**

  HARD-B - public.auth_login_attempts table for the auth lockout
  ledger. Authority: docs/contracts/hardening_auth_protection_contract.md
  "Lockout Schema".

  Records every credential attempt against the proxy login surface so
  the lockout enforcer can count failures in the rolling 15-minute
  window per (user_email_hash, ip_hash) and trip the 5-failure /
  423-Locked threshold without leaking which arm of the window the
  failure landed in. The table also carries the per-tenant rows the
  post-resolution success/failure path writes once the email maps to
  a known operator.

  Hard rules (CLAUDE.md + 9.0Sigma.b RLS wrappers):

  1. **Tz-naive timestamp columns are banned.** Every timestamp
  column is `timestamptz`. The partition driver (pg_partman) is
  registered on a derived `attempted_date date` so daily
  partition pruning works without a `timestamp` column.

  2. **RLS performance discipline (CLAUDE.md).** Every B-tree index
  that carries `operator_id` leads with it; the anonymous-lookup
  index leads with `(user_email_hash, attempted_at desc)` so the
  pre-tenant lookup the proxy runs (no scope resolved yet) hits
  the same probe shape. RLS policies call the 9.0Sigma.b wrapper
  functions; bare `current_setting()` is forbidden.

  3. **Append-only by grant shape.** service_role and forge_admin
  get INSERT and SELECT only. UPDATE and DELETE require partition
  drop via the DBA cadence (audit retention discipline).

  4. **Retention via pg_partman.** Daily range partitioning aligned
  with audit_logs (202604280005_phase_9_0sigma_f_audit_logs.sql).
  Anonymous-scope rows (operator_id IS NULL) age out at 30 days
  via partition drop; tenant-bound rows ride the audit_logs
  retention window. The retention sweep is documented next to
  the audit_logs partition runbook.

  5. **Sensitive fields are never stored in plaintext.** Email is
  stored as `bytea` SHA-256 (the proxy hashes the normalized
  email before insert). IP is stored as `bytea` SHA-256 (the
  proxy hashes the inbound client IP before insert). The
  `user_agent_class` column stores a coarse classifier
  ("desktop", "mobile", "bot", "unknown") - never the raw
  User-Agent string.

  6. **operator_id nullable on purpose.** The login route hits this
  table BEFORE Firebase scope is resolved (anonymous lookups by
  `(user_email_hash, ip_hash)`). Once a successful login resolves
  a tenant, the success row carries `operator_id` and the per-
  tenant RLS policy admits it. Mixed nullability is the locked
  shape per the contract.

## `202605020500_hardening_auth_rls_to_wrappers.sql`

- **Applied:** 2026-05-02 05:00
- **Title:** hardening auth rls to wrappers
- **Description:**

  HARD-F — defense-in-depth re-assert of wrapper-based auth RLS policies.

  Re-applies the wrapper-function rewrite that 202604280001 already
  landed for the 12 auth tables originally defined in 202604260000.
  The rewrite drops + recreates each per-tenant / per-user policy so
  bare `current_setting('app.<name>', true)::uuid` reads cannot creep
  back onto these tables — for example after a hand-edit on staging
  or after an out-of-band restore that resurrected the 9.2 shape.

  All four wrapper functions
  (`app_current_operator`, `app_current_location`, `app_current_actor_user`,
  `app_acting_as_operator`) live in 202604280000_phase_9_0sigma_b_rls_wrappers.sql
  and are frozen — this migration depends on them but never redefines
  them.

  Behavioral parity: every policy below matches the predicate shape the
  202604280001 rewrite uses. Append-only audit grants on
  `auth_events_audit` and `role_audit_log` keep `with check (true)` on
  INSERT so failed-tenant logins still write an audit row.

  Idempotency posture (HARD-F hard constraint): every DROP uses `if
  exists` and the migration runs in `psql --single-transaction` so the
  tables are never policy-less between statements. Re-running this
  migration is a no-op when 202604280001 has already been applied.
  Running it on a database that somehow lost the 202604280001 rewrite
  restores the wrapper-based policies in one atomic transaction.

  Lint coverage: `tool/rls_policy_lint.dart` rejects any new migration
  whose policy body reads `current_setting` directly against an `app.`
  GUC. The two files that historically held the bare reads
  (202604260000 and a hypothetical out-of-band rewrite) are listed in
  `tool/rls_policy_lint_allowlist.txt`. Every policy below uses the
  wrappers and therefore needs no allowlist entry.

  Tables touched (16 policies across 12 tables, matching 202604280001):

  public.permission_keys           — permission_keys_authenticated_select
  public.roles                     — roles_per_tenant_select / _modify
  public.role_permissions          — role_permissions_per_tenant_select / _modify
  public.user_roles                — user_roles_per_tenant
  public.auth_sessions             — auth_sessions_per_user
  public.mfa_factors               — mfa_factors_per_user
  public.tncs_acceptances          — tncs_acceptances_per_tenant
  public.password_history          — password_history_per_user
  public.auth_invites              — auth_invites_per_tenant
  public.auth_events_audit         — auth_events_audit_per_tenant_select / _append_insert
  public.role_audit_log            — role_audit_log_per_tenant_select / _append_insert
  public.external_identity_links   — external_identity_links_per_tenant

  ─── Drop existing policies ────────────────────────────────────────

  Ordered by table for readability; the runner applies the whole
  migration as one transaction so order does not matter for atomicity.

## `202605021000_phase_hardh_admin_idempotency.sql`

- **Applied:** 2026-05-02 10:00
- **Title:** phase hardh admin idempotency
- **Description:**

  HARD-H — admin request idempotency (cross-tenant admin operations).

  The Phase 9 `proxy_requests` table provides idempotency for tenant-
  scoped routes (operator_id + location_id NOT NULL with composite FK
  to `public.locations`). F&F admin operations driven by super_admin /
  ff_support actors are cross-tenant — the actor JWT carries no
  operator_id, and the route may legitimately mutate global rows
  (e.g. `feature_flags` with operator_id IS NULL). proxy_requests
  cannot host these because:

  1. operator_id is NOT NULL (no value to write for cross-tenant
  admin actions);
  2. (operator_id, location_id) composite FK requires a real
  locations row — admin actions don't have one.

  This table provides idempotency for those routes. Scope axis is
  (idempotency_key) — admin actors are global and the route is the
  only producer, so a single-key UNIQUE is sufficient. `request_type`
  is recorded so a key reused across different admin operations
  surfaces as a `idempotency_key_conflict` 409 (matching the
  service-principal idempotency contract).

  Live target: HARD-H feature flags admin route. Other admin routes
  (operators, locations, pricing tiers, integrations) can adopt the
  same store as their idempotency posture is rolled out.

## `202605021500_phase_9_0sigma_l_rls_depth.sql`

- **Applied:** 2026-05-02 15:00
- **Title:** phase 9 0sigma l rls depth
- **Description:**

  Phase 9.0Σ.l — RLS defense-in-depth on proxy_requests + feature_flags.

  Closes the P1 gap from `docs/POST_HARDENING_FOLLOWUPS.md`: both tables
  were created in `202604250005_advisor_cloud_foundation.sql` with RLS
  ENABLED but only carried the permissive `*_service_role_all using
  (true) with check (true)` stub policies the cloud-foundation drop
  shipped. Today's posture is therefore application-layer only —
  `OperatorScopedRepository` injects the tenant predicate, and the
  service-role-only policies do not assert anything else. This slice
  adds the database-side second layer.

  Authority order:
  1. CLAUDE.md "RLS-Ready Schema" — two-layer defense; repository is
  primary, RLS is the backup.
  2. `phase_9_scalability_decisions_2026-04-27.md` item 4 — RLS UUID
  wrappers (every operator-scoped policy reads tenant context
  through `app_current_operator()` + `app_current_location()` so
  the planner can fold the predicate into the tenant-leading
  index).
  3. `phase_9_scalability_decisions_2026-04-27.md` RLS performance
  discipline — every B-tree index leads with `operator_id`. The
  `proxy_requests` indexes from `202604250007_advisor_rls_index_
  hardening.sql` already comply (PK + the
  `proxy_requests_operator_location_idempotency_key_key` UNIQUE
  lead with `operator_id, location_id`); this migration does not
  add or rewrite any index.
  4. `202604280000_phase_9_0sigma_b_rls_wrappers.sql` — the wrapper
  functions this migration calls.

  Behavioral parity:

  * proxy_requests: location-scoped — proxy writes carry both
  operator_id and location_id (tenant transactions inject both
  GUCs). Policy filters on `(operator_id, location_id)` so a
  stray request whose location belongs to a different operator
  cannot be read or written even if the application-layer scope
  check is bypassed.

  * feature_flags: three logical scopes (global / operator-wide /
  location-scoped), enforced today by partial unique indexes from
  202604250005. The policy mirrors that shape — global rows
  (operator_id IS NULL) are visible to every tenant, operator/
  location-scoped rows are visible only to their owning operator.
  WITH CHECK is the asymmetric half: a tenant CANNOT insert or
  update a global-scope row through this policy. Migration-side
  seeds (the `audit_logs_cutover_enabled` and KMS rollout flags
  in 202605010100 and 202605020200) run as the deployment role,
  which owns the table and is therefore RLS-exempt; super-admin
  mutations from the 11A.7 admin Feature Flags screen elevate to
  `forge_admin BYPASSRLS` via `runAsSystem`. Net effect: tenants
  read their own + global flags but can only mutate their own.

  Idempotency: every DROP uses `if exists`; the file applies in one
  transaction (`psql --single-transaction`), so the tables are never
  policy-less between statements. Re-runs are no-ops.

  Lint coverage: every CREATE POLICY body below reads tenant context
  through wrapper functions, so `tool/rls_policy_lint.dart` does not
  need an allowlist entry for this file.

  ─── proxy_requests: drop permissive stub, add per-tenant policy ────

## `202605021600_phase_11A_7_feature_flags_forge_admin_grants.sql`

- **Applied:** 2026-05-02 16:00
- **Title:** phase 11A 7 feature flags forge admin grants
- **Description:**

  Phase 11A.7 follow-up -- feature_flags runtime grants.

  The admin Feature Flags repository and the proxy startup/runtime flag
  checks run through TenantTransactionWrapper.withSystem, which sets the
  transaction role to forge_admin. BYPASSRLS skips row policies, but it does
  not grant table privileges, so forge_admin still needs explicit
  SELECT/UPDATE on public.feature_flags.

## `202605021700_phase_11A_health_age_graph_bootstrap.sql`

- **Applied:** 2026-05-02 17:00
- **Title:** phase 11A health age graph bootstrap
- **Description:**

  Phase 11A health AGE graph bootstrap.

  The strict /health AGE probe executes a real cypher MATCH against the
  canonical graph name. An empty graph is healthy, but a missing graph is
  schema/config drift. Keep the graph namespace present even before corpus
  projection has materialized vertices or edges.

## `202605021710_phase_11A_health_age_runtime_grants.sql`

- **Applied:** 2026-05-02 17:10
- **Title:** phase 11A health age runtime grants
- **Description:**

  Phase 11A health AGE runtime grants.

  The proxy health runner executes dependency probes through
  TenantTransactionWrapper.runAsSystem, which assumes the runtime
  Postgres role `forge_admin`. Apache AGE keeps its functions/types in
  ag_catalog and graph label tables in the graph-named schema. Creating the
  extension/graph as the database owner is not enough for that runtime role:
  it still needs explicit schema/function/table privileges before a strict
  cypher MATCH can prove the graph path is healthy.

## `202605021800_hardening_auth_login_attempts_index_rekey.sql`

- **Applied:** 2026-05-02 18:00
- **Title:** hardening auth login attempts index rekey
- **Description:**

  HARD-B follow-up: re-key auth_login_attempts indexes now that the
  repo-wide operator-leading lint covers this table.

  The email-hash lockout index remains intentionally cross-tenant:
  the login lockout enforcer evaluates `(email_hash, ip_hash)` before
  Firebase/operator scope exists and runs through the forge_admin
  BYPASSRLS path. The IP-failure triage index, however, supports
  operator-side review and must lead with operator_id.

## `202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql`

- **Applied:** 2026-05-02 19:00
- **Title:** phase 11A 3a corpus versions seed existing chunks
- **Description:**

  Phase 11A.3a follow-up: seed the corpus version ledger from any
  active corpus chunks that were loaded before the admin ledger
  existed.

  11A.3a intentionally made advisor_source_chunks.version_id
  nullable so pre-existing staging loads would keep working. The
  live admin screen, however, reads corpus_versions plus the
  corpus_version_chunks membership table. If staging already has
  active chunks but an empty ledger, the screen truthfully says
  "No corpus versions yet" even though retrieval data exists. This
  one-time seed creates a baseline ledger row only for that state.

## `202605030000_phase_9_5_0_leaderboard_schema_rls.sql`

- **Applied:** 2026-05-03 00:00
- **Title:** phase 9 5 0 leaderboard schema rls
- **Description:**

  Phase 9.5.0 — El Podio leaderboard schema + per-tenant RLS.

  Backend skeleton for the El Podio learning leaderboard. The phase 9.5
  plan replaces the demo-only `el_podio_demo_data.dart` consumer with a
  real authenticated multi-user board sourced from durable Postgres
  truth. UX (operator/staff-facing leaderboard surfaces) lands in the
  9.5.UX slice; this slice owns ONLY the table + RLS posture + thin
  repository skeleton so 9.5.x consumers have a stable shape to bind
  against.

  Hard rules carried verbatim from CLAUDE.md (Authority Order item 5):

  1. **RLS-Ready Schema (CLAUDE.md).** The fact table includes
  `(operator_id, location_id)` from creation; single-location
  operators run with the operator's `primary_location_id` injected
  as the default `location_id`. Scaffolding is NOT retrofitted
  later.

  2. **OperatorScopedRepository is the primary defense; RLS is the
  backup.** This migration ships the secondary defense. The
  repository (lib/infrastructure/persistence/postgres/repositories/
  leaderboard_score_repository.dart) carries the SET LOCAL ordering
  and the tenant-scoped INSERT/SELECT shape so a missing or
  malformed RLS policy cannot leak rows even before the policy is
  evaluated.

  3. **Wrapper-only RLS posture (Phase 9.0Σ.b item 4).** Every policy
  body calls the locked
  `STABLE LEAKPROOF PARALLEL SAFE` wrapper functions
  (`app_current_operator()`, `app_current_location()`,
  `app_current_actor_user()`). No bare
  `current_setting('app.<name>', true)::uuid` reads — the
  `tool/rls_policy_lint.dart` rule rejects them.

  4. **Tenant-leading B-tree indexes (CLAUDE.md / 9.0Σ.b item 4).**
  Every B-tree index leads with `operator_id` (or `(operator_id,
  location_id)`) so the planner can fold the per-tenant policy
  into the index probe. CI lint enforces.

  5. **Time guardrails (CLAUDE.md, phase_7_55_time_boundary_contract).**
  `occurred_at` is `timestamptz` (UTC source-truth instant);
  `business_date` is a denormalized `date` computed at write from
  the operator's location timezone + `business_day_rollover_hour`.
  The repository derives `business_date` from the same instant so
  the DB does not need to read `locations` in the hot path; a
  CHECK constraint guards against malformed dates (1900-01-01 or
  later) without recomputing the projection in SQL.

  6. **Append-only fact-table grants.** `service_role` and
  `forge_admin` get INSERT and SELECT on `leaderboard_scores`;
  UPDATE/DELETE are explicitly REVOKEd. Score events are
  immutable history — re-ranking is a read-side projection over
  the append log, not a row-level mutation. Retention sweeps are
  a Phase 9.5.x follow-up (the Operations El Podio phase will
  decide retention windows by score_event_type).

  Live apply status:
  * NOT YET APPLIED. The Phase 9.5 launch lane will apply this on
  staging + Production1 once 9.5.UX has shipped enough surface to
  justify a board-level migration apply window. The migration is
  idempotent (`if not exists` on table + indexes; `drop policy if
  exists` before `create policy`) so re-running it is safe.

## `202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql`

- **Applied:** 2026-05-03 14:30
- **Title:** phase 11A 5 debug proxy requests forge admin grant
- **Description:**

  Phase 11A.5 follow-up -- debug console proxy_requests grant.

  The Debug Console request-log gateway runs through
  TenantTransactionWrapper.runAsSystem, which sets the transaction role to
  forge_admin. BYPASSRLS skips tenant row policies, but it does not grant table
  privileges. The live staging route was returning 503 because forge_admin
  could not SELECT from public.proxy_requests after the Phase 9.0Sigma.l RLS
  hardening policy flip.

## `202605040000_phase_8_0_integration_framework.sql`

- **Applied:** 2026-05-04 00:00
- **Title:** phase 8 0 integration framework
- **Description:**

  Phase 8.0 — Inbound integration framework schema (V1 lean cut 2).

  The framework slice for Phase 8 / 8R / 8.S. Adds the per-vendor
  credential storage, connection state, watermark, sync log, webhook
  idempotency + dead-letter, demo-mode state, and raw-payload
  retention pattern. The first concrete vendor adapter (8.LSK,
  8R.LB, 8.S.QBT) plugs in via subsequent slices.

  Hard rules carried verbatim from CLAUDE.md / phase docs:

  1. **HP #1 transport-only.** No business-logic table is touched
  here. We add a single `raw_payload JSONB` column to existing
  canonical fact tables (sales / covers / punches /
  reservations) and the new framework tables. No formula, no
  read-service contract.

  2. **HP #4 RLS-Ready Schema.** Every operator-scoped fact table
  added here carries `(operator_id, location_id)` from creation.
  Operator-leading B-tree indexes drive planner pushdown
  (CLAUDE.md / 9.0Σ.b item 4); CI lint enforces.

  3. **HP #7 server-side secrets.** `vendor_credentials` stores
  the access/refresh-token envelope encrypted with `pgcrypto`
  (`pgp_sym_encrypt`/`pgp_sym_decrypt`) using the symmetric key
  stored in Cloud Run env. Production-grade KMS rollout is a
  separate Production1 hardening lane, not part of Phase 8.0
  V1 lean cut 2. Plaintext tokens never appear in the column or
  in any read path; the Flutter clients never see them.

  4. **Wrapper-only RLS posture (Phase 9.0Σ.b item 4).** Every
  policy body calls the locked `STABLE LEAKPROOF PARALLEL SAFE`
  wrappers (`app_current_operator`, `app_current_location`).

  5. **Time guardrails (CLAUDE.md / 7.55 Rule 11).** UTC instants
  are stored as `TIMESTAMPTZ`; denormalized `business_date`
  `DATE` columns are computed at write from `location.timezone`
  + `location.business_day_rollover_hour` via the IANA converter
  in Dart. `TIMESTAMP WITHOUT TIME ZONE` is banned.

  6. **3-state machine for `connector_connection.status`.** V1
  lean cut: `connected` / `disconnected` / `error`. `connecting`
  and `degraded` are explicit non-goals.

  7. **V1 lean cut 2 (locked 2026-05-03,
  `memory/project_v1_lean_cut_2_2026_05_03.md`).** No KMS
  provider, no webhook signing-key rotation UI, no
  `parse_warnings`/`parse_partial` columns, no per-(operator,
  vendor) advisory lock on the OAuth cron, no 3-strike
  `email_outbox` emit (cron writes audit_logs + flips status to
  `error`), no SIGTERM graceful drain handler, no DLQ tile
  surfaced in observability, single `raw_payload` JSONB column
  with no per-month partitioning, no fixed-second
  test-connection SLA. The `disconnect_reason` enum carries
  only the four reasons that have a real-life trigger at V1.

  8. **Idempotent migration.** `if not exists` on every CREATE,
  `drop policy if exists` before `create policy`.

## `202605040100_phase_9_8_tos_versions.sql`

- **Applied:** 2026-05-04 01:00
- **Title:** phase 9 8 tos versions
- **Description:**

  Phase 9.8 — Inbound-vendor T&Cs schema (minimum two tables).

  Backs the click-through flow specified in
  `docs/phases/phase_9_8/phase_9_8_inbound_vendor_tcs_draft.md`. The
  draft asks for two tables:

  * `tos_versions`     — versioned legal text the operator agrees to.
  Scope-aware so the universal click-through
  (`inbound_vendor_universal`) and the
  per-vendor click-throughs
  (`inbound_vendor_<vendor_id>`) live in the
  same table.
  * `tos_acceptances`  — append-only acceptance log keyed by
  (operator_id, user_id, version_id) with the
  IP + UA captured at the moment of click.

  This slice (`11W.0` shell) only ships the schema so the click-through
  screen has a write target. The T&Cs versioning admin UI lives behind
  a later Phase 11A slice; this migration does not back-fill any
  versions and does not add admin grants beyond the standard
  `forge_admin` insert/select.

  Existing `public.tncs_acceptances` (Phase 9.0 auth foundation) stays
  in place — it tracks the legacy app-T&Cs acceptance shape (text
  version string only). The Phase 9.8 inbound-vendor flow needs the
  richer scope + version_id model the draft specifies, so we add a new
  table rather than evolve the legacy one. A future Phase 9.8 slice
  will reconcile the two; for `11W.0` we only need write targets.

  Hard rules carried verbatim from CLAUDE.md (Authority Order item 5):

  1. **RLS-Ready Schema (CLAUDE.md).** Operator-scoped fact tables
  include `(operator_id, location_id)` from creation. T&Cs
  acceptances are operator-scoped (no location dimension — T&Cs
  acceptance is operator-wide), so `(operator_id)` leads.
  `tos_versions` is corpus-scoped (operator-agnostic legal text)
  and stays unscoped at the row level — it carries no
  `operator_id` column; reads are public to authenticated roles.

  2. **OperatorScopedRepository is the primary defense; RLS is the
  backup.** This migration ships the secondary defense via
  wrapper-only RLS policies on `tos_acceptances`.

  3. **Wrapper-only RLS posture (Phase 9.0Σ.b item 4).** Every policy
  body calls the locked
  `STABLE LEAKPROOF PARALLEL SAFE` wrapper functions
  (`app_current_operator()`, `app_current_actor_user()`).

  4. **Tenant-leading B-tree indexes (CLAUDE.md / 9.0Σ.b item 4).**
  Every B-tree index on `tos_acceptances` leads with
  `operator_id` so the planner can fold the per-tenant policy
  into the index probe.

  5. **Append-only fact-table grants.** `service_role` and
  `forge_admin` get INSERT and SELECT on `tos_acceptances`;
  UPDATE/DELETE are explicitly REVOKEd. Acceptance is a legal
  record — it must never be silently mutated. Corrections land
  as a fresh acceptance row referencing a superseding version.

## `202605040200_phase_9_8_email_provider.sql`

- **Applied:** 2026-05-04 02:00
- **Title:** phase 9 8 email provider
- **Description:**

  Phase 9.8 — Email provider durable queue + delivery event log.

  Owns three tables and one pg_cron job:

  * `public.email_credentials` — single-row, F&F-platform-wide
  SendGrid API key. The plaintext is encrypted at rest with
  pgcrypto envelope on staging; production swaps in Cloud KMS
  when 8.0's KMS rollout lands. Mirrors the
  `provider_credentials` pattern (Phase 11A.4) but keeps the
  SendGrid key in its own table because the rotation contract is
  identical and the F&F platform-wide scope rules out the
  operator-scoped tables.

  * `public.email_outbox` — durable transactional queue. Producers
  enqueue rows in the same transaction as the business write
  (operator invite, password reset, vendor sync alert, etc.).
  The `email_outbox_dispatcher` (lib/services/email) drains
  pending rows on a 1-minute cadence, advances the status state
  machine, and stamps `provider_message_id` on success.

  * `public.email_event` — webhook delivery log. SendGrid event
  webhooks (delivered, opened, clicked, bounced, complaint,
  unsubscribe) land here so the admin "Test connection" flow
  can confirm a test email actually reached the recipient and
  so the dispatcher's 3-strike alert path has audit context.

  Hard rules carried from CLAUDE.md and the slice doc:
  1. RLS performance discipline — operator-scoped fact-table
  indexes lead with `(operator_id, …)`. `email_outbox` carries
  a partial index keyed on `operator_id` for operator-scoped
  rows (`operator_id IS NOT NULL`) and a system-only index for
  F&F-internal rows (`operator_id IS NULL`).
  2. RLS uses the wrapper functions from 9.0Σ.b
  (`public.app_current_operator()`); bare `current_setting()`
  is forbidden by the lint in `tool/rls_policy_lint.dart`.
  3. `TIMESTAMPTZ` everywhere; `TIMESTAMP WITHOUT TIME ZONE` is
  banned in operator-scoped tables.
  4. Per Hard Promise #7 — server-side keys only — the plaintext
  column is `bytea` and stores `pgp_sym_encrypt(plaintext,
  <env-injected key>)`. The migration does NOT hard-code the
  symmetric key; the proxy bootstrap reads it from
  `EMAIL_CREDENTIALS_ENVELOPE_KEY` (Cloud Run env / Secret
  Manager) at runtime and decrypts on read. Production swaps
  in Cloud KMS when 8.0's KMS rollout lands.
  5. The pg_cron tick is NOTIFY-only (matches the rollups pattern
  from `phase_9_0sigma_k_pg_cron_jobs.sql`). The Dart
  dispatcher subscribes to `email_outbox_tick` and drains the
  queue; the SQL function never claims rows itself.

  Live apply: lands on staging first; production cutover waits for
  DNS records on `mail.forgeflow.app` (DKIM, SPF, DMARC) and a
  production SendGrid key.

## `202605040300_phase_10a_2_dead_letter.sql`

- **Applied:** 2026-05-04 03:00
- **Title:** phase 10a 2 dead letter
- **Description:**

  Phase 10a.2 — event_outbox dead-letter table.

  Closes the only "queue can grow unbounded" gap in the Phase 10a
  bridge worker pipeline. Without a dead-letter, a row whose publish
  to Cloud Pub/Sub fails permanently (corrupt payload, gone topic,
  subscriber-side schema drift) is recycled forever by the lease /
  attempt_count retry path: the bridge's claim loop picks the row
  up every `claimReclaimAfter` window, the publish fails again,
  `attempt_count` increments, repeat. Q22 / item 33 in
  `phase_9_scalability_decisions_2026-04-27.md` calls this out
  explicitly — the contract requires a tunable attempt cap that
  moves runaway rows OUT of the live queue so the live queue stays
  drainable while operators triage the failures.

  Authority:
  * `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md` —
  Scope "Dead-letter" subsection.
  * `docs/contracts/event_outbox_contract.md` — "Worker
  Responsibilities" `Dead-letter rows whose attempt_count
  exceeds the tunable cap (Phase 10a defines the value;
  expected ≥ 5) by writing the row to an
  `event_outbox_dead_letter` table and removing it from
  `event_outbox`. Dead-letter handling is alarmed.`

  Hard rules carried from CLAUDE.md and the 4-27 lock:

  1. RLS performance discipline — the dead-letter index leads with
  `(operator_id, dead_lettered_at desc)` so the admin tile's
  "depth + last 10 rows for this operator" query folds into the
  tenant-leading index probe. The `tool/index_leading_column_lint`
  gate enforces this on every B-tree index that touches the
  table.
  2. RLS uses the wrapper functions from 9.0Σ.b
  (`public.app_current_operator()`); bare `current_setting()`
  is forbidden by the lint in `tool/rls_policy_lint.dart`.
  3. `TIMESTAMPTZ` everywhere; `TIMESTAMP WITHOUT TIME ZONE` is
  banned in operator-scoped tables.
  4. The MOVE that drops a row from `event_outbox` and inserts the
  row into `event_outbox_dead_letter` MUST be transactional —
  either both writes commit or neither does. The bridge worker
  runs the move via a single `WITH dead AS (DELETE … RETURNING *)
  INSERT … SELECT …` CTE inside a `runInTenantContext` so RLS
  admits both writes and the operator's tenant transaction
  bounds the atomicity guarantee.
  5. `pg_partman` partitions the table by `dead_lettered_at_month`
  with 90-day retention. Rows whose dead-letter window has
  passed are dropped via `DETACH` + `DROP` partition-cadence;
  operators triage live rows during the 90-day window.

  Phase 10a.2 worker contract (locked here so the bridge worker has
  a stable schema):
  * The bridge claim loop partitions claimed rows by `attempt_count
  > EVENT_OUTBOX_DLQ_CAP`. Rows past the cap MOVE here in a
  single transaction; the live publish loop continues unchanged.
  * `dead_lettered_at` is server-set at MOVE time; the bridge
  does NOT pass a producer-supplied timestamp.
  * `last_error` carries the most-recent failure string for
  operator triage. `dead_letter_reason` carries a short
  machine-readable code (`'attempt_cap_exceeded'`, `'forced_dlq'`)
  so the admin tile can group by reason without parsing
  free-form error text.
  * No auto-replay job at V1 — operators trigger replay manually
  after triage. Replay UX is a post-V1 lane.

## `202605040400_phase_8_0_lifecycle_add_vendor_lifecycle_notification.sql`

- **Applied:** 2026-05-04 04:00
- **Title:** phase 8 0 lifecycle add vendor lifecycle notification
- **Description:**

  Phase 8.0.lifecycle — vendor_lifecycle_notification table.

  Backs the Operator Web vendor picker "Notify me when ready" capture
  on `documented` / `sandbox_verified` vendor rows per
  `docs/phases/phase_8/vendor_connections_admin_surface.md`
  ("Backend UX exposure" → "Notify me when ready"). The fan-out cron
  + email template wiring lands in the `9.8.email` follow-up; this
  slice ships only the table the picker writes into.

  Hard rules carried verbatim from CLAUDE.md / phase docs:

  1. **HP #4 RLS-Ready Schema.** The table carries `operator_id`
  from creation; the primary B-tree index leads with
  `operator_id` (CLAUDE.md / 9.0Σ.b item 4); CI lint enforces.
  Operator-scoped only — no `location_id` column. Notifications
  are operator-level subscriptions ("when Toast is ready, email
  this operator's admin"), not per-(operator, location) facts.

  2. **Wrapper-only RLS posture (Phase 9.0Σ.b item 4 +
  `docs/contracts/hardening_rls_and_repository_pattern_contract.md`).**
  Every policy body calls the locked
  `STABLE LEAKPROOF PARALLEL SAFE` wrappers
  (`app_current_operator`); bare `current_setting()` is forbidden.

  3. **Time guardrail (CLAUDE.md / 7.55 Rule 11).** UTC instants
  stored as `TIMESTAMPTZ`; the bare-timestamp column type is
  banned in operator-scoped tables.

  4. **Idempotent migration.** `if not exists` on every CREATE,
  `drop policy if exists` before `create policy`.

## `202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql`

- **Applied:** 2026-05-04 19:30
- **Title:** phase 11A operator location admin forge admin grants
- **Description:**

  Phase 11A.1 follow-up -- operator/location admin runtime grants.

  The F&F admin console runs operator, location, and operator-admin grant
  writes through TenantTransactionWrapper.runAsSystem, which sets the
  transaction role to forge_admin. BYPASSRLS skips tenant row policies, but it
  does not grant table privileges, so live staging mutations fail before the
  repository SQL can run unless forge_admin has explicit DML on these tables.

## `202605050000_phase_8_data_accuracy_settings.sql`

- **Applied:** 2026-05-05 00:00
- **Title:** phase 8 data accuracy settings
- **Description:**

  Phase 8 spine-bridge Lane .A — data accuracy settings + F&F polling tier
  assignment.

  Authority:
  docs/contracts/data_accuracy_settings_contract.md "Schema" section
  (verbatim).

  Two operator-scoped tables:

  1. `public.data_accuracy_settings` — per-(operator, location) operator
  controlled overrides for canonical-fact resolution. Carries:
  * Covers source per daypart (vendor / forecast / manual)
  * Sparse manual covers entries jsonb keyed by business_date+daypart
  * Wage source binary (vendor / manual_mix)
  Per the F&F-controlled tier model (REVERSED 2026-05-05) this row
  carries NO polling-cadence-override fields. Cadence is set by F&F
  admin via `forge_flow_polling_tier_assignment` (table 2 below).

  2. `public.forge_flow_polling_tier_assignment` — per-(operator,
  location) tier row + per-vendor cadence JSONB + F&F price + internal
  cost basis. F&F admin controls; operator never reads directly. The
  currently-effective row is identified by `effective_until is null`;
  assignment history is preserved chronologically via the
  `effective_at desc` index. `forge_admin` writes; `service_role`
  read-only.

  Hard rules carried verbatim from CLAUDE.md / phase docs:

  * **HP #4 RLS-Ready Schema.** Both tables carry (operator_id,
  location_id) from creation; per-tenant RLS policy enabled at table
  creation time; operator-leading B-tree index drives planner
  pushdown.
  * **Wrapper-only RLS posture (Phase 9.0Σ.b item 4).** Every policy
  body calls `app_current_operator()` / `app_current_location()`. No
  bare `current_setting(...)` reads.
  * **Time guardrails (CLAUDE.md / 7.55 Rule 11).** All temporal
  columns are `TIMESTAMPTZ`. No `TIMESTAMP WITHOUT TIME ZONE`.
  * **Idempotent migration.** `if not exists` on every CREATE,
  `drop policy if exists` before `create policy`. Re-applying the
  migration is a no-op.

  V1 lean cut 2 banned items absent: no KMS, no parse_warnings /
  parse_partial, no advisory locks, no email_outbox emit, no pg_partman,
  no SIGTERM handler.

## `202605050100_phase_8_0a_polling_event_kinds.sql`

- **Applied:** 2026-05-05 01:00
- **Title:** phase 8 0a polling event kinds
- **Description:**

  Phase 8 spine-bridge `8.spine-bridge.0a` — extend
  `connector_sync_log.event_kind` CHECK constraint to admit the four
  event kinds the polling cadence resolver + its dispatch hook emit.

  Authority:
  * docs/contracts/data_accuracy_settings_contract.md "Polling
  cadence resolution" — F&F-controlled tier model (REVERSED
  2026-05-05).
  * docs/contracts/integration_spine_architecture_contract.md sub-
  lane `.0a`.

  New event kinds:
  * `tier_assignment_missing` — resolver invoked with a null tier
  row for (operator, location); fell back to the standard-tier
  presets. F&F Ops Console (`8.spine-bridge.C`) surfaces this so
  operations sees which operator-locations still need a tier
  assignment after onboarding.
  * `cadence_clamped` — resolver received an override outside
  `[vendor_minimum, framework_maximum]` (3600s) and clamped it.
  The audit row carries the requested + clamped values + the
  bound name (`vendor_minimum` / `framework_maximum`).
  * `custom_tier_vendor_unset` — tier_key='custom' assigned for the
  (operator, location) but the per-vendor JSONB has no entry for
  this vendor; resolver fell back to the vendor minimum. Tells
  F&F admin which vendor cadences still need explicit values for
  a custom-tier operator.
  * `tier_assignment_lookup_failed` — the dispatch hook's tier-
  assignment lookup threw (DB connection lost, timeout, etc.).
  The poll proceeds with the default cadence; the failure is
  surfaced separately so it does not get conflated with vendor
  poll errors.

  This migration also closes a latent gap from Lane `.0`: the
  dispatcher was already emitting `vendor_not_registered` (when a
  `connector_connection.vendor_id` references a retired or drifted
  vendor key) but that value was missing from the original CHECK
  list. Lane `.0`'s in-memory test fakes do not enforce CHECK
  constraints, so the gap was invisible until a Postgres-backed sink
  ran the path.

  The CHECK constraint is dropped + recreated in a single transaction
  when `connector_sync_log` exists. Some staging databases may carry
  the Data Accuracy admin tables before the broader integration
  framework table has been applied; in that partial-schema case this
  migration is a no-op instead of blocking the independent admin
  surface rollout. When the integration framework migration is present,
  the constraint is still repaired in place. No rows in
  `connector_sync_log` carry the new values yet, so the recreate is a
  structural-only change — no data migration needed.

## `202605050200_phase_10a_3_event_outbox_retention.sql`

- **Applied:** 2026-05-05 02:00
- **Title:** phase 10a 3 event outbox retention
- **Description:**

  Phase 10a.3 — event_outbox retention sweep.

  Closes the only "delivered rows accumulate forever" gap in the
  Phase 10a bridge worker pipeline. Once Pub/Sub acks a publish, the
  bridge stamps `delivered_at = now()` and the row drops out of the
  claim predicate (Phase 9.0Σ.e migration / contract). But the row
  itself stays in `public.event_outbox` indefinitely, so a busy
  operator's outbox would grow unboundedly even though nothing reads
  delivered rows.

  This slice adds:

  * A daily SQL function `public.event_outbox_retention_sweep()`
  that DELETEs rows whose `delivered_at IS NOT NULL AND
  delivered_at < now() - INTERVAL '7 days'`. The sweep runs in
  `forge_admin BYPASSRLS` scope (cron context has no tenant) so
  the per-tenant policies do not block the cross-operator delete.

  * A `pg_cron` schedule that fires the function once a day at
  03:00 UTC. The schedule registration is idempotent
  (unschedule-then-reschedule, mirroring the rollups + email
  dispatcher migrations from Phase 9.0Σ.k / 9.8 — `cron.schedule`
  raises `unique_violation` on a second call with the same
  `jobname`, so the DO block removes any prior entry first).

  * A partial index on `delivered_at WHERE delivered_at IS NOT
  NULL` so the sweep walks delivered rows by date without sharing
  the tenant-leading claim index. The contract
  (`docs/contracts/event_outbox_contract.md` "Retention" section)
  names this index explicitly: "the delivered_at column lets the
  sweep walk by date without a separate index — a partial index
  (WHERE delivered_at IS NOT NULL) lands alongside the sweep".

  Hard rules carried from CLAUDE.md and the contract:

  1. The sweep MUST NOT touch un-delivered rows (`delivered_at IS
  NULL`). The contract is explicit: "Un-delivered rows: never
  auto-deleted. The yellow/red tripwires alert before the table
  grows past safe size; an operator-specific runbook walks
  through manual claim or producer pause if needed." The
  retention test (`test/services/realtime/event_outbox_retention_sweep_test.dart`)
  pins this invariant against the literal SQL predicate.

  2. The 7-day window is the contract value. Changing it requires a
  paired update to `docs/contracts/event_outbox_contract.md`
  "Retention" section.

  3. The partial index MUST be tenant-leading per CLAUDE.md "RLS
  performance discipline" — operator-scoped fact-table indexes
  lead with `operator_id`. The sweep itself runs cross-operator
  (forge_admin BYPASSRLS), but per-operator triage queries that
  filter on `delivered_at` need the operator-leading shape so
  the per-tenant RLS policy folds into the index probe.

  4. The cron job uses the same NOTIFY-only / forge_admin pattern as
  the rollups + email dispatcher cron jobs. The retention
  function differs from those in that it ALSO does the work
  itself — there is no separate Dart worker that needs the
  lease to advance. A cross-tenant DELETE is purely a database
  operation; no producer state to keep in lockstep.

  5. RLS uses the wrapper function `public.app_current_operator()`
  from 9.0Σ.b only where it appears (the function does not need
  to set a tenant context because it runs as `forge_admin`).

  6. `TIMESTAMPTZ` everywhere — the existing `delivered_at` column
  is `timestamptz` per Phase 9.0Σ.e.

  Live apply status: lands on staging first; production cutover after
  the staging tick fires once and the proxy `/health`
  `event_outbox_retention_backlog` metric reports green.

  Authority:
  * `docs/contracts/event_outbox_contract.md` — "Retention" section
  locks the 7-day window + un-delivered-rows-stay invariant.
  * `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md` —
  scope "Retention sweep" subsection: "Cloud Run scheduled job
  (or `pg_cron`) deletes rows where `delivered_at IS NOT NULL
  AND delivered_at < now() - INTERVAL '7 days'`. Un-delivered
  rows are never auto-deleted".

## `202605050300_phase_10a_4_event_outbox_publish_metrics.sql`

- **Applied:** 2026-05-05 03:00
- **Title:** phase 10a 4 event outbox publish metrics
- **Description:**

  Phase 10a.4 — event_outbox publish-error-rate metrics table.

  Closes the production-data gap behind the
  `event_outbox_publish_error_rate` proxy `/health` producer
  (`tool/advisor_proxy/health_producers/outbox_producers.dart`). The
  producer's SQL has been live since 10a.0 and reads:

  select coalesce(sum(failed_publish_count), 0)::bigint as failed,
  coalesce(sum(attempted_publish_count), 0)::bigint as attempted
  from event_outbox_publish_metrics
  where window_start > now() - interval '5 minutes'

  but no migration ever created `event_outbox_publish_metrics` and no
  writer ever populated it, so the producer always projected to
  `producer_error` / `unknown` in production. This slice creates the
  table, instruments the bridge worker to UPSERT one-minute buckets
  through the admin pool, and adds a daily retention sweep so the
  bookkeeping table cannot grow unbounded.

  Authority:
  * `docs/contracts/event_outbox_contract.md` "Foundation vs. Bridge
  Boundary" — yellow at 1 % publish error rate / red at "repeated
  publish failures". `outbox_producers.dart` pins the concrete red
  line at 5 % over the rolling 5-minute window.
  * `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md`
  "Yellow/red tripwires" subsection — surface in F&F Dev/Admin
  Health UX, not just logs.
  * Decision 33 in `phase_9_scalability_decisions_2026-04-27.md`
  locks the threshold values.

  Hard rules carried from CLAUDE.md and the contract:

  1. This is a platform-wide bridge-bookkeeping table, NOT a
  per-tenant fact table — same posture as
  `event_outbox_dead_letter`'s cross-operator depth aggregate
  (proxy `/health` envelope's "no tenant identifiers" rule). The
  table therefore has no `operator_id` column and no per-tenant
  RLS policy. The bridge writer runs through `runAsSystem` on the
  admin pool; the proxy `/health` producer reads through the same
  admin pool. Tenants never read or write this table directly.
  2. RLS is OFF on the table because there is no per-tenant
  predicate to enforce; access is gated entirely through the
  grants below (forge_admin only).
  3. `TIMESTAMPTZ` for `window_start` and `updated_at` per
  CLAUDE.md "Time Guardrails".
  4. `attempted_publish_count` and `failed_publish_count` are
  monotonically increasing per bucket; the bridge UPSERTs deltas
  so a slow flush followed by a fast flush in the same minute
  bucket sums correctly.
  5. Retention is via `pg_cron` daily DELETE — same pattern as the
  10a.3 event_outbox retention sweep. Rows older than 1 hour are
  removed; the producer reads only the last 5 minutes, so 1
  hour is plenty of headroom for clock skew or a delayed cron
  run without unbounded growth.

  Live apply status: lands on staging first; production cutover after
  the proxy `/health` `event_outbox_publish_error_rate` metric reports
  a non-`unknown` value (proves the bridge is writing buckets).

## `202605050400_phase_10a_5_subscription_watermark.sql`

- **Applied:** 2026-05-05 04:00
- **Title:** phase 10a 5 subscription watermark
- **Description:**

  Phase 10a.5 — realtime subscription watermark.

  THIS FILE IS A SQLITE-ONLY SCHEMA REGISTRATION PLACEHOLDER.
  It exists so the proxy's migration catalog
  (`tool/advisor_proxy/main.dart::loadProxyMigrationFilenames` →
  `recordProxyStartupMigrations`) records the slice in
  `public.proxy_migrations_applied` for cross-environment drift
  accounting, but it INTENTIONALLY contains no Postgres DDL.

  The actual table lives on the per-device SQLite cache and is
  created by the `_migrateToV26` helper in
  `lib/infrastructure/persistence/sqlite/sqlite_database_migrations.dart`
  (and on fresh installs by `_createAllTables` in
  `sqlite_database_schema.dart`). V1 watermark is per-device only;
  cross-device sync is Phase 10b. The realtime subscription
  (`lib/services/realtime/realtime_subscription.dart`) writes the
  per-(operator_id, topic) cursor inside the same transaction that
  surfaces the event to the UI; on reconnect, it picks the freshest
  cursor for the operator and forwards it as `?last_event_id=<uuid>`
  on the WebSocket upgrade URI so the route's
  `RealtimeReplayResolver` can replay events missed during the
  disconnect window (default 5 minutes).

  Authority:
  * docs/contracts/event_outbox_contract.md — `event_id` for
  consumer dedupe, `occurred_at` for ordering.
  * docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md
  "WebSocket lifecycle" — replay window default 5 min.

  Hard rules carried from CLAUDE.md and the contract:

  1. Per-device only. The watermark MUST NOT live in Postgres
  until Phase 10b promotes it to cross-device. A Postgres
  column for this in V1 would create a per-device write
  hotspot the contract has not yet sized for.

  2. Operator scoping is on the primary key. Two different
  operators signing in on the same device get separate rows;
  the realtime subscription's `setTenantContext` hydrates only
  the rows whose `operator_id` matches the active tenant.

  3. Empty Postgres effect. This migration is a no-op against the
  Postgres pool; the proxy's startup registry writer records
  the filename without running any DDL. The migration drift
  scanner sees the file in `db/migrations/`; the schema
  contract verifier (`AdminProxySchemaContractVerifier`) does
  NOT reference this slice's table because it does not exist
  in Postgres.

## `202605050400_phase_8_business_date_denorm.sql`

- **Applied:** 2026-05-05 04:00
- **Title:** phase 8 business date denorm
- **Description:**

  Phase 8 — Denormalized business_date on integration framework tables.

  Authority:
  * docs/contracts/phase_7_55_time_boundary_contract.md Rule 11
  (Storage convention for operator-scoped fact tables) —
  "denormalized `business_date` `DATE` column lives alongside the
  source-truth `TIMESTAMPTZ` ... write-once — never recomputed at
  read."
  * docs/contracts/integration_spine_architecture_contract.md —
  business_date denormalized at write via IANA converter.
  * CLAUDE.md — TIMESTAMPTZ + business_date discipline; every
  operator-scoped fact-table B-tree index leads with operator_id.

  Three Phase 8 integration framework tables carry fact-bearing time
  data and need denormalized `business_date` columns:

  | Table                          | Source-truth timestamp |
  | public.connector_sync_log      | occurred_at TIMESTAMPTZ |
  | public.inbound_webhook_dead_letter | occurred_at TIMESTAMPTZ |
  | public.sanity_log              | detected_at TIMESTAMPTZ |

  Five framework tables stay business_date-free:

  * vendor_credentials (credential metadata)
  * connector_connection (config)
  * connector_sync_watermark (point-in-time sync markers)
  * inbound_webhook_idempotency (24h TTL dedupe)
  * demo_mode_state (singleton)

  Hard rules:

  1. **Additive-safe.** Nullable column → backfill in bounded passes
  → SET NOT NULL. No long ACCESS EXCLUSIVE locks; backfill loops
  with LIMIT 50000 per pass.

  2. **Operator-leading indexes.** Every new B-tree leads with
  `operator_id` (CLAUDE.md / 9.0Σ.b item 4); the
  `tool/index_leading_column_lint.dart` CI gate enforces.

  3. **Defense in depth via BEFORE INSERT trigger.** The existing
  Wave-1 sinks
  (`lib/infrastructure/persistence/postgres/{libro,oracle_micros_simphony,quickbooks_time}_postgres_sink.dart`)
  insert into `connector_sync_log` without setting
  `business_date`. The trigger computes it from the row's
  source-truth TIMESTAMPTZ via the location's IANA timezone
  AND `business_day_rollover_hour` (mirrors
  `lib/services/integration/iana_timezone_converter.dart`
  `toBusinessDate`) whenever NEW.business_date IS NULL.
  Future spine-bridge sink updates can carry an explicit
  business_date if computed Dart-side; the trigger only fires
  on NULL.

  4. **SECURITY DEFINER + OWNED BY forge_admin.** The trigger reads
  `public.locations` (RLS-enabled) to project the row's
  timestamp through the per-location IANA zone. Owning the
  function as `forge_admin` (BYPASSRLS) lets the projection
  succeed regardless of the inserter's tenant context. Function
  grants are tightened so only the trigger context invokes it.

  5. **Honest UTC fallback.** `locations.timezone` is declared NOT
  NULL on the table, but a defensive COALESCE keeps the trigger
  and backfill from raising on edge fixtures (tests inserting a
  stub location with empty-string tz). The fallback emits
  `RAISE NOTICE` so operators can spot drift in staging logs.
  Honest-fallback rule: do not silently drop the row, do not
  block the write — denormalize against UTC and surface the
  degradation.

  6. **Idempotent migration.** `if not exists` on every additive
  step; the SET NOT NULL only fires once `business_date IS NULL`
  is empty (idempotent re-apply is a no-op).

## `202605051000_phase_10a_3_outbox_retention_sweep.sql`

- **Applied:** 2026-05-05 10:00
- **Title:** phase 10a 3 outbox retention sweep
- **Description:**

  Phase 10a.3 — bounded retention sweep + sweep-history log.

  Layered slice on top of the existing 10a.3 retention work
  (`db/migrations/202605050200_phase_10a_3_event_outbox_retention.sql`).
  The earlier migration shipped an unbounded `event_outbox_retention_sweep()`
  function and a daily 09:00 UTC pg_cron schedule. Two operational gaps
  remained that this slice closes:

  1. **Unbounded DELETE locks.** A single sweep call does the entire
  DELETE in one statement. On a busy operator the row count past
  the 7-day window can climb into the millions during a Pub/Sub
  regional outage; one statement holding a row-level lock on
  every match starves the bridge claim path. This slice adds
  `public.run_event_outbox_retention_sweep()` which caps the
  DELETE at 10000 rows per call. Multiple cron passes drain the
  backlog without long locks; the cap_hit signal in the log
  table tells operators when extra passes are pending.

  2. **No sweep-history evidence.** With nothing recorded across
  sweep runs, the proxy `/health` envelope had no way to tell
  "sweep is healthy and just ran" from "sweep has been broken
  for a week". The existing `event_outbox_retention_backlog`
  producer counts delivered rows past the 7-day window, but it
  cannot distinguish "1000 rows that just landed past the window
  because operator volume spiked" from "1000 rows because the
  sweep stopped firing three days ago". The new
  `event_outbox_retention_sweep_log` table records one row per
  cron pass; the new `event_outbox_retention_lag_hours`
  producer reads `now() - max(swept_at)` so a stale lag is
  visible immediately.

  The earlier `event_outbox_retention_sweep()` function and its
  09:00 UTC schedule are intentionally NOT removed. The new
  `run_event_outbox_retention_sweep()` runs at 03:00 UTC and is
  the bounded path; the older function stays as the legacy
  belt-and-braces sweep for one release cycle so the 03:00 cron
  failing does not silently strand delivered rows. The legacy job
  retires in a follow-up migration after operators confirm the
  bounded sweep is keeping the table drained.

  Authority:
  * `docs/contracts/event_outbox_contract.md` — "Retention sweep"
  sub-bullet locks the 7-day delivered-rows window and the
  un-delivered-rows-stay invariant. The bounded-DELETE shape is
  an implementation detail that respects both invariants.
  * `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md` —
  Scope "Retention sweep" subsection.
  * `docs/contracts/phase_7_55_time_boundary_contract.md` —
  TIMESTAMPTZ everywhere; the new log table follows the rule.

  Hard rules carried from CLAUDE.md and the contract:

  1. The bounded sweep MUST NOT touch un-delivered rows
  (`delivered_at IS NULL`). The sub-select that picks LIMIT
  10000 victims pins both predicates from the contract:
  `delivered_at IS NOT NULL AND delivered_at < now() -
  INTERVAL '7 days'`.

  2. The 7-day window stays the contract literal. Changing it
  requires a paired update to
  `docs/contracts/event_outbox_contract.md` "Retention".

  3. The new log table carries an always-NULL `operator_id`
  column so the tenant-leading index discipline lands cleanly
  even though the sweep is platform-wide. Per CLAUDE.md "RLS
  performance discipline" + `tool/index_leading_column_lint.dart`
  every B-tree index on a table that declares `operator_id`
  MUST lead with it. The column is documented as never-written
  so a future "wait, why is this NULL?" reviewer has the
  answer in the schema.

  4. The log table sets RLS off (no per-tenant rows to gate);
  access is gated entirely through grants. Same posture as
  `event_outbox_publish_metrics` (10a.4). The proxy `/health`
  producer reads through the admin pool; F&F engineers triage
  via `forge_admin` BYPASSRLS SQL.

  5. SECURITY DEFINER + forge_admin owner so the cross-operator
  DELETE runs without a tenant context. `set search_path =
  public, pg_catalog` locks the function against schema
  injection.

  6. The pg_cron registration is idempotent (unschedule-then-
  reschedule). `cron.schedule(jobname, …)` raises
  `unique_violation` on a duplicate jobname; the DO block
  removes any prior entry by jobid first. The same NOTICE-and-
  return guard from the rollups + email-dispatcher migrations
  handles the Azure split-database case where pg_cron metadata
  lives in `cron.database_name`.

  Live apply status: lands on staging first; production cutover after
  the staging tick fires once and the `event_outbox_retention_lag_hours`
  metric flips from `unknown` (sweep_never_ran sentinel) to a
  numeric value below 24 hours.

## `202605060000_mobile_push_notifications.sql`

- **Applied:** 2026-05-06 00:00
- **Title:** mobile push notifications
- **Description:**

  Mobile OS push notification support.

  Adds operator/user-scoped device token storage plus a channel-specific
  durable push outbox. Business notification creation still goes through
  public.event_outbox; this table records the mobile-delivery sidecar
  state so the event_outbox single delivered_at marker is not used as a
  multi-consumer acknowledgement.

  Plain device tokens are encrypted by the server-side repository with
  pgp_sym_encrypt(..., MOBILE_PUSH_TOKEN_ENVELOPE_KEY). The client never
  receives server credentials or Firebase service keys, and payload rows
  carry only notification display/data fields, not device tokens.

## `202605060000_phase_business_timing_live_schema.sql`

- **Applied:** 2026-05-06 00:00
- **Title:** phase business timing live schema
- **Description:**

  Business Timing Live - canonical timing profiles + open shift snapshots.

  This slice creates the server-side source of truth for business timing:

  * business_timing_profiles: scoped, effective-dated profile rows.
  * business_timing_service_periods: optional whole-set service-period
  overrides for a profile.
  * business_timing_audit_events: append-only audit ledger for timing writes.
  * open_shift_snapshots: provisional live/projected Shift read model rows.

  RLS posture:
  * timing profiles, service periods, and audit rows are operator-scoped.
  Location resolution must read inherited operator and org-unit profiles.
  * open_shift_snapshots is an operator+location fact table.
  * all policies use 9.0Sigma.b wrapper functions, never bare
  current_setting().

  Time posture:
  * locations.timezone remains the authoritative IANA timezone.
  * timing profiles carry local business-day start and week-start rules only.
  * operator-scoped fact timestamps are timestamptz; local clock settings are
  stored as time-of-day values, not timezone-naive timestamps.

## `202605061100_phase_11A_14_admin_users_reset_mfa_factors_key.sql`

- **Applied:** 2026-05-06 11:00
- **Title:** phase 11A 14 admin users reset mfa factors key
- **Description:**

  Phase 11A.14 — additive permission-key catalog row for the F&F
  admin "Reset member MFA" support action.

  The 11A.14 Audited support actions surface ships an Actions panel
  that exposes three F&F-admin support escalations: reset member MFA,
  initiate password reset, and issue paired-approval erasure. The
  second and third actions are gated on existing catalog keys
  (`admin.users.reset_password`, `admin.users.erase_pii`); the first
  needs a new key — `admin.users.reset_mfa_factors` — that the 9.0
  foundation seed never carried because the admin-side reset-MFA
  escalation path did not exist at 9.0 close.

  The parity contract
  (`docs/contracts/team_roles_hierarchy_console_parity_contract.md`)
  pins the new key in two places: § Security (line 161) and the
  Permission gate cheat sheet (line 208). The contract Anti-pattern
  "If a slice prompt needs a new route, the parity contract is
  incomplete — STOP and update this contract first" does NOT apply
  here because the new entity is a permission key and the contract
  already names it; this slice closes the catalog/code/migration
  keep-in-sync rule (catalog § "Keep in sync" lines 24–37).

  Hard rules carried from CLAUDE.md and the catalog contract:

  * Permission keys are app-defined and frozen at code level. The
  catalog seeded here mirrors `lib/auth/permission_keys.dart` and
  `docs/contracts/auth_permission_key_catalog.md`. Operators may
  not invent new keys at runtime.

  * MFA-required keys carry `requires_mfa = true` in the seed and
  in `PermissionKeys.requiresMfa`. The runtime resolver refuses
  to admit such a key unless the caller's session has a fresh
  `auth_time` MFA assertion. Reset-MFA is the highest-trust
  account-recovery action; mirror the posture used for
  `admin.users.erase_pii` / `admin.roles.edit_seeded`.

  * The migration is additive only — single INSERT into
  `permission_keys` with `on conflict (key) do nothing`, plus an
  idempotent default role-grant insert for the two seeded F&F
  internal roles (`super_admin`, `ff_support`). Re-applying the
  migration is a no-op.

  * No live database mutation. Live apply on staging + Production1
  is queued under the Phase 9 live-mutation gate.

## `202605061500_hardening_phase_8_email_index_leading_column_rekey.sql`

- **Applied:** 2026-05-06 15:00
- **Title:** hardening phase 8 email index leading column rekey
- **Description:**

  Hardening: re-key 5 fact-table B-tree indexes that lead with a
  non-operator_id column so the operator-leading discipline (CLAUDE.md
  "RLS-Ready Schema" section) is enforced repo-wide. Per-tenant index
  probes degrade into per-row filters when the leading column is not
  operator_id; the lint at tool/index_leading_column_lint.dart fails
  the build until each violation is rekeyed.

  Affected indexes (all 5 originate from Phase 8 / Phase 9.8 V1
  migrations that landed before the lint was wired up):

  1. vendor_credentials_expiring_idx
  (db/migrations/202605040000_phase_8_0_integration_framework.sql:127)
  Original: (token_expires_at) WHERE is_active AND token_expires_at IS NOT NULL.
  Rekey:    (operator_id, token_expires_at) preserving the same WHERE.

  2. connector_sync_watermark_unique_idx (UNIQUE)
  (db/migrations/202605040000_phase_8_0_integration_framework.sql:234)
  Original: UNIQUE (connection_id, resource).
  Rekey:    UNIQUE (operator_id, connection_id, resource).
  `connection_id` is itself globally unique (PK on
  connector_connection), so prepending operator_id preserves the
  uniqueness contract without weakening it.

  3. connector_sync_log_connection_recent_idx
  (db/migrations/202605040000_phase_8_0_integration_framework.sql:292)
  Original: (connection_id, occurred_at desc).
  Rekey:    (operator_id, connection_id, occurred_at desc).

  4. inbound_webhook_idempotency_unique_idx (UNIQUE)
  (db/migrations/202605040000_phase_8_0_integration_framework.sql:334)
  Original: UNIQUE (vendor_id, operator_id, vendor_event_id).
  Rekey:    UNIQUE (operator_id, vendor_id, vendor_event_id).
  Same column set, operator_id promoted to leading position. The
  uniqueness contract is identical because UNIQUE constraints are
  defined by the set of columns, not their order.

  5. email_outbox_provider_message_id_idx
  (db/migrations/202605040200_phase_9_8_email_provider.sql:197)
  Original: (provider_message_id) WHERE provider_message_id IS NOT NULL.
  Rekey:    (operator_id, provider_message_id) WHERE provider_message_id IS NOT NULL.
  The webhook handler that resolves provider_message_id back to
  an email_outbox row already runs under runAsSystem (BYPASSRLS)
  for system rows; for operator-scoped rows the operator_id
  leading column matches the per-tenant claim path.

  ─── ORDERING is load-bearing ────────────────────────────────────────
  CONCURRENTLY index ops cannot run inside an enclosing BEGIN/COMMIT
  block. Each statement below runs in its own implicit per-statement
  transaction; live writers see neither a long lock nor a window in
  which the table has no usable index for the relevant access pattern.

  Re-applying is a no-op: every IF EXISTS / IF NOT EXISTS guard makes
  subsequent runs neither error nor duplicate work. Pattern reference:
  db/migrations/202605021800_hardening_auth_login_attempts_index_rekey.sql
  (single-table version) and
  db/migrations/202605010001_phase_9_b4_role_audit_log_operator_id.sql
  (multi-index CONCURRENTLY swap).

  The original migrations' CREATE INDEX text is exempted in
  tool/index_leading_column_lint.dart `_defaultExemptions` so the
  shipped-migration immutability rule and the lint coexist (see the
  auth_login_attempts precedent, lines 107-120 of that tool).

  ─── 1. vendor_credentials_expiring_idx ──────────────────────────────

## `202605061600_phase_11W_5_team_audit_log_export_key.sql`

- **Applied:** 2026-05-06 16:00
- **Title:** phase 11W 5 team audit log export key
- **Description:**

  Phase 11W.5 — additive permission-key catalog row for the operator-
  facing Audit Log CSV export action.

  The 11W.5 Operator Web Audit Log screen
  (`lib/operator_web/screens/audit_log_screen.dart`) gates its CSV
  export action on `team.audit_log.export`, but the 9.0a foundation
  seed only carried `team.audit_log.view` (read access). The export
  key was referenced by the screen as `kAuditLogExportPermissionKey`
  but never lived in `permission_keys.dart`, the seed migrations, or
  the catalog contract — a phantom gate that always fell through to
  the role-tier fallback. This slice closes the catalog/code/
  migration keep-in-sync rule (catalog § "Keep in sync") so a real
  session permission set can carry the key and the export action
  gets honest authorization.

  Hard rules carried from CLAUDE.md and the catalog contract:

  * Permission keys are app-defined and frozen at code level. The
  row seeded here mirrors `lib/auth/permission_keys.dart` and
  `docs/contracts/auth_permission_key_catalog.md`.

  * No MFA gate on `team.*` keys at launch (locked decision in the
  catalog contract § team.*); export is admin-tier responsibility
  but not high-trust-recovery. `requires_mfa = false` mirrors the
  other team.* rows.

  * Default grants seat the key on `operator_owner` AND
  `operator_admin` only. Manager-tier and below do NOT receive
  the export grant by default — pulling a full audit trail to
  CSV is a senior-role action per the parity contract
  (audit log § Permission gate cheat sheet). Operators can mint
  custom roles that grant the key via the 9.6 admin endpoints.

  * Migration is additive only — single INSERT into
  `permission_keys` with `on conflict (key) do nothing`, plus
  idempotent role-grant inserts. Re-applying the migration is a
  no-op.

  * No live database mutation. Live apply on staging + Production1
  is queued under the Phase 9 live-mutation gate.

## `202605061650_phase_8_legacy_fact_tables_postgres_create.sql`

- **Applied:** 2026-05-06 16:50
- **Title:** phase 8 legacy fact tables postgres create
- **Description:**

  Wave 2 Lane B B-W1 — Phase 8 base-schema migration for the four
  legacy fact tables (`shift_records`, `cover_facts`, `labor_punches`,
  `reservation_facts`).

  Authority:
  * docs/POST_HARDENING_FOLLOWUPS.md "Wave bugs surfaced 2026-05-13 by
  local apply" W-1 — the bug this migration fixes.
  * docs/contracts/hardening_rls_and_repository_pattern_contract.md —
  operator-scoped fact tables carry (operator_id, location_id) from
  creation, RLS policy is wrapper-only via
  `app_current_operator()` / `app_current_location()`, B-tree
  indexes lead with `operator_id`.
  * docs/contracts/phase_7_55_time_boundary_contract.md — timestamps
  are TIMESTAMPTZ (UTC); each fact table carries a denormalized
  `business_date DATE NOT NULL` column; `TIMESTAMP WITHOUT TIME
  ZONE` is banned.
  * CLAUDE.md "Hard Promises" HP #1 (pure transport swap), HP #4
  (per-operator isolation non-negotiable).
  * docs/contracts/core_app_architecture.md (Layer assignment for
  fact tables — Layer 4 canonical facts).
  * db/migrations/202605040000_phase_8_0_integration_framework.sql
  lines 479-537 — the framework's `add column if not exists
  vendor_id / vendor_entity_id / vendor_modified_at / raw_payload`
  loop that runs after this migration; the columns we declare here
  match what that loop expects so its idempotent guard is a no-op
  once this migration has landed.
  * db/migrations/202605061700_phase_8_timing_provenance_shift_records.sql
  — the migration that fails today with `relation "shift_records"
  does not exist`; lex-ordered after this one so its `ALTER TABLE`
  and `CREATE INDEX CONCURRENTLY` statements succeed.
  * db/migrations/202605080600_phase_8_idempotency_location_id_rekey.sql
  — drops + recreates the `<fact>_vendor_idempotency_idx` unique
  indexes on all four tables; the columns it keys on
  `(operator_id, location_id, vendor_id, vendor_entity_id)` are
  present at creation here.

  Why this exists:

  Phase 8 framework writes vendor data into the existing SQLite fact
  tables per HP #1. The Phase 8 Postgres migrations
  (`202605061700_…_shift_records`, `_..._fk_posture`,
  `_idempotency_location_id_rekey`, plus the keyed data-accuracy
  service-period child table) were authored assuming Postgres-side
  counterparts exist, but no migration ever runs `CREATE TABLE
  public.shift_records` (or the three sibling fact tables). Today
  they exist only as minimal local stubs created out-of-band by step
  6 of `runbooks/local_full_stack_setup_runbook.md`. Staging /
  Production1 apply fails the moment one of the dependent migrations
  runs an `ALTER TABLE` against a non-existent relation.

  This migration creates all four fact tables with the columns the
  codebase already reads/writes (per the audit of
  `lib/infrastructure/persistence/postgres/postgres_shift_record_writer.dart`
  and the 17 Phase 8 vendor sinks in the same directory). Every
  subsequent migration that ALTERs these tables then applies cleanly.

  Column inventory (grep ground truth, NOT guesswork):

  * shift_records — from `postgres_shift_record_writer.dart` and the
  `202605061700_…_shift_records.sql` ALTERs:
  operator_id, location_id, restaurant_id, week_id, day_label,
  daypart, status, business_date, covers, forecast_covers,
  actual_sales, ppa, cplh, splh, foh_hours, boh_hours,
  foh_labor_dollar, boh_labor_dollar, theoretical_labor_pct,
  primary_lever, target_profile_id, target_profile_version_id,
  target_source_type, target_cplh, target_splh, target_ppa,
  target_foh_wage, target_boh_wage, opz_floor_cplh,
  opz_ceiling_cplh, theoretical_foh_labor_pct,
  theoretical_boh_labor_pct, business_timing_profile_id,
  business_timing_profile_version_id, service_period_key,
  source_system, source_shift_id, covers_provenance,
  labor_dollars_provenance, vendor_id, vendor_entity_id,
  vendor_modified_at, raw_payload, created_at, updated_at.

  * cover_facts — from `square_pos_postgres_sink.dart`,
  `toast_pos_postgres_sink.dart`, the eight other POS sinks, and
  the framework's add-column loop:
  operator_id, location_id, vendor_id, vendor_entity_id,
  vendor_modified_at, covers, covers_source, opened_at,
  closed_at, business_date, actual_sales, raw_payload,
  created_at, updated_at.

  * labor_punches — from `quickbooks_time_postgres_sink.dart`,
  `adp_postgres_sink.dart`, the four other labor sinks, and the
  framework's add-column loop:
  operator_id, location_id, employee_source_id, role_name,
  shift_start, shift_end, hours_worked, pay_rate, vendor_id,
  vendor_entity_id, vendor_modified_at, raw_payload,
  business_date, created_at, updated_at.

  * reservation_facts — from `libro_postgres_sink.dart`,
  `sevenrooms_reservation_postgres_sink.dart`,
  `opentable_reservation_postgres_sink.dart`,
  `tock_reservation_postgres_sink.dart`, and the framework's
  add-column loop:
  operator_id, location_id, connection_id, vendor_id,
  vendor_entity_id, vendor_modified_at, reservation_at,
  business_date, party_size, status, seated_at, cancelled_at,
  raw_payload, created_at, updated_at.

  Idempotency:

  * Every CREATE uses `IF NOT EXISTS`. Re-applying this migration is
  a no-op.
  * No data writes. No backfill.

  Sequencing note:

  The Phase 8 framework migration `202605040000_phase_8_0_integration_framework.sql`
  already runs `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` for
  `vendor_id / vendor_entity_id / vendor_modified_at / raw_payload`
  on each fact table under an `IF EXISTS` table guard, and creates
  the `<fact>_vendor_idempotency_idx` UNIQUE indexes. That migration
  runs BEFORE this one (lex 040000 < 061650), so on a fresh apply
  its table guard finds no tables to alter and the alter loop is a
  no-op. The four base tables then materialize here with the columns
  the framework expected. The subsequent rekey migration
  `202605080600_…_idempotency_location_id_rekey.sql` then drops +
  recreates those unique indexes with `(operator_id, location_id,
  vendor_id, vendor_entity_id)`. This migration includes the
  pre-rekey index shape so the framework's idempotency contract holds
  on a fresh Postgres until the rekey lands.

  RLS / grants:

  * Each fact table enables row level security at creation.
  * Per-tenant policy uses wrapper functions
  `app_current_operator()` + `app_current_location()` (the four
  STABLE LEAKPROOF PARALLEL SAFE wrappers from
  `202604280000_phase_9_0sigma_b_rls_wrappers.sql`). No bare
  `current_setting('app.*')` reads.
  * `service_role` and `forge_admin` get SELECT, INSERT, UPDATE
  (canonical-fact tables are append/upsert; DELETE not needed at
  V1). `forge_admin` retains BYPASSRLS for support paths.
  * `public` is REVOKEd.

## `202605061700_hardening_audit_anchor_daily_schedule.sql`

- **Applied:** 2026-05-06 17:00
- **Title:** hardening audit anchor daily schedule
- **Description:**

  Hardening / Wave B3 — daily pg_cron tick for the audit-anchor sweep.

  Origin: `docs/_execution/2026-05-05_v1_launch_punchlist.md` §5
  "Daily Azure Blob audit-anchor cron". The Phase 9.0Σ.f hash-chained
  audit_logs slice (`202604280005_phase_9_0sigma_f_audit_logs.sql`)
  created `public.audit_chain_anchors`; the Cloud Run job
  `forge-flow-audit-anchor` (`tool/audit_anchor/main.dart` +
  `runbooks/audit_anchor_cloudrun_deploy_runbook.md`) is the
  production executor that walks each `(operator_id, chain_date)`
  chain, writes the immutable Azure Blob, and inserts the matching
  `audit_chain_anchors` row.

  Status entering this slice (per the punchlist + B43 in
  `phase_9_execution_backlog.md`): the Cloud Run Job is deployed on
  staging and was exercised once via `gcloud run jobs execute` on
  2026-05-03; the matching Cloud Scheduler trigger
  `forge-flow-audit-anchor-daily` (23:55 Etc/UTC) is created but
  **paused**. There is no continuous in-DB schedule of the daily
  anchor cadence yet — only the manually-fired Cloud Run executions.

  This migration adds a small `pg_cron` NOTIFY-only kickoff so the
  daily anchor cadence is observable from inside Postgres
  (`cron.job_run_details`) regardless of whether Cloud Scheduler is
  paused/resumed/region-failed. The pattern mirrors
  `public.rollup_run_hot_path()` / `public.rollup_run_cold_path()`
  from the prior batch's
  `202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql`: the SQL
  function NEVER does the anchor work itself (anchoring requires
  Azure Blob writes via WIF, which Postgres has no business
  attempting), it only `pg_notify`s an `audit_anchor_tick` envelope.
  A future Dart subscriber can listen on the channel and trigger the
  Cloud Run anchor sweep independently of Cloud Scheduler; until
  that subscriber lands, the row in `cron.job_run_details` is the
  evidence-of-tick that operators read for "did the daily cadence
  fire today".

  Anchor function behavior is UNCHANGED. The Cloud Run binary at
  `tool/audit_anchor/main.dart` and its Azure Blob client at
  `tool/audit_anchor/azure_blob_client.dart` are out of scope here;
  this slice only adds the in-DB cron tick that wraps them with a
  pg_cron-owned daily cadence.

  Authority:
  * `docs/_execution/2026-05-05_v1_launch_punchlist.md` §5
  * `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
  (RLS-ready schema, tenant-leading index discipline; this slice
  adds neither a table nor an index, so the rules apply only by
  reference — no new operator-scoped surfaces.)
  * `docs/phases/phase_9/phase_9_execution_backlog.md` (B43 audit
  anchor deploy)
  * `runbooks/phase_9_production1_migration_apply_runbook.md`
  (next-batch pending follow-up scope + apply order)

  Hard rules carried from CLAUDE.md and the prior batch:

  1. **Tenant-leading discipline.** This is a maintenance job;
  cron rows have no `operator_id`. The kickoff function does
  not read or write any operator-scoped table, so the
  tenant-leading-index rule does not bind. The actual anchor
  sweep is owned by the Cloud Run binary, which authenticates
  with `forge_admin` BYPASSRLS for cross-operator reads.

  2. **Replay-safe.** `cron.schedule(jobname, …)` raises
  `unique_violation` on a duplicate jobname. The DO block
  below removes any existing job by jobid first, then
  reschedules. Re-running this migration on a host where the
  schedule already exists is a clean no-op.

  3. **Azure pg_cron split-DB topology.** Azure DB Flexible Server
  keeps pg_cron metadata in the database named by
  `cron.database_name` (currently `postgres` on
  staging + Production1). The DO block emits a NOTICE and
  returns when pg_cron metadata is not in this database; the
  runbook captures the manual `cron.schedule_in_database(...,
  'forgeflow')` follow-up step. Pattern matches the rollup
  hot/cold path migration byte-for-byte.

  4. **NOTIFY-only kickoff.** The function MUST NOT attempt the
  actual anchor work. Postgres has no Azure WIF client and no
  `pg_net`-style HTTP capability; trying to anchor from inside
  pg_cron would either silently fail or require granting the
  database network egress it currently does not have. The
  function is deliberately one-statement (`pg_notify`) so the
  cost of a daily fire is negligible.

  5. **Job naming.** `forge_audit_anchor_daily` follows the
  existing `forge_rollup_hot_path` / `forge_rollup_cold_path`
  naming convention from the prior batch.

  6. **Schedule choice.** `'0 2 * * *'` = 02:00 Etc/UTC daily.
  Two hours past midnight UTC gives the previous-UTC-day chain
  a settled buffer (the chain rolls at 00:00 UTC because
  `audit_logs.chain_date = (occurred_at AT TIME ZONE 'UTC')
  ::date`). The Cloud Scheduler trigger fires at 23:55 UTC
  and anchors the previous UTC day; this in-DB tick at 02:00
  UTC is intentionally staggered so the two cadences do not
  collide if both end up driving the Cloud Run binary in
  future. 02:00 UTC corresponds to 21:00 ET / 18:00 PT prior
  day — restaurants are still open in the West, but the
  kickoff is NOTIFY-only so it does not contend on any live
  facts.

  7. **No new tables, no new RLS, no new grants.** The function
  is granted to `forge_admin` only; runtime `service_role`
  has no business firing the audit-anchor cadence on its own.

  Verification SQL operators can run post-apply:

  -- 1. Function exists in the app database.
  select pg_get_functiondef(p.oid)
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
  and p.proname = 'audit_anchor_run_daily';

  -- 2. Cron job exists with the expected schedule (run from
  --    the postgres maintenance database on Azure):
  select jobname, schedule, active, command
  from cron.job
  where jobname = 'forge_audit_anchor_daily';
  -- expected: '0 2 * * *', active = true,
  --           command = 'select public.audit_anchor_run_daily();'

  -- 3. NOTIFY envelope shape (sanity check; LISTEN in another
  --    session before running):
  select public.audit_anchor_run_daily();
  -- expected: notification on channel 'audit_anchor_tick' with
  --           payload like {"fired_at": "...", "source": "pg_cron"}

  -- 4. Recent run history (after the first daily fire):
  select start_time, status, return_message
  from cron.job_run_details
  where jobid = (
  select jobid from cron.job
  where jobname = 'forge_audit_anchor_daily'
  )
  order by start_time desc
  limit 5;

  Live apply status: code-ready 2026-05-06; staging apply pending
  under the Live-Mutation Gate of
  `runbooks/phase_9_production1_migration_apply_runbook.md`.

## `202605061700_phase_8_timing_provenance_shift_records.sql`

- **Applied:** 2026-05-06 17:00
- **Title:** phase 8 timing provenance shift records
- **Description:**

  Phase 8 live + closed truth Lane 0: timing provenance foundation.

  Decision: current business timing uses immutable
  business_timing_profiles.profile_id as both the profile id and current
  version id. A future migration may introduce a dedicated versions table,
  but this lane must not query a table that does not exist on master.

  This migration is additive:
  * nullable closed shift_records columns preserve legacy rows as NULL.
  * nullable open_shift_snapshots version column backfills from profile_id.
  * no historical closed rows are rewritten or re-bucketed.
  * indexes lead with operator_id and use CONCURRENTLY for live tables.

## `202605061701_phase_8_data_accuracy_service_period_settings.sql`

- **Applied:** 2026-05-06 17:01
- **Title:** phase 8 data accuracy service period settings
- **Description:**

  Hardening Wave B1 — Data Accuracy keyed service-period settings.

  Authority:
  * docs/contracts/data_accuracy_settings_contract.md
  "Business timing compatibility amendment (2026-05-06)" + "Schema"
  section. The amendment declares the hardcoded
  `covers_source_lunch` / `_dinner` / `_late_night` columns a
  rejected legacy compatibility shape; the V1 implementation target
  is a keyed child table per `service_period_key`.
  * docs/contracts/phase_7_55_time_boundary_contract.md
  (TIMESTAMPTZ-only on operator-scoped fact tables).
  * docs/contracts/integration_spine_architecture_contract.md
  (covers-source resolution at the aggregator layer keys on a
  stable service_period_key, not display label).
  * docs/contracts/hardening_rls_and_repository_pattern_contract.md
  (RLS wrapper-only policy bodies; tenant-leading B-tree indexes;
  `app_current_operator()` / `app_current_location()` only — no
  bare `current_setting('app.*')`).
  * docs/_execution/2026-05-05_v1_launch_punchlist.md §5
  "Data Accuracy keyed service-period settings".

  Why this migration:

  The existing `public.data_accuracy_settings` row carries one
  covers_source column per hardcoded daypart (lunch / dinner /
  late_night). Business timing makes service periods restaurant-
  configurable, so a 4th period (e.g., `breakfast`) or a custom
  period (e.g., `brunch`) cannot be operator-controlled without a
  schema change. This migration replaces the hardcoded shape with
  a keyed child table that admits one covers-source row per
  (operator, location, service_period_key, effective_at_business_date)
  so future service periods light up without further migrations.

  What this migration does NOT do (in scope of this lane):

  * Does NOT drop the legacy `covers_source_lunch` /
  `covers_source_dinner` / `covers_source_late_night` columns on
  `public.data_accuracy_settings`. They remain as a read-only
  fallback for rows the keyed table does not yet cover. A future
  migration will drop them once every read path (aggregator, F&F
  Ops Console admin reads, operator web Data Accuracy tab) is
  migrated to the keyed lookup.
  * Does NOT touch `public.shift_records` or any timing triplet on
  ShiftFactBuilder — those are owned by the `8.live-and-closed-truth`
  lanes.

  Hard rules carried verbatim from CLAUDE.md / phase docs:

  * **HP #4 RLS-Ready Schema.** Table carries (operator_id,
  location_id) from creation; tenant-leading B-tree indexes;
  per-tenant RLS policy enabled at table-creation time.
  * **Wrapper-only RLS posture (Phase 9.0Σ.b item 4).** Policy body
  calls `app_current_operator()` / `app_current_location()`. No
  bare `current_setting(...)` reads.
  * **Time guardrails (CLAUDE.md / 7.55 Rule 11).** All temporal
  columns are `TIMESTAMPTZ`; the effective-dating anchor is a
  business-local DATE column denormalized off
  `locations.business_day_rollover_hour`.
  * **Idempotent migration.** `if not exists` on every CREATE,
  `drop policy if exists` before `create policy`. Re-applying the
  migration is a no-op.

  service_period_key shape pattern matches the `business_timing_*`
  tables (see 202605060000_phase_business_timing_live_schema.sql line
  172): `^[a-z][a-z0-9_]{0,63}$` so `lunch`, `dinner`, `late_night`,
  `breakfast`, `brunch`, `happy_hour`, etc. are all admissible. The
  aggregator reads with the wire form of `Daypart` (`lunch`, `dinner`,
  `late_night`) so existing rows seeded under those keys keep
  working.

## `202605061800_phase_8_first_connection_backfill_jobs.sql`

- **Applied:** 2026-05-06 18:00
- **Title:** phase 8 first connection backfill jobs
- **Description:**

  Phase 8 mobile core - first connection backfill jobs.

  Authority:
  * docs/contracts/mobile_core_first_connection_backfill_contract.md
  * docs/_execution/2026-05-06_mobile_core_first_connection_backfill_sprint_plan.md
  * docs/contracts/integration_spine_architecture_contract.md
  * docs/contracts/phase_7_55_time_boundary_contract.md
  * docs/contracts/hardening_rls_and_repository_pattern_contract.md

  Why this migration:

  First connection already has adapter `backfill()` command/result seams,
  but the production spine needs a durable, claimable work item before
  connect routes, workers, projector wire-in, and mobile status can share
  one source of truth. This table stores only server-side work state.
  Mobile remains a cache and reads status through the proxy in a later
  lane.

## `202605061900_phase_8_star_target_truth.sql`

- **Applied:** 2026-05-06 19:00
- **Title:** phase 8 star target truth
- **Description:**

  Phase 8 star/target truth: selected stars, target cycles, profiles.

  This migration is additive server truth for Doc 1 mobile core logic:

  * selected_star_shift_decisions: append-only manager/admin select/clear
  decisions. Recommendations are referenced as provenance, never stored
  as manager-selected rows.
  * target_cycles: server-owned locked target cycles.
  * active_target_profiles: server projection of the active target cycle.
  * target_profile_versions: immutable profile snapshots for closed-shift
  provenance and mobile cache sync.
  * star_target_audit_events: append-only audit ledger for later proxy
  write paths.

  RLS posture:
  * every table is operator/location scoped.
  * every hot-path B-tree index starts with operator_id.
  * policies use wrapper functions, never bare current_setting().

## `202605070000_phase_11W_7_operator_account_fields.sql`

- **Applied:** 2026-05-07 00:00
- **Title:** phase 11W 7 operator account fields
- **Description:**

  Phase 11W.7 / Wave A2 - operator account write-fields.

  Adds the editable business-identity columns the operator-web Account
  settings page (PATCH /v1/operator/account) needs. Columns are
  additive and nullable / defaulted so existing rows are preserved.

  Field locations follow the existing schema:
  * business_name and primary_location_id already live on operators.
  * business_day_rollover_hour already lives on locations and is the
  authoritative per-location source. Phase 11W.7 stores an
  operator-level default (rollover_hour) that the operator-web
  settings UI reads/writes; per-location overrides remain on
  locations.business_day_rollover_hour.
  * locale_tag, currency_code, week_start_day, logo_url are
  operator-level identity/regional defaults that locations inherit.

  RLS posture: operators is identity (per-operator) and is already
  protected by existing operator policies created in earlier slices
  (operator owners can update their own row through the proxy's
  TenantContext SET LOCAL flow). This migration does not change RLS.

  Time posture: no new TIMESTAMPTZ columns added; updated_at is already
  present and maintained by cloud_foundation_set_updated_at trigger.

## `202605070100_password_history_salt_pepper.sql`

- **Applied:** 2026-05-07 01:00
- **Title:** password history salt pepper
- **Description:**

  Lane: code-health.M2

  CODE_HEALTH reference:
  "Salt-less SHA-256 password-history hash"
  (lib/services/auth/repository_password_history_check.dart:38)
  — credential oracle on table leak.

  Intent (schema only; no app code in this slice):
  The 9.0 password_history schema stored a bare SHA-256 of
  (operator_id || user_id || candidate). Per-tenant + per-user salting
  raised the cost of a same-password fingerprint attack across rows,
  but it did NOT defeat an offline rainbow-table attack against a
  single (operator_id, user_id) pair: an attacker who exfiltrates the
  table can pre-compute SHA-256(operator || user || guess) for a
  dictionary of guesses and learn whether each user re-used a common
  password. There is no per-row work factor and no secret material
  outside the table.

  This migration adds the columns required to migrate the hash family
  to a salted form WITHOUT touching the existing rows' bytes:

  password_hash_salt        BYTEA         per-row random salt
  password_hash_pepper_id   TEXT          which env-injected pepper
  was mixed in (rotation)
  password_hash_algo        TEXT NOT NULL identifies the hash family
  of password_hash so the
  verifier can pick the
  right code path

  Existing rows are flagged 'sha256-legacy' with NULL salt so the
  legacy verification code path (no salt, no pepper) can still
  constant-time-compare them. The DEFAULT for new rows is
  'sha256-salted' so a forgotten code path cannot ship sha256 (legacy
  without salt) by accident — code lane L12 will explicitly set the
  algo on every write and is responsible for actually generating the
  per-row salt and selecting the active pepper id from env.

  A NOT VALID CHECK constraint enforces the legacy <-> salt invariant:
  algo = 'sha256-legacy'  IFF  salt IS NULL
  We mark it NOT VALID so the apply does not take an ACCESS EXCLUSIVE
  lock to re-scan existing rows; the backfill above already ensures
  every legacy row has NULL salt. We then VALIDATE CONSTRAINT in a
  separate statement, which scans without the heavy lock.

  Code lane L12 will:
  * generate a 16+ byte CSPRNG salt on every write
  * select the active pepper id from env / KMS
  * write password_hash = SHA-256(operator || user || salt ||
  pepper || candidate)
  * verify legacy rows (algo = 'sha256-legacy') via the existing
  unsalted code path during the migration window
  * set algo = 'sha256-salted' on every new row

  Forward-compatible: the columns are nullable (except algo), so older
  proxy builds that have not yet been redeployed when this migration
  applies continue to insert legacy-shape rows; the trigger of the new
  behavior is the L12 code change, not this schema change.

## `202605070200_audit_anchor_advisory_lock_infra.sql`

- **Applied:** 2026-05-07 02:00
- **Title:** audit anchor advisory lock infra
- **Description:**

  Code-Health Lane M3 — audit anchor advisory lock + Azure blob columns.

  CODE_HEALTH references:
  * "Audit anchor sweep has no advisory-lock guard"
  (`tool/audit_anchor/audit_anchor.dart:1101` — verify path reads
  the current anchor row but nothing serializes concurrent sweeps;
  two pods firing the daily cadence at the same time can race the
  read-then-write of the audit_chain_anchors row).
  * "Audit-anchor cadence is paused"
  (`db/migrations/202605061700_hardening_audit_anchor_daily_schedule.sql`
  — the in-DB pg_cron tick is NOTIFY-only and the Cloud Scheduler
  trigger `forge-flow-audit-anchor-daily` is paused; resuming +
  wiring the Cloud Run binary to the daily Azure Blob write is
  code-lane L9 work).
  * "Audit anchor verify can't recover from crashed-write state"
  (the verifier currently has no notion of a half-written anchor;
  L9 adds a roll-forward path that needs the new
  last_anchor_blob_url / last_anchor_blob_at columns to know
  whether the previous run wrote the Blob before crashing).

  Scope of THIS migration: schema infrastructure ONLY.
  1. Constants table `audit_anchor_advisory_locks` carrying the
  stable INTEGER lock id used by `pg_advisory_lock(...)` to
  serialize the daily anchor sweep across pods/regions.
  2. Two new columns on the existing `public.audit_chain_anchors`
  table tracking the most-recent daily Azure Blob write:
  - `last_anchor_blob_url  TEXT`
  - `last_anchor_blob_at   TIMESTAMPTZ`
  These columns are crash-recovery breadcrumbs the verifier
  reads to roll a half-written sweep forward instead of
  reporting `anchorMissing`.

  NOTE: Cron unpause + the daily Azure Blob write are wired in code lane L9, not in this migration.

  Scope (operator) — this migration is **global / cluster-wide**
  infrastructure, not operator-scoped. The advisory-lock id table
  holds one constant row shared by every operator's sweep; the new
  columns hang off `public.audit_chain_anchors`, which is already
  operator-scoped at row level (PRIMARY KEY (operator_id, chain_date)).
  No new RLS surface is created here, so the tenant-leading-index
  rule from the hardening RLS contract does not bind to this slice.

  Authority:
  * `docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`
  (Audit Anchor section — advisory lock, paused cadence,
  crash-recovery rollforward).
  * `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`
  (original `audit_chain_anchors` CREATE TABLE — append-only
  grant shape preserved; this slice only ALTERs to add columns).
  * `db/migrations/202605061700_hardening_audit_anchor_daily_schedule.sql`
  (in-DB NOTIFY-only cadence the L9 lane will graduate to
  resumed Cloud Scheduler / wired Azure Blob writes).
  * `tool/audit_anchor/audit_anchor.dart`
  (the Cloud Run binary that L9 will wrap with
  `pg_advisory_lock(audit_anchor_sweep)`).

  Replay-safe: every DDL statement uses IF NOT EXISTS / ON CONFLICT
  DO NOTHING so re-running this migration on a host where it has
  already applied is a clean no-op.

## `202605070400_phase_8_notification_preferences.sql`

- **Applied:** 2026-05-07 04:00
- **Title:** phase 8 notification preferences
- **Description:**

  Phase 8 W2.B - operator-web notification preferences.

  Authority:
  * docs/contracts/hardening_rls_and_repository_pattern_contract.md
  (RLS-Ready Schema, wrapper-only RLS posture, tenant-leading
  B-tree indexes).
  * docs/POST_HARDENING_FOLLOWUPS.md "P0 - Production1 Migration
  Apply Gap" (this migration appended to the gap table).
  * Master plan: W2.B "operator-web.settings-notifications-config"
  (notification event catalog + per-channel + per-scope toggles).

  Adds public.notification_preferences: operator-scoped + per-user
  per-event-key per-channel per-scope row. Absence of a row means the
  catalog default applies; presence with enabled=true is an explicit
  opt-in, enabled=false is an explicit opt-out.

  Schema follows the durable contract:
  * synthetic UUID primary key (no client-side UUIDs; PG generates)
  * UNIQUE NULLS NOT DISTINCT on the 6-tuple (operator_id, user_id,
  event_key, channel, scope_kind, scope_id) so a (operator) scope
  row with scope_id=NULL still uniques cleanly.
  * channel enum (push / email / inbox).
  * scope enum (operator / location); scope_id NULL when scope_kind
  is 'operator', UUID when scope_kind is 'location'.
  * created_at / updated_at TIMESTAMPTZ per the time guardrails.

  Hard rules carried verbatim from CLAUDE.md / phase docs:

  * **HP #4 RLS-Ready Schema.** Table carries operator_id from
  creation; tenant-leading B-tree indexes; per-tenant +
  per-user RLS policy enabled at table-creation time.
  * **Wrapper-only RLS posture (Phase 9.0Σ.b item 4).** Policy body
  calls public.app_current_operator() / public.app_current_actor_user().
  No bare current_setting(...) reads.
  * **Time guardrails.** All temporal columns are TIMESTAMPTZ.
  * **Idempotent migration.** if not exists on every CREATE,
  drop policy if exists before create policy. Re-applying the
  migration is a no-op.
  * **No client-side UUIDs.** id default is gen_random_uuid()
  server-side; clients PUT by event/channel/scope, not by id.

## `202605071400_advisor_response_cache_table.sql`

- **Applied:** 2026-05-07 14:00
- **Title:** advisor response cache table
- **Description:**

  code-health.L14 — Postgres-backed advisor response cache.

  CODE_HEALTH ref: "AlwaysMissAdvisorResponseCache still in production
  wiring (`main.dart:325`)" — collapsed fallback chain (LLM → secondary
  → cache → refusal). The cache hop currently always misses, so a
  breaker-open + secondary failure goes straight to graceful refusal
  with no chance to replay a recent identical answer.

  This migration creates the operator-scoped fact table that backs the
  new `PostgresAdvisorResponseCache` (see
  `tool/advisor_proxy/advisor_response_cache.dart`) and the hourly
  pg_cron sweep that drains expired entries. Lock 7 v1 shipped the
  abstract `AdvisorResponseCache` interface (lib/domain/services/) +
  the always-miss stub; E.2b was the locked slot to swap in a real
  impl. This slice fulfills that promise.

  Authority:
  * CLAUDE.md "RLS-Ready Schema" — operator-scoped fact tables ship
  with `(operator_id, location_id)` + an RLS policy stub from
  creation. App code uses `OperatorScopedRepository` (primary
  defense); RLS is the backup.
  * CLAUDE.md "Time Guardrails" — operator-scoped Postgres fact
  tables store `TIMESTAMPTZ` (UTC). Plain `TIMESTAMP WITHOUT TIME
  ZONE` is banned.
  * CLAUDE.md "RLS performance discipline" — every B-tree index on
  an operator-scoped fact table MUST lead with `operator_id` (or
  `(operator_id, location_id)`). `tool/index_leading_column_lint.dart`
  enforces the rule.
  * `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
  — RLS policies use `STABLE LEAKPROOF PARALLEL SAFE` wrapper
  functions; bare `current_setting()` reads forbidden in policy
  bodies. The wrapper of record is `public.app_current_operator()`
  / `public.app_current_location()` (Phase 9.0Σ.b lock).

  Hard rules carried from CLAUDE.md and the contract:

  1. The cache is operator-scoped and location-scoped — same answer
  to the same prompt at a different location is a different
  cache entry. The unique key leads with `operator_id` so the
  policy folds into the index probe.

  2. The TTL sweep job runs hourly (cheap DELETE; the table never
  grows past one day's traffic). The unschedule-then-reschedule
  pattern matches the Phase 10a.3 retention sweep migration so a
  re-apply does not leave duplicate cron rows.

  3. The `prompt_hash` column is `BYTEA` (raw SHA-256) so a partial
  hash collision check (e.g. via prefix index) stays cheap. The
  Dart side digests the normalized prompt and binds the bytes
  directly — never hex-encodes for the round-trip.

  4. The `response` column is `JSONB` so a future swap from "answer
  text only" to a richer cached envelope (e.g. completion +
  provenance + token counts) does not require a new migration.
  v1 stores `{"answer": "<string>"}`.

  5. The `embedding_id` column is nullable; populated when the
  semantic-cache lookup uses an embedding probe (v2). v1 always
  writes NULL. The unique key uses `coalesce(embedding_id, 0)`
  so two identical-prompt entries cannot collide on insert just
  because one has an embedding probe and the other does not.

  6. The pg_cron sweep is `SECURITY DEFINER` + `forge_admin` owner
  so the cross-operator DELETE runs without a tenant context.
  `set search_path = public, pg_catalog` is the standard
  hardening so a session-injected schema cannot hijack a
  same-named object.

## `202605071500_phase_9_mfa_factor_removal_attempt_count.sql`

- **Applied:** 2026-05-07 15:00
- **Title:** phase 9 mfa factor removal attempt count
- **Description:**

  Lane: code-health.M4

  Reason: unblocks code-health.L7 (CODE_HEALTH "MFA removal worker has
  no retry cap, no DLQ" — see lib/services/admin/mfa_removal_worker.dart
  around line 123). The worker needs a durable per-row attempt counter
  and a dead-letter sentinel so a poison row stops being re-claimed
  after exceeding the configured retry budget.

  Schema deltas to public.mfa_factor_removal_requests:

  1. attempt_count    integer not null default 0
  Per-row retry counter. Bumped by the worker via
  MfaFactorRemovalRequestsRepository.incrementAttemptCount in the
  same tenant transaction that records markFailed/markCompleted.
  Defensive CHECK caps at 100 — app-level enforcement (L7) is the
  tighter gate at 10; the schema cap is only there to prevent a
  runaway counter in a buggy retry loop.

  2. dead_lettered_at timestamptz null
  DLQ sentinel. Once set, the row is excluded from the partial
  indexes that drive worker claim / due-pending listings, so a
  poison row stops being re-tried and instead waits for operator
  review. Setting dead_lettered_at is the worker's choice (L7),
  not an automatic trigger; this migration only provides the
  column and the index posture.

  Index reshape:

  The three partial indexes that filter `WHERE completed_at IS NULL
  AND cancelled_at IS NULL` are dropped and recreated with an
  additional `AND dead_lettered_at IS NULL` predicate. After this
  migration, dead-lettered rows naturally fall out of the
  active/due/processing index sets, so claimDuePending and friends
  stop seeing them with no app-layer changes. Index leading-column
  shapes are preserved verbatim from the original migration so this
  change is a pure predicate-narrowing.

  RLS policy untouched: the existing `mfa_factor_removal_requests_per_user`
  policy filters by operator/location/user only — it does not reference
  completed_at/cancelled_at, so adding dead_lettered_at to the table has
  no policy implications.

  Apply posture:

  - Column adds use IF NOT EXISTS for idempotency on partial replay.
  - The CHECK constraint is added NOT VALID then VALIDATEd to avoid
  holding ACCESS EXCLUSIVE during the row-walk.
  - Indexes are dropped + recreated (no CONCURRENTLY because this
  migration runs inside a transaction by convention; partial index
  rebuilds are fast on a table whose hot working set is the small
  pending sliver).

## `202605071800_actor_kind_constraint_consolidation.sql`

- **Applied:** 2026-05-07 18:00
- **Title:** actor kind constraint consolidation
- **Description:**

  Lane: code-health.actor-kind

  CODE_HEALTH reference:
  "Conflicting `actor_kind` constraint definitions in migrations
  `202604280004` + `202604280013` (different constraint names; later
  migration adds `actor_service_principal_id` not in canonical slice)."

  Background.

  Two earlier migrations both declare a CHECK constraint on
  `public.auth_events_audit.actor_kind`:

  1. `202604280004_phase_9_0sigma_d_service_principals.sql`
  adds the column with an INLINE CHECK
  (`actor_kind in ('user','service')`). Postgres assigns a
  system-generated constraint name based on the column —
  conventionally `auth_events_audit_actor_kind_check` — but the
  precise name is implementation-dependent on the apply order /
  pre-existing constraints, so the system-generated form is not
  guaranteed to match the explicit form below in every
  environment that replayed the slice fragmentarily during the
  live closeout.

  2. `202604280013_phase_9_audit_actor_kind_live_repair.sql`
  drops `auth_events_audit_actor_kind_check` (no-op when absent)
  and re-adds it explicitly under the same name. The same
  migration also adds `actor_service_principal_id uuid null`,
  which is NOT part of the canonical Phase 9.0Σ.d slice — it is
  a live-closeout repair carried forward unchanged.

  Predicate equivalence.

  Both definitions encode the SAME logical predicate:

  actor_kind IN ('user', 'service')

  This consolidation is therefore a NAME consolidation only. No row
  is rejected by the canonical constraint that the previous
  definitions accepted, and no row is accepted that the previous
  definitions rejected. There is no data-integrity decision embedded
  here; if a future slice changes the allowed value set, that is a
  separate migration, not this one.

  Canonical name and predicate.

  Canonical name : `auth_events_audit_actor_kind_check`
  Canonical body : `CHECK (actor_kind IN ('user', 'service'))`

  Reasoning. The explicit name from `202604280013` is the form the
  live audit writer assumes when it surfaces constraint-violation
  errors, and it matches the Postgres convention for an inline check
  on a single column (`<table>_<column>_check`). Keeping the same
  name avoids any churn in error-string-matching paths or in the
  dispute-reconstruction surface.

  What this migration does.

  This migration is idempotent and re-runnable. It:

  * Drops every observed prior name for the actor_kind CHECK on
  `public.auth_events_audit`. The two names known to have been
  introduced are the explicit
  `auth_events_audit_actor_kind_check` (from 202604280013) and
  the system-generated default of the same shape (from the
  inline CHECK in 202604280004). DO blocks with an
  `EXCEPTION WHEN undefined_object` swallow the case where the
  named constraint never existed in this environment.

  * Re-adds the canonical CHECK as NOT VALID, then VALIDATE
  CONSTRAINT. NOT VALID + VALIDATE avoids the ACCESS EXCLUSIVE
  full-table scan that a naked ADD CONSTRAINT would take, which
  matters because `auth_events_audit` is a high-write surface
  on the live proxy.

  Old constraint names dropped:
  * `auth_events_audit_actor_kind_check` (the explicit name from
  `202604280013`; also the conventional system-generated name
  for the inline CHECK from `202604280004`).

  Canonical constraint kept:
  * `auth_events_audit_actor_kind_check`
  CHECK (actor_kind IN ('user', 'service'))

  Note. `actor_service_principal_id` and its partial index from
  `202604280013` are intentionally NOT touched here. Their presence
  pre-dates this consolidation and is orthogonal to the constraint
  naming question; removing them would be a separate decision the
  orchestrator owns.

## `202605071900_phase_8_set_business_date_hardening.sql`

- **Applied:** 2026-05-07 19:00
- **Title:** phase 8 set business date hardening
- **Description:**

  Lane: code-health.biz-date-sec
  CODE_HEALTH ref:
  "phase_8_set_business_date() is SECURITY DEFINER owned by
  forge_admin, granted EXECUTE to service_role. SQL-injection on
  the proxy that lands a row insert hits BYPASSRLS context as a
  side effect."

  Posture chosen: KEEP `SECURITY DEFINER` + owner `forge_admin`
  (Strategy B), and tighten the blast radius by:

  1. REVOKE EXECUTE FROM service_role. Postgres invokes trigger
  functions internally under the function's own privileges
  (SECURITY DEFINER) — no application caller needs EXECUTE.
  The previous GRANT TO service_role was an over-grant: it let
  service_role (or anything that could land calls as
  service_role, e.g. SQL injection on the proxy) invoke the
  function directly outside trigger context, where the
  forge_admin (BYPASSRLS) elevation has no legitimate purpose.
  Trigger-context invocations continue to work because
  forge_admin (the function owner) retains EXECUTE.

  2. Defense-in-depth input validation. tg_argv[0] is hardcoded
  in the per-table CREATE TRIGGER statements ('occurred_at' /
  'detected_at') and Postgres does not expose a path for
  callers to override it. Validate anyway: reject anything
  outside the small allowlist so a future trigger-creation
  mistake fails fast and obvious. Validate the projected
  timestamp text via an explicit cast in a sub-block so a
  malformed value raises with a clear message rather than
  propagating an opaque cast error.

  3. search_path is already locked (`SET search_path = public,
  pg_catalog`) in the original migration; preserved here so
  session-level search_path mutations cannot redirect the
  `public.locations` lookup.

  Why NOT Strategy A (SECURITY INVOKER):
  * The function reads `public.locations`, which is RLS-enabled.
  Inserts arrive on connector_sync_log / inbound_webhook_dead_letter
  / sanity_log under varying tenant contexts (proxy session,
  spine-bridge sink, integration sync worker). Switching to
  INVOKER would cause the locations join to filter by the
  current tenant context and miss the row whenever the inserter
  is operating cross-tenant or before SET LOCAL has been
  applied — the trigger would then take the UTC fallback path
  on every cross-tenant insert, silently corrupting business_date
  denorm for those rows.
  * `test/integration/business_date_denorm_test.dart` (lines
  222–248) explicitly asserts the function MUST be
  SECURITY DEFINER + owned by forge_admin so the locations join
  succeeds across tenant contexts. Strategy A would fail that
  guard.

  Idempotent: CREATE OR REPLACE FUNCTION + REVOKE-IF-GRANTED
  semantics. Re-running the migration is a no-op.

## `202605072000_feature_flags_sentinel_operator.sql`

- **Applied:** 2026-05-07 20:00
- **Title:** feature flags sentinel operator
- **Description:**

  code-health.ff-policy-fold — feature_flags sentinel operator_id

  CODE_HEALTH reference: "`feature_flags` policy `OR (operator_id IS
  NULL …)` can't fold into the tenant-leading index (perf concern)."
  The 202605021500_phase_9_0sigma_l_rls_depth.sql policy reads
  `operator_id IS NULL OR operator_id = app_current_operator()`. The
  `IS NULL` arm prevents Postgres from folding the predicate into the
  operator-leading partial unique index
  `feature_flags_operator_scope_idx (flag_name, operator_id) WHERE
  operator_id IS NOT NULL AND location_id IS NULL` — every tenant-
  scoped flag lookup falls back to a sequential scan or the wider
  `feature_flags_pkey`.

  Fix shape: introduce a sentinel UUID for system-wide flags so the
  policy becomes `operator_id = app_current_operator() OR operator_id
  = <sentinel>`. The `IS NULL` clause is gone and the planner can fold
  the OR into a bitmap-or on the operator-leading partial unique
  index.

  Sentinel value chosen: `00000000-0000-0000-0000-000000000000`. Why:
  * Repo-wide search of `db/migrations/**` and `test/**` confirms
  no real `operators.operator_id` row uses the all-zeros UUID.
  `gen_random_uuid()` (the table default) cannot produce all-
  zeros. The all-zeros pattern IS used elsewhere as a NULL
  `location_id` coalescing sentinel inside `coalesce(location_id,
  '00000000-...')` predicates (`202604250008_auth_schema_
  foundation.sql`, `202605040000_phase_8_0_integration_framework
  .sql`, `202604290101_phase_9_hierarchy_access_wiring.sql`,
  `202604300002_phase_9_mfa_hardening_launch_roles.sql`) — but
  only as a `location_id` placeholder, never as an `operator_id`,
  so the namespaces don't overlap.
  * Recognizable on staging at a glance (`\dt`-style triage knows
  all-zeros = system sentinel).

  Authority order:
  1. CLAUDE.md "RLS-Ready Schema" — wrappers + tenant-leading index
  fold; no bare `current_setting` reads.
  2. `phase_9_scalability_decisions_2026-04-27.md` item 4 — every
  RLS predicate must fold into a tenant-leading index.
  3. `202604280000_phase_9_0sigma_b_rls_wrappers.sql` — the
  `app_current_operator()` wrapper this policy calls.
  4. `202605021500_phase_9_0sigma_l_rls_depth.sql` — the policy
  this migration replaces.

  Behavioral parity:

  * Visibility: tenants still SELECT their own + system-wide rows
  (the sentinel matches the OR arm).
  * Mutation: WITH CHECK still rejects system-wide writes from
  tenant context — sentinel-bearing rows are still mutated only
  via `forge_admin BYPASSRLS` (super_admin Feature Flags screen)
  or migration-side seeds.
  * Index fold: the operator-scope partial unique index
  (`feature_flags_operator_scope_idx`) now matches sentinel-
  bearing rows (sentinel is NOT NULL), so global-scope uniqueness
  enforcement folds into the same index that operator-wide
  uniqueness uses. The dedicated global-scope partial index
  (`feature_flags_global_scope_idx WHERE operator_id IS NULL AND
  location_id IS NULL`) is dropped because no row matches its
  predicate after the backfill.

  FK posture: `feature_flags.operator_id` references
  `public.operators(operator_id)` with `ON DELETE CASCADE`. To keep
  the FK valid after the backfill, this migration seeds a synthetic
  `operators` row at the sentinel UUID. The synthetic row carries
  the `business_name = 'forge-and-flow-system-sentinel'` marker so
  ops triage can identify it. RLS on `public.operators` is the
  permissive `using (true)` stub from `202604250005`, so tenant
  queries still see the row only by FK reference (they cannot
  mutate it through the per-tenant Feature Flags policy because
  WITH CHECK still rejects sentinel writes from tenant context).

  Idempotency: every UPDATE / INSERT carries an existence guard;
  DROP POLICY uses `if exists`; the migration runs in
  `psql --single-transaction` so the table is never policy-less
  between statements. Re-runs are no-ops.

## `202605080000_phase_8_timing_provenance_fk_posture.sql`

- **Applied:** 2026-05-08 00:00
- **Title:** phase 8 timing provenance fk posture
- **Description:**

  Phase 8 timing provenance FK posture follow-up (V1.B).

  Lane 0 (`202605061700_phase_8_timing_provenance_shift_records.sql`) added
  the timing-profile foreign keys on closed `shift_records` and on live
  `open_shift_snapshots` with the default `ON DELETE NO ACTION` action. That
  conflicts with the `core_app_architecture.md` "What never rewrites"
  non-negotiable: closed historical truth must outlive profile mutation.
  Default `NO ACTION` would block any `business_timing_profiles` delete the
  moment a single closed row references the profile, breaking the Operator
  Web timing editor's expected lifecycle.

  Decision (per `docs/POST_HARDENING_FOLLOWUPS.md` P1 Phase 8 carry-forward):
  flip these three FKs to `ON DELETE SET NULL` so that profile deletion
  degrades the closed/live row to a null timing triplet (legacy `daypart`
  still drives display until a future re-aggregation). Validation is
  deferred — the new constraints stay `NOT VALID`, mirroring Lane 0's
  posture, until a maintenance-window `VALIDATE CONSTRAINT` follow-up.

  Out of scope: the version-equals-profile CHECKs
  (`shift_records_timing_version_profile_match_check`,
  `open_shift_snapshots_timing_version_profile_match_check`) stay in place;
  they get dropped in a separate Phase 8R follow-up before any divergent
  `business_timing_profile_versions` writes (see POST_HARDENING_FOLLOWUPS).

  Idempotent: each block drops the constraint by name only if present and
  re-adds it only if absent.

## `202605080100_admin_idempotency_expires_at.sql`

- **Applied:** 2026-05-08 01:00
- **Title:** admin idempotency expires at
- **Description:**

  Lane: code-health.M1 — admin idempotency `expires_at` + sweep cron.

  CODE_HEALTH reference: C4 — `tool/advisor_proxy/advisor_proxy.dart`
  `_runAdminIdempotent` helper has no compute-failure cleanup or TTL on
  the admin idempotency table. A single transient compute failure
  between `reserve()` and `completeReservation()` (proxy crash, network
  glitch, panic in the route body, etc.) leaves the row pinned in the
  "in-flight" state — `response_status IS NULL AND completed_at IS
  NULL` — forever. Every replay of the same Idempotency-Key thereafter
  returns `409 idempotency_request_in_flight`, even though no work is
  actually in flight, until an operator manually deletes the row.

  This migration is the schema half of the fix: each row gets a
  mandatory `expires_at TIMESTAMPTZ` defaulting to `now() + interval
  '15 minutes'`, a partial B-tree index on `(expires_at)` for in-flight
  rows, and a `pg_cron` sweep that runs every 5 minutes and DELETEs
  in-flight rows whose `expires_at` has passed. The matching code-side
  reclaim logic — treating an in-flight row whose `expires_at < now()`
  as orphan and re-reserving it on the spot — lands in lane L4 (proxy
  hardening). M1 ships only the schema + sweep so once the cron is
  live the orphan rows are bounded to a 15-minute pin window even
  without a proxy redeploy.

  Authority:
  * `db/migrations/202605021000_phase_hardh_admin_idempotency.sql` —
  original CREATE TABLE for `public.admin_request_idempotency`.
  The HARD-H table has no `status` column; "in-flight" is signaled
  by `response_status IS NULL AND completed_at IS NULL`. The
  partial index and sweep WHERE clause use that pair as the
  in-flight predicate.
  * `docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md` — C4 finding.

  Sweep scope:
  ============
  The sweep is registered cluster-wide via `cron.schedule(jobname,
  '*/5 * * * *', sql)`, NOT per-operator. The HARD-H table is
  intentionally cross-tenant — admin actors (super_admin, ff_support)
  carry no `operator_id` in their JWT and the table itself has no
  `operator_id` column, so there is no per-tenant axis to schedule
  along. Correctness comes from the WHERE clause (`response_status IS
  NULL AND completed_at IS NULL AND expires_at < now()`), which only
  removes rows whose 15-minute reserve TTL has expired without
  completion — i.e. orphans the proxy will never finish.

  pg_cron metadata in Azure DB Flexible Server:
  =============================================
  Azure keeps pg_cron metadata in the database named by
  `cron.database_name`. When pg_cron is in a different database than
  the migration target, the DO block below raises a NOTICE so the
  live-apply log captures the "schedule from cron.database_name with
  cron.schedule_in_database(..., 'forgeflow')" manual step. Same shape
  as `202605051000_phase_10a_3_outbox_retention_sweep.sql`.

## `202605080100_phase_8_weekly_plan_server_truth.sql`

- **Applied:** 2026-05-08 01:00
- **Title:** phase 8 weekly plan server truth
- **Description:**

  Phase 8 weekly plan server truth: snapshots and forecast context.

  Additive Doc 1 Lane 0 server truth for weekly plan snapshots. Mobile
  SQLite remains a cache mirror; Postgres owns the locked weekly plan and the
  explainable forecast context that produced it.

  RLS posture:
  * every table is operator/location scoped.
  * every hot-path B-tree index starts with operator_id.
  * policies use wrapper functions, never bare current_setting().

## `202605080200_phase_8_wage_role_rows_server_truth.sql`

- **Applied:** 2026-05-08 02:00
- **Title:** phase 8 wage role rows server truth
- **Description:**

  Phase 8 mobile settings spine: server truth for wage role rows.

  Admin/web wage source and role/job-code mapping settings affect mobile
  labor calculations, so the operator-configured wage mix needs a
  tenant-scoped Postgres source of truth. SQLite remains a mobile cache and
  does not need to reuse the server UUID as its local integer id.

  RLS posture:
  * table is operator/location scoped from creation.
  * hot-path B-tree indexes start with operator_id.
  * policy bodies call app_current_operator() / app_current_location().

## `202605080300_phase_8_data_accuracy_walk_in_settings.sql`

- **Applied:** 2026-05-08 03:00
- **Title:** phase 8 data accuracy walk in settings
- **Description:**

  Phase 8 mobile core logic: reservation demand / walk-in settings.

  Authority:
  * docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md
  * docs/contracts/data_accuracy_settings_contract.md

  Adds durable server-owned walk-in handling fields to
  public.data_accuracy_settings. The row remains operator/location scoped
  and mobile reads it through the proxy as a cache only.

## `202605080400_phase_8_connector_oauth_state.sql`

- **Applied:** 2026-05-08 04:00
- **Title:** phase 8 connector oauth state
- **Description:**

  Phase 8 — Operator-facing connector OAuth state (CSRF) table.

  Authority:
  * The active slice prompt (operator-facing OAuth begin/callback
  routes per vendor).
  * docs/contracts/hardening_rls_and_repository_pattern_contract.md
  * CLAUDE.md Hard Promise #4 (per-operator isolation; RLS-ready
  schema from creation) and Hard Promise #7 (server-side secrets).

  Why this table:
  The new `/v1/integrations/oauth/<vendor>/begin` route mints a
  single-use CSRF state token, stores it here with a 10-minute TTL,
  and hands the operator's browser the vendor authorize URL. The
  matching `/v1/integrations/oauth/<vendor>/callback` route reads
  the row, marks it consumed, and only then proceeds to swap the
  vendor `code` for an access/refresh token bundle. The state row
  binds (operator_id, location_id, vendor_id) to the token so a
  stolen state token cannot be replayed against a different
  operator.

  V1 lean cuts:
  * No partitioning. Pruning happens via the index on `expires_at`
  plus an opportunistic delete inside the validate path; a cron
  sweep is a Production1 follow-up.
  * No dedicated `consumed_at` index. The (state_token) primary key
  is the only lookup path; consumed rows linger until the TTL
  prune deletes them.
  * No on-conflict logic. The state token is generated server-side
  with sufficient entropy that collisions are not modeled at V1.

  Time guardrails (CLAUDE.md / 7.55 Rule 11):
  `created_at` / `expires_at` / `consumed_at` are `TIMESTAMPTZ`
  (UTC). `TIMESTAMP WITHOUT TIME ZONE` is banned in operator-scoped
  tables.

  RLS posture (Phase 9.0Σ.b item 4):
  Wrapper-only policy bodies (`app_current_operator`,
  `app_current_location`). The route module reads + writes through
  the tenant-scoped pool so the SET LOCAL chain pins the policy.

  Idempotent: every CREATE uses `if not exists`; every policy is
  `drop policy if exists` first.

## `202605080500_permission_cache_invalidation_channel.sql`

- **Applied:** 2026-05-08 05:00
- **Title:** permission cache invalidation channel
- **Description:**

  Code-health PCACHE-FANOUT — declare the
  `permission_cache_invalidate` Postgres NOTIFY channel by convention.

  This migration is documentation-only. Postgres NOTIFY channels are
  not first-class schema objects — there is nothing to CREATE here.
  The channel exists the moment a session calls `LISTEN
  permission_cache_invalidate` (the listener in
  `lib/auth/permission_cache_invalidation_listener.dart`) or
  `pg_notify('permission_cache_invalidate', ...)` (producers added in
  follow-up slices that touch role/grant write paths). Locking the
  name + payload contract here keeps the listener and producers from
  drifting.

  Why we need a fan-out channel:
  Each Cloud Run proxy instance keeps its own in-process
  `PermissionCache` (LRU, default 60s TTL, keyed on
  `(user_id, roles_version, operator_id, location_id)`). When an
  admin role-change commits on instance A, instance B keeps serving
  any cached snapshot for that user that still presents the OLD
  roles_version (e.g. via a stale Firebase custom claim) until the
  per-entry TTL expires. The TTL is the catch-all; the NOTIFY
  channel is the precise wake-up so other instances drop the entry
  immediately on commit.

  Channel name : `permission_cache_invalidate`

  Payload      : JSON object. Required:
  user_id       text  -- users.id to invalidate
  Optional (forward-compatible, currently ignored
  by the listener):
  operator_id   text
  location_id   text

  Producer convention (no producer is wired in this slice — they land
  in follow-ups that touch the relevant write paths):

  * Emit AFTER the role/grant change commits, never inside the
  write transaction. NOTIFY is delivered on COMMIT regardless,
  but emitting at the post-commit boundary keeps the contract
  readable and avoids surprising rollbacks of intent-only signals.

  PERFORM pg_notify(
  'permission_cache_invalidate',
  json_build_object('user_id', :user_id)::text
  );

  * Producers MUST treat NOTIFY as best-effort. Postgres drops
  notifications under connection failure / queue pressure. The
  `PermissionCache` per-entry TTL (default 60s, configurable via
  env var `PERMISSION_CACHE_TTL_SECONDS`) bounds staleness when a
  notification is dropped.

  Consumer (this slice):

  * `PermissionCacheInvalidationListener` (Dart) holds a dedicated
  `package:postgres` connection, calls `LISTEN
  permission_cache_invalidate`, and on each NOTIFY parses the
  payload and calls `cache.invalidateUser(user_id)` on the local
  in-process `PermissionCache`. The cache's external API is not
  changed by this fix.

  No DDL — this file exists so the migration ledger records the
  channel-name lock alongside the listener landing. Re-running this
  migration is a no-op.

## `202605080600_ops_debt_vendor_credentials_webhook_signing_secret.sql`

- **Applied:** 2026-05-08 06:00
- **Title:** ops debt vendor credentials webhook signing secret
- **Description:**

  Ops debt fix — Add `vendor_credentials.webhook_signing_secret_ciphertext`.

  Authority:
  * Active prompt: `claude/ops-debt.webhook-signing-secret`.
  * `CODE_OPS_DEBT.md` Theme G row 2: webhook signature verifiers were
  receiving an OAuth bearer token instead of an HMAC signing secret,
  so no real vendor's signed webhook ever validated.
  * CLAUDE.md Hard Promise #7 — F&F holds all provider keys
  server-side. The webhook signing secret is a separate provisioning
  artifact distinct from the OAuth bearer; storing them in the same
  column is a category error.
  * `lib/services/integration/repository_inbound_webhook_gateway.dart`
  `lookupSigningSecret` previously read `access_token_ciphertext`;
  the matching read-path patch in this slice points at the new
  column.

  Why a new column instead of overloading `access_token_ciphertext`:
  Every vendor with `webhookSupport != pollOnly` treats the webhook
  signing secret as a separate provisioning artifact. The OAuth
  bearer is required for outbound polling (we keep it as-is); the
  webhook signing secret is required for inbound HMAC verification.
  Conflating them broke verification for every real vendor — a
  bearer token is not an HMAC key.

  Affected vendors (each must have this column populated via the
  credential rotation runbook before signed webhooks validate):

  POS:
  * `toast`             — HMAC-SHA256 over raw body; per-vendor
  webhook secret minted in Toast partner
  portal under `Webhooks` tab.
  * `square`            — HMAC-SHA256; webhook signature key
  (separate from OAuth bearer) minted in
  Square Developer Dashboard per webhook
  subscription.
  * `clover`            — HMAC-SHA256; per-app static secret from
  Clover Developer Dashboard webhook
  config.
  * `revel`             — HMAC-SHA256; per-establishment webhook
  secret minted in Revel admin portal.
  * `lightspeed_lsk`    — HMAC-SHA256; per-account webhook secret
  from Lightspeed K-Series partner portal.
  * `aloha_ncr_voyix`   — HMAC-SHA256; hub-shared secret from
  NCR Voyix Aloha hub configuration.
  Labor:
  * `adp`               — HMAC-SHA256; per-app webhook secret from
  ADP Marketplace partner console.
  * `seven_shifts`      — HMAC-SHA256; account-scoped webhook
  signing secret minted in 7shifts admin.
  Reservation:
  * `libro`             — HMAC-SHA256; per-app static webhook
  secret from Libro partner portal.
  * `opentable`         — HMAC-SHA256; per-restaurant webhook
  secret from OpenTable for Restaurants
  admin (separate from API OAuth bearer).
  * `sevenrooms`        — HMAC-SHA256; per-venue webhook secret
  pasted into SevenRooms admin (manualPaste
  flow — operator copies the F&F webhook URL
  into the SevenRooms console and the
  vendor mints the matching signing key).
  * `tock`              — HMAC-SHA256; per-app static secret pasted
  into Tock admin alongside the F&F webhook
  URL (manualPaste flow).

  The values themselves are operator-staged at rotation time via the
  runbook documented in
  `runbooks/admin_provider_credentials_kms_rollout_runbook.md`
  ("Provision A Vendor Webhook Signing Secret"). The runbook references
  each vendor's spec doc under `docs/integrations/<vendor>/webhook_signature.md`.

  Posture:
  * Column is **NULL-allowed** so the migration applies cleanly on
  existing rows. No row backfill — the runbook supplies values per
  vendor, per operator, on schedule.
  * The repository read path returns NULL when the column is NULL,
  and the inbound webhook handler **fails closed** (rejects the
  webhook with 403 "no signing secret on file") rather than
  skipping verification.
  * `access_token_ciphertext` is **kept as-is** — it is still used
  for OAuth bearer auth on outbound polling.

  Time guardrails (CLAUDE.md / 7.55 Rule 11):
  No new timestamp columns. Existing `updated_at` on
  `vendor_credentials` records when the secret last rotated.

  RLS posture:
  The existing `vendor_credentials_per_tenant` policy on
  `public.vendor_credentials` already covers the new column — RLS
  evaluates row-level access, not column-level. No policy change.

## `202605080600_phase_8_demo_pending_counter_persisted.sql`

- **Applied:** 2026-05-08 06:00
- **Title:** phase 8 demo pending counter persisted
- **Description:**

  Phase 8 / A2 fix — persist demo-mode pending-insert counter so that the
  flip evaluation is race-safe across multiple pods.

  Problem (A2):
  Each POS sink held an in-memory `_pendingInsertsByTenant` map.  The
  watermark write committed inside `withTenant`, then the counter read
  and `evaluateDemoFlip` call ran OUTSIDE the transaction.  Two failure
  modes:
  (a) a throw inside `evaluateDemoFlip` after the watermark committed
  left the operator stuck in demo mode;
  (b) multi-pod deployments double-counted and double-fired the flip.

  Fix:
  Add `pending_inserts_count` to `demo_mode_state`.  Each upsert
  increments the counter inside the same `withTenant` transaction as the
  cover-facts row.  The watermark writer reads the counter with
  `SELECT … FOR UPDATE` and, if it is >= 1 and `is_demo = true`, flips
  atomically (resetting `pending_inserts_count = 0`) — all in one
  transaction.  The in-memory map is removed from every sink.

  Migration is replay-safe: `ADD COLUMN IF NOT EXISTS` is idempotent.

## `202605080600_phase_8_idempotency_location_id_rekey.sql`

- **Applied:** 2026-05-08 06:00
- **Title:** phase 8 idempotency location id rekey
- **Description:**

  Phase 8 — Vendor idempotency key hardening: add location_id to the
  four fact-table partial UNIQUE indexes and to the
  inbound_webhook_idempotency UNIQUE index.

  ─── WHY ─────────────────────────────────────────────────────────────
  The previous indexes keyed on
  (operator_id, vendor_id, vendor_entity_id, vendor_modified_at).
  Two bugs follow:

  1. Multi-location data loss: Two locations under one operator can
  share a `vendor_entity_id` (Toast check-id reuse, multi-store
  POS).  The second location's write silently no-ops because the
  index fires on the FIRST location's row — the conflict trips
  before the engine can compare location_id.

  2. Late-backfill shadows newer corrections: vendor_modified_at was
  part of the key, so an older-timestamped correction
  (vendor_modified_at < stored) inserted a NEW row rather than
  being blocked or updating.  The "closed truth never rewritten"
  promise was violated.

  Fix:
  * Add location_id to every fact-table idempotency key so same-
  entity, different-location rows coexist.
  * Drop vendor_modified_at from the key.  It now lives in the
  upsert WHERE clause (`WHERE excluded.vendor_modified_at >=
  public.<fact>.vendor_modified_at`) so older arrivals are
  rejected, newer arrivals update in-place.

  ─── PATTERN ─────────────────────────────────────────────────────────
  CONCURRENTLY index ops cannot run inside a transaction block; each
  DROP/CREATE below runs in its own implicit per-statement transaction
  so live writers see neither a long lock nor a window without an
  index.  Re-applying is a no-op: every IF EXISTS / IF NOT EXISTS
  guard makes subsequent runs safe. Pattern mirrors
  db/migrations/202605061500_hardening_phase_8_email_index_leading_column_rekey.sql.

  ─── 1. shift_records_vendor_idempotency_idx ─────────────────────────

## `202605080700_audit_anchor_cron_unpause.sql`

- **Applied:** 2026-05-08 07:00
- **Title:** audit anchor cron unpause
- **Description:**

  Code-Health Lane M3 / L9 — unpause the forge_audit_anchor_daily cron job.

  Context:
  Migration `202605061700_hardening_audit_anchor_daily_schedule.sql`
  registered the `forge_audit_anchor_daily` pg_cron job with schedule
  `'0 2 * * *'` and `active = true`. However the Cloud Scheduler
  trigger `forge-flow-audit-anchor-daily` was left PAUSED (per the
  punchlist §5 note in `docs/_execution/2026-05-05_v1_launch_punchlist.md`).
  Code-Health Lane L9 wires the advisory lock guard and the Azure Blob
  daily write in the Cloud Run binary; this migration ensures the
  in-DB pg_cron job is active and on the expected schedule so the
  daily cadence is verifiable from inside Postgres
  (`cron.job_run_details`) regardless of Cloud Scheduler state.

  Azure DB Flexible Server note:
  Azure DB Flexible Server does NOT expose `cron.alter_job()` — the
  extension ships without that helper. The only supported mutation
  path is a direct UPDATE on `cron.job` (table-level write) inside
  the cron database. This migration does a direct UPDATE; the guard
  first checks that the table exists in this database.

  Replay-safe:
  The DO block checks whether `cron.job` is present and whether the
  target row exists before touching anything. Re-running on a host
  where it has already applied is a clean no-op (the UPDATE is
  idempotent). A NOTICE is raised instead of an ERROR when pg_cron
  metadata is not in this database so the migration does not block
  batch application on the app database (Azure keeps pg_cron metadata
  in the database named by `cron.database_name`, typically `postgres`).

  Authority:
  * `docs/_execution/2026-05-05_v1_launch_punchlist.md` §5
  * `db/migrations/202605061700_hardening_audit_anchor_daily_schedule.sql`
  (the original schedule registration that left active=true; this
  migration is a belt-and-suspenders unpause for the code-lane
  graduation).
  * `docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`
  — "Audit-anchor cadence is paused" finding.

  Verification SQL (run in the cron database, typically `postgres`):

  select jobname, schedule, active, command
  from cron.job
  where jobname = 'forge_audit_anchor_daily';
  -- expected: schedule = '0 2 * * *', active = true

## `202605080800_auth_permission_version.sql`

- **Applied:** 2026-05-08 08:00
- **Title:** auth permission version
- **Description:**

  B1.A1 — permission_version column on users.

  A3 audit finding: admins keep API access for ~5 minutes after a
  permission revoke because the live JWT is still valid and the proxy
  does not compare a DB-side freshness stamp to the token claim.

  Fix: add `permission_version INTEGER NOT NULL DEFAULT 0` to `users`.
  Every grant/revoke path increments this column; the proxy auth-
  middleware compares the JWT claim `permission_version` against the
  DB on every request. On mismatch → 401.

  Replay-safe: `ADD COLUMN IF NOT EXISTS` + re-entrant default.

  2026-05-13 audit carve-out (PR #481 retroactive audit Finding #M1):
  the functional index below was rewritten in-place during PR #481
  (changed from `(user_id, permission_version)` to
  `(operator_id, user_id, permission_version)`) to satisfy CLAUDE.md
  HP #4 leading-column rule. Migrations are normally immutable once
  applied; the in-place rewrite is acceptable here because the operator
  verified 2026-05-13 that this migration had NOT been applied to
  staging or Production1 at the time of the rewrite (it was still in
  the "code-ready" pending-apply queue per
  `docs/POST_HARDENING_FOLLOWUPS.md`). Future migrations MUST follow
  the expand-contract pattern (new migration drops + recreates the
  index) once the migration has been applied anywhere downstream.
  See `docs/archive/_audits/post_codex_wave/pr_481_retroactive_audit.md` for
  the full rationale.

## `202605080900_oauth_refresh_advisory_lock.sql`

- **Applied:** 2026-05-08 09:00
- **Title:** oauth refresh advisory lock
- **Description:**

  B2 async race fix — OAuth refresh advisory lock registry entry.

  Findings reference: J4 — two Cloud Run pods both notice
  `token_expires_at < now() + 24h` for the same (operator_id,
  vendor_id) and both call the vendor's token endpoint; some
  vendors auto-revoke the earlier token on a second refresh,
  causing the first pod's subsequent API calls to 401.

  Fix: wrap the per-(operator, vendor) refresh call in
  `pg_advisory_xact_lock(<id>, hashtextextended(...))`. The lock
  is transaction-scoped so it releases automatically on commit or
  rollback — no explicit unlock needed.

  This migration seeds the lock-id constant into the same
  `audit_anchor_advisory_locks` constants table created by
  `202605070200_audit_anchor_advisory_lock_infra.sql`.
  That migration created the table; we only add a row here.

  Lock id `8472002` is the next slot after the audit_anchor_sweep
  id (`8472001`) from the infra migration. Both are deliberately-
  distinctive integers in the low-8-digit range; collision with a
  hashtext()-derived key is astronomically unlikely.

  Authority:
  * `db/migrations/202605070200_audit_anchor_advisory_lock_infra.sql`
  (table creation + precedent for the pattern).
  * `lib/services/integration/oauth_refresh_cron.dart`
  (the runner that acquires this lock per (operator, vendor)).

  Replay-safe: ON CONFLICT DO NOTHING makes re-running idempotent.

## `202605081000_outbox_notify_channel_split.sql`

- **Applied:** 2026-05-08 10:00
- **Title:** outbox notify channel split
- **Description:**

  Phase B6 (performance hardening, PF5) — NOTIFY channel split for per-category
  listener fanout.

  Current state (Phase 9.0Σ.e):
  * All event_outbox rows fire NOTIFY on a single 'event_outbox' channel.
  * The Phase 10a bridge worker LISTEN on 'event_outbox' and claims all rows
  regardless of topic.

  This slice:
  * Splits the trigger so NOTIFY fires on a per-category channel based on
  the row's `topic` prefix (e.g. 'pos.*' → 'event_outbox_pos',
  'labor.*' → 'event_outbox_labor', etc.).
  * Keeps the legacy 'event_outbox' channel as a fallback so a listener
  that only LISTEN on the original channel continues to receive all events.
  * Updates PackagePostgresOutboxListener to LISTEN on all four category
  channels + the legacy channel so no events are lost.

  Topic-to-channel mapping (locked in docs/contracts/event_outbox_contract.md):
  * 'pos.*'         → 'event_outbox_pos'
  * 'labor.*'       → 'event_outbox_labor'
  * 'reservation.*' → 'event_outbox_reservation'
  * 'admin.*'       → 'event_outbox_admin'
  * All others      → 'event_outbox' (fallback)

## `202605081100_partman_maintenance_hourly_cron.sql`

- **Applied:** 2026-05-08 11:00
- **Title:** partman maintenance hourly cron
- **Description:**

  CODE_OPS_DEBT — Theme C #6 — register the hourly partman_maintenance
  pg_cron job.

  Context:
  `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql` set up
  `pg_partman` daily range partitioning on `public.audit_logs` and
  noted in a comment that the maintenance call should run hourly via
  `cron.schedule('partman_maintenance', '0 * * * *',
  $$SELECT public.run_maintenance(p_analyze := true)$$)`. The
  schedule was never registered. Without it `audit_logs` partitions
  stop being created ahead of the producer (the `daily premake` of 7
  buffers a week, but eventually exhausts) and detached partitions
  never get pruned.

  Azure DB Flexible Server topology:
  Azure keeps `pg_cron` metadata in the database named by
  `cron.database_name` (typically `postgres`). Application databases
  call `cron.schedule_in_database(...)` to register from outside the
  metadata database, OR the migration runs INSIDE the cron database.
  This migration is split-safe: a `to_regnamespace('cron') is null`
  guard at the top emits a NOTICE and exits cleanly when applied to
  a database without the cron schema, so the same SQL ships against
  every environment without environment-specific hand-edits.

  Replay-safe:
  The DO block deletes any pre-existing job with the same name before
  inserting the new schedule, so re-running the migration is
  idempotent. The schedule is fixed at `0 * * * *` (top of every
  hour) — the comment in 202604280005 pinned the cadence and the
  constants in `phase_9_scalability_decisions_2026-04-27.md` lock it.

  Authority:
  * `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`:38-46
  (the original TODO comment)
  * `CODE_OPS_DEBT.md` Theme C row 6 — partman maintenance is a
  comment-only TODO; this migration retires the row.
  * `runbooks/admin_provider_credentials_kms_rollout_runbook.md` —
  references `pg_partman` daily partitioning for audit_logs.

  Verification SQL (run in the cron database, typically `postgres`):

  select jobname, schedule, active, command
  from cron.job
  where jobname = 'partman_maintenance';
  -- expected: schedule = '0 * * * *', active = true,
  --           command = 'select public.run_maintenance(p_analyze := true);'

## `202605081300_seed_kms_rollout_flags_default_disabled.sql`

- **Applied:** 2026-05-08 13:00
- **Title:** seed kms rollout flags default disabled
- **Description:**

  Staging proxy startup unblock — idempotently seed the four KMS
  rollout feature-flag rows that the admin schema contract requires.

  Background
  ----------
  The original `202605020200_phase_11A_4c_kms_rollout_flags.sql`
  migration seeded the four `kms_real_provider_<lane>_enabled`
  rows with `INSERT ... ON CONFLICT DO NOTHING`. At that time
  `feature_flags.operator_id` was nullable and global-scope rows
  carried `operator_id IS NULL`; uniqueness was enforced by the
  partial unique index `feature_flags_global_scope_idx (flag_name)
  WHERE operator_id IS NULL AND location_id IS NULL`.

  Then `202605072000_feature_flags_sentinel_operator.sql` introduced
  the system-wide sentinel UUID (`00000000-…-000000000000`),
  backfilled every NULL `operator_id` row to the sentinel, made the
  column NOT NULL, and dropped the global-scope partial unique
  index in favor of `feature_flags_operator_scope_idx (flag_name,
  operator_id) WHERE operator_id IS NOT NULL AND location_id IS
  NULL`. The startup contract in
  `tool/advisor_proxy/advisor_proxy.dart::AdminProxySchemaContractVerifier`
  now scopes its existence check to
  `operator_id = public.feature_flag_system_wide_operator_id() AND
  location_id IS NULL`.

  On staging (`forge-flow-staging-proxy` rev 00069) the four rows
  were absent from `public.feature_flags` at startup, the contract
  verifier surfaced
  row:public.feature_flags.kms_real_provider_anthropic_enabled
  row:public.feature_flags.kms_real_provider_azure_db_enabled
  row:public.feature_flags.kms_real_provider_gemini_enabled
  row:public.feature_flags.kms_real_provider_voyage_enabled
  and the proxy exited 78. Cloud Run auto-rolled back to rev 68
  (which started before the contract tightened around the sentinel
  shape).

  Fix shape
  ---------
  This migration idempotently seeds the four rows at the system-wide
  sentinel scope with `enabled = false` (the production-shaped
  default — every lane stays on `KmsStubProvider` until an operator
  flips the row to ON via the 11A.7 admin Feature Flags screen). It
  mirrors the original 11A.4c semantics, just rebased onto the
  post-sentinel schema.

  The `kind = 'destructive'` classification on these rows is owned
  by `202605020400_phase_11A_7_feature_flags_admin_columns.sql`
  (the post-launch reclassification UPDATE there is `kind <>
  'destructive'`-guarded so an operator override survives). This
  seed only writes the row identity columns (`flag_name`,
  `operator_id`, `location_id`, `enabled`) and lets the kind /
  description / updated_by fields fall back to their column
  defaults — the 11A.7 reclassification migration will idempotently
  promote these rows on its next apply if they were not present
  when it last ran.

  Authority order
  1. CLAUDE.md "Proxy & API Conventions" — every proxy write is
  idempotent.
  2. `202605072000_feature_flags_sentinel_operator.sql` — the
  sentinel UUID + reader function this seed uses.
  3. `202605020200_phase_11A_4c_kms_rollout_flags.sql` — original
  seed, now superseded by this one.
  4. `tool/advisor_proxy/advisor_proxy.dart::AdminProxySchemaContractVerifier`
  — the startup contract this seed satisfies.

  Idempotency
  * `WHERE NOT EXISTS` guards each row against duplicate inserts.
  Plain `ON CONFLICT (operator_id, location_id, flag_name)` is
  not available because the post-sentinel uniqueness target is
  a partial unique index (`feature_flags_operator_scope_idx`),
  not a named constraint, and `NULL` `location_id` does not
  compare equal under `ON CONFLICT` semantics in any case.
  * The seed never touches rows that already exist — an operator
  override (`enabled = true` after a lane flip via the 11A.7
  admin screen) survives migration replays unchanged.

## `202605082000_user_pii_erasure_requests.sql`

- **Applied:** 2026-05-08 20:00
- **Title:** user pii erasure requests
- **Description:**

  CODE_OPS_DEBT Theme B#1 — single-admin PII erasure with 24h reverse window.

  Background:
  Phase 11A.14 wired `admin.users.erase_pii` (MFA-required) and the
  "Issue erasure" button on `audited_support_actions_admin_screen`,
  but the proxy POST route never landed. The frontend button calls a
  404. Per the operator decision register (2026-05-08):
  * Single-admin action — paired approval is overkill at launch.
  * Fresh-MFA gate — admin must have authenticated MFA within 1h.
  * 24h grace-window reversal.
  * Scope = PII fields ONLY (display name, email, phone, avatar
  URL). Audit log rows referencing user_id are NOT cascaded —
  the user row remains; the PII columns are NULLed.

  This migration creates the durable request ledger. The proxy route
  writes one row per erasure request, captures a JSON snapshot of the
  pre-erasure PII so reversal can restore it, and the grace-window
  worker (`PiiErasureWorker`) runs after `grace_period_ends_at` to
  apply the actual NULL-out on `public.users` and wipe the snapshot.

  Hard rules carried from CLAUDE.md / contracts:

  1. Operator-scoped fact table → leading `operator_id` on every
  B-tree index, RLS policy stub from creation
  (`operator_pii_erasure_requests_per_user`), denormalized
  `business_date DATE` per the Phase 8 time-boundary contract.
  2. Postgres role grants follow the same shape as
  `mfa_factor_removal_requests`: runtime gets full DML
  (`service_role`, `forge_admin`); cron-driven sweep uses
  `forge_admin` BYPASSRLS.
  3. Grace window default = 24h; configurable via the
  `PII_ERASURE_GRACE_PERIOD_SECONDS` env var read by the proxy.
  Schema CHECK (`grace_period_ends_at >= requested_at`) just
  enforces "non-negative window"; the policy length lives in app
  code so a hot-fix does not require a new migration.
  4. `pii_snapshot` is `JSONB NOT NULL`. Once the worker applies the
  erasure, it overwrites the snapshot with `'{}'::jsonb` so PII
  does not linger in the archive past the grace window.
  5. Per-row uniqueness is `(operator_id, user_id)` partial on
  pending rows — at most one in-flight erasure per user. A
  reversed or applied row drops out of the partial index so a
  subsequent erasure can be issued for the same user.
  6. pg_cron sweep ticker emits `pii_erasure_grace_expired_tick` on
  a `*/1 * * * *` schedule. The Dart worker LISTENs and calls
  `PiiErasureRepository.applyDuePending` which UPDATEs `users`
  atomically with the request row's `applied_at` stamp.

## `202605082100_phase_10a_3_retention_sweep_in_db_followup.sql`

- **Applied:** 2026-05-08 21:00
- **Title:** phase 10a 3 retention sweep in db followup
- **Description:**

  Phase 10a.3 — bounded retention sweep, Azure split-DB schedule
  follow-up.

  Context:
  `db/migrations/202605050200_phase_10a_3_event_outbox_retention.sql`
  shipped the original unbounded `event_outbox_retention_sweep()`
  function and a daily 09:00 UTC `forge_event_outbox_retention_sweep`
  cron entry; `db/migrations/202605051000_phase_10a_3_outbox_retention_sweep.sql`
  layered the bounded `run_event_outbox_retention_sweep()` function
  plus a 03:00 UTC `event_outbox_retention_sweep_daily` cron entry
  on top.

  Both prior schedule blocks gracefully bow out with a NOTICE when
  the migration runs against a database that does not host the
  pg_cron metadata. Azure DB Flexible Server pins pg_cron metadata
  to the database named in `cron.database_name` (typically
  `postgres`); the application schema (`forgeflow`) is a different
  database, so on Azure those NOTICEs were the live-apply outcome
  and the schedules were never registered. The bounded sweep
  relied on an out-of-band manual step that was easy to miss.

  What this migration does:
  1. From the `cron.database_name` (where pg_cron lives), DELETE
  any prior `forge_event_outbox_retention_sweep` row (the
  legacy unbounded daily cron from the first migration). The
  bounded path supersedes it; leaving both around would cause
  two writers fighting for the same delivered-rows window.
  2. Then DELETE-then-INSERT the bounded
  `event_outbox_retention_sweep_daily` schedule via
  `cron.schedule_in_database('event_outbox_retention_sweep_daily',
  '0 3 * * *', '...', 'forgeflow')` so the sweep call runs in
  the application database where the function lives.

  Idempotent. Re-running this migration deletes the rows again, then
  re-INSERTs the bounded entry.

  Topology guards:
  * pg_cron in this DB → run the DELETE-then-INSERT here.
  * pg_cron in a different DB → emit a NOTICE (the migration is
  intended to be applied from the cron database; the
  `forgeflow` application database does not host the metadata).

  Why "_in_database":
  `cron.schedule()` queues the command against the same database
  as the caller, which would route the SELECT into the metadata
  database where `public.run_event_outbox_retention_sweep()` does
  not exist. `cron.schedule_in_database(jobname, schedule,
  command, database)` pins the per-tick connection to the named
  database so the function call resolves correctly.

  Hard rules carried from CLAUDE.md and the contract:

  1. The bounded sweep MUST NOT touch un-delivered rows; this
  migration only changes how the schedule is registered, not
  what runs. The bounded function from
  `202605051000_phase_10a_3_outbox_retention_sweep.sql` keeps
  the predicate.

  2. The schedule cadence stays `0 3 * * *` per the prior
  migration. Changing it requires a paired update there.

  3. The DELETE leg is bounded by `jobname` so the migration cannot
  accidentally evict an unrelated job.

  Live apply:
  Apply against the database named in `cron.database_name` (Azure:
  typically `postgres`). The migration emits NOTICEs that the
  deploy verification log can grep for to confirm the legacy
  schedule was removed and the bounded schedule was re-registered
  under `cron.schedule_in_database`.

  Authority:
  * `db/migrations/202605050200_phase_10a_3_event_outbox_retention.sql`
  — function `public.event_outbox_retention_sweep` + the
  legacy unbounded daily schedule.
  * `db/migrations/202605051000_phase_10a_3_outbox_retention_sweep.sql`
  — function `public.run_event_outbox_retention_sweep` + the
  bounded 03:00 UTC schedule (in-database NOTICE only on Azure).
  * `docs/contracts/event_outbox_contract.md` — Retention.

## `202605082200_admin_hierarchy_lifecycle.sql`

- **Applied:** 2026-05-08 22:00
- **Title:** admin hierarchy lifecycle
- **Description:**

  Admin Hierarchy UX cleanup - hierarchy lifecycle columns and gates.

  Adds persisted suspend/delete state for Business Accounts hierarchy
  management. The route layer gates lifecycle actions with the two
  team.hierarchy.* permission keys seeded here.

## `202605121200_admin_hierarchy_scoped_data_polling.sql`

- **Applied:** 2026-05-12 12:00
- **Title:** admin hierarchy scoped data polling
- **Description:**

  Admin hierarchy scoped Data Accuracy and Polling Setup.

  Business Accounts is the command center: a Forge admin selects a
  business, org unit, or location, then writes setup settings at that
  exact scope. Existing per-location tables remain for operator self
  service and backward compatibility. The effective views below resolve
  location values with the most specific configured admin scope winning:
  scoped location, nearest org-unit ancestor, business scope, legacy
  per-location row, then defaults.

## `202605131000_admin_audit_log_actor_reason_contract.sql`

- **Applied:** 2026-05-13 10:00
- **Title:** admin audit log actor reason contract
- **Description:**

  Admin audit-log actor/reason contract.

  The original Phase 9 audit ledger shipped with the historical
  `user` / `service` actor_kind pair. The admin hierarchy and team parity
  contracts now need explicit human-friendly actor classes:
  `team_member`, `forge_admin`, and `service_principal`. Keep the legacy
  labels valid during the transition because existing non-admin writers still
  emit them, but require `admin_reason` on every forge_admin ledger row.

## `202605131010_admin_audit_logs_business_date.sql`

- **Applied:** 2026-05-13 10:10
- **Title:** admin audit logs business date
- **Description:**

  Admin audit-log business-date projection.

  The hash chain stays partitioned by UTC `chain_date`; this adds the
  operator-facing restaurant-local `business_date` required by the console
  parity contract. New writes populate it from location timing metadata in
  AuditLogsRepository. Existing rows backfill from `chain_date` because their
  original location timing cannot be reconstructed perfectly after the fact.

## `202605131020_admin_hierarchy_lifecycle_access_hardening.sql`

- **Applied:** 2026-05-13 10:20
- **Title:** admin hierarchy lifecycle access hardening
- **Description:**

  Admin hierarchy lifecycle/access hardening.

  The lifecycle column core landed in
  202605082200_admin_hierarchy_lifecycle.sql. This follow-up carries the
  non-superseded hardening:

  * creator/updater audit stamps for hierarchy/user rows
  * active-only org-unit path uniqueness after soft delete
  * direct location/org-unit grant lookup indexes for repository guards
  * user_effective_locations refresh logic for inactive hierarchy rows
  * refresh triggers when suspended_at or deleted_at changes

## `202605131030_b11_1_auth_handoff_codes.sql`

- **Applied:** 2026-05-13 10:30
- **Title:** b11 1 auth handoff codes
- **Description:**

  Lane B B11.1 — auth_handoff_codes table.

  Authority:
  * docs/archive/_execution/lane_b_features/03_execution_slices.md
  ("B11.1 — handoff_codes table + endpoints")
  * docs/archive/_execution/lane_b_features/01_product_rule_and_ia.md
  (addendum A1: "Redemption-Code Handoff" — code never appears in
  a JWT-in-URL; mobile mints a one-time short-TTL opaque code that
  the web client redeems atomically against this table.)
  * CLAUDE.md "Hard Promises" #4 (per-operator isolation NON-NEGOTIABLE)
  * CLAUDE.md "RLS-Ready Schema" — operator-scoped fact tables include
  (operator_id, location_id) + RLS policy stub from creation; every
  fact-table B-tree index leads with operator_id; RLS policies use
  the four STABLE LEAKPROOF PARALLEL SAFE wrapper functions; bare
  current_setting() reads forbidden.
  * CLAUDE.md "Time Guardrails" — operator-scoped tables MUST use
  TIMESTAMPTZ. handoff codes are session-bucketed (NOT business-day-
  bucketed) so business_date denorm is intentionally out of scope.
  * docs/contracts/hardening_rls_and_repository_pattern_contract.md
  (wrapper-only RLS posture; SET LOCAL transaction-scoped tenant
  injection via OperatorScopedRepository.)

  Adds public.handoff_codes — one row per minted handoff code. Each row
  represents a mobile-side request to hand the active operator's session
  off to the web. The web client resolves the row by POSTing the opaque
  code to /v1/auth/handoff/redeem; the proxy's atomic UPDATE … RETURNING
  consumes the row (consumed_at = now()) and returns the resolved
  (user_id, operator_id, target_path) so the web can mint a fresh
  session for the same human. The opaque code never travels as a JWT,
  and the web client never sends it as a URL query parameter to the
  proxy — see addendum A1 above.

  Schema notes carried verbatim from the slice doc:
  * code text primary key — opaque, server-generated by gen_random_bytes(16)
  (pgcrypto). 22-char base64-url body provides ~128 bits of entropy
  so brute force inside the 60-second TTL is computationally
  infeasible.
  * 60-second TTL via expires_at = created_at + interval '60 seconds'.
  Enforced server-side by the redeem predicate
  (expires_at > now()); also enforced by the inline reaper running
  at the head of every mint (see auth_handoff_routes.dart).
  * source_device_fingerprint records the mobile device that minted
  the code so the audit row carries the originating device when
  the web later redeems. Optional (NULL allowed) — mobile clients
  that have not granted device-fingerprint capability still mint.

  Hard rules carried verbatim from CLAUDE.md / phase docs:

  * **HP #4 RLS-Ready Schema.** Table carries operator_id from
  creation; tenant-leading B-tree indexes; per-tenant RLS policy
  enabled at table-creation time using the wrapper function
  `app_current_operator()`. No bare current_setting() reads.
  * **Wrapper-only RLS posture (Phase 9.0Σ.b item 4).** Policy body
  calls public.app_current_operator(). The four wrapper functions
  are STABLE LEAKPROOF PARALLEL SAFE so the planner can fold them
  into index scans.
  * **Time guardrails.** All temporal columns are TIMESTAMPTZ.
  created_at, expires_at, consumed_at — all UTC instants, never
  wall-clock TIMESTAMP WITHOUT TIME ZONE.
  * **Idempotent migration.** if not exists on every CREATE,
  drop policy if exists before create policy. Re-applying the
  migration is a no-op.
  * **No client-side codes.** The opaque code is generated server-
  side by encode(gen_random_bytes(16), 'base64'), stripped of
  URL-unsafe characters by the application before storage. Clients
  never supply a candidate code.

  Operator approval gate: per CLAUDE.md "agent-led slices" — auth-
  critical, RLS-touching, schema-touching, and proxy-touching slices
  require explicit operator approval before merge regardless of audit
  verdict. This migration is one of the three artifacts that gate that
  approval.

## `202605131400_b11_2_auth_step_up_challenges.sql`

- **Applied:** 2026-05-13 14:00
- **Title:** b11 2 auth step up challenges
- **Description:**

  Lane B B11.2 — auth_step_up_challenges table.

  Authority:
  * docs/archive/_execution/lane_b_features/03_execution_slices.md
  ("B11.2 — RFC 9470 step-up challenge on sensitive routes")
  * RFC 9470 — OAuth 2.0 Step Up Authentication Challenge Protocol
  https://www.rfc-editor.org/rfc/rfc9470
  * CLAUDE.md "Hard Promises" #4 (per-operator isolation NON-NEGOTIABLE)
  * CLAUDE.md "RLS-Ready Schema" — operator-scoped fact tables include
  (operator_id, location_id) + RLS policy stub from creation; every
  fact-table B-tree index leads with operator_id; RLS policies use
  the four STABLE LEAKPROOF PARALLEL SAFE wrapper functions; bare
  current_setting() reads forbidden.
  * CLAUDE.md "Time Guardrails" — operator-scoped tables MUST use
  TIMESTAMPTZ.
  * docs/contracts/hardening_rls_and_repository_pattern_contract.md
  (wrapper-only RLS posture; SET LOCAL transaction-scoped tenant
  injection via OperatorScopedRepository.)
  * B11.1 precedent: 202605131030_b11_1_auth_handoff_codes.sql
  (mirrored idiom for opaque code/hash, TTL check constraint,
  operator-leading B-tree indexes, wrapper-only RLS, idempotent
  DDL).

  Adds public.auth_step_up_challenges — one row per emitted RFC 9470
  step-up challenge. A challenge is created when a caller hits a
  flagged sensitive route with a JWT whose `auth_time` (the
  `lastFreshAuthAt` claim in ProxyJwtClaims) is older than the
  route's required freshness window or whose `acr` does not meet the
  route's required acr level. The proxy returns 401 with a
  `WWW-Authenticate: Bearer error="insufficient_user_authentication",
  acr_values="<required>", max_age=<seconds>` header per RFC 9470 §4.
  The client (mobile or web) re-authenticates and replays with a
  fresher JWT. The proxy verifies the freshness/acr now meets the
  route's policy AND consumes the matching challenge row (marks
  `consumed_at`). Consumption is one-shot so a replay of the same
  challenge_id by a stolen device gets 410 Gone.

  Schema notes:
  * challenge_id text primary key — opaque, server-generated by
  gen_random_bytes(16) via pgcrypto. 22-char base64-url body
  gives ~128 bits of entropy. Matches the B11.1 idiom.
  * route_path stores the path the challenge was emitted on so the
  replay can be cross-checked: a challenge issued for
  `/v1/auth/password/change` cannot be replayed against
  `/v1/admin/auth/roles/...`. Length-bounded (1..256) to match
  the longest path constant in advisor_proxy.dart.
  * required_acr names the acr value the proxy demanded (today the
  only emitted value is `urn:mfa` per the slice doc; the column
  is text so future levels — e.g. `urn:mfa:totp` or
  `urn:mfa:webauthn` — can land without a migration).
  * required_freshness_seconds carries the route's freshness budget
  (today 300 s for password/mfa/role mutations per the slice doc;
  the per-route registry in tool/advisor_proxy/auth_step_up_routes.dart
  is the source of truth, the column persists the value that was
  in effect at challenge time for audit replay).
  * expires_at = created_at + interval (route's challenge_ttl).
  5-minute default; 15-minute hard ceiling (the CHECK below
  enforces the ceiling so a buggy emitter cannot mint a forever
  challenge).
  * consumed_at marks one-shot consumption; the redeem predicate
  (consumed_at IS NULL AND expires_at > now() AND
  route_path = $route) refuses replays.
  * source_actor_kind / source_actor_id records the caller that
  received the challenge so the audit reader can correlate
  "challenge issued" -> "challenge consumed" across two
  separate auth contexts when a service principal escalates.
  * source_device_fingerprint is the device that received the
  challenge (parallel to handoff_codes.source_device_fingerprint).

  Hard rules carried verbatim from CLAUDE.md / phase docs:

  * HP #4 RLS-Ready Schema. Table carries (operator_id, location_id)
  from creation; tenant-leading B-tree indexes; per-tenant RLS
  policy enabled at table-creation time using the wrapper function
  `app_current_operator()`. No bare current_setting() reads.
  * Wrapper-only RLS posture. Policy body calls
  public.app_current_operator(). The four wrapper functions are
  STABLE LEAKPROOF PARALLEL SAFE so the planner can fold them into
  index scans.
  * Time guardrails. All temporal columns are TIMESTAMPTZ.
  created_at, expires_at, consumed_at — all UTC instants, never
  wall-clock TIMESTAMP WITHOUT TIME ZONE.
  * Idempotent migration. if not exists on every CREATE,
  drop policy if exists before create policy. Re-applying the
  migration is a no-op.
  * No client-side challenge_id. The opaque id is generated server-
  side via encode(gen_random_bytes(16), 'base64'), stripped of
  URL-unsafe characters by the application before storage.
  Clients never supply a candidate id.

  Service principal note (CLAUDE.md "Service principals"):
  * `actor_kind` taxonomy applies. Service principals (`sp:`-prefixed
  JWT subjects) MAY be subject to step-up rules in the future, but
  for V1 the policy in tool/advisor_proxy/auth_step_up_routes.dart
  SKIPS challenge emission when actor_kind == 'service_principal'
  because service principals do not have an interactive MFA flow.
  The column is still populated when a challenge IS issued (e.g.
  when a future policy admits SP step-up via mTLS reauth) so the
  audit reader can attribute the challenge.

  Operator approval gate: per CLAUDE.md "agent-led slices" — auth-
  critical, RLS-touching, schema-touching, and proxy-touching slices
  require explicit operator approval before merge regardless of audit
  verdict.

## `202605131500_b10_1_vendor_applicability.sql`

- **Applied:** 2026-05-13 15:00
- **Title:** b10 1 vendor applicability
- **Description:**

  B10.1 - vendor_applicability.

  One temporal, discriminated source for "which vendors can apply to
  setting X" across wage, covers, polling, and future setting kinds.
  Global F&F-admin defaults use operator_id = NULL; per-operator rows carry
  operator_id and are readable only through app_current_operator() RLS.

## `202605131500_b5_b_catalog_tri_mirror.sql`

- **Applied:** 2026-05-13 15:00
- **Title:** b5 b catalog tri mirror
- **Description:**

  B5.b - additive permission-key catalog rows for operator settings.

  Seeds the two settings keys that were previously hand-typed by
  Operator Web screens:

  * account.configure
  * business_timing.configure

  The rows mirror docs/contracts/auth_permission_key_catalog.md and
  lib/auth/permission_keys.dart. The migration is additive and
  idempotent: catalog inserts use ON CONFLICT (key) DO NOTHING and
  grant inserts use ON CONFLICT (role_id, permission_key) DO NOTHING.

  Grant posture:

  * super_admin gets both keys explicitly so the seeded role keeps
  the "every catalog key" invariant for keys added after 9.0.
  * operator_owner and operator_admin (when seeded) get both keys
  because the account and business-timing write surfaces are
  owner/admin-owned in the current Operator Web screens and
  operator-scoped write routes.
  * operator_manager, operator_supervisor, operator_staff, and
  ff_support do not receive these configure grants by default.

  Neither key requires MFA at the catalog level. Future route-level
  freshness gates can be added without changing the grantable key.

## `202605131550_benchmark_overrides_hierarchy.sql`

- **Applied:** 2026-05-13 15:50
- **Title:** benchmark overrides hierarchy
- **Description:**

  B6 - benchmark override hierarchy.

  Operator benchmark standards can be configured at the business,
  org-unit, or location scope. The effective value for a location is:
  location override, nearest ancestor org-unit override, operator-wide
  override, then the existing target-cycle/baseline value. This migration
  adds only the temporal override table; existing target_cycles and
  active_target_profiles remain untouched.

## `202605131600_b2_1_default_role_catalog_versions.sql`

- **Applied:** 2026-05-13 16:00
- **Title:** b2 1 default role catalog versions
- **Description:**

  Lane B B2.1 — default_role_catalog_versions table + operators pointer.

  Authority:
  * docs/archive/_execution/lane_b_features/03_execution_slices.md
  ("B2.1 — Default Role catalog schema + publish endpoint")
  * CLAUDE.md "Hard Promises" #4 (per-operator isolation NON-NEGOTIABLE)
  * CLAUDE.md "RLS-Ready Schema" — operator-scoped fact tables include
  (operator_id, location_id) + RLS policy stub from creation. THIS
  TABLE IS NOT OPERATOR-SCOPED — see "Why no RLS" below.
  * CLAUDE.md "Time Guardrails" — all temporal columns are TIMESTAMPTZ.
  * docs/contracts/hardening_rls_and_repository_pattern_contract.md
  (admin-pool BYPASSRLS posture for non-tenant tables; SET LOCAL
  ROLE forge_admin via TenantTransactionWrapper.runAsSystem.)
  * Precedent: 202604280004_phase_9_0sigma_d_service_principals.sql
  (operator-scoped catalog of admin actors) for the admin DML grants
  shape, and 202605131030_b11_1_auth_handoff_codes.sql for the
  idempotent DDL idiom.

  Why this exists
  ---------------
  The Default Role catalog is the F&F-wide "starter set" of role
  definitions every operator inherits at signup. Today this catalog is
  hard-coded in application code; F&F admins cannot rotate it without
  a deploy. B2.1 introduces a versioned catalog (publish-with-rollback)
  so admins can ship catalog updates without code deploys, and so we
  can audit who published which version with what blast radius.

  B2.2 (separate slice) ships the admin editor UI; this migration is
  the persistence shape only.

  Schema notes
  ------------
  * version_id uuid PK — server-generated by gen_random_uuid().
  * version_number int — monotonically incrementing per publish. The
  repository computes it via MAX(version_number)+1 inside the
  publish transaction; the partial unique index on is_current keeps
  a single row globally as the "current" version.
  * published_at timestamptz — UTC instant; never wall-clock.
  * published_by_user_id uuid — the F&F admin who issued the publish.
  References public.users(user_id) so deletion of the user account
  cascades to ON DELETE RESTRICT — we intentionally preserve audit
  attribution.
  * payload jsonb — serialized catalog (the role definitions array).
  Stored verbatim as published so a rollback is a byte-identical
  replay of an earlier version. CHECK: jsonb_typeof = 'array' so
  a malformed publish body cannot land.
  * payload_sha256 text — SHA-256 hex of canonical payload. Computed
  application-side at publish time and persisted so the audit row +
  downstream readers can verify the catalog they're looking at
  matches the published bytes. CHECK: 64-char lowercase hex.
  * is_current boolean — partial UNIQUE INDEX where is_current = true
  enforces "at most one current version globally" without a hand-
  written CHECK or trigger. New publishes flip the old current to
  false in the same transaction (see publishVersion in the repo).
  * superseded_at timestamptz nullable — stamped at the moment a
  newer version takes over. NULL while the row is current; a row
  that never publishes a successor never sets this column.
  * notes text nullable — admin-written rollout notes. Length-
  bounded (0..2000) to keep accidental log dumps out of the table.

  operators.default_role_catalog_version_id
  ------------------------------------------
  New nullable FK column on operators that pins a specific catalog
  version to that operator. NULL = "follow the latest published
  version" (the common case at PR-merge time, since no version has
  been published yet). When a version is pinned, the resolver
  (lib/infrastructure/persistence/postgres/repositories/roles_repository.dart)
  returns that version's payload regardless of subsequent publishes
  — the rollback path is "patch operators.default_role_catalog_version_id
  to the older version's id". ON DELETE SET NULL because deleting a
  catalog version is allowed (versions are content-addressed) but
  must not orphan the operators row.

  Why no RLS on default_role_catalog_versions
  -------------------------------------------
  This is a GLOBAL F&F-wide catalog table — NOT an operator-scoped
  fact table. CLAUDE.md "RLS-Ready Schema" mandates operator-scoped
  fact tables ship with RLS policy stubs from creation; this table
  has NO operator_id column and is read by every operator through
  the resolver. The defense-in-depth posture is:

  * The admin-pool runtime (service_role + forge_admin) is the only
  identity that reads/writes this table. The repository (see
  default_role_catalog_versions_repository.dart) routes every call
  through TenantTransactionWrapper.runAsSystem so the connection
  carries `SET LOCAL ROLE forge_admin` for the lifetime of the
  transaction.
  * Grants below explicitly REVOKE all from public, GRANT SELECT to
  service_role (so the resolver can read the current catalog from
  a tenant transaction without elevating), and GRANT full DML to
  forge_admin (so the admin publish path can mutate).
  * Operator-scoped readers never need to filter by operator_id on
  this table because there is no operator_id column to filter on
  — the catalog is the same for everyone. The per-operator pin is
  `operators.default_role_catalog_version_id`, which is enforced
  by the existing per-operator RLS regime on the operators table
  (we do NOT touch that regime here).

  Idempotency
  -----------
  All DDL is idempotent (if not exists on every CREATE, drop policy if
  exists before create policy, alter table … add column if not exists).
  Re-applying the migration is a no-op.

  Lock + timeout guardrails
  -------------------------
  The ALTER TABLE on `operators` takes an ACCESS EXCLUSIVE lock
  briefly. We bound the wait so a hot tenant pool does not stall
  behind us.

  Operator approval gate
  ----------------------
  Per CLAUDE.md "agent-led slices" — schema-touching slices require
  explicit operator approval before merge regardless of audit verdict.
  This migration is the schema artifact that gates that approval.

## `202605131700_c_1a_email_event_provider_id.sql`

- **Applied:** 2026-05-13 17:00
- **Title:** c 1a email event provider id
- **Description:**

  Lane C C-1a — email_event.provider_event_id + partial UNIQUE INDEX.

  Authority:
  * docs/_indices/WAVE_EXECUTION_LEDGER.md row C-1a (line 82) —
  prep migration for SendGrid Event Webhook idempotency; operator
  Path A pick 2026-05-13.
  * docs/archive/_execution/lane_c_parity/03_execution_slices.md "Slice C-1
  — SendGrid Event Webhook receiver" (line 9-29) — the receiver
  relies on Postgres-enforced uniqueness for duplicate-event
  rejection via ON CONFLICT DO NOTHING.
  * CLAUDE.md "RLS-Ready Schema" — email_event is operator-scoped
  via FK join through email_outbox.operator_id. This migration
  does NOT change that RLS posture: no new policy, no new
  operator_id column, no GRANT changes.
  * CLAUDE.md "Time Guardrails" — temporal columns elsewhere stay
  TIMESTAMPTZ; the new column is text (provider-issued opaque
  identifier), so no time policy applies.
  * Precedent: 202605131600_b2_1_default_role_catalog_versions.sql
  for header/comment shape, lock+timeout guardrails, idempotent
  DDL idiom, and operator approval gate phrasing.
  * Precedent: 202605131030_b11_1_auth_handoff_codes.sql for the
  idempotent CREATE TABLE / CREATE INDEX IF NOT EXISTS idiom.
  * Existing email_event creation:
  202605040200_phase_9_8_email_provider.sql lines 301-344. Read
  in full before this migration; the table already carries
  event_id (UUID PK, F&F-side surrogate) and provider_message_id
  (SendGrid X-Message-Id, per-email NOT per-event). Neither
  stores SendGrid's per-event sg_event_id.

  Why this exists
  ---------------
  Slice C-1 (SendGrid Event Webhook receiver) needs Postgres-enforced
  dedupe on SendGrid's per-event sg_event_id so a re-delivered batch
  is a no-op rather than a duplicate row. The current email_event
  table has no column to hold sg_event_id:

  * event_id is gen_random_uuid() — an F&F-side surrogate, NOT a
  place to store a vendor-supplied event identifier.
  * provider_message_id holds SendGrid's X-Message-Id (one value
  per outbound email, NOT per event). Multiple webhook events
  for the same email share the same provider_message_id.

  Operator picked Path A 2026-05-13: "ship now while there's zero
  SendGrid traffic to worry about, so the first live operator's
  first email lands against an already-indexed table." This is a
  pure additive expand. C-1 will follow as a separate slice and
  write the receiver against this column.

  Schema notes
  ------------
  * provider_event_id text NULL — opaque SendGrid sg_event_id (or
  any future provider's per-event identifier). NULLABLE for
  back-compat with rows that pre-date this migration and for
  non-SendGrid-sourced events that never carry a per-event id.
  New SendGrid-sourced rows are expected to populate this column
  non-null; the receiver enforces that application-side.

  * Partial UNIQUE INDEX
  email_event_provider_event_id_unique
  ON public.email_event (provider_event_id)
  WHERE provider_event_id IS NOT NULL

  The WHERE clause is load-bearing. A full UNIQUE INDEX (or
  UNIQUE constraint) would forbid multiple NULL rows because
  Postgres treats NULLs as distinct in non-partial unique
  indexes only on b-tree default semantics — historically
  ambiguous and dependent on `NULLS NOT DISTINCT`. Pinning the
  predicate WHERE provider_event_id IS NOT NULL makes the
  intent explicit: dedupe enforced on populated rows only,
  historic + non-SendGrid rows freely coexist.

  C-1's receiver writes:
  INSERT INTO public.email_event (..., provider_event_id, ...)
  VALUES (..., $sg_event_id, ...)
  ON CONFLICT (provider_event_id) DO NOTHING;
  The partial UNIQUE INDEX backs that ON CONFLICT clause.

  Why no RLS change
  -----------------
  email_event already has RLS enabled with policy
  "email_event_per_tenant_select" (202605040200 line 326). The policy
  filters via EXISTS join through email_outbox.operator_id, so
  email_event itself carries no operator_id column. Adding
  provider_event_id does not affect that posture: the column is a
  vendor identifier scoped to the same row, not a cross-tenant
  discriminator. No new policy is required. No grants change
  (existing GRANT SELECT, INSERT on email_event to service_role /
  forge_admin already covers the new column under PostgreSQL's
  table-level grant semantics).

  Idempotency
  -----------
  ADD COLUMN IF NOT EXISTS + CREATE UNIQUE INDEX IF NOT EXISTS make
  this migration safe to re-apply. The COMMENT ON COLUMN replays
  harmlessly. No DROP, no DELETE, no ALTER COLUMN TYPE.

  Lock + timeout guardrails
  -------------------------
  ALTER TABLE … ADD COLUMN briefly takes ACCESS EXCLUSIVE on
  email_event. We bound the wait so a hot dispatcher cannot stall
  behind us. Adding a NULLABLE column with no default in Postgres
  11+ is a metadata-only operation, so the actual lock window is
  microseconds; the timeouts are belt-and-suspenders. The partial
  UNIQUE INDEX is built inline (transactional). On a freshly-
  migrated database the table has zero rows, so the index build is
  effectively instant; even on a populated table the predicate
  IS NOT NULL touches only the populated subset.

  Operator approval gate
  ----------------------
  Per CLAUDE.md "agent-led slices" — schema-touching slices require
  explicit operator approval before merge regardless of audit
  verdict. Operator approved Path A 2026-05-13.

## `202605131800_c_7a_recovery_codes_viewed_at.sql`

- **Applied:** 2026-05-13 18:00
- **Title:** c 7a recovery codes viewed at
- **Description:**

  Lane C C-7a — mfa_factors.recovery_codes_viewed_at column for C-7
  ("Adaptive 2FA button"). Pure additive expand.

  Authority:
  * docs/_indices/WAVE_EXECUTION_LEDGER.md row C-7a (line 94) — prep
  migration unblocking Codex's C-7 ("Adaptive 2FA button"). Operator
  approved 2026-05-13 ("yes to all" on the open-decisions slate).
  * docs/archive/_execution/lane_c_parity/03_execution_slices.md "Slice C-7
  — Adaptive 2FA button" (line 145) — the My Account button state
  adapts from `(session.mfaEnrolled, factor_count,
  recovery_codes_viewed_at)`. That last column did not exist on
  master before this migration, so C-7 was data-contract-blocked.
  * CLAUDE.md "RLS-Ready Schema" — `mfa_factors` already has RLS
  posture from the auth schema foundation. This migration does
  NOT change that posture: no new policy, no new operator_id
  column, no GRANT changes.
  * CLAUDE.md "Time Guardrails" — restaurant-local timing wins for
  business-date facts; this column is a per-user audit timestamp
  (UTC) for the last time the user *viewed* their MFA recovery
  codes, not a business-date fact. `timestamptz` per the operator-
  scoped fact-table convention even though `mfa_factors` is keyed
  by `user_id` rather than `operator_id` (auth-scope identity table).
  * Precedent: 202605131700_c_1a_email_event_provider_id.sql for
  header/comment shape, lock+timeout guardrails, idempotent DDL
  idiom, and operator approval gate phrasing. C-7a mirrors C-1a's
  pattern verbatim: additive ADD COLUMN IF NOT EXISTS, NULLABLE,
  comment, zero RLS / GRANT changes.
  * Existing mfa_factors creation:
  202604250008_auth_schema_foundation.sql lines 243-255. Read in
  full before this migration; the table already carries
  enrolled_at, last_used_at, revoked_at, created_at, updated_at
  timestamps. None of those holds the "when did the user last view
  their recovery codes" semantic that the Adaptive 2FA button needs
  to distinguish "View recovery codes" (never viewed) from "Manage
  two-factor sign-in" (already viewed at least once).

  Why this exists
  ---------------
  Slice C-7 (Adaptive 2FA button) computes the My Account button label
  from three inputs:

  1. session.mfaEnrolled — already on master via session.
  2. factor_count        — already on master via `select count(*)
  from mfa_factors where user_id = $1 and
  revoked_at is null;`
  3. recovery_codes_viewed_at — MISSING from schema, model, gateway.

  C-7's slice spec names the column explicitly (line 145). Without it,
  the gateway has no source of truth for the "View recovery codes" vs
  "Manage two-factor sign-in" branch and the button collapses to a
  single label. Operator approved 2026-05-13 ("yes to all" on open
  decisions slate): ship the prep migration now while there's no live
  business + zero existing mfa_factors rows, so the first live operator's
  first MFA enrollment lands against an already-shaped table. Mirrors
  the C-1a → C-1 cadence (PR #599 → PR #611) verbatim.

  Schema notes
  ------------
  * recovery_codes_viewed_at timestamptz NULL — UTC timestamp of the
  most recent time the user viewed their MFA recovery codes. NULL
  means "never viewed" (the only state pre-launch; also the default
  for any historic row that lands during demo/dev seeding). New
  rows do not need to populate this column at enrollment time; the
  C-7 gateway writes `UPDATE mfa_factors SET recovery_codes_viewed_at
  = now() WHERE factor_id = $1` on the View Recovery Codes click.

  * No new index. The Adaptive 2FA button reads the column on a
  per-user point lookup that's already covered by the existing
  `mfa_factors_user_active_idx (user_id, factor_type) WHERE
  revoked_at is null` index. Adding a column that's not part of
  any query predicate or sort order does not require a new index.

  Why no RLS change
  -----------------
  mfa_factors already has its existing per-user RLS regime from
  202604250008_auth_schema_foundation.sql (and any later hardening
  migration that touches it). Adding recovery_codes_viewed_at does
  not affect that posture: the column is a per-row audit timestamp
  on the same row the existing policies already gate. No new policy
  is required. No grants change — Postgres table-level grants cover
  the new column under default privilege semantics.

  Idempotency
  -----------
  ADD COLUMN IF NOT EXISTS makes this migration safe to re-apply.
  The COMMENT ON COLUMN replays harmlessly. No DROP, no DELETE, no
  ALTER COLUMN TYPE.

  Lock + timeout guardrails
  -------------------------
  ALTER TABLE … ADD COLUMN briefly takes ACCESS EXCLUSIVE on
  mfa_factors. We bound the wait so a hot session-validate path does
  not stall behind us. Adding a NULLABLE column with no default in
  Postgres 11+ is a metadata-only operation, so the actual lock
  window is microseconds; the timeouts are belt-and-suspenders. On a
  freshly-migrated database the table has zero rows (no business
  live yet), so the apply is effectively instant.

  Operator approval gate
  ----------------------
  Per CLAUDE.md "Agent-led slices" — schema-touching slices require
  explicit operator approval before merge regardless of audit verdict.
  Operator approved 2026-05-13 ("yes to all" on open-decisions slate).

## `202605131900_c_2_d_vendor_sync_outage_state.sql`

- **Applied:** 2026-05-13 19:00
- **Title:** c 2 d vendor sync outage state
- **Description:**

  Lane C C-2-D — vendor_sync_outage_state (first-failure-of-outage detector).

  Authority:
  * docs/_indices/WAVE_EXECUTION_LEDGER.md row C-2-D (line 86) —
  wire `vendor_sync_error_alert` with a first-failure-of-outage
  detector; per-row email would spam on transients. Operator
  picked WIRE option (D) in the C-2 matrix.
  * docs/archive/_decisions/c_2_email_template_wire_or_delete_decisions.md
  — draft D rationale + outage-detector design. Operator picks
  section 2026-05-13.
  * CLAUDE.md "RLS-Ready Schema" — operator-scoped fact tables
  include (operator_id, location_id) + RLS policy stub from
  creation. Operator-leading B-tree index.
  * CLAUDE.md "Time Guardrails" — operator-scoped Postgres fact
  tables store TIMESTAMPTZ (UTC). TIMESTAMP WITHOUT TIME ZONE
  banned in operator-scoped tables.
  * Precedent: 202605131700_c_1a_email_event_provider_id.sql for
  header/comment shape, lock+timeout guardrails, idempotent
  DDL idiom, and operator approval gate phrasing.
  * Precedent: 202605040000_phase_8_0_integration_framework.sql
  for the `(operator_id, location_id)` FK shape + per-tenant
  RLS policy posture used by sibling fact tables
  (`connector_sync_log`, `connector_sync_watermark`).

  Why this exists
  ---------------
  The `vendor_sync_error_alert` email template (Markdown source at
  `tool/advisor_proxy/email_templates/vendor_sync_error_alert.md`)
  promises in its body copy: "This alert fires once per outage." The
  polling tier (`tool/integration_sync_worker`) writes per-tick
  `connector_sync_log` rows with `event_kind = 'poll_error'` whenever
  a vendor adapter fails, but the log on its own has no notion of
  "outage windows" — a naive per-row email would spam the operator
  on every transient hiccup.

  This table is the state surface the outage detector uses to
  enforce "one email per outage". Per `(operator_id, location_id,
  connection_id)`:

  * `outage_started_at` — when the consecutive-failure streak
  that justified the email began (the timestamp of the FIRST
  `poll_error` in the streak, not the Nth that triggered the
  email).
  * `consecutive_failure_count` — how many consecutive
  `poll_error` rows have been observed since the last
  `poll_success`. Reset to 0 (row deleted) when a `poll_success`
  arrives.
  * `notified_at` — when the outage email was enqueued. NULL
  while the streak is being observed but has not yet crossed
  the N-failure threshold. Non-null after the email lands in
  `email_outbox`.
  * `last_error_message` — the most recent error message
  surfaced to the email body (`{{errorSummary}}` variable).

  The detector reads the latest `connector_sync_log` rows for the
  connection, walks them newest-first, and either:

  * Sees a `poll_success` before the N-th `poll_error` → no
  outage; clear any stale state row.
  * Sees N consecutive `poll_error` rows → there IS an outage.
  If no state row exists OR `notified_at IS NULL`, enqueue the
  email and stamp `notified_at`. If `notified_at IS NOT NULL`,
  the email has already been emitted for THIS outage window —
  no-op.

  Schema notes
  ------------
  * Primary key is `(connection_id)` because a vendor connection
  uniquely identifies the (operator, location, vendor, account)
  tuple; one outage window per connection at a time. operator_id
  + location_id are denormalised so the table is RLS-ready and
  the operator-leading B-tree index matches CLAUDE.md "every
  fact-table B-tree index leads with operator_id" rule.

  * `consecutive_failure_count` is `smallint` because the
  detector only cares whether the count crosses the threshold
  (N = 3 in the V1 detector). Values >> threshold are
  equivalent for decision-making and we never need to count
  above 32767.

  * No deletion-of-others FK to `connector_connection`: when a
  connection is deleted we want the cascade behaviour to clean
  this row up. Mirror the `connector_sync_log` ON DELETE
  CASCADE pattern.

  RLS posture
  -----------
  The detector runs from the integration_sync_worker, which already
  holds a `TenantTransactionWrapper` and writes
  `connector_sync_log` / `connector_sync_watermark` per tenant via
  `runInTenantContext`. The new table mirrors those siblings'
  per-tenant RLS policy verbatim. Email enqueue itself runs through
  `email_outbox` whose dispatcher uses `runAsSystem` (the operator
  column on `email_outbox` is nullable and indexed separately for
  the system fan-out path); the new state row updates always run
  under the tenant context the polling tick already established.

  Idempotency
  -----------
  CREATE TABLE IF NOT EXISTS + CREATE INDEX IF NOT EXISTS + DROP
  POLICY IF EXISTS / CREATE POLICY pattern make this migration
  safe to re-apply. The COMMENT ON COLUMN/TABLE replays harmlessly.
  No DROP, no DELETE, no ALTER COLUMN TYPE on existing tables.

  Lock + timeout guardrails
  -------------------------
  CREATE TABLE acquires ACCESS EXCLUSIVE briefly on the new
  relation only. We bound the wait so a concurrent migration
  cannot stall behind us. No existing table is touched.

  Operator approval gate
  ----------------------
  Per CLAUDE.md "agent-led slices" — schema-touching slices require
  explicit operator approval before merge regardless of audit
  verdict. Operator picked WIRE in C-2 matrix 2026-05-13 (recorded
  on master via PR #619 / decision doc operator picks section).

## `202605140000_w_3_self_profile_perm_key.sql`

- **Applied:** 2026-05-14 00:00
- **Title:** w 3 self profile perm key
- **Description:**

  Wave 2 W-3 — self-service profile editing permission key.

  Authority:
  * docs/_indices/WAVE_2_LEDGER.md Lane W row W-3 — self-service
  profile write paths (debug.md:45-52, P-1 / P-2 / P-3, MO-6c/d).
  * docs/contracts/auth_permission_key_catalog.md `team.*` table —
  this migration mirrors the new row.
  * lib/auth/permission_keys.dart `teamUsersSelfUpdate` constant —
  the runtime resolver iterates `PermissionKeys.all`; this row
  keeps the seed in lockstep.

  Why this exists
  ---------------
  The customer "My Account" surface (operator-web and admin) ships
  editable display name + email fields in W-3. The proxy route
  `PATCH /v1/auth/self/profile` gates on this new self-edit key.
  The slice deliberately AVOIDS widening `team.users.invite` (which
  gates admin-editing-someone-else) — self-edit is a distinct gate.
  Every signed-in operator role gets this key by default because
  anyone with a sign-in can update their own profile.

  Frozen + non-MFA: per the catalog doc, no `team.*` key is flagged
  MFA-required at the catalog level today. Route-level freshness for
  email change is layered on top via the existing fresh-MFA window
  the security section already enforces.

  CLAUDE.md compliance
  --------------------
  * Migrations are idempotent: ON CONFLICT DO NOTHING on both the
  permission_keys insert and the role_permissions grants.
  * Operator-scoped or admin-scoped? Permission keys are global
  (see `db/migrations/202604250008_auth_schema_foundation.sql`).
  `public.permission_keys` has no operator_id; the per-tenant
  join lives in `public.user_roles` × `public.role_permissions`.
  * After migration: `tool/migration_drift_scanner.dart --fix --strict-docs`
  and `tool/migration_cutoff_lint.dart`.

  Precedent: 202604270000_phase_9_0a_scope_extensions.sql for the
  `team.*` insert shape + baseline-grant cross-join.

## `202605142100_phase_R_1L_roles_schema_rewrite.sql`

- **Applied:** 2026-05-14 21:00
- **Title:** phase R 1L roles schema rewrite
- **Description:**

  Wave 2 R-1L - Roles schema rewrite (product label + category + scope kind + implies).

  Origin:
  * debug.md:28-43 (RP-7 / RP-8 / RP-12 / RP-14 / RP-15 / OW-7a..g).
  The operator brain-dump for Roles + Permissions calls for
  categorisation by product → functionality, dependency tracking
  (e.g. "edit" implies "view"; "manage members" implies
  `team.users.view`), org-wide vs location-scoped tagging, and a
  per-permission-key product label so the editor can group by
  product.
  * docs/_indices/WAVE_2_LEDGER.md Lane R row R-1L. R-2L (new Roles
  editor UI) and S-3 (Roles screen simplification) are held in
  the ledger pending this slice.
  * Authority anchors:
  - `lib/auth/permission_keys.dart` (frozen catalog mirror).
  - `docs/contracts/auth_permission_key_catalog.md` (canonical
  catalog doc).
  - `lib/services/auth/custom_role_validator.dart` (Q-4's
  advisory tables — `kOrgWidePermissionKeys`,
  `kViewRequiredForWrite`, `kTeamUsersWriteKeys`). The schema
  backfill mirrors the data already captured there so the
  validator and the schema can never drift.
  - CLAUDE.md "RLS-Ready Schema" — `permission_keys` is the
  frozen catalog table, NOT an operator-scoped fact table, so
  the (operator_id, location_id) discipline does NOT apply to
  its rows. RLS is enabled with a service-role-only policy stub
  from 9.0; this slice does not change that posture.
  - CLAUDE.md "Time Guardrails" — no new timestamp columns are
  added; `created_at` / `updated_at` already cover update audit.

  Why this exists
  ---------------
  The Roles editor UX (R-2L) needs to group permission keys by
  product → functionality, the runtime resolver needs to know which
  keys auto-grant other keys (e.g. `team.users.invite` should also
  grant `team.users.view`), and the proxy needs to reject
  location-scoped grants for org-wide-only keys. Today those facts
  live in three places:

  1. The catalog markdown doc has per-category prose but no
  machine-readable product label, category label, or scope
  tag.
  2. The custom_role_validator has hand-curated tables for
  view-required-for-write pairs, member-management chains, and
  org-wide-only keys — but those are UI-side advisory only.
  3. The Dart constants file has the dotted-key strings but no
  metadata.

  This slice promotes those facts into the canonical
  `public.permission_keys` table so the runtime resolver, the proxy
  editor, and the audit log all read the same source of truth.

  Expand-contract posture
  -----------------------
  The four new columns ship as NULLABLE in this expand-only
  migration. The backfill `UPDATE` runs inline so existing rows get
  non-null values before the migration commits. The follow-up
  migration `R-1L-FU` flips the columns to NOT NULL after a clean
  apply cycle on staging + production. Splitting the SET NOT NULL
  into its own migration is the standard expand-contract pattern
  enforced by `tool/migration_drift_scanner.dart` for any migration
  after the grandfather cutoff at
  `202605131030_b11_1_auth_handoff_codes.sql`.

  Defense-in-depth: `tool/permission_key_lint.dart` is extended in
  the same slice to fail CI when a new permission key is added
  without `product_label` / `category_label` / `scope_kind` /
  `implies` populated in the Dart mirror. The combination of
  (NULLABLE columns at the schema layer + NOT-NULL enforcement at
  the source-of-truth Dart layer) keeps the migration zero-downtime
  while still preventing operators from ever shipping a key with
  missing metadata.

## `202605150000_phase_r2l_default_role_catalog_v2.sql`

- **Applied:** 2026-05-15 00:00
- **Title:** phase r2l default role catalog v2
- **Description:**

  Wave 2 R-2L — Default Role Catalog v2 redesign.

  Authority:
  * docs/_indices/WAVE_2_R2L_DEFAULT_ROLE_CATALOG_V2_PROPOSAL.md
  (operator-approved 2026-05-14; locks role names, scopes,
  descriptions, MFA gating, and v1 -> v2 migration mapping).
  * docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md RP-3 / RP-6 /
  RP-14 (catalog gaps the v2 catalog closes).
  * Prereq: R-1L `202605142100_phase_R_1L_roles_schema_rewrite.sql`
  which added product_label / category_label / scope_kind /
  implies columns.
  * CLAUDE.md "RLS-Ready Schema" — `permission_keys`, `roles`,
  `role_permissions`, `user_roles` are the auth catalog tables;
  RLS posture is unchanged by this slice (service-role
  wrapper functions only).
  * CLAUDE.md "Time Guardrails" — every new timestamp column is
  `timestamptz` (none added here; existing created_at /
  updated_at columns cover audit).

  What this slice does
  --------------------
  1. Adds `permission_keys.human_label TEXT` (NULLABLE; expand-only
  per the R-1L expand-contract precedent — NOT NULL flip parked
  alongside R-1L-FU).
  2. Backfills every permission_key row with a Title Case English
  human label per the UX naming standard (no underscores, no
  engineering jargon). The R-2L editor + role explainer surfaces
  render `human_label` instead of the raw dotted key.
  3. Seeds 7 new v2 role rows (Owner already exists as
  `operator_owner` — only its `display_name` and `description`
  flip to the v2 wording):
  operator_general_manager  ("General Manager")
  location_manager          ("Location Manager")
  supervisor                ("Supervisor")
  finance_analyst           ("Finance Analyst")
  auditor_compliance        ("Auditor / Compliance")
  training_lead             ("Training Lead")
  team_admin                ("Team Admin")
  Plus 3 carry-overs: `super_admin`, `ff_support`, `operator_owner`.
  Total seeded v2 catalog = 10 roles.
  4. Seeds role_permissions for every new v2 role per the matrix in
  the proposal doc. Owner gains additional v2 keys
  (team.* / billing.* completeness); manager / supervisor / staff
  do NOT get fresh grants because those roles are soft-deleted in
  step 6.
  5. Auto-migrates v1 user_roles in a single transaction:
  operator_manager     -> operator_general_manager (operator-wide).
  operator_supervisor  -> supervisor (LOCATION-scoped; preserves
  v1 grant's location_id; for v1 rows with
  NULL location_id, fan out one supervisor
  grant per locations row the user has any
  visibility into and flag for operator
  review via reason text).
  operator_staff       -> supervisor (same location-preservation
  logic; staff users folded into the
  shift-supervisor role).
  6. Soft-deletes v1 retired role rows (`deleted_at = now()`) —
  operator_manager / operator_supervisor / operator_staff. Hard
  delete is forbidden so the audit trail and any FK references
  (role_permissions, role_audit_log) stay intact.
  7. Refreshes `operator_owner` display_name + description to the v2
  wording ("Owner" / reads-as-training description) and grants the
  v2 additions (team.* completeness, full billing) idempotently.
  8. Emits `auth.role.seeded_catalog_v2_published` rows to
  `auth_events_audit` for every migrated user_role + every retired
  seeded role.

  Idempotency
  -----------
  The migration wraps every mutation in a single transaction and
  uses `on conflict do nothing` for role + role_permissions inserts.
  The user_roles auto-migrate filters on the OLD role_id so re-runs
  after a successful pass are a no-op (no rows still carry the v1
  role_id). The fan-out INSERT excludes already-present grants via
  an anti-join against `user_roles_active_grant_idx`.

  Reader-side mirror
  ------------------
  `lib/auth/permission_key_metadata.dart` is extended in the same
  slice with a `humanLabel` field on `PermissionKeyMetadata`; every
  entry in `PermissionKeyMetadataCatalog.byKey` carries a Title Case
  humanLabel matching the backfill below.
  `tool/permission_key_lint.dart`'s HUMAN_LABEL_INVALID pass fails
  CI if any entry has an empty humanLabel or one containing
  underscores.

## `202605150100_phase_r_followup_not_null_flip.sql`

- **Applied:** 2026-05-15 01:00
- **Title:** phase r followup not null flip
- **Description:**

  Wave 2 R-1L-FU + R-2L-FU — flip permission_keys text columns to NOT NULL.

  Origin:
  * Prereq R-1L `db/migrations/202605142100_phase_R_1L_roles_schema_rewrite.sql`
  added `permission_keys.product_label`, `category_label`, `scope_kind`
  (all `text`, NULLABLE) with inline `UPDATE ... CASE` backfills that
  hydrate every row before commit. The migration's terminal fail-loud
  DO block raises if any backfill row is left NULL. The expand-only
  posture deferred the NOT NULL flip to this follow-up per the
  expand-contract discipline `tool/migration_drift_scanner.dart`
  enforces for migrations after the grandfather cutoff at
  `202605131030_b11_1_auth_handoff_codes.sql`.
  * Prereq R-2L `db/migrations/202605150000_phase_r2l_default_role_catalog_v2.sql`
  added `permission_keys.human_label` (`text`, NULLABLE) with an inline
  `UPDATE ... CASE` backfill that hydrates every catalog key. The
  same fail-loud DO block guards that backfill at apply time. R-2L's
  terminal comment explicitly parks the human_label NOT NULL flip
  alongside the R-1L-FU follow-up — this slice picks both up in one
  combined contract migration.
  * Operator approval (2026-05-14): fold the combined NOT NULL flip into
  the wave without a separate staging cycle. The Dart-side mirror at
  `lib/auth/permission_key_metadata.dart` is NOT-NULL-at-source via
  `tool/permission_key_lint.dart`'s METADATA + HUMAN_LABEL_INVALID
  passes; any catalog key shipping without a label fails CI before it
  ever reaches a migration apply, so the inline backfills are
  guaranteed to find a non-NULL value in every row.
  * CLAUDE.md "RLS-Ready Schema" — `permission_keys` is the global
  catalog table (operator_id IS NULL across every row); HP #4
  per-operator isolation does not apply. RLS posture unchanged.
  * CLAUDE.md "Time Guardrails" — no new timestamp columns added.

  What this slice does
  --------------------
  1. Defensive pre-flight: count any rows where product_label /
  category_label / scope_kind / human_label / implies is NULL. If any
  are present, raise loudly with the row count so the operator can
  investigate the R-1L + R-2L backfills before retrying. The flip MUST
  NOT proceed silently when the source-of-truth data is incomplete.
  2. Flip `product_label`, `category_label`, `scope_kind`, `human_label`
  to NOT NULL. Each `SET NOT NULL` is idempotent (PG no-ops if the
  column is already NOT NULL), so a re-run after partial success is
  safe.
  3. Ensure the `implies text[]` column carries the safe default of
  `'{}'::text[]` (R-1L added it with this default + NOT NULL, but
  defensively re-assert here in case any earlier migration in a
  bespoke staging cycle dropped the default). Backfill any NULL rows
  to `'{}'` before reasserting NOT NULL.

  Idempotency
  -----------
  Every statement is a structural contract that PostgreSQL no-ops when
  the column is already in the target state:
  * `SET NOT NULL` on an already-NOT-NULL column is a no-op.
  * `SET DEFAULT '{}'::text[]` on a column that already has that
  default is a no-op.
  * The pre-flight assertion short-circuits before any structural
  change when source data is incomplete.

  Expand-contract posture
  -----------------------
  This is the **contract** half of the R-1L + R-2L expand-contract pair.
  The migration adds NO new columns, runs NO data-shape backfills (only
  the defensive `implies = '{}'::text[] WHERE implies IS NULL` safety
  net), and only tightens existing nullability constraints. The drift
  scanner's expand-contract lint allows SET NOT NULL on its own
  (`hasAddNullable && hasUpdate && hasSetNotNull` is the violation
  shape; SET NOT NULL alone with no ADD COLUMN is allowed).

## `202605150200_phase_u_fu_hp11_account_per_location_overrides.sql`

- **Applied:** 2026-05-15 02:00
- **Title:** phase u fu hp11 account per location overrides
- **Description:**

  Wave 2 U-FU-hp11-account — per-location overrides for AccountScreen's
  three settings cards (region, business-day rollover, business identity
  contact email + phone).

  Authority anchors
  -----------------
  * docs/_indices/WAVE_2_LEDGER.md U-FU-hp11-account row — schema +
  write path for the HP #11 scope notice shipped in PUNT mode by
  PR #712 (operator decision logged 2026-05-14).
  * db/migrations/202605070000_phase_11W_7_operator_account_fields.sql
  — the operator-level (Business default) source for these fields.
  * lib/operator_web/screens/account_screen.dart — UI shipped with
  HP #11 notices but Save disabled below Business scope.
  * docs/contracts/auth_permission_key_catalog.md — no new permission
  key is introduced; per-location overrides reuse the existing
  operator_owner / operator_admin role gate the rest of the
  operator-write surface enforces.

  Per-location-with-business-fallback semantics
  ---------------------------------------------
  The operator decision was: location-level edits override the business
  default *for that location only*. When the override row is missing
  (or a column is NULL inside the row), the location inherits the
  business default from `public.operators`.

  The table stores only the SCOPED FIELDS — the business display name
  stays operator-wide (single business name doctrine) so it is NOT in
  this table. The HP #11 carve-out is documented in account_screen.dart
  and surfaced in the UI as a disabled field at location scope with the
  explainer "The business name is set at the Business level."

  CLAUDE.md compliance
  --------------------
  * RLS-ready schema from day one (HP #4 per-operator + per-location
  isolation). RLS is the backup defence; the proxy + repository
  are the primary defence via OperatorScopedRepository.withTenant.
  * B-tree index leads with `operator_id` per the RLS-ready rule.
  * Wrapper functions are the canonical
  `STABLE LEAKPROOF PARALLEL SAFE` ones from
  `db/migrations/202605020500_hardening_auth_rls_to_wrappers.sql`
  (`public.app_current_operator()`).
  * Migration is idempotent: `create table if not exists`,
  `if not exists` on the index, `drop policy if exists` before
  `create policy`.

## `202605150300_phase_rp_9_default_catalog_edit_permission_key.sql`

- **Applied:** 2026-05-15 03:00
- **Title:** phase rp 9 default catalog edit permission key
- **Description:**

  Wave 2 RP-9 — Default Role Catalog admin permission keys.

  Authority:
  * docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md RP-9
  ("Admin can edit Default-role permissions across F&F; this
  itself is a permission"). Verification worker flagged that the
  `default_role_catalog_admin_screen.dart` admin surface was
  gated by role tier (`super_admin` write, `ff_support` read-only)
  but not represented as a granular permission key in the catalog.
  * docs/contracts/auth_permission_key_catalog.md `team.*` table —
  this migration mirrors the two new rows
  `team.roles.default_catalog.view` and
  `team.roles.default_catalog.edit`.
  * lib/auth/permission_keys.dart `teamRolesDefaultCatalogView` /
  `teamRolesDefaultCatalogEdit` constants — the runtime resolver
  iterates `PermissionKeys.all`; this migration keeps the seed in
  lockstep with the Dart catalog mirror.
  * tool/advisor_proxy/admin_default_role_catalog_routes.dart —
  `kDefaultRoleCatalogAdminReadRoles` (super_admin + ff_support)
  and `kDefaultRoleCatalogAdminWriteRoles` (super_admin) define
  the role tiers this slice promotes to granular permission keys.
  * CLAUDE.md HP #2 — demo parity. Both keys are global catalog
  rows (operator_id IS NULL) so demo and production resolve to the
  same seed without parallel `demo_*` tables.

  Why this exists
  ---------------
  The F&F-internal Default Role Catalog admin surface lets a
  `super_admin` publish a new template that every new operator's seeded
  role set is minted from. `ff_support` lands on a read-only branch.
  Before this slice the gate lived only in two places:
  1. `tool/advisor_proxy/admin_default_role_catalog_routes.dart` role
  tier sets (the proxy gate).
  2. `lib/admin/admin_routes.dart` `_buildDefaultRoleCatalog`
  builder (`session.roles.contains('super_admin')` decides the
  `editingEnabled` flag).
  Neither layer registered the gate as a granular permission key in
  `public.permission_keys`, so the catalog mirror disagreed with the
  runtime authority. This migration closes the gap by adding two
  permission keys + baseline grants. The proxy + route layers continue
  to enforce role-tier checks as defense-in-depth fallbacks.

  Frozen + non-MFA: like every other `team.*` key at launch, neither
  new key is MFA-required at the catalog level. The Default Role
  Catalog admin route inherits the admin-console MFA freshness gate
  through `AdminAuthSession.lastFreshAuthAt` — no per-key freshness
  claim is needed here. The grant set stays narrow (super_admin only
  for `edit`; super_admin + ff_support for `view`) so widening the
  gate accidentally is not possible without an explicit code change.

  HP #4 carve-out: this is F&F-internal admin scope. Do NOT widen the
  baseline grants to operator-tier roles (`operator_owner`,
  `operator_admin`, manager / supervisor / staff). Publishing a new
  default catalog version affects every operator in the F&F
  deployment, so the write gate is F&F super-admin-only by design.

  CLAUDE.md compliance
  --------------------
  * Migrations are idempotent: ON CONFLICT DO NOTHING on both the
  permission_keys insert and the role_permissions grants.
  * Operator-scoped or admin-scoped? Permission keys are global
  (see `db/migrations/202604250008_auth_schema_foundation.sql`).
  `public.permission_keys` has no `operator_id`; the per-tenant
  join lives in `public.user_roles` x `public.role_permissions`.
  * R-1L / R-2L mirror columns (`product_label`, `category_label`,
  `scope_kind`, `human_label`) are populated inline because this
  migration runs after the R-1L schema-rewrite and R-2L human-label
  backfill — leaving them NULL would trip the eventual NOT NULL
  flip and the lint's HUMAN_LABEL_INVALID pass on the Dart side.
  * After migration: `tool/migration_drift_scanner.dart --fix
  --strict-docs` and `tool/migration_cutoff_lint.dart`.

  Precedent
  ---------
  * `202605140000_w_3_self_profile_perm_key.sql` for the `team.*`
  insert shape + baseline-grant cross-join. The W-3 slice ran
  BEFORE the R-1L schema rewrite so it did not need to populate
  the new metadata columns; this slice runs AFTER R-1L + R-2L and
  fills them in the same migration.
  * `202605061100_phase_11A_14_admin_users_reset_mfa_factors_key.sql`
  for the F&F-internal-only baseline grant pattern (super_admin
  only; no operator-tier widening).

## `202605150400_per_daypart_v1_drop_close_authority.sql`

- **Applied:** 2026-05-15 04:00
- **Title:** per daypart v1 drop close authority
- **Description:**

  Per-Daypart Targets V1 — Slice 1.5

  Deprecates the operator-set `close_authority` + `local_close_fallback_time`
  columns on `public.business_timing_profiles` (the Postgres parent of the
  SQLite `restaurant_timing_configs` mirror named in the prompt).

  Operator decision 2026-05-15: close-authority is now auto-derived per
  shift from the per-vendor `CloseAuthorityCapability` lookup
  (`lib/services/integration/close_authority_capability.dart`) plus the
  operator's `business_day_start_local_time` as the universal fallback.
  There is no operator-facing setting any more, so the persistent
  column on `business_timing_profiles` carries no truth.

  This migration drops the NOT NULL + CHECK constraints and the
  dependent cross-column CHECK so:
  * New rows can be written without supplying close_authority /
  local_close_fallback_time.
  * Existing rows preserve their legacy values until the next
  wave's full-drop migration (separate slice).

  The dropped CHECK `business_timing_profiles_local_close_required_check`
  enforced "if close_authority = app_local_cutoff_fallback then
  local_close_fallback_time is not null", which makes no sense when
  close_authority is optional. The per-column CHECK on the allowed
  close_authority enum values is preserved on the still-existing column
  so any legacy writes still validate.

## `202605160000_per_daypart_v1_per_period_target_persistence.sql`

- **Applied:** 2026-05-16 00:00
- **Title:** per daypart v1 per period target persistence
- **Description:**

  Per-Daypart Targets V1 — Slice 1

  Per-period data layer foundation. Three additive surfaces:

  * `public.target_cycle_dayparts` — one row per (cycle, service_period).
  Carries per-period CPLH/SPLH/PPA + OPZ band + cover_count (the
  per-period candidate cover total at compute time, used for
  cover-weighted whole-day pool rollup inside the cycle write path).

  * `public.weekly_plan_snapshot_day_dayparts` — one row per
  (snapshot, business_date, service_period). Carries per-(day,
  period) demand-derived values stamped at lock time: forecast
  covers + sales + required FOH/BOH hours + theoretical FOH/BOH
  dollars (wages stay whole-day per Design Rule 5).

  * `public.weekly_plan_snapshots.wage_at_lock_time_json` (JSONB) —
  audit checks comparing locked dollar values against wages must
  compare against THIS column, not against `ActiveTargetProfile`
  current wages (Design Rule 8).

  * Per-shift per-period target stamp columns on `public.shift_records`
  (`daypart_target_cplh` etc.) — closed-truth retains the stamp
  from its close time per Promise 2.

  RLS posture (per
  `docs/contracts/hardening_rls_and_repository_pattern_contract.md`):
  * every new operator-scoped table carries `(operator_id, location_id)`.
  * every hot-path B-tree index leads with `(operator_id, location_id)`.
  * policies use the four sanctioned wrapper functions
  (`app_current_operator()`, `app_current_location()`); bare
  `current_setting('app.*')` is forbidden.
  * tables `ENABLE ROW LEVEL SECURITY`; `service_role` + `forge_admin`
  receive least-privilege grants.

## `202605161500_per_daypart_v1_deprecate_locations_rollover_hour.sql`

- **Applied:** 2026-05-16 15:00
- **Title:** per daypart v1 deprecate locations rollover hour
- **Description:**

  Per-Daypart Targets V1 — Slice 7b option (b) (2026-05-15)

  Document the deprecation of `public.locations.business_day_rollover_hour`.

  Operator decision (2026-05-15, locked) per
  `docs/_audits/per_daypart_v1/slice_7b_research_2026_05_15.md`:
  vendor sinks resolve `business_date` via the canonical
  `BusinessTimingProfilesRepository.listCandidateProfilesForLocation`
  → `BusinessTimingProfileResolver.resolve` → `BusinessDateResolver.resolve`
  chain. That chain consumes `business_timing_profiles.business_day_start_local_time`
  (TIME, HH:MM, sub-hour aware) and honors the operator → org_unit →
  location inheritance per Hard Promise #11. The legacy
  `locations.business_day_rollover_hour` (INTEGER 0..23) truncates
  sub-hour cutoffs and bypasses inheritance — the source of Gaps 46
  and 47 in the per-daypart V1 end-to-end verification.

  Sub-decisions (locked, do not revisit):
  * Sub-option (b1): the SQL trigger
  `db/migrations/202605071900_phase_8_set_business_date_hardening.sql:126-147`
  stays as a defense-in-depth backup — NOT rewritten in 7b.
  * Fallback hour `4` across all sinks (matches Libro + the
  operator-default `business_day_start_local_time = '04:00'`).
  * Column deprecated, NOT dropped in 7b. The drop migration is a
  follow-up after a deprecation cycle so a rolled-back deploy can
  fall back to the legacy SQL trigger if needed.

  This migration adds a column comment only — no DDL changes, no data
  changes, fully backward compatible. The column remains writable and
  readable; only its role in the architecture is now documented.

## `202605161501_per_daypart_v1_s0_verdict_persistence.sql`

- **Applied:** 2026-05-16 15:01
- **Title:** per daypart v1 s0 verdict persistence
- **Description:**

  Per-Daypart Targets V1 — Slice S0 (foundation, 2026-05-16)

  Per-period verdict + reason persistence.

  A later per_daypart_v1 slice replaces the benchmark-selection
  algorithm so each service period (lunch / dinner / late_night) gets
  its own quality VERDICT, and the Benchmark card / DAYPART BREAKDOWN
  renders a per-period badge. Per-period TARGET persistence already
  exists (Slice 1, migration
  `202605160000_per_daypart_v1_per_period_target_persistence.sql`).
  This S0 slice adds ONLY the missing per-period verdict + reason
  persistence so the future algorithm has a column to write to.

  Scope: two additive, nullable, no-default TEXT columns on the
  existing per-period child table `public.target_cycle_dayparts`.
  `ActiveTargetProfileDaypart` has no own table — it is projected at
  runtime from `target_cycle_dayparts` by the service layer — so only
  this one per-period child table needs the columns.

  Back-compat: rows that pre-date S0 (and rows the future algorithm
  leaves unscored) read back as NULL. Per Design Rule 2, NULL means
  "unavailable"; callers never substitute 0 / empty string. No
  algorithm, seeder, widget, or operator-facing copy changes here.

  RLS posture unchanged: the table already carries
  `(operator_id, location_id)` + the per-tenant-location policy from
  migration 202605160000; these additive columns inherit it.

## `202605170000_per_daypart_v1_r5_covers_source_keyed_backfill.sql`

- **Applied:** 2026-05-17 00:00
- **Title:** per daypart v1 r5 covers source keyed backfill
- **Description:**

  Per-Daypart Targets V1 — Slice R5 (Gap 27/36, 2026-05-17)

  De-hardcode covers-source: data-preserving backfill of the legacy
  hardcoded `covers_source_lunch` / `covers_source_dinner` /
  `covers_source_late_night` columns on
  `public.data_accuracy_settings` into the existing keyed
  `public.data_accuracy_service_period_settings` table, then deprecate
  the legacy columns.

  Authority:
  * docs/contracts/data_accuracy_settings_contract.md
  "Business timing compatibility amendment (2026-05-06)" — the
  hardcoded covers_source_* triplet is a rejected legacy shape;
  the V1 target is the keyed child table per service_period_key.
  * db/migrations/202605061701_phase_8_data_accuracy_service_period_settings.sql
  created the keyed table and stated: "A future migration will
  drop them once every read path ... is migrated to the keyed
  lookup." This slice migrates the model / aggregator / repository
  / operator-web + mobile covers UIs read paths.
  * docs/contracts/phase_7_55_time_boundary_contract.md
  (TIMESTAMPTZ on operator-scoped fact tables; the keyed table
  already complies — this migration adds no temporal columns).
  * docs/contracts/hardening_rls_and_repository_pattern_contract.md
  (RLS-ready; operator-leading indexes; wrapper-only policies).

  ── Why this migration ───────────────────────────────────────────

  The legacy columns admit exactly three hardcoded dayparts. An
  operator running 4+ service periods (e.g. breakfast / lunch /
  dinner / late_night) cannot set covers source per period. The keyed
  `data_accuracy_service_period_settings` table (created 2026-05-06)
  already admits one covers-source row per
  (operator, location, service_period_key, effective_at_business_date)
  and the closed-shift aggregator already resolves keyed-first. This
  migration moves the legacy values into the keyed table so no
  operator setting is lost when the model / UIs stop reading the
  legacy columns.

  ── Data preservation (HARD CONSTRAINT) ──────────────────────────

  For every existing `data_accuracy_settings` row, three keyed rows
  are inserted (one per legacy daypart) carrying that row's legacy
  covers_source value, keyed by service_period_key = 'lunch' /
  'dinner' / 'late_night'. The effective date is the sentinel
  1970-01-01 so the keyed row is always "at or before" any closed
  shift's business date — exactly reproducing the legacy column's
  always-applies semantics (the aggregator's at-or-before lookup
  resolves to the operator's intent on the day the shift closed).

  `on conflict ... do nothing`: a keyed row the operator already
  created for that (operator, location, service_period_key,
  1970-01-01) wins and is NOT clobbered by the legacy value. A
  later, operator-set row at a more recent effective date also wins
  via the descending at-or-before lookup. Idempotent: re-applying
  this migration inserts nothing the second time.

  Every legacy value lands as a keyed row; no covers-source data is
  lost. The backfill copies operator_id / location_id straight from
  the source row, so per-(operator, location) isolation and the
  keyed table's existing per-tenant RLS policy are preserved.

  ── Legacy-column deprecation, NOT hard drop (scope-conservative) ─

  The legacy columns are still read/written by surfaces OUTSIDE this
  slice's named scope: `tool/advisor_proxy/proxy_bootstrap.dart`
  (mobile-operational sync upsert + admin override SQL), the
  `public.effective_data_accuracy_settings_v` view (defined in
  202605121200_admin_hierarchy_scoped_data_polling.sql, which also
  coalesces the HP #11 `data_accuracy_scoped_overrides` columns), the
  sync DTO, and the admin gateway. A hard `DROP COLUMN` here would
  silently break that view + proxy SQL and cascade into a
  proxy-touching / view-touching / HP #11-hierarchy refactor the R5
  prompt's bounded "CURRENT STATE TO REPLACE" list did not name
  ("Do not broaden scope"). Following this repo's own deferred-drop
  idiom (202605161500 deprecate-not-drop; 202605061701 "a future
  migration will drop them once every read path is migrated"), the
  columns are marked DEPRECATED via column comments. The hard drop is
  a scoped follow-up once the proxy / view / admin-hierarchy read
  paths are migrated. The R5 model / aggregator / repository / covers
  UIs no longer read these columns; the keyed table is their sole
  source of truth.

  ── Idempotency ──────────────────────────────────────────────────

  `insert ... on conflict do nothing` (conflict identity = the keyed
  table's existing UNIQUE index). `comment on column` is naturally
  idempotent. Wrapped in BEGIN ... COMMIT so a partial failure leaves
  the schema unchanged.

## `202605170100_per_daypart_v1_r7a_covers_source_per_period_hierarchy.sql`

- **Applied:** 2026-05-17 01:00
- **Title:** per daypart v1 r7a covers source per period hierarchy
- **Description:**

  Per-Daypart Targets V1 — Slice R7a (2026-05-17)

  Per-service-period covers source through the HP #11 admin hierarchy.

  This migration is PURELY ADDITIVE and backward compatible. It does
  two things and nothing else:

  1. Adds a nullable `covers_source_per_service_period jsonb` column
  to `public.data_accuracy_scoped_overrides` (the HP #11
  scoped-overrides table) so a Forge admin can set covers source
  keyed by `service_period_key` at a business / org-unit /
  location scope, not only via the three hardcoded
  `covers_source_lunch` / `_dinner` / `_late_night` columns.

  2. Redefines `public.effective_data_accuracy_settings_v` to ADD a
  new output column `covers_source_per_service_period jsonb` that
  resolves per `service_period_key` with the SAME
  most-specific-scope-wins precedence the view uses today
  (location scope → org-unit scope via the HP #11 ltree lateral →
  business scope → legacy keyed
  `public.data_accuracy_service_period_settings` effective row →
  'vendor' default).

  Authority:
  * docs/contracts/data_accuracy_settings_contract.md
  "Business timing compatibility amendment (2026-05-06)" — the
  hardcoded covers_source_* triplet is a rejected legacy shape;
  the V1 target is the keyed child table per service_period_key.
  * CLAUDE.md Hard Promise #11 — hierarchy-scoped settings inherit
  downward (operator → org unit → location); lower configured
  scopes override higher scopes. This migration carries the
  per-period covers source through that same inheritance.
  * db/migrations/202605121200_admin_hierarchy_scoped_data_polling.sql
  defined the scoped-overrides table + the effective view this
  migration extends. The HP #11 org-unit ltree lateral
  (`loc.org_unit_path <@ ou.path`, deepest ancestor wins) is
  reproduced byte-for-byte for the new jsonb output.
  * db/migrations/202605061701_phase_8_data_accuracy_service_period_settings.sql
  created the keyed legacy fallback table whose effective-row
  resolution (DISTINCT ON … ORDER BY effective_at_business_date
  DESC, at-or-before today) this migration mirrors in SQL, the
  same projection used by
  lib/services/data_accuracy/data_accuracy_settings_repository.dart
  and lib/services/integration/canonical_fact_to_closed_shift_input.dart.
  * db/migrations/202605170000_per_daypart_v1_r5_covers_source_keyed_backfill.sql
  (Slice R5) backfilled the legacy per-location covers columns into
  the keyed table and DEPRECATED (did not drop) the legacy
  columns. R7a does not drop or alter any legacy column either:
  the hard drop of the scalar columns + the legacy view outputs is
  a later scoped slice (R7d). R7b moves the proxy onto the new
  jsonb; R7c owns the admin / app Dart. R7a is schema + view only.
  * docs/contracts/phase_7_55_time_boundary_contract.md
  (TIMESTAMPTZ on operator-scoped fact tables; this migration adds
  no temporal columns — only a jsonb column).
  * docs/contracts/hardening_rls_and_repository_pattern_contract.md
  (per-tenant RLS preserved; operator-leading B-tree indexes;
  wrapper-only policy bodies — none changed here).

  ── ADDITIVE ONLY (HARD CONSTRAINT) ──────────────────────────────

  No column is dropped or altered. The existing scalar columns
  `covers_source_lunch` / `covers_source_dinner` /
  `covers_source_late_night` on
  `public.data_accuracy_scoped_overrides` and on
  `public.data_accuracy_settings` are untouched. The view's three
  existing scalar outputs (`covers_source_lunch` /
  `covers_source_dinner` / `covers_source_late_night`) are emitted
  byte-for-byte exactly as today, still backed by the legacy columns,
  so every current consumer keeps working unchanged. The only change
  to the view's output shape is one ADDED column appended after the
  existing late-night scalar; no existing output column is removed,
  reordered, or re-typed. The hard drop of the scalars + the legacy
  columns + redefining the view to remove them is deferred to R7d.

  ── Why a jsonb column on the scoped-overrides table ──────────────

  The scoped-overrides table is keyed by (scope_type, org_unit_id,
  location_id) — one row per admin scope, not per service period.
  The keyed legacy table
  `public.data_accuracy_service_period_settings` is the per-period
  shape but is per-(operator, location) only and carries no admin
  scope dimension. To carry per-period covers source through the
  HP #11 hierarchy without inventing a parallel scoped+keyed table
  (which would duplicate the hierarchy logic), the per-period map
  rides on the existing scope row as a `{service_period_key:
  covers_source}` jsonb. This preserves the table's existing
  scope_type / org_unit_id / location_id hierarchy dimensions, its
  existing per-tenant RLS policy, and its operator-leading indexes
  unchanged.

  The jsonb value contract (validated by a CHECK below):
  * Must be a jsonb object (or null when the scope sets no
  per-period covers source).
  * Keys are service_period_key strings (e.g. 'lunch', 'dinner',
  'late_night', 'breakfast', 'brunch', 'happy_hour').
  * Each value is one of the keyed table's covers_source enum
  values ('vendor' / 'forecast' / 'manual' /
  'reservation_plus_walkin'), matching
  public.data_accuracy_service_period_settings.covers_source.

  ── Most-specific-scope-wins precedence (HP #11) ──────────────────

  The new view output resolves per service_period_key by merging the
  per-period maps from least to most specific, so the most specific
  configured scope wins per key (a key set at location scope
  overrides the same key set at org-unit scope, which overrides
  business scope, which overrides the legacy keyed table, which
  defaults to 'vendor'). The org-unit scope row is selected by the
  SAME HP #11 ltree lateral the view already uses for the scalar
  columns (`loc.org_unit_path <@ ou.path`, deepest ancestor wins) —
  the lateral join `org_scope` is reused, not duplicated. Per-key
  precedence is implemented with jsonb concatenation in
  least-to-most-specific order (`a || b` keeps b's value on key
  collision), then a default-fill for any keyed-table period the
  scopes did not set, defaulting unset periods to 'vendor' to match
  the scalar columns' 'vendor' fallback.

  ── Idempotency ──────────────────────────────────────────────────

  `add column if not exists` + `create or replace view`. The CHECK
  constraint is added with a guarded DO block so re-applying the
  migration does not error on an already-present constraint. Wrapped
  in BEGIN … COMMIT so a partial failure leaves the schema
  unchanged. No down migration: the column add is additive and the
  view replace is forward-compatible (R7d redefines the view and
  drops columns). This follows the repo's deferred-drop idiom
  (202605161500 / 202605170000 deprecate-not-drop).

## `202605170200_per_daypart_v1_r7d_drop_legacy_covers_columns.sql`

- **Applied:** 2026-05-17 02:00
- **Title:** per daypart v1 r7d drop legacy covers columns
- **Description:**

  Per-Daypart Targets V1 — Slice R7d (2026-05-17)

  FINAL covers-source step. SCHEMA-DESTRUCTIVE (hard column drop).

  This migration does exactly two things, atomically, and nothing
  else:

  1. Redefines `public.effective_data_accuracy_settings_v` to REMOVE
  its three legacy scalar outputs (`covers_source_lunch` /
  `covers_source_dinner` / `covers_source_late_night`), keeping
  the R7a `covers_source_per_service_period jsonb` output and
  every other existing output unchanged (same HP #11 precedence,
  same RLS posture, same grants).

  2. DROPS the three legacy scalar covers columns:
  * public.data_accuracy_settings.covers_source_lunch
  * public.data_accuracy_settings.covers_source_dinner
  * public.data_accuracy_settings.covers_source_late_night
  * public.data_accuracy_scoped_overrides.covers_source_lunch
  * public.data_accuracy_scoped_overrides.covers_source_dinner
  * public.data_accuracy_scoped_overrides.covers_source_late_night
  with `drop column if exists` (idempotent), inside the SAME
  transaction as the view redefinition so the view no longer
  depends on these columns before Postgres processes the drop
  (no CASCADE, the view is never dropped).

  ── Why this is safe NOW (deferred-drop-now-executed) ─────────────

  Slice R5 (202605170000) keyed-backfilled every legacy per-location
  covers value into the keyed table
  `public.data_accuracy_service_period_settings` and DEPRECATED (did
  not drop) the legacy scalar columns. Slice R7a (202605170100) added
  the `covers_source_per_service_period jsonb` replacement column to
  `public.data_accuracy_scoped_overrides` and the matching jsonb
  output on the effective view, resolved with the SAME HP #11
  most-specific-scope-wins precedence. Slice R7b moved the advisor
  proxy off legacy-column SQL onto the keyed table / view jsonb (the
  proxy still emits the three legacy JSON wire keys, but sourced from
  keyed data — that wire shape is unaffected by this column drop).
  Slice R7c removed the dead legacy-column Dart. A repo-wide pre-drop
  safety gate (see the R7d PR body) confirmed ZERO remaining SQL
  reads/writes of these columns and ZERO readers of the view's three
  legacy scalar outputs anywhere in lib/**, tool/**, db/migrations/**,
  or test/** (the only same-named symbols remaining are JSON
  request/response wire keys sourced from keyed data, which this drop
  does not touch). With zero readers, the hard drop is safe.

  ── No down migration (intentional) ──────────────────────────────

  This is the final destructive step of the covers-source migration;
  it is not reversible. The legacy scalar columns and view outputs
  are fully superseded by the keyed table + the R7a
  `covers_source_per_service_period` jsonb path. A rollback would
  require re-deriving the dropped scalars from the keyed data, which
  the application no longer reads. This follows the repo's
  deferred-drop idiom (202605161500 / 202605170000 deprecate-not-drop,
  then a later scoped slice executes the hard drop).

  ── Production safety ────────────────────────────────────────────

  All prior covers-source migrations (R5 202605170000, R7a
  202605170100) are Production1-pending (not yet applied to any live
  environment per the migration apply audit), so there is no live
  data in these columns to lose. On a fresh staging/Production1 apply
  this migration runs after R5 + R7a in filename order.

  ── Idempotency / atomicity ──────────────────────────────────────

  `create or replace view` + `drop column if exists` (re-applying is
  a no-op). Wrapped in BEGIN … COMMIT so the view redefinition and
  the six column drops are one atomic unit: either the view stops
  depending on the legacy columns and the columns are dropped, or the
  schema is left entirely unchanged. The view MUST be redefined
  within this transaction before the drops, otherwise Postgres blocks
  the drop (the old view depends on the columns) — which is exactly
  why no CASCADE is used: CASCADE would silently drop the view.

  Authority:
  * docs/contracts/data_accuracy_settings_contract.md
  "Business timing compatibility amendment (2026-05-06)" — the
  hardcoded covers_source_* triplet is a rejected legacy shape;
  the V1 target is the keyed child table per service_period_key.
  * CLAUDE.md Hard Promise #11 — hierarchy-scoped settings inherit
  downward; the retained `covers_source_per_service_period` output
  carries that inheritance unchanged.
  * db/migrations/202605121200_admin_hierarchy_scoped_data_polling.sql
  defined the scoped-overrides table + the effective view.
  * db/migrations/202605170000_per_daypart_v1_r5_covers_source_keyed_backfill.sql
  (R5) keyed-backfilled + deprecated the legacy scalar columns.
  * db/migrations/202605170100_per_daypart_v1_r7a_covers_source_per_period_hierarchy.sql
  (R7a) added the jsonb replacement column + view output, byte-for-byte
  the basis for the redefined view below (this migration only removes
  the three legacy scalar SELECT outputs from R7a's view body; every
  other output, join, and the HP #11 ltree lateral are reproduced
  exactly as R7a defined them).
  * docs/contracts/phase_7_55_time_boundary_contract.md
  (no temporal columns added or altered — drop-only + view replace).
  * docs/contracts/hardening_rls_and_repository_pattern_contract.md
  (per-tenant RLS preserved; no policy/index change; the dropped
  columns are non-indexed scalar columns).

## `202605190900_per_daypart_v1_r7e_data_accuracy_provenance.sql`

- **Applied:** 2026-05-19 09:00
- **Title:** per daypart v1 r7e data accuracy provenance
- **Description:**

  Per-Daypart V1 R7e data accuracy provenance.

  Adds source metadata to public.effective_data_accuracy_settings_v so
  clients can show where effective data-accuracy values came from
  without guessing inheritance in Flutter.

  Additive only:
  * existing view columns stay in the same order and keep the same
  expressions
  * new source columns are appended at the end
  * no table shape changes

## `202605191000_per_daypart_v1_r7f_data_accuracy_precedence_fix.sql`

- **Applied:** 2026-05-19 10:00
- **Title:** per daypart v1 r7f data accuracy precedence fix
- **Description:**

  Per-Daypart V1 R7f data accuracy precedence/source parity.

  R7e added source metadata to public.effective_data_accuracy_settings_v
  but accidentally merged scoped override maps before keyed
  service-period rows. Because jsonb concat keeps the right-hand value
  on key collision, that let keyed rows overwrite hierarchy overrides.

  This migration restores the R7a/R7d hierarchy rule:
  keyed service-period rows are the base fallback
  then business, org-unit, and location scoped overrides win per key
  and applies the same order to covers_source_per_service_period_source.

## `202605191200_wage_role_rows_hierarchy_scope_refresh.sql`

- **Applied:** 2026-05-19 12:00
- **Title:** wage role rows hierarchy scope refresh
- **Description:**

  Wage Role Rows hierarchy scope refresh.

  Schema-touching risk:
  * Adds hierarchy scope columns to public.wage_role_rows.
  * Allows location_id to be NULL only for business/org-unit scoped rows.
  * Relaxes the wage_role_rows RLS policy from operator+location to
  operator-only so operator owners can read/write higher-scope wage rows.

  This intentionally reuses the unmerged PR #836 direction, but fixes two
  live-path gaps from that closed branch:
  * The prior migration described NULL location_id rows without dropping the
  NOT NULL constraint.
  * The uniqueness/upsert path still only targeted location rows.

## `202605191830_canonical_fact_projection_retry_jobs.sql`

- **Applied:** 2026-05-19 18:30
- **Title:** canonical fact projection retry jobs
- **Description:**

  Canonical fact projection retry jobs.

  Why this exists
  ---------------
  Canonical fact writes must stay successful even when the downstream
  projection layer fails. The in-memory projection buffer is not durable,
  so a projector failure needs a tenant-scoped retry row that can be
  claimed and replayed later without asking the vendor to re-send data.

  Schema notes
  ------------
  * One row stores the exact post-commit projector input that failed.
  * `attempt_count` is incremented by the replay dispatcher when it claims.
  * `dead_lettered_at` is set after the bounded retry budget is exhausted.
  * Operator-leading indexes and RLS mirror the integration fact tables.

  Operator approval gate
  ----------------------
  This is schema-touching. Per CLAUDE.md, it requires explicit operator
  approval before merge regardless of audit verdict.

## `202605191845_data_accuracy_cover_facts_nullable_covers.sql`

- **Applied:** 2026-05-19 18:45
- **Title:** data accuracy cover facts nullable covers
- **Description:**

  Data Accuracy cover_facts nullable covers.

  Why this exists
  ---------------
  Some POS vendors, including Square and Clover, do not expose cover counts
  through their public APIs. Their sink rows must preserve NULL covers so the
  closed-shift aggregator can distinguish "vendor sent zero covers" from
  "vendor sent no covers field".

## `202605191900_canonical_fact_projection_retry_evidence.sql`

- **Applied:** 2026-05-19 19:00
- **Title:** canonical fact projection retry evidence
- **Description:**

  Projection retry evidence hardening.

  Why this exists
  ---------------
  The retry ledger now records both post-input projector failures and
  pre-input failures where the projector input could not be built. Support
  needs to see that failure point directly, and hard-deleting a location or
  connector must not silently remove terminal retry evidence.

  Operator approval gate
  ----------------------
  This is schema-touching. Per CLAUDE.md, it requires explicit operator
  approval before merge regardless of audit verdict.
