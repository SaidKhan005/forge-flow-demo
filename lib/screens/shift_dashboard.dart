import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/meridian_data.dart';
import '../services/labor_model.dart';
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
        SliverToBoxAdapter(child: _ShiftHeader()),
        const SliverToBoxAdapter(child: ZoneStatusCard()),
        SliverPersistentHeader(
          pinned: true,
          delegate: _VarianceBannerDelegate(onTap: onVarianceTap),
        ),
        SliverToBoxAdapter(child: _MetricCardsSection()),
        SliverToBoxAdapter(child: _HoursSection()),
        SliverToBoxAdapter(child: _TeachingTakeaway()),
        const SliverToBoxAdapter(child: SizedBox(height: 40)),
      ],
    );
  }
}

// ─── Header ──────────────────────────────────────────────────────────────────

class _ShiftHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.backgroundDeep,
            AppColors.backgroundDeep.withValues(alpha: 0.0),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Restaurant name
          Text(
            MeridianConfig.restaurantName,
            style: AppTextStyles.display36(color: AppColors.tealPrimary),
          ),
          const SizedBox(height: 12),
          // Context row
          Row(
            children: [
              // Daypart pill
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppColors.tealPrimary.withValues(alpha: 0.15),
                      AppColors.tealPrimary.withValues(alpha: 0.08),
                    ],
                  ),
                  border: Border.all(
                      color: AppColors.tealPrimary.withValues(alpha: 0.3),
                      width: 1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: AppColors.tealPrimary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${ShiftSnapshot.daypart} \u00b7 ${ShiftSnapshot.day}',
                      style:
                          AppTextStyles.mono11(color: AppColors.tealPrimary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              // Time
              Text(
                '${ShiftSnapshot.time} \u00b7 ${ShiftSnapshot.serviceElapsed}',
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Metric cards section ────────────────────────────────────────────────────

class _MetricCardsSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final gridCards = ShiftMetrics.cards.where((m) => !m.fullWidth).toList();
    final fullWidthCards =
        ShiftMetrics.cards.where((m) => m.fullWidth).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section label
          _SectionHeader(label: 'SHIFT INPUTS'),
          const SizedBox(height: 10),
          // Grid
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
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(label: 'HOURS vs MODEL'),
          const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _SideSummaryCard(side: 'FOH')),
                const SizedBox(width: 8),
                Expanded(child: _SideSummaryCard(side: 'BOH')),
              ],
            ),
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
            color: AppColors.tealPrimary,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
        const SizedBox(width: 10),
        Text(label, style: AppTextStyles.mono8(color: AppColors.textMuted)),
        const SizedBox(width: 12),
        Expanded(
          child: Container(
            height: 1,
            color: AppColors.borderSubtle.withValues(alpha: 0.4),
          ),
        ),
      ],
    );
  }
}

// ─── Teaching takeaway ───────────────────────────────────────────────────────

class _TeachingTakeaway extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final lever = ShiftSnapshot.primaryLeverCard;
    final accentColor =
        lever.isFavorable ? AppColors.positive : AppColors.negative;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.backgroundSurface.withValues(alpha: 0.6),
            AppColors.backgroundMid,
          ],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Accent top edge
          Container(height: 3, color: accentColor),
          // Header strip
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.05),
              border: Border(
                bottom: BorderSide(
                    color: AppColors.borderSubtle.withValues(alpha: 0.5),
                    width: 1),
              ),
            ),
            child: Row(
              children: [
                // Icon in a circle
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.lightbulb_outline,
                      size: 13, color: accentColor),
                ),
                const SizedBox(width: 10),
                Text('PRIMARY DRIVER',
                    style: AppTextStyles.mono10(color: accentColor)),
                const Spacer(),
                // Lever badge
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.10),
                    border: Border.all(
                        color: accentColor.withValues(alpha: 0.3), width: 1),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(lever.shortLabel,
                      style: AppTextStyles.mono8(color: accentColor)),
                ),
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundMid.withValues(alpha: 0.6),
                    border: Border.all(
                        color: AppColors.borderSubtle, width: 1),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(lever.sideLabel,
                      style: AppTextStyles.mono8(
                          color: AppColors.textSecondary)),
                ),
              ],
            ),
          ),
          // Lever headline
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text(
              lever.metric,
              style: AppTextStyles.mono14(
                  color: AppColors.textPrimary, weight: FontWeight.w600),
            ),
          ),
          // Teaching body
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
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

// ─── Side summary card ───────────────────────────────────────────────────────

class _SideSummaryCard extends StatelessWidget {
  final String side;

  const _SideSummaryCard({required this.side});

  @override
  Widget build(BuildContext context) {
    final isFoh = side == 'FOH';

    final scheduled = isFoh
        ? ShiftSnapshot.scheduledFohHours
        : ShiftSnapshot.scheduledBohHours;
    final needed = isFoh
        ? LaborModel.modelFohHours(
            ShiftSnapshot.actualCovers, BaselineData.derivedTargetCPLH)
        : LaborModel.modelBohHours(ShiftSnapshot.actualCovers,
            BaselineData.derivedTargetPPA, BaselineData.derivedTargetSPLH);
    final excess = scheduled - needed;

    final costPerHour =
        isFoh ? MeridianConfig.fohWage : MeridianConfig.bohWage;
    final excessCost = (excess * costPerHour).abs().toStringAsFixed(0);

    final isOverModel = excess > 0;
    final deltaColor = isOverModel ? AppColors.negative : AppColors.positive;
    final deltaIcon = isOverModel ? Icons.arrow_upward : Icons.arrow_downward;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        border: Border(
          left: BorderSide(
            color: deltaColor.withValues(alpha: 0.6),
            width: 3,
          ),
          top: BorderSide(color: AppColors.borderSubtle, width: 1),
          right: BorderSide(color: AppColors.borderSubtle, width: 1),
          bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Side badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.tealPrimary,
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(
              '$side  \u00b7  ${isFoh ? 'FLOOR' : 'KITCHEN'}',
              style: AppTextStyles.mono7(color: AppColors.backgroundDeep),
            ),
          ),
          const SizedBox(height: 14),
          // Hours
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
          // Divider
          Container(
              height: 1,
              color: AppColors.borderSubtle.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          // Delta + cost
          Row(
            children: [
              Icon(deltaIcon, size: 14, color: deltaColor),
              const SizedBox(width: 4),
              Text(
                '${isOverModel ? '+' : ''}$excess hrs',
                style: AppTextStyles.mono15(
                    color: deltaColor, weight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${isOverModel ? '+' : '\u2212'}\$$excessCost impact',
            style: AppTextStyles.mono10(color: deltaColor),
          ),
        ],
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
