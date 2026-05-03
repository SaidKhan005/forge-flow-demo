// Phase 10a.UX.1 — Realtime producer wiring end-to-end test.
//
// Pin the production wiring after the 10a.UX.0 / 10a.UX.1 lane
// integration:
//   * The shared `RealtimeSubscription` is created by 10a.UX.0's
//     `bootstrapAndRunApp` and exposed via
//     `Provider<RealtimeSubscription?>`. The auth-driven lifecycle
//     (`setTenantContext` / `clearTenantContext`) lives in UX.0's
//     `RealtimeAuthBridge` above the app shell.
//   * UX.1's `_RealtimeProducerWiring` (this slice) consumes that
//     same subscription via the Provider, pipes
//     `subscription.events` into the [RealtimeEventBus], and clears
//     the [LastSyncedTimestampsNotifier] on hard sign-out /
//     operator change so the prior tenant's freshness rows do not
//     survive session loss.
//
// Without these pins, an integration regression could silently:
//   - leave the freshness map populated across a sign-out, OR
//   - drop the events pipe so frames never reach the toast/bus.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/forge_flow_app.dart';
import 'package:forge_and_flow/services/auth_login_service.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/services/realtime/realtime_subscription.dart';
import 'package:forge_and_flow/services/realtime/realtime_transport.dart';
import 'package:forge_and_flow/services/secure_session_storage.dart';
import 'package:forge_and_flow/state/auth_session_notifier.dart';
import 'package:forge_and_flow/state/last_synced_timestamps_notifier.dart';
import 'package:forge_and_flow/state/realtime_event_bus.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '22222222-2222-2222-2222-222222222222';
const String _locA = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

void main() {
  testWidgets(
    'frames from the shared RealtimeSubscription flow into the bus '
    'and surface on the shell-level PeerEditToast',
    (tester) async {
      final transport = _ScriptedRealtimeTransport();
      final subscription = RealtimeSubscription(
        proxyBaseUri: Uri.parse('ws://localhost:8080'),
        transport: transport,
      );
      addTearDown(subscription.dispose);
      final authNotifier = AuthSessionNotifier(
        loginService: const ScaffoldFailingAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      );

      // Mirror the bootstrap layout: Provider<RealtimeSubscription?>
      // above the app, AuthSessionNotifier above it. UX.0's
      // RealtimeAuthBridge isn't in the test tree, so the test
      // drives the subscription directly via setTenantContext.
      await tester.pumpWidget(
        Provider<RealtimeSubscription?>.value(
          value: subscription,
          child: ChangeNotifierProvider<AuthSessionNotifier>.value(
            value: authNotifier,
            child: const ForgeFlowApp(requireAuth: false),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Connect the subscription so the fake channel opens.
      await subscription.setTenantContext(
        const RealtimeTenantContext(
          operatorId: _opA,
          authToken: 'token-A',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump();
      expect(transport.activeChannel, isNotNull);

      final bus = tester
          .element(find.byType(MaterialApp))
          .read<RealtimeEventBus>();
      final received = <RealtimeEvent>[];
      final busSub = bus.events.listen(received.add);
      addTearDown(busSub.cancel);

      transport.activeChannel!.injectFrame(
        jsonEncode(<String, Object?>{
          'event_id': 'evt-pipe-1',
          'topic': 'shared_state.$_opA.audit_trail',
          'operator_id': _opA,
          'occurred_at': '2026-05-03T18:23:41.123Z',
          'payload': <String, Object?>{
            'schema_version': 1,
            'table': 'audit_trail',
            'op': 'INSERT',
          },
        }),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(received.map((e) => e.eventId).toList(), <String>['evt-pipe-1']);
      expect(find.text('Peer edit: audit_trail'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets(
    'sign-out clears LastSyncedTimestampsNotifier so the prior '
    'tenant\'s freshness rows do not survive session loss',
    (tester) async {
      final authNotifier = AuthSessionNotifier(
        loginService: const ScaffoldFailingAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      );

      await tester.pumpWidget(
        // No subscription provider — keeps the producer dormant on
        // the events-pipe side so the freshness clear is the only
        // thing being exercised.
        ChangeNotifierProvider<AuthSessionNotifier>.value(
          value: authNotifier,
          child: const ForgeFlowApp(requireAuth: false),
        ),
      );
      await tester.pump();
      await tester.pump();

      final freshness = tester
          .element(find.byType(MaterialApp))
          .read<LastSyncedTimestampsNotifier>();

      // Operator A signs in and the freshness map picks up a frame
      // via direct ingestion (the test bypasses the subscription
      // pipe so it can isolate the clear logic).
      authNotifier.debugSetSession(_session(_opA, 'token-A'));
      await tester.pump();
      freshness.ingest(
        _event(
          topic: 'shared_state.$_opA.audit_trail',
          payload: const <String, Object?>{'table': 'audit_trail'},
        ),
      );
      expect(
        freshness.lastSyncedAt('audit_trail'),
        isNotNull,
        reason: 'operator A frame must stamp the audit_trail row',
      );

      // Sign out. Producer's auth listener fires → freshness clears.
      authNotifier.debugSetState(const AuthSessionUnauthenticated());
      await tester.pump();
      expect(
        freshness.timestamps,
        isEmpty,
        reason:
            'sign-out must clear the freshness map; the prior '
            'tenant\'s timestamps cannot survive session loss',
      );

      // Operator B signs in with no frames yet → still empty.
      authNotifier.debugSetSession(_session(_opB, 'token-B'));
      await tester.pump();
      expect(
        freshness.timestamps,
        isEmpty,
        reason:
            'operator B starts with a clean freshness map; '
            'operator A\'s timestamps must NOT carry over',
      );
    },
  );

  testWidgets(
    'operator change without an intervening Unauthenticated state '
    '(SSO-style swap) also clears freshness so the prior tenant\'s '
    'rows do not leak',
    (tester) async {
      final authNotifier = AuthSessionNotifier(
        loginService: const ScaffoldFailingAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<AuthSessionNotifier>.value(
          value: authNotifier,
          child: const ForgeFlowApp(requireAuth: false),
        ),
      );
      await tester.pump();
      await tester.pump();

      final freshness = tester
          .element(find.byType(MaterialApp))
          .read<LastSyncedTimestampsNotifier>();

      authNotifier.debugSetSession(_session(_opA, 'token-A'));
      await tester.pump();
      freshness.ingest(
        _event(
          topic: 'shared_state.$_opA.audit_trail',
          payload: const <String, Object?>{'table': 'audit_trail'},
        ),
      );
      expect(freshness.lastSyncedAt('audit_trail'), isNotNull);

      // Direct Authenticated → Authenticated swap with a different
      // operator id — defensive clear path.
      authNotifier.debugSetSession(_session(_opB, 'token-B'));
      await tester.pump();
      expect(
        freshness.timestamps,
        isEmpty,
        reason:
            'operator-id change without Unauthenticated must still '
            'clear freshness; prior tenant rows are not allowed to '
            'leak across operator swaps',
      );
    },
  );

  testWidgets(
    'token-refresh blip (same operator, transient Loading) preserves '
    'freshness — only hard sign-outs and operator changes wipe rows',
    (tester) async {
      final authNotifier = AuthSessionNotifier(
        loginService: const ScaffoldFailingAuthLoginService(),
        storage: InMemorySecureSessionStorage(),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<AuthSessionNotifier>.value(
          value: authNotifier,
          child: const ForgeFlowApp(requireAuth: false),
        ),
      );
      await tester.pump();
      await tester.pump();

      final freshness = tester
          .element(find.byType(MaterialApp))
          .read<LastSyncedTimestampsNotifier>();

      authNotifier.debugSetSession(_session(_opA, 'token-A'));
      await tester.pump();
      freshness.ingest(
        _event(
          topic: 'shared_state.$_opA.audit_trail',
          payload: const <String, Object?>{'table': 'audit_trail'},
        ),
      );
      expect(freshness.lastSyncedAt('audit_trail'), isNotNull);

      // Transient Loading — the operator id is still A; freshness
      // must not be wiped.
      authNotifier.debugSetState(const AuthSessionLoading());
      await tester.pump();
      expect(
        freshness.lastSyncedAt('audit_trail'),
        isNotNull,
        reason:
            'transient Loading must NOT wipe freshness — a token-'
            'refresh blip would otherwise erase valid rows',
      );

      // Back to Authenticated as the same operator with a refreshed
      // token — still no clear.
      authNotifier.debugSetSession(_session(_opA, 'token-A2'));
      await tester.pump();
      expect(
        freshness.lastSyncedAt('audit_trail'),
        isNotNull,
        reason: 'same operator returning from Loading preserves rows',
      );
    },
  );
}

AuthSession _session(String operatorId, String token) {
  return AuthSession(
    userId: 'user-$operatorId',
    operatorId: operatorId,
    locationId: _locA,
    firebaseIdToken: token,
    issuedAt: DateTime.utc(2026, 5, 3, 12),
    expiresAt: DateTime.utc(2026, 5, 3, 13),
    lastFreshAuthAt: DateTime.utc(2026, 5, 3, 12),
    roles: const <String>['operator_owner'],
    mfaEnrolled: false,
  );
}

RealtimeEvent _event({
  required String topic,
  required Map<String, Object?> payload,
}) {
  return RealtimeEvent(
    eventId: 'evt-${topic.hashCode}-${payload['table'] ?? 'none'}',
    topic: topic,
    operatorId: _opA,
    occurredAt: DateTime.utc(2026, 5, 3, 12),
    payload: payload,
  );
}

/// Test seam — fake transport that opens a fake channel and lets the
/// test inject inbound frames. Mirrors the pattern from
/// `test/services/realtime/realtime_subscription_test.dart`.
class _ScriptedRealtimeTransport implements RealtimeTransport {
  _FakeRealtimeChannel? activeChannel;

  @override
  Future<RealtimeChannel> connect(Uri uri, {String? authToken}) async {
    final channel = _FakeRealtimeChannel();
    activeChannel = channel;
    return channel;
  }
}

class _FakeRealtimeChannel implements RealtimeChannel {
  final StreamController<String> _controller =
      StreamController<String>.broadcast();
  bool closed = false;

  void injectFrame(String raw) {
    if (closed) return;
    _controller.add(raw);
  }

  @override
  Stream<String> get incoming => _controller.stream;

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _controller.close();
  }
}
