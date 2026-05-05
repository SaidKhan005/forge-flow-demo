// Phase 10a.5 — `last_event_id` reconnect-resume tests.
//
// Pinned behavior:
//   * Client RealtimeSubscription tracks the most recent event_id seen
//     on the current tenant scope and forwards it to the transport on
//     every reconnect. setTenantContext / clearTenantContext clear the
//     cursor (the previous tenant's id must never reach the new
//     scope).
//   * The server route `handleRealtimeUpgrade` reads
//     `?last_event_id=<id>` from the upgrade URI; when present and a
//     [RealtimeReplayFetcher] is wired, it replays events scoped to
//     the connecting operator BEFORE forwarding live frames.
//   * Beyond the replay window the route emits a single
//     `{"control":"replay_truncated"}` envelope and the client clears
//     its cursor on receipt so the next reconnect does not loop on
//     the same stale id.
//   * Replay is operator-scoped — a fetcher MUST receive the
//     connecting operator's [OperatorContext] and the route's defense-
//     in-depth check drops events whose operator_id mismatches before
//     they hit the wire.
//   * First-connect (null last_event_id) leaves the replay seam
//     untouched — the existing 10a.0 behavior is unchanged.
//
// Authority:
//   * docs/contracts/event_outbox_contract.md — Topic / Payload Shape.
//   * docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md
//     "WebSocket lifecycle" subsection.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/services/realtime/realtime_event_publisher.dart';
import 'package:forge_and_flow/services/realtime/realtime_subscription.dart';
import 'package:forge_and_flow/services/realtime/realtime_transport.dart';
import 'package:forge_and_flow/services/realtime/web_socket_channel_realtime_transport.dart';
import 'package:web_socket_channel/io.dart';

import '../../../tool/advisor_proxy/advisor_proxy.dart';
import '../../../tool/advisor_proxy/realtime_route.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '22222222-2222-2222-2222-222222222222';

void main() {
  group('RealtimeSubscription cursor tracking', () {
    test(
      'tracks the most recent event_id from inbound frames and forwards '
      'it on reconnect',
      () async {
        final transport = _RecordingTransport()
          ..nextChannel = _FakeChannel()
          ..nextChannel = _FakeChannel();
        final subscription = RealtimeSubscription(
          proxyBaseUri: Uri.parse('ws://localhost:8080'),
          transport: transport,
          initialBackoff: const Duration(milliseconds: 50),
          maxBackoff: const Duration(milliseconds: 200),
        );
        await subscription.setTenantContext(
          const RealtimeTenantContext(operatorId: _opA, authToken: 'tA'),
        );
        await Future<void>.delayed(Duration.zero);

        // First connect carries no cursor (nothing seen yet).
        expect(transport.lastEventIdsAttempted, <String?>[null]);
        expect(subscription.lastEventIdForTest, isNull);

        // Receive a frame; cursor should advance.
        final firstChannel = transport.channels[0];
        firstChannel.injectFrame(
          RealtimeEvent(
            eventId: '42',
            topic: 'rollup.invalidate.variance_week',
            operatorId: _opA,
            occurredAt: DateTime.utc(2026, 5, 5, 12),
            payload: const <String, Object?>{},
          ).encode(),
        );
        await Future<void>.delayed(Duration.zero);
        expect(subscription.lastEventIdForTest, '42');

        // Drop the channel to trigger reconnect; the new connect must
        // carry the cursor.
        firstChannel.simulateClose();
        // Wait for the back-off timer to fire and the second connect
        // to register its lastEventId on the transport.
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          if (transport.lastEventIdsAttempted.length >= 2) break;
        }
        expect(
          transport.lastEventIdsAttempted,
          <String?>[null, '42'],
          reason: 'reconnect after a frame must forward the cursor',
        );

        await subscription.dispose();
      },
    );

    test(
      'setTenantContext drops the cursor so the new operator does NOT '
      'inherit the previous scope\'s last_event_id',
      () async {
        final transport = _RecordingTransport()
          ..nextChannel = _FakeChannel()
          ..nextChannel = _FakeChannel();
        final subscription = RealtimeSubscription(
          proxyBaseUri: Uri.parse('ws://localhost:8080'),
          transport: transport,
        );
        await subscription.setTenantContext(
          const RealtimeTenantContext(operatorId: _opA, authToken: 'tA'),
        );
        await Future<void>.delayed(Duration.zero);
        transport.channels[0].injectFrame(
          RealtimeEvent(
            eventId: '99',
            topic: 'rollup.invalidate.variance_week',
            operatorId: _opA,
            occurredAt: DateTime.utc(2026, 5, 5, 12),
            payload: const <String, Object?>{},
          ).encode(),
        );
        await Future<void>.delayed(Duration.zero);
        expect(subscription.lastEventIdForTest, '99');

        // Switch tenants — A's cursor must NOT cross over to B.
        await subscription.setTenantContext(
          const RealtimeTenantContext(operatorId: _opB, authToken: 'tB'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(subscription.lastEventIdForTest, isNull);
        expect(
          transport.lastEventIdsAttempted.last,
          isNull,
          reason: 'tenant B\'s first connect must not carry tenant A\'s id',
        );

        await subscription.dispose();
      },
    );

    test(
      'replay_truncated control envelope clears the cursor and emits on '
      'replayTruncated stream',
      () async {
        final transport = _RecordingTransport()..nextChannel = _FakeChannel();
        final subscription = RealtimeSubscription(
          proxyBaseUri: Uri.parse('ws://localhost:8080'),
          transport: transport,
        );
        final received = <RealtimeEvent>[];
        final eventsSub = subscription.events.listen(received.add);
        var truncatedFires = 0;
        final truncatedSub =
            subscription.replayTruncated.listen((_) => truncatedFires += 1);

        await subscription.setTenantContext(
          const RealtimeTenantContext(operatorId: _opA, authToken: 'tA'),
        );
        await Future<void>.delayed(Duration.zero);

        // Seed a cursor so we can verify it gets cleared.
        transport.channels[0].injectFrame(
          RealtimeEvent(
            eventId: '7',
            topic: 'rollup.invalidate.variance_week',
            operatorId: _opA,
            occurredAt: DateTime.utc(2026, 5, 5, 12),
            payload: const <String, Object?>{},
          ).encode(),
        );
        await Future<void>.delayed(Duration.zero);
        expect(subscription.lastEventIdForTest, '7');

        // Server emits the truncation control envelope.
        transport.channels[0].injectFrame(
          jsonEncode(<String, Object?>{
            kRealtimeControlKey: kRealtimeControlReplayTruncated,
          }),
        );
        await Future<void>.delayed(Duration.zero);
        expect(truncatedFires, 1);
        expect(
          subscription.lastEventIdForTest,
          isNull,
          reason: 'cursor must drop so the next reconnect does not loop on the '
              'same stale id',
        );
        expect(
          received.where((e) => e.eventId == 'control'),
          isEmpty,
          reason: 'control envelopes must NOT surface as RealtimeEvent frames',
        );

        await eventsSub.cancel();
        await truncatedSub.cancel();
        await subscription.dispose();
      },
    );
  });

  group('handleRealtimeUpgrade replay path (server-side)', () {
    late HttpServer server;
    late InProcessRealtimePublisher publisher;
    late _SettableVerifier verifier;
    late ProxyRequestGuard authGuard;
    late int port;
    late _ScriptedReplayFetcher replayFetcher;

    setUp(() async {
      publisher = InProcessRealtimePublisher();
      verifier = _SettableVerifier()
        ..claims = const ProxyJwtClaims(
          userId: 'user_ok',
          operatorId: _opA,
          locationId: 'loc_ok',
          roles: <String>[],
        );
      authGuard = ProxyRequestGuard(verifier: verifier);
      replayFetcher = _ScriptedReplayFetcher();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      server.listen((HttpRequest request) {
        unawaited(
          handleRealtimeUpgrade(
            request: request,
            authGuard: authGuard,
            publisher: publisher,
            replayFetcher: replayFetcher.fetch,
          ),
        );
      });
    });

    tearDown(() async {
      await server.close(force: true);
      await publisher.close();
    });

    test(
      'first connect (no last_event_id query) does not invoke the replay '
      'fetcher — the 10a.0 path is unchanged',
      () async {
        final received = <String>[];
        final completer = Completer<void>();
        final channel = IOWebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:$port/v1/realtime'),
          headers: <String, dynamic>{
            HttpHeaders.authorizationHeader: 'Bearer t',
          },
        );
        await channel.ready;
        final sub = channel.stream.listen(
          (Object? frame) {
            received.add(frame is String ? frame : frame.toString());
            if (received.length == 1 && !completer.isCompleted) {
              completer.complete();
            }
          },
          onError: (Object e) {
            if (!completer.isCompleted) completer.completeError(e);
          },
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await publisher.publish(
          RealtimeEvent(
            eventId: 'live-1',
            topic: 'rollup.invalidate.variance_week',
            operatorId: _opA,
            occurredAt: DateTime.utc(2026, 5, 5, 12),
            payload: const <String, Object?>{},
          ),
        );
        await completer.future.timeout(const Duration(seconds: 2));

        expect(replayFetcher.invocations, isEmpty,
            reason: 'no last_event_id ⇒ no replay');
        expect(received, hasLength(1));
        expect(
          (jsonDecode(received.single) as Map<String, Object?>)['event_id'],
          'live-1',
        );

        await sub.cancel();
        await channel.sink.close();
      },
    );

    test(
      'recent last_event_id replays missed events BEFORE live frames flow',
      () async {
        replayFetcher.nextResult = RealtimeReplayResult(
          events: <RealtimeEvent>[
            RealtimeEvent(
              eventId: '101',
              topic: 'rollup.invalidate.variance_week',
              operatorId: _opA,
              occurredAt: DateTime.utc(2026, 5, 5, 12),
              payload: const <String, Object?>{},
            ),
            RealtimeEvent(
              eventId: '102',
              topic: 'rollup.invalidate.variance_week',
              operatorId: _opA,
              occurredAt: DateTime.utc(2026, 5, 5, 12, 0, 1),
              payload: const <String, Object?>{},
            ),
          ],
          truncated: false,
        );

        final received = <String>[];
        final firstReplay = Completer<void>();
        final secondReplay = Completer<void>();
        final live = Completer<void>();
        final channel = IOWebSocketChannel.connect(
          Uri.parse(
            'ws://127.0.0.1:$port/v1/realtime?last_event_id=100',
          ),
          headers: <String, dynamic>{
            HttpHeaders.authorizationHeader: 'Bearer t',
          },
        );
        await channel.ready;
        final sub = channel.stream.listen(
          (Object? frame) {
            received.add(frame is String ? frame : frame.toString());
            if (received.length == 1 && !firstReplay.isCompleted) {
              firstReplay.complete();
            } else if (received.length == 2 && !secondReplay.isCompleted) {
              secondReplay.complete();
            } else if (received.length == 3 && !live.isCompleted) {
              live.complete();
            }
          },
        );
        // Give the route time to invoke the fetcher and send replay
        // frames before publishing the live event.
        await firstReplay.future.timeout(const Duration(seconds: 2));
        await secondReplay.future.timeout(const Duration(seconds: 2));

        // Verify replay arrived first, in producer order.
        expect(
          received.map(
            (raw) => (jsonDecode(raw) as Map<String, Object?>)['event_id'],
          ),
          <Object?>['101', '102'],
        );

        await publisher.publish(
          RealtimeEvent(
            eventId: 'live-after-replay',
            topic: 'rollup.invalidate.variance_week',
            operatorId: _opA,
            occurredAt: DateTime.utc(2026, 5, 5, 12, 0, 2),
            payload: const <String, Object?>{},
          ),
        );
        await live.future.timeout(const Duration(seconds: 2));
        expect(received, hasLength(3));
        expect(
          (jsonDecode(received[2]) as Map<String, Object?>)['event_id'],
          'live-after-replay',
        );

        // Fetcher was invoked exactly once, with the connecting
        // operator's scope and the cursor from the URI.
        expect(replayFetcher.invocations, hasLength(1));
        final invocation = replayFetcher.invocations.single;
        expect(invocation.scope.operatorId, _opA);
        expect(invocation.lastEventId, '100');
        expect(invocation.window, kRealtimeReplayWindow);

        await sub.cancel();
        await channel.sink.close();
      },
    );

    test(
      'fetcher returning truncated=true emits replay_truncated control '
      'envelope and skips replay events',
      () async {
        replayFetcher.nextResult = const RealtimeReplayResult(
          events: <RealtimeEvent>[],
          truncated: true,
        );

        final received = <String>[];
        final controlReceived = Completer<void>();
        final channel = IOWebSocketChannel.connect(
          Uri.parse(
            'ws://127.0.0.1:$port/v1/realtime?last_event_id=1',
          ),
          headers: <String, dynamic>{
            HttpHeaders.authorizationHeader: 'Bearer t',
          },
        );
        await channel.ready;
        final sub = channel.stream.listen(
          (Object? frame) {
            received.add(frame is String ? frame : frame.toString());
            if (received.length == 1 && !controlReceived.isCompleted) {
              controlReceived.complete();
            }
          },
        );
        await controlReceived.future.timeout(const Duration(seconds: 2));

        expect(received, hasLength(1));
        final decoded = jsonDecode(received.single) as Map<String, Object?>;
        expect(decoded[kRealtimeControlKey], kRealtimeControlReplayTruncated);
        expect(
          decoded.containsKey('event_id'),
          isFalse,
          reason: 'control envelopes must not carry event_id',
        );

        await sub.cancel();
        await channel.sink.close();
      },
    );

    test(
      'route drops a fetcher event whose operator_id mismatches the '
      'connecting scope (defense in depth against a buggy fetcher)',
      () async {
        // Fetcher returns one row scoped to A (correct) and one to B
        // (incorrect — simulates a bug in a future replay binding).
        replayFetcher.nextResult = RealtimeReplayResult(
          events: <RealtimeEvent>[
            RealtimeEvent(
              eventId: 'a-1',
              topic: 'rollup.invalidate.variance_week',
              operatorId: _opA,
              occurredAt: DateTime.utc(2026, 5, 5, 12),
              payload: const <String, Object?>{},
            ),
            RealtimeEvent(
              eventId: 'b-leak',
              topic: 'rollup.invalidate.variance_week',
              operatorId: _opB,
              occurredAt: DateTime.utc(2026, 5, 5, 12),
              payload: const <String, Object?>{},
            ),
          ],
          truncated: false,
        );

        final received = <String>[];
        final firstReplay = Completer<void>();
        final channel = IOWebSocketChannel.connect(
          Uri.parse(
            'ws://127.0.0.1:$port/v1/realtime?last_event_id=0',
          ),
          headers: <String, dynamic>{
            HttpHeaders.authorizationHeader: 'Bearer t',
          },
        );
        await channel.ready;
        final sub = channel.stream.listen(
          (Object? frame) {
            received.add(frame is String ? frame : frame.toString());
            if (received.length == 1 && !firstReplay.isCompleted) {
              firstReplay.complete();
            }
          },
        );
        await firstReplay.future.timeout(const Duration(seconds: 2));
        // Give the route a tick so the second (cross-operator) event
        // would have been written if the guard were missing.
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(received, hasLength(1));
        final decoded = jsonDecode(received.single) as Map<String, Object?>;
        expect(decoded['event_id'], 'a-1');
        expect(
          received.any((raw) => raw.contains('b-leak')),
          isFalse,
          reason:
              'cross-operator events from a buggy fetcher must never reach '
              'the wire',
        );

        await sub.cancel();
        await channel.sink.close();
      },
    );

    test(
      'WebSocketChannelRealtimeTransport places last_event_id on the URI '
      'as a query parameter (browser-compatible carrier)',
      () async {
        // End-to-end: real client transport → real server route →
        // verify the fetcher receives the cursor parsed off the URI.
        replayFetcher.nextResult = const RealtimeReplayResult(
          events: <RealtimeEvent>[],
          truncated: false,
        );
        final transport = const WebSocketChannelRealtimeTransport();
        final channel = await transport.connect(
          Uri.parse('ws://127.0.0.1:$port/v1/realtime'),
          authToken: 't',
          lastEventId: '777',
        );

        // Drain the incoming stream (replay returned no events; we
        // just need to know the route invoked the fetcher with the
        // cursor we passed through the transport).
        final drain = channel.incoming.listen((_) {});
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(replayFetcher.invocations, hasLength(1));
        expect(replayFetcher.invocations.single.lastEventId, '777');

        await drain.cancel();
        await channel.close();
      },
    );
  });
}

class _RecordingTransport implements RealtimeTransport {
  final List<_FakeChannel> _queue = <_FakeChannel>[];
  final List<String?> lastEventIdsAttempted = <String?>[];
  final List<_FakeChannel> channels = <_FakeChannel>[];

  set nextChannel(_FakeChannel channel) => _queue.add(channel);

  @override
  Future<RealtimeChannel> connect(
    Uri uri, {
    String? authToken,
    String? lastEventId,
  }) async {
    lastEventIdsAttempted.add(lastEventId);
    if (_queue.isEmpty) {
      throw StateError(
        'no scripted channel for connect (#${lastEventIdsAttempted.length})',
      );
    }
    final next = _queue.removeAt(0);
    channels.add(next);
    return next;
  }
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

class _SettableVerifier implements ProxyJwtVerifier {
  ProxyJwtClaims? claims;
  String? errorMessage;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final error = errorMessage;
    if (error != null) {
      throw ProxyJwtVerificationError(error);
    }
    final value = claims;
    if (value != null) return value;
    throw ProxyJwtVerificationError('test verifier not configured');
  }
}

class _ReplayInvocation {
  const _ReplayInvocation({
    required this.scope,
    required this.lastEventId,
    required this.window,
  });

  final OperatorContext scope;
  final String lastEventId;
  final Duration window;
}

class _ScriptedReplayFetcher {
  final List<_ReplayInvocation> invocations = <_ReplayInvocation>[];
  RealtimeReplayResult? nextResult;

  Future<RealtimeReplayResult> fetch({
    required OperatorContext scope,
    required String lastEventId,
    required Duration window,
  }) async {
    invocations.add(
      _ReplayInvocation(
        scope: scope,
        lastEventId: lastEventId,
        window: window,
      ),
    );
    final result = nextResult;
    if (result == null) {
      return const RealtimeReplayResult(
        events: <RealtimeEvent>[],
        truncated: false,
      );
    }
    return result;
  }
}
