// Phase 8 spine-bridge Lane .B — Covers source per-service-period
// toggle.
//
// Three states per service period:
//
//   * vendor   — read covers from POS (default).
//   * forecast — substitute the F&F-computed forecast covers value.
//   * manual   — operator types the number per business date.
//
// Authority: docs/contracts/data_accuracy_settings_contract.md
// "Covers source card" + "Covers source resolution" sections.
//
// Per-Daypart V1 Slice R5 (Gap 27/36): the hardcoded 3-daypart
// `Daypart.values` iteration is replaced by the operator-configured
// service periods (resolver-ordered via
// `ServicePeriodDefinitionResolver.ordered`). An operator with any
// number of periods (e.g. breakfast/lunch/dinner/late_night) gets one
// row per period.
//
// When the operator picks `manual` for a period, the parent screen is
// responsible for rendering the manual-entry sub-card; this widget
// only owns the per-period 3-way picker plus the dynamic vendor
// relativity label.

import 'package:flutter/material.dart';

import '../../domain/models/data_accuracy_settings.dart';
import '../../domain/models/service_period_definition.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
import '../../theme/app_theme.dart';
import 'vendor_relativity_label.dart';

class CoversSourceToggle extends StatelessWidget {
  const CoversSourceToggle({
    super.key,
    required this.settings,
    required this.servicePeriods,
    required this.onChanged,
    required this.bundle,
  });

  final DataAccuracySettings settings;

  /// Operator-configured service periods, resolver-ordered by the
  /// screen (`ServicePeriodDefinitionResolver.ordered`). One picker row
  /// renders per period; never a hardcoded daypart list.
  final List<ServicePeriodDefinition> servicePeriods;

  final void Function(String servicePeriodId, CoversSource source) onChanged;
  final VendorConnectionsBundle? bundle;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('data_accuracy_covers_source_card'),
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
                Icons.restaurant_menu_outlined,
                size: 18,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Where covers come from, per service period',
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
            'Covers (number of guests served) drive the per-cover '
            'metrics on your dashboard. Pick where Forge & Flow should read '
            'covers from for each service period. Different periods can use '
            'different sources, for example vendor at lunch and manual at '
            'dinner.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          if (servicePeriods.isEmpty)
            Text(
              'No service periods are configured yet. Set up your service '
              'periods under Business timing and they will appear here.',
              key: const Key('covers_source_no_periods'),
              style: AppTextStyles.body13(color: AppColors.textMuted),
            )
          else
            for (final period in servicePeriods) ...[
              _PeriodRow(
                period: period,
                source: settings.coversSourceFor(period.id),
                sourceMetadata: settings.coversSourceSourceFor(period.id),
                onChanged: (source) => onChanged(period.id, source),
              ),
              if (period != servicePeriods.last) const SizedBox(height: 10),
            ],
          const SizedBox(height: 14),
          VendorRelativityLabel(
            setting: VendorRelativitySetting.covers,
            bundle: bundle,
          ),
        ],
      ),
    );
  }
}

class _PeriodRow extends StatelessWidget {
  const _PeriodRow({
    required this.period,
    required this.source,
    required this.sourceMetadata,
    required this.onChanged,
  });

  final ServicePeriodDefinition period;
  final CoversSource source;
  final DataAccuracySettingSource? sourceMetadata;
  final ValueChanged<CoversSource> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('covers_source_daypart_${period.id}'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 96,
                child: Text(
                  period.label,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
              ),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final option in CoversSource.values)
                      _ChoiceChip(
                        chipKey: Key(
                          'covers_source_chip_${period.id}_${option.wire}',
                        ),
                        label: _sourceLabel(option),
                        selected: option == source,
                        onTap: () => onChanged(option),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (sourceMetadata != null) ...[
            const SizedBox(height: 6),
            Text(
              'Source: ${sourceMetadata!.label}',
              key: Key('covers_source_source_${period.id}'),
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }

  String _sourceLabel(CoversSource s) {
    switch (s) {
      case CoversSource.vendor:
        return 'Vendor';
      case CoversSource.forecast:
        return 'Forecast';
      case CoversSource.manual:
        return 'Manual';
      case CoversSource.reservationPlusWalkin:
        return 'Reservations + walk-ins';
    }
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.chipKey,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final Key chipKey;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: chipKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.sunset.withValues(alpha: 0.14)
              : AppColors.backgroundSurface,
          border: Border.all(
            color: selected ? AppColors.sunsetDark : AppColors.borderSubtle,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: AppTextStyles.mono14(
            color: selected ? AppColors.sunsetDark : AppColors.textSecondary,
            weight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
