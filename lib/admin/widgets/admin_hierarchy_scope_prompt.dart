import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../admin_route_handoff.dart';

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
            'Lower configured scopes override higher scopes.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          Flexible(
            child: SingleChildScrollView(
              child: scopes.isEmpty
                  ? const _EmptyScopeState()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final scope in scopes)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _ScopeOption(
                              scope: scope,
                              selected: scope == selectedScope,
                              onTap: () => onScopeSelected(scope),
                            ),
                          ),
                      ],
                    ),
            ),
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
                'Showing $surfaceName for ${scope.scopeType.label.toLowerCase()} scope',
                style: AppTextStyles.uiLabel(color: AppColors.peacockDark),
              ),
              const SizedBox(height: 2),
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

class _ScopeOption extends StatelessWidget {
  const _ScopeOption({
    required this.scope,
    required this.selected,
    required this.onTap,
  });

  final AdminHierarchyScopeIntent scope;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final borderColor = selected
        ? AppColors.sunset.withValues(alpha: 0.62)
        : AppColors.borderSubtle;
    return Material(
      color: selected
          ? AppColors.sunset.withValues(alpha: 0.08)
          : AppColors.backgroundDeep.withValues(alpha: 0.56),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: Key('admin_hierarchy_scope_option_${scope.cacheKey}'),
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: borderColor, width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_iconFor(scope.scopeType), size: 18, color: borderColor),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      scope.scopeType.label,
                      style: AppTextStyles.uiLabel(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      scope.displayLabel,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body14(color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        AdminHierarchyScopeStatusChip(
                          label: scope.inheritanceLabel,
                        ),
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
                ),
              ),
              if (selected)
                const Icon(
                  Icons.check_circle,
                  size: 18,
                  color: AppColors.sunsetDark,
                ),
            ],
          ),
        ),
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

IconData _iconFor(AdminHierarchyScopeType type) {
  switch (type) {
    case AdminHierarchyScopeType.business:
      return Icons.business_outlined;
    case AdminHierarchyScopeType.orgUnit:
      return Icons.account_tree_outlined;
    case AdminHierarchyScopeType.location:
      return Icons.storefront_outlined;
  }
}

String _keySafe(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
}
