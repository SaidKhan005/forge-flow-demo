// Phase 9.UX.1 - Settings MFA widget tests.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/screens/settings/settings_mfa_section.dart';
import 'package:forge_and_flow/screens/settings_screen.dart';
import 'package:forge_and_flow/services/auth_login_service.dart';
import 'package:forge_and_flow/services/mfa/mfa_enrollment_service.dart';
import 'package:forge_and_flow/services/mfa/mfa_operations_gateway.dart';
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
        'Two-factor issue: MFA operations are not configured for this runtime.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('mfa_enroll_totp_button')), findsNothing);
  });

  testWidgets('hides add authenticator while status is checking', (
    tester,
  ) async {
    final gateway = _SlowListGateway();

    await tester.pumpWidget(
      MaterialApp(
        theme: _testTheme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SettingsMfaSection(
              gateway: gateway,
              actor: kDemoMfaActorContext,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('mfa_factors_loading')), findsOneWidget);
    expect(find.byKey(const Key('mfa_enroll_totp_button')), findsNothing);

    gateway.complete();
    await tester.pumpAndSettle();

    expect(find.text('No authenticator app enrolled.'), findsOneWidget);
    expect(find.byKey(const Key('mfa_enroll_totp_button')), findsOneWidget);
  });

  testWidgets('failed MFA status load can be retried in place', (tester) async {
    final gateway = _FlakyListGateway();

    await tester.pumpWidget(
      MaterialApp(
        theme: _testTheme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SettingsMfaSection(
              gateway: gateway,
              actor: kDemoMfaActorContext,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not reach MFA settings'), findsOneWidget);
    expect(find.byKey(const Key('mfa_retry_button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('mfa_retry_button')));
    await tester.pumpAndSettle();

    expect(gateway.listCalls, equals(2));
    expect(find.text('No authenticator app enrolled.'), findsOneWidget);
    expect(find.byKey(const Key('mfa_enroll_totp_button')), findsOneWidget);
  });

  testWidgets('refreshGeneration reloads factor status', (tester) async {
    final gateway = _RecordingMfaGateway();

    Widget build(int generation) {
      return MaterialApp(
        theme: _testTheme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SettingsMfaSection(
              gateway: gateway,
              actor: kDemoMfaActorContext,
              refreshGeneration: generation,
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(build(0));
    await tester.pumpAndSettle();
    expect(gateway.listCalls, hasLength(1));

    await tester.pumpWidget(build(1));
    await tester.pumpAndSettle();
    expect(gateway.listCalls, hasLength(2));
  });

  testWidgets('equal actor rebuild does not reload factor status', (
    tester,
  ) async {
    final gateway = _RecordingMfaGateway();

    Widget build() {
      return MaterialApp(
        theme: _testTheme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SettingsMfaSection(
              gateway: gateway,
              actor: const MfaActorContext(
                actorUserId: 'demo-actor-user-id',
                operatorId: 'demo-operator-id',
                locationId: 'demo-location-id',
                userEmail: 'demo.operator@forgeflow.test',
              ),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    expect(gateway.listCalls, hasLength(1));

    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    expect(gateway.listCalls, hasLength(1));
  });

  testWidgets('demo enrollment shows QR, copy values, and factor', (
    tester,
  ) async {
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

    expect(find.byKey(const Key('mfa_recovery_codes_row')), findsNothing);
    expect(
      find.text(
        'Two-factor update: Authenticator app added. If you lose access, ask your restaurant admin to reset MFA.',
      ),
      findsOneWidget,
    );
    expect(find.text('Authenticator app'), findsOneWidget);
    expect(find.textContaining('Not used yet'), findsOneWidget);
  });

  testWidgets('remove MFA explains the 24-hour security window', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: _testTheme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SettingsMfaSection(
              gateway: _PendingRemovalGateway(),
              actor: kDemoMfaActorContext,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('mfa_revoke_button_totp-db-factor')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('will be removed after May 1, 2026'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Check back after the security window to confirm it is done.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Removal pending'), findsWidgets);
    expect(
      find.byKey(const Key('mfa_revoke_button_totp-db-factor')),
      findsNothing,
    );
    expect(find.widgetWithText(TextButton, 'Cancel removal'), findsOneWidget);
  });

  testWidgets('pending MFA removal can be cancelled', (tester) async {
    final gateway = _PendingRemovalGateway();

    await tester.pumpWidget(
      MaterialApp(
        theme: _testTheme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SettingsMfaSection(
              gateway: gateway,
              actor: kDemoMfaActorContext,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('mfa_revoke_button_totp-db-factor')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('mfa_cancel_removal_button_totp-db-factor')),
    );
    await tester.pumpAndSettle();

    expect(
      gateway.cancelCommands.single.requestId,
      equals('removal-request-1'),
    );
    expect(
      find.textContaining('Authenticator app removal cancelled.'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('mfa_revoke_button_totp-db-factor')),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(TextButton, 'Remove authenticator app'),
      findsOneWidget,
    );
  });

  testWidgets('stale auth action returns to sign-in without a widget error', (
    tester,
  ) async {
    final loginService = _RecordingAuthLoginService();
    final notifier = AuthSessionNotifier(
      loginService: loginService,
      storage: InMemorySecureSessionStorage(),
    )..debugSetSession(_nonAdminSession());

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthSessionNotifier>.value(
        value: notifier,
        child: MaterialApp(
          theme: _testTheme,
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: Center(
                  child: FilledButton(
                    key: const Key('open_mfa_settings_button'),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const Scaffold(
                            body: SingleChildScrollView(
                              child: SettingsMfaSection(
                                gateway: _FreshnessRequiredGateway(),
                                actor: kDemoMfaActorContext,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                    child: const Text('Open MFA settings'),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('open_mfa_settings_button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('mfa_revoke_button_totp-db-factor')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Security check required'), findsOneWidget);
    expect(find.byKey(const Key('mfa_sign_in_again_button')), findsOneWidget);
    expect(find.text('Sign in again'), findsOneWidget);

    await tester.tap(find.byKey(const Key('mfa_sign_in_again_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('open_mfa_settings_button')), findsOneWidget);
    expect(find.byKey(const Key('settings_mfa_section')), findsNothing);
    expect(loginService.signOutThisSessionCalls, equals(1));
    expect(notifier.state, isA<AuthSessionUnauthenticated>());
    expect(tester.takeException(), isNull);
  });

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

    expect(
      find.byKey(const Key('mfa_header'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settings_mfa_section'), skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byKey(const Key('settings_tab_team')), findsNothing);
  });
}

class _SlowListGateway implements MfaOperationsGateway {
  final Completer<MfaListFactorsCompleted> _listCompleter =
      Completer<MfaListFactorsCompleted>();

  void complete() {
    _listCompleter.complete(
      const MfaListFactorsCompleted(factors: <MfaFactorSummary>[]),
    );
  }

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment(MfaTotpBeginCommand command) {
    throw UnimplementedError();
  }

  @override
  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<MfaListFactorsCompleted> listFactors(MfaListFactorsCommand command) {
    return _listCompleter.future;
  }

  @override
  Future<MfaRevokeFactorCompleted> revokeFactor(
    MfaRevokeFactorCommand command,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<MfaCancelFactorRemovalCompleted> cancelFactorRemoval(
    MfaCancelFactorRemovalCommand command,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<MfaRevokeUserFactorsCompleted> revokeUserFactors(
    MfaRevokeUserFactorsCommand command,
  ) {
    throw UnimplementedError();
  }
}

class _FlakyListGateway implements MfaOperationsGateway {
  int listCalls = 0;

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment(MfaTotpBeginCommand command) {
    throw UnimplementedError();
  }

  @override
  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<MfaListFactorsCompleted> listFactors(
    MfaListFactorsCommand command,
  ) async {
    listCalls += 1;
    if (listCalls == 1) {
      throw const MfaOperationRejected(
        code: 'mfa_proxy_timeout',
        message: 'Could not reach MFA settings. Check connection and retry.',
        statusCode: 503,
      );
    }
    return const MfaListFactorsCompleted(factors: <MfaFactorSummary>[]);
  }

  @override
  Future<MfaRevokeFactorCompleted> revokeFactor(
    MfaRevokeFactorCommand command,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<MfaCancelFactorRemovalCompleted> cancelFactorRemoval(
    MfaCancelFactorRemovalCommand command,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<MfaRevokeUserFactorsCompleted> revokeUserFactors(
    MfaRevokeUserFactorsCommand command,
  ) {
    throw UnimplementedError();
  }
}

class _RecordingMfaGateway implements MfaOperationsGateway {
  final List<MfaListFactorsCommand> listCalls = <MfaListFactorsCommand>[];

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment(MfaTotpBeginCommand command) {
    throw UnimplementedError();
  }

  @override
  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<MfaListFactorsCompleted> listFactors(
    MfaListFactorsCommand command,
  ) async {
    listCalls.add(command);
    return const MfaListFactorsCompleted(factors: <MfaFactorSummary>[]);
  }

  @override
  Future<MfaRevokeFactorCompleted> revokeFactor(
    MfaRevokeFactorCommand command,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<MfaCancelFactorRemovalCompleted> cancelFactorRemoval(
    MfaCancelFactorRemovalCommand command,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<MfaRevokeUserFactorsCompleted> revokeUserFactors(
    MfaRevokeUserFactorsCommand command,
  ) {
    throw UnimplementedError();
  }
}

class _FreshnessRequiredGateway implements MfaOperationsGateway {
  const _FreshnessRequiredGateway();

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment(MfaTotpBeginCommand command) {
    throw UnimplementedError();
  }

  @override
  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<MfaListFactorsCompleted> listFactors(
    MfaListFactorsCommand command,
  ) async {
    return MfaListFactorsCompleted(
      factors: <MfaFactorSummary>[
        MfaFactorSummary(
          factorId: 'totp-db-factor',
          factorType: 'totp',
          enrolledAt: DateTime.utc(2026, 4, 30),
          issuerLabel: 'Forge & Flow',
        ),
      ],
    );
  }

  @override
  Future<MfaRevokeFactorCompleted> revokeFactor(
    MfaRevokeFactorCommand command,
  ) async {
    throw const MfaOperationRejected(
      code: 'mfa_freshness_required',
      message: 'Sign in again before removing MFA.',
    );
  }

  @override
  Future<MfaCancelFactorRemovalCompleted> cancelFactorRemoval(
    MfaCancelFactorRemovalCommand command,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<MfaRevokeUserFactorsCompleted> revokeUserFactors(
    MfaRevokeUserFactorsCommand command,
  ) {
    throw UnimplementedError();
  }
}

class _PendingRemovalGateway implements MfaOperationsGateway {
  final cancelCommands = <MfaCancelFactorRemovalCommand>[];
  bool _removalPending = false;

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment(MfaTotpBeginCommand command) {
    throw UnimplementedError();
  }

  @override
  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<MfaListFactorsCompleted> listFactors(
    MfaListFactorsCommand command,
  ) async {
    return MfaListFactorsCompleted(
      factors: <MfaFactorSummary>[
        MfaFactorSummary(
          factorId: 'totp-db-factor',
          factorType: 'totp',
          enrolledAt: DateTime.utc(2026, 4, 30),
          issuerLabel: 'Forge & Flow',
        ),
      ],
      removalRequests: _removalPending
          ? <MfaRemovalRequestSummary>[
              MfaRemovalRequestSummary(
                requestId: 'removal-request-1',
                factorId: 'totp-db-factor',
                status: 'pending',
                executeAfter: DateTime.utc(2026, 5, 1),
              ),
            ]
          : const <MfaRemovalRequestSummary>[],
    );
  }

  @override
  Future<MfaRevokeFactorCompleted> revokeFactor(
    MfaRevokeFactorCommand command,
  ) async {
    _removalPending = true;
    return MfaRevokeFactorCompleted(
      revoked: false,
      requestId: 'removal-request-1',
      executeAfter: DateTime.utc(2026, 5, 1),
    );
  }

  @override
  Future<MfaCancelFactorRemovalCompleted> cancelFactorRemoval(
    MfaCancelFactorRemovalCommand command,
  ) async {
    cancelCommands.add(command);
    _removalPending = false;
    return const MfaCancelFactorRemovalCompleted(cancelled: true);
  }

  @override
  Future<MfaRevokeUserFactorsCompleted> revokeUserFactors(
    MfaRevokeUserFactorsCommand command,
  ) {
    throw UnimplementedError();
  }
}

class _RecordingAuthLoginService implements AuthLoginService {
  int signOutThisSessionCalls = 0;

  @override
  Future<AuthLoginResult> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async {
    return const AuthLoginFailure(
      code: 'unconfigured',
      message: 'test login service',
    );
  }

  @override
  Future<void> requestPasswordReset({required String email}) async {}

  @override
  Future<AuthSession?> refreshSession(AuthSession current) async => current;

  @override
  Future<AuthLoginResult> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    return const AuthLoginFailure(
      code: 'unconfigured',
      message: 'test login service',
    );
  }

  @override
  Future<void> signOutAllSessions() async {}

  @override
  Future<void> signOutThisSession() async {
    signOutThisSessionCalls += 1;
  }
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
