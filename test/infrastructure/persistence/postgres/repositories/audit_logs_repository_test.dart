// Phase 9.0Σ.f / post-hardening P2 — canonical-path unit tests for
// AuditLogsRepository + AuditLogsCutoverFlag resolvers.
//
// Companion to `test/repositories/audit_logs_repository_test.dart`,
// which pins the `writeRow` parameter shape (chain_date computation,
// actor_kind mapping, payload JSON encoding). This file is the
// canonical-path entry expected by the post-hardening test-coverage
// rollup and focuses on the seams that file does NOT cover:
//
//   * `AuditLogsCutoverFlag` resolver implementations (`Fixed` and
//     `FeatureFlagsTable`) at the unit level — exercised through
//     `AuthEventsAuditRepository` in the cutover integration test, but
//     not directly. Default-ON when the row is missing, which is the
//     *opposite* of `FeatureFlagsTableKmsRolloutFlag` (default-OFF).
//     This test pins both defaults so a future refactor of either
//     resolver cannot silently flip them.
//
//   * SHA-256 hash-chain input shape — the repository must NOT supply
//     `prev_row_hash` / `row_hash`; the BEFORE INSERT trigger
//     `audit_logs_set_chain` computes both server-side. The
//     repository's ONLY chain-related obligation is `chain_date =
//     (occurred_at AT TIME ZONE 'UTC')::date`, which the table CHECK
//     also enforces.
//
//   * `actor_kind` never-NULL guard — both the `required` parameter at
//     the API surface AND the SQL must bind `actor_kind` on every
//     write. (`audit_logs_actor_shape_check` then enforces the
//     `'user'` / `'service'` shape; that DB constraint is exercised
//     end-to-end by the chain-integrity test elsewhere.)
//
//   * `operator_id` RLS posture — `audit_logs.writeRow` runs inside
//     the CALLER'S transaction (no SET LOCAL of its own), so the
//     unit-test obligation here is to verify the repository binds
//     `operator_id` parametrically. The policy fold happens at the
//     auth-event boundary that opens the wrapper transaction; this
//     test holds the boundary contract honest by ensuring
//     `@operator_id::uuid` shows up on every insert.
//
// The end-to-end chain integrity (prev/row_hash recomputation, single-
// byte tamper detection, chain-boundary isolation) lives in
// `test/phase_9_0sigma_f_audit_chain_e2e_test.dart` (B37); this file
// is the canonical-path resolver + writer-guard slice.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';
const String _spId = '99999999-9999-9999-9999-999999999999';

void main() {
  group('AuditLogsRepository.writeRow — chain-input + actor_kind guards', () {
    test(
      'SHA-256 chain inputs: repository emits ONLY the row inputs, never '
      'prev_row_hash / row_hash (the BEFORE INSERT trigger computes both)',
      () async {
        final exec = _RecordingExecutor();
        const repo = AuditLogsRepository();
        await repo.writeRow(
          exec,
          operatorId: _opA,
          locationId: _locA,
          occurredAt: DateTime.utc(2026, 4, 30, 12),
          actorKind: 'user',
          actorUserId: _userA,
          action: 'auth.user.signed_in',
          payload: const <String, Object?>{'method': 'password'},
        );
        expect(exec.statements, hasLength(1));
        final sql = exec.statements.single;
        expect(sql, contains('insert into public.audit_logs'));
        // Hard rule from migration 202604280005: prev_row_hash + row_hash
        // are populated by `public.audit_logs_set_chain()` in a BEFORE
        // INSERT trigger. The repository must never bind them — doing so
        // would either be ignored (wasted bind) or, worse, fight the
        // trigger and break chain continuity. Both names must stay out
        // of the SQL surface AND the parameter map.
        expect(sql, isNot(contains('prev_row_hash')));
        expect(sql, isNot(contains('row_hash')));
        expect(exec.parameters.single.containsKey('prev_row_hash'), isFalse);
        expect(exec.parameters.single.containsKey('row_hash'), isFalse);
      },
    );

    test(
      'actor_kind never-NULL: both the SQL column list AND the bound '
      'parameters carry actor_kind on every insert; the API surface '
      'requires it (compile-time guard)',
      () async {
        final exec = _RecordingExecutor();
        const repo = AuditLogsRepository();
        // user-actor row.
        await repo.writeRow(
          exec,
          operatorId: _opA,
          locationId: _locA,
          occurredAt: DateTime.utc(2026, 4, 30, 12),
          actorKind: 'user',
          actorUserId: _userA,
          action: 'auth.user.signed_in',
        );
        // service-actor row.
        await repo.writeRow(
          exec,
          operatorId: _opA,
          locationId: _locA,
          occurredAt: DateTime.utc(2026, 4, 30, 12),
          actorKind: 'service',
          actorPrincipalId: 'sp:$_spId',
          action: 'admin.service_principal.issue_token',
        );
        expect(exec.statements, hasLength(2));
        for (final sql in exec.statements) {
          expect(
            sql,
            contains('actor_kind'),
            reason: 'every write must list actor_kind in the column list '
                'so audit_logs.actor_kind NOT NULL is satisfied',
          );
          expect(
            sql,
            contains('@actor_kind'),
            reason: 'actor_kind is bound, never concatenated',
          );
        }
        expect(exec.parameters[0]['actor_kind'], equals('user'));
        expect(exec.parameters[1]['actor_kind'], equals('service'));
      },
    );

    test(
      'operator_id RLS predicate posture: audit_logs writes run inside '
      'the caller\'s transaction (no SET LOCAL emitted by the repo); '
      'the boundary fold relies on @operator_id::uuid being bound',
      () async {
        final exec = _RecordingExecutor();
        const repo = AuditLogsRepository();
        await repo.writeRow(
          exec,
          operatorId: _opA,
          locationId: _locA,
          occurredAt: DateTime.utc(2026, 4, 30, 12),
          actorKind: 'user',
          actorUserId: _userA,
          action: 'auth.user.signed_in',
        );
        final sql = exec.statements.single;
        // The repo must bind operator_id parametrically; the auth-event
        // boundary opens the wrapper transaction with SET LOCAL
        // app.operator_id, and the audit_logs RLS policy folds against
        // that GUC + the row's operator_id column. Concatenated SQL
        // would defeat the binding and the policy fold.
        expect(sql, contains('@operator_id::uuid'));
        expect(exec.parameters.single['operator_id'], equals(_opA));
        // The repo MUST NOT emit its own SET LOCAL — it relies on the
        // caller's transaction.
        expect(
          exec.statements.where((s) => s.contains('set_config')),
          isEmpty,
          reason: 'audit_logs.writeRow runs inside caller\'s tx; SET '
              'LOCAL is the caller\'s responsibility',
        );
      },
    );
  });

  group('FixedAuditLogsCutoverFlag', () {
    final exec = _RecordingExecutor();

    test('FixedAuditLogsCutoverFlag(true) returns true for any executor',
        () async {
      const flag = FixedAuditLogsCutoverFlag(true);
      expect(await flag.isEnabled(exec), isTrue);
      // Fixed flag MUST NOT consult the executor.
      expect(exec.statements, isEmpty);
    });

    test('FixedAuditLogsCutoverFlag(false) returns false for any executor',
        () async {
      const flag = FixedAuditLogsCutoverFlag(false);
      expect(await flag.isEnabled(exec), isFalse);
      expect(exec.statements, isEmpty);
    });
  });

  group('FeatureFlagsTableAuditLogsCutoverFlag (production resolver)', () {
    test(
      'enabled=true row → returns true; query targets feature_flags '
      'with global scope (operator_id IS NULL AND location_id IS NULL) '
      'and the locked flag_name',
      () async {
        final exec = _CannedFeatureFlagsExecutor(rowEnabled: true);
        const flag = FeatureFlagsTableAuditLogsCutoverFlag();
        expect(await flag.isEnabled(exec), isTrue);
        // Single SELECT against feature_flags.
        expect(exec.statements, hasLength(1));
        final sql = exec.statements.single;
        expect(sql, contains('from public.feature_flags'));
        expect(sql, contains("flag_name = 'audit_logs_cutover_enabled'"));
        // Global scope predicate — the seeded row carries
        // (operator_id NULL, location_id NULL).
        expect(sql, contains('operator_id is null'));
        expect(sql, contains('location_id is null'));
        // limit 1 — never more than one canonical global row.
        expect(sql, contains('limit 1'));
      },
    );

    test('enabled=false row → returns false (the production rollback knob)',
        () async {
      final exec = _CannedFeatureFlagsExecutor(rowEnabled: false);
      const flag = FeatureFlagsTableAuditLogsCutoverFlag();
      expect(await flag.isEnabled(exec), isFalse);
    });

    test(
      'missing row → DEFAULTS TO TRUE (different from '
      'FeatureFlagsTableKmsRolloutFlag, which defaults FALSE). '
      'Default-ON keeps the production posture intact during a '
      'partial migration apply',
      () async {
        final exec = _CannedFeatureFlagsExecutor(rowEnabled: null);
        const flag = FeatureFlagsTableAuditLogsCutoverFlag();
        expect(
          await flag.isEnabled(exec),
          isTrue,
          reason:
              'audit_logs cutover defaults ON; KMS rollout defaults OFF — '
              'this is the canonical pin so a refactor cannot flip them',
        );
      },
    );

    test(
      'enabled column carries non-bool truthy values (defensive '
      'normalization): num != 0, "true"/"t" string → returns true',
      () async {
        final flag = FeatureFlagsTableAuditLogsCutoverFlag();
        // Some Postgres adapters return BOOL as 't'/'f' text.
        expect(
          await flag.isEnabled(
            _CannedFeatureFlagsExecutor.withRawValue('t'),
          ),
          isTrue,
        );
        expect(
          await flag.isEnabled(
            _CannedFeatureFlagsExecutor.withRawValue('true'),
          ),
          isTrue,
        );
        // Numeric encodings (some legacy boolean stores hand back 1/0).
        expect(
          await flag.isEnabled(_CannedFeatureFlagsExecutor.withRawValue(1)),
          isTrue,
        );
        expect(
          await flag.isEnabled(_CannedFeatureFlagsExecutor.withRawValue(0)),
          isFalse,
        );
      },
    );
  });
}

/// Minimal `PostgresExecutor` fake that records every executed
/// statement / parameter map and returns no rows. The
/// `AuditLogsRepository.writeRow` SQL ends with `returning id`, but
/// the repo discards the returned rows for the unit-test slice — we
/// only need the bind shape.
class _RecordingExecutor implements PostgresExecutor {
  final List<String> statements = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    statements.add(sql);
    this.parameters.add(parameters);
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    statements.add(sql);
    this.parameters.add(parameters);
    return 1;
  }
}

/// Returns a single `feature_flags` row whose `enabled` column carries
/// either a canonical bool, a string like `'t'` / `'true'`, a numeric
/// 1/0, or no row at all (when `rowEnabled` / `rawValue` are both null
/// AND `_emitsRow` is false).
class _CannedFeatureFlagsExecutor implements PostgresExecutor {
  _CannedFeatureFlagsExecutor({required bool? rowEnabled})
      : _emitsRow = rowEnabled != null,
        _value = rowEnabled;

  _CannedFeatureFlagsExecutor.withRawValue(Object value)
      : _emitsRow = true,
        _value = value;

  final bool _emitsRow;
  final Object? _value;
  final List<String> statements = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    statements.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from public.feature_flags')) {
      if (!_emitsRow) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'enabled': _value},
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    statements.add(sql);
    this.parameters.add(parameters);
    return 0;
  }
}
