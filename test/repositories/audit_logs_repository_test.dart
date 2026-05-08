// Phase 9.0Σ.f B.2 — AuditLogsRepository unit tests.
//
// Asserts the SQL shape and parameter mapping that the BEFORE INSERT
// chain trigger needs:
//
//   * `chain_date` is computed from the UTC date of `occurred_at` so
//     the trigger's CHECK constraint
//     (`chain_date = (occurred_at at time zone 'UTC')::date`) holds.
//   * `actor_kind = 'user'` rows carry only `actor_user_id`;
//     `actor_kind = 'service'` rows carry only `actor_principal_id`.
//     The DB CHECK `audit_logs_actor_shape_check` enforces this — the
//     repository surface lets callers pass either slot, and the
//     fan-out callsites are responsible for the right mapping.
//   * `payload` is encoded as canonical JSON (so the trigger's
//     canonical-bytes encoding and the verifier line up).
//   * `prev_row_hash` / `row_hash` are NOT supplied; the trigger
//     computes both server-side.
//
// The end-to-end chain integrity (prev/row hash recomputation, single-
// byte tamper detection, chain boundary isolation) lives in
// `test/phase_9_0sigma_f_audit_chain_e2e_test.dart` (B37); this file
// is the parameter-mapping unit slice.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';
const String _spId = '99999999-9999-9999-9999-999999999999';

void main() {
  group('AuditLogsRepository.writeRow', () {
    test(
      'binds INSERT into public.audit_logs and never supplies '
      'prev_row_hash / row_hash (the BEFORE INSERT trigger sets them)',
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
        // The 2026-05-08 P1 hardening adds a `current_setting` SELECT
        // before the insert (defense-in-depth tenant cross-check). The
        // insert is the second statement when the tenant context is
        // unset (system path) — exec returns no rows, so the writer
        // accepts the parameter. Tests assert the INSERT shape via
        // `exec.insertStatement` to stay decoupled from the read.
        expect(
          exec.insertStatement,
          contains('insert into public.audit_logs'),
        );
        expect(exec.insertStatement, isNot(contains('prev_row_hash')));
        expect(exec.insertStatement, isNot(contains('row_hash')));
      },
    );

    test(
      'computes chain_date from the UTC date of occurred_at so the '
      'trigger CHECK (chain_date = occurred_at::date) holds even when '
      'the caller hands in a non-UTC instant',
      () async {
        final exec = _RecordingExecutor();
        const repo = AuditLogsRepository();
        // 2026-04-30 23:30 EDT = 2026-05-01 03:30 UTC; the chain_date
        // must be the UTC date (2026-05-01), not the wall-clock date.
        final localInstant = DateTime.utc(
          2026,
          5,
          1,
          3,
          30,
        ).toLocal(); // round-trips through local zone
        await repo.writeRow(
          exec,
          operatorId: _opA,
          occurredAt: localInstant,
          actorKind: 'user',
          actorUserId: _userA,
          action: 'auth.user.signed_in',
        );
        final params = exec.insertParameters;
        expect(params['chain_date'], equals('2026-05-01'));
        expect(
          (params['occurred_at']! as DateTime).toUtc(),
          equals(DateTime.utc(2026, 5, 1, 3, 30)),
        );
      },
    );

    test(
      'user actor: actor_kind=user, actor_user_id set, '
      'actor_principal_id null (audit_logs_actor_shape_check)',
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
          targetKind: 'user',
          targetId: _userA,
          action: 'auth.password_changed',
        );
        final params = exec.insertParameters;
        expect(params['actor_kind'], equals('user'));
        expect(params['actor_user_id'], equals(_userA));
        expect(params['actor_principal_id'], isNull);
        expect(params['target_kind'], equals('user'));
        expect(params['target_id'], equals(_userA));
        expect(params['action'], equals('auth.password_changed'));
        expect(params['operator_id'], equals(_opA));
        expect(params['location_id'], equals(_locA));
      },
    );

    test(
      'service actor: actor_kind=service, actor_principal_id carries '
      'the canonical sp:<uuid> JWT subject, actor_user_id null',
      () async {
        final exec = _RecordingExecutor();
        const repo = AuditLogsRepository();
        await repo.writeRow(
          exec,
          operatorId: _opA,
          locationId: _locA,
          occurredAt: DateTime.utc(2026, 4, 30, 12),
          actorKind: 'service',
          actorPrincipalId: 'sp:$_spId',
          action: 'admin.service_principal.issue_token',
          payload: const <String, Object?>{'service_principal_id': _spId},
        );
        final params = exec.insertParameters;
        expect(params['actor_kind'], equals('service'));
        expect(params['actor_user_id'], isNull);
        expect(params['actor_principal_id'], equals('sp:$_spId'));
        expect(
          params['action'],
          equals('admin.service_principal.issue_token'),
        );
      },
    );

    test('payload is encoded as canonical JSON so the SQL trigger and '
        'the verifier compute the same canonical bytes', () async {
      final exec = _RecordingExecutor();
      const repo = AuditLogsRepository();
      await repo.writeRow(
        exec,
        operatorId: _opA,
        occurredAt: DateTime.utc(2026, 4, 30, 12),
        actorKind: 'user',
        actorUserId: _userA,
        action: 'auth.user.signed_in',
        payload: const <String, Object?>{
          'method': 'password',
          'count': 3,
        },
      );
      final params = exec.parameters.single;
      final encoded = params['payload'] as String;
      // The binding sends the JSON text; PG's `::jsonb` cast normalizes
      // key order for the trigger.
      final decoded = jsonDecode(encoded);
      expect(decoded, equals(<String, Object?>{'method': 'password', 'count': 3}));
    });

    test('omitting occurredAt defaults to "now" in UTC; chain_date '
        'matches that UTC date', () async {
      final exec = _RecordingExecutor();
      const repo = AuditLogsRepository();
      final before = DateTime.now().toUtc();
      await repo.writeRow(
        exec,
        operatorId: _opA,
        actorKind: 'user',
        actorUserId: _userA,
        action: 'auth.user.signed_in',
      );
      final after = DateTime.now().toUtc();
      final params = exec.parameters.single;
      final occurred = (params['occurred_at']! as DateTime).toUtc();
      expect(occurred.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
      expect(occurred.isBefore(after.add(const Duration(seconds: 1))), isTrue);
      final chainDate = params['chain_date'] as String;
      expect(
        chainDate,
        equals(
          '${occurred.year.toString().padLeft(4, '0')}-'
          '${occurred.month.toString().padLeft(2, '0')}-'
          '${occurred.day.toString().padLeft(2, '0')}',
        ),
      );
    });
  });
}

class _RecordingExecutor implements PostgresExecutor {
  _RecordingExecutor({this.tenantOperatorId});

  /// When non-null, the recording executor responds to the
  /// `current_setting('app.operator_id', true)` probe with this
  /// value, simulating a tenant-scoped transaction whose
  /// `SET LOCAL app.operator_id` is set. When null (the default),
  /// the probe returns no rows — the system / no-tenant path.
  final String? tenantOperatorId;

  final List<String> statements = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];

  String get insertStatement => statements.firstWhere(
        (s) => s.contains('insert into public.audit_logs'),
        orElse: () => throw StateError('no audit_logs INSERT recorded'),
      );

  PostgresParameters get insertParameters {
    final idx = statements.indexWhere(
      (s) => s.contains('insert into public.audit_logs'),
    );
    if (idx < 0) {
      throw StateError('no audit_logs INSERT recorded');
    }
    return parameters[idx];
  }

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    statements.add(sql);
    this.parameters.add(parameters);
    if (sql.contains("current_setting('app.operator_id'")) {
      final tenant = tenantOperatorId;
      if (tenant == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'operator_id': tenant},
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
    return 1;
  }
}
