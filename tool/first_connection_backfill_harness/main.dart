// Lane 5 fixture proof for the first-connection backfill spine.
//
// This is intentionally a small deterministic harness, not a load suite and
// not a live provider proof. It exercises the accepted seams from Lanes 0-4
// with in-memory adapters/stores so the closeout docs can state exactly what
// was simulated.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/aggregator_provenance_context.dart';
import 'package:forge_and_flow/domain/models/closed_shift_input.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/models/shift_fact.dart';
import 'package:forge_and_flow/domain/models/target_snapshot.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_post_commit_projector.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_to_closed_shift_input.dart';
import 'package:forge_and_flow/services/integration/canonical_sink.dart';
import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/labor_adapter.dart';
import 'package:forge_and_flow/services/integration/open_shift_snapshot_projector.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';
import 'package:forge_and_flow/services/integration/reservation_adapter.dart';

import '../integration_sync_worker/backfill_dispatch.dart';

const String _operatorId = '11111111-1111-4111-8111-111111111111';
const String _locationId = '22222222-2222-4222-8222-222222222222';
const String _actorUserId = '33333333-3333-4333-8333-333333333333';
const String _restaurantId = 'restaurant-first-backfill';
const String _profileId = '44444444-4444-4444-8444-444444444444';
final DateTime _connectedAt = DateTime.utc(2026, 5, 6, 12);

void main() {
  test(
    'first connection backfill reaches mobile-visible closed/open state',
    () async {
      final proof = await FirstConnectionBackfillHarness().run();
      // Printed intentionally so the walkthrough can cite the fixture proof
      // summary without relying on hidden test internals.
      // ignore: avoid_print
      print(const JsonEncoder.withIndent('  ').convert(proof.toJson()));
    },
  );
}

class FirstConnectionBackfillHarness {
  Future<FirstConnectionBackfillProof> run() async {
    final sink = _RecordingCanonicalSink();
    final enqueuer = _FixtureFirstBackfillEnqueuer();
    final dispatch = const IntegrationSyncWorkerBackfillDispatch();

    final connectJob = await _simulateConnect(enqueuer);
    _check(
      connectJob.windowEnd.difference(connectJob.windowStart) ==
          kFirstConnectionBackfillMaxWindow,
      'first connection enqueued exactly one bounded 60-day job',
    );

    final zeroStore = _FixtureBackfillJobStore(<FirstConnectionBackfillJob>[
      _job(
        jobId: '00000000-0000-4000-8000-0000000000e0',
        connectionId: '00000000-0000-4000-8000-0000000000c0',
        vendorId: 'lightspeed_lsk',
        category: IntegrationCategory.pos,
      ),
    ]);
    final zeroAdapter = _FixturePosBackfillAdapter(
      sink: sink,
      recordsWritten: 0,
      cursorToken: 'cursor-zero',
    );
    final zeroResult = await dispatch.dispatchNext(
      operatorId: _operatorId,
      locationId: _locationId,
      workerId: 'fixture-worker',
      jobStore: zeroStore,
      adapterFactory: (_) => zeroAdapter,
      canonicalSink: sink,
    );
    _check(
      zeroResult.outcome == BackfillDispatchOutcome.succeeded &&
          sink.demoFlips.isEmpty,
      'zero-row first backfill completes without flipping demo mode',
    );

    final store = _FixtureBackfillJobStore(<FirstConnectionBackfillJob>[
      _job(
        jobId: '00000000-0000-4000-8000-0000000000b1',
        connectionId: '00000000-0000-4000-8000-0000000000c1',
        vendorId: 'lightspeed_lsk',
        category: IntegrationCategory.pos,
      ),
      _job(
        jobId: '00000000-0000-4000-8000-0000000000b2',
        connectionId: '00000000-0000-4000-8000-0000000000c2',
        vendorId: 'seven_shifts',
        category: IntegrationCategory.labor,
      ),
      _job(
        jobId: '00000000-0000-4000-8000-0000000000b3',
        connectionId: '00000000-0000-4000-8000-0000000000c3',
        vendorId: 'libro',
        category: IntegrationCategory.reservation,
      ),
    ]);
    final adapters = <IntegrationCategory, Object>{
      IntegrationCategory.pos: _FixturePosBackfillAdapter(
        sink: sink,
        recordsWritten: 2,
        cursorToken: 'cursor-pos',
      ),
      IntegrationCategory.labor: _FixtureLaborBackfillAdapter(
        sink: sink,
        recordsWritten: 2,
        cursorToken: 'cursor-labor',
      ),
      IntegrationCategory.reservation: _FixtureReservationBackfillAdapter(
        sink: sink,
        recordsWritten: 1,
        cursorToken: 'cursor-reservation',
      ),
    };
    final batchResult = await dispatch.dispatchAvailable(
      operatorId: _operatorId,
      locationId: _locationId,
      workerId: 'fixture-worker',
      jobStore: store,
      adapterFactory: (job) => adapters[job.category]!,
      canonicalSink: sink,
    );

    _check(
      batchResult.attempted == 3 &&
          batchResult.succeeded == 3 &&
          batchResult.failed == 0,
      'POS, labor, and reservation backfills dispatch successfully',
    );
    _check(
      sink.coverFacts.isNotEmpty &&
          sink.laborPunches.isNotEmpty &&
          sink.reservationFacts.isNotEmpty,
      'accepted adapters wrote canonical POS, labor, and reservation facts',
    );
    _check(
      sink.watermarkAdvances.length == 4,
      'watermark advanced for zero-row and committed backfills',
    );
    _check(
      sink.demoFlips.length == 3,
      'demo flips only after committed non-zero first backfill rows',
    );

    final postCommit = _PostCommitFixture();
    final closedResult = await postCommit.projector.project(
      _input(periods: <CanonicalFactCommittedPeriod>[_period()]),
    );
    _check(
      closedResult.closedShiftRecordsProjected == 1 &&
          postCommit.closedWriter.rows.length == 1,
      'completed canonical period projected one closed shift row',
    );

    final mobile = _MobileCacheFixture();
    mobile.pullClosedRows(postCommit.closedWriter.rows);
    _check(
      mobile.closedRowsVisible == 1,
      'closed shift row became mobile-visible through the existing cache shape',
    );

    final openResult = await postCommit.projector.project(
      _input(
        periods: <CanonicalFactCommittedPeriod>[
          _period(state: CanonicalFactPeriodState.openCurrent),
        ],
        openCurrentFacts: <Map<String, Object?>>[sink.coverFacts.first],
      ),
    );
    _check(
      openResult.openSnapshotsUpserted == 1 &&
          postCommit.openProjector.calls.length == 1,
      'open/current canonical period invoked the open snapshot projector',
    );

    return FirstConnectionBackfillProof(
      connectJobsEnqueued: enqueuer.jobs.length,
      dispatchedJobs: batchResult.attempted,
      canonicalFactsWritten:
          sink.coverFacts.length +
          sink.laborPunches.length +
          sink.reservationFacts.length,
      demoFlips: sink.demoFlips.length,
      closedRowsMobileVisible: mobile.closedRowsVisible,
      openSnapshotsProjected: openResult.openSnapshotsUpserted,
      simulated: const <String>[
        'connect result and enqueue gateway',
        'POS/labor/reservation adapter backfill writes',
        'canonical sink, watermark, sync-log, and demo flip seams',
        'closed post-commit aggregator/writer seam',
        'open snapshot projector seam',
        'mobile-visible cache read shape',
      ],
      notRun: const <String>[
        'live vendor/provider calls',
        'live Postgres migration apply',
        'Cloud Run worker invocation',
        'push notification proof',
        'large pressure suite',
      ],
    );
  }

  Future<FirstConnectionBackfillJob> _simulateConnect(
    _FixtureFirstBackfillEnqueuer enqueuer,
  ) {
    final connectResult = ConnectResult(
      connectionId: '00000000-0000-4000-8000-0000000000a1',
      status: ConnectionStatus.connected,
      metadata: const <String, Object?>{'fixture': true},
      firstBackfillStarted: true,
    );
    _check(
      connectResult.firstBackfillStarted,
      'adapter connect result requested first backfill',
    );
    final window = FirstConnectionBackfillWindow.lastSixtyDays(_connectedAt);
    return enqueuer.enqueueFirstBackfill(
      operatorId: _operatorId,
      locationId: _locationId,
      connectionId: connectResult.connectionId,
      vendorId: 'lightspeed_lsk',
      category: IntegrationCategory.pos,
      windowStart: window.windowStart,
      windowEnd: window.windowEnd,
      actorUserId: _actorUserId,
    );
  }
}

class FirstConnectionBackfillProof {
  const FirstConnectionBackfillProof({
    required this.connectJobsEnqueued,
    required this.dispatchedJobs,
    required this.canonicalFactsWritten,
    required this.demoFlips,
    required this.closedRowsMobileVisible,
    required this.openSnapshotsProjected,
    required this.simulated,
    required this.notRun,
  });

  final int connectJobsEnqueued;
  final int dispatchedJobs;
  final int canonicalFactsWritten;
  final int demoFlips;
  final int closedRowsMobileVisible;
  final int openSnapshotsProjected;
  final List<String> simulated;
  final List<String> notRun;

  Map<String, Object?> toJson() => <String, Object?>{
    'status': 'pass',
    'connect_jobs_enqueued': connectJobsEnqueued,
    'dispatched_jobs': dispatchedJobs,
    'canonical_facts_written': canonicalFactsWritten,
    'demo_flips': demoFlips,
    'closed_rows_mobile_visible': closedRowsMobileVisible,
    'open_snapshots_projected': openSnapshotsProjected,
    'simulated': simulated,
    'not_run': notRun,
  };
}

class _FixtureFirstBackfillEnqueuer {
  final List<FirstConnectionBackfillJob> jobs = <FirstConnectionBackfillJob>[];

  Future<FirstConnectionBackfillJob> enqueueFirstBackfill({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String vendorId,
    required IntegrationCategory category,
    required DateTime windowStart,
    required DateTime windowEnd,
    String? actorUserId,
  }) async {
    final existing = jobs.where((job) {
      return job.connectionId == connectionId &&
          job.category == category &&
          job.windowStart == windowStart &&
          job.windowEnd == windowEnd &&
          job.isActive;
    }).firstOrNull;
    if (existing != null) return existing;
    final job = FirstConnectionBackfillJob(
      jobId: '00000000-0000-4000-8000-000000000001',
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      vendorId: vendorId,
      category: category,
      windowStart: windowStart,
      windowEnd: windowEnd,
      status: FirstConnectionBackfillJobStatus.pending,
      attemptCount: 0,
      createdAt: _connectedAt,
      updatedAt: _connectedAt,
    );
    jobs.add(job);
    return job;
  }
}

class _FixtureBackfillJobStore implements BackfillJobStore {
  _FixtureBackfillJobStore(List<FirstConnectionBackfillJob> jobs)
    : _jobs = List<FirstConnectionBackfillJob>.of(jobs);

  final List<FirstConnectionBackfillJob> _jobs;
  final List<String> succeeded = <String>[];
  final List<String> failed = <String>[];

  @override
  Future<FirstConnectionBackfillJob?> claimNext({
    required String operatorId,
    required String locationId,
    required String workerId,
    String? actorUserId,
    Duration claimStaleAfter = const Duration(minutes: 15),
  }) async {
    if (_jobs.isEmpty) return null;
    return _jobs.removeAt(0);
  }

  @override
  Future<FirstConnectionBackfillJob?> markSucceeded({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? actorUserId,
  }) async {
    succeeded.add(jobId);
    return null;
  }

  @override
  Future<FirstConnectionBackfillJob?> markFailed({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String errorMessage,
    String? actorUserId,
  }) async {
    failed.add(jobId);
    return null;
  }

  @override
  Future<FirstConnectionBackfillJob?> releaseForResume({
    required String operatorId,
    required String locationId,
    required String jobId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? errorMessage,
    String? actorUserId,
  }) async => null;
}

class _RecordingCanonicalSink implements CanonicalSink {
  final List<Map<String, Object?>> coverFacts = <Map<String, Object?>>[];
  final List<Map<String, Object?>> laborPunches = <Map<String, Object?>>[];
  final List<Map<String, Object?>> reservationFacts = <Map<String, Object?>>[];
  final List<String> watermarkAdvances = <String>[];
  final List<String> syncLogs = <String>[];
  final List<IntegrationCategory> demoFlips = <IntegrationCategory>[];

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async {
    coverFacts.add(canonicalFact);
    return true;
  }

  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) async {
    laborPunches.add(canonicalPunch);
    return true;
  }

  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) async {
    reservationFacts.add(canonicalReservation);
    return true;
  }

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) async {
    watermarkAdvances.add('$connectionId:$cursorToken');
  }

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) async {
    syncLogs.add('$connectionId:$eventKind:${recordsCount ?? 0}');
  }

  @override
  Future<void> evaluateDemoFlip({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required ConnectionStatus connectionStatus,
    required bool firstBackfillCommitted,
    required int backfillRecordsWritten,
    required String connectionId,
  }) async {
    if (connectionStatus == ConnectionStatus.connected &&
        firstBackfillCommitted &&
        backfillRecordsWritten > 0) {
      demoFlips.add(category);
    }
  }
}

class _FixturePosBackfillAdapter implements PosAdapter {
  _FixturePosBackfillAdapter({
    required this.sink,
    required this.recordsWritten,
    required this.cursorToken,
  });

  final _RecordingCanonicalSink sink;
  final int recordsWritten;
  final String cursorToken;

  @override
  String get vendorId => 'lightspeed_lsk';

  @override
  String get displayName => 'Fixture POS';

  @override
  VendorCapabilityProfile get capabilityProfile => _profile(
    vendorId: vendorId,
    displayName: displayName,
    category: IntegrationCategory.pos,
    authMode: VendorAuthMode.oauth,
    webhookSupport: VendorWebhookSupport.autoRegister,
    coversFieldExposed: true,
  );

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    await command.sanityHook(
      vendorEventId: 'pos-fixture-1',
      payload: const <String, Object?>{},
      isDeliberateBackfill: false,
    );
    for (var i = 0; i < recordsWritten; i += 1) {
      await sink.upsertCoverFact(
        operatorId: command.operatorId,
        locationId: command.locationId,
        canonicalFact: <String, Object?>{
          'fact_type': 'cover_fact',
          'operator_id': command.operatorId,
          'location_id': command.locationId,
          'vendor_id': vendorId,
          'vendor_entity_id': 'pos-$i',
          'business_date': '2026-05-06',
          'service_period_key': 'dinner',
          'covers': 40 + i,
        },
      );
    }
    return BackfillResult(
      batchesCommitted: recordsWritten == 0 ? 0 : 1,
      recordsWritten: recordsWritten,
      cursorToken: cursorToken,
      lastModifiedSeen: DateTime.utc(2026, 5, 6, 12, 5),
    );
  }

  @override
  Future<ConnectResult> connect(ConnectCommand command) =>
      throw UnimplementedError();

  @override
  Future<TestConnectionResult> testConnection(TestConnectionCommand command) =>
      throw UnimplementedError();

  @override
  Future<PollIncrementalResult> pollIncremental(
    PollIncrementalCommand command,
  ) => throw UnimplementedError();

  @override
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command) =>
      throw UnimplementedError();

  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) =>
      throw UnimplementedError();
}

class _FixtureLaborBackfillAdapter implements LaborAdapter {
  _FixtureLaborBackfillAdapter({
    required this.sink,
    required this.recordsWritten,
    required this.cursorToken,
  });

  final _RecordingCanonicalSink sink;
  final int recordsWritten;
  final String cursorToken;

  @override
  String get vendorId => 'seven_shifts';

  @override
  String get displayName => 'Fixture Labor';

  @override
  VendorCapabilityProfile get capabilityProfile => _profile(
    vendorId: vendorId,
    displayName: displayName,
    category: IntegrationCategory.labor,
    authMode: VendorAuthMode.oauth,
    webhookSupport: VendorWebhookSupport.autoRegister,
    coversFieldExposed: false,
  );

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    await command.sanityHook(
      vendorEventId: 'labor-fixture-1',
      payload: const <String, Object?>{},
      isDeliberateBackfill: false,
    );
    for (var i = 0; i < recordsWritten; i += 1) {
      await sink.upsertLaborPunch(
        operatorId: command.operatorId,
        locationId: command.locationId,
        canonicalPunch: <String, Object?>{
          'fact_type': 'labor_punch',
          'operator_id': command.operatorId,
          'location_id': command.locationId,
          'vendor_id': vendorId,
          'vendor_entity_id': 'labor-$i',
          'business_date': '2026-05-06',
          'service_period_key': 'dinner',
          'actual_foh_hours': 10 + i,
        },
      );
    }
    return BackfillResult(
      batchesCommitted: 1,
      recordsWritten: recordsWritten,
      cursorToken: cursorToken,
      lastModifiedSeen: DateTime.utc(2026, 5, 6, 12, 6),
    );
  }

  @override
  Future<ConnectResult> connect(ConnectCommand command) =>
      throw UnimplementedError();

  @override
  Future<TestConnectionResult> testConnection(TestConnectionCommand command) =>
      throw UnimplementedError();

  @override
  Future<PollIncrementalResult> pollIncremental(
    PollIncrementalCommand command,
  ) => throw UnimplementedError();

  @override
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command) =>
      throw UnimplementedError();

  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) =>
      throw UnimplementedError();
}

class _FixtureReservationBackfillAdapter implements ReservationAdapter {
  _FixtureReservationBackfillAdapter({
    required this.sink,
    required this.recordsWritten,
    required this.cursorToken,
  });

  final _RecordingCanonicalSink sink;
  final int recordsWritten;
  final String cursorToken;

  @override
  String get vendorId => 'libro';

  @override
  String get displayName => 'Fixture Reservations';

  @override
  VendorCapabilityProfile get capabilityProfile => _profile(
    vendorId: vendorId,
    displayName: displayName,
    category: IntegrationCategory.reservation,
    authMode: VendorAuthMode.oauth,
    webhookSupport: VendorWebhookSupport.autoRegister,
    coversFieldExposed: true,
  );

  @override
  Future<BackfillResult> backfill(BackfillCommand command) async {
    await command.sanityHook(
      vendorEventId: 'reservation-fixture-1',
      payload: const <String, Object?>{},
      isDeliberateBackfill: false,
    );
    for (var i = 0; i < recordsWritten; i += 1) {
      await sink.upsertReservationFact(
        operatorId: command.operatorId,
        locationId: command.locationId,
        canonicalReservation: <String, Object?>{
          'fact_type': 'reservation_fact',
          'operator_id': command.operatorId,
          'location_id': command.locationId,
          'vendor_id': vendorId,
          'vendor_entity_id': 'reservation-$i',
          'business_date': '2026-05-06',
          'service_period_key': 'dinner',
          'covers': 6,
        },
      );
    }
    return BackfillResult(
      batchesCommitted: 1,
      recordsWritten: recordsWritten,
      cursorToken: cursorToken,
      lastModifiedSeen: DateTime.utc(2026, 5, 6, 12, 7),
    );
  }

  @override
  Future<ConnectResult> connect(ConnectCommand command) =>
      throw UnimplementedError();

  @override
  Future<TestConnectionResult> testConnection(TestConnectionCommand command) =>
      throw UnimplementedError();

  @override
  Future<PollIncrementalResult> pollIncremental(
    PollIncrementalCommand command,
  ) => throw UnimplementedError();

  @override
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command) =>
      throw UnimplementedError();

  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) =>
      throw UnimplementedError();
}

class _PostCommitFixture {
  _PostCommitFixture()
    : closedWriter = _FixtureClosedWriter(),
      openProjector = _FixtureOpenProjector() {
    projector = CanonicalFactPostCommitProjector(
      closedAggregator: _FixtureClosedAggregator(),
      targetSnapshotResolver: _FixtureTargetResolver(),
      closedWriter: closedWriter,
      openProjector: openProjector,
    );
  }

  late final CanonicalFactPostCommitProjector projector;
  final _FixtureClosedWriter closedWriter;
  final _FixtureOpenProjector openProjector;
}

class _FixtureClosedAggregator implements ClosedShiftPostCommitAggregator {
  @override
  Future<AggregatorResult?> aggregate(
    CanonicalFactCommittedPeriod period,
  ) async {
    return AggregatorResult(
      input: ClosedShiftInput(
        restaurantId: _restaurantId,
        businessDate: period.businessDateAsDateTime,
        weekId: period.weekId,
        dayLabel: period.dayLabel,
        daypart: 'dinner',
        businessTimingProfileId: _profileId,
        businessTimingProfileVersionId: _profileId,
        servicePeriodKey: period.servicePeriodKey,
        covers: 86,
        forecastCovers: 82,
        actualSales: 4200,
        actualFohHours: 22,
        actualBohHours: 31,
        actualFohLaborDollars: 440,
        actualBohLaborDollars: 744,
        sourceSystem: 'fixture',
      ),
      provenance: const AggregatorProvenanceContext(
        coversProvenance: 'vendor_lightspeed_lsk',
        laborDollarsProvenance: 'vendor_seven_shifts',
        priorTargetProfileVersionId: 'target-prior',
        hasPriorShiftRecord: true,
        priorBusinessTimingProfileId: _profileId,
        priorBusinessTimingProfileVersionId: _profileId,
        priorServicePeriodKey: 'dinner',
      ),
    );
  }
}

class _FixtureTargetResolver implements ClosedShiftTargetSnapshotResolver {
  @override
  Future<TargetSnapshot> resolveTargetSnapshot({
    required CanonicalFactPostCommitInput input,
    required CanonicalFactCommittedPeriod period,
    required AggregatorResult aggregateResult,
  }) async {
    return const TargetSnapshot(
      restaurantId: _restaurantId,
      targetProfileId: 'target-current',
      targetProfileVersionId: 'target-current-v1',
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
  }
}

class _FixtureClosedWriter implements ClosedShiftPostCommitWriter {
  final List<ShiftFact> rows = <ShiftFact>[];

  @override
  Future<void> write({
    required String operatorId,
    required String locationId,
    required ShiftFact shiftFact,
    required AggregatorProvenanceContext provenance,
  }) async {
    rows.add(shiftFact);
  }
}

class _FixtureOpenProjector implements OpenShiftPostCommitProjector {
  final List<CanonicalFactPostCommitInput> calls =
      <CanonicalFactPostCommitInput>[];

  @override
  Future<OpenShiftProjectionResult> project({
    required CanonicalFactPostCommitInput input,
    required Iterable<CanonicalFactCommittedPeriod> periods,
  }) async {
    calls.add(input);
    return OpenShiftProjectionResult.projected(
      businessDate: '2026-05-06',
      snapshotsUpserted: 1,
      servicePeriodSnapshotsUpserted: 1,
      ignoredFacts: 0,
      servicePeriodKeys: const <String>['dinner'],
    );
  }
}

class _MobileCacheFixture {
  final List<ShiftFact> _closedRows = <ShiftFact>[];

  int get closedRowsVisible => _closedRows.length;

  void pullClosedRows(List<ShiftFact> rows) {
    _closedRows.addAll(rows);
  }
}

FirstConnectionBackfillJob _job({
  required String jobId,
  required String connectionId,
  required String vendorId,
  required IntegrationCategory category,
}) {
  final window = FirstConnectionBackfillWindow.lastSixtyDays(_connectedAt);
  return FirstConnectionBackfillJob(
    jobId: jobId,
    operatorId: _operatorId,
    locationId: _locationId,
    connectionId: connectionId,
    vendorId: vendorId,
    category: category,
    windowStart: window.windowStart,
    windowEnd: window.windowEnd,
    status: FirstConnectionBackfillJobStatus.running,
    attemptCount: 1,
    createdAt: _connectedAt,
    updatedAt: _connectedAt,
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
    vendorId: 'lightspeed_lsk',
    connectionId: '00000000-0000-4000-8000-0000000000c1',
    changedPeriods: periods,
    openCurrentFactMaps: openCurrentFacts,
    userId: _actorUserId,
  );
}

CanonicalFactCommittedPeriod _period({
  CanonicalFactPeriodState state = CanonicalFactPeriodState.completed,
}) {
  return CanonicalFactCommittedPeriod(
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    businessDate: '2026-05-06',
    weekId: '2026-W19',
    dayLabel: 'Wed',
    servicePeriodKey: 'dinner',
    servicePeriodDefinition: const ServicePeriodDefinition(
      id: 'dinner',
      label: 'Dinner',
      shortLabel: 'D',
      sortOrder: 2,
      startLocalTime: '17:00',
      endLocalTime: '22:00',
      rollsPastMidnight: false,
      applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
    ),
    state: state,
    businessTimingProfileId: _profileId,
    businessTimingProfileVersionId: _profileId,
  );
}

VendorCapabilityProfile _profile({
  required String vendorId,
  required String displayName,
  required IntegrationCategory category,
  required VendorAuthMode authMode,
  required VendorWebhookSupport webhookSupport,
  required bool coversFieldExposed,
}) {
  return VendorCapabilityProfile(
    vendorId: vendorId,
    displayName: displayName,
    category: category,
    authMode: authMode,
    grantScope: VendorGrantScope.perLocation,
    webhookSupport: webhookSupport,
    coversFieldExposed: coversFieldExposed,
    lifecycle: VendorLifecycle.documented,
  );
}

void _check(bool condition, String message) {
  if (!condition) {
    throw StateError('First-connection backfill proof failed: $message');
  }
}
