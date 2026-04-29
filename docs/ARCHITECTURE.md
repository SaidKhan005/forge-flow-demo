# Forge Flow Architecture Guide

Last updated: 2026-04-29

Repository/tracker state reviewed through: 2026-04-28

This document explains Forge Flow in two languages at the same time:

- Plain English: what the piece means and why it exists.
- Technical, but translated: each technical term is explained as what it is, what it does, and why it helps.

The goal is not just to list technology. The goal is to make the system understandable enough that you can reason about it, ask better questions, and know where each piece belongs.

## How To Read This

Most areas follow this pattern:

1. Plain English: the mental model.
2. Named architecture areas: a direct plain-English explanation, then a restaurant analogy, then the technical purpose.
3. Tables inside each section: each term explained as what it is, what it does, and why it matters.
4. How it works: the flow through the system.
5. Where it lives: repo paths to inspect.

Status words used in this guide:

- Live: implemented and actively used or verified.
- Scaffolded: foundation exists, but the final consumer or workflow is not complete.
- Planned: documented in phase plans, not fully implemented.

## 1. Whole System In One Picture

### Plain English

Forge Flow is a restaurant operations system.

It helps an operator understand:

- what the plan was
- what is happening now
- whether labor is on track
- whether demand changed
- what happened historically
- what the system recommends next

The app on the device is only one part of the system. The bigger system includes a server-side proxy, a shared database, auth, audit logs, DNS, cloud infrastructure, AI retrieval, and future workflow automation.

Think of the whole system like a restaurant office:

- The Flutter app is the front desk screen.
- SQLite is the local notebook on that desk.
- The proxy is the trusted manager who can enter locked rooms.
- Postgres is the back-office records cabinet.
- Firebase is the identity desk that checks who someone is.
- DNS and the load balancer are the building address and lobby.
- The advisor is the analyst who reads the manuals, numbers, and history before recommending something.

### Core System Map

Plain English purpose: The core system map shows the biggest pieces of Forge Flow and how they fit together.

Restaurant analogy: It is the restaurant floor plan. The dining room, POS, manager office, records cabinet, front door, and expo station are separate areas, but service only works when they connect cleanly.

Technical purpose: the core system map defines top-level runtime boundaries and trust zones. It separates client execution, local persistence, server-side API authority, shared database authority, identity verification, public edge routing, and AI/advisor processing so each layer has a clear responsibility, deployment model, and security posture.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Flutter app | The user-facing app code | Shows screens, handles user interaction, reads local state, calls services | One shared app framework can serve the operator experience across platforms without rebuilding every screen separately | Supports future mobile, web, and branded surfaces without creating separate UI stacks. |
| Dart | The programming language | Runs both the Flutter app and the Cloud Run proxy | Sharing one language reduces context switching and lets some patterns/DTOs stay consistent across app and server code | Keeps app and proxy patterns closer together as shared DTOs and gateways grow. |
| SQLite | A small local database inside the app/device | Stores local app state, demo/replay data, cached read models, and offline-friendly data | The app stays fast and useful even when network/server state is not immediately available | Leaves room for offline-first behavior and fast caches without making the client authoritative. |
| Postgres | A server-side relational database | Stores shared truth for auth, audit, operators, usage, advisor, graph, rollups, and future shared state | Shared and sensitive records need one authoritative place with transactions, constraints, indexes, and security rules | Gives multi-device and multi-operator features one durable authority to build on. |
| Firebase Identity Platform | Hosted identity service | Handles login credentials, password auth, and MFA | Credential security is hard; using Firebase avoids building password/MFA infrastructure from scratch | Keeps future auth/MFA improvements on a dedicated identity platform instead of custom credential code. |
| Proxy | Server-side API layer | Verifies identity, checks permissions, protects secrets, and talks to privileged services | The app can request protected work without holding database passwords, vendor secrets, or admin power | Creates one server boundary for future vendor secrets, admin actions, and workflow APIs. |
| Cloud Run | Google managed container runtime | Runs the Dart proxy without managing servers manually | The proxy can scale and deploy as a container while Google handles much of the server operations burden | Lets backend services scale, split, and redeploy without managing servers directly. |
| DNS | Internet naming system | Turns names like `staging-api.feflow.org` into a network destination | Apps and browsers can use stable friendly names even if infrastructure changes behind them | Lets public endpoints move infrastructure without forcing app/client changes. |
| Load balancer | Google edge traffic router | Receives public web traffic and forwards it to Cloud Run | Public traffic gets a stable entry point, HTTPS termination, and routing before it reaches the proxy | Leaves room for certificates, edge policy, and multiple backend services behind one front door. |
| Cloud Armor | Google edge protection | Logs or blocks suspicious traffic before it reaches the proxy | Bad or abusive traffic can be handled at the edge before it consumes backend resources | Can move from preview to enforcement once clean traffic patterns are understood. |
| Advisor | AI/retrieval system | Answers operational questions using documents, metrics, SQL, graph data, and model providers | Recommendations become grounded in evidence instead of being generic chatbot output | Creates a path for smarter recommendations without coupling AI directly to screens. |

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

For public staging traffic:

```text
https://staging-api.feflow.org
  -> DNS resolves the hostname
  -> Google load balancer receives traffic
  -> Google managed certificate handles HTTPS
  -> Cloud Armor evaluates edge rules
  -> Cloud Run runs the proxy
  -> proxy answers the route
```

### Where It Lives

- App: `lib/`
- Proxy: `tool/advisor_proxy/`
- SQLite: `lib/infrastructure/persistence/sqlite/`
- Postgres: `lib/infrastructure/persistence/postgres/`, `db/migrations/`
- Docs and plans: `docs/`, `runbooks/`, `PROJECT_TRACKER.md`, `CLAUDE.md`

## 2. Product Loop

### Plain English

The product is built around a loop:

```text
what happened before
  -> what good should look like
  -> what we expect this week
  -> what we planned
  -> what is happening now
  -> what actually happened
  -> what we learn
```

This matters because live restaurant data can be messy. Sales can change. Labor can change. Reservations can move. A manager can adjust a schedule. If the system mixes live data, planned data, and historical truth, it becomes hard to trust.

Forge Flow tries to keep those meanings separate.

### Product Truth Model

Plain English purpose: The product truth model explains the different kinds of restaurant truth the product must keep separate.

Restaurant analogy: A forecast, prep list, posted schedule, live shift notes, and closed nightly report all matter, but a manager would not treat them as the same document.

Technical purpose: the product truth model defines domain invariants. It keeps planned, forecasted, live, benchmarked, and closed data as separate concepts so formulas, UI state, persistence, integrations, analytics, and advisor logic do not accidentally compare or rewrite the wrong kind of truth.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Operational facts | Raw or normalized restaurant facts | Represent sales, labor, reservations, shifts, wages, plans, and outcomes | The system needs real restaurant evidence before it can make useful comparisons or recommendations | Provides stable evidence for future integrations, audits, rollups, and advisor reasoning. |
| Canonical facts | Forge Flow's standard internal version of those facts | Lets all vendors and app surfaces speak one common data language | Vendor-specific mess stays at the boundary, so the app and advisor do not need custom logic for every provider | Lets new vendors be added without changing product logic everywhere. |
| Benchmark | A trusted historical comparison period | Says what good performance should look like | Operators need a stable standard to compare against, not a moving target invented by the live shift | Keeps future comparisons stable as target-setting gets more advanced. |
| TargetCycle | A locked benchmark window | Prevents targets from constantly changing after a plan is made | Keeps planning fair: the standard used to make a plan is still the standard used to judge it | Supports fair plan-versus-result comparison across future planning phases. |
| ActiveTargetProfile | The currently active target settings | Gives screens and formulas the current standard to compare against | UI and calculations stay aligned on one current target source | Lets target strategy evolve without rewriting every screen and formula. |
| DemandForecastContext | Expected demand inputs | Helps estimate labor and staffing needs | Staffing decisions depend on expected demand, not only historical averages | Leaves room for richer demand inputs from POS, labor, and reservations. |
| WeeklyPlanSnapshot | The locked plan for a week | Preserves what the operator intended before actuals arrive | Actual results can be compared to the plan that existed at the time, not a rewritten plan | Preserves plan history for future variance, audit, and learning features. |
| Shift | The live or whole-day shift view | Shows what is happening now or happened in a shift | Operators need a current operational picture while the day is still actionable | Gives live operations a stable surface as daypart and real-time data expand. |
| Variance | Difference between plan and actual | Explains whether the restaurant is above/below plan | Variance turns raw numbers into a clear "on track or off track" signal | Becomes the bridge for future coaching, alerts, and planning feedback. |
| History | Closed truth | Stores what actually happened after the period is complete | Learning and reporting need stable completed data that live edits cannot rewrite | Protects training and reporting data for future learning features. |
| Learn | Teaching/recommendation layer | Uses repeated closed evidence to explain patterns and recommend action | The system can improve guidance by learning from patterns that actually repeated | Provides the future path for coaching based on repeated closed evidence. |

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

In plain English:

1. Vendor systems provide facts.
2. Forge Flow converts them into its own consistent shape.
3. The system picks a trusted history window.
4. That becomes a target cycle.
5. The operator plans against that target and expected demand.
6. The live shift compares current reality to the plan.
7. Closed shifts become history.
8. History feeds future learning and recommendations.

### Where It Lives

- Product architecture contracts: `docs/contracts/`
- Main app state/services: `lib/state/`, `lib/services/`, `lib/domain/`
- SQLite operational storage: `lib/infrastructure/persistence/sqlite/`

## 3. Repository Map

### Plain English

The repository is split by responsibility. That keeps the system from becoming one pile of app code, database code, cloud code, and planning notes.

If you want to understand a change, first ask: is this UI, app state, local data, server API, database schema, cloud deployment, or documentation?

### Repository Layout

Plain English purpose: The repository layout explains where different kinds of work live in the repo.

Restaurant analogy: A restaurant keeps dry goods, knives, prep lists, invoices, and cleaning logs in different places. The repo does the same for UI, database blueprints, server tools, tests, and docs.

Technical purpose: the repository layout documents separation of concerns. Each folder represents an ownership boundary: presentation, domain logic, runtime services, state management, local persistence, server persistence, proxy/API code, schema migration, tests, architecture docs, and operational procedures.

| Path | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| `lib/` | Main Flutter/Dart app code | Contains UI, state, services, domain logic, persistence wrappers | Keeps the user-facing product code in one main tree | - |
| `lib/domain/` | Pure domain logic | Holds formulas and interfaces that should not directly do I/O | Business rules stay testable and are not tangled with databases or APIs | Keeps formulas portable into future services, tests, and advisor tooling. |
| `lib/services/` | Runtime services | Coordinates auth, providers, gateways, app operations | Orchestration sits between raw UI and low-level infrastructure | Keeps orchestration replaceable as providers, gateways, and proxy features change. |
| `lib/state/` | App state objects | Holds screen/application state through notifiers/read models | UI can react to clean state changes instead of calculating everything itself | Lets UI surfaces grow without duplicating state logic. |
| `lib/infrastructure/persistence/sqlite/` | Local database layer | Defines SQLite schema, migrations, and local data access | Local storage behavior stays centralized and easier to migrate | Keeps local schema/cache changes isolated as offline behavior expands. |
| `lib/infrastructure/persistence/postgres/` | Server database access layer | Defines safe Postgres execution and tenant-scoped repository patterns | Server data access can enforce tenant and transaction rules consistently | Keeps tenant-safe data access reusable as server tables grow. |
| `tool/advisor_proxy/` | Dart proxy server | Runs the server-side API used by the app and staging edge | Privileged backend behavior is separated from Flutter client code | Keeps backend APIs independently deployable from app UI releases. |
| `db/migrations/` | Postgres schema history | Creates/updates tables, indexes, policies, functions, and extensions | Database changes become reviewable, repeatable, and auditable | Provides a durable history of schema evolution for staging and production applies. |
| `test/` | Automated tests | Verifies app behavior, proxy behavior, auth, migrations, RLS, contracts | Safety-critical behavior gets checked before changes ship | Gives future refactors a safety net. |
| `docs/contracts/` | Durable architecture rules | Holds rules future work must obey | Long-lived decisions have a stable home outside temporary phase notes | Prevents future phases from re-litigating stable architecture decisions. |
| `docs/phases/` | Phase plans | Holds active implementation plans and audits | Work in progress stays organized by roadmap slice | - |
| `runbooks/` | Operational procedures | Explains how to do live maintenance safely | Live operations can be repeated with less guesswork and less risk | Makes live operations repeatable as production risk grows. |
| `.github/workflows/` | GitHub Actions automation | Runs CI and platform verification | Important checks run consistently without relying on memory | Keeps platform checks scalable as release gates expand. |
| `scripts/` | Helper scripts | Handles deployment and operations tasks | Repeated commands become safer and less manual | - |

### How It Works

When a feature touches multiple layers, the path usually looks like:

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

- Repo index: `docs/README.md`
- Root status: `PROJECT_TRACKER.md`
- Repo rules: `CLAUDE.md`

## 4. App Runtime And UI

### Plain English

The app is the part users see. It gives restaurant operators screens for the current shift, variance, plans, benchmarks, settings, and notifications.

The app has two flavors:

- ForgeFlow: main product app.
- Barrio: branded/demo flavor.

Both flavors share the same architectural backbone.

### App Runtime Flow

Plain English purpose: The app runtime flow explains how the visible app starts and gets ready for the user.

Restaurant analogy: It is the opening checklist before service: unlock the right branded door, turn on the POS, check the manager log, confirm who is on shift, and then open the right station.

Technical purpose: the app runtime flow defines the Flutter composition path. Entrypoints select flavor/runtime mode, bootstrap builds dependencies, providers expose services, notifiers publish state changes, the app shell owns navigation, and auth gating prevents protected UI from rendering before identity state is known.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Flutter | UI framework | Lets the app run across mobile, web, desktop, and test environments | One UI system can support several platforms and branded builds | Supports future platforms without separate UI stacks. |
| Dart | App language | Runs Flutter code and shared logic | The app and proxy can use a common language and similar models | - |
| Flavor | Build variant | Lets one codebase produce different branded/runtime versions | ForgeFlow and Barrio can share core logic while presenting different app identities | Allows customer/branded builds without code forks. |
| Entrypoint | First file that starts the app | Chooses flavor and runtime bindings | Startup decisions stay explicit instead of hidden throughout the app | - |
| `main_forgeflow.dart` | ForgeFlow app entrypoint | Starts the ForgeFlow flavor | The main product has a clear launch path | - |
| `main_barrio.dart` | Barrio app entrypoint | Starts the Barrio flavor | The branded demo/customer flavor can be built separately without forking the app | - |
| Bootstrap | Startup wiring | Initializes services, local state, auth session, and providers | The app starts with the same dependency and state setup every time | Centralizes startup so auth, storage, and runtime changes do not scatter. |
| Provider | Dependency/state injection package | Makes services and notifiers available to widgets | Widgets can use shared services without manually passing them through every screen | Keeps dependency wiring manageable as services grow. |
| Notifier | State object that can tell UI to rebuild | Holds app state and emits changes | Screens update when state changes without each widget polling for data | Keeps screen updates predictable as state surfaces expand. |
| `MaterialApp` | Flutter app shell | Provides routing, theme, navigator, and app-level behavior | The app gets a standard place for navigation, theme, and global behavior | - |
| Auth gate | Screen/router that checks sign-in state | Shows login, MFA, loading, or the real app shell | Protected screens stay behind authentication and MFA state | Preserves one place to enforce login/MFA before new protected screens. |

### How It Works

Startup flow:

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

Important behavior:

- If auth runtime is configured, Firebase-backed services are created.
- If auth runtime is not configured, fail-closed/scaffold defaults are used for protected behavior.
- The app tries to hydrate local state before the user interacts with screens.

### Where It Lives

- Entrypoints: `lib/main_forgeflow.dart`, `lib/main_barrio.dart`
- Bootstrap: `lib/forge_flow_bootstrap.dart`
- App shell: `lib/forge_flow_app.dart`
- Barrio shell: `lib/barrio_app.dart`
- Auth state: `lib/state/auth_session_notifier.dart`

## 5. SQLite: Local App Database

### Plain English

SQLite is the app's local notebook.

It is fast. It lives with the app. It is useful for demo data, replay data, local state, cached screen data, and offline-friendly reads.

But SQLite is not the official shared record for sensitive or multi-user truth. If something must be correct across users, devices, operators, or audits, it belongs in Postgres or must eventually sync through the server path.

### Local Database Model

Plain English purpose: The local database model explains why the app keeps useful data on the device.

Restaurant analogy: SQLite is the clipboard at the host stand or expo station. It keeps today's quick notes close by, even though the official records still live in the back office.

Technical purpose: the local database model defines the embedded persistence layer. It covers local schema versioning, migrations, seed data, replay fixtures, screen-optimized read models, and cached copies of operational data while keeping shared/security-sensitive authority out of the client database.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| SQLite | Embedded local database | Stores data inside the app/device without a separate server | The app can load quickly and keep local/demo/cache data close to the UI | Supports richer cache/offline features without adding server round trips. |
| `sqflite` | Flutter SQLite package | Lets Flutter read and write SQLite on mobile | Mobile builds get a proven database bridge instead of custom native storage code | - |
| `sqflite_common_ffi` | Desktop/test SQLite support | Lets SQLite work in desktop/test environments | Developers and tests can exercise the same persistence ideas outside phones | - |
| Schema version | Number for database shape | Tells the app which migrations need to run | Existing installs can upgrade safely as tables and columns evolve | Allows installed apps to upgrade local data safely. |
| Migration | Controlled database change | Adds/changes tables and columns over time | Database changes happen predictably instead of breaking old local data | Prevents future local schema changes from breaking existing users. |
| Seed data | Initial/demo records | Gives the app a known starting restaurant and replay data | Demo and development flows start from a repeatable baseline | Keeps demos and development scenarios repeatable. |
| Mock replay | Simulated operational data | Lets the app behave as if live data exists | Product surfaces can be built and tested before every vendor integration is live | Lets product work continue before every live integration is ready. |
| Read model | Screen-friendly data shape | Makes UI reads fast and simple | The UI can display complex information without recalculating raw facts every time | Keeps complex screens fast as raw data grows. |
| Cache | Local copy of data | Avoids re-fetching or recalculating everything | The app feels faster and can tolerate network/server delays | Supports future sync/shared-state work without slowing the UI. |

### What SQLite Stores

SQLite currently stores local/app-facing data such as:

- restaurant locations
- connector configs
- import runs
- raw import records
- sync watermarks
- active target profiles
- target profile versions
- shift records
- week records
- baseline selected records
- open shift snapshots
- reservation book snapshots
- mock replay state
- wage role rows
- target cycles
- weekly plan snapshots
- benchmark selection summaries
- restaurant timing configs
- app notifications

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

- SQLite code: `lib/infrastructure/persistence/sqlite/`
- Desktop/dev database file: `forge_flow_v2.db`
- Current schema version in code: `24`

## 6. Postgres: Shared Server Truth

### Plain English

Postgres is the official shared back-office records cabinet.

SQLite is the local notebook. Postgres is the server-side record that must work across users, devices, operators, audits, admin actions, advisor systems, and future automation.

The app should not bypass Postgres for shared or sensitive data.

### Managed Postgres Platform

Plain English purpose: The managed Postgres platform explains what the official shared database is and where it runs.

Restaurant analogy: Postgres is the restaurant company's off-site records room. Azure is the property team that keeps that room available, backed up, and maintained.

Technical purpose: the managed Postgres platform defines the database runtime contract: database engine, cloud provider, region, and version. Those choices determine extension availability, latency profile, operational responsibilities, backup/maintenance expectations, and the baseline behavior migrations must target.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Postgres | Server-side relational database | Stores durable shared records and enforces relational rules | Shared truth needs transactions, constraints, indexes, and security in one authoritative place | Makes shared-state, audit, and multi-operator features possible on one consistent authority. |
| Azure Database for PostgreSQL Flexible Server | Managed Postgres hosted by Azure | Runs Postgres without managing the database server manually | Azure handles much of the operational burden such as hosting, backups, and managed platform behavior | Keeps database operations more managed as production data grows. |
| Canada Central | Azure region | Controls where the managed database lives geographically | Region choice affects latency, residency, and operational alignment | Keeps data-location, latency, and residency assumptions explicit as production usage grows. |
| PostgreSQL 16 | Database version | Defines available database features and behavior | A fixed version makes extension support, syntax, and behavior predictable | Stabilizes extension and migration planning until an intentional database upgrade is scheduled. |

### Postgres Code Locations

Plain English purpose: Postgres code locations explain the difference between code that uses Postgres and files that define Postgres.

Restaurant analogy: One binder tells managers how to use the back-office records. Another binder holds the renovation plans for changing the records room itself.

Technical purpose: Postgres code locations separate application-level persistence code from schema evolution. Repository/executor code controls how runtime queries are issued, while migrations define the database objects, constraints, indexes, policies, and functions that must exist consistently across environments.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| `lib/infrastructure/persistence/postgres/` | Postgres access code | Holds safe execution abstractions and repository patterns | Database access rules stay centralized instead of being reinvented across services | Lets new repositories follow existing safe access patterns. |
| `db/migrations/` | Database schema history | Creates tables, indexes, security policies, functions, and extensions | Schema evolution is reviewable and replayable across environments | Supports staged and production applies with clear order and review history. |

### Postgres Abstractions

Plain English purpose: Postgres abstractions are the safe wrappers around direct database access.

Restaurant analogy: They are the trained office manager at the records desk. Staff do not wander into the cabinet alone; they ask through someone who knows the rules.

Technical purpose: Postgres abstractions are the database access layer. They standardize query execution, transaction lifecycle, connection reuse, tenant context propagation, and repository ownership so low-level driver behavior does not leak into business services or UI-facing code.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| `PostgresExecutor` | Query runner abstraction | Lets repository code run SQL without caring about the concrete driver | Repositories can be tested and reused without coupling to one low-level connection object | Allows repositories and tests to swap execution contexts. |
| `PostgresTransaction` | Bundle of database work | Makes several operations succeed or fail together | Multi-step changes do not leave the database half-updated if one step fails | Keeps future multi-write operations atomic. |
| `PostgresPool` | Reusable connection manager | Shares database connections instead of opening a new one per query | Connection reuse improves performance and avoids exhausting database connections | Helps request volume grow without connection churn. |
| `TenantContext` | Current operator/location/user label | Tells database work which tenant and actor it belongs to | Every database operation can be tied to the right operator, location, and user | Centralizes tenant metadata for future RLS-protected tables. |
| `OperatorScopedRepository` | Base class for operator-owned data access | Forces repository work to run with tenant context | Operator-owned tables get a consistent tenant safety pattern | Makes new operator-owned tables safer by default. |
| `package:postgres` | Low-level Dart Postgres driver | Actually speaks to Postgres; usage is kept behind adapters | Keeping the raw driver isolated prevents unsafe one-off database access patterns | Keeps the low-level driver replaceable and testable because callers depend on adapters. |

### Postgres Extensions

Plain English purpose: Postgres extensions are extra capabilities installed into the shared database.

Restaurant analogy: They are specialized back-office tools: a safe-code ledger, recipe index, station map, prep timer, storage organizer, and performance report.

Technical purpose: Postgres extensions are database-level capabilities added beyond core SQL. They support cryptographic hashing, embedding similarity search, graph traversal, scheduled jobs, partition lifecycle management, query performance telemetry, and hierarchical organization modeling without forcing separate external systems for each capability.

| Extension | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| `pgcrypto` | Cryptography tools inside Postgres | Creates hashes, UUID helpers, and audit hash-chain digests | Audit and security features can use database-native fingerprints instead of fragile app-only hashing | Supports future audit and compliance proof work. |
| `pgvector` | Vector storage/search extension | Lets AI embeddings be stored and searched by similarity | Advisor retrieval can live near the operational/document data it needs | Supports a larger advisor corpus and semantic search surface. |
| `pg_diskann` | Advanced vector index extension | Supports scalable approximate vector search as data grows | Larger vector sets can remain searchable without every query becoming slow | Provides a scaling path if vector indexes outgrow simpler search. |
| `AGE` | Graph extension for Postgres | Lets the system query nodes and relationships | Relationship-heavy advisor questions can be answered without a totally separate graph database | Supports future causal graph and advisor traversal features. |
| `pg_cron` | Database scheduler | Runs scheduled database jobs such as rollup refreshes | Recurring database maintenance can run close to the data | Keeps scheduled database maintenance close to the data. |
| `pg_partman` | Partition manager | Helps split huge tables into smaller date/tenant chunks | Large audit/event/rollup tables stay easier to query and maintain | Keeps high-volume audit/event/rollup tables maintainable. |
| `pg_stat_statements` | Query statistics extension | Shows which SQL queries are slow, frequent, or expensive | Performance problems can be diagnosed from real query behavior | Supports performance tuning as usage grows. |
| `ltree` | Hierarchy path extension | Stores/query organization trees like operator -> region -> location | Operator/location hierarchies can be queried cleanly without awkward string parsing | Supports deeper org/location hierarchy without redesigning schema. |

### Important Execution Patterns

Plain English purpose: Important execution patterns are the approved ways code is allowed to run database work.

Restaurant analogy: Before someone enters the cash office, they sign in, say which restaurant/location they represent, and say whether they are doing normal shift work or special manager work.

Technical purpose: important execution patterns are runtime database standards. They require tenant-scoped work to run inside explicit transactions with transaction-local context, reserve privileged system execution for named maintenance paths, and isolate raw driver usage behind approved adapters to prevent context leaks and inconsistent transaction handling.

| Pattern | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| `runInTenantContext` | Normal tenant-scoped database execution | Starts a transaction and sets the current operator/location/user for that transaction | Most app work runs as a specific tenant, so RLS and audit can protect the right rows | Sets the baseline for safe new tenant-scoped repositories. |
| `runAsSystem` | Carefully scoped system execution | Runs backend maintenance or privileged work with an explicit reason | Some jobs are not tied to one user action, but they still need traceable boundaries | Keeps maintenance and admin jobs traceable when they must bypass normal user scope. |
| Raw-driver isolation | Keeping `package:postgres` behind an adapter | Prevents random files from opening direct database connections | Security, transactions, and testing stay consistent across repositories | Prevents future shortcuts from bypassing tenant context, transactions, or test seams. |

### How It Works

Typical secure database work:

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

Why `package:postgres` is not scattered everywhere:

```text
raw database driver
  -> adapter
  -> executor/pool/transaction abstractions
  -> repositories
  -> services/proxy/app
```

That keeps security, tenant context, testing, and transaction behavior consistent.

### Where It Lives

- Postgres code: `lib/infrastructure/persistence/postgres/`
- Migrations: `db/migrations/`
- Production apply guidance: `runbooks/phase_9_production1_migration_apply_runbook.md`

## 7. Tenant Safety And Row Level Security

### Plain English

Forge Flow is multi-tenant. That means many operators and locations can exist in the same system.

The safety rule is simple:

```text
Operator A must not see Operator B's data.
```

The system protects that in two ways:

1. App/proxy code passes the correct operator/location/user context.
2. Postgres Row Level Security blocks rows outside that context.

Repository discipline is the first line of defense. RLS is the database safety net.

### Tenant Identity And RLS

Plain English purpose: Tenant identity and RLS explain how the system keeps one operator's data separate from another's.

Restaurant analogy: Each restaurant company has its own locked cash drawer and records bin. Even if they sit in the same back office, staff can only open the drawer for their restaurant.

Technical purpose: tenant identity and RLS define the multi-tenant isolation model. Tenant identifiers label ownership, transaction-local settings tell Postgres the current tenant/actor, RLS policies enforce row access at the database layer, tenant-leading indexes keep scoped access performant, and time rules preserve correct business-date reporting.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Tenant | A customer/operator boundary | Separates one operator's data from another's | Multi-operator SaaS only works if each customer boundary is explicit and protected | Scales the platform to many operators without mixing ownership boundaries. |
| `operator_id` | Operator identifier | Labels which operator owns a row | Queries and policies can filter data to the correct operator | Becomes the backbone for future RLS, indexing, partitioning, and reporting. |
| `location_id` | Restaurant/location identifier | Labels which location a row belongs to | Operators with multiple locations can scope access and reporting correctly | Supports multi-location reporting and scoped permissions. |
| `user_id` | Acting user identifier | Labels who is performing the action | Audit, permissions, and session behavior can tie actions to a real actor | Improves future audit, permissions, and per-user session controls. |
| RLS | Row Level Security | Lets Postgres hide rows that do not match the current context | The database itself becomes a backstop against cross-tenant data leaks | Provides database-level protection as the query surface grows. |
| RLS policy | Database rule for row access | Defines who can select/insert/update/delete rows | Access rules are enforced even if a query forgets a filter | Keeps access rules enforced even when future queries change. |
| Wrapper function | Approved helper used by RLS policies | Avoids unsafe direct use of session settings in policies | Policy logic stays consistent and lintable across many tables | Keeps policy logic lintable and consistent across more tables. |
| `set_config(..., true)` | Transaction-local setting | Sets current operator/location/user only for this transaction | Tenant context cannot accidentally leak into the next request on a reused connection | Prevents tenant leakage when pooled connections are reused. |
| Tenant-leading index | Index beginning with tenant columns | Keeps tenant-scoped queries fast and safe | The database can efficiently find one operator's rows without scanning everyone else's | Keeps tenant-scoped queries fast at larger row counts. |
| `TIMESTAMPTZ` | Timestamp with timezone | Stores absolute instants safely | Events from different timezones can be ordered and compared correctly | Avoids cross-timezone ordering bugs as regions and integrations expand. |
| Business date | Restaurant-local operating date | Lets a late-night shift belong to the correct business day | Restaurant reporting follows operating reality, not just calendar midnight | Preserves restaurant reporting semantics across late-night operations. |

### How It Works

```text
verified user belongs to operator X
  -> proxy creates TenantContext(operator X)
  -> transaction sets app.operator_id = X locally
  -> query asks for records
  -> RLS policy checks current operator
  -> Postgres returns only rows for operator X
```

Important rule:

- Do not use global session settings for tenant context.
- Use transaction-local settings so context cannot leak between requests.

### Where It Lives

- RLS wrappers: `db/migrations/202604280000_phase_9_0sigma_b_rls_wrappers.sql`
- Policy rewrites: `db/migrations/202604280001_phase_9_0sigma_b_rewrite_existing_policies.sql`
- RLS lint: `tool/rls_policy_lint.dart`
- Tenant execution code: `lib/infrastructure/persistence/postgres/`

## 8. Proxy And API Layer

### Plain English

The proxy is the secure server-side front desk.

The Flutter app should not have database passwords, vendor secrets, admin credentials, or privileged service keys. The proxy has the protected access. The app asks the proxy to do protected work.

The proxy checks:

- who the caller is
- which operator/location/user they belong to
- what permissions they have
- whether the request is allowed
- what database or Firebase action should happen

### Proxy Request And Security

Plain English purpose: Proxy request and security explain how the app asks the server to do protected work.

Restaurant analogy: The proxy is the manager at the office door. Staff can request something from the safe, but the manager checks who they are and whether the request is allowed.

Technical purpose: proxy request and security define the server API boundary and trust enforcement layer. They cover route contracts, HTTP semantics, DTO boundaries, JWT verification, permission checks, fail-closed behavior, and the Cloud Run runtime that hosts privileged server operations outside the Flutter client.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Proxy | Server-side HTTP API | Protects secrets and performs privileged work | The app can stay untrusted/thin while sensitive operations happen on the server | Provides the server boundary future admin, vendor, and workflow routes can reuse. |
| API route | URL path handled by the proxy | Defines what operation the caller is requesting | Each capability has a clear, testable entry point | New capabilities can be versioned, tested, and documented cleanly. |
| HTTP method | Verb like GET/POST/PATCH/DELETE | Describes read, create, update, or delete style behavior | The API communicates intent using standard web conventions | - |
| DTO | Data Transfer Object | Safe request/response shape crossing the API boundary | The app receives only the fields it should know about, not raw database internals | Lets API contracts evolve without exposing database internals. |
| JWT | Signed identity token | Proves who is calling and carries identity claims | The proxy can verify identity without trusting a plain user id from the app | Scales identity proof across services without passing passwords. |
| Permission guard | Authorization check | Blocks callers without the needed permission | Sensitive operations are denied before they reach data-changing code | Lets new protected actions reuse one authorization pattern. |
| Fail closed | Deny when uncertain | Prevents misconfiguration from silently allowing unsafe behavior | Broken config becomes an outage, not an accidental security bypass | Reduces security risk as configuration and environments multiply. |
| Dart executable | Compiled server program | Lets the proxy run as a Cloud Run container | The proxy can deploy as a small runnable artifact | - |
| Cloud Run | Managed container host | Runs the proxy in staging/production-style environments | The backend can scale and restart without managing VM servers | Lets backend route surface scale and deploy independently from the app. |

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

Representative routes:

- `GET /healthz`
- `GET /readyz`
- `GET /health`
- `GET /v1/scope`
- `GET /v1/usage-smoke`
- `GET /v1/advisor-smoke`
- `GET /v1/auth/permissions/snapshot`
- `POST /v1/auth/session/login`
- `POST /v1/auth/session/refresh`
- `POST /v1/auth/session/revoke`
- `POST /v1/auth/session/revoke-all`
- `POST /v1/auth/password/change`
- `POST /v1/auth/mfa/totp/begin`
- `POST /v1/auth/mfa/totp/confirm`
- `POST /v1/auth/mfa/recovery/consume`
- `/v1/admin/auth/*`

### Where It Lives

- Proxy main: `tool/advisor_proxy/main.dart`
- Proxy wiring: `tool/advisor_proxy/proxy_bootstrap.dart`
- Proxy routes/core: `tool/advisor_proxy/advisor_proxy.dart`
- Build: `Dockerfile`
- Deploy: `scripts/deploy_staging_proxy.ps1`

## 9. DNS, Edge, And Cloud Run

### Plain English

Users and apps do not call a raw server process. They call a friendly name.

For staging, that name is:

```text
staging-api.feflow.org
```

DNS translates that name into a network destination. Google receives the traffic, checks HTTPS and edge rules, then forwards it to the Cloud Run proxy.

### DNS And Edge Routing

Plain English purpose: DNS and edge routing explain how a public hostname reaches the running proxy service.

Restaurant analogy: It is the restaurant's street address, front sign, host stand, security check, and service corridor guiding a request to the right back-office desk.

Technical purpose: DNS and edge routing define the public ingress path. DNS resolves hostnames, certificates establish HTTPS trust, the load balancer terminates and routes traffic, Cloud Armor/reCAPTCHA provide edge policy controls, the serverless NEG binds the load balancer to Cloud Run, and Cloud Run executes the proxy container.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Hostname | Human-readable service name | Gives apps/users a stable name to call | Clients can keep calling the same name even when backend wiring changes | Keeps client configuration stable through infrastructure changes. |
| DNS | Internet naming system | Translates hostnames into destinations | Humans and apps use names; networks route to destinations | Supports future environment/domain expansion. |
| A record | DNS record from hostname to IPv4 address | Points `staging-api` directly to `34.54.204.29` | The hostname can reach Google's reserved load-balancer IP directly | Useful when a hostname should point directly at a reserved load-balancer IP. |
| CNAME | DNS record from hostname to hostname | Points one name at another service-owned name | Useful when another provider owns the target and may change its IPs | Useful when a provider-managed hostname should hide changing IPs. |
| IP address | Numeric network address | Initial destination for internet traffic | Network routers need numeric addresses to deliver traffic | - |
| TLS/HTTPS certificate | Proof used for secure HTTPS | Lets browsers trust encrypted traffic to the hostname | Users and apps can communicate securely without certificate warnings | Establishes the trust foundation for future public APIs. |
| Google managed cert | Certificate Google provisions/renews | Handles HTTPS certificate lifecycle for the load balancer | Certificate renewal becomes cloud-managed instead of a manual chore | Reduces manual renewal risk as more hostnames are added. |
| Load balancer | Public traffic entry point | Receives requests and routes them to the backend | Traffic gets one stable front door with routing, HTTPS, and edge controls | Allows multiple services and edge policies behind one entry point. |
| Cloud Armor | Edge security policy | Logs or blocks suspicious traffic before backend | Protection happens before bad traffic reaches application code | Can move from monitoring to enforcement as traffic evidence improves. |
| reCAPTCHA edge path | Bot/abuse protection path | Helps protect public endpoints from automated abuse | Automated attacks can be challenged or filtered closer to the edge | Adds a path for abuse protection on public endpoints. |
| Serverless NEG | Load balancer backend connector | Connects Google load balancing to Cloud Run | The load balancer can treat a serverless Cloud Run service as a backend | Keeps load-balancer-to-Cloud-Run routing standard. |
| Cloud Run service | Managed running container | Hosts the Dart proxy | The proxy runs without managing machine instances directly | Allows backend revisions without DNS changes. |

### How It Works

Current staging path:

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

Why a hostname matters:

- Clients can call a stable name.
- Certificates are issued for names, not just random IPs.
- Infrastructure can move behind the name without changing app code.

Why a CNAME sometimes matters:

- It lets one hostname point to another hostname.
- That is useful when another provider owns the changing backend target.
- In this staging case, the correct final fix was an A record to Google's reserved IP.

### Where It Lives

- Current status: `PROJECT_TRACKER.md`
- Deploy script: `scripts/deploy_staging_proxy.ps1`
- Proxy health routes: `tool/advisor_proxy/advisor_proxy.dart`

## 10. Authentication

### Plain English

Authentication answers: "Who are you?"

Firebase handles the login credential part. Forge Flow handles the business meaning of that login.

Firebase says:

- this password/MFA was valid
- this Firebase user is signed in
- this ID token is legitimate

Forge Flow says:

- this user belongs to this operator
- this user may act in this location
- this user has these roles and permissions
- this session should be recorded

### Identity And Sessions

Plain English purpose: Identity and sessions explain login identity and how it becomes Forge Flow business identity.

Restaurant analogy: Firebase checks the person's ID at the door. Forge Flow checks the shift roster and role sheet to know which restaurant, location, and station they belong to.

Technical purpose: identity and sessions define the authentication handoff between external credential authority and internal business identity. Firebase verifies credentials and issues signed tokens; custom claims and Forge Flow records map that token to tenant/user/location context; session ledgers make auth activity auditable; secure storage preserves local session state; fail-closed logic rejects incomplete identity context.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Firebase Identity Platform | Hosted auth provider | Handles credentials, sign-in, password auth, MFA identity | Credential security and MFA are delegated to a dedicated identity platform | Keeps credential and MFA upgrades externalized. |
| Firebase UID | Firebase user identifier | Stable identity from Firebase | Forge Flow can link business user records to a durable auth identity | Provides a stable link between Firebase and Forge Flow user records. |
| ID token | Signed JWT from Firebase | Proves the user is currently authenticated | The app can prove login state to the proxy without sending passwords | Gives future APIs a reusable proof of login state. |
| Custom claims | Extra fields inside the token | Carry operator/location/user/role context | The proxy can connect Firebase identity to Forge Flow tenant context | Carries business identity context into protected server calls. |
| Auth session | Forge Flow record of a login session | Makes sign-in activity auditable and revocable | Session behavior becomes visible and controllable server-side | Enables revocation and audit as login flows grow. |
| Session ledger | Server-side session table | Records login, refresh, revoke, and session state | Security reviews can trace session lifecycle instead of trusting device state only | Supports future security reviews and session management. |
| Secure storage | Device-protected local storage | Stores local session envelope safely | The app can persist session state without plain local files | Keeps device session handling safer as auth state grows. |
| Fail closed | Deny when context is incomplete | Prevents accidental auth bypass | Missing claims or broken setup do not accidentally unlock the app | Prevents missing identity context from becoming a security hole. |

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

Important claims:

- `operator_id`
- optional `user_id`
- optional `location_id`
- role/admin/support flags
- role version fields

If required claims are missing, the app/proxy should fail closed.

### Where It Lives

- Auth state: `lib/state/auth_session_notifier.dart`
- Firebase runtime wiring: `lib/services/auth/firebase_auth_runtime_bindings.dart`
- Login service: `lib/services/auth/firebase_auth_login_service.dart`
- Proxy gateway: `lib/services/auth/proxy_auth_operations_gateway.dart`
- Auth schema: `db/migrations/202604250008_auth_schema_foundation.sql`

## 11. MFA And Recovery Codes

### Plain English

MFA means "password plus another proof."

The launch MFA path is TOTP: the rotating six-digit codes from an authenticator app.

Recovery codes are backup one-time codes. They are used if someone loses access to their authenticator app. They should be shown once, stored hashed, and consumed through the proxy.

### MFA Protection

Plain English purpose: MFA protection explains the second proof required beyond a password.

Restaurant analogy: Opening the restaurant safe requires both the manager's key and today's rotating safe code. Having only one is not enough.

Technical purpose: MFA protection defines the second-factor authentication and recovery safety model. It covers TOTP setup/confirmation, recovery-code generation and one-time consumption, hash-only storage, attempt ledgers, Firebase Identity Toolkit integration, and throttling controls to reduce credential-stuffing and brute-force risk.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| MFA | Multi-factor authentication | Requires another proof beyond password | A stolen password alone is not enough to access protected accounts | Raises the baseline before higher-risk admin/operator workflows expand. |
| TOTP | Time-based one-time password | Generates rotating codes from authenticator apps | Strong MFA works without SMS and without storing reusable codes | Avoids SMS dependency while supporting standard authenticator apps. |
| Recovery code | One-time backup code | Lets a user recover access if MFA device is unavailable | Users have a controlled recovery path that does not require weakening MFA | Keeps a secure account-recovery path without weakening MFA. |
| Hash | One-way fingerprint | Stores proof of a code without storing the code itself | If the database leaks, raw recovery codes are not exposed | Reduces blast radius if stored recovery data is exposed. |
| Attempt ledger | Record of MFA/recovery attempts | Supports rate limits, abuse detection, and audit | Suspicious guessing or repeated failures can be detected and limited | Supports future risk scoring, throttling, and investigation. |
| Identity Toolkit | Firebase admin/auth API surface | Lets server-side code manage MFA operations | The proxy can manage Firebase MFA flows without putting admin power in the app | Keeps MFA operations aligned with Firebase as the credential authority. |
| Rate limit | Attempt throttling | Prevents unlimited guessing | Attackers cannot brute-force recovery or MFA codes freely | Protects future public auth flows from automated guessing. |

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

Recovery code consume:

```text
user submits recovery code
  -> app sends code to proxy
  -> proxy checks attempt limits
  -> proxy hashes submitted code
  -> proxy compares hash to stored hash
  -> proxy consumes code once
  -> audit/attempt records are written
```

### Where It Lives

- App MFA gateway: `lib/services/mfa/proxy_mfa_operations_gateway.dart`
- Recovery attempts migration: `db/migrations/202604280011_phase_9_0sigma_recovery_code_attempts.sql`
- Recovery attempt store: `lib/infrastructure/persistence/postgres/repositories/recovery_code_attempt_store.dart`
- Proxy MFA routes: `tool/advisor_proxy/advisor_proxy.dart`

## 12. Permissions, Roles, And Admin

### Plain English

Permissions answer: "What are you allowed to do?"

Forge Flow uses roles so permissions are manageable. A manager, owner, staff member, internal admin, or support user can receive different permissions.

The app should not guess permissions from a job title. It should ask for a permission snapshot and obey that snapshot.

### Authorization And Admin

Plain English purpose: Authorization and admin explain how the system decides what a signed-in person can do.

Restaurant analogy: A server, bartender, manager, and owner may all be inside the same restaurant, but only certain badges open the wine room, cash drawer, schedule board, or manager POS screen.

Technical purpose: authorization and admin define authorization after authentication. RBAC maps users to roles and roles to permission keys, snapshots give clients a resolved permission view, admin routes mutate access through protected APIs, role audit logs preserve access-change history, and future ReBAC can add relationship-based rules without replacing the launch model.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| RBAC | Role-Based Access Control | Gives users roles that expand into permissions | Access can be managed by job responsibility instead of custom rules per person | Can grow into custom/team roles without rewriting every feature. |
| Permission key | Named allowed action | Represents a specific capability like viewing or editing something | Capabilities become explicit and testable instead of hidden in UI code | Lets new features add precise gates. |
| Role | Bundle of permissions | Makes permission assignment easier | Common permission sets can be reused across many users | Simplifies access management as teams grow. |
| Role grant / user role | Assignment of role to user | Gives a user a role in an operator/location context | Access can be scoped to the correct operator or location | Supports future location-scoped and time-scoped access. |
| Permission snapshot | Current resolved permission set | Tells the app what this user can do now | The UI can render allowed actions without recalculating auth logic | Lets client UX adapt without reimplementing authorization logic. |
| Admin route | Protected server-side management route | Lets admins manage users/roles safely | Sensitive admin changes happen behind server-side checks and audit | Centralizes future user/role admin changes behind audit and permission checks. |
| Role audit log | Record of role changes | Preserves who changed access and when | Access changes are traceable for security and support | Supports future compliance and support investigations. |
| ReBAC | Relationship-Based Access Control | Future model where access depends on relationships, deferred to Phase 12 | More advanced access can be added later without overcomplicating launch RBAC | Leaves a path for relationship-based workflow access later. |

### How It Works

```text
app requests permission snapshot
  -> proxy verifies user
  -> proxy reads roles and role permissions
  -> proxy resolves effective permissions
  -> app receives permission snapshot
  -> UI enables/disables protected actions
```

Current status:

- B17 admin role catalog CRUD is implemented and smoke-passed on staging.
- Operator-facing Settings -> Team UX can consume the role catalog surface
  when that slice resumes.

### Where It Lives

- Role repositories: `lib/infrastructure/persistence/postgres/repositories/`
- Auth schema: `db/migrations/202604250008_auth_schema_foundation.sql`
- Admin proxy routes: `tool/advisor_proxy/advisor_proxy.dart`

## 13. Service Principals

### Plain English

A service principal is a non-human identity.

Humans log in with Firebase. Automation should not pretend to be a human. A workflow or backend job needs its own identity so audit logs can say exactly what acted.

Example:

```text
human actor: manager Sarah
service actor: nightly-audit-anchor-job
```

### Automation Identity

Plain English purpose: Automation identity explains identity for non-human jobs and workflows.

Restaurant analogy: A scheduled prep checklist or nightly closing job should have its own staff badge, not borrow the general manager's badge.

Technical purpose: automation identity defines non-human identity. Service principals receive scoped credentials, `sp:` JWTs distinguish automation from Firebase human tokens, issuers and verifiers control token lifecycle, actor-kind fields preserve audit attribution, and workflow identities allow future automation to execute with explicit permissions and traceability.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Service principal | Non-human identity | Lets automation act with scoped permissions | Workflows and jobs can act without pretending to be a human user | Enables future workflows without human impersonation. |
| `sp:` JWT | Service-principal token pattern | Distinguishes automation tokens from human Firebase tokens | The proxy can quickly route token handling and audit attribution by actor type | Keeps service tokens distinguishable from human login tokens. |
| Issuer | Code that creates a signed token | Gives an approved service a token | Token creation stays controlled instead of letting arbitrary services self-authorize | Needed to scale service identities safely. |
| Verifier | Code that validates a signed token | Checks that the token is real and allowed | The proxy can reject fake or expired automation identities | Lets APIs trust automation identity without trusting callers blindly. |
| Actor kind | Human/service classification | Keeps audit records honest about who or what acted | Audit reviews can distinguish user actions from automation actions | Keeps future audit attribution clear as automation expands. |
| Workflow identity | Identity used by automation | Lets Phase 12 workflows run without impersonating humans | Future automation can have scoped permissions, cost tracking, and audit trails | Forms the identity foundation for Phase 12 automation. |

### How It Works

```text
workflow needs to run
  -> requests or receives service-principal JWT
  -> proxy verifies `sp:` token
  -> proxy derives service actor context
  -> action runs with scoped permissions
  -> audit log records service actor
```

Known gap:

- The verifier exists.
- The issuer route is still queued.
- Phase 12 workflows need that issuer route.

### Where It Lives

- Service-principal migration: `db/migrations/202604280004_phase_9_0sigma_d_service_principals.sql`
- JWT code: `tool/advisor_proxy/advisor_proxy.dart`

## 14. Audit And Compliance

### Plain English

Audit answers: "Who did what, when, and under which authority?"

For sensitive systems, ordinary logs are not enough. Forge Flow is building toward tamper-evident audit logs, where records are chained together with hashes. If someone changes old audit data, the chain no longer verifies.

This does not mean the database is impossible to alter. It means alteration becomes detectable.

### Audit Integrity

Plain English purpose: Audit integrity explains how sensitive actions are recorded and checked later.

Restaurant analogy: It is the manager logbook with numbered pages and end-of-night signatures. If someone rewrites a page, the signatures and page order no longer line up.

Technical purpose: audit integrity defines tamper-evident audit architecture. Durable audit rows capture actor/action context, actor-kind fields separate human/service/system actions, pgcrypto digests chain rows together, external anchors checkpoint chain state outside normal table mutation, and redaction patterns support privacy obligations without destroying audit structure.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Audit log | Durable event record | Stores who did what and when | Sensitive operations need a trustworthy record for support, compliance, and investigations | Forms the foundation for future compliance, support, and incident review. |
| Actor | Person or service that acted | Identifies the source of the action | The system can attribute changes to the right human or automation | Allows future investigations to attribute changes accurately. |
| Actor kind | Human/service/system label | Distinguishes people from automation | Auditors can tell whether a person, workflow, or system job performed the action | Avoids mixing human and automation responsibility in future audits. |
| Hash | One-way fingerprint | Produces a digest of row contents | Changes to the original content become detectable because the fingerprint changes | Makes later tampering detectable. |
| Hash chain | Each row points to prior hash | Makes historical tampering detectable | A change in old audit history breaks the chain after it | Makes sequence integrity verifiable over time. |
| Digest | Hash output | The fingerprint value used in the chain | The verifier has a compact value to compare instead of re-reading trust by eye | - |
| Anchor | External checkpoint | Stores a trusted chain checkpoint outside normal table flow | There is an independent point of comparison if database history is questioned | Provides an external proof point for audit review. |
| Immutable blob | Storage object that should not change | Preserves daily audit anchor evidence | Audit checkpoints can survive normal database edits or disputes | Reduces reliance on database-only audit trust. |
| Redaction | Removing sensitive personal content | Supports erasure while preserving audit shape | Privacy obligations can be handled without destroying the audit trail | Balances privacy obligations with long-term audit retention. |

### How It Works

```text
sensitive action happens
  -> audit row is written
  -> row includes previous hash reference
  -> pgcrypto computes digest
  -> daily anchor records chain checkpoint
  -> verifier can later walk the chain
```

Known contract note:

- `audit_logs.actor_principal_id` and `auth_events_audit.actor_service_principal_id` overlap conceptually but differ in name/type.
- This is intentional in migrations but needs clear query guidance.
- It is tracked as B34.

### Where It Lives

- Audit migration: `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`
- Live repair migration: `db/migrations/202604280013_phase_9_0sigma_audit_actor_kind_live_repair.sql`
- Audit anchor tool: `tool/audit_anchor/audit_anchor.dart`
- Audit runbook: `runbooks/audit_chain_verify_runbook.md`
- Erasure runbook: `runbooks/gdpr_erasure_runbook.md`

## 15. Eventing And Real Time

### Plain English

When something changes on the server, other parts of the system may need to know.

The safe pattern is not "send a notification and hope." The safe pattern is:

1. Save the real database change.
2. Save an event row.
3. Let a worker deliver the event.

The event row is durable. A notification is only a wake-up.

### Event Delivery

Plain English purpose: Event delivery explains how the system tells other parts of the platform that something changed.

Restaurant analogy: It is the kitchen ticket rail. An order ticket stays on the rail until the expo or runner picks it up, even if the kitchen is busy.

Technical purpose: event delivery defines reliable asynchronous delivery. The transactional outbox persists events with the source write, NOTIFY wakes workers, row-claiming with `SKIP LOCKED` enables concurrent consumers, Pub/Sub/WebSocket paths distribute updates, leases and idempotency support safe retries, and dead-letter handling isolates poisoned events.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Event | Record that something happened | Lets other systems react | Changes can fan out without every system being tightly coupled to the original write | Forms the basis for future async consumers and workflow triggers. |
| Outbox | Database table of events to deliver | Makes event delivery durable | If a worker or network fails, the event is still stored for retry | Avoids lost events when workers or networks fail. |
| `event_outbox` | Forge Flow's outbox table | Stores pending/delivered event records | The app has one standard backbone for future realtime and workflow triggers | Provides a reusable event backbone for realtime and workflows. |
| Postgres NOTIFY | Lightweight database notification | Wakes workers when new events exist | Workers can react quickly without constantly polling | Keeps worker wakeups low-latency without making NOTIFY the source of truth. |
| Pub/Sub | Cloud messaging service | Fan-outs events to subscribers | Multiple downstream services can receive events without each querying Postgres directly | Scales fan-out to multiple downstream consumers. |
| WebSocket | Long-lived app connection | Pushes updates to connected clients | Devices can update sooner than a periodic polling loop | Enables future real-time app experiences. |
| `SKIP LOCKED` | SQL row-claiming pattern | Lets workers claim jobs without blocking each other | Several workers can process the queue safely in parallel | Allows parallel workers without double-claiming rows. |
| Lease | Temporary claim on work | Prevents duplicate workers from processing the same row | A failed worker does not permanently lose or lock an event | Lets the system recover work from failed workers. |
| Dead-letter | Failed-event holding area | Keeps repeatedly failing events from blocking all progress | Bad payloads can be isolated while healthy events continue | Prevents one bad event from blocking the whole backlog. |
| Idempotency | Safe repeat handling | Makes retries avoid duplicate side effects | Retried writes/events do not accidentally create duplicate sessions, charges, or actions | Makes retries safe as delivery paths grow. |

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

Why not rely only on NOTIFY:

- Notifications can be missed.
- The durable outbox row remains.
- A worker can always catch up by reading the table.

Known gap:

- Event table exists.
- Consumer worker scaffold and dead-letter contract are still queued.

### Where It Lives

- Contract: `docs/contracts/event_outbox_contract.md`
- Migration: `db/migrations/202604280003_phase_9_0sigma_e_event_outbox.sql`

## 16. Usage, Caps, And Rollups

### Plain English

Usage tracking answers: "How much did someone use?"

Caps answer: "How much are they allowed to use?"

Rollups answer: "Can we summarize lots of raw detail into faster dashboard numbers?"

Instead of recalculating everything from raw rows every time, the system precomputes summaries by time period.

### Usage And Reporting

Plain English purpose: Usage and reporting explain usage measurement, limits, and summarized reporting.

Restaurant analogy: It is like counting inventory pulls during service, comparing them to par levels, and turning every ticket into a nightly, weekly, or monthly manager report.

Technical purpose: usage and reporting define metering and aggregation infrastructure. Usage logs record consumption, caps define allowed limits, reconciliation keys align actuals with caps, rollup grains precompute summaries at multiple reporting levels, aggregation state tracks freshness, and scheduled jobs maintain derived tables for dashboards and health checks.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Usage log | Record of usage | Tracks consumed units/events | Billing, limits, and abuse controls need a factual usage trail | Forms the factual basis for future billing, limits, and abuse analysis. |
| Usage cap | Limit record | Defines allowed usage by operator/slot/period | Operators can be kept within plan, budget, or product limits | Supports future plan enforcement and quota controls. |
| Two-slot key | Cap identity model | Separates dimensions needed for reconciliation | Cap math can distinguish the right entity and period without ambiguous joins | Avoids redesigning reconciliation when cap dimensions expand. |
| Reconciliation | Cap versus actual comparison | Checks whether usage fits allowed limits | The system can catch overages, drift, or accounting mismatches | Keeps future usage/accounting comparisons trustworthy. |
| Rollup | Precomputed summary | Makes dashboards faster | Expensive calculations happen ahead of time instead of on every dashboard load | Keeps dashboards fast as data volume grows. |
| Grain | Time bucket size | Daypart, day, week, month, quarter, year | Different reporting views can use the right time scale | Supports multiple reporting views without recalculating from raw rows. |
| Aggregation state | Progress tracker | Remembers what rollup work is fresh or stale | Health checks can tell whether summaries are current | Enables freshness monitoring for future health surfaces. |
| `pg_cron` | Database scheduler | Runs recurring rollup jobs | Summary maintenance can run automatically on a schedule | Automates summary maintenance as reporting grows. |

### How It Works

```text
raw usage or operational events arrive
  -> usage_logs record details
  -> usage_caps define limits
  -> rollup functions aggregate detail
  -> dashboards read summary tables
  -> health checks monitor freshness
```

Known Q3.1 gap:

- `usage_caps` has the two-slot model.
- `usage_logs` still needs a matching mirror for cap-versus-actual reconciliation.
- This is tracked as B33.

### Where It Lives

- Usage foundation: `db/migrations/202604250005_advisor_cloud_foundation.sql`
- Usage cap migrations: `db/migrations/202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_schema.sql`, `db/migrations/202604280006_b_phase_9_0sigma_g_usage_caps_two_slot_backfill.sql`, `db/migrations/202604280006_c_phase_9_0sigma_g_usage_caps_two_slot_contract.sql`
- Rollups: `db/migrations/202604280010_a_phase_9_0sigma_k_rollups_schema.sql`, `db/migrations/202604280010_b_phase_9_0sigma_k_rollup_functions.sql`, `db/migrations/202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql`

## 17. Advisor And AI

### Plain English

The advisor is not just "ask a chatbot."

It is supposed to answer from evidence:

- product docs
- operational metrics
- SQL data
- graph relationships
- prior context

The advisor should recommend, explain, and cite context. It should not silently perform risky actions.

### Advisor Evidence And Models

Plain English purpose: Advisor evidence and models explain how the AI advisor answers from evidence.

Restaurant analogy: The advisor is an experienced operator who checks the recipe binder, POS numbers, labor sheet, reservation book, and station map before making a recommendation.

Technical purpose: advisor evidence and models define evidence-grounded AI architecture. Provider abstractions isolate external model vendors, retrieval and embeddings locate relevant context, vector and sparse search collect candidate evidence, reranking improves context quality, classifiers route work to the right tool path, synthesis produces the final answer, provenance supports reviewability, and caching/routing control latency and cost.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| LLM | Large language model | Reads context and generates natural-language answers | Operators can ask questions in normal language instead of learning query tools | Allows a natural-language interface as operational data grows. |
| Provider | Wrapper around an external AI service | Lets code call Anthropic/Voyage through stable interfaces | The app can swap or route providers without rewriting every advisor caller | Makes model/vendor swaps easier. |
| RAG | Retrieval-Augmented Generation | Retrieves evidence before asking the model to answer | Answers are grounded in repo/product/operator context instead of generic guesses | Lets answer quality improve as the evidence corpus improves. |
| Embedding | Meaning represented as numbers | Lets similar text be searched by similarity | The system can find relevant text even when wording is not identical | Supports semantic search across a larger corpus. |
| Vector search | Similarity search over embeddings | Finds documents close to the user's question | The advisor can locate useful evidence quickly across a large corpus | Keeps retrieval feasible as document chunks grow. |
| `pgvector` | Postgres vector extension | Stores/searches embeddings inside Postgres | Retrieval can live beside permissions, tenant data, and source documents | Keeps advisor retrieval close to source data and permissions. |
| Reranker | Model that re-sorts retrieved results | Puts the most relevant evidence first | The final answer gets better context and less noise | Improves relevance as the corpus becomes noisier and larger. |
| Classifier | Model/router that chooses the path | Decides SQL, retrieval, graph, or mixed route | Simple questions can take cheap paths while complex questions get stronger tools | Routes cost and latency intelligently as advisor tools expand. |
| Synthesis | Final answer generation | Combines evidence into a readable response | The user gets an explanation, not just raw search results | - |
| Tool use | Model-triggered structured calls | Lets advisor call SQL/retrieval/graph tools | The advisor can fetch exact data instead of making up operational numbers | Allows future structured tools and workflows without free-form guessing. |
| Provenance | Evidence trail | Shows what sources support the answer | Users can inspect why the recommendation was made | Supports trust, debugging, and review of advisor answers. |
| Prompt caching | Reuse of stable prompt context | Reduces cost and latency | Repeated advisor calls become cheaper and faster | Controls cost and latency at higher usage. |
| Model routing | Choosing cheap/strong model per task | Saves cost while keeping quality | Expensive models are reserved for tasks that actually need them | Controls quality/cost tradeoffs as advisor traffic grows. |

### How It Works

```text
user asks a question
  -> classifier decides the route
  -> system retrieves docs, SQL facts, graph facts, or mixed evidence
  -> Voyage reranks evidence
  -> Claude synthesizes answer
  -> app shows recommendation and supporting context
```

Provider choices in the docs:

- Anthropic Claude Haiku for classification/cheaper tasks.
- Anthropic Claude Sonnet for answer synthesis.
- Voyage `voyage-4-large` for embeddings.
- Voyage `rerank-2.5` for reranking.
- Postgres `pgvector` for dense retrieval.
- Postgres full-text search for sparse retrieval.
- AGE for graph traversal.

Safety rule:

- Advisor is recommendation-only until workflow approval gates exist.

### Where It Lives

- Provider interfaces: `lib/domain/services/llm_provider.dart`, `lib/domain/services/embedding_provider.dart`, `lib/domain/services/rerank_provider.dart`
- Provider implementations: `lib/services/claude_llm_provider.dart`, `lib/services/voyage_embedding_provider.dart`, `lib/services/voyage_rerank_provider.dart`
- Advisor decision docs: `docs/phases/phase_11a/phase_11a_decision_register.md`
- Advisor corpus docs: `docs/Knowledge_graph_docs/`

## 18. Graph Layer

### Plain English

Tables are good for rows. Graphs are good for relationships.

The graph layer helps answer questions where the connections matter:

- What caused this?
- What is related to this issue?
- Which document, workflow, metric, or operator fact connects to this symptom?

### Graph Data

Plain English purpose: Graph data explains how the system stores relationships between things.

Restaurant analogy: It is the restaurant flow map that shows how prep delays affect the line, how the line affects the expo window, and how the expo window affects guest timing.

Technical purpose: graph data define relationship modeling. Nodes and edges represent graph entities and links, AGE/Cypher provide graph query capabilities inside Postgres, projections build graph views from canonical facts, and tripwire metrics monitor size/degree thresholds so graph traversal remains operable.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Graph | Network of connected things | Models relationships, not just rows | Cause/effect and dependency questions are easier to answer as relationships | Supports future causal and relationship-heavy advisor reasoning. |
| Node | Thing in the graph | Represents an entity, document, metric, workflow, or concept | The graph needs named objects to connect and query | Gives future relationships standard entities to connect. |
| Edge | Relationship between nodes | Represents "causes", "references", "belongs to", "depends on" | Connections make it possible to traverse from symptom to evidence or cause | Allows relationship types to expand without changing the whole model. |
| AGE | Postgres graph extension | Lets Postgres run graph-style queries | Graph data can stay in the same database platform as the rest of the system | Keeps graph capability inside Postgres for now. |
| Cypher | Graph query language | Asks relationship questions across nodes/edges | Relationship questions can be expressed directly instead of with awkward joins | Gives future traversal queries a direct language. |
| Projection | Built graph view from source facts | Keeps graph query data aligned with canonical data | The graph reflects trusted source data rather than becoming a separate truth | Allows graph views to be rebuilt from canonical truth. |
| Tripwire metric | Safety/scale threshold | Warns when graph size/degree needs attention | Growth problems can be seen before graph queries become unhealthy | Warns before graph growth turns into operational trouble. |

### How It Works

```text
canonical facts/docs are processed
  -> graph nodes represent entities/concepts
  -> graph edges represent relationships
  -> advisor or health tools query relationships
  -> system can explain connected causes/evidence
```

### Where It Lives

- Graph migration: `db/migrations/202604280008_phase_9_0sigma_i_graph_canonical.sql`
- Future consumers: Phase 11b advisor traversal and Phase 11A health

## 19. Live Integrations

### Plain English

Forge Flow should eventually use live vendor data from POS, labor, reservation, accounting, banking, and other systems.

But the UI should not be rewritten for every vendor. Vendor data should enter through adapters, become canonical Forge Flow facts, and then flow through the same screens.

### Vendor Integrations

Plain English purpose: Vendor integrations explain how outside systems feed data into Forge Flow.

Restaurant analogy: POS, labor, reservation, and accounting vendors arrive at the loading dock with different paperwork. Adapters translate those papers before they enter the main kitchen flow.

Technical purpose: vendor integrations define external integration boundaries. Connectors handle vendor APIs/auth/webhooks, adapters normalize vendor payloads into canonical DTOs, secrets remain server-side, OAuth supports delegated authorization, watermarks make sync resumable, and raw imports preserve original evidence for debugging and replay.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Adapter | Translator for a vendor system | Converts vendor-specific data into Forge Flow shapes | Each vendor can differ without forcing the whole app to care | Lets new vendors plug in without UI rewrites. |
| Connector | Integration with an external service | Handles API calls, auth, sync, and vendor behavior | Vendor-specific networking and auth stay behind a clean boundary | Keeps vendor-specific networking and auth isolated. |
| Canonical DTO | Standard data shape | Lets the app ignore vendor-specific payload formats | Screens and domain logic can work the same way regardless of vendor | Keeps the core product stable across providers. |
| Vendor secret | API key/token for external service | Must stay server-side, not inside Flutter | Compromising a client app should not expose vendor credentials | Keeps integrations safer as more providers are added. |
| OAuth | Standard delegated auth flow | Lets customers authorize third-party integrations | Customers can connect accounts without handing Forge Flow their passwords | Supports customer-authorized integrations without password sharing. |
| Webhook | Vendor calls Forge Flow when something changes | Supports near-real-time sync from external systems | The system can react sooner than scheduled polling alone | Enables near-real-time integration updates. |
| Sync watermark | Last processed point | Lets imports continue without repeating all data | Sync jobs can resume efficiently and avoid duplicates | Makes incremental sync reliable and resumable. |
| Raw import record | Stored original vendor payload | Supports debugging and reprocessing | If mapping logic changes, the original evidence can be inspected or replayed | Supports debugging and replay when provider mappings change. |

### How It Works

```text
vendor API provides payload
  -> trusted connector fetches/receives data
  -> adapter converts payload into canonical facts
  -> repository stores facts
  -> SQLite/Postgres/state update
  -> UI and advisor use the same internal model
```

Rules:

- Use official APIs.
- Keep vendor secrets out of Flutter.
- Convert timestamps using restaurant IANA timezones.
- Do not build a separate UI truth path for each vendor.

### Where It Lives

- POS/labor plan: `docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`
- Reservation plan: `docs/phases/phase_8R/phase_8R_official_reservation_connector_plan.md`
- External integrations plan: `docs/phases/phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md`

## 20. Shared State Roadmap

### Plain English

Shared state means multiple devices can see and update the same server-backed data.

SQLite can still make the app fast locally, but Postgres becomes the source for shared truth. The proxy controls writes. Events tell other devices to refresh.

### Shared State Sync

Plain English purpose: Shared state sync explains how multiple devices can share official data while staying fast locally.

Restaurant analogy: The restaurant has one master expo board, while each station may keep a quick copy. The master board decides what is official.

Technical purpose: shared state sync defines the synchronization model. Postgres owns authoritative shared state, SQLite caches local read models, startup sync hydrates devices, invalidation/event bridges notify clients of changes, LWW provides a simple V1 conflict policy, and audit trails preserve mutation history.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Source of truth | Official record | Decides what is correct when copies differ | Multi-device state needs one trusted answer when local copies disagree | Prevents multi-device conflict from turning into competing truths. |
| Cache | Local copy | Makes reads fast and offline-friendly | The app can stay responsive without waiting on the server for every screen | Maintains app speed as shared data grows. |
| Invalidation | "Your cache is stale" signal | Tells app to refresh local data | Devices can update only what changed instead of constantly reloading everything | Avoids full reloads when only some data changed. |
| Startup sync | Initial data refresh on launch | Hydrates local cache from server | A returning device can catch up before showing stale shared state | Lets returning devices catch up safely. |
| Event bridge | Path from server events to clients | Pushes changes toward connected devices | Shared changes can appear on other devices quickly | Provides the path for real-time shared-state updates. |
| LWW | Last-write-wins conflict rule | Simple conflict model where latest accepted write wins | V1 can handle conflicts predictably without building complex merging too early | Keeps V1 conflict handling simple until richer merging is justified. |
| Audit trail | Record of changes | Preserves who changed shared state and when | Shared edits remain explainable and reversible by investigation | Lets shared edits be investigated later. |

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

- Shared state plan: `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md`
- Event contract: `docs/contracts/event_outbox_contract.md`

## 21. Operations Console

### Plain English

The operations console is an internal admin tool for Forge and Flow staff.

It is not the restaurant operator app. It is for managing the platform itself: operators, locations, pricing, feature flags, corpus, integrations, support, audit, and health.

### Internal Operations

Plain English purpose: Internal operations explain the admin tool used by Forge and Flow staff.

Restaurant analogy: It is the restaurant company's manager office, where trusted staff manage locations, menus, pricing, support, health checks, and incident notes.

Technical purpose: internal operations define platform administration. A staff-only web UI calls protected admin APIs, feature flags control rollout, observability surfaces health and diagnostics, support actions are routed through auditable workflows, and browsers never receive direct database access.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Internal admin app | Staff-only management UI | Gives Forge and Flow admins controlled platform tools | Platform operations can happen through governed workflows instead of ad hoc database access | Scales support and platform operations without direct DB access. |
| Flutter Web | Flutter running in browser | Lets admin console share Flutter skills/patterns | The team can reuse app framework knowledge for internal tooling | - |
| Admin API | Protected proxy routes | Performs admin actions server-side | Admin power stays behind server-side identity, permission, and audit checks | Centralizes future admin authority behind server checks. |
| Feature flag | Runtime on/off switch | Enables controlled rollout of capabilities | Features can be tested, staged, or disabled without shipping a new app build | Supports safer rollout and rollback. |
| Observability | Health/log/metric visibility | Shows whether systems are working | Operators and staff can diagnose problems before users report them | Improves diagnosis as services multiply. |
| Support action | Admin operation for customer support | Helps resolve customer issues without direct DB poking | Support becomes safer, repeatable, and auditable | Makes customer support repeatable and auditable. |
| No direct DB from browser | Security boundary | Browser talks to proxy, not Postgres | A compromised browser session cannot become raw database access | Keeps the admin surface safer as tooling expands. |

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

- Ops console plan: `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`
- Admin routes: `tool/advisor_proxy/advisor_proxy.dart`

## 22. Workflow Platform

### Plain English

The workflow platform is the future automation layer.

It will let Forge Flow run scheduled or event-driven work, but with strict identity, permission, audit, cost, and approval controls.

The important safety idea is: automation should be powerful, but not invisible.

### Workflow Automation

Plain English purpose: Workflow automation explains future automation that can run repeated operational work.

Restaurant analogy: It is a trained shift lead following a prep or closing checklist. Routine steps can run automatically, but risky changes still need manager approval.

Technical purpose: workflow automation defines controlled automation architecture. Triggers start workflows, service-principal identity authenticates them, tool registries restrict available actions, Plan-Then-Execute separates planning from mutation, approval gates protect risky operations, artifacts preserve outputs, background jobs execute long work, and cost caps/batch paths control provider spend.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Workflow | Automated process | Runs a defined sequence of steps | Repeated operational work can happen reliably without manual clicking | Automates repeated operations as the product matures. |
| Trigger | Thing that starts a workflow | Could be time, event, user action, or external signal | Automation can respond to schedules and real events | Supports scheduled and event-driven future work. |
| Tool registry | List of allowed workflow actions | Controls what automation can call | Workflows cannot call arbitrary dangerous operations | Controls automation scope as more tools are added. |
| Plan-Then-Execute | Two-stage workflow model | Separates proposed plan from actual execution | Risky automation can be reviewed before it changes anything | Makes future agentic workflows reviewable before mutation. |
| Approval gate | Human checkpoint | Requires approval before risky action | Humans remain in control of sensitive or high-impact actions | Keeps humans in control of high-impact actions. |
| Artifact | Output file/data from workflow | Stores reports, exports, or generated results | Workflow outputs remain accessible and auditable after the run | Preserves workflow outputs for review and reuse. |
| Cloud Run job | Managed background job | Runs scheduled or batch work | Long-running/background automation can run outside the interactive proxy request path | Scales background work outside interactive requests. |
| Cost cap | Spend/usage limit | Prevents runaway AI/tool cost | Automation cannot accidentally burn unlimited provider spend | Prevents runaway provider spend as automation grows. |
| Batch API | Offline/bulk AI processing | Handles lower-cost background AI work | Non-urgent AI work can be cheaper and less latency-sensitive | Moves non-urgent AI work to cheaper async processing. |

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

- Workflow plan: `docs/phases/phase_12_workflow_platform/phase_12_workflow_platform_plan.md`
- Service-principal foundation: `db/migrations/202604280004_phase_9_0sigma_d_service_principals.sql`

## 23. Deployment, Secrets, And Environments

### Plain English

An environment is a place the system runs.

Local is for development. Staging is for testing real cloud wiring before production. Production1 is protected and should only change through explicit runbooks/gates.

Secrets are sensitive values like API keys and database URLs. They should not be committed to Git or baked into the Flutter app.

### Environment And Release

Plain English purpose: Environment and release explain where the system runs and how secrets reach deployed services safely.

Restaurant analogy: Local, staging, and production are the practice kitchen, test kitchen, and live kitchen. Secrets are locked ingredients handed to the right kitchen, not printed on the public menu.

Technical purpose: environment and release define runtime operations. Environments separate development/staging/production risk, Secret Manager and env vars provide runtime configuration without committing secrets, Dockerfiles make proxy builds reproducible, CI/CD gates validate changes, runbooks standardize live operations, and managed certificates secure public ingress.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Environment | Runtime target | Separates local, staging, and production behavior | Risky changes can be tested away from production users | Creates a clear promotion path from local to staging to production. |
| Local dev | Developer machine setup | Runs app and local/test services | Engineers can build and debug without touching shared cloud systems | - |
| Staging | Pre-production cloud environment | Proves DNS, certs, Cloud Run, proxy, secrets, and smoke tests | Real infrastructure can be validated before production changes | Catches infrastructure problems before production changes. |
| Production1 | Protected production environment | Requires runbooks and gates before change | Customer-facing data and services are changed only through controlled procedures | Protects live data with gates and runbooks. |
| Secret | Sensitive configuration value | API key, database URL, or credential | These values would be dangerous if committed or exposed to clients | Keeps sensitive values out of code and client bundles. |
| Secret Manager | Google secret storage | Injects secrets into Cloud Run without Git exposure | Secrets can be rotated and managed without rewriting code or leaking values | Supports central secret rotation and injection. |
| Environment variable | Runtime config variable | Gives app/proxy configuration at startup | Builds can be reused across environments with different settings | Allows runtime changes without rebuilding containers. |
| Dockerfile | Container build recipe | Builds the proxy container image | Deployment becomes repeatable because the runtime environment is described in code | Makes proxy deploys reproducible. |
| CI/CD | Automated checks/deploy process | Runs verification and deployment steps | Releases depend less on manual memory and more on repeatable gates | Keeps release checks repeatable. |
| Runbook | Step-by-step operational procedure | Reduces risk during live maintenance | High-risk operations get a checklist, verification, and backout path | Makes high-risk live operations repeatable. |
| Managed certificate | Cloud-managed HTTPS cert | Lets HTTPS work for the hostname | Certificate renewal and attachment are handled by the cloud platform | Keeps public HTTPS stable without manual certificate renewal. |

### How It Works

Staging deploy shape:

```text
local private secrets file
  -> deploy script validates required values
  -> secrets sync to Google Secret Manager
  -> Cloud Run deploy uses secret references
  -> load balancer routes public traffic
  -> smoke test verifies /readyz
```

Production migration shape:

```text
confirm gates
  -> backup
  -> apply migrations in documented order
  -> run verification queries
  -> monitor
  -> use backout notes if needed
```

### Where It Lives

- Deploy script: `scripts/deploy_staging_proxy.ps1`
- Proxy build: `Dockerfile`
- Local Postgres scaffold: `docker-compose.dev.yml`
- Production apply runbook: `runbooks/phase_9_production1_migration_apply_runbook.md`

## 24. Testing And Gates

### Plain English

Tests are safety rails.

In this repo, tests protect more than UI. They protect auth, MFA, tenant isolation, database migration shape, proxy behavior, platform builds, and production readiness.

### Verification

Plain English purpose: Verification explains the checks that keep code, schema, auth, and deployments from drifting.

Restaurant analogy: It is the pre-service line check and health inspection. Equipment, doors, cash drawer, prep, and safety rules are checked before guests arrive.

Technical purpose: verification defines gates across layers. Static analysis catches code issues, unit/widget tests check behavior, contract/migration tests enforce architectural and schema expectations, RLS lint protects tenant isolation policy shape, smoke tests validate live wiring, CI runs checks consistently, and platform builds catch target-specific regressions.

| Technical piece | What it is | What it does | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- | --- |
| Analyzer | Static code checker | Finds Dart/Flutter issues before runtime | Many errors are caught before the app even runs | Catches drift before runtime. |
| Unit test | Small focused test | Checks one function/class behavior | Core logic can be verified quickly and precisely | Supports safe refactors of core logic. |
| Widget test | Flutter UI test | Checks UI behavior without full device run | UI behavior can be tested faster than manual clicking on devices | Catches UI behavior regressions earlier. |
| Contract test | Architecture/schema expectation test | Ensures code still obeys documented shape | Important architecture promises do not silently drift | Protects architecture promises across phases. |
| Migration test | Database-schema test | Verifies migration definitions and patterns | Schema changes can be checked before they reach live databases | Helps database schema evolve safely. |
| RLS lint | Policy safety checker | Blocks unsafe RLS policy patterns | Tenant isolation rules get automated protection | Protects tenant isolation as policies grow. |
| Smoke test | Small live check | Verifies a deployed service responds basically correctly | Deployment wiring problems are caught with a quick end-to-end probe | Catches deployment wiring problems quickly. |
| GitHub Actions | Hosted automation | Runs CI and platform verification | Checks run the same way for pushes and pull requests | Keeps checks consistent across branches and PRs. |
| Simulator build | iOS build without physical device | Proves platform compilation path | iOS build problems are caught even before real-device QA | Keeps iOS build path healthy before real-device QA. |

### How It Works

CI path:

```text
push or pull request
  -> GitHub Actions starts
  -> flutter pub get
  -> flutter analyze --fatal-infos
  -> dart run tool/rls_policy_lint.dart
  -> flutter test
```

Apple verification:

```text
macos-15 runner
  -> focused auth/MFA tests
  -> iOS simulator build for ForgeFlow
  -> iOS simulator build for Barrio
```

### Where It Lives

- Main CI: `.github/workflows/ci.yml`
- Apple verify: `.github/workflows/apple-platform-verify.yml`
- Tests: `test/`
- RLS lint: `tool/rls_policy_lint.dart`

## 25. Current Status And Known Gaps

### Plain English

The foundation is broad and much of it is now merged or scaffolded. Some database structures exist before their final UI, worker, or workflow consumer exists.

That is normal for this repo's phase style: build the foundation, verify the contracts, then attach consumer features.

### Current Status And Gaps

Plain English purpose: Current status and gaps explain what is done, what is being watched, and what still needs follow-up.

Restaurant analogy: It is the manager shift-handoff board. Completed prep is checked off, active risks are circled, and unfinished work stays visible for the next shift.

Technical purpose: current status and gaps summarize operational readiness and remaining risk. They track merged foundation work, staging ingress status, production migration state, auth/admin completion, security monitoring, known schema gaps, missing workers/routes, test coverage gaps, and health-surface requirements so future work can prioritize by dependency and risk.

| Item | What it means | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- |
| `9.0Sigma.b-k` merged | Foundation migrations/features are on master | Auth/RLS/service/audit/event/graph/rollup groundwork exists | Forms the base for later consumer phases. |
| Staging DNS/HTTPS passing | Public staging API resolves and smokes | Cloud edge path is wired | Confirms the edge pattern for future environments. |
| Secret Manager-backed env refs | Cloud Run receives secrets securely | Sensitive values are not plain deploy config | Establishes the secret-handling pattern for later services. |
| Phase 9 accepted | Live auth closeout is accepted for next-phase handoff | Cloud Armor is monitored; physical iOS QA is deferred | Allows next-phase work to proceed with known constraints. |
| Cloud Armor preview | Edge policy logs but does not block yet | Heartbeat monitors 3 clean post-tuning days before enforcement | Collects evidence before enforcement changes risk. |
| Production1 applied | Phase 9 migrations through `202604280013` are applied | Future production mutation still requires a fresh gate | Shows the migration path worked under gates; future changes still need fresh gates. |
| B17 complete | Admin role catalog CRUD is deployed and smoke-passed on staging | Unblocks operator team settings consumption | Unblocks future team/settings UX work. |
| B33 queued | `usage_logs` two-slot mirror missing | Needed for cap-vs-actual reconciliation | Needs closure before usage billing/reconciliation becomes reliable. |
| B34 queued | Audit attribution contract clarification | Needed for clear cross-table audit queries | Needs closure before audit reporting matures. |
| RLS isolation sweep missing | New tables need cross-tenant tests | Reduces tenant leak risk | Should be closed before relying more heavily on new production tables. |
| Service-principal issuer route missing | Verifier exists but issuance endpoint is queued | Needed for Phase 12 workflows | Blocks the workflow platform from issuing automation identity safely. |
| Event outbox worker missing | Table exists but consumer scaffold queued | Needed for real event fan-out | Blocks durable event fan-out and real-time consumers. |
| Health expansion needed | `/health` needs more system signals | Needed for ops console health views | Needed before the operations console can show complete platform health. |

### Where It Lives

- Current tracker: `PROJECT_TRACKER.md`
- Backlog: `docs/phases/phase_9/phase_9_execution_backlog.md`
- Production apply: `runbooks/phase_9_production1_migration_apply_runbook.md`

## 26. End-To-End Examples

### Example A: User Login

```text
user enters email/password
  -> Firebase validates credentials
  -> app receives Firebase ID token
  -> app/proxy checks required custom claims
  -> Forge Flow resolves operator/location/user context
  -> Postgres auth session ledger is written
  -> secure local session envelope is stored
  -> permissions snapshot controls app access
```

In plain English:

Firebase proves the person logged in. Forge Flow records the session and decides what business access that person has.

### Example B: Staging Health Check

```text
browser requests https://staging-api.feflow.org/readyz
  -> DNS resolves hostname to 34.54.204.29
  -> Google load balancer receives HTTPS traffic
  -> Google managed certificate handles encryption
  -> Cloud Armor evaluates edge policy
  -> serverless NEG routes to Cloud Run
  -> Dart proxy handles /readyz
  -> proxy returns {"status":"ok"}
```

In plain English:

The friendly name gets translated, Google receives the secure request, routes it to the proxy, and the proxy says it is alive.

### Example C: Advisor Answer

```text
user asks operational question
  -> classifier chooses route
  -> system retrieves docs, SQL facts, graph facts, or mixed evidence
  -> Voyage reranks evidence
  -> Claude synthesizes response
  -> app shows recommendation and context
```

In plain English:

The advisor gathers evidence first, then writes an answer from that evidence.

### Example D: Future Shared-State Update

```text
manager updates shared setting
  -> app sends request to proxy
  -> proxy verifies JWT and permissions
  -> Postgres write runs in tenant context
  -> event_outbox row is written
  -> worker publishes update
  -> other devices refresh local SQLite cache
```

In plain English:

One device changes official server state, and other devices learn their local cache needs to update.

## 27. Quick Glossary

| Term | What it means | Why it matters / benefit | How this helps long term |
| --- | --- | --- | --- |
| A record | DNS record from hostname to IPv4 address | Sends a friendly name directly to a known IP | - |
| AGE | Postgres extension for graph queries | Lets relationship questions live inside Postgres | - |
| API | Server route or interface that software calls | Gives app/backend pieces a clear contract for talking to each other | - |
| CNAME | DNS record from hostname to another hostname | Lets one service name follow another provider-owned name | - |
| Cloud Armor | Google edge security layer | Filters or observes suspicious traffic before backend code | - |
| Cloud Run | Google service that runs containers | Runs the proxy without hand-managing servers | - |
| DNS | Internet naming system | Turns human-friendly names into network destinations | - |
| Firebase Identity Platform | Hosted login/auth/MFA service | Avoids building credential and MFA systems from scratch | - |
| Hostname | Friendly service name like `staging-api.feflow.org` | Gives clients a stable name to call | - |
| JWT | Signed identity token | Lets services verify identity and claims without trusting plain text | - |
| Load balancer | Public traffic router | Provides a stable secure front door for backend services | - |
| MFA | More than one proof of identity | Reduces risk from stolen passwords | - |
| NEG | Connector from load balancer to backend | Lets the load balancer route to serverless Cloud Run | - |
| Pgvector | Postgres vector search extension | Supports AI retrieval over embeddings in the database | - |
| Proxy | Server-side API gatekeeper | Keeps secrets and privileged actions off the client | - |
| RAG | Retrieve evidence, then generate answer | Grounds AI answers in real context | - |
| RLS | Postgres row-level access control | Prevents cross-tenant row access at the database layer | - |
| Secret Manager | Cloud storage for secrets | Keeps sensitive config out of Git and app bundles | - |
| Service principal | Non-human automation identity | Lets automation act with its own audit trail | - |
| SQLite | Local embedded app database | Keeps app reads fast and offline-friendly | - |
| TOTP | Rotating authenticator-app code | Provides MFA without SMS | - |
| WebSocket | Long-lived real-time connection | Lets the server push changes to connected clients | - |

## 28. Source Documents And Code Read

This guide was synthesized from:

- `README.md`
- `PROJECT_TRACKER.md`
- `CLAUDE.md`
- `pubspec.yaml`
- `Dockerfile`
- `docker-compose.dev.yml`
- `docs/README.md`
- `docs/contracts/phase_7_55_plain_english_architecture.md`
- `docs/contracts/event_outbox_contract.md`
- `docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`
- `docs/phases/phase_8R/phase_8R_official_reservation_connector_plan.md`
- `docs/phases/phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md`
- `docs/phases/phase_9/phase_9_auth_plan.md`
- `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md`
- `docs/phases/phase_11a/phase_11a_decision_register.md`
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`
- `docs/phases/phase_12_workflow_platform/phase_12_workflow_platform_plan.md`
- `runbooks/phase_9_production1_migration_apply_runbook.md`
- `runbooks/audit_chain_verify_runbook.md`
- `runbooks/gdpr_erasure_runbook.md`
- `lib/main_forgeflow.dart`
- `lib/main_barrio.dart`
- `lib/forge_flow_bootstrap.dart`
- `lib/forge_flow_app.dart`
- `lib/state/auth_session_notifier.dart`
- `lib/services/auth/firebase_auth_runtime_bindings.dart`
- `lib/services/auth/firebase_auth_login_service.dart`
- `lib/services/mfa/proxy_mfa_operations_gateway.dart`
- `lib/infrastructure/persistence/sqlite/`
- `lib/infrastructure/persistence/postgres/`
- `tool/advisor_proxy/`
- `db/migrations/`
- `.github/workflows/ci.yml`
- `.github/workflows/apple-platform-verify.yml`
