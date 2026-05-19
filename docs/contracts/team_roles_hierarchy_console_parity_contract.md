# Team / Roles / Hierarchy / Sessions / Audit / Security — Console Parity Contract

**Status:** Active. Lands with the Self-Service Parity block (`11W.1`–`11W.6`) and the Cross-Operator Parity block (`11A.12`/`13`/`14`).
**Last updated:** 2026-05-05
**Authority order:** This contract binds both the Operator Web Console (Phase 11W) and the F&F Operations Console (Phase 11A) to the existing mobile Settings end-to-end behavior. The canonical sources of truth this contract preserves are: the mobile Settings sections in `lib/screens/settings/`, the team controllers in `lib/services/team/`, the auth gateway interfaces in `lib/services/auth/`, the proxy route handlers in `tool/advisor_proxy/advisor_proxy.dart` (Phase 9 + 11A.1 routes), and the permission-key catalog in `docs/contracts/auth_permission_key_catalog.md`. This doc must stay in sync with those.

## Why this contract

Six self-service Settings surfaces (Team / Roles / Hierarchy / Sessions / Audit / Security) ship simultaneously into two new web consoles after living on mobile only. The risk is that nine parallel slices each interpret "parity" slightly differently — different filter sets, different idempotency keys, different audit-row shapes, different validation copy, different error mapping — and the result is two consoles that look right but quietly diverge from the mobile behavior operators already know.

The contract enforces a single end-to-end behavior across all three surfaces (mobile, operator web, admin web) by binding every parity slice to:

- the same proxy routes (operator self-service vs F&F admin path differs only in the URL prefix and the gating key set)
- the same idempotency-key strategy
- the same audit-row shape and `created_by` / `updated_by` population rule
- the same permission-key gates per action
- the same validation copy for fields shared with mobile
- the same filter set, sort order, and pagination shape on every list view
- the same demo-mode fixture data so walkthroughs are reproducible across consoles

## Core promise

A team member who can do action X on the mobile Settings screen can do action X with identical effect on the Operator Web Console screen for the same surface. An F&F support user who can do action X on the F&F Operations Console for a chosen operator produces an audit-row that is indistinguishable from a mobile/web-self-service audit-row except for the actor identity, the `admin_reason` field, and the `audit_logs.actor_kind = 'forge_admin'` marker.

The interface is a translator, not a different product (per `docs/frameworks/UX_ADJUSTMENT_FRAMEWORK.md` golden rule).

## Surface map (binding)

Each row is a parity surface. All three consoles must satisfy the same proxy / audit / permission posture for that surface.

| Surface | Mobile section | Operator Web slice | F&F Admin slice | Operator self-service routes | F&F admin routes |
|---|---|---|---|---|---|
| Members + Invites | `lib/screens/settings/settings_data_sections.dart` (Team Settings + invite flow) | `11W.1` Members | `11A.12` Members + Invites parity | `/v1/auth/team/users` + `/v1/auth/team/invites` | `/v1/admin/auth/users` + `/v1/admin/auth/invites` |
| Roles + Permission Explainer | `lib/screens/settings/settings_custom_roles_section.dart` + `settings_permission_explainer.dart` + `settings_role_editor.dart` | `11W.2` Roles | `11A.13` Roles + Hierarchy + Sessions inspect (Roles tab) | `/v1/auth/team/roles` + `/v1/auth/team/role-grants` | `/v1/admin/auth/roles` + `/v1/admin/auth/role-grants` |
| Hierarchy (org units + locations) | `lib/screens/settings/settings_org_hierarchy_section.dart` | `11W.3` Hierarchy | `11A.13` Roles + Hierarchy + Sessions inspect (Hierarchy tab) | `/v1/auth/team/org-units` + `/v1/auth/team/locations/:id` | `/v1/admin/auth/org-units` + `/v1/admin/auth/locations/:id` |
| Sessions | `lib/screens/settings/settings_active_sessions_section.dart` | `11W.4` Sessions | `11A.13` Roles + Hierarchy + Sessions inspect (Sessions tab) | `/v1/auth/sessions` + `/v1/auth/session/revoke` + `/v1/auth/team/sessions` | `/v1/admin/auth/sessions` |
| Audit Log | `lib/screens/settings/settings_audit_log_section.dart` | `11W.5` Audit Log | `11A.14` Audited support actions (Audit log tab) | `/v1/auth/audit-log` | `/v1/admin/auth/audit-log` + `/v1/admin/auth/audit-log/export` |
| Security (MFA + password + login history) | `lib/screens/settings/settings_mfa_section.dart` | `11W.6` Security | `11A.14` Audited support actions (Actions panel) | `/v1/auth/mfa/*` + `/v1/auth/password/*` | `/v1/admin/auth/users/:id/mfa/*` + `/v1/admin/auth/users/:id/password/*` |

If a future slice needs a route not in this table, the parity contract is incomplete — update this table and the consuming slice prompt before implementation.

## Hard Rule W3.A — mobile Settings is an intentional read-only mirror

**The mobile Settings screen is a deliberate read-only mirror of the
operator-web settings/identity/team/security surface. Operator Web
(and, on the support path, the F&F Operations Console) owns every write
path for the surfaces in the table above. This is a PRODUCTION posture,
not a demo-mode carve-out and not a gap.**

The mobile sections collapse to a read/summary view and unconditionally
suppress their mutation affordances. The suppression is hardcoded — not
gated on `kDemoMode`, not branched on environment — so demo and prod
behave identically (consistent with `CLAUDE.md` Demo Mode "Default = NO
branch"). The verified suppressions, with the owning write surface for
each:

| Mobile site (verified) | Suppression | Write owned by |
|---|---|---|
| `lib/screens/settings_screen.dart:33`, `:206-208`; `lib/forge_flow_app.dart:1347-1349` | Settings collapsed to 3 read-only tabs (Account / Setup / Data); Team / Diagnostics / Advisor tabs removed | Operator Web (Team management); Operator Web + F&F admin (advisor admin) |
| `lib/screens/settings_screen.dart:600-608` | Data-alignment section gated to `super_admin` / `ff_support` only; removed from operator (owner/manager) Data tab | F&F Operations Console (support path) |
| `lib/screens/settings/settings_wage_authority_section.dart:24-27` (wired `viewOnly: true` at `settings_screen.dart:379-382`) | Wage editor button suppressed; read-only summary only | Operator Web (`lib/operator_web/screens/wage_authority_screen.dart` — wage role rows) |
| `lib/screens/settings/settings_mfa_section.dart:84-87` (wired `viewOnly: true` at `settings_screen.dart:477-486`) | Enrolled-factor list rendered read-only; enrollment + removal hidden | Operator Web (`11W.6` Security, `/v1/auth/mfa/*`) |
| `lib/screens/settings/settings_active_sessions_section.dart:155-158` (wired `viewOnly: true` at `settings_screen.dart:529-540`) | Every revoke / sign-out affordance hidden; session list with last-active timestamps still shown | Operator Web (`11W.4` Sessions, `/v1/auth/sessions` + `/v1/auth/session/revoke`) |
| `lib/screens/settings/settings_data_sections.dart:469-478`, `:699-711` (wired `viewOnly: true` at `settings_screen.dart:504-510`) | Password-change form + bulk sign-out hidden; account-info summary + sign-out-this-device fallback only; `SettingsPointerRow` deep-links to operator-web My Account | Operator Web (`/v1/auth/password/*`, My Account via JWT-handoff) |
| `lib/screens/settings/settings_timing_authority_section.dart:110-118` | Timing authority rendered view-only on mobile | Operator Web |
| `lib/screens/settings/settings_pointer_row.dart:1-8` | Mobile sections that used to host edit affordances end with a pointer row deep-linking to the matching operator-web surface | Operator Web |

**Rationale.** Mobile is the read-mostly single-location operational
tool (see Hard Rule 9 in
`docs/contracts/mobile_core_business_scope_contract.md`). Settings,
identity, team, and security mutations are owned by the Operator Web
Console, with the F&F Operations Console as the support path. This keeps
a single authoritative write surface per the Core promise above ("a team
member who can do action X on the mobile Settings screen can do action X
with identical effect on the Operator Web Console screen for the same
surface") rather than forking write flows across three clients.

**Posture, not a gap.** This mirror is a deliberate PRODUCTION design
decision. It is NOT a `kDemoMode` carve-out (the suppression is
unconditional, with no demo branch) and NOT an incomplete or backend-only
capability — the write paths exist and are fully exposed on Operator Web
/ F&F admin per the § Surface map. It satisfies `CLAUDE.md` Hard Promise
#10 (every backend phase ships operator-facing UX before phase close —
the UX ships on Operator Web / F&F admin, mirrored read-only on mobile)
and is the mobile companion to Hard Promise #11's "or document why the
capability is backend-only/gated/incomplete" clause, the same clause
exercised by Hard Rule 9 in `mobile_core_business_scope_contract.md`.

**Change control.** Removing or altering the mirror — bringing any of the
suppressed write affordances onto mobile — is a deliberate scope decision
that requires an update to this contract (and re-evaluation of the Core
promise + § Surface map) before implementation, not an ad-hoc code
change. The W3.A code comments at the sites above are descriptive; this
rule is the binding source.

## Backend route invariants (must hold across all three surfaces)

These invariants are already enforced by the Phase 9 + 11A.1 proxy code. Slice prompts must NOT introduce new routes that break them.

### Operator self-service vs F&F admin path

- **Operator self-service** (`/v1/auth/*` family) gates on `team.*` permission keys (per `auth_permission_key_catalog.md` § `team.*`). The proxy resolves the calling user's `(operator_id, location_scope)` from the session JWT and scopes every read/write to that operator. RLS is the backup defense; the primary defense is the proxy clamping `operator_id` from the session before query construction.
- **F&F admin path** (`/v1/admin/auth/*` family) gates on `admin.*` permission keys (per `auth_permission_key_catalog.md` § `admin.*`). The proxy admits only `super_admin` and `ff_support` Firebase tokens and uses the `forge_admin` Postgres role for `BYPASSRLS`. Every admin-path call requires an explicit `operator_id` query parameter (or path segment) — there is no implicit operator selection on the admin path.

The two paths produce **identical canonical fact rows**. They differ only in the actor identity recorded on `audit_logs.actor_kind` (`team_member` vs `forge_admin`) and the additional `admin_reason` field required on every admin-path mutation.

### Idempotency keys

Every mutation across both paths carries an `Idempotency-Key` request header. The minting rule is owned by the screen layer (matches `_OperatorLocationAdminScreenState._nextIdempotencyKey` from 11A.1) — one key per user action, propagated through the dialog → command → gateway path. The proxy stores keys in `proxy_requests` (UNIQUE constraint per `docs/contracts/migrations_summary.md`); replay returns the original 2xx response with no second write.

Slices must NOT mint a new key inside the gateway; doing so double-mints for the same user action and breaks idempotency replay.

### Audit-row shape

Every mutation writes one `audit_logs` row with:

- `audit_logs.operator_id` — target operator
- `audit_logs.actor_user_id` — calling user UID
- `audit_logs.actor_kind` — `team_member` for `/v1/auth/*` calls, `forge_admin` for `/v1/admin/auth/*` calls, `service_principal` for `sp:`-prefixed JWTs
- `audit_logs.action` — locked enum, e.g. `team.users.invite`, `team.roles.create_custom`, `team.session.force_logout`, `team.org_unit.move`, `auth.mfa.enroll`, `auth.password.change`
- `audit_logs.target_kind` + `audit_logs.target_id` — entity touched
- `audit_logs.payload` — JSONB diff snapshot (before/after for patches, full row for creates, target id only for deletes)
- `audit_logs.admin_reason` — REQUIRED for `actor_kind = 'forge_admin'`; NULL otherwise
- `audit_logs.business_date` — denormalized restaurant-local business date per `docs/contracts/phase_7_55_time_boundary_contract.md`
- `audit_logs.row_hash` — SHA-256 chain link per B27 hash-chain

The hash chain is integrity-critical. Slices must NOT bypass the hash-chain producer; every write goes through the standard `audit_logs` insert path.

### Created_by / updated_by population

Every fact-table write populates `created_by` (insert) or `updated_by` (update) with the calling user's UID. This is non-negotiable per the Phase 11A non-negotiables (`audit_logs` is queryable; `created_by`/`updated_by` is on every row). For F&F admin writes, populate with the F&F admin's UID — do NOT impersonate the operator user.

## Per-surface parity rules

### Members + Invites (`11W.1` + `11A.12`)

**Filter set (locked):** `status` ∈ {`active`, `suspended`, `dormant_30`, `soft_deleted`} • `role_key` ∈ catalog • `location_id` ∈ visible locations per `team_scope_visibility_policy` • `mfa_enrolled` ∈ {true, false, null} • `search` (free-text on email + display_name).

**Pagination:** Cursor-based, 50 rows per page, sorted by `last_active_at DESC` then `email ASC`. `next_cursor` opaque string.

**Row actions (operator self-service, gated on `team.users.*`):** `Suspend`, `Reactivate`, `Soft delete`, `Reset password` (sends email), `Reset MFA` (delayed-removal flow per `team.users.reset_mfa`), `Force logout`. Soft-deleted rows show `Restore` action gated on the **admin path only** — operator self-service cannot restore.

**Row actions (F&F admin, gated on `admin.users.*`):** all of the above plus `Restore soft-deleted`, `Override role grant` (requires `admin_reason`), `Issue paired-approval erasure` (`admin.users.erase_pii`, MFA-required).

**Invite flow:** Single-step form (email + display_name + role_key + primary_location_id + optional org_unit_id + optional welcome_note). Server validates email uniqueness within operator, mints invite token, sends email via SendGrid (per Phase 9.8). Idempotency key per submission. Client must allow re-submission with the same idempotency key (returns the original invite row, no duplicate email).

**Validation copy (locked, identical across surfaces):**
- Empty email → "Email address is required."
- Malformed email → "Enter a valid email address."
- Email already in operator → "This email is already on the team. Edit the existing member instead."
- Missing role → "Choose a role for this member."
- Missing location → "Choose a primary location for this member."

### Roles + Permission Explainer (`11W.2` + `11A.13` Roles tab)

**Catalog source:** `docs/contracts/auth_permission_key_catalog.md` is the rendered source. Every key listed there must appear in the Permission Explainer; nothing else may. The Explainer renders 9 categories in this exact order: `product.*` → `forgeflow.*` → `barrio.*` → `admin.*` → `team.*` → `billing.*` → `integration.*` → `integrations.*` → `workflow.*`.

**Seeded roles:** `super_admin`, `ff_support`, `operator_owner`, `operator_manager`, `operator_supervisor`, `operator_staff`. All render with `is_editable=false` enforced server-side. Operator self-service surface shows seeded roles read-only with no edit button. F&F admin surface shows seeded roles read-only by default; edit button gated on `admin.roles.edit_seeded` (MFA-required) opens an editor.

**Custom-role builder:** Operator self-service via `team.roles.create_custom`. F&F admin via `admin.roles.create_custom`. Builder UX: name + description + permission picker (multi-select tree organized by category). Server enforces frozen catalog — keys outside `PermissionKeys.all` are rejected with `validation_failed/permission_key_unknown`. Custom-role rows carry `operator_id` (operator-scoped); F&F-admin-created custom roles carry the target operator's ID, not NULL.

**Permission Explainer copy:** Use the `description` text from the catalog verbatim. Do NOT paraphrase. If a description is unclear, fix it in the catalog (and the migration + `lib/auth/permission_keys.dart`) — do NOT silently improve copy in the UI.

**MFA-required keys:** Render with a 🔒 chip (or text equivalent — no emoji-only signals per accessibility) and the tooltip "Requires multi-factor authentication."

### Hierarchy (`11W.3` + `11A.13` Hierarchy tab)

**Tree shape:** `org_units` form an n-ary tree per operator. `locations` are leaves attached to a single `org_unit_id`. Roots are `org_units` with `parent_org_unit_id IS NULL`.

**Move semantics:** Moving a location updates `locations.org_unit_id`; moving an org-unit updates `org_units.parent_org_unit_id`. Both are gated on `team.roles.assign` (operator self-service) or `admin.users.create` analog (F&F admin) per the hierarchy-touches-grants posture in `phase_9_auth_plan.md`. Moves are audited.

**Rename semantics (GAP A1):** Renaming an org-unit updates ONLY the display `org_units.name` column — the ltree `path`/label and the `unique(operator_id, path)` + single-root invariants are untouched, so there is no descendant rewrite and no DB migration. Rename is a supported operation across operator-web self-service (`PATCH /v1/auth/team/org-units/:id/name`) and the F&F admin path (`PATCH /v1/admin/auth/org-units/:id/name`), at full parity, same gating posture as create/move (`team.roles.assign` self-service; `admin.users.create` analog for F&F admin). The corp root IS renameable (it is the operator-facing Business label) behind the same write key. `audit_logs.action = 'team.org_unit.rename'`; `payload = {before:{name}, after:{name}}`; `target_kind = 'org_unit'`, `target_id = :id`. Self-service rename carries NO `admin_reason` (consistent with self-service create/move) and `actor_kind = 'team_member'`; the F&F admin rename path REQUIRES a non-blank `admin_reason` and writes `actor_kind = 'forge_admin'` (the admin route rejects a missing reason before any write). Duplicate-name-within-parent is re-validated server-side AND client-side with the locked copy below. Idempotency-Key is minted at the screen layer and forwarded; the proxy stores it in `proxy_requests` (UNIQUE) and a replay returns the original 2xx; gateways never mint keys.

**Org-unit DELETE exposure (operator decision 2026-05-16):** Operator self-service surfaces (operator-web + mobile) MUST NOT expose org-unit DELETE. Org-unit delete is F&F-admin-only, by operator decision 2026-05-16. (Rename IS exposed to operator self-service.) This records a deliberate product decision, not a gap.

**Display order:** Children sorted alphabetically by `name`. Locations sorted alphabetically by `name` within their org-unit.

**Read-only audiences:** Floor managers (`location_manager`) and `operator_supervisor` see read-only hierarchy. Mutate buttons hidden; tree expand/collapse stays interactive.

**Validation copy (locked):**
- Empty org-unit name → "Org unit name is required."
- Duplicate org-unit name within parent → "An org unit with this name already exists in this group." (applies to create AND rename)
- Move would create cycle → "Cannot move into a child of itself."

### Sessions (`11W.4` + `11A.13` Sessions tab)

**List shape:** One row per `auth_sessions` row (Phase 9.0Σ session ledger). Columns: device fingerprint (browser + OS string), IP/geo hint (city-level only, never raw IP), `last_active_at`, `is_this_session` chip (operator self-service only), `Revoke` action.

**Operator self-service surface (`/v1/auth/sessions`):** Shows the actor's own sessions by default. If the actor holds `team.session.force_logout`, a `Team sessions` toggle exposes every team-member session within scope.

**F&F admin surface (`/v1/admin/auth/sessions?operator_id=...`):** Shows every session for every user in the operator. `Revoke` requires `admin_reason`. Force-logout writes `audit_logs.action = 'admin.session.force_logout'` with target user UID + session ID.

**Revoking the current session:** Operator self-service: after the proxy returns 200, the gateway calls `signOut()`. F&F admin: cannot revoke own admin session via this surface (server returns `validation_failed/cannot_revoke_self`); use admin sign-out instead.

### Audit Log (`11W.5` + `11A.14` Audit log tab)

**Source:** `audit_logs` table, scoped per query (operator self-service auto-clamps `operator_id`; F&F admin requires explicit `operator_id` query param).

**Filter set (locked):** `actor` ∈ {user picker} • `action` ∈ enum (multi-select) • `target_kind` ∈ enum • `target_id` (free text, copyable from row) • `time_window` ∈ {last 24h, last 7d, last 30d, last 90d, custom range} • `actor_kind` ∈ {`team_member`, `forge_admin`, `service_principal`} (F&F admin surface only).

**Pagination:** Cursor-based, 200 rows per page (per Performance Framework cap), sorted by `created_at DESC`. `next_cursor` opaque string.

**Row rendering:** `created_at` (operator-local timezone per `phase_7_55_time_boundary_contract.md`), actor (display_name + email + actor_kind chip), action (humanized — `team.users.invite` → "Invited team member"), target (target_kind + target_id with copy button), `View payload` toggle (collapsed JSONB diff). For `forge_admin` rows, also render the `admin_reason` field inline.

**CSV export (gated on `team.audit_log.export` for self-service, `admin.audit_log.export` for admin):** Server-side rendering, signed URL, 1-hour TTL. Export job writes its own audit row (`audit.export.requested`) so exports themselves are auditable.

### Security (`11W.6` + `11A.14` Actions panel)

**Operator self-service (`11W.6`):**
- MFA factors list (TOTP / SMS / authenticator-app) with per-factor status (`active`, `pending_enrollment`, `pending_removal`, `removed`)
- Enroll factor → `/v1/auth/mfa/totp/begin` then `/v1/auth/mfa/totp/confirm`
- Revoke factor → `/v1/auth/mfa/factors/revoke` (24-hour delayed removal per `team.users.reset_mfa` posture)
- Cancel pending removal → `/v1/auth/mfa/factors/removal/cancel`
- Recovery request → `/v1/auth/mfa/recovery/request`
- Change password → `/v1/auth/password/change` (requires current-password reverification)
- Login history → subset of `/v1/auth/audit-log` filtered to `auth.session.*` + `auth.password.*` + `auth.mfa.*` events, last 90 days

**F&F admin (`11A.14` Actions panel):**
- Reset member MFA → admin path with `admin_reason`; gated on the new `admin.users.reset_mfa_factors` key (must be added to the catalog as part of `11A.14`)
- Initiate password reset → admin path; sends email via SendGrid; gated on `admin.users.reset_password`
- Issue paired-approval erasure → admin path; gated on `admin.users.erase_pii` (MFA-required); paired-approval workflow with second admin confirmation

**Validation copy (locked):**
- Wrong current password → "Current password is incorrect."
- Password too weak → "Password must be at least 12 characters with one number and one symbol."
- Password matches a previous password → "You can't reuse a recent password. Choose a new one."
- TOTP code invalid → "That code didn't match. Try again with the next code from your authenticator."

## Web-compatibility rules

Slices must NOT import `dart:io` or `sqflite` / `sqflite_common_ffi` from any file reachable from `lib/main_operator_web.dart` or `lib/main_admin.dart` entry points. The mobile gateway implementations in `lib/services/auth/proxy_*.dart` use `dart:io` `HttpClient` and are mobile-only — web slices must build new gateway implementations under `lib/operator_web/services/` (or `lib/admin/services/` for 11A) using `package:http`.

The abstract gateway interfaces in `lib/services/auth/*_gateway.dart` (e.g., `AuthOperationsGateway`, `AccountInfoGateway`, `PasswordChangeGateway`) are pure-Dart and reusable. Re-implement against `package:http` — do NOT extend the dart:io implementations.

The team controllers in `lib/services/team/` (`TeamUsersListController`, `TeamInviteFormController`, `TeamScopeVisibilityPolicy`) are `ChangeNotifier`-based pure logic and import only `package:flutter/foundation.dart`. Reuse verbatim.

The mobile Settings section widgets in `lib/screens/settings/` are mostly web-compatible (they import `package:flutter/material.dart` + `package:provider/provider.dart` + abstract gateways + theme). They MAY be lifted into a shared widget location IF the lift is purely additive (no behavior change, no breaking of existing mobile imports). If lift requires mobile-specific behavior to be split out, build the web version separately and leave mobile as-is — do NOT refactor mobile to fit web.

## Demo-mode fixtures

Each parity slice ships an in-memory demo gateway under `lib/operator_web/services/demo_*.dart` (or `lib/admin/services/demo_*.dart`) that mirrors the abstract gateway interface and returns walkthrough-friendly fixture data. The fixture data set is **shared across all six 11W slices** so a demo session can navigate `/members → /roles → /locations → /sessions → /audit-log → /security` without seeing inconsistent state.

Shared fixture data lives at `lib/operator_web/services/demo_team_fixtures.dart` (created in `11W.1`, extended by `11W.2`–`11W.6`). The fixture set:

- 1 demo operator (`Demo Bistro`)
- 3 locations (`Downtown`, `North Loop`, `Riverside`)
- 2 org-units (`East Region` containing Downtown + North Loop; `West Region` containing Riverside)
- 6 demo users covering each seeded role (`super_admin` excluded — no super_admin walkthrough)
- 1 custom role (`Floor Captain`) with a 4-permission subset
- 4 active sessions (mobile + web for the operator_owner, mobile only for the others)
- ~50 audit-log entries across the last 30 days covering invite / role-grant / password-change / mfa-enroll / session-revoke actions

Demo gateways MUST NOT mutate this fixture data permanently between sessions — the walkthrough must be reproducible across runs. Mutations during the walkthrough are session-local and reset on next page load.

## Permission gate cheat sheet

Console-level gate: `console.web` (operator self-service) or `super_admin` / `ff_support` Firebase claim (F&F admin). Sub-screen gates layer on top.

| Surface | Self-service read | Self-service write | Admin read | Admin write |
|---|---|---|---|---|
| Members list | `team.users.view` | `team.users.invite` / `.deactivate` / `.reactivate` / `.soft_delete` / `.reset_password` / `.reset_mfa` | `admin.users.view` | `admin.users.create` / `.deactivate` / `.reactivate` / `.soft_delete` / `.reset_password` / `.reset_mfa_factors` |
| Roles list | `team.roles.view` | `team.roles.create_custom` / `.assign` / `.revoke` | `admin.roles.view` | `admin.roles.create_custom` / `.delete_custom` / `.assign` / `.revoke` / `.edit_seeded` (MFA) |
| Hierarchy | `team.users.view` (org-unit visibility piggybacks on user-list scope) | `team.roles.assign` | `admin.users.view` | `admin.users.create` analog |
| Sessions | `team.users.view` (own only) | `team.session.force_logout` (team-wide) | `admin.users.view` | `admin.session.force_logout` |
| Audit Log | `team.audit_log.view` | (read-only) | `admin.audit_log.view` | `admin.audit_log.export` |
| Security | (own user always) | (own user always; current-password reverification per write) | (own user) | `admin.users.reset_mfa_factors` (NEW) / `admin.users.reset_password` / `admin.users.erase_pii` (MFA) |

Floor managers (`location_manager`) get read-only Members + Roles + Hierarchy via `team.users.view` + `team.roles.view`; no write keys.

## Acceptance gates per slice

Per `docs/CODEX_PROMPT_GENERATION_STANDARD.md` and `docs/contracts/slice_runtime_acceptance_contract.md`:

1. **Code on branch** — slice files match the Files-this-slice-owns list in the phase doc; no scope drift.
2. **Web-compatibility verified** — `flutter build web -t lib/main_operator_web.dart --dart-define=OPERATOR_WEB_DEMO_AUTH=true --pwa-strategy=none` (or `lib/main_admin.dart` + `ADMIN_DEMO_AUTH=true`) succeeds on the slice branch with no `dart:io` / `sqflite` import error.
3. **Parity contract satisfied** — every relevant rule in this contract is met. The slice prompt's Acceptance Criteria section MUST cite the specific § headings from this contract that the slice satisfies (e.g., "§ Members + Invites (11W.1 + 11A.12) filter set, validation copy, idempotency, audit-row shape").
4. **Demo-mode walkthrough captured** at the click-path bar set by `docs/archive/_walkthroughs/7.58.UX.5.md`. Walkthrough lives at `docs/_walkthroughs/<slice-id>.md`.
5. **Tests pass:** `flutter analyze --fatal-infos <touched-paths>` + `flutter test test/operator_web/<slice>_test.dart` (or `test/admin/<slice>_test.dart`) + at least one widget test asserting the parity contract's filter set + validation copy + permission gate.
6. **No new backend routes** — every read/write hits a route already shipped by Phase 9 + 11A.1, except `11A.14` which adds the `admin.users.reset_mfa_factors` permission key via additive migration. If a slice prompt needs a new route, the parity contract is incomplete — STOP and update this contract first.
7. **Cross-console parity check** — for each surface in the table at § Surface map, both the 11W slice and the corresponding 11A slice ship and pass acceptance before either is merged. The pair lands together.

## Anti-patterns

- A slice that builds a new HTTP client instead of re-implementing the existing abstract gateway interface against `package:http`.
- A slice that mints a new idempotency key inside the gateway instead of accepting one from the screen.
- A slice that paraphrases the catalog `description` text in the Permission Explainer.
- A slice that adds a new filter to one console's list view without adding the same filter to the other console.
- A slice that diverges validation copy between mobile and web for the same field.
- A slice that imports `dart:io` from a file reachable from `lib/main_operator_web.dart`.
- A slice that bypasses the audit-log hash-chain producer by writing `audit_logs` rows directly.
- A slice that ships a new backend route without updating this contract first.
- An F&F admin slice that writes mutations without populating `admin_reason`.
- A pair (`11W.x` + `11A.y`) where one ships and the other defers — the pair lands together or both stay active.
