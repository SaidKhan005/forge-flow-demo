import 'package:flutter/material.dart';

import '../../auth/permission_keys.dart';
import '../../theme/app_theme.dart';
import '../admin_visual_system.dart';

enum RoleEditorProduct {
  forgeFlow(label: 'Forge & Flow'),
  barrio(label: 'Barrio');

  const RoleEditorProduct({required this.label});

  final String label;
}

RoleEditorProduct _productForPermission(String permissionKey) {
  if (permissionKey == 'product.barrio.access' ||
      permissionKey.startsWith('barrio.')) {
    return RoleEditorProduct.barrio;
  }
  return RoleEditorProduct.forgeFlow;
}

String _resourceLabelForPermission(String permissionKey) {
  if (permissionKey == PermissionKeys.productForgeflowAccess ||
      permissionKey == PermissionKeys.productBarrioAccess) {
    return 'Product access';
  }
  final parts = permissionKey.split('.');
  if (parts.length < 2) return permissionKey;
  final product = _productForPermission(permissionKey);
  return switch (product) {
    RoleEditorProduct.forgeFlow when parts.first == 'forgeflow' =>
      parts.skip(1).take(1),
    RoleEditorProduct.barrio when parts.first == 'barrio' =>
      parts.skip(1).take(1),
    _ => parts.take(parts.length - 1),
  }.map(_titleCaseToken).join(' ');
}

List<String> _orderedPermissionKeysForProduct(RoleEditorProduct product) {
  final keys = PermissionKeys.all
      .where((key) => _productForPermission(key) == product)
      .toList(growable: false);
  keys.sort((a, b) {
    final resource = _resourceLabelForPermission(
      a,
    ).compareTo(_resourceLabelForPermission(b));
    if (resource != 0) return resource;
    return a.compareTo(b);
  });
  return keys;
}

Map<String, List<String>> _permissionKeysByResource(RoleEditorProduct product) {
  final grouped = <String, List<String>>{};
  for (final key in _orderedPermissionKeysForProduct(product)) {
    grouped
        .putIfAbsent(_resourceLabelForPermission(key), () => <String>[])
        .add(key);
  }
  return grouped;
}

List<String> orderedSelectedPermissionKeys(Set<String> selected) {
  final ordered = <String>[];
  for (final product in RoleEditorProduct.values) {
    for (final key in _orderedPermissionKeysForProduct(product)) {
      if (selected.contains(key)) ordered.add(key);
    }
  }
  final unknown =
      selected
          .where((key) => !PermissionKeys.all.contains(key))
          .toList(growable: false)
        ..sort();
  ordered.addAll(unknown);
  return ordered;
}

String permissionHumanLabel(String permissionKey) {
  final parts = permissionKey
      .split('.')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.length < 2) return _titleCaseToken(permissionKey);
  final action = parts.last;
  final resource = _permissionResourceLabel(parts.take(parts.length - 1));
  final verb = _permissionActionLabel(action);
  if (verb == 'Access' && parts.first == 'product') {
    return 'Access $resource';
  }
  return '$verb $resource';
}

String _permissionResourceLabel(Iterable<String> parts) {
  final normalized = parts.toList(growable: false);
  if (normalized.isEmpty) return 'permission';
  if (normalized.length == 2 &&
      normalized.first == 'product' &&
      normalized.last == 'forgeflow') {
    return 'Forge & Flow product';
  }
  if (normalized.length == 2 &&
      normalized.first == 'product' &&
      normalized.last == 'barrio') {
    return 'Barrio product';
  }
  return normalized.map(_permissionResourceToken).join(' ');
}

String _permissionResourceToken(String token) {
  switch (token) {
    case 'forgeflow':
      return 'Forge & Flow';
    case 'barrio':
      return 'Barrio';
    case 'admin':
      return 'admin';
    case 'team':
      return 'team';
    case 'billing':
      return 'billing';
    case 'integration':
      return 'integration';
    case 'integrations':
      return 'vendor integrations';
    case 'workflow':
      return 'workflow';
    case 'users':
      return 'users';
    case 'roles':
      return 'roles';
    case 'audit_log':
      return 'audit log';
    case 'session':
      return 'sessions';
    case 'service_principal':
      return 'service principal';
    case 'feature_flag':
      return 'feature flags';
    case 'pricing_tier':
      return 'pricing tiers';
    case 'payment_method':
      return 'payment methods';
    case 'usage_caps':
      return 'usage caps';
    case 'target_cycle':
      return 'target cycles';
    case 'target_profile':
      return 'target profiles';
    case 'weekly_plan':
      return 'weekly plans';
    case 'jim_taylor':
      return 'Jim Taylor';
    case 'preston_lee':
      return 'Preston Lee';
    case 'el_podio':
      return 'El Podio';
    case '7shifts':
      return '7shifts';
    case 'qbo':
      return 'QuickBooks';
    default:
      return token
          .split('_')
          .where((part) => part.isNotEmpty)
          .map(_titleCaseToken)
          .join(' ');
  }
}

String _permissionActionLabel(String action) {
  switch (action) {
    case 'access':
      return 'Access';
    case 'view':
      return 'View';
    case 'edit':
      return 'Edit';
    case 'override':
      return 'Override';
    case 'manage':
      return 'Manage';
    case 'unlock':
      return 'Unlock';
    case 'replace':
      return 'Replace';
    case 'create':
      return 'Create';
    case 'delete':
      return 'Delete';
    case 'assign':
      return 'Assign';
    case 'revoke':
      return 'Revoke';
    case 'invite':
      return 'Invite';
    case 'deactivate':
      return 'Deactivate';
    case 'reactivate':
      return 'Reactivate';
    case 'soft_delete':
      return 'Soft delete';
    case 'erase_pii':
      return 'Erase PII for';
    case 'reset_password':
      return 'Reset password for';
    case 'reset_mfa':
      return 'Reset two-factor sign-in for';
    case 'reset_mfa_factors':
      return 'Reset two-factor sign-in factors for';
    case 'edit_seeded':
      return 'Edit seeded';
    case 'export':
      return 'Export';
    case 'force_logout':
      return 'Force logout';
    case 'issue_token':
      return 'Issue token for';
    case 'read':
      return 'Read';
    case 'toggle':
      return 'Toggle';
    case 'publish':
      return 'Publish';
    case 'connect':
      return 'Connect';
    case 'key_rotate':
      return 'Rotate keys for';
    case 'configure':
      return 'Configure';
    case 'run':
      return 'Run';
    case 'approve':
      return 'Approve';
    case 'reject':
      return 'Reject';
    case 'complete_unit':
      return 'Complete unit in';
    case 'tool_invoke':
      return 'Invoke tools in';
    default:
      return _titleCaseToken(action);
  }
}

String _titleCaseToken(String token) {
  final normalized = token.trim().replaceAll(RegExp(r'[_\-]+'), ' ');
  final words = normalized
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .map((word) {
        if (word.length == 1) return word.toUpperCase();
        return word.substring(0, 1).toUpperCase() +
            word.substring(1).toLowerCase();
      });
  return words.join(' ');
}

class AdminProductPermissionPicker extends StatefulWidget {
  const AdminProductPermissionPicker({
    super.key,
    required this.selected,
    required this.barrioPlanIncluded,
    required this.onToggle,
    this.lockedPermissionKeys = const <String>{},
  });

  final Set<String> selected;
  final bool barrioPlanIncluded;
  final Set<String> lockedPermissionKeys;
  final void Function(String permissionKey, bool selected) onToggle;

  @override
  State<AdminProductPermissionPicker> createState() =>
      _AdminProductPermissionPickerState();
}

class _AdminProductPermissionPickerState
    extends State<AdminProductPermissionPicker>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: RoleEditorProduct.values.length,
    vsync: this,
  );

  RoleEditorProduct _activeProduct = RoleEditorProduct.forgeFlow;

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final product = _activeProduct;
    final disabled =
        product == RoleEditorProduct.barrio && !widget.barrioPlanIncluded;
    return Container(
      key: const Key('admin_rhs_role_editor_permission_picker'),
      decoration: AdminVisualSystem.surfaceDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TabBar(
            key: const Key('admin_rhs_role_editor_product_tabs'),
            controller: _tabController,
            labelColor: AppColors.textPrimary,
            unselectedLabelColor: AppColors.textMuted,
            indicatorColor: AppColors.sunset,
            labelStyle: AppTextStyles.body15Bold(color: AppColors.textPrimary),
            unselectedLabelStyle: AppTextStyles.body14(
              color: AppColors.textMuted,
            ),
            labelPadding: AdminVisualSystem.tabPadding,
            onTap: (index) {
              setState(() => _activeProduct = RoleEditorProduct.values[index]);
            },
            tabs: const <Widget>[
              Tab(
                key: Key('admin_rhs_role_editor_tab_forgeflow'),
                text: 'Forge & Flow',
              ),
              Tab(key: Key('admin_rhs_role_editor_tab_barrio'), text: 'Barrio'),
            ],
          ),
          if (disabled)
            const _AdminDormantProductNotice(
              key: Key('admin_rhs_role_editor_barrio_coming_soon'),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              children: <Widget>[
                for (final entry in _permissionKeysByResource(product).entries)
                  _AdminPermissionResourceSection(
                    key: Key(
                      'admin_rhs_role_editor_resource_'
                      '${product.name}_${entry.key}',
                    ),
                    resourceLabel: entry.key,
                    permissionKeys: entry.value,
                    selected: widget.selected,
                    disabled: disabled,
                    lockedPermissionKeys: widget.lockedPermissionKeys,
                    onToggle: widget.onToggle,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminDormantProductNotice extends StatelessWidget {
  const _AdminDormantProductNotice({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.warning.withValues(alpha: 0.32),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.info_outline, size: 16, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Coming soon. Barrio permissions are visible for planning, '
              'but this operator plan does not include Barrio yet.',
              style: AppTextStyles.body12(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminPermissionResourceSection extends StatelessWidget {
  const _AdminPermissionResourceSection({
    super.key,
    required this.resourceLabel,
    required this.permissionKeys,
    required this.selected,
    required this.disabled,
    required this.lockedPermissionKeys,
    required this.onToggle,
  });

  final String resourceLabel;
  final List<String> permissionKeys;
  final Set<String> selected;
  final bool disabled;
  final Set<String> lockedPermissionKeys;
  final void Function(String permissionKey, bool selected) onToggle;

  @override
  Widget build(BuildContext context) {
    final selectedCount = permissionKeys.where(selected.contains).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  resourceLabel,
                  style: AppTextStyles.mono12(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '$selectedCount / ${permissionKeys.length}',
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final key in permissionKeys)
            _AdminPermissionCheckbox(
              key: Key('admin_rhs_role_editor_perm_$key'),
              permissionKey: key,
              selected: selected.contains(key),
              disabled: disabled,
              locked: lockedPermissionKeys.contains(key),
              onChanged: (value) => onToggle(key, value ?? false),
            ),
        ],
      ),
    );
  }
}

class _AdminPermissionCheckbox extends StatelessWidget {
  const _AdminPermissionCheckbox({
    super.key,
    required this.permissionKey,
    required this.selected,
    required this.disabled,
    required this.locked,
    required this.onChanged,
  });

  final String permissionKey;
  final bool selected;
  final bool disabled;
  final bool locked;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    final mfa = PermissionKeys.requiresMfa.contains(permissionKey);
    return CheckboxListTile(
      key: Key('admin_rhs_role_editor_checkbox_$permissionKey'),
      value: selected,
      onChanged: disabled || locked ? null : onChanged,
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      title: Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text(
            permissionHumanLabel(permissionKey),
            style: AppTextStyles.body12(color: AppColors.textPrimary),
          ),
          if (mfa)
            Tooltip(
              message: kMfaRequiredTooltip,
              child: Text(
                'MFA',
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
            ),
        ],
      ),
      subtitle: locked
          ? Text(
              'Required for platform safety.',
              style: AppTextStyles.body12(color: AppColors.textMuted),
            )
          : Text(
              permissionKey,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
    );
  }
}

@visibleForTesting
const String kMfaRequiredTooltip = 'Requires multi-factor authentication.';
