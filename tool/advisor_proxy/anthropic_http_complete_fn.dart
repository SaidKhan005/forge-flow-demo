// Phase 11a — HTTP adapter for the Anthropic Messages API.
//
// Replaces the rejecting placeholder used by Block 2's
// `AnthropicProxyLlmProvider`. Block 2 shipped the fallback chain
// `anthropic -> gemini -> cached -> refusal`; until this file lands the
// Anthropic slot threw on every call and Gemini served as the
// de-facto primary. With the real adapter wired, Anthropic is the
// primary and Gemini takes over only on 5xx / network failures —
// matching Hard Promise #5 (advisor speaks in recommendations) and
// Hard Promise #7 (F&F holds all provider keys server-side; this file
// lives under `tool/advisor_proxy/`, never imported from `lib/`).
//
// Streaming is intentionally not supported: the public
// [AnthropicProxyCompleteFn] typedef is non-streaming, and changing
// it would break chain composition (Hard Constraint in
// `advisor_proxy.dart` Block 2). Errors propagate as exceptions so
// `FallbackChainProxyLlmProvider` advances to the next slot.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'advisor_proxy.dart'
    show AnthropicProxyCompleteFn, ProxyLlmCompletePayload;

/// Anthropic Messages API endpoint.
const String anthropicMessagesEndpoint = 'https://api.anthropic.com/v1/messages';

/// Pinned API version header sent on every request. Anthropic dates
/// their API; this is the latest stable version compatible with the
/// `claude-haiku-4-5` and `claude-sonnet-4-5` models the proxy uses.
const String anthropicApiVersion = '2023-06-01';

/// Default `max_tokens` for a Messages API call. Caps a single
/// completion to keep cost predictable; callers can override per
/// invocation by passing `maxTokens` to [buildAnthropicHttpCompleteFn].
const int defaultAnthropicMaxTokens = 1024;

/// Default request timeout for a Messages API call. Bounds how long a
/// single Anthropic call can hang before the fallback chain advances
/// to the Gemini slot. Callers can override per invocation by passing
/// `timeout` to [buildAnthropicHttpCompleteFn].
const Duration defaultAnthropicRequestTimeout = Duration(seconds: 30);

/// Thrown when the Anthropic Messages API returns a non-200 response
/// or a malformed body. The fallback chain catches any thrown
/// exception and advances to the Gemini slot — surfacing this concrete
/// type lets telemetry distinguish HTTP failures from local bugs.
class AnthropicHttpCompletionError implements Exception {
  AnthropicHttpCompletionError({
    required this.statusCode,
    required this.body,
  });

  /// HTTP status code returned by Anthropic. `200` indicates a
  /// malformed-but-otherwise-successful response (missing `content`
  /// array, unexpected JSON shape, etc).
  final int statusCode;

  /// Raw response body. Bounded by Anthropic's response size so
  /// stuffing the whole body into the exception is safe for logging.
  final String body;

  @override
  String toString() => 'AnthropicHttpCompletionError($statusCode): $body';
}

/// Builds an [AnthropicProxyCompleteFn] backed by a real HTTP call to
/// the Messages API. Inject [httpClient] in tests via
/// `package:http/testing.dart`'s `MockClient` so the function can be
/// exercised without network I/O.
///
/// - [apiKey]: secret loaded from `ProxySecretNames.anthropicApiKey`
///   at startup. Never logged; threaded into the `x-api-key` header.
/// - [endpoint]: defaults to [anthropicMessagesEndpoint]; overridable
///   for tests that want to assert the outbound URL.
/// - [maxTokens]: per-call upper bound on output tokens. Defaults to
///   [defaultAnthropicMaxTokens].
/// - [timeout]: per-call request timeout. Defaults to
///   [defaultAnthropicRequestTimeout]. A `TimeoutException` propagates
///   to the fallback chain so the Gemini slot can take over.
AnthropicProxyCompleteFn buildAnthropicHttpCompleteFn({
  required String apiKey,
  http.Client? httpClient,
  Uri? endpoint,
  int maxTokens = defaultAnthropicMaxTokens,
  Duration timeout = defaultAnthropicRequestTimeout,
}) {
  final client = httpClient ?? http.Client();
  final uri = endpoint ?? Uri.parse(anthropicMessagesEndpoint);
  return ({
    required String modelId,
    required String question,
    required String context,
  }) async {
    final body = <String, Object?>{
      'model': modelId,
      'max_tokens': maxTokens,
      'messages': <Map<String, Object?>>[
        <String, Object?>{'role': 'user', 'content': question},
      ],
    };
    if (context.isNotEmpty) {
      body['system'] = context;
    }
    final response = await client
        .post(
          uri,
          headers: <String, String>{
            'x-api-key': apiKey,
            'anthropic-version': anthropicApiVersion,
            HttpHeaders.contentTypeHeader: 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw AnthropicHttpCompletionError(
        statusCode: response.statusCode,
        body: response.body,
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, Object?>;
    final content = decoded['content'];
    if (content is! List) {
      throw AnthropicHttpCompletionError(
        statusCode: 200,
        body: 'malformed response: missing content array',
      );
    }
    final buffer = StringBuffer();
    for (final block in content) {
      if (block is Map<String, Object?> && block['type'] == 'text') {
        final text = block['text'];
        if (text is String) buffer.write(text);
      }
    }
    // Defensive parsing of `usage`. Anthropic always returns it on a
    // successful 200, but the chain treats missing / malformed shapes
    // as zero rather than throwing — a partial result is still useful
    // and the fallback chain logs `usage_logs` from the returned
    // payload regardless.
    final usage = decoded['usage'];
    int inputTokens = 0;
    int outputTokens = 0;
    if (usage is Map<String, Object?>) {
      final input = usage['input_tokens'];
      if (input is int) inputTokens = input;
      final output = usage['output_tokens'];
      if (output is int) outputTokens = output;
    }
    return ProxyLlmCompletePayload(
      text: buffer.toString(),
      inputTokens: inputTokens,
      outputTokens: outputTokens,
    );
  };
}
