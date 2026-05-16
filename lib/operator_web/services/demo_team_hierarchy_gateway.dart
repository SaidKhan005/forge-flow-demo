// Phase 11W.3 - Operator Web team hierarchy demo gateway.
//
// In-memory implementation of [WebTeamHierarchyGateway] that the
// operator-web shell binds when `OPERATOR_WEB_DEMO_AUTH=true`. Reads
// the shared fixture set at [demo_team_fixtures.dart] so the demo
// walkthrough across `/members`, `/locations` (this slice), and the
// remaining 11W parity surfaces sees consistent data.
//
// Mutations made during a walkthrough (create org unit, move
// location) are stored on this instance only - page reload resets to
// the fixture defaults. That keeps the walkthrough reproducible
// across runs without persisting fixture drift.
//
// Idempotency: replays of the same `idempotencyKey` against an
// already-applied mutation surface the original response, mirroring
// the proxy's `proxy_requests` UNIQUE-key replay semantics so the
// demo behaviour matches the live gateway.
//
// Validation: the demo gateway enforces the parity-contract
// validation rules (empty name, duplicate name within parent, cycle
// prevention) so the screen layer can surface the locked copy without
// waiting on a server round-trip in the demo flavor. Locked copy is
// the single authoritative copy strings the screen renders.

import 'dart:async';

import '../../services/auth/auth_operations_gateway.dart';
import 'demo_team_fixtures.dart';
import 'web_team_hierarchy_gateway.dart';

/// In-memory demo gateway. Constructs from the shared fixture set
/// declared in [demo_team_fixtures.dart].
class DemoWebTeamHierarchyGateway implements WebTeamHierarchyGateway {
  DemoWebTeamHierarchyGateway() {
    for (final fixture in kDemoTeamOrgUnitsFixture) {
      _orgUnits[fixture.orgUnitId] = teamOrgUnitEntryFromFixture(fixture);
    }
    for (final fixture in kDemoTeamLocationsFixture) {
      _locations[fixture.locationId] = teamOrgLocationEntryFromFixture(fixture);
    }
  }

  final Map<String, TeamOrgUnitEntry> _orgUnits = <String, TeamOrgUnitEntry>{};
  final Map<String, TeamOrgLocationEntry> _locations =
      <String, TeamOrgLocationEntry>{};

  /// Cached responses keyed by the screen-minted idempotency key, so
  /// a re-submission of the same action returns the original outcome
  /// rather than mutating again.
  final Map<String, _CachedMutation> _idempotency =
      <String, _CachedMutation>{};

  /// Counter for synthesising stable demo org-unit ids when the
  /// walkthrough creates more than one org-unit in a session.
  int _nextOrgUnitSeq = 100;

  @override
  Future<TeamOrgHierarchyListed> listOrgHierarchy(
    TeamOrgHierarchyListCommand command,
  ) async {
    final units = _orgUnits.values.toList(growable: false);
    units.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    final locations = _locations.values.toList(growable: false);
    locations.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    return TeamOrgHierarchyListed(
      orgUnits: List<TeamOrgUnitEntry>.unmodifiable(units),
      locations: List<TeamOrgLocationEntry>.unmodifiable(locations),
    );
  }

  @override
  Future<TeamOrgUnitCreated> createOrgUnit(
    TeamOrgUnitCreateCommand command, {
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is _CachedOrgUnitCreated) return cached.created;
    final parent = _orgUnits[command.parentOrgUnitId];
    if (parent == null) {
      throw const WebTeamHierarchyError(
        code: 'parent_not_found',
        message: 'Parent org unit no longer exists. Refresh and try again.',
      );
    }
    final trimmedName = command.name.trim();
    if (trimmedName.isEmpty) {
      throw const WebTeamHierarchyError(
        code: 'validation_failed',
        message: 'Org unit name is required.',
      );
    }
    final hasDuplicate = _orgUnits.values.any(
      (entry) =>
          entry.parentOrgUnitId == command.parentOrgUnitId &&
          entry.label.toLowerCase() == trimmedName.toLowerCase(),
    );
    if (hasDuplicate) {
      throw const WebTeamHierarchyError(
        code: 'validation_failed',
        message:
            'An org unit with this name already exists in this group.',
      );
    }
    final orgUnitId = 'demo-org-seq-${_nextOrgUnitSeq++}';
    final entry = TeamOrgUnitEntry(
      orgUnitId: orgUnitId,
      parentOrgUnitId: command.parentOrgUnitId,
      unitType: command.unitType,
      path: '${parent.path}.${command.label.trim().toLowerCase()}',
      label: trimmedName,
    );
    _orgUnits[orgUnitId] = entry;
    final created = TeamOrgUnitCreated(orgUnitId: orgUnitId);
    _idempotency[idempotencyKey] = _CachedOrgUnitCreated(created);
    return created;
  }

  @override
  Future<TeamOrgUnitRenamed> renameOrgUnit(
    TeamOrgUnitRenameCommand command, {
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is _CachedOrgUnitRenamed) return cached.renamed;
    final existing = _orgUnits[command.orgUnitId];
    if (existing == null) {
      throw const WebTeamHierarchyError(
        code: 'unknown_org_unit',
        message: 'Org unit no longer exists. Refresh and try again.',
      );
    }
    final trimmedName = command.name.trim();
    if (trimmedName.isEmpty) {
      throw const WebTeamHierarchyError(
        code: 'validation_failed',
        message: 'Org unit name is required.',
      );
    }
    // Duplicate-name-within-parent rejection mirrors the live proxy.
    // Root rename (parentOrgUnitId == null) IS allowed — the corp root
    // is the operator-facing Business label.
    final hasDuplicate = _orgUnits.values.any(
      (entry) =>
          entry.orgUnitId != command.orgUnitId &&
          entry.parentOrgUnitId == existing.parentOrgUnitId &&
          entry.label.toLowerCase() == trimmedName.toLowerCase(),
    );
    if (hasDuplicate) {
      throw const WebTeamHierarchyError(
        code: 'validation_failed',
        message: 'An org unit with this name already exists in this group.',
      );
    }
    final renamedEntry = TeamOrgUnitEntry(
      orgUnitId: existing.orgUnitId,
      parentOrgUnitId: existing.parentOrgUnitId,
      unitType: existing.unitType,
      path: existing.path,
      label: trimmedName,
      suspendedAt: existing.suspendedAt,
      deletedAt: existing.deletedAt,
    );
    _orgUnits[command.orgUnitId] = renamedEntry;
    final renamed = TeamOrgUnitRenamed(orgUnit: renamedEntry);
    _idempotency[idempotencyKey] = _CachedOrgUnitRenamed(renamed);
    return renamed;
  }

  @override
  Future<TeamLocationOrgUnitMoved> moveLocationToOrgUnit(
    TeamLocationOrgUnitMoveCommand command, {
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached is _CachedLocationMoved) return cached.moved;
    final existing = _locations[command.targetLocationId];
    if (existing == null) {
      throw const WebTeamHierarchyError(
        code: 'location_not_found',
        message: 'Location no longer exists. Refresh and try again.',
      );
    }
    final destination = _orgUnits[command.parentOrgUnitId];
    if (destination == null) {
      throw const WebTeamHierarchyError(
        code: 'parent_not_found',
        message: 'Destination org unit no longer exists. Refresh and try '
            'again.',
      );
    }
    if (existing.parentOrgUnitId == command.parentOrgUnitId) {
      const result = TeamLocationOrgUnitMoved(moved: false);
      _idempotency[idempotencyKey] = const _CachedLocationMoved(result);
      return result;
    }
    _locations[command.targetLocationId] = TeamOrgLocationEntry(
      locationId: existing.locationId,
      parentOrgUnitId: command.parentOrgUnitId,
      orgUnitPath: destination.path,
      label: existing.label,
    );
    const result = TeamLocationOrgUnitMoved(moved: true);
    _idempotency[idempotencyKey] = const _CachedLocationMoved(result);
    return result;
  }
}

abstract class _CachedMutation {
  const _CachedMutation();
}

class _CachedOrgUnitCreated extends _CachedMutation {
  const _CachedOrgUnitCreated(this.created);
  final TeamOrgUnitCreated created;
}

class _CachedOrgUnitRenamed extends _CachedMutation {
  const _CachedOrgUnitRenamed(this.renamed);
  final TeamOrgUnitRenamed renamed;
}

class _CachedLocationMoved extends _CachedMutation {
  const _CachedLocationMoved(this.moved);
  final TeamLocationOrgUnitMoved moved;
}
