import 'dart:io';

import 'advisor_corpus.dart';

Future<void> main(List<String> args) async {
  final commands = args.where((arg) => !arg.startsWith('--')).toList();
  final command = commands.isEmpty ? 'validate' : commands.first;
  final manifestPath = _option(args, 'manifest') ?? defaultManifestPath;
  final repoRoot = Directory.current;

  try {
    final validator = CorpusValidator(repoRoot: repoRoot);
    final validation = await validator.validate(manifestPath: manifestPath);
    if (!validation.isValid) {
      stderr.writeln('Advisor corpus manifest failed validation:');
      for (final error in validation.errors) {
        stderr.writeln('- $error');
      }
      exitCode = 1;
      return;
    }

    switch (command) {
      case 'validate':
        stdout.writeln(
          'Advisor corpus manifest OK: '
          '${validation.manifest.documents.length} documents, '
          '${validation.activeMarkdownFiles.length} active Markdown files.',
        );
        break;
      case 'plan-chunks':
        final planner = CorpusChunkPlanner(repoRoot: repoRoot);
        final plan = await planner.plan(validation.manifest);
        stdout.writeln(
          'Advisor corpus chunk plan OK: '
          '${plan.documentCount} documents, ${plan.chunkCount} planned chunks.',
        );
        final counts = plan.chunkCountsByDocument.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key));
        for (final entry in counts) {
          stdout.writeln('- ${entry.key}: ${entry.value}');
        }
        break;
      case 'materialize':
        final outputDirectory =
            _option(args, 'output') ?? 'build/advisor_corpus';
        final planner = CorpusChunkPlanner(repoRoot: repoRoot);
        final plan = await planner.plan(validation.manifest);
        final materializer = CorpusIngestionMaterializer(repoRoot: repoRoot);
        final result = await materializer.materialize(
          manifest: validation.manifest,
          plan: plan,
          outputDirectory: outputDirectory,
        );
        stdout.writeln(
          'Advisor corpus materialization OK: '
          '${result.documentCount} documents, '
          '${result.chunkCount} chunks, '
          '${result.graphNodeSeedCount} graph node seeds, '
          '${result.graphEdgeHintCount} graph edge hints.',
        );
        stdout.writeln('Output: ${result.outputDirectory}');
        break;
      case 'prepare-load':
        final materializationDirectory =
            _option(args, 'materialized') ?? 'build/advisor_corpus';
        final outputDirectory =
            _option(args, 'output') ?? 'build/advisor_corpus/load';
        final planner = CorpusChunkPlanner(repoRoot: repoRoot);
        final plan = await planner.plan(validation.manifest);
        final materializer = CorpusIngestionMaterializer(repoRoot: repoRoot);
        await materializer.materialize(
          manifest: validation.manifest,
          plan: plan,
          outputDirectory: materializationDirectory,
        );
        final preparer = CorpusDbLoadPreparer(repoRoot: repoRoot);
        final result = await preparer.prepare(
          materializationDirectory: materializationDirectory,
          outputDirectory: outputDirectory,
        );
        stdout.writeln(
          'Advisor corpus DB load prep OK: '
          '${result.documentCount} documents, '
          '${result.chunkCount} chunks, '
          '${result.graphNodeSeedCount} graph node seeds, '
          '${result.graphEdgeHintCount} graph edge hints.',
        );
        stdout.writeln('Run ID: ${result.runId}');
        stdout.writeln('Output: ${result.outputDirectory}');
        break;
      case 'prepare-embeddings':
        final materializationDirectory =
            _option(args, 'materialized') ?? 'build/advisor_corpus';
        final outputDirectory =
            _option(args, 'output') ?? 'build/advisor_corpus/embeddings';
        final planner = CorpusChunkPlanner(repoRoot: repoRoot);
        final plan = await planner.plan(validation.manifest);
        final materializer = CorpusIngestionMaterializer(repoRoot: repoRoot);
        await materializer.materialize(
          manifest: validation.manifest,
          plan: plan,
          outputDirectory: materializationDirectory,
        );
        final preparer = CorpusEmbeddingJobPreparer(repoRoot: repoRoot);
        final result = await preparer.prepare(
          materializationDirectory: materializationDirectory,
          outputDirectory: outputDirectory,
        );
        stdout.writeln(
          'Advisor corpus embedding prep OK: '
          '${result.chunkCount} chunks, '
          '${result.estimatedTokenCount} estimated tokens.',
        );
        stdout.writeln(
          'Contract: ${result.provider}/${result.model} '
          '(${result.dimensions} dimensions)',
        );
        stdout.writeln(
          'Planned retrieval: pgvector cosine -> '
          '$advisorRerankProvider/$advisorRerankModel -> '
          '$advisorAnswerRuntimeFamily answer runtime.',
        );
        stdout.writeln('Job ID: ${result.jobId}');
        stdout.writeln('Output: ${result.outputDirectory}');
        stdout.writeln('Mode: dry run, no API call, no DB mutation.');
        break;
      case 'prepare-age-projection':
        final materializationDirectory =
            _option(args, 'materialized') ?? 'build/advisor_corpus';
        final outputDirectory =
            _option(args, 'output') ?? 'build/advisor_corpus/age';
        final planner = CorpusChunkPlanner(repoRoot: repoRoot);
        final plan = await planner.plan(validation.manifest);
        final materializer = CorpusIngestionMaterializer(repoRoot: repoRoot);
        await materializer.materialize(
          manifest: validation.manifest,
          plan: plan,
          outputDirectory: materializationDirectory,
        );
        final preparer = CorpusAgeProjectionPreparer(repoRoot: repoRoot);
        final result = await preparer.prepare(
          materializationDirectory: materializationDirectory,
          outputDirectory: outputDirectory,
        );
        stdout.writeln(
          'Advisor corpus AGE projection prep OK: '
          '${result.expectedNodeSeedCount} graph node seeds, '
          '${result.expectedEdgeHintCount} graph edge hints '
          '(generated SQL only; no DB mutation).',
        );
        stdout.writeln('Graph: ${result.graphName}');
        stdout.writeln('Projection run ID: ${result.projectionRunId}');
        stdout.writeln('Output: ${result.outputDirectory}');
        stdout.writeln(
          'Files: ${result.projectionFiles.join(', ')}, '
          '${result.manifestFile}',
        );
        stdout.writeln(
          'Blocker path: emits AGE_BLOCKER RAISE NOTICE when '
          'pg_available_extensions does not list age.',
        );
        break;
      case 'execute-embeddings':
        final inputDirectory =
            _option(args, 'input') ?? 'build/advisor_corpus/embeddings';
        final outputDirectory =
            _option(args, 'output') ?? 'build/advisor_corpus/embeddings';
        final batchItemLimit =
            _intOption(args, 'batch-item-limit') ??
            advisorEmbeddingBatchItemLimit;
        final batchEstimatedTokenLimit =
            _intOption(args, 'batch-token-limit') ??
            advisorEmbeddingBatchEstimatedTokenLimit;
        final batchDelayMs = _intOption(args, 'batch-delay-ms') ?? 0;
        final executor = CorpusEmbeddingExecutor(repoRoot: repoRoot);
        final result = await executor.execute(
          inputDirectory: inputDirectory,
          outputDirectory: outputDirectory,
          batchItemLimit: batchItemLimit,
          batchEstimatedTokenLimit: batchEstimatedTokenLimit,
          batchDelay: Duration(milliseconds: batchDelayMs),
          onBatchComplete: (completedBatch, totalBatches, chunkCount) {
            stdout.writeln(
              'Embedding batch $completedBatch/$totalBatches complete '
              '($chunkCount chunks).',
            );
          },
        );
        stdout.writeln(
          'Advisor corpus embedding execution OK: '
          '${result.chunkCount} chunks across ${result.batchCount} batches.',
        );
        stdout.writeln(
          'Contract: ${result.provider}/${result.model} '
          '(${result.dimensions} dimensions)',
        );
        stdout.writeln(
          'Provider-reported tokens: ${result.providerReportedTokenCount}',
        );
        stdout.writeln('Execution ID: ${result.executionId}');
        stdout.writeln('Output: ${result.outputDirectory}');
        stdout.writeln('Generated SQL only; no DB mutation by this command.');
        break;
      case 'prepare-graphify-candidates':
        // Phase 11A.3b — read graphify-out/graph.json, apply the
        // corpus_manifest.yaml scope filter, and emit the deterministic
        // JSONL artifacts the proxy serves to the Corpus Admin "Graph
        // candidates" tab. Does NOT mutate the database.
        final graphifyDirectory =
            _option(args, 'graphify-out') ?? defaultGraphifyOutputDirectory;
        final outputDirectory = _option(args, 'output') ??
            defaultGraphifyCandidatesOutputDirectory;
        final graphScope = _option(args, 'graph-scope') ?? 'methodology';
        final graphVersion = _option(args, 'graph-version') ?? '1';
        final graphifyVersion =
            _option(args, 'graphify-version') ?? 'v5';
        final graphifySourceCommit =
            _option(args, 'graphify-source-commit');
        final importer = GraphifyCandidateImporter(
          repoRoot: repoRoot,
          graphifyVersion: graphifyVersion,
          graphifySourceCommit: graphifySourceCommit,
        );
        final result = await importer.prepare(
          manifest: validation.manifest,
          graphifyDirectory: graphifyDirectory,
          outputDirectory: outputDirectory,
          graphScope: graphScope,
          graphVersion: graphVersion,
        );
        stdout.writeln(
          'Graphify candidate prep OK: '
          '${result.nodeCandidateCount} nodes, '
          '${result.edgeCandidateCount} edges, '
          '${result.droppedOutOfScopeCount} dropped out-of-scope.',
        );
        stdout.writeln(
          'Graphify version: ${result.manifest['graphify_version']}',
        );
        stdout.writeln('Output: ${result.outputDirectory}');
        stdout.writeln(
          'Files: $graphifyNodeCandidatesFileName, '
          '$graphifyEdgeCandidatesFileName, '
          '$graphifyCandidateManifestFileName',
        );
        stdout.writeln(
          'Mode: read-only against graph.json; no DB mutation, no live API call.',
        );
        break;
      case 'execute-contexts':
        final materializationDirectory =
            _option(args, 'materialized') ?? 'build/advisor_corpus';
        final outputDirectory =
            _option(args, 'output') ?? 'build/advisor_corpus/context';
        final batchDelayMs = _intOption(args, 'batch-delay-ms') ?? 0;
        final executor = CorpusContextExecutor(repoRoot: repoRoot);
        final result = await executor.execute(
          materializationDirectory: materializationDirectory,
          outputDirectory: outputDirectory,
          batchDelay: Duration(milliseconds: batchDelayMs),
          onContextComplete: (completed, total) {
            stdout.writeln('Context $completed/$total complete.');
          },
        );
        stdout.writeln(
          'Advisor corpus context execution OK: '
          '${result.chunkCount} chunks.',
        );
        stdout.writeln(
          'Contract: ${result.provider}/${result.model} '
          '(${result.maxOutputTokens} max output tokens).',
        );
        stdout.writeln('Execution ID: ${result.executionId}');
        stdout.writeln('Output: ${result.outputDirectory}');
        stdout.writeln(
          'Generated SQL + contextual embedding inputs only; '
          'no DB mutation by this command.',
        );
        break;
      default:
        stderr.writeln('Unknown command: $command');
        stderr.writeln(
          'Usage: dart run tool/advisor_corpus/main.dart '
          '[validate|plan-chunks|materialize|prepare-load|'
          'prepare-embeddings|execute-embeddings|execute-contexts|'
          'prepare-age-projection|prepare-graphify-candidates]',
        );
        exitCode = 64;
    }
  } on CorpusManifestException catch (error) {
    stderr.writeln('Advisor corpus manifest error: ${error.message}');
    exitCode = 1;
  }
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

int? _intOption(List<String> args, String name) {
  final raw = _option(args, name);
  if (raw == null) {
    return null;
  }
  final value = int.tryParse(raw);
  if (value == null) {
    throw CorpusManifestException('Invalid integer option --$name=$raw');
  }
  return value;
}
