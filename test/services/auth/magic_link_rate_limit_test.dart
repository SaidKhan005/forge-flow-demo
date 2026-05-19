// B1.S8 — Magic-link / password-reset request rate-limit tests.
//
// Verifies the three rate limits on the password-reset request endpoint:
//   1. Per-email 24h cap (10 requests, existing [RollingWindowAttemptCounter]).
//   2. Per-email 5-min short window (1 request per 5 min).
//   3. Per-IP 24h cap (50 requests).
//
// All three use [RollingWindowAttemptCounter] with different keys and windows.

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('B1.S8 rate-limit constants', () {
    test('email short window is 5 minutes', () {
      expect(kAuthPasswordResetEmailShortWindow.inMinutes, equals(5));
    });

    test('email short threshold is 1 request per window', () {
      expect(kAuthPasswordResetEmailShortThreshold, equals(1));
    });

    test('IP window is 24 hours', () {
      expect(kAuthPasswordResetIpWindow.inHours, equals(24));
    });

    test('IP threshold is 50 requests per window', () {
      expect(kAuthPasswordResetIpThreshold, equals(50));
    });

    test('email 24h cap remains 10 requests', () {
      expect(kAuthPasswordResetThreshold, equals(10));
    });
  });

  group('RollingWindowAttemptCounter — per-email short window', () {
    test('allows first request within the window', () {
      final fakeNow = DateTime.utc(2026, 5, 8, 9);
      final counter = RollingWindowAttemptCounter(
        window: kAuthPasswordResetEmailShortWindow,
        now: () => fakeNow,
      );
      final emailHash = hashAuthEmailHex('user@example.test');

      final count = counter.countInWindow(emailHash);
      expect(count, equals(0), reason: 'no prior attempts');
    });

    test('blocks second request within 5-min window', () {
      var fakeNow = DateTime.utc(2026, 5, 8, 9);
      final counter = RollingWindowAttemptCounter(
        window: kAuthPasswordResetEmailShortWindow,
        now: () => fakeNow,
      );
      final emailHash = hashAuthEmailHex('op@example.test');

      // First request.
      counter.incrementAndCount(emailHash);

      // Advance 2 minutes — still within the 5-min window.
      fakeNow = fakeNow.add(const Duration(minutes: 2));
      final count = counter.countInWindow(emailHash);
      expect(
        count,
        greaterThanOrEqualTo(kAuthPasswordResetEmailShortThreshold),
        reason: 'should be at or above threshold',
      );
    });

    test('allows again after short window elapses', () {
      var fakeNow = DateTime.utc(2026, 5, 8, 9, 30);
      final counter = RollingWindowAttemptCounter(
        window: kAuthPasswordResetEmailShortWindow,
        now: () => fakeNow,
      );
      final emailHash = hashAuthEmailHex('recover@example.test');

      counter.incrementAndCount(emailHash);

      // Jump past the 5-min window.
      fakeNow = fakeNow
          .add(kAuthPasswordResetEmailShortWindow + const Duration(seconds: 1));
      final countAfter = counter.countInWindow(emailHash);
      expect(countAfter, equals(0),
          reason: 'count resets after window elapses');
    });
  });

  group('RollingWindowAttemptCounter — per-IP 24h cap', () {
    test('50 requests from same IP exhaust the quota', () {
      var fakeNow = DateTime.utc(2026, 5, 8, 0);
      final counter = RollingWindowAttemptCounter(
        window: kAuthPasswordResetIpWindow,
        now: () => fakeNow,
      );
      final ipHash = hashAuthIpHex('203.0.113.5');

      for (var i = 0; i < kAuthPasswordResetIpThreshold; i++) {
        fakeNow = fakeNow.add(const Duration(minutes: 1));
        counter.incrementAndCount(ipHash);
      }

      final count = counter.countInWindow(ipHash);
      expect(
        count,
        greaterThanOrEqualTo(kAuthPasswordResetIpThreshold),
        reason: 'IP counter should be at threshold after 50 requests',
      );
    });

    test('different IPs do not share quota', () {
      var fakeNow = DateTime.utc(2026, 5, 8, 8);
      final counter = RollingWindowAttemptCounter(
        window: kAuthPasswordResetIpWindow,
        now: () => fakeNow,
      );

      final ipA = hashAuthIpHex('10.0.0.1');
      final ipB = hashAuthIpHex('10.0.0.2');

      for (var i = 0; i < kAuthPasswordResetIpThreshold; i++) {
        fakeNow = fakeNow.add(const Duration(minutes: 1));
        counter.incrementAndCount(ipA);
      }

      // IP B should still have 0 requests.
      expect(counter.countInWindow(ipB), equals(0));
    });
  });

  group('hashAuthEmailHex / hashAuthIpHex', () {
    test('email hash is deterministic and normalises case', () {
      final h1 = hashAuthEmailHex('Operator@Example.test');
      final h2 = hashAuthEmailHex('operator@example.test');
      expect(h1, equals(h2));
    });

    test('IP hash is deterministic', () {
      final h1 = hashAuthIpHex('203.0.113.42');
      final h2 = hashAuthIpHex('203.0.113.42');
      expect(h1, equals(h2));
    });

    test('different IPs produce different hashes', () {
      final h1 = hashAuthIpHex('10.0.0.1');
      final h2 = hashAuthIpHex('10.0.0.2');
      expect(h1, isNot(equals(h2)));
    });
  });
}
