// Phase 11A.13 - in-memory demo gateway for Roles + Hierarchy +
// Sessions admin surface. Powers the kDemoMode walkthrough plus
// widget tests. Mirrors the shape of
// [HttpRolesHierarchySessionsAdminGateway]: every write is gated on
// `actorIsForgeAdmin` + non-empty `admin_reason`, every write
// captures an audit event with `actor_kind = forge_admin`, and every
// retried call with the same idempotency key returns the original
// result without double-mutation.
//
// Demo seeds reuse the two operators from the 11A.12 Members
// fixture (Demo Diner Co. + Sunset Cafe Group) so the walkthrough
// can hop from the Members surface straight into Roles / Hierarchy /
// Sessions for the same operator without seeding extra identities.

import 'package:flutter/foundation.dart';

import 'demo_members_admin_gateway.dart';
import 'roles_hierarchy_sessions_admin_gateway.dart';

class InMemoryRolesHierarchySessionsAdminGateway
    implements RolesHierarchySessionsAdminGateway {
  InMemoryRolesHierarchySessionsAdminGateway({
    Map<String, List<RoleAdminRow>>? rolesByOperator,
    Map<String, List<OrgUnitAdminNode>>? orgUnitsByOperator,
    Map<String, List<HierarchyLocationLeaf>>? locationsByOperator,
    Map<String, List<SessionAdminRow>>? sessionsByOperator,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _roles = <String, List<RoleAdminRow>>{
         for (final entry in (rolesByOperator ?? const {}).entries)
           entry.key: List<RoleAdminRow>.of(entry.value),
       },
       _orgUnits = <String, List<OrgUnitAdminNode>>{
         for (final entry in (orgUnitsByOperator ?? const {}).entries)
           entry.key: List<OrgUnitAdminNode>.of(entry.value),
       },
       _locations = <String, List<HierarchyLocationLeaf>>{
         for (final entry in (locationsByOperator ?? const {}).entries)
           entry.key: List<HierarchyLocationLeaf>.of(entry.value),
       },
       _sessions = <String, List<SessionAdminRow>>{
         for (final entry in (sessionsByOperator ?? const {}).entries)
           entry.key: List<SessionAdminRow>.of(entry.value),
       };

  final DateTime Function() _clock;
  final Map<String, List<RoleAdminRow>> _roles;
  final Map<String, List<OrgUnitAdminNode>> _orgUnits;
  final Map<String, List<HierarchyLocationLeaf>> _locations;
  final Map<String, List<SessionAdminRow>> _sessions;
  final List<RolesHierarchySessionsAuditEvent> _auditLog =
      <RolesHierarchySessionsAuditEvent>[];

  /// Idempotency cache so a retried mutation collapses to a single
  /// audit row and a single state change.
  final Map<String, Object?> _idempotentResults = <String, Object?>{};

  /// Public read-only view of every audit event the gateway has
  /// captured so far. Tests assert on this directly.
  List<RolesHierarchySessionsAuditEvent> get capturedAuditEvents =>
      List<RolesHierarchySessionsAuditEvent>.unmodifiable(_auditLog);

  void _ensureForgeAdmin(bool actorIsForgeAdmin, String operation) {
    if (!actorIsForgeAdmin) {
      throw RolesHierarchySessionsForbiddenException(
        '$operation requires forge_admin role',
      );
    }
  }

  void _ensureAdminReason(String adminReason, String operation) {
    if (adminReason.trim().isEmpty) {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 400,
        errorCode: 'admin_reason_required',
        message: '$operation requires a non-empty admin_reason',
      );
    }
  }

  void _record({
    required String action,
    required String actorUserId,
    required String operatorId,
    required String targetKind,
    required String targetId,
    required Map<String, Object?> payload,
    required String adminReason,
  }) {
    final occurredAt = _clock();
    _auditLog.add(
      RolesHierarchySessionsAuditEvent(
        eventId: 'audit-${_auditLog.length + 1}',
        action: action,
        occurredAt: occurredAt,
        actorUserId: actorUserId,
        operatorId: operatorId,
        targetKind: targetKind,
        targetId: targetId,
        payload: Map<String, Object?>.unmodifiable(payload),
        adminReason: adminReason,
        businessDate: DateTime.utc(
          occurredAt.year,
          occurredAt.month,
          occurredAt.day,
        ),
      ),
    );
  }

  List<RoleAdminRow> _rolesFor(String operatorId) {
    return _roles.putIfAbsent(operatorId, () => <RoleAdminRow>[]);
  }

  List<OrgUnitAdminNode> _orgUnitsFor(String operatorId) {
    return _orgUnits.putIfAbsent(operatorId, () => <OrgUnitAdminNode>[]);
  }

  List<HierarchyLocationLeaf> _locationsFor(String operatorId) {
    return _locations.putIfAbsent(operatorId, () => <HierarchyLocationLeaf>[]);
  }

  List<SessionAdminRow> _sessionsFor(String operatorId) {
    return _sessions.putIfAbsent(operatorId, () => <SessionAdminRow>[]);
  }

  @override
  Future<List<RoleAdminRow>> listRoles({required String operatorId}) async {
    return List<RoleAdminRow>.unmodifiable(_rolesFor(operatorId));
  }

  @override
  Future<List<OrgUnitAdminNode>> listOrgUnits({
    required String operatorId,
  }) async {
    return List<OrgUnitAdminNode>.unmodifiable(_orgUnitsFor(operatorId));
  }

  @override
  Future<List<HierarchyLocationLeaf>> listHierarchyLocations({
    required String operatorId,
  }) async {
    return List<HierarchyLocationLeaf>.unmodifiable(_locationsFor(operatorId));
  }

  @override
  Future<List<SessionAdminRow>> listSessions({
    required String operatorId,
  }) async {
    return List<SessionAdminRow>.unmodifiable(_sessionsFor(operatorId));
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
    _ensureForgeAdmin(actorIsForgeAdmin, 'editSeededRole');
    _ensureAdminReason(adminReason, 'editSeededRole');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is RoleAdminRow) return cached;
    final roles = _rolesFor(operatorId);
    final index = roles.indexWhere((r) => r.roleId == roleId);
    if (index < 0) {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 404,
        errorCode: 'unknown_role',
        message: 'role $roleId not found for operator $operatorId',
      );
    }
    final prev = roles[index];
    if (!prev.isSeeded) {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 400,
        errorCode: 'not_seeded_role',
        message: 'editSeededRole only valid for seeded roles',
      );
    }
    final updated = RoleAdminRow(
      roleId: prev.roleId,
      roleKey: prev.roleKey,
      displayName: prev.displayName,
      description: prev.description,
      isSeeded: true,
      permissionKeys: List<String>.unmodifiable(permissionKeys),
      operatorId: prev.operatorId,
    );
    roles[index] = updated;
    _record(
      action: 'team.roles.edit_seeded',
      actorUserId: actorUserId,
      operatorId: operatorId,
      targetKind: 'team_role',
      targetId: roleId,
      payload: <String, Object?>{
        'permission_keys': <String, Object?>{
          'from': prev.permissionKeys,
          'to': updated.permissionKeys,
        },
      },
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = updated;
    return updated;
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
    _ensureForgeAdmin(actorIsForgeAdmin, 'createCustomRole');
    _ensureAdminReason(adminReason, 'createCustomRole');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is RoleAdminRow) return cached;
    final roles = _rolesFor(operatorId);
    if (roles.any((r) => r.roleKey == roleKey)) {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 409,
        errorCode: 'role_key_in_use',
        message: 'role_key already in use for this operator',
      );
    }
    final created = RoleAdminRow(
      roleId:
          'custom-role-${roles.length + 1}-'
          '${_clock().microsecondsSinceEpoch}',
      roleKey: roleKey,
      displayName: displayName,
      description: description,
      isSeeded: false,
      permissionKeys: List<String>.unmodifiable(permissionKeys),
      operatorId: operatorId,
    );
    roles.add(created);
    _record(
      action: 'team.roles.create_custom',
      actorUserId: actorUserId,
      operatorId: operatorId,
      targetKind: 'team_role',
      targetId: created.roleId,
      payload: <String, Object?>{
        'role_key': roleKey,
        'permission_keys': permissionKeys,
      },
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = created;
    return created;
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
    _ensureForgeAdmin(actorIsForgeAdmin, 'deleteCustomRole');
    _ensureAdminReason(adminReason, 'deleteCustomRole');
    if (_idempotentResults.containsKey(idempotencyKey)) return;
    final roles = _rolesFor(operatorId);
    final index = roles.indexWhere((r) => r.roleId == roleId);
    if (index < 0) {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 404,
        errorCode: 'unknown_role',
        message: 'role $roleId not found for operator $operatorId',
      );
    }
    final prev = roles[index];
    if (prev.isSeeded) {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 400,
        errorCode: 'cannot_delete_seeded',
        message: 'seeded roles cannot be deleted',
      );
    }
    roles.removeAt(index);
    _record(
      action: 'team.roles.delete_custom',
      actorUserId: actorUserId,
      operatorId: operatorId,
      targetKind: 'team_role',
      targetId: roleId,
      payload: <String, Object?>{'role_key': prev.roleKey},
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = const Object();
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
    _ensureForgeAdmin(actorIsForgeAdmin, 'createOrgUnit');
    _ensureAdminReason(adminReason, 'createOrgUnit');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is OrgUnitAdminNode) return cached;
    final units = _orgUnitsFor(operatorId);
    if (!units.any((u) => u.orgUnitId == parentOrgUnitId)) {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 404,
        errorCode: 'unknown_parent_org_unit',
        message: 'parent org unit $parentOrgUnitId not found',
      );
    }
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 400,
        errorCode: 'validation_failed',
        message: HierarchyValidationCopy.orgUnitNameEmpty,
      );
    }
    final hasDuplicate = units.any(
      (u) =>
          u.parentOrgUnitId == parentOrgUnitId &&
          u.name.toLowerCase() == trimmedName.toLowerCase(),
    );
    if (hasDuplicate) {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 400,
        errorCode: 'validation_failed',
        message: HierarchyValidationCopy.orgUnitNameDuplicate,
      );
    }
    final created = OrgUnitAdminNode(
      orgUnitId:
          'org-unit-demo-${units.length + 1}-'
          '${_clock().microsecondsSinceEpoch}',
      name: trimmedName,
      operatorId: operatorId,
      parentOrgUnitId: parentOrgUnitId,
    );
    units.add(created);
    _record(
      action: 'team.org_unit.create',
      actorUserId: actorUserId,
      operatorId: operatorId,
      targetKind: 'org_unit',
      targetId: created.orgUnitId,
      payload: <String, Object?>{
        'parent_org_unit_id': parentOrgUnitId,
        'unit_type': unitType,
        'label': label,
        'name': trimmedName,
      },
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = created;
    return created;
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
    _ensureForgeAdmin(actorIsForgeAdmin, 'moveOrgUnit');
    _ensureAdminReason(adminReason, 'moveOrgUnit');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is OrgUnitAdminNode) return cached;
    final units = _orgUnitsFor(operatorId);
    final index = units.indexWhere((u) => u.orgUnitId == orgUnitId);
    if (index < 0) {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 404,
        errorCode: 'unknown_org_unit',
        message: 'org unit $orgUnitId not found for operator $operatorId',
      );
    }
    if (newParentOrgUnitId == orgUnitId) {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 400,
        errorCode: 'cycle_detected',
        message: HierarchyValidationCopy.cycleDetected,
      );
    }
    if (newParentOrgUnitId != null &&
        _isDescendant(units, newParentOrgUnitId, orgUnitId)) {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 400,
        errorCode: 'cycle_detected',
        message: HierarchyValidationCopy.cycleDetected,
      );
    }
    final prev = units[index];
    final updated = OrgUnitAdminNode(
      orgUnitId: prev.orgUnitId,
      name: prev.name,
      operatorId: prev.operatorId,
      parentOrgUnitId: newParentOrgUnitId,
    );
    units[index] = updated;
    _record(
      action: 'team.org_unit.move',
      actorUserId: actorUserId,
      operatorId: operatorId,
      targetKind: 'org_unit',
      targetId: orgUnitId,
      payload: <String, Object?>{
        'parent_org_unit_id': <String, Object?>{
          'from': prev.parentOrgUnitId,
          'to': newParentOrgUnitId,
        },
      },
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = updated;
    return updated;
  }

  bool _isDescendant(
    List<OrgUnitAdminNode> units,
    String candidateId,
    String ancestorId,
  ) {
    String? cursor = candidateId;
    final seen = <String>{};
    while (cursor != null && seen.add(cursor)) {
      if (cursor == ancestorId) return true;
      final current = cursor;
      final parent = units.firstWhere(
        (u) => u.orgUnitId == current,
        orElse: () =>
            OrgUnitAdminNode(orgUnitId: current, name: '', operatorId: ''),
      );
      cursor = parent.parentOrgUnitId;
    }
    return false;
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
    _ensureForgeAdmin(actorIsForgeAdmin, 'moveLocation');
    _ensureAdminReason(adminReason, 'moveLocation');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is HierarchyLocationLeaf) return cached;
    final locations = _locationsFor(operatorId);
    final index = locations.indexWhere((l) => l.locationId == locationId);
    if (index < 0) {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 404,
        errorCode: 'unknown_location',
        message: 'location $locationId not found for operator $operatorId',
      );
    }
    final prev = locations[index];
    final updated = HierarchyLocationLeaf(
      locationId: prev.locationId,
      name: prev.name,
      operatorId: prev.operatorId,
      orgUnitId: newOrgUnitId,
    );
    locations[index] = updated;
    _record(
      action: 'team.location.move',
      actorUserId: actorUserId,
      operatorId: operatorId,
      targetKind: 'location',
      targetId: locationId,
      payload: <String, Object?>{
        'org_unit_id': <String, Object?>{
          'from': prev.orgUnitId,
          'to': newOrgUnitId,
        },
      },
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = updated;
    return updated;
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
    _ensureForgeAdmin(actorIsForgeAdmin, 'forceLogoutSession');
    _ensureAdminReason(adminReason, 'forceLogoutSession');
    if (userId == actorUserId) {
      // Per parity contract § Sessions "Revoking the current session":
      // F&F admin cannot revoke own admin session via this surface;
      // server returns `validation_failed/cannot_revoke_self`. The
      // demo gateway mirrors that response.
      throw RolesHierarchySessionsGatewayError(
        statusCode: 400,
        errorCode: 'cannot_revoke_self',
        message: SessionsValidationCopy.cannotRevokeSelf,
      );
    }
    if (_idempotentResults.containsKey(idempotencyKey)) return;
    final sessions = _sessionsFor(operatorId);
    final index = sessions.indexWhere((s) => s.sessionId == sessionId);
    if (index < 0) {
      throw RolesHierarchySessionsGatewayError(
        statusCode: 404,
        errorCode: 'unknown_session',
        message: 'session $sessionId not found for operator $operatorId',
      );
    }
    final removed = sessions.removeAt(index);
    _record(
      action: 'admin.session.force_logout',
      actorUserId: actorUserId,
      operatorId: operatorId,
      targetKind: 'auth_session',
      targetId: sessionId,
      payload: <String, Object?>{'user_id': removed.userId},
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = const Object();
  }

  @visibleForTesting
  void clearAuditEventsForTesting() {
    _auditLog.clear();
  }
}

/// Locked validation copy for the Hierarchy tab, mirrored verbatim
/// from the parity contract § "Hierarchy" "Validation copy (locked)".
class HierarchyValidationCopy {
  const HierarchyValidationCopy._();

  static const String orgUnitNameEmpty = 'Org unit name is required.';
  static const String orgUnitNameDuplicate =
      'An org unit with this name already exists in this group.';
  static const String cycleDetected = 'Cannot move into a child of itself.';
}

/// Locked validation copy for the Sessions tab.
class SessionsValidationCopy {
  const SessionsValidationCopy._();

  /// Parity contract § Sessions "Revoking the current session": F&F
  /// admin cannot revoke own admin session via this surface.
  static const String cannotRevokeSelf =
      'You cannot sign yourself out from this surface. '
      'Use admin sign-out instead.';
}

// ---------------------------------------------------------------------
// Demo seeds
// ---------------------------------------------------------------------

/// Demo seeds reuse the operators from `kDemoMembersByOperator` so
/// the walkthrough can hop seamlessly from Members into Roles /
/// Hierarchy / Sessions for the same operator.
const String kDemoDinerOrgUnitRoot = '00000000-0000-4000-8000-000000000d01';
const String kDemoDinerOrgUnitEast = '00000000-0000-4000-8000-000000000d02';
const String kDemoDinerOrgUnitWest = '00000000-0000-4000-8000-000000000d03';
const String kDemoSunsetOrgUnitRoot = '00000000-0000-4000-8000-000000000s01';

Map<String, List<RoleAdminRow>> kDemoRolesByOperator() {
  const dinerRoles = <RoleAdminRow>[
    RoleAdminRow(
      roleId: 'role-seed-operator-owner',
      roleKey: 'operator_owner',
      displayName: 'Operator owner',
      description:
          'Full access to the operator account, including team and billing.',
      isSeeded: true,
      permissionKeys: <String>[
        'team.users.view',
        'team.users.invite',
        'team.users.deactivate',
        'team.roles.assign',
        'team.audit_log.view',
      ],
    ),
    RoleAdminRow(
      roleId: 'role-seed-operator-manager',
      roleKey: 'operator_manager',
      displayName: 'Operator manager',
      description: 'Day-to-day operations and team management.',
      isSeeded: true,
      permissionKeys: <String>['team.users.view', 'team.roles.assign'],
    ),
    RoleAdminRow(
      roleId: 'role-seed-operator-supervisor',
      roleKey: 'operator_supervisor',
      displayName: 'Operator supervisor',
      description: 'Floor supervisor with read-only team visibility.',
      isSeeded: true,
      permissionKeys: <String>['team.users.view'],
    ),
    RoleAdminRow(
      roleId: 'role-seed-operator-staff',
      roleKey: 'operator_staff',
      displayName: 'Operator staff',
      description: 'Staff member.',
      isSeeded: true,
      permissionKeys: <String>[],
    ),
    RoleAdminRow(
      roleId: 'role-custom-floor-captain',
      roleKey: 'custom.floor_captain',
      displayName: 'Floor Captain',
      description:
          'Trusted lead who runs a shift but does not manage the team.',
      isSeeded: false,
      permissionKeys: <String>['team.users.view', 'team.audit_log.view'],
      operatorId: kDemoDinerOperatorId,
    ),
  ];
  const sunsetRoles = <RoleAdminRow>[
    RoleAdminRow(
      roleId: 'role-seed-operator-owner',
      roleKey: 'operator_owner',
      displayName: 'Operator owner',
      description:
          'Full access to the operator account, including team and billing.',
      isSeeded: true,
      permissionKeys: <String>[
        'team.users.view',
        'team.users.invite',
        'team.users.deactivate',
        'team.roles.assign',
        'team.audit_log.view',
      ],
    ),
    RoleAdminRow(
      roleId: 'role-seed-operator-staff',
      roleKey: 'operator_staff',
      displayName: 'Operator staff',
      description: 'Staff member.',
      isSeeded: true,
      permissionKeys: <String>[],
    ),
  ];
  return <String, List<RoleAdminRow>>{
    kDemoDinerOperatorId: List<RoleAdminRow>.of(dinerRoles),
    kDemoSunsetOperatorId: List<RoleAdminRow>.of(sunsetRoles),
  };
}

Map<String, List<OrgUnitAdminNode>> kDemoOrgUnitsByOperator() {
  return <String, List<OrgUnitAdminNode>>{
    kDemoDinerOperatorId: <OrgUnitAdminNode>[
      const OrgUnitAdminNode(
        orgUnitId: kDemoDinerOrgUnitRoot,
        name: 'Demo Diner Co.',
        operatorId: kDemoDinerOperatorId,
      ),
      const OrgUnitAdminNode(
        orgUnitId: kDemoDinerOrgUnitEast,
        name: 'East region',
        operatorId: kDemoDinerOperatorId,
        parentOrgUnitId: kDemoDinerOrgUnitRoot,
      ),
      const OrgUnitAdminNode(
        orgUnitId: kDemoDinerOrgUnitWest,
        name: 'West region',
        operatorId: kDemoDinerOperatorId,
        parentOrgUnitId: kDemoDinerOrgUnitRoot,
      ),
    ],
    kDemoSunsetOperatorId: <OrgUnitAdminNode>[
      const OrgUnitAdminNode(
        orgUnitId: kDemoSunsetOrgUnitRoot,
        name: 'Sunset Cafe Group',
        operatorId: kDemoSunsetOperatorId,
      ),
    ],
  };
}

Map<String, List<HierarchyLocationLeaf>> kDemoHierarchyLocationsByOperator() {
  return <String, List<HierarchyLocationLeaf>>{
    kDemoDinerOperatorId: <HierarchyLocationLeaf>[
      const HierarchyLocationLeaf(
        locationId: kDemoDinerLocationToronto,
        name: 'Toronto Yorkville',
        operatorId: kDemoDinerOperatorId,
        orgUnitId: kDemoDinerOrgUnitEast,
      ),
      const HierarchyLocationLeaf(
        locationId: kDemoDinerLocationVancouver,
        name: 'Vancouver Robson',
        operatorId: kDemoDinerOperatorId,
        orgUnitId: kDemoDinerOrgUnitWest,
      ),
    ],
    kDemoSunsetOperatorId: <HierarchyLocationLeaf>[
      const HierarchyLocationLeaf(
        locationId: kDemoSunsetLocationBrooklyn,
        name: 'Brooklyn Williamsburg',
        operatorId: kDemoSunsetOperatorId,
        orgUnitId: kDemoSunsetOrgUnitRoot,
      ),
    ],
  };
}

Map<String, List<SessionAdminRow>> kDemoSessionsByOperator({DateTime? at}) {
  final ts = at ?? DateTime.utc(2026, 5, 4, 12);
  return <String, List<SessionAdminRow>>{
    kDemoDinerOperatorId: <SessionAdminRow>[
      SessionAdminRow(
        sessionId: 'session-diner-owner-mobile',
        userId: 'demo-user-diner-owner',
        userDisplayName: 'Dana Owner',
        userEmail: 'owner@demo-diner.test',
        deviceFingerprint: 'iOS Safari on iPhone',
        ipGeoCity: 'Toronto, ON',
        lastActiveAt: ts.subtract(const Duration(minutes: 15)),
        createdAt: ts.subtract(const Duration(days: 12)),
      ),
      SessionAdminRow(
        sessionId: 'session-diner-owner-web',
        userId: 'demo-user-diner-owner',
        userDisplayName: 'Dana Owner',
        userEmail: 'owner@demo-diner.test',
        deviceFingerprint: 'Chrome on macOS',
        ipGeoCity: 'Toronto, ON',
        lastActiveAt: ts.subtract(const Duration(hours: 2)),
        createdAt: ts.subtract(const Duration(days: 3)),
      ),
      SessionAdminRow(
        sessionId: 'session-diner-manager-mobile',
        userId: 'demo-user-diner-manager',
        userDisplayName: 'Mira Manager',
        userEmail: 'manager@demo-diner.test',
        deviceFingerprint: 'Android Chrome on Pixel',
        ipGeoCity: 'Vancouver, BC',
        lastActiveAt: ts.subtract(const Duration(hours: 6)),
        createdAt: ts.subtract(const Duration(days: 5)),
      ),
    ],
    kDemoSunsetOperatorId: <SessionAdminRow>[
      SessionAdminRow(
        sessionId: 'session-sunset-owner-mobile',
        userId: 'demo-user-sunset-owner',
        userDisplayName: 'Quinn Owner',
        userEmail: 'owner@sunset-cafe.test',
        deviceFingerprint: 'iOS Safari on iPhone',
        ipGeoCity: 'Brooklyn, NY',
        lastActiveAt: ts.subtract(const Duration(minutes: 30)),
        createdAt: ts.subtract(const Duration(days: 8)),
      ),
    ],
  };
}
