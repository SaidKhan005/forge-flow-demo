import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'admin_responsive_layout.dart';

class PlainEnglishExplainerCard extends StatelessWidget {
  const PlainEnglishExplainerCard({super.key});

  // Verbatim contract text — pinned by tests so that any future edit to
  // `data_accuracy_settings_contract.md` Tab 2 explainer is reflected
  // here (or vice versa) before merge.
  static const String kExplainerParagraph1 =
      'Polling cadence is how often F&F checks each vendor for new data. '
      'Webhook vendors (Toast, Square, Clover, Lightspeed, Revel, Aloha, '
      '7shifts, ADP, Libro, OpenTable, SevenRooms, Tock) push updates in '
      "real time — cadence doesn't apply. Poll-only vendors (Oracle "
      'MICROS Simphony, QuickBooks Time, Humanity, Agendrix, Push '
      'Operations) update only at the cadence we set here.';

  static const String kExplainerParagraph2 =
      'F&F absorbs vendor API costs and packages them into operator-facing '
      'tier prices. Operators see a tier name and a tier price on their '
      "bill — they don't see vendor per-call costs. This panel is "
      'where we set the cadences, the prices, and the cost basis.';

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_data_accuracy_explainer_card'),
      child: AdminCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'About this surface',
              style: AppTextStyles.sectionTitle(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 12),
            Text(
              kExplainerParagraph1,
              style: AppTextStyles.body14(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 12),
            Text(
              kExplainerParagraph2,
              style: AppTextStyles.body14(color: AppColors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}
