// CODE_HEALTH L4 — secondary-LLM circuit breaker tests.
//
// Verifies the per-instance breaker that wraps the optional Gemini
// secondary in `AdvisorRequestPipeline`:
//
//   1. 5 simulated failures within 60s open the breaker.
//   2. Subsequent calls return without invoking the underlying gateway
//      (skipping the secondary entirely; the pipeline falls through to
//      cache → refusal).
//   3. After 30s the breaker half-opens (next call admitted).
//   4. The next success closes it (failure count reset).
//
// The test drives a [ProxyLlmProvider] stub that counts invocations and
// can be configured to fail / succeed on demand. Time is controlled by
// a fake clock injected into the breaker via the
// [AdvisorRequestPipeline] constructor.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/advisor_response_cache.dart';
import 'package:forge_and_flow/domain/services/circuit_breaker.dart';
import 'package:forge_and_flow/domain/services/llm_provider.dart';

import '../../../tool/advisor_proxy/advisor_proxy.dart';

class _FakeClock {
  _FakeClock(DateTime initial) : _now = initial;

  DateTime _now;

  DateTime call() => _now;

  void advance(Duration d) {
    _now = _now.add(d);
  }
}

class _ConfigurableLlmProvider implements ProxyLlmProvider {
  int completeCalls = 0;
  Object? nextError;

  @override
  Future<ProxyLlmCompletion> complete(ProxyLlmRequest request) async {
    completeCalls += 1;
    final error = nextError;
    if (error != null) {
      throw error;
    }
    return ProxyLlmCompletion(
      text: 'gemini ok',
      modelId: request.modelId,
      tier: request.tier,
      outputTokens: 1,
      costCents: 0,
    );
  }
}

/// Always-throw primary so the pipeline always falls through to the
/// secondary path under test.
class _AlwaysFailingPrimary implements ProxyLlmProvider {
  @override
  Future<ProxyLlmCompletion> complete(ProxyLlmRequest request) async {
    throw const LLMProviderException(
      FailureKind.http5xx,
      'primary down',
      statusCode: 503,
    );
  }
}

ProxyLlmRequest _request() => const ProxyLlmRequest(
      question: 'test',
      promptBlocks: <ProxyPromptBlock>[],
      tier: ProxyLlmTier.haiku,
      modelId: 'claude-haiku-4-5',
      cacheKey: 'k',
      maxOutputTokens: 64,
    );

void main() {
  group('AdvisorRequestPipeline secondary-LLM breaker', () {
    test('opens after 5 failures within 60s, skips gateway while open', () async {
      final fakeClock = _FakeClock(DateTime.utc(2026, 5, 7, 12));
      final secondary = _ConfigurableLlmProvider();
      final pipeline = AdvisorRequestPipeline(
        breaker: CircuitBreaker(providerId: 'anthropic'),
        cache: const AlwaysMissAdvisorResponseCache(),
        secondaryLlmProvider: secondary,
        secondaryBreakerClock: fakeClock.call,
      );
      final primary = _AlwaysFailingPrimary();

      // Five simulated transient (5xx) failures within the 60s window.
      secondary.nextError = const LLMProviderException(
        FailureKind.http5xx,
        'gemini 503',
        statusCode: 503,
      );
      for (var i = 0; i < 5; i++) {
        final result = await pipeline.execute(
          llmProvider: primary,
          llmRequest: _request(),
          operatorId: 'op',
          locationId: 'loc',
          queryClass: 'qa',
          questionHash: 'h',
          corpusVersion: 'v1',
        );
        expect(result.refused, isTrue,
            reason: 'failure run #$i should fall to refusal');
        expect(result.fallbackUsed, equals('refusal'));
        // The clock barely advances inside the 60s window so all five
        // failures stay in the sliding window.
        fakeClock.advance(const Duration(seconds: 1));
      }
      expect(secondary.completeCalls, equals(5));
      expect(pipeline.secondaryBreaker.isOpen, isTrue,
          reason: '5 failures within 60s must open the breaker');

      // Breaker open: subsequent calls do NOT invoke the gateway.
      // (We leave nextError in place; if the gateway were invoked,
      // completeCalls would tick up and the failure would also count.)
      for (var i = 0; i < 3; i++) {
        final result = await pipeline.execute(
          llmProvider: primary,
          llmRequest: _request(),
          operatorId: 'op',
          locationId: 'loc',
          queryClass: 'qa',
          questionHash: 'h',
          corpusVersion: 'v1',
        );
        expect(result.refused, isTrue);
        expect(result.fallbackUsed, equals('refusal'));
      }
      expect(secondary.completeCalls, equals(5),
          reason: 'gateway must NOT be invoked while breaker is open');
    });

    test('half-opens after 30s and a success closes it', () async {
      final fakeClock = _FakeClock(DateTime.utc(2026, 5, 7, 12));
      final secondary = _ConfigurableLlmProvider();
      final pipeline = AdvisorRequestPipeline(
        breaker: CircuitBreaker(providerId: 'anthropic'),
        cache: const AlwaysMissAdvisorResponseCache(),
        secondaryLlmProvider: secondary,
        secondaryBreakerClock: fakeClock.call,
      );
      final primary = _AlwaysFailingPrimary();

      // Trip the breaker.
      secondary.nextError = const LLMProviderException(
        FailureKind.http5xx,
        'gemini 503',
        statusCode: 503,
      );
      for (var i = 0; i < 5; i++) {
        await pipeline.execute(
          llmProvider: primary,
          llmRequest: _request(),
          operatorId: 'op',
          locationId: 'loc',
          queryClass: 'qa',
          questionHash: 'h',
          corpusVersion: 'v1',
        );
      }
      expect(pipeline.secondaryBreaker.isOpen, isTrue);

      // Advance past the 30s open duration. The breaker should
      // half-open on the next tryAcquire and admit the call.
      fakeClock.advance(const Duration(seconds: 31));
      secondary.nextError = null; // next call succeeds
      final reseatedCalls = secondary.completeCalls;
      final result = await pipeline.execute(
        llmProvider: primary,
        llmRequest: _request(),
        operatorId: 'op',
        locationId: 'loc',
        queryClass: 'qa',
        questionHash: 'h',
        corpusVersion: 'v1',
      );
      expect(secondary.completeCalls, equals(reseatedCalls + 1),
          reason: 'half-open must invoke the gateway exactly once');
      expect(result.refused, isFalse);
      expect(result.fallbackUsed, equals('gemini'));
      expect(pipeline.secondaryBreaker.isOpen, isFalse,
          reason: 'a successful half-open call must close the breaker');
    });

    test('per-call 8s timeout maps to a TimeoutException-counted failure',
        () async {
      // The pipeline wraps the secondary call in a Future.timeout. We
      // simulate a slow gateway with a Future that never completes
      // and assert the timeout is observed within a tight bound.
      final pipeline = AdvisorRequestPipeline(
        breaker: CircuitBreaker(providerId: 'anthropic'),
        cache: const AlwaysMissAdvisorResponseCache(),
        secondaryLlmProvider: _NeverCompletingProvider(),
        secondaryTimeout: const Duration(milliseconds: 50),
      );
      final result = await pipeline
          .execute(
            llmProvider: _AlwaysFailingPrimary(),
            llmRequest: _request(),
            operatorId: 'op',
            locationId: 'loc',
            queryClass: 'qa',
            questionHash: 'h',
            corpusVersion: 'v1',
          )
          .timeout(const Duration(seconds: 2));
      expect(result.refused, isTrue);
      expect(result.fallbackUsed, equals('refusal'));
    });

    test(
        'auth failures do NOT trip the breaker (credentials are not transient)',
        () async {
      final secondary = _ConfigurableLlmProvider();
      final pipeline = AdvisorRequestPipeline(
        breaker: CircuitBreaker(providerId: 'anthropic'),
        cache: const AlwaysMissAdvisorResponseCache(),
        secondaryLlmProvider: secondary,
      );
      secondary.nextError = const LLMProviderException(
        FailureKind.unknown,
        'gemini 401',
        statusCode: 401,
      );
      // 10 auth failures must NOT open the breaker — recovery is
      // gated on a credential rotation, not on time.
      for (var i = 0; i < 10; i++) {
        await pipeline.execute(
          llmProvider: _AlwaysFailingPrimary(),
          llmRequest: _request(),
          operatorId: 'op',
          locationId: 'loc',
          queryClass: 'qa',
          questionHash: 'h',
          corpusVersion: 'v1',
        );
      }
      expect(pipeline.secondaryBreaker.isOpen, isFalse);
      expect(secondary.completeCalls, equals(10));
    });
  });

  group('classifySecondaryLlmFailure', () {
    test('TimeoutException → timeout', () {
      expect(
        classifySecondaryLlmFailure(TimeoutException('slow')),
        equals(SecondaryLlmFailureKind.timeout),
      );
    });

    test('429 → rateLimit', () {
      expect(
        classifySecondaryLlmFailure(
          const LLMProviderException(FailureKind.http429, 'rl', statusCode: 429),
        ),
        equals(SecondaryLlmFailureKind.rateLimit),
      );
    });

    test('401/403 → auth', () {
      expect(
        classifySecondaryLlmFailure(
          const LLMProviderException(FailureKind.unknown, 'unauth', statusCode: 401),
        ),
        equals(SecondaryLlmFailureKind.auth),
      );
      expect(
        classifySecondaryLlmFailure(
          const LLMProviderException(FailureKind.unknown, 'forbidden', statusCode: 403),
        ),
        equals(SecondaryLlmFailureKind.auth),
      );
    });

    test('5xx → transient', () {
      expect(
        classifySecondaryLlmFailure(
          const LLMProviderException(FailureKind.http5xx, 'down', statusCode: 503),
        ),
        equals(SecondaryLlmFailureKind.transient),
      );
    });

    test('400/404 → permanent', () {
      expect(
        classifySecondaryLlmFailure(
          const LLMProviderException(FailureKind.unknown, 'bad req', statusCode: 400),
        ),
        equals(SecondaryLlmFailureKind.permanent),
      );
    });

    test('arbitrary thrown object → unknown', () {
      expect(
        classifySecondaryLlmFailure('boom'),
        equals(SecondaryLlmFailureKind.unknown),
      );
    });
  });
}

class _NeverCompletingProvider implements ProxyLlmProvider {
  @override
  Future<ProxyLlmCompletion> complete(ProxyLlmRequest request) {
    return Completer<ProxyLlmCompletion>().future; // never completes
  }
}
