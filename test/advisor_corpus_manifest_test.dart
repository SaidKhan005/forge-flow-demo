import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/advisor_provider_constants.dart';
import 'package:forge_and_flow/domain/services/rerank_provider.dart';
import 'package:forge_and_flow/services/voyage_rerank_provider.dart';

import '../tool/advisor_corpus/advisor_corpus.dart';

void main() {
  group('Advisor corpus manifest validator', () {
    test(
      'real corpus manifest validates against active Markdown files',
      () async {
        final validator = CorpusValidator(repoRoot: Directory.current);

        final result = await validator.validate();

        expect(result.errors, isEmpty);
        // Count guard: bump deliberately when the approved corpus in
        // docs/Knowledge_graph_docs/corpus_manifest.yaml changes.
        // 19 as of 2026-07-11: barrio_menu added (operator-authored
        // dinner menu + concept history, curated from the slide deck).
        // 21 as of 2026-07-27: clover_sop + push_employee_sop added
        // (Scribe-format point-of-sale + scheduling SOP training manuals).
        // 24 as of 2026-07-28: host_manual + bar_manual + drink_specs added
        // (operator host, bar, and combined drink-spec training manuals).
        expect(result.manifest.documents, hasLength(24));
        expect(result.activeMarkdownFiles, hasLength(24));
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

  group('Advisor corpus content-addressed chunks (11a.11a)', () {
    test(
      'chunk ids are content-addressed and deterministic across runs',
      () async {
        final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
        final validation = await CorpusValidator(repoRoot: repo).validate();
        final plan = await CorpusChunkPlanner(
          repoRoot: repo,
        ).plan(validation.manifest);

        final firstResult = await CorpusIngestionMaterializer(
          repoRoot: repo,
        ).materialize(manifest: validation.manifest, plan: plan);
        final firstChunks = File(
          '${firstResult.outputDirectory}/source_chunks.jsonl',
        ).readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
        final firstIds = <String>[
          for (final line in firstChunks)
            (jsonDecode(line) as Map<String, Object?>)['chunk_id'].toString(),
        ];

        final secondResult = await CorpusIngestionMaterializer(
          repoRoot: repo,
        ).materialize(manifest: validation.manifest, plan: plan);
        final secondChunks = File(
          '${secondResult.outputDirectory}/source_chunks.jsonl',
        ).readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
        final secondIds = <String>[
          for (final line in secondChunks)
            (jsonDecode(line) as Map<String, Object?>)['chunk_id'].toString(),
        ];

        expect(secondIds, equals(firstIds));
        // Format guard: ids are doc-prefixed and content-addressed.
        for (final id in firstIds) {
          expect(id, startsWith('sample_doc__c_'));
          // suffix is 16 hex chars (head of sha256).
          final suffix = id.substring('sample_doc__c_'.length);
          expect(suffix, hasLength(16));
          expect(RegExp(r'^[a-f0-9]{16}$').hasMatch(suffix), isTrue);
        }
      },
    );

    test('changing chunk text changes chunk_id', () async {
      final repoA = await _createFixtureRepo(content: _headingAwareMarkdown);
      final repoB = await _createFixtureRepo(content: _alteredHandbookMarkdown);

      final planA = await CorpusChunkPlanner(
        repoRoot: repoA,
      ).plan((await CorpusValidator(repoRoot: repoA).validate()).manifest);
      final planB = await CorpusChunkPlanner(
        repoRoot: repoB,
      ).plan((await CorpusValidator(repoRoot: repoB).validate()).manifest);

      final idsA = planA.chunks.map((c) => c.chunkId).toSet();
      final idsB = planB.chunks.map((c) => c.chunkId).toSet();

      // Both fixtures emit at least the introductory + Food Safety sections;
      // the altered fixture's Food Safety body text differs, so its chunk
      // ids must shift accordingly. The altered repo must have at least
      // one id absent from the original repo.
      expect(idsB.difference(idsA), isNotEmpty);
    });

    test('same chunk text in different docs does not collide', () async {
      final repo = await _createTwoDocFixtureWithSharedChunkText();
      final validation = await CorpusValidator(repoRoot: repo).validate();
      final plan = await CorpusChunkPlanner(
        repoRoot: repo,
      ).plan(validation.manifest);

      final docAChunks = plan.chunks.where((c) => c.docId == 'doc_alpha');
      final docBChunks = plan.chunks.where((c) => c.docId == 'doc_beta');
      expect(docAChunks, isNotEmpty);
      expect(docBChunks, isNotEmpty);

      // No id appears in both docs' chunk-id sets, even though the
      // chunk contents overlap.
      final aIds = docAChunks.map((c) => c.chunkId).toSet();
      final bIds = docBChunks.map((c) => c.chunkId).toSet();
      expect(aIds.intersection(bIds), isEmpty);

      // Doc-prefix discipline.
      for (final c in docAChunks) {
        expect(c.chunkId, startsWith('doc_alpha__c_'));
      }
      for (final c in docBChunks) {
        expect(c.chunkId, startsWith('doc_beta__c_'));
      }
    });

    test('load SQL marks prior chunks inactive (never deletes), inserts '
        'current chunks active, and keeps embedding match by chunk_id + '
        'content_sha256', () async {
      final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
      final validation = await CorpusValidator(repoRoot: repo).validate();
      final plan = await CorpusChunkPlanner(
        repoRoot: repo,
      ).plan(validation.manifest);
      await CorpusIngestionMaterializer(
        repoRoot: repo,
      ).materialize(manifest: validation.manifest, plan: plan);

      final result = await CorpusDbLoadPreparer(repoRoot: repo).prepare();
      final chunksSql = File(
        '${result.outputDirectory}/003_source_chunks.sql',
      ).readAsStringSync();

      // Stale chunks for the materialized doc(s) get deactivated up
      // front, in a single update keyed on doc_id.
      expect(chunksSql, contains('update public.advisor_source_chunks'));
      expect(chunksSql, contains('set active = false'));
      expect(chunksSql, contains("where doc_id in ('sample_doc')"));

      // Current chunks are inserted active=true and the upsert path
      // re-activates a previously-deactivated chunk if its content
      // re-emerged.
      expect(chunksSql, contains('insert into public.advisor_source_chunks'));
      expect(chunksSql, contains('active'));
      expect(chunksSql, contains('active = excluded.active'));
      expect(chunksSql, contains('bm25_tsv'));
      expect(chunksSql, contains("to_tsvector('english'::regconfig"));
      expect(chunksSql, contains('bm25_tsv = excluded.bm25_tsv'));

      // No deletion path — old chunks must remain in the table for
      // citation replay.
      expect(
        chunksSql,
        isNot(contains('delete from public.advisor_source_chunks')),
      );
    });

    test(
      '11a.11b: doc with zero current chunks is still deactivated',
      () async {
        final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
        final validation = await CorpusValidator(repoRoot: repo).validate();
        final plan = await CorpusChunkPlanner(
          repoRoot: repo,
        ).plan(validation.manifest);
        await CorpusIngestionMaterializer(
          repoRoot: repo,
        ).materialize(manifest: validation.manifest, plan: plan);

        // Append a synthetic source-document record that has no
        // matching chunk records. This simulates a manifest-included
        // doc that materialized with zero current chunks (e.g. a
        // template-only file). The fix for 11a.11b must still
        // deactivate prior chunks for this doc_id.
        final docsFile = File(
          '${repo.path}/build/advisor_corpus/source_documents.jsonl',
        );
        final docLines = docsFile.readAsLinesSync();
        final templateDoc = jsonDecode(docLines.first) as Map<String, Object?>;
        final zeroChunkDoc = Map<String, Object?>.from(templateDoc)
          ..['doc_id'] = 'zero_chunk_doc'
          ..['file_name'] = 'zero.md'
          ..['source_path'] = 'docs/Knowledge_graph_docs/zero.md'
          ..['title'] = 'Zero Chunk Handbook';
        docsFile.writeAsStringSync(
          '${docLines.join('\n')}\n${jsonEncode(zeroChunkDoc)}\n',
        );

        final result = await CorpusDbLoadPreparer(repoRoot: repo).prepare();
        final chunksSql = File(
          '${result.outputDirectory}/003_source_chunks.sql',
        ).readAsStringSync();

        // Both the chunk-bearing doc and the zero-chunk doc must
        // appear in the deactivation list, in sorted order. The fix
        // keys the list on the materialized source-document records,
        // not on the chunk records themselves.
        expect(
          chunksSql,
          contains("where doc_id in ('sample_doc', 'zero_chunk_doc')"),
        );
        expect(chunksSql, contains('set active = false'));

        // The zero-chunk doc has no chunk rows. A content-addressed
        // chunk-id prefixed `zero_chunk_doc__c_` would only appear in
        // the SQL if a chunk row had been emitted for it, so the
        // absence proves no upsert target exists for the empty doc.
        expect(chunksSql, isNot(contains('zero_chunk_doc__c_')));

        // No deletion path — old chunks for the zero-chunk doc stay
        // in the table for citation replay.
        expect(
          chunksSql,
          isNot(contains('delete from public.advisor_source_chunks')),
        );
      },
    );
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
        // 11a.11a: chunk ordering is content-addressed (lex by hash),
        // so the first record is no longer guaranteed to be the
        // introductory section. Assert the doc title appears in at
        // least one input across the file instead.
        final allInputLines = File(
          '${first.outputDirectory}/embedding_inputs.jsonl',
        ).readAsLinesSync().where((l) => l.trim().isNotEmpty).toList();
        final allInputTexts = <String>[
          for (final line in allInputLines)
            (jsonDecode(line) as Map<String, Object?>)['input'].toString(),
        ];
        expect(allInputTexts.any((t) => t.contains('Sample Handbook')), isTrue);

        // 11a.8: prepare-embeddings template documents the provider-safe
        // triple that execute-embeddings will write per row.
        final updateTemplate = File(
          '${first.outputDirectory}/embedding_update_template.sql',
        ).readAsStringSync();
        expect(updateTemplate, contains('embedding_provider_id'));
        expect(updateTemplate, contains('embedding_model_id'));
        expect(updateTemplate, contains('embedding_dimension'));
        expect(updateTemplate, contains('11a.8'));
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
        // 11a.8 versioned embedding metadata: each row update writes the
        // provider-safe triple consumed by advisor_search_chunks and the
        // HNSW partial index.
        expect(sql, contains("embedding_provider_id = 'voyage'"));
        expect(sql, contains("embedding_model_id = 'voyage-4-large'"));
        expect(sql, contains('embedding_dimension = 1024'));
        // Surface comment carries the 11a.8 note.
        expect(sql, contains('11a.8'));
        expect(sql, contains('advisor_search_chunks'));
        // Database mutation is still gated by the manifest, not by SQL apply.
        expect(executionManifest['database_mutation'], isFalse);
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

  group('Advisor corpus Contextual Retrieval executor', () {
    test(
      'writes chunk_context SQL and context-enriched embedding inputs',
      () async {
        final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
        final validation = await CorpusValidator(repoRoot: repo).validate();
        final plan = await CorpusChunkPlanner(
          repoRoot: repo,
        ).plan(validation.manifest);
        await CorpusIngestionMaterializer(
          repoRoot: repo,
        ).materialize(manifest: validation.manifest, plan: plan);

        final gateway = _FakeContextGateway();
        final result = await CorpusContextExecutor(
          repoRoot: repo,
          gateway: gateway,
        ).execute(apiKey: 'test-key');
        final manifest =
            jsonDecode(
                  File(
                    '${result.outputDirectory}/context_execution_manifest.json',
                  ).readAsStringSync(),
                )
                as Map<String, Object?>;
        final contexts = File(
          '${result.outputDirectory}/chunk_contexts.jsonl',
        ).readAsLinesSync().where((line) => line.trim().isNotEmpty).toList();
        final embeddingInputs = File(
          '${result.outputDirectory}/embedding_inputs.jsonl',
        ).readAsLinesSync().where((line) => line.trim().isNotEmpty).toList();
        final firstContext = jsonDecode(contexts.first) as Map<String, Object?>;
        final firstEmbeddingInput =
            jsonDecode(embeddingInputs.first) as Map<String, Object?>;
        final sql = File(
          '${result.outputDirectory}/chunk_context_updates.sql',
        ).readAsStringSync();

        expect(result.chunkCount, plan.chunkCount);
        expect(result.provider, advisorContextProvider);
        expect(result.model, advisorContextModel);
        expect(gateway.seenModel, advisorContextModel);
        expect(gateway.seenChunkTexts.length, plan.chunkCount);
        expect(manifest['database_mutation'], isFalse);
        expect(
          manifest['contextual_embedding_input_file'],
          'embedding_inputs.jsonl',
        );
        expect(contexts.length, plan.chunkCount);
        expect(embeddingInputs.length, plan.chunkCount);
        expect(firstContext['record_type'], 'chunk_context');
        expect(firstContext['provider'], advisorContextProvider);
        expect(firstContext['model'], advisorContextModel);
        expect(firstContext['context'], contains('Generated context for'));
        expect(
          firstEmbeddingInput['input'].toString(),
          startsWith(firstContext['context'].toString()),
        );
        expect(firstEmbeddingInput['context_provider'], advisorContextProvider);
        expect(sql, contains('update public.advisor_source_chunks'));
        expect(sql, contains('chunk_context ='));
        expect(sql, contains('bm25_tsv ='));
        expect(sql, contains('content_sha256'));
        expect(sql, contains('to_tsvector'));
      },
    );

    test('requires ANTHROPIC_API_KEY for live context generation', () async {
      final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
      final validation = await CorpusValidator(repoRoot: repo).validate();
      final plan = await CorpusChunkPlanner(
        repoRoot: repo,
      ).plan(validation.manifest);
      await CorpusIngestionMaterializer(
        repoRoot: repo,
      ).materialize(manifest: validation.manifest, plan: plan);

      expect(
        CorpusContextExecutor(
          repoRoot: repo,
          gateway: _FakeContextGateway(),
        ).execute(apiKey: ''),
        throwsA(isA<CorpusManifestException>()),
      );
    });
  });

  group('Advisor corpus schema scaffold', () {
    test('requires pgvector while keeping Apache AGE projection optional', () {
      final migration = File(
        'db/migrations/202604250001_advisor_corpus_storage_schema.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final embeddingContractMigration = File(
        'db/migrations/202604250002_advisor_embedding_contract.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');

      expect(migration, contains('create extension if not exists vector'));
      expect(migration, contains("where name = 'age'"));
      // 7.57.4: projection is no longer "a later slice" — the preparer
      // generates it now, conditional on AGE availability.
      expect(migration, contains('tool/advisor_corpus prepare-age-projection'));
      expect(
        migration,
        isNot(contains('advisor graph projection remains staged only')),
      );
      expect(migration, isNot(contains('for later Apache AGE ingestion')));
      expect(migration, contains('embedding vector(1024)'));
      expect(embeddingContractMigration, contains('vector(1024)'));
      expect(embeddingContractMigration, contains('voyage-4-large'));
      expect(embeddingContractMigration, contains('rerank-2.5'));
      expect(embeddingContractMigration, contains('Claude'));
      // 11a.11a active flag + comment on advisor_source_chunks.
      expect(migration, contains('active boolean not null default true'));
      expect(
        migration,
        contains('comment on column public.advisor_source_chunks.active'),
      );
      expect(migration, contains('11a.11a'));
    });
  });

  group('Advisor vector search migration (11a.8)', () {
    test('adds versioned embedding metadata, HNSW cosine index, and a stable '
        'scoped advisor_search_chunks function', () {
      final migration = File(
        'db/migrations/202604250003_advisor_vector_search.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');

      // Provider/model/dimension columns.
      expect(
        migration,
        contains('add column if not exists embedding_provider_id text'),
      );
      expect(
        migration,
        contains('add column if not exists embedding_model_id text'),
      );
      expect(
        migration,
        contains('add column if not exists embedding_dimension integer'),
      );

      // Backfill from the locked Voyage row shape.
      expect(migration, contains("set embedding_provider_id = 'voyage'"));
      expect(migration, contains("embedding_model_id = 'voyage-4-large'"));
      expect(migration, contains('embedding_dimension = 1024'));
      expect(migration, contains("embedding_status = 'ready'"));
      expect(migration, contains('embedding is not null'));

      // Column comments document the provider-safe contract.
      expect(
        migration,
        contains(
          'comment on column public.advisor_source_chunks.embedding_provider_id',
        ),
      );
      expect(
        migration,
        contains(
          'comment on column public.advisor_source_chunks.embedding_model_id',
        ),
      );
      expect(
        migration,
        contains(
          'comment on column public.advisor_source_chunks.embedding_dimension',
        ),
      );

      // HNSW cosine index, partial on the provider-safe triple.
      expect(
        migration,
        contains(
          'create index if not exists advisor_source_chunks_voyage_hnsw_idx',
        ),
      );
      expect(migration, contains('using hnsw (embedding vector_cosine_ops)'));
      expect(migration, contains("embedding_provider_id = 'voyage'"));
      expect(migration, contains("embedding_model_id = 'voyage-4-large'"));
      expect(migration, contains('embedding_dimension = 1024'));

      // Stable scoped search function.
      expect(
        migration,
        contains('create or replace function public.advisor_search_chunks'),
      );
      expect(migration, contains('query_embedding vector(1024)'));
      expect(migration, contains('scope_filter text'));
      expect(migration, contains('restaurant_id_filter uuid'));
      expect(migration, contains('provider_id_filter text'));
      expect(migration, contains('model_id_filter text'));
      expect(migration, contains('dimension_filter integer'));
      expect(migration, contains('max_results integer'));

      // Returns citation/provenance metadata alongside scores.
      expect(migration, contains('returns table'));
      expect(migration, contains('chunk_id text'));
      expect(migration, contains('doc_id text'));
      expect(migration, contains('source_path text'));
      expect(migration, contains('heading_path text[]'));
      expect(migration, contains('content_sha256 text'));
      expect(migration, contains('provenance jsonb'));
      expect(migration, contains('similarity double precision'));
      expect(migration, contains('distance double precision'));

      // Cosine distance operator + similarity = 1 - distance.
      expect(migration, contains('c.embedding <=> query_embedding'));
      expect(migration, contains('1.0 - (c.embedding <=> query_embedding)'));

      // Filters: status, non-null, provider/model/dimension, scope,
      // optional restaurant_id.
      expect(migration, contains("c.embedding_status = 'ready'"));
      expect(migration, contains('c.embedding is not null'));
      expect(
        migration,
        contains('c.embedding_provider_id = provider_id_filter'),
      );
      expect(migration, contains('c.embedding_model_id = model_id_filter'));
      expect(migration, contains('c.embedding_dimension = dimension_filter'));
      expect(migration, contains('c.scope = scope_filter'));
      expect(
        migration,
        contains(
          'restaurant_id_filter is null or c.restaurant_id = restaurant_id_filter',
        ),
      );

      // Result count cap is bounded.
      expect(migration, contains('greatest(1, least('));
      expect(migration, contains('100)'));

      // Function is `stable` (read-only) and language sql so the
      // planner can inline it through the HNSW index.
      expect(migration, contains('language sql'));
      expect(migration, contains('stable'));

      // Routing-rules comment: candidate retrieval only — rerank +
      // Claude answer runtime are downstream slices.
      expect(migration, contains('Reranking'));
      expect(migration, contains('11a.9'));
      expect(migration, contains('candidate retrieval'));

      // 11a.11a: active filtering on both the function and the
      // partial HNSW index predicate.
      expect(migration, contains('c.active = true'));
      expect(migration, contains('and active = true'));
    });
  });

  group('Advisor corpus rerank smoke (11a.9)', () {
    CorpusVectorSearchCandidate candidate({
      required String chunkId,
      required String text,
      double similarity = 0.5,
      double distance = 0.5,
      String sourcePath = 'docs/Knowledge_graph_docs/sample.md',
      List<String>? headingPath,
      String? contentSha256,
      Map<String, Object?>? provenance,
    }) {
      return CorpusVectorSearchCandidate(
        chunkId: chunkId,
        text: text,
        sourcePath: sourcePath,
        headingPath: headingPath ?? const <String>['Sample Handbook'],
        contentSha256: contentSha256 ?? ('a' * 64),
        provenance:
            provenance ??
            const <String, Object?>{
              'source_doc_id': 'sample_doc',
              'heading_path': <String>['Sample Handbook'],
              'confidence': 'extracted',
            },
        similarity: similarity,
        distance: distance,
      );
    }

    test(
      'routes through VoyageRerankProvider with the rerank-2.5 model',
      () async {
        String? seenModel;
        final provider = VoyageRerankProvider(
          rerankFn:
              ({
                required String query,
                required List<RerankCandidate> candidates,
                required String model,
              }) async {
                seenModel = model;
                return [for (final c in candidates) (id: c.id, score: 0.5)];
              },
        );
        final runner = CorpusRerankSmokeRunner(rerankProvider: provider);

        final result = await runner.run(
          query: 'how do we improve CPLH',
          candidates: <CorpusVectorSearchCandidate>[
            candidate(chunkId: 'chunk_a', text: 'CPLH context A'),
          ],
        );

        expect(seenModel, equals(AdvisorProviderConstants.voyageRerankModelId));
        expect(seenModel, equals('rerank-2.5'));
        expect(result.providerId, equals('voyage'));
        expect(result.modelId, equals('rerank-2.5'));
        expect(result.query, equals('how do we improve CPLH'));
      },
    );

    test(
      'orders rows by provider score, not by original vector similarity',
      () async {
        // Vector order: chunk_a (sim 0.90) > chunk_c (sim 0.80) > chunk_b
        // (sim 0.70). Rerank gateway flips it: chunk_b is the strongest
        // CPLH match per rerank score. The rerank smoke output must
        // honor the provider order, not the vector order.
        final provider = VoyageRerankProvider(
          rerankFn:
              ({
                required String query,
                required List<RerankCandidate> candidates,
                required String model,
              }) async {
                return const [
                  (id: 'chunk_a', score: 0.20),
                  (id: 'chunk_b', score: 0.99),
                  (id: 'chunk_c', score: 0.50),
                ];
              },
        );
        final runner = CorpusRerankSmokeRunner(rerankProvider: provider);

        final result = await runner.run(
          query: 'CPLH',
          candidates: <CorpusVectorSearchCandidate>[
            candidate(
              chunkId: 'chunk_a',
              text: 'tangential CPLH mention',
              similarity: 0.90,
              distance: 0.10,
            ),
            candidate(
              chunkId: 'chunk_b',
              text: 'strong CPLH guidance and worked example',
              similarity: 0.70,
              distance: 0.30,
            ),
            candidate(
              chunkId: 'chunk_c',
              text: 'CPLH adjacent context',
              similarity: 0.80,
              distance: 0.20,
            ),
          ],
        );

        // Rerank order, not vector order.
        expect(
          result.rows.map((row) => row.chunkId).toList(),
          equals(<String>['chunk_b', 'chunk_c', 'chunk_a']),
        );
        expect(
          result.rows.map((row) => row.rank).toList(),
          equals(<int>[0, 1, 2]),
        );
        expect(result.rows.first.rerankScore, closeTo(0.99, 1e-9));
        expect(result.rows.last.rerankScore, closeTo(0.20, 1e-9));

        // Each row preserves its original vector metrics.
        expect(result.rows.first.vectorSimilarity, closeTo(0.70, 1e-9));
        expect(result.rows.first.vectorDistance, closeTo(0.30, 1e-9));
        expect(result.rows.last.vectorSimilarity, closeTo(0.90, 1e-9));
        expect(result.rows.last.vectorDistance, closeTo(0.10, 1e-9));
      },
    );

    test(
      'preserves citation/provenance metadata unchanged across rerank',
      () async {
        const richProvenance = <String, Object?>{
          'source_doc_id': 'sample_doc',
          'heading_path': <String>['Sample Handbook', 'Food Safety'],
          'chunk_id': 'chunk_a',
          'confidence': 'extracted',
        };
        final provider = VoyageRerankProvider(
          rerankFn:
              ({
                required String query,
                required List<RerankCandidate> candidates,
                required String model,
              }) async => [for (final c in candidates) (id: c.id, score: 0.7)],
        );
        final runner = CorpusRerankSmokeRunner(rerankProvider: provider);

        final result = await runner.run(
          query: 'CPLH',
          candidates: <CorpusVectorSearchCandidate>[
            CorpusVectorSearchCandidate(
              chunkId: 'chunk_a',
              text: 'CPLH guidance',
              sourcePath: 'docs/Knowledge_graph_docs/sample.md',
              headingPath: const <String>['Sample Handbook', 'Food Safety'],
              contentSha256: 'b' * 64,
              provenance: richProvenance,
              similarity: 0.85,
              distance: 0.15,
            ),
          ],
        );

        final row = result.rows.single;
        expect(row.chunkId, equals('chunk_a'));
        expect(row.sourcePath, equals('docs/Knowledge_graph_docs/sample.md'));
        expect(
          row.headingPath,
          equals(const <String>['Sample Handbook', 'Food Safety']),
        );
        expect(row.contentSha256, equals('b' * 64));
        expect(row.provenance, equals(richProvenance));
        // Vector metrics survive too.
        expect(row.vectorSimilarity, closeTo(0.85, 1e-9));
        expect(row.vectorDistance, closeTo(0.15, 1e-9));
      },
    );

    test(
      'empty candidates degrade to empty rows without calling the gateway',
      () async {
        var gatewayCalled = false;
        final provider = VoyageRerankProvider(
          rerankFn:
              ({
                required String query,
                required List<RerankCandidate> candidates,
                required String model,
              }) async {
                gatewayCalled = true;
                return const <({String id, double score})>[];
              },
        );
        final runner = CorpusRerankSmokeRunner(rerankProvider: provider);

        final result = await runner.run(
          query: 'q',
          candidates: const <CorpusVectorSearchCandidate>[],
        );

        expect(result.rows, isEmpty);
        // Provider id/model still surface for routing observability.
        expect(result.providerId, equals('voyage'));
        expect(result.modelId, equals('rerank-2.5'));
        expect(gatewayCalled, isFalse);
      },
    );

    test('unknown gateway-returned id is rejected by the provider check '
        'and propagates through the smoke runner', () async {
      final provider = VoyageRerankProvider(
        rerankFn:
            ({
              required String query,
              required List<RerankCandidate> candidates,
              required String model,
            }) async => const [(id: 'never_in_candidate_list', score: 0.5)],
      );
      final runner = CorpusRerankSmokeRunner(rerankProvider: provider);

      expect(
        runner.run(
          query: 'CPLH',
          candidates: <CorpusVectorSearchCandidate>[
            candidate(chunkId: 'chunk_a', text: 'A'),
          ],
        ),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'mismatched gateway score count is rejected by the provider check',
      () async {
        final provider = VoyageRerankProvider(
          rerankFn:
              ({
                required String query,
                required List<RerankCandidate> candidates,
                required String model,
              }) async => const [
                (id: 'chunk_a', score: 0.7),
              ], // missing chunk_b
        );
        final runner = CorpusRerankSmokeRunner(rerankProvider: provider);

        expect(
          runner.run(
            query: 'CPLH',
            candidates: <CorpusVectorSearchCandidate>[
              candidate(chunkId: 'chunk_a', text: 'A'),
              candidate(chunkId: 'chunk_b', text: 'B'),
            ],
          ),
          throwsA(isA<StateError>()),
        );
      },
    );
  });

  group('Advisor corpus AGE projection preparer', () {
    test(
      'writes deterministic AGE projection + smoke SQL artifacts and a manifest',
      () async {
        final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
        final validation = await CorpusValidator(repoRoot: repo).validate();
        final plan = await CorpusChunkPlanner(
          repoRoot: repo,
        ).plan(validation.manifest);
        await CorpusIngestionMaterializer(
          repoRoot: repo,
        ).materialize(manifest: validation.manifest, plan: plan);
        final preparer = CorpusAgeProjectionPreparer(repoRoot: repo);

        final first = await preparer.prepare();
        final firstProjection = await File(
          '${first.outputDirectory}/'
          '${CorpusAgeProjectionPreparer.projectionFileName}',
        ).readAsString();
        final firstSmoke = await File(
          '${first.outputDirectory}/'
          '${CorpusAgeProjectionPreparer.smokeFileName}',
        ).readAsString();
        final firstIndexStrategy = await File(
          '${first.outputDirectory}/'
          '${CorpusAgeProjectionPreparer.indexStrategyFileName}',
        ).readAsString();
        final firstBenchmarkHarness = await File(
          '${first.outputDirectory}/'
          '${CorpusAgeProjectionPreparer.benchmarkHarnessFileName}',
        ).readAsString();
        final firstVectorDecision = await File(
          '${first.outputDirectory}/'
          '${CorpusAgeProjectionPreparer.vectorDecisionFileName}',
        ).readAsString();
        final second = await preparer.prepare();
        final secondProjection = await File(
          '${second.outputDirectory}/'
          '${CorpusAgeProjectionPreparer.projectionFileName}',
        ).readAsString();
        final secondSmoke = await File(
          '${second.outputDirectory}/'
          '${CorpusAgeProjectionPreparer.smokeFileName}',
        ).readAsString();
        final secondIndexStrategy = await File(
          '${second.outputDirectory}/'
          '${CorpusAgeProjectionPreparer.indexStrategyFileName}',
        ).readAsString();
        final secondBenchmarkHarness = await File(
          '${second.outputDirectory}/'
          '${CorpusAgeProjectionPreparer.benchmarkHarnessFileName}',
        ).readAsString();
        final secondVectorDecision = await File(
          '${second.outputDirectory}/'
          '${CorpusAgeProjectionPreparer.vectorDecisionFileName}',
        ).readAsString();
        final manifest =
            jsonDecode(
                  File(
                    '${first.outputDirectory}/'
                    '${CorpusAgeProjectionPreparer.manifestFileName}',
                  ).readAsStringSync(),
                )
                as Map<String, Object?>;

        // Determinism between runs.
        expect(first.projectionRunId, second.projectionRunId);
        expect(secondProjection, firstProjection);
        expect(secondSmoke, firstSmoke);
        expect(secondIndexStrategy, firstIndexStrategy);
        expect(secondBenchmarkHarness, firstBenchmarkHarness);
        expect(secondVectorDecision, firstVectorDecision);

        // Manifest shape.
        expect(
          manifest['record_type'],
          'advisor_corpus_age_projection_manifest',
        );
        expect(manifest['graph_name'], advisorAgeGraphName);
        expect(manifest['apply_mode'], 'not_applied_build_artifacts_only');
        expect(manifest['projection_run_id'], first.projectionRunId);

        final projectionFiles = (manifest['projection_files']! as List<Object?>)
            .cast<Map<String, Object?>>();
        expect(projectionFiles.map((f) => f['file']).toList(), <String>[
          CorpusAgeProjectionPreparer.projectionFileName,
          CorpusAgeProjectionPreparer.smokeFileName,
          CorpusAgeProjectionPreparer.indexStrategyFileName,
          CorpusAgeProjectionPreparer.benchmarkHarnessFileName,
          CorpusAgeProjectionPreparer.vectorDecisionFileName,
        ]);

        final inputs = manifest['projection_inputs']! as Map<String, Object?>;
        expect(
          inputs['graph_node_seed_table'],
          'public.advisor_graph_node_seeds',
        );
        expect(
          inputs['graph_edge_hint_table'],
          'public.advisor_graph_edge_hints',
        );
        expect(
          (inputs['expected_node_types']! as List<Object?>).cast<String>(),
          containsAll(<String>['Document', 'Chunk']),
        );
        expect(
          (inputs['expected_edge_types']! as List<Object?>).cast<String>(),
          contains('CONTAINS'),
        );

        final expectedCounts =
            manifest['expected_counts_from_summary']! as Map<String, Object?>;
        expect(expectedCounts['graph_node_seeds'], first.expectedNodeSeedCount);
        expect(expectedCounts['graph_edge_hints'], first.expectedEdgeHintCount);

        final blocker = manifest['blocker_path']! as Map<String, Object?>;
        expect(blocker['condition'], contains('pg_available_extensions'));
        expect(blocker['behavior'], contains('AGE_BLOCKER'));

        final ageIndexStrategy =
            manifest['age_index_strategy']! as Map<String, Object?>;
        expect(
          (ageIndexStrategy['labels']! as List<Object?>).cast<String>(),
          containsAll(<String>['Document', 'Chunk', 'CONTAINS']),
        );
        expect(ageIndexStrategy['btree_required'], isA<List<Object?>>());
        expect(ageIndexStrategy['gin_required'], contains('properties'));

        final benchmarkGate =
            manifest['benchmark_gate']! as Map<String, Object?>;
        expect(
          (benchmarkGate['synthetic_operator_scales']! as List<Object?>)
              .cast<int>(),
          <int>[1000, 10000],
        );
        expect(benchmarkGate['isolated_p95_ms_max'], 500);
        expect(benchmarkGate['concurrent_10x_p95_ms_max'], 1000);

        final vectorDecision =
            manifest['vector_index_decision']! as Map<String, Object?>;
        expect(vectorDecision['candidates'], contains('DiskANN'));
        expect(vectorDecision['rule'], contains('do not drop HNSW'));

        // Notes are honest about current shape — no fake Metric / Chapter /
        // Formula nodes are claimed.
        final notes = (manifest['notes']! as List<Object?>).cast<String>();
        expect(notes.join('\n'), contains('Document/Chunk'));
        expect(notes.join('\n'), contains('Metric / Chapter / Formula'));
      },
    );

    test('projection SQL is idempotent and reads from the staged graph tables, '
        'with an explicit AGE-missing blocker', () async {
      final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
      final validation = await CorpusValidator(repoRoot: repo).validate();
      final plan = await CorpusChunkPlanner(
        repoRoot: repo,
      ).plan(validation.manifest);
      await CorpusIngestionMaterializer(
        repoRoot: repo,
      ).materialize(manifest: validation.manifest, plan: plan);
      final result = await CorpusAgeProjectionPreparer(
        repoRoot: repo,
      ).prepare();
      final projectionSql = await File(
        '${result.outputDirectory}/'
        '${CorpusAgeProjectionPreparer.projectionFileName}',
      ).readAsString();

      // Reads from staged graph tables.
      expect(projectionSql, contains('public.advisor_graph_node_seeds'));
      expect(projectionSql, contains('public.advisor_graph_edge_hints'));
      expect(projectionSql, contains("node_type = 'Document'"));
      expect(projectionSql, contains("node_type = 'Chunk'"));

      // AGE availability gate.
      expect(
        projectionSql,
        contains("from pg_available_extensions where name = 'age'"),
      );
      expect(projectionSql, contains('AGE_BLOCKER'));

      // Idempotent extension + graph creation.
      expect(projectionSql, contains('create extension if not exists age'));
      expect(projectionSql, contains('ag_catalog.create_graph'));
      expect(projectionSql, contains('ag_catalog.ag_graph'));

      // MERGE-based vertex projection (idempotent on re-run).
      expect(projectionSql, contains('MERGE (v:Document {node_id:'));
      expect(projectionSql, contains('MERGE (v:Chunk {node_id:'));

      // Edge projection from edge_hints with MERGE.
      expect(projectionSql, contains('MERGE (a)-[r:'));

      // Stamps projected provenance back onto the seed tables.
      expect(projectionSql, contains('update public.advisor_graph_node_seeds'));
      expect(projectionSql, contains('age_graph_name'));
      expect(projectionSql, contains('age_vertex_id'));
      expect(projectionSql, contains('update public.advisor_graph_edge_hints'));
      expect(projectionSql, contains('age_edge_id'));
    });

    test('smoke traversal SQL covers the CPLH path honestly against the '
        'current Document -> CONTAINS -> Chunk shape', () async {
      final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
      final validation = await CorpusValidator(repoRoot: repo).validate();
      final plan = await CorpusChunkPlanner(
        repoRoot: repo,
      ).plan(validation.manifest);
      await CorpusIngestionMaterializer(
        repoRoot: repo,
      ).materialize(manifest: validation.manifest, plan: plan);
      final result = await CorpusAgeProjectionPreparer(
        repoRoot: repo,
      ).prepare();
      final smokeSql = await File(
        '${result.outputDirectory}/'
        '${CorpusAgeProjectionPreparer.smokeFileName}',
      ).readAsString();

      // Cypher traversal pattern.
      expect(smokeSql, contains('MATCH (d:Document)-[:CONTAINS]->(c:Chunk)'));

      // Joins to advisor_source_chunks for the CPLH text/heading filter.
      expect(smokeSql, contains('public.advisor_source_chunks'));
      expect(smokeSql, contains('cplh'));
      expect(smokeSql, contains('lower(ch.text)'));
      expect(smokeSql, contains('unnest(ch.heading_path)'));

      // AGE-missing blocker is present in the smoke artifact too.
      expect(
        smokeSql,
        contains("from pg_available_extensions where name = 'age'"),
      );
      expect(smokeSql, contains('AGE_BLOCKER'));

      // Reports both the structural and CPLH-bearing counts honestly.
      expect(smokeSql, contains('document_chunk_pairs'));
      expect(smokeSql, contains('cplh_bearing_chunks'));
    });

    test(
      'AGE index strategy artifact covers required BTree and GIN indexes',
      () async {
        final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
        final validation = await CorpusValidator(repoRoot: repo).validate();
        final plan = await CorpusChunkPlanner(
          repoRoot: repo,
        ).plan(validation.manifest);
        await CorpusIngestionMaterializer(
          repoRoot: repo,
        ).materialize(manifest: validation.manifest, plan: plan);
        final result = await CorpusAgeProjectionPreparer(
          repoRoot: repo,
        ).prepare();
        final indexSql = await File(
          '${result.outputDirectory}/'
          '${CorpusAgeProjectionPreparer.indexStrategyFileName}',
        ).readAsString();

        expect(indexSql, contains('AGE_BLOCKER'));
        expect(indexSql, contains('AGE_INDEX_BLOCKER'));
        expect(indexSql, contains('using btree (id)'));
        expect(indexSql, contains('using btree (start_id)'));
        expect(indexSql, contains('using btree (end_id)'));
        expect(indexSql, contains('using gin (properties)'));
        expect(indexSql, contains('Document'));
        expect(indexSql, contains('Chunk'));
        expect(indexSql, contains('CONTAINS'));
        expect(indexSql, contains('"node_id"'));
        expect(indexSql, contains('"source_chunk_id"'));
        expect(indexSql, contains('"edge_id"'));
      },
    );

    test(
      'benchmark + DiskANN decision artifacts are local-only runbooks',
      () async {
        final repo = await _createFixtureRepo(content: _headingAwareMarkdown);
        final validation = await CorpusValidator(repoRoot: repo).validate();
        final plan = await CorpusChunkPlanner(
          repoRoot: repo,
        ).plan(validation.manifest);
        await CorpusIngestionMaterializer(
          repoRoot: repo,
        ).materialize(manifest: validation.manifest, plan: plan);
        final result = await CorpusAgeProjectionPreparer(
          repoRoot: repo,
        ).prepare();
        final benchmarkSql = await File(
          '${result.outputDirectory}/'
          '${CorpusAgeProjectionPreparer.benchmarkHarnessFileName}',
        ).readAsString();
        final vectorDecisionSql = await File(
          '${result.outputDirectory}/'
          '${CorpusAgeProjectionPreparer.vectorDecisionFileName}',
        ).readAsString();

        expect(benchmarkSql, contains('operator scales: 1K and 10K'));
        expect(benchmarkSql, contains('isolated p95 <= 500 ms'));
        expect(benchmarkSql, contains('10x concurrent p95 <= 1000 ms'));
        expect(benchmarkSql, contains('pgbench --client=1'));
        expect(benchmarkSql, contains('pgbench --client=10'));
        expect(
          benchmarkSql,
          contains("MATCH (d:Document)-[:CONTAINS]->(c:Chunk)"),
        );
        expect(
          benchmarkSql,
          contains('phase_11a_11c6b_age_benchmark_result.md'),
        );

        expect(vectorDecisionSql, contains('using diskann'));
        expect(
          vectorDecisionSql,
          contains('advisor_source_chunks_voyage_diskann_idx'),
        );
        expect(
          vectorDecisionSql,
          contains('advisor_source_chunks_voyage_hnsw_idx'),
        );
        expect(vectorDecisionSql, contains('Do NOT drop'));
        expect(
          vectorDecisionSql,
          contains('explain (analyze, buffers, format json)'),
        );
        expect(
          vectorDecisionSql,
          contains(":'query_embedding_1024'::vector(1024)"),
        );
        expect(vectorDecisionSql, isNot(contains("'[0.0]'::vector(1024)")));
        expect(
          vectorDecisionSql,
          contains('phase_11a_11c6b_vector_index_decision.md'),
        );
      },
    );
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

// 11a.11a: same shape as `_headingAwareMarkdown` but with materially
// different Food Safety body text so the chunk-id content-address
// changes for that section while the introductory section stays
// stable. Used to prove "changing chunk text changes chunk_id".
const _alteredHandbookMarkdown = '''
---
source: fixture
---

# Sample Handbook

Introductory context for the sample handbook.

## Food Safety

Wash hands twice before prep. Refrigerate cold food immediately and reheat hot food to 165 degrees.

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

class _FakeContextGateway implements AdvisorContextGateway {
  String? seenModel;
  final seenChunkTexts = <String>[];

  @override
  Future<String> generateContext({
    required String apiKey,
    required String model,
    required String documentTitle,
    required String sourcePath,
    required List<String> headingPath,
    required String chunkText,
  }) async {
    seenModel = model;
    seenChunkTexts.add(chunkText);
    return 'Generated context for $documentTitle at ${headingPath.join(' > ')}.';
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

/// 11a.11a fixture: two distinct docs whose source content overlaps
/// (both have a `## Food Safety` section with identical body). Used to
/// prove cross-doc chunk_id collision is impossible under content-
/// addressed ids.
Future<Directory> _createTwoDocFixtureWithSharedChunkText() async {
  final repo = await Directory.systemTemp.createTemp('advisor_corpus_2doc_');
  const sharedMarkdown = '''
---
source: fixture
---

# Shared Title

Introductory context shared between docs.

## Food Safety

Identical Food Safety body text in both docs to force a chunk-content
overlap, exercising the content-addressed id's doc-prefix discipline.
''';
  await _writeText(repo, 'docs/Knowledge_graph_docs/alpha.md', sharedMarkdown);
  await _writeText(repo, 'docs/Knowledge_graph_docs/beta.md', sharedMarkdown);
  final alphaHash = await sha256ForFile(
    File('${repo.path}/docs/Knowledge_graph_docs/alpha.md'),
  );
  final betaHash = await sha256ForFile(
    File('${repo.path}/docs/Knowledge_graph_docs/beta.md'),
  );
  final manifest = _manifestYaml(<_FixtureDoc>[
    _FixtureDoc(
      docId: 'doc_alpha',
      fileName: 'alpha.md',
      sourcePath: 'docs/Knowledge_graph_docs/alpha.md',
      title: 'Shared Title',
      chunkProfile: 'heading_aware_policy_handbook',
      contentRole: 'operating_handbook',
      riskLevel: 'medium',
      sha256Hash: alphaHash,
    ),
    _FixtureDoc(
      docId: 'doc_beta',
      fileName: 'beta.md',
      sourcePath: 'docs/Knowledge_graph_docs/beta.md',
      title: 'Shared Title',
      chunkProfile: 'heading_aware_policy_handbook',
      contentRole: 'operating_handbook',
      riskLevel: 'medium',
      sha256Hash: betaHash,
    ),
  ]);
  await _writeText(repo, defaultManifestPath, manifest);
  return repo;
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
