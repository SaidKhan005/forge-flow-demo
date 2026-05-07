// Phase 8 Wave B `8.spine-bridge.0` — Lane W5-LB3: integration sync
// worker scaffold (`tool/integration_sync_worker/integration_sync_worker.dart`)
// outer-loop typed-catch coverage.
//
// CODE_HEALTH cite: "Sync worker bare `catch (_)` ...
// `tool/integration_sync_worker/integration_sync_worker.dart:303` swallows
// every per-tick exception". The fix replaces the bare catch with three
// typed-catch arms (`TimeoutException` / `Exception` / `Object`) so per-tick
// failures surface through a structured reporter; the loop never crashes.
//
// The tests drive [integrationSyncWorkerMain] with `tickCount`-bounded
// iterations (production runs forever) and a fake gateway whose
// `findDueConnections` raises whatever the scripted action says, then
// assert the typed-catch arm classifies the failure correctly and the
// loop continues to the next tick.
//
// Why we exercise via the gateway seam: it's the only `runOnce`-internal
// surface that can throw a `TimeoutException` / `Exception` /
// non-`Exception` `Object` before per-row catches absorb it.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/labor_adapter.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';
import 'package:forge_and_flow/services/integration/reservation_adapter.dart';

import '../../../tool/integration_sync_worker/integration_sync_worker.dart';

void main() {
  group('integrationSyncWorkerMain — typed catch loop', () {
    test(
      'TimeoutException → reporter sees kind=timeout, loop continues to '
      'the next tick',
      () async {
        final gateway = _ScriptedGateway(<_TickAction>[
          _TickAction.throwTimeout(),
          _TickAction.success(),
        ]);
        final worker = _buildWorker(gateway);
        final reported = <IntegrationSyncWorkerLoopError>[];

        await integrationSyncWorkerMain(
          worker,
          tickInterval: Duration.zero,
          tickCount: 2,
          reportError: reported.add,
        );

        expect(gateway.findDueCalls, 2,
            reason: 'loop must keep ticking after a TimeoutException');
        expect(reported, hasLength(1));
        expect(reported.single.kind, 'timeout');
        expect(reported.single.error, isA<TimeoutException>());

        final fields = reported.single.toLogFields();
        expect(fields['worker'], 'integration_sync');
        expect(fields['event'], 'tick_error');
        expect(fields['kind'], 'timeout');
        expect(fields['error'], contains('TimeoutException'));
        expect(fields['stackTrace'], isA<String>());
      },
    );

    test(
      'generic Exception → reporter sees kind=exception, loop continues '
      'to the next tick',
      () async {
        final gateway = _ScriptedGateway(<_TickAction>[
          _TickAction.success(),
          _TickAction.throwException('gateway SELECT failed'),
          _TickAction.success(),
        ]);
        final worker = _buildWorker(gateway);
        final reported = <IntegrationSyncWorkerLoopError>[];

        await integrationSyncWorkerMain(
          worker,
          tickInterval: Duration.zero,
          tickCount: 3,
          reportError: reported.add,
        );

        expect(gateway.findDueCalls, 3,
            reason:
                'middle-tick exception must not crash the surrounding loop');
        expect(reported, hasLength(1));
        expect(reported.single.kind, 'exception');
        expect(
          reported.single.error.toString(),
          contains('gateway SELECT failed'),
        );
        expect(
          reported.single.toLogFields()['stackTrace'],
          isA<String>(),
        );
      },
    );

    test(
      'non-Exception Object throw → reporter sees kind=unhandled, loop '
      'continues',
      () async {
        final gateway = _ScriptedGateway(<_TickAction>[
          _TickAction.throwRawObject(),
          _TickAction.success(),
        ]);
        final worker = _buildWorker(gateway);
        final reported = <IntegrationSyncWorkerLoopError>[];

        await integrationSyncWorkerMain(
          worker,
          tickInterval: Duration.zero,
          tickCount: 2,
          reportError: reported.add,
        );

        expect(gateway.findDueCalls, 2);
        expect(reported, hasLength(1));
        expect(reported.single.kind, 'unhandled');
        expect(reported.single.error, isA<String>());
      },
    );

    test(
      'fully successful ticks emit no reporter events',
      () async {
        final gateway = _ScriptedGateway(<_TickAction>[
          _TickAction.success(),
          _TickAction.success(),
        ]);
        final worker = _buildWorker(gateway);
        final reported = <IntegrationSyncWorkerLoopError>[];

        await integrationSyncWorkerMain(
          worker,
          tickInterval: Duration.zero,
          tickCount: 2,
          reportError: reported.add,
        );

        expect(reported, isEmpty);
        expect(gateway.findDueCalls, 2);
      },
    );
  });
}

// ─── Test fakes ──────────────────────────────────────────────────────

IntegrationSyncWorker _buildWorker(IntegrationSyncWorkerGateway gateway) =>
    IntegrationSyncWorker(
      gateway: gateway,
      posAdapters: const <String, PosAdapter>{},
      laborAdapters: const <String, LaborAdapter>{},
      reservationAdapters: const <String, ReservationAdapter>{},
    );

/// One scripted gateway-tick outcome (success-empty or thrown).
class _TickAction {
  const _TickAction._(this._fn);

  factory _TickAction.success() => _TickAction._(_successBody);
  factory _TickAction.throwTimeout() =>
      _TickAction._(_throwTimeoutBody);
  factory _TickAction.throwException(String message) =>
      _TickAction._(() => _throwExceptionBody(message));
  factory _TickAction.throwRawObject() =>
      _TickAction._(_throwRawObjectBody);

  final Future<List<PollableConnection>> Function() _fn;

  Future<List<PollableConnection>> run() => _fn();
}

Future<List<PollableConnection>> _successBody() async =>
    const <PollableConnection>[];

Future<List<PollableConnection>> _throwTimeoutBody() async {
  throw TimeoutException('gateway timed out');
}

Future<List<PollableConnection>> _throwExceptionBody(String message) async {
  throw Exception(message);
}

Future<List<PollableConnection>> _throwRawObjectBody() async {
  // ignore: only_throw_errors
  throw 'raw string throw';
}

class _ScriptedGateway implements IntegrationSyncWorkerGateway {
  _ScriptedGateway(this._actions);

  final List<_TickAction> _actions;
  int findDueCalls = 0;

  @override
  Future<List<PollableConnection>> findDueConnections({
    required DateTime now,
    int limit = 100,
  }) {
    final action = _actions[findDueCalls];
    findDueCalls += 1;
    return action.run();
  }

  @override
  Future<void> persistWatermark({
    required String connectionId,
    required String operatorId,
    required String locationId,
    required String resource,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) async {}

  @override
  Future<void> appendSyncLog({
    required String connectionId,
    required String operatorId,
    required String locationId,
    required String eventKind,
    int? recordsCount,
    String? errorMessage,
    int? durationMs,
  }) async {}

  @override
  Future<void> recordSanityDrop({
    required String connectionId,
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String vendorEventId,
    required String rule,
    required Map<String, Object?> payloadSummary,
  }) async {}
}
