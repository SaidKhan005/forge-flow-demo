// Phase 8 spine-bridge Lane .2 — PostgresShiftRecordWriter test suite.
//
// Tests cover the writer-side acceptance per
// `docs/contracts/integration_spine_architecture_contract.md`
// "Sub-lane shape -> .2":
//
//   A. Write trio result: built ShiftFact + aggregator provenance ->
//      one shift_records row with correct numeric values + provenance
//      strings.
//   J. Re-aggregation idempotent: same input set twice -> same output
//      row (replace-for-slot semantics).
//   K. Concern A (target_profile_version_id preservation): first-time
//      aggregation writes tpv_X; cycle rolls; re-aggregation reuses
//      tpv_X verbatim, NOT the current ActiveTargetProfile's tpv_Y.
//   L. RLS + tenancy: every writer transaction injects
//      app.operator_id / app.location_id via set_config.
//   M. Banned-items grep across the writer source per
//      `memory/project_v1_lean_cut_2_2026_05_03.md`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/aggregator_provenance_context.dart';
import 'package:forge_and_flow/domain/models/closed_shift_input.dart';
import 'package:forge_and_flow/domain/models/target_snapshot.dart';
import 'package:forge_and_flow/domain/services/shift_fact_builder.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_shift_record_writer.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-4111-8111-111111111111';
const String _opB = '22222222-2222-4222-8222-222222222222';
const String _locA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _locB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

final DateTime _businessDate = DateTime.utc(2026, 5, 4);
const String _businessDateIso = '2026-05-04';

const TargetSnapshot _targetSnapshotV1 = TargetSnapshot(
  restaurantId: 'demo_restaurant_001',
  targetProfileId: 'tp_demo_2026_q2',
  targetProfileVersionId: 'tpv_X',
  sourceType: 'cycle_recommended',
  targetCPLH: 12.0,
  targetSPLH: 50.0,
  targetPPA: 40.0,
  fohWage: 18.0,
  bohWage: 20.0,
  opzFloorCPLH: 10.0,
  opzCeilingCPLH: 14.0,
  theoreticalFohLaborPct: 12.5,
  theoreticalBohLaborPct: 12.5,
  theoreticalLaborPct: 25.0,
);

const TargetSnapshot _targetSnapshotV2 = TargetSnapshot(
  restaurantId: 'demo_restaurant_001',
  targetProfileId: 'tp_demo_2026_q2',
  targetProfileVersionId: 'tpv_Y', // cycle rolled to a newer version.
  sourceType: 'cycle_recommended',
  targetCPLH: 13.0,
  targetSPLH: 52.0,
  targetPPA: 42.0,
  fohWage: 19.0,
  bohWage: 21.0,
  opzFloorCPLH: 11.0,
  opzCeilingCPLH: 15.0,
  theoreticalFohLaborPct: 12.0,
  theoreticalBohLaborPct: 12.0,
  theoreticalLaborPct: 24.0,
);

ClosedShiftInput _trioInput() => ClosedShiftInput(
      businessDate: _businessDate,
      weekId: '2026-W18',
      dayLabel: 'Mon',
      daypart: 'dinner',
      covers: 5,
      forecastCovers: 10,
      actualSales: 124.85,
      actualFohHours: 5,
      actualBohHours: 6,
      actualFohLaborDollars: 5 * 18.0,
      actualBohLaborDollars: 6 * 20.0,
      sourceSystem: 'oracle_micros_simphony',
    );

void main() {
  // ─────────────────── A — write trio result ──────────────────────────────
  group('PostgresShiftRecordWriter — A. trio write', () {
    test('built ShiftFact + aggregator provenance -> one shift_records row '
        'with correct numeric values + provenance strings', () async {
      final pool = _FakePool();
      final writer = PostgresShiftRecordWriter(TenantTransactionWrapper(pool));

      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _trioInput(),
        _targetSnapshotV1,
      );

      await writer.writeShiftRecord(
        operatorId: _opA,
        locationId: _locA,
        shiftFact: fact,
        provenance: const AggregatorProvenanceContext(
          coversProvenance: 'vendor_oracle_micros_simphony',
          laborDollarsProvenance:
              'vendor_quickbooks_time_per_employee_actual_dollars_per_employee_rates',
          priorTargetProfileVersionId: null,
        ),
      );

      expect(pool.shiftRecords, hasLength(1));
      final row = pool.shiftRecords.values.single;
      expect(row['operator_id'], _opA);
      expect(row['location_id'], _locA);
      expect(row['business_date'], _businessDateIso);
      expect(row['daypart'], 'dinner');
      expect(row['covers'], 5);
      expect((row['actual_sales'] as num).toDouble(),
          closeTo(124.85, 0.001));
      expect(row['foh_hours'], 5);
      expect(row['boh_hours'], 6);
      expect((row['foh_labor_dollar'] as num).toDouble(),
          closeTo(5 * 18.0, 0.001));
      expect((row['boh_labor_dollar'] as num).toDouble(),
          closeTo(6 * 20.0, 0.001));
      expect(row['source_system'], 'oracle_micros_simphony');
      expect(row['target_profile_version_id'], 'tpv_X',
          reason: 'first-time aggregation adopts the current ActiveTargetProfile');
      expect(row['covers_provenance'], 'vendor_oracle_micros_simphony');
      expect(
        row['labor_dollars_provenance'],
        'vendor_quickbooks_time_per_employee_actual_dollars_per_employee_rates',
      );
    });
  });

  // ─────────────────── J — re-aggregation idempotency ─────────────────────
  group('PostgresShiftRecordWriter — J. re-aggregation idempotent', () {
    test('writing the same trio result twice replaces in place; no '
        'duplicate row', () async {
      final pool = _FakePool();
      final writer = PostgresShiftRecordWriter(TenantTransactionWrapper(pool));

      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _trioInput(),
        _targetSnapshotV1,
      );
      final provenance = const AggregatorProvenanceContext(
        coversProvenance: 'vendor_oracle_micros_simphony',
        laborDollarsProvenance:
            'vendor_quickbooks_time_per_employee_actual_dollars_per_employee_rates',
        priorTargetProfileVersionId: null,
      );

      await writer.writeShiftRecord(
        operatorId: _opA,
        locationId: _locA,
        shiftFact: fact,
        provenance: provenance,
      );
      await writer.writeShiftRecord(
        operatorId: _opA,
        locationId: _locA,
        shiftFact: fact,
        provenance: provenance,
      );

      expect(pool.shiftRecords, hasLength(1),
          reason: 'replace-for-slot keeps a single row per slot');
    });
  });

  // ─────────────────── K — Concern A (TPV preservation) ───────────────────
  group('PostgresShiftRecordWriter — K. Concern A: '
      'target_profile_version_id preservation', () {
    test('first-time aggregation writes tpv_X; vendor correction arrives '
        'after cycle roll; re-aggregation reuses tpv_X verbatim, NOT '
        'tpv_Y', () async {
      final pool = _FakePool();
      final writer = PostgresShiftRecordWriter(TenantTransactionWrapper(pool));

      // ── First-time aggregation locks tpv_X ──
      final firstFact = ShiftFactBuilder.fromClosedShiftInput(
        _trioInput(),
        _targetSnapshotV1,
      );
      await writer.writeShiftRecord(
        operatorId: _opA,
        locationId: _locA,
        shiftFact: firstFact,
        provenance: const AggregatorProvenanceContext(
          coversProvenance: 'vendor_oracle_micros_simphony',
          laborDollarsProvenance:
              'vendor_quickbooks_time_per_employee_actual_dollars_per_employee_rates',
          priorTargetProfileVersionId: null,
        ),
      );
      expect(pool.shiftRecords.values.single['target_profile_version_id'],
          'tpv_X');

      // ── TargetCycle rolls; ActiveTargetProfile points at tpv_Y ──
      // A corrected vendor fact arrives. The aggregator (.2) reads the
      // existing shift_records row at slot, surfaces
      // priorTargetProfileVersionId = 'tpv_X', and calls the writer
      // with a ShiftFact built from the CURRENT (tpv_Y) target
      // snapshot — the writer must override the snapshot's tpv_Y with
      // the prior tpv_X verbatim.
      final correctedInput = ClosedShiftInput(
        businessDate: _businessDate,
        weekId: '2026-W18',
        dayLabel: 'Mon',
        daypart: 'dinner',
        covers: 6, // vendor correction: covers nudged up by 1.
        forecastCovers: 10,
        actualSales: 142.50,
        actualFohHours: 5,
        actualBohHours: 6,
        actualFohLaborDollars: 5 * 18.0,
        actualBohLaborDollars: 6 * 20.0,
        sourceSystem: 'oracle_micros_simphony',
      );
      final correctedFact = ShiftFactBuilder.fromClosedShiftInput(
        correctedInput,
        _targetSnapshotV2, // cycle rolled — current snapshot is tpv_Y.
      );
      await writer.writeShiftRecord(
        operatorId: _opA,
        locationId: _locA,
        shiftFact: correctedFact,
        provenance: const AggregatorProvenanceContext(
          coversProvenance: 'vendor_oracle_micros_simphony',
          laborDollarsProvenance:
              'vendor_quickbooks_time_per_employee_actual_dollars_per_employee_rates',
          // The aggregator surfaces the prior tpv_X here.
          priorTargetProfileVersionId: 'tpv_X',
        ),
      );

      expect(pool.shiftRecords, hasLength(1),
          reason: 'replace-for-slot, not append');
      final reread = pool.shiftRecords.values.single;
      expect(reread['target_profile_version_id'], 'tpv_X',
          reason:
              'Concern A: corrected fact does NOT re-grade closed history under '
              'a newer cycle; prior tpv_X preserved verbatim');
      expect(reread['covers'], 6,
          reason: 'numeric correction lands on the row');
      expect((reread['actual_sales'] as num).toDouble(),
          closeTo(142.50, 0.001));
    });

    test('first-time aggregation (priorTargetProfileVersionId = null) '
        'mints a fresh version id from the current ActiveTargetProfile',
        () async {
      final pool = _FakePool();
      final writer = PostgresShiftRecordWriter(TenantTransactionWrapper(pool));

      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _trioInput(),
        _targetSnapshotV2, // ActiveTargetProfile currently at tpv_Y.
      );
      await writer.writeShiftRecord(
        operatorId: _opA,
        locationId: _locA,
        shiftFact: fact,
        provenance: const AggregatorProvenanceContext(
          coversProvenance: 'vendor_oracle_micros_simphony',
          laborDollarsProvenance:
              'vendor_quickbooks_time_per_employee_actual_dollars_per_employee_rates',
          priorTargetProfileVersionId: null,
        ),
      );

      final row = pool.shiftRecords.values.single;
      expect(row['target_profile_version_id'], 'tpv_Y',
          reason: 'first-time aggregation adopts the current snapshot version');
    });
  });

  // ─────────────────── L — RLS + tenancy ──────────────────────────────────
  group('PostgresShiftRecordWriter — L. RLS + tenancy injection', () {
    test('every writer transaction injects '
        'app.operator_id / app.location_id via set_config', () async {
      final pool = _FakePool();
      final writer = PostgresShiftRecordWriter(TenantTransactionWrapper(pool));

      final fact = ShiftFactBuilder.fromClosedShiftInput(
        _trioInput(),
        _targetSnapshotV1,
      );
      final provenance = const AggregatorProvenanceContext(
        coversProvenance: 'vendor_oracle_micros_simphony',
        laborDollarsProvenance:
            'vendor_quickbooks_time_per_employee_actual_dollars_per_employee_rates',
        priorTargetProfileVersionId: null,
      );

      await writer.writeShiftRecord(
        operatorId: _opA,
        locationId: _locA,
        shiftFact: fact,
        provenance: provenance,
      );
      await writer.writeShiftRecord(
        operatorId: _opB,
        locationId: _locB,
        shiftFact: fact,
        provenance: provenance,
      );

      expect(pool.transactions, isNotEmpty);
      final tenants = pool.transactions
          .map((tx) => '${tx.setConfigCalls['app.operator_id']}|'
              '${tx.setConfigCalls['app.location_id']}')
          .toSet();
      expect(tenants.contains('$_opA|$_locA'), isTrue);
      expect(tenants.contains('$_opB|$_locB'), isTrue);
      // Tenant isolation: rows are keyed by the SET LOCAL pair so
      // operator A's write does not surface under operator B's tenant.
      expect(pool.shiftRecords, hasLength(2),
          reason: '(operator_id, location_id) is part of the slot key');
    });
  });

  // ─────────────────── M — banned-items grep ──────────────────────────────
  group('PostgresShiftRecordWriter — M. banned-items grep', () {
    test('writer source contains zero V1 lean cut 2 banned items', () async {
      final source = await File(
        'lib/infrastructure/persistence/postgres/postgres_shift_record_writer.dart',
      ).readAsString();

      const banned = <String>[
        'KMS',
        'pgp_sym_encrypt_kms',
        'rotateSigningKey',
        'parse_warnings',
        'parse_partial',
        'kStrictReplayFiveMinute',
        'pg_try_advisory_lock',
        'pg_advisory_lock',
        'sigtermDrainHandler',
        'inboundWebhookDLQTile',
        'raw_payload_partition',
        'pg_partman_raw',
      ];
      for (final token in banned) {
        expect(
          source.toLowerCase().contains(token.toLowerCase()),
          isFalse,
          reason: 'banned item present in writer source: $token',
        );
      }
    });
  });
}

// ─── Fake pool ────────────────────────────────────────────────────────

class _FakePool implements PostgresPool {
  /// Keyed by `(operator_id, location_id, business_date_iso, daypart)`.
  /// Replace-for-slot means a single row per key; the fake mirrors the
  /// production ON CONFLICT DO UPDATE semantics.
  final Map<String, Map<String, Object?>> shiftRecords =
      <String, Map<String, Object?>>{};

  final List<_FakeTransaction> transactions = <_FakeTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _FakeTransaction(this);
    transactions.add(tx);
    return tx;
  }
}

class _FakeTransaction implements PostgresTransaction {
  _FakeTransaction(this.pool);

  final _FakePool pool;
  final Map<String, String> setConfigCalls = <String, String>{};
  bool committed = false;

  void _captureSetConfig(String sql, PostgresParameters parameters) {
    final regex = RegExp(r"set_config\('(?<name>[a-zA-Z0-9_.]+)'");
    final match = regex.firstMatch(sql);
    if (match == null) return;
    final name = match.namedGroup('name')!;
    final value = parameters['value'];
    if (value is String) {
      setConfigCalls[name] = value;
    }
  }

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('select set_config(')) {
      _captureSetConfig(sql, parameters);
      return const <PostgresRow>[];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('select set_config(')) {
      _captureSetConfig(sql, parameters);
      return 0;
    }
    if (sql.contains('insert into public.shift_records')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final businessDate = parameters['business_date'] as String;
      final daypart = parameters['daypart'] as String;
      final key = '$operatorId|$locationId|$businessDate|$daypart';
      pool.shiftRecords[key] = <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'restaurant_id': parameters['restaurant_id'],
        'week_id': parameters['week_id'],
        'day_label': parameters['day_label'],
        'daypart': daypart,
        'status': parameters['status'],
        'business_date': businessDate,
        'covers': parameters['covers'],
        'forecast_covers': parameters['forecast_covers'],
        'actual_sales': parameters['actual_sales'],
        'ppa': parameters['ppa'],
        'cplh': parameters['cplh'],
        'splh': parameters['splh'],
        'foh_hours': parameters['foh_hours'],
        'boh_hours': parameters['boh_hours'],
        'foh_labor_dollar': parameters['foh_labor_dollar'],
        'boh_labor_dollar': parameters['boh_labor_dollar'],
        'theoretical_labor_pct': parameters['theoretical_labor_pct'],
        'primary_lever': parameters['primary_lever'],
        'target_profile_id': parameters['target_profile_id'],
        'target_profile_version_id': parameters['target_profile_version_id'],
        'target_source_type': parameters['target_source_type'],
        'target_cplh': parameters['target_cplh'],
        'target_splh': parameters['target_splh'],
        'target_ppa': parameters['target_ppa'],
        'target_foh_wage': parameters['target_foh_wage'],
        'target_boh_wage': parameters['target_boh_wage'],
        'opz_floor_cplh': parameters['opz_floor_cplh'],
        'opz_ceiling_cplh': parameters['opz_ceiling_cplh'],
        'theoretical_foh_labor_pct':
            parameters['theoretical_foh_labor_pct'],
        'theoretical_boh_labor_pct':
            parameters['theoretical_boh_labor_pct'],
        'source_system': parameters['source_system'],
        'source_shift_id': parameters['source_shift_id'],
        'covers_provenance': parameters['covers_provenance'],
        'labor_dollars_provenance':
            parameters['labor_dollars_provenance'],
      };
      return 1;
    }
    return 0;
  }

  @override
  Future<void> commit() async {
    committed = true;
  }

  @override
  Future<void> rollback() async {}
}
