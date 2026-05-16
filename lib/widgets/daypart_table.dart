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

  /// Sub-label appended under a period's name when its target cells are
  /// the whole-day pool standing in for an absent per-period child row
  /// (Gap 42 fallback). Lets the operator tell a pooled stand-in apart
  /// from a true per-period target (Design Rule 1 — scope must be
  /// obvious). Plain, lower-case, matches the table's quiet grammar.
  static const String _poolFallbackTag = 'whole-day est.';

  /// A period has no historical evidence in the current candidate
  /// window when the read service emitted `sampleSize == 0` (empty
  /// range branch of `benchmark_tracker_read_service.dart`). Such a row
  /// renders an honest dash, never a sentinel `0` (Metric Honesty
  /// Doctrine / Design Rule 2 — null, not a zero sentinel).
  bool _hasData(DaypartRange range) => range.sampleSize > 0;

  /// True when this period's targets are the whole-day pool standing in
  /// for an absent per-period child row (Gap 42). Only meaningful for a
  /// row that *has* data — an empty period dashes its targets outright,
  /// so there is nothing to mark.
  bool _isPoolFallback(DaypartRange range) {
    final p = profile;
    if (p == null) return false;
    if (!_hasData(range)) return false;
    return p.daypartFor(range.id) == null;
  }

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
    // Empty period — no historical evidence this range. The targets
    // here would be either profile pool stand-ins or sentinel zeros;
    // neither is an honest per-period number, so dash them (Metric
    // Honesty Doctrine: missing actuals → `—`, never `0`).
    if (!_hasData(range)) {
      return const [_missing, _missing, _missing, _missing];
    }
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

  @override
  Widget build(BuildContext context) {
    final p = profile;

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
          // One static table that always fits the available width — never
          // a horizontally-scrolling table (operator finding 2026-05-16:
          // a phone must show a simple table that just fits, comfortably
          // spaced). Spacing breathes out on wide layouts and tightens
          // (but stays readable) toward the 360px phone floor. The
          // numeric/header cells are fit with `BoxFit.scaleDown`, so at
          // the very narrowest widths a value shrinks a hair rather than
          // clipping or ellipsizing — and stays full, uniform size at any
          // comfortable width. The OPZ range wraps to two lines instead of
          // shrinking, so the widest value never forces the rest tiny.
          final w = constraints.maxWidth;
          final compact = w < 480;
          final hPad = compact ? 12.0 : 24.0;
          final vPad = compact ? 16.0 : 20.0;
          final gap = (w / 45).clamp(10.0, 26.0);

          Widget rule() => Container(height: 1, color: AppColors.rule);

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header row
              _TableRow(
                cells: const [
                  'DAYPART',
                  'AVG COVERS',
                  'TARGET CPLH',
                  'TARGET SPLH',
                  'TARGET PPA',
                  'OPZ RANGE',
                ],
                isHeader: true,
                hPad: hPad,
                vPad: vPad,
                gap: gap,
              ),
              rule(),
              // Per-period data rows
              ...dayparts.map((stat) {
                final targets = _targetCellsFor(stat);
                final hasData = _hasData(stat);
                return Column(
                  children: [
                    _TableRow(
                      cells: [
                        _labelFor(stat),
                        // Empty period → honest dash, never a phantom `0`.
                        hasData ? stat.avgCovers.toString() : _missing,
                        targets[0],
                        targets[1],
                        targets[2],
                        targets[3],
                      ],
                      isHeader: false,
                      subLabel:
                          _isPoolFallback(stat) ? _poolFallbackTag : null,
                      hPad: hPad,
                      vPad: vPad,
                      gap: gap,
                    ),
                    rule(),
                  ],
                );
              }),
              // Whole Day rollup row — cover-weighted pool. Same fields the
              // CPLH Range & Target widget at the top of the tab reads, so
              // the rollup row equals that widget's CPLH by construction.
              _TableRow(
                cells: [
                  'Whole Day',
                  dayparts
                      .fold<int>(0, (s, r) => s + r.avgCovers)
                      .toString(),
                  p == null ? _missing : p.targetCPLH.toStringAsFixed(2),
                  p == null
                      ? _missing
                      : '\$${p.targetSPLH.toStringAsFixed(0)}',
                  p == null
                      ? _missing
                      : '\$${p.targetPPA.toStringAsFixed(2)}',
                  p == null
                      ? _missing
                      : _opzRange(p.opzFloorCPLH, p.opzCeilingCPLH),
                ],
                isHeader: false,
                isRollup: true,
                hPad: hPad,
                vPad: vPad,
                gap: gap,
              ),
            ],
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

  /// Optional muted annotation rendered under the label (first) cell.
  /// Used for the Gap 42 "whole-day est." pooled-stand-in marker so a
  /// pooled target is visually distinct from a true per-period one
  /// (Design Rule 1). Null on every other row.
  final String? subLabel;

  /// Responsive spacing handed down from the [DaypartTable] LayoutBuilder
  /// so the same row reads comfortably on a wide layout and still fits a
  /// 360px phone without a horizontal scroll.
  final double hPad;
  final double vPad;
  final double gap;

  const _TableRow({
    required this.cells,
    required this.isHeader,
    required this.hPad,
    required this.vPad,
    required this.gap,
    this.isRollup = false,
    this.subLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: isRollup ? AppColors.cardGlow : null,
      padding: EdgeInsets.symmetric(horizontal: hPad, vertical: vPad),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < cells.length; i++) ...[
            // Gap between columns so values do not crowd the next
            // header/value (the operator's "cramped" finding); it widens
            // on roomier layouts and tightens on a phone.
            if (i != 0) SizedBox(width: gap),
            Expanded(
              // The label column and the OPZ-range column (last) get
              // extra room — the label so long period names + the
              // subordinate marker stay legible, OPZ so its wider
              // "floor – ceiling" string can wrap to two clean lines
              // instead of squeezing every other column. The remaining
              // numeric columns share the rest evenly so each value sits
              // directly under its header.
              flex: (i == 0 || i == cells.length - 1) ? 5 : 4,
              child: _cell(i),
            ),
          ],
        ],
      ),
    );
  }

  Widget _cell(int i) {
    final isLabel = i == 0;
    final isRange = i == cells.length - 1; // OPZ range / "OPZ RANGE"

    // Label column on a data row: plain wrapping text so a long period
    // name and the subordinate "whole-day est." marker stay fully
    // legible — never shrunk, never clipped or ellipsized.
    if (isLabel && !isHeader) {
      final label = Text(
        cells[i],
        style: _styleFor(i),
        textAlign: TextAlign.left,
      );
      if (subLabel == null) return label;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label,
          const SizedBox(height: 3),
          Text(
            subLabel!,
            style: AppTextStyles.mono8(color: AppColors.textMuted),
            textAlign: TextAlign.left,
          ),
        ],
      );
    }

    // OPZ range cell (and its header): the widest token in the table.
    // Let it wrap to two lines at full size rather than shrink, so it
    // never forces every other column tiny. Still never clipped: a soft
    // wrap, no ellipsis.
    if (isRange) {
      return Text(
        cells[i],
        style: _styleFor(i),
        textAlign: TextAlign.right,
        softWrap: true,
        maxLines: 2,
      );
    }

    // Every other cell (the DAYPART header + the single-token numeric
    // values + their headers): a one-line atom fit with scaleDown, so at
    // the 360px floor it shrinks a hair instead of clipping/ellipsizing,
    // and stays full, uniform size at any comfortable width.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: isLabel ? Alignment.centerLeft : Alignment.centerRight,
      child: Text(
        cells[i],
        style: _styleFor(i),
        maxLines: 1,
        softWrap: false,
        textAlign: isLabel ? TextAlign.left : TextAlign.right,
      ),
    );
  }

  TextStyle _styleFor(int i) => isHeader
      ? AppTextStyles.mono7()
      : (i == 0
          ? AppTextStyles.body11(
              color: AppColors.primaryText,
              style: FontStyle.normal,
            )
          : AppTextStyles.mono10(color: AppColors.primaryText));
}
