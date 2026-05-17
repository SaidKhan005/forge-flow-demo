// Choose Star Shifts R2: tap-day bottom sheet.
//
// Replaces the old full-screen day-detail PUSH navigation with a
// `showModalBottomSheet` overlay. Tapping a calendar day opens this
// sheet in place; there is no route change.
//
// Two variants, driven by the active lens:
//
//  - A specific service period: one shift for that day + period, the
//    metric set (CPLH, COVERS, SPLH, PPA, LABOR %, LEVER), and a single
//    Select / Remove action that toggles that shift's recordKey then
//    closes the sheet.
//
//  - Whole day: a cover-weighted whole-day rollup for that date (display
//    only, mirroring TargetCycleDaypartPool.fromDayparts cover-weighting)
//    plus a per-service breakdown list. Each service row has a
//    keep/remove toggle; the sheet stays open while the operator works
//    multiple services and a Close action dismisses it.
//
// Selection still flows ONLY by mutating the screen's draft set through
// the existing onToggle callback. Nothing here persists or recomputes a
// target. The rollup is a read-only summary.

import 'package:flutter/material.dart';

import '../../domain/models/service_period_definition.dart';
import '../../domain/services/service_period_definition_resolver.dart';
import '../../models/baseline_candidate_shift.dart';
import '../../services/labor_model.dart';
import '../../theme/app_theme.dart';
import 'baseline_manager_helpers.dart';
import 'baseline_manager_lens.dart';

/// Cover-weighted whole-day rollup for a single date.
///
/// Display only. The cover-weighting shape is a deliberate mirror of
/// [TargetCycleDaypartPool.fromDayparts] (Design Rule 4): covers sum,
/// CPLH/SPLH/PPA cover-weighted, with an unweighted-mean fallback when
/// every service has zero covers so a stable scalar is still shown
/// instead of dividing by zero. This class never persists anything and
/// is not on the target write path; the only selection mechanism stays
/// the draft-set toggle.
///
/// Labor % is derived from the rolled-up rates via
/// [LaborModel.theoreticalLaborPct] using the WHOLE-DAY wage pair
/// (Design Rule 5). It never uses a per-period or cover-weighted wage;
/// the same single FOH/BOH wage authority applies across every service.
class WholeDayRollup {
  final int totalCovers;
  final double cplh;
  final double splh;
  final double ppa;

  /// Whole-day labor %, or null when wage authority is unavailable or
  /// the rolled rates are degenerate (honest unknown, never a phantom
  /// zero).
  final double? laborPct;

  const WholeDayRollup({
    required this.totalCovers,
    required this.cplh,
    required this.splh,
    required this.ppa,
    required this.laborPct,
  });

  /// Build from a single day's per-service shifts.
  ///
  /// [fohWage] / [bohWage] are the WHOLE-DAY wage authority (one pair,
  /// not per period). When null the labor % is reported as unknown
  /// rather than guessed.
  static WholeDayRollup fromShifts(
    List<BaselineCandidateShift> shifts, {
    required double? fohWage,
    required double? bohWage,
  }) {
    final totalCovers = shifts.fold<int>(0, (s, c) => s + c.covers);
    double cplh = 0;
    double splh = 0;
    double ppa = 0;
    if (shifts.isEmpty) {
      return const WholeDayRollup(
        totalCovers: 0,
        cplh: 0,
        splh: 0,
        ppa: 0,
        laborPct: null,
      );
    }
    if (totalCovers > 0) {
      // Cover-weighted: exactly the TargetCycleDaypartPool shape.
      for (final c in shifts) {
        final w = c.covers / totalCovers;
        cplh += c.cplh * w;
        splh += c.splh * w;
        ppa += c.ppa * w;
      }
    } else {
      // Zero covers across every service: unweighted mean keeps the
      // summary honest instead of dividing by zero. Mirrors the
      // TargetCycleDaypartPool zero-covers fallback.
      for (final c in shifts) {
        cplh += c.cplh;
        splh += c.splh;
        ppa += c.ppa;
      }
      final n = shifts.length;
      cplh /= n;
      splh /= n;
      ppa /= n;
    }

    double? laborPct;
    if (fohWage != null && bohWage != null) {
      final pct = LaborModel.theoreticalLaborPct(
        cplh,
        splh,
        ppa,
        fohWage,
        bohWage,
      );
      // theoreticalLaborPct returns 0 for degenerate rates; surface that
      // as an honest unknown rather than a phantom 0.0%.
      laborPct = pct > 0 ? pct : null;
    }

    return WholeDayRollup(
      totalCovers: totalCovers,
      cplh: cplh,
      splh: splh,
      ppa: ppa,
      laborPct: laborPct,
    );
  }
}

/// Opens the tap-day bottom sheet for [date]. This is a
/// [showModalBottomSheet] overlay, not a route push: the calendar stays
/// mounted underneath.
///
/// [selectedLensId] is the active lens. [kWholeDayLensId] shows the
/// whole-day rollup + per-service breakdown; any period id shows that
/// single period's shift.
///
/// [onToggle] toggles a recordKey in the screen's draft set (the only
/// selection mechanism). [isSelected] reads the current draft state so
/// the sheet reflects live toggles.
Future<void> showBaselineDayBottomSheet({
  required BuildContext context,
  required String date,
  required List<BaselineCandidateShift> dayShifts,
  required String selectedLensId,
  required List<ServicePeriodDefinition> defs,
  required bool Function(String recordKey) isSelected,
  required void Function(String recordKey) onToggle,
  double? fohWage,
  double? bohWage,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.backgroundDeep,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (sheetContext) {
      return _DaySheetBody(
        date: date,
        dayShifts: dayShifts,
        selectedLensId: selectedLensId,
        defs: defs,
        isSelected: isSelected,
        onToggle: onToggle,
        fohWage: fohWage,
        bohWage: bohWage,
      );
    },
  );
}

class _DaySheetBody extends StatefulWidget {
  final String date;
  final List<BaselineCandidateShift> dayShifts;
  final String selectedLensId;
  final List<ServicePeriodDefinition> defs;
  final bool Function(String recordKey) isSelected;
  final void Function(String recordKey) onToggle;
  final double? fohWage;
  final double? bohWage;

  const _DaySheetBody({
    required this.date,
    required this.dayShifts,
    required this.selectedLensId,
    required this.defs,
    required this.isSelected,
    required this.onToggle,
    required this.fohWage,
    required this.bohWage,
  });

  @override
  State<_DaySheetBody> createState() => _DaySheetBodyState();
}

class _DaySheetBodyState extends State<_DaySheetBody> {
  bool _isPeriodSelected(String recordKey) => widget.isSelected(recordKey);

  void _toggle(String recordKey) {
    widget.onToggle(recordKey);
    // Re-read on the next frame so the sheet reflects the live draft.
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isWholeDay = widget.selectedLensId == kWholeDayLensId;
    final media = MediaQuery.of(context);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: media.size.height * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Grab handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppColors.borderSubtle,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Flexible(
                child: isWholeDay
                    ? _WholeDaySheet(
                        date: widget.date,
                        dayShifts: widget.dayShifts,
                        defs: widget.defs,
                        isSelected: _isPeriodSelected,
                        onToggle: _toggle,
                        fohWage: widget.fohWage,
                        bohWage: widget.bohWage,
                      )
                    : _PeriodSheet(
                        date: widget.date,
                        dayShifts: widget.dayShifts,
                        selectedLensId: widget.selectedLensId,
                        defs: widget.defs,
                        isSelected: _isPeriodSelected,
                        onToggle: (recordKey) {
                          widget.onToggle(recordKey);
                          Navigator.of(context).pop();
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Period-lens variant ──────────────────────────────────────────────────────

class _PeriodSheet extends StatelessWidget {
  final String date;
  final List<BaselineCandidateShift> dayShifts;
  final String selectedLensId;
  final List<ServicePeriodDefinition> defs;
  final bool Function(String recordKey) isSelected;
  final void Function(String recordKey) onToggle;

  const _PeriodSheet({
    required this.date,
    required this.dayShifts,
    required this.selectedLensId,
    required this.defs,
    required this.isSelected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final periodLabel =
        ServicePeriodDefinitionResolver.labelForId(defs, selectedLensId);
    final matches =
        dayShifts.where((c) => c.daypart == selectedLensId).toList();

    if (matches.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${formatDayDetailDate(date)} $periodLabel',
            style: AppTextStyles.mono11(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 16),
          Text(
            'No closed $periodLabel shift for this date.',
            style: AppTextStyles.body13(color: AppColors.textMuted),
          ),
          const SizedBox(height: 16),
          _CloseAction(onTap: () => Navigator.of(context).pop()),
        ],
      );
    }

    // Per the lens contract a period day has a single shift; if data
    // ever carries more, render each so nothing is hidden.
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${formatDayDetailDate(date)} $periodLabel',
            style: AppTextStyles.mono11(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 12),
          for (final c in matches)
            _PeriodMetricCard(
              candidate: c,
              selected: isSelected(c.recordKey),
              onPrimaryAction: () => onToggle(c.recordKey),
            ),
        ],
      ),
    );
  }
}

class _PeriodMetricCard extends StatelessWidget {
  final BaselineCandidateShift candidate;
  final bool selected;
  final VoidCallback onPrimaryAction;

  const _PeriodMetricCard({
    required this.candidate,
    required this.selected,
    required this.onPrimaryAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.sunset.withValues(alpha: 0.07)
            : AppColors.backgroundMid,
        border: Border.all(
          color: selected
              ? AppColors.sunset.withValues(alpha: 0.7)
              : AppColors.borderSubtle,
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 10,
            children: [
              _SheetMetric(
                label: 'CPLH',
                value: candidate.cplh.toStringAsFixed(2),
              ),
              _SheetMetric(
                label: 'COVERS',
                value: '${candidate.covers}',
              ),
              _SheetMetric(
                label: 'SPLH',
                value: '\$${candidate.splh.toStringAsFixed(0)}',
              ),
              _SheetMetric(
                label: 'PPA',
                value: '\$${candidate.ppa.toStringAsFixed(0)}',
              ),
              _SheetMetric(
                label: 'LABOR %',
                value: candidate.hasActualLaborPctTruth
                    ? '${candidate.actualLaborPct.toStringAsFixed(1)}%'
                    : '--',
              ),
              _SheetMetric(
                label: 'LEVER',
                value: leverLabel(candidate.primaryLeverId),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _PrimaryActionButton(
            label: selected ? 'REMOVE' : 'SELECT',
            onTap: onPrimaryAction,
          ),
        ],
      ),
    );
  }
}

// ─── Whole-day variant ────────────────────────────────────────────────────────

class _WholeDaySheet extends StatelessWidget {
  final String date;
  final List<BaselineCandidateShift> dayShifts;
  final List<ServicePeriodDefinition> defs;
  final bool Function(String recordKey) isSelected;
  final void Function(String recordKey) onToggle;
  final double? fohWage;
  final double? bohWage;

  const _WholeDaySheet({
    required this.date,
    required this.dayShifts,
    required this.defs,
    required this.isSelected,
    required this.onToggle,
    required this.fohWage,
    required this.bohWage,
  });

  @override
  Widget build(BuildContext context) {
    final rollup = WholeDayRollup.fromShifts(
      dayShifts,
      fohWage: fohWage,
      bohWage: bohWage,
    );

    // One row per configured period that has a shift this day, in the
    // operator-configured order. Period order/labels/count come only
    // from the resolved defs, never a hardcoded daypart list.
    final orderedIds =
        ServicePeriodDefinitionResolver.ordered(defs).map((d) => d.id).toList();
    final byPeriod = <String, List<BaselineCandidateShift>>{};
    for (final c in dayShifts) {
      byPeriod.putIfAbsent(c.daypart, () => []).add(c);
    }
    final rowPeriods = <String>[
      ...orderedIds.where(byPeriod.containsKey),
      // Any period present in data but not in the configured order, kept
      // visible so nothing is silently dropped.
      ...byPeriod.keys.where((k) => !orderedIds.contains(k)),
    ];

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatDayDetailDate(date),
            style: AppTextStyles.mono11(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            'Whole day rollup',
            style: AppTextStyles.mono8(color: AppColors.textMuted),
          ),
          const SizedBox(height: 12),
          if (dayShifts.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No closed shifts for this date.',
                style: AppTextStyles.body13(color: AppColors.textMuted),
              ),
            )
          else ...[
            _RollupCard(rollup: rollup),
            const SizedBox(height: 16),
            Text(
              'BY SERVICE',
              style: AppTextStyles.mono7(color: AppColors.textMuted),
            ),
            const SizedBox(height: 8),
            for (final periodId in rowPeriods)
              for (final c in byPeriod[periodId]!)
                _ServiceBreakdownRow(
                  periodLabel: ServicePeriodDefinitionResolver.labelForId(
                    defs,
                    periodId,
                  ),
                  candidate: c,
                  selected: isSelected(c.recordKey),
                  onToggle: () => onToggle(c.recordKey),
                ),
          ],
          const SizedBox(height: 16),
          _CloseAction(onTap: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }
}

class _RollupCard extends StatelessWidget {
  final WholeDayRollup rollup;

  const _RollupCard({required this.rollup});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('whole_day_rollup_card'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundMid, AppColors.backgroundDeep],
        ),
        border: Border.all(color: AppColors.borderStrong, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Wrap(
        spacing: 18,
        runSpacing: 10,
        children: [
          _SheetMetric(
            label: 'COVERS',
            value: '${rollup.totalCovers}',
          ),
          _SheetMetric(
            label: 'CPLH',
            value: rollup.cplh.toStringAsFixed(2),
            highlight: true,
          ),
          _SheetMetric(
            label: 'SPLH',
            value: '\$${rollup.splh.toStringAsFixed(0)}',
          ),
          _SheetMetric(
            label: 'PPA',
            value: '\$${rollup.ppa.toStringAsFixed(0)}',
          ),
          _SheetMetric(
            label: 'LABOR %',
            value: rollup.laborPct != null
                ? '${rollup.laborPct!.toStringAsFixed(1)}%'
                : '--',
          ),
        ],
      ),
    );
  }
}

class _ServiceBreakdownRow extends StatelessWidget {
  final String periodLabel;
  final BaselineCandidateShift candidate;
  final bool selected;
  final VoidCallback onToggle;

  const _ServiceBreakdownRow({
    required this.periodLabel,
    required this.candidate,
    required this.selected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onToggle,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.sunset.withValues(alpha: 0.07)
              : Colors.transparent,
          border: Border.all(
            color: selected
                ? AppColors.sunset.withValues(alpha: 0.7)
                : AppColors.borderSubtle,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: selected ? AppColors.sunset : Colors.transparent,
                border: Border.all(
                  color: selected ? AppColors.sunset : AppColors.textMuted,
                  width: 1.5,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check,
                      size: 12, color: AppColors.backgroundDeep)
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    periodLabel,
                    style: AppTextStyles.mono10(
                      color: selected
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      Text('CPLH ',
                          style:
                              AppTextStyles.mono7(color: AppColors.textMuted)),
                      Text(
                        candidate.cplh.toStringAsFixed(2),
                        style: AppTextStyles.mono10(
                            color: AppColors.textSecondary),
                      ),
                      const SizedBox(width: 14),
                      Text('COVERS ',
                          style:
                              AppTextStyles.mono7(color: AppColors.textMuted)),
                      Text(
                        '${candidate.covers}',
                        style: AppTextStyles.mono10(
                            color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Text(
              selected ? 'REMOVE' : 'KEEP',
              style: AppTextStyles.mono8(
                color: selected ? AppColors.sunset : AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Shared sheet widgets ─────────────────────────────────────────────────────

class _SheetMetric extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _SheetMetric({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: AppTextStyles.mono7(color: AppColors.textMuted)),
        const SizedBox(height: 3),
        Text(
          value,
          style: AppTextStyles.mono14(
            color: highlight ? AppColors.sunsetDark : AppColors.textSecondary,
            weight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _PrimaryActionButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _PrimaryActionButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.sunset.withValues(alpha: 0.18),
          border: Border.all(color: AppColors.sunset, width: 1),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: AppTextStyles.mono8(color: AppColors.sunset),
        ),
      ),
    );
  }
}

class _CloseAction extends StatelessWidget {
  final VoidCallback onTap;

  const _CloseAction({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            'CLOSE',
            style: AppTextStyles.mono8(color: AppColors.textMuted),
          ),
        ),
      ),
    );
  }
}
