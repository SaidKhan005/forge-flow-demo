// Phase 11A.13 - Roles + Hierarchy + Sessions admin gateway.
//
// Cross-operator inspect surface for the F&F Operations Console:
// the F&F admin picks an operator via the existing operator picker
// (`lib/admin/screens/operator_picker_screen.dart`) and then tabs
// through Roles, Hierarchy, and Sessions for that operator. All
// reads and writes flow through the admin proxy
// `/v1/admin/auth/{roles,role-grants,org-units,sessions}` family with
// an explicit `operator_id` query parameter and a `forge_admin`
// BYPASSRLS posture, mirroring the 11A.12 Members surface.
//
// Authority:
//
//   * docs/contracts/team_roles_hierarchy_console_parity_contract.md
//     "§ Roles + Permission Explainer (11W.2 + 11A.13 Roles tab)" +
//     "§ Hierarchy (11W.3 + 11A.13 Hierarchy tab)" +
//     "§ Sessions (11W.4 + 11A.13 Sessions tab)" +
//     "§ Operator self-service vs F&F admin path" +
//     "§ Idempotency keys" + "§ Audit-row shape".
//   * docs/contracts/auth_permission_key_catalog.md `admin.roles.*` +
//     `admin.session.force_logout` keys.
//
// Two implementations ship in this slice, mirroring the 11A.12
// gateway split:
//
//   * [HttpRolesHierarchySessionsAdminGateway] - production. GET +
//     POST against the proxy with the signed-in F&F admin's bearer
//     token. Bearer source is injected so production binds the
//     Firebase ID-token stream while widget tests pin a fixed value.
//
//   * [InMemoryRolesHierarchySessionsAdminGateway] (demo gateway,
//     in `demo_roles_hierarchy_sessions_admin_gateway.dart`) - demo
//     + widget tests. Mutates an in-memory collection so the admin
//     walkthrough runs end-to-end in `kDemoMode` without a backend.
//
// Idempotency-key minting lives on the screen layer (mirrors
// `_OperatorLocationAdminScreenState._nextIdempotencyKey` from 11A.1
// + the 11A.12 Members surface) - the gateway accepts the key from
// the caller and forwards it on the request header. Every retried
// mutation collapses to a single proxy `proxy_requests` row and a
// single audit row.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../auth/permission_keys.dart';
import 'admin_http_timeout.dart';

/// Bearer source the gateway attaches to every proxy call. Production
/// binds this to the admin Firebase ID-token stream; tests pin a
/// synthetic value.
typedef RolesHierarchySessionsBearerTokenProvider = Future<String> Function();

/// One role row visible in the Roles tab. `isSeeded == true` rows are
/// `super_admin` / `ff_support` / `operator_owner` /
/// `operator_general_manager` / `location_manager` / `supervisor` per
/// the parity contract § "Seeded roles". Seeded rows render
/// view-only by default; the admin can edit them only with
/// `admin.roles.edit_seeded` (MFA-required).
@immutable
class RoleAdminRow {
  const RoleAdminRow({
    required this.roleId,
    required this.roleKey,
    required this.displayName,
    required this.description,
    required this.isSeeded,
    required this.permissionKeys,
    this.operatorId,
  });

  /// Stable database id. Seeded roles share the same id across
  /// operators (they are global); custom roles carry per-operator ids.
  final String roleId;

  /// `team.users.view` style key. Custom roles are operator-scoped and
  /// carry an operator-specific key (e.g. `custom.floor_captain`).
  final String roleKey;

  /// Human label rendered in the Roles tab. For seeded roles this is
  /// the catalog display name (e.g. "Operator owner"). For custom
  /// roles the operator owner picks the label.
  final String displayName;

  /// Short, plain-English description shown alongside the role.
  final String description;

  /// True for the six seeded roles per the parity contract; false
  /// for custom operator-scoped roles.
  final bool isSeeded;

  /// Granted permission keys (frozen catalog from
  /// `auth_permission_key_catalog.md`).
  final List<String> permissionKeys;

  /// Null for global seeded roles; operator-scoped for custom roles
  /// per the parity contract § "Custom-role builder" which pins
  /// custom-role rows to carry `operator_id`.
  final String? operatorId;
}

/// One node in the org-unit hierarchy. Roots have
/// [parentOrgUnitId] == null. The screen builds the tree client-side
/// from a flat list returned by the gateway.
@immutable
class OrgUnitAdminNode {
  const OrgUnitAdminNode({
    required this.orgUnitId,
    required this.name,
    required this.operatorId,
    this.parentOrgUnitId,
    this.unitType,
    this.suspendedAt,
    this.deletedAt,
  });

  final String orgUnitId;
  final String name;
  final String operatorId;
  final String? parentOrgUnitId;

  /// GAP A3 — the real structural type from the `org_units.unit_type`
  /// column (`corp` / `region` / `district` / `location_group`). Was
  /// previously discarded and synthesized into a generic `'org_unit'`
  /// string at render time, which made every intermediate node look
  /// identical. Carried through verbatim now; the screen turns it into
  /// plain-English copy. Nullable so legacy payloads without the field
  /// still parse.
  final String? unitType;

  final DateTime? suspendedAt;
  final DateTime? deletedAt;

  bool get isSuspended => suspendedAt != null;
  bool get isDeleted => deletedAt != null;
}

/// One leaf in the hierarchy: a location attached to an org-unit.
/// Mirrors the Phase 11A.1 location admin record shape but is scoped
/// to the inspect surface (no business-day rollover hour or address
/// because the Hierarchy tab is read-mostly with audited move
/// actions, not full location editing — that lives on 11A.1).
@immutable
class HierarchyLocationLeaf {
  const HierarchyLocationLeaf({
    required this.locationId,
    required this.name,
    required this.operatorId,
    required this.orgUnitId,
    this.suspendedAt,
    this.deletedAt,
  });

  final String locationId;
  final String name;
  final String operatorId;
  final String orgUnitId;
  final DateTime? suspendedAt;
  final DateTime? deletedAt;

  bool get isSuspended => suspendedAt != null;
  bool get isDeleted => deletedAt != null;
}

/// One row in the Sessions tab. One row per `auth_sessions` row per
/// the parity contract § "Sessions" list-shape line.
@immutable
class SessionAdminRow {
  const SessionAdminRow({
    required this.sessionId,
    required this.userId,
    required this.userDisplayName,
    required this.userEmail,
    required this.deviceFingerprint,
    required this.ipGeoCity,
    required this.lastActiveAt,
    required this.createdAt,
  });

  final String sessionId;
  final String userId;
  final String userDisplayName;
  final String userEmail;

  /// Device fingerprint string (browser + OS) per the parity contract;
  /// not raw user-agent.
  final String deviceFingerprint;

  /// City-level geo hint per the parity contract; never raw IP.
  final String ipGeoCity;
  final DateTime lastActiveAt;
  final DateTime createdAt;
}

/// One audit-log row written by the admin gateway. Mirrors every
/// column pinned by the parity contract § "Audit-row shape": every
/// `actor_kind = forge_admin` write carries `admin_reason`,
/// `business_date`, and the calling admin UID.
@immutable
class RolesHierarchySessionsAuditEvent {
  const RolesHierarchySessionsAuditEvent({
    required this.eventId,
    required this.action,
    required this.occurredAt,
    required this.actorUserId,
    required this.operatorId,
    required this.targetKind,
    required this.targetId,
    required this.payload,
    required this.adminReason,
    required this.businessDate,
    this.actorKind = 'forge_admin',
    this.rowHash,
  });

  final String eventId;
  final String action;
  final DateTime occurredAt;
  final String actorUserId;
  final String actorKind;
  final String operatorId;
  final String targetKind;
  final String targetId;
  final Map<String, Object?> payload;
  final String adminReason;
  final DateTime businessDate;
  final String? rowHash;
}

/// 403 thrown when a non-forge-admin caller tries to mutate via this
/// gateway. Mirrors the 11A.12 Members gateway pattern; the screen
/// layer also hides every mutate affordance when `editingEnabled` is
/// false. The throw is defence in depth.
class RolesHierarchySessionsForbiddenException implements Exception {
  const RolesHierarchySessionsForbiddenException(this.message);

  final String message;

  @override
  String toString() => 'RolesHierarchySessionsForbiddenException: $message';
}

class RolesHierarchySessionsGatewayError implements Exception {
  const RolesHierarchySessionsGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() =>
      'RolesHierarchySessionsGatewayError($statusCode/$errorCode): $message';
}

/// Slice E — resolves the current actor's roles to gate hierarchy
/// mutations when no live permission snapshot is available. Tests
/// inject a mock implementation; production wires nothing today (the
/// gate is server-enforced, so the live HTTP gateway is constructed
/// with no resolver and the client gate is a no-op).
typedef RolesHierarchySessionsRoleResolver = Future<List<String>> Function();

/// Slice E — resolves the current actor's server-resolved permission-key
/// set. Mirrors the integration gateway's Slice E3 [PermissionResolver]:
/// purely additive alongside [RolesHierarchySessionsRoleResolver] and
/// never replaces it. When a permission resolver is wired and returns a
/// NON-EMPTY set, each hierarchy-mutation gate keys off the method's
/// `admin.hierarchy.*` key; when it is null or resolves EMPTY (demo /
/// un-hydrated / tests), the gate falls back to the role check, which is
/// byte-identical to the pre-slice behaviour (no gate at all when no
/// resolver is wired).
typedef RolesHierarchySessionsPermissionResolver =
    Future<Set<String>> Function();

/// Slice E — shared hierarchy-mutation gate evaluation used by every
/// concrete [RolesHierarchySessionsAdminGateway] implementation so all
/// 10 mutate-method call sites stay byte-identical (one place to audit
/// the invariant). Throws [RolesHierarchySessionsGatewayError] (403 /
/// `permission_denied`) when the actor may not perform the mutation;
/// returns normally (no gate) when neither resolver is wired.
///
/// Fail-safe key-first logic, mirroring the integration gateway's Slice
/// E3 `_evaluateRotationGate` (`integration_admin_gateway.dart`):
///   * Both resolvers null -> return (no gate; production server-
///     enforced, demo / widget-test un-gated). This is the BYTE-IDENTITY
///     branch: every current caller injects no resolver, so the gate is
///     a pure no-op and behaviour is exactly as before the slice.
///   * Permission set NON-EMPTY -> allow iff it contains [requiredKey];
///     otherwise deny. Activates only once a live permission snapshot is
///     supplied; a role holding the key is allowed even if not
///     super_admin, and a role lacking it is denied even if super_admin
///     (intentional, mirrors E3).
///   * Permission set EMPTY/absent -> fall back to the role check. The
///     `admin.hierarchy.*` keys default-grant to `super_admin` +
///     `ff_support` ONLY (see
///     `db/migrations/202605230900_phase_slice_e_admin_hierarchy_keys.sql`
///     "default-grant to super_admin + ff_support"), so the fallback
///     ALLOWS those two roles and denies all others. If no role resolver
///     is wired either, there is no gate.
Future<void> evaluateHierarchyMutationGate({
  required String requiredKey,
  required RolesHierarchySessionsPermissionResolver? permissionResolver,
  required RolesHierarchySessionsRoleResolver? roleResolver,
}) async {
  if (permissionResolver == null && roleResolver == null) {
    return; // No gate configured (production server-enforced / demo).
  }
  final perms = permissionResolver == null
      ? const <String>{}
      : await permissionResolver();
  if (perms.isNotEmpty) {
    // Live permission set is authoritative.
    if (!perms.contains(requiredKey)) {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 403,
        errorCode: 'permission_denied',
        message: 'caller lacks $requiredKey',
      );
    }
    return;
  }
  // Empty/absent permission set: fall back to the role check. The
  // default grant for these keys is super_admin + ff_support only.
  if (roleResolver == null) return;
  final roles = await roleResolver();
  final allowed =
      roles.contains(PermissionKeys.roleSuperAdmin) ||
      roles.contains(PermissionKeys.roleFfSupport);
  if (!allowed) {
    throw RolesHierarchySessionsGatewayError(
      statusCode: 403,
      errorCode: 'permission_denied',
      message: 'caller lacks $requiredKey',
    );
  }
}

abstract class RolesHierarchySessionsAdminGateway {
  Future<List<RoleAdminRow>> listRoles({required String operatorId});

  Future<List<OrgUnitAdminNode>> listOrgUnits({required String operatorId});

  Future<List<HierarchyLocationLeaf>> listHierarchyLocations({
    required String operatorId,
  });

  Future<List<SessionAdminRow>> listSessions({required String operatorId});

  /// Edit permissions on a seeded role. Gated on
  /// `admin.roles.edit_seeded` (MFA-required) per the parity contract.
  Future<RoleAdminRow> editSeededRole({
    required String operatorId,
    required String roleId,
    required List<String> permissionKeys,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  /// Create a custom operator-scoped role. Gated on
  /// `admin.roles.create_custom`.
  Future<RoleAdminRow> createCustomRole({
    required String operatorId,
    required String roleKey,
    required String displayName,
    required String description,
    required List<String> permissionKeys,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  /// Delete a custom operator-scoped role. Gated on
  /// `admin.roles.delete_custom`.
  Future<void> deleteCustomRole({
    required String operatorId,
    required String roleId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  /// Move an org-unit under a new parent. Audited per the parity
  /// contract § "Move semantics" + "§ Hierarchy".
  Future<OrgUnitAdminNode> createOrgUnit({
    required String operatorId,
    required String parentOrgUnitId,
    required String unitType,
    required String label,
    required String name,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  Future<OrgUnitAdminNode> moveOrgUnit({
    required String operatorId,
    required String orgUnitId,
    required String? newParentOrgUnitId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  /// GAP A1 — rename an org unit's display name (F&F admin path).
  /// `admin_reason` is REQUIRED. The corp root IS renameable.
  Future<OrgUnitAdminNode> renameOrgUnit({
    required String operatorId,
    required String orgUnitId,
    required String name,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  Future<OrgUnitAdminNode> suspendOrgUnit({
    required String operatorId,
    required String orgUnitId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  Future<OrgUnitAdminNode> reactivateOrgUnit({
    required String operatorId,
    required String orgUnitId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  Future<void> deleteOrgUnit({
    required String operatorId,
    required String orgUnitId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  /// Move a location under a new org-unit. Audited.
  Future<HierarchyLocationLeaf> moveLocation({
    required String operatorId,
    required String locationId,
    required String newOrgUnitId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  Future<HierarchyLocationLeaf> suspendLocation({
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  Future<HierarchyLocationLeaf> reactivateLocation({
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  Future<void> deleteLocation({
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  /// Force-logout a single session. Server returns
  /// `validation_failed/cannot_revoke_self` if the targeted session
  /// belongs to the calling admin per the parity contract § Sessions
  /// "Revoking the current session" line.
  Future<void> forceLogoutSession({
    required String operatorId,
    required String sessionId,
    required String userId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });
}

class _HierarchyEnvelope {
  const _HierarchyEnvelope({required this.orgUnits, required this.locations});

  final List<OrgUnitAdminNode> orgUnits;
  final List<HierarchyLocationLeaf> locations;
}

class HttpRolesHierarchySessionsAdminGateway
    implements RolesHierarchySessionsAdminGateway {
  HttpRolesHierarchySessionsAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
    RolesHierarchySessionsRoleResolver? roleResolver,
    RolesHierarchySessionsPermissionResolver? permissionResolver,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout,
       _roleResolver = roleResolver,
       _permissionResolver = permissionResolver;

  final Uri baseUri;
  final RolesHierarchySessionsBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  /// Slice E — optional role / permission sources for the hierarchy-
  /// mutation gate. Both null in production today (the gate is server-
  /// enforced; the live gateway is constructed with no resolver, so the
  /// client gate is a pure no-op and behaviour is byte-identical to the
  /// pre-slice path). When wired, see [evaluateHierarchyMutationGate].
  final RolesHierarchySessionsRoleResolver? _roleResolver;
  final RolesHierarchySessionsPermissionResolver? _permissionResolver;

  final Map<String, Future<_HierarchyEnvelope>> _hierarchyInFlight =
      <String, Future<_HierarchyEnvelope>>{};

  static const String rolesPath = '/v1/admin/auth/roles';
  static const String orgUnitsPath = '/v1/admin/auth/org-units';
  static const String sessionsPath = '/v1/admin/auth/sessions';

  @override
  Future<List<RoleAdminRow>> listRoles({required String operatorId}) async {
    final body = await _send(
      method: 'GET',
      path: rolesPath,
      queryParameters: <String, String>{'operator_id': operatorId},
    );
    final roles = (body['roles'] as List?) ?? const [];
    return <RoleAdminRow>[
      for (final role in roles)
        _roleRowFromJson((role as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<List<OrgUnitAdminNode>> listOrgUnits({
    required String operatorId,
  }) async {
    final hierarchy = await _loadHierarchy(operatorId);
    return hierarchy.orgUnits;
  }

  @override
  Future<List<HierarchyLocationLeaf>> listHierarchyLocations({
    required String operatorId,
  }) async {
    final hierarchy = await _loadHierarchy(operatorId);
    return hierarchy.locations;
  }

  Future<_HierarchyEnvelope> _loadHierarchy(String operatorId) {
    final existing = _hierarchyInFlight[operatorId];
    if (existing != null) return existing;
    final next = _fetchHierarchy(operatorId);
    _hierarchyInFlight[operatorId] = next;
    next.whenComplete(() => _hierarchyInFlight.remove(operatorId));
    return next;
  }

  Future<_HierarchyEnvelope> _fetchHierarchy(String operatorId) async {
    final body = await _send(
      method: 'GET',
      path: orgUnitsPath,
      queryParameters: <String, String>{'operator_id': operatorId},
    );
    final units = (body['org_units'] as List?) ?? const [];
    final locations = (body['locations'] as List?) ?? const [];
    return _HierarchyEnvelope(
      orgUnits: <OrgUnitAdminNode>[
        for (final unit in units)
          _orgUnitFromJson((unit as Map).cast<String, Object?>()),
      ],
      locations: <HierarchyLocationLeaf>[
        for (final loc in locations)
          _locationLeafFromJson((loc as Map).cast<String, Object?>()),
      ],
    );
  }

  @override
  Future<List<SessionAdminRow>> listSessions({
    required String operatorId,
  }) async {
    final body = await _send(
      method: 'GET',
      path: sessionsPath,
      queryParameters: <String, String>{'operator_id': operatorId},
    );
    final sessions = (body['sessions'] as List?) ?? const [];
    return <SessionAdminRow>[
      for (final s in sessions)
        _sessionRowFromJson((s as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<RoleAdminRow> editSeededRole({
    required String operatorId,
    required String roleId,
    required List<String> permissionKeys,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'editSeededRole');
    _requireAdminReason(adminReason, 'editSeededRole');
    final body = await _send(
      method: 'POST',
      path: '$rolesPath/${Uri.encodeComponent(roleId)}/permissions',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'permission_keys': permissionKeys,
        'admin_reason': adminReason,
      },
    );
    return _roleRowFromJson(_asMap(body['role']));
  }

  @override
  Future<RoleAdminRow> createCustomRole({
    required String operatorId,
    required String roleKey,
    required String displayName,
    required String description,
    required List<String> permissionKeys,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'createCustomRole');
    _requireAdminReason(adminReason, 'createCustomRole');
    final body = await _send(
      method: 'POST',
      path: rolesPath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'role_key': roleKey,
        'display_name': displayName,
        'description': description,
        'permission_keys': permissionKeys,
        'admin_reason': adminReason,
      },
    );
    return _roleRowFromJson(_asMap(body['role']));
  }

  @override
  Future<void> deleteCustomRole({
    required String operatorId,
    required String roleId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'deleteCustomRole');
    _requireAdminReason(adminReason, 'deleteCustomRole');
    await _send(
      method: 'POST',
      path: '$rolesPath/${Uri.encodeComponent(roleId)}/delete',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'admin_reason': adminReason,
      },
    );
  }

  @override
  Future<OrgUnitAdminNode> createOrgUnit({
    required String operatorId,
    required String parentOrgUnitId,
    required String unitType,
    required String label,
    required String name,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    await _evaluateHierarchyGate(requiredKey: PermissionKeys.adminHierarchyCreate);
    _requireEditable(actorIsForgeAdmin, 'createOrgUnit');
    _requireAdminReason(adminReason, 'createOrgUnit');
    final body = await _send(
      method: 'POST',
      path: orgUnitsPath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'parent_org_unit_id': parentOrgUnitId,
        'unit_type': unitType,
        'label': label,
        'name': name,
        'admin_reason': adminReason,
      },
    );
    final orgUnit = body['org_unit'];
    if (orgUnit != null) {
      return _orgUnitFromJson(_asMap(orgUnit));
    }
    return OrgUnitAdminNode(
      orgUnitId: _firstStringField(body, const <String>['org_unit_id', 'id']),
      name: name,
      operatorId: operatorId,
      parentOrgUnitId: parentOrgUnitId,
      unitType: unitType,
    );
  }

  @override
  Future<OrgUnitAdminNode> moveOrgUnit({
    required String operatorId,
    required String orgUnitId,
    required String? newParentOrgUnitId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    await _evaluateHierarchyGate(requiredKey: PermissionKeys.adminHierarchyMove);
    _requireEditable(actorIsForgeAdmin, 'moveOrgUnit');
    _requireAdminReason(adminReason, 'moveOrgUnit');
    final body = await _send(
      method: 'PATCH',
      path: '$orgUnitsPath/${Uri.encodeComponent(orgUnitId)}/parent',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'parent_org_unit_id': newParentOrgUnitId,
        'admin_reason': adminReason,
      },
    );
    final orgUnit = body['org_unit'];
    if (orgUnit != null) {
      return _orgUnitFromJson(_asMap(orgUnit));
    }
    return OrgUnitAdminNode(
      orgUnitId: orgUnitId,
      name:
          _optionalString(body['name']) ??
          _optionalString(body['label']) ??
          orgUnitId,
      operatorId: operatorId,
      parentOrgUnitId: newParentOrgUnitId,
    );
  }

  @override
  Future<OrgUnitAdminNode> renameOrgUnit({
    required String operatorId,
    required String orgUnitId,
    required String name,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    await _evaluateHierarchyGate(requiredKey: PermissionKeys.adminHierarchyRename);
    _requireEditable(actorIsForgeAdmin, 'renameOrgUnit');
    _requireAdminReason(adminReason, 'renameOrgUnit');
    final body = await _send(
      method: 'PATCH',
      path: '$orgUnitsPath/${Uri.encodeComponent(orgUnitId)}/name',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'name': name,
        'admin_reason': adminReason,
      },
    );
    final orgUnit = body['org_unit'];
    if (orgUnit != null) {
      return _orgUnitFromJson(_asMap(orgUnit));
    }
    return OrgUnitAdminNode(
      orgUnitId: orgUnitId,
      name: name,
      operatorId: operatorId,
    );
  }

  @override
  Future<OrgUnitAdminNode> suspendOrgUnit({
    required String operatorId,
    required String orgUnitId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) {
    return _orgUnitLifecycle(
      operation: 'suspendOrgUnit',
      operatorId: operatorId,
      orgUnitId: orgUnitId,
      action: 'suspend',
      idempotencyKey: idempotencyKey,
      actorIsForgeAdmin: actorIsForgeAdmin,
      adminReason: adminReason,
    );
  }

  @override
  Future<OrgUnitAdminNode> reactivateOrgUnit({
    required String operatorId,
    required String orgUnitId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) {
    return _orgUnitLifecycle(
      operation: 'reactivateOrgUnit',
      operatorId: operatorId,
      orgUnitId: orgUnitId,
      action: 'reactivate',
      idempotencyKey: idempotencyKey,
      actorIsForgeAdmin: actorIsForgeAdmin,
      adminReason: adminReason,
    );
  }

  Future<OrgUnitAdminNode> _orgUnitLifecycle({
    required String operation,
    required String operatorId,
    required String orgUnitId,
    required String action,
    required String idempotencyKey,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    await _evaluateHierarchyGate(requiredKey: PermissionKeys.adminHierarchySuspend);
    _requireEditable(actorIsForgeAdmin, operation);
    _requireAdminReason(adminReason, operation);
    final body = await _send(
      method: 'PATCH',
      path: '$orgUnitsPath/${Uri.encodeComponent(orgUnitId)}/$action',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'admin_reason': adminReason,
      },
    );
    return _orgUnitFromJson(_asMap(body['org_unit']));
  }

  @override
  Future<void> deleteOrgUnit({
    required String operatorId,
    required String orgUnitId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    await _evaluateHierarchyGate(requiredKey: PermissionKeys.adminHierarchyDelete);
    _requireEditable(actorIsForgeAdmin, 'deleteOrgUnit');
    _requireAdminReason(adminReason, 'deleteOrgUnit');
    await _send(
      method: 'POST',
      path: '$orgUnitsPath/${Uri.encodeComponent(orgUnitId)}/delete',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'admin_reason': adminReason,
      },
    );
  }

  @override
  Future<HierarchyLocationLeaf> moveLocation({
    required String operatorId,
    required String locationId,
    required String newOrgUnitId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    await _evaluateHierarchyGate(requiredKey: PermissionKeys.adminHierarchyMove);
    _requireEditable(actorIsForgeAdmin, 'moveLocation');
    _requireAdminReason(adminReason, 'moveLocation');
    final body = await _send(
      method: 'PATCH',
      path:
          '/v1/admin/auth/locations/${Uri.encodeComponent(locationId)}/org-unit',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'parent_org_unit_id': newOrgUnitId,
        'admin_reason': adminReason,
      },
    );
    final location = body['location'];
    if (location != null) {
      return _locationLeafFromJson(_asMap(location));
    }
    return HierarchyLocationLeaf(
      locationId: locationId,
      name: _optionalString(body['location_label']) ?? locationId,
      operatorId: operatorId,
      orgUnitId: newOrgUnitId,
    );
  }

  @override
  Future<HierarchyLocationLeaf> suspendLocation({
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) {
    return _locationLifecycle(
      operation: 'suspendLocation',
      operatorId: operatorId,
      locationId: locationId,
      action: 'suspend',
      idempotencyKey: idempotencyKey,
      actorIsForgeAdmin: actorIsForgeAdmin,
      adminReason: adminReason,
    );
  }

  @override
  Future<HierarchyLocationLeaf> reactivateLocation({
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) {
    return _locationLifecycle(
      operation: 'reactivateLocation',
      operatorId: operatorId,
      locationId: locationId,
      action: 'reactivate',
      idempotencyKey: idempotencyKey,
      actorIsForgeAdmin: actorIsForgeAdmin,
      adminReason: adminReason,
    );
  }

  Future<HierarchyLocationLeaf> _locationLifecycle({
    required String operation,
    required String operatorId,
    required String locationId,
    required String action,
    required String idempotencyKey,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    await _evaluateHierarchyGate(requiredKey: PermissionKeys.adminHierarchySuspend);
    _requireEditable(actorIsForgeAdmin, operation);
    _requireAdminReason(adminReason, operation);
    final body = await _send(
      method: 'PATCH',
      path:
          '/v1/admin/auth/locations/${Uri.encodeComponent(locationId)}/$action',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'admin_reason': adminReason,
      },
    );
    return _locationLeafFromJson(_asMap(body['location']));
  }

  @override
  Future<void> deleteLocation({
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    await _evaluateHierarchyGate(requiredKey: PermissionKeys.adminHierarchyDelete);
    _requireEditable(actorIsForgeAdmin, 'deleteLocation');
    _requireAdminReason(adminReason, 'deleteLocation');
    await _send(
      method: 'POST',
      path:
          '/v1/admin/auth/locations/${Uri.encodeComponent(locationId)}/delete',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'admin_reason': adminReason,
      },
    );
  }

  @override
  Future<void> forceLogoutSession({
    required String operatorId,
    required String sessionId,
    required String userId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'forceLogoutSession');
    _requireAdminReason(adminReason, 'forceLogoutSession');
    await _send(
      method: 'POST',
      path: '$sessionsPath/${Uri.encodeComponent(sessionId)}/revoke',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'user_id': userId,
        'admin_reason': adminReason,
      },
    );
  }

  /// Slice E — key-first hierarchy-mutation gate with a fail-safe role
  /// fallback (default grant: super_admin + ff_support). Delegates to
  /// the shared [evaluateHierarchyMutationGate] so the live and demo
  /// gateways share one auditable evaluation. With no resolver wired
  /// (production today / every current caller) this is a no-op.
  Future<void> _evaluateHierarchyGate({required String requiredKey}) {
    return evaluateHierarchyMutationGate(
      requiredKey: requiredKey,
      permissionResolver: _permissionResolver,
      roleResolver: _roleResolver,
    );
  }

  void _requireEditable(bool actorIsForgeAdmin, String operation) {
    if (!actorIsForgeAdmin) {
      throw RolesHierarchySessionsForbiddenException(
        '$operation requires forge_admin role',
      );
    }
  }

  void _requireAdminReason(String adminReason, String operation) {
    if (adminReason.trim().isEmpty) {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 400,
        errorCode: 'admin_reason_required',
        message: '$operation requires a non-empty admin_reason',
      );
    }
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    Map<String, String> queryParameters = const <String, String>{},
    Map<String, Object?>? jsonBody,
    String? idempotencyKey,
  }) async {
    final token = await bearerTokenProvider();
    var uri = baseUri.resolve(path);
    if (queryParameters.isNotEmpty) {
      uri = uri.replace(queryParameters: queryParameters);
    }
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    if (jsonBody != null) {
      request.headers['content-type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(jsonBody));
    }
    late final http.Response response;
    try {
      response = await sendAdminHttpRequest(
        _httpClient,
        request,
        timeout: _timeout,
      );
    } on AdminHttpTimeoutException {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message:
            'admin roles/hierarchy/sessions proxy timed out after '
            '${_timeout.inSeconds}s',
      );
    }
    final raw = utf8.decode(response.bodyBytes);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) parsed = decoded.cast<String, Object?>();
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return parsed;
    }
    final message =
        (parsed['message'] as String?) ??
        'admin roles/hierarchy/sessions proxy returned an error';
    if (response.statusCode == 403) {
      throw RolesHierarchySessionsForbiddenException(message);
    }
    throw RolesHierarchySessionsGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message: message,
    );
  }
}

RoleAdminRow _roleRowFromJson(Map<String, Object?> json) {
  final permsRaw = json['permission_keys'];
  final permissions = <String>[
    if (permsRaw is List)
      for (final p in permsRaw)
        if (p is String) p,
  ];
  return RoleAdminRow(
    roleId: _firstStringField(json, const <String>['role_id', 'id']),
    roleKey: _firstStringField(json, const <String>['role_key', 'key']),
    displayName: _firstStringField(json, const <String>[
      'display_name',
      'role_label',
      'name',
      'role_key',
    ]),
    description: (json['description'] as String?) ?? '',
    isSeeded: _boolField(json, 'is_seeded'),
    permissionKeys: List<String>.unmodifiable(permissions),
    operatorId: _optionalString(json['operator_id']),
  );
}

OrgUnitAdminNode _orgUnitFromJson(Map<String, Object?> json) {
  return OrgUnitAdminNode(
    orgUnitId: _firstStringField(json, const <String>['org_unit_id', 'id']),
    name: _firstStringField(json, const <String>[
      'name',
      'display_name',
      'label',
      'org_unit_name',
    ]),
    operatorId: _optionalString(json['operator_id']) ?? '',
    parentOrgUnitId: _optionalString(json['parent_org_unit_id']),
    unitType: _optionalString(json['unit_type']),
    suspendedAt: _optionalDateTime(json['suspended_at']),
    deletedAt: _optionalDateTime(json['deleted_at']),
  );
}

HierarchyLocationLeaf _locationLeafFromJson(Map<String, Object?> json) {
  return HierarchyLocationLeaf(
    locationId: _firstStringField(json, const <String>['location_id', 'id']),
    name: _firstStringField(json, const <String>[
      'name',
      'display_name',
      'label',
      'location_label',
    ]),
    operatorId: _optionalString(json['operator_id']) ?? '',
    orgUnitId:
        _optionalString(json['org_unit_id']) ??
        _optionalString(json['parent_org_unit_id']) ??
        '',
    suspendedAt: _optionalDateTime(json['suspended_at']),
    deletedAt: _optionalDateTime(json['deleted_at']),
  );
}

SessionAdminRow _sessionRowFromJson(Map<String, Object?> json) {
  final lastActiveAt =
      _optionalDateTime(json['last_active_at']) ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  return SessionAdminRow(
    sessionId: _stringField(json, 'session_id'),
    userId: _stringField(json, 'user_id'),
    userDisplayName:
        _firstOptionalStringField(json, const <String>[
          'user_display_name',
          'display_name',
          'user_email',
        ]) ??
        'Unknown user',
    userEmail: _stringField(json, 'user_email'),
    deviceFingerprint:
        _optionalString(json['device_fingerprint']) ?? 'Unknown device',
    ipGeoCity: _optionalString(json['ip_geo_city']) ?? 'Unknown location',
    lastActiveAt: lastActiveAt,
    createdAt: _optionalDateTime(json['created_at']) ?? lastActiveAt,
  );
}

Map<String, Object?> _asMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  return const <String, Object?>{};
}

String _stringField(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw StateError('missing string field $key');
}

String _firstStringField(Map<String, Object?> json, List<String> keys) {
  final value = _firstOptionalStringField(json, keys);
  if (value != null) return value;
  throw StateError('missing string field ${keys.join('/')}');
}

String? _firstOptionalStringField(
  Map<String, Object?> json,
  List<String> keys,
) {
  for (final key in keys) {
    final value = _optionalString(json[key]);
    if (value != null) return value;
  }
  return null;
}

bool _boolField(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  if (value is String) return value == 'true';
  return false;
}

String? _optionalString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

DateTime? _optionalDateTime(Object? value) {
  if (value is DateTime) return value.toUtc();
  if (value is String && value.isNotEmpty) {
    return DateTime.parse(value).toUtc();
  }
  return null;
}

/// Display labels for the seeded role keys. Mirrors
/// `kSeededRoleDisplayNames` from the 11A.12 Members surface but
/// includes the F&F-internal seeded roles too — the inspect surface
/// shows ALL roles for the chosen operator, including the
/// `super_admin` / `ff_support` rows in case the operator's owners
/// have ever been crossed-grafted on (those rows render
/// view-only for everyone except a super_admin holding
/// `admin.roles.edit_seeded`).
const Map<String, String> kRoleDisplayNamesForAdmin = <String, String>{
  'super_admin': 'F&F super admin',
  'ff_support': 'F&F support',
  'operator_owner': 'Owner',
  'operator_general_manager': 'General Manager',
  'location_manager': 'Location Manager',
  'supervisor': 'Supervisor',
};

String roleAdminDisplayLabel(RoleAdminRow row) {
  if (!row.isSeeded) return row.displayName;
  final seededLabel = kRoleDisplayNamesForAdmin[row.roleKey];
  if (seededLabel != null) return seededLabel;
  return row.displayName.isNotEmpty ? row.displayName : row.roleKey;
}
