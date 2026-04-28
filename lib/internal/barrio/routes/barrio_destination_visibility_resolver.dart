// Phase 9 live-closeout B18 - Production hook for Barrio
// destination visibility.
//
// The Barrio bubble hub historically called
// `BarrioPreviewRole.isIntendedFor(dest)` to decide which
// destinations to render at full opacity vs. dim. That preview-role
// path remains as the dev / preview default (so the role chip on the
// home screen still works) but production now wires the
// [BarrioDestinationVisibilityResolver] which consults the live
// `PermissionContext`.
//
// Pattern matches the auth_session_ledger_writer / mfa_factors
// repository / role-permissions guard pattern from earlier in the
// live-closeout: an interface the production binding implements +
// fallback-to-preview when the resolver is null.

import '../../../state/permission_context.dart';
import 'barrio_destinations.dart';
import 'barrio_preview_role.dart';

/// Decides whether a Barrio destination should render at full opacity
/// (intended audience) vs. dimmed (out of audience). Production wires
/// [PermissionContextBarrioVisibilityResolver]; dev / preview falls
/// back to [BarrioPreviewRole.isIntendedFor] when no resolver is
/// supplied.
abstract class BarrioDestinationVisibilityResolver {
  /// Returns true iff [destination] should render at full opacity for
  /// the current actor.
  bool isVisible(BarrioDestination destination);
}

/// Always-visible resolver — used by tests + dev shells where the
/// preview chip should drive everything.
class AlwaysVisibleBarrioDestinationResolver
    implements BarrioDestinationVisibilityResolver {
  const AlwaysVisibleBarrioDestinationResolver();

  @override
  bool isVisible(BarrioDestination destination) => true;
}

/// Production resolver: consults the operator-scoped
/// [PermissionContext] for a permission key derived from the
/// destination id. Pattern: `barrio.destination.<dest_id>`.
///
/// When the context is null (no Provider in the tree) this resolver
/// falls back to [PermissionContextBarrioVisibilityResolver.fallback]
/// — defaults to "visible" so dev / demo without a permission
/// context keeps the existing behavior.
class PermissionContextBarrioVisibilityResolver
    implements BarrioDestinationVisibilityResolver {
  const PermissionContextBarrioVisibilityResolver({
    required PermissionContext? context,
    bool Function(BarrioDestination)? fallback,
  }) : _context = context,
       _fallback = fallback ?? _defaultFallback;

  final PermissionContext? _context;
  final bool Function(BarrioDestination) _fallback;

  /// Permission-key prefix used by the resolver. Mirrors the
  /// `barrio.*` namespace convention in
  /// `auth_permission_key_catalog.md` (the catalog itself adds the
  /// concrete keys when the operator console UX lands).
  static const String permissionKeyPrefix = 'barrio.destination.';

  /// Maps a destination to its permission key. Stable so the
  /// catalog seed knows what to register.
  static String permissionKeyFor(BarrioDestination destination) {
    return '$permissionKeyPrefix${destination.id}';
  }

  @override
  bool isVisible(BarrioDestination destination) {
    final ctx = _context;
    if (ctx == null) return _fallback(destination);
    return ctx.hasPermission(permissionKeyFor(destination));
  }

  static bool _defaultFallback(BarrioDestination destination) => true;
}

/// Resolver backed by the existing preview-role tier — used when a
/// dev / preview shell wants the chip-driven behavior even though a
/// resolver slot exists.
class PreviewRoleBarrioVisibilityResolver
    implements BarrioDestinationVisibilityResolver {
  const PreviewRoleBarrioVisibilityResolver(this.previewRole);

  final BarrioPreviewRole previewRole;

  @override
  bool isVisible(BarrioDestination destination) {
    return previewRole.isIntendedFor(destination);
  }
}
