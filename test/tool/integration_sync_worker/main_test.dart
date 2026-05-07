// Phase 8 Wave B `8.spine-bridge.0` integration_sync_worker entrypoint
// tests.
//
// Covers the wire-in scenarios introduced by the production runner
// without touching live Postgres or vendor HTTP:
//
//   * happy path tick: source yields two connected rows, the runner
//     awaits the resolver, the dispatcher writes a watermark advance +
//     poll_success log per row, the tally counts succeeded=2.
//   * partial failure tick: one row's adapter throws; the dispatcher
//     writes a poll_error log for that row but does NOT advance its
//     watermark, and the runner continues to the second row.
//   * resolver-side disabled vendor: a row whose vendor is in the
//     binder's disabledVendors map surfaces a poll_error sync_log row
//     with the disabled reason; the dispatcher is NEVER called for
//     that row.
//   * resolver-side not-wired vendor: the runner emits a
//     vendor_not_registered sync_log row and skips the row.
//   * runCli with overrides: returns 0 + emits a JSON exit log
//     containing the tally.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/canonical_sink.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';

import '../../../tool/integration_sync_worker/dispatch.dart';
import '../../../tool/integration_sync_worker/main.dart';

const String _opId = '11111111-1111-4111-8111-111111111111';
const String _locId = '22222222-2222-4222-8222-222222222222';

void main() {
  group('runSyncWorkerOnce', () {
    test(
      'happy path: two connected rows → two poll_success logs + two '
      'watermark advances + tally succeeded=2',
      () async {
        final source = _FakeSource(<ConnectorConnectionRow>[
          _posRow(connectionId: 'conn-1'),
          _posRow(connectionId: 'conn-2'),
        ]);
        final sink = _RecordingCanonicalSink();
        final adapter = _RecordingPosAdapter()
          ..pollResult = PollIncrementalResult(
            recordsWritten: 5,
            newCursorToken: 'cursor-after-tick',
            newLastModifiedSeen: DateTime.utc(2026, 5, 4, 12),
          );

        final result = await runSyncWorkerOnce(
          source: source,
          canonicalSink: sink,
          resolveAdapterFactory: (_) async => adapter,
        );

        expect(result.processed, 2);
        expect(result.succeeded, 2);
        expect(result.failed, 0);
        expect(result.skipped, 0);
        expect(result.watermarkAdvanced, 2);
        expect(adapter.pollCalls, 2);
        expect(sink.watermarkAdvances, hasLength(2));
        expect(sink.syncLogs, hasLength(2));
        expect(
          sink.syncLogs.every((entry) => entry.eventKind == 'poll_success'),
          isTrue,
        );
      },
    );

    test(
      'adapter throw: one poll_error log, no watermark advance for that '
      'row; runner continues to the next row',
      () async {
        final source = _FakeSource(<ConnectorConnectionRow>[
          _posRow(connectionId: 'conn-failing'),
          _posRow(connectionId: 'conn-ok'),
        ]);
        final sink = _RecordingCanonicalSink();
        final failingAdapter = _RecordingPosAdapter()
          ..throwOnPoll = StateError('vendor 503');
        final okAdapter = _RecordingPosAdapter()
          ..pollResult = PollIncrementalResult(
            recordsWritten: 3,
            newCursorToken: 'cursor-ok',
            newLastModifiedSeen: DateTime.utc(2026, 5, 4, 13),
          );

        final result = await runSyncWorkerOnce(
          source: source,
          canonicalSink: sink,
          resolveAdapterFactory: (row) async =>
              row.connectionId == 'conn-failing' ? failingAdapter : okAdapter,
        );

        expect(result.processed, 2);
        expect(result.succeeded, 1);
        expect(result.failed, 1, reason: 'poll_error counts as a failure');
        expect(result.watermarkAdvanced, 1,
            reason: 'failed row must not advance the watermark');
        expect(sink.watermarkAdvances, hasLength(1));
        expect(sink.watermarkAdvances.single.connectionId, 'conn-ok');
        expect(
          sink.syncLogs.where((e) => e.eventKind == 'poll_error').length,
          1,
        );
        expect(
          sink.syncLogs.where((e) => e.eventKind == 'poll_success').length,
          1,
        );
      },
    );

    test(
      'disabled vendor: resolver throws SyncWorkerVendorDisabledException '
      '→ poll_error log + no dispatch',
      () async {
        final source = _FakeSource(<ConnectorConnectionRow>[
          _posRow(connectionId: 'conn-disabled', vendorId: 'aloha_ncr_voyix'),
        ]);
        final sink = _RecordingCanonicalSink();
        final adapter = _RecordingPosAdapter();

        final result = await runSyncWorkerOnce(
          source: source,
          canonicalSink: sink,
          resolveAdapterFactory: (row) async {
            throw const SyncWorkerVendorDisabledException(
              vendorId: 'aloha_ncr_voyix',
              category: IntegrationCategory.pos,
              reason: 'aloha_ncr_voyix_credentials_missing',
            );
          },
        );

        expect(result.processed, 1);
        expect(result.succeeded, 0);
        expect(result.skipped, 1);
        expect(adapter.pollCalls, 0,
            reason: 'disabled vendor must not invoke the adapter');
        expect(sink.watermarkAdvances, isEmpty);
        expect(sink.syncLogs, hasLength(1));
        expect(sink.syncLogs.single.eventKind, 'poll_error');
        expect(
          sink.syncLogs.single.errorMessage,
          contains('aloha_ncr_voyix_credentials_missing'),
        );
      },
    );

    test(
      'not-wired vendor: resolver throws SyncWorkerVendorNotWiredException '
      '→ vendor_not_registered log + no dispatch',
      () async {
        final source = _FakeSource(<ConnectorConnectionRow>[
          _posRow(connectionId: 'conn-unknown', vendorId: 'mystery_vendor'),
        ]);
        final sink = _RecordingCanonicalSink();
        final adapter = _RecordingPosAdapter();

        final result = await runSyncWorkerOnce(
          source: source,
          canonicalSink: sink,
          resolveAdapterFactory: (row) async {
            throw const SyncWorkerVendorNotWiredException(
              vendorId: 'mystery_vendor',
              category: IntegrationCategory.pos,
            );
          },
        );

        expect(result.processed, 1);
        expect(result.skipped, 1);
        expect(adapter.pollCalls, 0);
        expect(sink.watermarkAdvances, isEmpty);
        expect(sink.syncLogs, hasLength(1));
        expect(sink.syncLogs.single.eventKind, 'vendor_not_registered');
      },
    );

    test(
      'maxRowsPerTick: cap enforced, excess rows dropped silently',
      () async {
        final source = _FakeSource(<ConnectorConnectionRow>[
          _posRow(connectionId: 'conn-1'),
          _posRow(connectionId: 'conn-2'),
          _posRow(connectionId: 'conn-3'),
        ]);
        final sink = _RecordingCanonicalSink();
        final adapter = _RecordingPosAdapter();

        final result = await runSyncWorkerOnce(
          source: source,
          canonicalSink: sink,
          resolveAdapterFactory: (_) async => adapter,
          maxRowsPerTick: 2,
        );

        expect(result.processed, 2);
        expect(result.succeeded, 2);
        expect(adapter.pollCalls, 2);
      },
    );

    test(
      'shouldStop: respected between rows so the daemon loop exits '
      'cleanly without a custom drain handler',
      () async {
        final source = _FakeSource(<ConnectorConnectionRow>[
          _posRow(connectionId: 'conn-1'),
          _posRow(connectionId: 'conn-2'),
        ]);
        final sink = _RecordingCanonicalSink();
        final adapter = _RecordingPosAdapter();
        var stopAfter = false;

        final result = await runSyncWorkerOnce(
          source: source,
          canonicalSink: sink,
          resolveAdapterFactory: (_) async {
            stopAfter = true;
            return adapter;
          },
          shouldStop: () => stopAfter,
        );

        expect(result.processed, 1,
            reason: 'shouldStop must trip before the second row dispatches');
      },
    );
  });

  group('runCli', () {
    test(
      'overrides path: returns 0 + emits a JSON exit log carrying the '
      'tally',
      () async {
        final source = _FakeSource(<ConnectorConnectionRow>[
          _posRow(connectionId: 'conn-1'),
        ]);
        final sink = _RecordingCanonicalSink();
        final adapter = _RecordingPosAdapter()
          ..pollResult = PollIncrementalResult(
            recordsWritten: 1,
            newCursorToken: 'cursor-1',
            newLastModifiedSeen: DateTime.utc(2026, 5, 4, 14),
          );
        // ignore: close_sinks - test-owned in-memory sink; safe to leak.
        final out = _MemorySink();
        // ignore: close_sinks - test-owned in-memory sink; safe to leak.
        final err = _MemorySink();

        final exitCode = await runCli(
          <String>['runOnce'],
          environment: const <String, String>{},
          sourceOverride: source,
          canonicalSinkOverride: sink,
          resolveAdapterFactoryOverride: (_) async => adapter,
          out: out,
          err: err,
        );

        expect(exitCode, 0);
        expect(adapter.pollCalls, 1);
        // Exit log is a single JSON event line carrying the tally.
        final exitLine = out.lines.lastWhere(
          (line) => line.contains('"event":"exit"'),
          orElse: () => '',
        );
        expect(exitLine, isNotEmpty,
            reason: 'runOnce must emit an exit JSON log');
        final start = exitLine.indexOf('{');
        expect(start, isNonNegative);
        final json =
            jsonDecode(exitLine.substring(start)) as Map<String, Object?>;
        expect(json['event'], 'exit');
        expect(json['mode'], 'runOnce');
        expect(json['processed'], 1);
        expect(json['succeeded'], 1);
        expect(json['failed'], 0);
      },
    );

    test(
      'malformed args → exit code 2',
      () async {
        // ignore: close_sinks - test-owned in-memory sink; safe to leak.
        final out = _MemorySink();
        // ignore: close_sinks - test-owned in-memory sink; safe to leak.
        final err = _MemorySink();
        final exitCode = await runCli(
          <String>['banana'],
          environment: const <String, String>{},
          out: out,
          err: err,
        );
        expect(exitCode, 2);
      },
    );

    test(
      'missing POSTGRES_URL → exit code 2 with WorkerConfigError surface',
      () async {
        // ignore: close_sinks - test-owned in-memory sink; safe to leak.
        final out = _MemorySink();
        // ignore: close_sinks - test-owned in-memory sink; safe to leak.
        final err = _MemorySink();
        final exitCode = await runCli(
          <String>['runOnce'],
          environment: const <String, String>{
            'PGCRYPTO_ENVELOPE_KEY': 'x',
          },
          out: out,
          err: err,
        );
        expect(exitCode, 2);
        expect(err.lines.any((line) => line.contains('POSTGRES_URL')), isTrue);
      },
    );
  });
}

// ─── Test fakes ──────────────────────────────────────────────────────

ConnectorConnectionRow _posRow({
  required String connectionId,
  String vendorId = 'lightspeed_lsk',
}) =>
    ConnectorConnectionRow(
      connectionId: connectionId,
      operatorId: _opId,
      locationId: _locId,
      vendorId: vendorId,
      category: IntegrationCategory.pos,
      status: ConnectionStatus.connected,
      lastModifiedSeen: DateTime.utc(2026, 5, 3),
    );

class _FakeSource implements SyncWorkerSource {
  _FakeSource(this._rows);

  final List<ConnectorConnectionRow> _rows;

  @override
  Stream<ConnectorConnectionRow> connectedConnections() async* {
    for (final row in _rows) {
      yield row;
    }
  }
}

class _RecordingPosAdapter implements PosAdapter {
  int pollCalls = 0;
  PollIncrementalResult pollResult = PollIncrementalResult(
    recordsWritten: 0,
    newCursorToken: 'cursor',
    newLastModifiedSeen: DateTime.utc(2026, 5, 4),
  );
  Object? throwOnPoll;

  @override
  String get vendorId => 'lightspeed_lsk';
  @override
  String get displayName => 'Recording POS';
  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: 'lightspeed_lsk',
        displayName: 'Recording POS',
        category: IntegrationCategory.pos,
        authMode: VendorAuthMode.oauth,
        grantScope: VendorGrantScope.perLocation,
        webhookSupport: VendorWebhookSupport.autoRegister,
        coversFieldExposed: true,
        lifecycle: VendorLifecycle.documented,
      );

  @override
  Future<ConnectResult> connect(ConnectCommand command) =>
      throw UnimplementedError();
  @override
  Future<TestConnectionResult> testConnection(TestConnectionCommand command) =>
      throw UnimplementedError();
  @override
  Future<BackfillResult> backfill(BackfillCommand command) =>
      throw UnimplementedError();
  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) =>
      throw UnimplementedError();

  @override
  Future<PollIncrementalResult> pollIncremental(
    PollIncrementalCommand command,
  ) async {
    pollCalls += 1;
    if (throwOnPoll != null) throw throwOnPoll!;
    return pollResult;
  }

  @override
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command) async =>
      const HandleWebhookResult(recordsWritten: 1);
}

class _RecordingCanonicalSink implements CanonicalSink {
  final List<_WatermarkAdvance> watermarkAdvances = <_WatermarkAdvance>[];
  final List<_SyncLogEntry> syncLogs = <_SyncLogEntry>[];

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async =>
      true;
  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) async =>
      true;
  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) async =>
      true;

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) async {
    watermarkAdvances.add(_WatermarkAdvance(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      cursorToken: cursorToken,
      lastModifiedSeen: lastModifiedSeen,
    ));
  }

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) async {
    syncLogs.add(_SyncLogEntry(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      eventKind: eventKind,
      errorMessage: errorMessage,
      recordsCount: recordsCount,
    ));
  }

  @override
  Future<void> evaluateDemoFlip({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required ConnectionStatus connectionStatus,
    required bool firstBackfillCommitted,
    required int backfillRecordsWritten,
    required String connectionId,
  }) async {}
}

class _WatermarkAdvance {
  const _WatermarkAdvance({
    required this.operatorId,
    required this.locationId,
    required this.connectionId,
    required this.cursorToken,
    required this.lastModifiedSeen,
  });
  final String operatorId;
  final String locationId;
  final String connectionId;
  final String cursorToken;
  final DateTime lastModifiedSeen;
}

class _SyncLogEntry {
  const _SyncLogEntry({
    required this.operatorId,
    required this.locationId,
    required this.connectionId,
    required this.eventKind,
    this.errorMessage,
    this.recordsCount,
  });
  final String operatorId;
  final String locationId;
  final String connectionId;
  final String eventKind;
  final String? errorMessage;
  final int? recordsCount;
}

/// In-memory `IOSink` for asserting on stdout/stderr without writing
/// anything to the host. Only the [writeln] and [write] surfaces are
/// exercised by the worker; the rest fall back to no-ops.
class _MemorySink implements IOSink {
  final List<String> lines = <String>[];

  @override
  Encoding encoding = utf8;

  @override
  void writeln([Object? message = '']) {
    lines.add(message?.toString() ?? '');
  }

  @override
  void write(Object? message) {
    final text = message?.toString() ?? '';
    if (lines.isEmpty) {
      lines.add(text);
    } else {
      lines[lines.length - 1] = lines.last + text;
    }
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    for (final obj in objects) {
      write(obj);
      if (separator.isNotEmpty) write(separator);
    }
  }

  @override
  void writeCharCode(int charCode) {
    write(String.fromCharCode(charCode));
  }

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> get done => Future<void>.value();
}
