// Phase 9.6 - Permission resolver + role management policy +
// permission cache tests.
//
// Pure logic; no DB / HTTP. Fixtures emulate the rows the proxy
// would load via OperatorScopedRepository.withTenant.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/permission_cache.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/auth/permission_resolution.dart';
import 'package:forge_and_flow/auth/role_management_policy.dart';
import 'package:forge_and_flow/services/team/team_scope_visibility_policy.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '22222222-2222-2222-2222-222222222222';
const String _locA = '33333333-3333-3333-3333-333333333333';
const String _locB = '44444444-4444-4444-4444-444444444444';
const String _userX = '55555555-5555-5555-5555-555555555555';
const String _userY = '66666666-6666-6666-6666-666666666666';
const String _roleStaff = 'role-staff';
const String _roleManager = 'role-manager';

UserRoleGrant grant({
  String userRoleId = 'ur-1',
  String userId = _userX,
  String roleId = _roleStaff,
  String operatorId = _opA,
  String? scopeType,
  String? locationId,
  String? orgUnitId,
  List<String> effectiveLocationIds = const <String>[],
  DateTime? validFrom,
  DateTime? validUntil,
  DateTime? revokedAt,
}) {
  return UserRoleGrant(
    userRoleId: userRoleId,
    userId: userId,
    roleId: roleId,
    operatorId: operatorId,
    scopeType: scopeType ?? (locationId == null ? 'operator_wide' : 'location'),
    locationId: locationId,
    orgUnitId: orgUnitId,
    effectiveLocationIds: effectiveLocationIds,
    validFrom: validFrom ?? DateTime.utc(2026, 4, 1),
    validUntil: validUntil,
    revokedAt: revokedAt,
  );
}

RolePermissionRule rule({
  String roleId = _roleStaff,
  required String permissionKey,
  PermissionEffect effect = PermissionEffect.allow,
}) {
  return RolePermissionRule(
    roleId: roleId,
    permissionKey: permissionKey,
    effect: effect,
  );
}

void main() {
  group('PermissionResolver.resolve', () {
    final now = DateTime.utc(2026, 4, 26, 12);

    test('default deny when the user has no active grants', () {
      final result = PermissionResolver.resolve(
        permissionKey: 'forgeflow.shift.view',
        grants: const <UserRoleGrant>[],
        rules: <RolePermissionRule>[
          rule(permissionKey: 'forgeflow.shift.view'),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
      );
      expect(result, equals(PermissionEffect.deny));
    });

    test('allow when one active grant has an allow rule', () {
      final result = PermissionResolver.resolve(
        permissionKey: 'forgeflow.shift.view',
        grants: <UserRoleGrant>[grant()],
        rules: <RolePermissionRule>[
          rule(permissionKey: 'forgeflow.shift.view'),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
      );
      expect(result, equals(PermissionEffect.allow));
    });

    test('deny wins over allow even when allow appears first in the list', () {
      final result = PermissionResolver.resolve(
        permissionKey: 'forgeflow.shift.view',
        grants: <UserRoleGrant>[
          grant(userRoleId: 'ur-allow', roleId: _roleStaff),
          grant(userRoleId: 'ur-deny', roleId: _roleManager),
        ],
        rules: <RolePermissionRule>[
          rule(roleId: _roleStaff, permissionKey: 'forgeflow.shift.view'),
          rule(
            roleId: _roleManager,
            permissionKey: 'forgeflow.shift.view',
            effect: PermissionEffect.deny,
          ),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
      );
      expect(result, equals(PermissionEffect.deny));
    });

    test('expired grant (validUntil < now) does NOT apply', () {
      final result = PermissionResolver.resolve(
        permissionKey: 'forgeflow.shift.view',
        grants: <UserRoleGrant>[
          grant(
            validFrom: DateTime.utc(2026, 4, 1),
            validUntil: DateTime.utc(2026, 4, 25),
          ),
        ],
        rules: <RolePermissionRule>[
          rule(permissionKey: 'forgeflow.shift.view'),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
      );
      expect(result, equals(PermissionEffect.deny));
    });

    test('not-yet-valid grant (validFrom > now) does NOT apply', () {
      final result = PermissionResolver.resolve(
        permissionKey: 'forgeflow.shift.view',
        grants: <UserRoleGrant>[grant(validFrom: DateTime.utc(2026, 5, 1))],
        rules: <RolePermissionRule>[
          rule(permissionKey: 'forgeflow.shift.view'),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
      );
      expect(result, equals(PermissionEffect.deny));
    });

    test('revoked grant (revokedAt <= now) does NOT apply', () {
      final result = PermissionResolver.resolve(
        permissionKey: 'forgeflow.shift.view',
        grants: <UserRoleGrant>[grant(revokedAt: DateTime.utc(2026, 4, 20))],
        rules: <RolePermissionRule>[
          rule(permissionKey: 'forgeflow.shift.view'),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
      );
      expect(result, equals(PermissionEffect.deny));
    });

    test('cross-tenant grant does NOT leak (filter by operatorId)', () {
      final result = PermissionResolver.resolve(
        permissionKey: 'forgeflow.shift.view',
        grants: <UserRoleGrant>[grant(operatorId: _opB)],
        rules: <RolePermissionRule>[
          rule(permissionKey: 'forgeflow.shift.view'),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
      );
      expect(result, equals(PermissionEffect.deny));
    });

    test('location-scoped grant denies when location does not match', () {
      final result = PermissionResolver.resolve(
        permissionKey: 'forgeflow.shift.view',
        grants: <UserRoleGrant>[grant(locationId: _locB)],
        rules: <RolePermissionRule>[
          rule(permissionKey: 'forgeflow.shift.view'),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
      );
      expect(result, equals(PermissionEffect.deny));
    });

    test('operator-wide grant (locationId == null) covers any location', () {
      final result = PermissionResolver.resolve(
        permissionKey: 'forgeflow.shift.view',
        grants: <UserRoleGrant>[grant(locationId: null)],
        rules: <RolePermissionRule>[
          rule(permissionKey: 'forgeflow.shift.view'),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
      );
      expect(result, equals(PermissionEffect.allow));
    });

    test('org-unit grant covers only materialized effective locations', () {
      final covered = PermissionResolver.resolve(
        permissionKey: 'forgeflow.shift.view',
        grants: <UserRoleGrant>[
          grant(
            scopeType: 'org_unit',
            orgUnitId: 'org-unit-1',
            effectiveLocationIds: const <String>[_locA],
          ),
        ],
        rules: <RolePermissionRule>[
          rule(permissionKey: 'forgeflow.shift.view'),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
      );
      final uncovered = PermissionResolver.resolve(
        permissionKey: 'forgeflow.shift.view',
        grants: <UserRoleGrant>[
          grant(
            scopeType: 'org_unit',
            orgUnitId: 'org-unit-1',
            effectiveLocationIds: const <String>[_locA],
          ),
        ],
        rules: <RolePermissionRule>[
          rule(permissionKey: 'forgeflow.shift.view'),
        ],
        operatorId: _opA,
        locationId: _locB,
        now: now,
      );

      expect(covered, equals(PermissionEffect.allow));
      expect(uncovered, equals(PermissionEffect.deny));
    });

    test('resolveAll returns the full per-key map for the active grants', () {
      final result = PermissionResolver.resolveAll(
        grants: <UserRoleGrant>[grant()],
        rules: <RolePermissionRule>[
          rule(permissionKey: 'forgeflow.shift.view'),
          rule(permissionKey: 'forgeflow.variance.view'),
          rule(
            permissionKey: 'forgeflow.shift.edit',
            effect: PermissionEffect.deny,
          ),
        ],
        operatorId: _opA,
        locationId: _locA,
        now: now,
      );
      expect(
        result,
        equals(<String, PermissionEffect>{
          'forgeflow.shift.view': PermissionEffect.allow,
          'forgeflow.variance.view': PermissionEffect.allow,
          'forgeflow.shift.edit': PermissionEffect.deny,
        }),
      );
    });
  });

  group('RoleManagementPolicy.evaluateRoleAction', () {
    ActorContext actor({
      Set<String> roles = const <String>{'super_admin'},
      String operatorId = _opA,
    }) {
      return ActorContext(
        actorUserId: _userX,
        actorOperatorId: operatorId,
        actorLocationId: _locA,
        actorRoles: roles,
        actorAssignedOperatorIds: const <String>{},
      );
    }

    TargetRole role({
      String operatorIdNullable = _opA,
      bool isSeeded = false,
      bool isEditable = true,
      bool global = false,
    }) {
      return TargetRole(
        roleId: 'role-x',
        roleKey: 'custom_role',
        operatorId: global ? null : operatorIdNullable,
        isSeeded: isSeeded,
        isEditable: isEditable,
      );
    }

    test('super_admin can edit anything (including locked seeded roles)', () {
      final decision = RoleManagementPolicy.evaluateRoleAction(
        actor: actor(),
        action: RoleManagementAction.editRole,
        role: role(isSeeded: true, isEditable: false, global: true),
      );
      expect(decision.allowed, isTrue);
    });

    test('non-super_admin cannot edit a seeded + locked role', () {
      final decision = RoleManagementPolicy.evaluateRoleAction(
        actor: actor(roles: const <String>{'operator_owner'}),
        action: RoleManagementAction.editRole,
        role: role(isSeeded: true, isEditable: false),
      );
      expect(decision.allowed, isFalse);
      expect(decision.reason, contains('seeded'));
    });

    test(
      'non-super_admin cannot touch a global (operator_id IS NULL) role',
      () {
        final decision = RoleManagementPolicy.evaluateRoleAction(
          actor: actor(roles: const <String>{'operator_owner'}),
          action: RoleManagementAction.editRole,
          role: role(global: true),
        );
        expect(decision.allowed, isFalse);
        expect(decision.reason, contains('global roles'));
      },
    );

    test('operator_owner can edit operator-scoped custom role within own '
        'operator', () {
      final decision = RoleManagementPolicy.evaluateRoleAction(
        actor: actor(roles: const <String>{'operator_owner'}),
        action: RoleManagementAction.editRole,
        role: role(operatorIdNullable: _opA),
      );
      expect(decision.allowed, isTrue);
    });

    test('operator_owner cannot edit a role belonging to another operator', () {
      final decision = RoleManagementPolicy.evaluateRoleAction(
        actor: actor(roles: const <String>{'operator_owner'}),
        action: RoleManagementAction.editRole,
        role: role(operatorIdNullable: _opB),
      );
      expect(decision.allowed, isFalse);
      expect(decision.reason, contains('another operator'));
    });

    test('operator_owner can create + delete operator-scoped roles', () {
      for (final action in const <RoleManagementAction>[
        RoleManagementAction.createRole,
        RoleManagementAction.deleteRole,
      ]) {
        final decision = RoleManagementPolicy.evaluateRoleAction(
          actor: actor(roles: const <String>{'operator_owner'}),
          action: action,
          role: role(),
        );
        expect(decision.allowed, isTrue, reason: 'action $action');
      }
    });
  });

  group('RoleManagementPolicy.evaluateGrantAction', () {
    ActorContext actor({
      Set<String> roles = const <String>{},
      String operatorId = _opA,
      String locationId = _locA,
      Set<String> assigned = const <String>{},
    }) {
      return ActorContext(
        actorUserId: _userX,
        actorOperatorId: operatorId,
        actorLocationId: locationId,
        actorRoles: roles,
        actorAssignedOperatorIds: assigned,
      );
    }

    TargetGrant grantTarget({
      String operatorId = _opA,
      String? locationId = _locA,
      String roleKey = 'operator_staff',
    }) {
      return TargetGrant(
        targetUserId: _userY,
        targetOperatorId: operatorId,
        targetLocationId: locationId,
        targetRoleKey: roleKey,
      );
    }

    test('super_admin can grant anything', () {
      final decision = RoleManagementPolicy.evaluateGrantAction(
        actor: actor(roles: const <String>{'super_admin'}),
        action: RoleManagementAction.grantRole,
        grant: grantTarget(roleKey: 'super_admin'),
      );
      expect(decision.allowed, isTrue);
    });

    test('ff_support without scope is denied', () {
      final decision = RoleManagementPolicy.evaluateGrantAction(
        actor: actor(roles: const <String>{'ff_support'}),
        action: RoleManagementAction.grantRole,
        grant: grantTarget(),
      );
      expect(decision.allowed, isFalse);
      expect(decision.reason, contains('scope on the target operator'));
    });

    test('ff_support with assigned operator is allowed', () {
      final decision = RoleManagementPolicy.evaluateGrantAction(
        actor: actor(
          roles: const <String>{'ff_support'},
          assigned: const <String>{_opA},
        ),
        action: RoleManagementAction.grantRole,
        grant: grantTarget(operatorId: _opA),
      );
      expect(decision.allowed, isTrue);
    });

    test('operator_owner cannot manage grants for another operator', () {
      final decision = RoleManagementPolicy.evaluateGrantAction(
        actor: actor(roles: const <String>{'operator_owner'}),
        action: RoleManagementAction.grantRole,
        grant: grantTarget(operatorId: _opB),
      );
      expect(decision.allowed, isFalse);
    });

    test('operator_general_manager grants active non-platform roles', () {
      final actorCtx = actor(roles: const <String>{'operator_general_manager'});
      for (final role in const <String>[
        'location_manager',
        'supervisor',
        'team_admin',
      ]) {
        expect(
          RoleManagementPolicy.evaluateGrantAction(
            actor: actorCtx,
            action: RoleManagementAction.grantRole,
            grant: grantTarget(roleKey: role),
          ).allowed,
          isTrue,
          reason: role,
        );
      }
      for (final role in const <String>[
        'operator_owner',
        'super_admin',
        'ff_support',
        'operator_manager',
      ]) {
        expect(
          RoleManagementPolicy.evaluateGrantAction(
            actor: actorCtx,
            action: RoleManagementAction.grantRole,
            grant: grantTarget(roleKey: role),
          ).allowed,
          isFalse,
          reason: role,
        );
      }
    });

    test('location_manager can grant supervisor at own location only', () {
      final actorCtx = actor(roles: const <String>{'location_manager'});
      expect(
        RoleManagementPolicy.evaluateGrantAction(
          actor: actorCtx,
          action: RoleManagementAction.grantRole,
          grant: grantTarget(roleKey: 'supervisor'),
        ).allowed,
        isTrue,
      );
      for (final role in const <String>['location_manager', 'team_admin']) {
        expect(
          RoleManagementPolicy.evaluateGrantAction(
            actor: actorCtx,
            action: RoleManagementAction.grantRole,
            grant: grantTarget(roleKey: role),
          ).allowed,
          isFalse,
          reason: role,
        );
      }
    });

    test('retired operator_manager has no grant privilege', () {
      final actorCtx = actor(roles: const <String>{'operator_manager'});
      for (final role in const <String>['supervisor', 'location_manager']) {
        expect(
          RoleManagementPolicy.evaluateGrantAction(
            actor: actorCtx,
            action: RoleManagementAction.grantRole,
            grant: grantTarget(roleKey: role),
          ).allowed,
          isFalse,
          reason: role,
        );
      }
    });

    test('location_manager refused if target location differs', () {
      final decision = RoleManagementPolicy.evaluateGrantAction(
        actor: actor(roles: const <String>{'location_manager'}),
        action: RoleManagementAction.grantRole,
        grant: grantTarget(locationId: _locB, roleKey: 'supervisor'),
      );
      expect(decision.allowed, isFalse);
      expect(decision.reason, contains('outside own location'));
    });

    test('operator_staff has no grant privilege', () {
      final decision = RoleManagementPolicy.evaluateGrantAction(
        actor: actor(roles: const <String>{'operator_staff'}),
        action: RoleManagementAction.grantRole,
        grant: grantTarget(),
      );
      expect(decision.allowed, isFalse);
    });

    test('non-grant actions on this entry point are denied', () {
      final decision = RoleManagementPolicy.evaluateGrantAction(
        actor: actor(roles: const <String>{'super_admin'}),
        action: RoleManagementAction.editRole,
        grant: grantTarget(),
      );
      expect(decision.allowed, isFalse);
    });
  });

  group('TeamScopeVisibilityPolicy v2 role gates', () {
    TeamScopeActor actor({
      required Set<String> roles,
      Set<String> assignedLocations = const <String>{},
      Set<String> permissions = const <String>{'team.users.view'},
    }) {
      return TeamScopeActor(
        actorRoles: roles,
        actorOperatorId: _opA,
        actorAssignedLocationIds: assignedLocations,
        actorPermissions: permissions,
      );
    }

    const operatorWideTarget = TeamScopeTarget(targetOperatorId: _opA);
    const locationTarget = TeamScopeTarget(
      targetOperatorId: _opA,
      targetLocationId: _locA,
    );

    test('operator_general_manager has business-scope Team access', () {
      final actorCtx = actor(roles: const <String>{'operator_general_manager'});

      expect(TeamScopeVisibilityPolicy.canSeeTeamNav(actorCtx), isTrue);
      expect(
        TeamScopeVisibilityPolicy.canViewTarget(
          actor: actorCtx,
          target: operatorWideTarget,
        ),
        isTrue,
      );
      expect(
        TeamScopeVisibilityPolicy.canMutateTarget(
          actor: actor(
            roles: const <String>{'operator_general_manager'},
            permissions: const <String>{'team.users.deactivate'},
          ),
          target: locationTarget,
          requiredPermissionKey: 'team.users.deactivate',
        ),
        isTrue,
      );
    });

    test('retired operator_manager is not treated as current GM', () {
      final actorCtx = actor(
        roles: const <String>{'operator_manager'},
        assignedLocations: const <String>{_locA},
      );

      expect(TeamScopeVisibilityPolicy.canSeeTeamNav(actorCtx), isFalse);
      expect(
        TeamScopeVisibilityPolicy.canViewTarget(
          actor: actorCtx,
          target: locationTarget,
        ),
        isFalse,
      );
      expect(
        TeamScopeVisibilityPolicy.canMutateTarget(
          actor: actor(
            roles: const <String>{'operator_manager'},
            assignedLocations: const <String>{_locA},
            permissions: const <String>{'team.users.deactivate'},
          ),
          target: locationTarget,
          requiredPermissionKey: 'team.users.deactivate',
        ),
        isFalse,
      );
    });

    test('location_manager keeps the assigned-location gate', () {
      final actorCtx = actor(
        roles: const <String>{'location_manager'},
        assignedLocations: const <String>{_locA},
      );

      expect(TeamScopeVisibilityPolicy.canSeeTeamNav(actorCtx), isTrue);
      expect(
        TeamScopeVisibilityPolicy.canViewTarget(
          actor: actorCtx,
          target: locationTarget,
        ),
        isTrue,
      );
      expect(
        TeamScopeVisibilityPolicy.canViewTarget(
          actor: actorCtx,
          target: operatorWideTarget,
        ),
        isFalse,
      );
    });
  });

  group('PermissionCache (LRU + roles_version invalidation)', () {
    PermissionSnapshot makeSnapshot({
      String userId = _userX,
      int rolesVersion = 1,
      String operatorId = _opA,
      String locationId = _locA,
      DateTime? at,
      Map<String, PermissionEffect>? entries,
    }) {
      return PermissionSnapshot(
        userId: userId,
        rolesVersion: rolesVersion,
        operatorId: operatorId,
        locationId: locationId,
        evaluatedAt: at ?? DateTime.utc(2026, 4, 26, 12),
        entries:
            entries ??
            <String, PermissionEffect>{
              'forgeflow.shift.view': PermissionEffect.allow,
            },
      );
    }

    test('first read is a miss; subsequent same-key read is a hit', () {
      final cache = PermissionCache(
        ttl: const Duration(seconds: 60),
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      expect(
        cache.read(
          userId: _userX,
          rolesVersion: 1,
          operatorId: _opA,
          locationId: _locA,
        ),
        isNull,
      );
      expect(cache.missCount, equals(1));

      cache.put(makeSnapshot());
      final hit = cache.read(
        userId: _userX,
        rolesVersion: 1,
        operatorId: _opA,
        locationId: _locA,
      );
      expect(hit, isNotNull);
      expect(cache.hitCount, equals(1));
    });

    test('roles_version bump misses on the same userId', () {
      final cache = PermissionCache(
        ttl: const Duration(seconds: 60),
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      cache.put(makeSnapshot(rolesVersion: 1));
      expect(
        cache.read(
          userId: _userX,
          rolesVersion: 2,
          operatorId: _opA,
          locationId: _locA,
        ),
        isNull,
      );
      expect(cache.missCount, equals(1));
    });

    test('cross-tenant key collision is impossible — different opId is a '
        'separate cache key', () {
      final cache = PermissionCache(
        ttl: const Duration(seconds: 60),
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      cache.put(makeSnapshot(operatorId: _opA));
      expect(
        cache.read(
          userId: _userX,
          rolesVersion: 1,
          operatorId: _opB,
          locationId: _locA,
        ),
        isNull,
      );
    });

    test('TTL expiry treats stale entry as a miss', () {
      var clock = DateTime.utc(2026, 4, 26, 12);
      final cache = PermissionCache(
        ttl: const Duration(seconds: 60),
        now: () => clock,
      );
      cache.put(makeSnapshot(at: clock));
      clock = clock.add(const Duration(seconds: 61));
      expect(
        cache.read(
          userId: _userX,
          rolesVersion: 1,
          operatorId: _opA,
          locationId: _locA,
        ),
        isNull,
      );
      expect(cache.missCount, equals(1));
    });

    test('LRU evicts oldest entry on overflow', () {
      final cache = PermissionCache(
        maxEntries: 2,
        ttl: const Duration(minutes: 10),
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      cache.put(makeSnapshot(userId: 'u-1'));
      cache.put(makeSnapshot(userId: 'u-2'));
      // Touching u-1 promotes it to MRU.
      cache.read(
        userId: 'u-1',
        rolesVersion: 1,
        operatorId: _opA,
        locationId: _locA,
      );
      cache.put(makeSnapshot(userId: 'u-3'));

      // u-2 was the LRU, should be evicted.
      expect(
        cache.read(
          userId: 'u-2',
          rolesVersion: 1,
          operatorId: _opA,
          locationId: _locA,
        ),
        isNull,
      );
      // u-1 + u-3 still resident.
      expect(
        cache.read(
          userId: 'u-1',
          rolesVersion: 1,
          operatorId: _opA,
          locationId: _locA,
        ),
        isNotNull,
      );
      expect(
        cache.read(
          userId: 'u-3',
          rolesVersion: 1,
          operatorId: _opA,
          locationId: _locA,
        ),
        isNotNull,
      );
      expect(cache.evictionCount, equals(1));
    });

    test('invalidateUser drops every snapshot for that user', () {
      final cache = PermissionCache(
        ttl: const Duration(minutes: 10),
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      cache.put(makeSnapshot(userId: 'u-1'));
      cache.put(makeSnapshot(userId: 'u-2'));
      cache.invalidateUser('u-1');
      expect(
        cache.read(
          userId: 'u-1',
          rolesVersion: 1,
          operatorId: _opA,
          locationId: _locA,
        ),
        isNull,
      );
      expect(
        cache.read(
          userId: 'u-2',
          rolesVersion: 1,
          operatorId: _opA,
          locationId: _locA,
        ),
        isNotNull,
      );
    });

    test('snapshot.effectFor returns deny for unmapped keys', () {
      final snap = makeSnapshot(
        entries: <String, PermissionEffect>{
          'forgeflow.shift.view': PermissionEffect.allow,
        },
      );
      expect(
        snap.effectFor('forgeflow.shift.view'),
        equals(PermissionEffect.allow),
      );
      expect(
        snap.effectFor('admin.users.erase_pii'),
        equals(PermissionEffect.deny),
      );
    });
  });
}
