# Phase 11W: Operator Web Console

Updated: 2026-05-05 (Members/Roles/Hierarchy/Sessions/Audit/Security un-deferred; sequenced after Phase 7 + Phase 10 close per `project_role_hierarchy_web_migration_sequencing.md`)
Status: Active. V1 launch ships 3 slices (`11W.0` shell, `11W.7` Account, `11W.8` Vendor connections mount). Six self-service Settings parity slices (`11W.1` Members, `11W.2` Roles, `11W.3` Hierarchy, `11W.4` Sessions, `11W.5` Audit Log, `11W.6` Security) are un-deferred and queued to start after Phase 7 + Phase 10 close. `11W.9` Outbound Integrations remains deferred while Phase 8.5 is paused.
Owner: Operator web lane

## Why this exists

Forge & Flow's role/permission/operator/location/team-management foundation is built (Phase 9 backend + mobile Settings UX; Phase 11A foundation for F&F-internal admin). Two structural gaps remain:

1. **Operators have no dedicated web console.** Mobile Settings exposes Team / Roles / Hierarchy / Sessions / Audit Log / MFA, but heavier business-management workflows (custom-role design, multi-location org tree edits, integration management, business setup) are too thick for mobile.
2. **The F&F Operations Console** (Phase 11A) does not yet have full inspect/edit visibility into the operator-managed data it can already create. Adding member visibility, custom-role configuration views, and audited support edits is queued as `11A.12` / `11A.13` / `11A.14` — un-deferred 2026-05-05 to ship in lockstep with the `11W.1`–`11W.6` block. See Phase 11A plan.

Phase 11W fills the operator-side gap by shipping a desktop-first web back office. Mobile Settings stays as the lightweight read-mostly access point. Web becomes the primary surface for setup, administration, and heavier role/location/member management.

## Audience and Boundary

- **Audience.** Operator's senior roles only — `operator_admin` / `operator_owner` (GM / Owner level). Floor managers (`location_manager`) get read-only access to a subset; staff roles do not see this console at all.
- **Boundary.** Single-operator scope. RLS via `OperatorScopedRepository` enforces — an operator_admin sees only their own operator's data. The console does not expose cross-operator views; that's the F&F Operations Console (Phase 11A).
- **Auth.** Existing Phase 9 session + role gates. Same Firebase Auth login as mobile; web shell adds a "Continue on web" path from a logged-in mobile session via QR / magic link.
- **Hosting.** Separate Cloud Run service from operator app proxy + F&F admin console. URL: `app.forgeflow.app` or `console.forgeflow.app` (decision deferred to Wave A).
- **Tech stack.** Flutter for Web off the same codebase as the operator app (`lib/main_forgeflow.dart`). Reuses `lib/theme/app_theme.dart` for brand consistency. Operator-scoped routes only; admin/cross-operator routes deliberately absent.

## Scope

Phase 11W owns:

- Web console shell (auth, navigation, branding, responsive layout).
- Web parity for every mobile Settings screen that has a heavier desktop equivalent.
- Hosting the Vendor Connections widget (built by Phase 8 `8.0`) within the operator-scoped shell.
- Hosting the Outbound Integrations widget (built by Phase 8.5) within the operator-scoped shell.
- A "Continue on web" handoff from mobile to web (QR-code or magic-link based).

Phase 11W does **not** own:

- The vendor-connections widget or outbound-integrations widget themselves (Phase 8 `8.0` and Phase 8.5 build them; 11W just hosts).
- Cross-operator inspect/edit (Phase 11A `.12`/`.13`/`.14`).
- The advisor / Coach / Workflow Platform UX (Phase 11b / 12 — operator-app only at V1, web-host TBD).
- Mobile Settings parity for screens that don't need a desktop counterpart (e.g., notification preferences stay mobile-only).
- New backend surfaces (everything reuses Phase 9 + Phase 11A backend routes; widget reads/writes go through existing Cloud Run admin/operator endpoints).

## Sub-Slice Sequence

The V1 launch block ships 3 slices (`11W.0`/`11W.7`/`11W.8`). The Self-Service Parity block (`11W.1`–`11W.6`) starts after Phase 7 + Phase 10 close, scheduled in parallel with `11A.12`/`13`/`14` per the cross-operator parity plan. The framework in `11W.0` is built so adding parity slices is purely additive: new route, new screen, no architectural change.

### `11W.0` Web console shell

Flutter for Web bootstrap at `lib/main_operator_web.dart` (separate web entry point, not a web build of `lib/main_forgeflow.dart`; incompatibility verified 2026-05-03 because the operator app uses `dart:io` and SQLite extensively for offline mobile caching). Brand styling shared with operator app via the same `lib/theme/app_theme.dart`. Route shell. Phase 9 session gate. Magic-link landing for the onboarding-welcome flow (operator sets password, enrolls MFA, accepts T&Cs). Empty placeholder routes for Account and Vendor connections. Walkthrough at acceptance: log in via magic-link, navigate every placeholder route, log out.

UX-writing standard applies to every onboarding screen. Welcome copy explains why F&F needs to connect to vendor systems. Password setup explains why a strong password matters. MFA enrollment explains what MFA is for in plain English. T&Cs click-through explains what the operator is agreeing to (per the inbound-vendor T&Cs draft in Phase 9.8).

### `11W.7` Account and Business setup

Minimal account-management screen for V1. Operator edits business name, business identity (logo upload, brand color), preferred currency, business-day rollover hour, and per-location IANA timezone. Reads from Phase 9 auth tables and Phase 11A.1 operator/location schema. Writes through existing operator-scoped routes. Audited via existing Phase 9 audit log.

V1 explicit non-goals on this screen: full billing UI, invoice viewer, audit log export, profile photo upload for individual users. These wait until operator demand justifies the engineering work.

### `11W.8` Vendor connections mount

Hosts the shared Vendor Connections widget tree (built in Phase 8 `8.0`) under the operator-scoped path `/locations/:location_id/vendor-connections`. No new widget code. Permission gating with `integrations.configure` granted to `operator_admin` and `operator_owner`. Lights up as Phase 8 / 8R / 8.S adapter slices ship; each new vendor card appears here automatically because the widget tree is shared with the F&F Operations Console.

### Self-Service Parity block (`11W.1`–`11W.6`, scheduled after Phase 7 + Phase 10 close)

Six parity slices migrate the heavier-than-mobile self-service Settings workflows from `lib/screens/settings/` into the Operator Web Console. Each slice ships in its own worktree against an operator-scoped backend route already shipped by Phase 9 (`/v1/auth/*` family); no new backend routes, schemas, or migrations. Per the parity contract (`docs/contracts/team_roles_hierarchy_console_parity_contract.md`), every slice must reach behavioral parity with the corresponding mobile section before acceptance — same proxy routes, same idempotency keys, same audit columns, same permission gates, same validation copy.

#### `11W.1` Members (Team list + invite)

Web parity for mobile Settings → Team. Lists current operator's users with the same filter set (`status` / `role` / `location` / `mfa_enrolled` / `search`), exposes the same row actions (`Suspend`, `Reactivate`, `Soft delete`, `Reset password`, `Reset MFA`, `Force logout`), and the same invite flow (email + role + location + org-unit + optional welcome note). Reuses `lib/services/team/team_users_list_controller.dart` and `lib/services/team/team_invite_form_controller.dart` verbatim — those controllers are pure-logic `ChangeNotifier`s already; only the gateway shape differs. Reads/writes through `/v1/auth/team/*` (operator self-service routes, gates on `team.users.*` keys; falls back to `/v1/admin/auth/users` only for users the actor's `team_scope_visibility_policy` admits). Console gate `console.web` plus per-action `team.users.*` keys; floor managers get a read-only members list (no row actions).

Files this slice owns: `lib/operator_web/services/web_team_users_gateway.dart` (web `package:http` impl of `AuthOperationsGateway` for the team-users surface), `lib/operator_web/screens/members_screen.dart`, `lib/operator_web/screens/invite_member_dialog.dart`, route entry in `lib/operator_web/router/operator_web_router.dart`, gateway resolver in `lib/main_operator_web.dart`. May lift the section widgets in `lib/screens/settings/settings_data_sections.dart` (Team Settings rendering helpers) into a shared `lib/widgets/team/` location IF the lift is purely additive — otherwise re-render in operator-web layout. Walkthrough at acceptance: log in via demo magic-link → land on `/members` → filter by role + search → invite a fixture user → suspend a fixture user → reactivate → screenshot trace per `docs/_walkthroughs/7.58.UX.5.md` bar.

#### `11W.2` Roles + custom-role builder + Permission Explainer

Web parity for mobile Settings → Roles. Lists seeded roles (`super_admin` / `ff_support` / `operator_owner` / `operator_manager` / `operator_supervisor` / `operator_staff`) plus operator custom roles. Custom-role builder lets `operator_owner` (gated by `team.roles.create_custom`) create new roles by selecting permissions from the frozen catalog (`docs/contracts/auth_permission_key_catalog.md`); seeded roles are read-only with `is_editable=false` enforced server-side. Permission Explainer renders the catalog grouped by category (`product.*` / `forgeflow.*` / `barrio.*` / `admin.*` / `team.*` / `billing.*` / `integration.*` / `integrations.*` / `workflow.*`) with the description text from the catalog. Reads/writes through `/v1/auth/team/roles` (operator self-service, gates on `team.roles.*`); seeded role views are catalog-only and do not touch the live `roles` table.

Files this slice owns: `lib/operator_web/services/web_team_roles_gateway.dart`, `lib/operator_web/screens/roles_screen.dart`, `lib/operator_web/screens/custom_role_editor_screen.dart`, `lib/operator_web/screens/permission_explainer_screen.dart`, route entries. Reuses `lib/screens/settings/settings_role_editor.dart` permission-picker widget IF the lift is additive; otherwise re-renders. Walkthrough at acceptance: log in → land on `/roles` → open Permission Explainer → create a custom role with a 3-permission subset → assign it to a fixture user from `/members` → revoke it → screenshot trace.

#### `11W.3` Hierarchy (org units + locations)

Web parity for mobile Settings → Org Hierarchy. Renders the operator's org-unit tree (regions / districts / locations) with drag-or-button move actions; exposes location create/edit/suspend at the leaves. Reads/writes through `/v1/auth/team/org-units` and `/v1/auth/team/locations/:id` (operator self-service); writes audit via existing Phase 9 audit log. Gates: `team.org_units.view` for reads, `team.roles.assign` for moves (per the hierarchy-touches-grants posture in `phase_9_auth_plan.md`), `team.locations.edit` for location edits. Floor managers see read-only hierarchy.

Files this slice owns: `lib/operator_web/services/web_team_hierarchy_gateway.dart`, `lib/operator_web/screens/hierarchy_screen.dart`, `lib/operator_web/widgets/org_unit_tree_view.dart`, `lib/operator_web/widgets/location_card.dart`, route entry. Reuses the hierarchy load-state model + render rules from `lib/screens/settings/settings_org_hierarchy_section.dart` — those structures (`TeamOrgUnitEntry`, `TeamOrgLocationEntry`, `TeamOrgHierarchyLoadState`) live in pure-logic services and are web-safe. Walkthrough at acceptance: log in → land on `/locations` → expand a region → move a location to a different district → create a new region → suspend a location → screenshot trace.

#### `11W.4` Sessions (Active Sessions)

Web parity for mobile Settings → Active Sessions. Lists the operator's own active sessions (or, if the actor holds `team.session.force_logout`, every team-member session within the actor's scope) with device fingerprint, last-active timestamp, IP/geo hint, and a `Revoke` action. Reads/writes through `/v1/auth/sessions` and `/v1/auth/session/revoke` (operator self-service for own sessions) plus `/v1/auth/team/sessions` for cross-member views (gates on `team.session.force_logout`). Idempotency key per revoke. The Operator Web Console session itself is shown with a `(this session)` chip and the revoke action calls `signOut()` after the proxy returns.

Files this slice owns: `lib/operator_web/services/web_team_sessions_gateway.dart`, `lib/operator_web/screens/sessions_screen.dart`, route entry. Reuses the session row + chip render rules from `lib/screens/settings/settings_active_sessions_section.dart` patterns. Walkthrough at acceptance: log in on web + mobile concurrently → open `/sessions` on web → see two sessions → revoke the mobile session → mobile drops to login → revoke this web session → web drops to welcome → screenshot trace.

#### `11W.5` Audit Log

Web parity for mobile Settings → Audit Log. Renders the operator's audit log (`audit_logs` rows scoped to current operator via RLS) with filters (`actor` / `action` / `target` / `time_window`), pagination (cursor-based, capped at 200 rows per page per the Performance Framework), and a CSV export button gated on `team.audit_log.view` (export gated separately by `admin.audit_log.export` — exports route through admin path with operator-picker). Reads through `/v1/auth/audit-log` (operator self-service); export through `/v1/admin/auth/audit-log/export?operator_id=...` if and only if the actor holds the admin export key (operator owners typically do not, but the catalog allows it).

Files this slice owns: `lib/operator_web/services/web_team_audit_log_gateway.dart`, `lib/operator_web/screens/audit_log_screen.dart`, `lib/operator_web/widgets/audit_log_row.dart`, route entry. Reuses the row/render rules from `lib/screens/settings/settings_audit_log_section.dart`. Walkthrough at acceptance: log in → land on `/audit-log` → filter by `team.users.invite` action → page forward → export CSV → screenshot trace.

#### `11W.6` Security (MFA + password change + login history)

Web parity for mobile Settings → Security. Renders the actor's own MFA factor inventory (TOTP / SMS / authenticator-app), enroll/revoke/recovery-request buttons (each writing through `/v1/auth/mfa/*`), the password change form (`/v1/auth/password/change` with current-password reverification), and a login-history list (subset of audit log filtered to `auth.session.login` / `auth.session.refresh` / `auth.password.change` / `auth.mfa.*` events, last 90 days). Idempotency key per write. Floor managers see only their own security surface; cross-team MFA reset is on `11W.1` Members or via support escalation through `11A.14`.

Files this slice owns: `lib/operator_web/services/web_security_gateway.dart`, `lib/operator_web/screens/security_screen.dart`, `lib/operator_web/screens/mfa_factor_dialog.dart` (separate from the onboarding `MfaEnrollmentScreen`; this is the post-onboarding manage flow), `lib/operator_web/screens/change_password_dialog.dart`, route entry. Reuses the MFA factor card + status chip rules from `lib/screens/settings/settings_mfa_section.dart`. Walkthrough at acceptance: log in → land on `/security` → enroll a TOTP factor (fixture-confirm) → cancel a pending removal → change password → view login history filtered to last 7 days → screenshot trace.

### Deferred slices (post-V1, still queued behind operator demand)

- `11W.9` Outbound Integrations mount — depends on paused Phase 8.5; resumes when 8.5 unfreezes.

## Mobile vs Web Coverage Matrix

Mobile Settings stays available for every workflow it currently handles. The Operator Web Console covers the same surfaces with desktop-first layouts for heavier multi-field admin work. Mobile and web are peers — operators can use either, and `11W.4` Sessions explicitly shows both web and mobile sessions in a unified list.

| Mobile Settings screen | Web equivalent | Slice | Status |
|---|---|---|---|
| Team list | `/members` | `11W.1` Members | Self-Service Parity block |
| Team invite | `/members` invite dialog | `11W.1` Members | Self-Service Parity block |
| Roles + Permission Explainer | `/roles` | `11W.2` Roles | Self-Service Parity block |
| Org Hierarchy | `/locations` (tree view) | `11W.3` Hierarchy | Self-Service Parity block |
| Active Sessions | `/sessions` | `11W.4` Sessions | Self-Service Parity block |
| Audit Log | `/audit-log` | `11W.5` Audit Log | Self-Service Parity block |
| MFA / Password reset / Login history | `/security` | `11W.6` Security | Self-Service Parity block |
| Account / Business | `/account` | `11W.7` Account | V1 launch block (accepted) |
| Notifications | (mobile only) | — | Stays mobile-only |
| (n/a) | `/locations/:location_id/vendor-connections` | `11W.8` Vendor Connections | V1 launch block (accepted) |

V1 launch ships `11W.0`/`11W.7`/`11W.8`. The Self-Service Parity block (`11W.1`–`11W.6`) starts after Phase 7 + Phase 10 close per `project_role_hierarchy_web_migration_sequencing.md`; mobile Settings continues to handle those workflows in the interim. Each parity slice is purely additive (new route, new screen) with no architectural change to the `11W.0` framework.

## Dual-Surface Hosting (Vendor Connections widget)

The Vendor Connections widget tree (Phase 8 `8.0`) is shared across two consoles:

- F&F Operations Console (Phase 11A) hosts the widget for F&F internal staff configuring connections on the operator's behalf during onboarding or support escalation. Cross-operator scope via `forge_admin` role and admin-side RLS bypass.
- Operator Web Console (Phase 11W) hosts the widget for operator senior roles to self-serve their own connections. Single-operator scope via standard `OperatorScopedRepository` and RLS.

Same widget tree, same backend routes, two host shells. The widget reads `(operator_id, location_id)` from its host context and renders accordingly. Permission gating (`integrations.configure`) applies identically in both shells.

Widget hosting paths:

- The shared widget code lives at `lib/integrations/ui/vendor_connections/` (proposed path, finalized in Phase 8 `8.0`).
- F&F Ops Console mounts via `lib/admin/screens/operator_location_admin_screen.dart`.
- Operator Web Console (`11W.8`) mounts via `lib/operator_web/screens/vendor_connections_screen.dart` (path finalized in `11W.8`).

V1 deferred: Outbound Integrations widget mount (`11W.9`). Depends on Phase 8.5 which is paused. Returns when 8.5 unfreezes.

## Technical Architecture

- **Build target — separate web entry point, not a web build of the operator app.** `lib/main_operator_web.dart` is a NEW Flutter for Web entry point, parallel to `lib/main_admin.dart` (Phase 11A). It does NOT compile `lib/main_forgeflow.dart` for web. **Reason (verified 2026-05-03):** the operator app codebase imports `dart:io` in 13+ files and uses SQLite (`sqflite`/`sqflite_common_ffi`) extensively for offline mobile caching. None of those are web-compatible without significant conditional-import / persistence-layer rework. The Operator Web Console doesn't need offline SQLite — it reads/writes through the proxy via HTTP. Building a separate web entry skips that whole class of work.
- **Code reuse.** `lib/main_operator_web.dart` imports the screens / widgets / services it needs from `lib/screens/`, `lib/widgets/`, `lib/services/auth/`, etc. — same pattern as how `lib/main_admin.dart` reuses brand theme + auth gateways without dragging in the full operator app. The Vendor Connections widget tree (Phase 8 `8.0`) is built as a self-contained mountable component for exactly this reason.
- **Hosting.** New Cloud Run service `forge-flow-operator-web`. Serves static Flutter Web assets + calls existing advisor proxy backend. Same proxy URL operator-app mobile uses.
- **Auth.** Firebase Auth session via existing `firebase_auth_web` (already in `pubspec.yaml`). "Continue on web" handoff: magic-link from mobile → web opens with same Firebase user logged in. Web session has same MFA / role enforcement as mobile.
- **Routing.** Operator-scoped paths only. Examples:
  - `/onboarding/welcome?token=...` — first-login magic-link landing
  - `/members` — current operator's member list
  - `/roles` — current operator's roles + custom-role builder
  - `/locations` — current operator's location tree
  - `/locations/:location_id/vendor-connections` — vendor connections for a specific location
  - `/account` — business setup
  - No `/operators/:operator_id/...` paths — operator is implicit from session.
- **Persistence.** No client-side SQLite. All reads/writes go through the proxy via HTTPS. Phase 11W is a thin HTTP client to the existing operator-scoped backend routes Phase 9 / Phase 8 build.
- **Cross-cloud egress.** Cloud Run service serves static assets; client-side HTTPS calls go to the proxy. No server-side Azure connection from the operator-web Cloud Run service itself, so static-egress IP / VPC connector are not required for `11W.0` (matches `scripts/deploy_admin_console.ps1` posture). If the service later adds server-side Azure calls, add the same static-egress flags as Phase 11A.
- **Brand styling.** `lib/theme/app_theme.dart` shared with mobile + admin. Sunset / Peacock palette. Playfair Display + IBM Plex.

### URL decision (locked 2026-05-03)

**`app.forgeflow.app`**. Reasoning:

- Operator-facing — `app.` reads as "the customer-facing app" and aligns with how operators describe Forge & Flow internally.
- Distinct from `admin.forgeflow.app` (F&F internal Operations Console).
- Distinct from `forgeflow.app` (marketing site / future top-level brand).
- "console" reads internal / engineering-focused; not appropriate for the customer-facing surface.

DNS + TLS provisioning is operator action before `11W.0` deploys to staging.

## Permission Model

Phase 11W relies entirely on existing Phase 9 permission keys. No new keys needed except:

- `integrations.configure` — added by Phase 8 `8.0` (governs vendor-connections + outbound-integrations widget access). Granted to `operator_admin`, `operator_owner`, `forge_admin` per the Vendor Connections surface design doc.

The console-level access gate is `console.web` — granted to `operator_admin`, `operator_owner`, and `location_manager` (read-only). All sub-screens further filter by their domain-specific keys (`team.*`, `roles.*`, `audit.*`, `integrations.*`, etc.).

## Frontend Exposure

Phase 11W IS frontend. Per Hard Promise #10:

- **Operator-facing surfaces this phase ships:** see Sub-Slice Sequence above. Each `11W.x` slice IS a UX surface.
- **Admin (11A) surfaces this phase requires:** none new. F&F Ops Console pre-exists.
- **Demo-mode walkthrough (per slice):** log in to web console as a demo `operator_admin` → exercise the new surface end-to-end → screenshot trace.

Walkthrough evidence required at slice acceptance per `docs/CODEX_PROMPT_GENERATION_STANDARD.md`.

## Acceptance Criteria (per slice)

- New web route renders correctly at desktop breakpoint (≥1024px) and tablet breakpoint (768px).
- Permission gate enforced server-side (proxy returns 403 for missing role); client UI hides actions where permission missing.
- All mutations audited via existing Phase 9 audit log.
- All reads route through `OperatorScopedRepository` — no direct DB access from client.
- Demo-mode walkthrough captured per `docs/CODEX_PROMPT_GENERATION_STANDARD.md`.
- Brand styling matches operator-app mobile (visual diff against staging mobile screen).
- "Continue on web" handoff works from a logged-in mobile session.

## Dependencies

- **Phase 9** auth + roles + permissions accepted on master (current state).
- **Phase 11a `11a.11c-e`** Azure DB Flexible Server live (current state — staging green, Production1 paused per operator).
- **Phase 8 `8.0`** ships the vendor-connections widget that `11W.8` mounts. Phase 11W can ship Wave A-C without Phase 8 — `11W.8` lands when `8.0` does.
- **Phase 8.5** ships the outbound-integrations widget that `11W.9` mounts. Same pattern.
- **Cross-cloud egress** plumbing (already exists in staging — `ff-staging-proxy-egress` reused).
- **Cloud Run service slot** reserved for `app.forgeflow.app` or `console.forgeflow.app`.
- **Operator-app Firebase config + flavors** for the web build (mostly reuse mobile config).

## Sequencing in Build Cadence

V1 launch block (in flight): `11W.0`/`11W.7`/`11W.8` ship parallel with Phase 8 `8.0` adapter framework. `11W.0` shell roughly 2–3 weeks; `11W.7` Account roughly 1 week post-`11W.0`; `11W.8` blocks on `8.0` then ships in roughly 1 week.

Self-Service Parity block (queued, starts after Phase 7 + Phase 10 close): `11W.1`–`11W.6` ship in fully parallel worktrees per `docs/_execution/role_hierarchy_console_migration/parallel_execution_runbook.md`. File ownership is disjoint slice-to-slice (each owns its own gateway + screen + route entry), so the only serialization rule is on `lib/main_operator_web.dart` (gateway resolver wiring) and `lib/operator_web/router/operator_web_router.dart` (nav-item registration). Both serialize through a single integration lane that picks up each slice as it lands. Approximate per-slice runtime: 3–5 days of focused engineering once Codex is reviewing in parallel.

MVP launch state = `11W.0`/`11W.7`/`11W.8` complete + Phase 8 Wave 1+2+3 complete. Operators self-serve vendor connections from Wave 3 vendors (Toast, Square, Lightspeed, OpenTable, Libro, 7shifts, QuickBooks Time, ADP). Members, Roles, Hierarchy, Sessions, Audit Log, Security continue to work via mobile Settings until the Self-Service Parity block lands.

## Non-Negotiables

- All operator actions go through the proxy backend's existing operator-scoped routes. Direct DB access from the web client is forbidden — same repository pattern + RLS as mobile.
- Audit columns (`created_by`, `updated_by`) populated on every web-initiated write. Same as mobile.
- No cross-operator views ever — that's F&F Ops Console (Phase 11A). The web console URL itself never exposes a path with another operator's ID.
- Brand styling identical to operator-app mobile.
- Demo-mode banner stays in operator-app mobile only — not in web console (web is admin/setup-only, demo-mode is operational).

## Adjacent Phases

- **Phase 9** — backend foundation Phase 11W consumes.
- **Phase 11A** — sibling F&F-internal console. Phase 11A `.12/.13/.14` cross-operator parity slices give F&F staff support visibility into the same data Phase 11W exposes to operators.
- **Phase 8 / 8R / 8.S / 8.5** — adapter widgets that Phase 11W mounts (`11W.8`/`11W.9`).
- **Phase 11b** — operator-facing advisor (mobile-first at V1; web hosting TBD post-launch).
- **Phase 12** — workflow platform. May extend Phase 11W with workflow-management screens later.

## Cross-references

- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` — sibling F&F Operations Console; cross-operator parity slices `11A.12/.13/.14` ship in lockstep with `11W.1`–`11W.6`.
- `docs/contracts/team_roles_hierarchy_console_parity_contract.md` — binding parity contract for the Self-Service Parity block; both consoles must satisfy this contract before slice acceptance.
- `docs/_execution/role_hierarchy_console_migration/parallel_execution_runbook.md` — worktree names, branches, file-ownership map, serialization rules for the 9-slice parallel push.
- `docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md` — Phase 8 framework + POS adapters.
- `docs/phases/phase_8/vendor_connections_admin_surface.md` — vendor-connections widget design (dual-surface hosting section).
- `docs/phases/phase_8R/phase_8R_official_reservation_connector_plan.md` — reservation adapters.
- `docs/phases/phase_8S/phase_8S_scheduling_connector_plan.md` — scheduling adapters.
- `docs/phases/phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md` — outbound integrations.
- `docs/phases/phase_9/phase_9_auth_plan.md` — auth + roles + permissions backend that Phase 11W consumes.
- `docs/contracts/auth_permission_key_catalog.md` — permission keys.
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` — RLS / OperatorScopedRepository.
