// B5 — Password-reset end-to-end integration test.
//
// Tests the full reset flow with fake collaborators (no live Firebase,
// no live Postgres):
//   1. requestPasswordReset(email) — sends the Firebase OOB email.
//   2. Token captured from the fake mailer (fake Firebase client).
//   3. Submit token + new password to the confirm gateway.
//   4. Old password no longer works (Firebase verifyPassword returns false).
//   5. New password signs in (Firebase verifyPassword returns true).
//   6. Password-history check rejects reusing a recent password.
//
// Existing coverage covers individual gateways:
//   - password_reset_request_gateway_test.dart
//   - password_reset_confirm_gateway_test.dart
//   - repository_password_history_check_test.dart
// This file stitches them into one scenario to verify sequencing.

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/password_history_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';
import 'package:forge_and_flow/services/auth/hibp_pwned_password_screener.dart';
import 'package:forge_and_flow/services/auth/password_change_gateway.dart';
import 'package:forge_and_flow/services/auth/password_reset_confirm_gateway.dart';
import 'package:forge_and_flow/services/auth/password_reset_request_gateway.dart';
import 'package:forge_and_flow/services/auth/repository_password_history_check.dart';

const String _kTestPepper = 'b5-e2e-test-pepper-not-secret';
const String _kUserId = '11111111-1111-4111-8111-111111111111';
const String _kOperatorId = '22222222-2222-4222-8222-222222222222';
const String _kLocationId = '33333333-3333-4333-8333-333333333333';
const String _kUserEmail = 'operator@reset-test.invalid';
const String _kOldPassword = 'OldSecure@Pass1';
const String _kNewPassword = 'NewSecure@Pass2';

/// Compute the legacy SHA-256 hash matching what [Sha256PasswordHistoryHasher]
/// produces for [password] under the given [operatorId] and [userId].
/// Format: SHA-256(operatorId + '|' + userId + '|' + password).
String _legacyHash(
  String password, {
  String operatorId = _kOperatorId,
  String userId = _kUserId,
}) {
  final bytes = utf8.encode('$operatorId|$userId|$password');
  return crypto.sha256.convert(bytes).toString();
}

void main() {
  group('Password reset end-to-end flow', () {
    test(
      'full reset flow: request → capture token → confirm → old password '
      'rejected → new password accepted',
      () async {
        final firebase = _E2EFakeFirebaseAdminAuthClient(
          email: _kUserEmail,
          uid: _kUserId,
          initialPassword: _kOldPassword,
        );
        final pool = _E2EFakePostgresPool(
          email: _kUserEmail,
          userId: _kUserId,
          operatorId: _kOperatorId,
          locationId: _kLocationId,
        );
        final wrapper = TenantTransactionWrapper(pool);

        // Step 1: request reset.
        final requestGateway =
            RepositoryPasswordResetRequestGateway.fromDependencies(
          firebaseAdmin: firebase,
          lookup: (_) async => UserAuthLookupRow(
            userId: _kUserId,
            operatorId: _kOperatorId,
            locationId: _kLocationId,
            email: _kUserEmail,
          ),
          auditWriter: (_) async {},
          sleep: (_) async {},
          stopwatchFactory: () => Stopwatch(),
        );
        await requestGateway.requestReset(
          const PasswordResetRequestCommand(email: _kUserEmail),
        );
        expect(
          firebase.sentEmails,
          contains(_kUserEmail),
          reason: 'Step 1: Firebase must send the reset email',
        );

        // Step 2: capture the OOB token.
        final oobCode = firebase.lastOobCode;
        expect(oobCode, isNotEmpty,
            reason: 'Step 2: OOB code must be issued');

        // Step 3: confirm reset.
        final confirmGateway = RepositoryPasswordResetConfirmGateway(
          firebaseAdmin: firebase,
          usersRepository: UsersRepository(wrapper),
          passwordHistoryRepository: PasswordHistoryRepository(wrapper),
          auditRepository: AuthEventsAuditRepository(wrapper),
          hibpScreener: HibpPwnedPasswordScreener(
            fetcher: const _EmptyHibpRangeFetcher(),
          ),
          passwordHistoryHasher: const Sha256PasswordHistoryHasher(),
          pepper: PasswordHistoryPepperConfig.literal(_kTestPepper),
        );
        final result = await confirmGateway.confirmPasswordReset(
          PasswordResetConfirmCommand(
            oobCode: oobCode,
            newPassword: _kNewPassword,
          ),
        );
        expect(result.hibpUnavailable, isFalse,
            reason: 'Step 3: HIBP check passes with empty range fetcher');
        expect(firebase.confirmCalls, equals(1),
            reason: 'Step 3: Firebase.confirmPasswordReset called once');

        // Step 4: old password no longer works.
        final oldWorks = await firebase.verifyPassword(
          email: _kUserEmail,
          password: _kOldPassword,
          expectedUid: _kUserId,
        );
        expect(oldWorks, isFalse,
            reason: 'Step 4: old password must not authenticate after reset');

        // Step 5: new password works.
        final newWorks = await firebase.verifyPassword(
          email: _kUserEmail,
          password: _kNewPassword,
          expectedUid: _kUserId,
        );
        expect(newWorks, isTrue,
            reason: 'Step 5: new password must authenticate after reset');
      },
    );

    test(
      'password-history check rejects reusing a recently-used password',
      () async {
        // Seed pool with the new password already in history.
        final pool = _E2EFakePostgresPool(
          email: _kUserEmail,
          userId: _kUserId,
          operatorId: _kOperatorId,
          locationId: _kLocationId,
          seededPasswordHashes: <String>[
            _legacyHash(_kNewPassword),
          ],
        );
        final wrapper = TenantTransactionWrapper(pool);
        final firebase = _E2EFakeFirebaseAdminAuthClient(
          email: _kUserEmail,
          uid: _kUserId,
          initialPassword: _kOldPassword,
        );

        final confirmGateway = RepositoryPasswordResetConfirmGateway(
          firebaseAdmin: firebase,
          usersRepository: UsersRepository(wrapper),
          passwordHistoryRepository: PasswordHistoryRepository(wrapper),
          auditRepository: AuthEventsAuditRepository(wrapper),
          hibpScreener: HibpPwnedPasswordScreener(
            fetcher: const _EmptyHibpRangeFetcher(),
          ),
          passwordHistoryHasher: const Sha256PasswordHistoryHasher(),
          pepper: PasswordHistoryPepperConfig.literal(_kTestPepper),
        );

        Object? thrown;
        try {
          await confirmGateway.confirmPasswordReset(
            PasswordResetConfirmCommand(
              oobCode: 'test-oob-code',
              newPassword: _kNewPassword,
            ),
          );
        } on PasswordChangeRejected catch (e) {
          thrown = e;
        } catch (e) {
          thrown = e;
        }

        expect(
          thrown,
          isA<PasswordChangeRejected>(),
          reason: 'History check must reject reusing a recent password',
        );
      },
    );

    test(
      'invalid OOB code surfaces as PasswordChangeRejected '
      'with code=password_reset_expired',
      () async {
        final firebase = _E2EFakeFirebaseAdminAuthClient(
          email: _kUserEmail,
          uid: _kUserId,
          initialPassword: _kOldPassword,
          invalidOobCode: true,
        );
        final wrapper = TenantTransactionWrapper(_NeverPool());
        final confirmGateway = RepositoryPasswordResetConfirmGateway(
          firebaseAdmin: firebase,
          usersRepository: UsersRepository(wrapper),
          passwordHistoryRepository: PasswordHistoryRepository(wrapper),
          auditRepository: AuthEventsAuditRepository(wrapper),
          hibpScreener: HibpPwnedPasswordScreener(
            fetcher: const _EmptyHibpRangeFetcher(),
          ),
          passwordHistoryHasher: const Sha256PasswordHistoryHasher(),
          pepper: PasswordHistoryPepperConfig.literal(_kTestPepper),
        );

        Object? thrown;
        try {
          await confirmGateway.confirmPasswordReset(
            const PasswordResetConfirmCommand(
              oobCode: 'bad-code',
              newPassword: _kNewPassword,
            ),
          );
        } on PasswordChangeRejected catch (e) {
          thrown = e;
        }

        expect(thrown, isA<PasswordChangeRejected>());
        final rejected = thrown! as PasswordChangeRejected;
        expect(
          rejected.code,
          equals('password_reset_expired'),
          reason: 'Invalid OOB code must map to password_reset_expired',
        );
      },
    );
  });
}

// ─── Fake Firebase client ─────────────────────────────────────────────

class _E2EFakeFirebaseAdminAuthClient implements FirebaseAdminAuthClient {
  _E2EFakeFirebaseAdminAuthClient({
    required this.email,
    required this.uid,
    required this.initialPassword,
    this.invalidOobCode = false,
  }) : _currentPassword = initialPassword;

  final String email;
  final String uid;
  final String initialPassword;
  final bool invalidOobCode;

  String _currentPassword;
  final List<String> sentEmails = <String>[];
  String lastOobCode = '';
  int confirmCalls = 0;

  @override
  Future<FirebasePasswordResetCodeInfo> verifyPasswordResetCode({
    required String oobCode,
  }) async {
    if (invalidOobCode) {
      throw const FirebaseAdminAuthError(
        'invalid_oob_code',
        statusCode: 400,
      );
    }
    return FirebasePasswordResetCodeInfo(email: email, uid: uid);
  }

  @override
  Future<void> confirmPasswordReset({
    required String oobCode,
    required String newPassword,
  }) async {
    confirmCalls += 1;
    _currentPassword = newPassword;
  }

  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    String? continueUrl,
  }) async {
    sentEmails.add(email);
    lastOobCode = 'fake-oob-${sentEmails.length}-${email.hashCode}';
  }

  @override
  Future<bool> verifyPassword({
    required String email,
    required String password,
    required String expectedUid,
  }) async =>
      email == this.email &&
      password == _currentPassword &&
      expectedUid == uid;

  @override
  Future<void> createUser({
    required String uid,
    required Map<String, Object?> customClaims,
    required String email,
  }) async {}

  @override
  Future<void> setCustomClaims({
    required String uid,
    required Map<String, Object?> customClaims,
  }) async {}

  @override
  Future<void> setDisabled({
    required String uid,
    required bool disabled,
  }) async {}

  @override
  Future<void> updateUser({
    required String uid,
    String? email,
    String? displayName,
  }) async {}

  @override
  Future<void> updatePassword({
    required String uid,
    required String password,
  }) async {}

  @override
  Future<void> revokeRefreshTokens({required String uid}) async {}

  @override
  Future<void> clearMfaEnrollments({required String uid}) async {}
}

// ─── Fake Postgres pool ───────────────────────────────────────────────

class _E2EFakePostgresPool implements PostgresPool {
  _E2EFakePostgresPool({
    required this.email,
    required this.userId,
    required this.operatorId,
    required this.locationId,
    List<String> seededPasswordHashes = const <String>[],
  }) : _seededHashes = List<String>.from(seededPasswordHashes);

  final String email;
  final String userId;
  final String operatorId;
  final String locationId;
  final List<String> _seededHashes;

  @override
  Future<PostgresTransaction> beginTransaction() async =>
      _E2EFakePostgresTransaction(
        email: email,
        userId: userId,
        operatorId: operatorId,
        locationId: locationId,
        seededHashes: _seededHashes,
      );
}

class _E2EFakePostgresTransaction implements PostgresTransaction {
  _E2EFakePostgresTransaction({
    required this.email,
    required this.userId,
    required this.operatorId,
    required this.locationId,
    required this.seededHashes,
  });

  final String email;
  final String userId;
  final String operatorId;
  final String locationId;
  final List<String> seededHashes;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    // Users lookup.
    if (sql.contains('from users u') ||
        (sql.contains('users') && sql.contains('email'))) {
      return <PostgresRow>[
        <String, Object?>{
          'user_id': userId,
          'operator_id': operatorId,
          'location_id': locationId,
          'email': email,
          'firebase_uid': userId,
        },
      ];
    }
    // Password history lookup — return seeded hashes.
    // Must carry the columns that _HistoryEntry.fromRow() expects:
    //   password_hash, password_hash_salt, password_hash_pepper_id,
    //   password_hash_algo, entry_id, set_at.
    if (sql.contains('from password_history')) {
      if (seededHashes.isEmpty) return const <PostgresRow>[];
      return seededHashes
          .asMap()
          .entries
          .map(
            (e) => <String, Object?>{
              'entry_id': 'hist-${e.key}',
              'password_hash': e.value,
              'password_hash_salt': null, // legacy algo — no salt
              'password_hash_pepper_id': null,
              'password_hash_algo': 'sha256-legacy',
              'set_at': DateTime.utc(2026, 5, 1),
            },
          )
          .toList();
    }
    // History insert.
    if (sql.contains('insert into password_history') ||
        sql.contains('insert into public.password_history')) {
      return <PostgresRow>[
        <String, Object?>{'entry_id': 'new-hist-1'},
      ];
    }
    // Audit insert.
    if (sql.contains('insert into auth_events_audit') ||
        sql.contains('audit')) {
      return <PostgresRow>[
        <String, Object?>{'event_id': 'event-1'},
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('update users') ||
        sql.contains('update public.users')) {
      return 1;
    }
    return 0;
  }

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}

class _NeverPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() async =>
      throw StateError('Postgres must not be touched in this test path.');
}

class _EmptyHibpRangeFetcher implements HibpRangeFetcher {
  const _EmptyHibpRangeFetcher();

  @override
  Future<String> fetchRange(String hexPrefix) async => '';
}
