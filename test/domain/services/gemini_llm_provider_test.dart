// Forge & Flow — GeminiLLMProvider tests.
//
// Block 2 fallback slice. Mirrors the callback-injection style used by
// `provider_abstraction_test.dart` for ClaudeLLMProvider — no mocking
// framework, plain Dart closures as fakes, and the file under test
// stays SDK-free.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/llm_provider.dart';
import 'package:forge_and_flow/services/gemini_llm_provider.dart';

void main() {
  group('A — completion round-trip through the injected gateway', () {
    test('default tier round-trip captures args and wraps the reply', () async {
      String? capturedModelId;
      String? capturedQuestion;
      String? capturedContext;

      Future<String> fakeFn({
        required String modelId,
        required String question,
        required String context,
        void Function(String chunk)? onChunk,
      }) async {
        capturedModelId = modelId;
        capturedQuestion = question;
        capturedContext = context;
        return 'fake-gemini-answer';
      }

      final provider = GeminiLLMProvider(completeFn: fakeFn);
      final answer = await provider.complete(question: 'q', context: 'c');

      expect(answer.text, equals('fake-gemini-answer'));
      expect(answer.modelId, equals('gemini-2.5-flash'));
      expect(answer.tier, equals(LLMTier.quick));
      expect(capturedModelId, equals('gemini-2.5-flash'));
      expect(capturedQuestion, equals('q'));
      expect(capturedContext, equals('c'));
    });

    test('providerId is "gemini" and capabilities is empty', () {
      Future<String> fakeFn({
        required String modelId,
        required String question,
        required String context,
        void Function(String chunk)? onChunk,
      }) async =>
          '';

      final provider = GeminiLLMProvider(completeFn: fakeFn);
      expect(provider.providerId, equals('gemini'));
      expect(provider.capabilities, isEmpty);
    });
  });

  group('B — tier dispatch resolves quick/nuanced to flash/pro', () {
    Future<String> echoModelFn({
      required String modelId,
      required String question,
      required String context,
      void Function(String chunk)? onChunk,
    }) async =>
        modelId;

    test('quick tier resolves to gemini-2.5-flash', () async {
      final provider = GeminiLLMProvider(completeFn: echoModelFn);
      expect(provider.modelIdFor(LLMTier.quick), equals('gemini-2.5-flash'));

      final answer = await provider.complete(
        question: 'q',
        context: 'c',
        tier: LLMTier.quick,
      );
      expect(answer.modelId, equals('gemini-2.5-flash'));
      expect(answer.tier, equals(LLMTier.quick));
    });

    test('nuanced tier resolves to gemini-2.5-pro', () async {
      final provider = GeminiLLMProvider(completeFn: echoModelFn);
      expect(provider.modelIdFor(LLMTier.nuanced), equals('gemini-2.5-pro'));

      final answer = await provider.complete(
        question: 'q',
        context: 'c',
        tier: LLMTier.nuanced,
      );
      expect(answer.modelId, equals('gemini-2.5-pro'));
      expect(answer.tier, equals(LLMTier.nuanced));
    });
  });

  group('C — streaming round-trip via the onChunk seam', () {
    test('chunks observed in order and result equals concatenation', () async {
      const streamed = ['Hello', ' ', 'world'];
      Future<String> streamingFn({
        required String modelId,
        required String question,
        required String context,
        void Function(String chunk)? onChunk,
      }) async {
        for (final chunk in streamed) {
          onChunk?.call(chunk);
        }
        return streamed.join();
      }

      final chunks = <String>[];
      final provider = GeminiLLMProvider(
        completeFn: streamingFn,
        onChunkObserver: chunks.add,
      );
      final result = await provider.complete(question: 'q', context: 'c');

      expect(chunks, equals(['Hello', ' ', 'world']));
      expect(result.text, equals('Hello world'));
    });
  });
}
