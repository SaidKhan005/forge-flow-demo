// Phase 8 Wave B `8.spine-bridge.0` sync worker dispatch tests.
//
// Pure-logic coverage of [IntegrationSyncWorkerDispatch]. Adapter
// behavior is faked at the per-row factory level so the dispatcher's
// branching (success / failure / unknown vendor / wrong category) is
// exercised without any real adapter or live HTTP.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/forge_flow_polling_tier_assignment.dart';
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

    test(
        'watermark atomicity: when the adapter throws AFTER the call '
        'starts, watermark advance is NEVER issued (the only durable '
        'side-effect on the failure path is the poll_error sync log)',
        () async {
      // Adapter records the call but throws — simulating the "vendor
      // wrote some rows then we lost the connection" shape.
      posAdapter.throwOnPoll = StateError('connection lost mid-poll');

      await dispatcher.dispatchPollTick(
        connectorConnectionRow: _posRow(),
        adapterFactory: (_) => posAdapter,
        canonicalSink: sink,
      );

      // The dispatcher's transactional contract on the failure path:
      // watermark MUST NOT advance. (Cross-tx atomicity between adapter
      // writes and the watermark itself requires an executor-bearing
      // adapter API, which is the multi-file rewrite documented in the
      // CODE_HEALTH ledger.)
      expect(sink.watermarkAdvances, isEmpty,
          reason: 'failed adapter call must NOT advance the watermark; '
              'idempotency on the next tick re-replays absorbed-or-not '
              'vendor double writes from the prior cursor');
      expect(posAdapter.pollCalls, 1,
          reason: 'adapter was invoked exactly once');
      expect(sink.syncLogs, hasLength(1));
      expect(sink.syncLogs.single.eventKind, 'poll_error');
    });

    test(
        'watermark atomicity: on success the watermark advance and the '
        'poll_success log are the only sink writes, in that order, so a '
        'crash between fact upserts (inside the adapter) and the '
        'watermark advance leaves the watermark unchanged',
        () async {
      posAdapter.pollResult = PollIncrementalResult(
        recordsWritten: 3,
        newCursorToken: 'cursor-tx-test',
        newLastModifiedSeen: DateTime.utc(2026, 5, 6, 9, 0, 0),
      );

      await dispatcher.dispatchPollTick(
        connectorConnectionRow: _posRow(),
        adapterFactory: (_) => posAdapter,
        canonicalSink: sink,
      );

      expect(sink.watermarkAdvances, hasLength(1));
      expect(sink.watermarkAdvances.single.cursorToken, 'cursor-tx-test');
      expect(sink.syncLogs, hasLength(1));
      expect(sink.syncLogs.single.eventKind, 'poll_success');

      // Sequencing assertion: watermark advance is recorded BEFORE the
      // poll_success log row. The dispatcher relies on this ordering so
      // a crash between the two leaves the watermark advanced and the
      // log row absent — the next tick treats the prior poll as
      // committed (acceptable per the canonical-sink contract).
      expect(sink.callOrder, ['advanceWatermark', 'appendSyncLog']);
    });
  });

  group(
      'IntegrationSyncWorkerDispatch cadence resolver: resolved value is '
      'now delivered to a consumer (CODE_HEALTH `dispatch.dart:373`)', () {
    test(
        'when resolvedCadenceSink is supplied, the resolved cadence '
        'flows out of the dispatcher (no longer discarded)', () async {
      final cadenceCalls = <_ResolvedCadenceCall>[];
      final dispatcher = IntegrationSyncWorkerDispatch(
        tierAssignmentLookup: (operatorId, locationId) async => null,
        vendorMinimumCadenceLookup: (vendorId) => 300,
        resolvedCadenceSink: ({
          required connectionId,
          required vendorId,
          required operatorId,
          required locationId,
          required resolvedCadenceSeconds,
        }) {
          cadenceCalls.add(_ResolvedCadenceCall(
            connectionId: connectionId,
            vendorId: vendorId,
            operatorId: operatorId,
            locationId: locationId,
            resolvedCadenceSeconds: resolvedCadenceSeconds,
          ));
        },
      );
      final sink = _RecordingCanonicalSink();
      final adapter = _RecordingPosAdapter()
        ..vendorIdOverride = 'oracle_micros_simphony'
        ..pollResult = PollIncrementalResult(
          recordsWritten: 0,
          newCursorToken: 'c',
          newLastModifiedSeen: DateTime.utc(2026, 5, 4),
        );

      await dispatcher.dispatchPollTick(
        connectorConnectionRow: _posRow(vendorId: 'oracle_micros_simphony'),
        adapterFactory: (_) => adapter,
        canonicalSink: sink,
      );

      expect(cadenceCalls, hasLength(1),
          reason: 'resolved cadence must be delivered exactly once per '
              'poll tick when the resolver path is active');
      expect(cadenceCalls.single.connectionId, 'conn-1');
      expect(cadenceCalls.single.vendorId, 'oracle_micros_simphony');
      expect(cadenceCalls.single.operatorId, _opId);
      expect(cadenceCalls.single.locationId, _locId);
      // Tier assignment was null -> resolver falls back to the standard
      // preset for Oracle, which is 300s.
      expect(cadenceCalls.single.resolvedCadenceSeconds, 300);

      // The observability log emission still fires too.
      expect(
          sink.syncLogs.where((log) =>
              log.eventKind == 'tier_assignment_missing'),
          hasLength(1));
    });

    test(
        'resolved cadence reflects per-vendor JSONB override on the '
        'tier assignment (premium tier, custom override)', () async {
      _ResolvedCadenceCall? cadenceCall;
      final dispatcher = IntegrationSyncWorkerDispatch(
        tierAssignmentLookup: (operatorId, locationId) async =>
            ForgeFlowPollingTierAssignment(
          assignmentId: '00000000-0000-4000-8000-0000000000aa',
          operatorId: operatorId,
          locationId: locationId,
          tierKey: PollingTierKey.premium,
          pollingCadencePerVendorSeconds: const <String, int>{
            'quickbooks_time': 90,
          },
          effectiveAt: DateTime.utc(2026, 5, 1),
          createdAt: DateTime.utc(2026, 5, 1),
        ),
        vendorMinimumCadenceLookup: (vendorId) => 60,
        resolvedCadenceSink: ({
          required connectionId,
          required vendorId,
          required operatorId,
          required locationId,
          required resolvedCadenceSeconds,
        }) {
          cadenceCall = _ResolvedCadenceCall(
            connectionId: connectionId,
            vendorId: vendorId,
            operatorId: operatorId,
            locationId: locationId,
            resolvedCadenceSeconds: resolvedCadenceSeconds,
          );
        },
      );
      final sink = _RecordingCanonicalSink();
      final adapter = _RecordingLaborAdapter(vendorId: 'quickbooks_time');

      await dispatcher.dispatchPollTick(
        connectorConnectionRow: ConnectorConnectionRow(
          connectionId: 'conn-qbt-1',
          operatorId: _opId,
          locationId: _locId,
          vendorId: 'quickbooks_time',
          category: IntegrationCategory.labor,
          status: ConnectionStatus.connected,
          lastModifiedSeen: DateTime.utc(2026, 5, 3),
        ),
        adapterFactory: (_) => adapter,
        canonicalSink: sink,
      );

      expect(cadenceCall, isNotNull);
      expect(cadenceCall!.resolvedCadenceSeconds, 90,
          reason: 'override of 90s is within [vendorMin=60, '
              'frameworkMax=3600] so the resolver returns it as-is');
    });

    test(
        'resolvedCadenceSink is NOT invoked when either lookup is null '
        '(lane .0 baseline preserves backward compatibility)', () async {
      final cadenceCalls = <_ResolvedCadenceCall>[];
      final dispatcher = IntegrationSyncWorkerDispatch(
        // Both lookups omitted (null).
        resolvedCadenceSink: ({
          required connectionId,
          required vendorId,
          required operatorId,
          required locationId,
          required resolvedCadenceSeconds,
        }) {
          cadenceCalls.add(_ResolvedCadenceCall(
            connectionId: connectionId,
            vendorId: vendorId,
            operatorId: operatorId,
            locationId: locationId,
            resolvedCadenceSeconds: resolvedCadenceSeconds,
          ));
        },
      );
      final sink = _RecordingCanonicalSink();
      final adapter = _RecordingPosAdapter();

      await dispatcher.dispatchPollTick(
        connectorConnectionRow: _posRow(),
        adapterFactory: (_) => adapter,
        canonicalSink: sink,
      );

      expect(cadenceCalls, isEmpty,
          reason: 'sink must stay quiet when the resolver path is not '
              'wired — production main.dart still passes neither lookup '
              'and the dispatcher must not invoke the cadence sink');
    });

    test(
        'resolvedCadenceSink is NOT invoked for vendors that are NOT '
        'in pollOnlyVendorIds (webhook-driven vendors)', () async {
      final cadenceCalls = <_ResolvedCadenceCall>[];
      final dispatcher = IntegrationSyncWorkerDispatch(
        tierAssignmentLookup: (operatorId, locationId) async => null,
        vendorMinimumCadenceLookup: (vendorId) => 60,
        resolvedCadenceSink: ({
          required connectionId,
          required vendorId,
          required operatorId,
          required locationId,
          required resolvedCadenceSeconds,
        }) {
          cadenceCalls.add(_ResolvedCadenceCall(
            connectionId: connectionId,
            vendorId: vendorId,
            operatorId: operatorId,
            locationId: locationId,
            resolvedCadenceSeconds: resolvedCadenceSeconds,
          ));
        },
      );
      final sink = _RecordingCanonicalSink();
      // 7shifts is webhook-driven (autoRegister) — NOT in pollOnly.
      final adapter = _RecordingLaborAdapter(vendorId: 'seven_shifts');

      await dispatcher.dispatchPollTick(
        connectorConnectionRow: ConnectorConnectionRow(
          connectionId: 'conn-7s-1',
          operatorId: _opId,
          locationId: _locId,
          vendorId: 'seven_shifts',
          category: IntegrationCategory.labor,
          status: ConnectionStatus.connected,
          lastModifiedSeen: DateTime.utc(2026, 5, 3),
        ),
        adapterFactory: (_) => adapter,
        canonicalSink: sink,
      );

      expect(cadenceCalls, isEmpty,
          reason: 'webhook-driven vendors do not use polling cadence; '
              'the dispatcher gate suppresses the resolver call entirely');
    });

    test(
        'resolvedCadenceSink is NOT invoked when the tier-assignment '
        'lookup throws — failure surfaces as a '
        'tier_assignment_lookup_failed sync log row, then control '
        'returns without delivering a cadence value', () async {
      final cadenceCalls = <_ResolvedCadenceCall>[];
      final dispatcher = IntegrationSyncWorkerDispatch(
        tierAssignmentLookup: (operatorId, locationId) async {
          throw StateError('tier repo down');
        },
        vendorMinimumCadenceLookup: (vendorId) => 300,
        resolvedCadenceSink: ({
          required connectionId,
          required vendorId,
          required operatorId,
          required locationId,
          required resolvedCadenceSeconds,
        }) {
          cadenceCalls.add(_ResolvedCadenceCall(
            connectionId: connectionId,
            vendorId: vendorId,
            operatorId: operatorId,
            locationId: locationId,
            resolvedCadenceSeconds: resolvedCadenceSeconds,
          ));
        },
      );
      final sink = _RecordingCanonicalSink();
      final adapter = _RecordingPosAdapter()
        ..vendorIdOverride = 'oracle_micros_simphony';

      await dispatcher.dispatchPollTick(
        connectorConnectionRow: _posRow(vendorId: 'oracle_micros_simphony'),
        adapterFactory: (_) => adapter,
        canonicalSink: sink,
      );

      expect(cadenceCalls, isEmpty);
      expect(
          sink.syncLogs
              .where((log) => log.eventKind == 'tier_assignment_lookup_failed'),
          hasLength(1));
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

  /// Override the adapter's vendor id at runtime so a single recording
  /// fixture covers both the default `lightspeed_lsk` rows and the
  /// poll-only `oracle_micros_simphony` rows the cadence-resolver
  /// tests need.
  String? vendorIdOverride;

  @override
  String get vendorId => vendorIdOverride ?? 'lightspeed_lsk';
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

  /// Ordered tape of method names recorded across the sink. The
  /// watermark-atomicity tests use this to assert the dispatcher
  /// issues `advanceWatermark` BEFORE the `poll_success`
  /// `appendSyncLog` so the durable state on a mid-tick crash is
  /// well-defined.
  final List<String> callOrder = <String>[];

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
    callOrder.add('advanceWatermark');
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
    callOrder.add('appendSyncLog');
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

class _ResolvedCadenceCall {
  const _ResolvedCadenceCall({
    required this.connectionId,
    required this.vendorId,
    required this.operatorId,
    required this.locationId,
    required this.resolvedCadenceSeconds,
  });
  final String connectionId;
  final String vendorId;
  final String operatorId;
  final String locationId;
  final int resolvedCadenceSeconds;
}
