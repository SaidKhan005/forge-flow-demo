# Admin Console — In-Browser QA Runbook

Use this whenever you are asked to "run the admin console tests",
"pressure-test the admin console", or "QA the admin web". This is
the canonical method.

## Why this method

Same reasoning as the operator web runbook — Flutter Web renders entirely to
a `<canvas>` inside `flt-glass-pane`, so CSS selectors find no buttons. The
`_qa_polyfill.js` already committed to `web/` solves the headless Electron
visibility/rAF problem. Steps below are identical in shape to
`runbooks/operator_web_qa_runbook.md` but use the admin entrypoint and
super-admin share-preview mode (no proxy, no login screen, all routes open).

---

## Setup (one-time per machine, already done)

- `web/_qa_polyfill.js` — polyfill source, committed to the repo.
- `web/index.html` — already has `<script src="_qa_polyfill.js"></script>`
  as the first script after `<base href>`. Survives every `flutter build web`.
- `.claude/launch.json` — has an `admin-web-static` config that serves
  `build/web` on port 8186 via dhttpd.

---

## Step 1 — Build

```powershell
# From the repo root (or the worktree). Use whatever `flutter` resolves
# to on PATH; the SDK path is machine-specific (see the note below).
flutter build web --profile `
    -t lib/main_admin.dart `
    --dart-define=ADMIN_SHARE_PREVIEW=true `
    --dart-define=ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true `
    --dart-define=ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true
```

All three dart-defines are required together to boot into demo data as a
super-admin without a live proxy. With only the role selector, the app tries
to reach a live server and shows "Admin live wiring failed... ADMIN_PROXY_BASE_URI
is required". What each flag does:

- `ADMIN_SHARE_PREVIEW=true` opens straight into seeded in-memory fixture data
  with no Firebase, no proxy, and no login screen.
- `ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true` picks the fixture identity: a
  fully-privileged ecosystem super-admin (omit it and you get read-only support).
- `ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true` is the release/profile fail-closed
  opt-in. A non-debug build (like `--profile`) refuses fixture auth without it
  and lands on a "fixture auth blocked" screen instead of the console.

Build output lands in `build/web/`. Takes ~30 s.

---

## Step 2 — Serve

Serve the `build/web` output on port 8186 with ANY static file server. The
specific server does not matter, only that it serves `build/web` on 8186. For
example, from inside `build/web`:

```
python -m http.server 8186
```

The `.claude/launch.json` `admin-web-static` config and the `preview_start`
MCP tool (server name `admin-web-static`, port 8186) both do the same thing
via dhttpd:

```
dhttpd --path build/web --port 8186
```

Note: the dhttpd path and the flutter SDK path baked into `.claude/launch.json`
are machine-specific (they point at one developer's user profile), and dhttpd
may not be installed at all. Use whatever `flutter` resolves to on your PATH
and whatever static server you have available. The only requirement is that
`build/web` is served on port 8186.

---

## Step 3 — Boot and verify

Navigate to `http://localhost:8186`. The app boots as a super-admin with the
in-memory demo dataset (Demo Diner Co. + Sunset Cafe Group operators).

Verify the polyfill is active and Flutter painted:

```javascript
(function() {
  var glass = document.querySelector('flt-glass-pane');
  var canvasCount = glass && glass.shadowRoot
    ? glass.shadowRoot.querySelectorAll('canvas').length : 0;
  return {
    visibilityState: document.visibilityState,  // must be 'visible'
    hasFocus: document.hasFocus(),              // must be true
    canvasCount: canvasCount,                   // must be >= 1
    title: document.title                       // must be 'Forge & Flow Admin Console'
  };
})()
```

All four values must pass before continuing.

---

## Step 4 — Enable Flutter semantics

```javascript
(function() {
  var p = document.querySelector('flt-semantics-placeholder');
  if (p) {
    p.focus();
    p.dispatchEvent(new MouseEvent('click', {bubbles: true}));
    p.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true}));
    p.dispatchEvent(new PointerEvent('pointerup',   {bubbles: true}));
  }
  return !!p;
})()
```

Confirm semantics are live:

```javascript
document.querySelectorAll('flt-semantics').length  // expect > 50
```

---

## Step 5 — Run the assertion-based test suite

Paste the full contents of `web/_qa_runner_admin.js` into a `preview_eval` call.
The runner handles semantics enabling internally — no separate Step 4 invocation
is needed when running the full suite.

**What the runner covers (baseline 2026-05-26):**

- **5 boot checks** — `visibilityState`, `hasFocus()`, canvas present,
  `document.title` is `Forge & Flow Admin Console`, `flt-semantics` count > 30
- **27 shell + identity assertions** — Forge & Flow brand, Admin Console label,
  Demo data banner, demo super-admin email, "Managing …" scope chip, 4 explicit
  side-nav section labels (AI / System monitoring / Service setup / Your account
  — Operations is implicit, no rendered header), and presence of all 18 nav rows
- **18 primary nav routes** — each asserts route-specific text labels, key
  affordances, filter chips, seed content, and no generic error state:
  Business accounts, Team members, Roles & permissions, Audit log, Vendor
  integrations, Data accuracy, Service periods, Plans and limits, Knowledge base,
  AI Metrics, System health, Support logs, Connected services, Vendor
  applicability, Launch controls, Default roles, My account, Notifications
- **1 interaction test** — Audit log "Last 7 days" filter chip keeps content rendered
- **2 passive regression checks (live click skipped — see runner notes)**:
  R-03 (business "Suspend" affordance present), R-04 (AI Metrics "Run metrics check"
  CTA present). The live destructive-action / dialog-dismiss contracts belong to
  the integration test suite at `integration_test/admin_pressure/`.
- **1 RenderFlex-overflow guard** — taps `console.error` for the full nav tour
  and fails if any RenderFlex overflow was logged

**Expected output on a clean run:**

```json
{
  "passed": 124,
  "failed": 0,
  "skipped": 0,
  "summary": "PASSED 124/124"
}
```

Any `FAIL` entry includes a `detail` field stating what was not found. Fix,
rebuild (`flutter build web --profile ...`), and re-run to confirm.

**This is the canonical execution path.** Steps 6–7 below document the manual
approach; use them only for targeted investigation of a specific failing assertion.

**Why two regressions are passive (presence-only) instead of live-click:**
clicking the business-level Suspend button OR the AI Metrics "Run metrics check"
button in share-preview mode currently wedges Flutter's gesture loop and the
subsequent navigation (the "Close / Stay here / Open Business accounts" guard
dialog blocks every following route). The browser runner asserts presence; the
integration test suite at `integration_test/admin_pressure/` owns the live click
contracts (`scenario_ops_ba_04_suspend_business_requires_confirmation.dart` and
`scenario_ai_obs_02_cancel_confirmation_dismisses.dart`). Document any new
share-preview navigation hangs in the "Document findings" step below before
expanding the runner's live-click coverage.

---

## Step 6 — Navigate and interact (manual fallback)

Identical mechanism to the operator web runbook. Target `flt-semantics` nodes
by text content or role. Helper to find a nav item by text and click it:

```javascript
(function(label) {
  var all = document.querySelectorAll('flt-semantics[role="button"]');
  for (var i = 0; i < all.length; i++) {
    if (all[i].textContent.replace(/\n/g, ' ').trim() === label) {
      all[i].dispatchEvent(new PointerEvent('pointerdown', {bubbles: true}));
      all[i].dispatchEvent(new PointerEvent('pointerup',   {bubbles: true}));
      all[i].dispatchEvent(new MouseEvent('click',         {bubbles: true}));
      return 'clicked: ' + all[i].id;
    }
  }
  return 'not found: ' + label;
})('Business accounts')
```

The admin shell uses a **left nav rail** (280 px wide) on screens ≥ 720 px.
Nav items are grouped into labeled sections: Operations · AI · System
monitoring · Service setup · Your account.

---

## Step 7 — Route checklist

### Primary nav routes (visible in the left nav rail)

| Nav label | What to verify |
|---|---|
| `Business accounts` | Two demo operators (Demo Diner Co., Sunset Cafe Group); drill into each; all tiles (Team, Access, Security & audit, Timing, Integrations, Data accuracy, Polling, Support workspace) navigate to their hidden routes |
| `Vendor Applicability` | Wage/covers/polling applicability tables render; vendor rows show enabled/disabled with metadata; super_admin can toggle |
| `Polling Setup` | Polling configuration table renders; admin-only controls visible |
| `Plans and limits` | Scope picker (Business/Org unit/Location); tier table populates; super_admin sees edit controls |
| `Knowledge base` | Scope picker; corpus content list; "Graph candidates" tab; commit button disabled with "no live tenant" banner |
| `AI Metrics` | Scope picker; cost/usage/dormancy/margin/cap-event panels render; read-only |
| `System health` | Health check categories (Advisor data, app services, ecosystem dependencies); "Run check" button fires and result appears |
| `Support logs` | Log list renders; filter by operator/location scope works |
| `Connected services` | Scope picker; provider health tiles and platform service key summary render; super_admin sees edit affordances |
| `Launch controls` | Feature flag list renders; toggle a flag — confirmation dialog appears; undo restores |
| `Default roles` | Published role catalog versions list; "Edit draft" and "Publish" affordances; publish confirmation requires audit reason field |
| `My account` | Sign-in details; two-factor status card; active sessions list with "Revoke" buttons; "Sign out everywhere" button |
| `Notifications` | Notification category list; toggle a channel — state persists after toggle |

### Hidden routes (reached from Business accounts tiles)

| Route | Entry point | What to verify |
|---|---|---|
| Support workspace | Business accounts "Open support workspace" | Read-only operator view with all support context panels |
| People, access & roles | Business accounts "Team" | Members table (Active/Suspended/Dormant; MFA status); invite dialog; suspend/reactivate/delete require reason field |
| Access | Business accounts "Access" | Roles tab (seeded + custom); Hierarchy tab (org unit tree CRUD); Sessions tab (force-logout any non-self session) |
| Security & audit | Business accounts "Security & audit" | Audit log table with actor kind + time window filters; export CSV (requires admin reason + MFA); PII erasure with 24h grace shown |
| Vendor integrations | Business accounts location Integrations tile | Location-scoped vendor connection list; connect/test/disconnect/logs |
| Timing | Business accounts location Timing tile | Effective timezone, business-day start, week-start, service periods; repair affordances for super_admin |
| Data accuracy | Business accounts "Data accuracy" | Covers/wage data accuracy per vendor; super_admin can toggle |

Also test cross-cutting:
- **Role pill** (header): shows "Ecosystem admin" in super-admin share-preview mode
- **Identity chip** (header): shows the demo super-admin email
- **Sign out** button in header: navigates to the sign-out / restart screen

---

## Step 8 — Document findings

For each issue found, record:

- **Severity**: High / Medium / Low
- **Route + steps to reproduce**
- **Expected vs actual behaviour**
- **Root cause hypothesis**

---

## Known baseline (as of 2026-05-26)

Full run executed with the assertion runner: **PASSED 124/124, 0 failures, 0 skips.**

Two surface-level product issues are NOT covered by live-click assertions because
they wedge Flutter's gesture loop in share-preview mode (Cancel taps stop reaching
Flutter and the page becomes navigation-locked):

- **PRD-01 · OPEN** — Business-level "Suspend" wedges navigation after first click.
  The runner asserts only that the affordance is present. Reproduction: open Business
  accounts, click Suspend at the org-unit-root level, observe page no longer responds
  to nav clicks. Fix candidate: prevent the destructive-action confirmation from
  taking over the route guard, OR plumb the "Close / Stay here / Open Business
  accounts" guard dialog so Escape / Stay-here dismisses correctly.

- **PRD-02 · OPEN** — AI Metrics "Run metrics check" confirmation Cancel does not
  re-enter Flutter's event handler. The runner asserts only that the CTA is present.
  Reproduction: nav to AI Metrics, click Run metrics check, click Cancel — dialog
  stays open and the whole page is then unresponsive to subsequent clicks.

Both issues are covered by the integration test suite at
`integration_test/admin_pressure/` (regression scenarios
`scenario_ops_ba_04_suspend_business_requires_confirmation.dart` and
`scenario_ai_obs_02_cancel_confirmation_dismisses.dart`).

Updating runner / IA expectations: when the admin shell adds, renames, or
restructures a nav row, update the `NAV_ITEMS` array in
`web/_qa_runner_admin.js` and re-baseline the route-specific asserts by
running the manual capture loop in Step 6. The runner is intentionally
text-driven (not DOM-key-driven) to survive Flutter Web's canvas-rendered
layout while still catching meaningful content drift.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `canvasCount` = 0 after boot | Reload; confirm `_qa_polyfill.js` is the first `<script>` in `index.html` |
| `flt-semantics` count = 0 after placeholder click | Use the JS dispatch approach in Step 4, not `preview_click` — the placeholder is 1×1 at (-1,-1) |
| Nav button `not found` | A dialog or context menu may be open; dismiss with Escape then retry |
| Hidden route not reachable via nav | Navigate from Business accounts tiles as described in the checklist above |
| `preview_snapshot` truncates | Use `preview_eval` with targeted `querySelectorAll` instead |
| Build takes >5 min | Normal for first build after `flutter clean`; subsequent profile builds are ~30 s |
| Port 8186 already in use | Stop any previous dhttpd process or use `netstat -ano | findstr 8186` to identify the process |
