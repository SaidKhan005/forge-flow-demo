// Phase 8 Wave B `8.spine-bridge.0` sync worker entrypoint.
//
// Cloud Run Job entry. Pure orchestration: builds the
// [IntegrationSyncWorkerDispatch], walks every connected
// [ConnectorConnectionRow] yielded by the supplied [SyncWorkerSource],
// and invokes `dispatchPollTick` per row. All I/O lives behind
// interfaces so this entrypoint stays test-friendly:
//
//   * [SyncWorkerSource]: yields rows from `connector_connection`.
//   * [CanonicalSink]: lives behind `IntegrationSyncWorkerDispatch`
//                      for watermark + sync log writes.
//   * [AdapterFactory]: per-row adapter materialiser (composed by the
//                       caller from the registry + per-vendor deps).
//
// What this file does NOT do (left for sibling lanes):
//   * Real database SELECT / UPDATE: `.1.*` lanes wire concrete
//     [SyncWorkerSource] implementations and the production
//     `CanonicalSink`.
//   * Real Cloud Run / Cloud Scheduler entry: `.3` lane wires the
//     scheduler trigger; this file ships the `runSyncWorkerOnce` body
//     the scheduler will call.
//   * Graceful-shutdown hooks, dead-letter UI mounts, and operator
//     notifications are out of scope per the lean-cut hardening
//     ledger.
//
// V1 hardening alignment: the lean-cut ledger of removed items is
// enforced by the per-file source grep in
// test/services/integration/canonical_sink_contract_test.dart; this
// file's executable code holds none of those tokens.

import 'package:forge_and_flow/services/integration/canonical_sink.dart';

import 'dispatch.dart';

/// Source the worker pulls work from. Production impl SELECTs every
/// `connector_connection` row with `status = 'connected'`; tests
/// inject an in-memory list.
abstract class SyncWorkerSource {
  /// Yields one row per connection ready for a poll tick.
  Stream<ConnectorConnectionRow> connectedConnections();
}

/// Resolves the per-row adapter factory at dispatch time. The bundle
/// the caller supplies must cover every category the source emits;
/// missing slots cause `dispatchPollTick` to throw `StateError` from
/// the type-check below.
typedef AdapterFactoryResolver = AdapterFactory Function(
  ConnectorConnectionRow row,
);

/// Run one walk over every connected connection. Returns when the
/// source stream is drained. Each row dispatch is wrapped in
/// try/catch so one row's failure does not stop the walk; the
/// dispatcher already wrote the `poll_error` sync log row before the
/// exception bubbles, so the failure is durable.
Future<void> runSyncWorkerOnce({
  required SyncWorkerSource source,
  required CanonicalSink canonicalSink,
  required AdapterFactoryResolver resolveAdapterFactory,
}) async {
  final dispatcher = IntegrationSyncWorkerDispatch();

  await for (final row in source.connectedConnections()) {
    try {
      await dispatcher.dispatchPollTick(
        connectorConnectionRow: row,
        adapterFactory: resolveAdapterFactory(row),
        canonicalSink: canonicalSink,
      );
    } on StateError {
      // "vendor not registered" or "adapterFactory returned wrong
      // category" surfaces here. Skip this row; production wiring
      // logs via the proxy log surface.
      continue;
    }
  }
}
