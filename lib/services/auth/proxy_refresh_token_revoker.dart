// Phase 9 closeout - app-side bridge for Firebase refresh-token revoke.
//
// The Flutter SDK can sign out the current device, but revoking every
// refresh token for the account requires a trusted backend call. This small
// client sends that request to the proxy while keeping tokens in headers only.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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

  static final math.Random _idempotencyRandom = math.Random.secure();

  /// Default idempotency key — 16 random bytes (128 bits) hex-encoded
  /// as 32 lowercase hex chars. Sourced from `Random.secure()` so two
  /// concurrent revoke calls (or a fast retry within the same
  /// microsecond) cannot collide on the same key, which would let the
  /// proxy short-circuit the second revoke as a duplicate. Mirrors the
  /// convention used by [ProxyAuthSessionLedgerWriter] and the other
  /// proxy gateways in this directory.
  static String _defaultIdempotencyKey() {
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = _idempotencyRandom.nextInt(256);
    }
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static String? _readNonBlankString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
