// Phase 9.0Σ.i — canonical graph_nodes / graph_edges tests.
//
// Local framework slice (no live database). Three groups:
//
//   1. Migration shape — proves
//      `db/migrations/202604280008_phase_9_0sigma_i_graph_canonical.sql`
//      creates the canonical tables with operator-scoped columns,
//      composite same-operator FKs (location + edge endpoints), the
//      tenant-leading B-tree indexes, the active-row partial indexes,
//      RLS via `public.app_current_operator()`, the tripwire surface
//      `public.graph_health_metrics()` with Q19 yellow 3M / red 4M
//      thresholds, and grants to service_role + forge_admin.
//
//   2. RLS lint — runs the existing `RlsPolicyLintRunner` against the
//      new migration so a regression that swaps the wrapper for bare
//      `current_setting()` would be caught here as well as in the
//      global lint sweep.
//
//   3. Graph projection rebuild artifact — drives
//      `GraphProjectionRebuildPreparer` against a temp output
//      directory and asserts deterministic file output, the
//      AGE_BLOCKER path, the canonical-only input contract, and the
//      drop+rebuild AGE projection shape.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/graph_projection/graph_projection.dart';
import '../tool/rls_policy_lint.dart';

void main() {
  final migrationFile = File(
    'db/migrations/202604280008_phase_9_0sigma_i_graph_canonical.sql',
  );

  group('Phase 9.0Σ.i migration shape', () {
    setUpAll(() {
      expect(
        migrationFile.existsSync(),
        isTrue,
        reason: 'Phase 9.0Σ.i migration file must exist alongside the '
            'other 9.0Σ slot migrations',
      );
    });

    String migration() => _readSqlNormalized(migrationFile.path);

    test('runs in a single transaction (begin/commit pair)', () {
      final sql = migration();
      expect(sql, contains('begin;'));
      expect(sql, contains('commit;'));
    });

    test('creates graph_nodes with the canonical column shape', () {
      final sql = migration();
      expect(sql, contains('create table if not exists public.graph_nodes'));
      expect(sql, contains('id uuid primary key default gen_random_uuid()'));
      expect(
        sql,
        contains('operator_id uuid not null references public.operators'),
      );
      expect(sql, contains('location_id uuid null'));
      expect(sql, contains('graph_scope text not null'));
      expect(sql, contains('graph_version text not null'));
      expect(sql, contains('node_key text not null'));
      expect(sql, contains('node_type text not null'));
      // Confidence is a 0..1 numeric per the slice contract.
      expect(
        sql,
        contains(
          'check (confidence is null or '
          '(confidence >= 0.0 and confidence <= 1.0))',
        ),
      );
      expect(sql, contains('source text null'));
      expect(sql, contains('source_ref text null'));
      expect(sql, contains("properties jsonb not null default '{}'::jsonb"));
      expect(sql, contains("check (jsonb_typeof(properties) = 'object')"));
      // Lifecycle markers + audit timestamps.
      expect(sql, contains('active_from timestamptz not null default now()'));
      expect(sql, contains('active_to timestamptz null'));
      expect(sql, contains('deleted_at timestamptz null'));
      expect(sql, contains('archived_at timestamptz null'));
      expect(sql, contains('created_at timestamptz not null default now()'));
      expect(sql, contains('updated_at timestamptz not null default now()'));
    });

    test('creates graph_edges with the canonical column shape', () {
      final sql = migration();
      expect(sql, contains('create table if not exists public.graph_edges'));
      expect(sql, contains('id uuid primary key default gen_random_uuid()'));
      expect(sql, contains('edge_key text not null'));
      expect(sql, contains('edge_type text not null'));
      expect(sql, contains('from_node_id uuid not null'));
      expect(sql, contains('to_node_id uuid not null'));
      expect(sql, contains("check (jsonb_typeof(properties) = 'object')"));
      expect(sql, contains('active_from timestamptz not null default now()'));
      expect(sql, contains('active_to timestamptz null'));
      expect(sql, contains('deleted_at timestamptz null'));
      expect(sql, contains('archived_at timestamptz null'));
    });

    test('graph_nodes carries the (operator, scope, version, id) composite '
        'uniqueness target the edge FKs depend on', () {
      final sql = migration();
      expect(
        sql,
        contains('unique (operator_id, graph_scope, graph_version, id)'),
      );
      expect(
        sql,
        contains('unique (operator_id, graph_scope, graph_version, node_key)'),
      );
    });

    test('graph_edges endpoint FKs reference graph_nodes within the same '
        '(operator_id, graph_scope, graph_version) tuple — cross-tenant '
        'or cross-version edges are DB errors', () {
      final sql = migration();
      // From-endpoint composite FK.
      expect(
        sql,
        contains('constraint graph_edges_from_node_same_scope_fk'),
      );
      expect(
        sql,
        contains(
          'foreign key (operator_id, graph_scope, graph_version, '
          'from_node_id)\n'
          '    references public.graph_nodes(operator_id, graph_scope, '
          'graph_version, id)',
        ),
      );
      // To-endpoint composite FK.
      expect(
        sql,
        contains('constraint graph_edges_to_node_same_scope_fk'),
      );
      expect(
        sql,
        contains(
          'foreign key (operator_id, graph_scope, graph_version, '
          'to_node_id)\n'
          '    references public.graph_nodes(operator_id, graph_scope, '
          'graph_version, id)',
        ),
      );
    });

    test('location_id FK pins to the same operator on both tables '
        '(cross-operator location pointers forbidden)', () {
      final sql = migration();
      expect(
        sql,
        contains('constraint graph_nodes_location_same_operator_fk'),
      );
      expect(
        sql,
        contains('constraint graph_edges_location_same_operator_fk'),
      );
      expect(
        sql,
        contains(
          'foreign key (operator_id, location_id)\n'
          '    references public.locations(operator_id, location_id)',
        ),
      );
    });

    test('location FK uses ON DELETE SET NULL — a location delete must NOT '
        'cascade-erase canonical graph history (Q19 non-destructive '
        'rollover)', () {
      // Both location FKs must use SET NULL on the location_id column.
      // The PG15+ column-list form preserves operator_id (NOT NULL) on
      // the same-operator-cascade path. CASCADE is forbidden — Q19
      // says soft-delete/archive is the path that pulls a location's
      // graph contribution out of the active projection; the actual
      // canonical row is retained for audit / re-projection of prior
      // graph_version generations.
      final sql = migration();

      // Both same-operator FK constraints must explicitly use
      // `set null (location_id)` — the migration currently has two
      // such occurrences, one per table.
      final setNullPattern = 'on delete set null (location_id)';
      expect(
        setNullPattern.allMatches(sql).length,
        greaterThanOrEqualTo(2),
        reason:
            'graph_nodes AND graph_edges location FKs must use ON DELETE '
            'SET NULL (location_id); cascade would erase canonical '
            'history when a location is deleted.',
      );

      // Defensive: neither location FK constraint may use cascade.
      // Look for the cascade keyword in the same statement as either
      // location FK constraint name.
      for (final fkName in <String>[
        'graph_nodes_location_same_operator_fk',
        'graph_edges_location_same_operator_fk',
      ]) {
        final fkStart = sql.indexOf('constraint $fkName');
        expect(
          fkStart,
          isNonNegative,
          reason: '$fkName must exist in the migration',
        );
        // Scan up to 400 chars after the constraint head — long enough
        // to cover the FK clause through ON DELETE.
        final fkBody = sql.substring(
          fkStart,
          (fkStart + 400).clamp(0, sql.length),
        );
        expect(
          fkBody,
          contains('on delete set null (location_id)'),
          reason: '$fkName must use SET NULL (location_id) so a '
              'location delete preserves canonical graph history',
        );
        expect(
          fkBody,
          isNot(contains('on delete cascade')),
          reason: '$fkName must NOT cascade — a location delete must '
              'never erase canonical graph rows',
        );
      }
    });

    test('every B-tree index leads with operator_id (RLS performance '
        'discipline)', () {
      final sql = migration();
      // graph_nodes lookup index — leads with operator_id.
      expect(
        sql,
        contains(
          'create index if not exists graph_nodes_operator_scope_type_idx\n'
          '  on public.graph_nodes (operator_id, graph_scope, '
          'graph_version, node_type)',
        ),
      );
      // Active-only partial index for the projection rebuild scan.
      expect(
        sql,
        contains(
          'create index if not exists graph_nodes_operator_active_idx\n'
          '  on public.graph_nodes (operator_id, graph_scope, graph_version)\n'
          '  where deleted_at is null and archived_at is null',
        ),
      );
      // Edge traversal indexes — both lead with operator_id.
      expect(
        sql,
        contains(
          'create index if not exists graph_edges_operator_from_node_idx',
        ),
      );
      expect(
        sql,
        contains(
          '    (operator_id, graph_scope, graph_version, from_node_id)',
        ),
      );
      expect(
        sql,
        contains(
          'create index if not exists graph_edges_operator_to_node_idx',
        ),
      );
      expect(
        sql,
        contains(
          '    (operator_id, graph_scope, graph_version, to_node_id)',
        ),
      );
      // Active-edge tripwire scan index.
      expect(
        sql,
        contains(
          'create index if not exists graph_edges_operator_active_idx\n'
          '  on public.graph_edges (operator_id, graph_scope, graph_version)\n'
          '  where deleted_at is null and archived_at is null',
        ),
      );
    });

    test('updated_at triggers reuse the cloud-foundation function', () {
      final sql = migration();
      expect(sql, contains('graph_nodes_set_updated_at'));
      expect(sql, contains('graph_edges_set_updated_at'));
      expect(
        sql,
        contains(
          'execute function public.cloud_foundation_set_updated_at()',
        ),
      );
    });

    test('RLS enabled and policies use app_current_operator() wrapper', () {
      final sql = migration();
      expect(
        sql,
        contains('alter table public.graph_nodes enable row level security'),
      );
      expect(
        sql,
        contains(
          'create policy "graph_nodes_per_tenant"\n'
          '  on public.graph_nodes for all to service_role\n'
          '  using (operator_id = public.app_current_operator())\n'
          '  with check (operator_id = public.app_current_operator())',
        ),
      );
      expect(
        sql,
        contains('alter table public.graph_edges enable row level security'),
      );
      expect(
        sql,
        contains(
          'create policy "graph_edges_per_tenant"\n'
          '  on public.graph_edges for all to service_role\n'
          '  using (operator_id = public.app_current_operator())\n'
          '  with check (operator_id = public.app_current_operator())',
        ),
      );
      // Bare current_setting reads must not appear in any policy
      // body — the lint group below double-checks the same assertion
      // but the literal guard surfaces a regression earlier.
      expect(
        sql,
        isNot(contains("current_setting('app.operator_id'")),
      );
    });

    test('table grants: full DML to service_role and forge_admin', () {
      final sql = migration();
      for (final table in <String>['graph_nodes', 'graph_edges']) {
        for (final role in <String>['service_role', 'forge_admin']) {
          expect(
            sql,
            contains(
              'grant select, insert, update, delete on public.$table to '
              '$role',
            ),
            reason: '$role needs DML on public.$table for runtime + admin '
                'paths',
          );
        }
      }
    });

    test('does not introduce timestamp without time zone (storage rule)', () {
      final sql = migration().toLowerCase();
      expect(sql, isNot(contains('timestamp without time zone')));
      // Regex guard catches any bare `timestamp ` not followed by
      // `with`. The file uses `timestamptz` exclusively per the
      // CLAUDE.md storage rule.
      expect(
        sql,
        isNot(matches(RegExp(r'\btimestamp\b(?!\s*with)'))),
      );
    });

    test('graph health/tripwire surface exposes Q19 yellow 3M / red 4M '
        'thresholds and counts active rows only', () {
      final sql = migration();
      expect(
        sql,
        contains('create or replace function public.graph_health_metrics()'),
      );
      // Per-(scope, version) result columns.
      expect(sql, contains('graph_scope text'));
      expect(sql, contains('graph_version text'));
      expect(sql, contains('active_node_count bigint'));
      expect(sql, contains('active_edge_count bigint'));
      expect(sql, contains('yellow_threshold_active_edges bigint'));
      expect(sql, contains('red_threshold_active_edges bigint'));
      expect(sql, contains('status text'));
      // Reserved metadata slots so the 11A panel shape is stable now.
      expect(sql, contains('last_projection_built_at timestamptz'));
      expect(sql, contains('last_benchmark_at timestamptz'));
      // Q19 thresholds — yellow 3M, red 4M.
      expect(sql, contains('3000000::bigint as yellow_threshold_active_edges'));
      expect(sql, contains('4000000::bigint as red_threshold_active_edges'));
      expect(sql, contains("when coalesce(e.cnt, 0) >= 4000000 then 'red'"));
      expect(sql, contains("when coalesce(e.cnt, 0) >= 3000000 then 'yellow'"));
      expect(sql, contains("else 'green'"));
      // Active row filter — soft-deleted / archived / future-staged /
      // expired all excluded. The `active_from <= now()` predicate is
      // load-bearing: without it, a row staged for a future activation
      // would be counted in graph_health_metrics and projected by the
      // rebuild before its activation date (the original P2.2 fix).
      expect(sql, contains('deleted_at is null'));
      expect(sql, contains('archived_at is null'));
      expect(sql, contains('active_from <= now()'));
      expect(sql, contains('active_to is null or active_to > now()'));
      // Grants so service_role + forge_admin can call the function.
      expect(
        sql,
        contains(
          'grant execute on function public.graph_health_metrics() to '
          'service_role',
        ),
      );
      expect(
        sql,
        contains(
          'grant execute on function public.graph_health_metrics() to '
          'forge_admin',
        ),
      );
    });
  });

  group('Phase 9.0Σ.i RLS lint', () {
    test('migration passes the policy-aware lint', () {
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202604280008_phase_9_0sigma_i_graph_canonical.sql':
              _readSqlNormalized(migrationFile.path),
        },
        allowlist: const <String>{},
      ).run();
      expect(
        result.isClean,
        isTrue,
        reason: 'graph_nodes / graph_edges policies must read GUCs through '
            'the 9.0Σ.b wrappers; violations: ${result.violations}',
      );
    });
  });

  group('GraphProjectionRebuildPreparer (B30 — generated artifacts only)', () {
    late Directory tempRepo;

    setUp(() {
      tempRepo = Directory.systemTemp.createTempSync('graph_projection_test_');
    });

    tearDown(() {
      if (tempRepo.existsSync()) {
        tempRepo.deleteSync(recursive: true);
      }
    });

    test('writes deterministic SQL artifacts + manifest from canonical inputs',
        () async {
      final preparer = GraphProjectionRebuildPreparer(repoRoot: tempRepo);

      final first = await preparer.prepare();
      final firstDrop = await File(
        '${first.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.dropFileName}',
      ).readAsString();
      final firstProjection = await File(
        '${first.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.projectionFileName}',
      ).readAsString();
      final firstSmoke = await File(
        '${first.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.smokeFileName}',
      ).readAsString();
      final firstTripwire = await File(
        '${first.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.tripwireFileName}',
      ).readAsString();
      final firstManifestRaw = await File(
        '${first.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.manifestFileName}',
      ).readAsString();

      final second = await preparer.prepare();
      final secondDrop = await File(
        '${second.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.dropFileName}',
      ).readAsString();
      final secondProjection = await File(
        '${second.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.projectionFileName}',
      ).readAsString();
      final secondSmoke = await File(
        '${second.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.smokeFileName}',
      ).readAsString();
      final secondTripwire = await File(
        '${second.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.tripwireFileName}',
      ).readAsString();
      final secondManifestRaw = await File(
        '${second.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.manifestFileName}',
      ).readAsString();

      // Determinism — re-runs are byte-identical.
      expect(first.rebuildRunId, equals(second.rebuildRunId));
      expect(secondDrop, equals(firstDrop));
      expect(secondProjection, equals(firstProjection));
      expect(secondSmoke, equals(firstSmoke));
      expect(secondTripwire, equals(firstTripwire));
      expect(secondManifestRaw, equals(firstManifestRaw));

      final manifest = jsonDecode(firstManifestRaw) as Map<String, Object?>;
      expect(
        manifest['record_type'],
        equals('graph_projection_rebuild_manifest'),
      );
      expect(manifest['graph_name'], equals(defaultGraphName));
      expect(
        manifest['graph_scope_filter'],
        equals(defaultGraphScopeFilter),
      );
      expect(
        manifest['apply_mode'],
        equals('not_applied_build_artifacts_only'),
      );
      expect(manifest['rebuild_run_id'], equals(first.rebuildRunId));

      // Canonical-only input contract — manifest names the canonical
      // tables AND explicitly lists the older 7.57.4 advisor seed
      // tables as forbidden inputs so a future regression cannot
      // quietly re-introduce them.
      final inputs = manifest['canonical_inputs']! as Map<String, Object?>;
      expect(inputs['graph_nodes_table'], equals('public.graph_nodes'));
      expect(inputs['graph_edges_table'], equals('public.graph_edges'));
      expect(
        (inputs['active_filter']! as List<Object?>).cast<String>(),
        containsAll(<String>[
          'deleted_at IS NULL',
          'archived_at IS NULL',
          // Future-staged rows (active_from > now()) must be excluded
          // so the rebuild does not project them early.
          'active_from <= now()',
          '(active_to IS NULL OR active_to > now())',
        ]),
      );
      final forbidden =
          (inputs['forbidden_inputs']! as List<Object?>).cast<String>();
      expect(forbidden, contains('public.advisor_graph_node_seeds'));
      expect(forbidden, contains('public.advisor_graph_edge_hints'));

      // Rebuild file ordering: drop → rebuild → smoke → tripwire.
      final files =
          (manifest['rebuild_files']! as List<Object?>).cast<Map<String, Object?>>();
      expect(files.map((f) => f['file']).toList(), <String>[
        GraphProjectionRebuildPreparer.dropFileName,
        GraphProjectionRebuildPreparer.projectionFileName,
        GraphProjectionRebuildPreparer.smokeFileName,
        GraphProjectionRebuildPreparer.tripwireFileName,
      ]);

      // Canonical safety: the rebuild promises NOT to mutate canonical
      // rows even though it WILL drop/recreate the AGE projection.
      final safety = manifest['canonical_safety']! as Map<String, Object?>;
      expect(safety['mutates_canonical_rows'], isFalse);
      expect(safety['mutates_age_projection'], isTrue);

      // Tripwire surface declares Q19 thresholds.
      final tripwire =
          manifest['tripwire_surface']! as Map<String, Object?>;
      expect(tripwire['function'], equals('public.graph_health_metrics()'));
      expect(tripwire['yellow_threshold_active_edges'], equals(3000000));
      expect(tripwire['red_threshold_active_edges'], equals(4000000));

      // Blocker path is documented in the manifest as well as in the
      // emitted SQL (covered below).
      final blocker = manifest['blocker_path']! as Map<String, Object?>;
      expect(blocker['condition'], contains('pg_available_extensions'));
      expect(blocker['behavior'], contains('AGE_BLOCKER'));
    });

    test('drop SQL drops the AGE label graph and emits the AGE_BLOCKER '
        'path when the extension is missing', () async {
      final preparer = GraphProjectionRebuildPreparer(repoRoot: tempRepo);
      final result = await preparer.prepare();
      final dropSql = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.dropFileName}',
      ).readAsString();

      // AGE availability gate.
      expect(
        dropSql,
        contains("from pg_available_extensions where name = 'age'"),
      );
      expect(dropSql, contains('AGE_BLOCKER'));
      // Drops only the AGE label graph; canonical rows are untouched.
      expect(dropSql, contains('ag_catalog.drop_graph(graph_name, true)'));
      expect(dropSql, contains('AGE_DROP_OK'));
      // Idempotent — no-op when graph is absent.
      expect(dropSql, contains('AGE_DROP_NOTE'));
      // No mutation of canonical tables.
      expect(dropSql, isNot(contains('update public.graph_nodes')));
      expect(dropSql, isNot(contains('delete from public.graph_nodes')));
      expect(dropSql, isNot(contains('update public.graph_edges')));
      expect(dropSql, isNot(contains('delete from public.graph_edges')));
      // Older 7.57.4 advisor seed surface stays out of the rebuild.
      expect(dropSql, isNot(contains('public.advisor_graph_node_seeds')));
      expect(dropSql, isNot(contains('public.advisor_graph_edge_hints')));
    });

    test('rebuild projection SQL reads canonical-only, orders deterministically,'
        ' MERGEs vertices and edges, and never mutates canonical rows',
        () async {
      final preparer = GraphProjectionRebuildPreparer(repoRoot: tempRepo);
      final result = await preparer.prepare();
      final projectionSql = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.projectionFileName}',
      ).readAsString();

      // Reads canonical tables.
      expect(projectionSql, contains('from public.graph_nodes'));
      expect(projectionSql, contains('from public.graph_edges'));

      // Old 7.57.4 advisor seed inputs are forbidden — the rebuild
      // path must not depend on them.
      expect(
        projectionSql,
        isNot(contains('public.advisor_graph_node_seeds')),
      );
      expect(
        projectionSql,
        isNot(contains('public.advisor_graph_edge_hints')),
      );

      // Active-only filter — including the active_from gate so a
      // node staged for a future activation does not project early.
      expect(projectionSql, contains('deleted_at is null'));
      expect(projectionSql, contains('archived_at is null'));
      expect(projectionSql, contains('active_from <= now()'));
      expect(
        projectionSql,
        contains('active_to is null or active_to > now()'),
      );

      // Deterministic ordering — re-runs at staging compare byte
      // sequences against this contract.
      expect(
        projectionSql,
        contains('order by operator_id, graph_scope, graph_version, id'),
      );

      // AGE blocker path.
      expect(
        projectionSql,
        contains("from pg_available_extensions where name = 'age'"),
      );
      expect(projectionSql, contains('AGE_BLOCKER'));

      // Idempotent extension + graph creation.
      expect(
        projectionSql,
        contains('create extension if not exists age'),
      );
      expect(projectionSql, contains('ag_catalog.create_graph'));

      // MERGE-based vertex + edge projection (idempotent on re-run).
      expect(projectionSql, contains('MERGE (v:%s {node_id:'));
      expect(projectionSql, contains('MERGE (a)-[r:%s {edge_id:'));

      // Stamps the canonical identity tuple back onto every projected
      // vertex + edge so the smoke artifact can read it via Cypher and
      // compute an AGE-side byte-equivalence digest. Without these
      // properties, the digest comparison cannot run. The edge type
      // is stamped as `r.edge_type` (mirroring `v.node_type`) so the
      // smoke can read it without depending on Cypher's `label(r)` /
      // `type(r)` helpers, which vary across AGE releases.
      expect(projectionSql, contains('v.node_type ='));
      expect(projectionSql, contains('v.node_key ='));
      expect(projectionSql, contains('r.edge_type ='));
      expect(projectionSql, contains('r.from_node_id ='));
      expect(projectionSql, contains('r.to_node_id ='));

      // Canonical rows are read-only — rebuild never UPDATEs them.
      expect(
        projectionSql,
        isNot(contains('update public.graph_nodes')),
      );
      expect(
        projectionSql,
        isNot(contains('update public.graph_edges')),
      );
      expect(
        projectionSql,
        isNot(contains('delete from public.graph_nodes')),
      );
      expect(
        projectionSql,
        isNot(contains('delete from public.graph_edges')),
      );

      // Defensive identifier guard — invalid Cypher labels surface as
      // a hard error instead of being silently injected.
      expect(projectionSql, contains('AGE_REBUILD_INVALID_NODE_TYPE'));
      expect(projectionSql, contains('AGE_REBUILD_INVALID_EDGE_TYPE'));

      // Completion notice carries projected counts so the operator
      // run can attach them to acceptance evidence.
      expect(projectionSql, contains('AGE_REBUILD_OK'));
    });

    test('smoke artifact computes BOTH canonical and AGE-side digests over '
        'the identity tuple and raises on any digest drift — counts alone '
        'are not the byte-equivalence gate', () async {
      final preparer = GraphProjectionRebuildPreparer(repoRoot: tempRepo);
      final result = await preparer.prepare();
      final smokeSql = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.smokeFileName}',
      ).readAsString();

      // AGE blocker is honored in the smoke as well.
      expect(
        smokeSql,
        contains("from pg_available_extensions where name = 'age'"),
      );
      expect(smokeSql, contains('AGE_BLOCKER'));

      // Canonical-side counts + active filter (including active_from).
      expect(smokeSql, contains('canonical_node_count'));
      expect(smokeSql, contains('canonical_edge_count'));
      expect(smokeSql, contains('active_from <= now()'));

      // Canonical-side digests — split into nodes and edges so a
      // single-side regression (e.g. an edge endpoint flipping)
      // surfaces in exactly one digest.
      expect(smokeSql, contains('canonical_node_digest'));
      expect(smokeSql, contains('canonical_edge_digest'));

      // AGE projection counts via Cypher.
      expect(smokeSql, contains('age_node_count'));
      expect(smokeSql, contains('age_edge_count'));
      expect(smokeSql, contains('MATCH (v) RETURN v'));
      expect(smokeSql, contains('MATCH ()-[r]->() RETURN r'));

      // AGE-side digests — the byte-equivalence gate. The Cypher cursor
      // returns the canonical-identity tuple stamped onto each
      // projected row by the rebuild step, then aggregates via SHA-256.
      expect(smokeSql, contains('age_node_digest'));
      expect(smokeSql, contains('age_edge_digest'));
      expect(smokeSql, contains('v.operator_id'));
      expect(smokeSql, contains('v.graph_scope'));
      expect(smokeSql, contains('v.graph_version'));
      expect(smokeSql, contains('v.node_id'));
      expect(smokeSql, contains('v.node_type'));
      expect(smokeSql, contains('v.node_key'));
      expect(smokeSql, contains('r.operator_id'));
      expect(smokeSql, contains('r.graph_scope'));
      expect(smokeSql, contains('r.graph_version'));
      expect(smokeSql, contains('r.edge_id'));
      // r.edge_type — stamped by the rebuild as a property and read
      // back via property access only. AGE relationship-label helpers
      // are not portable across releases (Apache AGE documents
      // relationship-type retrieval via the type-helper form), so
      // reading a stamped property keeps the smoke independent of
      // helper-function availability.
      expect(smokeSql, contains('r.edge_type'));
      expect(smokeSql, isNot(contains('label(r)')));
      expect(smokeSql, contains('r.from_node_id'));
      expect(smokeSql, contains('r.to_node_id'));

      // SHA-256 over the line-aggregated identity tuple.
      expect(smokeSql, contains("encode("));
      expect(smokeSql, contains("digest("));
      expect(smokeSql, contains("'sha256'"));

      // Both count and digest mismatches are surfaced — counts are
      // necessary but not sufficient; the digest comparison is what
      // catches wrong endpoints, mislabeled edges, dropped or invented
      // rows that count-only checks would miss.
      expect(smokeSql, contains('AGE_REBUILD_SMOKE_MISMATCH'));
      expect(smokeSql, contains('AGE_REBUILD_SMOKE_DIGEST_MISMATCH'));
      expect(
        smokeSql,
        contains('age_node_digest is distinct from canonical_node_digest'),
      );
      expect(
        smokeSql,
        contains('age_edge_digest is distinct from canonical_edge_digest'),
      );
      expect(smokeSql, contains('AGE_REBUILD_SMOKE_OK'));
    });

    test('manifest declares the byte-equivalence gate compares both '
        'canonical and AGE digests over the identity tuple', () async {
      final preparer = GraphProjectionRebuildPreparer(repoRoot: tempRepo);
      final result = await preparer.prepare();
      final manifestRaw = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.manifestFileName}',
      ).readAsString();
      final manifest = jsonDecode(manifestRaw) as Map<String, Object?>;
      final gate =
          manifest['byte_equivalence_gate']! as Map<String, Object?>;

      final compares = (gate['compares']! as List<Object?>).cast<String>();
      expect(
        compares,
        containsAll(<String>[
          'canonical_node_digest',
          'canonical_edge_digest',
          'age_node_digest',
          'age_edge_digest',
        ]),
      );
      expect(gate['algorithm'], equals('sha256'));

      // Identity tuples for nodes and edges are explicit so a future
      // change to the digest input set is a manifest-level signal.
      final nodeTuple =
          (gate['identity_tuple_nodes']! as List<Object?>).cast<String>();
      expect(
        nodeTuple,
        containsAll(<String>[
          'operator_id',
          'graph_scope',
          'graph_version',
          'id',
          'node_type',
          'node_key',
        ]),
      );
      final edgeTuple =
          (gate['identity_tuple_edges']! as List<Object?>).cast<String>();
      expect(
        edgeTuple,
        containsAll(<String>[
          'operator_id',
          'graph_scope',
          'graph_version',
          'id',
          'edge_type',
          'from_node_id',
          'to_node_id',
        ]),
      );
    });

    test('tripwire artifact reads public.graph_health_metrics() and '
        'reports yellow/red status with Q19 thresholds', () async {
      final preparer = GraphProjectionRebuildPreparer(repoRoot: tempRepo);
      final result = await preparer.prepare();
      final tripwireSql = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.tripwireFileName}',
      ).readAsString();

      expect(
        tripwireSql,
        contains('from public.graph_health_metrics()'),
      );
      expect(tripwireSql, contains('AGE_TRIPWIRE_RED'));
      expect(tripwireSql, contains('AGE_TRIPWIRE_YELLOW'));
      expect(tripwireSql, contains('AGE_TRIPWIRE_GREEN'));
      // Per-row notice carries scope/version + counts so the operator
      // panel can attach them.
      expect(tripwireSql, contains('AGE_TRIPWIRE: scope='));
      // Q19 4M / 3M thresholds are surfaced in the rollover prose so
      // the operator running the rebuild knows what just fired.
      expect(tripwireSql, contains('4M'));
      expect(tripwireSql, contains('3M'));
    });
  });
}

/// Normalize CRLF → LF so multi-line `contains(...)` assertions are
/// platform-independent. Windows checkouts via the default
/// `core.autocrlf=true` setting deliver CRLF line endings, which
/// would otherwise break literal-string assertions that span multiple
/// lines.
String _readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}
