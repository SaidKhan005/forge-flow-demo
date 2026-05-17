// Phase 7.55o.5 — Baseline Manager day detail + candidate tiles.
//
// Single-date drill-in with the underlying candidate tiles and their
// per-metric chips. Extracted from baseline_manager_screen.dart. Tap
// semantics, selection visuals, and metric labels are unchanged.

import 'package:flutter/material.dart';

import '../../domain/models/service_period_definition.dart';
import '../../domain/services/service_period_definition_resolver.dart';
import '../../models/baseline_candidate_shift.dart';
import '../../theme/app_theme.dart';
import 'baseline_manager_helpers.dart';

// ─── Day detail (single date) ─────────────────────────────────────────────────

class DayDetail extends StatelessWidget {
  final String date;
  final List<BaselineCandidateShift> candidates;
  final Set<String> draftKeys;
  final ValueChanged<String> onToggle;
  final VoidCallback onBack;

  /// Resolved, operator-configured service-period definitions (already
  /// ordered by the caller). Period grouping order comes from this,
  /// never a hardcoded `['lunch','dinner','late_night']`.
  final List<ServicePeriodDefinition> defs;

  const DayDetail({
    super.key,
    required this.date,
    required this.candidates,
    required this.draftKeys,
    required this.onToggle,
    required this.onBack,
    required this.defs,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Back control
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: GestureDetector(
            onTap: onBack,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.arrow_back_ios,
                    size: 12, color: AppColors.textMuted),
                const SizedBox(width: 4),
                Text('BACK TO CALENDAR',
                    style: AppTextStyles.mono8(color: AppColors.textMuted)),
              ],
            ),
          ),
        ),
        // Date label
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            formatDayDetailDate(date),
            style: AppTextStyles.mono11(color: AppColors.textPrimary),
          ),
        ),
        // Candidate list or empty state
        Expanded(
          child: candidates.isEmpty
              ? Center(
                  child: Text(
                    'No closed shifts for this date.',
                    style: AppTextStyles.body13(color: AppColors.textMuted),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _buildDaypartSections(),
                  ),
                ),
        ),
      ],
    );
  }

  List<Widget> _buildDaypartSections() {
    final groups = <String, List<BaselineCandidateShift>>{};
    for (final c in candidates) {
      groups.putIfAbsent(c.daypart, () => []).add(c);
    }

    final order = ServicePeriodDefinitionResolver.ordered(
      defs,
    ).map((d) => d.id).toList();
    final items = <Widget>[];

    for (final dp in order) {
      final group = groups[dp];
      if (group == null || group.isEmpty) continue;
      items.add(_daypartHeader(group.first.daypartLabel));
      for (final c in group) {
        items.add(_CandidateTile(
          candidate: c,
          isSelected: draftKeys.contains(c.recordKey),
          onToggle: () => onToggle(c.recordKey),
        ));
      }
    }

    // Unknown dayparts after known ones
    for (final entry in groups.entries) {
      if (order.contains(entry.key)) continue;
      items.add(_daypartHeader(entry.key));
      for (final c in entry.value) {
        items.add(_CandidateTile(
          candidate: c,
          isSelected: draftKeys.contains(c.recordKey),
          onToggle: () => onToggle(c.recordKey),
        ));
      }
    }

    return items;
  }

  static Widget _daypartHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Text(label.toUpperCase(),
              style: AppTextStyles.mono11(color: AppColors.textMuted)),
          const SizedBox(width: 12),
          Expanded(
            child: Container(height: 1, color: AppColors.borderSubtle),
          ),
        ],
      ),
    );
  }
}

class _CandidateTile extends StatelessWidget {
  final BaselineCandidateShift candidate;
  final bool isSelected;
  final VoidCallback onToggle;

  const _CandidateTile({
    required this.candidate,
    required this.isSelected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = isSelected
        ? AppColors.sunset.withValues(alpha: 0.7)
        : AppColors.borderSubtle;
    final bgColor = isSelected
        ? AppColors.sunset.withValues(alpha: 0.07)
        : Colors.transparent;

    return GestureDetector(
      onTap: onToggle,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: bgColor,
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Row(
          children: [
            // Selection indicator
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color:
                    isSelected ? AppColors.sunset : Colors.transparent,
                border: Border.all(
                  color: isSelected
                      ? AppColors.sunset
                      : AppColors.textMuted,
                  width: 1.5,
                ),
              ),
              child: isSelected
                  ? const Icon(Icons.check,
                      size: 12, color: AppColors.backgroundDeep)
                  : null,
            ),
            const SizedBox(width: 12),

            // Label + metrics
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    candidate.businessDate != null
                        ? '${formatDayDetailDate(candidate.businessDate!)} ${candidate.daypartLabel}'
                        : candidate.displayLabel,
                    style: AppTextStyles.mono10(
                        color: isSelected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary),
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      _MetricChip(
                        label: 'CPLH',
                        value: candidate.cplh.toStringAsFixed(2),
                        highlight: isSelected,
                      ),
                      _MetricChip(
                        label: 'COVERS',
                        value: '${candidate.covers}',
                        highlight: false,
                      ),
                      _MetricChip(
                        label: 'SPLH',
                        value: '\$${candidate.splh.toStringAsFixed(0)}',
                        highlight: false,
                      ),
                      _MetricChip(
                        label: 'PPA',
                        value: '\$${candidate.ppa.toStringAsFixed(0)}',
                        highlight: false,
                      ),
                      _MetricChip(
                        label: 'LABOR %',
                        value: candidate.hasActualLaborPctTruth
                            ? '${candidate.actualLaborPct.toStringAsFixed(1)}%'
                            : '--',
                        highlight: false,
                      ),
                      _MetricChip(
                        label: 'LEVER',
                        value: leverLabel(candidate.primaryLeverId),
                        highlight: false,
                      ),
                    ],
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

class _MetricChip extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _MetricChip({
    required this.label,
    required this.value,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: AppTextStyles.mono7(color: AppColors.textMuted)),
        Text(
          value,
          style: AppTextStyles.mono10(
              color:
                  highlight ? AppColors.sunsetDark : AppColors.textSecondary),
        ),
      ],
    );
  }
}
