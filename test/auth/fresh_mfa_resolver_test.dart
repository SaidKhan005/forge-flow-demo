// Tests for [JwtFreshMfaResolver].
//
// Coverage:
//   * `isFresh` returns true when `auth_time` is within the window.
//   * `isFresh` returns false when `auth_time` is older than the
//     window.
//   * `isFresh` returns false when the session carries no
//     `auth_time` (epoch-zero placeholder used by the proxy).
//   * Window default is 3600 s.
//   * `secondsUntilStale` returns null on missing claim, 0 on stale,
//     positive remaining seconds when fresh.
//
// Env-override behaviour is covered by inspection (the env read
// happens in the constructor); tests use the explicit constructor
// argument since `Platform.environment` is unmodifiable at runtime.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/auth/fresh_mfa_resolver.dart';

AuthSession _sessionWith({required DateTime authTime}) {
  return AuthSession(
    userId: 'u1',
    operatorId: 'op1',
    locationId: 'loc1',
    firebaseIdToken: '',
    issuedAt: authTime,
    expiresAt: authTime.add(const Duration(hours: 1)),
    lastFreshAuthAt: authTime,
    roles: const <String>['super_admin'],
    mfaEnrolled: true,
  );
}

void main() {
  group('JwtFreshMfaResolver', () {
    test('isFresh true within 1-hour default window', () {
      final now = DateTime.utc(2026, 5, 7, 12, 0);
      final authTime = now.subtract(const Duration(minutes: 30));
      final resolver = JwtFreshMfaResolver(now: () => now);
      expect(resolver.isFresh(_sessionWith(authTime: authTime)), isTrue);
    });

    test('isFresh false when auth_time older than window', () {
      final now = DateTime.utc(2026, 5, 7, 12, 0);
      final authTime = now.subtract(const Duration(hours: 2));
      final resolver = JwtFreshMfaResolver(now: () => now);
      expect(resolver.isFresh(_sessionWith(authTime: authTime)), isFalse);
    });

    test('isFresh false at exactly the boundary', () {
      // Window is closed-on-the-stale-side: elapsed == window → stale.
      final now = DateTime.utc(2026, 5, 7, 12, 0);
      final authTime = now.subtract(const Duration(seconds: 3600));
      final resolver = JwtFreshMfaResolver(now: () => now);
      expect(resolver.isFresh(_sessionWith(authTime: authTime)), isFalse);
    });

    test('isFresh false when session carries epoch-zero stamp', () {
      final resolver = JwtFreshMfaResolver(
        now: () => DateTime.utc(2026, 5, 7, 12, 0),
      );
      final session = _sessionWith(
        authTime: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
      expect(resolver.isFresh(session), isFalse);
    });

    test('secondsUntilStale returns null for epoch-zero stamp', () {
      final resolver = JwtFreshMfaResolver(
        now: () => DateTime.utc(2026, 5, 7, 12, 0),
      );
      final session = _sessionWith(
        authTime: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
      expect(resolver.secondsUntilStale(session), isNull);
    });

    test('secondsUntilStale returns 0 when stale', () {
      final now = DateTime.utc(2026, 5, 7, 12, 0);
      final resolver = JwtFreshMfaResolver(now: () => now);
      final session = _sessionWith(
        authTime: now.subtract(const Duration(hours: 2)),
      );
      expect(resolver.secondsUntilStale(session), equals(0));
    });

    test('secondsUntilStale returns positive remainder when fresh', () {
      final now = DateTime.utc(2026, 5, 7, 12, 0);
      final resolver = JwtFreshMfaResolver(now: () => now);
      final session = _sessionWith(
        authTime: now.subtract(const Duration(minutes: 10)),
      );
      // 3600 - 600 = 3000 s remaining.
      expect(resolver.secondsUntilStale(session), equals(3000));
    });

    test('explicit windowSeconds overrides default', () {
      final now = DateTime.utc(2026, 5, 7, 12, 0);
      final resolver = JwtFreshMfaResolver(
        windowSeconds: 60,
        now: () => now,
      );
      // 90s old → stale under a 60s window.
      final session = _sessionWith(
        authTime: now.subtract(const Duration(seconds: 90)),
      );
      expect(resolver.isFresh(session), isFalse);
      expect(resolver.windowSeconds, equals(60));
    });

    test('default window seconds is 3600', () {
      expect(JwtFreshMfaResolver.defaultWindowSeconds, equals(3600));
    });
  });

  group('FakeFreshMfaResolver', () {
    test('returns its canned answer regardless of session', () {
      final session = _sessionWith(
        authTime: DateTime.utc(1970, 1, 1),
      );
      final fake = FakeFreshMfaResolver(fresh: true);
      expect(fake.isFresh(session), isTrue);
      final fakeStale = FakeFreshMfaResolver(fresh: false);
      expect(fakeStale.isFresh(session), isFalse);
    });
  });
}
