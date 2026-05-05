// Phase 10a.UX.0 — RealtimeAuthBridge widget tests.
//
// Pinned behavior:
//   * sign-in pushes the operator's tenant context into the
//     bootstrap-owned [RealtimeSubscription];
//   * sign-out (auth session → unauthenticated) calls
//     [RealtimeSubscription.clearTenantContext] so the previous
//     operator's WebSocket cannot stay connected or keep walking
//     the back-off curve (CLAUDE.md Hard Promise #4 — per-operator
//     isolation);
//   * the bridge survives navigation: popping a route below the
//     bridge (the embedded F&F destination inside Barrio is a
//     pushed route) does NOT detach the listener, so a sign-out
//     that happens AFTER the operator has popped back to the
//     Barrio home still clears the tenant scope;
//   * the subscription is restartable: signing back in resumes
//     the lifecycle without rebuilding the broadcast streams the
//     SyncStateBadge reads from.
//
// The bridge is decoupled from AppShell, so these tests mount the
// bridge directly above a trivial child.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/services/auth_login_service.dart';
import 'package:forge_and_flow/services/realtime/realtime_subscription.dart';
import 'package:forge_and_flow/services/realtime/realtime_transport.dart';
import 'package:forge_and_flow/services/secure_session_storage.dart';
import 'package:forge_and_flow/state/auth_session_notifier.dart';
import 'package:forge_and_flow/state/realtime_auth_bridge.dart';

void main() {
  group('RealtimeAuthBridge', () {
    testWidgets(
      'sign-in pushes tenant context, sign-out clears it, sign-in again '
      'restarts the subscription against the new operator',
      (tester) async {
        final transport = _ScriptedTransport();
        final subscription = RealtimeSubscription(
          proxyBaseUri: Uri.parse('ws://localhost:8080'),
          transport: transport,
        );
        addTearDown(subscription.dispose);
        final authNotifier = AuthSessionNotifier(
          loginService: const ScaffoldFailingAuthLoginService(),
          storage: ScaffoldFailingSecureSessionStorage(),
        );

        await tester.pumpWidget(
          _harness(
            authNotifier: authNotifier,
            subscription: subscription,
            child: const SizedBox.shrink(),
          ),
        );
        await tester.pumpAndSettle();

        // No tenant set yet → subscription has not been driven.
        expect(transport.attempts, 0);
        expect(
          subscription.currentConnectionState,
          RealtimeConnectionState.idle,
        );

        // Sign in as operator A.
        transport.queueSuccess();
        authNotifier.debugSetSession(_session(operatorId: 'op-A', token: 'tA'));
        await tester.pumpAndSettle();
        expect(transport.attempts, 1);
        expect(transport.lastTokenAttempted, 'tA');
        expect(
          subscription.currentConnectionState,
          RealtimeConnectionState.connected,
        );
        final connectedChannelForA = transport.activeChannel;

        // Sign out → bridge must clear the tenant scope.
        // clearTenantContext walks several real Stream microtasks
        // (StreamSubscription.cancel + StreamController.close), so
        // wrap the wait in runAsync to yield to the real event loop.
        authNotifier.debugSetState(const AuthSessionUnauthenticated());
        await tester.runAsync(() async {
          for (var i = 0; i < 20; i++) {
            await Future<void>.delayed(Duration.zero);
            if (subscription.currentConnectionState ==
                RealtimeConnectionState.idle) {
              break;
            }
          }
        });
        await tester.pumpAndSettle();
        expect(
          connectedChannelForA?.closed,
          isTrue,
          reason: 'sign-out must close the previous operator\'s channel',
        );
        expect(
          subscription.currentConnectionState,
          RealtimeConnectionState.idle,
          reason: 'tenant cleared → subscription returns to idle',
        );

        // Sign back in as a DIFFERENT operator. The subscription
        // is restartable: setTenantContext is called again and a
        // fresh channel opens.
        transport.queueSuccess();
        authNotifier.debugSetSession(_session(operatorId: 'op-B', token: 'tB'));
        await tester.pumpAndSettle();
        expect(transport.attempts, 2);
        expect(transport.lastTokenAttempted, 'tB');
        expect(
          subscription.currentConnectionState,
          RealtimeConnectionState.connected,
        );
        expect(transport.activeChannel, isNot(same(connectedChannelForA)));
      },
    );

    testWidgets(
      'sign-out AFTER popping a child route still clears the tenant — '
      'the bridge lives above the popped route, not inside it',
      (tester) async {
        // Reproduces the embedded-F&F-destination-pop case from
        // Barrio. The bridge sits above the [Navigator]; the child
        // pushes and pops a route. Even after the route is popped,
        // a subsequent sign-out must still drive
        // [RealtimeSubscription.clearTenantContext].
        final transport = _ScriptedTransport();
        final subscription = RealtimeSubscription(
          proxyBaseUri: Uri.parse('ws://localhost:8080'),
          transport: transport,
        );
        addTearDown(subscription.dispose);
        final authNotifier = AuthSessionNotifier(
          loginService: const ScaffoldFailingAuthLoginService(),
          storage: ScaffoldFailingSecureSessionStorage(),
        );

        await tester.pumpWidget(
          _harness(
            authNotifier: authNotifier,
            subscription: subscription,
            child: const _PushPopHome(),
          ),
        );
        await tester.pumpAndSettle();

        // Sign in.
        transport.queueSuccess();
        authNotifier.debugSetSession(_session(operatorId: 'op-A', token: 'tA'));
        await tester.pumpAndSettle();
        expect(
          subscription.currentConnectionState,
          RealtimeConnectionState.connected,
        );
        final channelForA = transport.activeChannel;

        // Push the destination route — analogous to entering F&F
        // from the Barrio home.
        await tester.tap(find.text('Open destination'));
        await tester.pumpAndSettle();
        expect(find.text('Destination route'), findsOneWidget);

        // Pop back. The destination subtree is unmounted — but the
        // bridge is above the Navigator, so its listener stays
        // registered.
        await tester.tap(find.text('Back'));
        await tester.pumpAndSettle();
        expect(find.text('Destination route'), findsNothing);

        // Sign out HERE, AFTER the pop. With a shell-scoped bridge
        // this would silently leak the channel; with the bootstrap
        // bridge, the listener fires and clears the tenant.
        authNotifier.debugSetState(const AuthSessionUnauthenticated());
        await tester.runAsync(() async {
          for (var i = 0; i < 20; i++) {
            await Future<void>.delayed(Duration.zero);
            if (subscription.currentConnectionState ==
                RealtimeConnectionState.idle) {
              break;
            }
          }
        });
        await tester.pumpAndSettle();
        expect(
          channelForA?.closed,
          isTrue,
          reason:
              'sign-out after pop must still close the operator\'s channel',
        );
        expect(
          subscription.currentConnectionState,
          RealtimeConnectionState.idle,
        );
      },
    );

    testWidgets(
      'redundant authenticated notifier ticks for the same operator do '
      'not reset the back-off curve',
      (tester) async {
        final transport = _ScriptedTransport();
        final subscription = RealtimeSubscription(
          proxyBaseUri: Uri.parse('ws://localhost:8080'),
          transport: transport,
        );
        addTearDown(subscription.dispose);
        final authNotifier = AuthSessionNotifier(
          loginService: const ScaffoldFailingAuthLoginService(),
          storage: ScaffoldFailingSecureSessionStorage(),
        );

        await tester.pumpWidget(
          _harness(
            authNotifier: authNotifier,
            subscription: subscription,
            child: const SizedBox.shrink(),
          ),
        );
        await tester.pumpAndSettle();

        transport.queueSuccess();
        final session = _session(operatorId: 'op-A', token: 'tA');
        authNotifier.debugSetSession(session);
        await tester.pumpAndSettle();
        expect(transport.attempts, 1);

        // Re-fire the same session — bridge dedupes via
        // (operatorId, token), so no extra connect happens.
        authNotifier.debugSetSession(session);
        await tester.pumpAndSettle();
        expect(transport.attempts, 1);
      },
    );

    testWidgets(
      'no subscription provider → bridge is a no-op (demo / no-Firebase '
      'paths and widget tests that bypass bootstrap)',
      (tester) async {
        final authNotifier = AuthSessionNotifier(
          loginService: const ScaffoldFailingAuthLoginService(),
          storage: ScaffoldFailingSecureSessionStorage(),
        );
        // Mount the bridge WITHOUT the RealtimeSubscription provider.
        await tester.pumpWidget(
          MaterialApp(
            home: ChangeNotifierProvider<AuthSessionNotifier>.value(
              value: authNotifier,
              child: const RealtimeAuthBridge(child: SizedBox.shrink()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Driving the auth state should not throw — the bridge
        // resolves a null subscription and exits.
        authNotifier.debugSetSession(_session(operatorId: 'op-A', token: 'tA'));
        await tester.pumpAndSettle();
        authNotifier.debugSetState(const AuthSessionUnauthenticated());
        await tester.pumpAndSettle();
        // Reaching this point with no exceptions is the assertion.
      },
    );
  });
}

AuthSession _session({required String operatorId, required String token}) {
  final now = DateTime.utc(2026, 5, 3, 12);
  return AuthSession(
    userId: 'user-$operatorId',
    operatorId: operatorId,
    locationId: 'loc-1',
    firebaseIdToken: token,
    issuedAt: now,
    expiresAt: now.add(const Duration(hours: 1)),
    lastFreshAuthAt: now,
    roles: const <String>[],
    mfaEnrolled: false,
  );
}

Widget _harness({
  required AuthSessionNotifier authNotifier,
  required RealtimeSubscription subscription,
  required Widget child,
}) {
  return Provider<RealtimeSubscription?>.value(
    value: subscription,
    child: ChangeNotifierProvider<AuthSessionNotifier>.value(
      value: authNotifier,
      child: RealtimeAuthBridge(child: MaterialApp(home: child)),
    ),
  );
}

class _PushPopHome extends StatelessWidget {
  const _PushPopHome();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (routeContext) => Scaffold(
                appBar: AppBar(
                  title: const Text('Destination route'),
                ),
                body: Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(routeContext).pop(),
                    child: const Text('Back'),
                  ),
                ),
              ),
            ),
          ),
          child: const Text('Open destination'),
        ),
      ),
    );
  }
}

// ── Realtime transport stub ─────────────────────────────────────────────

class _ScriptedTransport implements RealtimeTransport {
  final List<bool> _queue = <bool>[];
  int attempts = 0;
  String? lastTokenAttempted;
  _FakeChannel? activeChannel;

  void queueSuccess() => _queue.add(true);

  @override
  Future<RealtimeChannel> connect(
    Uri uri, {
    String? authToken,
    String? lastEventId,
  }) async {
    attempts += 1;
    lastTokenAttempted = authToken;
    if (_queue.isEmpty) {
      throw StateError('no scripted result for connect');
    }
    final shouldSucceed = _queue.removeAt(0);
    if (!shouldSucceed) {
      throw StateError('scripted connect failure');
    }
    final channel = _FakeChannel();
    activeChannel = channel;
    return channel;
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
}
