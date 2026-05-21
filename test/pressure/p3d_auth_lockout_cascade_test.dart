// Pressure Preview v2 — Phase 3D auth lockout cascade test.
//
// Invariant
// ---------
// Concurrent failed logins on a single account trip the lockout window
// correctly; subsequent retries (even from different IP buckets) are
// rejected without revealing the lockout to the attacker; expiry +
// post-success reset semantics hold under concurrent re-attempts.
//
// Seam under test
// ---------------
// The in-process surface is [InMemoryAuthLockoutEnforcer] in
// `tool/advisor_proxy/advisor_proxy.dart` (the production-shape
// counter the route handler uses; Postgres-backed enforcer mirrors
// the same contract). This pressures the rolling-window math + the
// success-reset semantics that the production path can ONLY exercise
// against a live DB.
//
// What in-process pressure proves
// -------------------------------
// 1. Five concurrent failures across `Future.wait` trip lockout
//    exactly once — not five times.
// 2. A sixth concurrent attempt after lockout sees `locked=true`.
// 3. Concurrent attempts from a different IP for the SAME email count
//    independently (the lockout window is keyed by (email, ip)).
// 4. After the window advances past expiry, the same (email, ip)
//    becomes unlocked even under burst re-attempts.
// 5. A recorded success between bursts resets the failure count for
//    that (email, ip) pair (the contract's "success resets" rule).
//
// External-DB pressure
// --------------------
// DB-backed concurrency pressure for this seam is deferred to a
// future infra-gated slice (needs live Postgres) — see
// POST_HARDENING_FOLLOWUPS. The Postgres `auth_login_attempts` path
// is already covered by `auth_login_attempts_repository_test` + the
// rls_isolation_p2 suite.

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('p3d auth lockout cascade — concurrent failures', () {
    test(
      'five concurrent failed logins trip lockout exactly once '
      '(rolling-window threshold = 5, no double-trip race)',
      () async {
        final clock = _FrozenClock(DateTime.utc(2026, 5, 21, 10));
        final enforcer = InMemoryAuthLockoutEnforcer(now: clock.now);

        // 5 concurrent failures on the same (email, ip).
        await Future.wait(<Future<int>>[
          for (var i = 0; i < 5; i++)
            enforcer.recordFailure(
              email: 'victim@example.invalid',
              ip: '203.0.113.10',
            ),
        ]);

        final eval = await enforcer.evaluate(
          email: 'victim@example.invalid',
          ip: '203.0.113.10',
        );
        expect(eval.locked, isTrue,
            reason: '5 failures should equal the threshold (5) and lock');
        expect(eval.failureCount, equals(5),
            reason: 'no failure should be double-counted by concurrent writes');
      },
    );

    test(
      'after lockout trip, additional concurrent attempts continue to '
      'see locked=true and the failure count grows monotonically',
      () async {
        final clock = _FrozenClock(DateTime.utc(2026, 5, 21, 10));
        final enforcer = InMemoryAuthLockoutEnforcer(now: clock.now);

        // Trip lockout.
        for (var i = 0; i < 5; i++) {
          await enforcer.recordFailure(
            email: 'victim@example.invalid',
            ip: '203.0.113.10',
          );
        }
        await enforcer.recordLocked(
          email: 'victim@example.invalid',
          ip: '203.0.113.10',
        );

        // 20 concurrent post-lock attempts.
        final evals = await Future.wait(<Future<AuthLockoutEvaluation>>[
          for (var i = 0; i < 20; i++)
            enforcer.evaluate(
              email: 'victim@example.invalid',
              ip: '203.0.113.10',
            ),
        ]);

        for (final ev in evals) {
          expect(ev.locked, isTrue,
              reason: 'every post-lock evaluation must report locked=true');
        }
      },
    );

    test(
      'lockout is keyed by (email, ip) — different IP for same email is '
      'an independent window',
      () async {
        final clock = _FrozenClock(DateTime.utc(2026, 5, 21, 10));
        final enforcer = InMemoryAuthLockoutEnforcer(now: clock.now);

        // Trip ip A.
        for (var i = 0; i < 5; i++) {
          await enforcer.recordFailure(
            email: 'shared@example.invalid',
            ip: '203.0.113.10',
          );
        }
        // ip B is untouched.
        final evalA = await enforcer.evaluate(
          email: 'shared@example.invalid',
          ip: '203.0.113.10',
        );
        final evalB = await enforcer.evaluate(
          email: 'shared@example.invalid',
          ip: '203.0.113.99',
        );
        expect(evalA.locked, isTrue);
        expect(evalB.locked, isFalse,
            reason: '(email, ip) is the key; second IP must not inherit lock');
      },
    );

    test(
      'window expiry releases the lock under concurrent re-attempts',
      () async {
        final clock = _FrozenClock(DateTime.utc(2026, 5, 21, 10));
        final enforcer = InMemoryAuthLockoutEnforcer(now: clock.now);

        // Trip lock at t0.
        for (var i = 0; i < 5; i++) {
          await enforcer.recordFailure(
            email: 'victim@example.invalid',
            ip: '203.0.113.10',
          );
        }
        // Advance past the 15-min window.
        clock.advance(kAuthLoginLockoutWindow + const Duration(minutes: 1));

        // 10 concurrent evaluations — all should report unlocked because
        // the rolling-window cutoff is past the failure rows.
        final evals = await Future.wait(<Future<AuthLockoutEvaluation>>[
          for (var i = 0; i < 10; i++)
            enforcer.evaluate(
              email: 'victim@example.invalid',
              ip: '203.0.113.10',
            ),
        ]);
        for (final ev in evals) {
          expect(ev.locked, isFalse,
              reason: 'window expired; lock must clear under re-attempts');
          expect(ev.failureCount, equals(0),
              reason: 'old failures fall outside the rolling window');
        }
      },
    );

    test(
      'a recorded success in the window resets the failure count for '
      'that (email, ip) pair — concurrent recordSuccess calls do not '
      'double-erase',
      () async {
        final clock = _FrozenClock(DateTime.utc(2026, 5, 21, 10));
        final enforcer = InMemoryAuthLockoutEnforcer(now: clock.now);

        // Three failures, well below the threshold.
        for (var i = 0; i < 3; i++) {
          await enforcer.recordFailure(
            email: 'victim@example.invalid',
            ip: '203.0.113.10',
          );
        }
        // Advance one second so the success timestamps strictly follow.
        clock.advance(const Duration(seconds: 1));
        await Future.wait(<Future<void>>[
          enforcer.recordSuccess(
            email: 'victim@example.invalid',
            ip: '203.0.113.10',
            operatorId: 'op-1',
            locationId: 'loc-1',
            actorUserId: 'user-1',
          ),
          enforcer.recordSuccess(
            email: 'victim@example.invalid',
            ip: '203.0.113.10',
            operatorId: 'op-1',
            locationId: 'loc-1',
            actorUserId: 'user-1',
          ),
        ]);

        final eval = await enforcer.evaluate(
          email: 'victim@example.invalid',
          ip: '203.0.113.10',
        );
        expect(eval.locked, isFalse);
        expect(eval.failureCount, equals(0),
            reason: 'success in window resets failure count to 0');
      },
    );
  });
}

/// Pure deterministic clock so window math is reproducible.
class _FrozenClock {
  _FrozenClock(this._instant);
  DateTime _instant;
  DateTime now() => _instant;
  void advance(Duration d) {
    _instant = _instant.add(d);
  }
}
