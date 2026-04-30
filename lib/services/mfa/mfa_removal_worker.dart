// Phase 9.UX.1a - scheduled MFA removal completion worker.
//
// User and admin actions only initiate the 24-hour removal window. This worker
// is the backend-owned completion pass that Cloud Scheduler / Cloud Run Jobs
// can run every 5-15 minutes. It is idempotent: rows are claimed with
// SKIP LOCKED, completion updates guard on pending state, and failures release
// the claim for a later retry.

import '../../infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/mfa_factor_removal_requests_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/users_repository.dart';
import '../auth/firebase_admin_auth_client.dart';

class MfaRemovalWorkerResult {
  const MfaRemovalWorkerResult({
    required this.claimed,
    required this.completed,
    required this.failed,
  });

  final int claimed;
  final int completed;
  final int failed;
}

class MfaRemovalWorker {
  MfaRemovalWorker({
    required MfaFactorRemovalRequestsRepository removalRequestsRepository,
    required MfaFactorsRepository mfaFactorsRepository,
    required UsersRepository usersRepository,
    required AuthEventsAuditRepository auditRepository,
    required FirebaseAdminAuthClient firebaseAdmin,
    EventOutboxRepository? eventOutboxRepository,
    DateTime Function()? now,
    this.workerOwner = 'mfa-removal-worker',
  }) : _removalRequestsRepository = removalRequestsRepository,
       _mfaFactorsRepository = mfaFactorsRepository,
       _usersRepository = usersRepository,
       _auditRepository = auditRepository,
       _firebaseAdmin = firebaseAdmin,
       _eventOutboxRepository = eventOutboxRepository,
       _now = now ?? DateTime.now;

  final MfaFactorRemovalRequestsRepository _removalRequestsRepository;
  final MfaFactorsRepository _mfaFactorsRepository;
  final UsersRepository _usersRepository;
  final AuthEventsAuditRepository _auditRepository;
  final FirebaseAdminAuthClient _firebaseAdmin;
  final EventOutboxRepository? _eventOutboxRepository;
  final DateTime Function() _now;
  final String workerOwner;

  Future<MfaRemovalWorkerResult> processDue({int batchSize = 50}) async {
    final now = _now().toUtc();
    final due = await _removalRequestsRepository.claimDuePending(
      now: now,
      workerOwner: workerOwner,
      limit: batchSize,
    );
    var completed = 0;
    var failed = 0;
    for (final request in due) {
      try {
        final firebaseUid = await _usersRepository.firebaseUidForUserSystem(
          userId: request.userId,
          adminReason: 'system.mfa_factor_removal_worker_firebase_uid',
        );
        await _firebaseAdmin.clearMfaEnrollments(uid: firebaseUid);
        await _mfaFactorsRepository.revokeTotpFactor(
          operatorId: request.operatorId,
          locationId: request.locationId,
          userId: request.userId,
          factorId: request.factorId,
        );
        await _mfaFactorsRepository.revokeActiveRecoveryCodeFactorsForUser(
          operatorId: request.operatorId,
          locationId: request.locationId,
          userId: request.userId,
        );
        final changed = await _removalRequestsRepository.markCompleted(
          operatorId: request.operatorId,
          locationId: request.locationId,
          userId: request.userId,
          requestId: request.requestId,
          completedAt: now,
        );
        if (changed == 0) {
          continue;
        }
        completed += 1;
        await _auditRepository.insertSystemEvent(
          operatorId: request.operatorId,
          locationId: request.locationId,
          actorKind: 'system',
          targetUserId: request.userId,
          eventType: 'mfa_factor_revocation_completed',
          payload: <String, Object?>{
            'factor_id': request.factorId,
            'request_id': request.requestId,
            'requested_by_user_id': request.requestedByUserId,
            'completed_at': now.toIso8601String(),
            'worker_owner': workerOwner,
          },
          adminReason: 'system.mfa_factor_removal_worker_complete',
        );
        await _eventOutboxRepository?.enqueue(
          operatorId: request.operatorId,
          locationId: request.locationId,
          userId: request.userId,
          topic: 'auth.user.mfa_factor_removed',
          payload: <String, Object?>{
            'event_id': request.requestId,
            'event_type': 'auth.user.mfa_factor_removed',
            'occurred_at': now.toIso8601String(),
            'operator_id': request.operatorId,
            'location_id': request.locationId,
            'user_id': request.userId,
            'factor_id': request.factorId,
          },
        );
      } catch (error) {
        failed += 1;
        await _removalRequestsRepository.markFailed(
          operatorId: request.operatorId,
          locationId: request.locationId,
          userId: request.userId,
          requestId: request.requestId,
          error: error.runtimeType.toString(),
        );
      }
    }
    return MfaRemovalWorkerResult(
      claimed: due.length,
      completed: completed,
      failed: failed,
    );
  }
}
