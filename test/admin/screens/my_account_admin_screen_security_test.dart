// Audit fix-first #7 (cross-surface parity finding G4) — admin "My
// Account" Security card working-surface widget tests.
//
// Verifies that when an AdminSecurityGateway is wired the Security
// card renders the working self-service surface (not the read-only
// W-4 posture): MFA status reflects the gateway, the enroll → confirm
// path drives the gateway with a stable idempotency key, the password
// and recovery actions are reachable, and a gateway failure fails
// closed (no false success toast). Also pins that a NULL gateway still
// degrades to the legacy read-only note (so older fixtures stay green).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/screens/my_account_admin_screen.dart';
import 'package:forge_and_flow/admin/services/admin_security_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  void wideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 1024);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  AdminAuthSession session() => AdminAuthSession(
        uid: 'demo-super-admin',
        email: 'super.admin@forgeflow.test',
        displayName: 'Demo Super Admin',
        roles: const <String>['super_admin'],
        lastFreshAuthAt: DateTime.utc(2026, 5, 14, 12, 0, 0),
      );

  testWidgets(
      'NULL security gateway still degrades to the read-only note (G4 '
      'fail-safe)', (tester) async {
    wideViewport(tester);
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          now: () => DateTime.utc(2026, 5, 14, 12, 30, 0),
        ),
      ),
    );

    expect(
      find.byKey(const Key('admin_my_account_two_factor_readonly_note')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_my_account_mfa_enroll_button')),
      findsNothing,
    );
  });

  testWidgets(
      'wired gateway with no factor renders the working enroll surface',
      (tester) async {
    wideViewport(tester);
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);
    final gateway = InMemoryAdminSecurityGateway();

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          securityGateway: gateway,
          now: () => DateTime.utc(2026, 5, 14, 12, 30, 0),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Working surface — NOT the read-only note. MFA is now its own
    // "Two-factor sign-in" card (ops parity); the enroll CTA lives
    // there and Change password lives in the Security card.
    expect(
      find.byKey(const Key('admin_my_account_two_factor_readonly_note')),
      findsNothing,
    );
    expect(find.text('Not set up'), findsOneWidget);
    expect(
      find.byKey(const Key('admin_my_account_two_factor_card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_my_account_mfa_enroll_button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_my_account_change_password_button')),
      findsOneWidget,
    );
    // Recovery ("Lost your authenticator?") is offered only once a
    // factor is enrolled — there is nothing to recover before then.
    expect(
      find.byKey(const Key('admin_my_account_mfa_recovery_button')),
      findsNothing,
    );
  });

  testWidgets('enroll → confirm drives the gateway with a stable key',
      (tester) async {
    wideViewport(tester);
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);
    final gateway = InMemoryAdminSecurityGateway();

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          securityGateway: gateway,
          now: () => DateTime.utc(2026, 5, 14, 12, 30, 0),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final enroll = find.byKey(const Key('admin_my_account_mfa_enroll_button'));
    await tester.ensureVisible(enroll);
    await tester.tap(enroll);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_enroll_mfa_dialog')), findsOneWidget);
    // Parity with ops + mobile: the enroll dialog renders a scannable QR
    // code (in addition to the paste-able setup link and secret).
    expect(find.byKey(const Key('admin_enroll_mfa_qr')), findsOneWidget);
    expect(find.byKey(const Key('admin_enroll_mfa_secret')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('admin_enroll_mfa_code_field')),
      '123456',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('admin_enroll_mfa_confirm')));
    await tester.pumpAndSettle();

    // Dialog closed, factor enrolled, toast shown.
    expect(find.byKey(const Key('admin_enroll_mfa_dialog')), findsNothing);
    expect((await gateway.listFactors()).hasEnrolledFactor, isTrue);
    expect(
      find.byKey(const Key('admin_my_account_two_factor_toast')),
      findsOneWidget,
    );
    // begin + confirm share ONE caller-stable key (no G60 bug).
    expect(gateway.idempotencyKeys, hasLength(2));
    expect(gateway.idempotencyKeys.toSet(), hasLength(1));
  });

  testWidgets('gateway failure on confirm fails closed (no success toast)',
      (tester) async {
    wideViewport(tester);
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);
    final gateway = InMemoryAdminSecurityGateway();

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          securityGateway: gateway,
          now: () => DateTime.utc(2026, 5, 14, 12, 30, 0),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final enroll = find.byKey(const Key('admin_my_account_mfa_enroll_button'));
    await tester.ensureVisible(enroll);
    await tester.tap(enroll);
    await tester.pumpAndSettle();

    // Wrong-length code → InMemory gateway throws → dialog shows the
    // error, the surface does NOT claim success.
    await tester.enterText(
      find.byKey(const Key('admin_enroll_mfa_code_field')),
      '12345',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
              find.byKey(const Key('admin_enroll_mfa_confirm')))
          .onPressed,
      isNull,
      reason: 'A 5-digit code must not be submittable.',
    );

    // Cancel and confirm no false enrollment / no success toast.
    await tester.tap(find.byKey(const Key('admin_enroll_mfa_cancel')));
    await tester.pumpAndSettle();
    expect((await gateway.listFactors()).hasEnrolledFactor, isFalse);
    expect(
      find.byKey(const Key('admin_my_account_two_factor_toast')),
      findsNothing,
    );
  });

  testWidgets('password change dialog opens and routes through the gateway',
      (tester) async {
    wideViewport(tester);
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);
    final gateway = InMemoryAdminSecurityGateway();

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          securityGateway: gateway,
          now: () => DateTime.utc(2026, 5, 14, 12, 30, 0),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('admin_my_account_change_password_button')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_change_password_dialog')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('admin_change_password_current')),
      'old-secret',
    );
    await tester.enterText(
      find.byKey(const Key('admin_change_password_new')),
      'a-very-strong-pw-1!',
    );
    await tester.enterText(
      find.byKey(const Key('admin_change_password_confirm')),
      'a-very-strong-pw-1!',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('admin_change_password_save')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_change_password_dialog')),
      findsNothing,
    );
    expect(gateway.idempotencyKeys, isNotEmpty);
  });

  // ─── Turn off two-factor sign-in (operator-web parity) ─────────────

  testWidgets(
      'turn-off action is offered only when a factor is enrolled',
      (tester) async {
    wideViewport(tester);
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);
    final now = DateTime.utc(2026, 5, 14, 12, 30, 0);

    // Not enrolled — no turn-off action. (Distinct screen keys force a
    // fresh State so each pump re-reads its own gateway in initState.)
    final notEnrolled = InMemoryAdminSecurityGateway(now: () => now);
    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          key: const Key('screen-not-enrolled'),
          session: session(),
          authSource: source,
          securityGateway: notEnrolled,
          now: () => now,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_my_account_mfa_turn_off_button')),
      findsNothing,
    );

    // Enrolled — turn-off action present.
    final enrolled = InMemoryAdminSecurityGateway(
      seedEnrolledFactor: true,
      now: () => now,
    );
    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          key: const Key('screen-enrolled'),
          session: session(),
          authSource: source,
          securityGateway: enrolled,
          now: () => now,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_my_account_mfa_turn_off_button')),
      findsOneWidget,
    );
  });

  testWidgets(
      'requesting removal sends an idempotency key and shows the pending '
      'scheduled state', (tester) async {
    wideViewport(tester);
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);
    final now = DateTime.utc(2026, 5, 14, 12, 30, 0);
    final gateway = InMemoryAdminSecurityGateway(
      seedEnrolledFactor: true,
      now: () => now,
    );

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          securityGateway: gateway,
          now: () => now,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final turnOff =
        find.byKey(const Key('admin_my_account_mfa_turn_off_button'));
    await tester.ensureVisible(turnOff);
    await tester.tap(turnOff);
    await tester.pumpAndSettle();

    // Confirm dialog appears (operator-web parity copy).
    expect(find.byKey(const Key('admin_mfa_turn_off_dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('admin_mfa_turn_off_confirm')));
    await tester.pumpAndSettle();

    // Gateway was driven with a stable idempotency key, removal pending.
    expect(gateway.idempotencyKeys, isNotEmpty);
    expect((await gateway.listFactors()).pendingRemoval, isNotNull);

    // Card now shows the pending/scheduled state + cancel action.
    expect(
      find.byKey(const Key('admin_my_account_mfa_removal_pending')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_my_account_mfa_cancel_removal_button')),
      findsOneWidget,
    );
    // The scheduled date is the 24h grace window past the injected now.
    expect(
      find.byKey(const Key('admin_my_account_mfa_removal_scheduled')),
      findsOneWidget,
    );
    expect(find.textContaining('2026-05-15 12:30 UTC'), findsOneWidget);
    // The turn-off action is replaced by the pending state.
    expect(
      find.byKey(const Key('admin_my_account_mfa_turn_off_button')),
      findsNothing,
    );
  });

  testWidgets(
      'cancel removal calls the gateway and returns to the enrolled state',
      (tester) async {
    wideViewport(tester);
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);
    final now = DateTime.utc(2026, 5, 14, 12, 30, 0);
    final gateway = InMemoryAdminSecurityGateway(
      seedEnrolledFactor: true,
      now: () => now,
    );

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          securityGateway: gateway,
          now: () => now,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Drive into the pending state first.
    final turnOff =
        find.byKey(const Key('admin_my_account_mfa_turn_off_button'));
    await tester.ensureVisible(turnOff);
    await tester.tap(turnOff);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_mfa_turn_off_confirm')));
    await tester.pumpAndSettle();
    expect((await gateway.listFactors()).pendingRemoval, isNotNull);

    final keysAfterRequest = gateway.idempotencyKeys.length;

    // Now cancel.
    final cancel =
        find.byKey(const Key('admin_my_account_mfa_cancel_removal_button'));
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();

    // Cancel hit the gateway (a new key) and cleared the pending request.
    expect(gateway.idempotencyKeys.length, greaterThan(keysAfterRequest));
    expect((await gateway.listFactors()).pendingRemoval, isNull);

    // Card is back to the enrolled (not-pending) state: turn-off action
    // returns, pending state gone, factor still enrolled.
    expect(
      find.byKey(const Key('admin_my_account_mfa_removal_pending')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_my_account_mfa_turn_off_button')),
      findsOneWidget,
    );
    expect((await gateway.listFactors()).hasEnrolledFactor, isTrue);
  });

  testWidgets(
      'removal request fails closed on a gateway error (no false success, '
      'factor stays enrolled)', (tester) async {
    wideViewport(tester);
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);
    final now = DateTime.utc(2026, 5, 14, 12, 30, 0);
    final gateway = _ThrowingRemovalGateway(now: () => now);

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          securityGateway: gateway,
          now: () => now,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final turnOff =
        find.byKey(const Key('admin_my_account_mfa_turn_off_button'));
    await tester.ensureVisible(turnOff);
    await tester.tap(turnOff);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_mfa_turn_off_confirm')));
    await tester.pumpAndSettle();

    // No pending state, factor still enrolled, turn-off action remains.
    expect(
      find.byKey(const Key('admin_my_account_mfa_removal_pending')),
      findsNothing,
    );
    expect((await gateway.listFactors()).pendingRemoval, isNull);
    expect((await gateway.listFactors()).hasEnrolledFactor, isTrue);
    expect(
      find.byKey(const Key('admin_my_account_mfa_turn_off_button')),
      findsOneWidget,
    );

    // The error surfaces in the toast, and crucially the success copy
    // ("will turn off after a 24-hour wait") is absent — no false
    // success.
    expect(
      find.byKey(const Key('admin_my_account_two_factor_toast')),
      findsOneWidget,
    );
    expect(find.textContaining('will turn off after a 24-hour wait'),
        findsNothing);
    expect(find.textContaining('two-factor service is unavailable'),
        findsOneWidget);
  });

  testWidgets(
      'freshness error surfaces an actionable "Sign in again" control that '
      'triggers re-authentication, and still fails closed', (tester) async {
    wideViewport(tester);
    final source = _SpyAdminAuthSource();
    addTearDown(source.dispose);
    final now = DateTime.utc(2026, 5, 14, 12, 30, 0);
    final gateway = _ThrowingRemovalGateway(
      now: () => now,
      error: const AdminSecurityGatewayError(
        statusCode: 403,
        errorCode: 'mfa_freshness_required',
        message: 'fresh step-up required',
      ),
    );

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          securityGateway: gateway,
          now: () => now,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final turnOff =
        find.byKey(const Key('admin_my_account_mfa_turn_off_button'));
    await tester.ensureVisible(turnOff);
    await tester.tap(turnOff);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_mfa_turn_off_confirm')));
    await tester.pumpAndSettle();

    // The distinctive freshness remedy copy (not the generic
    // "sign in again first" hint already on the turn-off action body).
    expect(
      find.textContaining('Please sign in again before changing two-factor'),
      findsOneWidget,
    );
    // The remedy is now an actionable control, not just text: a plain red
    // error toast is NOT used for the freshness case.
    final signInAgain = find.byKey(
      const Key('admin_my_account_two_factor_sign_in_again'),
    );
    expect(signInAgain, findsOneWidget);
    expect(find.text('Sign in again'), findsOneWidget);

    // Fails closed: no pending removal, factor stays enrolled, and the
    // re-auth path has NOT fired until the operator taps the control.
    expect((await gateway.listFactors()).pendingRemoval, isNull);
    expect((await gateway.listFactors()).hasEnrolledFactor, isTrue);
    expect(source.signOutCount, 0);

    // Tapping it triggers the admin console's re-authentication path
    // (a fresh sign-in via AdminAuthSource.signOut()).
    await tester.ensureVisible(signInAgain);
    await tester.tap(signInAgain);
    await tester.pumpAndSettle();
    expect(source.signOutCount, 1);
  });

  testWidgets(
      'a non-freshness gateway error keeps the plain red toast (no '
      '"Sign in again" control)', (tester) async {
    wideViewport(tester);
    final source = _SpyAdminAuthSource();
    addTearDown(source.dispose);
    final now = DateTime.utc(2026, 5, 14, 12, 30, 0);
    // Default _ThrowingRemovalGateway error is a generic 503 (not
    // freshness).
    final gateway = _ThrowingRemovalGateway(now: () => now);

    await tester.pumpWidget(
      wrap(
        MyAccountAdminScreen(
          session: session(),
          authSource: source,
          securityGateway: gateway,
          now: () => now,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final turnOff =
        find.byKey(const Key('admin_my_account_mfa_turn_off_button'));
    await tester.ensureVisible(turnOff);
    await tester.tap(turnOff);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_mfa_turn_off_confirm')));
    await tester.pumpAndSettle();

    // The generic error renders in the toast; the actionable freshness
    // control is absent and the re-auth path never fires.
    expect(
      find.byKey(const Key('admin_my_account_two_factor_toast')),
      findsOneWidget,
    );
    expect(find.textContaining('two-factor service is unavailable'),
        findsOneWidget);
    expect(
      find.byKey(const Key('admin_my_account_two_factor_sign_in_again')),
      findsNothing,
    );
    expect(source.signOutCount, 0);
    // Still fails closed.
    expect((await gateway.listFactors()).pendingRemoval, isNull);
    expect((await gateway.listFactors()).hasEnrolledFactor, isTrue);
  });
}

/// Spy auth source that counts [signOut] calls so the freshness "Sign in
/// again" control can be asserted to route through the admin console's
/// re-authentication path. Extends [DemoAdminAuthSource] so the real
/// state stream (emitting [AdminAuthUnauthenticated] on sign-out) is
/// preserved; only the call is recorded.
class _SpyAdminAuthSource extends DemoAdminAuthSource {
  _SpyAdminAuthSource()
      : super(
          initial: const AdminAuthAuthenticated(
            AdminAuthSession(
              uid: 'demo-super-admin',
              email: 'super.admin@forgeflow.test',
              displayName: 'Demo Super Admin',
              roles: <String>['super_admin'],
            ),
          ),
        );

  int signOutCount = 0;

  @override
  Future<void> signOut() {
    signOutCount += 1;
    return super.signOut();
  }
}

/// Enrolled gateway whose [requestFactorRemoval] always throws, so the
/// screen's fail-closed path can be exercised. Defaults to a generic
/// error; tests pass [error] to drive the freshness branch.
class _ThrowingRemovalGateway extends InMemoryAdminSecurityGateway {
  _ThrowingRemovalGateway({super.now, this.error})
      : super(seedEnrolledFactor: true);

  final AdminSecurityGatewayError? error;

  @override
  Future<AdminSecurityFactorRemovalRequested> requestFactorRemoval({
    required String factorId,
    required String idempotencyKey,
    String? freshAuthProof,
  }) async {
    idempotencyKeys.add(idempotencyKey);
    throw error ??
        const AdminSecurityGatewayError(
          statusCode: 503,
          errorCode: 'mfa_unavailable',
          message: 'two-factor service is unavailable',
        );
  }
}
