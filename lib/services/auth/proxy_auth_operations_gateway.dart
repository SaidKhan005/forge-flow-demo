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
  Future<ProxyAuthOperationsResponse> getJson({
    required Uri url,
    required Map<String, String> headers,
  });

  Future<ProxyAuthOperationsResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  });

  Future<ProxyAuthOperationsResponse> patchJson({
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
    Duration timeout = const Duration(seconds: 30),
  }) : _httpClient = httpClient ?? HttpClient(),
       _timeout = timeout;

  final HttpClient _httpClient;
  final Duration _timeout;

  @override
  Future<ProxyAuthOperationsResponse> getJson({
    required Uri url,
    required Map<String, String> headers,
  }) {
    return _sendJson(method: 'GET', url: url, headers: headers);
  }

  @override
  Future<ProxyAuthOperationsResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) {
    return _sendJson(method: 'POST', url: url, headers: headers, body: body);
  }

  @override
  Future<ProxyAuthOperationsResponse> patchJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) {
    return _sendJson(method: 'PATCH', url: url, headers: headers, body: body);
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
    Map<String, Object?>? body,
  }) async {
    final request = switch (method) {
      'DELETE' => await _httpClient.deleteUrl(url).timeout(_timeout),
      'GET' => await _httpClient.getUrl(url).timeout(_timeout),
      'PATCH' => await _httpClient.patchUrl(url).timeout(_timeout),
      _ => await _httpClient.postUrl(url).timeout(_timeout),
    };
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      final encoded = utf8.encode(jsonEncode(body));
      request.contentLength = encoded.length;
      request.add(encoded);
    }
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
  Future<ProxyAuthOperationsResponse> getJson({
    required Uri url,
    required Map<String, String> headers,
  }) async {
    throw StateError(_message);
  }

  @override
  Future<ProxyAuthOperationsResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    throw StateError(_message);
  }

  @override
  Future<ProxyAuthOperationsResponse> patchJson({
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
      'ProxyAuthOperationsError(code: $code, status: $statusCode, '
      'message: $message)';
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
  static const String usersPath = '/v1/admin/auth/users';
  static const String usersPrefix = '/v1/admin/auth/users/';
  static const String rolesPath = '/v1/admin/auth/roles';
  static const String roleGrantsPath = '/v1/admin/auth/role-grants';
  // Phase 9.UX.4 — org hierarchy admin client paths.
  static const String orgUnitsPath = '/v1/admin/auth/org-units';
  static const String locationsPrefix = '/v1/admin/auth/locations/';
  // Phase 9.UX.5 — self-service Active Sessions client paths. The
  // GET reads through the new `/v1/auth/sessions` projection; revoke
  // calls reuse the existing single / all session-revoke routes from
  // the B6 ledger surface so notifier state and refresh-token revoke
  // semantics stay aligned.
  static const String authSessionsPath = '/v1/auth/sessions';
  static const String authSessionRevokePath = '/v1/auth/session/revoke';
  static const String authSessionRevokeAllPath = '/v1/auth/session/revoke-all';

  // Phase 9.UX.6 — self-service Audit Log read projection. The proxy
  // pins user_id to the verified bearer token; client-supplied user
  // ids are ignored. Filtering and pagination travel as query params.
  static const String authAuditLogPath = '/v1/auth/audit-log';

  @override
  Future<TeamUsersListed> listUsers(TeamUserListCommand command) async {
    final response = await _get(usersPath);
    _expectStatus(response, 200);
    final rawUsers = response.body['users'];
    if (rawUsers is! List) {
      throw _malformed(response, 'team users response was incomplete');
    }
    return TeamUsersListed(
      users: List<TeamUserListEntry>.unmodifiable(
        rawUsers.map((raw) => _teamUserFromJson(response, raw)),
      ),
    );
  }

  @override
  Future<TeamRoleCatalogListed> listRoles(
    TeamRoleCatalogListCommand command,
  ) async {
    final path = _rolesListPath(command.scope);
    final response = await _get(path);
    _expectStatus(response, 200);
    final rawRoles = response.body['roles'];
    if (rawRoles is! List) {
      throw _malformed(response, 'role list response was incomplete');
    }
    return TeamRoleCatalogListed(
      roles: List<TeamRoleCatalogEntry>.unmodifiable(
        rawRoles.map((raw) => _roleFromJson(response, raw)),
      ),
    );
  }

  @override
  Future<TeamRoleCreated> createRole(TeamRoleCreateCommand command) async {
    final response = await _post(rolesPath, <String, Object?>{
      'role_key': command.roleKey,
      'display_name': command.displayName,
      if (command.description.trim().isNotEmpty)
        'description': command.description.trim(),
      if (command.permissions.isNotEmpty)
        'permissions': command.permissions.map(_permissionUpdateJson).toList(),
      if (_readNonBlankString(command.reason) != null)
        'reason': command.reason!.trim(),
    });
    _expectStatus(response, 201);
    return TeamRoleCreated(
      role: _roleFromJson(response, response.body['role']),
    );
  }

  @override
  Future<TeamRolePatched> patchRole(TeamRolePatchCommand command) async {
    final response = await _patch(
      '$rolesPath/${Uri.encodeComponent(command.roleId)}',
      <String, Object?>{
        if (_readNonBlankString(command.displayName) != null)
          'display_name': command.displayName!.trim(),
        if (command.description != null)
          'description': command.description!.trim(),
        if (command.permissions.isNotEmpty)
          'permissions': command.permissions
              .map(_permissionUpdateJson)
              .toList(),
        if (_readNonBlankString(command.reason) != null)
          'reason': command.reason!.trim(),
      },
    );
    _expectStatus(response, 200);
    final bumpedUsers = response.body['bumped_users'];
    if (bumpedUsers is! int) {
      throw _malformed(response, 'role patch response was incomplete');
    }
    return TeamRolePatched(
      role: _roleFromJson(response, response.body['role']),
      bumpedUsers: bumpedUsers,
    );
  }

  @override
  Future<TeamRoleDeleted> deleteRole(TeamRoleDeleteCommand command) async {
    final response = await _delete(
      '$rolesPath/${Uri.encodeComponent(command.roleId)}',
      <String, Object?>{
        if (_readNonBlankString(command.reason) != null)
          'reason': command.reason!.trim(),
      },
    );
    _expectStatus(response, 200);
    final deleted = response.body['deleted'];
    if (deleted is! bool) {
      throw _malformed(response, 'role delete response was incomplete');
    }
    return TeamRoleDeleted(deleted: deleted);
  }

  @override
  Future<TeamInvitesListed> listInvites(TeamInviteListCommand command) async {
    final response = await _get(invitesPath);
    _expectStatus(response, 200);
    final rawInvites = response.body['invites'];
    if (rawInvites is! List) {
      throw _malformed(response, 'team invites response was incomplete');
    }
    return TeamInvitesListed(
      invites: List<TeamInviteListEntry>.unmodifiable(
        rawInvites.map((raw) => _teamInviteFromJson(response, raw)),
      ),
    );
  }

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
      if (command.targetOrgUnitId != null)
        'org_unit_id': command.targetOrgUnitId,
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
      userId: _readNonBlankString(response.body['user_id']),
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
  Future<TeamMfaResetQueued> requestMfaReset(
    TeamMfaResetCommand command,
  ) async {
    final response = await _post(
      _userActionPath(command.targetUserId, 'reset-mfa'),
      <String, Object?>{
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
    return TeamMfaResetQueued(
      requestedCount: requestedCount,
      requestIds: List<String>.unmodifiable(rawRequestIds.whereType<String>()),
      executeAfter: _readDateTime(response.body['execute_after']),
    );
  }

  @override
  Future<TeamMfaRemovalCancelled> cancelMfaRemoval(
    TeamMfaRemovalCancelCommand command,
  ) async {
    final response = await _post(
      _userActionPath(command.targetUserId, 'cancel-mfa-removal'),
      <String, Object?>{'request_id': command.requestId},
    );
    _expectStatus(response, 200);
    final cancelled = response.body['cancelled'];
    if (cancelled is! bool) {
      throw _malformed(response, 'MFA removal cancel response was incomplete');
    }
    return TeamMfaRemovalCancelled(cancelled: cancelled);
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
      if (command.targetOrgUnitId != null)
        'org_unit_id': command.targetOrgUnitId,
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

  @override
  Future<TeamOrgHierarchyListed> listOrgHierarchy(
    TeamOrgHierarchyListCommand command,
  ) async {
    final response = await _get(orgUnitsPath);
    _expectStatus(response, 200);
    final rawOrgUnits = response.body['org_units'];
    final rawLocations = response.body['locations'];
    if (rawOrgUnits is! List || rawLocations is! List) {
      throw _malformed(response, 'org hierarchy response was incomplete');
    }
    return TeamOrgHierarchyListed(
      orgUnits: List<TeamOrgUnitEntry>.unmodifiable(
        rawOrgUnits.map((raw) => _orgUnitFromJson(response, raw)),
      ),
      locations: List<TeamOrgLocationEntry>.unmodifiable(
        rawLocations.map((raw) => _orgLocationFromJson(response, raw)),
      ),
    );
  }

  @override
  Future<TeamOrgUnitCreated> createOrgUnit(
    TeamOrgUnitCreateCommand command,
  ) async {
    final response = await _post(orgUnitsPath, <String, Object?>{
      'parent_org_unit_id': command.parentOrgUnitId,
      'unit_type': command.unitType,
      'label': command.label,
      'name': command.name,
    });
    _expectStatus(response, 201);
    final orgUnitId = _readNonBlankString(response.body['org_unit_id']);
    if (orgUnitId == null) {
      throw _malformed(response, 'org unit create response was incomplete');
    }
    return TeamOrgUnitCreated(orgUnitId: orgUnitId);
  }

  @override
  Future<TeamLocationOrgUnitMoved> moveLocationToOrgUnit(
    TeamLocationOrgUnitMoveCommand command,
  ) async {
    final response = await _patch(
      '$locationsPrefix${Uri.encodeComponent(command.targetLocationId)}'
      '/org-unit',
      <String, Object?>{'parent_org_unit_id': command.parentOrgUnitId},
    );
    _expectStatus(response, 200);
    final moved = response.body['moved'];
    if (moved is! bool) {
      throw _malformed(response, 'org unit move response was incomplete');
    }
    return TeamLocationOrgUnitMoved(moved: moved);
  }

  @override
  Future<AuthActiveSessionsListed> listActiveSessions(
    AuthActiveSessionsListCommand command,
  ) async {
    final response = await _get(authSessionsPath);
    _expectStatus(response, 200);
    final rawSessions = response.body['sessions'];
    if (rawSessions is! List) {
      throw _malformed(response, 'active sessions response was incomplete');
    }
    return AuthActiveSessionsListed(
      sessions: List<AuthSessionSummary>.unmodifiable(
        rawSessions.map((raw) => _authSessionFromJson(response, raw)),
      ),
    );
  }

  @override
  Future<AuthSessionRevoked> revokeSession(
    AuthSessionRevokeCommand command,
  ) async {
    final response = await _post(authSessionRevokePath, <String, Object?>{
      'session_id': command.sessionId,
      if (_readNonBlankString(command.reason) != null)
        'reason': command.reason!.trim(),
    });
    _expectStatus(response, 200);
    final ok = response.body['ok'];
    final revoked = response.body['revoked'];
    final result = revoked is bool
        ? revoked
        : ok is bool
        ? ok
        : false;
    return AuthSessionRevoked(revoked: result);
  }

  @override
  Future<AuthAllSessionsRevoked> signOutAll(
    AuthAllSessionsRevokeCommand command,
  ) async {
    final response = await _post(authSessionRevokeAllPath, <String, Object?>{
      if (_readNonBlankString(command.reason) != null)
        'reason': command.reason!.trim(),
    });
    _expectStatus(response, 200);
    final raw = response.body['revoked_count'];
    final count = raw is int ? raw : 0;
    return AuthAllSessionsRevoked(revokedCount: count);
  }

  @override
  Future<AuthEventsListed> listAuthEventsForActor(
    AuthEventListCommand command,
  ) async {
    final query = <String, String>{
      'limit': command.limit.toString(),
      'offset': command.offset.toString(),
      if (command.eventKind != null)
        'event_kind': AuthEventLabels.wireKey(command.eventKind!),
      if (command.from != null)
        'from': command.from!.toUtc().toIso8601String(),
      if (command.to != null)
        'to': command.to!.toUtc().toIso8601String(),
    };
    final response = await _get(_appendQuery(authAuditLogPath, query));
    _expectStatus(response, 200);
    final rawEntries = response.body['entries'];
    if (rawEntries is! List) {
      throw _malformed(response, 'audit log response was incomplete');
    }
    final hasMore = response.body['has_more'];
    return AuthEventsListed(
      entries: List<AuthEventListEntry>.unmodifiable(
        rawEntries.map((raw) => _authEventFromJson(response, raw)),
      ),
      hasMore: hasMore is bool ? hasMore : false,
    );
  }

  AuthEventListEntry _authEventFromJson(
    ProxyAuthOperationsResponse response,
    Object? raw,
  ) {
    if (raw is! Map) {
      throw _malformed(response, 'audit log entry payload was malformed');
    }
    final json = Map<String, Object?>.from(raw);
    final eventId = _readNonBlankString(json['event_id']);
    final eventType = _readNonBlankString(json['event_type']);
    final occurredAt = _readDateTime(json['occurred_at']);
    if (eventId == null || eventType == null || occurredAt == null) {
      throw _malformed(response, 'audit log entry payload was incomplete');
    }
    final friendlyLabel =
        _readNonBlankString(json['friendly_label']) ??
        AuthEventLabels.labelFor(eventType);
    final kindWire = _readNonBlankString(json['event_kind']);
    final kind =
        AuthEventLabels.fromWireKey(kindWire) ??
        AuthEventLabels.kindFor(eventType);
    final payload = json['payload'];
    return AuthEventListEntry(
      eventId: eventId,
      eventKind: kind,
      eventType: eventType,
      friendlyLabel: friendlyLabel,
      occurredAt: occurredAt,
      subType: _readNonBlankString(json['sub_type']),
      ip: _readNonBlankString(json['ip']),
      userAgent: _readNonBlankString(json['user_agent']),
      geoCountry: _readNonBlankString(json['geo_country']),
      scope: _readNonBlankString(json['scope']),
      payload: payload is Map
          ? Map<String, Object?>.unmodifiable(
              Map<String, Object?>.from(payload),
            )
          : const <String, Object?>{},
    );
  }

  static String _appendQuery(String path, Map<String, String> params) {
    if (params.isEmpty) return path;
    final encoded = params.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}='
              '${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    return path.contains('?') ? '$path&$encoded' : '$path?$encoded';
  }

  AuthSessionSummary _authSessionFromJson(
    ProxyAuthOperationsResponse response,
    Object? raw,
  ) {
    if (raw is! Map) {
      throw _malformed(response, 'auth session payload was malformed');
    }
    final json = Map<String, Object?>.from(raw);
    final sessionId = _readNonBlankString(json['session_id']);
    final createdAt = _readDateTime(json['created_at']);
    final lastSeenAt = _readDateTime(json['last_seen_at']);
    if (sessionId == null || createdAt == null || lastSeenAt == null) {
      throw _malformed(response, 'auth session payload was incomplete');
    }
    return AuthSessionSummary(
      sessionId: sessionId,
      createdAt: createdAt,
      lastSeenAt: lastSeenAt,
      deviceLabel: _readNonBlankString(json['device_label']),
      userAgent: _readNonBlankString(json['user_agent']),
      ip: _readNonBlankString(json['ip']),
      geoCountry: _readNonBlankString(json['geo_country']),
      deviceFingerprint: _readNonBlankString(json['device_fingerprint']),
      revokedAt: _readDateTime(json['revoked_at']),
      revokedReason: _readNonBlankString(json['revoked_reason']),
    );
  }

  TeamOrgUnitEntry _orgUnitFromJson(
    ProxyAuthOperationsResponse response,
    Object? raw,
  ) {
    if (raw is! Map) {
      throw _malformed(response, 'org unit payload was malformed');
    }
    final json = Map<String, Object?>.from(raw);
    final orgUnitId = _readNonBlankString(json['org_unit_id']);
    final unitType = _readNonBlankString(json['unit_type']);
    final path = _readNonBlankString(json['path']);
    final label = _readNonBlankString(json['label']);
    if (orgUnitId == null ||
        unitType == null ||
        path == null ||
        label == null) {
      throw _malformed(response, 'org unit payload was incomplete');
    }
    return TeamOrgUnitEntry(
      orgUnitId: orgUnitId,
      parentOrgUnitId: _readNonBlankString(json['parent_org_unit_id']),
      unitType: unitType,
      path: path,
      label: label,
    );
  }

  TeamOrgLocationEntry _orgLocationFromJson(
    ProxyAuthOperationsResponse response,
    Object? raw,
  ) {
    if (raw is! Map) {
      throw _malformed(response, 'org location payload was malformed');
    }
    final json = Map<String, Object?>.from(raw);
    final locationId = _readNonBlankString(json['location_id']);
    final parentOrgUnitId = _readNonBlankString(json['parent_org_unit_id']);
    final orgUnitPath = _readNonBlankString(json['org_unit_path']);
    final label = _readNonBlankString(json['label']);
    if (locationId == null ||
        parentOrgUnitId == null ||
        orgUnitPath == null ||
        label == null) {
      throw _malformed(response, 'org location payload was incomplete');
    }
    return TeamOrgLocationEntry(
      locationId: locationId,
      parentOrgUnitId: parentOrgUnitId,
      orgUnitPath: orgUnitPath,
      label: label,
    );
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

  String _rolesListPath(String? scope) {
    final trimmed = _readNonBlankString(scope);
    if (trimmed == null) return rolesPath;
    return '$rolesPath?scope=${Uri.encodeQueryComponent(trimmed)}';
  }

  String _userActionPath(String userId, String action) {
    return '$usersPrefix${Uri.encodeComponent(userId)}/$action';
  }

  Future<ProxyAuthOperationsResponse> _get(String relativePath) async {
    return _send(
      relativePath: relativePath,
      send: (url, headers) => _httpClient.getJson(url: url, headers: headers),
    );
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

  Future<ProxyAuthOperationsResponse> _patch(
    String relativePath,
    Map<String, Object?> body,
  ) async {
    return _send(
      relativePath: relativePath,
      send: (url, headers) =>
          _httpClient.patchJson(url: url, headers: headers, body: body),
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

  TeamRoleCatalogEntry _roleFromJson(
    ProxyAuthOperationsResponse response,
    Object? raw,
  ) {
    if (raw is! Map) {
      throw _malformed(response, 'role payload was malformed');
    }
    final json = Map<String, Object?>.from(raw);
    final roleId = _readNonBlankString(json['role_id']);
    final roleKey = _readNonBlankString(json['role_key']);
    final displayName = _readNonBlankString(json['display_name']);
    final description = json['description'];
    final isSeeded = json['is_seeded'];
    final isEditable = json['is_editable'];
    final permissions = json['permissions'];
    if (roleId == null ||
        roleKey == null ||
        displayName == null ||
        description is! String ||
        isSeeded is! bool ||
        isEditable is! bool ||
        permissions is! List) {
      throw _malformed(response, 'role payload was incomplete');
    }
    return TeamRoleCatalogEntry(
      roleId: roleId,
      roleKey: roleKey,
      displayName: displayName,
      description: description,
      isSeeded: isSeeded,
      isEditable: isEditable,
      operatorId: _readNonBlankString(json['operator_id']),
      permissions: List<TeamRolePermissionRule>.unmodifiable(
        permissions.map((rawPermission) {
          if (rawPermission is! Map) {
            throw _malformed(response, 'role permission payload was malformed');
          }
          final permission = Map<String, Object?>.from(rawPermission);
          final permissionKey = _readNonBlankString(
            permission['permission_key'],
          );
          final effect = _readNonBlankString(permission['effect']);
          if (permissionKey == null ||
              (effect != 'allow' && effect != 'deny')) {
            throw _malformed(
              response,
              'role permission payload was incomplete',
            );
          }
          return TeamRolePermissionRule(
            permissionKey: permissionKey,
            effect: effect!,
          );
        }),
      ),
    );
  }

  TeamUserListEntry _teamUserFromJson(
    ProxyAuthOperationsResponse response,
    Object? raw,
  ) {
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
    final mfaRemovalPending = json['mfa_removal_pending'];
    final mfaRemovalRequestId = _readNonBlankString(
      json['mfa_removal_request_id'],
    );
    if (userId == null ||
        email == null ||
        displayName == null ||
        roleId == null ||
        roleLabel == null ||
        status == null ||
        mfaEnrolled is! bool) {
      throw _malformed(response, 'team user payload was incomplete');
    }
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
      mfaRemovalPending: mfaRemovalPending is bool ? mfaRemovalPending : false,
      mfaRemovalRequestId: mfaRemovalRequestId,
      userRoleId: _readNonBlankString(json['user_role_id']),
      lastActiveAt: _readDateTime(json['last_active_at']),
      grants: _teamGrantsFromJson(response, json['grants']),
    );
  }

  List<TeamGrantSnapshot> _teamGrantsFromJson(
    ProxyAuthOperationsResponse response,
    Object? raw,
  ) {
    if (raw == null) return const <TeamGrantSnapshot>[];
    if (raw is! List) {
      throw _malformed(response, 'team user grants payload was malformed');
    }
    return List<TeamGrantSnapshot>.unmodifiable(
      raw.map((entry) => _teamGrantFromJson(response, entry)),
    );
  }

  TeamGrantSnapshot _teamGrantFromJson(
    ProxyAuthOperationsResponse response,
    Object? raw,
  ) {
    if (raw is! Map) {
      throw _malformed(response, 'team user grant payload was malformed');
    }
    final json = Map<String, Object?>.from(raw);
    final userRoleId = _readNonBlankString(json['user_role_id']);
    final roleId = _readNonBlankString(json['role_id']);
    final scopeType = _readNonBlankString(json['scope_type']);
    if (userRoleId == null || roleId == null || scopeType == null) {
      throw _malformed(response, 'team user grant payload was incomplete');
    }
    final rawEffective = json['effective_location_ids'];
    final effectiveLocationIds = rawEffective is List
        ? List<String>.unmodifiable(
            rawEffective
                .whereType<String>()
                .where((entry) => entry.isNotEmpty),
          )
        : const <String>[];
    return TeamGrantSnapshot(
      userRoleId: userRoleId,
      roleId: roleId,
      roleLabel: _readNonBlankString(json['role_label']),
      scopeType: scopeType,
      orgUnitId: _readNonBlankString(json['org_unit_id']),
      locationId: _readNonBlankString(json['location_id']),
      sourceOrgUnitId: _readNonBlankString(json['source_org_unit_id']),
      effectiveLocationIds: effectiveLocationIds,
      validFrom: _readDateTime(json['valid_from']),
      validUntil: _readDateTime(json['valid_until']),
      revokedAt: _readDateTime(json['revoked_at']),
    );
  }

  TeamInviteListEntry _teamInviteFromJson(
    ProxyAuthOperationsResponse response,
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
    final expiresAt = _readDateTime(json['expires_at']);
    final createdAt = _readDateTime(json['created_at']);
    if (inviteId == null ||
        email == null ||
        roleId == null ||
        roleLabel == null ||
        scopeType == null ||
        expiresAt == null ||
        createdAt == null) {
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
      expiresAt: expiresAt,
      createdAt: createdAt,
    );
  }

  Map<String, Object?> _permissionUpdateJson(TeamRolePermissionUpdate update) {
    return <String, Object?>{
      'permission_key': update.permissionKey,
      'effect': update.effect ?? 'inherit',
    };
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

  static DateTime? _readDateTime(Object? value) {
    if (value is DateTime) return value.toUtc();
    final raw = _readNonBlankString(value);
    if (raw == null) return null;
    return DateTime.tryParse(raw)?.toUtc();
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
