// Admin route MODEL: the typed `AdminRoute` catalog entry and the
// `AdminRouteSection` nav category. Extracted verbatim from
// `admin_routes.dart` so that frozen-ceiling route table
// (refactor-phase `operator_web_size_lint`) shrinks rather than grows
// as new routes and per-action gates land. `admin_routes.dart`
// re-exports this file, so every importer that referenced these types
// through the route table keeps working unchanged.

import 'package:flutter/widgets.dart';

/// One entry in the admin route catalog.
@immutable
class AdminRoute {
  const AdminRoute({
    required this.id,
    required this.title,
    required this.path,
    required this.icon,
    required this.section,
    required this.builder,
    this.subtitle,
    this.badge,
    this.placeholder = false,
    this.visibleInNav = true,
    this.navAnchorRouteId,
  });

  /// Stable ID used by tests, deep-links, and audit logs.
  final String id;

  /// Human-readable label shown in the side nav.
  final String title;

  /// Canonical route path (`/`, `/operators`, `/pricing`, ...).
  /// Future slices will use this with a router; 11A.0 only needs
  /// stable IDs the shell can switch on.
  final String path;

  /// Material icon shown in the side nav.
  final IconData icon;

  /// High-level side-nav category.
  final AdminRouteSection section;

  /// Optional one-line description for the empty-state body when the
  /// route is opened ahead of its slice landing.
  final String? subtitle;

  /// Optional short nav chip for route-level status.
  final String? badge;

  /// True when the route is a placeholder for a slice that hasn't
  /// landed yet. The shell renders a "coming in 11A.x" empty state
  /// instead of [builder] so the nav structure is visible from
  /// 11A.0 without exposing scaffolding.
  final bool placeholder;

  /// Whether this route appears as a primary side-nav destination.
  ///
  /// Some settings routes are still real destinations for route
  /// handoff/deep-link tests, but the product IA reaches them from
  /// Business accounts setup tiles rather than exposing duplicate
  /// top-level Operations entries.
  final bool visibleInNav;

  /// Optional visible route that should stay highlighted while this
  /// route is active. Setup-only routes anchor to Business accounts
  /// because the business hierarchy workspace is their entry point.
  final String? navAnchorRouteId;

  /// Builds the route surface. For [placeholder] routes the shell
  /// substitutes a branded "coming soon" panel; for live routes the
  /// builder runs.
  final Widget Function(BuildContext context) builder;
}

enum AdminRouteSection {
  ai,
  operations,
  serviceSetup,
  systemMonitoring,
  account,
}
