// Advisor Knowledge Activation — Slice A4.1.
//
// Unit tests for `AdvisorAgenticAnswerEngine`. FAKES ONLY: a scripted
// `AnthropicToolUseCompleteFn` closure stands in for the Anthropic
// round-trip (returns a tool_use turn, then a final text turn), and
// `ToolHandler`s return canned data. No HTTP, no Postgres, no real
// Anthropic call.
//
// Proves:
//   (a) the loop runs the requested tool, then synthesizes a final
//       answer from the tool result;
//   (b) the loop terminates at the iteration cap when the model keeps
//       asking for tools (no infinite loop);
//   (c) citations map to the tool-provided sources (and only real ones);
//   (d) the recommendation-only system prompt is present and carries NO
//       imperative / action-taking language;
//   (e) input/output token totals are summed across ALL round-trips.

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/advisor_proxy.dart';
import '../../../tool/advisor_proxy/anthropic_tool_use_complete_fn.dart';

/// Builds a terminal (final-text) turn with the given usage.
AnthropicToolUseTurn _textTurn(
  String text, {
  int inputTokens = 0,
  int outputTokens = 0,
  String stopReason = 'end_turn',
}) {
  return AnthropicToolUseTurn(
    stopReason: stopReason,
    finalText: text,
    toolUseRequests: const <AnthropicToolUseRequest>[],
    assistantContentBlocks: <Object?>[
      <String, Object?>{'type': 'text', 'text': text},
    ],
    inputTokens: inputTokens,
    outputTokens: outputTokens,
  );
}

/// Builds a `tool_use` turn requesting one tool call.
AnthropicToolUseTurn _toolUseTurn({
  required String toolUseId,
  required String toolName,
  Map<String, Object?> input = const <String, Object?>{},
  int inputTokens = 0,
  int outputTokens = 0,
}) {
  final block = <String, Object?>{
    'type': 'tool_use',
    'id': toolUseId,
    'name': toolName,
    'input': input,
  };
  return AnthropicToolUseTurn(
    stopReason: 'tool_use',
    finalText: '',
    toolUseRequests: <AnthropicToolUseRequest>[
      AnthropicToolUseRequest(id: toolUseId, name: toolName, input: input),
    ],
    assistantContentBlocks: <Object?>[block],
    inputTokens: inputTokens,
    outputTokens: outputTokens,
  );
}

/// A scripted gateway: returns the next turn from [script] on each call,
/// and records the messages/tools/toolChoice it was handed so tests can
/// assert what the engine sent.
class _ScriptedGateway {
  _ScriptedGateway(this.script);

  final List<AnthropicToolUseTurn> script;
  int callCount = 0;
  final List<List<Map<String, Object?>>> messagesPerCall =
      <List<Map<String, Object?>>>[];
  final List<Map<String, Object?>?> toolChoicePerCall =
      <Map<String, Object?>?>[];
  final List<String?> systemPerCall = <String?>[];

  AnthropicToolUseCompleteFn get fn => ({
        required String modelId,
        String? system,
        required List<Map<String, Object?>> messages,
        required List<AnthropicToolDefinition> tools,
        Map<String, Object?>? toolChoice,
      }) async {
        // Deep-ish snapshot of messages (the engine mutates the live
        // list between calls).
        messagesPerCall.add(
          List<Map<String, Object?>>.from(
            messages.map((m) => Map<String, Object?>.from(m)),
          ),
        );
        toolChoicePerCall.add(toolChoice);
        systemPerCall.add(system);
        final turn = script[callCount];
        callCount++;
        return turn;
      };
}

const AnthropicToolDefinition _retrieveTool = AnthropicToolDefinition(
  name: 'retrieve_methodology',
  description: 'Retrieve labor and sales methodology relevant to the '
      'operator question.',
  inputSchema: <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'query': <String, Object?>{'type': 'string'},
    },
    'required': <String>['query'],
  },
);

void main() {
  group('AdvisorAgenticAnswerEngine', () {
    test('(a) runs the requested tool then synthesizes a final answer',
        () async {
      final gateway = _ScriptedGateway(<AnthropicToolUseTurn>[
        _toolUseTurn(
          toolUseId: 'toolu_1',
          toolName: 'retrieve_methodology',
          input: <String, Object?>{'query': 'why is CPLH up?'},
        ),
        _textTurn(
          'You could consider reviewing your prep-shift staffing; one '
          'option is trimming the early shift.',
        ),
      ]);

      var handlerCalls = 0;
      Map<String, Object?>? handlerSawInput;
      final engine = AdvisorAgenticAnswerEngine(
        completeFn: gateway.fn,
        modelId: 'claude-haiku-4-5',
        toolDefinitions: const <AnthropicToolDefinition>[_retrieveTool],
        toolHandlers: <String, ToolHandler>{
          'retrieve_methodology': (input) async {
            handlerCalls++;
            handlerSawInput = input;
            return <String, Object?>{
              'sources': <Map<String, Object?>>[
                <String, Object?>{
                  'chunk_id': 'chunk_42',
                  'heading_path': 'Labor > CPLH',
                  'text': 'CPLH rises when scheduled hours outpace sales.',
                },
              ],
            };
          },
        },
      );

      final result = await engine.answer('Why is my CPLH up this week?');

      // The tool ran once, with the model-produced input.
      expect(handlerCalls, equals(1));
      expect(handlerSawInput, equals(<String, Object?>{'query': 'why is CPLH up?'}));
      // Two round-trips: tool_use turn + synthesis turn.
      expect(gateway.callCount, equals(2));
      // Final answer is the synthesized text (recommendation framing).
      expect(result.answer, contains('You could consider'));
      expect(result.answer, contains('one option is'));
      expect(result.toolCallsInvoked, equals(<String>['retrieve_methodology']));
      expect(result.hitIterationCap, isFalse);
      expect(result.modelUsed, equals('claude-haiku-4-5'));

      // Second call's messages must include the assistant tool_use turn
      // and the user tool_result turn the engine appended.
      final secondCallMessages = gateway.messagesPerCall[1];
      expect(secondCallMessages.length, equals(3));
      expect(secondCallMessages[0]['role'], equals('user'));
      expect(secondCallMessages[1]['role'], equals('assistant'));
      expect(secondCallMessages[2]['role'], equals('user'));
      final toolResultContent = secondCallMessages[2]['content'] as List<Object?>;
      final resultBlock = toolResultContent.single as Map<String, Object?>;
      expect(resultBlock['type'], equals('tool_result'));
      expect(resultBlock['tool_use_id'], equals('toolu_1'));
      // The tool_result content carries the canned data, not fabricated.
      expect(resultBlock['content'], contains('chunk_42'));
    });

    test('(b) terminates at the iteration cap when the model keeps '
        'requesting tools (no infinite loop)', () async {
      // Every scripted turn is a tool_use turn. With maxToolRounds = 2,
      // the engine makes 2 tool-bearing calls + 1 forced synthesis call
      // = 3 calls total, then stops even though the model still wants a
      // tool on the forced turn.
      final gateway = _ScriptedGateway(<AnthropicToolUseTurn>[
        _toolUseTurn(toolUseId: 'toolu_1', toolName: 'retrieve_methodology'),
        _toolUseTurn(toolUseId: 'toolu_2', toolName: 'retrieve_methodology'),
        // Forced-synthesis turn: model STILL asks for a tool (worst case).
        _toolUseTurn(toolUseId: 'toolu_3', toolName: 'retrieve_methodology'),
        // This 4th turn must never be reached.
        _textTurn('unreachable'),
      ]);

      var handlerCalls = 0;
      final engine = AdvisorAgenticAnswerEngine(
        completeFn: gateway.fn,
        modelId: 'claude-haiku-4-5',
        toolDefinitions: const <AnthropicToolDefinition>[_retrieveTool],
        toolHandlers: <String, ToolHandler>{
          'retrieve_methodology': (input) async {
            handlerCalls++;
            return <String, Object?>{'sources': const <Object?>[]};
          },
        },
        maxToolRounds: 2,
      );

      final result = await engine.answer('keep going');

      expect(result.hitIterationCap, isTrue);
      // 3 calls: round 0 (tool), round 1 (tool), round 2 (forced, no-tool
      // request honored as a stop). The 4th scripted turn is untouched.
      expect(gateway.callCount, equals(3));
      // Handlers ran only on the two tool-bearing rounds (the forced
      // synthesis turn's tool request is NOT executed).
      expect(handlerCalls, equals(2));
      // The forced-synthesis (last) call disabled tools.
      expect(
        gateway.toolChoicePerCall.last,
        equals(<String, Object?>{'type': 'none'}),
      );
      // Earlier calls allowed tools.
      expect(
        gateway.toolChoicePerCall.first,
        equals(<String, Object?>{'type': 'auto'}),
      );
    });

    test('(c) citations map to the tool-provided sources (deduped, real '
        'ids only)', () async {
      final gateway = _ScriptedGateway(<AnthropicToolUseTurn>[
        _toolUseTurn(toolUseId: 'toolu_1', toolName: 'retrieve_methodology'),
        _textTurn('You could review the prep schedule.'),
      ]);

      final engine = AdvisorAgenticAnswerEngine(
        completeFn: gateway.fn,
        modelId: 'claude-haiku-4-5',
        toolDefinitions: const <AnthropicToolDefinition>[_retrieveTool],
        toolHandlers: <String, ToolHandler>{
          'retrieve_methodology': (input) async {
            return <String, Object?>{
              'sources': <Object?>[
                <String, Object?>{
                  'chunk_id': 'chunk_1',
                  'heading_path': 'Labor > Prep',
                  'text': 'Prep labor leads sales by 30 minutes.',
                },
                // Duplicate id — must be deduped.
                <String, Object?>{
                  'chunk_id': 'chunk_1',
                  'text': 'dup',
                },
                <String, Object?>{
                  'chunk_id': 'chunk_2',
                  'title': 'Sales pacing',
                },
                // No usable id — must be skipped (no fabricated citation).
                <String, Object?>{'text': 'orphan with no id'},
              ],
            };
          },
        },
      );

      final result = await engine.answer('prep?');

      expect(result.citations.length, equals(2));
      expect(
        result.citations.map((c) => c.sourceId).toList(),
        equals(<String>['chunk_1', 'chunk_2']),
      );
      final first = result.citations.first;
      expect(first.toolName, equals('retrieve_methodology'));
      expect(first.title, equals('Labor > Prep'));
      expect(first.snippet, equals('Prep labor leads sales by 30 minutes.'));
      // Every citation traces to a real source id the tool returned.
      for (final c in result.citations) {
        expect(c.sourceId, isNotEmpty);
      }
    });

    test('(d) recommendation-only system prompt is present with NO '
        'imperative / action-taking language', () async {
      final gateway = _ScriptedGateway(<AnthropicToolUseTurn>[
        _textTurn('You could consider trimming the early shift.'),
      ]);

      final engine = AdvisorAgenticAnswerEngine(
        completeFn: gateway.fn,
        modelId: 'claude-haiku-4-5',
        toolDefinitions: const <AnthropicToolDefinition>[_retrieveTool],
        toolHandlers: const <String, ToolHandler>{},
      );

      await engine.answer('what should I do?');

      final system = gateway.systemPerCall.single;
      expect(system, isNotNull);
      final prompt = system!;

      // Recommendation framing IS present.
      expect(prompt.toLowerCase(), contains('recommend'));
      expect(prompt, contains('I do not have methodology on that yet'));
      expect(prompt.toLowerCase(), contains('cite'));
      expect(prompt.toLowerCase(), contains('never fabricate'));

      // NO imperative / action-taking strings. The advisor advises; it
      // never claims to act on the operator's behalf (HP#6). We check
      // the default prompt does not contain affirmative action claims.
      const forbidden = <String>[
        'I have changed',
        'I changed',
        'I will change',
        'I updated',
        'I have updated',
        'I edited',
        'I have scheduled',
        'on your behalf I',
        'I will edit',
        'I have set',
      ];
      for (final phrase in forbidden) {
        expect(
          prompt.toLowerCase().contains(phrase.toLowerCase()),
          isFalse,
          reason: 'system prompt must not contain action-taking phrase: '
              '"$phrase"',
        );
      }

      // The default prompt is also exposed as a const for callers/tests.
      expect(
        AdvisorAgenticAnswerEngine.defaultSystemPrompt,
        equals(prompt),
      );
    });

    test('(e) token totals are summed across ALL round-trips', () async {
      final gateway = _ScriptedGateway(<AnthropicToolUseTurn>[
        _toolUseTurn(
          toolUseId: 'toolu_1',
          toolName: 'retrieve_methodology',
          inputTokens: 100,
          outputTokens: 20,
        ),
        _toolUseTurn(
          toolUseId: 'toolu_2',
          toolName: 'retrieve_methodology',
          inputTokens: 150,
          outputTokens: 25,
        ),
        _textTurn(
          'You could consider adjusting the schedule.',
          inputTokens: 200,
          outputTokens: 40,
        ),
      ]);

      final engine = AdvisorAgenticAnswerEngine(
        completeFn: gateway.fn,
        modelId: 'claude-sonnet-4-6',
        toolDefinitions: const <AnthropicToolDefinition>[_retrieveTool],
        toolHandlers: <String, ToolHandler>{
          'retrieve_methodology': (input) async =>
              <String, Object?>{'sources': const <Object?>[]},
        },
        maxToolRounds: 4,
      );

      final result = await engine.answer('summarize');

      // 3 round-trips total: 100+150+200 input, 20+25+40 output.
      expect(gateway.callCount, equals(3));
      expect(result.totalInputTokens, equals(450));
      expect(result.totalOutputTokens, equals(85));
      expect(result.modelUsed, equals('claude-sonnet-4-6'));
      expect(result.hitIterationCap, isFalse);
    });

    test('priorTurns are prepended for forward-compat memory (A4.7)',
        () async {
      final gateway = _ScriptedGateway(<AnthropicToolUseTurn>[
        _textTurn('You could revisit last week plan.'),
      ]);

      final engine = AdvisorAgenticAnswerEngine(
        completeFn: gateway.fn,
        modelId: 'claude-haiku-4-5',
        toolDefinitions: const <AnthropicToolDefinition>[_retrieveTool],
        toolHandlers: const <String, ToolHandler>{},
      );

      await engine.answer(
        'and this week?',
        priorTurns: const <AdvisorPriorTurn>[
          (role: 'user', content: 'how was last week?'),
          (role: 'assistant', content: 'Last week CPLH held steady.'),
        ],
      );

      final firstCallMessages = gateway.messagesPerCall.single;
      expect(firstCallMessages.length, equals(3));
      expect(firstCallMessages[0]['content'], equals('how was last week?'));
      expect(
        firstCallMessages[1]['content'],
        equals('Last week CPLH held steady.'),
      );
      expect(firstCallMessages[2]['content'], equals('and this week?'));
    });

    test('a failing tool handler surfaces an is_error tool_result without '
        'throwing or fabricating', () async {
      final gateway = _ScriptedGateway(<AnthropicToolUseTurn>[
        _toolUseTurn(toolUseId: 'toolu_1', toolName: 'retrieve_methodology'),
        _textTurn('I do not have methodology on that yet.'),
      ]);

      final engine = AdvisorAgenticAnswerEngine(
        completeFn: gateway.fn,
        modelId: 'claude-haiku-4-5',
        toolDefinitions: const <AnthropicToolDefinition>[_retrieveTool],
        toolHandlers: <String, ToolHandler>{
          'retrieve_methodology': (input) async {
            throw StateError('retrieval backend down');
          },
        },
      );

      final result = await engine.answer('anything?');

      // No citations (the tool failed; nothing real to cite).
      expect(result.citations, isEmpty);
      // The error tool_result was appended to the follow-up turn.
      final secondCallMessages = gateway.messagesPerCall[1];
      final toolResultContent =
          secondCallMessages[2]['content'] as List<Object?>;
      final resultBlock = toolResultContent.single as Map<String, Object?>;
      expect(resultBlock['is_error'], isTrue);
      expect(result.answer, contains('I do not have methodology'));
    });
  });
}
