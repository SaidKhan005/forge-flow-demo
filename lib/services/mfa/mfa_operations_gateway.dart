// Phase 9 live-closeout - proxy MFA operations gateway.
//
// This is the server-side seam used by `/v1/auth/mfa/*` routes. It composes
// Firebase TOTP enrollment, local `mfa_factors` persistence, recovery-code
// consumption, and append-only audit rows. Flutter never gets database
// credentials; plaintext recovery codes are returned only on the successful
// enrollment-confirm response.

import '../../infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart';
import 'mfa_enrollment_service.dart';
import 'recovery_code_consumer.dart';

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

class RecoveryCodeConsumeCommand {
  const RecoveryCodeConsumeCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.rawCode,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String rawCode;
}

class MfaTotpConfirmCompleted {
  const MfaTotpConfirmCompleted({
    required this.factorId,
    required this.recoveryCodesPlaintext,
  });

  final String factorId;
  final List<String> recoveryCodesPlaintext;
}

class RecoveryCodeConsumeCompleted {
  const RecoveryCodeConsumeCompleted({required this.factorId});

  final String factorId;
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

  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  );

  Future<RecoveryCodeConsumeCompleted> consumeRecoveryCode(
    RecoveryCodeConsumeCommand command,
  );
}

class ScaffoldFailingMfaOperationsGateway implements MfaOperationsGateway {
  const ScaffoldFailingMfaOperationsGateway();

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment(MfaTotpBeginCommand command) {
    throw StateError(_message);
  }

  @override
  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<RecoveryCodeConsumeCompleted> consumeRecoveryCode(
    RecoveryCodeConsumeCommand command,
  ) {
    throw StateError(_message);
  }

  static const String _message =
      'Phase 9 MFA operations gateway is not wired; bind the proxy-side '
      'gateway before exposing MFA enrollment or recovery-code routes.';
}

class RepositoryMfaOperationsGateway implements MfaOperationsGateway {
  RepositoryMfaOperationsGateway({
    required MfaEnrollmentService enrollmentService,
    required MfaFactorsRepository mfaFactorsRepository,
    required RecoveryCodeConsumer recoveryCodeConsumer,
    required AuthEventsAuditRepository auditRepository,
  }) : _enrollmentService = enrollmentService,
       _mfaFactorsRepository = mfaFactorsRepository,
       _recoveryCodeConsumer = recoveryCodeConsumer,
       _auditRepository = auditRepository;

  final MfaEnrollmentService _enrollmentService;
  final MfaFactorsRepository _mfaFactorsRepository;
  final RecoveryCodeConsumer _recoveryCodeConsumer;
  final AuthEventsAuditRepository _auditRepository;

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment(MfaTotpBeginCommand command) {
    return _enrollmentService.beginTotpEnrollment(
      authorizationIdToken: command.authorizationIdToken,
      userId: command.actorUserId,
      userEmail: command.userEmail,
      issuerName: command.issuerName,
    );
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
          hashedRecoveryCodes: payload.hashedRecoveryCodes
              .map((hashed) => hashed.toJson())
              .toList(growable: false),
        );
        await _audit(
          command,
          eventType: 'auth.mfa_totp_enrolled',
          payload: <String, Object?>{
            'factor_id': persisted.totpFactorId,
            'recovery_code_count': persisted.recoveryCodeFactorIds.length,
          },
        );
        return MfaTotpConfirmCompleted(
          factorId: persisted.totpFactorId,
          recoveryCodesPlaintext: payload.recoveryCodesPlaintext,
        );
    }
  }

  @override
  Future<RecoveryCodeConsumeCompleted> consumeRecoveryCode(
    RecoveryCodeConsumeCommand command,
  ) async {
    final result = await _recoveryCodeConsumer.consume(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.actorUserId,
      rawCode: command.rawCode,
    );
    switch (result) {
      case RecoveryCodeConsumed(:final factorId):
        await _audit(
          command,
          eventType: 'auth.recovery_code_consumed',
          payload: <String, Object?>{'factor_id': factorId},
        );
        return RecoveryCodeConsumeCompleted(factorId: factorId);
      case RecoveryCodeInvalid():
        await _audit(command, eventType: 'auth.recovery_code_failed');
        throw const MfaOperationRejected(
          code: 'recovery_code_invalid',
          message: 'Recovery code was invalid or already used.',
        );
      case RecoveryCodeAlreadyUsed():
        await _audit(command, eventType: 'auth.recovery_code_failed');
        throw const MfaOperationRejected(
          code: 'recovery_code_invalid',
          message: 'Recovery code was invalid or already used.',
        );
      case RecoveryCodeRateLimited(:final retryAfter):
        throw MfaOperationRejected(
          code: 'recovery_code_rate_limited',
          message: 'Too many recovery-code attempts. Try again shortly.',
          statusCode: 429,
          retryAfter: retryAfter,
        );
      case RecoveryCodeDailyBudgetExceeded(:final resetsAt):
        throw MfaOperationRejected(
          code: 'recovery_code_daily_limit_reached',
          message: 'Recovery-code attempts are exhausted for today.',
          statusCode: 429,
          resetsAt: resetsAt,
        );
    }
  }

  Future<void> _audit(
    Object command, {
    required String eventType,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    final actorUserId = switch (command) {
      MfaTotpConfirmCommand(:final actorUserId) => actorUserId,
      RecoveryCodeConsumeCommand(:final actorUserId) => actorUserId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final operatorId = switch (command) {
      MfaTotpConfirmCommand(:final operatorId) => operatorId,
      RecoveryCodeConsumeCommand(:final operatorId) => operatorId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    final locationId = switch (command) {
      MfaTotpConfirmCommand(:final locationId) => locationId,
      RecoveryCodeConsumeCommand(:final locationId) => locationId,
      _ => throw ArgumentError.value(command, 'command'),
    };
    return _auditRepository.insertEvent(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      targetUserId: actorUserId,
      eventType: eventType,
      payload: payload,
    );
  }
}
