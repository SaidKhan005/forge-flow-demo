// Phase 9 live-closeout - app-side password-change proxy client.
//
// Sends the signed-in password-change command to the proxy. The proxy owns all
// Firebase Admin, Postgres, HIBP, and audit writes.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'password_change_gateway.dart';
import 'proxy_auth_operations_gateway.dart';

class ProxyPasswordChangeGateway implements PasswordChangeGateway {
  ProxyPasswordChangeGateway({
    required Uri proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    required ProxyAuthOperationsHttpClient httpClient,
    String Function()? idempotencyKeyFactory,
  }) : _proxyBaseUri = proxyBaseUri,
       _idTokenProvider = idTokenProvider,
       _httpClient = httpClient,
       _idempotencyKeyFactory = idempotencyKeyFactory ?? _defaultIdempotencyKey;

  static const String changePath = '/v1/auth/password/change';

  final Uri _proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final ProxyAuthOperationsHttpClient _httpClient;
  final String Function() _idempotencyKeyFactory;

  @override
  Future<PasswordChangeCompleted> changePassword(
    PasswordChangeCommand command,
  ) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const PasswordChangeRejected(
        code: 'no_id_token',
        message: 'There is no live authenticated session.',
        statusCode: 401,
      );
    }
    final response = await _httpClient.postJson(
      url: _proxyBaseUri.resolve(changePath),
      headers: <String, String>{
        HttpHeaders.authorizationHeader: 'Bearer ${token.trim()}',
        'Idempotency-Key': _idempotencyKeyFactory(),
      },
      body: <String, Object?>{
        'current_password': command.currentPassword,
        'new_password': command.newPassword,
      },
    );
    if (response.statusCode != 200) {
      throw PasswordChangeRejected(
        code: _errorCode(response),
        message: _errorMessage(response),
        statusCode: response.statusCode,
        rejections: _rejections(response.body['rejections']),
      );
    }
    return PasswordChangeCompleted(
      hibpUnavailable: response.body['hibp_unavailable'] == true,
    );
  }

  static String _errorCode(ProxyAuthOperationsResponse response) {
    final value = response.body['error'];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return 'password_change_failed';
  }

  static String _errorMessage(ProxyAuthOperationsResponse response) {
    final value = response.body['message'];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return 'Password change failed. Please try again.';
  }

  static List<String> _rejections(Object? raw) {
    if (raw is! List<Object?>) return const <String>[];
    return raw.whereType<String>().toList(growable: false);
  }

  static String _defaultIdempotencyKey() {
    final random = math.Random.secure();
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}
