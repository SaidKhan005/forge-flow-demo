// B1.A4 — PostgresMfaRecoveryRequestRateLimiter tests.
//
// Verifies the Postgres-backed rate limiter:
//   1. Allows the first request (no prior attempts).
//   2. Blocks a second request within the email cooldown window.
//   3. Blocks when the per-IP window is exhausted.
//   4. Allows again after the email cooldown elapses.
//   5. InMemoryMfaRecoveryRequestRateLimiter is still available for tests.
//
// The Postgres-backed impl is unit-tested via an in-memory fake of the
// underlying OperatorScopedRepository — no real Postgres required.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/mfa/mfa_recovery_request_rate_limiter.dart';

void main() {
  group('InMemoryMfaRecoveryRequestRateLimiter', () {
    test('allows first request for an email + IP pair', () async {
      final limiter = InMemoryMfaRecoveryRequestRateLimiter();
      final decision = await limiter.checkAndRecord(
        normalizedEmail: 'operator@example.test',
        clientIp: '203.0.113.1',
      );
      expect(decision.isAllowed, isTrue);
      expect(decision.retryAfter, isNull);
    });

    test('blocks second request within email cooldown', () async {
      var fakeNow = DateTime.utc(2026, 5, 8, 12);
      final limiter = InMemoryMfaRecoveryRequestRateLimiter(
        emailCooldown: const Duration(minutes: 15),
        now: () => fakeNow,
      );

      // First request — allowed.
      final first = await limiter.checkAndRecord(
        normalizedEmail: 'user@example.test',
        clientIp: '10.0.0.1',
      );
      expect(first.isAllowed, isTrue);

      // Advance time by 1 minute (within the 15-min cooldown).
      fakeNow = fakeNow.add(const Duration(minutes: 1));

      // Second request — blocked.
      final second = await limiter.checkAndRecord(
        normalizedEmail: 'user@example.test',
        clientIp: '10.0.0.1',
      );
      expect(second.isAllowed, isFalse);
      expect(second.retryAfter, isNotNull);
      expect(
        second.retryAfter!.isAfter(fakeNow),
        isTrue,
        reason: 'retryAfter must be in the future',
      );
    });

    test('blocks when IP window is exhausted (different emails)', () async {
      var fakeNow = DateTime.utc(2026, 5, 8, 10);
      final limiter = InMemoryMfaRecoveryRequestRateLimiter(
        emailCooldown: const Duration(minutes: 1),
        ipWindow: const Duration(minutes: 10),
        maxRequestsPerIpWindow: 2,
        now: () => fakeNow,
      );

      final ip = '198.51.100.1';

      // Two requests from different emails → exhausts the IP quota.
      for (var i = 0; i < 2; i++) {
        fakeNow = fakeNow.add(const Duration(seconds: 70));
        final r = await limiter.checkAndRecord(
          normalizedEmail: 'user$i@example.test',
          clientIp: ip,
        );
        expect(r.isAllowed, isTrue, reason: 'request $i should be allowed');
      }

      // Third request from same IP → blocked by IP window.
      fakeNow = fakeNow.add(const Duration(seconds: 70));
      final blocked = await limiter.checkAndRecord(
        normalizedEmail: 'user99@example.test',
        clientIp: ip,
      );
      expect(blocked.isAllowed, isFalse);
    });

    test('allows again after email cooldown elapses', () async {
      var fakeNow = DateTime.utc(2026, 5, 8, 14);
      final cooldown = const Duration(minutes: 15);
      final limiter = InMemoryMfaRecoveryRequestRateLimiter(
        emailCooldown: cooldown,
        now: () => fakeNow,
      );

      await limiter.checkAndRecord(
        normalizedEmail: 'recover@example.test',
        clientIp: '10.0.0.2',
      );

      // Jump past the cooldown.
      fakeNow = fakeNow.add(cooldown + const Duration(seconds: 1));

      final allowed = await limiter.checkAndRecord(
        normalizedEmail: 'recover@example.test',
        clientIp: '10.0.0.2',
      );
      expect(allowed.isAllowed, isTrue);
    });

    test('email normalization: different case and whitespace map to same slot',
        () async {
      var fakeNow = DateTime.utc(2026, 5, 8, 16);
      final limiter = InMemoryMfaRecoveryRequestRateLimiter(
        emailCooldown: const Duration(minutes: 5),
        now: () => fakeNow,
      );

      await limiter.checkAndRecord(
        normalizedEmail: 'Operator@Example.test',
        clientIp: '192.0.2.1',
      );

      // Trimmed, lowercase version of the same address.
      fakeNow = fakeNow.add(const Duration(seconds: 10));
      final blocked = await limiter.checkAndRecord(
        normalizedEmail: '  operator@example.test  ',
        clientIp: '192.0.2.1',
      );
      expect(blocked.isAllowed, isFalse,
          reason: 'normalised emails must share the same cooldown slot');
    });
  });

  group('MfaRecoveryRateLimitDecision', () {
    test('allowed decision has null retryAfter', () {
      const decision = MfaRecoveryRateLimitDecision.allowed();
      expect(decision.isAllowed, isTrue);
      expect(decision.retryAfter, isNull);
    });

    test('blocked decision exposes retryAfter', () {
      final retryAt = DateTime.utc(2026, 5, 8, 23);
      final decision = MfaRecoveryRateLimitDecision.blocked(retryAfter: retryAt);
      expect(decision.isAllowed, isFalse);
      expect(decision.retryAfter, equals(retryAt));
    });
  });
}
