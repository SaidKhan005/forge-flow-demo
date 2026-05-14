// W3.A — mobile.settings-collapse-and-restructure widget acceptance
// tests. Covers the 3-tab read-only collapse: Account / Setup / Data,
// with no edit affordances on Active Sessions or Wage, no Audit log
// section on Account, and the Data tab's "Data alignment" panel
// gated to F&F support actors only. Demo-only sections render only
// when `kDemoMode = true`.
//
// MO-1 (Wave 2) — the Data tab itself is now restricted to seeded
// F&F admin users (super_admin / ff_support). Operator-tier actors
// (owner / manager / supervisor / staff) no longer see the tab.
// Tests covering the Data tab's body therefore use the F&F support
// actor; the operator_owner test asserts the tab is hidden.
//
// MP-1 (Wave 2) — the top-level Integrations tab is now a permanent
// home for per-category integration status, the operator master
// Demo→Live switch (moved from Setup per MO-1-FU's interim mount),
// and the operator-console deep-link. Gated by `showAdminTabs`, so
// every operator admin role reaches it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/screens/settings/settings_data_sections.dart';
import 'package:forge_and_flow/screens/settings/settings_demo_live_switch.dart';
import 'package:forge_and_flow/screens/settings_screen.dart';
import 'package:forge_and_flow/services/auth_login_service.dart';
import 'package:forge_and_flow/services/secure_session_storage.dart';
import 'package:forge_and_flow/services/team/team_scope_visibility_policy.dart';
import 'package:forge_and_flow/state/auth_session_notifier.dart';

const TeamScopeActor _ownerActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{},
);

const TeamScopeActor _ffSupportActor = TeamScopeActor(
  actorRoles: <String>{'ff_support'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{},
);

const TeamScopeActor _superAdminActor = TeamScopeActor(
  actorRoles: <String>{'super_admin'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{},
);

AuthSession _session() => AuthSession(
  userId: 'user-1',
  operatorId: 'op-1',
  locationId: 'loc-1',
  firebaseIdToken: 'token',
  issuedAt: DateTime.utc(2026, 4, 29, 12),
  expiresAt: DateTime.utc(2026, 4, 29, 13),
  lastFreshAuthAt: DateTime.utc(2026, 4, 29, 12),
  roles: const <String>['operator_owner'],
  mfaEnrolled: true,
);

AuthSessionNotifier _notifier() {
  return AuthSessionNotifier(
    loginService: const ScaffoldFailingAuthLoginService(),
    storage: InMemorySecureSessionStorage(),
  )..debugSetSession(_session());
}

Widget _wrap({required AuthSessionNotifier notifier, required Widget child}) {
  return ChangeNotifierProvider<AuthSessionNotifier>.value(
    value: notifier,
    child: MaterialApp(home: child),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'renders Account + Setup + Integrations tabs for operator_owner '
    '(Data tab gated to F&F admin)',
    (tester) async {
      // MO-1 — operator_owner is admin-tier for Setup but no longer
      // sees the Data tab; that surface is F&F-internal.
      // MP-1 — operator_owner DOES reach the new Integrations tab;
      // it's gated by `showAdminTabs` (all operator admins).
      final notifier = _notifier();
      await tester.pumpWidget(
        _wrap(
          notifier: notifier,
          child: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            teamActor: _ownerActor,
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('settings_tab_account')), findsOneWidget);
      expect(find.byKey(const Key('settings_tab_authority')), findsOneWidget);
      expect(
        find.byKey(const Key('settings_tab_integrations')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('settings_tab_data')), findsNothing);
      expect(find.byKey(const Key('settings_tab_team')), findsNothing);
      expect(find.byKey(const Key('settings_tab_developer')), findsNothing);
    },
  );

  testWidgets(
    'renders all four tabs (Account, Setup, Integrations, Data) for '
    'F&F support actor',
    (tester) async {
      // MO-1 — F&F support is the seeded role that retains Data tab
      // visibility post-gate.
      // MP-1 — F&F support also sees the Integrations tab.
      final notifier = _notifier();
      await tester.pumpWidget(
        _wrap(
          notifier: notifier,
          child: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            teamActor: _ffSupportActor,
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('settings_tab_account')), findsOneWidget);
      expect(find.byKey(const Key('settings_tab_authority')), findsOneWidget);
      expect(
        find.byKey(const Key('settings_tab_integrations')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('settings_tab_data')), findsOneWidget);
    },
  );

  testWidgets(
    'renders all four tabs (Account, Setup, Integrations, Data) for '
    'super_admin actor',
    (tester) async {
      // MO-1 — super_admin is the second seeded F&F admin role that
      // retains Data tab visibility.
      // MP-1 — super_admin also sees the Integrations tab.
      final notifier = _notifier();
      await tester.pumpWidget(
        _wrap(
          notifier: notifier,
          child: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            teamActor: _superAdminActor,
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('settings_tab_account')), findsOneWidget);
      expect(find.byKey(const Key('settings_tab_authority')), findsOneWidget);
      expect(
        find.byKey(const Key('settings_tab_integrations')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('settings_tab_data')), findsOneWidget);
    },
  );

  testWidgets(
    'Data tab is hidden from operator_manager (Wave 2 MO-1)',
    (tester) async {
      // MO-1 — operator_manager is admin-tier for Setup but no longer
      // sees the Data tab. Mirrors the operator_owner expectation;
      // every operator-tier role is gated out.
      const managerActor = TeamScopeActor(
        actorRoles: <String>{'operator_manager'},
        actorOperatorId: 'op-1',
        actorAssignedLocationIds: <String>{'loc-1'},
        actorPermissions: <String>{},
      );
      final notifier = _notifier();
      await tester.pumpWidget(
        _wrap(
          notifier: notifier,
          child: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            teamActor: managerActor,
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('settings_tab_data')), findsNothing);
    },
  );

  testWidgets('Account tab does not render an Audit log section', (
    tester,
  ) async {
    final notifier = _notifier();
    await tester.pumpWidget(
      _wrap(
        notifier: notifier,
        child: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          teamActor: _ownerActor,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Audit log', skipOffstage: false), findsNothing);
  });

  testWidgets(
    'Active Sessions section does not render revoke or sign-out-all '
    'buttons in viewOnly',
    (tester) async {
      final notifier = _notifier();
      await tester.pumpWidget(
        _wrap(
          notifier: notifier,
          child: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            teamActor: _ownerActor,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('active_sessions_sign_out_everywhere')),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith(
                'active_sessions_revoke_',
              ),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('Setup tab Wage section renders no editor button in viewOnly', (
    tester,
  ) async {
    final notifier = _notifier();
    await tester.pumpWidget(
      _wrap(
        notifier: notifier,
        child: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          teamActor: _ownerActor,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('settings_tab_authority')));
    await tester.pump(const Duration(milliseconds: 200));

    // The whole-mix editor primary button copy is "Edit wage mix".
    expect(find.text('Edit wage mix', skipOffstage: false), findsNothing);
  });

  testWidgets(
    'Data tab body (including Data alignment) is absent for operator_owner',
    (tester) async {
      // MO-1 — under the new tab gate, operator_owner does not see
      // the Data tab at all, so neither the Sync status header nor
      // the F&F-only SettingsAuditSection should mount.
      final notifier = _notifier();
      await tester.pumpWidget(
        _wrap(
          notifier: notifier,
          child: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            teamActor: _ownerActor,
          ),
        ),
      );
      await tester.pump();

      // The Data tab key is gone; the Data tab body and its F&F-only
      // section are absent from the tree.
      expect(find.byKey(const Key('settings_tab_data')), findsNothing);
      expect(
        find.byType(SettingsAuditSection, skipOffstage: false),
        findsNothing,
      );
    },
  );

  testWidgets('Data tab renders Data alignment for F&F support actor', (
    tester,
  ) async {
    final notifier = _notifier();
    // Use a larger viewport so all Data tab sections lay out at once.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      _wrap(
        notifier: notifier,
        child: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          teamActor: _ffSupportActor,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.byKey(const Key('settings_tab_data')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Assert against the SettingsAuditSection widget itself rather
    // than the sticky-header text. Sliver headers only mount when
    // their paint area is in view; the widget instance is in the
    // element tree as soon as the SliverMainAxisGroup is laid out.
    expect(
      find.byType(SettingsAuditSection, skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('Demo-only sections are hidden when kDemoMode is false', (
    tester,
  ) async {
    // Default --dart-define has kDemoMode unset (false). Demo rows
    // ("Data reset" + "Demo date") must stay hidden even for an F&F
    // admin actor (the only role that now reaches the Data tab —
    // MO-1).
    final notifier = _notifier();
    await tester.pumpWidget(
      _wrap(
        notifier: notifier,
        child: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          teamActor: _ffSupportActor,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('settings_tab_data')));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Data reset', skipOffstage: false), findsNothing);
    expect(find.text('Demo date', skipOffstage: false), findsNothing);
  });

  testWidgets(
    'Data tab is visible to unauthenticated demo shell (no teamActor)',
    (tester) async {
      // MO-1 — when the screen mounts without an auth session (demo
      // walkthrough / unauth flow), `showAccount` is false and the
      // Data tab remains visible so the demo Demo→Live + Data reset
      // affordances are still reachable. The gate falls open in the
      // same posture as the existing `showAdminTabs` null-actor
      // behaviour.
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(initialStatus: AppDataStatus.current()),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('settings_tab_data')), findsOneWidget);
    },
  );

  testWidgets(
    'Integrations tab renders Demo→Live switch for operator_owner (MP-1)',
    (tester) async {
      // MP-1 — the operator master Demo→Live switch's permanent home
      // is the new top-level Integrations tab (it had a brief
      // intermediate mount under Setup per MO-1-FU after MO-1
      // gated the Data tab to F&F admins). operator_owner is the
      // primary demo operator role; they MUST reach the switch
      // through the Integrations tab. Asserts:
      //   (a) Integrations tab is present
      //   (b) Data tab is hidden (MO-1 gate still strict)
      //   (c) the SettingsDemoLiveSwitch widget mounts in the
      //       Integrations tab body
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final notifier = _notifier();
      await tester.pumpWidget(
        _wrap(
          notifier: notifier,
          child: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            teamActor: _ownerActor,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('settings_tab_integrations')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('settings_tab_data')), findsNothing);

      await tester.tap(find.byKey(const Key('settings_tab_integrations')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byType(SettingsDemoLiveSwitch, skipOffstage: false),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Integrations tab renders Demo→Live switch for F&F support actor (MP-1)',
    (tester) async {
      // MP-1 — F&F admin keeps Data tab visibility but the master
      // Demo→Live switch lives on the Integrations tab. Confirm
      // exactly one switch mounts (the move is a relocation, not
      // a duplication).
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final notifier = _notifier();
      await tester.pumpWidget(
        _wrap(
          notifier: notifier,
          child: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            teamActor: _ffSupportActor,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('settings_tab_integrations')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Exactly one SettingsDemoLiveSwitch across the whole settings
      // screen (TabBarView mounts all tab bodies); the move from
      // Setup to Integrations is a relocation, not a duplication.
      expect(
        find.byType(SettingsDemoLiveSwitch, skipOffstage: false),
        findsOneWidget,
      );
    },
  );
}
