// Phase 9 B36 — cross-tenant RLS isolation integration test sweep.
//
// Sweeps every operator-scoped table the parallel-merge audit
// (`docs/phases/phase_9/phase_9_execution_backlog.md` B36) names and,
// for each, asserts:
//
//   * Cross-tenant SELECT under tenant SET LOCAL returns no rows.
//   * Cross-tenant INSERT under the other operator_id is rejected, or
//     writes zero rows; admin verification proves no forged row
//     exists.
//   * Cross-tenant UPDATE/DELETE is rejected, or affects zero rows;
//     admin verification proves the other tenant row remains intact.
//   * `forge_admin` emergency read path through
//     [TenantTransactionWrapper.runAsSystem] sees both tenants.
//   * EXPLAIN under service_role tenant context uses an index path
//     whose Index Cond / Index Name names `operator_id` — i.e. the
//     locked tenant-leading index posture (item 4 / RLS performance
//     discipline in
//     `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`).
//
// Both directions (Tenant A vs Tenant B and Tenant B vs Tenant A) are
// covered for every assertion.
//
// Tables covered (B36-named, even though the B36 prose mentions "11
// tables" while listing 13):
//   audit_logs, rollup_daypart, rollup_business_day, rollup_week,
//   rollup_accounting_period, rollup_month, rollup_quarter,
//   rollup_year, advisor_conversation_log, service_principals,
//   event_outbox, graph_nodes, graph_edges.
//
// PASSIVE BY DEFAULT. The whole sweep runs only when
// `FORGE_FLOW_RUN_STAGING_RLS_SWEEP=true` is set; without the flag
// the suite skips with a clear name-only reason. With the flag set
// but `POSTGRES_URL` or `POSTGRES_ADMIN_URL` missing, the suite fails
// fast with a BLOCKED-style preflight error that names ONLY the
// missing env names — values are never echoed. Live target is
// staging; Production1 is never touched.
//
// CLAUDE.md bindings:
//   * `package:postgres` is not imported here; all SQL flows through
//     `PackagePostgresPool` + `TenantTransactionWrapper`, so SET
//     LOCAL discipline holds and the rule against direct
//     `package:postgres` imports outside
//     `lib/infrastructure/persistence/postgres/` is preserved.
//   * Admin DSN is used only for fixture seed/cleanup; tenant checks
//     run through `runInTenantContext`, and forge_admin emergency
//     reads run through `runAsSystem`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

// ─── Fixture identifiers ─────────────────────────────────────────────
//
// `b36000…` namespace marks every fixture row so a manual cleanup on
// staging can be recognized at a glance and so the seed/cleanup helper
// has a deterministic predicate. Two operators, one location each, one
// org_unit each, two graph_nodes each (so an edge can connect two
// nodes within the same operator/scope/version).

const String _opA = 'b3600000-0000-0000-0000-0000000000a1';
const String _opB = 'b3600000-0000-0000-0000-0000000000b1';
const String _locA = 'b3600000-0000-0000-0000-0000000000a2';
const String _locB = 'b3600000-0000-0000-0000-0000000000b2';
const String _ouA = 'b3600000-0000-0000-0000-0000000000a3';
const String _ouB = 'b3600000-0000-0000-0000-0000000000b3';
const String _userA = 'b3600000-0000-0000-0000-0000000000a4';
const String _userB = 'b3600000-0000-0000-0000-0000000000b4';
const String _convA = 'b3600000-0000-0000-0000-0000000000a8';
const String _convB = 'b3600000-0000-0000-0000-0000000000b8';
const String _nodeA1 = 'b3600000-0000-0000-0000-0000000000a5';
const String _nodeA2 = 'b3600000-0000-0000-0000-0000000000a6';
const String _nodeB1 = 'b3600000-0000-0000-0000-0000000000b5';
const String _nodeB2 = 'b3600000-0000-0000-0000-0000000000b6';

const String _fixtureMarker = 'b36-rls-sweep';
const String _envFlag = 'FORGE_FLOW_RUN_STAGING_RLS_SWEEP';
const String _envPostgresUrl = 'POSTGRES_URL';
const String _envPostgresAdminUrl = 'POSTGRES_ADMIN_URL';

void main() {
  final flagRaw = Platform.environment[_envFlag] ?? '';
  final liveEnabled = flagRaw.toLowerCase() == 'true' || flagRaw == '1';

  if (!liveEnabled) {
    test(
      'B36 staging RLS isolation sweep (passive default)',
      () {
        // The skip below is the contract — body intentionally empty.
      },
      skip:
          'B36 sweep is passive by default. To run against staging '
          'Postgres, set $_envFlag=true and provide $_envPostgresUrl + '
          '$_envPostgresAdminUrl. Live target is staging only — never '
          'Production1.',
    );
    return;
  }

  final pgUrl = Platform.environment[_envPostgresUrl];
  final pgAdminUrl = Platform.environment[_envPostgresAdminUrl];
  final missingEnv = <String>[
    if (pgUrl == null || pgUrl.isEmpty) _envPostgresUrl,
    if (pgAdminUrl == null || pgAdminUrl.isEmpty) _envPostgresAdminUrl,
  ];
  if (missingEnv.isNotEmpty) {
    test('B36 staging RLS isolation sweep — env preflight', () {
      fail(
        'BLOCKED: $_envFlag is true but required env names are '
        'missing: ${missingEnv.join(', ')}. Source the staging env '
        'loader (scripts/use_postgres_staging_env.ps1) and re-run. '
        'No env values are echoed by this test.',
      );
    });
    return;
  }

  late PackagePostgresPool tenantPool;
  late PackagePostgresPool adminPool;
  late TenantTransactionWrapper tenantWrapper;

  setUpAll(() async {
    tenantPool = PackagePostgresPool.fromUrl(pgUrl!);
    adminPool = PackagePostgresPool.fromUrl(pgAdminUrl!);
    tenantWrapper = TenantTransactionWrapper(tenantPool);

    await _runAdmin(adminPool, _cleanupFixtures);
    await _runAdmin(adminPool, _seedBaseFixtures);
    await _runAdmin(adminPool, _seedTableRows);
  });

  tearDownAll(() async {
    await _runAdmin(adminPool, _cleanupFixtures);
  });

  final ctxA = TenantContext(
    operatorId: _opA,
    locationId: _locA,
    userId: _userA,
  );
  final ctxB = TenantContext(
    operatorId: _opB,
    locationId: _locB,
    userId: _userB,
  );

  for (final spec in _tableSpecs) {
    group('B36 RLS isolation — ${spec.name}', () {
      test('tenant A SELECT cannot see tenant B rows', () async {
        await _expectTenantSelectIsolated(
          wrapper: tenantWrapper,
          ctx: ctxA,
          spec: spec,
          otherOpId: _opB,
        );
      });

      test('tenant B SELECT cannot see tenant A rows', () async {
        await _expectTenantSelectIsolated(
          wrapper: tenantWrapper,
          ctx: ctxB,
          spec: spec,
          otherOpId: _opA,
        );
      });

      test(
        'tenant A INSERT under tenant B operator_id is rejected; '
        'admin verifies no forged row',
        () async {
          await _expectCrossTenantInsertRejected(
            wrapper: tenantWrapper,
            adminPool: adminPool,
            ctx: ctxA,
            spec: spec,
            crossOpId: _opB,
          );
        },
      );

      test(
        'tenant B INSERT under tenant A operator_id is rejected; '
        'admin verifies no forged row',
        () async {
          await _expectCrossTenantInsertRejected(
            wrapper: tenantWrapper,
            adminPool: adminPool,
            ctx: ctxB,
            spec: spec,
            crossOpId: _opA,
          );
        },
      );

      test(
        'tenant A UPDATE of tenant B rows is rejected or affects 0 '
        'rows; admin verifies B row intact',
        () async {
          await _expectCrossTenantUpdateBlocked(
            wrapper: tenantWrapper,
            adminPool: adminPool,
            ctx: ctxA,
            spec: spec,
            crossOpId: _opB,
          );
        },
      );

      test(
        'tenant B UPDATE of tenant A rows is rejected or affects 0 '
        'rows; admin verifies A row intact',
        () async {
          await _expectCrossTenantUpdateBlocked(
            wrapper: tenantWrapper,
            adminPool: adminPool,
            ctx: ctxB,
            spec: spec,
            crossOpId: _opA,
          );
        },
      );

      test(
        'tenant A DELETE of tenant B rows is rejected or affects 0 '
        'rows; admin verifies B row intact',
        () async {
          await _expectCrossTenantDeleteBlocked(
            wrapper: tenantWrapper,
            adminPool: adminPool,
            ctx: ctxA,
            spec: spec,
            crossOpId: _opB,
          );
        },
      );

      test(
        'tenant B DELETE of tenant A rows is rejected or affects 0 '
        'rows; admin verifies A row intact',
        () async {
          await _expectCrossTenantDeleteBlocked(
            wrapper: tenantWrapper,
            adminPool: adminPool,
            ctx: ctxB,
            spec: spec,
            crossOpId: _opA,
          );
        },
      );

      test(
        'forge_admin emergency read via runAsSystem sees both '
        'tenants',
        () async {
          await _expectForgeAdminEmergencyReadSeesBoth(
            wrapper: tenantWrapper,
            spec: spec,
          );
        },
      );

      test(
        'service_role tenant query uses tenant-leading operator_id '
        'index posture (no Seq Scan, Index Cond / Index Name names '
        'operator_id)',
        () async {
          await _expectTenantLeadingIndexPlan(
            wrapper: tenantWrapper,
            ctx: ctxA,
            spec: spec,
          );
        },
      );
    });
  }
}

// ─── Table specifications ────────────────────────────────────────────
//
// Each spec encodes the minimum INSERT shape, an UPDATE shape, a
// DELETE shape, a tenant-scope SELECT shape, and an EXPLAIN target
// for one B36-named table. Composite-FK tables (rollups, edges) carry
// extra parameters so the seed inserts wire them correctly.
//
// `tenantWriteable` says whether `service_role` has UPDATE/DELETE
// grants on the table; for read-only or append-only tables, the
// cross-tenant write attempt is expected to be rejected at the
// privilege layer rather than affect zero rows. Both outcomes satisfy
// the B36 acceptance.

class _TableSpec {
  const _TableSpec({
    required this.name,
    required this.insertSqlFor,
    required this.insertParamsFor,
    required this.crossInsertParamsFor,
    required this.updateSqlFor,
    required this.updateParamsFor,
    required this.deleteSqlFor,
    required this.deleteParamsFor,
    required this.markerColumn,
    required this.markerSeedValueFor,
    required this.markerNewValue,
  });

  final String name;
  // INSERT one fixture row owned by [opId]. Used by the seed helper.
  final String Function(String opId) insertSqlFor;
  final Map<String, Object?> Function(String opId) insertParamsFor;
  // Build INSERT params for a cross-tenant attempt: a row attributed
  // to [crossOpId] whose composite-FK dependencies (org_unit, location,
  // graph node endpoints, …) all belong to [crossOpId] so the foreign
  // keys *accept* the row. The marker column carries the *caller's*
  // seed value so admin-side verification can distinguish a forged
  // row from the cross tenant's own seed. Unique-keyed columns (e.g.
  // `graph_edges.edge_key`) are set to a cross-direction-distinct
  // value so the unique constraint cannot reject before WITH CHECK
  // gets a chance to fire. Without these wiring rules an FK or a
  // unique-collision would reject for the wrong reason and a broken
  // WITH CHECK could go undetected — which is the B36 review concern
  // this builder closes.
  final Map<String, Object?> Function(
    String callerOpId,
    String crossOpId,
  ) crossInsertParamsFor;
  // UPDATE the marker column on the row owned by [targetOpId].
  final String Function(String targetOpId) updateSqlFor;
  final Map<String, Object?> Function(String targetOpId) updateParamsFor;
  // DELETE the row owned by [targetOpId].
  final String Function(String targetOpId) deleteSqlFor;
  final Map<String, Object?> Function(String targetOpId) deleteParamsFor;
  // Column name to read for "row intact after attempted mutation"
  // checks. Choosing a non-PK column whose value the seed pins so the
  // verifier can compare before/after.
  final String markerColumn;
  // Seed value for the marker column for [opId] (so we can assert it
  // unchanged after a failed cross-tenant write).
  final Object Function(String opId) markerSeedValueFor;
  // Value the cross-tenant UPDATE would try to write. Picking a
  // distinct value so a successful (forbidden) write would be visible.
  final String markerNewValue;
}

const String _markerSeedAValue = '$_fixtureMarker:a';
const String _markerSeedBValue = '$_fixtureMarker:b';
const String _markerNewValue = '$_fixtureMarker:cross';

String _markerForOp(String opId) =>
    opId == _opA ? _markerSeedAValue : _markerSeedBValue;

// Cross-direction unique key. Two-char trailing slots in the fixture
// UUIDs (`…a1` / `…b1`) make the key easy to recognize on staging.
// Collisions are impossible by construction: every table's per-tenant
// unique key (`graph_*.{node_key,edge_key}`, `service_principals.name`)
// is namespaced by `(operator_id, …)`, so a cross-direction key like
// `b36_cross_a1_to_b1` cannot collide with the cross tenant's seed
// row (which uses `b36_seed_*` / `b36_*_n1` / etc) under the same
// operator_id.
String _crossKey(String callerOpId, String crossOpId) =>
    'b36_cross_${callerOpId.substring(34)}_to_${crossOpId.substring(34)}';

int _crossAdvisorTurnIndex(String callerOpId, String crossOpId) {
  if (callerOpId == _opA && crossOpId == _opB) return 101;
  if (callerOpId == _opB && crossOpId == _opA) return 102;
  throw ArgumentError.value(
    '$callerOpId -> $crossOpId',
    'callerOpId/crossOpId',
    'unsupported B36 cross-tenant direction',
  );
}

// Generic cross-tenant INSERT params builder: clone the *target*
// tenant's params (so every composite FK accepts the row) and
// override the marker column with the *caller's* marker so admin-
// side verification can spot a forged row distinct from the seed
// row. Tables whose unique key sits on a column other than the
// marker (graph_nodes.node_key, graph_edges.edge_key) layer their
// own override on top of this in their spec.
Map<String, Object?> _cloneTargetParamsWithCallerMarker({
  required Map<String, Object?> targetParams,
  required String markerColumn,
  required String callerOpId,
}) {
  final params = Map<String, Object?>.from(targetParams);
  params[markerColumn] = _markerForOp(callerOpId);
  return params;
}

// Rollup tables share the same INSERT shape; daypart adds the
// `daypart` column. Builders below render the SQL per table name so
// the spec list stays declarative.

String _rollupInsertSql(String tableName, {required bool isDaypart}) {
  final cols = <String>[
    'operator_id',
    'scoped_org_unit_id',
    'location_id',
    'period_start',
    'period_end',
    'business_date',
    if (isDaypart) 'daypart',
    'metric_family',
    'dimensions',
    'metrics',
    'rule_version',
  ];
  final values = <String>[
    '@operator_id::uuid',
    '@scoped_org_unit_id::uuid',
    '@location_id::uuid',
    '@period_start::timestamptz',
    '@period_end::timestamptz',
    '@business_date::date',
    if (isDaypart) '@daypart',
    '@metric_family',
    '@dimensions::jsonb',
    '@metrics::jsonb',
    '@rule_version',
  ];
  return 'insert into public.$tableName (${cols.join(', ')}) '
      'values (${values.join(', ')})';
}

Map<String, Object?> _rollupInsertParams(
  String opId, {
  required bool isDaypart,
}) {
  final ouId = opId == _opA ? _ouA : _ouB;
  final locId = opId == _opA ? _locA : _locB;
  return <String, Object?>{
    'operator_id': opId,
    'scoped_org_unit_id': ouId,
    'location_id': locId,
    'period_start': '2026-04-01T00:00:00Z',
    'period_end': '2026-04-02T00:00:00Z',
    'business_date': '2026-04-01',
    if (isDaypart) 'daypart': 'all',
    'metric_family': _markerForOp(opId),
    'dimensions': '{}',
    'metrics': '{}',
    'rule_version': 'b36',
  };
}

String _rollupUpdateSql(String tableName) =>
    'update public.$tableName '
    'set metric_family = @new_marker '
    'where operator_id = @target_op::uuid';

Map<String, Object?> _rollupUpdateParams(String targetOpId) =>
    <String, Object?>{
      'new_marker': _markerNewValue,
      'target_op': targetOpId,
    };

String _rollupDeleteSql(String tableName) =>
    'delete from public.$tableName '
    'where operator_id = @target_op::uuid';

Map<String, Object?> _rollupDeleteParams(String targetOpId) =>
    <String, Object?>{'target_op': targetOpId};

_TableSpec _rollupSpec(String tableName, {required bool isDaypart}) =>
    _TableSpec(
      name: tableName,
      insertSqlFor: (_) =>
          _rollupInsertSql(tableName, isDaypart: isDaypart),
      insertParamsFor: (opId) =>
          _rollupInsertParams(opId, isDaypart: isDaypart),
      // Rollup composite FKs pin (operator_id, scoped_org_unit_id) to
      // org_units and (operator_id, location_id) to locations. The
      // cross-INSERT row therefore uses crossOpId's own org_unit and
      // location IDs (cloned via _rollupInsertParams(crossOpId)) so
      // the FKs accept the row; a broken WITH CHECK has no FK alibi.
      crossInsertParamsFor: (callerOpId, crossOpId) =>
          _cloneTargetParamsWithCallerMarker(
        targetParams: _rollupInsertParams(crossOpId, isDaypart: isDaypart),
        markerColumn: 'metric_family',
        callerOpId: callerOpId,
      ),
      updateSqlFor: (_) => _rollupUpdateSql(tableName),
      updateParamsFor: _rollupUpdateParams,
      deleteSqlFor: (_) => _rollupDeleteSql(tableName),
      deleteParamsFor: _rollupDeleteParams,
      markerColumn: 'metric_family',
      markerSeedValueFor: _markerForOp,
      markerNewValue: _markerNewValue,
    );

final List<_TableSpec> _tableSpecs = <_TableSpec>[
  // ── audit_logs ──
  //
  // chain_date / occurred_at are computed inside the SQL using
  // `now()` so the row always lands in an active pg_partman daily
  // partition (premake = 7 means partitions exist for [today,
  // today + 7]; a hard-coded past date would fail with "no partition
  // of relation found for row"). The CHECK constraint
  // `chain_date = (occurred_at at time zone 'UTC')::date` holds
  // because every `now()` inside one statement returns the same
  // value.
  _TableSpec(
    name: 'audit_logs',
    insertSqlFor: (_) => 'insert into public.audit_logs ('
        'operator_id, location_id, chain_date, occurred_at, '
        'actor_kind, actor_user_id, action, payload, row_hash) '
        'values ('
        '@operator_id::uuid, @location_id::uuid, '
        "(now() at time zone 'UTC')::date, now(), "
        "'user', @actor_user_id::uuid, @action, "
        '@payload::jsonb, @row_hash)',
    insertParamsFor: _auditLogsInsertParams,
    // audit_logs.location_id has no composite FK and the table has
    // no per-tenant unique key (PK is bigserial id). The cross-tenant
    // attempt only needs to clear (a) operator_id FK to operators
    // (both seeded operators exist), and (b) the chain_date <->
    // occurred_at CHECK (handled by SQL-side now()). WITH CHECK is
    // therefore the sole barrier the policy must enforce.
    crossInsertParamsFor: (callerOpId, crossOpId) =>
        _cloneTargetParamsWithCallerMarker(
      targetParams: _auditLogsInsertParams(crossOpId),
      markerColumn: 'action',
      callerOpId: callerOpId,
    ),
    updateSqlFor: (_) => 'update public.audit_logs '
        'set action = @new_marker '
        'where operator_id = @target_op::uuid',
    updateParamsFor: (targetOpId) => <String, Object?>{
      'new_marker': _markerNewValue,
      'target_op': targetOpId,
    },
    deleteSqlFor: (_) => 'delete from public.audit_logs '
        'where operator_id = @target_op::uuid',
    deleteParamsFor: (targetOpId) => <String, Object?>{
      'target_op': targetOpId,
    },
    markerColumn: 'action',
    markerSeedValueFor: _markerForOp,
    markerNewValue: _markerNewValue,
  ),

  // ── rollup_* (7 grains) ──
  _rollupSpec('rollup_daypart', isDaypart: true),
  _rollupSpec('rollup_business_day', isDaypart: false),
  _rollupSpec('rollup_week', isDaypart: false),
  _rollupSpec('rollup_accounting_period', isDaypart: false),
  _rollupSpec('rollup_month', isDaypart: false),
  _rollupSpec('rollup_quarter', isDaypart: false),
  _rollupSpec('rollup_year', isDaypart: false),

  // ── advisor_conversation_log ──
  _TableSpec(
    name: 'advisor_conversation_log',
    insertSqlFor: (_) => 'insert into public.advisor_conversation_log ('
        'operator_id, location_id, user_id, conversation_id, '
        'turn_index, role, '
        'content_encrypted, content_iv, content_key_ref, '
        'content_hash, surface, usage_class) '
        'values ('
        '@operator_id::uuid, @location_id::uuid, @user_id::uuid, '
        '@conversation_id::uuid, '
        '@turn_index, @role, '
        '@content_encrypted, @content_iv, @content_key_ref, '
        '@content_hash, @surface, @usage_class)',
    insertParamsFor: _advisorLogInsertParams,
    // The composite FK (operator_id, location_id) → locations pins
    // the row's location to the SAME operator. The cross-INSERT row
    // therefore uses crossOpId's own location_id (cloned via
    // _advisorLogInsertParams(crossOpId)). The migration also has a
    // unique index on (operator_id, conversation_id, turn_index), so
    // the cross-attempt keeps the target tenant's conversation_id but
    // uses a direction-specific turn_index. That leaves WITH CHECK as
    // the only barrier for INSERT.
    crossInsertParamsFor: (callerOpId, crossOpId) {
      final params = _cloneTargetParamsWithCallerMarker(
        targetParams: _advisorLogInsertParams(crossOpId),
        markerColumn: 'surface',
        callerOpId: callerOpId,
      );
      params['turn_index'] = _crossAdvisorTurnIndex(callerOpId, crossOpId);
      return params;
    },
    // service_role lacks UPDATE/DELETE grants on this table; both
    // directions of the cross-tenant test will surface as privilege
    // rejection (caught and accepted by the helper).
    updateSqlFor: (_) => 'update public.advisor_conversation_log '
        'set surface = @new_marker '
        'where operator_id = @target_op::uuid',
    updateParamsFor: (targetOpId) => <String, Object?>{
      'new_marker': _markerNewValue,
      'target_op': targetOpId,
    },
    deleteSqlFor: (_) => 'delete from public.advisor_conversation_log '
        'where operator_id = @target_op::uuid',
    deleteParamsFor: (targetOpId) => <String, Object?>{
      'target_op': targetOpId,
    },
    markerColumn: 'surface',
    markerSeedValueFor: _markerForOp,
    markerNewValue: _markerNewValue,
  ),

  // ── service_principals ──
  _TableSpec(
    name: 'service_principals',
    insertSqlFor: (_) => 'insert into public.service_principals ('
        'operator_id, name, scopes) '
        'values (@operator_id::uuid, @name, @scopes::jsonb)',
    insertParamsFor: _servicePrincipalsInsertParams,
    // `name` is also the marker column AND the per-operator unique
    // key. Cloning the target's params then writing the caller's
    // marker into `name` is what we want here: the resulting row
    // carries operator_id=crossOpId AND name=<caller's marker>, so
    // (a) the unique constraint is fine (crossOpId's own seed has a
    //     different name — the cross tenant's own marker), and
    // (b) admin-side verification can find the forged row by
    //     looking for crossOpId rows that carry the *caller's*
    //     marker.
    crossInsertParamsFor: (callerOpId, crossOpId) =>
        _cloneTargetParamsWithCallerMarker(
      targetParams: _servicePrincipalsInsertParams(crossOpId),
      markerColumn: 'name',
      callerOpId: callerOpId,
    ),
    updateSqlFor: (_) => 'update public.service_principals '
        'set name = @new_marker '
        'where operator_id = @target_op::uuid',
    updateParamsFor: (targetOpId) => <String, Object?>{
      'new_marker': _markerNewValue,
      'target_op': targetOpId,
    },
    deleteSqlFor: (_) => 'delete from public.service_principals '
        'where operator_id = @target_op::uuid',
    deleteParamsFor: (targetOpId) => <String, Object?>{
      'target_op': targetOpId,
    },
    markerColumn: 'name',
    markerSeedValueFor: _markerForOp,
    markerNewValue: _markerNewValue,
  ),

  // ── event_outbox ──
  _TableSpec(
    name: 'event_outbox',
    insertSqlFor: (_) => 'insert into public.event_outbox ('
        'operator_id, topic, payload) '
        'values (@operator_id::uuid, @topic, @payload::jsonb)',
    insertParamsFor: _eventOutboxInsertParams,
    // Only operator_id is FK'd (to operators). No per-tenant unique
    // key (PK is bigserial id). The cross-INSERT row attributes to
    // crossOpId and tags `topic` with the caller's marker so admin
    // verification can detect any forged row.
    crossInsertParamsFor: (callerOpId, crossOpId) =>
        _cloneTargetParamsWithCallerMarker(
      targetParams: _eventOutboxInsertParams(crossOpId),
      markerColumn: 'topic',
      callerOpId: callerOpId,
    ),
    updateSqlFor: (_) => 'update public.event_outbox '
        'set topic = @new_marker '
        'where operator_id = @target_op::uuid',
    updateParamsFor: (targetOpId) => <String, Object?>{
      'new_marker': _markerNewValue,
      'target_op': targetOpId,
    },
    deleteSqlFor: (_) => 'delete from public.event_outbox '
        'where operator_id = @target_op::uuid',
    deleteParamsFor: (targetOpId) => <String, Object?>{
      'target_op': targetOpId,
    },
    markerColumn: 'topic',
    markerSeedValueFor: _markerForOp,
    markerNewValue: _markerNewValue,
  ),

  // ── graph_nodes ──
  _TableSpec(
    name: 'graph_nodes',
    insertSqlFor: (_) => 'insert into public.graph_nodes ('
        'operator_id, graph_scope, graph_version, node_key, node_type) '
        'values ('
        '@operator_id::uuid, @graph_scope, @graph_version, '
        '@node_key, @node_type)',
    // graph_nodes seed lands in _seedBaseFixtures (edge endpoints +
    // marker nodes); insertParamsFor here is consumed only by
    // crossInsertParamsFor below, but we still produce a coherent
    // shape so a future caller can use it to seed another node.
    insertParamsFor: _graphNodeInsertParams,
    // Per-tenant unique key is (operator_id, graph_scope,
    // graph_version, node_key). The cross-INSERT swaps node_key to a
    // direction-distinct cross-key so it cannot collide with the
    // crossOpId-seeded `b36_*_n1/n2/marker` rows or with a prior
    // sweep run's residue. node_type carries the caller's marker so
    // admin verification can spot a forged row.
    crossInsertParamsFor: (callerOpId, crossOpId) {
      final params = _graphNodeInsertParams(crossOpId);
      params['node_key'] = _crossKey(callerOpId, crossOpId);
      params['node_type'] = _markerForOp(callerOpId);
      return params;
    },
    updateSqlFor: (_) => 'update public.graph_nodes '
        'set node_type = @new_marker '
        'where operator_id = @target_op::uuid',
    updateParamsFor: (targetOpId) => <String, Object?>{
      'new_marker': _markerNewValue,
      'target_op': targetOpId,
    },
    deleteSqlFor: (_) => 'delete from public.graph_nodes '
        'where operator_id = @target_op::uuid '
        'and node_key = @marker_node_key',
    deleteParamsFor: (targetOpId) => <String, Object?>{
      'target_op': targetOpId,
      // Only delete the marker node, not the edge endpoints — the
      // graph_edges spec depends on the endpoint nodes staying alive
      // so its own DELETE direction still has a row to point at.
      'marker_node_key': targetOpId == _opA ? 'b36_a_marker' : 'b36_b_marker',
    },
    markerColumn: 'node_type',
    markerSeedValueFor: _markerForOp,
    markerNewValue: _markerNewValue,
  ),

  // ── graph_edges ──
  //
  // The seed (`b36_seed_a` / `b36_seed_b`) and the cross-INSERT
  // attempts (`b36_cross_a1_to_b1` / `b36_cross_b1_to_a1`) live in
  // disjoint namespaces, so the per-operator unique constraint on
  // `(operator_id, graph_scope, graph_version, edge_key)` cannot
  // reject the cross-INSERT for a unique-collision reason — only
  // WITH CHECK can. The composite FKs to `graph_nodes` (endpoints)
  // are also satisfied by cloning crossOpId's params (its endpoint
  // nodes already exist in the seed under (crossOpId, b36, v1)).
  _TableSpec(
    name: 'graph_edges',
    insertSqlFor: (_) => 'insert into public.graph_edges ('
        'operator_id, graph_scope, graph_version, edge_key, '
        'edge_type, from_node_id, to_node_id) '
        'values ('
        '@operator_id::uuid, @graph_scope, @graph_version, '
        '@edge_key, @edge_type, @from_node::uuid, @to_node::uuid)',
    insertParamsFor: _graphEdgeInsertParams,
    // Cross-INSERT: clone crossOpId's params (endpoint nodes are
    // crossOpId's, so the composite FK passes), then override
    // edge_key with a cross-direction-distinct value (so the unique
    // constraint cannot reject) and edge_type with the caller's
    // marker (so admin verification can spot a forged row).
    crossInsertParamsFor: (callerOpId, crossOpId) {
      final params = _graphEdgeInsertParams(crossOpId);
      params['edge_key'] = _crossKey(callerOpId, crossOpId);
      params['edge_type'] = _markerForOp(callerOpId);
      return params;
    },
    updateSqlFor: (_) => 'update public.graph_edges '
        'set edge_type = @new_marker '
        'where operator_id = @target_op::uuid',
    updateParamsFor: (targetOpId) => <String, Object?>{
      'new_marker': _markerNewValue,
      'target_op': targetOpId,
    },
    deleteSqlFor: (_) => 'delete from public.graph_edges '
        'where operator_id = @target_op::uuid',
    deleteParamsFor: (targetOpId) => <String, Object?>{
      'target_op': targetOpId,
    },
    markerColumn: 'edge_type',
    markerSeedValueFor: _markerForOp,
    markerNewValue: _markerNewValue,
  ),
];

// ─── Per-table insertParams helpers ────────────────────────────────
//
// Factored out so each spec's `crossInsertParamsFor` can clone the
// *target* tenant's params via the same builder that produces the
// seed shape — no risk of drift between seed-time IDs and cross-
// tenant-time IDs.

Map<String, Object?> _auditLogsInsertParams(String opId) {
  final locId = opId == _opA ? _locA : _locB;
  final userId = opId == _opA ? _userA : _userB;
  return <String, Object?>{
    'operator_id': opId,
    'location_id': locId,
    'actor_user_id': userId,
    'action': _markerForOp(opId),
    'payload': '{"b36": "${_markerForOp(opId)}"}',
    // bytea — overwritten by the BEFORE INSERT trigger; we still
    // pass a non-null placeholder so the column-NOT-NULL check is
    // satisfied for any environment where the trigger is somehow
    // disabled (a reviewer-friendly belt-and-braces seed).
    'row_hash': <int>[0],
  };
}

Map<String, Object?> _advisorLogInsertParams(String opId) {
  final locId = opId == _opA ? _locA : _locB;
  final userId = opId == _opA ? _userA : _userB;
  final convId = opId == _opA ? _convA : _convB;
  return <String, Object?>{
    'operator_id': opId,
    'location_id': locId,
    'user_id': userId,
    'conversation_id': convId,
    'turn_index': 0,
    'role': 'user',
    'content_encrypted': <int>[1, 2, 3],
    'content_iv': <int>[4, 5, 6],
    'content_key_ref': 'b36-key/v1',
    'content_hash': '0' * 64,
    'surface': _markerForOp(opId),
    'usage_class': 'advisor.b36',
  };
}

Map<String, Object?> _servicePrincipalsInsertParams(String opId) =>
    <String, Object?>{
      'operator_id': opId,
      'name': _markerForOp(opId),
      'scopes': '[]',
    };

Map<String, Object?> _eventOutboxInsertParams(String opId) =>
    <String, Object?>{
      'operator_id': opId,
      'topic': _markerForOp(opId),
      'payload': '{"b36": "${_markerForOp(opId)}"}',
    };

Map<String, Object?> _graphNodeInsertParams(String opId) {
  // Used only by crossInsertParamsFor (graph_nodes seed lives in
  // _seedBaseFixtures); the node_key here is overridden in the cross
  // builder to a direction-distinct value.
  final shortTail = opId == _opA ? 'a1' : 'b1';
  return <String, Object?>{
    'operator_id': opId,
    'graph_scope': 'b36',
    'graph_version': 'v1',
    'node_key': 'b36_node_$shortTail',
    'node_type': _markerForOp(opId),
  };
}

Map<String, Object?> _graphEdgeInsertParams(String opId) {
  final fromNode = opId == _opA ? _nodeA1 : _nodeB1;
  final toNode = opId == _opA ? _nodeA2 : _nodeB2;
  final shortTail = opId == _opA ? 'a1' : 'b1';
  return <String, Object?>{
    'operator_id': opId,
    'graph_scope': 'b36',
    'graph_version': 'v1',
    'edge_key': 'b36_seed_$shortTail',
    'edge_type': _markerForOp(opId),
    'from_node': fromNode,
    'to_node': toNode,
  };
}

// ─── Admin helpers (POSTGRES_ADMIN_URL — fixture seed/cleanup only) ─

Future<void> _runAdmin(
  PostgresPool pool,
  Future<void> Function(PostgresExecutor exec) body,
) async {
  // POSTGRES_ADMIN_URL connects as the deployment role (the migration
  // owner; see scripts/postgres_staging_setup.ps1). Table owners are
  // exempt from RLS unless the table sets `force row level security`,
  // which none of the B36-named tables do. The owner is also exempt
  // from explicit GRANT/REVOKE on its own tables — important here
  // because `audit_logs`/`audit_chain_anchors` REVOKE UPDATE/DELETE
  // from `forge_admin` (the append-only posture), so issuing
  // `SET LOCAL ROLE forge_admin` would actually weaken the admin
  // transaction's privilege set and the cleanup DELETE would fail.
  // We deliberately rely on the deployment role's natural owner
  // privileges and write a single audit marker so any audit trigger
  // that observes `app.bypass_rls_audit` records the admin scope.
  final tx = await pool.beginTransaction();
  var finalized = false;
  try {
    await tx.execute(
      "select set_config('app.bypass_rls_audit', "
      "'system:b36_rls_sweep_fixture', true)",
    );
    await body(tx);
    await tx.commit();
    finalized = true;
  } finally {
    if (!finalized) {
      try {
        await tx.rollback();
      } catch (_) {
        // Swallow rollback secondary failure; the original error is
        // more useful.
      }
    }
  }
}

Future<void> _cleanupFixtures(PostgresExecutor exec) async {
  // Order matters because of FK chains: graph_edges → graph_nodes,
  // rollup_* → org_units/locations, advisor_conversation_log →
  // locations, audit_logs → operators (cascade). Delete the heaviest
  // dependents first, then operators (which cascades through the
  // remaining operator-scoped tables). Idempotent.
  Future<void> deleteFor(String table) async {
    await exec.execute(
      'delete from public.$table where operator_id::text in '
      "('$_opA', '$_opB')",
    );
  }

  const tables = <String>[
    'graph_edges',
    'graph_nodes',
    'audit_logs',
    'event_outbox',
    'service_principals',
    'advisor_conversation_log',
    'rollup_daypart',
    'rollup_business_day',
    'rollup_week',
    'rollup_accounting_period',
    'rollup_month',
    'rollup_quarter',
    'rollup_year',
    'org_units',
    'locations',
    'operators',
  ];
  for (final table in tables) {
    await deleteFor(table);
  }
}

Future<void> _seedBaseFixtures(PostgresExecutor exec) async {
  // Make sure today's pg_partman daily partition exists for
  // partitioned tables that have no DEFAULT partition (audit_logs).
  // Best-effort: if pg_partman is somehow unavailable on the host the
  // call fails and the audit_logs INSERT below will surface the real
  // partition error directly — which is the correct user-facing
  // signal — instead of the seeded row landing in a wrong partition.
  try {
    await exec.execute(
      'select public.run_maintenance(p_analyze := true)',
    );
  } catch (_) {
    // Intentional swallow — see comment above.
  }

  // Operators, locations, org_units, marker graph_nodes (incl.
  // edge endpoints + a separate per-operator "marker" node the
  // graph_nodes DELETE direction targets so the edge endpoints
  // survive the test).
  final operators = <List<String>>[
    <String>[_opA, 'B36 RLS Sweep Tenant A'],
    <String>[_opB, 'B36 RLS Sweep Tenant B'],
  ];
  for (final op in operators) {
    await exec.execute(
      'insert into public.operators '
      '(operator_id, business_name, owner_email) '
      'values (@id::uuid, @name, @email) '
      'on conflict (operator_id) do nothing',
      parameters: <String, Object?>{
        'id': op[0],
        'name': op[1],
        'email': '${op[0]}@b36-rls-sweep.invalid',
      },
    );
  }

  final locations = <List<String>>[
    <String>[_opA, _locA, 'B36 Location A'],
    <String>[_opB, _locB, 'B36 Location B'],
  ];
  for (final loc in locations) {
    await exec.execute(
      'insert into public.locations '
      '(location_id, operator_id, name, timezone, '
      'business_day_rollover_hour) '
      'values (@locId::uuid, @opId::uuid, @name, @tz, @rollover) '
      'on conflict (location_id) do nothing',
      parameters: <String, Object?>{
        'locId': loc[1],
        'opId': loc[0],
        'name': loc[2],
        'tz': 'America/Toronto',
        'rollover': 4,
      },
    );
  }

  final orgUnits = <List<String>>[
    <String>[_opA, _ouA, 'b36_a'],
    <String>[_opB, _ouB, 'b36_b'],
  ];
  for (final ou in orgUnits) {
    await exec.execute(
      'insert into public.org_units '
      "(id, operator_id, parent_id, unit_type, path, name) "
      "values (@id::uuid, @opId::uuid, null, 'corp', "
      '@path::ltree, @name) '
      'on conflict (id) do nothing',
      parameters: <String, Object?>{
        'id': ou[1],
        'opId': ou[0],
        'path': ou[2],
        'name': 'B36 ${ou[2]}',
      },
    );
  }

  // Edge-endpoint nodes (used by graph_edges seed + tests) plus a
  // separate "marker" node per operator that the graph_nodes DELETE
  // direction targets so the edge endpoints stay alive.
  final nodes = <Map<String, Object?>>[
    <String, Object?>{
      'id': _nodeA1,
      'operator_id': _opA,
      'node_key': 'b36_a_n1',
      'node_type': _markerSeedAValue,
    },
    <String, Object?>{
      'id': _nodeA2,
      'operator_id': _opA,
      'node_key': 'b36_a_n2',
      'node_type': _markerSeedAValue,
    },
    <String, Object?>{
      'id': _nodeB1,
      'operator_id': _opB,
      'node_key': 'b36_b_n1',
      'node_type': _markerSeedBValue,
    },
    <String, Object?>{
      'id': _nodeB2,
      'operator_id': _opB,
      'node_key': 'b36_b_n2',
      'node_type': _markerSeedBValue,
    },
    // Marker nodes (graph_nodes DELETE direction target). Distinct
    // from the edge endpoints so the edges stay valid.
    <String, Object?>{
      'id': null,
      'operator_id': _opA,
      'node_key': 'b36_a_marker',
      'node_type': _markerSeedAValue,
    },
    <String, Object?>{
      'id': null,
      'operator_id': _opB,
      'node_key': 'b36_b_marker',
      'node_type': _markerSeedBValue,
    },
  ];
  for (final n in nodes) {
    final id = n['id'];
    if (id == null) {
      // Marker node — let PG generate the id via default.
      await exec.execute(
        'insert into public.graph_nodes '
        '(operator_id, graph_scope, graph_version, node_key, '
        'node_type) '
        "values (@operator_id::uuid, 'b36', 'v1', "
        '@node_key, @node_type) '
        'on conflict (operator_id, graph_scope, graph_version, '
        'node_key) do nothing',
        parameters: <String, Object?>{
          'operator_id': n['operator_id'],
          'node_key': n['node_key'],
          'node_type': n['node_type'],
        },
      );
    } else {
      await exec.execute(
        'insert into public.graph_nodes '
        '(id, operator_id, graph_scope, graph_version, node_key, '
        'node_type) '
        "values (@id::uuid, @operator_id::uuid, 'b36', 'v1', "
        '@node_key, @node_type) '
        'on conflict (operator_id, graph_scope, graph_version, '
        'node_key) do nothing',
        parameters: <String, Object?>{
          'id': id,
          'operator_id': n['operator_id'],
          'node_key': n['node_key'],
          'node_type': n['node_type'],
        },
      );
    }
  }
}

Future<void> _seedTableRows(PostgresExecutor exec) async {
  // Insert one fixture row per operator into every B36-named table,
  // using the spec's own INSERT shape. Wrapping in
  // `on conflict do nothing` is not portable across all spec INSERTs
  // (some tables have generated PKs / partition routing), so the seed
  // assumes _cleanupFixtures has already cleared the slate.
  for (final spec in _tableSpecs) {
    if (spec.name == 'graph_nodes') {
      // Already seeded by _seedBaseFixtures so the graph_edges seed
      // can reference them. Skip the spec's own seed here to avoid
      // a conflict.
      continue;
    }
    for (final opId in <String>[_opA, _opB]) {
      await exec.execute(
        spec.insertSqlFor(opId),
        parameters: spec.insertParamsFor(opId),
      );
    }
  }
}

// ─── Tenant-scope assertions ────────────────────────────────────────

Future<void> _expectTenantSelectIsolated({
  required TenantTransactionWrapper wrapper,
  required TenantContext ctx,
  required _TableSpec spec,
  required String otherOpId,
}) async {
  final rows = await wrapper.runInTenantContext<List<PostgresRow>>(
    ctx,
    (exec) => exec.query(
      'select count(*)::bigint as cnt from public.${spec.name} '
      'where operator_id = @other_op::uuid',
      parameters: <String, Object?>{'other_op': otherOpId},
    ),
  );
  expect(rows, hasLength(1));
  final cnt = (rows.single['cnt'] as int?) ??
      int.tryParse('${rows.single['cnt']}');
  expect(
    cnt,
    equals(0),
    reason:
        '${spec.name}: tenant SET LOCAL = ${ctx.operatorId} must not see '
        'rows owned by $otherOpId — RLS USING predicate filters them '
        'out before they reach the WHERE clause.',
  );
}

Future<void> _expectCrossTenantInsertRejected({
  required TenantTransactionWrapper wrapper,
  required PackagePostgresPool adminPool,
  required TenantContext ctx,
  required _TableSpec spec,
  required String crossOpId,
}) async {
  // crossInsertParamsFor wires the row so every composite FK + every
  // per-tenant unique constraint *passes* — operator_id, dependent
  // org_unit / location / endpoint-node IDs all belong to crossOpId.
  // The row's marker column carries the caller's marker so admin
  // verification can spot a forged row, but the calling tenant's
  // SET LOCAL says `app_current_operator() = ${ctx.operatorId}`, so
  // the per-tenant WITH CHECK predicate is the only barrier left.
  // If WITH CHECK is broken, the cross row lands and admin
  // verification flags it; if a privilege check (rollups) rejects
  // first, the rejection itself satisfies the assertion. Either way
  // the failure mode is unambiguous — no FK / unique false-positive
  // can mask a regression in the per-tenant policy.
  final crossParams = spec.crossInsertParamsFor(ctx.operatorId, crossOpId);

  final outcome = await _attemptTenantWrite(
    wrapper,
    ctx,
    spec.insertSqlFor(crossOpId),
    crossParams,
  );

  expect(
    outcome.rejected || outcome.affectedRows == 0,
    isTrue,
    reason: '${spec.name}: cross-tenant INSERT under '
        '${ctx.operatorId} attributing to $crossOpId must be rejected '
        '(WITH CHECK / privilege) or affect 0 rows. Got '
        'rejected=${outcome.rejected}, affected=${outcome.affectedRows}, '
        'error=${outcome.error}',
  );

  // Admin verification: the cross-tenant operator's row count for the
  // distinguishing fixture marker is unchanged (no forged row).
  final forgedCount = await _countForgedRowAsAdmin(
    adminPool: adminPool,
    spec: spec,
    crossOpId: crossOpId,
    callerOpId: ctx.operatorId,
  );
  expect(
    forgedCount,
    equals(0),
    reason:
        '${spec.name}: admin-side scan must find zero rows attributed '
        'to $crossOpId carrying the calling tenant\'s marker '
        '(${spec.markerSeedValueFor(ctx.operatorId)}). Found '
        '$forgedCount.',
  );
}

Future<void> _expectCrossTenantUpdateBlocked({
  required TenantTransactionWrapper wrapper,
  required PackagePostgresPool adminPool,
  required TenantContext ctx,
  required _TableSpec spec,
  required String crossOpId,
}) async {
  final outcome = await _attemptTenantWrite(
    wrapper,
    ctx,
    spec.updateSqlFor(crossOpId),
    spec.updateParamsFor(crossOpId),
  );

  expect(
    outcome.rejected || outcome.affectedRows == 0,
    isTrue,
    reason: '${spec.name}: cross-tenant UPDATE under '
        '${ctx.operatorId} targeting $crossOpId must be rejected or '
        'affect 0 rows. Got rejected=${outcome.rejected}, '
        'affected=${outcome.affectedRows}, error=${outcome.error}',
  );

  final markerAfter = await _readMarkerAsAdmin(
    adminPool: adminPool,
    spec: spec,
    targetOpId: crossOpId,
  );
  expect(
    markerAfter,
    equals(spec.markerSeedValueFor(crossOpId)),
    reason:
        '${spec.name}: admin-side read of $crossOpId\'s '
        '${spec.markerColumn} must still equal '
        '"${spec.markerSeedValueFor(crossOpId)}" — a successful '
        'cross-tenant UPDATE would have replaced it with '
        '"${spec.markerNewValue}".',
  );
}

Future<void> _expectCrossTenantDeleteBlocked({
  required TenantTransactionWrapper wrapper,
  required PackagePostgresPool adminPool,
  required TenantContext ctx,
  required _TableSpec spec,
  required String crossOpId,
}) async {
  final outcome = await _attemptTenantWrite(
    wrapper,
    ctx,
    spec.deleteSqlFor(crossOpId),
    spec.deleteParamsFor(crossOpId),
  );

  expect(
    outcome.rejected || outcome.affectedRows == 0,
    isTrue,
    reason: '${spec.name}: cross-tenant DELETE under '
        '${ctx.operatorId} targeting $crossOpId must be rejected or '
        'affect 0 rows. Got rejected=${outcome.rejected}, '
        'affected=${outcome.affectedRows}, error=${outcome.error}',
  );

  final crossCount = await _countTotalAsAdmin(
    adminPool: adminPool,
    spec: spec,
    targetOpId: crossOpId,
  );
  expect(
    crossCount,
    greaterThanOrEqualTo(1),
    reason:
        '${spec.name}: admin-side count of rows owned by $crossOpId '
        'must remain ≥ 1 — a successful cross-tenant DELETE would '
        'have removed at least the seed row.',
  );
}

Future<void> _expectForgeAdminEmergencyReadSeesBoth({
  required TenantTransactionWrapper wrapper,
  required _TableSpec spec,
}) async {
  final rows = await wrapper.runAsSystem<List<PostgresRow>>(
    (exec) => exec.query(
      'select operator_id::text as operator_id, '
      'count(*)::bigint as cnt from public.${spec.name} '
      "where operator_id::text in ('$_opA', '$_opB') "
      'group by operator_id::text',
    ),
    reason: 'b36_rls_sweep_emergency_read:${spec.name}',
  );
  final perOp = <String, int>{
    for (final row in rows)
      (row['operator_id'] as String): (row['cnt'] as int?) ??
          int.parse('${row['cnt']}'),
  };
  expect(
    perOp[_opA] ?? 0,
    greaterThanOrEqualTo(1),
    reason:
        '${spec.name}: forge_admin BYPASSRLS read via runAsSystem '
        'must see at least one tenant-A row.',
  );
  expect(
    perOp[_opB] ?? 0,
    greaterThanOrEqualTo(1),
    reason:
        '${spec.name}: forge_admin BYPASSRLS read via runAsSystem '
        'must see at least one tenant-B row.',
  );
}

Future<void> _expectTenantLeadingIndexPlan({
  required TenantTransactionWrapper wrapper,
  required TenantContext ctx,
  required _TableSpec spec,
}) async {
  final planJson = await wrapper.runInTenantContext<Object?>(
    ctx,
    (exec) async {
      // Force the planner to consider index paths even on the small
      // B36 fixture set. Transaction-local so no other test inherits
      // these settings.
      await exec.execute('set local enable_seqscan = off');
      await exec.execute('set local enable_bitmapscan = off');
      final rows = await exec.query(
        // Read a constant rather than a column so the query still
        // works on advisor_conversation_log (column-restricted
        // grants for service_role); the RLS predicate is appended
        // automatically, exercising the operator_id-leading index.
        'explain (format json) select 1 from public.${spec.name} '
        'limit 1',
      );
      expect(rows, hasLength(1));
      return rows.single['QUERY PLAN'];
    },
  );

  final List<dynamic> parsed = _parseExplainJson(planJson);
  expect(
    _planUsesTenantLeadingIndex(parsed),
    isTrue,
    reason:
        '${spec.name}: tenant SET LOCAL EXPLAIN plan must use an '
        'Index/Bitmap path whose Index Cond / Index Name names '
        'operator_id (RLS performance discipline — item 4 of '
        'phase_9_scalability_decisions_2026-04-27.md). Plan: '
        '${jsonEncode(parsed)}',
  );
}

// ─── Cross-tenant attempt + admin verification helpers ─────────────

class _WriteOutcome {
  _WriteOutcome({
    required this.rejected,
    required this.affectedRows,
    required this.error,
  });

  final bool rejected;
  final int affectedRows;
  final Object? error;
}

Future<_WriteOutcome> _attemptTenantWrite(
  TenantTransactionWrapper wrapper,
  TenantContext ctx,
  String sql,
  Map<String, Object?> parameters,
) async {
  Object? caught;
  var affected = -1;
  try {
    affected = await wrapper.runInTenantContext<int>(
      ctx,
      (exec) => exec.execute(sql, parameters: parameters),
    );
  } catch (e) {
    caught = e;
  }
  return _WriteOutcome(
    rejected: caught != null,
    affectedRows: caught == null ? affected : -1,
    error: caught,
  );
}

Future<int> _countForgedRowAsAdmin({
  required PackagePostgresPool adminPool,
  required _TableSpec spec,
  required String crossOpId,
  required String callerOpId,
}) async {
  late int count;
  await _runAdmin(adminPool, (exec) async {
    final rows = await exec.query(
      'select count(*)::bigint as cnt from public.${spec.name} '
      'where operator_id = @target::uuid '
      'and ${spec.markerColumn} = @marker',
      parameters: <String, Object?>{
        'target': crossOpId,
        'marker': spec.markerSeedValueFor(callerOpId),
      },
    );
    count = (rows.single['cnt'] as int?) ??
        int.tryParse('${rows.single['cnt']}') ??
        0;
  });
  return count;
}

Future<Object?> _readMarkerAsAdmin({
  required PackagePostgresPool adminPool,
  required _TableSpec spec,
  required String targetOpId,
}) async {
  Object? marker;
  await _runAdmin(adminPool, (exec) async {
    final rows = await exec.query(
      'select ${spec.markerColumn} as marker from public.${spec.name} '
      'where operator_id = @target::uuid '
      'order by ${spec.markerColumn} '
      'limit 1',
      parameters: <String, Object?>{'target': targetOpId},
    );
    if (rows.isEmpty) {
      marker = null;
    } else {
      marker = rows.single['marker'];
    }
  });
  return marker;
}

Future<int> _countTotalAsAdmin({
  required PackagePostgresPool adminPool,
  required _TableSpec spec,
  required String targetOpId,
}) async {
  late int count;
  await _runAdmin(adminPool, (exec) async {
    final rows = await exec.query(
      'select count(*)::bigint as cnt from public.${spec.name} '
      'where operator_id = @target::uuid',
      parameters: <String, Object?>{'target': targetOpId},
    );
    count = (rows.single['cnt'] as int?) ??
        int.tryParse('${rows.single['cnt']}') ??
        0;
  });
  return count;
}

// ─── EXPLAIN JSON walking ───────────────────────────────────────────

List<dynamic> _parseExplainJson(Object? raw) {
  if (raw == null) {
    throw StateError('EXPLAIN returned a null QUERY PLAN');
  }
  if (raw is List) {
    return raw;
  }
  if (raw is String) {
    final decoded = jsonDecode(raw);
    if (decoded is List) return decoded;
    throw StateError(
      'EXPLAIN JSON did not decode as a list: ${decoded.runtimeType}',
    );
  }
  throw StateError(
    'Unexpected EXPLAIN result shape: ${raw.runtimeType}',
  );
}

bool _planUsesTenantLeadingIndex(List<dynamic> plans) {
  for (final entry in plans) {
    if (entry is Map) {
      final root = entry['Plan'];
      if (root is Map && _walkPlanNode(Map<String, dynamic>.from(root))) {
        return true;
      }
    }
  }
  return false;
}

bool _walkPlanNode(Map<String, dynamic> plan) {
  if (_isTenantLeadingIndexNode(plan)) return true;
  final children = plan['Plans'];
  if (children is List) {
    for (final child in children) {
      if (child is Map &&
          _walkPlanNode(Map<String, dynamic>.from(child))) {
        return true;
      }
    }
  }
  return false;
}

bool _isTenantLeadingIndexNode(Map<String, dynamic> plan) {
  final nodeType = (plan['Node Type'] ?? '').toString();
  // Index Scan, Index Only Scan, Bitmap Index Scan all qualify; a
  // bare Seq Scan does not.
  if (!nodeType.contains('Index') && !nodeType.contains('Bitmap')) {
    return false;
  }
  final cond = (plan['Index Cond'] ?? '').toString();
  final indexName = (plan['Index Name'] ?? '').toString();
  // Index Cond appearing operator_id is the strongest signal: the
  // planner folded the RLS predicate into the index probe. Index Name
  // containing "operator" is the secondary acceptance — every B36
  // table's leading index name contains operator_id-bearing
  // constructs (`<table>_uq`, `<table>_*_idx` with operator_id as the
  // first column) and Postgres indexes auto-generated for primary
  // keys are named `<table>_pkey`; for partitioned tables the PK
  // includes operator_id as the leading column even when the name
  // does not say so. The conservative check is the Index Cond —
  // which is what we lead with.
  return cond.contains('operator_id') ||
      indexName.contains('operator');
}
