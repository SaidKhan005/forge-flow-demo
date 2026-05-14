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
//   * GET    /v1/auth/team/users
//   * GET    /v1/auth/team/invites
//   * POST   /v1/auth/team/invites
//   * DELETE /v1/auth/team/invites/{invite_id}
//   * POST   /v1/auth/team/users/{user_id}/suspend
//   * POST   /v1/auth/team/users/{user_id}/reactivate
//   * POST   /v1/auth/team/users/{user_id}/soft-delete
//   * POST   /v1/auth/team/users/{user_id}/reset-password
//   * POST   /v1/auth/team/users/{user_id}/reset-mfa
//   * PATCH  /v1/auth/team/users/{user_id}    (Wave 2 W-1 — email +
//                                              display name patch)
//   * POST   /v1/auth/team/role-grants         (Wave 2 W-1-FU — role +
//                                              hierarchy scope rotation
//                                              from the Edit member
//                                              dialog)
//   * DELETE /v1/auth/team/role-grants/{user_role_id}  (Wave 2 W-1-FU)
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

  /// Wave 2 W-1 — Members edit-user write path. PATCHes one user's
  /// display name and/or email through the proxy `PATCH
  /// /v1/auth/team/users/{user_id}` route. The proxy orchestrates the
  /// Firebase Identity Platform update + Postgres mirror update +
  /// audit row.
  ///
  /// At least one of [TeamUserProfilePatchCommand.displayName] or
  /// [TeamUserProfilePatchCommand.email] must be non-null; the proxy
  /// rejects the all-null shape with 400.
  Future<TeamUserProfilePatched> editMember(
    TeamUserProfilePatchCommand command, {
    required String idempotencyKey,
  });

  /// Wave 2 W-1-FU — role + hierarchy scope rotation from the Edit
  /// member dialog. POSTs through the proxy `POST
  /// /v1/auth/team/role-grants` route, which delegates to the existing
  /// `createRoleGrant` orchestration in
  /// [RepositoryAuthOperationsGateway] (writes the new `user_roles` row,
  /// refreshes Firebase custom claims, and emits the
  /// `auth.role_grant_created` audit row).
  ///
  /// The proxy gates this call on `team.roles.assign`.
  Future<TeamRoleGrantCreated> createRoleGrant(
    TeamRoleGrantCreateCommand command, {
    required String idempotencyKey,
  });

  /// Wave 2 W-1-FU — companion revoke for role + hierarchy scope
  /// rotation. DELETEs through the proxy `DELETE
  /// /v1/auth/team/role-grants/{user_role_id}` route, which delegates
  /// to the existing `revokeRoleGrant` orchestration (marks the old
  /// `user_roles` row revoked, refreshes Firebase custom claims, and
  /// emits the `auth.role_grant_revoked` audit row).
  ///
  /// The proxy gates this call on `team.roles.revoke`.
  Future<TeamRoleGrantRevoked> revokeRoleGrant(
    TeamRoleGrantRevokeCommand command, {
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

  static const String invites = '/v1/auth/team/invites';
  static const String invitePrefix = '/v1/auth/team/invites/';
  static const String users = '/v1/auth/team/users';
  static const String userPrefix = '/v1/auth/team/users/';

  /// Wave 2 W-1-FU — role-grant create/revoke routes used by the Edit
  /// member dialog when the operator changes role or hierarchy scope.
  /// The proxy canonicalizes `/v1/auth/team/role-grants` to
  /// `/v1/admin/auth/role-grants` (see `_canonicalAuthOperationPath` in
  /// `tool/advisor_proxy/advisor_proxy.dart`).
  static const String roleGrants = '/v1/auth/team/role-grants';
  static const String roleGrantPrefix = '/v1/auth/team/role-grants/';

  static String userAction(String userId, String action) =>
      '$userPrefix${Uri.encodeComponent(userId)}/$action';

  static String invite(String inviteId) =>
      '$invitePrefix${Uri.encodeComponent(inviteId)}';

  static String roleGrant(String userRoleId) =>
      '$roleGrantPrefix${Uri.encodeComponent(userRoleId)}';
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
  }) : _idTokenProvider = idTokenProvider,
       _httpClient = httpClient ?? http.Client(),
       _timeout = timeout;

  final Uri proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  @override
  Future<TeamUsersListed> listUsers(TeamUserListCommand command) async {
    final response = await _send(method: 'GET', path: WebTeamUsersPaths.users);
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
      path: WebTeamUsersPaths.userAction(
        command.targetUserId,
        'reset-password',
      ),
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

  @override
  Future<TeamUserProfilePatched> editMember(
    TeamUserProfilePatchCommand command, {
    required String idempotencyKey,
  }) async {
    // W-1 — Members edit-user write path. PATCH /v1/auth/team/users/{id}.
    // Both `display_name` and `email` are optional; at least one must
    // be present so the proxy can fan out to Firebase + Postgres +
    // audit. The proxy rejects the all-null shape with 400.
    final response = await _send(
      method: 'PATCH',
      path: '${WebTeamUsersPaths.userPrefix}${Uri.encodeComponent(command.targetUserId)}',
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{
        if (command.displayName != null) 'display_name': command.displayName,
        if (command.email != null) 'email': command.email,
        'admin_reason': command.reason,
      },
    );
    _expectStatus(response, 200);
    final rawUser = response.body['user'];
    if (rawUser is! Map) {
      throw _malformed(response, 'edit member response was incomplete');
    }
    return TeamUserProfilePatched(user: _userFromJson(response, rawUser));
  }

  @override
  Future<TeamRoleGrantCreated> createRoleGrant(
    TeamRoleGrantCreateCommand command, {
    required String idempotencyKey,
  }) async {
    // W-1-FU — role + hierarchy scope rotation. POST
    // /v1/auth/team/role-grants. The proxy canonicalizes to
    // `/v1/admin/auth/role-grants`, gates on `team.roles.assign`, and
    // delegates to `createRoleGrant` on the repository gateway.
    final response = await _send(
      method: 'POST',
      path: WebTeamUsersPaths.roleGrants,
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{
        'user_id': command.targetUserId,
        'role_id': command.roleId,
        'scope_type': command.scopeType,
        if (command.targetLocationId != null)
          'location_id': command.targetLocationId,
        if (command.targetOrgUnitId != null)
          'org_unit_id': command.targetOrgUnitId,
        if (command.reason != null && command.reason!.trim().isNotEmpty)
          'reason': command.reason!.trim(),
      },
    );
    _expectStatus(response, 201);
    final userRoleId = _readNonBlankString(response.body['user_role_id']);
    if (userRoleId == null) {
      throw _malformed(response, 'role grant create response was incomplete');
    }
    return TeamRoleGrantCreated(userRoleId: userRoleId);
  }

  @override
  Future<TeamRoleGrantRevoked> revokeRoleGrant(
    TeamRoleGrantRevokeCommand command, {
    required String idempotencyKey,
  }) async {
    // W-1-FU — companion revoke. DELETE
    // /v1/auth/team/role-grants/{user_role_id}. The proxy canonicalizes
    // to `/v1/admin/auth/role-grants/{id}`, gates on
    // `team.roles.revoke`, and delegates to `revokeRoleGrant` on the
    // repository gateway. `user_id` travels in the request body so the
    // proxy can pair the grant with its owning user when refreshing
    // Firebase claims.
    final response = await _send(
      method: 'DELETE',
      path: WebTeamUsersPaths.roleGrant(command.userRoleId),
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{
        'user_id': command.targetUserId,
        if (command.reason != null && command.reason!.trim().isNotEmpty)
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
        message:
            'team-users gateway request timed out before reaching the '
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
      code: _readNonBlankString(response.body['error']) ?? 'team_users_failed',
      message:
          _readNonBlankString(response.body['message']) ??
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
      mfaRemovalPending: json['mfa_removal_pending'] is bool
          ? json['mfa_removal_pending'] as bool
          : false,
      mfaRemovalRequestId: _readNonBlankString(json['mfa_removal_request_id']),
      userRoleId: _readNonBlankString(json['user_role_id']),
      lastActiveAt: lastActiveAtRaw == null
          ? null
          : DateTime.parse(lastActiveAtRaw).toUtc(),
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
