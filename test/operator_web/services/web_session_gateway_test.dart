// Phase 11W.0 / Wave A1 - WebSessionGateway lifecycle tests.
//
// Pins the contract described in
// `lib/operator_web/services/web_session_gateway.dart`: every
// session-lifecycle entry point (refresh on a missing/expired
// token, sign-out, force-logout-this-session, scope mismatch) drops
// to `OperatorWebNeedsSignIn`.
//
// Uses a fake `OperatorWebAuthSource` so we can observe the emitted
// states without spinning up Firebase. The fake mirrors the
// lifecycle invariant from
// `lib/operator_web/auth/firebase_operator_web_auth_source.dart`:
// signOut() clears `currentSessionId` and emits
// `OperatorWebNeedsSignIn` through a single funnel.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/services/web_session_gateway.dart';

void main() {
  group('OperatorWebSessionGateway lifecycle', () {
    test(
      'signOut drops the auth source to OperatorWebNeedsSignIn and clears '
      'currentSessionId',
      () async {
        final source = _LifecycleFakeSource(initialSessionId: 'session-A');
        addTearDown(source.dispose);
        final gateway = OperatorWebSessionGateway(source: source);

        await gateway.signOut();

        expect(source.current, isA<OperatorWebNeedsSignIn>());
        expect(source.currentSessionId, isNull);
      },
    );

    test(
      'forceLogoutCurrentSession funnels through signOut so '
      '`(this session)` rows cannot survive into a re-auth',
      () async {
        final source = _LifecycleFakeSource(initialSessionId: 'session-B');
        addTearDown(source.dispose);
        final gateway = OperatorWebSessionGateway(source: source);

        await gateway.forceLogoutCurrentSession();

        expect(source.current, isA<OperatorWebNeedsSignIn>());
        expect(source.currentSessionId, isNull);
        expect(source.signOutCalls, 1);
      },
    );

    test(
      'refresh with a null id token emits NeedsSignIn cleanly (token '
      'expired or revoked)',
      () async {
        final source = _LifecycleFakeSource(initialSessionId: 'session-C');
        addTearDown(source.dispose);
        final gateway = OperatorWebSessionGateway(
          source: source,
          idTokenProvider: () async => null,
        );

        await gateway.refresh();

        expect(source.current, isA<OperatorWebNeedsSignIn>());
        expect(source.currentSessionId, isNull);
      },
    );

    test(
      'refresh with a thrown id-token provider also emits NeedsSignIn '
      '(network outage / SDK error)',
      () async {
        final source = _LifecycleFakeSource(initialSessionId: 'session-D');
        addTearDown(source.dispose);
        final gateway = OperatorWebSessionGateway(
          source: source,
          idTokenProvider: () async => throw StateError('id-token outage'),
        );

        await gateway.refresh();

        expect(source.current, isA<OperatorWebNeedsSignIn>());
        expect(source.currentSessionId, isNull);
      },
    );

    test(
      'refresh keeps the session when the id-token provider returns a '
      'valid token (no NeedsSignIn flush)',
      () async {
        final source = _LifecycleFakeSource(initialSessionId: 'session-E');
        addTearDown(source.dispose);
        final gateway = OperatorWebSessionGateway(
          source: source,
          idTokenProvider: () async => 'fresh-id-token',
        );

        await gateway.refresh();

        expect(source.current, isA<OperatorWebCompleted>());
        expect(source.currentSessionId, 'session-E');
        expect(source.signOutCalls, 0);
      },
    );

    test(
      'refresh in demo mode (no idTokenProvider) is a no-op; the demo '
      'source keeps driving the stage machine itself',
      () async {
        final source = _LifecycleFakeSource(initialSessionId: 'demo-session');
        addTearDown(source.dispose);
        final gateway = OperatorWebSessionGateway(source: source);

        await gateway.refresh();

        expect(source.current, isA<OperatorWebCompleted>());
        expect(source.currentSessionId, 'demo-session');
        expect(source.signOutCalls, 0);
      },
    );

    test(
      'handleScopeMismatch drops to NeedsSignIn so the operator can '
      're-authenticate with the correct operator/location scope',
      () async {
        final source = _LifecycleFakeSource(
          initialSessionId: 'wrong-scope-session',
        );
        addTearDown(source.dispose);
        final gateway = OperatorWebSessionGateway(source: source);

        await gateway.handleScopeMismatch();

        expect(source.current, isA<OperatorWebNeedsSignIn>());
        expect(source.currentSessionId, isNull);
      },
    );
  });
}

/// Fake auth source that mirrors the lifecycle invariant in
/// `FirebaseOperatorWebAuthSource._emit`: every transition to
/// [OperatorWebNeedsSignIn] clears `currentSessionId`. The fake
/// counts `signOut` invocations so tests can assert that lifecycle
/// methods funnel through the documented exit point. Seeded with
/// `OperatorWebCompleted` + `kDemoOperatorWebSession` so tests can
/// assert post-onboarding starting state without subclassing the
/// sealed `OperatorWebAuthState` family.
class _LifecycleFakeSource extends OperatorWebAuthSource {
  _LifecycleFakeSource({required String initialSessionId})
      : _state = const OperatorWebCompleted(session: kDemoOperatorWebSession),
        _currentSessionId = initialSessionId {
    _controller.add(_state);
  }

  final StreamController<OperatorWebAuthState> _controller =
      StreamController<OperatorWebAuthState>.broadcast();
  OperatorWebAuthState _state;
  String? _currentSessionId;
  int signOutCalls = 0;

  String? get currentSessionId => _currentSessionId;

  @override
  Stream<OperatorWebAuthState> get stream => _controller.stream;

  @override
  OperatorWebAuthState get current => _state;

  @override
  Future<void> signOut() async {
    signOutCalls += 1;
    _emit(const OperatorWebNeedsSignIn());
  }

  void _emit(OperatorWebAuthState next) {
    if (next is OperatorWebNeedsSignIn) {
      _currentSessionId = null;
    }
    _state = next;
    _controller.add(next);
  }

  @override
  void dispose() {
    _controller.close();
  }
}
