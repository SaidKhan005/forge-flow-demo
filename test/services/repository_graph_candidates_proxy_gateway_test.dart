// Phase 11A.3b — RepositoryGraphCandidatesProxyGateway tests.
//
// Targets the production proxy gateway directly (not the route
// handler). Coverage:
//
//   * P1 review finding: a replayed Idempotency-Key returns the
//     cached commit result without hitting the underlying
//     GraphRepository a second time. The route handler enforces the
//     header (400 missing_idempotency_key); this gateway honours it
//     by deduping at the gateway boundary so a retry cannot stamp a
//     duplicate audit row or trip the canonical UNIQUE on
//     (operator, scope, version, node_key).
//
//   * P2 review finding: defense-in-depth manifest scope filter on
//     resolved candidates. The route handler can only inspect
//     `edited_payload.source_file`; approve / reject decisions carry
//     only `candidate_id` over the wire, so this is the only point
//     where a stale or tampered out-of-scope JSONL entry is caught
//     for those decision kinds. The gateway re-reads the manifest
//     and rejects the commit if any resolved candidate's
//     `source_file` is no longer in the active manifest scope.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/graph_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart'
    show GraphCandidatesGatewayValidationError;
import '../../tool/advisor_proxy/proxy_bootstrap.dart'
    show RepositoryGraphCandidatesProxyGateway;

/// Stand-in for AuthEventsAuditRepository — the proxy gateway's
/// `_audit` helper just calls `auditRepository.insertSystemEvent`,
/// which we don't need to verify here because the route-level audit
/// fan-out is already covered by the gateway's existing tests. We
/// inject a fake repository that no-ops the call so the test does
/// not try to hit any auth tables.
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';

void main() {
  Future<Directory> stageCandidates({
    required Directory repoRoot,
    required List<Map<String, Object?>> nodes,
    required List<Map<String, Object?>> edges,
    Map<String, Object?>? manifest,
  }) async {
    final candidatesDir = Directory(
      '${repoRoot.path}/graphify-out/candidates',
    );
    candidatesDir.createSync(recursive: true);
    final manifestFile =
        File('${candidatesDir.path}/graphify_candidate_manifest.json');
    await manifestFile.writeAsString(jsonEncode(manifest ??
        <String, Object?>{
          'graph_scope': 'methodology',
          'graph_version': '1',
          'graphify_version': 'v5',
          'graphify_source_commit': 'fixture-commit',
        }));
    final nodesFile =
        File('${candidatesDir.path}/graphify_node_candidates.jsonl');
    final nodeBuf = StringBuffer();
    for (final n in nodes) {
      nodeBuf.writeln(jsonEncode(n));
    }
    await nodesFile.writeAsString(nodeBuf.toString());
    final edgesFile =
        File('${candidatesDir.path}/graphify_edge_candidates.jsonl');
    final edgeBuf = StringBuffer();
    for (final e in edges) {
      edgeBuf.writeln(jsonEncode(e));
    }
    await edgesFile.writeAsString(edgeBuf.toString());
    return candidatesDir;
  }

  /// Copies the project's real `corpus_manifest.yaml` into [repoRoot]
  /// at the path the gateway's `_loadManifestScopeForFilter()` looks
  /// for. Using the real manifest avoids YAML-parser bugs in
  /// hand-rolled fixtures (`CorpusManifest.load` requires every
  /// document field to validate). The included document set is
  /// whatever the project ships.
  void copyProjectManifest({required Directory repoRoot}) {
    final source = File(
      'docs/Knowledge_graph_docs/corpus_manifest.yaml',
    );
    if (!source.existsSync()) {
      throw StateError(
        'docs/Knowledge_graph_docs/corpus_manifest.yaml is missing — '
        'the test relies on the real project manifest as a parseable '
        'fixture; this file should exist in the repo root the test '
        'runs from',
      );
    }
    final manifestDir =
        Directory('${repoRoot.path}/docs/Knowledge_graph_docs');
    manifestDir.createSync(recursive: true);
    File('${manifestDir.path}/corpus_manifest.yaml').writeAsStringSync(
      source.readAsStringSync(),
    );
  }

  test(
    'idempotency-key replay returns cached result without re-running '
    'GraphRepository.commitBatch (P1 review finding)',
    () async {
      final tempRoot = Directory.systemTemp.createTempSync(
        'ff_11A_3b_proxy_dedup_',
      );
      try {
        // The manifest is now fail-closed (a missing manifest
        // would short-circuit the commit with a typed 503), so we
        // must stage the project's real manifest first. The
        // candidate's `source_file` must reference an in-scope
        // path (one listed in the manifest) — pick the first
        // included document.
        copyProjectManifest(repoRoot: tempRoot);
        await stageCandidates(
          repoRoot: tempRoot,
          nodes: const <Map<String, Object?>>[
            <String, Object?>{
              'candidate_id': 'node:graphify:approve_me',
              'kind': 'node',
              'candidate_key': 'graphify:approve_me',
              'candidate_type': 'Concept',
              'label': 'EXTRACTED',
              'confidence_score': 0.95,
              // In-scope: the project manifest lists this exact
              // source_path under `documents`. The dedup behaviour
              // we're testing fires after the scope check passes.
              'source_file':
                  'docs/Knowledge_graph_docs/Barrio_company_handbook.md',
              'payload': <String, Object?>{'label': 'A'},
            },
          ],
          edges: const <Map<String, Object?>>[],
        );

        final pool = _CountingPool(
          rowsByContains: <String, List<PostgresRow>>{
            'select node_key, id::text as id': const <PostgresRow>[],
            'insert into public.graph_nodes': <PostgresRow>[
              <String, Object?>{'id': '00000000-0000-4000-9000-aaaaaaaaaaaa'},
            ],
            'insert into public.audit_logs': <PostgresRow>[
              <String, Object?>{'id': '00000000-0000-4000-9000-eeeeeeeeeeee'},
            ],
          },
        );
        final repo = GraphRepository(TenantTransactionWrapper(pool));
        final gateway = RepositoryGraphCandidatesProxyGateway(
          graphRepository: repo,
          auditRepository: const _NoopAuthEventsAuditRepository(),
          repoRoot: tempRoot,
        );

        final firstCall = await gateway.commitBatch(
          actorUserId: _userA,
          operatorId: _opA,
          locationId: _locA,
          decisions: const <Map<String, Object?>>[
            <String, Object?>{
              'candidate_id': 'node:graphify:approve_me',
              'kind': 'approve',
            },
          ],
          idempotencyKey: 'replay-test-key',
          adminReason: 'admin.corpus.graph_candidates.commit_batch:'
              'replay-test',
        );
        expect(firstCall['approved_node_count'], equals(1));
        // First call opened a transaction.
        expect(pool.transactions, hasLength(1));

        // Replay: same key, same decisions → cached result, NO new
        // transaction, NO new INSERTs.
        final secondCall = await gateway.commitBatch(
          actorUserId: _userA,
          operatorId: _opA,
          locationId: _locA,
          decisions: const <Map<String, Object?>>[
            <String, Object?>{
              'candidate_id': 'node:graphify:approve_me',
              'kind': 'approve',
            },
          ],
          idempotencyKey: 'replay-test-key',
          adminReason: 'admin.corpus.graph_candidates.commit_batch:'
              'replay-test',
        );
        expect(secondCall, equals(firstCall));
        expect(
          pool.transactions,
          hasLength(1),
          reason: 'replay must NOT open a second transaction; the '
              'gateway returns the cached result built from the '
              'first call. Without this, a retry would double-write '
              'the audit row and trip canonical UNIQUE on retry, '
              'surfacing as a 503 to the operator.',
        );
      } finally {
        tempRoot.deleteSync(recursive: true);
      }
    },
  );

  test(
    'manifest filter on resolved candidates rejects out-of-scope source '
    'before opening a transaction (P2 review finding)',
    () async {
      final tempRoot = Directory.systemTemp.createTempSync(
        'ff_11A_3b_resolved_scope_',
      );
      try {
        // Manifest scope: copy the project's real manifest so the
        // YAML parses; then point the stale candidate at a file
        // path that is GUARANTEED not to be in the manifest's
        // included set (any garbage path that doesn't match a real
        // F&F corpus document).
        copyProjectManifest(repoRoot: tempRoot);
        // JSONL carries one stale out-of-scope candidate (e.g. the
        // importer ran against an older manifest that included
        // `corpus/__stale_out_of_scope__.md`). The gateway must
        // reject any commit-batch that references the stale
        // candidate, even though the wire decision only carries
        // `candidate_id`.
        await stageCandidates(
          repoRoot: tempRoot,
          nodes: const <Map<String, Object?>>[
            <String, Object?>{
              'candidate_id': 'node:graphify:stale_node',
              'kind': 'node',
              'candidate_key': 'graphify:stale_node',
              'candidate_type': 'Concept',
              'label': 'EXTRACTED',
              'confidence_score': 0.95,
              // Garbage path — MUST NOT collide with any real F&F
              // manifest document or the test's premise breaks.
              'source_file': 'corpus/__stale_out_of_scope__.md',
              'payload': <String, Object?>{'label': 'stale'},
            },
          ],
          edges: const <Map<String, Object?>>[],
        );

        final pool = _CountingPool(
          rowsByContains: <String, List<PostgresRow>>{},
        );
        final repo = GraphRepository(TenantTransactionWrapper(pool));
        final gateway = RepositoryGraphCandidatesProxyGateway(
          graphRepository: repo,
          auditRepository: const _NoopAuthEventsAuditRepository(),
          repoRoot: tempRoot,
        );

        // Decision references the stale candidate — this is the
        // exact attack surface the P2 finding flagged: a stale
        // JSONL entry carrying an out-of-scope source_file passes
        // the route-level filter (which only sees
        // edited_payload.source_file on edits) and would otherwise
        // reach GraphRepository.commitBatch unchecked.
        await expectLater(
          () => gateway.commitBatch(
            actorUserId: _userA,
            operatorId: _opA,
            locationId: _locA,
            decisions: const <Map<String, Object?>>[
              <String, Object?>{
                'candidate_id': 'node:graphify:stale_node',
                'kind': 'approve',
              },
            ],
            idempotencyKey: 'scope-test-key',
            adminReason:
                'admin.corpus.graph_candidates.commit_batch:scope-test',
          ),
          throwsA(
            isA<GraphCandidatesGatewayValidationError>()
                .having((e) => e.statusCode, 'statusCode', 403)
                .having((e) => e.code, 'code', 'source_out_of_scope'),
          ),
        );

        // No transaction opened — the rejection happens before any
        // database work.
        expect(
          pool.transactions,
          isEmpty,
          reason: 'manifest scope rejection must abort before opening '
              'a transaction so a stale JSONL cannot leak even one '
              'half-applied row',
        );
      } finally {
        tempRoot.deleteSync(recursive: true);
      }
    },
  );

  test(
    'manifest scope check fails CLOSED when the manifest is missing — '
    '503 manifest_unavailable, never silently allow decisions through '
    '(P2 follow-up)',
    () async {
      // Earlier behaviour was fail-OPEN: a missing manifest returned
      // an empty scope set and the commit path skipped source
      // validation. That defeated the defense-in-depth contract for
      // stale JSONL — a missing manifest meant the safety net was
      // gone, but commits proceeded unchecked. This test pins the
      // new fail-closed behaviour: no manifest → 503, no
      // transaction, nothing reaches the repository.
      final tempRoot = Directory.systemTemp.createTempSync(
        'ff_11A_3b_fail_closed_',
      );
      try {
        // No manifest staged — directory exists but
        // docs/Knowledge_graph_docs/corpus_manifest.yaml is absent.
        await stageCandidates(
          repoRoot: tempRoot,
          nodes: const <Map<String, Object?>>[
            <String, Object?>{
              'candidate_id': 'node:graphify:any',
              'kind': 'node',
              'candidate_key': 'graphify:any',
              'candidate_type': 'Concept',
              'label': 'EXTRACTED',
              'confidence_score': 0.95,
              'source_file': 'corpus/anything.md',
              'payload': <String, Object?>{'label': 'A'},
            },
          ],
          edges: const <Map<String, Object?>>[],
        );

        final pool = _CountingPool(
          rowsByContains: <String, List<PostgresRow>>{},
        );
        final repo = GraphRepository(TenantTransactionWrapper(pool));
        final gateway = RepositoryGraphCandidatesProxyGateway(
          graphRepository: repo,
          auditRepository: const _NoopAuthEventsAuditRepository(),
          repoRoot: tempRoot,
        );

        await expectLater(
          () => gateway.commitBatch(
            actorUserId: _userA,
            operatorId: _opA,
            locationId: _locA,
            decisions: const <Map<String, Object?>>[
              <String, Object?>{
                'candidate_id': 'node:graphify:any',
                'kind': 'approve',
              },
            ],
            idempotencyKey: 'fail-closed-key',
            adminReason:
                'admin.corpus.graph_candidates.commit_batch:fail-closed',
          ),
          throwsA(
            isA<GraphCandidatesGatewayValidationError>()
                .having((e) => e.statusCode, 'statusCode', 503)
                .having((e) => e.code, 'code', 'manifest_unavailable'),
          ),
        );

        expect(
          pool.transactions,
          isEmpty,
          reason: 'fail-closed must abort BEFORE any transaction '
              'opens so an unloadable manifest cannot leak even '
              'one decision through unchecked',
        );
      } finally {
        tempRoot.deleteSync(recursive: true);
      }
    },
  );

  test(
    'server-side AMBIGUOUS guard rejects kind=approve on resolved '
    'AMBIGUOUS candidate (P2 follow-up — UI guard alone is '
    'insufficient against direct or stale HTTP requests)',
    () async {
      // The screen hides Approve on AMBIGUOUS rows and
      // _toggleApprove() guards the path. But the production
      // gateway still has to refuse `kind: approve` on a resolved
      // AMBIGUOUS candidate, otherwise a direct or stale HTTP
      // request can bypass the widget and route an unedited
      // ambiguous relationship into canonical storage. Spec line
      // 249: AMBIGUOUS = debug-only until edited.
      final tempRoot = Directory.systemTemp.createTempSync(
        'ff_11A_3b_ambiguous_guard_',
      );
      try {
        copyProjectManifest(repoRoot: tempRoot);
        await stageCandidates(
          repoRoot: tempRoot,
          nodes: const <Map<String, Object?>>[],
          edges: const <Map<String, Object?>>[
            <String, Object?>{
              'candidate_id': 'edge:graphify:ambiguous_edge',
              'kind': 'edge',
              'candidate_key': 'graphify:ambiguous_edge',
              'candidate_type': 'RELATES_TO',
              // Resolved AMBIGUOUS — the producer flagged this
              // edge as needing operator interpretation.
              'label': 'AMBIGUOUS',
              'confidence_score': 0.41,
              'source_file':
                  'docs/Knowledge_graph_docs/Barrio_company_handbook.md',
              'from_node_key': 'graphify:a',
              'to_node_key': 'graphify:b',
              'payload': <String, Object?>{'label': 'a NEAR b'},
            },
          ],
        );

        final pool = _CountingPool(
          rowsByContains: <String, List<PostgresRow>>{},
        );
        final repo = GraphRepository(TenantTransactionWrapper(pool));
        final gateway = RepositoryGraphCandidatesProxyGateway(
          graphRepository: repo,
          auditRepository: const _NoopAuthEventsAuditRepository(),
          repoRoot: tempRoot,
        );

        await expectLater(
          () => gateway.commitBatch(
            actorUserId: _userA,
            operatorId: _opA,
            locationId: _locA,
            decisions: const <Map<String, Object?>>[
              <String, Object?>{
                'candidate_id': 'edge:graphify:ambiguous_edge',
                // BARE approve — the attack surface this guard
                // closes. Edit-then-approve (kind: 'edit' with
                // edited_payload + edited_candidate_type) is the
                // only valid path for AMBIGUOUS candidates.
                'kind': 'approve',
              },
            ],
            idempotencyKey: 'ambiguous-key',
            adminReason: 'admin.corpus.graph_candidates.commit_batch:'
                'ambiguous-test',
          ),
          throwsA(
            isA<GraphCandidatesGatewayValidationError>()
                .having((e) => e.statusCode, 'statusCode', 400)
                .having((e) => e.code, 'code', 'ambiguous_requires_edit'),
          ),
        );

        expect(
          pool.transactions,
          isEmpty,
          reason: 'AMBIGUOUS approve rejection must abort before '
              'opening a transaction; a half-applied write here '
              'would defeat the spec contract that AMBIGUOUS is '
              'debug-only until edited',
        );
      } finally {
        tempRoot.deleteSync(recursive: true);
      }
    },
  );

  test(
    'concurrent commitBatch calls with the same idempotency-key share '
    'one transaction (in-flight Future is cached BEFORE awaits, so '
    'two overlapping retries cannot both stamp duplicate audit rows '
    'or trip canonical UNIQUE)',
    () async {
      // P1 follow-up: the previous shape cached the resolved
      // result AFTER the work completed, so two concurrent
      // requests both observed `cached == null` and both opened
      // write transactions. The fix reserves the in-flight Future
      // synchronously before any await so the second arrival sees
      // the same Future and awaits it instead of starting a
      // second transaction.
      final tempRoot = Directory.systemTemp.createTempSync(
        'ff_11A_3b_concurrent_dedup_',
      );
      try {
        copyProjectManifest(repoRoot: tempRoot);
        await stageCandidates(
          repoRoot: tempRoot,
          nodes: const <Map<String, Object?>>[
            <String, Object?>{
              'candidate_id': 'node:graphify:concurrent_node',
              'kind': 'node',
              'candidate_key': 'graphify:concurrent_node',
              'candidate_type': 'Concept',
              'label': 'EXTRACTED',
              'confidence_score': 0.95,
              'source_file':
                  'docs/Knowledge_graph_docs/Barrio_company_handbook.md',
              'payload': <String, Object?>{'label': 'concurrent A'},
            },
          ],
          edges: const <Map<String, Object?>>[],
        );

        final pool = _CountingPool(
          rowsByContains: <String, List<PostgresRow>>{
            'select node_key, id::text as id': const <PostgresRow>[],
            'insert into public.graph_nodes': <PostgresRow>[
              <String, Object?>{
                'id': '00000000-0000-4000-9000-aaaaaaaaaaaa',
              },
            ],
            'insert into public.audit_logs': <PostgresRow>[
              <String, Object?>{
                'id': '00000000-0000-4000-9000-eeeeeeeeeeee',
              },
            ],
          },
        );
        final repo = GraphRepository(TenantTransactionWrapper(pool));
        final gateway = RepositoryGraphCandidatesProxyGateway(
          graphRepository: repo,
          auditRepository: const _NoopAuthEventsAuditRepository(),
          repoRoot: tempRoot,
        );

        // Fire BOTH requests with the same key without awaiting
        // either. The synchronous prefix of the first call must
        // insert the in-flight Future before the second call's
        // synchronous prefix runs; otherwise both observe a cache
        // miss and both open a transaction.
        final futureA = gateway.commitBatch(
          actorUserId: _userA,
          operatorId: _opA,
          locationId: _locA,
          decisions: const <Map<String, Object?>>[
            <String, Object?>{
              'candidate_id': 'node:graphify:concurrent_node',
              'kind': 'approve',
            },
          ],
          idempotencyKey: 'concurrent-key',
          adminReason: 'admin.corpus.graph_candidates.commit_batch:cc-A',
        );
        final futureB = gateway.commitBatch(
          actorUserId: _userA,
          operatorId: _opA,
          locationId: _locA,
          decisions: const <Map<String, Object?>>[
            <String, Object?>{
              'candidate_id': 'node:graphify:concurrent_node',
              'kind': 'approve',
            },
          ],
          idempotencyKey: 'concurrent-key',
          adminReason: 'admin.corpus.graph_candidates.commit_batch:cc-B',
        );

        final resultA = await futureA;
        final resultB = await futureB;
        // Both requests observe the same response.
        expect(resultA, equals(resultB));
        expect(
          pool.transactions,
          hasLength(1),
          reason: 'concurrent retries with the same key MUST share '
              'one transaction. Two transactions here would mean a '
              'real production retry could double-write the audit '
              'row and trip the canonical UNIQUE on the second '
              'INSERT — exactly the failure mode the fix prevents.',
        );
      } finally {
        tempRoot.deleteSync(recursive: true);
      }
    },
  );

  test(
    'commit-batch rejects a candidate with missing source_file '
    '(stale JSONL with null source must NOT bypass the manifest '
    'check)',
    () async {
      // P2 follow-up: the manifest check used to skip when
      // `candidateSourceFile == null`, so a tampered JSONL row
      // with no source could approve into canonical storage. The
      // fix rejects null/blank source upfront — approved
      // candidates MUST carry source provenance per spec line
      // 253-255, and the importer treats null source as
      // out-of-scope already, so the proxy mirrors that contract.
      final tempRoot = Directory.systemTemp.createTempSync(
        'ff_11A_3b_missing_source_',
      );
      try {
        copyProjectManifest(repoRoot: tempRoot);
        await stageCandidates(
          repoRoot: tempRoot,
          nodes: const <Map<String, Object?>>[
            <String, Object?>{
              'candidate_id': 'node:graphify:no_source',
              'kind': 'node',
              'candidate_key': 'graphify:no_source',
              'candidate_type': 'Concept',
              'label': 'EXTRACTED',
              'confidence_score': 0.95,
              // Tampered: no source_file at all. Earlier the
              // manifest check would skip this entirely.
              'payload': <String, Object?>{'label': 'no source'},
            },
          ],
          edges: const <Map<String, Object?>>[],
        );

        final pool = _CountingPool(
          rowsByContains: <String, List<PostgresRow>>{},
        );
        final repo = GraphRepository(TenantTransactionWrapper(pool));
        final gateway = RepositoryGraphCandidatesProxyGateway(
          graphRepository: repo,
          auditRepository: const _NoopAuthEventsAuditRepository(),
          repoRoot: tempRoot,
        );

        await expectLater(
          () => gateway.commitBatch(
            actorUserId: _userA,
            operatorId: _opA,
            locationId: _locA,
            decisions: const <Map<String, Object?>>[
              <String, Object?>{
                'candidate_id': 'node:graphify:no_source',
                'kind': 'approve',
              },
            ],
            idempotencyKey: 'missing-source-key',
            adminReason: 'admin.corpus.graph_candidates.commit_batch:'
                'missing-source',
          ),
          throwsA(
            isA<GraphCandidatesGatewayValidationError>()
                .having((e) => e.statusCode, 'statusCode', 403)
                .having((e) => e.code, 'code', 'source_out_of_scope'),
          ),
        );
        expect(
          pool.transactions,
          isEmpty,
          reason: 'a candidate without source_file must abort '
              'before any transaction; otherwise it could land in '
              'canonical storage with no provenance, violating the '
              'spec contract that approved candidates record '
              'source documents (lines 253-255)',
        );
      } finally {
        tempRoot.deleteSync(recursive: true);
      }
    },
  );

  test(
    'listGraphCandidates drops out-of-scope candidates from the diff '
    '(spec line 195-196: Graphify output for files outside the '
    'manifest is ignored)',
    () async {
      // P3 follow-up: the diff was bucketing every JSONL entry
      // without re-applying the manifest scope filter. An
      // operator could see and queue a stale out-of-scope row,
      // only to fail at commit time. The fix applies the same
      // fail-closed scope filter at list time so invalid rows
      // never render.
      final tempRoot = Directory.systemTemp.createTempSync(
        'ff_11A_3b_list_scope_',
      );
      try {
        copyProjectManifest(repoRoot: tempRoot);
        await stageCandidates(
          repoRoot: tempRoot,
          nodes: const <Map<String, Object?>>[
            <String, Object?>{
              'candidate_id': 'node:graphify:in_scope',
              'kind': 'node',
              'candidate_key': 'graphify:in_scope',
              'candidate_type': 'Concept',
              'label': 'EXTRACTED',
              'confidence_score': 0.95,
              'source_file':
                  'docs/Knowledge_graph_docs/Barrio_company_handbook.md',
              'payload': <String, Object?>{'label': 'in scope'},
            },
            <String, Object?>{
              'candidate_id': 'node:graphify:out_of_scope',
              'kind': 'node',
              'candidate_key': 'graphify:out_of_scope',
              'candidate_type': 'Concept',
              'label': 'EXTRACTED',
              'confidence_score': 0.95,
              // Stale JSONL: source path not in the project
              // manifest. The diff must drop this silently.
              'source_file': 'corpus/__stale_out_of_scope__.md',
              'payload': <String, Object?>{'label': 'stale'},
            },
            <String, Object?>{
              'candidate_id': 'node:graphify:no_source',
              'kind': 'node',
              'candidate_key': 'graphify:no_source',
              'candidate_type': 'Concept',
              'label': 'EXTRACTED',
              'confidence_score': 0.95,
              // Tampered: missing source_file. Also dropped.
              'payload': <String, Object?>{'label': 'no source'},
            },
          ],
          edges: const <Map<String, Object?>>[],
        );

        final pool = _CountingPool(
          rowsByContains: <String, List<PostgresRow>>{},
        );
        final repo = GraphRepository(TenantTransactionWrapper(pool));
        final gateway = RepositoryGraphCandidatesProxyGateway(
          graphRepository: repo,
          auditRepository: const _NoopAuthEventsAuditRepository(),
          repoRoot: tempRoot,
        );

        final response = await gateway.listGraphCandidates(
          actorUserId: _userA,
          adminReason: 'admin.corpus.graph_candidates.list:scope-drop',
        );

        final extracted = (response['extracted'] as List<Object?>)
            .cast<Map<String, Object?>>();
        final inferred = (response['inferred'] as List<Object?>)
            .cast<Map<String, Object?>>();
        final ambiguous = (response['ambiguous'] as List<Object?>)
            .cast<Map<String, Object?>>();
        // Only the in-scope candidate survives.
        expect(extracted, hasLength(1));
        expect(extracted.single['candidate_id'],
            equals('node:graphify:in_scope'));
        expect(inferred, isEmpty);
        expect(ambiguous, isEmpty);
        // Stale + missing-source rows are silently dropped.
        final keys = <String>[
          for (final c in extracted) c['candidate_id']! as String,
          for (final c in inferred) c['candidate_id']! as String,
          for (final c in ambiguous) c['candidate_id']! as String,
        ];
        expect(keys, isNot(contains('node:graphify:out_of_scope')));
        expect(keys, isNot(contains('node:graphify:no_source')));
      } finally {
        tempRoot.deleteSync(recursive: true);
      }
    },
  );

  test(
    'listGraphCandidates fails CLOSED when the manifest is missing '
    '(503 manifest_unavailable, never render the diff with no scope '
    'filter applied)',
    () async {
      // P3 follow-up: the diff endpoint must mirror the commit
      // path's fail-closed behaviour. Without the manifest the
      // operator could see (and try to queue) candidates that
      // commit-batch will then reject — confusing UX. Cleaner to
      // surface the misconfiguration as a typed 503 at list time
      // so the operator fixes the manifest first.
      final tempRoot = Directory.systemTemp.createTempSync(
        'ff_11A_3b_list_fail_closed_',
      );
      try {
        // No manifest staged.
        await stageCandidates(
          repoRoot: tempRoot,
          nodes: const <Map<String, Object?>>[
            <String, Object?>{
              'candidate_id': 'node:graphify:any',
              'kind': 'node',
              'candidate_key': 'graphify:any',
              'candidate_type': 'Concept',
              'label': 'EXTRACTED',
              'confidence_score': 0.95,
              'source_file': 'corpus/anything.md',
              'payload': <String, Object?>{'label': 'A'},
            },
          ],
          edges: const <Map<String, Object?>>[],
        );

        final pool = _CountingPool(
          rowsByContains: <String, List<PostgresRow>>{},
        );
        final repo = GraphRepository(TenantTransactionWrapper(pool));
        final gateway = RepositoryGraphCandidatesProxyGateway(
          graphRepository: repo,
          auditRepository: const _NoopAuthEventsAuditRepository(),
          repoRoot: tempRoot,
        );

        await expectLater(
          () => gateway.listGraphCandidates(
            actorUserId: _userA,
            adminReason: 'admin.corpus.graph_candidates.list:'
                'fail-closed-list',
          ),
          throwsA(
            isA<GraphCandidatesGatewayValidationError>()
                .having((e) => e.statusCode, 'statusCode', 503)
                .having((e) => e.code, 'code', 'manifest_unavailable'),
          ),
        );
      } finally {
        tempRoot.deleteSync(recursive: true);
      }
    },
  );

  test(
    'audit failure AFTER graph commit does not clear idempotency '
    'cache; retry returns cached success without re-running graph '
    'writes (P1 follow-up)',
    () async {
      // The previous shape cleared the idempotency cache on every
      // error. If `_audit(...)` failed AFTER `_graph.commitBatch`
      // had committed canonical rows, a retry with the same key
      // would re-run the graph commit and trip the canonical
      // UNIQUE on (operator_id, graph_scope, graph_version,
      // node_key) for the rows just written, surfacing as a 503
      // for an operation that actually succeeded.
      //
      // The fix treats the auth_events_audit write as
      // best-effort: a failure is logged to stderr but the
      // success response is returned anyway and the cache stays
      // populated. The graph_repository.dart audit fan-out into
      // public.audit_logs ran inside the same tenant transaction
      // as the graph writes, so the hash-chained system audit
      // trail is intact.
      final tempRoot = Directory.systemTemp.createTempSync(
        'ff_11A_3b_audit_failure_',
      );
      try {
        copyProjectManifest(repoRoot: tempRoot);
        await stageCandidates(
          repoRoot: tempRoot,
          nodes: const <Map<String, Object?>>[
            <String, Object?>{
              'candidate_id': 'node:graphify:audit_fail_node',
              'kind': 'node',
              'candidate_key': 'graphify:audit_fail_node',
              'candidate_type': 'Concept',
              'label': 'EXTRACTED',
              'confidence_score': 0.95,
              'source_file':
                  'docs/Knowledge_graph_docs/Barrio_company_handbook.md',
              'payload': <String, Object?>{'label': 'audit-fail A'},
            },
          ],
          edges: const <Map<String, Object?>>[],
        );

        final pool = _CountingPool(
          rowsByContains: <String, List<PostgresRow>>{
            'select node_key, id::text as id': const <PostgresRow>[],
            'insert into public.graph_nodes': <PostgresRow>[
              <String, Object?>{
                'id': '00000000-0000-4000-9000-aaaaaaaaaaaa',
              },
            ],
            'insert into public.audit_logs': <PostgresRow>[
              <String, Object?>{
                'id': '00000000-0000-4000-9000-eeeeeeeeeeee',
              },
            ],
          },
        );
        final repo = GraphRepository(TenantTransactionWrapper(pool));
        final auditRepo = _ThrowingAuthEventsAuditRepository();
        final gateway = RepositoryGraphCandidatesProxyGateway(
          graphRepository: repo,
          auditRepository: auditRepo,
          repoRoot: tempRoot,
        );

        // First call: graph commit succeeds, audit insert
        // throws. The gateway swallows the audit error and
        // returns the success response.
        final firstResponse = await gateway.commitBatch(
          actorUserId: _userA,
          operatorId: _opA,
          locationId: _locA,
          decisions: const <Map<String, Object?>>[
            <String, Object?>{
              'candidate_id': 'node:graphify:audit_fail_node',
              'kind': 'approve',
            },
          ],
          idempotencyKey: 'audit-fail-key',
          adminReason:
              'admin.corpus.graph_candidates.commit_batch:audit-fail',
        );
        // Operator sees success despite audit failure.
        expect(firstResponse['approved_node_count'], equals(1));
        // Audit was attempted (and threw).
        expect(auditRepo.callCount, equals(1));
        // Graph commit landed exactly one transaction.
        expect(pool.transactions, hasLength(1));

        // Retry with the same key: must return the cached success
        // and MUST NOT re-run _graph.commitBatch (which would
        // trip the canonical UNIQUE for the rows just written).
        final retryResponse = await gateway.commitBatch(
          actorUserId: _userA,
          operatorId: _opA,
          locationId: _locA,
          decisions: const <Map<String, Object?>>[
            <String, Object?>{
              'candidate_id': 'node:graphify:audit_fail_node',
              'kind': 'approve',
            },
          ],
          idempotencyKey: 'audit-fail-key',
          adminReason:
              'admin.corpus.graph_candidates.commit_batch:audit-fail-retry',
        );
        expect(retryResponse, equals(firstResponse));
        expect(
          pool.transactions,
          hasLength(1),
          reason: 'retry after a post-graph-commit audit failure '
              'MUST return the cached success — re-running '
              '_graph.commitBatch would re-insert the same '
              '(node_key) row and trip the canonical UNIQUE, '
              'surfacing as a 503 for an operation that already '
              'succeeded',
        );
      } finally {
        tempRoot.deleteSync(recursive: true);
      }
    },
  );
}

/// Audit repo that throws on the first call. Mimics a transient
/// auth_events_audit insert failure (e.g. a connection blip)
/// AFTER the graph commit has already landed canonical rows.
class _ThrowingAuthEventsAuditRepository
    implements AuthEventsAuditRepository {
  int callCount = 0;

  @override
  Future<String> insertSystemEvent({
    required String eventType,
    required String actorKind,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    required String adminReason,
  }) async {
    callCount += 1;
    throw StateError(
      'simulated auth_events_audit insert failure '
      '(transient connection blip after graph commit)',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

/// Stand-in audit repo that does nothing. The proxy gateway calls
/// `insertSystemEvent` for the route-level audit — irrelevant to
/// the dedup / scope contract under test.
///
/// We avoid `noSuchMethod` because `insertSystemEvent` returns
/// `Future<String>` (the audit row id) and a generic `Future<void>`
/// from noSuchMethod fails the type cast at the await site. Implement
/// the one method the gateway actually calls; everything else routes
/// through noSuchMethod for type-erased convenience.
class _NoopAuthEventsAuditRepository implements AuthEventsAuditRepository {
  const _NoopAuthEventsAuditRepository();

  @override
  Future<String> insertSystemEvent({
    required String eventType,
    required String actorKind,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    required String adminReason,
  }) async =>
      'fake-audit-id';

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _CountingPool implements PostgresPool {
  _CountingPool({required this.rowsByContains});

  final Map<String, List<PostgresRow>> rowsByContains;
  final List<_CountingTx> transactions = <_CountingTx>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _CountingTx(rowsByContains: rowsByContains);
    transactions.add(tx);
    return tx;
  }
}

class _CountingTx extends PostgresTransaction {
  _CountingTx({required this.rowsByContains});

  final Map<String, List<PostgresRow>> rowsByContains;
  final List<_RecordedSql> executed = <_RecordedSql>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executed.add(_RecordedSql(sql: sql, parameters: parameters));
    for (final entry in rowsByContains.entries) {
      if (sql.contains(entry.key)) return entry.value;
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executed.add(_RecordedSql(sql: sql, parameters: parameters));
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}

class _RecordedSql {
  _RecordedSql({required this.sql, required this.parameters});
  final String sql;
  final PostgresParameters parameters;
}
