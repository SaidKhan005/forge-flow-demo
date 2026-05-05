// Phase 8 Wave B `8.spine-bridge.0` unified CanonicalSink interface.
//
// Spine reference: docs/contracts/integration_spine_architecture_contract.md
// (binding) sections "The canonical chain (binding)" and
// "Sub-lane shape -> .0".
//
// CanonicalSink is the category-uniform write surface that spine-bridge
// lanes `.1.OR` (Oracle MICROS Simphony POS), `.1.QBT` (QuickBooks Time
// labor), and `.1.LB` (Libro reservation) implement against the operator
// scoped Postgres fact tables. Per-vendor sinks already exist on the 17
// Wave B adapters with bespoke method shapes; those bespoke sinks
// COMPOSE this unified interface in lanes `.1.*` rather than being
// replaced. This file is therefore a SEAM ONLY: it adds no Postgres
// imports, no migrations, no behavior. The next lane wires it up.
//
// Hard-Promise alignment (CLAUDE.md Authority Order):
//   * HP #1 (pure transport swap): all writes flow into the existing
//     canonical fact tables. No business logic, no formula change.
//   * HP #4 (per-operator isolation): every method takes
//     `(operatorId, locationId)`; the production-backed implementation
//     wraps each call in `OperatorScopedRepository.withTenant`, never
//     bypassing the repository pattern.
//   * HP #2 (demo mode persists post-launch): [evaluateDemoFlip]
//     centralises the (operator, location, category) flip rule so the
//     same code path runs whether the operator is in demo or live.
//
// Hardening alignment (memory/project_v1_lean_cut_2_2026_05_03.md):
// no encryption-rotation surface declared here, no malformed-payload
// sidecar columns, no advisory-lock primitives, no graceful-shutdown
// hook, no dead-letter UI surface, no raw-payload sibling-table
// writers. The hardening doctrine is enforced by the per-file source
// grep in `test/services/integration/canonical_sink_contract_test.dart`.

import 'integration_adapter_common.dart';

/// Vendor-agnostic write surface for canonical facts.
///
/// Implementations land in lanes `.1.OR`, `.1.QBT`, and `.1.LB`. Each
/// implementation is responsible for:
///
///   * Wrapping every write inside
///     `OperatorScopedRepository.withTenant(operatorId, locationId, ...)`
///     so the repository pattern is the primary tenant defense and
///     Postgres RLS is the backup (HP #4).
///   * Honouring the idempotency UNIQUE on
///     `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
///     for every fact-row upsert (`upsert*Fact`). Repeat writes of the
///     same `(vendor_event_id, vendor_modified_at)` MUST be no-ops and
///     return `false`.
///   * Persisting `connector_sync_watermark.cursor_token` +
///     `last_modified_seen` AFTER each batch commit, NOT only at the
///     end of the whole backfill. [advanceWatermark] is the only seam
///     adapters / dispatchers may call.
///   * Treating [evaluateDemoFlip] as the sole flip evaluator: the
///     idempotent flip-once policy is enforced by the production impl,
///     a second call is a no-op once the row already flipped to live.
abstract class CanonicalSink {
  /// Insert one canonical sales / cover row.
  ///
  /// Idempotency: production impl uses `INSERT ... ON CONFLICT DO
  /// NOTHING` keyed on
  /// `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`.
  /// Returns `true` when a new row landed; returns `false` when the
  /// idempotency UNIQUE short-circuited (replay arrived twice).
  ///
  /// Transactional contract: the call MUST run inside
  /// `OperatorScopedRepository.withTenant(operatorId, locationId, ...)`.
  /// Crash between fact-row commit and watermark commit is acceptable
  /// (idempotency absorbs the replay on resume); crash after watermark
  /// commit means the next tick resumes from the new cursor.
  ///
  /// `canonicalFact` carries the projected vendor-shape -> canonical
  /// row mapping the adapter materialised. Required keys per the
  /// per-vendor field-mapping doc; unknown keys are ignored.
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  });

  /// Insert one canonical labor punch row.
  ///
  /// Same idempotency + transactional contract as [upsertCoverFact].
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  });

  /// Insert one canonical reservation row.
  ///
  /// Same idempotency + transactional contract as [upsertCoverFact].
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  });

  /// Update `connector_sync_watermark.cursor_token` +
  /// `last_modified_seen` for a connection. Called AFTER each batch
  /// commit (not only at end-of-backfill) so a Cloud Run Job restart
  /// resumes from the last successful cursor.
  ///
  /// Implementations MUST persist atomically with the fact-row commits
  /// inside the same `withTenant` transaction; production impl runs
  /// fact upserts and watermark advance in the same tx.
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  });

  /// Append one row to `connector_sync_log`. The sole place adapters /
  /// the dispatcher record polled-batch outcomes (`poll_success`,
  /// `poll_error`, `parse_drop`, `disconnect`, etc.). Idempotent in the
  /// sense that the table is append-only; duplicate rows are tolerated;
  /// the dispatcher relies on monotonic ordering, not row-uniqueness.
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  });

  /// Evaluate whether `(operatorId, locationId, category)` should flip
  /// out of demo mode. Production impl delegates to
  /// `DemoModeFlipPolicy.evaluateFlip` inside the same transaction the
  /// fact-row commit ran in, so a half-applied flip cannot occur.
  ///
  /// Idempotence: a second call with the same `(operatorId, locationId,
  /// category)` after the row already flipped to live is a no-op (the
  /// `flipped_to_live_at` timestamp is preserved, the original
  /// `flipped_by_connection_id` is preserved). Disconnect does NOT
  /// auto-revert. See `lib/services/integration/demo_mode_state.dart`
  /// for the policy contract carried through here.
  ///
  /// Returns `Future<void>`: this lane keeps the flip side-effect on
  /// the sink interface and does not surface the resulting record.
  /// Lanes `.1.*` wire the production policy + the operator-facing
  /// "you're now live" signal (if/when justified).
  Future<void> evaluateDemoFlip({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required ConnectionStatus connectionStatus,
    required bool firstBackfillCommitted,
    required int backfillRecordsWritten,
    required String connectionId,
  });
}
