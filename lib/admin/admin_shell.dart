// Phase 11A.0 — Admin shell.
//
// Branded scaffold that wraps the admin route surface. Renders a
// fixed left-side nav (icon + label) for desktop / wide web layouts
// and a brand header strip across the top with the signed-in admin
// identity and a sign-out affordance.
//
// The shell is intentionally render-only on a [List<AdminRoute>] —
// it does not own the route catalog. That lives in
// `admin_routes.dart` so later 11A.x slices add surfaces by
// extending the const list, not by editing the shell.

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'admin_auth_gate.dart';
import 'admin_routes.dart';

class AdminShell extends StatefulWidget {
  const AdminShell({
    super.key,
    required this.session,
    required this.authSource,
    this.routes = kAdminRoutes,
    this.initialRouteId = kAdminHomeRouteId,
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

  void _select(String id) {
    if (id == _selectedRouteId) return;
    setState(() => _selectedRouteId = id);
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
                    child: _AdminBody(
                      key: ValueKey('admin-body-${_currentRoute.id}'),
                      route: _currentRoute,
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
                  style: AppTextStyles.display20(
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  'Operations Console',
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.mono8(color: AppColors.sunsetDark),
                ),
              ],
            ),
          ),
          const Spacer(),
          _RolePill(roles: session.roles),
          const SizedBox(width: 12),
          Flexible(child: _IdentityChip(session: session)),
          const SizedBox(width: 8),
          IconButton(
            key: const Key('admin_header_signout'),
            tooltip: 'Sign out',
            onPressed: onSignOut,
            icon: const Icon(
              Icons.logout_outlined,
              size: 18,
              color: AppColors.textSecondary,
            ),
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
        adminRole,
        style: AppTextStyles.mono8(color: AppColors.peacockDark),
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
      child: ListView.builder(
        itemCount: routes.length,
        itemBuilder: (context, index) {
          final route = routes[index];
          final selected = route.id == selectedRouteId;
          return _NavItem(
            key: Key('admin_nav_item_${route.id}'),
            route: route,
            selected: selected,
            onTap: () => onSelect(route.id),
          );
        },
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
                  child: Text(
                    route.title,
                    style: AppTextStyles.body14(
                      color: selected
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
                if (route.placeholder)
                  Text(
                    'soon',
                    style: AppTextStyles.mono8(color: AppColors.textMuted),
                  ),
              ],
            ),
          ),
        ),
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
                  Icon(
                    route.icon,
                    size: 22,
                    color: AppColors.sunsetDark,
                  ),
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
                route.subtitle ?? 'This admin surface is not online yet.',
                style: AppTextStyles.body13(
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
