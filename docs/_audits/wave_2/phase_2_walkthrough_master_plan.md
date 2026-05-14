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

| Lane | State | Last commit | Next action |
|---|---|---|---|
| **Operator-web** | 🟡 IN PROGRESS — Lane U + V + downstream H/W/R/S + loose OW-* matrix landed; 7 surfaces still need live drive; trackers carry changelog-only entries (NOT yet inline-annotated per operator preference) | `c92d8a9a` (2026-05-14 evening) — first matrix commit | Re-apply dev patches → drive 7 skipped surfaces → spawn 3 parallel agents (debug_md_status inline annotations / wave ledgers inline annotations / R-2L-FU-demo-fixture live fix) → audit + merge → close lane |
| **Admin console** | ⏸ PENDING | — | After operator-web lane closes. Need `admin-console-demo` launch entry + admin-side demo auth shortcut (ADMIN_DEMO_AUTH=true already exists per `run_admin_console_dev.ps1`). |
| **Mobile (Samsung A54 R5CW503HJHP)** | ⏸ PENDING | — | After admin closes. Need forgeflow APK build + adb install + demo seed. |

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
- [ ] **U-1 true post-sign-out Login screen** — Sign out from the demo session, reach the actual operator-web Login screen. Validate: no green logo, no "use the same forge & flow operator account..." subtitle, login form copy matches OW-0a/0b.
- [ ] **W-1 + W-1-FU Edit-member dialog body** — Click 3-dot → Edit member on a Team members row. Validate: dialog shows email + display name + role rotation + hierarchy rotation, all wired. Use the screenshot pixel-coord click pattern since the menu/dialog overlay doesn't expose in the semantics tree.
- [ ] **RP-15 benchmark override cap state transitions** — Submit an override at Location scope as the demo Owner; validate the manager-once cap UX kicks in (row goes read-only / cap copy shows / Save disables). Then attempt a second override and confirm the cap holds.
- [ ] **Permission Explainer screen** — Click "Permission Explainer" button on Roles & permissions. Validate: catalog rendering with product/category groupings matches the custom role editor's structure.
- [ ] **OW-12j polling cadence subtitle copy diff** — Scroll Data accuracy → Data Freshness section to the polling cadence + webhook subtitle copy. Confirm operator-requested strings: "Polling and data freshness applies to..." and "Vendors outside this list update in real time...".
- [ ] **OW-8c lost-authenticator with MFA enrolled** — Patch demo to have an MFA factor enrolled (`kDemoOperatorWebSession` + DemoWebSecurityGateway / DemoWebTeamUsersGateway). Then navigate to My account → Two-factor sign-in → verify the "Request removal" CTA + "Cancel request" copy (the 24h-window path) renders correctly per OW-8c.
- [ ] **OW-4 business-scope inverse** — Patch demo to a business-scoped session (`primaryLocationId: null` OR add `kDemoOperatorWebBusinessSession` factory). Confirm Locations item appears in left nav at Business scope.

### Tracker annotation status — operator-web lane scope

Phase 1 (changelog-only entry) is DONE in commit `c92d8a9a`. Phase 2 (inline annotation per row) is NOT done.

- [ ] **DEBUG_MD_IMPLEMENTATION_STATUS.md** — 0 / ~135 rows inline-annotated. Operator-web-relevant rows = ~80 rows.
- [ ] **WAVE_2_LEDGER.md** — 0 / 33 rows inline-annotated.
- [ ] **WAVE_EXECUTION_LEDGER.md (Wave 1)** — 0 / ~60 rows inline-annotated. Operator-web-visible Wave 1 backbone rows = ~25 rows (B1.a, B5.b, B6, B8, B8.b, B9.2, B10.1, B10.2, B11.1, C-2-C/D/F, C-4, C-6, C-7, C-7a, C-9, C-10, etc.).

### Gaps filed (master gap register)

| ID | Title | Source surface | Severity | Disposition | Status |
|---|---|---|---|---|---|
| `R-2L-FU-demo-fixture` | Operator-web demo `kDemoTeamRolesFixture` still seeds v1 5-role list, not v2 10-role catalog from R-2L PR #711 | Roles & permissions list | Demo-fidelity (cosmetic) | **FIX LIVE** (worktree agent) | open |
| `U-FU-hp11-account-demo-defaults` | "Inherits from Business: null / null" + "Business: null:00 local" string interpolation leak on Account scope notices | Business Account → Region / Business week sections | Demo-fidelity (cosmetic) | **FIX LIVE** | open |
| `MO-5b-FU-operator-web` | Two-factor sign-in / MFA / 2FA label drift extends to operator-web. Surfaces: My account Two-factor card; Audit log Action filter chips ("MFA enrolled (authenticator)" / "MFA factor removed" vs canonical "Reset two-factor sign-in") | My account, Audit log | Demo + production-copy (operator-facing) | **FIX LIVE** (canonical label needs operator confirm) | open — operator decision pending |
| `OW-6d-FU-edit-button-UX` | Operator's debug.md 156 literal ask was "instead of the 3 dot icon is should be a button saying edit user"; what shipped is a 3-dot menu with Edit member + Suspend + Reset password + Reset two-factor sign-in + Remove from team as menu items | Team members row | UX decision | **OPERATOR DECISION** — file as parked row | open — needs decision |
| `OW-4-FU-business-scope-demo` | Demo session is location-pinned via `kDemoOperatorWebSession.primaryLocationId='demo-location'`; the top-bar scope selector renders the H-3 tree but selecting "All locations / Business-wide" is a no-op | Top-bar selector | Demo-fidelity (walkthrough-only) | **OPERATOR DECISION** — defer V1.1 | open — defer |
| `B-FU-dev-csp` | Production CSP in `web/index.html` blocks Flutter dev DDC bootstrap; walkthrough requires a dev-only `unsafe-inline` + `unsafe-eval` carve-out applied + reverted per session | `web/index.html` CSP | Infra (developer-experience) | **DEFER** until operator-web lane closes; then dedicated slice | parked |

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
