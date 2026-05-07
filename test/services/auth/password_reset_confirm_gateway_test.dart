// Phase 9.UX.7 - RepositoryPasswordResetConfirmGateway tests.

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
import 'package:forge_and_flow/services/auth/repository_password_history_check.dart';

void main() {
  group('RepositoryPasswordResetConfirmGateway', () {
    test('maps invalid reset action codes to expired-link copy', () async {
      final gateway = _gateway(
        firebase: _ResetCodeErrorFirebaseAdminAuthClient(
          verifyError: const FirebaseAdminAuthError(
            'invalid_oob_code',
            statusCode: 400,
          ),
        ),
      );

      final error = await _captureError(
        gateway.confirmPasswordReset(
          const PasswordResetConfirmCommand(
            oobCode: 'bad-code',
            newPassword: 'fresh-password',
          ),
        ),
      );

      expect(error, isA<PasswordChangeRejected>());
      final rejected = error! as PasswordChangeRejected;
      expect(rejected.code, equals('password_reset_expired'));
      expect(rejected.statusCode, equals(400));
      expect(rejected.message, contains('Request a new reset link'));
    });

    test('maps expired reset action codes to expired-link copy', () async {
      final gateway = _gateway(
        firebase: _ResetCodeErrorFirebaseAdminAuthClient(
          verifyError: const FirebaseAdminAuthError(
            'expired_oob_code',
            statusCode: 400,
          ),
        ),
      );

      final error = await _captureError(
        gateway.confirmPasswordReset(
          const PasswordResetConfirmCommand(
            oobCode: 'expired-code',
            newPassword: 'fresh-password',
          ),
        ),
      );

      expect(error, isA<PasswordChangeRejected>());
      final rejected = error! as PasswordChangeRejected;
      expect(rejected.code, equals('password_reset_expired'));
      expect(rejected.statusCode, equals(400));
    });

    test('returns success once Firebase accepts the reset even if '
        'post-confirm bookkeeping fails', () async {
      final firebase = _SuccessfulResetFirebaseAdminAuthClient();
      final pool = _PasswordResetPostgresPool(
        throwOnRecordHash: true,
        throwOnMarkPasswordChanged: true,
        throwOnAudit: true,
      );
      final gateway = _gateway(
        firebase: firebase,
        pool: pool,
        fetcher: const _EmptyHibpRangeFetcher(),
      );

      final result = await gateway.confirmPasswordReset(
        const PasswordResetConfirmCommand(
          oobCode: 'live-code',
          newPassword: 'fresh-password',
        ),
      );

      expect(result.hibpUnavailable, isFalse);
      expect(firebase.confirmCalls, equals(1));
      expect(pool.recordHashAttempts, equals(1));
      expect(pool.markPasswordChangedAttempts, equals(1));
      expect(pool.auditAttempts, equals(1));
    });

    test('HIBP-unavailable audit failure does not block the reset', () async {
      final firebase = _SuccessfulResetFirebaseAdminAuthClient();
      final pool = _PasswordResetPostgresPool(throwOnAudit: true);
      final gateway = _gateway(
        firebase: firebase,
        pool: pool,
        fetcher: const _UnavailableHibpRangeFetcher(),
      );

      final result = await gateway.confirmPasswordReset(
        const PasswordResetConfirmCommand(
          oobCode: 'live-code',
          newPassword: 'fresh-password',
        ),
      );

      expect(result.hibpUnavailable, isTrue);
      expect(firebase.confirmCalls, equals(1));
      expect(pool.auditAttempts, greaterThanOrEqualTo(1));
    });
  });
}

// CODE_HEALTH L12 follow-up: RepositoryPasswordResetConfirmGateway
// instantiates RepositoryPasswordHistoryCheck internally, which would
// otherwise read PASSWORD_HISTORY_PEPPER from the env at construction
// time and throw PasswordHistoryPepperMissingError in non-demo mode.
// Inject a deterministic literal pepper so the salted-hash path is
// constructible inside the test process. The value is not secret — it
// only needs to be stable for the test run. Matches the pattern used in
// test/password_live_binding_test.dart.
const String _testPepper = 'test-pepper-bytes-not-secret';

RepositoryPasswordResetConfirmGateway _gateway({
  required FirebaseAdminAuthClient firebase,
  PostgresPool? pool,
  HibpRangeFetcher? fetcher,
}) {
  final wrapper = TenantTransactionWrapper(pool ?? _NeverPostgresPool());
  return RepositoryPasswordResetConfirmGateway(
    firebaseAdmin: firebase,
    usersRepository: UsersRepository(wrapper),
    passwordHistoryRepository: PasswordHistoryRepository(wrapper),
    auditRepository: AuthEventsAuditRepository(wrapper),
    hibpScreener: HibpPwnedPasswordScreener(
      fetcher: fetcher ?? const _NeverHibpRangeFetcher(),
    ),
    passwordHistoryHasher: const Sha256PasswordHistoryHasher(),
    pepper: PasswordHistoryPepperConfig.literal(_testPepper),
  );
}

Future<Object?> _captureError(Future<Object?> future) async {
  try {
    await future;
    return null;
  } catch (error) {
    return error;
  }
}

class _ResetCodeErrorFirebaseAdminAuthClient
    implements FirebaseAdminAuthClient {
  const _ResetCodeErrorFirebaseAdminAuthClient({required this.verifyError});

  final FirebaseAdminAuthError verifyError;

  @override
  Future<FirebasePasswordResetCodeInfo> verifyPasswordResetCode({
    required String oobCode,
  }) async => throw verifyError;

  @override
  Future<void> confirmPasswordReset({
    required String oobCode,
    required String newPassword,
  }) async => throw UnimplementedError();

  @override
  Future<void> createUser({
    required String uid,
    required String email,
    required Map<String, Object?> customClaims,
  }) async => throw UnimplementedError();

  @override
  Future<void> setCustomClaims({
    required String uid,
    required Map<String, Object?> customClaims,
  }) async => throw UnimplementedError();

  @override
  Future<void> setDisabled({
    required String uid,
    required bool disabled,
  }) async => throw UnimplementedError();

  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    String? continueUrl,
  }) async => throw UnimplementedError();

  @override
  Future<bool> verifyPassword({
    required String email,
    required String password,
    required String expectedUid,
  }) async => throw UnimplementedError();

  @override
  Future<void> updatePassword({
    required String uid,
    required String password,
  }) async => throw UnimplementedError();

  @override
  Future<void> revokeRefreshTokens({required String uid}) async =>
      throw UnimplementedError();

  @override
  Future<void> clearMfaEnrollments({required String uid}) async =>
      throw UnimplementedError();
}

class _SuccessfulResetFirebaseAdminAuthClient
    implements FirebaseAdminAuthClient {
  int confirmCalls = 0;

  @override
  Future<FirebasePasswordResetCodeInfo> verifyPasswordResetCode({
    required String oobCode,
  }) async => const FirebasePasswordResetCodeInfo(
    email: 'owner@example.test',
    uid: _userId,
  );

  @override
  Future<void> confirmPasswordReset({
    required String oobCode,
    required String newPassword,
  }) async {
    confirmCalls += 1;
  }

  @override
  Future<void> createUser({
    required String uid,
    required String email,
    required Map<String, Object?> customClaims,
  }) async => throw UnimplementedError();

  @override
  Future<void> setCustomClaims({
    required String uid,
    required Map<String, Object?> customClaims,
  }) async => throw UnimplementedError();

  @override
  Future<void> setDisabled({
    required String uid,
    required bool disabled,
  }) async => throw UnimplementedError();

  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    String? continueUrl,
  }) async => throw UnimplementedError();

  @override
  Future<bool> verifyPassword({
    required String email,
    required String password,
    required String expectedUid,
  }) async => throw UnimplementedError();

  @override
  Future<void> updatePassword({
    required String uid,
    required String password,
  }) async => throw UnimplementedError();

  @override
  Future<void> revokeRefreshTokens({required String uid}) async =>
      throw UnimplementedError();

  @override
  Future<void> clearMfaEnrollments({required String uid}) async =>
      throw UnimplementedError();
}

const String _userId = '11111111-1111-4111-8111-111111111111';
const String _operatorId = '22222222-2222-4222-8222-222222222222';
const String _locationId = '33333333-3333-4333-8333-333333333333';

class _PasswordResetPostgresPool implements PostgresPool {
  _PasswordResetPostgresPool({
    this.throwOnRecordHash = false,
    this.throwOnMarkPasswordChanged = false,
    this.throwOnAudit = false,
  });

  final bool throwOnRecordHash;
  final bool throwOnMarkPasswordChanged;
  final bool throwOnAudit;
  int recordHashAttempts = 0;
  int markPasswordChangedAttempts = 0;
  int auditAttempts = 0;

  @override
  Future<PostgresTransaction> beginTransaction() async =>
      _PasswordResetPostgresTransaction(this);
}

class _PasswordResetPostgresTransaction implements PostgresTransaction {
  _PasswordResetPostgresTransaction(this.pool);

  final _PasswordResetPostgresPool pool;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('from users u')) {
      return const <PostgresRow>[
        <String, Object?>{
          'user_id': _userId,
          'operator_id': _operatorId,
          'location_id': _locationId,
          'email': 'owner@example.test',
          'firebase_uid': _userId,
        },
      ];
    }
    if (sql.contains('from password_history')) {
      return const <PostgresRow>[];
    }
    if (sql.contains('insert into password_history')) {
      pool.recordHashAttempts += 1;
      if (pool.throwOnRecordHash) {
        throw StateError('password history insert failed');
      }
      return const <PostgresRow>[
        <String, Object?>{'entry_id': 'history-1'},
      ];
    }
    if (sql.contains('insert into auth_events_audit')) {
      pool.auditAttempts += 1;
      if (pool.throwOnAudit) {
        throw StateError('audit insert failed');
      }
      return const <PostgresRow>[
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
    if (sql.startsWith('update users')) {
      pool.markPasswordChangedAttempts += 1;
      if (pool.throwOnMarkPasswordChanged) {
        throw StateError('password timestamp update failed');
      }
      return 1;
    }
    return 0;
  }

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}

class _NeverPostgresPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() async =>
      throw StateError('Postgres should not be touched in this test.');
}

class _NeverHibpRangeFetcher implements HibpRangeFetcher {
  const _NeverHibpRangeFetcher();

  @override
  Future<String> fetchRange(String hexPrefix) async =>
      throw StateError('HIBP should not be touched in this test.');
}

class _EmptyHibpRangeFetcher implements HibpRangeFetcher {
  const _EmptyHibpRangeFetcher();

  @override
  Future<String> fetchRange(String hexPrefix) async => '';
}

class _UnavailableHibpRangeFetcher implements HibpRangeFetcher {
  const _UnavailableHibpRangeFetcher();

  @override
  Future<String> fetchRange(String hexPrefix) async =>
      throw StateError('HIBP unavailable');
}
