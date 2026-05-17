// === CplhOpzBandCard : Variance Coaching V2 (Lane HIST) ====================
// The mockup `#hist` "CPLH vs your OPZ · 60-day" card
// (docs/f&f Coaching/variance_tab_v2_mockup.html, lines ~275-288).
//
// Renders the green-zone band that shows where the operator's lived CPLH
// has run relative to the active target profile's CPLH OPZ floor/ceiling,
// plus the "What the zone is telling you" teaching narrative.
//
// Authority: docs/contracts/phase_7_58_primary_driver_contract.md.
//   - V2-4: inline emphasis is applied at RENDER time, never stored. The
//     "below it N of the last M weeks" span is wrapped in the V2-4
//     `[[bad:…]]` token and rendered through InlineEmphasisText, which
//     owns the verbatim-fallback contract.
//   - V2-6: Telestrator stays EXCLUDED. This is the existing OPZ band
//     concept, sourced from data the History tab already loads + the
//     active target profile's CPLH OPZ bounds. NO new math, no engine
//     change (lib/services/labor_model.dart is FROZEN).
//
// Metric Honesty Doctrine: when the OPZ bounds or the lived CPLH series
// are unavailable, this renders an honest degraded state (no fabricated
// green zone, no phantom zeroes). The mockup is one populated example,
// not a guaranteed shape.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'inline_emphasis_text.dart';

/// Geometry + narrative inputs for the CPLH-vs-OPZ 60-day band.
///
/// Built by [CplhOpzBandData.fromInputs] from the per-week CPLH series the
/// History tab already loads (`WeekRecord.avgCPLH`) plus the active target
/// profile's CPLH OPZ floor/ceiling. Returns a non-renderable instance
/// (`canRenderBand == false`) whenever the honest preconditions are not
/// met, so the widget can degrade instead of fabricating a zone.
@immutable
class CplhOpzBandData {
  const CplhOpzBandData._({
    required this.canRenderBand,
    this.livedMin = 0,
    this.livedMax = 0,
    this.scaleMin = 0,
    this.scaleMax = 0,
    this.opzFloor = 0,
    this.opzCeiling = 0,
    this.now = 0,
    this.weeksBelowFloor = 0,
    this.weekCount = 0,
  });

  /// True only when every band element can be drawn honestly: a usable
  /// OPZ range AND at least one lived CPLH observation.
  final bool canRenderBand;

  /// Lived CPLH range endpoints (the `.tickm` min/max labels).
  final double livedMin;
  final double livedMax;

  /// Retained for API stability. Option 1 (operator-approved, mockup-
  /// faithful) maps render geometry onto the lived 60-day range
  /// `[livedMin, livedMax]` via [OpzScaleGeometry], NOT onto a union
  /// domain, so these are no longer the active scale. They mirror the
  /// lived range so any legacy `fractionFor` caller stays well-defined.
  final double scaleMin;
  final double scaleMax;

  /// Active target profile CPLH OPZ bounds (the green box edges).
  final double opzFloor;
  final double opzCeiling;

  /// Most recent week's CPLH (the red "now" marker).
  final double now;

  /// How many of the last [weekCount] weeks ran below [opzFloor].
  final int weeksBelowFloor;
  final int weekCount;

  /// Normalised [0,1] position of [value] on the lived 60-day range.
  /// Option 1: the rail IS the real lived range, so this maps onto
  /// `[livedMin, livedMax]` and clamps so a marker (or a clamped OPZ
  /// edge) never escapes the rail. `scaleMin`/`scaleMax` mirror the
  /// lived range, so legacy callers get the same answer as the new
  /// [OpzScaleGeometry] helper.
  double fractionFor(double value) {
    final span = scaleMax - scaleMin;
    if (span <= 0) return 0;
    return ((value - scaleMin) / span).clamp(0.0, 1.0);
  }

  /// Builds band geometry from the data the History tab already has.
  ///
  /// [weeklyCplhSeries] is the per-week `avgCPLH` series (newest first is
  /// not required; the most recent week is identified by [nowCplh]).
  /// [opzFloor]/[opzCeiling] come from the active target profile. Any of
  /// these being null/absent yields an honest degraded result.
  static CplhOpzBandData fromInputs({
    required List<double> weeklyCplhSeries,
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

    final now =
        (nowCplh != null && nowCplh.isFinite && nowCplh > 0) ? nowCplh : null;

    // Honest precondition: we need a usable OPZ range AND at least one
    // lived observation. Without either we cannot draw a truthful band.
    if (!hasOpz || lived.isEmpty) {
      return const CplhOpzBandData._(canRenderBand: false);
    }

    final livedMin = lived.reduce((a, b) => a < b ? a : b);
    final livedMax = lived.reduce((a, b) => a > b ? a : b);

    // Option 1 (operator-approved, mockup-faithful): the rail IS the
    // real 60-day lived range. Render geometry maps onto
    // `[livedMin, livedMax]` (see [OpzScaleGeometry]); the OPZ box and
    // now marker are CLAMPED to the rail and an extends-beyond cap
    // signals when the healthy zone continues past the observed range.
    // `scaleMin`/`scaleMax` therefore mirror the lived range so the
    // legacy `fractionFor` agrees with the new helper. This is a
    // RENDER-domain choice only; livedMin/Max, opzFloor/Ceiling, now,
    // weeksBelowFloor and weekCount are computed exactly as before.
    final scaleMin = livedMin;
    final scaleMax = livedMax;

    final weeksBelowFloor =
        lived.where((v) => v < opzFloor).length;

    return CplhOpzBandData._(
      canRenderBand: true,
      livedMin: livedMin,
      livedMax: livedMax,
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
    // The "below it N of last M weeks" span is the only emphasised span
    // and is wrapped in the V2-4 `[[bad:…]]` token at RENDER time
    // (never stored), then rendered through InlineEmphasisText which
    // owns the verbatim plain-text fallback.
    const intro = 'What the zone is telling you. The green band is where '
        'your CPLH is healthy: enough hands to take care of the guest, not '
        'so many you are paying for tables that are not there. ';

    final String body;
    if (n == 0) {
      body = 'You have stayed in or above it every one of the last '
          '$m ${_weekWord(m)}. Hold the line: this is the hours matching '
          'the volume.';
    } else if (n == m) {
      body = 'You have sat [[bad:below it ${_count(n, m)}]]. The volume '
          'keeps showing up. The hours are not tightening to meet it.';
    } else {
      body = 'You have sat [[bad:below it ${_count(n, m)}]]. The volume '
          'keeps showing up on those weeks. The hours are not tightening '
          'to meet it.';
    }

    return InlineEmphasisText(
      '$intro$body',
      baseStyle: AppTextStyles.body14(color: AppColors.textPrimary),
    );
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
/// Option 1 (operator-approved, mockup-faithful). The rail IS the real
/// 60-day lived CPLH range: `domain = [livedMin, livedMax]` and
/// `pct(v) = clamp01((v - livedMin) / (livedMax - livedMin))`. The lived
/// min/max land at the rail ends (~0% / ~100%), exactly like the mockup
/// `.tickm` `left:0` / `right:0`.
///
/// The green OPZ box maps `opzFloor`->`opzCeiling` into that domain and
/// CLAMPS to `[0%, 100%]`:
///   - OPZ inside the lived range  -> an interior band (mockup shape);
///   - OPZ extends past an end     -> the box clamps to that rail edge
///     and an extends-beyond cap ([leftCap] / [rightCap]) signals the
///     healthy zone continues past the observed range.
///
/// HONEST LABELS: the box edge clamps, but the `.opzlab` text always
/// shows the TRUE `opzFloor` / `opzCeiling` numbers (the widget reads
/// `data.opzFloor` / `data.opzCeiling`, never a clamped value). The cap
/// flags here only drive the subtle edge affordance.
///
/// This is a presentation transform of values the data layer already
/// derived. It does NOT touch [CplhOpzBandData.fromInputs] math or any
/// data source. Exposed so the geometry is verifiable without eyeballing
/// the rendered widget.
@immutable
class OpzScaleGeometry {
  const OpzScaleGeometry._({
    required this.livedMinPct,
    required this.livedMaxPct,
    required this.opzLeftPct,
    required this.opzRightPct,
    required this.nowPct,
    required this.leftCap,
    required this.rightCap,
  });

  /// Builds the band geometry from the (already real) values on [data],
  /// mapping onto the lived range `[livedMin, livedMax]` and clamping the
  /// OPZ box / now marker to the rail.
  factory OpzScaleGeometry.fromData(CplhOpzBandData data) {
    // `pct` clamps to [0,1] via [CplhOpzBandData.fractionFor], whose
    // domain is the lived range (scaleMin/scaleMax mirror livedMin/Max).
    final floorClamped = data.fractionFor(data.opzFloor);
    final ceilClamped = data.fractionFor(data.opzCeiling);

    // Extends-beyond detection uses the TRUE values (not the clamped
    // fractions): the zone continues past an observed end when the OPZ
    // bound sits outside the lived range. Strictly-outside only, so an
    // exact touch (opzFloor == livedMin) is the mockup interior case,
    // not a cap.
    final extendsLeft = data.opzFloor < data.livedMin;
    final extendsRight = data.opzCeiling > data.livedMax;

    return OpzScaleGeometry._(
      livedMinPct: data.fractionFor(data.livedMin),
      livedMaxPct: data.fractionFor(data.livedMax),
      opzLeftPct: floorClamped,
      // CSS `right:` inset (mockup `.opzbox{...;right:21%}`): the gap
      // from the rail's right edge to the (clamped) OPZ ceiling.
      opzRightPct: (1.0 - ceilClamped).clamp(0.0, 1.0),
      nowPct: data.fractionFor(data.now),
      leftCap: extendsLeft,
      rightCap: extendsRight,
    );
  }

  /// Lived-range min/max rail fractions. These are the rail ENDS
  /// (~0.0 / ~1.0) because the domain is exactly `[livedMin, livedMax]`,
  /// mirroring the mockup `.tickm` `left:0` / `right:0`.
  final double livedMinPct;
  final double livedMaxPct;

  /// OPZ box left edge fraction (== clamped `pct(opzFloor)`). 0.0 when
  /// the floor extends past the lived min (clamped to the rail edge).
  final double opzLeftPct;

  /// OPZ box right INSET fraction (== `1 - clamped pct(opzCeiling)`),
  /// mirroring the mockup's CSS `right:` so the box spans floor->ceiling.
  /// 0.0 when the ceiling extends past the lived max.
  final double opzRightPct;

  /// True when the OPZ floor sits below the lived min: the green box is
  /// clamped at the LEFT rail edge and the left extends-beyond cap is
  /// drawn (the healthy zone continues below the observed range).
  final bool leftCap;

  /// True when the OPZ ceiling sits above the lived max: the green box
  /// is clamped at the RIGHT rail edge and the right extends-beyond cap
  /// is drawn (the healthy zone continues above the observed range).
  final bool rightCap;

  /// OPZ ceiling rail fraction (the box's right edge position).
  double get opzCeilingPct => (1.0 - opzRightPct).clamp(0.0, 1.0);

  /// Width of the OPZ box as a fraction of the rail. When the zone is
  /// wider than the lived range on both sides this is ~1.0 (the box
  /// fills the rail and BOTH caps signal it continues past each end).
  double get opzWidthPct => (opzCeilingPct - opzLeftPct).clamp(0.0, 1.0);

  /// Now-marker rail fraction (dot + label share this position),
  /// clamped to the rail.
  final double nowPct;
}

/// The `.opzscale` band, laid out 1:1 with the approved mockup
/// (docs/f&f Coaching/variance_tab_v2_mockup.html `#hist .opzscale`,
/// CSS lines 153-159, DOM lines 277-283), under the operator-approved
/// Option 1 (the rail IS the real 60-day lived range):
///
///   - `.lived` : a single full-width rail (`left:0; right:0`). The
///     domain is exactly `[livedMin, livedMax]`, so the lived min/max
///     ARE the rail ends.
///   - `.tickm` : the lived-min / lived-max labels at the rail ends
///     (~0% / ~100%), exactly like the mockup `left:0` / `right:0`.
///     Real lived-range bounds, not the OPZ bounds.
///   - `.opzbox`: the green OPZ zone, `pct(opzFloor)`->`pct(opzCeiling)`
///     CLAMPED to the rail. Interior band when the zone fits inside the
///     lived range (mockup shape); clamps to a rail edge when it
///     extends past an end.
///   - extends-beyond cap: a subtle on-theme chevron at a clamped edge
///     ([OpzScaleGeometry.leftCap] / `rightCap`) signalling the healthy
///     zone continues past the observed range. The only new visual.
///   - `.opzlab`: `OPZ {floor}` at the box's (possibly clamped) left
///     edge and `{ceiling}` near its right edge, ABOVE the green box.
///     The text is ALWAYS the TRUE floor/ceiling (`data.opzFloor` /
///     `data.opzCeiling`), never the clamped position's value.
///   - `.nowdot`: the red current-CPLH dot, centred on clamped
///     `pct(now)`.
///   - `.nowlab`: `now {value}` DIRECTLY BELOW the dot, sharing
///     `pct(now)` so it tracks under the dot.
///
/// Positions are derived ONLY from the real values already on [data]
/// (lived bounds from the real `weeklyCplhSeries`, OPZ bounds from the
/// active target profile, now from the latest real week), mapped onto
/// the lived range. No mockup constant is ever drawn. The mockup's
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
        final livedMinX = g.livedMinPct * w;
        final livedMaxX = g.livedMaxPct * w;
        final hasNow = data.now > 0;

        // Box edges, kept on-rail (the geometry already clamps; this
        // belt-and-braces guards float drift at the very edges).
        final boxLeft = floorX.clamp(0.0, w);
        final boxRight = ceilX.clamp(0.0, w);
        final boxWidth = (boxRight - boxLeft).clamp(1.0, w);

        // Vertical geometry mirrors the mockup `.opzscale` (54px tall;
        // 60 here for label headroom under the rail):
        //   .opzlab top:-2   (above the green box)
        //   .opzbox top:16  height:19
        //   .nowdot top:6   (on the rail)
        //   .lived  top:24  height:3   (full-width rail)
        //   .tickm  top:30  (lived min/max at the rail ends)
        //   .nowlab top:40  (directly below the dot)
        const scaleHeight = 60.0;

        return SizedBox(
          height: scaleHeight,
          width: double.infinity,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // .lived: full-width rail (mockup `left:0; right:0`). The
              // domain IS the lived range, so the rail spans exactly
              // livedMin..livedMax.
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
              // pct(opzCeiling) CLAMPED to the rail. Interior band when
              // the zone fits inside the lived range (mockup shape);
              // clamps to a rail edge when it extends past an end.
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

              // Extends-beyond cap (LEFT): a subtle on-theme chevron at
              // the clamped left edge signalling the healthy zone
              // continues BELOW the observed 60-day range. Subtle, not a
              // big arrow. The OPZ label still shows the TRUE floor.
              if (g.leftCap)
                Positioned(
                  top: 18,
                  left: boxLeft,
                  child: const _ExtendsBeyondCap(pointsLeft: true),
                ),

              // Extends-beyond cap (RIGHT): same affordance at the
              // clamped right edge (zone continues ABOVE the range).
              if (g.rightCap)
                Positioned(
                  top: 18,
                  left: (boxRight - _ExtendsBeyondCap.width).clamp(0.0, w),
                  child: const _ExtendsBeyondCap(pointsLeft: false),
                ),

              // .opzlab: "OPZ {floor}" ABOVE the green box, at its
              // (possibly clamped) left edge. The TEXT is always the
              // TRUE floor value, never the clamped position's value
              // (honest-labels-even-when-clamped).
              Positioned(
                top: 0,
                left: boxLeft,
                child: Text(
                  'OPZ ${data.opzFloor.toStringAsFixed(2)}',
                  style: AppTextStyles.mono10(color: AppColors.positive),
                ),
              ),

              // .opzlab: ceiling value ABOVE the green box, at its
              // (possibly clamped) right edge. Always the TRUE ceiling.
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

              // .tickm: lived MIN at the rail's LEFT end (mockup
              // `left:0`). The domain IS the lived range, so livedMin
              // sits at ~0%. Real lived-range lower bound.
              Positioned(
                top: 32,
                left: livedMinX,
                child: Text(
                  data.livedMin.toStringAsFixed(1),
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
              ),

              // .tickm: lived MAX at the rail's RIGHT end (mockup
              // `right:0`). The domain IS the lived range, so livedMax
              // sits at ~100%. Right-aligned so the label reads up to
              // that position rather than spilling past it. Real
              // lived-range upper bound.
              Positioned(
                top: 32,
                left: livedMaxX,
                child: FractionalTranslation(
                  translation: const Offset(-1.0, 0),
                  child: Text(
                    data.livedMax.toStringAsFixed(1),
                    style: AppTextStyles.mono10(color: AppColors.textMuted),
                  ),
                ),
              ),

              // .nowdot: red current-CPLH marker on the rail, centred
              // on its (clamped) value position.
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

/// Subtle on-theme extends-beyond affordance drawn at a CLAMPED OPZ box
/// edge. Signals the healthy zone continues past the observed 60-day
/// range without shouting: a small chevron in the same OPZ green,
/// matching the green box height (19px) so it reads as part of the zone,
/// not a separate control. Deliberately small (not a big arrow): the
/// card stays clean like the mockup, and the honest `.opzlab` text still
/// carries the TRUE OPZ bound number, so this is purely "there's more
/// healthy zone off this edge".
class _ExtendsBeyondCap extends StatelessWidget {
  const _ExtendsBeyondCap({required this.pointsLeft});

  /// Chevron points outward from the rail: left at the left-clamped
  /// edge, right at the right-clamped edge.
  final bool pointsLeft;

  /// Footprint width so callers can right-align the right-edge cap.
  static const double width = 7.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: 19,
      child: CustomPaint(
        painter: _ChevronPainter(
          pointsLeft: pointsLeft,
          color: AppColors.positive.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

class _ChevronPainter extends CustomPainter {
  _ChevronPainter({required this.pointsLeft, required this.color});

  final bool pointsLeft;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final midY = size.height / 2;
    // A single small `>` / `<` chevron, vertically centred, inset a
    // touch from the edge so it sits just past the clamped box border.
    const inset = 1.5;
    final path = Path();
    if (pointsLeft) {
      path
        ..moveTo(size.width - inset, midY - 4)
        ..lineTo(inset, midY)
        ..lineTo(size.width - inset, midY + 4);
    } else {
      path
        ..moveTo(inset, midY - 4)
        ..lineTo(size.width - inset, midY)
        ..lineTo(inset, midY + 4);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ChevronPainter old) =>
      old.pointsLeft != pointsLeft || old.color != color;
}
