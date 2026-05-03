# Phase 11W: Operator Web Console

Updated: 2026-05-03 (V1 lean scope cut applied)
Status: Planned. V1 ships only 3 slices (`11W.0` shell, `11W.7` Account, `11W.8` Vendor connections mount). The other 7 slices originally proposed (Members, Roles, Hierarchy, Sessions, Audit Log, Security, Outbound integrations) are deferred per `project_v1_lean_scope_cut.md`; mobile Settings handles those workflows at V1.
Owner: Operator web lane

## Why this exists

Forge & Flow's role/permission/operator/location/team-management foundation is built (Phase 9 backend + mobile Settings UX; Phase 11A foundation for F&F-internal admin). Two structural gaps remain:

1. **Operators have no dedicated web console.** Mobile Settings exposes Team / Roles / Hierarchy / Sessions / Audit Log / MFA, but heavier business-management workflows (custom-role design, multi-location org tree edits, integration management, business setup) are too thick for mobile.
2. **The F&F Operations Console** (Phase 11A) does not yet have full inspect/edit visibility into the operator-managed data it can already create. Adding member visibility, custom-role configuration views, and audited support edits is queued separately as `11A.12` / `11A.13` / `11A.14` — see Phase 11A plan.

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

## Sub-Slice Sequence (V1 leaner posture)

V1 ships 3 slices only. The framework in `11W.0` is built so adding deferred slices later is purely additive: new route, new screen, no architectural change.

### `11W.0` Web console shell

Flutter for Web bootstrap at `lib/main_operator_web.dart` (separate web entry point, not a web build of `lib/main_forgeflow.dart`; incompatibility verified 2026-05-03 because the operator app uses `dart:io` and SQLite extensively for offline mobile caching). Brand styling shared with operator app via the same `lib/theme/app_theme.dart`. Route shell. Phase 9 session gate. Magic-link landing for the onboarding-welcome flow (operator sets password, enrolls MFA, accepts T&Cs). Empty placeholder routes for Account and Vendor connections. Walkthrough at acceptance: log in via magic-link, navigate every placeholder route, log out.

UX-writing standard applies to every onboarding screen. Welcome copy explains why F&F needs to connect to vendor systems. Password setup explains why a strong password matters. MFA enrollment explains what MFA is for in plain English. T&Cs click-through explains what the operator is agreeing to (per the inbound-vendor T&Cs draft in Phase 9.8).

### `11W.7` Account and Business setup

Minimal account-management screen for V1. Operator edits business name, business identity (logo upload, brand color), preferred currency, business-day rollover hour, and per-location IANA timezone. Reads from Phase 9 auth tables and Phase 11A.1 operator/location schema. Writes through existing operator-scoped routes. Audited via existing Phase 9 audit log.

V1 explicit non-goals on this screen: full billing UI, invoice viewer, audit log export, profile photo upload for individual users. These wait until operator demand justifies the engineering work.

### `11W.8` Vendor connections mount

Hosts the shared Vendor Connections widget tree (built in Phase 8 `8.0`) under the operator-scoped path `/locations/:location_id/vendor-connections`. No new widget code. Permission gating with `integrations.configure` granted to `operator_admin` and `operator_owner`. Lights up as Phase 8 / 8R / 8.S adapter slices ship; each new vendor card appears here automatically because the widget tree is shared with the F&F Operations Console.

### Deferred slices (post-V1, queued behind operator demand)

The following slices were originally proposed but are pulled back from V1 per the lean scope cut. They get added when actual operator volume or operator complaints justify the engineering work, not preemptively.

- Members list and invite (mobile Team handles V1)
- Roles and custom-role builder (mobile Roles handles V1)
- Locations / Hierarchy (mobile Org Hierarchy handles V1)
- Sessions (mobile Active Sessions handles V1)
- Audit Log (mobile Audit Log handles V1)
- Security (MFA, password reset, login history; mobile Security handles V1)
- Outbound Integrations mount (depends on paused Phase 8.5; resumes when 8.5 unfreezes)

## Mobile vs Web Coverage Matrix (V1)

Mobile Settings stays available for the read-mostly and lightweight workflows. The Operator Web Console covers only the heavier-than-mobile workflows that V1 needs (Account / Business setup and Vendor Connections).

| Mobile Settings screen | V1 web equivalent | Where the V1 operator goes |
|---|---|---|
| Team list | (no V1 web) | Mobile Team |
| Team invite | (no V1 web) | Mobile Team |
| Roles + Permission Explainer | (no V1 web) | Mobile Roles |
| Org Hierarchy | (no V1 web) | Mobile Org Hierarchy |
| Active Sessions | (no V1 web) | Mobile Active Sessions |
| Audit Log | (no V1 web) | Mobile Audit Log |
| MFA | (no V1 web) | Mobile Security |
| Password reset | (no V1 web) | Mobile Security |
| Account / Business | `11W.7` Account | Web (multi-field desktop edits) |
| Notifications | (mobile only) | Mobile |
| (n/a) | `11W.8` Vendor Connections | Web only (too heavy for mobile) |

Web parity for the deferred mobile screens (Members, Roles, Hierarchy, Sessions, Audit Log, Security) is post-V1, queued behind operator demand. Adding any deferred slice later is purely additive (new route, new screen) with no architectural change to the V1 framework.

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

## Sequencing in Build Cadence (V1 leaner posture)

Phase 11W ships in parallel with Phase 8 `8.0` framework. Approximate timeline:

- `11W.0` shell ships parallel with Phase 8 `8.0` framework engineering. Roughly 2 to 3 weeks of focused engineering.
- `11W.7` Account ships after `11W.0` lands. Roughly 1 week. Reuses Phase 9 auth + Phase 11A.1 operator/location schema; minimal new code.
- `11W.8` vendor connections mount blocks on Phase 8 `8.0` widget shipping. Once `8.0` is green, `11W.8` is a thin shell-level mount with permission gating. Roughly 1 week.

MVP launch state = `11W.0`, `11W.7`, `11W.8` complete + Phase 8 Wave 1+2+3 complete. Operators self-serve vendor connections from Wave 3 vendors (Toast, Square, Lightspeed, OpenTable, Libro, 7shifts, QuickBooks Time, ADP). Members, Roles, Hierarchy, Sessions, Audit Log, Security continue to work via mobile Settings at V1.

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

- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` — sibling F&F Operations Console; cross-operator parity slices `11A.12/.13/.14`.
- `docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md` — Phase 8 framework + POS adapters.
- `docs/phases/phase_8/vendor_connections_admin_surface.md` — vendor-connections widget design (dual-surface hosting section).
- `docs/phases/phase_8R/phase_8R_official_reservation_connector_plan.md` — reservation adapters.
- `docs/phases/phase_8S/phase_8S_scheduling_connector_plan.md` — scheduling adapters.
- `docs/phases/phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md` — outbound integrations.
- `docs/phases/phase_9/phase_9_auth_plan.md` — auth + roles + permissions backend that Phase 11W consumes.
- `docs/contracts/auth_permission_key_catalog.md` — permission keys.
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` — RLS / OperatorScopedRepository.
