// Phase 10a.4 — periodic poller that drives the sync badge's
// degraded-state branch.
//
// The slice contract calls for the badge to poll
// `/v1/realtime/tripwire-status` every ~60 seconds. The badge widget
// itself is a stateless consumer of `RealtimeTripwireScope`; the
// scope's stream comes from this poller. Splitting concerns this way
// keeps the widget testable without HTTP and keeps the polling
// loop testable without Flutter.
//
// Production wiring constructs the poller with a fetcher closure
// that hits the proxy `/v1/realtime/tripwire-status` route through
// the operator app's HTTP client (Firebase bearer token if the
// route ever upgrades from unauth, or a simple GET in the current
// shape). Widget tests / demo walkthroughs bypass this entirely by
// driving the scope's stream from a controller.
//
// File stays free of `dart:io` / `sqflite` so it's reachable from
// `lib/main_operator_web.dart` (the badge ships in the operator web
// shell too).

import 'dart:async';

import 'outbox_tripwire_evaluator.dart' show OutboxTripwireStatus;

/// Default poll interval. The slice contract pins ~60 seconds; the
/// constant is exported so a future tuning pass can adjust without
/// chasing literal values.
const Duration kOutboxTripwirePollInterval = Duration(seconds: 60);

/// Function that fetches one tripwire-status snapshot. Production
/// binds this to an HTTP call against the proxy
/// `/v1/realtime/tripwire-status` route; tests bind to a closure that
/// returns a deterministic value.
typedef OutboxTripwireFetcher = Future<OutboxTripwireStatus> Function();

/// Drives a `Stream<OutboxTripwireStatus>` from a periodic call to
/// [fetcher]. The stream is broadcast so multiple subscribers (sync
/// badge + admin observability) can share the same poll cadence.
///
/// Lifecycle:
///   * `start()` runs an immediate fetch and schedules the next at
///     [interval]. Repeated calls to `start()` are no-ops while the
///     poller is already running.
///   * `dispose()` cancels the timer, closes the underlying
///     controller, and forgets any in-flight fetch result.
///
/// Error policy: a fetcher exception does NOT propagate to listeners
/// (the badge would crash mid-render). Failures are logged through
/// [onError] when supplied; the most-recent successful status stays
/// visible to subscribers until the next poll succeeds.
class OutboxTripwirePoller {
  OutboxTripwirePoller({
    required OutboxTripwireFetcher fetcher,
    Duration interval = kOutboxTripwirePollInterval,
    OutboxTripwireStatus seedStatus = OutboxTripwireStatus.green,
    void Function(Object error, StackTrace stackTrace)? onError,
  })  : _fetcher = fetcher,
        _interval = interval,
        _onError = onError {
    // Seed the latest value so a brand-new subscriber gets a sane
    // starting state instead of hanging on the first emission.
    _latest = seedStatus;
  }

  final OutboxTripwireFetcher _fetcher;
  final Duration _interval;
  final void Function(Object, StackTrace)? _onError;

  final StreamController<OutboxTripwireStatus> _controller =
      StreamController<OutboxTripwireStatus>.broadcast();
  Timer? _timer;
  bool _running = false;
  bool _disposed = false;
  late OutboxTripwireStatus _latest;

  /// Hot stream used by the sync badge scope. Late subscribers are
  /// re-seeded with [latest] via the badge's `initialStatus` so the
  /// pill never flickers to green-by-default before the first emit.
  Stream<OutboxTripwireStatus> get stream => _controller.stream;

  /// Most-recent status the poller observed. Used as the
  /// `initialStatus` when wiring the scope so the badge renders the
  /// known state immediately.
  OutboxTripwireStatus get latest => _latest;

  /// Begin polling. The first fetch fires synchronously (well, on the
  /// next microtask) so the badge sees a fresh status without waiting
  /// out the full interval.
  void start() {
    if (_running || _disposed) return;
    _running = true;
    unawaited(_pollOnce());
    _timer = Timer.periodic(_interval, (_) => unawaited(_pollOnce()));
  }

  Future<void> _pollOnce() async {
    if (_disposed) return;
    try {
      final status = await _fetcher();
      if (_disposed) return;
      _latest = status;
      if (!_controller.isClosed) _controller.add(status);
    } catch (error, stackTrace) {
      if (_onError != null) _onError(error, stackTrace);
      // Swallow — see error policy in class docs.
    }
  }

  /// Cancel the timer and close the stream. Safe to call multiple
  /// times.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _running = false;
    _timer?.cancel();
    _timer = null;
    if (!_controller.isClosed) await _controller.close();
  }
}
