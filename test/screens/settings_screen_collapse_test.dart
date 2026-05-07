// W3.A — mobile.settings-collapse-and-restructure widget acceptance
// tests. Covers the 3-tab read-only collapse: Account / Setup / Data,
// with no edit affordances on Active Sessions or Wage, no Audit log
// section on Account, and the Data tab's "Data alignment" panel
// gated to F&F support actors only. Demo-only sections render only
// when `kDemoMode = true`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/screens/settings/settings_data_sections.dart';
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

  testWidgets('renders exactly three tabs (Account, Setup, Data) for admin', (
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

    expect(find.byKey(const Key('settings_tab_account')), findsOneWidget);
    expect(find.byKey(const Key('settings_tab_authority')), findsOneWidget);
    expect(find.byKey(const Key('settings_tab_data')), findsOneWidget);
    expect(find.byKey(const Key('settings_tab_team')), findsNothing);
    expect(find.byKey(const Key('settings_tab_developer')), findsNothing);
  });

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

  testWidgets('Data tab does NOT render Data alignment for non-F&F actor', (
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

    await tester.tap(find.byKey(const Key('settings_tab_data')));
    await tester.pump(const Duration(milliseconds: 200));

    // Non-F&F actor: SettingsAuditSection must not be in the tree.
    expect(
      find.byType(SettingsAuditSection, skipOffstage: false),
      findsNothing,
    );
  });

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
    // ("Data reset" + "Demo date") must stay hidden even for an
    // admin actor.
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

    await tester.tap(find.byKey(const Key('settings_tab_data')));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Data reset', skipOffstage: false), findsNothing);
    expect(find.text('Demo date', skipOffstage: false), findsNothing);
  });
}
