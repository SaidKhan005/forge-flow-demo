// Phase 9 live-closeout - app-side proxy MFA operations gateway.
//
// Sends MFA enrollment and recovery-code commands to the proxy. The app never
// talks to Postgres and never receives anything beyond display-once recovery
// codes after a successful TOTP confirmation.

import 'dart:io';

import '../auth/proxy_auth_operations_gateway.dart';
import 'mfa_enrollment_service.dart';
import 'mfa_operations_gateway.dart';

class ProxyMfaOperationsGateway implements MfaOperationsGateway {
  ProxyMfaOperationsGateway({
    required Uri proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    required ProxyAuthOperationsHttpClient httpClient,
  }) : _proxyBaseUri = proxyBaseUri,
       _idTokenProvider = idTokenProvider,
       _httpClient = httpClient;

  final Uri _proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final ProxyAuthOperationsHttpClient _httpClient;

  static const String totpBeginPath = '/v1/auth/mfa/totp/begin';
  static const String totpConfirmPath = '/v1/auth/mfa/totp/confirm';
  static const String recoveryConsumePath = '/v1/auth/mfa/recovery/consume';

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment(
    MfaTotpBeginCommand command,
  ) async {
    final response = await _post(totpBeginPath, <String, Object?>{
      'user_email': command.userEmail,
      'issuer_name': command.issuerName,
    });
    _expectStatus(response, 200);
    final factorId = _readString(response.body['factor_id']);
    final secretBase32 = _readString(response.body['secret_base32']);
    final otpAuthUrl = _readString(response.body['otp_auth_url']);
    if (factorId == null || secretBase32 == null || otpAuthUrl == null) {
      throw const MfaOperationRejected(
        code: 'malformed_response',
        message: 'MFA begin response was incomplete.',
      );
    }
    return TotpEnrollmentSetup(
      factorId: factorId,
      secretBase32: secretBase32,
      otpAuthUrl: otpAuthUrl,
    );
  }

  @override
  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  ) async {
    final response = await _post(totpConfirmPath, <String, Object?>{
      'factor_id': command.factorId,
      'one_time_code': command.oneTimeCode,
      'issuer_name': command.issuerName,
    });
    _expectStatus(response, 200);
    final factorId = _readString(response.body['factor_id']);
    final recoveryCodes = response.body['recovery_codes'];
    if (factorId == null || recoveryCodes is! List) {
      throw const MfaOperationRejected(
        code: 'malformed_response',
        message: 'MFA confirm response was incomplete.',
      );
    }
    return MfaTotpConfirmCompleted(
      factorId: factorId,
      recoveryCodesPlaintext: recoveryCodes.whereType<String>().toList(
        growable: false,
      ),
    );
  }

  @override
  Future<RecoveryCodeConsumeCompleted> consumeRecoveryCode(
    RecoveryCodeConsumeCommand command,
  ) async {
    final response = await _post(recoveryConsumePath, <String, Object?>{
      'recovery_code': command.rawCode,
    });
    _expectStatus(response, 200);
    final factorId = _readString(response.body['factor_id']);
    if (factorId == null) {
      throw const MfaOperationRejected(
        code: 'malformed_response',
        message: 'Recovery-code response was incomplete.',
      );
    }
    return RecoveryCodeConsumeCompleted(factorId: factorId);
  }

  Future<ProxyAuthOperationsResponse> _post(
    String relativePath,
    Map<String, Object?> body,
  ) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const MfaOperationRejected(
        code: 'no_id_token',
        message: 'MFA operations gateway has no live Firebase ID token.',
        statusCode: 401,
      );
    }
    return _httpClient.postJson(
      url: _proxyBaseUri.resolve(relativePath),
      headers: <String, String>{
        HttpHeaders.authorizationHeader: 'Bearer ${token.trim()}',
      },
      body: body,
    );
  }

  void _expectStatus(ProxyAuthOperationsResponse response, int expected) {
    if (response.statusCode == expected) return;
    throw MfaOperationRejected(
      code: _readString(response.body['error']) ?? 'mfa_operation_failed',
      message:
          _readString(response.body['message']) ??
          'Proxy returned status ${response.statusCode}.',
      statusCode: response.statusCode,
      retryAfter: _readDateTime(response.body['retry_after']),
      resetsAt: _readDateTime(response.body['resets_at']),
    );
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static DateTime? _readDateTime(Object? value) {
    final raw = _readString(value);
    if (raw == null) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }
}
