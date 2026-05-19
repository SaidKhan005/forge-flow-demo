// Builds HistoryPatternRecords from real closed ShiftRecords.
//
// Replaces the manual hand-authored DemoData.historyPatternRecords list.
// The ingest path (Phase 3) will close shifts into SQLite; this builder
// reads those records back and produces the pattern signal that
// HistoryTeachingAnalyzer summarizes.
//
// Phase 7.55k.3: DaypartPatternSummaryBuilder now exists as a richer
// aggregate builder. This builder remains the active path for
// HistoryTeachingAnalyzer and LearnTeachingAnalyzer until 7.55k.5 /
// 7.55k.6 migrate them.

import '../domain/constants/app_defaults.dart';
import '../domain/models/restaurant_timing_config.dart';
import '../domain/models/service_period_definition.dart';
import '../domain/services/shift_boundary_resolver.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../models/history_pattern_record.dart';
import '../models/shift_record.dart';
import '../services/closed_timing_label_resolver.dart';
import '../services/labor_model.dart';

typedef HistoryPatternShiftCloseAuthorityResolver =
    ShiftCloseAuthority Function(ShiftRecord shift);

class HistoryPatternBuilder {
  HistoryPatternBuilder._();

  /// Builds one [HistoryPatternRecord] per eligible closed shift.
  ///
  /// Eligibility rules:
  /// - `shift` is eligible for closed-truth surfaces
  /// - `shift.normalizedLeverId != 'on_model'`
  /// - `shift.normalizedLeverId` exists in `LeverCards.all`
  ///
  /// [weekLabelsById] maps weekId → human-readable label (e.g. 'Mar 17').
  /// Falls back to the raw weekId when no label is found.
  static List<HistoryPatternRecord> fromClosedShifts(
    List<ShiftRecord> shifts,
    Map<String, String> weekLabelsById, {
    ClosedTimingLabelResolver? timingLabelResolver,
    List<ServicePeriodDefinition>? servicePeriodDefinitions,
    String? currentOperationalBusinessDate,
    HistoryPatternShiftCloseAuthorityResolver? shiftCloseAuthorityForRow,
  }) {
    final validLeverIds = LeverCards.all.map((l) => l.id).toSet();
    final configuredDefinitions = servicePeriodDefinitions?.isNotEmpty == true
        ? servicePeriodDefinitions
        : null;

    final result = <HistoryPatternRecord>[];
    for (final shift in shifts) {
      if (!_isEligibleClosedTruth(
        shift,
        currentOperationalBusinessDate: currentOperationalBusinessDate,
        shiftCloseAuthorityForRow: shiftCloseAuthorityForRow,
      )) {
        continue;
      }

      final leverId = shift.normalizedLeverId;
      if (leverId == 'on_model') continue;
      if (!validLeverIds.contains(leverId)) continue;

      result.add(
        HistoryPatternRecord(
          weekId: shift.weekId,
          weekLabel: weekLabelsById[shift.weekId] ?? shift.weekId,
          dayLabel: shift.dayLabel,
          daypart: _bucketKeyFor(
            shift,
            timingLabelResolver: timingLabelResolver,
            servicePeriodDefinitions: configuredDefinitions,
          ),
          servicePeriodLabel: _servicePeriodLabelFor(
            shift,
            timingLabelResolver: timingLabelResolver,
            servicePeriodDefinitions: configuredDefinitions,
          ),
          servicePeriodSortOrder: _servicePeriodSortOrderFor(
            shift,
            timingLabelResolver: timingLabelResolver,
            servicePeriodDefinitions: configuredDefinitions,
          ),
          leverId: leverId,
          isBenchmark: LaborModel.isFavorableLever(leverId),
        ),
      );
    }
    return result;
  }

  static String _bucketKeyFor(
    ShiftRecord shift, {
    ClosedTimingLabelResolver? timingLabelResolver,
    List<ServicePeriodDefinition>? servicePeriodDefinitions,
  }) {
    if (timingLabelResolver?.hasSavedTimingIdentity(shift) ?? false) {
      return timingLabelResolver!.bucketKeyFor(shift);
    }
    final servicePeriodKey = shift.servicePeriodKey?.trim();
    if (_hasSavedTimingIdentity(shift)) {
      return servicePeriodKey!;
    }
    if (servicePeriodDefinitions != null &&
        servicePeriodKey != null &&
        servicePeriodKey.isNotEmpty) {
      return servicePeriodKey;
    }
    return shift.daypart;
  }

  static String? _servicePeriodLabelFor(
    ShiftRecord shift, {
    ClosedTimingLabelResolver? timingLabelResolver,
    List<ServicePeriodDefinition>? servicePeriodDefinitions,
  }) {
    final snapshot = timingLabelResolver?.snapshotFor(shift);
    final snapshotLabel = snapshot?.label.trim();
    if (snapshotLabel != null && snapshotLabel.isNotEmpty) {
      return snapshot!.label;
    }

    final servicePeriodKey = shift.servicePeriodKey?.trim();
    if (servicePeriodDefinitions != null &&
        servicePeriodKey != null &&
        servicePeriodKey.isNotEmpty) {
      return ServicePeriodDefinitionResolver.labelForId(
        servicePeriodDefinitions,
        servicePeriodKey,
      );
    }
    return timingLabelResolver?.labelFor(shift);
  }

  static int? _servicePeriodSortOrderFor(
    ShiftRecord shift, {
    ClosedTimingLabelResolver? timingLabelResolver,
    List<ServicePeriodDefinition>? servicePeriodDefinitions,
  }) {
    final savedSortOrder = timingLabelResolver?.sortOrderFor(shift);
    if (savedSortOrder != null) return savedSortOrder;

    final servicePeriodKey = shift.servicePeriodKey?.trim();
    if (servicePeriodDefinitions != null &&
        servicePeriodKey != null &&
        servicePeriodKey.isNotEmpty) {
      return ServicePeriodDefinitionResolver.sortIndex(
        servicePeriodDefinitions,
        servicePeriodKey,
      );
    }
    return null;
  }

  static bool _isEligibleClosedTruth(
    ShiftRecord shift, {
    required String? currentOperationalBusinessDate,
    required HistoryPatternShiftCloseAuthorityResolver?
    shiftCloseAuthorityForRow,
  }) {
    if (currentOperationalBusinessDate == null) return shift.isClosed;
    return ShiftBoundaryResolver.isEligibleForClosedTruth(
      rowStatus: shift.status,
      shiftCloseAuthority:
          shiftCloseAuthorityForRow?.call(shift) ??
          ShiftCloseAuthority.appLocalCutoffFallback,
      rowBusinessDate: shift.businessDate,
      currentOperationalBusinessDate: currentOperationalBusinessDate,
    );
  }

  static bool _hasSavedTimingIdentity(ShiftRecord shift) {
    final versionId = shift.businessTimingProfileVersionId?.trim();
    final periodKey = shift.servicePeriodKey?.trim();
    return versionId != null &&
        versionId.isNotEmpty &&
        periodKey != null &&
        periodKey.isNotEmpty;
  }
}
