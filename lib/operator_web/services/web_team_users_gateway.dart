// Phase 11W.1 - Operator Web team-users gateway (live).
//
// Re-implementation of the team-users + team-invites surface of
// `AuthOperationsGateway` against `package:http`, so the operator-web
// build can call the existing Phase 9 + 11A.1 proxy routes without
// dragging in `dart:io`.
//
// The mobile / Phase 11A admin gateway lives at
// `lib/services/auth/proxy_auth_operations_gateway.dart` and uses
// `dart:io` `HttpClient`. Per the Team / Roles / Hierarchy / Sessions
// / Audit / Security console parity contract, this slice MUST NOT
// extend that gateway - it must re-implement the abstract interface
// for the web target so the operator-web shell stays free of
// `dart:io`.
//
// Routes (already shipped by Phase 9 + 11A.1, no new backend
// surface added by 11W.1):
//
//   * GET    /v1/admin/auth/users
//   * GET    /v1/admin/auth/invites
//   * POST   /v1/admin/auth/invites
//   * DELETE /v1/admin/auth/invites/{invite_id}
//   * POST   /v1/admin/auth/users/{user_id}/suspend
//   * POST   /v1/admin/auth/users/{user_id}/reactivate
//   * POST   /v1/admin/auth/users/{user_id}/soft-delete
//   * POST   /v1/admin/auth/users/{user_id}/reset-password
//   * POST   /v1/admin/auth/users/{user_id}/reset-mfa
//
// Idempotency posture: every write carries an `Idempotency-Key`
// header; the screen layer mints one key per user action and threads
// it through the dialog → gateway path, matching the parity contract
// § Idempotency keys rule. The gateway does NOT mint keys internally
// (doing so would double-mint and break replay).

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../services/auth/auth_operations_gateway.dart';

/// Narrow interface the Members screen + invite dialog read against.
/// Mirrors the team-users + team-invites slice of the existing
/// `AuthOperationsGateway` interface so future 11W slices that need
/// adjacent surfaces (roles, hierarchy, sessions, audit, security)
/// can ship their own gateway under the same naming pattern.
abstract class WebTeamUsersGateway {
  Future<TeamUsersListed> listUsers(TeamUserListCommand command);

  Future<TeamInvitesListed> listInvites(TeamInviteListCommand command);

  Future<TeamInviteCreated> createInvite(
    TeamInviteCreateCommand command, {
    required String idempotencyKey,
  });

  Future<TeamInviteRevoked> revokeInvite(
    TeamInviteRevokeCommand command, {
    required String idempotencyKey,
  });

  Future<TeamUserStatusUpdated> suspendUser(
    TeamUserStatusCommand command, {
    required String idempotencyKey,
  });

  Future<TeamUserStatusUpdated> reactivateUser(
    TeamUserStatusCommand command, {
    required String idempotencyKey,
  });

  Future<TeamUserStatusUpdated> softDeleteUser(
    TeamUserStatusCommand command, {
    required String idempotencyKey,
  });

  Future<TeamPasswordResetQueued> requestPasswordReset(
    TeamPasswordResetCommand command, {
    required String idempotencyKey,
  });

  Future<TeamMfaResetQueued> requestMfaReset(
    TeamMfaResetCommand command, {
    required String idempotencyKey,
  });
}

/// Live wire shape returned by the proxy. Mirrors the response
/// envelope `proxy_auth_operations_gateway.dart` already consumes.
class WebTeamUsersResponse {
  const WebTeamUsersResponse({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, Object?> body;
}

/// Thrown when the proxy returns a non-2xx for a team-users / invites
/// call, or when the response body cannot be parsed.
class WebTeamUsersError implements Exception {
  const WebTeamUsersError({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'WebTeamUsersError(code: $code, status: $statusCode, message: $message)';
}

/// Path constants used by both the gateway and its tests. Public so
/// the HTTP wire test can pin the exact routes the gateway calls.
class WebTeamUsersPaths {
  const WebTeamUsersPaths._();

  static const String invites = '/v1/admin/auth/invites';
  static const String invitePrefix = '/v1/admin/auth/invites/';
  static const String users = '/v1/admin/auth/users';
  static const String userPrefix = '/v1/admin/auth/users/';

  static String userAction(String userId, String action) =>
      '$userPrefix${Uri.encodeComponent(userId)}/$action';

  static String invite(String inviteId) =>
      '$invitePrefix${Uri.encodeComponent(inviteId)}';
}

/// Live `package:http` implementation. Reads the Firebase ID token
/// from the supplied provider on every call so refreshed tokens land
/// on the next request.
class WebTeamUsersGatewayLive implements WebTeamUsersGateway {
  WebTeamUsersGatewayLive({
    required this.proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
  })  : _idTokenProvider = idTokenProvider,
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout;

  final Uri proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  @override
  Future<TeamUsersListed> listUsers(TeamUserListCommand command) async {
    final response = await _send(
      method: 'GET',
      path: WebTeamUsersPaths.users,
    );
    _expectStatus(response, 200);
    final rawUsers = response.body['users'];
    if (rawUsers is! List) {
      throw _malformed(response, 'team users response was incomplete');
    }
    return TeamUsersListed(
      users: List<TeamUserListEntry>.unmodifiable(
        rawUsers.map((raw) => _userFromJson(response, raw)),
      ),
    );
  }

  @override
  Future<TeamInvitesListed> listInvites(TeamInviteListCommand command) async {
    final response = await _send(
      method: 'GET',
      path: WebTeamUsersPaths.invites,
    );
    _expectStatus(response, 200);
    final rawInvites = response.body['invites'];
    if (rawInvites is! List) {
      throw _malformed(response, 'team invites response was incomplete');
    }
    return TeamInvitesListed(
      invites: List<TeamInviteListEntry>.unmodifiable(
        rawInvites.map((raw) => _inviteFromJson(response, raw)),
      ),
    );
  }

  @override
  Future<TeamInviteCreated> createInvite(
    TeamInviteCreateCommand command, {
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'POST',
      path: WebTeamUsersPaths.invites,
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{
        'email': command.email,
        'role_id': command.roleId,
        'scope_type': command.scopeType,
        if (command.targetLocationId != null)
          'location_id': command.targetLocationId,
        if (command.targetOrgUnitId != null)
          'org_unit_id': command.targetOrgUnitId,
      },
    );
    _expectStatus(response, 201);
    final inviteId = _readNonBlankString(response.body['invite_id']);
    final expiresAtRaw = _readNonBlankString(response.body['expires_at']);
    if (inviteId == null || expiresAtRaw == null) {
      throw _malformed(response, 'invite create response was incomplete');
    }
    return TeamInviteCreated(
      inviteId: inviteId,
      expiresAt: DateTime.parse(expiresAtRaw).toUtc(),
      userId: _readNonBlankString(response.body['user_id']),
    );
  }

  @override
  Future<TeamInviteRevoked> revokeInvite(
    TeamInviteRevokeCommand command, {
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'DELETE',
      path: WebTeamUsersPaths.invite(command.inviteId),
      idempotencyKey: idempotencyKey,
      body: const <String, Object?>{},
    );
    _expectStatus(response, 200);
    final revoked = response.body['revoked'];
    if (revoked is! bool) {
      throw _malformed(response, 'invite revoke response was incomplete');
    }
    return TeamInviteRevoked(revoked: revoked);
  }

  @override
  Future<TeamUserStatusUpdated> suspendUser(
    TeamUserStatusCommand command, {
    required String idempotencyKey,
  }) {
    return _userStatusAction(command, 'suspend', idempotencyKey);
  }

  @override
  Future<TeamUserStatusUpdated> reactivateUser(
    TeamUserStatusCommand command, {
    required String idempotencyKey,
  }) {
    return _userStatusAction(command, 'reactivate', idempotencyKey);
  }

  @override
  Future<TeamUserStatusUpdated> softDeleteUser(
    TeamUserStatusCommand command, {
    required String idempotencyKey,
  }) {
    return _userStatusAction(command, 'soft-delete', idempotencyKey);
  }

  @override
  Future<TeamPasswordResetQueued> requestPasswordReset(
    TeamPasswordResetCommand command, {
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'POST',
      path: WebTeamUsersPaths.userAction(command.targetUserId, 'reset-password'),
      idempotencyKey: idempotencyKey,
      body: const <String, Object?>{},
    );
    _expectStatus(response, 200);
    return const TeamPasswordResetQueued();
  }

  @override
  Future<TeamMfaResetQueued> requestMfaReset(
    TeamMfaResetCommand command, {
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'POST',
      path: WebTeamUsersPaths.userAction(command.targetUserId, 'reset-mfa'),
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{
        if (_readNonBlankString(command.stepUpProofId) != null)
          'step_up_proof_id': command.stepUpProofId.trim(),
      },
    );
    _expectStatus(response, 200);
    final requestedCount = response.body['requested_count'];
    final rawRequestIds = response.body['request_ids'];
    if (requestedCount is! int || rawRequestIds is! List) {
      throw _malformed(response, 'MFA reset response was incomplete');
    }
    final executeAfterRaw = _readNonBlankString(response.body['execute_after']);
    return TeamMfaResetQueued(
      requestedCount: requestedCount,
      requestIds: List<String>.unmodifiable(rawRequestIds.whereType<String>()),
      executeAfter: executeAfterRaw == null
          ? null
          : DateTime.parse(executeAfterRaw).toUtc(),
    );
  }

  Future<TeamUserStatusUpdated> _userStatusAction(
    TeamUserStatusCommand command,
    String action,
    String idempotencyKey,
  ) async {
    final response = await _send(
      method: 'POST',
      path: WebTeamUsersPaths.userAction(command.targetUserId, action),
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{'reason': command.reason},
    );
    _expectStatus(response, 200);
    final updated = response.body['updated'];
    if (updated is! bool) {
      throw _malformed(response, 'user status response was incomplete');
    }
    return TeamUserStatusUpdated(updated: updated);
  }

  Future<WebTeamUsersResponse> _send({
    required String method,
    required String path,
    String? idempotencyKey,
    Map<String, Object?>? body,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const WebTeamUsersError(
        code: 'no_id_token',
        message:
            'team-users gateway has no live Firebase ID token to attach to '
            'the request.',
      );
    }
    final headers = <String, String>{
      'accept': 'application/json',
      'authorization': 'Bearer ${token.trim()}',
      if (body != null) 'content-type': 'application/json',
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
    };
    final url = proxyBaseUri.resolve(path);
    final request = http.Request(method, url);
    request.headers.addAll(headers);
    if (body != null) request.body = jsonEncode(body);
    final http.StreamedResponse streamed;
    try {
      streamed = await _httpClient.send(request).timeout(_timeout);
    } on TimeoutException {
      throw const WebTeamUsersError(
        code: 'transport_timeout',
        message: 'team-users gateway request timed out before reaching the '
            'proxy.',
      );
    } catch (error) {
      throw WebTeamUsersError(
        code: 'transport_error',
        message:
            'team-users gateway request failed before reaching the proxy '
            '($error).',
      );
    }
    final raw = await streamed.stream.bytesToString().timeout(_timeout);
    Object? decoded;
    if (raw.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        decoded = const <String, Object?>{};
      }
    }
    final responseBody = decoded is Map<Object?, Object?>
        ? Map<String, Object?>.from(decoded)
        : const <String, Object?>{};
    return WebTeamUsersResponse(
      statusCode: streamed.statusCode,
      body: responseBody,
    );
  }

  void _expectStatus(WebTeamUsersResponse response, int expected) {
    if (response.statusCode == expected) return;
    throw WebTeamUsersError(
      code:
          _readNonBlankString(response.body['error']) ?? 'team_users_failed',
      message: _readNonBlankString(response.body['message']) ??
          'proxy returned status ${response.statusCode}',
      statusCode: response.statusCode,
    );
  }

  WebTeamUsersError _malformed(WebTeamUsersResponse response, String message) {
    return WebTeamUsersError(
      code: 'malformed_response',
      message: message,
      statusCode: response.statusCode,
    );
  }

  TeamUserListEntry _userFromJson(WebTeamUsersResponse response, Object? raw) {
    if (raw is! Map) {
      throw _malformed(response, 'team user payload was malformed');
    }
    final json = Map<String, Object?>.from(raw);
    final userId = _readNonBlankString(json['user_id']);
    final email = _readNonBlankString(json['email']);
    final displayName = _readNonBlankString(json['display_name']);
    final roleId = _readNonBlankString(json['role_id']);
    final roleLabel = _readNonBlankString(json['role_label']);
    final status = _readNonBlankString(json['status']);
    final mfaEnrolled = json['mfa_enrolled'];
    if (userId == null ||
        email == null ||
        displayName == null ||
        roleId == null ||
        roleLabel == null ||
        status == null ||
        mfaEnrolled is! bool) {
      throw _malformed(response, 'team user payload was incomplete');
    }
    final lastActiveAtRaw = _readNonBlankString(json['last_active_at']);
    return TeamUserListEntry(
      userId: userId,
      email: email,
      displayName: displayName,
      roleId: roleId,
      roleLabel: roleLabel,
      status: status,
      locationId: _readNonBlankString(json['location_id']),
      locationLabel: _readNonBlankString(json['location_label']),
      mfaEnrolled: mfaEnrolled,
      mfaRemovalPending:
          json['mfa_removal_pending'] is bool ? json['mfa_removal_pending'] as bool : false,
      mfaRemovalRequestId:
          _readNonBlankString(json['mfa_removal_request_id']),
      userRoleId: _readNonBlankString(json['user_role_id']),
      lastActiveAt:
          lastActiveAtRaw == null ? null : DateTime.parse(lastActiveAtRaw).toUtc(),
    );
  }

  TeamInviteListEntry _inviteFromJson(
    WebTeamUsersResponse response,
    Object? raw,
  ) {
    if (raw is! Map) {
      throw _malformed(response, 'team invite payload was malformed');
    }
    final json = Map<String, Object?>.from(raw);
    final inviteId = _readNonBlankString(json['invite_id']);
    final email = _readNonBlankString(json['email']);
    final roleId = _readNonBlankString(json['role_id']);
    final roleLabel = _readNonBlankString(json['role_label']);
    final scopeType = _readNonBlankString(json['scope_type']);
    final expiresAtRaw = _readNonBlankString(json['expires_at']);
    final createdAtRaw = _readNonBlankString(json['created_at']);
    if (inviteId == null ||
        email == null ||
        roleId == null ||
        roleLabel == null ||
        scopeType == null ||
        expiresAtRaw == null ||
        createdAtRaw == null) {
      throw _malformed(response, 'team invite payload was incomplete');
    }
    return TeamInviteListEntry(
      inviteId: inviteId,
      email: email,
      roleId: roleId,
      roleLabel: roleLabel,
      scopeType: scopeType,
      locationId: _readNonBlankString(json['location_id']),
      locationLabel: _readNonBlankString(json['location_label']),
      orgUnitId: _readNonBlankString(json['org_unit_id']),
      orgUnitLabel: _readNonBlankString(json['org_unit_label']),
      expiresAt: DateTime.parse(expiresAtRaw).toUtc(),
      createdAt: DateTime.parse(createdAtRaw).toUtc(),
    );
  }

  static String? _readNonBlankString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
