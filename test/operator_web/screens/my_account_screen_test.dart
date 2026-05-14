// Phase 11W.7 / Wave B9.2 - My account screen widget tests.
//
// Covers the B9.2 card order (Profile, Security, MFA, Active Sessions),
// desktop/tablet breakpoints, role gates for security writes, audit-log links,
// and the self-service active-session controls.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/account/operator_web_account_actions.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/my_account_screen.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_team_gateway_providers.dart';
import 'package:forge_and_flow/operator_web/services/web_account_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_security_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  Future<void> sizeViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> pumpAccount(
    WidgetTester tester,
    OperatorWebSession session, {
    OperatorWebAccountActions? actions,
    WebSecurityGateway? securityGateway,
    DateTime Function()? now,
  }) async {
    await tester.pumpWidget(
      wrap(
        MyAccountScreen(
          session: session,
          actions: actions,
          securityGateway: securityGateway,
          now: now,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  OperatorWebSession sessionWithRole(
    String role, {
    bool mfaEnrolled = false,
    String? phone,
  }) => OperatorWebSession(
    uid: 'demo-uid-$role',
    email: 'alex@brio-restaurants.com',
    displayName: 'Alex Morrison',
    operatorId: 'demo-operator',
    businessName: 'Brio Restaurants',
    primaryLocationId: 'demo-location',
    primaryLocationName: 'Brio Main Street',
    roles: <String>[role],
    mfaEnrolled: mfaEnrolled,
    phone: phone,
  );

  group('MyAccountScreen layout', () {
    testWidgets('renders B9.2 cards in order at desktop 1024x768', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await pumpAccount(tester, session);

      final profile = find.byKey(const Key('account_section_profile'));
      final security = find.byKey(const Key('account_section_security'));
      final mfa = find.byKey(const Key('account_section_mfa'));
      final active = find.byKey(const Key('account_section_active_sessions'));
      expect(
        find.byKey(const Key('operator_web_account_screen')),
        findsOneWidget,
      );
      expect(profile, findsOneWidget);
      expect(security, findsOneWidget);
      expect(mfa, findsOneWidget);
      expect(active, findsOneWidget);
      expect(find.byKey(const Key('account_section_tos')), findsNothing);
      expect(
        tester.getTopLeft(profile).dy < tester.getTopLeft(security).dy,
        isTrue,
      );
      expect(
        tester.getTopLeft(security).dy < tester.getTopLeft(mfa).dy,
        isTrue,
      );
      expect(tester.getTopLeft(mfa).dy < tester.getTopLeft(active).dy, isTrue);
    });

    testWidgets('renders B9.2 cards at tablet 768x1024', (tester) async {
      await sizeViewport(tester, const Size(768, 1024));
      final session = sessionWithRole('operator_owner');

      await pumpAccount(tester, session);

      expect(find.byKey(const Key('account_section_profile')), findsOneWidget);
      expect(find.byKey(const Key('account_section_security')), findsOneWidget);
      expect(find.byKey(const Key('account_section_mfa')), findsOneWidget);
      expect(
        find.byKey(const Key('account_section_active_sessions')),
        findsOneWidget,
      );
    });

    testWidgets('Profile two-column flips to single-column at tablet width', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await pumpAccount(tester, session);

      expect(
        find.byKey(const Key('account_section_profile_two_column')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('account_section_profile_single_column')),
        findsNothing,
      );

      await sizeViewport(tester, const Size(768, 1024));
      await pumpAccount(tester, session);

      expect(
        find.byKey(const Key('account_section_profile_single_column')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('account_section_profile_two_column')),
        findsNothing,
      );
    });

    testWidgets('Profile section renders identity values from the session', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole(
        'operator_owner',
        phone: '+1 (555) 010-2580',
      );

      await pumpAccount(tester, session);

      expect(find.text('Alex Morrison'), findsOneWidget);
      expect(find.text('alex@brio-restaurants.com'), findsOneWidget);
      expect(find.text('Brio Restaurants'), findsOneWidget);
      expect(find.text('+1 (555) 010-2580'), findsOneWidget);
    });

    testWidgets(
      'Profile section falls back to "Not on file" when phone absent',
      (tester) async {
        await sizeViewport(tester, const Size(1024, 768));
        final session = sessionWithRole('operator_owner');

        await pumpAccount(tester, session);

        expect(find.text('Not on file'), findsOneWidget);
      },
    );

    testWidgets('Profile section is read-only and every card links audit log', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await pumpAccount(tester, session);

      expect(
        find.descendant(
          of: find.byKey(const Key('account_section_profile')),
          matching: find.byType(TextField),
        ),
        findsNothing,
      );
      expect(
        find.byKey(const Key('account_section_profile_audit_log_link')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('account_section_security_audit_log_link')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('account_section_mfa_audit_log_link')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('account_section_active_sessions_audit_log_link')),
        findsOneWidget,
      );
    });
  });

  group('MyAccountScreen MFA section', () {
    testWidgets('starts on Not enrolled with the Enroll CTA visible', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await pumpAccount(tester, session);

      expect(find.text('Two-factor sign-in: Off'), findsOneWidget);
      expect(
        find.byKey(const Key('account_section_mfa_enroll')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('account_section_mfa_view_backup_codes')),
        findsNothing,
      );
    });

    testWidgets('renders the adaptive R1 MFA labels', (tester) async {
      await sizeViewport(tester, const Size(1024, 900));

      await pumpAccount(tester, sessionWithRole('operator_owner'));
      expect(find.text('Enable two-factor sign-in'), findsOneWidget);

      final session = sessionWithRole('operator_owner', mfaEnrolled: true);
      await pumpAccount(tester, session, actions: _FakeMfaAccountActions());
      expect(find.text('View recovery codes'), findsOneWidget);

      await pumpAccount(
        tester,
        session,
        actions: _FakeMfaAccountActions(recoveryCodesViewed: true),
      );
      expect(find.text('Add another method'), findsOneWidget);

      await pumpAccount(
        tester,
        session,
        actions: _FakeMfaAccountActions(
          recoveryCodesViewed: true,
          factorCount: 2,
        ),
      );
      expect(find.text('Manage two-factor sign-in'), findsOneWidget);
    });

    testWidgets('Enroll -> confirm 123456 -> badge flips to Enrolled', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await pumpAccount(tester, session);

      await tester.ensureVisible(
        find.byKey(const Key('account_section_mfa_enroll')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account_section_mfa_enroll')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('mfa_enroll_dialog_code_field')),
        '123456',
      );
      await tester.tap(find.byKey(const Key('mfa_enroll_dialog_confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('mfa_enroll_dialog')), findsNothing);
      expect(find.text('Two-factor sign-in: Enabled'), findsOneWidget);
      expect(find.text('View recovery codes'), findsOneWidget);
    });

    testWidgets('Wrong code surfaces remediation copy without flipping badge', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await pumpAccount(tester, session);

      await tester.ensureVisible(
        find.byKey(const Key('account_section_mfa_enroll')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account_section_mfa_enroll')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('mfa_enroll_dialog_code_field')),
        '000000',
      );
      await tester.tap(find.byKey(const Key('mfa_enroll_dialog_confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('mfa_enroll_dialog')), findsOneWidget);
      expect(find.textContaining('did not match'), findsOneWidget);
      await tester.tap(find.byKey(const Key('mfa_enroll_dialog_cancel')));
      await tester.pumpAndSettle();
      expect(find.text('Two-factor sign-in: Off'), findsOneWidget);
    });

    testWidgets('Manage methods can request and cancel 24-hour removal', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 900));
      final session = sessionWithRole('operator_owner', mfaEnrolled: true);
      final actions = _FakeMfaAccountActions(
        now: () => DateTime.now().toUtc(),
        recoveryCodesViewed: true,
      );

      await pumpAccount(tester, session, actions: actions);

      await tester.ensureVisible(
        find.byKey(const Key('account_section_mfa_add_method')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account_section_mfa_add_method')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account_section_mfa_turn_off')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('account_section_mfa_request_removal_confirm')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Two-factor sign-in: Removal pending'), findsOneWidget);
      expect(
        find.byKey(const Key('account_section_mfa_cancel_removal')),
        findsOneWidget,
      );
      expect(actions.stepUpLabels, contains('removing two-factor sign-in'));

      await tester.tap(
        find.byKey(const Key('account_section_mfa_cancel_removal')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Two-factor sign-in: Enabled'), findsOneWidget);
      expect(
        find.byKey(const Key('account_section_mfa_add_method')),
        findsOneWidget,
      );
      expect(
        actions.stepUpLabels,
        contains('cancelling two-factor sign-in removal'),
      );
    });

    testWidgets('View recovery codes is available without write access', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 900));
      final session = sessionWithRole('location_manager', mfaEnrolled: true);
      final actions = _FakeMfaAccountActions();

      await pumpAccount(tester, session, actions: actions);

      await tester.ensureVisible(
        find.byKey(const Key('account_section_mfa_view_recovery_codes')),
      );
      await tester.pumpAndSettle();
      final viewCodes = tester.widget<OutlinedButton>(
        find.byKey(const Key('account_section_mfa_view_recovery_codes')),
      );
      expect(viewCodes.onPressed, isNotNull);

      await tester.tap(
        find.byKey(const Key('account_section_mfa_view_recovery_codes')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('mfa_backup_codes_dialog')), findsOneWidget);
      expect(actions.securityGateway.recoveryCodesViewedCalls, equals(1));

      await tester.tap(find.byKey(const Key('mfa_backup_codes_dialog_close')));
      await tester.pumpAndSettle();
      expect(find.text('Add another method'), findsOneWidget);
    });

    testWidgets('Removable turns off after step-up when server drops factor', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 900));
      var now = DateTime.utc(2026, 5, 6, 12);
      final session = sessionWithRole('operator_owner', mfaEnrolled: true);
      final actions = _FakeMfaAccountActions(
        now: () => now,
        recoveryCodesViewed: true,
      );

      await pumpAccount(tester, session, actions: actions);

      await tester.ensureVisible(
        find.byKey(const Key('account_section_mfa_add_method')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account_section_mfa_add_method')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account_section_mfa_turn_off')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('account_section_mfa_request_removal_confirm')),
      );
      await tester.pumpAndSettle();

      now = now.add(const Duration(hours: 24, minutes: 1));
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();

      expect(find.text('Two-factor sign-in: Ready to turn off'), findsOneWidget);
      expect(
        find.byKey(const Key('account_section_mfa_turn_off_final')),
        findsOneWidget,
      );

      actions.securityGateway.completeDueRemovals();
      await tester.tap(
        find.byKey(const Key('account_section_mfa_turn_off_final')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Two-factor sign-in: Off'), findsOneWidget);
      expect(
        actions.stepUpLabels,
        contains('turning off two-factor sign-in'),
      );
    });
  });

  group('MyAccountScreen Security section', () {
    testWidgets('Change password opens a 3-field modal', (tester) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await pumpAccount(tester, session);

      await tester.ensureVisible(
        find.byKey(const Key('account_section_password_change')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('account_section_password_change')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('change_password_dialog')), findsOneWidget);
      expect(
        find.byKey(const Key('change_password_dialog_current')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('change_password_dialog_new')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('change_password_dialog_confirm')),
        findsOneWidget,
      );
    });

    testWidgets(
      'Submitting a valid password closes the modal and shows toast',
      (tester) async {
        await sizeViewport(tester, const Size(1024, 768));
        final session = sessionWithRole('operator_owner');

        await pumpAccount(tester, session);

        await tester.ensureVisible(
          find.byKey(const Key('account_section_password_change')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('account_section_password_change')),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('change_password_dialog_current')),
          'old-password-123',
        );
        await tester.enterText(
          find.byKey(const Key('change_password_dialog_new')),
          'new-password-12345',
        );
        await tester.enterText(
          find.byKey(const Key('change_password_dialog_confirm')),
          'new-password-12345',
        );
        await tester.tap(
          find.byKey(const Key('change_password_dialog_submit')),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('change_password_dialog')), findsNothing);
        expect(
          find.byKey(const Key('account_section_password_toast')),
          findsOneWidget,
        );
        expect(find.text('Password updated'), findsOneWidget);
      },
    );

    testWidgets('Recent sign-in activity filters locally by window', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 1100));
      final session = sessionWithRole('operator_owner');
      final gateway = _FakeSecurityGateway(() => DateTime.utc(2026, 5, 6, 12));

      await pumpAccount(
        tester,
        session,
        securityGateway: gateway,
        now: () => DateTime.utc(2026, 5, 6, 12),
      );

      expect(
        find.byKey(const Key('operator_web_security_login_history_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('operator_web_security_login_history_row_history-recent'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('operator_web_security_login_history_row_history-april'),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(
          const Key('operator_web_security_login_history_filter_last_7'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const Key('operator_web_security_login_history_row_history-recent'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('operator_web_security_login_history_row_history-april'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key('operator_web_security_login_history_row_history-march'),
        ),
        findsNothing,
      );
    });
  });

  group('MyAccountScreen Active Sessions section', () {
    testWidgets('marks the current session as This device', (tester) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');
      final actions = _FakeAccountActions();

      await pumpAccount(tester, session, actions: actions);

      expect(find.text('This device'), findsOneWidget);
      expect(
        find.byKey(
          const Key('account_active_sessions_this_device_session-current'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('account_active_sessions_row_session-ipad')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('account_active_sessions_sign_out_others')),
        findsOneWidget,
      );
    });

    testWidgets('Sign out all other sessions revokes only non-current rows', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');
      final actions = _FakeAccountActions();

      await pumpAccount(tester, session, actions: actions);

      await tester.ensureVisible(
        find.byKey(const Key('account_active_sessions_sign_out_others')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('account_active_sessions_sign_out_others')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('account_active_sessions_confirm_submit')),
      );
      await tester.pumpAndSettle();

      expect(actions.signOutCalls, hasLength(1));
      expect(
        actions.signOutCalls.single,
        unorderedEquals(<String>['session-ipad', 'session-chrome']),
      );
      expect(
        find.byKey(const Key('account_active_sessions_row_session-current')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('account_active_sessions_row_session-ipad')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('account_active_sessions_row_session-chrome')),
        findsNothing,
      );
    });

    testWidgets('Sign out CTA is disabled when only this device is active', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');
      final actions = _FakeAccountActions(
        sessions: <AccountActiveSessionEntry>[
          _sessionEntry('session-current', 'Safari on Mac'),
        ],
      );

      await pumpAccount(tester, session, actions: actions);

      final button = tester.widget<OutlinedButton>(
        find.byKey(const Key('account_active_sessions_sign_out_others')),
      );
      expect(button.onPressed, isNull);
      expect(find.text('This device'), findsOneWidget);
    });
  });

  group('MyAccountScreen permission gate', () {
    testWidgets('operator_owner sees enabled MFA + Security CTAs', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final session = sessionWithRole('operator_owner');

      await pumpAccount(tester, session);

      final enroll = tester.widget<OutlinedButton>(
        find.byKey(const Key('account_section_mfa_enroll')),
      );
      final pwd = tester.widget<OutlinedButton>(
        find.byKey(const Key('account_section_password_change')),
      );
      expect(enroll.onPressed, isNotNull);
      expect(pwd.onPressed, isNotNull);
    });

    testWidgets(
      'location_manager sees Profile + Active Sessions but security writes disabled',
      (tester) async {
        await sizeViewport(tester, const Size(1024, 768));
        final session = sessionWithRole('location_manager');
        final actions = _FakeAccountActions();

        await pumpAccount(tester, session, actions: actions);

        expect(
          find.byKey(const Key('account_section_profile')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('account_section_active_sessions')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('account_section_tos')), findsNothing);

        final enroll = tester.widget<OutlinedButton>(
          find.byKey(const Key('account_section_mfa_enroll')),
        );
        final pwd = tester.widget<OutlinedButton>(
          find.byKey(const Key('account_section_password_change')),
        );
        final sessions = tester.widget<OutlinedButton>(
          find.byKey(const Key('account_active_sessions_sign_out_others')),
        );
        expect(enroll.onPressed, isNull);
        expect(pwd.onPressed, isNull);
        expect(sessions.onPressed, isNotNull);
      },
    );

    testWidgets('demo location_manager factory lands on the read-only branch', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1024, 768));
      final source = DemoOperatorWebAuthSource.completedAsLocationManager();
      addTearDown(source.dispose);
      final completed = source.current as OperatorWebCompleted;

      await pumpAccount(tester, completed.session);

      final enroll = tester.widget<OutlinedButton>(
        find.byKey(const Key('account_section_mfa_enroll')),
      );
      expect(enroll.onPressed, isNull);
      expect(completed.session.roles, contains('location_manager'));
    });
  });
}

class _FakeAccountActions implements OperatorWebAccountActions {
  _FakeAccountActions({List<AccountActiveSessionEntry>? sessions})
    : _sessions = List<AccountActiveSessionEntry>.of(
        sessions ?? _defaultSessions,
      );

  @override
  String? get currentAccountSessionId => 'session-current';

  final List<AccountActiveSessionEntry> _sessions;
  final List<List<String>> signOutCalls = <List<String>>[];

  @override
  Future<MfaEnrollmentArtifact> beginAccountMfaEnrollment({
    required String email,
  }) async {
    return const MfaEnrollmentArtifact(
      enrollmentId: 'enroll-1',
      factorType: MfaFactorType.totp,
      totpSharedSecret: 'JBSWY3DPEHPK3PXP',
      totpQrUri: 'otpauth://totp/Forge%20%26%20Flow:test',
    );
  }

  @override
  Future<void> confirmAccountMfaEnrollment({
    required String enrollmentId,
    required String oneTimeCode,
  }) async {}

  @override
  Future<void> changeAccountPassword({
    required String currentPassword,
    required String newPassword,
  }) async {}

  @override
  Future<AccountActiveSessionsListed> listAccountActiveSessions() async {
    return AccountActiveSessionsListed(
      sessions: List<AccountActiveSessionEntry>.unmodifiable(_sessions),
    );
  }

  @override
  Future<AccountSessionSignOutOthersResult> signOutOtherAccountSessions({
    required Iterable<String> sessionIds,
  }) async {
    final ids = sessionIds.toList(growable: false);
    signOutCalls.add(ids);
    _sessions.removeWhere((session) => ids.contains(session.sessionId));
    return AccountSessionSignOutOthersResult(revokedCount: ids.length);
  }

  @override
  Future<SelfProfilePatchResult?> patchSelfProfile({
    String? displayName,
    String? email,
  }) async {
    // Wave 2 W-3 — fake does not wire the
    // OperatorWebAccountGatewayProvider seam; the My Account widget
    // test suite covers only the read-only profile section here.
    // The dedicated W-3 dialog test
    // (`edit_self_profile_dialog_test.dart`) exercises the live path.
    return null;
  }

  static final List<AccountActiveSessionEntry> _defaultSessions =
      <AccountActiveSessionEntry>[
        _sessionEntry('session-current', 'Safari on Mac', city: 'Portland'),
        _sessionEntry('session-ipad', 'iPad app', city: 'Seattle'),
        _sessionEntry('session-chrome', 'Chrome on Windows', city: 'Boston'),
      ];
}

class _FakeMfaAccountActions extends _FakeAccountActions
    implements
        OperatorWebSecurityGatewayProvider,
        OperatorWebAccountMfaFreshnessGate {
  _FakeMfaAccountActions({
    DateTime Function()? now,
    bool recoveryCodesViewed = false,
    int factorCount = 1,
  }) : securityGateway = _FakeSecurityGateway(
         now ?? (() => DateTime.utc(2026, 5, 6, 12)),
         recoveryCodesViewed: recoveryCodesViewed,
         factorCount: factorCount,
       );

  @override
  final _FakeSecurityGateway securityGateway;

  final List<String> stepUpLabels = <String>[];

  @override
  Future<void> requireFreshMfaForAccountSecurity({
    required String actionLabel,
  }) async {
    stepUpLabels.add(actionLabel);
  }
}

class _FakeSecurityGateway implements WebSecurityGateway {
  _FakeSecurityGateway(
    DateTime Function() now, {
    bool recoveryCodesViewed = false,
    int factorCount = 1,
  }) : _now = now {
    for (var index = 0; index < factorCount; index += 1) {
      _factors.add(
        WebSecurityMfaFactor(
          factorId: 'totp-db-factor-${index + 1}',
          factorType: 'totp',
          enrolledAt: now().subtract(Duration(days: 7 - index)),
          recoveryCodesViewedAt: recoveryCodesViewed ? now() : null,
          issuerLabel: 'Forge & Flow',
        ),
      );
    }
  }

  final DateTime Function() _now;
  final List<WebSecurityMfaFactor> _factors = <WebSecurityMfaFactor>[];
  final List<WebSecurityMfaRemoval> _removals = <WebSecurityMfaRemoval>[];
  int recoveryCodesViewedCalls = 0;
  final List<WebSecurityLoginHistoryEntry> _history =
      <WebSecurityLoginHistoryEntry>[
        WebSecurityLoginHistoryEntry(
          eventId: 'history-recent',
          eventType: 'auth.signed_in',
          friendlyLabel: 'Signed in',
          occurredAt: DateTime.utc(2026, 5, 5, 11),
          deviceLabel: 'Chrome on Mac',
          geoCity: 'Portland',
          geoCountry: 'US',
        ),
        WebSecurityLoginHistoryEntry(
          eventId: 'history-april',
          eventType: 'auth.password_changed',
          friendlyLabel: 'Password changed',
          occurredAt: DateTime.utc(2026, 4, 10, 9),
          deviceLabel: 'Safari',
          geoCity: 'Seattle',
          geoCountry: 'US',
        ),
        WebSecurityLoginHistoryEntry(
          eventId: 'history-march',
          eventType: 'auth.session.revoked',
          friendlyLabel: 'Session signed out',
          occurredAt: DateTime.utc(2026, 3, 22, 17),
          deviceLabel: 'iPad app',
          geoCity: 'Boston',
          geoCountry: 'US',
        ),
      ];

  void completeDueRemovals() {
    final now = _now().toUtc();
    final dueFactorIds = _removals
        .where((removal) => !removal.executeAfter.isAfter(now))
        .map((removal) => removal.factorId)
        .toSet();
    _factors.removeWhere((factor) => dueFactorIds.contains(factor.factorId));
  }

  @override
  Future<WebSecurityFactorsListed> listFactors() async {
    return WebSecurityFactorsListed(
      factors: List<WebSecurityMfaFactor>.unmodifiable(_factors),
      removalRequests: List<WebSecurityMfaRemoval>.unmodifiable(_removals),
    );
  }

  @override
  Future<WebSecurityRevokeFactorResult> revokeFactor({
    required String factorId,
    required String idempotencyKey,
  }) async {
    final executeAfter = _now().toUtc().add(const Duration(hours: 24));
    final removal = WebSecurityMfaRemoval(
      requestId: 'removal-1',
      factorId: factorId,
      status: 'pending',
      executeAfter: executeAfter,
    );
    _removals.add(removal);
    return WebSecurityRevokeFactorResult(
      revoked: false,
      requestId: removal.requestId,
      executeAfter: executeAfter,
    );
  }

  @override
  Future<WebSecurityRecoveryCodesViewedResult> markRecoveryCodesViewed({
    required String factorId,
    required String idempotencyKey,
  }) async {
    recoveryCodesViewedCalls += 1;
    final index = _factors.indexWhere((factor) => factor.factorId == factorId);
    if (index == -1) {
      throw const WebSecurityError(
        code: 'mfa_factor_not_found',
        message: 'Authenticator was already removed or does not exist.',
        statusCode: 404,
      );
    }
    final factor = _factors[index];
    final viewedAt = factor.recoveryCodesViewedAt ?? _now().toUtc();
    _factors[index] = WebSecurityMfaFactor(
      factorId: factor.factorId,
      factorType: factor.factorType,
      enrolledAt: factor.enrolledAt,
      lastUsedAt: factor.lastUsedAt,
      recoveryCodesViewedAt: viewedAt,
      issuerLabel: factor.issuerLabel,
      canRevoke: factor.canRevoke,
    );
    return WebSecurityRecoveryCodesViewedResult(viewedAt: viewedAt);
  }

  @override
  Future<WebSecurityCancelRemovalResult> cancelFactorRemoval({
    required String requestId,
    required String idempotencyKey,
  }) async {
    _removals.removeWhere((removal) => removal.requestId == requestId);
    return const WebSecurityCancelRemovalResult(cancelled: true);
  }

  @override
  Future<WebSecurityTotpEnrollment> beginTotpEnrollment({
    required String userEmail,
    required String idempotencyKey,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<WebSecurityMfaFactor> confirmTotpEnrollment({
    required String factorId,
    required String oneTimeCode,
    required String idempotencyKey,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<WebSecurityPasswordChangeResult> changePassword({
    required String currentPassword,
    required String newPassword,
    required String idempotencyKey,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<WebSecurityLoginHistoryListed> listLoginHistory() async {
    return WebSecurityLoginHistoryListed(
      entries: List<WebSecurityLoginHistoryEntry>.unmodifiable(_history),
    );
  }

  @override
  Future<WebSecurityRecoveryRequestResult> requestMfaRecovery({
    required String email,
    String? reason,
    required String idempotencyKey,
  }) {
    throw UnimplementedError();
  }
}

AccountActiveSessionEntry _sessionEntry(
  String id,
  String device, {
  String city = 'Portland',
}) {
  return AccountActiveSessionEntry(
    sessionId: id,
    deviceLabel: device,
    deviceFingerprint: 'fp-$id',
    userAgent: 'ForgeFlowTest/1.0',
    geoCity: city,
    geoCountry: 'US',
    createdAt: DateTime.utc(2026, 5, 1, 12),
    lastActiveAt: DateTime.utc(2026, 5, 6, 18),
  );
}
