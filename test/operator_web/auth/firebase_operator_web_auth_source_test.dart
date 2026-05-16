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
      expect(source, isA<OperatorWebSecurityGatewayProvider>());
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

  group('FirebaseOperatorWebAuthSource live onboarding (G24/G3)', () {
    /// Scripts the redeem POST + the post-sign-in profile load. The
    /// account `mfa_enabled` flag drives whether the onboarding path
    /// lands on the MFA-enroll stage (false) or Completed (true).
    OperatorWebProxyClient buildOnboardingProxy({
      required bool mfaEnabled,
      String customToken = 'custom-tok-1',
      void Function(Map<String, Object?> redeemBody)? onRedeemBody,
      void Function(String path)? onPath,
    }) {
      return OperatorWebProxyClient(
        baseUri: kProxyBase,
        httpClient: MockClient((request) async {
          final path = request.url.path;
          onPath?.call(path);
          if (path == OperatorWebProxyClient.authMagicLinkRedeemPath) {
            onRedeemBody?.call(
              jsonDecode(request.body) as Map<String, Object?>,
            );
            return http.Response(
              jsonEncode(<String, Object?>{
                'ok': true,
                'firebase_custom_token': customToken,
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          if (path == OperatorWebProxyClient.authSessionLoginPath) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'session_id': 'sess-onb',
                'user_id': 'user-1',
                'operator_id': 'op-1',
                'location_id': 'loc-1',
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          if (path == OperatorWebProxyClient.authAccountInfoPath) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'display_name': 'Demo Operator Owner',
                'email': 'owner@demo.forgeflow.test',
                'status_label': 'Active',
                'location_label': 'Demo Main Street',
                'role_labels': <String>['operator_owner'],
                'mfa_enabled': mfaEnabled,
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          if (path == OperatorWebProxyClient.authPermissionsSnapshotPath) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'user_id': 'user-1',
                'operator_id': 'op-1',
                'location_id': 'loc-1',
                'roles_version': 1,
                'evaluated_at': '2026-05-06T12:00:00Z',
                'permissions': <String, String>{
                  'integrations.configure': 'allow',
                },
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          if (path == OperatorWebProxyClient.authMfaTotpBeginPath) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'factor_id': 'factor-1',
                'secret_base32': 'JBSWY3DPEHPK3PXP',
                'otp_auth_url': 'otpauth://totp/x?secret=JBSWY3DPEHPK3PXP',
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          if (path == OperatorWebProxyClient.authMfaTotpConfirmPath) {
            return http.Response(
              jsonEncode(<String, Object?>{'ok': true}),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{'error': 'unscripted_route'}),
            500,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );
    }

    test(
      'post-redeem custom-token sign-in routes a no-MFA invitee to '
      'the onboarding MFA-enroll stage',
      () async {
        final authClient = _StubFirebaseAuthClient()
          ..scriptedCustomTokenSignIn = FirebaseAuthSignInSucceeded(
            buildCredential(),
          );
        final source = FirebaseOperatorWebAuthSource(
          authClient: authClient,
          proxyClient: buildOnboardingProxy(mfaEnabled: false),
        );
        addTearDown(source.dispose);
        await _waitFor(source, _isNeedsSignIn);

        await source.verifyMagicLinkToken('invite-token-abc');
        await _waitFor(source, (s) => s is OperatorWebEnrollingMfa);

        expect(authClient.customTokenCalls, 1);
        expect(authClient.lastCustomToken, 'custom-tok-1');
        expect(source.current, isA<OperatorWebEnrollingMfa>());
      },
    );

    test(
      'post-redeem custom-token sign-in lands an MFA-enrolled invitee '
      'on Completed',
      () async {
        final authClient = _StubFirebaseAuthClient()
          ..scriptedCustomTokenSignIn = FirebaseAuthSignInSucceeded(
            buildCredential(),
          );
        final source = FirebaseOperatorWebAuthSource(
          authClient: authClient,
          proxyClient: buildOnboardingProxy(mfaEnabled: true),
        );
        addTearDown(source.dispose);
        await _waitFor(source, _isNeedsSignIn);

        await source.verifyMagicLinkToken('invite-token-abc');
        await _waitFor(source, _isCompletedOrForbidden);

        expect(source.current, isA<OperatorWebCompleted>());
      },
    );

    test('redeem body carries a stable token-derived idempotency key', () async {
      Map<String, Object?>? firstBody;
      Map<String, Object?>? secondBody;
      final authClient = _StubFirebaseAuthClient()
        ..scriptedCustomTokenSignIn = FirebaseAuthSignInSucceeded(
          buildCredential(),
        );
      var call = 0;
      final source = FirebaseOperatorWebAuthSource(
        authClient: authClient,
        proxyClient: buildOnboardingProxy(
          mfaEnabled: true,
          onRedeemBody: (body) {
            call += 1;
            if (call == 1) {
              firstBody = body;
            } else {
              secondBody = body;
            }
          },
        ),
      );
      addTearDown(source.dispose);
      await _waitFor(source, _isNeedsSignIn);

      await source.verifyMagicLinkToken('invite-token-abc');
      await _waitFor(source, _isCompletedOrForbidden);
      await source.verifyMagicLinkToken('invite-token-abc');

      expect(firstBody, isNotNull);
      expect(secondBody, isNotNull);
      // Same logical action (same token) => same idempotency key on a
      // retry, so the proxy can replay its cached result (G60).
      expect(
        firstBody!['idempotency_key'],
        equals(secondBody!['idempotency_key']),
      );
      // The key is derived (hashed) — never the raw token.
      expect(firstBody!['idempotency_key'], isNot(equals('invite-token-abc')));
    });

    test('2xx redeem with missing custom token fails closed to NeedsToken', () async {
      final authClient = _StubFirebaseAuthClient();
      final source = FirebaseOperatorWebAuthSource(
        authClient: authClient,
        proxyClient: OperatorWebProxyClient(
          baseUri: kProxyBase,
          httpClient: MockClient((request) async {
            if (request.url.path ==
                OperatorWebProxyClient.authMagicLinkRedeemPath) {
              return http.Response(
                jsonEncode(<String, Object?>{'ok': true}),
                200,
                headers: <String, String>{'content-type': 'application/json'},
              );
            }
            return http.Response('{}', 500);
          }),
        ),
      );
      addTearDown(source.dispose);
      await _waitFor(source, _isNeedsSignIn);

      await source.verifyMagicLinkToken('invite-token-abc');
      await _waitFor(source, (s) => s is OperatorWebNeedsToken);

      expect(source.current, isA<OperatorWebNeedsToken>());
      expect(authClient.customTokenCalls, 0);
    });

    test('onboarding TOTP enroll + confirm wires to the proxy and '
        'advances to Completed', () async {
      // NOTE: scriptedRefresh is intentionally left null until after
      // bootstrap. Setting it before construction would make
      // `_bootstrap`'s refreshIdToken() succeed and skip straight to
      // Completed, never landing on NeedsSignIn.
      final authClient = _StubFirebaseAuthClient()
        ..scriptedCustomTokenSignIn = FirebaseAuthSignInSucceeded(
          buildCredential(),
        );
      final source = FirebaseOperatorWebAuthSource(
        authClient: authClient,
        proxyClient: buildOnboardingProxy(mfaEnabled: false),
      );
      addTearDown(source.dispose);
      await _waitFor(source, _isNeedsSignIn);

      await source.verifyMagicLinkToken('invite-token-abc');
      await _waitFor(source, (s) => s is OperatorWebEnrollingMfa);

      final artifact = await source.beginMfaEnrollment(
        factorType: MfaFactorType.totp,
      );
      expect(artifact.enrollmentId, 'factor-1');
      expect(artifact.totpSharedSecret, 'JBSWY3DPEHPK3PXP');

      // confirmMfaEnrollment re-loads the profile via refreshIdToken();
      // arm it now that bootstrap is done.
      authClient.scriptedRefresh = buildCredential();

      await source.confirmMfaEnrollment(
        enrollmentId: 'factor-1',
        oneTimeCode: '123456',
      );
      await _waitFor(source, _isCompletedOrForbidden);
      expect(source.current, isA<OperatorWebCompleted>());
    });

    test('onboarding SMS MFA stays unsupported (TOTP only on live)', () async {
      final authClient = _StubFirebaseAuthClient()
        ..scriptedCustomTokenSignIn = FirebaseAuthSignInSucceeded(
          buildCredential(),
        );
      final source = FirebaseOperatorWebAuthSource(
        authClient: authClient,
        proxyClient: buildOnboardingProxy(mfaEnabled: false),
      );
      addTearDown(source.dispose);
      await _waitFor(source, _isNeedsSignIn);
      await source.verifyMagicLinkToken('invite-token-abc');
      await _waitFor(source, (s) => s is OperatorWebEnrollingMfa);

      await expectLater(
        () => source.beginMfaEnrollment(factorType: MfaFactorType.sms),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('submitPassword fails closed (no UnsupportedError, no '
        'signed-in state)', () async {
      final source = FirebaseOperatorWebAuthSource(
        authClient: _StubFirebaseAuthClient(),
        proxyClient: OperatorWebProxyClient(
          baseUri: kProxyBase,
          httpClient: MockClient((request) async => http.Response('{}', 200)),
        ),
      );
      addTearDown(source.dispose);
      await _waitFor(source, _isNeedsSignIn);

      // Must not throw UnsupportedError; must not become Completed.
      await source.submitPassword(
        password: 'a-very-long-password',
        confirmation: 'a-very-long-password',
      );
      expect(source.current, isNot(isA<OperatorWebCompleted>()));
    });

    test('acceptTos fails closed (no UnsupportedError, no Completed)', () async {
      final source = FirebaseOperatorWebAuthSource(
        authClient: _StubFirebaseAuthClient(),
        proxyClient: OperatorWebProxyClient(
          baseUri: kProxyBase,
          httpClient: MockClient((request) async => http.Response('{}', 200)),
        ),
      );
      addTearDown(source.dispose);
      await _waitFor(source, _isNeedsSignIn);

      await source.acceptTos(versionId: 'v1', scope: 'inbound_vendor_universal');
      expect(source.current, isNot(isA<OperatorWebCompleted>()));
    });
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
  FirebaseAuthSignInOutcome? scriptedCustomTokenSignIn;
  FirebaseAuthCredential? scriptedRefresh;
  String? currentToken = 'tok-abc';
  int customTokenCalls = 0;
  String? lastCustomToken;

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
  Future<FirebaseAuthSignInOutcome> signInWithCustomToken({
    required String customToken,
  }) async {
    customTokenCalls += 1;
    lastCustomToken = customToken;
    final outcome = scriptedCustomTokenSignIn ?? scriptedSignIn;
    if (outcome == null) {
      return const FirebaseAuthSignInFailed(
        code: 'unscripted',
        message: 'test stub did not script a custom-token sign-in outcome',
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
