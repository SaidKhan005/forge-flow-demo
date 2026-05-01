// Forge & Flow — fallback chain tests for AdvisorRequestPipeline.
//
// Lock 7 (Block 2 v1) coverage:
//   - Chain order: primary → cache → graceful refusal.
//   - Locked refusal copy (byte-equal to gracefulRefusalMessage).
//   - `gemini-reserved` is unreachable in v1 (E.2b reserved slot).
//
// Hand-rolled fakes only: no mocktail/mockito.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/services/advisor_response_cache.dart';
import 'package:forge_and_flow/domain/services/circuit_breaker.dart';
import 'package:forge_and_flow/domain/services/graceful_refusal_response.dart';
import 'package:forge_and_flow/domain/services/llm_provider.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

class _FakeProxyLlmProvider implements ProxyLlmProvider {
  _FakeProxyLlmProvider({this.shouldFail = false, this.exception});
  bool shouldFail;
  Object? exception;
  int completeCalls = 0;
  ProxyLlmCompletion? nextResponse;

  @override
  Future<ProxyLlmCompletion> complete(ProxyLlmRequest request) async {
    completeCalls += 1;
    if (shouldFail) {
      throw exception ?? const LLMProviderException(FailureKind.http5xx, 'fake');
    }
    return nextResponse ??
        ProxyLlmCompletion(
          text: 'fake answer',
          modelId: request.modelId,
          tier: request.tier,
          outputTokens: 5,
          costCents: 1,
        );
  }
}

class _CapturingCache implements AdvisorResponseCache {
  String? answerToReturn;
  int lookupCalls = 0;
  Map<String, Object?>? lastLookupArgs;

  @override
  Future<String?> lookup({
    required String operatorId,
    required String locationId,
    required String queryClass,
    required String questionHash,
    required String corpusVersion,
  }) async {
    lookupCalls += 1;
    lastLookupArgs = <String, Object?>{
      'operatorId': operatorId,
      'locationId': locationId,
      'queryClass': queryClass,
      'questionHash': questionHash,
      'corpusVersion': corpusVersion,
    };
    return answerToReturn;
  }
}

ProxyLlmRequest _makeLlmRequest({String question = 'q'}) => ProxyLlmRequest(
      question: question,
      promptBlocks: const <ProxyPromptBlock>[],
      tier: ProxyLlmTier.haiku,
      modelId: 'claude-haiku-4-5',
      cacheKey: 'advisor-corpus:launch_v1',
      maxOutputTokens: 1000,
    );

const String _operatorId = 'op-1';
const String _locationId = 'loc-1';
const String _queryClass = 'recommendation';
const String _questionHash = 'hash-abc';
const String _corpusVersion = 'launch_v1';

void main() {
  group('AdvisorRequestPipeline chain order', () {
    test('primary success → completion served, cache never consulted',
        () async {
      final breaker = CircuitBreaker(providerId: 'anthropic');
      final cache = _CapturingCache();
      final provider = _FakeProxyLlmProvider();
      final pipeline = AdvisorRequestPipeline(breaker: breaker, cache: cache);

      final result = await pipeline.execute(
        llmProvider: provider,
        llmRequest: _makeLlmRequest(),
        operatorId: _operatorId,
        locationId: _locationId,
        queryClass: _queryClass,
        questionHash: _questionHash,
        corpusVersion: _corpusVersion,
      );

      expect(result.completion, isNotNull);
      expect(result.cachedAnswer, isNull);
      expect(result.refused, isFalse);
      expect(result.fallbackUsed, equals('none'));
      expect(result.circuitStateAtStart, equals(CircuitState.closed));
      expect(result.decision, equals(AcquireDecision.allow));
      expect(provider.completeCalls, equals(1));
      expect(cache.lookupCalls, equals(0));
      expect(cache.lastLookupArgs, isNull);
      expect(result.fallbackUsed, isNot(equals('gemini-reserved')));
    });

    test(
        'after 3 consecutive failures (open) → primary skipped, cache miss '
        'returns refusal', () async {
      final breaker = CircuitBreaker(providerId: 'anthropic');
      // Drive the breaker open via direct failure recording (3 consecutive
      // 5xx failures match the default consecutiveFailureThreshold).
      breaker.recordFailure(FailureKind.http5xx);
      breaker.recordFailure(FailureKind.http5xx);
      breaker.recordFailure(FailureKind.http5xx);
      expect(breaker.state, equals(CircuitState.open));

      final cache = _CapturingCache(); // miss by default
      final provider = _FakeProxyLlmProvider();
      final pipeline = AdvisorRequestPipeline(breaker: breaker, cache: cache);

      final result = await pipeline.execute(
        llmProvider: provider,
        llmRequest: _makeLlmRequest(),
        operatorId: _operatorId,
        locationId: _locationId,
        queryClass: _queryClass,
        questionHash: _questionHash,
        corpusVersion: _corpusVersion,
      );

      // Primary must NOT have been called when the breaker is open.
      expect(provider.completeCalls, equals(0));
      // Cache lookup invoked exactly once with the documented key fields.
      expect(cache.lookupCalls, equals(1));
      expect(cache.lastLookupArgs, <String, Object?>{
        'operatorId': _operatorId,
        'locationId': _locationId,
        'queryClass': _queryClass,
        'questionHash': _questionHash,
        'corpusVersion': _corpusVersion,
      });
      expect(result.completion, isNull);
      expect(result.cachedAnswer, isNull);
      expect(result.refused, isTrue);
      expect(result.fallbackUsed, equals('refusal'));
      expect(result.circuitStateAtStart, equals(CircuitState.open));
      expect(result.decision, equals(AcquireDecision.reject));
      expect(result.fallbackUsed, isNot(equals('gemini-reserved')));
    });

    test(
        'after 3 consecutive failures (open) → cache hit returns '
        'cachedAnswer with fallbackUsed == "cache"', () async {
      final breaker = CircuitBreaker(providerId: 'anthropic');
      breaker.recordFailure(FailureKind.http5xx);
      breaker.recordFailure(FailureKind.http5xx);
      breaker.recordFailure(FailureKind.http5xx);
      expect(breaker.state, equals(CircuitState.open));

      final cache = _CapturingCache()..answerToReturn = '<hit>';
      final provider = _FakeProxyLlmProvider();
      final pipeline = AdvisorRequestPipeline(breaker: breaker, cache: cache);

      final result = await pipeline.execute(
        llmProvider: provider,
        llmRequest: _makeLlmRequest(),
        operatorId: _operatorId,
        locationId: _locationId,
        queryClass: _queryClass,
        questionHash: _questionHash,
        corpusVersion: _corpusVersion,
      );

      expect(provider.completeCalls, equals(0));
      expect(cache.lookupCalls, equals(1));
      expect(result.completion, isNull);
      expect(result.cachedAnswer, equals('<hit>'));
      expect(result.refused, isTrue);
      expect(result.fallbackUsed, equals('cache'));
      expect(result.circuitStateAtStart, equals(CircuitState.open));
      expect(result.decision, equals(AcquireDecision.reject));
      expect(result.fallbackUsed, isNot(equals('gemini-reserved')));
    });

    test(
        'three consecutive failures driven via execute() also opens '
        'the breaker', () async {
      final breaker = CircuitBreaker(providerId: 'anthropic');
      final cache = _CapturingCache(); // miss
      // Pass an explicit LLMProviderException so the failure classifies
      // as http5xx (matches recordFailure(http5xx) in the direct-driven
      // test above).
      final provider = _FakeProxyLlmProvider(
        shouldFail: true,
        exception: const LLMProviderException(FailureKind.http5xx, 'fake-5xx'),
      );
      final pipeline = AdvisorRequestPipeline(breaker: breaker, cache: cache);

      // Three failing executes should trip the breaker.
      for (var i = 0; i < 3; i++) {
        await pipeline.execute(
          llmProvider: provider,
          llmRequest: _makeLlmRequest(),
          operatorId: _operatorId,
          locationId: _locationId,
          queryClass: _queryClass,
          questionHash: _questionHash,
          corpusVersion: _corpusVersion,
        );
      }
      expect(breaker.state, equals(CircuitState.open));
      expect(provider.completeCalls, equals(3));

      final invocationsBefore = provider.completeCalls;
      final lookupsBefore = cache.lookupCalls;

      final next = await pipeline.execute(
        llmProvider: provider,
        llmRequest: _makeLlmRequest(),
        operatorId: _operatorId,
        locationId: _locationId,
        queryClass: _queryClass,
        questionHash: _questionHash,
        corpusVersion: _corpusVersion,
      );

      // Provider call count must not increase once the breaker is open.
      expect(provider.completeCalls, equals(invocationsBefore));
      // Cache should have been consulted exactly once on this call.
      expect(cache.lookupCalls, equals(lookupsBefore + 1));
      expect(next.completion, isNull);
      expect(next.cachedAnswer, isNull);
      expect(next.refused, isTrue);
      expect(next.fallbackUsed, equals('refusal'));
      expect(next.fallbackUsed, isNot(equals('gemini-reserved')));
    });
  });

  group('GracefulRefusalResponse locked refusal copy', () {
    test('message is byte-equal to gracefulRefusalMessage (no cached answer)',
        () {
      const refusal = GracefulRefusalResponse(
        cachedAnswer: null,
        providerId: 'anthropic',
        circuitState: 'open',
      );

      final json = refusal.toJson();

      expect(json['message'], equals(gracefulRefusalMessage));
      expect(json['error'], equals('service_degraded'));

      final degraded = json['degraded'] as Map<String, Object?>;
      expect(degraded['provider_id'], equals('anthropic'));
      expect(degraded['circuit_state'], equals('open'));
      expect(degraded['cached_answer'], isNull);
      expect(degraded['retry_after_seconds'], equals(30));
    });

    test('message is byte-equal even when a cached answer is present', () {
      const refusal = GracefulRefusalResponse(
        cachedAnswer: 'previous answer',
        providerId: 'anthropic',
        circuitState: 'open',
      );

      final json = refusal.toJson();

      expect(json['message'], equals(gracefulRefusalMessage));
      expect(json['error'], equals('service_degraded'));

      final degraded = json['degraded'] as Map<String, Object?>;
      expect(degraded['provider_id'], equals('anthropic'));
      expect(degraded['circuit_state'], equals('open'));
      expect(degraded['cached_answer'], equals('previous answer'));
      expect(degraded['retry_after_seconds'], equals(30));
    });
  });

  group('gemini-reserved is no-op in v1', () {
    test(
        'no execute() outcome (closed-success, open-cache-miss, '
        'open-cache-hit, half-open-probe-success) sets fallbackUsed to '
        '"gemini-reserved"', () async {
      final results = <AdvisorPipelineResult>[];

      // ── Closed → success
      {
        final breaker = CircuitBreaker(providerId: 'anthropic');
        final cache = _CapturingCache();
        final provider = _FakeProxyLlmProvider();
        final pipeline =
            AdvisorRequestPipeline(breaker: breaker, cache: cache);
        results.add(await pipeline.execute(
          llmProvider: provider,
          llmRequest: _makeLlmRequest(),
          operatorId: _operatorId,
          locationId: _locationId,
          queryClass: _queryClass,
          questionHash: _questionHash,
          corpusVersion: _corpusVersion,
        ));
      }

      // ── Open → cache miss → refusal
      {
        final breaker = CircuitBreaker(providerId: 'anthropic');
        breaker.recordFailure(FailureKind.http5xx);
        breaker.recordFailure(FailureKind.http5xx);
        breaker.recordFailure(FailureKind.http5xx);
        final cache = _CapturingCache();
        final provider = _FakeProxyLlmProvider();
        final pipeline =
            AdvisorRequestPipeline(breaker: breaker, cache: cache);
        results.add(await pipeline.execute(
          llmProvider: provider,
          llmRequest: _makeLlmRequest(),
          operatorId: _operatorId,
          locationId: _locationId,
          queryClass: _queryClass,
          questionHash: _questionHash,
          corpusVersion: _corpusVersion,
        ));
      }

      // ── Open → cache hit
      {
        final breaker = CircuitBreaker(providerId: 'anthropic');
        breaker.recordFailure(FailureKind.http5xx);
        breaker.recordFailure(FailureKind.http5xx);
        breaker.recordFailure(FailureKind.http5xx);
        final cache = _CapturingCache()..answerToReturn = '<hit>';
        final provider = _FakeProxyLlmProvider();
        final pipeline =
            AdvisorRequestPipeline(breaker: breaker, cache: cache);
        results.add(await pipeline.execute(
          llmProvider: provider,
          llmRequest: _makeLlmRequest(),
          operatorId: _operatorId,
          locationId: _locationId,
          queryClass: _queryClass,
          questionHash: _questionHash,
          corpusVersion: _corpusVersion,
        ));
      }

      // ── Half-open probe success: drive open with a controllable clock,
      // advance past coolDown, then call execute(). The breaker must
      // promote open → halfOpen → closed via allowProbe + recordSuccess.
      {
        var now = DateTime.utc(2026, 5, 1, 12);
        DateTime fakeClock() => now;
        final breaker = CircuitBreaker(
          providerId: 'anthropic',
          clock: fakeClock,
        );
        breaker.recordFailure(FailureKind.http5xx);
        breaker.recordFailure(FailureKind.http5xx);
        breaker.recordFailure(FailureKind.http5xx);
        expect(breaker.state, equals(CircuitState.open));
        // Advance past the cool-down window so tryAcquire promotes to
        // halfOpen and returns allowProbe.
        now = now.add(const Duration(seconds: 31));

        final cache = _CapturingCache();
        final provider = _FakeProxyLlmProvider();
        final pipeline =
            AdvisorRequestPipeline(breaker: breaker, cache: cache);
        final result = await pipeline.execute(
          llmProvider: provider,
          llmRequest: _makeLlmRequest(),
          operatorId: _operatorId,
          locationId: _locationId,
          queryClass: _queryClass,
          questionHash: _questionHash,
          corpusVersion: _corpusVersion,
        );
        expect(result.decision, equals(AcquireDecision.allowProbe));
        expect(result.completion, isNotNull);
        expect(result.fallbackUsed, equals('none'));
        results.add(result);
      }

      // No outcome may use the E.2b reserved slot in v1.
      for (final r in results) {
        expect(r.fallbackUsed, isNot(equals('gemini-reserved')));
      }
    });
  });
}
