// Advisor Knowledge Activation — Slice A4.1.
//
// Tool-use-capable adapter for the Anthropic Messages API. This is the
// sibling of `anthropic_http_complete_fn.dart`: that file is the
// single-shot path (one user turn -> one text turn, no tools); THIS
// file adds the `tools` / `tool_use` round-trip loop the agentic answer
// engine (`AdvisorAgenticAnswerEngine`) drives.
//
// Why a NEW standalone file rather than extending the single-shot one:
//   * The single-shot `AnthropicProxyCompleteFn` typedef is non-streaming
//     and tool-free; the fallback chain composes it and must stay
//     byte-stable (Hard Constraint in `advisor_proxy.dart` Block 2).
//   * This file imports `dart:convert` / `dart:io` / `package:http`
//     independently and is NOT a Dart `part of` the monolith, so the
//     monolith's import space and line count are untouched (the
//     `tool/advisor_proxy_size_lint.dart` bleed-stop ceiling is not
//     pressured by this slice).
//
// Hard Promise #7 (F&F holds all provider keys server-side): the API
// key is threaded ONLY into the `x-api-key` header. It is never logged,
// never returned in a result or exception, and never placed in the
// request body. Error bodies surfaced through the typed exception are
// truncated so a provider that echoes request material cannot leak a
// large payload into logs.
//
// This file lives under `tool/advisor_proxy/`, never imported from
// `lib/` (server-side only).

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Anthropic Messages API endpoint. Duplicated from
/// `anthropic_http_complete_fn.dart` deliberately: this file is
/// import-independent of the monolith and its single-shot sibling so
/// the agentic loop can evolve without touching the fallback-chain
/// adapter.
const String anthropicToolUseMessagesEndpoint =
    'https://api.anthropic.com/v1/messages';

/// Pinned API version header. Matches the single-shot adapter so both
/// paths speak the same wire contract to Anthropic.
const String anthropicToolUseApiVersion = '2023-06-01';

/// Default `max_tokens` per round-trip. Bounds a single completion to
/// keep cost predictable; callers override via
/// [buildAnthropicToolUseCompleteFn].
const int defaultAnthropicToolUseMaxTokens = 2048;

/// Default request timeout per round-trip. Bounds how long a single
/// Anthropic call can hang. Callers override via
/// [buildAnthropicToolUseCompleteFn].
const Duration defaultAnthropicToolUseRequestTimeout = Duration(seconds: 60);

/// Hard cap on the number of characters retained from a non-200 (or
/// malformed) response body when constructing
/// [AnthropicToolUseCompletionError]. HP #7: a provider that echoes
/// request material back in an error must not leak a large payload into
/// logs. 512 chars is enough to identify the failure class without
/// stuffing a whole body into the exception/log line.
const int kAnthropicToolUseErrorBodyMaxChars = 512;

/// Anthropic `stop_reason` value that means the model wants to call one
/// or more tools. The loop pauses on this value, surfaces the requested
/// `tool_use` blocks to the caller, and resumes once `tool_result`
/// blocks are appended.
const String anthropicStopReasonToolUse = 'tool_use';

/// Thrown when the Anthropic Messages API returns a non-200 response or
/// a malformed body during a tool-use round-trip. The engine surfaces
/// this as an upstream failure. The [body] is truncated to
/// [kAnthropicToolUseErrorBodyMaxChars] characters (HP #7). The API key
/// is NEVER included.
class AnthropicToolUseCompletionError implements Exception {
  AnthropicToolUseCompletionError({
    required this.statusCode,
    required String body,
  }) : body = _truncateBody(body);

  /// HTTP status code returned by Anthropic. `200` indicates a
  /// malformed-but-otherwise-successful response (missing `content`
  /// array, unexpected JSON shape, missing `stop_reason`, etc).
  final int statusCode;

  /// Truncated response body. Bounded by
  /// [kAnthropicToolUseErrorBodyMaxChars]. Never contains the API key
  /// (the key is only ever a header, never echoed by Anthropic).
  final String body;

  static String _truncateBody(String raw) {
    if (raw.length <= kAnthropicToolUseErrorBodyMaxChars) {
      return raw;
    }
    return '${raw.substring(0, kAnthropicToolUseErrorBodyMaxChars)}'
        '...[truncated ${raw.length - kAnthropicToolUseErrorBodyMaxChars} '
        'chars]';
  }

  @override
  String toString() =>
      'AnthropicToolUseCompletionError($statusCode): $body';
}

/// One tool the model is allowed to call, in Anthropic's `tools` array
/// shape: `{ "name", "description", "input_schema" }`. `inputSchema` is
/// a JSON Schema object (a `Map`) describing the tool's input.
class AnthropicToolDefinition {
  const AnthropicToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'description': description,
        'input_schema': inputSchema,
      };
}

/// A single tool call requested by the model in a `tool_use` content
/// block. Surfaced to the caller so it can run the matching handler and
/// produce a [AnthropicToolResult].
class AnthropicToolUseRequest {
  const AnthropicToolUseRequest({
    required this.id,
    required this.name,
    required this.input,
  });

  /// Anthropic's opaque `tool_use` block id (`toolu_...`). The matching
  /// `tool_result` block MUST echo this id.
  final String id;

  /// Name of the requested tool — keys into the caller's handler map.
  final String name;

  /// Decoded `input` object the model produced for the tool.
  final Map<String, Object?> input;
}

/// A tool result the caller hands back for one [AnthropicToolUseRequest].
/// Encoded into a `tool_result` content block on the next round-trip.
class AnthropicToolResult {
  const AnthropicToolResult({
    required this.toolUseId,
    required this.content,
    this.isError = false,
  });

  /// Echoes [AnthropicToolUseRequest.id] so Anthropic can pair the
  /// result with the call.
  final String toolUseId;

  /// Result payload. Serialized to JSON text for the `tool_result`
  /// block (Anthropic accepts a string or a content-block array; we
  /// send the canonical JSON-string form for determinism).
  final Map<String, Object?> content;

  /// When true, the `tool_result` block is flagged `is_error: true` so
  /// the model knows the tool failed and can recover or synthesize a
  /// graceful answer instead of fabricating.
  final bool isError;
}

/// What one round-trip of the tool-use loop returned. Exactly one of
/// [toolUseRequests] (non-empty) OR [finalText] is the operative field,
/// distinguished by [stopReason]:
///   * `stop_reason == 'tool_use'` -> [toolUseRequests] is non-empty and
///     the caller must run handlers and continue the loop.
///   * otherwise -> [finalText] holds the assistant's text turn and the
///     loop is done.
/// [inputTokens] / [outputTokens] are THIS round-trip's usage; the
/// engine sums them across all round-trips for metering.
class AnthropicToolUseTurn {
  const AnthropicToolUseTurn({
    required this.stopReason,
    required this.finalText,
    required this.toolUseRequests,
    required this.assistantContentBlocks,
    required this.inputTokens,
    required this.outputTokens,
  });

  /// Anthropic `stop_reason` for this turn (`tool_use`, `end_turn`,
  /// `max_tokens`, `stop_sequence`, ...).
  final String stopReason;

  /// Concatenated text from all `text` blocks in this turn. Non-empty
  /// only on a terminal (non-`tool_use`) turn in practice, but we always
  /// surface whatever text the model emitted.
  final String finalText;

  /// Tool calls the model requested this turn. Empty unless
  /// [stopReason] == `tool_use`.
  final List<AnthropicToolUseRequest> toolUseRequests;

  /// The RAW assistant `content` array from the response, preserved
  /// verbatim so the caller can append it to the running `messages`
  /// accumulator as the assistant turn before adding `tool_result`
  /// blocks. Anthropic requires the prior assistant `tool_use` blocks to
  /// be present for the follow-up turn to validate.
  final List<Object?> assistantContentBlocks;

  /// This round-trip's input token count (0 if usage absent/malformed).
  final int inputTokens;

  /// This round-trip's output token count (0 if usage absent/malformed).
  final int outputTokens;

  bool get wantsToolUse => stopReason == anthropicStopReasonToolUse;
}

/// Signature for the tool-use-capable Anthropic gateway. Drives ONE
/// round-trip: it sends the accumulated [messages] (already including
/// any `tool_result` turns the caller appended), the [tools] catalog,
/// and an optional [toolChoice], and returns a single
/// [AnthropicToolUseTurn].
///
/// The multi-turn LOOP (run handler -> append `tool_result` -> call
/// again until a terminal turn) is owned by the caller
/// ([AdvisorAgenticAnswerEngine]); this typedef is intentionally a
/// single round-trip so it is trivial to fake in tests with a scripted
/// closure.
///
/// - [modelId]: Anthropic model id (Haiku default, Sonnet for nuanced).
/// - [system]: optional system prompt (recommendation-only voice).
/// - [messages]: the running conversation accumulator
///   (`{role, content}` maps); `content` may be a string OR a content
///   block array (for assistant `tool_use` turns and user `tool_result`
///   turns).
/// - [tools]: the tool catalog. Empty disables tool use for the turn.
/// - [toolChoice]: optional Anthropic `tool_choice` object
///   (`{type: auto|any|tool, name?}`).
typedef AnthropicToolUseCompleteFn = Future<AnthropicToolUseTurn> Function({
  required String modelId,
  String? system,
  required List<Map<String, Object?>> messages,
  required List<AnthropicToolDefinition> tools,
  Map<String, Object?>? toolChoice,
});

/// Builds an [AnthropicToolUseCompleteFn] backed by a real HTTP call to
/// the Messages API. Inject [client] in tests via
/// `package:http/testing.dart`'s `MockClient` so the function can be
/// exercised without network I/O.
///
/// - [client]: HTTP client (required; inject a `MockClient` in tests).
/// - [apiKey]: secret loaded from the proxy secret store at startup.
///   Never logged; threaded ONLY into the `x-api-key` header (HP #7).
/// - [endpoint]: defaults to [anthropicToolUseMessagesEndpoint];
///   overridable for tests that assert the outbound URL.
/// - [maxTokens]: per-round-trip output-token cap. Defaults to
///   [defaultAnthropicToolUseMaxTokens].
/// - [timeout]: per-round-trip request timeout. Defaults to
///   [defaultAnthropicToolUseRequestTimeout]. A `TimeoutException`
///   propagates to the engine.
/// - [userAgent]: optional User-Agent override (the monolith threads a
///   correlation-tagged UA; this file stays import-independent of the
///   monolith, so the caller may pass one in).
AnthropicToolUseCompleteFn buildAnthropicToolUseCompleteFn({
  required http.Client client,
  required String apiKey,
  Uri? endpoint,
  int maxTokens = defaultAnthropicToolUseMaxTokens,
  Duration timeout = defaultAnthropicToolUseRequestTimeout,
  String userAgent = 'forge-and-flow-advisor-proxy/1.0',
}) {
  final uri = endpoint ?? Uri.parse(anthropicToolUseMessagesEndpoint);
  return ({
    required String modelId,
    String? system,
    required List<Map<String, Object?>> messages,
    required List<AnthropicToolDefinition> tools,
    Map<String, Object?>? toolChoice,
  }) async {
    final body = <String, Object?>{
      'model': modelId,
      'max_tokens': maxTokens,
      // Defensive copy: the engine owns the live accumulator; snapshot
      // it so a caller mutating the list after we read it cannot affect
      // the body `jsonEncode` serializes.
      'messages': List<Map<String, Object?>>.from(messages),
    };
    if (system != null && system.isNotEmpty) {
      body['system'] = system;
    }
    if (tools.isNotEmpty) {
      body['tools'] =
          tools.map((t) => t.toJson()).toList(growable: false);
      if (toolChoice != null) {
        body['tool_choice'] = Map<String, Object?>.from(toolChoice);
      }
    }

    final response = await client
        .post(
          uri,
          headers: <String, String>{
            'x-api-key': apiKey,
            'anthropic-version': anthropicToolUseApiVersion,
            HttpHeaders.contentTypeHeader: 'application/json',
            HttpHeaders.userAgentHeader: userAgent,
          },
          body: jsonEncode(body),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      // HP #7: the body is truncated inside the exception constructor;
      // the API key is a header only, never echoed here.
      throw AnthropicToolUseCompletionError(
        statusCode: response.statusCode,
        body: response.body,
      );
    }

    final Object? decodedRaw = jsonDecode(response.body);
    if (decodedRaw is! Map<String, Object?>) {
      throw AnthropicToolUseCompletionError(
        statusCode: 200,
        body: 'malformed response: top-level JSON is not an object',
      );
    }
    final decoded = decodedRaw;

    final content = decoded['content'];
    if (content is! List) {
      throw AnthropicToolUseCompletionError(
        statusCode: 200,
        body: 'malformed response: missing content array',
      );
    }

    final stopReasonRaw = decoded['stop_reason'];
    // Anthropic always returns stop_reason on a 200; treat a missing or
    // non-string value as a terminal end_turn rather than throwing so a
    // partial-but-usable text turn still surfaces.
    final stopReason = stopReasonRaw is String ? stopReasonRaw : 'end_turn';

    final textBuffer = StringBuffer();
    final toolUseRequests = <AnthropicToolUseRequest>[];
    for (final block in content) {
      if (block is! Map<String, Object?>) continue;
      final type = block['type'];
      if (type == 'text') {
        final text = block['text'];
        if (text is String) textBuffer.write(text);
      } else if (type == 'tool_use') {
        final id = block['id'];
        final name = block['name'];
        final input = block['input'];
        if (id is String && name is String) {
          toolUseRequests.add(
            AnthropicToolUseRequest(
              id: id,
              name: name,
              input: input is Map<String, Object?>
                  ? Map<String, Object?>.from(input)
                  : const <String, Object?>{},
            ),
          );
        }
      }
    }

    final usage = decoded['usage'];
    var inputTokens = 0;
    var outputTokens = 0;
    if (usage is Map<String, Object?>) {
      final input = usage['input_tokens'];
      if (input is int) inputTokens = input;
      final output = usage['output_tokens'];
      if (output is int) outputTokens = output;
    }

    return AnthropicToolUseTurn(
      stopReason: stopReason,
      finalText: textBuffer.toString(),
      toolUseRequests: List<AnthropicToolUseRequest>.unmodifiable(
        toolUseRequests,
      ),
      assistantContentBlocks: List<Object?>.unmodifiable(content),
      inputTokens: inputTokens,
      outputTokens: outputTokens,
    );
  };
}

/// Encodes an [AnthropicToolResult] into a Messages-API `tool_result`
/// content block. Exposed (not private) so the engine in
/// `advisor_agentic_answer_part.dart` — a DIFFERENT library — can build
/// the follow-up `user` turn without re-deriving the wire shape.
///
/// The result payload is serialized to a JSON STRING (Anthropic accepts
/// a string or a content-block array for `content`; the string form is
/// deterministic and avoids ambiguity about nested block types).
Map<String, Object?> anthropicToolResultBlock(AnthropicToolResult result) {
  final block = <String, Object?>{
    'type': 'tool_result',
    'tool_use_id': result.toolUseId,
    'content': jsonEncode(result.content),
  };
  if (result.isError) {
    block['is_error'] = true;
  }
  return block;
}
