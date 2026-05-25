import '../../domain/models/data_accuracy_service_period_setting.dart';
import '../../domain/models/data_accuracy_settings.dart';
import '../../domain/models/forge_flow_polling_tier_assignment.dart';
import '../../operator_web/services/operator_web_data_accuracy_gateway.dart';
import 'data_accuracy_admin_gateway.dart';

class AdminOperatorWebDataAccuracyGateway
    implements OperatorWebDataAccuracyGateway {
  AdminOperatorWebDataAccuracyGateway({
    required DataAccuracyAdminGateway adminGateway,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String reasonNote = 'Admin Data Accuracy parity edit.',
  }) : _adminGateway = adminGateway,
       _actorUserId = actorUserId,
       _actorIsForgeAdmin = actorIsForgeAdmin,
       _reasonNote = reasonNote;

  final DataAccuracyAdminGateway _adminGateway;
  final String _actorUserId;
  final bool _actorIsForgeAdmin;
  final String _reasonNote;

  @override
  Future<DataAccuracySettings?> loadSettings({
    required String operatorId,
    required String locationId,
  }) {
    return _adminGateway.loadSettings(
      operatorId: operatorId,
      locationId: locationId,
    );
  }

  @override
  Future<DataAccuracySettings> saveSettings(DataAccuracySettings settings) {
    return _adminGateway.saveSettings(
      settings: settings,
      actorUserId: _actorUserId,
      actorIsForgeAdmin: _actorIsForgeAdmin,
      reasonNote: _reasonNote,
    );
  }

  @override
  Future<DataAccuracySettings> saveManualCovers({
    required String operatorId,
    required String locationId,
    required String businessDateIso,
    required String servicePeriodKey,
    required int covers,
  }) {
    return _adminGateway.saveManualCovers(
      DataAccuracyManualCoversSaveCommand(
        target: DataAccuracyManualCoversTarget(
          operatorId: operatorId,
          locationId: locationId,
          businessDateIso: businessDateIso,
          servicePeriodKey: servicePeriodKey,
        ),
        covers: covers,
        actorUserId: _actorUserId,
        actorIsForgeAdmin: _actorIsForgeAdmin,
        reasonNote: _reasonNote,
      ),
    );
  }

  @override
  Future<DataAccuracySettings> clearManualCovers({
    required String operatorId,
    required String locationId,
    required String businessDateIso,
    required String servicePeriodKey,
  }) {
    return _adminGateway.clearManualCovers(
      operatorId: operatorId,
      locationId: locationId,
      businessDateIso: businessDateIso,
      servicePeriodKey: servicePeriodKey,
      actorUserId: _actorUserId,
      actorIsForgeAdmin: _actorIsForgeAdmin,
      reasonNote: _reasonNote,
    );
  }

  @override
  Future<List<DataAccuracyServicePeriodSetting>> loadServicePeriodSettings({
    required String operatorId,
    required String locationId,
  }) {
    return _adminGateway.listDataAccuracyServicePeriodRows(
      operatorId: operatorId,
      locationId: locationId,
    );
  }

  @override
  Future<OperatorWebPollingTierSnapshot?> loadPollingTierAssignment({
    required String operatorId,
    required String locationId,
  }) async {
    final assignment = await _adminGateway.loadPollingTierAssignment(
      operatorId: operatorId,
      locationId: locationId,
    );
    if (assignment == null) return null;
    return OperatorWebPollingTierSnapshot(
      operatorId: assignment.operatorId,
      locationId: assignment.locationId,
      tierKey: assignment.tierKey.wire,
      pollingCadencePerVendorSeconds: assignment.pollingCadencePerVendorSeconds,
      monthlyPriceCents: assignment.monthlyPriceCents,
      effectiveAt: assignment.effectiveAt,
    );
  }

  @override
  Future<DataAccuracyServicePeriodSetting> saveServicePeriodSetting({
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    required ServicePeriodCoversSource coversSource,
    required ServicePeriodWageSource wageSource,
    required String effectiveAtBusinessDateIso,
  }) {
    return _adminGateway.overrideDataAccuracyServicePeriod(
      operatorId: operatorId,
      locationId: locationId,
      servicePeriodKey: servicePeriodKey,
      coversSource: coversSource,
      wageSource: wageSource,
      effectiveAtBusinessDateIso: effectiveAtBusinessDateIso,
      actorUserId: _actorUserId,
      actorIsForgeAdmin: _actorIsForgeAdmin,
      reasonNote: _reasonNote,
    );
  }

  @override
  Future<void> resetServicePeriodSetting({
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
  }) {
    return _adminGateway.resetServicePeriodSetting(
      operatorId: operatorId,
      locationId: locationId,
      servicePeriodKey: servicePeriodKey,
      actorUserId: _actorUserId,
      actorIsForgeAdmin: _actorIsForgeAdmin,
      reasonNote: _reasonNote,
    );
  }
}
