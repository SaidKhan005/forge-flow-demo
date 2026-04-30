// Phase 9.UX.1 - Settings MFA widget tests.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/screens/settings/settings_mfa_section.dart';
import 'package:forge_and_flow/screens/settings_screen.dart';
import 'package:forge_and_flow/services/auth_login_service.dart';
import 'package:forge_and_flow/services/secure_session_storage.dart';
import 'package:forge_and_flow/state/auth_session_notifier.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('fails closed when no MFA gateway is configured', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: _testTheme,
        home: const Scaffold(
          body: SingleChildScrollView(child: SettingsMfaSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'MFA ERROR: MFA operations are not configured for this runtime.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('mfa_enroll_totp_button')), findsNothing);
  });

  testWidgets(
    'demo enrollment shows QR, copy values, recovery codes, and factor',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _testTheme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: SettingsMfaSection(
                gateway: DemoMfaOperationsGateway(),
                actor: kDemoMfaActorContext,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Checking status...'), findsNothing);
      expect(find.text('No authenticator app enrolled.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('mfa_enroll_totp_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('mfa_qr_code')), findsOneWidget);
      expect(
        find.byKey(const Key('mfa_copy_otpauth_url_button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('mfa_copy_secret_button')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('mfa_one_time_code_field')),
        '123456',
      );
      await tester.ensureVisible(
        find.byKey(const Key('mfa_confirm_enrollment_button')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('mfa_confirm_enrollment_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('mfa_recovery_codes_row')), findsOneWidget);
      expect(
        find.byKey(const Key('mfa_copy_recovery_codes_button')),
        findsOneWidget,
      );
      expect(find.text('Authenticator app'), findsOneWidget);
      expect(find.textContaining('Not used yet'), findsOneWidget);
    },
  );

  testWidgets('Account tab exposes MFA for a signed-in non-admin user', (
    tester,
  ) async {
    final notifier = AuthSessionNotifier(
      loginService: const ScaffoldFailingAuthLoginService(),
      storage: InMemorySecureSessionStorage(),
    )..debugSetSession(_nonAdminSession());

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthSessionNotifier>.value(
        value: notifier,
        child: MaterialApp(
          theme: _testTheme,
          home: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            initialMockDate: '2026-03-27',
            mfaOperationsGateway: DemoMfaOperationsGateway(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settings_tab_account')));
    await tester.pumpAndSettle();

    expect(find.text('MFA', skipOffstage: false), findsOneWidget);
    expect(
      find.byKey(const Key('settings_mfa_section'), skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settings_tab_team')), findsNothing);
  });
}

final ThemeData _testTheme = ThemeData(splashFactory: NoSplash.splashFactory);

AuthSession _nonAdminSession() {
  final now = DateTime.utc(2026, 4, 30, 12);
  return AuthSession(
    userId: 'newfoundland-user-id',
    operatorId: 'operator-id',
    locationId: 'location-id',
    firebaseIdToken: 'id-token',
    issuedAt: now,
    expiresAt: now.add(const Duration(hours: 1)),
    lastFreshAuthAt: now,
    roles: const <String>['staff'],
    mfaEnrolled: false,
  );
}
