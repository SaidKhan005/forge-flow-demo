// Admin Data Accuracy parity mount.
//
// The admin scope picker chooses one location. Once a location is selected,
// this screen mounts the real Operator Web DataAccuracyScreen with admin
// adapters around the admin gateways. Admin-only tables, audit panels, local
// service-period dialogs, and in-page location pickers intentionally live
// outside this file.

import 'package:flutter/material.dart';

import '../../auth/permission_keys.dart';
import '../../domain/models/data_accuracy_settings.dart';
import '../../domain/models/service_period_definition.dart';
import '../../domain/services/business_date_resolver.dart';
import '../../domain/services/service_period_definition_resolver.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import '../../operator_web/auth/operator_web_auth_source.dart';
import '../../operator_web/screens/data_accuracy_screen.dart';
import '../../operator_web/services/operator_web_wage_authority_gateway.dart';
import '../../services/integration/iana_timezone_converter.dart';
import '../../theme/app_theme.dart';
import '../admin_route_handoff.dart';
import '../services/admin_business_timing_resolution_gateway.dart';
import '../services/admin_business_timing_resolution_projection.dart';
import '../services/data_accuracy_admin_gateway.dart';
import '../services/operator_web_data_accuracy_admin_adapter.dart';
import '../services/operator_web_vendor_applicability_admin_adapter.dart';
import '../services/vendor_applicability_admin_gateway.dart';

class PerLocationDataAccuracyScreen extends StatefulWidget {
  const PerLocationDataAccuracyScreen({
    super.key,
    required this.gateway,
    required this.actorUserId,
    required this.timingResolutionGateway,
    required this.vendorApplicabilityGateway,
    this.vendorConnectionsGateway,
    this.wageAuthorityGateway,
    this.editingEnabled = true,
    this.initialScope,
    this.initialHierarchyScope,
    this.scopeLocationIds,
    this.onBackToBusinessAccounts,
    this.showPageHeader = true,
    this.showScopeControls = true,
    this.nowUtc,
  });

  final DataAccuracyAdminGateway gateway;
  final String actorUserId;
  final AdminBusinessTimingResolutionGateway timingResolutionGateway;
  final VendorApplicabilityAdminGateway vendorApplicabilityGateway;
  final VendorConnectionsGateway? vendorConnectionsGateway;
  final OperatorWebWageAuthorityGateway? wageAuthorityGateway;
  final bool editingEnabled;
  final AdminOperatorLocationScopeIntent? initialScope;
  final AdminHierarchyScopeIntent? initialHierarchyScope;
  final Set<String>? scopeLocationIds;
  final VoidCallback? onBackToBusinessAccounts;
  final bool showPageHeader;
  final bool showScopeControls;
  final DateTime Function()? nowUtc;

  @override
  State<PerLocationDataAccuracyScreen> createState() =>
      _PerLocationDataAccuracyScreenState();
}

class _PerLocationDataAccuracyScreenState
    extends State<PerLocationDataAccuracyScreen> {
  Future<_AdminDataAccuracyMountData>? _mountFuture;
  String? _mountKey;
  late final OperatorWebDemoWageAuthorityGateway _fallbackWageGateway =
      OperatorWebDemoWageAuthorityGateway();

  AdminHierarchyScopeIntent? get _selectedScope =>
      widget.initialHierarchyScope ?? widget.initialScope?.toHierarchyScope();

  @override
  void initState() {
    super.initState();
    _refreshMountFuture();
  }

  @override
  void didUpdateWidget(covariant PerLocationDataAccuracyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextKey = _selectedScope?.cacheKey;
    if (nextKey != _mountKey ||
        widget.gateway != oldWidget.gateway ||
        widget.timingResolutionGateway != oldWidget.timingResolutionGateway ||
        widget.nowUtc != oldWidget.nowUtc) {
      _refreshMountFuture();
    }
  }

  void _refreshMountFuture() {
    final scope = _selectedScope;
    _mountKey = scope?.cacheKey;
    if (scope == null || !scope.isLocationScope) {
      _mountFuture = null;
      return;
    }
    _mountFuture = _loadMountData(scope);
  }

  Future<_AdminDataAccuracyMountData> _loadMountData(
    AdminHierarchyScopeIntent scope,
  ) async {
    final locationId = scope.locationId;
    if (locationId == null || locationId.trim().isEmpty) {
      throw StateError('Data accuracy needs a selected location.');
    }
    final instantUtc = (widget.nowUtc ?? DateTime.now)().toUtc();
    final resolutionFuture = widget.timingResolutionGateway.resolve(
      operatorId: scope.operatorId,
      locationId: locationId,
      businessDate: _isoDate(instantUtc),
    );
    final rowFuture = widget.gateway.loadDataAccuracyRow(
      operatorId: scope.operatorId,
      locationId: locationId,
    );

    final resolution = await resolutionFuture;
    final projection = AdminBusinessTimingResolutionProjection.project(
      resolution,
    );
    final effective = projection.effective;
    final localNow = IanaTimezoneConverter.shared.toBusinessLocal(
      restaurantTimezone: effective.businessTimezone,
      instant: instantUtc,
    );
    final businessDateIso = BusinessDateResolver.resolve(
      localTimestamp: localNow,
      businessDayStartLocalTime: effective.businessDayStartLocalTime,
    );
    final servicePeriods = ServicePeriodDefinitionResolver.ordered(
      effective.servicePeriodDefinitions,
    );
    final row = await rowFuture;
    return _AdminDataAccuracyMountData(
      operatorId: scope.operatorId,
      locationId: locationId,
      businessName:
          _clean(row?.operatorRef.businessName) ??
          _clean(scope.operatorName) ??
          'Selected business',
      locationName:
          _clean(row?.operatorRef.locationName) ??
          _clean(scope.locationName) ??
          'Selected location',
      businessDateIso: businessDateIso,
      servicePeriods: servicePeriods,
      initialSettings: row?.settings,
      primaryTimezone: effective.businessTimezone,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = _selectedScope;
    if (scope == null || !scope.isLocationScope) {
      return const SizedBox(
        key: Key('admin_data_accuracy_waiting_for_location_scope'),
      );
    }
    return Container(
      key: const Key('admin_data_accuracy_screen'),
      color: AppColors.backgroundDeep,
      child: FutureBuilder<_AdminDataAccuracyMountData>(
        key: ValueKey<String>('admin_data_accuracy_mount_${scope.cacheKey}'),
        future: _mountFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _DataAccuracyBusinessTimingError(error: snapshot.error);
          }
          final data = snapshot.data;
          if (data == null) {
            return const _DataAccuracyBusinessTimingLoading();
          }
          return DataAccuracyScreen(
            key: ValueKey<String>(
              'admin_data_accuracy_operator_mount_${data.operatorId}_${data.locationId}',
            ),
            session: _sessionFor(data),
            locationId: data.locationId,
            locationName: data.locationName,
            gateway: widget.vendorConnectionsGateway,
            initialSettings: data.initialSettings,
            dataAccuracyGateway: AdminOperatorWebDataAccuracyGateway(
              adminGateway: widget.gateway,
              actorUserId: widget.actorUserId,
              actorIsForgeAdmin: widget.editingEnabled,
            ),
            vendorApplicabilityGateway:
                AdminOperatorWebVendorApplicabilityGateway(
                  adminGateway: widget.vendorApplicabilityGateway,
                  operatorId: data.operatorId,
                  locationId: data.locationId,
                ),
            businessDateIso: data.businessDateIso,
            servicePeriodsLoader: () async => data.servicePeriods,
            wageAuthorityGateway:
                widget.wageAuthorityGateway ?? _fallbackWageGateway,
            businessName: data.businessName,
          );
        },
      ),
    );
  }

  OperatorWebSession _sessionFor(_AdminDataAccuracyMountData data) {
    return OperatorWebSession(
      uid: 'admin:${widget.actorUserId}',
      email: '${widget.actorUserId}@admin.forgeflow.local',
      displayName: 'Forge Flow admin',
      operatorId: data.operatorId,
      businessName: data.businessName,
      primaryLocationId: data.locationId,
      primaryLocationName: data.locationName,
      roles: const <String>[PermissionKeys.roleOperatorOwner],
      primaryLocationTimezone: data.primaryTimezone,
    );
  }
}

class _AdminDataAccuracyMountData {
  const _AdminDataAccuracyMountData({
    required this.operatorId,
    required this.locationId,
    required this.businessName,
    required this.locationName,
    required this.businessDateIso,
    required this.servicePeriods,
    required this.primaryTimezone,
    this.initialSettings,
  });

  final String operatorId;
  final String locationId;
  final String businessName;
  final String locationName;
  final String businessDateIso;
  final List<ServicePeriodDefinition> servicePeriods;
  final String primaryTimezone;
  final DataAccuracySettings? initialSettings;
}

class _DataAccuracyBusinessTimingLoading extends StatelessWidget {
  const _DataAccuracyBusinessTimingLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      key: Key('operator_web_data_accuracy_loading'),
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppColors.sunsetDark,
        ),
      ),
    );
  }
}

class _DataAccuracyBusinessTimingError extends StatelessWidget {
  const _DataAccuracyBusinessTimingError({required this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('operator_web_data_accuracy_business_timing_error'),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 22,
                    color: AppColors.sunsetDark,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Data accuracy needs Business Timing',
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'We could not resolve the current business date for this '
                'location. To protect your settings, this page is not '
                'showing or saving data accuracy changes until Business '
                'Timing is available.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _isoDate(DateTime value) {
  final utc = value.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}

String? _clean(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed;
}
