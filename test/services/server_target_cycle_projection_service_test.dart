import 'package:forge_and_flow/domain/services/target_cycle_active_target_profile_projector.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/active_target_profile_repository.dart'
    as active_profile_pg;
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/target_cycle_repository.dart'
    as target_cycle_pg;
import 'package:forge_and_flow/services/server_target_cycle_projection_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ServerTargetCycleProjectionService', () {
    test(
      'manager override consumes server selections and projects active profile',
      () async {
        final targetCycles = _FakeTargetCycleWriter();
        final activeProfiles = _FakeActiveTargetProfileWriter();
        final selectedStars = _FakeSelectedStarReader(_selectedStars());
        final service = ServerTargetCycleProjectionService(
          selectedStars: selectedStars,
          targetCycles: targetCycles,
          activeProfiles: activeProfiles,
          clock: () => _fixedNow,
        );

        final result = await service
            .projectManagerOverrideFromCurrentServerSelections(
              command: _command(),
            );

        expect(selectedStars.lastOperatorId, _operatorId);
        expect(selectedStars.lastLocationId, _locationId);
        expect(selectedStars.lastRestaurantId, 'restaurant-1');
        expect(selectedStars.lastUserId, _actorUserId);

        final replacement = targetCycles.replacements.single;
        expect(targetCycles.enforceFlags.single, isTrue);
        expect(replacement.source, 'manager_override');
        expect(replacement.effectiveStart, '2026-05-06');
        expect(replacement.effectiveEnd, '2026-07-05');
        expect(replacement.calibrationWindowStart, '2026-03-08');
        expect(replacement.calibrationWindowEnd, '2026-05-06');
        expect(replacement.targetCplh, 14.5);
        expect(replacement.targetSplh, 28.0);
        expect(replacement.targetPpa, 32.0);
        expect(replacement.fohWage, 22.0);
        expect(replacement.bohWage, 24.0);
        expect(replacement.opzFloorCplh, 12.0);
        expect(replacement.opzCeilingCplh, 16.0);
        expect(replacement.managerOverrideUsed, isTrue);
        expect(replacement.managerOverrideAt, _fixedNow);
        expect(replacement.managerOverrideByUserId, _actorUserId);
        expect(replacement.adminReplacedAt, isNull);
        expect(replacement.selectedShiftCount, 2);
        expect(replacement.selectedRecordKeys, <String>[
          '2026-W18|Fri|dinner',
          '2026-W18|Sat|dinner',
        ]);
        expect(replacement.selectionDecisionIds, <String>[
          'decision-a',
          'decision-b',
        ]);
        expect(replacement.replacementReason, 'manager selected new stars');
        expect(replacement.idempotencyKey, 'override-key-1');
        expect(replacement.requestHash, 'request-hash-1');
        expect(replacement.createdBy, _actorUserId);

        final profileWrite = activeProfiles.writes.single;
        final projected = TargetCycleActiveTargetProfileProjector.project(
          result.cycle.toDomainCycle(),
        );
        expect(profileWrite.targetCycleId, result.cycle.cycleId);
        expect(profileWrite.sourceType, projected.sourceType);
        expect(profileWrite.targetCplh, projected.targetCPLH);
        expect(profileWrite.targetSplh, projected.targetSPLH);
        expect(profileWrite.targetPpa, projected.targetPPA);
        expect(profileWrite.fohWage, projected.fohWage);
        expect(profileWrite.bohWage, projected.bohWage);
        expect(profileWrite.opzFloorCplh, projected.opzFloorCPLH);
        expect(profileWrite.opzCeilingCplh, projected.opzCeilingCPLH);
        expect(
          profileWrite.theoreticalFohLaborPct,
          closeTo(projected.theoreticalFohLaborPct, 0.000001),
        );
        expect(
          profileWrite.theoreticalBohLaborPct,
          closeTo(projected.theoreticalBohLaborPct, 0.000001),
        );
        expect(
          profileWrite.theoreticalLaborPct,
          closeTo(projected.theoreticalLaborPct, 0.000001),
        );
        expect(profileWrite.builtAt, result.cycle.createdAt);
        expect(result.selectedStarSummary.selectedShiftCount, 2);
        expect(result.activeProfile.targetCycleId, result.cycle.cycleId);
      },
    );

    test(
      'idempotent replay reuses the target cycle and version snapshot',
      () async {
        final targetCycles = _FakeTargetCycleWriter();
        final activeProfiles = _FakeActiveTargetProfileWriter();
        final service = ServerTargetCycleProjectionService(
          targetCycles: targetCycles,
          activeProfiles: activeProfiles,
          clock: () => _fixedNow,
        );

        final first = await service.projectManagerOverride(
          command: _command(),
          selectedStars: _selectedStars(),
        );
        final second = await service.projectManagerOverride(
          command: _command(),
          selectedStars: _selectedStars(),
        );

        expect(first.cycle.cycleId, second.cycle.cycleId);
        expect(targetCycles.newCycleCount, 1);
        expect(targetCycles.replacements, hasLength(2));
        expect(activeProfiles.writes, hasLength(2));
        expect(
          activeProfiles.writes.map((write) => write.targetProfileVersionId),
          everyElement(activeProfiles.writes.first.targetProfileVersionId),
        );
        expect(activeProfiles.uniqueVersionSnapshots, hasLength(1));
      },
    );

    test(
      'once-per-cycle denial from target-cycle repository stops projection',
      () async {
        final targetCycles = _FakeTargetCycleWriter()
          ..denyManagerOverride = true;
        final activeProfiles = _FakeActiveTargetProfileWriter();
        final service = ServerTargetCycleProjectionService(
          targetCycles: targetCycles,
          activeProfiles: activeProfiles,
          clock: () => _fixedNow,
        );

        expect(
          () => service.projectManagerOverride(
            command: _command(idempotencyKey: 'override-key-2'),
            selectedStars: _selectedStars(),
          ),
          throwsA(isA<target_cycle_pg.TargetCycleManagerOverrideAlreadyUsed>()),
        );
        expect(targetCycles.enforceFlags.single, isTrue);
        expect(activeProfiles.writes, isEmpty);
      },
    );
  });
}

const _operatorId = '11111111-1111-4111-8111-111111111111';
const _locationId = '22222222-2222-4222-8222-222222222222';
const _actorUserId = '33333333-3333-4333-8333-333333333333';
final _fixedNow = DateTime.utc(2026, 5, 6, 15, 30);

ServerTargetCycleProjectionCommand _command({
  String idempotencyKey = 'override-key-1',
}) {
  return ServerTargetCycleProjectionCommand(
    operatorId: _operatorId,
    locationId: _locationId,
    restaurantId: 'restaurant-1',
    effectiveStart: '2026-05-06',
    effectiveEnd: '2026-07-05',
    calibrationWindowStart: '2026-03-08',
    calibrationWindowEnd: '2026-05-06',
    standards: const ServerTargetStandards(
      targetCplh: 14.5,
      targetSplh: 28.0,
      targetPpa: 32.0,
      fohWage: 22.0,
      bohWage: 24.0,
      opzFloorCplh: 12.0,
      opzCeilingCplh: 16.0,
    ),
    actorUserId: _actorUserId,
    reason: 'manager selected new stars',
    idempotencyKey: idempotencyKey,
    requestHash: 'request-hash-1',
  );
}

List<ServerSelectedStarDecisionInput> _selectedStars() {
  return const <ServerSelectedStarDecisionInput>[
    ServerSelectedStarDecisionInput(
      decisionId: 'decision-a',
      recordKey: '2026-W18|Fri|dinner',
    ),
    ServerSelectedStarDecisionInput(
      decisionId: 'decision-b',
      recordKey: '2026-W18|Sat|dinner',
    ),
  ];
}

class _FakeSelectedStarReader implements ServerSelectedStarDecisionReader {
  _FakeSelectedStarReader(this.selections);

  final List<ServerSelectedStarDecisionInput> selections;
  String? lastOperatorId;
  String? lastLocationId;
  String? lastRestaurantId;
  String? lastUserId;

  @override
  Future<List<ServerSelectedStarDecisionInput>> listCurrentSelections({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    String? userId,
    int limit = 250,
  }) async {
    lastOperatorId = operatorId;
    lastLocationId = locationId;
    lastRestaurantId = restaurantId;
    lastUserId = userId;
    return selections.take(limit).toList();
  }
}

class _FakeTargetCycleWriter implements ServerTargetCycleWriter {
  final replacements = <target_cycle_pg.TargetCyclePostgresWrite>[];
  final enforceFlags = <bool>[];
  final _byIdempotency = <String, target_cycle_pg.TargetCyclePostgresRow>{};
  bool denyManagerOverride = false;
  int newCycleCount = 0;

  @override
  Future<target_cycle_pg.TargetCyclePostgresRow> replaceActiveCycle({
    required target_cycle_pg.TargetCyclePostgresWrite replacement,
    required bool enforceManagerOverrideAvailable,
    required String actorKind,
    required String reason,
  }) async {
    replacements.add(replacement);
    enforceFlags.add(enforceManagerOverrideAvailable);
    final replay = _byIdempotency[replacement.idempotencyKey];
    if (replay != null) return replay;
    if (denyManagerOverride && enforceManagerOverrideAvailable) {
      throw const target_cycle_pg.TargetCycleManagerOverrideAlreadyUsed(
        'existing-cycle',
        'restaurant-1',
      );
    }
    newCycleCount += 1;
    final cycleId = replacement.cycleId ?? _uuid(newCycleCount);
    final row = _cycleRowFromWrite(replacement, cycleId: cycleId);
    _byIdempotency[replacement.idempotencyKey] = row;
    return row;
  }
}

class _FakeActiveTargetProfileWriter
    implements ServerActiveTargetProfileWriter {
  final writes = <active_profile_pg.ActiveTargetProfileProjectionWrite>[];
  final uniqueVersionSnapshots = <String>{};

  @override
  Future<active_profile_pg.ActiveTargetProfilePostgresRow> upsertProjection({
    required active_profile_pg.ActiveTargetProfileProjectionWrite profile,
    required String actorKind,
    required String reason,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    writes.add(profile);
    uniqueVersionSnapshots.add(profile.targetProfileVersionId);
    return active_profile_pg.ActiveTargetProfilePostgresRow(
      targetProfileId: profile.targetProfileId ?? 'active-profile-1',
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
      projectionSource: 'server_target_cycle',
      createdAt: _fixedNow,
      updatedAt: _fixedNow,
    );
  }
}

target_cycle_pg.TargetCyclePostgresRow _cycleRowFromWrite(
  target_cycle_pg.TargetCyclePostgresWrite write, {
  required String cycleId,
}) {
  return target_cycle_pg.TargetCyclePostgresRow(
    cycleId: cycleId,
    operatorId: write.operatorId,
    locationId: write.locationId,
    restaurantId: write.restaurantId,
    source: write.source,
    effectiveStart: write.effectiveStart,
    effectiveEnd: write.effectiveEnd,
    calibrationWindowStart: write.calibrationWindowStart,
    calibrationWindowEnd: write.calibrationWindowEnd,
    targetCplh: write.targetCplh,
    targetSplh: write.targetSplh,
    targetPpa: write.targetPpa,
    fohWage: write.fohWage,
    bohWage: write.bohWage,
    opzFloorCplh: write.opzFloorCplh,
    opzCeilingCplh: write.opzCeilingCplh,
    managerOverrideUsed: write.managerOverrideUsed,
    managerOverrideAt: write.managerOverrideAt,
    managerOverrideByUserId: write.managerOverrideByUserId,
    adminReplacedAt: write.adminReplacedAt,
    adminReplacedByUserId: write.adminReplacedByUserId,
    supersedesCycleId: write.supersedesCycleId,
    selectedShiftCount: write.selectedShiftCount,
    selectedRecordKeys: write.selectedRecordKeys,
    selectionDecisionIds: write.selectionDecisionIds,
    replacementReason: write.replacementReason,
    idempotencyKey: write.idempotencyKey,
    requestHash: write.requestHash,
    createdBy: write.createdBy,
    createdAt: _fixedNow,
    updatedAt: _fixedNow,
    deactivatedAt: null,
  );
}

String _uuid(int counter) {
  return '44444444-4444-4444-8444-${counter.toString().padLeft(12, '0')}';
}
