// Phase 8.0 (V1 lean cut 2) — Vendor timestamp sanity guard at the
// adapter boundary.
//
// Three rules. Every inbound vendor event passes through this check
// BEFORE any canonical-fact write:
//
//   1. `closed_at >= opened_at` — drop event when the vendor emits
//      a payload whose closed_at predates its opened_at. Logged
//      with rule = `closed_before_opened`.
//   2. `opened_at <= now() + 1 hour` — drop event when the vendor
//      emits a future-dated opened_at (typical bug: clock skew or
//      misconfigured tz). Logged with rule = `opened_in_future`.
//   3. `opened_at >= now() - 90 days` UNLESS the call is flagged as
//      a deliberate backfill — drop event when the vendor emits an
//      opened_at older than 90 days. Logged with rule =
//      `opened_too_old`.
//
// The guard does NOT decide whether the event is "real"; it
// inspects only the timestamps the adapter passes through. Per
// metric_card_honesty_contract.md the operator dashboard is
// load-bearing on these signals — corrupting it with future-dated
// or out-of-order events kills the operator-trust outcome silently.
//
// Pure logic; no I/O. The webhook handler / sync worker calls
// `evaluate(...)` and the gateway writes the resulting
// `sanity_log` row + `connector_sync_log` 'sanity_drop' entry.

/// Default age cap for non-backfill events. 90 days.
const Duration kSanityMaxAge = Duration(days: 90);

/// Default future tolerance. 1 hour absorbs typical clock skew
/// without admitting wildly future-dated events.
const Duration kSanityMaxFuture = Duration(hours: 1);

/// One of the three sanity rules.
enum SanityRule {
  closedBeforeOpened,
  openedInFuture,
  openedTooOld,
}

extension SanityRuleSql on SanityRule {
  /// Mirrors the `sanity_log.rule` CHECK enum.
  String get sqlValue {
    switch (this) {
      case SanityRule.closedBeforeOpened:
        return 'closed_before_opened';
      case SanityRule.openedInFuture:
        return 'opened_in_future';
      case SanityRule.openedTooOld:
        return 'opened_too_old';
    }
  }
}

class SanityResult {
  const SanityResult.ok()
      : failed = false,
        rule = null,
        message = '',
        payloadSummary = const <String, Object?>{};

  const SanityResult.failed({
    required SanityRule this.rule,
    required this.message,
    required this.payloadSummary,
  }) : failed = true;

  final bool failed;
  final SanityRule? rule;
  final String message;
  final Map<String, Object?> payloadSummary;
}

/// The guard. Stateless; one default-constructed instance is fine.
class VendorTimestampSanity {
  const VendorTimestampSanity({
    Duration maxAge = kSanityMaxAge,
    Duration maxFuture = kSanityMaxFuture,
  })  : _maxAge = maxAge,
        _maxFuture = maxFuture;

  final Duration _maxAge;
  final Duration _maxFuture;

  /// Evaluate the three rules against [payload]'s `opened_at` /
  /// `closed_at` fields (vendor adapters normalize these into the
  /// canonical names before calling). [now] is the UTC clock at
  /// the time of evaluation — webhook handler passes
  /// `request_received_at`, polling worker passes the tick start.
  /// [isDeliberateBackfill] is the operator-initiated 60-day
  /// backfill bypass for rule 3.
  ///
  /// Vendor payloads that lack `opened_at` cannot be sanity-checked
  /// from this surface; the guard returns OK for those (the adapter
  /// is expected to refuse them at parse time — this guard is
  /// timestamp-only).
  SanityResult evaluate({
    required Map<String, Object?> payload,
    required DateTime now,
    required bool isDeliberateBackfill,
  }) {
    final opened = _readUtcInstant(payload, 'opened_at');
    final closed = _readUtcInstant(payload, 'closed_at');
    if (opened == null) {
      // Adapter parses this; the guard cannot speak about it.
      return const SanityResult.ok();
    }

    // Rule 1: closed_at >= opened_at when both present.
    if (closed != null && closed.isBefore(opened)) {
      return SanityResult.failed(
        rule: SanityRule.closedBeforeOpened,
        message:
            'closed_at ($closed) precedes opened_at ($opened); event dropped at sanity boundary.',
        payloadSummary: <String, Object?>{
          'opened_at': opened.toIso8601String(),
          'closed_at': closed.toIso8601String(),
        },
      );
    }

    // Rule 2: opened_at <= now + maxFuture.
    final futureBound = now.add(_maxFuture);
    if (opened.isAfter(futureBound)) {
      return SanityResult.failed(
        rule: SanityRule.openedInFuture,
        message:
            'opened_at ($opened) is more than ${_maxFuture.inMinutes}m '
            'in the future of now ($now); event dropped at sanity '
            'boundary.',
        payloadSummary: <String, Object?>{
          'opened_at': opened.toIso8601String(),
          'now': now.toIso8601String(),
          'future_tolerance_minutes': _maxFuture.inMinutes,
        },
      );
    }

    // Rule 3: opened_at >= now - maxAge UNLESS backfill.
    if (!isDeliberateBackfill) {
      final ageFloor = now.subtract(_maxAge);
      if (opened.isBefore(ageFloor)) {
        return SanityResult.failed(
          rule: SanityRule.openedTooOld,
          message:
              'opened_at ($opened) is older than the sanity floor '
              '($ageFloor, now - ${_maxAge.inDays}d) and the call is '
              'not flagged as a deliberate backfill; event dropped at '
              'sanity boundary.',
          payloadSummary: <String, Object?>{
            'opened_at': opened.toIso8601String(),
            'now': now.toIso8601String(),
            'max_age_days': _maxAge.inDays,
          },
        );
      }
    }

    return const SanityResult.ok();
  }

  DateTime? _readUtcInstant(Map<String, Object?> payload, String key) {
    final raw = payload[key];
    if (raw == null) return null;
    if (raw is DateTime) {
      return raw.toUtc();
    }
    if (raw is String && raw.isNotEmpty) {
      final parsed = DateTime.tryParse(raw);
      return parsed?.toUtc();
    }
    return null;
  }
}
