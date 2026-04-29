// Phase 9.0Σ.i — canonical graph projection rebuild artifact generator.
//
// `GraphProjectionRebuildPreparer` emits deterministic SQL artifacts +
// a manifest that drop and recreate the Apache AGE label graph from
// the canonical `public.graph_nodes` / `public.graph_edges` rows
// landed by `db/migrations/202604280008_phase_9_0sigma_i_graph_canonical.sql`.
//
// Build artifact only. The generated SQL is the contract — `dart run
// tool/graph_projection/main.dart prepare-rebuild` writes files; it
// never opens a Postgres connection, never hits a provider, and never
// touches the live AGE projection. Operator-side apply lives in a
// separate slice that runs the generated SQL inside a tenant-scoped
// transaction with RLS enforcing scope per Q19.
//
// Hard rules (carried from CLAUDE.md and the migration header):
//   1. Canonical truth lives in `public.graph_nodes` /
//      `public.graph_edges`. The generated SQL READS canonical rows
//      and may DROP/RECREATE the AGE label graph; it must NEVER
//      mutate canonical rows. The advisor seed tables
//      (`public.advisor_graph_node_seeds`, `public.advisor_graph_edge_hints`)
//      are out of scope for this slice — they are the older 7.57.4
//      AGE seed surface and the rebuild SQL emitted here references
//      `public.graph_nodes`/`public.graph_edges` only.
//   2. Active filter — only rows with `deleted_at IS NULL`,
//      `archived_at IS NULL`, `active_from <= now()`, and
//      `(active_to IS NULL OR active_to > now())` participate in the
//      rebuild. Future-staged rows (active_from > now()) are excluded
//      so they do not project early; soft-deleted and archived rows
//      stay on disk for audit / version revert.
//   3. Deterministic ordering — every cursor that drives `MERGE`
//      orders by `(operator_id, graph_scope, graph_version, id)` so a
//      re-run of the rebuild produces byte-identical Cypher
//      statements; staging byte-equivalence checks rely on this.
//   4. AGE blocker path — when the AGE extension is unavailable, the
//      generated SQL emits `RAISE NOTICE 'AGE_BLOCKER: ...'` and
//      exits cleanly. Vector-only retrieval remains the launch
//      fallback until AGE is provisioned.
//   5. The tripwire surface aggregates canonical
//      `public.graph_nodes` / `public.graph_edges` directly with
//      `GROUP BY (operator_id, graph_scope, graph_version)` so a
//      forge_admin BYPASSRLS run reports per-tenant rows. The
//      migration's `public.graph_health_metrics()` function exists as
//      a tenant-scoped helper for ad-hoc queries; it aggregates by
//      `(graph_scope, graph_version)` only and is intentionally NOT
//      the rebuild's tripwire read path because forge_admin views
//      require operator scoping (B42 archived contract).

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Default AGE graph name the rebuild artifact targets. Matches the
/// historical advisor projection name so the operator-run rebuild
/// continues to maintain the same downstream graph identity.
const String defaultGraphName = 'advisor_corpus';

/// Default canonical scope rebuilt by the generated SQL. The migration
/// permits multiple scopes (`methodology`, `workflows`, `causal`); the
/// rebuild artifact ranges over every active scope/version pair the
/// canonical tables expose so a single run keeps the AGE graph in sync
/// with whatever is canonical right now.
const String defaultGraphScopeFilter = 'all_active';

/// Output of a `prepare-rebuild` run. The CLI prints a small subset of
/// these fields; tests assert against the full shape.
class GraphProjectionRebuildResult {
  GraphProjectionRebuildResult({
    required this.outputDirectory,
    required this.rebuildRunId,
    required this.graphName,
    required this.graphScopeFilter,
    required this.rebuildFiles,
    required this.manifestFile,
  });

  final String outputDirectory;
  final String rebuildRunId;
  final String graphName;
  final String graphScopeFilter;
  final List<String> rebuildFiles;
  final String manifestFile;
}

/// `prepare-rebuild` artifact preparer. Emits four SQL files plus a
/// manifest into `outputDirectory`. Re-running with the same inputs
/// produces byte-identical artifacts because every internal id is
/// derived deterministically from the rebuild contract.
class GraphProjectionRebuildPreparer {
  GraphProjectionRebuildPreparer({
    required Directory repoRoot,
    String graphName = defaultGraphName,
    String graphScopeFilter = defaultGraphScopeFilter,
  })  : _repoRoot = repoRoot,
        _graphName = graphName,
        _graphScopeFilter = graphScopeFilter,
        _filter = _ScopeFilter.parse(graphScopeFilter);

  final Directory _repoRoot;
  final String _graphName;
  final String _graphScopeFilter;
  final _ScopeFilter _filter;

  static const String dropFileName = '001_age_drop_projection.sql';
  static const String projectionFileName = '002_age_rebuild_projection.sql';
  static const String smokeFileName = '003_age_rebuild_smoke.sql';
  static const String tripwireFileName = '004_age_rebuild_tripwire.sql';
  static const String manifestFileName = 'graph_projection_rebuild_manifest.json';

  Future<GraphProjectionRebuildResult> prepare({
    String outputDirectory = 'build/graph_projection',
  }) async {
    final output = Directory(p.join(_repoRoot.path, outputDirectory));
    output.createSync(recursive: true);

    final dropSql = _dropSql();
    final projectionSql = _projectionSql();
    final smokeSql = _smokeSql();
    final tripwireSql = _tripwireSql();

    await File(p.join(output.path, dropFileName)).writeAsString(dropSql);
    await File(
      p.join(output.path, projectionFileName),
    ).writeAsString(projectionSql);
    await File(p.join(output.path, smokeFileName)).writeAsString(smokeSql);
    await File(
      p.join(output.path, tripwireFileName),
    ).writeAsString(tripwireSql);

    // Deterministic id derived from the contract, not from a clock.
    // Identical inputs → identical id, so a staging byte-equivalence
    // check can compare manifests across runs without touching the
    // generated SQL.
    final rebuildRunId = _deterministicUuid(
      'graph_projection_rebuild:'
      '$_graphName:$_graphScopeFilter:'
      '${_sha256ForString(dropSql)}:'
      '${_sha256ForString(projectionSql)}:'
      '${_sha256ForString(smokeSql)}:'
      '${_sha256ForString(tripwireSql)}',
    );

    final manifest = <String, Object?>{
      'record_type': 'graph_projection_rebuild_manifest',
      'preparer_version': 3,
      'rebuild_run_id': rebuildRunId,
      'graph_name': _graphName,
      'graph_scope_filter': _graphScopeFilter,
      'graph_scope_filter_parsed': _filter.toManifest(),
      'graph_scope_version_pairs':
          _filter.isAllActive
              ? 'all active (operator_id, graph_scope, graph_version) '
                  'tuples with deleted_at/archived_at NULL and '
                  'active_from <= now() < coalesce(active_to, infinity)'
              : 'active (operator_id, graph_scope, graph_version) tuples '
                  'narrowed by ${_filter.description}',
      'apply_mode': 'not_applied_build_artifacts_only',
      'canonical_source_tables': const <String>[
        'public.graph_nodes',
        'public.graph_edges',
      ],
      'canonical_inputs': <String, Object?>{
        'graph_nodes_table': 'public.graph_nodes',
        'graph_edges_table': 'public.graph_edges',
        'active_filter': <String>[
          'deleted_at IS NULL',
          'archived_at IS NULL',
          'active_from <= now()',
          '(active_to IS NULL OR active_to > now())',
          if (_filter.scope != null) "graph_scope = '${_filter.scope}'",
          if (_filter.version != null)
            "graph_version = '${_filter.version}'",
        ],
        'forbidden_inputs': const <String>[
          'public.advisor_graph_node_seeds',
          'public.advisor_graph_edge_hints',
        ],
      },
      'age_projection_identity': <String, Object?>{
        'vertex_merge_pattern_keys': const <String>[
          'operator_id',
          'graph_scope',
          'graph_version',
          'node_id',
        ],
        'edge_merge_pattern_keys': const <String>[
          'operator_id',
          'graph_scope',
          'graph_version',
          'edge_id',
          'edge_key',
        ],
        'edge_endpoint_match_keys': const <String>[
          'operator_id',
          'graph_scope',
          'graph_version',
          'node_id',
        ],
        'rationale':
            'Canonical identity is (operator_id, graph_scope, '
            'graph_version, id) — UUID alone is not the identity. AGE '
            'MERGE keys carry the full tuple so two canonical rows '
            'with the same UUID across different tenants/scopes/'
            'versions stay separate vertices in AGE; edge endpoints '
            'MATCH on the same tuple so an edge can only attach to a '
            'vertex within its own canonical frame.',
      },
      'rebuild_files': <Map<String, Object?>>[
        <String, Object?>{
          'order': 1,
          'file': dropFileName,
          'role': _filter.isAllActive
              ? 'drop_age_label_graph'
              : 'drop_age_subgraph_for_scope_filter',
          'note': _filter.isAllActive
              ? 'Whole-graph drop via ag_catalog.drop_graph; every '
                  'projection in the AGE catalog is replaced.'
              : 'Bounded drop via Cypher DETACH DELETE — only the '
                  'matched (graph_scope[, graph_version]) subgraph is '
                  'removed. Untouched projections survive.',
        },
        <String, Object?>{
          'order': 2,
          'file': projectionFileName,
          'role': 'rebuild_age_label_graph',
          'note':
              'Rebuilds vertices/edges with composite-identity MERGE '
              '(operator_id, graph_scope, graph_version, node_id|edge_id) '
              'so cross-tenant / cross-scope / cross-version UUIDs do '
              'not collide.',
        },
        <String, Object?>{
          'order': 3,
          'file': smokeFileName,
          'role': 'smoke_byte_equivalence_check',
          'note':
              'Canonical-side and AGE-side digests both honor the '
              'scope filter so a bounded rebuild compares only the '
              'rebuilt subgraph.',
        },
        <String, Object?>{
          'order': 4,
          'file': tripwireFileName,
          'role': 'tripwire_health_check',
          'note':
              'Reads canonical tables directly with GROUP BY '
              '(operator_id, graph_scope, graph_version) so '
              'forge_admin BYPASSRLS sees per-tenant rows.',
        },
      ],
      'determinism': <String, Object?>{
        'cursor_order': const <String>[
          'operator_id',
          'graph_scope',
          'graph_version',
          'id',
        ],
        'rationale':
            'A re-run with identical canonical rows produces the same '
            'sequence of MERGE statements, supporting later staging '
            'byte-equivalence checks against the AGE projection.',
      },
      'canonical_safety': <String, Object?>{
        'mutates_canonical_rows': false,
        'mutates_age_projection': true,
        'mutates_graph_nodes_table': false,
        'mutates_graph_edges_table': false,
        'rebuild_artifacts_imply_canonical_mutation': false,
        'note':
            'The drop + rebuild SQL drops/recreates the AGE label graph '
            'only. graph_nodes and graph_edges rows are read-only inputs '
            'to the rebuild; per Q19 canonical truth lives in those '
            'tables. The tripwire artifact reads public.graph_nodes / '
            'public.graph_edges directly with GROUP BY (operator_id, '
            'graph_scope, graph_version) and never mutates canonical '
            'rows or the AGE projection. The migration\'s '
            'public.graph_health_metrics() function is NOT the '
            'tripwire read path (it aggregates across operator_id and '
            'is unsuitable for forge_admin views); it remains '
            'available as a tenant-scoped helper for ad-hoc queries.',
      },
      'tripwire_surface': <String, Object?>{
        // The rebuild's tripwire reads canonical tables directly with
        // GROUP BY (operator_id, graph_scope, graph_version) so
        // forge_admin sees per-tenant rows. The B42 manifest consumer
        // MUST follow `reads_from` + `aggregation_keys` (not the old
        // `function` field, which has been removed because pointing
        // a B42 implementation at public.graph_health_metrics() would
        // recreate the cross-tenant aggregation bug — that helper
        // groups by (graph_scope, graph_version) only and discards
        // operator_id). `tenant_scoped_helper_function` names the
        // migration's helper for ad-hoc tenant queries that do not
        // need operator-level rows.
        'reads_from': const <String>[
          'public.graph_nodes',
          'public.graph_edges',
        ],
        'aggregation_keys': const <String>[
          'operator_id',
          'graph_scope',
          'graph_version',
        ],
        'tenant_scoped_helper_function': 'public.graph_health_metrics()',
        'tenant_scoped_helper_function_warning':
            'public.graph_health_metrics() aggregates by '
            '(graph_scope, graph_version) only and discards '
            'operator_id. It is suitable for tenant-scoped ad-hoc '
            'queries (RLS scopes the read to one operator) but MUST '
            'NOT be used as the B42 forge_admin /health read path — '
            'the cross-tenant view requires operator-level rows '
            'which this helper cannot produce. B42 implementers '
            'follow `reads_from` + `aggregation_keys` above.',
        'yellow_threshold_active_edges': 3000000,
        'red_threshold_active_edges': 4000000,
        'status_values': const <String>['green', 'yellow', 'red'],
        'metadata_slots': const <String>[
          'last_projection_built_at',
          'last_benchmark_at',
        ],
        // B42 reserved metric key contract. The "active" set is
        // populated today by the canonical aggregation; the
        // "reserved_null_today" set is emitted as `<key>=null` in
        // every tripwire NOTICE so the proxy parser-side schema is
        // stable and a later benchmark / runtime telemetry slice can
        // flip individual keys to numeric without breaking 11A.5.
        'b42_health_metric_keys': const <String>[
          'graph_node_count',
          'graph_edge_count',
          'graph_active_edges_count',
          'graph_traversal_latency_ms',
          'graph_p95_traversal_latency_ms',
          'graph_timeout_rate',
          'graph_high_degree_count',
          'graph_last_projection_build_seconds_ago',
        ],
        'b42_health_metric_keys_active': const <String>[
          'graph_node_count',
          'graph_edge_count',
          'graph_active_edges_count',
        ],
        'b42_health_metric_keys_reserved_null_today': const <String>[
          'graph_traversal_latency_ms',
          'graph_p95_traversal_latency_ms',
          'graph_timeout_rate',
          'graph_high_degree_count',
          'graph_last_projection_build_seconds_ago',
        ],
        'notice_prefixes': const <String>[
          'AGE_TRIPWIRE',
          'AGE_TRIPWIRE_TOTALS',
          'AGE_TRIPWIRE_GREEN',
          'AGE_TRIPWIRE_YELLOW',
          'AGE_TRIPWIRE_RED',
        ],
        'forge_admin_per_tenant_rows': true,
        'note':
            'Yellow at 3,000,000 active edges per (operator_id, '
            'graph_scope, graph_version), red at 4,000,000. The '
            'reserved-null keys are populated by a later benchmark / '
            'runtime telemetry slice; the key names are part of the '
            'B42 contract today so the proxy /health route can wire '
            'against a stable schema. The B42 proxy /health route '
            'consumes the AGE_TRIPWIRE / AGE_TRIPWIRE_TOTALS notice '
            'shape directly so 11A.5 wiring reuses the same key names.',
      },
      'rebuild_validation_steps': const <Map<String, Object?>>[
        <String, Object?>{
          'order': 1,
          'name': 'preflight',
          'description':
              'Confirm runbook reviewed in this session, target '
              '(staging vs Production1) named explicitly, fresh '
              'restore point captured, and AGE extension allow-listed '
              'in Azure Flexible Server.',
        },
        <String, Object?>{
          'order': 2,
          'name': 'dry_run_artifacts',
          'description':
              'Run `dart run tool/graph_projection/main.dart '
              'prepare-rebuild` locally to regenerate the four SQL '
              'files plus this manifest. Confirm the rebuild_run_id '
              'matches a re-run (byte-determinism).',
        },
        <String, Object?>{
          'order': 3,
          'name': 'drop_age_projection',
          'description':
              'Apply 001_age_drop_projection.sql inside a tenant-scoped '
              'transaction. AGE_BLOCKER NOTICE → record the blocker as '
              'acceptance evidence and stop; vector-only retrieval '
              'remains the launch fallback.',
        },
        <String, Object?>{
          'order': 4,
          'name': 'rebuild_age_projection',
          'description':
              'Apply 002_age_rebuild_projection.sql. Confirm '
              'AGE_REBUILD_OK NOTICE with projected_nodes / '
              'projected_edges. Canonical rows must be untouched.',
        },
        <String, Object?>{
          'order': 5,
          'name': 'smoke_byte_equivalence',
          'description':
              'Apply 003_age_rebuild_smoke.sql. The B30 staging gate '
              'is "canonical and AGE digests match" — a digest '
              'mismatch fails the rebuild and the operator rolls back '
              'to the prior projection.',
        },
        <String, Object?>{
          'order': 6,
          'name': 'tripwire_health_check',
          'description':
              'Apply 004_age_rebuild_tripwire.sql. Capture the '
              'AGE_TRIPWIRE / AGE_TRIPWIRE_TOTALS NOTICE lines as '
              'acceptance evidence; the per-row terms are the B42 '
              '/health contract.',
        },
      ],
      'runbook_reference':
          'docs/phases/phase_9/phase_9_graph_projection_rebuild_runbook.md',
      'byte_equivalence_gate': <String, Object?>{
        'compares': const <String>[
          'canonical_node_digest',
          'canonical_edge_digest',
          'age_node_digest',
          'age_edge_digest',
        ],
        'algorithm': 'sha256',
        'identity_tuple_nodes': const <String>[
          'operator_id',
          'graph_scope',
          'graph_version',
          'id',
          'node_type',
          'node_key',
        ],
        'identity_tuple_edges': const <String>[
          'operator_id',
          'graph_scope',
          'graph_version',
          'id',
          'edge_type',
          'from_node_id',
          'to_node_id',
        ],
        'rationale':
            'Counts alone do not detect wrong endpoints, mislabeled edges, '
            'or invented/dropped rows. The B30 staging gate is "canonical '
            'and AGE digests match" computed over the identity tuple so '
            'any drift on either side surfaces as a digest mismatch.',
      },
      'blocker_path': <String, Object?>{
        'condition':
            "pg_available_extensions does not list extension name 'age'",
        'behavior':
            'rebuild artifacts RAISE NOTICE with the AGE_BLOCKER prefix '
            'and exit cleanly without mutating the database',
      },
      'notes': _manifestNotes(),
    };

    final manifestPath = p.join(output.path, manifestFileName);
    await File(
      manifestPath,
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));

    return GraphProjectionRebuildResult(
      outputDirectory: output.path,
      rebuildRunId: rebuildRunId,
      graphName: _graphName,
      graphScopeFilter: _graphScopeFilter,
      rebuildFiles: const <String>[
        dropFileName,
        projectionFileName,
        smokeFileName,
        tripwireFileName,
      ],
      manifestFile: manifestFileName,
    );
  }

  // ─── Generated SQL ────────────────────────────────────────────────

  String _dropSql() {
    final scopeDescription = _filter.description;
    final isAllActive = _filter.isAllActive;
    if (isAllActive) {
      return '''
-- Generated by tool/graph_projection prepare-rebuild.
-- Drops the Apache AGE label graph "$_graphName" so the rebuild step
-- can recreate it from canonical public.graph_nodes / public.graph_edges
-- rows. Build artifact only — do not apply without an explicit
-- live-mutation slice. Per Q19, canonical rows are NEVER mutated by
-- the rebuild; only the AGE projection is dropped and recreated.
--
-- Scope filter: $scopeDescription. The whole-graph drop path is the
-- right behavior for `all_active` because every projection is being
-- replaced; bounded scope filters use a Cypher DETACH DELETE that
-- targets only the matching (graph_scope, graph_version) subgraph.

do \$age_drop\$
declare
  age_present boolean;
  graph_name text := '$_graphName';
begin
  select exists (
    select 1 from pg_available_extensions where name = 'age'
  ) into age_present;

  if not age_present then
    raise notice
      'AGE_BLOCKER: Apache AGE extension is not available in this Postgres '
      'instance. Canonical graph rebuild cannot proceed locally. Record '
      'this blocker as the 9.0Σ.i acceptance evidence and continue with '
      'vector-only retrieval as the launch fallback until AGE is '
      'provisioned.';
    return;
  end if;

  execute 'create extension if not exists age';
  perform set_config('search_path', 'ag_catalog,"\$user",public', false);

  if exists (select 1 from ag_catalog.ag_graph where name = graph_name) then
    perform ag_catalog.drop_graph(graph_name, true);
    raise notice 'AGE_DROP_OK: graph="%" dropped (scope=all_active).',
      graph_name;
  else
    raise notice 'AGE_DROP_NOTE: graph="%" not present; nothing to drop.',
      graph_name;
  end if;
end;
\$age_drop\$;
''';
    }

    // Bounded-scope drop. We DO NOT call ag_catalog.drop_graph because
    // that would erase every projection — including operators / scopes /
    // versions the rebuild is NOT touching. Instead the script runs a
    // Cypher DETACH DELETE that targets only the matched
    // (graph_scope[, graph_version]) subgraph. Untouched projections
    // stay intact, so a `--scope=methodology:v3` rebuild only replaces
    // methodology v3 — which is the prior-version re-projection path
    // the runbook describes for rollback.
    final cypherWhereVertex = _filter.cypherPredicateFor('v');
    return '''
-- Generated by tool/graph_projection prepare-rebuild.
-- Bounded-scope drop of the Apache AGE label graph "$_graphName".
-- Build artifact only — do not apply without an explicit
-- live-mutation slice. Per Q19, canonical rows are NEVER mutated by
-- the rebuild; only the AGE projection vertices/edges that match the
-- scope filter are removed.
--
-- Scope filter: $scopeDescription.
--
-- This script intentionally does NOT call ag_catalog.drop_graph: that
-- helper drops every projection in the AGE catalog, which would erase
-- operators / scopes / versions the rebuild is not touching. The
-- DETACH DELETE below targets only the matched subgraph so untouched
-- projections survive the rebuild — that is the prior-version
-- re-projection / scope-bounded rollback path the runbook describes.

do \$age_drop\$
declare
  age_present boolean;
  graph_name text := '$_graphName';
  vertex_count_before bigint;
  vertex_count_after bigint;
begin
  select exists (
    select 1 from pg_available_extensions where name = 'age'
  ) into age_present;

  if not age_present then
    raise notice
      'AGE_BLOCKER: Apache AGE extension is not available in this Postgres '
      'instance. Canonical graph rebuild cannot proceed locally. Record '
      'this blocker as the 9.0Σ.i acceptance evidence and continue with '
      'vector-only retrieval as the launch fallback until AGE is '
      'provisioned.';
    return;
  end if;

  execute 'create extension if not exists age';
  perform set_config('search_path', 'ag_catalog,"\$user",public', false);

  if not exists (select 1 from ag_catalog.ag_graph where name = graph_name) then
    raise notice 'AGE_DROP_NOTE: graph="%" not present; nothing to drop.',
      graph_name;
    return;
  end if;

  -- Count matching vertices before the bounded delete so the operator
  -- can see what was removed.
  execute format(
    \$cy\$select count(*) from cypher(%L, \$cypher\$
      MATCH (v) $cypherWhereVertex
      RETURN v
    \$cypher\$) as (v agtype)\$cy\$,
    graph_name
  ) into vertex_count_before;

  -- DETACH DELETE removes the matched vertices and every edge
  -- attached to them in one pass; untouched vertices stay.
  execute format(
    \$cy\$select * from cypher(%L, \$cypher\$
      MATCH (v) $cypherWhereVertex
      DETACH DELETE v
    \$cypher\$) as (deleted agtype)\$cy\$,
    graph_name
  );

  execute format(
    \$cy\$select count(*) from cypher(%L, \$cypher\$
      MATCH (v) $cypherWhereVertex
      RETURN v
    \$cypher\$) as (v agtype)\$cy\$,
    graph_name
  ) into vertex_count_after;

  if vertex_count_after <> 0 then
    raise exception
      'AGE_DROP_INCOMPLETE: bounded drop left % matched vertices behind '
      '(scope filter: $scopeDescription). Investigate before rebuild.',
      vertex_count_after;
  end if;

  raise notice
    'AGE_DROP_OK: graph="%" bounded-scope drop complete '
    '(scope filter: $scopeDescription, vertices removed=%).',
    graph_name, vertex_count_before;
end;
\$age_drop\$;
''';
  }

  String _projectionSql() {
    final scopeDescription = _filter.description;
    final scopePredicate = _filter.sqlPredicateLines();
    return '''
-- Generated by tool/graph_projection prepare-rebuild.
-- Rebuilds the Apache AGE label graph "$_graphName" from canonical
-- public.graph_nodes / public.graph_edges rows. Build artifact only —
-- do not apply without an explicit live-mutation slice.
--
-- Scope filter: $scopeDescription.
--
-- Reads (active rows only):
--   public.graph_nodes  WHERE deleted_at IS NULL
--                         AND archived_at IS NULL
--                         AND active_from <= now()
--                         AND (active_to IS NULL OR active_to > now())
--                         [AND graph_scope = '<scope>'
--                          [AND graph_version = '<version>']]
--   public.graph_edges  WHERE deleted_at IS NULL
--                         AND archived_at IS NULL
--                         AND active_from <= now()
--                         AND (active_to IS NULL OR active_to > now())
--                         [AND graph_scope = '<scope>'
--                          [AND graph_version = '<version>']]
--
-- Writes (only when AGE is available):
--   ag_catalog graph "$_graphName" — vertex labels per node_type,
--   edge labels per edge_type. Canonical rows are NEVER mutated.
--
-- Identity: AGE vertices and edges are MERGEd on the canonical
-- composite identity tuple (operator_id, graph_scope, graph_version,
-- id) — NOT on UUID alone. This is required to keep cross-tenant /
-- cross-scope / cross-version projections from collapsing into a
-- single AGE node when their canonical UUIDs happen to align (the
-- canonical contract makes identity composite, not UUID-only).
-- Edge endpoints MATCH on the same composite tuple so an edge can
-- only attach to a vertex within its own canonical (operator, scope,
-- version) frame.
--
-- Determinism: every cursor orders by
-- (operator_id, graph_scope, graph_version, id) so a re-run with
-- identical canonical rows produces an identical Cypher sequence.
--
-- Blocker:
--   AGE missing -> RAISE NOTICE 'AGE_BLOCKER: ...' and exit cleanly.

do \$age_rebuild\$
declare
  age_present boolean;
  graph_name text := '$_graphName';
  rec record;
  cypher_query text;
  projected_node_count bigint := 0;
  projected_edge_count bigint := 0;
begin
  select exists (
    select 1 from pg_available_extensions where name = 'age'
  ) into age_present;

  if not age_present then
    raise notice
      'AGE_BLOCKER: Apache AGE extension is not available in this Postgres '
      'instance. Canonical graph rebuild cannot proceed locally.';
    return;
  end if;

  execute 'create extension if not exists age';
  perform set_config('search_path', 'ag_catalog,"\$user",public', false);

  if not exists (select 1 from ag_catalog.ag_graph where name = graph_name) then
    perform ag_catalog.create_graph(graph_name);
  end if;

  -- Project vertices from public.graph_nodes (active rows only).
  for rec in
    select
      operator_id,
      graph_scope,
      graph_version,
      id,
      node_key,
      node_type,
      properties
    from public.graph_nodes
    where deleted_at is null
      and archived_at is null
      and active_from <= now()
      and (active_to is null or active_to > now())
$scopePredicate    order by operator_id, graph_scope, graph_version, id
  loop
    if rec.node_type !~ '^[A-Za-z_][A-Za-z0-9_]*\$' then
      raise exception
        'AGE_REBUILD_INVALID_NODE_TYPE: % (id=%)',
        rec.node_type, rec.id;
    end if;
    -- Composite-identity MERGE: the pattern carries the full
    -- (operator_id, graph_scope, graph_version, node_id) tuple so
    -- two canonical rows with the same UUID across different
    -- tenants/scopes/versions stay separate vertices in AGE.
    cypher_query := format(
      'MERGE (v:%s {operator_id: %s, graph_scope: %s, '
      '             graph_version: %s, node_id: %s}) '
      'SET v.node_key = %s, '
      '    v.node_type = %s '
      'RETURN v',
      rec.node_type,
      quote_literal(rec.operator_id::text),
      quote_literal(rec.graph_scope),
      quote_literal(rec.graph_version),
      quote_literal(rec.id::text),
      quote_literal(rec.node_key),
      quote_literal(rec.node_type)
    );
    execute format(
      \$cy\$select * from cypher(%L, \$cypher\$%s\$cypher\$) as (v agtype)\$cy\$,
      graph_name,
      cypher_query
    );
    projected_node_count := projected_node_count + 1;
  end loop;

  -- Project edges from public.graph_edges (active rows only).
  for rec in
    select
      operator_id,
      graph_scope,
      graph_version,
      id,
      edge_key,
      edge_type,
      from_node_id,
      to_node_id
    from public.graph_edges
    where deleted_at is null
      and archived_at is null
      and active_from <= now()
      and (active_to is null or active_to > now())
$scopePredicate    order by operator_id, graph_scope, graph_version, id
  loop
    if rec.edge_type !~ '^[A-Za-z_][A-Za-z0-9_]*\$' then
      raise exception
        'AGE_REBUILD_INVALID_EDGE_TYPE: % (id=%)',
        rec.edge_type, rec.id;
    end if;
    -- Endpoint MATCH carries the full canonical identity tuple so an
    -- edge cannot attach to a same-UUID vertex from a different
    -- tenant/scope/version. The edge MERGE pattern itself is also
    -- composite so re-runs are idempotent within the bounded frame.
    cypher_query := format(
      'MATCH (a {operator_id: %s, graph_scope: %s, '
      '          graph_version: %s, node_id: %s}), '
      '      (b {operator_id: %s, graph_scope: %s, '
      '          graph_version: %s, node_id: %s}) '
      'MERGE (a)-[r:%s {operator_id: %s, graph_scope: %s, '
      '                 graph_version: %s, edge_id: %s, '
      '                 edge_key: %s}]->(b) '
      'SET r.edge_type = %s, '
      '    r.from_node_id = %s, '
      '    r.to_node_id = %s '
      'RETURN r',
      // MATCH a — (operator, scope, version, from_node_id):
      quote_literal(rec.operator_id::text),
      quote_literal(rec.graph_scope),
      quote_literal(rec.graph_version),
      quote_literal(rec.from_node_id::text),
      // MATCH b — (operator, scope, version, to_node_id):
      quote_literal(rec.operator_id::text),
      quote_literal(rec.graph_scope),
      quote_literal(rec.graph_version),
      quote_literal(rec.to_node_id::text),
      // Edge label:
      rec.edge_type,
      // Edge MERGE composite identity:
      quote_literal(rec.operator_id::text),
      quote_literal(rec.graph_scope),
      quote_literal(rec.graph_version),
      quote_literal(rec.id::text),
      quote_literal(rec.edge_key),
      // SET payload (edge_type repeats the label as a property so the
      // smoke can read it without depending on Cypher's `type(r)`
      // helper, which varies across AGE releases):
      quote_literal(rec.edge_type),
      quote_literal(rec.from_node_id::text),
      quote_literal(rec.to_node_id::text)
    );
    execute format(
      \$cy\$select * from cypher(%L, \$cypher\$%s\$cypher\$) as (e agtype)\$cy\$,
      graph_name,
      cypher_query
    );
    projected_edge_count := projected_edge_count + 1;
  end loop;

  raise notice
    'AGE_REBUILD_OK: graph="%" rebuilt from public.graph_nodes / '
    'public.graph_edges (canonical rows untouched, scope filter: '
    '$scopeDescription). projected_nodes=%, projected_edges=%.',
    graph_name, projected_node_count, projected_edge_count;
end;
\$age_rebuild\$;
''';
  }

  String _smokeSql() {
    final scopeDescription = _filter.description;
    final scopePredicate = _filter.sqlPredicateLines();
    final cypherWhereV = _filter.cypherPredicateFor('v');
    final cypherWhereR = _filter.cypherPredicateFor('r');
    return '''
-- Generated by tool/graph_projection prepare-rebuild.
-- Smoke / byte-equivalence verification artifact for the rebuilt AGE
-- label graph "$_graphName". Build artifact only — operator-run.
--
-- Scope filter: $scopeDescription. Canonical and AGE-side digests are
-- both narrowed to the same filter so a bounded rebuild's digest
-- match check is restricted to the scope/version actually rebuilt.
--
-- The smoke proves byte-equivalence between canonical truth and the
-- projected AGE label graph by:
--   1. Counting active rows on both sides (cheap structural check).
--   2. Computing TWO SHA-256 digests over the same identity tuple
--      `(operator_id|graph_scope|graph_version|id|type|...)` — once
--      against `public.graph_nodes` / `public.graph_edges` and once
--      against the AGE projection's stored properties. The digests
--      MUST match. A projection that drops an edge, invents an
--      edge, mislabels an edge, or wires the wrong endpoints would
--      change the AGE digest while leaving the canonical digest
--      untouched, so a count-only check is not sufficient and is
--      not the gate here.
--   3. RAISE NOTICEs the digests + a per-side mismatch banner so the
--      operator running the rebuild attaches the result to the
--      acceptance record. The B30 staging gate is "canonical and AGE
--      digests match"; counts alone do not satisfy it.
--
-- The AGE-side digest reads canonical-identity properties stamped
-- back onto every projected vertex (`v.operator_id, v.graph_scope,
-- v.graph_version, v.node_id, v.node_type, v.node_key`) and edge
-- (`r.operator_id, r.graph_scope, r.graph_version, r.edge_id,
-- r.edge_type, r.from_node_id, r.to_node_id`). The relationship
-- label set at MERGE time and the stamped `r.edge_type` property are
-- the same value by contract; reading the stamped property rather
-- than a Cypher relationship-label helper keeps the smoke
-- independent of whichever helper the local AGE runtime exposes
-- (Apache AGE documents `type` for relationship type retrieval, and
-- the older `label` form is not portable across releases). The
-- rebuild script in 002_age_rebuild_projection.sql is the contract
-- that puts those properties in place; changing one side without
-- the other will surface here as a digest mismatch.
--
-- Both digests order by the line value so AGE's natural traversal
-- order does not have to match the canonical cursor order — the
-- ordering is driven by the identity tuple's lexicographic prefix
-- (`operator_id|graph_scope|graph_version|id|...`) which encodes
-- the same canonical cursor key.
--
-- Blocker:
--   AGE missing -> RAISE NOTICE 'AGE_BLOCKER: ...' and exit cleanly.

do \$age_smoke\$
declare
  age_present boolean;
  graph_name text := '$_graphName';
  canonical_node_count bigint;
  canonical_edge_count bigint;
  age_node_count bigint;
  age_edge_count bigint;
  canonical_node_digest text;
  canonical_edge_digest text;
  age_node_digest text;
  age_edge_digest text;
begin
  select exists (
    select 1 from pg_available_extensions where name = 'age'
  ) into age_present;

  if not age_present then
    raise notice
      'AGE_BLOCKER: smoke cannot run because Apache AGE is not '
      'available in this Postgres instance.';
    return;
  end if;

  perform set_config('search_path', 'ag_catalog,"\$user",public', false);

  -- ─── Canonical-side counts + digests ─────────────────────────────
  select count(*) into canonical_node_count
  from public.graph_nodes
  where deleted_at is null
    and archived_at is null
    and active_from <= now()
    and (active_to is null or active_to > now())
$scopePredicate  ;

  select count(*) into canonical_edge_count
  from public.graph_edges
  where deleted_at is null
    and archived_at is null
    and active_from <= now()
    and (active_to is null or active_to > now())
$scopePredicate  ;

  with canonical_node_lines as (
    select operator_id::text || '|'
        || graph_scope || '|'
        || graph_version || '|'
        || id::text || '|'
        || node_type || '|'
        || node_key as line
    from public.graph_nodes
    where deleted_at is null
      and archived_at is null
      and active_from <= now()
      and (active_to is null or active_to > now())
$scopePredicate  ),
  ordered as (select line from canonical_node_lines order by line)
  select encode(
    digest(coalesce(string_agg(line, e'\\n'), ''), 'sha256'),
    'hex'
  )
  into canonical_node_digest
  from ordered;

  with canonical_edge_lines as (
    select operator_id::text || '|'
        || graph_scope || '|'
        || graph_version || '|'
        || id::text || '|'
        || edge_type || '|'
        || from_node_id::text || '|'
        || to_node_id::text as line
    from public.graph_edges
    where deleted_at is null
      and archived_at is null
      and active_from <= now()
      and (active_to is null or active_to > now())
$scopePredicate  ),
  ordered as (select line from canonical_edge_lines order by line)
  select encode(
    digest(coalesce(string_agg(line, e'\\n'), ''), 'sha256'),
    'hex'
  )
  into canonical_edge_digest
  from ordered;

  -- ─── AGE-side counts + digests ───────────────────────────────────
  -- AGE-side queries carry the same scope filter as the canonical
  -- side so a bounded rebuild's digest comparison is restricted to
  -- the matching subgraph.
  execute format(
    \$cy\$select count(*) from cypher(%L, \$cypher\$
      MATCH (v) $cypherWhereV
      RETURN v
    \$cypher\$) as (v agtype)\$cy\$,
    graph_name
  ) into age_node_count;

  execute format(
    \$cy\$select count(*) from cypher(%L, \$cypher\$
      MATCH ()-[r]->() $cypherWhereR
      RETURN r
    \$cypher\$) as (r agtype)\$cy\$,
    graph_name
  ) into age_edge_count;

  -- AGE-side node digest. trim(both '"' from agtype::text) strips the
  -- JSON quoting AGE wraps every text value in.
  execute format(
    \$cy\$
      with age_node_lines as (
        select
          trim(both '"' from (op::text)) || '|'
          || trim(both '"' from (gs::text)) || '|'
          || trim(both '"' from (gv::text)) || '|'
          || trim(both '"' from (nid::text)) || '|'
          || trim(both '"' from (nt::text)) || '|'
          || trim(both '"' from (nk::text)) as line
        from cypher(%L, \$cypher\$
          MATCH (v) $cypherWhereV
          RETURN
            v.operator_id,
            v.graph_scope,
            v.graph_version,
            v.node_id,
            v.node_type,
            v.node_key
        \$cypher\$) as (
          op agtype, gs agtype, gv agtype,
          nid agtype, nt agtype, nk agtype
        )
      ),
      ordered as (select line from age_node_lines order by line)
      select encode(
        digest(coalesce(string_agg(line, e'\\n'), ''), 'sha256'),
        'hex'
      )
      from ordered
    \$cy\$,
    graph_name
  ) into age_node_digest;

  -- Edge identity tuple is read entirely from stamped properties.
  -- The rebuild step stamps `r.edge_type` explicitly (mirroring how
  -- it stamps `v.node_type` on vertices) so the AGE-side digest never
  -- depends on whether the local AGE runtime exposes a Cypher helper
  -- for relationship type retrieval. The relationship label set at
  -- MERGE time and the stamped property are the same value by
  -- contract.
  execute format(
    \$cy\$
      with age_edge_lines as (
        select
          trim(both '"' from (op::text)) || '|'
          || trim(both '"' from (gs::text)) || '|'
          || trim(both '"' from (gv::text)) || '|'
          || trim(both '"' from (eid::text)) || '|'
          || trim(both '"' from (et::text)) || '|'
          || trim(both '"' from (fn::text)) || '|'
          || trim(both '"' from (tn::text)) as line
        from cypher(%L, \$cypher\$
          MATCH ()-[r]->() $cypherWhereR
          RETURN
            r.operator_id,
            r.graph_scope,
            r.graph_version,
            r.edge_id,
            r.edge_type,
            r.from_node_id,
            r.to_node_id
        \$cypher\$) as (
          op agtype, gs agtype, gv agtype,
          eid agtype, et agtype,
          fn agtype, tn agtype
        )
      ),
      ordered as (select line from age_edge_lines order by line)
      select encode(
        digest(coalesce(string_agg(line, e'\\n'), ''), 'sha256'),
        'hex'
      )
      from ordered
    \$cy\$,
    graph_name
  ) into age_edge_digest;

  -- ─── Report + mismatch raises ───────────────────────────────────
  raise notice
    'AGE_REBUILD_SMOKE_OK: graph="%", canonical_nodes=%, canonical_edges=%, '
    'age_nodes=%, age_edges=%, '
    'canonical_node_digest=%, canonical_edge_digest=%, '
    'age_node_digest=%, age_edge_digest=%.',
    graph_name,
    canonical_node_count,
    canonical_edge_count,
    age_node_count,
    age_edge_count,
    canonical_node_digest,
    canonical_edge_digest,
    age_node_digest,
    age_edge_digest;

  if age_node_count <> canonical_node_count then
    raise notice
      'AGE_REBUILD_SMOKE_MISMATCH: vertex count drift — canonical=% age=%.',
      canonical_node_count, age_node_count;
  end if;
  if age_edge_count <> canonical_edge_count then
    raise notice
      'AGE_REBUILD_SMOKE_MISMATCH: edge count drift — canonical=% age=%.',
      canonical_edge_count, age_edge_count;
  end if;

  -- The digest comparisons are the actual byte-equivalence gate.
  -- Counts above are necessary but NOT sufficient — wrong endpoints,
  -- wrong labels, or invented/dropped edges show up here.
  if age_node_digest is distinct from canonical_node_digest then
    raise notice
      'AGE_REBUILD_SMOKE_DIGEST_MISMATCH: node identity tuple drift — '
      'canonical=% age=%.',
      canonical_node_digest, age_node_digest;
  end if;
  if age_edge_digest is distinct from canonical_edge_digest then
    raise notice
      'AGE_REBUILD_SMOKE_DIGEST_MISMATCH: edge identity tuple drift — '
      'canonical=% age=%.',
      canonical_edge_digest, age_edge_digest;
  end if;
end;
\$age_smoke\$;
''';
  }

  String _tripwireSql() {
    final scopeDescription = _filter.description;
    final scopePredicate = _filter.sqlPredicateLines();
    return '''
-- Generated by tool/graph_projection prepare-rebuild.
-- Tripwire health check after a rebuild. Emits per-(operator_id,
-- graph_scope, graph_version) green/yellow/red status so the operator
-- running the rebuild has acceptance evidence for the Q19 thresholds.
--
-- Scope filter: $scopeDescription.
--
-- Yellow fires at 3,000,000 active edges in a single
-- (operator_id, graph_scope, graph_version) tuple
-- (yellow_threshold_active_edges = 3000000).
-- Red fires at 4,000,000 (red_threshold_active_edges = 4000000).
--
-- Operator-scoped read path: this script aggregates active rows
-- directly from public.graph_nodes / public.graph_edges with
-- GROUP BY (operator_id, graph_scope, graph_version). The migration
-- also exposes public.graph_health_metrics() for tenant-scoped helper
-- queries; that function aggregates by (graph_scope, graph_version)
-- and intentionally does NOT surface operator_id, so it is unsuitable
-- for forge_admin BYPASSRLS reads where one row per (operator,
-- scope, version) is required (B42 archived language calls this out
-- explicitly). The rebuild's tripwire reads canonical tables directly
-- so a forge_admin run sees per-tenant rows.
--
-- Operator-readable health-metric terms emitted (B42 contract — the
-- proxy /health route that 11A.5/11A.6 will consume reuses these key
-- names verbatim, so the tripwire NOTICE shape is the parsing target):
--
--   Active counts (filled today by the canonical aggregation):
--   * graph_node_count                 — active vertices for the row.
--   * graph_edge_count                 — active edges for the row.
--   * graph_active_edges_count         — Q19 tripwire-side active-edge
--                                        count (alias of edge_count
--                                        named to match the B44 metric
--                                        label so 11A.5 wiring reads
--                                        cleanly).
--
--   Reserved-but-null today (filled by a later benchmark / runtime
--   telemetry slice; key names are stable so the proxy parser-side
--   schema does not break when the values flip from null to numeric):
--   * graph_traversal_latency_ms
--   * graph_p95_traversal_latency_ms
--   * graph_timeout_rate
--   * graph_high_degree_count
--   * graph_last_projection_build_seconds_ago
--   * last_projection_built_at
--   * last_benchmark_at
--
--   Thresholds:
--   * yellow_at / yellow_threshold_active_edges = 3000000
--   * red_at    / red_threshold_active_edges    = 4000000
--
-- The roll-up NOTICE at the end emits the same terms in totaled form
-- (across all scopes / versions / operators returned by the cursor)
-- so a single grep pulls the cross-tenant summary for ad-hoc operator
-- review without re-parsing every per-row line.
--
-- Canonical-safety note: this script is read-only against
-- public.graph_nodes / public.graph_edges and never touches the AGE
-- projection.
--
-- Build artifact only — operator-run after the rebuild commits.

do \$age_tripwire\$
declare
  rec record;
  any_red boolean := false;
  any_yellow boolean := false;
  total_active_node_count bigint := 0;
  total_active_edge_count bigint := 0;
  row_count integer := 0;
  overall_status text;
begin
  for rec in
    with active_nodes as (
      select operator_id, graph_scope, graph_version,
             count(*)::bigint as cnt
      from public.graph_nodes
      where deleted_at is null
        and archived_at is null
        and active_from <= now()
        and (active_to is null or active_to > now())
$scopePredicate      group by operator_id, graph_scope, graph_version
    ),
    active_edges as (
      select operator_id, graph_scope, graph_version,
             count(*)::bigint as cnt
      from public.graph_edges
      where deleted_at is null
        and archived_at is null
        and active_from <= now()
        and (active_to is null or active_to > now())
$scopePredicate      group by operator_id, graph_scope, graph_version
    ),
    keys as (
      select operator_id, graph_scope, graph_version from active_nodes
      union
      select operator_id, graph_scope, graph_version from active_edges
    )
    select
      k.operator_id,
      k.graph_scope,
      k.graph_version,
      coalesce(n.cnt, 0)::bigint as active_node_count,
      coalesce(e.cnt, 0)::bigint as active_edge_count,
      3000000::bigint as yellow_threshold_active_edges,
      4000000::bigint as red_threshold_active_edges,
      case
        when coalesce(e.cnt, 0) >= 4000000 then 'red'
        when coalesce(e.cnt, 0) >= 3000000 then 'yellow'
        else 'green'
      end as status
    from keys k
    left join active_nodes n
      on n.operator_id = k.operator_id
     and n.graph_scope = k.graph_scope
     and n.graph_version = k.graph_version
    left join active_edges e
      on e.operator_id = k.operator_id
     and e.graph_scope = k.graph_scope
     and e.graph_version = k.graph_version
    order by k.operator_id, k.graph_scope, k.graph_version
  loop
    raise notice
      'AGE_TRIPWIRE: operator="%" scope="%" version="%" status=% '
      'graph_node_count=% graph_edge_count=% '
      'graph_active_edges_count=% '
      'graph_traversal_latency_ms=null '
      'graph_p95_traversal_latency_ms=null '
      'graph_timeout_rate=null '
      'graph_high_degree_count=null '
      'graph_last_projection_build_seconds_ago=null '
      'yellow_at=% red_at=% '
      'last_projection_built_at=null last_benchmark_at=null.',
      rec.operator_id,
      rec.graph_scope,
      rec.graph_version,
      rec.status,
      rec.active_node_count,
      rec.active_edge_count,
      rec.active_edge_count,
      rec.yellow_threshold_active_edges,
      rec.red_threshold_active_edges;
    total_active_node_count := total_active_node_count + rec.active_node_count;
    total_active_edge_count := total_active_edge_count + rec.active_edge_count;
    row_count := row_count + 1;
    if rec.status = 'red' then
      any_red := true;
    elsif rec.status = 'yellow' then
      any_yellow := true;
    end if;
  end loop;

  overall_status := case
    when any_red then 'red'
    when any_yellow then 'yellow'
    else 'green'
  end;

  -- Roll-up NOTICE — single line carrying the B42 health-metric keys
  -- in totaled form so a 11A.5 health surface (or any operator grep)
  -- can pull the cross-tenant summary without re-parsing every row.
  raise notice
    'AGE_TRIPWIRE_TOTALS: graph_node_count=% graph_edge_count=% '
    'graph_active_edges_count=% '
    'graph_traversal_latency_ms=null '
    'graph_p95_traversal_latency_ms=null '
    'graph_timeout_rate=null '
    'graph_high_degree_count=null '
    'graph_last_projection_build_seconds_ago=null '
    'yellow_threshold_active_edges=% red_threshold_active_edges=% '
    'operator_scope_version_row_count=% '
    'last_projection_built_at=null last_benchmark_at=null '
    'overall_status=%.',
    total_active_node_count,
    total_active_edge_count,
    total_active_edge_count,
    3000000,
    4000000,
    row_count,
    overall_status;

  if any_red then
    raise notice
      'AGE_TRIPWIRE_RED: at least one (operator, scope, version) row '
      'exceeds the 4M active-edge red line '
      '(red_threshold_active_edges=4000000). Follow Q19 rollover '
      'actions: repartition, archive stale edges, rebuild AGE, '
      'shadow-query, cut over only after validation. See '
      'docs/phases/phase_9/phase_9_graph_projection_rebuild_runbook.md.';
  elsif any_yellow then
    raise notice
      'AGE_TRIPWIRE_YELLOW: at least one (operator, scope, version) '
      'row is between 3M (yellow_threshold_active_edges=3000000) and '
      '4M (red_threshold_active_edges=4000000) active edges. Schedule '
      'the Q19 rollover plan before red fires. See '
      'docs/phases/phase_9/phase_9_graph_projection_rebuild_runbook.md.';
  else
    raise notice
      'AGE_TRIPWIRE_GREEN: all (operator, scope, version) rows below '
      'the 3M yellow line (yellow_threshold_active_edges=3000000).';
  end if;
end;
\$age_tripwire\$;
''';
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────

/// Parsed `--scope` flag. Three accepted shapes:
///   * `all_active` — sentinel; no SQL-level filter, every active row
///     under every (graph_scope, graph_version) is rebuilt.
///   * `<scope>` — bounded to a single canonical scope; every active
///     `graph_version` under that scope rebuilds.
///   * `<scope>:<version>` — bounded to a single canonical
///     (graph_scope, graph_version) tuple — the prior-version
///     re-projection path the runbook calls out.
///
/// Inputs are sanitized to `[A-Za-z0-9_-]` (and `.` in the version
/// segment, since version strings often look like `v1.2`) so the
/// emitted SQL/Cypher cannot smuggle injection. An invalid filter
/// throws `GraphProjectionException` at parse time.
class _ScopeFilter {
  const _ScopeFilter._({
    required this.isAllActive,
    required this.scope,
    required this.version,
  });

  final bool isAllActive;
  final String? scope;
  final String? version;

  static final _scopeOnly = RegExp(r'^[A-Za-z0-9_-]+$');
  static final _scopeAndVersion =
      RegExp(r'^([A-Za-z0-9_-]+):([A-Za-z0-9_.\-]+)$');

  factory _ScopeFilter.parse(String value) {
    if (value == defaultGraphScopeFilter) {
      return const _ScopeFilter._(
        isAllActive: true,
        scope: null,
        version: null,
      );
    }
    final tupleMatch = _scopeAndVersion.firstMatch(value);
    if (tupleMatch != null) {
      return _ScopeFilter._(
        isAllActive: false,
        scope: tupleMatch.group(1),
        version: tupleMatch.group(2),
      );
    }
    if (_scopeOnly.hasMatch(value)) {
      return _ScopeFilter._(
        isAllActive: false,
        scope: value,
        version: null,
      );
    }
    throw GraphProjectionException(
      'Invalid graph scope filter "$value". Expected "all_active" '
      'or "<scope>" or "<scope>:<version>" with [A-Za-z0-9_-] '
      'characters (`.` is also accepted in the version segment).',
    );
  }

  /// SQL `AND` predicate for canonical SELECTs against
  /// `public.graph_nodes` / `public.graph_edges`. Returns an empty
  /// string for `all_active`. The fragment is intentionally prefixed
  /// with `      and` so it slots cleanly into a multi-line `WHERE`
  /// clause without breaking byte-determinism alignment when the
  /// filter is the same across two preparer runs.
  String sqlPredicateLines() {
    if (isAllActive) return '';
    final buffer = StringBuffer();
    buffer.write("      and graph_scope = '$scope'\n");
    if (version != null) {
      buffer.write("      and graph_version = '$version'\n");
    }
    return buffer.toString();
  }

  /// Cypher `WHERE` predicate for AGE-side reads (smoke + bounded
  /// drop). Caller passes the alias (`v` or `r`) so the same parser
  /// handles both vertex and edge queries.
  String cypherPredicateFor(String alias) {
    if (isAllActive) return '';
    final buffer = StringBuffer();
    buffer.write("WHERE $alias.graph_scope = '$scope'");
    if (version != null) {
      buffer.write(" AND $alias.graph_version = '$version'");
    }
    return buffer.toString();
  }

  /// Cypher AND-prefix that slots after an existing WHERE. Used by
  /// the smoke when the WHERE is added downstream of a MATCH.
  String cypherAndFor(String alias) {
    if (isAllActive) return '';
    final buffer = StringBuffer();
    buffer.write("AND $alias.graph_scope = '$scope'");
    if (version != null) {
      buffer.write(" AND $alias.graph_version = '$version'");
    }
    return buffer.toString();
  }

  /// Operator-readable description used in NOTICEs and manifest text.
  String get description {
    if (isAllActive) return 'all active scopes/versions';
    if (version != null) return 'scope=$scope, version=$version';
    return 'scope=$scope, all versions';
  }

  /// Manifest-friendly Map.
  Map<String, Object?> toManifest() => <String, Object?>{
        'is_all_active': isAllActive,
        'scope': scope,
        'version': version,
        'description': description,
      };
}

List<String> _manifestNotes() {
  const note1 = 'This slice owns the rebuild artifact contract. '
      'Operator-side apply (running the generated SQL inside a tenant '
      'transaction) lands in a later slice once the live-mutation gate '
      'is open.';
  const note2 = 'The rebuild SQL references public.graph_nodes / '
      'public.graph_edges only. The older 7.57.4 advisor seed tables '
      'are out of scope for the canonical rebuild path and the '
      'manifest names them as forbidden inputs.';
  const note3 = 'The tripwire NOTICE shape is the B42 /health contract '
      'parsing target. The proxy route the 11A.5 / 11A.6 dashboards '
      'wire to (B42, queued) reads graph_node_count, graph_edge_count, '
      'graph_active_edges_count, and graph_traversal_latency_ms from '
      'the AGE_TRIPWIRE / AGE_TRIPWIRE_TOTALS lines — keep these key '
      'names stable when the route lands or 11A.5 will need to '
      'refactor.';
  const note4 = 'Runbook authority for operator-side apply lives at '
      'docs/phases/phase_9/phase_9_graph_projection_rebuild_runbook.md '
      '(when, preflight, dry-run, Production1 approval gate, execution '
      'outline, validation, rollback, and B42 consumption notes).';
  return const <String>[note1, note2, note3, note4];
}

String _sha256ForString(String value) =>
    sha256.convert(utf8.encode(value)).toString();

/// Same deterministic UUID shape the advisor_corpus tool uses so
/// downstream identifiers can be cross-checked with the same parser.
String _deterministicUuid(String seed) {
  final hex = _sha256ForString(seed);
  final chars = hex.substring(0, 32).split('');
  chars[12] = '5';
  chars[16] = 'a';
  final value = chars.join();
  return '${value.substring(0, 8)}-'
      '${value.substring(8, 12)}-'
      '${value.substring(12, 16)}-'
      '${value.substring(16, 20)}-'
      '${value.substring(20, 32)}';
}

class GraphProjectionException implements Exception {
  GraphProjectionException(this.message);

  final String message;

  @override
  String toString() => message;
}
