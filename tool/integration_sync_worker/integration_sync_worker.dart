// Phase 8.0 — Polling sync worker scaffold (V1 lean cut 2).
//
// One Cloud Run Job per integration category. The framework slice
// ships only the scaffold; per-vendor adapters land in subsequent
// slices and register themselves with the worker via the adapter
// catalog. Per the framework spec:
//
//   * Polling-driven by default; webhook-driven where the vendor
//     supports it; hybrid where both are available.
//   * Watermark cursor persists per BATCH commit, not per backfill
//     end. Worker restart resumes from the last persisted cursor.
//   * Vendor timestamp sanity guard runs before each canonical-fact
//     write. Future-dated, out-of-order, or suspiciously-old events
//     are dropped + logged via `sanity_log` /
//     `connector_sync_log`.
//   * V1 lean cut 2 — Cloud Run's default drain handles V1 traffic.
//     There is NO custom SIGTERM graceful-drain handler. The
//     watermark-per-batch-commit guarantee is what makes restart
//     resilient.
//
// This file is the runner. Tests drive it directly with a fake
// adapter catalog + gateway; production wires it via the Cloud Run
// Job entrypoint at the bottom of the file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/labor_adapter.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';
import 'package:forge_and_flow/services/integration/reservation_adapter.dart';
import 'package:forge_and_flow/services/integration/vendor_timestamp_sanity.dart';

/// One pollable connection row the worker iterates over per tick.
class PollableConnection {
  const PollableConnection({
    required this.connectionId,
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.category,
    required this.lastModifiedSeen,
    this.cursorToken,
    required this.actorUserId,
  });

  final String connectionId;
  final String operatorId;
  final String locationId;
  final String vendorId;
  final IntegrationCategory category;
  final DateTime lastModifiedSeen;
  final String? cursorToken;
  final String actorUserId;
}

/// Sync worker gateway. Production wires Postgres-backed methods;
/// tests pass an in-memory fake.
abstract class IntegrationSyncWorkerGateway {
  /// Connections that are due for a poll.
  Future<List<PollableConnection>> findDueConnections({
    required DateTime now,
    int limit = 100,
  });

  /// Persist the new watermark cursor + last_modified_seen AFTER
  /// each successful batch commit. Production writes
  /// `connector_sync_watermark` inside the same transaction the
  /// adapter used to write canonical facts, so a crash between
  /// batches preserves the cursor at the last fully-committed batch.
  Future<void> persistWatermark({
    required String connectionId,
    required String operatorId,
    required String locationId,
    required String resource,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  });

  /// Append a `connector_sync_log` row.
  Future<void> appendSyncLog({
    required String connectionId,
    required String operatorId,
    required String locationId,
    required String eventKind,
    int? recordsCount,
    String? errorMessage,
    int? durationMs,
  });

  /// V1 lean cut 2 — adapter-boundary sanity drop. Writes a row into
  /// `sanity_log` and a `connector_sync_log` entry of kind
  /// `sanity_drop`. No canonical fact is written.
  Future<void> recordSanityDrop({
    required String connectionId,
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required String rule,
    required Map<String, Object?> payloadSummary,
  });
}

/// One tick's tally for telemetry.
class IntegrationSyncTickResult {
  const IntegrationSyncTickResult({
    required this.connectionsProcessed,
    required this.recordsWritten,
    required this.errors,
    required this.sanityDropped,
  });

  final int connectionsProcessed;
  final int recordsWritten;
  final int errors;
  final int sanityDropped;
}

/// Per-tick worker. Stateless across ticks; the gateway holds all
/// transactional state.
class IntegrationSyncWorker {
  IntegrationSyncWorker({
    required this.gateway,
    required this.posAdapters,
    required this.laborAdapters,
    required this.reservationAdapters,
    VendorTimestampSanity? sanityChecker,
    DateTime Function()? now,
  })  : sanityChecker = sanityChecker ?? const VendorTimestampSanity(),
        _now = now ?? DateTime.now;

  final IntegrationSyncWorkerGateway gateway;
  final Map<String, PosAdapter> posAdapters;
  final Map<String, LaborAdapter> laborAdapters;
  final Map<String, ReservationAdapter> reservationAdapters;
  final VendorTimestampSanity sanityChecker;
  final DateTime Function() _now;

  /// Run one tick. The Cloud Run Job invokes this on a poll
  /// interval; tests call it directly.
  Future<IntegrationSyncTickResult> runOnce() async {
    final now = _now().toUtc();
    final due = await gateway.findDueConnections(now: now);

    var connectionsProcessed = 0;
    var recordsWritten = 0;
    var errors = 0;
    var sanityDropped = 0;

    for (final conn in due) {
      final tickStart = _now();
      try {
        // V1 lean cut 2 — bind a connection-scoped sanity hook so the
        // adapter cannot bypass the timestamp guard on the polling
        // path. Adapters MUST call this before each canonical fact
        // write and skip the write when it returns false.
        Future<bool> boundSanityHook({
          required String vendorEventId,
          required Map<String, Object?> payload,
          required bool isDeliberateBackfill,
        }) {
          return passesSanity(
            connectionId: conn.connectionId,
            operatorId: conn.operatorId,
            locationId: conn.locationId,
            vendorId: conn.vendorId,
            vendorEventId: vendorEventId,
            payload: payload,
            isDeliberateBackfill: isDeliberateBackfill,
          );
        }

        final command = PollIncrementalCommand(
          operatorId: conn.operatorId,
          locationId: conn.locationId,
          actorUserId: conn.actorUserId,
          vendorId: conn.vendorId,
          lastModifiedSeen: conn.lastModifiedSeen,
          cursorToken: conn.cursorToken,
          sanityHook: boundSanityHook,
        );
        PollIncrementalResult result;
        switch (conn.category) {
          case IntegrationCategory.pos:
            final adapter = posAdapters[conn.vendorId];
            if (adapter == null) continue;
            result = await adapter.pollIncremental(command);
          case IntegrationCategory.labor:
            final adapter = laborAdapters[conn.vendorId];
            if (adapter == null) continue;
            result = await adapter.pollIncremental(command);
          case IntegrationCategory.reservation:
            final adapter = reservationAdapters[conn.vendorId];
            if (adapter == null) continue;
            result = await adapter.pollIncremental(command);
        }
        // Persist watermark per batch commit. Production wires this
        // inside the same Postgres transaction the adapter used to
        // write canonical facts so a crash mid-batch preserves the
        // cursor at the last fully-committed batch boundary. This
        // is what makes the worker resilient to Cloud Run restarts
        // without a custom SIGTERM handler.
        await gateway.persistWatermark(
          connectionId: conn.connectionId,
          operatorId: conn.operatorId,
          locationId: conn.locationId,
          resource: _resourceFor(conn.category),
          cursorToken: result.newCursorToken,
          lastModifiedSeen: result.newLastModifiedSeen,
        );
        await gateway.appendSyncLog(
          connectionId: conn.connectionId,
          operatorId: conn.operatorId,
          locationId: conn.locationId,
          eventKind: 'poll_success',
          recordsCount: result.recordsWritten,
          durationMs: _now().difference(tickStart).inMilliseconds,
        );
        recordsWritten += result.recordsWritten;
        sanityDropped += result.sanityDropped;
        connectionsProcessed += 1;
      } catch (error) {
        errors += 1;
        await gateway.appendSyncLog(
          connectionId: conn.connectionId,
          operatorId: conn.operatorId,
          locationId: conn.locationId,
          eventKind: 'poll_error',
          errorMessage: error.toString(),
          durationMs: _now().difference(tickStart).inMilliseconds,
        );
      }
    }

    return IntegrationSyncTickResult(
      connectionsProcessed: connectionsProcessed,
      recordsWritten: recordsWritten,
      errors: errors,
      sanityDropped: sanityDropped,
    );
  }

  /// Sanity-drop hook for adapters that produce candidate canonical
  /// facts via polling. Call this BEFORE writing the canonical fact;
  /// when it returns `false` the caller MUST skip the write.
  Future<bool> passesSanity({
    required String connectionId,
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required Map<String, Object?> payload,
    required bool isDeliberateBackfill,
  }) async {
    final result = sanityChecker.evaluate(
      payload: payload,
      now: _now().toUtc(),
      isDeliberateBackfill: isDeliberateBackfill,
    );
    if (!result.failed) return true;
    await gateway.recordSanityDrop(
      connectionId: connectionId,
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      vendorEventId: vendorEventId,
      rule: result.rule!.sqlValue,
      payloadSummary: result.payloadSummary,
    );
    await gateway.appendSyncLog(
      connectionId: connectionId,
      operatorId: operatorId,
      locationId: locationId,
      eventKind: 'sanity_drop',
      errorMessage: result.message,
    );
    return false;
  }

  String _resourceFor(IntegrationCategory category) {
    switch (category) {
      case IntegrationCategory.pos:
        return 'orders';
      case IntegrationCategory.labor:
        return 'punches';
      case IntegrationCategory.reservation:
        return 'reservations';
    }
  }
}

/// Per-tick error event surfaced by [integrationSyncWorkerMain].
///
/// The runner writes a `poll_error` row to `connector_sync_log` for
/// per-row failures inside [IntegrationSyncWorker.runOnce]; an
/// exception that escapes that loop (gateway SELECT failure, dispatch
/// resolution that wasn't caught downstream, etc.) reaches the outer
/// loop wrapper. We classify it for observability instead of swallowing
/// blind, and never crash the long-running loop.
class IntegrationSyncWorkerLoopError {
  const IntegrationSyncWorkerLoopError({
    required this.kind,
    required this.error,
    required this.stackTrace,
  });

  /// `'timeout'` for [TimeoutException]; `'exception'` for any other
  /// `Exception`; `'unhandled'` for non-`Exception` `Object` throws.
  final String kind;
  final Object error;
  final StackTrace stackTrace;

  Map<String, Object?> toLogFields() => <String, Object?>{
        'worker': 'integration_sync',
        'event': 'tick_error',
        'kind': kind,
        'error': error.toString(),
        'stackTrace': stackTrace.toString(),
      };
}

/// Reporter contract for per-tick loop errors. Tests inject a
/// recorder; production wires a JSON-line writer to stderr.
typedef IntegrationSyncWorkerLoopErrorReporter = void Function(
  IntegrationSyncWorkerLoopError error,
);

/// Default reporter: write a single-line JSON to stderr so Cloud Run /
/// log routing keeps structured fields intact.
void _defaultLoopErrorReporter(IntegrationSyncWorkerLoopError error) {
  stderr.writeln(jsonEncode(error.toLogFields()));
}

/// Cloud Run Job entrypoint. V1 lean cut 2 — Cloud Run's default
/// drain handles SIGTERM. The custom drain handler from iter1 was
/// removed: watermark-per-batch-commit makes the worker restart-
/// resilient without it.
///
/// The outer loop catches typed error classes — `TimeoutException`,
/// then any `Exception`, then any `Object` — so a non-`Exception`
/// throw cannot crash the tick cadence. Each captured error is
/// surfaced through [reportError] with structured fields
/// (`worker`, `event`, `kind`, `error`, `stackTrace`) so the deploy's
/// log router can fan it out to metrics. Tests inject a recording
/// reporter to assert the loop continues past per-tick failures.
///
/// `tickCount` (test-only) bounds the loop iteration count so the
/// tick cadence can be exercised under `flutter_test` without
/// `runZoned` wallclock manipulation. Production passes nothing and
/// the loop runs forever.
Future<void> integrationSyncWorkerMain(
  IntegrationSyncWorker worker, {
  Duration tickInterval = const Duration(seconds: 30),
  IntegrationSyncWorkerLoopErrorReporter reportError =
      _defaultLoopErrorReporter,
  int? tickCount,
}) async {
  var ticksRun = 0;
  while (tickCount == null || ticksRun < tickCount) {
    try {
      await worker.runOnce();
    } on TimeoutException catch (e, st) {
      // Gateway SELECT or downstream call timed out. Log structured;
      // the tick cadence keeps running so the next iteration retries
      // against a (likely) recovered DB connection.
      reportError(IntegrationSyncWorkerLoopError(
        kind: 'timeout',
        error: e,
        stackTrace: st,
      ));
    } on Exception catch (e, st) {
      // Per-row failures already flushed `poll_error` to
      // `connector_sync_log` inside [runOnce]; an exception that
      // bubbles here means the SELECT itself failed (DB unreachable,
      // role-elevate refused, etc.). Don't crash the loop — log and
      // tick again.
      reportError(IntegrationSyncWorkerLoopError(
        kind: 'exception',
        error: e,
        stackTrace: st,
      ));
    } on Object catch (e, st) {
      // Non-`Exception` throws (StateError chained from `Object`,
      // raw `String` throws, etc.). Same posture as `Exception`:
      // surface and keep ticking.
      reportError(IntegrationSyncWorkerLoopError(
        kind: 'unhandled',
        error: e,
        stackTrace: st,
      ));
    }
    ticksRun += 1;
    if (tickCount != null && ticksRun >= tickCount) break;
    await Future<void>.delayed(tickInterval);
  }
}
