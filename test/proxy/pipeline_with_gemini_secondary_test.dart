// Forge & Flow — AdvisorRequestPipeline with Gemini secondary tests.
//
// Phase 11A.4b graft. Master's Lock 7 v1 reserved a `// TODO(E.2b)`
// slot in `AdvisorRequestPipeline.execute` for the Gemini Flash
// secondary; this slice fills it with a real `GeminiProxyLlmProvider`.
// These tests exercise the modified pipeline shape:
//
//   primary success                   → fallbackUsed='none'
//   primary fail + secondary success  → fallbackUsed='gemini'
//   primary + secondary fail + cache  → fallbackUsed='cache'
//   all three fail                    → fallbackUsed='refusal'
//   breaker open + secondary success  → fallbackUsed='gemini' (skips primary)
//
// The breaker only protects the primary; secondary failures fall
// through to cache silently (matches v1 minimal posture; a Gemini-
// side breaker is a future tightening).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/advisor_response_cache.dart';
import 'package:forge_and_flow/domain/services/circuit_breaker.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

class _StubProvider implements ProxyLlmProvider {
  _StubProvider({this.completion, this.throwsOnNextCall});

  ProxyLlmCompletion? completion;
  Object? throwsOnNextCall;
  int callCount = 0;

  @override
  Future<ProxyLlmCompletion> complete(ProxyLlmRequest request) async {
    callCount += 1;
    final raise = throwsOnNextCall;
    if (raise != null) {
      throwsOnNextCall = null;
      throw raise;
    }
    final c = completion;
    if (c == null) {
      throw StateError('_StubProvider.completion not configured');
    }
    return c;
  }
}

class _StubCache implements AdvisorResponseCache {
  _StubCache({this.answer});
  String? answer;

  @override
  Future<String?> lookup({
    required String operatorId,
    required String locationId,
    required String queryClass,
    required String questionHash,
    required String corpusVersion,
  }) async => answer;
}

ProxyLlmRequest _request() {
  return const ProxyLlmRequest(
    question: 'q',
    promptBlocks: <ProxyPromptBlock>[],
    tier: ProxyLlmTier.haiku,
    modelId: 'claude-haiku-4-5',
    cacheKey: 'k',
    maxOutputTokens: 256,
  );
}

ProxyLlmCompletion _claudeCompletion() {
  return const ProxyLlmCompletion(
    text: 'anthropic answer',
    modelId: 'claude-haiku-4-5',
    tier: ProxyLlmTier.haiku,
    outputTokens: 12,
    costCents: 1,
  );
}

ProxyLlmCompletion _geminiCompletion() {
  return const ProxyLlmCompletion(
    text: 'gemini answer',
    modelId: 'gemini-2.5-flash',
    tier: ProxyLlmTier.haiku,
    outputTokens: 14,
    costCents: 0,
  );
}

void main() {
  group('AdvisorRequestPipeline with Gemini secondary', () {
    test('primary serves → fallbackUsed=none, secondary not invoked',
        () async {
      final primary = _StubProvider(completion: _claudeCompletion());
      final secondary = _StubProvider();
      final pipeline = AdvisorRequestPipeline(
        breaker: CircuitBreaker(providerId: 'anthropic'),
        cache: _StubCache(),
        secondaryLlmProvider: secondary,
      );

      final result = await pipeline.execute(
        llmProvider: primary,
        llmRequest: _request(),
        operatorId: 'op',
        locationId: 'loc',
        queryClass: 'qc',
        questionHash: 'h',
        corpusVersion: 'v',
      );

      expect(primary.callCount, 1);
      expect(secondary.callCount, 0);
      expect(result.completion?.text, 'anthropic answer');
      expect(result.completion?.modelId, 'claude-haiku-4-5');
      expect(result.fallbackUsed, 'none');
      expect(result.refused, isFalse);
    });

    test('primary fails + secondary succeeds → fallbackUsed=gemini, '
        'completion.modelId reflects gemini', () async {
      final primary = _StubProvider(throwsOnNextCall: Exception('5xx'));
      final secondary = _StubProvider(completion: _geminiCompletion());
      final pipeline = AdvisorRequestPipeline(
        breaker: CircuitBreaker(providerId: 'anthropic'),
        cache: _StubCache(),
        secondaryLlmProvider: secondary,
      );

      final result = await pipeline.execute(
        llmProvider: primary,
        llmRequest: _request(),
        operatorId: 'op',
        locationId: 'loc',
        queryClass: 'qc',
        questionHash: 'h',
        corpusVersion: 'v',
      );

      expect(primary.callCount, 1);
      expect(secondary.callCount, 1);
      expect(result.completion?.text, 'gemini answer');
      expect(result.completion?.modelId, 'gemini-2.5-flash');
      expect(result.fallbackUsed, 'gemini');
      expect(result.refused, isFalse,
          reason: 'Gemini producing a real answer is not a degraded '
              'response — this should be a normal HTTP 200 path');
    });

    test('primary + secondary both fail + cache hits → fallbackUsed=cache',
        () async {
      final primary = _StubProvider(throwsOnNextCall: Exception('5xx'));
      final secondary = _StubProvider(throwsOnNextCall: Exception('boom'));
      final cache = _StubCache(answer: 'cached answer');
      final pipeline = AdvisorRequestPipeline(
        breaker: CircuitBreaker(providerId: 'anthropic'),
        cache: cache,
        secondaryLlmProvider: secondary,
      );

      final result = await pipeline.execute(
        llmProvider: primary,
        llmRequest: _request(),
        operatorId: 'op',
        locationId: 'loc',
        queryClass: 'qc',
        questionHash: 'h',
        corpusVersion: 'v',
      );

      expect(primary.callCount, 1);
      expect(secondary.callCount, 1);
      expect(result.completion, isNull);
      expect(result.cachedAnswer, 'cached answer');
      expect(result.fallbackUsed, 'cache');
      expect(result.refused, isTrue);
    });

    test('primary + secondary both fail + cache miss → fallbackUsed=refusal',
        () async {
      final primary = _StubProvider(throwsOnNextCall: Exception('5xx'));
      final secondary = _StubProvider(throwsOnNextCall: Exception('boom'));
      final pipeline = AdvisorRequestPipeline(
        breaker: CircuitBreaker(providerId: 'anthropic'),
        cache: _StubCache(),
        secondaryLlmProvider: secondary,
      );

      final result = await pipeline.execute(
        llmProvider: primary,
        llmRequest: _request(),
        operatorId: 'op',
        locationId: 'loc',
        queryClass: 'qc',
        questionHash: 'h',
        corpusVersion: 'v',
      );

      expect(primary.callCount, 1);
      expect(secondary.callCount, 1);
      expect(result.completion, isNull);
      expect(result.cachedAnswer, isNull);
      expect(result.fallbackUsed, 'refusal');
      expect(result.refused, isTrue);
    });

    test('breaker open after 3 primary failures → secondary serves on the '
        'next request, primary skipped', () async {
      final primary = _StubProvider(throwsOnNextCall: Exception('5xx'));
      final secondary = _StubProvider();
      final breaker = CircuitBreaker(providerId: 'anthropic');
      final pipeline = AdvisorRequestPipeline(
        breaker: breaker,
        cache: _StubCache(),
        secondaryLlmProvider: secondary,
      );

      // Trip the breaker with 3 consecutive primary failures.
      for (var i = 0; i < 3; i++) {
        primary.throwsOnNextCall = Exception('5xx-$i');
        secondary.completion = _geminiCompletion();
        await pipeline.execute(
          llmProvider: primary,
          llmRequest: _request(),
          operatorId: 'op',
          locationId: 'loc',
          queryClass: 'qc',
          questionHash: 'h',
          corpusVersion: 'v',
        );
      }
      expect(breaker.state, CircuitState.open);

      // Reset call counters; next request must skip primary entirely
      // and go straight to the secondary.
      final primaryCallsBeforeOpenRequest = primary.callCount;
      secondary.completion = _geminiCompletion();
      final result = await pipeline.execute(
        llmProvider: primary,
        llmRequest: _request(),
        operatorId: 'op',
        locationId: 'loc',
        queryClass: 'qc',
        questionHash: 'h',
        corpusVersion: 'v',
      );

      expect(primary.callCount, primaryCallsBeforeOpenRequest,
          reason: 'breaker open → primary must NOT be called');
      expect(result.completion?.modelId, 'gemini-2.5-flash');
      expect(result.fallbackUsed, 'gemini');
    });

    test('null secondary → pipeline reduces to anthropic → cache → refusal',
        () async {
      final primary = _StubProvider(throwsOnNextCall: Exception('5xx'));
      final pipeline = AdvisorRequestPipeline(
        breaker: CircuitBreaker(providerId: 'anthropic'),
        cache: _StubCache(answer: 'cached fallback'),
        secondaryLlmProvider: null,
      );

      final result = await pipeline.execute(
        llmProvider: primary,
        llmRequest: _request(),
        operatorId: 'op',
        locationId: 'loc',
        queryClass: 'qc',
        questionHash: 'h',
        corpusVersion: 'v',
      );

      expect(result.cachedAnswer, 'cached fallback');
      expect(result.fallbackUsed, 'cache');
    });
  });
}
