// Phase 9.4 - MFA removal service.
//
// Removing the only enrolled MFA factor downgrades account security,
// so the locked decision is to require step-up auth + a 24-hour
// delay window before the removal actually takes effect. The flow
// audits both ends:
//
//   1. `mfa_factor_revocation_initiated` event written on request.
//   2. `mfa_factor_revocation_completed` event written 24h later
//      after the cooling-off window passes.
//
// During the 24h window the user (and any admin watching the audit
// log) can cancel the removal — that path emits a
// `mfa_factor_revocation_cancelled` event.
//
// This service intentionally does not call Firebase. Phase 9.4 only
// wires the framework + state machine; the production binding to
// `firebase_auth.MultiFactor.unenroll` lands in the same follow-up
// that brings the live `firebase_auth` SDK in.

class MfaRemovalRequest {
  MfaRemovalRequest({
    required this.requestId,
    required this.userId,
    required this.factorId,
    required this.requestedAt,
    required this.executeAfter,
    required this.stepUpProofId,
    this.cancelledAt,
    this.completedAt,
  });

  final String requestId;
  final String userId;
  final String factorId;
  final DateTime requestedAt;
  final DateTime executeAfter;

  /// Identifier for the step-up proof (e.g. the
  /// `auth_events_audit.event_id` that recorded the fresh-auth
  /// challenge). The proxy demands this be present and recent
  /// before accepting the removal request.
  final String stepUpProofId;

  DateTime? cancelledAt;
  DateTime? completedAt;

  bool get isPending => cancelledAt == null && completedAt == null;
  bool get isExecutable {
    if (!isPending) return false;
    return true; // The "now passed executeAfter" check is done by the service.
  }

  bool get isCompleted => completedAt != null;
  bool get isCancelled => cancelledAt != null;
}

/// Outcome of [MfaRemovalService.executeRemoval].
sealed class MfaRemovalExecuteResult {
  const MfaRemovalExecuteResult();
}

class MfaRemovalCompleted extends MfaRemovalExecuteResult {
  const MfaRemovalCompleted(this.request);
  final MfaRemovalRequest request;
}

class MfaRemovalNotYetExecutable extends MfaRemovalExecuteResult {
  const MfaRemovalNotYetExecutable({
    required this.request,
    required this.executesAt,
  });
  final MfaRemovalRequest request;
  final DateTime executesAt;
}

class MfaRemovalAlreadyFinalized extends MfaRemovalExecuteResult {
  const MfaRemovalAlreadyFinalized(this.request);
  final MfaRemovalRequest request;
}

class MfaRemovalService {
  MfaRemovalService({
    required Duration delay,
    DateTime Function()? now,
  }) : _delay = delay,
       _now = now ?? DateTime.now;

  /// Locked decision: 24-hour delay before the removal can execute.
  static const Duration defaultDelay = Duration(hours: 24);

  final Duration _delay;
  final DateTime Function() _now;

  /// Records a removal request. Returns the request handle so the
  /// caller (proxy) can persist it and emit the
  /// `mfa_factor_revocation_initiated` audit event with the correct
  /// `executeAfter` timestamp.
  ///
  /// [stepUpProofId] is required and must be non-blank — the proxy
  /// has already verified that step-up freshness held when it
  /// produced this proof. The service does NOT re-validate the
  /// freshness; that's the proxy's responsibility.
  MfaRemovalRequest requestRemoval({
    required String requestId,
    required String userId,
    required String factorId,
    required String stepUpProofId,
  }) {
    if (stepUpProofId.trim().isEmpty) {
      throw ArgumentError.value(
        stepUpProofId,
        'stepUpProofId',
        'must be non-blank — fresh-auth proof is required for MFA removal',
      );
    }
    final now = _now();
    return MfaRemovalRequest(
      requestId: requestId,
      userId: userId,
      factorId: factorId,
      requestedAt: now,
      executeAfter: now.add(_delay),
      stepUpProofId: stepUpProofId,
    );
  }

  /// Cancels a pending removal. Idempotent — calling cancel on an
  /// already-cancelled request is a no-op; calling cancel on a
  /// completed request returns false to signal that the caller
  /// should NOT emit a cancellation audit event.
  bool cancelRemoval(MfaRemovalRequest request) {
    if (request.isCompleted) return false;
    if (request.isCancelled) return true;
    request.cancelledAt = _now();
    return true;
  }

  /// Attempts to execute the removal. Returns:
  ///
  ///   - [MfaRemovalNotYetExecutable] when the 24-hour window has
  ///     not elapsed (proxy returns a 425 / 409 to the client).
  ///   - [MfaRemovalAlreadyFinalized] when the request has already
  ///     been completed or cancelled.
  ///   - [MfaRemovalCompleted] when the removal proceeded; the
  ///     proxy then issues the actual Firebase `unenroll` call and
  ///     writes the `mfa_factor_revocation_completed` audit event.
  MfaRemovalExecuteResult executeRemoval(MfaRemovalRequest request) {
    if (!request.isPending) {
      return MfaRemovalAlreadyFinalized(request);
    }
    final now = _now();
    if (now.isBefore(request.executeAfter)) {
      return MfaRemovalNotYetExecutable(
        request: request,
        executesAt: request.executeAfter,
      );
    }
    request.completedAt = now;
    return MfaRemovalCompleted(request);
  }
}
