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
//   5. The tripwire surface (`public.graph_health_metrics()`) is
//      already declared in the migration; the rebuild SQL invokes it
//      on completion so the caller can record yellow/red status as
//      acceptance evidence.

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
        _graphScopeFilter = graphScopeFilter;

  final Directory _repoRoot;
  final String _graphName;
  final String _graphScopeFilter;

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
      'preparer_version': 1,
      'rebuild_run_id': rebuildRunId,
      'graph_name': _graphName,
      'graph_scope_filter': _graphScopeFilter,
      'apply_mode': 'not_applied_build_artifacts_only',
      'canonical_inputs': <String, Object?>{
        'graph_nodes_table': 'public.graph_nodes',
        'graph_edges_table': 'public.graph_edges',
        'active_filter': const <String>[
          'deleted_at IS NULL',
          'archived_at IS NULL',
          'active_from <= now()',
          '(active_to IS NULL OR active_to > now())',
        ],
        'forbidden_inputs': const <String>[
          'public.advisor_graph_node_seeds',
          'public.advisor_graph_edge_hints',
        ],
      },
      'rebuild_files': <Map<String, Object?>>[
        <String, Object?>{
          'order': 1,
          'file': dropFileName,
          'role': 'drop_age_label_graph',
        },
        <String, Object?>{
          'order': 2,
          'file': projectionFileName,
          'role': 'rebuild_age_label_graph',
        },
        <String, Object?>{
          'order': 3,
          'file': smokeFileName,
          'role': 'smoke_byte_equivalence_check',
        },
        <String, Object?>{
          'order': 4,
          'file': tripwireFileName,
          'role': 'tripwire_health_check',
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
        'note':
            'The drop + rebuild SQL drops/recreates the AGE label graph '
            'only. graph_nodes and graph_edges rows are read-only inputs '
            'to the rebuild; per Q19 canonical truth lives in those '
            'tables.',
      },
      'tripwire_surface': <String, Object?>{
        'function': 'public.graph_health_metrics()',
        'yellow_threshold_active_edges': 3000000,
        'red_threshold_active_edges': 4000000,
      },
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
    return '''
-- Generated by tool/graph_projection prepare-rebuild.
-- Drops the Apache AGE label graph "$_graphName" so the rebuild step
-- can recreate it from canonical public.graph_nodes / public.graph_edges
-- rows. Build artifact only — do not apply without an explicit
-- live-mutation slice. Per Q19, canonical rows are NEVER mutated by
-- the rebuild; only the AGE projection is dropped and recreated.

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
    raise notice 'AGE_DROP_OK: graph="%" dropped.', graph_name;
  else
    raise notice 'AGE_DROP_NOTE: graph="%" not present; nothing to drop.',
      graph_name;
  end if;
end;
\$age_drop\$;
''';
  }

  String _projectionSql() {
    return '''
-- Generated by tool/graph_projection prepare-rebuild.
-- Rebuilds the Apache AGE label graph "$_graphName" from canonical
-- public.graph_nodes / public.graph_edges rows. Build artifact only —
-- do not apply without an explicit live-mutation slice.
--
-- Reads (active rows only):
--   public.graph_nodes  WHERE deleted_at IS NULL
--                         AND archived_at IS NULL
--                         AND active_from <= now()
--                         AND (active_to IS NULL OR active_to > now())
--   public.graph_edges  WHERE deleted_at IS NULL
--                         AND archived_at IS NULL
--                         AND active_from <= now()
--                         AND (active_to IS NULL OR active_to > now())
--
-- Writes (only when AGE is available):
--   ag_catalog graph "$_graphName" — vertex labels per node_type,
--   edge labels per edge_type. Canonical rows are NEVER mutated.
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
    order by operator_id, graph_scope, graph_version, id
  loop
    if rec.node_type !~ '^[A-Za-z_][A-Za-z0-9_]*\$' then
      raise exception
        'AGE_REBUILD_INVALID_NODE_TYPE: % (id=%)',
        rec.node_type, rec.id;
    end if;
    cypher_query := format(
      'MERGE (v:%s {node_id: %s}) '
      'SET v.operator_id = %s, '
      '    v.graph_scope = %s, '
      '    v.graph_version = %s, '
      '    v.node_key = %s, '
      '    v.node_type = %s '
      'RETURN v',
      rec.node_type,
      quote_literal(rec.id::text),
      quote_literal(rec.operator_id::text),
      quote_literal(rec.graph_scope),
      quote_literal(rec.graph_version),
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
    order by operator_id, graph_scope, graph_version, id
  loop
    if rec.edge_type !~ '^[A-Za-z_][A-Za-z0-9_]*\$' then
      raise exception
        'AGE_REBUILD_INVALID_EDGE_TYPE: % (id=%)',
        rec.edge_type, rec.id;
    end if;
    cypher_query := format(
      'MATCH (a {node_id: %s}), (b {node_id: %s}) '
      'MERGE (a)-[r:%s {edge_id: %s, edge_key: %s}]->(b) '
      'SET r.operator_id = %s, '
      '    r.graph_scope = %s, '
      '    r.graph_version = %s, '
      '    r.edge_type = %s, '
      '    r.from_node_id = %s, '
      '    r.to_node_id = %s '
      'RETURN r',
      quote_literal(rec.from_node_id::text),
      quote_literal(rec.to_node_id::text),
      rec.edge_type,
      quote_literal(rec.id::text),
      quote_literal(rec.edge_key),
      quote_literal(rec.operator_id::text),
      quote_literal(rec.graph_scope),
      quote_literal(rec.graph_version),
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
    'public.graph_edges (canonical rows untouched). '
    'projected_nodes=%, projected_edges=%.',
    graph_name, projected_node_count, projected_edge_count;
end;
\$age_rebuild\$;
''';
  }

  String _smokeSql() {
    return '''
-- Generated by tool/graph_projection prepare-rebuild.
-- Smoke / byte-equivalence verification artifact for the rebuilt AGE
-- label graph "$_graphName". Build artifact only — operator-run.
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
    and (active_to is null or active_to > now());

  select count(*) into canonical_edge_count
  from public.graph_edges
  where deleted_at is null
    and archived_at is null
    and active_from <= now()
    and (active_to is null or active_to > now());

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
  ),
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
  ),
  ordered as (select line from canonical_edge_lines order by line)
  select encode(
    digest(coalesce(string_agg(line, e'\\n'), ''), 'sha256'),
    'hex'
  )
  into canonical_edge_digest
  from ordered;

  -- ─── AGE-side counts + digests ───────────────────────────────────
  execute format(
    \$cy\$select count(*) from cypher(%L, \$cypher\$
      MATCH (v) RETURN v
    \$cypher\$) as (v agtype)\$cy\$,
    graph_name
  ) into age_node_count;

  execute format(
    \$cy\$select count(*) from cypher(%L, \$cypher\$
      MATCH ()-[r]->() RETURN r
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
          MATCH (v)
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
          MATCH ()-[r]->()
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
    return '''
-- Generated by tool/graph_projection prepare-rebuild.
-- Tripwire health check after a rebuild. Reads the canonical
-- public.graph_health_metrics() function declared in
-- 202604280008_phase_9_0sigma_i_graph_canonical.sql and emits the
-- per-(scope, version) yellow/red status so the operator running the
-- rebuild has acceptance evidence for the Q19 thresholds.
--
-- Yellow fires at 3,000,000 active edges in a single scope/version.
-- Red fires at 4,000,000.
--
-- Build artifact only — operator-run after the rebuild commits.

do \$age_tripwire\$
declare
  rec record;
  any_red boolean := false;
  any_yellow boolean := false;
begin
  for rec in
    select
      graph_scope,
      graph_version,
      active_node_count,
      active_edge_count,
      yellow_threshold_active_edges,
      red_threshold_active_edges,
      status
    from public.graph_health_metrics()
    order by graph_scope, graph_version
  loop
    raise notice
      'AGE_TRIPWIRE: scope="%" version="%" status=% '
      'active_nodes=% active_edges=% yellow_at=% red_at=%.',
      rec.graph_scope,
      rec.graph_version,
      rec.status,
      rec.active_node_count,
      rec.active_edge_count,
      rec.yellow_threshold_active_edges,
      rec.red_threshold_active_edges;
    if rec.status = 'red' then
      any_red := true;
    elsif rec.status = 'yellow' then
      any_yellow := true;
    end if;
  end loop;

  if any_red then
    raise notice
      'AGE_TRIPWIRE_RED: at least one scope/version exceeds the 4M '
      'active-edge red line. Follow Q19 rollover actions: repartition, '
      'archive stale edges, rebuild AGE, shadow-query, cut over only '
      'after validation.';
  elsif any_yellow then
    raise notice
      'AGE_TRIPWIRE_YELLOW: at least one scope/version is between 3M '
      'and 4M active edges. Schedule the Q19 rollover plan before red '
      'fires.';
  else
    raise notice 'AGE_TRIPWIRE_GREEN: all scope/versions below the 3M yellow line.';
  end if;
end;
\$age_tripwire\$;
''';
  }
}

// ─── Helpers ──────────────────────────────────────────────────────────

List<String> _manifestNotes() {
  const note1 = 'This slice owns the rebuild artifact contract. '
      'Operator-side apply (running the generated SQL inside a tenant '
      'transaction) lands in a later slice once the live-mutation gate '
      'is open.';
  const note2 = 'The rebuild SQL references public.graph_nodes / '
      'public.graph_edges only. The older 7.57.4 advisor seed tables '
      'are out of scope for the canonical rebuild path and the '
      'manifest names them as forbidden inputs.';
  return const <String>[note1, note2];
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
