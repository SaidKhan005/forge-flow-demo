# Phase 2 walkthrough — master plan

> **Created 2026-05-14 evening.** Owner: orchestrator. Purpose: hold the
> Phase 2 walkthrough state across multiple sessions so nothing is lost
> mid-flight or due to context boundaries.
>
> **Read this top to bottom on every session restart.** The Status
> board below is the source of truth for what's done, what's next, and
> what's blocked.

---

## Continuation prompt (paste into a fresh session to resume)

```
You are resuming the Phase 2 walkthrough verification per
`docs/_audits/wave_2/phase_2_walkthrough_master_plan.md`. Read that
file top to bottom before anything else. The Status board at the top
tells you which console lane is active and the next concrete action.

The rolling evidence matrix lives at
`docs/_audits/wave_2/phase_2_walkthrough_verification.md`. Update it
inline as you go (do not write an "appendix" — annotate the existing
matrix tables).

Workflow per console lane (operator-web → admin → mobile):
 1. Drive every surface in the lane's surfaces-to-drive list. Use the
    two dev-only patches (web/index.html CSP relax + lib/main_operator_web.dart
    initial-state skip-onboarding) per the markers in this master plan
    when driving the operator-web lane. Revert before any commit.
 2. Sweep all relevant rows in the three trackers (WAVE_2_LEDGER,
    WAVE_EXECUTION_LEDGER, DEBUG_MD_IMPLEMENTATION_STATUS) and append
    an inline one-line annotation per row, not a single changelog
    entry. Format: `Phase 2 walkthrough 2026-05-14: <state> — <evidence>`.
 3. Demo-fidelity bugs you find LIVE get fixed live — either spawn a
    worktree agent (`isolation: worktree`, contract = branch → fix →
    self-audit → commit → push → open PR → STOP) or inline in this
    branch if the edit is < 20 LoC and operator hasn't said "no auto-fix".
 4. UX-decision gaps (e.g. 3-dot vs inline button, scope-flip demo
    behaviour) get filed as parked rows in WAVE_2_LEDGER and the Gaps
    Filed table in this master plan, NEVER auto-fixed.
 5. After each meaningful slice of work, commit + push. Update the
    Status board in this master plan before the commit.
 6. Hand off to operator only when the lane's acceptance criteria are
    all met OR you need an operator decision.

Use the `window.__ff` helper from §"Helper scripts" below to drive
Flutter web clicks after enabling semantics via the flt-semantics-
placeholder click. Flutter web text inputs ignore programmatic .value
writes — use the skip-onboarding patch to avoid the welcome→token
typing requirement.

Worktree agents must NEVER merge, NEVER use --no-verify, NEVER update
trackers themselves. Orchestrator audits + merges only.

Read `CLAUDE.md` for the authority order, the Hard Promises, and the
workflow. Read `docs/_audits/audit_chunking_playbook.md` if a chunk
gets big enough to warrant sub-agents.

Stop only when: a console lane is fully done AND committed, OR you
need an operator decision (file the question, do not guess).
```

---

## Status board (update on every commit)

| Lane | Owner | State | Last commit | Next action |
|---|---|---|---|---|
| **Operator-web** | Main Claude (this lane) | ✅ **DONE** — Round 3 (2026-05-14 evening 2) closed the deferred set: U-1 sign-out drove demo source signOut → Welcome (live login screen code-anchored, filed U-1-FU-demo-needs-signin-emission DEFER V1.1); OW-8c MFA-enrolled drove "MFA: Enrolled" badge + "View recovery codes" CTA live via session.mfaEnrolled patch (deeper Request-removal sub-states code-anchored, filed OW-8c-FU-demo-gateway-pending-removal DEFER V1.1); OW-4 inverse + RP-15 cap code-anchored per gaps register defer dispositions. All patches reverted. PR #741 lands Round 2 closure + Claude2 handoff + walkthrough docs on master. | `63e262b9` (PR #741 merge, 2026-05-14 evening 2) | Hand off to admin console (Claude2 lane) + mobile (pending operator instruction). |
| **Admin console** | Claude2 lane (separate machine) | 🟡 ASSIGNED — handoff doc opened 2026-05-14 evening at `docs/_indices/PHASE_2_WALKTHROUGH_CLAUDE2_HANDOFF.md`; Claude2 starts when operator pastes the opening prompt into the second session | — | Claude2 reads handoff doc, applies admin dev patches per handoff §"Admin dev patches", boots `admin-console-demo` at port 8182, drives admin surfaces per handoff §"Surfaces to drive" (Phase A through H), inline-annotates admin rows in 3 trackers, files gaps in this master plan's Gaps register. |
| **Mobile (Samsung A54 R5CW503HJHP)** | Main Claude (this lane) | ⏸ PENDING | — | After operator-web lane closes. Need forgeflow APK build + adb install + demo seed. |

### Cross-lane coordination

Append a one-line note here whenever a cross-lane event happens that the other lane needs to know about. Format: `<date>: <lane> — <event>`.

- 2026-05-14 evening: Main opened Claude2 handoff doc for admin console lane. Claude2 takes over admin lane on a separate machine. Concurrency rule: Main never edits `lib/admin/**`; Claude2 never edits `lib/operator_web/**` or `lib/main_forgeflow.dart`. Shared docs (master plan + verification matrix + trackers) get per-lane sections; both lanes annotate their own tracker rows inline, never overwrite each other's annotations.
- 2026-05-14 evening 2: Main merged Claude2 handoff + Round 2 walkthrough closure into master via PR #741 (commit `63e262b9`). Claude2 can now `git pull origin master` on the second machine and pick up `docs/_indices/PHASE_2_WALKTHROUGH_CLAUDE2_HANDOFF.md` + the master plan + the verification matrix.
- 2026-05-14 evening 2: Main closed operator-web lane via Round 3 (U-1 + OW-8c live; OW-4 inverse + RP-15 cap code-anchored). 2 new V1.1 follow-up rows filed (U-1-FU-demo-needs-signin-emission, OW-8c-FU-demo-gateway-pending-removal). Operator-web Status flipped to ✅ DONE.

---

## Operator-web lane

### Surfaces to drive (live)

Tick as each is driven and matrix-annotated.

#### Done in `c92d8a9a` (Lane U + V matrix commit)
- [x] Top bar (OW-0c) — scope selector, role chip, sign-out, branding
- [x] Business Account (U-3 + U-FU-hp11-account + OW-2b/c/d/e/f/g + W-5 + W-6)
- [x] Business Setup (U-4 + OW-3a/b/d/f/g + H-2 inheritance tree + HP #11 effective-value)
- [x] My account (U-5 + W-3 + OW-5b/d/8d + Two-factor card)
- [x] Team members (U-5 + OW-6a/b/c + W-2 cancel invite)
- [x] Roles & permissions (U-5 + S-3 list + OW-7b-g)
- [x] Custom role editor (S-3 + R-1L human_label + R-2L MFA badges + Q-4 scope filter)
- [x] Active sessions (U-5 + OW-9a/b/c)
- [x] Audit log (U-6 + OW-10 + B8.b filter + B8 anchor status)
- [x] Vendor integrations (U-6 + V-1 + OW-11a/b/c/d + HP #2 demo badges)
- [x] Data accuracy (U-6 + OW-12a-i + S-1 wage authority + S-2 unified IA + OW-13a/b/c)
- [x] Notifications (U-6 + OW-14a-g)
- [x] Schedule (OW-1 + H-1)
- [x] OW-4 location-scope half (no Locations item in nav at location scope)

#### Remaining to drive

##### Done in round 2 (2026-05-14 evening)
- [x] **Permission Explainer screen** — ✅ DONE-LIVE. Renders 106 permission keys grouped by 10 productLabels (Product access / Forge & Flow / Barrio / F&F admin / Team self-service / Account configuration / Business timing / Billing / Integrations per vendor / Integrations vendor connections / Workflows Phase 12). Each row carries key + human_label + MFA badge where required. 🐛 GAP `RP-1-FU-permission-key-human-labels` filed (4 newer keys missing human_label).
- [x] **W-1 + W-1-FU Edit-member dialog body** — ✅ DONE-LIVE. Drove via pixel-coord click on the overlay menu. Dialog header "Edit member" + explainer "Change this teammate's email, name, role, or hierarchy scope. The change writes to Firebase + audit log; the operator will see the change in their audit log." Field set: Email + Display name + Role (Owner) + Hierarchy scope (Business-wide, with "Business-wide: this teammate can act in every location." helper) + Reason field + Cancel + Save.
- [x] **RP-15 scope-flip on Benchmarks** — 🟢 SURFACE-LIVE. Clicked Downtown in tree → override card flipped from "Demo Restaurant Group / 4.58 / Target cycle" to "Downtown / 4.58 / Target cycle". Tree+card wiring works. Cap state-machine deferred to Manager-role demo session (filed `RP-15-FU-cap-state-manager-session`).
- [x] **OW-12j polling cadence subtitle copy diff** — 🐛 GAP-FOUND. Operator-requested literal strings ("Polling and data freshness applies to..." / "Vendors outside this list update in real time...") NOT rendered verbatim. Shipped copy ("F&F controls how often we ask your poll-only vendors..." / "Webhook vendors are real-time regardless.") is arguably better but doesn't match the literal ask. Filed `OW-12j-FU-copy-decision`.

##### Done in Round 3 (2026-05-14 evening 2)
- [x] **U-1 post-sign-out path** — drove `Sign out` live. Demo source emits `OperatorWebSignedOut` which the router maps to Welcome (NeedsToken), NOT the live Login screen. Live Login screen is owned by `FirebaseOperatorWebAuthSource` (`OperatorWebNeedsSignIn` state) and code-anchored in `lib/operator_web/screens/login_screen.dart`. Filed **U-1-FU-demo-needs-signin-emission** to add a demo-source variant that emits NeedsSignIn on signOut (DEFER V1.1).
- [x] **OW-8c MFA-enrolled** — drove the CTA shift live via `session.mfaEnrolled: true` dev patch. Verified: "MFA: Enrolled" badge + headline "Save your recovery codes" + "1 method is enrolled" body + "View recovery codes" CTA. Matches `MfaCardStage.enrolled` + `!recoveryCodesViewed` at [mfa_card_controller.dart:330-344](lib/operator_web/account/mfa_card_controller.dart:330). Deeper "Request removal" + "Cancel request" sub-states code-anchored at [my_account_screen.dart:313-345](lib/operator_web/screens/my_account_screen.dart:313) + [mfa_card_controller.dart:376-392](lib/operator_web/account/mfa_card_controller.dart:376) (require `DemoWebSecurityGateway` pending-removal seeding to exercise live — filed **OW-8c-FU-demo-gateway-pending-removal** DEFER V1.1).
- [x] **OW-4 business-scope inverse** — code-anchored at [operator_web_router.dart:989-995](lib/operator_web/router/operator_web_router.dart:989) (`if (!isLocationScope) const OperatorWebNavItem(... title: 'Locations' ...)`). Live drive deferred per existing **OW-4-FU-business-scope-demo** (OPERATOR DECISION — defer V1.1).
- [x] **RP-15 manager-once cap state** — code-anchored at [benchmarks_screen.dart:187-198](lib/operator_web/screens/benchmarks_screen.dart:187) (cap rejection translates `manager_override_cap_reached` envelope to operator-facing copy). Live drive deferred per existing **RP-15-FU-cap-state-manager-session** (DEFER — code-anchored + tested).

### Tracker annotation status — operator-web lane scope

Phase 1 (changelog-only entry) DONE in commit `c92d8a9a`. Phase 2 (inline annotation per row) DONE via PR #739 (`2e2f03aa`, merged to master via PR #741 at `63e262b9`).

- [x] **DEBUG_MD_IMPLEMENTATION_STATUS.md** — ~148 rows inline-annotated (DONE-LIVE 104, SURFACE-LIVE 7, BACKEND 120, ADMIN-DEFERRED 10, MOBILE-DEFERRED 30, GAP-FOUND 2, NOT-DRIVEN 1).
- [x] **WAVE_2_LEDGER.md** — 33 rows inline-annotated.
- [x] **WAVE_EXECUTION_LEDGER.md (Wave 1)** — Wave 1 Lane A + Lane B backbone rows operator-web-visible annotated.

### Gaps filed (master gap register)

| ID | Title | Source surface | Severity | Disposition | Status |
|---|---|---|---|---|---|
| `R-2L-FU-demo-fixture` | Operator-web demo `kDemoTeamRolesFixture` still seeds v1 5-role list, not v2 10-role catalog from R-2L PR #711 | Roles & permissions list | Demo-fidelity (cosmetic) | **FIX LIVE** (worktree agent) | **in flight** — agent dispatched 2026-05-14 evening |
| `U-FU-hp11-account-demo-defaults` | "Inherits from Business: null / null" + "Business: null:00 local" string interpolation leak on Account scope notices + brand-new-operator path | Business Account → Region / Business week sections | Demo-fidelity + production brand-new-operator path | **FIX LIVE** | ✅ **RESOLVED** via PR #738 → merged to master at `21582169` (2026-05-14 evening). |
| `MO-5b-FU-operator-web` | Two-factor sign-in / MFA / 2FA label drift extends to operator-web. Surfaces: My account Two-factor card; Audit log Action filter chips ("MFA enrolled (authenticator)" / "MFA factor removed" vs canonical "Reset two-factor sign-in") | My account, Audit log | Demo + production-copy (operator-facing) | **FIX LIVE** (canonical label needs operator confirm) | open — operator decision pending |
| `OW-6d-FU-edit-button-UX` | Operator's debug.md 156 literal ask was "instead of the 3 dot icon is should be a button saying edit user"; what shipped is a 3-dot menu with Edit member + Suspend + Reset password + Reset two-factor sign-in + Remove from team as menu items. **The dialog body itself is fully shipped + verified live 2026-05-14 evening** (Email + Display name + Role + Hierarchy scope + Reason + Save/Cancel) | Team members row trailing | UX decision | **OPERATOR DECISION** — file as parked row | open — needs decision |
| `OW-4-FU-business-scope-demo` | Demo session is location-pinned via `kDemoOperatorWebSession.primaryLocationId='demo-location'`; the top-bar scope selector renders the H-3 tree but selecting "All locations / Business-wide" is a no-op | Top-bar selector | Demo-fidelity (walkthrough-only) | **OPERATOR DECISION** — defer V1.1 | open — defer |
| `B-FU-dev-csp` | Production CSP in `web/index.html` blocks Flutter dev DDC bootstrap; walkthrough requires a dev-only `unsafe-inline` + `unsafe-eval` carve-out applied + reverted per session | `web/index.html` CSP | Infra (developer-experience) | **DEFER** until operator-web lane closes; then dedicated slice | parked |
| `RP-1-FU-permission-key-human-labels` (new 2026-05-14 evening) | 4 newer permission keys render their machine key as their own description on the Permission Explainer because `human_label` metadata is missing in `lib/auth/permission_key_metadata.dart`: `team.roles.default_catalog.edit`, `team.roles.default_catalog.view`, `team.users.self_update`, `integrations.configure` (audit Phase 12 `workflow.*` too) | Permission Explainer screen | Operator-visible bug (Explainer looks broken on those rows) | **FIX LIVE candidate** (metadata addition, no behavior change) | open — defer to next operator-web round |
| `OW-12j-FU-copy-decision` (new 2026-05-14 evening) | Data accuracy → "What this page is for" + Data freshness tier card uses operator-friendly + concrete copy but NOT the exact debug.md 197-199 literal strings | `data_accuracy_screen.dart` | Copy decision — shipped is arguably better than literal | **OPERATOR DECISION** | open |
| `RP-15-FU-cap-state-manager-session` (new 2026-05-14 evening) | RP-15 manager-once override cap state-machine cannot be exercised live because demo session is Owner. Need either (a) Manager-role demo session OR (b) Flutter web text-input automation that can type into Override value field | `kDemoOperatorWebSession` role binding | Walkthrough fidelity | DEFER — cap logic is code-anchored + tested | open — defer |
| `U-1-FU-demo-needs-signin-emission` (new 2026-05-14 evening 2) | Demo source maps `signOut → SignedOut → NeedsToken → Welcome` instead of `SignedOut → NeedsSignIn → live LoginScreen`. Live Login screen is owned by `FirebaseOperatorWebAuthSource` and unreachable from demo. Need a demo-source variant (or `--dart-define=OPERATOR_WEB_DEMO_NEEDS_SIGNIN=true` flag) that emits `OperatorWebNeedsSignIn` on signOut | `DemoOperatorWebAuthSource.signOut` + new initial-state factory | Walkthrough fidelity | DEFER V1.1 — Login screen is code-anchored at `lib/operator_web/screens/login_screen.dart` | open — defer |
| `OW-8c-FU-demo-gateway-pending-removal` (new 2026-05-14 evening 2) | OW-8c deeper sub-states (`MfaCardStage.removalRequested` "MFA: Removal requested" + countdown copy; `MfaCardStage.removable` "MFA: Ready to turn off") cannot be exercised live because `DemoWebSecurityGateway` does not seed pending-removal state. Live drive verified `MfaCardStage.enrolled` only (via `session.mfaEnrolled: true` patch) | `DemoWebSecurityGateway.fetchMfaState()` seeding | Walkthrough fidelity | DEFER V1.1 — full state machine is code-anchored at `lib/operator_web/account/mfa_card_controller.dart:302-401` + tested | open — defer |

### Acceptance criteria for "operator-web lane done"

1. ✅ All driven surfaces in the matrix.
2. ✅ All demo-fidelity bugs marked FIX LIVE either fixed (PR merged) or filed with explicit operator-deferral note.
3. ✅ All UX-decision gaps captured in WAVE_2_LEDGER as parked rows awaiting operator.
4. ✅ All operator-web-relevant rows in all 3 trackers inline-annotated.
5. ✅ Dev patches reverted; tree clean; final commit + push.
6. ✅ Master plan Status board flipped to ✅ DONE; "next action" = "hand off to admin console lane".

---

## Admin console lane

### Surfaces to drive

(To be populated after operator-web lane closes. Seed list:)

- [ ] Admin sign-in screen
- [ ] Admin top bar / operator switcher
- [ ] Admin Health (`health_admin_screen.dart`) — QI-8 3-tab tile rendering
- [ ] Admin Default Role Catalog (`default_role_catalog_admin_screen.dart`) — RP-9 permission gate
- [ ] Admin Default Role Catalog publish dialog (`default_role_catalog_publish_dialog.dart`)
- [ ] Admin My Account (`my_account_admin_screen.dart`) — W-4 parity
- [ ] Admin Members (`members_admin_screen.dart`) — W-1 admin side
- [ ] Admin Invite member (`invite_member_admin_dialog.dart`) — RP-10 admin side
- [ ] Admin Audit log (`audit_log_admin_screen.dart`) — AC-1 actor_kind label sweep
- [ ] Admin Audited support actions (`audited_support_actions_admin_screen.dart`)
- [ ] Admin Vendor applicability (`vendor_applicability_admin_screen.dart`) — OW-13d 3-tab editor
- [ ] Admin Vendor connections (`vendor_connections_admin_mount.dart`)
- [ ] Admin Per-location data accuracy (`per_location_data_accuracy_screen.dart`) — RP-15 admin-undo path
- [ ] Admin Roles + Hierarchy + Sessions (`roles_hierarchy_sessions_admin_screen.dart`)
- [ ] Admin Polling + pricing (`polling_and_pricing_admin_screen.dart`)
- [ ] Admin Pricing tier (`pricing_tier_admin_screen.dart`)
- [ ] Admin Corpus (`corpus_admin_screen.dart`)
- [ ] Admin Debug console (`debug_console_admin_screen.dart`)
- [ ] Admin Feature flags (`feature_flags_admin_screen.dart`)
- [ ] Admin Integration (`integration_admin_screen.dart`)
- [ ] Admin Observability (`observability_admin_screen.dart`)
- [ ] Admin Operator picker (`operator_picker_screen.dart`)
- [ ] Admin Operator location (`operator_location_admin_screen.dart`)
- [ ] Admin Support operator view (`support_operator_view_admin_screen.dart`)
- [ ] Admin Timing setup (`admin_timing_setup_screen.dart`)

### Admin launch reference

```
scripts/run_admin_console_dev.ps1 -DemoMode
```

This runs `flutter run -t lib/main_admin.dart -d chrome --dart-define=ADMIN_DEMO_AUTH=true` per `run_admin_console_dev.ps1:43-55`. Fixture login users available: `super.admin@`, `support@`, `operator@` (see `_resolveAuthSource` in `main_admin.dart`).

For Claude Preview MCP, swap `-d chrome` for `-d web-server --web-port=8182 --web-hostname=0.0.0.0` to bind a queryable URL.

### Acceptance criteria same shape as operator-web.

---

## Mobile lane (Samsung A54, deviceId `R5CW503HJHP`)

### Prereq

- [ ] `flutter build apk --debug --flavor forgeflow -t lib/main_forgeflow.dart --dart-define=ANTHROPIC_API_KEY=$env:ANTHROPIC_API_KEY` (or use `scripts/run_flutter_dev.ps1 -App forgeflow -Device R5CW503HJHP -UseFirebaseAuth`)
- [ ] `adb install` the resulting APK to the Samsung
- [ ] Confirm demo seed flows (mock replay)

### Surfaces to drive

(To be populated after admin lane closes. Seed list — from debug.md 257-306 + MP-1 + MO-* ledger rows:)

- [ ] Home screen — MO-H-1 live button explainer
- [ ] Notifications tab — MO-1 mark-as-read tick
- [ ] Data tab — MO-1 (renamed MO-2 in debug.md) F&F-admin-only gating
- [ ] Setup tab — Business timing MO-3a/b/c (view-only + cleanup + operator-web deeplink)
- [ ] Wage Setup — MO-4a/b/c
- [ ] Covers Setup — MO-2 / MO-6 manual entry + reservation fallback
- [ ] Integrations tab — MP-1 (live status + demo-live switch + ops-portal deeplink)
- [ ] Account → 2FA — MO-5a/b/c
- [ ] Account → Sign-in details — MO-6b/c/d
- [ ] Account → Active Sessions — MO-7c/d/e/f
- [ ] Settings tab order — MO-S (Setup → Integrations → Data → Account)
- [ ] U-FU-mobile-deeplink handoff-code flow

### Mobile screenshot pattern

`$adb shell screencap -p /sdcard/screen.png && $adb pull /sdcard/screen.png` — pull each surface as PNG, save under `docs/_audits/wave_2/phase_2_walkthrough_evidence/mobile/<surface>.png`.

### Acceptance criteria same shape.

---

## Dev-only patches reference

These patches are required for the operator-web walkthrough only. Re-apply
when starting a session, revert before any commit. See `B-FU-dev-csp`
in the gap register for the permanent fix.

### Patch 1 — CSP relaxation (`web/index.html`)

Replace the production CSP `<meta>` tag (matches `'sha256-LEIgqV9+9hWnNcFZ7vYClnAB0Fj6CI1idm4CgGmnQ5g='`) with:

```html
<!-- DEV-ONLY CSP RELAXATION (Phase 2 walkthrough 2026-05-14, REVERT BEFORE COMMIT) -->
<meta http-equiv="Content-Security-Policy" content="
  default-src 'self' 'unsafe-inline' 'unsafe-eval';
  script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' https://www.gstatic.com https://*.firebaseapp.com;
  style-src 'self' 'unsafe-inline' https://fonts.googleapis.com;
  img-src 'self' data: blob: https:;
  font-src 'self' data: https://fonts.gstatic.com;
  connect-src 'self' ws://localhost:* http://localhost:* https://www.gstatic.com https://fonts.gstatic.com https://*.googleapis.com https://*.firebaseio.com https://*.cloudfunctions.net wss://*.firebaseio.com https://admin-proxy.forgeflow.app https://*.forgeflow.app https://*.run.app;
  frame-src 'self' https://*.firebaseapp.com;
  object-src 'none';
  base-uri 'self';
  form-action 'self';
">
```

### Patch 2 — Skip onboarding (`lib/main_operator_web.dart`)

In `_DemoOperatorWebAuthSourceWithTeamSurfaces`, change:

```dart
super(initial: const OperatorWebNeedsToken());
```

to:

```dart
// DEV-ONLY (Phase 2 walkthrough 2026-05-14, REVERT BEFORE COMMIT):
// Skip onboarding and land directly on the authenticated app shell.
super(initial: const OperatorWebCompleted(session: kDemoOperatorWebSession));
```

### Patch 3 (apply when driving OW-4 business-scope inverse)

Patch `kDemoOperatorWebSession` in `lib/operator_web/auth/operator_web_auth_source.dart`:

```dart
// DEV-ONLY: business-scope variant for OW-4 inverse-case drive.
const OperatorWebSession kDemoOperatorWebBusinessSession = OperatorWebSession(
  uid: 'demo-operator-owner',
  email: 'owner@demo.forgeflow.test',
  displayName: 'Demo Operator Owner',
  operatorId: 'demo-operator',
  businessName: 'Demo Restaurant Group',
  primaryLocationId: null,   // <-- the key change
  // (preserve other fields from kDemoOperatorWebSession)
);
```

Then point `_DemoOperatorWebAuthSourceWithTeamSurfaces` at the business
variant for the inverse-case drive.

### Patch 4 (apply when driving OW-8c MFA-enrolled state)

Edit `DemoWebTeamUsersGateway` or `DemoWebSecurityGateway` (in
`lib/operator_web/services/demo_team_*_gateway.dart`) to seed the demo
Owner with at least one enrolled MFA factor — see existing test fixture
`demo-mfa-factor-owner-totp` referenced in
`demo_team_audit_log_gateway.dart` for the shape.

### .claude/launch.json

Gitignored. Required entries:

```json
{
  "version": "0.0.1",
  "configurations": [
    {
      "name": "operator-web-demo",
      "runtimeExecutable": "flutter",
      "runtimeArgs": [
        "run", "-d", "web-server", "--web-port=8181",
        "--web-hostname=0.0.0.0",
        "-t", "lib/main_operator_web.dart",
        "--dart-define=OPERATOR_WEB_DEMO_AUTH=true"
      ],
      "port": 8181
    },
    {
      "name": "admin-console-demo",
      "runtimeExecutable": "flutter",
      "runtimeArgs": [
        "run", "-d", "web-server", "--web-port=8182",
        "--web-hostname=0.0.0.0",
        "-t", "lib/main_admin.dart",
        "--dart-define=ADMIN_DEMO_AUTH=true"
      ],
      "port": 8182
    }
  ]
}
```

---

## Boot procedure — operator-web

```
1. Apply Patch 1 + Patch 2 (and Patch 3 / Patch 4 if the surfaces-to-drive
   list calls for them).
2. preview_start name="operator-web-demo".
3. Bash poll: `until curl -sf http://localhost:8181/main_module.bootstrap.js >/dev/null; do sleep 3; done`.
4. preview_screenshot (page shows splash).
5. preview_eval the manual loader invocation:
       (async () => {
         await window._flutter.loader.load({
           onEntrypointLoaded: async (init) => {
             const appRunner = await init.initializeEngine();
             await appRunner.runApp();
           }
         });
       })()
6. Wait ~30-45s for DDC modules to evaluate (705 .lib.js files).
7. preview_eval: click flt-semantics-placeholder to enable semantics.
8. Install __ff helper (see Helper scripts).
9. Drive surfaces.
```

---

## Helper scripts

### `window.__ff` click helper (paste into preview_eval after semantics enabled)

```js
window.__ff = {
  enableSem() {
    const ph = document.querySelector('flt-semantics-placeholder');
    if (ph) ph.click();
  },
  findNav(label) {
    const nodes = Array.from(document.querySelectorAll('flt-semantics'));
    const m = nodes.filter(n => (n.textContent||'').includes(label) && n.children.length === 0);
    if (!m.length) return null;
    m.sort((a,b) => (a.textContent||'').length - (b.textContent||'').length);
    return m[0];
  },
  clickRect(rect) {
    const glass = document.querySelector('flt-glass-pane');
    if (!glass) return false;
    const x = rect.left + rect.width/2, y = rect.top + rect.height/2;
    const opts = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y, button: 0, pointerType: 'mouse', isPrimary: true, pointerId: 1 };
    glass.dispatchEvent(new PointerEvent('pointerdown', opts));
    glass.dispatchEvent(new MouseEvent('mousedown', opts));
    glass.dispatchEvent(new PointerEvent('pointerup', opts));
    glass.dispatchEvent(new MouseEvent('mouseup', opts));
    glass.dispatchEvent(new MouseEvent('click', opts));
    return { x, y };
  },
  clickXY(x, y) { return this.clickRect({ left: x - 1, top: y - 1, width: 2, height: 2 }); },
  async clickNav(label) {
    this.enableSem();
    await new Promise(r => setTimeout(r, 300));
    const t = this.findNav(label);
    if (!t) return { ok: false, reason: 'not found' };
    const r = t.getBoundingClientRect();
    const res = this.clickRect(r);
    await new Promise(r => setTimeout(r, 800));
    return { ok: true, click: res, label };
  },
  async snapshot() {
    this.enableSem();
    await new Promise(r => setTimeout(r, 400));
    const nodes = Array.from(document.querySelectorAll('flt-semantics'));
    return nodes.filter(n => n.children.length <= 2)
      .map(n => (n.textContent||'').trim())
      .filter(t => t.length > 0 && t.length < 120);
  }
};
```

### Notes on Flutter web automation quirks

- **CanvasKit + semantic tree**: clicks on `flt-semantics` nodes themselves DON'T fire Flutter's pointer router. Always dispatch on `flt-glass-pane` at the bounding-rect center.
- **Overlay menus (popup_menu / dropdown items)**: dropdown overlay items are NOT in the semantic tree. Read pixel coordinates from a screenshot and use `__ff.clickXY(x, y)`.
- **Text inputs**: `input.value = '…'` + `dispatchEvent('input')` is IGNORED by Flutter's TextEditingController. `document.execCommand('insertText', …)` also ignored. The walkthrough avoids typing via the skip-onboarding patch; if a surface absolutely needs text entry, the fix is to drive a real KeyboardEvent at each character through the engine — much slower, kept as last resort.
- **`location.href` does not change** on nav. Operator-web router renders on auth state, not URL paths. Don't try `navigate()`-style routing.

---

## Workflow checklist (paste-friendly per session)

```
[ ] 1. Open this master plan; read top to bottom.
[ ] 2. Run `git status` — expect clean tree.
[ ] 3. Open `phase_2_walkthrough_verification.md` — confirm matrix state.
[ ] 4. Confirm Status board's "next action" still matches reality.
[ ] 5. Re-apply Patch 1 + Patch 2 (any others called for).
[ ] 6. preview_start operator-web-demo.
[ ] 7. Wait for bootstrap; run manual loader; enable semantics; install __ff.
[ ] 8. Drive the next [ ] surface from the lane's surfaces-to-drive list.
[ ] 9. Record evidence in the matrix (in the verification doc).
[ ]10. If a demo-fidelity bug surfaces — fix inline (<20 LoC) OR spawn
       worktree fix agent (>=20 LoC); add row to the Gaps register.
[ ]11. If a UX-decision gap surfaces — file as parked row in WAVE_2_LEDGER
       + add to Gaps register; ask operator before next session.
[ ]12. After 3-6 surfaces, refresh the matrix + master plan Status board.
       Revert dev patches, commit, push. Update commit hash in Status board.
[ ]13. Loop back to step 8 until lane is empty.
[ ]14. When lane is empty AND all acceptance criteria pass, flip lane to
       ✅ DONE in Status board, mark next lane's "next action".
[ ]15. Hand off to operator only if a UX decision is required, or the
       lane is fully done.
```

---

## Worktree agent contract (for fix agents + annotation agents)

Spawn with `isolation: worktree`. Each agent's prompt should be self-
contained and follow this contract:

```
Branch off the orchestrator's current branch.
Apply the canonical hooks: `pwsh scripts/install_git_hooks.ps1`.
Make the specific edit listed below.
Self-audit with file:line citations (Pattern B half-table).
Commit + push + open PR. NEVER merge. NEVER --no-verify. NEVER edit trackers.
Reply with PR number + Pattern B self-audit table + STOP.
```

Annotation agents get a per-tracker prompt template; fix agents get the
specific bug + the matrix evidence as context.

---

## Acceptance criteria for "Phase 2 walkthrough done" (all three lanes)

- All three Status board lanes flipped to ✅ DONE.
- Every operator-web-visible + admin-visible + mobile-visible row in
  WAVE_2_LEDGER + WAVE_EXECUTION_LEDGER + DEBUG_MD_IMPLEMENTATION_STATUS
  carries an inline `Phase 2 walkthrough <date>: <state> — <evidence>`
  annotation.
- Every demo-fidelity bug surfaced either has a merged fix PR OR is
  parked with explicit operator-deferral note.
- Every UX-decision gap is filed as a parked row awaiting operator
  decision.
- Dev patches reverted; tree clean.
- Operator signs off + tags `happy-state-<date>`.
