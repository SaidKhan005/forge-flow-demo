// Phase 11a — unit tests for the Anthropic Messages API HTTP adapter.
//
// Verifies the round-trip shape (URL, headers, body) and the error
// behavior the fallback chain depends on (any non-200 throws, so the
// chain advances to Gemini). Uses `package:http/testing.dart`'s
// `MockClient` to stub responses; mirrors the test style in
// `fallback_chain_with_gemini_test.dart` (relative imports, plain
// Dart closures, no mocking framework).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../tool/advisor_proxy/anthropic_http_complete_fn.dart';

http.Response _jsonResponse(int statusCode, Object? body) {
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: <String, String>{
      HttpHeaders.contentTypeHeader: 'application/json',
    },
  );
}

Map<String, Object?> _decodeBody(http.BaseRequest request) {
  if (request is! http.Request) {
    fail('expected http.Request, got ${request.runtimeType}');
  }
  return jsonDecode(request.body) as Map<String, Object?>;
}

void main() {
  group('buildAnthropicHttpCompleteFn', () {
    test('successful round-trip returns concatenated text from a single '
        'text content block', () async {
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'id': 'msg_123',
          'content': <Map<String, Object?>>[
            <String, Object?>{'type': 'text', 'text': 'hello world'},
          ],
          'stop_reason': 'end_turn',
          'usage': <String, Object?>{
            'input_tokens': 12,
            'output_tokens': 34,
          },
        });
      });

      final completeFn = buildAnthropicHttpCompleteFn(
        apiKey: 'test-key',
        httpClient: mock,
      );

      final result = await completeFn(
        modelId: 'claude-haiku-4-5',
        question: 'why?',
        context: 'system',
      );

      expect(result.text, equals('hello world'));
      expect(result.inputTokens, equals(12));
      expect(result.outputTokens, equals(34));
    });

    test('multi-block content concatenates each text block in order',
        () async {
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'content': <Map<String, Object?>>[
            <String, Object?>{'type': 'text', 'text': 'first '},
            <String, Object?>{'type': 'text', 'text': 'second'},
          ],
        });
      });

      final completeFn = buildAnthropicHttpCompleteFn(
        apiKey: 'test-key',
        httpClient: mock,
      );

      final result = await completeFn(
        modelId: 'claude-haiku-4-5',
        question: 'q',
        context: 'c',
      );

      expect(result.text, equals('first second'));
    });

    test('skips non-text content blocks and only returns text', () async {
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'content': <Map<String, Object?>>[
            <String, Object?>{'type': 'text', 'text': 'visible '},
            <String, Object?>{
              'type': 'tool_use',
              'id': 'toolu_1',
              'name': 'lookup',
              'input': <String, Object?>{'q': 'x'},
            },
            <String, Object?>{'type': 'text', 'text': 'tail'},
          ],
        });
      });

      final completeFn = buildAnthropicHttpCompleteFn(
        apiKey: 'test-key',
        httpClient: mock,
      );

      final result = await completeFn(
        modelId: 'claude-haiku-4-5',
        question: 'q',
        context: 'c',
      );

      expect(result.text, equals('visible tail'));
    });

    test('outbound request uses Messages API URL, required headers, and '
        'body shape with system when context is non-empty', () async {
      late http.BaseRequest captured;
      final mock = MockClient((request) async {
        captured = request;
        return _jsonResponse(200, <String, Object?>{
          'content': <Map<String, Object?>>[
            <String, Object?>{'type': 'text', 'text': 'ok'},
          ],
        });
      });

      final completeFn = buildAnthropicHttpCompleteFn(
        apiKey: 'sk-test-abc',
        httpClient: mock,
      );

      await completeFn(
        modelId: 'claude-haiku-4-5',
        question: 'why is variance up?',
        context: 'You are a labor advisor.',
      );

      expect(captured.method, equals('POST'));
      expect(
        captured.url.toString(),
        equals('https://api.anthropic.com/v1/messages'),
      );
      expect(captured.headers['x-api-key'], equals('sk-test-abc'));
      expect(captured.headers['anthropic-version'], equals('2023-06-01'));
      expect(
        captured.headers[HttpHeaders.contentTypeHeader],
        contains('application/json'),
      );

      final body = _decodeBody(captured);
      expect(body['model'], equals('claude-haiku-4-5'));
      expect(body['max_tokens'], equals(defaultAnthropicMaxTokens));
      expect(body['system'], equals('You are a labor advisor.'));
      final messages = body['messages'] as List<Object?>;
      expect(messages, hasLength(1));
      expect(
        messages.single,
        equals(<String, Object?>{
          'role': 'user',
          'content': 'why is variance up?',
        }),
      );
    });

    test('empty context omits the system key from the body', () async {
      late http.BaseRequest captured;
      final mock = MockClient((request) async {
        captured = request;
        return _jsonResponse(200, <String, Object?>{
          'content': <Map<String, Object?>>[
            <String, Object?>{'type': 'text', 'text': 'ok'},
          ],
        });
      });

      final completeFn = buildAnthropicHttpCompleteFn(
        apiKey: 'test-key',
        httpClient: mock,
      );

      await completeFn(
        modelId: 'claude-haiku-4-5',
        question: 'q',
        context: '',
      );

      final body = _decodeBody(captured);
      expect(body.containsKey('system'), isFalse);
    });

    test('non-200 response throws AnthropicHttpCompletionError with '
        'statusCode and body intact', () async {
      final mock = MockClient((request) async {
        return http.Response('upstream is down', 503);
      });

      final completeFn = buildAnthropicHttpCompleteFn(
        apiKey: 'test-key',
        httpClient: mock,
      );

      try {
        await completeFn(
          modelId: 'claude-haiku-4-5',
          question: 'q',
          context: 'c',
        );
        fail('expected AnthropicHttpCompletionError');
      } on AnthropicHttpCompletionError catch (error) {
        expect(error.statusCode, equals(503));
        expect(error.body, equals('upstream is down'));
        expect(error.toString(), contains('503'));
        expect(error.toString(), contains('upstream is down'));
      }
    });

    test('custom maxTokens propagates to the request body', () async {
      late http.BaseRequest captured;
      final mock = MockClient((request) async {
        captured = request;
        return _jsonResponse(200, <String, Object?>{
          'content': <Map<String, Object?>>[
            <String, Object?>{'type': 'text', 'text': 'ok'},
          ],
        });
      });

      final completeFn = buildAnthropicHttpCompleteFn(
        apiKey: 'test-key',
        httpClient: mock,
        maxTokens: 4096,
      );

      await completeFn(
        modelId: 'claude-haiku-4-5',
        question: 'q',
        context: 'c',
      );

      final body = _decodeBody(captured);
      expect(body['max_tokens'], equals(4096));
    });

    test('custom timeout passes through and fires when the upstream '
        'response is delayed beyond it', () async {
      final mock = MockClient((request) async {
        // Delay well past the timeout so .timeout() fires before the
        // mocked response resolves.
        return Future<http.Response>.delayed(
          const Duration(seconds: 1),
          () => _jsonResponse(200, <String, Object?>{
            'content': <Map<String, Object?>>[
              <String, Object?>{'type': 'text', 'text': 'never seen'},
            ],
          }),
        );
      });

      final completeFn = buildAnthropicHttpCompleteFn(
        apiKey: 'test-key',
        httpClient: mock,
        timeout: const Duration(milliseconds: 100),
      );

      await expectLater(
        completeFn(
          modelId: 'claude-haiku-4-5',
          question: 'q',
          context: 'c',
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('usage tokens are extracted from the response body', () async {
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'content': <Map<String, Object?>>[
            <String, Object?>{'type': 'text', 'text': 'ok'},
          ],
          'usage': <String, Object?>{
            'input_tokens': 50,
            'output_tokens': 100,
          },
        });
      });

      final completeFn = buildAnthropicHttpCompleteFn(
        apiKey: 'test-key',
        httpClient: mock,
      );

      final result = await completeFn(
        modelId: 'claude-haiku-4-5',
        question: 'q',
        context: 'c',
      );

      expect(result.text, equals('ok'));
      expect(result.inputTokens, equals(50));
      expect(result.outputTokens, equals(100));
    });

    test('missing usage field defaults tokens to zero without throwing',
        () async {
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'content': <Map<String, Object?>>[
            <String, Object?>{'type': 'text', 'text': 'ok'},
          ],
          // No `usage` key.
        });
      });

      final completeFn = buildAnthropicHttpCompleteFn(
        apiKey: 'test-key',
        httpClient: mock,
      );

      final result = await completeFn(
        modelId: 'claude-haiku-4-5',
        question: 'q',
        context: 'c',
      );

      expect(result.text, equals('ok'));
      expect(result.inputTokens, equals(0));
      expect(result.outputTokens, equals(0));
    });

    test('cacheControl provided emits structured system blocks with '
        'cache_control on the wire', () async {
      // L13 — Anthropic prompt caching only engages when the request
      // body sends `system` as a list of content blocks, each with
      // `cache_control`. The proxy computes the marker
      // (`{'type':'ephemeral','ttl':'1h'}` from
      // `proxyPromptBlockToCacheControl`) but the HTTP adapter has to
      // actually serialize it onto the wire — without this branch
      // `prompt_cache_hit_rate` sits at 0%.
      late http.BaseRequest captured;
      final mock = MockClient((request) async {
        captured = request;
        return _jsonResponse(200, <String, Object?>{
          'content': <Map<String, Object?>>[
            <String, Object?>{'type': 'text', 'text': 'ok'},
          ],
        });
      });

      final completeFn = buildAnthropicHttpCompleteFn(
        apiKey: 'sk-test-cache',
        httpClient: mock,
        cacheControl: const <String, Object?>{
          'type': 'ephemeral',
          'ttl': '1h',
        },
      );

      await completeFn(
        modelId: 'claude-haiku-4-5',
        question: 'why?',
        context: 'You are a labor advisor.',
      );

      final body = _decodeBody(captured);
      final systemField = body['system'];
      expect(systemField, isA<List<Object?>>());
      final blocks = systemField as List<Object?>;
      expect(blocks, hasLength(1));
      final block = blocks.single as Map<String, Object?>;
      expect(block['type'], equals('text'));
      expect(block['text'], equals('You are a labor advisor.'));
      expect(
        block['cache_control'],
        equals(<String, Object?>{
          'type': 'ephemeral',
          'ttl': '1h',
        }),
      );
    });

    test('cacheControl omitted falls back to flat-string system block',
        () async {
      // Negative case — when no cache marker is supplied, the wire shape
      // matches the pre-L13 behavior (flat string). Keeps the endpoint
      // shape compatible for callers (e.g. fallback chain) that have
      // not yet computed a per-request cache marker.
      late http.BaseRequest captured;
      final mock = MockClient((request) async {
        captured = request;
        return _jsonResponse(200, <String, Object?>{
          'content': <Map<String, Object?>>[
            <String, Object?>{'type': 'text', 'text': 'ok'},
          ],
        });
      });

      final completeFn = buildAnthropicHttpCompleteFn(
        apiKey: 'test-key',
        httpClient: mock,
      );

      await completeFn(
        modelId: 'claude-haiku-4-5',
        question: 'q',
        context: 'You are a labor advisor.',
      );

      final body = _decodeBody(captured);
      expect(body['system'], equals('You are a labor advisor.'));
    });

    test('malformed usage value is tolerated and tokens default to zero',
        () async {
      final mock = MockClient((request) async {
        return _jsonResponse(200, <String, Object?>{
          'content': <Map<String, Object?>>[
            <String, Object?>{'type': 'text', 'text': 'ok'},
          ],
          'usage': 'not an object',
        });
      });

      final completeFn = buildAnthropicHttpCompleteFn(
        apiKey: 'test-key',
        httpClient: mock,
      );

      final result = await completeFn(
        modelId: 'claude-haiku-4-5',
        question: 'q',
        context: 'c',
      );

      expect(result.text, equals('ok'));
      expect(result.inputTokens, equals(0));
      expect(result.outputTokens, equals(0));
    });
  });
}
