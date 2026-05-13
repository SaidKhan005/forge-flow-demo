// Phase 11W.2 - Operator Web team-roles gateway (live).
//
// Re-implementation of the role catalog + role-grant slice of
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
// surface added by 11W.2):
//
//   * GET    /v1/auth/team/roles
//   * POST   /v1/auth/team/roles
//   * PATCH  /v1/auth/team/roles/{role_id}
//   * DELETE /v1/auth/team/roles/{role_id}
//   * POST   /v1/auth/team/role-grants
//   * DELETE /v1/auth/team/role-grants/{user_role_id}
//
// Idempotency posture: every write carries an `Idempotency-Key`
// header; the screen layer mints one key per user action and threads
// it through the editor screen / dialog -> gateway path, matching the
// parity contract idempotency rule. The gateway does NOT mint keys
// internally (doing so would double-mint and break replay).

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../services/auth/auth_operations_gateway.dart';

/// Narrow interface the Roles screen + custom-role editor + Permission
/// Explainer read against. Mirrors the role-catalog + role-grant slice
/// of the existing `AuthOperationsGateway` interface. The Permission
/// Explainer is a pure projection over the catalog returned by
/// [listRoles] plus the frozen [PermissionKeys] catalog, so it does
/// not need its own gateway surface.
abstract class WebTeamRolesGateway {
  Future<TeamRoleCatalogListed> listRoles(TeamRoleCatalogListCommand command);

  Future<TeamRoleCreated> createRole(
    TeamRoleCreateCommand command, {
    required String idempotencyKey,
  });

  Future<TeamRolePatched> patchRole(
    TeamRolePatchCommand command, {
    required String idempotencyKey,
  });

  Future<TeamRoleDeleted> deleteRole(
    TeamRoleDeleteCommand command, {
    required String idempotencyKey,
  });

  Future<TeamRoleGrantCreated> createRoleGrant(
    TeamRoleGrantCreateCommand command, {
    required String idempotencyKey,
  });

  Future<TeamRoleGrantRevoked> revokeRoleGrant(
    TeamRoleGrantRevokeCommand command, {
    required String idempotencyKey,
  });
}

/// Live wire shape returned by the proxy. Mirrors the response
/// envelope `proxy_auth_operations_gateway.dart` already consumes.
class WebTeamRolesResponse {
  const WebTeamRolesResponse({required this.statusCode, required this.body});

  final int statusCode;
  final Map<String, Object?> body;
}

/// Thrown when the proxy returns a non-2xx for a role catalog / grant
/// call, or when the response body cannot be parsed.
class WebTeamRolesError implements Exception {
  const WebTeamRolesError({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'WebTeamRolesError(code: $code, status: $statusCode, message: $message)';
}

/// Path constants used by both the gateway and its tests.
class WebTeamRolesPaths {
  const WebTeamRolesPaths._();

  static const String roles = '/v1/auth/team/roles';
  static const String rolesPrefix = '/v1/auth/team/roles/';
  static const String roleGrants = '/v1/auth/team/role-grants';
  static const String roleGrantsPrefix = '/v1/auth/team/role-grants/';

  static String role(String roleId) =>
      '$rolesPrefix${Uri.encodeComponent(roleId)}';

  static String roleGrant(String userRoleId) =>
      '$roleGrantsPrefix${Uri.encodeComponent(userRoleId)}';

  static String rolesList(String? scope) {
    if (scope == null || scope.trim().isEmpty) return roles;
    return '$roles?scope=${Uri.encodeQueryComponent(scope.trim())}';
  }
}

/// Live `package:http` implementation. Reads the Firebase ID token
/// from the supplied provider on every call so refreshed tokens land
/// on the next request.
class WebTeamRolesGatewayLive implements WebTeamRolesGateway {
  WebTeamRolesGatewayLive({
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
  Future<TeamRoleCatalogListed> listRoles(
    TeamRoleCatalogListCommand command,
  ) async {
    final response = await _send(
      method: 'GET',
      path: WebTeamRolesPaths.rolesList(command.scope),
    );
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
  Future<TeamRoleCreated> createRole(
    TeamRoleCreateCommand command, {
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'POST',
      path: WebTeamRolesPaths.roles,
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{
        'role_key': command.roleKey,
        'display_name': command.displayName,
        if (command.description.trim().isNotEmpty)
          'description': command.description.trim(),
        if (command.permissions.isNotEmpty)
          'permissions': command.permissions
              .map(_permissionUpdateJson)
              .toList(),
        if (_readNonBlankString(command.reason) != null)
          'reason': command.reason!.trim(),
      },
    );
    _expectStatus(response, 201);
    return TeamRoleCreated(
      role: _roleFromJson(response, response.body['role']),
    );
  }

  @override
  Future<TeamRolePatched> patchRole(
    TeamRolePatchCommand command, {
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'PATCH',
      path: WebTeamRolesPaths.role(command.roleId),
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{
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
  Future<TeamRoleDeleted> deleteRole(
    TeamRoleDeleteCommand command, {
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'DELETE',
      path: WebTeamRolesPaths.role(command.roleId),
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{
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
  Future<TeamRoleGrantCreated> createRoleGrant(
    TeamRoleGrantCreateCommand command, {
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'POST',
      path: WebTeamRolesPaths.roleGrants,
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{
        'user_id': command.targetUserId,
        'role_id': command.roleId,
        'scope_type': command.scopeType,
        if (command.targetLocationId != null)
          'location_id': command.targetLocationId,
        if (command.targetOrgUnitId != null)
          'org_unit_id': command.targetOrgUnitId,
        if (_readNonBlankString(command.reason) != null)
          'reason': command.reason!.trim(),
      },
    );
    _expectStatus(response, 201);
    final userRoleId = _readNonBlankString(response.body['user_role_id']);
    if (userRoleId == null) {
      throw _malformed(response, 'role grant response was incomplete');
    }
    return TeamRoleGrantCreated(userRoleId: userRoleId);
  }

  @override
  Future<TeamRoleGrantRevoked> revokeRoleGrant(
    TeamRoleGrantRevokeCommand command, {
    required String idempotencyKey,
  }) async {
    final response = await _send(
      method: 'DELETE',
      path: WebTeamRolesPaths.roleGrant(command.userRoleId),
      idempotencyKey: idempotencyKey,
      body: <String, Object?>{
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

  Future<WebTeamRolesResponse> _send({
    required String method,
    required String path,
    String? idempotencyKey,
    Map<String, Object?>? body,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const WebTeamRolesError(
        code: 'no_id_token',
        message:
            'team-roles gateway has no live Firebase ID token to attach to '
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
      throw const WebTeamRolesError(
        code: 'transport_timeout',
        message:
            'team-roles gateway request timed out before reaching the proxy.',
      );
    } catch (error) {
      throw WebTeamRolesError(
        code: 'transport_error',
        message:
            'team-roles gateway request failed before reaching the proxy '
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
    return WebTeamRolesResponse(
      statusCode: streamed.statusCode,
      body: responseBody,
    );
  }

  void _expectStatus(WebTeamRolesResponse response, int expected) {
    if (response.statusCode == expected) return;
    throw WebTeamRolesError(
      code: _readNonBlankString(response.body['error']) ?? 'team_roles_failed',
      message:
          _readNonBlankString(response.body['message']) ??
          'proxy returned status ${response.statusCode}',
      statusCode: response.statusCode,
    );
  }

  WebTeamRolesError _malformed(WebTeamRolesResponse response, String message) {
    return WebTeamRolesError(
      code: 'malformed_response',
      message: message,
      statusCode: response.statusCode,
    );
  }

  TeamRoleCatalogEntry _roleFromJson(
    WebTeamRolesResponse response,
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
    // Lane B B2.4 — `catalog_version_id` + `catalog_published_at`
    // are additive nullable fields the proxy adds on every seeded
    // row when the operator is following a published catalog
    // version. Missing fields (legacy proxy build) and explicit
    // nulls (custom roles, genesis state) both surface as null
    // here; the screen renders the "Updated by F&F on <date>"
    // annotation only when both are non-null and falls back to
    // "Managed by Forge & Flow" otherwise.
    final catalogVersionId = _readNonBlankString(json['catalog_version_id']);
    final catalogPublishedAt = _readCatalogPublishedAt(
      response,
      json['catalog_published_at'],
    );
    return TeamRoleCatalogEntry(
      roleId: roleId,
      roleKey: roleKey,
      displayName: displayName,
      description: description,
      isSeeded: isSeeded,
      isEditable: isEditable,
      operatorId: _readNonBlankString(json['operator_id']),
      catalogVersionId: catalogVersionId,
      catalogPublishedAt: catalogPublishedAt,
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

  /// Lane B B2.4 — Parse `catalog_published_at` defensively.
  ///
  /// The proxy emits a UTC ISO-8601 string; missing / explicit null
  /// is the back-compat shape (custom rows, genesis state, legacy
  /// proxy). A non-null value that isn't a parseable ISO-8601 string
  /// surfaces as a typed [WebTeamRolesError] so the screen layer can
  /// fall back to the version-agnostic copy without crashing.
  DateTime? _readCatalogPublishedAt(WebTeamRolesResponse response, Object? raw) {
    if (raw == null) return null;
    if (raw is! String) {
      throw _malformed(response, 'catalog_published_at was not a string');
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final parsed = DateTime.tryParse(trimmed);
    if (parsed == null) {
      throw _malformed(response, 'catalog_published_at was not ISO-8601');
    }
    return parsed.toUtc();
  }

  Map<String, Object?> _permissionUpdateJson(TeamRolePermissionUpdate update) {
    return <String, Object?>{
      'permission_key': update.permissionKey,
      'effect': update.effect ?? 'inherit',
    };
  }

  static String? _readNonBlankString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
