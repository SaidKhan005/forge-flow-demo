// Advisor Knowledge Activation — Slice D1 client tests.
//
// FAKES-ONLY: a `package:http/testing.dart` MockClient stands in for the
// network, so these tests never touch a live proxy. They prove the live impl's
// REQUEST shape (POST path + Bearer header + JSON body), its 200 PARSE into an
// `AdvisorAnswerResult`, its mapping of every server fail-closed state to the
// correct typed `AdvisorAnswerStatus`, that `conversationId` threads into the
// body on a follow-up turn, and that the Demo impl returns sample data with NO
// network call.
//
// The 200 fixture mirrors the server success envelope written by
// `tool/advisor_proxy/advisor_answer_route_group_part.dart`.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/services/advisor/advisor_answer_gateway.dart';

void main() {
  // ── 200 success envelope (mirrors the A4.2b route) ─────────────────────────
  Map<String, Object?> answerPayload({
    String answer =
        'You could consider trimming the early prep shift by an hour.',
    String conversationId = '11111111-1111-4111-8111-111111111111',
    int turnIndex = 1,
    List<Map<String, Object?>>? citations,
  }) {
    return <String, Object?>{
      'answer': answer,
      'citations': citations ??
          <Map<String, Object?>>[
            <String, Object?>{
              'source_id': 'target_cycle:aaaa',
              'tool_name': 'get_active_targets',
              'title': 'Active target cycle',
              'snippet': 'Target CPLH 8.0.',
            },
          ],
      'conversation_id': conversationId,
      'turn_index': turnIndex,
      'tool_calls': <String>['get_active_targets'],
      'model_used': 'claude-haiku-4-5',
      'usage_class': 'advisor_answer',
      'query_class': 'methodology_lookup',
      'hit_iteration_cap': false,
      'operator_id': '22222222-2222-4222-8222-222222222222',
      'location_id': '33333333-3333-4333-8333-333333333333',
    };
  }

  // Builds a live gateway whose MockClient records every request and returns a
  // scripted (status, body) per call. `proxyBaseUri` + `idTokenProvider` are
  // INJECTED — never hardcoded inside the gateway.
  ({
    AdvisorAnswerGatewayLive gateway,
    List<http.Request> requests,
  }) buildLive({
    String? token = 'demo-id-token',
    int status = 200,
    Map<String, Object?>? body,
    List<({int status, Map<String, Object?> body})>? scripted,
    bool throwTransport = false,
  }) {
    final requests = <http.Request>[];
    var index = 0;
    final mock = MockClient((request) async {
      requests.add(request);
      if (throwTransport) {
        throw http.ClientException('connection refused', request.url);
      }
      if (scripted != null) {
        final step = scripted[index];
        index++;
        return http.Response(
          jsonEncode(step.body),
          step.status,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode(body ?? answerPayload()),
        status,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    });
    final gateway = AdvisorAnswerGatewayLive(
      proxyBaseUri: Uri.parse('https://proxy.test/'),
      idTokenProvider: () async => token,
      httpClient: mock,
    );
    return (gateway: gateway, requests: requests);
  }

  group('AdvisorAnswerGatewayLive — request shape', () {
    test('POSTs to /v1/advisor/answer with Bearer header and {question} body',
        () async {
      final harness = buildLive();
      await harness.gateway.ask(question: 'Why is my CPLH high?');

      final request = harness.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, kAdvisorAnswerPath);
      expect(request.url.path, '/v1/advisor/answer');
      expect(request.headers['authorization'], 'Bearer demo-id-token');
      expect(request.headers['content-type'], contains('application/json'));

      final sentBody = jsonDecode(request.body) as Map<String, Object?>;
      expect(sentBody['question'], 'Why is my CPLH high?');
      // No conversation_id on a fresh turn.
      expect(sentBody.containsKey('conversation_id'), isFalse);
    });

    test('threads conversationId into the body on a follow-up turn', () async {
      final harness = buildLive();
      await harness.gateway.ask(
        question: 'And this week?',
        conversationId: '11111111-1111-4111-8111-111111111111',
      );

      final sentBody =
          jsonDecode(harness.requests.single.body) as Map<String, Object?>;
      expect(sentBody['question'], 'And this week?');
      expect(
        sentBody['conversation_id'],
        '11111111-1111-4111-8111-111111111111',
      );
    });

    test('a refreshed token is read on every call (token provider awaited)',
        () async {
      // First call sees token A, second sees token B: prove the provider is
      // awaited per request rather than captured once at construction.
      final tokens = <String>['token-A', 'token-B'];
      var call = 0;
      final requests = <http.Request>[];
      final mock = MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(answerPayload()),
          200,
          headers: const <String, String>{'content-type': 'application/json'},
        );
      });
      final gateway = AdvisorAnswerGatewayLive(
        proxyBaseUri: Uri.parse('https://proxy.test/'),
        idTokenProvider: () async => tokens[call++],
        httpClient: mock,
      );

      await gateway.ask(question: 'one');
      await gateway.ask(question: 'two');

      expect(requests[0].headers['authorization'], 'Bearer token-A');
      expect(requests[1].headers['authorization'], 'Bearer token-B');
    });

    test('no token → notSwitchedOn and NO network call', () async {
      final harness = buildLive(token: null);
      await expectLater(
        harness.gateway.ask(question: 'hi'),
        throwsA(
          isA<AdvisorAnswerException>().having(
            (e) => e.status,
            'status',
            AdvisorAnswerStatus.notSwitchedOn,
          ),
        ),
      );
      expect(harness.requests, isEmpty);
    });
  });

  group('AdvisorAnswerGatewayLive — 200 parse', () {
    test('parses answer + citations + conversation_id + turn_index', () async {
      final harness = buildLive();
      final result = await harness.gateway.ask(question: 'Why is my CPLH high?');

      expect(result.answer,
          'You could consider trimming the early prep shift by an hour.');
      expect(result.conversationId, '11111111-1111-4111-8111-111111111111');
      expect(result.turnIndex, 1);
      expect(result.citations, hasLength(1));
      final citation = result.citations.single;
      expect(citation.sourceId, 'target_cycle:aaaa');
      expect(citation.toolName, 'get_active_targets');
      expect(citation.title, 'Active target cycle');
      expect(citation.snippet, 'Target CPLH 8.0.');
    });

    test('drops a citation with no source_id; keeps well-formed ones',
        () async {
      final harness = buildLive(
        body: answerPayload(citations: <Map<String, Object?>>[
          <String, Object?>{'tool_name': 'get_week_plan'}, // no source_id
          <String, Object?>{
            'source_id': 'week_plan:bbbb',
            'tool_name': 'get_week_plan',
          },
        ]),
      );
      final result = await harness.gateway.ask(question: 'q');
      expect(result.citations, hasLength(1));
      expect(result.citations.single.sourceId, 'week_plan:bbbb');
      // Optional fields absent → null, not empty string.
      expect(result.citations.single.title, isNull);
      expect(result.citations.single.snippet, isNull);
    });

    test('empty citations list parses to an empty result list', () async {
      final harness = buildLive(
        body: answerPayload(citations: const <Map<String, Object?>>[]),
      );
      final result = await harness.gateway.ask(question: 'q');
      expect(result.citations, isEmpty);
    });

    test('malformed 200 (missing answer) → serverError', () async {
      final body = answerPayload()..remove('answer');
      final harness = buildLive(body: body);
      await expectLater(
        harness.gateway.ask(question: 'q'),
        throwsA(
          isA<AdvisorAnswerException>().having(
            (e) => e.status,
            'status',
            AdvisorAnswerStatus.serverError,
          ),
        ),
      );
    });
  });

  group('AdvisorAnswerGatewayLive — fail-closed status mapping', () {
    Future<void> expectStatus({
      required int httpStatus,
      required Map<String, Object?> body,
      required AdvisorAnswerStatus expected,
    }) async {
      final harness = buildLive(status: httpStatus, body: body);
      await expectLater(
        harness.gateway.ask(question: 'q'),
        throwsA(
          isA<AdvisorAnswerException>()
              .having((e) => e.status, 'status', expected),
        ),
      );
    }

    test('503 advisor_answer_encryption_unavailable → notSwitchedOn', () async {
      await expectStatus(
        httpStatus: 503,
        body: const <String, Object?>{
          'error': 'advisor_answer_encryption_unavailable',
          'message': 'unavailable',
        },
        expected: AdvisorAnswerStatus.notSwitchedOn,
      );
    });

    test('503 advisor_answer_not_configured → notConfigured', () async {
      await expectStatus(
        httpStatus: 503,
        body: const <String, Object?>{
          'error': 'advisor_answer_not_configured',
          'message': 'unavailable',
        },
        expected: AdvisorAnswerStatus.notConfigured,
      );
    });

    test('503 generic advisor_answer_unavailable → notSwitchedOn', () async {
      await expectStatus(
        httpStatus: 503,
        body: const <String, Object?>{
          'error': 'advisor_answer_unavailable',
          'message': 'retry',
        },
        expected: AdvisorAnswerStatus.notSwitchedOn,
      );
    });

    test('402 monthly_cap_reached → usageCapReached', () async {
      await expectStatus(
        httpStatus: 402,
        body: const <String, Object?>{'error': 'monthly_cap_reached'},
        expected: AdvisorAnswerStatus.usageCapReached,
      );
    });

    test('500 → serverError', () async {
      await expectStatus(
        httpStatus: 500,
        body: const <String, Object?>{'error': 'internal'},
        expected: AdvisorAnswerStatus.serverError,
      );
    });

    test('401 (insufficient scope / no advisor.read) → serverError', () async {
      await expectStatus(
        httpStatus: 401,
        body: const <String, Object?>{'error': 'unauthorized'},
        expected: AdvisorAnswerStatus.serverError,
      );
    });

    test('transport failure → networkError', () async {
      final harness = buildLive(throwTransport: true);
      await expectLater(
        harness.gateway.ask(question: 'q'),
        throwsA(
          isA<AdvisorAnswerException>().having(
            (e) => e.status,
            'status',
            AdvisorAnswerStatus.networkError,
          ),
        ),
      );
    });
  });

  group('AdvisorAnswerException — calm messages, no jargon, no em dash', () {
    test('every status carries a non-empty plain message with no em dash', () {
      for (final status in AdvisorAnswerStatus.values) {
        final message = AdvisorAnswerException(status).message;
        expect(message, isNotEmpty);
        // UX no-em-dash law: no em dash anywhere in operator-facing copy.
        expect(message.contains('—'), isFalse,
            reason: 'message for ${status.name} must not contain an em dash');
      }
    });

    test('notSwitchedOn message matches the contracted calm wording', () {
      expect(
        const AdvisorAnswerException(AdvisorAnswerStatus.notSwitchedOn).message,
        "The advisor isn't switched on yet.",
      );
    });
  });

  group('AdvisorAnswerGatewayDemo — sample data, no network', () {
    test('returns a recommendation + citations with no HTTP client at all',
        () async {
      // No MockClient is injected: the demo impl must not need one.
      final demo = AdvisorAnswerGatewayDemo();
      final result = await demo.ask(question: 'How am I doing this week?');

      expect(result.answer, contains('you could consider'));
      // HP #6: recommendation voice, never a command. No execute/apply verbs.
      expect(result.answer.toLowerCase(), isNot(contains('apply this')));
      expect(result.citations, isNotEmpty);
      expect(result.citations.first.sourceId, isNotEmpty);
      expect(result.conversationId, isNotEmpty);
      expect(result.turnIndex, 1);
    });

    test('advances the turn index across exchanges and threads conversationId',
        () async {
      final demo = AdvisorAnswerGatewayDemo();
      final first = await demo.ask(question: 'one');
      final second = await demo.ask(
        question: 'two',
        conversationId: first.conversationId,
      );
      expect(first.turnIndex, 1);
      expect(second.turnIndex, 3); // user + assistant per exchange.
      expect(second.conversationId, first.conversationId);
    });

    test('a fixed result is returned verbatim when supplied', () async {
      const fixed = AdvisorAnswerResult(
        answer: 'You could consider X.',
        citations: <AdvisorCitation>[],
        conversationId: 'fixed-convo',
        turnIndex: 7,
      );
      final demo = AdvisorAnswerGatewayDemo(fixedResult: fixed);
      final result = await demo.ask(question: 'anything');
      expect(identical(result, fixed), isTrue);
    });
  });
}
