import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../data/legacy_fixture_data.dart';
import '../data/restaurant_scope_notifier.dart';
import '../data/shift_dashboard_notifier.dart';
import '../models/shift_dashboard_read_model.dart';
import '../services/labor_model.dart';
import '../widgets/zone_status_card.dart';
import '../widgets/input_metric_card.dart';
import '../widgets/variance_banner.dart';

class ShiftDashboard extends StatelessWidget {
  final VoidCallback? onVarianceTap;

  const ShiftDashboard({super.key, this.onVarianceTap});

  @override
  Widget build(BuildContext context) {
    return Consumer<ShiftDashboardNotifier>(
      builder: (context, notifier, _) {
        if (notifier.isLoading) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.tealPrimary),
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
              child: ZoneStatusCard(
                currentCPLH: rm.actualCPLH,
                opzFloorCPLH: rm.opzFloorCPLH,
                opzCeilingCPLH: rm.opzCeilingCPLH,
                targetCPLH: rm.targetCPLH,
                opzStatus: rm.opzStatus,
                opzLabel: rm.opzLabel,
                opzSubLabel: rm.opzSubLabel,
              ),
            ),
            SliverPersistentHeader(
              pinned: true,
              delegate: _VarianceBannerDelegate(onTap: onVarianceTap),
            ),
            SliverToBoxAdapter(child: _MetricCardsSection(cards: rm.metricCards)),
            SliverToBoxAdapter(child: _HoursSection(readModel: rm)),
            SliverToBoxAdapter(child: _TeachingTakeaway(lever: rm.primaryLeverCard)),
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
            style: AppTextStyles.display36(color: AppColors.tealPrimary),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppColors.tealPrimary.withValues(alpha: 0.14),
                      AppColors.tealPrimary.withValues(alpha: 0.06),
                    ],
                  ),
                  border: Border.all(
                      color: AppColors.tealPrimary.withValues(alpha: 0.25),
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
                        color: AppColors.tealPrimary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${readModel.daypart} \u00b7 ${readModel.day}',
                      style:
                          AppTextStyles.mono11(color: AppColors.tealPrimary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
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
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppColors.tealPrimary, AppColors.tealSoft],
            ),
            borderRadius: BorderRadius.circular(1.5),
          ),
        ),
        const SizedBox(width: 10),
        Text(label, style: AppTextStyles.mono8(color: AppColors.textMuted)),
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppColors.borderSubtle.withValues(alpha: 0.5),
                  AppColors.borderSubtle.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Metric cards section ────────────────────────────────────────────────────

class _MetricCardsSection extends StatelessWidget {
  final List<InputMetric> cards;
  const _MetricCardsSection({required this.cards});

  @override
  Widget build(BuildContext context) {
    final gridCards = cards.where((m) => !m.fullWidth).toList();
    final fullWidthCards = cards.where((m) => m.fullWidth).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(label: 'SHIFT INPUTS'),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 1.05,
            children:
                gridCards.map((m) => InputMetricCard(metric: m)).toList(),
          ),
          if (fullWidthCards.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...fullWidthCards.map((m) => InputMetricCard(metric: m)),
          ],
        ],
      ),
    );
  }
}

// ─── Hours vs Model section ──────────────────────────────────────────────────

class _HoursSection extends StatelessWidget {
  final ShiftDashboardReadModel readModel;
  const _HoursSection({required this.readModel});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(label: 'HOURS vs MODEL'),
          const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _SideSummaryCard(side: 'FOH', readModel: readModel)),
                const SizedBox(width: 8),
                Expanded(child: _SideSummaryCard(side: 'BOH', readModel: readModel)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Side summary card ───────────────────────────────────────────────────────

class _SideSummaryCard extends StatelessWidget {
  final String side;
  final ShiftDashboardReadModel readModel;

  const _SideSummaryCard({required this.side, required this.readModel});

  @override
  Widget build(BuildContext context) {
    final isFoh = side == 'FOH';

    final scheduled = isFoh
        ? readModel.scheduledFohHours
        : readModel.scheduledBohHours;
    final needed = isFoh
        ? LaborModel.modelFohHours(readModel.actualCovers, readModel.targetCPLH)
        : LaborModel.modelBohHours(
            readModel.actualCovers, readModel.targetPPA, readModel.targetSPLH);
    final excess = scheduled - needed;

    final costPerHour = isFoh ? readModel.fohWage : readModel.bohWage;
    final excessCost = (excess * costPerHour).abs().toStringAsFixed(0);

    final isOverModel = excess > 0;
    final deltaColor = isOverModel ? AppColors.negative : AppColors.positive;
    final deltaIcon = isOverModel ? Icons.arrow_upward : Icons.arrow_downward;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border(
          left: BorderSide(
            color: deltaColor.withValues(alpha: 0.6),
            width: 3,
          ),
          top: BorderSide(
              color: AppColors.borderSubtle.withValues(alpha: 0.7), width: 1),
          right: BorderSide(
              color: AppColors.borderSubtle.withValues(alpha: 0.7), width: 1),
          bottom: BorderSide(
              color: AppColors.borderSubtle.withValues(alpha: 0.7), width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.tealPrimary, AppColors.tealSoft],
              ),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(
              '$side  \u00b7  ${isFoh ? 'FLOOR' : 'KITCHEN'}',
              style: AppTextStyles.mono7(color: AppColors.backgroundDeep),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('$scheduled', style: AppTextStyles.mono28()),
              const SizedBox(width: 4),
              Text('hrs',
                  style: AppTextStyles.mono12(color: AppColors.textMuted)),
            ],
          ),
          const SizedBox(height: 4),
          Text('Model needs $needed',
              style: AppTextStyles.mono10(color: AppColors.textMuted)),
          const SizedBox(height: 14),
          Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppColors.borderSubtle.withValues(alpha: 0.6),
                  AppColors.borderSubtle.withValues(alpha: 0.1),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: deltaColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(deltaIcon, size: 12, color: deltaColor),
                    const SizedBox(width: 3),
                    Text(
                      '${isOverModel ? '+' : ''}$excess hrs',
                      style: AppTextStyles.mono14(
                          color: deltaColor, weight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${isOverModel ? '+' : '\u2212'}\$$excessCost impact',
            style: AppTextStyles.mono10(color: deltaColor),
          ),
        ],
      ),
    );
  }
}

// ─── Teaching takeaway ───────────────────────────────────────────────────────

class _TeachingTakeaway extends StatelessWidget {
  final LeverCardData lever;
  const _TeachingTakeaway({required this.lever});

  @override
  Widget build(BuildContext context) {
    final accentColor =
        lever.isFavorable ? AppColors.positive : AppColors.negative;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 22, 16, 0),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const [0.0, 0.4, 1.0],
          colors: [
            AppColors.backgroundSurface.withValues(alpha: 0.7),
            AppColors.shimmer,
            AppColors.cardGlow,
          ],
        ),
        border: Border.all(
            color: AppColors.borderSubtle.withValues(alpha: 0.8), width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 3,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [accentColor, accentColor.withValues(alpha: 0.3)],
              ),
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.04),
              border: Border(
                bottom: BorderSide(
                    color: AppColors.borderSubtle.withValues(alpha: 0.4),
                    width: 1),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        accentColor.withValues(alpha: 0.15),
                        accentColor.withValues(alpha: 0.06),
                      ],
                    ),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: accentColor.withValues(alpha: 0.2), width: 1),
                  ),
                  child: Icon(Icons.lightbulb_outline,
                      size: 13, color: accentColor),
                ),
                const SizedBox(width: 10),
                Text('PRIMARY DRIVER',
                    style: AppTextStyles.mono10(color: accentColor)),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.08),
                    border: Border.all(
                        color: accentColor.withValues(alpha: 0.25), width: 1),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(lever.shortLabel,
                      style: AppTextStyles.mono8(color: accentColor)),
                ),
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.shimmer.withValues(alpha: 0.6),
                    border: Border.all(
                        color: AppColors.borderSubtle.withValues(alpha: 0.6),
                        width: 1),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(lever.sideLabel,
                      style: AppTextStyles.mono8(
                          color: AppColors.textSecondary)),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              lever.metric,
              style: AppTextStyles.mono14(
                  color: AppColors.textPrimary, weight: FontWeight.w600),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
            child: Text(
              lever.whatHappened,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Variance banner delegate ────────────────────────────────────────────────

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

// ─── Variance banner delegate ────────────────────────────────────────────────

class _VarianceBannerDelegate extends SliverPersistentHeaderDelegate {
  final VoidCallback? onTap;

  const _VarianceBannerDelegate({this.onTap});

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return VarianceBanner(onTap: onTap);
  }

  @override
  double get minExtent => 98;

  @override
  double get maxExtent => 98;

  @override
  bool shouldRebuild(_VarianceBannerDelegate oldDelegate) => false;
}
