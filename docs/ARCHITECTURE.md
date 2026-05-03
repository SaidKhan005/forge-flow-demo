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
3. One-at-a-time explanations inside each area: each term gets its own short block with what it is, what it does, an example in the app, and why it matters.
4. How it works: the flow through the system.
5. Where it lives: repo paths to inspect.

Status words used in this guide:

- Live: implemented and actively used or verified.
- Scaffolded: foundation exists, but the final consumer or workflow is not complete.
- Planned: documented in phase plans, not fully implemented.

Recommended reading flow:

1. Start with the whole-system picture and quick walkthroughs.
2. Read the product loop so the restaurant concepts make sense.
3. Read app, SQLite, proxy, DNS, auth, and Postgres as the core runtime path.
4. Read RLS, permissions, service principals, and audit as the safety path.
5. Read events, usage, advisor, graph, integrations, shared state, and workflow as the expansion path.
6. Use deployment, testing, status, glossary, and source files as reference material.

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

Think of the whole system like the operating flow of a restaurant:

- The Flutter app is the operator-facing screen, like the POS/floor-management surface staff actually use during service.
- SQLite is the local working copy, like a station's current prep sheet, floor chart, or KDS view.
- The proxy is the manager-on-duty checkpoint for protected work, like voids, comps, drawer closeout, or sensitive reports.
- Postgres is the back-office system of record for sales, labor, closeout, audit, manager-log, and multi-location data.
- Firebase is the identity check, similar to proving which employee profile is signing in before permissions are applied.
- DNS and the load balancer are the public listing and routed entry path that get requests to the right backend service.
- The advisor is the experienced GM/chef view that reviews POS, labor, reservations, prep, and manager-log evidence before recommending action.

### Core System Map

We use a core system map because Forge Flow has several major pieces, and it is easier to understand them when you can see how they fit together first.

In restaurant operations terms, this is the service map from FOH to BOH: host stand and reservations, POS order entry, KDS/prep stations, the expo at the pass, food runners, manager closeout, and back-office reporting. Each station has a job, and service works when the handoffs are clear.

Technically, the core system map defines top-level runtime boundaries and trust zones. It separates client execution, local persistence, server-side API authority, shared database authority, identity verification, public edge routing, and AI/advisor processing so each layer has a clear responsibility, deployment model, and security posture.

Key pieces, one at a time:

#### Flutter app

- **What it is:** The user-facing app code
- **What it does:** Shows screens, handles user interaction, reads local state, calls services
- **Example in the app:** Manager opens Forge Flow to check tonight's labor.
- **Why it matters:** One shared app framework can serve the operator experience across platforms without rebuilding every screen separately
- **How this helps long term:** Supports future mobile, web, and branded surfaces without creating separate UI stacks.

#### Dart

- **What it is:** The programming language
- **What it does:** Runs both the Flutter app and the Cloud Run proxy
- **Example in the app:** App code and proxy DTOs are both written in Dart.
- **Why it matters:** Sharing one language reduces context switching and lets some patterns/DTOs stay consistent across app and server code
- **How this helps long term:** Keeps app and proxy patterns closer together as shared DTOs and gateways grow.

#### SQLite

- **What it is:** A small local database inside the app/device
- **What it does:** Stores local app state, demo/replay data, cached read models, and offline-friendly data
- **Example in the app:** Shift screen reads cached local shift data.
- **Why it matters:** The app stays fast and useful even when network/server state is not immediately available
- **How this helps long term:** Leaves room for offline-first behavior and fast caches without making the client authoritative.

#### Postgres

- **What it is:** A server-side relational database
- **What it does:** Stores shared truth for auth, audit, operators, usage, advisor, graph, rollups, and future shared state
- **Example in the app:** Operator records, audit logs, and usage rows live here.
- **Why it matters:** Shared and sensitive records need one authoritative place with transactions, constraints, indexes, and security rules
- **How this helps long term:** Gives multi-device and multi-operator features one durable authority to build on.

#### Firebase Identity Platform

- **What it is:** Hosted identity service
- **What it does:** Handles login credentials, password auth, and MFA
- **Example in the app:** Sarah signs in with email, password, and MFA.
- **Why it matters:** Credential security is hard; using Firebase avoids building password/MFA infrastructure from scratch
- **How this helps long term:** Keeps future auth/MFA improvements on a dedicated identity platform instead of custom credential code.

#### Proxy

- **What it is:** Server-side API layer
- **What it does:** Verifies identity, checks permissions, protects secrets, and talks to privileged services
- **Example in the app:** App asks proxy to start a delayed MFA reset.
- **Why it matters:** The app can request protected work without holding database passwords, vendor secrets, or admin power
- **How this helps long term:** Creates one server boundary for future vendor secrets, admin actions, and workflow APIs.

#### Cloud Run

- **What it is:** Google managed container runtime
- **What it does:** Runs the Dart proxy without managing servers manually
- **Example in the app:** Staging proxy runs as `forge-flow-staging-proxy`.
- **Why it matters:** The proxy can scale and deploy as a container while Google handles much of the server operations burden
- **How this helps long term:** Lets backend services scale, split, and redeploy without managing servers directly.

#### DNS

- **What it is:** Internet naming system
- **What it does:** Turns names like `staging-api.feflow.org` into a network destination
- **Example in the app:** `staging-api.feflow.org` resolves to Google edge.
- **Why it matters:** Apps and browsers can use stable friendly names even if infrastructure changes behind them
- **How this helps long term:** Lets public endpoints move infrastructure without forcing app/client changes.

#### Load balancer

- **What it is:** Google edge traffic router
- **What it does:** Receives public web traffic and forwards it to Cloud Run
- **Example in the app:** Routes `/readyz` traffic to the proxy backend.
- **Why it matters:** Public traffic gets a stable entry point, HTTPS termination, and routing before it reaches the proxy
- **How this helps long term:** Leaves room for certificates, edge policy, and multiple backend services behind one front door.

#### Cloud Armor

- **What it is:** Google edge protection
- **What it does:** Logs or blocks suspicious traffic before it reaches the proxy
- **Example in the app:** Logs suspicious requests before the proxy sees them.
- **Why it matters:** Bad or abusive traffic can be handled at the edge before it consumes backend resources
- **How this helps long term:** Can move from preview to enforcement once clean traffic patterns are understood.

#### Advisor

- **What it is:** AI/retrieval system
- **What it does:** Answers operational questions using documents, metrics, SQL, graph data, and model providers
- **Example in the app:** Answers why labor is high using sales and schedule evidence.
- **Why it matters:** Recommendations become grounded in evidence instead of being generic chatbot output
- **How this helps long term:** Creates a path for smarter recommendations without coupling AI directly to screens.


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

## Quick Walkthroughs Before The Details

These examples show how the pieces connect before the detailed one-at-a-time explanations go deeper.

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
manager updates official schedule
  -> app sends mutation to proxy
  -> proxy verifies auth and permissions
  -> Postgres writes official change
  -> audit log records actor/action
  -> outbox event records schedule changed
  -> real-time/sync path tells other devices to refresh cache
```

In plain English:

One device changes official server state, and other devices learn their local cache needs to update.

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

We use a product truth model because restaurant data has different meanings depending on whether it is planned, live, historical, or recommended.

In restaurant operations terms, these are different operating artifacts: the forecast tells you expected covers, the prep list tells the kitchen what to prepare, the schedule says who is working, the POS/KDS shows live tickets, the 86 list says what is unavailable, and the manager log/closeout captures what actually happened.

Technically, the product truth model defines domain invariants. It keeps planned, forecasted, live, benchmarked, and closed data as separate concepts so formulas, UI state, persistence, integrations, analytics, and advisor logic do not accidentally compare or rewrite the wrong kind of truth.

Key pieces, one at a time:

#### Operational facts

- **What it is:** Raw or normalized restaurant facts
- **What it does:** Represent sales, labor, reservations, shifts, wages, plans, and outcomes
- **Example in the app:** Actual sales, labor punches, reservations, and shifts.
- **Why it matters:** The system needs real restaurant evidence before it can make useful comparisons or recommendations
- **How this helps long term:** Provides stable evidence for future integrations, audits, rollups, and advisor reasoning.

#### Canonical facts

- **What it is:** Forge Flow's standard internal version of those facts
- **What it does:** Lets all vendors and app surfaces speak one common data language
- **Example in the app:** Toast labor data normalized into Forge Flow fields.
- **Why it matters:** Vendor-specific mess stays at the boundary, so the app and advisor do not need custom logic for every provider
- **How this helps long term:** Lets new vendors be added without changing product logic everywhere.

#### Benchmark

- **What it is:** A trusted historical comparison period
- **What it does:** Says what good performance should look like
- **Example in the app:** Last 60 comparable dinner services.
- **Why it matters:** Operators need a stable standard to compare against, not a moving target invented by the live shift
- **How this helps long term:** Keeps future comparisons stable as target-setting gets more advanced.

#### TargetCycle

- **What it is:** A locked benchmark window
- **What it does:** Prevents targets from constantly changing after a plan is made
- **Example in the app:** This week locked against the chosen benchmark.
- **Why it matters:** Keeps planning fair: the standard used to make a plan is still the standard used to judge it
- **How this helps long term:** Supports fair plan-versus-result comparison across future planning phases.

#### ActiveTargetProfile

- **What it is:** The currently active target settings
- **What it does:** Gives screens and formulas the current standard to compare against
- **Example in the app:** Downtown's current labor target settings.
- **Why it matters:** UI and calculations stay aligned on one current target source
- **How this helps long term:** Lets target strategy evolve without rewriting every screen and formula.

#### DemandForecastContext

- **What it is:** Expected demand inputs
- **What it does:** Helps estimate labor and staffing needs
- **Example in the app:** Friday reservations plus expected walk-ins.
- **Why it matters:** Staffing decisions depend on expected demand, not only historical averages
- **How this helps long term:** Leaves room for richer demand inputs from POS, labor, and reservations.

#### WeeklyPlanSnapshot

- **What it is:** The locked plan for a week
- **What it does:** Preserves what the operator intended before actuals arrive
- **Example in the app:** Schedule Sarah approved on Monday.
- **Why it matters:** Actual results can be compared to the plan that existed at the time, not a rewritten plan
- **How this helps long term:** Preserves plan history for future variance, audit, and learning features.

#### Shift

- **What it is:** The live or whole-day shift view
- **What it does:** Shows what is happening now or happened in a shift
- **Example in the app:** Tonight's dinner shift at Downtown.
- **Why it matters:** Operators need a current operational picture while the day is still actionable
- **How this helps long term:** Gives live operations a stable surface as daypart and real-time data expand.

#### Variance

- **What it is:** Difference between plan and actual
- **What it does:** Explains whether the restaurant is above/below plan
- **Example in the app:** Labor is 8 hours over plan.
- **Why it matters:** Variance turns raw numbers into a clear "on track or off track" signal
- **How this helps long term:** Becomes the bridge for future coaching, alerts, and planning feedback.

#### History

- **What it is:** Closed truth
- **What it does:** Stores what actually happened after the period is complete
- **Example in the app:** Last Friday's closed actuals.
- **Why it matters:** Learning and reporting need stable completed data that live edits cannot rewrite
- **How this helps long term:** Protects training and reporting data for future learning features.

#### Learn

- **What it is:** Teaching/recommendation layer
- **What it does:** Uses repeated closed evidence to explain patterns and recommend action
- **Example in the app:** Repeated overstaffed lunches become coaching guidance.
- **Why it matters:** The system can improve guidance by learning from patterns that actually repeated
- **How this helps long term:** Provides the future path for coaching based on repeated closed evidence.


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

We organize the repository by responsibility because UI code, database code, cloud code, tests, and planning docs all need clear homes.

In restaurant operations terms, this is station organization and mise en place. Prep lists, recipe cards, vendor invoices, temp logs, cash closeout paperwork, and POS configuration do not all live in the same binder because different people use them for different jobs.

Technically, the repository layout documents separation of concerns. Each folder represents an ownership boundary: presentation, domain logic, runtime services, state management, local persistence, server persistence, proxy/API code, schema migration, tests, architecture docs, and operational procedures.

Key pieces, one at a time:

#### `lib/`

- **What it is:** Main Flutter/Dart app code
- **What it does:** Contains UI, state, services, domain logic, persistence wrappers
- **Example in the app:** Main app screens and services live here.
- **Why it matters:** Keeps the user-facing product code in one main tree

#### `lib/domain/`

- **What it is:** Pure domain logic
- **What it does:** Holds formulas and interfaces that should not directly do I/O
- **Example in the app:** Labor variance formula lives here.
- **Why it matters:** Business rules stay testable and are not tangled with databases or APIs
- **How this helps long term:** Keeps formulas portable into future services, tests, and advisor tooling.

#### `lib/services/`

- **What it is:** Runtime services
- **What it does:** Coordinates auth, providers, gateways, app operations
- **Example in the app:** Auth gateway coordinates sign-in work.
- **Why it matters:** Orchestration sits between raw UI and low-level infrastructure
- **How this helps long term:** Keeps orchestration replaceable as providers, gateways, and proxy features change.

#### `lib/state/`

- **What it is:** App state objects
- **What it does:** Holds screen/application state through notifiers/read models
- **Example in the app:** Shift dashboard notifier stores current screen state.
- **Why it matters:** UI can react to clean state changes instead of calculating everything itself
- **How this helps long term:** Lets UI surfaces grow without duplicating state logic.

#### `lib/infrastructure/persistence/sqlite/`

- **What it is:** Local database layer
- **What it does:** Defines SQLite schema, migrations, and local data access
- **Example in the app:** Local shift cache tables live here.
- **Why it matters:** Local storage behavior stays centralized and easier to migrate
- **How this helps long term:** Keeps local schema/cache changes isolated as offline behavior expands.

#### `lib/infrastructure/persistence/postgres/`

- **What it is:** Server database access layer
- **What it does:** Defines safe Postgres execution and tenant-scoped repository patterns
- **Example in the app:** Tenant-safe Postgres repositories live here.
- **Why it matters:** Server data access can enforce tenant and transaction rules consistently
- **How this helps long term:** Keeps tenant-safe data access reusable as server tables grow.

#### `tool/advisor_proxy/`

- **What it is:** Dart proxy server
- **What it does:** Runs the server-side API used by the app and staging edge
- **Example in the app:** The Dart proxy route for `/readyz` lives here.
- **Why it matters:** Privileged backend behavior is separated from Flutter client code
- **How this helps long term:** Keeps backend APIs independently deployable from app UI releases.

#### `db/migrations/`

- **What it is:** Postgres schema history
- **What it does:** Creates/updates tables, indexes, policies, functions, and extensions
- **Example in the app:** `auth_sessions` table migration lives here.
- **Why it matters:** Database changes become reviewable, repeatable, and auditable
- **How this helps long term:** Provides a durable history of schema evolution for staging and production applies.

#### `test/`

- **What it is:** Automated tests
- **What it does:** Verifies app behavior, proxy behavior, auth, migrations, RLS, contracts
- **Example in the app:** MFA enrollment, reset, and route tests live here.
- **Why it matters:** Safety-critical behavior gets checked before changes ship
- **How this helps long term:** Gives future refactors a safety net.

#### `docs/contracts/`

- **What it is:** Durable architecture rules
- **What it does:** Holds rules future work must obey
- **Example in the app:** RLS and auth rules live here.
- **Why it matters:** Long-lived decisions have a stable home outside temporary phase notes
- **How this helps long term:** Prevents future phases from re-litigating stable architecture decisions.

#### `docs/phases/`

- **What it is:** Phase plans
- **What it does:** Holds active implementation plans and audits
- **Example in the app:** Phase 9 auth plan lives here.
- **Why it matters:** Work in progress stays organized by roadmap slice

#### `runbooks/`

- **What it is:** Operational procedures
- **What it does:** Explains how to do live maintenance safely
- **Example in the app:** Production migration apply steps live here.
- **Why it matters:** Live operations can be repeated with less guesswork and less risk
- **How this helps long term:** Makes live operations repeatable as production risk grows.

#### `.github/workflows/`

- **What it is:** GitHub Actions automation
- **What it does:** Runs CI and platform verification
- **Example in the app:** Apple platform verify workflow lives here.
- **Why it matters:** Important checks run consistently without relying on memory
- **How this helps long term:** Keeps platform checks scalable as release gates expand.

#### `scripts/`

- **What it is:** Helper scripts
- **What it does:** Handles deployment and operations tasks
- **Example in the app:** Staging proxy deploy script lives here.
- **Why it matters:** Repeated commands become safer and less manual


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

We have an app runtime flow because the visible app needs a reliable startup path before users see protected screens.

In restaurant operations terms, this is the opening checklist: terminals and KDS screens come online, the starting cash bank is counted, staff are clocked in, sections/stations are assigned, pre-shift notes are reviewed, and service starts only after the basics are ready.

Technically, the app runtime flow defines the Flutter composition path. Entrypoints select flavor/runtime mode, bootstrap builds dependencies, providers expose services, notifiers publish state changes, the app shell owns navigation, and auth gating prevents protected UI from rendering before identity state is known.

Key pieces, one at a time:

#### Flutter

- **What it is:** UI framework
- **What it does:** Lets the app run across mobile, web, desktop, and test environments
- **Why it matters:** One UI system can support several platforms and branded builds
- **How this helps long term:** Supports future platforms without separate UI stacks.

#### Dart

- **What it is:** App language
- **What it does:** Runs Flutter code and shared logic
- **Example in the app:** App code and proxy DTOs are both written in Dart.
- **Why it matters:** The app and proxy can use a common language and similar models

#### Flavor

- **What it is:** Build variant
- **What it does:** Lets one codebase produce different branded/runtime versions
- **Example in the app:** ForgeFlow vs Barrio app branding.
- **Why it matters:** ForgeFlow and Barrio can share core logic while presenting different app identities
- **How this helps long term:** Allows customer/branded builds without code forks.

#### Entrypoint

- **What it is:** First file that starts the app
- **What it does:** Chooses flavor and runtime bindings
- **Example in the app:** `main_forgeflow.dart` starts Forge Flow.
- **Why it matters:** Startup decisions stay explicit instead of hidden throughout the app

#### `main_forgeflow.dart`

- **What it is:** ForgeFlow app entrypoint
- **What it does:** Starts the ForgeFlow flavor
- **Example in the app:** Launches the Forge Flow branded app.
- **Why it matters:** The main product has a clear launch path

#### `main_barrio.dart`

- **What it is:** Barrio app entrypoint
- **What it does:** Starts the Barrio flavor
- **Example in the app:** Launches the Barrio branded app.
- **Why it matters:** The branded demo/customer flavor can be built separately without forking the app

#### Bootstrap

- **What it is:** Startup wiring
- **What it does:** Initializes services, local state, auth session, and providers
- **Example in the app:** Loads dependencies before app screens render.
- **Why it matters:** The app starts with the same dependency and state setup every time
- **How this helps long term:** Centralizes startup so auth, storage, and runtime changes do not scatter.

#### Provider

- **What it is:** Dependency/state injection package
- **What it does:** Makes services and notifiers available to widgets
- **Example in the app:** A shift screen reads the current auth/session provider.
- **Why it matters:** Widgets can use shared services without manually passing them through every screen
- **How this helps long term:** Keeps dependency wiring manageable as services grow.

#### Notifier

- **What it is:** State object that can tell UI to rebuild
- **What it does:** Holds app state and emits changes
- **Example in the app:** Publishes updated shift state to the UI.
- **Why it matters:** Screens update when state changes without each widget polling for data
- **How this helps long term:** Keeps screen updates predictable as state surfaces expand.

#### `MaterialApp`

- **What it is:** Flutter app shell
- **What it does:** Provides routing, theme, navigator, and app-level behavior
- **Example in the app:** Owns routes, theme, and app shell.
- **Why it matters:** The app gets a standard place for navigation, theme, and global behavior

#### Auth gate

- **What it is:** Screen/router that checks sign-in state
- **What it does:** Shows login, MFA, loading, or the real app shell
- **Example in the app:** Blocks dashboard until Sarah is signed in.
- **Why it matters:** Protected screens stay behind authentication and MFA state
- **How this helps long term:** Preserves one place to enforce login/MFA before new protected screens.


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

SQLite is the app's local working copy.

It is fast. It lives with the app. It is useful for demo data, replay data, local state, cached screen data, and offline-friendly reads.

But SQLite is not the official shared record for sensitive or multi-user truth. If something must be correct across users, devices, operators, or audits, it belongs in Postgres or must eventually sync through the server path.

### Local Database Model

We use a local database model because the app needs fast nearby data for screens, demos, replay, and cache behavior.

In restaurant operations terms, SQLite is the working copy at a station: the host stand floor chart, a printed prep sheet, or the expo's current ticket view. It is close and fast for service, but the official closeout, sales, labor, and audit records still come from the system of record.

Technically, the local database model defines the embedded persistence layer. It covers local schema versioning, migrations, seed data, replay fixtures, screen-optimized read models, and cached copies of operational data while keeping shared/security-sensitive authority out of the client database.

Key pieces, one at a time:

#### SQLite

- **What it is:** Embedded local database
- **What it does:** Stores data inside the app/device without a separate server
- **Example in the app:** Shift screen reads cached local shift data.
- **Why it matters:** The app can load quickly and keep local/demo/cache data close to the UI
- **How this helps long term:** Supports richer cache/offline features without adding server round trips.

#### `sqflite`

- **What it is:** Flutter SQLite package
- **What it does:** Lets Flutter read and write SQLite on mobile
- **Example in the app:** Mobile SQLite package used by the app.
- **Why it matters:** Mobile builds get a proven database bridge instead of custom native storage code

#### `sqflite_common_ffi`

- **What it is:** Desktop/test SQLite support
- **What it does:** Lets SQLite work in desktop/test environments
- **Example in the app:** Desktop/test SQLite runtime.
- **Why it matters:** Developers and tests can exercise the same persistence ideas outside phones

#### Schema version

- **What it is:** Number for database shape
- **What it does:** Tells the app which migrations need to run
- **Example in the app:** Version 12 means migration 12 has run.
- **Why it matters:** Existing installs can upgrade safely as tables and columns evolve
- **How this helps long term:** Allows installed apps to upgrade local data safely.

#### Migration

- **What it is:** Controlled database change
- **What it does:** Adds/changes tables and columns over time
- **Example in the app:** Adds a cached shift table on app upgrade.
- **Why it matters:** Database changes happen predictably instead of breaking old local data
- **How this helps long term:** Prevents future local schema changes from breaking existing users.

#### Seed data

- **What it is:** Initial/demo records
- **What it does:** Gives the app a known starting restaurant and replay data
- **Example in the app:** Demo operator and sample shifts for local runs.
- **Why it matters:** Demo and development flows start from a repeatable baseline
- **How this helps long term:** Keeps demos and development scenarios repeatable.

#### Mock replay

- **What it is:** Simulated operational data
- **What it does:** Lets the app behave as if live data exists
- **Example in the app:** Replay a known Friday dinner scenario.
- **Why it matters:** Product surfaces can be built and tested before every vendor integration is live
- **How this helps long term:** Lets product work continue before every live integration is ready.

#### Read model

- **What it is:** Screen-friendly data shape
- **What it does:** Makes UI reads fast and simple
- **Example in the app:** Pre-shaped dashboard summary row.
- **Why it matters:** The UI can display complex information without recalculating raw facts every time
- **How this helps long term:** Keeps complex screens fast as raw data grows.

#### Cache

- **What it is:** Local copy of data
- **What it does:** Avoids re-fetching or recalculating everything
- **Example in the app:** Recently fetched location settings stored locally.
- **Why it matters:** The app feels faster and can tolerate network/server delays
- **How this helps long term:** Supports future sync/shared-state work without slowing the UI.


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

Postgres is the official shared back-office system of record.

SQLite is the local working copy. Postgres is the server-side record that must work across users, devices, operators, audits, admin actions, advisor systems, and future automation.

The app should not bypass Postgres for shared or sensitive data.

### Managed Postgres Platform

We have a managed Postgres platform because Forge Flow needs one official shared database for server-side truth, and that database needs to be hosted, backed up, and maintained reliably.

In restaurant operations terms, Postgres is the back-office system of record for things managers and accountants depend on: sales, labor, closeouts, manager logs, inventory history, permissions, audits, and multi-location reporting. Azure is the managed facility that keeps that system running instead of the restaurant maintaining the database server itself.

Technically, the managed Postgres platform defines the database runtime contract: database engine, cloud provider, region, and version. Those choices determine extension availability, latency profile, operational responsibilities, backup/maintenance expectations, and the baseline behavior migrations must target.

Key pieces, one at a time:

#### Postgres

- **What it is:** Server-side relational database
- **What it does:** Stores durable shared records and enforces relational rules
- **Example in the app:** Operator records, audit logs, and usage rows live here.
- **Why it matters:** Shared truth needs transactions, constraints, indexes, and security in one authoritative place
- **How this helps long term:** Makes shared-state, audit, and multi-operator features possible on one consistent authority.

#### Azure Database for PostgreSQL Flexible Server

- **What it is:** Managed Postgres hosted by Azure
- **What it does:** Runs Postgres without managing the database server manually
- **Example in the app:** Managed Postgres instance in Azure.
- **Why it matters:** Azure handles much of the operational burden such as hosting, backups, and managed platform behavior
- **How this helps long term:** Keeps database operations more managed as production data grows.

#### Canada Central

- **What it is:** Azure region
- **What it does:** Controls where the managed database lives geographically
- **Example in the app:** Database runs in the Canada Central region.
- **Why it matters:** Region choice affects latency, residency, and operational alignment
- **How this helps long term:** Keeps data-location, latency, and residency assumptions explicit as production usage grows.

#### PostgreSQL 16

- **What it is:** Database version
- **What it does:** Defines available database features and behavior
- **Example in the app:** Migrations target PostgreSQL 16 behavior.
- **Why it matters:** A fixed version makes extension support, syntax, and behavior predictable
- **How this helps long term:** Stabilizes extension and migration planning until an intentional database upgrade is scheduled.


### Postgres Code Locations

We separate Postgres code locations because runtime code and database schema changes are different kinds of work.

In restaurant operations terms, this is the difference between using the POS/back-office system during service and changing its configuration. A manager running a closeout is not doing the same work as someone adding a new report, permission, menu rule, or accounting export.

Technically, Postgres code locations separate application-level persistence code from schema evolution. Repository/executor code controls how runtime queries are issued, while migrations define the database objects, constraints, indexes, policies, and functions that must exist consistently across environments.

Key pieces, one at a time:

#### `lib/infrastructure/persistence/postgres/`

- **What it is:** Postgres access code
- **What it does:** Holds safe execution abstractions and repository patterns
- **Example in the app:** Tenant-safe Postgres repositories live here.
- **Why it matters:** Database access rules stay centralized instead of being reinvented across services
- **How this helps long term:** Lets new repositories follow existing safe access patterns.

#### `db/migrations/`

- **What it is:** Database schema history
- **What it does:** Creates tables, indexes, security policies, functions, and extensions
- **Example in the app:** `auth_sessions` table migration lives here.
- **Why it matters:** Schema evolution is reviewable and replayable across environments
- **How this helps long term:** Supports staged and production applies with clear order and review history.


### Postgres Abstractions

We have Postgres abstractions because application code should not talk to the database in random, one-off ways.

In restaurant operations terms, these are the standard manager procedures for back-office work. Staff do not get raw access to every report, drawer, comp, void, or safe drop; they work through controlled roles and approved steps.

Technically, Postgres abstractions are the database access layer. They standardize query execution, transaction lifecycle, connection reuse, tenant context propagation, and repository ownership so low-level driver behavior does not leak into business services or UI-facing code.

Key pieces, one at a time:

#### `PostgresExecutor`

- **What it is:** Query runner abstraction
- **What it does:** Lets repository code run SQL without caring about the concrete driver
- **Example in the app:** Repository calls `executor.execute(...)` for SQL.
- **Why it matters:** Repositories can be tested and reused without coupling to one low-level connection object
- **How this helps long term:** Allows repositories and tests to swap execution contexts.

#### `PostgresTransaction`

- **What it is:** Bundle of database work
- **What it does:** Makes several operations succeed or fail together
- **Example in the app:** Create role and audit row succeed or roll back together.
- **Why it matters:** Multi-step changes do not leave the database half-updated if one step fails
- **How this helps long term:** Keeps future multi-write operations atomic.

#### `PostgresPool`

- **What it is:** Reusable connection manager
- **What it does:** Shares database connections instead of opening a new one per query
- **Example in the app:** Proxy reuses database connections across requests.
- **Why it matters:** Connection reuse improves performance and avoids exhausting database connections
- **How this helps long term:** Helps request volume grow without connection churn.

#### `TenantContext`

- **What it is:** Current operator/location/user label
- **What it does:** Tells database work which tenant and actor it belongs to
- **Example in the app:** operator_id = Restaurant Company A; location_id = Downtown; user_id = manager Sarah.
- **Why it matters:** Every database operation can be tied to the right operator, location, and user
- **How this helps long term:** Centralizes tenant metadata for future RLS-protected tables.

#### `OperatorScopedRepository`

- **What it is:** Base class for operator-owned data access
- **What it does:** Forces repository work to run with tenant context
- **Example in the app:** Role repository always runs for one operator context.
- **Why it matters:** Operator-owned tables get a consistent tenant safety pattern
- **How this helps long term:** Makes new operator-owned tables safer by default.

#### `package:postgres`

- **What it is:** Low-level Dart Postgres driver
- **What it does:** Actually speaks to Postgres; usage is kept behind adapters
- **Example in the app:** Raw driver used only inside the adapter layer.
- **Why it matters:** Keeping the raw driver isolated prevents unsafe one-off database access patterns
- **How this helps long term:** Keeps the low-level driver replaceable and testable because callers depend on adapters.


### Postgres Extensions

We use Postgres extensions because the database needs extra abilities beyond normal tables and SQL queries.

In restaurant operations terms, these are specialized back-office modules: inventory counts, sales reports, prep station routing, manager logs, scheduled closeout work, food-safety records, and organization/location hierarchies.

Technically, Postgres extensions are database-level capabilities added beyond core SQL. They support cryptographic hashing, embedding similarity search, graph traversal, scheduled jobs, partition lifecycle management, query performance telemetry, and hierarchical organization modeling without forcing separate external systems for each capability.

Key pieces, one at a time:

#### `pgcrypto`

- **What it is:** Cryptography tools inside Postgres
- **What it does:** Creates hashes, UUID helpers, and audit hash-chain digests
- **Example in the app:** Builds audit hash-chain digests.
- **Why it matters:** Audit and security features can use database-native fingerprints instead of fragile app-only hashing
- **How this helps long term:** Supports future audit and compliance proof work.

#### `pgvector`

- **What it is:** Vector storage/search extension
- **What it does:** Lets AI embeddings be stored and searched by similarity
- **Example in the app:** Stores embeddings for advisor document search.
- **Why it matters:** Advisor retrieval can live near the operational/document data it needs
- **How this helps long term:** Supports a larger advisor corpus and semantic search surface.

#### `pg_diskann`

- **What it is:** Advanced vector index extension
- **What it does:** Supports scalable approximate vector search as data grows
- **Example in the app:** Scales vector search when embeddings grow large.
- **Why it matters:** Larger vector sets can remain searchable without every query becoming slow
- **How this helps long term:** Provides a scaling path if vector indexes outgrow simpler search.

#### `AGE`

- **What it is:** Graph extension for Postgres
- **What it does:** Lets the system query nodes and relationships
- **Example in the app:** Queries graph links between prep, line, and demand.
- **Why it matters:** Relationship-heavy advisor questions can be answered without a totally separate graph database
- **How this helps long term:** Supports future causal graph and advisor traversal features.

#### `pg_cron`

- **What it is:** Database scheduler
- **What it does:** Runs scheduled database jobs such as rollup refreshes
- **Example in the app:** Refreshes rollups on a schedule.
- **Why it matters:** Recurring database maintenance can run close to the data
- **How this helps long term:** Keeps scheduled database maintenance close to the data.

#### `pg_partman`

- **What it is:** Partition manager
- **What it does:** Helps split huge tables into smaller date/tenant chunks
- **Example in the app:** Partitions large audit or event tables.
- **Why it matters:** Large audit/event/rollup tables stay easier to query and maintain
- **How this helps long term:** Keeps high-volume audit/event/rollup tables maintainable.

#### `pg_stat_statements`

- **What it is:** Query statistics extension
- **What it does:** Shows which SQL queries are slow, frequent, or expensive
- **Example in the app:** Shows slow SQL used by dashboards.
- **Why it matters:** Performance problems can be diagnosed from real query behavior
- **How this helps long term:** Supports performance tuning as usage grows.

#### `ltree`

- **What it is:** Hierarchy path extension
- **What it does:** Stores/query organization trees like operator -> region -> location
- **Example in the app:** Stores operator -> region -> location hierarchy.
- **Why it matters:** Operator/location hierarchies can be queried cleanly without awkward string parsing
- **How this helps long term:** Supports deeper org/location hierarchy without redesigning schema.


### Important Execution Patterns

We have important execution patterns because database work must carry the right tenant, actor, transaction, and privilege context every time.

In restaurant operations terms, every sensitive action has context: which location, which drawer, which shift, which manager or employee, and whether it is normal service work, closeout, a cash drop, a comp/void, or corporate/back-office maintenance.

Technically, important execution patterns are runtime database standards. They require tenant-scoped work to run inside explicit transactions with transaction-local context, reserve privileged system execution for named maintenance paths, and isolate raw driver usage behind approved adapters to prevent context leaks and inconsistent transaction handling.

Key pieces, one at a time:

#### `runInTenantContext`

- **What it is:** Normal tenant-scoped database execution
- **What it does:** Starts a transaction and sets the current operator/location/user for that transaction
- **Example in the app:** Runs as operator_id = Restaurant Company A; location_id = Downtown; user_id = manager Sarah.
- **Why it matters:** Most app work runs as a specific tenant, so RLS and audit can protect the right rows
- **How this helps long term:** Sets the baseline for safe new tenant-scoped repositories.

#### `runAsSystem`

- **What it is:** Carefully scoped system execution
- **What it does:** Runs backend maintenance or privileged work with an explicit reason
- **Example in the app:** Nightly rollup job runs with a system reason.
- **Why it matters:** Some jobs are not tied to one user action, but they still need traceable boundaries
- **How this helps long term:** Keeps maintenance and admin jobs traceable when they must bypass normal user scope.

#### Raw-driver isolation

- **What it is:** Keeping `package:postgres` behind an adapter
- **What it does:** Prevents random files from opening direct database connections
- **Example in the app:** Repositories cannot open random direct Postgres sockets.
- **Why it matters:** Security, transactions, and testing stay consistent across repositories
- **How this helps long term:** Prevents future shortcuts from bypassing tenant context, transactions, or test seams.


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

We use tenant identity and RLS because many operators can share the same platform, but each operator's data must stay separated.

In restaurant operations terms, each operator and location has its own POS location, revenue centers, labor reports, drawers, deposits, inventory counts, and manager logs. Downtown staff should not be able to open Uptown's reports just because both locations use the same platform.

Technically, tenant identity and RLS define the multi-tenant isolation model. Tenant identifiers label ownership, transaction-local settings tell Postgres the current tenant/actor, RLS policies enforce row access at the database layer, tenant-leading indexes keep scoped access performant, and time rules preserve correct business-date reporting.

Concrete app example:

```text
Which operator is this for?  operator_id = Restaurant Company A
Which location is this for?  location_id = Downtown location
Which user is acting?       user_id = manager Sarah
```

That identity context travels with protected database work so the app, proxy, audit logs, and RLS policies are all talking about the same tenant and actor.

Key pieces, one at a time:

#### Tenant

- **What it is:** A customer/operator boundary
- **What it does:** Separates one operator's data from another's
- **Example in the app:** Restaurant Company A is separate from Restaurant Company B.
- **Why it matters:** Multi-operator SaaS only works if each customer boundary is explicit and protected
- **How this helps long term:** Scales the platform to many operators without mixing ownership boundaries.

#### `operator_id`

- **What it is:** Operator identifier
- **What it does:** Labels which operator owns a row
- **Example in the app:** operator_id = Restaurant Company A.
- **Why it matters:** Queries and policies can filter data to the correct operator
- **How this helps long term:** Becomes the backbone for future RLS, indexing, partitioning, and reporting.

#### `location_id`

- **What it is:** Restaurant/location identifier
- **What it does:** Labels which location a row belongs to
- **Example in the app:** location_id = Downtown location.
- **Why it matters:** Operators with multiple locations can scope access and reporting correctly
- **How this helps long term:** Supports multi-location reporting and scoped permissions.

#### `user_id`

- **What it is:** Acting user identifier
- **What it does:** Labels who is performing the action
- **Example in the app:** user_id = manager Sarah.
- **Why it matters:** Audit, permissions, and session behavior can tie actions to a real actor
- **How this helps long term:** Improves future audit, permissions, and per-user session controls.

#### RLS

- **What it is:** Row Level Security
- **What it does:** Lets Postgres hide rows that do not match the current context
- **Example in the app:** Sarah's query only sees Restaurant Company A rows.
- **Why it matters:** The database itself becomes a backstop against cross-tenant data leaks
- **How this helps long term:** Provides database-level protection as the query surface grows.

#### RLS policy

- **What it is:** Database rule for row access
- **What it does:** Defines who can select/insert/update/delete rows
- **Example in the app:** Only allow rows where row.operator_id matches current operator.
- **Why it matters:** Access rules are enforced even if a query forgets a filter
- **How this helps long term:** Keeps access rules enforced even when future queries change.

#### Wrapper function

- **What it is:** Approved helper used by RLS policies
- **What it does:** Avoids unsafe direct use of session settings in policies
- **Example in the app:** `app_current_operator_id()` reads current tenant safely.
- **Why it matters:** Policy logic stays consistent and lintable across many tables
- **How this helps long term:** Keeps policy logic lintable and consistent across more tables.

#### `set_config(..., true)`

- **What it is:** Transaction-local setting
- **What it does:** Sets current operator/location/user only for this transaction
- **Example in the app:** Set current operator only for this one transaction.
- **Why it matters:** Tenant context cannot accidentally leak into the next request on a reused connection
- **How this helps long term:** Prevents tenant leakage when pooled connections are reused.

#### Tenant-leading index

- **What it is:** Index beginning with tenant columns
- **What it does:** Keeps tenant-scoped queries fast and safe
- **Example in the app:** Index starts with `operator_id`, then date or id.
- **Why it matters:** The database can efficiently find one operator's rows without scanning everyone else's
- **How this helps long term:** Keeps tenant-scoped queries fast at larger row counts.

#### `TIMESTAMPTZ`

- **What it is:** Timestamp with timezone
- **What it does:** Stores absolute instants safely
- **Example in the app:** Store login at one exact instant across timezones.
- **Why it matters:** Events from different timezones can be ordered and compared correctly
- **How this helps long term:** Avoids cross-timezone ordering bugs as regions and integrations expand.

#### Business date

- **What it is:** Restaurant-local operating date
- **What it does:** Lets a late-night shift belong to the correct business day
- **Example in the app:** 1 AM close still belongs to Friday service.
- **Why it matters:** Restaurant reporting follows operating reality, not just calendar midnight
- **How this helps long term:** Preserves restaurant reporting semantics across late-night operations.


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

We use a proxy request and security layer because the app needs to ask for protected work without holding powerful secrets or direct database access.

In restaurant operations terms, the proxy is the manager-on-duty checkpoint for protected actions. A server can ring in orders, but manager-level work such as voids, comps, drawer closeout, safe drops, or sensitive reports requires the right authority.

Technically, proxy request and security define the server API boundary and trust enforcement layer. They cover route contracts, HTTP semantics, DTO boundaries, JWT verification, permission checks, fail-closed behavior, and the Cloud Run runtime that hosts privileged server operations outside the Flutter client.

Key pieces, one at a time:

#### Proxy

- **What it is:** Server-side HTTP API
- **What it does:** Protects secrets and performs privileged work
- **Example in the app:** App asks proxy to start a delayed MFA reset.
- **Why it matters:** The app can stay untrusted/thin while sensitive operations happen on the server
- **How this helps long term:** Provides the server boundary future admin, vendor, and workflow routes can reuse.

#### API route

- **What it is:** URL path handled by the proxy
- **What it does:** Defines what operation the caller is requesting
- **Example in the app:** `POST /v1/auth/mfa/factors/revoke`.
- **Why it matters:** Each capability has a clear, testable entry point
- **How this helps long term:** New capabilities can be versioned, tested, and documented cleanly.

#### HTTP method

- **What it is:** Verb like GET/POST/PATCH/DELETE
- **What it does:** Describes read, create, update, or delete style behavior
- **Example in the app:** `GET /readyz` checks health; `POST` changes state.
- **Why it matters:** The API communicates intent using standard web conventions

#### DTO

- **What it is:** Data Transfer Object
- **What it does:** Safe request/response shape crossing the API boundary
- **Example in the app:** MFA reset request body with typed fields.
- **Why it matters:** The app receives only the fields it should know about, not raw database internals
- **How this helps long term:** Lets API contracts evolve without exposing database internals.

#### JWT

- **What it is:** Signed identity token
- **What it does:** Proves who is calling and carries identity claims
- **Example in the app:** Firebase ID token sent to the proxy.
- **Why it matters:** The proxy can verify identity without trusting a plain user id from the app
- **How this helps long term:** Scales identity proof across services without passing passwords.

#### Permission guard

- **What it is:** Authorization check
- **What it does:** Blocks callers without the needed permission
- **Example in the app:** Only admins can change role definitions.
- **Why it matters:** Sensitive operations are denied before they reach data-changing code
- **How this helps long term:** Lets new protected actions reuse one authorization pattern.

#### Fail closed

- **What it is:** Deny when uncertain
- **What it does:** Prevents misconfiguration from silently allowing unsafe behavior
- **Example in the app:** Missing operator claim means deny the request.
- **Why it matters:** Broken config becomes an outage, not an accidental security bypass
- **How this helps long term:** Reduces security risk as configuration and environments multiply.

#### Dart executable

- **What it is:** Compiled server program
- **What it does:** Lets the proxy run as a Cloud Run container
- **Example in the app:** `advisor_proxy.dart` handles routes.
- **Why it matters:** The proxy can deploy as a small runnable artifact

#### Cloud Run

- **What it is:** Managed container host
- **What it does:** Runs the proxy in staging/production-style environments
- **Example in the app:** Staging proxy runs as `forge-flow-staging-proxy`.
- **Why it matters:** The backend can scale and restart without managing VM servers
- **How this helps long term:** Lets backend route surface scale and deploy independently from the app.


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
- `POST /v1/auth/mfa/recovery/challenge`
- `POST /v1/auth/mfa/recovery/request`
- `POST /v1/auth/mfa/factors/list`
- `POST /v1/auth/mfa/factors/revoke`
- `POST /v1/auth/mfa/factors/removal/cancel`
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

We use DNS and edge routing because public requests need a stable name, secure entry point, and path to the running proxy service.

In restaurant operations terms, DNS and the edge are like the public listing, reservation channel, host stand, and floor path that get a guest to the right location. The guest should not need to know where the kitchen, office, or server station physically sits behind the scenes.

Technically, DNS and edge routing define the public ingress path. DNS resolves hostnames, certificates establish HTTPS trust, the load balancer terminates and routes traffic, Cloud Armor/reCAPTCHA provide edge policy controls, the serverless NEG binds the load balancer to Cloud Run, and Cloud Run executes the proxy container.

Key pieces, one at a time:

#### Hostname

- **What it is:** Human-readable service name
- **What it does:** Gives apps/users a stable name to call
- **Example in the app:** `staging-api.feflow.org`.
- **Why it matters:** Clients can keep calling the same name even when backend wiring changes
- **How this helps long term:** Keeps client configuration stable through infrastructure changes.

#### DNS

- **What it is:** Internet naming system
- **What it does:** Translates hostnames into destinations
- **Example in the app:** `staging-api.feflow.org` resolves to Google edge.
- **Why it matters:** Humans and apps use names; networks route to destinations
- **How this helps long term:** Supports future environment/domain expansion.

#### A record

- **What it is:** DNS record from hostname to IPv4 address
- **What it does:** Points `staging-api` directly to `34.54.204.29`
- **Example in the app:** `staging-api` points to `34.54.204.29`.
- **Why it matters:** The hostname can reach Google's reserved load-balancer IP directly
- **How this helps long term:** Useful when a hostname should point directly at a reserved load-balancer IP.

#### CNAME

- **What it is:** DNS record from hostname to hostname
- **What it does:** Points one name at another service-owned name
- **Example in the app:** `api.example.com` points to provider-owned hostname.
- **Why it matters:** Useful when another provider owns the target and may change its IPs
- **How this helps long term:** Useful when a provider-managed hostname should hide changing IPs.

#### IP address

- **What it is:** Numeric network address
- **What it does:** Initial destination for internet traffic
- **Example in the app:** `34.54.204.29` is the reserved Google edge IP.
- **Why it matters:** Network routers need numeric addresses to deliver traffic

#### TLS/HTTPS certificate

- **What it is:** Proof used for secure HTTPS
- **What it does:** Lets browsers trust encrypted traffic to the hostname
- **Example in the app:** Browser trusts `https://staging-api.feflow.org`.
- **Why it matters:** Users and apps can communicate securely without certificate warnings
- **How this helps long term:** Establishes the trust foundation for future public APIs.

#### Google managed cert

- **What it is:** Certificate Google provisions/renews
- **What it does:** Handles HTTPS certificate lifecycle for the load balancer
- **Example in the app:** Google provisions the certificate after DNS is visible.
- **Why it matters:** Certificate renewal becomes cloud-managed instead of a manual chore
- **How this helps long term:** Reduces manual renewal risk as more hostnames are added.

#### Load balancer

- **What it is:** Public traffic entry point
- **What it does:** Receives requests and routes them to the backend
- **Example in the app:** Routes `/readyz` traffic to the proxy backend.
- **Why it matters:** Traffic gets one stable front door with routing, HTTPS, and edge controls
- **How this helps long term:** Allows multiple services and edge policies behind one entry point.

#### Cloud Armor

- **What it is:** Edge security policy
- **What it does:** Logs or blocks suspicious traffic before backend
- **Example in the app:** Logs suspicious requests before the proxy sees them.
- **Why it matters:** Protection happens before bad traffic reaches application code
- **How this helps long term:** Can move from monitoring to enforcement as traffic evidence improves.

#### reCAPTCHA edge path

- **What it is:** Bot/abuse protection path
- **What it does:** Helps protect public endpoints from automated abuse
- **Example in the app:** Suspicious auth traffic can be challenged at edge.
- **Why it matters:** Automated attacks can be challenged or filtered closer to the edge
- **How this helps long term:** Adds a path for abuse protection on public endpoints.

#### Serverless NEG

- **What it is:** Load balancer backend connector
- **What it does:** Connects Google load balancing to Cloud Run
- **Example in the app:** Connects load balancer to Cloud Run proxy.
- **Why it matters:** The load balancer can treat a serverless Cloud Run service as a backend
- **How this helps long term:** Keeps load-balancer-to-Cloud-Run routing standard.

#### Cloud Run service

- **What it is:** Managed running container
- **What it does:** Hosts the Dart proxy
- **Example in the app:** `forge-flow-staging-proxy` receives routed traffic.
- **Why it matters:** The proxy runs without managing machine instances directly
- **How this helps long term:** Allows backend revisions without DNS changes.


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

We use identity and sessions because logging in only proves who someone is; Forge Flow also needs to know what restaurant, location, and role they belong to.

In restaurant operations terms, Firebase is the identity check, while Forge Flow is closer to the POS employee profile: after someone is recognized, the system still needs to know whether they are a server, manager, owner, support user, and which location or revenue center they can work in.

Technically, identity and sessions define the authentication handoff between external credential authority and internal business identity. Firebase verifies credentials and issues signed tokens; custom claims and Forge Flow records map that token to tenant/user/location context; session ledgers make auth activity auditable; secure storage preserves local session state; fail-closed logic rejects incomplete identity context.

Key pieces, one at a time:

#### Firebase Identity Platform

- **What it is:** Hosted auth provider
- **What it does:** Handles credentials, sign-in, password auth, MFA identity
- **Example in the app:** Sarah signs in with email, password, and MFA.
- **Why it matters:** Credential security and MFA are delegated to a dedicated identity platform
- **How this helps long term:** Keeps credential and MFA upgrades externalized.

#### Firebase UID

- **What it is:** Firebase user identifier
- **What it does:** Stable identity from Firebase
- **Example in the app:** Firebase user id for manager Sarah.
- **Why it matters:** Forge Flow can link business user records to a durable auth identity
- **How this helps long term:** Provides a stable link between Firebase and Forge Flow user records.

#### ID token

- **What it is:** Signed JWT from Firebase
- **What it does:** Proves the user is currently authenticated
- **Example in the app:** Signed token proving Sarah is logged in now.
- **Why it matters:** The app can prove login state to the proxy without sending passwords
- **How this helps long term:** Gives future APIs a reusable proof of login state.

#### Custom claims

- **What it is:** Extra fields inside the token
- **What it does:** Carry operator/location/user/role context
- **Example in the app:** Token carries operator_id, location_id, and role version.
- **Why it matters:** The proxy can connect Firebase identity to Forge Flow tenant context
- **How this helps long term:** Carries business identity context into protected server calls.

#### Auth session

- **What it is:** Forge Flow record of a login session
- **What it does:** Makes sign-in activity auditable and revocable
- **Example in the app:** Sarah's current login session row.
- **Why it matters:** Session behavior becomes visible and controllable server-side
- **How this helps long term:** Enables revocation and audit as login flows grow.

#### Session ledger

- **What it is:** Server-side session table
- **What it does:** Records login, refresh, revoke, and session state
- **Example in the app:** Login, refresh, and revoke events for Sarah.
- **Why it matters:** Security reviews can trace session lifecycle instead of trusting device state only
- **How this helps long term:** Supports future security reviews and session management.

#### Secure storage

- **What it is:** Device-protected local storage
- **What it does:** Stores local session envelope safely
- **Example in the app:** Device stores encrypted session envelope.
- **Why it matters:** The app can persist session state without plain local files
- **How this helps long term:** Keeps device session handling safer as auth state grows.

#### Fail closed

- **What it is:** Deny when context is incomplete
- **What it does:** Prevents accidental auth bypass
- **Example in the app:** Missing operator claim means deny the request.
- **Why it matters:** Missing claims or broken setup do not accidentally unlock the app
- **How this helps long term:** Prevents missing identity context from becoming a security hole.


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

## 11. MFA And Admin Reset

### Plain English

MFA means "password plus another proof."

The launch MFA path is TOTP: the rotating six-digit codes from an authenticator app.

Recovery-code display and challenge entry are not a launch UX surface. If someone loses access to their authenticator app, the visible product path is restaurant-admin reset with the 24-hour removal delay.

### MFA Protection

We use MFA protection because a password alone is not enough for sensitive operator and admin access.

In restaurant operations terms, MFA is like requiring more than a memorized POS passcode for manager-level access. A password proves one thing; the second factor is an extra check before sensitive actions such as admin changes, recovery, or high-risk account access.

Technically, MFA protection defines the second-factor authentication and reset safety model. It covers TOTP setup/confirmation, admin reset / delayed removal, Firebase Identity Toolkit integration, audit events, and throttling controls to reduce credential-stuffing and brute-force risk. Hash-only recovery-code primitives may remain for compatibility tests, but they are not exposed in the app UX.

Key pieces, one at a time:

#### MFA

- **What it is:** Multi-factor authentication
- **What it does:** Requires another proof beyond password
- **Example in the app:** Password plus authenticator code.
- **Why it matters:** A stolen password alone is not enough to access protected accounts
- **How this helps long term:** Raises the baseline before higher-risk admin/operator workflows expand.

#### TOTP

- **What it is:** Time-based one-time password
- **What it does:** Generates rotating codes from authenticator apps
- **Example in the app:** Six-digit code from Sarah's authenticator app.
- **Why it matters:** Strong MFA works without SMS and without storing reusable codes
- **How this helps long term:** Avoids SMS dependency while supporting standard authenticator apps.

#### Admin reset

- **What it is:** Restaurant-admin reset path for lost authenticator access
- **What it does:** Lets an authorized admin start the controlled MFA removal/reset flow
- **Example in the app:** User selects Contact your admin; admin starts reset from Team.
- **Why it matters:** Users have a controlled support path without exposing backup codes that remove MFA
- **How this helps long term:** Keeps account recovery tied to ownership and audit.

#### Hash

- **What it is:** One-way fingerprint
- **What it does:** Stores proof of a sensitive value without storing the value itself
- **Example in the app:** Stored fingerprint of a recovery/help-request key.
- **Why it matters:** If the database leaks, raw recovery material is not exposed
- **How this helps long term:** Reduces blast radius if stored recovery data is exposed.

#### Attempt ledger

- **What it is:** Record of MFA/recovery attempts
- **What it does:** Supports rate limits, abuse detection, and audit
- **Example in the app:** Repeated MFA help requests for one account.
- **Why it matters:** Suspicious guessing or repeated failures can be detected and limited
- **How this helps long term:** Supports future risk scoring, throttling, and investigation.

#### Identity Toolkit

- **What it is:** Firebase admin/auth API surface
- **What it does:** Lets server-side code manage MFA operations
- **Example in the app:** Proxy asks Firebase to manage MFA state.
- **Why it matters:** The proxy can manage Firebase MFA flows without putting admin power in the app
- **How this helps long term:** Keeps MFA operations aligned with Firebase as the credential authority.

#### Rate limit

- **What it is:** Attempt throttling
- **What it does:** Prevents unlimited guessing
- **Example in the app:** Slow down repeated MFA recovery/help requests.
- **Why it matters:** Attackers cannot hammer recovery or MFA flows freely
- **How this helps long term:** Protects future public auth flows from automated guessing.


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

Admin reset / delayed removal:

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

We use authorization and admin controls because signing in should not automatically unlock every action in the system.

In restaurant operations terms, this mirrors POS permissions. A server may enter orders and close their checks, a bartender may use a bar drawer, a manager may approve voids/comps and close drawers, and an owner or corporate admin may see higher-level reports.

Technically, authorization and admin define authorization after authentication. RBAC maps users to roles and roles to permission keys, snapshots give clients a resolved permission view, admin routes mutate access through protected APIs, role audit logs preserve access-change history, and future ReBAC can add relationship-based rules without replacing the launch model.

Key pieces, one at a time:

#### RBAC

- **What it is:** Role-Based Access Control
- **What it does:** Gives users roles that expand into permissions
- **Example in the app:** Manager role grants schedule-edit permissions.
- **Why it matters:** Access can be managed by job responsibility instead of custom rules per person
- **How this helps long term:** Can grow into custom/team roles without rewriting every feature.

#### Permission key

- **What it is:** Named allowed action
- **What it does:** Represents a specific capability like viewing or editing something
- **Example in the app:** `auth.roles.update` or `schedule.view`.
- **Why it matters:** Capabilities become explicit and testable instead of hidden in UI code
- **How this helps long term:** Lets new features add precise gates.

#### Role

- **What it is:** Bundle of permissions
- **What it does:** Makes permission assignment easier
- **Example in the app:** Manager, owner, support, or staff.
- **Why it matters:** Common permission sets can be reused across many users
- **How this helps long term:** Simplifies access management as teams grow.

#### Role grant / user role

- **What it is:** Assignment of role to user
- **What it does:** Gives a user a role in an operator/location context
- **Example in the app:** Sarah has Manager at Downtown.
- **Why it matters:** Access can be scoped to the correct operator or location
- **How this helps long term:** Supports future location-scoped and time-scoped access.

#### Permission snapshot

- **What it is:** Current resolved permission set
- **What it does:** Tells the app what this user can do now
- **Example in the app:** App receives Sarah's allowed actions.
- **Why it matters:** The UI can render allowed actions without recalculating auth logic
- **How this helps long term:** Lets client UX adapt without reimplementing authorization logic.

#### Admin route

- **What it is:** Protected server-side management route
- **What it does:** Lets admins manage users/roles safely
- **Example in the app:** `PATCH /v1/admin/auth/roles/{id}`.
- **Why it matters:** Sensitive admin changes happen behind server-side checks and audit
- **How this helps long term:** Centralizes future user/role admin changes behind audit and permission checks.

#### Role audit log

- **What it is:** Record of role changes
- **What it does:** Preserves who changed access and when
- **Example in the app:** Records who changed Sarah's role and when.
- **Why it matters:** Access changes are traceable for security and support
- **How this helps long term:** Supports future compliance and support investigations.

#### ReBAC

- **What it is:** Relationship-Based Access Control
- **What it does:** Future model where access depends on relationships, deferred to Phase 12
- **Example in the app:** Future rule like Sarah manages locations X and Y.
- **Why it matters:** More advanced access can be added later without overcomplicating launch RBAC
- **How this helps long term:** Leaves a path for relationship-based workflow access later.


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

We use automation identity because background jobs and workflows need their own accountable identity instead of borrowing a human user's account.

In restaurant operations terms, automation should be treated like a named integration user or scheduled back-office job. A nightly sales export, payroll sync, or inventory import should not run under a real manager's personal login.

Technically, automation identity defines non-human identity. Service principals receive scoped credentials, `sp:` JWTs distinguish automation from Firebase human tokens, issuers and verifiers control token lifecycle, actor-kind fields preserve audit attribution, and workflow identities allow future automation to execute with explicit permissions and traceability.

Key pieces, one at a time:

#### Service principal

- **What it is:** Non-human identity
- **What it does:** Lets automation act with scoped permissions
- **Example in the app:** Nightly workflow identity for rollup sync.
- **Why it matters:** Workflows and jobs can act without pretending to be a human user
- **How this helps long term:** Enables future workflows without human impersonation.

#### `sp:` JWT

- **What it is:** Service-principal token pattern
- **What it does:** Distinguishes automation tokens from human Firebase tokens
- **Example in the app:** `sp:rollup-worker` token calling the proxy.
- **Why it matters:** The proxy can quickly route token handling and audit attribution by actor type
- **How this helps long term:** Keeps service tokens distinguishable from human login tokens.

#### Issuer

- **What it is:** Code that creates a signed token
- **What it does:** Gives an approved service a token
- **Example in the app:** Proxy route creates a scoped service token.
- **Why it matters:** Token creation stays controlled instead of letting arbitrary services self-authorize
- **How this helps long term:** Needed to scale service identities safely.

#### Verifier

- **What it is:** Code that validates a signed token
- **What it does:** Checks that the token is real and allowed
- **Example in the app:** Proxy checks the service token before work runs.
- **Why it matters:** The proxy can reject fake or expired automation identities
- **How this helps long term:** Lets APIs trust automation identity without trusting callers blindly.

#### Actor kind

- **What it is:** Human/service classification
- **What it does:** Keeps audit records honest about who or what acted
- **Example in the app:** Action was done by human, service, or system.
- **Why it matters:** Audit reviews can distinguish user actions from automation actions
- **How this helps long term:** Keeps future audit attribution clear as automation expands.

#### Workflow identity

- **What it is:** Identity used by automation
- **What it does:** Lets Phase 12 workflows run without impersonating humans
- **Example in the app:** Automation acts as `sp:closing-checklist`.
- **Why it matters:** Future automation can have scoped permissions, cost tracking, and audit trails
- **How this helps long term:** Forms the identity foundation for Phase 12 automation.


### How It Works

```text
workflow needs to run
  -> requests or receives service-principal JWT
  -> proxy verifies `sp:` token
  -> proxy derives service actor context
  -> action runs with scoped permissions
  -> audit log records service actor
```

Current gap:

- The verifier and issuer route are locally implemented.
- The queued Production1 migration apply must land before live Phase 12
  workflows depend on service-principal issuance.
- Phase 12 workflows still need live issuance evidence.

### Where It Lives

- Service-principal migration: `db/migrations/202604280004_phase_9_0sigma_d_service_principals.sql`
- JWT code: `tool/advisor_proxy/advisor_proxy.dart`

## 14. Audit And Compliance

### Plain English

Audit answers: "Who did what, when, and under which authority?"

For sensitive systems, ordinary logs are not enough. Forge Flow is building toward tamper-evident audit logs, where records are chained together with hashes. If someone changes old audit data, the chain no longer verifies.

This does not mean the database is impossible to alter. It means alteration becomes detectable.

### Audit Integrity

We use audit integrity because sensitive actions need a trustworthy record that can be checked later.

In restaurant operations terms, this is the manager log plus POS audit trail for sensitive events: comps, voids, no-sales, cash drops, closeout variances, incidents, and handoff notes. The point is not just to record the event, but to make later tampering visible.

Technically, audit integrity defines tamper-evident audit architecture. Durable audit rows capture actor/action context, actor-kind fields separate human/service/system actions, pgcrypto digests chain rows together, external anchors checkpoint chain state outside normal table mutation, and redaction patterns support privacy obligations without destroying audit structure.

Key pieces, one at a time:

#### Audit log

- **What it is:** Durable event record
- **What it does:** Stores who did what and when
- **Example in the app:** Record that Sarah changed a role.
- **Why it matters:** Sensitive operations need a trustworthy record for support, compliance, and investigations
- **How this helps long term:** Forms the foundation for future compliance, support, and incident review.

#### Actor

- **What it is:** Person or service that acted
- **What it does:** Identifies the source of the action
- **Example in the app:** manager Sarah or `sp:rollup-worker`.
- **Why it matters:** The system can attribute changes to the right human or automation
- **How this helps long term:** Allows future investigations to attribute changes accurately.

#### Actor kind

- **What it is:** Human/service/system label
- **What it does:** Distinguishes people from automation
- **Example in the app:** Action was done by human, service, or system.
- **Why it matters:** Auditors can tell whether a person, workflow, or system job performed the action
- **How this helps long term:** Avoids mixing human and automation responsibility in future audits.

#### Hash

- **What it is:** One-way fingerprint
- **What it does:** Produces a digest of row contents
- **Example in the app:** Audit row contents become a fingerprint.
- **Why it matters:** Changes to the original content become detectable because the fingerprint changes
- **How this helps long term:** Makes later tampering detectable.

#### Hash chain

- **What it is:** Each row points to prior hash
- **What it does:** Makes historical tampering detectable
- **Example in the app:** Each audit row fingerprints the previous row.
- **Why it matters:** A change in old audit history breaks the chain after it
- **How this helps long term:** Makes sequence integrity verifiable over time.

#### Digest

- **What it is:** Hash output
- **What it does:** The fingerprint value used in the chain
- **Example in the app:** Computed fingerprint for one audit row.
- **Why it matters:** The verifier has a compact value to compare instead of re-reading trust by eye

#### Anchor

- **What it is:** External checkpoint
- **What it does:** Stores a trusted chain checkpoint outside normal table flow
- **Example in the app:** Checkpoint saved outside the normal audit table.
- **Why it matters:** There is an independent point of comparison if database history is questioned
- **How this helps long term:** Provides an external proof point for audit review.

#### Immutable blob

- **What it is:** Storage object that should not change
- **What it does:** Preserves daily audit anchor evidence
- **Example in the app:** External audit checkpoint that should not change.
- **Why it matters:** Audit checkpoints can survive normal database edits or disputes
- **How this helps long term:** Reduces reliance on database-only audit trust.

#### Redaction

- **What it is:** Removing sensitive personal content
- **What it does:** Supports erasure while preserving audit shape
- **Example in the app:** Hide sensitive detail while keeping audit shape.
- **Why it matters:** Privacy obligations can be handled without destroying the audit trail
- **How this helps long term:** Balances privacy obligations with long-term audit retention.


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

We use event delivery because one part of the platform often needs to react after another part changes data.

In restaurant operations terms, this is POS-to-KDS ticket flow. Once a server sends an order, the right prep stations receive it, the expo/pass coordinates timing, and the ticket stays visible until the work is completed or handled.

Technically, event delivery defines reliable asynchronous delivery. The transactional outbox persists events with the source write, NOTIFY wakes workers, row-claiming with `SKIP LOCKED` enables concurrent consumers, Pub/Sub/WebSocket paths distribute updates, leases and idempotency support safe retries, and dead-letter handling isolates poisoned events.

Key pieces, one at a time:

#### Event

- **What it is:** Record that something happened
- **What it does:** Lets other systems react
- **Example in the app:** Role changed or schedule updated.
- **Why it matters:** Changes can fan out without every system being tightly coupled to the original write
- **How this helps long term:** Forms the basis for future async consumers and workflow triggers.

#### Outbox

- **What it is:** Database table of events to deliver
- **What it does:** Makes event delivery durable
- **Example in the app:** Event saved with the database write.
- **Why it matters:** If a worker or network fails, the event is still stored for retry
- **How this helps long term:** Avoids lost events when workers or networks fail.

#### `event_outbox`

- **What it is:** Forge Flow's outbox table
- **What it does:** Stores pending/delivered event records
- **Example in the app:** Table holding events waiting for delivery.
- **Why it matters:** The app has one standard backbone for future realtime and workflow triggers
- **How this helps long term:** Provides a reusable event backbone for realtime and workflows.

#### Postgres NOTIFY

- **What it is:** Lightweight database notification
- **What it does:** Wakes workers when new events exist
- **Example in the app:** Wake workers after an event is inserted.
- **Why it matters:** Workers can react quickly without constantly polling
- **How this helps long term:** Keeps worker wakeups low-latency without making NOTIFY the source of truth.

#### Pub/Sub

- **What it is:** Cloud messaging service
- **What it does:** Fan-outs events to subscribers
- **Example in the app:** Fan out server events to other services.
- **Why it matters:** Multiple downstream services can receive events without each querying Postgres directly
- **How this helps long term:** Scales fan-out to multiple downstream consumers.

#### WebSocket

- **What it is:** Long-lived app connection
- **What it does:** Pushes updates to connected clients
- **Example in the app:** Push live updates to connected app clients.
- **Why it matters:** Devices can update sooner than a periodic polling loop
- **How this helps long term:** Enables future real-time app experiences.

#### `SKIP LOCKED`

- **What it is:** SQL row-claiming pattern
- **What it does:** Lets workers claim jobs without blocking each other
- **Example in the app:** Two workers claim different unprocessed events.
- **Why it matters:** Several workers can process the queue safely in parallel
- **How this helps long term:** Allows parallel workers without double-claiming rows.

#### Lease

- **What it is:** Temporary claim on work
- **What it does:** Prevents duplicate workers from processing the same row
- **Example in the app:** Worker owns an event for a limited time.
- **Why it matters:** A failed worker does not permanently lose or lock an event
- **How this helps long term:** Lets the system recover work from failed workers.

#### Dead-letter

- **What it is:** Failed-event holding area
- **What it does:** Keeps repeatedly failing events from blocking all progress
- **Example in the app:** Bad event is parked for inspection.
- **Why it matters:** Bad payloads can be isolated while healthy events continue
- **How this helps long term:** Prevents one bad event from blocking the whole backlog.

#### Idempotency

- **What it is:** Safe repeat handling
- **What it does:** Makes retries avoid duplicate side effects
- **Example in the app:** Retrying same event does not duplicate the result.
- **Why it matters:** Retried writes/events do not accidentally create duplicate sessions, charges, or actions
- **How this helps long term:** Makes retries safe as delivery paths grow.


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

We use usage and reporting because the system needs to count consumption, compare it to limits, and summarize raw activity into useful views.

In restaurant operations terms, this is the reporting layer behind food cost, labor percentage, sales by revenue center, par versus actual inventory, and end-of-day closeout summaries. Raw tickets and punches become numbers managers can act on.

Technically, usage and reporting define metering and aggregation infrastructure. Usage logs record consumption, caps define allowed limits, reconciliation keys align actuals with caps, rollup grains precompute summaries at multiple reporting levels, aggregation state tracks freshness, and scheduled jobs maintain derived tables for dashboards and health checks.

Key pieces, one at a time:

#### Usage log

- **What it is:** Record of usage
- **What it does:** Tracks consumed units/events
- **Example in the app:** One advisor answer consumes a counted unit.
- **Why it matters:** Billing, limits, and abuse controls need a factual usage trail
- **How this helps long term:** Forms the factual basis for future billing, limits, and abuse analysis.

#### Usage cap

- **What it is:** Limit record
- **What it does:** Defines allowed usage by operator/slot/period
- **Example in the app:** Downtown can use up to N advisor calls this month.
- **Why it matters:** Operators can be kept within plan, budget, or product limits
- **How this helps long term:** Supports future plan enforcement and quota controls.

#### Two-slot key

- **What it is:** Cap identity model
- **What it does:** Separates dimensions needed for reconciliation
- **Example in the app:** Usage keyed by operator and location slot.
- **Why it matters:** Cap math can distinguish the right entity and period without ambiguous joins
- **How this helps long term:** Avoids redesigning reconciliation when cap dimensions expand.

#### Reconciliation

- **What it is:** Cap versus actual comparison
- **What it does:** Checks whether usage fits allowed limits
- **Example in the app:** Compare actual advisor calls against the cap.
- **Why it matters:** The system can catch overages, drift, or accounting mismatches
- **How this helps long term:** Keeps future usage/accounting comparisons trustworthy.

#### Rollup

- **What it is:** Precomputed summary
- **What it does:** Makes dashboards faster
- **Example in the app:** Daily labor summary for Downtown.
- **Why it matters:** Expensive calculations happen ahead of time instead of on every dashboard load
- **How this helps long term:** Keeps dashboards fast as data volume grows.

#### Grain

- **What it is:** Time bucket size
- **What it does:** Daypart, day, week, month, quarter, year
- **Example in the app:** Daily, weekly, monthly, operator, or location level.
- **Why it matters:** Different reporting views can use the right time scale
- **How this helps long term:** Supports multiple reporting views without recalculating from raw rows.

#### Aggregation state

- **What it is:** Progress tracker
- **What it does:** Remembers what rollup work is fresh or stale
- **Example in the app:** Last successful rollup refresh timestamp.
- **Why it matters:** Health checks can tell whether summaries are current
- **How this helps long term:** Enables freshness monitoring for future health surfaces.

#### `pg_cron`

- **What it is:** Database scheduler
- **What it does:** Runs recurring rollup jobs
- **Example in the app:** Refreshes rollups on a schedule.
- **Why it matters:** Summary maintenance can run automatically on a schedule
- **How this helps long term:** Automates summary maintenance as reporting grows.


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

We use advisor evidence and models because AI answers should come from real operational context, not unsupported guesses.

In restaurant operations terms, the advisor should behave like an experienced GM or chef reviewing the actual evidence: POS sales mix, labor report, reservations, 86s, prep levels, manager log notes, and station bottlenecks before making a recommendation.

Technically, advisor evidence and models define evidence-grounded AI architecture. Provider abstractions isolate external model vendors, retrieval and embeddings locate relevant context, vector and sparse search collect candidate evidence, reranking improves context quality, classifiers route work to the right tool path, synthesis produces the final answer, provenance supports reviewability, and caching/routing control latency and cost.

Key pieces, one at a time:

#### LLM

- **What it is:** Large language model
- **What it does:** Reads context and generates natural-language answers
- **Example in the app:** Claude writes an advisor explanation.
- **Why it matters:** Operators can ask questions in normal language instead of learning query tools
- **How this helps long term:** Allows a natural-language interface as operational data grows.

#### Provider

- **What it is:** Wrapper around an external AI service
- **What it does:** Lets code call Anthropic/Voyage through stable interfaces
- **Example in the app:** Claude or another model vendor behind an interface.
- **Why it matters:** The app can swap or route providers without rewriting every advisor caller
- **How this helps long term:** Makes model/vendor swaps easier.

#### RAG

- **What it is:** Retrieval-Augmented Generation
- **What it does:** Retrieves evidence before asking the model to answer
- **Example in the app:** Retrieve labor evidence, then generate an answer.
- **Why it matters:** Answers are grounded in repo/product/operator context instead of generic guesses
- **How this helps long term:** Lets answer quality improve as the evidence corpus improves.

#### Embedding

- **What it is:** Meaning represented as numbers
- **What it does:** Lets similar text be searched by similarity
- **Example in the app:** Numeric representation of an operations document.
- **Why it matters:** The system can find relevant text even when wording is not identical
- **How this helps long term:** Supports semantic search across a larger corpus.

#### Vector search

- **What it is:** Similarity search over embeddings
- **What it does:** Finds documents close to the user's question
- **Example in the app:** Find docs similar to "labor spike Friday".
- **Why it matters:** The advisor can locate useful evidence quickly across a large corpus
- **How this helps long term:** Keeps retrieval feasible as document chunks grow.

#### `pgvector`

- **What it is:** Postgres vector extension
- **What it does:** Stores/searches embeddings inside Postgres
- **Example in the app:** Stores embeddings for advisor document search.
- **Why it matters:** Retrieval can live beside permissions, tenant data, and source documents
- **How this helps long term:** Keeps advisor retrieval close to source data and permissions.

#### Reranker

- **What it is:** Model that re-sorts retrieved results
- **What it does:** Puts the most relevant evidence first
- **Example in the app:** Sort retrieved evidence by usefulness.
- **Why it matters:** The final answer gets better context and less noise
- **How this helps long term:** Improves relevance as the corpus becomes noisier and larger.

#### Classifier

- **What it is:** Model/router that chooses the path
- **What it does:** Decides SQL, retrieval, graph, or mixed route
- **Example in the app:** Route question to SQL, docs, graph, or mixed path.
- **Why it matters:** Simple questions can take cheap paths while complex questions get stronger tools
- **How this helps long term:** Routes cost and latency intelligently as advisor tools expand.

#### Synthesis

- **What it is:** Final answer generation
- **What it does:** Combines evidence into a readable response
- **Example in the app:** Final advisor answer from evidence.
- **Why it matters:** The user gets an explanation, not just raw search results

#### Tool use

- **What it is:** Model-triggered structured calls
- **What it does:** Lets advisor call SQL/retrieval/graph tools
- **Example in the app:** Advisor calls SQL or graph tool for facts.
- **Why it matters:** The advisor can fetch exact data instead of making up operational numbers
- **How this helps long term:** Allows future structured tools and workflows without free-form guessing.

#### Provenance

- **What it is:** Evidence trail
- **What it does:** Shows what sources support the answer
- **Example in the app:** Answer cites the rows/docs it used.
- **Why it matters:** Users can inspect why the recommendation was made
- **How this helps long term:** Supports trust, debugging, and review of advisor answers.

#### Prompt caching

- **What it is:** Reuse of stable prompt context
- **What it does:** Reduces cost and latency
- **Example in the app:** Reuse stable system/context prompt parts.
- **Why it matters:** Repeated advisor calls become cheaper and faster
- **How this helps long term:** Controls cost and latency at higher usage.

#### Model routing

- **What it is:** Choosing cheap/strong model per task
- **What it does:** Saves cost while keeping quality
- **Example in the app:** Use cheaper model for easy classification.
- **Why it matters:** Expensive models are reserved for tasks that actually need them
- **How this helps long term:** Controls quality/cost tradeoffs as advisor traffic grows.


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

We use graph data because some operational questions are about relationships, not just individual rows.

In restaurant operations terms, graph data maps dependencies in service: prep affects station readiness, station readiness affects ticket times, ticket times affect the pass, the pass affects runners, and runners affect table turns and guest experience.

Technically, graph data define relationship modeling. Nodes and edges represent graph entities and links, AGE/Cypher provide graph query capabilities inside Postgres, projections build graph views from canonical facts, and tripwire metrics monitor size/degree thresholds so graph traversal remains operable.

Key pieces, one at a time:

#### Graph

- **What it is:** Network of connected things
- **What it does:** Models relationships, not just rows
- **Example in the app:** Map relationships between demand, labor, and service.
- **Why it matters:** Cause/effect and dependency questions are easier to answer as relationships
- **How this helps long term:** Supports future causal and relationship-heavy advisor reasoning.

#### Node

- **What it is:** Thing in the graph
- **What it does:** Represents an entity, document, metric, workflow, or concept
- **Example in the app:** A location, shift, vendor, or metric point.
- **Why it matters:** The graph needs named objects to connect and query
- **How this helps long term:** Gives future relationships standard entities to connect.

#### Edge

- **What it is:** Relationship between nodes
- **What it does:** Represents "causes", "references", "belongs to", "depends on"
- **Example in the app:** Link from prep delay to service slowdown.
- **Why it matters:** Connections make it possible to traverse from symptom to evidence or cause
- **How this helps long term:** Allows relationship types to expand without changing the whole model.

#### AGE

- **What it is:** Postgres graph extension
- **What it does:** Lets Postgres run graph-style queries
- **Example in the app:** Queries graph links between prep, line, and demand.
- **Why it matters:** Graph data can stay in the same database platform as the rest of the system
- **How this helps long term:** Keeps graph capability inside Postgres for now.

#### Cypher

- **What it is:** Graph query language
- **What it does:** Asks relationship questions across nodes/edges
- **Example in the app:** Query graph relationships in AGE.
- **Why it matters:** Relationship questions can be expressed directly instead of with awkward joins
- **How this helps long term:** Gives future traversal queries a direct language.

#### Projection

- **What it is:** Built graph view from source facts
- **What it does:** Keeps graph query data aligned with canonical data
- **Example in the app:** Build graph nodes/edges from canonical facts.
- **Why it matters:** The graph reflects trusted source data rather than becoming a separate truth
- **How this helps long term:** Allows graph views to be rebuilt from canonical truth.

#### Tripwire metric

- **What it is:** Safety/scale threshold
- **What it does:** Warns when graph size/degree needs attention
- **Example in the app:** Alert when graph degree gets too high.
- **Why it matters:** Growth problems can be seen before graph queries become unhealthy
- **How this helps long term:** Warns before graph growth turns into operational trouble.


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

We use vendor integrations because Forge Flow needs to receive data from POS, labor, reservation, and accounting systems without letting each vendor shape the whole product.

In restaurant operations terms, POS, scheduling, reservations, inventory, and accounting systems all describe the same business differently. Integrations translate those vendor-specific exports, webhooks, and API fields into Forge Flow's standard operating data.

Technically, vendor integrations define external integration boundaries. Connectors handle vendor APIs/auth/webhooks, adapters normalize vendor payloads into canonical DTOs, secrets remain server-side, OAuth supports delegated authorization, watermarks make sync resumable, and raw imports preserve original evidence for debugging and replay.

Key pieces, one at a time:

#### Adapter

- **What it is:** Translator for a vendor system
- **What it does:** Converts vendor-specific data into Forge Flow shapes
- **Example in the app:** Convert Toast data into Forge Flow shape.
- **Why it matters:** Each vendor can differ without forcing the whole app to care
- **How this helps long term:** Lets new vendors plug in without UI rewrites.

#### Connector

- **What it is:** Integration with an external service
- **What it does:** Handles API calls, auth, sync, and vendor behavior
- **Example in the app:** Calls Toast, 7shifts, or accounting API.
- **Why it matters:** Vendor-specific networking and auth stay behind a clean boundary
- **How this helps long term:** Keeps vendor-specific networking and auth isolated.

#### Canonical DTO

- **What it is:** Standard data shape
- **What it does:** Lets the app ignore vendor-specific payload formats
- **Example in the app:** Standard `ShiftActual` object after vendor import.
- **Why it matters:** Screens and domain logic can work the same way regardless of vendor
- **How this helps long term:** Keeps the core product stable across providers.

#### Vendor secret

- **What it is:** API key/token for external service
- **What it does:** Must stay server-side, not inside Flutter
- **Example in the app:** API key kept in Secret Manager.
- **Why it matters:** Compromising a client app should not expose vendor credentials
- **How this helps long term:** Keeps integrations safer as more providers are added.

#### OAuth

- **What it is:** Standard delegated auth flow
- **What it does:** Lets customers authorize third-party integrations
- **Example in the app:** Operator authorizes a POS integration.
- **Why it matters:** Customers can connect accounts without handing Forge Flow their passwords
- **How this helps long term:** Supports customer-authorized integrations without password sharing.

#### Webhook

- **What it is:** Vendor calls Forge Flow when something changes
- **What it does:** Supports near-real-time sync from external systems
- **Example in the app:** Vendor sends Forge Flow a change event.
- **Why it matters:** The system can react sooner than scheduled polling alone
- **How this helps long term:** Enables near-real-time integration updates.

#### Sync watermark

- **What it is:** Last processed point
- **What it does:** Lets imports continue without repeating all data
- **Example in the app:** Remember last imported vendor record.
- **Why it matters:** Sync jobs can resume efficiently and avoid duplicates
- **How this helps long term:** Makes incremental sync reliable and resumable.

#### Raw import record

- **What it is:** Stored original vendor payload
- **What it does:** Supports debugging and reprocessing
- **Example in the app:** Store original vendor payload for replay.
- **Why it matters:** If mapping logic changes, the original evidence can be inspected or replayed
- **How this helps long term:** Supports debugging and replay when provider mappings change.


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

We use shared state sync because multiple devices need to agree on official server data while still keeping the app fast locally.

In restaurant operations terms, shared state is like POS/KDS order state. A prep station screen, expo screen, and server view may each show the order differently, but they should all reconcile back to the same official ticket state.

Technically, shared state sync defines the synchronization model. Postgres owns authoritative shared state, SQLite caches local read models, startup sync hydrates devices, invalidation/event bridges notify clients of changes, LWW provides a simple V1 conflict policy, and audit trails preserve mutation history.

Key pieces, one at a time:

#### Source of truth

- **What it is:** Official record
- **What it does:** Decides what is correct when copies differ
- **Example in the app:** Postgres copy wins over local cache.
- **Why it matters:** Multi-device state needs one trusted answer when local copies disagree
- **How this helps long term:** Prevents multi-device conflict from turning into competing truths.

#### Cache

- **What it is:** Local copy
- **What it does:** Makes reads fast and offline-friendly
- **Example in the app:** Recently fetched location settings stored locally.
- **Why it matters:** The app can stay responsive without waiting on the server for every screen
- **How this helps long term:** Maintains app speed as shared data grows.

#### Invalidation

- **What it is:** "Your cache is stale" signal
- **What it does:** Tells app to refresh local data
- **Example in the app:** Tell devices their cached schedule is stale.
- **Why it matters:** Devices can update only what changed instead of constantly reloading everything
- **How this helps long term:** Avoids full reloads when only some data changed.

#### Startup sync

- **What it is:** Initial data refresh on launch
- **What it does:** Hydrates local cache from server
- **Example in the app:** App downloads latest official data on open.
- **Why it matters:** A returning device can catch up before showing stale shared state
- **How this helps long term:** Lets returning devices catch up safely.

#### Event bridge

- **What it is:** Path from server events to clients
- **What it does:** Pushes changes toward connected devices
- **Example in the app:** Outbox event wakes client sync path.
- **Why it matters:** Shared changes can appear on other devices quickly
- **How this helps long term:** Provides the path for real-time shared-state updates.

#### LWW

- **What it is:** Last-write-wins conflict rule
- **What it does:** Simple conflict model where latest accepted write wins
- **Example in the app:** Latest accepted write wins in V1 conflict handling.
- **Why it matters:** V1 can handle conflicts predictably without building complex merging too early
- **How this helps long term:** Keeps V1 conflict handling simple until richer merging is justified.

#### Audit trail

- **What it is:** Record of changes
- **What it does:** Preserves who changed shared state and when
- **Example in the app:** Who changed the schedule and when.
- **Why it matters:** Shared edits remain explainable and reversible by investigation
- **How this helps long term:** Lets shared edits be investigated later.


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

We use internal operations tooling because platform staff need safe, auditable ways to manage support, health, and configuration work.

In restaurant operations terms, internal operations is the corporate/back-office console for multi-location support: store setup, menu/config checks, permissions, incident review, health monitoring, and controlled support actions.

Technically, internal operations define platform administration. A staff-only web UI calls protected admin APIs, feature flags control rollout, observability surfaces health and diagnostics, support actions are routed through auditable workflows, and browsers never receive direct database access.

Key pieces, one at a time:

#### Internal admin app

- **What it is:** Staff-only management UI
- **What it does:** Gives Forge and Flow admins controlled platform tools
- **Example in the app:** Forge staff support console.
- **Why it matters:** Platform operations can happen through governed workflows instead of ad hoc database access
- **How this helps long term:** Scales support and platform operations without direct DB access.

#### Flutter Web

- **What it is:** Flutter running in browser
- **What it does:** Lets admin console share Flutter skills/patterns
- **Example in the app:** Browser-based ops console built with Flutter.
- **Why it matters:** The team can reuse app framework knowledge for internal tooling

#### Admin API

- **What it is:** Protected proxy routes
- **What it does:** Performs admin actions server-side
- **Example in the app:** Protected route for support/admin actions.
- **Why it matters:** Admin power stays behind server-side identity, permission, and audit checks
- **How this helps long term:** Centralizes future admin authority behind server checks.

#### Feature flag

- **What it is:** Runtime on/off switch
- **What it does:** Enables controlled rollout of capabilities
- **Example in the app:** Enable new role UI for staging first.
- **Why it matters:** Features can be tested, staged, or disabled without shipping a new app build
- **How this helps long term:** Supports safer rollout and rollback.

#### Observability

- **What it is:** Health/log/metric visibility
- **What it does:** Shows whether systems are working
- **Example in the app:** Logs, health checks, and metrics.
- **Why it matters:** Operators and staff can diagnose problems before users report them
- **How this helps long term:** Improves diagnosis as services multiply.

#### Support action

- **What it is:** Admin operation for customer support
- **What it does:** Helps resolve customer issues without direct DB poking
- **Example in the app:** Support staff safely resets a stuck state.
- **Why it matters:** Support becomes safer, repeatable, and auditable
- **How this helps long term:** Makes customer support repeatable and auditable.

#### No direct DB from browser

- **What it is:** Security boundary
- **What it does:** Browser talks to proxy, not Postgres
- **Example in the app:** Ops console calls API, never Postgres directly.
- **Why it matters:** A compromised browser session cannot become raw database access
- **How this helps long term:** Keeps the admin surface safer as tooling expands.


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

We use workflow automation because repeated operational tasks should be able to run consistently, with controls around risky actions.

In restaurant operations terms, workflow automation is like an opening, prep, or closing checklist that can run routine steps consistently while still requiring manager approval for high-impact actions such as changing permissions, publishing schedules, or affecting money.

Technically, workflow automation defines controlled automation architecture. Triggers start workflows, service-principal identity authenticates them, tool registries restrict available actions, Plan-Then-Execute separates planning from mutation, approval gates protect risky operations, artifacts preserve outputs, background jobs execute long work, and cost caps/batch paths control provider spend.

Key pieces, one at a time:

#### Workflow

- **What it is:** Automated process
- **What it does:** Runs a defined sequence of steps
- **Example in the app:** Nightly closeout checklist automation.
- **Why it matters:** Repeated operational work can happen reliably without manual clicking
- **How this helps long term:** Automates repeated operations as the product matures.

#### Trigger

- **What it is:** Thing that starts a workflow
- **What it does:** Could be time, event, user action, or external signal
- **Example in the app:** Start workflow when shift closes.
- **Why it matters:** Automation can respond to schedules and real events
- **How this helps long term:** Supports scheduled and event-driven future work.

#### Tool registry

- **What it is:** List of allowed workflow actions
- **What it does:** Controls what automation can call
- **Example in the app:** Allowed tools a workflow may call.
- **Why it matters:** Workflows cannot call arbitrary dangerous operations
- **How this helps long term:** Controls automation scope as more tools are added.

#### Plan-Then-Execute

- **What it is:** Two-stage workflow model
- **What it does:** Separates proposed plan from actual execution
- **Example in the app:** Plan steps first, then run approved actions.
- **Why it matters:** Risky automation can be reviewed before it changes anything
- **How this helps long term:** Makes future agentic workflows reviewable before mutation.

#### Approval gate

- **What it is:** Human checkpoint
- **What it does:** Requires approval before risky action
- **Example in the app:** Manager approves risky schedule change.
- **Why it matters:** Humans remain in control of sensitive or high-impact actions
- **How this helps long term:** Keeps humans in control of high-impact actions.

#### Artifact

- **What it is:** Output file/data from workflow
- **What it does:** Stores reports, exports, or generated results
- **Example in the app:** Generated closeout report.
- **Why it matters:** Workflow outputs remain accessible and auditable after the run
- **How this helps long term:** Preserves workflow outputs for review and reuse.

#### Cloud Run job

- **What it is:** Managed background job
- **What it does:** Runs scheduled or batch work
- **Example in the app:** Background worker for long-running tasks.
- **Why it matters:** Long-running/background automation can run outside the interactive proxy request path
- **How this helps long term:** Scales background work outside interactive requests.

#### Cost cap

- **What it is:** Spend/usage limit
- **What it does:** Prevents runaway AI/tool cost
- **Example in the app:** Stop workflow before model spend exceeds limit.
- **Why it matters:** Automation cannot accidentally burn unlimited provider spend
- **How this helps long term:** Prevents runaway provider spend as automation grows.

#### Batch API

- **What it is:** Offline/bulk AI processing
- **What it does:** Handles lower-cost background AI work
- **Example in the app:** Run lower-priority AI work in batches.
- **Why it matters:** Non-urgent AI work can be cheaper and less latency-sensitive
- **How this helps long term:** Moves non-urgent AI work to cheaper async processing.


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

We use environment and release rules because local, staging, and production need different risk levels, configuration, and secret handling.

In restaurant operations terms, local, staging, and production are like training mode, a test store, and the live store. Staff can practice and verify setup in non-live modes, while production changes need closeout-level care and secrets must stay in controlled back-office systems.

Technically, environment and release define runtime operations. Environments separate development/staging/production risk, Secret Manager and env vars provide runtime configuration without committing secrets, Dockerfiles make proxy builds reproducible, CI/CD gates validate changes, runbooks standardize live operations, and managed certificates secure public ingress.

Key pieces, one at a time:

#### Environment

- **What it is:** Runtime target
- **What it does:** Separates local, staging, and production behavior
- **Example in the app:** Local, staging, or Production1.
- **Why it matters:** Risky changes can be tested away from production users
- **How this helps long term:** Creates a clear promotion path from local to staging to production.

#### Local dev

- **What it is:** Developer machine setup
- **What it does:** Runs app and local/test services
- **Example in the app:** Developer machine running the app/proxy.
- **Why it matters:** Engineers can build and debug without touching shared cloud systems

#### Staging

- **What it is:** Pre-production cloud environment
- **What it does:** Proves DNS, certs, Cloud Run, proxy, secrets, and smoke tests
- **Example in the app:** Test environment for live edge smoke.
- **Why it matters:** Real infrastructure can be validated before production changes
- **How this helps long term:** Catches infrastructure problems before production changes.

#### Production1

- **What it is:** Protected production environment
- **What it does:** Requires runbooks and gates before change
- **Example in the app:** Real production environment.
- **Why it matters:** Customer-facing data and services are changed only through controlled procedures
- **How this helps long term:** Protects live data with gates and runbooks.

#### Secret

- **What it is:** Sensitive configuration value
- **What it does:** API key, database URL, or credential
- **Example in the app:** Database password or Firebase API key.
- **Why it matters:** These values would be dangerous if committed or exposed to clients
- **How this helps long term:** Keeps sensitive values out of code and client bundles.

#### Secret Manager

- **What it is:** Google secret storage
- **What it does:** Injects secrets into Cloud Run without Git exposure
- **Example in the app:** Stores secrets outside Git.
- **Why it matters:** Secrets can be rotated and managed without rewriting code or leaking values
- **How this helps long term:** Supports central secret rotation and injection.

#### Environment variable

- **What it is:** Runtime config variable
- **What it does:** Gives app/proxy configuration at startup
- **Example in the app:** Runtime value injected into Cloud Run.
- **Why it matters:** Builds can be reused across environments with different settings
- **How this helps long term:** Allows runtime changes without rebuilding containers.

#### Dockerfile

- **What it is:** Container build recipe
- **What it does:** Builds the proxy container image
- **Example in the app:** Build recipe for the proxy container.
- **Why it matters:** Deployment becomes repeatable because the runtime environment is described in code
- **How this helps long term:** Makes proxy deploys reproducible.

#### CI/CD

- **What it is:** Automated checks/deploy process
- **What it does:** Runs verification and deployment steps
- **Example in the app:** GitHub Actions validates and deploys checks.
- **Why it matters:** Releases depend less on manual memory and more on repeatable gates
- **How this helps long term:** Keeps release checks repeatable.

#### Runbook

- **What it is:** Step-by-step operational procedure
- **What it does:** Reduces risk during live maintenance
- **Example in the app:** Step-by-step production apply instructions.
- **Why it matters:** High-risk operations get a checklist, verification, and backout path
- **How this helps long term:** Makes high-risk live operations repeatable.

#### Managed certificate

- **What it is:** Cloud-managed HTTPS cert
- **What it does:** Lets HTTPS work for the hostname
- **Example in the app:** Google-managed HTTPS cert for staging hostname.
- **Why it matters:** Certificate renewal and attachment are handled by the cloud platform
- **How this helps long term:** Keeps public HTTPS stable without manual certificate renewal.


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

We use verification gates because code, schema, auth rules, and deployments need repeatable checks before they are trusted.

In restaurant operations terms, verification is the pre-shift line check plus compliance discipline: stations stocked, KDS/POS working, sanitizer and temperature logs in range, cash drawer counted, and known issues surfaced before service starts.

Technically, verification defines gates across layers. Static analysis catches code issues, unit/widget tests check behavior, contract/migration tests enforce architectural and schema expectations, RLS lint protects tenant isolation policy shape, smoke tests validate live wiring, CI runs checks consistently, and platform builds catch target-specific regressions.

Key pieces, one at a time:

#### Analyzer

- **What it is:** Static code checker
- **What it does:** Finds Dart/Flutter issues before runtime
- **Example in the app:** `flutter analyze --fatal-infos`.
- **Why it matters:** Many errors are caught before the app even runs
- **How this helps long term:** Catches drift before runtime.

#### Unit test

- **What it is:** Small focused test
- **What it does:** Checks one function/class behavior
- **Example in the app:** Test labor variance calculation.
- **Why it matters:** Core logic can be verified quickly and precisely
- **How this helps long term:** Supports safe refactors of core logic.

#### Widget test

- **What it is:** Flutter UI test
- **What it does:** Checks UI behavior without full device run
- **Example in the app:** Test login form behavior.
- **Why it matters:** UI behavior can be tested faster than manual clicking on devices
- **How this helps long term:** Catches UI behavior regressions earlier.

#### Contract test

- **What it is:** Architecture/schema expectation test
- **What it does:** Ensures code still obeys documented shape
- **Example in the app:** Verify API/schema contract still matches docs.
- **Why it matters:** Important architecture promises do not silently drift
- **How this helps long term:** Protects architecture promises across phases.

#### Migration test

- **What it is:** Database-schema test
- **What it does:** Verifies migration definitions and patterns
- **Example in the app:** Check migration creates required indexes/policies.
- **Why it matters:** Schema changes can be checked before they reach live databases
- **How this helps long term:** Helps database schema evolve safely.

#### RLS lint

- **What it is:** Policy safety checker
- **What it does:** Blocks unsafe RLS policy patterns
- **Example in the app:** `dart run tool/rls_policy_lint.dart`.
- **Why it matters:** Tenant isolation rules get automated protection
- **How this helps long term:** Protects tenant isolation as policies grow.

#### Smoke test

- **What it is:** Small live check
- **What it does:** Verifies a deployed service responds basically correctly
- **Example in the app:** `GET /readyz` returns status ok.
- **Why it matters:** Deployment wiring problems are caught with a quick end-to-end probe
- **How this helps long term:** Catches deployment wiring problems quickly.

#### GitHub Actions

- **What it is:** Hosted automation
- **What it does:** Runs CI and platform verification
- **Example in the app:** CI workflow runs on GitHub.
- **Why it matters:** Checks run the same way for pushes and pull requests
- **How this helps long term:** Keeps checks consistent across branches and PRs.

#### Simulator build

- **What it is:** iOS build without physical device
- **What it does:** Proves platform compilation path
- **Example in the app:** Build iOS app on macOS runner.
- **Why it matters:** iOS build problems are caught even before real-device QA
- **How this helps long term:** Keeps iOS build path healthy before real-device QA.


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

We track current status and gaps because the architecture is partly live, partly scaffolded, and partly planned, and those states should not be confused.

In restaurant operations terms, status and gaps are the manager passdown: completed prep, 86s, equipment issues, labor concerns, cash variances, unresolved guest issues, and follow-up tasks stay visible for the next shift.

Technically, current status and gaps summarize operational readiness and remaining risk. They track merged foundation work, staging ingress status, production migration state, auth/admin completion, security monitoring, known schema gaps, missing workers/routes, test coverage gaps, and health-surface requirements so future work can prioritize by dependency and risk.

Key pieces, one at a time:

#### `9.0Sigma.b-k` merged

- **What it means:** Foundation migrations/features are on master
- **Example in the app:** Foundation auth/audit/event/graph/rollup work landed.
- **Why it matters:** Auth/RLS/service/audit/event/graph/rollup groundwork exists
- **How this helps long term:** Forms the base for later consumer phases.

#### Staging DNS/HTTPS passing

- **What it means:** Public staging API resolves and smokes
- **Example in the app:** `https://staging-api.feflow.org/readyz` works.
- **Why it matters:** Cloud edge path is wired
- **How this helps long term:** Confirms the edge pattern for future environments.

#### Secret Manager-backed env refs

- **What it means:** Cloud Run receives secrets securely
- **Example in the app:** Cloud Run reads secrets from Secret Manager refs.
- **Why it matters:** Sensitive values are not plain deploy config
- **How this helps long term:** Establishes the secret-handling pattern for later services.

#### Phase 9 accepted

- **What it means:** Live auth closeout is accepted for next-phase handoff
- **Example in the app:** Auth closeout accepted for next phase.
- **Why it matters:** Cloud Armor is monitored; physical iOS QA is deferred
- **How this helps long term:** Allows next-phase work to proceed with known constraints.

#### Cloud Armor preview

- **What it means:** Edge policy logs but does not block yet
- **Example in the app:** Edge WAF is logging before enforcement.
- **Why it matters:** Heartbeat monitors 3 clean post-tuning days before enforcement
- **How this helps long term:** Collects evidence before enforcement changes risk.

#### Production1 applied

- **What it means:** Phase 9 migrations through `202604280013` are applied
- **Example in the app:** Phase 9 migrations applied to production once gated.
- **Why it matters:** Future production mutation still requires a fresh gate
- **How this helps long term:** Shows the migration path worked under gates; future changes still need fresh gates.

#### B17 complete

- **What it means:** Admin role catalog CRUD is deployed and smoke-passed on staging
- **Example in the app:** Admin role CRUD route work is done.
- **Why it matters:** Unblocks operator team settings consumption
- **How this helps long term:** Unblocks future team/settings UX work.

#### B33 complete

- **What it means:** `usage_logs` two-slot mirror work is complete
- **Example in the app:** Usage/cap reconciliation has the two-slot writer and constraint posture.
- **Why it matters:** Supports cap-vs-actual reconciliation
- **How this helps long term:** Gives billing/reconciliation a stable base.

#### B34 complete

- **What it means:** Audit attribution contract clarification is complete
- **Example in the app:** Audit actor attribution has a documented discriminator rule.
- **Why it matters:** Supports clear cross-table audit queries
- **How this helps long term:** Keeps audit reporting semantics stable.

#### RLS isolation sweep complete

- **What it means:** New tenant-scoped tables have passive cross-tenant tests
- **Example in the app:** The staging sweep can prove Operator A cannot read Operator B when explicitly enabled.
- **Why it matters:** Reduces tenant leak risk
- **How this helps long term:** Keeps future production-table work tied to isolation evidence.

#### Service-principal issuer route local complete

- **What it means:** Issuance route/client/tests landed; live apply evidence is still pending
- **Example in the app:** `sp:` token issuance is implemented locally and waits on the queued Production1 apply batch.
- **Why it matters:** Needed for Phase 12 workflows
- **How this helps long term:** Gives the workflow platform an automation identity path once live migrations are applied.

#### Event outbox scaffold landed

- **What it means:** Phase 10a scaffold exists; Pub/Sub adapter, dead-letter handling, retention sweep, tripwires, and UX surfaces are still queued
- **Example in the app:** Durable `event_outbox` rows are the source of truth; NOTIFY only wakes consumers.
- **Why it matters:** Needed for real event fan-out
- **How this helps long term:** Keeps durable event delivery separate from transient push signals.

#### Health producers delivered

- **What it means:** B44 graph, B45 rollup, and B47 vector producers now fill the B42 health envelope in code
- **Example in the app:** `11A.6` now has a bounded observability dashboard; `11A.5` remains the health/debug surface against these producer families.
- **Why it matters:** Needed for ops console health views
- **How this helps long term:** Moves remaining work from producer wiring to health UX, live evidence, and operational recovery posture.


### Where It Lives

- Current tracker: `PROJECT_TRACKER.md`
- Backlog: `docs/phases/phase_9/phase_9_execution_backlog.md`
- Production apply: `runbooks/phase_9_production1_migration_apply_runbook.md`

## 26. Quick Glossary

Key pieces, one at a time:

#### A record

- **What it means:** DNS record from hostname to IPv4 address
- **Example in the app:** `staging-api` points to `34.54.204.29`.
- **Why it matters:** Sends a friendly name directly to a known IP

#### AGE

- **What it means:** Postgres extension for graph queries
- **Example in the app:** Queries graph links between prep, line, and demand.
- **Why it matters:** Lets relationship questions live inside Postgres

#### API

- **What it means:** Server route or interface that software calls
- **Example in the app:** `GET /readyz` or `POST /v1/auth/login`.
- **Why it matters:** Gives app/backend pieces a clear contract for talking to each other

#### CNAME

- **What it means:** DNS record from hostname to another hostname
- **Example in the app:** `api.example.com` points to provider-owned hostname.
- **Why it matters:** Lets one service name follow another provider-owned name

#### Cloud Armor

- **What it means:** Google edge security layer
- **Example in the app:** Logs suspicious requests before the proxy sees them.
- **Why it matters:** Filters or observes suspicious traffic before backend code

#### Cloud Run

- **What it means:** Google service that runs containers
- **Example in the app:** Staging proxy runs as `forge-flow-staging-proxy`.
- **Why it matters:** Runs the proxy without hand-managing servers

#### DNS

- **What it means:** Internet naming system
- **Example in the app:** `staging-api.feflow.org` resolves to Google edge.
- **Why it matters:** Turns human-friendly names into network destinations

#### Firebase Identity Platform

- **What it means:** Hosted login/auth/MFA service
- **Example in the app:** Sarah signs in with email, password, and MFA.
- **Why it matters:** Avoids building credential and MFA systems from scratch

#### Hostname

- **What it means:** Friendly service name like `staging-api.feflow.org`
- **Example in the app:** `staging-api.feflow.org`.
- **Why it matters:** Gives clients a stable name to call

#### JWT

- **What it means:** Signed identity token
- **Example in the app:** Firebase ID token sent to the proxy.
- **Why it matters:** Lets services verify identity and claims without trusting plain text

#### Load balancer

- **What it means:** Public traffic router
- **Example in the app:** Routes `/readyz` traffic to the proxy backend.
- **Why it matters:** Provides a stable secure front door for backend services

#### MFA

- **What it means:** More than one proof of identity
- **Example in the app:** Password plus authenticator code.
- **Why it matters:** Reduces risk from stolen passwords

#### NEG

- **What it means:** Connector from load balancer to backend
- **Example in the app:** Serverless NEG from load balancer to Cloud Run.
- **Why it matters:** Lets the load balancer route to serverless Cloud Run

#### Pgvector

- **What it means:** Postgres vector search extension
- **Example in the app:** Stores embeddings for advisor document search.
- **Why it matters:** Supports AI retrieval over embeddings in the database

#### Proxy

- **What it means:** Server-side API gatekeeper
- **Example in the app:** App asks proxy to start a delayed MFA reset.
- **Why it matters:** Keeps secrets and privileged actions off the client

#### RAG

- **What it means:** Retrieve evidence, then generate answer
- **Example in the app:** Retrieve labor evidence, then generate an answer.
- **Why it matters:** Grounds AI answers in real context

#### RLS

- **What it means:** Postgres row-level access control
- **Example in the app:** Sarah's query only sees Restaurant Company A rows.
- **Why it matters:** Prevents cross-tenant row access at the database layer

#### Secret Manager

- **What it means:** Cloud storage for secrets
- **Example in the app:** Stores secrets outside Git.
- **Why it matters:** Keeps sensitive config out of Git and app bundles

#### Service principal

- **What it means:** Non-human automation identity
- **Example in the app:** Nightly workflow identity for rollup sync.
- **Why it matters:** Lets automation act with its own audit trail

#### SQLite

- **What it means:** Local embedded app database
- **Example in the app:** Shift screen reads cached local shift data.
- **Why it matters:** Keeps app reads fast and offline-friendly

#### TOTP

- **What it means:** Rotating authenticator-app code
- **Example in the app:** Six-digit code from Sarah's authenticator app.
- **Why it matters:** Provides MFA without SMS

#### WebSocket

- **What it means:** Long-lived real-time connection
- **Example in the app:** Push live updates to connected app clients.
- **Why it matters:** Lets the server push changes to connected clients


## 27. Source Documents And Code Read

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

Restaurant operations references used to ground the analogies:

- [Toast platform glossary](https://doc.toasttab.com/doc/platformguide/adminGlossary.html): FOH, expo, prep stations, KDS, rail, 86, cash drawer/reporting language.
- [National Restaurant Association food-safety inspection guidance](https://restaurant.org/education-and-resources/resource-library/here-is-what-health-inspectors-look-for-in-your-restaurant-and-why/): temperature logs, sanitizing, prep-surface, and inspection-readiness framing.
- [Restaurant365 Manager Log docs](https://docs.restaurant365.com/docs/smart-ops-manager-log-overview): manager logbooks, log entries, location-specific notes, and operational handoff language.
- [Eat App FOH/BOH operations guide](https://restaurant.eatapp.co/blog/restaurant-front-of-house-management): FOH/BOH, pre-shift briefing, debriefing, role assignment, host/table management, and expo/window coordination.
- [Restaurant Association inventory management guide](https://restaurantassociation.com/posts/restaurant-inventory-management-best-practices/): par levels, inventory counts, standardized item lists, storage locations, recipe/portion control, and ordering rules.
