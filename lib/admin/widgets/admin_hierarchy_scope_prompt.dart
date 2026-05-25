import 'package:flutter/material.dart';

import '../../operator_web/widgets/hierarchy_map_picker.dart';
import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../admin_route_handoff.dart';

/// Admin scope-prompt — Wave 2 H-3 hierarchy-map variant.
///
/// Renders a hierarchy-map tree (Business → Org units → Locations)
/// derived from the flat [scopes] list the screen passes in. Each scope
/// becomes a [HierarchyMapNode] keyed by its
/// `AdminHierarchyScopeIntent.cacheKey`. The tree groups locations
/// under their `orgUnitId` parent (or directly under the business
/// scope when the location has no orgUnit). Inheritance + effective
/// chips render alongside the selected scope so the operator keeps
/// the HP #11 signal (scope / inherited / effective).
class AdminHierarchyScopePrompt extends StatelessWidget {
  const AdminHierarchyScopePrompt({
    super.key,
    required this.surfaceName,
    required this.scopes,
    required this.onScopeSelected,
    this.selectedScope,
    this.onCancel,
  });

  final String surfaceName;
  final List<AdminHierarchyScopeIntent> scopes;
  final AdminHierarchyScopeIntent? selectedScope;
  final ValueChanged<AdminHierarchyScopeIntent> onScopeSelected;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final selected = selectedScope;
    // `selected` is forwarded to `_AdminScopeHierarchyMap` so the
    // matching tree row renders highlighted; chip / breadcrumb data
    // travels with each `HierarchyMapNode`.
    return Container(
      key: const Key('admin_hierarchy_scope_prompt'),
      constraints: const BoxConstraints(maxWidth: 720),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.account_tree_outlined,
                color: AppColors.sunsetDark,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Choose scope for $surfaceName',
                  style: AppTextStyles.sectionTitle(
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Business settings inherit down through org units to locations. '
            'Lower configured scopes override higher scopes. The picker '
            'mirrors your hierarchy so you can pick by structure, not by '
            'an alphabetical list.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          if (scopes.isEmpty)
            const _EmptyScopeState()
          else
            _AdminScopeHierarchyMap(
              scopes: scopes,
              selectedScope: selected,
              onScopeSelected: onScopeSelected,
            ),
          if (onCancel != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton(
                key: const Key('admin_hierarchy_scope_prompt_cancel'),
                style: AdminButtonStyles.secondary(minWidth: 96),
                onPressed: onCancel,
                child: const Text('Cancel'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Card-shaped tree wrapping [HierarchyMapPicker] for the admin
/// scope-prompt surface. Renders the tree inline (no popover) — the
/// admin prompt IS the popover analog at the screen level, so the
/// shared widget mounts in always-open mode by passing a fixed shell
/// around the inner tree.
class _AdminScopeHierarchyMap extends StatefulWidget {
  const _AdminScopeHierarchyMap({
    required this.scopes,
    required this.selectedScope,
    required this.onScopeSelected,
  });

  final List<AdminHierarchyScopeIntent> scopes;
  final AdminHierarchyScopeIntent? selectedScope;
  final ValueChanged<AdminHierarchyScopeIntent> onScopeSelected;

  @override
  State<_AdminScopeHierarchyMap> createState() =>
      _AdminScopeHierarchyMapState();
}

class _AdminScopeHierarchyMapState extends State<_AdminScopeHierarchyMap> {
  @override
  Widget build(BuildContext context) {
    final scopesByKey = <String, AdminHierarchyScopeIntent>{};
    for (final scope in widget.scopes) {
      scopesByKey[scope.cacheKey] = scope;
    }
    final nodes = <HierarchyMapNode>[];
    String? businessKey;
    for (final scope in widget.scopes) {
      if (scope.isBusinessScope) {
        businessKey = scope.cacheKey;
        break;
      }
    }
    for (final scope in widget.scopes) {
      String? parentId;
      HierarchyMapNodeKind kind;
      switch (scope.scopeType) {
        case AdminHierarchyScopeType.business:
          parentId = null;
          kind = HierarchyMapNodeKind.business;
          break;
        case AdminHierarchyScopeType.orgUnit:
          parentId = businessKey;
          kind = HierarchyMapNodeKind.orgUnit;
          break;
        case AdminHierarchyScopeType.location:
          // Locations point at their orgUnit parent when known; fall
          // back to the business root so the tree is always connected.
          parentId = _findOrgUnitParentKey(
                widget.scopes,
                scope.operatorId,
                scope.orgUnitId,
              ) ??
              businessKey;
          kind = HierarchyMapNodeKind.location;
          break;
      }
      nodes.add(
        HierarchyMapNode(
          id: scope.cacheKey,
          label: scope.displayLabel,
          helper: scope.scopeType.label,
          kind: kind,
          parentId: parentId,
          inheritanceBreadcrumb: _breadcrumbForScope(scope),
          statusChips: <String>[
            scope.inheritanceLabel,
            if (scope.effectiveValueLabel != null)
              'Effective: ${scope.effectiveValueLabel}',
            if (scope.allowedActionsLabel != null)
              scope.allowedActionsLabel!,
          ],
        ),
      );
    }
    return Container(
      key: const Key('admin_hierarchy_scope_prompt_map_container'),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep.withValues(alpha: 0.32),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      // The admin scope-prompt IS the screen-level scope chooser
      // (rendered as a card, not a popover trigger). Use the inline
      // tree body so the tree is always visible — operators see every
      // available branch without an extra click — while sharing the
      // same hierarchy-map widget shape as the operator-web popover.
      child: HierarchyMapTreeBody(
        keyPrefix: 'admin_hierarchy_scope_map',
        nodes: nodes,
        selectedId: widget.selectedScope?.cacheKey,
        // Every kind selects in admin (business / orgUnit / location).
        allowNonLocationSelection: true,
        // Preserve the legacy per-row test key
        // `admin_hierarchy_scope_option_<cacheKey>` so existing tests
        // that tap the row directly keep working after the H-3 refactor.
        nodeKeyResolver: (nodeId) =>
            Key('admin_hierarchy_scope_option_$nodeId'),
        onNodeTap: (node) {
          final scope = scopesByKey[node.id];
          if (scope == null) return;
          widget.onScopeSelected(scope);
        },
      ),
    );
  }

  static String? _findOrgUnitParentKey(
    List<AdminHierarchyScopeIntent> scopes,
    String operatorId,
    String? orgUnitId,
  ) {
    if (orgUnitId == null || orgUnitId.isEmpty) return null;
    for (final candidate in scopes) {
      if (candidate.isOrgUnitScope &&
          candidate.operatorId == operatorId &&
          candidate.orgUnitId == orgUnitId) {
        return candidate.cacheKey;
      }
    }
    return null;
  }

  static String? _breadcrumbForScope(AdminHierarchyScopeIntent scope) {
    switch (scope.scopeType) {
      case AdminHierarchyScopeType.business:
        return 'Business-wide. Every org unit and location inherits '
            'these defaults unless they set their own.';
      case AdminHierarchyScopeType.orgUnit:
        return 'Inherits business defaults. Locations under this group '
            'inherit values you set here.';
      case AdminHierarchyScopeType.location:
        return null;
    }
  }
}


class AdminHierarchyScopeBanner extends StatelessWidget {
  const AdminHierarchyScopeBanner({
    super.key,
    required this.scope,
    required this.surfaceName,
    required this.onChangeScope,
    this.onClear,
  });

  final AdminHierarchyScopeIntent scope;
  final String surfaceName;
  final VoidCallback onChangeScope;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_hierarchy_scope_banner'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.peacock.withValues(alpha: 0.35),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final text = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                scope.displayLabel,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body14(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  AdminHierarchyScopeStatusChip(label: scope.inheritanceLabel),
                  if (scope.effectiveValueLabel != null)
                    AdminHierarchyScopeStatusChip(
                      label: 'Effective: ${scope.effectiveValueLabel}',
                    ),
                  if (scope.allowedActionsLabel != null)
                    AdminHierarchyScopeStatusChip(
                      label: scope.allowedActionsLabel!,
                    ),
                ],
              ),
            ],
          );
          final actions = Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('admin_hierarchy_scope_change'),
                style: AdminButtonStyles.secondary(
                  foregroundColor: AppColors.peacockDark,
                  borderColor: AppColors.peacock.withValues(alpha: 0.55),
                  minWidth: 126,
                  minHeight: 36,
                ),
                onPressed: onChangeScope,
                icon: const Icon(Icons.account_tree_outlined, size: 14),
                label: const Text('Change scope'),
              ),
              if (onClear != null)
                OutlinedButton.icon(
                  key: const Key('admin_hierarchy_scope_clear'),
                  style: AdminButtonStyles.secondary(
                    foregroundColor: AppColors.peacockDark,
                    borderColor: AppColors.peacock.withValues(alpha: 0.55),
                    minWidth: 100,
                    minHeight: 36,
                  ),
                  onPressed: onClear,
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 14),
                  label: const Text('Show all'),
                ),
            ],
          );
          if (constraints.maxWidth < 640) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [text, const SizedBox(height: 10), actions],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: text),
              const SizedBox(width: 12),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class AdminHierarchyScopeStatusChip extends StatelessWidget {
  const AdminHierarchyScopeStatusChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('admin_hierarchy_scope_chip_${_keySafe(label)}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep.withValues(alpha: 0.82),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.chipLabel(color: AppColors.textSecondary),
      ),
    );
  }
}

class _EmptyScopeState extends StatelessWidget {
  const _EmptyScopeState();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_hierarchy_scope_prompt_empty'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'No hierarchy scopes are available for this business yet.',
        style: AppTextStyles.body13(color: AppColors.textSecondary),
      ),
    );
  }
}

String _keySafe(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
}
