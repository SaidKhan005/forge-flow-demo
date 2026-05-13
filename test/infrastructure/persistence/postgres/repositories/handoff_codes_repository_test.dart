// Lane B B11.1 — HandoffCodesRepository unit tests.
//
// Exercises the repository pattern + SET LOCAL injection in isolation,
// with a fake Postgres pool that records every executed SQL string +
// parameter map. Mirrors the test discipline established in
// `test/operator_scoped_repository_test.dart`.
//
// What we assert:
//   * mint runs through the tenant transaction wrapper (SET LOCAL
//     app.operator_id / location_id / user_id) before the INSERT.
//   * mint generates an opaque code matching the migration's CHECK
//     shape (`^[A-Za-z0-9_-]+$`, 22..64 chars).
//   * mint runs the inline reaper DELETE before the INSERT.
//   * redeem issues an atomic UPDATE … RETURNING with the predicate
//     `consumed_at IS NULL AND expires_at > now() AND operator_id =
//     @operator_id` so a replay (no rows returned) yields null and
//     a wrong-operator caller cannot consume a row.
//   * countRecentForUser is index-scan-friendly (operator_id leading)
//     and binds `@operator_id` + `@user_id` + `@since`.
//   * lookupForReplayCheck runs through `withSystem` (BYPASSRLS) so
//     the redeem failure classifier can detect the cross-tenant case.
//   * hashCodeForAudit is a deterministic SHA-256 hex.

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:convert';

import 'package:forge_and_flow/infrastructure/persistence/postgres/operator_scoped_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/handoff_codes_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';

const String _opB = '44444444-4444-4444-4444-444444444444';

void main() {
  group('HandoffCodesRepository.mint', () {
    test('runs SET LOCAL via wrapper, then reaper DELETE, then INSERT',
        () async {
      final pool = _RecordingPool(
        insertCodeOverride: 'AAAAAAAAAAAAAAAAAAAAAA',
      );
      final repo = HandoffCodesRepository(TenantTransactionWrapper(pool));

      final code = await repo.mint(
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        targetPath: '/operator-web/team',
        sourceDeviceFingerprint: 'fp-mobile-1',
      );

      expect(pool.transactions, hasLength(1));
      final tx = pool.transactions.single;
      // SET LOCAL block (4 set_config calls — operator/location/user/
      // bypass_rls_audit) followed by reaper DELETE then INSERT … RETURNING.
      expect(tx.executedSql.length, greaterThanOrEqualTo(6));
      expect(tx.executedSql[0], contains("set_config('app.operator_id'"));
      expect(tx.executedSql[1], contains("set_config('app.location_id'"));
      expect(tx.executedSql[2], contains("set_config('app.user_id'"));
      expect(tx.executedSql[3], contains("set_config('app.bypass_rls_audit'"));
      // Reaper sweep — operator-scoped DELETE.
      final reaperSql = tx.executedSql[4];
      expect(reaperSql, contains('delete from public.handoff_codes'));
      expect(reaperSql, contains('operator_id = @operator_id'));
      // INSERT — server-side gen, returns code.
      final insertSql = tx.executedSql[5];
      expect(insertSql, contains('insert into public.handoff_codes'));
      expect(insertSql, contains("now() + interval '60 seconds'"));
      expect(insertSql, contains('returning code'));

      // The mint passes the code as a bound parameter (server-side
      // gen via gen_random_bytes happens in Dart inside this repo;
      // the migration's CHECK constraint still validates the shape).
      // The fake pool returned the override code so the test sees it.
      expect(code, equals('AAAAAAAAAAAAAAAAAAAAAA'));
      expect(tx.commitCount, equals(1));
    });

    test('generates a code matching the migration shape constraint',
        () async {
      final pool = _RecordingPool();
      final repo = HandoffCodesRepository(TenantTransactionWrapper(pool));

      final code = await repo.mint(
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        targetPath: '/operator-web/team',
        sourceDeviceFingerprint: null,
      );

      // Migration CHECK: code shape is base64-url body, 22..64 chars.
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(code), isTrue);
      expect(code.length, greaterThanOrEqualTo(22));
      expect(code.length, lessThanOrEqualTo(64));
      // 22-char base64 of 16 bytes is the standard envelope.
      expect(code, hasLength(22));
    });

    test('binds operator_id + user_id + target_path + fingerprint',
        () async {
      final pool = _RecordingPool();
      final repo = HandoffCodesRepository(TenantTransactionWrapper(pool));

      await repo.mint(
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        targetPath: '/operator-web/team',
        sourceDeviceFingerprint: 'fp-mobile-1',
      );

      final tx = pool.transactions.single;
      // INSERT is the last executed SQL.
      final insertParams = tx.parameters.last;
      expect(insertParams['operator_id'], equals(_opA));
      expect(insertParams['user_id'], equals(_userA));
      expect(insertParams['location_id'], equals(_locA));
      expect(insertParams['target_path'], equals('/operator-web/team'));
      expect(insertParams['source_device_fingerprint'], equals('fp-mobile-1'));
      // The opaque code MUST be passed as a parameter (not concatenated)
      // so a malformed body cannot smuggle SQL into the INSERT.
      expect(insertParams['code'], isA<String>());
    });
  });

  group('HandoffCodesRepository.redeem', () {
    test('issues atomic UPDATE … RETURNING with predicate '
        '(consumed_at IS NULL AND expires_at > now() AND '
        'operator_id matches caller)', () async {
      final fakeRedeemed = <PostgresRow>[
        <String, Object?>{
          'code': 'AAAAAAAAAAAAAAAAAAAAAA',
          'user_id': _userA,
          'operator_id': _opA,
          'location_id': _locA,
          'target_path': '/operator-web/team',
          'source_device_fingerprint': 'fp-mobile-1',
          'consumed_at': DateTime.utc(2026, 5, 12, 21, 30),
        },
      ];
      final pool = _RecordingPool(redeemReturning: fakeRedeemed);
      final repo = HandoffCodesRepository(TenantTransactionWrapper(pool));

      final result = await repo.redeem(
        callerOperatorId: _opA,
        callerLocationId: _locA,
        callerUserId: _userA,
        code: 'AAAAAAAAAAAAAAAAAAAAAA',
      );

      expect(result, isNotNull);
      expect(result!.userId, equals(_userA));
      expect(result.operatorId, equals(_opA));
      expect(result.locationId, equals(_locA));
      expect(result.targetPath, equals('/operator-web/team'));
      expect(result.sourceDeviceFingerprint, equals('fp-mobile-1'));

      final tx = pool.transactions.single;
      final updateSql = tx.executedSql.last;
      expect(updateSql, contains('update public.handoff_codes'));
      expect(updateSql, contains('set consumed_at = now()'));
      expect(updateSql, contains('where code = @code'));
      expect(updateSql, contains('and operator_id = @operator_id::uuid'));
      expect(updateSql, contains('and consumed_at is null'));
      expect(updateSql, contains('and expires_at > now()'));
      expect(updateSql, contains('returning'));
    });

    test('returns null on replay (UPDATE returns 0 rows)', () async {
      final pool = _RecordingPool(redeemReturning: <PostgresRow>[]);
      final repo = HandoffCodesRepository(TenantTransactionWrapper(pool));

      final result = await repo.redeem(
        callerOperatorId: _opA,
        callerLocationId: _locA,
        callerUserId: _userA,
        code: 'AAAAAAAAAAAAAAAAAAAAAA',
      );
      expect(result, isNull);
    });

    test('binds caller operator_id (defense in depth even if RLS '
        'were loosened)', () async {
      final pool = _RecordingPool(redeemReturning: <PostgresRow>[]);
      final repo = HandoffCodesRepository(TenantTransactionWrapper(pool));

      await repo.redeem(
        callerOperatorId: _opA,
        callerLocationId: _locA,
        callerUserId: _userA,
        code: 'AAAAAAAAAAAAAAAAAAAAAA',
      );
      final tx = pool.transactions.single;
      final params = tx.parameters.last;
      expect(params['operator_id'], equals(_opA));
      expect(params['code'], equals('AAAAAAAAAAAAAAAAAAAAAA'));
    });
  });

  group('HandoffCodesRepository.lookupForReplayCheck', () {
    test('runs through withSystem (BYPASSRLS) so cross-operator codes '
        'are visible for the redeem-failure classifier', () async {
      final pool = _RecordingPool(
        lookupReturning: <PostgresRow>[
          <String, Object?>{
            'operator_id': _opB,
            'expires_at': DateTime.utc(2026, 5, 12, 21, 30, 0).add(
              const Duration(seconds: 60),
            ),
            'consumed_at': null,
          },
        ],
      );
      final repo = HandoffCodesRepository(TenantTransactionWrapper(pool));

      final state = await repo.lookupForReplayCheck(
        code: 'AAAAAAAAAAAAAAAAAAAAAA',
        adminReason: 'auth.handoff.redeem_failure_classify',
      );

      expect(state, isNotNull);
      expect(state!.operatorId, equals(_opB));
      expect(state.isConsumed, isFalse);

      final tx = pool.transactions.single;
      // System-scope SET LOCAL: app.bypass_rls_audit = 'system:<reason>'.
      // The first executed SQL should be the bypass marker.
      expect(
        tx.executedSql.first,
        contains("set_config('app.bypass_rls_audit'"),
      );
      expect(tx.parameters.first['value'], contains('system:'));
      expect(
        tx.parameters.first['value'],
        contains('auth.handoff.redeem_failure_classify'),
      );
    });

    test('returns null when code does not exist anywhere', () async {
      final pool = _RecordingPool(lookupReturning: <PostgresRow>[]);
      final repo = HandoffCodesRepository(TenantTransactionWrapper(pool));

      final state = await repo.lookupForReplayCheck(
        code: 'unknown',
        adminReason: 'test',
      );
      expect(state, isNull);
    });
  });

  group('HandoffCodesRepository.countRecentForUser', () {
    test('binds (operator_id, user_id, since) and reads count(*)::int',
        () async {
      final pool = _RecordingPool(
        countReturning: <PostgresRow>[
          <String, Object?>{'cnt': 7},
        ],
      );
      final repo = HandoffCodesRepository(TenantTransactionWrapper(pool));

      final count = await repo.countRecentForUser(
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
      );
      expect(count, equals(7));

      final tx = pool.transactions.single;
      final selectSql = tx.executedSql.last;
      expect(selectSql, contains('select count(*)::int as cnt'));
      expect(selectSql, contains('operator_id = @operator_id::uuid'));
      expect(selectSql, contains('user_id = @user_id::uuid'));
      expect(selectSql, contains("created_at >= @since::timestamptz"));

      final params = tx.parameters.last;
      expect(params['operator_id'], equals(_opA));
      expect(params['user_id'], equals(_userA));
      expect(params['since'], isA<String>());
    });
  });

  group('HandoffCodesRepository.hashCodeForAudit', () {
    test('produces deterministic SHA-256 hex of the input code', () {
      const code = 'AAAAAAAAAAAAAAAAAAAAAA';
      final hashed = HandoffCodesRepository.hashCodeForAudit(code);
      final expected = sha256.convert(utf8.encode(code)).toString();
      expect(hashed, equals(expected));
      expect(hashed, hasLength(64));
      expect(RegExp(r'^[a-f0-9]{64}$').hasMatch(hashed), isTrue);
    });

    test('different codes produce different hashes', () {
      final h1 = HandoffCodesRepository.hashCodeForAudit('one');
      final h2 = HandoffCodesRepository.hashCodeForAudit('two');
      expect(h1, isNot(equals(h2)));
    });
  });

  group('HandoffCodesRepository constants', () {
    test('TTL is 60 seconds (matches migration CHECK)', () {
      expect(HandoffCodesRepository.kHandoffTtl, equals(const Duration(seconds: 60)));
    });

    test('rate limit is 10 per hour (matches slice doc)', () {
      expect(HandoffCodesRepository.kRateLimitPerHour, equals(10));
    });

    test('reaper horizon is 1 day (inline reaper picks option 2)', () {
      expect(HandoffCodesRepository.kReaperHorizon, equals(const Duration(days: 1)));
    });
  });
}

/// Recording transaction. Captures every executed SQL + parameter map
/// and routes the various read shapes (insert RETURNING, redeem
/// UPDATE … RETURNING, replay-check SELECT, count SELECT) to the
/// per-test override hooks. Models the same recording posture as
/// `_RecordingTransaction` in `test/operator_scoped_repository_test.dart`.
class _RecordingTransaction extends PostgresTransaction {
  _RecordingTransaction({
    this.insertCodeOverride,
    this.redeemReturning,
    this.lookupReturning,
    this.countReturning,
  });

  /// When set, the INSERT … RETURNING code returns this value instead
  /// of whatever the production codepath generated. Lets the test
  /// assert exact code surface text.
  final String? insertCodeOverride;
  final List<PostgresRow>? redeemReturning;
  final List<PostgresRow>? lookupReturning;
  final List<PostgresRow>? countReturning;

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
    if (sql.contains('insert into public.handoff_codes')) {
      // Production binds the freshly-generated code as `@code`. We
      // either echo it back or substitute the override so test
      // assertions can deal with deterministic output.
      final boundCode = parameters['code'];
      final returnedCode = insertCodeOverride ??
          (boundCode is String ? boundCode : '');
      return <PostgresRow>[
        <String, Object?>{'code': returnedCode},
      ];
    }
    if (sql.contains('update public.handoff_codes')) {
      return redeemReturning ?? const <PostgresRow>[];
    }
    if (sql.contains('select count(*)::int')) {
      return countReturning ?? const <PostgresRow>[
        <String, Object?>{'cnt': 0},
      ];
    }
    if (sql.contains('select') && sql.contains('from public.handoff_codes')) {
      return lookupReturning ?? const <PostgresRow>[];
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
    this.insertCodeOverride,
    this.redeemReturning,
    this.lookupReturning,
    this.countReturning,
  });

  final String? insertCodeOverride;
  final List<PostgresRow>? redeemReturning;
  final List<PostgresRow>? lookupReturning;
  final List<PostgresRow>? countReturning;

  final List<_RecordingTransaction> transactions = <_RecordingTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _RecordingTransaction(
      insertCodeOverride: insertCodeOverride,
      redeemReturning: redeemReturning,
      lookupReturning: lookupReturning,
      countReturning: countReturning,
    );
    transactions.add(tx);
    return tx;
  }
}

// Sanity: keep the OperatorScopedRepository surface referenced so a
// future refactor that breaks the inheritance is caught at compile
// time.
// ignore: unused_element
void _ensureBaseClassInheritance() {
  final HandoffCodesRepository repo = HandoffCodesRepository(
    TenantTransactionWrapper(_RecordingPool()),
  );
  final OperatorScopedRepository base = repo;
  // ignore: unused_local_variable
  final _ = base;
}
