import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../services/observability_admin_gateway.dart';
import 'admin_run_check_controls.dart';

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
          'See advisor spend, customer activity, reliability, and usage in one place.',
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
      cues: const <AdminRunCheckCue>[],
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
