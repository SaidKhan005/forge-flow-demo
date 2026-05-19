import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_post_commit_projector.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_projection_retry.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

void main() {
  group('CanonicalFactProjectionRetryRecord', () {
    test('preserves projector input for replay', () {
      final input = _input();

      final record = CanonicalFactProjectionRetryRecord.fromFailure(
        input: input,
        factCount: 2,
        error: StateError('projector down'),
        stackFirstFrame: '#0 test',
      );
      final replay = record.toInput();

      expect(record.inputHash, hasLength(64));
      expect(record.factCount, 2);
      expect(record.errorMessage, contains('projector down'));
      expect(replay.operatorId, input.operatorId);
      expect(replay.locationId, input.locationId);
      expect(replay.connectionId, input.connectionId);
      expect(replay.changedPeriods.single.servicePeriodKey, 'dinner');
      expect(replay.openCurrentFactMaps.single['fact_type'], 'cover_fact');
    });
  });

  group('CanonicalFactProjectionRetryDispatcher', () {
    test('claims a retry job, replays projection, and marks success', () async {
      final store = _FakeRetryStore(_job());
      final projector = _RecordingProjector();
      final dispatcher = CanonicalFactProjectionRetryDispatcher(
        jobStore: store,
        projector: projector,
      );

      final result = await dispatcher.dispatchNext(
        operatorId: _operatorId,
        locationId: _locationId,
        workerId: 'worker-1',
      );

      expect(
        result.outcome,
        CanonicalFactProjectionRetryDispatchOutcome.succeeded,
      );
      expect(projector.invocations, hasLength(1));
      expect(store.succeededJobIds, contains('job-1'));
      expect(store.failedJobIds, isEmpty);
    });

    test('failed replay returns job to pending retry budget', () async {
      final store = _FakeRetryStore(_job(attemptCount: 1));
      final projector = _RecordingProjector(throwOnProject: true);
      final dispatcher = CanonicalFactProjectionRetryDispatcher(
        jobStore: store,
        projector: projector,
      );

      final result = await dispatcher.dispatchNext(
        operatorId: _operatorId,
        locationId: _locationId,
        workerId: 'worker-1',
        maxAttempts: 3,
      );

      expect(
        result.outcome,
        CanonicalFactProjectionRetryDispatchOutcome.failed,
      );
      expect(store.failedJobIds, contains('job-1'));
      expect(store.deadLettered, isFalse);
    });

    test('failed replay dead-letters after retry budget', () async {
      final store = _FakeRetryStore(_job(attemptCount: 3));
      final projector = _RecordingProjector(throwOnProject: true);
      final dispatcher = CanonicalFactProjectionRetryDispatcher(
        jobStore: store,
        projector: projector,
      );

      final result = await dispatcher.dispatchNext(
        operatorId: _operatorId,
        locationId: _locationId,
        workerId: 'worker-1',
        maxAttempts: 3,
      );

      expect(
        result.outcome,
        CanonicalFactProjectionRetryDispatchOutcome.deadLettered,
      );
      expect(store.failedJobIds, contains('job-1'));
      expect(store.deadLettered, isTrue);
    });
  });
}

const _operatorId = '11111111-1111-4111-8111-111111111111';
const _locationId = '22222222-2222-4222-8222-222222222222';
const _restaurantId = 'restaurant-1';
const _connectionId = '33333333-3333-4333-8333-333333333333';

CanonicalFactPostCommitInput _input() {
  return CanonicalFactPostCommitInput(
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    integrationCategory: IntegrationCategory.pos,
    vendorId: 'toast',
    connectionId: _connectionId,
    changedPeriods: <CanonicalFactCommittedPeriod>[_period()],
    openCurrentFactMaps: const <Map<String, Object?>>[
      <String, Object?>{'fact_type': 'cover_fact', 'covers': 12},
    ],
  );
}

CanonicalFactCommittedPeriod _period() {
  return const CanonicalFactCommittedPeriod(
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    businessDate: '2026-05-06',
    weekId: '2026-W19',
    dayLabel: 'Wed',
    servicePeriodKey: 'dinner',
    servicePeriodDefinition: ServicePeriodDefinition(
      id: 'dinner',
      label: 'Dinner',
      shortLabel: 'D',
      sortOrder: 2,
      startLocalTime: '17:00',
      endLocalTime: '22:00',
      rollsPastMidnight: false,
      applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
    ),
    state: CanonicalFactPeriodState.completed,
  );
}

CanonicalFactProjectionRetryJob _job({int attemptCount = 1}) {
  final record = CanonicalFactProjectionRetryRecord.fromFailure(
    input: _input(),
    factCount: 1,
    error: StateError('projector down'),
    stackFirstFrame: '#0 test',
  );
  return CanonicalFactProjectionRetryJob(
    jobId: 'job-1',
    status: CanonicalFactProjectionRetryStatus.running,
    attemptCount: attemptCount,
    nextAttemptAt: DateTime.utc(2026, 5, 19),
    operatorId: record.operatorId,
    locationId: record.locationId,
    restaurantId: record.restaurantId,
    integrationCategory: record.integrationCategory,
    vendorId: record.vendorId,
    connectionId: record.connectionId,
    changedPeriods: record.changedPeriods,
    openCurrentFactMaps: record.openCurrentFactMaps,
    inputHash: record.inputHash,
    factCount: record.factCount,
    errorClass: record.errorClass,
    errorMessage: record.errorMessage,
    stackFirstFrame: record.stackFirstFrame,
  );
}

class _FakeRetryStore implements CanonicalFactProjectionRetryJobStore {
  _FakeRetryStore(this.job);

  CanonicalFactProjectionRetryJob? job;
  final succeededJobIds = <String>[];
  final failedJobIds = <String>[];
  bool deadLettered = false;

  @override
  Future<CanonicalFactProjectionRetryJob?> claimNext({
    required String operatorId,
    required String locationId,
    required String workerId,
    Duration claimStaleAfter = const Duration(minutes: 15),
  }) async {
    final claimed = job;
    job = null;
    return claimed;
  }

  @override
  Future<void> markSucceeded(CanonicalFactProjectionRetryJob job) async {
    succeededJobIds.add(job.jobId);
  }

  @override
  Future<void> markFailed({
    required CanonicalFactProjectionRetryJob job,
    required Object error,
    required StackTrace stackTrace,
    int maxAttempts = kCanonicalFactProjectionRetryMaxAttempts,
    Duration retryDelay = kCanonicalFactProjectionRetryDelay,
  }) async {
    failedJobIds.add(job.jobId);
    deadLettered = job.attemptCount >= maxAttempts;
  }

  @override
  Future<void> recordProjectionFailure(
    CanonicalFactProjectionRetryRecord record,
  ) async {}
}

class _RecordingProjector implements CanonicalFactPostCommitProjector {
  _RecordingProjector({this.throwOnProject = false});

  final bool throwOnProject;
  final invocations = <CanonicalFactPostCommitInput>[];

  @override
  Future<CanonicalFactPostCommitProjectionResult> project(
    CanonicalFactPostCommitInput input,
  ) async {
    invocations.add(input);
    if (throwOnProject) {
      throw StateError('still down');
    }
    return CanonicalFactPostCommitProjectionResult(
      operatorId: input.operatorId,
      locationId: input.locationId,
      integrationCategory: input.integrationCategory,
      vendorId: input.vendorId,
      connectionId: input.connectionId,
      completedPeriodsSeen: input.changedPeriods.length,
      openCurrentPeriodsSeen: input.openCurrentFactMaps.length,
      closedShiftRecordsProjected: input.changedPeriods.length,
      closedPeriodsUnavailable: 0,
      openSnapshotsUpserted: 0,
      openServicePeriodSnapshotsUpserted: 0,
      openProjectionUnavailable: false,
      openProjectionReason: null,
      closedPeriodKeys: <String>[
        for (final period in input.changedPeriods) period.periodIdentity,
      ],
      openPeriodKeys: const <String>[],
    );
  }
}
