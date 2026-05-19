import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_post_commit_projector.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_projection_retry.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../tool/projection_retry_worker/main.dart';

void main() {
  group('projection retry worker CLI', () {
    test('parses runOnce with bounded batch size', () {
      final args = parseArgs(<String>['runOnce', '--max-jobs-per-tick=7']);

      expect(args.mode, WorkerMode.runOnce);
      expect(args.maxJobsPerTick, 7);
    });

    test('rejects unknown mode', () {
      expect(
        () => parseArgs(<String>['forever']),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('runProjectionRetryWorkerTick', () {
    test('is safe when no jobs exist', () async {
      final store = _FakeRetryStore();
      final dispatcher = CanonicalFactProjectionRetryDispatcher(
        jobStore: store,
        projector: _RecordingProjector(),
      );

      final result = await runProjectionRetryWorkerTick(
        scopeSource: _FakeScopeSource(store),
        dispatcher: dispatcher,
        workerId: 'worker-1',
        maxJobsPerTick: 10,
      );

      expect(result.jobsAttempted, 0);
      expect(result.succeeded, 0);
      expect(result.failed, 0);
      expect(result.deadLettered, 0);
      expect(store.claimCalls, 0);
    });

    test('drains repeated due scopes up to the batch limit', () async {
      final store = _FakeRetryStore()
        ..add(_job(jobId: 'job-1'))
        ..add(_job(jobId: 'job-2'))
        ..add(_job(jobId: 'job-3'));
      final projector = _RecordingProjector();
      final dispatcher = CanonicalFactProjectionRetryDispatcher(
        jobStore: store,
        projector: projector,
      );

      final result = await runProjectionRetryWorkerTick(
        scopeSource: _FakeScopeSource(store),
        dispatcher: dispatcher,
        workerId: 'worker-1',
        maxJobsPerTick: 2,
      );

      expect(result.jobsAttempted, 2);
      expect(result.succeeded, 2);
      expect(result.failed, 0);
      expect(projector.invocations, hasLength(2));
      expect(store.succeededJobIds, <String>['job-1', 'job-2']);
      expect(store.remainingJobs, 1);
    });

    test('counts failed and dead-lettered dispatch outcomes', () async {
      final store = _FakeRetryStore()
        ..add(_job(jobId: 'job-1', attemptCount: 1))
        ..add(_job(jobId: 'job-2', attemptCount: 5));
      final dispatcher = CanonicalFactProjectionRetryDispatcher(
        jobStore: store,
        projector: _RecordingProjector(throwOnProject: true),
      );

      final result = await runProjectionRetryWorkerTick(
        scopeSource: _FakeScopeSource(store),
        dispatcher: dispatcher,
        workerId: 'worker-1',
        maxJobsPerTick: 10,
      );

      expect(result.jobsAttempted, 2);
      expect(result.succeeded, 0);
      expect(result.failed, 1);
      expect(result.deadLettered, 1);
      expect(store.failedJobIds, <String>['job-1', 'job-2']);
      expect(store.deadLetteredJobIds, <String>['job-2']);
    });

    test('stops between jobs when shutdown is requested', () async {
      final store = _FakeRetryStore()
        ..add(_job(jobId: 'job-1'))
        ..add(_job(jobId: 'job-2'));
      final dispatcher = CanonicalFactProjectionRetryDispatcher(
        jobStore: store,
        projector: _RecordingProjector(),
      );
      var calls = 0;

      final result = await runProjectionRetryWorkerTick(
        scopeSource: _FakeScopeSource(store),
        dispatcher: dispatcher,
        workerId: 'worker-1',
        maxJobsPerTick: 10,
        shouldStop: () {
          calls += 1;
          return calls > 2;
        },
      );

      expect(result.jobsAttempted, 1);
      expect(store.succeededJobIds, <String>['job-1']);
      expect(store.remainingJobs, 1);
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

CanonicalFactProjectionRetryJob _job({
  required String jobId,
  int attemptCount = 1,
}) {
  final record = CanonicalFactProjectionRetryRecord.fromFailure(
    input: _input(),
    factCount: 1,
    error: StateError('projector down'),
    stackFirstFrame: '#0 test',
  );
  return CanonicalFactProjectionRetryJob(
    jobId: jobId,
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

class _FakeScopeSource implements ProjectionRetryScopeSource {
  _FakeScopeSource(this.store);

  final _FakeRetryStore store;

  @override
  Stream<ProjectionRetryScope> dueScopes({
    required int limit,
    Duration claimStaleAfter = const Duration(minutes: 15),
  }) async* {
    if (limit <= 0 || store.remainingJobs == 0) return;
    yield const ProjectionRetryScope(
      operatorId: _operatorId,
      locationId: _locationId,
    );
  }
}

class _FakeRetryStore implements CanonicalFactProjectionRetryJobStore {
  final _jobs = <CanonicalFactProjectionRetryJob>[];
  final succeededJobIds = <String>[];
  final failedJobIds = <String>[];
  final deadLetteredJobIds = <String>[];
  var claimCalls = 0;

  int get remainingJobs => _jobs.length;

  void add(CanonicalFactProjectionRetryJob job) {
    _jobs.add(job);
  }

  @override
  Future<CanonicalFactProjectionRetryJob?> claimNext({
    required String operatorId,
    required String locationId,
    required String workerId,
    Duration claimStaleAfter = const Duration(minutes: 15),
  }) async {
    claimCalls += 1;
    if (_jobs.isEmpty) return null;
    return _jobs.removeAt(0);
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
    if (job.attemptCount >= maxAttempts) {
      deadLetteredJobIds.add(job.jobId);
    }
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
