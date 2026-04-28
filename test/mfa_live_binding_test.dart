// Phase 9 live-closeout B11/B12/B13 tests.
//
// Covers:
//   * ScaffoldFailingFirebaseMfaClient fail-closed default.
//   * SecureRandomRecoveryCodeSaltSource produces 16-byte salts.
//   * FirebaseMfaEnrollmentService composes the adapter with the
//     recovery-code generator + hasher: returns N codes + N hashes
//     from confirmTotpEnrollment, surfaces failures verbatim, uses
//     firebase_factor_uid from metadata when present.
//   * MfaFactorsRepository SQL contract (insertTotpFactor /
//     insertRecoveryCodeFactor / markRecoveryCodeUsed /
//     revokeTotpFactor / listActiveRecoveryCodeFactors) under a
//     fake PostgresPool — parameter binding + RETURNING projection.
//   * RecoveryCodeAttemptLimiter: allow on empty / rate-limit on
//     1-minute window / daily-exhausted on 5-in-24h /
//     ScaffoldFailingRecoveryCodeAttemptStore fail-closed.
//   * RecoveryCodeConsumer end-to-end: rate-limit short-circuit,
//     happy path consume, invalid code path, race-condition
//     "already used" handling, and the locked policy that EVERY
//     attempt (valid + invalid) burns one budget slot.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/mfa/firebase_mfa_client.dart';
import 'package:forge_and_flow/services/mfa/firebase_mfa_enrollment_service.dart';
import 'package:forge_and_flow/services/mfa/mfa_enrollment_service.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_attempt_limiter.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_consumer.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_generator.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_hasher.dart';

const String _validOpId = '11111111-1111-1111-1111-111111111111';
const String _validLocId = '22222222-2222-2222-2222-222222222222';
const String _validUserId = '33333333-3333-3333-3333-333333333333';
const String _validFactorId = '44444444-4444-4444-4444-444444444444';

void main() {
  group('ScaffoldFailingFirebaseMfaClient (B11)', () {
    test('every entry point throws so production fails closed', () async {
      const client = ScaffoldFailingFirebaseMfaClient();
      await expectLater(
        client.beginTotpEnrollment(
          userId: 'u',
          userEmail: 'u@example.test',
          issuerName: 'F&F',
        ),
        throwsStateError,
      );
      await expectLater(
        client.confirmTotpEnrollment(factorId: 'f', oneTimeCode: '000000'),
        throwsStateError,
      );
      await expectLater(
        client.unenrollFactor(userId: 'u', factorId: 'f'),
        throwsStateError,
      );
    });
  });

  group('SecureRandomRecoveryCodeSaltSource (B11)', () {
    test('produces 16-byte salts', () {
      final source = SecureRandomRecoveryCodeSaltSource();
      final salt = source.nextSalt();
      expect(salt, isA<Uint8List>());
      expect(salt.length, equals(16));
    });
  });

  group('FirebaseMfaEnrollmentService (B11)', () {
    FirebaseMfaEnrollmentService buildService({
      FirebaseMfaConfirmOutcome? confirmOutcome,
      int recoveryCodeCount = 10,
    }) {
      final client = _FakeFirebaseMfaClient(
        nextBegin: const FirebaseMfaTotpBeginPayload(
          factorId: 'fb-factor-1',
          secretBase32: 'JBSWY3DPEHPK3PXP',
          otpAuthUrl: 'otpauth://totp/Forge%20%26%20Flow:u@example.test?secret=...',
        ),
        nextConfirm: confirmOutcome,
      );
      return FirebaseMfaEnrollmentService(
        client: client,
        codeGenerator: RecoveryCodeGenerator(random: Random(17)),
        codeHasher: const Sha256RecoveryCodeHasher(),
        saltSource: _StaticSaltSource(saltByte: 0x42),
        recoveryCodeCount: recoveryCodeCount,
      );
    }

    test('beginTotpEnrollment forwards adapter payload into TotpEnrollmentSetup',
        () async {
      final service = buildService();
      final setup = await service.beginTotpEnrollment(
        userId: 'u',
        userEmail: 'u@example.test',
        issuerName: 'Forge & Flow',
      );
      expect(setup.factorId, equals('fb-factor-1'));
      expect(setup.secretBase32, equals('JBSWY3DPEHPK3PXP'));
      expect(setup.otpAuthUrl, contains('otpauth://totp/'));
    });

    test('confirmTotpEnrollment Succeeded -> N plaintext + N hashed codes '
        'with the firebase_factor_uid carried through', () async {
      final service = buildService(
        confirmOutcome: const FirebaseMfaConfirmSucceeded(
          factorMetadata: <String, Object?>{
            'firebase_factor_uid': 'firebase-totp-uid-9',
            'issuer': 'Forge & Flow',
          },
        ),
        recoveryCodeCount: 10,
      );
      final result = await service.confirmTotpEnrollment(
        factorId: 'fb-factor-1',
        oneTimeCode: '123456',
      );
      expect(result, isA<MfaEnrollmentConfirmSuccess>());
      final payload = (result as MfaEnrollmentConfirmSuccess).payload;
      expect(payload.recoveryCodesPlaintext, hasLength(10));
      expect(payload.hashedRecoveryCodes, hasLength(10));
      expect(payload.factorId, equals('firebase-totp-uid-9'));
      // Acceptance: every plaintext code matches the canonical
      // XXXX-XXXX-XXXX shape so the display-once UI can render
      // without further processing.
      for (final code in payload.recoveryCodesPlaintext) {
        expect(RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$').hasMatch(code), isTrue,
            reason: 'code "$code" did not match canonical shape');
      }
      // Acceptance: all hashes share the same salt (per-user salt
      // contract from recovery_code_hasher.dart).
      final sharedSalt = payload.hashedRecoveryCodes.first.saltBase64;
      for (final h in payload.hashedRecoveryCodes) {
        expect(h.saltBase64, equals(sharedSalt));
      }
    });

    test('confirmTotpEnrollment falls back to session factorId when metadata '
        'is missing firebase_factor_uid', () async {
      final service = buildService(
        confirmOutcome: const FirebaseMfaConfirmSucceeded(
          factorMetadata: <String, Object?>{'issuer': 'Forge & Flow'},
        ),
      );
      final result = await service.confirmTotpEnrollment(
        factorId: 'session-factor-x',
        oneTimeCode: '999999',
      );
      final payload = (result as MfaEnrollmentConfirmSuccess).payload;
      expect(payload.factorId, equals('session-factor-x'));
    });

    test('confirmTotpEnrollment Failed -> MfaEnrollmentConfirmFailure preserves '
        'code + message', () async {
      final service = buildService(
        confirmOutcome: const FirebaseMfaConfirmFailed(
          code: 'totp_otp_mismatch',
          message: 'Code did not match. Try again.',
        ),
      );
      final result = await service.confirmTotpEnrollment(
        factorId: 'fb-factor-1',
        oneTimeCode: '000000',
      );
      expect(result, isA<MfaEnrollmentConfirmFailure>());
      final f = result as MfaEnrollmentConfirmFailure;
      expect(f.code, equals('totp_otp_mismatch'));
      expect(f.message, equals('Code did not match. Try again.'));
    });
  });

  group('MfaFactorsRepository (B12 — fake Postgres)', () {
    test('insertTotpFactor runs SET LOCAL + INSERT with bound metadata and '
        'returns the RETURNING factor_id', () async {
      final pool = _MfaFactorsPool(returningFactorId: _validFactorId);
      final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));

      final id = await repo.insertTotpFactor(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
        firebaseFactorUid: 'firebase-totp-uid-9',
      );

      expect(id, equals(_validFactorId));
      final tx = pool.transactions.single;
      final insertSql = tx.executedSql.last;
      expect(insertSql, contains('insert into mfa_factors'));
      expect(insertSql, contains("'totp'"));
      expect(insertSql, contains('returning factor_id'));
      final params = tx.parameters.last;
      expect(params['user_id'], equals(_validUserId));
      // Metadata is bound as serialized JSON so the JSON shape lands
      // in factor_metadata::jsonb verbatim.
      final metaJson = jsonDecode(params['metadata'] as String)
          as Map<String, Object?>;
      expect(metaJson['firebase_factor_uid'], equals('firebase-totp-uid-9'));
      expect(metaJson['issuer'], equals('Forge & Flow'));
    });

    test('insertRecoveryCodeFactor binds the salt + hash JSON', () async {
      final pool = _MfaFactorsPool(returningFactorId: _validFactorId);
      final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));

      final id = await repo.insertRecoveryCodeFactor(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
        hashedCodeJson: const <String, Object?>{
          'salt': 'c2FsdC1zYWx0LXNhbHQtc2FsdA==',
          'hash': 'aGFzaC1oYXNoLWhhc2gtaGFzaC1oYXNoLWhhc2gtaGFzaC1oYXM=',
        },
      );

      expect(id, equals(_validFactorId));
      final params = pool.transactions.single.parameters.last;
      final meta = jsonDecode(params['metadata'] as String)
          as Map<String, Object?>;
      expect(meta['salt'], isA<String>());
      expect(meta['hash'], isA<String>());
    });

    test('markRecoveryCodeUsed updates last_used_at + revoked_at + filters '
        'by factor_type and revoked_at is null', () async {
      final pool = _MfaFactorsPool(returningFactorId: _validFactorId);
      final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
      await repo.markRecoveryCodeUsed(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
        factorId: _validFactorId,
      );
      final tx = pool.transactions.single;
      final sql = tx.executedSql.last;
      expect(sql, contains('update mfa_factors'));
      expect(sql, contains('last_used_at = now()'));
      expect(sql, contains('revoked_at = now()'));
      expect(sql, contains("factor_type = 'recovery_code'"));
      expect(sql, contains('revoked_at is null'));
    });

    test('revokeTotpFactor updates only TOTP rows', () async {
      final pool = _MfaFactorsPool(returningFactorId: _validFactorId);
      final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
      await repo.revokeTotpFactor(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
        factorId: _validFactorId,
      );
      final sql = pool.transactions.single.executedSql.last;
      expect(sql, contains("factor_type = 'totp'"));
    });

    test('listActiveRecoveryCodeFactors projects rows into MfaFactorRecord '
        'with parsed JSON metadata', () async {
      final pool = _MfaFactorsPool(
        returningFactorId: _validFactorId,
        recoveryCodeRows: <PostgresRow>[
          <String, Object?>{
            'factor_id': _validFactorId,
            'user_id': _validUserId,
            'factor_type': 'recovery_code',
            'factor_metadata': jsonEncode(<String, Object?>{
              'salt': 'c2FsdA==',
              'hash': 'aGFzaA==',
            }),
            'enrolled_at': DateTime.utc(2026, 4, 26, 12),
            'last_used_at': null,
            'revoked_at': null,
          },
        ],
      );
      final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
      final factors = await repo.listActiveRecoveryCodeFactors(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
      );
      expect(factors, hasLength(1));
      expect(factors.single.factorId, equals(_validFactorId));
      expect(factors.single.factorType, equals('recovery_code'));
      expect(factors.single.factorMetadata['salt'], equals('c2FsdA=='));
      expect(factors.single.isActive, isTrue);
    });

    test('insertTotpFactor throws when RETURNING produces no rows '
        '(RLS denial scenario)', () async {
      final pool = _MfaFactorsPool(returningFactorId: null);
      final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
      await expectLater(
        repo.insertTotpFactor(
          operatorId: _validOpId,
          locationId: _validLocId,
          userId: _validUserId,
          firebaseFactorUid: 'fb-1',
        ),
        throwsStateError,
      );
    });
  });

  group('RecoveryCodeAttemptLimiter (B13)', () {
    test('allows the first attempt on an empty store', () async {
      final store = InMemoryRecoveryCodeAttemptStore();
      final limiter = RecoveryCodeAttemptLimiter(
        store: store,
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      final decision = await limiter.check(userId: _validUserId);
      expect(decision, isA<RecoveryCodeAttemptAllowed>());
    });

    test('rate-limits within the 1-minute window', () async {
      final store = InMemoryRecoveryCodeAttemptStore();
      var now = DateTime.utc(2026, 4, 26, 12);
      final limiter = RecoveryCodeAttemptLimiter(
        store: store,
        now: () => now,
      );
      await limiter.recordAttempt(userId: _validUserId);
      now = now.add(const Duration(seconds: 30));
      final decision = await limiter.check(userId: _validUserId);
      expect(decision, isA<RecoveryCodeAttemptRateLimited>());
      expect(
        (decision as RecoveryCodeAttemptRateLimited).retryAfter,
        equals(DateTime.utc(2026, 4, 26, 12).add(const Duration(minutes: 1))),
      );
    });

    test('allows again past the 1-minute window', () async {
      final store = InMemoryRecoveryCodeAttemptStore();
      var now = DateTime.utc(2026, 4, 26, 12);
      final limiter = RecoveryCodeAttemptLimiter(
        store: store,
        now: () => now,
      );
      await limiter.recordAttempt(userId: _validUserId);
      now = now.add(const Duration(minutes: 1, seconds: 1));
      expect(
        await limiter.check(userId: _validUserId),
        isA<RecoveryCodeAttemptAllowed>(),
      );
    });

    test('blocks after 5 attempts in the 24h window', () async {
      final store = InMemoryRecoveryCodeAttemptStore();
      var now = DateTime.utc(2026, 4, 26, 0);
      final limiter = RecoveryCodeAttemptLimiter(
        store: store,
        now: () => now,
      );
      // Spread 5 attempts across the 24h window, each beyond the
      // 1-minute rate limit so only the daily budget triggers.
      for (var i = 0; i < 5; i++) {
        await limiter.recordAttempt(userId: _validUserId);
        now = now.add(const Duration(hours: 2));
      }
      // 6th check fails on daily budget.
      final decision = await limiter.check(userId: _validUserId);
      expect(decision, isA<RecoveryCodeAttemptDailyExhausted>());
      // Acceptance: the resetsAt is the oldest in-window attempt + 24h.
      final resets = (decision as RecoveryCodeAttemptDailyExhausted).resetsAt;
      expect(resets, equals(DateTime.utc(2026, 4, 27, 0)));
    });

    test('ScaffoldFailingRecoveryCodeAttemptStore throws on every method',
        () async {
      const store = ScaffoldFailingRecoveryCodeAttemptStore();
      await expectLater(
        store.recentAttempts(
          userId: _validUserId,
          now: DateTime.utc(2026, 4, 26),
          window: const Duration(hours: 24),
        ),
        throwsStateError,
      );
      await expectLater(
        store.recordAttempt(
          userId: _validUserId,
          at: DateTime.utc(2026, 4, 26),
        ),
        throwsStateError,
      );
    });
  });

  group('RecoveryCodeConsumer (B13)', () {
    RecoveryCodeConsumer buildConsumer({
      required _MfaFactorsPool pool,
      required InMemoryRecoveryCodeAttemptStore attemptStore,
      DateTime Function()? now,
    }) {
      final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
      return RecoveryCodeConsumer(
        hasher: const Sha256RecoveryCodeHasher(),
        repository: repo,
        limiter: RecoveryCodeAttemptLimiter(
          store: attemptStore,
          now: now ?? () => DateTime.utc(2026, 4, 26, 12),
        ),
      );
    }

    test('happy path: rate check passes, hash matches, mark used returns '
        'Consumed + records the attempt', () async {
      final salt = Uint8List(16);
      // SHA-256 of (salt || normalized) with the locked hasher.
      final hashed = const Sha256RecoveryCodeHasher().hash(
        normalizedCode: 'AAAABBBBCCCC',
        saltBytes: salt,
      );
      final pool = _MfaFactorsPool(
        returningFactorId: _validFactorId,
        recoveryCodeRows: <PostgresRow>[
          <String, Object?>{
            'factor_id': _validFactorId,
            'user_id': _validUserId,
            'factor_type': 'recovery_code',
            'factor_metadata': jsonEncode(hashed.toJson()),
            'enrolled_at': DateTime.utc(2026, 4, 26, 11),
            'last_used_at': null,
            'revoked_at': null,
          },
        ],
        affectedRowCount: 1,
      );
      final attempts = InMemoryRecoveryCodeAttemptStore();
      final consumer = buildConsumer(pool: pool, attemptStore: attempts);

      final result = await consumer.consume(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
        rawCode: 'AAAA-BBBB-CCCC',
      );

      expect(result, isA<RecoveryCodeConsumed>());
      expect((result as RecoveryCodeConsumed).factorId, equals(_validFactorId));
      // Acceptance: even on the happy path the attempt is recorded
      // so the budget shrinks by 1 (matches the locked policy).
      expect(
        await attempts.recentAttempts(
          userId: _validUserId,
          now: DateTime.utc(2026, 4, 26, 12),
          window: const Duration(hours: 24),
        ),
        hasLength(1),
      );
    });

    test('invalid code: returns Invalid AND still records the attempt',
        () async {
      final pool = _MfaFactorsPool(
        returningFactorId: _validFactorId,
        recoveryCodeRows: const <PostgresRow>[],
      );
      final attempts = InMemoryRecoveryCodeAttemptStore();
      final consumer = buildConsumer(pool: pool, attemptStore: attempts);

      final result = await consumer.consume(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
        rawCode: 'XXXX-YYYY-ZZZZ',
      );

      expect(result, isA<RecoveryCodeInvalid>());
      expect(
        await attempts.recentAttempts(
          userId: _validUserId,
          now: DateTime.utc(2026, 4, 26, 12),
          window: const Duration(hours: 24),
        ),
        hasLength(1),
      );
    });

    test('rate limited: returns RateLimited without touching the repository',
        () async {
      final pool = _MfaFactorsPool(returningFactorId: _validFactorId);
      final attempts = InMemoryRecoveryCodeAttemptStore();
      // Burn the per-minute slot.
      await attempts.recordAttempt(
        userId: _validUserId,
        at: DateTime.utc(2026, 4, 26, 11, 59, 30),
      );
      final consumer = buildConsumer(pool: pool, attemptStore: attempts);

      final result = await consumer.consume(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
        rawCode: 'AAAA-BBBB-CCCC',
      );

      expect(result, isA<RecoveryCodeRateLimited>());
      // Acceptance: no SQL was executed because the limiter
      // short-circuited before the consumer reached the repo.
      expect(pool.transactions, isEmpty);
    });

    test('daily budget exceeded: returns DailyBudgetExceeded', () async {
      final pool = _MfaFactorsPool(returningFactorId: _validFactorId);
      final attempts = InMemoryRecoveryCodeAttemptStore();
      // 5 attempts spread 2 hours apart (so the 1-minute window
      // doesn't hit first).
      for (var i = 0; i < 5; i++) {
        await attempts.recordAttempt(
          userId: _validUserId,
          at: DateTime.utc(2026, 4, 26, 0).add(Duration(hours: 2 * i)),
        );
      }
      final consumer = buildConsumer(
        pool: pool,
        attemptStore: attempts,
        now: () => DateTime.utc(2026, 4, 26, 12),
      );

      final result = await consumer.consume(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
        rawCode: 'AAAA-BBBB-CCCC',
      );

      expect(result, isA<RecoveryCodeDailyBudgetExceeded>());
    });

    test('AlreadyUsed: matched a hash but markRecoveryCodeUsed returned 0 '
        '(racing parallel verify-then-mark)', () async {
      final salt = Uint8List(16);
      final hashed = const Sha256RecoveryCodeHasher().hash(
        normalizedCode: 'AAAABBBBCCCC',
        saltBytes: salt,
      );
      final pool = _MfaFactorsPool(
        returningFactorId: _validFactorId,
        recoveryCodeRows: <PostgresRow>[
          <String, Object?>{
            'factor_id': _validFactorId,
            'user_id': _validUserId,
            'factor_type': 'recovery_code',
            'factor_metadata': jsonEncode(hashed.toJson()),
            'enrolled_at': DateTime.utc(2026, 4, 26, 11),
            'last_used_at': null,
            'revoked_at': null,
          },
        ],
        affectedRowCount: 0, // Race: another caller marked it first.
      );
      final attempts = InMemoryRecoveryCodeAttemptStore();
      final consumer = buildConsumer(pool: pool, attemptStore: attempts);

      final result = await consumer.consume(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
        rawCode: 'AAAA-BBBB-CCCC',
      );

      expect(result, isA<RecoveryCodeAlreadyUsed>());
    });
  });
}

// ─── Helpers ──────────────────────────────────────────────────────────────

class _FakeFirebaseMfaClient implements FirebaseMfaClient {
  _FakeFirebaseMfaClient({required this.nextBegin, this.nextConfirm});

  final FirebaseMfaTotpBeginPayload nextBegin;
  FirebaseMfaConfirmOutcome? nextConfirm;
  int beginCalls = 0;
  int confirmCalls = 0;
  int unenrollCalls = 0;

  @override
  Future<FirebaseMfaTotpBeginPayload> beginTotpEnrollment({
    required String userId,
    required String userEmail,
    required String issuerName,
  }) async {
    beginCalls += 1;
    return nextBegin;
  }

  @override
  Future<FirebaseMfaConfirmOutcome> confirmTotpEnrollment({
    required String factorId,
    required String oneTimeCode,
  }) async {
    confirmCalls += 1;
    return nextConfirm ??
        const FirebaseMfaConfirmFailed(
          code: 'unconfigured',
          message: 'fake client did not specify an outcome',
        );
  }

  @override
  Future<void> unenrollFactor({
    required String userId,
    required String factorId,
  }) async {
    unenrollCalls += 1;
  }
}

class _StaticSaltSource implements RecoveryCodeSaltSource {
  _StaticSaltSource({required this.saltByte});
  final int saltByte;

  @override
  Uint8List nextSalt() {
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = saltByte;
    }
    return out;
  }
}

class _MfaFactorsPool implements PostgresPool {
  _MfaFactorsPool({
    required this.returningFactorId,
    this.recoveryCodeRows = const <PostgresRow>[],
    this.affectedRowCount = 1,
  });

  final String? returningFactorId;
  final List<PostgresRow> recoveryCodeRows;
  final int affectedRowCount;

  final List<_MfaFactorsTransaction> transactions = <_MfaFactorsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _MfaFactorsTransaction(
      returningFactorId: returningFactorId,
      recoveryCodeRows: recoveryCodeRows,
      affectedRowCount: affectedRowCount,
    );
    transactions.add(tx);
    return tx;
  }
}

class _MfaFactorsTransaction extends PostgresTransaction {
  _MfaFactorsTransaction({
    required this.returningFactorId,
    required this.recoveryCodeRows,
    required this.affectedRowCount,
  });

  final String? returningFactorId;
  final List<PostgresRow> recoveryCodeRows;
  final int affectedRowCount;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;
  int commitCount = 0;
  int rollbackCount = 0;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('insert into mfa_factors') &&
        sql.contains('returning factor_id')) {
      final id = returningFactorId;
      if (id == null) return <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'factor_id': id},
      ];
    }
    if (sql.contains('select factor_id') &&
        sql.contains('from mfa_factors')) {
      return recoveryCodeRows;
    }
    return <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('update mfa_factors')) {
      return affectedRowCount;
    }
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
