import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/aggregator_provenance_context.dart';
import 'package:forge_and_flow/domain/models/closed_shift_input.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/models/shift_fact.dart';
import 'package:forge_and_flow/domain/models/target_snapshot.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_post_commit_projector.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_to_closed_shift_input.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/open_shift_snapshot_projector.dart';

const String _operatorId = '11111111-1111-1111-1111-111111111111';
const String _locationId = '22222222-2222-2222-2222-222222222222';
const String _restaurantId = 'restaurant-1';
const String _profileId = '33333333-3333-3333-3333-333333333333';

const TargetSnapshot _currentTarget = TargetSnapshot(
  restaurantId: _restaurantId,
  targetProfileId: 'target-profile-current',
  targetProfileVersionId: 'tpv_current',
  sourceType: 'cycle_recommended',
  targetCPLH: 4,
  targetSPLH: 100,
  targetPPA: 40,
  fohWage: 20,
  bohWage: 24,
  opzFloorCPLH: 3,
  opzCeilingCPLH: 5,
  theoreticalFohLaborPct: 12.5,
  theoreticalBohLaborPct: 24,
  theoreticalLaborPct: 36.5,
);

void main() {
  group('CanonicalFactPostCommitProjector', () {
    test(
      'completed periods invoke closed aggregator, builder, and writer',
      () async {
        final aggregateResult = _aggregateResult();
        final aggregator = _FakeClosedAggregator(<String, AggregatorResult?>{
          _period().periodIdentity: aggregateResult,
        });
        final writer = _FakeClosedWriter();
        final targetResolver = _FakeTargetResolver(_currentTarget);
        final open = _FakeOpenProjector();
        final projector = _projector(
          aggregator: aggregator,
          writer: writer,
          targetResolver: targetResolver,
          open: open,
        );

        final result = await projector.project(
          _input(periods: <CanonicalFactCommittedPeriod>[_period()]),
        );

        expect(result.completedPeriodsSeen, 1);
        expect(result.closedShiftRecordsProjected, 1);
        expect(result.closedPeriodsUnavailable, 0);
        expect(result.openSnapshotsUpserted, 0);
        expect(aggregator.calls, hasLength(1));
        expect(targetResolver.calls, hasLength(1));
        expect(writer.rows, hasLength(1));
        expect(open.calls, isEmpty);

        final row = writer.rows.single;
        expect(row.shiftFact.businessTimingProfileId, _profileId);
        expect(row.shiftFact.businessTimingProfileVersionId, _profileId);
        expect(row.shiftFact.servicePeriodKey, 'dinner');
        expect(
          row.shiftFact.targetSnapshot.targetProfileVersionId,
          'tpv_current',
        );
        expect(row.provenance.priorTargetProfileVersionId, 'tpv_prior');
      },
    );

    test(
      'open/current periods invoke only the open snapshot projector',
      () async {
        final aggregator = _FakeClosedAggregator(<String, AggregatorResult?>{});
        final writer = _FakeClosedWriter();
        final targetResolver = _FakeTargetResolver(_currentTarget);
        final open = _FakeOpenProjector(
          result: OpenShiftProjectionResult.projected(
            businessDate: '2026-05-06',
            snapshotsUpserted: 2,
            servicePeriodSnapshotsUpserted: 1,
            ignoredFacts: 0,
            servicePeriodKeys: const <String>['dinner'],
          ),
        );
        final projector = _projector(
          aggregator: aggregator,
          writer: writer,
          targetResolver: targetResolver,
          open: open,
        );

        final result = await projector.project(
          _input(
            periods: <CanonicalFactCommittedPeriod>[
              _period(state: CanonicalFactPeriodState.openCurrent),
            ],
            openCurrentFacts: <Map<String, Object?>>[
              <String, Object?>{
                'fact_type': 'cover_fact',
                'operator_id': _operatorId,
                'location_id': _locationId,
              },
            ],
          ),
        );

        expect(result.openCurrentPeriodsSeen, 1);
        expect(result.openSnapshotsUpserted, 2);
        expect(result.openServicePeriodSnapshotsUpserted, 1);
        expect(aggregator.calls, isEmpty);
        expect(targetResolver.calls, isEmpty);
        expect(writer.rows, isEmpty);
        expect(open.calls.single.input.vendorId, 'toast');
        expect(open.calls.single.input.connectionId, 'connection-1');
        expect(open.calls.single.input.openCurrentFactMaps, hasLength(1));
        expect(open.calls.single.periods.single.servicePeriodKey, 'dinner');
      },
    );

    test('mixed batches route completed and open periods separately', () async {
      final completed = _period();
      final openPeriod = _period(
        servicePeriodKey: 'lunch',
        state: CanonicalFactPeriodState.openCurrent,
      );
      final aggregator = _FakeClosedAggregator(<String, AggregatorResult?>{
        completed.periodIdentity: _aggregateResult(),
      });
      final writer = _FakeClosedWriter();
      final targetResolver = _FakeTargetResolver(_currentTarget);
      final open = _FakeOpenProjector();
      final projector = _projector(
        aggregator: aggregator,
        writer: writer,
        targetResolver: targetResolver,
        open: open,
      );

      final result = await projector.project(
        _input(periods: <CanonicalFactCommittedPeriod>[completed, openPeriod]),
      );

      expect(result.completedPeriodsSeen, 1);
      expect(result.openCurrentPeriodsSeen, 1);
      expect(result.closedShiftRecordsProjected, 1);
      expect(writer.rows, hasLength(1));
      expect(open.calls, hasLength(1));
      expect(open.calls.single.periods.single.servicePeriodKey, 'lunch');
    });

    test(
      'mixed batch only hands explicit open/current facts to open projector',
      () async {
        final completedOnlyFact = <String, Object?>{
          'fact_type': 'cover_fact',
          'operator_id': _operatorId,
          'location_id': _locationId,
          'vendor_entity_id': 'completed-check',
        };
        final openFact = <String, Object?>{
          'fact_type': 'cover_fact',
          'operator_id': _operatorId,
          'location_id': _locationId,
          'vendor_entity_id': 'open-check',
        };
        final completed = _period();
        final openPeriod = _period(state: CanonicalFactPeriodState.openCurrent);
        final aggregator = _FakeClosedAggregator(<String, AggregatorResult?>{
          completed.periodIdentity: _aggregateResult(),
        });
        final open = _FakeOpenProjector();
        final projector = _projector(
          aggregator: aggregator,
          writer: _FakeClosedWriter(),
          targetResolver: _FakeTargetResolver(_currentTarget),
          open: open,
        );

        await projector.project(
          _input(
            periods: <CanonicalFactCommittedPeriod>[completed, openPeriod],
            openCurrentFacts: <Map<String, Object?>>[openFact],
          ),
        );

        expect(open.calls, hasLength(1));
        expect(
          open.calls.single.input.openCurrentFactMaps,
          <Map<String, Object?>>[openFact],
        );
        expect(
          open.calls.single.input.openCurrentFactMaps,
          isNot(contains(completedOnlyFact)),
        );
      },
    );

    test('existing open adapter passes only openCurrentFactMaps', () async {
      final recordingProjector = _RecordingOpenShiftSnapshotProjector();
      final adapter = ExistingOpenShiftPostCommitProjector(recordingProjector);
      final openFact = <String, Object?>{
        'fact_type': 'cover_fact',
        'operator_id': _operatorId,
        'location_id': _locationId,
        'vendor_entity_id': 'open-check',
      };

      await adapter.project(
        input: _input(
          periods: <CanonicalFactCommittedPeriod>[
            _period(),
            _period(state: CanonicalFactPeriodState.openCurrent),
          ],
          openCurrentFacts: <Map<String, Object?>>[openFact],
        ),
        periods: <CanonicalFactCommittedPeriod>[
          _period(state: CanonicalFactPeriodState.openCurrent),
        ],
      );

      expect(recordingProjector.factMaps, <Map<String, Object?>>[openFact]);
      expect(recordingProjector.operatorId, _operatorId);
      expect(recordingProjector.locationId, _locationId);
      expect(recordingProjector.businessDate, '2026-05-06');
    });

    test('duplicate periods in one post-commit input are deduped', () async {
      final period = _period();
      final aggregator = _FakeClosedAggregator(<String, AggregatorResult?>{
        period.periodIdentity: _aggregateResult(),
      });
      final writer = _FakeClosedWriter();
      final targetResolver = _FakeTargetResolver(_currentTarget);
      final open = _FakeOpenProjector();
      final projector = _projector(
        aggregator: aggregator,
        writer: writer,
        targetResolver: targetResolver,
        open: open,
      );

      final result = await projector.project(
        _input(periods: <CanonicalFactCommittedPeriod>[period, period]),
      );

      expect(result.completedPeriodsSeen, 1);
      expect(aggregator.calls, hasLength(1));
      expect(writer.rows, hasLength(1));
    });

    test('closed replay stays idempotent at the writer boundary', () async {
      final period = _period();
      final aggregator = _FakeClosedAggregator(<String, AggregatorResult?>{
        period.periodIdentity: _aggregateResult(),
      });
      final writer = _FakeClosedWriter();
      final targetResolver = _FakeTargetResolver(_currentTarget);
      final projector = _projector(
        aggregator: aggregator,
        writer: writer,
        targetResolver: targetResolver,
        open: _FakeOpenProjector(),
      );
      final input = _input(periods: <CanonicalFactCommittedPeriod>[period]);

      await projector.project(input);
      await projector.project(input);

      expect(writer.rows, hasLength(1));
      expect(writer.writeCount, 2);
      expect(
        writer.rows.single.provenance.priorTargetProfileVersionId,
        'tpv_prior',
      );
    });

    test('unavailable closed aggregate skips writer honestly', () async {
      final period = _period();
      final aggregator = _FakeClosedAggregator(<String, AggregatorResult?>{
        period.periodIdentity: null,
      });
      final writer = _FakeClosedWriter();
      final projector = _projector(
        aggregator: aggregator,
        writer: writer,
        targetResolver: _FakeTargetResolver(_currentTarget),
        open: _FakeOpenProjector(),
      );

      final result = await projector.project(
        _input(periods: <CanonicalFactCommittedPeriod>[period]),
      );

      expect(result.closedShiftRecordsProjected, 0);
      expect(result.closedPeriodsUnavailable, 1);
      expect(writer.rows, isEmpty);
    });

    test('scope mismatch is rejected before projection', () async {
      final projector = _projector(
        aggregator: _FakeClosedAggregator(<String, AggregatorResult?>{}),
        writer: _FakeClosedWriter(),
        targetResolver: _FakeTargetResolver(_currentTarget),
        open: _FakeOpenProjector(),
      );

      expect(
        () => projector.project(
          _input(
            periods: <CanonicalFactCommittedPeriod>[
              _period(locationId: 'wrong-location'),
            ],
          ),
        ),
        throwsArgumentError,
      );
    });
  });
}

CanonicalFactPostCommitProjector _projector({
  required _FakeClosedAggregator aggregator,
  required _FakeClosedWriter writer,
  required _FakeTargetResolver targetResolver,
  required _FakeOpenProjector open,
}) {
  return CanonicalFactPostCommitProjector(
    closedAggregator: aggregator,
    targetSnapshotResolver: targetResolver,
    closedWriter: writer,
    openProjector: open,
  );
}

CanonicalFactPostCommitInput _input({
  required List<CanonicalFactCommittedPeriod> periods,
  List<Map<String, Object?>> openCurrentFacts = const <Map<String, Object?>>[],
}) {
  return CanonicalFactPostCommitInput(
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    integrationCategory: IntegrationCategory.pos,
    vendorId: 'toast',
    connectionId: 'connection-1',
    changedPeriods: periods,
    openCurrentFactMaps: openCurrentFacts,
    userId: 'user-1',
  );
}

CanonicalFactCommittedPeriod _period({
  String operatorId = _operatorId,
  String locationId = _locationId,
  String servicePeriodKey = 'dinner',
  CanonicalFactPeriodState state = CanonicalFactPeriodState.completed,
}) {
  return CanonicalFactCommittedPeriod(
    operatorId: operatorId,
    locationId: locationId,
    restaurantId: _restaurantId,
    businessDate: '2026-05-06',
    weekId: '2026-05-04_2026-05-10',
    dayLabel: 'Wed',
    servicePeriodKey: servicePeriodKey,
    servicePeriodDefinition: ServicePeriodDefinition(
      id: servicePeriodKey,
      label: servicePeriodKey == 'lunch' ? 'Lunch' : 'Dinner',
      shortLabel: servicePeriodKey == 'lunch' ? 'L' : 'D',
      sortOrder: servicePeriodKey == 'lunch' ? 1 : 2,
      startLocalTime: servicePeriodKey == 'lunch' ? '11:00' : '17:00',
      endLocalTime: servicePeriodKey == 'lunch' ? '15:00' : '22:00',
      rollsPastMidnight: false,
      applicableDays: const <int>[1, 2, 3, 4, 5, 6, 7],
    ),
    state: state,
    businessTimingProfileId: _profileId,
    businessTimingProfileVersionId: _profileId,
  );
}

AggregatorResult _aggregateResult() {
  return AggregatorResult(
    input: ClosedShiftInput(
      restaurantId: _restaurantId,
      businessDate: DateTime.utc(2026, 5, 6),
      weekId: '2026-05-04_2026-05-10',
      dayLabel: 'Wed',
      daypart: 'dinner',
      businessTimingProfileId: _profileId,
      businessTimingProfileVersionId: _profileId,
      servicePeriodKey: 'dinner',
      covers: 80,
      forecastCovers: 72,
      actualSales: 3600,
      actualFohHours: 20,
      actualBohHours: 30,
      actualFohLaborDollars: 400,
      actualBohLaborDollars: 720,
      sourceSystem: 'toast',
    ),
    provenance: const AggregatorProvenanceContext(
      coversProvenance: 'vendor_toast',
      laborDollarsProvenance: 'vendor_humanity_per_position_actual_dollars',
      priorTargetProfileVersionId: 'tpv_prior',
      hasPriorShiftRecord: true,
      priorBusinessTimingProfileId: _profileId,
      priorBusinessTimingProfileVersionId: _profileId,
      priorServicePeriodKey: 'dinner',
    ),
  );
}

class _FakeClosedAggregator implements ClosedShiftPostCommitAggregator {
  _FakeClosedAggregator(this.results);

  final Map<String, AggregatorResult?> results;
  final List<CanonicalFactCommittedPeriod> calls =
      <CanonicalFactCommittedPeriod>[];

  @override
  Future<AggregatorResult?> aggregate(
    CanonicalFactCommittedPeriod period,
  ) async {
    calls.add(period);
    return results[period.periodIdentity];
  }
}

class _FakeTargetResolver implements ClosedShiftTargetSnapshotResolver {
  _FakeTargetResolver(this.snapshot);

  final TargetSnapshot snapshot;
  final List<CanonicalFactCommittedPeriod> calls =
      <CanonicalFactCommittedPeriod>[];

  @override
  Future<TargetSnapshot> resolveTargetSnapshot({
    required CanonicalFactPostCommitInput input,
    required CanonicalFactCommittedPeriod period,
    required AggregatorResult aggregateResult,
  }) async {
    calls.add(period);
    return snapshot;
  }
}

class _FakeClosedWriter implements ClosedShiftPostCommitWriter {
  final Map<String, _ClosedWrite> _rows = <String, _ClosedWrite>{};
  int writeCount = 0;

  List<_ClosedWrite> get rows => _rows.values.toList();

  @override
  Future<void> write({
    required String operatorId,
    required String locationId,
    required ShiftFact shiftFact,
    required AggregatorProvenanceContext provenance,
  }) async {
    writeCount += 1;
    _rows['$operatorId|$locationId|'
        '${shiftFact.businessDate.toIso8601String().substring(0, 10)}|'
        '${shiftFact.servicePeriodKey ?? shiftFact.daypart}'] = _ClosedWrite(
      shiftFact: shiftFact,
      provenance: provenance,
    );
  }
}

class _ClosedWrite {
  const _ClosedWrite({required this.shiftFact, required this.provenance});

  final ShiftFact shiftFact;
  final AggregatorProvenanceContext provenance;
}

class _FakeOpenProjector implements OpenShiftPostCommitProjector {
  _FakeOpenProjector({OpenShiftProjectionResult? result})
    : result =
          result ??
          OpenShiftProjectionResult.projected(
            businessDate: '2026-05-06',
            snapshotsUpserted: 0,
            servicePeriodSnapshotsUpserted: 0,
            ignoredFacts: 0,
            servicePeriodKeys: const <String>[],
          );

  final OpenShiftProjectionResult result;
  final List<_OpenCall> calls = <_OpenCall>[];

  @override
  Future<OpenShiftProjectionResult> project({
    required CanonicalFactPostCommitInput input,
    required Iterable<CanonicalFactCommittedPeriod> periods,
  }) async {
    calls.add(
      _OpenCall(input: input, periods: periods.toList(growable: false)),
    );
    return result;
  }
}

class _RecordingOpenShiftSnapshotProjector extends OpenShiftSnapshotProjector {
  _RecordingOpenShiftSnapshotProjector()
    : super(
        timingSource: _NoopTimingSource(),
        snapshotWriter: _NoopSnapshotWriter(),
      );

  String? operatorId;
  String? locationId;
  String? businessDate;
  List<Map<String, Object?>> factMaps = const <Map<String, Object?>>[];

  @override
  Future<OpenShiftProjectionResult> projectFactMaps({
    required String operatorId,
    required String locationId,
    required Iterable<Map<String, Object?>> facts,
    String? businessDate,
    String? userId,
  }) async {
    this.operatorId = operatorId;
    this.locationId = locationId;
    this.businessDate = businessDate;
    factMaps = facts.toList(growable: false);
    return OpenShiftProjectionResult.projected(
      businessDate: businessDate ?? '2026-05-06',
      snapshotsUpserted: 1,
      servicePeriodSnapshotsUpserted: 1,
      ignoredFacts: 0,
      servicePeriodKeys: const <String>['dinner'],
    );
  }
}

class _NoopTimingSource implements OpenShiftTimingProfileSource {
  @override
  Future<ResolvedOpenShiftTimingProfile?> resolveForBusinessDate({
    required String operatorId,
    required String locationId,
    required String businessDate,
    String? userId,
  }) async {
    return null;
  }
}

class _NoopSnapshotWriter implements OpenShiftSnapshotWriter {
  @override
  Future<void> upsert(OpenShiftSnapshotProjectionWrite snapshot) async {}
}

class _OpenCall {
  const _OpenCall({required this.input, required this.periods});

  final CanonicalFactPostCommitInput input;
  final List<CanonicalFactCommittedPeriod> periods;
}
