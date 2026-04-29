// Phase 9 live-closeout B17 - UserRolesRepository.
//
// Reads + writes the `user_roles` table (the grant + scope +
// time-bound rows the resolver consumes). Every mutation also bumps
// `users.roles_version` for the affected user so the proxy's
// permission cache (Phase 9.6) invalidates correctly.
//
// `granted_by` and `revoked_by` hold the actor's user_id. The proxy
// resolves the actor from the verified JWT before invoking these
// methods; the repo trusts the caller.
//
// Audit-fix 2026-04-27: every grant carries an explicit
// [UserRoleScope]. The 9.0a migration made `user_roles.scope_type`
// NOT NULL, so an INSERT without it would now fail. Making the
// parameter required (rather than optional/derived) means typos and
// missed call sites break loudly at compile time, and tests can
// assert the value flows into the SQL parameter map.

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

/// Locked 9.0a CHECK constraint values for `user_roles.scope_type`.
///
/// `operatorWide` ↔ `'operator_wide'`: grant applies to every
/// location for the operator. `location_id` MUST be null.
///
/// `location` ↔ `'location'`: grant is scoped to a single location.
/// `location_id` MUST be non-null.
enum UserRoleScope {
  operatorWide,
  location;

  /// SQL value matching the 9.0a CHECK constraint
  /// (`scope_type in ('operator_wide', 'location')`).
  String get sqlKey {
    switch (this) {
      case UserRoleScope.operatorWide:
        return 'operator_wide';
      case UserRoleScope.location:
        return 'location';
    }
  }

  /// Convenience: derives the scope from a (nullable) [grantLocationId].
  /// Useful at call sites that mirror the legacy "null = operator-wide"
  /// convention; the explicit enum still has to be passed to
  /// [UserRolesRepository.insertGrant] so the SQL binding is
  /// auditable in tests.
  static UserRoleScope fromGrantLocationId(String? grantLocationId) {
    if (grantLocationId == null || grantLocationId.isEmpty) {
      return UserRoleScope.operatorWide;
    }
    return UserRoleScope.location;
  }
}

class UserRoleGrantRow {
  const UserRoleGrantRow({
    required this.userRoleId,
    required this.userId,
    required this.roleId,
    required this.operatorId,
    required this.validFrom,
    required this.grantedBy,
    required this.createdAt,
    required this.updatedAt,
    this.locationId,
    this.validUntil,
    this.revokedAt,
    this.revokedBy,
    this.reason,
  });

  final String userRoleId;
  final String userId;
  final String roleId;
  final String operatorId;
  final String? locationId;
  final DateTime validFrom;
  final DateTime? validUntil;
  final String grantedBy;
  final DateTime? revokedAt;
  final String? revokedBy;
  final String? reason;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class UserRolesRepository extends OperatorScopedRepository {
  UserRolesRepository(super.tenantWrapper);

  /// SELECT every active grant for [targetUserId]. "Active" =
  /// `revoked_at IS NULL` AND `valid_until` is NULL or in the future.
  /// The resolver layer (Phase 9.6) consumes this.
  Future<List<UserRoleGrantRow>> activeGrantsForUser({
    required String operatorId,
    required String locationId,
    required String targetUserId,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<List<UserRoleGrantRow>>(ctx, (exec) async {
      final rows = await exec.query(
        '${_selectColumns}from user_roles '
        'where user_id = @user_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and revoked_at is null '
        'and (valid_until is null or valid_until > now()) '
        'and valid_from <= now() '
        'order by valid_from',
        parameters: <String, Object?>{
          'user_id': targetUserId,
          'operator_id': operatorId,
        },
      );
      return rows.map(_projectRow).toList(growable: false);
    });
  }

  /// INSERT a new grant + bump `users.roles_version` atomically.
  /// Returns the new `user_role_id`.
  ///
  /// [scopeType] is REQUIRED to keep the call site honest about what
  /// kind of grant is being written. `UserRoleScope.location` requires
  /// a non-null [grantLocationId]; `UserRoleScope.operatorWide`
  /// requires a null [grantLocationId]. Mismatches throw
  /// [ArgumentError] before any SQL runs so the test layer catches
  /// typos rather than the database returning a CHECK / FK violation
  /// at runtime.
  Future<String> insertGrant({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String targetUserId,
    required String roleId,
    required UserRoleScope scopeType,
    String? grantLocationId,
    DateTime? validFrom,
    DateTime? validUntil,
    String? reason,
  }) {
    // Validate scope ↔ location_id consistency before opening a
    // transaction. Catches typos at the call site and avoids relying
    // on the 9.0a CHECK constraint to reject the row mid-transaction.
    switch (scopeType) {
      case UserRoleScope.location:
        if (grantLocationId == null || grantLocationId.isEmpty) {
          throw ArgumentError.value(
            grantLocationId,
            'grantLocationId',
            'scopeType=location requires a non-null grantLocationId',
          );
        }
      case UserRoleScope.operatorWide:
        if (grantLocationId != null && grantLocationId.isNotEmpty) {
          throw ArgumentError.value(
            grantLocationId,
            'grantLocationId',
            'scopeType=operator_wide requires grantLocationId to be null',
          );
        }
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into user_roles ('
        'user_id, role_id, operator_id, location_id, scope_type, '
        'valid_from, valid_until, granted_by, reason) '
        'values (@user_id::uuid, @role_id::uuid, @operator_id::uuid, '
        '@location_id::uuid, @scope_type, @valid_from, @valid_until, '
        '@actor::uuid, @reason) '
        'returning user_role_id::text as user_role_id',
        parameters: <String, Object?>{
          'user_id': targetUserId,
          'role_id': roleId,
          'operator_id': operatorId,
          'location_id': grantLocationId,
          'scope_type': scopeType.sqlKey,
          'valid_from': validFrom ?? DateTime.now().toUtc(),
          'valid_until': validUntil,
          'actor': actorUserId,
          'reason': reason,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'user_roles insert returned no rows — RLS may have blocked',
        );
      }
      final id = rows.single['user_role_id'];
      if (id is! String || id.isEmpty) {
        throw StateError('user_roles insert returned a malformed user_role_id');
      }
      // Bump roles_version atomically inside the same transaction so
      // the proxy's permission cache invalidates exactly when the
      // grant lands.
      await exec.execute(
        'update users '
        'set roles_version = roles_version + 1 '
        'where user_id = @user_id::uuid',
        parameters: <String, Object?>{'user_id': targetUserId},
      );
      return id;
    });
  }

  /// Revoke a grant + bump `users.roles_version` atomically.
  Future<int> revokeGrant({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String userRoleId,
    required String targetUserId,
    String? reason,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<int>(ctx, (exec) async {
      final affected = await exec.execute(
        'update user_roles '
        'set revoked_at = now(), revoked_by = @actor::uuid, '
        'reason = @reason, updated_at = now() '
        'where user_role_id = @user_role_id::uuid '
        'and revoked_at is null',
        parameters: <String, Object?>{
          'user_role_id': userRoleId,
          'actor': actorUserId,
          'reason': reason,
        },
      );
      if (affected > 0) {
        await exec.execute(
          'update users '
          'set roles_version = roles_version + 1 '
          'where user_id = @user_id::uuid',
          parameters: <String, Object?>{'user_id': targetUserId},
        );
      }
      return affected;
    });
  }

  /// Bump every active holder of [roleId]. Used when an operator-scoped custom
  /// role's permission bundle changes, so subsequent permission resolution sees
  /// the new role definition as a real roles-version change.
  Future<int> bumpActiveGrantHoldersForRole({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String roleId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<int>(ctx, (exec) async {
      return exec.execute(
        'update users '
        'set roles_version = roles_version + 1, updated_at = now() '
        'where operator_id = @operator_id::uuid '
        'and exists ('
        '  select 1 from user_roles '
        '  where user_roles.user_id = users.user_id '
        '  and user_roles.operator_id = @operator_id::uuid '
        '  and user_roles.role_id = @role_id::uuid '
        '  and user_roles.revoked_at is null '
        '  and (user_roles.valid_until is null or user_roles.valid_until > now()) '
        '  and user_roles.valid_from <= now()'
        ')',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'role_id': roleId,
        },
      );
    });
  }

  static const String _selectColumns =
      'select user_role_id::text as user_role_id, '
      'user_id::text as user_id, '
      'role_id::text as role_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'valid_from, valid_until, '
      'granted_by::text as granted_by, '
      'revoked_at, revoked_by::text as revoked_by, '
      'reason, created_at, updated_at ';

  static UserRoleGrantRow _projectRow(Map<String, Object?> row) {
    return UserRoleGrantRow(
      userRoleId: row['user_role_id'] as String,
      userId: row['user_id'] as String,
      roleId: row['role_id'] as String,
      operatorId: row['operator_id'] as String,
      locationId: row['location_id'] as String?,
      validFrom: row['valid_from'] as DateTime,
      validUntil: row['valid_until'] as DateTime?,
      grantedBy: row['granted_by'] as String,
      revokedAt: row['revoked_at'] as DateTime?,
      revokedBy: row['revoked_by'] as String?,
      reason: row['reason'] as String?,
      createdAt: row['created_at'] as DateTime,
      updatedAt: row['updated_at'] as DateTime,
    );
  }
}
