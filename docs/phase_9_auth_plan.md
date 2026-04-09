# Phase 9 Auth Plan

Updated: 2026-04-02
Owner: Codex planning / tracker truth
Purpose: define the final auth, role, permission, and persistent-session architecture for Forge & Flow and Barrio before Phase 9 implementation begins.

## Final Decisions Locked

These decisions are now the planning baseline.

- Use one auth style across both products.
- Use email/password login.
- Use Firebase Auth as the credential and session authority.
- Use Firestore as the canonical user, role, and permission store.
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

### Firestore Is The Canonical Profile / Role / Permission Store

Use Firestore for:

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

## Firebase Guardrails

These guardrails should be explicit in the plan.

- Use email/password auth, not username aliases layered on top of email.
- Enable standard password reset flow.
- Keep the user signed in until explicit logout.
- Keep Firebase custom claims minimal.
- Do not try to store the full permission catalog in custom claims.
- Treat Firestore as the canonical role/permission source.
- Use Security Rules to protect backend data instead of trusting the client.
- Test Security Rules in the Firebase emulator before production rollout.

Important platform note:

- Custom claims are useful for coarse access facts, but they are not the right place for a large, changing permission matrix.
- Claims are server-managed and token-refresh-driven, which makes them a bad fit for highly detailed per-screen permission state.

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
- admins may not invent new permission key names in Firestore

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

## Firestore Storage Model

Recommended structure:

- `restaurants/{restaurantId}`
- `restaurants/{restaurantId}/users/{uid}`
- `restaurants/{restaurantId}/roles/{roleId}`

Optional later collections:

- `restaurants/{restaurantId}/learning_progress/{uid}`
- `restaurants/{restaurantId}/podio_learning/{uid}`

The important rule is:

- backend identity lives on `uid`
- restaurant-specific profile and role state live under the restaurant record

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

Firebase client apps should not directly create other users as an admin action.

If admins create users inside the app, the project needs a trusted server-side path such as:

- Cloud Functions
- Firebase Admin SDK
- or another controlled backend admin endpoint

This is a hard Phase 9 requirement.

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

El Podio should be treated as two different systems.

### Phase 9.5 - Learning El Podio

Scope:

- real authenticated `userId`
- user-scoped completion points
- user-scoped mastery
- user-scoped streaks
- learning leaderboard identity

Important:

- if El Podio is truly a restaurant-wide multi-user leaderboard, the source of truth must be shared backend data, not only local `SharedPreferences`

### Later - Operations El Podio

Depends on:

- Phase 8 vendor data
- external identity links
- valid employee/shift/sales attribution rules

Examples:

- total sales ranking
- PPA ranking
- CPLH ranking

Do not fold this into the initial auth implementation.

## Implementation Research Guardrails

The plan should follow the platform reality:

- Firebase Auth is a strong fit for email/password, reset, and persisted mobile auth sessions.
- Firebase Security Rules should be used to protect backend data instead of trusting clients.
- Firestore rules should be tested in the emulator before rollout.
- Firebase Admin SDK or trusted server-side code is required for safe admin-created user flows.
- Keep custom claims minimal and avoid turning them into the main permission catalog.

## Firebase Setup Checkpoints

Phase 9 has a few places where work cannot responsibly continue without either:

- user-provided Firebase console setup
- user confirmation of backend choices
- or macOS-side Apple configuration later

Those checkpoints should be explicit in the plan.

### Firebase Project Shape

Recommended setup:

- one Firebase project for both apps
- same backend identity system
- same Firestore data store
- separate registered app entries per native package/bundle id

Why:

- same users need to work across Forge & Flow and Barrio
- same restaurant-scoped roles and permissions need to govern both products
- Forge & Flow inside Barrio must resolve against the same backend identity

### Setup Prompt Guidance

At the relevant implementation prompt, Codex/Claude should stop and guide the user through exactly what must be configured in Firebase and where the files belong in the repo.

That guidance should cover:

- creating or selecting the Firebase project
- enabling Email/Password auth
- creating the Firestore database
- deciding the trusted admin backend path:
  - Cloud Functions + Firebase Admin SDK
  - or another backend endpoint
- confirming any billing requirement if Cloud Functions are chosen
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

### Expected Firebase File Placement

Android:

- `android/app/src/forgeflow/google-services.json`
- `android/app/src/barrio/google-services.json`

iOS:

- flavor-specific `GoogleService-Info.plist` handling will be needed for the two iOS bundle ids
- because iOS already uses separate schemes/configurations, this should be handled in the iOS-specific auth prompt
- if the user is on Windows during implementation, the plan should call out any macOS/Xcode-only verification honestly

### Prompt Behavior Rule

At the Firebase setup prompt, Codex/Claude should:

- tell the user exactly what to create in Firebase
- tell the user exactly where the resulting files go in this repo
- tell the user what backend requirement exists for admin-created users
- stop and wait for that setup to exist before pretending the auth work is complete

## Prompt Breakdown

Phase 9 should not be treated as one prompt.

Use this breakdown.

## Phase 9 - Restaurant Auth + Login

Umbrella objective:

- one shared auth, role, and permission system across Forge & Flow and Barrio

### Prompt 9a - Firebase Foundation + Auth Backend Shape

Purpose:

- lock the Firebase project shape and backend responsibilities before runtime auth code is written

#### Prompt 9a.1 - Firebase Project Setup + Native App Registration

Goal:

- guide the user through Firebase setup and wire the project/app registrations into the repo

In scope:

- one Firebase project decision
- Email/Password auth enablement
- Firestore creation
- Android app registration for:
  - `com.forgeflow.app`
  - `com.forgeflow.barrio`
- iOS app registration for:
  - `com.forgeflow.app`
  - `com.forgeflow.barrio`
- Android config file placement
- iOS config-file wiring plan

Important:

- this is a prompt where Codex/Claude should explicitly ask the user for the Firebase setup status and guide them on exactly what to configure and where

#### Prompt 9a.2 - Trusted Admin Backend Decision

Goal:

- lock how admin-created users and password-management flows will be handled safely

In scope:

- choose Cloud Functions/Admin SDK or another trusted backend path
- document any billing/backend requirement
- define which admin actions require server-side execution

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

#### Prompt 9c.1 - Firebase Auth Wiring + Session Bootstrap

Goal:

- wire Firebase Auth into app bootstrap and keep users signed in until logout

In scope:

- Firebase SDK wiring
- startup auth resolution
- persistent session until logout
- separate local persisted sessions per installed app

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

- this prompt depends on the trusted admin backend path chosen in `9a.2`

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

### Prompt 9.5 - El Podio Learning Identity + Shared Data Model

Purpose:

- separate learning leaderboard identity work from the core auth rollout

#### Prompt 9.5a - User-Scoped Learning Persistence

Goal:

- replace in-memory learning completion/streak state with real user-scoped data

In scope:

- mastery persistence
- completion persistence
- streak ownership by `uid`

#### Prompt 9.5b - Shared El Podio Learning Leaderboard

Goal:

- move El Podio from demo users to real authenticated learning leaderboard data

In scope:

- learning points model
- ranking identity
- shared backend learning leaderboard state

Out of scope:

- live sales ranking
- live PPA ranking
- live CPLH ranking
- POS/labor-attributed leaderboard logic

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
