// Phase 8.0 — Demo-mode-to-live transition.
//
// Per-(operator, location, category) demo flag. Default `is_demo =
// true`. Flips to false when the first INTEGRATE vendor connection
// for that triple reaches `connected` AND the first backfill commits
// >=1 record. Disconnect does NOT auto-revert; historical facts stay
// in canonical tables and are still queryable.
//
// HP #2 (CLAUDE.md): "Demo mode persists post-launch." `kDemoMode` is
// a writer-side switch; same tables, same reads, same UI either way.
//
// Operator-app UX: the demo-mode banner reads runtime state from
// this surface, not from a config flag. Once the operator's first
// vendor connection backfills successfully, the banner clears
// without a redeploy.

import 'integration_adapter_common.dart';

/// One demo-mode row.
class DemoModeRecord {
  const DemoModeRecord({
    required this.operatorId,
    required this.locationId,
    required this.category,
    required this.isDemo,
    this.flippedToLiveAt,
    this.flippedByConnectionId,
  });

  final String operatorId;
  final String locationId;
  final IntegrationCategory category;
  final bool isDemo;
  final DateTime? flippedToLiveAt;
  final String? flippedByConnectionId;
}

/// Gateway interface the policy depends on. Production wires a
/// Postgres-backed implementation; tests pass a fake.
abstract class DemoModeStateGateway {
  /// Read the current row. Inserts a default `is_demo = true` row
  /// when none exists (operator just onboarded).
  Future<DemoModeRecord> readOrCreateDefault({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
  });

  /// Flip `is_demo = false`, set `flipped_to_live_at`, set
  /// `flipped_by_connection_id`. Idempotent: a second flip is a
  /// no-op (we do not re-stamp `flipped_to_live_at`).
  Future<DemoModeRecord> flipToLive({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required String connectionId,
    required DateTime flippedAt,
  });
}

/// Demo-mode flip policy. The framework calls this from two places:
///
///   * After [PosAdapter.connect] (or sibling) returns
///     `status = connected`. The policy checks the connection
///     status; if the first backfill has not yet committed, it does
///     not flip. (This is why the flip is gated on backfill commit,
///     not just on connect.)
///
///   * After the sync worker commits the first backfill batch.
///     `firstBackfillCommitted == true` triggers the flip.
class DemoModeFlipPolicy {
  DemoModeFlipPolicy({required this.gateway, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final DemoModeStateGateway gateway;
  final DateTime Function() _now;

  /// Evaluate whether the (operator, location, category) should
  /// flip out of demo mode. Triggered when a vendor connection
  /// reaches the "connected + first backfill commit >=1 record"
  /// state. Returns the post-flip record.
  Future<DemoModeRecord> evaluateFlip({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required ConnectionStatus connectionStatus,
    required bool firstBackfillCommitted,
    required int backfillRecordsWritten,
    required String connectionId,
  }) async {
    final current = await gateway.readOrCreateDefault(
      operatorId: operatorId,
      locationId: locationId,
      category: category,
    );

    // Idempotence: already live; never auto-revert on disconnect.
    if (!current.isDemo) {
      return current;
    }

    // Both gates must hold to flip.
    if (connectionStatus != ConnectionStatus.connected) return current;
    if (!firstBackfillCommitted) return current;
    if (backfillRecordsWritten < 1) return current;

    return gateway.flipToLive(
      operatorId: operatorId,
      locationId: locationId,
      category: category,
      connectionId: connectionId,
      flippedAt: _now().toUtc(),
    );
  }

  /// Disconnect does NOT auto-revert. Calling this method is a noop
  /// kept here so the policy surface documents the rule.
  Future<DemoModeRecord> handleDisconnect({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
  }) async {
    return gateway.readOrCreateDefault(
      operatorId: operatorId,
      locationId: locationId,
      category: category,
    );
  }
}
