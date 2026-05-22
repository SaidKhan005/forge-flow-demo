// Phase 8 spine-bridge Lane .B: Data Accuracy visual map.
//
// Operator-facing "What this page is for" card. It sits at the top of
// the Data Accuracy screen and shows how labor, covers, and data
// freshness flow from the operator's connected vendors into the
// app dashboard.

import 'package:flutter/material.dart';

import '../../domain/models/service_period_definition.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
import '../../services/integration/labor_wage_source_class.dart';
import '../../theme/app_theme.dart';
import 'data_accuracy_applicability.dart';
import 'package:forge_and_flow/widgets/console/console_info_button.dart';
import 'package:forge_and_flow/widgets/console/console_section_heading.dart';
import 'vendor_relativity_label.dart';

class DataAccuracyExplainerCard extends StatelessWidget {
  const DataAccuracyExplainerCard({
    super.key,
    required this.locationLabel,
    required this.bundle,
    required this.dataFreshnessApplies,
    this.servicePeriods = const <ServicePeriodDefinition>[],
  });

  final String locationLabel;
  final VendorConnectionsBundle? bundle;
  final bool dataFreshnessApplies;
  final List<ServicePeriodDefinition> servicePeriods;

  @override
  Widget build(BuildContext context) {
    final servicePeriodLabels = servicePeriods
        .map((period) => period.label.trim())
        .where((label) => label.isNotEmpty)
        .toList(growable: false);

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
          OperatorWebSectionHeading(
            title: 'How Forge & Flow reads this location',
            trailing: OperatorWebInfoButton(
              title: 'How Forge & Flow reads this location',
              tooltip: 'How Forge & Flow reads this location',
              body: Text(
                'These settings decide which source Forge & Flow uses when '
                'vendor data is incomplete or arrives on a schedule at '
                '$locationLabel.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Labor, covers, and freshness feed the app dashboard. Each setting is available only when the connected vendors make that choice useful.',
            key: const Key('data_accuracy_map_intro'),
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          _MapNode(
            slug: 'labor',
            icon: Icons.payments_outlined,
            heading: 'Labor',
            body: _laborMapLine(bundle),
            vendors: _vendorList(<VendorConnectionRow?>[
              bundle?.laborConnection,
            ]),
          ),
          const SizedBox(height: 12),
          _MapNode(
            slug: 'covers',
            icon: Icons.groups_2_outlined,
            heading: 'Covers',
            body: _coversMapLine(bundle, servicePeriodLabels),
            vendors: _vendorList(<VendorConnectionRow?>[
              bundle?.posConnection,
              bundle?.reservationConnection,
            ]),
          ),
          const SizedBox(height: 12),
          _MapNode(
            slug: 'freshness',
            icon: Icons.sync_outlined,
            heading: 'Data freshness',
            body: dataFreshnessApplies
                ? _freshnessMapLine(bundle)
                : 'Shows whether Forge & Flow checks vendors on a schedule or receives updates when vendors push them.',
            vendors: dataAccuracyConnectedPollOnlyVendors(bundle),
            disabled: !dataFreshnessApplies,
          ),
        ],
      ),
    );
  }

  static String _laborMapLine(VendorConnectionsBundle? bundle) {
    final labor = bundle?.laborConnection;
    if (labor == null) {
      return 'Controls how Forge & Flow turns labor hours into labor dollars for the app dashboard.';
    }
    final wageClass = laborWageSourceClassFor(labor.vendorId);
    return switch (wageClass) {
      LaborWageSourceClass.perEmployeeWithDollars =>
        '${labor.displayName} can supply labor dollars. This setting chooses the labor-dollar source for the app dashboard.',
      LaborWageSourceClass.perEmployeeWithRates =>
        '${labor.displayName} supplies employee rates and time. This setting chooses how labor dollars are calculated.',
      LaborWageSourceClass.perPositionWithRates =>
        '${labor.displayName} supplies role rates and hours. This setting chooses how labor dollars are calculated.',
      LaborWageSourceClass.hoursOnly =>
        '${labor.displayName} supplies hours. This setting chooses which wage source turns those hours into dollars.',
      null =>
        '${labor.displayName} is connected. This setting chooses the labor-dollar source for the app dashboard.',
    };
  }

  static String _coversMapLine(
    VendorConnectionsBundle? bundle,
    List<String> servicePeriodLabels,
  ) {
    final pos = bundle?.posConnection;
    if (pos == null) {
      return 'Controls the guest-count source for each service period. Covers drive per-cover metrics.';
    }
    if (posVendorExposesCovers(pos.vendorId)) {
      return '${pos.displayName} can supply POS guest counts. This setting chooses the cover source by service period.';
    }
    final periods = servicePeriodLabels.isEmpty
        ? 'each service period'
        : servicePeriodLabels.take(3).join(', ');
    return '${pos.displayName} does not supply POS guest counts. This setting chooses the fallback cover source for $periods.';
  }

  static String _freshnessMapLine(VendorConnectionsBundle? bundle) {
    final vendors = _pollOnlyVendorNames(bundle);
    if (vendors.isEmpty) {
      return 'Controls how often Forge & Flow checks scheduled integrations for new data.';
    }
    return 'Controls how often Forge & Flow checks ${vendors.join(' and ')} for new data.';
  }

  static List<VendorConnectionRow> _vendorList(
    List<VendorConnectionRow?> rows,
  ) {
    return rows.whereType<VendorConnectionRow>().toList(growable: false);
  }

  static List<String> _pollOnlyVendorNames(VendorConnectionsBundle? bundle) {
    return dataAccuracyConnectedPollOnlyVendors(
      bundle,
    ).map((row) => row.displayName).toList(growable: false);
  }
}

class _MapNode extends StatelessWidget {
  const _MapNode({
    required this.slug,
    required this.icon,
    required this.heading,
    required this.body,
    required this.vendors,
    this.disabled = false,
  });

  final String slug;
  final IconData icon;
  final String heading;
  final String body;
  final List<VendorConnectionRow> vendors;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('data_accuracy_explainer_$slug'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: disabled ? AppColors.shimmer : AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 20,
            color: disabled ? AppColors.textMuted : AppColors.sunsetDark,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  heading,
                  style: AppTextStyles.mono11(
                    color: disabled
                        ? AppColors.textMuted
                        : AppColors.sunsetDark,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: AppTextStyles.body13(
                    color: disabled
                        ? AppColors.textMuted
                        : AppColors.textPrimary,
                  ),
                ),
                if (vendors.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final vendor in vendors)
                        _VendorChip(vendor: vendor, disabled: disabled),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VendorChip extends StatelessWidget {
  const _VendorChip({required this.vendor, required this.disabled});

  final VendorConnectionRow vendor;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _VendorChipMark(vendor: vendor, disabled: disabled),
          const SizedBox(width: 6),
          Text(
            vendor.displayName,
            style: AppTextStyles.chipLabel(
              color: disabled ? AppColors.textMuted : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _VendorChipMark extends StatelessWidget {
  const _VendorChipMark({required this.vendor, required this.disabled});

  final VendorConnectionRow vendor;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final initials = vendor.displayName
        .split(RegExp(r'\s+'))
        .where((word) => word.trim().isNotEmpty)
        .take(2)
        .map((word) => word.substring(0, 1))
        .join();
    return Container(
      width: 18,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: disabled
            ? AppColors.shimmer
            : AppColors.sunset.withValues(alpha: 0.12),
        border: Border.all(
          color: disabled ? AppColors.borderSubtle : AppColors.sunsetDark,
          width: 1,
        ),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        initials.isEmpty ? '?' : initials,
        style: AppTextStyles.mono11(
          color: disabled ? AppColors.textMuted : AppColors.sunsetDark,
        ),
      ),
    );
  }
}

class DataAccuracyCoversModeInfo extends StatelessWidget {
  const DataAccuracyCoversModeInfo({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      key: Key('data_accuracy_covers_mode_info'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ModeLine(
          title: 'Vendor',
          body: 'Use POS guest counts when the connected POS exposes covers.',
        ),
        SizedBox(height: 8),
        _ModeLine(
          title: 'Forecast',
          body:
              'Use the Forge & Flow forecast, built from closed shifts and demand signals.',
        ),
        SizedBox(height: 8),
        _ModeLine(
          title: 'Manual',
          body:
              'Type the guest count for that business date and service period.',
        ),
        SizedBox(height: 8),
        _ModeLine(
          title: 'Reservations + walk-ins',
          body: 'Use reservation-book covers plus the walk-in count you enter.',
        ),
      ],
    );
  }
}

class _ModeLine extends StatelessWidget {
  const _ModeLine({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: AppTextStyles.body13(color: AppColors.textSecondary),
        children: [
          TextSpan(
            text: '$title: ',
            style: AppTextStyles.body13(
              color: AppColors.textPrimary,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
          TextSpan(text: body),
        ],
      ),
    );
  }
}
