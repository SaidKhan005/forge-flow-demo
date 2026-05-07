import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/active_target_profile_repository.dart'
    as active_profile_pg;
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/target_cycle_repository.dart'
    as target_cycle_pg;
import 'package:forge_and_flow/models/baseline_candidate_shift.dart';
import 'package:forge_and_flow/services/server_target_cycle_projection_service.dart';
import 'package:forge_and_flow/services/star_target_selection_write_service.dart';

Future<void> main() async {
  final server = _HarnessStarTargetServer();
  final writer = AuthSessionStarTargetSelectionWriter(
    client: server,
    authSessionProvider: () => _session,
    clock: () => _fixedNow,
  );
  final evidence = <String, Object?>{};

  await server.submitSelectedStarDecision(
    operatorId: _operatorId,
    locationId: _locationId,
    action: StarTargetSelectionWriteAction.select,
    idempotencyKey: 'select-after-clear',
    body: _serverBody(_candidateA),
  );
  _expect(server.currentRecordKeys, _contains(_candidateA.recordKey));
  evidence['selection_visible_on_second_device'] = server.deviceSnapshot();

  await server.submitSelectedStarDecision(
    operatorId: _operatorId,
    locationId: _locationId,
    action: StarTargetSelectionWriteAction.select,
    idempotencyKey: 'retry-idem',
    body: _serverBody(_candidateB),
  );
  final afterFirstRetryWrite = server.decisionCount;
  await server.submitSelectedStarDecision(
    operatorId: _operatorId,
    locationId: _locationId,
    action: StarTargetSelectionWriteAction.select,
    idempotencyKey: 'retry-idem',
    body: _serverBody(_candidateB),
  );
  _expect(server.decisionCount, afterFirstRetryWrite);
  evidence['idempotent_retry_decision_count'] = server.decisionCount;

  await writer.replaceSelection(
    restaurantId: _restaurantId,
    selectedCandidates: const <BaselineCandidateShift>[],
    previouslySelectedCandidates: <BaselineCandidateShift>[_candidateA],
  );
  _expect(server.currentRecordKeys.contains(_candidateA.recordKey), _isFalse);
  evidence['clear_visible_on_second_device'] = server.deviceSnapshot();

  server.denyWrites = true;
  try {
    await writer.replaceSelection(
      restaurantId: _restaurantId,
      selectedCandidates: <BaselineCandidateShift>[_candidateA],
      previouslySelectedCandidates: const <BaselineCandidateShift>[],
    );
    throw StateError('permission denial did not throw');
  } on StarTargetSelectionWriteException catch (error) {
    _expect(error.code, 'permission_denied');
  }
  _expect(server.currentRecordKeys.contains(_candidateA.recordKey), _isFalse);
  evidence['permission_denial_left_server_unchanged'] = server.deviceSnapshot();
  server.denyWrites = false;

  await writer.replaceSelection(
    restaurantId: _restaurantId,
    selectedCandidates: <BaselineCandidateShift>[_candidateA],
    previouslySelectedCandidates: const <BaselineCandidateShift>[],
  );
  final targetCycles = _HarnessTargetCycleWriter();
  final activeProfiles = _HarnessActiveTargetProfileWriter();
  final projectionService = ServerTargetCycleProjectionService(
    selectedStars: server,
    targetCycles: targetCycles,
    activeProfiles: activeProfiles,
    clock: () => _fixedNow,
    profileVersionIdForCycle: (_) => _profileVersionId,
  );
  final projection = await projectionService
      .projectManagerOverrideFromCurrentServerSelections(command: _command());
  _expect(projection.cycle.selectedShiftCount, 2);
  _expect(projection.activeProfile.targetCycleId, projection.cycle.cycleId);
  _expect(
    activeProfiles.writes.single.targetProfileVersionId,
    _profileVersionId,
  );
  evidence['manager_override_projection'] = <String, Object?>{
    'cycle_id': projection.cycle.cycleId,
    'selected_shift_count': projection.cycle.selectedShiftCount,
    'active_profile_cycle_id': projection.activeProfile.targetCycleId,
    'source_type': projection.activeProfile.sourceType,
  };

  stdout.writeln(const JsonEncoder.withIndent('  ').convert(evidence));
}

const _operatorId = '11111111-1111-4111-8111-111111111111';
const _locationId = '22222222-2222-4222-8222-222222222222';
const _actorUserId = '33333333-3333-4333-8333-333333333333';
const _restaurantId = 'restaurant-1';
const _cycleId = '44444444-4444-4444-8444-444444444444';
const _profileId = '55555555-5555-4555-8555-555555555555';
const _profileVersionId = '66666666-6666-4666-8666-666666666666';
final _fixedNow = DateTime.utc(2026, 5, 6, 12);

final _session = AuthSession(
  userId: _actorUserId,
  operatorId: _operatorId,
  locationId: _locationId,
  firebaseIdToken: 'fixture-token',
  issuedAt: DateTime.utc(2026, 5, 6, 11),
  expiresAt: DateTime.utc(2026, 5, 6, 13),
  lastFreshAuthAt: DateTime.utc(2026, 5, 6, 11),
  roles: const <String>['operator_manager'],
  mfaEnrolled: true,
);

const _candidateA = BaselineCandidateShift(
  recordKey: '2026-W19|Wednesday|dinner',
  weekId: '2026-W19',
  weekLabel: 'Week 19',
  dayLabel: 'Wednesday',
  daypart: 'dinner',
  covers: 120,
  cplh: 12.4,
  splh: 152,
  ppa: 42.5,
  primaryLeverId: 'labor',
  isSelected: false,
  businessDate: '2026-05-06',
  actualLaborPct: 21.5,
  hasActualLaborPctTruth: true,
);

const _candidateB = BaselineCandidateShift(
  recordKey: '2026-W19|Thursday|dinner',
  weekId: '2026-W19',
  weekLabel: 'Week 19',
  dayLabel: 'Thursday',
  daypart: 'dinner',
  covers: 130,
  cplh: 12.1,
  splh: 155,
  ppa: 43,
  primaryLeverId: 'labor',
  isSelected: false,
  businessDate: '2026-05-07',
  actualLaborPct: 21,
  hasActualLaborPctTruth: true,
);

ServerTargetCycleProjectionCommand _command() {
  return const ServerTargetCycleProjectionCommand(
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: _restaurantId,
    cycleId: _cycleId,
    effectiveStart: '2026-05-06',
    effectiveEnd: '2026-07-05',
    calibrationWindowStart: '2026-03-08',
    calibrationWindowEnd: '2026-05-06',
    standards: ServerTargetStandards(
      targetCplh: 12.25,
      targetSplh: 153.5,
      targetPpa: 42.75,
      fohWage: 18,
      bohWage: 20,
      opzFloorCplh: 10,
      opzCeilingCplh: 14,
    ),
    actorUserId: _actorUserId,
    reason: 'fixture manager selected stars',
    idempotencyKey: 'projection-idem',
    requestHash: 'projection-hash',
  );
}

Map<String, Object?> _serverBody(BaselineCandidateShift candidate) =>
    <String, Object?>{
      'restaurant_id': _restaurantId,
      'record_key': candidate.recordKey,
      'week_id': candidate.weekId,
      'day_label': candidate.dayLabel,
      'daypart': candidate.daypart,
      'business_date': candidate.businessDate,
      'service_period_key': candidate.daypart,
    };

class _HarnessStarTargetServer
    implements
        StarTargetSelectionWriteClient,
        ServerSelectedStarDecisionReader {
  final _decisions = <_Decision>[];
  final _idempotencyKeys = <String>{};
  bool denyWrites = false;

  int get decisionCount => _decisions.length;

  Set<String> get currentRecordKeys {
    final selected = <String, bool>{};
    for (final decision in _decisions) {
      selected[decision.recordKey] =
          decision.action == StarTargetSelectionWriteAction.select;
    }
    return {
      for (final entry in selected.entries)
        if (entry.value) entry.key,
    };
  }

  Map<String, Object?> deviceSnapshot() => <String, Object?>{
    'selected_record_keys': currentRecordKeys.toList()..sort(),
    'decision_count': decisionCount,
  };

  @override
  Future<void> submitSelectedStarDecision({
    required String operatorId,
    required String locationId,
    required StarTargetSelectionWriteAction action,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    if (denyWrites) {
      throw const StarTargetSelectionWriteException(
        code: 'permission_denied',
        message: 'fixture denied',
        statusCode: 403,
      );
    }
    _expect(operatorId, _operatorId);
    _expect(locationId, _locationId);
    if (_idempotencyKeys.contains(idempotencyKey)) return;
    _idempotencyKeys.add(idempotencyKey);
    _decisions.add(
      _Decision(
        decisionId: 'decision-${_decisions.length + 1}',
        recordKey: body['record_key']! as String,
        action: action,
      ),
    );
  }

  @override
  Future<void> submitSelectedStarTargetProjection({
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {}

  @override
  Future<List<ServerSelectedStarDecisionInput>> listCurrentSelections({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    String? userId,
    int limit = 250,
  }) async {
    _expect(operatorId, _operatorId);
    _expect(locationId, _locationId);
    _expect(restaurantId, _restaurantId);
    final latest = <String, _Decision>{};
    for (final decision in _decisions) {
      latest[decision.recordKey] = decision;
    }
    return <ServerSelectedStarDecisionInput>[
      for (final decision in latest.values)
        if (decision.action == StarTargetSelectionWriteAction.select)
          ServerSelectedStarDecisionInput(
            decisionId: decision.decisionId,
            recordKey: decision.recordKey,
          ),
    ].take(limit).toList(growable: false);
  }
}

class _Decision {
  const _Decision({
    required this.decisionId,
    required this.recordKey,
    required this.action,
  });

  final String decisionId;
  final String recordKey;
  final StarTargetSelectionWriteAction action;
}

class _HarnessTargetCycleWriter implements ServerTargetCycleWriter {
  @override
  Future<target_cycle_pg.TargetCyclePostgresRow> replaceActiveCycle({
    required target_cycle_pg.TargetCyclePostgresWrite replacement,
    required bool enforceManagerOverrideAvailable,
    required String actorKind,
    required String reason,
  }) async {
    _expect(enforceManagerOverrideAvailable, _isTrue);
    _expect(replacement.source, 'manager_override');
    return target_cycle_pg.TargetCyclePostgresRow(
      cycleId: replacement.cycleId ?? _cycleId,
      operatorId: replacement.operatorId,
      locationId: replacement.locationId,
      restaurantId: replacement.restaurantId,
      source: replacement.source,
      effectiveStart: replacement.effectiveStart,
      effectiveEnd: replacement.effectiveEnd,
      calibrationWindowStart: replacement.calibrationWindowStart,
      calibrationWindowEnd: replacement.calibrationWindowEnd,
      targetCplh: replacement.targetCplh,
      targetSplh: replacement.targetSplh,
      targetPpa: replacement.targetPpa,
      fohWage: replacement.fohWage,
      bohWage: replacement.bohWage,
      opzFloorCplh: replacement.opzFloorCplh,
      opzCeilingCplh: replacement.opzCeilingCplh,
      managerOverrideUsed: replacement.managerOverrideUsed,
      managerOverrideAt: replacement.managerOverrideAt,
      managerOverrideByUserId: replacement.managerOverrideByUserId,
      adminReplacedAt: replacement.adminReplacedAt,
      adminReplacedByUserId: replacement.adminReplacedByUserId,
      supersedesCycleId: replacement.supersedesCycleId,
      selectedShiftCount: replacement.selectedShiftCount,
      selectedRecordKeys: replacement.selectedRecordKeys,
      selectionDecisionIds: replacement.selectionDecisionIds,
      replacementReason: replacement.replacementReason,
      idempotencyKey: replacement.idempotencyKey,
      requestHash: replacement.requestHash,
      createdBy: replacement.createdBy,
      createdAt: _fixedNow,
      updatedAt: _fixedNow,
      deactivatedAt: null,
    );
  }
}

class _HarnessActiveTargetProfileWriter
    implements ServerActiveTargetProfileWriter {
  final writes = <active_profile_pg.ActiveTargetProfileProjectionWrite>[];

  @override
  Future<active_profile_pg.ActiveTargetProfilePostgresRow> upsertProjection({
    required active_profile_pg.ActiveTargetProfileProjectionWrite profile,
    required String actorKind,
    required String reason,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    writes.add(profile);
    return active_profile_pg.ActiveTargetProfilePostgresRow(
      targetProfileId: _profileId,
      operatorId: profile.operatorId,
      locationId: profile.locationId,
      restaurantId: profile.restaurantId,
      targetCycleId: profile.targetCycleId,
      targetProfileVersionId: profile.targetProfileVersionId,
      sourceType: profile.sourceType,
      targetCplh: profile.targetCplh,
      targetSplh: profile.targetSplh,
      targetPpa: profile.targetPpa,
      fohWage: profile.fohWage,
      bohWage: profile.bohWage,
      opzFloorCplh: profile.opzFloorCplh,
      opzCeilingCplh: profile.opzCeilingCplh,
      theoreticalFohLaborPct: profile.theoreticalFohLaborPct,
      theoreticalBohLaborPct: profile.theoreticalBohLaborPct,
      theoreticalLaborPct: profile.theoreticalLaborPct,
      builtAt: profile.builtAt,
      projectionSource: 'harness',
      createdAt: _fixedNow,
      updatedAt: _fixedNow,
    );
  }
}

const _isTrue = _Matcher(true);
const _isFalse = _Matcher(false);

_Contains _contains(Object? value) => _Contains(value);

void _expect(Object? actual, Object? matcher) {
  if (matcher is _Matcher) {
    if (actual != matcher.value) {
      throw StateError('Expected $actual to equal ${matcher.value}');
    }
    return;
  }
  if (matcher is _Contains) {
    if (actual is! Iterable || !actual.contains(matcher.value)) {
      throw StateError('Expected $actual to contain ${matcher.value}');
    }
    return;
  }
  if (actual != matcher) {
    throw StateError('Expected $actual to equal $matcher');
  }
}

class _Matcher {
  const _Matcher(this.value);
  final Object? value;
}

class _Contains {
  const _Contains(this.value);
  final Object? value;
}
