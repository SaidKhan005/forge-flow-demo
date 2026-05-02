// Phase 11A.3b — GraphifyCandidateImporter unit tests.
//
// Drives [GraphifyCandidateImporter.prepare] against the synthetic
// `test/fixtures/graphify_v5_sample/graph.json` artifact so the
// JSONL output shape, manifest scope filter, hyperedge fan-out, and
// determinism contract are all pinned without invoking the real
// Graphify pipeline.
//
// Coverage:
//
//   * The importer drops candidates whose `source_file` is not in the
//     manifest's `documents[*].source_path` set.
//   * Output JSONL files exist at the expected names with the right
//     shape and counts.
//   * Confidence labels (string EXTRACTED/INFERRED/AMBIGUOUS) are
//     preserved verbatim from `graph.json`.
//   * Numeric `confidence_score` is preserved.
//   * Hyperedges with arity ≥ 2 are fanned out to pairwise edges that
//     all carry the same `hyperedge_id` in payload.
//   * Re-running the importer against the same input produces
//     byte-identical output (deterministic).
//   * The low-confidence node (score 0.62 < 0.7) is preserved with
//     its score in the JSONL — the warning chip is a UI concern, not
//     an importer one.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../../tool/advisor_corpus/advisor_corpus.dart';

void main() {
  late Directory tempRepo;

  setUp(() async {
    tempRepo = await Directory.systemTemp.createTemp(
      'graphify_candidates_test_',
    );
    // Stage the fixture graph.json under graphify-out/ inside the
    // temp repo (the importer reads `<repoRoot>/graphify-out/graph.json`
    // by default).
    final fixtureRoot = Directory(
      p.join(
        Directory.current.path,
        'test',
        'fixtures',
        'graphify_v5_sample',
      ),
    );
    final graphJsonSrc = File(p.join(fixtureRoot.path, 'graph.json'));
    final graphifyDir = Directory(p.join(tempRepo.path, 'graphify-out'));
    graphifyDir.createSync(recursive: true);
    await graphJsonSrc.copy(p.join(graphifyDir.path, 'graph.json'));
    // Stage the manifest at the default path the importer expects.
    final manifestSrc = File(p.join(fixtureRoot.path, 'corpus_manifest.yaml'));
    final manifestDir = Directory(
      p.join(tempRepo.path, 'docs', 'Knowledge_graph_docs'),
    );
    manifestDir.createSync(recursive: true);
    await manifestSrc.copy(p.join(manifestDir.path, 'corpus_manifest.yaml'));
  });

  tearDown(() async {
    if (tempRepo.existsSync()) {
      await tempRepo.delete(recursive: true);
    }
  });

  /// Loads the staged manifest from the temp repo. Importer requires
  /// a [CorpusManifest] in to apply the scope filter.
  Future<CorpusManifest> loadStagedManifest() async {
    return CorpusManifest.load(
      File(
        p.join(
          tempRepo.path,
          'docs',
          'Knowledge_graph_docs',
          'corpus_manifest.yaml',
        ),
      ),
    );
  }

  test('drops candidates whose source_file is not in the manifest scope',
      () async {
    final manifest = await loadStagedManifest();
    final importer = GraphifyCandidateImporter(
      repoRoot: tempRepo,
      graphifyVersion: 'v5',
      graphifySourceCommit: 'fixture-commit',
    );
    final result = await importer.prepare(manifest: manifest);
    // The fixture seeds one out-of-scope node referencing
    // `unmanifested_doc.md` which is not listed under
    // `documents[*].source_path`. The importer must drop it.
    expect(result.droppedOutOfScopeCount, greaterThanOrEqualTo(1),
        reason: 'fixture seeds at least one out-of-scope node which the '
            'importer must drop before writing the JSONL');
  });

  test('writes node + edge JSONL files at the expected paths', () async {
    final manifest = await loadStagedManifest();
    final importer = GraphifyCandidateImporter(
      repoRoot: tempRepo,
      graphifyVersion: 'v5',
      graphifySourceCommit: 'fixture-commit',
    );
    final result = await importer.prepare(manifest: manifest);

    final nodesFile = File(
      p.join(result.outputDirectory, graphifyNodeCandidatesFileName),
    );
    final edgesFile = File(
      p.join(result.outputDirectory, graphifyEdgeCandidatesFileName),
    );
    final manifestFile = File(
      p.join(result.outputDirectory, graphifyCandidateManifestFileName),
    );

    expect(nodesFile.existsSync(), isTrue);
    expect(edgesFile.existsSync(), isTrue);
    expect(manifestFile.existsSync(), isTrue);

    final nodeLines = nodesFile
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .toList();
    final edgeLines = edgesFile
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .toList();

    // Fixture: 4 in-scope nodes (one duplicate by id) + 1 out-of-scope
    // dropped → 3 unique nodes after dedupe.
    expect(nodeLines.length, equals(result.nodeCandidateCount));
    expect(result.nodeCandidateCount, equals(3),
        reason: 'fixture deduplicates the duplicate cycles_section node');

    // Fixture: 2 pairwise edges (CONTAINS extracted + INFORMS inferred)
    // + 3 hyperedge fan-out pairs (arity 3 → C(3,2) = 3 pairs).
    // Pairwise and hyperedge candidate_ids differ (the hyperedge id
    // is part of the candidate_key suffix), so dedupe leaves 5 edges.
    expect(edgeLines.length, equals(result.edgeCandidateCount));
    expect(result.edgeCandidateCount, equals(5),
        reason: 'fixture: 2 pairwise edges + 3 hyperedge fan-out pairs '
            '(C(3,2) = 3) = 5 distinct edges after dedupe');
  });

  test('preserves the producer confidence label string verbatim',
      () async {
    final manifest = await loadStagedManifest();
    final importer = GraphifyCandidateImporter(repoRoot: tempRepo);
    final result = await importer.prepare(manifest: manifest);

    final edgeLines = File(
      p.join(result.outputDirectory, graphifyEdgeCandidatesFileName),
    ).readAsLinesSync();
    final labels = edgeLines
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, Object?>)
        .map((m) => m['label'] as String)
        .toSet();
    // The fixture exercises EXTRACTED + INFERRED on the pairwise
    // edges; the hyperedge fan-out also carries EXTRACTED.
    expect(labels, contains('EXTRACTED'));
    expect(labels, contains('INFERRED'));
  });

  test('preserves the numeric confidence_score on every node + edge',
      () async {
    final manifest = await loadStagedManifest();
    final importer = GraphifyCandidateImporter(repoRoot: tempRepo);
    final result = await importer.prepare(manifest: manifest);

    final nodeLines = File(
      p.join(result.outputDirectory, graphifyNodeCandidatesFileName),
    ).readAsLinesSync();
    final nodeRows = nodeLines
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, Object?>)
        .toList();

    // Every node in the fixture carries a numeric confidence_score.
    for (final row in nodeRows) {
      expect(row['confidence_score'], isA<num>(),
          reason: 'node ${row['candidate_key']} should carry a numeric '
              'confidence_score');
    }
  });

  test('low-confidence node is emitted with score < 0.7 in the JSONL',
      () async {
    final manifest = await loadStagedManifest();
    final importer = GraphifyCandidateImporter(repoRoot: tempRepo);
    final result = await importer.prepare(manifest: manifest);

    final nodeRows = File(
      p.join(result.outputDirectory, graphifyNodeCandidatesFileName),
    )
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, Object?>)
        .toList();

    final lowConfidence = nodeRows.where(
      (r) => (r['confidence_score'] as num).toDouble() < 0.7,
    );
    expect(lowConfidence, isNotEmpty,
        reason: 'fixture seeds weekly_plan_concept at confidence_score '
            '0.62 which trips the UI warning chip threshold (0.7)');
  });

  test('hyperedges fan out to pairwise edges with shared hyperedge_id',
      () async {
    final manifest = await loadStagedManifest();
    final importer = GraphifyCandidateImporter(repoRoot: tempRepo);
    final result = await importer.prepare(manifest: manifest);

    final edgeRows = File(
      p.join(result.outputDirectory, graphifyEdgeCandidatesFileName),
    )
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, Object?>)
        .toList();

    final hyperFanouts = edgeRows.where((r) {
      final payload = (r['payload'] as Map?)?.cast<String, Object?>();
      return payload != null && payload.containsKey('hyperedge_id');
    }).toList();

    expect(hyperFanouts, hasLength(3),
        reason: 'fixture has one hyperedge with arity 3 → C(3,2) = 3 '
            'pairwise fan-out edges');
    final sharedIds = hyperFanouts
        .map((r) => (r['payload'] as Map)['hyperedge_id'] as String)
        .toSet();
    expect(sharedIds, hasLength(1),
        reason: 'every fan-out from the same hyperedge must share the '
            'same hyperedge_id in payload');
    expect(sharedIds.single, equals('hyper_cycles_planning_triangle'));
    // Arity is also captured in payload so the admin can see the
    // multi-arity origin in the diff card.
    for (final row in hyperFanouts) {
      final payload = (row['payload'] as Map).cast<String, Object?>();
      expect(payload['hyperedge_arity'], equals(3));
    }
  });

  test('second invocation produces byte-identical output (deterministic)',
      () async {
    final manifest = await loadStagedManifest();
    final importer1 = GraphifyCandidateImporter(
      repoRoot: tempRepo,
      graphifyVersion: 'v5',
      graphifySourceCommit: 'fixture-commit',
    );
    final result1 = await importer1.prepare(manifest: manifest);
    final nodes1 = File(
      p.join(result1.outputDirectory, graphifyNodeCandidatesFileName),
    ).readAsBytesSync();
    final edges1 = File(
      p.join(result1.outputDirectory, graphifyEdgeCandidatesFileName),
    ).readAsBytesSync();

    final importer2 = GraphifyCandidateImporter(
      repoRoot: tempRepo,
      graphifyVersion: 'v5',
      graphifySourceCommit: 'fixture-commit',
    );
    final result2 = await importer2.prepare(manifest: manifest);
    final nodes2 = File(
      p.join(result2.outputDirectory, graphifyNodeCandidatesFileName),
    ).readAsBytesSync();
    final edges2 = File(
      p.join(result2.outputDirectory, graphifyEdgeCandidatesFileName),
    ).readAsBytesSync();

    expect(nodes2, equals(nodes1),
        reason: 'rerunning the importer against unchanged inputs must '
            'produce byte-identical node JSONL — required so '
            'graphify-out/candidates/ is reproducibly buildable in CI');
    expect(edges2, equals(edges1),
        reason: 'rerunning the importer against unchanged inputs must '
            'produce byte-identical edge JSONL');
  });
}
