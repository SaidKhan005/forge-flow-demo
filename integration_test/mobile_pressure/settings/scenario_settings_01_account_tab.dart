// Lane D — Scenario 01: Settings Account tab renders without crash.
//
// Tab order in SettingsScreen (settings_screen.dart lines 276-289):
//   Setup (index 0), Integrations (index 1), Data (index 2), Account (index 3).
// The Account tab is the last tab in the list and is only visible when a
// session exists. In the demo-mode boot the DemoAuthLoginService wires a
// session, so the Account tab should be present.
//
// Account tab sections (settings_screen.dart lines 495-563):
//   - "Two-factor sign-in" → SettingsMfaSection
//   - "Account"           → SettingsAccountSection
//   - "Active sessions"   → SettingsActiveSessionsSection
//
// SettingsActiveSessionsSection (settings_active_sessions_section.dart):
//   With allowDemoGatewayFallback=true the widget loads DemoActiveSessionsFixtures
//   (3 sessions) and renders a SettingsCard with an _ActiveSessionsHeader whose
//   description is 'Devices currently signed in to your account.'.

import 'package:flutter_test/flutter_test.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets('scenario 01 — Account tab renders all sections without crash', (
    WidgetTester tester,
  ) async {
    final tap = FlutterErrorTap.install();
    addTearDown(tap.restore);

    await launchDemoApp(tester);
    await expectAppShellMounted(tester);

    await openSettings(tester);
    expectSettings();

    // Account tab is the last tab. In demo mode the tab order is:
    // Setup (0), Integrations (1), Data (2), Account (3).
    // Tap the last bar item by tapping tab index 3.
    await tapSettingsTab(tester, 3);
    await pumpUntil(tester, budget: kTabBudget);

    // The sticky section-header titles come from _settingsSection(title:).
    expect(
      find.text('Account'),
      findsAtLeast(1),
      reason: 'Account section header not found on Account tab.',
    );
    expect(
      find.text('Active sessions'),
      findsAtLeast(1),
      reason: 'Active sessions section header not found on Account tab.',
    );
    expect(
      find.text('Two-factor sign-in'),
      findsAtLeast(1),
      reason: 'Two-factor sign-in section header not found on Account tab.',
    );

    // SettingsActiveSessionsSection header text
    // (settings_active_sessions_section.dart line 527)
    expect(
      find.text('Devices currently signed in to your account.'),
      findsAtLeast(1),
      reason:
          'Active sessions description not found — section may not have loaded.',
    );

    // No overflows.
    expect(
      tap.overflowErrors,
      isEmpty,
      reason:
          'RenderFlex overflow on Account tab:\n'
          '${tap.overflowErrors.map((e) => e.exceptionAsString()).join('\n')}',
    );
  });
}
