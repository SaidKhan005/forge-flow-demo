// Phase 9.8 - GDPR right-to-erasure (redact-don't-delete).
//
// Locked posture from the decision lock + plan:
//
//   * Redact PII columns; preserve operational + audit records
//     under GDPR Art. 17(3).
//   * Paired-approval: two F&F super_admin users with fresh-MFA on
//     both before the erasure can run.
//   * Erasure is an absorbing path — no rollback once executed.
//   * Hard-delete (legal-hold release scenarios) is NOT exposed
//     through this service; requires manual SQL with explicit
//     legal-team sign-off.
//   * Pending-erasure approvals expire after [defaultApprovalMaxAge]
//     (CODE_HEALTH L11). An approval older than the window cannot be
//     used to execute the erasure; the pair must re-approve. Per
//     deployment override via env var `GDPR_APPROVAL_MAX_AGE_DAYS`.
//
// The service is pure logic + a redaction template the proxy
// applies inside an `OperatorScopedRepository.withSystem` block
// (admin BYPASSRLS path with audit). Database writes themselves
// happen server-side once the proxy has the `package:postgres`
// binding from 9.2.

import 'dart:io' show Platform;

import '../../auth/user_lifecycle.dart';

class ErasureRequest {
  ErasureRequest({
    required this.requestId,
    required this.targetUserId,
    required this.targetOperatorId,
    required this.requestedBy,
    required this.requestedByRoles,
    required this.reason,
    required this.requestedAt,
    this.firstApprovalBy,
    this.firstApprovalAt,
    this.secondApprovalBy,
    this.secondApprovalAt,
    this.executedAt,
    this.cancelledAt,
  });

  final String requestId;
  final String targetUserId;
  final String targetOperatorId;
  final String requestedBy;
  final Set<String> requestedByRoles;
  final String reason;
  final DateTime requestedAt;

  String? firstApprovalBy;
  DateTime? firstApprovalAt;
  String? secondApprovalBy;
  DateTime? secondApprovalAt;
  DateTime? executedAt;
  DateTime? cancelledAt;

  bool get isExecuted => executedAt != null;
  bool get isCancelled => cancelledAt != null;
  bool get isPending => !isExecuted && !isCancelled;
  bool get isApprovedByPair =>
      firstApprovalBy != null && secondApprovalBy != null;
}

class ErasureError implements Exception {
  ErasureError(this.message);

  final String message;

  @override
  String toString() => 'ErasureError: $message';
}

/// Outcome of [GdprErasureService.executeErasure].
class ErasureExecutionResult {
  const ErasureExecutionResult({
    required this.targetUserId,
    required this.priorStatus,
    required this.newStatus,
    required this.redactionPayload,
  });

  final String targetUserId;
  final UserStatus priorStatus;
  final UserStatus newStatus;
  final Map<String, Object?> redactionPayload;
}

class GdprErasureService {
  GdprErasureService({
    DateTime Function()? now,
    Duration? approvalMaxAge,
  })  : _now = now ?? DateTime.now,
        _approvalMaxAge = approvalMaxAge ?? _resolveApprovalMaxAge();

  /// Default per-approval expiry window. Operators with stricter privacy
  /// posture override via `GDPR_APPROVAL_MAX_AGE_DAYS`.
  static const Duration defaultApprovalMaxAge = Duration(days: 14);

  /// Env var override for the approval expiry window (in days).
  static const String approvalMaxAgeEnvVar = 'GDPR_APPROVAL_MAX_AGE_DAYS';

  final DateTime Function() _now;
  final Duration _approvalMaxAge;

  /// Effective approval expiry window for this service instance.
  Duration get approvalMaxAge => _approvalMaxAge;

  static Duration _resolveApprovalMaxAge() {
    // CODE_HEALTH L11: configurable per-deployment. Falls back to the
    // 14-day default when the env var is unset / non-positive / unparsable.
    String? raw;
    try {
      raw = Platform.environment[approvalMaxAgeEnvVar];
    } catch (_) {
      // Platform.environment can throw on stripped runtimes (e.g. browser);
      // that's expected — use the default.
      return defaultApprovalMaxAge;
    }
    if (raw == null) return defaultApprovalMaxAge;
    final parsed = int.tryParse(raw.trim());
    if (parsed == null || parsed <= 0) return defaultApprovalMaxAge;
    return Duration(days: parsed);
  }

  /// Records that [approverUserId] (with [approverRoles]) approved
  /// the request. Throws when:
  ///   * approver is not a super_admin
  ///   * approver is the requester (no self-approval)
  ///   * approver already approved (no double-counting)
  ///   * pair already complete
  ///   * request already executed / cancelled
  void recordApproval(
    ErasureRequest request, {
    required String approverUserId,
    required Iterable<String> approverRoles,
  }) {
    if (!request.isPending) {
      throw ErasureError('request is no longer pending');
    }
    if (!_isSuperAdmin(approverRoles)) {
      throw ErasureError('approver must hold super_admin');
    }
    if (approverUserId == request.requestedBy) {
      throw ErasureError(
        'approver may not be the requester (no self-approval)',
      );
    }
    if (request.firstApprovalBy == approverUserId ||
        request.secondApprovalBy == approverUserId) {
      throw ErasureError('approver already counted for this request');
    }
    final now = _now();
    if (request.firstApprovalBy == null) {
      request.firstApprovalBy = approverUserId;
      request.firstApprovalAt = now;
    } else if (request.secondApprovalBy == null) {
      request.secondApprovalBy = approverUserId;
      request.secondApprovalAt = now;
    } else {
      throw ErasureError('paired approval already complete');
    }
  }

  /// Cancels a pending request. No-op when already cancelled / executed.
  /// Returns true iff the cancellation actually flipped state (the
  /// proxy uses this to decide whether to emit a duplicate audit row).
  bool cancel(ErasureRequest request, {required String cancelledBy}) {
    if (!request.isPending) return false;
    request.cancelledAt = _now();
    return true;
  }

  /// Performs the erasure. Requires:
  ///   * target user is in [UserStatus.deleted] (soft-delete is the
  ///     prerequisite — a live user cannot be erased)
  ///   * paired approval complete
  ///   * paired approvers are distinct (enforced by recordApproval)
  ///
  /// Returns the redaction payload the proxy applies to Postgres.
  /// The proxy emits `gdpr.erasure_executed` audit + the
  /// before/after diff.
  ErasureExecutionResult executeErasure(
    ErasureRequest request, {
    required UserStatus currentTargetStatus,
    required String erasureRunbookVersion,
  }) {
    if (!request.isPending) {
      throw ErasureError('request is no longer pending');
    }
    if (!request.isApprovedByPair) {
      throw ErasureError('paired approval is not complete');
    }
    // CODE_HEALTH L11: reject stale approvals. Either approval older than
    // the configured window forces the pair to re-approve. Bound to
    // `executeErasure` so a stalled request can still be cancelled, but
    // can never be executed on stale consent.
    final now = _now();
    final cutoff = now.subtract(_approvalMaxAge);
    final firstAt = request.firstApprovalAt;
    final secondAt = request.secondApprovalAt;
    if (firstAt != null && firstAt.isBefore(cutoff)) {
      throw ErasureError(
        'first approval is stale (older than ${_approvalMaxAge.inDays} '
        'days); approver must re-approve before erasure can execute',
      );
    }
    if (secondAt != null && secondAt.isBefore(cutoff)) {
      throw ErasureError(
        'second approval is stale (older than ${_approvalMaxAge.inDays} '
        'days); approver must re-approve before erasure can execute',
      );
    }
    if (currentTargetStatus != UserStatus.deleted) {
      throw ErasureError(
        'target user must be soft-deleted (status=deleted) before erasure; '
        'current status: $currentTargetStatus',
      );
    }
    request.executedAt = now;
    return ErasureExecutionResult(
      targetUserId: request.targetUserId,
      priorStatus: currentTargetStatus,
      newStatus: UserStatus.deleted,
      redactionPayload: ErasureRedactionTemplate.payloadFor(
        userId: request.targetUserId,
        runbookVersion: erasureRunbookVersion,
      ),
    );
  }

  static bool _isSuperAdmin(Iterable<String> roles) {
    for (final role in roles) {
      if (role.trim().toLowerCase() == 'super_admin') return true;
    }
    return false;
  }
}

/// Canonical redaction shape from the decision lock + plan. The
/// proxy maps this onto the actual Postgres UPDATE statements
/// (see `runbooks/gdpr_erasure_runbook.md` once that lands).
abstract class ErasureRedactionTemplate {
  ErasureRedactionTemplate._();

  /// Returns the structured redaction payload for [userId]. Keys
  /// are table.column targets; values are either:
  ///   - `null` to NULL the column
  ///   - a redacted string template (e.g. `redacted-{user_id}@deleted.local`)
  ///   - a `_RedactionDirective` for JSONB jsonb_set operations
  static Map<String, Object?> payloadFor({
    required String userId,
    required String runbookVersion,
  }) {
    return <String, Object?>{
      'runbook_version': runbookVersion,
      'redactions': <String, Object?>{
        'users.email': 'redacted-$userId@deleted.local',
        'users.firebase_uid_retain': true, // link integrity preserved
        'users.first_name': null,
        'users.last_name': null,
        'users.display_name': null,
        'users.avatar_url': null,
        'auth_events_audit.ip': null,
        'auth_events_audit.user_agent': null,
        'auth_events_audit.event_payload': const <String, Object?>{
          'jsonb_set': <String>['email', 'name'],
          'redaction_value': null,
        },
        'auth_sessions.ip': null,
        'auth_sessions.user_agent': null,
        'password_history.cleared': true,
        'mfa_factors.factor_metadata': const <String, Object?>{
          'jsonb_set': <String>['aaguid'],
          'redaction_value': null,
        },
      },
      'preserved_under_art_17_3': const <String>[
        'auth_events_audit.event_id',
        'auth_events_audit.actor_user_id',
        'auth_events_audit.event_type',
        'auth_events_audit.occurred_at',
      ],
    };
  }
}
