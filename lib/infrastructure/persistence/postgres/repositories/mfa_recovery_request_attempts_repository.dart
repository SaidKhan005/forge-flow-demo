import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:forge_and_flow/services/mfa/mfa_recovery_request_rate_limiter.dart';

import '../operator_scoped_repository.dart';

class PostgresMfaRecoveryRequestRateLimiter extends OperatorScopedRepository
    implements MfaRecoveryRequestRateLimiter {
  PostgresMfaRecoveryRequestRateLimiter(
    super.tenantWrapper, {
    this.emailCooldown = const Duration(minutes: 15),
    this.ipWindow = const Duration(minutes: 10),
    this.maxRequestsPerIpWindow = 10,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration emailCooldown;
  final Duration ipWindow;
  final int maxRequestsPerIpWindow;
  final DateTime Function() _now;

  @override
  Future<MfaRecoveryRateLimitDecision> checkAndRecord({
    required String normalizedEmail,
    required String clientIp,
  }) {
    final now = _now().toUtc();
    final emailHash = _sha256(normalizedEmail.trim().toLowerCase());
    final ipHash = _sha256(clientIp.trim().isEmpty ? 'unknown' : clientIp);
    final emailWindowStart = now.subtract(emailCooldown);
    final ipWindowStart = now.subtract(ipWindow);

    return withSystem<MfaRecoveryRateLimitDecision>((exec) async {
      final emailRows = await exec.query(
        'select attempted_at from mfa_recovery_request_attempts '
        'where email_hash = @email_hash '
        'and attempted_at >= @window_start::timestamptz '
        'order by attempted_at desc limit 1',
        parameters: <String, Object?>{
          'email_hash': emailHash,
          'window_start': emailWindowStart,
        },
      );
      if (emailRows.isNotEmpty) {
        final attemptedAt = emailRows.single['attempted_at'] as DateTime;
        return MfaRecoveryRateLimitDecision.blocked(
          retryAfter: attemptedAt.toUtc().add(emailCooldown),
        );
      }

      final ipRows = await exec.query(
        'select attempted_at from mfa_recovery_request_attempts '
        'where ip_hash = @ip_hash '
        'and attempted_at >= @window_start::timestamptz '
        'order by attempted_at asc',
        parameters: <String, Object?>{
          'ip_hash': ipHash,
          'window_start': ipWindowStart,
        },
      );
      if (ipRows.length >= maxRequestsPerIpWindow) {
        final firstAttempt = ipRows.first['attempted_at'] as DateTime;
        return MfaRecoveryRateLimitDecision.blocked(
          retryAfter: firstAttempt.toUtc().add(ipWindow),
        );
      }

      await exec.execute(
        'insert into mfa_recovery_request_attempts '
        '(email_hash, ip_hash, attempted_at) '
        'values (@email_hash, @ip_hash, @attempted_at::timestamptz)',
        parameters: <String, Object?>{
          'email_hash': emailHash,
          'ip_hash': ipHash,
          'attempted_at': now,
        },
      );
      await exec.execute(
        'delete from mfa_recovery_request_attempts '
        'where attempted_at < @prune_before::timestamptz',
        parameters: <String, Object?>{
          'prune_before': now.subtract(const Duration(days: 1)),
        },
      );
      return const MfaRecoveryRateLimitDecision.allowed();
    }, reason: 'auth.mfa_recovery_request_rate_limit');
  }

  static String _sha256(String value) {
    return sha256.convert(utf8.encode(value)).toString();
  }
}
