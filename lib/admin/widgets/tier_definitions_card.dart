import 'package:flutter/material.dart';

import '../../domain/models/forge_flow_polling_tier_assignment.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console/console_surface.dart';
import '../admin_human_labels.dart';
import '../services/data_accuracy_admin_gateway.dart';
import 'admin_action_controls.dart';
import 'admin_responsive_layout.dart';

class TierDefinitionsCard extends StatelessWidget {
  const TierDefinitionsCard({
    super.key,
    required this.definitions,
    required this.editingEnabled,
    required this.onEdit,
  });

  final List<TierDefinition> definitions;
  final bool editingEnabled;
  final void Function(TierDefinition definition) onEdit;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      key: const Key('admin_tier_definitions_card'),
      title: 'Tier definitions',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (definitions.isEmpty)
            Text(
              'No tier definitions configured.',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            )
          else
            for (final def in definitions)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _TierDefinitionSubcard(
                  definition: def,
                  editingEnabled: editingEnabled,
                  onEdit: () => onEdit(def),
                ),
              ),
        ],
      ),
    );
  }
}

class _TierDefinitionSubcard extends StatelessWidget {
  const _TierDefinitionSubcard({
    required this.definition,
    required this.editingEnabled,
    required this.onEdit,
  });

  final TierDefinition definition;
  final bool editingEnabled;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final margin = definition.defaultMarginCents;
    // Custom-tier defaults are 0 / 0 / 0 until F&F admin sets real
    // numbers per assignment. Render the zero margin neutral so it
    // doesn't read "positive" against a placeholder. Real positive
    // margins still render green; negative margins still render red.
    final Color marginColor;
    if (margin > 0) {
      marginColor = AppColors.positive;
    } else if (margin < 0) {
      marginColor = AppColors.negative;
    } else {
      marginColor = AppColors.textMuted;
    }

    return Container(
      key: Key('admin_tier_definition_${definition.tierKey.wire}'),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(12),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 8),
        backgroundColor: Colors.transparent,
        collapsedBackgroundColor: Colors.transparent,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Row(
          children: [
            Expanded(
              child: Text(
                _tierTitle(definition.tierKey),
                style: AppTextStyles.body14(color: AppColors.textPrimary),
              ),
            ),
            Text(
              formatCents(definition.defaultMonthlyPriceCents),
              style: AppTextStyles.mono14(color: AppColors.textPrimary),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            definition.descriptionMd,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ),
        children: [
          _CadenceTable(cadence: definition.pollingCadencePerVendorSeconds),
          const SizedBox(height: 12),
          AdminDetailRow(
            label: 'Default tier price (USD/month/location)',
            value: formatCents(definition.defaultMonthlyPriceCents),
          ),
          AdminDetailRow(
            label: 'Vendor API cost basis (USD/month/location)',
            value: formatCents(definition.vendorApiCostEstimateCentsMonthly),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 160,
                  child: Text(
                    'Default margin (USD/month/location)',
                    style: AppTextStyles.uiLabel(color: AppColors.textMuted),
                  ),
                ),
                Expanded(
                  child: Text(
                    formatCents(margin),
                    style: AppTextStyles.body14(color: marginColor),
                  ),
                ),
              ],
            ),
          ),
          AdminDetailRow(
            label: 'Last edited',
            value:
                '${adminHumanDateTime(definition.lastEditedAt)}'
                '${definition.lastEditedBy != null ? ' by ${definition.lastEditedBy}' : ''}',
          ),
          if (editingEnabled)
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: AdminActionButton(
                  key: Key(
                    'admin_tier_definition_edit_${definition.tierKey.wire}',
                  ),
                  label: 'Edit',
                  onPressed: onEdit,
                  compact: true,
                  minWidth: 80,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _tierTitle(PollingTierKey tier) {
    switch (tier) {
      case PollingTierKey.standard:
        return 'Regular';
      case PollingTierKey.premium:
        return 'Premium';
      case PollingTierKey.custom:
        return 'Custom';
    }
  }
}

class _CadenceTable extends StatelessWidget {
  const _CadenceTable({required this.cadence});

  final Map<String, int> cadence;

  @override
  Widget build(BuildContext context) {
    if (cadence.isEmpty) {
      return Text(
        'No vendor cadences set (admin must pick per assignment).',
        style: AppTextStyles.body13(color: AppColors.textMuted),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Polling cadence per vendor',
          style: AppTextStyles.uiLabel(color: AppColors.textMuted),
        ),
        const SizedBox(height: 6),
        for (final vendorId in kPollOnlyVendorIds)
          if (cadence[vendorId] != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 220,
                    child: Text(
                      kPollOnlyVendorDisplayNames[vendorId] ?? vendorId,
                      style: AppTextStyles.body13(color: AppColors.textPrimary),
                    ),
                  ),
                  Text(
                    formatCadenceSeconds(cadence[vendorId]!),
                    style: AppTextStyles.mono12(color: AppColors.textPrimary),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

/// Format a cadence interval. Promotes whole minutes to "N minutes",
/// otherwise keeps seconds. "1 minute" / "5 minutes" / "75 seconds".
String formatCadenceSeconds(int seconds) {
  if (seconds >= 60 && seconds % 60 == 0) {
    final minutes = seconds ~/ 60;
    return '$minutes ${minutes == 1 ? 'minute' : 'minutes'}';
  }
  return '$seconds seconds';
}
