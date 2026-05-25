// Wave 2 S-3 (RP-14) — Reusable permission picker grouped by
// `productLabel` → `categoryLabel`, with implies auto-select, search,
// and a scope-conflict notice.
//
// Consumed by:
//   * `lib/operator_web/screens/custom_role_editor_screen.dart`
//   * `lib/admin/screens/default_role_catalog_admin_screen.dart`
//
// Surfaces the picker from `PermissionKeyMetadataCatalog.byKey` (the
// Dart mirror of the R-1L / R-2L `permission_keys` metadata schema)
// so adding a new key auto-surfaces in every editor.
//
// HP #2 demo mode parity: this widget has no `kDemoMode` branch and
// no reader fork — the catalog is the same in demo and live.

import 'package:flutter/material.dart';

import '../auth/permission_key_metadata.dart';
import '../auth/permission_keys.dart';
import '../operator_web/screens/permission_explainer_screen.dart'
    show kPermissionExplainerMfaTooltip;
import '../services/auth/custom_role_validator.dart' show RoleScope;
import '../theme/app_theme.dart';

/// Title Case English labels for each `productLabel` value the picker
/// renders. Plain English per the UX writing standard.
const Map<String, String> kRolePermissionPickerProductLabels = <String, String>{
  'product': 'Product access',
  'forgeflow': 'Forge & Flow',
  'barrio': 'Barrio',
  'admin': 'F&F admin',
  'team': 'Team',
  'account': 'Account',
  'business_timing': 'Business timing',
  'billing': 'Billing',
  'integration': 'Integrations',
  'workflow': 'Workflows',
};

/// Fixed render order for the picker. Anything not in the list
/// tails alphabetically by machine label so new products surface
/// stably.
const List<String> kRolePermissionPickerProductOrder = <String>[
  'product',
  'forgeflow',
  'barrio',
  'team',
  'admin',
  'account',
  'business_timing',
  'billing',
  'integration',
  'workflow',
];

/// Returns the inverse imply graph — for every key, who lists it in
/// their `implies[]` chain? Pure function over
/// [PermissionKeyMetadataCatalog.byKey] so tests can pin it directly.
Map<String, List<String>> rolePermissionPickerReverseImplies() {
  final reverse = <String, List<String>>{};
  PermissionKeyMetadataCatalog.byKey.forEach((key, meta) {
    for (final implied in meta.implies) {
      reverse.putIfAbsent(implied, () => <String>[]).add(key);
    }
  });
  return reverse;
}

/// For a given [permissionKey] and the current [explicit] selection,
/// returns the list of explicit ancestor keys (top-most pullers) that
/// are currently pulling the key in via the implies graph. An empty
/// list means the key is either not selected or was selected directly.
List<String> rolePermissionPickerRequiredBy(
  String permissionKey,
  Set<String> explicit,
) {
  final reverse = rolePermissionPickerReverseImplies();
  final parents = reverse[permissionKey] ?? const <String>[];
  final pullers = <String>[];
  for (final parent in parents) {
    if (explicit.contains(parent) && !pullers.contains(parent)) {
      pullers.add(parent);
      continue;
    }
    // Parent isn't explicit — look further up the graph. Find any
    // explicit ancestor whose closure includes `parent` (and hence
    // includes `permissionKey`).
    for (final candidate in explicit) {
      if (candidate == permissionKey) continue;
      final closure = PermissionKeyMetadataCatalog.expandImplies(<String>[
        candidate,
      ]);
      if (closure.contains(parent) && !pullers.contains(candidate)) {
        pullers.add(candidate);
      }
    }
  }
  return pullers;
}

/// Wave 2 S-3 (RP-14) — Permission picker card. Renders permissions
/// grouped by [PermissionKeyMetadata.productLabel] → [categoryLabel].
/// Each row shows the [humanLabel] and an MFA chip when applicable.
///
/// State that mutates the selection lives in the caller; the picker
/// is a stateless surface from the caller's POV. Internal state
/// (search query, "What's hidden?" expander) lives inside the widget.
///
/// Auto-select semantics:
///   * Ticking a key invokes [onToggle] with `selected=true`. The
///     caller must add the key to the explicit set and recompute the
///     displayed [selected] = `expandImplies(explicit)`.
///   * Unticking a key the operator picked directly invokes
///     [onToggle] with `selected=false`.
///   * Unticking an auto-added key (implied by another selection) is
///     gated by the widget itself — the checkbox renders disabled and
///     a tooltip names the parent.
class RolePermissionPickerCard extends StatefulWidget {
  const RolePermissionPickerCard({
    super.key,
    required this.selected,
    required this.explicit,
    required this.roleScope,
    required this.onToggle,
    this.readOnly = false,
    this.barrioPlanIncluded = true,
    this.lockedPermissionKeys = const <String>{},
    this.keyPrefix = 'role_permission_picker',
    this.header,
  });

  /// Transitive `expandImplies` closure of [explicit]. Picker renders
  /// every key in this set with a checked box.
  final Set<String> selected;

  /// Keys the operator ticked directly. Used to compute the auto-add
  /// tooltip.
  final Set<String> explicit;

  final RoleScope roleScope;
  final void Function(String key, bool selected) onToggle;
  final bool readOnly;

  /// True when the operator's plan includes Barrio. False renders
  /// the Barrio product greyed with a "Coming soon" badge.
  final bool barrioPlanIncluded;

  /// Keys that must remain selected for host-specific safety rules.
  final Set<String> lockedPermissionKeys;

  /// Prefix for every widget Key the picker stamps. Lets two pickers
  /// coexist (e.g. one per admin draft row) without key collisions.
  final String keyPrefix;

  /// Optional host-supplied title treatment. Operator Web uses this to
  /// align the picker with its section heading system while other hosts
  /// keep the default picker title.
  final Widget? header;

  @override
  State<RolePermissionPickerCard> createState() =>
      _RolePermissionPickerCardState();
}

class _RolePermissionPickerCardState extends State<RolePermissionPickerCard> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _showHiddenScope = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _filtersOrgWide =>
      widget.roleScope == RoleScope.orgUnit ||
      widget.roleScope == RoleScope.location;

  Map<String, Map<String, List<String>>> _visibleGroups() {
    final query = _searchQuery.trim().toLowerCase();
    final out = <String, Map<String, List<String>>>{};
    PermissionKeyMetadataCatalog.byKey.forEach((key, meta) {
      if (!PermissionKeys.all.contains(key)) return;
      if (_filtersOrgWide && meta.scopeKind == PermissionScopeKind.orgWide) {
        return;
      }
      if (query.isNotEmpty && !meta.humanLabel.toLowerCase().contains(query)) {
        return;
      }
      out
          .putIfAbsent(meta.productLabel, () => <String, List<String>>{})
          .putIfAbsent(meta.categoryLabel, () => <String>[])
          .add(key);
    });
    for (final productMap in out.values) {
      for (final keys in productMap.values) {
        keys.sort((a, b) {
          final la = PermissionKeyMetadataCatalog.byKey[a]?.humanLabel ?? a;
          final lb = PermissionKeyMetadataCatalog.byKey[b]?.humanLabel ?? b;
          return la.compareTo(lb);
        });
      }
    }
    return out;
  }

  List<String> _hiddenOrgWideKeys() {
    if (!_filtersOrgWide) return const <String>[];
    final query = _searchQuery.trim().toLowerCase();
    final out = <String>[];
    PermissionKeyMetadataCatalog.byKey.forEach((key, meta) {
      if (!PermissionKeys.all.contains(key)) return;
      if (meta.scopeKind != PermissionScopeKind.orgWide) return;
      if (query.isNotEmpty && !meta.humanLabel.toLowerCase().contains(query)) {
        return;
      }
      out.add(key);
    });
    out.sort((a, b) {
      final la = PermissionKeyMetadataCatalog.byKey[a]?.humanLabel ?? a;
      final lb = PermissionKeyMetadataCatalog.byKey[b]?.humanLabel ?? b;
      return la.compareTo(lb);
    });
    return out;
  }

  Iterable<String> _orderedProductKeys(Iterable<String> present) {
    final seen = <String>{};
    final ordered = <String>[];
    for (final product in kRolePermissionPickerProductOrder) {
      if (present.contains(product)) {
        ordered.add(product);
        seen.add(product);
      }
    }
    final tail = present.where((p) => !seen.contains(p)).toList()..sort();
    ordered.addAll(tail);
    return ordered;
  }

  @override
  Widget build(BuildContext context) {
    final prefix = widget.keyPrefix;
    final groups = _visibleGroups();
    final hiddenOrgWide = _hiddenOrgWideKeys();
    final readOnly = widget.readOnly;
    return Container(
      key: Key('${prefix}_card'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: const BoxDecoration(
              color: AppColors.cardGlow,
              border: Border(
                bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                widget.header ??
                    Text(
                      'Permissions',
                      style: AppTextStyles.mono14(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w700,
                      ),
                    ),
                const SizedBox(height: 4),
                Text(
                  'Browse by product. Picking a permission also turns on '
                  'anything it needs (you can switch the parent off to '
                  'remove the whole set).',
                  style: AppTextStyles.body12(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: Key('${prefix}_search'),
                  controller: _searchController,
                  onChanged: (value) => setState(() => _searchQuery = value),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search permissions',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    border: const OutlineInputBorder(),
                    suffixIcon: _searchQuery.isEmpty
                        ? null
                        : IconButton(
                            key: Key('${prefix}_search_clear'),
                            icon: const Icon(Icons.close, size: 16),
                            tooltip: 'Clear search',
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          ),
                  ),
                ),
              ],
            ),
          ),
          if (_filtersOrgWide)
            _ScopeNotice(
              keyPrefix: prefix,
              hiddenKeys: hiddenOrgWide,
              expanded: _showHiddenScope,
              onToggle: () =>
                  setState(() => _showHiddenScope = !_showHiddenScope),
            ),
          if (groups.isEmpty)
            Padding(
              key: Key('${prefix}_search_empty'),
              padding: const EdgeInsets.fromLTRB(14, 18, 14, 18),
              child: Text(
                _searchQuery.isEmpty
                    ? 'No permissions available at this scope.'
                    : 'No permissions match "$_searchQuery".',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ),
          for (final product in _orderedProductKeys(groups.keys))
            _ProductSection(
              key: Key('${prefix}_product_$product'),
              keyPrefix: prefix,
              productLabel: product,
              productDisplayLabel:
                  kRolePermissionPickerProductLabels[product] ?? product,
              dormant: product == 'barrio' && !widget.barrioPlanIncluded,
              categories: groups[product]!,
              selected: widget.selected,
              explicit: widget.explicit,
              lockedPermissionKeys: widget.lockedPermissionKeys,
              readOnly: readOnly,
              onToggle: widget.onToggle,
            ),
        ],
      ),
    );
  }
}

class _ScopeNotice extends StatelessWidget {
  const _ScopeNotice({
    required this.keyPrefix,
    required this.hiddenKeys,
    required this.expanded,
    required this.onToggle,
  });

  final String keyPrefix;
  final List<String> hiddenKeys;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('${keyPrefix}_scope_notice'),
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(
                Icons.info_outline,
                size: 16,
                color: AppColors.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Some permissions don't apply below the business level and "
                  'are not shown.',
                  style: AppTextStyles.body12(color: AppColors.textSecondary),
                ),
              ),
              TextButton(
                key: Key('${keyPrefix}_scope_notice_toggle'),
                onPressed: hiddenKeys.isEmpty ? null : onToggle,
                child: Text(expanded ? 'Hide' : "What's hidden?"),
              ),
            ],
          ),
          if (expanded && hiddenKeys.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            for (final key in hiddenKeys)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Icon(
                      Icons.lock_outline,
                      size: 14,
                      color: AppColors.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Tooltip(
                        message: 'Not available at this scope',
                        child: Text(
                          PermissionKeyMetadataCatalog.byKey[key]?.humanLabel ??
                              key,
                          key: Key('${keyPrefix}_scope_hidden_$key'),
                          style: AppTextStyles.body12(
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ProductSection extends StatelessWidget {
  const _ProductSection({
    super.key,
    required this.keyPrefix,
    required this.productLabel,
    required this.productDisplayLabel,
    required this.dormant,
    required this.categories,
    required this.selected,
    required this.explicit,
    required this.lockedPermissionKeys,
    required this.readOnly,
    required this.onToggle,
  });

  final String keyPrefix;
  final String productLabel;
  final String productDisplayLabel;
  final bool dormant;
  final Map<String, List<String>> categories;
  final Set<String> selected;
  final Set<String> explicit;
  final Set<String> lockedPermissionKeys;
  final bool readOnly;
  final void Function(String key, bool selected) onToggle;

  @override
  Widget build(BuildContext context) {
    final orderedCategories = categories.keys.toList()..sort();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  productDisplayLabel,
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              if (dormant)
                Container(
                  key: Key('${keyPrefix}_dormant_$productLabel'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.10),
                    border: Border.all(
                      color: AppColors.warning.withValues(alpha: 0.45),
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Coming soon',
                    style: AppTextStyles.mono10(color: AppColors.warning),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          for (final category in orderedCategories)
            _CategorySection(
              key: Key('${keyPrefix}_category_${productLabel}_$category'),
              keyPrefix: keyPrefix,
              categoryLabel: category,
              permissionKeys: categories[category]!,
              selected: selected,
              explicit: explicit,
              lockedPermissionKeys: lockedPermissionKeys,
              readOnly: readOnly || dormant,
              onToggle: onToggle,
            ),
        ],
      ),
    );
  }
}

class _CategorySection extends StatelessWidget {
  const _CategorySection({
    super.key,
    required this.keyPrefix,
    required this.categoryLabel,
    required this.permissionKeys,
    required this.selected,
    required this.explicit,
    required this.lockedPermissionKeys,
    required this.readOnly,
    required this.onToggle,
  });

  final String keyPrefix;
  final String categoryLabel;
  final List<String> permissionKeys;
  final Set<String> selected;
  final Set<String> explicit;
  final Set<String> lockedPermissionKeys;
  final bool readOnly;
  final void Function(String key, bool selected) onToggle;

  @override
  Widget build(BuildContext context) {
    final selectedInCategory = permissionKeys.where(selected.contains).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  categoryLabel,
                  style: AppTextStyles.mono12(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '$selectedInCategory / ${permissionKeys.length}',
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final permissionKey in permissionKeys)
            _PermissionRow(
              key: Key('${keyPrefix}_perm_$permissionKey'),
              keyPrefix: keyPrefix,
              permissionKey: permissionKey,
              isSelected: selected.contains(permissionKey),
              isLocked: lockedPermissionKeys.contains(permissionKey),
              requiredBy: rolePermissionPickerRequiredBy(
                permissionKey,
                explicit,
              ),
              readOnly: readOnly,
              onToggle: onToggle,
            ),
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    super.key,
    required this.keyPrefix,
    required this.permissionKey,
    required this.isSelected,
    required this.isLocked,
    required this.requiredBy,
    required this.readOnly,
    required this.onToggle,
  });

  final String keyPrefix;
  final String permissionKey;
  final bool isSelected;
  final bool isLocked;
  final List<String> requiredBy;
  final bool readOnly;
  final void Function(String key, bool selected) onToggle;

  @override
  Widget build(BuildContext context) {
    final meta = PermissionKeyMetadataCatalog.byKey[permissionKey];
    final humanLabel = meta?.humanLabel ?? permissionKey;
    final requiresMfa = PermissionKeys.requiresMfa.contains(permissionKey);
    final isAutoAdded = isSelected && requiredBy.isNotEmpty;
    final parentLabel = requiredBy.isEmpty
        ? null
        : (PermissionKeyMetadataCatalog.byKey[requiredBy.first]?.humanLabel ??
              requiredBy.first);
    final tooltipMessage = isLocked
        ? 'Required platform safety permission'
        : isAutoAdded
        ? 'Required because $parentLabel is selected'
        : null;

    final checkboxOnChanged = readOnly || isAutoAdded || isLocked
        ? null
        : (bool? value) => onToggle(permissionKey, value ?? false);

    Widget checkbox = Checkbox(
      value: isSelected,
      onChanged: checkboxOnChanged,
      key: Key('${keyPrefix}_perm_${permissionKey}_checkbox'),
    );
    if (tooltipMessage != null) {
      checkbox = Tooltip(
        key: Key('${keyPrefix}_perm_${permissionKey}_tooltip'),
        message: tooltipMessage,
        child: checkbox,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          checkbox,
          const SizedBox(width: 4),
          Expanded(
            child: Row(
              children: <Widget>[
                Flexible(
                  child: Text(
                    humanLabel,
                    style: AppTextStyles.body13(
                      color: isAutoAdded
                          ? AppColors.textMuted
                          : AppColors.textPrimary,
                    ),
                  ),
                ),
                if (isAutoAdded) ...<Widget>[
                  const SizedBox(width: 8),
                  Container(
                    key: Key(
                      '${keyPrefix}_perm_${permissionKey}_required_chip',
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.borderSubtle,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(
                      'Required',
                      style: AppTextStyles.mono8(color: AppColors.textMuted),
                    ),
                  ),
                ],
                if (requiresMfa) ...<Widget>[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: kPermissionExplainerMfaTooltip,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.warning.withValues(alpha: 0.12),
                        border: Border.all(
                          color: AppColors.warning.withValues(alpha: 0.45),
                          width: 1,
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(
                            Icons.lock_outline,
                            size: 11,
                            color: AppColors.warning,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            'MFA',
                            style: AppTextStyles.mono8(
                              color: AppColors.warning,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
