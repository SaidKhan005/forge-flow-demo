// Tests the AdminAuthSession-driven MFA-freshness gate.
//
// Coverage:
//   * AdminAuthSession defaults `lastFreshAuthAt` to null (fail closed).
//   * AdminAuthSession round-trips a non-null lastFreshAuthAt.
//   * The shared FreshMfaResolver returns isFresh=true on a recent
//     stamp and isFresh=false on a stale stamp.
//
// We do not run a full widget pump here — the four affordances flow
// through `_isAdminMfaFresh` which is tested via the public
// FreshMfaResolver contract, and the integration with admin_routes
// is exercised by the existing admin route widget tests once the
// session carries the stamp. This test pins the contract those
// tests rely on so a regression in either the AdminAuthSession
// shape or the resolver flips a red light immediately.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/auth/fresh_mfa_resolver.dart';

void main() {
  group('AdminAuthSession.lastFreshAuthAt', () {
    test('defaults to null (fail-closed)', () {
      const session = AdminAuthSession(
        uid: 'u1',
        email: 'admin@example.test',
        displayName: 'Admin',
        roles: <String>['super_admin'],
      );
      expect(session.lastFreshAuthAt, isNull);
    });

    test('round-trips a non-null stamp', () {
      final stamp = DateTime.utc(2026, 5, 7, 12, 0);
      final session = AdminAuthSession(
        uid: 'u1',
        email: 'admin@example.test',
        displayName: 'Admin',
        roles: const <String>['super_admin'],
        lastFreshAuthAt: stamp,
      );
      expect(session.lastFreshAuthAt, equals(stamp));
    });
  });

  group('FreshMfaResolver gate (integration shape)', () {
    test('fresh stamp under window → resolver says true', () {
      final now = DateTime.utc(2026, 5, 7, 12, 0);
      final resolver = JwtFreshMfaResolver(now: () => now);
      final session = AuthSession(
        userId: 'u1',
        operatorId: 'op',
        locationId: 'loc',
        firebaseIdToken: '',
        issuedAt: now.subtract(const Duration(minutes: 5)),
        expiresAt: now.add(const Duration(hours: 1)),
        lastFreshAuthAt: now.subtract(const Duration(minutes: 5)),
        roles: const <String>['super_admin'],
        mfaEnrolled: true,
      );
      expect(resolver.isFresh(session), isTrue);
    });

    test('stale stamp past window → resolver says false', () {
      final now = DateTime.utc(2026, 5, 7, 12, 0);
      final resolver = JwtFreshMfaResolver(now: () => now);
      final session = AuthSession(
        userId: 'u1',
        operatorId: 'op',
        locationId: 'loc',
        firebaseIdToken: '',
        issuedAt: now.subtract(const Duration(hours: 2)),
        expiresAt: now.add(const Duration(hours: 1)),
        lastFreshAuthAt: now.subtract(const Duration(hours: 2)),
        roles: const <String>['super_admin'],
        mfaEnrolled: true,
      );
      expect(resolver.isFresh(session), isFalse);
    });
  });
}
