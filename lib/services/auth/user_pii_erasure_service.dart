// CODE_OPS_DEBT Theme B#1 - single-admin PII erasure service.
//
// Orchestrates the four moving parts of the PII erasure flow on top
// of [UserPiiErasureRepository]:
//
//   1. requestErasure   — captures a snapshot of the target user's
//                          PII and inserts a pending row in ONE
//                          tenant transaction so a parallel writer
//                          cannot mutate the user between snapshot
//                          capture and request insert.
//   2. reverseErasure   — within the grace window, mark the row
//                          reversed, restore the snapshot back onto
//                          `public.users`.
//   3. applyDuePending  — worker entrypoint: scan + apply the actual
//                          NULL-out for every row whose grace window
//                          expired.
//   4. statusFor        — read the latest erasure row for status UI.
//
// The service is deliberately repository-only: the proxy route layer
// stays responsible for permission gating, fresh-MFA, idempotency,
// and audit-log writes. This service writes the erasure ledger row
// + the user-row snapshot/restore, nothing else.
//
// Grace window: 24 hours by default; env-overridable via
// `PII_ERASURE_GRACE_PERIOD_SECONDS`. The window is captured at
// request time and stored on the row so a hot-fix to the env var
// does not change the deadline of an already-in-flight erasure.

import 'dart:io';

import '../../infrastructure/persistence/postgres/repositories/user_pii_erasure_repository.dart';

/// Returned by [UserPiiErasureService.requestErasure]. The proxy
/// route serialises [erasureId] + [gracePeriodEndsAt] into the 202
/// response so the admin shell can render the countdown chip.
class UserPiiErasureRequestResult {
  const UserPiiErasureRequestResult({
    required this.erasureId,
    required this.gracePeriodEndsAt,
  });

  final String erasureId;
  final DateTime gracePeriodEndsAt;
}

/// Outcome of [UserPiiErasureService.reverseErasure]. The proxy
/// returns 200 on [reversed] = true; 410 on [graceExpired] = true;
/// 404 otherwise.
class UserPiiErasureReverseResult {
  const UserPiiErasureReverseResult({
    required this.reversed,
    required this.graceExpired,
    this.notFound = false,
  });

  final bool reversed;
  final bool graceExpired;
  final bool notFound;
}

/// Outcome of [UserPiiErasureService.applyDuePending]. The worker
/// emits per-row apply log lines; this struct reports the batch
/// totals so the tick handler can surface a counter.
class UserPiiErasureApplyBatchResult {
  const UserPiiErasureApplyBatchResult({
    required this.scanned,
    required this.applied,
    required this.alreadyTerminal,
    required this.skippedNoLocation,
  });

  final int scanned;
  final int applied;
  final int alreadyTerminal;
  final int skippedNoLocation;
}

/// Single-admin erasure service. The proxy route layer composes this
/// service with the audit-log writer and the fresh-MFA gate; the
/// service itself is data-layer only.
class UserPiiErasureService {
  UserPiiErasureService({
    required UserPiiErasureRepository erasureRepository,
    Duration? gracePeriod,
    DateTime Function()? now,
    String Function()? erasureIdFactory,
  })  : _erasureRepository = erasureRepository,
        _gracePeriod = gracePeriod ?? _resolveGracePeriod(),
        _now = now ?? DateTime.now,
        _erasureIdFactory =
            erasureIdFactory ?? _defaultErasureIdFactory;

  /// Operator-locked default. 24 hours = 86_400 seconds.
  static const Duration defaultGracePeriod = Duration(hours: 24);

  /// Env var name. A non-numeric / non-positive value falls back to
  /// [defaultGracePeriod] so a typo never narrows the window
  /// silently.
  static const String gracePeriodEnvVarName =
      'PII_ERASURE_GRACE_PERIOD_SECONDS';

  final UserPiiErasureRepository _erasureRepository;
  final Duration _gracePeriod;
  final DateTime Function() _now;
  final String Function() _erasureIdFactory;

  /// Effective grace window for this service instance. Exposed for
  /// log lines / tests; not meant for security decisions.
  Duration get gracePeriod => _gracePeriod;

  static Duration _resolveGracePeriod() {
    String? raw;
    try {
      raw = Platform.environment[gracePeriodEnvVarName];
    } catch (_) {
      return defaultGracePeriod;
    }
    if (raw == null || raw.isEmpty) return defaultGracePeriod;
    final parsed = int.tryParse(raw.trim());
    if (parsed == null || parsed <= 0) return defaultGracePeriod;
    return Duration(seconds: parsed);
  }

  /// Captures a snapshot of the target user's PII columns and inserts
  /// a pending erasure row in ONE tenant transaction. The proxy
  /// passes the resolved tenant scope (operator + location) plus the
  /// actor user_id of the admin who initiated the request.
  ///
  /// Returns null when the target user is not found — proxy maps to
  /// 404 `user_not_found`.
  Future<UserPiiErasureRequestResult?> requestErasure({
    required String operatorId,
    required String locationId,
    required String targetUserId,
    required String requestedByUserId,
    required String businessDate,
  }) async {
    final requestedAt = _now().toUtc();
    final gracePeriodEndsAt = requestedAt.add(_gracePeriod);
    final erasureId = _erasureIdFactory();

    final row = await _erasureRepository.snapshotPiiAndInsertPending(
      erasureId: erasureId,
      operatorId: operatorId,
      locationId: locationId,
      userId: targetUserId,
      requestedByUserId: requestedByUserId,
      requestedAt: requestedAt,
      businessDate: businessDate,
      gracePeriodEndsAt: gracePeriodEndsAt,
    );
    if (row == null) return null;

    return UserPiiErasureRequestResult(
      erasureId: row.erasureId,
      gracePeriodEndsAt: row.gracePeriodEndsAt,
    );
  }

  /// Reverses an erasure within its grace window. Reads the row,
  /// extracts the captured snapshot, marks the row reversed (which
  /// also wipes `pii_snapshot` server-side), and restores the
  /// snapshot back onto `public.users`. Returns a struct describing
  /// the outcome so the proxy can map to 200 / 410 / 404.
  Future<UserPiiErasureReverseResult> reverseErasure({
    required String operatorId,
    required String locationId,
    required String targetUserId,
    required String erasureId,
    required String reversedByUserId,
    String? reversalReason,
  }) async {
    final row = await _erasureRepository.findPendingById(
      operatorId: operatorId,
      locationId: locationId,
      userId: targetUserId,
      erasureId: erasureId,
    );
    if (row == null) {
      return const UserPiiErasureReverseResult(
        reversed: false,
        graceExpired: false,
        notFound: true,
      );
    }
    if (row.isApplied || row.isReversed) {
      // Already terminal — for the reverse route, treat as expired
      // so the proxy returns 410.
      return const UserPiiErasureReverseResult(
        reversed: false,
        graceExpired: true,
      );
    }
    final reversedAt = _now().toUtc();
    if (!reversedAt.isBefore(row.gracePeriodEndsAt)) {
      return const UserPiiErasureReverseResult(
        reversed: false,
        graceExpired: true,
      );
    }

    // Capture the snapshot BEFORE markReversed wipes it.
    final snapshot = UserPiiSnapshot.fromJson(row.piiSnapshot);

    final updated = await _erasureRepository.markReversed(
      operatorId: operatorId,
      locationId: locationId,
      userId: targetUserId,
      erasureId: erasureId,
      reversedByUserId: reversedByUserId,
      reversalReason: reversalReason,
      reversedAt: reversedAt,
    );
    if (updated == 0) {
      // Race lost — another caller finalised the row first.
      return const UserPiiErasureReverseResult(
        reversed: false,
        graceExpired: true,
      );
    }

    await _erasureRepository.restoreSnapshotToUser(
      operatorId: operatorId,
      locationId: locationId,
      userId: targetUserId,
      snapshot: snapshot,
    );

    return const UserPiiErasureReverseResult(
      reversed: true,
      graceExpired: false,
    );
  }

  /// Latest erasure row for `(operatorId, targetUserId)` so the GET
  /// route can render status. Returns null when no erasure has ever
  /// been issued.
  Future<UserPiiErasureRequestRecord?> statusFor({
    required String operatorId,
    required String locationId,
    required String targetUserId,
  }) {
    return _erasureRepository.findLatestForUser(
      operatorId: operatorId,
      locationId: locationId,
      userId: targetUserId,
    );
  }

  /// Worker entrypoint. Scans for pending rows whose grace window has
  /// expired and applies the NULL-out on `public.users` for each.
  /// The scan runs through `withSystem` (forge_admin BYPASSRLS); the
  /// per-row apply runs through `withTenant` so RLS + audit
  /// attribution stays bound.
  Future<UserPiiErasureApplyBatchResult> applyDuePending({
    int batchSize = 100,
  }) async {
    final now = _now().toUtc();
    final due = await _erasureRepository.listDuePending(
      now: now,
      limit: batchSize,
    );

    var applied = 0;
    var alreadyTerminal = 0;
    var skippedNoLocation = 0;
    for (final row in due) {
      final locationId = await _erasureRepository.resolveLocationForUser(
        operatorId: row.operatorId,
        userId: row.userId,
      );
      if (locationId == null) {
        // Skip — the row will be retried on the next tick. We do
        // not stamp applied_at because we did not actually apply.
        skippedNoLocation += 1;
        continue;
      }
      final updated = await _erasureRepository.applyRowAndWipeSnapshot(
        operatorId: row.operatorId,
        locationId: locationId,
        userId: row.userId,
        erasureId: row.erasureId,
        appliedAt: now,
      );
      if (updated == 0) {
        alreadyTerminal += 1;
      } else {
        applied += 1;
      }
    }
    return UserPiiErasureApplyBatchResult(
      scanned: due.length,
      applied: applied,
      alreadyTerminal: alreadyTerminal,
      skippedNoLocation: skippedNoLocation,
    );
  }
}

String _defaultErasureIdFactory() {
  // Builds a v4-shaped lowercase string from
  // `DateTime.microsecondsSinceEpoch` so the runtime stays
  // self-contained without a uuid package dependency. Production is
  // expected to inject a real uuid factory via the constructor; tests
  // also inject deterministic ids.
  final stamp = DateTime.now()
      .microsecondsSinceEpoch
      .toRadixString(16)
      .padLeft(16, '0');
  final hex = (stamp + stamp).substring(0, 32);
  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '4${hex.substring(13, 16)}-'
      '8${hex.substring(17, 20)}-'
      '${hex.substring(20, 32)}';
}
