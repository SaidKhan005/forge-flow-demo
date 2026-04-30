// Phase 9.UX.1 - MFA account-recovery request seam.
//
// Used from the pre-auth MFA challenge screen when a user cannot access their
// authenticator app. The client receives only a
// generic accepted response so the endpoint cannot be used to enumerate
// accounts. The proxy-side implementation resolves the restaurant admin
// recipients internally and queues an event_outbox event. A separate
// notification bridge is still required before this produces inbox/email
// delivery.

import 'dart:math' as math;
import 'dart:typed_data';

import '../../infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'mfa_recovery_request_rate_limiter.dart';

class MfaRecoveryRequestCommand {
  const MfaRecoveryRequestCommand({
    required this.email,
    this.reason = 'mfa_challenge_no_factor_access',
    this.clientIp = '',
  });

  final String email;
  final String reason;
  final String clientIp;
}

class MfaRecoveryRequestAccepted {
  const MfaRecoveryRequestAccepted({required this.queued, this.requestId});

  final bool queued;
  final String? requestId;
}

class MfaRecoveryRequestRejected implements Exception {
  const MfaRecoveryRequestRejected({
    required this.code,
    required this.message,
    this.statusCode = 422,
    this.retryAfter,
  });

  final String code;
  final String message;
  final int statusCode;
  final DateTime? retryAfter;

  @override
  String toString() {
    return 'MfaRecoveryRequestRejected(code: $code, status: $statusCode)';
  }
}

abstract class MfaRecoveryRequestGateway {
  Future<MfaRecoveryRequestAccepted> requestRecovery(
    MfaRecoveryRequestCommand command,
  );
}

class ScaffoldFailingMfaRecoveryRequestGateway
    implements MfaRecoveryRequestGateway {
  const ScaffoldFailingMfaRecoveryRequestGateway();

  @override
  Future<MfaRecoveryRequestAccepted> requestRecovery(
    MfaRecoveryRequestCommand command,
  ) {
    throw const MfaRecoveryRequestRejected(
      code: 'mfa_recovery_request_not_configured',
      message: 'MFA recovery requests are not configured.',
      statusCode: 503,
    );
  }
}

class RepositoryMfaRecoveryRequestGateway implements MfaRecoveryRequestGateway {
  RepositoryMfaRecoveryRequestGateway({
    required UsersRepository usersRepository,
    required EventOutboxRepository eventOutboxRepository,
    MfaRecoveryRequestRateLimiter? rateLimiter,
    String Function()? idFactory,
    DateTime Function()? now,
  }) : _usersRepository = usersRepository,
       _eventOutboxRepository = eventOutboxRepository,
       _rateLimiter = rateLimiter,
       _idFactory = idFactory ?? _uuidV4,
       _now = now ?? DateTime.now;

  final UsersRepository _usersRepository;
  final EventOutboxRepository _eventOutboxRepository;
  final MfaRecoveryRequestRateLimiter? _rateLimiter;
  final String Function() _idFactory;
  final DateTime Function() _now;

  @override
  Future<MfaRecoveryRequestAccepted> requestRecovery(
    MfaRecoveryRequestCommand command,
  ) async {
    final email = command.email.trim().toLowerCase();
    if (email.isEmpty || !email.contains('@')) {
      throw const MfaRecoveryRequestRejected(
        code: 'invalid_email',
        message: 'Enter a valid email address.',
        statusCode: 400,
      );
    }
    final limiter = _rateLimiter;
    if (limiter != null) {
      final decision = await limiter.checkAndRecord(
        normalizedEmail: email,
        clientIp: command.clientIp,
      );
      if (!decision.isAllowed) {
        throw MfaRecoveryRequestRejected(
          code: 'mfa_recovery_request_rate_limited',
          message: 'Too many recovery requests. Try again later.',
          statusCode: 429,
          retryAfter: decision.retryAfter,
        );
      }
    }

    final target = await _usersRepository.findMfaRecoveryTargetByEmail(
      email: email,
      adminReason: 'mfa_recovery_request_lookup',
    );
    if (target == null || target.locationId == null || target.admins.isEmpty) {
      return const MfaRecoveryRequestAccepted(queued: false);
    }

    final requestId = _idFactory();
    final occurredAt = _now().toUtc();
    await _eventOutboxRepository.enqueue(
      operatorId: target.operatorId,
      locationId: target.locationId!,
      userId: target.userId,
      topic: 'auth.user.mfa_recovery_requested',
      payload: <String, Object?>{
        'event_id': requestId,
        'occurred_at': occurredAt.toIso8601String(),
        'event_type': 'auth.user.mfa_recovery_requested',
        'user_id': target.userId,
        'user_email': target.email,
        'operator_id': target.operatorId,
        'location_id': target.locationId,
        'reason': command.reason,
        'admin_user_ids': <String>[
          for (final admin in target.admins) admin.userId,
        ],
        'admin_emails': <String>[
          for (final admin in target.admins) admin.email,
        ],
      },
    );
    return MfaRecoveryRequestAccepted(queued: true, requestId: requestId);
  }

  static String _uuidV4() {
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
}
