import 'package:flutter/material.dart';
import '../domain/models/active_target_profile.dart';
import '../domain/models/service_period_definition.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../theme/app_theme.dart';
import '../services/baseline_authority_service.dart';

/// Per-Daypart Targets V1 / Slice 2 — Daypart Breakdown table.
///
/// Columns: DAYPART · AVG COVERS · TARGET CPLH · TARGET SPLH ·
/// TARGET PPA · OPZ RANGE. A Whole Day rollup row at the bottom shows
/// the cover-weighted pool (the same fields the CPLH Range & Target
/// widget at the top of the tab reads — 1:1 by construction).
///
/// Reader contract (Design Rules, per
/// `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`):
///   Rule 1 — per-period values read the `daypart*`-named accessors on
///     [ActiveTargetProfileDaypart]; whole-day field names are never
///     reused for a period row.
///   Rule 2 — when [ActiveTargetProfile.daypartFor] returns null (Gap
///     42 insufficient-recommendation fallback: no per-period child
///     rows), the row falls back to the whole-day pool fields. Missing
///     is rendered honestly, never as a sentinel `0`.
class DaypartTable extends StatelessWidget {
  final List<DaypartRange> dayparts;

  /// Active target profile. Per-period rows + the whole-day pool both
  /// come from here. Null only in bridge-only widget tests with no
  /// provider; the table then shows AVG COVERS and an honest dash for
  /// the target/OPZ columns.
  final ActiveTargetProfile? profile;

  /// Operator-configured service-period definitions for label lookup.
  final List<ServicePeriodDefinition> servicePeriodDefinitions;

  const DaypartTable({
    super.key,
    required this.dayparts,
    this.profile,
    this.servicePeriodDefinitions = const [],
  });

  static const String _missing = '—';

  String _labelFor(DaypartRange range) {
    if (servicePeriodDefinitions.isEmpty) return range.label;
    return ServicePeriodDefinitionResolver.labelForId(
      servicePeriodDefinitions,
      range.id,
    );
  }

  /// Per-period target cells. Reads the period's child row via the
  /// `daypart*` accessors (Rule 1); falls back to the whole-day pool
  /// when the period has no child row (Rule 2 — Gap 42), and to an
  /// honest dash when no profile is in scope at all (never `0`).
  List<String> _targetCellsFor(DaypartRange range) {
    final p = profile;
    if (p == null) {
      return const [_missing, _missing, _missing, _missing];
    }
    final period = p.daypartFor(range.id);
    if (period != null) {
      return [
        period.daypartTargetCPLH.toStringAsFixed(2),
        '\$${period.daypartTargetSPLH.toStringAsFixed(0)}',
        '\$${period.daypartTargetPPA.toStringAsFixed(2)}',
        _opzRange(period.daypartOpzFloorCPLH, period.daypartOpzCeilingCPLH),
      ];
    }
    // Gap 42: no per-period child row — fall back to the whole-day pool.
    return [
      p.targetCPLH.toStringAsFixed(2),
      '\$${p.targetSPLH.toStringAsFixed(0)}',
      '\$${p.targetPPA.toStringAsFixed(2)}',
      _opzRange(p.opzFloorCPLH, p.opzCeilingCPLH),
    ];
  }

  static String _opzRange(double floor, double ceiling) =>
      '${floor.toStringAsFixed(2)} – ${ceiling.toStringAsFixed(2)}';

  /// Minimum width that lets all six columns breathe without wrapping or
  /// clipping any value. At the demo device width (1080px) and any wider
  /// layout the table simply fills the space and the columns spread out;
  /// only below this floor does it scroll horizontally instead — so there
  /// is never a `RenderFlex overflowed` and text is never clipped.
  static const double _minTableWidth = 720;

  @override
  Widget build(BuildContext context) {
    final p = profile;

    final table = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Header row
        const _TableRow(
          cells: [
            'DAYPART',
            'AVG COVERS',
            'TARGET CPLH',
            'TARGET SPLH',
            'TARGET PPA',
            'OPZ RANGE',
          ],
          isHeader: true,
        ),
        Container(height: 1, color: AppColors.rule),
        // Per-period data rows
        ...dayparts.map((stat) {
          final targets = _targetCellsFor(stat);
          return Column(
            children: [
              _TableRow(
                cells: [
                  _labelFor(stat),
                  stat.avgCovers.toString(),
                  targets[0],
                  targets[1],
                  targets[2],
                  targets[3],
                ],
                isHeader: false,
              ),
              Container(height: 1, color: AppColors.rule),
            ],
          );
        }),
        // Whole Day rollup row — cover-weighted pool. Same fields the
        // CPLH Range & Target widget at the top of the tab reads, so
        // the rollup row equals that widget's CPLH by construction.
        _TableRow(
          cells: [
            'Whole Day',
            dayparts.fold<int>(0, (s, r) => s + r.avgCovers).toString(),
            p == null ? _missing : p.targetCPLH.toStringAsFixed(2),
            p == null ? _missing : '\$${p.targetSPLH.toStringAsFixed(0)}',
            p == null ? _missing : '\$${p.targetPPA.toStringAsFixed(2)}',
            p == null
                ? _missing
                : _opzRange(p.opzFloorCPLH, p.opzCeilingCPLH),
          ],
          isHeader: false,
          isRollup: true,
        ),
      ],
    );

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.surface, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.rule, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Wide enough (the demo device is 1080px): let the columns
          // spread across the full width.
          if (constraints.maxWidth >= _minTableWidth) return table;
          // Narrow (e.g. a 360px phone): scroll horizontally at the
          // breathing-room width so the six columns stay readable and
          // nothing overflows or gets clipped.
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: _minTableWidth, child: table),
          );
        },
      ),
    );
  }
}

class _TableRow extends StatelessWidget {
  final List<String> cells;
  final bool isHeader;
  final bool isRollup;

  const _TableRow({
    required this.cells,
    required this.isHeader,
    this.isRollup = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: isRollup ? AppColors.cardGlow : null,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++) ...[
            // Gap between columns so values do not crowd the next
            // header/value (the operator's "cramped" finding).
            if (i != 0) const SizedBox(width: 14),
            Expanded(
              // The label column gets extra room; the five numeric
              // columns share the rest evenly so each value sits
              // directly under its header.
              flex: i == 0 ? 5 : 4,
              child: Text(
                cells[i],
                style: isHeader
                    ? AppTextStyles.mono7()
                    : (i == 0
                        ? AppTextStyles.body11(
                            color: AppColors.primaryText,
                            style: FontStyle.normal,
                          )
                        : AppTextStyles.mono10(
                            color: AppColors.primaryText)),
                textAlign: i == 0 ? TextAlign.left : TextAlign.right,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
