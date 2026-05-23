// UX-parity Slice E1 — admin capability-key editing gate.
//
// Extracted from `admin_routes.dart` (which is frozen-ceiling under the
// refactor-phase size lint) so the monolith shrinks rather than grows.
// Public so it is unit-testable directly instead of via a mirror.

import 'admin_auth_gate.dart';
import '../auth/permission_keys.dart';

/// Capability-key editing gate with a role fallback. Mirrors
/// operator-web's `_canView`/`_canExport` pattern
/// (`lib/operator_web/screens/audit_log_screen.dart`): consult the
/// server-resolved [AdminAuthSession.permissions] set ONLY when it is
/// non-empty; otherwise fall back to the coarse super-admin role check
/// ([PermissionKeys.roleSuperAdmin]). An EMPTY permissions set (demo /
/// un-hydrated sessions, and every existing code path until the live
/// snapshot lands) therefore returns the same boolean as a bare
/// `roles.contains('super_admin')` check, which is byte-identical to
/// the pre-slice decision at a single-key super-admin-gated site. The
/// UI affordance is advisory only; the proxy `PermissionResolver`
/// re-checks every write server-side.
bool adminCanEdit(AdminAuthSession? session, {required String requiredKey}) {
  if (session == null) return false;
  if (session.permissions.isNotEmpty) {
    return session.permissions.contains(requiredKey);
  }
  return session.roles.contains(PermissionKeys.roleSuperAdmin);
}

/// UX-parity Slice E2 — resolver-style hint for surfaces that keep a
/// role-tier check authoritative but accept an advisory permission-key
/// verdict (e.g. `defaultRoleCatalogScreenCanEdit`'s
/// `actorHasEditKeyHint`). Returns whether [requiredKey] is present in
/// the live [AdminAuthSession.permissions] set, or `null` when the set
/// is empty (demo / un-hydrated) so the caller's behaviour stays
/// byte-identical to the pre-snapshot path.
bool? adminEditKeyHint(AdminAuthSession? session, String requiredKey) {
  if (session == null || session.permissions.isEmpty) return null;
  return session.permissions.contains(requiredKey);
}

/// The [AdminAuthSession] carried by [state] when it is the
/// authenticated state, else null. DRYs the
/// `state is AdminAuthAuthenticated ? state.session : null` extraction
/// the admin route builders repeat before computing an editing gate.
AdminAuthSession? adminSessionOf(AdminAuthState? state) =>
    state is AdminAuthAuthenticated ? state.session : null;
