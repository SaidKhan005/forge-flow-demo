// Audit fix-first #2 (G1 + G2) — admin auth-session ledger + Active
// Sessions gateway tests.
//
// Pins:
//   * G2 HTTP gateway hits the SAME Phase 9 / 11A.1 self-service proxy
//     routes the operator-web + mobile clients use, with the bearer
//     token + a caller-stable Idempotency-Key on every state-changing
//     POST.
//   * recordSessionLogin sends `{token_hash}` and parses
//     `{session_id,user_id}`.
//   * revokeSession sends `{session_id,reason}` to
//     `/v1/auth/session/revoke`.
//   * signOutEverywhere calls `/v1/auth/session/revoke-all` AND
//     `/v1/auth/refresh-tokens/revoke-all` with the SAME idempotency
//     key (no G60 bug), and returns the revoked_count.
//   * listOwnSessions parses the `_authSessionSummaryToJson` row shape
//     and drops the raw IP.
//   * Proxy 4xx/5xx surfaces as AdminSessionsGatewayError.
//   * G1 fail-closed: a live ledger write failure on
//     FirebaseAdminAuthSource sign-in does NOT admit the session.
//   * Demo (null ledger) sign-in is a no-op and still admits.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/services/admin_sessions_gateway.dart';
import 'package:forge_and_flow/services/auth/firebase_auth_client.dart';

void main() {
  group('HttpAdminSessionsGateway', () {
    test('recordSessionLogin posts token_hash + parses the ledger record',
        () async {
      late http.Request captured;
      final client = http_testing.MockClient.streaming((request, _) async {
        captured = request as http.Request;
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(<String, Object?>{
            'session_id': 'sess-1',
            'user_id': 'user-1',
            'operator_id': '',
            'location_id': '',
          }))),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAdminSessionsGateway(
        baseUri: Uri.parse('https://admin-proxy.test'),
        bearerTokenProvider: () async => 'tok',
        httpClient: client,
      );

      final record = await gateway.recordSessionLogin(
        tokenHash: 'hash-abc',
        idempotencyKey: 'idem-login-1',
      );

      expect(captured.method, 'POST');
      expect(captured.url.path, '/v1/auth/session/login');
      expect(captured.headers['authorization'], 'Bearer tok');
      expect(captured.headers['Idempotency-Key'], 'idem-login-1');
      expect(
        jsonDecode(captured.body),
        <String, Object?>{'token_hash': 'hash-abc'},
      );
      expect(record.sessionId, 'sess-1');
      expect(record.userId, 'user-1');
    });

    test('revokeSession posts session_id + reason to the revoke route',
        () async {
      late http.Request captured;
      final client = http_testing.MockClient.streaming((request, _) async {
        captured = request as http.Request;
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(<String, Object?>{'ok': true}))),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAdminSessionsGateway(
        baseUri: Uri.parse('https://admin-proxy.test'),
        bearerTokenProvider: () async => 'tok',
        httpClient: client,
      );

      await gateway.revokeSession(
        sessionId: 'sess-9',
        reason: 'admin_signed_out_this_session',
        idempotencyKey: 'idem-rev-1',
      );

      expect(captured.url.path, '/v1/auth/session/revoke');
      expect(captured.headers['Idempotency-Key'], 'idem-rev-1');
      expect(jsonDecode(captured.body), <String, Object?>{
        'session_id': 'sess-9',
        'reason': 'admin_signed_out_this_session',
      });
    });

    test(
        'signOutEverywhere hits revoke-all AND refresh-tokens revoke-all with '
        'the SAME stable idempotency key', () async {
      final calls = <String, String>{}; // path -> idempotency key
      final client = http_testing.MockClient.streaming((request, _) async {
        calls[request.url.path] = request.headers['Idempotency-Key'] ?? '';
        final body = request.url.path.contains('session/revoke-all')
            ? jsonEncode(<String, Object?>{'ok': true, 'revoked_count': 3})
            : jsonEncode(<String, Object?>{'ok': true});
        return http.StreamedResponse(
          Stream.value(utf8.encode(body)),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAdminSessionsGateway(
        baseUri: Uri.parse('https://admin-proxy.test'),
        bearerTokenProvider: () async => 'tok',
        httpClient: client,
      );

      final revoked = await gateway.signOutEverywhere(
        reason: 'admin_signed_out_all_sessions',
        idempotencyKey: 'idem-all-1',
      );

      expect(revoked, 3);
      expect(calls['/v1/auth/session/revoke-all'], 'idem-all-1');
      expect(calls['/v1/auth/refresh-tokens/revoke-all'], 'idem-all-1',
          reason:
              'Both legs of sign-out-everywhere must carry the SAME caller-'
              'stable key so a retry replays the original 2xx (no G60 bug).');
    });

    test('listOwnSessions parses rows and drops the raw IP', () async {
      final client = http_testing.MockClient.streaming((request, _) async {
        expect(request.url.path, '/v1/auth/sessions');
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(<String, Object?>{
            'sessions': <Object?>[
              <String, Object?>{
                'session_id': 's1',
                'created_at': '2026-05-16T10:00:00Z',
                'last_seen_at': '2026-05-16T11:00:00Z',
                'device_label': 'Chrome on macOS',
                'geo_country': 'CA',
                'ip': '203.0.113.7',
              },
              <String, Object?>{
                'session_id': 's2',
                'created_at': '2026-05-15T10:00:00Z',
                'last_seen_at': '2026-05-15T12:00:00Z',
                'revoked_at': '2026-05-15T13:00:00Z',
              },
            ],
          }))),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAdminSessionsGateway(
        baseUri: Uri.parse('https://admin-proxy.test'),
        bearerTokenProvider: () async => 'tok',
        httpClient: client,
      );

      final sessions = await gateway.listOwnSessions();

      expect(sessions, hasLength(2));
      expect(sessions.first.sessionId, 's1');
      expect(sessions.first.deviceLabel, 'Chrome on macOS');
      expect(sessions.first.geoCountry, 'CA');
      expect(sessions.first.isActive, isTrue);
      expect(sessions[1].isActive, isFalse);
    });

    test('surfaces a proxy 503 as AdminSessionsGatewayError', () async {
      final client = http_testing.MockClient.streaming((request, _) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(<String, Object?>{
            'error': 'auth_session_ledger_unavailable',
            'message': 'auth session ledger is unavailable; please retry',
          }))),
          503,
          headers: <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = HttpAdminSessionsGateway(
        baseUri: Uri.parse('https://admin-proxy.test'),
        bearerTokenProvider: () async => 'tok',
        httpClient: client,
      );

      Object? caught;
      try {
        await gateway.recordSessionLogin(
          tokenHash: 'h',
          idempotencyKey: 'k',
        );
      } catch (error) {
        caught = error;
      }
      expect(caught, isA<AdminSessionsGatewayError>());
      final err = caught! as AdminSessionsGatewayError;
      expect(err.statusCode, 503);
      expect(err.errorCode, 'auth_session_ledger_unavailable');
    });
  });

  group('FirebaseAdminAuthSource ledger wiring (G1)', () {
    test('live admit records a session ledger row before authenticating',
        () async {
      final ledger = _RecordingSessionsGateway();
      final client = _FakeAuthClient(
        signIn: FirebaseAuthSignInSucceeded(_superAdminCredential()),
      );
      final source = FirebaseAdminAuthSource(
        client: client,
        sessionLedger: ledger,
      );
      addTearDown(source.dispose);
      await Future<void>.delayed(Duration.zero);

      await source.signInWithEmailPassword(
        email: 'admin@forgeflow.test',
        password: 'pw',
      );

      expect(source.current, isA<AdminAuthAuthenticated>());
      expect(ledger.loginCalls, 1,
          reason: 'A live admit must write exactly one ledger row.');
      expect(ledger.lastLoginIdempotencyKey, isNotEmpty);

      await source.signOut();
      expect(ledger.revokedSessionIds, <String>['sess-recorded']);
    });

    test('fail-closed: a ledger write failure does NOT admit the session',
        () async {
      final ledger = _RecordingSessionsGateway()..failLogin = true;
      final client = _FakeAuthClient(
        signIn: FirebaseAuthSignInSucceeded(_superAdminCredential()),
      );
      final source = FirebaseAdminAuthSource(
        client: client,
        sessionLedger: ledger,
      );
      addTearDown(source.dispose);
      await Future<void>.delayed(Duration.zero);

      await source.signInWithEmailPassword(
        email: 'admin@forgeflow.test',
        password: 'pw',
      );

      expect(source.current, isA<AdminAuthUnauthenticated>(),
          reason:
              'Live ledger failure must fail the sign-in closed — no '
              'unrecorded admin session.');
      expect(client.signOutCalls, 1,
          reason: 'Fail-closed path also drops the half-open Firebase '
              'session.');
    });

    test('demo (null ledger) sign-in is a no-op and still admits', () async {
      final client = _FakeAuthClient(
        signIn: FirebaseAuthSignInSucceeded(_superAdminCredential()),
      );
      final source = FirebaseAdminAuthSource(client: client);
      addTearDown(source.dispose);
      await Future<void>.delayed(Duration.zero);

      await source.signInWithEmailPassword(
        email: 'admin@forgeflow.test',
        password: 'pw',
      );

      expect(source.current, isA<AdminAuthAuthenticated>());
    });

    test('non-admin still fail-closes to forbidden, never reaches ledger',
        () async {
      final ledger = _RecordingSessionsGateway();
      final client = _FakeAuthClient(
        signIn: FirebaseAuthSignInSucceeded(_nonAdminCredential()),
      );
      final source = FirebaseAdminAuthSource(
        client: client,
        sessionLedger: ledger,
      );
      addTearDown(source.dispose);
      await Future<void>.delayed(Duration.zero);

      await source.signInWithEmailPassword(
        email: 'op@forgeflow.test',
        password: 'pw',
      );

      expect(source.current, isA<AdminAuthForbidden>());
      expect(ledger.loginCalls, 0,
          reason: 'The forbidden branch must never write a ledger row.');
    });
  });
}

class _RecordingSessionsGateway implements AdminSessionsGateway {
  bool failLogin = false;
  int loginCalls = 0;
  String lastLoginIdempotencyKey = '';
  final List<String> revokedSessionIds = <String>[];

  @override
  Future<AdminSessionLedgerRecord> recordSessionLogin({
    required String tokenHash,
    required String idempotencyKey,
  }) async {
    loginCalls += 1;
    lastLoginIdempotencyKey = idempotencyKey;
    if (failLogin) {
      throw const AdminSessionsGatewayError(
        statusCode: 503,
        errorCode: 'auth_session_ledger_unavailable',
        message: 'unavailable',
      );
    }
    return const AdminSessionLedgerRecord(
      sessionId: 'sess-recorded',
      userId: 'user-1',
    );
  }

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String reason,
    required String idempotencyKey,
  }) async {
    revokedSessionIds.add(sessionId);
  }

  @override
  Future<List<AdminSessionEntry>> listOwnSessions() async =>
      const <AdminSessionEntry>[];

  @override
  Future<int> signOutEverywhere({
    required String reason,
    required String idempotencyKey,
  }) async =>
      0;
}

class _FakeAuthClient implements FirebaseAuthClient {
  _FakeAuthClient({required this.signIn});

  final FirebaseAuthSignInOutcome signIn;
  int signOutCalls = 0;

  @override
  Future<FirebaseAuthSignInOutcome> signInWithEmailPassword({
    required String email,
    required String password,
  }) async =>
      signIn;

  @override
  Future<FirebaseAuthSignInOutcome> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async =>
      signIn;

  @override
  Future<void> requestPasswordReset({required String email}) async {}

  @override
  Future<FirebaseAuthCredential?> refreshIdToken() async => null;

  @override
  Future<String?> currentIdToken() async => 'id-token';

  @override
  Future<void> signOut() async {
    signOutCalls += 1;
  }

  @override
  Future<void> revokeAllRefreshTokens() async {}
}

FirebaseAuthCredential _superAdminCredential() {
  final now = DateTime.utc(2026, 5, 16, 12);
  return FirebaseAuthCredential(
    userId: 'firebase-admin',
    idToken: 'id-token',
    idTokenIssuedAt: now,
    idTokenExpiresAt: now.add(const Duration(hours: 1)),
    lastFreshAuthAt: now,
    email: 'admin@forgeflow.test',
    displayName: 'Admin',
    customClaims: const <String, Object?>{'is_super_admin': true},
  );
}

FirebaseAuthCredential _nonAdminCredential() {
  final now = DateTime.utc(2026, 5, 16, 12);
  return FirebaseAuthCredential(
    userId: 'firebase-op',
    idToken: 'id-token',
    idTokenIssuedAt: now,
    idTokenExpiresAt: now.add(const Duration(hours: 1)),
    lastFreshAuthAt: now,
    email: 'op@forgeflow.test',
    displayName: 'Operator',
    customClaims: const <String, Object?>{},
  );
}
