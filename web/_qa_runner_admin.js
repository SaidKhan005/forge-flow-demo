// QA assertion runner — admin console.
// Paste into preview_eval (or inject via a <script src="…"> tag and read
// `window.__adminQaResult`). Returns structured pass/fail JSON.
// Mirrors web/_qa_runner.js (operator web) but targets the admin
// console's share-preview build (lib/main_admin.dart with
// ADMIN_SHARE_PREVIEW=true + ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true +
// ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true).
//
// IA mapped 2026-05-26 against current origin/master. The admin shell
// renders a left nav rail with five sections (Operations is implicit —
// no rendered section header — followed by AI / System monitoring /
// Service setup / Your account). Most former "hidden routes via
// Business accounts tiles" are now top-level nav rows.
//
// NOT shipped to production.
(async function () {
  'use strict';

  // Heartbeat + error capture so a calling harness can detect a stuck
  // or failed runner without relying on console output.
  window.__adminQaHeartbeat = { stage: 'starting', at: Date.now() };
  window.__adminQaError = null;

  function _hb(stage) {
    window.__adminQaHeartbeat = { stage: stage, at: Date.now() };
  }

  try {

  var _results = [];

  function pass(route, test) {
    _results.push({ route: route, test: test, status: 'PASS' });
  }
  function fail(route, test, detail) {
    _results.push({ route: route, test: test, status: 'FAIL', detail: detail || '' });
  }
  function skip(route, test, reason) {
    _results.push({ route: route, test: test, status: 'SKIP', detail: reason || '' });
  }

  function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  function getText() {
    var nodes = document.querySelectorAll('flt-semantics');
    var arr = [];
    for (var i = 0; i < nodes.length; i++) {
      var t = nodes[i].textContent.replace(/\n/g, ' ').trim();
      if (t) arr.push(t);
    }
    return arr;
  }

  function getSemCount() {
    return document.querySelectorAll('flt-semantics').length;
  }

  function hasText(str) {
    var arr = getText();
    for (var i = 0; i < arr.length; i++) {
      if (arr[i].indexOf(str) !== -1) return true;
    }
    return false;
  }

  function hasTextRe(re) {
    var arr = getText();
    for (var i = 0; i < arr.length; i++) {
      if (re.test(arr[i])) return true;
    }
    return false;
  }

  function hasAnyText(candidates) {
    for (var i = 0; i < candidates.length; i++) {
      if (hasText(candidates[i])) return true;
    }
    return false;
  }

  function assertText(route, text) {
    if (hasText(text)) pass(route, '"' + text + '" present');
    else fail(route, '"' + text + '" present', 'not found in semantics tree');
  }

  function assertTextRe(route, re, label) {
    if (hasTextRe(re)) pass(route, label || re.toString() + ' present');
    else fail(route, label || re.toString() + ' present', 'no match in semantics tree');
  }

  function assertNoText(route, text) {
    if (!hasText(text)) pass(route, '"' + text + '" absent');
    else fail(route, '"' + text + '" absent', 'unexpectedly found in semantics tree');
  }

  function assertAnyText(route, candidates, label) {
    if (hasAnyText(candidates)) pass(route, label || 'one of [' + candidates.join(', ') + '] present');
    else fail(route, label || 'one of [' + candidates.join(', ') + '] present', 'none found in semantics tree');
  }

  function clickLabel(label) {
    var all = document.querySelectorAll('flt-semantics[role="button"]');
    for (var i = 0; i < all.length; i++) {
      var t = all[i].textContent.replace(/\n/g, ' ').trim();
      if (t === label || t.startsWith(label)) {
        all[i].dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
        all[i].dispatchEvent(new PointerEvent('pointerup',   { bubbles: true }));
        all[i].dispatchEvent(new MouseEvent('click',         { bubbles: true }));
        return true;
      }
    }
    return false;
  }

  function clickAnyLabel(candidates) {
    for (var i = 0; i < candidates.length; i++) {
      if (clickLabel(candidates[i])) return candidates[i];
    }
    return null;
  }

  function pressEscape() {
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }));
    document.dispatchEvent(new KeyboardEvent('keyup',   { key: 'Escape', bubbles: true }));
  }

  async function nav(route, labels) {
    var candidates = Array.isArray(labels) ? labels : [labels];
    var clicked = clickAnyLabel(candidates);
    if (clicked) {
      pass(route, 'navigation: clicked "' + clicked + '"');
    } else {
      fail(route, 'navigation: clicked ' + candidates.join(' / '), 'button not found');
    }
    await wait(1100);
    return clicked;
  }

  // Console-error tap for RenderFlex / framework errors. Set up BEFORE
  // any nav so we catch overflows from the initial paint and every
  // route transition.
  var _consoleErrors = [];
  var _origErr = console.error;
  console.error = function () {
    try {
      var s = Array.prototype.slice.call(arguments).map(function (a) {
        return (a && a.message) ? a.message : String(a);
      }).join(' ');
      _consoleErrors.push(s);
    } catch (e) { /* ignore */ }
    return _origErr.apply(console, arguments);
  };

  // ─── ENABLE SEMANTICS ─────────────────────────────────────────────────────
  _hb('semantics');

  var p = document.querySelector('flt-semantics-placeholder');
  if (p) {
    p.focus();
    p.dispatchEvent(new MouseEvent('click',         { bubbles: true }));
    p.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
    p.dispatchEvent(new PointerEvent('pointerup',   { bubbles: true }));
  }
  await wait(2500);

  // Defensive modal-dismissal sweep. If a prior run or stray click
  // left a dialog open, dismiss it so route assertions are not
  // poisoned by carry-over state.
  for (var dsi = 0; dsi < 3; dsi++) {
    var modal = document.querySelector('flt-semantics[role="alertdialog"], flt-semantics[role="dialog"]');
    if (!modal) break;
    if (!clickAnyLabel(['Cancel', 'Close', 'Stay here'])) pressEscape();
    await wait(400);
  }

  // ─── BOOT CHECKS (5) ──────────────────────────────────────────────────────
  _hb('boot');

  var BOOT = 'boot';

  if (document.visibilityState === 'visible') pass(BOOT, 'visibilityState visible');
  else fail(BOOT, 'visibilityState visible', 'got: ' + document.visibilityState);

  if (document.hasFocus()) pass(BOOT, 'document.hasFocus() true');
  else fail(BOOT, 'document.hasFocus() true', 'hasFocus() returned false');

  var glassPaneShadow = null;
  var gp = document.querySelector('flt-glass-pane');
  if (gp && gp.shadowRoot) glassPaneShadow = gp.shadowRoot;
  if (glassPaneShadow && glassPaneShadow.querySelectorAll('canvas').length >= 1) {
    pass(BOOT, 'flt-glass-pane shadow root has at least 1 canvas');
  } else {
    fail(BOOT, 'flt-glass-pane shadow root has at least 1 canvas',
      gp ? (gp.shadowRoot ? 'shadow root has no canvas' : 'shadowRoot is null') : 'flt-glass-pane not found');
  }

  if (document.title === 'Forge & Flow Admin Console') {
    pass(BOOT, 'document.title correct');
  } else {
    fail(BOOT, 'document.title correct', 'got: ' + document.title);
  }

  // Threshold tuned for admin's first paint (Business accounts =
  // scope picker + hierarchy + nav + header). Lower than operator-web's
  // 50 because the admin shell renders fewer per-row affordances by
  // default and the body shows "Pick a business first" until a scope
  // is selected.
  var semCount = getSemCount();
  if (semCount > 30) pass(BOOT, 'flt-semantics count > 30 after enable (got ' + semCount + ')');
  else fail(BOOT, 'flt-semantics count > 30 after enable', 'got ' + semCount);

  // ─── SHELL / IDENTITY ─────────────────────────────────────────────────────
  _hb('shell');

  var SHELL = 'shell';

  assertText(SHELL, 'Forge & Flow');
  assertText(SHELL, 'Admin Console');
  assertText(SHELL, 'Demo data');
  assertText(SHELL, 'demo.super.admin@forgeflow.test');
  // Scope chip text — admin shell exposes a "Managing <business> <scope>"
  // chip when a default scope is selected by share-preview seeding.
  assertTextRe(SHELL, /^Managing /, 'header scope chip "Managing …" present');

  // Side-nav section labels. Operations is implicit (no rendered header);
  // the other four are explicit.
  assertText(SHELL, 'AI');
  assertText(SHELL, 'System monitoring');
  assertText(SHELL, 'Service setup');
  assertText(SHELL, 'Your account');

  // Nav items must all be present (passive presence check, no clicks).
  var NAV_ITEMS = [
    'Business accounts', 'Team members', 'Roles & permissions', 'Audit log',
    'Vendor integrations', 'Data accuracy', 'Service periods',
    'Plans and limits', 'Knowledge base', 'AI Metrics',
    'System health', 'Support logs',
    'Connected services', 'Vendor applicability', 'Launch controls', 'Default roles',
    'My account', 'Notifications',
  ];
  for (var ni = 0; ni < NAV_ITEMS.length; ni++) {
    assertText(SHELL, NAV_ITEMS[ni]);
  }

  // Expand the scope hierarchy so subsequent routes have a business
  // selected — most routes show "Pick a business first" otherwise.
  clickLabel('Expand hierarchy');
  await wait(700);
  clickLabel('Demo Diner Co. Org unit scope');
  await wait(900);

  // ─── R01 — Business accounts (operators) ──────────────────────────────────
  _hb('R_BA');

  var R_BA = 'Business accounts';
  await nav(R_BA, 'Business accounts');

  assertText(R_BA, 'Business accounts');
  assertText(R_BA, 'New business');
  assertText(R_BA, 'Scope');
  // Hierarchy tree should now show Demo Diner Co. plus its sub-tree.
  assertText(R_BA, 'Demo Diner Co.');
  assertAnyText(R_BA, ['Toronto Yorkville', 'Vancouver Robson'],
    'at least one demo location present in the hierarchy');
  assertNoText(R_BA, 'Something went wrong');

  // Regression R-03 (passive): business-level "Suspend" affordance must
  // be reachable. KNOWN BREAK (2026-05-26): the live click destroys
  // session state in share-preview mode and wedges subsequent
  // navigation — we assert only presence. The destructive-action
  // contract belongs to the integration test suite at
  // integration_test/admin_pressure/ops_business_accounts/scenario_ops_ba_04_suspend_business_requires_confirmation.dart.
  var suspendPresent = false;
  var sBtns = document.querySelectorAll('flt-semantics[role="button"]');
  for (var sbi = 0; sbi < sBtns.length; sbi++) {
    var sbt = sBtns[sbi].textContent.replace(/\n/g, ' ').trim();
    if (sbt === 'Suspend' || sbt === 'Suspend org unit' || sbt === 'Suspend location') {
      suspendPresent = true; break;
    }
  }
  if (suspendPresent) {
    pass(R_BA, 'R-03 reg: business "Suspend" affordance present (live click skipped — see runner note)');
  } else {
    skip(R_BA, 'R-03 reg: business "Suspend" affordance present',
      'no Suspend button on hierarchy nodes for this fixture');
  }

  // ─── R02 — Team members ───────────────────────────────────────────────────
  _hb('R_TM');

  var R_TM = 'Team members';
  await nav(R_TM, 'Team members');

  assertText(R_TM, 'Invite member');
  assertAnyText(R_TM, ['Status', 'Role', 'Two-factor sign-in'],
    'at least one filter chip present');
  assertNoText(R_TM, 'Something went wrong');

  // ─── R03 — Roles & permissions ────────────────────────────────────────────
  _hb('R_RP');

  var R_RP = 'Roles & permissions';
  await nav(R_RP, 'Roles & permissions');

  assertText(R_RP, 'New role');
  assertTextRe(R_RP, /Custom roles \(\d+\)/, '"Custom roles (N)" header present');
  assertTextRe(R_RP, /Default roles \(\d+\)/, '"Default roles (N)" header present');
  assertAnyText(R_RP, ['Owner', 'General Manager', 'Location Manager', 'Super admin'],
    'at least one default role name present');
  assertNoText(R_RP, 'Something went wrong');

  // ─── R04 — Audit log ──────────────────────────────────────────────────────
  _hb('R_AL');

  var R_AL = 'Audit log';
  await nav(R_AL, 'Audit log');

  assertText(R_AL, 'Export CSV');
  assertText(R_AL, 'Filters');
  assertText(R_AL, 'Last 7 days');
  assertText(R_AL, 'Last 30 days');
  assertAnyText(R_AL, ['Last 24 hours', 'Last 90 days', 'Custom range'],
    'at least one extra time-range filter present');
  assertAnyText(R_AL, ['Invited team member', 'Suspended team member', 'Assigned role'],
    'at least one action-type row visible');
  assertNoText(R_AL, 'Something went wrong');

  // Interaction R04-i1: Click "Last 7 days" filter chip — page should
  // still render audit log content.
  var lastClicked = clickLabel('Last 7 days');
  if (lastClicked) {
    await wait(600);
    if (hasText('Filters') || hasText('Export CSV')) {
      pass(R_AL, 'interaction: Last 7 days filter keeps Audit log content rendered');
    } else {
      fail(R_AL, 'interaction: Last 7 days filter keeps Audit log content rendered',
        'audit log markers gone after filter click');
    }
  } else {
    skip(R_AL, 'interaction: Last 7 days filter', 'button not found');
  }

  // ─── R05 — Vendor integrations ────────────────────────────────────────────
  _hb('R_VI');

  var R_VI = 'Vendor integrations';
  await nav(R_VI, 'Vendor integrations');

  // Org-unit scope shows the "select a location" empty state.
  assertAnyText(R_VI, [
    'Select a location to edit vendor integrations',
    'Manage the services connected to a location',
  ], 'vendor-integrations route marker present');
  assertNoText(R_VI, 'Something went wrong');

  // ─── R06 — Data accuracy ──────────────────────────────────────────────────
  _hb('R_DA');

  var R_DA = 'Data accuracy';
  await nav(R_DA, 'Data accuracy');

  assertAnyText(R_DA, [
    'Select a location to edit data accuracy',
    'Data accuracy',
  ], 'data-accuracy route marker present');
  assertNoText(R_DA, 'Something went wrong');

  // ─── R07 — Service periods ────────────────────────────────────────────────
  _hb('R_SP');

  var R_SP = 'Service periods';
  await nav(R_SP, 'Service periods');

  assertText(R_SP, 'Edit service periods');
  assertAnyText(R_SP, ['Service period 1', 'First day of the business week'],
    'service-periods route marker present');
  assertAnyText(R_SP, ['Mon', 'Tue', 'Wed'], 'at least one day-of-week marker present');
  assertNoText(R_SP, 'Something went wrong');

  // ─── R08 — Plans and limits ───────────────────────────────────────────────
  _hb('R_PL');

  var R_PL = 'Plans and limits';
  await nav(R_PL, 'Plans and limits');

  // Three top tabs: Plans / Features / Businesses.
  assertText(R_PL, 'Plans');
  assertText(R_PL, 'Features');
  assertText(R_PL, 'Businesses');
  // Preset plan tiles.
  assertText(R_PL, 'Pilot');
  assertText(R_PL, 'Starter');
  assertText(R_PL, 'Premium');
  assertAnyText(R_PL, ['$0', '$250'], 'at least one plan price label present');
  assertNoText(R_PL, 'Something went wrong');

  // ─── R09 — Knowledge base ─────────────────────────────────────────────────
  _hb('R_KB');

  var R_KB = 'Knowledge base';
  await nav(R_KB, 'Knowledge base');

  assertText(R_KB, 'What the advisor knows');
  assertText(R_KB, 'Add knowledge');
  assertText(R_KB, 'Topics the advisor knows');
  assertTextRe(R_KB, /Showing \d+ of \d+/, '"Showing N of M" topic-count present');
  assertAnyText(R_KB, ['Food Safety Manual', 'FIFO', 'HACCP'],
    'at least one seeded topic name present');
  assertNoText(R_KB, 'Something went wrong');

  // ─── R10 — AI Metrics ─────────────────────────────────────────────────────
  _hb('R_AM');

  var R_AM = 'AI Metrics';
  await nav(R_AM, 'AI Metrics');

  assertText(R_AM, 'AI Metrics');
  assertText(R_AM, 'Run metrics check');
  assertAnyText(R_AM, ['Check AI Metrics', 'Review advisor usage'],
    'AI Metrics intro / CTA marker present');
  assertAnyText(R_AM, ['This month', 'Last month'],
    'at least one time-window pill present');
  assertNoText(R_AM, 'Something went wrong');

  // Regression R-04 (passive): "Run metrics check" CTA presence.
  // KNOWN BREAK (2026-05-26): the live click wedges Flutter's gesture
  // loop in share-preview mode — the confirmation dialog renders but
  // synthetic Cancel clicks never re-enter Flutter's event handler.
  // We assert only that the CTA is present + tappable. The full
  // Cancel-dismiss contract belongs to the integration test suite at
  // integration_test/admin_pressure/ai_observability/scenario_ai_obs_02_cancel_confirmation_dismisses.dart.
  var rcBtn = null;
  var btns0 = document.querySelectorAll('flt-semantics[role="button"]');
  for (var ri = 0; ri < btns0.length; ri++) {
    if (btns0[ri].textContent.replace(/\n/g, ' ').trim() === 'Run metrics check') {
      rcBtn = btns0[ri]; break;
    }
  }
  if (rcBtn) {
    pass(R_AM, 'R-04 reg: "Run metrics check" CTA present (live click skipped — see runner note)');
  } else {
    fail(R_AM, 'R-04 reg: "Run metrics check" CTA present',
      'button not found in semantics tree');
  }

  // ─── R11 — System health ──────────────────────────────────────────────────
  _hb('R_SH');

  var R_SH = 'System health';
  await nav(R_SH, 'System health');

  assertText(R_SH, 'System health');
  assertAnyText(R_SH, ['Check system health', 'Run system check'],
    'System health primary CTA present');
  assertNoText(R_SH, 'Something went wrong');

  // ─── R12 — Support logs ───────────────────────────────────────────────────
  _hb('R_SL');

  var R_SL = 'Support logs';
  await nav(R_SL, 'Support logs');

  assertText(R_SL, 'Refresh');
  assertAnyText(R_SL, ['Filter by type', 'Filter by when', 'Filter by result', 'Set at this scope'],
    'at least one Support logs filter chip present');
  assertNoText(R_SL, 'Something went wrong');

  // ─── R13 — Connected services ─────────────────────────────────────────────
  _hb('R_CS');

  var R_CS = 'Connected services';
  await nav(R_CS, 'Connected services');

  assertAnyText(R_CS, ['Platform provider keys', 'Anthropic API', 'Voyage embeddings'],
    'Connected-services platform-keys section present');
  assertAnyText(R_CS, ['Vendor connector catalog', 'POS', 'Vendor setup'],
    'Connected-services vendor-catalog section present');
  assertNoText(R_CS, 'Something went wrong');

  // ─── R14 — Vendor applicability ───────────────────────────────────────────
  _hb('R_VA');

  var R_VA = 'Vendor applicability';
  await nav(R_VA, 'Vendor applicability');

  assertText(R_VA, 'Refresh');
  assertText(R_VA, 'Add rule');
  assertTextRe(R_VA, /Current rules \(\d+\)/, '"Current rules (N)" header present');
  assertAnyText(R_VA, ['Use defaults', 'Reset defaults'],
    'Vendor-applicability defaults action present');
  assertNoText(R_VA, 'Something went wrong');

  // ─── R15 — Launch controls ────────────────────────────────────────────────
  _hb('R_LC');

  var R_LC = 'Launch controls';
  await nav(R_LC, 'Launch controls');

  // Launch controls renders a list of flags with Enable/Disable toggles.
  // The shape varies but at least one of these must be in the tree.
  assertAnyText(R_LC, ['Enable', 'Disable'],
    'at least one Launch-controls Enable/Disable affordance present');
  assertNoText(R_LC, 'Something went wrong');

  // ─── R16 — Default roles ──────────────────────────────────────────────────
  _hb('R_DR');

  var R_DR = 'Default roles';
  await nav(R_DR, 'Default roles');

  assertText(R_DR, 'Manage the starter roles every new business receives');
  assertText(R_DR, 'Add role');
  assertText(R_DR, 'Publish');
  assertText(R_DR, 'Discard changes');
  assertText(R_DR, 'History');
  assertAnyText(R_DR, ['Forge & Flow internal', 'Business defaults'],
    'Default-roles section header present');
  assertNoText(R_DR, 'Something went wrong');

  // ─── R17 — My account ─────────────────────────────────────────────────────
  _hb('R_MA');

  var R_MA = 'My account';
  await nav(R_MA, 'My account');

  assertText(R_MA, 'Identity');
  assertText(R_MA, 'Display name');
  assertText(R_MA, 'Email');
  assertText(R_MA, 'Role');
  assertText(R_MA, 'Demo Super Admin');
  assertText(R_MA, 'Ecosystem admin');
  assertText(R_MA, 'Security');
  assertText(R_MA, 'Change password');
  assertText(R_MA, 'Recent sign-in activity');
  assertTextRe(R_MA, /UTC/, 'at least one sign-in timestamp with UTC present');
  assertNoText(R_MA, 'Something went wrong');

  // ─── R18 — Notifications ──────────────────────────────────────────────────
  _hb('R_NO');

  var R_NO = 'Notifications';
  await nav(R_NO, 'Notifications');

  assertText(R_NO, 'About notifications');
  // Three channels mirror operator-web shape.
  assertText(R_NO, 'Push Notifications');
  assertText(R_NO, 'Email');
  assertText(R_NO, 'In-App Inbox');
  // Notification category section header.
  assertAnyText(R_NO, ['First Connect Backfill', 'Vendor became available', 'Audit and integrity'],
    'at least one notification category present');
  assertNoText(R_NO, 'Something went wrong');

  // ─── R-01 — RenderFlex overflow guard (full nav tour) ─────────────────────
  _hb('regression');

  // After the full nav tour, scan captured console.error stream for
  // any RenderFlex overflow. The 2026-05-22 manual pressure test
  // reported a 76 px overflow on _AdminHeaderBar at narrow widths;
  // this guard catches regressions on any route we visited above.
  var REG = 'regression';
  var overflowErrors = _consoleErrors.filter(function (s) {
    return /RenderFlex overflowed/i.test(s) ||
           /A RenderFlex/i.test(s);
  });
  if (overflowErrors.length === 0) {
    pass(REG, 'R-01 reg: no RenderFlex overflows across full nav tour');
  } else {
    fail(REG, 'R-01 reg: no RenderFlex overflows across full nav tour',
      overflowErrors.length + ' overflow(s) captured. First: ' + overflowErrors[0].slice(0, 200));
  }

  // ─── FINAL SUMMARY ────────────────────────────────────────────────────────

  // Restore console.error so we don't leak the wrapper into the page.
  console.error = _origErr;

  var passed  = _results.filter(function (r) { return r.status === 'PASS'; }).length;
  var failed  = _results.filter(function (r) { return r.status === 'FAIL'; }).length;
  var skipped = _results.filter(function (r) { return r.status === 'SKIP'; }).length;

  var report = {
    passed:  passed,
    failed:  failed,
    skipped: skipped,
    results: _results,
    summary: (failed === 0 ? 'PASSED' : 'FAILED') + ' ' + passed + '/' + (passed + failed)
  };

  try { window.__adminQaResult = report; } catch (e) { /* ignore */ }
  _hb('done');

  return report;

  } catch (err) {
    window.__adminQaError = (err && err.stack) ? err.stack : String(err);
    _hb('errored');
    throw err;
  }
})()
