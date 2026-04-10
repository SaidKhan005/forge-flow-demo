import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../data/legacy_fixture_data.dart';
import '../data/restaurant_scope_notifier.dart';
import '../data/shift_dashboard_notifier.dart';
import '../models/shift_dashboard_read_model.dart';
import '../widgets/zone_status_card.dart';
import '../widgets/input_metric_card.dart';
import '../widgets/sales_forecast_card.dart';

class ShiftDashboard extends StatelessWidget {
  final VoidCallback? onVarianceTap;

  const ShiftDashboard({super.key, this.onVarianceTap});

  @override
  Widget build(BuildContext context) {
    return Consumer<ShiftDashboardNotifier>(
      builder: (context, notifier, _) {
        if (notifier.isLoading) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.sunset),
          );
        }
        final rm = notifier.readModel;
        if (rm == null) {
          return _ShiftEmptyState(
            headline: notifier.status?.label ?? 'NO LIVE SHIFT',
            body: notifier.status?.description ??
                'No open or projected shift is available.',
            timestamp: notifier.status?.latestImportTimestamp,
          );
        }
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _ShiftHeader(readModel: rm)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _SectionHeader(label: 'SHIFT OUTPUTS'),
              ),
            ),
            SliverToBoxAdapter(
              child: _OutputsSection(readModel: rm),
            ),
            SliverToBoxAdapter(
              child: _InputsSection(readModel: rm),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SectionHeader(label: 'FOH PRODUCTIVITY'),
                    ZoneStatusCard(
                      currentCPLH: rm.actualCPLH,
                      opzFloorCPLH: rm.opzFloorCPLH,
                      opzCeilingCPLH: rm.opzCeilingCPLH,
                      targetCPLH: rm.targetCPLH,
                      opzStatus: rm.opzStatus,
                      opzLabel: rm.opzLabel,
                      opzSubLabel: rm.opzSubLabel,
                    ),
                  ],
                ),
              ),
            ),
            // PRIMARY DRIVER section hidden — lever detection needs
            // whole-day actuals vs daypart targets alignment (Phase 10.5).
            // SliverToBoxAdapter(
            //   child: Padding(
            //     padding: const EdgeInsets.symmetric(horizontal: 16),
            //     child: Column(
            //       crossAxisAlignment: CrossAxisAlignment.start,
            //       children: [
            //         _SectionHeaderWithIcon(
            //           label: 'PRIMARY DRIVER',
            //           icon: Icons.lightbulb_outline,
            //         ),
            //         _TeachingTakeaway(lever: rm.primaryLeverCard),
            //       ],
            //     ),
            //   ),
            // ),
            const SliverToBoxAdapter(child: SizedBox(height: 48)),
          ],
        );
      },
    );
  }
}

// ─── Header ──────────────────────────────────────────────────────────────────

class _ShiftHeader extends StatelessWidget {
  final ShiftDashboardReadModel readModel;
  const _ShiftHeader({required this.readModel});

  @override
  Widget build(BuildContext context) {
    final restaurantName =
        context.watch<RestaurantScopeNotifier?>()?.restaurant?.displayName ??
            'Restaurant';
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0.0, 0.6, 1.0],
          colors: [
            AppColors.backgroundDeep,
            AppColors.shimmer.withValues(alpha: 0.3),
            AppColors.backgroundDeep.withValues(alpha: 0.0),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            restaurantName,
            style: AppTextStyles.display36(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppColors.sunset.withValues(alpha: 0.14),
                      AppColors.sunset.withValues(alpha: 0.06),
                    ],
                  ),
                  border: Border.all(
                      color: AppColors.sunset.withValues(alpha: 0.25),
                      width: 1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: AppColors.sunset,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      readModel.daypart.isEmpty
                          ? readModel.day
                          : '${readModel.daypart} \u00b7 ${readModel.day}',
                      style:
                          AppTextStyles.mono11(color: AppColors.sunsetDark),
                    ),
                  ],
                ),
              ),
              Text(
                '${readModel.timeLabel} \u00b7 ${readModel.serviceElapsedLabel}',
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Section header ──────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 32, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [AppColors.sunset, AppColors.sunsetDark],
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Text(label, style: AppTextStyles.mono14(color: AppColors.textPrimary, weight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            height: 2,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [AppColors.sunset, AppColors.sunsetDark],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ignore: unused_element — Phase 10.5 lever teaching
class _SectionHeaderWithIcon extends StatelessWidget {
  final String label;
  final IconData icon;
  const _SectionHeaderWithIcon({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 32, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 4,
                height: 20,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [AppColors.sunset, AppColors.sunsetDark],
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Icon(icon, size: 16, color: AppColors.sunset),
              const SizedBox(width: 6),
              Text(label, style: AppTextStyles.mono14(color: AppColors.textPrimary, weight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            height: 2,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [AppColors.sunset, AppColors.sunsetDark],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Outputs section (Sales, Labor%, Covers, Blended Wage) ──────────────────

class _OutputsSection extends StatelessWidget {
  final ShiftDashboardReadModel readModel;
  const _OutputsSection({required this.readModel});

  @override
  Widget build(BuildContext context) {
    // Extract output metric cards: COVERS and BLENDED WAGE
    final coversCard = readModel.metricCards.where((m) => m.name == 'COVERS').toList();
    final wageCard = readModel.metricCards.where((m) => m.name == 'BLENDED WAGE').toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Column(
        children: [
          // ── Sales + Labor side by side ──
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SalesForecastCard(
                    currentSales: readModel.currentSales,
                    forecastSales: readModel.forecastSales,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _LaborCard(readModel: readModel),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // ── Covers + Blended Wage side by side ──
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (coversCard.isNotEmpty)
                  Expanded(child: InputMetricCard(metric: coversCard.first)),
                const SizedBox(width: 8),
                if (wageCard.isNotEmpty)
                  Expanded(child: InputMetricCard(metric: wageCard.first)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Inputs section (PPA, CPLH, SPLH, FOH HRS, BOH HRS) ───────────────────

class _InputsSection extends StatelessWidget {
  final ShiftDashboardReadModel readModel;
  const _InputsSection({required this.readModel});

  @override
  Widget build(BuildContext context) {
    // Input metric cards: PPA, CPLH, SPLH (exclude COVERS and BLENDED WAGE)
    final inputCards = readModel.metricCards
        .where((m) => m.name != 'COVERS' && m.name != 'BLENDED WAGE')
        .toList();

    // Hours data — plan targets from SchedulePlan day row
    final fohScheduled = readModel.scheduledFohHours;
    final bohScheduled = readModel.scheduledBohHours;
    final fohTarget = readModel.planFohHours;
    final bohTarget = readModel.planBohHours;
    final fohExcess = fohScheduled - fohTarget;
    final bohExcess = bohScheduled - bohTarget;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(label: 'SHIFT INPUTS'),
          // PPA, CPLH, SPLH in grid
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 1.05,
            children:
                inputCards.map((m) => InputMetricCard(metric: m)).toList(),
          ),
          const SizedBox(height: 8),
          // FOH + BOH hours side by side
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _CompactHoursColumn(
                    label: 'FOH HRS',
                    scheduled: fohScheduled,
                    needed: fohTarget,
                    excess: fohExcess,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _CompactHoursColumn(
                    label: 'BOH HRS',
                    scheduled: bohScheduled,
                    needed: bohTarget,
                    excess: bohExcess,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


// ─── Teaching takeaway ───────────────────────────────────────────────────────

// ignore: unused_element — Phase 10.5 lever teaching
class _TeachingTakeaway extends StatelessWidget {
  final LeverCardData lever;
  const _TeachingTakeaway({required this.lever});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(
            color: AppColors.borderSubtle.withValues(alpha: 0.7), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            lever.metric,
            style: AppTextStyles.mono14(
                color: AppColors.textPrimary, weight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            lever.whatHappened,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

// ─── Empty state ────────────────────────────────────────────────────────────

class _ShiftEmptyState extends StatelessWidget {
  final String headline;
  final String body;
  final String? timestamp;
  const _ShiftEmptyState({
    required this.headline,
    required this.body,
    this.timestamp,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(headline,
                style: AppTextStyles.mono14(color: AppColors.textMuted)),
            const SizedBox(height: 8),
            Text(body,
                style: AppTextStyles.body13(color: AppColors.textSecondary),
                textAlign: TextAlign.center),
            if (timestamp != null) ...[
              const SizedBox(height: 8),
              Text('Last import: $timestamp',
                  style: AppTextStyles.mono8(color: AppColors.textMuted)),
            ],
          ],
        ),
      ),
    );
  }
}


class _LaborCard extends StatelessWidget {
  final ShiftDashboardReadModel readModel;
  const _LaborCard({required this.readModel});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border(
          left: BorderSide(color: AppColors.sunset, width: 4),
          top: BorderSide(
              color: AppColors.borderSubtle.withValues(alpha: 0.7),
              width: 1),
          right: BorderSide(
              color: AppColors.borderSubtle.withValues(alpha: 0.7),
              width: 1),
          bottom: BorderSide(
              color: AppColors.borderSubtle.withValues(alpha: 0.7),
              width: 1),
        ),
      ),
      child: _LaborVarianceSection(readModel: readModel),
    );
  }
}

class _LaborVarianceSection extends StatelessWidget {
  final ShiftDashboardReadModel readModel;
  const _LaborVarianceSection({required this.readModel});

  @override
  Widget build(BuildContext context) {
    final actual = readModel.actualLaborPct;
    final target = readModel.targetLaborPct;
    final variancePts = readModel.laborVariancePts;

    final isOver = variancePts > 0;
    final accentColor = isOver ? AppColors.negative : AppColors.positive;
    final ptSign = isOver ? '+' : '\u2212';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label
        Text('LABOR %',
            style: AppTextStyles.mono10(color: AppColors.textMuted)),
        const SizedBox(height: 6),
        // Current value
        Text(
          '${actual.toStringAsFixed(1)}%',
          style: AppTextStyles.mono28(color: accentColor),
        ),
        const SizedBox(height: 3),
        // Target reference
        Text(
          'Target ${target.toStringAsFixed(1)}%',
          style: AppTextStyles.mono10(color: AppColors.textMuted),
        ),
        const SizedBox(height: 8),
        // Delta pill
        Container(
          padding: const EdgeInsets.symmetric(
              horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: accentColor.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isOver ? Icons.arrow_upward : Icons.arrow_downward,
                size: 14, color: accentColor),
              const SizedBox(width: 2),
              Text(
                '$ptSign${variancePts.abs().toStringAsFixed(1)} pts',
                style: AppTextStyles.mono12(
                    color: accentColor, weight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CompactHoursColumn extends StatelessWidget {
  final String label;
  final int scheduled;
  final int needed;
  final int excess;

  const _CompactHoursColumn({
    required this.label,
    required this.scheduled,
    required this.needed,
    required this.excess,
  });

  @override
  Widget build(BuildContext context) {
    final isOver = excess > 0;
    final deltaColor = isOver ? AppColors.negative : AppColors.positive;
    final deltaIcon = isOver ? Icons.arrow_upward : Icons.arrow_downward;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(
          color: AppColors.borderSubtle.withValues(alpha: 0.7),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Label
          Text(label,
              style: AppTextStyles.mono10(color: AppColors.textMuted)),
          const SizedBox(height: 6),
          // Current value
          Text('$scheduled',
              style: AppTextStyles.mono28()),
          const SizedBox(height: 3),
          // Target reference
          Text('Target $needed hrs',
              style: AppTextStyles.mono10(color: AppColors.textMuted)),
          const SizedBox(height: 8),
          // Delta pill
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: deltaColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(deltaIcon, size: 14, color: deltaColor),
                const SizedBox(width: 2),
                Text(
                  '${isOver ? '+' : ''}$excess hrs',
                  style: AppTextStyles.mono12(
                      color: deltaColor, weight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
