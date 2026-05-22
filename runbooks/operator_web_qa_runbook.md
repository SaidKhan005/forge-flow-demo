# Operator Web Console — In-Browser QA Runbook

Use this whenever you are asked to "run the web console tests", "pressure-test
the operator console", or "QA the operator web". This is the canonical method.

## Why this method

Flutter Web uses CanvasKit — the app renders entirely to a `<canvas>` element
inside a shadow DOM, so normal CSS-selector-based browser automation finds no
buttons. The method below bypasses that by:

1. Building a **profile** build (strips the DDC debug client that blocks
   any browser other than the one Flutter launched).
2. Injecting a **visibility polyfill** (`web/_qa_polyfill.js`) so Flutter's
   render loop ticks inside the Claude Preview in-app browser (headless
   Electron), which would otherwise pause `requestAnimationFrame`.
3. Enabling Flutter's **accessibility / semantics tree** (`flt-semantics`
   nodes), which overlays real DOM elements on top of the canvas that can
   be targeted by CSS ID selectors.

---

## Setup (one-time per machine, already done)

- `web/_qa_polyfill.js` — polyfill source, committed to the repo.
- `web/index.html` — already has `<script src="_qa_polyfill.js"></script>`
  as the first script after `<base href>`. Flutter copies `web/` into
  `build/web/` on every build, so the polyfill survives rebuilds.
- `.claude/launch.json` — has an `operator-web-static` config that serves
  `build/web` on port 8185 via dhttpd.

---

## Step 1 — Build

```powershell
# From the repo root (or the worktree)
& 'C:\src\flutter\bin\flutter.bat' build web --profile `
    -t lib/main_operator_web.dart `
    --dart-define=OPERATOR_WEB_DEMO_AUTH=true `
    --dart-define=OPERATOR_WEB_DEMO_SCENARIO=owner-location-completed
```

Build output lands in `build/web/`. Takes ~30 s.

---

## Step 2 — Serve

Use the `operator-web-static` launch config in `.claude/launch.json`, which
runs:

```
C:\Users\blund\AppData\Local\Pub\Cache\bin\dhttpd.bat --path build/web --port 8185
```

Or start it via the `preview_start` MCP tool (server name
`operator-web-static`, port 8185).

---

## Step 3 — Boot and verify

After the preview server starts, navigate to `http://localhost:8185`. The app
boots with the `owner-location-completed` demo scenario (signed in, post-
onboarding, Owner role, Demo Main Street Location scope).

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
    title: document.title                       // must be 'Forge & Flow - Operator Web Console'
  };
})()
```

All four values must pass before continuing.

---

## Step 4 — Enable Flutter semantics

Flutter emits `flt-semantics` DOM nodes only after the accessibility tree is
enabled. The polyfill-aware way to do this:

```javascript
(function() {
  // Dispatch click/pointer events directly on flt-semantics-placeholder
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

All interactive elements are `flt-semantics` nodes. Target them by:

- **CSS ID**: `#flt-semantic-node-XX` (use `preview_click`)
- **Text content**: query-select by `textContent` then dispatch pointer/click
  events manually (labels are in `textContent`, not `aria-label`)
- **Role**: `flt-semantics[role="button"]`, `flt-semantics[role="switch"]`,
  `flt-semantics[role="menuitem"]`

Helper to find a button by text and click it:

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
})('Operations Plan')
```

Use `preview_snapshot` after each navigation to read the full accessibility
tree and confirm the route loaded.

---

## Step 6 — Route checklist

Navigate to every route via the left nav. Expected nav button text values:

| Nav label | What to verify |
|---|---|
| `Operations\nPlan` | Weekly plan table (7 days), "Why these numbers?" section with 7 metric cards |
| `Business\nBusiness account` | Currency/locale pickers open menus; Save shows "Saved. Your changes are live."; scope-locked fields (business name, logo) disabled at location scope |
| `Business\nService periods` | Service periods list; Edit service periods dialog opens; Add caps at 4 periods; Close restores |
| `Business\nLocations` (business/org scope only) | Location list / org hierarchy; hidden when managing a single-location scope |
| `People\nMy account` | Profile shown; Change password dialog opens; 2FA setup dialog shows QR + shared secret; sign-in activity with time filters |
| `Team members` | Member list with all 4 statuses (Active/Suspended/Dormant/Removed); Invite dialog with org tree; Edit dialog with reason field; More actions context-aware (Suspend vs Reactivate) |
| `Access\nRoles & permissions` | Custom role with Edit/Delete; 8 default roles; New role editor with permission tree |
| `Active sessions` | "(this session)" label; Sign out per session |
| `Audit log` | Time range filters; 17 action-type filters; Export CSV; chain anchor badge |
| `Data & integrations\nVendor integrations` | 3 categories; POS picker shows 7 vendors |
| `Data accuracy` | Labor source toggle; blended wage calculator; per-role Edit/Remove |
| `People & access\nNotifications` | 3-channel toggles per notification; toggle state persists |

Also test cross-cutting:
- **Scope picker** (header "Managing …" button): org tree overlay opens
- **Sign out** button: confirm it navigates to welcome screen

---

## Step 7 — Document findings

For each issue found, record:

- **Severity**: High / Medium / Low
- **Route + steps to reproduce**
- **Expected vs actual behaviour**
- **Root cause hypothesis** (seeded data gap, missing validation, etc.)

---

## Known baseline (as of 2026-05-22)

Two open issues established during the first full run:

**DEF-01 · HIGH — Audit log empty in all time ranges (demo)**
- All 5 time filters return "No audit log entries match the current filters."
- My Account sign-in activity shows events in the same window — those events
  are not reaching the audit log table.
- Likely cause: `MockReplayDataSourceProvider` does not seed `audit_log_entries`.

**DEF-02 · MEDIUM — Change password: no validation feedback on empty submit**
- Clicking "Update password" with all fields blank leaves the dialog open
  silently — no inline error messages appear.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `canvasCount` = 0 after boot | Reload the page; polyfill may not have fired before Flutter init — confirm `_qa_polyfill.js` is the first `<script>` in `index.html` |
| `flt-semantics` count = 0 after placeholder click | The placeholder is 1×1 at (-1,-1) and CSS clicks miss it — use the JS dispatch approach in Step 4, not `preview_click` |
| Nav button `not found` | A popup menu or dialog may be open and the nav is not in the current semantics tree; dismiss with Escape first |
| `preview_snapshot` truncates | The tree is large; use `preview_eval` with targeted `querySelectorAll` to read specific sections instead |
| Build takes >5 min | Normal for first build after `flutter clean`; subsequent profile builds are ~30 s |
