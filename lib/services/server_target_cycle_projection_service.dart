import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../domain/models/target_cycle.dart';
import '../domain/models/target_cycle_source.dart';
import '../domain/services/target_cycle_active_target_profile_projector.dart';
import '../infrastructure/persistence/postgres/repositories/active_target_profile_repository.dart'
    as active_profile_pg;
import '../infrastructure/persistence/postgres/repositories/selected_star_shift_repository.dart'
    as selected_star_pg;
import '../infrastructure/persistence/postgres/repositories/target_cycle_repository.dart'
    as target_cycle_pg;

class ServerTargetCycleProjectionService {
  ServerTargetCycleProjectionService({
    required ServerTargetCycleWriter targetCycles,
    required ServerActiveTargetProfileWriter activeProfiles,
    ServerSelectedStarDecisionReader? selectedStars,
    DateTime Function()? clock,
    String Function(String cycleId)? profileVersionIdForCycle,
  }) : _targetCycles = targetCycles,
       _activeProfiles = activeProfiles,
       _selectedStars = selectedStars,
       _clock = clock ?? (() => DateTime.now().toUtc()),
       _profileVersionIdForCycle =
           profileVersionIdForCycle ?? _stableProfileVersionIdForCycle;

  factory ServerTargetCycleProjectionService.postgres({
    required selected_star_pg.SelectedStarShiftRepository selectedStars,
    required target_cycle_pg.TargetCycleRepository targetCycles,
    required active_profile_pg.ActiveTargetProfileRepository activeProfiles,
    DateTime Function()? clock,
    String Function(String cycleId)? profileVersionIdForCycle,
  }) {
    return ServerTargetCycleProjectionService(
      selectedStars: PostgresSelectedStarDecisionReader(selectedStars),
      targetCycles: PostgresTargetCycleWriter(targetCycles),
      activeProfiles: PostgresActiveTargetProfileWriter(activeProfiles),
      clock: clock,
      profileVersionIdForCycle: profileVersionIdForCycle,
    );
  }

  final ServerTargetCycleWriter _targetCycles;
  final ServerActiveTargetProfileWriter _activeProfiles;
  final ServerSelectedStarDecisionReader? _selectedStars;
  final DateTime Function() _clock;
  final String Function(String cycleId) _profileVersionIdForCycle;

  Future<ServerTargetCycleProjectionResult>
  projectManagerOverrideFromCurrentServerSelections({
    required ServerTargetCycleProjectionCommand command,
    int selectionLimit = 250,
  }) async {
    final reader = _selectedStars;
    if (reader == null) {
      throw StateError(
        'ServerTargetCycleProjectionService requires a selected-star reader '
        'for repository-backed projection.',
      );
    }
    final selected = await reader.listCurrentSelections(
      operatorId: command.operatorId,
      locationId: command.locationId,
      restaurantId: command.restaurantId,
      userId: command.actorUserId,
      limit: selectionLimit,
    );
    return projectManagerOverride(command: command, selectedStars: selected);
  }

  Future<ServerTargetCycleProjectionResult> projectManagerOverride({
    required ServerTargetCycleProjectionCommand command,
    required List<ServerSelectedStarDecisionInput> selectedStars,
  }) async {
    command.validate();
    final summary = ServerSelectedStarSummary.fromSelections(selectedStars);
    if (summary.selectedShiftCount == 0) {
      throw StateError(
        'Manager override projection requires at least one server-selected '
        'star decision.',
      );
    }

    final now = _clock().toUtc();
    final managerOverrideAt = command.managerOverrideAt ?? now;
    final replacement = target_cycle_pg.TargetCyclePostgresWrite(
      operatorId: command.operatorId,
      locationId: command.locationId,
      restaurantId: command.restaurantId,
      cycleId: command.cycleId,
      source: TargetCycleSource.managerOverride.label,
      effectiveStart: command.effectiveStart,
      effectiveEnd: command.effectiveEnd,
      calibrationWindowStart: command.calibrationWindowStart,
      calibrationWindowEnd: command.calibrationWindowEnd,
      targetCplh: command.standards.targetCplh,
      targetSplh: command.standards.targetSplh,
      targetPpa: command.standards.targetPpa,
      fohWage: command.standards.fohWage,
      bohWage: command.standards.bohWage,
      opzFloorCplh: command.standards.opzFloorCplh,
      opzCeilingCplh: command.standards.opzCeilingCplh,
      managerOverrideUsed: true,
      managerOverrideAt: managerOverrideAt,
      managerOverrideByUserId:
          command.managerOverrideByUserId ?? command.actorUserId,
      adminReplacedAt: command.adminReplacedAt,
      adminReplacedByUserId: command.adminReplacedByUserId,
      supersedesCycleId: command.supersedesCycleId,
      selectedShiftCount: summary.selectedShiftCount,
      selectedRecordKeys: summary.recordKeys,
      selectionDecisionIds: summary.decisionIds,
      replacementReason: command.reason,
      idempotencyKey: command.idempotencyKey,
      requestHash: command.requestHash,
      createdBy: command.actorUserId,
    );

    final cycle = await _targetCycles.replaceActiveCycle(
      replacement: replacement,
      enforceManagerOverrideAvailable: true,
      actorKind: command.actorKind,
      reason: command.reason,
    );
    final projected = TargetCycleActiveTargetProfileProjector.project(
      cycle.toDomainCycle(),
    );
    final profileWrite = active_profile_pg.ActiveTargetProfileProjectionWrite(
      operatorId: cycle.operatorId,
      locationId: cycle.locationId,
      restaurantId: cycle.restaurantId,
      targetCycleId: cycle.cycleId,
      targetProfileVersionId: _profileVersionIdForCycle(cycle.cycleId),
      sourceType: projected.sourceType,
      targetCplh: projected.targetCPLH,
      targetSplh: projected.targetSPLH,
      targetPpa: projected.targetPPA,
      fohWage: projected.fohWage,
      bohWage: projected.bohWage,
      opzFloorCplh: projected.opzFloorCPLH,
      opzCeilingCplh: projected.opzCeilingCPLH,
      theoreticalFohLaborPct: projected.theoreticalFohLaborPct,
      theoreticalBohLaborPct: projected.theoreticalBohLaborPct,
      theoreticalLaborPct: projected.theoreticalLaborPct,
      builtAt: cycle.createdAt.toUtc(),
      actorUserId: command.actorUserId,
    );
    final activeProfile = await _activeProfiles.upsertProjection(
      profile: profileWrite,
      actorKind: command.actorKind,
      reason: command.reason,
      metadata: <String, Object?>{
        'target_cycle_id': cycle.cycleId,
        'source': cycle.source,
        'selected_shift_count': cycle.selectedShiftCount,
        'selected_record_keys': cycle.selectedRecordKeys,
        'selection_decision_ids': cycle.selectionDecisionIds,
      },
    );

    return ServerTargetCycleProjectionResult(
      cycle: cycle,
      activeProfile: activeProfile,
      selectedStarSummary: summary,
    );
  }
}

abstract class ServerSelectedStarDecisionReader {
  Future<List<ServerSelectedStarDecisionInput>> listCurrentSelections({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    String? userId,
    int limit = 250,
  });
}

abstract class ServerTargetCycleWriter {
  Future<target_cycle_pg.TargetCyclePostgresRow> replaceActiveCycle({
    required target_cycle_pg.TargetCyclePostgresWrite replacement,
    required bool enforceManagerOverrideAvailable,
    required String actorKind,
    required String reason,
  });
}

abstract class ServerActiveTargetProfileWriter {
  Future<active_profile_pg.ActiveTargetProfilePostgresRow> upsertProjection({
    required active_profile_pg.ActiveTargetProfileProjectionWrite profile,
    required String actorKind,
    required String reason,
    Map<String, Object?> metadata = const <String, Object?>{},
  });
}

class PostgresSelectedStarDecisionReader
    implements ServerSelectedStarDecisionReader {
  const PostgresSelectedStarDecisionReader(this._repository);

  final selected_star_pg.SelectedStarShiftRepository _repository;

  @override
  Future<List<ServerSelectedStarDecisionInput>> listCurrentSelections({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    String? userId,
    int limit = 250,
  }) async {
    final rows = await _repository.listCurrentSelections(
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      userId: userId,
      limit: limit,
    );
    return <ServerSelectedStarDecisionInput>[
      for (final row in rows) ServerSelectedStarDecisionInput.fromPostgres(row),
    ];
  }
}

class PostgresTargetCycleWriter implements ServerTargetCycleWriter {
  const PostgresTargetCycleWriter(this._repository);

  final target_cycle_pg.TargetCycleRepository _repository;

  @override
  Future<target_cycle_pg.TargetCyclePostgresRow> replaceActiveCycle({
    required target_cycle_pg.TargetCyclePostgresWrite replacement,
    required bool enforceManagerOverrideAvailable,
    required String actorKind,
    required String reason,
  }) {
    return _repository.replaceActiveCycle(
      replacement: replacement,
      enforceManagerOverrideAvailable: enforceManagerOverrideAvailable,
      actorKind: actorKind,
      reason: reason,
    );
  }
}

class PostgresActiveTargetProfileWriter
    implements ServerActiveTargetProfileWriter {
  const PostgresActiveTargetProfileWriter(this._repository);

  final active_profile_pg.ActiveTargetProfileRepository _repository;

  @override
  Future<active_profile_pg.ActiveTargetProfilePostgresRow> upsertProjection({
    required active_profile_pg.ActiveTargetProfileProjectionWrite profile,
    required String actorKind,
    required String reason,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    return _repository.upsertProjection(
      profile: profile,
      actorKind: actorKind,
      reason: reason,
      metadata: metadata,
    );
  }
}

class ServerTargetCycleProjectionCommand {
  const ServerTargetCycleProjectionCommand({
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    this.cycleId,
    required this.effectiveStart,
    required this.effectiveEnd,
    required this.calibrationWindowStart,
    required this.calibrationWindowEnd,
    required this.standards,
    this.actorUserId,
    this.managerOverrideAt,
    this.managerOverrideByUserId,
    this.adminReplacedAt,
    this.adminReplacedByUserId,
    this.supersedesCycleId,
    required this.reason,
    required this.idempotencyKey,
    required this.requestHash,
    this.actorKind = 'operator_user',
  });

  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String? cycleId;
  final String effectiveStart;
  final String effectiveEnd;
  final String calibrationWindowStart;
  final String calibrationWindowEnd;
  final ServerTargetStandards standards;
  final String? actorUserId;
  final DateTime? managerOverrideAt;
  final String? managerOverrideByUserId;
  final DateTime? adminReplacedAt;
  final String? adminReplacedByUserId;
  final String? supersedesCycleId;
  final String reason;
  final String idempotencyKey;
  final String requestHash;
  final String actorKind;

  void validate() {
    _validateNonBlank(operatorId, 'operatorId');
    _validateNonBlank(locationId, 'locationId');
    _validateNonBlank(restaurantId, 'restaurantId');
    _validateNonBlank(reason, 'reason');
    _validateNonBlank(idempotencyKey, 'idempotencyKey');
    _validateNonBlank(requestHash, 'requestHash');
    _validateDateWindow(
      effectiveStart,
      effectiveEnd,
      startName: 'effectiveStart',
      endName: 'effectiveEnd',
      requireEndAfterStart: true,
    );
    _validateDateWindow(
      calibrationWindowStart,
      calibrationWindowEnd,
      startName: 'calibrationWindowStart',
      endName: 'calibrationWindowEnd',
      requireEndAfterStart: false,
    );
    standards.validate();
  }
}

class ServerTargetStandards {
  const ServerTargetStandards({
    required this.targetCplh,
    required this.targetSplh,
    required this.targetPpa,
    required this.fohWage,
    required this.bohWage,
    required this.opzFloorCplh,
    required this.opzCeilingCplh,
  });

  final double targetCplh;
  final double targetSplh;
  final double targetPpa;
  final double fohWage;
  final double bohWage;
  final double opzFloorCplh;
  final double opzCeilingCplh;

  void validate() {
    _validateNonNegative(targetCplh, 'targetCplh');
    _validateNonNegative(targetSplh, 'targetSplh');
    _validateNonNegative(targetPpa, 'targetPpa');
    _validateNonNegative(fohWage, 'fohWage');
    _validateNonNegative(bohWage, 'bohWage');
    _validateNonNegative(opzFloorCplh, 'opzFloorCplh');
    _validateNonNegative(opzCeilingCplh, 'opzCeilingCplh');
    if (opzCeilingCplh < opzFloorCplh) {
      throw ArgumentError.value(
        opzCeilingCplh,
        'opzCeilingCplh',
        'must be greater than or equal to opzFloorCplh',
      );
    }
  }
}

class ServerSelectedStarDecisionInput {
  const ServerSelectedStarDecisionInput({
    required this.decisionId,
    required this.recordKey,
  });

  factory ServerSelectedStarDecisionInput.fromPostgres(
    selected_star_pg.SelectedStarShiftDecisionRow row,
  ) {
    return ServerSelectedStarDecisionInput(
      decisionId: row.decisionId,
      recordKey: row.recordKey,
    );
  }

  final String decisionId;
  final String recordKey;

  void validate() {
    _validateNonBlank(decisionId, 'decisionId');
    _validateNonBlank(recordKey, 'recordKey');
  }
}

class ServerSelectedStarSummary {
  const ServerSelectedStarSummary({
    required this.selectedShiftCount,
    required this.recordKeys,
    required this.decisionIds,
  });

  factory ServerSelectedStarSummary.fromSelections(
    List<ServerSelectedStarDecisionInput> selectedStars,
  ) {
    final recordKeys = <String>[];
    final decisionIds = <String>[];
    for (final star in selectedStars) {
      star.validate();
      if (!recordKeys.contains(star.recordKey)) {
        recordKeys.add(star.recordKey);
      }
      if (!decisionIds.contains(star.decisionId)) {
        decisionIds.add(star.decisionId);
      }
    }
    return ServerSelectedStarSummary(
      selectedShiftCount: recordKeys.length,
      recordKeys: List<String>.unmodifiable(recordKeys),
      decisionIds: List<String>.unmodifiable(decisionIds),
    );
  }

  final int selectedShiftCount;
  final List<String> recordKeys;
  final List<String> decisionIds;
}

class ServerTargetCycleProjectionResult {
  const ServerTargetCycleProjectionResult({
    required this.cycle,
    required this.activeProfile,
    required this.selectedStarSummary,
  });

  final target_cycle_pg.TargetCyclePostgresRow cycle;
  final active_profile_pg.ActiveTargetProfilePostgresRow activeProfile;
  final ServerSelectedStarSummary selectedStarSummary;
}

extension ServerTargetCyclePostgresRowProjection
    on target_cycle_pg.TargetCyclePostgresRow {
  TargetCycle toDomainCycle() {
    return TargetCycle(
      cycleId: cycleId,
      restaurantId: restaurantId,
      source: TargetCycleSource.fromLabel(source),
      effectiveStart: effectiveStart,
      effectiveEnd: effectiveEnd,
      calibrationWindowStart: calibrationWindowStart,
      calibrationWindowEnd: calibrationWindowEnd,
      targetCPLH: targetCplh,
      targetSPLH: targetSplh,
      targetPPA: targetPpa,
      fohWage: fohWage,
      bohWage: bohWage,
      opzFloorCPLH: opzFloorCplh,
      opzCeilingCPLH: opzCeilingCplh,
      managerOverrideUsed: managerOverrideUsed,
      managerOverrideAt: managerOverrideAt?.toUtc().toIso8601String(),
      adminReplacedAt: adminReplacedAt?.toUtc().toIso8601String(),
      createdAt: createdAt.toUtc().toIso8601String(),
    );
  }
}

String _stableProfileVersionIdForCycle(String cycleId) {
  final digest = crypto.sha1
      .convert(utf8.encode('server-target-profile-version:$cycleId'))
      .bytes;
  final bytes = List<int>.from(digest.take(16));
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String two(int value) => value.toRadixString(16).padLeft(2, '0');
  final hex = bytes.map(two).join();
  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20, 32)}';
}

void _validateDateWindow(
  String start,
  String end, {
  required String startName,
  required String endName,
  required bool requireEndAfterStart,
}) {
  final parsedStart = DateTime.parse(start);
  final parsedEnd = DateTime.parse(end);
  final valid = requireEndAfterStart
      ? parsedEnd.isAfter(parsedStart)
      : !parsedEnd.isBefore(parsedStart);
  if (!valid) {
    throw ArgumentError.value(
      end,
      endName,
      'must be ${requireEndAfterStart ? 'after' : 'on or after'} $startName',
    );
  }
}

void _validateNonBlank(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'must be non-blank');
  }
}

void _validateNonNegative(double value, String name) {
  if (value.isNaN || value < 0) {
    throw ArgumentError.value(value, name, 'must be non-negative');
  }
}
