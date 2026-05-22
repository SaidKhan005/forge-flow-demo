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
# From the repo root (or the worktree)
& 'C:\src\flutter\bin\flutter.bat' build web --profile `
    -t lib/main_admin.dart `
    --dart-define=ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true
```

`ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true` boots the app as a fully-privileged
ecosystem super-admin with no login screen and all gateways served from
in-memory demo fixtures — no proxy required. Build output lands in
`build/web/`. Takes ~30 s.

---

## Step 2 — Serve

Use the `admin-web-static` launch config in `.claude/launch.json`, which
runs:

```
C:\Users\blund\AppData\Local\Pub\Cache\bin\dhttpd.bat --path build/web --port 8186
```

Or start it via the `preview_start` MCP tool (server name
`admin-web-static`, port 8186).

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

## Step 5 — Navigate and interact

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

The admin shell uses a **left nav rail** (220 px wide) on screens ≥ 720 px.
Nav items are grouped into labeled sections: Operations · AI · System
monitoring · Service setup · Your account.

---

## Step 6 — Route checklist

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

## Step 7 — Document findings

For each issue found, record:

- **Severity**: High / Medium / Low
- **Route + steps to reproduce**
- **Expected vs actual behaviour**
- **Root cause hypothesis**

---

## Known baseline (as of 2026-05-22)

First full run with polyfill methodology not yet executed — no established
baseline defects for admin console. Run this runbook and document any
findings to establish the baseline here.

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
