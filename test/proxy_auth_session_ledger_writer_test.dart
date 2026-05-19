// Phase 9 live-closeout B6 — ProxyAuthSessionLedgerWriter unit tests.
//
// Coverage matrix:
//   * `recordLogin`: builds the right URL + headers (Authorization
//     bearer + Idempotency-Key + JSON content-type), body carries
//     only `token_hash`, returns the proxy's `session_id`.
//   * `recordRefresh` / `revokeSession` / `revokeAllSessionsForUser`:
//     correct URLs, body shape, parses `revoked_count`.
//   * Failure surfaces: non-200 maps to ProxyAuthSessionLedgerError
//     with the proxy's error code; transport failures map to
//     `transport_error`; missing ID token maps to `no_id_token`.
//   * Backwards-compat sanity: writer's path constants must exactly
//     match the proxy route constants exported from
//     advisor_proxy.dart so the wire contract stays in sync.
//   * No live HTTP — every test injects an in-memory
//     ProxyHttpJsonClient fake.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/proxy_auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/proxy_refresh_token_revoker.dart';

import '../tool/advisor_proxy/advisor_proxy.dart' as proxy;

void main() {
  final baseUri = Uri.parse('https://forge-flow-proxy.example.com');

  group('ProxyAuthSessionLedgerWriter — recordLogin', () {
    test(
      'POSTs token_hash to /v1/auth/session/login with Authorization '
      'bearer + Idempotency-Key, returns session_id from the response',
      () async {
        final fake = _FakeProxyHttpJsonClient(
          respondWith: const ProxyHttpJsonResponse(
            statusCode: 200,
            body: <String, Object?>{
              'session_id': 'session-from-proxy',
              'user_id': 'u',
              'operator_id': 'op',
              'location_id': 'loc',
            },
          ),
        );
        final writer = ProxyAuthSessionLedgerWriter(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'live-id-token',
          httpClient: fake,
          idempotencyKeyFactory: () => 'idempotency-test-1',
        );

        final id = await writer.recordLogin(
          const AuthSessionLedgerLogin(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            tokenHash: 'sha256-hex-hash',
          ),
        );
        expect(id, equals('session-from-proxy'));

        final call = fake.calls.single;
        // Acceptance: URL targets the documented proxy route.
        expect(
          call.url.toString(),
          equals('https://forge-flow-proxy.example.com/v1/auth/session/login'),
        );
        // Acceptance: Authorization carries the live ID token; the
        // raw token never appears in any other header / body field.
        // Header key matches the dart:io HttpHeaders constant
        // (`authorization` — lowercase by HTTP/2 convention).
        expect(
          call.headers[HttpHeaders.authorizationHeader],
          equals('Bearer live-id-token'),
        );
        expect(call.headers['Idempotency-Key'], equals('idempotency-test-1'));
        // Acceptance: body carries only `token_hash`; audit enrichment
        // is owned by the proxy and its configured ingress trust mode.
        expect(call.body.keys, equals(<String>{'token_hash'}));
        expect(call.body['token_hash'], equals('sha256-hex-hash'));
      },
    );

    test('recordLoginAndResolveScope returns canonical proxy scope when '
        'the local user id is still the Firebase UID', () async {
      final fake = _FakeProxyHttpJsonClient(
        respondWith: const ProxyHttpJsonResponse(
          statusCode: 200,
          body: <String, Object?>{
            'session_id': 'session-from-proxy',
            'user_id': 'postgres-user-id',
            'operator_id': 'op',
            'location_id': 'loc',
          },
        ),
      );
      final writer = ProxyAuthSessionLedgerWriter(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'live-id-token',
        httpClient: fake,
      );

      final record = await writer.recordLoginAndResolveScope(
        const AuthSessionLedgerLogin(
          userId: 'firebase-uid',
          operatorId: 'op',
          locationId: 'loc',
          tokenHash: 'sha256-hex-hash',
        ),
      );

      expect(record.sessionId, equals('session-from-proxy'));
      expect(record.userId, equals('postgres-user-id'));
      expect(record.operatorId, equals('op'));
      expect(record.locationId, equals('loc'));
    });

    test('non-200 response maps to ProxyAuthSessionLedgerError with the '
        "proxy's error code + status code", () async {
      final fake = _FakeProxyHttpJsonClient(
        respondWith: const ProxyHttpJsonResponse(
          statusCode: 503,
          body: <String, Object?>{
            'error': 'auth_session_ledger_unavailable',
            'message': 'auth session ledger is unavailable; please retry',
          },
        ),
      );
      final writer = ProxyAuthSessionLedgerWriter(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'token',
        httpClient: fake,
      );

      Object? thrown;
      try {
        await writer.recordLogin(
          const AuthSessionLedgerLogin(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            tokenHash: 'h',
          ),
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ProxyAuthSessionLedgerError>());
      final error = thrown! as ProxyAuthSessionLedgerError;
      expect(error.code, equals('auth_session_ledger_unavailable'));
      expect(error.statusCode, equals(503));
    });

    test('200 with malformed body (no session_id) maps to '
        'malformed_response error', () async {
      final fake = _FakeProxyHttpJsonClient(
        respondWith: const ProxyHttpJsonResponse(
          statusCode: 200,
          body: <String, Object?>{'wrong': 'shape'},
        ),
      );
      final writer = ProxyAuthSessionLedgerWriter(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'token',
        httpClient: fake,
      );

      Object? thrown;
      try {
        await writer.recordLogin(
          const AuthSessionLedgerLogin(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            tokenHash: 'h',
          ),
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ProxyAuthSessionLedgerError>());
      expect(
        (thrown! as ProxyAuthSessionLedgerError).code,
        equals('malformed_response'),
      );
    });

    test('200 with missing scope echo maps to malformed_response', () async {
      final fake = _FakeProxyHttpJsonClient(
        respondWith: const ProxyHttpJsonResponse(
          statusCode: 200,
          body: <String, Object?>{'session_id': 'session-from-proxy'},
        ),
      );
      final writer = ProxyAuthSessionLedgerWriter(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'token',
        httpClient: fake,
      );

      Object? thrown;
      try {
        await writer.recordLogin(
          const AuthSessionLedgerLogin(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            tokenHash: 'h',
          ),
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ProxyAuthSessionLedgerError>());
      final error = thrown! as ProxyAuthSessionLedgerError;
      expect(error.code, equals('malformed_response'));
      expect(error.message.contains('session-from-proxy'), isFalse);
    });

    // B1 follow-up — global-admin (ff_support / super_admin) sign-in
    // contract: proxy returns 200 with empty-string `operator_id` /
    // `location_id` for these identities. The parser MUST accept that
    // shape for global admins and MUST still reject it for everyone
    // else. See `docs/archive/_audits/post_codex_wave/pr_476_b1_b2_audit.md`
    // §1.
    test(
      'ff_support: 200 with empty operator/location echo is accepted '
      'and surfaces a record with empty scope',
      () async {
        final fake = _FakeProxyHttpJsonClient(
          respondWith: const ProxyHttpJsonResponse(
            statusCode: 200,
            body: <String, Object?>{
              'session_id': 'session-from-proxy',
              'user_id': 'support-user-id',
              // Proxy contract for global admins: empty strings, not
              // null — the keys are still present so the client can
              // sanity-check the shape, but the values are empty.
              'operator_id': '',
              'location_id': '',
            },
          ),
        );
        final writer = ProxyAuthSessionLedgerWriter(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'token',
          httpClient: fake,
        );

        final record = await writer.recordLoginAndResolveScope(
          const AuthSessionLedgerLogin(
            userId: 'support-user-id',
            // Local AuthSession for a global admin also has empty
            // scope because the verified JWT carried no tenant claim.
            operatorId: '',
            locationId: '',
            tokenHash: 'h',
            roles: <String>['ff_support'],
          ),
        );

        expect(record.sessionId, equals('session-from-proxy'));
        expect(record.userId, equals('support-user-id'));
        expect(record.operatorId, equals(''));
        expect(record.locationId, equals(''));
      },
    );

    test(
      'super_admin: 200 with empty operator/location echo is accepted '
      'and surfaces a record with empty scope',
      () async {
        final fake = _FakeProxyHttpJsonClient(
          respondWith: const ProxyHttpJsonResponse(
            statusCode: 200,
            body: <String, Object?>{
              'session_id': 'session-from-proxy',
              'user_id': 'admin-user-id',
              'operator_id': '',
              'location_id': '',
            },
          ),
        );
        final writer = ProxyAuthSessionLedgerWriter(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'token',
          httpClient: fake,
        );

        // recordLogin also exercises `_validateLoginScopeEcho`, so
        // running it through the higher-level API covers both
        // role-aware code paths.
        final sessionId = await writer.recordLogin(
          const AuthSessionLedgerLogin(
            userId: 'admin-user-id',
            operatorId: '',
            locationId: '',
            tokenHash: 'h',
            roles: <String>['super_admin'],
          ),
        );
        expect(sessionId, equals('session-from-proxy'));
      },
    );

    test(
      'normal user: 200 with empty operator/location echo still maps '
      'to malformed_response (regression protection)',
      () async {
        final fake = _FakeProxyHttpJsonClient(
          respondWith: const ProxyHttpJsonResponse(
            statusCode: 200,
            body: <String, Object?>{
              'session_id': 'session-from-proxy',
              'user_id': 'normal-user-id',
              'operator_id': '',
              'location_id': '',
            },
          ),
        );
        final writer = ProxyAuthSessionLedgerWriter(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'token',
          httpClient: fake,
        );

        Object? thrown;
        try {
          await writer.recordLogin(
            const AuthSessionLedgerLogin(
              userId: 'normal-user-id',
              operatorId: 'op',
              locationId: 'loc',
              tokenHash: 'h',
              // Empty roles -> strict tenant-scoped contract applies.
              // Even if a normal user's claims include unrelated
              // role markers (e.g. `advisor.read`), the parser only
              // tolerates the empty-scope shape when the role set
              // contains `ff_support` or `super_admin`.
              roles: <String>['advisor.read'],
            ),
          );
        } catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ProxyAuthSessionLedgerError>());
        final error = thrown! as ProxyAuthSessionLedgerError;
        expect(error.code, equals('malformed_response'));
        expect(
          error.message,
          contains('incomplete scope'),
        );
      },
    );

    test(
      'ff_support: 200 with NON-empty operator/location echo still '
      'parses cleanly (no regression to the normal tenant-scoped path)',
      () async {
        // A global admin who has explicitly impersonated a tenant
        // could legitimately receive a populated echo. The carve-out
        // widens "what we accept", it does not narrow it.
        final fake = _FakeProxyHttpJsonClient(
          respondWith: const ProxyHttpJsonResponse(
            statusCode: 200,
            body: <String, Object?>{
              'session_id': 'session-from-proxy',
              'user_id': 'support-user-id',
              'operator_id': 'op',
              'location_id': 'loc',
            },
          ),
        );
        final writer = ProxyAuthSessionLedgerWriter(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'token',
          httpClient: fake,
        );

        final record = await writer.recordLoginAndResolveScope(
          const AuthSessionLedgerLogin(
            userId: 'support-user-id',
            operatorId: 'op',
            locationId: 'loc',
            tokenHash: 'h',
            roles: <String>['ff_support'],
          ),
        );

        expect(record.sessionId, equals('session-from-proxy'));
        expect(record.operatorId, equals('op'));
        expect(record.locationId, equals('loc'));
      },
    );

    test('200 with mismatched scope echo maps to scope_mismatch', () async {
      final fake = _FakeProxyHttpJsonClient(
        respondWith: const ProxyHttpJsonResponse(
          statusCode: 200,
          body: <String, Object?>{
            'session_id': 'session-from-proxy',
            'user_id': 'DIFFERENT',
            'operator_id': 'op',
            'location_id': 'loc',
          },
        ),
      );
      final writer = ProxyAuthSessionLedgerWriter(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'token',
        httpClient: fake,
      );

      Object? thrown;
      try {
        await writer.recordLogin(
          const AuthSessionLedgerLogin(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            tokenHash: 'h',
          ),
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ProxyAuthSessionLedgerError>());
      final error = thrown! as ProxyAuthSessionLedgerError;
      expect(error.code, equals('scope_mismatch'));
      expect(error.message.contains('DIFFERENT'), isFalse);
    });

    test('null ID token maps to no_id_token before any HTTP call', () async {
      final fake = _FakeProxyHttpJsonClient(
        respondWith: const ProxyHttpJsonResponse(
          statusCode: 200,
          body: <String, Object?>{'session_id': 'unused'},
        ),
      );
      final writer = ProxyAuthSessionLedgerWriter(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => null,
        httpClient: fake,
      );

      Object? thrown;
      try {
        await writer.recordLogin(
          const AuthSessionLedgerLogin(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            tokenHash: 'h',
          ),
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ProxyAuthSessionLedgerError>());
      expect(
        (thrown! as ProxyAuthSessionLedgerError).code,
        equals('no_id_token'),
      );
      // Acceptance: writer NEVER hit the HTTP transport because the
      // missing token is a hard-fail-before-network condition.
      expect(fake.calls, isEmpty);
    });

    test('transport-level error maps to transport_error without leaking '
        'the underlying exception text', () async {
      final fake = _FakeProxyHttpJsonClient.throwsOnEveryCall(
        StateError('connect ECONNREFUSED secret://blob'),
      );
      final writer = ProxyAuthSessionLedgerWriter(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'token',
        httpClient: fake,
      );

      Object? thrown;
      try {
        await writer.recordLogin(
          const AuthSessionLedgerLogin(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            tokenHash: 'h',
          ),
        );
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ProxyAuthSessionLedgerError>());
      final error = thrown! as ProxyAuthSessionLedgerError;
      expect(error.code, equals('transport_error'));
      // Acceptance: the StateError's message (which could carry a
      // connection string or secret) does NOT surface in the error
      // message routed back through the writer.
      expect(error.message.contains('secret://blob'), isFalse);
      expect(error.message.contains('connect ECONNREFUSED'), isFalse);
    });
  });

  group('ProxyAuthSessionLedgerWriter — recordRefresh / revoke', () {
    test(
      'recordRefresh POSTs session_id to /v1/auth/session/refresh',
      () async {
        final fake = _FakeProxyHttpJsonClient(
          respondWith: const ProxyHttpJsonResponse(
            statusCode: 200,
            body: <String, Object?>{'ok': true},
          ),
        );
        final writer = ProxyAuthSessionLedgerWriter(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'token',
          httpClient: fake,
        );

        await writer.recordRefresh(
          sessionId: 'session-uuid',
          userId: 'u',
          operatorId: 'op',
          locationId: 'loc',
        );

        final call = fake.calls.single;
        expect(
          call.url.toString(),
          equals(
            'https://forge-flow-proxy.example.com/v1/auth/session/refresh',
          ),
        );
        expect(
          call.body,
          equals(<String, Object?>{'session_id': 'session-uuid'}),
        );
      },
    );

    test(
      'revokeSession POSTs session_id + reason to /v1/auth/session/revoke',
      () async {
        final fake = _FakeProxyHttpJsonClient(
          respondWith: const ProxyHttpJsonResponse(
            statusCode: 200,
            body: <String, Object?>{'ok': true},
          ),
        );
        final writer = ProxyAuthSessionLedgerWriter(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'token',
          httpClient: fake,
        );

        await writer.revokeSession(
          sessionId: 'session-uuid',
          userId: 'u',
          operatorId: 'op',
          locationId: 'loc',
          reason: 'user_signed_out_this_session',
        );

        final call = fake.calls.single;
        expect(
          call.url.toString(),
          equals('https://forge-flow-proxy.example.com/v1/auth/session/revoke'),
        );
        expect(
          call.body,
          equals(<String, Object?>{
            'session_id': 'session-uuid',
            'reason': 'user_signed_out_this_session',
          }),
        );
      },
    );

    test('revokeAllSessionsForUser POSTs reason to /v1/auth/session/revoke-all '
        'and returns revoked_count from response', () async {
      final fake = _FakeProxyHttpJsonClient(
        respondWith: const ProxyHttpJsonResponse(
          statusCode: 200,
          body: <String, Object?>{'ok': true, 'revoked_count': 3},
        ),
      );
      final writer = ProxyAuthSessionLedgerWriter(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'token',
        httpClient: fake,
      );

      final count = await writer.revokeAllSessionsForUser(
        userId: 'u',
        operatorId: 'op',
        locationId: 'loc',
        reason: 'user_signed_out_all_sessions',
      );
      expect(count, equals(3));

      final call = fake.calls.single;
      expect(
        call.url.toString(),
        equals(
          'https://forge-flow-proxy.example.com/v1/auth/session/revoke-all',
        ),
      );
      expect(
        call.body,
        equals(<String, Object?>{'reason': 'user_signed_out_all_sessions'}),
      );
    });

    test(
      'revokeAllSessionsForUser returns 0 when revoked_count is missing',
      () async {
        final fake = _FakeProxyHttpJsonClient(
          respondWith: const ProxyHttpJsonResponse(
            statusCode: 200,
            body: <String, Object?>{'ok': true},
          ),
        );
        final writer = ProxyAuthSessionLedgerWriter(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'token',
          httpClient: fake,
        );

        final count = await writer.revokeAllSessionsForUser(
          userId: 'u',
          operatorId: 'op',
          locationId: 'loc',
          reason: 'r',
        );
        expect(count, equals(0));
      },
    );
  });

  group('ProxyAuthSessionLedgerWriter — wire-contract sanity', () {
    test(
      'writer endpoint paths match the proxy route constants exactly',
      () async {
        // The writer can't import from `tool/` (lib/ → tool/ would
        // pull the proxy module into the Flutter binary), so it
        // declares its own path constants. This test asserts both
        // sides agree byte-for-byte. If either constant changes the
        // wire contract is broken and this guard fires.
        final fake = _FakeProxyHttpJsonClient(
          respondWith: const ProxyHttpJsonResponse(
            statusCode: 200,
            body: <String, Object?>{
              'session_id': 'x',
              'user_id': 'u',
              'operator_id': 'op',
              'location_id': 'loc',
            },
          ),
        );
        final writer = ProxyAuthSessionLedgerWriter(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'token',
          httpClient: fake,
        );

        await writer.recordLogin(
          const AuthSessionLedgerLogin(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            tokenHash: 'h',
          ),
        );
        await writer.recordRefresh(
          sessionId: 's',
          userId: 'u',
          operatorId: 'op',
          locationId: 'loc',
        );
        await writer.revokeSession(
          sessionId: 's',
          userId: 'u',
          operatorId: 'op',
          locationId: 'loc',
          reason: 'r',
        );
        await writer.revokeAllSessionsForUser(
          userId: 'u',
          operatorId: 'op',
          locationId: 'loc',
          reason: 'r',
        );

        expect(
          fake.calls.map((c) => c.url.path).toList(),
          equals(<String>[
            proxy.authSessionLoginPath,
            proxy.authSessionRefreshPath,
            proxy.authSessionRevokePath,
            proxy.authSessionRevokeAllPath,
          ]),
        );
      },
    );

    test(
      'default idempotency-key factory generates non-blank distinct values',
      () async {
        // Sanity: two consecutive logins through the default factory
        // produce different Idempotency-Key values, so a future proxy
        // slice that integrates `proxy_requests` can dedupe replays
        // without the client baking in collisions.
        final fake = _FakeProxyHttpJsonClient(
          respondWith: const ProxyHttpJsonResponse(
            statusCode: 200,
            body: <String, Object?>{
              'session_id': 'x',
              'user_id': 'u',
              'operator_id': 'op',
              'location_id': 'loc',
            },
          ),
        );
        final writer = ProxyAuthSessionLedgerWriter(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'token',
          httpClient: fake,
        );

        await writer.recordLogin(
          const AuthSessionLedgerLogin(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            tokenHash: 'h',
          ),
        );
        await writer.recordLogin(
          const AuthSessionLedgerLogin(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            tokenHash: 'h',
          ),
        );

        final keys = fake.calls
            .map((c) => c.headers['Idempotency-Key'])
            .whereType<String>()
            .toList();
        expect(keys, hasLength(2));
        expect(keys.first.isNotEmpty, isTrue);
        expect(keys.last.isNotEmpty, isTrue);
        expect(keys.first, isNot(equals(keys.last)));
      },
    );
  });

  group('ProxyRefreshTokenRevoker', () {
    test('POSTs an empty body to the refresh-token revoke-all route', () async {
      final fake = _FakeProxyHttpJsonClient(
        respondWith: const ProxyHttpJsonResponse(
          statusCode: 200,
          body: <String, Object?>{'ok': true},
        ),
      );
      final revoker = ProxyRefreshTokenRevoker(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'live-id-token',
        httpClient: fake,
        idempotencyKeyFactory: () => 'idempotency-refresh-revoke',
      );

      await revoker.revokeAllRefreshTokens();

      final call = fake.calls.single;
      expect(
        call.url.toString(),
        equals(
          'https://forge-flow-proxy.example.com'
          '/v1/auth/refresh-tokens/revoke-all',
        ),
      );
      expect(
        call.headers[HttpHeaders.authorizationHeader],
        equals('Bearer live-id-token'),
      );
      expect(
        call.headers['Idempotency-Key'],
        equals('idempotency-refresh-revoke'),
      );
      expect(call.body, isEmpty);
    });

    test('route path matches the proxy constant', () {
      expect(
        ProxyRefreshTokenRevoker.revokeAllPath,
        equals(proxy.authRefreshTokensRevokeAllPath),
      );
    });

    test('missing ID token maps to no_id_token before any HTTP call', () async {
      final fake = _FakeProxyHttpJsonClient(
        respondWith: const ProxyHttpJsonResponse(
          statusCode: 200,
          body: <String, Object?>{'ok': true},
        ),
      );
      final revoker = ProxyRefreshTokenRevoker(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => null,
        httpClient: fake,
      );

      Object? thrown;
      try {
        await revoker.revokeAllRefreshTokens();
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<ProxyAuthSessionLedgerError>());
      expect((thrown! as ProxyAuthSessionLedgerError).code, 'no_id_token');
      expect(fake.calls, isEmpty);
    });
  });

  group('ScaffoldFailingProxyHttpJsonClient', () {
    test('every call throws so a misconfigured deploy fails closed', () async {
      const transport = ScaffoldFailingProxyHttpJsonClient();
      await expectLater(
        transport.postJson(
          url: Uri.parse('https://example.com'),
          headers: const <String, String>{},
          body: const <String, Object?>{},
        ),
        throwsStateError,
      );
    });
  });
}

class _RecordedHttpCall {
  _RecordedHttpCall({
    required this.url,
    required this.headers,
    required this.body,
  });

  final Uri url;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}

class _FakeProxyHttpJsonClient implements ProxyHttpJsonClient {
  _FakeProxyHttpJsonClient({required ProxyHttpJsonResponse respondWith})
    : _respondWith = respondWith,
      _throwError = null;

  _FakeProxyHttpJsonClient.throwsOnEveryCall(Object error)
    : _respondWith = null,
      _throwError = error;

  final ProxyHttpJsonResponse? _respondWith;
  final Object? _throwError;

  final List<_RecordedHttpCall> calls = <_RecordedHttpCall>[];

  @override
  Future<ProxyHttpJsonResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    calls.add(_RecordedHttpCall(url: url, headers: headers, body: body));
    final error = _throwError;
    if (error != null) throw error;
    return _respondWith!;
  }
}
