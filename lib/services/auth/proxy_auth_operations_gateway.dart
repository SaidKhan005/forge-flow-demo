// Phase 9 live-closeout - app-side proxy auth-operations gateway.
//
// Team/user-management actions must not run directly from Flutter against
// Firebase Admin SDK or Postgres. This client sends the narrow commands from
// AuthOperationsGateway to the proxy's `/v1/admin/auth/*` routes, where the
// bearer token is verified, permissions are checked, and the multi-system
// write happens server-side.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'auth_operations_gateway.dart';

class ProxyAuthOperationsResponse {
  const ProxyAuthOperationsResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, Object?> body;
}

abstract class ProxyAuthOperationsHttpClient {
  Future<ProxyAuthOperationsResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  });

  Future<ProxyAuthOperationsResponse> deleteJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  });
}

class DartIoProxyAuthOperationsHttpClient
    implements ProxyAuthOperationsHttpClient {
  DartIoProxyAuthOperationsHttpClient({
    HttpClient? httpClient,
    Duration timeout = const Duration(seconds: 10),
  }) : _httpClient = httpClient ?? HttpClient(),
       _timeout = timeout;

  final HttpClient _httpClient;
  final Duration _timeout;

  @override
  Future<ProxyAuthOperationsResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) {
    return _sendJson(method: 'POST', url: url, headers: headers, body: body);
  }

  @override
  Future<ProxyAuthOperationsResponse> deleteJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) {
    return _sendJson(method: 'DELETE', url: url, headers: headers, body: body);
  }

  Future<ProxyAuthOperationsResponse> _sendJson({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    final request = method == 'DELETE'
        ? await _httpClient.deleteUrl(url).timeout(_timeout)
        : await _httpClient.postUrl(url).timeout(_timeout);
    request.headers.contentType = ContentType.json;
    headers.forEach(request.headers.set);
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
    final response = await request.close().timeout(_timeout);
    final raw = await utf8
        .decodeStream(response.cast<List<int>>())
        .timeout(_timeout);
    if (raw.isEmpty) {
      return ProxyAuthOperationsResponse(
        statusCode: response.statusCode,
        body: const <String, Object?>{},
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return ProxyAuthOperationsResponse(
        statusCode: response.statusCode,
        body: const <String, Object?>{},
      );
    }
    if (decoded is! Map) {
      return ProxyAuthOperationsResponse(
        statusCode: response.statusCode,
        body: const <String, Object?>{},
      );
    }
    return ProxyAuthOperationsResponse(
      statusCode: response.statusCode,
      body: Map<String, Object?>.from(decoded),
    );
  }
}

class ScaffoldFailingProxyAuthOperationsHttpClient
    implements ProxyAuthOperationsHttpClient {
  const ScaffoldFailingProxyAuthOperationsHttpClient();

  @override
  Future<ProxyAuthOperationsResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    throw StateError(_message);
  }

  @override
  Future<ProxyAuthOperationsResponse> deleteJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    throw StateError(_message);
  }

  static const String _message =
      'Phase 9 auth-operations HTTP transport is not wired; bind '
      'DartIoProxyAuthOperationsHttpClient before exposing Team actions.';
}

class ProxyAuthOperationsError implements Exception {
  const ProxyAuthOperationsError({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'ProxyAuthOperationsError(code: $code, status: $statusCode)';
}

class ProxyAuthOperationsGateway implements AuthOperationsGateway {
  ProxyAuthOperationsGateway({
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

  static const String invitesPath = '/v1/admin/auth/invites';
  static const String usersPrefix = '/v1/admin/auth/users/';
  static const String roleGrantsPath = '/v1/admin/auth/role-grants';

  @override
  Future<TeamInviteCreated> createInvite(
    TeamInviteCreateCommand command,
  ) async {
    final response = await _post(invitesPath, <String, Object?>{
      'email': command.email,
      'role_id': command.roleId,
      'scope_type': command.scopeType,
      if (command.targetLocationId != null)
        'location_id': command.targetLocationId,
    });
    _expectStatus(response, 201);
    final inviteId = _readNonBlankString(response.body['invite_id']);
    final expiresAtRaw = _readNonBlankString(response.body['expires_at']);
    if (inviteId == null || expiresAtRaw == null) {
      throw _malformed(response, 'invite create response was incomplete');
    }
    return TeamInviteCreated(
      inviteId: inviteId,
      expiresAt: DateTime.parse(expiresAtRaw).toUtc(),
    );
  }

  @override
  Future<TeamInviteRevoked> revokeInvite(
    TeamInviteRevokeCommand command,
  ) async {
    final response = await _delete(
      '$invitesPath/${Uri.encodeComponent(command.inviteId)}',
      const <String, Object?>{},
    );
    _expectStatus(response, 200);
    final revoked = response.body['revoked'];
    if (revoked is! bool) {
      throw _malformed(response, 'invite revoke response was incomplete');
    }
    return TeamInviteRevoked(revoked: revoked);
  }

  @override
  Future<TeamUserStatusUpdated> suspendUser(TeamUserStatusCommand command) {
    return _updateUserStatus(command, 'suspend');
  }

  @override
  Future<TeamUserStatusUpdated> reactivateUser(TeamUserStatusCommand command) {
    return _updateUserStatus(command, 'reactivate');
  }

  @override
  Future<TeamUserStatusUpdated> softDeleteUser(TeamUserStatusCommand command) {
    return _updateUserStatus(command, 'soft-delete');
  }

  @override
  Future<TeamPasswordResetQueued> requestPasswordReset(
    TeamPasswordResetCommand command,
  ) async {
    final response = await _post(
      _userActionPath(command.targetUserId, 'reset-password'),
      const <String, Object?>{},
    );
    _expectStatus(response, 200);
    return const TeamPasswordResetQueued();
  }

  @override
  Future<TeamRoleGrantCreated> createRoleGrant(
    TeamRoleGrantCreateCommand command,
  ) async {
    final response = await _post(roleGrantsPath, <String, Object?>{
      'user_id': command.targetUserId,
      'role_id': command.roleId,
      'scope_type': command.scopeType,
      if (command.targetLocationId != null)
        'location_id': command.targetLocationId,
      if (_readNonBlankString(command.reason) != null)
        'reason': command.reason!.trim(),
    });
    _expectStatus(response, 201);
    final userRoleId = _readNonBlankString(response.body['user_role_id']);
    if (userRoleId == null) {
      throw _malformed(response, 'role grant response was incomplete');
    }
    return TeamRoleGrantCreated(userRoleId: userRoleId);
  }

  @override
  Future<TeamRoleGrantRevoked> revokeRoleGrant(
    TeamRoleGrantRevokeCommand command,
  ) async {
    final response = await _delete(
      '$roleGrantsPath/${Uri.encodeComponent(command.userRoleId)}',
      <String, Object?>{
        'user_id': command.targetUserId,
        if (_readNonBlankString(command.reason) != null)
          'reason': command.reason!.trim(),
      },
    );
    _expectStatus(response, 200);
    final revoked = response.body['revoked'];
    if (revoked is! bool) {
      throw _malformed(response, 'role grant revoke response was incomplete');
    }
    return TeamRoleGrantRevoked(revoked: revoked);
  }

  Future<TeamUserStatusUpdated> _updateUserStatus(
    TeamUserStatusCommand command,
    String action,
  ) async {
    final response = await _post(
      _userActionPath(command.targetUserId, action),
      <String, Object?>{'reason': command.reason},
    );
    _expectStatus(response, 200);
    final updated = response.body['updated'];
    if (updated is! bool) {
      throw _malformed(response, 'user status response was incomplete');
    }
    return TeamUserStatusUpdated(updated: updated);
  }

  String _userActionPath(String userId, String action) {
    return '$usersPrefix${Uri.encodeComponent(userId)}/$action';
  }

  Future<ProxyAuthOperationsResponse> _post(
    String relativePath,
    Map<String, Object?> body,
  ) async {
    return _send(
      relativePath: relativePath,
      send: (url, headers) =>
          _httpClient.postJson(url: url, headers: headers, body: body),
    );
  }

  Future<ProxyAuthOperationsResponse> _delete(
    String relativePath,
    Map<String, Object?> body,
  ) async {
    return _send(
      relativePath: relativePath,
      send: (url, headers) =>
          _httpClient.deleteJson(url: url, headers: headers, body: body),
    );
  }

  Future<ProxyAuthOperationsResponse> _send({
    required String relativePath,
    required Future<ProxyAuthOperationsResponse> Function(
      Uri url,
      Map<String, String> headers,
    )
    send,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const ProxyAuthOperationsError(
        code: 'no_id_token',
        message: 'auth operations gateway has no live Firebase ID token',
      );
    }
    final headers = <String, String>{
      HttpHeaders.authorizationHeader: 'Bearer ${token.trim()}',
      'Idempotency-Key': _idempotencyKeyFactory(),
    };
    try {
      return await send(_proxyBaseUri.resolve(relativePath), headers);
    } on ProxyAuthOperationsError {
      rethrow;
    } catch (error) {
      throw ProxyAuthOperationsError(
        code: 'transport_error',
        message:
            'proxy auth operation failed before reaching the proxy '
            '(${_describeTransportError(error)})',
      );
    }
  }

  void _expectStatus(ProxyAuthOperationsResponse response, int expected) {
    if (response.statusCode == expected) return;
    throw ProxyAuthOperationsError(
      code:
          _readNonBlankString(response.body['error']) ??
          'auth_operations_failed',
      message:
          _readNonBlankString(response.body['message']) ??
          'proxy returned status ${response.statusCode}',
      statusCode: response.statusCode,
    );
  }

  ProxyAuthOperationsError _malformed(
    ProxyAuthOperationsResponse response,
    String message,
  ) {
    return ProxyAuthOperationsError(
      code: 'malformed_response',
      message: message,
      statusCode: response.statusCode,
    );
  }

  static String? _readNonBlankString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String _describeTransportError(Object error) {
    if (error is TimeoutException) return 'timeout';
    if (error is SocketException) return 'socket';
    if (error is HttpException) return 'http';
    if (error is HandshakeException) return 'tls';
    if (error is OSError) return 'os';
    return 'transport';
  }

  static final math.Random _idempotencyRandom = math.Random.secure();

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
}
