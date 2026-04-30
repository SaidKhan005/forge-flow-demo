// Phase 9.UX.1 - app-side proxy client for MFA recovery requests.

import '../auth/proxy_auth_operations_gateway.dart';
import 'mfa_recovery_request_gateway.dart';

class ProxyMfaRecoveryRequestGateway implements MfaRecoveryRequestGateway {
  ProxyMfaRecoveryRequestGateway({
    required Uri proxyBaseUri,
    required ProxyAuthOperationsHttpClient httpClient,
  }) : _proxyBaseUri = proxyBaseUri,
       _httpClient = httpClient;

  final Uri _proxyBaseUri;
  final ProxyAuthOperationsHttpClient _httpClient;

  static const String recoveryRequestPath = '/v1/auth/mfa/recovery/request';

  @override
  Future<MfaRecoveryRequestAccepted> requestRecovery(
    MfaRecoveryRequestCommand command,
  ) async {
    final response = await _httpClient.postJson(
      url: _proxyBaseUri.resolve(recoveryRequestPath),
      headers: const <String, String>{},
      body: <String, Object?>{'email': command.email, 'reason': command.reason},
    );
    if (response.statusCode != 202) {
      throw MfaRecoveryRequestRejected(
        code: _readString(response.body['error']) ?? 'mfa_recovery_failed',
        message:
            _readString(response.body['message']) ??
            'MFA recovery request failed.',
        statusCode: response.statusCode,
      );
    }
    return MfaRecoveryRequestAccepted(
      queued: response.body['queued'] == true,
      requestId: _readString(response.body['request_id']),
    );
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
