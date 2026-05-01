import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/circuit_breaker.dart';

void main() {
  group('CircuitBreaker — closed → open transitions', () {
    test('3 consecutive failures within window → open', () {
      var t = DateTime.utc(2026, 5, 1, 12);
      final breaker = CircuitBreaker(
        providerId: 'anthropic',
        clock: () => t,
      );

      expect(breaker.state, equals(CircuitState.closed));
      expect(breaker.tryAcquire(), equals(AcquireDecision.allow));

      breaker.recordFailure(FailureKind.unknown);
      expect(breaker.state, equals(CircuitState.closed));

      t = t.add(const Duration(seconds: 1));
      breaker.recordFailure(FailureKind.unknown);
      expect(breaker.state, equals(CircuitState.closed));

      t = t.add(const Duration(seconds: 1));
      breaker.recordFailure(FailureKind.unknown);
      expect(breaker.state, equals(CircuitState.open));
      expect(breaker.openedAt, equals(t));
    });

    test('failures separated by > window do not trip', () {
      var t = DateTime.utc(2026, 5, 1, 12);
      final breaker = CircuitBreaker(
        providerId: 'anthropic',
        clock: () => t,
      );

      breaker.recordFailure(FailureKind.unknown);
      t = t.add(const Duration(seconds: 70));
      breaker.recordFailure(FailureKind.unknown);
      t = t.add(const Duration(seconds: 70));
      breaker.recordFailure(FailureKind.unknown);
      // Each failure restarts the streak; counter sits at 1 forever.
      expect(breaker.state, equals(CircuitState.closed));
    });

    test('3 consecutive timeouts trip via timeout path', () {
      var t = DateTime.utc(2026, 5, 1, 12);
      // Set consecutiveFailureThreshold high so the trip can only come
      // from the timeout-specific trigger.
      final breaker = CircuitBreaker(
        providerId: 'anthropic',
        config: const CircuitBreakerConfig(
          consecutiveFailureThreshold: 999,
          timeoutTripThreshold: 3,
        ),
        clock: () => t,
      );

      breaker.recordFailure(FailureKind.timeout);
      t = t.add(const Duration(seconds: 1));
      breaker.recordFailure(FailureKind.timeout);
      expect(breaker.state, equals(CircuitState.closed));
      t = t.add(const Duration(seconds: 1));
      breaker.recordFailure(FailureKind.timeout);
      expect(breaker.state, equals(CircuitState.open));
    });

    test('non-timeout failure resets the consecutive-timeout counter', () {
      final t = DateTime.utc(2026, 5, 1, 12);
      final breaker = CircuitBreaker(
        providerId: 'anthropic',
        config: const CircuitBreakerConfig(
          consecutiveFailureThreshold: 999,
          timeoutTripThreshold: 3,
        ),
        clock: () => t,
      );

      breaker.recordFailure(FailureKind.timeout);
      breaker.recordFailure(FailureKind.timeout);
      // 5xx between timeouts breaks the consecutive timeout streak.
      breaker.recordFailure(FailureKind.http5xx);
      breaker.recordFailure(FailureKind.timeout);
      breaker.recordFailure(FailureKind.timeout);
      expect(breaker.state, equals(CircuitState.closed));
    });

    test('costBreach trips immediately', () {
      final breaker = CircuitBreaker(
        providerId: 'anthropic',
        clock: () => DateTime.utc(2026, 5, 1, 12),
      );
      breaker.recordFailure(FailureKind.costBreach);
      expect(breaker.state, equals(CircuitState.open));
    });

    test('recordSuccess resets the consecutive-failure counter', () {
      final t = DateTime.utc(2026, 5, 1, 12);
      final breaker = CircuitBreaker(
        providerId: 'anthropic',
        clock: () => t,
      );
      breaker.recordFailure(FailureKind.unknown);
      breaker.recordFailure(FailureKind.unknown);
      breaker.recordSuccess();
      breaker.recordFailure(FailureKind.unknown);
      breaker.recordFailure(FailureKind.unknown);
      expect(breaker.state, equals(CircuitState.closed));
    });
  });

  group('CircuitBreaker — open → halfOpen → closed/open', () {
    test('tryAcquire after coolDown returns allowProbe; concurrent reject', () {
      var t = DateTime.utc(2026, 5, 1, 12);
      final breaker = CircuitBreaker(
        providerId: 'anthropic',
        clock: () => t,
      );

      // Trip.
      breaker.recordFailure(FailureKind.unknown);
      breaker.recordFailure(FailureKind.unknown);
      breaker.recordFailure(FailureKind.unknown);
      expect(breaker.state, equals(CircuitState.open));

      // Within cool-down: rejected.
      t = t.add(const Duration(seconds: 10));
      expect(breaker.tryAcquire(), equals(AcquireDecision.reject));

      // At cool-down boundary: allowProbe (single canary).
      t = t.add(const Duration(seconds: 20));
      expect(breaker.tryAcquire(), equals(AcquireDecision.allowProbe));
      expect(breaker.state, equals(CircuitState.halfOpen));

      // Concurrent caller during probe: rejected.
      expect(breaker.tryAcquire(), equals(AcquireDecision.reject));
    });

    test('probe success → closed', () {
      var t = DateTime.utc(2026, 5, 1, 12);
      final breaker = CircuitBreaker(
        providerId: 'anthropic',
        clock: () => t,
      );
      breaker.recordFailure(FailureKind.unknown);
      breaker.recordFailure(FailureKind.unknown);
      breaker.recordFailure(FailureKind.unknown);
      t = t.add(const Duration(seconds: 30));
      expect(breaker.tryAcquire(), equals(AcquireDecision.allowProbe));
      breaker.recordSuccess();
      expect(breaker.state, equals(CircuitState.closed));
      expect(breaker.openedAt, isNull);

      // After probe-close, normal traffic flows again.
      expect(breaker.tryAcquire(), equals(AcquireDecision.allow));
    });

    test('probe failure → open with new openedAt and fresh cool-down', () {
      var t = DateTime.utc(2026, 5, 1, 12);
      final breaker = CircuitBreaker(
        providerId: 'anthropic',
        clock: () => t,
      );
      breaker.recordFailure(FailureKind.unknown);
      breaker.recordFailure(FailureKind.unknown);
      breaker.recordFailure(FailureKind.unknown);
      final firstOpen = breaker.openedAt;

      t = t.add(const Duration(seconds: 30));
      expect(breaker.tryAcquire(), equals(AcquireDecision.allowProbe));
      breaker.recordFailure(FailureKind.http5xx);

      expect(breaker.state, equals(CircuitState.open));
      expect(breaker.openedAt, isNot(equals(firstOpen)));
      expect(breaker.openedAt, equals(t));

      // Fresh cool-down starts now.
      expect(breaker.tryAcquire(), equals(AcquireDecision.reject));
      t = t.add(const Duration(seconds: 30));
      expect(breaker.tryAcquire(), equals(AcquireDecision.allowProbe));
    });
  });

  group('CircuitBreaker — guard rails', () {
    test('recordFailure on already-open breaker is a no-op', () {
      var t = DateTime.utc(2026, 5, 1, 12);
      final breaker = CircuitBreaker(
        providerId: 'anthropic',
        clock: () => t,
      );
      breaker.recordFailure(FailureKind.unknown);
      breaker.recordFailure(FailureKind.unknown);
      breaker.recordFailure(FailureKind.unknown);
      final firstOpenedAt = breaker.openedAt;

      // Concurrent in-flight failure arriving after trip must not extend
      // the cool-down window.
      t = t.add(const Duration(seconds: 5));
      breaker.recordFailure(FailureKind.unknown);
      expect(breaker.openedAt, equals(firstOpenedAt));
    });

    test('circuitStateToWireString matches DB CHECK enum', () {
      expect(circuitStateToWireString(CircuitState.closed), equals('closed'));
      expect(circuitStateToWireString(CircuitState.open), equals('open'));
      expect(circuitStateToWireString(CircuitState.halfOpen), equals('half_open'));
    });
  });
}
