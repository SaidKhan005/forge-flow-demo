// Phase 8 Wave B `8.spine-bridge.0` sync worker dispatch.
//
// Spine reference: docs/contracts/integration_spine_architecture_contract.md
// (binding) section "Sub-lane shape -> .0".
//
// Pure logic. One row at a time, derives the right category-scoped
// registry from `connector_connection.category`, runs the supplied
// `adapterFactory` against the row, and bridges the adapter's poll /
// webhook results back through the unified [CanonicalSink]
// (`advanceWatermark`, `appendSyncLog`).
//
// What this lane does NOT do (left for sibling lanes):
//   * `.1.OR` / `.1.QBT` / `.1.LB`: production-backed [CanonicalSink]
//     implementations.
//   * `.2`: `CanonicalFact -> ClosedShiftInput` adapter (the bridge
//     into the formula layer).
//   * `.3`: Cloud Tasks / Cloud Scheduler wiring.
//
// V1 hardening alignment: the lean-cut ledger of removed items is
// enforced by the per-file source grep in
// test/services/integration/canonical_sink_contract_test.dart; this
// file's executable code holds none of those tokens.

import 'package:forge_and_flow/domain/models/forge_flow_polling_tier_assignment.dart';
import 'package:forge_and_flow/services/integration/canonical_sink.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/labor_adapter.dart';
import 'package:forge_and_flow/services/integration/polling_cadence_resolver.dart';
import 'package:forge_and_flow/services/integration/polling_tier_presets.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';
import 'package:forge_and_flow/services/integration/projecting_canonical_sink.dart';
import 'package:forge_and_flow/services/integration/reservation_adapter.dart';

import '../advisor_proxy/labor_adapter_registry.dart';
import '../advisor_proxy/pos_adapter_registry.dart';
import '../advisor_proxy/reservation_adapter_registry.dart';
import '../advisor_proxy/vendor_capability_index.dart';

// ─── Connector-connection row (worker view) ─────────────────────────

/// Subset of the `connector_connection` row the dispatcher needs to
/// drive one tick. Production wires this from a database SELECT in
/// `tool/integration_sync_worker/main.dart`; tests construct it inline.
class ConnectorConnectionRow {
  const ConnectorConnectionRow({
    required this.connectionId,
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.category,
    required this.status,
    required this.lastModifiedSeen,
    this.cursorToken,
  });

  final String connectionId;
  final String operatorId;
  final String locationId;
  final String vendorId;
  final IntegrationCategory category;
  final ConnectionStatus status;

  /// `connector_sync_watermark.last_modified_seen` for this connection.
  /// Worker passes this into [PollIncrementalCommand.lastModifiedSeen].
  final DateTime lastModifiedSeen;

  /// Optional pagination cursor (when the prior poll did not finish
  /// the page chain).
  final String? cursorToken;
}

// ─── Adapter factory (caller-supplied) ──────────────────────────────

/// Closure that materialises the right-category adapter for the
/// connection row. Caller composes this from
/// `lookup{Pos,Labor,Reservation}Adapter` + the per-vendor deps record
/// the production wiring constructed at boot.
///
/// The returned object MUST be one of [PosAdapter] / [LaborAdapter] /
/// [ReservationAdapter] matching [ConnectorConnectionRow.category];
/// the dispatcher type-checks at call time and throws `StateError` on
/// mismatch so a misconfigured factory fails loud.
typedef AdapterFactory = Object Function(ConnectorConnectionRow row);

/// Service-principal `actor_user_id` the worker stamps onto
/// [PollIncrementalCommand]. Adapters that materialise a
/// `TenantContext` from the command (e.g., Lightspeed K-Series) bind
/// this as `userId`, which validates against the project-wide UUID
/// pattern. Per CLAUDE.md: non-human actors authenticate with `sp:`
/// JWTs at the proxy boundary; downstream the tenant context carries
/// a UUID-shaped sentinel so RLS-helper SQL stays type-stable.
const String kSyncWorkerServicePrincipalId =
    '00000000-0000-4000-8000-100000000001';

/// Default poll cadence per the spine-bridge contract section
/// "Sub-lane shape -> .0": "calls `pollIncremental` per cadence
/// (vendor-defined; default 60s)". Lane `.0` exposes this as a single
/// hardcoded constant; Lane `.0a`
/// (`lib/services/integration/polling_cadence_resolver.dart`)
/// supersedes it with a per-(operator, location, vendor) tier-driven
/// resolver without changing this surface — the resolver falls back
/// to this constant when no override applies.
const Duration kDefaultPollCadence = Duration(seconds: 60);

// ─── Dispatch ───────────────────────────────────────────────────────

/// Lookup signature: returns the currently-effective F&F polling tier
/// assignment for `(operatorId, locationId)`, or null when none has
/// been assigned yet. Lane `.A`'s `ForgeFlowPollingTierRepository`
/// satisfies this signature; tests inject an in-memory closure.
typedef PollingTierAssignmentLookup =
    Future<ForgeFlowPollingTierAssignment?> Function(
      String operatorId,
      String locationId,
    );

/// Lookup signature: returns the vendor-documented minimum poll cadence
/// (in seconds) for `vendorId`. Sourced from each vendor's
/// `docs/integrations/<vendor_id>/api_consumed.md` "Production
/// environment -> Rate-limit policy" section. Production wiring is the
/// per-vendor capability profile; tests inject a small constant map.
typedef VendorMinimumCadenceLookup = int Function(String vendorId);

/// Sink signature: receives the resolved cadence (in seconds) the
/// dispatcher computed for `(connectionId, vendorId)` on this tick.
/// Replaces the prior pattern where the resolver's return value was
/// computed-and-discarded. The callback is the seam the scheduling
/// layer (Lane `.3` / loop main.dart) plugs into to drive a per-
/// connection next-tick: e.g., `nextPollAt = now() + Duration(seconds:
/// resolvedCadenceSeconds)`. Default null keeps the dispatcher
/// backward-compatible — callers that have not opted in see the same
/// surface as before, and the resolved-int is simply not delivered.
typedef ResolvedCadenceSink =
    void Function({
      required String connectionId,
      required String vendorId,
      required String operatorId,
      required String locationId,
      required int resolvedCadenceSeconds,
    });

/// Pure-logic dispatcher exercised under fakes by
/// `test/tool/integration_sync_worker/dispatch_test.dart`. The only
/// I/O is whatever the supplied [CanonicalSink] performs.
class IntegrationSyncWorkerDispatch {
  IntegrationSyncWorkerDispatch({
    DateTime Function()? now,
    this.tierAssignmentLookup,
    this.vendorMinimumCadenceLookup,
    this.resolvedCadenceSink,
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  /// Lane `.0a` wiring. When non-null, every poll tick consults
  /// [PollingCadenceResolver] to surface tier-assignment-driven
  /// cadence + emit `tier_assignment_missing` /
  /// `cadence_clamped` / `custom_tier_vendor_unset` sync_log rows.
  /// Default null keeps the surface backward-compatible: existing
  /// callers (Lane `.0` tests, `runSyncWorkerOnce` in `main.dart`)
  /// pass nothing and the resolver is never invoked. Lane `.C` wires
  /// `ForgeFlowPollingTierRepository.readCurrentAssignment` here.
  final PollingTierAssignmentLookup? tierAssignmentLookup;

  /// Companion lookup for [tierAssignmentLookup]: vendor-documented
  /// minimum poll cadence in seconds. Both must be supplied together
  /// to enable the resolver call inside [dispatchPollTick]; either
  /// being null leaves the resolver path inactive.
  final VendorMinimumCadenceLookup? vendorMinimumCadenceLookup;

  /// Optional consumer for the resolved cadence value. When the
  /// resolver path is active (both lookups wired + the connection's
  /// vendor is poll-only) the dispatcher delivers the resolved
  /// cadence-seconds here so the scheduling layer can drive a per-
  /// connection next-tick (e.g., `Duration(seconds: resolvedSeconds)`)
  /// rather than the worker's single global tick interval. The prior
  /// shape computed-and-discarded the resolver's return value
  /// (CODE_HEALTH: "Cadence resolver's resolved value discarded —
  /// tier assignments observability-only today"); routing the value
  /// through this seam closes the seam-side half of that concern.
  /// Default null preserves the lane `.0` baseline.
  final ResolvedCadenceSink? resolvedCadenceSink;

  /// One poll tick for one [ConnectorConnectionRow]. The dispatcher:
  ///
  ///   1. Verifies the row's `vendorId` is registered in the right
  ///      category-scoped registry, otherwise throws `StateError` so
  ///      the worker logs and skips the row (vendor was retired or
  ///      the column drifted).
  ///   2. Builds the per-row adapter via the supplied factory (which
  ///      closes over the per-vendor deps record).
  ///   3. Constructs a [PollIncrementalCommand] with a sanity-hook
  ///      closure bound to the connection's tenant context.
  ///   4. Calls `adapter.pollIncremental` once.
  ///   5. On success: [CanonicalSink.advanceWatermark] +
  ///      [CanonicalSink.appendSyncLog] `'poll_success'`.
  ///   6. On adapter throw: [CanonicalSink.appendSyncLog] `'poll_error'`
  ///      with the exception text. Watermark is NOT advanced. The
  ///      `consecutive_refresh_failures` increment is logic computed
  ///      by the `.1.*` lane alongside the persistent worker sink; this
  ///      lane intentionally keeps the dispatch interface
  ///      `Future<void>` per the spine contract.
  Future<void> dispatchPollTick({
    required ConnectorConnectionRow connectorConnectionRow,
    required AdapterFactory adapterFactory,
    required CanonicalSink canonicalSink,
    CanonicalFactProjectionCommitDrainer? projectionCommitDrainer,
  }) async {
    final row = connectorConnectionRow;

    if (!_isVendorRegistered(row.vendorId, row.category)) {
      // Spine contract Lane `.0` test req: "missing adapter returns
      // null + logs". The lookup-side null is in the registry; this
      // is the durable observability log row the framework emits when
      // a connected row references a retired or drifted vendor_id.
      // The poll tick itself remains undispatchable, so the worker
      // catches the StateError below and skips the row.
      await canonicalSink.appendSyncLog(
        operatorId: row.operatorId,
        locationId: row.locationId,
        connectionId: row.connectionId,
        eventKind: 'vendor_not_registered',
        errorMessage:
            'vendor "${row.vendorId}" is not registered in the '
            '${row.category.name} adapter registry; poll tick skipped',
      );
      throw StateError(
        'vendor "${row.vendorId}" is not registered in the '
        '${row.category.name} adapter registry; row '
        '${row.connectionId} cannot be dispatched',
      );
    }

    final tenantOperatorId = row.operatorId;
    final tenantLocationId = row.locationId;
    Future<bool> sanityHook({
      required String vendorEventId,
      required Map<String, Object?> payload,
      required bool isDeliberateBackfill,
    }) async {
      // Closure captures (operatorId, locationId) via the surrounding
      // scope so the eventual `.1.*` real implementation can write
      // sanity_log rows scoped to the right tenant. This lane keeps
      // the seam intact (returns true) so adapters' contractual call
      // does not short-circuit the happy path during the spine-bridge
      // transition.
      assert(tenantOperatorId.isNotEmpty);
      assert(tenantLocationId.isNotEmpty);
      return true;
    }

    final command = PollIncrementalCommand(
      operatorId: row.operatorId,
      locationId: row.locationId,
      actorUserId: kSyncWorkerServicePrincipalId,
      vendorId: row.vendorId,
      lastModifiedSeen: row.lastModifiedSeen,
      sanityHook: sanityHook,
      cursorToken: row.cursorToken,
    );

    // Resolve adapter + start poll UPFRONT so misconfigured wiring
    // (`StateError`) fails loud before any sync_log is written.
    // Adapter-call exceptions remain caught below and turn into
    // poll_error log rows.
    final pollFuture = _startPoll(row, adapterFactory, command);

    try {
      final result = await pollFuture;

      await canonicalSink.advanceWatermark(
        operatorId: row.operatorId,
        locationId: row.locationId,
        connectionId: row.connectionId,
        cursorToken: result.newCursorToken,
        lastModifiedSeen: result.newLastModifiedSeen,
      );

      await canonicalSink.appendSyncLog(
        operatorId: row.operatorId,
        locationId: row.locationId,
        connectionId: row.connectionId,
        eventKind: 'poll_success',
        recordsCount: result.recordsWritten,
      );
      await projectionCommitDrainer?.drainIfCommitEvent(
        vendorId: row.vendorId,
        operatorId: row.operatorId,
        locationId: row.locationId,
        connectionId: row.connectionId,
        eventKind: 'poll_success',
      );
    } catch (error) {
      // Adapter-thrown errors become a durable poll_error sync_log
      // row; the worker continues to the next connection.
      await canonicalSink.appendSyncLog(
        operatorId: row.operatorId,
        locationId: row.locationId,
        connectionId: row.connectionId,
        eventKind: 'poll_error',
        errorMessage: error.toString(),
      );
    } finally {
      await _resolveCadenceForRow(row, canonicalSink);
    }
  }

  /// Inbound webhook dispatch. Returns to `InboundWebhookHandler` for
  /// framework-side idempotency / signature handling. Per the spine
  /// contract this method just resolves the right adapter and forwards
  /// to `handleWebhook`; signature, replay defense, binding, and
  /// idempotency are owned by the existing handler.
  ///
  /// `canonicalSink` is required so the seam can write a durable
  /// `vendor_not_registered` log row before throwing when a webhook
  /// arrives for a `connector_connection` whose `vendor_id` no longer
  /// resolves in the category registry (retirement / drift). Per the
  /// spine contract Lane `.0` test req: "missing adapter returns null
  /// + logs". `.1.*` Postgres sinks compose [CanonicalSink] so the
  /// caller already has one in hand.
  Future<void> dispatchWebhook({
    required ConnectorConnectionRow connectorConnectionRow,
    required AdapterFactory adapterFactory,
    required CanonicalSink canonicalSink,
    required String vendorEventId,
    required Map<String, Object?> payload,
    required Map<String, String> headers,
  }) async {
    final row = connectorConnectionRow;

    if (!_isVendorRegistered(row.vendorId, row.category)) {
      await canonicalSink.appendSyncLog(
        operatorId: row.operatorId,
        locationId: row.locationId,
        connectionId: row.connectionId,
        eventKind: 'vendor_not_registered',
        errorMessage:
            'vendor "${row.vendorId}" is not registered in the '
            '${row.category.name} adapter registry; webhook discarded',
      );
      throw StateError(
        'vendor "${row.vendorId}" is not registered in the '
        '${row.category.name} adapter registry; webhook for '
        'connection ${row.connectionId} cannot be dispatched',
      );
    }

    final command = HandleWebhookCommand(
      operatorId: row.operatorId,
      locationId: row.locationId,
      vendorId: row.vendorId,
      vendorEventId: vendorEventId,
      payload: payload,
      headers: headers,
      receivedAt: _now().toUtc(),
    );

    await _startWebhook(row, adapterFactory, command);
  }

  // ─── Internals ────────────────────────────────────────────────────

  /// Lane `.0a` resolver hook. When [tierAssignmentLookup] +
  /// [vendorMinimumCadenceLookup] are both wired, this consults the
  /// F&F-controlled tier assignment for `(operatorId, locationId)`,
  /// resolves the per-vendor cadence (clamped to vendor min/framework
  /// max), and forwards the resolver's `onSyncLog` events to the
  /// canonical sink so `tier_assignment_missing` / `cadence_clamped` /
  /// `custom_tier_vendor_unset` rows surface in the per-tenant audit
  /// timeline.
  ///
  /// The resolved cadence value is delivered to [resolvedCadenceSink]
  /// when one is supplied — that is the seam Lane `.3` (worker
  /// scheduling) plugs into so per-connection next-tick uses the
  /// resolved value instead of the worker's single global poll
  /// interval. When [resolvedCadenceSink] is null the value is
  /// dropped silently, which keeps the lane `.0` baseline intact.
  /// (The audit's "tier assignments observability-only" concern lives
  /// in the not-yet-wired downstream consumer, not in this seam.)
  ///
  /// Three gates keep this hook quiet for callers that have not opted
  /// in:
  ///   * Either lookup is null (Lane `.0` baseline + existing tests)
  ///     -> no-op, no log row, resolvedCadenceSink not invoked.
  ///   * The connection's vendor is NOT in [pollOnlyVendorIds]
  ///     (webhook-driven vendors like Toast / 7shifts / ADP) ->
  ///     no-op. Polling cadence is irrelevant for `autoRegister` /
  ///     `manualPaste` vendors per
  ///     `data_accuracy_settings_contract.md` "Transport-bounded
  ///     live-ness" — emitting `tier_assignment_missing` for those
  ///     vendors would create audit noise.
  ///   * The lookup throws (DB connection lost, repository
  ///     unavailable, etc.) -> a single
  ///     `tier_assignment_lookup_failed` sync_log row is written and
  ///     the poll proceeds with default scheduling. The exception
  ///     does NOT bubble into the surrounding `try/catch` (which
  ///     would mis-tag the failure as a `poll_error`), and
  ///     resolvedCadenceSink is not invoked.
  Future<void> _resolveCadenceForRow(
    ConnectorConnectionRow row,
    CanonicalSink canonicalSink,
  ) async {
    final tierLookup = tierAssignmentLookup;
    final vendorMinLookup = vendorMinimumCadenceLookup;
    if (tierLookup == null || vendorMinLookup == null) return;
    if (!pollOnlyVendorIds.contains(row.vendorId)) return;

    ForgeFlowPollingTierAssignment? tierAssignment;
    try {
      tierAssignment = await tierLookup(row.operatorId, row.locationId);
    } catch (error) {
      await canonicalSink.appendSyncLog(
        operatorId: row.operatorId,
        locationId: row.locationId,
        connectionId: row.connectionId,
        eventKind: 'tier_assignment_lookup_failed',
        errorMessage: error.toString(),
      );
      return;
    }

    final pendingLogs = <Future<void>>[];
    final resolvedCadenceSeconds = PollingCadenceResolver.resolve(
      vendorId: row.vendorId,
      tierAssignment: tierAssignment,
      vendorMinimumCadenceSeconds: vendorMinLookup(row.vendorId),
      frameworkMaximumCadenceSeconds: kFrameworkMaximumCadenceSeconds,
      onSyncLog: (eventKind, payload) {
        pendingLogs.add(
          canonicalSink.appendSyncLog(
            operatorId: row.operatorId,
            locationId: row.locationId,
            connectionId: row.connectionId,
            eventKind: eventKind,
            payloadPreview: payload,
          ),
        );
      },
    );
    // Forward the resolved cadence to the scheduling-layer consumer.
    // Prior shape: the resolver's return value was discarded, leaving
    // tier assignments observability-only. Now the value flows out of
    // the dispatcher cleanly so a downstream consumer can drive
    // per-connection next-tick scheduling.
    final cadenceSink = resolvedCadenceSink;
    if (cadenceSink != null) {
      cadenceSink(
        connectionId: row.connectionId,
        vendorId: row.vendorId,
        operatorId: row.operatorId,
        locationId: row.locationId,
        resolvedCadenceSeconds: resolvedCadenceSeconds,
      );
    }
    if (pendingLogs.isNotEmpty) await Future.wait(pendingLogs);
  }

  bool _isVendorRegistered(String vendorId, IntegrationCategory category) {
    switch (category) {
      case IntegrationCategory.pos:
        return registeredPosVendorIds.contains(vendorId);
      case IntegrationCategory.labor:
        return registeredLaborVendorIds.contains(vendorId);
      case IntegrationCategory.reservation:
        return registeredReservationVendorIds.contains(vendorId);
    }
  }

  /// Materialises the adapter and kicks off `pollIncremental`. Throws
  /// `StateError` synchronously when the factory hands back the wrong
  /// category type, so the caller can fail loud BEFORE writing any
  /// sync_log row. The returned future carries any adapter-thrown
  /// poll error.
  Future<PollIncrementalResult> _startPoll(
    ConnectorConnectionRow row,
    AdapterFactory adapterFactory,
    PollIncrementalCommand command,
  ) {
    final adapter = adapterFactory(row);
    switch (row.category) {
      case IntegrationCategory.pos:
        if (adapter is! PosAdapter) {
          throw StateError(
            'adapterFactory for pos vendor "${row.vendorId}" returned '
            '${adapter.runtimeType}; expected PosAdapter',
          );
        }
        return adapter.pollIncremental(command);
      case IntegrationCategory.labor:
        if (adapter is! LaborAdapter) {
          throw StateError(
            'adapterFactory for labor vendor "${row.vendorId}" returned '
            '${adapter.runtimeType}; expected LaborAdapter',
          );
        }
        return adapter.pollIncremental(command);
      case IntegrationCategory.reservation:
        if (adapter is! ReservationAdapter) {
          throw StateError(
            'adapterFactory for reservation vendor "${row.vendorId}" '
            'returned ${adapter.runtimeType}; expected ReservationAdapter',
          );
        }
        return adapter.pollIncremental(command);
    }
  }

  /// Materialises the adapter and forwards to `handleWebhook`. Throws
  /// `StateError` synchronously when the factory hands back the wrong
  /// category type.
  Future<HandleWebhookResult> _startWebhook(
    ConnectorConnectionRow row,
    AdapterFactory adapterFactory,
    HandleWebhookCommand command,
  ) {
    final adapter = adapterFactory(row);
    switch (row.category) {
      case IntegrationCategory.pos:
        if (adapter is! PosAdapter) {
          throw StateError(
            'adapterFactory for pos vendor "${row.vendorId}" returned '
            '${adapter.runtimeType}; expected PosAdapter',
          );
        }
        return adapter.handleWebhook(command);
      case IntegrationCategory.labor:
        if (adapter is! LaborAdapter) {
          throw StateError(
            'adapterFactory for labor vendor "${row.vendorId}" returned '
            '${adapter.runtimeType}; expected LaborAdapter',
          );
        }
        return adapter.handleWebhook(command);
      case IntegrationCategory.reservation:
        if (adapter is! ReservationAdapter) {
          throw StateError(
            'adapterFactory for reservation vendor "${row.vendorId}" '
            'returned ${adapter.runtimeType}; expected ReservationAdapter',
          );
        }
        return adapter.handleWebhook(command);
    }
  }
}
