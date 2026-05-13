// Lane C C-2-D — vendor sync outage detector.
//
// First-failure-of-outage state machine that gates the
// `vendor_sync_error_alert` email. The polling tier
// (`tool/integration_sync_worker`) writes per-tick
// `connector_sync_log` rows with `event_kind = 'poll_error'`
// whenever a vendor adapter fails; a naive per-row email would
// spam the operator on every transient hiccup. This detector
// turns that stream into "one email per outage".
//
// State machine (per `(operator_id, location_id, connection_id)`):
//
//   * No state row + poll_success           → no-op.
//   * No state row + 1..N-1 poll_errors     → INSERT state row with
//                                             consecutive_failure_count
//                                             = current streak length;
//                                             notified_at = NULL.
//   * No state row + ≥N consecutive errors  → INSERT state row;
//                                             enqueue email; stamp
//                                             notified_at.
//   * Existing state row + poll_error       → UPDATE
//                                             consecutive_failure_count
//                                             += 1; if threshold
//                                             newly crossed and
//                                             notified_at IS NULL,
//                                             enqueue email + stamp.
//   * Existing state row, notified_at set   → no-op on additional
//     + poll_error                            poll_errors (one email
//                                             per outage window).
//   * Existing state row + poll_success     → DELETE state row
//                                             (outage recovered).
//   * State row deleted, then another      → fresh outage; a new
//     streak begins                          state row is created
//                                             and a new email
//                                             eventually fires once
//                                             the threshold is hit.
//
// Threshold defaults (V1):
//
//   * N = 3 consecutive `poll_error` rows. Mirrors the
//     auto-disable cap threshold the OAuth refresh worker uses in
//     `tool/oauth_refresh_worker/main.dart`. Three ticks at the
//     production 5-minute poll cadence ≈ 15 minutes of dark data
//     before the operator is paged — short enough to be
//     actionable, long enough to ride out transient network /
//     vendor flaps.
//   * M = 30 minutes lookback window. The detector looks at the
//     most recent `connector_sync_log` rows for the connection;
//     rows older than 30 minutes are considered stale and do not
//     count toward the consecutive-failure streak. Production
//     adapters poll every 5 minutes, so 30 minutes is ≈ 6 ticks
//     — comfortably bigger than the failure threshold so a slow
//     poll cadence does not accidentally reset the streak.
//
// Idempotency / retry posture:
//
//   * Email enqueue + notified_at stamp run inside the SAME
//     tenant-scoped transaction the polling tick already
//     established. A crash between the INSERT into email_outbox
//     and the UPDATE on vendor_sync_outage_state rolls both back
//     (no orphaned email + no double notification).
//   * The dispatcher's idempotency-key for the email is stable
//     per `(operator_id, connection_id, outage_started_at)` so a
//     replayed detector call within the same outage window short-
//     circuits at the email_outbox level too (defence in depth).
//   * `notified_at IS NOT NULL` is the load-bearing flag: the
//     detector returns "no email" without inspecting the log when
//     the current outage is already notified.
//
// Banned items posture (CLAUDE.md / Hard Promises):
//   * No raw `package:postgres` import here — the repository seams
//     keep this file SQLite-and-Postgres-agnostic. Only files under
//     `lib/infrastructure/persistence/postgres/` (plus the proxy
//     bootstrap shim) bind the seams to the Postgres pool. CI lint
//     (`tool/postgres_import_lint.dart`) enforces.
//   * No tracker updates — this lane only ships the detector +
//     wiring.
//   * Operator-facing copy lives in
//     `tool/advisor_proxy/email_templates/vendor_sync_error_alert.md`;
//     this file owns no operator-facing text.

import 'package:meta/meta.dart';

/// One row read from `public.connector_sync_log` ordered newest-first.
/// The detector only needs the columns the state-machine inspects.
@immutable
class SyncLogEntry {
  const SyncLogEntry({
    required this.eventKind,
    required this.occurredAt,
    this.errorMessage,
  });

  /// `connector_sync_log.event_kind`. The detector only walks
  /// `poll_success` and `poll_error`; other kinds are ignored.
  final String eventKind;

  /// `connector_sync_log.occurred_at` (UTC).
  final DateTime occurredAt;

  /// `connector_sync_log.error_message`. Populated on `poll_error`
  /// rows; surfaced to the email body via the `errorSummary`
  /// template variable.
  final String? errorMessage;
}

/// Current state row from `public.vendor_sync_outage_state`. Returned
/// by [VendorSyncOutageStateRepository.fetchForConnection] as `null`
/// when no row exists.
@immutable
class VendorSyncOutageStateRow {
  const VendorSyncOutageStateRow({
    required this.outageStartedAt,
    required this.consecutiveFailureCount,
    this.notifiedAt,
    this.lastErrorMessage,
  });

  /// Timestamp of the FIRST poll_error in the streak that justified
  /// the outage row.
  final DateTime outageStartedAt;

  /// Count of consecutive poll_error rows observed since the last
  /// poll_success.
  final int consecutiveFailureCount;

  /// When the vendor_sync_error_alert email was enqueued for the
  /// current outage window. `null` while the streak is being
  /// observed but has not yet crossed the threshold.
  final DateTime? notifiedAt;

  /// Most recent error message surfaced from connector_sync_log.
  final String? lastErrorMessage;

  /// Convenience predicate the detector uses to short-circuit when
  /// the current outage window already produced an email.
  bool get isAlreadyNotified => notifiedAt != null;
}

/// Repository seam — read most-recent connector_sync_log entries +
/// upsert / delete the per-connection outage state row. Production
/// binds this to a Postgres-backed implementation under
/// `lib/infrastructure/persistence/postgres/`; tests pass an
/// in-memory fake.
abstract class VendorSyncOutageStateRepository {
  /// Returns the most-recent `connector_sync_log` rows for
  /// [connectionId] ordered newest-first, bounded by [lookback]. The
  /// detector walks the result to compute the consecutive-failure
  /// streak.
  ///
  /// Production query (per-tenant, RLS engaged):
  ///
  ///     SELECT event_kind, occurred_at, error_message
  ///       FROM public.connector_sync_log
  ///      WHERE operator_id = @operator_id
  ///        AND connection_id = @connection_id
  ///        AND occurred_at >= now() - @lookback
  ///      ORDER BY occurred_at DESC
  ///      LIMIT @limit;
  Future<List<SyncLogEntry>> fetchRecentSyncLogEntries({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required Duration lookback,
    required int limit,
  });

  /// Returns the current `vendor_sync_outage_state` row for the
  /// connection, or `null` when no row exists (no in-flight outage).
  Future<VendorSyncOutageStateRow?> fetchForConnection({
    required String operatorId,
    required String locationId,
    required String connectionId,
  });

  /// INSERT or UPDATE the per-connection state row. The detector
  /// supplies the row fields; production translates this to an
  /// `INSERT ... ON CONFLICT (connection_id) DO UPDATE SET ...`
  /// inside the existing tenant transaction.
  Future<void> upsert({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required DateTime outageStartedAt,
    required int consecutiveFailureCount,
    DateTime? notifiedAt,
    String? lastErrorMessage,
  });

  /// DELETE the state row for the connection. Called when a
  /// `poll_success` arrives and the prior streak has cleared.
  Future<void> clearForConnection({
    required String operatorId,
    required String locationId,
    required String connectionId,
  });
}

/// Outcome of a single [VendorSyncOutageDetector.observe] call. The
/// polling tier does not branch on the outcome; tests + future
/// observability surfaces use it to assert the detector's decision.
@immutable
class OutageDetectionOutcome {
  const OutageDetectionOutcome({
    required this.action,
    this.outageStartedAt,
    this.consecutiveFailureCount,
    this.errorSummary,
  });

  /// What the detector decided to do for this observation.
  final OutageDetectionAction action;

  /// `outage_started_at` value persisted (only set when action is
  /// `recordedFailure` or `enqueuedEmail`).
  final DateTime? outageStartedAt;

  /// The streak length the detector observed at decision time.
  final int? consecutiveFailureCount;

  /// Error message threaded into the email body (only set when
  /// `action == enqueuedEmail`).
  final String? errorSummary;
}

/// Action taxonomy. Stable strings used in observability logs.
enum OutageDetectionAction {
  /// No streak observed — no-op.
  noOp,

  /// poll_success arrived; any prior state row was cleared.
  clearedRecovery,

  /// A poll_error row was observed but the streak has not yet
  /// crossed the threshold. State row recorded; no email.
  recordedFailure,

  /// The streak crossed the threshold AND no prior email landed for
  /// the current outage window. Email enqueued; notified_at stamped.
  enqueuedEmail,

  /// The streak is still in failure mode and an email already
  /// landed for the current outage window. No-op.
  alreadyNotified,
}

/// Seam the detector calls to enqueue the
/// `vendor_sync_error_alert` email. Production binds this to a
/// repository-backed implementation that INSERTs into
/// `public.email_outbox`; tests pass an in-memory fake.
///
/// The seam is intentionally narrow (no email-rendering / no
/// recipient-resolution embedded here): all of that lives in the
/// companion `VendorSyncErrorAlertDispatcher` so the detector
/// stays a pure state machine.
typedef VendorSyncErrorAlertEnqueueSeam = Future<void> Function({
  required String operatorId,
  required String locationId,
  required String connectionId,
  required DateTime outageStartedAt,
  required String? errorSummary,
});

/// Pure state machine. Construction is dependency-injected so tests
/// pass fakes for every seam.
class VendorSyncOutageDetector {
  VendorSyncOutageDetector({
    required VendorSyncOutageStateRepository repository,
    required VendorSyncErrorAlertEnqueueSeam enqueueAlert,
    int failureThreshold = kDefaultFailureThreshold,
    Duration lookbackWindow = kDefaultLookbackWindow,
    int lookbackEntryLimit = kDefaultLookbackEntryLimit,
    DateTime Function()? now,
  })  : assert(failureThreshold > 0,
            'failureThreshold must be positive'),
        assert(lookbackWindow > Duration.zero,
            'lookbackWindow must be positive'),
        assert(lookbackEntryLimit >= failureThreshold,
            'lookbackEntryLimit must be at least the failure threshold'),
        _repository = repository,
        _enqueueAlert = enqueueAlert,
        _failureThreshold = failureThreshold,
        _lookbackWindow = lookbackWindow,
        _lookbackEntryLimit = lookbackEntryLimit,
        _now = now ?? DateTime.now;

  /// V1 default: 3 consecutive `poll_error` rows trigger the email.
  /// Mirrors the auto-disable cap from the OAuth refresh worker.
  static const int kDefaultFailureThreshold = 3;

  /// V1 default: only consider sync log rows from the last 30
  /// minutes. The production polling cadence is 5 minutes, so 30
  /// minutes ≈ 6 ticks — comfortably bigger than the failure
  /// threshold.
  static const Duration kDefaultLookbackWindow = Duration(minutes: 30);

  /// V1 default: read at most 20 log rows per detector invocation.
  /// Production poll cadence is 5 minutes so this comfortably
  /// covers the lookback window (6 ticks worst case). Bounded so a
  /// runaway log table cannot blow up the detector's working set.
  static const int kDefaultLookbackEntryLimit = 20;

  /// Catalog event_key for observability logs. Constant so the
  /// trigger site and consumers share the same string verbatim.
  static const String kVendorSyncOutageEventKey = 'notif.vendor.sync_outage';

  final VendorSyncOutageStateRepository _repository;
  final VendorSyncErrorAlertEnqueueSeam _enqueueAlert;
  final int _failureThreshold;
  final Duration _lookbackWindow;
  final int _lookbackEntryLimit;
  final DateTime Function() _now;

  /// Observe the latest tick result for [connectionId] and decide
  /// whether to enqueue the outage email. Called by the polling
  /// tier AFTER the per-tick `connector_sync_log` row has been
  /// inserted, so the log read inside the detector sees the row
  /// that just landed.
  ///
  /// [latestEventKind] short-circuits the common `poll_success`
  /// case without touching the state table: a healthy tick clears
  /// any prior outage state. Other kinds (`poll_error`,
  /// `auth_refresh_failed`, etc.) drive the state machine through
  /// the repository read path.
  Future<OutageDetectionOutcome> observe({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String latestEventKind,
  }) async {
    if (latestEventKind == 'poll_success') {
      return _handleSuccess(
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
      );
    }
    if (!_isFailureKind(latestEventKind)) {
      // Sanity-drop / vendor_not_registered / cadence-resolver rows
      // do not affect the outage state machine.
      return const OutageDetectionOutcome(action: OutageDetectionAction.noOp);
    }
    return _handleFailure(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
    );
  }

  Future<OutageDetectionOutcome> _handleSuccess({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) async {
    final existing = await _repository.fetchForConnection(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
    );
    if (existing == null) {
      return const OutageDetectionOutcome(action: OutageDetectionAction.noOp);
    }
    // Streak broken by a successful tick. Wipe the state so the
    // next outage starts fresh (with a fresh outage_started_at +
    // notified_at = NULL window).
    await _repository.clearForConnection(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
    );
    return const OutageDetectionOutcome(
      action: OutageDetectionAction.clearedRecovery,
    );
  }

  Future<OutageDetectionOutcome> _handleFailure({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) async {
    final entries = await _repository.fetchRecentSyncLogEntries(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      lookback: _lookbackWindow,
      limit: _lookbackEntryLimit,
    );

    // Compute the consecutive-failure streak walking newest-first.
    // The streak ends at the first poll_success (or at the lookback
    // boundary). Non-failure / non-success rows are skipped
    // entirely (they neither contribute to the streak nor break it).
    var streak = 0;
    String? latestErrorMessage;
    DateTime? streakOldestFailureAt;
    for (final entry in entries) {
      if (entry.eventKind == 'poll_success') break;
      if (!_isFailureKind(entry.eventKind)) continue;
      streak += 1;
      latestErrorMessage ??= entry.errorMessage;
      streakOldestFailureAt = entry.occurredAt;
    }

    if (streak == 0) {
      // The latest event kind was a failure but the lookback table
      // did not surface it (race between the per-tick INSERT and
      // this read). Treat as a no-op; the next observation will
      // pick up the row.
      return const OutageDetectionOutcome(action: OutageDetectionAction.noOp);
    }

    final existing = await _repository.fetchForConnection(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
    );

    if (existing != null && existing.isAlreadyNotified) {
      // Email already landed for the current outage window; this
      // is the load-bearing idempotency check. Keep the state row
      // current (consecutive_failure_count grows; last error
      // message refreshes) so an observability scan reflects the
      // ongoing outage, but do NOT re-enqueue the email.
      await _repository.upsert(
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        outageStartedAt: existing.outageStartedAt,
        consecutiveFailureCount: streak,
        notifiedAt: existing.notifiedAt,
        lastErrorMessage: latestErrorMessage ?? existing.lastErrorMessage,
      );
      return OutageDetectionOutcome(
        action: OutageDetectionAction.alreadyNotified,
        outageStartedAt: existing.outageStartedAt,
        consecutiveFailureCount: streak,
        errorSummary: latestErrorMessage ?? existing.lastErrorMessage,
      );
    }

    // The outage_started_at is the OLDEST failure in the current
    // streak: stable across retries (re-running the detector with
    // the same log rows produces the same outage_started_at).
    final outageStartedAt =
        streakOldestFailureAt ?? existing?.outageStartedAt ?? _now().toUtc();

    if (streak < _failureThreshold) {
      // Streak is real but below threshold. Record the state so
      // the next failure has continuity; no email yet.
      await _repository.upsert(
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        outageStartedAt: outageStartedAt,
        consecutiveFailureCount: streak,
        notifiedAt: null,
        lastErrorMessage: latestErrorMessage,
      );
      return OutageDetectionOutcome(
        action: OutageDetectionAction.recordedFailure,
        outageStartedAt: outageStartedAt,
        consecutiveFailureCount: streak,
        errorSummary: latestErrorMessage,
      );
    }

    // Threshold crossed and no email has landed for this outage
    // window. Enqueue + stamp inside the SAME tenant transaction
    // the polling tick already established: a crash between the
    // two writes rolls both back, so we never emit an email
    // without a matching `notified_at` stamp.
    final notifiedAt = _now().toUtc();
    await _enqueueAlert(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      outageStartedAt: outageStartedAt,
      errorSummary: latestErrorMessage,
    );
    await _repository.upsert(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      outageStartedAt: outageStartedAt,
      consecutiveFailureCount: streak,
      notifiedAt: notifiedAt,
      lastErrorMessage: latestErrorMessage,
    );

    return OutageDetectionOutcome(
      action: OutageDetectionAction.enqueuedEmail,
      outageStartedAt: outageStartedAt,
      consecutiveFailureCount: streak,
      errorSummary: latestErrorMessage,
    );
  }

  /// Failure-kind taxonomy. Matches the `connector_sync_log.event_kind`
  /// CHECK constraint from `db/migrations/202605040000_phase_8_0_integration_framework.sql`.
  /// `auth_refresh_failed` is treated as a failure because a refresh
  /// failure forces the next poll to fail too; including it lets the
  /// detector page the operator one tick earlier when token rot is
  /// the root cause.
  static bool _isFailureKind(String eventKind) {
    return eventKind == 'poll_error' ||
        eventKind == 'auth_refresh_failed' ||
        eventKind == 'webhook_rejected';
  }
}
