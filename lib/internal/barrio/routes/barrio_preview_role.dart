// Typed preview-role model for the Barrio shell.
//
// This is preview logic only. It does NOT enforce access.
// Navigation remains available to all destinations in all preview modes.
// Real permission gating lands in Phase 9.7. Phase 9.3 added
// [BarrioPreviewRole.fromAuthRoles] so the Barrio shell can derive
// the visual preview tier from a real authenticated session's role
// list (super_admin / ff_support / operator_owner / operator_manager
// / operator_supervisor / operator_staff). 9.7 layers actual deny /
// allow gating on top of this preview view via the permission
// catalog.

import 'barrio_destinations.dart';

/// A preview role for the Barrio shell.
///
/// Used to show what each audience tier is intended to see in the
/// future, without enforcing access. Default is [admin].
enum BarrioPreviewRole {
  staff,
  supervisor,
  manager,
  admin;

  /// Maps the authenticated role list (Phase 9.6 catalog roles) to
  /// the preview tier the Barrio shell renders. Falls back to
  /// [admin] when the role list is empty so dev / demo mode keeps
  /// the existing "see everything" behavior. The mapping mirrors the
  /// recommended-role intents in `auth_permission_key_catalog.md`:
  ///
  ///   - `super_admin` / `ff_support` / `operator_owner` →
  ///     [BarrioPreviewRole.admin] (full surface).
  ///   - `operator_manager` → [BarrioPreviewRole.manager].
  ///   - `operator_supervisor` → [BarrioPreviewRole.supervisor].
  ///   - `operator_staff` → [BarrioPreviewRole.staff].
  ///
  /// When a session carries multiple roles (e.g. an owner who also
  /// happens to hold the manager seat), the highest tier wins so the
  /// shell never under-renders.
  static BarrioPreviewRole fromAuthRoles(Iterable<String> authRoles) {
    if (authRoles.isEmpty) return BarrioPreviewRole.admin;
    BarrioPreviewRole resolved = BarrioPreviewRole.staff;
    for (final role in authRoles) {
      final tier = _tierFor(role);
      if (tier == null) continue;
      if (tier.index > resolved.index) {
        resolved = tier;
      }
    }
    return resolved;
  }

  static BarrioPreviewRole? _tierFor(String authRole) {
    final normalized = authRole.trim().toLowerCase();
    switch (normalized) {
      case 'super_admin':
      case 'ff_support':
      case 'operator_owner':
        return BarrioPreviewRole.admin;
      case 'operator_manager':
        return BarrioPreviewRole.manager;
      case 'operator_supervisor':
        return BarrioPreviewRole.supervisor;
      case 'operator_staff':
        return BarrioPreviewRole.staff;
      default:
        return null;
    }
  }

  /// Human-readable display label.
  String get label {
    switch (this) {
      case BarrioPreviewRole.staff:
        return 'Staff';
      case BarrioPreviewRole.supervisor:
        return 'Supervisor';
      case BarrioPreviewRole.manager:
        return 'Manager';
      case BarrioPreviewRole.admin:
        return 'Admin';
    }
  }

  /// Short description of what this preview role sees.
  String get description {
    switch (this) {
      case BarrioPreviewRole.staff:
        return 'Learning surfaces only';
      case BarrioPreviewRole.supervisor:
        return 'Operational + learning';
      case BarrioPreviewRole.manager:
        return 'Full operational access';
      case BarrioPreviewRole.admin:
        return 'Everything';
    }
  }

  /// Returns true if this preview role is intended to access [dest].
  ///
  /// This is preview intent only -- it does NOT block navigation.
  bool isIntendedFor(BarrioDestination dest) {
    return dest.audiences.any((a) => _matchesAudience(a));
  }

  bool _matchesAudience(BarrioAudience audience) {
    switch (this) {
      case BarrioPreviewRole.admin:
        return true; // admin sees everything
      case BarrioPreviewRole.manager:
        return audience == BarrioAudience.allStaff ||
            audience == BarrioAudience.supervisor ||
            audience == BarrioAudience.manager ||
            audience == BarrioAudience.admin;
      case BarrioPreviewRole.supervisor:
        return audience == BarrioAudience.allStaff ||
            audience == BarrioAudience.supervisor;
      case BarrioPreviewRole.staff:
        return audience == BarrioAudience.allStaff;
    }
  }
}
