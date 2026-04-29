// Phase 9.0Σ.j / B47 — vector index health CLI entry.
//
// Modes:
//   * (default)         emit a vector index health snapshot envelope
//                       to stdout for the locked Voyage searchable
//                       embedding space (active_vectors=0, latency
//                       null) so the operator can see the data shape
//                       without running a live benchmark.
//
//   * --emit-benchmark  write the dry-run filtered-search benchmark
//                       artifact pair (`.sql` + `.json`) to
//                       `--output=<dir>`. The SQL ends with ROLLBACK
//                       and never references DiskANN.
//
// Hard rules carried from the slice contract:
//   * No live database, provider, or proxy calls.
//   * Never flips HNSW → DiskANN as default.
//   * Never wires a `/health` proxy route — that is B42's surface,
//     and B44/B45 share the proxy file for parallel work.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'vector_index_health.dart';

const String _benchmarkSqlFileName = 'filtered_search_benchmark.sql';
const String _benchmarkJsonFileName = 'filtered_search_benchmark.json';

Future<void> main(List<String> args) async {
  final emitBenchmark = args.contains('--emit-benchmark');
  final outputDir = _option(args, 'output');
  final filterScope = _option(args, 'scope') ?? 'methodology';
  final filterRestaurantId = _option(args, 'restaurant-id');
  final filterMaxResults = int.tryParse(_option(args, 'max-results') ?? '10');

  if (filterMaxResults == null || filterMaxResults <= 0) {
    stderr.writeln('vector_index_health: --max-results must be a '
        'positive integer.');
    exitCode = 64;
    return;
  }

  if (emitBenchmark && (outputDir == null || outputDir.isEmpty)) {
    stderr.writeln(
      'vector_index_health: --emit-benchmark requires --output=<dir>; '
      'this tool never connects to a database, artifacts are written '
      'to a directory only.',
    );
    exitCode = 64;
    return;
  }

  // Placeholder snapshot — no live DB query was issued. Carries the
  // documented starting budgets so the helper's `recommendedAction`
  // evaluates deterministically against an explicit threshold set;
  // operators tune `budgets` per searchable embedding space before
  // wiring the snapshot into the 11A.5 surface.
  final placeholderSnapshot = VectorIndexHealthSnapshot(
    space: kVoyageVoyage4Large1024Space,
    activeVectors: 0,
    indexType: kDefaultActiveIndexType,
    indexSizeBytes: 0,
    buildStatus: BuildStatus.ready,
    lastBuild: null,
    benchmark: const BenchmarkResult(),
    growthProjection: const GrowthProjection(
      horizonDays: 90,
      projectedActiveVectors: 0,
    ),
    affectedFunctionality: const <String>[
      'advisor_candidate_retrieval',
    ],
    budgets: VectorIndexHealthBudgets.exampleStartingBudgets,
    evaluationTime: DateTime.now().toUtc(),
    notes:
        'CLI placeholder snapshot — no live DB query was issued. Replace '
        'with measured numbers before recording on the 11A.5 surface.',
  );

  if (!emitBenchmark) {
    final encoder = const JsonEncoder.withIndent('  ');
    final body = <String, Object?>{
      'snapshots': <Map<String, Object?>>[placeholderSnapshot.toJson()],
      'b42_metrics':
          mapToB42Metrics(<VectorIndexHealthSnapshot>[placeholderSnapshot])
              .toJson(),
    };
    stdout.writeln(encoder.convert(body));
    return;
  }

  final artifact = buildFilteredSearchBenchmarkArtifact(
    <VectorIndexHealthSnapshot>[placeholderSnapshot],
    filterScope: filterScope,
    filterRestaurantId: filterRestaurantId,
    filterMaxResults: filterMaxResults,
  );

  final outDir = Directory(outputDir!);
  outDir.createSync(recursive: true);
  await File(p.join(outDir.path, _benchmarkSqlFileName))
      .writeAsString(artifact.sql);
  await File(p.join(outDir.path, _benchmarkJsonFileName))
      .writeAsString(artifact.envelopeJson);

  stdout.writeln(
    'vector_index_health: wrote dry-run filtered-search benchmark '
    'artifact to ${outDir.path} '
    '($_benchmarkSqlFileName, $_benchmarkJsonFileName).',
  );
  stdout.writeln(
    'Mode: dry-run only. SQL ends with ROLLBACK. HNSW remains active; '
    'DiskANN remains dormant.',
  );
}

String? _option(List<String> args, String name) {
  final prefix = '--$name=';
  for (final arg in args) {
    if (arg.startsWith(prefix)) {
      return arg.substring(prefix.length);
    }
  }
  return null;
}
