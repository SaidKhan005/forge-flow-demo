// Phase 9 live-closeout - RepositoryMfaOperationsGateway tests.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_factor_removal_requests_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';
import 'package:forge_and_flow/services/mfa/firebase_mfa_client.dart';
import 'package:forge_and_flow/services/mfa/mfa_enrollment_service.dart';
import 'package:forge_and_flow/services/mfa/mfa_operations_gateway.dart';
import 'package:forge_and_flow/services/mfa/mfa_removal_worker.dart';

void main() {
  group('RepositoryMfaOperationsGateway', () {
    test('confirm TOTP persists factor bundle and audits success', () async {
      final mfaRepo = _RecordingMfaFactorsRepository();
      final auditRepo = _RecordingAuditRepository();
      final gateway = RepositoryMfaOperationsGateway(
        enrollmentService: const _SuccessfulEnrollmentService(),
        mfaFactorsRepository: mfaRepo,
        auditRepository: auditRepo,
      );

      final result = await gateway.confirmTotpEnrollment(
        const MfaTotpConfirmCommand(
          actorUserId: _userId,
          operatorId: _operatorId,
          locationId: _locationId,
          factorId: 'firebase-session-factor',
          oneTimeCode: '123456',
          issuerName: 'Forge & Flow',
        ),
      );

      expect(result.factorId, equals('totp-db-factor'));
      expect(
        mfaRepo.persisted.single.firebaseFactorUid,
        equals('firebase-factor-uid'),
      );
      expect(
        auditRepo.events.single.eventType,
        equals('auth.mfa_totp_enrolled'),
      );
      // ops-debt.actor-kind-audit: TOTP enrollment confirm runs on the
      // user's HTTP path with their JWT; actor and target are the same
      // user. The 'user' tag pins the actor on the hash-chained
      // audit_logs row.
      expect(
        auditRepo.events.single.actorKind,
        equals('user'),
        reason:
            'TOTP enrollment confirm runs on the HTTP path with the '
            "actor's JWT and must tag the audit row 'user'",
      );
    });

    test('listFactors projects active TOTP summaries', () async {
      final enrolledAt = DateTime.utc(2026, 4, 30, 12);
      final mfaRepo = _RecordingMfaFactorsRepository(
        activeTotpFactors: <MfaFactorRecord>[
          MfaFactorRecord(
            factorId: 'totp-db-factor',
            userId: _userId,
            factorType: 'totp',
            factorMetadata: const <String, Object?>{'issuer': 'Forge & Flow'},
            enrolledAt: enrolledAt,
          ),
        ],
      );
      final gateway = RepositoryMfaOperationsGateway(
        enrollmentService: const _SuccessfulEnrollmentService(),
        mfaFactorsRepository: mfaRepo,
        auditRepository: _RecordingAuditRepository(),
      );

      final result = await gateway.listFactors(
        const MfaListFactorsCommand(
          actorUserId: _userId,
          operatorId: _operatorId,
          locationId: _locationId,
        ),
      );

      expect(result.factors.single.factorId, equals('totp-db-factor'));
      expect(result.factors.single.factorType, equals('totp'));
      expect(result.factors.single.enrolledAt, equals(enrolledAt));
      expect(mfaRepo.listActiveTotpCalls, equals(1));
    });

    test(
      'listFactors degrades when MFA removal queue table is absent',
      () async {
        final enrolledAt = DateTime.utc(2026, 4, 30, 12);
        final gateway = RepositoryMfaOperationsGateway(
          enrollmentService: const _SuccessfulEnrollmentService(),
          mfaFactorsRepository: _RecordingMfaFactorsRepository(
            activeTotpFactors: <MfaFactorRecord>[
              MfaFactorRecord(
                factorId: 'totp-db-factor',
                userId: _userId,
                factorType: 'totp',
                factorMetadata: const <String, Object?>{},
                enrolledAt: enrolledAt,
              ),
            ],
          ),
          auditRepository: _RecordingAuditRepository(),
          removalRequestsRepository: _RecordingRemovalRequestsRepository(
            throwMissingTableOnList: true,
          ),
        );

        final result = await gateway.listFactors(
          const MfaListFactorsCommand(
            actorUserId: _userId,
            operatorId: _operatorId,
            locationId: _locationId,
          ),
        );

        expect(result.factors.single.factorId, equals('totp-db-factor'));
        expect(result.removalRequests, isEmpty);
      },
    );

    test(
      'begin rejects when an active authenticator app already exists',
      () async {
        final mfaRepo = _RecordingMfaFactorsRepository(
          activeTotpFactors: <MfaFactorRecord>[
            MfaFactorRecord(
              factorId: 'totp-db-factor',
              userId: _userId,
              factorType: 'totp',
              factorMetadata: const <String, Object?>{},
              enrolledAt: DateTime.utc(2026, 4, 30),
            ),
          ],
        );
        final gateway = RepositoryMfaOperationsGateway(
          enrollmentService: const _SuccessfulEnrollmentService(),
          mfaFactorsRepository: mfaRepo,
          auditRepository: _RecordingAuditRepository(),
        );

        final error = await _captureError(
          gateway.beginTotpEnrollment(
            const MfaTotpBeginCommand(
              actorUserId: _userId,
              operatorId: _operatorId,
              locationId: _locationId,
              userEmail: 'owner@example.test',
              issuerName: 'Forge & Flow',
            ),
          ),
        );

        expect(error, isA<MfaOperationRejected>());
        expect(
          (error! as MfaOperationRejected).code,
          equals('mfa_factor_already_enrolled'),
        );
      },
    );

    test(
      'revokeFactor initiates delayed removal and audits contract event',
      () async {
        final auditRepo = _RecordingAuditRepository();
        final removalRepo = _RecordingRemovalRequestsRepository();
        final now = DateTime.utc(2026, 4, 30, 12);
        final gateway = RepositoryMfaOperationsGateway(
          enrollmentService: const _SuccessfulEnrollmentService(),
          mfaFactorsRepository: _RecordingMfaFactorsRepository(
            activeTotpFactors: <MfaFactorRecord>[
              MfaFactorRecord(
                factorId: 'totp-db-factor',
                userId: _userId,
                factorType: 'totp',
                factorMetadata: const <String, Object?>{},
                enrolledAt: now,
              ),
            ],
          ),
          auditRepository: auditRepo,
          removalRequestsRepository: removalRepo,
          now: () => now,
        );

        final result = await gateway.revokeFactor(
          const MfaRevokeFactorCommand(
            actorUserId: _userId,
            operatorId: _operatorId,
            locationId: _locationId,
            factorId: 'totp-db-factor',
            stepUpProofId: 'fresh-proof',
          ),
        );

        expect(result.revoked, isFalse);
        expect(result.executeAfter, equals(now.add(const Duration(hours: 24))));
        expect(
          auditRepo.events.single.eventType,
          equals('mfa_factor_revocation_initiated'),
        );
        // ops-debt.actor-kind-audit: revocation is initiated on the
        // user's HTTP path with their JWT (the worker-driven completion
        // is a separate audit row tagged 'system'); this row must
        // carry actor_kind='user' so audit_logs.actor_user_id pins the
        // initiating actor.
        expect(
          auditRepo.events.single.actorKind,
          equals('user'),
          reason:
              'revocation initiation runs on the HTTP path with the '
              "actor's JWT and must tag the audit row 'user'",
        );
        expect(
          auditRepo.events.single.payload['factor_id'],
          equals('totp-db-factor'),
        );
        expect(removalRepo.records.single.factorId, equals('totp-db-factor'));
      },
    );

    test(
      'revokeFactor rejects a duplicate pending removal without another audit',
      () async {
        final auditRepo = _RecordingAuditRepository();
        final existingExecuteAfter = DateTime.utc(2026, 5, 1, 12);
        final removalRepo = _RecordingRemovalRequestsRepository(
          records: <MfaFactorRemovalRequestRecord>[
            MfaFactorRemovalRequestRecord(
              requestId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              operatorId: _operatorId,
              locationId: _locationId,
              userId: _userId,
              factorId: 'totp-db-factor',
              requestedByUserId: _userId,
              stepUpProofId: 'fresh-proof',
              requestedAt: DateTime.utc(2026, 4, 30, 12),
              executeAfter: existingExecuteAfter,
            ),
          ],
        );
        final gateway = RepositoryMfaOperationsGateway(
          enrollmentService: const _SuccessfulEnrollmentService(),
          mfaFactorsRepository: _RecordingMfaFactorsRepository(
            activeTotpFactors: <MfaFactorRecord>[
              MfaFactorRecord(
                factorId: 'totp-db-factor',
                userId: _userId,
                factorType: 'totp',
                factorMetadata: const <String, Object?>{},
                enrolledAt: DateTime.utc(2026, 4, 30, 12),
              ),
            ],
          ),
          auditRepository: auditRepo,
          removalRequestsRepository: removalRepo,
          now: () => DateTime.utc(2026, 4, 30, 13),
        );

        final error = await _captureError(
          gateway.revokeFactor(
            const MfaRevokeFactorCommand(
              actorUserId: _userId,
              operatorId: _operatorId,
              locationId: _locationId,
              factorId: 'totp-db-factor',
              stepUpProofId: 'fresh-proof',
            ),
          ),
        );

        expect(error, isA<MfaOperationRejected>());
        final rejected = error! as MfaOperationRejected;
        expect(rejected.code, equals('mfa_removal_already_pending'));
        expect(rejected.statusCode, equals(409));
        expect(rejected.retryAfter, equals(existingExecuteAfter));
        expect(auditRepo.events, isEmpty);
        expect(removalRepo.records, hasLength(1));
      },
    );

    test(
      'revokeUserFactors rejects pending removal before partial reset work',
      () async {
        final auditRepo = _RecordingAuditRepository();
        final existingExecuteAfter = DateTime.utc(2026, 5, 1, 12);
        final removalRepo = _RecordingRemovalRequestsRepository(
          records: <MfaFactorRemovalRequestRecord>[
            MfaFactorRemovalRequestRecord(
              requestId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              operatorId: _operatorId,
              locationId: _locationId,
              userId: _userId,
              factorId: 'totp-db-factor-pending',
              requestedByUserId: _userId,
              stepUpProofId: 'fresh-proof',
              requestedAt: DateTime.utc(2026, 4, 30, 12),
              executeAfter: existingExecuteAfter,
            ),
          ],
        );
        final gateway = RepositoryMfaOperationsGateway(
          enrollmentService: const _SuccessfulEnrollmentService(),
          mfaFactorsRepository: _RecordingMfaFactorsRepository(
            activeTotpFactors: <MfaFactorRecord>[
              MfaFactorRecord(
                factorId: 'totp-db-factor-new',
                userId: _userId,
                factorType: 'totp',
                factorMetadata: const <String, Object?>{},
                enrolledAt: DateTime.utc(2026, 4, 30, 13),
              ),
              MfaFactorRecord(
                factorId: 'totp-db-factor-pending',
                userId: _userId,
                factorType: 'totp',
                factorMetadata: const <String, Object?>{},
                enrolledAt: DateTime.utc(2026, 4, 30, 12),
              ),
            ],
          ),
          auditRepository: auditRepo,
          removalRequestsRepository: removalRepo,
          now: () => DateTime.utc(2026, 4, 30, 13),
        );

        final error = await _captureError(
          gateway.revokeUserFactors(
            const MfaRevokeUserFactorsCommand(
              actorUserId: _userId,
              operatorId: _operatorId,
              locationId: _locationId,
              targetUserId: _userId,
              stepUpProofId: 'fresh-proof',
            ),
          ),
        );

        expect(error, isA<MfaOperationRejected>());
        final rejected = error! as MfaOperationRejected;
        expect(rejected.code, equals('mfa_removal_already_pending'));
        expect(rejected.statusCode, equals(409));
        expect(rejected.retryAfter, equals(existingExecuteAfter));
        expect(auditRepo.events, isEmpty);
        expect(removalRepo.records, hasLength(1));
      },
    );

    test(
      'revokeFactor repairs Firebase-only inventory before removal',
      () async {
        final auditRepo = _RecordingAuditRepository();
        final removalRepo = _RecordingRemovalRequestsRepository();
        final mfaRepo = _RecordingMfaFactorsRepository();
        final firebaseMfa = _RecordingFirebaseMfaClient(
          factors: <FirebaseMfaTotpFactor>[
            FirebaseMfaTotpFactor(
              factorId: 'firebase-factor-uid',
              enrolledAt: DateTime.utc(2026, 4, 30, 11),
              displayName: 'Forge & Flow',
            ),
          ],
        );
        final gateway = RepositoryMfaOperationsGateway(
          enrollmentService: const _SuccessfulEnrollmentService(),
          mfaFactorsRepository: mfaRepo,
          auditRepository: auditRepo,
          removalRequestsRepository: removalRepo,
          firebaseMfaClient: firebaseMfa,
          now: () => DateTime.utc(2026, 4, 30, 12),
        );

        final result = await gateway.revokeFactor(
          const MfaRevokeFactorCommand(
            actorUserId: _userId,
            operatorId: _operatorId,
            locationId: _locationId,
            authorizationIdToken: 'id-token',
            factorId: 'firebase:firebase-factor-uid',
            stepUpProofId: 'fresh-proof',
          ),
        );

        expect(result.revoked, isFalse);
        expect(
          mfaRepo.ensuredFirebaseUids,
          equals(<String>['firebase-factor-uid']),
        );
        expect(
          removalRepo.records.single.factorId,
          equals('repaired-totp-db-factor'),
        );
      },
    );

    test(
      'cancelFactorRemoval cancels pending request and audits event',
      () async {
        final auditRepo = _RecordingAuditRepository();
        final removalRepo = _RecordingRemovalRequestsRepository(
          records: <MfaFactorRemovalRequestRecord>[
            MfaFactorRemovalRequestRecord(
              requestId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              operatorId: _operatorId,
              locationId: _locationId,
              userId: _userId,
              factorId: 'totp-db-factor',
              requestedByUserId: _userId,
              stepUpProofId: 'fresh-proof',
              requestedAt: DateTime.utc(2026, 4, 30, 12),
              executeAfter: DateTime.utc(2026, 5, 1, 12),
            ),
          ],
        );
        final gateway = RepositoryMfaOperationsGateway(
          enrollmentService: const _SuccessfulEnrollmentService(),
          mfaFactorsRepository: _RecordingMfaFactorsRepository(),
          auditRepository: auditRepo,
          removalRequestsRepository: removalRepo,
          now: () => DateTime.utc(2026, 4, 30, 13),
        );

        final result = await gateway.cancelFactorRemoval(
          const MfaCancelFactorRemovalCommand(
            actorUserId: _userId,
            operatorId: _operatorId,
            locationId: _locationId,
            requestId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          ),
        );

        expect(result.cancelled, isTrue);
        expect(removalRepo.records.single.cancelledAt, isNotNull);
        expect(
          auditRepo.events.single.eventType,
          equals('mfa_factor_revocation_cancelled'),
        );
        // ops-debt.actor-kind-audit: cancellation runs on the user's
        // HTTP path with their JWT.
        expect(
          auditRepo.events.single.actorKind,
          equals('user'),
          reason:
              'cancellation runs on the HTTP path with the actor JWT '
              "and must tag the audit row 'user'",
        );
        expect(
          auditRepo.events.single.payload['request_id'],
          equals('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
        );
      },
    );

    test(
      'removal worker completes due delayed removal and queues event',
      () async {
        final auditRepo = _RecordingAuditRepository();
        final removalRepo = _RecordingRemovalRequestsRepository(
          records: <MfaFactorRemovalRequestRecord>[
            MfaFactorRemovalRequestRecord(
              requestId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              operatorId: _operatorId,
              locationId: _locationId,
              userId: _userId,
              factorId: 'totp-db-factor',
              requestedByUserId: _userId,
              stepUpProofId: 'fresh-proof',
              requestedAt: DateTime.utc(2026, 4, 30, 12),
              executeAfter: DateTime.utc(2026, 5, 1, 12),
            ),
          ],
        );
        final mfaRepo = _RecordingMfaFactorsRepository(
          activeTotpFactors: <MfaFactorRecord>[
            MfaFactorRecord(
              factorId: 'totp-db-factor',
              userId: _userId,
              factorType: 'totp',
              factorMetadata: const <String, Object?>{
                'firebase_factor_uid': 'firebase-factor-uid',
              },
              enrolledAt: DateTime.utc(2026, 4, 30, 12),
            ),
          ],
        );
        final firebaseAdmin = _RecordingFirebaseAdminAuthClient();
        final outboxRepo = _RecordingEventOutboxRepository();
        final worker = MfaRemovalWorker(
          removalRequestsRepository: removalRepo,
          mfaFactorsRepository: mfaRepo,
          usersRepository: _RecordingUsersRepository(
            firebaseUid: 'firebase-uid',
          ),
          auditRepository: auditRepo,
          firebaseAdmin: firebaseAdmin,
          eventOutboxRepository: outboxRepo,
          now: () => DateTime.utc(2026, 5, 1, 13),
        );

        final result = await worker.processDue();

        expect(firebaseAdmin.clearedMfaUids, equals(<String>['firebase-uid']));
        expect(mfaRepo.revokedTotpFactors, equals(<String>['totp-db-factor']));
        expect(mfaRepo.revokedRecoveryCodeRows, equals(1));
        expect(result.claimed, equals(1));
        expect(result.completed, equals(1));
        expect(
          auditRepo.events.single.eventType,
          equals('mfa_factor_revocation_completed'),
        );
        // ops-debt.actor-kind-audit: the 24-hour MFA removal worker is
        // a legacy worker boundary with no human / SP attribution, so
        // the completion row tags actor_kind='system'. The corresponding
        // 'mfa_factor_revocation_initiated' row is emitted separately
        // by the user-path gateway with actor_kind='user'.
        expect(
          auditRepo.events.single.actorKind,
          equals('system'),
          reason:
              'MFA removal worker has no human / SP actor and must '
              "tag the completion audit row 'system'",
        );
        expect(
          outboxRepo.enqueued.single.topic,
          'auth.user.mfa_factor_removed',
        );
      },
    );

    test('revokeFactor without fresh proof is rejected', () async {
      final gateway = RepositoryMfaOperationsGateway(
        enrollmentService: const _SuccessfulEnrollmentService(),
        mfaFactorsRepository: _RecordingMfaFactorsRepository(),
        auditRepository: _RecordingAuditRepository(),
      );

      final error = await _captureError(
        gateway.revokeFactor(
          const MfaRevokeFactorCommand(
            actorUserId: _userId,
            operatorId: _operatorId,
            locationId: _locationId,
            factorId: 'totp-db-factor',
          ),
        ),
      );

      expect(error, isA<MfaOperationRejected>());
      expect(
        (error! as MfaOperationRejected).code,
        equals('mfa_freshness_required'),
      );
    });
  });
}

const _userId = '11111111-1111-4111-8111-111111111111';
const _operatorId = '22222222-2222-4222-8222-222222222222';
const _locationId = '33333333-3333-4333-8333-333333333333';

Future<Object?> _captureError(Future<Object?> future) async {
  try {
    await future;
    return null;
  } catch (error) {
    return error;
  }
}

class _SuccessfulEnrollmentService implements MfaEnrollmentService {
  const _SuccessfulEnrollmentService();

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment({
    String authorizationIdToken = '',
    required String userId,
    required String userEmail,
    required String issuerName,
  }) async {
    return const TotpEnrollmentSetup(
      factorId: 'firebase-session-factor',
      secretBase32: 'JBSWY3DPEHPK3PXP',
      otpAuthUrl: 'otpauth://totp/Forge%20%26%20Flow:user@example.test',
    );
  }

  @override
  Future<MfaEnrollmentConfirmResult> confirmTotpEnrollment({
    String authorizationIdToken = '',
    required String factorId,
    required String oneTimeCode,
    String issuerName = 'Forge & Flow',
  }) async {
    return const MfaEnrollmentConfirmSuccess(
      MfaEnrollmentCompleted(factorId: 'firebase-factor-uid'),
    );
  }
}

class _RecordingMfaFactorsRepository extends MfaFactorsRepository {
  _RecordingMfaFactorsRepository({
    List<MfaFactorRecord> activeTotpFactors = const <MfaFactorRecord>[],
  }) : _activeTotpFactors = activeTotpFactors,
       super(TenantTransactionWrapper(_NoopPool()));

  final persisted = <_PersistedEnrollment>[];
  final List<MfaFactorRecord> _activeTotpFactors;
  final revokedTotpFactors = <String>[];
  final ensuredFirebaseUids = <String>[];
  int revokedRecoveryCodeRows = 0;
  int listActiveTotpCalls = 0;

  @override
  Future<MfaEnrollmentPersistenceResult> insertTotpEnrollment({
    required String operatorId,
    required String locationId,
    required String userId,
    required String firebaseFactorUid,
    String issuerName = 'Forge & Flow',
  }) async {
    persisted.add(_PersistedEnrollment(firebaseFactorUid: firebaseFactorUid));
    return const MfaEnrollmentPersistenceResult(totpFactorId: 'totp-db-factor');
  }

  @override
  Future<List<MfaFactorRecord>> listActiveTotpFactors({
    required String operatorId,
    required String locationId,
    required String userId,
  }) async {
    listActiveTotpCalls += 1;
    return _activeTotpFactors
        .where((factor) => !revokedTotpFactors.contains(factor.factorId))
        .toList(growable: false);
  }

  @override
  Future<String> ensureTotpFactorForFirebaseUid({
    required String operatorId,
    required String locationId,
    required String userId,
    required String firebaseFactorUid,
    String issuerName = 'Forge & Flow',
    DateTime? firebaseEnrolledAt,
  }) async {
    ensuredFirebaseUids.add(firebaseFactorUid);
    return 'repaired-totp-db-factor';
  }

  @override
  Future<int> revokeTotpFactor({
    required String operatorId,
    required String locationId,
    required String userId,
    required String factorId,
  }) async {
    revokedTotpFactors.add(factorId);
    return 1;
  }

  @override
  Future<int> revokeActiveRecoveryCodeFactorsForUser({
    required String operatorId,
    required String locationId,
    required String userId,
  }) async {
    revokedRecoveryCodeRows += 1;
    return 3;
  }
}

class _PersistedEnrollment {
  const _PersistedEnrollment({required this.firebaseFactorUid});

  final String firebaseFactorUid;
}

class _RecordingAuditRepository extends AuthEventsAuditRepository {
  _RecordingAuditRepository() : super(TenantTransactionWrapper(_NoopPool()));

  final events = <_AuditEvent>[];

  @override
  Future<String> insertEvent({
    required String operatorId,
    required String locationId,
    required String eventType,
    required String actorKind,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
  }) async {
    events.add(_AuditEvent(
      eventType: eventType,
      actorKind: actorKind,
      payload: payload,
    ));
    return 'event-1';
  }

  @override
  Future<String> insertSystemEvent({
    required String eventType,
    required String actorKind,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    required String adminReason,
  }) async {
    events.add(_AuditEvent(
      eventType: eventType,
      actorKind: actorKind,
      payload: payload,
    ));
    return 'event-1';
  }

  /// L7 atomic-completion on-executor variant. Records onto the same
  /// `events` list so the gateway test's existing assertions still hold.
  @override
  Future<String> insertSystemEventOn(
    PostgresExecutor exec, {
    required String eventType,
    required String actorKind,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
  }) async {
    events.add(_AuditEvent(
      eventType: eventType,
      actorKind: actorKind,
      payload: payload,
    ));
    return 'event-1';
  }
}

class _AuditEvent {
  const _AuditEvent({
    required this.eventType,
    required this.actorKind,
    required this.payload,
  });

  final String eventType;
  final String actorKind;
  final Map<String, Object?> payload;
}

class _RecordingRemovalRequestsRepository
    extends MfaFactorRemovalRequestsRepository {
  _RecordingRemovalRequestsRepository({
    List<MfaFactorRemovalRequestRecord> records =
        const <MfaFactorRemovalRequestRecord>[],
    this.throwMissingTableOnList = false,
  }) : records = <MfaFactorRemovalRequestRecord>[...records],
       super(TenantTransactionWrapper(_NoopPool()));

  final List<MfaFactorRemovalRequestRecord> records;
  final bool throwMissingTableOnList;

  @override
  Future<MfaFactorRemovalRequestRecord> insertPending({
    required String operatorId,
    required String locationId,
    required String userId,
    required String factorId,
    required String requestedByUserId,
    required String stepUpProofId,
    required String requestId,
    required DateTime requestedAt,
    required DateTime executeAfter,
  }) async {
    final existing = records.where(
      (record) =>
          record.operatorId == operatorId &&
          record.userId == userId &&
          record.factorId == factorId &&
          record.completedAt == null &&
          record.cancelledAt == null,
    );
    if (existing.isNotEmpty) return existing.first;
    final record = MfaFactorRemovalRequestRecord(
      requestId: requestId,
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
      factorId: factorId,
      requestedByUserId: requestedByUserId,
      stepUpProofId: stepUpProofId,
      requestedAt: requestedAt,
      executeAfter: executeAfter,
    );
    records.add(record);
    return record;
  }

  @override
  Future<List<MfaFactorRemovalRequestRecord>> listRecentForUser({
    required String operatorId,
    required String locationId,
    required String userId,
    int limit = 20,
  }) async {
    if (throwMissingTableOnList) {
      throw StateError('relation "mfa_factor_removal_requests" does not exist');
    }
    return records
        .where(
          (record) =>
              record.operatorId == operatorId &&
              record.locationId == locationId &&
              record.userId == userId,
        )
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<List<MfaFactorRemovalRequestRecord>> listDuePendingForUser({
    required String operatorId,
    required String locationId,
    required String userId,
    required DateTime now,
    int limit = 10,
  }) async {
    return records
        .where(
          (record) =>
              record.operatorId == operatorId &&
              record.locationId == locationId &&
              record.userId == userId &&
              record.completedAt == null &&
              record.cancelledAt == null &&
              !record.executeAfter.isAfter(now),
        )
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<List<MfaFactorRemovalRequestRecord>> claimDuePending({
    required DateTime now,
    required String workerOwner,
    int limit = 50,
    Duration staleAfter = const Duration(minutes: 15),
  }) async {
    return records
        .where(
          (record) =>
              record.completedAt == null &&
              record.cancelledAt == null &&
              !record.executeAfter.isAfter(now),
        )
        .take(limit)
        .toList(growable: false);
  }

  @override
  Future<int> markCompleted({
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestId,
    required DateTime completedAt,
  }) async {
    return _applyCompletion(requestId: requestId, completedAt: completedAt);
  }

  /// L7 atomic-completion on-executor variant. The fake ignores [exec]
  /// and applies the same record mutation as the legacy [markCompleted].
  /// Atomicity (rollback on body throw) is simulated by the [withTenant]
  /// override below.
  @override
  Future<int> markCompletedInTransaction(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestId,
    required DateTime completedAt,
  }) async {
    return _applyCompletion(requestId: requestId, completedAt: completedAt);
  }

  /// Override the inherited `withTenant` so the fake can run the body
  /// without a live Postgres pool. The gateway test exercises the
  /// success path only, so a try/rethrow is enough — no rollback
  /// simulation is needed for these scenarios. (`mfa_removal_worker_test`
  /// has the explicit rollback coverage.)
  @override
  Future<R> withTenant<R>(
    TenantContext context,
    Future<R> Function(PostgresExecutor exec) body,
  ) async {
    return body(_FakeExecutor());
  }

  int _applyCompletion({
    required String requestId,
    required DateTime completedAt,
  }) {
    final index = records.indexWhere((record) => record.requestId == requestId);
    if (index < 0) return 0;
    final current = records[index];
    records[index] = MfaFactorRemovalRequestRecord(
      requestId: current.requestId,
      operatorId: current.operatorId,
      locationId: current.locationId,
      userId: current.userId,
      factorId: current.factorId,
      requestedByUserId: current.requestedByUserId,
      stepUpProofId: current.stepUpProofId,
      requestedAt: current.requestedAt,
      executeAfter: current.executeAfter,
      completedAt: completedAt,
      cancelledAt: current.cancelledAt,
      lastError: current.lastError,
    );
    return 1;
  }

  @override
  Future<int> markCancelled({
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestId,
    required DateTime cancelledAt,
  }) async {
    final index = records.indexWhere(
      (record) =>
          record.requestId == requestId &&
          record.operatorId == operatorId &&
          record.locationId == locationId &&
          record.userId == userId &&
          record.completedAt == null &&
          record.cancelledAt == null,
    );
    if (index < 0) return 0;
    final current = records[index];
    records[index] = MfaFactorRemovalRequestRecord(
      requestId: current.requestId,
      operatorId: current.operatorId,
      locationId: current.locationId,
      userId: current.userId,
      factorId: current.factorId,
      requestedByUserId: current.requestedByUserId,
      stepUpProofId: current.stepUpProofId,
      requestedAt: current.requestedAt,
      executeAfter: current.executeAfter,
      completedAt: current.completedAt,
      cancelledAt: cancelledAt,
      lastError: current.lastError,
    );
    return 1;
  }

  @override
  Future<int> markFailed({
    required String operatorId,
    required String locationId,
    required String userId,
    required String requestId,
    required String error,
  }) async {
    return 1;
  }
}

class _RecordingFirebaseAdminAuthClient implements FirebaseAdminAuthClient {
  final clearedMfaUids = <String>[];

  @override
  Future<void> clearMfaEnrollments({required String uid}) async {
    clearedMfaUids.add(uid);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingFirebaseMfaClient implements FirebaseMfaClient {
  _RecordingFirebaseMfaClient({this.factors = const <FirebaseMfaTotpFactor>[]});

  final List<FirebaseMfaTotpFactor> factors;

  @override
  Future<List<FirebaseMfaTotpFactor>> listTotpFactors({
    String authorizationIdToken = '',
    required String userId,
  }) async {
    return factors;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingUsersRepository extends UsersRepository {
  _RecordingUsersRepository({required this.firebaseUid})
    : super(TenantTransactionWrapper(_NoopPool()));

  final String firebaseUid;

  @override
  Future<String> firebaseUidForUserSystem({
    required String userId,
    required String adminReason,
    String? requireOperatorId,
  }) async {
    return firebaseUid;
  }

  @override
  Future<UserAuthLookupRow?> findActiveAuthUserByEmail({
    required String email,
    required String adminReason,
  }) async {
    return null;
  }
}

class _RecordingEventOutboxRepository extends EventOutboxRepository {
  _RecordingEventOutboxRepository()
    : super(TenantTransactionWrapper(_NoopPool()));

  final enqueued = <_OutboxEvent>[];

  @override
  Future<String> enqueue({
    required String operatorId,
    required String locationId,
    required String topic,
    required Map<String, Object?> payload,
    String? userId,
  }) async {
    enqueued.add(_OutboxEvent(topic: topic, payload: payload));
    return 'outbox-1';
  }

  /// L7 atomic-completion on-executor variant. Records onto the same
  /// `enqueued` list so the gateway test's existing assertions still
  /// hold.
  @override
  Future<String> enqueueInTransaction(
    PostgresExecutor exec, {
    required String operatorId,
    required String topic,
    required Map<String, Object?> payload,
  }) async {
    enqueued.add(_OutboxEvent(topic: topic, payload: payload));
    return 'outbox-1';
  }
}

class _OutboxEvent {
  const _OutboxEvent({required this.topic, required this.payload});

  final String topic;
  final Map<String, Object?> payload;
}

/// Stand-in for a real `PostgresExecutor` inside the atomic-completion
/// body of `MfaRemovalWorker`. The downstream fakes ignore the
/// executor argument; this exists only so the type system is happy.
class _FakeExecutor implements PostgresExecutor {
  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    throw StateError('unexpected query in atomic-completion body: $sql');
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    throw StateError('unexpected execute in atomic-completion body: $sql');
  }
}

class _NoopPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() {
    throw UnimplementedError();
  }
}
