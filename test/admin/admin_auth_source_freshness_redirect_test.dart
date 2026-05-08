// CODE_OPS_DEBT carry-over #1 — `AdminAuthSource` implementations
// act as the [MfaFreshnessRedirectListener] for the admin shell.
// When the admin HTTP layer dispatches a 403 redirect, the source
// signs out and emits an [AdminAuthUnauthenticated] state carrying
// the proxy-supplied `redirect_uri` hint.
//
// This test pins the demo source's behaviour. The Firebase source
// drives the same emit path through the same `_emit` channel; the
// difference is the awaited Firebase sign-out call, which lives
// behind a private SDK seam. Demo coverage is enough to pin the
// state-machine contract.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/auth/mfa_freshness_redirect_listener.dart';

void main() {
  test(
    'DemoAdminAuthSource.onMfaFreshnessRedirect emits unauthenticated + carries redirectUri',
    () async {
      final source = DemoAdminAuthSource(
        initial: const AdminAuthAuthenticated(
          AdminAuthSession(
            uid: 'demo-super-admin',
            email: 'super.admin@forgeflow.test',
            displayName: 'Demo Super Admin',
            roles: <String>['super_admin'],
          ),
        ),
      );

      final emitted = <AdminAuthState>[];
      final sub = source.stream.listen(emitted.add);

      // Drain initial state replay.
      await Future<void>.delayed(Duration.zero);

      const payload = MfaFreshnessRedirectPayload(
        redirectUri:
            '/auth/login?reason=fresh_mfa_required&permission_key=admin.audit.export',
        message: 'fresh authentication is required',
      );

      source.onMfaFreshnessRedirect(payload);
      await Future<void>.delayed(Duration.zero);

      final unauth = emitted.whereType<AdminAuthUnauthenticated>().toList();
      expect(unauth, isNotEmpty);
      expect(
        unauth.last.redirectUri,
        '/auth/login?reason=fresh_mfa_required&permission_key=admin.audit.export',
      );
      expect(unauth.last.lastInfoMessage, 'fresh authentication is required');
      expect(unauth.last.lastErrorMessage, isNull);

      await sub.cancel();
      source.dispose();
    },
  );

  test(
    'DemoAdminAuthSource falls back to a default info message when the proxy did not supply one',
    () async {
      final source = DemoAdminAuthSource.signedInAsSuperAdmin();
      final emitted = <AdminAuthState>[];
      final sub = source.stream.listen(emitted.add);
      await Future<void>.delayed(Duration.zero);

      const payload = MfaFreshnessRedirectPayload(
        redirectUri: '/auth/login',
      );
      source.onMfaFreshnessRedirect(payload);
      await Future<void>.delayed(Duration.zero);

      final unauth = emitted.whereType<AdminAuthUnauthenticated>().single;
      expect(unauth.lastInfoMessage, isNotNull);
      expect(unauth.lastInfoMessage, contains('sign in again'));
      expect(unauth.redirectUri, '/auth/login');

      await sub.cancel();
      source.dispose();
    },
  );

  test('AdminAuthUnauthenticated round-trips the new fields', () {
    const state = AdminAuthUnauthenticated(
      lastInfoMessage: 'msg',
      redirectUri: '/auth/login?x=1',
    );
    expect(state.lastInfoMessage, 'msg');
    expect(state.redirectUri, '/auth/login?x=1');
    expect(state.lastErrorMessage, isNull);
  });
}
