// Phase 9.UX.7 - app-side password-reset proxy client.
//
// Sends the self-serve reset request and confirm payloads to the proxy.
// The proxy owns Firebase action-link issuance, oobCode resolution,
// HIBP screening, last-5 password-history reuse, and audit writes.
// Both routes are unauthenticated from the operator's perspective —
// the request route is the public "send me a link" surface, and the
// confirm route is hit from the email-link deep-link before the
// operator has signed back in.

import 'dart:math' as math;
import 'dart:typed_data';

import 'password_reset_gateway.dart';
import 'proxy_auth_operations_gateway.dart';

class ProxyPasswordResetGateway implements PasswordResetGateway {
  ProxyPasswordResetGateway({
    required Uri proxyBaseUri,
    required ProxyAuthOperationsHttpClient httpClient,
    String Function()? idempotencyKeyFactory,
  }) : _proxyBaseUri = proxyBaseUri,
       _httpClient = httpClient,
       _idempotencyKeyFactory = idempotencyKeyFactory ?? _defaultIdempotencyKey;

  static const String requestPath = '/v1/auth/password/reset/request';
  static const String confirmPath = '/v1/auth/password/reset/confirm';

  final Uri _proxyBaseUri;
  final ProxyAuthOperationsHttpClient _httpClient;
  final String Function() _idempotencyKeyFactory;

  @override
  Future<PasswordResetRequested> requestReset(
    PasswordResetRequestCommand command,
  ) async {
    // Honor caller-supplied key when present so a retry of the
    // same logical submit replays the proxy's cached response.
    // Falls back to a fresh per-call key only when the caller
    // does not own the lifecycle (e.g., scripted tests).
    final idempotencyKey =
        command.idempotencyKey ?? _idempotencyKeyFactory();
    final response = await _httpClient.postJson(
      url: _proxyBaseUri.resolve(requestPath),
      headers: <String, String>{'Idempotency-Key': idempotencyKey},
      body: <String, Object?>{'email': command.email},
    );
    if (response.statusCode == 200 || response.statusCode == 202) {
      return const PasswordResetRequested();
    }
    if (response.statusCode == 429) {
      throw PasswordResetRejected(
        code: 'rate_limited',
        message:
            'Too many reset requests. Please wait a moment and try again.',
        statusCode: response.statusCode,
        rejections: _rejections(response.body['rejections']),
      );
    }
    throw PasswordResetRejected(
      code: _errorCode(response, fallback: 'password_reset_request_failed'),
      message: _errorMessage(
        response,
        fallback: 'Password reset is unavailable. Please try again.',
      ),
      statusCode: response.statusCode,
      rejections: _rejections(response.body['rejections']),
    );
  }

  @override
  Future<PasswordResetConfirmed> confirmReset(
    PasswordResetConfirmRequest request,
  ) async {
    // Confirm retries are the high-stakes case: oobCode is single-
    // use, so without dedupe a retry surfaces password_reset_expired
    // even when the original submit succeeded server-side. Honor
    // the caller-supplied key first.
    final idempotencyKey =
        request.idempotencyKey ?? _idempotencyKeyFactory();
    final response = await _httpClient.postJson(
      url: _proxyBaseUri.resolve(confirmPath),
      headers: <String, String>{'Idempotency-Key': idempotencyKey},
      body: <String, Object?>{
        'oob_code': request.oobCode,
        'new_password': request.newPassword,
      },
    );
    if (response.statusCode == 200) {
      return PasswordResetConfirmed(
        hibpUnavailable: response.body['hibp_unavailable'] == true,
      );
    }
    throw PasswordResetRejected(
      code: _errorCode(response, fallback: 'password_reset_confirm_failed'),
      message: _errorMessage(
        response,
        fallback: 'Password reset could not be completed. Please try again.',
      ),
      statusCode: response.statusCode,
      rejections: _rejections(response.body['rejections']),
    );
  }

  static String _errorCode(
    ProxyAuthOperationsResponse response, {
    required String fallback,
  }) {
    final value = response.body['error'];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return fallback;
  }

  static String _errorMessage(
    ProxyAuthOperationsResponse response, {
    required String fallback,
  }) {
    final value = response.body['message'];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return fallback;
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
