// Phase 9.7 - PermissionContext + per-request snapshot.
//
// Wraps the [PermissionSnapshot] (Phase 9.6) the runtime uses to
// answer every "is the user allowed to do X right now?" question.
// The proxy builds one of these per request inside the same
// `OperatorScopedRepository.withTenant` that loads the user's
// grants; the Flutter shells receive a parallel structure that
// reflects the JWT claims + cached snapshot from 9.6.
//
// `hasPermission` returns the resolved effect; the caller treats
// missing keys + explicit denies as "not allowed". Sensitive keys
// (those marked `requires_mfa = true` in
// `auth_permission_key_catalog.md`) additionally require that
// `requireFreshAuth()` on the auth notifier returned non-null —
// the gate enforces that as a separate condition so this class
// stays scope-only.

import '../auth/permission_cache.dart';
import '../auth/permission_effect.dart';

class PermissionContext {
  PermissionContext({
    required this.snapshot,
    Set<String> requiresMfaKeys = const <String>{},
  }) : _requiresMfaKeys = Set<String>.unmodifiable(requiresMfaKeys);

  final PermissionSnapshot snapshot;
  final Set<String> _requiresMfaKeys;

  String get userId => snapshot.userId;
  String get operatorId => snapshot.operatorId;
  String get locationId => snapshot.locationId;
  int get rolesVersion => snapshot.rolesVersion;

  /// True iff the resolver said `allow` for [permissionKey] under
  /// the current snapshot. Missing or denied keys return false.
  bool hasPermission(String permissionKey) {
    return snapshot.effectFor(permissionKey) == PermissionEffect.allow;
  }

  /// True iff [permissionKey] is in the MFA-required set. Used by
  /// gates to decide whether to layer a fresh-auth check on top of
  /// the permission check.
  bool requiresFreshAuth(String permissionKey) {
    return _requiresMfaKeys.contains(permissionKey);
  }

  /// Diagnostic count of allow / deny entries the snapshot carries.
  /// Useful for the dev console (Phase 11A.5) but not relied on for
  /// any security decision.
  int get allowedCount => snapshot.entries.values
      .where((effect) => effect == PermissionEffect.allow)
      .length;

  int get deniedCount => snapshot.entries.values
      .where((effect) => effect == PermissionEffect.deny)
      .length;
}
