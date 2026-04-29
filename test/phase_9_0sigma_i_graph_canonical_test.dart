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

      // Tripwire surface declares Q19 thresholds and an operator-
      // scoped read path. The misleading `function` field — which
      // pointed B42 implementers at public.graph_health_metrics() and
      // would have recreated the cross-tenant aggregation bug — is
      // intentionally removed. B42 manifest consumers follow
      // `reads_from` + `aggregation_keys` instead.
      final tripwire =
          manifest['tripwire_surface']! as Map<String, Object?>;
      expect(
        tripwire.containsKey('function'),
        isFalse,
        reason: 'The "function" field was removed because pointing '
            'B42 at public.graph_health_metrics() recreates the '
            'forge_admin operatorless-aggregation bug. Consumers must '
            'use reads_from + aggregation_keys instead.',
      );
      final readsFrom =
          (tripwire['reads_from']! as List<Object?>).cast<String>();
      expect(
        readsFrom,
        containsAll(<String>[
          'public.graph_nodes',
          'public.graph_edges',
        ]),
      );
      final aggregationKeys =
          (tripwire['aggregation_keys']! as List<Object?>).cast<String>();
      expect(
        aggregationKeys,
        containsAllInOrder(<String>[
          'operator_id',
          'graph_scope',
          'graph_version',
        ]),
      );
      expect(
        tripwire['tenant_scoped_helper_function'],
        equals('public.graph_health_metrics()'),
      );
      // The helper is still NAMED for tenant-scoped ad-hoc use, but
      // an explicit warning string sits next to it so a B42 reader
      // does not mistake it for the cross-tenant read path.
      expect(
        tripwire['tenant_scoped_helper_function_warning'],
        contains('MUST NOT be used as the B42 forge_admin /health '
            'read path'),
      );
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

      // Composite-identity MERGE — vertex pattern carries
      // (operator_id, graph_scope, graph_version, node_id) so two
      // canonical rows with the same UUID across different
      // tenants/scopes/versions stay separate vertices in AGE.
      expect(projectionSql, contains('MERGE (v:%s {operator_id:'));
      expect(projectionSql, contains('graph_scope:'));
      expect(projectionSql, contains('graph_version:'));
      expect(projectionSql, contains('node_id:'));
      // Edge MERGE pattern is composite too — same rationale.
      expect(projectionSql, contains('MERGE (a)-[r:%s {operator_id:'));
      // Edge endpoint MATCH carries the full canonical identity tuple
      // so an edge cannot attach to a same-UUID vertex from a
      // different tenant/scope/version.
      expect(projectionSql, contains('MATCH (a {operator_id:'));
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

      // AGE projection counts via Cypher. The MATCH carries an
      // optional WHERE slot so a bounded scope filter can narrow the
      // count to the rebuilt subgraph; `all_active` collapses the
      // slot to an empty string and the count walks the whole graph.
      expect(smokeSql, contains('age_node_count'));
      expect(smokeSql, contains('age_edge_count'));
      expect(smokeSql, contains('MATCH (v)'));
      expect(smokeSql, contains('RETURN v'));
      expect(smokeSql, contains('MATCH ()-[r]->()'));
      expect(smokeSql, contains('RETURN r'));

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

    test('tripwire artifact aggregates canonical tables grouped by '
        '(operator_id, graph_scope, graph_version) and reports '
        'green/yellow/red status with Q19 thresholds', () async {
      final preparer = GraphProjectionRebuildPreparer(repoRoot: tempRepo);
      final result = await preparer.prepare();
      final tripwireSql = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.tripwireFileName}',
      ).readAsString();

      // Reads canonical tables directly so forge_admin BYPASSRLS sees
      // per-tenant rows. The migration's graph_health_metrics()
      // function exists as a tenant-scoped helper but is unsuitable
      // for forge_admin reads because it aggregates across
      // operator_id; the rebuild's tripwire avoids it deliberately.
      expect(tripwireSql, contains('from public.graph_nodes'));
      expect(tripwireSql, contains('from public.graph_edges'));
      expect(
        tripwireSql,
        contains('group by operator_id, graph_scope, graph_version'),
      );
      expect(tripwireSql, contains('AGE_TRIPWIRE_RED'));
      expect(tripwireSql, contains('AGE_TRIPWIRE_YELLOW'));
      expect(tripwireSql, contains('AGE_TRIPWIRE_GREEN'));
      // Per-row notice carries operator + scope/version + counts so
      // the operator panel can attach them. The line shape begins
      // with `operator=` because the tripwire is operator-scoped now.
      expect(tripwireSql, contains('AGE_TRIPWIRE: operator='));
      expect(tripwireSql, contains('scope='));
      expect(tripwireSql, contains('version='));
      // Q19 4M / 3M thresholds are surfaced in the rollover prose so
      // the operator running the rebuild knows what just fired.
      expect(tripwireSql, contains('4M'));
      expect(tripwireSql, contains('3M'));
    });

    test('B44 — bounded scope filter pushes into the generated SQL: drop '
        'targets only the matched subgraph via DETACH DELETE, projection '
        'and smoke narrow canonical SELECTs to the matched scope/version, '
        'and the tripwire restricts its aggregation to the same filter',
        () async {
      final preparer = GraphProjectionRebuildPreparer(
        repoRoot: tempRepo,
        graphScopeFilter: 'methodology:v3',
      );
      final result = await preparer.prepare();
      final dropSql = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.dropFileName}',
      ).readAsString();
      final projectionSql = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.projectionFileName}',
      ).readAsString();
      final smokeSql = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.smokeFileName}',
      ).readAsString();
      final tripwireSql = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.tripwireFileName}',
      ).readAsString();
      final manifestRaw = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.manifestFileName}',
      ).readAsString();
      final manifest = jsonDecode(manifestRaw) as Map<String, Object?>;

      // Bounded drop — the script runs Cypher DETACH DELETE on the
      // matched subgraph and explicitly does NOT call
      // ag_catalog.drop_graph (which would erase every projection
      // including untouched scopes).
      expect(dropSql, contains("v.graph_scope = 'methodology'"));
      expect(dropSql, contains("v.graph_version = 'v3'"));
      expect(dropSql, contains('DETACH DELETE v'));
      expect(
        dropSql,
        isNot(contains('ag_catalog.drop_graph(graph_name, true)')),
        reason: 'A bounded-scope drop must not call drop_graph; that '
            'helper drops every projection in the AGE catalog and '
            'would erase scopes the rebuild is not touching.',
      );

      // Projection and smoke narrow canonical SELECTs to the matched
      // scope/version. The fragment is positional so the byte
      // sequence stays deterministic.
      expect(projectionSql, contains("and graph_scope = 'methodology'"));
      expect(projectionSql, contains("and graph_version = 'v3'"));
      expect(smokeSql, contains("and graph_scope = 'methodology'"));
      expect(smokeSql, contains("and graph_version = 'v3'"));
      // Smoke's AGE-side queries also carry the same Cypher WHERE so
      // a bounded rebuild's digest comparison is restricted to the
      // matched subgraph (count + digest both narrowed identically).
      expect(smokeSql, contains("v.graph_scope = 'methodology'"));
      expect(smokeSql, contains("v.graph_version = 'v3'"));
      expect(smokeSql, contains("r.graph_scope = 'methodology'"));
      expect(smokeSql, contains("r.graph_version = 'v3'"));

      // Tripwire restricts its aggregation to the same filter so a
      // bounded rebuild reports only the rebuilt subgraph's status.
      expect(tripwireSql, contains("and graph_scope = 'methodology'"));
      expect(tripwireSql, contains("and graph_version = 'v3'"));

      // Manifest captures the parsed filter so a downstream tool
      // sees exactly what the SQL was narrowed to without re-parsing.
      final parsed =
          manifest['graph_scope_filter_parsed']! as Map<String, Object?>;
      expect(parsed['is_all_active'], isFalse);
      expect(parsed['scope'], equals('methodology'));
      expect(parsed['version'], equals('v3'));
      expect(
        parsed['description'],
        equals('scope=methodology, version=v3'),
      );

      // Drop role on the manifest reflects the bounded behavior.
      final files = (manifest['rebuild_files']! as List<Object?>)
          .cast<Map<String, Object?>>();
      final dropEntry = files.firstWhere(
        (f) => f['file'] == GraphProjectionRebuildPreparer.dropFileName,
      );
      expect(
        dropEntry['role'],
        equals('drop_age_subgraph_for_scope_filter'),
      );
    });

    test('B44 — invalid scope filter values are rejected at parse time so '
        'the SQL cannot smuggle injection', () {
      // Empty / whitespace.
      expect(
        () => GraphProjectionRebuildPreparer(
          repoRoot: tempRepo,
          graphScopeFilter: '',
        ),
        throwsA(isA<GraphProjectionException>()),
      );
      // SQL injection attempt — quotes and statement separators.
      expect(
        () => GraphProjectionRebuildPreparer(
          repoRoot: tempRepo,
          graphScopeFilter: "methodology'; drop table public.graph_nodes; --",
        ),
        throwsA(isA<GraphProjectionException>()),
      );
      // Cypher injection attempt — closing brace.
      expect(
        () => GraphProjectionRebuildPreparer(
          repoRoot: tempRepo,
          graphScopeFilter: 'methodology}) DETACH DELETE v //',
        ),
        throwsA(isA<GraphProjectionException>()),
      );
    });

    test('B44 — AGE projection identity is composite '
        '(operator_id, graph_scope, graph_version, node_id) so '
        'cross-tenant / cross-scope / cross-version UUIDs do not '
        'collapse into a single AGE node', () async {
      final preparer = GraphProjectionRebuildPreparer(repoRoot: tempRepo);
      final result = await preparer.prepare();
      final projectionSql = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.projectionFileName}',
      ).readAsString();
      final manifestRaw = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.manifestFileName}',
      ).readAsString();
      final manifest = jsonDecode(manifestRaw) as Map<String, Object?>;

      // Vertex MERGE pattern carries the full canonical identity
      // tuple. Same-UUID rows under different (operator, scope,
      // version) frames stay separate vertices in AGE.
      expect(projectionSql, contains('MERGE (v:%s {operator_id:'));
      // Edge MERGE pattern is composite too.
      expect(projectionSql, contains('MERGE (a)-[r:%s {operator_id:'));
      // Edge endpoint MATCH is composite — an edge cannot attach to
      // a same-UUID vertex from a different (operator, scope,
      // version) frame.
      expect(projectionSql, contains('MATCH (a {operator_id:'));

      // Manifest declares the same posture so a downstream tool sees
      // the contract.
      final identity =
          manifest['age_projection_identity']! as Map<String, Object?>;
      final vertexKeys = (identity['vertex_merge_pattern_keys']!
              as List<Object?>)
          .cast<String>();
      expect(
        vertexKeys,
        containsAllInOrder(<String>[
          'operator_id',
          'graph_scope',
          'graph_version',
          'node_id',
        ]),
      );
      final edgeKeys =
          (identity['edge_merge_pattern_keys']! as List<Object?>)
              .cast<String>();
      expect(
        edgeKeys,
        containsAllInOrder(<String>[
          'operator_id',
          'graph_scope',
          'graph_version',
          'edge_id',
        ]),
      );
      final endpointKeys = (identity['edge_endpoint_match_keys']!
              as List<Object?>)
          .cast<String>();
      expect(
        endpointKeys,
        containsAllInOrder(<String>[
          'operator_id',
          'graph_scope',
          'graph_version',
          'node_id',
        ]),
      );
    });

    test('B44 — tripwire is operator-scoped so forge_admin BYPASSRLS '
        'sees one row per (operator_id, graph_scope, graph_version) '
        'instead of cross-tenant aggregates', () async {
      final preparer = GraphProjectionRebuildPreparer(repoRoot: tempRepo);
      final result = await preparer.prepare();
      final tripwireSql = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.tripwireFileName}',
      ).readAsString();
      final manifestRaw = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.manifestFileName}',
      ).readAsString();
      final manifest = jsonDecode(manifestRaw) as Map<String, Object?>;

      // Per-row line surfaces operator_id alongside scope/version so
      // forge_admin can wire one row per tenant without re-deriving.
      expect(tripwireSql, contains('AGE_TRIPWIRE: operator='));
      // Aggregation is GROUP BY (operator_id, graph_scope,
      // graph_version) — not the migration's
      // graph_health_metrics() function, which discards operator_id.
      expect(
        tripwireSql,
        contains('group by operator_id, graph_scope, graph_version'),
      );
      // Manifest declares the aggregation keys explicitly so the B42
      // proxy ingestion layer knows what cardinality to expect.
      final tripwire =
          manifest['tripwire_surface']! as Map<String, Object?>;
      final aggregationKeys =
          (tripwire['aggregation_keys']! as List<Object?>).cast<String>();
      expect(
        aggregationKeys,
        containsAllInOrder(<String>[
          'operator_id',
          'graph_scope',
          'graph_version',
        ]),
      );
      expect(tripwire['forge_admin_per_tenant_rows'], isTrue);
      // The migration's tenant-scoped helper is still named in the
      // manifest as a fallback for ad-hoc tenant queries.
      expect(
        tripwire['tenant_scoped_helper_function'],
        equals('public.graph_health_metrics()'),
      );
    });

    test('B44 — yellow threshold begins at 3M active edges and red threshold '
        'begins at 4M active edges, surfaced in BOTH the tripwire SQL and '
        'the rebuild manifest', () async {
      final preparer = GraphProjectionRebuildPreparer(repoRoot: tempRepo);
      final result = await preparer.prepare();
      final tripwireSql = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.tripwireFileName}',
      ).readAsString();
      final manifestRaw = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.manifestFileName}',
      ).readAsString();
      final manifest = jsonDecode(manifestRaw) as Map<String, Object?>;

      // SQL surfaces the exact numeric thresholds AND the named
      // constants — 11A.5 wiring asserts on the numeric form, the
      // operator running the rebuild reads the named form.
      expect(
        tripwireSql,
        contains('yellow_threshold_active_edges=3000000'),
        reason: 'Yellow tripwire begins at 3M active edges per Q19; '
            'the named-constant form must appear in the SQL so '
            'operators reading NOTICEs can see why the row fired.',
      );
      expect(
        tripwireSql,
        contains('red_threshold_active_edges=4000000'),
        reason: 'Red tripwire begins at 4M active edges per Q19; '
            'the named-constant form must appear in the SQL.',
      );
      // Roll-up TOTALS line carries the exact integers as well so a
      // single grep over the rebuild logs proves the gate fired
      // against 3M / 4M without re-reading the per-row entries.
      expect(tripwireSql, contains('3000000'));
      expect(tripwireSql, contains('4000000'));

      // Manifest declares the same thresholds as ints so a downstream
      // tool ingesting the manifest sees the contract directly.
      final tripwire =
          manifest['tripwire_surface']! as Map<String, Object?>;
      expect(
        tripwire['yellow_threshold_active_edges'],
        equals(3000000),
        reason: 'Manifest must lock yellow at 3M active edges.',
      );
      expect(
        tripwire['red_threshold_active_edges'],
        equals(4000000),
        reason: 'Manifest must lock red at 4M active edges.',
      );
      // Status alphabet stays {green, yellow, red} so 11A.5 has a
      // closed enum to render against.
      final statusValues =
          (tripwire['status_values']! as List<Object?>).cast<String>();
      expect(
        statusValues,
        containsAll(<String>['green', 'yellow', 'red']),
      );
    });

    test('B44 — tripwire SQL + manifest expose the FULL B42 graph health '
        'metric key contract (active counts plus reserved-null keys for '
        'p95 latency, timeout rate, high-degree count, and last-build '
        'age) so the proxy /health route can wire to a stable parsing '
        'target without breaking when individual keys flip from null '
        'to numeric', () async {
      final preparer = GraphProjectionRebuildPreparer(repoRoot: tempRepo);
      final result = await preparer.prepare();
      final tripwireSql = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.tripwireFileName}',
      ).readAsString();
      final manifestRaw = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.manifestFileName}',
      ).readAsString();
      final manifest = jsonDecode(manifestRaw) as Map<String, Object?>;

      // Per-row tripwire NOTICE carries the B42 key shapes verbatim so
      // a 11A.5 surface ingesting the lines pulls the metric without
      // having to translate column aliases.
      // Active keys — non-null today.
      expect(tripwireSql, contains('graph_node_count='));
      expect(tripwireSql, contains('graph_edge_count='));
      expect(tripwireSql, contains('graph_active_edges_count='));
      // Reserved-null keys — emitted as `<key>=null` in every line so
      // the parser-side schema is stable today and a later benchmark
      // slice can flip individual keys to numeric without breaking
      // the proxy.
      expect(tripwireSql, contains('graph_traversal_latency_ms=null'));
      expect(tripwireSql, contains('graph_p95_traversal_latency_ms=null'));
      expect(tripwireSql, contains('graph_timeout_rate=null'));
      expect(tripwireSql, contains('graph_high_degree_count=null'));
      expect(
        tripwireSql,
        contains('graph_last_projection_build_seconds_ago=null'),
      );
      // Cross-scope roll-up line carries the totaled form of the same
      // keys for a one-line summary view.
      expect(tripwireSql, contains('AGE_TRIPWIRE_TOTALS:'));
      // Reserved metadata slots flow into both per-row and totals
      // NOTICEs so 11A.5 can render last-build/last-benchmark context
      // (currently null until a benchmark / runtime telemetry slice
      // fills them).
      expect(tripwireSql, contains('last_projection_built_at=null'));
      expect(tripwireSql, contains('last_benchmark_at=null'));

      // Manifest mirrors the same key list so a manifest-only consumer
      // (CI gate, doc generator, B42 proxy ingestion) sees the
      // contract. The key set is the union of active + reserved-null.
      final tripwire =
          manifest['tripwire_surface']! as Map<String, Object?>;
      final keys =
          (tripwire['b42_health_metric_keys']! as List<Object?>).cast<String>();
      expect(
        keys,
        containsAll(<String>[
          'graph_node_count',
          'graph_edge_count',
          'graph_active_edges_count',
          'graph_traversal_latency_ms',
          'graph_p95_traversal_latency_ms',
          'graph_timeout_rate',
          'graph_high_degree_count',
          'graph_last_projection_build_seconds_ago',
        ]),
        reason: 'B42 reserved health key names must round-trip through '
            'the manifest so the proxy /health slice can ingest them '
            'without re-reading the SQL. The set includes both active '
            'counts (filled today) and reserved-null keys (filled by '
            'a later benchmark slice).',
      );
      // Active vs reserved-null split is explicit so the proxy parser
      // knows which keys it must handle as nullable strings until the
      // benchmark slice ships.
      final activeKeys = (tripwire['b42_health_metric_keys_active']!
              as List<Object?>)
          .cast<String>();
      expect(
        activeKeys,
        containsAll(<String>[
          'graph_node_count',
          'graph_edge_count',
          'graph_active_edges_count',
        ]),
      );
      final reservedNullKeys =
          (tripwire['b42_health_metric_keys_reserved_null_today']!
                  as List<Object?>)
              .cast<String>();
      expect(
        reservedNullKeys,
        containsAll(<String>[
          'graph_traversal_latency_ms',
          'graph_p95_traversal_latency_ms',
          'graph_timeout_rate',
          'graph_high_degree_count',
          'graph_last_projection_build_seconds_ago',
        ]),
      );
      // No overlap between active and reserved-null sets.
      for (final reserved in reservedNullKeys) {
        expect(
          activeKeys,
          isNot(contains(reserved)),
          reason: 'Key "$reserved" must be in exactly one set; the '
              'active vs reserved-null split is the contract.',
        );
      }

      final metadataSlots =
          (tripwire['metadata_slots']! as List<Object?>).cast<String>();
      expect(
        metadataSlots,
        containsAll(<String>[
          'last_projection_built_at',
          'last_benchmark_at',
        ]),
      );
      final noticePrefixes =
          (tripwire['notice_prefixes']! as List<Object?>).cast<String>();
      expect(
        noticePrefixes,
        containsAll(<String>[
          'AGE_TRIPWIRE',
          'AGE_TRIPWIRE_TOTALS',
          'AGE_TRIPWIRE_GREEN',
          'AGE_TRIPWIRE_YELLOW',
          'AGE_TRIPWIRE_RED',
        ]),
      );
    });

    test('B44 — rebuild artifacts do NOT imply canonical graph mutation: '
        'every emitted SQL file is read-only against public.graph_nodes / '
        'public.graph_edges, and the manifest declares the same posture '
        'explicitly', () async {
      final preparer = GraphProjectionRebuildPreparer(repoRoot: tempRepo);
      final result = await preparer.prepare();
      final manifestRaw = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.manifestFileName}',
      ).readAsString();
      final manifest = jsonDecode(manifestRaw) as Map<String, Object?>;

      // Manifest claim: no canonical mutation, regardless of which SQL
      // file fires. The four explicit booleans below would each fail
      // to round-trip if a future regression flipped the contract.
      final safety = manifest['canonical_safety']! as Map<String, Object?>;
      expect(safety['mutates_canonical_rows'], isFalse);
      expect(safety['mutates_graph_nodes_table'], isFalse);
      expect(safety['mutates_graph_edges_table'], isFalse);
      expect(safety['rebuild_artifacts_imply_canonical_mutation'], isFalse);
      // The rebuild DOES drop/recreate the AGE projection — that is
      // not canonical mutation per Q19.
      expect(safety['mutates_age_projection'], isTrue);

      // SQL-level guard — every emitted file must be free of
      // canonical-mutation statements. The drop / projection / smoke
      // tests already cover this individually; the loop here makes
      // canonical-safety a single B44 acceptance assertion that
      // surfaces if any future file regressed.
      const sqlFiles = <String>[
        GraphProjectionRebuildPreparer.dropFileName,
        GraphProjectionRebuildPreparer.projectionFileName,
        GraphProjectionRebuildPreparer.smokeFileName,
        GraphProjectionRebuildPreparer.tripwireFileName,
      ];
      for (final fileName in sqlFiles) {
        final sql = await File(
          '${result.outputDirectory}/$fileName',
        ).readAsString();
        for (final forbidden in const <String>[
          'update public.graph_nodes',
          'update public.graph_edges',
          'delete from public.graph_nodes',
          'delete from public.graph_edges',
          'insert into public.graph_nodes',
          'insert into public.graph_edges',
          'truncate public.graph_nodes',
          'truncate public.graph_edges',
        ]) {
          expect(
            sql,
            isNot(contains(forbidden)),
            reason: 'Rebuild artifact $fileName must never imply canonical '
                'mutation. Found forbidden statement "$forbidden". Per '
                'Q19, canonical truth is graph_nodes/graph_edges; the '
                'rebuild is a projection-only operation.',
          );
        }
      }
    });

    test('B44 — manifest carries operator-readable rebuild metadata: '
        'last projection build slot, benchmark slot, graph scope/version '
        'context, canonical source tables, and a four-step validation '
        'plan so 11A health surfaces have everything they need', () async {
      final preparer = GraphProjectionRebuildPreparer(repoRoot: tempRepo);
      final result = await preparer.prepare();
      final manifestRaw = await File(
        '${result.outputDirectory}/'
        '${GraphProjectionRebuildPreparer.manifestFileName}',
      ).readAsString();
      final manifest = jsonDecode(manifestRaw) as Map<String, Object?>;

      // Reserved metadata slots match graph_health_metrics() column
      // shape so a 11A.5 panel reading the manifest already knows
      // which fields in the SQL function it should render.
      final tripwire =
          manifest['tripwire_surface']! as Map<String, Object?>;
      final metadataSlots =
          (tripwire['metadata_slots']! as List<Object?>).cast<String>();
      expect(metadataSlots, contains('last_projection_built_at'));
      expect(metadataSlots, contains('last_benchmark_at'));

      // Graph scope / version context — the manifest names the filter
      // shape and the canonical source tables so a downstream B42
      // /health route consumer does not need to re-read the migration.
      expect(
        manifest['graph_scope_filter'],
        equals(defaultGraphScopeFilter),
      );
      expect(
        manifest['graph_scope_version_pairs'],
        contains('graph_scope, graph_version'),
      );
      final sources =
          (manifest['canonical_source_tables']! as List<Object?>).cast<String>();
      expect(
        sources,
        containsAll(<String>[
          'public.graph_nodes',
          'public.graph_edges',
        ]),
      );

      // Validation step plan — drop, rebuild, smoke, tripwire (plus
      // preflight + dry-run) in the order the runbook prescribes.
      final steps = (manifest['rebuild_validation_steps']! as List<Object?>)
          .cast<Map<String, Object?>>();
      final stepNames = steps.map((s) => s['name']).toList();
      expect(
        stepNames,
        containsAllInOrder(<String>[
          'preflight',
          'dry_run_artifacts',
          'drop_age_projection',
          'rebuild_age_projection',
          'smoke_byte_equivalence',
          'tripwire_health_check',
        ]),
        reason: 'Rebuild validation steps must be ordered so the runbook '
            'and the manifest agree on the apply sequence.',
      );

      // Runbook reference exists so any tooling reading the manifest
      // knows where to find operator procedure.
      expect(
        manifest['runbook_reference'],
        equals(
          'docs/phases/phase_9/phase_9_graph_projection_rebuild_runbook.md',
        ),
      );
    });
  });

  group('Phase 9.0Σ.i graph projection rebuild runbook (B44)', () {
    final runbookFile = File(
      'docs/phases/phase_9/phase_9_graph_projection_rebuild_runbook.md',
    );

    test('runbook file exists at the manifest-referenced path', () {
      expect(
        runbookFile.existsSync(),
        isTrue,
        reason: 'B44 runbook must live at the path the manifest names so '
            'the manifest reference is not a broken link.',
      );
    });

    test('runbook covers when to rebuild, preflight, dry-run, Production1 '
        'gate, execution outline, validation, rollback, and B42 '
        'consumption', () {
      final runbook = runbookFile.readAsStringSync();
      // Required headings — the runbook is normative, so the section
      // names are part of the contract.
      const requiredHeadings = <String>[
        '## When to run a rebuild',
        '## Preflight checks',
        '## Dry-run / local artifact generation',
        '## Production1 approval gate',
        '## Rebuild execution outline',
        '## Validation and smoke checks',
        '## Rollback / fallback',
        '## How B42 graph health keys consume this status',
      ];
      for (final heading in requiredHeadings) {
        expect(
          runbook,
          contains(heading),
          reason: 'Runbook must define section "$heading" so a B44 '
              'reader has procedure for that phase of the rebuild.',
        );
      }
      // Q19 thresholds + B42 keys must appear so the runbook agrees
      // with the SQL/manifest contract above.
      expect(runbook, contains('3,000,000'));
      expect(runbook, contains('4,000,000'));
      expect(runbook, contains('graph_node_count'));
      expect(runbook, contains('graph_edge_count'));
      expect(runbook, contains('graph_traversal_latency_ms'));
      expect(runbook, contains('public.graph_health_metrics()'));
      // The rebuild is non-destructive against canonical truth — the
      // runbook must say so out loud.
      expect(runbook, contains('graph_nodes'));
      expect(runbook, contains('graph_edges'));
      expect(runbook, contains('canonical'));
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
