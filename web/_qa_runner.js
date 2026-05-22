// QA assertion runner — operator web console.
// Paste into preview_eval. Returns structured pass/fail JSON.
// NOT shipped to production.
(async function () {
  'use strict';

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

  function assertNoTextRe(route, re, label) {
    if (!hasTextRe(re)) pass(route, label || re.toString() + ' absent');
    else fail(route, label || re.toString() + ' absent', 'unexpectedly found in semantics tree');
  }

  function assertAnyText(route, candidates, label) {
    if (hasAnyText(candidates)) pass(route, label || 'one of [' + candidates.join(', ') + '] present');
    else fail(route, label || 'one of [' + candidates.join(', ') + '] present', 'none found in semantics tree');
  }

  function assertSemCountGt(route, threshold, label) {
    var count = getSemCount();
    if (count > threshold) pass(route, label || 'semantics count > ' + threshold + ' (got ' + count + ')');
    else fail(route, label || 'semantics count > ' + threshold, 'got ' + count);
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

  async function nav(label) {
    clickLabel(label);
    await wait(800);
  }

  // ─── BOOT SEQUENCE ────────────────────────────────────────────────────────

  // Enable semantics (polyfill already ran; Flutter is already painted)
  var p = document.querySelector('flt-semantics-placeholder');
  if (p) {
    p.focus();
    p.dispatchEvent(new MouseEvent('click',         { bubbles: true }));
    p.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
    p.dispatchEvent(new PointerEvent('pointerup',   { bubbles: true }));
  }
  await wait(1000);

  // ─── BOOT CHECKS ──────────────────────────────────────────────────────────

  var BOOT = 'boot';

  // visibilityState
  if (document.visibilityState === 'visible') pass(BOOT, 'visibilityState visible');
  else fail(BOOT, 'visibilityState visible', 'got: ' + document.visibilityState);

  // hasFocus
  if (document.hasFocus()) pass(BOOT, 'document.hasFocus() true');
  else fail(BOOT, 'document.hasFocus() true', 'hasFocus() returned false');

  // flt-glass-pane shadow root has canvas
  var glassPaneShadow = null;
  var gp = document.querySelector('flt-glass-pane');
  if (gp && gp.shadowRoot) glassPaneShadow = gp.shadowRoot;
  if (glassPaneShadow && glassPaneShadow.querySelectorAll('canvas').length >= 1) {
    pass(BOOT, 'flt-glass-pane shadow root has at least 1 canvas');
  } else {
    fail(BOOT, 'flt-glass-pane shadow root has at least 1 canvas',
      gp ? (gp.shadowRoot ? 'shadow root has no canvas' : 'shadowRoot is null') : 'flt-glass-pane not found');
  }

  // document.title
  if (document.title === 'Forge & Flow - Operator Web Console') {
    pass(BOOT, 'document.title correct');
  } else {
    fail(BOOT, 'document.title correct', 'got: ' + document.title);
  }

  // semantics count > 50
  var semCount = getSemCount();
  if (semCount > 50) pass(BOOT, 'flt-semantics count > 50 after semantics enable (got ' + semCount + ')');
  else fail(BOOT, 'flt-semantics count > 50 after semantics enable', 'got ' + semCount + ' — semantics may not be enabled');

  // ─── OPERATIONS PLAN ──────────────────────────────────────────────────────

  var R_OPS = 'Operations Plan';
  await nav('Operations Plan');

  assertText(R_OPS, 'Daily plan');
  assertTextRe(R_OPS, /Week of/, '"Week of" header present');
  assertText(R_OPS, 'Forecast covers');
  assertText(R_OPS, 'FOH hrs');
  assertText(R_OPS, 'Forecast sales');
  assertTextRe(R_OPS, /2026-\d{2}-\d{2}/, 'at least one date cell present (YYYY-MM-DD)');
  assertNoText(R_OPS, 'Something went wrong');

  // ─── BUSINESS ACCOUNT ─────────────────────────────────────────────────────

  var R_BIZ = 'Business account';
  await nav('Business Business account');

  assertText(R_BIZ, 'Business identity');
  assertText(R_BIZ, 'Logo');
  assertText(R_BIZ, 'Currency and locale');
  assertText(R_BIZ, 'Save business account');
  assertNoText(R_BIZ, 'Something went wrong');

  // ─── SERVICE PERIODS ──────────────────────────────────────────────────────

  var R_SVC = 'Service periods';
  await nav('Service periods');

  assertText(R_SVC, 'Edit service periods');
  assertText(R_SVC, 'Timezone');
  assertText(R_SVC, 'Business day starts');
  assertAnyText(R_SVC, ['Lunch', 'Dinner', 'Breakfast', 'Late night'],
    'at least one service period name present');
  assertNoText(R_SVC, 'Something went wrong');

  // Interaction: open and dismiss Edit service periods dialog
  var clicked = clickLabel('Edit service periods');
  if (!clicked) {
    fail(R_SVC, 'interaction: Edit service periods dialog opens', 'button not found');
  } else {
    await wait(600);
    if (hasText('Cancel') || hasText('Close')) {
      pass(R_SVC, 'interaction: Edit service periods dialog opens (Cancel/Close present)');
    } else {
      fail(R_SVC, 'interaction: Edit service periods dialog opens', 'neither Cancel nor Close found after click');
    }
    pressEscape();
    await wait(400);
  }

  // ─── TEAM MEMBERS ─────────────────────────────────────────────────────────

  var R_TEAM = 'Team members';
  await nav('Team members');

  assertText(R_TEAM, 'Invite member');
  assertText(R_TEAM, 'Status');
  assertText(R_TEAM, 'Member');
  assertSemCountGt(R_TEAM, 20, 'semantics count > 20 (rows present)');
  assertText(R_TEAM, 'Active');
  assertNoText(R_TEAM, 'Something went wrong');

  // ─── ROLES & PERMISSIONS ──────────────────────────────────────────────────

  var R_ROLES = 'Roles & permissions';
  await nav('Access Roles');

  assertText(R_ROLES, 'New role');
  assertText(R_ROLES, 'Custom roles');
  assertText(R_ROLES, 'Default roles');
  assertSemCountGt(R_ROLES, 25, 'semantics count > 25 (at least 8 default role names visible)');
  assertNoText(R_ROLES, 'Something went wrong');

  // ─── ACTIVE SESSIONS ──────────────────────────────────────────────────────

  var R_SESS = 'Active sessions';
  await nav('Active sessions');

  assertText(R_SESS, 'Your sessions');
  assertText(R_SESS, '(this session)');
  assertText(R_SESS, 'Sign out this session');
  assertNoText(R_SESS, 'Something went wrong');

  // ─── AUDIT LOG ────────────────────────────────────────────────────────────

  var R_AUDIT = 'Audit log';
  await nav('Audit log');

  assertText(R_AUDIT, 'Export CSV');
  assertText(R_AUDIT, 'Last 7 days');
  assertText(R_AUDIT, 'Last 30 days');
  assertTextRe(R_AUDIT, /\d{4}-\d{2}-\d{2} \d{2}:\d{2}/, 'at least one timestamp present');
  assertNoTextRe(R_AUDIT, /No audit log entries/i, '"No audit log entries" absent');
  assertNoText(R_AUDIT, 'Something went wrong');

  // Interaction: click "Last 7 days" and assert entries remain
  var auditFilterClicked = clickLabel('Last 7 days');
  if (!auditFilterClicked) {
    fail(R_AUDIT, 'interaction: Last 7 days filter click', 'button not found');
  } else {
    await wait(600);
    if (hasTextRe(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}/)) {
      pass(R_AUDIT, 'interaction: page still has timestamp entries after Last 7 days filter');
    } else {
      fail(R_AUDIT, 'interaction: page still has timestamp entries after Last 7 days filter',
        'no timestamps found after filter click');
    }
  }

  // ─── VENDOR INTEGRATIONS ──────────────────────────────────────────────────

  var R_VENDOR = 'Vendor integrations';
  await nav('Data & integrations Vendor');

  assertText(R_VENDOR, 'Point-of-sale');
  assertText(R_VENDOR, 'Scheduling and labor');
  assertText(R_VENDOR, 'Reservations');
  assertNoText(R_VENDOR, 'Something went wrong');

  // Interaction: click "Choose POS" or "Choose" under Point-of-sale
  var textBefore = getText().slice();
  var posClicked = clickAnyLabel(['Choose POS', 'Choose']);
  if (!posClicked) {
    fail(R_VENDOR, 'interaction: POS picker opens', '"Choose POS" or "Choose" button not found');
  } else {
    await wait(600);
    var textAfter = getText();
    // Check for new text OR a dialog indicator
    var hasNewContent = false;
    for (var i = 0; i < textAfter.length; i++) {
      if (textBefore.indexOf(textAfter[i]) === -1) {
        hasNewContent = true;
        break;
      }
    }
    if (hasNewContent) {
      pass(R_VENDOR, 'interaction: POS picker opens (new content appeared)');
    } else {
      fail(R_VENDOR, 'interaction: POS picker opens', 'no new content found after clicking Choose');
    }
    pressEscape();
    await wait(400);
  }

  // ─── DATA ACCURACY ────────────────────────────────────────────────────────

  var R_DATA = 'Data accuracy';
  await nav('Data accuracy');

  assertText(R_DATA, 'Labor');
  assertText(R_DATA, 'Covers');
  assertText(R_DATA, 'Data freshness');
  assertNoText(R_DATA, 'Something went wrong');

  // ─── NOTIFICATIONS ────────────────────────────────────────────────────────

  var R_NOTIF = 'Notifications';
  await nav('People & access Notifications');

  assertText(R_NOTIF, 'Notifications');
  assertText(R_NOTIF, 'Email');
  assertAnyText(R_NOTIF, ['Push Notifications', 'Push'],
    '"Push Notifications" or "Push" present');
  assertAnyText(R_NOTIF, ['In-App Inbox', 'In-App'],
    '"In-App Inbox" or "In-App" present');
  assertNoText(R_NOTIF, 'Something went wrong');

  // ─── MY ACCOUNT ───────────────────────────────────────────────────────────

  var R_ACCT = 'My account';
  await nav('People My account');

  assertText(R_ACCT, 'Profile');
  assertText(R_ACCT, 'Display name');
  assertText(R_ACCT, 'Security');
  assertText(R_ACCT, 'Change password');
  assertText(R_ACCT, 'Recent sign-in activity');
  assertTextRe(R_ACCT, /UTC/, 'at least one sign-in timestamp with UTC present');
  assertNoText(R_ACCT, 'Something went wrong');

  // Interaction — DEF-02 regression: Change password empty submit
  var pwClicked = clickLabel('Change password');
  if (!pwClicked) {
    fail(R_ACCT, 'DEF-02 regression: Change password button found', 'button not found');
  } else {
    await wait(600);

    // Assert dialog opened (Update password present)
    if (hasText('Update password')) {
      pass(R_ACCT, 'DEF-02 regression: dialog opened (Update password present)');
    } else {
      fail(R_ACCT, 'DEF-02 regression: dialog opened', '"Update password" not found after clicking Change password');
    }

    // Submit empty
    var submitClicked = clickLabel('Update password');
    if (!submitClicked) {
      fail(R_ACCT, 'DEF-02 regression: Update password submit button clickable', 'button not found');
    } else {
      await wait(600);

      // Assert validation error: text matching /password/i other than the button itself
      var arr = getText();
      var validationFound = false;
      for (var vi = 0; vi < arr.length; vi++) {
        var t = arr[vi];
        // Must match /password/i but must NOT be exactly the submit button label
        if (/password/i.test(t) && t !== 'Update password' && t !== 'Change password') {
          validationFound = true;
          break;
        }
      }
      if (validationFound) {
        pass(R_ACCT, 'DEF-02 regression: empty submit shows validation error (password text found)');
      } else {
        fail(R_ACCT, 'DEF-02 regression: empty submit shows validation error',
          'validation text not found after submit');
      }
    }

    // Dismiss dialog
    var dismissed = clickAnyLabel(['Close', 'Cancel']);
    if (!dismissed) {
      // Try Escape as fallback
      pressEscape();
    }
    await wait(400);

    // Assert dialog closed
    if (!hasText('Update password')) {
      pass(R_ACCT, 'DEF-02 regression: dialog dismissed (Update password gone)');
    } else {
      fail(R_ACCT, 'DEF-02 regression: dialog dismissed', '"Update password" still present after dismiss');
    }
  }

  // ─── FINAL SUMMARY ────────────────────────────────────────────────────────

  var passed  = _results.filter(function (r) { return r.status === 'PASS'; }).length;
  var failed  = _results.filter(function (r) { return r.status === 'FAIL'; }).length;
  var skipped = _results.filter(function (r) { return r.status === 'SKIP'; }).length;

  return {
    passed:  passed,
    failed:  failed,
    skipped: skipped,
    results: _results,
    summary: (failed === 0 ? 'PASSED' : 'FAILED') + ' ' + passed + '/' + (passed + failed)
  };
})()
