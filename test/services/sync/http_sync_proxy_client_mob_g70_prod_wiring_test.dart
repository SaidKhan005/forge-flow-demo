// MOB-G70 — production sync-client auth-resilience wiring.
//
// Before the fix, the production `HttpSyncProxyClient` was constructed
// in `lib/main_forgeflow.dart` WITHOUT the `refreshIdToken` argument,
// so the 401-refresh-and-retry already implemented in
// `http_sync_proxy_client.dart` (`_getJson` / `_postJson`) was dead in
// the prod flavor. A clock-skew / mid-rotation 401 hard-failed
// operational sync with no recovery. (This corrects the cross-surface
// register's G61 "mobile auto-recovers" claim, which was aspirational
// for the prod flavor until this wiring landed.)
//
// `firebase_auth_runtime_bindings.dart` now exposes `forceRefreshIdToken`
// bound to `FirebaseAuthClient.refreshIdToken` (SDK
// `getIdTokenResult(forceRefresh: true)`), and `main_forgeflow.dart`
// threads it into the prod `HttpSyncProxyClient`.
//
// These tests pin the BINDINGS-TO-SYNC-CLIENT CONTRACT exactly as the
// bootstrap now wires it:
//
//   idTokenProvider : authClient.currentIdToken      (cached — cheap)
//   refreshIdToken  : () async {                      (FORCE refresh)
//                       await authClient.refreshIdToken();
//                     }
//
// and assert:
//   1. a 401 triggers exactly one force-refresh + one retry, then
//      succeeds — and the retry uses the FORCE-refreshed token, not
//      the still-stale cached token;
//   2. a persistent 401 exhausts after exactly one retry.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:forge_and_flow/services/auth/firebase_auth_client.dart';
import 'package:forge_and_flow/services/sync/http_sync_proxy_client.dart';

void main() {
  test(
    'prod-wired client recovers a 401 via the bindings force-refresh hook',
    () async {
      final authClient = _FakeFirebaseAuthClient(
        // The CACHED token never changes (mirrors the SDK's cached
        // `getIdToken()` which does NOT force-refresh). Only a FORCE
        // refresh rotates the live token. If the sync client used the
        // cached provider on the retry it would re-send the stale
        // token and loop — proving the force-refresh path matters.
        cachedToken: 'stale-cached-token',
        forcedToken: 'fresh-forced-token',
      );
      final requestTokens = <String>[];
      final client = HttpSyncProxyClient(
        proxyBaseUri: Uri.parse('https://proxy.example'),
        // EXACT bindings wiring shape:
        idTokenProvider: authClient.currentIdToken,
        refreshIdToken: () async {
          await authClient.refreshIdToken();
        },
        httpClient: http_testing.MockClient((request) async {
          requestTokens.add(request.headers['authorization'] ?? '');
          if (requestTokens.length == 1) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'error': 'unauthorized',
                'message': 'token expired',
              }),
              401,
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'records': const <Object?>[],
              'next_cursor': null,
            }),
            200,
          );
        }),
      );

      final page = await client.fetchShiftRecords(
        operatorId: 'op',
        locationId: 'loc',
        cursor: null,
        pageSize: 10,
      );

      expect(
        authClient.forceRefreshCount,
        1,
        reason: 'the bindings hook force-refreshes exactly once on 401',
      );
      expect(
        requestTokens,
        <String>['Bearer stale-cached-token', 'Bearer fresh-forced-token'],
        reason:
            'the retry must carry the FORCE-refreshed token, not the '
            'still-stale cached token',
      );
      expect(page.records, isEmpty);
    },
  );

  test(
    'prod-wired client exhausts correctly on a persistent 401',
    () async {
      final authClient = _FakeFirebaseAuthClient(
        cachedToken: 'still-stale',
        forcedToken: 'still-stale-after-refresh',
      );
      var requestCount = 0;
      final client = HttpSyncProxyClient(
        proxyBaseUri: Uri.parse('https://proxy.example'),
        idTokenProvider: authClient.currentIdToken,
        refreshIdToken: () async {
          await authClient.refreshIdToken();
        },
        httpClient: http_testing.MockClient((_) async {
          requestCount++;
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': 'unauthorized',
              'message': 'token expired',
            }),
            401,
          );
        }),
      );

      await expectLater(
        client.fetchShiftRecords(
          operatorId: 'op',
          locationId: 'loc',
          cursor: null,
          pageSize: 10,
        ),
        throwsA(
          isA<SyncProxyClientException>().having(
            (error) => error.statusCode,
            'statusCode',
            401,
          ),
        ),
      );
      expect(
        requestCount,
        2,
        reason: 'one initial + exactly one retry, then surface the 401',
      );
      expect(authClient.forceRefreshCount, 1);
    },
  );
}

/// Minimal [FirebaseAuthClient] fake that models the two distinct
/// token paths the bindings rely on:
///   * [currentIdToken] returns the CACHED token (never rotates),
///   * [refreshIdToken] FORCE-refreshes and rotates the live token.
class _FakeFirebaseAuthClient implements FirebaseAuthClient {
  _FakeFirebaseAuthClient({
    required String cachedToken,
    required this.forcedToken,
  }) : _liveToken = cachedToken;

  final String forcedToken;
  String _liveToken;
  int forceRefreshCount = 0;

  @override
  Future<String?> currentIdToken() async => _liveToken;

  @override
  Future<FirebaseAuthCredential?> refreshIdToken() async {
    forceRefreshCount++;
    _liveToken = forcedToken;
    return FirebaseAuthCredential(
      userId: 'user-1',
      idToken: _liveToken,
      idTokenIssuedAt: DateTime.utc(2026, 5, 16),
      idTokenExpiresAt: DateTime.utc(2026, 5, 16, 1),
      lastFreshAuthAt: DateTime.utc(2026, 5, 16),
    );
  }

  @override
  Future<FirebaseAuthSignInOutcome> signInWithEmailPassword({
    required String email,
    required String password,
  }) =>
      throw UnimplementedError();

  @override
  Future<FirebaseAuthSignInOutcome> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> requestPasswordReset({required String email}) =>
      throw UnimplementedError();

  @override
  Future<void> signOut() => throw UnimplementedError();

  @override
  Future<void> revokeAllRefreshTokens() => throw UnimplementedError();
}
