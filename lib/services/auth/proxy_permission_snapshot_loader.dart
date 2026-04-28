// Phase 9 live-closeout - app-side permission snapshot bridge.
//
// Loads the proxy-resolved permission snapshot after Firebase login so live
// Settings surfaces can gate themselves from server authority instead of
// widget-test injection.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../auth/permission_cache.dart';
import '../../auth/permission_effect.dart';
import '../../state/permission_context.dart';
import '../../auth/auth_session.dart';

abstract class PermissionContextLoader {
  Future<PermissionContext?> load(AuthSession session);
}

class PermissionContextLoadError implements Exception {
  const PermissionContextLoadError({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'PermissionContextLoadError(code: $code, status: $statusCode)';
}

class ProxyPermissionSnapshotResponse {
  const ProxyPermissionSnapshotResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, Object?> body;
}

abstract class ProxyPermissionSnapshotHttpClient {
  Future<ProxyPermissionSnapshotResponse> getJson({
    required Uri url,
    required Map<String, String> headers,
  });
}

class DartIoProxyPermissionSnapshotHttpClient
    implements ProxyPermissionSnapshotHttpClient {
  DartIoProxyPermissionSnapshotHttpClient({
    HttpClient? httpClient,
    Duration timeout = const Duration(seconds: 10),
  }) : _httpClient = httpClient ?? HttpClient(),
       _timeout = timeout;

  final HttpClient _httpClient;
  final Duration _timeout;

  @override
  Future<ProxyPermissionSnapshotResponse> getJson({
    required Uri url,
    required Map<String, String> headers,
  }) async {
    final request = await _httpClient.getUrl(url).timeout(_timeout);
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(_timeout);
    final raw = await utf8
        .decodeStream(response.cast<List<int>>())
        .timeout(_timeout);
    if (raw.isEmpty) {
      return ProxyPermissionSnapshotResponse(
        statusCode: response.statusCode,
        body: const <String, Object?>{},
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      decoded = const <String, Object?>{};
    }
    return ProxyPermissionSnapshotResponse(
      statusCode: response.statusCode,
      body: decoded is Map
          ? Map<String, Object?>.from(decoded)
          : const <String, Object?>{},
    );
  }
}

class ProxyPermissionContextLoader implements PermissionContextLoader {
  ProxyPermissionContextLoader({
    required Uri proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    required ProxyPermissionSnapshotHttpClient httpClient,
  }) : _proxyBaseUri = proxyBaseUri,
       _idTokenProvider = idTokenProvider,
       _httpClient = httpClient;

  final Uri _proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final ProxyPermissionSnapshotHttpClient _httpClient;

  static const String snapshotPath = '/v1/auth/permissions/snapshot';

  @override
  Future<PermissionContext?> load(AuthSession session) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const PermissionContextLoadError(
        code: 'no_id_token',
        message: 'permission snapshot has no live Firebase ID token',
      );
    }
    final response = await _httpClient.getJson(
      url: _proxyBaseUri.resolve(snapshotPath),
      headers: <String, String>{
        HttpHeaders.authorizationHeader: 'Bearer ${token.trim()}',
        'Idempotency-Key': _defaultIdempotencyKey(),
      },
    );
    if (response.statusCode != 200) {
      throw PermissionContextLoadError(
        code: _errorCode(response.body),
        message: 'permission snapshot request failed',
        statusCode: response.statusCode,
      );
    }

    final userId = _readString(response.body['user_id']);
    final operatorId = _readString(response.body['operator_id']);
    final locationId = _readString(response.body['location_id']);
    final rolesVersion = response.body['roles_version'];
    final evaluatedAtRaw = _readString(response.body['evaluated_at']);
    if (userId == null ||
        operatorId == null ||
        locationId == null ||
        rolesVersion is! int ||
        evaluatedAtRaw == null) {
      throw const PermissionContextLoadError(
        code: 'malformed_response',
        message: 'permission snapshot response was incomplete',
        statusCode: 200,
      );
    }
    if (userId != session.userId ||
        operatorId != session.operatorId ||
        locationId != session.locationId) {
      throw const PermissionContextLoadError(
        code: 'scope_mismatch',
        message: 'permission snapshot scope did not match session',
        statusCode: 200,
      );
    }

    final permissions = response.body['permissions'];
    if (permissions is! Map) {
      throw const PermissionContextLoadError(
        code: 'malformed_response',
        message: 'permission snapshot permissions map was missing',
        statusCode: 200,
      );
    }
    final entries = <String, PermissionEffect>{};
    permissions.forEach((key, value) {
      if (key is String && value == 'allow') {
        entries[key] = PermissionEffect.allow;
      } else if (key is String && value == 'deny') {
        entries[key] = PermissionEffect.deny;
      }
    });

    final requiresMfa = response.body['requires_mfa'];
    return PermissionContext(
      snapshot: PermissionSnapshot(
        userId: userId,
        rolesVersion: rolesVersion,
        operatorId: operatorId,
        locationId: locationId,
        evaluatedAt: DateTime.parse(evaluatedAtRaw).toUtc(),
        entries: entries,
      ),
      requiresMfaKeys: requiresMfa is List
          ? requiresMfa.whereType<String>().toSet()
          : const <String>{},
    );
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String _errorCode(Map<String, Object?> body) {
    final error = body['error'];
    return error is String && error.isNotEmpty ? error : 'proxy_error';
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
