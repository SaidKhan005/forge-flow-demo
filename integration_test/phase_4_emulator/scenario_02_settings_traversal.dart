// Phase 4 Scenario 2 — Settings tab full traversal.
//
// Per CLAUDE.md "Demo Mode" → carve-out #3: the demo flavor (built
// with `--dart-define=kDemoMode=true`) shows two extra demo-only
// management sections on the Settings → Data tab: "Data reset"
// and "Demo date". Production builds hide both sections; the rest
// of the Settings tab renders identically in demo and prod.
//
// Path: dashboard -> Settings icon -> traverse the 3 settings tabs
// (Account / Setup / Data) and confirm each section mounts.
//
// Asserts:
//   - SettingsScreen mounts.
//   - The Account tab's "Account" section + "Active sessions"
//     section render.
//   - The two demo carve-out sections ("Data reset" + "Demo date")
//     render in the Data tab — both are demo-only chrome.
//   - No RenderFlex overflow exceptions.
//
// SCENARIO GAP: the prompt names 10 sub-sections (Account, MFA,
// Active Sessions, Data freshness, Wage authority, Team, Permissions,
// FF Support, Data reset, Demo date). The mobile app's W3.A collapse
// (lib/screens/settings_screen.dart, ~line 167) intentionally moves
// Team / Permissions / MFA-recovery / FF Support primary surfaces
// out of mobile and into the Operator Web console — what's left in
// the mobile app is the "view-only mirror" surfaces (Account,
// Sessions, Setup [timing + wage], Data [sync + freshness + demo
// carve-outs + FF support diagnostic gate]). We assert the mobile
// surfaces that DO exist and document the gap here rather than
// asserting against UI that intentionally lives elsewhere. The
// underlying `kDemoMode` carve-outs are fully covered by the
// existing widget test (`test/screens/settings_screen_collapse_test.dart`).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '_harness.dart';

/// Switches the active settings tab by reading the inner
/// [BottomNavigationBar]'s `onTap` callback. The Settings screen owns
/// its own bar (`_SettingsBottomNav`) layered above the AppShell bar,
/// so we pick the LAST [BottomNavigationBar] in the tree (the
/// settings one).
Future<void> _tapSettingsTab(WidgetTester tester, int tabIndex) async {
  final bars = find.byType(BottomNavigationBar);
  expect(
    bars,
    findsAtLeast(1),
    reason: 'Settings BottomNavigationBar not mounted.',
  );
  final settingsBar = tester.widget<BottomNavigationBar>(bars.last);
  settingsBar.onTap?.call(tabIndex);
  await tester.pump();
  await pumpUntilSettledOrBudget(
    tester,
    budget: const Duration(seconds: 5),
  );
}

void main() {
  bootstrapPhase4Binding();

  testWidgets('scenario 02 — settings tabs traverse without exceptions', (
    WidgetTester tester,
  ) async {
    final tap = FlutterErrorTap.install();
    addTearDown(tap.restore);

    await launchDemoApp(tester);
    await expectAppShellMounted(tester);

    // AppShell's settings entry-point is the `Icons.settings_outlined`
    // icon in the app bar (`_AppShellIconButton` in
    // `lib/forge_flow_app.dart` ~line 1421, `tooltip: 'Settings'`).
    // Tap it to navigate to SettingsScreen.
    final settingsIcon = find.byIcon(Icons.settings_outlined);
    expect(
      settingsIcon,
      findsAtLeast(1),
      reason:
          'Settings entry-point icon not found in the AppBar — '
          'Settings traversal cannot proceed.',
    );
    await tester.tap(settingsIcon.first);
    await pumpUntilSettledOrBudget(tester);
    expectSettingsScreenMounted();

    // Account tab is the default landing tab. The section title text
    // 'Account' is rendered by the StickySectionDelegate header. We
    // tolerate `findsAtLeast(1)` because various places in the tree
    // also use the literal 'Account' (e.g. side-of-app routing).
    expect(find.text('Account'), findsAtLeast(1));
    expect(find.text('Active sessions'), findsAtLeast(1));

    // Setup tab — second tab in `_SettingsTabSpec` order
    // (account / authority / data). Index 1.
    await _tapSettingsTab(tester, 1);
    expect(
      find.text('Wage setup'),
      findsAtLeast(1),
      reason:
          'Setup tab did not render the Wage setup section. The seed '
          "may not have populated the demo operator's admin role.",
    );

    // Data tab — index 2.
    await _tapSettingsTab(tester, 2);
    expect(find.text('Sync status'), findsAtLeast(1));
    // The two demo carve-out sections — the assertion the prompt pins.
    // Both must render in a kDemoMode=true build.
    expect(
      find.text('Data reset'),
      findsAtLeast(1),
      reason:
          'Demo carve-out #3 violated: "Data reset" did not render '
          'in a kDemoMode=true build.',
    );
    expect(
      find.text('Demo date'),
      findsAtLeast(1),
      reason:
          'Demo carve-out #3 violated: "Demo date" did not render '
          'in a kDemoMode=true build.',
    );

    expect(
      tap.overflowErrors,
      isEmpty,
      reason:
          'RenderFlex overflow detected during Settings traversal:\n'
          '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
    );
  });
}
