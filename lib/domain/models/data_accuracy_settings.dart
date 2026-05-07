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

/// Allowed values for the per-daypart covers source toggle.
enum CoversSource { vendor, forecast, manual }

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
      default:
        throw ArgumentError.value(
          value,
          'covers_source',
          'must be one of vendor / forecast / manual',
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

/// Daypart key. Matches the per-daypart column suffix on the SQL row
/// (`covers_source_lunch` / `covers_source_dinner` /
/// `covers_source_late_night`) and the manual-entry jsonb shape.
enum Daypart { lunch, dinner, lateNight }

extension DaypartWire on Daypart {
  String get wire {
    switch (this) {
      case Daypart.lunch:
        return 'lunch';
      case Daypart.dinner:
        return 'dinner';
      case Daypart.lateNight:
        return 'late_night';
    }
  }

  static Daypart fromWire(String value) {
    switch (value) {
      case 'lunch':
        return Daypart.lunch;
      case 'dinner':
        return Daypart.dinner;
      case 'late_night':
        return Daypart.lateNight;
      default:
        throw ArgumentError.value(
          value,
          'daypart',
          'must be one of lunch / dinner / late_night',
        );
    }
  }
}

class DataAccuracySettings {
  DataAccuracySettings({
    required this.settingId,
    required this.operatorId,
    required this.locationId,
    required this.coversSourceLunch,
    required this.coversSourceDinner,
    required this.coversSourceLateNight,
    required this.coversManualEntries,
    required this.wageSource,
    required this.createdAt,
    required this.updatedAt,
    this.walkInHandlingMode = DataAccuracyWalkInHandlingMode.reservationsOnly,
    this.walkInManualEntries = const <String, int>{},
    this.updatedBy,
  });

  final String settingId;
  final String operatorId;
  final String locationId;
  final CoversSource coversSourceLunch;
  final CoversSource coversSourceDinner;
  final CoversSource coversSourceLateNight;

  /// Sparse map keyed by ISO `YYYY-MM-DD` business_date string ->
  /// `{daypart_wire: covers_int}`. Only populated dates need entries;
  /// missing date + manual setting = aggregator returns null for that
  /// daypart (no ShiftRecord written).
  final Map<String, Map<String, int>> coversManualEntries;

  final WageSource wageSource;

  /// How server-side reservation demand should treat operator-entered
  /// walk-in counts when POS covers are unavailable.
  final DataAccuracyWalkInHandlingMode walkInHandlingMode;

  /// Sparse map keyed by ISO `YYYY-MM-DD` business_date string ->
  /// walk-in count for that day. Used when [walkInHandlingMode] is
  /// `walkInsAddedToReservations`.
  final Map<String, int> walkInManualEntries;

  final DateTime createdAt;
  final DateTime updatedAt;
  final String? updatedBy;

  CoversSource coversSourceFor(Daypart daypart) {
    switch (daypart) {
      case Daypart.lunch:
        return coversSourceLunch;
      case Daypart.dinner:
        return coversSourceDinner;
      case Daypart.lateNight:
        return coversSourceLateNight;
    }
  }

  /// Resolve the manual covers entry for a (business_date, daypart)
  /// pair. Returns null when the operator has not entered a value for
  /// that date+daypart — the aggregator interprets null as "do not
  /// write a ShiftRecord for this daypart" so the dashboard renders
  /// `MetricCardNotYetAvailable` instead of phantom zeroes.
  int? manualCoversFor(String businessDateIso, Daypart daypart) {
    final dayMap = coversManualEntries[businessDateIso];
    if (dayMap == null) return null;
    return dayMap[daypart.wire];
  }

  int? walkInCountFor(String businessDateIso) {
    return walkInManualEntries[businessDateIso];
  }

  /// Project from a `data_accuracy_settings` row produced by the
  /// PostgresExecutor (UUIDs cast to text in SELECT, jsonb returned
  /// as a map).
  factory DataAccuracySettings.fromRow(Map<String, Object?> row) {
    final settingId = row['setting_id'];
    final operatorId = row['operator_id'];
    final locationId = row['location_id'];
    final coversLunch = row['covers_source_lunch'];
    final coversDinner = row['covers_source_dinner'];
    final coversLateNight = row['covers_source_late_night'];
    final manualEntriesRaw = row['covers_manual_entries'];
    final wageSourceRaw = row['wage_source'];
    final walkInModeRaw = row['walk_in_handling_mode'];
    final walkInEntriesRaw = row['walk_in_manual_entries'];
    final createdAt = row['created_at'];
    final updatedAt = row['updated_at'];

    if (settingId is! String ||
        operatorId is! String ||
        locationId is! String ||
        coversLunch is! String ||
        coversDinner is! String ||
        coversLateNight is! String ||
        wageSourceRaw is! String ||
        createdAt is! DateTime ||
        updatedAt is! DateTime) {
      throw StateError(
        'data_accuracy_settings row malformed: missing required fields',
      );
    }

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
      coversSourceLunch: CoversSourceWire.fromWire(coversLunch),
      coversSourceDinner: CoversSourceWire.fromWire(coversDinner),
      coversSourceLateNight: CoversSourceWire.fromWire(coversLateNight),
      coversManualEntries: manualEntries,
      wageSource: WageSourceWire.fromWire(wageSourceRaw),
      walkInHandlingMode: walkInMode,
      walkInManualEntries: walkInManualEntries,
      createdAt: createdAt,
      updatedAt: updatedAt,
      updatedBy: updatedBy is String && updatedBy.isNotEmpty ? updatedBy : null,
    );
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
