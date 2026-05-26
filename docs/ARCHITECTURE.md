# Forge Flow Architecture Guide

Last updated: 2026-05-26

Repository/tracker state reviewed through: 2026-05-26 (master tip)

This document is a study guide to Forge Flow. It walks through every meaningful part of the system in plain English, explains what each piece does and why it exists, and shows how the pieces fit together. The goal is not to list technology. The goal is to make the system understandable enough that you can reason about it, ask better questions, and know where each piece belongs.

## How To Read This

Each section follows the same shape. First there is a short plain-English introduction that gives you the mental model. Then there is a longer prose explanation of the area, where every concept is woven into the narrative rather than listed in a glossary. After that comes a "How it works" walkthrough that shows the runtime path, and finally a short "Where it lives" pointer to the relevant code or contract paths.

Three status words are used throughout. **Live** means the work is implemented and verified on master or in staging. **Scaffolded** means the foundation exists but a downstream consumer or workflow is still queued. **Planned** means the contract or phase doc describes it, but the code does not yet exist.

A reasonable reading order is to start with the whole-system picture and the quick walkthroughs, then read the product loop so the operational concepts make sense, then read app, SQLite, proxy, DNS, auth, and Postgres as the core runtime path. From there, RLS, permissions, service principals, and audit form the safety path. Events, usage, advisor, graph, integrations, shared state, and workflow form the expansion path. Deployment, testing, status, the glossary, and the source-file list are reference material you can dip into as needed.

## 1. Whole System In One Picture

### Plain English

Forge Flow helps an operator understand what the plan was, what is happening right now, whether labor is on track, whether demand has changed, what happened historically, and what the system recommends next. The app on a device is only one part of that system. The bigger picture includes a server-side proxy, a shared cloud database, an identity service, audit logs, DNS, edge protection, an AI retrieval layer, and a future workflow automation tier. Each of those pieces has a single job, a single deployment boundary, and a single trust posture, and the system works because the handoffs between them are explicit.

### The Core System Map

The Flutter app is the user-facing surface. It is written in Dart, runs on mobile, web, and desktop, and ships in two flavors today: the main **ForgeFlow** product and the branded **Barrio** flavor. The app holds no privileged secrets. It reads cached state from a small local SQLite database, asks Firebase Identity Platform to verify credentials, and asks the server-side proxy to perform anything that involves shared data, vendor credentials, or privileged action.

The **proxy** is a Dart server living under `tool/advisor_proxy/`. It is the only place in the system that holds database passwords, vendor API keys, and the Firebase admin surface, and it is the only place that talks directly to Postgres. Every protected action the app needs (sign-in handoff, MFA management, role lookups, admin operations, advisor calls) flows through the proxy. It deploys as a container to Google **Cloud Run**, which scales it without us managing servers.

The **shared database** is **Azure Database for PostgreSQL Flexible Server, version 16, in Canada Central**. Postgres holds everything that must be correct across users, devices, operators, and audits: auth sessions, audit logs, operator and location records, roles and permissions, usage and caps, advisor evidence, graph relationships, and the rollup tables that feed dashboards. The proxy talks to Postgres through a small set of safe abstractions; nothing else does.

**Firebase Identity Platform** sits beside the proxy as the credential authority. It validates passwords, manages multi-factor enrollment, issues signed ID tokens, and holds the custom claims that map a Firebase user back to a Forge Flow operator, location, and role. Forge Flow trusts Firebase to say "this is a real authenticated person" and then layers its own business identity on top.

At the public edge, traffic enters through **DNS** (for example `staging-api.feflow.org`), terminates HTTPS at a **Google managed load balancer** with a **Google managed certificate**, passes through **Cloud Armor** for edge filtering, and is forwarded to Cloud Run via a **serverless network endpoint group**. The advisor, Forge Flow's AI surface, sits above this stack and uses model providers, embeddings, vector search, graph traversal, and SQL evidence to ground its recommendations rather than answering from generic chatbot memory.

The mental picture is layered: a thin Flutter client, a fast local SQLite cache, a privileged proxy at the trust boundary, a hardened Postgres for shared truth, Firebase for credentials, a managed edge for public ingress, and the advisor for grounded answers.

### How It Works

```text
User opens Flutter app
  -> app reads local SQLite cache
  -> user signs in through Firebase
  -> app calls proxy for protected operations
  -> proxy verifies identity and permissions
  -> proxy reads/writes Azure Postgres
  -> Postgres applies tenant safety and audit rules
  -> app receives safe results
```

For public staging traffic the path is:

```text
https://staging-api.feflow.org
  -> DNS resolves the hostname
  -> Google load balancer receives traffic
  -> Google managed certificate terminates HTTPS
  -> Cloud Armor evaluates edge rules
  -> Cloud Run runs the proxy
  -> proxy answers the route
```

### Where It Lives

The app lives under `lib/`. The proxy lives under `tool/advisor_proxy/`. Local persistence lives under `lib/infrastructure/persistence/sqlite/` and server persistence under `lib/infrastructure/persistence/postgres/`. Database migrations are in `db/migrations/`. Architecture contracts, phase plans, and runbooks live in `docs/`, `docs/contracts/`, `docs/phases/`, and `runbooks/` (a single unified home as of the 2026-05-16 Wave 4 consolidation), with `PROJECT_TRACKER.md` and `CLAUDE.md` at the repo root.

## Quick Walkthroughs Before The Details

Four short walkthroughs make the system concrete before the detailed sections go deeper.

**A. User login.** A user enters email and password, Firebase validates the credentials and returns a signed ID token, and the app passes that token to the proxy. The proxy checks that the required custom claims are present, resolves the operator, location, and user context, writes a row to the auth session ledger in Postgres, and returns a permission snapshot. The app stores a secure session envelope locally and unlocks the protected surfaces. In one sentence: Firebase proves the person, and Forge Flow records the session and decides what business access that person has.

**B. Staging health check.** A browser requests `https://staging-api.feflow.org/readyz`. DNS resolves the name to Google's reserved load-balancer IP, the load balancer terminates HTTPS using the Google-managed certificate, Cloud Armor evaluates its edge policy, the serverless NEG forwards the request to the `forge-flow-staging-proxy` Cloud Run service, and the Dart proxy returns `{"status":"ok"}`.

**C. Advisor answer.** A user asks an operational question. A classifier picks the route (docs, SQL, graph, or mixed). Evidence is retrieved from the chosen sources, Voyage reranks the candidate evidence so the most useful pieces come first, Claude synthesizes a final answer that cites its sources, and the app shows the recommendation alongside the supporting context.

**D. Future shared-state update.** A manager updates an official schedule. The app sends the mutation to the proxy. The proxy verifies the JWT and the permission, the Postgres write runs inside a tenant-scoped transaction, an `event_outbox` row is written next to it, and a worker fans the event out so other devices know their local cache is stale.

## 2. Product Loop

### Plain English

The product is built around a loop: what happened before, what good should look like, what we expect this week, what we planned, what is happening now, what actually happened, and what we learn. Live operational data is messy (sales change, labor changes, reservations move, a manager adjusts a schedule), and if planned, live, and historical truths get mixed together the system becomes hard to trust. Forge Flow keeps those meanings separate.

### The Truth Model

Forge Flow's canonical architecture, recorded in `docs/contracts/core_app_architecture.md`, organizes the product into twelve named layers. The first layer is the **source systems** (POS, labor, reservations, accounting, banking) that produce raw evidence. The second is **canonical operational facts**: every vendor's exports, webhooks, and API payloads get translated into Forge Flow's own normalized shape so screens and advisor logic never see vendor-specific mess. The third is the **60-Day Benchmark**, the trusted history window that defines what "good" looks like for a comparable service. The fourth is the **TargetCycle**, a locked benchmark window that prevents the standard from drifting after a plan is made, and the fifth is the **ActiveTargetProfile**, the current target settings that the screens and formulas read against. The sixth is the **DemandForecastContext**, which combines reservations, walk-ins, and history into expected demand so staffing decisions are not based on averages alone. The seventh is the **SchedulePlan**, the operator's intended staffing, which then locks into the eighth layer, the **WeeklyPlanSnapshot**: the version of the plan that existed at the moment it was approved, so future variance comparisons are fair. The ninth layer is **Shift**, the live or whole-day view that shows what is happening right now. The tenth is **Variance**, the gap between plan and actual that turns raw numbers into an on-track / off-track signal. The eleventh is **History**, the closed truth that completed periods leave behind, and the twelfth is **Learn**, the teaching layer that uses repeated closed evidence to explain patterns and recommend coaching.

These twelve layers are bound by several cross-cutting rules. The integration spine carries vendor data inward without letting any one vendor's shape leak into the product. Hierarchy-scoped settings let business-level values inherit downward through org units to individual locations, and any settings surface must show which scope produced the effective value. Provenance rules say that source facts, derived metrics, and teaching summaries are never collapsed into one another. Mandatory separation rules forbid widgets from owning source-truth or daypart bucketing; the `LaborModel` is the only formula source, the `TargetCycle` locks the 60-day standard, and `WeeklyPlanSnapshot` is the locked week-in-force comparison plan.

The active feature line on top of these layers as of 2026-05-19 is **Per-Daypart Targets V1**, recorded in `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`. Per-daypart targets push the existing whole-day TargetCycle down to a daypart grain so lunch and dinner can carry distinct expected covers, labor, and verdict thresholds. The plan consolidates 44 surface-coverage gaps from the mobile walkthrough and ships in **seven slices** (Slice 0 through Slice 6). As of the 2026-05-19 status snapshot in `NEXT_WAVE_PLAN.md`, Slices 0 through 5 have landed; Slice 6 and any later follow-up work are still in flight. The database half of the work landed in seven migrations: `202605150400_per_daypart_v1_drop_close_authority.sql`, `202605160000_per_daypart_v1_per_period_target_persistence.sql`, `202605161500_per_daypart_v1_deprecate_locations_rollover_hour.sql`, `202605161501_per_daypart_v1_s0_verdict_persistence.sql`, `202605170000_per_daypart_v1_r5_covers_source_keyed_backfill.sql`, `202605170100_per_daypart_v1_r7a_covers_source_per_period_hierarchy.sql`, and `202605170200_per_daypart_v1_r7d_drop_legacy_covers_columns.sql`.

### How It Works

```text
POS + labor + reservation systems
  -> canonical operational facts
  -> 60-day benchmark snapshot
  -> TargetCycle + DemandForecastContext
  -> SchedulePlan
  -> WeeklyPlanSnapshot
  -> Shift
  -> Variance
  -> History
  -> Learn
```

In plain English: vendor systems provide facts, Forge Flow converts them into its own shape, the system picks a trusted history window, that becomes a target cycle, the operator plans against the target and the expected demand, the live shift compares current reality to the plan, closed shifts become history, and history feeds learning and future recommendations.

### Where It Lives

The canonical architecture and its binding rules live in `docs/contracts/core_app_architecture.md`. App state and runtime services live under `lib/state/`, `lib/services/`, and `lib/domain/`. SQLite-backed operational storage lives under `lib/infrastructure/persistence/sqlite/`. The phase-7.55 plain-English companion is `docs/contracts/phase_7_55_plain_english_architecture.md`. The active feature plan is `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`.

## 3. Repository Map

### Plain English

The repository is split by responsibility so that UI code, database code, cloud code, planning notes, and tests each have a clear home. When you make a change, the first question is which layer it touches: UI, app state, local data, server API, database schema, cloud deployment, or documentation.

### The Layout

The main Dart app lives under `lib/`. Inside it, `lib/domain/` holds pure formulas and interfaces that do not perform I/O, including the provider interfaces such as `llm_provider.dart`, `embedding_provider.dart`, and `rerank_provider.dart` under `lib/domain/services/`. `lib/services/` holds runtime services that coordinate auth, providers, gateways, and app operations, and now also a growing set of subdomains like `lib/services/email/` and `lib/services/realtime/`. `lib/state/` holds the notifiers and read models that the UI listens to. `lib/dev/` contains demo-only and developer-only code, `lib/auth/` holds the frozen permission key catalog that mirrors `docs/contracts/auth_permission_key_catalog.md`, and `lib/internal/` holds Forge & Flow internal-only modules that should never be touched by operator-facing surfaces.

Persistence is split in two: `lib/infrastructure/persistence/sqlite/` defines the local schema, migrations, and DAOs that back the app's local working copy, while `lib/infrastructure/persistence/postgres/` holds the only place in the codebase where raw `package:postgres` imports are allowed, CI lint enforces that boundary. Three large surfaces sit alongside the main app: `lib/admin/` holds the internal admin console (services, gateways, and screens), `lib/operator_web/` holds the operator-facing web console (router, auth, account, demo state, and screens), and `lib/integrations/` holds vendor integrations for labor, POS, and reservation data.

A second group of `lib/` subdirectories supports the UI without owning runtime behavior. `lib/screens/` holds the actual screen widgets that the routes render into. `lib/widgets/` holds the reusable widget primitives shared across screens. `lib/models/` holds plain data classes (read models like `shift_record` and `week_record`, plus the teaching summary shapes used in §17) that flow between services and screens. `lib/theme/` holds `app_theme.dart`, which is the single source of the Forge & Flow brand palette (Sunset, Peacock, Jade, Ocean, Red Sand, Shell) referenced throughout the product and the book you are reading. `lib/l10n/` holds the localization entries, and `lib/utils/` holds small cross-cutting helpers like `formatters.dart` and the IANA timezone resolver used by §19's integration timestamps.

Outside `lib/`, the proxy lives under `tool/advisor_proxy/` as an independently deployable Dart server. Database schema history lives under `db/migrations/`, where each migration creates or evolves tables, indexes, RLS policies, functions, and extensions. Automated tests live under `test/`, covering MFA enrollment, recovery, RLS, contract shape, migration shape, and proxy behavior. Durable architecture rules, the ones future work must obey, live under `docs/contracts/`, while active phase plans live under `docs/phases/`. Operational procedures for live maintenance live under `runbooks/`, which the 2026-05-16 Wave 4 consolidation merged into a single unified home (previously scattered across multiple subdirectories). CI workflows live under `.github/workflows/`, and helper scripts (including the staging proxy deploy script) live under `scripts/`.

### How It Works

When a feature touches multiple layers, the path typically goes:

```text
docs/contract or phase plan
  -> db/migrations if schema changes
  -> lib/infrastructure if persistence changes
  -> lib/services if orchestration changes
  -> lib/state if app state changes
  -> lib/screens/widgets if UI changes
  -> test/ coverage
```

### Where It Lives

The repo index is `docs/README.md`. Root status is `PROJECT_TRACKER.md`. Repo rules and the authority order are `CLAUDE.md`. The forward plan is `docs/_indices/NEXT_WAVE_PLAN.md`.

## 4. App Runtime And UI

### Plain English

The app is the part users see, with screens for the current shift, variance, plans, benchmarks, settings, and notifications. It ships in two flavors today, **ForgeFlow** (the main product, launched from `lib/main_forgeflow.dart`) and **Barrio** (a branded/demo variant, launched from `lib/main_barrio.dart`), and both flavors share the same architectural backbone. Two additional entrypoints exist for non-app surfaces: `lib/main_admin.dart` boots the internal admin console, and `lib/main_operator_web.dart` boots the operator web console.

### The Runtime Path

The visible app needs a reliable startup path before any protected screen renders. The flavor entrypoint is the first file that runs; it chooses which runtime bindings to install. From there, `bootstrapAndRunApp` performs the work of starting the app: it checks whether the Firebase auth runtime is enabled, builds the dependency tree, hydrates local SQLite-backed state, creates the `AuthSessionNotifier`, attempts to rehydrate any secure session envelope already on the device, and only then constructs the provider tree that feeds the widget tree.

Flutter is the UI framework that makes the app portable across mobile, web, and desktop, and Dart is the shared language across the app and the proxy. The `provider` package wires dependencies and notifiers into the widget tree so that any screen can read the current auth or session state without it being threaded through every constructor. Notifiers are state objects that emit changes; screens listen and rebuild when state updates rather than polling for new data. The `MaterialApp` shell owns routing, theme, and global navigation, and an auth gate sits between the shell and the protected surfaces so a logged-out user sees the login or MFA flow instead of the dashboard. If the auth runtime is not configured at all, fail-closed defaults take over: protected behavior denies by default rather than silently unlocking.

### How It Works

```text
main_forgeflow.dart or main_barrio.dart
  -> checks whether Firebase auth runtime is enabled
  -> builds runtime bindings
  -> bootstrapAndRunApp
  -> hydrate local SQLite-backed state
  -> create AuthSessionNotifier
  -> try to rehydrate secure session
  -> build provider tree
  -> show the app shell
```

### Where It Lives

The flavor entrypoints are `lib/main_forgeflow.dart` and `lib/main_barrio.dart`. Bootstrap lives in `lib/forge_flow_bootstrap.dart`. The app shell is `lib/forge_flow_app.dart`, the Barrio shell is `lib/barrio_app.dart`, and auth state is `lib/state/auth_session_notifier.dart`.

## 5. SQLite: Local App Database

### Plain English

SQLite is the app's local working copy. It is fast, it lives inside the app, and it is used for demo data, replay scenarios, local app state, cached read models, and offline-friendly reads. SQLite is not the official record for anything that must be correct across users, devices, operators, or audits, that authority belongs to Postgres. Anything shared or security-sensitive must eventually flow through the server path.

### The Local Database

The local database layer is built on `sqflite` for mobile builds and `sqflite_common_ffi` for desktop and test environments. A monotonically increasing schema version (currently `37`, declared in `lib/infrastructure/persistence/sqlite/sqlite_database.dart`) tells the app which migrations to run when an existing install opens; each migration is a controlled change that adds or evolves tables and columns without breaking older local data. On first launch, or whenever demo data is requested, seed data populates the local database with a known starting restaurant and replay fixtures, and a mock-replay state machine drives sample business days through the system so that screens have realistic operational data to render against even before live integrations are wired up.

Above the raw storage, the layer defines screen-friendly read models, pre-shaped row types that the UI can render directly, and caches operational data so that complex dashboards do not have to recalculate from raw facts on every frame. The result is that the app stays responsive, the demo experience is repeatable, and the local schema can evolve under migrations without losing user data.

Demo mode deserves a special call-out here. Forge Flow's second Hard Promise (HP #2) says demo mode is a *writer-side* switch, not a reader-side fork: demo data lives in the same standard SQLite tables as production data, under a single `DemoScope.restaurantId = 'demo_restaurant_001'`. The reader code never branches on `kDemoMode`; only writers do. As of the May 2026 wave, demo↔live switching is also a runtime user-facing control surfaced in `lib/screens/settings/settings_demo_live_switch.dart`, which reads `DemoModeStateNotifier` and calls the proxy to flip the per-(operator, location, category) `demo_mode_state` rows in Postgres without requiring a rebuild.

### What SQLite Stores

The local database currently stores restaurant locations, connector configs, import runs, raw import records, sync watermarks, active target profiles, target profile versions, shift records, week records, baseline selected records, open-shift snapshots, reservation-book snapshots, mock-replay state, wage roles, target cycles, weekly plan snapshots, benchmark selection summaries, restaurant timing configs, and app notifications.

### How It Works

```text
app starts
  -> opens local SQLite database
  -> checks schema version
  -> runs needed migrations
  -> seeds demo/replay state if needed
  -> services read local records
  -> state notifiers produce screen data
  -> UI displays the result
```

### Where It Lives

SQLite code lives under `lib/infrastructure/persistence/sqlite/`. The desktop/dev database file is `forge_flow_v2.db`. The current schema version is `37`. The demo-mode contract is `docs/contracts/demo_mode_contract.md`.

## 6. Postgres: Shared Server Truth

### Plain English

Postgres is the official shared system of record. SQLite is the local working copy; Postgres is the source of truth that must work across users, devices, operators, audits, admin actions, advisor systems, and future automation. The app should never bypass Postgres for shared or sensitive data.

### The Managed Platform

Forge Flow runs on **Azure Database for PostgreSQL Flexible Server**, version 16, in the **Canada Central** region. Azure handles the operational burden of hosting, backups, and platform maintenance, which leaves the team free to focus on schema and access patterns rather than database administration. The choice of PostgreSQL 16 fixes the available syntax, the supported extensions, and the baseline behavior that migrations target, so behavior stays predictable until an explicit upgrade is planned.

### Code Locations

Postgres code is split into two homes that do different jobs. `lib/infrastructure/persistence/postgres/` holds the runtime access layer: the executor, the connection pool, the transaction wrapper, the tenant-scoped repository base classes, and the adapter that isolates the raw `package:postgres` driver. `db/migrations/` holds the schema history: each migration creates or evolves tables, indexes, RLS policies, functions, and extensions, and the directory is the source of truth for what production should look like at any point in time. Production applies are gated by `runbooks/phase_9_production1_migration_apply_runbook.md`.

### The Access Abstractions

Application code never talks directly to a Postgres connection. Repositories call a `PostgresExecutor` to run SQL, a `PostgresTransaction` to bundle several operations so they succeed or fail together, and a `PostgresPool` to reuse connections rather than opening a new socket per query. A `TenantContext` value carries the current operator, location, and user identifiers into every protected transaction so that audit, RLS, and repository logic all agree on whose data is being touched. The `OperatorScopedRepository` base class enforces that operator-owned data access always runs inside tenant context. The raw `package:postgres` driver is held behind an adapter and is the only place in the codebase where direct database sockets are allowed, a CI lint enforces that no other file imports it. This isolation keeps security, transaction handling, and testing patterns consistent across every repository.

### Important Extensions

Postgres extensions add capabilities the database needs beyond standard SQL. `pgcrypto` provides cryptographic hashing, UUID helpers, and the digests that feed the audit hash-chain. `pgvector` stores and similarity-searches embeddings for the advisor's document retrieval, and `pg_diskann` provides a scalable approximate-nearest-neighbor index for that vector data as the corpus grows. `AGE` adds property-graph capability so the database can answer relationship-style questions without standing up a separate graph store. `pg_cron` schedules recurring database jobs such as rollup refreshes. `pg_partman` partitions large tables, particularly audit logs, into manageable per-tenant, per-day chunks. `pg_stat_statements` surfaces query performance so slow or hot SQL can be diagnosed from real traffic. `ltree` stores and queries hierarchical paths such as operator → brand → region → district → location, and is the foundation for hierarchy-scoped settings: business-level values inherit downward, org-unit values override their ancestors, and location values override everything above them. The May 2026 brand-tier migration (`202605200900_brand_org_unit_type.sql`) added brand as a real org-unit type alongside region and district, with cascading account fields (timezone, locale, currency, contact) resolved through `org_unit_account_overrides`. Any admin, operator, proxy, mobile, or migration work that exposes settings must preserve that rule and show which scope produced the effective value. Integrations remain location-editable because vendor credentials are bound to a specific location.

### Important Execution Patterns

Most database work runs through `runInTenantContext`, which starts a transaction and sets the operator, location, and user identifiers as transaction-local Postgres variables. Because these settings are transaction-local rather than session-global, tenant context cannot leak across requests on a reused pooled connection. Maintenance and backend work that is not tied to a single user action runs through `runAsSystem`, which keeps that work traceable with an explicit reason while letting it bypass normal user scope. Outside these two paths, raw driver usage is prohibited, keeping `package:postgres` behind the adapter is what guarantees that future shortcuts cannot bypass tenant context, transactions, or testing seams.

### How It Works

A typical secure database operation goes:

```text
proxy receives request
  -> verifies identity
  -> builds TenantContext
  -> repository calls runInTenantContext
  -> Postgres transaction starts
  -> tenant variables are set locally for this transaction
  -> SQL runs
  -> RLS filters allowed rows
  -> transaction commits or rolls back
```

The reason `package:postgres` is not scattered across the codebase is so that the access pattern stays uniform:

```text
raw database driver
  -> adapter
  -> executor/pool/transaction abstractions
  -> repositories
  -> services/proxy/app
```

### Where It Lives

Postgres code is in `lib/infrastructure/persistence/postgres/`. Migrations are in `db/migrations/`. Production apply guidance is `runbooks/phase_9_production1_migration_apply_runbook.md`.

## 7. Tenant Safety And Row Level Security

### Plain English

Forge Flow is multi-tenant: many operators and many locations can live in the same database. The rule is simple, Operator A must not see Operator B's data, and the system enforces it in two layers. The app and proxy code pass the correct operator, location, and user context on every protected request, and Postgres Row Level Security blocks rows that fall outside that context even if a query forgets to filter. Repository discipline is the first line of defense; RLS is the database-level safety net.

### Identity And Policies

Every protected database operation carries three identifiers: `operator_id` labels which customer/operator owns the work, `location_id` labels which restaurant location it belongs to, and `user_id` labels who is performing the action. Concretely, "operator_id = Restaurant Company A, location_id = Downtown, user_id = manager Sarah" is the kind of identity context that travels with the transaction so that the app, the proxy, the audit log, and the RLS policies are all talking about the same tenant and actor.

Row Level Security is a Postgres feature that hides rows that do not match the current context. RLS policies define what each role is allowed to select, insert, update, and delete; a typical policy says "only allow rows where `row.operator_id` matches the current operator." Policies are written using a small set of approved **wrapper functions** rather than bare `current_setting()` calls (for example, `app_current_operator_id()`) because the wrappers are `STABLE LEAKPROOF PARALLEL SAFE` and are guaranteed to behave consistently across queries. A CI lint at `tool/rls_policy_lint.dart` enforces that policies never read bare session settings.

Tenant context is set with `set_config(..., true)` so that the current operator, location, and user are recorded only for the duration of the current transaction. This is critical because the proxy reuses pooled database connections; if context were set as a session-global, it could leak from one request into the next. Every operator-scoped table is also indexed with a tenant-leading index (typically a B-tree starting with `operator_id` or `(operator_id, location_id)`) so that tenant-scoped queries stay fast even as the row count grows. CI lint enforces the index-shape rule. Finally, operator-scoped tables store timestamps as `TIMESTAMPTZ` (UTC) plus a denormalized `business_date` column, so that a late-night close at 1 AM still belongs to the correct operational day and cross-timezone events can still be ordered correctly.

### How It Works

```text
verified user belongs to operator X
  -> proxy creates TenantContext(operator X)
  -> transaction sets app.operator_id = X locally
  -> query asks for records
  -> RLS policy checks current operator
  -> Postgres returns only rows for operator X
```

The non-negotiable rule is: never use global session settings for tenant context. Use transaction-local settings so context cannot leak between requests on a reused connection.

### Where It Lives

The RLS wrapper functions live in `db/migrations/202604280000_phase_9_0sigma_b_rls_wrappers.sql`. Existing policies were rewritten to use the wrappers in `db/migrations/202604280001_phase_9_0sigma_b_rewrite_existing_policies.sql`. The RLS shape lint is `tool/rls_policy_lint.dart`. Tenant execution code lives under `lib/infrastructure/persistence/postgres/`. The binding contract is `docs/contracts/hardening_rls_and_repository_pattern_contract.md`.

## 8. Proxy And API Layer

### Plain English

The proxy is the secure server-side front desk. The Flutter app does not hold database passwords, vendor secrets, admin credentials, or privileged service keys, the proxy does. When the app needs protected work done, it asks the proxy, and the proxy verifies who the caller is, which operator and location they belong to, what permissions they hold, and whether the request is allowed before it touches the database or any external service.

### Routes, Tokens, And Trust

Each capability the app needs is a versioned route under `/v1/...`; breaking changes get a new prefix like `/v2/...`, and old paths stay live until they are explicitly deprecated. Routes use standard HTTP verbs (`GET` for reads, `POST` for state-changing operations, `PATCH` for partial updates, `DELETE` for removals), and request and response bodies cross the API boundary as data transfer objects (DTOs) with typed fields, so that the app never sees raw database internals. Every write is idempotent: the client carries an idempotency key, and the proxy records that key in a `proxy_requests` table with a UNIQUE constraint so that retries cannot accidentally double-charge or double-act.

Identity arrives as a Firebase-issued JWT in the `Authorization: Bearer` header. The proxy verifies the signature, reads the required custom claims (`operator_id`, optional `user_id`, optional `location_id`, role and admin flags, role-version fields), and rejects the request fail-closed if anything is missing. Permission guards then check that the resolved identity is actually allowed to perform this specific action (only admins can change role definitions, only operators with the right scope can update settings, and so on) before any data-changing code runs.

The proxy is a Dart executable that runs as a container on **Cloud Run**. The staging deployment is named `forge-flow-staging-proxy`, and Cloud Run scales it automatically as request volume changes. There is no parallel API stack: every AI surface, every admin action, and every shared-state mutation plugs into the same proxy plus the provider abstractions, counter and cap logic, and feature flags introduced in Phase 11a.10.

### How It Works

```text
Flutter app calls /v1/auth/permissions/snapshot
  -> proxy reads Bearer token
  -> proxy verifies Firebase JWT
  -> proxy derives OperatorContext
  -> proxy checks permission rules
  -> proxy opens tenant-scoped Postgres transaction
  -> repository reads allowed data
  -> proxy returns safe response DTO
```

The full route surface is large (roughly 90 versioned routes across auth, admin, team, integrations, corpus, feature flags, graph maintenance, mobile push, and realtime). The representative slice that this guide leans on is the health and smoke endpoints (`GET /healthz`, `GET /readyz`, `GET /health`, `GET /v1/scope`, `GET /v1/usage-smoke`, `GET /v1/advisor-smoke`); the session and password endpoints (`POST /v1/auth/session/login`, `/refresh`, `/revoke`, `/revoke-all`, `POST /v1/auth/password/change`); the MFA endpoints (`POST /v1/auth/mfa/totp/begin` and `/confirm` for setup, `POST /v1/auth/mfa/recovery/request` and `GET /v1/auth/mfa/recovery-codes/viewed` for the admin-mediated reset path, and the factor `list`/`revoke`/`removal/cancel` paths); the permission snapshot route (`GET /v1/auth/permissions/snapshot`); and the protected `/v1/admin/auth/*` admin surface. The complete route catalog lives in `tool/advisor_proxy/advisor_proxy.dart` as named constants.

### Where It Lives

The proxy entrypoint is `tool/advisor_proxy/main.dart`. Wiring lives in `tool/advisor_proxy/proxy_bootstrap.dart`, and the route handlers are in `tool/advisor_proxy/advisor_proxy.dart`. The container build is `Dockerfile`. The deploy script is `scripts/deploy_staging_proxy.ps1`.

## 9. DNS, Edge, And Cloud Run

### Plain English

Apps and users do not call a raw server process; they call a friendly name. For staging that name is `staging-api.feflow.org`. DNS translates that name into a network destination, Google receives the traffic, HTTPS and edge rules are applied, and the request is forwarded to the Cloud Run proxy. The naming and edge layer is what makes infrastructure changeable behind the scenes without forcing client updates.

### How A Public Request Travels

A **hostname** like `staging-api.feflow.org` is the stable client-facing identifier. **DNS** translates hostnames into destinations. An **A record** points directly to an IPv4 address, in this case Google's reserved load-balancer IP `34.54.204.29`, and a **CNAME** points one hostname at another. The current staging fix is an A record to the reserved Google edge IP; CNAME is the pattern to reach for when a provider owns a target hostname whose underlying IPs may change.

HTTPS trust comes from a **Google-managed certificate** issued for the hostname once DNS is publicly visible. The **load balancer** is the public entry point that terminates HTTPS and routes traffic to the backend. Before traffic reaches the backend, **Cloud Armor** evaluates an edge policy that logs or blocks suspicious requests, and an optional **reCAPTCHA edge path** sits ready for cases where bot or abuse protection is needed. A **serverless network endpoint group** (serverless NEG) connects the load balancer to the **Cloud Run service**: `forge-flow-staging-proxy` for staging, where the Dart proxy container actually runs.

### How It Works

```text
https://staging-api.feflow.org/readyz
  -> DNS A record
  -> 34.54.204.29
  -> Google HTTP(S) load balancer
  -> Google managed certificate
  -> Cloud Armor/reCAPTCHA policy path
  -> serverless NEG
  -> forge-flow-staging-proxy Cloud Run service
  -> Dart proxy route
  -> {"status":"ok"}
```

The reason hostnames matter is that clients call stable names rather than IPs, certificates are issued for names, and the infrastructure behind the name can move without forcing every app to update. CNAME matters when another provider owns the changing backend target; for staging the correct final fix turned out to be an A record to Google's reserved IP.

### Where It Lives

Edge status lives in `PROJECT_TRACKER.md`. The deploy script is `scripts/deploy_staging_proxy.ps1`. The proxy health routes are in `tool/advisor_proxy/advisor_proxy.dart`.

## 10. Authentication

### Plain English

Authentication answers "Who are you?" Firebase handles the credential side: it confirms the password and MFA, says which Firebase user is signed in, and issues a legitimate signed ID token. Forge Flow then takes that proof and adds business meaning: which operator the user belongs to, which location they can act in, what roles and permissions they hold, and which session should be recorded.

### Identity Handoff And Sessions

Firebase Identity Platform is the credential authority. It manages the email-password sign-in flow, the MFA factor enrollment, and the issuance of ID tokens, which are JSON Web Tokens signed by Firebase. Each Firebase user has a stable UID, and Forge Flow's user records reference that UID so that the business identity in Postgres is permanently linked to the credential identity in Firebase.

What turns a Firebase token into a Forge Flow session is the set of **custom claims** baked into the token. These claims carry the `operator_id`, the optional `user_id` and `location_id`, the role and admin flags, and the role version fields that let the proxy detect when a user's permissions have changed since the token was issued. If any required claim is missing, the proxy and the app both fail closed and refuse the request rather than guess.

When a sign-in succeeds, the proxy writes a row to the auth session ledger in Postgres so that the session has a server-side record beyond the device. The ledger captures login, refresh, and revoke events, which makes session lifecycle auditable and revocable, a security review can trace exactly when a session began, was refreshed, or was ended, regardless of what the device says locally. The app stores a secure session envelope in device-protected storage so the session can be rehydrated without keeping plain credentials around.

### How It Works

```text
user enters email/password
  -> Firebase validates credentials
  -> app receives Firebase ID token
  -> app/proxy requires Forge Flow custom claims
  -> proxy writes auth session ledger in Postgres
  -> app stores secure session envelope
  -> app unlocks authenticated surfaces
```

The important claims that must be present are `operator_id`, the optional `user_id` and `location_id`, the role and admin/support flags, and the role version fields. If a required claim is missing, the request fails closed.

### Where It Lives

Auth state lives in `lib/state/auth_session_notifier.dart`. The Firebase runtime wiring is in `lib/services/auth/firebase_auth_runtime_bindings.dart`, and the login service is `lib/services/auth/firebase_auth_login_service.dart`. The proxy-side auth gateway is `lib/services/auth/proxy_auth_operations_gateway.dart`. The auth schema is `db/migrations/202604250008_auth_schema_foundation.sql`.

## 11. MFA And Admin Reset

### Plain English

Multi-factor authentication means password plus another proof. The launch path uses TOTP, the rotating six-digit codes from an authenticator app, because it is strong, standard, and avoids SMS dependency. Recovery-code display and challenge entry are intentionally not exposed in the launch UX; the visible product path for a user who loses access to their authenticator is restaurant-admin reset with a 24-hour removal delay.

### Setup, Recovery, And Throttling

TOTP setup runs through the proxy and Firebase's Identity Toolkit. The user begins setup, the app asks the proxy to start an enrollment, the proxy talks to the Identity Toolkit to create the TOTP secret, the user scans or types the secret into their authenticator, and the user confirms a code. The proxy records the MFA factor state in Postgres so the system knows the factor is live.

When a user loses their second factor, the recovery flow is admin-mediated rather than self-service. The user selects "Contact your admin," and a restaurant admin starts the reset from the Team surface. The proxy schedules a 24-hour removal that either the user or the admin can cancel while it is pending; when the window completes, a worker performs the actual removal and writes audit records. This delayed removal keeps account recovery tied to ownership and audit, and means the visible product never displays backup codes that could be stolen alongside a password.

Hash-only primitives for recovery codes remain in the codebase for compatibility tests, but they are not exposed in the app UX. Sensitive values are stored as one-way hashes so that a database leak does not expose raw recovery material. An attempt ledger records MFA and recovery attempts to support rate-limit decisions and abuse detection, and rate limits throttle repeated guesses so that recovery and MFA endpoints cannot be hammered by automation.

### How It Works

TOTP setup:

```text
user begins TOTP setup
  -> app calls proxy
  -> proxy talks to Firebase Identity Toolkit
  -> user scans/setup secret
  -> user confirms code
  -> proxy records MFA factor state
```

Admin reset and delayed removal:

```text
user requests reset or admin starts reset
  -> app sends reset request to proxy
  -> proxy checks freshness and permissions
  -> proxy schedules 24-hour removal
  -> user/admin may cancel while pending
  -> worker completes the removal when due
  -> audit records are written
```

### Where It Lives

The app-side MFA gateway is `lib/services/mfa/proxy_mfa_operations_gateway.dart`. The recovery attempts schema is `db/migrations/202604280011_phase_9_0sigma_recovery_code_attempts.sql`, and the recovery attempt store is `lib/infrastructure/persistence/postgres/repositories/recovery_code_attempt_store.dart`. Proxy MFA routes are in `tool/advisor_proxy/advisor_proxy.dart`.

## 12. Permissions, Roles, And Admin

### Plain English

Permissions answer "What are you allowed to do?" Forge Flow uses roles so permissions are manageable. A manager, owner, staff member, internal admin, or support user can receive different permissions. The app does not guess permissions from a job title, it asks for a permission snapshot and obeys it.

### RBAC, Snapshots, And Admin Routes

The model is **role-based access control**: users get roles, and roles expand into a set of named permission keys such as `auth.roles.update` or `schedule.view`. Permission keys are the explicit capability names that gates check against, which keeps capabilities testable and visible instead of hidden in UI conditionals. Roles bundle permission keys so that common access patterns can be reused across many users, and a role grant attaches a role to a user inside an operator or location context, for example, "Sarah has Manager at Downtown." This scoping lets multi-location operators give the same person different access at different locations without rewriting the role itself. Roles are defined in a hierarchy-scoped way (per the May 2026 roles redesign in `db/migrations/202605142100_phase_R_1L_roles_schema_rewrite.sql` and its follow-ups) so that role definitions can inherit from business level down through org units to specific locations.

The **permission snapshot** is the resolved view that the app actually uses. When the app asks the proxy for `/v1/auth/permissions/snapshot`, the proxy verifies the user, reads the relevant role grants and role permissions, resolves the effective permission set, and returns it as a DTO. The UI then enables and disables protected actions based on that snapshot rather than trying to recompute authorization logic on the client.

Administrative changes, creating roles, editing role permissions, granting roles to users, happen through protected `/v1/admin/auth/*` routes on the proxy. Every administrative change writes to a role audit log that preserves who changed access and when, which is essential for both security investigations and customer support. The launch model is RBAC, but the architecture leaves room for **relationship-based access control** (ReBAC) in Phase 12, where access can depend on relationships like "Sarah manages locations X and Y" rather than only on role assignments.

### How It Works

```text
app requests permission snapshot
  -> proxy verifies user
  -> proxy reads roles and role permissions
  -> proxy resolves effective permissions
  -> app receives permission snapshot
  -> UI enables/disables protected actions
```

The B17 admin role catalog CRUD is implemented and smoke-passed on staging. The operator-facing Settings → Team surface can consume the role catalog when that slice resumes.

### Where It Lives

Role repositories live under `lib/infrastructure/persistence/postgres/repositories/`. The auth schema foundation is `db/migrations/202604250008_auth_schema_foundation.sql`, and the May 2026 roles rewrite is `db/migrations/202605142100_phase_R_1L_roles_schema_rewrite.sql`. Admin proxy routes are in `tool/advisor_proxy/advisor_proxy.dart`. The frozen permission key catalog mirror lives at `lib/auth/` and `docs/contracts/auth_permission_key_catalog.md`.

## 13. Service Principals

### Plain English

A service principal is a non-human identity. Humans log in with Firebase. Automation should not pretend to be a human. A workflow or backend job needs its own identity so audit logs can say exactly what acted, for example, the actor for a nightly audit anchor job is `sp:nightly-audit-anchor-job`, not the engineer who deployed it.

### Issuance, Verification, And Audit Attribution

Service principals receive scoped credentials in the form of JWTs whose subjects are prefixed `sp:` (for example, `sp:rollup-worker`). The prefix makes it trivially easy for the proxy to distinguish automation tokens from Firebase human tokens, route them through different handling, and attribute audit rows correctly. An issuer route inside the proxy creates the signed token for an approved service, and a verifier validates incoming `sp:` tokens before any work runs, rejecting expired or unknown identities.

Every audit row stores an **actor kind** field so that a reviewer can tell whether a person, a service, or the system acted. Actor-kind values are drawn from a single canonical catalog, `ActorKindLabelCatalog` in `lib/services/auth/actor_kind_label_catalog.dart`. Both the `user` and `team_member` actor-kind values resolve to the display label **"Team member"**; both `service` and `service_principal` resolve to **"Service account"**. Both the admin console and the operator-web audit surface read labels from this single source, which means the same audit row reads consistently regardless of which UI is rendering it.

Future Phase 12 workflow identities will use the same `sp:` pattern so that automation can be granted scoped permissions, tracked for cost, and tied to audit attribution without ever borrowing a human user's account.

### How It Works

```text
workflow needs to run
  -> requests or receives service-principal JWT
  -> proxy verifies `sp:` token
  -> proxy derives service actor context
  -> action runs with scoped permissions
  -> audit log records service actor
```

The current state is that the verifier and the issuance route exist locally, and the 2026-05-03 Production1 migration apply landed the service-principal issuance permission key in production. Phase 12 workflows still need live issuance evidence before they can rely on this path end-to-end.

### Where It Lives

The service-principal schema is `db/migrations/202604280004_phase_9_0sigma_d_service_principals.sql`. JWT issuance and verification code is in `tool/advisor_proxy/advisor_proxy.dart`. The actor-kind label catalog is `lib/services/auth/actor_kind_label_catalog.dart`.

## 14. Audit And Compliance

### Plain English

Audit answers "Who did what, when, and under which authority?" For sensitive systems, ordinary logs are not enough, they can be edited or rotated away. Forge Flow is building toward tamper-evident audit logs where records are chained together with cryptographic hashes, so that altering an old audit entry breaks the chain that follows it. This does not make the database impossible to alter; it makes alteration detectable.

### Hash Chains, Anchors, And Redaction

Every sensitive action writes a durable **audit row** that captures the actor (human or service), the action, the resource, the operator and location context, and the timestamp. The actor field identifies the source, either a person like "manager Sarah" or a service principal like `sp:rollup-worker`, and the **actor kind** field separates human, service, and system actions so reviewers can apportion responsibility correctly. The actor-kind label catalog described in §13 now provides a single source of truth so audit rendering stays consistent across admin and operator-web surfaces.

Tamper evidence comes from chaining. Each audit row includes a reference to the previous row's hash, and `pgcrypto` computes the digest for the current row over its own content plus that previous hash. The result is a hash chain: changing any historical row produces a different digest, which breaks the chain at every row after it. A daily **anchor** writes a chain checkpoint to an external Azure Blob, outside the normal table write path, so that even if Postgres history were tampered with, an independent point of comparison still exists. The anchor blob is treated as immutable; it preserves checkpoint evidence so audit reviews are not entirely dependent on database history.

Privacy obligations like GDPR right-to-erasure are handled through redaction patterns rather than deletion. Redaction removes sensitive personal content from an audit row while preserving its structural shape, so the audit trail and the chain remain intact while the user-identifying detail is gone.

A known contract note: `audit_logs.actor_principal_id` and `auth_events_audit.actor_service_principal_id` describe overlapping concepts but differ in name and type. This is intentional, but query authors need clear guidance to avoid mistaking them for each other; this is tracked as audit-attribution work item B34, now closed.

### How It Works

```text
sensitive action happens
  -> audit row is written
  -> row includes previous hash reference
  -> pgcrypto computes digest
  -> daily anchor records chain checkpoint
  -> verifier can later walk the chain
```

### Where It Lives

The audit schema is `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`. The live actor-kind repair migration is `db/migrations/202604280013_phase_9_0sigma_audit_actor_kind_live_repair.sql`. The audit anchor tool lives at `tool/audit_anchor/audit_anchor.dart`. The verification and erasure runbooks are `runbooks/audit_chain_verify_runbook.md` and `runbooks/gdpr_erasure_runbook.md`. The architecture binding is `docs/contracts/audit_log_architecture_contract.md`.

## 15. Eventing And Real Time

### Plain English

When something changes on the server, other parts of the system may need to know. The safe pattern is not "send a notification and hope", it is to save the real database change, save an event row, and let a worker deliver the event. The event row is durable; a notification is only a wake-up.

### Outbox, Notify, And Workers

The pattern is the **transactional outbox**: alongside the business write (changing a schedule, updating a role, closing a shift), the same transaction writes a row into the `event_outbox` table. Because the business write and the event live in the same transaction, the event is durable the moment the change is committed, it cannot be lost even if a worker is down or the network is flaky.

Workers learn about new events through `LISTEN`/`NOTIFY`: when an outbox row is inserted, Postgres fires a notification that wakes any listening worker. The notification is just a wake-up; the worker reads the outbox table for the actual data, which means a missed notification is not a data loss. Workers claim rows for processing using `SELECT ... FOR UPDATE SKIP LOCKED`, which lets several workers run in parallel without two of them claiming the same row.

A **lease** model means each worker owns a row for a limited time, so that a failed or crashed worker eventually releases the row for another worker to retry. Repeated processing is safe because consumers handle events **idempotently**: retrying the same event does not double-charge, double-write, or duplicate side effects. Events that repeatedly fail are moved to a **dead-letter** holding area so a single bad payload cannot block the entire backlog, and downstream fan-out to **Pub/Sub** subscribers or **WebSocket**-connected clients lets multiple consumers (other services, other devices) receive the same change without each having to query Postgres directly.

Postgres's `pgmq` extension is not available on Azure Flexible Server, which is why the system uses `SKIP LOCKED` (and, for some workloads, Cloud Tasks) rather than a managed queue. The reason NOTIFY is not the source of truth is that notifications can be missed, but the outbox row remains, and a worker can always catch up by reading the table.

### How It Works

```text
business mutation happens
  -> event_outbox row is written
  -> Postgres NOTIFY wakes worker
  -> worker claims rows with SKIP LOCKED
  -> worker publishes event
  -> row is marked delivered
  -> app refresh/invalidation can happen
```

The current gap is that the event table exists, but the consumer worker scaffold, the dead-letter contract, the retention sweep, and the operator-facing UX surfaces are still queued.

### Where It Lives

The event-outbox contract is `docs/contracts/event_outbox_contract.md`. The schema is `db/migrations/202604280003_phase_9_0sigma_e_event_outbox.sql`.

## 16. Usage, Caps, And Rollups

### Plain English

Usage tracking answers "how much did someone use?" Caps answer "how much are they allowed to use?" Rollups answer "can we summarize a lot of raw detail into faster dashboard numbers?" Together they cover three jobs: counting consumption, enforcing limits, and pre-computing summaries so dashboards stay fast.

### Logs, Caps, And Reconciliation

Every measurable consumption, an advisor call, a vendor sync, an export, writes a row to a **usage log** so that billing, abuse detection, and product limits all have a factual trail. **Usage caps** define how much usage is allowed by operator, slot, and period. The cap identity uses a **two-slot key model** that separates the dimensions necessary for reconciliation: an operator slot plus a location or capability slot. Reconciliation compares actual usage against the cap and surfaces overages, drift, or accounting mismatches before they turn into surprise bills.

**Rollups** are pre-computed summaries at multiple time grains, daypart, day, week, month, quarter, year, and at multiple entity levels, operator, location. Because dashboards do not have time to recompute totals from raw rows on every load, the rollup tables hold the answer and the dashboards read from them. An **aggregation state** tracker remembers when each rollup was last refreshed so that health checks can tell whether a dashboard is fresh or stale. The rollup refresh work runs as scheduled Postgres jobs through the **pg_cron** extension, which keeps recurring summary maintenance close to the data and automates what would otherwise be a manual operations chore.

### How It Works

```text
raw usage or operational events arrive
  -> usage_logs record details
  -> usage_caps define limits
  -> rollup functions aggregate detail
  -> dashboards read summary tables
  -> health checks monitor freshness
```

The Q3.1 gap that originally tracked `usage_logs` needing a matching two-slot mirror for cap-versus-actual reconciliation (item B33) is now complete: the writer and constraint posture support reconciliation.

### Where It Lives

The usage foundation is `db/migrations/202604250005_advisor_cloud_foundation.sql`. The two-slot cap migrations are `db/migrations/202604280006_a/b/c_phase_9_0sigma_g_usage_caps_two_slot_*.sql`. The rollup migrations are `db/migrations/202604280010_a/b/c_phase_9_0sigma_k_rollups_*.sql`.

### Plans And Limits V1

On top of the usage and cap foundation, the May 2026 **Plans & Limits V1** work introduced subscription tiers and contract pricing as first-class operator attributes. Six canonical tiers (Pilot, Starter, Premium, Elite, Pro, Enterprise) are pinned by a CHECK constraint on `operators.subscription_tier` (`202605240900_plans_and_limits_phase0_subscription_tier_check.sql`). A global `pricing_plan_catalog` table holds the editable per-tier monthly fee, per-seat ramp, and onboarding range (`202605241100_plans_and_limits_phase3_pricing_plan_catalog.sql`). Per-business, per-org-unit, and per-location custom pricing rides on `pricing_contract_overrides` with non-overlapping effective-date windows enforced by trigger (`202605251000_plans_and_limits_scoped_contract_overrides.sql`, `202605251020_plans_and_limits_scoped_contract_windows.sql`). A `feature_entitlements` matrix (`202605241700_plans_and_limits_phase5a_feature_entitlements.sql`) maps tier→feature pairs as foundation for plan-level gating (distinct from §12's role-level RBAC); the gates themselves remain DEFERRED until the gateable surfaces (LMS, scoreboard, SOPs, workflows) exist. A `trial_mode` flag plus `trial_expires_at` on `operators` (`202605241600`) drives the Pilot free-trial conversion flow. The admin Plans & Limits screen lives at `lib/admin/screens/pricing_tier_admin_screen.dart`; the operator-web "Your plan" surface is display-only. Two observability tables back the same release: `usage_cap_events` is an append-only ledger of proxy cap-refusal telemetry with 30-day retention via `pg_cron` (`202605240000_ai_metrics_usage_cap_events.sql`), and `proxy_request_stats` is the operator-scoped fact table for AI request stats (`202605241500`). Plans & Limits V1 is shipped on master through Phase 5 plus scoped custom contracts and final QA polish; only Phase 5d (real feature gates) is deferred, and the migration cohort is queued for Production1 under the live-mutation gate.

## 17. Advisor And AI

### Plain English

The advisor is not just "ask a chatbot." It is supposed to answer from evidence, product docs, operational metrics, SQL data, graph relationships, prior context, and explain why. The advisor recommends, explains, and cites the context that produced the answer, and it does not silently perform risky actions. Forge Flow's sixth Hard Promise binds this: the advisor speaks in recommendations, not commands, and never acts on the operator's behalf at launch.

### Providers, Retrieval, And Synthesis

The architecture treats every external AI dependency through a **provider abstraction** so that vendor swaps do not ripple through every caller. The launch providers are Anthropic Claude for synthesis and classification, and Voyage for embeddings and reranking; the same `LLMProvider`, `EmbeddingProvider`, `RerankProvider`, `DataSourceProvider`, and `IntegrationProvider` interfaces will be reused by Phase 12, which means the AI infrastructure is general-purpose rather than advisor-specific.

When a user asks an operational question, a **classifier** decides the route: should this answer come from documents, from SQL facts, from graph traversal, or from a mix? Sending a simple question down a cheap path while reserving stronger tools for hard questions keeps both cost and latency under control. Once the path is chosen, retrieval-augmented generation (**RAG**) collects evidence: dense **vector search** over **pgvector** embeddings finds documents close to the question even when wording differs, sparse full-text search adds keyword precision, and AGE-based graph queries pull related entities and edges. A **reranker** model, Voyage's `rerank-2.5`, re-sorts the retrieved candidates so the most useful evidence comes first, which dramatically reduces noise in the final prompt.

**Synthesis** is the final answer generation, produced by Anthropic Claude Sonnet, that combines the reranked evidence into a readable response. **Tool use** lets the model invoke structured calls, running a SQL query, asking the retrieval system for more, or traversing the graph, instead of guessing at numbers. Every answer carries **provenance**: the rows, documents, and graph edges that supported the answer are recorded so a user can inspect why a recommendation was made. **Prompt caching** reuses stable system context across calls to lower cost and latency, and **model routing** sends easy tasks to Claude Haiku and harder tasks to Claude Sonnet, so the system pays for capability only where it is needed.

The cost discipline comes from `usage_caps`' two-slot key, five cost levers, and the meter-by-class rule defined in Forge Flow's ninth Hard Promise, which targets a 75 to 95% gross margin. All provider keys live server-side; there is no BYO-key support at launch, Hard Promise #7.

### How It Works

```text
user asks a question
  -> classifier decides the route
  -> system retrieves docs, SQL facts, graph facts, or mixed evidence
  -> Voyage reranks evidence
  -> Claude synthesizes answer
  -> app shows recommendation and supporting context
```

Provider choices documented for launch are Anthropic Claude Haiku for classification and cheaper tasks, Anthropic Claude Sonnet for answer synthesis, Voyage `voyage-4-large` for embeddings, Voyage `rerank-2.5` for reranking, Postgres `pgvector` for dense retrieval, Postgres full-text search for sparse retrieval, and AGE for graph traversal. The safety rule is that the advisor remains recommendation-only until workflow approval gates exist.

### Where It Lives

Provider interfaces live in `lib/domain/services/llm_provider.dart`, `lib/domain/services/embedding_provider.dart`, and `lib/domain/services/rerank_provider.dart`. The primary LLM implementation is `lib/services/claude_llm_provider.dart` (Anthropic Claude); `lib/services/gemini_llm_provider.dart` is a Google Gemini fallback wired through the same `LLMProvider` interface for the Block 2 fallback path. Embedding and rerank implementations live in `lib/services/voyage_embedding_provider.dart` and `lib/services/voyage_rerank_provider.dart`. Advisor decision-making is recorded in `docs/phases/phase_11a/phase_11a_decision_register.md`, and the corpus lives under `docs/Knowledge_graph_docs/`. The client-side Advisor Answer service (`lib/services/advisor/advisor_answer_gateway.dart`, slice D1, 2026-05-25) provides an abstract gateway with HTTP-live, in-memory demo, and provider-bridge implementations so the upcoming chat surface can consume the already-live `POST /v1/advisor/answer` proxy route while keeping HP #6 (recommendation-only) and HP #7 (server-side keys) intact; the D2 chat-screen preview spec is `docs/phases/advisor_knowledge_activation/advisor_knowledge_activation_plan.md`. The 30-day retention of conversation telemetry runs via `advisor_conversation_log_purge_expired()` on `pg_cron` (`202605241000`).

## 18. Graph Layer

### Plain English

Tables are good for rows. Graphs are good for relationships. The graph layer helps Forge Flow answer questions where the connections matter: what caused this, what is related to this issue, which document or workflow or metric connects to this symptom. Forge Flow's fifth Hard Promise commits to AGE infrastructure being live before Phase 11b, with retrieval growing into Modular Adaptive Agentic RAG over time.

### Nodes, Edges, And Traversal

A **graph** is a network of connected things, made up of **nodes** that represent entities (a location, a shift, a vendor, a metric, a document, a workflow concept) and **edges** that represent typed relationships ("causes," "references," "belongs to," "depends on"). Inside Postgres, the **AGE** extension provides property-graph capabilities, and **Cypher** is the query language that expresses traversals directly instead of forcing relational joins to mimic them.

The graph is not a competing source of truth: it is a **projection** built from canonical facts. When source data changes, the graph view is rebuilt from canonical truth, which means the graph always reflects the same operational reality the rest of the system uses. **Tripwire metrics** monitor node count, edge count, and degree distribution so growth that would make traversal unhealthy is visible early and can be addressed before it impacts advisor latency.

### How It Works

```text
canonical facts/docs are processed
  -> graph nodes represent entities/concepts
  -> graph edges represent relationships
  -> advisor or health tools query relationships
  -> system can explain connected causes/evidence
```

### Where It Lives

The graph schema is `db/migrations/202604280008_phase_9_0sigma_i_graph_canonical.sql`. Future consumers include Phase 11b advisor traversal and Phase 11A health.

## 19. Live Integrations

### Plain English

Forge Flow should eventually use live vendor data from POS, labor, reservation, accounting, and banking systems, but the UI should not be rewritten for every vendor. Vendor data enters through adapters, becomes canonical Forge Flow facts, and then flows through the same screens, the same advisor, and the same audit and tenant safety as anything else. Hard Promise #1 makes this explicit: Phase 8 is a pure transport swap; the vendor connectors write the same SQLite tables the demo writer does.

### Connectors, Adapters, And Watermarks

A **connector** owns the conversation with one vendor: API calls, authentication, sync orchestration, webhook handling, and rate-limit behavior. An **adapter** then translates the vendor-specific payload into a **canonical DTO**: the Forge Flow shape that the rest of the product is built against, so that vendor-specific differences stay at the boundary and never leak into screens or services.

Vendor **secrets** stay server-side. API keys, OAuth tokens, and refresh credentials live in Secret Manager and are reached only by the proxy and connector code; they never ship inside the Flutter bundle. Where the vendor supports it, **OAuth** is the delegated authorization flow so operators can authorize an integration without handing Forge Flow their vendor password. **Webhooks** push near-real-time updates from the vendor when something changes, and polling with **sync watermarks** handles the cases where a vendor only supports pull-based reads, the watermark records the last processed point so the next sync can resume from there rather than reprocessing the whole dataset. Every vendor payload is also stored as a **raw import record** before adaptation, so if the mapping logic changes later the original evidence can be inspected or replayed.

The rules for any new integration are: use official APIs, keep vendor secrets out of Flutter, convert timestamps using the restaurant's IANA timezone, and never build a separate UI truth path for each vendor. Vendor **applicability** rules define which vendors are allowed at which scope, resolved by precedence (location-specific override beats operator-level override beats global default); the `202605240900_b10_1_vendor_applicability_location_scope.sql` migration added the location scope.

### How It Works

```text
vendor API provides payload
  -> trusted connector fetches/receives data
  -> adapter converts payload into canonical facts
  -> repository stores facts
  -> SQLite/Postgres/state update
  -> UI and advisor use the same internal model
```

### Where It Lives

Vendor integration code lives under `lib/integrations/` (labor, POS, reservation). The POS and labor plan is `docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`. The reservation plan is `docs/archive/phases/phase_8R/phase_8R_official_reservation_connector_plan.md`. The external integrations plan is `docs/archive/phases/phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md`. The integration spine contract is `docs/contracts/integration_spine_architecture_contract.md`.

## 20. Shared State Roadmap

### Plain English

Shared state means multiple devices can see and update the same server-backed data. SQLite can still make the app fast locally, but Postgres becomes the source for shared truth. The proxy controls writes. Events tell other devices to refresh.

### Truth, Cache, And Invalidation

The model is straightforward: Postgres holds the **source of truth**, and SQLite holds a **cache** that makes reads fast and tolerant of network hiccups. When something changes on the server, an **invalidation** signal tells connected devices that their local cache for the affected entity is stale; the device fetches the new version rather than full-reloading every screen. **Startup sync** runs when a device first opens or returns to the app, hydrating the local cache from the server so a returning device does not display old shared state.

The path between server-side change and device-side refresh runs through an **event bridge**: a transactional outbox row, a worker, and a delivery channel (Pub/Sub fan-out or WebSocket push). When two clients edit the same shared entity, Forge Flow's V1 conflict policy is **last-write-wins**: the latest accepted write replaces the prior value. It is simple and predictable, with richer merge semantics deferred until they are clearly worth the complexity. Every shared mutation is audited so that "who changed this" is always answerable.

### How It Works

```text
manager changes shared setting
  -> app calls proxy
  -> proxy verifies JWT and permission
  -> Postgres write runs with RLS
  -> event_outbox records change
  -> worker/bridge notifies clients
  -> other devices refresh SQLite cache
```

### Where It Lives

The shared state plan is `docs/archive/phases/phase_10a/phase_10a_shared_state_v1_plan.md`. The event contract is `docs/contracts/event_outbox_contract.md`.

## 21. Operations Console

### Plain English

The operations console is the internal admin tool that Forge & Flow staff use to manage the platform itself, not the restaurant operator app. It is where the team manages operators, locations, pricing, feature flags, the advisor corpus, integrations, support actions, audit reviews, and health monitoring.

### Internal Admin Surface

The internal admin app is a Flutter Web surface (built from the same Flutter skills the operator app uses) that calls protected **admin API** routes on the proxy. Every administrative action, provisioning an operator, adjusting a feature flag, running a support fix, reviewing audit, reading a health envelope, goes through the proxy, which means admin power stays behind server-side identity, MFA, permission, and audit checks rather than relying on direct database access.

**Feature flags** let the team enable or disable capabilities at runtime, which supports staged rollout and quick rollback without shipping a new app build. **Observability** surfaces, health checks, logs, metrics, and the bounded dashboard delivered in Phase 11A.6, let staff diagnose problems before users report them. **Support actions** are the named, audited operations that resolve customer issues (resetting a stuck state, advancing demo time, revoking a session) so support becomes repeatable rather than ad-hoc.

The hard line is that the browser never receives direct database access. The ops console calls API routes, and the proxy enforces every check; a compromised browser session cannot become raw Postgres access.

### How It Works

```text
internal admin signs in
  -> admin console calls /v1/admin/*
  -> proxy verifies admin identity and MFA
  -> proxy checks admin permission
  -> proxy performs scoped server action
  -> audit log records the action
```

### Where It Lives

The admin console code lives under `lib/admin/`. The ops console plan is `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`. Admin routes are in `tool/advisor_proxy/advisor_proxy.dart`.

## 22. Workflow Platform

### Plain English

The workflow platform is the future automation layer. It will let Forge Flow run scheduled or event-driven work, but with strict identity, permission, audit, cost, and approval controls. The safety idea is that automation should be powerful, but never invisible.

### Triggers, Tools, And Approval Gates

A **workflow** is a defined sequence of steps that runs in response to a **trigger**: a schedule, an event, a user action, or an external signal. The workflow authenticates as a service principal (§13), which is what keeps its actions distinct from human actions in the audit log. The **tool registry** is the list of allowed actions a workflow may call; nothing else is reachable, which controls automation scope as more tools are added.

The execution model is **Plan-Then-Execute**: the workflow proposes a plan first, and only after that plan exists does it execute. Risky steps wait at an **approval gate** for a human to review and approve before any state changes. Outputs (reports, exports, generated artifacts) are preserved so a run is reviewable after the fact. Long or batch work runs as a **Cloud Run job** outside the interactive proxy request path so a slow workflow does not tie up a user request. **Cost caps** stop runaway provider spend before it accumulates, and **batch APIs** route non-urgent AI work to cheaper asynchronous processing where latency does not matter.

### How It Works

```text
trigger occurs
  -> workflow service principal authenticates
  -> workflow creates plan
  -> risky steps wait for approval
  -> approved tools execute
  -> events/audit records are written
  -> artifacts are stored if needed
```

### Where It Lives

The workflow plan is `docs/archive/phases/phase_12_workflow_platform/phase_12_workflow_platform_plan.md`. The service-principal foundation is `db/migrations/202604280004_phase_9_0sigma_d_service_principals.sql`.

## 23. Deployment, Secrets, And Environments

### Plain English

An environment is a place the system runs. Local is for development. Staging is for testing real cloud wiring before production. Production1 is protected and should only change through explicit runbooks/gates. Secrets are sensitive values like API keys and database URLs. They should not be committed to Git or baked into the Flutter app.

### Environments, Secrets, And Releases

**Local** runs the app and supporting services on a developer machine so engineers can build and debug without touching shared cloud systems. **Staging** proves the real cloud wiring: DNS, certificates, Cloud Run, the proxy, the secret store, and smoke tests. **Production1** is the customer-facing environment, where changes flow only through documented runbooks and explicit gates, destructive operations, force pushes to main, RLS-touching migrations, schema-touching migrations, proxy-touching slices, and ceiling raises like `kAdvisorProxyMaxLines` all require explicit operator approval.

**Secrets** are configuration values that would be dangerous if exposed: database passwords, Firebase admin keys, vendor API tokens. They live in Google **Secret Manager**, and Cloud Run reads them as secret references at startup rather than baking them into the container or the source tree. **Environment variables** carry non-secret runtime configuration so the same container image can be reused across environments with different settings.

The proxy is built from a **Dockerfile** that describes the exact runtime environment in code, which makes deploys reproducible. Continuous integration runs on **GitHub Actions**, where checks like static analysis, RLS lint, unit tests, contract tests, and Apple platform builds run on every push and pull request. High-risk live operations, production migration applies, secret rotations, schema changes, follow **runbooks** (now consolidated into a single `runbooks/` home as of the 2026-05-16 Wave 4 docs consolidation) that document the steps, the verification queries, and the backout plan. A **Google-managed certificate** secures public HTTPS without manual renewal, attached to the load balancer and refreshed automatically as long as DNS stays correct.

### How It Works

A staging deploy looks like:

```text
local private secrets file
  -> deploy script validates required values
  -> secrets sync to Google Secret Manager
  -> Cloud Run deploy uses secret references
  -> load balancer routes public traffic
  -> smoke test verifies /readyz
```

A production migration apply looks like:

```text
confirm gates
  -> backup
  -> apply migrations in documented order
  -> run verification queries
  -> monitor
  -> use backout notes if needed
```

### Where It Lives

The deploy script is `scripts/deploy_staging_proxy.ps1`. The proxy build is `Dockerfile`. The local Postgres scaffold is `docker-compose.dev.yml`. The production apply runbook is `runbooks/phase_9_production1_migration_apply_runbook.md`.

## 24. Testing And Gates

### Plain English

Tests are safety rails. In this repo, tests protect more than UI, they protect auth, MFA, tenant isolation, database migration shape, proxy behavior, platform builds, and production readiness.

### The Verification Layers

**Static analysis** runs `flutter analyze --fatal-infos` to catch Dart issues before the app ever runs, which catches drift early. **Unit tests** check small, focused behaviors, for example, the labor variance formula, and **widget tests** check Flutter UI behavior without booting a full device. **Contract tests** verify that the running code still obeys documented architectural shapes, and **migration tests** verify that schema changes create the indexes, constraints, and policies they promise. **RLS lint** at `tool/rls_policy_lint.dart` blocks unsafe RLS policy patterns automatically.

**Smoke tests** verify that a deployed service actually responds: a `GET /readyz` that returns `{"status":"ok"}` proves the deployment wiring is intact. **GitHub Actions** runs all of this on every push and pull request, so checks behave the same way regardless of branch. A separate Apple verification workflow runs on a macOS runner and produces iOS simulator builds for both the ForgeFlow and Barrio flavors, which catches iOS-specific compilation problems before real-device QA.

For runtime acceptance, the team uses the advisory pattern described in `docs/contracts/slice_runtime_acceptance_contract.md`; it is reviewer judgment, not CI-enforced. Browser-based slices follow `runbooks/browser_use_codex_acceptance_workflow.md`.

### How It Works

The CI path runs:

```text
push or pull request
  -> GitHub Actions starts
  -> flutter pub get
  -> flutter analyze --fatal-infos
  -> dart run tool/rls_policy_lint.dart
  -> flutter test
```

Apple platform verification runs:

```text
macos-15 runner
  -> focused auth/MFA tests
  -> iOS simulator build for ForgeFlow
  -> iOS simulator build for Barrio
```

### Where It Lives

Main CI is `.github/workflows/ci.yml`. Apple verify is `.github/workflows/apple-platform-verify.yml`. Tests live under `test/`. RLS lint is `tool/rls_policy_lint.dart`.

## 25. Current Status And Known Gaps

### Plain English

The foundation is broad, and much of it is now merged or scaffolded. Some database structures exist before their final UI, worker, or workflow consumer exists, and that is normal for this repo's phase style. The doctrine is: build the foundation, verify the contracts, then attach the consumer features. This section is a snapshot of where the system stands and what the next gates are.

### Snapshot

The Phase 9.0Sigma.b through k foundation is **Live**, which means the auth, RLS, service-principal, audit, event, graph, and rollup groundwork is on master. Staging DNS and HTTPS are passing, so the public staging API at `https://staging-api.feflow.org/readyz` resolves and smokes successfully and Cloud Run reads its secrets from Secret Manager references rather than plain deploy config. Phase 9 is accepted: live auth closeout is accepted for next-phase handoff, Cloud Armor is in monitored preview, and physical iOS QA is deferred. The Phase 9 migrations through `202604280013` remain the last cohort applied to Production1; the May 2026 migration cohort (Per-Daypart V1, hierarchy-scoped roles, brand-tier org hierarchy, Plans & Limits V1, scoped custom contracts, AI Metrics observability, and the advisor conversation-log retention) is queued for Production1 under the live-mutation gate.

The post-Codex execution pipeline is mid-flight. As of the 2026-05-19 `NEXT_WAVE_PLAN.md` status snapshot: **Phase 0 (smoke) is complete. Phase 1 (Wave 2) is CLOSED.** Wave 1 closed 2026-05-13; Wave 2 ran 33 slices across 11 lanes (operator-web and admin lanes closed 2026-05-14, mobile lane closed 2026-05-15). **Phase 2.5 (Per-Daypart Targets V1) is the live phase**, transitioned to after Wave 2 mobile closeout. Per-Daypart Targets V1 records seven slices (Slice 0 through Slice 6) that push the TargetCycle layer from whole-day down to a daypart grain (lunch vs dinner expected covers, labor, verdicts) and consolidates 44 surface-coverage gaps from the mobile walkthrough. As of the 2026-05-19 snapshot, **Slices 0 through 5 have landed; Slice 6 and any later follow-ups are still in flight**. The happy-state Phase 2 tag will only drop once Phase 2.5 exits and the post-Wave-2 walkthrough re-runs cleanly. The team currently runs dual-Claude orchestration (main orchestrator + a second Claude lane) because Codex is out of quota; the workflow itself is executor-agnostic and the same pattern holds regardless of which executor is active.

Recent landings since the 2026-05-19 doc refresh extend the May 2026 cohort: a new **brand** org-unit tier (`202605200900_brand_org_unit_type.sql`) with cascading account fields via `org_unit_account_overrides`; the **Plans & Limits V1** ship of Phases 0 through 5 plus scoped custom contracts (six canonical subscription tiers, editable `pricing_plan_catalog`, `pricing_contract_overrides` with effective-date windows, `feature_entitlements` foundation, `trial_mode` flag); **AI Metrics + Support Logs** observability (`usage_cap_events`, `proxy_request_stats`, `advisor_conversation_log_purge_expired()` daily `pg_cron`); the **Advisor D1** client gateway (`lib/services/advisor/advisor_answer_gateway.dart`, 2026-05-25) and the **D2** operator-web chat preview spec (2026-05-26); and the **Data Accuracy** tabbed redesign (2026-05-25). Earlier in the May cohort: the hierarchy-scoped roles redesign (`db/migrations/202605142100_phase_R_1L_roles_schema_rewrite.sql`) and its follow-ups, hierarchy-scoped benchmark overrides (`db/migrations/202605131550_benchmark_overrides_hierarchy.sql`), self-service profile permission key (`db/migrations/202605140000_w_3_self_profile_perm_key.sql`), email-event provider id (`db/migrations/202605131700_c_1a_email_event_provider_id.sql`), and the full Per-Daypart V1 migration chain (`202605150400_per_daypart_v1_drop_close_authority.sql`, `202605160000_per_period_target_persistence.sql`, `202605161500_deprecate_locations_rollover_hour.sql`, `202605161501_s0_verdict_persistence.sql`, `202605170000_r5_covers_source_keyed_backfill.sql`, `202605170100_r7a_covers_source_per_period_hierarchy.sql`, `202605170200_r7d_drop_legacy_covers_columns.sql`). The admin actor-kind label unification (2026-05-14) brought admin and operator-web audit surfaces onto a single canonical catalog at `lib/services/auth/actor_kind_label_catalog.dart`. The Wave 4 docs consolidation (2026-05-16) unified runbooks into one home.

The B17 admin role catalog CRUD is **Live** and smoke-passed on staging, unblocking the operator-facing Settings → Team consumption. The B33 `usage_logs` two-slot mirror work is **Live**, supporting cap-vs-actual reconciliation. The B34 audit attribution contract clarification is **Live**. The RLS isolation sweep is **Live**, with passive cross-tenant tests in place for new tenant-scoped tables. The service-principal issuer route is **Live in schema**: the issuance route, client, and tests have landed, and the Production1 permission-key apply completed on 2026-05-03. The event-outbox is **Scaffolded** in Phase 10a, while the Pub/Sub adapter, dead-letter handling, retention sweep, tripwires, and operator-facing UX surfaces remain queued. Health producers B44 (graph), B45 (rollup), and B47 (vector) now fill the B42 health envelope in code, which gives 11A.6 a bounded observability dashboard.

The runtime user-facing demo↔live switch landed in `lib/screens/settings/settings_demo_live_switch.dart` in May 2026, which means an operator can now flip demo→live state at runtime without a rebuild, while the demo-mode reader path remains a single, non-branching code path per Hard Promise #2.

### Where It Lives

The current tracker is `PROJECT_TRACKER.md`. The forward plan is `docs/_indices/NEXT_WAVE_PLAN.md`. The active feature plan is `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`. Adjacent active plans: `docs/phases/advisor_knowledge_activation/advisor_knowledge_activation_plan.md` (chat surface), `docs/phases/plans_and_limits_v1/plans_and_limits_v1_plan.md` (subscription tiers + admin), `docs/phases/plans_and_limits_v1/scoped_custom_contracts_plan.md` (per-scope contract overrides), and `docs/phases/phase_production_cutover/phase_production_cutover_plan.md` (six-gate cutover sequencing). The backlog is `docs/phases/phase_9/phase_9_execution_backlog.md`. The production apply runbook is `runbooks/phase_9_production1_migration_apply_runbook.md`.

## 26. Quick Glossary

The glossary collects the most-referenced terms in one place for quick lookup. Each entry is a short definition plus a one-line example.

**A record**: A DNS entry that points a hostname to an IPv4 address; `staging-api` points to `34.54.204.29`. It sends a friendly name directly to a known IP.

**AGE**: The Postgres extension that adds property-graph capability to relational tables; it lets the system traverse relationships between prep, line, and demand entities. It keeps graph queries inside Postgres rather than a separate store.

**API**: A server route or interface that software calls; `GET /readyz` and `POST /v1/auth/session/login` are examples. It gives the app and backend a clear contract for talking to each other.

**Business date**: The restaurant-local operating date that anchors reporting; a 1 AM close still belongs to Friday service. It keeps reporting aligned with operational reality rather than calendar midnight.

**CNAME**: A DNS entry that points one hostname to another hostname. It is the right shape when a provider owns the target name and may change its underlying IPs.

**Cloud Armor**: Google's edge security layer that logs or blocks suspicious requests before they reach the backend. It filters or observes traffic before backend code ever runs.

**Cloud Run**: The Google service that runs containers; the staging proxy runs there as `forge-flow-staging-proxy`. It hosts the proxy without hand-managing servers.

**DNS**: The internet's naming system that translates `staging-api.feflow.org` into a network destination. It turns human-friendly names into routable addresses.

**Firebase Identity Platform**: Google's hosted login, auth, and MFA service. Forge Flow uses it so it does not have to build credential and MFA systems from scratch.

**Hostname**: A friendly service name like `staging-api.feflow.org`. It gives clients a stable name to call independent of underlying infrastructure.

**JWT**: A signed identity token; the Firebase ID token the app sends to the proxy is one. It lets services verify identity and claims without trusting plain text.

**Load balancer**: The public traffic router that terminates HTTPS and forwards requests; it routes `/readyz` traffic to the proxy backend. It provides a stable, secure front door.

**MFA**: More than one proof of identity (password plus an authenticator code). It reduces risk from stolen passwords.

**NEG**: A serverless network endpoint group that connects a Google load balancer to Cloud Run.

**Pgvector**: The Postgres extension that stores and similarity-searches embeddings. Supports AI retrieval inside the same database as the rest of the data.

**Proxy**: The server-side API gatekeeper that holds secrets, verifies identity, and performs privileged work.

**RAG**: Retrieval-Augmented Generation: retrieve evidence first, then have the model generate an answer. Grounds AI answers in real context rather than guesswork.

**RLS**: Postgres Row Level Security, which hides rows that do not match the current tenant context. The database-layer backstop against cross-tenant access.

**Secret Manager**: Google's storage for sensitive configuration values; holds API keys, database URLs, and credentials outside Git.

**Service principal**: A non-human automation identity (for example `sp:rollup-worker`). Lets automation act with its own audit trail rather than borrowing a human's account.

**SQLite**: The local embedded database the app uses for caches, replay data, and demo state.

**TOTP**: A rotating time-based one-time password produced by an authenticator app. Provides MFA without SMS.

**WebSocket**: A long-lived real-time connection between the server and a client. Lets the server push changes to connected clients.

## 27. Source Documents And Code Read

This guide was synthesized from `README.md`, `PROJECT_TRACKER.md`, `CLAUDE.md`, `pubspec.yaml`, `Dockerfile`, and `docker-compose.dev.yml` at the repo root; `docs/README.md`; the contracts directory including `docs/contracts/core_app_architecture.md` (the canonical Phase 7.55 architecture), `docs/contracts/phase_7_55_plain_english_architecture.md`, `docs/contracts/event_outbox_contract.md`, `docs/contracts/demo_mode_contract.md`, `docs/contracts/audit_log_architecture_contract.md`, `docs/contracts/hardening_rls_and_repository_pattern_contract.md`, and `docs/contracts/integration_spine_architecture_contract.md`; the active feature plan `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`; the forward plan `docs/_indices/NEXT_WAVE_PLAN.md`; the historical phase plans for Phases 8, 8R, 8.5, 9, 10a, 11a, 11A, and 12; the consolidated runbooks under `runbooks/`; and the code at `lib/main_forgeflow.dart`, `lib/main_barrio.dart`, `lib/forge_flow_bootstrap.dart`, `lib/forge_flow_app.dart`, `lib/state/auth_session_notifier.dart`, `lib/services/auth/firebase_auth_runtime_bindings.dart`, `lib/services/auth/firebase_auth_login_service.dart`, `lib/services/auth/actor_kind_label_catalog.dart`, `lib/services/mfa/proxy_mfa_operations_gateway.dart`, `lib/screens/settings/settings_demo_live_switch.dart`, `lib/admin/`, `lib/operator_web/`, `lib/integrations/`, `lib/internal/`, `lib/infrastructure/persistence/sqlite/`, `lib/infrastructure/persistence/postgres/`, `tool/advisor_proxy/`, `db/migrations/`, `.github/workflows/ci.yml`, and `.github/workflows/apple-platform-verify.yml`.
