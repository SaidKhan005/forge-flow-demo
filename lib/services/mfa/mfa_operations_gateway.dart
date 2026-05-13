// Phase 9 live-closeout - proxy MFA operations gateway.
//
// This is the server-side seam used by `/v1/auth/mfa/*` routes. It composes
// Firebase TOTP enrollment, local `mfa_factors` persistence, and append-only
// audit rows. Flutter never gets database credentials.

import 'dart:math' as math;
import 'dart:typed_data';

import '../../infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/mfa_factor_removal_requests_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart';
import 'firebase_mfa_client.dart';
import 'mfa_enrollment_service.dart';
import 'mfa_removal_service.dart';

class MfaTotpBeginCommand {
  const MfaTotpBeginCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    this.authorizationIdToken = '',
    required this.userEmail,
    required this.issuerName,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String authorizationIdToken;
  final String userEmail;
  final String issuerName;
}

class MfaTotpConfirmCommand {
  const MfaTotpConfirmCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    this.authorizationIdToken = '',
    required this.factorId,
    required this.oneTimeCode,
    required this.issuerName,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String authorizationIdToken;
  final String factorId;
  final String oneTimeCode;
  final String issuerName;
}

class MfaTotpConfirmCompleted {
  const MfaTotpConfirmCompleted({required this.factorId});

  final String factorId;
}

class MfaFactorSummary {
  const MfaFactorSummary({
    required this.factorId,
    required this.factorType,
    required this.enrolledAt,
    required this.issuerLabel,
    this.lastUsedAt,
    this.recoveryCodesViewedAt,
    this.canRevoke = true,
  });

  final String factorId;
  final String factorType;
  final DateTime enrolledAt;
  final DateTime? lastUsedAt;
  final DateTime? recoveryCodesViewedAt;
  final String issuerLabel;
  final bool canRevoke;
}

class MfaListFactorsCommand {
  const MfaListFactorsCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    this.authorizationIdToken = '',
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String authorizationIdToken;
}

class MfaMarkRecoveryCodesViewedCommand {
  const MfaMarkRecoveryCodesViewedCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    this.authorizationIdToken = '',
    required this.factorId,
    required this.idempotencyKey,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String authorizationIdToken;
  final String factorId;
  final String idempotencyKey;
}

class MfaMarkRecoveryCodesViewedCompleted {
  const MfaMarkRecoveryCodesViewedCompleted({required this.viewedAt});

  final DateTime viewedAt;
}

class MfaListFactorsCompleted {
  const MfaListFactorsCompleted({
    required this.factors,
    this.removalRequests = const <MfaRemovalRequestSummary>[],
  });

  final List<MfaFactorSummary> factors;
  final List<MfaRemovalRequestSummary> removalRequests;
}

class MfaRemovalRequestSummary {
  const MfaRemovalRequestSummary({
    required this.requestId,
    required this.factorId,
    required this.status,
    required this.executeAfter,
    this.completedAt,
  });

  final String requestId;
  final String factorId;
  final String status;
  final DateTime executeAfter;
  final DateTime? completedAt;
}

class MfaRevokeFactorCommand {
  const MfaRevokeFactorCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.factorId,
    this.stepUpProofId = '',
    this.authorizationIdToken = '',
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String factorId;
  final String stepUpProofId;
  final String authorizationIdToken;
}

class MfaRevokeFactorCompleted {
  const MfaRevokeFactorCompleted({
    required this.revoked,
    this.requestId,
    this.executeAfter,
  });

  final bool revoked;
  final String? requestId;
  final DateTime? executeAfter;
}

class MfaCancelFactorRemovalCommand {
  const MfaCancelFactorRemovalCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.requestId,
    this.targetUserId,
    this.authorizationIdToken = '',
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String requestId;
  final String? targetUserId;
  final String authorizationIdToken;
}

class MfaCancelFactorRemovalCompleted {
  const MfaCancelFactorRemovalCompleted({required this.cancelled});

  final bool cancelled;
}

class MfaRevokeUserFactorsCommand {
  const MfaRevokeUserFactorsCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.targetUserId,
    this.stepUpProofId = '',
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String targetUserId;
  final String stepUpProofId;
}

class MfaRevokeUserFactorsCompleted {
  const MfaRevokeUserFactorsCompleted({
    required this.requestedCount,
    required this.requestIds,
    this.executeAfter,
  });

  final int requestedCount;
  final List<String> requestIds;
  final DateTime? executeAfter;
}

class MfaOperationRejected implements Exception {
  const MfaOperationRejected({
    required this.code,
    required this.message,
    this.statusCode = 422,
    this.retryAfter,
    this.resetsAt,
  });

  final String code;
  final String message;
  final int statusCode;
  final DateTime? retryAfter;
  final DateTime? resetsAt;

  @override
  String toString() => 'MfaOperationRejected(code: $code, status: $statusCode)';
}

abstract class MfaOperationsGateway {
  Future<TotpEnrollmentSetup> beginTotpEnrollment(MfaTotpBeginCommand command);

  Future<MfaListFactorsCompleted> listFactors(MfaListFactorsCommand command);

  Future<MfaRevokeFactorCompleted> revokeFactor(MfaRevokeFactorCommand command);

  Future<MfaMarkRecoveryCodesViewedCompleted> markRecoveryCodesViewed(
    MfaMarkRecoveryCodesViewedCommand command,
  );

  Future<MfaCancelFactorRemovalCompleted> cancelFactorRemoval(
    MfaCancelFactorRemovalCommand command,
  );

  Future<MfaRevokeUserFactorsCompleted> revokeUserFactors(
    MfaRevokeUserFactorsCommand command,
  );

  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  );
}

class ScaffoldFailingMfaOperationsGateway implements MfaOperationsGateway {
  const ScaffoldFailingMfaOperationsGateway();

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment(MfaTotpBeginCommand command) {
    throw StateError(_message);
  }

  @override
  Future<MfaListFactorsCompleted> listFactors(MfaListFactorsCommand command) {
    throw StateError(_message);
  }

  @override
  Future<MfaRevokeFactorCompleted> revokeFactor(
    MfaRevokeFactorCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<MfaMarkRecoveryCodesViewedCompleted> markRecoveryCodesViewed(
    MfaMarkRecoveryCodesViewedCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<MfaCancelFactorRemovalCompleted> cancelFactorRemoval(
    MfaCancelFactorRemovalCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<MfaRevokeUserFactorsCompleted> revokeUserFactors(
    MfaRevokeUserFactorsCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  ) {
    throw StateError(_message);
  }

  static const String _message =
      'Phase 9 MFA operations gateway is not wired; bind the proxy-side '
      'gateway before exposing MFA enrollment routes.';
}

class RepositoryMfaOperationsGateway implements MfaOperationsGateway {
  RepositoryMfaOperationsGateway({
    required MfaEnrollmentService enrollmentService,
    required MfaFactorsRepository mfaFactorsRepository,
    required AuthEventsAuditRepository auditRepository,
    FirebaseMfaClient? firebaseMfaClient,
    MfaFactorRemovalRequestsRepository? removalRequestsRepository,
    DateTime Function()? now,
  }) : _enrollmentService = enrollmentService,
       _mfaFactorsRepository = mfaFactorsRepository,
       _auditRepository = auditRepository,
       _firebaseMfaClient = firebaseMfaClient,
       _removalRequestsRepository = removalRequestsRepository,
       _now = now ?? DateTime.now;

  final MfaEnrollmentService _enrollmentService;
  final MfaFactorsRepository _mfaFactorsRepository;
  final AuthEventsAuditRepository _auditRepository;
  final FirebaseMfaClient? _firebaseMfaClient;
  final MfaFactorRemovalRequestsRepository? _removalRequestsRepository;
  final DateTime Function() _now;

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment(
    MfaTotpBeginCommand command,
  ) async {
    final existing = await _activeTotpSummaries(command);
    if (existing.isNotEmpty) {
      throw const MfaOperationRejected(
        code: 'mfa_factor_already_enrolled',
        message: 'An authenticator app is already enrolled.',
        statusCode: 409,
      );
    }
    return _enrollmentService.beginTotpEnrollment(
      authorizationIdToken: command.authorizationIdToken,
      userId: command.actorUserId,
      userEmail: command.userEmail,
      issuerName: command.issuerName,
    );
  }

  @override
  Future<MfaListFactorsCompleted> listFactors(
    MfaListFactorsCommand command,
  ) async {
    return MfaListFactorsCompleted(
      factors: await _activeTotpSummaries(command),
      removalRequests: await _recentRemovalSummaries(
        operatorId: command.operatorId,
        locationId: command.locationId,
        userId: command.actorUserId,
      ),
    );
  }

  Future<List<MfaFactorSummary>> _activeTotpSummaries(Object command) async {
    final actorUserId = switch (command) {
      MfaListFactorsCommand(:final actorUserId) => actorUserId,
      MfaTotpBeginCommand(:final actorUserId) => actorUserId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final operatorId = switch (command) {
      MfaListFactorsCommand(:final operatorId) => operatorId,
      MfaTotpBeginCommand(:final operatorId) => operatorId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final locationId = switch (command) {
      MfaListFactorsCommand(:final locationId) => locationId,
      MfaTotpBeginCommand(:final locationId) => locationId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final authorizationIdToken = switch (command) {
      MfaListFactorsCommand(:final authorizationIdToken) =>
        authorizationIdToken,
      MfaTotpBeginCommand(:final authorizationIdToken) => authorizationIdToken,
      _ => '',
    };
    final records = await _mfaFactorsRepository.listActiveTotpFactors(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    final factors = <MfaFactorSummary>[
      for (final record in records)
        MfaFactorSummary(
          factorId: record.factorId,
          factorType: record.factorType,
          enrolledAt: record.enrolledAt,
          lastUsedAt: record.lastUsedAt,
          recoveryCodesViewedAt: record.recoveryCodesViewedAt,
          issuerLabel:
              (record.factorMetadata['issuer'] as String?) ?? 'Forge & Flow',
        ),
    ];
    final knownFirebaseUids = records
        .map((record) => record.factorMetadata['firebase_factor_uid'])
        .whereType<String>()
        .where((uid) => uid.trim().isNotEmpty)
        .toSet();
    final firebaseClient = _firebaseMfaClient;
    if (firebaseClient == null || authorizationIdToken.trim().isEmpty) {
      return List<MfaFactorSummary>.unmodifiable(factors);
    }
    final firebaseFactors = await firebaseClient.listTotpFactors(
      authorizationIdToken: authorizationIdToken,
      userId: actorUserId,
    );
    for (final firebaseFactor in firebaseFactors) {
      if (knownFirebaseUids.contains(firebaseFactor.factorId)) continue;
      factors.add(
        MfaFactorSummary(
          factorId: 'firebase:${firebaseFactor.factorId}',
          factorType: 'totp',
          enrolledAt: firebaseFactor.enrolledAt,
          issuerLabel: firebaseFactor.displayName ?? 'Forge & Flow',
          canRevoke: true,
        ),
      );
    }
    return List<MfaFactorSummary>.unmodifiable(factors);
  }

  @override
  Future<MfaRevokeFactorCompleted> revokeFactor(
    MfaRevokeFactorCommand command,
  ) async {
    final stepUpProofId = _requireStepUpProof(command.stepUpProofId);
    final factors = await _mfaFactorsRepository.listActiveTotpFactors(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.actorUserId,
    );
    var removalFactorId = command.factorId;
    final matchingLocal = factors.where(
      (factor) => factor.factorId == removalFactorId,
    );
    if (matchingLocal.isEmpty) {
      final repaired = await _repairFirebaseOnlyFactor(command);
      if (repaired != null) {
        removalFactorId = repaired;
      }
    }
    if (matchingLocal.isEmpty && removalFactorId == command.factorId) {
      throw const MfaOperationRejected(
        code: 'mfa_factor_not_found',
        message: 'MFA factor was already removed or does not exist.',
        statusCode: 404,
      );
    }
    final request = await _initiateRemoval(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorUserId: command.actorUserId,
      targetUserId: command.actorUserId,
      factorId: removalFactorId,
      stepUpProofId: stepUpProofId,
    );
    return MfaRevokeFactorCompleted(
      revoked: false,
      requestId: request.requestId,
      executeAfter: request.executeAfter,
    );
  }

  Future<String?> _repairFirebaseOnlyFactor(
    MfaRevokeFactorCommand command,
  ) async {
    const prefix = 'firebase:';
    if (!command.factorId.startsWith(prefix)) return null;
    final firebaseFactorUid = command.factorId.substring(prefix.length).trim();
    if (firebaseFactorUid.isEmpty) return null;
    final firebaseClient = _firebaseMfaClient;
    if (firebaseClient == null || command.authorizationIdToken.trim().isEmpty) {
      return null;
    }
    final firebaseFactors = await firebaseClient.listTotpFactors(
      authorizationIdToken: command.authorizationIdToken,
      userId: command.actorUserId,
    );
    final matches = firebaseFactors.where(
      (factor) => factor.factorId == firebaseFactorUid,
    );
    if (matches.isEmpty) return null;
    final firebaseFactor = matches.first;
    return _mfaFactorsRepository.ensureTotpFactorForFirebaseUid(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.actorUserId,
      firebaseFactorUid: firebaseFactor.factorId,
      issuerName: firebaseFactor.displayName ?? 'Forge & Flow',
      firebaseEnrolledAt: firebaseFactor.enrolledAt,
    );
  }

  @override
  Future<MfaRevokeUserFactorsCompleted> revokeUserFactors(
    MfaRevokeUserFactorsCommand command,
  ) async {
    final stepUpProofId = _requireStepUpProof(command.stepUpProofId);
    final factors = await _mfaFactorsRepository.listActiveTotpFactors(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.targetUserId,
    );
    if (factors.isEmpty) {
      return const MfaRevokeUserFactorsCompleted(
        requestedCount: 0,
        requestIds: <String>[],
      );
    }
    await _rejectIfRemovalAlreadyPending(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.targetUserId,
      factorIds: factors.map((factor) => factor.factorId).toSet(),
    );
    final requests = <MfaRemovalRequest>[];
    for (final factor in factors) {
      requests.add(
        await _initiateRemoval(
          operatorId: command.operatorId,
          locationId: command.locationId,
          actorUserId: command.actorUserId,
          targetUserId: command.targetUserId,
          factorId: factor.factorId,
          stepUpProofId: stepUpProofId,
        ),
      );
    }
    return MfaRevokeUserFactorsCompleted(
      requestedCount: requests.length,
      requestIds: List<String>.unmodifiable(
        requests.map((request) => request.requestId),
      ),
      executeAfter: requests.first.executeAfter,
    );
  }

  @override
  Future<MfaMarkRecoveryCodesViewedCompleted> markRecoveryCodesViewed(
    MfaMarkRecoveryCodesViewedCommand command,
  ) async {
    final factorId = command.factorId.trim();
    final idempotencyKey = command.idempotencyKey.trim();
    if (factorId.isEmpty) {
      throw const MfaOperationRejected(
        code: 'missing_factor_id',
        message: 'MFA factor id is required.',
        statusCode: 400,
      );
    }
    if (idempotencyKey.isEmpty) {
      throw const MfaOperationRejected(
        code: 'missing_idempotency_key',
        message: 'Idempotency-Key header is required.',
        statusCode: 400,
      );
    }
    final result = await _mfaFactorsRepository.markRecoveryCodesViewed(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.actorUserId,
      factorId: factorId,
      viewedAt: _now().toUtc(),
    );
    if (result == null) {
      throw const MfaOperationRejected(
        code: 'mfa_factor_not_found',
        message: 'Authenticator app was not found for this account.',
        statusCode: 404,
      );
    }
    if (result.changed) {
      await _auditRepository.insertEvent(
        operatorId: command.operatorId,
        locationId: command.locationId,
        actorKind: 'user',
        actorUserId: command.actorUserId,
        targetUserId: command.actorUserId,
        eventType: 'auth.mfa_recovery_codes_viewed',
        payload: <String, Object?>{
          'factor_id': factorId,
          'viewed_at': result.viewedAt.toUtc().toIso8601String(),
          'idempotency_key_present': true,
        },
      );
    }
    return MfaMarkRecoveryCodesViewedCompleted(viewedAt: result.viewedAt);
  }

  @override
  Future<MfaCancelFactorRemovalCompleted> cancelFactorRemoval(
    MfaCancelFactorRemovalCommand command,
  ) async {
    final repository = _removalRequestsRepository;
    if (repository == null) {
      throw const MfaOperationRejected(
        code: 'mfa_removal_cancel_not_configured',
        message: 'MFA removal cancellation is unavailable.',
        statusCode: 503,
      );
    }
    final requestId = command.requestId.trim();
    final targetUserId = command.targetUserId?.trim().isNotEmpty == true
        ? command.targetUserId!.trim()
        : command.actorUserId;
    if (requestId.isEmpty) {
      throw const MfaOperationRejected(
        code: 'missing_removal_request_id',
        message: 'MFA removal request id is required.',
        statusCode: 400,
      );
    }
    final cancelledAt = _now().toUtc();
    final changed = await repository.markCancelled(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: targetUserId,
      requestId: requestId,
      cancelledAt: cancelledAt,
    );
    if (changed == 0) {
      throw const MfaOperationRejected(
        code: 'mfa_removal_request_not_found',
        message: 'MFA removal request was already completed or cancelled.',
        statusCode: 404,
      );
    }
    // User-initiated: MFA removal cancellation runs on the HTTP
    // path with the actor's JWT. Tag the audit row as 'user'.
    await _auditRepository.insertEvent(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorKind: 'user',
      actorUserId: command.actorUserId,
      targetUserId: targetUserId,
      eventType: 'mfa_factor_revocation_cancelled',
      payload: <String, Object?>{
        'request_id': requestId,
        'cancelled_at': cancelledAt.toUtc().toIso8601String(),
      },
    );
    return const MfaCancelFactorRemovalCompleted(cancelled: true);
  }

  Future<void> _rejectIfRemovalAlreadyPending({
    required String operatorId,
    required String locationId,
    required String userId,
    required Set<String> factorIds,
  }) async {
    final repository = _removalRequestsRepository;
    if (repository == null || factorIds.isEmpty) return;
    final existing = await repository.listRecentForUser(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
      limit: 50,
    );
    for (final request in existing) {
      if (!factorIds.contains(request.factorId) || !request.isPending) {
        continue;
      }
      throw MfaOperationRejected(
        code: 'mfa_removal_already_pending',
        message: 'Authenticator app removal is already scheduled.',
        statusCode: 409,
        retryAfter: request.executeAfter,
      );
    }
  }

  String _requireStepUpProof(String stepUpProofId) {
    final trimmed = stepUpProofId.trim();
    if (trimmed.isEmpty) {
      throw const MfaOperationRejected(
        code: 'mfa_freshness_required',
        message: 'Sign in again before removing MFA.',
        statusCode: 403,
      );
    }
    return trimmed;
  }

  Future<MfaRemovalRequest> _initiateRemoval({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String targetUserId,
    required String factorId,
    required String stepUpProofId,
  }) async {
    final requestedAt = _now().toUtc();
    final request =
        MfaRemovalService(
          delay: MfaRemovalService.defaultDelay,
          now: () => requestedAt,
        ).requestRemoval(
          requestId: _uuidV4(),
          userId: targetUserId,
          factorId: factorId,
          stepUpProofId: stepUpProofId,
        );
    final persisted = await _removalRequestsRepository?.insertPending(
      operatorId: operatorId,
      locationId: locationId,
      userId: targetUserId,
      factorId: factorId,
      requestedByUserId: actorUserId,
      stepUpProofId: stepUpProofId,
      requestId: request.requestId,
      requestedAt: request.requestedAt,
      executeAfter: request.executeAfter,
    );
    if (persisted != null && persisted.requestId != request.requestId) {
      throw MfaOperationRejected(
        code: 'mfa_removal_already_pending',
        message: 'Authenticator app removal is already scheduled.',
        statusCode: 409,
        retryAfter: persisted.executeAfter,
      );
    }
    final effectiveRequest = persisted == null
        ? request
        : MfaRemovalRequest(
            requestId: persisted.requestId,
            userId: persisted.userId,
            factorId: persisted.factorId,
            requestedAt: persisted.requestedAt,
            executeAfter: persisted.executeAfter,
            stepUpProofId: persisted.stepUpProofId,
            completedAt: persisted.completedAt,
            cancelledAt: persisted.cancelledAt,
          );
    // User-initiated: revocation is requested via the HTTP path with
    // the actor's JWT. The 24-hour worker-driven *completion* row is
    // emitted separately by MfaRemovalWorker with actorKind: 'system'.
    await _auditRepository.insertEvent(
      operatorId: operatorId,
      locationId: locationId,
      actorKind: 'user',
      actorUserId: actorUserId,
      targetUserId: targetUserId,
      eventType: 'mfa_factor_revocation_initiated',
      payload: <String, Object?>{
        'factor_id': factorId,
        'request_id': effectiveRequest.requestId,
        'execute_after': effectiveRequest.executeAfter
            .toUtc()
            .toIso8601String(),
        'step_up_proof_present': true,
      },
    );
    return effectiveRequest;
  }

  Future<List<MfaRemovalRequestSummary>> _recentRemovalSummaries({
    required String operatorId,
    required String locationId,
    required String userId,
  }) async {
    final repository = _removalRequestsRepository;
    if (repository == null) return const <MfaRemovalRequestSummary>[];
    final List<MfaFactorRemovalRequestRecord> rows;
    try {
      rows = await repository.listRecentForUser(
        operatorId: operatorId,
        locationId: locationId,
        userId: userId,
      );
    } catch (error) {
      if (!_isMissingMfaRemovalRequestsTable(error)) rethrow;
      return const <MfaRemovalRequestSummary>[];
    }
    return List<MfaRemovalRequestSummary>.unmodifiable(
      rows.map(_removalSummary),
    );
  }

  MfaRemovalRequestSummary _removalSummary(
    MfaFactorRemovalRequestRecord record,
  ) {
    return MfaRemovalRequestSummary(
      requestId: record.requestId,
      factorId: record.factorId,
      status: record.completedAt != null
          ? 'completed'
          : record.cancelledAt != null
          ? 'cancelled'
          : 'pending',
      executeAfter: record.executeAfter,
      completedAt: record.completedAt,
    );
  }

  bool _isMissingMfaRemovalRequestsTable(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('mfa_factor_removal_requests') &&
        (text.contains('does not exist') ||
            text.contains('undefined_table') ||
            text.contains('42p01'));
  }

  @override
  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  ) async {
    final result = await _enrollmentService.confirmTotpEnrollment(
      authorizationIdToken: command.authorizationIdToken,
      factorId: command.factorId,
      oneTimeCode: command.oneTimeCode,
      issuerName: command.issuerName,
    );
    switch (result) {
      case MfaEnrollmentConfirmFailure(:final code, :final message):
        await _audit(
          command,
          eventType: 'auth.mfa_totp_enroll_failed',
          payload: <String, Object?>{'code': code},
        );
        throw MfaOperationRejected(code: code, message: message);
      case MfaEnrollmentConfirmSuccess(:final payload):
        final persisted = await _mfaFactorsRepository.insertTotpEnrollment(
          operatorId: command.operatorId,
          locationId: command.locationId,
          userId: command.actorUserId,
          firebaseFactorUid: payload.factorId,
          issuerName: command.issuerName,
        );
        await _audit(
          command,
          eventType: 'auth.mfa_totp_enrolled',
          payload: <String, Object?>{'factor_id': persisted.totpFactorId},
        );
        return MfaTotpConfirmCompleted(factorId: persisted.totpFactorId);
    }
  }

  Future<void> _audit(
    MfaTotpConfirmCommand command, {
    required String eventType,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    // User-initiated: TOTP enrollment confirm runs on the HTTP path
    // with the actor's JWT — actor and target are the same user.
    return _auditRepository.insertEvent(
      operatorId: command.operatorId,
      locationId: command.locationId,
      actorKind: 'user',
      actorUserId: command.actorUserId,
      targetUserId: command.actorUserId,
      eventType: eventType,
      payload: payload,
    );
  }
}

String _uuidV4() {
  final random = math.Random.secure();
  final bytes = Uint8List(16);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = random.nextInt(256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int start, int end) => bytes
      .sublist(start, end)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-'
      '${hex(8, 10)}-${hex(10, 16)}';
}
