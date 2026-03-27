import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/meridian_data.dart';
import '../widgets/zone_status_card.dart';
import '../widgets/input_metric_card.dart';
import '../widgets/variance_banner.dart';
class ShiftDashboard extends StatelessWidget {
  final VoidCallback? onVarianceTap;

  const ShiftDashboard({super.key, this.onVarianceTap});

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        // ── Header ─────────────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: _ShiftHeader(),
        ),

        // ── Zone status card ───────────────────────────────────────────────
        const SliverToBoxAdapter(
          child: ZoneStatusCard(),
        ),

        // ── Sticky variance banner ─────────────────────────────────────────
        SliverPersistentHeader(
          pinned: true,
          delegate: _VarianceBannerDelegate(onTap: onVarianceTap),
        ),

        // ── Five input metric cards ────────────────────────────────────────
        SliverToBoxAdapter(
          child: _MetricCardsGrid(),
        ),

        // ── Which Lever Moved ──────────────────────────────────────────────
        SliverToBoxAdapter(
          child: _WhichLeverMoved(),
        ),

        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

class _ShiftHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                MeridianConfig.restaurantName,
                style: AppTextStyles.display16(),
              ),
              Text(
                '${ShiftSnapshot.daypart} · ${ShiftSnapshot.day}',
                style: AppTextStyles.mono10(),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${ShiftSnapshot.time} · ${ShiftSnapshot.serviceElapsed}',
            style: AppTextStyles.mono10(),
          ),
        ],
      ),
    );
  }
}

class _MetricCardsGrid extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final gridCards = ShiftMetrics.cards.where((m) => !m.fullWidth).toList();
    final fullWidthCards =
        ShiftMetrics.cards.where((m) => m.fullWidth).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 1.4,
            children: gridCards
                .map((m) => InputMetricCard(metric: m))
                .toList(),
          ),
          const SizedBox(height: 8),
          ...fullWidthCards.map((m) => InputMetricCard(metric: m)),
        ],
      ),
    );
  }
}

class _WhichLeverMoved extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // FOH / BOH side cards
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(child: _SideSummaryCard(side: 'FOH')),
              const SizedBox(width: 8),
              Expanded(child: _SideSummaryCard(side: 'BOH')),
            ],
          ),
        ),

        // Plain-language read
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Text(
            'Fewer guests than forecast, and the hours did not move with them. '
            'That is where the variance came from. This is a scheduling gap, not a team problem.',
            style: AppTextStyles.body13(color: AppColors.secondaryText),
          ),
        ),

      ],
    );
  }
}

class _SideSummaryCard extends StatelessWidget {
  final String side;

  const _SideSummaryCard({required this.side});

  @override
  Widget build(BuildContext context) {
    final isFoh = side == 'FOH';
    final scheduled = isFoh
        ? WeeklyVariance.actualFohHours
        : WeeklyVariance.actualBohHours;
    final needed = isFoh
        ? WeeklyVariance.theoreticalFohHours
        : WeeklyVariance.theoreticalBohHours;
    final excess = isFoh
        ? WeeklyVariance.fohHoursVariance
        : WeeklyVariance.bohHoursVariance;
    final cost = isFoh
        ? WeeklyVariance.fohExcessCost
        : WeeklyVariance.bohExcessCost;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.rule, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            color: AppColors.slateTag.withValues(alpha: 0.4),
            child: Text(
              side,
              style: AppTextStyles.mono7(color: AppColors.secondaryText),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$scheduled hrs scheduled',
            style: AppTextStyles.mono10(color: AppColors.primaryText),
          ),
          const SizedBox(height: 2),
          Text(
            'Model needed $needed',
            style: AppTextStyles.mono10(),
          ),
          const SizedBox(height: 4),
          Text(
            '+$excess hrs · +$cost',
            style: AppTextStyles.mono10(color: AppColors.accent),
          ),
        ],
      ),
    );
  }
}

// SliverPersistentHeaderDelegate for the sticky variance banner
class _VarianceBannerDelegate extends SliverPersistentHeaderDelegate {
  final VoidCallback? onTap;

  const _VarianceBannerDelegate({this.onTap});

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return VarianceBanner(onTap: onTap);
  }

  @override
  double get minExtent => 60;

  @override
  double get maxExtent => 60;

  @override
  bool shouldRebuild(_VarianceBannerDelegate oldDelegate) => false;
}
