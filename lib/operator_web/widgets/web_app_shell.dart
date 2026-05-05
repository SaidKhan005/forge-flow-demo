// Phase 11W.0 — Operator Web Console shell.
//
// Branded scaffold that wraps the post-onboarding route surface
// (Account, Vendor connections). Renders a fixed top brand strip
// with the signed-in operator identity, business name, sign-out
// affordance, and a side nav with the V1 routes.
//
// Mirrors the `lib/admin/admin_shell.dart` pattern (Phase 11A.0).
// The shell is intentionally render-only — `OperatorWebRouter`
// owns the route catalog and current selection.

import 'package:flutter/material.dart';

import '../auth/operator_web_auth_source.dart';
import '../../theme/app_theme.dart';

/// One nav entry on the operator-web side rail.
@immutable
class OperatorWebNavItem {
  const OperatorWebNavItem({
    required this.id,
    required this.title,
    required this.icon,
    this.placeholder = false,
  });

  final String id;
  final String title;
  final IconData icon;
  final bool placeholder;
}

/// Branded shell for the operator-web console. Hosts the body widget
/// the router renders for the active route.
class WebAppShell extends StatelessWidget {
  const WebAppShell({
    super.key,
    required this.session,
    required this.navItems,
    required this.selectedNavId,
    required this.onSelectNav,
    required this.body,
    required this.onSignOut,
  });

  final OperatorWebSession session;
  final List<OperatorWebNavItem> navItems;
  final String selectedNavId;
  final ValueChanged<String> onSelectNav;
  final Widget body;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('operator_web_shell_scaffold'),
      backgroundColor: AppColors.backgroundDeep,
      body: SafeArea(
        child: Column(
          children: [
            _HeaderBar(session: session, onSignOut: onSignOut),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SideNav(
                    items: navItems,
                    selectedId: selectedNavId,
                    onSelect: onSelectNav,
                  ),
                  Expanded(
                    child: KeyedSubtree(
                      key: ValueKey('operator_web_body_$selectedNavId'),
                      child: body,
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

class _HeaderBar extends StatelessWidget {
  const _HeaderBar({required this.session, required this.onSignOut});

  final OperatorWebSession session;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_header_bar'),
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
                  session.businessName,
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
            key: const Key('operator_web_header_signout'),
            tooltip:
                'Sign out — ends this browser session and returns '
                'you to the welcome screen.',
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
    final label = _roleLabel(roles);
    return Tooltip(
      message:
          'Your role determines which actions are available. Operator '
          'owners and admins can edit; location managers see read-only '
          'views.',
      child: Container(
        key: const Key('operator_web_header_role_pill'),
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
          label,
          style: AppTextStyles.mono8(color: AppColors.peacockDark),
        ),
      ),
    );
  }

  String _roleLabel(List<String> roles) {
    if (roles.contains('operator_owner')) return 'Owner';
    if (roles.contains('operator_admin')) return 'Admin';
    if (roles.contains('operator_manager')) return 'Manager';
    if (roles.contains('location_manager')) return 'Location manager';
    if (roles.isEmpty) return 'Unknown role';
    return roles.first.replaceAll('_', ' ');
  }
}

class _IdentityChip extends StatelessWidget {
  const _IdentityChip({required this.session});

  final OperatorWebSession session;

  @override
  Widget build(BuildContext context) {
    final label = session.email.isNotEmpty ? session.email : session.uid;
    return Text(
      label,
      key: const Key('operator_web_header_identity'),
      overflow: TextOverflow.ellipsis,
      style: AppTextStyles.mono11(color: AppColors.textSecondary),
    );
  }
}

class _SideNav extends StatelessWidget {
  const _SideNav({
    required this.items,
    required this.selectedId,
    required this.onSelect,
  });

  final List<OperatorWebNavItem> items;
  final String selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_side_nav'),
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
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          final selected = item.id == selectedId;
          return _NavItemTile(
            key: Key('operator_web_nav_item_${item.id}'),
            item: item,
            selected: selected,
            onTap: () => onSelect(item.id),
          );
        },
      ),
    );
  }
}

class _NavItemTile extends StatelessWidget {
  const _NavItemTile({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final OperatorWebNavItem item;
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
                  item.icon,
                  size: 18,
                  color: selected
                      ? AppColors.sunsetDark
                      : AppColors.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    item.title,
                    style: AppTextStyles.body14(
                      color: selected
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
                if (item.placeholder)
                  Tooltip(
                    message:
                        'This page is a placeholder for V1. The real '
                        'screen ships in a later slice.',
                    child: Text(
                      'Soon',
                      style: AppTextStyles.mono8(color: AppColors.textMuted),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
