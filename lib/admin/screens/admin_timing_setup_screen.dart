import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../admin_route_handoff.dart';
import '../models/operator_location_admin_models.dart';
import '../services/operator_location_admin_gateway.dart';
import '../widgets/admin_responsive_layout.dart';

class AdminTimingSetupScreen extends StatelessWidget {
  const AdminTimingSetupScreen({
    super.key,
    required this.operatorGateway,
    required this.selectedScope,
    required this.scopeLocationIds,
    this.editingEnabled = true,
  });

  final OperatorLocationAdminGateway operatorGateway;
  final AdminHierarchyScopeIntent selectedScope;
  final Set<String> scopeLocationIds;
  final bool editingEnabled;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<OperatorAdminBundle>>(
      future: operatorGateway.listOperators(),
      builder: (context, snapshot) {
        final bundles = snapshot.data ?? const <OperatorAdminBundle>[];
        final bundle = _bundleForScope(bundles, selectedScope.operatorId);
        final location = bundle == null ? null : _locationForScope(bundle);
        return ColoredBox(
          key: const Key('admin_timing_setup_screen'),
          color: AppColors.backgroundDeep,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 880),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (snapshot.connectionState != ConnectionState.done)
                      const LinearProgressIndicator(minHeight: 2),
                    if (snapshot.hasError)
                      _TimingMessageCard(
                        icon: Icons.error_outline,
                        title: 'Timing could not load',
                        body:
                            'Refresh Business Accounts and try this setup screen again.',
                      )
                    else if (location == null)
                      const _TimingMessageCard(
                        icon: Icons.storefront_outlined,
                        title: 'Choose a location before editing timing',
                        body:
                            'Business and org-unit scopes show inherited timing from the locations they cover. Add or select a location to review timezone, business day, and service periods.',
                      )
                    else
                      _TimingSummaryCard(
                        selectedScope: selectedScope,
                        location: location,
                        scopeLocationCount: scopeLocationIds.isEmpty
                            ? null
                            : scopeLocationIds.length,
                        editingEnabled: editingEnabled,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  OperatorAdminBundle? _bundleForScope(
    List<OperatorAdminBundle> bundles,
    String operatorId,
  ) {
    for (final bundle in bundles) {
      if (bundle.operator.operatorId == operatorId) return bundle;
    }
    return null;
  }

  LocationAdminRecord? _locationForScope(OperatorAdminBundle bundle) {
    final selectedLocationId = selectedScope.locationId;
    if (selectedLocationId != null && selectedLocationId.isNotEmpty) {
      for (final location in bundle.locations) {
        if (location.locationId == selectedLocationId) return location;
      }
    }
    if (scopeLocationIds.isNotEmpty) {
      final primary = bundle.primaryLocation;
      if (primary != null && scopeLocationIds.contains(primary.locationId)) {
        return primary;
      }
      for (final location in bundle.locations) {
        if (scopeLocationIds.contains(location.locationId)) return location;
      }
    }
    return bundle.primaryLocation ??
        (bundle.locations.isEmpty ? null : bundle.locations.first);
  }
}

class _TimingSummaryCard extends StatelessWidget {
  const _TimingSummaryCard({
    required this.selectedScope,
    required this.location,
    required this.scopeLocationCount,
    required this.editingEnabled,
  });

  final AdminHierarchyScopeIntent selectedScope;
  final LocationAdminRecord location;
  final int? scopeLocationCount;
  final bool editingEnabled;

  @override
  Widget build(BuildContext context) {
    final covered = scopeLocationCount == null
        ? 'Selected location'
        : '$scopeLocationCount covered location'
              '${scopeLocationCount == 1 ? '' : 's'}';
    return AdminCard(
      key: const Key('admin_timing_summary_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(
                Icons.schedule_outlined,
                size: 20,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Effective timing',
                      style: AppTextStyles.sectionTitle(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Review the timezone, business day, and service periods used by this selected scope.',
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (!selectedScope.isLocationScope &&
              scopeLocationCount != null &&
              scopeLocationCount! > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Container(
                key: const Key('admin_timing_scope_inheritance_notice'),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.cardGlow,
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'Showing timing from ${location.name}. Other locations under this scope may have local overrides — review each location individually for accuracy.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ),
            ),
          AdminDetailRow(
            label: 'Selected scope',
            value: selectedScope.displayLabel,
          ),
          AdminDetailRow(label: 'Timing source', value: location.name),
          AdminDetailRow(label: 'Covered locations', value: covered),
          AdminDetailRow(label: 'Timezone', value: location.timezone),
          AdminDetailRow(
            label: 'Business day starts',
            value: _businessDayStart(location.businessDayRolloverHour),
          ),
          const AdminDetailRow(label: 'Week starts', value: 'Monday'),
          const AdminDetailRow(
            label: 'Shift close rule',
            value:
                'Use the app close time if vendor finalization is unavailable',
          ),
          const SizedBox(height: 16),
          Container(
            key: const Key('admin_timing_service_periods_panel'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.cardGlow,
              border: Border.all(color: AppColors.borderSubtle, width: 1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const <Widget>[
                _TimingPeriodLine(label: 'Lunch', range: '11:00 - 16:00'),
                _TimingPeriodLine(label: 'Dinner', range: '16:00 - 22:00'),
                _TimingPeriodLine(label: 'Late night', range: '22:00 - 02:00'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            editingEnabled
                ? 'Timing is shown here for review so the selected hierarchy has a clear source of truth.'
                : 'Support access can review timing without changing it.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  static String _businessDayStart(int? hour) {
    final safeHour = (hour ?? 4).clamp(0, 23);
    return '${safeHour.toString().padLeft(2, '0')}:00';
  }
}

class _TimingPeriodLine extends StatelessWidget {
  const _TimingPeriodLine({required this.label, required this.range});

  final String label;
  final String range;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: AppTextStyles.body14(color: AppColors.textPrimary),
            ),
          ),
          Text(range, style: AppTextStyles.mono11(color: AppColors.textMuted)),
        ],
      ),
    );
  }
}

class _TimingMessageCard extends StatelessWidget {
  const _TimingMessageCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return AdminCard(
      key: const Key('admin_timing_message_card'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: AppTextStyles.sectionTitle(
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
