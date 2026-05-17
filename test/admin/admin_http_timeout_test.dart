import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:forge_and_flow/admin/services/admin_http_timeout.dart';
import 'package:forge_and_flow/admin/services/feature_flags_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/health_admin_gateway.dart';

void main() {
  group('G71 — admin 401 force-refresh-and-retry-once', () {
    tearDown(AdminHttpTokenRefreshDispatcher.resetForTesting);

    test(
      '401 then success: request retried ONCE with refreshed token and '
      'the IDENTICAL idempotency key + body',
      () async {
        var refreshCalls = 0;
        AdminHttpTokenRefreshDispatcher.refreshIdToken = () async {
          refreshCalls += 1;
          return 'fresh-token-v2';
        };

        final client = _ScriptedClient(<_ScriptedReply>[
          _ScriptedReply(statusCode: 401, body: '{"error":"token_expired"}'),
          _ScriptedReply(statusCode: 200, body: '{"ok":true}'),
        ]);

        final request = http.Request(
          'POST',
          Uri.parse('https://proxy.test/v1/admin/destructive-action'),
        )
          ..headers['authorization'] = 'Bearer stale-token-v1'
          ..headers['content-type'] = 'application/json'
          ..headers['Idempotency-Key'] = 'idem-key-abc-123'
          ..bodyBytes = utf8.encode(jsonEncode(<String, Object?>{
            'operator_id': 'op_1',
            'confirm': true,
          }));

        final response = await sendAdminHttpRequest(client, request);

        // Recovered: final answer is the post-refresh 200.
        expect(response.statusCode, 200);
        // Exactly one refresh, exactly two sends (first + single retry).
        expect(refreshCalls, 1);
        expect(client.sent, hasLength(2));

        final first = client.sent[0];
        final retry = client.sent[1];

        // First attempt carried the stale bearer.
        expect(first.headers['authorization'], 'Bearer stale-token-v1');
        // Retry swapped ONLY the bearer to the refreshed token.
        expect(retry.headers['authorization'], 'Bearer fresh-token-v2');

        // Idempotency-Key reused VERBATIM — NOT re-minted (G60/G70
        // idempotency bug class).
        expect(first.headers['Idempotency-Key'], 'idem-key-abc-123');
        expect(retry.headers['Idempotency-Key'], 'idem-key-abc-123');

        // Method, URL, body, and every non-auth header preserved
        // byte-for-byte on the retry.
        expect(retry.method, 'POST');
        expect(retry.url, first.url);
        expect(retry.headers['content-type'], 'application/json');
        expect(retry.body, first.body);
        expect(
          jsonDecode(retry.body),
          <String, Object?>{'operator_id': 'op_1', 'confirm': true},
        );
      },
    );

    test(
      '401 then 401: surfaces the same failure as today (single retry, '
      'no infinite loop)',
      () async {
        var refreshCalls = 0;
        AdminHttpTokenRefreshDispatcher.refreshIdToken = () async {
          refreshCalls += 1;
          return 'fresh-but-still-rejected';
        };

        final client = _ScriptedClient(<_ScriptedReply>[
          _ScriptedReply(statusCode: 401, body: '{"error":"token_expired"}'),
          _ScriptedReply(statusCode: 401, body: '{"error":"unauthorized"}'),
        ]);

        final request = http.Request(
          'POST',
          Uri.parse('https://proxy.test/v1/admin/destructive-action'),
        )
          ..headers['authorization'] = 'Bearer stale'
          ..headers['Idempotency-Key'] = 'idem-key-loop-guard'
          ..bodyBytes = utf8.encode('{"x":1}');

        final response = await sendAdminHttpRequest(client, request);

        // The second 401 is the FINAL answer — same status the caller
        // saw before this slice. No third send; refresh fired once.
        expect(response.statusCode, 401);
        expect(refreshCalls, 1);
        expect(client.sent, hasLength(2));
        // Retry still carried the same idempotency key verbatim.
        expect(
          client.sent[1].headers['Idempotency-Key'],
          'idem-key-loop-guard',
        );
      },
    );

    test(
      'non-401 error path is unchanged (no refresh, no retry)',
      () async {
        var refreshCalls = 0;
        AdminHttpTokenRefreshDispatcher.refreshIdToken = () async {
          refreshCalls += 1;
          return 'should-not-be-used';
        };

        final client = _ScriptedClient(<_ScriptedReply>[
          _ScriptedReply(statusCode: 500, body: '{"error":"server_error"}'),
        ]);

        final request = http.Request(
          'POST',
          Uri.parse('https://proxy.test/v1/admin/action'),
        )
          ..headers['authorization'] = 'Bearer token'
          ..headers['Idempotency-Key'] = 'idem-key-500'
          ..bodyBytes = utf8.encode('{"y":2}');

        final response = await sendAdminHttpRequest(client, request);

        // 500 returned untouched; refresh hook never consulted; exactly
        // one send (pre-slice behaviour, byte-equivalent).
        expect(response.statusCode, 500);
        expect(response.body, '{"error":"server_error"}');
        expect(refreshCalls, 0);
        expect(client.sent, hasLength(1));
      },
    );

    test(
      'no refresh hook wired (demo / share-preview): first 401 returns '
      'as-is, no retry',
      () async {
        // Dispatcher left unset (the demo / share-preview / default
        // state) — the chokepoint must NOT retry.
        final client = _ScriptedClient(<_ScriptedReply>[
          _ScriptedReply(statusCode: 401, body: '{"error":"token_expired"}'),
        ]);

        final request = http.Request(
          'GET',
          Uri.parse('https://proxy.test/v1/admin/read'),
        )..headers['authorization'] = 'Bearer token';

        final response = await sendAdminHttpRequest(client, request);

        expect(response.statusCode, 401);
        expect(client.sent, hasLength(1));
      },
    );

    test(
      'refresh hook returning null (signed out) surfaces the original '
      '401 unchanged, no retry',
      () async {
        AdminHttpTokenRefreshDispatcher.refreshIdToken = () async => null;

        final client = _ScriptedClient(<_ScriptedReply>[
          _ScriptedReply(statusCode: 401, body: '{"error":"token_expired"}'),
        ]);

        final request = http.Request(
          'POST',
          Uri.parse('https://proxy.test/v1/admin/action'),
        )
          ..headers['authorization'] = 'Bearer token'
          ..headers['Idempotency-Key'] = 'idem-null-refresh'
          ..bodyBytes = utf8.encode('{"z":3}');

        final response = await sendAdminHttpRequest(client, request);

        expect(response.statusCode, 401);
        expect(client.sent, hasLength(1));
      },
    );

    test(
      'refresh hook throwing surfaces the original 401 unchanged, no retry',
      () async {
        AdminHttpTokenRefreshDispatcher.refreshIdToken =
            () async => throw StateError('refresh network failure');

        final client = _ScriptedClient(<_ScriptedReply>[
          _ScriptedReply(statusCode: 401, body: '{"error":"token_expired"}'),
        ]);

        final request = http.Request(
          'POST',
          Uri.parse('https://proxy.test/v1/admin/action'),
        )
          ..headers['authorization'] = 'Bearer token'
          ..headers['Idempotency-Key'] = 'idem-throw-refresh'
          ..bodyBytes = utf8.encode('{"w":4}');

        final response = await sendAdminHttpRequest(client, request);

        expect(response.statusCode, 401);
        expect(client.sent, hasLength(1));
      },
    );
  });

  test(
    'sendAdminHttpRequest bounds the full request/response future',
    () async {
      final client = _NeverCompletingClient();
      final request = http.Request('GET', Uri.parse('https://proxy.test/slow'));

      await expectLater(
        sendAdminHttpRequest(
          client,
          request,
          timeout: const Duration(milliseconds: 5),
        ),
        throwsA(isA<AdminHttpTimeoutException>()),
      );
    },
  );

  test(
    'feature flag HTTP gateway maps timeout to a screen-readable error',
    () async {
      final gateway = HttpFeatureFlagsAdminGateway(
        baseUri: Uri.parse('https://proxy.test'),
        bearerTokenProvider: () async => 'token',
        httpClient: _NeverCompletingClient(),
        timeout: const Duration(milliseconds: 5),
      );

      await expectLater(
        gateway.listFlags(),
        throwsA(
          isA<FeatureFlagsAdminGatewayError>()
              .having((e) => e.statusCode, 'statusCode', 408)
              .having((e) => e.errorCode, 'errorCode', 'timeout'),
        ),
      );
    },
  );

  test(
    'health HTTP gateway maps timeout to the existing health error type',
    () async {
      final gateway = HttpHealthAdminGateway(
        baseUri: Uri.parse('https://proxy.test'),
        httpClient: _NeverCompletingClient(),
        timeout: const Duration(milliseconds: 5),
      );

      await expectLater(
        gateway.fetch(),
        throwsA(
          isA<HealthAdminGatewayError>()
              .having((e) => e.statusCode, 'statusCode', 408)
              .having(
                (e) => e.message,
                'message',
                contains('/health timed out'),
              ),
        ),
      );
    },
  );
}

class _NeverCompletingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return Completer<http.StreamedResponse>().future;
  }
}

class _ScriptedReply {
  const _ScriptedReply({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

/// Replays [_replies] in order and records a verbatim snapshot of every
/// request it was asked to send (method, URL, headers, decoded body) so
/// tests can assert the G71 retry preserved the idempotency key + body
/// and swapped only the bearer.
class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this._replies);

  final List<_ScriptedReply> _replies;
  final List<_SentSnapshot> sent = <_SentSnapshot>[];
  int _index = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = request as http.Request;
    sent.add(
      _SentSnapshot(
        method: req.method,
        url: req.url,
        headers: Map<String, String>.from(req.headers),
        body: utf8.decode(req.bodyBytes),
      ),
    );
    if (_index >= _replies.length) {
      throw StateError(
        'unexpected extra send (#${_index + 1}) — scripted client ran out '
        'of replies; this indicates a retry loop',
      );
    }
    final reply = _replies[_index++];
    final bytes = utf8.encode(reply.body);
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      reply.statusCode,
      contentLength: bytes.length,
      request: req,
    );
  }
}

class _SentSnapshot {
  _SentSnapshot({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String body;
}
