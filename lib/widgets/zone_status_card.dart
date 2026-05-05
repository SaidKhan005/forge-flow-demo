import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'opz_matrix_grid.dart';

class ZoneStatusCard extends StatelessWidget {
  final double currentCPLH;
  final double opzFloorCPLH;
  final double opzCeilingCPLH;
  final double targetCPLH;
  final String opzStatus;
  final String opzLabel;
  final String opzSubLabel;

  /// 7.58 depth wave (slice 10.5.6): SPLH band for the cross-axis matrix
  /// grid rendered inside the OPZ tile. `'below'` / `'on'` / `'above'`
  /// when BOH minutes are logged; null when BOH has not punched in yet,
  /// which the matrix grid renders as nine dim cells with no active
  /// marker.
  final String? splhState;

  const ZoneStatusCard({
    super.key,
    required this.currentCPLH,
    required this.opzFloorCPLH,
    required this.opzCeilingCPLH,
    required this.targetCPLH,
    required this.opzStatus,
    required this.opzLabel,
    required this.opzSubLabel,
    this.splhState,
  });

  static OpzCplhBand _cplhBandFor(String status) {
    switch (status) {
      case 'above':
        return OpzCplhBand.aboveCeiling;
      case 'below':
        return OpzCplhBand.belowFloor;
      default:
        return OpzCplhBand.inOpz;
    }
  }

  static OpzSplhBand? _splhBandFor(String? state) {
    switch (state) {
      case 'below':
        return OpzSplhBand.low;
      case 'on':
        return OpzSplhBand.onTarget;
      case 'above':
        return OpzSplhBand.high;
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final opzColor = opzStatus == 'in'
        ? AppColors.positive
        : opzStatus == 'below'
            ? AppColors.negative
            : AppColors.warning;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.backgroundSurface.withValues(alpha: 0.6),
            AppColors.shimmer,
            AppColors.cardGlow,
          ],
        ),
        border: Border.all(
            color: AppColors.borderStrong.withValues(alpha: 0.7), width: 2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('CURRENT CPLH',
              style: AppTextStyles.mono10(color: AppColors.textMuted)),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                currentCPLH.toStringAsFixed(2),
                style: AppTextStyles.mono28(color: AppColors.textPrimary),
              ),
              const Spacer(),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(opzLabel,
                      style: AppTextStyles.mono28(color: opzColor)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _CplhGauge(
            opzFloor: opzFloorCPLH,
            opzCeiling: opzCeilingCPLH,
            target: targetCPLH,
            current: currentCPLH,
          ),
          // 7.58 depth wave (slice 10.5.6): 3x3 cross-axis matrix grid +
          // joint cross-axis sub-label, lifted inside the OPZ tile so
          // operators see the joint diagnosis without scanning a sibling
          // card.
          OpzMatrixGrid(
            cplh: _cplhBandFor(opzStatus),
            splh: _splhBandFor(splhState),
          ),
          const SizedBox(height: 8),
          Text(
            opzSubLabel,
            key: const Key('opz_sub_label'),
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

// ─── Normalized CPLH gauge ───────────────────────────────────────────────────

class _CplhGauge extends StatelessWidget {
  final double opzFloor;
  final double opzCeiling;
  final double target;
  final double current;

  const _CplhGauge({
    required this.opzFloor,
    required this.opzCeiling,
    required this.target,
    required this.current,
  });

  // Threshold for treating two values as "same" (hides duplicate labels)
  static const _nearThreshold = 0.02;

  @override
  Widget build(BuildContext context) {
    // ── Defensive clamping — keep floor/ceiling inside gauge bounds ────────
    const double gaugeMin = 0.0;
    const double gaugeMax = 7.5;

    final safeFloor = opzFloor.clamp(gaugeMin, gaugeMax);
    final safeCeiling = math.max(safeFloor, opzCeiling.clamp(gaugeMin, gaugeMax));

    // ── Raw data ranges ───────────────────────────────────────────────────
    final rawBelowRange = safeFloor - gaugeMin;
    final rawOpzRange = safeCeiling - safeFloor;
    final rawAboveRange = gaugeMax - safeCeiling;

    // ── Normalized scale math ─────────────────────────────────────────────
    // Give the OPZ band a guaranteed minimum visual share so it's always
    // readable. Wider OPZs render wider, tighter OPZs render narrower,
    // but never less than 30% of the bar.
    //
    // Edge case: if OPZ spans the entire gauge (floor=0, ceiling=7.5),
    // let it take 100% — there is no below or above zone to show.
    final rawTotal = gaugeMax - gaugeMin;
    final naturalOpzShare = rawTotal > 0 ? rawOpzRange / rawTotal : 0.0;

    final double opzVisualShare;
    final double belowShare;
    final double aboveShare;

    if (naturalOpzShare >= 0.95) {
      // OPZ spans (nearly) the entire gauge — give it everything
      opzVisualShare = 1.0;
      belowShare = 0.0;
      aboveShare = 0.0;
    } else {
      opzVisualShare =
          math.max(0.30, naturalOpzShare * 3.0).clamp(0.30, 0.55);
      final remainingShare = 1.0 - opzVisualShare;
      final belowAboveTotal = rawBelowRange + rawAboveRange;
      belowShare = belowAboveTotal > 0
          ? remainingShare * (rawBelowRange / belowAboveTotal)
          : remainingShare / 2;
      aboveShare = remainingShare - belowShare;
    }

    // ── Detect degenerate cases for label deduplication ───────────────────
    final floorNearTarget = (safeFloor - target).abs() < _nearThreshold;
    final ceilingNearTarget = (safeCeiling - target).abs() < _nearThreshold;
    final floorNearCeiling = (safeFloor - safeCeiling).abs() < _nearThreshold;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        if (totalWidth <= 0) return const SizedBox.shrink();

        final belowW = totalWidth * belowShare;
        final opzW = totalWidth * opzVisualShare;
        final aboveW = totalWidth * aboveShare;

        // ── Piecewise value → pixel mapping ──────────────────────────────
        double valueToPixel(double value) {
          if (value <= gaugeMin) return 0.0;
          if (value >= gaugeMax) return totalWidth;
          if (value <= safeFloor) {
            final frac =
                rawBelowRange > 0 ? (value - gaugeMin) / rawBelowRange : 0.0;
            return frac * belowW;
          } else if (value <= safeCeiling) {
            final frac =
                rawOpzRange > 0 ? (value - safeFloor) / rawOpzRange : 0.5;
            return belowW + frac * opzW;
          } else {
            final frac = rawAboveRange > 0
                ? (value - safeCeiling) / rawAboveRange
                : 1.0;
            return belowW + opzW + frac * aboveW;
          }
        }

        final currentPos = valueToPixel(current).clamp(0.0, totalWidth);
        final targetPos = valueToPixel(target).clamp(0.0, totalWidth);
        final floorPos = belowW;
        final ceilingPos = belowW + opzW;

        // ── Layout constants ─────────────────────────────────────────────
        const barH = 20.0;
        const labelGap = 8.0;
        const labelRowH = 34.0;
        const totalH = barH + labelGap + labelRowH;

        // ── Build the list of visible labels below the bar ───────────────
        // Deduplicate: hide floor/ceiling labels when they ≈ target.
        final showFloor = !floorNearTarget && !floorNearCeiling;
        final showCeiling = !ceilingNearTarget && !floorNearCeiling;

        // Adaptive label width — shrink if widget is very narrow
        final valW = math.min(48.0, totalWidth / 3 - 4);
        if (valW < 20) {
          // Widget too narrow for any labels — just show bar + markers
          return _buildBarOnly(
            totalWidth: totalWidth,
            belowW: belowW,
            opzW: opzW,
            aboveW: aboveW,
            currentPos: currentPos,
            targetPos: targetPos,
            floorPos: floorPos,
            ceilingPos: ceilingPos,
            floorNearCeiling: floorNearCeiling,
          );
        }

        double clampLeft(double center) =>
            (center - valW / 2)
                .clamp(0.0, math.max(0.0, totalWidth - valW));

        // Collect only the labels we actually show
        final labels = <_PosEntry>[];
        if (showFloor) {
          labels.add(_PosEntry('floor', clampLeft(floorPos)));
        }
        labels.add(_PosEntry('target', clampLeft(targetPos)));
        if (showCeiling) {
          labels.add(_PosEntry('ceiling', clampLeft(ceilingPos)));
        }

        // Sort left-to-right, nudge overlapping labels apart
        labels.sort((a, b) => a.left.compareTo(b.left));
        final spacing = valW + 4;
        for (int i = 1; i < labels.length; i++) {
          if (labels[i].left < labels[i - 1].left + spacing) {
            labels[i] =
                _PosEntry(labels[i].id, labels[i - 1].left + spacing);
          }
        }
        // Clamp rightmost back into bounds, push earlier labels left
        for (int i = labels.length - 1; i >= 0; i--) {
          labels[i] = _PosEntry(labels[i].id,
              labels[i].left.clamp(0.0, math.max(0.0, totalWidth - valW)));
          if (i > 0 && labels[i].left < labels[i - 1].left + spacing) {
            labels[i - 1] = _PosEntry(
                labels[i - 1].id, labels[i].left - spacing);
          }
        }
        // Final clamp pass
        for (int i = 0; i < labels.length; i++) {
          labels[i] = _PosEntry(labels[i].id,
              labels[i].left.clamp(0.0, math.max(0.0, totalWidth - valW)));
        }

        // Extract final positions
        double floorLeft = 0, targetLeft = 0, ceilingLeft = 0;
        for (final e in labels) {
          if (e.id == 'floor') floorLeft = e.left;
          if (e.id == 'target') targetLeft = e.left;
          if (e.id == 'ceiling') ceilingLeft = e.left;
        }

        // ── Current dot position, clamped so the circle stays visible ────
        final dotLeft = (currentPos - 9).clamp(-2.0, totalWidth - 16.0);

        // ── Zone label visibility thresholds ─────────────────────────────
        final showBelow = belowW > 28;
        final showAbove = aboveW > 28;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Semantic zone labels above bar ────────────────────────────
            Row(
              children: [
                SizedBox(
                  width: belowW,
                  child: showBelow
                      ? Text('BELOW',
                          style:
                              AppTextStyles.mono8(color: AppColors.negative),
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis)
                      : const SizedBox.shrink(),
                ),
                SizedBox(
                  width: opzW,
                  child: Text('OPTIMAL',
                      style: AppTextStyles.mono10(color: AppColors.positive),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis),
                ),
                SizedBox(
                  width: aboveW,
                  child: showAbove
                      ? Text('ABOVE',
                          style:
                              AppTextStyles.mono8(color: AppColors.warning),
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis)
                      : const SizedBox.shrink(),
                ),
              ],
            ),
            const SizedBox(height: 5),

            // ── Bar + ticks + dot + anchored values ──────────────────────
            SizedBox(
              height: totalH,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Bar segments
                  Row(
                    children: [
                      if (belowW > 0)
                        Container(
                          width: belowW,
                          height: barH,
                          color: AppColors.negative.withValues(alpha: 0.2),
                        ),
                      Container(
                        width: opzW,
                        height: barH,
                        decoration: BoxDecoration(
                          color: AppColors.positive.withValues(alpha: 0.35),
                          border: Border.all(
                            color: AppColors.positive.withValues(alpha: 0.7),
                            width: 1.5,
                          ),
                        ),
                      ),
                      if (aboveW > 0)
                        Container(
                          width: aboveW,
                          height: barH,
                          color: AppColors.warning.withValues(alpha: 0.15),
                        ),
                    ],
                  ),

                  // Floor tick — only when OPZ has real width
                  if (!floorNearCeiling && belowW > 0)
                    Positioned(
                      left: (floorPos - 1).clamp(0.0, totalWidth - 2),
                      top: -3,
                      child: Container(
                        width: 2,
                        height: barH + 6,
                        color: AppColors.positive.withValues(alpha: 0.7),
                      ),
                    ),

                  // Ceiling tick — only when OPZ has real width
                  if (!floorNearCeiling && aboveW > 0)
                    Positioned(
                      left: (ceilingPos - 1).clamp(0.0, totalWidth - 2),
                      top: -3,
                      child: Container(
                        width: 2,
                        height: barH + 6,
                        color: AppColors.positive.withValues(alpha: 0.7),
                      ),
                    ),

                  // Target tick — always visible, dominant teal
                  Positioned(
                    left: (targetPos - 1.5).clamp(0.0, totalWidth - 3),
                    top: -6,
                    child: Container(
                      width: 3,
                      height: barH + 12,
                      color: AppColors.sunset,
                    ),
                  ),

                  // Current position dot — clamped to stay visible
                  Positioned(
                    left: dotLeft,
                    top: (barH - 18) / 2,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: AppColors.textPrimary,
                        shape: BoxShape.circle,
                        border:
                            Border.all(color: AppColors.sunset, width: 2),
                      ),
                    ),
                  ),

                  // ── Anchored values below bar ──────────────────────────

                  // Floor value — only if distinct from target and from ceiling
                  if (showFloor)
                    Positioned(
                      left: floorLeft,
                      top: barH + labelGap,
                      child: SizedBox(
                        width: valW,
                        child: Text(
                          safeFloor.toStringAsFixed(2),
                          style: AppTextStyles.mono10(
                              color: AppColors.textSecondary),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),

                  // Target value — always visible, emphasized
                  Positioned(
                    left: targetLeft,
                    top: barH + labelGap,
                    child: SizedBox(
                      width: valW,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            target.toStringAsFixed(2),
                            style: AppTextStyles.mono12(
                                color: AppColors.sunsetDark),
                            textAlign: TextAlign.center,
                          ),
                          Text('TARGET',
                              style: AppTextStyles.mono7(
                                  color: AppColors.sunsetDark)),
                        ],
                      ),
                    ),
                  ),

                  // Ceiling value — only if distinct from target and from floor
                  if (showCeiling)
                    Positioned(
                      left: ceilingLeft,
                      top: barH + labelGap,
                      child: SizedBox(
                        width: valW,
                        child: Text(
                          safeCeiling.toStringAsFixed(2),
                          style: AppTextStyles.mono10(
                              color: AppColors.textSecondary),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// Ultra-narrow fallback — just the bar + markers, no text labels below.
  Widget _buildBarOnly({
    required double totalWidth,
    required double belowW,
    required double opzW,
    required double aboveW,
    required double currentPos,
    required double targetPos,
    required double floorPos,
    required double ceilingPos,
    required bool floorNearCeiling,
  }) {
    const barH = 20.0;
    final dotLeft = (currentPos - 9).clamp(-2.0, totalWidth - 16.0);

    return SizedBox(
      height: barH + 12,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Row(
            children: [
              if (belowW > 0)
                Container(
                    width: belowW,
                    height: barH,
                    color: AppColors.negative.withValues(alpha: 0.2)),
              Container(
                width: opzW,
                height: barH,
                decoration: BoxDecoration(
                  color: AppColors.positive.withValues(alpha: 0.35),
                  border: Border.all(
                      color: AppColors.positive.withValues(alpha: 0.7),
                      width: 1.5),
                ),
              ),
              if (aboveW > 0)
                Container(
                    width: aboveW,
                    height: barH,
                    color: AppColors.warning.withValues(alpha: 0.15)),
            ],
          ),
          Positioned(
            left: (targetPos - 1.5).clamp(0.0, totalWidth - 3),
            top: -6,
            child: Container(
                width: 3, height: barH + 12, color: AppColors.sunset),
          ),
          Positioned(
            left: dotLeft,
            top: (barH - 18) / 2,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: AppColors.textPrimary,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.sunset, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PosEntry {
  final String id;
  final double left;
  const _PosEntry(this.id, this.left);
}
