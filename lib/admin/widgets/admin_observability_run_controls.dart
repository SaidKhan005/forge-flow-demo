import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../admin_human_labels.dart';
import '../services/observability_admin_gateway.dart';
import 'admin_run_check_controls.dart';

class AdminObservabilityManualRunPrompt extends StatelessWidget {
  const AdminObservabilityManualRunPrompt({
    super.key,
    required this.onRunCheck,
    required this.loading,
    required this.month,
    required this.onSelectMonth,
    required this.useCase,
    required this.onSelectUseCase,
  });

  final Future<void> Function() onRunCheck;
  final bool loading;
  final ObservabilityMonth month;
  final ValueChanged<ObservabilityMonth> onSelectMonth;

  /// Selected use-case `query_class` (null = All). Selectable before the
  /// first run so the eventual fetched view opens already scoped.
  final String? useCase;
  final ValueChanged<String?> onSelectUseCase;

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
      control: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          AdminObservabilityMonthSelector(
            month: month,
            onSelectMonth: onSelectMonth,
            enabled: !loading,
          ),
          AdminObservabilityUseCaseSelector(
            selected: useCase,
            onSelect: onSelectUseCase,
            enabled: !loading,
          ),
        ],
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

/// Sentinel menu value for the "All" choice. `PopupMenuButton` treats a
/// `null` selection as a dismissal and never fires `onSelected`, so "All"
/// carries this non-null sentinel internally and is mapped back to `null`
/// (the screen's "no filter") in [AdminObservabilityUseCaseSelector].
const String _kUseCaseAllValue = '__all__';

/// Whole-page "Use case" filter. Mirrors the mockup's `Use case: All ▾`
/// drop chip: a surface-background chip with a subtle border, the
/// selected value in `sunsetDark` bold, and a caret. `null` = All.
///
/// Filtering is client-side in the screen against the already-fetched
/// envelope (every class's rows are present), so selecting a value does
/// NOT re-fetch.
class AdminObservabilityUseCaseSelector extends StatelessWidget {
  const AdminObservabilityUseCaseSelector({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.enabled,
  });

  /// Selected `query_class` id, or null for "All".
  final String? selected;
  final ValueChanged<String?> onSelect;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final valueLabel = selected == null
        ? 'All'
        : adminRequestUseCaseLabel(selected!);
    return PopupMenuButton<String>(
      key: const Key('admin_observability_use_case_selector'),
      tooltip: 'Filter by kind of AI work',
      enabled: enabled,
      color: AppColors.backgroundSurface,
      onSelected: (value) =>
          onSelect(value == _kUseCaseAllValue ? null : value),
      itemBuilder: (_) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          key: const Key('admin_observability_use_case_all'),
          value: _kUseCaseAllValue,
          child: Text(
            'All',
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
        ),
        for (final useCase in adminRequestUseCases)
          PopupMenuItem<String>(
            key: Key('admin_observability_use_case_${useCase.id}'),
            value: useCase.id,
            child: Text(
              useCase.label,
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
          ),
      ],
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.backgroundSurface,
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(9),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Use case: ',
              style: AppTextStyles.body12(color: AppColors.textSecondary),
            ),
            Flexible(
              child: Text(
                valueLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body13(
                  color: AppColors.sunsetDark,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact muted note that names why a panel/tab does not change with the
/// use-case filter (the data is per-business or platform-wide). Used at
/// the top of the Customers, Reliability, and Knowledge tabs when a use
/// case is selected. Lives here to conserve screen lines.
class AdminObservabilityScopeNote extends StatelessWidget {
  const AdminObservabilityScopeNote({
    super.key,
    required this.message,
  });

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.info_outline,
            size: 15,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}
