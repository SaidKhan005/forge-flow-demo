// Phase 11A.B43 — prompt-cache breakpoint TTL discipline + corpus-versioned
// cache key. Locks scalability-decisions item 12 ("must explicitly set
// cache_control: {\"type\": \"ephemeral\", \"ttl\": \"1h\"} so cost
// assumptions do not silently break if vendor defaults change. Assert this
// in proxy unit tests.").

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('AdvisorPromptCacheBuilder — TTL pin', () {
    const builder = AdvisorPromptCacheBuilder();

    test('every breakpoint block carries cacheTtl == "1h"', () {
      final blocks = builder.build(
        corpusVersion: 'launch_v1',
        methodologyContext: 'methodology context body',
        toolDefinitions: 'tool definitions body',
        operatorContext: 'operator context body',
      );

      final breakpoints = blocks.where((b) => b.cacheBreakpoint).toList();
      expect(
        breakpoints,
        isNotEmpty,
        reason: 'builder must produce at least one breakpoint block',
      );
      for (final block in breakpoints) {
        expect(
          block.cacheTtl,
          equals('1h'),
          reason: 'breakpoint "${block.id}" must pin ttl=1h',
        );
      }
    });

    test('proxyPromptBlockToCacheControl emits ephemeral 1h on breakpoints', () {
      final blocks = builder.build(
        corpusVersion: 'launch_v1',
        methodologyContext: 'methodology context body',
        toolDefinitions: 'tool definitions body',
        operatorContext: 'operator context body',
      );

      for (final block in blocks) {
        final cacheControl = proxyPromptBlockToCacheControl(block);
        if (block.cacheBreakpoint) {
          expect(
            cacheControl,
            equals(<String, Object?>{
              'type': 'ephemeral',
              'ttl': '1h',
            }),
            reason:
                'breakpoint "${block.id}" must serialize to '
                '{"type":"ephemeral","ttl":"1h"}',
          );
        } else {
          expect(
            cacheControl,
            isNull,
            reason:
                'non-breakpoint "${block.id}" must not emit a cache_control map',
          );
        }
      }
    });

    test(
      'ProxyPromptBlock toJson exposes cache_ttl alongside cache_breakpoint',
      () {
        const block = ProxyPromptBlock(
          id: 'system_prompt',
          text: 'hello',
          cacheBreakpoint: true,
        );
        expect(
          block.toJson(),
          equals(<String, Object?>{
            'id': 'system_prompt',
            'text': 'hello',
            'cache_breakpoint': true,
            'cache_ttl': '1h',
          }),
        );
      },
    );

    test(
      'breakpoint set is exactly system_prompt + tool_definitions + corpus_context',
      () {
        final blocks = builder.build(
          corpusVersion: 'launch_v1',
          methodologyContext: 'm',
          toolDefinitions: 't',
          operatorContext: 'o',
        );
        final cachedIds = <String>[
          for (final block in blocks)
            if (block.cacheBreakpoint) block.id,
        ];
        expect(
          cachedIds,
          equals(<String>[
            'system_prompt',
            'tool_definitions',
            'corpus_context:launch_v1',
          ]),
        );
      },
    );
  });

  group('Cache key — corpus_version threading', () {
    const builder = AdvisorPromptCacheBuilder();

    test('cacheKeyForCorpusVersion includes the literal corpus_version', () {
      expect(
        builder.cacheKeyForCorpusVersion('launch_v1'),
        contains('launch_v1'),
      );
      expect(
        builder.cacheKeyForCorpusVersion('launch_v2'),
        contains('launch_v2'),
      );
    });

    test('different corpus versions produce different cache keys', () {
      expect(
        builder.cacheKeyForCorpusVersion('launch_v1'),
        isNot(equals(builder.cacheKeyForCorpusVersion('launch_v2'))),
      );
    });

    test('cache key prefix is the canonical "advisor-corpus:" namespace', () {
      expect(
        builder.cacheKeyForCorpusVersion('any_version_string'),
        startsWith('advisor-corpus:'),
      );
    });

    test(
      'ProxyLlmRequest accepts a cacheKey threaded from the builder helper',
      () {
        const corpusVersion = 'launch_v3';
        final request = ProxyLlmRequest(
          question: 'q',
          promptBlocks: builder.build(
            corpusVersion: corpusVersion,
            methodologyContext: 'm',
            toolDefinitions: 't',
            operatorContext: 'o',
          ),
          tier: ProxyLlmTier.haiku,
          modelId: 'claude-haiku-4-5-20251001',
          cacheKey: builder.cacheKeyForCorpusVersion(corpusVersion),
          maxOutputTokens: 256,
        );
        expect(request.cacheKey, startsWith('advisor-corpus:'));
        expect(request.cacheKey, contains(corpusVersion));
      },
    );
  });

  group('ProxyCacheFeatureFlags — defaults', () {
    test('cacheTelemetryV2 defaults to false (gated rollout)', () {
      const flags = ProxyCacheFeatureFlags();
      expect(flags.cacheTelemetryV2, isFalse);
    });

    test('cacheTelemetryV2 can be flipped via constructor', () {
      const flags = ProxyCacheFeatureFlags(cacheTelemetryV2: true);
      expect(flags.cacheTelemetryV2, isTrue);
    });
  });

  group('ProxyConfig.fromEnvironment — CACHE_TELEMETRY_V2', () {
    Map<String, String> environmentWithSecrets({String? cacheFlag}) {
      return <String, String>{
        ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
        ProxySecretNames.voyageApiKey: 'placeholder-voyage',
        ProxySecretNames.postgresUrl: 'placeholder-postgres-url',
        ProxySecretNames.postgresAdminUrl: 'placeholder-postgres-admin-url',
        ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web-api-key',
        ProxySecretNames.servicePrincipalJwtSecret:
            'placeholder-service-principal-jwt-secret',
        if (cacheFlag != null) ProxyConfigNames.cacheTelemetryV2: cacheFlag,
      };
    }

    test('unset CACHE_TELEMETRY_V2 leaves cacheTelemetryV2 == false', () {
      final config = ProxyConfig.fromEnvironment(environmentWithSecrets());
      expect(config.cacheTelemetryV2, isFalse);
    });

    test('CACHE_TELEMETRY_V2=true flips cacheTelemetryV2 to true', () {
      final config =
          ProxyConfig.fromEnvironment(environmentWithSecrets(cacheFlag: 'true'));
      expect(config.cacheTelemetryV2, isTrue);
    });

    test('CACHE_TELEMETRY_V2 accepts true/1/on (case-insensitive)', () {
      for (final raw in const <String>['true', 'TRUE', '1', 'on', 'ON']) {
        final config = ProxyConfig.fromEnvironment(
          environmentWithSecrets(cacheFlag: raw),
        );
        expect(
          config.cacheTelemetryV2,
          isTrue,
          reason: '"$raw" should enable the flag',
        );
      }
    });

    test('unrecognised CACHE_TELEMETRY_V2 values keep the flag off', () {
      for (final raw in const <String>['false', '0', 'off', '', 'maybe']) {
        final config = ProxyConfig.fromEnvironment(
          environmentWithSecrets(cacheFlag: raw),
        );
        expect(
          config.cacheTelemetryV2,
          isFalse,
          reason: '"$raw" must NOT enable the flag (default-off posture)',
        );
      }
    });
  });
}
