// Settings screen widget tests.
// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/services/schedule_plan_read_service.dart';
import 'package:forge_and_flow/state/restaurant_scope_notifier.dart';
import 'package:forge_and_flow/services/wage_standard_context_service.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/domain/models/wage_role_row.dart';
import 'package:forge_and_flow/domain/models/wage_standard_context.dart';
import 'package:forge_and_flow/domain/models/wage_standard_source.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_wage_role_row_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/screens/settings_screen.dart';
import 'package:forge_and_flow/screens/team/team_settings_section.dart';
import 'package:forge_and_flow/services/auth/account_info_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/password_change_gateway.dart';
import 'package:forge_and_flow/services/advisor_corpus_admin_service.dart';
import 'package:forge_and_flow/services/advisor_model_config_service.dart';
import 'package:forge_and_flow/services/auth_login_service.dart';
import 'package:forge_and_flow/services/secure_session_storage.dart';
import 'package:forge_and_flow/services/team/team_scope_visibility_policy.dart';
import 'package:forge_and_flow/state/auth_session_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

bool _includePrunedLabelGroups() => false;

const TeamScopeActor _settingsTeamOwnerActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{'team.users.view', 'team.users.invite'},
);

const TeamScopeActor _settingsTeamLockedActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{},
);

// Phase 9.UX.2 — owner with role catalog perms so the Settings → Team
// → Roles surface renders end-to-end.
const TeamScopeActor _settingsRolesOwnerActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{
    'team.users.view',
    'team.roles.view',
    'team.roles.create_custom',
    'team.roles.assign',
    'team.roles.revoke',
  },
);

const TeamScopeActor _settingsRolesReadOnlyActor = TeamScopeActor(
  actorRoles: <String>{'operator_manager'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{'loc-1'},
  actorPermissions: <String>{'team.users.view', 'team.roles.view'},
);

AuthSession _settingsAuthSession() {
  return AuthSession(
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  group('Settings screen smoke', () {
    testWidgets('current status renders in the DATA STATUS section', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialStatus: AppDataStatus.current(
              importStatus: 'completed',
              timestamp: '2026-03-30T10:00:00',
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('settings_tab_data')), findsOneWidget);
      expect(find.byKey(const Key('settings_tab_authority')), findsOneWidget);
      expect(find.byKey(const Key('settings_tab_developer')), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings_tab_data')));
      await tester.pumpAndSettle();
      expect(find.text('Data status'), findsOneWidget);
      expect(find.text('CURRENT'), findsOneWidget);
    });

    testWidgets('core Settings sections and mock replay anchors render', (
      tester,
    ) async {
      await _reseedDemoForWidgetTest(tester);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<RestaurantScopeNotifier>(
              create: (_) => RestaurantScopeNotifier.fromRestaurant(
                const RestaurantLocation(
                  restaurantId: 'demo_restaurant_001',
                  displayName: 'Forge & Flow',
                  businessTimezone: 'America/St_Johns',
                  createdAt: '2026-03-30T10:00:00Z',
                  updatedAt: '2026-03-30T10:00:00Z',
                ),
              ),
            ),
          ],
          child: MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
            ),
          ),
        ),
      );
      await _pumpForAsync(tester);
      await tester.tap(find.byKey(const Key('settings_tab_data')));
      await _pumpForAsync(tester);
      expect(find.text('Mock replay', skipOffstage: false), findsOneWidget);
      expect(find.text('Data management', skipOffstage: false), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings_tab_authority')));
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Timing authority');

      expect(
        find.text('Timing authority', skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('America/St_Johns'), findsOneWidget);
    });

    testWidgets('Team tab is hidden by default', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            initialMockDate: '2026-03-27',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings_tab_team')), findsNothing);
      expect(find.text('TEAM', skipOffstage: false), findsNothing);
    });

    testWidgets('signed-in Settings renders account actions', (tester) async {
      final notifier = AuthSessionNotifier(
        loginService: const ScaffoldFailingAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      )..debugSetSession(_settingsAuthSession());

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthSessionNotifier>.value(
          value: notifier,
          child: MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings_tab_account')), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings_tab_account')));
      await tester.pumpAndSettle();

      expect(
        find.text('Account', skipOffstage: false),
        findsAtLeastNWidgets(1),
      );
      expect(find.text('Change Password', skipOffstage: false), findsOneWidget);
      expect(find.text('Sign Out', skipOffstage: false), findsOneWidget);
      expect(
        find.text('Sign out of all devices', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text('Terms & Conditions', skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('signed-in Settings renders My info above account actions', (
      tester,
    ) async {
      final notifier = AuthSessionNotifier(
        loginService: const ScaffoldFailingAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      )..debugSetSession(_settingsAuthSession());
      final gateway = _FixedAccountInfoGateway(
        info: AccountInfo(
          displayName: 'Jane Operator',
          email: 'jane@example.test',
          statusLabel: 'Active',
          locationLabel: 'Downtown',
          roleLabels: const <String>['Kitchen Lead'],
          mfaEnabled: true,
          lastLoginAt: DateTime.utc(2026, 4, 29, 12),
          lastActiveAt: DateTime.utc(2026, 4, 29, 12, 15),
          passwordUpdatedAt: DateTime.utc(2026, 4, 20, 9),
        ),
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthSessionNotifier>.value(
          value: notifier,
          child: MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              accountInfoGateway: gateway,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings_tab_account')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('account_my_info_card'), skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('My info', skipOffstage: false), findsOneWidget);
      expect(find.text('Jane Operator', skipOffstage: false), findsOneWidget);
      expect(
        find.text('jane@example.test', skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('Downtown', skipOffstage: false), findsOneWidget);
      expect(find.text('Kitchen Lead', skipOffstage: false), findsOneWidget);
      expect(find.text('Enabled', skipOffstage: false), findsOneWidget);
      expect(find.text('Change Password', skipOffstage: false), findsOneWidget);
      expect(gateway.requests.single.actorUserId, equals('user-1'));
      expect(
        tester
            .getTopLeft(
              find.byKey(
                const Key('account_my_info_card'),
                skipOffstage: false,
              ),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(find.text('Change Password', skipOffstage: false))
              .dy,
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('account My info uses safe session copy while refreshing', (
      tester,
    ) async {
      final notifier = AuthSessionNotifier(
        loginService: const ScaffoldFailingAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      )..debugSetSession(_settingsAuthSession());
      final gateway = _PendingAccountInfoGateway();

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthSessionNotifier>.value(
          value: notifier,
          child: MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              accountInfoGateway: gateway,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings_tab_account')));
      await tester.pump();

      expect(
        find.byKey(const Key('account_my_info_card'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('account_my_info_loading'), skipOffstage: false),
        findsNothing,
      );
      expect(
        find.byKey(const Key('account_my_info_error'), skipOffstage: false),
        findsNothing,
      );
      expect(
        find.text('Signed-in operator', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text('Refreshing profile details.', skipOffstage: false),
        findsOneWidget,
      );

      gateway.complete(
        AccountInfo(
          displayName: 'Jane Operator',
          email: 'jane@example.test',
          statusLabel: 'Active',
          locationLabel: 'Downtown',
          roleLabels: const <String>['Kitchen Lead'],
          mfaEnabled: true,
          lastLoginAt: DateTime.utc(2026, 4, 29, 12),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Jane Operator', skipOffstage: false), findsOneWidget);
      expect(
        find.text('Refreshing profile details.', skipOffstage: false),
        findsNothing,
      );
      expect(
        find.byKey(const Key('account_my_info_fallback'), skipOffstage: false),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('account My info failure falls back to safe session copy', (
      tester,
    ) async {
      final notifier = AuthSessionNotifier(
        loginService: const ScaffoldFailingAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      )..debugSetSession(_settingsAuthSession());

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthSessionNotifier>.value(
          value: notifier,
          child: MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              accountInfoGateway: _FailingAccountInfoGateway(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings_tab_account')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('account_my_info_card'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('account_my_info_fallback'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text('Signed-in operator', skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('Signed in', skipOffstage: false), findsOneWidget);
      expect(
        find.text('Current location', skipOffstage: false),
        findsAtLeastNWidgets(1),
      );
      expect(find.text('Operator Owner', skipOffstage: false), findsOneWidget);
      expect(
        find.text(
          'Some profile details are temporarily unavailable.',
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      final fallbackCard = find.byKey(
        const Key('account_my_info_card'),
        skipOffstage: false,
      );
      expect(
        find.descendant(
          of: fallbackCard,
          matching: find.textContaining('uuid', skipOffstage: false),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: fallbackCard,
          matching: find.textContaining('permission', skipOffstage: false),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: fallbackCard,
          matching: find.textContaining('Firebase', skipOffstage: false),
        ),
        findsNothing,
      );
      expect(find.text('Change Password', skipOffstage: false), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('signed-in Settings hides Team tab without view permission', (
      tester,
    ) async {
      final notifier = AuthSessionNotifier(
        loginService: const ScaffoldFailingAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      )..debugSetSession(_settingsAuthSession());

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthSessionNotifier>.value(
          value: notifier,
          child: MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              teamActor: _settingsTeamLockedActor,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings_tab_team')), findsNothing);
      expect(find.text('TEAM', skipOffstage: false), findsNothing);
    });

    testWidgets('Settings tab header stays compact across team visibility', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Future<void> pumpSettings(TeamScopeActor actor) async {
        await tester.pumpWidget(
          ChangeNotifierProvider<AuthSessionNotifier>(
            create: (_) => AuthSessionNotifier(
              loginService: const ScaffoldFailingAuthLoginService(),
              storage: InMemorySecureSessionStorage(),
            )..debugSetSession(_settingsAuthSession()),
            child: MaterialApp(
              home: SettingsScreen(
                initialStatus: AppDataStatus.current(),
                initialMockDate: '2026-03-27',
                teamActor: actor,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Finder tabIcon(Key tabKey, IconData icon) {
        return find.descendant(
          of: find.byKey(tabKey),
          matching: find.byIcon(icon),
        );
      }

      await pumpSettings(_settingsTeamLockedActor);

      expect(find.byKey(const Key('settings_tab_team')), findsNothing);
      expect(
        tabIcon(const Key('settings_tab_data'), Icons.storage_rounded),
        findsOneWidget,
      );
      expect(
        tabIcon(const Key('settings_tab_account'), Icons.person_outline),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await pumpSettings(_settingsTeamOwnerActor);

      expect(find.byKey(const Key('settings_tab_team')), findsOneWidget);
      expect(
        tabIcon(const Key('settings_tab_data'), Icons.storage_rounded),
        findsOneWidget,
      );
      expect(
        tabIcon(const Key('settings_tab_team'), Icons.group_outlined),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('account password dialog submits on a phone viewport', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final notifier = AuthSessionNotifier(
        loginService: const ScaffoldFailingAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      )..debugSetSession(_settingsAuthSession());
      final gateway = _RecordingPasswordChangeGateway();

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthSessionNotifier>.value(
          value: notifier,
          child: MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              passwordChangeGateway: gateway,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'initial settings render');

      await tester.tap(find.byKey(const Key('settings_tab_account')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'account tab render');
      await tester.tap(find.text('Change Password', skipOffstage: false));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'password dialog render');

      await tester.enterText(
        find.byKey(const Key('settings_current_password_field')),
        'current-password',
      );
      await tester.enterText(
        find.byKey(const Key('settings_new_password_field')),
        'next-password',
      );
      await tester.enterText(
        find.byKey(const Key('settings_confirm_password_field')),
        'next-password',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Update'));
      await tester.pumpAndSettle();

      expect(gateway.commands, hasLength(1));
      expect(gateway.commands.single.currentPassword, 'current-password');
      expect(gateway.commands.single.newPassword, 'next-password');
      expect(tester.takeException(), isNull);
    });

    testWidgets('account password rejection stays inside the dialog', (
      tester,
    ) async {
      final notifier = AuthSessionNotifier(
        loginService: const ScaffoldFailingAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      )..debugSetSession(_settingsAuthSession());
      final gateway = _RecordingPasswordChangeGateway(
        error: const PasswordChangeRejected(
          code: 'password_reused',
          message: 'reused',
          rejections: <String>['reused_from_history'],
        ),
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthSessionNotifier>.value(
          value: notifier,
          child: MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              passwordChangeGateway: gateway,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings_tab_account')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change Password', skipOffstage: false));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('settings_current_password_field')),
        'current-password',
      );
      await tester.enterText(
        find.byKey(const Key('settings_new_password_field')),
        'next-password',
      );
      await tester.enterText(
        find.byKey(const Key('settings_confirm_password_field')),
        'next-password',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Update'));
      await tester.pumpAndSettle();

      expect(gateway.commands, hasLength(1));
      expect(find.text('Change password'), findsOneWidget);
      expect(
        find.text('Choose a password you have not used recently.'),
        findsOneWidget,
      );
      expect(find.text('Password updated.'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('account password requirements wrap on a phone viewport', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final notifier = AuthSessionNotifier(
        loginService: const ScaffoldFailingAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      )..debugSetSession(_settingsAuthSession());
      final gateway = _RecordingPasswordChangeGateway();

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthSessionNotifier>.value(
          value: notifier,
          child: MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              passwordChangeGateway: gateway,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings_tab_account')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change Password', skipOffstage: false));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('settings_current_password_field')),
        'current-password',
      );
      await tester.enterText(
        find.byKey(const Key('settings_new_password_field')),
        ' short ',
      );
      await tester.enterText(
        find.byKey(const Key('settings_confirm_password_field')),
        ' short ',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Update'));
      await tester.pumpAndSettle();

      expect(gateway.commands, isEmpty);
      expect(
        find.text(
          'Use at least 8 characters. Remove spaces at the beginning or end.',
        ),
        findsOneWidget,
      );
      final message = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('settings_password_dialog_message')),
          matching: find.byType(Text),
        ),
      );
      expect(message.softWrap, isTrue);
      expect(message.maxLines, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('sign out everywhere shows the captain progress message', (
      tester,
    ) async {
      final loginService = _CompletingAuthLoginService();
      addTearDown(loginService.completeSignOutAll);
      final notifier = AuthSessionNotifier(
        loginService: loginService,
        storage: InMemorySecureSessionStorage(),
      )..debugSetSession(_settingsAuthSession());

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthSessionNotifier>.value(
          value: notifier,
          child: MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings_tab_account')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.text('Sign out of all devices', skipOffstage: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Sign out'));
      await tester.pump();

      expect(
        find.text('Chit times rising, Signing you off Captain'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('account_sign_out_everywhere_progress')),
        findsOneWidget,
      );

      loginService.completeSignOutAll();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('data status timestamp truncates on a phone viewport', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialStatus: AppDataStatus.current(
              importStatus: 'completed',
              timestamp:
                  '2026-04-29T12:34:56.789123Z-very-long-import-id-for-ui',
            ),
            initialMockDate: '2026-03-27',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings_tab_data')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Last import:'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'Team tab Org Hierarchy honors team.roles.assign permission gating',
      (tester) async {
        const root = TeamOrgUnitEntry(
          orgUnitId: 'unit-root',
          parentOrgUnitId: null,
          unitType: 'corp',
          path: 'acme',
          label: 'ACME',
        );
        const child = TeamOrgUnitEntry(
          orgUnitId: 'unit-east',
          parentOrgUnitId: 'unit-root',
          unitType: 'region',
          path: 'acme.east',
          label: 'East Region',
        );
        const downtown = TeamOrgLocationEntry(
          locationId: 'loc-downtown',
          parentOrgUnitId: 'unit-root',
          orgUnitPath: 'acme',
          label: 'Downtown',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              teamActor: _settingsTeamOwnerActor,
              teamOrgUnits: const <TeamOrgUnitEntry>[root, child],
              teamOrgLocations: const <TeamOrgLocationEntry>[downtown],
              teamOrgUnitOptions: const <TeamOrgUnitOption>[
                TeamOrgUnitOption(
                  orgUnitId: 'unit-east',
                  label: 'East Region',
                  path: 'acme.east',
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('settings_tab_team')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('org_hierarchy_section'), skipOffstage: false),
          findsOneWidget,
        );
        expect(find.text('ACME', skipOffstage: false), findsOneWidget);
        expect(find.text('East Region', skipOffstage: false), findsOneWidget);
        // Owner has team.users.invite (required by our actor) and the
        // Section gates mutate controls on team.roles.assign which is
        // NOT in the locked actor's permission set.
        expect(
          find.byKey(
            const Key('org_unit_add_child_unit-root'),
            skipOffstage: false,
          ),
          findsNothing,
        );
        expect(
          find.byKey(
            const Key('org_unit_move_location_loc-downtown'),
            skipOffstage: false,
          ),
          findsNothing,
        );
      },
    );

    testWidgets(
      'Org Hierarchy tree refreshes when the listenable yields new data',
      (tester) async {
        const seedRoot = TeamOrgUnitEntry(
          orgUnitId: 'unit-root',
          parentOrgUnitId: null,
          unitType: 'corp',
          path: 'acme',
          label: 'ACME',
        );
        final orgUnits = ValueNotifier<List<TeamOrgUnitEntry>>(
          const <TeamOrgUnitEntry>[seedRoot],
        );
        final orgLocations = ValueNotifier<List<TeamOrgLocationEntry>>(
          const <TeamOrgLocationEntry>[],
        );
        addTearDown(orgUnits.dispose);
        addTearDown(orgLocations.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              teamActor: _settingsTeamOwnerActor,
              teamOrgUnits: orgUnits.value,
              teamOrgLocations: orgLocations.value,
              teamOrgUnitsListenable: orgUnits,
              teamOrgLocationsListenable: orgLocations,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('settings_tab_team')));
        await tester.pumpAndSettle();

        // Initial state: seed root only, no East yet.
        expect(find.text('East Region', skipOffstage: false), findsNothing);

        orgUnits.value = const <TeamOrgUnitEntry>[
          seedRoot,
          TeamOrgUnitEntry(
            orgUnitId: 'unit-east',
            parentOrgUnitId: 'unit-root',
            unitType: 'region',
            path: 'acme.east',
            label: 'East Region',
          ),
        ];
        await tester.pump();

        expect(
          find.text('East Region', skipOffstage: false),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Org Hierarchy Add Child dialog enables submit after typing',
      (tester) async {
        const owner = TeamScopeActor(
          actorRoles: <String>{'operator_owner'},
          actorOperatorId: 'op-1',
          actorAssignedLocationIds: <String>{},
          actorPermissions: <String>{
            'team.users.view',
            'team.roles.assign',
          },
        );
        const root = TeamOrgUnitEntry(
          orgUnitId: 'unit-root',
          parentOrgUnitId: null,
          unitType: 'corp',
          path: 'acme',
          label: 'ACME',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              teamActor: owner,
              teamOrgUnits: const <TeamOrgUnitEntry>[root],
              onTeamOrgUnitCreate: (_) async => null,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('settings_tab_team')));
        await tester.pumpAndSettle();

        final addButton = find.byKey(
          const Key('org_unit_add_child_unit-root'),
          skipOffstage: false,
        );
        await tester.ensureVisible(addButton);
        await tester.pumpAndSettle();
        await tester.tap(addButton);
        await tester.pumpAndSettle();

        final submit = find.byKey(const Key('org_unit_add_child_submit'));
        expect(submit, findsOneWidget);
        // Submit must start disabled (empty label/name).
        expect(
          tester.widget<FilledButton>(submit).onPressed,
          isNull,
        );

        await tester.enterText(
          find.byKey(const Key('org_unit_add_child_label')),
          'east',
        );
        await tester.enterText(
          find.byKey(const Key('org_unit_add_child_name')),
          'East Region',
        );
        await tester.pump();

        expect(
          tester.widget<FilledButton>(submit).onPressed,
          isNotNull,
        );
      },
    );

    testWidgets(
      'Team tab Org Hierarchy renders mutation controls for assign actor',
      (tester) async {
        const owner = TeamScopeActor(
          actorRoles: <String>{'operator_owner'},
          actorOperatorId: 'op-1',
          actorAssignedLocationIds: <String>{},
          actorPermissions: <String>{
            'team.users.view',
            'team.roles.assign',
          },
        );
        const root = TeamOrgUnitEntry(
          orgUnitId: 'unit-root',
          parentOrgUnitId: null,
          unitType: 'corp',
          path: 'acme',
          label: 'ACME',
        );
        const downtown = TeamOrgLocationEntry(
          locationId: 'loc-downtown',
          parentOrgUnitId: 'unit-root',
          orgUnitPath: 'acme',
          label: 'Downtown',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              teamActor: owner,
              teamOrgUnits: const <TeamOrgUnitEntry>[root],
              teamOrgLocations: const <TeamOrgLocationEntry>[downtown],
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('settings_tab_team')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(
            const Key('org_unit_add_child_unit-root'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('Team tab renders for an allowed actor', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            initialMockDate: '2026-03-27',
            teamActor: _settingsTeamOwnerActor,
            teamUsers: const <TeamUserListItem>[
              TeamUserListItem(
                userId: 'user-1',
                email: 'jane@example.test',
                displayName: 'Jane Owner',
                roleId: 'operator_owner',
                roleLabel: 'Owner',
                status: 'active',
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('settings_tab_team')), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings_tab_team')));
      await tester.pumpAndSettle();

      expect(find.text('Members', skipOffstage: false), findsOneWidget);
      expect(
        find.byKey(const Key('team_settings_section'), skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('Jane Owner', skipOffstage: false), findsOneWidget);
    });

    testWidgets('Team role options can hydrate after Settings opens', (
      tester,
    ) async {
      final roles = ValueNotifier<List<TeamRoleOption>>(
        TeamSettingsSection.defaultRoleOptions,
      );
      addTearDown(roles.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            initialMockDate: '2026-03-27',
            teamActor: _settingsTeamOwnerActor,
            teamRoleOptionsListenable: roles,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings_tab_team')));
      await tester.pumpAndSettle();

      TeamSettingsSection section() {
        return tester.widget<TeamSettingsSection>(
          find.byType(TeamSettingsSection, skipOffstage: false),
        );
      }

      expect(section().roleOptions.first.label, equals('Owner'));

      roles.value = const <TeamRoleOption>[
        TeamRoleOption(roleId: 'role-chef', label: 'Chef Lead'),
      ];
      await tester.pump();

      expect(section().roleOptions, hasLength(1));
      expect(section().roleOptions.single.label, equals('Chef Lead'));
    });

    testWidgets(
      'Team tab shows a friendly loading fallback before data lands',
      (tester) async {
        final dataLoadState = ValueNotifier<TeamSettingsDataLoadState>(
          TeamSettingsDataLoadState.waiting,
        );
        addTearDown(dataLoadState.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              teamActor: _settingsTeamOwnerActor,
              teamDataLoadState: TeamSettingsDataLoadState.waiting,
              teamDataLoadStateListenable: dataLoadState,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        await tester.tap(find.byKey(const Key('settings_tab_team')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));

        expect(
          find.text('Staff late looking for Parking lol', skipOffstage: false),
          findsWidgets,
        );
        expect(
          find.byKey(
            const Key('team_data_loading_notice'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );

        dataLoadState.value = TeamSettingsDataLoadState.ready;
        await tester.pump();

        expect(
          find.byKey(
            const Key('team_data_loading_notice'),
            skipOffstage: false,
          ),
          findsNothing,
        );
        expect(
          find.text('No team members', skipOffstage: false),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    // Phase 9.UX.2 — Settings → Team → Roles wiring assertions. The
    // dedicated section widget tests live in
    // `test/settings_custom_roles_section_test.dart`; these only assert
    // that the screen passes the catalog through and reflects
    // permission gates.
    testWidgets(
      'Roles section renders catalog and create button for owner',
      (tester) async {
        const catalog = <TeamRoleCatalogEntry>[
          TeamRoleCatalogEntry(
            roleId: 'role-seed-owner',
            roleKey: 'operator_owner',
            displayName: 'Operator Owner',
            description: 'Full operator-scope admin.',
            isSeeded: true,
            isEditable: false,
            permissions: <TeamRolePermissionRule>[],
          ),
          TeamRoleCatalogEntry(
            roleId: 'role-custom-1',
            roleKey: 'kitchen_lead',
            displayName: 'Kitchen Lead',
            description: '',
            isSeeded: false,
            isEditable: true,
            operatorId: 'op-1',
            permissions: <TeamRolePermissionRule>[
              TeamRolePermissionRule(
                permissionKey: 'forgeflow.shift.view',
                effect: 'allow',
              ),
            ],
          ),
        ];

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              teamActor: _settingsRolesOwnerActor,
              teamRoleCatalog: catalog,
              onTeamRoleCreate: (_) async => null,
              onTeamRolePatch: (_) async => null,
              onTeamRoleDelete: (_) async => true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('settings_tab_team')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(
            const Key('settings_custom_roles_section'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('settings_custom_roles_create_button'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(
          find.text('Custom roles (1)', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text('Seeded roles (1)', skipOffstage: false),
          findsOneWidget,
        );
        // Custom Kitchen Lead is editable + deletable; seeded
        // operator_owner is read-only with View affordance.
        expect(
          find.byKey(
            const Key('settings_custom_role_edit_role-custom-1'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('settings_custom_role_delete_role-custom-1'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('settings_custom_role_view_role-seed-owner'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Roles section hides create + mutators for read-only managers',
      (tester) async {
        const catalog = <TeamRoleCatalogEntry>[
          TeamRoleCatalogEntry(
            roleId: 'role-custom-1',
            roleKey: 'kitchen_lead',
            displayName: 'Kitchen Lead',
            description: '',
            isSeeded: false,
            isEditable: true,
            operatorId: 'op-1',
            permissions: <TeamRolePermissionRule>[],
          ),
        ];

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              teamActor: _settingsRolesReadOnlyActor,
              teamRoleCatalog: catalog,
              onTeamRoleCreate: (_) async => null,
              onTeamRolePatch: (_) async => null,
              onTeamRoleDelete: (_) async => true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('settings_tab_team')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(
            const Key('settings_custom_roles_section'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('settings_custom_roles_create_button'),
            skipOffstage: false,
          ),
          findsNothing,
        );
        expect(
          find.byKey(
            const Key('settings_custom_role_edit_role-custom-1'),
            skipOffstage: false,
          ),
          findsNothing,
        );
        expect(
          find.byKey(
            const Key('settings_custom_role_delete_role-custom-1'),
            skipOffstage: false,
          ),
          findsNothing,
        );
        expect(
          find.byKey(
            const Key('settings_custom_role_view_role-custom-1'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Roles catalog feeds TeamSettingsSection.roleOptions',
      (tester) async {
        // P3: when teamRoleCatalogListenable yields entries, the role
        // pickers used by invite + role-grant flows must consume the
        // catalog so a newly created custom role is grantable without
        // a Settings reopen.
        final catalog = ValueNotifier<List<TeamRoleCatalogEntry>>(
          const <TeamRoleCatalogEntry>[],
        );
        addTearDown(catalog.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              teamActor: _settingsRolesOwnerActor,
              teamRoleCatalog: catalog.value,
              teamRoleCatalogListenable: catalog,
              onTeamRoleCreate: (_) async => null,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('settings_tab_team')));
        await tester.pumpAndSettle();

        TeamSettingsSection section() {
          return tester.widget<TeamSettingsSection>(
            find.byType(TeamSettingsSection, skipOffstage: false),
          );
        }

        // Empty catalog → falls back to the default seeded options
        // bundled with TeamSettingsSection so existing flows do not
        // collapse before the live gateway resolves.
        expect(section().roleOptions.first.label, equals('Owner'));

        // Catalog yields a custom role → role pickers immediately
        // consume the catalog projection. The fallback (Owner /
        // Manager / Supervisor / Staff) is dropped in favor of
        // whatever the operator's catalog actually contains.
        catalog.value = const <TeamRoleCatalogEntry>[
          TeamRoleCatalogEntry(
            roleId: 'role-new-1',
            roleKey: 'kitchen_lead',
            displayName: 'Kitchen Lead',
            description: '',
            isSeeded: false,
            isEditable: true,
            operatorId: 'op-1',
            permissions: <TeamRolePermissionRule>[],
          ),
        ];
        await tester.pump();

        final options = section().roleOptions;
        expect(options, hasLength(1));
        expect(options.single.roleId, equals('role-new-1'));
        expect(options.single.label, equals('Kitchen Lead'));
      },
    );

    testWidgets(
      'Roles catalog listenable rehydrates after a save',
      (tester) async {
        final catalog = ValueNotifier<List<TeamRoleCatalogEntry>>(
          const <TeamRoleCatalogEntry>[],
        );
        addTearDown(catalog.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              teamActor: _settingsRolesOwnerActor,
              teamRoleCatalog: catalog.value,
              teamRoleCatalogListenable: catalog,
              onTeamRoleCreate: (_) async => null,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('settings_tab_team')));
        await tester.pumpAndSettle();

        // Empty-state hint until the listenable yields.
        expect(
          find.byKey(
            const Key('settings_custom_roles_empty_custom'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );

        catalog.value = const <TeamRoleCatalogEntry>[
          TeamRoleCatalogEntry(
            roleId: 'role-new-1',
            roleKey: 'kitchen_lead',
            displayName: 'Kitchen Lead',
            description: '',
            isSeeded: false,
            isEditable: true,
            operatorId: 'op-1',
            permissions: <TeamRolePermissionRule>[],
          ),
        ];
        await tester.pump();

        // Catalog section now renders the new tile.
        expect(
          find.byKey(
            const Key('settings_custom_role_tile_role-new-1'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
      },
    );
  });

  if (_includePrunedLabelGroups())
    group('Settings DATA STATUS section', () {
      testWidgets('shows CURRENT when status is current', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(
                importStatus: 'completed',
                timestamp: '2026-03-30T10:00:00',
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Data status'), findsOneWidget);
        expect(find.text('CURRENT'), findsOneWidget);
      });

      testWidgets('shows IMPORT FAILED when status is failedImport', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.failedImport(
                errorSummary: 'Connection timeout',
                timestamp: '2026-03-30T09:00:00',
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('IMPORT FAILED'), findsOneWidget);
      });

      testWidgets('shows NO DATA when status is noData', (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: SettingsScreen(initialStatus: AppDataStatus.noData),
          ),
        );
        await tester.pump();

        expect(find.text('NO DATA'), findsOneWidget);
      });

      testWidgets('shows HISTORICAL ONLY when status is historicalOnly', (
        tester,
      ) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: SettingsScreen(initialStatus: AppDataStatus.historicalOnly),
          ),
        );
        await tester.pump();

        expect(find.text('HISTORICAL ONLY'), findsOneWidget);
      });

      testWidgets('shows STALE when status is stale', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.stale(
                timestamp: '2026-03-28T10:00:00',
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('STALE'), findsOneWidget);
      });

      testWidgets('Clear All Data description text is correct', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(initialStatus: AppDataStatus.current()),
          ),
        );
        await tester.pump();
        await _scrollToText(tester, 'Clear All Data');

        expect(
          find.textContaining(
            'keeping restaurant scope and connector settings',
          ),
          findsOneWidget,
        );
      });
    });

  // ── Section organization (7.55m.6) ──────────────────────────────────

  if (_includePrunedLabelGroups())
    group('Settings section labels (7.55m.6)', () {
      testWidgets('shows MOCK REPLAY section label', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Mock replay'), findsOneWidget);
      });

      testWidgets('shows DATA MANAGEMENT section label', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Data management'), findsOneWidget);
      });
    });

  if (_includePrunedLabelGroups())
    group('Settings timing authority section', () {
      testWidgets('shows persisted restaurant timing settings', (tester) async {
        await _reseedDemoForWidgetTest(tester);

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider<RestaurantScopeNotifier>(
                create: (_) => RestaurantScopeNotifier.fromRestaurant(
                  const RestaurantLocation(
                    restaurantId: 'demo_restaurant_001',
                    displayName: 'Forge & Flow',
                    businessTimezone: 'America/St_Johns',
                    createdAt: '2026-03-30T10:00:00Z',
                    updatedAt: '2026-03-30T10:00:00Z',
                  ),
                ),
              ),
            ],
            child: MaterialApp(
              home: SettingsScreen(
                initialStatus: AppDataStatus.current(),
                initialMockDate: '2026-03-27',
              ),
            ),
          ),
        );
        await _pumpForAsync(tester);
        await _scrollToText(tester, 'Timing authority');

        expect(find.text('Timing authority'), findsOneWidget);
        expect(find.text('America/St_Johns'), findsOneWidget);
        expect(find.text('Business Day Starts'), findsOneWidget);
        expect(find.text('Week Starts'), findsOneWidget);
        expect(find.text('Lunch'), findsOneWidget);
        expect(find.text('Dinner'), findsOneWidget);
        expect(find.text('Late Night'), findsOneWidget);
      });
    });

  // ── Mock replay controls ──────────────────────────────────────────────

  if (_includePrunedLabelGroups())
    group('Settings mock replay controls', () {
      testWidgets('shows Mock Business Date label', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Mock Business Date'), findsOneWidget);
      });

      testWidgets('shows formatted mock date when provided', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Fri, Mar 27, 2026'), findsOneWidget);
      });

      testWidgets('shows Reset Mock Scenario action', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Reset Mock Scenario'), findsOneWidget);
      });

      testWidgets('shows Advance Mock Day action', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Advance Mock Day'), findsOneWidget);
        expect(
          find.text('Move mock business date forward one day'),
          findsOneWidget,
        );
      });
    });

  // ── Wage mix panel read-only shape (7.55p.5f1a) ──────────────────────

  group('Settings data alignment audit plan authority', () {
    testWidgets(
      'audit panel stays on the strict locked-plan path when the snapshot '
      'is missing',
      (tester) async {
        await _reseedDemoForWidgetTest(tester);

        await tester.runAsync(() async {
          final db = await SqliteDatabase.instance.database;
          await db.delete('weekly_plan_snapshots');

          // Sanity: the live plan path still resolves, but the audit panel
          // must not use it as a competing authority path.
          final livePlan = await SchedulePlanReadService.instance
              .getCurrentWeeklyPlan();
          expect(livePlan, isNotNull);
          expect(await db.query('weekly_plan_snapshots'), isEmpty);
        });

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
            ),
          ),
        );
        await _pumpForAsync(tester);
        await _scrollToText(tester, 'Data Alignment Audit');

        await tester.tap(find.text('Data Alignment Audit'));
        await _pumpUntilFound(
          tester,
          find.text('SCHEDULE FORECAST', skipOffstage: false),
        );

        expect(find.textContaining('LIVE RESOLVED'), findsNothing);
        expect(
          find.text('SCHEDULE FORECAST', skipOffstage: false),
          findsOneWidget,
        );
        expect(find.text('SCHEDULE PLAN', skipOffstage: false), findsOneWidget);
        expect(
          find.text('Not resolved', skipOffstage: false),
          findsAtLeastNWidgets(2),
        );

        // 7.55r item 4 Tier 3: provenance section degrades honestly in the
        // no-snapshot state (does not fabricate a locked-week identity).
        expect(
          find.text('LOCKED WEEK PROVENANCE', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text('No current-week snapshot resolved', skipOffstage: false),
          findsOneWidget,
        );

        await tester.runAsync(() async {
          final db = await SqliteDatabase.instance.database;
          expect(
            await db.query('weekly_plan_snapshots'),
            isEmpty,
            reason:
                'expanding the audit panel must not auto-generate a locked '
                'snapshot through the live plan path',
          );
        });
      },
    );

    testWidgets(
      'audit panel exposes locked-week / target-cycle provenance rows '
      'when a snapshot exists',
      (tester) async {
        await _reseedDemoForWidgetTest(tester);

        // Prime a locked weekly plan via the auto-generating read path so
        // the audit panel has a snapshot to read from. Uses the same
        // authority seam a production first-render would take.
        await tester.runAsync(() async {
          await SchedulePlanReadService.instance.getCurrentLockedWeeklyPlan();
        });

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
            ),
          ),
        );
        await _pumpForAsync(tester);
        await _scrollToText(tester, 'Data Alignment Audit');

        await tester.tap(find.text('Data Alignment Audit'));
        await _pumpUntilFound(
          tester,
          find.text('LOCKED WEEK PROVENANCE', skipOffstage: false),
        );

        expect(
          find.text('LOCKED WEEK PROVENANCE', skipOffstage: false),
          findsOneWidget,
        );
        // Labels rendered by the provenance rows. Asserting the labels
        // rather than the resolved values keeps the test robust to seed
        // timing drift.
        expect(find.text('WEEK KEY', skipOffstage: false), findsOneWidget);
        expect(find.text('WEEK SPAN', skipOffstage: false), findsOneWidget);
        expect(find.text('SNAPSHOT ID', skipOffstage: false), findsOneWidget);
        expect(
          find.text('TARGET CYCLE ID', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text('EFFECTIVE WINDOW', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.text('CALIBRATION WINDOW', skipOffstage: false),
          findsOneWidget,
        );
      },
    );

    // ── 7.56c.1 — grouped audit-check sections render ───────────────────
    //
    // The audit panel now exposes Plan + Benchmark coverage in grouped
    // sections (live actuals / benchmark authority / benchmark runtime
    // / locked plan ↔ projection / plan runtime). This smoke covers
    // header + group titles for the populated-snapshot path so the
    // grouped audit is wired through the read service end to end.

    testWidgets('audit panel renders 7.56c.1 grouped audit-check sections '
        'with summary lines', (tester) async {
      await _reseedDemoForWidgetTest(tester);
      await tester.runAsync(() async {
        await SchedulePlanReadService.instance.getCurrentLockedWeeklyPlan();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            initialMockDate: '2026-03-27',
          ),
        ),
      );
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Data Alignment Audit');

      await tester.tap(find.text('Data Alignment Audit'));
      await _pumpUntilFound(
        tester,
        find.textContaining('AUDIT CHECKS —', skipOffstage: false),
      );

      // Overall AUDIT CHECKS header is present with a summary line.
      expect(
        find.textContaining('AUDIT CHECKS —', skipOffstage: false),
        findsOneWidget,
      );

      // Each canonical group title is rendered with an aligned/drifted/
      // unavailable summary suffix.
      expect(
        find.textContaining('LIVE / ACTUAL PROVENANCE', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('BENCHMARK AUTHORITY', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('BENCHMARK -> RUNTIME', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('LOCKED PLAN <-> PROJECTION', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('PLAN -> RUNTIME', skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('audit panel grouped sections degrade to unavailable when no '
        'snapshot exists', (tester) async {
      await _reseedDemoForWidgetTest(tester);

      await tester.runAsync(() async {
        final db = await SqliteDatabase.instance.database;
        await db.delete('weekly_plan_snapshots');
      });

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            initialMockDate: '2026-03-27',
          ),
        ),
      );
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Data Alignment Audit');

      await tester.tap(find.text('Data Alignment Audit'));
      await _pumpUntilFound(
        tester,
        find.textContaining('AUDIT CHECKS —', skipOffstage: false),
      );

      // Group titles still render even when the snapshot path is empty.
      expect(
        find.textContaining('LOCKED PLAN <-> PROJECTION', skipOffstage: false),
        findsOneWidget,
      );

      // Confirms the panel degrades honestly: the no-snapshot path
      // surfaces unavailable counts somewhere in the AUDIT CHECKS area
      // rather than silently dropping the sections.
      expect(
        find.textContaining('unavailable', skipOffstage: false),
        findsAtLeastNWidgets(1),
      );
    });
  });

  group('Settings wage mix panel (7.55p.5f1a)', () {
    testWidgets('panel is a read-only summary + single Edit Wage Mix action', (
      tester,
    ) async {
      await _reseedDemoForWidgetTest(tester);
      final restaurantId = await _getActiveRestaurantId(tester);
      await _deleteAllWageRows(tester, restaurantId);

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            initialMockDate: '2026-03-27',
          ),
        ),
      );
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Edit Wage Mix');

      // Wage panel content is now in view.
      expect(find.text('MIX SUMMARY'), findsWidgets);

      // Grouped read-only bucket headers are rendered as their own row;
      // role count lives in a count pill beside each header.
      expect(find.text('FRONT OF HOUSE'), findsOneWidget);
      expect(find.text('BACK OF HOUSE'), findsOneWidget);
      expect(find.text('MANAGEMENT'), findsOneWidget);

      // The panel exposes exactly one whole-mix edit action.
      expect(find.text('Edit Wage Mix'), findsOneWidget);

      // The per-bucket add buttons from the intermediate 7.55p.5f1
      // implementation are gone from the Settings panel. Editing now
      // happens only inside the editor.
      expect(find.text('Add FOH role'), findsNothing);
      expect(find.text('Add BOH role'), findsNothing);
      expect(find.text('Add Management role'), findsNothing);

      // Older flat-list affordances from before 7.55p.5f1 remain absent.
      expect(find.text('Add Role'), findsNothing);
      expect(find.text('FALLBACK ROLES'), findsNothing);
    });

    testWidgets('empty mix shows Config Default warning on the panel', (
      tester,
    ) async {
      await _reseedDemoForWidgetTest(tester);
      final restaurantId = await _getActiveRestaurantId(tester);
      await _deleteAllWageRows(tester, restaurantId);

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            initialMockDate: '2026-03-27',
          ),
        ),
      );
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Edit Wage Mix');

      expect(find.textContaining('No roles configured'), findsOneWidget);
      expect(find.text('Config Default'), findsOneWidget);
    });
  });

  // ── Whole-mix editor real save path (7.55p.5f1a) ─────────────────────
  //
  // These tests drive the actual UI: tap `Edit Wage Mix`, fill inline
  // rows, tap Save, and assert persistence + profile sync. They
  // replace the earlier repo-seeded shape tests.

  group('Whole-mix editor real save path (7.55p.5f1a)', () {
    testWidgets('complete FOH+BOH mix entered through the editor persists and '
        'updates ActiveTargetProfile wages', (tester) async {
      await _reseedDemoForWidgetTest(tester);
      final restaurantId = await _getActiveRestaurantId(tester);
      await _deleteAllWageRows(tester, restaurantId);
      // Pre-sync so the profile starts with config defaults.
      await _syncWagesToActiveProfile(tester);

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            initialMockDate: '2026-03-27',
          ),
        ),
      );
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Edit Wage Mix');

      // Open the whole-mix editor.
      await tester.tap(find.text('Edit Wage Mix'));
      await _pumpUntilFound(tester, find.text('Add FOH role'));

      // Editor route is live.
      expect(find.text('Edit Wage Mix'), findsWidgets);
      expect(find.text('Add FOH role'), findsOneWidget);
      expect(find.text('Add BOH role'), findsOneWidget);

      // Add one FOH row inline.
      await tester.tap(find.text('Add FOH role'));
      await _pumpForAsync(tester);

      // The newly added FOH row exposes three fields (role, rate,
      // hours). Fill them in via real text entry.
      var fields = find.byType(TextField);
      expect(fields, findsNWidgets(3));
      await tester.enterText(fields.at(0), 'Server');
      await tester.enterText(fields.at(1), '17.50');
      await tester.enterText(fields.at(2), '30');
      await _pumpForAsync(tester);

      // Add one BOH row inline.
      await tester.tap(find.text('Add BOH role'));
      await _pumpForAsync(tester);

      fields = find.byType(TextField);
      expect(fields, findsNWidgets(6));
      await tester.enterText(fields.at(3), 'Line Cook');
      await tester.enterText(fields.at(4), '22.75');
      await tester.enterText(fields.at(5), '35');
      await _pumpForAsync(tester);

      // Save the whole mix in one pass.
      await tester.tap(find.text('Save Wage Mix'));
      await _pumpForDbAsync(tester);

      // Persistence proof: two rows are in SQLite.
      final rows = await _getWageRows(tester, restaurantId);
      expect(rows.length, 2);
      final foh = rows.firstWhere((r) => r.laborBucket == 'foh');
      final boh = rows.firstWhere((r) => r.laborBucket == 'boh');
      expect(foh.roleName, 'Server');
      expect(foh.hourlyRate, closeTo(17.50, 0.01));
      expect(foh.weightedHours, closeTo(30, 0.01));
      expect(boh.roleName, 'Line Cook');
      expect(boh.hourlyRate, closeTo(22.75, 0.01));
      expect(boh.weightedHours, closeTo(35, 0.01));

      // Resolution proof: the authority waterfall resolves as
      // App Configured (not config fallback).
      final ctx = await _resolveWageContext(tester, restaurantId);
      expect(ctx.source, WageStandardSource.appConfiguredGenerator);
      expect(ctx.fohWage, closeTo(17.50, 0.01));
      expect(ctx.bohWage, closeTo(22.75, 0.01));

      // Sync proof: the ActiveTargetProfile fields that Benchmark,
      // Variance WTD, Variance Full Week, and Shift read from now
      // carry the edited wages and the wage-derived theoretical
      // percentages.
      final profile = await _getActiveTargetProfile(tester, restaurantId);
      expect(profile, isNotNull);
      expect(profile!.fohWage, closeTo(17.50, 0.01));
      expect(profile.bohWage, closeTo(22.75, 0.01));
      final expectedFoh =
          17.50 / (profile.targetCPLH * profile.targetPPA) * 100;
      final expectedBoh = 22.75 / profile.targetSPLH * 100;
      expect(profile.theoreticalFohLaborPct, closeTo(expectedFoh, 0.01));
      expect(profile.theoreticalBohLaborPct, closeTo(expectedBoh, 0.01));
      expect(
        profile.theoreticalLaborPct,
        closeTo(expectedFoh + expectedBoh, 0.01),
      );
    });

    testWidgets('manager-only mix entered through the editor stays honest: '
        'saves the row but authority remains Config Default', (tester) async {
      await _reseedDemoForWidgetTest(tester);
      final restaurantId = await _getActiveRestaurantId(tester);
      await _deleteAllWageRows(tester, restaurantId);
      await _syncWagesToActiveProfile(tester);

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            initialMockDate: '2026-03-27',
          ),
        ),
      );
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Edit Wage Mix');

      // Open editor.
      await tester.tap(find.text('Edit Wage Mix'));
      await _pumpUntilFound(tester, find.text('Add Management role'));

      // The Management bucket sits at the bottom of the editor — scroll
      // its add button into view before tapping so it isn't blocked by
      // the pinned Save Wage Mix bar.
      await tester.ensureVisible(find.text('Add Management role'));
      await _pumpForAsync(tester);

      // Add one Management row only — deliberately incomplete.
      await tester.tap(find.text('Add Management role'));
      await _pumpForAsync(tester);

      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(3));
      await tester.enterText(fields.at(0), 'GM');
      await tester.enterText(fields.at(1), '30');
      await tester.enterText(fields.at(2), '40');
      await _pumpForAsync(tester);

      // Editor shows the honest "will fall back" warning.
      expect(
        find.textContaining('Will fall back to Config Default'),
        findsOneWidget,
      );

      await tester.tap(find.text('Save Wage Mix'));
      await _pumpForDbAsync(tester);

      // Persistence proof: manager row is saved.
      final rows = await _getWageRows(tester, restaurantId);
      expect(rows.length, 1);
      expect(rows.first.laborBucket, 'manager');
      expect(rows.first.hourlyRate, closeTo(30, 0.01));

      // Honesty proof: authority still resolves as Config Default,
      // and the profile does NOT carry the $30 manager rate as FOH or
      // BOH wages.
      final ctx = await _resolveWageContext(tester, restaurantId);
      expect(ctx.source, WageStandardSource.configFallback);

      final profile = await _getActiveTargetProfile(tester, restaurantId);
      expect(profile, isNotNull);
      expect(profile!.fohWage, lessThan(30.0));
      expect(profile.bohWage, lessThan(30.0));

      // Settings panel shows the incomplete warning band.
      await _scrollToText(tester, 'Edit Wage Mix');
      expect(
        find.textContaining('one FOH role AND one BOH role'),
        findsOneWidget,
      );
      expect(find.text('Config Default'), findsOneWidget);
      expect(find.text('App Configured'), findsNothing);
    });

    testWidgets('removing an existing row in the editor deletes it on save '
        'and degrades authority honestly', (tester) async {
      await _reseedDemoForWidgetTest(tester);
      final restaurantId = await _getActiveRestaurantId(tester);
      await _deleteAllWageRows(tester, restaurantId);
      // Seed a complete mix first.
      await tester.runAsync(() async {
        await SqliteWageRoleRowRepository.instance.upsertRow(
          WageRoleRow(
            restaurantId: restaurantId,
            roleName: 'Server',
            laborBucket: 'foh',
            hourlyRate: 16.00,
            weightedHours: 30,
          ),
        );
        await SqliteWageRoleRowRepository.instance.upsertRow(
          WageRoleRow(
            restaurantId: restaurantId,
            roleName: 'Line Cook',
            laborBucket: 'boh',
            hourlyRate: 20.00,
            weightedHours: 35,
          ),
        );
      });
      await _syncWagesToActiveProfile(tester);

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            initialMockDate: '2026-03-27',
          ),
        ),
      );
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Edit Wage Mix');

      await tester.tap(find.text('Edit Wage Mix'));
      await _pumpUntilFound(tester, find.text('Add FOH role'));

      // Editor should show both seeded rows (6 TextFields — 3 per row).
      expect(find.byType(TextField), findsNWidgets(6));

      // Remove the BOH row via its trash-style icon.
      final removeButtons = find.byTooltip('Remove role');
      expect(removeButtons, findsNWidgets(2));
      await tester.tap(removeButtons.at(1));
      await _pumpForAsync(tester);

      // Only the FOH row's fields remain.
      expect(find.byType(TextField), findsNWidgets(3));

      await tester.tap(find.text('Save Wage Mix'));
      await _pumpForDbAsync(tester);

      // Persistence proof: the removed BOH row is gone.
      final rows = await _getWageRows(tester, restaurantId);
      expect(rows.length, 1);
      expect(rows.first.laborBucket, 'foh');

      // Authority proof: FOH-only mix degrades to configFallback.
      final ctx = await _resolveWageContext(tester, restaurantId);
      expect(ctx.source, WageStandardSource.configFallback);
    });

    testWidgets(
      'clearing an existing row field drops the stale persisted row on save',
      (tester) async {
        await _reseedDemoForWidgetTest(tester);
        final restaurantId = await _getActiveRestaurantId(tester);
        await _deleteAllWageRows(tester, restaurantId);
        await tester.runAsync(() async {
          await SqliteWageRoleRowRepository.instance.upsertRow(
            WageRoleRow(
              restaurantId: restaurantId,
              roleName: 'Server',
              laborBucket: 'foh',
              hourlyRate: 16.00,
              weightedHours: 30,
            ),
          );
          await SqliteWageRoleRowRepository.instance.upsertRow(
            WageRoleRow(
              restaurantId: restaurantId,
              roleName: 'Line Cook',
              laborBucket: 'boh',
              hourlyRate: 20.00,
              weightedHours: 35,
            ),
          );
        });
        await _syncWagesToActiveProfile(tester);

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
            ),
          ),
        );
        await _pumpForAsync(tester);
        await _scrollToText(tester, 'Edit Wage Mix');

        await tester.tap(find.text('Edit Wage Mix'));
        await _pumpUntilFound(tester, find.text('Add FOH role'));

        final fields = find.byType(TextField);
        expect(fields, findsNWidgets(6));

        // Clear the persisted BOH role name to make that draft invalid.
        await tester.enterText(fields.at(3), '');
        await _pumpForAsync(tester);

        await tester.tap(find.text('Save Wage Mix'));
        await _pumpForDbAsync(tester);

        // The stale BOH row should be deleted instead of silently preserved.
        final rows = await _getWageRows(tester, restaurantId);
        expect(rows.length, 1);
        expect(rows.first.laborBucket, 'foh');
        expect(rows.first.roleName, 'Server');

        final ctx = await _resolveWageContext(tester, restaurantId);
        expect(ctx.source, WageStandardSource.configFallback);
      },
    );
  });

  // ── 7.55q.9 — Reset Target Cycle (Admin) tile renders + opens dialog ──

  group('Settings 7.55q.9 admin reset tile', () {
    if (_includePrunedLabelGroups())
      testWidgets('Reset Target Cycle (Admin) tile renders with admin '
          'description', (tester) async {
        await _reseedDemoForWidgetTest(tester);
        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
            ),
          ),
        );
        await _pumpForAsync(tester);

        // Settings screen is long — match offstage and use the file's
        // established scroll helper so suite ordering doesn't make the
        // assertion flaky.
        expect(
          find.text('Reset Target Cycle (Admin)', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Clears manager override + rebuilds the active 60-day',
            skipOffstage: false,
          ),
          findsOneWidget,
        );
      });

    testWidgets('tapping Reset Target Cycle (Admin) opens a confirm '
        'dialog with Cancel + Reset actions', (tester) async {
      await _reseedDemoForWidgetTest(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            initialMockDate: '2026-03-27',
          ),
        ),
      );
      await _pumpForAsync(tester);

      // Use the file's established scroll helper to bring the tile
      // on-stage before tapping (Settings is taller than the test
      // viewport).
      await _scrollToText(tester, 'Reset Target Cycle (Admin)');
      final resetRow = find.ancestor(
        of: find.text('Reset Target Cycle (Admin)'),
        matching: find.byType(InkWell),
      );
      await tester.ensureVisible(resetRow.first);
      await _pumpForAsync(tester);
      await tester.tap(resetRow.first);
      await _pumpForAsync(tester);

      expect(find.text('Reset target cycle?'), findsOneWidget);
      expect(
        find.textContaining(
          'Clears the persisted manager override and the active',
        ),
        findsOneWidget,
      );
      expect(find.text('Cancel'), findsAtLeastNWidgets(1));
      expect(find.text('Reset'), findsOneWidget);

      // Cancel exits the dialog without acting.
      await tester.tap(find.text('Cancel'));
      await _pumpForAsync(tester);
      expect(find.text('Reset target cycle?'), findsNothing);
    });
  });

  // 7.57.3a-review-fix: dev-only ADVISOR MODELS section. Registered last so
  // it does not change the relative ordering of the prior groups (a few
  // smoke tests are sensitive to a clean test-binding state at start).
  _advisorSectionTests();

  // 11a.12: dev-only ADVISOR CORPUS section. Registered after the model
  // section for the same reason — keep the prior smoke-test ordering
  // untouched.
  _advisorCorpusSectionTests();
}

/// Helper: pump repeatedly to let async DB work + animations settle
/// without risking `pumpAndSettle` deadlock on a Provider-heavy
/// screen.
Future<void> _pumpForAsync(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    });
  }
}

Future<void> _pumpForDbAsync(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });
  await _pumpForAsync(tester);
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxTicks = 20,
}) async {
  for (var i = 0; i < maxTicks; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await _pumpForAsync(tester);
  }
}

Future<void> _scrollToText(WidgetTester tester, String text) async {
  final tabId = _settingsTabIdForText(text);
  await _openSettingsTab(tester, tabId);
  await tester.scrollUntilVisible(
    find.text(text, skipOffstage: false),
    250,
    scrollable: _settingsScrollable(tabId),
  );
  await _pumpForAsync(tester);
}

Future<void> _openSettingsTab(WidgetTester tester, String tabId) async {
  final tab = find.byKey(Key('settings_tab_$tabId'));
  if (tab.evaluate().isEmpty) return;
  await tester.tap(tab);
  await _pumpForAsync(tester);
}

Finder _settingsScrollable(String tabId) {
  return find
      .descendant(
        of: find.byKey(PageStorageKey<String>('settings_${tabId}_scroll')),
        matching: find.byType(Scrollable),
      )
      .first;
}

String _settingsTabIdForText(String text) {
  const authorityTargets = {
    'Timing authority',
    'Wage authority',
    'Edit Wage Mix',
  };
  const developerTargets = {
    'Data Alignment Audit',
    'Advisor models',
    'Advisor corpus',
  };
  if (authorityTargets.contains(text)) return 'authority';
  if (developerTargets.contains(text)) return 'developer';
  return 'data';
}

String _settingsTabIdForKey(Key key) {
  if (key == const Key('advisor_check_button') ||
      key == const Key('advisor_corpus_preview_button') ||
      key == const Key('advisor_corpus_cloud_load_button')) {
    return 'developer';
  }
  return 'data';
}

Future<void> _reseedDemoForWidgetTest(WidgetTester tester) async {
  await tester.runAsync(() async {
    await SqliteDatabase.instance.reseedDemo();
  });
}

Future<String> _getActiveRestaurantId(WidgetTester tester) async {
  return (await tester.runAsync(() async {
    return SqliteRestaurantScopeRepository.instance.getActiveRestaurantId();
  }))!;
}

Future<void> _deleteAllWageRows(
  WidgetTester tester,
  String restaurantId,
) async {
  await tester.runAsync(() async {
    await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);
  });
}

Future<void> _syncWagesToActiveProfile(WidgetTester tester) async {
  await tester.runAsync(() async {
    await WageStandardContextService.instance.syncWagesToActiveProfile();
  });
}

Future<List<WageRoleRow>> _getWageRows(
  WidgetTester tester,
  String restaurantId,
) async {
  return (await tester.runAsync(() async {
    return SqliteWageRoleRowRepository.instance.getRows(restaurantId);
  }))!;
}

Future<WageStandardContext> _resolveWageContext(
  WidgetTester tester,
  String restaurantId,
) async {
  return (await tester.runAsync(() async {
    return WageStandardContextService.instance.resolve(restaurantId);
  }))!;
}

Future<ActiveTargetProfile?> _getActiveTargetProfile(
  WidgetTester tester,
  String restaurantId,
) async {
  return (await tester.runAsync<ActiveTargetProfile?>(() async {
    return SqliteTargetProfileRepository.instance.getActiveTargetProfile(
      restaurantId,
    );
  }))!;
}

// ─── 7.57.3a-review-fix: dev-only ADVISOR MODELS section tests ───────────────

Future<void> _pumpAdvisorSettings(
  WidgetTester tester, {
  required AdvisorModelConfigService service,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SettingsScreen(
        initialStatus: AppDataStatus.current(),
        initialMockDate: '2026-03-27',
        advisorModelConfigService: service,
        forceShowAdvisorModelSection: true,
      ),
    ),
  );
  // Section bodies use FutureBuilders / async loads — drain them so no
  // timers leak into subsequent tests in the same file.
  await tester.pump();
  await tester.pumpAndSettle();
}

void _advisorSectionTests() {
  group('Settings ADVISOR MODELS section (dev-only)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets('renders pinned defaults and Voyage read-only values', (
      tester,
    ) async {
      final svc = AdvisorModelConfigService(
        onlineCheckFn:
            ({
              required String quickModelId,
              required String nuancedModelId,
            }) async =>
                const AnthropicModelCheckResult.cannotCheck('test default'),
      );

      await _pumpAdvisorSettings(tester, service: svc);
      await _scrollToText(tester, 'Advisor models');

      expect(find.text('Advisor models', skipOffstage: false), findsOneWidget);
      expect(
        find.textContaining('claude-haiku-4-5', skipOffstage: false),
        findsWidgets,
      );
      expect(
        find.textContaining('claude-sonnet-4-6', skipOffstage: false),
        findsWidgets,
      );
      expect(
        find.byKey(const Key('advisor_voyage_pinned'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('voyage-4-large', skipOffstage: false),
        findsWidgets,
      );
      expect(
        find.textContaining('rerank-2.5', skipOffstage: false),
        findsWidgets,
      );
    });

    testWidgets('Reset Defaults and Check Anthropic Models actions render', (
      tester,
    ) async {
      final svc = AdvisorModelConfigService(
        onlineCheckFn:
            ({
              required String quickModelId,
              required String nuancedModelId,
            }) async =>
                const AnthropicModelCheckResult.cannotCheck('test default'),
      );

      await _pumpAdvisorSettings(tester, service: svc);
      await _scrollToText(tester, 'Advisor models');

      expect(
        find.byKey(const Key('advisor_reset_button'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('advisor_check_button'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('advisor_quick_override_field'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('advisor_nuanced_override_field'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
    });

    testWidgets('Check action surfaces injected fake result text', (
      tester,
    ) async {
      final svc = AdvisorModelConfigService(
        onlineCheckFn:
            ({
              required String quickModelId,
              required String nuancedModelId,
            }) async => const AnthropicModelCheckResult(
              status: AnthropicModelCheckStatus.available,
              message: 'fake-up-to-date-message',
            ),
      );

      await _pumpAdvisorSettings(tester, service: svc);
      // Scroll the check button itself onto the visible region before tap.
      await _scrollKeyIntoView(tester, const Key('advisor_check_button'));

      await tester.tap(find.byKey(const Key('advisor_check_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.textContaining('fake-up-to-date-message', skipOffstage: false),
        findsOneWidget,
      );
      // Up-to-date branch (status=available + updateAvailable=false).
      expect(find.text('UP TO DATE', skipOffstage: false), findsOneWidget);
    });

    testWidgets(
      'UPDATE AVAILABLE label and candidate rows render when fake reports update',
      (tester) async {
        final svc = AdvisorModelConfigService(
          onlineCheckFn:
              ({
                required String quickModelId,
                required String nuancedModelId,
              }) async => const AnthropicModelCheckResult(
                status: AnthropicModelCheckStatus.available,
                message: 'newer same-family seen',
                seenModelIds: [
                  'claude-haiku-4-5',
                  'claude-sonnet-4-6',
                  'claude-sonnet-4-7',
                ],
                updateAvailable: true,
                latestNuancedCandidate: 'claude-sonnet-4-7',
              ),
        );

        await _pumpAdvisorSettings(tester, service: svc);
        await _scrollKeyIntoView(tester, const Key('advisor_check_button'));

        await tester.tap(find.byKey(const Key('advisor_check_button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          find.text('UPDATE AVAILABLE', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('advisor_check_nuanced_candidate'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining('claude-sonnet-4-7', skipOffstage: false),
          findsWidgets,
        );
      },
    );

    testWidgets(
      'real debug route renders ADVISOR MODELS without forceShow (kDebugMode + service)',
      (tester) async {
        // Mirrors what `forge_flow_app.dart::_openSettings` does in debug:
        // pushes a SettingsScreen with `advisorModelConfigService` set but
        // no force flag. The section gate (kDebugMode && service != null)
        // should render the section in this configuration.
        final svc = AdvisorModelConfigService(
          onlineCheckFn:
              ({
                required String quickModelId,
                required String nuancedModelId,
              }) async => const AnthropicModelCheckResult.cannotCheck(
                'real-route-test no-network',
              ),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
              advisorModelConfigService: svc,
              // forceShowAdvisorModelSection deliberately omitted
            ),
          ),
        );
        await tester.pump();
        await tester.pumpAndSettle();
        await _scrollToText(tester, 'Advisor models');

        expect(
          find.text('Advisor models', skipOffstage: false),
          findsOneWidget,
        );
      },
    );
  });
}

// ─── 11a.12: dev-only ADVISOR CORPUS section tests ───────────────────────────

Future<void> _pumpAdvisorCorpusSettings(
  WidgetTester tester, {
  required AdvisorCorpusAdminService service,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SettingsScreen(
        initialStatus: AppDataStatus.current(),
        initialMockDate: '2026-03-27',
        advisorCorpusAdminService: service,
        forceShowAdvisorCorpusSection: true,
      ),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<void> _scrollKeyIntoView(WidgetTester tester, Key key) async {
  final tabId = _settingsTabIdForKey(key);
  await _openSettingsTab(tester, tabId);
  // scrollUntilVisible needs the default `skipOffstage: true` so it
  // keeps scrolling until the widget is actually on stage. Passing
  // `skipOffstage: false` would short-circuit on the first frame
  // because the widget exists in the tree (just offstage).
  await tester.scrollUntilVisible(
    find.byKey(key),
    100,
    scrollable: _settingsScrollable(tabId),
  );
  await _pumpForAsync(tester);
}

void _advisorCorpusSectionTests() {
  group('Settings ADVISOR CORPUS section (dev-only)', () {
    testWidgets('renders header, fields, actions, and blocked cloud row', (
      tester,
    ) async {
      await _pumpAdvisorCorpusSettings(
        tester,
        service: AdvisorCorpusAdminService(),
      );
      await _scrollToText(tester, 'Advisor corpus');

      expect(find.text('Advisor corpus', skipOffstage: false), findsOneWidget);
      expect(
        find.byKey(const Key('advisor_corpus_header'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('advisor_corpus_file_name_field'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('advisor_corpus_markdown_field'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('advisor_corpus_preview_button'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('advisor_corpus_cloud_load_button'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('advisor_corpus_cloud_blocked'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
    });

    testWidgets('valid Markdown preview surfaces the local-only summary', (
      tester,
    ) async {
      final service = AdvisorCorpusAdminService();
      await _pumpAdvisorCorpusSettings(tester, service: service);
      await _scrollKeyIntoView(
        tester,
        const Key('advisor_corpus_preview_button'),
      );

      // Drive the controllers directly via the service's preview path
      // and then request the rebuild via tap. Avoids enterText's
      // EditableText focus path, which is unreliable for off-stage
      // multi-line fields in the test viewport.
      tester
              .widget<TextField>(
                find.byKey(
                  const Key('advisor_corpus_file_name_field'),
                  skipOffstage: false,
                ),
              )
              .controller!
              .text =
          'sample.md';
      tester
              .widget<TextField>(
                find.byKey(
                  const Key('advisor_corpus_markdown_field'),
                  skipOffstage: false,
                ),
              )
              .controller!
              .text =
          '# Heading\n\nBody line one.\nBody line two.\n';

      await _scrollKeyIntoView(
        tester,
        const Key('advisor_corpus_preview_button'),
      );
      await tester.tap(find.byKey(const Key('advisor_corpus_preview_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.byKey(
          const Key('advisor_corpus_preview_result'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('PREVIEW LOCAL ONLY', skipOffstage: false),
        findsOneWidget,
      );
      // Ingestion-shaped fields rendered in the result row.
      expect(
        find.textContaining('file · sample.md', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'source · docs/Knowledge_graph_docs/sample.md',
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('title · Heading', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('headings · 1', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('lines · 5', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('est chunks · 1', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('preview_local_only', skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('preview falls back to file-name stem when no H1 is present', (
      tester,
    ) async {
      final service = AdvisorCorpusAdminService();
      await _pumpAdvisorCorpusSettings(tester, service: service);
      await _scrollKeyIntoView(
        tester,
        const Key('advisor_corpus_preview_button'),
      );

      tester
              .widget<TextField>(
                find.byKey(
                  const Key('advisor_corpus_file_name_field'),
                  skipOffstage: false,
                ),
              )
              .controller!
              .text =
          'Wage_Standards.md';
      tester
              .widget<TextField>(
                find.byKey(
                  const Key('advisor_corpus_markdown_field'),
                  skipOffstage: false,
                ),
              )
              .controller!
              .text =
          '## Sub-only heading\n\nbody text\n';

      await _scrollKeyIntoView(
        tester,
        const Key('advisor_corpus_preview_button'),
      );
      await tester.tap(find.byKey(const Key('advisor_corpus_preview_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Title falls back to the file-name stem (no `.md`); the H2
      // line is counted in `headings` but does not become the title.
      expect(
        find.textContaining('title · Wage_Standards', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('headings · 1', skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets(
      'preview normalizes a backslash-prefixed file path to its basename',
      (tester) async {
        final service = AdvisorCorpusAdminService();
        await _pumpAdvisorCorpusSettings(tester, service: service);
        await _scrollKeyIntoView(
          tester,
          const Key('advisor_corpus_preview_button'),
        );

        tester
                .widget<TextField>(
                  find.byKey(
                    const Key('advisor_corpus_file_name_field'),
                    skipOffstage: false,
                  ),
                )
                .controller!
                .text =
            r'C:\some\path\Wage_Standards.md';
        tester
                .widget<TextField>(
                  find.byKey(
                    const Key('advisor_corpus_markdown_field'),
                    skipOffstage: false,
                  ),
                )
                .controller!
                .text =
            '# Wages\n\nbody\n';

        await _scrollKeyIntoView(
          tester,
          const Key('advisor_corpus_preview_button'),
        );
        await tester.tap(
          find.byKey(const Key('advisor_corpus_preview_button')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          find.textContaining('file · Wage_Standards.md', skipOffstage: false),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'source · docs/Knowledge_graph_docs/Wage_Standards.md',
            skipOffstage: false,
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('non-.md filename is rejected with a UI-visible error', (
      tester,
    ) async {
      final service = AdvisorCorpusAdminService();
      await _pumpAdvisorCorpusSettings(tester, service: service);
      await _scrollKeyIntoView(
        tester,
        const Key('advisor_corpus_preview_button'),
      );

      tester
              .widget<TextField>(
                find.byKey(
                  const Key('advisor_corpus_file_name_field'),
                  skipOffstage: false,
                ),
              )
              .controller!
              .text =
          'sample.txt';
      tester
              .widget<TextField>(
                find.byKey(
                  const Key('advisor_corpus_markdown_field'),
                  skipOffstage: false,
                ),
              )
              .controller!
              .text =
          '# Heading\n';

      await _scrollKeyIntoView(
        tester,
        const Key('advisor_corpus_preview_button'),
      );
      await tester.tap(find.byKey(const Key('advisor_corpus_preview_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.byKey(
          const Key('advisor_corpus_preview_error'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('PREVIEW REJECTED', skipOffstage: false),
        findsOneWidget,
      );
      expect(find.textContaining('.md', skipOffstage: false), findsWidgets);
    });

    testWidgets('blank Markdown is rejected with a UI-visible error', (
      tester,
    ) async {
      final service = AdvisorCorpusAdminService();
      await _pumpAdvisorCorpusSettings(tester, service: service);
      await _scrollKeyIntoView(
        tester,
        const Key('advisor_corpus_preview_button'),
      );

      tester
              .widget<TextField>(
                find.byKey(
                  const Key('advisor_corpus_file_name_field'),
                  skipOffstage: false,
                ),
              )
              .controller!
              .text =
          'sample.md';
      tester
              .widget<TextField>(
                find.byKey(
                  const Key('advisor_corpus_markdown_field'),
                  skipOffstage: false,
                ),
              )
              .controller!
              .text =
          '   \n  \t\n';

      await _scrollKeyIntoView(
        tester,
        const Key('advisor_corpus_preview_button'),
      );
      await tester.tap(find.byKey(const Key('advisor_corpus_preview_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.byKey(
          const Key('advisor_corpus_preview_error'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('PREVIEW REJECTED', skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('cloud-load button is non-interactive (onPressed == null)', (
      tester,
    ) async {
      await _pumpAdvisorCorpusSettings(
        tester,
        service: AdvisorCorpusAdminService(),
      );
      await _scrollKeyIntoView(
        tester,
        const Key('advisor_corpus_cloud_load_button'),
      );

      // The blocked row + disabled button are both always rendered.
      // The button is greyed out because `onPressed: null` — no tap
      // attempt is possible from this slice forward.
      final button = tester.widget<TextButton>(
        find.byKey(
          const Key('advisor_corpus_cloud_load_button'),
          skipOffstage: false,
        ),
      );
      expect(button.onPressed, isNull);

      expect(
        find.byKey(
          const Key('advisor_corpus_cloud_blocked'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('CLOUD LOAD · BLOCKED', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('11a.11b', skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('real debug route renders ADVISOR CORPUS without forceShow '
        '(kDebugMode + service)', (tester) async {
      // Mirrors what `forge_flow_app.dart::_openSettings` does in
      // debug: pushes a SettingsScreen with `advisorCorpusAdminService`
      // set but no force flag. The section gate
      // (kDebugMode && service != null) should render the section.
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            initialMockDate: '2026-03-27',
            advisorCorpusAdminService: AdvisorCorpusAdminService(),
            // forceShowAdvisorCorpusSection deliberately omitted
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      await _scrollToText(tester, 'Advisor corpus');

      expect(find.text('Advisor corpus', skipOffstage: false), findsOneWidget);
      expect(
        find.byKey(
          const Key('advisor_corpus_cloud_blocked'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
    });

    testWidgets('is hidden by default — no force flag, no service injected', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            initialMockDate: '2026-03-27',
            // forceShowAdvisorCorpusSection deliberately omitted
            // advisorCorpusAdminService deliberately omitted
          ),
        ),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Advisor corpus', skipOffstage: false), findsNothing);
    });
  });
}

class _RecordingPasswordChangeGateway implements PasswordChangeGateway {
  _RecordingPasswordChangeGateway({this.error});

  final commands = <PasswordChangeCommand>[];
  final Object? error;

  @override
  Future<PasswordChangeCompleted> changePassword(
    PasswordChangeCommand command,
  ) async {
    commands.add(command);
    final error = this.error;
    if (error != null) throw error;
    return const PasswordChangeCompleted();
  }
}

class _FixedAccountInfoGateway implements AccountInfoGateway {
  _FixedAccountInfoGateway({required this.info});

  final AccountInfo info;
  final requests = <AccountInfoRequest>[];

  @override
  Future<AccountInfo> load(AccountInfoRequest request) async {
    requests.add(request);
    return info;
  }
}

class _FailingAccountInfoGateway implements AccountInfoGateway {
  @override
  Future<AccountInfo> load(AccountInfoRequest request) async {
    throw StateError(
      'raw uuid 11111111-1111-4111-8111-111111111111 permission.key Firebase',
    );
  }
}

class _PendingAccountInfoGateway implements AccountInfoGateway {
  final _completer = Completer<AccountInfo>();
  final requests = <AccountInfoRequest>[];

  void complete(AccountInfo info) {
    if (!_completer.isCompleted) _completer.complete(info);
  }

  @override
  Future<AccountInfo> load(AccountInfoRequest request) {
    requests.add(request);
    return _completer.future;
  }
}

class _CompletingAuthLoginService implements AuthLoginService {
  final Completer<void> _signOutAllCompleter = Completer<void>();

  void completeSignOutAll() {
    if (!_signOutAllCompleter.isCompleted) {
      _signOutAllCompleter.complete();
    }
  }

  @override
  Future<AuthLoginResult> signInWithEmailPassword({
    required String email,
    required String password,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<AuthLoginResult> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> requestPasswordReset({required String email}) {
    throw UnimplementedError();
  }

  @override
  Future<AuthSession?> refreshSession(AuthSession current) {
    throw UnimplementedError();
  }

  @override
  Future<void> signOutThisSession() async {}

  @override
  Future<void> signOutAllSessions() => _signOutAllCompleter.future;
}
