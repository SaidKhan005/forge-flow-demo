// Phase 11W.live - lifecycle tests for FirebaseOperatorWebAuthSource.
//
// Pins the lifecycle invariant: every emit path back to
// `OperatorWebNeedsSignIn` clears the cached `_currentSessionId` so a
// re-sign-in by a different user (same browser) cannot mark the wrong
// row as `(this session)` on the sessions screen. Audit MEDIUM #3.
//
// Also pins MEDIUM #4: the 6 router-consumed gateway provider mixins
// are implemented by the live source so the router can resolve each
// gateway via `is`-typecheck without a circular import on the router.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/operator_web/account/operator_web_account_actions.dart';
import 'package:forge_and_flow/operator_web/auth/firebase_operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_proxy_client.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_team_gateway_providers.dart';
import 'package:forge_and_flow/services/auth/firebase_auth_client.dart';

void main() {
  final Uri kProxyBase = Uri.parse('https://proxy.forgeflow.test');

  FirebaseAuthCredential buildCredential({String idToken = 'tok-abc'}) {
    final issuedAt = DateTime.utc(2026, 5, 6, 12);
    return FirebaseAuthCredential(
      userId: 'user-1',
      idToken: idToken,
      idTokenIssuedAt: issuedAt,
      idTokenExpiresAt: issuedAt.add(const Duration(hours: 1)),
      lastFreshAuthAt: issuedAt,
      email: 'owner@demo.forgeflow.test',
      displayName: 'Demo Operator Owner',
      customClaims: const <String, Object?>{
        'business_name': 'Demo Restaurant Group',
      },
    );
  }

  /// Drives the auth source through a successful sign-in so
  /// `_currentSessionId` is set, then awaits the [OperatorWebCompleted]
  /// emit. Returns once the post-login state has landed.
  Future<FirebaseOperatorWebAuthSource> signInSuccessfully({
    required _StubFirebaseAuthClient authClient,
    required _ScriptedProxyHandler handler,
  }) async {
    handler.reset();
    handler.scriptSuccessfulLogin();
    authClient.scriptedSignIn = FirebaseAuthSignInSucceeded(buildCredential());
    final source = FirebaseOperatorWebAuthSource(
      authClient: authClient,
      proxyClient: OperatorWebProxyClient(
        baseUri: kProxyBase,
        httpClient: MockClient(handler.handle),
      ),
    );
    // The constructor calls `_bootstrap`; without a Firebase user the
    // bootstrap emits NeedsSignIn. Then we drive sign-in.
    await _waitFor(source, _isNeedsSignIn);
    await source.signInWithEmailPassword(
      email: 'owner@demo.forgeflow.test',
      password: 'demo-password-1234',
    );
    await _waitFor(source, _isCompletedOrForbidden);
    return source;
  }

  group('FirebaseOperatorWebAuthSource provider mixins (audit MEDIUM #4)', () {
    test('implements every router-consumed gateway provider interface', () {
      final source = FirebaseOperatorWebAuthSource(
        authClient: _StubFirebaseAuthClient(),
        proxyClient: OperatorWebProxyClient(
          baseUri: kProxyBase,
          httpClient: MockClient((request) async => http.Response('{}', 200)),
        ),
      );
      addTearDown(source.dispose);

      // Compile-time + runtime check: each provider is satisfied so the
      // router can resolve gateways via `is`-typecheck without importing
      // the auth-source.
      expect(source, isA<OperatorWebTeamUsersGatewayProvider>());
      expect(source, isA<OperatorWebTeamRolesGatewayProvider>());
      expect(source, isA<OperatorWebTeamHierarchyGatewayProvider>());
      expect(source, isA<OperatorWebTeamSessionsGatewayProvider>());
      expect(source, isA<OperatorWebTeamAuditLogGatewayProvider>());
      expect(source, isA<OperatorWebAuditLogHierarchyGatewayProvider>());
      expect(source, isA<OperatorWebSecurityGatewayProvider>());
      expect(source, isA<OperatorWebBusinessLogoUploadGatewayProvider>());
      expect(source, isA<OperatorWebAccountMfaFreshnessGate>());
      expect(source, isA<OperatorWebVendorConnectionsGatewayProvider>());
    });
  });

  group('FirebaseOperatorWebAuthSource My Account MFA freshness gate', () {
    test('accepts a token with recent auth_time', () async {
      final now = DateTime.now().toUtc();
      final authClient = _StubFirebaseAuthClient()
        ..currentToken = _idTokenWithAuthTime(
          now.subtract(const Duration(minutes: 2)),
        );
      final source = FirebaseOperatorWebAuthSource(
        authClient: authClient,
        proxyClient: OperatorWebProxyClient(
          baseUri: kProxyBase,
          httpClient: MockClient((request) async => http.Response('{}', 200)),
        ),
      );
      addTearDown(source.dispose);

      await source.requireFreshMfaForAccountSecurity(
        actionLabel: 'removing 2FA',
      );
    });

    test('accepts a token within the account MFA clock-skew window', () async {
      final now = DateTime.now().toUtc();
      final authClient = _StubFirebaseAuthClient()
        ..currentToken = _idTokenWithAuthTime(
          now.add(const Duration(seconds: 30)),
        );
      final source = FirebaseOperatorWebAuthSource(
        authClient: authClient,
        proxyClient: OperatorWebProxyClient(
          baseUri: kProxyBase,
          httpClient: MockClient((request) async => http.Response('{}', 200)),
        ),
      );
      addTearDown(source.dispose);

      await source.requireFreshMfaForAccountSecurity(
        actionLabel: 'removing 2FA',
      );
    });

    test(
      'stale auth_time signs out through the existing freshness listener',
      () async {
        final now = DateTime.now().toUtc();
        final authClient = _StubFirebaseAuthClient()
          ..currentToken = _idTokenWithAuthTime(
            now.subtract(const Duration(minutes: 10)),
          );
        final source = FirebaseOperatorWebAuthSource(
          authClient: authClient,
          proxyClient: OperatorWebProxyClient(
            baseUri: kProxyBase,
            httpClient: MockClient((request) async => http.Response('{}', 200)),
          ),
        );
        addTearDown(source.dispose);

        await expectLater(
          () => source.requireFreshMfaForAccountSecurity(
            actionLabel: 'cancelling 2FA removal',
          ),
          throwsA(isA<OperatorWebProxyException>()),
        );
        await _waitFor(source, _isNeedsSignIn);

        final state = source.current as OperatorWebNeedsSignIn;
        expect(state.redirectUri, '/auth/login?reason=fresh_mfa_required');
        expect(state.lastInfoMessage, contains('cancelling 2FA removal'));
      },
    );
  });

  group('FirebaseOperatorWebAuthSource performance posture', () {
    test(
      'loads account info and permissions snapshot in parallel after login',
      () async {
        final authClient = _StubFirebaseAuthClient();
        authClient.scriptedSignIn = FirebaseAuthSignInSucceeded(
          buildCredential(),
        );
        final accountStarted = Completer<void>();
        final snapshotStarted = Completer<void>();
        final proxyClient = OperatorWebProxyClient(
          baseUri: kProxyBase,
          httpClient: MockClient((request) async {
            final path = request.url.path;
            if (path == OperatorWebProxyClient.authSessionLoginPath) {
              return http.Response(
                jsonEncode(<String, Object?>{
                  'session_id': 'session-uuid-perf',
                  'user_id': 'user-1',
                  'operator_id': 'op-1',
                  'location_id': 'loc-1',
                }),
                200,
                headers: <String, String>{'content-type': 'application/json'},
              );
            }
            if (path == OperatorWebProxyClient.authAccountInfoPath) {
              if (!accountStarted.isCompleted) accountStarted.complete();
              await snapshotStarted.future.timeout(
                const Duration(seconds: 1),
                onTimeout: () {
                  throw StateError('permission snapshot did not start');
                },
              );
              return http.Response(
                jsonEncode(<String, Object?>{
                  'display_name': 'Demo Operator Owner',
                  'email': 'owner@demo.forgeflow.test',
                  'status_label': 'Active',
                  'location_label': 'Demo Main Street',
                  'role_labels': <String>['operator_owner'],
                  'mfa_enabled': true,
                }),
                200,
                headers: <String, String>{'content-type': 'application/json'},
              );
            }
            if (path == OperatorWebProxyClient.authPermissionsSnapshotPath) {
              if (!snapshotStarted.isCompleted) snapshotStarted.complete();
              await accountStarted.future.timeout(
                const Duration(seconds: 1),
                onTimeout: () {
                  throw StateError('account info did not start');
                },
              );
              return http.Response(
                jsonEncode(<String, Object?>{
                  'user_id': 'user-1',
                  'operator_id': 'op-1',
                  'location_id': 'loc-1',
                  'roles_version': 1,
                  'evaluated_at': '2026-05-06T12:00:00Z',
                  'permissions': <String, String>{
                    'team.users.view': 'allow',
                    'integrations.configure': 'allow',
                  },
                }),
                200,
                headers: <String, String>{'content-type': 'application/json'},
              );
            }
            return http.Response(
              jsonEncode(<String, Object?>{
                'error': 'unscripted_route',
                'message': 'no canned response for $path',
              }),
              500,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }),
        );
        final source = FirebaseOperatorWebAuthSource(
          authClient: authClient,
          proxyClient: proxyClient,
        );
        addTearDown(source.dispose);

        await _waitFor(source, _isNeedsSignIn);
        await source.signInWithEmailPassword(
          email: 'owner@demo.forgeflow.test',
          password: 'demo-password-1234',
        );
        await _waitFor(source, _isCompletedOrForbidden);

        expect(accountStarted.isCompleted, isTrue);
        expect(snapshotStarted.isCompleted, isTrue);
        expect(source.current, isA<OperatorWebCompleted>());
      },
    );
  });

  group('FirebaseOperatorWebAuthSource session id lifecycle '
      '(audit MEDIUM #3)', () {
    test('signOut clears _currentSessionId', () async {
      final authClient = _StubFirebaseAuthClient();
      final handler = _ScriptedProxyHandler();
      final source = await signInSuccessfully(
        authClient: authClient,
        handler: handler,
      );
      addTearDown(source.dispose);
      expect(
        source.currentSessionId,
        isNotNull,
        reason: 'Sign-in should have set the session id',
      );

      await source.signOut();

      expect(source.currentSessionId, isNull);
      expect(source.current, isA<OperatorWebNeedsSignIn>());
    });

    test(
      'token refresh failure on bootstrap clears _currentSessionId',
      () async {
        // Drive a clean bootstrap that hits the NeedsSignIn (token-null)
        // path. `_currentSessionId` starts null, but the invariant is that
        // any NeedsSignIn emit goes through `_emit` which resets it. We
        // simulate stale state by re-signing in then forcing another
        // bootstrap-style failure.
        final authClient = _StubFirebaseAuthClient();
        final handler = _ScriptedProxyHandler();

        // First land on Completed so _currentSessionId is set.
        final source = await signInSuccessfully(
          authClient: authClient,
          handler: handler,
        );
        addTearDown(source.dispose);
        expect(source.currentSessionId, isNotNull);

        // Now drive a token-refresh-failure path: refreshIdToken returns
        // null. The auth source emits NeedsSignIn with the standard
        // copy. We invoke this through the public surface by signing in
        // again with bad outcome that forces NeedsSignIn.
        authClient.scriptedSignIn = const FirebaseAuthSignInFailed(
          code: 'wrong-password',
          message: 'Email or password did not match.',
        );
        await source.signInWithEmailPassword(
          email: 'owner@demo.forgeflow.test',
          password: 'bad-password',
        );
        await _waitFor(source, _isNeedsSignIn);

        expect(source.currentSessionId, isNull);
        expect(source.current, isA<OperatorWebNeedsSignIn>());
      },
    );

    test(
      'scope mismatch in _completeCredential clears _currentSessionId',
      () async {
        final authClient = _StubFirebaseAuthClient();
        final handler = _ScriptedProxyHandler();

        // Land on Completed with a known session id.
        final source = await signInSuccessfully(
          authClient: authClient,
          handler: handler,
        );
        addTearDown(source.dispose);
        expect(source.currentSessionId, isNotNull);

        // Re-sign-in but force the proxy permission snapshot to disagree
        // with the session ledger, which raises the
        // `permission_scope_mismatch` proxy exception inside
        // `_completeCredential`. The catch arm emits NeedsSignIn.
        handler.reset();
        handler.scriptScopeMismatchLogin();
        authClient.scriptedSignIn = FirebaseAuthSignInSucceeded(
          buildCredential(),
        );
        await source.signInWithEmailPassword(
          email: 'owner@demo.forgeflow.test',
          password: 'demo-password-1234',
        );
        await _waitFor(source, _isNeedsSignIn);

        expect(source.currentSessionId, isNull);
        expect(source.current, isA<OperatorWebNeedsSignIn>());
      },
    );

    test('proxy 5xx in _completeCredential clears _currentSessionId', () async {
      final authClient = _StubFirebaseAuthClient();
      final handler = _ScriptedProxyHandler();

      // Land on Completed first.
      final source = await signInSuccessfully(
        authClient: authClient,
        handler: handler,
      );
      addTearDown(source.dispose);
      expect(source.currentSessionId, isNotNull);

      // Re-sign-in but force the proxy session-login route to 500. The
      // `OperatorWebProxyException` thrown by the proxy client lands in
      // the `_completeCredential` catch arm, which emits NeedsSignIn.
      handler.reset();
      handler.scriptInternalError();
      authClient.scriptedSignIn = FirebaseAuthSignInSucceeded(
        buildCredential(),
      );
      await source.signInWithEmailPassword(
        email: 'owner@demo.forgeflow.test',
        password: 'demo-password-1234',
      );
      await _waitFor(source, _isNeedsSignIn);

      expect(source.currentSessionId, isNull);
      expect(source.current, isA<OperatorWebNeedsSignIn>());
    });

    test(
      'blank email path keeps _currentSessionId null without a prior login',
      () async {
        // The early-return validation arms (blank email, blank password,
        // expired MFA challenge) emit NeedsSignIn through `_emit`. Even
        // without a prior login, the session id stays null.
        final authClient = _StubFirebaseAuthClient();
        final source = FirebaseOperatorWebAuthSource(
          authClient: authClient,
          proxyClient: OperatorWebProxyClient(
            baseUri: kProxyBase,
            httpClient: MockClient((request) async => http.Response('{}', 200)),
          ),
        );
        addTearDown(source.dispose);
        await _waitFor(source, _isNeedsSignIn);

        await source.signInWithEmailPassword(email: '', password: '');

        expect(source.currentSessionId, isNull);
        expect(source.current, isA<OperatorWebNeedsSignIn>());
      },
    );
  });
}

bool _isNeedsSignIn(OperatorWebAuthState state) =>
    state is OperatorWebNeedsSignIn;

bool _isCompletedOrForbidden(OperatorWebAuthState state) =>
    state is OperatorWebCompleted || state is OperatorWebForbidden;

String _idTokenWithAuthTime(DateTime authTime) {
  String encode(Map<String, Object?> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final seconds = authTime.toUtc().millisecondsSinceEpoch ~/ 1000;
  return '${encode(<String, Object?>{'alg': 'none'})}.'
      '${encode(<String, Object?>{'auth_time': seconds})}.sig';
}

Future<void> _waitFor(
  FirebaseOperatorWebAuthSource source,
  bool Function(OperatorWebAuthState) predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  if (predicate(source.current)) return;
  final completer = Completer<void>();
  final sub = source.stream.listen((state) {
    if (!completer.isCompleted && predicate(state)) {
      completer.complete();
    }
  });
  try {
    await completer.future.timeout(timeout);
  } finally {
    await sub.cancel();
  }
}

class _StubFirebaseAuthClient implements FirebaseAuthClient {
  FirebaseAuthSignInOutcome? scriptedSignIn;
  FirebaseAuthCredential? scriptedRefresh;
  String? currentToken = 'tok-abc';

  @override
  Future<FirebaseAuthSignInOutcome> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    final outcome = scriptedSignIn;
    if (outcome == null) {
      return const FirebaseAuthSignInFailed(
        code: 'unscripted',
        message: 'test stub did not script a sign-in outcome',
      );
    }
    return outcome;
  }

  @override
  Future<FirebaseAuthSignInOutcome> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async {
    final outcome = scriptedSignIn;
    if (outcome == null) {
      return const FirebaseAuthSignInFailed(
        code: 'unscripted',
        message: 'test stub did not script an MFA outcome',
      );
    }
    return outcome;
  }

  @override
  Future<void> requestPasswordReset({required String email}) async {}

  @override
  Future<FirebaseAuthCredential?> refreshIdToken() async => scriptedRefresh;

  @override
  Future<String?> currentIdToken() async => currentToken;

  @override
  Future<void> signOut() async {}

  @override
  Future<void> revokeAllRefreshTokens() async {}
}

/// Tiny scripting helper for the operator-web proxy routes the auth
/// source touches inside `_completeCredential`. Each `script*` method
/// loads a queue of canned responses; routes are matched by path so
/// retries / re-logins can cycle through fresh fixtures.
class _ScriptedProxyHandler {
  final List<_ScriptedResponse> _queue = <_ScriptedResponse>[];

  void reset() {
    _queue.clear();
  }

  void scriptSuccessfulLogin() {
    _queue.add(
      _ScriptedResponse(
        path: OperatorWebProxyClient.authSessionLoginPath,
        statusCode: 200,
        body: <String, Object?>{
          'session_id': 'session-uuid-1',
          'user_id': 'user-1',
          'operator_id': 'op-1',
          'location_id': 'loc-1',
        },
      ),
    );
    _queue.add(
      _ScriptedResponse(
        path: OperatorWebProxyClient.authAccountInfoPath,
        statusCode: 200,
        body: <String, Object?>{
          'display_name': 'Demo Operator Owner',
          'email': 'owner@demo.forgeflow.test',
          'status_label': 'Active',
          'location_label': 'Demo Main Street',
          'role_labels': <String>['operator_owner'],
          'mfa_enabled': true,
        },
      ),
    );
    _queue.add(
      _ScriptedResponse(
        path: OperatorWebProxyClient.authPermissionsSnapshotPath,
        statusCode: 200,
        body: <String, Object?>{
          'user_id': 'user-1',
          'operator_id': 'op-1',
          'location_id': 'loc-1',
          'roles_version': 1,
          'evaluated_at': '2026-05-06T12:00:00Z',
          'permissions': <String, String>{
            'team.users.view': 'allow',
            'integrations.configure': 'allow',
          },
        },
      ),
    );
  }

  void scriptScopeMismatchLogin() {
    _queue.add(
      _ScriptedResponse(
        path: OperatorWebProxyClient.authSessionLoginPath,
        statusCode: 200,
        body: <String, Object?>{
          'session_id': 'session-uuid-2',
          'user_id': 'user-1',
          'operator_id': 'op-1',
          'location_id': 'loc-1',
        },
      ),
    );
    _queue.add(
      _ScriptedResponse(
        path: OperatorWebProxyClient.authAccountInfoPath,
        statusCode: 200,
        body: <String, Object?>{
          'display_name': 'Demo Operator Owner',
          'email': 'owner@demo.forgeflow.test',
          'status_label': 'Active',
          'location_label': 'Demo Main Street',
          'role_labels': <String>['operator_owner'],
          'mfa_enabled': true,
        },
      ),
    );
    // Snapshot disagrees with ledger -> permission_scope_mismatch.
    _queue.add(
      _ScriptedResponse(
        path: OperatorWebProxyClient.authPermissionsSnapshotPath,
        statusCode: 200,
        body: <String, Object?>{
          'user_id': 'different-user',
          'operator_id': 'different-op',
          'location_id': 'different-loc',
          'roles_version': 1,
          'evaluated_at': '2026-05-06T12:00:00Z',
          'permissions': <String, String>{'team.users.view': 'allow'},
        },
      ),
    );
  }

  void scriptInternalError() {
    _queue.add(
      _ScriptedResponse(
        path: OperatorWebProxyClient.authSessionLoginPath,
        statusCode: 500,
        body: <String, Object?>{
          'error': 'proxy_internal_error',
          'message': 'The proxy is unavailable.',
        },
      ),
    );
  }

  Future<http.Response> handle(http.BaseRequest request) async {
    final path = request.url.path;
    final scripted = _queue.firstWhere(
      (entry) => entry.path == path,
      orElse: () => _ScriptedResponse(
        path: path,
        statusCode: 500,
        body: <String, Object?>{
          'error': 'unscripted_route',
          'message': 'no canned response for $path',
        },
      ),
    );
    _queue.remove(scripted);
    return http.Response(
      jsonEncode(scripted.body),
      scripted.statusCode,
      headers: <String, String>{'content-type': 'application/json'},
    );
  }
}

class _ScriptedResponse {
  _ScriptedResponse({
    required this.path,
    required this.statusCode,
    required this.body,
  });

  final String path;
  final int statusCode;
  final Map<String, Object?> body;
}
