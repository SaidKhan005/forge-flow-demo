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

import '../../auth/permission_keys.dart';
import '../auth/operator_web_auth_source.dart';
import '../../theme/app_theme.dart';
import 'hierarchy_map_picker.dart';
import 'operator_web_demo_banner.dart';

/// One nav entry on the operator-web side rail.
@immutable
class OperatorWebNavItem {
  const OperatorWebNavItem({
    required this.id,
    required this.title,
    required this.icon,
    required this.group,
    this.placeholder = false,
    this.alertCount = 0,
    this.alertTooltip,
  });

  final String id;
  final String title;
  final IconData icon;
  final String group;
  final bool placeholder;

  /// Number of attention-needed items associated with this nav surface.
  /// When > 0, the tile renders a red dot + count chip on the right
  /// edge so the operator sees something needs their attention without
  /// having to open the screen. Today this is wired only for Vendor
  /// integrations (count of connections in `status == error`); other
  /// surfaces leave it at 0.
  final int alertCount;

  /// Tooltip shown on hover over the alert chip. Defaults to a generic
  /// "needs attention" line when null and [alertCount] > 0.
  final String? alertTooltip;
}

/// Management scope surfaced in the shell header. The hierarchy tab
/// owns structural edits; this selector only tells route bodies what
/// part of the business the operator is managing right now.
enum OperatorWebManagementScopeKind { operator, orgUnit, location }

@immutable
class OperatorWebManagementScopeOption {
  const OperatorWebManagementScopeOption({
    required this.key,
    required this.kind,
    required this.id,
    required this.label,
    required this.helper,
    this.parentOrgUnitId,
  });

  final String key;
  final OperatorWebManagementScopeKind kind;
  final String id;
  final String label;
  final String helper;
  final String? parentOrgUnitId;
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
    this.managementScopeOptions = const <OperatorWebManagementScopeOption>[],
    this.selectedManagementScopeKey,
    this.managementScopeLoading = false,
    this.managementScopeError,
    this.onSelectManagementScope,
    this.isDemoSource = false,
  });

  final OperatorWebSession session;
  final List<OperatorWebNavItem> navItems;
  final String selectedNavId;
  final ValueChanged<String> onSelectNav;
  final Widget body;
  final VoidCallback onSignOut;
  final List<OperatorWebManagementScopeOption> managementScopeOptions;
  final String? selectedManagementScopeKey;
  final bool managementScopeLoading;
  final String? managementScopeError;
  final ValueChanged<String>? onSelectManagementScope;

  /// G19 — true only when the router's auth source is the
  /// fixture-driven [DemoOperatorWebAuthSource]. Drives the persistent
  /// [OperatorWebDemoBanner] so demo fixture data is unmistakable. A
  /// live source leaves this false and the banner collapses to a
  /// zero-height box (production operators never see it).
  final bool isDemoSource;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('operator_web_shell_scaffold'),
      backgroundColor: AppColors.backgroundDeep,
      body: SafeArea(
        child: Column(
          children: [
            _HeaderBar(
              session: session,
              onSignOut: onSignOut,
              managementScopeOptions: managementScopeOptions,
              selectedManagementScopeKey: selectedManagementScopeKey,
              managementScopeLoading: managementScopeLoading,
              managementScopeError: managementScopeError,
              onSelectManagementScope: onSelectManagementScope,
            ),
            // G19 — persistent demo indicator, mounted once in the
            // shell (not per screen). Collapses to a zero-height box
            // for any live source.
            OperatorWebDemoBanner(isDemoSource: isDemoSource),
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
  const _HeaderBar({
    required this.session,
    required this.onSignOut,
    required this.managementScopeOptions,
    required this.selectedManagementScopeKey,
    required this.managementScopeLoading,
    required this.managementScopeError,
    required this.onSelectManagementScope,
  });

  final OperatorWebSession session;
  final VoidCallback onSignOut;
  final List<OperatorWebManagementScopeOption> managementScopeOptions;
  final String? selectedManagementScopeKey;
  final bool managementScopeLoading;
  final String? managementScopeError;
  final ValueChanged<String>? onSelectManagementScope;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showRole = constraints.maxWidth >= 760;
        final showIdentity = constraints.maxWidth >= 1000;
        final pickerWidth = constraints.maxWidth >= 980 ? 260.0 : 184.0;
        final showPicker =
            managementScopeOptions.isNotEmpty || managementScopeLoading;
        return Container(
          key: const Key('operator_web_header_bar'),
          height: 80,
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
              // Wave 2 W-5 — operator's uploaded logo, falls back to
              // the Forge & Flow splash icon when the operator has
              // not uploaded one. The fallback keeps the shell
              // identical for fresh tenants.
              _OperatorBrandMark(logoUrl: session.logoUrl),
              const SizedBox(width: 12),
              Expanded(
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
                      session.businessName,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.mono10(color: AppColors.sunsetDark),
                    ),
                  ],
                ),
              ),
              if (showPicker) ...[
                const SizedBox(width: 12),
                SizedBox(
                  width: pickerWidth,
                  child: _ManagementScopePicker(
                    options: managementScopeOptions,
                    selectedKey: selectedManagementScopeKey,
                    loading: managementScopeLoading,
                    error: managementScopeError,
                    onChanged: onSelectManagementScope,
                  ),
                ),
              ],
              if (showRole) ...[
                const SizedBox(width: 12),
                _RolePill(roles: session.roles),
              ],
              if (showIdentity) ...[
                const SizedBox(width: 12),
                Flexible(child: _IdentityChip(session: session)),
              ],
              const SizedBox(width: 8),
              Tooltip(
                message:
                    'Sign out: ends this browser session and returns '
                    'you to the welcome screen.',
                child: TextButton.icon(
                  key: const Key('operator_web_header_signout'),
                  onPressed: onSignOut,
                  icon: const Icon(
                    Icons.logout_outlined,
                    size: 22,
                    color: AppColors.textSecondary,
                  ),
                  label: Text(
                    'Sign out',
                    style: AppTextStyles.body13(
                      color: AppColors.textSecondary,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    foregroundColor: AppColors.textSecondary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Wave 2 W-5 — operator brand mark in the shell header. Renders the
/// operator's uploaded `logoUrl` when one is present; falls back to
/// the Forge & Flow splash icon otherwise. Both branches share the
/// same 40x40 circular footprint (U-2 bumped the bar to height 80, so
/// the splash/logo follows proportionally) so the rest of the header
/// layout stays unchanged. Image load errors fall back to the F&F
/// splash silently — a broken logo URL must never blank the shell.
class _OperatorBrandMark extends StatelessWidget {
  const _OperatorBrandMark({required this.logoUrl});

  final String? logoUrl;

  static const double _size = 40;

  @override
  Widget build(BuildContext context) {
    final url = logoUrl?.trim();
    final hasUrl = url != null && url.isNotEmpty;
    return ClipOval(
      key: const Key('operator_web_header_brand_mark'),
      child: SizedBox(
        width: _size,
        height: _size,
        child: hasUrl
            ? Image.network(
                url,
                key: Key('operator_web_header_brand_logo_${url.hashCode}'),
                width: _size,
                height: _size,
                fit: BoxFit.cover,
                // Defence in depth: if the network image fails (CORS,
                // 404, transient AAD outage), fall back to the splash
                // icon so the shell never blanks.
                errorBuilder: (_, __, ___) => _splashFallback(),
              )
            : _splashFallback(),
      ),
    );
  }

  Widget _splashFallback() {
    return Image.asset(
      'assets/images/forge_flow_splash_icon.png',
      key: const Key('operator_web_header_brand_splash_fallback'),
      width: _size,
      height: _size,
      fit: BoxFit.cover,
    );
  }
}

/// Wave 2 H-3 — hierarchy-map picker shim for the operator-web top bar.
///
/// Bridges `OperatorWebManagementScopeOption` to the reusable
/// [HierarchyMapPicker] so the trigger button (the test surface key
/// `operator_web_management_scope_picker`) opens a tree-shaped popover
/// instead of a flat dropdown. Operator-web's scope kinds map 1:1 onto
/// [HierarchyMapNodeKind] (`operator` → `business`, `orgUnit` →
/// `orgUnit`, `location` → `location`).
class _ManagementScopePicker extends StatelessWidget {
  const _ManagementScopePicker({
    required this.options,
    required this.selectedKey,
    required this.loading,
    required this.error,
    required this.onChanged,
  });

  final List<OperatorWebManagementScopeOption> options;
  final String? selectedKey;
  final bool loading;
  final String? error;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty && !loading) {
      return const _ManagementScopePlaceholder();
    }
    final nodes = _toNodes(options);
    final resolvedSelected =
        options.any((option) => option.key == selectedKey)
            ? selectedKey
            : (options.isEmpty ? null : options.first.key);
    return HierarchyMapPicker(
      key: const Key('operator_web_management_scope_container'),
      keyPrefix: 'operator_web_management_scope',
      // Preserve the legacy test key on the trigger button so existing
      // tests (`tester.tap(find.byKey(Key('operator_web_management_scope_picker')))`)
      // keep driving the popover open.
      triggerKey: const Key('operator_web_management_scope_picker'),
      nodes: nodes,
      selectedId: resolvedSelected,
      onSelected: (node) {
        if (onChanged == null || loading) return;
        onChanged!(node.id);
      },
      loading: loading,
      error: error,
      // Operator-web routes that need a location forward to a "Choose
      // a location" surface when a non-location scope is picked, so
      // non-location selection IS valid at the picker level. Schedule,
      // Vendor connections, etc. handle the redirect themselves.
      allowNonLocationSelection: true,
    );
  }

  static List<HierarchyMapNode> _toNodes(
    List<OperatorWebManagementScopeOption> options,
  ) {
    // Locate the operator (business-level) row so all top-level org
    // units / locations parent under it. There is exactly one in the
    // operator-web catalog ("All locations").
    OperatorWebManagementScopeOption? operatorOption;
    for (final option in options) {
      if (option.kind == OperatorWebManagementScopeKind.operator) {
        operatorOption = option;
        break;
      }
    }
    final operatorKey = operatorOption?.key;
    // Pre-compute the set of org-unit keys actually present in the
    // options list. The router currently filters `unitType=='corp'`
    // out of the orgUnit catalog, so a child orgUnit (or location)
    // pointing at the corp-root org unit (e.g. `demo-org-root`) has
    // no in-tree parent. Re-parent those orphans under the operator
    // "All locations" row so the tree stays connected.
    final orgUnitKeys = <String>{
      for (final option in options)
        if (option.kind == OperatorWebManagementScopeKind.orgUnit)
          option.key,
    };
    return <HierarchyMapNode>[
      for (final option in options)
        HierarchyMapNode(
          id: option.key,
          label: option.label,
          helper: option.helper,
          kind: _nodeKindFor(option.kind),
          parentId: _parentIdFor(option, operatorKey, orgUnitKeys),
          inheritanceBreadcrumb: _breadcrumbFor(option),
        ),
    ];
  }

  static HierarchyMapNodeKind _nodeKindFor(
    OperatorWebManagementScopeKind kind,
  ) {
    switch (kind) {
      case OperatorWebManagementScopeKind.operator:
        return HierarchyMapNodeKind.business;
      case OperatorWebManagementScopeKind.orgUnit:
        return HierarchyMapNodeKind.orgUnit;
      case OperatorWebManagementScopeKind.location:
        return HierarchyMapNodeKind.location;
    }
  }

  static String? _parentIdFor(
    OperatorWebManagementScopeOption option,
    String? operatorKey,
    Set<String> orgUnitKeys,
  ) {
    switch (option.kind) {
      case OperatorWebManagementScopeKind.operator:
        return null;
      case OperatorWebManagementScopeKind.orgUnit:
        // OrgUnits whose parent is the corp root (or any orgUnit that
        // is not surfaced in the options catalog) re-parent under the
        // operator "All locations" row so the tree has a single root.
        final parent = option.parentOrgUnitId;
        if (parent == null || parent.isEmpty) return operatorKey;
        final parentKey = 'orgUnit:$parent';
        return orgUnitKeys.contains(parentKey) ? parentKey : operatorKey;
      case OperatorWebManagementScopeKind.location:
        final parent = option.parentOrgUnitId;
        if (parent == null || parent.isEmpty) return operatorKey;
        final parentKey = 'orgUnit:$parent';
        return orgUnitKeys.contains(parentKey) ? parentKey : operatorKey;
    }
  }

  static String? _breadcrumbFor(OperatorWebManagementScopeOption option) {
    switch (option.kind) {
      case OperatorWebManagementScopeKind.operator:
        return 'Business-wide. Every location inherits these defaults.';
      case OperatorWebManagementScopeKind.orgUnit:
        return 'Inherits business-wide defaults. Locations under '
            'this group inherit values you set here.';
      case OperatorWebManagementScopeKind.location:
        return null;
    }
  }
}

class _ManagementScopePlaceholder extends StatelessWidget {
  const _ManagementScopePlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_management_scope_loading'),
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface.withValues(alpha: 0.84),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.sunsetDark,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Loading context',
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
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

  // G7d (spec §2.B/§3): display pill re-based on the v2 default role
  // catalog. Phantom `'operator_admin'` dropped (folded into
  // `operator_owner` — `_inferRoles` no longer synthesizes it); v1
  // soft-deleted `'operator_manager'` → `roleOperatorGeneralManager`
  // (mapped, not dropped). The four new v2 roles (`finance_analyst`,
  // `auditor_compliance`, `training_lead`, `team_admin`) and the
  // carry-over `ff_support` are now labelled too, since `_inferRoles`
  // can emit them.
  String _roleLabel(List<String> roles) {
    if (roles.contains(PermissionKeys.roleOperatorOwner)) return 'Owner';
    if (roles.contains(PermissionKeys.roleOperatorGeneralManager)) {
      return 'General manager';
    }
    if (roles.contains(PermissionKeys.roleLocationManager)) {
      return 'Location manager';
    }
    if (roles.contains(PermissionKeys.roleSupervisor)) return 'Supervisor';
    if (roles.contains(PermissionKeys.roleFinanceAnalyst)) {
      return 'Finance analyst';
    }
    if (roles.contains(PermissionKeys.roleAuditorCompliance)) {
      return 'Auditor / Compliance';
    }
    if (roles.contains(PermissionKeys.roleTrainingLead)) {
      return 'Training lead';
    }
    if (roles.contains(PermissionKeys.roleTeamAdmin)) return 'Team admin';
    if (roles.contains(PermissionKeys.roleFfSupport)) return 'F&F Support';
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
      style: AppTextStyles.mono14(color: AppColors.textSecondary),
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
          final groupStarts =
              index == 0 || items[index - 1].group != item.group;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (groupStarts) _NavGroupHeader(label: item.group),
              _NavItemTile(
                key: Key('operator_web_nav_item_${item.id}'),
                item: item,
                selected: selected,
                onTap: () => onSelect(item.id),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _NavGroupHeader extends StatelessWidget {
  const _NavGroupHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key('operator_web_nav_group_${_groupKey(label)}'),
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 5),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.mono8(
          color: AppColors.textMuted,
        ).copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }

  static String _groupKey(String label) => label
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
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
                  )
                else if (item.alertCount > 0)
                  Tooltip(
                    key: Key('operator_web_nav_alert_tooltip_${item.id}'),
                    message: item.alertTooltip ??
                        '${item.alertCount} ${item.alertCount == 1 ? "item needs" : "items need"} your attention',
                    child: Container(
                      key: Key('operator_web_nav_alert_chip_${item.id}'),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.negative.withValues(alpha: 0.16),
                        border: Border.all(
                          color: AppColors.negative.withValues(alpha: 0.55),
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        item.alertCount.toString(),
                        style: AppTextStyles.mono8(color: AppColors.negative)
                            .copyWith(fontWeight: FontWeight.w700),
                      ),
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
