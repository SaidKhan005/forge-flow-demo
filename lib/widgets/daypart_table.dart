import 'package:flutter/material.dart';
import '../domain/models/active_target_profile.dart';
import '../domain/models/service_period_definition.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../theme/app_theme.dart';
import '../services/baseline_authority_service.dart';

/// Per-Daypart Targets V1 / Slice 2 — Daypart Breakdown.
///
/// Operator finding 2026-05-16 (binding): the prior six-column row
/// table was still too condensed/unreadable on a phone even after the
/// no-horizontal-scroll cleanup — values were `FittedBox`-shrunk to
/// fit. This is the operator-chosen redesign: **one card per daypart**,
/// stacked vertically. Each card carries the period name + avg covers
/// in its header, then the four targets (CPLH · SPLH · PPA · OPZ Range)
/// as full-size label/value rows — nothing shrinks, no horizontal
/// scroll, every value at its natural size. A tinted Whole Day card at
/// the bottom shows the cover-weighted pool (the same fields the CPLH
/// Range & Target widget at the top of the tab reads — 1:1 by
/// construction).
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

  // Card-row metric labels. Mixed-case (card grammar, not the old
  // uppercase column-header grammar) and read once per card.
  static const String _labelCPLH = 'Target CPLH';
  static const String _labelSPLH = 'Target SPLH';
  static const String _labelPPA = 'Target PPA';
  static const String _labelOPZ = 'OPZ Range';

  @override
  Widget build(BuildContext context) {
    final p = profile;

    final cards = <Widget>[];

    // One card per daypart.
    for (final stat in dayparts) {
      final targets = _targetCellsFor(stat);
      final hasData = _hasData(stat);
      cards.add(
        _DaypartCard(
          title: _labelFor(stat),
          // Empty period → honest dash, never a phantom `0`.
          covers: hasData ? stat.avgCovers.toString() : _missing,
          // Gap 42 pooled stand-in marker — unchanged string + style.
          subLabel: _isPoolFallback(stat) ? _poolFallbackTag : null,
          metrics: [
            (_labelCPLH, targets[0]),
            (_labelSPLH, targets[1]),
            (_labelPPA, targets[2]),
            (_labelOPZ, targets[3]),
          ],
          isRollup: false,
        ),
      );
    }

    // Whole Day rollup card — cover-weighted pool. Same fields the CPLH
    // Range & Target widget at the top of the tab reads, so this card's
    // CPLH equals that widget's by construction.
    cards.add(
      _DaypartCard(
        title: 'Whole Day',
        covers: dayparts.fold<int>(0, (s, r) => s + r.avgCovers).toString(),
        subLabel: null,
        metrics: [
          (_labelCPLH,
              p == null ? _missing : p.targetCPLH.toStringAsFixed(2)),
          (_labelSPLH,
              p == null ? _missing : '\$${p.targetSPLH.toStringAsFixed(0)}'),
          (_labelPPA,
              p == null ? _missing : '\$${p.targetPPA.toStringAsFixed(2)}'),
          (_labelOPZ,
              p == null
                  ? _missing
                  : _opzRange(p.opzFloorCPLH, p.opzCeilingCPLH)),
        ],
        isRollup: true,
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: cards,
    );
  }
}

/// One daypart's card: a header band (period name + avg covers, plus the
/// optional Gap 42 "whole-day est." marker) over a hairline rule, then
/// the four targets as full-size label/value rows. Nothing is shrunk to
/// fit — the card is the full content width, so every value renders at
/// its natural size with no horizontal scroll (operator finding
/// 2026-05-16). The rollup card uses a flat tinted surface so it reads
/// as the deliberate summary of the cards above it.
class _DaypartCard extends StatelessWidget {
  final String title;
  final String covers;

  /// Gap 42 pooled-stand-in marker, rendered muted under the title so a
  /// pooled target is visually distinct from a true per-period one
  /// (Design Rule 1). Null on every card that is not a pooled stand-in.
  final String? subLabel;

  /// (label, value) pairs in display order: CPLH, SPLH, PPA, OPZ Range.
  final List<(String, String)> metrics;

  final bool isRollup;

  const _DaypartCard({
    required this.title,
    required this.covers,
    required this.subLabel,
    required this.metrics,
    required this.isRollup,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        // Period cards keep the surface→glow gradient; the rollup is a
        // flat glow fill so it reads as the summary, not another period.
        gradient: isRollup
            ? null
            : const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppColors.surface, AppColors.cardGlow],
              ),
        color: isRollup ? AppColors.cardGlow : null,
        border: Border.all(color: AppColors.rule, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header band — period name (left) + avg covers (right).
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTextStyles.body14(
                        color: AppColors.primaryText,
                        style: FontStyle.normal,
                      ),
                    ),
                    if (subLabel != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subLabel!,
                        style:
                            AppTextStyles.mono8(color: AppColors.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Covers reads as one line ("91 covers") — the count at
              // full mono size with a quiet trailing unit, baseline-
              // aligned so the small unit sits on the number's baseline.
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    covers,
                    style:
                        AppTextStyles.mono14(color: AppColors.primaryText),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    'covers',
                    style: AppTextStyles.mono8(color: AppColors.textMuted),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(height: 1, color: AppColors.rule),
          const SizedBox(height: 12),
          // Four target rows — label left (muted), value right, full
          // size. The OPZ value is the widest token; it may wrap to two
          // lines rather than shrink, so no value is ever clipped.
          for (var i = 0; i < metrics.length; i++) ...[
            if (i != 0) const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    metrics[i].$1,
                    style:
                        AppTextStyles.mono10(color: AppColors.textMuted),
                  ),
                ),
                const SizedBox(width: 28),
                Flexible(
                  child: Text(
                    metrics[i].$2,
                    style: AppTextStyles.mono14(
                      color: AppColors.primaryText,
                    ),
                    textAlign: TextAlign.right,
                    softWrap: true,
                    maxLines: 2,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
