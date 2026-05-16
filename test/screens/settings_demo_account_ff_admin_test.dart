// Demo Forge & Flow: Account tab renders + demo operator = F&F admin.
//
// Operator findings (live emulator walkthrough): in the demo flavor
// (1) the Account tab did not render and (2) the demo operator was not
// a F&F admin, so the Data tab + the F&F-only Data-alignment panel and
// the Account tab were all hidden.
//
// Root cause: the standalone demo flavor mounted `requireAuth: false`
// with the scaffold-failing login service, so `AuthSession` stayed
// null forever — `showAccount` was false (Account tab dropped) and the
// `teamActor` was null (the `ff_support`-gated Data-alignment panel
// stayed hidden). The fix wires a writer-side `DemoAuthLoginService`
// that mints an `ff_support` session.
//
// These tests pin the post-fix behavior at the Settings surface, and
// prove the elevation is fixture-scoped (an operator-tier session does
// NOT get the F&F surfaces — production auth posture unchanged).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/screens/settings/settings_data_sections.dart';
import 'package:forge_and_flow/screens/settings_screen.dart';
import 'package:forge_and_flow/services/auth/demo_auth_login_service.dart';
import 'package:forge_and_flow/services/auth_login_service.dart';
import 'package:forge_and_flow/services/secure_session_storage.dart';
import 'package:forge_and_flow/services/team/team_scope_visibility_policy.dart';
import 'package:forge_and_flow/state/auth_session_notifier.dart';

// Mirrors what `forge_flow_app.dart` `_teamActorFromSession` projects
// from the demo `ff_support` session (no PermissionContext in a demo
// shell, so roles flow straight through).
const TeamScopeActor _demoFfActor = TeamScopeActor(
  actorRoles: <String>{'ff_support', 'roles_version:1'},
  actorOperatorId: kDemoOperatorOperatorId,
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{},
);

// An operator-tier session that did NOT come through the demo
// fixture — proves the F&F elevation is scoped to DemoAuthLoginService.
const TeamScopeActor _operatorActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{},
);

Future<AuthSession> _demoSession() async {
  final result = await const DemoAuthLoginService().signInWithEmailPassword(
    email: kDemoOperatorEmail,
    password: kDemoOperatorPassword,
  );
  return (result as AuthLoginSuccess).session;
}

AuthSession _operatorSession() => AuthSession(
  userId: 'user-1',
  operatorId: 'op-1',
  locationId: 'loc-1',
  firebaseIdToken: 'token',
  issuedAt: DateTime.utc(2026, 5, 15, 12),
  expiresAt: DateTime.utc(2026, 6, 15, 12),
  lastFreshAuthAt: DateTime.utc(2026, 5, 15, 12),
  roles: const <String>['operator_owner'],
  mfaEnrolled: false,
);

AuthSessionNotifier _notifier(AuthSession session) {
  return AuthSessionNotifier(
    loginService: const ScaffoldFailingAuthLoginService(),
    storage: InMemorySecureSessionStorage(),
  )..debugSetSession(session);
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
    'demo F&F-admin session: Account + Data tabs render and the '
    'F&F-only Data alignment panel mounts',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final notifier = _notifier(await _demoSession());
      await tester.pumpWidget(
        _wrap(
          notifier: notifier,
          child: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            teamActor: _demoFfActor,
            // Demo flavor wires no AccountInfoGateway.
            allowDemoAccountInfoFallback: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Finding 1: the Account tab renders.
      expect(find.byKey(const Key('settings_tab_account')), findsOneWidget);
      // Finding 2: the F&F-gated Data tab renders.
      expect(find.byKey(const Key('settings_tab_data')), findsOneWidget);

      await tester.tap(find.byKey(const Key('settings_tab_data')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The F&F-only Data-alignment panel mounts for the demo operator.
      expect(
        find.byType(SettingsAuditSection, skipOffstage: false),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'demo Account tab renders the honest session-derived card '
    '(not blank) when no AccountInfoGateway is wired',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final notifier = _notifier(await _demoSession());
      await tester.pumpWidget(
        _wrap(
          notifier: notifier,
          child: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            teamActor: _demoFfActor,
            allowDemoAccountInfoFallback: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const Key('settings_tab_account')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Honest demo identity decoded from the synthetic token — never
      // phantom data.
      expect(
        find.text(kDemoOperatorEmail, skipOffstage: false),
        findsWidgets,
      );
      expect(
        find.text('Demo Operator', skipOffstage: false),
        findsWidgets,
      );
    },
  );

  testWidgets(
    'production posture unchanged: operator-tier session (not via the '
    'demo fixture) has no Data tab and a blank Account section without '
    'the fallback flag',
    (tester) async {
      final notifier = _notifier(_operatorSession());
      await tester.pumpWidget(
        _wrap(
          notifier: notifier,
          child: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            teamActor: _operatorActor,
            // Production wires a real gateway, so the demo fallback is
            // false; the elevation is NOT global.
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // F&F surfaces stay hidden for an operator-tier identity.
      expect(find.byKey(const Key('settings_tab_data')), findsNothing);
      expect(
        find.byType(SettingsAuditSection, skipOffstage: false),
        findsNothing,
      );

      // Account tab still present (signed in) but its section collapses
      // to nothing without a gateway and without the demo fallback —
      // i.e. the elevation/fallback are demo-fixture-scoped.
      expect(find.byKey(const Key('settings_tab_account')), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings_tab_account')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(kDemoOperatorEmail, skipOffstage: false), findsNothing);
    },
  );
}
