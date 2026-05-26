import 'package:flutter/material.dart';

import '../../domain/models/forge_flow_polling_tier_assignment.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console/console_surface.dart';
import '../admin_human_labels.dart';
import '../services/data_accuracy_admin_gateway.dart';
import 'admin_action_controls.dart';

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
      title: 'Polling tiers',
      subtitle:
          'Each tier sets the default price, polling frequency, and margin.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (definitions.isEmpty)
            Text(
              'No polling tiers configured.',
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
    final marginColor = _marginColor(margin);

    return Container(
      key: Key('admin_tier_definition_${definition.tierKey.wire}'),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _TierDefinitionHeader(
            definition: definition,
            editingEnabled: editingEnabled,
            onEdit: onEdit,
          ),
          const SizedBox(height: 12),
          _TierDefinitionFacts(
            definition: definition,
            margin: margin,
            marginColor: marginColor,
          ),
          const SizedBox(height: 10),
          Text(
            'Updated ${adminHumanDateTime(definition.lastEditedAt)}'
            '${definition.lastEditedBy != null ? ' by ${definition.lastEditedBy}' : ''}',
            style: AppTextStyles.body11(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  static String _tierTitle(PollingTierKey tier) {
    return adminPollingTierLabel(tier);
  }

  static String _tierSummary(PollingTierKey tier) {
    switch (tier) {
      case PollingTierKey.standard:
        return 'Webhook vendors stay real time. Poll-only vendors check every 5 minutes.';
      case PollingTierKey.premium:
        return 'Faster polling where vendors allow it. Oracle stays at 5 minutes.';
      case PollingTierKey.custom:
        return 'Negotiated per location. Set polling, price, and margin manually.';
    }
  }

  static Color _marginColor(int margin) {
    if (margin > 0) return AppColors.positive;
    if (margin < 0) return AppColors.negative;
    return AppColors.textMuted;
  }
}

class _PricePill extends StatelessWidget {
  const _PricePill({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        value,
        style: AppTextStyles.mono12(
          color: AppColors.textPrimary,
          weight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _TierDefinitionHeader extends StatelessWidget {
  const _TierDefinitionHeader({
    required this.definition,
    required this.editingEnabled,
    required this.onEdit,
  });

  final TierDefinition definition;
  final bool editingEnabled;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                _TierDefinitionSubcard._tierTitle(definition.tierKey),
                style: AppTextStyles.body14(
                  color: AppColors.textPrimary,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 3),
              Text(
                _TierDefinitionSubcard._tierSummary(definition.tierKey),
                style: AppTextStyles.body12(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _PricePill(value: formatCents(definition.defaultMonthlyPriceCents)),
        if (editingEnabled) ...<Widget>[
          const SizedBox(width: 8),
          AdminActionButton(
            key: Key('admin_tier_definition_edit_${definition.tierKey.wire}'),
            label: 'Edit',
            onPressed: onEdit,
            icon: Icons.edit_outlined,
            compact: true,
            minWidth: 76,
          ),
        ],
      ],
    );
  }
}

class _TierDefinitionFacts extends StatelessWidget {
  const _TierDefinitionFacts({
    required this.definition,
    required this.margin,
    required this.marginColor,
  });

  final TierDefinition definition;
  final int margin;
  final Color marginColor;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        _TierFact(
          label: 'Polling frequency',
          value: _frequencySummary(definition.pollingCadencePerVendorSeconds),
        ),
        _TierFact(
          label: 'Vendor cost',
          value: formatCents(definition.vendorApiCostEstimateCentsMonthly),
        ),
        _TierFact(
          label: 'Margin',
          value: formatCents(margin),
          valueColor: marginColor,
        ),
      ],
    );
  }
}

class _TierFact extends StatelessWidget {
  const _TierFact({
    required this.label,
    required this.value,
    this.valueColor = AppColors.textPrimary,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 180,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: AppTextStyles.uiLabel(color: AppColors.textMuted)),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body13(
              color: valueColor,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

String _frequencySummary(Map<String, int> cadence) {
  if (cadence.isEmpty) return 'Set per location';
  final bySeconds = <int, List<String>>{};
  for (final vendorId in kPollOnlyVendorIds) {
    final seconds = cadence[vendorId];
    if (seconds == null) continue;
    bySeconds.putIfAbsent(seconds, () => <String>[]).add(vendorId);
  }
  if (bySeconds.isEmpty) return 'Set per location';
  final entries = bySeconds.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  if (entries.length == 1) {
    return 'All vendors: ${_formatCompactCadenceSeconds(entries.single.key)}';
  }
  return entries
      .map((entry) {
        final vendors = entry.value;
        final vendorLabel = vendors.length == 1
            ? _shortVendorLabel(vendors.single)
            : '${vendors.length} vendors';
        return '$vendorLabel: ${_formatCompactCadenceSeconds(entry.key)}';
      })
      .join('; ');
}

String _shortVendorLabel(String vendorId) {
  switch (vendorId) {
    case 'oracle_micros_simphony':
      return 'Oracle';
    case 'quickbooks_time':
      return 'QuickBooks';
    case 'push_operations':
      return 'Push Ops';
    default:
      return kPollOnlyVendorDisplayNames[vendorId] ?? vendorId;
  }
}

String _formatCompactCadenceSeconds(int seconds) {
  if (seconds >= 60 && seconds % 60 == 0) {
    final minutes = seconds ~/ 60;
    return '$minutes min';
  }
  return '${seconds}s';
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
