// Phase 8 `8.post-commit-projector-wire-in` — wrapper contract tests.
//
// Covers the contract from the slice prompt:
//   * Happy: write via projecting sink → underlying writes + projector
//     fires once after commit signal with the just-written facts.
//   * Underlying sink throws → projector NOT invoked.
//   * Projector throws → underlying write succeeded; warning surfaced;
//     wrapper does not propagate the failure.
//   * Operator-scope: projector receives the same tenant tuple the
//     underlying sink saw.
//   * Re-projecting the same period identity is deduped before the
//     projector sees it (the projector class itself dedupes; the
//     wrapper makes the dedupe deterministic by suppressing duplicate
//     period identities accumulated within a batch).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/aggregator_provenance_context.dart';
import 'package:forge_and_flow/domain/models/closed_shift_input.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/models/shift_fact.dart';
import 'package:forge_and_flow/domain/models/target_snapshot.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_post_commit_projector.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_projection_retry.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_to_closed_shift_input.dart';
import 'package:forge_and_flow/services/integration/canonical_sink.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/open_shift_snapshot_projector.dart';
import 'package:forge_and_flow/services/integration/projecting_canonical_sink.dart';

const String _operatorA = '11111111-1111-1111-1111-111111111111';
const String _operatorB = '99999999-9999-9999-9999-999999999999';
const String _locationA = '22222222-2222-2222-2222-222222222222';
const String _locationB = '88888888-8888-8888-8888-888888888888';
const String _connectionA = '33333333-3333-3333-3333-333333333333';
const String _restaurantA = 'restaurant-A';
const String _restaurantB = 'restaurant-B';
const String _profileId = '44444444-4444-4444-4444-444444444444';

void main() {
  group('ProjectingCanonicalSink', () {
    test(
      'happy path: upserts forwarded, projector fires once on backfill_success',
      () async {
        final underlying = _RecordingCanonicalSink();
        final projector = _RecordingProjector();
        final wrapper = _wrapper(underlying: underlying, projector: projector);

        final wrote = await wrapper.upsertCoverFact(
          operatorId: _operatorA,
          locationId: _locationA,
          canonicalFact: _coverFact(connectionId: _connectionA),
        );

        expect(
          wrote,
          isTrue,
          reason: 'wrapper forwards underlying boolean verbatim',
        );
        expect(underlying.coverFacts, hasLength(1));
        expect(
          projector.invocations,
          isEmpty,
          reason: 'no projection until commit signal arrives',
        );

        await wrapper.appendSyncLog(
          operatorId: _operatorA,
          locationId: _locationA,
          connectionId: _connectionA,
          eventKind: 'backfill_success',
          recordsCount: 1,
        );

        expect(
          projector.invocations,
          hasLength(1),
          reason: 'commit signal drains the buffer once',
        );
        final invocation = projector.invocations.single;
        expect(invocation.operatorId, _operatorA);
        expect(invocation.locationId, _locationA);
        expect(invocation.connectionId, _connectionA);
        expect(invocation.changedPeriods, hasLength(1));
        expect(invocation.changedPeriods.single.servicePeriodKey, 'dinner');
      },
    );

    test(
      'real vendor maps without connection_id still drain on commit signal',
      () async {
        final underlying = _RecordingCanonicalSink();
        final projector = _RecordingProjector();
        final resolvedFacts = <Map<String, Object?>>[];
        final wrapper = _wrapper(
          underlying: underlying,
          projector: projector,
          periodResolver:
              ({
                required String operatorId,
                required String locationId,
                required IntegrationCategory category,
                required String vendorId,
                required String connectionId,
                required Map<String, Object?> canonicalFact,
              }) {
                resolvedFacts.add(canonicalFact);
                return _stubResolver(
                  operatorId: operatorId,
                  locationId: locationId,
                  category: category,
                  vendorId: vendorId,
                  connectionId: connectionId,
                  canonicalFact: canonicalFact,
                );
              },
        );
        final fact = Map<String, Object?>.of(
          _coverFact(connectionId: _connectionA),
        )..remove('connection_id');

        await wrapper.upsertCoverFact(
          operatorId: _operatorA,
          locationId: _locationA,
          canonicalFact: fact,
        );
        await wrapper.appendSyncLog(
          operatorId: _operatorA,
          locationId: _locationA,
          connectionId: _connectionA,
          eventKind: 'poll_success',
          recordsCount: 1,
        );

        expect(projector.invocations, hasLength(1));
        expect(projector.invocations.single.connectionId, _connectionA);
        expect(resolvedFacts.single['operator_id'], _operatorA);
        expect(resolvedFacts.single['location_id'], _locationA);
        expect(resolvedFacts.single['fact_type'], 'cover_fact');
        expect(resolvedFacts.single['source_system'], 'toast');
      },
    );

    test(
      'webhook_received drains the wrapper buffer as a commit signal',
      () async {
        final underlying = _RecordingCanonicalSink();
        final projector = _RecordingProjector();
        final wrapper = _wrapper(underlying: underlying, projector: projector);

        await wrapper.upsertCoverFact(
          operatorId: _operatorA,
          locationId: _locationA,
          canonicalFact: _coverFact(connectionId: _connectionA),
        );
        await wrapper.appendSyncLog(
          operatorId: _operatorA,
          locationId: _locationA,
          connectionId: _connectionA,
          eventKind: 'webhook_received',
          recordsCount: 1,
        );

        expect(projector.invocations, hasLength(1));
        expect(projector.invocations.single.connectionId, _connectionA);
      },
    );

    test('direct projection tap drains on webhook_received', () async {
      final projector = _RecordingProjector();
      final tap = BufferedCanonicalFactProjectionTap(
        projector: projector,
        category: IntegrationCategory.pos,
        vendorId: 'toast',
        periodResolver: _stubResolver,
        restaurantIdResolver: _stubRestaurantResolver,
      );
      final drainer = CanonicalFactProjectionCommitDrainer(
        tapsByVendor: <String, CanonicalFactProjectionTap>{'toast': tap},
      );

      tap.recordCommittedCoverFact(
        operatorId: _operatorA,
        locationId: _locationA,
        canonicalFact: _coverFact(connectionId: _connectionA),
      );
      await drainer.drainIfCommitEvent(
        vendorId: 'toast',
        operatorId: _operatorA,
        locationId: _locationA,
        connectionId: _connectionA,
        eventKind: 'webhook_received',
      );

      expect(projector.invocations, hasLength(1));
      expect(projector.invocations.single.changedPeriods, hasLength(1));
    });

    test(
      'underlying sink throwing short-circuits before projector fires',
      () async {
        final underlying = _ThrowingCanonicalSink();
        final projector = _RecordingProjector();
        final wrapper = _wrapper(underlying: underlying, projector: projector);

        await expectLater(
          wrapper.upsertCoverFact(
            operatorId: _operatorA,
            locationId: _locationA,
            canonicalFact: _coverFact(connectionId: _connectionA),
          ),
          throwsA(isA<StateError>()),
        );

        await wrapper.appendSyncLog(
          operatorId: _operatorA,
          locationId: _locationA,
          connectionId: _connectionA,
          eventKind: 'backfill_success',
        );

        expect(
          projector.invocations,
          isEmpty,
          reason: 'underlying throw means no fact buffered, no projection',
        );
      },
    );

    test(
      'projector throwing is logged as warning and does not propagate',
      () async {
        final underlying = _RecordingCanonicalSink();
        final projector = _RecordingProjector(throwOnNextProject: true);
        final wrapper = _wrapper(underlying: underlying, projector: projector);

        // Underlying write must succeed regardless of projector failure.
        final wrote = await wrapper.upsertCoverFact(
          operatorId: _operatorA,
          locationId: _locationA,
          canonicalFact: _coverFact(connectionId: _connectionA),
        );
        expect(wrote, isTrue);

        // Commit signal triggers projector; projector throws; wrapper
        // must catch the failure and log without re-throwing.
        await expectLater(
          wrapper.appendSyncLog(
            operatorId: _operatorA,
            locationId: _locationA,
            connectionId: _connectionA,
            eventKind: 'backfill_success',
          ),
          completes,
          reason: 'projector failure must not propagate to caller',
        );

        expect(
          projector.invocations,
          hasLength(1),
          reason: 'projector was invoked once before throwing',
        );
        expect(
          underlying.syncLogs,
          hasLength(1),
          reason: 'underlying syncLog write occurred regardless of projector',
        );
      },
    );

    test('projector failure records durable retry input', () async {
      final underlying = _RecordingCanonicalSink();
      final projector = _RecordingProjector(throwOnNextProject: true);
      final retryRecorder = _RecordingProjectionRetryRecorder();
      final wrapper = _wrapper(
        underlying: underlying,
        projector: projector,
        retryRecorder: retryRecorder,
      );

      await wrapper.upsertCoverFact(
        operatorId: _operatorA,
        locationId: _locationA,
        canonicalFact: _coverFact(connectionId: _connectionA),
      );
      await expectLater(
        wrapper.appendSyncLog(
          operatorId: _operatorA,
          locationId: _locationA,
          connectionId: _connectionA,
          eventKind: 'backfill_success',
        ),
        completes,
      );

      expect(retryRecorder.records, hasLength(1));
      final record = retryRecorder.records.single;
      expect(record.operatorId, _operatorA);
      expect(record.locationId, _locationA);
      expect(record.connectionId, _connectionA);
      expect(record.changedPeriods, hasLength(1));
      expect(record.openCurrentFactMaps, isEmpty);
      expect(record.errorMessage, contains('projector blew up'));
      expect(record.toInput().changedPeriods.single.servicePeriodKey, 'dinner');
    });

    test(
      'per-tenant buffers do not cross operator/location/connection',
      () async {
        final underlying = _RecordingCanonicalSink();
        final projector = _RecordingProjector();
        final wrapper = _wrapper(underlying: underlying, projector: projector);

        // Write into (operatorA, locationA, connectionA).
        await wrapper.upsertCoverFact(
          operatorId: _operatorA,
          locationId: _locationA,
          canonicalFact: _coverFact(connectionId: _connectionA),
        );
        // Write into a different tenant — same wrapper instance.
        await wrapper.upsertCoverFact(
          operatorId: _operatorB,
          locationId: _locationB,
          canonicalFact: _coverFact(connectionId: 'connection-B'),
        );

        // Drain only the first tenant's buffer.
        await wrapper.appendSyncLog(
          operatorId: _operatorA,
          locationId: _locationA,
          connectionId: _connectionA,
          eventKind: 'backfill_success',
        );

        expect(projector.invocations, hasLength(1));
        final invocation = projector.invocations.single;
        expect(invocation.operatorId, _operatorA);
        expect(invocation.locationId, _locationA);
        expect(invocation.connectionId, _connectionA);
        expect(
          invocation.changedPeriods,
          hasLength(1),
          reason: 'B tenant facts must not leak into A drain',
        );

        // Drain B tenant — separate invocation, separate scope.
        await wrapper.appendSyncLog(
          operatorId: _operatorB,
          locationId: _locationB,
          connectionId: 'connection-B',
          eventKind: 'backfill_success',
        );
        expect(projector.invocations, hasLength(2));
        expect(projector.invocations.last.operatorId, _operatorB);
      },
    );

    test('duplicate period identities within a batch are deduped', () async {
      final underlying = _RecordingCanonicalSink();
      final projector = _RecordingProjector();
      final wrapper = _wrapper(underlying: underlying, projector: projector);

      // Two facts for the same business_date + service_period_key →
      // same period identity. The wrapper must dedupe before passing
      // periods to the projector.
      await wrapper.upsertCoverFact(
        operatorId: _operatorA,
        locationId: _locationA,
        canonicalFact: _coverFact(connectionId: _connectionA),
      );
      await wrapper.upsertCoverFact(
        operatorId: _operatorA,
        locationId: _locationA,
        canonicalFact: _coverFact(
          connectionId: _connectionA,
          vendorEntityId: 'pos-2',
        ),
      );

      await wrapper.appendSyncLog(
        operatorId: _operatorA,
        locationId: _locationA,
        connectionId: _connectionA,
        eventKind: 'backfill_success',
      );

      expect(projector.invocations, hasLength(1));
      expect(
        projector.invocations.single.changedPeriods,
        hasLength(1),
        reason:
            'same (business_date, service_period_key) fact pair → one period',
      );
    });

    test(
      'non-commit appendSyncLog event kinds do not drain the buffer',
      () async {
        final underlying = _RecordingCanonicalSink();
        final projector = _RecordingProjector();
        final wrapper = _wrapper(underlying: underlying, projector: projector);

        await wrapper.upsertCoverFact(
          operatorId: _operatorA,
          locationId: _locationA,
          canonicalFact: _coverFact(connectionId: _connectionA),
        );
        await wrapper.appendSyncLog(
          operatorId: _operatorA,
          locationId: _locationA,
          connectionId: _connectionA,
          eventKind: 'poll_error',
          errorMessage: 'transient timeout',
        );

        expect(
          projector.invocations,
          isEmpty,
          reason: 'poll_error is not a commit signal',
        );

        // Subsequent commit signal still flushes the buffered fact.
        await wrapper.appendSyncLog(
          operatorId: _operatorA,
          locationId: _locationA,
          connectionId: _connectionA,
          eventKind: 'backfill_success',
        );
        expect(projector.invocations, hasLength(1));
      },
    );

    test('flush() drains explicitly without an appendSyncLog call', () async {
      final underlying = _RecordingCanonicalSink();
      final projector = _RecordingProjector();
      final wrapper = _wrapper(underlying: underlying, projector: projector);

      await wrapper.upsertLaborPunch(
        operatorId: _operatorA,
        locationId: _locationA,
        canonicalPunch: _laborPunch(connectionId: _connectionA),
      );
      await wrapper.flush(
        operatorId: _operatorA,
        locationId: _locationA,
        connectionId: _connectionA,
      );

      expect(projector.invocations, hasLength(1));
      expect(
        projector.invocations.single.changedPeriods.single.servicePeriodKey,
        'dinner',
      );
    });

    test('underlying upsert returning false (idempotency replay) does not '
        'accumulate the fact', () async {
      final underlying = _RecordingCanonicalSink(returnFalseOnUpsert: true);
      final projector = _RecordingProjector();
      final wrapper = _wrapper(underlying: underlying, projector: projector);

      final wrote = await wrapper.upsertCoverFact(
        operatorId: _operatorA,
        locationId: _locationA,
        canonicalFact: _coverFact(connectionId: _connectionA),
      );
      expect(
        wrote,
        isFalse,
        reason:
            'underlying signalled idempotency replay; wrapper forwards verbatim',
      );
      await wrapper.flush(
        operatorId: _operatorA,
        locationId: _locationA,
        connectionId: _connectionA,
      );
      expect(
        projector.invocations,
        isEmpty,
        reason: 'replays must not retrigger projection',
      );
    });

    test('re-projecting identical periods across drains is deduped by the '
        'projector itself (smoke)', () async {
      final underlying = _RecordingCanonicalSink();
      // Wrap the real CanonicalFactPostCommitProjector so we exercise
      // the dedupe in `_dedupePeriods`.
      final closedAggregator = _FakeClosedAggregator();
      final realProjector = CanonicalFactPostCommitProjector(
        closedAggregator: closedAggregator,
        targetSnapshotResolver: _FakeTargetResolver(),
        closedWriter: _FakeClosedWriter(),
        openProjector: _FakeOpenProjector(),
      );
      final wrapper = ProjectingCanonicalSink(
        underlying: underlying,
        projector: realProjector,
        category: IntegrationCategory.pos,
        vendorId: 'toast',
        periodResolver: _stubResolver,
        restaurantIdResolver: _stubRestaurantResolver,
      );

      await wrapper.upsertCoverFact(
        operatorId: _operatorA,
        locationId: _locationA,
        canonicalFact: _coverFact(connectionId: _connectionA),
      );
      await wrapper.upsertCoverFact(
        operatorId: _operatorA,
        locationId: _locationA,
        canonicalFact: _coverFact(
          connectionId: _connectionA,
          vendorEntityId: 'pos-2',
        ),
      );
      await wrapper.flush(
        operatorId: _operatorA,
        locationId: _locationA,
        connectionId: _connectionA,
      );

      expect(
        closedAggregator.calls,
        hasLength(1),
        reason:
            'duplicate (business_date, service_period_key) facts collapse '
            'to a single aggregator call',
      );
    });
  });
}

ProjectingCanonicalSink _wrapper({
  required CanonicalSink underlying,
  required _RecordingProjector projector,
  CanonicalFactPeriodResolver? periodResolver,
  CanonicalFactProjectionRetryRecorder? retryRecorder,
}) {
  return ProjectingCanonicalSink(
    underlying: underlying,
    projector: projector,
    category: IntegrationCategory.pos,
    vendorId: 'toast',
    periodResolver: periodResolver ?? _stubResolver,
    restaurantIdResolver: _stubRestaurantResolver,
    retryRecorder: retryRecorder,
  );
}

FutureOr<CanonicalFactCommittedPeriod?> _stubResolver({
  required String operatorId,
  required String locationId,
  required IntegrationCategory category,
  required String vendorId,
  required String connectionId,
  required Map<String, Object?> canonicalFact,
}) {
  final businessDate = canonicalFact['business_date'] as String?;
  final servicePeriodKey = canonicalFact['service_period_key'] as String?;
  if (businessDate == null || servicePeriodKey == null) {
    return null;
  }
  return CanonicalFactCommittedPeriod(
    operatorId: operatorId,
    locationId: locationId,
    restaurantId: operatorId == _operatorB ? _restaurantB : _restaurantA,
    businessDate: businessDate,
    weekId: '2026-W19',
    dayLabel: 'Wed',
    servicePeriodKey: servicePeriodKey,
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
    state: CanonicalFactPeriodState.completed,
    businessTimingProfileId: _profileId,
    businessTimingProfileVersionId: _profileId,
  );
}

FutureOr<String> _stubRestaurantResolver({
  required String operatorId,
  required String locationId,
}) {
  return operatorId == _operatorB ? _restaurantB : _restaurantA;
}

Map<String, Object?> _coverFact({
  required String connectionId,
  String vendorEntityId = 'pos-1',
}) {
  return <String, Object?>{
    'fact_type': 'cover_fact',
    'vendor_id': 'toast',
    'vendor_entity_id': vendorEntityId,
    'connection_id': connectionId,
    'business_date': '2026-05-06',
    'service_period_key': 'dinner',
    'covers': 50,
  };
}

Map<String, Object?> _laborPunch({required String connectionId}) {
  return <String, Object?>{
    'fact_type': 'labor_punch',
    'vendor_id': 'toast',
    'vendor_entity_id': 'labor-1',
    'connection_id': connectionId,
    'business_date': '2026-05-06',
    'service_period_key': 'dinner',
    'actual_foh_hours': 8,
  };
}

class _RecordingCanonicalSink implements CanonicalSink {
  _RecordingCanonicalSink({this.returnFalseOnUpsert = false});

  final bool returnFalseOnUpsert;
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
    return !returnFalseOnUpsert;
  }

  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) async {
    laborPunches.add(canonicalPunch);
    return !returnFalseOnUpsert;
  }

  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) async {
    reservationFacts.add(canonicalReservation);
    return !returnFalseOnUpsert;
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
    demoFlips.add(category);
  }
}

class _ThrowingCanonicalSink implements CanonicalSink {
  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async {
    throw StateError('underlying upsert failed');
  }

  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) async {
    throw StateError('underlying upsert failed');
  }

  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) async {
    throw StateError('underlying upsert failed');
  }

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) async {}

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) async {}

  @override
  Future<void> evaluateDemoFlip({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required ConnectionStatus connectionStatus,
    required bool firstBackfillCommitted,
    required int backfillRecordsWritten,
    required String connectionId,
  }) async {}
}

class _RecordingProjector implements CanonicalFactPostCommitProjector {
  _RecordingProjector({this.throwOnNextProject = false});

  bool throwOnNextProject;
  final List<CanonicalFactPostCommitInput> invocations =
      <CanonicalFactPostCommitInput>[];

  @override
  Future<CanonicalFactPostCommitProjectionResult> project(
    CanonicalFactPostCommitInput input,
  ) async {
    invocations.add(input);
    if (throwOnNextProject) {
      throwOnNextProject = false;
      throw StateError('projector blew up');
    }
    return CanonicalFactPostCommitProjectionResult(
      operatorId: input.operatorId,
      locationId: input.locationId,
      integrationCategory: input.integrationCategory,
      vendorId: input.vendorId,
      connectionId: input.connectionId,
      completedPeriodsSeen: input.changedPeriods.length,
      openCurrentPeriodsSeen: 0,
      closedShiftRecordsProjected: input.changedPeriods.length,
      closedPeriodsUnavailable: 0,
      openSnapshotsUpserted: 0,
      openServicePeriodSnapshotsUpserted: 0,
      openProjectionUnavailable: false,
      openProjectionReason: null,
      closedPeriodKeys: <String>[
        for (final p in input.changedPeriods) p.periodIdentity,
      ],
      openPeriodKeys: const <String>[],
    );
  }
}

class _RecordingProjectionRetryRecorder
    implements CanonicalFactProjectionRetryRecorder {
  final records = <CanonicalFactProjectionRetryRecord>[];

  @override
  Future<void> recordProjectionFailure(
    CanonicalFactProjectionRetryRecord record,
  ) async {
    records.add(record);
  }
}

class _FakeClosedAggregator implements ClosedShiftPostCommitAggregator {
  final List<CanonicalFactCommittedPeriod> calls =
      <CanonicalFactCommittedPeriod>[];

  @override
  Future<AggregatorResult?> aggregate(
    CanonicalFactCommittedPeriod period,
  ) async {
    calls.add(period);
    return AggregatorResult(
      input: ClosedShiftInput(
        restaurantId: _restaurantA,
        businessDate: period.businessDateAsDateTime,
        weekId: period.weekId,
        dayLabel: period.dayLabel,
        daypart: 'dinner',
        businessTimingProfileId: _profileId,
        businessTimingProfileVersionId: _profileId,
        servicePeriodKey: period.servicePeriodKey,
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
}

class _FakeTargetResolver implements ClosedShiftTargetSnapshotResolver {
  @override
  Future<TargetSnapshot> resolveTargetSnapshot({
    required CanonicalFactPostCommitInput input,
    required CanonicalFactCommittedPeriod period,
    required AggregatorResult aggregateResult,
  }) async {
    return const TargetSnapshot(
      restaurantId: _restaurantA,
      targetProfileId: 'target-current',
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
  }
}

class _FakeClosedWriter implements ClosedShiftPostCommitWriter {
  @override
  Future<void> write({
    required String operatorId,
    required String locationId,
    required ShiftFact shiftFact,
    required AggregatorProvenanceContext provenance,
  }) async {}
}

class _FakeOpenProjector implements OpenShiftPostCommitProjector {
  @override
  Future<OpenShiftProjectionResult> project({
    required CanonicalFactPostCommitInput input,
    required Iterable<CanonicalFactCommittedPeriod> periods,
  }) async {
    return OpenShiftProjectionResult.projected(
      businessDate: '2026-05-06',
      snapshotsUpserted: 0,
      servicePeriodSnapshotsUpserted: 0,
      ignoredFacts: 0,
      servicePeriodKeys: const <String>[],
    );
  }
}
