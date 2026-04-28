// Phase 9 live-closeout - RepositoryMfaOperationsGateway tests.

import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/mfa/mfa_enrollment_service.dart';
import 'package:forge_and_flow/services/mfa/mfa_operations_gateway.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_attempt_limiter.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_consumer.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_hasher.dart';

void main() {
  group('RepositoryMfaOperationsGateway', () {
    test('confirm TOTP persists factor bundle and audits success', () async {
      final mfaRepo = _RecordingMfaFactorsRepository();
      final auditRepo = _RecordingAuditRepository();
      final gateway = RepositoryMfaOperationsGateway(
        enrollmentService: const _SuccessfulEnrollmentService(),
        mfaFactorsRepository: mfaRepo,
        recoveryCodeConsumer: _FakeRecoveryCodeConsumer(),
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
      expect(result.recoveryCodesPlaintext, equals(<String>['ABCD-EFGH-JKMN']));
      expect(
        mfaRepo.persisted.single.firebaseFactorUid,
        equals('firebase-factor-uid'),
      );
      expect(mfaRepo.persisted.single.hashedRecoveryCodes, hasLength(1));
      expect(
        auditRepo.events.single.eventType,
        equals('auth.mfa_totp_enrolled'),
      );
      expect(auditRepo.events.single.payload['recovery_code_count'], equals(1));
    });

    test(
      'recovery-code invalid path audits and returns generic rejection',
      () async {
        final auditRepo = _RecordingAuditRepository();
        final gateway = RepositoryMfaOperationsGateway(
          enrollmentService: const _SuccessfulEnrollmentService(),
          mfaFactorsRepository: _RecordingMfaFactorsRepository(),
          recoveryCodeConsumer: _FakeRecoveryCodeConsumer(
            result: const RecoveryCodeInvalid(),
          ),
          auditRepository: auditRepo,
        );

        final error = await _captureError(
          gateway.consumeRecoveryCode(
            const RecoveryCodeConsumeCommand(
              actorUserId: _userId,
              operatorId: _operatorId,
              locationId: _locationId,
              rawCode: 'wrong',
            ),
          ),
        );

        expect(error, isA<MfaOperationRejected>());
        expect(
          (error! as MfaOperationRejected).code,
          equals('recovery_code_invalid'),
        );
        expect(
          auditRepo.events.single.eventType,
          equals('auth.recovery_code_failed'),
        );
      },
    );
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
      MfaEnrollmentCompleted(
        factorId: 'firebase-factor-uid',
        recoveryCodesPlaintext: <String>['ABCD-EFGH-JKMN'],
        hashedRecoveryCodes: <HashedRecoveryCode>[
          HashedRecoveryCode(saltBase64: 'c2FsdA==', hashBase64: 'aGFzaA=='),
        ],
      ),
    );
  }
}

class _RecordingMfaFactorsRepository extends MfaFactorsRepository {
  _RecordingMfaFactorsRepository()
    : super(TenantTransactionWrapper(_NoopPool()));

  final persisted = <_PersistedEnrollment>[];

  @override
  Future<MfaEnrollmentPersistenceResult> insertTotpEnrollment({
    required String operatorId,
    required String locationId,
    required String userId,
    required String firebaseFactorUid,
    required List<Map<String, Object?>> hashedRecoveryCodes,
    String issuerName = 'Forge & Flow',
  }) async {
    persisted.add(
      _PersistedEnrollment(
        firebaseFactorUid: firebaseFactorUid,
        hashedRecoveryCodes: hashedRecoveryCodes,
      ),
    );
    return const MfaEnrollmentPersistenceResult(
      totpFactorId: 'totp-db-factor',
      recoveryCodeFactorIds: <String>['recovery-db-factor'],
    );
  }
}

class _PersistedEnrollment {
  const _PersistedEnrollment({
    required this.firebaseFactorUid,
    required this.hashedRecoveryCodes,
  });

  final String firebaseFactorUid;
  final List<Map<String, Object?>> hashedRecoveryCodes;
}

class _RecordingAuditRepository extends AuthEventsAuditRepository {
  _RecordingAuditRepository() : super(TenantTransactionWrapper(_NoopPool()));

  final events = <_AuditEvent>[];

  @override
  Future<String> insertEvent({
    required String operatorId,
    required String locationId,
    required String eventType,
    String? actorUserId,
    String actorKind = 'user',
    String? actorServicePrincipalId,
    String? targetUserId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
  }) async {
    events.add(_AuditEvent(eventType: eventType, payload: payload));
    return 'event-1';
  }
}

class _AuditEvent {
  const _AuditEvent({required this.eventType, required this.payload});

  final String eventType;
  final Map<String, Object?> payload;
}

class _FakeRecoveryCodeConsumer extends RecoveryCodeConsumer {
  _FakeRecoveryCodeConsumer({
    RecoveryCodeConsumeResult result = const RecoveryCodeConsumed(
      factorId: 'recovery-db-factor',
    ),
  }) : _result = result,
       super(
         hasher: const _NoopRecoveryCodeHasher(),
         repository: _RecordingMfaFactorsRepository(),
         limiter: RecoveryCodeAttemptLimiter(
           store: InMemoryRecoveryCodeAttemptStore(),
         ),
       );

  final RecoveryCodeConsumeResult _result;

  @override
  Future<RecoveryCodeConsumeResult> consume({
    required String operatorId,
    required String locationId,
    required String userId,
    required String rawCode,
  }) async {
    return _result;
  }
}

class _NoopRecoveryCodeHasher implements RecoveryCodeHasher {
  const _NoopRecoveryCodeHasher();

  @override
  HashedRecoveryCode hash({
    required String normalizedCode,
    required Uint8List saltBytes,
  }) {
    throw UnimplementedError();
  }

  @override
  bool verify({
    required String normalizedCode,
    required HashedRecoveryCode stored,
  }) {
    throw UnimplementedError();
  }
}

class _NoopPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() {
    throw UnimplementedError();
  }
}
