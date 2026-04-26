# Phase 9 - Auth, Identity, Permissions, Audit

Updated: 2026-04-26
Status: Active next (sequence locked under "full proper dev before launch
- no shortcuts" 2026-04-26)
Owner: Phase 9 auth lane

This is the comprehensive Phase 9 plan. The pre-rewrite version is
archived at
`docs/archive/phases/phase_9/phase_9_auth_plan_2026-04-26_PRE_NO_SHORTCUTS_LOCK.md`
for traceability.

## Why Phase 9 Exists

Phase 9 turns the operator product from "nobody can use it because there is
no auth" into "operators, locations, staff, F&F super-admins, and F&F
support staff all log in, see only their data, can have custom roles, can
be audited, and meet 2026 industry-standard security posture."

It also closes the existing code gaps: `BarrioPreviewRole` is preview-only,
learning completion is in-memory `Set<String>`, streaks live in global
`SharedPreferences`, manager override and settings actions have no real
permission checks. None of these can survive the production cutover gate.

## Architecture Lock (decided 2026-04-26)

Five product decisions locked alongside the slice plan:

1. **Identity layer: Firebase Identity Platform tier** (not Firebase Auth
   standard). Required for MFA enforcement, future blocking functions, and
   per-tenant project config. Free up to 50k MAU then ~$0.0055/MAU.
   Live setup note (2026-04-26): official Identity Platform docs list
   email/password, phone, federated/OIDC/SAML, and custom-auth integration
   paths; TOTP is documented as a supported MFA factor. No official
   first-party WebAuthn/passkey provider surface was found. Decision:
   Phase 9 launches with email/password + TOTP MFA; passkeys are a future
   follow-up, not a launch gate, unless Firebase / Identity Platform exposes
   an official supported passkey path before cutover.
2. **Permission model: enriched RBAC at launch**. Custom roles, deny
   rules, location-scoped, time-bound. ReBAC graph permissions
   (OpenFGA / SpiceDB) deferred to Phase 12 workflow approval chains
   where graph relationships actually pay off.
3. **SSO / SAML / SCIM: WorkOS, deferred** to first Enterprise-tier
   customer demand. Don't build SAML in-house; WorkOS at $125/mo/connection.
4. **MFA enforcement policy**: required for all admin users at every
   tier; required for all users (staff included) at Premium tier and
   above. Lower tiers (Pilot, Starter) make MFA optional for staff.
5. **GDPR right-to-erasure**: redact-don't-delete with documented runbook
   and break-glass approval. Operational record carve-out under GDPR
   Art. 17(3); preserves audit integrity. Hard-delete is reserved for
   legal-hold release scenarios only.

Detailed rationale lives under "Phase 9 Architecture Lock (2026-04-26)"
in `phase_11a_decision_register.md`.

The full user-approved decision set for Phase 9 lives in
`phase_9_decision_lock_2026-04-26.md`. Future prompts should not re-ask those
choices unless the user explicitly reopens them.

## Product Boundary Rules

Preserved from the prior plan — non-negotiable architecture truth about
the Forge & Flow / Barrio product split. Every Phase 9 slice respects
these.

1. Any shared Forge & Flow runtime change is visible inside Barrio
   because Barrio consumes the shared Forge & Flow runtime boundary.
2. Shared Forge & Flow runtime changes do not mean Barrio shell
   changes leak back into standalone Forge & Flow.
3. Forge & Flow must not become dependent on Barrio-specific runtime
   code to function.
4. Barrio may continue depending on the shared Forge & Flow runtime
   because that is already how the product split is structured.
5. Standalone Forge & Flow only renders Forge & Flow surfaces.
6. Standalone Barrio may render both Forge & Flow and Barrio surfaces.
7. Barrio admin is the superset role: full Forge & Flow permissions +
   full Barrio permissions + full admin controls. (In Phase 9 terms:
   `super_admin` and `operator_owner` carry both `product.forgeflow.access`
   and `product.barrio.access`.)
8. Even if a backend account has both Forge & Flow and Barrio
   permissions, standalone Forge & Flow still shows only Forge & Flow.
9. Forge & Flow inside Barrio must use the same live auth/session
   context already active in Barrio and must not prompt for a second
   login.

## App Behavior Rules

Preserved runtime experience rules from the prior plan.

**Standalone Forge & Flow:**
- Requires login.
- Shows Forge & Flow only.
- Does not show Barrio surfaces even if backend permissions allow them.
- Reads the same backend role and permission model.
- Remains the foundational commercial app experience.

**Standalone Barrio:**
- Requires login.
- Can show both Forge & Flow and Barrio surfaces according to the
  shared permission model.
- Acts as the internal superset shell.

**Forge & Flow inside Barrio (embedded):**
- Uses the same live auth/session context already active in Barrio.
- Must not prompt for a second login.
- Uses the same user identity and role context.
- Uses the same permission model.

## Backend And Storage Split

Preserved storage discipline from the prior plan.

**Firebase Auth / Identity Platform is the credential authority.** Use it
for: email/password login, password reset, session persistence,
authenticated user identity (`uid`), and TOTP MFA enrollment. Passkeys
are parked as a future follow-up unless Firebase / Identity Platform
ships an official supported WebAuthn/passkey path before cutover.

**Azure DB for PostgreSQL Flexible Server is the canonical profile +
role + permission + audit store.** Use it for: restaurant records,
operator profiles, role definitions, permission bundles per role,
product access flags, external identity link fields (Phase 8 bridge),
shared learning leaderboard data (Phase 9.5), audit log, sessions,
MFA factor inventory.

**SQLite stays local and operational.** Keep SQLite for: existing
operational/cache data already used by Forge & Flow, local canonical
app-side data that already flows through repositories and notifiers,
local cache/snapshot support where useful for startup performance.

**Do NOT use SQLite as the source of truth for:** auth, passwords,
role definitions, permission assignments, restaurant user identity,
session ledger, audit log.

**Do NOT use POS / labor / reservation systems as the auth source-of-
truth.** Vendor employee records are joined to app users via the
`external_identity_links` mapping bridge (see 9.0 schema), not the
other way around.

## Hard Promises Phase 9 respects

- HP #4 Per-operator isolation: RLS-ready schema from day one; Phase 9
  enforces. `staff_id` axis added in `11b.1`.
- HP #6 Advisor speaks in recommendations, not commands: T&Cs schema
  lands here; T&Cs content lands in 9.8.
- HP #7 F&F holds all provider keys server-side: client never holds
  Firebase Admin SDK key.
- HP #9 AI cost is metered by class: per-(operator_id, location_id,
  staff_id NULL, workflow_id NULL, usage_class). Phase 9 wires
  `staff_id NULL` slot now; Phase 11b.1 fills it.

Plus the locked architectural rules already in CLAUDE.md:

- Repository pattern (`OperatorScopedRepository<T>`) is the primary
  defense; RLS is the backup.
- `SET LOCAL` (transaction-scoped) tenant injection, never `SET`.
- RLS performance discipline: every fact-table index leads with
  `operator_id`.
- `TIMESTAMPTZ` everywhere; `business_date` denormalized at write.
- API URL versioning `/v1/...`; idempotency on every write.

## Non-Negotiables

- No vendor secrets in Flutter; Firebase Admin SDK is server-only.
- No SQLite as auth source-of-truth; Postgres is canonical.
- No POS / labor / reservation as identity source-of-truth; identity
  attribution to vendor employees is a separate mapping table
  (Phase 8 dependency).
- No hard-delete on `users` or `auth_events_audit`; soft-delete +
  PII-redact is the only path.
- No plaintext passwords stored anywhere; bcrypt cost 12 minimum
  (Firebase manages); no custom password hashing.
- No SMS as a primary MFA factor (NIST SP 800-63B-4 deprecated).
- Login persists until explicit logout (Hard Promise from prior plan;
  preserved).
- No biometric unlock layer in the app (Hard Promise from prior plan;
  preserved). Future passkeys, if enabled through an official supported
  path, use the OS biometric transparently to the app.
- One auth style across both products (Forge & Flow + Barrio); same
  Firebase project, same Postgres instance, same role model.
- Forge & Flow inside Barrio uses the live Barrio session; no second
  login.
- Permission keys are app-defined, frozen at code level; admins may
  not invent new keys at runtime.
- Every admin write has audit columns (`created_by`, `updated_by`)
  populated; every admin action emits an `auth_events_audit` row.
- Every login / logout / token refresh / password change / MFA
  enrollment / role change / permission change / soft-delete / GDPR
  redaction is logged to `auth_events_audit` (append-only, INSERT only,
  DELETE / UPDATE revoked from `service_role`).

## Sub-Slice Sequence (9.0 → 9.9)

Sequential. Do not start the next slice until the prior accepts.
Estimated total: 12-15 weeks.

### `9.0` Auth Schema Foundation (~3-5 days)

**Status:** Accepted 2026-04-26. Local tests passed; migration applied and
verified on staging + Production1. Result doc:
`phase_9_0_auth_schema_live_apply_result.md`.

**Single deterministic migration.** Local-first; applies cleanly to
staging and production1.

**New tables:**

- `roles` — operator-scoped or global
  - `role_id UUID PK, operator_id UUID NULL FK, role_key TEXT,
    display_name, description, is_seeded BOOL, is_editable BOOL,
    created_by, updated_by, created_at, updated_at, deleted_at NULL`
  - Composite UNIQUE `(operator_id, role_key)`
- `permission_keys` — frozen catalog
  - `key TEXT PK, category TEXT, description TEXT,
    requires_mfa BOOL DEFAULT false, frozen BOOL DEFAULT true`
  - Seeded from code-defined catalog (~80 keys; see "Permission Key
    Catalog" below)
- `role_permissions` — bundle definition
  - `role_id UUID FK, permission_key TEXT FK, effect TEXT
    CHECK (effect IN ('allow', 'deny')), created_by, updated_by,
    created_at, updated_at`
  - Composite PK `(role_id, permission_key)`; deny wins
- `user_roles` — grant + scope + time-bound
  - `user_role_id UUID PK, user_id UUID FK, role_id UUID FK,
    location_id UUID NULL FK, valid_from TIMESTAMPTZ, valid_until
    TIMESTAMPTZ NULL, granted_by UUID FK, revoked_at TIMESTAMPTZ
    NULL, revoked_by UUID NULL FK, reason TEXT NULL, created_at,
    updated_at`
  - Tenant-leading active-grant UNIQUE
    `(operator_id, user_id, role_id, coalesce(location_id, sentinel))`
    where `revoked_at IS NULL` (partial index)
- `auth_sessions` — own-ledger of Firebase sessions
  - `session_id UUID PK, user_id UUID FK, refresh_token_hash TEXT,
    ip INET, user_agent TEXT, device_fingerprint TEXT NULL,
    geo_country CHAR(2) NULL, created_at, last_seen_at, revoked_at
    NULL, revoked_reason TEXT NULL`
- `auth_events_audit` — append-only audit log
  - `event_id UUID PK, actor_user_id UUID FK NULL, target_user_id
    UUID FK NULL, operator_id UUID NULL, location_id UUID NULL,
    event_type TEXT, event_payload JSONB, ip INET NULL, user_agent
    TEXT NULL, geo_country CHAR(2) NULL, request_id UUID NULL,
    occurred_at TIMESTAMPTZ, schema_version INT DEFAULT 1`
  - **Append-only enforcement**: `REVOKE DELETE, UPDATE ON
    auth_events_audit FROM PUBLIC, service_role; GRANT INSERT,
    SELECT TO service_role`
- `mfa_factors` — enrolled second-factor inventory
  - `factor_id UUID PK, user_id UUID FK, factor_type TEXT
    CHECK (factor_type IN ('passkey', 'totp', 'recovery_code')),
    factor_metadata JSONB (Firebase factor uid, AAGUID for passkey,
    issuer for TOTP), enrolled_at, last_used_at NULL, revoked_at
    NULL`
- `tncs_acceptances` — never-overwrite acceptance log
  - `acceptance_id UUID PK, user_id UUID FK, operator_id UUID FK,
    tncs_version TEXT, accepted_at TIMESTAMPTZ, ip INET, user_agent
    TEXT`
- `password_history` — last 5 password hashes per user
  - `entry_id UUID PK, user_id UUID FK, password_hash TEXT
    (Firebase handles; we store the hash for re-use detection only),
    set_at TIMESTAMPTZ`
  - Pruning: trigger or scheduled job keeps newest 5 per user;
    cleared on GDPR erasure
- `auth_invites` — invite-with-expiry
  - `invite_id UUID PK, email TEXT, operator_id UUID FK, role_id
    UUID FK, location_id UUID NULL FK, invited_by UUID FK,
    expires_at TIMESTAMPTZ, accepted_at TIMESTAMPTZ NULL,
    revoked_at TIMESTAMPTZ NULL, invite_token_hash TEXT, created_at`
- `role_audit_log` — append-only role/permission change history
  - `entry_id UUID PK, role_id UUID NULL, user_role_id UUID NULL,
    change_type TEXT, change_payload JSONB, changed_by UUID FK,
    changed_at TIMESTAMPTZ`
  - Same append-only grant pattern as `auth_events_audit`
- `external_identity_links` — Phase 8 vendor employee bridge
  (preserved from prior plan; **distinct from `users.external_id`
  which is for SSO**)
  - `link_id UUID PK, user_id UUID FK, operator_id UUID FK,
    location_id UUID NULL FK, vendor TEXT (`pos:toast`, `labor:7shifts`,
    `reservation:opentable`, etc.), labor_email TEXT NULL,
    labor_employee_id TEXT NULL, pos_employee_id TEXT NULL,
    vendor_display_name_snapshot TEXT NULL, last_linked_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ NULL, created_at, updated_at`
  - Composite UNIQUE `(operator_id, vendor, labor_employee_id)` and
    `(operator_id, vendor, pos_employee_id)` (partial, where the
    column is NOT NULL)
  - Phase 8 / 8R / Operations El Podio later phases consume this
    table to attribute vendor data (sales, shifts, reservations) to
    real app users
  - **NOT the auth source-of-truth**: this is a mapping bridge only.
    Vendor APIs do not become identity authority.

**Extend existing tables:**

- `users` adds (auth + identity):
  - `firebase_uid UUID UNIQUE NOT NULL` — links Firebase user to row
  - `external_id TEXT UNIQUE NULL` — future SSO/SAML/SCIM mapping
    (distinct from `external_identity_links` Phase 8 vendor bridge
    below)
  - `status TEXT NOT NULL DEFAULT 'invited'` CHECK in
    (`'invited'`, `'active'`, `'suspended'`,
    `'dormant_30'`, `'dormant_60'`, `'dormant_90'`, `'deleted'`)
  - `deleted_at TIMESTAMPTZ NULL` — soft-delete
  - `roles_version INT NOT NULL DEFAULT 0` — cache invalidation key
  - `mfa_required BOOL NOT NULL DEFAULT false` — per-user override
  - `last_login_at TIMESTAMPTZ NULL`
  - `last_active_at TIMESTAMPTZ NULL` — drives dormancy state machine
  - `password_set_at TIMESTAMPTZ NULL`
  - `email_verified_at TIMESTAMPTZ NULL`
- `users` adds (user profile — preserved from prior plan):
  - `first_name TEXT NULL` — display in admin console + leaderboards
  - `last_name TEXT NULL`
  - `display_name TEXT NULL` — denormalized "First L." or chosen
    handle for compact UI
  - `primary_role_id UUID NULL FK` — denormalized primary role for
    quick header rendering (computed from highest-precedence active
    `user_roles` row; updated by trigger on `user_roles` change)
  - `preferred_locale TEXT NULL` — for future i18n
  - `avatar_url TEXT NULL` — admin/leaderboard headshots
- `users` drops legacy `role TEXT NULL` column (migrated into
  `user_roles` via 9.0 backfill — empty in production, real in any
  test seeds)
- `operator_admins` adds:
  - `scope_type TEXT NOT NULL` CHECK in (`'super_admin'`,
    `'ff_support'`, `'operator_owner'`, `'operator_manager'`)
  - `scope_location_id UUID NULL FK` — for `ff_support` per-operator
    + per-location read scope
  - `valid_from TIMESTAMPTZ NOT NULL DEFAULT now()`
  - `valid_until TIMESTAMPTZ NULL`

**RLS scaffolding** on all new tables, service-role-only stubs (Phase 9.2
flips them to per-tenant policies). Composite `(operator_id, ...)` leading
indexes per Lock 4 on every operator-scoped row.

**Seed data:**

- `permission_keys` catalog (~80 keys; full list in "Permission Key
  Catalog" section below)
- 6 baseline roles via `roles` + `role_permissions` rows:
  `super_admin`, `ff_support`, `operator_owner`, `operator_manager`,
  `operator_supervisor`, `operator_staff`

**Acceptance:**

- Migration applies cleanly to local + staging + production1
- Tests verify: every FK target exists; every composite UNIQUE present;
  RLS scaffolding present; append-only grants enforced (test that
  `DELETE FROM auth_events_audit` fails as `service_role`); seed data
  loaded; all `(operator_id, ...)` leading indexes present per Lock 4
  audit query
- No live runtime change; identity layer not yet wired

### `9.1` Firebase Identity Platform setup + JWT verifier wiring (~5-7 days)

**Live, billable.** Notify user before account/billing setup. The
implementer (Claude) **must stop and guide the user through every
setup step** before code work proceeds — this is a hard prerequisite
gate, preserved from the prior plan's "Firebase Auth + Setup
Checkpoints" section.

**Setup Prompt Behavior Rule** (preserved from prior plan): at
this slice's prompt, Codex/Claude must:

- Tell the user exactly what to create in Firebase (Identity Platform
  tier + app registrations + email templates).
- Tell the user exactly what to enable on Azure DB Flexible Server
  (already done in `11a.11c.6`; re-verify Firebase Admin SDK
  service-account access).
- Tell the user exactly where the resulting config files go in this
  repo.
- Tell the user what billing requirement exists (Identity Platform
  paid tier — free up to 50k MAU, then ~$0.0055/MAU).
- Stop and wait for that setup to exist before pretending the
  Firebase work is complete.

**Human prerequisites (set up before slice runs):**

- Firebase Identity Platform tier provisioned (MFA and future blocking
  functions enabled). NOT Firebase Auth standard tier.
- One Firebase project for both apps; native app registrations:
  - Android: `com.forgeflow.app`, `com.forgeflow.barrio`
  - iOS: `com.forgeflow.app`, `com.forgeflow.barrio`
  - Web: `admin.forgeflow.app`
- Email/password auth enabled; TOTP factor enabled; SMS disabled (NIST
  deprecation). Passkeys are not a 9.1 launch gate unless Firebase exposes
  an official supported path before cutover.
- Auth email path: Firebase action links with Forge & Flow branded web pages
  for invite, password reset, email verification, and MFA-related action
  flows. Built-in Firebase subject/body template customization is not a
  launch blocker.
- `google-services.json` placed per-flavor under
  `android/app/src/forgeflow/` and `android/app/src/barrio/`
- iOS `GoogleService-Info.plist` per-bundle-id wiring planned
  per scheme/configuration (macOS-only verification flagged honestly
  if implementing on Windows)
- Cloud Run service account with Firebase Admin SDK permissions
- Billing decision confirmed (Firebase Blaze plan if Cloud Functions
  ever land; Cloud Run already on pay-as-you-go)
- **Files NOT to commit:** Firebase Admin SDK private key JSON
  (lives in Cloud Run env / KMS); service-account JSON for local
  dev (lives outside repo at
  `$HOME/.forge_flow/firebase-staging-adminsdk.json`, with local env
  loaded from `$HOME/.forge_flow/forge_flow.secrets.ps1`)

**Code:**

- `RealProxyJwtVerifier` replaces `ScaffoldRejectingJwtVerifier`
  in `tool/advisor_proxy/advisor_proxy.dart`
- Firebase Admin SDK Dart wiring (via `package:firebase_admin_interop`
  or HTTP-based JWKS verification)
- JWKS auto-cache (~6h Cache-Control)
- JWT verifier style: verify Firebase ID tokens locally with Firebase public
  keys/JWKS; do not call Firebase per normal request.
- Revocation policy: normal requests use local JWT verification + DB user
  status; sensitive ops do live revoked-token checks (`checkRevoked=true`)
  (role changes, billing, MFA enrollment, soft-delete, GDPR erasure)
- Custom claims policy: `operator_id`, `is_super_admin`,
  `is_ff_support`, `roles_version` — total under 200 bytes
- Tenant-context resolver: `firebase_uid → users → (operator_id,
  default_location_id, status)`; reject if `status != 'active'`
- `AuthEventLogger` writes to `auth_events_audit` on every login /
  logout / verification failure / revocation / MFA challenge

**Acceptance:**

- Live JWT smoke against Firebase Identity Platform succeeds
- Dedicated staging auth test user: `auth-smoke@forgeflow.dev`
- Cross-tenant token rejected (403); revoked token rejected (401);
  suspended user rejected (403); soft-deleted user rejected (404)
- MFA-enrolled user gets MFA challenge on login
- Audit row written for every login attempt (success or failure)
- JWKS cache hit rate > 99% in load test

### `9.2` Repository pattern + SET LOCAL injection + RLS enforcement live (~5-7 days)

**Code-only initially; live RLS flip on staging at end.** User-approved:
perform the live staging RLS flip once integration tests are ready.

- `OperatorScopedRepository<T>` abstraction in
  `lib/infrastructure/persistence/postgres/`
- `TenantTransactionWrapper` issues `BEGIN; SET LOCAL
  app.operator_id = $1; SET LOCAL app.location_id = $2; SET LOCAL
  app.user_id = $3; ...; COMMIT;` per request
- RLS policies: drop service-role-only stubs; replace with per-tenant
  `USING (operator_id = current_setting('app.operator_id', true)::uuid)`
  on every operator-scoped table
- `forge_admin` Postgres role with `BYPASSRLS` granted only to admin
  paths (`/v1/admin/*`); audit row on every BYPASSRLS use. This bypass-role
  approach is user-approved; do not replace it with normal-RLS-only admin
  modeling unless explicitly reopened.
- CI lint: `package:postgres` raw imports forbidden outside
  `lib/infrastructure/persistence/postgres/` (extends existing rule)

**Cross-operator isolation integration tests:**

- Tenant A user cannot SELECT tenant B rows on every operator-scoped
  table (~30 tables × 4 operations = ~120 test cases)
- Tenant A user cannot INSERT with operator_id = tenant_b
- Tenant A user cannot UPDATE tenant B rows even with malformed payload
- Tenant A user cannot DELETE tenant B rows
- ff_support user can SELECT only assigned operator's rows (via
  `scope_type = 'ff_support'`, `scope_location_id` filter)

**Acceptance:**

- Real RLS enforcement live on staging (drop the service-role-only
  stubs)
- Cross-operator integration test suite (~120 cases) passes
- CI lint catches violations (test commit fails)
- BYPASSRLS audit row written on every super_admin action

### `9.3` Login + persistent session + step-up auth + Flutter app wiring (~7-10 days)

**Live, real users on staging.**

- Flutter login screen for both Forge & Flow + Barrio
- Sign-in methods: email + password (NIST 800-63B-4 compliant) with TOTP
  MFA where required; magic-link / action-link flow for invite acceptance.
  Passkeys are future follow-up only unless official Firebase / Identity
  Platform support appears before cutover.
- Firebase Auth Flutter SDK: `firebase_auth` for mobile; `firebase_auth`
  + `firebase_auth_web` for admin console
- Persistent session until explicit logout
- Refresh-token rotation default-on (Firebase manages internally;
  reuse detection auto-revokes family)
- Step-up auth: re-prompt on sensitive ops (role changes, billing,
  MFA enrollment, soft-delete, GDPR erasure); enforce `auth_time`
  claim < 5 minutes
- Logout flows:
  - Single-session: revoke this session's `auth_sessions` row +
    Firebase token refresh
  - All-sessions: revoke all `auth_sessions` for user + Firebase
    `revokeRefreshTokens(uid)` so all devices re-auth
- `auth_sessions` writes:
  - INSERT on login with `(ip, user_agent, device_fingerprint,
    geo_country)` enrichment
  - UPDATE `last_seen_at` on token refresh
  - SET `revoked_at` on logout
  - Background job marks dormant sessions (`last_seen_at > 30d`)
- Forge & Flow + Barrio share session via `lib/forge_flow_bootstrap.dart`
- Web admin console security headers:
  - `Set-Cookie: session=...; HttpOnly; Secure; SameSite=Strict`
  - `Content-Security-Policy: default-src 'self'; ...`
  - `X-Frame-Options: DENY`
  - `Strict-Transport-Security: max-age=63072000; includeSubDomains`
- Mobile secure storage via `flutter_secure_storage` (Keychain on
  iOS; Android Keystore on Android)

**Acceptance:**

- Login works on staging across both apps
- Sessions tracked correctly in `auth_sessions`
- Logout-all-sessions revokes everywhere within 60s
- Step-up auth triggers on role changes / billing / MFA enrollment
- CSP + cookie flags verified by Mozilla Observatory
- Mobile secure storage uses Keychain / Android Keystore (verified
  via integration test)
- `BarrioPreviewRole` removed; real role context wired

### `9.4` MFA enrollment + enforcement (TOTP + recovery codes; passkeys future follow-up) (~5-7 days)

- Passkeys are parked as a future follow-up unless Firebase / Identity
  Platform exposes an official supported path before cutover. Do not build
  custom WebAuthn in Phase 9 launch scope. The 9.0 `mfa_factors`
  `factor_type='passkey'` enum stays as forward-compatible schema.
- TOTP enrollment via Firebase Identity Platform
  - QR code display once (issuer = `Forge & Flow`)
  - `mfa_factors` row with `factor_type='totp'`
- Recovery codes:
  - 10 single-use codes generated at MFA enrollment
  - Display-once with download/print prompt
  - Hashed in `mfa_factors` with `factor_type='recovery_code'`
  - Each code single-use; `used_at` set on consumption
  - Rate limit on attempts: 1/min, max 5/24h
- MFA enforcement policy (the locked decision):
  - **All admin users (super_admin, ff_support, operator_owner,
    operator_manager) must enroll MFA at every tier**
  - **All users (including operator_supervisor + operator_staff)
    must enroll MFA at Premium / Pro / Enterprise tier**
  - Pilot / Starter operators may opt staff-level users out
  - Read from `operators.subscription_tier`
  - Login refused if `mfa_required = true` and no enrolled factor;
    user routed to enrollment flow
- MFA removal flow:
  - Requires step-up auth + 24h delay window (security best practice
    against account-takeover-then-remove-MFA)
  - Audit: `mfa_factor_revocation_initiated` event + scheduled
    `mfa_factor_revocation_completed` event 24h later

**Acceptance:**

- TOTP fallback works on all tiers
- Passkeys remain documented as not launch-blocking unless official Firebase /
  Identity Platform support appears before cutover
- Recovery codes single-use; hashed at rest
- MFA enforcement triggers at correct tiers
- MFA-removal-delay enforced; audit trail complete
- Recovery code rate limit triggers

### `9.5` Password policy + HIBP screening + brute-force protection + Cloud Armor (~5-7 days)

**NIST SP 800-63B-4 password rules:**

- 8-64+ chars (recommend 15+)
- All printable Unicode allowed
- No composition rules (no "must have one uppercase + one digit + ...")
- No forced rotation (unless breach evidence)
- No security questions (deprecated by NIST)
- No password hints (deprecated by NIST)

**HIBP k-anonymity password screening:**

- On signup + password change: hash password SHA-1, send first 5 chars,
  receive list of pwned suffix hashes, reject if match found
- Cached client-side for 24h to reduce HIBP calls (~$3/month at
  10k MAU under HIBP free tier)
- Server-side rate limit on HIBP calls (100/min/IP)

**Password history:**

- `password_history` retains last 5 hashes per user
- Reject password change if new password matches any of last 5
- Cleared on GDPR erasure

**Brute-force protection (no account lockout):**

- Cloud Armor L7 rate limit on `/v1/auth/*` endpoints:
  100 req/hr/IP/account; 10 req/min/IP global
- Firebase Auth built-in throttling kept on
- reCAPTCHA v3 challenge after N=5 failed login attempts in 1h
- IP reputation enrichment starts with geo / ASN / impossible-travel audit
  only; paid VPN / Tor reputation vendor is deferred:
  - Suspicious IP → soft-block (require step-up auth on next login)
  - Impossible-travel detection: log `auth.suspicious_login` event;
    require step-up auth
- `auth_events_audit` records every brute-force-related event

**Acceptance:**

- Password < 8 chars rejected with NIST-aligned error
- Pwned password rejected via HIBP
- Last-5-passwords reuse rejected
- 100 req/hr/IP rate limit triggers
- reCAPTCHA appears after 5 failures
- Impossible-travel logs warning event in `auth_events_audit`
- Suspicious IP triggers step-up auth on next login

### `9.6` Role + permission system runtime (~7-10 days)

**Schema landed in 9.0; this slice wires the runtime API.**

- Admin endpoints under `/v1/admin/auth/roles/*`:
  - `GET /v1/admin/auth/roles` — list roles (filtered by scope)
  - `POST /v1/admin/auth/roles` — create custom role (operator_owner
    can create operator-scoped; super_admin can create global)
  - `GET /v1/admin/auth/roles/{role_id}` — role detail + permissions
  - `PATCH /v1/admin/auth/roles/{role_id}` — edit role permissions
  - `DELETE /v1/admin/auth/roles/{role_id}` — delete custom role
    (cascade audit; reject if role has active grants — must revoke
    first)
- Admin endpoints under `/v1/admin/auth/role-grants/*`:
  - `POST /v1/admin/auth/role-grants` — grant role to user with optional
    `location_id` scope + `valid_from` / `valid_until`
  - `DELETE /v1/admin/auth/role-grants/{user_role_id}` — revoke
    (sets `revoked_at`, never deletes; audit retained)
  - `GET /v1/admin/auth/users/{user_id}/role-grants` — list user's
    grants
- Permission resolution algorithm (proxy implements):
  ```
  for each user_roles row WHERE user_id = X
    AND now() BETWEEN valid_from AND COALESCE(valid_until, 'infinity')
    AND revoked_at IS NULL:
    join role_permissions
    collect (permission_key, effect) tuples
  if any (permission_key, 'deny') exists for permission_key, effect = deny
  else if any (permission_key, 'allow') exists, effect = allow
  else effect = deny (default)
  ```
- `users.roles_version` bumped on every change; invalidates JWT
  custom claim cache + permission cache
- `role_audit_log` writes on every change with `change_payload JSONB`
  capturing before/after diff
- Scope visibility:
  - `super_admin` can grant/revoke any role
  - `ff_support` can grant/revoke only for operators in their
    `scope_location_id` set
  - `operator_owner` can grant/revoke only operator-scoped roles
    within their operator
  - `operator_manager` can grant only `operator_supervisor` and
    `operator_staff` roles within their operator + location

**Acceptance:**

- 6 seeded roles loaded; default permission grants per spec
- `operator_owner` creates operator-scoped custom role; permission edit
  works
- Deny rule overrides allow rule (integration test)
- Time-bound grant: `valid_until = now() + interval '5 minutes'`
  expires correctly within 5 min
- Scoped role: location-A-only grant cannot read location-B data
- `roles_version` bumps visible on next request
- Scope-visibility: ff_support cannot see operators outside scope

### `9.7` Permission enforcement runtime: cache + Forge & Flow + Barrio gates (~7-10 days)

- `PermissionContext` built per request in proxy from JWT claim
  `roles_version` + DB lookup
- Permission cache: in-process LRU, 60s TTL, keyed by
  `(user_id, roles_version)` — cache hit ~0ms, miss ~3-5ms
- Cache invalidation: `roles_version` bump on role change → next
  request gets fresh cache entry naturally
- Memorystore deferred until ~50k MAU (per Hard Promise: defer
  fixed-cost services until usage justifies)
- Permission-aware Flutter navigation:
  - Barrio destinations: `barrio.handbook.view`,
    `barrio.interview_playbook.view`, `barrio.jim_taylor.view`,
    `barrio.preston_lee.view`, `barrio.supervisor_content.view`,
    `barrio.el_podio.view`
  - Forge & Flow surfaces: `forgeflow.shift.view`,
    `forgeflow.variance.view`, `forgeflow.schedule.view`,
    `forgeflow.baseline.view`, `forgeflow.history.view`
  - Forge & Flow actions: `forgeflow.baseline.override`,
    `forgeflow.target_profile.manage`, `forgeflow.settings.manage`,
    `forgeflow.demo_data.manage`, `forgeflow.operational_data.clear`,
    `forgeflow.target_cycle.unlock`
- Replace existing code gaps:
  - `BarrioPreviewRole` → real role context (handed off to 9.7 from
    9.3)
  - `Set<String> _completedUnits` → user-scoped persistent state
    (handoff to Phase 9.5)
  - Global `SharedPreferences` streak → user-scoped streak (handoff
    to Phase 9.5)

**Acceptance:**

- Barrio routes hidden for unpermitted users
- Forge & Flow settings hidden when missing permission
- Manager override gated; target cycle unlock gated
- Cache hit rate > 90% in load tests at 1000 concurrent users
- `roles_version` bump → fresh permissions visible on next request

### `9.8` Admin user lifecycle: invite, create, reset, deactivate, soft-delete, audit, GDPR erasure (~5-7 days)

- Admin endpoints under `/v1/admin/auth/users/*` (require
  super_admin or ff_support):
  - `POST /v1/admin/auth/invites` — create invite
  - `GET /v1/admin/auth/invites` — list invites
  - `DELETE /v1/admin/auth/invites/{invite_id}` — revoke invite
  - `POST /v1/admin/auth/users/{user_id}/deactivate` — set status
    to `'suspended'`; user cannot log in but data preserved
  - `POST /v1/admin/auth/users/{user_id}/reactivate` — restore
    from `'suspended'`
  - `POST /v1/admin/auth/users/{user_id}/soft-delete` — set status
    to `'deleted'`, set `deleted_at`; RLS hides from queries; audit
    retained
  - `POST /v1/admin/auth/users/{user_id}/erase-pii` — GDPR right-to-
    erasure procedure (break-glass, requires super_admin + paired
    approval)
- Invite flow:
  1. Admin creates invite: email + operator + role + optional
     location + 7-day expiry → `auth_invites` row + Firebase magic-
     link email sent
  2. Recipient clicks link → magic-link auth → Firebase user created
  3. Backend creates `users` row with matching `firebase_uid`,
     `external_id NULL`, `status='active'`, `email_verified_at = now()`
  4. Backend creates `user_roles` row from invite
  5. `auth_invites.accepted_at = now()`
  6. Audit: `auth.invite_accepted` event
- Trusted user creation (programmatic, no invite email): F&F `super_admin`
  only. Operator owners cannot directly create users without an invite.
  Creation uses Firebase Admin SDK in Cloud Run; rare path; audit required.
- Password reset:
  - Firebase action link rendered by branded Forge & Flow web page
  - Audit: `auth.password_reset_requested`, `auth.password_reset_completed`
- Email verification:
  - Firebase action link rendered by branded Forge & Flow web page
  - `users.email_verified_at` set on completion
- GDPR right-to-erasure procedure (the locked posture):
  1. Operator (or user) submits erasure request
  2. ff_support / super_admin verifies identity + processes through
     break-glass flow
  3. Required: paired-approval (two F&F admins; both with super_admin
     scope) + step-up MFA on both
  4. Procedure redacts PII columns:
     - `users.email → 'redacted-{user_id}@deleted.local'`
     - `users.firebase_uid` retained (link integrity)
     - `auth_events_audit.ip → null`
     - `auth_events_audit.user_agent → null`
     - `auth_events_audit.event_payload`: redact email, name fields
       via JSONB `jsonb_set`
     - `auth_sessions.ip → null`, `user_agent → null`
     - `password_history` cleared
     - `mfa_factors.factor_metadata`: redact AAGUID identifiers
  5. Preserve `event_id`, `actor_user_id`, `event_type`, `occurred_at`
     under GDPR Art. 17(3) operational record carve-out
  6. Audit: `gdpr.erasure_executed` event with diff summary
  7. Document procedure in `runbooks/gdpr_erasure_runbook.md`
- Auth/security audit retention: 7 years.

**Acceptance:**

- Invite flow works end-to-end
- Deactivated user cannot log in (Firebase + status check)
- Soft-deleted user cannot be queried via RLS (integration test)
- GDPR erasure runbook smoke-tested on test operator
  - PII redacted correctly
  - Operational record preserved
  - Cannot be reversed (irreversible by design)
- Every admin action visible in `auth_events_audit` within 1s

### `9.9` Admin role console UX (~7-10 days)

UX surface in the Flutter for Web admin console (`admin.forgeflow.app`)
codebase, owned by Phase 9 because the surface is auth-specific.

Note: 11A.1 (Operator + location management) is the basic operator
CRUD surface; 9.9 is the advanced auth + role + permission + audit
surface.

**Surfaces:**

- Users list:
  - filter by operator / status / role / last-active / has-MFA
  - actions: view detail, view roles, view audit, soft-delete,
    reactivate, force-logout-all-sessions, reset password,
    enroll-MFA-on-behalf-of-user (admin assist)
- Roles list:
  - filter by operator / is_seeded / is_editable
  - actions: view detail, edit permissions (with visual deny-wins
    indicator), create custom, delete (cascade audit; reject if
    active grants)
- Role-permission matrix editor:
  - rows = permission keys (grouped by category)
  - columns = roles
  - cells = allow / deny / inherit
  - visual diff vs seeded role baseline
- Role assignment surface:
  - grant role to user with optional location scope + time-bound
  - bulk grant (paste user emails)
- Permission key catalog viewer (read-only):
  - documentation per key (description, category, MFA required)
- Audit log viewer:
  - filter by user / action type / time-window / IP / event_type
  - search free text
  - export CSV for authorized admins; every export is audited
  - sub-second response on indexed queries
- MFA enforcement policy editor:
  - per-tier defaults (locked: super_admin / ff_support / owner /
    manager require MFA; Premium+ require MFA for all)
  - per-operator override (super_admin only)
- Scope visibility:
  - super_admin sees all operators in dropdown
  - ff_support sees only assigned operators

**Acceptance:**

- F&F admin can do all of the above without manual SQL
- Audit log query response < 1s on indexed dimensions
- MFA enforcement policy editor live; changes propagate via
  `roles_version` bump
- Per-scope visibility enforced (ff_support cannot see other
  operators)

## Future Extensions (Out of Phase 9 Scope)

| Slot | Trigger | Owner | Estimated effort |
|---|---|---|---|
| 9-future-1 SSO/SAML/SCIM via WorkOS | First Enterprise customer demands | Phase 9 lane (post-launch) | ~2 weeks |
| 9-future-2 OpenFGA / ReBAC for workflow approval graphs | Phase 12 workflow approval chains | Phase 12 lane | ~3 weeks (integrated with 12.3 approval gate work) |
| 9-future-3 Just-in-time access requests | Post-launch admin polish | Phase 11A.7-10 lane | ~1 week |
| 9-future-4 Bulk user import via CSV | Post-launch admin polish | Phase 11A.7-10 lane | ~3 days |
| 9-future-5 IP allowlist | Enterprise tier feature | Phase 9 lane (post-launch) | ~1 week |
| 9-future-6 DPoP / token binding | Firebase Auth supports it (~2027?) | Phase 9 lane (when ready) | ~3 days |
| 9-future-7 BYO-IDP / OIDC federation | Post-MVP if anyone asks | Phase 9 lane (post-launch) | ~2 weeks |

These have placeholder slots; none block Phase 9 close.

## Phase 8 Interaction

Preserved from the prior plan. Phase 9 auth must not disrupt Phase 8
architecture.

The clean separation is:

- **Phase 9 identity answers "WHO is the user in the app."** — Firebase
  `uid` → `users` row → roles + permissions.
- **Phase 8 vendor integration answers "WHAT happened operationally."**
  — POS sales, labor punches, reservation seatings.

The bridge between them is the `external_identity_links` mapping table
(landing in 9.0):

- App user `uid` → optional labor identity link → optional POS
  identity link → optional reservation identity link.
- Vendor APIs do NOT become the auth source of truth.
- Auth does NOT reshape the canonical Phase 8 ingest path.
- Later operational attribution (Operations El Podio sales /
  PPA / CPLH ranking, post-launch) joins app users to vendor
  employee records through this explicit mapping table.

The bridge supports the "permission-aware operational action" pattern:
e.g., `TargetCycle` early unlock + replace actions are gated by Phase 9
admin role (`admin.target_cycle.unlock`); the resulting cycle change
is attributed to the authenticated `user_id`, while the vendor data
that motivates the change comes through Phase 8 ingest paths
unchanged.

## Phase Boundary

**Phase 9 owns:**

- Identity layer (Firebase Identity Platform setup + JWT verifier
  wiring in proxy)
- Schema for users, roles, permissions, sessions, audit, MFA, T&Cs,
  invites, password history, role audit log
- Repository pattern + SET LOCAL injection + RLS enforcement live
- Login + session + step-up auth + Flutter app wiring (both apps)
- MFA enrollment + enforcement
- Password policy + HIBP + brute-force protection + Cloud Armor
- Role + permission system runtime
- Permission enforcement on Forge & Flow + Barrio screens / actions
- Admin user lifecycle (invite, deactivate, soft-delete, reset)
- GDPR right-to-erasure procedure
- Admin role console UX inside `admin.forgeflow.app`

**Phase 9 does NOT own:**

- El Podio learning identity (Phase 9.5; depends on Phase 9 user_id
  + permission key `barrio.el_podio.view`)
- Barrio shell with staff daily companion (Phase 9.75; depends on
  Phase 9 staff identity)
- Operator + location management UX (Phase 11A.1; consumes Phase 9
  schema for users / operator_admins)
- Pricing tier admin UX (Phase 11A.2; consumes Phase 9 user identity)
- Corpus admin UX (Phase 11A.3)
- Integration management UX (Phase 11A.4)
- Debug console + observability (Phase 11A.5-6)
- Admin polish: feature flags, API versioning, audit log review,
  status page (Phase 11A.7-10)
- POS / labor / reservation transport (Phase 8 / 8R)
- External integrations (Phase 8.5)
- Advisor UX (Phase 11b)
- Workflow platform (Phase 12)
- T&Cs content + DPA package (Phase 9.8 — Phase 9 only owns the
  schema; the legal text + acceptance flow integration is Phase 9.8)
- Operations El Podio ranking (later phase, depends on Phase 8
  attribution)

## Permission Key Catalog (Frozen Code-Defined)

The full catalog is implemented as a constants file in
`lib/auth/permission_keys.dart` and seeded into `permission_keys` via
the 9.0 migration. Categories:

- `product.*` — product-access gates (forgeflow access, barrio access)
- `forgeflow.*` — Forge & Flow surfaces and actions (~20 keys)
- `barrio.*` — Barrio destinations and actions (~15 keys)
- `admin.*` — admin actions (~25 keys: users.create, users.deactivate,
  users.soft_delete, users.erase_pii, roles.edit_seeded,
  roles.create_custom, roles.assign, roles.revoke, target_cycle.unlock,
  pricing_tier.edit, integration.key_rotate, feature_flag.toggle,
  status_page.publish, audit_log.export, etc.)
- `billing.*` — billing-related actions (~5 keys)
- `integration.*` — integration management (~8 keys)
- `workflow.*` — Phase 12 workflow capabilities (~10 keys; placeholder
  for now, populated when Phase 12 lands)

Each `permission_keys` row carries `requires_mfa BOOL` — sensitive
keys (e.g., `admin.users.erase_pii`, `admin.roles.edit_seeded`,
`billing.*`, `integration.key_rotate`) require MFA-fresh `auth_time`
to use.

Full catalog detail in `docs/contracts/auth_permission_key_catalog.md`
(landing in 9.0 alongside the migration).

## Recommended Role Intent (Default Permission Grants)

Preserved from the prior plan. These are planning defaults seeded by
9.0; operator owners may revise via the role console. Operators may
create additional custom roles on top of these defaults.

**`super_admin`** (F&F company, not an operator role):
- Full F&F admin controls (`admin.*` keys)
- Full Forge & Flow surfaces and actions across all operators
- Full Barrio surfaces across all operators
- `BYPASSRLS` via `forge_admin` Postgres role
- All sensitive permission keys (those with `requires_mfa=true`)
- Can grant / revoke any role on any operator

**`ff_support`** (F&F support staff, scoped to assigned operators):
- Read-only on assigned operators' surfaces
- `admin.users.view`, `admin.audit_log.view`, `admin.debug_console.view`
- Cannot edit billing / pricing / integrations
- Cannot grant / revoke roles
- Cannot trigger GDPR erasure (super_admin only)
- Scope enforced via `operator_admins.scope_location_id` filter

**`operator_owner`** (the customer, e.g., Vanessa):
- Full Forge & Flow operational surfaces and actions for owned
  operator
- Full Barrio internal surfaces for owned operator
- Operator-scoped admin controls (`admin.users.*` for own operator,
  `admin.roles.create_custom` for own operator, `admin.target_cycle.unlock`,
  `admin.pricing_tier.edit` is read-only — F&F super_admin owns
  pricing changes)
- Cannot manipulate other operators' data (RLS enforced)
- Carries `product.forgeflow.access` + `product.barrio.access`

**`operator_manager`** (manager-level user inside operator):
- Broad Forge & Flow operational access (shift, variance, schedule,
  baseline, history view; baseline override; target profile manage)
- Broad Barrio internal learning / supervisor surfaces
- Limited admin: can grant `operator_supervisor` and `operator_staff`
  roles within own operator + location
- Carries `product.forgeflow.access` + `product.barrio.access`

**`operator_supervisor`** (supervisor-level user):
- Selected Forge & Flow operational surfaces (shift view, variance
  view, schedule view; no baseline override; no settings manage)
- Barrio staff and supervisor surfaces
- No admin controls
- Carries `product.forgeflow.access` (limited) +
  `product.barrio.access`

**`operator_staff`** (line-level staff):
- Barrio learning surfaces only (handbook, interview playbook, jim
  taylor, preston lee, supervisor content, el podio for the user's
  own data)
- No Forge & Flow operational access by default
- Carries `product.barrio.access` only
- This is the role most users have

These intents are starting points. Operator owners may upgrade
`operator_supervisor` to also have `forgeflow.shift.view` if their
operation works that way; operators may create a custom
`forgeflow_only_user` role; etc. Custom role creation is
operator-scoped.

## Acceptance (Phase Close)

Phase 9 closes when:

- 9.0–9.9 all accept
- Cross-operator isolation integration test suite (~120 cases) green
  on staging and production1
- OWASP ASVS 5.0 Level 2 self-audit complete; gaps documented
- NIST SP 800-63B-4 AAL2 compliance for admin paths verified
- SOC 2 CC6 + CC7 evidence-collection ready (auth_events_audit
  retention configured)
- All Hard Promises preserved
- Phase 9.5 (El Podio learning identity), Phase 9.75 (Barrio shell),
  Phase 11A.1 (operator/location management) unblocked

## Dependencies

Required before `9.0` can open:

- `11a` accepted (cloud foundation schema with operators / locations /
  users / operator_admins / usage_logs / etc. already in place;
  composite FKs locked; RLS scaffolding present)
- `phase_production_cutover` not yet open (production schema flexibility
  must remain open through 9.0)
- Firebase Identity Platform account access
- Cloud Run service account with Firebase Admin SDK permissions
  (provisioned by 9.1 setup step)

After 9.9 closes:

- `11A.0-6` proceeds (admin console foundation consumes Phase 9 schema +
  admin endpoints + role console)
- `7.58` proceeds (Primary Driver audit; Hard Promise gate before 11b)
- `10a`, `10.5`, `9.5`, `9.75` proceed in locked sequence

## Source Material

- Pre-rewrite: `docs/archive/phases/phase_9/phase_9_auth_plan_2026-04-26_PRE_NO_SHORTCUTS_LOCK.md`
- `phase_9_5_el_podio_learning_identity_plan.md` — extracted learning
  identity work
- `phase_11A_operations_console_plan.md` — admin console that consumes
  Phase 9
- `phase_11a_decision_register.md` — RLS performance discipline,
  repository pattern, SET LOCAL discipline, Phase 9 architecture lock
- `db/migrations/202604250005_advisor_cloud_foundation.sql` — existing
  identity schema (operators, locations, users, operator_admins)
- `tool/advisor_proxy/advisor_proxy.dart` — existing JWT verifier
  scaffold (ScaffoldRejectingJwtVerifier replaced by 9.1)
- [OAuth 2.1 draft-13](https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/)
- [NIST SP 800-63B-4 — Digital Identity Guidelines](https://pages.nist.gov/800-63-4/sp800-63b.html)
- [Firebase Identity Platform docs](https://cloud.google.com/identity-platform)
- [Identity Platform authentication concepts](https://cloud.google.com/identity-platform/docs/concepts-authentication)
- [Identity Platform TOTP MFA](https://cloud.google.com/identity-platform/docs/admin/enabling-totp-mfa)
- [Firebase custom email action handlers](https://firebase.google.com/docs/auth/custom-email-handler)
- [Firebase Admin SDK email action links](https://firebase.google.com/docs/auth/admin/email-action-links)
- [Have I Been Pwned — Pwned Passwords k-Anonymity API](https://haveibeenpwned.com/API/v3#PwnedPasswords)
- [OpenFGA — open-source Zanzibar implementation](https://openfga.dev/)
- [WorkOS — SSO + SCIM as a service](https://workos.com/)
- [OWASP ASVS 5.0](https://owasp.org/www-project-application-security-verification-standard/)
- [GDPR Art. 17 — Right to Erasure carve-outs](https://gdpr-info.eu/art-17-gdpr/)
- [PostgreSQL — RLS performance considerations](https://www.postgresql.org/docs/16/ddl-rowsecurity.html)
- [FIDO Alliance — Passkey adoption tracker](https://fidoalliance.org/passkeys/)

## Placeholder Notes

- iOS `GoogleService-Info.plist` per-bundle-id wiring needs macOS
  access; if implementing on Windows, defer iOS setup to a later
  paired session.
- `auth_permission_key_catalog.md` contract doc lands alongside 9.0
  migration; full ~80-key list documented there.
- `runbooks/gdpr_erasure_runbook.md` lands alongside 9.8.
- WorkOS evaluation (9-future-1) requires legal review of WorkOS DPA
  alongside 9.8 compliance work; not part of Phase 9 scope but worth
  flagging for whoever picks it up.
