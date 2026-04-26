// Phase 7.57.3a — Provider Abstraction Foundation Tests
//
// Proves the new domain-level provider interfaces and concrete adapter
// classes carry the 11a contract values exactly. No real API calls —
// the adapters take injected gateway callbacks so tests can use fakes.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/domain/services/advisor_model_routing.dart';
import 'package:forge_and_flow/domain/services/advisor_provider_constants.dart';
import 'package:forge_and_flow/domain/services/llm_provider.dart';
import 'package:forge_and_flow/domain/services/rerank_provider.dart';
import 'package:forge_and_flow/services/advisor_model_config_service.dart';
import 'package:forge_and_flow/services/claude_llm_provider.dart';
import 'package:forge_and_flow/services/mock_replay_data_source_provider.dart';
import 'package:forge_and_flow/services/voyage_embedding_provider.dart';
import 'package:forge_and_flow/services/voyage_rerank_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('A — AdvisorProviderConstants match the 11a contract', () {
    test('Voyage embedding provider id, model id, dimensions', () {
      expect(AdvisorProviderConstants.voyageProviderId, equals('voyage'));
      expect(AdvisorProviderConstants.voyageEmbeddingModelId,
          equals('voyage-4-large'));
      expect(AdvisorProviderConstants.voyageEmbeddingDimensions, equals(1024));
    });

    test('Voyage rerank model id', () {
      expect(AdvisorProviderConstants.voyageRerankModelId, equals('rerank-2.5'));
    });

    test('Anthropic provider id', () {
      expect(AdvisorProviderConstants.anthropicProviderId, equals('anthropic'));
    });

    test('exact pinned default model ids', () {
      expect(AdvisorProviderConstants.haikuModelId, equals('claude-haiku-4-5'));
      expect(AdvisorProviderConstants.sonnetModelId, equals('claude-sonnet-4-6'));
    });

    test('mock replay provider id', () {
      expect(AdvisorProviderConstants.mockReplayProviderId, equals('mock_replay'));
    });
  });

  group('B — ClaudeLLMProvider tier dispatch', () {
    String? capturedModelId;
    Future<String> fakeFn({
      required String modelId,
      required String question,
      required String context,
    }) async {
      capturedModelId = modelId;
      return 'fake answer for $modelId';
    }

    setUp(() {
      capturedModelId = null;
    });

    test('default tier is quick and routes to Haiku', () async {
      final provider = ClaudeLLMProvider(completeFn: fakeFn);

      // modelIdFor(default-resolved-quick) returns Haiku without a call
      expect(provider.modelIdFor(LLMTier.quick),
          equals(AdvisorProviderConstants.haikuModelId));

      // .complete(...) with no tier passed -> Haiku
      final answer = await provider.complete(question: 'q', context: 'c');
      expect(answer.tier, equals(LLMTier.quick));
      expect(answer.modelId, equals(AdvisorProviderConstants.haikuModelId));
      expect(capturedModelId, equals(AdvisorProviderConstants.haikuModelId));
    });

    test('nuanced tier routes to Sonnet', () async {
      final provider = ClaudeLLMProvider(completeFn: fakeFn);

      expect(provider.modelIdFor(LLMTier.nuanced),
          equals(AdvisorProviderConstants.sonnetModelId));

      final answer = await provider.complete(
        question: 'q',
        context: 'c',
        tier: LLMTier.nuanced,
      );
      expect(answer.tier, equals(LLMTier.nuanced));
      expect(answer.modelId, equals(AdvisorProviderConstants.sonnetModelId));
      expect(capturedModelId, equals(AdvisorProviderConstants.sonnetModelId));
    });

    test('completion body comes from the gateway callback verbatim', () async {
      final provider = ClaudeLLMProvider(completeFn: fakeFn);
      final answer = await provider.complete(question: 'q', context: 'c');
      expect(answer.text, contains('fake answer'));
    });

    test('exposes promptCaching capability', () {
      final provider = ClaudeLLMProvider(completeFn: fakeFn);
      expect(provider.capabilities,
          contains(LLMProviderCapability.promptCaching));
    });
  });

  group('C — VoyageEmbeddingProvider reports the locked contract values', () {
    Future<List<List<double>>> fake1024(
      List<String> texts, {
      required String model,
    }) async {
      return [for (final _ in texts) List.filled(1024, 0.0)];
    }

    test('reports voyage / voyage-4-large / 1024', () {
      final provider = VoyageEmbeddingProvider(embedFn: fake1024);
      expect(provider.providerId, equals('voyage'));
      expect(provider.modelId, equals('voyage-4-large'));
      expect(provider.dimensions, equals(1024));
    });

    test('passes the contract model id to the gateway', () async {
      String? seenModel;
      Future<List<List<double>>> capturingFn(
        List<String> texts, {
        required String model,
      }) async {
        seenModel = model;
        return [for (final _ in texts) List.filled(1024, 0.0)];
      }

      final provider = VoyageEmbeddingProvider(embedFn: capturingFn);
      await provider.embed('hello');
      expect(seenModel, equals(AdvisorProviderConstants.voyageEmbeddingModelId));
    });

    test('rejects vectors that violate the dimensions contract', () async {
      Future<List<List<double>>> wrongDims(
        List<String> texts, {
        required String model,
      }) async {
        return [for (final _ in texts) List.filled(512, 0.0)];
      }

      final provider = VoyageEmbeddingProvider(embedFn: wrongDims);
      expect(provider.embed('x'), throwsStateError);
    });
  });

  group('D — VoyageRerankProvider preserves order from the fake gateway', () {
    test('reports voyage / rerank-2.5', () {
      final provider = VoyageRerankProvider(
        rerankFn: ({
          required String query,
          required List<RerankCandidate> candidates,
          required String model,
        }) async =>
            [for (final c in candidates) (id: c.id, score: 0.0)],
      );
      expect(provider.providerId, equals('voyage'));
      expect(provider.modelId, equals('rerank-2.5'));
    });

    test('returns candidates ordered by score desc with 0-based ranks', () async {
      // Fake returns scores 0.10, 0.90, 0.50 for ids a, b, c respectively.
      final provider = VoyageRerankProvider(
        rerankFn: ({
          required String query,
          required List<RerankCandidate> candidates,
          required String model,
        }) async =>
            [
          (id: 'a', score: 0.10),
          (id: 'b', score: 0.90),
          (id: 'c', score: 0.50),
        ],
      );

      final out = await provider.rerank('q', const [
        RerankCandidate(id: 'a', text: 'alpha'),
        RerankCandidate(id: 'b', text: 'bravo'),
        RerankCandidate(id: 'c', text: 'charlie'),
      ]);

      expect(out.map((r) => r.id).toList(), equals(['b', 'c', 'a']));
      expect(out.map((r) => r.rank).toList(), equals([0, 1, 2]));
      expect(out.first.score, closeTo(0.90, 1e-9));
      expect(out.last.score, closeTo(0.10, 1e-9));
    });

    test('empty candidates short-circuits without calling the gateway',
        () async {
      var called = false;
      final provider = VoyageRerankProvider(
        rerankFn: ({
          required String query,
          required List<RerankCandidate> candidates,
          required String model,
        }) async {
          called = true;
          return const <({String id, double score})>[];
        },
      );
      final out = await provider.rerank('q', const []);
      expect(out, isEmpty);
      expect(called, isFalse);
    });
  });

  group('E — MockReplayDataSourceProvider wraps without behavior change', () {
    const provider = MockReplayDataSourceProvider();

    test('reports the locked provider id and source system', () {
      expect(provider.providerId, equals('mock_replay'));
      expect(provider.sourceSystem,
          equals(MockIntegrationReplaySeed.sourceSystem));
    });

    test('default business date matches MockIntegrationReplaySeed', () {
      expect(provider.defaultBusinessDate,
          equals(MockIntegrationReplaySeed.defaultBusinessDate));
    });

    test('fetch() with no business date returns the same shape as the writer',
        () async {
      final out = await provider.fetch();
      final direct = MockIntegrationReplaySeed.generateForDate(
          MockIntegrationReplaySeed.defaultBusinessDate);

      // Equality through the provenance fields the wrapped writer exposes.
      expect(out.scenario.currentBusinessDate,
          equals(direct.scenario.currentBusinessDate));
      expect(out.scenario.currentWeekId,
          equals(direct.scenario.currentWeekId));
      expect(out.scenario.openShiftDayLabel,
          equals(direct.scenario.openShiftDayLabel));
      expect(out.scenario.openShiftDaypart,
          equals(direct.scenario.openShiftDaypart));
      expect(out.historicalClosedShifts.length,
          equals(direct.historicalClosedShifts.length));
      expect(out.currentWeekShifts.length,
          equals(direct.currentWeekShifts.length));
      expect(out.weekRecords.length, equals(direct.weekRecords.length));
    });

    test('fetch(businessDate: ...) routes through the writer', () async {
      final out = await provider.fetch(
          businessDate: MockIntegrationReplaySeed.defaultBusinessDate);
      expect(out.scenario.currentBusinessDate,
          equals(MockIntegrationReplaySeed.defaultBusinessDate));
    });
  });

  group('F — AdvisorModelRouting resolves overrides honestly', () {
    test('defaults route to the pinned Haiku/Sonnet ids', () {
      const r = AdvisorModelRouting.defaults;
      expect(r.effectiveQuickModelId, equals('claude-haiku-4-5'));
      expect(r.effectiveNuancedModelId, equals('claude-sonnet-4-6'));
      expect(r.quickSource, equals(AdvisorModelSource.defaultPinned));
      expect(r.nuancedSource, equals(AdvisorModelSource.defaultPinned));
      expect(r.sourceLabelForTier(LLMTier.quick), equals('Default'));
      expect(r.sourceLabelForTier(LLMTier.nuanced), equals('Default'));
    });

    test('quick override flips quick to Override and leaves nuanced default',
        () {
      final r = AdvisorModelRouting.resolve(quickOverride: 'claude-future-quick');
      expect(r.effectiveQuickModelId, equals('claude-future-quick'));
      expect(r.quickSource, equals(AdvisorModelSource.userOverride));
      expect(r.effectiveNuancedModelId, equals('claude-sonnet-4-6'));
      expect(r.nuancedSource, equals(AdvisorModelSource.defaultPinned));
      expect(r.sourceLabelForTier(LLMTier.quick), equals('Override'));
    });

    test('nuanced override flips nuanced to Override and leaves quick default',
        () {
      final r = AdvisorModelRouting.resolve(
          nuancedOverride: 'claude-future-nuanced');
      expect(r.effectiveNuancedModelId, equals('claude-future-nuanced'));
      expect(r.nuancedSource, equals(AdvisorModelSource.userOverride));
      expect(r.effectiveQuickModelId, equals('claude-haiku-4-5'));
      expect(r.quickSource, equals(AdvisorModelSource.defaultPinned));
    });

    test('whitespace / empty override strings count as no override', () {
      final r = AdvisorModelRouting.resolve(
        quickOverride: '   ',
        nuancedOverride: '',
      );
      expect(r.quickSource, equals(AdvisorModelSource.defaultPinned));
      expect(r.nuancedSource, equals(AdvisorModelSource.defaultPinned));
    });

    test('Voyage values are pinned read-only', () {
      const r = AdvisorModelRouting.defaults;
      expect(r.voyageEmbeddingProviderId, equals('voyage'));
      expect(r.voyageEmbeddingModelId, equals('voyage-4-large'));
      expect(r.voyageEmbeddingDimensions, equals(1024));
      expect(r.voyageRerankProviderId, equals('voyage'));
      expect(r.voyageRerankModelId, equals('rerank-2.5'));
    });
  });

  group('G — ClaudeLLMProvider honors injected routing', () {
    Future<String> fakeFn({
      required String modelId,
      required String question,
      required String context,
    }) async =>
        modelId;

    test('default routing -> default model ids', () async {
      final p = ClaudeLLMProvider(completeFn: fakeFn);
      expect((await p.complete(question: 'q', context: 'c')).modelId,
          equals('claude-haiku-4-5'));
      expect(
          (await p.complete(
                  question: 'q', context: 'c', tier: LLMTier.nuanced))
              .modelId,
          equals('claude-sonnet-4-6'));
    });

    test('routing with overrides flows into both tiers', () async {
      final r = AdvisorModelRouting.resolve(
        quickOverride: 'override-quick',
        nuancedOverride: 'override-nuanced',
      );
      final p = ClaudeLLMProvider(completeFn: fakeFn, routing: r);
      expect(p.modelIdFor(LLMTier.quick), equals('override-quick'));
      expect(p.modelIdFor(LLMTier.nuanced), equals('override-nuanced'));
      expect((await p.complete(question: 'q', context: 'c')).modelId,
          equals('override-quick'));
    });
  });

  group('H — AdvisorModelConfigService persists overrides + reset', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('save quick override is observable in currentRouting()', () async {
      final svc = AdvisorModelConfigService(
        onlineCheckFn: ({
          required String quickModelId,
          required String nuancedModelId,
        }) async =>
            const AnthropicModelCheckResult.cannotCheck('test'),
      );
      await svc.saveQuickOverride('my-haiku');
      final r = await svc.currentRouting();
      expect(r.effectiveQuickModelId, equals('my-haiku'));
      expect(r.quickSource, equals(AdvisorModelSource.userOverride));
      expect(r.nuancedSource, equals(AdvisorModelSource.defaultPinned));
    });

    test('reset removes both overrides', () async {
      final svc = AdvisorModelConfigService(
        onlineCheckFn: ({
          required String quickModelId,
          required String nuancedModelId,
        }) async =>
            const AnthropicModelCheckResult.cannotCheck('test'),
      );
      await svc.saveQuickOverride('q');
      await svc.saveNuancedOverride('n');
      await svc.resetOverrides();
      final r = await svc.currentRouting();
      expect(r.quickSource, equals(AdvisorModelSource.defaultPinned));
      expect(r.nuancedSource, equals(AdvisorModelSource.defaultPinned));
      expect(r.effectiveQuickModelId, equals('claude-haiku-4-5'));
      expect(r.effectiveNuancedModelId, equals('claude-sonnet-4-6'));
    });

    test('saving an empty/whitespace override clears the entry', () async {
      final svc = AdvisorModelConfigService(
        onlineCheckFn: ({
          required String quickModelId,
          required String nuancedModelId,
        }) async =>
            const AnthropicModelCheckResult.cannotCheck('test'),
      );
      await svc.saveQuickOverride('temp');
      await svc.saveQuickOverride('   ');
      final r = await svc.currentRouting();
      expect(r.quickSource, equals(AdvisorModelSource.defaultPinned));
    });
  });

  group('I — Anthropic online check tri-state via injected fake', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('available when fake returns both effective ids', () async {
      final svc = AdvisorModelConfigService(
        onlineCheckFn: ({
          required String quickModelId,
          required String nuancedModelId,
        }) async =>
            AnthropicModelCheckResult(
          status: AnthropicModelCheckStatus.available,
          message: 'ok',
          seenModelIds: [quickModelId, nuancedModelId],
        ),
      );
      final result = await svc.checkAvailableModels();
      expect(result.status, equals(AnthropicModelCheckStatus.available));
      expect(result.seenModelIds, contains('claude-haiku-4-5'));
      expect(result.seenModelIds, contains('claude-sonnet-4-6'));
    });

    test('unavailable when fake omits one effective id', () async {
      final svc = AdvisorModelConfigService(
        onlineCheckFn: ({
          required String quickModelId,
          required String nuancedModelId,
        }) async =>
            const AnthropicModelCheckResult(
          status: AnthropicModelCheckStatus.unavailable,
          message: 'sonnet missing',
          seenModelIds: ['claude-haiku-4-5'],
        ),
      );
      final result = await svc.checkAvailableModels();
      expect(result.status, equals(AnthropicModelCheckStatus.unavailable));
      expect(result.message, contains('sonnet'));
    });

    test('cannotCheck when fake reports it', () async {
      final svc = AdvisorModelConfigService(
        onlineCheckFn: ({
          required String quickModelId,
          required String nuancedModelId,
        }) async =>
            const AnthropicModelCheckResult.cannotCheck(
                'no api key in test env'),
      );
      final result = await svc.checkAvailableModels();
      expect(result.status, equals(AnthropicModelCheckStatus.cannotCheck));
      expect(result.message, contains('api key'));
    });
  });

  group('J — findUpdateCandidate detects newer same-family ids', () {
    test('returns the lex-greatest family id strictly newer than configured',
        () {
      final ids = [
        'claude-haiku-4-5',
        'claude-sonnet-4-6',
        'claude-sonnet-4-7',
      ];
      expect(
        findUpdateCandidate(ids, 'claude-sonnet-4-6',
            (id) => id.contains('sonnet')),
        equals('claude-sonnet-4-7'),
      );
    });

    test('returns null when configured is already the family-latest', () {
      final ids = ['claude-haiku-4-5', 'claude-sonnet-4-6'];
      expect(
        findUpdateCandidate(ids, 'claude-sonnet-4-6',
            (id) => id.contains('sonnet')),
        isNull,
      );
    });

    test('returns null when no same-family id is in the list', () {
      final ids = ['claude-haiku-4-5'];
      expect(
        findUpdateCandidate(ids, 'claude-sonnet-4-6',
            (id) => id.contains('sonnet')),
        isNull,
      );
    });

    test('handles date-stamped id ordering', () {
      final ids = [
        'claude-3-5-haiku-20241022',
        'claude-3-5-haiku-20250307',
      ];
      expect(
        findUpdateCandidate(ids, 'claude-3-5-haiku-20241022',
            (id) => id.contains('haiku')),
        equals('claude-3-5-haiku-20250307'),
      );
    });

    test('two-digit version segments rank above one-digit segments', () {
      // Regression: naive lex sort puts `claude-sonnet-4-10` BEFORE
      // `claude-sonnet-4-6` because '1' < '6' as a char. The
      // segment-aware comparator must rank `4-10` above `4-6`.
      final ids = [
        'claude-sonnet-4-6',
        'claude-sonnet-4-10',
      ];
      expect(
        findUpdateCandidate(ids, 'claude-sonnet-4-6',
            (id) => id.contains('sonnet')),
        equals('claude-sonnet-4-10'),
      );
    });

    test('two-digit configured stays up-to-date over one-digit candidates', () {
      // Symmetric regression: `4-10` configured must NOT be flagged
      // as outdated by a `4-6` sibling under segment-aware ordering.
      final ids = [
        'claude-sonnet-4-6',
        'claude-sonnet-4-10',
      ];
      expect(
        findUpdateCandidate(ids, 'claude-sonnet-4-10',
            (id) => id.contains('sonnet')),
        isNull,
      );
    });
  });

  group('K — Anthropic check is update-aware', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('available + up-to-date when configured ids are family-latest',
        () async {
      final svc = AdvisorModelConfigService(
        onlineCheckFn: ({
          required String quickModelId,
          required String nuancedModelId,
        }) async =>
            AnthropicModelCheckResult(
          status: AnthropicModelCheckStatus.available,
          message: 'Both up-to-date',
          seenModelIds: [quickModelId, nuancedModelId],
          updateAvailable: false,
        ),
      );
      final r = await svc.checkAvailableModels();
      expect(r.status, equals(AnthropicModelCheckStatus.available));
      expect(r.updateAvailable, isFalse);
      expect(r.latestQuickCandidate, isNull);
      expect(r.latestNuancedCandidate, isNull);
    });

    test('available + update-available when newer family id seen', () async {
      final svc = AdvisorModelConfigService(
        onlineCheckFn: ({
          required String quickModelId,
          required String nuancedModelId,
        }) async =>
            AnthropicModelCheckResult(
          status: AnthropicModelCheckStatus.available,
          message: 'Update candidate found',
          seenModelIds: [
            quickModelId,
            nuancedModelId,
            'claude-sonnet-4-7',
          ],
          updateAvailable: true,
          latestNuancedCandidate: 'claude-sonnet-4-7',
        ),
      );
      final r = await svc.checkAvailableModels();
      expect(r.status, equals(AnthropicModelCheckStatus.available));
      expect(r.updateAvailable, isTrue);
      expect(r.latestNuancedCandidate, equals('claude-sonnet-4-7'));
    });

    test('cannotCheck constructor preserves zero-update fields', () {
      const r = AnthropicModelCheckResult.cannotCheck('no key');
      expect(r.updateAvailable, isFalse);
      expect(r.latestQuickCandidate, isNull);
      expect(r.latestNuancedCandidate, isNull);
    });
  });
}
