import 'package:flutter/material.dart';

import '../../domain/services/business_timing_profile_resolver.dart';
import '../../theme/app_theme.dart';
import '../admin_route_handoff.dart';
import '../models/operator_location_admin_models.dart';
import '../services/admin_business_timing_resolution_gateway.dart';
import '../services/admin_business_timing_resolution_projection.dart';
import '../services/operator_location_admin_gateway.dart';
import '../widgets/admin_responsive_layout.dart';

class AdminTimingSetupScreen extends StatelessWidget {
  const AdminTimingSetupScreen({
    super.key,
    required this.operatorGateway,
    required this.selectedScope,
    required this.scopeLocationIds,
    this.editingEnabled = true,
    this.timingResolutionGateway,
  });

  final OperatorLocationAdminGateway operatorGateway;
  final AdminHierarchyScopeIntent selectedScope;
  final Set<String> scopeLocationIds;
  final bool editingEnabled;

  /// Fix #4 / S4 (G41): READ-ONLY S2 admin cross-tenant business-
  /// timing resolution gateway. Null falls back to the seeded
  /// in-memory demo gateway (mirrors the established optional-gateway
  /// admin DI pattern), so demo / share-preview / widget tests render
  /// without the Cloud Run admin proxy. This screen reads timing only;
  /// server-side super admin repair routes exist for profile writes.
  final AdminBusinessTimingResolutionGateway? timingResolutionGateway;

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
                        timingResolutionGateway: timingResolutionGateway ??
                            _fallbackTimingResolutionGateway,
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

/// Fix #4 / S4 (G41): shared seeded in-memory fallback so demo /
/// share-preview / widget tests render without the Cloud Run admin
/// proxy. Empty by default → the screen shows its honest "no timing
/// profile yet" state instead of fabricating values. Production
/// passes a real [HttpAdminBusinessTimingResolutionGateway].
final AdminBusinessTimingResolutionGateway _fallbackTimingResolutionGateway =
    InMemoryAdminBusinessTimingResolutionGateway();

class _TimingSummaryCard extends StatelessWidget {
  const _TimingSummaryCard({
    required this.selectedScope,
    required this.location,
    required this.scopeLocationCount,
    required this.editingEnabled,
    required this.timingResolutionGateway,
  });

  final AdminHierarchyScopeIntent selectedScope;
  final LocationAdminRecord location;
  final int? scopeLocationCount;
  final bool editingEnabled;
  final AdminBusinessTimingResolutionGateway timingResolutionGateway;

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
                  'Showing timing from ${location.name}. Other locations under this scope may have local overrides. Review each location individually for accuracy.',
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
          const SizedBox(height: 12),
          // Fix #4 / S4 (G41): the timezone / business-day / week-start
          // / service-period rows below are now the REAL resolved
          // `EffectiveBusinessTimingProfile` — the canonical S2 admin
          // candidate chain run through the ONE
          // `BusinessTimingProfileResolver`. The prior hardcoded
          // periods, hardcoded "Monday", hardcoded close-rule string,
          // and the legacy `_businessDayStart(businessDayRolloverHour)`
          // integer-column path are deleted. Gap 31: the shift-close
          // rule is being removed as an operator setting, so it is no
          // longer shown here (auto-derived per shift downstream).
          _ResolvedTimingFields(
            operatorId: selectedScope.operatorId,
            locationId: location.locationId,
            gateway: timingResolutionGateway,
          ),
          const SizedBox(height: 16),
          Text(
            editingEnabled
                ? 'Timing is shown here for review so the selected hierarchy has a clear source of truth. Operators own these values; admin is read-only.'
                : 'Support access can review timing without changing it.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Fix #4 / S4 (G41): resolves the REAL effective business-timing
/// profile via the READ-ONLY S2 admin gateway → canonical resolver →
/// real per-field provenance, replacing every previously hardcoded /
/// synthetic value on this screen.
class _ResolvedTimingFields extends StatelessWidget {
  const _ResolvedTimingFields({
    required this.operatorId,
    required this.locationId,
    required this.gateway,
  });

  final String operatorId;
  final String locationId;
  final AdminBusinessTimingResolutionGateway gateway;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AdminBusinessTimingResolution>(
      future: gateway.resolve(
        operatorId: operatorId,
        locationId: locationId,
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            key: Key('admin_timing_resolution_loading'),
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(minHeight: 2),
          );
        }
        if (snapshot.hasError) {
          return Padding(
            key: const Key('admin_timing_resolution_error'),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Effective timing could not load. The operator owns these '
              'values; try again after the operator has saved a timing '
              'profile.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          );
        }
        final resolution = snapshot.data!;
        if (resolution.candidates.isEmpty) {
          return Padding(
            key: const Key('admin_timing_resolution_empty'),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No business timing profile has been saved by the operator '
              'yet. Timezone, business day, and service periods will '
              'appear here once the operator configures them.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          );
        }
        final AdminEffectiveTimingProjection projection;
        try {
          projection =
              AdminBusinessTimingResolutionProjection.project(resolution);
        } on BusinessTimingProfileResolutionException {
          return Padding(
            key: const Key('admin_timing_resolution_error'),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Effective timing could not load. The operator owns these '
              'values; try again after the operator has saved a timing '
              'profile.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          );
        }
        final effective = projection.effective;
        final sourceLabel = projection.provenance.detailLabel;
        final periods = effective.servicePeriodDefinitions.toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
        return Column(
          key: const Key('admin_timing_resolved_fields'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AdminDetailRow(
              label: 'Effective from',
              value: projection.effectiveDateLabel,
            ),
            AdminDetailRow(
              label: 'Timezone',
              value: effective.businessTimezone,
            ),
            AdminDetailRow(label: 'Timezone source', value: sourceLabel),
            AdminDetailRow(
              label: 'Business day starts',
              value: effective.businessDayStartLocalTime,
            ),
            AdminDetailRow(label: 'Day-start source', value: sourceLabel),
            AdminDetailRow(
              label: 'Week starts',
              value: AdminBusinessTimingResolutionProjection.weekdayLabel(
                effective.weekStartDay,
              ),
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
                children: <Widget>[
                  for (final period in periods)
                    _TimingPeriodLine(
                      label: period.label,
                      range:
                          '${period.startLocalTime} - ${period.endLocalTime}',
                      daysLabel:
                          AdminBusinessTimingResolutionProjection.daysLabel(
                        period.applicableDays,
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Source: $sourceLabel',
                      style: AppTextStyles.mono11(
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TimingPeriodLine extends StatelessWidget {
  const _TimingPeriodLine({
    required this.label,
    required this.range,
    this.daysLabel,
  });

  final String label;
  final String range;

  /// G45 / Gap 28: plain-English day restriction (e.g. "Mon, Tue"),
  /// or null when the period runs every day (the common case).
  final String? daysLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
                if (daysLabel != null)
                  Text(
                    daysLabel!,
                    style: AppTextStyles.mono11(color: AppColors.textMuted),
                  ),
              ],
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
