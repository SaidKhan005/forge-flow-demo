// Phase 8 Wave B `8.spine-bridge.0` sync worker dispatch tests.
//
// Pure-logic coverage of [IntegrationSyncWorkerDispatch]. Adapter
// behavior is faked at the per-row factory level so the dispatcher's
// branching (success / failure / unknown vendor / wrong category) is
// exercised without any real adapter or live HTTP.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/labor/adp_labor_adapter.dart'
    show kAdpVendorId;
import 'package:forge_and_flow/integrations/reservation/libro_reservation_adapter.dart';
import 'package:forge_and_flow/services/integration/canonical_sink.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/labor_adapter.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';
import 'package:forge_and_flow/services/integration/reservation_adapter.dart';

import '../../../tool/integration_sync_worker/dispatch.dart';

const String _opId = '00000000-0000-4000-8000-000000000001';
const String _locId = '00000000-0000-4000-8000-0000000000a1';

void main() {
  group('IntegrationSyncWorkerDispatch.dispatchPollTick', () {
    late _RecordingCanonicalSink sink;
    late _RecordingPosAdapter posAdapter;
    late IntegrationSyncWorkerDispatch dispatcher;

    setUp(() {
      sink = _RecordingCanonicalSink();
      posAdapter = _RecordingPosAdapter();
      dispatcher = IntegrationSyncWorkerDispatch();
    });

    test(
        'calls adapter.pollIncremental exactly once with a non-null '
        'sanityHook bound to the connection tenant', () async {
      await dispatcher.dispatchPollTick(
        connectorConnectionRow: _posRow(),
        adapterFactory: (_) => posAdapter,
        canonicalSink: sink,
      );

      expect(posAdapter.pollCalls, 1);
      expect(posAdapter.lastCommand, isNotNull);
      expect(posAdapter.lastCommand!.operatorId, _opId);
      expect(posAdapter.lastCommand!.locationId, _locId);
      expect(posAdapter.lastCommand!.actorUserId,
          kSyncWorkerServicePrincipalId,
          reason: 'worker stamps a UUID-shaped service-principal id so '
              'TenantContext.userId validation passes downstream');
      expect(posAdapter.lastCommand!.sanityHook, isNotNull);

      // Sanity hook is callable + returns true (seam contract).
      final ok = await posAdapter.lastCommand!.sanityHook(
        vendorEventId: 'evt-1',
        payload: const <String, Object?>{},
        isDeliberateBackfill: false,
      );
      expect(ok, true);
    });

    test('on success: watermark advances + poll_success log fires', () async {
      posAdapter.pollResult = PollIncrementalResult(
        recordsWritten: 7,
        newCursorToken: 'cursor-after-tick',
        newLastModifiedSeen: DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      await dispatcher.dispatchPollTick(
        connectorConnectionRow: _posRow(),
        adapterFactory: (_) => posAdapter,
        canonicalSink: sink,
      );

      expect(sink.watermarkAdvances, hasLength(1));
      expect(sink.watermarkAdvances.single.cursorToken, 'cursor-after-tick');
      expect(sink.watermarkAdvances.single.connectionId, 'conn-1');

      expect(sink.syncLogs, hasLength(1));
      expect(sink.syncLogs.single.eventKind, 'poll_success');
      expect(sink.syncLogs.single.recordsCount, 7);
    });

    test(
        'on adapter throw: poll_error log fires + watermark NOT advanced',
        () async {
      posAdapter.throwOnPoll = StateError('vendor 503');

      await dispatcher.dispatchPollTick(
        connectorConnectionRow: _posRow(),
        adapterFactory: (_) => posAdapter,
        canonicalSink: sink,
      );

      expect(sink.watermarkAdvances, isEmpty,
          reason: 'failed tick must NOT advance the watermark');
      expect(sink.syncLogs, hasLength(1));
      expect(sink.syncLogs.single.eventKind, 'poll_error');
      expect(sink.syncLogs.single.errorMessage, contains('vendor 503'));
    });

    test(
        'throws StateError when vendor is not in the category registry '
        '+ writes a vendor_not_registered sync_log row (spine contract '
        'Lane .0 test req: "missing adapter returns null + logs")',
        () async {
      await expectLater(
        dispatcher.dispatchPollTick(
          connectorConnectionRow: _posRow(vendorId: 'vendor_not_registered'),
          adapterFactory: (_) => posAdapter,
          canonicalSink: sink,
        ),
        throwsA(isA<StateError>()),
      );

      expect(posAdapter.pollCalls, 0,
          reason: 'unknown vendor must short-circuit before adapter '
              'construction');

      expect(sink.syncLogs, hasLength(1),
          reason: 'vendor_not_registered must produce exactly one '
              'durable log row');
      expect(sink.syncLogs.single.eventKind, 'vendor_not_registered');
      expect(sink.syncLogs.single.errorMessage,
          contains('vendor_not_registered'));
      expect(sink.watermarkAdvances, isEmpty,
          reason: 'unregistered vendor must NOT advance the watermark');
    });

    test(
        'throws StateError when adapterFactory returns wrong category type',
        () async {
      // POS row but factory hands back a labor adapter.
      final laborAdapter = _RecordingLaborAdapter();
      await expectLater(
        dispatcher.dispatchPollTick(
          connectorConnectionRow: _posRow(),
          adapterFactory: (_) => laborAdapter,
          canonicalSink: sink,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('IntegrationSyncWorkerDispatch.dispatchWebhook', () {
    test(
        'calls handleWebhook on the registered Libro adapter; does not '
        'invoke any other-category adapter', () async {
      final libro = _RecordingReservationAdapter();
      final pos = _RecordingPosAdapter();
      final labor = _RecordingLaborAdapter();
      final sink = _RecordingCanonicalSink();
      final dispatcher = IntegrationSyncWorkerDispatch();

      await dispatcher.dispatchWebhook(
        connectorConnectionRow: _libroRow(),
        adapterFactory: (_) => libro,
        canonicalSink: sink,
        vendorEventId: 'libro-evt-1',
        payload: const <String, Object?>{'reservation_id': 'r1'},
        headers: const <String, String>{'libro-signature': 'sha256=...'},
      );

      expect(libro.handleWebhookCalls, 1);
      expect(libro.lastWebhookCommand, isNotNull);
      expect(libro.lastWebhookCommand!.vendorId, kLibroVendorId);
      expect(libro.lastWebhookCommand!.vendorEventId, 'libro-evt-1');

      expect(pos.handleWebhookCalls, 0,
          reason: 'reservation webhook must not touch POS adapter');
      expect(labor.handleWebhookCalls, 0,
          reason: 'reservation webhook must not touch labor adapter');
      expect(sink.syncLogs, isEmpty,
          reason: 'happy path: dispatchWebhook does not write sync_log; '
              'the bound vendor sink owns post-write logging');
    });

    test(
        'ADP webhook routes through handleWebhook (architecture amendment: '
        'ADP is autoRegister, NOT pollOnly — dispatch must NOT fall back '
        'to pollIncremental)', () async {
      final adp = _RecordingLaborAdapter(vendorId: kAdpVendorId);
      final sink = _RecordingCanonicalSink();
      final dispatcher = IntegrationSyncWorkerDispatch();

      await dispatcher.dispatchWebhook(
        connectorConnectionRow: _adpRow(),
        adapterFactory: (_) => adp,
        canonicalSink: sink,
        vendorEventId: 'adp-evt-1',
        payload: const <String, Object?>{
          'event_type': 'punch.upsert',
          'employee_id': 'emp-1',
        },
        headers: const <String, String>{'adp-signature': 'sha256=...'},
      );

      expect(adp.handleWebhookCalls, 1,
          reason: 'ADP webhook MUST be delivered to handleWebhook');
      expect(adp.lastWebhookCommand, isNotNull);
      expect(adp.lastWebhookCommand!.vendorId, kAdpVendorId);
      expect(adp.lastWebhookCommand!.vendorEventId, 'adp-evt-1');

      expect(adp.pollIncrementalCalls, 0,
          reason: 'ADP webhook MUST NOT trigger a polling fallback; dispatch '
              'has no pollOnly-fallback branch and ADP is auto-registered.');
    });

    test(
        'unregistered webhook vendor: throws StateError + writes a '
        'vendor_not_registered sync_log row (parity with the poll path)',
        () async {
      final pos = _RecordingPosAdapter();
      final sink = _RecordingCanonicalSink();
      final dispatcher = IntegrationSyncWorkerDispatch();

      await expectLater(
        dispatcher.dispatchWebhook(
          connectorConnectionRow: _posRow(vendorId: 'vendor_not_registered'),
          adapterFactory: (_) => pos,
          canonicalSink: sink,
          vendorEventId: 'evt-x',
          payload: const <String, Object?>{},
          headers: const <String, String>{},
        ),
        throwsA(isA<StateError>()),
      );

      expect(pos.handleWebhookCalls, 0,
          reason: 'unregistered vendor must short-circuit before '
              'adapter construction');
      expect(sink.syncLogs, hasLength(1));
      expect(sink.syncLogs.single.eventKind, 'vendor_not_registered');
    });
  });
}

ConnectorConnectionRow _adpRow() => ConnectorConnectionRow(
      connectionId: 'conn-adp-1',
      operatorId: _opId,
      locationId: _locId,
      vendorId: kAdpVendorId,
      category: IntegrationCategory.labor,
      status: ConnectionStatus.connected,
      lastModifiedSeen: DateTime.utc(2026, 5, 3, 0, 0, 0),
    );

ConnectorConnectionRow _posRow({String vendorId = 'lightspeed_lsk'}) =>
    ConnectorConnectionRow(
      connectionId: 'conn-1',
      operatorId: _opId,
      locationId: _locId,
      vendorId: vendorId,
      category: IntegrationCategory.pos,
      status: ConnectionStatus.connected,
      lastModifiedSeen: DateTime.utc(2026, 5, 3, 0, 0, 0),
    );

ConnectorConnectionRow _libroRow() => ConnectorConnectionRow(
      connectionId: 'conn-libro-1',
      operatorId: _opId,
      locationId: _locId,
      vendorId: kLibroVendorId,
      category: IntegrationCategory.reservation,
      status: ConnectionStatus.connected,
      lastModifiedSeen: DateTime.utc(2026, 5, 3, 0, 0, 0),
    );

// ─── Recording adapters ────────────────────────────────────────────

class _RecordingPosAdapter implements PosAdapter {
  int pollCalls = 0;
  int handleWebhookCalls = 0;
  PollIncrementalCommand? lastCommand;
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
    lastCommand = command;
    if (throwOnPoll != null) throw throwOnPoll!;
    return pollResult;
  }

  @override
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command) async {
    handleWebhookCalls += 1;
    return const HandleWebhookResult(recordsWritten: 1);
  }
}

class _RecordingLaborAdapter implements LaborAdapter {
  _RecordingLaborAdapter({this.vendorId = 'seven_shifts'});

  int handleWebhookCalls = 0;
  int pollIncrementalCalls = 0;
  HandleWebhookCommand? lastWebhookCommand;

  @override
  final String vendorId;
  @override
  String get displayName => 'Recording Labor';
  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: 'seven_shifts',
        displayName: 'Recording Labor',
        category: IntegrationCategory.labor,
        authMode: VendorAuthMode.oauth,
        grantScope: VendorGrantScope.operatorWide,
        webhookSupport: VendorWebhookSupport.autoRegister,
        coversFieldExposed: false,
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
  Future<PollIncrementalResult> pollIncremental(
    PollIncrementalCommand command,
  ) async {
    pollIncrementalCalls += 1;
    return PollIncrementalResult(
      recordsWritten: 0,
      newCursorToken: 'cursor-labor',
      newLastModifiedSeen: DateTime.utc(2026, 5, 4),
    );
  }

  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) =>
      throw UnimplementedError();

  @override
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command) async {
    handleWebhookCalls += 1;
    lastWebhookCommand = command;
    return const HandleWebhookResult(recordsWritten: 1);
  }
}

class _RecordingReservationAdapter implements ReservationAdapter {
  int handleWebhookCalls = 0;
  HandleWebhookCommand? lastWebhookCommand;

  @override
  String get vendorId => kLibroVendorId;
  @override
  String get displayName => 'Recording Libro';
  @override
  VendorCapabilityProfile get capabilityProfile => const VendorCapabilityProfile(
        vendorId: kLibroVendorId,
        displayName: 'Recording Libro',
        category: IntegrationCategory.reservation,
        authMode: VendorAuthMode.keyPaste,
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
  Future<PollIncrementalResult> pollIncremental(
          PollIncrementalCommand command) =>
      throw UnimplementedError();
  @override
  Future<DisconnectResult> disconnect(DisconnectCommand command) =>
      throw UnimplementedError();

  @override
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command) async {
    handleWebhookCalls += 1;
    lastWebhookCommand = command;
    return const HandleWebhookResult(recordsWritten: 1);
  }
}

// ─── Recording sink ────────────────────────────────────────────────

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
