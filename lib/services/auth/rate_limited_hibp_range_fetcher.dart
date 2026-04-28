// Phase 9 live-closeout B14 - Defense-in-depth HIBP rate limiter.
//
// HIBP's "Acceptable Use" policy + the Phase 9 plan call out a
// 100-requests-per-minute-per-IP cap. Cloud Armor on the proxy's
// inbound side handles per-client-IP shaping; this Dart-side
// limiter wraps the outbound `HibpRangeFetcher` so even a runaway
// internal caller cannot exceed the per-process cap.
//
// Defaults: 100 requests / 60s. When the cap is hit the wrapped
// fetcher throws [HibpRateLimitExceeded]; the
// [HibpPwnedPasswordScreener] maps that into
// [PwnedPasswordResult.screenerUnavailable] (the existing failure
// mode), so the user-visible behavior is identical to a transient
// HIBP outage. The proxy emits the same `auth.hibp_unavailable`
// audit event for both cases — risk + ops can review the rate-limit
// distinct via the `payload.cause` field.

import 'hibp_pwned_password_screener.dart';

class HibpRateLimitExceeded implements Exception {
  const HibpRateLimitExceeded();

  @override
  String toString() =>
      'HibpRateLimitExceeded: per-process HIBP rate cap reached';
}

/// Wraps another [HibpRangeFetcher] with a sliding-window per-process
/// rate cap. The inner fetcher is only called when the cap allows.
class RateLimitedHibpRangeFetcher implements HibpRangeFetcher {
  RateLimitedHibpRangeFetcher({
    required HibpRangeFetcher inner,
    Duration window = const Duration(minutes: 1),
    int maxRequestsPerWindow = defaultMaxRequestsPerMinute,
    DateTime Function()? now,
  }) : _inner = inner,
       _window = window,
       _maxPerWindow = maxRequestsPerWindow,
       _now = now ?? DateTime.now;

  /// HIBP "Acceptable Use" + plan-locked default: 100 requests
  /// per minute per IP. The Dart-side cap matches as a defense in
  /// depth (Cloud Armor still enforces on the inbound side).
  static const int defaultMaxRequestsPerMinute = 100;

  final HibpRangeFetcher _inner;
  final Duration _window;
  final int _maxPerWindow;
  final DateTime Function() _now;

  /// Sliding window of the most recent request timestamps.
  final List<DateTime> _recent = <DateTime>[];

  @override
  Future<String> fetchRange(String hexPrefix) async {
    final now = _now();
    final cutoff = now.subtract(_window);
    _recent.removeWhere((ts) => ts.isBefore(cutoff));
    if (_recent.length >= _maxPerWindow) {
      throw const HibpRateLimitExceeded();
    }
    _recent.add(now);
    return _inner.fetchRange(hexPrefix);
  }
}
