// Phase 7.55o.5 — Baseline Manager preview model + panel.
//
// Houses [ManagerOverridePlanPreview] (the draft plan-impact model)
// and the preview panel / plan-impact section / preview-cell widgets
// that render it. Extracted from baseline_manager_screen.dart as part
// of the 7.55o.5 shell split. Preview formulas are unchanged; this is
// a structural move.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/active_target_profile_notifier.dart';
import '../../domain/constants/app_defaults.dart';
import '../../services/schedule_plan_read_service.dart';
import '../../domain/models/active_target_profile.dart';
import '../../models/baseline_candidate_shift.dart';
import '../../services/labor_model.dart';
import '../../theme/app_theme.dart';
import 'baseline_manager_lens.dart';

// ─── Plan impact preview model ───────────────────────────────────────────────
// Computed from the draft selected shifts through SchedulePlanReadService.
// Plan-owned values (covers / sales / required hours) flow through the shared
// plan authority, while benchmark-owned values (theoretical labor % / blended
// wage) are read from the canonical benchmark seam formulas using the same
// draft target inputs and wage authority.

class ManagerOverridePlanPreview {
  final int forecastCovers;
  final String coversSourceLabel;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;
  final double theoreticalLaborPct;
  final double targetBlendedWage;

  const ManagerOverridePlanPreview({
    required this.forecastCovers,
    required this.coversSourceLabel,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.theoreticalLaborPct,
    required this.targetBlendedWage,
  });

  /// Build from the current draft selected shifts.
  ///
  /// [historicalWeeklyAvgCovers] must come from the canonical
  /// [DemandForecastContext], not from `BaselineData`. The caller loads
  /// it once during init and passes it here for synchronous preview.
  ///
  /// Production callers should also pass wage-authority values from the
  /// current [ActiveTargetProfile]. The config fallback remains as a
  /// compatibility default for tests and detached preview callers that
  /// do not have the provider tree in scope.
  ///
  /// Routes through [SchedulePlanReadService.resolveFromInputs] so all
  /// plan consumers share the same resolver pipeline.
  ///
  /// Returns null when no shifts are selected or demand is unavailable.
  static ManagerOverridePlanPreview? fromDraftSelection(
    List<BaselineCandidateShift> selected, {
    required int? historicalWeeklyAvgCovers,
    double fohWage = MeridianConfig.fohWage,
    double bohWage = MeridianConfig.bohWage,
  }) {
    if (selected.isEmpty) return null;

    final count = selected.length;
    final draftCPLH = selected.fold(0.0, (s, c) => s + c.cplh) / count;
    final draftSPLH = selected.fold(0.0, (s, c) => s + c.splh) / count;
    final draftPPA = selected.fold(0.0, (s, c) => s + c.ppa) / count;

    // Resolve through the shared plan authority.
    final plan = SchedulePlanReadService.resolveFromInputs(
      targetCPLH: draftCPLH,
      targetPPA: draftPPA,
      targetSPLH: draftSPLH,
      fohWage: fohWage,
      bohWage: bohWage,
      historicalWeeklyAvgCovers: historicalWeeklyAvgCovers,
    );

    if (plan == null) return null;

    final previewTheoreticalLaborPct = LaborModel.theoreticalLaborPct(
      draftCPLH,
      draftSPLH,
      draftPPA,
      fohWage,
      bohWage,
    );
    final previewTargetBlendedWage = ActiveTargetProfile.computeTargetBlendedWage(
      targetCPLH: draftCPLH,
      targetSPLH: draftSPLH,
      targetPPA: draftPPA,
      fohWage: fohWage,
      bohWage: bohWage,
    );

    return ManagerOverridePlanPreview(
      forecastCovers: plan.forecastCovers,
      coversSourceLabel: plan.coversSourceLabel,
      forecastSales: plan.forecastSales,
      requiredFohHours: plan.requiredFohHours,
      requiredBohHours: plan.requiredBohHours,
      theoreticalLaborPct: previewTheoreticalLaborPct,
      targetBlendedWage: previewTargetBlendedWage,
    );
  }

  /// R3 per-period preview (closes Gap 40).
  ///
  /// Builds the preview for a single service period from THAT period's
  /// selected candidate shifts only. Covers come from the selected
  /// shifts' own covers for the period (timing-config-driven), never a
  /// `/N` or fixed-fraction split of a whole-day number and never the
  /// demand-context forecast covers used by the whole-day path.
  ///
  /// Rates (CPLH / SPLH / PPA) are cover-weighted exactly like the
  /// existing whole-day [WholeDayRollup] cover-weighting (unweighted-mean
  /// fallback when every selected shift has zero covers) so the per-period
  /// pieces reconcile up to the whole-day rollup. Required hours use the
  /// same Jim Taylor model-hour formulas the shared plan resolver uses
  /// ([LaborModel.modelFohHours] / [LaborModel.modelBohHoursFromSales]).
  ///
  /// Labor dollars use the SINGLE whole-day wage pair (Design Rule 5):
  /// there is no per-period or cover-weighted wage. [fohWage] / [bohWage]
  /// are the one whole-day wage authority applied to every period.
  ///
  /// Returns null when no shifts are selected for the period.
  static ManagerOverridePlanPreview? forPeriod(
    List<BaselineCandidateShift> periodSelected, {
    double fohWage = MeridianConfig.fohWage,
    double bohWage = MeridianConfig.bohWage,
  }) {
    if (periodSelected.isEmpty) return null;

    final totalCovers =
        periodSelected.fold<int>(0, (s, c) => s + c.covers);
    double cplh = 0;
    double splh = 0;
    double ppa = 0;
    if (totalCovers > 0) {
      // Cover-weighted: the same shape as WholeDayRollup so the
      // per-period pieces reconcile up to the whole-day rollup.
      for (final c in periodSelected) {
        final w = c.covers / totalCovers;
        cplh += c.cplh * w;
        splh += c.splh * w;
        ppa += c.ppa * w;
      }
    } else {
      // Zero covers across every selected shift: unweighted mean keeps
      // the summary honest instead of dividing by zero (mirrors the
      // WholeDayRollup / TargetCycleDaypartPool zero-covers fallback).
      for (final c in periodSelected) {
        cplh += c.cplh;
        splh += c.splh;
        ppa += c.ppa;
      }
      final n = periodSelected.length;
      cplh /= n;
      splh /= n;
      ppa /= n;
    }

    // Per-period covers come from the selected shifts themselves, never
    // a split of a whole-day number.
    final periodCovers = totalCovers;
    final sales = periodCovers * ppa;
    final fohHours = LaborModel.modelFohHours(periodCovers, cplh);
    final bohHours = LaborModel.modelBohHoursFromSales(sales, splh);

    final laborPct = LaborModel.theoreticalLaborPct(
      cplh,
      splh,
      ppa,
      fohWage,
      bohWage,
    );
    final blendedWage = ActiveTargetProfile.computeTargetBlendedWage(
      targetCPLH: cplh,
      targetSPLH: splh,
      targetPPA: ppa,
      fohWage: fohWage,
      bohWage: bohWage,
    );

    return ManagerOverridePlanPreview(
      forecastCovers: periodCovers,
      coversSourceLabel: 'Selected period shifts',
      forecastSales: sales,
      requiredFohHours: fohHours,
      requiredBohHours: bohHours,
      theoreticalLaborPct: laborPct,
      targetBlendedWage: blendedWage,
    );
  }
}

// ─── Preview panel ─────────────────────────────────────────────────────────────

class PreviewPanel extends StatelessWidget {
  final List<BaselineCandidateShift> selected;
  final int? historicalWeeklyAvgCovers;

  /// R1 active lens. [kWholeDayLensId] keeps the existing cover-weighted
  /// whole-day rollup preview (read from the unchanged plan plumbing); a
  /// period id switches the plan-impact region to the R3 per-period
  /// preview built from that period's selected shifts.
  final String selectedLensId;

  const PreviewPanel({
    super.key,
    required this.selected,
    required this.historicalWeeklyAvgCovers,
    this.selectedLensId = kWholeDayLensId,
  });

  @override
  Widget build(BuildContext context) {
    final count = selected.length;
    final hasData = count > 0;

    final cplh = hasData
        ? (selected.fold(0.0, (s, c) => s + c.cplh) / count)
            .toStringAsFixed(1)
        : '--';
    final splh = hasData
        ? (selected.fold(0.0, (s, c) => s + c.splh) / count)
            .toStringAsFixed(0)
        : '--';
    final ppa = hasData
        ? (selected.fold(0.0, (s, c) => s + c.ppa) / count)
            .toStringAsFixed(0)
        : '--';
    final floor = hasData
        ? selected
            .map((c) => c.cplh)
            .reduce((a, b) => a < b ? a : b)
            .toStringAsFixed(1)
        : '--';
    final ceil = hasData
        ? selected
            .map((c) => c.cplh)
            .reduce((a, b) => a > b ? a : b)
            .toStringAsFixed(1)
        : '--';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundMid, AppColors.backgroundDeep],
        ),
        border: Border.all(color: AppColors.borderStrong, width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Row 1: SELECTED SHIFTS · TARGET CPLH
          Row(
            children: [
              Expanded(
                child: _PreviewCell(
                  label: 'SELECTED SHIFTS',
                  value: '$count',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PreviewCell(
                  label: 'TARGET CPLH',
                  value: cplh,
                  highlight: hasData,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Row 2: TARGET SPLH · TARGET PPA
          Row(
            children: [
              Expanded(
                child: _PreviewCell(label: 'TARGET SPLH', value: splh),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PreviewCell(label: 'TARGET PPA', value: ppa),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Row 3: OPZ FLOOR · OPZ CEILING
          Row(
            children: [
              Expanded(
                child: _PreviewCell(label: 'OPZ FLOOR', value: floor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PreviewCell(label: 'OPZ CEILING', value: ceil),
              ),
            ],
          ),
          // ── PLAN IMPACT ──────────────────────────────────────────────
          _PlanImpactSection(
            selected: selected,
            historicalWeeklyAvgCovers: historicalWeeklyAvgCovers,
            selectedLensId: selectedLensId,
          ),
        ],
      ),
    );
  }
}

/// Shows downstream SchedulePlan impact from the draft target profile.
/// When no shifts are selected all cells show "--".
///
/// R9: this is a tap-to-expand dropdown (accordion) matching the
/// committed prototype's `.pi` element. It is COLLAPSED by default and
/// shows a `PLAN IMPACT ›` header row; tapping the header expands the
/// six plan-impact metrics inline (the chevron rotates 90 degrees) and
/// tapping again collapses it. It is never a section the operator has
/// to scroll to reach. The metrics and their formulas are unchanged;
/// only their disclosure (show/hide) changed.
class _PlanImpactSection extends StatefulWidget {
  final List<BaselineCandidateShift> selected;
  final int? historicalWeeklyAvgCovers;
  final String selectedLensId;

  const _PlanImpactSection({
    required this.selected,
    required this.historicalWeeklyAvgCovers,
    required this.selectedLensId,
  });

  @override
  State<_PlanImpactSection> createState() => _PlanImpactSectionState();
}

class _PlanImpactSectionState extends State<_PlanImpactSection> {
  // R9: collapsed by default (matches the prototype, which renders the
  // `.pi` element without the `.open` class until tapped).
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final historicalWeeklyAvgCovers = widget.historicalWeeklyAvgCovers;
    final selectedLensId = widget.selectedLensId;
    final profile = context.watch<ActiveTargetProfileNotifier?>()?.profile;
    final hasWageAuthority = profile != null;
    final isWholeDay = selectedLensId == kWholeDayLensId;
    // Whole-day: the existing cover-weighted rollup, READ from the
    // unchanged plan plumbing (not recomputed). Period lens: the R3
    // per-period preview built from THIS period's selected shifts'
    // own covers, never a split of the whole-day number.
    final preview = isWholeDay
        ? ManagerOverridePlanPreview.fromDraftSelection(
            selected,
            historicalWeeklyAvgCovers: historicalWeeklyAvgCovers,
            fohWage: profile?.fohWage ?? MeridianConfig.fohWage,
            bohWage: profile?.bohWage ?? MeridianConfig.bohWage,
          )
        : ManagerOverridePlanPreview.forPeriod(
            selected,
            fohWage: profile?.fohWage ?? MeridianConfig.fohWage,
            bohWage: profile?.bohWage ?? MeridianConfig.bohWage,
          );
    final hasData = preview != null;

    final fcCovers = hasData ? '${preview.forecastCovers}' : '--';
    final fcSales = hasData
        ? '\$${preview.forecastSales.toStringAsFixed(0)}'
        : '--';
    final fohHrs = hasData ? '${preview.requiredFohHours}' : '--';
    final bohHrs = hasData ? '${preview.requiredBohHours}' : '--';
    final laborPct = hasData && hasWageAuthority
        ? '${preview.theoreticalLaborPct.toStringAsFixed(1)}%'
        : '--';
    final wage = hasData && hasWageAuthority
        ? '\$${preview.targetBlendedWage.toStringAsFixed(2)}'
        : '--';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Container(height: 1, color: AppColors.borderSubtle),
        const SizedBox(height: 10),
        // R9: tappable header row (the prototype's `.pi-h`). Always
        // visible; tapping it toggles the metric grid. The chevron
        // rotates 90 degrees when open (prototype: `.pi.open .cv`).
        GestureDetector(
          key: const ValueKey<String>('plan_impact_toggle'),
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _open = !_open),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('PLAN IMPACT',
                  style: AppTextStyles.mono7(color: AppColors.textMuted)),
              AnimatedRotation(
                key: const ValueKey<String>('plan_impact_chevron'),
                turns: _open ? 0.25 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Text('>',
                    style:
                        AppTextStyles.mono8(color: AppColors.textMuted)),
              ),
            ],
          ),
        ),
        // R9: the six plan-impact metrics render INLINE only when the
        // dropdown is open. Collapsed by default so this is never a
        // section the operator scrolls to reach.
        if (_open) ...[
          const SizedBox(height: 8),
          // Row 4: FORECAST COVERS · FORECAST SALES
          Row(
            children: [
              Expanded(
                child: _PreviewCell(
                    label: 'FORECAST COVERS', value: fcCovers),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PreviewCell(
                    label: 'FORECAST SALES', value: fcSales),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Row 5: FOH HRS · BOH HRS
          Row(
            children: [
              Expanded(
                child: _PreviewCell(label: 'FOH HRS', value: fohHrs),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PreviewCell(label: 'BOH HRS', value: bohHrs),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Row 6: LABOR % · BLENDED WAGE
          Row(
            children: [
              Expanded(
                child: _PreviewCell(label: 'LABOR %', value: laborPct),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PreviewCell(label: 'BLENDED WAGE', value: wage),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _PreviewCell extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _PreviewCell({
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
