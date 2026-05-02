# E.3 Walkthrough — Feature flags admin surface (11A.7)

**Slice:** E.3 / 11A.7 (Phase 11A — F&F Operations Console)
**Mode:** `-DemoMode` (admin Flutter Web client + in-memory feature
flags gateway, no live Cloud Run admin proxy required)
**Date:** 2026-05-02

This walkthrough covers the admin click path for the launch Feature
Flags screen: viewing every row in the `feature_flags` catalog,
toggling a standard flag, the destructive confirm-by-typing dialog
for kill switches, the read-only `ff_support` branch, and the
non-admin fail-closed branch. The demo source is opt-in (`-DemoMode`);
production binds the live Firebase admin auth source + HTTP gateway
(`HttpFeatureFlagsAdminGateway`) against the F&F admin Cloud Run
proxy.

## Authority files exercised

- `lib/main_admin.dart` — production binds
  `HttpFeatureFlagsAdminGateway` against
  `--dart-define=ADMIN_PROXY_BASE_URI=...` and wraps
  `AdminConsoleApp` in `AdminConsoleServicesScope` with the
  operator/location, pricing, corpus, integration, and feature flags
  gateways. Demo falls back to the seeded in-memory feature flags
  gateway in `admin_routes.dart`.
- `lib/admin/admin_routes.dart` — Feature Flags route promoted from
  placeholder to live; `AdminConsoleServicesScope` grows a
  `featureFlagsGateway` field and a default in-memory demo seed
  (audit-logs cutover, two KMS rollout lanes, advisor enabled).
- `lib/admin/screens/feature_flags_admin_screen.dart` — the new
  admin surface. List of flag tiles, kind chip (DANGER for
  destructive), scope chip (global / operator / location), value
  badge, last-toggle metadata, Enable/Disable button. Destructive
  flag tap opens a confirm-by-typing dialog
  (`Key('admin_feature_flag_danger_dialog')`) — the Toggle button
  stays disabled until the typed text matches the flag name.
- `lib/admin/models/feature_flags_admin_models.dart` —
  `FeatureFlagAdminRow`, `FeatureFlagToggleCommand`, and the
  locked `kFeatureFlagKindStandard` / `kFeatureFlagKindDestructive`
  constants used by both the UI chip rendering and the proxy
  validation surface.
- `lib/admin/services/feature_flags_admin_gateway.dart` — HTTP +
  in-memory gateway implementations. Toggle POST carries an
  `Idempotency-Key`; the in-memory gateway caches results by key so
  retries collapse to one toggle, mirroring the proxy
  `proxy_requests` UNIQUE constraint.
- `lib/infrastructure/persistence/postgres/repositories/feature_flags_repository.dart`
  — cross-operator `feature_flags` SELECT and toggle UPDATE through
  `withSystem`. The toggle UPDATE keys on `flag_id`, sets
  `enabled` + `updated_by`, and projects the post-update row via
  `RETURNING`.
- `db/migrations/202605020400_phase_11A_7_feature_flags_admin_columns.sql`
  — adds `kind` (NOT NULL DEFAULT `standard`, CHECK in (`standard`,
  `destructive`)), `description`, and `updated_by` columns to
  `public.feature_flags`. Reclassifies the launch flags whose
  semantics are destructive (audit_logs cutover, KMS rollout lanes)
  in the same migration.
- `tool/advisor_proxy/advisor_proxy.dart` — adds the
  `/v1/admin/feature-flags*` route block. CORS preflight uses a
  dedicated `_setAdminFeatureFlagsCorsHeaders` helper (GET + POST +
  OPTIONS, with `Idempotency-Key` in the allow-list). Method-scoped
  role gate: `kFfFeatureFlagsAdminReadRoles` (`super_admin` +
  `ff_support`) for `GET`; `kFfFeatureFlagsAdminWriteRoles`
  (`super_admin` only) for `POST`. Toggle requires `Idempotency-Key`
  and resolves the verified Firebase UID through the shared
  `IntegrationAdminActorResolver` (audit-attribution defense in
  depth).
- `tool/advisor_proxy/proxy_bootstrap.dart` —
  `RepositoryFeatureFlagsAdminProxyGateway` binding wired from
  `FeatureFlagsRepository` + admin-pool `AuthEventsAuditRepository`.
  Toggle writes one `admin.feature_flags.toggle` event via
  `insertSystemEvent`; the cutover fan-out into hash-chained
  `audit_logs` lights up automatically when
  `audit_logs_cutover_enabled` is on.

## Demo identities

Demo auth fixture emails (any password accepted in demo mode); admit
decisions match the 11A.0 / 11A.1 / 11A.2 / 11A.3a / 11A.4
walkthroughs.

| Email                         | Roles            | Admit decision     | Flag toggle |
| ----------------------------- | ---------------- | ------------------ | ----------- |
| `super.admin@forgeflow.test`  | `super_admin`    | Admin shell        | Yes         |
| `support@forgeflow.test`      | `ff_support`     | Admin shell        | No          |
| `operator@forgeflow.test`     | `operator_owner` | Forbidden surface  | n/a         |

The default in-memory feature flags gateway is seeded with four
rows that mirror the launch catalog: `audit_logs_cutover_enabled`
(destructive, on), `kms_real_provider_anthropic_enabled`
(destructive, off), `kms_real_provider_voyage_enabled` (destructive,
off), and `advisor_enabled` (standard, on).

## Click path (text trace)

### Step 1 — Sign in as a demo super-admin

Launch the admin console with `-DemoMode -Device chrome` and sign in
as `super.admin@forgeflow.test`.

**Expected:** branded admin shell renders with the side nav
including a `Feature Flags` item that is now live (no longer the
11A.0 placeholder).

### Step 2 — Open Feature Flags

Click `Feature Flags` in the side nav.

**Expected:**

- Body region renders the new `Feature Flags` surface
  (`Key('admin_feature_flags_screen')`).
- Header reads `Feature Flags` with a one-line subtitle explaining
  destructive flags require confirm-by-typing and every toggle
  writes an audit row.
- The flag list (`Key('admin_feature_flags_list')`) shows four
  tiles, destructive-first then alphabetical:
  * `audit_logs_cutover_enabled` — DANGER chip, GLOBAL chip,
    `value: ENABLED`, description, `updated by demo-super-admin`.
  * `kms_real_provider_anthropic_enabled` — DANGER chip, GLOBAL
    chip, `value: DISABLED`.
  * `kms_real_provider_voyage_enabled` — DANGER chip, GLOBAL chip,
    `value: DISABLED`.
  * `advisor_enabled` — STANDARD chip, GLOBAL chip,
    `value: ENABLED`.

### Step 3 — Toggle a standard flag

Click `Disable` on the `advisor_enabled` tile.

**Expected:**

- No confirmation dialog (standard flags toggle on a single click).
- Toggle button shows a brief spinner while the gateway POST runs.
- SnackBar displays `Flag updated`.
- Tile re-renders with `value: DISABLED`, the new `updated_at`
  timestamp, and the demo super-admin actor in the metadata row.
- The toggle button now reads `Enable`.

### Step 4 — Toggle a destructive flag

Click `Disable` on the `kms_real_provider_anthropic_enabled` tile
(seeded as DISABLED → click reads as `Enable`, but the destructive
gating is symmetric on either direction).

**Expected:**

- The DANGER confirm dialog
  (`Key('admin_feature_flag_danger_dialog')`) opens with title
  `Toggle destructive flag?` and a body explaining that toggling
  changes production runtime behaviour. The exact flag name is
  rendered in monospace below the explanation.
- The `Toggle` button is disabled. Type `wrong_name` into the
  confirm input — the button stays disabled.
- Clear the field and type `kms_real_provider_anthropic_enabled`
  exactly. The `Toggle` button enables.
- Click `Toggle` → dialog closes, SnackBar displays `Flag updated`,
  the tile re-renders with `value: ENABLED` and the new
  `updated_at`.

### Step 5 — Cancel a destructive toggle keeps the prior value

Click `Disable` on the freshly-enabled
`kms_real_provider_anthropic_enabled` tile to reopen the DANGER
dialog. Click `Cancel` without typing.

**Expected:** the dialog closes, no SnackBar appears, no audit row
is written, and the tile still reads `value: ENABLED`. Asserted by
`test/admin/feature_flags_admin_screen_test.dart` test
`destructive cancel keeps the prior value (no toggle fires)`.

### Step 6 — Verify support identity sees read-only Feature Flags

Sign out, sign in as `support@forgeflow.test`.

**Expected:** the admin shell still renders (`ff_support` is admitted
to the console). Click `Feature Flags`. In live mode the screen
issues `GET /v1/admin/feature-flags`, which the proxy admits because
`ff_support` is in `kFfFeatureFlagsAdminReadRoles`. The data renders,
and the screen is in **read-only mode**: the
`View-only: feature flag toggles require the super_admin role.`
banner shows (`Key('admin_feature_flags_readonly_banner')`), and
every `Enable`/`Disable` button renders disabled
(`Key('admin_feature_flag_toggle_disabled_<flag_id>')`). Asserted
by `test/admin/feature_flags_admin_screen_test.dart` test
`editingEnabled = false hides toggle affordance + shows banner`.

Server-side defence-in-depth: any toggle attempt that bypassed the
UI would still be rejected by the write-only gate
(`kFfFeatureFlagsAdminWriteRoles`). Asserted by
`test/services/proxy_feature_flags_routes_test.dart` test
`POST /v1/admin/feature-flags/toggle rejects ff_support (write)`.

### Step 7 — Idempotency replay (proxy contract)

Submit the same toggle POST twice with the same `Idempotency-Key`
header (e.g. via `curl` against the proxy in a live deploy, or via
the in-memory demo gateway's idempotency cache). The proxy stores
the key on `proxy_requests` (UNIQUE) and the in-memory demo gateway
caches the result by key, so the second call returns the cached
post-toggle row without re-toggling. The audit row writes exactly
once. Asserted by `test/admin/feature_flags_admin_gateway_test.dart`
test `idempotency-key replay returns the cached result without
re-toggling`.

### Step 8 — Verify non-admin fail-closed

Sign out, sign in as `operator@forgeflow.test`.

**Expected:** the branded forbidden card renders. The Feature Flags
surface, side nav, and header bar are absent. The same fail-closed
branch covers Operators / Pricing / Corpus / Integrations because
the gate sits above the route catalog.

## Trace summary (text evidence)

```
signin    super.admin@forgeflow.test                       -> admin shell        (PASS)
nav       /feature-flags                                   -> feature flags screen (PASS)
seed      list shows 4 flags, destructive-first ordering   -> 3 DANGER chips, 1 STANDARD (PASS)
toggle    advisor_enabled (standard)                       -> SnackBar, value flips, updated_by stamped (PASS)
danger    kms_real_provider_anthropic_enabled              -> DANGER dialog, button disabled until exact match (PASS)
cancel    DANGER dialog cancel                             -> no toggle, no audit row (PASS — screen test)
proxy     ff_support GET /v1/admin/feature-flags           -> 200 (PASS — proxy test)
proxy     ff_support POST .../toggle                       -> 403 permission_denied (PASS — proxy test)
proxy     POST without Idempotency-Key                     -> 400 missing_idempotency_key (PASS — proxy test)
proxy     POST with no users row for Firebase UID          -> 403 actor_user_not_resolvable (PASS — proxy test)
proxy     POST toggle on missing flag_id                   -> 404 unknown_flag (PASS — proxy test)
ui        ff_support shell -> Feature Flags                -> read-only banner, no toggle (PASS — screen test)
idempot   replay same Idempotency-Key                      -> cached row, no second audit (PASS — gateway test)
signout   header signout                                   -> sign-in card       (PASS)
signin    operator@forgeflow.test                          -> forbidden card     (PASS)
```

## Permission gating evidence

- Client side (admin console): the Feature Flags route is only
  reachable when the auth gate admits the caller (`super_admin` or
  `ff_support`); `operator@forgeflow.test` lands on the forbidden
  card. The screen exposes an `editingEnabled` flag (default
  `true`) that disables every toggle button and renders a
  `View-only: feature flag toggles require the super_admin role.`
  banner; the read-only branch is asserted in
  `test/admin/feature_flags_admin_screen_test.dart`.
- Server side (proxy): every `/v1/admin/feature-flags*` request
  verifies the Firebase bearer token through
  `_resolveVerifiedClaimsOrWrite` and then evaluates a method-
  scoped role set — `kFfFeatureFlagsAdminReadRoles` (`super_admin`
  + `ff_support`) for `GET`, `kFfFeatureFlagsAdminWriteRoles`
  (`super_admin` only) for `POST`. The split lets `ff_support`
  load the read-only flags view live without weakening the toggle
  gate. POST also requires an `Idempotency-Key` and resolves the
  verified Firebase UID into a Postgres `users.user_id` UUID
  before the gateway is touched (audit attribution invariant —
  `auth_events_audit.actor_user_id` is never null when
  `actor_kind = 'user'`). Asserted by
  `test/services/proxy_feature_flags_routes_test.dart`.

## Tests run

- `dart analyze` — clean (`No issues found!`).
- `flutter test test/admin/feature_flags_admin_gateway_test.dart`
  — passes (list ordering, toggle round trip, unknown_flag 404,
  idempotency-key replay).
- `flutter test test/admin/feature_flags_admin_screen_test.dart`
  — passes (kind + scope chip rendering, standard toggle SnackBar,
  destructive confirm-by-typing happy path, destructive cancel,
  read-only mode hides toggle).
- `flutter test test/services/proxy_feature_flags_routes_test.dart`
  — passes (gateway absent → 503, operator_owner GET 403,
  ff_support GET 200, ff_support POST 403, missing Idempotency-Key
  400, actor resolver round-trip, actor_user_not_resolvable 403,
  unknown_flag 404, OPTIONS preflight admits POST + Idempotency-Key
  header).
- `flutter test test/repositories/feature_flags_repository_test.dart`
  — passes (listFlags ordering + audit marker + role elevation,
  findById parameter binding, findById returns null when row is
  missing, toggleFlag UPDATE shape + parameters, toggleFlag returns
  null when no row matches).

## Boundary checks

- No Phase 9 operator Settings/Team/MFA/org hierarchy files were
  touched. `lib/screens/auth/`, `lib/screens/settings*`,
  `lib/screens/team/`, and `lib/auth/` are unchanged.
- No Phase 8 / 8.5 / 9.8 connector code is wired.
- The 11A.1 admin operator/location surface
  (`/v1/admin/operators`, `/v1/admin/locations`), the 11A.2 pricing
  surface (`/v1/admin/pricing/*`), the 11A.3a corpus surface
  (`/v1/admin/corpus/*`), and the 11A.4 integrations surface
  (`/v1/admin/integrations*`) are untouched. The new feature flags
  routes live on a disjoint path prefix
  (`/v1/admin/feature-flags*`) and do not reorder any existing
  route handlers.
- `admin_routes.dart` only adds the Feature Flags route, the
  `featureFlagsGateway` field on `AdminConsoleServicesScope`, the
  `featureFlagsGatewayOf` accessor, and the
  `_defaultFeatureFlagsDemoGateway` seed. The existing route
  catalog ordering is preserved (Feature Flags slots between
  Integrations and Debug).
- `main_admin.dart` only wires the feature flags gateway into
  `AdminConsoleServicesScope`; the existing fail-closed live
  wiring, Firebase admin auth, and demo-mode behaviour are
  preserved.
- `tool/advisor_proxy/advisor_proxy.dart` only adds
  `/v1/admin/feature-flags*` constants, dispatch, validation,
  CORS, and the gateway interface. Existing routes are untouched.
- `tool/advisor_proxy/proxy_bootstrap.dart` only binds the new
  feature flags repository / gateway into production bindings;
  auth, operator/location, pricing, corpus, and integrations
  bindings are untouched.
- The `feature_flags` migration adds three columns and one CHECK
  constraint with `if not exists` / `drop constraint if exists`
  guards; re-applying the migration after an operator override of
  `kind` does not bounce the override (the destructive seed UPDATE
  uses `where kind <> 'destructive'`).
- Plaintext flag values are not secrets — the table holds gating
  bits and operator-facing copy only — so the response payload
  returns the row JSON as-is. The repository never redacts.
- Toggle audit: the write goes through
  `AuthEventsAuditRepository.insertSystemEvent` with
  `event_type = 'admin.feature_flags.toggle'`. The fan-out into
  hash-chained `audit_logs` is gated by the existing
  `audit_logs_cutover_enabled` flag (B.2) — when on, every toggle
  emits one row in `auth_events_audit` and one row in
  `audit_logs`; when off, only `auth_events_audit`. The toggle
  payload carries `flag_id`, `flag_name`, `enabled`, `kind`, and
  `idempotency_key` so a forensic readout can reconstruct the
  exact intent without joining tables.
- The shared `IntegrationAdminActorResolver` is reused on the
  toggle path — F&F admins live outside any operator's tenant
  scope, so the verified Firebase UID resolves to a Postgres
  `users.user_id` UUID (or 403 `actor_user_not_resolvable` when no
  active row matches). Reads (GET list) skip the resolver because
  no audit row is written.
- `AdminConsoleServicesScope` is now mounted in both demo and
  live modes from `main_admin.dart` so the route builder always
  has access to the `AdminAuthSource` for role-based UI gating.
- No tracker updates and no commits.
