// === CplhOpzBandCard : Variance Coaching V2 (Lane HIST) ====================
// The mockup `#hist` "CPLH vs your OPZ · 60-day" card
// (docs/f&f Coaching/variance_tab_v2_mockup.html, lines ~275-288).
//
// Renders the green-zone band that shows where the operator's active CPLH
// OPZ floor/ceiling sits inside the real 60-day observed CPLH range, plus
// the History-specific red "now" marker and the "What the zone is telling
// you" teaching narrative.
//
// OPERATOR DECISION (Variance V2, History OPZ band re-model): stop
// inventing a bespoke scale. REUSE the proven range model + data source
// of the "CPLH RANGE & TARGET" band in `lib/screens/baseline_tracker.dart`
// (its `_CplhRangeBar`, fed by `BaselineRangeGraphModel`/`rangeGraphModel`
// in `lib/services/baseline_authority_service.dart`). That band's outer
// axis = `BaselineData.historicalContextRecords` min/max CPLH, i.e. the
// lowest CPLH last 60 days and the highest CPLH last 60 days. Because the
// rail is the widest real observed bound, the OPZ/benchmark range ALWAYS
// sits naturally inside it for every realistic scenario, so the previous
// clamp + extends-beyond-cap kludge is removed by construction.
//
// Reused proven source (file:line):
//   - `BaselineData.historicalContextRecords`
//     (lib/services/baseline_authority_service.dart:204) — the same list
//     the proven band's `rangeGraphModel` reads (line 623) for its
//     `histMin`/`histMax` outer axis (`LOWEST CPLH LAST 60 DAYS` /
//     `HIGHEST CPLH LAST 60 DAYS`, lines 624-625, 708-709).
//   - The History tab passes those bounds via `sixtyDayLowCplh` /
//     `sixtyDayHighCplh` (see `BaselineData.cplhSixtyDayLow` /
//     `cplhSixtyDayHigh` accessors added on the same proven list); this
//     widget does NOT duplicate the min/max computation.
//
// Positioning math mirrors the proven band exactly
// (baseline_authority_service.dart:664-680):
//   scaleMin/scaleMax = the 60-day low/high; if scaleMax <= scaleMin
//   (degenerate: every 60-day CPLH identical) it widens to
//   [max(0, c - 1.0), c + 1.0] around the OPZ centre `c`, mirroring the
//   proven band's `target ± 1.0` guard. pct(v) = clamp01((v - scaleMin) /
//   (scaleMax - scaleMin)). No bespoke clamp/cap path.
//
// Authority: docs/contracts/phase_7_58_primary_driver_contract.md.
//   - V2-4: inline emphasis is applied at RENDER time, never stored. The
//     "below it N of the last M weeks" span is wrapped in the V2-4
//     `[[bad:…]]` token and rendered through InlineEmphasisText, which
//     owns the verbatim-fallback contract.
//   - V2-6: Telestrator stays EXCLUDED. No engine change
//     (lib/services/labor_model.dart is FROZEN).
//
// Metric Honesty Doctrine: when the OPZ bounds or the 60-day low/high
// bounds are unavailable, this renders an honest degraded state (no
// fabricated green zone, no phantom zeroes). The mockup is one populated
// example, not a guaranteed shape.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'inline_emphasis_text.dart';

/// Geometry + narrative inputs for the CPLH-vs-OPZ 60-day band.
///
/// Built by [CplhOpzBandData.fromInputs]. The outer rail bounds
/// ([sixtyDayLow]/[sixtyDayHigh]) come from the SAME proven source the
/// `baseline_tracker` "CPLH RANGE & TARGET" band uses
/// (`BaselineData.historicalContextRecords` min/max CPLH — the lowest and
/// highest CPLH over the last 60 days). The OPZ floor/ceiling come from
/// the active target profile. The History-specific `now` marker and
/// `weeksBelowFloor`/`weekCount` are derived from the per-week CPLH series
/// the History tab already loads. Returns a non-renderable instance
/// (`canRenderBand == false`) whenever the honest preconditions are not
/// met, so the widget can degrade instead of fabricating a zone.
@immutable
class CplhOpzBandData {
  const CplhOpzBandData._({
    required this.canRenderBand,
    this.sixtyDayLow = 0,
    this.sixtyDayHigh = 0,
    this.scaleMin = 0,
    this.scaleMax = 0,
    this.opzFloor = 0,
    this.opzCeiling = 0,
    this.now = 0,
    this.weeksBelowFloor = 0,
    this.weekCount = 0,
  });

  /// True only when every band element can be drawn honestly: a usable
  /// OPZ range AND a usable 60-day low/high rail.
  final bool canRenderBand;

  /// Outer rail bounds: the lowest / highest CPLH over the last 60 days.
  /// Sourced from the proven `BaselineData.historicalContextRecords`
  /// min/max CPLH (the same axis the baseline_tracker band draws as its
  /// `LOWEST CPLH LAST 60 DAYS` / `HIGHEST CPLH LAST 60 DAYS` ends).
  /// These are the `.tickm` end labels at the rail ends.
  final double sixtyDayLow;
  final double sixtyDayHigh;

  /// Normalisation domain. Equals `[sixtyDayLow, sixtyDayHigh]`, except
  /// in the degenerate case where every 60-day CPLH is identical
  /// (`sixtyDayHigh <= sixtyDayLow`): then it widens to
  /// `[max(0, c - 1.0), c + 1.0]` around the OPZ centre `c`, mirroring
  /// the proven band's `target ± 1.0` guard
  /// (lib/services/baseline_authority_service.dart:666-669).
  final double scaleMin;
  final double scaleMax;

  /// Active target profile CPLH OPZ bounds (the green box edges). By
  /// construction the rail is the widest real observed bound, so these
  /// sit inside `[sixtyDayLow, sixtyDayHigh]` in every realistic
  /// scenario (no clamp needed).
  final double opzFloor;
  final double opzCeiling;

  /// Most recent week's CPLH (the red "now" marker). History-specific
  /// element layered on top, unchanged in meaning.
  final double now;

  /// How many of the last [weekCount] weeks ran below [opzFloor].
  /// History-specific; drives the teaching paragraph only.
  final int weeksBelowFloor;
  final int weekCount;

  /// Normalised [0,1] position of [value] on the rail. Mirrors the
  /// proven band's normalization
  /// (lib/services/baseline_authority_service.dart:672-680):
  /// `clamp01((value - scaleMin) / (scaleMax - scaleMin))`. The clamp
  /// here is the proven band's own clamp, NOT the removed bespoke
  /// extends-beyond kludge: because the rail is the widest observed
  /// bound, OPZ edges land strictly interior and are never actually
  /// clamped in realistic data.
  double fractionFor(double value) {
    final span = scaleMax - scaleMin;
    if (span <= 0) return 0;
    return ((value - scaleMin) / span).clamp(0.0, 1.0);
  }

  /// Builds band geometry reusing the proven baseline_tracker range
  /// source for the outer rail.
  ///
  /// [sixtyDayLowCplh]/[sixtyDayHighCplh] are the lowest / highest CPLH
  /// over the last 60 days — pass `BaselineData.cplhSixtyDayLow` /
  /// `cplhSixtyDayHigh` (the same `historicalContextRecords` the proven
  /// band reads). This widget does NOT recompute the min/max.
  /// [opzFloor]/[opzCeiling] come from the active target profile.
  /// [weeklyCplhSeries] is the per-week `avgCPLH` series the History tab
  /// already loads; it drives ONLY the History-specific
  /// `weeksBelowFloor`/`weekCount` teaching numbers (it no longer defines
  /// the rail). [nowCplh] is the most recent week's CPLH.
  ///
  /// Any of the rail bounds or OPZ bounds being null/absent/unusable
  /// yields an honest degraded result.
  static CplhOpzBandData fromInputs({
    required List<double> weeklyCplhSeries,
    required double? sixtyDayLowCplh,
    required double? sixtyDayHighCplh,
    required double? opzFloor,
    required double? opzCeiling,
    required double? nowCplh,
  }) {
    final lived = weeklyCplhSeries
        .where((v) => v.isFinite && v > 0)
        .toList(growable: false);

    final hasOpz = opzFloor != null &&
        opzCeiling != null &&
        opzFloor.isFinite &&
        opzCeiling.isFinite &&
        opzFloor > 0 &&
        opzCeiling > 0 &&
        opzCeiling > opzFloor;

    // The outer rail uses the proven 60-day low/high. Honest precondition:
    // both bounds present, finite, positive, and low <= high.
    final hasRail = sixtyDayLowCplh != null &&
        sixtyDayHighCplh != null &&
        sixtyDayLowCplh.isFinite &&
        sixtyDayHighCplh.isFinite &&
        sixtyDayLowCplh > 0 &&
        sixtyDayHighCplh > 0 &&
        sixtyDayHighCplh >= sixtyDayLowCplh;

    final now =
        (nowCplh != null && nowCplh.isFinite && nowCplh > 0) ? nowCplh : null;

    // Honest precondition: a usable OPZ range AND a usable 60-day rail.
    // Without either we cannot draw a truthful band.
    if (!hasOpz || !hasRail) {
      return const CplhOpzBandData._(canRenderBand: false);
    }

    final low = sixtyDayLowCplh;
    final high = sixtyDayHighCplh;

    // Position normalization — the proven band's exact math
    // (lib/services/baseline_authority_service.dart:664-670). When the
    // 60-day low/high collapse (every observed CPLH identical) the proven
    // band widens the scale around its target by ±1.0; here the analogous
    // centring value is the OPZ midpoint (the band has no single
    // "target"). This mirrors the proven degenerate behavior exactly
    // rather than inventing a new one.
    var scaleMin = low;
    var scaleMax = high;
    if (scaleMax <= scaleMin) {
      final centre = (opzFloor + opzCeiling) / 2.0;
      scaleMin = math.max(0.0, centre - 1.0);
      scaleMax = centre + 1.0;
    }

    final weeksBelowFloor = lived.where((v) => v < opzFloor).length;

    return CplhOpzBandData._(
      canRenderBand: true,
      sixtyDayLow: low,
      sixtyDayHigh: high,
      scaleMin: scaleMin,
      scaleMax: scaleMax,
      opzFloor: opzFloor,
      opzCeiling: opzCeiling,
      now: now ?? 0,
      weeksBelowFloor: weeksBelowFloor,
      weekCount: lived.length,
    );
  }
}

/// The mockup `#hist` "CPLH vs your OPZ · 60-day" card: the green-zone
/// band visualization plus the "What the zone is telling you" narrative.
///
/// Pass [data] built via [CplhOpzBandData.fromInputs]. When the data
/// cannot be drawn honestly the card renders a degraded message instead
/// of a fabricated zone (Metric Honesty Doctrine).
class CplhOpzBandCard extends StatelessWidget {
  const CplhOpzBandCard({super.key, required this.data});

  final CplhOpzBandData data;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundSurface, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: data.canRenderBand
          ? _buildPopulated(context)
          : _buildDegraded(context),
    );
  }

  Widget _buildPopulated(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _OpzScale(data: data),
        const SizedBox(height: 14),
        _buildTeach(context),
      ],
    );
  }

  Widget _buildTeach(BuildContext context) {
    final m = data.weekCount;
    final n = data.weeksBelowFloor;

    // The teaching paragraph adapts honestly to where the operator sits.
    //
    // Mockup parity (docs/f&f Coaching/variance_tab_v2_mockup.html `#hist`
    // `.teach`): the lead-in is `<b>What the zone is telling you.</b>` —
    // BOLD, default ink, on EVERY variant. The shared
    // InlineEmphasisText renderer has no non-coloured bold token (only
    // `[[bad:…]]`/`[[good:…]]`/chip), and it is reused by This Week +
    // Learn, so per the slice contract it is NOT modified here. Instead
    // the lead-in is rendered as a bold prefix TextSpan and the marked-up
    // remainder is parsed through the SAME InlineEmphasisMarkup parser so
    // the verbatim-fallback / V2-4 render contract is preserved.
    //
    // Each variant carries EXACTLY ONE colour emphasis span, applied at
    // RENDER time (never stored): `[[bad:…]]` (red) when the message is
    // unfavourable (operator below the zone), `[[good:…]]` (green) when
    // favourable (in or above the zone). The honest no-history variant
    // (`m == 0`) has no real favourable/unfavourable stat to grade, so it
    // honestly carries NO colour span (Metric Honesty Doctrine: never
    // fabricate a highlight where there is no real stat). All numbers are
    // the real computed values already on `data` (no mockup literals).
    const lead = 'What the zone is telling you. ';
    const intro = 'The green band is where '
        'your CPLH is healthy: enough hands to take care of the guest, not '
        'so many you are paying for tables that are not there. ';

    final String body;
    if (m == 0) {
      // No closed-week history yet to grade against. Stay honest: the
      // zone itself is real (sourced from the proven 60-day rail + OPZ),
      // but there is no week-count claim to make — so no colour span.
      body = 'Once your weeks close, this will show how often your hours '
          'matched the volume.';
    } else if (n == 0) {
      // Favourable: in or above the zone every week → green emphasis on
      // the positive stat clause, mirroring how the unfavourable variant
      // emphasises its key stat in red.
      body = 'You have [[good:stayed in or above it every one of the last '
          '$m ${_weekWord(m)}]]. Hold the line: this is the hours matching '
          'the volume.';
    } else if (n == m) {
      // Unfavourable. Mockup `.teach`: "You have sat <em-bad>below it N of
      // the last M weeks</em-bad>." `_count` already begins with "below
      // it", so the lead-in here is just "You have sat " (no doubled
      // "below it" — that was a pre-existing copy defect vs the mockup).
      body = 'You have sat [[bad:${_count(n, m)}]]. The volume '
          'keeps showing up. The hours are not tightening to meet it.';
    } else {
      body = 'You have sat [[bad:${_count(n, m)}]]. The volume '
          'keeps showing up on those weeks. The hours are not tightening '
          'to meet it.';
    }

    // `AppTextStyles.body14` defaults to FontWeight.w600 (semibold), which
    // would render the WHOLE teaching paragraph heavy. Mockup `.teach`
    // (docs/f&f Coaching/variance_tab_v2_mockup.html) is regular-weight
    // body with bold ONLY on the lead-in and the colored stat spans. Pin
    // the plain weight explicitly to w400 so plain segments are regular.
    final base = AppTextStyles.body14(color: AppColors.textPrimary)
        .copyWith(fontWeight: FontWeight.w400);
    return Text.rich(
      TextSpan(
        children: [
          // BOLD lead-in: mockup `.teach b` weight, default ink colour
          // (NOT a sentiment colour). Rendered as a prefix span because
          // the shared renderer has no neutral-bold token and must not be
          // changed.
          TextSpan(
            text: lead,
            style: base.copyWith(fontWeight: FontWeight.w700),
          ),
          // Remainder rendered through the SAME V2-4 parser the shared
          // InlineEmphasisText uses, so colour spans + verbatim fallback
          // behave identically without touching inline_emphasis_text.dart.
          for (final segment
              in InlineEmphasisMarkup.parse('$intro$body'))
            _emphasisSpan(segment, base),
        ],
      ),
    );
  }

  /// Maps a parsed [InlineEmphasisSegment] to a styled [InlineSpan] using
  /// the same V2-2 sentiment palette as `InlineEmphasisText` (loss = red /
  /// `AppColors.negative`, profit = green / `AppColors.positive`). Kept
  /// local so the shared renderer is not modified (it is reused by This
  /// Week + Learn). Chips are not produced by this card's copy, so the
  /// chip kinds fall back to the plain style defensively.
  InlineSpan _emphasisSpan(InlineEmphasisSegment segment, TextStyle base) {
    switch (segment.kind) {
      case InlineEmphasisKind.causalBad:
        return TextSpan(
          text: segment.text,
          style: base.copyWith(
            color: AppColors.negative,
            fontWeight: FontWeight.w700,
          ),
        );
      case InlineEmphasisKind.causalGood:
        return TextSpan(
          text: segment.text,
          style: base.copyWith(
            color: AppColors.positive,
            fontWeight: FontWeight.w700,
          ),
        );
      case InlineEmphasisKind.plain:
      case InlineEmphasisKind.chipBad:
      case InlineEmphasisKind.chipGood:
        return TextSpan(text: segment.text, style: base);
    }
  }

  Widget _buildDegraded(BuildContext context) {
    // Metric Honesty Doctrine: no fabricated green zone. Say plainly
    // that the comparison is not available yet.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'CPLH ZONE',
          style: AppTextStyles.mono10(color: AppColors.textMuted),
        ),
        const SizedBox(height: 8),
        Text(
          '—',
          style: AppTextStyles.mono14(color: AppColors.textMuted),
        ),
        const SizedBox(height: 10),
        Text(
          'The CPLH zone needs your locked OPZ targets and at least one '
          'closed week to show. It will appear once both are in place.',
          style: AppTextStyles.body14(color: AppColors.textMuted),
        ),
      ],
    );
  }

  String _count(int n, int m) =>
      'below it $n of the last $m ${_weekWord(m)}';

  String _weekWord(int m) => m == 1 ? 'week' : 'weeks';
}

/// Pure, unit-testable render geometry for the `.opzscale` band.
///
/// REUSED MODEL (operator decision): identical in shape to the proven
/// `baseline_tracker` "CPLH RANGE & TARGET" band
/// (`_CplhRangeBar` + `BaselineRangeGraphModel`). The rail domain is the
/// real 60-day CPLH low/high (`BaselineData.historicalContextRecords`
/// min/max — the SAME source, see `cplh_opz_band_card.dart` header) and
/// `pct(v) = clamp01((v - scaleMin) / (scaleMax - scaleMin))`, the proven
/// band's exact normalization
/// (lib/services/baseline_authority_service.dart:672-680). The 60-day
/// low/high land at the rail ends (~0% / ~100%), exactly like the mockup
/// `.tickm` `left:0` / `right:0` and the proven band's left/right
/// endpoint ticks.
///
/// The green OPZ box maps `opzFloor`->`opzCeiling` into that domain.
/// Because the rail is the WIDEST real observed bound (lowest/highest
/// CPLH over 60 days across all shifts), the OPZ range sits strictly
/// interior in every realistic scenario — exactly the proven band's
/// inner `BENCHMARK RANGE` box behavior. The previous bespoke clamp +
/// extends-beyond-cap path is REMOVED: it is unreachable by construction.
/// The only residual clamp is the proven band's own `clamp(0,1)` in
/// `fractionFor`, kept for float-edge safety (identical to
/// baseline_authority_service.dart:673/676/679).
///
/// HONEST LABELS: the `.opzlab` text always shows the TRUE `opzFloor` /
/// `opzCeiling` numbers (the widget reads `data.opzFloor` /
/// `data.opzCeiling`).
///
/// This is a presentation transform of values the data layer already
/// derived. It does NOT touch [CplhOpzBandData.fromInputs] math or any
/// data source. Exposed so the geometry is verifiable without eyeballing
/// the rendered widget.
@immutable
class OpzScaleGeometry {
  const OpzScaleGeometry._({
    required this.railLowPct,
    required this.railHighPct,
    required this.opzLeftPct,
    required this.opzRightPct,
    required this.nowPct,
  });

  /// Builds the band geometry from the (already real) values on [data],
  /// mapping onto the 60-day rail `[scaleMin, scaleMax]` exactly as the
  /// proven baseline_tracker band maps onto its historical scale.
  factory OpzScaleGeometry.fromData(CplhOpzBandData data) {
    final floorPct = data.fractionFor(data.opzFloor);
    final ceilPct = data.fractionFor(data.opzCeiling);

    return OpzScaleGeometry._(
      railLowPct: data.fractionFor(data.sixtyDayLow),
      railHighPct: data.fractionFor(data.sixtyDayHigh),
      opzLeftPct: floorPct,
      // CSS `right:` inset (mockup `.opzbox{...;right:21%}`): the gap
      // from the rail's right edge to the OPZ ceiling.
      opzRightPct: (1.0 - ceilPct).clamp(0.0, 1.0),
      nowPct: data.fractionFor(data.now),
    );
  }

  /// 60-day low/high rail fractions. These are the rail ENDS
  /// (~0.0 / ~1.0) because the domain is exactly `[sixtyDayLow,
  /// sixtyDayHigh]` (mirroring the mockup `.tickm` `left:0` / `right:0`
  /// and the proven band's left/right endpoint ticks). In the degenerate
  /// widened-scale case the low/high land symmetrically interior, exactly
  /// as the proven band's endpoints do under its `target ± 1.0` guard.
  final double railLowPct;
  final double railHighPct;

  /// OPZ box left edge fraction (== `pct(opzFloor)`). Strictly interior
  /// (> 0) in every realistic scenario because the rail is the widest
  /// observed bound.
  final double opzLeftPct;

  /// OPZ box right INSET fraction (== `1 - pct(opzCeiling)`), mirroring
  /// the mockup's CSS `right:` so the box spans floor->ceiling. Strictly
  /// interior (> 0) in every realistic scenario.
  final double opzRightPct;

  /// OPZ ceiling rail fraction (the box's right edge position).
  double get opzCeilingPct => (1.0 - opzRightPct).clamp(0.0, 1.0);

  /// Width of the OPZ box as a fraction of the rail.
  double get opzWidthPct => (opzCeilingPct - opzLeftPct).clamp(0.0, 1.0);

  /// Now-marker rail fraction (dot + label share this position).
  final double nowPct;
}

/// The `.opzscale` band, laid out 1:1 with the approved mockup
/// (docs/f&f Coaching/variance_tab_v2_mockup.html `#hist .opzscale`,
/// CSS lines 153-159, DOM lines 277-283), under the operator-approved
/// REUSED model (the rail IS the proven 60-day CPLH low/high range, same
/// source + math as the baseline_tracker "CPLH RANGE & TARGET" band):
///
///   - `.lived` : a single full-width rail (`left:0; right:0`). The
///     domain is exactly `[sixtyDayLow, sixtyDayHigh]`, so those bounds
///     ARE the rail ends.
///   - `.tickm` : the 60-day low / 60-day high labels at the rail ends
///     (~0% / ~100%), exactly like the mockup `left:0` / `right:0` and
///     the proven band's endpoint labels. Real 60-day bounds.
///   - `.opzbox`: the green OPZ zone, `pct(opzFloor)`->`pct(opzCeiling)`.
///     A strictly interior band by construction (the rail is the widest
///     observed bound) — exactly the proven band's inner range box.
///   - `.opzlab`: `OPZ {floor}` at the box's left edge and `{ceiling}`
///     near its right edge, ABOVE the green box. The text is ALWAYS the
///     TRUE floor/ceiling (`data.opzFloor` / `data.opzCeiling`).
///   - `.nowdot`: the red current-CPLH dot, centred on `pct(now)`.
///   - `.nowlab`: `now {value}` DIRECTLY BELOW the dot, sharing
///     `pct(now)` so it tracks under the dot.
///
/// Positions are derived ONLY from the real values already on [data]
/// (60-day bounds from the proven `BaselineData.historicalContextRecords`
/// source, OPZ bounds from the active target profile, now from the latest
/// real week). No mockup constant is ever drawn. The mockup's
/// `46% / 21% / 36%` percentages are an illustrative example, not
/// literals.
class _OpzScale extends StatelessWidget {
  const _OpzScale({required this.data});

  final CplhOpzBandData data;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final g = OpzScaleGeometry.fromData(data);
        final floorX = g.opzLeftPct * w;
        final ceilX = g.opzCeilingPct * w;
        final nowX = g.nowPct * w;
        final railLowX = g.railLowPct * w;
        final railHighX = g.railHighPct * w;
        final hasNow = data.now > 0;

        // Box edges, kept on-rail. The geometry is interior by
        // construction; this is belt-and-braces float-drift safety,
        // identical in spirit to the proven band's own clamp
        // (baseline_tracker.dart:332-334).
        final boxLeft = floorX.clamp(0.0, w);
        final boxRight = ceilX.clamp(0.0, w);
        final boxWidth = (boxRight - boxLeft).clamp(1.0, w);

        // Vertical geometry mirrors the mockup `.opzscale` (54px tall;
        // 60 here for label headroom under the rail):
        //   .opzlab top:-2   (above the green box)
        //   .opzbox top:16  height:19
        //   .nowdot top:6   (on the rail)
        //   .lived  top:24  height:3   (full-width rail)
        //   .tickm  top:30  (60-day low/high at the rail ends)
        //   .nowlab top:40  (directly below the dot)
        const scaleHeight = 60.0;

        return SizedBox(
          height: scaleHeight,
          width: double.infinity,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // .lived: full-width rail (mockup `left:0; right:0`). The
              // domain IS the 60-day low/high range, so the rail spans
              // exactly sixtyDayLow..sixtyDayHigh.
              Positioned(
                top: 26,
                left: 0,
                right: 0,
                child: Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: AppColors.borderSubtle,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),

              // .opzbox: the green healthy zone, pct(opzFloor) ->
              // pct(opzCeiling). A strictly interior band by
              // construction (the rail is the widest observed bound),
              // exactly the proven band's inner range box.
              Positioned(
                top: 18,
                left: boxLeft,
                width: boxWidth,
                child: Container(
                  height: 19,
                  decoration: BoxDecoration(
                    color: AppColors.positive.withValues(alpha: 0.16),
                    border: Border.all(
                      color: AppColors.positive.withValues(alpha: 0.5),
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ),

              // .opzlab: "OPZ {floor}" ABOVE the green box, at its left
              // edge. The TEXT is always the TRUE floor value.
              Positioned(
                top: 0,
                left: boxLeft,
                child: Text(
                  'OPZ ${data.opzFloor.toStringAsFixed(2)}',
                  style: AppTextStyles.mono10(color: AppColors.positive),
                ),
              ),

              // .opzlab: ceiling value ABOVE the green box, at its right
              // edge. Always the TRUE ceiling.
              Positioned(
                top: 0,
                left: boxRight,
                child: FractionalTranslation(
                  translation: const Offset(-1.0, 0),
                  child: Text(
                    data.opzCeiling.toStringAsFixed(2),
                    style: AppTextStyles.mono10(color: AppColors.positive),
                  ),
                ),
              ),

              // .tickm: 60-day LOW at the rail's LEFT end (mockup
              // `left:0`). The domain IS the 60-day range, so the low
              // sits at ~0%. Real lowest CPLH last 60 days, from the
              // proven source.
              Positioned(
                top: 32,
                left: railLowX,
                child: Text(
                  data.sixtyDayLow.toStringAsFixed(1),
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
              ),

              // .tickm: 60-day HIGH at the rail's RIGHT end (mockup
              // `right:0`). The domain IS the 60-day range, so the high
              // sits at ~100%. Right-aligned so the label reads up to
              // that position rather than spilling past it. Real highest
              // CPLH last 60 days, from the proven source.
              Positioned(
                top: 32,
                left: railHighX,
                child: FractionalTranslation(
                  translation: const Offset(-1.0, 0),
                  child: Text(
                    data.sixtyDayHigh.toStringAsFixed(1),
                    style: AppTextStyles.mono10(color: AppColors.textMuted),
                  ),
                ),
              ),

              // .nowdot: red current-CPLH marker on the rail, centred
              // on its value position.
              if (hasNow)
                Positioned(
                  top: 8,
                  left: nowX - 5.5,
                  child: Container(
                    width: 11,
                    height: 11,
                    decoration: const BoxDecoration(
                      color: AppColors.negative,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),

              // .nowlab: "now {cplh}" DIRECTLY BELOW the dot, tracking
              // the dot's position (mockup `top:40`, translateX(-50%)).
              if (hasNow)
                Positioned(
                  top: 42,
                  left: nowX,
                  child: FractionalTranslation(
                    translation: const Offset(-0.5, 0),
                    child: Text(
                      'now ${data.now.toStringAsFixed(2)}',
                      style: AppTextStyles.mono10(color: AppColors.negative)
                          .copyWith(fontWeight: FontWeight.w700),
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
