import 'package:flutter/material.dart';
import '../domain/models/active_target_profile.dart';
import '../domain/models/service_period_definition.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../theme/app_theme.dart';
import '../services/baseline_authority_service.dart';

/// Per-Daypart Targets V1 / Slice 2 — Daypart Target Breakdowns.
///
/// Operator-chosen UX redesign 2026-05-16 (binding, strictly UX — no
/// formula, fallback, or read-path change): one card per daypart,
/// stacked vertically. Each card leads with the headline **Target
/// CPLH** at display size, with a compact OPZ bullet bar beside it
/// (same grammar as the `CPLH RANGE & TARGET` bar at the top of the
/// tab) so the operator sees *where the target sits inside its OPZ
/// band* at a glance instead of reading two unrelated numbers. The
/// exact `floor – ceiling` range is kept verbatim as a quiet caption
/// under the bar. SPLH + PPA pair into one divided footer row. Covers
/// is the period's historical **average** (relabelled "Avg covers" so
/// the one non-target value is unambiguous) and carries its share of
/// the day. A tinted Whole Day rollup card at the bottom shows the
/// cover-weighted pool — the same fields the CPLH Range & Target widget
/// reads, 1:1 by construction. The word "Target" lives once in the
/// section header (`DAYPART TARGET BREAKDOWNS`), not on every row.
///
/// Reader contract (Design Rules, per
/// `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`),
/// unchanged by the redesign — the bar and every displayed string come
/// from the SAME [_targetsFor] branch so there is no drift:
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
  /// provider; the table then shows Avg covers and an honest dash for
  /// the target/OPZ values.
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

  /// Single source of truth for a period's targets — both the displayed
  /// strings AND the raw numbers the bullet bar positions from come out
  /// of this one branch, so the visual can never disagree with the text
  /// (Rule 1 child-row read; Rule 2 / Gap 42 whole-day-pool fallback;
  /// honest dash + null numerics when there is no evidence or no
  /// profile — never a sentinel `0`). The string formatting is byte-for-
  /// byte the prior contract: CPLH 2dp, SPLH `$`+0dp, PPA `$`+2dp, OPZ
  /// `floor – ceiling` via [_opzRange].
  _DaypartTargets _targetsFor(DaypartRange range) {
    // Empty period — no historical evidence this range. Any target here
    // would be a profile pool stand-in or a sentinel zero; neither is an
    // honest per-period number, so dash them and draw no bar (Metric
    // Honesty Doctrine: missing actuals → `—`, never `0`).
    if (!_hasData(range)) {
      return const _DaypartTargets.missing();
    }
    final p = profile;
    if (p == null) {
      return const _DaypartTargets.missing();
    }
    final period = p.daypartFor(range.id);
    if (period != null) {
      return _DaypartTargets(
        cplh: period.daypartTargetCPLH.toStringAsFixed(2),
        splh: '\$${period.daypartTargetSPLH.toStringAsFixed(0)}',
        ppa: '\$${period.daypartTargetPPA.toStringAsFixed(2)}',
        opz: _opzRange(
            period.daypartOpzFloorCPLH, period.daypartOpzCeilingCPLH),
        cplhVal: period.daypartTargetCPLH,
        opzFloor: period.daypartOpzFloorCPLH,
        opzCeiling: period.daypartOpzCeilingCPLH,
      );
    }
    // Gap 42: no per-period child row — fall back to the whole-day pool.
    return _DaypartTargets(
      cplh: p.targetCPLH.toStringAsFixed(2),
      splh: '\$${p.targetSPLH.toStringAsFixed(0)}',
      ppa: '\$${p.targetPPA.toStringAsFixed(2)}',
      opz: _opzRange(p.opzFloorCPLH, p.opzCeilingCPLH),
      cplhVal: p.targetCPLH,
      opzFloor: p.opzFloorCPLH,
      opzCeiling: p.opzCeilingCPLH,
    );
  }

  /// Whole Day rollup targets — cover-weighted pool, identical to the
  /// prior contract (honest dash, never `0`, when no profile).
  _DaypartTargets _rollupTargets() {
    final p = profile;
    if (p == null) return const _DaypartTargets.missing();
    return _DaypartTargets(
      cplh: p.targetCPLH.toStringAsFixed(2),
      splh: '\$${p.targetSPLH.toStringAsFixed(0)}',
      ppa: '\$${p.targetPPA.toStringAsFixed(2)}',
      opz: _opzRange(p.opzFloorCPLH, p.opzCeilingCPLH),
      cplhVal: p.targetCPLH,
      opzFloor: p.opzFloorCPLH,
      opzCeiling: p.opzCeilingCPLH,
    );
  }

  static String _opzRange(double floor, double ceiling) =>
      '${floor.toStringAsFixed(2)} – ${ceiling.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    // Whole-day cover basis — unchanged math (sum of per-period avg
    // covers). Reused both for the rollup card's covers and to derive
    // each period's honest share of the day.
    final totalCovers =
        dayparts.fold<int>(0, (s, r) => s + r.avgCovers);

    final cards = <Widget>[];

    for (final stat in dayparts) {
      final hasData = _hasData(stat);
      final t = _targetsFor(stat);
      // Share of day — only when the period has real covers and there
      // is a non-zero basis. Honest: an empty period shows no share.
      String? share;
      if (hasData && totalCovers > 0) {
        share = '${(stat.avgCovers / totalCovers * 100).round()}% of day';
      }
      cards.add(
        _DaypartCard(
          title: _labelFor(stat),
          // Empty period → honest dash, never a phantom `0`.
          coversValue: hasData ? stat.avgCovers.toString() : _missing,
          share: share,
          // Gap 42 pooled stand-in marker — unchanged string + style.
          subLabel: _isPoolFallback(stat) ? _poolFallbackTag : null,
          targets: t,
          isRollup: false,
        ),
      );
    }

    // Whole Day rollup — cover-weighted pool. Same fields the CPLH
    // Range & Target widget at the top of the tab reads, so this card's
    // CPLH equals that widget's by construction. No share (it is the
    // 100% basis itself).
    cards.add(
      _DaypartCard(
        title: 'Whole Day',
        coversValue: totalCovers.toString(),
        share: null,
        subLabel: null,
        targets: _rollupTargets(),
        isRollup: true,
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: cards,
    );
  }
}

/// Resolved per-card targets: the display strings (byte-for-byte the
/// prior formatting contract) plus the raw numerics the bullet bar
/// positions from. [cplhVal]/[opzFloor]/[opzCeiling] are null exactly
/// when the strings are the honest `—` (no evidence / no profile), so
/// the bar is suppressed in lockstep with the dash.
class _DaypartTargets {
  final String cplh;
  final String splh;
  final String ppa;
  final String opz;
  final double? cplhVal;
  final double? opzFloor;
  final double? opzCeiling;

  const _DaypartTargets({
    required this.cplh,
    required this.splh,
    required this.ppa,
    required this.opz,
    required this.cplhVal,
    required this.opzFloor,
    required this.opzCeiling,
  });

  const _DaypartTargets.missing()
      : cplh = DaypartTable._missing,
        splh = DaypartTable._missing,
        ppa = DaypartTable._missing,
        opz = DaypartTable._missing,
        cplhVal = null,
        opzFloor = null,
        opzCeiling = null;

  bool get hasBar =>
      cplhVal != null && opzFloor != null && opzCeiling != null;
}

/// One daypart's card: a header band (period name + Avg covers + share
/// of day, plus the optional Gap 42 "whole-day est." marker), then the
/// headline Target CPLH beside its OPZ bullet bar, the exact OPZ range
/// as a quiet caption, and a divided SPLH / PPA footer. The rollup card
/// uses a flat tinted surface with a heavier top accent so it reads as
/// the deliberate summary of the cards above it. Nothing is shrunk to
/// fit; the bar flexes via [Expanded] so there is no horizontal scroll
/// and no RenderFlex overflow at any device width.
class _DaypartCard extends StatelessWidget {
  final String title;
  final String coversValue;
  final String? share;

  /// Gap 42 pooled-stand-in marker, rendered muted under the title so a
  /// pooled target is visually distinct from a true per-period one
  /// (Design Rule 1). Null on every card that is not a pooled stand-in.
  final String? subLabel;

  final _DaypartTargets targets;
  final bool isRollup;

  const _DaypartCard({
    required this.title,
    required this.coversValue,
    required this.share,
    required this.subLabel,
    required this.targets,
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
        // Heavier top accent marks the rollup as the deliberate summary.
        borderRadius: BorderRadius.circular(3),
      ),
      foregroundDecoration: isRollup
          ? const BoxDecoration(
              border: Border(
                top: BorderSide(color: AppColors.sunsetDark, width: 2),
              ),
            )
          : null,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header band — period name (left) + Avg covers / share
          // (right). Title takes the slack; the covers cluster stays
          // intrinsic so a long title never pushes it off-card.
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
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // "<n> Avg covers" — count at full mono size, quiet
                  // trailing unit on its baseline.
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        coversValue,
                        style: AppTextStyles.mono14(
                            color: AppColors.primaryText),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'Avg covers',
                        style:
                            AppTextStyles.mono8(color: AppColors.textMuted),
                      ),
                    ],
                  ),
                  if (share != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      share!,
                      style: AppTextStyles.mono8(color: AppColors.textMuted),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Headline Target CPLH + OPZ bullet bar. The big value and the
          // bar both read from the same resolved targets.
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    targets.cplh,
                    style: AppTextStyles.mono22(
                        color: AppColors.primaryText),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'CPLH',
                    style: AppTextStyles.mono8(color: AppColors.textMuted),
                  ),
                ],
              ),
              const SizedBox(width: 16),
              Expanded(
                child: targets.hasBar
                    ? _OpzBar(
                        floor: targets.opzFloor!,
                        ceiling: targets.opzCeiling!,
                        target: targets.cplhVal!,
                      )
                    : const SizedBox(height: _OpzBar.height),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Exact OPZ range, kept verbatim as a quiet caption so the
          // precise floor/ceiling numbers are never lost behind the bar.
          Row(
            children: [
              Text(
                'OPZ',
                style: AppTextStyles.mono8(color: AppColors.textMuted),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  targets.opz,
                  style: AppTextStyles.mono10(color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(height: 1, color: AppColors.rule),
          const SizedBox(height: 12),
          // SPLH + PPA — one divided footer row. Labels muted/once,
          // values full size; each value is its own Text node.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _FooterStat(label: 'SPLH', value: targets.splh)),
              Container(
                width: 1,
                height: 30,
                color: AppColors.rule,
                margin: const EdgeInsets.symmetric(horizontal: 16),
              ),
              Expanded(child: _FooterStat(label: 'PPA', value: targets.ppa)),
            ],
          ),
        ],
      ),
    );
  }
}

/// One footer metric — muted label over its full-size value.
class _FooterStat extends StatelessWidget {
  final String label;
  final String value;
  const _FooterStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: AppTextStyles.mono8(color: AppColors.textMuted)),
        const SizedBox(height: 4),
        Text(value,
            style: AppTextStyles.mono14(color: AppColors.primaryText)),
      ],
    );
  }
}

/// Compact OPZ bullet bar — shaded band = the OPZ range (floor →
/// ceiling), tick/dot = where the Target CPLH lands inside it. Same
/// grammar as the `CPLH RANGE & TARGET` bar at the top of the tab, so
/// the operator learns the visual once. Purely presentational: every
/// number is supplied by the caller's single resolved-targets branch.
/// A degenerate floor==ceiling band collapses to one muted point
/// instead of faking a width. Flexes to its [Expanded] width — no
/// horizontal scroll, fixed height so the card never overflows.
class _OpzBar extends StatelessWidget {
  final double floor;
  final double ceiling;
  final double target;

  const _OpzBar({
    required this.floor,
    required this.ceiling,
    required this.target,
  });

  static const double height = 26.0;
  // Inner inset on each side so the shaded band has visual breathing
  // room and the tick can sit at the band edges without clipping.
  static const double _inset = 0.12;

  @override
  Widget build(BuildContext context) {
    final degenerate = (ceiling - floor).abs() < 0.0001;
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final zoneLeft = w * _inset;
        final zoneRight = w * (1 - _inset);
        final zoneW = (zoneRight - zoneLeft).clamp(2.0, w);
        final double tickX;
        if (degenerate) {
          tickX = w / 2;
        } else {
          final frac =
              ((target - floor) / (ceiling - floor)).clamp(0.0, 1.0);
          tickX = zoneLeft + frac * (zoneRight - zoneLeft);
        }
        const trackH = 3.0;
        const zoneH = 14.0;
        const tickH = 18.0;
        const dotD = 9.0;
        return SizedBox(
          height: height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Neutral track across the full width.
              Positioned(
                left: 0,
                right: 0,
                top: (height - trackH) / 2,
                child: Opacity(
                  opacity: degenerate ? 0.45 : 1.0,
                  child: Container(
                    height: trackH,
                    decoration: BoxDecoration(
                      color: AppColors.borderSubtle,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
              // Shaded OPZ band — only when there is a real width.
              if (!degenerate)
                Positioned(
                  left: zoneLeft,
                  top: (height - zoneH) / 2,
                  child: Container(
                    width: zoneW,
                    height: zoneH,
                    decoration: BoxDecoration(
                      color: AppColors.shimmer,
                      border:
                          Border.all(color: AppColors.borderSubtle, width: 1),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              // Target tick + dot.
              Positioned(
                left: tickX - 1,
                top: (height - tickH) / 2,
                child: Container(
                  width: 2,
                  height: tickH,
                  color: AppColors.sunsetDark,
                ),
              ),
              Positioned(
                left: tickX - dotD / 2,
                top: (height - tickH) / 2 - 4,
                child: Container(
                  width: dotD,
                  height: dotD,
                  decoration: const BoxDecoration(
                    color: AppColors.sunset,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
