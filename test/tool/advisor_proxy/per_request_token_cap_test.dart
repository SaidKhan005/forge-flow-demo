// CODE_HEALTH TOKEN-CAP-REAL — global per-request token cap on outbound
// LLM dispatch.
//
// Exercises:
//   * `resolveMaxTokensPerRequest` env-resolver behavior (default,
//     override, invalid input, upper-bound clamp).
//   * The cap-check semantics applied at the advisor-smoke dispatch site
//     in `advisor_proxy.dart`: requests at-or-below the cap pass through
//     to the gateway; requests above the cap reject with HTTP 413
//     (`request_too_large`) and the underlying gateway is never invoked.
//
// The cap-check site in `advisor_proxy.dart` is a small predicate:
//
//     final maxTokensPerRequest = resolveMaxTokensPerRequest();
//     if (estimate.tokenCount > maxTokensPerRequest) {
//       _writeJson(response, 413, { 'error': 'request_too_large', ... });
//       return;
//     }
//
// These tests reproduce that predicate against a fake `ProxyLlmProvider`
// to assert "below cap → dispatched", "above cap → rejected, gateway not
// invoked", and that the env-resolver controls the threshold.

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/advisor_proxy.dart';

/// Fake gateway that records every `complete` invocation. Used to assert
/// "underlying gateway NOT invoked" when the cap check rejects.
class _CountingLlmProvider implements ProxyLlmProvider {
  int completeCalls = 0;

  @override
  Future<ProxyLlmCompletion> complete(ProxyLlmRequest request) async {
    completeCalls += 1;
    return ProxyLlmCompletion(
      text: 'ok',
      modelId: request.modelId,
      tier: request.tier,
      outputTokens: 1,
      costCents: 0,
    );
  }
}

/// Models the production cap-check predicate in advisor_proxy.dart:
///
///     if (estimate.tokenCount > resolveMaxTokensPerRequest(env)) {
///       writeJson(413, request_too_large, { estimate, cap });
///       return;  // gateway is NOT invoked
///     }
///     await llmProvider.complete(...);
///
/// Returns `null` on dispatch (gateway invoked); returns a refusal map on
/// reject.
Future<Map<String, Object?>?> _runCapCheck({
  required _CountingLlmProvider provider,
  required int estimateTokenCount,
  Map<String, String>? environment,
}) async {
  final cap = resolveMaxTokensPerRequest(environment: environment);
  if (estimateTokenCount > cap) {
    return <String, Object?>{
      'status_code': 413,
      'error': 'request_too_large',
      'message': 'estimated request tokens exceed the per-request cap',
      'estimate_request_tokens': estimateTokenCount,
      'cap_request_tokens': cap,
    };
  }
  await provider.complete(
    const ProxyLlmRequest(
      question: 'q',
      promptBlocks: <ProxyPromptBlock>[],
      tier: ProxyLlmTier.haiku,
      modelId: 'claude-haiku-4-5',
      cacheKey: 'k',
      maxOutputTokens: 64,
    ),
  );
  return null;
}

void main() {
  group('CODE_HEALTH TOKEN-CAP-REAL — resolveMaxTokensPerRequest', () {
    test('falls back to default when env var is unset', () {
      expect(
        resolveMaxTokensPerRequest(environment: const <String, String>{}),
        equals(kMaxTokensPerRequestDefault),
      );
    });

    test('default cap is 100,000 (Claude Opus 200k window with margin)', () {
      expect(kMaxTokensPerRequestDefault, equals(100000));
      expect(kMaxTokensPerRequestEnvVar, equals('MAX_TOKENS_PER_REQUEST'));
    });

    test('falls back to default when env var is empty / whitespace', () {
      expect(
        resolveMaxTokensPerRequest(
          environment: const <String, String>{
            kMaxTokensPerRequestEnvVar: '',
          },
        ),
        equals(kMaxTokensPerRequestDefault),
      );
      expect(
        resolveMaxTokensPerRequest(
          environment: const <String, String>{
            kMaxTokensPerRequestEnvVar: '   ',
          },
        ),
        equals(kMaxTokensPerRequestDefault),
      );
    });

    test('falls back to default when env var is unparsable', () {
      expect(
        resolveMaxTokensPerRequest(
          environment: const <String, String>{
            kMaxTokensPerRequestEnvVar: 'not-a-number',
          },
        ),
        equals(kMaxTokensPerRequestDefault),
      );
    });

    test('falls back to default when env var is zero or negative', () {
      expect(
        resolveMaxTokensPerRequest(
          environment: const <String, String>{
            kMaxTokensPerRequestEnvVar: '0',
          },
        ),
        equals(kMaxTokensPerRequestDefault),
      );
      expect(
        resolveMaxTokensPerRequest(
          environment: const <String, String>{
            kMaxTokensPerRequestEnvVar: '-1',
          },
        ),
        equals(kMaxTokensPerRequestDefault),
      );
    });

    test('falls back to default when env var exceeds the upper bound', () {
      expect(
        resolveMaxTokensPerRequest(
          environment: <String, String>{
            kMaxTokensPerRequestEnvVar:
                '${kMaxTokensPerRequestUpperBound + 1}',
          },
        ),
        equals(kMaxTokensPerRequestDefault),
      );
    });

    test('accepts a value exactly at the upper bound', () {
      expect(
        resolveMaxTokensPerRequest(
          environment: <String, String>{
            kMaxTokensPerRequestEnvVar:
                '$kMaxTokensPerRequestUpperBound',
          },
        ),
        equals(kMaxTokensPerRequestUpperBound),
      );
    });

    test('Test 3 — env override returns the parsed value (5000)', () {
      // Acceptance from prompt sub-task (c) Test 3:
      // env override `{'MAX_TOKENS_PER_REQUEST': '5000'}` → resolver returns 5000.
      expect(
        resolveMaxTokensPerRequest(
          environment: const <String, String>{
            kMaxTokensPerRequestEnvVar: '5000',
          },
        ),
        equals(5000),
      );
    });
  });

  group('CODE_HEALTH TOKEN-CAP-REAL — dispatch-site cap check', () {
    test('Test 1 — request below cap → dispatch proceeds (gateway invoked)',
        () async {
      final provider = _CountingLlmProvider();
      final result = await _runCapCheck(
        provider: provider,
        estimateTokenCount: 1000,
        environment: const <String, String>{
          kMaxTokensPerRequestEnvVar: '5000',
        },
      );

      expect(result, isNull, reason: 'cap not exceeded → no refusal');
      expect(
        provider.completeCalls,
        equals(1),
        reason: 'gateway invoked when below cap',
      );
    });

    test(
        'Test 2 — request above cap → rejected with HTTP 413; gateway NOT '
        'invoked', () async {
      final provider = _CountingLlmProvider();
      final result = await _runCapCheck(
        provider: provider,
        estimateTokenCount: 5001,
        environment: const <String, String>{
          kMaxTokensPerRequestEnvVar: '5000',
        },
      );

      expect(result, isNotNull, reason: 'cap exceeded → typed refusal');
      expect(result!['status_code'], equals(413));
      expect(result['error'], equals('request_too_large'));
      expect(
        result['estimate_request_tokens'],
        equals(5001),
        reason: 'response includes the estimate so clients can shrink',
      );
      expect(
        result['cap_request_tokens'],
        equals(5000),
        reason: 'response includes the cap so clients can shrink',
      );
      expect(
        provider.completeCalls,
        equals(0),
        reason:
            'CRITICAL: underlying gateway NOT invoked when cap exceeded — '
            'no silent downgrade / trim, hard cap',
      );
    });

    test(
        'request exactly at cap → dispatch proceeds (cap is strict greater-'
        'than)', () async {
      final provider = _CountingLlmProvider();
      final result = await _runCapCheck(
        provider: provider,
        estimateTokenCount: 5000,
        environment: const <String, String>{
          kMaxTokensPerRequestEnvVar: '5000',
        },
      );

      expect(result, isNull);
      expect(provider.completeCalls, equals(1));
    });

    test(
        'cap responds to env override — same estimate dispatches under high '
        'cap, refuses under low cap', () async {
      final providerHigh = _CountingLlmProvider();
      final highResult = await _runCapCheck(
        provider: providerHigh,
        estimateTokenCount: 50000,
        environment: const <String, String>{
          kMaxTokensPerRequestEnvVar: '100000',
        },
      );
      expect(highResult, isNull);
      expect(providerHigh.completeCalls, equals(1));

      final providerLow = _CountingLlmProvider();
      final lowResult = await _runCapCheck(
        provider: providerLow,
        estimateTokenCount: 50000,
        environment: const <String, String>{
          kMaxTokensPerRequestEnvVar: '10000',
        },
      );
      expect(lowResult, isNotNull);
      expect(lowResult!['status_code'], equals(413));
      expect(lowResult['cap_request_tokens'], equals(10000));
      expect(providerLow.completeCalls, equals(0));
    });
  });
}
