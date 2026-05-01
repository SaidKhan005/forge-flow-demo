// Phase 11A — usage_logs circuit_state / fallback_used coverage.
//
// AdvisorRequestPipeline is the source of truth for the
// (circuitStateAtStart, fallbackUsed) pair the proxy stores in
// `usage_logs.circuit_state` / `usage_logs.fallback_used` via
// `commitUsageLog`. These tests pin the pair across the four
// scenarios that map onto the migration's CHECK constraint values:
//   - closed       + none
//   - open         + refusal
//   - open         + cache
//   - half_open    + none  (canary success — snapshot at decision time)
//
// Hand-rolled fakes only — no mocktail/mockito.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/services/advisor_response_cache.dart';
import 'package:forge_and_flow/domain/services/circuit_breaker.dart';
import 'package:forge_and_flow/domain/services/llm_provider.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

class _SuccessProvider implements ProxyLlmProvider {
  @override
  Future<ProxyLlmCompletion> complete(ProxyLlmRequest request) async {
    return ProxyLlmCompletion(
      text: 'ok',
      modelId: request.modelId,
      tier: request.tier,
      outputTokens: 1,
      costCents: 1,
    );
  }
}

class _FailingProvider implements ProxyLlmProvider {
  @override
  Future<ProxyLlmCompletion> complete(ProxyLlmRequest request) async {
    throw const LLMProviderException(FailureKind.http5xx, 'down');
  }
}

class _StubCache implements AdvisorResponseCache {
  _StubCache(this.answer);
  final String? answer;

  @override
  Future<String?> lookup({
    required String operatorId,
    required String locationId,
    required String queryClass,
    required String questionHash,
    required String corpusVersion,
  }) async => answer;
}

ProxyLlmRequest _llmRequest() => const ProxyLlmRequest(
  question: 'q',
  promptBlocks: <ProxyPromptBlock>[],
  tier: ProxyLlmTier.haiku,
  modelId: 'claude-haiku-4-5',
  cacheKey: 'advisor-corpus:launch_v1',
  maxOutputTokens: 1000,
);

void main() {
  group('AdvisorRequestPipeline — usage_logs circuit_state / fallback_used', () {
    test(
      'Scenario 1: closed + provider success → ("closed", "none")',
      () async {
        final breaker = CircuitBreaker(providerId: 'anthropic');
        final pipeline = AdvisorRequestPipeline(
          breaker: breaker,
          cache: _StubCache(null),
        );

        final result = await pipeline.execute(
          llmProvider: _SuccessProvider(),
          llmRequest: _llmRequest(),
          operatorId: 'op-1',
          locationId: 'loc-1',
          queryClass: 'lookup',
          questionHash: 'hash-1',
          corpusVersion: 'launch_v1',
        );

        expect(
          circuitStateToWireString(result.circuitStateAtStart),
          equals('closed'),
        );
        expect(result.fallbackUsed, equals('none'));
        expect(result.completion, isNotNull);
        expect(result.refused, isFalse);
      },
    );

    test(
      'Scenario 2: open + cache miss → ("open", "refusal")',
      () async {
        final breaker = CircuitBreaker(providerId: 'anthropic');
        // Drive breaker to open via 3 consecutive failures.
        breaker.recordFailure(FailureKind.unknown);
        breaker.recordFailure(FailureKind.unknown);
        breaker.recordFailure(FailureKind.unknown);
        expect(breaker.state, equals(CircuitState.open));

        final pipeline = AdvisorRequestPipeline(
          breaker: breaker,
          cache: _StubCache(null),
        );

        final result = await pipeline.execute(
          llmProvider: _FailingProvider(),
          llmRequest: _llmRequest(),
          operatorId: 'op-1',
          locationId: 'loc-1',
          queryClass: 'lookup',
          questionHash: 'hash-2',
          corpusVersion: 'launch_v1',
        );

        expect(
          circuitStateToWireString(result.circuitStateAtStart),
          equals('open'),
        );
        expect(result.fallbackUsed, equals('refusal'));
        expect(result.cachedAnswer, isNull);
        expect(result.refused, isTrue);
      },
    );

    test(
      'Scenario 3: open + cache hit → ("open", "cache")',
      () async {
        final breaker = CircuitBreaker(providerId: 'anthropic');
        breaker.recordFailure(FailureKind.unknown);
        breaker.recordFailure(FailureKind.unknown);
        breaker.recordFailure(FailureKind.unknown);
        expect(breaker.state, equals(CircuitState.open));

        final pipeline = AdvisorRequestPipeline(
          breaker: breaker,
          cache: _StubCache('cached previous answer'),
        );

        final result = await pipeline.execute(
          llmProvider: _FailingProvider(),
          llmRequest: _llmRequest(),
          operatorId: 'op-1',
          locationId: 'loc-1',
          queryClass: 'lookup',
          questionHash: 'hash-3',
          corpusVersion: 'launch_v1',
        );

        expect(
          circuitStateToWireString(result.circuitStateAtStart),
          equals('open'),
        );
        expect(result.fallbackUsed, equals('cache'));
        expect(result.cachedAnswer, equals('cached previous answer'));
        expect(result.refused, isTrue);
      },
    );

    test(
      'Scenario 4: half-open canary success → ("half_open", "none")',
      () async {
        // Virtual clock to drive the breaker from open into half-open
        // after the 30-second cool-down without sleeping.
        var virtualNow = DateTime.utc(2026, 5, 1, 12, 0, 0);
        final breaker = CircuitBreaker(
          providerId: 'anthropic',
          clock: () => virtualNow,
        );

        // Trip the breaker: 3 failures inside the failure window.
        breaker.recordFailure(FailureKind.unknown);
        breaker.recordFailure(FailureKind.unknown);
        breaker.recordFailure(FailureKind.unknown);
        expect(breaker.state, equals(CircuitState.open));

        // Advance past the 30-second cool-down so the next tryAcquire
        // promotes the breaker from open → halfOpen.
        virtualNow = virtualNow.add(const Duration(seconds: 31));

        final pipeline = AdvisorRequestPipeline(
          breaker: breaker,
          cache: _StubCache(null),
        );

        final result = await pipeline.execute(
          llmProvider: _SuccessProvider(),
          llmRequest: _llmRequest(),
          operatorId: 'op-1',
          locationId: 'loc-1',
          queryClass: 'lookup',
          questionHash: 'hash-4',
          corpusVersion: 'launch_v1',
        );

        // Snapshot-at-decision-time semantics: the pair recorded into
        // usage_logs reflects the state the breaker entered the
        // canary phase in (half_open), not the closed state the
        // breaker transitions to after recordSuccess. The canary
        // ran during half-open, so the wire string is 'half_open'.
        expect(
          circuitStateToWireString(result.circuitStateAtStart),
          equals('half_open'),
        );
        expect(result.fallbackUsed, equals('none'));
        expect(result.completion, isNotNull);
      },
    );
  });
}
