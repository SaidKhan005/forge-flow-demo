// Canonical fact post-commit projection seam.
//
// This service runs after a canonical fact batch has committed. It deliberately
// does not own adapter dispatch, worker claiming, mobile sync, or formula
// logic. Completed service periods route through the existing closed
// aggregator + ShiftRecord writer; open/current periods route through the
// existing OpenShiftSnapshotProjector.

import '../../domain/models/aggregator_provenance_context.dart';
import '../../domain/models/demand_forecast_context.dart';
import '../../domain/models/service_period_definition.dart';
import '../../domain/models/shift_fact.dart';
import '../../domain/models/target_snapshot.dart';
import '../../domain/services/shift_fact_builder.dart';
import '../../infrastructure/persistence/postgres/postgres_shift_record_writer.dart';
import 'canonical_fact_to_closed_shift_input.dart';
import 'integration_adapter_common.dart';
import 'open_shift_snapshot_projector.dart';

abstract class ClosedShiftPostCommitAggregator {
  Future<AggregatorResult?> aggregate(CanonicalFactCommittedPeriod period);
}

abstract class ClosedShiftPostCommitWriter {
  Future<void> write({
    required String operatorId,
    required String locationId,
    required ShiftFact shiftFact,
    required AggregatorProvenanceContext provenance,
  });
}

abstract class ClosedShiftTargetSnapshotResolver {
  Future<TargetSnapshot> resolveTargetSnapshot({
    required CanonicalFactPostCommitInput input,
    required CanonicalFactCommittedPeriod period,
    required AggregatorResult aggregateResult,
  });
}

abstract class OpenShiftPostCommitProjector {
  Future<OpenShiftProjectionResult> project({
    required CanonicalFactPostCommitInput input,
    required Iterable<CanonicalFactCommittedPeriod> periods,
  });
}

class ExistingClosedShiftPostCommitAggregator
    implements ClosedShiftPostCommitAggregator {
  const ExistingClosedShiftPostCommitAggregator(this.aggregator);

  final CanonicalFactToClosedShiftInputAggregator aggregator;

  @override
  Future<AggregatorResult?> aggregate(CanonicalFactCommittedPeriod period) {
    return aggregator.aggregate(
      operatorId: period.operatorId,
      locationId: period.locationId,
      restaurantId: period.restaurantId,
      businessDate: period.businessDateAsDateTime,
      weekId: period.weekId,
      dayLabel: period.dayLabel,
      servicePeriodId: period.servicePeriodKey,
      periodDefinition: period.servicePeriodDefinition,
      businessTimingProfileId: period.businessTimingProfileId,
      businessTimingProfileVersionId: period.businessTimingProfileVersionId,
      forecastContext: period.forecastContext,
      walkInOverride: period.walkInOverride,
    );
  }
}

class ExistingClosedShiftPostCommitWriter
    implements ClosedShiftPostCommitWriter {
  const ExistingClosedShiftPostCommitWriter(this.writer);

  final PostgresShiftRecordWriter writer;

  @override
  Future<void> write({
    required String operatorId,
    required String locationId,
    required ShiftFact shiftFact,
    required AggregatorProvenanceContext provenance,
  }) {
    return writer.writeShiftRecord(
      operatorId: operatorId,
      locationId: locationId,
      shiftFact: shiftFact,
      provenance: provenance,
    );
  }
}

class ExistingOpenShiftPostCommitProjector
    implements OpenShiftPostCommitProjector {
  const ExistingOpenShiftPostCommitProjector(this.projector);

  final OpenShiftSnapshotProjector projector;

  @override
  Future<OpenShiftProjectionResult> project({
    required CanonicalFactPostCommitInput input,
    required Iterable<CanonicalFactCommittedPeriod> periods,
  }) {
    return projector.projectFactMaps(
      operatorId: input.operatorId,
      locationId: input.locationId,
      facts: input.openCurrentFactMaps,
      businessDate: _singleBusinessDateOrNull(periods),
      userId: input.userId,
    );
  }
}

class CanonicalFactPostCommitProjector {
  const CanonicalFactPostCommitProjector({
    required ClosedShiftPostCommitAggregator closedAggregator,
    required ClosedShiftTargetSnapshotResolver targetSnapshotResolver,
    required ClosedShiftPostCommitWriter closedWriter,
    required OpenShiftPostCommitProjector openProjector,
  }) : _closedAggregator = closedAggregator,
       _targetSnapshotResolver = targetSnapshotResolver,
       _closedWriter = closedWriter,
       _openProjector = openProjector;

  final ClosedShiftPostCommitAggregator _closedAggregator;
  final ClosedShiftTargetSnapshotResolver _targetSnapshotResolver;
  final ClosedShiftPostCommitWriter _closedWriter;
  final OpenShiftPostCommitProjector _openProjector;

  Future<CanonicalFactPostCommitProjectionResult> project(
    CanonicalFactPostCommitInput input,
  ) async {
    input.validate();
    final periods = _dedupePeriods(input.changedPeriods);
    final completed = periods
        .where((period) => period.state == CanonicalFactPeriodState.completed)
        .toList(growable: false);
    final openCurrent = periods
        .where((period) => period.state == CanonicalFactPeriodState.openCurrent)
        .toList(growable: false);

    var closedProjected = 0;
    var closedUnavailable = 0;
    final closedKeys = <String>[];
    for (final period in completed) {
      final aggregateResult = await _closedAggregator.aggregate(period);
      if (aggregateResult == null) {
        closedUnavailable += 1;
        continue;
      }
      final targetSnapshot = await _targetSnapshotResolver
          .resolveTargetSnapshot(
            input: input,
            period: period,
            aggregateResult: aggregateResult,
          );
      final shiftFact = ShiftFactBuilder.fromClosedShiftInput(
        aggregateResult.input,
        targetSnapshot,
      );
      await _closedWriter.write(
        operatorId: input.operatorId,
        locationId: input.locationId,
        shiftFact: shiftFact,
        provenance: aggregateResult.provenance,
      );
      closedProjected += 1;
      closedKeys.add(period.periodIdentity);
    }

    OpenShiftProjectionResult? openResult;
    if (openCurrent.isNotEmpty) {
      openResult = await _openProjector.project(
        input: input,
        periods: openCurrent,
      );
    }

    return CanonicalFactPostCommitProjectionResult(
      operatorId: input.operatorId,
      locationId: input.locationId,
      integrationCategory: input.integrationCategory,
      vendorId: input.vendorId,
      connectionId: input.connectionId,
      completedPeriodsSeen: completed.length,
      openCurrentPeriodsSeen: openCurrent.length,
      closedShiftRecordsProjected: closedProjected,
      closedPeriodsUnavailable: closedUnavailable,
      openSnapshotsUpserted: openResult?.snapshotsUpserted ?? 0,
      openServicePeriodSnapshotsUpserted:
          openResult?.servicePeriodSnapshotsUpserted ?? 0,
      openProjectionUnavailable: openResult?.isUnavailable ?? false,
      openProjectionReason: openResult?.reason,
      closedPeriodKeys: List<String>.unmodifiable(closedKeys),
      openPeriodKeys: List<String>.unmodifiable(
        openCurrent.map((period) => period.periodIdentity),
      ),
    );
  }

  static List<CanonicalFactCommittedPeriod> _dedupePeriods(
    Iterable<CanonicalFactCommittedPeriod> periods,
  ) {
    final seen = <String>{};
    final out = <CanonicalFactCommittedPeriod>[];
    for (final period in periods) {
      if (seen.add(period.periodIdentity)) out.add(period);
    }
    return List<CanonicalFactCommittedPeriod>.unmodifiable(out);
  }
}

class CanonicalFactPostCommitInput {
  const CanonicalFactPostCommitInput({
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.integrationCategory,
    required this.vendorId,
    required this.connectionId,
    required this.changedPeriods,
    this.openCurrentFactMaps = const <Map<String, Object?>>[],
    this.userId,
  });

  final String operatorId;
  final String locationId;
  final String restaurantId;
  final IntegrationCategory integrationCategory;
  final String vendorId;
  final String connectionId;
  final List<CanonicalFactCommittedPeriod> changedPeriods;

  /// Canonical fact dictionaries that are explicitly safe to feed into the
  /// provisional open/current projector. Completed-period facts intentionally
  /// have no field on this input; closed projection re-reads canonical truth
  /// through the closed aggregator by period identity.
  final List<Map<String, Object?>> openCurrentFactMaps;
  final String? userId;

  void validate() {
    _requireNonBlank(operatorId, 'operatorId');
    _requireNonBlank(locationId, 'locationId');
    _requireNonBlank(restaurantId, 'restaurantId');
    _requireNonBlank(vendorId, 'vendorId');
    _requireNonBlank(connectionId, 'connectionId');
    if (changedPeriods.isEmpty) {
      throw ArgumentError.value(
        changedPeriods,
        'changedPeriods',
        'must name at least one changed service period',
      );
    }
    for (final period in changedPeriods) {
      if (period.operatorId != operatorId ||
          period.locationId != locationId ||
          period.restaurantId != restaurantId) {
        throw ArgumentError(
          'changed period scope must match the post-commit input scope',
        );
      }
    }
  }
}

class CanonicalFactCommittedPeriod {
  const CanonicalFactCommittedPeriod({
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.businessDate,
    required this.weekId,
    required this.dayLabel,
    required this.servicePeriodKey,
    required this.servicePeriodDefinition,
    required this.state,
    this.businessTimingProfileId,
    this.businessTimingProfileVersionId,
    this.forecastContext,
    this.walkInOverride,
  });

  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String businessDate;
  final String weekId;
  final String dayLabel;
  final String servicePeriodKey;
  final ServicePeriodDefinition servicePeriodDefinition;
  final CanonicalFactPeriodState state;
  final String? businessTimingProfileId;
  final String? businessTimingProfileVersionId;
  final DemandForecastContext? forecastContext;
  final ReservationWalkInOverride? walkInOverride;

  DateTime get businessDateAsDateTime => DateTime.parse(businessDate);

  String get periodIdentity =>
      '$operatorId|$locationId|$businessDate|${state.wire}|$servicePeriodKey';
}

enum CanonicalFactPeriodState {
  completed('completed'),
  openCurrent('open_current');

  const CanonicalFactPeriodState(this.wire);
  final String wire;
}

class CanonicalFactPostCommitProjectionResult {
  const CanonicalFactPostCommitProjectionResult({
    required this.operatorId,
    required this.locationId,
    required this.integrationCategory,
    required this.vendorId,
    required this.connectionId,
    required this.completedPeriodsSeen,
    required this.openCurrentPeriodsSeen,
    required this.closedShiftRecordsProjected,
    required this.closedPeriodsUnavailable,
    required this.openSnapshotsUpserted,
    required this.openServicePeriodSnapshotsUpserted,
    required this.openProjectionUnavailable,
    required this.openProjectionReason,
    required this.closedPeriodKeys,
    required this.openPeriodKeys,
  });

  final String operatorId;
  final String locationId;
  final IntegrationCategory integrationCategory;
  final String vendorId;
  final String connectionId;
  final int completedPeriodsSeen;
  final int openCurrentPeriodsSeen;
  final int closedShiftRecordsProjected;
  final int closedPeriodsUnavailable;
  final int openSnapshotsUpserted;
  final int openServicePeriodSnapshotsUpserted;
  final bool openProjectionUnavailable;
  final String? openProjectionReason;
  final List<String> closedPeriodKeys;
  final List<String> openPeriodKeys;
}

void _requireNonBlank(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'must be non-blank');
  }
}

String? _singleBusinessDateOrNull(
  Iterable<CanonicalFactCommittedPeriod> periods,
) {
  String? found;
  for (final period in periods) {
    if (found == null) {
      found = period.businessDate;
    } else if (found != period.businessDate) {
      return null;
    }
  }
  return found;
}
