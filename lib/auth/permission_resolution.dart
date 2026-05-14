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
// Location-scoped grants apply only when the requested `location_id` matches
// the grant's direct location. Org-unit grants apply through the materialized
// `user_effective_locations` cache. Operator-wide grants cover every location.
//
// Wave 2 R-1L — recursive imply walk. The resolver accepts an optional
// `implies` map (permission key → list of permission keys this key
// auto-grants when granted with effect=allow). After collecting the
// raw (allow, deny) tuples the resolver walks the imply graph and
// promotes every transitively implied key to `allow` UNLESS an
// explicit `deny` rule was emitted for it (deny always wins).
// Mirrors the `permission_keys.implies` column from migration
// `202605142100_phase_R_1L_roles_schema_rewrite.sql` and the
// `PermissionKeyMetadataCatalog.byKey` Dart mirror.

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
/// resolver needs. [scopeType] is one of `operator_wide`, `org_unit`, or
/// `location`.
class UserRoleGrant {
  const UserRoleGrant({
    required this.userRoleId,
    required this.userId,
    required this.roleId,
    required this.operatorId,
    required this.validFrom,
    this.scopeType = 'operator_wide',
    this.locationId,
    this.orgUnitId,
    this.effectiveLocationIds = const <String>[],
    this.validUntil,
    this.revokedAt,
  });

  final String userRoleId;
  final String userId;
  final String roleId;
  final String operatorId;
  final String scopeType;
  final String? locationId;
  final String? orgUnitId;
  final List<String> effectiveLocationIds;
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

  /// True iff this grant covers [requestedLocationId].
  bool coversLocation(String requestedLocationId) {
    switch (scopeType) {
      case 'operator_wide':
        return true;
      case 'location':
        return locationId == requestedLocationId;
      case 'org_unit':
        return effectiveLocationIds.contains(requestedLocationId);
      default:
        final scope = locationId;
        if (scope == null) return true;
        return scope == requestedLocationId;
    }
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
  ///
  /// Wave 2 R-1L — when [implies] is supplied and the direct resolve
  /// result for [permissionKey] would be `deny` purely because no rule
  /// mentioned it, the resolver also checks every key that recursively
  /// implies [permissionKey] (via the inverted imply graph). If any
  /// transitively-implying key resolves to `allow`, the result
  /// promotes to `allow`. An explicit `deny` rule on [permissionKey]
  /// is NEVER overridden by an implying allow — deny still wins.
  static PermissionEffect resolve({
    required String permissionKey,
    required Iterable<UserRoleGrant> grants,
    required Iterable<RolePermissionRule> rules,
    required String operatorId,
    required String locationId,
    required DateTime now,
    Map<String, List<String>>? implies,
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

    // First pass — direct rules. An explicit deny rule short-circuits
    // and wins immediately; an explicit allow short-circuits at end of
    // pass; otherwise we fall through to the imply walk (if any).
    var sawDirectAllow = false;
    for (final rule in rules) {
      if (rule.permissionKey != permissionKey) continue;
      if (!activeRoleIds.contains(rule.roleId)) continue;
      if (rule.effect == PermissionEffect.deny) {
        // Deny wins immediately — no need to scan remaining rules.
        return PermissionEffect.deny;
      }
      sawDirectAllow = true;
    }
    if (sawDirectAllow) return PermissionEffect.allow;

    // Second pass — imply walk. Only fires when the caller supplied
    // an implies map. We resolve via `resolveAll` (which knows how to
    // expand implies) and read back the requested key. This keeps the
    // single-key path consistent with the bulk path so both honour the
    // same deny-wins semantics across the imply graph.
    if (implies != null && implies.isNotEmpty) {
      final resolved = resolveAll(
        grants: grants,
        rules: rules,
        operatorId: operatorId,
        locationId: locationId,
        now: now,
        implies: implies,
      );
      return resolved[permissionKey] ?? PermissionEffect.deny;
    }

    return PermissionEffect.deny;
  }

  /// Returns the resolved permission set for the user (every key
  /// mentioned in [rules] resolved at once, optionally expanded
  /// through the [implies] graph). Useful for the permission-cache
  /// snapshot the runtime takes at request time.
  ///
  /// Wave 2 R-1L imply expansion semantics:
  ///   1. Collect direct (allow, deny) rules per the existing
  ///      deny-wins logic.
  ///   2. For every key with effect=allow, walk [implies] recursively
  ///      and add every transitively-implied key with effect=allow.
  ///   3. Direct `deny` rules win over implied `allow`. An implied
  ///      key cannot override an explicit deny on the same key.
  ///   4. Imply edges are NEVER traversed through a deny — deny stays
  ///      the safer state and does not propagate at all.
  static Map<String, PermissionEffect> resolveAll({
    required Iterable<UserRoleGrant> grants,
    required Iterable<RolePermissionRule> rules,
    required String operatorId,
    required String locationId,
    required DateTime now,
    Map<String, List<String>>? implies,
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

    if (implies == null || implies.isEmpty) return out;

    // Imply walk. Iterative DFS with a visited set to keep the walk
    // cycle-safe even though the metadata layer is expected to be
    // acyclic. Only walks edges from keys whose resolved effect is
    // `allow` (deny is never propagated through implies).
    final pending = <String>[
      for (final entry in out.entries)
        if (entry.value == PermissionEffect.allow) entry.key,
    ];
    final visited = <String>{...pending};
    while (pending.isNotEmpty) {
      final key = pending.removeLast();
      final edges = implies[key];
      if (edges == null || edges.isEmpty) continue;
      for (final implied in edges) {
        // An explicit deny on the implied key wins over imply-allow.
        if (out[implied] == PermissionEffect.deny) continue;
        // If the implied key is not yet known OR was missing entirely
        // from `out`, promote it to allow.
        if (out[implied] != PermissionEffect.allow) {
          out[implied] = PermissionEffect.allow;
        }
        if (visited.add(implied)) pending.add(implied);
      }
    }
    return out;
  }
}
