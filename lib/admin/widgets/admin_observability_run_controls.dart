import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/scope_icons.dart';
import '../admin_route_handoff.dart';
import '../services/observability_admin_gateway.dart';
import 'admin_run_check_controls.dart';

class AdminObservabilityScopeNote extends StatelessWidget {
  const AdminObservabilityScopeNote({super.key, required this.scope});

  final AdminHierarchyScopeIntent scope;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_observability_scope_note'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.10),
        border: Border.all(color: AppColors.peacock, width: 1.4),
        borderRadius: BorderRadius.circular(6),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560;
          final selected = Row(
            children: <Widget>[
              Icon(
                _scopeIcon(scope.scopeType),
                size: 17,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      scope.displayLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body14(color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Selected ${scope.scopeType.label.toLowerCase()} scope',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.mono11(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              if (!compact) ...<Widget>[
                const SizedBox(width: 10),
                const _ScopeChip(
                  icon: Icons.public_outlined,
                  label: 'Hosting + graph platform-wide',
                ),
              ],
              const SizedBox(width: 8),
              const Icon(
                Icons.check_circle,
                size: 16,
                color: AppColors.peacockDark,
              ),
            ],
          );
          if (!compact) return selected;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              selected,
              const SizedBox(height: 8),
              const _ScopeChip(
                icon: Icons.public_outlined,
                label: 'Hosting + graph platform-wide',
              ),
            ],
          );
        },
      ),
    );
  }
}

class AdminObservabilityManualRunPrompt extends StatelessWidget {
  const AdminObservabilityManualRunPrompt({
    super.key,
    required this.onRunCheck,
    required this.loading,
    required this.month,
    required this.onSelectMonth,
  });

  final Future<void> Function() onRunCheck;
  final bool loading;
  final ObservabilityMonth month;
  final ValueChanged<ObservabilityMonth> onSelectMonth;

  @override
  Widget build(BuildContext context) {
    return AdminRunCheckLaunchPanel(
      key: const Key('admin_observability_manual_prompt'),
      icon: Icons.insights_outlined,
      title: 'Check AI Metrics',
      description:
          'Load cost, usage, customers, and platform signals for the selected scope.',
      buttonKey: const Key('admin_observability_refresh_button'),
      buttonLabel: 'Run metrics check',
      loadingLabel: 'Running...',
      loading: loading,
      onPressed: () {
        onRunCheck();
      },
      control: AdminObservabilityMonthSelector(
        month: month,
        onSelectMonth: onSelectMonth,
        enabled: !loading,
      ),
      cues: const <AdminRunCheckCue>[
        AdminRunCheckCue(
          icon: Icons.account_tree_outlined,
          label: 'Scope-aware',
        ),
        AdminRunCheckCue(
          icon: Icons.calendar_month_outlined,
          label: 'Month view',
        ),
        AdminRunCheckCue(icon: Icons.visibility_outlined, label: 'Read-only'),
      ],
    );
  }
}

IconData _scopeIcon(AdminHierarchyScopeType type) {
  switch (type) {
    case AdminHierarchyScopeType.business:
      return scopeIcon(kind: ScopeEntityKind.business);
    case AdminHierarchyScopeType.orgUnit:
      return scopeIcon(kind: ScopeEntityKind.orgUnit);
    case AdminHierarchyScopeType.location:
      return scopeIcon(kind: ScopeEntityKind.location);
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 15, color: AppColors.sunsetDark),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.chipLabel(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class AdminObservabilityMonthSelector extends StatelessWidget {
  const AdminObservabilityMonthSelector({
    super.key,
    required this.month,
    required this.onSelectMonth,
    required this.enabled,
  });

  final ObservabilityMonth month;
  final ValueChanged<ObservabilityMonth> onSelectMonth;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_observability_month_selector'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _MonthSegment(
            keyName: 'admin_observability_month_current',
            label: 'This month',
            selected: month == ObservabilityMonth.current,
            enabled: enabled,
            onTap: () => onSelectMonth(ObservabilityMonth.current),
          ),
          _MonthSegment(
            keyName: 'admin_observability_month_previous',
            label: 'Last month',
            selected: month == ObservabilityMonth.previous,
            enabled: enabled,
            onTap: () => onSelectMonth(ObservabilityMonth.previous),
          ),
        ],
      ),
    );
  }
}

class _MonthSegment extends StatelessWidget {
  const _MonthSegment({
    required this.keyName,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String keyName;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: Key(keyName),
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.sunset : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: AppTextStyles.body12(
            color: selected
                ? AppColors.backgroundSurface
                : AppColors.textSecondary,
          ).copyWith(fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
        ),
      ),
    );
  }
}
