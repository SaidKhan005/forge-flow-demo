// Lane B B11.2.b — StepUpChallengesRepository unit tests.
//
// Exercises the repository pattern + SET LOCAL injection in isolation,
// with a fake Postgres pool that records every executed SQL string +
// parameter map. Mirrors the test discipline established in
// `handoff_codes_repository_test.dart` (B11.1).
//
// What we assert:
//   * emit runs through the tenant transaction wrapper (SET LOCAL
//     app.operator_id / location_id / user_id) before the INSERT.
//   * emit runs the inline reaper DELETE before the INSERT.
//   * emit generates an opaque challenge_id matching the migration's
//     CHECK shape (`^[A-Za-z0-9_-]+$`, 22..64 chars).
//   * emit clamps challenge TTL to the 15-minute hard ceiling.
//   * consume issues an atomic UPDATE … RETURNING with the predicate
//     (consumed_at IS NULL AND expires_at > now() AND route_path = $
//     route AND user_id = $user AND operator_id = $operator) so a
//     replay yields null + a wrong-operator caller cannot consume.
//   * lookupForReplayCheck runs through `withSystem` (BYPASSRLS) so
//     the consume-failure classifier in StepUpChallengeRouter can
//     detect the cross-tenant case.
//   * Repository extends OperatorScopedRepository (compile-time pin).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/operator_scoped_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/step_up_challenges_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';

const String _opB = '44444444-4444-4444-4444-444444444444';

void main() {
  group('StepUpChallengesRepository.emit', () {
    test('runs SET LOCAL via wrapper, then reaper DELETE, then INSERT',
        () async {
      final pool = _RecordingPool();
      final repo = StepUpChallengesRepository(TenantTransactionWrapper(pool));

      final challengeId = await repo.emit(
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        routePath: '/v1/auth/password/change',
        requiredAcr: 'urn:mfa',
        requiredFreshnessSeconds: 300,
        challengeTtl: const Duration(seconds: 300),
        sourceActorKind: 'user',
        sourceDeviceFingerprint: 'fp-web-1',
      );

      expect(pool.transactions, hasLength(1));
      final tx = pool.transactions.single;
      // 4 set_config calls (operator/location/user/bypass_rls_audit)
      // + reaper DELETE + INSERT … RETURNING.
      expect(tx.executedSql.length, greaterThanOrEqualTo(6));
      expect(tx.executedSql[0], contains("set_config('app.operator_id'"));
      expect(tx.executedSql[1], contains("set_config('app.location_id'"));
      expect(tx.executedSql[2], contains("set_config('app.user_id'"));
      expect(tx.executedSql[3], contains("set_config('app.bypass_rls_audit'"));
      final reaperSql = tx.executedSql[4];
      expect(reaperSql, contains('delete from public.auth_step_up_challenges'));
      expect(reaperSql, contains('operator_id = @operator_id'));
      final insertSql = tx.executedSql[5];
      expect(insertSql, contains('insert into public.auth_step_up_challenges'));
      expect(insertSql, contains('returning challenge_id'));

      // Migration CHECK: challenge_id shape is base64-url, 22..64 chars.
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(challengeId), isTrue);
      expect(challengeId.length, equals(22));
      expect(tx.commitCount, equals(1));
    });

    test('binds operator_id + user_id + route_path + acr + ttl + fingerprint',
        () async {
      final pool = _RecordingPool();
      final repo = StepUpChallengesRepository(TenantTransactionWrapper(pool));

      await repo.emit(
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        routePath: '/v1/auth/session/revoke',
        requiredAcr: 'urn:mfa',
        requiredFreshnessSeconds: 300,
        challengeTtl: const Duration(seconds: 300),
        sourceActorKind: 'user',
        sourceDeviceFingerprint: 'fp-web-1',
      );

      final tx = pool.transactions.single;
      // INSERT is the last executed SQL.
      final insertParams = tx.parameters.last;
      expect(insertParams['operator_id'], equals(_opA));
      expect(insertParams['user_id'], equals(_userA));
      expect(insertParams['location_id'], equals(_locA));
      expect(insertParams['route_path'], equals('/v1/auth/session/revoke'));
      expect(insertParams['required_acr'], equals('urn:mfa'));
      expect(insertParams['required_freshness_seconds'], equals(300));
      expect(insertParams['ttl_seconds'], equals('300'));
      expect(insertParams['source_actor_kind'], equals('user'));
      expect(insertParams['source_device_fingerprint'], equals('fp-web-1'));
    });

    test('clamps challenge TTL to 15 minutes (migration ceiling)',
        () async {
      final pool = _RecordingPool();
      final repo = StepUpChallengesRepository(TenantTransactionWrapper(pool));

      // Pass 30 minutes — migration would reject; repo clamps to 15min.
      await repo.emit(
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        routePath: '/v1/auth/password/change',
        requiredAcr: 'urn:mfa',
        requiredFreshnessSeconds: 300,
        challengeTtl: const Duration(minutes: 30),
        sourceActorKind: 'user',
        sourceDeviceFingerprint: null,
      );

      final tx = pool.transactions.single;
      final insertParams = tx.parameters.last;
      // 900 seconds = 15 minutes.
      expect(insertParams['ttl_seconds'], equals('900'));
    });
  });

  group('StepUpChallengesRepository.consume', () {
    test('atomic UPDATE … RETURNING with full one-shot predicate',
        () async {
      final consumedAt = DateTime.utc(2026, 5, 13, 10);
      final pool = _RecordingPool(
        consumeReturning: <PostgresRow>[
          <String, Object?>{
            'challenge_id': 'CHALLENGE_AAA',
            'operator_id': _opA,
            'location_id': _locA,
            'user_id': _userA,
            'route_path': '/v1/auth/session/revoke',
            'required_acr': 'urn:mfa',
            'required_freshness_seconds': 300,
            'consumed_at': consumedAt,
          },
        ],
      );
      final repo = StepUpChallengesRepository(TenantTransactionWrapper(pool));

      final result = await repo.consume(
        callerOperatorId: _opA,
        callerLocationId: _locA,
        callerUserId: _userA,
        callerRoutePath: '/v1/auth/session/revoke',
        challengeId: 'CHALLENGE_AAA',
      );

      expect(result, isNotNull);
      expect(result!.challengeId, equals('CHALLENGE_AAA'));
      expect(result.operatorId, equals(_opA));
      expect(result.userId, equals(_userA));
      expect(result.routePath, equals('/v1/auth/session/revoke'));
      expect(result.requiredAcr, equals('urn:mfa'));
      expect(result.requiredFreshnessSeconds, equals(300));

      // Verify the UPDATE predicate hits all five clauses.
      final tx = pool.transactions.single;
      final updateSql = tx.executedSql.last;
      expect(updateSql, contains('update public.auth_step_up_challenges'));
      expect(updateSql, contains('set consumed_at = now()'));
      expect(updateSql, contains('challenge_id = @challenge_id'));
      expect(updateSql, contains('operator_id = @operator_id'));
      expect(updateSql, contains('user_id = @user_id'));
      expect(updateSql, contains('route_path = @route_path'));
      expect(updateSql, contains('consumed_at is null'));
      expect(updateSql, contains('expires_at > now()'));
    });

    test('returns null when predicate matches no row (replay attempt)',
        () async {
      final pool = _RecordingPool(consumeReturning: const <PostgresRow>[]);
      final repo = StepUpChallengesRepository(TenantTransactionWrapper(pool));

      final result = await repo.consume(
        callerOperatorId: _opA,
        callerLocationId: _locA,
        callerUserId: _userA,
        callerRoutePath: '/v1/auth/session/revoke',
        challengeId: 'CHALLENGE_AAA',
      );

      expect(result, isNull);
    });

    test('binds caller_operator_id so a wrong-operator caller cannot consume',
        () async {
      final pool = _RecordingPool(consumeReturning: const <PostgresRow>[]);
      final repo = StepUpChallengesRepository(TenantTransactionWrapper(pool));

      await repo.consume(
        callerOperatorId: _opB, // not the issuer
        callerLocationId: _locA,
        callerUserId: _userA,
        callerRoutePath: '/v1/auth/session/revoke',
        challengeId: 'CHALLENGE_AAA',
      );

      final tx = pool.transactions.single;
      final updateParams = tx.parameters.last;
      expect(updateParams['operator_id'], equals(_opB));
      expect(updateParams['challenge_id'], equals('CHALLENGE_AAA'));
    });
  });

  group('StepUpChallengesRepository.lookupForReplayCheck', () {
    test('runs through withSystem (BYPASSRLS) so cross-operator '
        'state is visible to the classifier', () async {
      final expiresAt = DateTime.utc(2026, 5, 13, 10, 5);
      final pool = _RecordingPool(
        lookupReturning: <PostgresRow>[
          <String, Object?>{
            'operator_id': _opB, // different operator
            'user_id': _userA,
            'route_path': '/v1/auth/session/revoke',
            'expires_at': expiresAt,
            'consumed_at': null,
          },
        ],
      );
      final repo = StepUpChallengesRepository(TenantTransactionWrapper(pool));

      final state = await repo.lookupForReplayCheck(
        challengeId: 'CHALLENGE_AAA',
      );

      expect(state, isNotNull);
      expect(state!.operatorId, equals(_opB));
      expect(state.userId, equals(_userA));
      expect(state.routePath, equals('/v1/auth/session/revoke'));
      expect(state.expiresAt, equals(expiresAt));
      expect(state.consumedAt, isNull);

      // System-scope path: the tx runs 4 set_config + 1 select.
      final tx = pool.transactions.single;
      // First, the bypass-RLS audit marker is set.
      final bypassSql = tx.executedSql
          .firstWhere((sql) => sql.contains("'app.bypass_rls_audit'"));
      expect(bypassSql, isNotEmpty);
      // The SET ROLE forge_admin runs in admin path.
      final roleSql = tx.executedSql.firstWhere(
        (sql) => sql.contains('set local role'),
        orElse: () => '',
      );
      expect(roleSql, contains('forge_admin'));
      final selectSql = tx.executedSql.last;
      expect(selectSql, contains('select'));
      expect(selectSql, contains('from public.auth_step_up_challenges'));
    });

    test('returns null when challenge does not exist anywhere', () async {
      final pool = _RecordingPool(lookupReturning: const <PostgresRow>[]);
      final repo = StepUpChallengesRepository(TenantTransactionWrapper(pool));

      final state = await repo.lookupForReplayCheck(
        challengeId: 'NONEXISTENT',
      );
      expect(state, isNull);
    });
  });

  group('StepUpChallengesRepository constants', () {
    test('challenge TTL ceiling is 15 minutes (matches migration CHECK)', () {
      expect(
        StepUpChallengesRepository.kChallengeTtlCeiling,
        equals(const Duration(minutes: 15)),
      );
    });

    test('reaper horizon is 1 day', () {
      expect(
        StepUpChallengesRepository.kReaperHorizon,
        equals(const Duration(days: 1)),
      );
    });
  });

  group('StepUpChallengesRepository inheritance', () {
    test('extends OperatorScopedRepository (primary defense)', () {
      final repo = StepUpChallengesRepository(
        TenantTransactionWrapper(_RecordingPool()),
      );
      final OperatorScopedRepository base = repo;
      // ignore: unnecessary_statements
      base;
    });
  });
}

class _RecordingTransaction extends PostgresTransaction {
  _RecordingTransaction({
    this.consumeReturning,
    this.lookupReturning,
  });

  final List<PostgresRow>? consumeReturning;
  final List<PostgresRow>? lookupReturning;

  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  int commitCount = 0;
  int rollbackCount = 0;
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('insert into public.auth_step_up_challenges')) {
      // Echo back the bound challenge_id.
      final boundId = parameters['challenge_id'];
      return <PostgresRow>[
        <String, Object?>{
          'challenge_id': boundId is String ? boundId : '',
        },
      ];
    }
    if (sql.contains('update public.auth_step_up_challenges')) {
      return consumeReturning ?? const <PostgresRow>[];
    }
    if (sql.contains('select') &&
        sql.contains('from public.auth_step_up_challenges')) {
      return lookupReturning ?? const <PostgresRow>[];
    }
    // SET LOCAL set_config calls return an empty row set or the value.
    if (sql.contains('select set_config')) {
      return <PostgresRow>[
        <String, Object?>{},
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 1;
  }

  @override
  Future<void> commit() async {
    if (_finalized) return;
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
    rollbackCount += 1;
  }
}

class _RecordingPool implements PostgresPool {
  _RecordingPool({
    this.consumeReturning,
    this.lookupReturning,
  });

  final List<PostgresRow>? consumeReturning;
  final List<PostgresRow>? lookupReturning;

  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(
      consumeReturning: consumeReturning,
      lookupReturning: lookupReturning,
    );
    transactions.add(tx);
    return tx;
  }
}
