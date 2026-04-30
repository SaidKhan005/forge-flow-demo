// Phase 9 live-closeout - app-side proxy MFA operations gateway.
//
// Sends MFA enrollment and factor-management commands to the proxy. The app
// never talks to Postgres; launch UX does not display or accept recovery codes.

import 'dart:async';
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
  static const String factorsListPath = '/v1/auth/mfa/factors/list';
  static const String factorsRevokePath = '/v1/auth/mfa/factors/revoke';
  static const String factorsRemovalCancelPath =
      '/v1/auth/mfa/factors/removal/cancel';

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
  Future<MfaListFactorsCompleted> listFactors(
    MfaListFactorsCommand command,
  ) async {
    final response = await _post(factorsListPath, const <String, Object?>{});
    _expectStatus(response, 200);
    final rawFactors = response.body['factors'];
    if (rawFactors is! List) {
      throw const MfaOperationRejected(
        code: 'malformed_response',
        message: 'MFA factors response was incomplete.',
      );
    }
    final rawRemovalRequests = response.body['removal_requests'];
    if (rawRemovalRequests != null && rawRemovalRequests is! List) {
      throw const MfaOperationRejected(
        code: 'malformed_response',
        message: 'MFA removal request response was incomplete.',
      );
    }
    final removalItems = rawRemovalRequests is List
        ? rawRemovalRequests
        : const <Object?>[];
    return MfaListFactorsCompleted(
      factors: List<MfaFactorSummary>.unmodifiable(
        rawFactors.map(_factorFromJson),
      ),
      removalRequests: List<MfaRemovalRequestSummary>.unmodifiable(
        removalItems.map(_removalRequestFromJson),
      ),
    );
  }

  @override
  Future<MfaRevokeFactorCompleted> revokeFactor(
    MfaRevokeFactorCommand command,
  ) async {
    final response = await _post(factorsRevokePath, <String, Object?>{
      'factor_id': command.factorId,
      if (command.stepUpProofId.trim().isNotEmpty)
        'step_up_proof_id': command.stepUpProofId,
    });
    _expectStatus(response, 200);
    final revoked = response.body['revoked'];
    if (revoked is! bool) {
      throw const MfaOperationRejected(
        code: 'malformed_response',
        message: 'MFA revoke response was incomplete.',
      );
    }
    return MfaRevokeFactorCompleted(
      revoked: revoked,
      requestId: _readString(response.body['request_id']),
      executeAfter: _readDateTime(response.body['execute_after']),
    );
  }

  @override
  Future<MfaCancelFactorRemovalCompleted> cancelFactorRemoval(
    MfaCancelFactorRemovalCommand command,
  ) async {
    final response = await _post(factorsRemovalCancelPath, <String, Object?>{
      'request_id': command.requestId,
    });
    _expectStatus(response, 200);
    final cancelled = response.body['cancelled'];
    if (cancelled is! bool) {
      throw const MfaOperationRejected(
        code: 'malformed_response',
        message: 'MFA cancel response was incomplete.',
      );
    }
    return MfaCancelFactorRemovalCompleted(cancelled: cancelled);
  }

  @override
  Future<MfaRevokeUserFactorsCompleted> revokeUserFactors(
    MfaRevokeUserFactorsCommand command,
  ) async {
    throw const MfaOperationRejected(
      code: 'unsupported_client_operation',
      message: 'Team MFA reset uses AuthOperationsGateway.',
      statusCode: 400,
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
    if (factorId == null) {
      throw const MfaOperationRejected(
        code: 'malformed_response',
        message: 'MFA confirm response was incomplete.',
      );
    }
    return MfaTotpConfirmCompleted(factorId: factorId);
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
    try {
      return await _httpClient.postJson(
        url: _proxyBaseUri.resolve(relativePath),
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer ${token.trim()}',
        },
        body: body,
      );
    } on TimeoutException {
      throw const MfaOperationRejected(
        code: 'mfa_proxy_timeout',
        message: 'Could not reach MFA settings. Check connection and retry.',
        statusCode: 503,
      );
    } on SocketException {
      throw const MfaOperationRejected(
        code: 'mfa_proxy_unreachable',
        message: 'Could not reach MFA settings. Check connection and retry.',
        statusCode: 503,
      );
    } on HttpException {
      throw const MfaOperationRejected(
        code: 'mfa_proxy_unavailable',
        message: 'MFA settings are temporarily unavailable.',
        statusCode: 503,
      );
    }
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

  static MfaFactorSummary _factorFromJson(Object? value) {
    if (value is! Map) {
      throw const MfaOperationRejected(
        code: 'malformed_response',
        message: 'MFA factor payload was incomplete.',
      );
    }
    final json = Map<String, Object?>.from(value);
    final factorId = _readString(json['factor_id']);
    final factorType = _readString(json['factor_type']);
    final enrolledAt = _readDateTime(json['enrolled_at']);
    final issuerLabel = _readString(json['issuer_label']) ?? 'Forge & Flow';
    if (factorId == null || factorType == null || enrolledAt == null) {
      throw const MfaOperationRejected(
        code: 'malformed_response',
        message: 'MFA factor payload was incomplete.',
      );
    }
    return MfaFactorSummary(
      factorId: factorId,
      factorType: factorType,
      enrolledAt: enrolledAt,
      lastUsedAt: _readDateTime(json['last_used_at']),
      issuerLabel: issuerLabel,
      canRevoke: json['can_revoke'] is bool ? json['can_revoke'] as bool : true,
    );
  }

  static MfaRemovalRequestSummary _removalRequestFromJson(Object? value) {
    if (value is! Map) {
      throw const MfaOperationRejected(
        code: 'malformed_response',
        message: 'MFA removal request payload was incomplete.',
      );
    }
    final json = Map<String, Object?>.from(value);
    final requestId = _readString(json['request_id']);
    final factorId = _readString(json['factor_id']);
    final status = _readString(json['status']);
    final executeAfter = _readDateTime(json['execute_after']);
    if (requestId == null ||
        factorId == null ||
        status == null ||
        executeAfter == null) {
      throw const MfaOperationRejected(
        code: 'malformed_response',
        message: 'MFA removal request payload was incomplete.',
      );
    }
    return MfaRemovalRequestSummary(
      requestId: requestId,
      factorId: factorId,
      status: status,
      executeAfter: executeAfter,
      completedAt: _readDateTime(json['completed_at']),
    );
  }
}
