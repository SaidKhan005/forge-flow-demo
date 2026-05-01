// Forge & Flow — circuit breaker state machine.
//
// Lock 7 (`docs/phases/phase_11a/phase_11a_decision_register.md:938-972`):
// per-instance in-memory v1; cross-instance Memorystore deferred to E.2b.
// v1 trigger subset: consecutive-failure window + timeout-trip-on-3rd.
// Rolling-window error rate, p99 latency, and cost-breach are deferred —
// `FailureKind.costBreach` is reserved but never raised in v1 production.
//
// Single-isolate Dart server makes the probe-slot bool flip safe. If the
// proxy ever runs multi-isolate, the probe slot needs `package:synchronized`.
//
// Block 2 v1 simplifications: 429 collapses into the trip path (no retry
// or backoff). `FailureKind.http429` exists for E.2b backoff plumbing.

/// Three-state circuit-breaker FSM for outbound provider calls.
enum CircuitState { closed, open, halfOpen }

/// Failure taxonomy for breaker decisions. Mapped from thrown exceptions
/// at the call site via `classifyLlmFailure` in `llm_provider.dart`.
enum FailureKind { http5xx, http429, timeout, costBreach, unknown }

/// Outcome of `CircuitBreaker.tryAcquire()`.
enum AcquireDecision {
  /// Closed state: normal flow.
  allow,

  /// Half-open state: caller is the canary. Exactly one canary at a time.
  allowProbe,

  /// Open or half-open with probe in flight: skip to fallback.
  reject,
}

class CircuitBreakerConfig {
  const CircuitBreakerConfig({
    this.consecutiveFailureThreshold = 3,
    this.failureWindow = const Duration(seconds: 60),
    this.coolDown = const Duration(seconds: 30),
    this.timeoutTripThreshold = 3,
  });

  final int consecutiveFailureThreshold;
  final Duration failureWindow;
  final Duration coolDown;
  final int timeoutTripThreshold;
}

DateTime _systemClock() => DateTime.now().toUtc();

class CircuitBreaker {
  CircuitBreaker({
    required this.providerId,
    this.config = const CircuitBreakerConfig(),
    DateTime Function() clock = _systemClock,
  }) : _clock = clock;

  final String providerId;
  final CircuitBreakerConfig config;
  final DateTime Function() _clock;

  CircuitState _state = CircuitState.closed;
  int _consecutiveFailures = 0;
  int _consecutiveTimeouts = 0;
  DateTime? _streakStart;
  DateTime? _openedAt;
  bool _probeInFlight = false;

  CircuitState get state => _state;
  DateTime? get openedAt => _openedAt;

  /// Atomic check-and-reserve. Mutates state if a cool-down has elapsed
  /// (open → halfOpen) and reserves the probe slot when returning
  /// `allowProbe`.
  AcquireDecision tryAcquire() {
    final now = _clock();
    if (_state == CircuitState.open) {
      if (_openedAt != null && now.difference(_openedAt!) >= config.coolDown) {
        _state = CircuitState.halfOpen;
        _probeInFlight = true;
        return AcquireDecision.allowProbe;
      }
      return AcquireDecision.reject;
    }
    if (_state == CircuitState.halfOpen) {
      if (_probeInFlight) {
        return AcquireDecision.reject;
      }
      _probeInFlight = true;
      return AcquireDecision.allowProbe;
    }
    return AcquireDecision.allow;
  }

  void recordSuccess() {
    if (_state == CircuitState.open) {
      return;
    }
    if (_state == CircuitState.halfOpen) {
      _state = CircuitState.closed;
      _openedAt = null;
      _probeInFlight = false;
    }
    _consecutiveFailures = 0;
    _consecutiveTimeouts = 0;
    _streakStart = null;
  }

  void recordFailure(FailureKind kind) {
    if (_state == CircuitState.open) {
      return;
    }
    final now = _clock();
    if (_state == CircuitState.halfOpen) {
      _state = CircuitState.open;
      _openedAt = now;
      _probeInFlight = false;
      _consecutiveFailures = 0;
      _consecutiveTimeouts = 0;
      _streakStart = null;
      return;
    }

    if (kind == FailureKind.timeout) {
      _consecutiveTimeouts += 1;
      if (_consecutiveTimeouts >= config.timeoutTripThreshold) {
        _trip(now);
        return;
      }
    } else {
      _consecutiveTimeouts = 0;
    }

    if (kind == FailureKind.costBreach) {
      _trip(now);
      return;
    }

    if (_streakStart == null ||
        now.difference(_streakStart!) > config.failureWindow) {
      _streakStart = now;
      _consecutiveFailures = 1;
    } else {
      _consecutiveFailures += 1;
    }
    if (_consecutiveFailures >= config.consecutiveFailureThreshold) {
      _trip(now);
    }
  }

  void _trip(DateTime now) {
    _state = CircuitState.open;
    _openedAt = now;
    _consecutiveFailures = 0;
    _consecutiveTimeouts = 0;
    _streakStart = null;
    _probeInFlight = false;
  }
}

/// Stable wire string for `usage_logs.circuit_state` (matches
/// migration 202604250006 CHECK constraint).
String circuitStateToWireString(CircuitState state) {
  switch (state) {
    case CircuitState.closed:
      return 'closed';
    case CircuitState.open:
      return 'open';
    case CircuitState.halfOpen:
      return 'half_open';
  }
}
