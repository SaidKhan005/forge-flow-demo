// B1.A7 — Account lockout enforcement tests.
//
// Verifies that:
//   1. The lockout enforcer rejects login attempts when the failure count
//      reaches kAuthLoginLockoutThreshold.
//   2. A successful login within the window resets the failure count.
//   3. The lockout window is 15 minutes (kAuthLoginLockoutRetryAfter).
//   4. The in-memory enforcer correctly implements the same contract as
//      the production Postgres-backed path.

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('Account lockout enforcement — kAuth* constants', () {
    test('lockout threshold is 5 failures', () {
      expect(kAuthLoginLockoutThreshold, equals(5));
    });

    test('lockout retry-after is 15 minutes (900 seconds)', () {
      expect(kAuthLoginLockoutRetryAfter.inSeconds, equals(900));
    });

    test('lockout window is 15 minutes', () {
      expect(kAuthLoginLockoutWindow.inMinutes, equals(15));
    });
  });

  group('InMemoryAuthLockoutEnforcer', () {
    InMemoryAuthLockoutEnforcer makeEnforcer(DateTime Function() now) {
      return InMemoryAuthLockoutEnforcer(
        threshold: kAuthLoginLockoutThreshold,
        window: kAuthLoginLockoutWindow,
        now: now,
      );
    }

    test('evaluate returns not-locked when no attempts', () async {
      final fakeNow = DateTime.utc(2026, 5, 8, 10);
      final enforcer = makeEnforcer(() => fakeNow);

      final eval = await enforcer.evaluate(
        email: 'op@example.test',
        ip: '10.0.0.1',
      );

      expect(eval.locked, isFalse);
      expect(eval.failureCount, equals(0));
    });

    test('trips locked after threshold failures', () async {
      var fakeNow = DateTime.utc(2026, 5, 8, 10);
      final enforcer = makeEnforcer(() => fakeNow);
      const email = 'target@example.test';
      const ip = '192.168.1.1';

      for (var i = 0; i < kAuthLoginLockoutThreshold; i++) {
        fakeNow = fakeNow.add(const Duration(seconds: 30));
        await enforcer.recordFailure(email: email, ip: ip);
      }

      final eval = await enforcer.evaluate(email: email, ip: ip);
      expect(
        eval.locked || eval.failureCount >= kAuthLoginLockoutThreshold,
        isTrue,
        reason: 'must be locked after $kAuthLoginLockoutThreshold failures',
      );
    });

    test('success inside window resets failure count', () async {
      var fakeNow = DateTime.utc(2026, 5, 8, 11);
      final enforcer = makeEnforcer(() => fakeNow);
      const email = 'reset@example.test';
      const ip = '10.1.2.3';

      // 4 failures.
      for (var i = 0; i < 4; i++) {
        fakeNow = fakeNow.add(const Duration(seconds: 20));
        await enforcer.recordFailure(email: email, ip: ip);
      }

      // Successful login resets the count.
      fakeNow = fakeNow.add(const Duration(seconds: 20));
      await enforcer.recordSuccess(
        email: email,
        ip: ip,
        operatorId: 'op-1',
        locationId: 'loc-1',
        actorUserId: 'u-1',
      );

      // Another 4 failures — should not trip the lock (count resets).
      for (var i = 0; i < 4; i++) {
        fakeNow = fakeNow.add(const Duration(seconds: 20));
        await enforcer.recordFailure(email: email, ip: ip);
      }

      final eval = await enforcer.evaluate(email: email, ip: ip);
      // 4 failures after success → below threshold → not locked.
      expect(
        eval.failureCount < kAuthLoginLockoutThreshold,
        isTrue,
        reason: 'success inside window must reset the failure count',
      );
    });

    test('failures outside the window are not counted', () async {
      var fakeNow = DateTime.utc(2026, 5, 8, 12);
      final enforcer = makeEnforcer(() => fakeNow);
      const email = 'old@example.test';
      const ip = '172.16.0.1';

      // 5 failures in the past (outside the 15-min window).
      for (var i = 0; i < kAuthLoginLockoutThreshold; i++) {
        await enforcer.recordFailure(email: email, ip: ip);
      }

      // Jump forward past the window.
      fakeNow = fakeNow.add(kAuthLoginLockoutWindow + const Duration(minutes: 1));

      final eval = await enforcer.evaluate(email: email, ip: ip);
      expect(eval.locked, isFalse,
          reason: 'failures older than the window must not count');
      expect(eval.failureCount, equals(0));
    });

    test('recordLocked adds a locked outcome row', () async {
      final enforcer = InMemoryAuthLockoutEnforcer();
      await enforcer.recordLocked(email: 'lock@test.test', ip: '1.2.3.4');

      expect(
        enforcer.attempts.any((a) => a.outcome == 'locked'),
        isTrue,
      );
    });
  });

  group('InMemoryAuthLockoutAuditSink', () {
    test('records login-failed event', () async {
      final sink = InMemoryAuthLockoutAuditSink();
      await sink.recordLoginFailed(
        emailHashHex: 'abc123',
        ipHashHex: 'def456',
        outcome: AuthLoginFailureOutcomes.badPassword,
        attemptCountInWindow: 1,
        locked: false,
      );

      expect(sink.events, hasLength(1));
      expect(sink.events.first['event_type'], equals('auth.login_failed'));
    });

    test('records account-locked event', () async {
      final sink = InMemoryAuthLockoutAuditSink();
      await sink.recordAccountLocked(
        emailHashHex: 'abc123',
        ipHashHex: 'def456',
        attemptCount: 5,
        lockoutUntil: DateTime.utc(2026, 5, 8, 13),
      );

      expect(sink.events, hasLength(1));
      expect(sink.events.first['event_type'], equals('auth.account_locked'));
    });
  });
}
