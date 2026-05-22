// Phase 8 spine-bridge Lane .B: Data Accuracy visual map.
//
// Operator-facing "What this page is for" card. It sits at the top of
// the Data Accuracy screen and shows how labor, covers, and data
// freshness flow from the operator's connected vendors into the
// dashboard.

import 'package:flutter/material.dart';

import '../../domain/models/service_period_definition.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
import '../../services/integration/labor_wage_source_class.dart';
import '../../theme/app_theme.dart';
import 'data_accuracy_applicability.dart';
import 'operator_web_info_button.dart';
import 'operator_web_section_heading.dart';
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
            title: 'What this page is for',
            trailing: OperatorWebInfoButton(
              title: 'What this page is for',
              tooltip: 'What this page is for',
              body: Text(
                'This page tells Forge & Flow which source to trust for '
                'labor dollars, guest counts, and update timing at '
                '$locationLabel.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'A quick map of the numbers behind the dashboard.',
            key: const Key('data_accuracy_map_intro'),
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          if (!dataAccuracyHasAnyConnectedVendor(bundle)) ...[
            const SizedBox(height: 10),
            const _NoVendorsNotice(),
          ],
          const SizedBox(height: 14),
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
                : dataFreshnessNotApplicableCopy(bundle),
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
      return 'Use a labor vendor when one is connected, or keep manual '
          'wage rows as the fallback.';
    }
    final wageClass = laborWageSourceClassFor(labor.vendorId);
    return switch (wageClass) {
      LaborWageSourceClass.perEmployeeWithDollars =>
        '${labor.displayName} reports labor dollars directly. Manual mix '
            'stays available when you want to override it.',
      LaborWageSourceClass.perEmployeeWithRates =>
        '${labor.displayName} reports employee rates. Forge & Flow turns '
            'rate and time into labor dollars.',
      LaborWageSourceClass.perPositionWithRates =>
        '${labor.displayName} reports position rates. Forge & Flow turns '
            'role rates and hours into labor dollars.',
      LaborWageSourceClass.hoursOnly =>
        '${labor.displayName} reports hours only. Manual mix stays available '
            'when target wage fallback is not the right fit.',
      null =>
        '${labor.displayName} is connected. Manual mix stays available if '
            'vendor labor dollars are not usable.',
    };
  }

  static String _coversMapLine(
    VendorConnectionsBundle? bundle,
    List<String> servicePeriodLabels,
  ) {
    final pos = bundle?.posConnection;
    if (pos == null) {
      return 'Choose vendor, forecast, manual, or reservations plus walk-ins '
          'for each service period.';
    }
    if (posVendorExposesCovers(pos.vendorId)) {
      return '${pos.displayName} exposes covers. You can still override a '
          'service period when the floor count needs a different source.';
    }
    final periods = servicePeriodLabels.isEmpty
        ? 'each service period'
        : servicePeriodLabels.take(3).join(', ');
    return '${pos.displayName} does not expose covers. Pick the source for '
        '$periods so per-cover metrics stay honest.';
  }

  static String _freshnessMapLine(VendorConnectionsBundle? bundle) {
    final vendors = _pollOnlyVendorNames(bundle);
    if (vendors.isEmpty) {
      return 'Applies only when Oracle MICROS Simphony, QuickBooks Time, '
          'Humanity, Agendrix, or Push Operations is connected.';
    }
    return 'Applies to ${vendors.join(' and ')} because those vendors need '
        'scheduled checks.';
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

class _NoVendorsNotice extends StatelessWidget {
  const _NoVendorsNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('data_accuracy_no_vendors_notice'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.shimmer,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.link_off_outlined,
            size: 18,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'No vendor is connected for this location yet. Manual labor and manual covers stay available while vendor-only choices wait for an integration.',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
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
          body:
              'Use the POS count. Best when the POS exposes covers and the count is trusted.',
        ),
        SizedBox(height: 8),
        _ModeLine(
          title: 'Forecast',
          body:
              'Use the Forge & Flow forecast. Best when the vendor count is missing or noisy.',
        ),
        SizedBox(height: 8),
        _ModeLine(
          title: 'Manual',
          body:
              'Type the count yourself. Best when the floor manager closes covers by hand.',
        ),
        SizedBox(height: 8),
        _ModeLine(
          title: 'Reservations + walk-ins',
          body:
              'Start with the reservation book and add walk-ins. Best when the POS does not count covers.',
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
