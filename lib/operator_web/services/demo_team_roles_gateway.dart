// Phase 11W.2 - Operator Web team-roles demo gateway.
//
// In-memory implementation of [WebTeamRolesGateway] that the operator-
// web shell binds when `OPERATOR_WEB_DEMO_AUTH=true`. Reads from the
// shared fixture set declared in [demo_team_fixtures.dart] so the
// demo walkthroughs across `/members`, `/roles`, `/locations`,
// `/sessions`, `/audit-log`, `/security` see consistent data.
//
// Mutations made during a walkthrough (create custom role, patch,
// delete, assign / revoke grant) are stored on this instance only -
// page reload resets to the fixture defaults. Idempotency replays the
// original outcome so the demo behaviour matches the proxy's
// `proxy_requests` UNIQUE-key replay semantics.

import 'dart:async';

import '../../services/auth/auth_operations_gateway.dart';
import 'demo_team_fixtures.dart';
import 'web_team_roles_gateway.dart';

/// In-memory demo gateway for the Roles + Permission Explainer +
/// custom-role builder surface.
class DemoWebTeamRolesGateway implements WebTeamRolesGateway {
  DemoWebTeamRolesGateway() {
    for (final fixture in kDemoTeamRolesFixture) {
      _roles[fixture.roleId] = teamRoleEntryFromFixture(fixture);
    }
    for (final grant in kDemoTeamRoleGrantsFixture) {
      _grants[grant.userRoleId] = grant;
    }
  }

  final Map<String, TeamRoleCatalogEntry> _roles =
      <String, TeamRoleCatalogEntry>{};

  /// Mutable copy of the seeded role-grants. The Roles screen + member
  /// row mutations (assign / revoke) update this map; the Members
  /// gateway exposes `listUsers()` against its own copy so the two
  /// demo gateways can stay independent without cross-coupling.
  final Map<String, DemoTeamRoleGrantFixture> _grants =
      <String, DemoTeamRoleGrantFixture>{};

  /// Cached responses keyed by the screen-minted idempotency key.
  final Map<String, _CachedRoleMutation> _idempotency =
      <String, _CachedRoleMutation>{};

  int _nextRoleSeq = 200;
  int _nextGrantSeq = 200;

  @override
  Future<TeamRoleCatalogListed> listRoles(
    TeamRoleCatalogListCommand command,
  ) async {
    final entries = _roles.values.toList(growable: false);
    final scope = command.scope?.trim().toLowerCase();
    final filtered = entries.where((role) {
      switch (scope) {
        case null:
        case '':
        case 'all':
          return true;
        case 'global':
        case 'seeded':
          return role.isSeeded;
        case 'operator':
        case 'custom':
          return !role.isSeeded;
        default:
          return true;
      }
    }).toList();
    filtered.sort((a, b) {
      if (a.isSeeded != b.isSeeded) return a.isSeeded ? 1 : -1;
      return a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          );
    });
    return TeamRoleCatalogListed(
      roles: List<TeamRoleCatalogEntry>.unmodifiable(filtered),
    );
  }

  @override
  Future<TeamRoleCreated> createRole(
    TeamRoleCreateCommand command, {
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is _CachedRoleCreate) return cached.created;
    final roleId = 'demo-role-seq-${_nextRoleSeq++}';
    final entry = TeamRoleCatalogEntry(
      roleId: roleId,
      roleKey: command.roleKey,
      displayName: command.displayName,
      description: command.description,
      isSeeded: false,
      isEditable: true,
      operatorId: command.operatorId,
      permissions: List<TeamRolePermissionRule>.unmodifiable(
        command.permissions
            .where((update) => update.effect == 'allow' || update.effect == 'deny')
            .map(
              (update) => TeamRolePermissionRule(
                permissionKey: update.permissionKey,
                effect: update.effect!,
              ),
            ),
      ),
    );
    _roles[roleId] = entry;
    final created = TeamRoleCreated(role: entry);
    _idempotency[idempotencyKey] = _CachedRoleCreate(created);
    return created;
  }

  @override
  Future<TeamRolePatched> patchRole(
    TeamRolePatchCommand command, {
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is _CachedRolePatch) return cached.patched;
    final existing = _roles[command.roleId];
    if (existing == null || existing.isSeeded || !existing.isEditable) {
      // Mirrors the proxy's seeded-edit guard so the demo screen sees
      // the same friendly failure as live.
      throw const WebTeamRolesError(
        code: 'role_not_editable',
        message: 'Seeded roles cannot be edited from the operator self-service '
            'surface.',
        statusCode: 403,
      );
    }
    final mergedPermissions = _mergePermissions(
      existing.permissions,
      command.permissions,
    );
    final updated = TeamRoleCatalogEntry(
      roleId: existing.roleId,
      roleKey: existing.roleKey,
      displayName: command.displayName?.trim().isNotEmpty == true
          ? command.displayName!.trim()
          : existing.displayName,
      description: command.description ?? existing.description,
      isSeeded: existing.isSeeded,
      isEditable: existing.isEditable,
      operatorId: existing.operatorId,
      permissions: mergedPermissions,
    );
    _roles[updated.roleId] = updated;
    final bumpedUsers = _grants.values
        .where((grant) => grant.roleId == updated.roleId)
        .length;
    final patched = TeamRolePatched(role: updated, bumpedUsers: bumpedUsers);
    _idempotency[idempotencyKey] = _CachedRolePatch(patched);
    return patched;
  }

  @override
  Future<TeamRoleDeleted> deleteRole(
    TeamRoleDeleteCommand command, {
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is _CachedRoleDelete) return cached.deleted;
    final existing = _roles[command.roleId];
    if (existing == null) {
      const result = TeamRoleDeleted(deleted: false);
      _idempotency[idempotencyKey] = const _CachedRoleDelete(result);
      return result;
    }
    if (existing.isSeeded || !existing.isEditable) {
      throw const WebTeamRolesError(
        code: 'role_not_editable',
        message:
            'Seeded roles cannot be deleted from the operator self-service '
            'surface.',
        statusCode: 403,
      );
    }
    if (_grants.values.any((grant) => grant.roleId == command.roleId)) {
      throw const WebTeamRolesError(
        code: 'role_has_active_grants',
        message:
            'Revoke this role from every member before deleting it.',
        statusCode: 409,
      );
    }
    _roles.remove(command.roleId);
    const result = TeamRoleDeleted(deleted: true);
    _idempotency[idempotencyKey] = const _CachedRoleDelete(result);
    return result;
  }

  @override
  Future<TeamRoleGrantCreated> createRoleGrant(
    TeamRoleGrantCreateCommand command, {
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is _CachedGrantCreate) return cached.created;
    final userRoleId = 'demo-grant-seq-${_nextGrantSeq++}';
    _grants[userRoleId] = DemoTeamRoleGrantFixture(
      userRoleId: userRoleId,
      userId: command.targetUserId,
      roleId: command.roleId,
      scopeType: command.scopeType,
      locationId: command.targetLocationId,
      orgUnitId: command.targetOrgUnitId,
    );
    final created = TeamRoleGrantCreated(userRoleId: userRoleId);
    _idempotency[idempotencyKey] = _CachedGrantCreate(created);
    return created;
  }

  @override
  Future<TeamRoleGrantRevoked> revokeRoleGrant(
    TeamRoleGrantRevokeCommand command, {
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is _CachedGrantRevoke) return cached.revoked;
    final removed = _grants.remove(command.userRoleId);
    final result = TeamRoleGrantRevoked(revoked: removed != null);
    _idempotency[idempotencyKey] = _CachedGrantRevoke(result);
    return result;
  }

  /// Read-only snapshot of the current grant ledger, projected into
  /// [TeamGrantSnapshot]. Screens use this to render which members
  /// hold a given role without dragging in the Members gateway.
  List<TeamGrantSnapshot> grantsForRole(String roleId) {
    return _grants.values
        .where((grant) => grant.roleId == roleId)
        .map(
          (grant) => teamGrantSnapshotFromFixture(
            grant,
            roleLabel: _roles[grant.roleId]?.displayName,
          ),
        )
        .toList(growable: false);
  }

  List<TeamRolePermissionRule> _mergePermissions(
    List<TeamRolePermissionRule> existing,
    List<TeamRolePermissionUpdate> updates,
  ) {
    final byKey = <String, TeamRolePermissionRule>{
      for (final rule in existing) rule.permissionKey: rule,
    };
    for (final update in updates) {
      final effect = update.effect;
      if (effect == null || effect == 'inherit') {
        byKey.remove(update.permissionKey);
      } else if (effect == 'allow' || effect == 'deny') {
        byKey[update.permissionKey] = TeamRolePermissionRule(
          permissionKey: update.permissionKey,
          effect: effect,
        );
      }
    }
    final merged = byKey.values.toList(growable: false);
    merged.sort((a, b) => a.permissionKey.compareTo(b.permissionKey));
    return List<TeamRolePermissionRule>.unmodifiable(merged);
  }
}

abstract class _CachedRoleMutation {
  const _CachedRoleMutation();
}

class _CachedRoleCreate extends _CachedRoleMutation {
  const _CachedRoleCreate(this.created);
  final TeamRoleCreated created;
}

class _CachedRolePatch extends _CachedRoleMutation {
  const _CachedRolePatch(this.patched);
  final TeamRolePatched patched;
}

class _CachedRoleDelete extends _CachedRoleMutation {
  const _CachedRoleDelete(this.deleted);
  final TeamRoleDeleted deleted;
}

class _CachedGrantCreate extends _CachedRoleMutation {
  const _CachedGrantCreate(this.created);
  final TeamRoleGrantCreated created;
}

class _CachedGrantRevoke extends _CachedRoleMutation {
  const _CachedGrantRevoke(this.revoked);
  final TeamRoleGrantRevoked revoked;
}
