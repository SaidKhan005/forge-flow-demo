// G4 C3: Semantic extraction tooling unit tests.
//
// ALL tests use a mock [AdvisorSemanticExtractionGateway].
// No real LLM, no network, no paid API calls are made here.
// Run with: flutter test test/tool/advisor_corpus/semantic_extraction_test.dart
//
// Coverage:
//   - C3 vocabulary completeness (kC3NodeKinds, kC3EdgeTypes, kC3EdgeVerbPhrases)
//   - Node/edge vocab validation + AMBIGUOUS fallback
//   - Idempotency key skip logic
//   - HP#9 cost record accumulation
//   - JSONL output format matches GraphifyCandidateImporter shape
//   - Merge-with-prior logic (re-run preserves prior candidates)
//   - manifest proxy_endpoint_needed flag

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_corpus/advisor_corpus.dart';

// ─── Mock gateway ──────────────────────────────────────────────────────────────

/// A mock gateway that accepts a list of raw JSON strings to return per call.
/// Each element of [rawJsonResponses] is returned for successive calls.
class _MockGateway implements AdvisorSemanticExtractionGateway {
  _MockGateway({
    required this.rawJsonResponses,
    this.estimatedInputTokens = 500,
    this.estimatedOutputTokens = 200,
  });

  /// Queue of raw JSON responses ({"nodes":[...],"edges":[...]}) per call.
  final List<String> rawJsonResponses;
  final int estimatedInputTokens;
  final int estimatedOutputTokens;
  int callCount = 0;

  @override
  Future<SemanticExtractionResponse> extractFromChunk({
    required String apiKey,
    required String model,
    required String documentTitle,
    required String sourcePath,
    required List<String> headingPath,
    required String chunkText,
    required Set<String> nodeKinds,
    required Set<String> edgeTypes,
    required Map<String, String> edgeVerbPhrases,
  }) async {
    final index = callCount.clamp(0, rawJsonResponses.length - 1);
    callCount += 1;
    return _makeResponse(
      rawJsonResponses[index],
      estimatedInputTokens,
      estimatedOutputTokens,
    );
  }
}

SemanticExtractionResponse _makeResponse(
  String rawJson,
  int inputTokens,
  int outputTokens,
) {
  final Map<String, Object?> parsed;
  try {
    parsed = jsonDecode(rawJson) as Map<String, Object?>;
  } catch (e) {
    throw CorpusManifestException(
      'Mock: invalid JSON: $e',
    );
  }
  final rawNodes = (parsed['nodes'] as List?) ?? const <Object?>[];
  final rawEdges = (parsed['edges'] as List?) ?? const <Object?>[];

  final nodes = <SemanticNodeExtraction>[];
  for (final entry in rawNodes) {
    if (entry is! Map<String, Object?>) continue;
    final nodeKey = entry['key']?.toString().trim() ?? '';
    if (nodeKey.isEmpty) continue;
    final rawKind = entry['kind']?.toString().trim() ?? '';
    final rawLabel = entry['label']?.toString().trim().toUpperCase() ?? '';
    final isValidKind = kC3NodeKinds.contains(rawKind);
    final resolvedKind = isValidKind ? rawKind : 'Concept';
    final resolvedLabel =
        (!isValidKind || rawLabel == 'AMBIGUOUS')
        ? 'AMBIGUOUS'
        : (rawLabel == 'INFERRED' ? 'INFERRED' : 'EXTRACTED');
    nodes.add(
      SemanticNodeExtraction(
        nodeKey: nodeKey,
        kind: resolvedKind,
        label: resolvedLabel,
        verbatimText: entry['verbatim']?.toString().trim() ?? '',
      ),
    );
  }

  final edges = <SemanticEdgeExtraction>[];
  for (final entry in rawEdges) {
    if (entry is! Map<String, Object?>) continue;
    final fromKey = entry['from']?.toString().trim() ?? '';
    final toKey = entry['to']?.toString().trim() ?? '';
    if (fromKey.isEmpty || toKey.isEmpty) continue;
    final rawType = entry['type']?.toString().trim() ?? '';
    final rawLabel = entry['label']?.toString().trim().toUpperCase() ?? '';
    final isValidType = kC3EdgeTypes.contains(rawType);
    final resolvedType = isValidType ? rawType : 'RELATES_TO';
    final resolvedLabel =
        (!isValidType || rawLabel == 'AMBIGUOUS')
        ? 'AMBIGUOUS'
        : (rawLabel == 'INFERRED' ? 'INFERRED' : 'EXTRACTED');
    edges.add(
      SemanticEdgeExtraction(
        fromNodeKey: fromKey,
        toNodeKey: toKey,
        edgeType: resolvedType,
        label: resolvedLabel,
        verbatimText: entry['verbatim']?.toString().trim() ?? '',
      ),
    );
  }

  return SemanticExtractionResponse(
    nodes: nodes,
    edges: edges,
    estimatedInputTokens: inputTokens,
    estimatedOutputTokens: outputTokens,
  );
}

// ─── Fixture helpers ───────────────────────────────────────────────────────────

Future<Directory> _createFixtureRepo({
  String content = _headingMarkdown,
}) async {
  final repo = await Directory.systemTemp.createTemp('semantic_test_');
  await Directory('${repo.path}/docs/Knowledge_graph_docs').create(
    recursive: true,
  );
  await Directory('${repo.path}/build/advisor_corpus').create(recursive: true);

  final sourceFile = File(
    '${repo.path}/docs/Knowledge_graph_docs/sample.md',
  );
  await sourceFile.writeAsString(content);
  final hash = await sha256ForFile(sourceFile);

  await File('${repo.path}/$defaultManifestPath').writeAsString('''
manifest_version: 1
updated: "2026-05-26"
corpus_root: "docs/Knowledge_graph_docs"
default_scope: "global_shared_methodology"
default_restaurant_id: null
authorship_policy: "founder_authored_or_founder_synthesized_only"
markdown_only: true

excluded_sources:
  - file_name: "$excludedEmptyApronFileName"
    status: "excluded"
    reason: "excluded_for_testing"

documents:
  - doc_id: "sample_doc"
    file_name: "sample.md"
    source_path: "docs/Knowledge_graph_docs/sample.md"
    title: "Sample Handbook"
    status: "included"
    scope: "global_shared_methodology"
    restaurant_id: null
    brand_context: "fixture"
    content_role: "operating_handbook"
    authority_tier: "primary_founder_operating_material"
    risk_level: "medium"
    audience:
      - "managers"
    chunk_profile: "heading_aware_policy_handbook"
    graph_profiles:
      - "Concept"
    tags:
      - "fixture"
    word_count_estimate: 10
    heading_count: 2
    line_count: 10
    sha256: "$hash"
''');
  return repo;
}

Future<void> _materializeChunks(Directory repo) async {
  final validator = CorpusValidator(repoRoot: repo);
  final validation = await validator.validate();
  final planner = CorpusChunkPlanner(repoRoot: repo);
  final plan = await planner.plan(validation.manifest);
  final materializer = CorpusIngestionMaterializer(repoRoot: repo);
  await materializer.materialize(manifest: validation.manifest, plan: plan);
}

const String _headingMarkdown = '''
# Sample Handbook

Introductory section about food-safety compliance.

## Food Safety

CPLH must stay above 85. A risk of cross-contamination exists when raw proteins
contact cooked produce. The BOH manager governs food-safety SOPs.
''';

/// A JSON string returning one Metric node + one INFORMS edge.
String _metricNodeJson() => jsonEncode(<String, Object?>{
      'nodes': <Map<String, Object?>>[
        <String, Object?>{
          'key': 'CPLH',
          'kind': 'Metric',
          'label': 'EXTRACTED',
          'verbatim': 'CPLH must stay above 85.',
        },
      ],
      'edges': <Map<String, Object?>>[
        <String, Object?>{
          'from': 'CPLH',
          'to': 'food-safety',
          'type': 'INFORMS',
          'label': 'EXTRACTED',
          'verbatim': 'CPLH informs food-safety.',
        },
      ],
    });

/// A JSON string returning a Role node with a GOVERNS edge.
String _roleNodeJson() => jsonEncode(<String, Object?>{
      'nodes': <Map<String, Object?>>[
        <String, Object?>{
          'key': 'BOH manager',
          'kind': 'Role',
          'label': 'EXTRACTED',
          'verbatim': 'The BOH manager governs food-safety SOPs.',
        },
      ],
      'edges': const <Object?>[],
    });

/// A JSON string with an unknown node kind and an unknown edge type.
String _unknownVocabJson() => jsonEncode(<String, Object?>{
      'nodes': <Map<String, Object?>>[
        <String, Object?>{
          'key': 'SomeConcept',
          'kind': 'UnrecognisedKind',
          'label': 'EXTRACTED',
          'verbatim': 'text',
        },
      ],
      'edges': <Map<String, Object?>>[
        <String, Object?>{
          'from': 'A',
          'to': 'B',
          'type': 'FAKE_TYPE',
          'label': 'EXTRACTED',
          'verbatim': 'text',
        },
      ],
    });

/// Empty response.
String _emptyJson() => jsonEncode(<String, Object?>{
      'nodes': const <Object?>[],
      'edges': const <Object?>[],
    });

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  // ── C3 vocabulary completeness ──────────────────────────────────────────────

  group('C3 vocabulary (sealed at migration 202605261200)', () {
    test('kC3NodeKinds contains all 13 migration-sealed kinds', () {
      const expectedKinds = <String>{
        'Concept',
        'SOP',
        'Policy',
        'Metric',
        'Formula',
        'Risk',
        'Word_To_Know',
        'Coaching_Move',
        'Role',
        'Workflow',
        'Document',
        'Chunk',
        'Procedure',
      };
      for (final kind in expectedKinds) {
        expect(
          kC3NodeKinds,
          contains(kind),
          reason: 'Missing C3 node kind: $kind',
        );
      }
      expect(kC3NodeKinds.length, 13);
    });

    test('kC3EdgeTypes contains all 15 migration-sealed edge types', () {
      const expectedTypes = <String>{
        'CONTAINS',
        'CAUSES',
        'INFORMS',
        'RELATES_TO',
        'DEPENDS_ON',
        'GOVERNS',
        'MITIGATES',
        'TEACHES',
        'DEFINES',
        'MEASURES',
        'CALCULATES',
        'REDUCES_RISK_OF',
        'REQUIRES',
        'PART_OF',
        'NEAR',
      };
      for (final type in expectedTypes) {
        expect(
          kC3EdgeTypes,
          contains(type),
          reason: 'Missing C3 edge type: $type',
        );
      }
      expect(kC3EdgeTypes.length, 15);
    });

    test('kC3EdgeVerbPhrases covers all kC3EdgeTypes', () {
      for (final edgeType in kC3EdgeTypes) {
        expect(
          kC3EdgeVerbPhrases.containsKey(edgeType),
          isTrue,
          reason: 'Missing verb phrase for edge type: $edgeType',
        );
        expect(
          kC3EdgeVerbPhrases[edgeType],
          isNotEmpty,
          reason: 'Empty verb phrase for edge type: $edgeType',
        );
      }
    });

    test('no C3 edge type wire value contains an em dash', () {
      for (final type in kC3EdgeTypes) {
        expect(
          type.contains('—'),
          isFalse,
          reason: 'Em dash in edge type: $type',
        );
      }
      for (final phrase in kC3EdgeVerbPhrases.values) {
        expect(
          phrase.contains('—'),
          isFalse,
          reason: 'Em dash in verb phrase: $phrase',
        );
      }
    });
  });

  // ── Vocab validation (via mock gateway) ─────────────────────────────────────

  group('Vocab validation + AMBIGUOUS fallback (mock gateway)', () {
    test('accepts valid C3 node kinds and edge types', () async {
      final response = _makeResponse(_metricNodeJson(), 500, 200);
      expect(response.nodes, hasLength(1));
      expect(response.nodes.first.kind, 'Metric');
      expect(response.nodes.first.label, 'EXTRACTED');
      expect(response.edges, hasLength(1));
      expect(response.edges.first.edgeType, 'INFORMS');
      expect(response.edges.first.label, 'EXTRACTED');
    });

    test('remaps unknown node kind to Concept + marks AMBIGUOUS', () async {
      final response = _makeResponse(_unknownVocabJson(), 300, 100);
      expect(response.nodes, hasLength(1));
      expect(response.nodes.first.kind, 'Concept');
      expect(response.nodes.first.label, 'AMBIGUOUS');
    });

    test('remaps unknown edge type to RELATES_TO + marks AMBIGUOUS', () async {
      final response = _makeResponse(_unknownVocabJson(), 300, 100);
      expect(response.edges, hasLength(1));
      expect(response.edges.first.edgeType, 'RELATES_TO');
      expect(response.edges.first.label, 'AMBIGUOUS');
    });

    test('already-AMBIGUOUS label is preserved', () async {
      final json = jsonEncode(<String, Object?>{
        'nodes': <Map<String, Object?>>[
          <String, Object?>{
            'key': 'something',
            'kind': 'Concept',
            'label': 'AMBIGUOUS',
            'verbatim': 'text',
          },
        ],
        'edges': const <Object?>[],
      });
      final response = _makeResponse(json, 200, 50);
      expect(response.nodes.first.label, 'AMBIGUOUS');
    });

    test('INFERRED label is preserved for valid vocab', () async {
      final json = jsonEncode(<String, Object?>{
        'nodes': <Map<String, Object?>>[
          <String, Object?>{
            'key': 'cross-contamination',
            'kind': 'Risk',
            'label': 'INFERRED',
            'verbatim': 'risk of cross-contamination',
          },
        ],
        'edges': const <Object?>[],
      });
      final response = _makeResponse(json, 200, 50);
      expect(response.nodes.first.label, 'INFERRED');
      expect(response.nodes.first.kind, 'Risk');
    });

    test('skips nodes with empty key', () async {
      final json = jsonEncode(<String, Object?>{
        'nodes': <Map<String, Object?>>[
          <String, Object?>{
            'key': '',
            'kind': 'Concept',
            'label': 'EXTRACTED',
            'verbatim': 'text',
          },
        ],
        'edges': const <Object?>[],
      });
      final response = _makeResponse(json, 200, 50);
      expect(response.nodes, isEmpty);
    });

    test('skips edges with empty from or to', () async {
      final json = jsonEncode(<String, Object?>{
        'nodes': const <Object?>[],
        'edges': <Map<String, Object?>>[
          <String, Object?>{
            'from': '',
            'to': 'B',
            'type': 'GOVERNS',
            'label': 'EXTRACTED',
            'verbatim': 'text',
          },
          <String, Object?>{
            'from': 'A',
            'to': '',
            'type': 'GOVERNS',
            'label': 'EXTRACTED',
            'verbatim': 'text',
          },
        ],
      });
      final response = _makeResponse(json, 200, 50);
      expect(response.edges, isEmpty);
    });

    test('returns empty lists for empty arrays', () async {
      final response = _makeResponse(_emptyJson(), 100, 20);
      expect(response.nodes, isEmpty);
      expect(response.edges, isEmpty);
    });
  });

  // ── Extractor integration (no real API) ─────────────────────────────────────

  group('CorpusSemanticExtractor (mocked gateway, no paid API)', () {
    test('processes chunks, writes JSONL candidates, emits cost records',
        () async {
      final repo = await _createFixtureRepo();
      await _materializeChunks(repo);

      final gateway = _MockGateway(
        rawJsonResponses: <String>[_metricNodeJson(), _roleNodeJson()],
        estimatedInputTokens: 400,
        estimatedOutputTokens: 150,
      );

      final outputDir = '${repo.path}/build/semantic_out';
      final extractor = CorpusSemanticExtractor(
        repoRoot: repo,
        gateway: gateway,
      );

      final result = await extractor.extract(
        outputDirectory: outputDir,
        apiKey: 'test-sentinel-not-real',
      );

      expect(result.processedChunkCount, greaterThan(0));
      expect(result.skippedChunkCount, 0);
      expect(result.nodeCandidateCount, greaterThan(0));
      expect(result.costRecords, hasLength(result.processedChunkCount));
      expect(result.totalEstimatedInputTokens, greaterThan(0));
      expect(result.totalEstimatedOutputTokens, greaterThan(0));

      final nodeFile = File('$outputDir/$semanticNodeCandidatesFileName');
      final edgeFile = File('$outputDir/$semanticEdgeCandidatesFileName');
      final manifestFile = File(
        '$outputDir/$semanticExtractionManifestFileName',
      );
      expect(nodeFile.existsSync(), isTrue);
      expect(edgeFile.existsSync(), isTrue);
      expect(manifestFile.existsSync(), isTrue);
    });

    test('node candidate JSONL format matches GraphifyCandidateImporter shape',
        () async {
      final repo = await _createFixtureRepo();
      await _materializeChunks(repo);

      final gateway = _MockGateway(
        rawJsonResponses: <String>[_metricNodeJson()],
      );

      final outputDir = '${repo.path}/build/semantic_shape_out';
      await CorpusSemanticExtractor(repoRoot: repo, gateway: gateway).extract(
        outputDirectory: outputDir,
        apiKey: 'test-sentinel-not-real',
      );

      final nodeFile = File('$outputDir/$semanticNodeCandidatesFileName');
      final lines = nodeFile
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .toList();
      expect(lines, isNotEmpty);
      final record = jsonDecode(lines.first) as Map<String, Object?>;

      // Required fields that the proxy commit path expects.
      expect(record['candidate_id'], isA<String>());
      expect(record['kind'], 'node');
      expect(record['candidate_key'], isA<String>());
      expect(record['candidate_type'], isA<String>());
      expect(record['label'], isA<String>());
      expect(record['payload'], isA<Map<String, Object?>>());
      expect(record['idempotency_key'], isA<String>());
      // candidate_type must be a C3-sealed node kind.
      expect(kC3NodeKinds.contains(record['candidate_type']), isTrue);
    });

    test('edge candidate JSONL includes from_node_key, to_node_key, verb_phrase',
        () async {
      final repo = await _createFixtureRepo();
      await _materializeChunks(repo);

      final edgeJson = jsonEncode(<String, Object?>{
        'nodes': const <Object?>[],
        'edges': <Map<String, Object?>>[
          <String, Object?>{
            'from': 'BOH manager',
            'to': 'food-safety SOPs',
            'type': 'GOVERNS',
            'label': 'EXTRACTED',
            'verbatim': 'BOH manager governs food-safety SOPs.',
          },
        ],
      });

      final gateway = _MockGateway(rawJsonResponses: <String>[edgeJson]);
      final outputDir = '${repo.path}/build/semantic_edge_out';
      await CorpusSemanticExtractor(repoRoot: repo, gateway: gateway).extract(
        outputDirectory: outputDir,
        apiKey: 'test-sentinel-not-real',
      );

      final edgeFile = File('$outputDir/$semanticEdgeCandidatesFileName');
      final lines = edgeFile
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .toList();
      expect(lines, isNotEmpty);
      final record = jsonDecode(lines.first) as Map<String, Object?>;

      expect(record['kind'], 'edge');
      expect(record['from_node_key'], isA<String>());
      expect(record['to_node_key'], isA<String>());
      expect(kC3EdgeTypes.contains(record['candidate_type']), isTrue);
      final payload = record['payload'] as Map<String, Object?>;
      expect(payload['verb_phrase'], isA<String>());
      final verbPhrase = payload['verb_phrase']! as String;
      expect(verbPhrase, isNotEmpty);
      // GOVERNS verb phrase from the sealed vocab.
      expect(verbPhrase, kC3EdgeVerbPhrases['GOVERNS']);
    });

    test('HP#9 cost records are accumulated per processed chunk', () async {
      final repo = await _createFixtureRepo();
      await _materializeChunks(repo);

      final gateway = _MockGateway(
        rawJsonResponses: <String>[_emptyJson()],
        estimatedInputTokens: 700,
        estimatedOutputTokens: 250,
      );

      final outputDir = '${repo.path}/build/semantic_cost_out';
      final result = await CorpusSemanticExtractor(
        repoRoot: repo,
        gateway: gateway,
      ).extract(
        outputDirectory: outputDir,
        apiKey: 'test-sentinel-not-real',
      );

      for (final record in result.costRecords) {
        expect(record.costClass, advisorSemanticCostClass);
        expect(record.provider, isNotEmpty);
        expect(record.model, isNotEmpty);
        expect(record.chunkId, isNotEmpty);
        expect(record.contentSha256, isNotEmpty);
        expect(record.estimatedInputTokens, 700);
        expect(record.estimatedOutputTokens, 250);
      }

      final manifest = jsonDecode(
        File('$outputDir/$semanticExtractionManifestFileName')
            .readAsStringSync(),
      ) as Map<String, Object?>;
      expect(manifest['hp9_cost_class'], advisorSemanticCostClass);
      final costRecordsInManifest =
          manifest['hp9_cost_records']! as List<Object?>;
      expect(costRecordsInManifest.length, result.processedChunkCount);
    });

    test('manifest flags proxy_endpoint_needed as true', () async {
      final repo = await _createFixtureRepo();
      await _materializeChunks(repo);

      final gateway = _MockGateway(rawJsonResponses: <String>[_emptyJson()]);
      final outputDir = '${repo.path}/build/semantic_proxy_out';
      await CorpusSemanticExtractor(repoRoot: repo, gateway: gateway).extract(
        outputDirectory: outputDir,
        apiKey: 'test-sentinel-not-real',
      );

      final manifest = jsonDecode(
        File('$outputDir/$semanticExtractionManifestFileName')
            .readAsStringSync(),
      ) as Map<String, Object?>;
      expect(manifest['proxy_endpoint_needed'], isTrue);
      expect(
        manifest['proxy_endpoint_note']?.toString(),
        contains('proxy endpoint'),
      );
    });

    test('idempotency: re-run skips chunks already in output JSONL', () async {
      final repo = await _createFixtureRepo();
      await _materializeChunks(repo);

      final gateway = _MockGateway(rawJsonResponses: <String>[_metricNodeJson()]);
      final outputDir = '${repo.path}/build/semantic_idempotent_out';
      final extractor = CorpusSemanticExtractor(
        repoRoot: repo,
        gateway: gateway,
      );

      // First run.
      final firstResult = await extractor.extract(
        outputDirectory: outputDir,
        apiKey: 'test-sentinel-not-real',
      );
      expect(firstResult.processedChunkCount, greaterThan(0));
      expect(firstResult.skippedChunkCount, 0);
      final firstCallCount = gateway.callCount;

      // Second run: all chunks already present (no API key needed).
      final secondResult = await extractor.extract(outputDirectory: outputDir);
      expect(secondResult.processedChunkCount, 0);
      expect(secondResult.skippedChunkCount, firstResult.processedChunkCount);
      // Gateway was NOT called again.
      expect(gateway.callCount, firstCallCount);
    });

    test('re-run preserves prior candidates (merge-with-prior)', () async {
      final repo = await _createFixtureRepo();
      await _materializeChunks(repo);

      final gateway = _MockGateway(rawJsonResponses: <String>[_metricNodeJson()]);
      final outputDir = '${repo.path}/build/semantic_merge_out';
      final extractor = CorpusSemanticExtractor(
        repoRoot: repo,
        gateway: gateway,
      );

      final firstResult = await extractor.extract(
        outputDirectory: outputDir,
        apiKey: 'test-sentinel-not-real',
      );
      final firstNodeCount = firstResult.nodeCandidateCount;
      expect(firstNodeCount, greaterThan(0));

      // Second run (idempotent): no candidates lost (no API key needed).
      final secondResult = await extractor.extract(outputDirectory: outputDir);
      expect(
        secondResult.nodeCandidateCount,
        greaterThanOrEqualTo(firstNodeCount),
      );
    });

    test('ambiguous fallback count is correct for unknown kinds/types', () async {
      final repo = await _createFixtureRepo();
      await _materializeChunks(repo);

      final gateway = _MockGateway(
        rawJsonResponses: <String>[_unknownVocabJson()],
      );

      final outputDir = '${repo.path}/build/semantic_ambig_out';
      final result = await CorpusSemanticExtractor(
        repoRoot: repo,
        gateway: gateway,
      ).extract(
        outputDirectory: outputDir,
        apiKey: 'test-sentinel-not-real',
      );

      // Every processed chunk has 1 AMBIGUOUS node + 1 AMBIGUOUS edge.
      expect(result.ambiguousNodeCount, result.processedChunkCount);
      expect(result.ambiguousEdgeCount, result.processedChunkCount);

      // Wire values in JSONL are the fallbacks (Concept / RELATES_TO).
      final nodeLines = File('$outputDir/$semanticNodeCandidatesFileName')
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .toList();
      for (final line in nodeLines) {
        final record = jsonDecode(line) as Map<String, Object?>;
        expect(kC3NodeKinds.contains(record['candidate_type']), isTrue);
        expect(record['label'], 'AMBIGUOUS');
      }
      final edgeLines = File('$outputDir/$semanticEdgeCandidatesFileName')
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .toList();
      for (final line in edgeLines) {
        final record = jsonDecode(line) as Map<String, Object?>;
        expect(kC3EdgeTypes.contains(record['candidate_type']), isTrue);
        expect(record['label'], 'AMBIGUOUS');
      }
    });

    test('manifest includes C3 vocab source migration reference', () async {
      final repo = await _createFixtureRepo();
      await _materializeChunks(repo);

      final gateway = _MockGateway(rawJsonResponses: <String>[_emptyJson()]);
      final outputDir = '${repo.path}/build/semantic_vocab_out';
      await CorpusSemanticExtractor(repoRoot: repo, gateway: gateway).extract(
        outputDirectory: outputDir,
        apiKey: 'test-sentinel-not-real',
      );

      final manifest = jsonDecode(
        File('$outputDir/$semanticExtractionManifestFileName')
            .readAsStringSync(),
      ) as Map<String, Object?>;
      final vocab = manifest['c3_vocab'] as Map<String, Object?>;
      expect(
        vocab['source_migration']?.toString(),
        contains('202605261200_phase_12_c3_typed_graph_vocabulary'),
      );
      final nodeKinds = vocab['node_kinds']! as List<Object?>;
      expect(nodeKinds.length, kC3NodeKinds.length);
      final edgeTypes = vocab['edge_types']! as List<Object?>;
      expect(edgeTypes.length, kC3EdgeTypes.length);
    });

    test('empty source_chunks.jsonl produces zero counts', () async {
      final repo = await Directory.systemTemp.createTemp('semantic_empty_');
      await Directory('${repo.path}/build/advisor_corpus').create(
        recursive: true,
      );
      await File(
        '${repo.path}/build/advisor_corpus/source_chunks.jsonl',
      ).writeAsString('');

      final gateway = _MockGateway(rawJsonResponses: <String>[_emptyJson()]);
      final outputDir = '${repo.path}/build/semantic_empty_out';
      final result = await CorpusSemanticExtractor(
        repoRoot: repo,
        gateway: gateway,
      ).extract(outputDirectory: outputDir);
      // No chunks to process, so API key guard is not triggered.

      expect(result.processedChunkCount, 0);
      expect(result.skippedChunkCount, 0);
      expect(result.nodeCandidateCount, 0);
      expect(result.edgeCandidateCount, 0);
      expect(result.costRecords, isEmpty);
    });
  });
}
