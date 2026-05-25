// Advisor Knowledge Activation — Slice A4.1.
//
// `AdvisorAgenticAnswerEngine` — a bounded tool-use loop that produces
// the advisor's answer by letting Claude call injected tools (retrieval
// in A4.2, operational lookups in A4.6) and then synthesizing a final,
// recommendation-only answer with real source citations.
//
// This is a Dart `part of advisor_proxy.dart`, so it shares the
// library's imports and private scope. The tool-use WIRE adapter and
// its value types live in the standalone, import-independent sibling
// `anthropic_tool_use_complete_fn.dart`, which the monolith imports (one
// line). The engine itself does NO network or DB I/O — every tool is an
// injected `ToolHandler`, and the Anthropic round-trip is an injected
// `AnthropicToolUseCompleteFn`. That keeps the engine trivially fakeable
// and lets A4.2's retrieval tool + A4.6's operational tools plug in
// WITHOUT changing this file.
//
// What this slice DELIBERATELY does NOT do (all A4.2+): no HTTP route,
// no `routeRequest` dispatch, no bootstrap wiring, no real tool
// handlers. The engine is self-contained here; the monolith grows by
// only the `part` + `import` declarations.
//
// Hard Promise #6 (advisor speaks in recommendations, never commands,
// never acts on the operator's behalf): the system prompt
// [AdvisorAgenticAnswerEngine.defaultSystemPrompt] pins that voice and
// the no-fabrication / cite-sources / graceful-"no methodology yet"
// rules. The engine cannot itself take an action — it only calls
// read-shaped tool handlers and returns text.

part of 'advisor_proxy.dart';

/// A tool the agentic engine can run. Receives the model-produced
/// `input` object and returns a JSON-able result map that the engine
/// hands back to Claude as a `tool_result`.
///
/// Handlers are injected (A4.2 retrieval, A4.6 operational lookups), so
/// the engine performs no I/O of its own. A handler that wants its
/// returned data to be citable should include a `sources` key — see
/// [AdvisorAgenticAnswerEngine] / [AdvisorAnswerCitation].
typedef ToolHandler =
    Future<Map<String, Object?>> Function(Map<String, Object?> input);

/// A single prior conversation turn, prepended to the agentic loop's
/// messages. Designed in NOW for forward-compat with A4.7 advisor
/// memory; A4.1 exercises the loop with this empty.
typedef AdvisorPriorTurn = ({String role, String content});

/// One citation surfaced by the agentic answer. Maps to a REAL source a
/// tool returned (never fabricated): the engine only emits a citation
/// for a `sources` entry a `ToolHandler` actually produced.
class AdvisorAnswerCitation {
  const AdvisorAnswerCitation({
    required this.sourceId,
    required this.toolName,
    this.title,
    this.snippet,
  });

  /// Stable identifier of the source (e.g. a corpus `chunk_id` /
  /// `doc_id` from the A4.2 retrieval tool). Load-bearing: this is what
  /// ties the citation to a real retrieved artifact.
  final String sourceId;

  /// Name of the tool that surfaced this source.
  final String toolName;

  /// Optional human-readable source title (e.g. heading path).
  final String? title;

  /// Optional short excerpt of the source text.
  final String? snippet;

  Map<String, Object?> toJson() => <String, Object?>{
        'source_id': sourceId,
        'tool_name': toolName,
        if (title != null) 'title': title,
        if (snippet != null) 'snippet': snippet,
      };
}

/// Result of a single agentic answer run.
class AdvisorAgenticAnswerResult {
  const AdvisorAgenticAnswerResult({
    required this.answer,
    required this.citations,
    required this.toolCallsInvoked,
    required this.totalInputTokens,
    required this.totalOutputTokens,
    required this.modelUsed,
    required this.hitIterationCap,
  });

  /// The advisor's final text answer (recommendation-only voice).
  final String answer;

  /// Real sources surfaced by tool calls, in first-seen order, deduped
  /// by `sourceId`.
  final List<AdvisorAnswerCitation> citations;

  /// Names of the tools the model actually invoked, in invocation order
  /// (a tool may appear more than once).
  final List<String> toolCallsInvoked;

  /// Summed input tokens across ALL Anthropic round-trips (metering).
  final int totalInputTokens;

  /// Summed output tokens across ALL Anthropic round-trips (metering).
  final int totalOutputTokens;

  /// Model id used for the run (Haiku default; Sonnet for nuanced).
  final String modelUsed;

  /// True when the loop hit [AdvisorAgenticAnswerEngine.maxToolRounds]
  /// and was forced into a final synthesis turn (no infinite loop).
  final bool hitIterationCap;
}

/// Runs a bounded multi-turn tool-use loop against an injected
/// [AnthropicToolUseCompleteFn]:
///
///   1. Seed `messages` with [priorTurns] (forward-compat memory) then
///      the operator's question.
///   2. Up to [maxToolRounds] times: call the gateway with the tool
///      catalog. If `stop_reason == tool_use`, run each requested tool's
///      handler, append the assistant turn + a `tool_result` user turn,
///      record citations + invoked tool names, and continue.
///   3. If the model produces a terminal (non-`tool_use`) turn, that
///      text is the answer.
///   4. If the cap is hit while the model still wants tools, force ONE
///      final synthesis turn with `tool_choice: {type:'none'}` so the
///      model must answer from what it has (no infinite loop).
///
/// The engine never performs I/O directly: tools are injected handlers
/// and the Anthropic call is an injected function. This is the seam
/// A4.2 (retrieval tool) and A4.6 (operational tools) plug into without
/// touching the engine.
class AdvisorAgenticAnswerEngine {
  AdvisorAgenticAnswerEngine({
    required AnthropicToolUseCompleteFn completeFn,
    required this.modelId,
    required List<AnthropicToolDefinition> toolDefinitions,
    required Map<String, ToolHandler> toolHandlers,
    this.systemPrompt = defaultSystemPrompt,
    this.maxToolRounds = defaultMaxToolRounds,
  })  : _completeFn = completeFn,
        _toolDefinitions =
            List<AnthropicToolDefinition>.unmodifiable(toolDefinitions),
        _toolHandlers = Map<String, ToolHandler>.unmodifiable(toolHandlers);

  /// Default cap on tool round-trips before a forced synthesis turn.
  /// Four rounds is enough for retrieve -> (optional) refine -> answer
  /// without letting a misbehaving model loop forever.
  static const int defaultMaxToolRounds = 4;

  /// Recommendation-only system prompt (HP #6). Pins: recommend don't
  /// command; never act on the operator's behalf; never fabricate; cite
  /// sources the tools returned; and give a graceful "I don't have
  /// methodology on that yet" when the tools return nothing relevant.
  ///
  /// No em dash anywhere (UX no-em-dash law); this string is operator-
  /// facing methodology even though A4.1 does not yet render it.
  static const String defaultSystemPrompt =
      'You are the Forge and Flow advisor. You help restaurant operators '
      'understand their labor and sales metrics and decide what to do '
      'next.\n'
      '\n'
      'Voice and boundaries:\n'
      '- Recommend, do not command. Offer options and tradeoffs and let '
      'the operator decide. Use phrasing like "you could consider" or '
      '"one option is", never "do this" or "I have changed".\n'
      '- Never act on the operator behalf. You cannot edit schedules, '
      'change targets, or take any action. You only explain and advise.\n'
      '- Never fabricate. Use only what the tools return. If a number or '
      'fact is not in the tool results, say you do not have it rather '
      'than guessing.\n'
      '- Cite your sources. When you use information a tool returned, '
      'refer to it so the operator can trace the recommendation back to '
      'real data.\n'
      '- If the tools return nothing relevant, say plainly: "I do not '
      'have methodology on that yet." Do not invent an answer.\n'
      '\n'
      'Use the available tools to gather what you need before you '
      'answer. When you have enough, give a clear, plain-English '
      'recommendation.';

  final AnthropicToolUseCompleteFn _completeFn;

  /// Anthropic model id for this run.
  final String modelId;

  final List<AnthropicToolDefinition> _toolDefinitions;
  final Map<String, ToolHandler> _toolHandlers;

  /// System prompt threaded into every round-trip.
  final String systemPrompt;

  /// Cap on tool round-trips before a forced synthesis turn.
  final int maxToolRounds;

  /// Runs the agentic loop for [question]. [priorTurns] (default empty)
  /// is prepended for forward-compat memory (A4.7).
  Future<AdvisorAgenticAnswerResult> answer(
    String question, {
    List<AdvisorPriorTurn> priorTurns = const <AdvisorPriorTurn>[],
  }) async {
    // Running conversation accumulator. `content` is a String for plain
    // user/assistant turns and a content-block array for assistant
    // tool_use turns and user tool_result turns.
    final messages = <Map<String, Object?>>[
      for (final turn in priorTurns)
        <String, Object?>{'role': turn.role, 'content': turn.content},
      <String, Object?>{'role': 'user', 'content': question},
    ];

    final toolCallsInvoked = <String>[];
    final citations = <AdvisorAnswerCitation>[];
    final seenSourceIds = <String>{};
    var totalInputTokens = 0;
    var totalOutputTokens = 0;
    var hitIterationCap = false;

    // One extra synthesis turn is allowed AFTER the last tool round, so
    // the loop bound is maxToolRounds tool-bearing turns + 1 forced
    // terminal turn.
    AnthropicToolUseTurn? lastTurn;
    for (var round = 0; round <= maxToolRounds; round++) {
      final isForcedSynthesis = round == maxToolRounds;
      final turn = await _completeFn(
        modelId: modelId,
        system: systemPrompt,
        messages: messages,
        // On the forced-synthesis turn we still pass the catalog but
        // disable tool use so the model MUST answer with text. Anthropic
        // `tool_choice {type:'none'}` means "do not call a tool".
        tools: _toolDefinitions,
        toolChoice: isForcedSynthesis
            ? const <String, Object?>{'type': 'none'}
            : const <String, Object?>{'type': 'auto'},
      );
      totalInputTokens += turn.inputTokens;
      totalOutputTokens += turn.outputTokens;
      lastTurn = turn;

      if (!turn.wantsToolUse) {
        // Terminal turn — the model produced its final answer.
        return AdvisorAgenticAnswerResult(
          answer: turn.finalText,
          citations: List<AdvisorAnswerCitation>.unmodifiable(citations),
          toolCallsInvoked: List<String>.unmodifiable(toolCallsInvoked),
          totalInputTokens: totalInputTokens,
          totalOutputTokens: totalOutputTokens,
          modelUsed: modelId,
          hitIterationCap: hitIterationCap,
        );
      }

      if (isForcedSynthesis) {
        // The model wanted more tools even on the no-tools turn. Stop
        // here with whatever text it produced; never loop again.
        hitIterationCap = true;
        break;
      }

      // Append the assistant's tool_use turn verbatim (Anthropic
      // requires the prior tool_use blocks for the follow-up to
      // validate), then run each handler and append one user turn
      // carrying all tool_result blocks.
      messages.add(<String, Object?>{
        'role': 'assistant',
        'content': turn.assistantContentBlocks,
      });

      final resultBlocks = <Map<String, Object?>>[];
      for (final request in turn.toolUseRequests) {
        toolCallsInvoked.add(request.name);
        final handler = _toolHandlers[request.name];
        if (handler == null) {
          // Unknown tool: surface an error result so the model can
          // recover gracefully rather than hang. Not fabricated data.
          resultBlocks.add(
            anthropicToolResultBlock(
              AnthropicToolResult(
                toolUseId: request.id,
                content: <String, Object?>{
                  'error': 'unknown_tool',
                  'message': 'No handler is registered for tool '
                      '"${request.name}".',
                },
                isError: true,
              ),
            ),
          );
          continue;
        }

        Map<String, Object?> handlerResult;
        var handlerErrored = false;
        try {
          handlerResult = await handler(request.input);
        } catch (e) {
          // A tool failure is surfaced as an is_error result, not
          // thrown — the model is told the tool failed and can fall
          // back to the graceful no-methodology answer.
          handlerResult = <String, Object?>{
            'error': 'tool_failed',
            'message': 'The "${request.name}" tool failed.',
          };
          handlerErrored = true;
        }

        if (!handlerErrored) {
          _collectCitations(
            toolName: request.name,
            result: handlerResult,
            citations: citations,
            seenSourceIds: seenSourceIds,
          );
        }

        resultBlocks.add(
          anthropicToolResultBlock(
            AnthropicToolResult(
              toolUseId: request.id,
              content: handlerResult,
              isError: handlerErrored,
            ),
          ),
        );
      }

      messages.add(<String, Object?>{
        'role': 'user',
        'content': resultBlocks,
      });
    }

    // Loop exited via the iteration cap (the model kept asking for
    // tools). Return the last text the model produced so the caller
    // still gets a usable, non-fabricated answer.
    return AdvisorAgenticAnswerResult(
      answer: lastTurn?.finalText ?? '',
      citations: List<AdvisorAnswerCitation>.unmodifiable(citations),
      toolCallsInvoked: List<String>.unmodifiable(toolCallsInvoked),
      totalInputTokens: totalInputTokens,
      totalOutputTokens: totalOutputTokens,
      modelUsed: modelId,
      hitIterationCap: hitIterationCap,
    );
  }

  /// Extracts citable sources from a tool result. A handler signals
  /// citable data by returning a `sources` list of maps, each with at
  /// least a stable id under `source_id` / `id` / `chunk_id` / `doc_id`
  /// (first present wins). Optional `title` / `heading_path` and
  /// `snippet` / `text` enrich the citation. Entries without a usable id
  /// are skipped (no fabricated citations). Dedupes by id across the
  /// whole run.
  static void _collectCitations({
    required String toolName,
    required Map<String, Object?> result,
    required List<AdvisorAnswerCitation> citations,
    required Set<String> seenSourceIds,
  }) {
    final sources = result['sources'];
    if (sources is! List) return;
    for (final raw in sources) {
      if (raw is! Map) continue;
      final source = raw.cast<Object?, Object?>();
      final sourceId = _firstString(
        source,
        const <String>['source_id', 'id', 'chunk_id', 'doc_id'],
      );
      if (sourceId == null || sourceId.isEmpty) continue;
      if (!seenSourceIds.add(sourceId)) continue;
      citations.add(
        AdvisorAnswerCitation(
          sourceId: sourceId,
          toolName: toolName,
          title: _firstString(
            source,
            const <String>['title', 'heading_path'],
          ),
          snippet: _firstString(source, const <String>['snippet', 'text']),
        ),
      );
    }
  }

  /// Returns the first non-null String value among [keys] in [map].
  static String? _firstString(Map<Object?, Object?> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String) return value;
    }
    return null;
  }
}
