// Phase 9 live-closeout B12 / post-hardening P2 — canonical-path
// unit tests for MfaFactorsRepository.
//
// Coverage focus:
//
//   * factor_type allowlist — the production schema CHECK (from
//     `db/migrations/202604250008_auth_schema_foundation.sql`) admits
//     `'passkey'`, `'totp'`, `'recovery_code'`. Launch enrollment only
//     writes `'totp'`; legacy recovery-code rows still flow through
//     the consumer / revoke paths. The repo therefore only ever binds
//     two values on the wire: `'totp'` (TOTP enroll / repair / revoke /
//     list) and `'recovery_code'` (insert / mark-used / list / revoke).
//     Tests pin every write SQL surface to one of those two literals
//     so a typo or stray case-mismatch fails loudly here instead of
//     silently bypassing the CHECK constraint.
//
//     Note: an earlier draft of this slice's prompt mentioned an
//     `sms_pending_removal` factor_type. That value does not exist in
//     production — neither in the schema CHECK nor in any code path —
//     so the test pins what the code actually emits. If a future
//     migration adds an SMS-shaped factor_type, the corresponding
//     repository write path will land alongside it and the test
//     surface here is the right place to mirror the new literal.
//
//   * operator + user double-scope — `mfa_factors` is per-user
//     (RLS policy `mfa_factors_per_user`). The repo runs through
//     `withTenant`, which emits SET LOCAL for BOTH `app.operator_id`
//     (so audit triggers + cross-fact-table joins see the tenant) AND
//     `app.user_id` (the actual RLS predicate). Tests verify the
//     canonical SET LOCAL ordering precedes every INSERT / UPDATE /
//     SELECT, so a refactor that drops one of the two SET LOCAL calls
//     would surface here.
//
//   * `insertTotpEnrollment` / `insertTotpFactor` — both write `'totp'`
//     with a metadata JSON carrying `firebase_factor_uid` and `issuer`
//     (round-tripped via `jsonEncode`). RETURNING projects
//     `factor_id::text`; empty rows throw StateError; malformed (empty
//     string) factor_id throws StateError. Both are pinned.
//
//   * `ensureTotpFactorForFirebaseUid` — repair path. Probes for an
//     existing active TOTP row matching the `firebase_factor_uid`; if
//     present, returns its factor_id without writing. If absent,
//     inserts a fresh row with `'firebase_inventory_repair'` source
//     marker. Tests pin both branches.
//
//   * `markRecoveryCodeUsed` — single-use seal: sets BOTH `last_used_at
//     = now()` AND `revoked_at = now()` so a second verify on the
//     same code row cannot match. The `factor_type = 'recovery_code'`
//     guard keeps a stray TOTP factor_id from accidentally being
//     marked used; the `revoked_at is null` guard makes the seal
//     idempotent (re-running on a used code returns 0).
//
//   * `revokeTotpFactor` — 24-hour-delayed removal flow. UPDATE sets
//     `revoked_at = now()`; WHERE filters `factor_type = 'totp'` so a
//     stray recovery_code factor_id is rejected; idempotent on
//     `revoked_at is null`.
//
//   * `revokeActiveRecoveryCodeFactorsForUser` — bulk revoke for the
//     legacy compat sweep. `coalesce(revoked_at, now())` makes it
//     idempotent on already-revoked rows; user_id scoping keeps it
//     from revoking another user's codes.
//
//   * `listActiveTotpFactors` / `listActiveRecoveryCodeFactors` —
//     metadata projection. Driver returns `factor_metadata::text` (the
//     repo casts in the SELECT); the projection decodes the JSON. A
//     malformed JSON metadata string falls back to an empty map (a
//     hardened guard so a malformed legacy row doesn't crash the
//     consumer).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';
const String _factorTotpA = '44444444-4444-4444-4444-444444444444';
const String _factorTotpB = '55555555-5555-5555-5555-555555555555';
const String _factorRecoveryA = '66666666-6666-6666-6666-666666666666';
const String _firebaseUid = 'firebase-mfa-uid-001';

void main() {
  group(
      'MfaFactorsRepository.insertTotpEnrollment — '
      "factor_type='totp' write", () {
    test(
      "binds factor_type='totp' as a SQL literal (NOT a parameter); "
      "metadata JSON carries firebase_factor_uid + issuer; "
      "factor_id::text returned",
      () async {
        final pool = _MfaFactorsPool(insertedFactorId: _factorTotpA);
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
        final result = await repo.insertTotpEnrollment(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          firebaseFactorUid: _firebaseUid,
        );
        expect(result.totpFactorId, equals(_factorTotpA));

        final tx = pool.transactions.single;
        final insertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into mfa_factors'),
        );
        // factor_type is a SQL literal so the CHECK constraint admits
        // exactly the two production-allowed values; binding it would
        // open a substitution path that could land an unsupported
        // value before the CHECK ran.
        expect(
          insertSql,
          contains("'totp'"),
          reason: 'factor_type bound as literal so the schema CHECK '
              'admits exactly the supported values',
        );
        expect(insertSql, contains('returning factor_id::text as factor_id'));

        final params = tx.parameters.firstWhere(
          (p) => p['user_id'] == _userA && p['metadata'] is String,
        );
        // metadata round-trips through jsonEncode — verify decode.
        final metadata = jsonDecode(params['metadata']! as String)
            as Map<String, Object?>;
        expect(metadata['firebase_factor_uid'], equals(_firebaseUid));
        expect(metadata['issuer'], equals('Forge & Flow'));
      },
    );

    test(
      'operator + user double-scope: SET LOCAL emits BOTH '
      'app.operator_id AND app.user_id BEFORE the INSERT — '
      'mfa_factors RLS policy folds against app.user_id, but the '
      'audit triggers also need app.operator_id for tenant attribution',
      () async {
        final pool = _MfaFactorsPool(insertedFactorId: _factorTotpA);
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
        await repo.insertTotpEnrollment(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          firebaseFactorUid: _firebaseUid,
        );
        final tx = pool.transactions.single;
        // Canonical SET LOCAL order: operator → location → user.
        expect(tx.executedSql[0], contains("'app.operator_id'"));
        expect(tx.parameters[0]['value'], equals(_opA));
        expect(tx.executedSql[1], contains("'app.location_id'"));
        expect(tx.parameters[1]['value'], equals(_locA));
        expect(tx.executedSql[2], contains("'app.user_id'"));
        expect(
          tx.parameters[2]['value'],
          equals(_userA),
          reason: 'app.user_id MUST equal the userId being written; the '
              'RLS policy (mfa_factors_per_user) admits only when the '
              'GUC matches the row',
        );
        // No BYPASSRLS escape — mfa_factors has no admin path.
        expect(
          tx.executedSql.where((s) => s.contains('set local role forge_admin')),
          isEmpty,
        );
        // INSERT runs AFTER the SET LOCAL block.
        final insertIdx = tx.executedSql.indexWhere(
          (s) => s.contains('insert into mfa_factors'),
        );
        expect(insertIdx, greaterThan(2));
      },
    );

    test(
      'StateError when INSERT RETURNING is empty — RLS denied the '
      'row even though SET LOCAL ran (e.g. user_id mismatch); never '
      'a silent null',
      () async {
        final pool = _MfaFactorsPool(insertedFactorId: null);
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
        await expectLater(
          repo.insertTotpEnrollment(
            operatorId: _opA,
            locationId: _locA,
            userId: _userA,
            firebaseFactorUid: _firebaseUid,
          ),
          throwsStateError,
        );
      },
    );

    test(
      'StateError when INSERT RETURNING factor_id is malformed (empty '
      'string) — defensive guard against a misbehaving driver',
      () async {
        final pool = _MfaFactorsPool(insertedFactorId: '');
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
        await expectLater(
          repo.insertTotpEnrollment(
            operatorId: _opA,
            locationId: _locA,
            userId: _userA,
            firebaseFactorUid: _firebaseUid,
          ),
          throwsStateError,
        );
      },
    );
  });

  group('MfaFactorsRepository.insertRecoveryCodeFactor — '
      "factor_type='recovery_code' write", () {
    test(
      "binds factor_type='recovery_code' as a SQL literal; metadata "
      "is the caller-supplied hash payload (jsonEncoded)",
      () async {
        final pool = _MfaFactorsPool(insertedFactorId: _factorRecoveryA);
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
        final id = await repo.insertRecoveryCodeFactor(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          hashedCodeJson: const <String, Object?>{
            'salt': 'salt-bytes-base64',
            'hash': 'hash-bytes-base64',
            'algo': 'sha256',
          },
        );
        expect(id, equals(_factorRecoveryA));

        final tx = pool.transactions.single;
        final insertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into mfa_factors'),
        );
        expect(
          insertSql,
          contains("'recovery_code'"),
          reason: 'recovery_code bound as literal — hardens against '
              'CHECK-bypass via parameter substitution',
        );
        // No 'totp' or 'passkey' literal slipped in.
        expect(insertSql, isNot(contains("'totp'")));
        expect(insertSql, isNot(contains("'passkey'")));

        final params = tx.parameters.firstWhere(
          (p) => p['user_id'] == _userA && p['metadata'] is String,
        );
        final metadata = jsonDecode(params['metadata']! as String)
            as Map<String, Object?>;
        expect(metadata['salt'], equals('salt-bytes-base64'));
        expect(metadata['hash'], equals('hash-bytes-base64'));
        expect(metadata['algo'], equals('sha256'));
      },
    );
  });

  group('MfaFactorsRepository.ensureTotpFactorForFirebaseUid — repair path',
      () {
    test(
      'returns the existing factor_id when an active TOTP row already '
      'maps to the firebase_factor_uid (idempotent: NO insert runs)',
      () async {
        final pool = _MfaFactorsPool(
          existingTotpRowsByFirebaseUid: <PostgresRow>[
            <String, Object?>{'factor_id': _factorTotpA},
          ],
        );
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
        final id = await repo.ensureTotpFactorForFirebaseUid(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          firebaseFactorUid: _firebaseUid,
        );
        expect(id, equals(_factorTotpA));

        final tx = pool.transactions.single;
        // Probe SELECT ran — it filters by user_id, factor_type=totp,
        // metadata->>firebase_factor_uid match, revoked_at IS NULL.
        final probeSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('from mfa_factors') &&
              s.contains("factor_type = 'totp'"),
        );
        expect(probeSql, contains("factor_metadata->>'firebase_factor_uid'"));
        expect(probeSql, contains('revoked_at is null'));
        expect(probeSql, contains('order by enrolled_at desc'));
        expect(probeSql, contains('limit 1'));

        // No INSERT — the existing row was reused.
        expect(
          tx.executedSql.where((s) => s.contains('insert into mfa_factors')),
          isEmpty,
          reason: 'repair path is idempotent: reuse the existing row '
              'instead of minting a duplicate',
        );
      },
    );

    test(
      'inserts a fresh totp row when no existing factor maps to the '
      "firebase_factor_uid; metadata carries 'firebase_inventory_repair' "
      "source marker AND firebase_enrolled_at when supplied",
      () async {
        final firebaseEnrolledAt = DateTime.utc(2026, 4, 25, 9);
        final pool = _MfaFactorsPool(
          existingTotpRowsByFirebaseUid: const <PostgresRow>[],
          insertedFactorId: _factorTotpB,
        );
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
        final id = await repo.ensureTotpFactorForFirebaseUid(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          firebaseFactorUid: _firebaseUid,
          firebaseEnrolledAt: firebaseEnrolledAt,
        );
        expect(id, equals(_factorTotpB));

        final tx = pool.transactions.single;
        final insertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into mfa_factors'),
        );
        expect(insertSql, contains("'totp'"));

        final insertParams = tx.parameters.lastWhere(
          (p) => p['metadata'] is String,
        );
        final metadata = jsonDecode(insertParams['metadata']! as String)
            as Map<String, Object?>;
        expect(metadata['source'], equals('firebase_inventory_repair'));
        expect(
          metadata['firebase_enrolled_at'],
          equals(firebaseEnrolledAt.toIso8601String()),
        );
        expect(metadata['firebase_factor_uid'], equals(_firebaseUid));
      },
    );

    test(
      'firebase_enrolled_at omitted: metadata still carries source + '
      "firebase_factor_uid + issuer, but no firebase_enrolled_at key",
      () async {
        final pool = _MfaFactorsPool(
          existingTotpRowsByFirebaseUid: const <PostgresRow>[],
          insertedFactorId: _factorTotpB,
        );
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
        await repo.ensureTotpFactorForFirebaseUid(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          firebaseFactorUid: _firebaseUid,
          // firebaseEnrolledAt deliberately omitted
        );
        final insertParams = pool.transactions.single.parameters.lastWhere(
          (p) => p['metadata'] is String,
        );
        final metadata = jsonDecode(insertParams['metadata']! as String)
            as Map<String, Object?>;
        expect(metadata.containsKey('firebase_enrolled_at'), isFalse);
        expect(metadata['source'], equals('firebase_inventory_repair'));
      },
    );
  });

  group('MfaFactorsRepository.markRecoveryCodeUsed — single-use seal', () {
    test(
      'UPDATE sets BOTH last_used_at = now() AND revoked_at = now() '
      "with the factor_type = 'recovery_code' guard so a stray TOTP "
      'factor_id cannot be marked used through this path',
      () async {
        final pool = _MfaFactorsPool(updateAffectedRows: 1);
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
        final affected = await repo.markRecoveryCodeUsed(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          factorId: _factorRecoveryA,
        );
        expect(affected, equals(1));

        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('update mfa_factors') &&
              s.contains('last_used_at = now()'),
        );
        // Single-use seal: BOTH last_used_at and revoked_at advance so
        // a second verify on the same code row never matches.
        expect(updateSql, contains('revoked_at = now()'));
        // factor_type literal guard.
        expect(updateSql, contains("factor_type = 'recovery_code'"));
        // Idempotency guard so re-running on a used code returns 0.
        expect(updateSql, contains('and revoked_at is null'));
        // user_id double-scope on the WHERE clause defends against a
        // factor_id stolen from another user's row.
        expect(updateSql, contains('user_id = @user_id::uuid'));
      },
    );

    test(
      'returns 0 when the row was already used / revoked '
      "(idempotency guard short-circuits)",
      () async {
        final pool = _MfaFactorsPool(updateAffectedRows: 0);
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
        final affected = await repo.markRecoveryCodeUsed(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          factorId: _factorRecoveryA,
        );
        expect(affected, equals(0));
      },
    );
  });

  group('MfaFactorsRepository.revokeTotpFactor — 24h-delayed removal seal',
      () {
    test(
      "factor_type='totp' guard rejects a stray recovery_code "
      'factor_id; revoked_at = now() advances; idempotent on '
      'revoked_at is null',
      () async {
        final pool = _MfaFactorsPool(updateAffectedRows: 1);
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
        final affected = await repo.revokeTotpFactor(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          factorId: _factorTotpA,
        );
        expect(affected, equals(1));

        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('update mfa_factors') &&
              s.contains('revoked_at = now()'),
        );
        expect(updateSql, contains("factor_type = 'totp'"));
        expect(updateSql, contains('and revoked_at is null'));
        // last_used_at NOT advanced — TOTP revoke is the user's
        // explicit "remove this authenticator" path, not a successful
        // verify.
        expect(
          updateSql,
          isNot(contains('last_used_at = now()')),
          reason: 'TOTP revoke is removal, not a verify — last_used_at '
              'must not advance or the audit row would mis-attribute '
              'the use to the revoke',
        );
        expect(updateSql, contains('user_id = @user_id::uuid'));
      },
    );
  });

  group('MfaFactorsRepository.revokeActiveRecoveryCodeFactorsForUser — '
      'legacy compat sweep', () {
    test(
      'idempotent: coalesce(revoked_at, now()) preserves the existing '
      'revoked_at on already-revoked rows; user_id scoping keeps the '
      "sweep from touching another user's codes",
      () async {
        final pool = _MfaFactorsPool(updateAffectedRows: 3);
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
        final affected = await repo.revokeActiveRecoveryCodeFactorsForUser(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
        );
        expect(affected, equals(3));

        final tx = pool.transactions.single;
        final updateSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('update mfa_factors') &&
              s.contains('coalesce(revoked_at, now())'),
        );
        // Idempotent — coalesce keeps the original revoked_at if set.
        expect(updateSql, contains('coalesce(revoked_at, now())'));
        // factor_type literal guard.
        expect(updateSql, contains("factor_type = 'recovery_code'"));
        // user_id scoping.
        expect(updateSql, contains('user_id = @user_id::uuid'));
        // Only sweeps still-active rows.
        expect(updateSql, contains('and revoked_at is null'));
      },
    );
  });

  group('MfaFactorsRepository.listActiveTotpFactors', () {
    test(
      'projects rows with metadata JSON decoded; only active '
      "(revoked_at IS NULL), factor_type='totp' rows; ordered by "
      'enrolled_at desc',
      () async {
        final pool = _MfaFactorsPool(
          totpListRows: <PostgresRow>[
            <String, Object?>{
              'factor_id': _factorTotpA,
              'user_id': _userA,
              'factor_type': 'totp',
              'factor_metadata': jsonEncode(
                <String, Object?>{
                  'firebase_factor_uid': _firebaseUid,
                  'issuer': 'Forge & Flow',
                },
              ),
              'enrolled_at': DateTime.utc(2026, 4, 28),
              'last_used_at': null,
              'revoked_at': null,
            },
          ],
        );
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listActiveTotpFactors(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
        );
        expect(rows, hasLength(1));
        final row = rows.single;
        expect(row.factorId, equals(_factorTotpA));
        expect(row.factorType, equals('totp'));
        expect(row.isActive, isTrue);
        expect(row.factorMetadata['firebase_factor_uid'], equals(_firebaseUid));

        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('from mfa_factors') &&
              s.contains("factor_type = 'totp'"),
        );
        expect(selectSql, contains('and revoked_at is null'));
        expect(selectSql, contains('order by enrolled_at desc'));
        // Casts metadata to text so the projection's JSON decode runs
        // identically on every driver / encoding (bypasses the driver
        // returning a typed jsonb that sometimes lands as Map and
        // sometimes as String).
        expect(selectSql, contains('factor_metadata::text as factor_metadata'));
      },
    );

    test(
      'malformed JSON metadata falls back to an empty map (so a '
      "legacy row with corrupted JSON doesn't crash the consumer)",
      () async {
        final pool = _MfaFactorsPool(
          totpListRows: <PostgresRow>[
            <String, Object?>{
              'factor_id': _factorTotpA,
              'user_id': _userA,
              'factor_type': 'totp',
              'factor_metadata': '{not valid json',
              'enrolled_at': DateTime.utc(2026, 4, 28),
              'last_used_at': null,
              'revoked_at': null,
            },
          ],
        );
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listActiveTotpFactors(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
        );
        expect(rows, hasLength(1));
        expect(rows.single.factorMetadata, isEmpty);
      },
    );

    test(
      'metadata returned as a Map by some drivers (jsonb pre-decode) '
      'projects through unchanged',
      () async {
        final pool = _MfaFactorsPool(
          totpListRows: <PostgresRow>[
            <String, Object?>{
              'factor_id': _factorTotpA,
              'user_id': _userA,
              'factor_type': 'totp',
              'factor_metadata': <String, Object?>{
                'firebase_factor_uid': _firebaseUid,
              },
              'enrolled_at': DateTime.utc(2026, 4, 28),
              'last_used_at': null,
              'revoked_at': null,
            },
          ],
        );
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listActiveTotpFactors(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
        );
        expect(rows.single.factorMetadata['firebase_factor_uid'],
            equals(_firebaseUid));
      },
    );
  });

  group('MfaFactorsRepository.listActiveRecoveryCodeFactors', () {
    test(
      "factor_type='recovery_code' literal guard; only active rows; "
      'ordered by enrolled_at (ascending — oldest first, so the '
      "consumer's constant-time hash loop has stable ordering)",
      () async {
        final pool = _MfaFactorsPool(
          recoveryListRows: <PostgresRow>[
            <String, Object?>{
              'factor_id': _factorRecoveryA,
              'user_id': _userA,
              'factor_type': 'recovery_code',
              'factor_metadata': jsonEncode(
                <String, Object?>{'salt': 's', 'hash': 'h', 'algo': 'sha256'},
              ),
              'enrolled_at': DateTime.utc(2026, 4, 28),
              'last_used_at': null,
              'revoked_at': null,
            },
          ],
        );
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listActiveRecoveryCodeFactors(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
        );
        expect(rows, hasLength(1));
        expect(rows.single.factorType, equals('recovery_code'));

        final tx = pool.transactions.single;
        final selectSql = tx.executedSql.firstWhere(
          (s) =>
              s.contains('from mfa_factors') &&
              s.contains("factor_type = 'recovery_code'"),
        );
        expect(selectSql, contains('and revoked_at is null'));
        expect(selectSql, contains('order by enrolled_at'));
        expect(selectSql, isNot(contains('order by enrolled_at desc')),
            reason:
                "recovery code consumer iterates oldest-first; reverse "
                'order would be a behavior change');
      },
    );

    test('returns empty when no active recovery_code factor rows', () async {
      final pool = _MfaFactorsPool(
        recoveryListRows: const <PostgresRow>[],
      );
      final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));
      final rows = await repo.listActiveRecoveryCodeFactors(
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
      );
      expect(rows, isEmpty);
    });
  });

  group('MfaFactorsRepository.markRecoveryCodesViewed', () {
    test(
      'updates recovery_codes_viewed_at to the supplied latest view time',
      () async {
        final viewedAt = DateTime.utc(2026, 5, 6, 12);
        final pool = _MfaFactorsPool(
          recoveryCodesViewedUpdateRows: <PostgresRow>[
            <String, Object?>{'recovery_codes_viewed_at': viewedAt},
          ],
        );
        final repo = MfaFactorsRepository(TenantTransactionWrapper(pool));

        final result = await repo.markRecoveryCodesViewed(
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          factorId: _factorTotpA,
          viewedAt: viewedAt,
        );

        expect(result, isNotNull);
        expect(result!.viewedAt, equals(viewedAt));
        expect(result.changed, isTrue);
        final updateSql = pool.transactions.single.executedSql.firstWhere(
          (s) => s.contains('update mfa_factors'),
        );
        expect(updateSql, contains('set recovery_codes_viewed_at'));
        expect(updateSql, contains("factor_type = 'totp'"));
        expect(updateSql, contains('revoked_at is null'));
        expect(updateSql, isNot(contains('recovery_codes_viewed_at is null')));
      },
    );
  });
}

/// Recording fake `PostgresPool` shaped for the MfaFactorsRepository
/// seam.
///
/// `insertedFactorId` controls every INSERT … RETURNING factor_id
/// (pass null for empty rows / RLS denial; pass empty string for the
/// malformed-id guard).
///
/// `existingTotpRowsByFirebaseUid` controls the
/// `ensureTotpFactorForFirebaseUid` probe SELECT.
///
/// `totpListRows` / `recoveryListRows` control the
/// `listActiveTotpFactors` / `listActiveRecoveryCodeFactors` SELECT.
///
/// `updateAffectedRows` controls every UPDATE affected count.
class _MfaFactorsPool implements PostgresPool {
  _MfaFactorsPool({
    this.insertedFactorId,
    this.existingTotpRowsByFirebaseUid = const <PostgresRow>[],
    this.totpListRows = const <PostgresRow>[],
    this.recoveryListRows = const <PostgresRow>[],
    this.recoveryCodesViewedUpdateRows = const <PostgresRow>[],
    this.updateAffectedRows = 0,
  });

  final String? insertedFactorId;
  final List<PostgresRow> existingTotpRowsByFirebaseUid;
  final List<PostgresRow> totpListRows;
  final List<PostgresRow> recoveryListRows;
  final List<PostgresRow> recoveryCodesViewedUpdateRows;
  final int updateAffectedRows;
  final List<_MfaFactorsTransaction> transactions = <_MfaFactorsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _MfaFactorsTransaction(
      insertedFactorId: insertedFactorId,
      existingTotpRowsByFirebaseUid: existingTotpRowsByFirebaseUid,
      totpListRows: totpListRows,
      recoveryListRows: recoveryListRows,
      recoveryCodesViewedUpdateRows: recoveryCodesViewedUpdateRows,
      updateAffectedRows: updateAffectedRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _MfaFactorsTransaction extends PostgresTransaction {
  _MfaFactorsTransaction({
    required this.insertedFactorId,
    required this.existingTotpRowsByFirebaseUid,
    required this.totpListRows,
    required this.recoveryListRows,
    required this.recoveryCodesViewedUpdateRows,
    required this.updateAffectedRows,
  });

  final String? insertedFactorId;
  final List<PostgresRow> existingTotpRowsByFirebaseUid;
  final List<PostgresRow> totpListRows;
  final List<PostgresRow> recoveryListRows;
  final List<PostgresRow> recoveryCodesViewedUpdateRows;
  final int updateAffectedRows;

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
    if (sql.contains('insert into mfa_factors')) {
      final id = insertedFactorId;
      if (id == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'factor_id': id},
      ];
    }
    if (sql.contains('update mfa_factors') &&
        sql.contains('recovery_codes_viewed_at')) {
      return recoveryCodesViewedUpdateRows;
    }
    if (sql.contains('from mfa_factors')) {
      // ensureTotpFactorForFirebaseUid probe — filters
      // metadata->>firebase_factor_uid.
      if (sql.contains("factor_metadata->>'firebase_factor_uid'")) {
        return existingTotpRowsByFirebaseUid;
      }
      if (sql.contains("factor_type = 'totp'")) {
        return totpListRows;
      }
      if (sql.contains("factor_type = 'recovery_code'")) {
        return recoveryListRows;
      }
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
    if (sql.contains('update mfa_factors')) {
      return updateAffectedRows;
    }
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
    rollbackCount += 1;
  }
}
