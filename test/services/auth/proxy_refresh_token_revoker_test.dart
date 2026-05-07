// CODE_HEALTH L2 / C2 — ProxyRefreshTokenRevoker idempotency-key tests.
//
// Guards the regression: the default idempotency-key factory must be
// driven by `Random.secure()` (128-bit nonce, 32 lowercase hex chars),
// not `DateTime.now().microsecondsSinceEpoch`, so two concurrent
// revoke calls cannot collide on the same key and let the proxy
// short-circuit the second revoke as a duplicate.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/proxy_auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/proxy_refresh_token_revoker.dart';

void main() {
  final baseUri = Uri.parse('https://forge-flow-proxy.example.com');
  final hex32 = RegExp(r'^[0-9a-f]{32}$');

  group('ProxyRefreshTokenRevoker default idempotency key', () {
    test(
      'is exactly 32 lowercase hex chars on every revoke call',
      () async {
        final fake = _FakeProxyHttpJsonClient();
        final revoker = ProxyRefreshTokenRevoker(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'fake-id-token',
          httpClient: fake,
        );

        // 16 calls is plenty to catch a stray prefix or wrong length;
        // the 1000-key uniqueness check below covers collision risk.
        for (var i = 0; i < 16; i++) {
          await revoker.revokeAllRefreshTokens();
        }

        expect(fake.posts, hasLength(16));
        for (final call in fake.posts) {
          final key = call.headers['Idempotency-Key'];
          expect(key, isNotNull);
          expect(
            key,
            matches(hex32),
            reason: 'idempotency key must be 32 lowercase hex chars',
          );
        }
      },
    );

    test('generates 1000 distinct hex32 keys (no collisions)', () async {
      final fake = _FakeProxyHttpJsonClient();
      final revoker = ProxyRefreshTokenRevoker(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'fake-id-token',
        httpClient: fake,
      );

      for (var i = 0; i < 1000; i++) {
        await revoker.revokeAllRefreshTokens();
      }

      expect(fake.posts, hasLength(1000));
      final keys = fake.posts
          .map((call) => call.headers['Idempotency-Key']!)
          .toList(growable: false);
      for (final key in keys) {
        expect(
          key,
          matches(hex32),
          reason: 'idempotency key must be 32 lowercase hex chars',
        );
      }
      expect(keys.toSet().length, equals(1000));
    });

    test(
      'forwards a caller-supplied idempotencyKeyFactory verbatim',
      () async {
        final fake = _FakeProxyHttpJsonClient();
        final revoker = ProxyRefreshTokenRevoker(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'fake-id-token',
          httpClient: fake,
          idempotencyKeyFactory: () => 'caller-owned-key',
        );

        await revoker.revokeAllRefreshTokens();

        expect(
          fake.posts.single.headers['Idempotency-Key'],
          equals('caller-owned-key'),
        );
      },
    );
  });

  test(
    'sends the bearer token and POSTs to /v1/auth/refresh-tokens/revoke-all',
    () async {
      final fake = _FakeProxyHttpJsonClient();
      final revoker = ProxyRefreshTokenRevoker(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'fake-id-token',
        httpClient: fake,
      );

      await revoker.revokeAllRefreshTokens();

      final call = fake.posts.single;
      expect(call.url.path, equals(ProxyRefreshTokenRevoker.revokeAllPath));
      expect(
        call.headers[HttpHeaders.authorizationHeader],
        equals('Bearer fake-id-token'),
      );
      expect(call.body, isEmpty);
    },
  );
}

class _FakeProxyHttpJsonClient implements ProxyHttpJsonClient {
  _FakeProxyHttpJsonClient();

  static const ProxyHttpJsonResponse _defaultResponse = ProxyHttpJsonResponse(
    statusCode: 200,
    body: <String, Object?>{'ok': true},
  );

  final posts = <_CapturedRevokeCall>[];

  @override
  Future<ProxyHttpJsonResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    posts.add(_CapturedRevokeCall(url, headers, body));
    return _defaultResponse;
  }
}

class _CapturedRevokeCall {
  const _CapturedRevokeCall(this.url, this.headers, this.body);

  final Uri url;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}
