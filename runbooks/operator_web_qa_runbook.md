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

## Step 5 — Run the assertion-based test suite

Paste the full contents of `web/_qa_runner.js` into a `preview_eval` call.
The runner handles semantics enabling internally — no separate Step 4 invocation
is needed when running the full suite.

**What the runner covers:**

- 5 boot checks — `visibilityState`, `hasFocus()`, canvas present, `document.title`,
  `flt-semantics` count > 50
- All 11 routes — each asserts specific text labels and no error state
- 4 interaction tests — service periods Edit dialog opens/closes, audit log Last 7 days
  filter keeps timestamps, vendor POS picker opens, DEF-02 regression (empty
  Change password submit shows validation text)

**Expected output on a clean run:**

```json
{
  "passed": 42,
  "failed": 0,
  "skipped": 0,
  "summary": "PASSED 42/42"
}
```

Any `FAIL` entry includes a `detail` field stating what was not found. Fix,
rebuild (`flutter build web --profile ...`), and re-run to confirm.

**This is the canonical execution path.** Steps 6–7 below document the manual
approach; use them only for targeted investigation of a specific failing assertion.

---

## Step 6 — Navigate and interact (manual fallback)

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

## Step 7 — Route checklist

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

## Step 8 — Document findings

For each issue found, record:

- **Severity**: High / Medium / Low
- **Route + steps to reproduce**
- **Expected vs actual behaviour**
- **Root cause hypothesis** (seeded data gap, missing validation, etc.)

---

## Known baseline (as of 2026-05-22)

Full run completed 2026-05-22. All 11 routes pass. Both prior defects confirmed fixed.

**DEF-01 · FIXED** — Audit log now shows 29 entries (2026-04-24 to 2026-05-05).
**DEF-02 · FIXED** — Empty "Update password" submit now shows inline validation:
  "Type your current password first so we can confirm it's you."

No new defects found.

---

## Polyfill internals (for maintainers)

The polyfill has 7 sections. All must be active for Flutter to render:

1. **Visibility** — `document.visibilityState → 'visible'`, `document.hidden → false`
2. **visibilitychange event** — dispatched on load to wake any already-attached listeners
3. **rAF replacement** — uses `new Worker('/_qa_rAF_worker.js')` (a served script file,
   not a blob URL — blob URLs are blocked by `script-src 'self'` CSP). The Worker runs
   `setInterval(postMessage, 16)` in a separate thread; Chromium throttles `setInterval`
   in the page to ~1 Hz when hidden, but Worker timers are not subject to that throttling.
4. **`document.hasFocus()` → true**
5. **`window.innerWidth/Height` → 1440/900** plus `outerWidth/Height`, `devicePixelRatio`,
   `screen.width/height`
6. **`window.visualViewport.width/height` → 1440/900** — this is the critical one.
   Flutter Web reads `visualViewport` (not `innerWidth`) to compute its logical viewport
   and set `flutter-view`'s CSS width/height. In headless Electron both are 0, so Flutter
   sets a 0×0 view and never schedules a render frame.
7. **`Element.prototype.getBoundingClientRect`** — returns a 1440×900 fake rect for
   `flutter-view`, `flt-glass-pane`, `BODY`, and `HTML`. Also patches `clientWidth/Height`.

The IIFE must be properly closed with `})();` — a missing closing brace is a silent
SyntaxError that prevents the entire polyfill from running.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `canvasCount` = 0 after boot | Check `visualViewport.width` — if 0, the polyfill's `})();` closing brace may be missing (syntax error) or the polyfill script ran from SW cache before the fix. Clear SW + cache (`caches.delete`) and hard-reload twice. |
| `canvasCount` = 0 and `flutterViewStyle` shows `0px` | `visualViewport` override not active — confirm polyfill ran (`[qa-polyfill]` log in console). If not, clear SW cache and reload. |
| Only 1–2 rAF frames per second | `setInterval` is throttled. Worker-based ticker should prevent this; confirm `_qa_rAF_worker.js` is served at `/_qa_rAF_worker.js` and no Worker error appears in console. |
| Worker error in console | CSP blocked the worker. Ensure `new Worker('/_qa_rAF_worker.js')` (served file), not a blob URL. |
| `flt-semantics` count = 0 after placeholder click | The placeholder is 1×1 at (-1,-1) and CSS clicks miss it — use the JS dispatch approach in Step 4, not `preview_click` |
| Nav button `not found` | A popup menu or dialog may be open and the nav is not in the current semantics tree; dismiss with Escape first |
| `preview_snapshot` truncates | The tree is large; use `preview_eval` with targeted `querySelectorAll` to read specific sections instead |
| Build takes >5 min | Normal for first build after `flutter clean`; subsequent profile builds are ~30 s |
