// Phase 9.6 - Permission resolution kernel.
//
// Implements the algorithm from `phase_9_auth_plan.md` 9.6:
//
//   for each user_roles row WHERE user_id = X
//     AND now() BETWEEN valid_from AND COALESCE(valid_until, 'infinity')
//     AND revoked_at IS NULL:
//     join role_permissions
//     collect (permission_key, effect) tuples
//   if any (permission_key, 'deny') exists for permission_key, effect = deny
//   else if any (permission_key, 'allow') exists, effect = allow
//   else effect = deny (default)
//
// Pure logic — no DB, no HTTP. The proxy is responsible for loading
// the grants + bundle definitions inside an
// `OperatorScopedRepository.withTenant` block (Phase 9.2) and feeding
// them to [PermissionResolver]. Tests construct the input maps
// directly.
//
// Location-scoped grants apply only when the requested
// `location_id` matches the grant's `location_id` (or the grant has
// no location scope, meaning operator-wide). Phase 9.7 wires this
// into the runtime gates.

import 'permission_effect.dart';

/// One row from `role_permissions` (Phase 9.0 schema). Defines
/// whether a given role grants or denies a given permission key.
class RolePermissionRule {
  const RolePermissionRule({
    required this.roleId,
    required this.permissionKey,
    required this.effect,
  });

  final String roleId;
  final String permissionKey;
  final PermissionEffect effect;
}

/// One row from `user_roles` (Phase 9.0 schema), in the shape the
/// resolver needs. Optional [locationId] makes the grant
/// location-scoped; null means operator-wide.
class UserRoleGrant {
  const UserRoleGrant({
    required this.userRoleId,
    required this.userId,
    required this.roleId,
    required this.operatorId,
    required this.validFrom,
    this.locationId,
    this.validUntil,
    this.revokedAt,
  });

  final String userRoleId;
  final String userId;
  final String roleId;
  final String operatorId;
  final String? locationId;
  final DateTime validFrom;
  final DateTime? validUntil;
  final DateTime? revokedAt;

  /// True iff the grant is "live" at [now]: not revoked, after
  /// [validFrom], and (when set) before [validUntil].
  bool isActiveAt(DateTime now) {
    if (revokedAt != null && !now.isBefore(revokedAt!)) {
      return false;
    }
    if (now.isBefore(validFrom)) return false;
    final until = validUntil;
    if (until != null && !now.isBefore(until)) return false;
    return true;
  }

  /// True iff this grant covers [requestedLocationId]. Null grant
  /// `locationId` means operator-wide (covers any location).
  bool coversLocation(String requestedLocationId) {
    final scope = locationId;
    if (scope == null) return true;
    return scope == requestedLocationId;
  }
}

class PermissionResolver {
  PermissionResolver._();

  /// Returns the resolved [PermissionEffect] for [permissionKey] given
  /// the user's [grants] + per-role [rules]. Filters grants by:
  ///
  ///   - tenant ([operatorId] must match)
  ///   - active-at-now (`now()` between valid_from and valid_until,
  ///     not revoked)
  ///   - location scope ([locationId] must match the grant's
  ///     `location_id` or the grant must be operator-wide)
  ///
  /// Then applies the deny-wins / default-deny semantics.
  static PermissionEffect resolve({
    required String permissionKey,
    required Iterable<UserRoleGrant> grants,
    required Iterable<RolePermissionRule> rules,
    required String operatorId,
    required String locationId,
    required DateTime now,
  }) {
    final activeRoleIds = <String>{};
    for (final grant in grants) {
      if (grant.operatorId != operatorId) continue;
      if (!grant.isActiveAt(now)) continue;
      if (!grant.coversLocation(locationId)) continue;
      activeRoleIds.add(grant.roleId);
    }
    if (activeRoleIds.isEmpty) {
      return PermissionEffect.deny;
    }

    var sawAllow = false;
    for (final rule in rules) {
      if (rule.permissionKey != permissionKey) continue;
      if (!activeRoleIds.contains(rule.roleId)) continue;
      if (rule.effect == PermissionEffect.deny) {
        // Deny wins immediately — no need to scan remaining rules.
        return PermissionEffect.deny;
      }
      sawAllow = true;
    }
    return sawAllow ? PermissionEffect.allow : PermissionEffect.deny;
  }

  /// Returns the resolved permission set for the user (every key
  /// mentioned in [rules] resolved at once). Useful for the
  /// permission-cache snapshot the runtime takes at request time.
  static Map<String, PermissionEffect> resolveAll({
    required Iterable<UserRoleGrant> grants,
    required Iterable<RolePermissionRule> rules,
    required String operatorId,
    required String locationId,
    required DateTime now,
  }) {
    final activeRoleIds = <String>{};
    for (final grant in grants) {
      if (grant.operatorId != operatorId) continue;
      if (!grant.isActiveAt(now)) continue;
      if (!grant.coversLocation(locationId)) continue;
      activeRoleIds.add(grant.roleId);
    }
    final out = <String, PermissionEffect>{};
    if (activeRoleIds.isEmpty) return out;

    for (final rule in rules) {
      if (!activeRoleIds.contains(rule.roleId)) continue;
      final existing = out[rule.permissionKey];
      if (existing == PermissionEffect.deny) continue; // deny sticks
      if (rule.effect == PermissionEffect.deny) {
        out[rule.permissionKey] = PermissionEffect.deny;
      } else if (existing == null) {
        out[rule.permissionKey] = PermissionEffect.allow;
      }
    }
    return out;
  }
}
