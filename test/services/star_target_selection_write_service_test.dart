import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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

AuthSession _session() {
  return AuthSession(
    userId: 'user-1',
    operatorId: 'op-1',
    locationId: 'loc-1',
    firebaseIdToken: 'token',
    issuedAt: DateTime.utc(2026, 5, 6, 11),
    expiresAt: DateTime.utc(2026, 5, 6, 13),
    lastFreshAuthAt: DateTime.utc(2026, 5, 6, 11),
    roles: const <String>['operator_manager'],
    mfaEnrolled: true,
  );
}

BaselineCandidateShift _candidate(
  String recordKey, {
  required bool selected,
  String? businessDate = '2026-05-06',
  String? servicePeriodKey,
}) {
  return BaselineCandidateShift(
    recordKey: recordKey,
    weekId: '2026-W19',
    weekLabel: 'Week 19',
    dayLabel: 'Wednesday',
    daypart: 'dinner',
    servicePeriodKey: servicePeriodKey,
    covers: 120,
    cplh: 12.4,
    splh: 152.0,
    ppa: 42.5,
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
