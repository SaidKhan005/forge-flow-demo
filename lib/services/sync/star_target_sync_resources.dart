import '../../domain/models/active_target_profile.dart';
import '../../domain/models/target_cycle.dart';
import '../../domain/models/target_cycle_source.dart';
import '../../domain/models/target_profile_version.dart';

abstract class StarTargetSyncProxyClient {
  Future<SelectedStarShiftDecisionPage> fetchSelectedStarShiftDecisions({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  });

  Future<TargetCycleSyncPage> fetchTargetCycles({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  });

  Future<ActiveTargetProfileSyncPage> fetchActiveTargetProfiles({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  });

  Future<TargetProfileVersionSyncPage> fetchTargetProfileVersions({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  });
}

enum StarTargetResourceSyncState { synced, unavailable, skipped }

class StarTargetMirrorSyncResult {
  const StarTargetMirrorSyncResult({
    required this.selectedStars,
    required this.targetCycles,
    required this.activeTargetProfiles,
    required this.targetProfileVersions,
  });

  final StarTargetResourceSyncStatus selectedStars;
  final StarTargetResourceSyncStatus targetCycles;
  final StarTargetResourceSyncStatus activeTargetProfiles;
  final StarTargetResourceSyncStatus targetProfileVersions;

  bool get allAvailable =>
      selectedStars.state == StarTargetResourceSyncState.synced &&
      targetCycles.state == StarTargetResourceSyncState.synced &&
      activeTargetProfiles.state == StarTargetResourceSyncState.synced &&
      targetProfileVersions.state == StarTargetResourceSyncState.synced;

  static StarTargetMirrorSyncResult skipped() => StarTargetMirrorSyncResult(
    selectedStars: StarTargetResourceSyncStatus.skipped('selected_stars'),
    targetCycles: StarTargetResourceSyncStatus.skipped('target_cycles'),
    activeTargetProfiles: StarTargetResourceSyncStatus.skipped(
      'active_target_profiles',
    ),
    targetProfileVersions: StarTargetResourceSyncStatus.skipped(
      'target_profile_versions',
    ),
  );

  static StarTargetMirrorSyncResult unavailable(String reason) =>
      StarTargetMirrorSyncResult(
        selectedStars: StarTargetResourceSyncStatus.unavailable(
          'selected_stars',
          reason,
        ),
        targetCycles: StarTargetResourceSyncStatus.unavailable(
          'target_cycles',
          reason,
        ),
        activeTargetProfiles: StarTargetResourceSyncStatus.unavailable(
          'active_target_profiles',
          reason,
        ),
        targetProfileVersions: StarTargetResourceSyncStatus.unavailable(
          'target_profile_versions',
          reason,
        ),
      );
}

class StarTargetResourceSyncStatus {
  const StarTargetResourceSyncStatus({
    required this.resource,
    required this.state,
    required this.rowsWritten,
    required this.pagesPulled,
    required this.finalCursor,
    this.unavailableReason,
  });

  final String resource;
  final StarTargetResourceSyncState state;
  final int rowsWritten;
  final int pagesPulled;
  final String? finalCursor;
  final String? unavailableReason;

  bool get isAvailable => state == StarTargetResourceSyncState.synced;

  static StarTargetResourceSyncStatus synced({
    required String resource,
    required int rowsWritten,
    required int pagesPulled,
    required String? finalCursor,
  }) => StarTargetResourceSyncStatus(
    resource: resource,
    state: StarTargetResourceSyncState.synced,
    rowsWritten: rowsWritten,
    pagesPulled: pagesPulled,
    finalCursor: finalCursor,
  );

  static StarTargetResourceSyncStatus unavailable(
    String resource,
    String reason, {
    String? finalCursor,
  }) => StarTargetResourceSyncStatus(
    resource: resource,
    state: StarTargetResourceSyncState.unavailable,
    rowsWritten: 0,
    pagesPulled: 0,
    finalCursor: finalCursor,
    unavailableReason: reason,
  );

  static StarTargetResourceSyncStatus skipped(String resource) =>
      StarTargetResourceSyncStatus(
        resource: resource,
        state: StarTargetResourceSyncState.skipped,
        rowsWritten: 0,
        pagesPulled: 0,
        finalCursor: null,
      );
}

class SelectedStarShiftDecisionPage {
  const SelectedStarShiftDecisionPage({
    required this.decisions,
    required this.nextCursor,
    this.unavailableReason,
  });

  final List<SelectedStarShiftDecisionSyncRow> decisions;
  final String? nextCursor;
  final String? unavailableReason;

  bool get isUnavailable => unavailableReason != null;

  static SelectedStarShiftDecisionPage unavailable(String reason) =>
      SelectedStarShiftDecisionPage(
        decisions: const <SelectedStarShiftDecisionSyncRow>[],
        nextCursor: null,
        unavailableReason: reason,
      );
}

class TargetCycleSyncPage {
  const TargetCycleSyncPage({
    required this.cycles,
    required this.nextCursor,
    this.unavailableReason,
  });

  final List<TargetCycleSyncRow> cycles;
  final String? nextCursor;
  final String? unavailableReason;

  bool get isUnavailable => unavailableReason != null;

  static TargetCycleSyncPage unavailable(String reason) => TargetCycleSyncPage(
    cycles: const <TargetCycleSyncRow>[],
    nextCursor: null,
    unavailableReason: reason,
  );
}

class ActiveTargetProfileSyncPage {
  const ActiveTargetProfileSyncPage({
    required this.profiles,
    required this.nextCursor,
    this.unavailableReason,
  });

  final List<ActiveTargetProfileSyncRow> profiles;
  final String? nextCursor;
  final String? unavailableReason;

  bool get isUnavailable => unavailableReason != null;

  static ActiveTargetProfileSyncPage unavailable(String reason) =>
      ActiveTargetProfileSyncPage(
        profiles: const <ActiveTargetProfileSyncRow>[],
        nextCursor: null,
        unavailableReason: reason,
      );
}

class TargetProfileVersionSyncPage {
  const TargetProfileVersionSyncPage({
    required this.versions,
    required this.nextCursor,
    this.unavailableReason,
  });

  final List<TargetProfileVersionSyncRow> versions;
  final String? nextCursor;
  final String? unavailableReason;

  bool get isUnavailable => unavailableReason != null;

  static TargetProfileVersionSyncPage unavailable(String reason) =>
      TargetProfileVersionSyncPage(
        versions: const <TargetProfileVersionSyncRow>[],
        nextCursor: null,
        unavailableReason: reason,
      );
}

class SelectedStarShiftDecisionSyncRow {
  const SelectedStarShiftDecisionSyncRow({
    required this.recordKey,
    required this.isSelected,
    required this.isClear,
    this.servicePeriodKey,
    this.operatorId,
    this.locationId,
    this.restaurantId,
    this.decisionType,
    this.updatedAt,
  });

  final String recordKey;
  final bool isSelected;
  final bool isClear;
  final String? servicePeriodKey;
  final String? operatorId;
  final String? locationId;
  final String? restaurantId;
  final String? decisionType;
  final DateTime? updatedAt;

  factory SelectedStarShiftDecisionSyncRow.fromJson(Map<String, dynamic> json) {
    final type = _readString(json['decision_type'])?.toLowerCase();
    final selectedFlag = _readBool(
      json['is_selected'] ?? json['selected'] ?? json['selected_star'],
    );
    final servicePeriodKey =
        _readString(json['service_period_key']) ??
        _readString(json['service_period_id']) ??
        _readString(json['servicePeriodId']);
    final recordKey =
        _deriveStableRecordKey(
          businessDate: _readDateString(json['business_date']),
          servicePeriodKey: servicePeriodKey,
        ) ??
        _readString(json['record_key']) ??
        _deriveRecordKey(
          weekId: _readString(json['week_id']),
          dayLabel: _readString(json['day_label']),
          daypart: _readString(json['daypart']),
        );
    if (recordKey == null) {
      throw const FormatException(
        'Selected-star sync row was missing record_key.',
      );
    }
    final isSelected = switch (type) {
      'manager_selected' || 'admin_selected' => true,
      'manager_cleared' || 'admin_cleared' => false,
      _ => selectedFlag == true,
    };
    final isClear = switch (type) {
      'manager_cleared' || 'admin_cleared' => true,
      'manager_selected' || 'admin_selected' => false,
      _ => selectedFlag == false,
    };
    if (!isSelected && !isClear) {
      throw const FormatException(
        'Selected-star sync row did not declare selected or cleared state.',
      );
    }
    return SelectedStarShiftDecisionSyncRow(
      recordKey: recordKey,
      isSelected: isSelected,
      isClear: isClear,
      servicePeriodKey: servicePeriodKey,
      operatorId: _readString(json['operator_id']),
      locationId: _readString(json['location_id']),
      restaurantId: _readString(json['restaurant_id']),
      decisionType: type,
      updatedAt: _readDateTime(json['updated_at']),
    );
  }
}

class TargetCycleSyncRow {
  const TargetCycleSyncRow({
    required this.cycle,
    this.operatorId,
    this.locationId,
    this.updatedAt,
  });

  final TargetCycle cycle;
  final String? operatorId;
  final String? locationId;
  final DateTime? updatedAt;

  factory TargetCycleSyncRow.fromJson(Map<String, dynamic> json) {
    return TargetCycleSyncRow(
      operatorId: _readString(json['operator_id']),
      locationId: _readString(json['location_id']),
      updatedAt: _readDateTime(json['updated_at']),
      cycle: TargetCycle(
        cycleId: _requiredString(json, 'cycle_id'),
        restaurantId: _requiredString(json, 'restaurant_id'),
        source: TargetCycleSource.fromLabel(_requiredString(json, 'source')),
        effectiveStart: _requiredDateString(json, 'effective_start'),
        effectiveEnd: _requiredDateString(json, 'effective_end'),
        calibrationWindowStart: _requiredDateString(
          json,
          'calibration_window_start',
        ),
        calibrationWindowEnd: _requiredDateString(
          json,
          'calibration_window_end',
        ),
        targetCPLH: _requiredDouble(json, 'target_cplh'),
        targetSPLH: _requiredDouble(json, 'target_splh'),
        targetPPA: _requiredDouble(json, 'target_ppa'),
        fohWage: _requiredDouble(json, 'foh_wage'),
        bohWage: _requiredDouble(json, 'boh_wage'),
        opzFloorCPLH: _requiredDouble(json, 'opz_floor_cplh'),
        opzCeilingCPLH: _requiredDouble(json, 'opz_ceiling_cplh'),
        managerOverrideUsed: _readBool(json['manager_override_used']) ?? false,
        managerOverrideAt: _readIsoString(json['manager_override_at']),
        adminReplacedAt: _readIsoString(json['admin_replaced_at']),
        createdAt: _requiredIsoString(json, 'created_at'),
        deactivatedAt: _readIsoString(json['deactivated_at']),
        dayparts: _readTargetCycleDayparts(json),
      ),
    );
  }
}

class ActiveTargetProfileSyncRow {
  const ActiveTargetProfileSyncRow({
    required this.profile,
    this.operatorId,
    this.locationId,
    this.targetCycleId,
    this.targetProfileVersionId,
    this.updatedAt,
  });

  final ActiveTargetProfile profile;
  final String? operatorId;
  final String? locationId;
  final String? targetCycleId;
  final String? targetProfileVersionId;
  final DateTime? updatedAt;

  factory ActiveTargetProfileSyncRow.fromJson(Map<String, dynamic> json) {
    return ActiveTargetProfileSyncRow(
      operatorId: _readString(json['operator_id']),
      locationId: _readString(json['location_id']),
      targetCycleId: _readString(json['target_cycle_id']),
      targetProfileVersionId: _readString(json['target_profile_version_id']),
      updatedAt: _readDateTime(json['updated_at']),
      profile: ActiveTargetProfile(
        targetProfileId: _requiredString(json, 'target_profile_id'),
        restaurantId: _requiredString(json, 'restaurant_id'),
        targetCycleId: _readString(json['target_cycle_id']),
        targetProfileVersionId: _readString(json['target_profile_version_id']),
        sourceType: _requiredString(json, 'source_type'),
        targetCPLH: _requiredDouble(json, 'target_cplh'),
        targetSPLH: _requiredDouble(json, 'target_splh'),
        targetPPA: _requiredDouble(json, 'target_ppa'),
        fohWage: _requiredDouble(json, 'foh_wage'),
        bohWage: _requiredDouble(json, 'boh_wage'),
        opzFloorCPLH: _requiredDouble(json, 'opz_floor_cplh'),
        opzCeilingCPLH: _requiredDouble(json, 'opz_ceiling_cplh'),
        theoreticalFohLaborPct: _requiredDouble(
          json,
          'theoretical_foh_labor_pct',
        ),
        theoreticalBohLaborPct: _requiredDouble(
          json,
          'theoretical_boh_labor_pct',
        ),
        theoreticalLaborPct: _requiredDouble(json, 'theoretical_labor_pct'),
        builtAt: _requiredIsoString(json, 'built_at'),
        dayparts: _readActiveTargetProfileDayparts(json),
      ),
    );
  }
}

class TargetProfileVersionSyncRow {
  const TargetProfileVersionSyncRow({
    required this.version,
    this.operatorId,
    this.locationId,
    this.targetCycleId,
    this.updatedAt,
  });

  final TargetProfileVersion version;
  final String? operatorId;
  final String? locationId;
  final String? targetCycleId;
  final DateTime? updatedAt;

  factory TargetProfileVersionSyncRow.fromJson(Map<String, dynamic> json) {
    return TargetProfileVersionSyncRow(
      operatorId: _readString(json['operator_id']),
      locationId: _readString(json['location_id']),
      targetCycleId: _readString(json['target_cycle_id']),
      updatedAt: _readDateTime(json['updated_at']),
      version: TargetProfileVersion(
        targetProfileVersionId: _requiredString(
          json,
          'target_profile_version_id',
        ),
        targetProfileId: _requiredString(json, 'target_profile_id'),
        restaurantId: _requiredString(json, 'restaurant_id'),
        targetCycleId: _readString(json['target_cycle_id']),
        sourceType: _requiredString(json, 'source_type'),
        targetCPLH: _requiredDouble(json, 'target_cplh'),
        targetSPLH: _requiredDouble(json, 'target_splh'),
        targetPPA: _requiredDouble(json, 'target_ppa'),
        fohWage: _requiredDouble(json, 'foh_wage'),
        bohWage: _requiredDouble(json, 'boh_wage'),
        opzFloorCPLH: _requiredDouble(json, 'opz_floor_cplh'),
        opzCeilingCPLH: _requiredDouble(json, 'opz_ceiling_cplh'),
        theoreticalFohLaborPct: _requiredDouble(
          json,
          'theoretical_foh_labor_pct',
        ),
        theoreticalBohLaborPct: _requiredDouble(
          json,
          'theoretical_boh_labor_pct',
        ),
        theoreticalLaborPct: _requiredDouble(json, 'theoretical_labor_pct'),
        createdAt: _requiredIsoString(json, 'created_at'),
      ),
    );
  }
}

String? starTargetUnavailableReason(Map<String, Object?> body) {
  final available = _readBool(body['available']);
  final status = _readString(body['status'])?.toLowerCase();
  if (available == false ||
      status == 'unavailable' ||
      status == 'setup_required' ||
      status == 'not_configured') {
    return _readString(body['unavailable_reason']) ??
        _readString(body['setup_reason']) ??
        _readString(body['reason']) ??
        status ??
        'star_target_truth_unavailable';
  }
  return null;
}

String? _deriveStableRecordKey({
  required String? businessDate,
  required String? servicePeriodKey,
}) {
  if (businessDate == null || servicePeriodKey == null) return null;
  return '$businessDate|$servicePeriodKey';
}

String? _deriveRecordKey({
  required String? weekId,
  required String? dayLabel,
  required String? daypart,
}) {
  if (weekId == null || dayLabel == null || daypart == null) return null;
  return '$weekId|$dayLabel|$daypart';
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = _readString(json[key]);
  if (value == null) {
    throw FormatException('Star-target sync row was missing "$key".');
  }
  return value;
}

String _requiredDateString(Map<String, dynamic> json, String key) {
  final value = _readDateString(json[key]);
  if (value == null) {
    throw FormatException('Star-target sync row was missing "$key".');
  }
  return value;
}

String _requiredIsoString(Map<String, dynamic> json, String key) {
  final value = _readIsoString(json[key]);
  if (value == null) {
    throw FormatException('Star-target sync row was missing "$key".');
  }
  return value;
}

double _requiredDouble(Map<String, dynamic> json, String key) {
  final value = _readDouble(json[key]);
  if (value == null) {
    throw FormatException('Star-target sync row was missing "$key".');
  }
  return value;
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = _readInt(json[key]);
  if (value == null) {
    throw FormatException('Star-target sync row was missing "$key".');
  }
  return value;
}

List<TargetCycleDaypart> _readTargetCycleDayparts(Map<String, dynamic> json) {
  final rows =
      _readList(json['target_cycle_dayparts']) ?? _readList(json['dayparts']);
  if (rows == null) return const <TargetCycleDaypart>[];
  return <TargetCycleDaypart>[
    for (final row in rows)
      TargetCycleDaypart(
        servicePeriodId: _requiredServicePeriodId(row),
        targetCPLH: _requiredDouble(row, 'target_cplh'),
        targetSPLH: _requiredDouble(row, 'target_splh'),
        targetPPA: _requiredDouble(row, 'target_ppa'),
        opzFloorCPLH: _requiredDouble(row, 'opz_floor_cplh'),
        opzCeilingCPLH: _requiredDouble(row, 'opz_ceiling_cplh'),
        coverCount: _requiredInt(row, 'cover_count'),
        verdict: _readString(row['verdict']),
        verdictReason: _readString(row['verdict_reason']),
      ),
  ];
}

List<ActiveTargetProfileDaypart> _readActiveTargetProfileDayparts(
  Map<String, dynamic> json,
) {
  final rows =
      _readList(json['active_target_profile_dayparts']) ??
      _readList(json['dayparts']);
  if (rows == null) return const <ActiveTargetProfileDaypart>[];
  return <ActiveTargetProfileDaypart>[
    for (final row in rows)
      ActiveTargetProfileDaypart(
        servicePeriodId: _requiredServicePeriodId(row),
        daypartTargetCPLH: _requiredFirstDouble(row, const <String>[
          'daypart_target_cplh',
          'target_cplh',
        ]),
        daypartTargetSPLH: _requiredFirstDouble(row, const <String>[
          'daypart_target_splh',
          'target_splh',
        ]),
        daypartTargetPPA: _requiredFirstDouble(row, const <String>[
          'daypart_target_ppa',
          'target_ppa',
        ]),
        daypartOpzFloorCPLH: _requiredFirstDouble(row, const <String>[
          'daypart_opz_floor_cplh',
          'opz_floor_cplh',
        ]),
        daypartOpzCeilingCPLH: _requiredFirstDouble(row, const <String>[
          'daypart_opz_ceiling_cplh',
          'opz_ceiling_cplh',
        ]),
        verdict: _readString(row['verdict']),
        verdictReason: _readString(row['verdict_reason']),
      ),
  ];
}

double _requiredFirstDouble(Map<String, dynamic> json, List<String> keys) {
  for (final key in keys) {
    final value = _readDouble(json[key]);
    if (value != null) return value;
  }
  throw FormatException('Star-target sync row was missing "${keys.first}".');
}

String _requiredServicePeriodId(Map<String, dynamic> json) {
  final value =
      _readString(json['service_period_id']) ??
      _readString(json['service_period_key']) ??
      _readString(json['servicePeriodId']);
  if (value == null) {
    throw const FormatException(
      'Star-target sync daypart row was missing "service_period_id".',
    );
  }
  return value;
}

List<Map<String, dynamic>>? _readList(Object? value) {
  if (value == null) return null;
  if (value is! List) {
    throw const FormatException('Star-target dayparts value was not a list.');
  }
  return <Map<String, dynamic>>[for (final item in value) _dynamicMap(item)];
}

Map<String, dynamic> _dynamicMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }
  throw const FormatException('Star-target daypart row was not an object.');
}

String? _readString(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  return value.toString();
}

String? _readDateString(Object? value) {
  if (value == null) return null;
  if (value is DateTime) {
    return value.toUtc().toIso8601String().substring(0, 10);
  }
  final raw = _readString(value);
  if (raw == null) return null;
  return raw.length >= 10 ? raw.substring(0, 10) : raw;
}

String? _readIsoString(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc().toIso8601String();
  return _readString(value);
}

DateTime? _readDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  final raw = _readString(value);
  return raw == null ? null : DateTime.tryParse(raw)?.toUtc();
}

double? _readDouble(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int? _readInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num && value.roundToDouble() == value.toDouble()) {
    return value.toInt();
  }
  if (value is String) return int.tryParse(value);
  return null;
}

bool? _readBool(Object? value) {
  if (value == null) return null;
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') return true;
    if (normalized == 'false' || normalized == '0') return false;
  }
  return null;
}
