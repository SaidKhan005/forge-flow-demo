// Phase 9 closeout - app-side bridge for Firebase refresh-token revoke.
//
// The Flutter SDK can sign out the current device, but revoking every
// refresh token for the account requires a trusted backend call. This small
// client sends that request to the proxy while keeping tokens in headers only.

import 'dart:io';

import 'proxy_auth_session_ledger_writer.dart';

class ProxyRefreshTokenRevoker {
  ProxyRefreshTokenRevoker({
    required Uri proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    required ProxyHttpJsonClient httpClient,
    String Function()? idempotencyKeyFactory,
  }) : _proxyBaseUri = proxyBaseUri,
       _idTokenProvider = idTokenProvider,
       _httpClient = httpClient,
       _idempotencyKeyFactory =
           idempotencyKeyFactory ??
           ProxyRefreshTokenRevoker._defaultIdempotencyKey;

  static const String revokeAllPath = '/v1/auth/refresh-tokens/revoke-all';

  final Uri _proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final ProxyHttpJsonClient _httpClient;
  final String Function() _idempotencyKeyFactory;

  Future<void> revokeAllRefreshTokens() async {
    final token = await _idTokenProvider();
    if (token == null || token.isEmpty) {
      throw ProxyAuthSessionLedgerError(
        code: 'no_id_token',
        message:
            'proxy refresh-token revoker has no live Firebase ID token to '
            'present',
      );
    }
    final response = await _httpClient.postJson(
      url: _proxyBaseUri.resolve(revokeAllPath),
      headers: <String, String>{
        HttpHeaders.authorizationHeader: 'Bearer $token',
        'Idempotency-Key': _idempotencyKeyFactory(),
      },
      body: const <String, Object?>{},
    );
    if (response.statusCode != 200) {
      throw ProxyAuthSessionLedgerError(
        code:
            _readNonBlankString(response.body['error']) ??
            'refresh_token_revoke_failed',
        message:
            _readNonBlankString(response.body['message']) ??
            'proxy returned status ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
  }

  static String _defaultIdempotencyKey() =>
      DateTime.now().microsecondsSinceEpoch.toRadixString(16);

  static String? _readNonBlankString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
