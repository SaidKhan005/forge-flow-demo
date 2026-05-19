/// Pure projector: [TargetCycle] -> [ActiveTargetProfile].
///
/// No persistence, no side effects. Deterministic projection of the
/// cycle's locked standards into the runtime profile format that
/// existing consumers read.
///
/// Phase 7.55l.4a: projection only — consumer migration comes later.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import '../models/active_target_profile.dart';
import '../models/target_cycle.dart';
import '../models/target_cycle_source.dart';

class TargetCycleActiveTargetProfileProjector {
  const TargetCycleActiveTargetProfileProjector._();

  /// Projects a [TargetCycle] to an [ActiveTargetProfile].
  ///
  /// Maps all standards fields directly. Derives `sourceType` from the
  /// cycle source. Computes theoretical labor percentages using the
  /// standard formulas.
  static ActiveTargetProfile project(
    TargetCycle cycle, {
    String? targetProfileId,
    String? targetProfileVersionId,
    String? builtAt,
  }) {
    final fohPct = (cycle.targetCPLH > 0 && cycle.targetPPA > 0)
        ? cycle.fohWage / (cycle.targetCPLH * cycle.targetPPA) * 100
        : 0.0;
    final bohPct = cycle.targetSPLH > 0
        ? cycle.bohWage / cycle.targetSPLH * 100
        : 0.0;

    return ActiveTargetProfile(
      targetProfileId: targetProfileId ?? '${cycle.restaurantId}_active',
      restaurantId: cycle.restaurantId,
      targetCycleId: cycle.cycleId,
      targetProfileVersionId:
          targetProfileVersionId ??
          stableProfileVersionIdForCycle(cycle.cycleId),
      sourceType: _sourceType(cycle.source),
      targetCPLH: cycle.targetCPLH,
      targetSPLH: cycle.targetSPLH,
      targetPPA: cycle.targetPPA,
      fohWage: cycle.fohWage,
      bohWage: cycle.bohWage,
      opzFloorCPLH: cycle.opzFloorCPLH,
      opzCeilingCPLH: cycle.opzCeilingCPLH,
      theoreticalFohLaborPct: fohPct,
      theoreticalBohLaborPct: bohPct,
      theoreticalLaborPct: fohPct + bohPct,
      builtAt: builtAt ?? DateTime.now().toUtc().toIso8601String(),
    );
  }

  static String _sourceType(TargetCycleSource source) => switch (source) {
    TargetCycleSource.recommended => 'cycle_recommended',
    TargetCycleSource.managerOverride => 'cycle_manager_override',
    TargetCycleSource.adminReplacement => 'cycle_admin_replacement',
  };

  /// Stable version identity for the immutable target snapshot projected
  /// from [cycleId].
  ///
  /// Mirrors the server projection convention so local/offline TargetCycle
  /// projection and synced server projection lock the same version id for
  /// the same cycle.
  static String stableProfileVersionIdForCycle(String cycleId) {
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
}
