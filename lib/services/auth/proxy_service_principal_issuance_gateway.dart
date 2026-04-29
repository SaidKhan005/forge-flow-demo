// Phase 9 B41 - app-side proxy client for service-principal JWT issuance.
//
// Flutter never signs service-principal tokens. It calls the proxy, which
// verifies the human admin, checks the MFA-required permission key, writes
// the audit row, and returns a short-lived `sp:` JWT.

import 'dart:math' as math;
import 'dart:typed_data';

import 'proxy_auth_operations_gateway.dart';

class ServicePrincipalJwtIssued {
  const ServicePrincipalJwtIssued({required this.jwt, required this.expiresAt});

  final String jwt;
  final DateTime expiresAt;
}

class ProxyServicePrincipalIssuanceError implements Exception {
  const ProxyServicePrincipalIssuanceError({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'ProxyServicePrincipalIssuanceError(code: $code, status: $statusCode)';
}

class ProxyServicePrincipalIssuanceGateway {
  ProxyServicePrincipalIssuanceGateway({
    required Uri proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    required ProxyAuthOperationsHttpClient httpClient,
    String Function()? idempotencyKeyFactory,
  }) : _proxyBaseUri = proxyBaseUri,
       _idTokenProvider = idTokenProvider,
       _httpClient = httpClient,
       _idempotencyKeyFactory = idempotencyKeyFactory ?? _defaultIdempotencyKey;

  final Uri _proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final ProxyAuthOperationsHttpClient _httpClient;
  final String Function() _idempotencyKeyFactory;

  static const String servicePrincipalsPrefix = '/v1/admin/service-principals/';

  Future<ServicePrincipalJwtIssued> issueJwt({
    required String servicePrincipalId,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const ProxyServicePrincipalIssuanceError(
        code: 'missing_id_token',
        message: 'No signed-in admin token is available.',
      );
    }

    final encodedId = Uri.encodeComponent(servicePrincipalId);
    final response = await _httpClient.postJson(
      url: _proxyBaseUri.resolve('$servicePrincipalsPrefix$encodedId/jwt'),
      headers: <String, String>{
        'Authorization': 'Bearer ${token.trim()}',
        'Idempotency-Key': _idempotencyKeyFactory(),
      },
      body: const <String, Object?>{},
    );
    _expectStatus(response, 200);

    final jwt = response.body['jwt'];
    final expiresAtRaw = response.body['expires_at'];
    final expiresAt = expiresAtRaw is String
        ? DateTime.tryParse(expiresAtRaw)
        : null;
    if (jwt is! String || jwt.isEmpty || expiresAt == null) {
      throw _malformed(response, 'service-principal JWT response incomplete');
    }

    return ServicePrincipalJwtIssued(jwt: jwt, expiresAt: expiresAt.toUtc());
  }

  static void _expectStatus(
    ProxyAuthOperationsResponse response,
    int expected,
  ) {
    if (response.statusCode == expected) return;
    final code = response.body['error']?.toString() ?? 'proxy_error';
    final message =
        response.body['message']?.toString() ?? 'Proxy request failed.';
    throw ProxyServicePrincipalIssuanceError(
      code: code,
      message: message,
      statusCode: response.statusCode,
    );
  }

  static ProxyServicePrincipalIssuanceError _malformed(
    ProxyAuthOperationsResponse response,
    String message,
  ) {
    return ProxyServicePrincipalIssuanceError(
      code: 'malformed_proxy_response',
      message: message,
      statusCode: response.statusCode,
    );
  }

  static String _defaultIdempotencyKey() {
    final bytes = Uint8List(16);
    final random = math.Random.secure();
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'sp-issue-$hex';
  }
}
