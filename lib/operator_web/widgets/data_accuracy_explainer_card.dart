// Phase 8 spine-bridge Lane .B — Data Accuracy explainer card.
//
// Static "What this page is for" card that walks the operator
// through each data accuracy setting in plain English with one
// concrete example per setting. Sits at the bottom of the Operator
// Web Console Data Accuracy tab.
//
// Authority:
//   docs/contracts/data_accuracy_settings_contract.md
//   "Operator Web Console — Data Accuracy tab" → "What this means
//   card" section.
//
// UX writing standard (`memory/project_ux_writing_standard.md`):
// every operator-facing UX surface reads as if training the user
// while they use it. Brief inline explainers, plain English, no
// engineering jargon. The card teaches the operator what the
// settings on this page do without sending them to a separate
// help page.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Static "What this page is for" explainer card. Renders 5
/// sub-sections — one per setting (wage, covers, walk-in,
/// historical seed, polling tier) — each with a short heading,
/// 1-sentence body, and 1-sentence concrete example.
class DataAccuracyExplainerCard extends StatelessWidget {
  const DataAccuracyExplainerCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('data_accuracy_explainer_card'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.menu_book_outlined,
                size: 18,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'What this page is for',
                  style: AppTextStyles.mono15(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'These settings tell F&F where your most important numbers '
            'come from when your vendors do not expose them directly. '
            'Set them once and your dashboard stays honest.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          const _ExplainerSection(
            slug: 'wage',
            heading: 'Where labor dollars come from',
            body:
                'If your scheduling vendor reports per-shift dollars, '
                'F&F uses those. If not, F&F can substitute your wage '
                'editor mix or your TargetCycle wage × hours.',
            example:
                'Example: QuickBooks Time reports per-employee dollars, '
                'so F&F uses them. If you switch to Humanity, F&F '
                'multiplies Humanity\'s pay rates by scheduled hours '
                'instead — same outcome, different path.',
          ),
          const SizedBox(height: 12),
          const _ExplainerSection(
            slug: 'covers',
            heading: 'Where covers come from',
            body:
                'Covers (guest counts) drive every per-cover metric. '
                'F&F reads them from your POS by default; if your POS '
                'does not track them, you pick forecast or manual per '
                'daypart.',
            example:
                'Example: Square does not track covers. Set lunch and '
                'dinner to Manual, type your numbers nightly, and CPLH '
                'stays trustworthy.',
          ),
          const SizedBox(height: 12),
          const _ExplainerSection(
            slug: 'walk_in',
            heading: 'Walk-in handling',
            body:
                'Only relevant when your reservation system is '
                'connected and your POS does not track covers. Tells '
                'F&F whether walk-ins are bundled with reservations, '
                'kept separate, or ignored.',
            example:
                'Example: OpenTable + Square. Pick "Add walk-ins to '
                'reservations" and type a daily walk-in count. F&F '
                'adds your walk-ins to OpenTable\'s reservation count '
                'for total covers.',
          ),
          const SizedBox(height: 12),
          const _ExplainerSection(
            slug: 'historical_seed',
            heading: '60-day backfill',
            body:
                'F&F\'s forecast learns from your last 60 days. If '
                'your POS does not expose covers, this is where you '
                'give F&F a starting point.',
            example:
                'Example: Paste a CSV with date, lunch, dinner, '
                'late_night columns and F&F uses it to forecast next '
                'week. You can edit any cell later.',
          ),
          const SizedBox(height: 12),
          const _ExplainerSection(
            slug: 'polling_tier',
            heading: 'Data freshness tier',
            body:
                'F&F controls how often we ask your poll-only vendors '
                'for new data — your dashboard stays as live as the '
                'schedule. Webhook vendors are real-time regardless.',
            example:
                'Example: On Standard, F&F checks Oracle MICROS every '
                '5 minutes. On Premium, F&F checks every minute when '
                'Oracle allows. Tap "Request tier change" to switch.',
          ),
        ],
      ),
    );
  }
}

class _ExplainerSection extends StatelessWidget {
  const _ExplainerSection({
    required this.slug,
    required this.heading,
    required this.body,
    required this.example,
  });

  final String slug;
  final String heading;
  final String body;
  final String example;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('data_accuracy_explainer_$slug'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            heading,
            style: AppTextStyles.mono11(color: AppColors.sunsetDark),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 6),
          Text(
            example,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
