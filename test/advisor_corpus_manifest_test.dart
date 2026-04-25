import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/advisor_corpus/advisor_corpus.dart';

void main() {
  group('Advisor corpus manifest validator', () {
    test(
      'real corpus manifest validates against active Markdown files',
      () async {
        final validator = CorpusValidator(repoRoot: Directory.current);

        final result = await validator.validate();

        expect(result.errors, isEmpty);
        expect(result.manifest.documents, hasLength(8));
        expect(result.activeMarkdownFiles, hasLength(8));
        expect(
          result.activeMarkdownFiles,
          isNot(contains(excludedEmptyApronFileName)),
        );
      },
    );

    test('rejects unmanifested Markdown files in the corpus root', () async {
      final repo = await _createFixtureRepo();
      await _writeText(
        repo,
        'docs/Knowledge_graph_docs/unlisted.md',
        '# Surprise\n\nThis file is not approved.',
      );

      final result = await CorpusValidator(repoRoot: repo).validate();

      expect(result.errors.join('\n'), contains('Unmanifested Markdown files'));
      expect(result.errors.join('\n'), contains('unlisted.md'));
    });

    test('rejects missing source files', () async {
      final repo = await _createFixtureRepo(writeSource: false);

      final result = await CorpusValidator(repoRoot: repo).validate();

      expect(result.errors.join('\n'), contains('Missing source file'));
      expect(result.errors.join('\n'), contains('Manifested files missing'));
    });

    test('rejects duplicate document ids', () async {
      final repo = await _createFixtureRepo(includeDuplicateDocId: true);

      final result = await CorpusValidator(repoRoot: repo).validate();

      expect(
        result.errors.join('\n'),
        contains('Duplicate doc_id: sample_doc'),
      );
    });

    test('rejects hash drift', () async {
      final repo = await _createFixtureRepo(hashOverride: '0' * 64);

      final result = await CorpusValidator(repoRoot: repo).validate();

      expect(result.errors.join('\n'), contains('SHA-256 mismatch'));
    });

    test(
      'rejects active Empty Apron source even though it is excluded',
      () async {
        final repo = await _createFixtureRepo();
        await _writeText(
          repo,
          'docs/Knowledge_graph_docs/$excludedEmptyApronFileName',
          '# Empty Apron\n\nExcluded by owner.',
        );

        final result = await CorpusValidator(repoRoot: repo).validate();

        expect(result.errors.join('\n'), contains('must not be present'));
        expect(result.errors.join('\n'), contains(excludedEmptyApronFileName));
      },
    );
  });

  group('Advisor corpus chunk planner', () {
    test('plans heading-aware chunks with source and risk metadata', () async {
      final repo = await _createFixtureRepo(
        content: _headingAwareMarkdown,
        riskLevel: 'high',
      );
      final validation = await CorpusValidator(repoRoot: repo).validate();
      final plan = await CorpusChunkPlanner(
        repoRoot: repo,
      ).plan(validation.manifest);

      expect(validation.errors, isEmpty);
      expect(plan.documentCount, 1);
      expect(plan.chunkCount, greaterThanOrEqualTo(2));
      expect(plan.chunks.first.docId, 'sample_doc');
      expect(plan.chunks.first.riskLevel, 'high');
      expect(plan.chunks.first.headingPath.first, 'Sample Handbook');
      expect(
        plan.chunks.first.sourcePath,
        'docs/Knowledge_graph_docs/sample.md',
      );
    });

    test('plans glossary files as one chunk per term', () async {
      final repo = await _createFixtureRepo(
        content: _glossaryMarkdown,
        chunkProfile: 'glossary_entry_per_term',
        contentRole: 'glossary',
      );
      final validation = await CorpusValidator(repoRoot: repo).validate();
      final plan = await CorpusChunkPlanner(
        repoRoot: repo,
      ).plan(validation.manifest);

      expect(validation.errors, isEmpty);
      expect(plan.chunkCount, 2);
      expect(
        plan.chunks.map((chunk) => chunk.chunkKind),
        everyElement('glossary_term'),
      );
      expect(plan.chunks.first.headingPath, contains('BOH (BACK OF HOUSE)'));
    });
  });

  group('Advisor corpus materializer', () {
    test(
      'writes deterministic ingestion records without mutating source',
      () async {
        final repo = await _createFixtureRepo(
          content: _headingAwareMarkdown,
          riskLevel: 'high',
        );
        final sourceFile = File(
          '${repo.path}/docs/Knowledge_graph_docs/sample.md',
        );
        final sourceHashBefore = await sha256ForFile(sourceFile);
        final validation = await CorpusValidator(repoRoot: repo).validate();
        final plan = await CorpusChunkPlanner(
          repoRoot: repo,
        ).plan(validation.manifest);
        final materializer = CorpusIngestionMaterializer(repoRoot: repo);

        final first = await materializer.materialize(
          manifest: validation.manifest,
          plan: plan,
        );
        final firstChunkRecords = await File(
          '${first.outputDirectory}/source_chunks.jsonl',
        ).readAsString();
        final second = await materializer.materialize(
          manifest: validation.manifest,
          plan: plan,
        );
        final secondChunkRecords = await File(
          '${second.outputDirectory}/source_chunks.jsonl',
        ).readAsString();

        expect(first.documentCount, 1);
        expect(first.chunkCount, plan.chunkCount);
        expect(first.graphNodeSeedCount, plan.chunkCount + 1);
        expect(first.graphEdgeHintCount, plan.chunkCount);
        expect(secondChunkRecords, firstChunkRecords);
        expect(await sha256ForFile(sourceFile), sourceHashBefore);
      },
    );

    test('emits pending embedding and graph provenance records', () async {
      final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
      final validation = await CorpusValidator(repoRoot: repo).validate();
      final plan = await CorpusChunkPlanner(
        repoRoot: repo,
      ).plan(validation.manifest);

      final result = await CorpusIngestionMaterializer(
        repoRoot: repo,
      ).materialize(manifest: validation.manifest, plan: plan);

      final documentRecord = _firstJsonLine(
        File('${result.outputDirectory}/source_documents.jsonl'),
      );
      final chunkRecord = _firstJsonLine(
        File('${result.outputDirectory}/source_chunks.jsonl'),
      );
      final nodeRecord = _firstJsonLine(
        File('${result.outputDirectory}/graph_node_seeds.jsonl'),
      );
      final edgeRecord = _firstJsonLine(
        File('${result.outputDirectory}/graph_edge_hints.jsonl'),
      );
      final summary =
          jsonDecode(
                File(
                  '${result.outputDirectory}/manifest_summary.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;

      expect(documentRecord['record_type'], 'source_document');
      expect(documentRecord['embedding_status'], 'pending');
      expect(chunkRecord['record_type'], 'source_chunk');
      expect(chunkRecord['embedding_status'], 'pending');
      expect(chunkRecord['embedding_model'], isNull);
      expect(chunkRecord['content_sha256'], isA<String>());
      expect(nodeRecord['record_type'], 'graph_node_seed');
      expect(edgeRecord['record_type'], 'graph_edge_hint');
      expect(edgeRecord['edge_type'], 'CONTAINS');
      expect(summary['chunk_count'], result.chunkCount);
    });
  });

  group('Advisor corpus DB load preparer', () {
    test('writes ordered deterministic load artifacts', () async {
      final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
      final validation = await CorpusValidator(repoRoot: repo).validate();
      final plan = await CorpusChunkPlanner(
        repoRoot: repo,
      ).plan(validation.manifest);
      await CorpusIngestionMaterializer(
        repoRoot: repo,
      ).materialize(manifest: validation.manifest, plan: plan);
      final preparer = CorpusDbLoadPreparer(repoRoot: repo);

      final first = await preparer.prepare();
      final firstDocumentSql = await File(
        '${first.outputDirectory}/002_source_documents.sql',
      ).readAsString();
      final second = await preparer.prepare();
      final secondDocumentSql = await File(
        '${second.outputDirectory}/002_source_documents.sql',
      ).readAsString();

      expect(first.runId, second.runId);
      expect(firstDocumentSql, secondDocumentSql);
      expect(first.loadFiles, <String>[
        '001_ingestion_run.sql',
        '002_source_documents.sql',
        '003_source_chunks.sql',
        '004_graph_node_seeds.sql',
        '005_graph_edge_hints.sql',
      ]);
      expect(first.documentCount, 1);
      expect(first.chunkCount, plan.chunkCount);
      expect(first.graphNodeSeedCount, plan.chunkCount + 1);
      expect(first.graphEdgeHintCount, plan.chunkCount);
    });

    test('load manifest maps generated files to target tables', () async {
      final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
      final validation = await CorpusValidator(repoRoot: repo).validate();
      final plan = await CorpusChunkPlanner(
        repoRoot: repo,
      ).plan(validation.manifest);
      await CorpusIngestionMaterializer(
        repoRoot: repo,
      ).materialize(manifest: validation.manifest, plan: plan);

      final result = await CorpusDbLoadPreparer(repoRoot: repo).prepare();
      final loadManifest =
          jsonDecode(
                File(
                  '${result.outputDirectory}/load_manifest.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final loadOrder = loadManifest['load_order']! as List<Object?>;
      final firstSql = File(
        '${result.outputDirectory}/001_ingestion_run.sql',
      ).readAsStringSync();
      final chunksSql = File(
        '${result.outputDirectory}/003_source_chunks.sql',
      ).readAsStringSync();

      expect(loadManifest['apply_mode'], 'not_applied_build_artifacts_only');
      expect(loadManifest['run_id'], result.runId);
      expect(
        loadOrder
            .cast<Map<String, Object?>>()
            .map((step) => step['table'])
            .toList(),
        <String>[
          'advisor_ingestion_runs',
          'advisor_source_documents',
          'advisor_source_chunks',
          'advisor_graph_node_seeds',
          'advisor_graph_edge_hints',
        ],
      );
      expect(firstSql, contains('insert into public.advisor_ingestion_runs'));
      expect(chunksSql, contains('insert into public.advisor_source_chunks'));
      expect(chunksSql, contains("'pending'"));
    });
  });

  group('Advisor corpus embedding job preparer', () {
    test(
      'writes deterministic dry-run embedding inputs and manifest',
      () async {
        final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
        final validation = await CorpusValidator(repoRoot: repo).validate();
        final plan = await CorpusChunkPlanner(
          repoRoot: repo,
        ).plan(validation.manifest);
        await CorpusIngestionMaterializer(
          repoRoot: repo,
        ).materialize(manifest: validation.manifest, plan: plan);
        final preparer = CorpusEmbeddingJobPreparer(repoRoot: repo);

        final first = await preparer.prepare();
        final firstInputs = await File(
          '${first.outputDirectory}/embedding_inputs.jsonl',
        ).readAsString();
        final second = await preparer.prepare();
        final secondInputs = await File(
          '${second.outputDirectory}/embedding_inputs.jsonl',
        ).readAsString();
        final manifest =
            jsonDecode(
                  File(
                    '${first.outputDirectory}/embedding_job_manifest.json',
                  ).readAsStringSync(),
                )
                as Map<String, Object?>;
        final input = _firstJsonLine(
          File('${first.outputDirectory}/embedding_inputs.jsonl'),
        );

        expect(first.jobId, second.jobId);
        expect(secondInputs, firstInputs);
        expect(first.provider, advisorEmbeddingProvider);
        expect(first.model, advisorEmbeddingModel);
        expect(first.dimensions, advisorEmbeddingDimensions);
        expect(first.chunkCount, plan.chunkCount);
        expect(manifest['mode'], 'dry_run_no_api_call');
        expect(manifest['database_mutation'], isFalse);
        expect(manifest['api_key_required_for_execution'], 'VOYAGE_API_KEY');
        expect(manifest['rerank_provider'], advisorRerankProvider);
        expect(manifest['rerank_model'], advisorRerankModel);
        expect(manifest['answer_runtime_family'], advisorAnswerRuntimeFamily);
        expect(
          manifest['planned_retrieval_pipeline'],
          contains('claude_answer_runtime_with_provenance'),
        );
        expect(input['record_type'], 'embedding_input');
        expect(input['dimensions'], advisorEmbeddingDimensions);
        expect(input['input'], contains('Sample Handbook'));
      },
    );

    test('rejects unsupported embedding model dimensions', () async {
      final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
      final validation = await CorpusValidator(repoRoot: repo).validate();
      final plan = await CorpusChunkPlanner(
        repoRoot: repo,
      ).plan(validation.manifest);
      await CorpusIngestionMaterializer(
        repoRoot: repo,
      ).materialize(manifest: validation.manifest, plan: plan);

      expect(
        CorpusEmbeddingJobPreparer(repoRoot: repo).prepare(dimensions: 2048),
        throwsA(isA<CorpusManifestException>()),
      );
    });
  });

  group('Advisor corpus embedding executor', () {
    test(
      'writes SQL updates from provider embeddings without applying them',
      () async {
        final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
        final validation = await CorpusValidator(repoRoot: repo).validate();
        final plan = await CorpusChunkPlanner(
          repoRoot: repo,
        ).plan(validation.manifest);
        await CorpusIngestionMaterializer(
          repoRoot: repo,
        ).materialize(manifest: validation.manifest, plan: plan);
        await CorpusEmbeddingJobPreparer(repoRoot: repo).prepare();

        final gateway = _FakeEmbeddingGateway();
        final result = await CorpusEmbeddingExecutor(
          repoRoot: repo,
          gateway: gateway,
        ).execute(apiKey: 'test-key');
        final executionManifest =
            jsonDecode(
                  File(
                    '${result.outputDirectory}/embedding_execution_manifest.json',
                  ).readAsStringSync(),
                )
                as Map<String, Object?>;
        final sql = File(
          '${result.outputDirectory}/embedding_updates.sql',
        ).readAsStringSync();

        expect(result.chunkCount, plan.chunkCount);
        expect(result.batchCount, 1);
        expect(result.providerReportedTokenCount, 1234);
        expect(gateway.seenModel, advisorEmbeddingModel);
        expect(gateway.seenDimensions, advisorEmbeddingDimensions);
        expect(gateway.seenInputs.length, plan.chunkCount);
        expect(executionManifest['database_mutation'], isFalse);
        expect(executionManifest['input_type'], advisorEmbeddingInputType);
        expect(sql, contains('update public.advisor_source_chunks'));
        expect(sql, contains("embedding_status = 'ready'"));
        expect(sql, contains("embedding_model = 'voyage-4-large'"));
        expect(sql, contains('::vector(1024)'));
      },
    );

    test('requires VOYAGE_API_KEY for live execution', () async {
      final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
      final validation = await CorpusValidator(repoRoot: repo).validate();
      final plan = await CorpusChunkPlanner(
        repoRoot: repo,
      ).plan(validation.manifest);
      await CorpusIngestionMaterializer(
        repoRoot: repo,
      ).materialize(manifest: validation.manifest, plan: plan);
      await CorpusEmbeddingJobPreparer(repoRoot: repo).prepare();

      expect(
        CorpusEmbeddingExecutor(
          repoRoot: repo,
          gateway: _FakeEmbeddingGateway(),
        ).execute(apiKey: ''),
        throwsA(isA<CorpusManifestException>()),
      );
    });

    test(
      'wrong-dimension gateway output fails through the provider abstraction',
      () async {
        // 7.57.3b regression: the embedding executor now routes
        // through `VoyageEmbeddingProvider`, which enforces the
        // contract dimension count. A gateway that returns a
        // shorter vector must be rejected by the provider (StateError)
        // instead of slipping through to the SQL writer.
        final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
        final validation = await CorpusValidator(repoRoot: repo).validate();
        final plan = await CorpusChunkPlanner(
          repoRoot: repo,
        ).plan(validation.manifest);
        await CorpusIngestionMaterializer(
          repoRoot: repo,
        ).materialize(manifest: validation.manifest, plan: plan);
        await CorpusEmbeddingJobPreparer(repoRoot: repo).prepare();

        expect(
          CorpusEmbeddingExecutor(
            repoRoot: repo,
            gateway: _WrongDimensionEmbeddingGateway(),
          ).execute(apiKey: 'test-key'),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  group('Advisor corpus schema scaffold', () {
    test('requires pgvector while keeping Apache AGE projection optional', () {
      final migration = File(
        'supabase/migrations/202604250001_advisor_corpus_storage_schema.sql',
      ).readAsStringSync();
      final embeddingContractMigration = File(
        'supabase/migrations/202604250002_advisor_embedding_contract.sql',
      ).readAsStringSync();

      expect(migration, contains('create extension if not exists vector'));
      expect(migration, contains("where name = 'age'"));
      expect(
        migration,
        contains('advisor graph projection remains staged only'),
      );
      expect(migration, contains('embedding vector(1024)'));
      expect(embeddingContractMigration, contains('vector(1024)'));
      expect(embeddingContractMigration, contains('voyage-4-large'));
      expect(embeddingContractMigration, contains('rerank-2.5'));
      expect(embeddingContractMigration, contains('Claude'));
    });
  });
}

const _headingAwareMarkdown = '''
---
source: fixture
---

# Sample Handbook

Introductory context for the sample handbook.

## Food Safety

Wash hands before prep. Keep cold food cold and hot food hot.

## Service Standards

Greet guests quickly and keep the floor communication clean.
''';

const _glossaryMarkdown = '''
---
source: fixture
---

# General Words To Know

- **BOH (BACK OF HOUSE):** The kitchen team.
- **COVERS:** The number of guests served or expected.
''';

Future<Directory> _createFixtureRepo({
  bool writeSource = true,
  bool includeDuplicateDocId = false,
  String content = _headingAwareMarkdown,
  String chunkProfile = 'heading_aware_policy_handbook',
  String contentRole = 'operating_handbook',
  String riskLevel = 'medium',
  String? hashOverride,
}) async {
  final repo = await Directory.systemTemp.createTemp('advisor_corpus_test_');
  if (writeSource) {
    await _writeText(repo, 'docs/Knowledge_graph_docs/sample.md', content);
  } else {
    Directory(
      '${repo.path}/docs/Knowledge_graph_docs',
    ).createSync(recursive: true);
  }

  final sourceFile = File('${repo.path}/docs/Knowledge_graph_docs/sample.md');
  final hash =
      hashOverride ??
      (sourceFile.existsSync() ? await sha256ForFile(sourceFile) : '1' * 64);

  final documents = <_FixtureDoc>[
    _FixtureDoc(
      docId: 'sample_doc',
      fileName: 'sample.md',
      sourcePath: 'docs/Knowledge_graph_docs/sample.md',
      title: 'Sample Handbook',
      chunkProfile: chunkProfile,
      contentRole: contentRole,
      riskLevel: riskLevel,
      sha256Hash: hash,
    ),
  ];

  if (includeDuplicateDocId) {
    await _writeText(
      repo,
      'docs/Knowledge_graph_docs/sample_two.md',
      '# Sample Two\n',
    );
    documents.add(
      _FixtureDoc(
        docId: 'sample_doc',
        fileName: 'sample_two.md',
        sourcePath: 'docs/Knowledge_graph_docs/sample_two.md',
        title: 'Sample Two',
        chunkProfile: chunkProfile,
        contentRole: contentRole,
        riskLevel: riskLevel,
        sha256Hash: await sha256ForFile(
          File('${repo.path}/docs/Knowledge_graph_docs/sample_two.md'),
        ),
      ),
    );
  }

  await _writeText(repo, defaultManifestPath, _manifestYaml(documents));
  return repo;
}

Future<void> _writeText(
  Directory repo,
  String relativePath,
  String content,
) async {
  final file = File('${repo.path}/$relativePath');
  file.parent.createSync(recursive: true);
  await file.writeAsString(content);
}

Map<String, Object?> _firstJsonLine(File file) {
  final line = file.readAsLinesSync().first;
  return jsonDecode(line) as Map<String, Object?>;
}

class _FakeEmbeddingGateway implements AdvisorEmbeddingGateway {
  String? seenModel;
  int? seenDimensions;
  final seenInputs = <String>[];

  @override
  Future<EmbeddingBatchResult> embedDocuments({
    required String apiKey,
    required String model,
    required int dimensions,
    required List<String> inputs,
  }) async {
    seenModel = model;
    seenDimensions = dimensions;
    seenInputs.addAll(inputs);
    return EmbeddingBatchResult(
      vectors: <List<double>>[
        for (var row = 0; row < inputs.length; row += 1)
          <double>[
            for (var col = 0; col < dimensions; col += 1) (row + 1) / (col + 2),
          ],
      ],
      providerReportedTokenCount: 1234,
    );
  }
}

/// Returns vectors that are one dimension short of the contract.
/// Used to verify the `VoyageEmbeddingProvider` rejection path the
/// executor now relies on (7.57.3b).
class _WrongDimensionEmbeddingGateway implements AdvisorEmbeddingGateway {
  @override
  Future<EmbeddingBatchResult> embedDocuments({
    required String apiKey,
    required String model,
    required int dimensions,
    required List<String> inputs,
  }) async {
    return EmbeddingBatchResult(
      vectors: <List<double>>[
        for (var i = 0; i < inputs.length; i += 1)
          List<double>.filled(dimensions - 1, 0.0),
      ],
      providerReportedTokenCount: 0,
    );
  }
}

String _manifestYaml(List<_FixtureDoc> documents) {
  final buffer = StringBuffer('''
manifest_version: 1
updated: "2026-04-25"
corpus_root: "docs/Knowledge_graph_docs"
default_scope: "global_shared_methodology"
default_restaurant_id: null
authorship_policy: "founder_authored_or_founder_synthesized_only"
markdown_only: true

excluded_sources:
  - file_name: "$excludedEmptyApronFileName"
    status: "excluded"
    reason: "owner_removed_from_active_knowledge_graph_corpus_before_11a_0"

documents:
''');

  for (final document in documents) {
    buffer.write('''
  - doc_id: "${document.docId}"
    file_name: "${document.fileName}"
    source_path: "${document.sourcePath}"
    title: "${document.title}"
    status: "included"
    scope: "global_shared_methodology"
    restaurant_id: null
    brand_context: "fixture"
    content_role: "${document.contentRole}"
    authority_tier: "primary_founder_operating_material"
    risk_level: "${document.riskLevel}"
    audience:
      - "managers"
    chunk_profile: "${document.chunkProfile}"
    graph_profiles:
      - "Concept"
    tags:
      - "fixture"
    word_count_estimate: 10
    heading_count: 1
    line_count: 1
    sha256: "${document.sha256Hash}"
''');
  }

  return buffer.toString();
}

class _FixtureDoc {
  _FixtureDoc({
    required this.docId,
    required this.fileName,
    required this.sourcePath,
    required this.title,
    required this.chunkProfile,
    required this.contentRole,
    required this.riskLevel,
    required this.sha256Hash,
  });

  final String docId;
  final String fileName;
  final String sourcePath;
  final String title;
  final String chunkProfile;
  final String contentRole;
  final String riskLevel;
  final String sha256Hash;
}
