// Phase 10a.0 — RealtimeSubscription unit tests.
//
// Pinned behavior:
//   * exponential back-off curve doubles per failed connect, capped
//     at maxBackoff (initial 1s → 2s → 4s → … → 30s)
//   * a successful connect resets the curve to zero
//   * setTenantContext resets the curve and reconnects immediately
//     (no inherited back-off from the previous tenant)
//   * dispose cancels the in-flight reconnect timer and stops further
//     connect attempts
//   * incoming frames parse via RealtimeEvent.fromJson and surface on
//     the events stream

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/services/realtime/realtime_subscription.dart';
import 'package:forge_and_flow/services/realtime/realtime_transport.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '22222222-2222-2222-2222-222222222222';

void main() {
  group('RealtimeSubscription back-off curve', () {
    test(
      'doubles back-off on consecutive failed connects, capped at maxBackoff',
      () {
        fakeAsync((async) {
          final transport = _AlwaysFailingTransport();
          final subscription = RealtimeSubscription(
            proxyBaseUri: Uri.parse('ws://localhost:8080'),
            transport: transport,
            initialBackoff: const Duration(seconds: 1),
            maxBackoff: const Duration(seconds: 16),
          );
          subscription.setTenantContext(
            const RealtimeTenantContext(operatorId: _opA, authToken: 't0'),
          );
          // First connect attempt fires immediately.
          async.flushMicrotasks();
          expect(transport.attempts, 1);
          expect(subscription.currentBackoffForTest, const Duration(seconds: 1));

          // Walk the back-off ladder. Each tick of the timer triggers
          // a new connect that also fails immediately.
          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();
          expect(transport.attempts, 2);
          expect(subscription.currentBackoffForTest, const Duration(seconds: 2));

          async.elapse(const Duration(seconds: 2));
          async.flushMicrotasks();
          expect(transport.attempts, 3);
          expect(subscription.currentBackoffForTest, const Duration(seconds: 4));

          async.elapse(const Duration(seconds: 4));
          async.flushMicrotasks();
          expect(transport.attempts, 4);
          expect(subscription.currentBackoffForTest, const Duration(seconds: 8));

          async.elapse(const Duration(seconds: 8));
          async.flushMicrotasks();
          expect(transport.attempts, 5);
          expect(subscription.currentBackoffForTest, const Duration(seconds: 16));

          // Cap holds across further failures.
          async.elapse(const Duration(seconds: 16));
          async.flushMicrotasks();
          expect(transport.attempts, 6);
          expect(
            subscription.currentBackoffForTest,
            const Duration(seconds: 16),
            reason: 'back-off must clamp to maxBackoff once it would exceed',
          );

          subscription.dispose();
        });
      },
    );

    test(
      'successful connect resets the curve back to zero so a fresh '
      'disconnect starts at initialBackoff again',
      () {
        fakeAsync((async) {
          final transport = _ScriptedTransport()
            ..nextResult = _ConnectResult.fail()
            ..nextResult = _ConnectResult.fail()
            ..nextResult = _ConnectResult.success();
          final subscription = RealtimeSubscription(
            proxyBaseUri: Uri.parse('ws://localhost:8080'),
            transport: transport,
            initialBackoff: const Duration(seconds: 1),
            maxBackoff: const Duration(seconds: 30),
          );
          subscription.setTenantContext(
            const RealtimeTenantContext(operatorId: _opA, authToken: 't0'),
          );
          async.flushMicrotasks();
          // Two failures, then a success on the 3rd attempt.
          expect(transport.attempts, 1);
          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 2));
          async.flushMicrotasks();
          expect(transport.attempts, 3);
          // Success must reset the back-off.
          expect(subscription.currentBackoffForTest, Duration.zero);

          // Now drop the connected channel; the next reconnect should
          // start at initialBackoff again, not at the previous 4s.
          transport.nextResult = _ConnectResult.fail();
          transport.activeChannel?.simulateClose();
          async.flushMicrotasks();
          expect(
            subscription.currentBackoffForTest,
            const Duration(seconds: 1),
            reason: 'reset on success means the next failure restarts at '
                'initialBackoff, not where the previous curve left off',
          );

          subscription.dispose();
        });
      },
    );
  });

  group('RealtimeSubscription tenant-context reset', () {
    test(
      'in-flight connect that resolves AFTER setTenantContext does NOT '
      'become _activeChannel — it would otherwise emit the previous '
      'tenant\'s frames into the new session',
      () async {
        final transport = _DeferredTransport();
        final subscription = RealtimeSubscription(
          proxyBaseUri: Uri.parse('ws://localhost:8080'),
          transport: transport,
        );
        final received = <RealtimeEvent>[];
        final sub = subscription.events.listen(received.add);
        // Tenant A: kick off a connect; the transport leaves it
        // pending so we can interleave a tenant change.
        await subscription.setTenantContext(
          const RealtimeTenantContext(operatorId: _opA, authToken: 'tA'),
        );
        // Microtask: ensure the connect call has been issued.
        await Future<void>.delayed(Duration.zero);
        expect(transport.pendingConnects, hasLength(1));
        // Tenant B arrives BEFORE A's connect resolves. The
        // generation token should make A's resolved channel
        // discardable.
        final tenantAResolver = transport.pendingConnects.removeAt(0);
        await subscription.setTenantContext(
          const RealtimeTenantContext(operatorId: _opB, authToken: 'tB'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(transport.pendingConnects, hasLength(1));
        // Now resolve the OLD (tenant A) connect with a fresh
        // channel. The subscription must close it without binding.
        final tenantAChannel = _FakeChannel();
        tenantAResolver.complete(tenantAChannel);
        await Future<void>.delayed(Duration.zero);
        expect(
          tenantAChannel.closed,
          isTrue,
          reason: 'stale channel must be closed instead of becoming '
              '_activeChannel',
        );
        // Inject a frame into the old channel to be sure: even if the
        // subscription somehow listened, the channel is already
        // closed so nothing arrives.
        tenantAChannel.injectFrame(
          RealtimeEvent(
            eventId: 'evt-from-tenant-A',
            topic: 'rollup.invalidate.variance_week',
            operatorId: _opA,
            occurredAt: DateTime.utc(2026, 5, 2, 12),
            payload: const <String, Object?>{},
          ).encode(),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          received.where((e) => e.eventId == 'evt-from-tenant-A'),
          isEmpty,
          reason: 'tenant A frames must never reach a tenant B session',
        );
        // Now resolve tenant B's connect with a fresh channel and
        // verify its frames DO arrive.
        final tenantBResolver = transport.pendingConnects.removeAt(0);
        final tenantBChannel = _FakeChannel();
        tenantBResolver.complete(tenantBChannel);
        await Future<void>.delayed(Duration.zero);
        tenantBChannel.injectFrame(
          RealtimeEvent(
            eventId: 'evt-from-tenant-B',
            topic: 'rollup.invalidate.variance_week',
            operatorId: _opB,
            occurredAt: DateTime.utc(2026, 5, 2, 12),
            payload: const <String, Object?>{},
          ).encode(),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          received.where((e) => e.eventId == 'evt-from-tenant-B'),
          hasLength(1),
        );
        await sub.cancel();
        await subscription.dispose();
      },
    );

    test(
      'setTenantContext mid back-off cancels the pending reconnect, '
      'resets the curve, and reconnects with the new token immediately',
      () {
        fakeAsync((async) {
          final transport = _AlwaysFailingTransport();
          final subscription = RealtimeSubscription(
            proxyBaseUri: Uri.parse('ws://localhost:8080'),
            transport: transport,
            initialBackoff: const Duration(seconds: 1),
            maxBackoff: const Duration(seconds: 30),
          );
          subscription.setTenantContext(
            const RealtimeTenantContext(operatorId: _opA, authToken: 'tA'),
          );
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();
          async.elapse(const Duration(seconds: 2));
          async.flushMicrotasks();
          expect(transport.attempts, 3);
          // Mid back-off (would next fire at +4s), set a new tenant.
          subscription.setTenantContext(
            const RealtimeTenantContext(operatorId: _opB, authToken: 'tB'),
          );
          async.flushMicrotasks();
          // Immediately re-connects at the new tenant — no waiting for
          // the previous back-off timer.
          expect(transport.attempts, 4);
          expect(transport.lastTokenAttempted, 'tB');
          expect(subscription.currentBackoffForTest, const Duration(seconds: 1));
          subscription.dispose();
        });
      },
    );
  });

  group('RealtimeSubscription clearTenantContext (sign-out path)', () {
    test(
      'tears down active channel, cancels reconnect, emits idle, '
      'and stays restartable on the next setTenantContext',
      () async {
        // The teardown chain walks real Stream microtasks
        // (StreamSubscription.cancel + StreamController.close), which
        // do not resolve under `fakeAsync` — use real async/await
        // here, matching the "in-flight stale connect" test above.
        final transport = _ScriptedTransport()
          ..nextResult = _ConnectResult.success();
        final subscription = RealtimeSubscription(
          proxyBaseUri: Uri.parse('ws://localhost:8080'),
          transport: transport,
          initialBackoff: const Duration(seconds: 1),
          maxBackoff: const Duration(seconds: 30),
        );
        final states = <RealtimeConnectionState>[];
        final stateSub = subscription.connectionState.listen(states.add);

        await subscription.setTenantContext(
          const RealtimeTenantContext(operatorId: _opA, authToken: 'tA'),
        );
        await Future<void>.delayed(Duration.zero);
        // Reached the connected lifecycle.
        expect(transport.attempts, 1);
        expect(states.last, RealtimeConnectionState.connected);
        final connectedChannel = transport.activeChannel!;
        expect(connectedChannel.closed, isFalse);

        // Sign-out: drop the tenant scope. The state stream delivers
        // events on a microtask hop, so yield once after the clear
        // completes before asserting the last broadcast value.
        await subscription.clearTenantContext();
        await Future<void>.delayed(Duration.zero);
        expect(
          connectedChannel.closed,
          isTrue,
          reason: 'sign-out must close the previous tenant\'s channel',
        );
        expect(states.last, RealtimeConnectionState.idle);
        // currentConnectionState reads the synchronous field; the
        // public stream always trails by a microtask.
        expect(
          subscription.currentConnectionState,
          RealtimeConnectionState.idle,
        );

        // Walk forward — clearTenantContext must not schedule any
        // future reconnect attempts under the old tenant. We don't
        // have access to fakeAsync here, but the public counter is
        // good enough: any scheduled reconnect would have to call
        // transport.connect again.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          transport.attempts,
          1,
          reason: 'no reconnect attempts allowed while tenant is cleared',
        );

        // Restartable: signing back in resumes the lifecycle.
        transport.nextResult = _ConnectResult.success();
        await subscription.setTenantContext(
          const RealtimeTenantContext(operatorId: _opB, authToken: 'tB'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(transport.attempts, 2);
        expect(states.last, RealtimeConnectionState.connected);

        await stateSub.cancel();
        await subscription.dispose();
      },
    );

    test(
      'invalidates an in-flight stale connect so it cannot bind '
      'to the post-sign-out idle subscription',
      () async {
        final transport = _DeferredTransport();
        final subscription = RealtimeSubscription(
          proxyBaseUri: Uri.parse('ws://localhost:8080'),
          transport: transport,
        );
        await subscription.setTenantContext(
          const RealtimeTenantContext(operatorId: _opA, authToken: 'tA'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(transport.pendingConnects, hasLength(1));
        final pending = transport.pendingConnects.removeAt(0);

        // Sign-out arrives while the connect is still pending.
        await subscription.clearTenantContext();

        // Now resolve the stale connect with a fresh channel; the
        // generation invariant must close it instead of binding it.
        final staleChannel = _FakeChannel();
        pending.complete(staleChannel);
        await Future<void>.delayed(Duration.zero);

        expect(
          staleChannel.closed,
          isTrue,
          reason: 'channel resolved after clearTenantContext belongs to '
              'a discarded session and must be closed',
        );
        expect(
          subscription.currentConnectionState,
          RealtimeConnectionState.idle,
        );

        await subscription.dispose();
      },
    );

    test('repeated clearTenantContext calls are idempotent', () {
      fakeAsync((async) {
        final transport = _AlwaysFailingTransport();
        final subscription = RealtimeSubscription(
          proxyBaseUri: Uri.parse('ws://localhost:8080'),
          transport: transport,
        );
        // No tenant has ever been set; clearing must not throw.
        subscription.clearTenantContext();
        async.flushMicrotasks();
        expect(subscription.currentConnectionState,
            RealtimeConnectionState.idle);

        // Set + clear + clear is also fine.
        subscription.setTenantContext(
          const RealtimeTenantContext(operatorId: _opA, authToken: 'tA'),
        );
        async.flushMicrotasks();
        subscription.clearTenantContext();
        async.flushMicrotasks();
        subscription.clearTenantContext();
        async.flushMicrotasks();
        expect(subscription.currentConnectionState,
            RealtimeConnectionState.idle);

        subscription.dispose();
      });
    });
  });

  group('RealtimeSubscription dispose', () {
    test(
      'dispose cancels the in-flight reconnect timer and stops further '
      'connect attempts',
      () {
        fakeAsync((async) {
          final transport = _AlwaysFailingTransport();
          final subscription = RealtimeSubscription(
            proxyBaseUri: Uri.parse('ws://localhost:8080'),
            transport: transport,
            initialBackoff: const Duration(seconds: 1),
            maxBackoff: const Duration(seconds: 30),
          );
          subscription.setTenantContext(
            const RealtimeTenantContext(operatorId: _opA, authToken: 'tA'),
          );
          async.flushMicrotasks();
          expect(transport.attempts, 1);
          subscription.dispose();
          async.elapse(const Duration(seconds: 30));
          expect(
            transport.attempts,
            1,
            reason: 'no further connect attempts after dispose',
          );
        });
      },
    );
  });

  group('RealtimeSubscription frame parsing', () {
    test('valid JSON frames surface as RealtimeEvent on events stream',
        () async {
      final transport = _ScriptedTransport()
        ..nextResult = _ConnectResult.success();
      final subscription = RealtimeSubscription(
        proxyBaseUri: Uri.parse('ws://localhost:8080'),
        transport: transport,
      );
      final received = <RealtimeEvent>[];
      final sub = subscription.events.listen(received.add);
      await subscription.setTenantContext(
        const RealtimeTenantContext(operatorId: _opA, authToken: 'tA'),
      );
      // Wait for the connect to land and the listener to attach.
      await Future<void>.delayed(Duration.zero);
      transport.activeChannel!.injectFrame(
        RealtimeEvent(
          eventId: 'evt-1',
          topic: 'rollup.invalidate.variance_week',
          operatorId: _opA,
          occurredAt: DateTime.utc(2026, 5, 2, 12),
          payload: const <String, Object?>{'week_start': '2026-04-27'},
        ).encode(),
      );
      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      expect(received.single.topic, 'rollup.invalidate.variance_week');
      expect(received.single.eventId, 'evt-1');
      await sub.cancel();
      await subscription.dispose();
    });

    test('malformed frames are dropped and do not crash the subscription',
        () async {
      final transport = _ScriptedTransport()
        ..nextResult = _ConnectResult.success();
      final subscription = RealtimeSubscription(
        proxyBaseUri: Uri.parse('ws://localhost:8080'),
        transport: transport,
      );
      final received = <RealtimeEvent>[];
      final sub = subscription.events.listen(received.add);
      await subscription.setTenantContext(
        const RealtimeTenantContext(operatorId: _opA, authToken: 'tA'),
      );
      await Future<void>.delayed(Duration.zero);
      transport.activeChannel!.injectFrame('not-json');
      transport.activeChannel!.injectFrame('{"not":"an event"}');
      transport.activeChannel!.injectFrame(
        RealtimeEvent(
          eventId: 'evt-good',
          topic: 'rollup.invalidate.variance_week',
          operatorId: _opA,
          occurredAt: DateTime.utc(2026, 5, 2, 12),
          payload: const <String, Object?>{},
        ).encode(),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        received.map((e) => e.eventId).toList(),
        <String>['evt-good'],
        reason: 'good frame still arrives after two bad ones',
      );
      await sub.cancel();
      await subscription.dispose();
    });
  });
}

class _AlwaysFailingTransport implements RealtimeTransport {
  int attempts = 0;
  String? lastTokenAttempted;

  @override
  Future<RealtimeChannel> connect(Uri uri, {String? authToken}) async {
    attempts += 1;
    lastTokenAttempted = authToken;
    throw const _SimulatedConnectFailure();
  }
}

class _ScriptedTransport implements RealtimeTransport {
  final List<_ConnectResult> _queue = <_ConnectResult>[];
  int attempts = 0;
  _FakeChannel? activeChannel;

  set nextResult(_ConnectResult result) {
    _queue.add(result);
  }

  @override
  Future<RealtimeChannel> connect(Uri uri, {String? authToken}) async {
    attempts += 1;
    if (_queue.isEmpty) throw StateError('no scripted result for connect');
    final result = _queue.removeAt(0);
    if (result.shouldFail) throw const _SimulatedConnectFailure();
    final channel = _FakeChannel();
    activeChannel = channel;
    return channel;
  }
}

class _ConnectResult {
  const _ConnectResult._({required this.shouldFail});
  factory _ConnectResult.success() => const _ConnectResult._(shouldFail: false);
  factory _ConnectResult.fail() => const _ConnectResult._(shouldFail: true);
  final bool shouldFail;
}

class _FakeChannel implements RealtimeChannel {
  final StreamController<String> _controller =
      StreamController<String>.broadcast();
  bool closed = false;

  @override
  Stream<String> get incoming => _controller.stream;

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }

  void injectFrame(String frame) {
    if (!_controller.isClosed) _controller.add(frame);
  }

  void simulateClose() {
    if (!_controller.isClosed) _controller.close();
  }
}

/// Transport that hands out long-lived [Completer]s so the test can
/// resolve each [connect] call manually. Required for the
/// generation-token test to interleave a tenant change between the
/// connect call and its resolution.
class _DeferredTransport implements RealtimeTransport {
  final List<Completer<RealtimeChannel>> pendingConnects =
      <Completer<RealtimeChannel>>[];

  @override
  Future<RealtimeChannel> connect(Uri uri, {String? authToken}) {
    final completer = Completer<RealtimeChannel>();
    pendingConnects.add(completer);
    return completer.future;
  }
}

class _SimulatedConnectFailure implements Exception {
  const _SimulatedConnectFailure();
}
