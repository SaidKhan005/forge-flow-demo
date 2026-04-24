# Phase 9 Auth Plan

Updated: 2026-04-23
Owner: Codex planning / tracker truth
Purpose: define the final auth, role, permission, and persistent-session architecture for Forge & Flow and Barrio before Phase 9 implementation begins.

Last review: 2026-04-23 - Backend stack pivoted from Firebase/Firestore to Firebase Auth + Supabase Postgres + Cloud Run. Firebase Auth retained as the identity layer (mature Flutter SDK, officially supported OIDC integration with Supabase). Supabase Postgres becomes the data layer for profiles, roles, permissions, and all application state. Phase 9.5 (El Podio Learning Identity) remains extracted at `docs/phases/phase_9_5/phase_9_5_el_podio_learning_identity_plan.md`.

## Decisions Locked (2026-04-23 review)

- **Backend stack: hybrid Firebase Auth + Supabase Postgres + Cloud Run.**
  - Firebase Auth owns identity, email/password login, password reset, and
    session persistence. Kept for its mature Flutter SDK and robust OAuth
    provider list.
  - Supabase Postgres owns the canonical data layer: profiles, roles,
    permissions, restaurant settings, methodology corpus (via Apache AGE),
    vector embeddings (via pgvector), analytics, audit trail, leaderboards.
  - Integration: Supabase verifies Firebase-issued JWTs natively via OIDC
    third-party auth (officially supported since 2025). No JWT translation
    layer. Firebase JWT identity (`sub` / `uid`) plus minimal restaurant-
    scoping claims map to Postgres RLS policies.
  - Cloud Run hosts Phase 11a MCP server + Phase 11b agent runtime.
  - Cloud Functions (or Supabase Edge Functions) host auth admin ops that
    bypass user-scoped access via Supabase service role.

- **Project structure for V1: one Firebase Auth project + one Supabase
  project, both single-instance.** Both Forge & Flow and Barrio share the
  same Firebase Auth project and the same Supabase Postgres project.
  Simpler infra, unified auth, one billing account per vendor.
  Local dev uses the Supabase local stack (Docker) and the Firebase Auth
  emulator so dev work does not touch real data.

- **Plan to migrate to environment-separated projects (dev / staging /
  prod) when any of these triggers hits. This is a deferred complexity,
  not an oversight:**
  - A second engineer joins the codebase (lose ability to coordinate
    "don't touch prod right now" manually)
  - Second operator onboards as a paying customer (risk tolerance for
    "oops" drops sharply when real customer data is in the project)
  - Automated tests start writing to production Postgres or production
    Firebase Auth (not just the local emulator stacks)
  - Schema migrations get complex enough that rehearsing them on a
    staging project is worth the ops overhead (likely triggered by
    Phase 11a knowledge-graph schema evolution or large Vanessa SOP
    ingestion restructures)

  Migration path when triggered: stand up `forge-flow-staging`
  alongside `forge-flow-prod` for both vendors, use `pg_dump` /
  Supabase backup-restore for content seed, use Firebase Auth user
  export / import for identity seed, update build flavors to env-aware
  config files.

- **Single Postgres instance implies same infra footprint for:**
  - Phase 9 auth profile tables, roles, permissions
  - Phase 9.5 El Podio leaderboard tables
  - Phase 10a shared multi-device restaurant state tables
  - Phase 11a methodology corpus + operator SOP tables (with Apache AGE
    extension for graph traversal and pgvector for embeddings)
  All four live in the same Supabase Postgres under separate tables and
  schemas. Row-Level Security (RLS) policies enforce per-table +
  per-operator access based on JWT claims.

- **Admin backend path: mixed.** Cloud Functions (or Supabase Edge
  Functions) for auth admin operations (user creation with roles,
  custom claims, role management, admin-only ops that bypass
  user-scoped RLS). Phase 11a MCP server + Phase 11b agent runtime live
  on a dedicated backend (Cloud Run), not Cloud Functions. Reason:
  Cloud Functions timeouts, cold starts, and statelessness constraints
  do not fit MCP tool-serving or an agent reasoning loop. Phase 11a owns
  the dedicated-backend decision and implementation.

  - Phase 9 admin-ops scope (Cloud Functions or Edge Functions): user
    provisioning via Firebase Admin SDK, role + permission management
    in Postgres via Supabase service-role, audit-style admin writes.
  - Phase 11a/b dedicated backend scope: MCP server, graph retrieval,
    agent runtime, ingestion pipeline runners, all reading Postgres via
    Supabase service-role where RLS must be bypassed.
  - Both backends authenticate clients against the same Firebase Auth;
    both read/write the same Supabase Postgres (with their respective
    RLS policies or service-role bypass).

## Final Decisions Locked

These decisions are now the planning baseline.

- Use one auth style across both products.
- Use email/password login.
- Use Firebase Auth as the credential and session authority.
- Use Supabase Postgres as the canonical user, role, and permission store.
- Keep SQLite for local app data and cache only.
- No guest mode.
- No punch-pin auth.
- No biometric unlock layer.
- Login is required in both apps.
- Login persists until the user explicitly logs out.
- Forge & Flow and Barrio use the same backend account system and the same credentials.
- Forge & Flow is the commercial app.
- Barrio is the internal app.
- Forge & Flow remains structurally independent of Barrio.
- Barrio continues consuming the shared Forge & Flow runtime.
- Permission design starts from the Forge & Flow baseline and Barrio adds internal permissions on top of that same shared account system.
- Seeded roles ship with recommended default permissions already checked.
- Seeded roles remain editable.
- Admins may create custom roles.
- Permission keys remain fixed and app-defined.
- Admins may grant and remove existing permission keys from roles.
- Admins may not invent new permission key types in runtime data.
- El Podio learning identity belongs in a separate Phase 9.5 block.
- El Podio operations ranking remains later work that depends on Phase 8 attribution.

## Verified Current Architecture

These observations were checked in the current repo before writing this plan.

- `lib/main_forgeflow.dart` launches the standalone Forge & Flow app.
- `lib/main_barrio.dart` launches the standalone Barrio app.
- `lib/forge_flow_bootstrap.dart` already provides a shared bootstrap path.
- `lib/forge_flow_app.dart` already provides the shared Forge & Flow runtime boundary.
- `lib/internal/barrio/screens/forge_and_flow_destination_screen.dart` already embeds Forge & Flow inside Barrio through `ForgeFlowScope(child: AppShell(embeddedInBarrio: true))`.
- The shared Forge & Flow runtime does not import `lib/internal/barrio/**`, which confirms the dependency is still one-way.
- `lib/internal/barrio/routes/barrio_destinations.dart` already contains destination audience intent metadata.
- `lib/internal/barrio/routes/barrio_preview_role.dart` already contains a preview-only role bridge that can later be replaced by real auth role context.
- `lib/internal/barrio/content/el_podio_demo_data.dart` already includes `userId` on `PodioEntry`.
- `lib/internal/barrio/screens/company_handbook_screen.dart` still uses in-memory `Set<String> _completedUnits`.
- `lib/internal/barrio/screens/interview_playbook_screen.dart` still uses in-memory `Set<String> _completedUnits`.
- `lib/internal/barrio/screens/jim_taylor_model_screen.dart` still uses in-memory `Set<String> _completedUnits`.
- `lib/internal/barrio/widgets/barrio_streak_tracker.dart` still uses global `SharedPreferences` keys that are not user-scoped.
- `lib/internal/barrio/screens/barrio_home_screen.dart` still uses preview-only role state and still launches `ElPodioScreen` directly from the home shell.
- `lib/screens/settings_screen.dart` and `lib/screens/baseline_tracker.dart` still expose actions that will need real permission enforcement in Phase 9.

The repo therefore already supports:

- one shared Forge & Flow runtime inside two branded app shells
- one future shared auth context across both apps
- one future shared role and permission model
- a clean one-way dependency where Forge & Flow can remain independently sellable and Barrio can remain the internal superset shell

## Product Boundary Rules

These rules are non-negotiable and should be treated as architecture truth.

1. Any shared Forge & Flow runtime change is visible inside Barrio because Barrio consumes the shared Forge & Flow runtime boundary.
2. Shared Forge & Flow runtime changes do not mean Barrio shell changes leak back into standalone Forge & Flow.
3. Forge & Flow must not become dependent on Barrio-specific runtime code to function.
4. Barrio may continue depending on the shared Forge & Flow runtime because that is already how the product split is structured.
5. Standalone Forge & Flow only renders Forge & Flow surfaces.
6. Standalone Barrio may render both Forge & Flow and Barrio surfaces.
7. Barrio admin is the superset role:
   - full Forge & Flow permissions
   - full Barrio permissions
   - full admin controls
8. Even if a backend account has both Forge & Flow and Barrio permissions, standalone Forge & Flow still shows only Forge & Flow.
9. Forge & Flow inside Barrio must use the same live auth/session context already active in Barrio and must not prompt for a second login.

## Backend And Storage Split

### Firebase Auth Is The Credential Authority

Use Firebase Auth for:

- email/password login
- password reset
- session persistence
- authenticated user identity (`uid`)

Why:

- this is the cleanest supported way to get proper login and password reset
- the same backend account can be used by both app flavors
- this gives a standard session lifecycle instead of inventing a local auth system

### Supabase Postgres Is The Canonical Profile / Role / Permission Store

Use Supabase Postgres for:

- restaurant records
- restaurant user profiles
- role definitions
- permission bundles per role
- product access flags
- later external identity link fields
- later shared learning leaderboard data

Why:

- roles and permissions are shared application state, not device-local state
- admins need to govern users centrally
- a real multi-user leaderboard cannot live only in local `SharedPreferences`
- Postgres RLS + the Firebase JWT integration give per-operator isolation
  enforced at the database layer, consistent across every query path

### SQLite Stays Local And Operational

Keep SQLite for:

- existing operational/cache data already used by Forge & Flow
- local canonical app-side data that already flows through repositories and notifiers
- local cache/snapshot support where useful for startup performance

Do not use SQLite as the source of truth for:

- auth
- passwords
- role definitions
- permission assignments
- restaurant user identity

## Auth + RLS Guardrails

These guardrails should be explicit in the plan.

- Use email/password auth (Firebase Auth), not username aliases layered on top of email.
- Enable standard Firebase Auth password reset flow.
- Keep the user signed in until explicit logout.
- Keep Firebase custom claims minimal (`restaurant_id` for tenant scoping, plus
  only the coarse role / scope facts Supabase RLS actually needs; never the
  full permission catalog).
- Treat Supabase Postgres as the canonical role/permission source.
- Use Postgres Row-Level Security (RLS) policies on every table to protect
  backend data instead of trusting the client.
- Configure Supabase's third-party auth integration with the Firebase
  project so Supabase validates Firebase-issued JWTs natively (no token
  translation layer).
- Test RLS policies against the local Supabase stack before production
  rollout. Include cross-operator access attempts as integration tests.
- Assign `role: 'authenticated'` as a custom claim on all Firebase users
  so Supabase's RLS policies can scope to the authenticated role.

Important platform note:

- Custom claims are useful for coarse access facts (`restaurant_id`, role
  name, tenant id), but they are not the right place for a large, changing
  permission matrix.
- Claims are server-managed and token-refresh-driven, which makes them a bad fit for highly detailed per-screen permission state.
- The detailed permission matrix lives in Postgres tables; RLS policies reference JWT claims for scoping, then the app resolves fine-grained per-surface permissions from the Postgres role/permission tables.

## Session Model

### Shared Credential System

- Forge & Flow and Barrio use the same backend credentials.
- The backend identity key is the Firebase `uid`.
- Password reset is shared because auth is shared.

### Persisted Session Behavior

- login persists until explicit logout
- no biometric layer
- no guest session
- no PIN layer

### Separate App Installs

Because Forge & Flow and Barrio are separate installed apps:

- each installed app keeps its own local persisted session state
- both installed apps still map to the same backend account system

This means:

- same credentials across both apps
- not OS-level shared native SSO between two separate installs

### Embedded Forge & Flow Inside Barrio

Because Forge & Flow inside Barrio runs inside the same runtime tree:

- it uses the same live Barrio auth context
- it must not show a second login
- it must enforce the same role and permission state already resolved by Barrio

## Core Identity Model

Phase 9 should introduce one shared identity model across both products.

### 1. Restaurant

Purpose:

- the current scope is still one restaurant/location
- keep the restaurant entity explicit so later growth does not require identity rewrites

Suggested fields:

- `restaurantId`
- `displayName`
- `status`
- `createdAt`

### 2. AuthUser

Purpose:

- Firebase Auth user
- credential authority only

Key:

- Firebase `uid`

### 3. RestaurantUser

Purpose:

- restaurant-scoped app profile tied to the auth user

Suggested fields:

- `uid`
- `restaurantId`
- `email`
- `firstName`
- `lastName`
- `displayName`
- `primaryRoleId`
- `status` (`active`, `inactive`, `suspended`)
- `createdAt`
- `updatedAt`
- `createdBy`
- `externalIdentityLinks`

### 4. RoleDefinition

Purpose:

- restaurant-scoped role model

Suggested fields:

- `roleId`
- `displayName`
- `description`
- `isSeeded`
- `isEditable`
- `permissionKeys`
- `createdAt`
- `updatedAt`

Role id guidance:

- keep role ids stable and immutable
- allow display names and permission bundles to be edited

### 5. PermissionKey

Purpose:

- fixed permission catalog defined by the app

Rules:

- permission keys are app-defined engineering artifacts
- roles may include any existing permission keys
- admins may edit which permission keys a role has
- admins may not invent new permission key names in Postgres

### 6. ExternalIdentityLink

Purpose:

- future mapping layer for Phase 8 vendor data attribution

Suggested fields:

- `laborEmail`
- `laborEmployeeId`
- `posEmployeeId`
- `vendorDisplayNameSnapshot`
- `lastLinkedAt`

Important:

- external identity links are not the auth source of truth
- this is a mapping bridge only
- later `TargetCycle` early unlock / replace actions should be permissioned
  through this same auth/role model as admin-only controls

## Postgres Schema Model

Recommended schema structure (Supabase Postgres):

- `public.restaurants` (`restaurant_id` PK, `display_name`, `status`, `created_at`)
- `public.restaurant_users` (`uid` PK from Firebase, `restaurant_id` FK, profile columns)
- `public.roles` (`role_id` PK, `restaurant_id` FK, `display_name`, `is_seeded`, `is_editable`)
- `public.role_permissions` (join table: `role_id`, `permission_key`)

Optional later tables:

- `public.learning_progress` (`uid`, `restaurant_id`, mastery/completion state)
- `public.podio_learning` (`uid`, `restaurant_id`, points/streaks)

RLS policies (applied to every table):

- `SELECT` / `UPDATE` / `DELETE` restricted to rows where `restaurant_id`
  matches the authenticated user's restaurant claim (resolved from
  Firebase JWT via the Supabase third-party auth integration)
- Admin-only tables (seeded role edits, user deactivation) require the
  authenticated user to have the appropriate role claim, resolved from
  the `restaurant_users` row keyed by `auth.uid()`

The important rule is:

- backend identity lives on the Firebase `uid`, also used as the
  `auth.uid()` value Supabase sees via the JWT integration
- restaurant-specific profile and role state live on rows keyed by
  `restaurant_id`, enforced through RLS policies on every table

## Role And Permission Model

### Seeded Roles

Base roles:

- `staff`
- `supervisor`
- `manager`
- `admin`

Rules:

- seeded roles ship with recommended default permissions already checked
- those recommended defaults should be revisited later as more features are implemented, tested, and validated through real feedback
- seeded roles are editable
- admins can create custom roles for edge cases

### Recommended Role Intent

These are planning defaults, not a frozen final permission table.

- `staff`
  - Barrio learning access only
  - no Forge & Flow operational access by default

- `supervisor`
  - selected Forge & Flow operational access
  - Barrio staff and supervisor surfaces

- `manager`
  - broad Forge & Flow operational access
  - broad Barrio internal learning/tool access

- `admin`
  - full Forge & Flow permissions
  - full Barrio permissions
  - full admin controls

### Permission Groups

Keep permissions grouped by product and capability.

#### Product Access

- `product.forgeflow.access`
- `product.barrio.access`

#### Forge & Flow Surface Access

- `forgeflow.shift.view`
- `forgeflow.variance.view`
- `forgeflow.schedule.view`
- `forgeflow.baseline.view`

#### Forge & Flow Action Access

- `forgeflow.baseline.override`
- `forgeflow.target_profile.manage`
- `forgeflow.settings.manage`
- `forgeflow.demo_data.manage`
- `forgeflow.operational_data.clear`

#### Barrio Destination Access

- `barrio.handbook.view`
- `barrio.interview_playbook.view`
- `barrio.jim_taylor.view`
- `barrio.preston_lee.view`
- `barrio.supervisor_content.view`
- `barrio.el_podio.view`

#### Admin Controls

- `admin.users.create`
- `admin.users.deactivate`
- `admin.users.reset_password`
- `admin.roles.edit_seeded`
- `admin.roles.create_custom`
- `admin.roles.assign`
- `admin.target_cycle.unlock`

These keys are examples of the right shape. The exact final key list should be frozen during implementation, not invented ad hoc inside the database.

## Admin User Management

### User Creation

The restaurant does not need public self-signup.

Phase 9 should use admin-created users only.

Flow:

1. admin creates the user record through the admin console
2. the trusted backend creates the Firebase Auth account
3. the app/restaurant delivers credentials through the approved restaurant process
4. user logs in and stays signed in until logout

### Important Backend Requirement

Firebase client apps should not directly create other users as an admin action, and Supabase client SDKs should not hold the service-role key.

If admins create users inside the app, the project needs a trusted server-side path such as:

- Cloud Functions (with Firebase Admin SDK for user creation; Supabase service-role key for inserting the matching `restaurant_users` row)
- Supabase Edge Functions (Deno-based; Firebase Admin SDK via npm package; Supabase service-role key)
- or another controlled backend admin endpoint (Cloud Run microservice, etc.)

This is a hard Phase 9 requirement. Admin-op handlers must authenticate
the calling admin (verify their Firebase JWT + check their role in
Postgres) before performing any privileged action with the Firebase
Admin SDK or Supabase service-role.

### Password Reset

Use standard reset flow.

Do not invent:

- PIN reset
- local-only credential resets
- custom credential systems

## App Behavior Rules

### Standalone Forge & Flow

- requires login
- shows Forge & Flow only
- does not show Barrio
- still reads the same backend role and permission model
- remains the foundational commercial app experience

### Standalone Barrio

- requires login
- can show both Forge & Flow and Barrio surfaces according to the shared permission model
- acts as the internal superset shell

### Forge & Flow Inside Barrio

- uses the same live auth/session context already active in Barrio
- must not prompt for a second login
- uses the same user identity and role context
- uses the same permission model

## Current Code Gaps Phase 9 Must Close

### Barrio Role Enforcement Gap

Current state:

- `BarrioPreviewRole` is still preview-only
- `barrio_home_screen.dart` still stores preview role locally in widget state

Phase 9 must:

- replace preview role with real auth role context
- make destination visibility and access enforcement use real permissions

### Barrio Learning Persistence Gap

Current state:

- all learning completion state is in-memory only
- progress is lost on app restart

Phase 9 must:

- replace local `Set<String> _completedUnits` state with user-scoped persistent data
- key that data by real authenticated `uid`

### Barrio Streak Gap

Current state:

- `BarrioStreakService` uses global `SharedPreferences` keys

Phase 9 must:

- make streaks user-scoped
- key streak data by `uid`

### El Podio Gap

Current state:

- El Podio still uses demo users and demo points

Phase 9.5 must:

- replace demo identity with real authenticated user identity
- replace demo score sources with real learning-derived score data

### Forge & Flow Permission Gap

Current state:

- manager override entry points and settings actions are not yet permission-aware

Phase 9 must:

- add permission-aware access to screens and sensitive actions
- avoid disturbing Phase 8 operational data flow

## Phase 8 Interaction

Phase 9 auth should not disrupt Phase 8 architecture.

The clean separation is:

- Phase 9 identity answers "who is the user in the app"
- Phase 8 vendor integration answers "what happened operationally"

The bridge between them is a simple mapping layer:

- app user `uid`
- optional labor identity link
- optional POS identity link

This means:

- vendor APIs do not become the auth source of truth
- auth does not reshape the canonical Phase 8 ingest path
- later operational attribution can join app users to vendor employee records through explicit mapping

## El Podio Split

El Podio is split into two different systems. The full plan lives in its
own doc:

- [phase_9_5_el_podio_learning_identity_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_9_5/phase_9_5_el_podio_learning_identity_plan.md)

Summary:

- **Phase 9.5 - Learning El Podio** owns real authenticated `userId`,
  user-scoped points / mastery / streaks, and shared-backend learning
  leaderboard. Deliberately split from Phase 9 so core auth ships without
  a parallel learning-identity rewrite.
- **Later - Operations El Podio** owns total sales / PPA / CPLH ranking;
  depends on Phase 8 vendor attribution and is explicitly out of the
  initial auth implementation.

Do not fold Phase 9.5 or Operations El Podio into Phase 9 prompts.

## Implementation Research Guardrails

The plan should follow the platform reality:

- Firebase Auth is a strong fit for email/password, reset, and persisted mobile auth sessions.
- Postgres Row-Level Security policies should be used to protect backend data instead of trusting clients.
- RLS policies should be tested against the local Supabase stack before rollout, including explicit cross-operator access attempts as integration tests.
- Firebase Admin SDK (via Cloud Functions or Supabase Edge Functions) is required for safe admin-created user flows.
- Supabase's third-party auth integration with Firebase is officially
  supported since 2025 (OIDC-based JWT validation); Supabase verifies
  Firebase JWTs natively without any translation layer.
- Keep custom claims minimal (role name, optional tenant id) and avoid
  turning them into the main permission catalog; detailed permissions
  live in Postgres role/permission tables.

## Firebase Auth + Supabase Setup Checkpoints

Phase 9 has a few places where work cannot responsibly continue without either:

- user-provided Firebase console setup for the identity layer
- user-provided Supabase project setup for the data layer
- user confirmation of backend choices
- or macOS-side Apple configuration later

Those checkpoints should be explicit in the plan.

### Project Shape

Recommended setup:

- one Firebase project for both apps (identity only — Firebase Auth enabled, Firestore NOT used)
- one Supabase project for both apps (data layer for profiles, roles, permissions, and all application state)
- same backend identity system via Firebase Auth; same Postgres data via Supabase
- separate registered app entries per native package/bundle id on the Firebase side

Why:

- same users need to work across Forge & Flow and Barrio
- same restaurant-scoped roles and permissions need to govern both products
- Forge & Flow inside Barrio must resolve against the same backend identity
- Firebase Auth for Flutter SDK polish; Supabase Postgres for analytics, graph (Phase 11a), and vectors (Phase 11a)

### Setup Prompt Guidance

At the relevant implementation prompt, Codex/Claude should stop and guide the user through exactly what must be configured in Firebase + Supabase and where the files belong in the repo.

That guidance should cover:

Firebase side:
- creating or selecting the Firebase project
- enabling Email/Password auth
- registering Android app ids:
  - `com.forgeflow.app`
  - `com.forgeflow.barrio`
- registering iOS bundle ids:
  - `com.forgeflow.app`
  - `com.forgeflow.barrio`
- downloading config files
- placing Android config files into flavor-specific locations
- planning iOS config-file wiring per scheme/configuration
- setting password reset email templates if desired

Supabase side:
- creating the Supabase project in the desired region (Canadian for NL-based data residency when available)
- enabling the `pgvector` and Apache `AGE` extensions via the SQL editor (Phase 11a needs these; enable now to avoid re-migration)
- configuring third-party auth integration with the Firebase project (OIDC Issuer Discovery; officially supported pattern)
- defining the minimal Firebase JWT claim contract Supabase RLS depends on
  (`restaurant_id`, the authenticated-role shape Supabase expects, and any
  optional coarse role/scope claim)
- deciding the trusted admin backend path:
  - Cloud Functions + Firebase Admin SDK + Supabase service-role
  - Supabase Edge Functions + Firebase Admin SDK (via npm)
  - Cloud Run microservice (if more general backend needed)
- confirming billing requirement (Firebase Blaze if Cloud Functions, Supabase Pro if graduating past the free tier)
- initial schema migration applied (`restaurants`, `restaurant_users`,
  `roles`, `role_permissions` with RLS policies)

### Expected Config File Placement

Android (Firebase Auth):

- `android/app/src/forgeflow/google-services.json`
- `android/app/src/barrio/google-services.json`

iOS (Firebase Auth):

- flavor-specific `GoogleService-Info.plist` handling will be needed for the two iOS bundle ids
- because iOS already uses separate schemes/configurations, this should be handled in the iOS-specific auth prompt
- if the user is on Windows during implementation, the plan should call out any macOS/Xcode-only verification honestly

Supabase (both flavors):

- Supabase URL and anon key committed via build-time flavor config (environment files), never hardcoded in Dart source
- service-role key never committed to client or repo; used only from Cloud Functions / Edge Functions / Cloud Run

### Prompt Behavior Rule

At the setup prompt, Codex/Claude should:

- tell the user exactly what to create in Firebase (Auth project + app registrations)
- tell the user exactly what to create in Supabase (project + extensions + third-party auth integration with Firebase)
- tell the user exactly where the resulting config files go in this repo
- tell the user what backend requirement exists for admin-created users
- stop and wait for that setup to exist before pretending the auth work is complete

## Prompt Breakdown

Phase 9 should not be treated as one prompt.

Use this breakdown.

## Phase 9 - Restaurant Auth + Login

Umbrella objective:

- one shared auth, role, and permission system across Forge & Flow and Barrio

### Prompt 9a - Identity + Data Platform Foundation

Purpose:

- lock the Firebase Auth project shape, Supabase project shape, and backend responsibilities before runtime auth code is written

#### Prompt 9a.1 - Firebase Auth Project Setup + Native App Registration

Goal:

- guide the user through Firebase Auth setup and wire the project/app registrations into the repo

In scope:

- one Firebase Auth project decision (identity only; no Firestore)
- Email/Password auth enablement
- Android app registration for:
  - `com.forgeflow.app`
  - `com.forgeflow.barrio`
- iOS app registration for:
  - `com.forgeflow.app`
  - `com.forgeflow.barrio`
- Android config file placement (`google-services.json` per flavor)
- iOS config-file wiring plan (`GoogleService-Info.plist` per bundle id)

Important:

- this is a prompt where Codex/Claude should explicitly ask the user for the Firebase setup status and guide them on exactly what to configure and where

#### Prompt 9a.2 - Supabase Project Setup + Third-Party Auth Integration

Goal:

- guide the user through Supabase project setup and wire the Firebase JWT integration so RLS can scope by authenticated identity

In scope:

- Supabase project creation (region choice: Canadian for NL data residency when available)
- Enable `pgvector` and Apache `AGE` extensions (Phase 11a needs these)
- Configure third-party auth integration with the Firebase Auth project (OIDC Issuer Discovery URL)
- Define the minimal Firebase JWT claim contract Supabase RLS depends on
  (`restaurant_id`, the authenticated-role shape Supabase expects, and any
  optional coarse role / scope claim)
- Apply initial schema migration: `restaurants`, `restaurant_users`, `roles`, `role_permissions` tables
- Apply baseline RLS policies on those tables (per-operator scoping based on Firebase JWT claims)
- Commit Supabase URL + anon key into flavor-specific build config (never the service-role key)

Important:

- this prompt depends on `Prompt 9a.1` completing first (Firebase Auth project must exist before Supabase can trust its JWTs)

#### Prompt 9a.3 - Trusted Admin Backend Decision

Goal:

- lock how admin-created users and password-management flows will be handled safely

In scope:

- choose the admin backend path (Cloud Functions + Admin SDK, Supabase Edge Functions, or Cloud Run microservice)
- document any billing/backend requirement
- define which admin actions require server-side execution (user creation requires Firebase Admin SDK; role + permission writes require Supabase service-role)
- define how admin-created users receive and refresh the required Firebase
  custom claims used by Supabase RLS
- define how admin-op handlers authenticate the calling admin before any privileged action

### Prompt 9b - Identity Model + Role Model + Permission Catalog

Purpose:

- define the shared auth-side domain model before UI enforcement begins

#### Prompt 9b.1 - Restaurant User Identity Model

Goal:

- add the shared `Restaurant`, `RestaurantUser`, and `ExternalIdentityLink` model shape

In scope:

- restaurant user model
- email as login identifier
- Firebase `uid` as app identity key
- future vendor link placeholders

#### Prompt 9b.2 - Seeded Roles + Custom Roles + Permission Keys

Goal:

- define the role and permission system cleanly

In scope:

- seeded roles
- recommended default permissions for seeded roles
- custom role model
- fixed permission catalog

Non-negotiable:

- admins may edit seeded roles
- admins may create custom roles
- admins may assign and remove existing permission keys
- admins may not invent new permission key types in database data

### Prompt 9c - Login + Persistent Session

Purpose:

- add the real login lifecycle to both products

#### Prompt 9c.1 - Firebase Auth + Supabase Client Wiring + Session Bootstrap

Goal:

- wire Firebase Auth into app bootstrap, configure the Supabase client to validate Firebase JWTs, and keep users signed in until logout

In scope:

- Firebase Auth SDK wiring (Flutter `firebase_auth` package)
- Supabase Flutter SDK wiring (`supabase_flutter` package) with Firebase JWT injection so RLS applies per request
- startup auth resolution (Firebase first, then Supabase session with Firebase JWT)
- persistent session until logout (both Firebase and Supabase sessions)
- separate local persisted sessions per installed app
- token refresh handoff: when Firebase Auth refreshes the JWT, Supabase client uses the refreshed token

#### Prompt 9c.2 - Login / Logout / Password Reset UX

Goal:

- build the user-facing auth surfaces for both products

In scope:

- login screen
- logout path
- password reset
- no guest mode
- no biometrics
- no PIN auth

### Prompt 9d - Admin User Control + Role Console

Purpose:

- let admins manage users and roles from one place

#### Prompt 9d.1 - Trusted Admin User Management Flows

Goal:

- wire the backend-backed create/reset/deactivate user flows safely

In scope:

- create user
- deactivate user
- reset password

Important:

- this prompt depends on the trusted admin backend path chosen in `9a.3`

#### Prompt 9d.2 - In-App Admin Console

Goal:

- give admins one console to manage users, roles, and permission assignments

In scope:

- user list
- role assignment
- seeded-role editing
- custom-role creation
- permission assignment

### Prompt 9e - Runtime Permission Enforcement Across Both Apps

Purpose:

- replace preview behavior and informal access with real enforcement

#### Prompt 9e.1 - Forge & Flow Runtime Enforcement

Goal:

- apply permissions to standalone Forge & Flow surfaces and actions

In scope:

- screen visibility
- action visibility
- manager override access
- settings/admin actions

#### Prompt 9e.2 - Barrio Runtime Enforcement

Goal:

- replace preview-only role behavior with real auth-driven access inside Barrio

In scope:

- bubble visibility
- route access
- destination access
- Forge & Flow-inside-Barrio access

Important:

- Barrio uses the same shared user and permission model
- Barrio admin remains the superset role

### Prompt 9.5 - El Podio Learning Identity

Moved to its own plan:

- [phase_9_5_el_podio_learning_identity_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_9_5/phase_9_5_el_podio_learning_identity_plan.md)

That doc contains prompts `9.5a` (User-Scoped Learning Persistence) and
`9.5b` (Shared El Podio Learning Leaderboard). Phase 9 execution does not
run those prompts; Phase 9.5 does.

## Non-Negotiable Rules

- Keep one shared auth style across both products.
- Keep one shared backend identity system.
- Keep email/password as the login method.
- Keep login persistent until explicit logout.
- Do not use SQLite as the source of truth for auth.
- Do not use POS/labor systems as the auth source of truth.
- Keep permission keys fixed and app-defined.
- Keep Forge & Flow inside Barrio on the same live session context.
- Keep the one-way runtime dependency honest: Forge & Flow does not depend on Barrio, Barrio consumes Forge & Flow.
- Keep the permission model aligned with the product boundary: Forge & Flow baseline first, Barrio additions second.
- Keep El Podio operational ranking out of the initial auth implementation.
