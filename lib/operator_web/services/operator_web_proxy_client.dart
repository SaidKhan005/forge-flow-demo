// Phase 11W.live - Flutter Web proxy client.
//
// The existing mobile/admin proxy gateway implementations import `dart:io`.
// This client intentionally stays web-safe so `lib/main_operator_web.dart`
// can build as a Flutter Web target.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../services/auth/account_info_gateway.dart';

class OperatorWebProxyClient {
  OperatorWebProxyClient({
    required this.baseUri,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
    String Function()? idempotencyKeyFactory,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout,
       _idempotencyKeyFactory = idempotencyKeyFactory ?? _defaultIdempotencyKey;

  final Uri baseUri;
  final http.Client _httpClient;
  final Duration _timeout;
  final String Function() _idempotencyKeyFactory;

  static const String authSessionLoginPath = '/v1/auth/session/login';
  static const String authAccountInfoPath = '/v1/auth/account';
  static const String authPermissionsSnapshotPath =
      '/v1/auth/permissions/snapshot';
  static const String authPasswordChangePath = '/v1/auth/password/change';
  static const String authMfaTotpBeginPath = '/v1/auth/mfa/totp/begin';
  static const String authMfaTotpConfirmPath = '/v1/auth/mfa/totp/confirm';

  Future<OperatorWebSessionLedgerRecord> recordSessionLogin({
    required String idToken,
    required String tokenHash,
    String? email,
  }) async {
    final response = await postJson(
      authSessionLoginPath,
      idToken: idToken,
      body: <String, Object?>{
        'token_hash': tokenHash,
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
      },
    );
    final sessionId = _readString(response.body['session_id']);
    final userId = _readString(response.body['user_id']);
    final operatorId = _readString(response.body['operator_id']);
    final locationId = _readString(response.body['location_id']);
    if (sessionId == null ||
        userId == null ||
        operatorId == null ||
        locationId == null) {
      throw const OperatorWebProxyException(
        code: 'malformed_session_response',
        message: 'The proxy returned an incomplete session record.',
      );
    }
    return OperatorWebSessionLedgerRecord(
      sessionId: sessionId,
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
    );
  }

  Future<AccountInfo> loadAccountInfo({required String idToken}) async {
    final response = await getJson(authAccountInfoPath, idToken: idToken);
    try {
      return AccountInfo.fromJson(response.body);
    } on AccountInfoUnavailable catch (error) {
      throw OperatorWebProxyException(code: error.code, message: error.message);
    }
  }

  Future<OperatorWebPermissionSnapshot> loadPermissionSnapshot({
    required String idToken,
  }) async {
    final response = await getJson(
      authPermissionsSnapshotPath,
      idToken: idToken,
    );
    return OperatorWebPermissionSnapshot.fromJson(response.body);
  }

  Future<OperatorWebPasswordChangeResult> changePassword({
    required String idToken,
    required String currentPassword,
    required String newPassword,
  }) async {
    final response = await postJson(
      authPasswordChangePath,
      idToken: idToken,
      body: <String, Object?>{
        'current_password': currentPassword,
        'new_password': newPassword,
      },
    );
    return OperatorWebPasswordChangeResult(
      hibpUnavailable: response.body['hibp_unavailable'] == true,
    );
  }

  Future<OperatorWebTotpEnrollment> beginTotpEnrollment({
    required String idToken,
    required String email,
    String issuerName = 'Forge & Flow',
  }) async {
    final response = await postJson(
      authMfaTotpBeginPath,
      idToken: idToken,
      body: <String, Object?>{'user_email': email, 'issuer_name': issuerName},
    );
    final factorId = _readString(response.body['factor_id']);
    final secret = _readString(response.body['secret_base32']);
    final otpAuthUrl = _readString(response.body['otp_auth_url']);
    if (factorId == null || secret == null || otpAuthUrl == null) {
      throw const OperatorWebProxyException(
        code: 'malformed_mfa_begin_response',
        message: 'The proxy returned an incomplete MFA setup response.',
      );
    }
    return OperatorWebTotpEnrollment(
      factorId: factorId,
      secretBase32: secret,
      otpAuthUrl: otpAuthUrl,
    );
  }

  Future<void> confirmTotpEnrollment({
    required String idToken,
    required String factorId,
    required String oneTimeCode,
    String issuerName = 'Forge & Flow',
  }) async {
    await postJson(
      authMfaTotpConfirmPath,
      idToken: idToken,
      body: <String, Object?>{
        'factor_id': factorId,
        'one_time_code': oneTimeCode,
        'issuer_name': issuerName,
      },
    );
  }

  Future<OperatorWebJsonResponse> getJson(
    String path, {
    required String idToken,
    Map<String, String>? queryParameters,
  }) async {
    final request = http.Request(
      'GET',
      _resolve(path, queryParameters: queryParameters),
    );
    _applyHeaders(request, idToken: idToken);
    final response = await _send(request);
    _throwIfUnsuccessful(response, path);
    return response;
  }

  Future<OperatorWebJsonResponse> postJson(
    String path, {
    required String idToken,
    Map<String, Object?> body = const <String, Object?>{},
    Map<String, String>? queryParameters,
  }) async {
    final request = http.Request(
      'POST',
      _resolve(path, queryParameters: queryParameters),
    );
    _applyHeaders(request, idToken: idToken);
    request.body = jsonEncode(body);
    final response = await _send(request);
    _throwIfUnsuccessful(response, path);
    return response;
  }

  Future<OperatorWebJsonResponse> patchJson(
    String path, {
    required String idToken,
    Map<String, Object?> body = const <String, Object?>{},
    Map<String, String>? queryParameters,
  }) async {
    final request = http.Request(
      'PATCH',
      _resolve(path, queryParameters: queryParameters),
    );
    _applyHeaders(request, idToken: idToken);
    request.body = jsonEncode(body);
    final response = await _send(request);
    _throwIfUnsuccessful(response, path);
    return response;
  }

  Uri _resolve(String path, {Map<String, String>? queryParameters}) {
    final uri = baseUri.resolve(path);
    if (queryParameters == null || queryParameters.isEmpty) return uri;
    return uri.replace(
      queryParameters: <String, String>{
        ...uri.queryParameters,
        ...queryParameters,
      },
    );
  }

  void _applyHeaders(http.Request request, {required String idToken}) {
    request.headers.addAll(<String, String>{
      'accept': 'application/json',
      'content-type': 'application/json',
      'authorization': 'Bearer ${idToken.trim()}',
      'Idempotency-Key': _idempotencyKeyFactory(),
    });
  }

  Future<OperatorWebJsonResponse> _send(http.Request request) async {
    final streamed = await _httpClient.send(request).timeout(_timeout);
    final raw = await streamed.stream.bytesToString().timeout(_timeout);
    Object? decoded;
    if (raw.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        decoded = const <String, Object?>{};
      }
    }
    final body = decoded is Map<Object?, Object?>
        ? Map<String, Object?>.from(decoded)
        : const <String, Object?>{};
    return OperatorWebJsonResponse(statusCode: streamed.statusCode, body: body);
  }

  void _throwIfUnsuccessful(OperatorWebJsonResponse response, String path) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw OperatorWebProxyException(
      code: _readString(response.body['error']) ?? 'proxy_request_failed',
      message:
          _readString(response.body['message']) ??
          'The operator web proxy could not complete $path.',
      statusCode: response.statusCode,
    );
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String _defaultIdempotencyKey() {
    final random = math.Random.secure();
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

class OperatorWebJsonResponse {
  const OperatorWebJsonResponse({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, Object?> body;
}

class OperatorWebProxyException implements Exception {
  const OperatorWebProxyException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'OperatorWebProxyException(code: $code)';
}

class OperatorWebSessionLedgerRecord {
  const OperatorWebSessionLedgerRecord({
    required this.sessionId,
    required this.userId,
    required this.operatorId,
    required this.locationId,
  });

  final String sessionId;
  final String userId;
  final String operatorId;
  final String locationId;
}

class OperatorWebPermissionSnapshot {
  const OperatorWebPermissionSnapshot({
    required this.userId,
    required this.operatorId,
    required this.locationId,
    required this.rolesVersion,
    required this.evaluatedAt,
    required this.permissions,
    this.requiresMfaKeys = const <String>{},
  });

  final String userId;
  final String operatorId;
  final String locationId;
  final int rolesVersion;
  final DateTime evaluatedAt;
  final Map<String, String> permissions;
  final Set<String> requiresMfaKeys;

  Set<String> get allowedPermissions => permissions.entries
      .where((entry) => entry.value == 'allow')
      .map((entry) => entry.key)
      .toSet();

  bool allows(String permissionKey) => permissions[permissionKey] == 'allow';

  static OperatorWebPermissionSnapshot fromJson(Map<String, Object?> json) {
    final userId = OperatorWebProxyClient._readString(json['user_id']);
    final operatorId = OperatorWebProxyClient._readString(json['operator_id']);
    final locationId = OperatorWebProxyClient._readString(json['location_id']);
    final rolesVersion = json['roles_version'];
    final evaluatedAtRaw = OperatorWebProxyClient._readString(
      json['evaluated_at'],
    );
    final permissionsRaw = json['permissions'];
    if (userId == null ||
        operatorId == null ||
        locationId == null ||
        rolesVersion is! int ||
        evaluatedAtRaw == null ||
        permissionsRaw is! Map) {
      throw const OperatorWebProxyException(
        code: 'malformed_permission_snapshot',
        message: 'The proxy returned an incomplete permission snapshot.',
      );
    }
    final permissions = <String, String>{};
    permissionsRaw.forEach((key, value) {
      if (key is String && value is String) {
        final effect = value.trim();
        if (effect == 'allow' || effect == 'deny') permissions[key] = effect;
      }
    });
    final requiresMfaRaw = json['requires_mfa'];
    return OperatorWebPermissionSnapshot(
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
      rolesVersion: rolesVersion,
      evaluatedAt: DateTime.parse(evaluatedAtRaw).toUtc(),
      permissions: Map<String, String>.unmodifiable(permissions),
      requiresMfaKeys: requiresMfaRaw is List
          ? requiresMfaRaw.whereType<String>().toSet()
          : const <String>{},
    );
  }
}

class OperatorWebPasswordChangeResult {
  const OperatorWebPasswordChangeResult({required this.hibpUnavailable});

  final bool hibpUnavailable;
}

class OperatorWebTotpEnrollment {
  const OperatorWebTotpEnrollment({
    required this.factorId,
    required this.secretBase32,
    required this.otpAuthUrl,
  });

  final String factorId;
  final String secretBase32;
  final String otpAuthUrl;
}
