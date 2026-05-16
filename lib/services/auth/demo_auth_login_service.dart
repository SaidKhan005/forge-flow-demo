// Demo Forge & Flow flavor — writer-side AuthLoginService fixture.
//
// HP #2 (CLAUDE.md → Demo Mode): demo is a *writer-side* switch. This
// service is the demo analogue of `MockReplayDataSourceProvider` — it
// is the SOURCE/WRITER of the auth session, exactly as
// `MockReplayDataSourceProvider` is the writer of demo SQLite data.
// Nothing downstream branches on `kDemoMode`: `AuthSessionNotifier`,
// `SettingsScreen`, the role/permission gates, and every reader path
// consume the resulting `AuthSession` identically in demo and prod.
// Selecting THIS implementation vs. `FirebaseAuthLoginService` at
// bootstrap is the same source-swap the demo contract already endorses
// for Operator Web (`OPERATOR_WEB_DEMO_AUTH`) and Admin
// (`ADMIN_DEMO_AUTH`) — see `docs/contracts/demo_mode_contract.md`
// "Architecture (web flavors)".
//
// Operator decision (per the fix prompt): the demo operator must be a
// F&F admin so the full mobile Settings surface is testable in demo —
// Account tab, Setup, Integrations, the Data tab, and the F&F-only
// Data-alignment panel inside it. We project the `ff_support` role
// (NOT `super_admin`): `ff_support` satisfies every gate that hides
// these surfaces — `admin_auth_gate.dart` `kAdminConsoleRoles`,
// `settings_screen.dart` `_isFFAccount` / `_shouldShowDataTab` (which
// keys off the `admin.debug_console.view` catalog key granted to
// `super_admin` + `ff_support` only) — without granting the
// destructive `super_admin`-tier F&F-ops affordances. This maps to the
// `ff_support` row in `docs/contracts/auth_permission_key_catalog.md`.
//
// Production auth is byte-unchanged: this file is only constructed by
// the `kDemoMode` / `FORGE_FLOW_DEMO_MODE` bootstrap branch in
// `lib/main_forgeflow.dart`. The `FORGE_FLOW_USE_FIREBASE_AUTH`
// production branch never references it.

import 'dart:convert';

import '../../auth/auth_session.dart';
import '../auth_login_service.dart';

/// Email the demo "Use demo operator" one-tap button submits (see the
/// `_demoOperatorSignInEnabled` carve-out in
/// `lib/screens/auth/login_screen.dart`). Matched case-insensitively.
const String kDemoOperatorEmail = 'demo.operator@forgeflow.test';

/// Password the demo one-tap button submits. The regular email/password
/// form also reaches this service; any other credential fails closed
/// with `invalid_credentials` (no parallel always-allow path).
const String kDemoOperatorPassword = 'forge-flow-demo';

/// Demo operator scope. `operatorId` matches
/// `restaurant_scope_notifier.dart`'s `_kBootFallbackOperatorId`
/// (`'demo-operator'`) and `locationId` matches `DemoScope.restaurantId`
/// (`'demo_restaurant_001'`) so demo SQLite data still resolves under
/// the signed-in session. Hardcoded (rather than importing the sqflite
/// `DemoScope`) to keep the auth seam free of a persistence import;
/// `demo_auth_login_service_test.dart` pins these against `DemoScope`
/// so they cannot drift.
const String kDemoOperatorUserId = 'demo-operator-user';
const String kDemoOperatorOperatorId = 'demo-operator';
const String kDemoOperatorLocationId = 'demo_restaurant_001';

/// Writer-side demo [AuthLoginService]. Recognises only the demo
/// operator credential and mints a long-lived F&F-admin
/// (`ff_support`) [AuthSession]. Every other credential fails closed.
class DemoAuthLoginService implements AuthLoginService {
  const DemoAuthLoginService({DateTime Function()? now}) : _now = now;

  final DateTime Function()? _now;

  DateTime _clock() => (_now ?? DateTime.now)();

  @override
  Future<AuthLoginResult> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    if (normalizedEmail != kDemoOperatorEmail || password != kDemoOperatorPassword) {
      return const AuthLoginFailure(
        code: 'invalid_credentials',
        message: 'Email or password is incorrect.',
      );
    }
    return AuthLoginSuccess(_demoSession());
  }

  @override
  Future<AuthLoginResult> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async {
    // The demo operator fixture carries no MFA factor (mfaEnrolled:
    // false), so sign-in never returns AuthLoginMfaRequired and this
    // path is unreachable in the demo flavor. Fail closed rather than
    // mint a session from an unsolicited challenge completion.
    return const AuthLoginFailure(
      code: 'invalid_credentials',
      message: 'Two-factor sign-in is not configured for the demo operator.',
    );
  }

  @override
  Future<void> requestPasswordReset({required String email}) async {
    // No-op: the demo flavor has no mail backend. The login screen's
    // `kDemoMode` "Forgot password?" path already routes to
    // `DemoPasswordResetGateway`; this keeps the seam total.
  }

  @override
  Future<AuthSession?> refreshSession(AuthSession current) async {
    // Re-issue the same identity with a fresh token window so a long
    // demo walkthrough never expires mid-session.
    return _demoSession();
  }

  @override
  Future<void> signOutThisSession() async {}

  @override
  Future<void> signOutAllSessions() async {}

  AuthSession _demoSession() {
    final issuedAt = _clock();
    return AuthSession(
      userId: kDemoOperatorUserId,
      operatorId: kDemoOperatorOperatorId,
      locationId: kDemoOperatorLocationId,
      firebaseIdToken: _syntheticIdToken(issuedAt),
      issuedAt: issuedAt,
      // Long-lived so a demo walkthrough does not expire; this token is
      // never verified server-side in the demo flavor (no proxy wired).
      expiresAt: issuedAt.add(const Duration(days: 30)),
      lastFreshAuthAt: issuedAt,
      roles: const <String>['ff_support', 'roles_version:1'],
      mfaEnrolled: false,
    );
  }

  /// Builds an unsigned (`alg: none`) JWT-shaped token carrying the
  /// honest demo identity claims. It is NOT a security credential —
  /// the demo flavor has no proxy to verify it — but
  /// `_fallbackAccountInfoForSession` / `_mfaEmailForSession` in
  /// `settings_data_sections.dart` / `settings_screen.dart` decode the
  /// payload for the Account-card display, so the values must be the
  /// real demo identity (Metric Honesty: honest values, never phantom).
  static String _syntheticIdToken(DateTime issuedAt) {
    String segment(Map<String, Object?> json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
    final header = segment(<String, Object?>{'alg': 'none', 'typ': 'JWT'});
    final payload = segment(<String, Object?>{
      'email': kDemoOperatorEmail,
      'name': 'Demo Operator',
      'is_ff_support': true,
      'operator_id': kDemoOperatorOperatorId,
      'location_id': kDemoOperatorLocationId,
      'iat': issuedAt.toUtc().millisecondsSinceEpoch ~/ 1000,
    });
    return '$header.$payload.';
  }
}
