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

  /// The scale domain the band is mapped onto. Chosen so the lived range,
  /// the OPZ box, and the "now" marker all fall inside [0, 1] after
  /// normalisation, with a small visual margin.
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

  /// Normalised [0,1] position of [value] on the scale domain. Clamped so
  /// a marker never escapes the rail even if the domain padding is tight.
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

    // The scale must contain everything we draw: the lived range, the OPZ
    // box, and the "now" marker. Otherwise the box / dot would clip.
    // `opzFloor` / `opzCeiling` are non-null here: the `hasOpz` guard
    // above proved it and the analyzer promotes them.
    var domainMin = livedMin;
    var domainMax = livedMax;
    domainMin = domainMin < opzFloor ? domainMin : opzFloor;
    domainMax = domainMax > opzCeiling ? domainMax : opzCeiling;
    if (now != null) {
      domainMin = domainMin < now ? domainMin : now;
      domainMax = domainMax > now ? domainMax : now;
    }

    // Small visual margin so endpoints are not flush against the edge.
    final rawSpan = domainMax - domainMin;
    final pad = rawSpan > 0 ? rawSpan * 0.08 : 0.1;
    final scaleMin = domainMin - pad;
    final scaleMax = domainMax + pad;

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

/// The `.opzscale` band: a lived-range rail, min/max ticks, the green OPZ
/// box, OPZ + ceiling labels, and the red "now" dot + label. Laid out
/// with [LayoutBuilder] so positions map to the same fractional geometry
/// as the mockup's percentage `left/right` styles.
class _OpzScale extends StatelessWidget {
  const _OpzScale({required this.data});

  final CplhOpzBandData data;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final livedLeft = data.fractionFor(data.livedMin) * w;
        final livedRight = data.fractionFor(data.livedMax) * w;
        final floorX = data.fractionFor(data.opzFloor) * w;
        final ceilX = data.fractionFor(data.opzCeiling) * w;
        final nowX = data.fractionFor(data.now) * w;
        final hasNow = data.now > 0;

        // Geometry mirrors the mockup `.opzscale` (54px tall):
        //   rail   top:24  height:3
        //   box    top:16  height:19
        //   labels top:-2 (opz) / top:30 (ticks) / top:40 (now)
        const scaleHeight = 60.0;

        return SizedBox(
          height: scaleHeight,
          width: double.infinity,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // .lived rail — full lived min..max span.
              Positioned(
                top: 30,
                left: livedLeft,
                width: (livedRight - livedLeft).clamp(1.0, w),
                child: Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: AppColors.borderSubtle,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),

              // .opzbox — the green healthy zone.
              Positioned(
                top: 22,
                left: floorX,
                width: (ceilX - floorX).clamp(1.0, w),
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

              // .opzlab — "OPZ {floor}" at the box left edge.
              Positioned(
                top: 0,
                left: floorX,
                child: Text(
                  'OPZ ${data.opzFloor.toStringAsFixed(2)}',
                  style: AppTextStyles.mono10(color: AppColors.positive),
                ),
              ),

              // .opzlab — ceiling value at the box right edge.
              Positioned(
                top: 0,
                left: ceilX,
                child: FractionalTranslation(
                  translation: const Offset(-1.0, 0),
                  child: Text(
                    data.opzCeiling.toStringAsFixed(2),
                    style: AppTextStyles.mono10(color: AppColors.positive),
                  ),
                ),
              ),

              // .tickm — lived min label, left-anchored.
              Positioned(
                top: 44,
                left: livedLeft,
                child: Text(
                  data.livedMin.toStringAsFixed(1),
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
              ),

              // .tickm — lived max label, right-anchored.
              Positioned(
                top: 44,
                left: livedRight,
                child: FractionalTranslation(
                  translation: const Offset(-1.0, 0),
                  child: Text(
                    data.livedMax.toStringAsFixed(1),
                    style: AppTextStyles.mono10(color: AppColors.textMuted),
                  ),
                ),
              ),

              // .nowdot — red marker at the current CPLH.
              if (hasNow)
                Positioned(
                  top: 12,
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

              // .nowlab — "now {cplh}" centred under the dot.
              if (hasNow)
                Positioned(
                  top: 44,
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
