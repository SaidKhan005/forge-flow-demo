// Phase 11A.0 - Admin shell.
//
// Branded scaffold that wraps the admin route surface. Renders a
// fixed left-side nav (icon + label) for desktop / wide web layouts
// and a brand header strip across the top with the signed-in admin
// identity and a sign-out affordance.
//
// The shell is intentionally render-only on a [List<AdminRoute>] -
// it does not own the route catalog. That lives in
// `admin_routes.dart` so later 11A.x slices add surfaces by
// extending the const list, not by editing the shell.

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'admin_auth_gate.dart';
import 'admin_button_styles.dart';
import 'admin_route_handoff.dart';
import 'admin_routes.dart';

class AdminShell extends StatefulWidget {
  const AdminShell({
    super.key,
    required this.session,
    required this.authSource,
    this.routes = kAdminRoutes,
    this.initialRouteId = kAdminOperatorsRouteId,
  });

  final AdminAuthSession session;
  final AdminAuthSource authSource;
  final List<AdminRoute> routes;
  final String initialRouteId;

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  late String _selectedRouteId;
  AdminSupportLogFilterIntent? _supportLogFilter;
  AdminOperatorLocationScopeIntent? _operatorLocationScope;

  @override
  void initState() {
    super.initState();
    _selectedRouteId = _routeIdOrFallback(widget.initialRouteId);
  }

  String _routeIdOrFallback(String requested) {
    final hit = widget.routes.firstWhere(
      (r) => r.id == requested,
      orElse: () => widget.routes.first,
    );
    return hit.id;
  }

  AdminRoute get _currentRoute => widget.routes.firstWhere(
    (r) => r.id == _selectedRouteId,
    orElse: () => widget.routes.first,
  );

  void _selectIntent(AdminRouteIntent intent) {
    final nextRouteId = _routeIdOrFallback(intent.routeId);
    final nextSupportLogFilter = nextRouteId == kAdminDebugConsoleRouteId
        ? intent.supportLogFilter
        : null;
    final nextOperatorLocationScope =
        intent.operatorLocationScope ?? _operatorLocationScope;
    if (nextRouteId == _selectedRouteId &&
        nextSupportLogFilter == _supportLogFilter &&
        nextOperatorLocationScope == _operatorLocationScope) {
      return;
    }
    setState(() {
      _selectedRouteId = nextRouteId;
      _supportLogFilter = nextSupportLogFilter;
      _operatorLocationScope = nextOperatorLocationScope;
    });
  }

  void _select(String id) {
    _selectIntent(AdminRouteIntent(routeId: id));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('admin_shell_scaffold'),
      backgroundColor: AppColors.backgroundDeep,
      body: SafeArea(
        child: Column(
          children: [
            _AdminHeaderBar(
              session: widget.session,
              onSignOut: () => widget.authSource.signOut(),
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _AdminSideNav(
                    routes: widget.routes,
                    selectedRouteId: _selectedRouteId,
                    onSelect: _select,
                  ),
                  Expanded(
                    child: AdminRouteHandoff(
                      selectedRouteId: _selectedRouteId,
                      supportLogFilter: _supportLogFilter,
                      operatorLocationScope: _operatorLocationScope,
                      onSelectRoute: _selectIntent,
                      child: _AdminBody(
                        key: ValueKey(
                          'admin-body-${_currentRoute.id}-'
                          '${_supportLogFilter?.cacheKey ?? 'none'}-'
                          '${_routeUsesOperatorScope(_currentRoute.id) ? _operatorLocationScope?.cacheKey ?? 'all' : 'global'}',
                        ),
                        route: _currentRoute,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _routeUsesOperatorScope(String routeId) {
  return routeId == kAdminDataAccuracyRouteId ||
      routeId == kAdminPollingPricingRouteId ||
      routeId == kAdminMembersRouteId ||
      routeId == kAdminRolesHierarchySessionsRouteId ||
      routeId == kAdminAuditedSupportActionsRouteId;
}

class _AdminHeaderBar extends StatelessWidget {
  const _AdminHeaderBar({required this.session, required this.onSignOut});

  final AdminAuthSession session;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_header_bar'),
      height: 64,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.backgroundDeep,
            AppColors.backgroundDeep.withValues(alpha: 0.85),
          ],
        ),
        border: Border(
          bottom: BorderSide(
            color: AppColors.borderSubtle.withValues(alpha: 0.7),
            width: 1,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          ClipOval(
            child: Image.asset(
              'assets/images/forge_flow_splash_icon.png',
              width: 32,
              height: 32,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Forge & Flow',
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                Text(
                  'Admin Console',
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.uiLabel(color: AppColors.sunsetDark),
                ),
              ],
            ),
          ),
          const Spacer(),
          _RolePill(roles: session.roles),
          const SizedBox(width: 12),
          Flexible(child: _IdentityChip(session: session)),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            key: const Key('admin_header_signout'),
            style: AdminButtonStyles.secondary(
              foregroundColor: AppColors.textSecondary,
              borderColor: AppColors.borderSubtle,
              minWidth: 116,
              minHeight: 44,
            ),
            onPressed: onSignOut,
            icon: const Icon(
              Icons.logout_outlined,
              size: 18,
              color: AppColors.textSecondary,
            ),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

class _RolePill extends StatelessWidget {
  const _RolePill({required this.roles});

  final List<String> roles;

  @override
  Widget build(BuildContext context) {
    final adminRole = roles.firstWhere(
      kAdminConsoleRoles.contains,
      orElse: () => roles.isEmpty ? 'unknown' : roles.first,
    );
    final roleLabel = switch (adminRole) {
      'super_admin' => 'Ecosystem admin',
      'ff_support' => 'Support access',
      'unknown' => 'Unknown role',
      _ => adminRole.replaceAll('_', ' '),
    };
    return Container(
      key: const Key('admin_header_role_pill'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.12),
        border: Border.all(
          color: AppColors.peacock.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        roleLabel,
        style: AppTextStyles.chipLabel(color: AppColors.peacockDark),
      ),
    );
  }
}

class _IdentityChip extends StatelessWidget {
  const _IdentityChip({required this.session});

  final AdminAuthSession session;

  @override
  Widget build(BuildContext context) {
    final label = session.email.isNotEmpty ? session.email : session.uid;
    return Text(
      label,
      key: const Key('admin_header_identity'),
      overflow: TextOverflow.ellipsis,
      style: AppTextStyles.mono11(color: AppColors.textSecondary),
    );
  }
}

class _AdminSideNav extends StatelessWidget {
  const _AdminSideNav({
    required this.routes,
    required this.selectedRouteId,
    required this.onSelect,
  });

  final List<AdminRoute> routes;
  final String selectedRouteId;
  final ValueChanged<String> onSelect;

  static const List<_NavSectionMeta> _sections = <_NavSectionMeta>[
    _NavSectionMeta(
      section: AdminRouteSection.operations,
      label: 'Operations',
      icon: Icons.storefront_outlined,
      accentColor: AppColors.sunset,
    ),
    _NavSectionMeta(
      section: AdminRouteSection.ai,
      label: 'AI',
      icon: Icons.auto_awesome_outlined,
      accentColor: AppColors.peacock,
      badge: 'Work in progress',
    ),
    _NavSectionMeta(
      section: AdminRouteSection.systemMonitoring,
      label: 'System monitoring',
      icon: Icons.monitor_heart_outlined,
      accentColor: AppColors.warning,
    ),
    _NavSectionMeta(
      section: AdminRouteSection.serviceSetup,
      label: 'Service setup',
      icon: Icons.settings_input_component_outlined,
      accentColor: AppColors.ocean,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_side_nav'),
      width: 220,
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        border: Border(
          right: BorderSide(
            color: AppColors.borderSubtle.withValues(alpha: 0.7),
            width: 1,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final section in _sections) ..._buildSection(context, section),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSection(BuildContext context, _NavSectionMeta section) {
    final sectionRoutes = routes
        .where((route) => route.section == section.section)
        .toList(growable: false);
    if (sectionRoutes.isEmpty) return const <Widget>[];
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DecoratedBox(
          key: Key('admin_nav_section_panel_${section.section.name}'),
          decoration: BoxDecoration(
            color: section.accentColor.withValues(alpha: 0.055),
            border: Border.all(
              color: section.accentColor.withValues(alpha: 0.18),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _NavSectionHeader(section: section),
                const SizedBox(height: 8),
                _NavSectionDivider(section: section),
                const SizedBox(height: 8),
                for (final route in sectionRoutes)
                  _NavItem(
                    key: Key('admin_nav_item_${route.id}'),
                    route: route,
                    selected: route.id == selectedRouteId,
                    onTap: () => onSelect(route.id),
                  ),
              ],
            ),
          ),
        ),
      ),
    ];
  }
}

class _NavSectionDivider extends StatelessWidget {
  const _NavSectionDivider({required this.section});

  final _NavSectionMeta section;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: Key('admin_nav_section_divider_${section.section.name}'),
      children: [
        Container(
          width: 34,
          height: 2,
          decoration: BoxDecoration(
            color: section.accentColor.withValues(alpha: 0.52),
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              color: AppColors.borderSubtle.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ],
    );
  }
}

class _NavSectionMeta {
  const _NavSectionMeta({
    required this.section,
    required this.label,
    required this.icon,
    required this.accentColor,
    this.badge,
  });

  final AdminRouteSection section;
  final String label;
  final IconData icon;
  final Color accentColor;
  final String? badge;
}

class _NavSectionHeader extends StatelessWidget {
  const _NavSectionHeader({required this.section});

  final _NavSectionMeta section;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key('admin_nav_section_${section.section.name}'),
      padding: const EdgeInsets.fromLTRB(2, 0, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                key: Key('admin_nav_section_icon_${section.section.name}'),
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: section.accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  section.icon,
                  size: 16,
                  color: Color.alphaBlend(
                    section.accentColor.withValues(alpha: 0.88),
                    AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  section.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.uiLabel(color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
          if (section.badge != null) ...[
            const SizedBox(height: 7),
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
                key: Key('admin_nav_section_badge_${section.section.name}'),
                constraints: const BoxConstraints(maxWidth: 150),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.peacock.withValues(alpha: 0.10),
                  border: Border.all(
                    color: AppColors.peacock.withValues(alpha: 0.35),
                    width: 1,
                  ),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  section.badge!,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.chipLabel(color: AppColors.peacockDark),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    super.key,
    required this.route,
    required this.selected,
    required this.onTap,
  });

  final AdminRoute route;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected
            ? AppColors.sunset.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: selected
                    ? AppColors.sunset.withValues(alpha: 0.55)
                    : Colors.transparent,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  route.icon,
                  size: 18,
                  color: selected
                      ? AppColors.sunsetDark
                      : AppColors.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        route.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.body14(
                          color: selected
                              ? AppColors.textPrimary
                              : AppColors.textSecondary,
                        ),
                      ),
                      if (route.badge != null) ...[
                        const SizedBox(height: 4),
                        _NavRouteBadge(routeId: route.id, label: route.badge!),
                      ],
                    ],
                  ),
                ),
                if (route.placeholder)
                  Text(
                    'Coming soon',
                    style: AppTextStyles.chipLabel(color: AppColors.textMuted),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavRouteBadge extends StatelessWidget {
  const _NavRouteBadge({required this.routeId, required this.label});

  final String routeId;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('admin_nav_item_badge_$routeId'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.10),
        border: Border.all(
          color: AppColors.peacock.withValues(alpha: 0.35),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.chipLabel(color: AppColors.peacockDark),
      ),
    );
  }
}

class _AdminBody extends StatelessWidget {
  const _AdminBody({super.key, required this.route});

  final AdminRoute route;

  @override
  Widget build(BuildContext context) {
    if (route.placeholder) {
      return _PlaceholderBody(route: route);
    }
    return route.builder(context);
  }
}

class _PlaceholderBody extends StatelessWidget {
  const _PlaceholderBody({required this.route});

  final AdminRoute route;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: Key('admin_placeholder_${route.id}'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(route.icon, size: 22, color: AppColors.sunsetDark),
                  const SizedBox(width: 10),
                  Text(
                    route.title,
                    style: AppTextStyles.display20(
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                route.subtitle ?? 'This page is not ready yet.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
