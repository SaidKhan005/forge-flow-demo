import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/forge_flow_bootstrap.dart'
    show buildStarTargetProjectionDayparts;
import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/models/baseline_candidate_shift.dart';
import 'package:forge_and_flow/services/star_target_selection_write_service.dart';

void main() {
  test(
    'AuthSessionStarTargetSelectionWriter submits clear/select diff',
    () async {
      final client = _RecordingStarTargetSelectionWriteClient();
      final writer = AuthSessionStarTargetSelectionWriter(
        client: client,
        authSessionProvider: () => _session(),
        clock: () => DateTime.utc(2026, 5, 6, 12),
      );

      await writer.replaceSelection(
        restaurantId: 'restaurant-1',
        selectedCandidates: <BaselineCandidateShift>[
          _candidate('new-key', selected: false, servicePeriodKey: 'supper'),
          _candidate('kept-key', selected: true),
        ],
        previouslySelectedCandidates: <BaselineCandidateShift>[
          _candidate('old-key', selected: true),
          _candidate('kept-key', selected: true),
        ],
      );

      expect(client.calls, hasLength(2));
      expect(client.calls[0].action, StarTargetSelectionWriteAction.clear);
      expect(client.calls[0].body['record_key'], 'old-key');
      expect(client.calls[0].body.containsKey('candidate_snapshot'), isFalse);
      expect(client.calls[1].action, StarTargetSelectionWriteAction.select);
      expect(client.calls[1].body['record_key'], 'new-key');
      expect(client.calls[1].body['daypart'], 'dinner');
      expect(client.calls[1].body['service_period_key'], 'supper');
      expect(client.calls[1].body['covers'], 120);
      final snapshot =
          client.calls[1].body['candidate_snapshot'] as Map<String, Object?>;
      expect(snapshot['source'], 'mobile_closed_shift_candidate');
      expect(snapshot['daypart'], 'dinner');
      expect(snapshot['service_period_key'], 'supper');
      expect(client.calls.map((call) => call.operatorId), everyElement('op-1'));
      expect(
        client.calls.map((call) => call.locationId),
        everyElement('loc-1'),
      );
      expect(
        client.calls.map((call) => call.idempotencyKey),
        everyElement(startsWith('mobile-star-')),
      );
    },
  );

  test(
    'AuthSessionStarTargetSelectionWriter clears stable and legacy keys',
    () async {
      final client = _RecordingStarTargetSelectionWriteClient();
      final writer = AuthSessionStarTargetSelectionWriter(
        client: client,
        authSessionProvider: () => _session(),
      );

      await writer.replaceSelection(
        restaurantId: 'restaurant-1',
        selectedCandidates: const <BaselineCandidateShift>[],
        previouslySelectedCandidates: <BaselineCandidateShift>[
          _candidate(
            '2026-05-06|late_night',
            selected: true,
            daypart: 'late_night',
            servicePeriodKey: 'late_night',
          ),
        ],
      );

      expect(client.calls, hasLength(2));
      expect(
        client.calls.map((call) => call.body['record_key']),
        containsAllInOrder(<String>[
          '2026-05-06|late_night',
          '2026-W19|Wednesday|late_night',
        ]),
      );
      expect(
        client.calls.map((call) => call.action),
        everyElement(StarTargetSelectionWriteAction.clear),
      );
    },
  );

  test('AuthSessionStarTargetSelectionWriter requires auth session', () async {
    final writer = AuthSessionStarTargetSelectionWriter(
      client: _RecordingStarTargetSelectionWriteClient(),
      authSessionProvider: () => null,
    );

    expect(
      () => writer.replaceSelection(
        restaurantId: 'restaurant-1',
        selectedCandidates: <BaselineCandidateShift>[
          _candidate('new-key', selected: false),
        ],
        previouslySelectedCandidates: const <BaselineCandidateShift>[],
      ),
      throwsA(
        isA<StarTargetSelectionWriteException>().having(
          (error) => error.code,
          'code',
          'auth_session_required',
        ),
      ),
    );
  });

  test(
    'AuthSessionStarTargetSelectionWriter projects server target after select',
    () async {
      final client = _RecordingStarTargetSelectionWriteClient();
      final writer = AuthSessionStarTargetSelectionWriter(
        client: client,
        authSessionProvider: () => _session(),
        clock: () => DateTime.utc(2026, 5, 6, 12),
        projectionContextProvider:
            ({required restaurantId, required selectedCandidates}) async {
              expect(restaurantId, 'restaurant-1');
              expect(
                selectedCandidates.map((c) => c.recordKey),
                contains('new-key'),
              );
              return const StarTargetProjectionContext(
                effectiveStart: '2026-05-06',
                effectiveEnd: '2026-07-04',
                calibrationWindowStart: '2026-03-08',
                calibrationWindowEnd: '2026-05-06',
                targetCplh: 12.4,
                targetSplh: 152.0,
                targetPpa: 42.5,
                fohWage: 18.0,
                bohWage: 20.0,
                opzFloorCplh: 12.0,
                opzCeilingCplh: 14.0,
                reason: 'manager selected star target on mobile',
              );
            },
      );

      await writer.replaceSelection(
        restaurantId: 'restaurant-1',
        selectedCandidates: <BaselineCandidateShift>[
          _candidate('new-key', selected: false),
        ],
        previouslySelectedCandidates: const <BaselineCandidateShift>[],
      );

      expect(client.calls, hasLength(1));
      expect(client.projections, hasLength(1));
      final projection = client.projections.single;
      expect(projection.operatorId, 'op-1');
      expect(projection.locationId, 'loc-1');
      expect(projection.idempotencyKey, startsWith('mobile-star-project-'));
      expect(projection.body['restaurant_id'], 'restaurant-1');
      expect(projection.body['effective_start'], '2026-05-06');
      expect(
        (projection.body['standards'] as Map<String, Object?>)['target_cplh'],
        12.4,
      );
    },
  );

  test(
    'AuthSessionStarTargetSelectionWriter projects selected service periods',
    () async {
      final client = _RecordingStarTargetSelectionWriteClient();
      final writer = AuthSessionStarTargetSelectionWriter(
        client: client,
        authSessionProvider: () => _session(),
        clock: () => DateTime.utc(2026, 5, 6, 12),
        projectionContextProvider:
            ({required restaurantId, required selectedCandidates}) async {
              return StarTargetProjectionContext(
                effectiveStart: '2026-05-06',
                effectiveEnd: '2026-07-04',
                calibrationWindowStart: '2026-03-08',
                calibrationWindowEnd: '2026-05-06',
                targetCplh: 99.0,
                targetSplh: 199.0,
                targetPpa: 59.0,
                fohWage: 18.0,
                bohWage: 20.0,
                opzFloorCplh: 9.0,
                opzCeilingCplh: 21.0,
                reason: 'manager selected star target on mobile',
                dayparts: buildStarTargetProjectionDayparts(selectedCandidates),
              );
            },
      );

      await writer.replaceSelection(
        restaurantId: 'restaurant-1',
        selectedCandidates: <BaselineCandidateShift>[
          _candidate(
            'brunch-1',
            selected: false,
            daypart: 'morning',
            servicePeriodKey: 'brunch',
            covers: 40,
            cplh: 10.0,
            splh: 100.0,
            ppa: 20.0,
          ),
          _candidate(
            'brunch-2',
            selected: false,
            daypart: 'morning',
            servicePeriodKey: 'brunch',
            covers: 60,
            cplh: 14.0,
            splh: 140.0,
            ppa: 30.0,
          ),
          _candidate(
            'supper-1',
            selected: false,
            daypart: 'dinner',
            servicePeriodKey: 'supper_rush',
            covers: 120,
            cplh: 20.0,
            splh: 220.0,
            ppa: 50.0,
          ),
        ],
        previouslySelectedCandidates: const <BaselineCandidateShift>[],
      );

      expect(client.calls, hasLength(3));
      expect(client.projections, hasLength(1));
      final standards =
          client.projections.single.body['standards'] as Map<String, Object?>;
      expect(standards['target_cplh'], 99.0);
      final dayparts = standards['target_cycle_dayparts'] as List<Object?>;
      expect(dayparts, hasLength(2));
      final brunch = dayparts[0] as Map<String, Object?>;
      expect(brunch['service_period_id'], 'brunch');
      expect(brunch['service_period_key'], 'brunch');
      expect(brunch['target_cplh'], 12.0);
      expect(brunch['target_splh'], 120.0);
      expect(brunch['target_ppa'], 25.0);
      expect(brunch['opz_floor_cplh'], 10.0);
      expect(brunch['opz_ceiling_cplh'], 14.0);
      expect(brunch['cover_count'], 100);
      final supper = dayparts[1] as Map<String, Object?>;
      expect(supper['service_period_id'], 'supper_rush');
      expect(supper['target_cplh'], 20.0);
      expect(supper['cover_count'], 120);
    },
  );

  test('buildStarTargetProjectionDayparts falls back to legacy daypart', () {
    final dayparts = buildStarTargetProjectionDayparts(<BaselineCandidateShift>[
      _candidate('legacy-1', selected: true, daypart: 'midday'),
    ]);

    expect(dayparts, hasLength(1));
    expect(dayparts.single.servicePeriodId, 'midday');
    expect(dayparts.single.servicePeriodKey, 'midday');
    expect(dayparts.single.coverCount, 120);
  });

  group('stable idempotency keys', () {
    test('select action repeats for same body and changes with body', () async {
      final first = await _selectedDecisionKey(
        candidate: _candidate('new-key', selected: false),
        clock: () => DateTime.utc(2026, 5, 6, 12),
      );
      final retry = await _selectedDecisionKey(
        candidate: _candidate('new-key', selected: false),
        clock: () => DateTime.utc(2026, 5, 6, 12, 0, 1),
      );
      final changedBody = await _selectedDecisionKey(
        candidate: _candidate('new-key', selected: false, covers: 121),
        clock: () => DateTime.utc(2026, 5, 6, 12),
      );

      expect(retry, first);
      expect(changedBody, isNot(first));
      expect(first, startsWith('mobile-star-select-'));
      expect(first, isNot(contains('new-key')));
    });

    test('clear action repeats for same body and changes with body', () async {
      final first = await _clearedDecisionKey(
        candidate: _candidate('old-key', selected: true),
        clock: () => DateTime.utc(2026, 5, 6, 12),
      );
      final retry = await _clearedDecisionKey(
        candidate: _candidate('old-key', selected: true),
        clock: () => DateTime.utc(2026, 5, 6, 12, 0, 1),
      );
      final changedBody = await _clearedDecisionKey(
        candidate: _candidate(
          'old-key',
          selected: true,
          servicePeriodKey: 'late-night',
        ),
        clock: () => DateTime.utc(2026, 5, 6, 12),
      );

      expect(retry, first);
      expect(changedBody, isNot(first));
      expect(first, startsWith('mobile-star-clear-'));
      expect(first, isNot(contains('old-key')));
    });

    test('projection repeats for same body and changes with body', () async {
      const context = StarTargetProjectionContext(
        effectiveStart: '2026-05-06',
        effectiveEnd: '2026-07-04',
        calibrationWindowStart: '2026-03-08',
        calibrationWindowEnd: '2026-05-06',
        targetCplh: 12.4,
        targetSplh: 152.0,
        targetPpa: 42.5,
        fohWage: 18.0,
        bohWage: 20.0,
        opzFloorCplh: 12.0,
        opzCeilingCplh: 14.0,
        reason: 'manager selected star target on mobile',
      );
      const changedContext = StarTargetProjectionContext(
        effectiveStart: '2026-05-06',
        effectiveEnd: '2026-07-04',
        calibrationWindowStart: '2026-03-08',
        calibrationWindowEnd: '2026-05-06',
        targetCplh: 12.5,
        targetSplh: 152.0,
        targetPpa: 42.5,
        fohWage: 18.0,
        bohWage: 20.0,
        opzFloorCplh: 12.0,
        opzCeilingCplh: 14.0,
        reason: 'manager selected star target on mobile',
      );

      final first = await _projectionKeyFor(
        context: context,
        clock: () => DateTime.utc(2026, 5, 6, 12),
      );
      final retry = await _projectionKeyFor(
        context: context,
        clock: () => DateTime.utc(2026, 5, 6, 12, 0, 1),
      );
      final changedBody = await _projectionKeyFor(
        context: changedContext,
        clock: () => DateTime.utc(2026, 5, 6, 12),
      );

      expect(retry, first);
      expect(changedBody, isNot(first));
      expect(first, startsWith('mobile-star-project-'));
      expect(first, isNot(contains('restaurant-1')));
    });
  });

  test(
    'AuthSessionStarTargetSelectionWriter rejects candidate without date',
    () async {
      final writer = AuthSessionStarTargetSelectionWriter(
        client: _RecordingStarTargetSelectionWriteClient(),
        authSessionProvider: () => _session(),
      );

      expect(
        () => writer.replaceSelection(
          restaurantId: 'restaurant-1',
          selectedCandidates: <BaselineCandidateShift>[
            _candidate('new-key', selected: false, businessDate: null),
          ],
          previouslySelectedCandidates: const <BaselineCandidateShift>[],
        ),
        throwsA(
          isA<StarTargetSelectionWriteException>().having(
            (error) => error.code,
            'code',
            'candidate_business_date_missing',
          ),
        ),
      );
    },
  );
}

Future<String> _selectedDecisionKey({
  required BaselineCandidateShift candidate,
  required DateTime Function() clock,
}) async {
  final client = _RecordingStarTargetSelectionWriteClient();
  final writer = AuthSessionStarTargetSelectionWriter(
    client: client,
    authSessionProvider: () => _session(),
    clock: clock,
  );

  await writer.replaceSelection(
    restaurantId: 'restaurant-1',
    selectedCandidates: <BaselineCandidateShift>[candidate],
    previouslySelectedCandidates: const <BaselineCandidateShift>[],
  );

  expect(client.calls, hasLength(1));
  return client.calls.single.idempotencyKey;
}

Future<String> _clearedDecisionKey({
  required BaselineCandidateShift candidate,
  required DateTime Function() clock,
}) async {
  final client = _RecordingStarTargetSelectionWriteClient();
  final writer = AuthSessionStarTargetSelectionWriter(
    client: client,
    authSessionProvider: () => _session(),
    clock: clock,
  );

  await writer.replaceSelection(
    restaurantId: 'restaurant-1',
    selectedCandidates: const <BaselineCandidateShift>[],
    previouslySelectedCandidates: <BaselineCandidateShift>[candidate],
  );

  expect(client.calls, hasLength(1));
  return client.calls.single.idempotencyKey;
}

Future<String> _projectionKeyFor({
  required StarTargetProjectionContext context,
  required DateTime Function() clock,
}) async {
  final client = _RecordingStarTargetSelectionWriteClient();
  final writer = AuthSessionStarTargetSelectionWriter(
    client: client,
    authSessionProvider: () => _session(),
    clock: clock,
    projectionContextProvider:
        ({required restaurantId, required selectedCandidates}) async => context,
  );

  await writer.replaceSelection(
    restaurantId: 'restaurant-1',
    selectedCandidates: <BaselineCandidateShift>[
      _candidate('new-key', selected: false),
    ],
    previouslySelectedCandidates: const <BaselineCandidateShift>[],
  );

  expect(client.projections, hasLength(1));
  return client.projections.single.idempotencyKey;
}

AuthSession _session() {
  return AuthSession(
    userId: 'user-1',
    operatorId: 'op-1',
    locationId: 'loc-1',
    firebaseIdToken: 'token',
    issuedAt: DateTime.utc(2026, 5, 6, 11),
    expiresAt: DateTime.utc(2026, 5, 6, 13),
    lastFreshAuthAt: DateTime.utc(2026, 5, 6, 11),
    roles: const <String>['operator_general_manager'],
    mfaEnrolled: true,
  );
}

BaselineCandidateShift _candidate(
  String recordKey, {
  required bool selected,
  String? businessDate = '2026-05-06',
  String daypart = 'dinner',
  String? servicePeriodKey,
  int covers = 120,
  double cplh = 12.4,
  double splh = 152.0,
  double ppa = 42.5,
}) {
  return BaselineCandidateShift(
    recordKey: recordKey,
    weekId: '2026-W19',
    weekLabel: 'Week 19',
    dayLabel: 'Wednesday',
    daypart: daypart,
    servicePeriodKey: servicePeriodKey,
    covers: covers,
    cplh: cplh,
    splh: splh,
    ppa: ppa,
    primaryLeverId: 'labor',
    isSelected: selected,
    businessDate: businessDate,
    actualLaborPct: 21.5,
    hasActualLaborPctTruth: true,
  );
}

class _RecordingStarTargetSelectionWriteClient
    implements StarTargetSelectionWriteClient {
  final calls =
      <
        ({
          String operatorId,
          String locationId,
          StarTargetSelectionWriteAction action,
          String idempotencyKey,
          Map<String, Object?> body,
        })
      >[];
  final projections =
      <
        ({
          String operatorId,
          String locationId,
          String idempotencyKey,
          Map<String, Object?> body,
        })
      >[];

  @override
  Future<void> submitSelectedStarDecision({
    required String operatorId,
    required String locationId,
    required StarTargetSelectionWriteAction action,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    calls.add((
      operatorId: operatorId,
      locationId: locationId,
      action: action,
      idempotencyKey: idempotencyKey,
      body: jsonDecode(jsonEncode(body)) as Map<String, Object?>,
    ));
  }

  @override
  Future<void> submitSelectedStarTargetProjection({
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    projections.add((
      operatorId: operatorId,
      locationId: locationId,
      idempotencyKey: idempotencyKey,
      body: jsonDecode(jsonEncode(body)) as Map<String, Object?>,
    ));
  }
}
