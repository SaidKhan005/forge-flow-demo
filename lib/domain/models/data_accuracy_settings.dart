/// Phase 8 spine-bridge Lane .A — operator-controlled data accuracy
/// overrides per (operator, location).
///
/// Authority: docs/contracts/data_accuracy_settings_contract.md
/// "Schema" section. Mirrors the `public.data_accuracy_settings` row.
///
/// Three operator-controlled seams collapse onto this model:
///
///   1. Covers source per daypart — `vendor` (default), `forecast`, or
///      `manual`. When `manual`, sparse `manualEntries` jsonb keyed by
///      `business_date -> {daypart -> covers}` carries the per-date
///      values.
///   2. Wage source binary — `vendor` (default; use labor vendor dollars
///      when exposed) or `manual_mix` (always use wage_role_rows).
///
/// Polling cadence is intentionally NOT here — F&F admin controls it
/// via `forge_flow_polling_tier_assignment` (see
/// [ForgeFlowPollingTierAssignment]).
library;

/// Allowed values for the per-service-period covers source toggle.
enum CoversSource { vendor, forecast, manual, reservationPlusWalkin }

extension CoversSourceWire on CoversSource {
  /// Wire encoding matches the SQL CHECK constraint values.
  String get wire {
    switch (this) {
      case CoversSource.vendor:
        return 'vendor';
      case CoversSource.forecast:
        return 'forecast';
      case CoversSource.manual:
        return 'manual';
      case CoversSource.reservationPlusWalkin:
        return 'reservation_plus_walkin';
    }
  }

  static CoversSource fromWire(String value) {
    switch (value) {
      case 'vendor':
        return CoversSource.vendor;
      case 'forecast':
        return CoversSource.forecast;
      case 'manual':
        return CoversSource.manual;
      case 'reservation_plus_walkin':
        return CoversSource.reservationPlusWalkin;
      default:
        throw ArgumentError.value(
          value,
          'covers_source',
          'must be one of vendor / forecast / manual / '
              'reservation_plus_walkin',
        );
    }
  }
}

/// Wage source toggle — operator-facing binary on top of the 4-way
/// internal vendor wage class (resolved by LaborWageSourceClass; out
/// of scope for this slice).
enum WageSource { vendor, manualMix }

extension WageSourceWire on WageSource {
  String get wire {
    switch (this) {
      case WageSource.vendor:
        return 'vendor';
      case WageSource.manualMix:
        return 'manual_mix';
    }
  }

  static WageSource fromWire(String value) {
    switch (value) {
      case 'vendor':
        return WageSource.vendor;
      case 'manual_mix':
        return WageSource.manualMix;
      default:
        throw ArgumentError.value(
          value,
          'wage_source',
          'must be one of vendor / manual_mix',
        );
    }
  }
}

/// Reservation demand / walk-in handling toggle. The operator chooses
/// how reservation covers should be treated when the POS does not
/// expose covers directly.
enum DataAccuracyWalkInHandlingMode {
  reservationsOnly,
  walkInsAddedToReservations,
  walkInsTrackedSeparately,
}

extension DataAccuracyWalkInHandlingModeWire on DataAccuracyWalkInHandlingMode {
  String get wire {
    switch (this) {
      case DataAccuracyWalkInHandlingMode.reservationsOnly:
        return 'reservations_only';
      case DataAccuracyWalkInHandlingMode.walkInsAddedToReservations:
        return 'walk_ins_added_to_reservations';
      case DataAccuracyWalkInHandlingMode.walkInsTrackedSeparately:
        return 'walk_ins_tracked_separately';
    }
  }

  static DataAccuracyWalkInHandlingMode fromWire(String value) {
    switch (value) {
      case 'reservations_only':
        return DataAccuracyWalkInHandlingMode.reservationsOnly;
      case 'walk_ins_added_to_reservations':
        return DataAccuracyWalkInHandlingMode.walkInsAddedToReservations;
      case 'walk_ins_tracked_separately':
        return DataAccuracyWalkInHandlingMode.walkInsTrackedSeparately;
      default:
        throw ArgumentError.value(
          value,
          'walk_in_handling_mode',
          'must be one of reservations_only / '
              'walk_ins_added_to_reservations / '
              'walk_ins_tracked_separately',
        );
    }
  }
}

/// Service-period key default when an operator has no per-period
/// covers-source row configured. The keyed
/// `data_accuracy_service_period_settings` table is the source of
/// truth for per-period covers source; absence resolves to `vendor`
/// (the SQL default), so a brand-new operator behaves exactly as the
/// pre-de-hardcode 'vendor' default did.
const CoversSource kDefaultCoversSource = CoversSource.vendor;

class DataAccuracySettingSource {
  const DataAccuracySettingSource({
    required this.scopeType,
    required this.sourceKind,
    this.scopeId,
    this.settingId,
    this.overrideId,
  });

  final String scopeType;
  final String sourceKind;
  final String? scopeId;
  final String? settingId;
  final String? overrideId;

  String? get operatorFacingLabel {
    if (sourceKind == 'default' || scopeType == 'default') return null;
    return label;
  }

  String get label {
    switch (sourceKind) {
      case 'default':
        return 'Default';
      case 'service_period_setting':
      case 'base_setting':
        return 'Location setting';
    }
    switch (scopeType) {
      case 'business':
        return 'Business';
      case 'org_unit':
        return 'Org unit';
      case 'location':
        return 'Location';
      case 'default':
        return 'Default';
      default:
        return 'Configured setting';
    }
  }

  static DataAccuracySettingSource? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final scopeType = _string(raw['scope_type']);
    final sourceKind = _string(raw['source_kind']);
    if (scopeType == null || sourceKind == null) return null;
    return DataAccuracySettingSource(
      scopeType: scopeType,
      sourceKind: sourceKind,
      scopeId: _string(raw['scope_id']),
      settingId: _string(raw['setting_id']),
      overrideId: _string(raw['override_id']),
    );
  }

  static String? _string(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class DataAccuracySettings {
  DataAccuracySettings({
    required this.settingId,
    required this.operatorId,
    required this.locationId,
    required this.coversSourcePerServicePeriod,
    required this.coversManualEntries,
    required this.wageSource,
    required this.createdAt,
    required this.updatedAt,
    this.coversSourcePerServicePeriodSources =
        const <String, DataAccuracySettingSource>{},
    this.wageSourceSource,
    this.walkInHandlingModeSource,
    this.walkInHandlingMode = DataAccuracyWalkInHandlingMode.reservationsOnly,
    this.walkInManualEntries = const <String, int>{},
    this.updatedBy,
  });

  final String settingId;
  final String operatorId;
  final String locationId;

  /// Covers source keyed by the operator-configured service-period id
  /// (the same stable `service_period_key` the keyed
  /// `data_accuracy_service_period_settings` table and the timing
  /// config use: `lunch`, `dinner`, `late_night`, `breakfast`,
  /// `brunch`, or any custom period the kitchen runs). Replaces the
  /// hardcoded 3-daypart `coversSourceLunch` / `_Dinner` / `_LateNight`
  /// fields so an operator with any number of periods works end to end
  /// (Gap 27/36). Periods absent from this map resolve to
  /// [kDefaultCoversSource] via [coversSourceFor].
  final Map<String, CoversSource> coversSourcePerServicePeriod;

  /// Server-emitted winning source for each configured covers source.
  /// Missing keys mean older proxy responses or no configured source
  /// metadata; callers must not guess a label in that case.
  final Map<String, DataAccuracySettingSource>
  coversSourcePerServicePeriodSources;

  /// Sparse map keyed by ISO `YYYY-MM-DD` business_date string ->
  /// `{service_period_id: covers_int}`. Only populated dates need
  /// entries; missing date + manual setting = aggregator returns null
  /// for that period (no ShiftRecord written).
  final Map<String, Map<String, int>> coversManualEntries;

  final WageSource wageSource;
  final DataAccuracySettingSource? wageSourceSource;

  /// How server-side reservation demand should treat operator-entered
  /// walk-in counts when POS covers are unavailable.
  final DataAccuracyWalkInHandlingMode walkInHandlingMode;
  final DataAccuracySettingSource? walkInHandlingModeSource;

  /// Sparse map keyed by ISO `YYYY-MM-DD` business_date string ->
  /// walk-in count for that day. Used when [walkInHandlingMode] is
  /// `walkInsAddedToReservations`.
  final Map<String, int> walkInManualEntries;

  final DateTime createdAt;
  final DateTime updatedAt;
  final String? updatedBy;

  /// Resolve the covers source for an operator-configured service
  /// period id. Periods the operator has not explicitly configured
  /// resolve to [kDefaultCoversSource] (`vendor`), matching the SQL
  /// keyed-table default — so an operator with 4 periods who has only
  /// touched 2 still gets honest `vendor` defaults for the other 2.
  CoversSource coversSourceFor(String servicePeriodId) {
    return coversSourcePerServicePeriod[servicePeriodId] ??
        kDefaultCoversSource;
  }

  DataAccuracySettingSource? coversSourceSourceFor(String servicePeriodId) {
    return coversSourcePerServicePeriodSources[servicePeriodId];
  }

  /// Resolve the manual covers entry for a (business_date,
  /// service_period_id) pair. Returns null when the operator has not
  /// entered a value for that date+period — the aggregator interprets
  /// null as "do not write a ShiftRecord for this period" so the
  /// dashboard renders `MetricCardNotYetAvailable` instead of phantom
  /// zeroes.
  int? manualCoversFor(String businessDateIso, String servicePeriodId) {
    final dayMap = coversManualEntries[businessDateIso];
    if (dayMap == null) return null;
    return dayMap[servicePeriodId];
  }

  int? walkInCountFor(String businessDateIso) {
    return walkInManualEntries[businessDateIso];
  }

  /// Project from a `data_accuracy_settings` row produced by the
  /// PostgresExecutor (UUIDs cast to text in SELECT, jsonb returned
  /// as a map).
  ///
  /// Per-period covers source is sourced from the keyed
  /// `data_accuracy_service_period_settings` table. Callers SELECT the
  /// effective keyed rows and pass them as a
  /// `covers_source_per_service_period` map (`{service_period_id:
  /// covers_source_wire}`). The keyed/jsonb path is the sole source;
  /// a period absent from the map resolves to [kDefaultCoversSource]
  /// via [coversSourceFor]. (The deprecated
  /// `covers_source_lunch` / `_dinner` / `_late_night` columns are no
  /// longer consulted here — the keyed path is authoritative.)
  factory DataAccuracySettings.fromRow(Map<String, Object?> row) {
    final settingId = row['setting_id'];
    final operatorId = row['operator_id'];
    final locationId = row['location_id'];
    final manualEntriesRaw = row['covers_manual_entries'];
    final wageSourceRaw = row['wage_source'];
    final walkInModeRaw = row['walk_in_handling_mode'];
    final walkInEntriesRaw = row['walk_in_manual_entries'];
    final createdAt = row['created_at'];
    final updatedAt = row['updated_at'];

    if (settingId is! String ||
        operatorId is! String ||
        locationId is! String ||
        wageSourceRaw is! String ||
        createdAt is! DateTime ||
        updatedAt is! DateTime) {
      throw StateError(
        'data_accuracy_settings row malformed: missing required fields',
      );
    }

    final perPeriod = _parseCoversSourcePerServicePeriod(
      row['covers_source_per_service_period'],
    );
    final perPeriodSources = _parseSourcePerServicePeriod(
      row['covers_source_per_service_period_source'],
    );

    final manualEntries = _parseManualEntries(manualEntriesRaw);
    final walkInMode = walkInModeRaw is String
        ? DataAccuracyWalkInHandlingModeWire.fromWire(walkInModeRaw)
        : DataAccuracyWalkInHandlingMode.reservationsOnly;
    final walkInManualEntries = _parseWalkInEntries(walkInEntriesRaw);
    final updatedBy = row['updated_by'];

    return DataAccuracySettings(
      settingId: settingId,
      operatorId: operatorId,
      locationId: locationId,
      coversSourcePerServicePeriod: perPeriod,
      coversSourcePerServicePeriodSources: perPeriodSources,
      coversManualEntries: manualEntries,
      wageSource: WageSourceWire.fromWire(wageSourceRaw),
      wageSourceSource: DataAccuracySettingSource.fromMap(
        row['wage_source_source'],
      ),
      walkInHandlingMode: walkInMode,
      walkInHandlingModeSource: DataAccuracySettingSource.fromMap(
        row['walk_in_handling_mode_source'],
      ),
      walkInManualEntries: walkInManualEntries,
      createdAt: createdAt,
      updatedAt: updatedAt,
      updatedBy: updatedBy is String && updatedBy.isNotEmpty ? updatedBy : null,
    );
  }

  /// Parse the keyed `{service_period_id: covers_source_wire}` map a
  /// caller projects from `data_accuracy_service_period_settings`.
  /// Unknown / malformed values are skipped (they fall through to the
  /// vendor default rather than throwing, so one bad row never blocks
  /// a whole settings load).
  static Map<String, CoversSource> _parseCoversSourcePerServicePeriod(
    Object? raw,
  ) {
    final out = <String, CoversSource>{};
    if (raw is! Map) return out;
    raw.forEach((key, value) {
      if (key is! String || key.isEmpty) return;
      if (value is! String || value.isEmpty) return;
      try {
        out[key] = CoversSourceWire.fromWire(value);
      } on ArgumentError {
        // Unknown values fall through to the vendor default rather than
        // crashing a whole settings load.
      }
    });
    return out;
  }

  static Map<String, DataAccuracySettingSource> _parseSourcePerServicePeriod(
    Object? raw,
  ) {
    final out = <String, DataAccuracySettingSource>{};
    if (raw is! Map) return out;
    raw.forEach((key, value) {
      if (key is! String || key.isEmpty) return;
      final source = DataAccuracySettingSource.fromMap(value);
      if (source == null) return;
      out[key] = source;
    });
    return out;
  }

  static Map<String, Map<String, int>> _parseManualEntries(Object? raw) {
    if (raw == null) return <String, Map<String, int>>{};
    if (raw is! Map) {
      throw StateError(
        'covers_manual_entries jsonb projected as ${raw.runtimeType}, '
        'expected Map',
      );
    }
    final out = <String, Map<String, int>>{};
    raw.forEach((key, value) {
      if (key is! String) return;
      if (value is! Map) return;
      final inner = <String, int>{};
      value.forEach((dpKey, dpValue) {
        if (dpKey is! String) return;
        if (dpValue is int) {
          inner[dpKey] = dpValue;
        } else if (dpValue is num) {
          inner[dpKey] = dpValue.toInt();
        }
      });
      out[key] = inner;
    });
    return out;
  }

  static Map<String, int> _parseWalkInEntries(Object? raw) {
    if (raw == null) return <String, int>{};
    if (raw is! Map) {
      throw StateError(
        'walk_in_manual_entries jsonb projected as ${raw.runtimeType}, '
        'expected Map',
      );
    }
    final out = <String, int>{};
    raw.forEach((key, value) {
      if (key is! String) return;
      if (value is int) {
        out[key] = value;
      } else if (value is num) {
        out[key] = value.toInt();
      }
    });
    return out;
  }
}
