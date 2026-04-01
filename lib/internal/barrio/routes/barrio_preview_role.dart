// Typed preview-role model for the Barrio shell.
//
// This is preview logic only. It does NOT enforce access.
// Navigation remains available to all destinations in all preview modes.
// Real auth, permissions, and gating belong to Phase 9.

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
