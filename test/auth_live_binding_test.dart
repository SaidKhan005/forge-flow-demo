// Phase 9 live-closeout B4/B5/B6 tests.
//
// Covers:
//   * FirebaseAuthClient adapter contract + ScaffoldFailing default.
//   * FirebaseAuthLoginService translation from FirebaseAuthSignIn*
//     outcomes to AuthLoginResult subclasses + AuthSession projection
//     from JWT custom claims.
//   * PlatformSecureSessionStorage + InMemory / ScaffoldFailing
//     backend.
//   * AuthSessionLedgerWriter in-memory recorder + ScaffoldFailing
//     default.
//   * AuthSessionsRepository SQL contract via fake PostgresPool —
//     parameter binding, RETURNING projection, withTenant SET LOCAL,
//     withSystem audit reason for the admin path.
//   * RepositoryAuthSessionLedgerWriter delegation.
//   * AuthSessionNotifier B6 wiring: ledger calls happen on signIn,
//     refreshSession, signOutThisSession, signOutAllSessions, and
//     ledger errors do not block sign-in.

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/operator_scoped_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_sessions_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/firebase_auth_client.dart';
import 'package:forge_and_flow/services/auth/firebase_auth_login_service.dart';
import 'package:forge_and_flow/services/auth/platform_secure_session_storage.dart';
import 'package:forge_and_flow/services/auth/repository_auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth_login_service.dart';
import 'package:forge_and_flow/services/secure_session_storage.dart';
import 'package:forge_and_flow/state/auth_session_notifier.dart';

const String _validOpId = '11111111-1111-1111-1111-111111111111';
const String _validLocId = '22222222-2222-2222-2222-222222222222';
const String _validUserId = '33333333-3333-3333-3333-333333333333';
const String _validSessionId = '44444444-4444-4444-4444-444444444444';

void main() {
  group('ScaffoldFailingFirebaseAuthClient (B4)', () {
    test('every entry point throws so production fails closed', () async {
      const client = ScaffoldFailingFirebaseAuthClient();
      await expectLater(
        client.signInWithEmailPassword(email: 'a@b.c', password: 'x'),
        throwsStateError,
      );
      await expectLater(
        client.completeTotpChallenge(
          mfaSessionToken: 't',
          factorId: 'f',
          oneTimeCode: '000000',
        ),
        throwsStateError,
      );
      await expectLater(
        client.requestPasswordReset(email: 'a@b.c'),
        throwsStateError,
      );
      await expectLater(client.refreshIdToken(), throwsStateError);
      await expectLater(client.signOut(), throwsStateError);
      await expectLater(client.revokeAllRefreshTokens(), throwsStateError);
    });
  });

  group('FirebaseAuthLoginService (B4)', () {
    FirebaseAuthCredential buildCredential({
      Map<String, Object?>? claims,
      String userId = 'fb-user-1',
    }) {
      final now = DateTime.utc(2026, 4, 26, 12);
      return FirebaseAuthCredential(
        userId: userId,
        idToken: 'header.payload.sig',
        idTokenIssuedAt: now.subtract(const Duration(minutes: 1)),
        idTokenExpiresAt: now.add(const Duration(hours: 1)),
        lastFreshAuthAt: now.subtract(const Duration(minutes: 1)),
        customClaims:
            claims ??
            <String, Object?>{
              'operator_id': _validOpId,
              'roles_version': 7,
              'mfa_enrolled': true,
            },
      );
    }

    test(
      'signInWithEmailPassword Succeeded -> AuthLoginSuccess with projected '
      'AuthSession including operator_id, location_id, roles, mfa flag',
      () async {
        final client = _FakeFirebaseAuthClient(
          nextSignInOutcome: FirebaseAuthSignInSucceeded(
            buildCredential(
              userId: _validUserId,
              claims: <String, Object?>{
                'operator_id': _validOpId,
                'is_super_admin': true,
                'roles_version': 9,
                'mfa_enrolled': true,
              },
            ),
          ),
        );
        final service = FirebaseAuthLoginService(
          client: client,
          locationResolver: const FixedAuthLocationResolver(_validLocId),
        );

        final result = await service.signInWithEmailPassword(
          email: 'admin@example.test',
          password: 'pw',
        );

        expect(result, isA<AuthLoginSuccess>());
        final session = (result as AuthLoginSuccess).session;
        expect(session.userId, equals(_validUserId));
        expect(session.operatorId, equals(_validOpId));
        expect(session.locationId, equals(_validLocId));
        expect(session.roles, contains('super_admin'));
        expect(session.roles, contains('roles_version:9'));
        expect(session.mfaEnrolled, isTrue);
      },
    );

    test(
      'location_id custom claim is used before the fallback resolver',
      () async {
        const claimedLocationId = '55555555-5555-5555-5555-555555555555';
        final client = _FakeFirebaseAuthClient(
          nextSignInOutcome: FirebaseAuthSignInSucceeded(
            buildCredential(
              userId: _validUserId,
              claims: const <String, Object?>{
                'operator_id': _validOpId,
                'location_id': claimedLocationId,
                'roles_version': 9,
              },
            ),
          ),
        );
        final service = FirebaseAuthLoginService(
          client: client,
          locationResolver: const FixedAuthLocationResolver(_validLocId),
        );

        final result = await service.signInWithEmailPassword(
          email: 'admin@example.test',
          password: 'pw',
        );

        expect(result, isA<AuthLoginSuccess>());
        expect(
          (result as AuthLoginSuccess).session.locationId,
          equals(claimedLocationId),
        );
      },
    );

    test(
      'user_id custom claim maps Firebase uid to Postgres user uuid',
      () async {
        final client = _FakeFirebaseAuthClient(
          nextSignInOutcome: FirebaseAuthSignInSucceeded(
            buildCredential(
              userId: 'firebase-uid-not-a-postgres-uuid',
              claims: const <String, Object?>{
                'user_id': _validUserId,
                'operator_id': _validOpId,
                'location_id': _validLocId,
              },
            ),
          ),
        );
        final service = FirebaseAuthLoginService(
          client: client,
          locationResolver: const FixedAuthLocationResolver(_validLocId),
        );

        final result = await service.signInWithEmailPassword(
          email: 'admin@example.test',
          password: 'pw',
        );

        expect(result, isA<AuthLoginSuccess>());
        expect(
          (result as AuthLoginSuccess).session.userId,
          equals(_validUserId),
        );
      },
    );

    test(
      'postgres_user_id custom claim maps Firebase uid to Postgres uuid',
      () async {
        final client = _FakeFirebaseAuthClient(
          nextSignInOutcome: FirebaseAuthSignInSucceeded(
            buildCredential(
              userId: 'firebase-uid-not-a-postgres-uuid',
              claims: const <String, Object?>{
                'postgres_user_id': _validUserId,
                'operator_id': _validOpId,
                'location_id': _validLocId,
              },
            ),
          ),
        );
        final service = FirebaseAuthLoginService(
          client: client,
          locationResolver: const FixedAuthLocationResolver(_validLocId),
        );

        final result = await service.signInWithEmailPassword(
          email: 'admin@example.test',
          password: 'pw',
        );

        expect(result, isA<AuthLoginSuccess>());
        expect(
          (result as AuthLoginSuccess).session.userId,
          equals(_validUserId),
        );
      },
    );

    test(
      'signInWithEmailPassword RequiresMfa -> AuthLoginMfaRequired',
      () async {
        final client = _FakeFirebaseAuthClient(
          nextSignInOutcome: const FirebaseAuthSignInRequiresMfa(
            mfaSessionToken: 'mfa-tok',
            factorIds: <String>['totp-1'],
          ),
        );
        final service = FirebaseAuthLoginService(
          client: client,
          locationResolver: const FixedAuthLocationResolver(_validLocId),
        );

        final result = await service.signInWithEmailPassword(
          email: 'mfa@example.test',
          password: 'pw',
        );

        expect(result, isA<AuthLoginMfaRequired>());
        expect(
          (result as AuthLoginMfaRequired).mfaSessionToken,
          equals('mfa-tok'),
        );
        expect(result.factorIds, equals(<String>['totp-1']));
      },
    );

    test('signInWithEmailPassword Failed -> AuthLoginFailure preserves code + '
        'message', () async {
      final client = _FakeFirebaseAuthClient(
        nextSignInOutcome: const FirebaseAuthSignInFailed(
          code: 'invalid_credentials',
          message: 'Email or password is incorrect.',
        ),
      );
      final service = FirebaseAuthLoginService(
        client: client,
        locationResolver: const FixedAuthLocationResolver(_validLocId),
      );

      final result = await service.signInWithEmailPassword(
        email: 'bad@example.test',
        password: 'pw',
      );

      expect(result, isA<AuthLoginFailure>());
      expect((result as AuthLoginFailure).code, equals('invalid_credentials'));
      expect(result.message, equals('Email or password is incorrect.'));
    });

    test(
      'missing operator_id custom claim -> invalid_claims AuthLoginFailure',
      () async {
        final client = _FakeFirebaseAuthClient(
          nextSignInOutcome: FirebaseAuthSignInSucceeded(
            buildCredential(
              claims: const <String, Object?>{'roles_version': 7},
            ),
          ),
        );
        final service = FirebaseAuthLoginService(
          client: client,
          locationResolver: const FixedAuthLocationResolver(_validLocId),
        );

        final result = await service.signInWithEmailPassword(
          email: 'a@b.c',
          password: 'x',
        );

        expect(result, isA<AuthLoginFailure>());
        expect((result as AuthLoginFailure).code, equals('invalid_claims'));
        // Acceptance: the failure message references the missing claim
        // by name so the operator can debug, without echoing claim values.
        expect(result.message, contains('operator_id'));
      },
    );

    test('completeTotpChallenge Succeeded -> AuthLoginSuccess', () async {
      final client = _FakeFirebaseAuthClient(
        nextSignInOutcome: FirebaseAuthSignInSucceeded(
          buildCredential(userId: _validUserId),
        ),
      );
      final service = FirebaseAuthLoginService(
        client: client,
        locationResolver: const FixedAuthLocationResolver(_validLocId),
      );

      final result = await service.completeTotpChallenge(
        mfaSessionToken: 'mfa-tok',
        factorId: 'totp-1',
        oneTimeCode: '000000',
      );

      expect(result, isA<AuthLoginSuccess>());
      expect(client.completeTotpCalls, equals(1));
      expect((result as AuthLoginSuccess).session.userId, equals(_validUserId));
    });

    test('refreshSession preserves the live session location_id', () async {
      final client = _FakeFirebaseAuthClient(
        nextRefreshCredential: buildCredential(userId: _validUserId),
      );
      // The resolver here returns a DIFFERENT location to prove that
      // refreshSession does NOT consult it (preserves the live one).
      final service = FirebaseAuthLoginService(
        client: client,
        locationResolver: const FixedAuthLocationResolver(
          '99999999-9999-9999-9999-999999999999',
        ),
      );
      final live = AuthSession(
        userId: _validUserId,
        operatorId: _validOpId,
        locationId: _validLocId,
        firebaseIdToken: 'old-token',
        issuedAt: DateTime.utc(2026, 4, 26),
        expiresAt: DateTime.utc(2026, 4, 26, 1),
        lastFreshAuthAt: DateTime.utc(2026, 4, 26),
        roles: const <String>['operator_owner'],
        mfaEnrolled: true,
      );

      final refreshed = await service.refreshSession(live);
      expect(refreshed, isNotNull);
      expect(refreshed!.locationId, equals(_validLocId));
    });

    test(
      'refreshSession returns null when client has no refreshable session',
      () async {
        final client = _FakeFirebaseAuthClient(nextRefreshCredential: null);
        final service = FirebaseAuthLoginService(
          client: client,
          locationResolver: const FixedAuthLocationResolver(_validLocId),
        );
        final live = AuthSession(
          userId: _validUserId,
          operatorId: _validOpId,
          locationId: _validLocId,
          firebaseIdToken: 't',
          issuedAt: DateTime.utc(2026, 4, 26),
          expiresAt: DateTime.utc(2026, 4, 26, 1),
          lastFreshAuthAt: DateTime.utc(2026, 4, 26),
          roles: const <String>[],
          mfaEnrolled: false,
        );
        expect(await service.refreshSession(live), isNull);
      },
    );
  });

  group('PlatformSecureSessionStorage (B5)', () {
    test('round-trips through the in-memory backend under the namespaced '
        'key', () async {
      final backend = InMemoryPlatformSecureStorageBackend();
      final storage = PlatformSecureSessionStorage(backend: backend);
      expect(await storage.readSessionJson(), isNull);
      await storage.writeSessionJson('{"k":1}');
      expect(await storage.readSessionJson(), equals('{"k":1}'));
      // Acceptance: the backend stored under the locked v1 key —
      // a future shape migration can migrate via key rename.
      expect(
        await backend.read(PlatformSecureSessionStorage.defaultSessionKey),
        equals('{"k":1}'),
      );
      await storage.clear();
      expect(await storage.readSessionJson(), isNull);
    });

    test('AuthSession round-trip via writeSession + readSession through the '
        'backend', () async {
      final backend = InMemoryPlatformSecureStorageBackend();
      final storage = PlatformSecureSessionStorage(backend: backend);
      final session = AuthSession(
        userId: _validUserId,
        operatorId: _validOpId,
        locationId: _validLocId,
        firebaseIdToken: 't',
        issuedAt: DateTime.utc(2026, 4, 26),
        expiresAt: DateTime.utc(2026, 4, 26, 1),
        lastFreshAuthAt: DateTime.utc(2026, 4, 26),
        roles: const <String>['operator_owner'],
        mfaEnrolled: true,
      );
      await storage.writeSession(session);
      final loaded = await storage.readSession();
      expect(loaded?.operatorId, equals(_validOpId));
    });

    test(
      'ScaffoldFailingPlatformSecureStorageBackend throws on every method',
      () async {
        const backend = ScaffoldFailingPlatformSecureStorageBackend();
        await expectLater(backend.read('k'), throwsStateError);
        await expectLater(backend.write('k', 'v'), throwsStateError);
        await expectLater(backend.delete('k'), throwsStateError);
      },
    );
  });

  group('InMemoryAuthSessionLedgerWriter + ScaffoldFailing (B6)', () {
    test('recordLogin returns a session_id and stores the row', () async {
      final writer = InMemoryAuthSessionLedgerWriter(
        sessionIdFactory: () => _validSessionId,
      );
      final id = await writer.recordLogin(
        AuthSessionLedgerLogin(
          userId: _validUserId,
          operatorId: _validOpId,
          locationId: _validLocId,
          tokenHash: 'hash-abc',
          context: const AuthSessionLedgerContext(
            ip: '1.2.3.4',
            userAgent: 'test-ua',
            geoCountry: 'CA',
          ),
        ),
      );
      expect(id, equals(_validSessionId));
      expect(writer.logins, hasLength(1));
      expect(writer.logins.single.tokenHash, equals('hash-abc'));
      expect(writer.issuedSessionIds.single, equals(_validSessionId));
    });

    test('revokeAllSessionsForUser revokes every recorded session for the '
        'matching user_id and skips other users', () async {
      final ids = <String>['s-1', 's-2', 's-3'];
      var idx = 0;
      final writer = InMemoryAuthSessionLedgerWriter(
        sessionIdFactory: () => ids[idx++],
      );
      await writer.recordLogin(_loginFor(userId: _validUserId));
      await writer.recordLogin(_loginFor(userId: _validUserId));
      await writer.recordLogin(
        _loginFor(userId: '99999999-9999-9999-9999-999999999999'),
      );

      final revoked = await writer.revokeAllSessionsForUser(
        userId: _validUserId,
        operatorId: _validOpId,
        locationId: _validLocId,
        reason: 'test',
      );

      expect(revoked, equals(2));
      expect(writer.revokedSessions['s-1'], equals('test'));
      expect(writer.revokedSessions['s-2'], equals('test'));
      // s-3 is owned by a different user — must NOT be revoked.
      expect(writer.revokedSessions.containsKey('s-3'), isFalse);
    });

    test(
      'ScaffoldFailingAuthSessionLedgerWriter throws on every method',
      () async {
        const writer = ScaffoldFailingAuthSessionLedgerWriter();
        await expectLater(
          writer.recordLogin(_loginFor(userId: _validUserId)),
          throwsStateError,
        );
        await expectLater(
          writer.recordRefresh(
            sessionId: 's',
            userId: _validUserId,
            operatorId: _validOpId,
            locationId: _validLocId,
          ),
          throwsStateError,
        );
        await expectLater(
          writer.revokeSession(
            sessionId: 's',
            userId: _validUserId,
            operatorId: _validOpId,
            locationId: _validLocId,
            reason: 'r',
          ),
          throwsStateError,
        );
        await expectLater(
          writer.revokeAllSessionsForUser(
            userId: _validUserId,
            operatorId: _validOpId,
            locationId: _validLocId,
            reason: 'r',
          ),
          throwsStateError,
        );
      },
    );
  });

  group('AuthSessionsRepository (B6 — fake Postgres)', () {
    test('insertLogin runs SET LOCAL + INSERT with bound parameters and '
        'returns the RETURNING session_id', () async {
      final pool = _AuthSessionsPool(returningSessionId: _validSessionId);
      final repo = AuthSessionsRepository(TenantTransactionWrapper(pool));

      final id = await repo.insertLogin(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
        tokenHash: 'hash-abc',
        ip: '1.2.3.4',
        userAgent: 'ua',
        deviceFingerprint: 'fp-1',
        geoCountry: 'CA',
      );
      expect(id, equals(_validSessionId));

      final tx = pool.transactions.single;
      // Three SET LOCAL calls (op/loc/user) + one bypass marker + INSERT.
      expect(tx.executedSql.length, greaterThanOrEqualTo(5));
      // Parameters bound, not concatenated.
      final insertParams = tx.parameters.last;
      expect(insertParams['user_id'], equals(_validUserId));
      expect(insertParams['token_hash'], equals('hash-abc'));
      expect(insertParams['ip'], equals('1.2.3.4'));
      expect(insertParams['user_agent'], equals('ua'));
      expect(insertParams['device_fingerprint'], equals('fp-1'));
      expect(insertParams['geo_country'], equals('CA'));
      // Acceptance: INSERT body uses parameter binding.
      final insertSql = tx.executedSql.last;
      expect(insertSql, contains('insert into auth_sessions'));
      expect(insertSql, contains('returning session_id'));
      expect(insertSql, contains('@user_id'));
      // Audit-fix 2026-04-27: column + parameter renamed from
      // refresh_token_hash → token_hash so the ledger contract
      // matches the actual content (ID-token hash today; future
      // refresh-token hash slots in the same column).
      expect(insertSql, contains('@token_hash'));
      expect(insertSql, isNot(contains('refresh_token_hash')));
    });

    test(
      'insertLogin throws when RETURNING produces no rows (RLS denial)',
      () async {
        final pool = _AuthSessionsPool(returningSessionId: null);
        final repo = AuthSessionsRepository(TenantTransactionWrapper(pool));
        await expectLater(
          repo.insertLogin(
            operatorId: _validOpId,
            locationId: _validLocId,
            userId: _validUserId,
            tokenHash: 'h',
          ),
          throwsStateError,
        );
      },
    );

    test('markRefreshed updates last_seen_at = now() with sessionId + userId '
        'parameters and skips already-revoked rows', () async {
      final pool = _AuthSessionsPool(returningSessionId: _validSessionId);
      final repo = AuthSessionsRepository(TenantTransactionWrapper(pool));

      await repo.markRefreshed(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
        sessionId: _validSessionId,
      );

      final tx = pool.transactions.single;
      final updateSql = tx.executedSql.last;
      expect(updateSql, contains('update auth_sessions'));
      expect(updateSql, contains('last_seen_at = now()'));
      expect(updateSql, contains('revoked_at is null'));
      expect(tx.parameters.last['session_id'], equals(_validSessionId));
      expect(tx.parameters.last['user_id'], equals(_validUserId));
    });

    test('revokeSession sets revoked_at + revoked_reason on a single row '
        'idempotently', () async {
      final pool = _AuthSessionsPool(returningSessionId: _validSessionId);
      final repo = AuthSessionsRepository(TenantTransactionWrapper(pool));

      await repo.revokeSession(
        operatorId: _validOpId,
        locationId: _validLocId,
        userId: _validUserId,
        sessionId: _validSessionId,
        reason: 'user_signed_out_this_session',
      );

      final tx = pool.transactions.single;
      final updateSql = tx.executedSql.last;
      expect(updateSql, contains('revoked_at = now()'));
      expect(updateSql, contains('revoked_reason = @reason'));
      expect(updateSql, contains('revoked_at is null'));
      expect(
        tx.parameters.last['reason'],
        equals('user_signed_out_this_session'),
      );
    });

    test(
      'revokeAllSessionsForUserAsAdmin uses withSystem with audited reason',
      () async {
        final pool = _AuthSessionsPool(returningSessionId: _validSessionId);
        final repo = AuthSessionsRepository(TenantTransactionWrapper(pool));

        await repo.revokeAllSessionsForUserAsAdmin(
          userId: _validUserId,
          reason: 'admin_force_logout',
          adminReason: 'admin.users.force_logout_all_sessions',
        );

        final tx = pool.transactions.single;
        // Acceptance: bypass_rls_audit reason is set with `system:<reason>`.
        expect(
          tx.parameters[0]['value'],
          equals('system:admin.users.force_logout_all_sessions'),
        );
        expect(tx.executedSql[1], equals('set local role forge_admin'));
        // Acceptance: the actual UPDATE filtered by user_id only — the
        // admin path does not need the row's tenant context.
        final updateSql = tx.executedSql.last;
        expect(updateSql, contains('update auth_sessions'));
        expect(updateSql, contains('where user_id = @user_id'));
      },
    );
  });

  group('RepositoryAuthSessionLedgerWriter delegates to AuthSessionsRepository '
      '(B6)', () {
    test('recordLogin forwards every field + returns session_id', () async {
      final pool = _AuthSessionsPool(returningSessionId: _validSessionId);
      final repo = AuthSessionsRepository(TenantTransactionWrapper(pool));
      final writer = RepositoryAuthSessionLedgerWriter(repository: repo);

      final id = await writer.recordLogin(
        AuthSessionLedgerLogin(
          userId: _validUserId,
          operatorId: _validOpId,
          locationId: _validLocId,
          tokenHash: 'h',
          context: const AuthSessionLedgerContext(
            ip: '5.6.7.8',
            userAgent: 'fake',
            geoCountry: 'US',
          ),
        ),
      );
      expect(id, equals(_validSessionId));
      final tx = pool.transactions.single;
      final params = tx.parameters.last;
      expect(params['ip'], equals('5.6.7.8'));
      expect(params['user_agent'], equals('fake'));
      expect(params['geo_country'], equals('US'));
    });

    test(
      'revokeAllSessionsForUser forwards reason to the SQL update',
      () async {
        final pool = _AuthSessionsPool(returningSessionId: _validSessionId);
        final repo = AuthSessionsRepository(TenantTransactionWrapper(pool));
        final writer = RepositoryAuthSessionLedgerWriter(repository: repo);

        await writer.revokeAllSessionsForUser(
          userId: _validUserId,
          operatorId: _validOpId,
          locationId: _validLocId,
          reason: 'user_signed_out_all_sessions',
        );

        final tx = pool.transactions.single;
        expect(
          tx.parameters.last['reason'],
          equals('user_signed_out_all_sessions'),
        );
      },
    );
  });

  group('AuthSessionNotifier B6 ledger wiring', () {
    AuthSession buildSession({
      String userId = _validUserId,
      String operatorId = _validOpId,
      String locationId = _validLocId,
      String token = 'header.payload.sig',
    }) {
      return AuthSession(
        userId: userId,
        operatorId: operatorId,
        locationId: locationId,
        firebaseIdToken: token,
        issuedAt: DateTime.utc(2026, 4, 26, 11, 59),
        expiresAt: DateTime.utc(2026, 4, 26, 13),
        lastFreshAuthAt: DateTime.utc(2026, 4, 26, 11, 59),
        roles: const <String>['operator_owner'],
        mfaEnrolled: true,
      );
    }

    test('signIn success calls ledgerWriter.recordLogin with operator/location'
        '/user from the session and stores the issued session_id', () async {
      final ledger = InMemoryAuthSessionLedgerWriter(
        sessionIdFactory: () => _validSessionId,
      );
      final session = buildSession();
      final notifier = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(
          signInResult: AuthLoginSuccess(session),
        ),
        storage: InMemorySecureSessionStorage(),
        ledgerWriter: ledger,
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      await notifier.rehydrate();

      await notifier.signInWithEmailPassword(email: 'a@b.c', password: 'pw');

      expect(ledger.logins, hasLength(1));
      expect(ledger.logins.single.userId, equals(_validUserId));
      expect(ledger.logins.single.operatorId, equals(_validOpId));
      expect(ledger.logins.single.locationId, equals(_validLocId));
      // Acceptance: the token_hash is the SHA-256 hex digest of the
      // AuthSession's firebaseIdToken — the raw token never leaves the
      // value class. Honest naming after the audit-fix rename: this
      // is the ID-token hash; refresh-token-reuse detection is a
      // future seam (see AuthSessionLedgerLogin doc).
      final expected = crypto.sha256
          .convert(utf8.encode(session.firebaseIdToken))
          .toString();
      expect(ledger.logins.single.tokenHash, equals(expected));
      expect(notifier.activeSessionId, equals(_validSessionId));
    });

    test('signIn FAILS CLOSED when the ledger writer rejects — no '
        'AuthSessionAuthenticated state, no stored session, calm '
        '`ledger_unavailable` failure surfaces to the UI '
        '(audit-fix 2026-04-27)', () async {
      final session = buildSession();
      final storage = InMemorySecureSessionStorage();
      final notifier = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(
          signInResult: AuthLoginSuccess(session),
        ),
        storage: storage,
        ledgerWriter: const ScaffoldFailingAuthSessionLedgerWriter(),
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      await notifier.rehydrate();

      final result = await notifier.signInWithEmailPassword(
        email: 'a@b.c',
        password: 'pw',
      );

      // Returned result is an AuthLoginFailure with the specific
      // calm code — UI renders a "try again in a moment" banner.
      expect(result, isA<AuthLoginFailure>());
      expect((result as AuthLoginFailure).code, equals('ledger_unavailable'));
      expect(result.message.toLowerCase(), contains('try again'));
      // State stays Unauthenticated — no half-authenticated phase.
      expect(notifier.state, isA<AuthSessionUnauthenticated>());
      final unauth = notifier.state as AuthSessionUnauthenticated;
      expect(unauth.lastErrorCode, equals('ledger_unavailable'));
      expect(notifier.activeSessionId, isNull);
      // Stored session was best-effort cleared so a relaunch doesn't
      // resurrect a session that was never written to the ledger.
      expect(await storage.readSession(), isNull);
    });

    test('signIn SUCCEEDS normally when the ledger writer accepts — UX '
        'stays low-friction in the success path '
        '(audit-fix 2026-04-27 regression guard)', () async {
      final ledger = InMemoryAuthSessionLedgerWriter(
        sessionIdFactory: () => _validSessionId,
      );
      final notifier = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(
          signInResult: AuthLoginSuccess(buildSession()),
        ),
        storage: InMemorySecureSessionStorage(),
        ledgerWriter: ledger,
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      await notifier.rehydrate();

      final result = await notifier.signInWithEmailPassword(
        email: 'a@b.c',
        password: 'pw',
      );

      expect(result, isA<AuthLoginSuccess>());
      expect(notifier.state, isA<AuthSessionAuthenticated>());
      expect(notifier.activeSessionId, equals(_validSessionId));
      expect(ledger.logins, hasLength(1));
    });

    test('refreshSession survives a ledger failure — log-and-continue '
        'preserves persistent login (audit-fix 2026-04-27 decision)', () async {
      final session = buildSession();
      final refreshed = session.copyWith(
        firebaseIdToken: 'refreshed.token.sig',
        issuedAt: DateTime.utc(2026, 4, 26, 12),
        expiresAt: DateTime.utc(2026, 4, 26, 14),
        lastFreshAuthAt: DateTime.utc(2026, 4, 26, 12),
      );
      final ledger = _SignInOkRefreshFailLedger();
      final notifier = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(
          signInResult: AuthLoginSuccess(session),
          refreshResult: refreshed,
        ),
        storage: InMemorySecureSessionStorage(),
        ledgerWriter: ledger,
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      await notifier.rehydrate();
      await notifier.signInWithEmailPassword(email: 'a@b.c', password: 'pw');
      // Sign-in succeeded; only refresh fails on this ledger.
      expect(notifier.state, isA<AuthSessionAuthenticated>());

      final out = await notifier.refreshSession();

      // Refresh ledger failure is intentionally non-fatal — session
      // stays alive so the user is not punished for a transient
      // last_seen_at write blip.
      expect(out, isNotNull);
      expect(notifier.state, isA<AuthSessionAuthenticated>());
      expect(notifier.session?.firebaseIdToken, equals('refreshed.token.sig'));
    });

    test('signOutThisSession clears state even when ledger revoke fails — '
        'local sign-out is a security primitive that always succeeds '
        '(audit-fix 2026-04-27)', () async {
      final ledger = _SignInOkRevokeFailLedger();
      final notifier = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(
          signInResult: AuthLoginSuccess(buildSession()),
        ),
        storage: InMemorySecureSessionStorage(),
        ledgerWriter: ledger,
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      await notifier.rehydrate();
      await notifier.signInWithEmailPassword(email: 'a@b.c', password: 'pw');
      expect(notifier.state, isA<AuthSessionAuthenticated>());

      await notifier.signOutThisSession();

      expect(notifier.state, isA<AuthSessionUnauthenticated>());
      expect(notifier.activeSessionId, isNull);
    });

    test('signOutThisSession revokes the active session_id with reason '
        'user_signed_out_this_session', () async {
      final ledger = InMemoryAuthSessionLedgerWriter(
        sessionIdFactory: () => _validSessionId,
      );
      final notifier = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(
          signInResult: AuthLoginSuccess(buildSession()),
        ),
        storage: InMemorySecureSessionStorage(),
        ledgerWriter: ledger,
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      await notifier.rehydrate();
      await notifier.signInWithEmailPassword(email: 'a@b.c', password: 'pw');

      await notifier.signOutThisSession();

      expect(notifier.activeSessionId, isNull);
      expect(
        ledger.revokedSessions[_validSessionId],
        equals('user_signed_out_this_session'),
      );
    });

    test('signOutAllSessions revokes every session for the user with reason '
        'user_signed_out_all_sessions', () async {
      final ledger = InMemoryAuthSessionLedgerWriter(
        sessionIdFactory: () => _validSessionId,
      );
      final notifier = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(
          signInResult: AuthLoginSuccess(buildSession()),
        ),
        storage: InMemorySecureSessionStorage(),
        ledgerWriter: ledger,
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      await notifier.rehydrate();
      await notifier.signInWithEmailPassword(email: 'a@b.c', password: 'pw');

      await notifier.signOutAllSessions();

      expect(notifier.activeSessionId, isNull);
      expect(ledger.revokedAllForUser, hasLength(1));
      expect(ledger.revokedAllForUser.single.userId, equals(_validUserId));
      expect(
        ledger.revokedAllForUser.single.reason,
        equals('user_signed_out_all_sessions'),
      );
    });

    test('refreshSession updates last_seen_at via ledgerWriter.recordRefresh '
        'on the active session_id', () async {
      final ledger = InMemoryAuthSessionLedgerWriter(
        sessionIdFactory: () => _validSessionId,
      );
      final session = buildSession();
      final refreshed = session.copyWith(
        firebaseIdToken: 'refreshed.token.sig',
        issuedAt: DateTime.utc(2026, 4, 26, 12),
        expiresAt: DateTime.utc(2026, 4, 26, 14),
        lastFreshAuthAt: DateTime.utc(2026, 4, 26, 12),
      );
      final service = _FakeAuthLoginService(
        signInResult: AuthLoginSuccess(session),
        refreshResult: refreshed,
      );
      final notifier = AuthSessionNotifier(
        loginService: service,
        storage: InMemorySecureSessionStorage(),
        ledgerWriter: ledger,
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      await notifier.rehydrate();
      await notifier.signInWithEmailPassword(email: 'a@b.c', password: 'pw');

      final out = await notifier.refreshSession();

      expect(out, isNotNull);
      expect(notifier.session?.firebaseIdToken, equals('refreshed.token.sig'));
      expect(ledger.refreshCalls[_validSessionId], equals(1));
    });
  });

  // ─── Audit-fix 2026-04-27 follow-up (Codex F1+F2) ─────────────────────
  //
  // F1: persisted shape carries `auth_sessions.session_id` so cold-start
  //     rehydrate restores `_activeSessionId`. Without this, post-restart
  //     refresh / sign-out silently skipped their ledger calls.
  // F2: side-effect order on sign-in is ledger → storage → state, so a
  //     ledger failure can never leave a persisted session orphaned from
  //     its `auth_sessions` row. A storage failure AFTER the ledger
  //     succeeds keeps the in-memory session live (matches the existing
  //     storage-error tolerance in rehydrate / refresh).
  group('AuthSessionNotifier audit-fix 2026-04-27 (Codex F1+F2)', () {
    AuthSession buildSession({
      String userId = _validUserId,
      String operatorId = _validOpId,
      String locationId = _validLocId,
      String token = 'header.payload.sig',
    }) {
      return AuthSession(
        userId: userId,
        operatorId: operatorId,
        locationId: locationId,
        firebaseIdToken: token,
        issuedAt: DateTime.utc(2026, 4, 26, 11, 59),
        expiresAt: DateTime.utc(2026, 4, 26, 13),
        lastFreshAuthAt: DateTime.utc(2026, 4, 26, 11, 59),
        roles: const <String>['operator_owner'],
        mfaEnrolled: true,
      );
    }

    test('F1: cold-start rehydrate restores activeSessionId from the '
        'envelope, and refresh + signOut after rehydrate use the original '
        'session_id', () async {
      final sharedStorage = InMemorySecureSessionStorage();
      final sharedLedger = InMemoryAuthSessionLedgerWriter(
        sessionIdFactory: () => _validSessionId,
      );
      final session = buildSession();
      final refreshed = session.copyWith(
        firebaseIdToken: 'refreshed.token.sig',
        issuedAt: DateTime.utc(2026, 4, 26, 12),
        expiresAt: DateTime.utc(2026, 4, 26, 14),
        lastFreshAuthAt: DateTime.utc(2026, 4, 26, 12),
      );

      // Notifier A — first launch: signs in, ledger issues session_id,
      // storage persists the envelope.
      final notifierA = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(
          signInResult: AuthLoginSuccess(session),
        ),
        storage: sharedStorage,
        ledgerWriter: sharedLedger,
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      await notifierA.rehydrate();
      await notifierA.signInWithEmailPassword(email: 'a@b.c', password: 'pw');
      expect(notifierA.activeSessionId, equals(_validSessionId));

      // Acceptance: the persisted shape is the envelope (carries the
      // `auth_session_id` so cold-start restore can hydrate it).
      final envelope = await sharedStorage.readEnvelope();
      expect(envelope, isNotNull);
      expect(envelope!.authSessionId, equals(_validSessionId));
      expect(envelope.session.userId, equals(_validUserId));

      // Notifier B — simulated cold restart: same storage + ledger.
      final notifierB = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(
          signInResult: const AuthLoginFailure(
            code: 'unused',
            message: 'cold-restart notifier never signs in again',
          ),
          refreshResult: refreshed,
        ),
        storage: sharedStorage,
        ledgerWriter: sharedLedger,
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      await notifierB.rehydrate();

      // Acceptance: state is Authenticated AND activeSessionId is the
      // original id from notifier A's sign-in.
      expect(notifierB.state, isA<AuthSessionAuthenticated>());
      expect(notifierB.activeSessionId, equals(_validSessionId));

      // Refresh after cold restart now hits the ledger with the
      // original session_id — before F1 the id was null and the
      // recordRefresh call was silently skipped.
      await notifierB.refreshSession();
      expect(sharedLedger.refreshCalls[_validSessionId], equals(1));

      // Sign-out after cold restart revokes the original session_id —
      // before F1 the id was null and the revokeSession call was
      // silently skipped, leaving an orphan row in `auth_sessions`.
      await notifierB.signOutThisSession();
      expect(
        sharedLedger.revokedSessions[_validSessionId],
        equals('user_signed_out_this_session'),
      );
      expect(notifierB.activeSessionId, isNull);
      expect(notifierB.state, isA<AuthSessionUnauthenticated>());
    });

    test('F1 backwards-compat: legacy bare-AuthSession blob rehydrates '
        'with authSessionId=null so the user stays signed in across the '
        'envelope upgrade (refresh + signOut skip ledger until next '
        'fresh sign-in)', () async {
      final session = buildSession();
      // Pre-populate storage with the LEGACY bare-AuthSession shape
      // (top-level `user_id`, no `session` key, no `auth_session_id`).
      final storage = InMemorySecureSessionStorage();
      await storage.writeSessionJson(jsonEncode(session.toJson()));

      final ledger = InMemoryAuthSessionLedgerWriter(
        sessionIdFactory: () => _validSessionId,
      );
      final notifier = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(
          signInResult: AuthLoginSuccess(session),
          refreshResult: session.copyWith(
            firebaseIdToken: 'refreshed.token.sig',
          ),
        ),
        storage: storage,
        ledgerWriter: ledger,
        now: () => DateTime.utc(2026, 4, 26, 12),
      );

      await notifier.rehydrate();

      // Acceptance: rehydrate succeeds (user stays signed in) but the
      // legacy blob has no ledger id, so activeSessionId is null.
      expect(notifier.state, isA<AuthSessionAuthenticated>());
      expect(notifier.activeSessionId, isNull);

      // refreshSession does NOT make a ledger call (no id to address)
      // — it cannot guess at an id and won't write a stale row.
      await notifier.refreshSession();
      expect(ledger.refreshCalls, isEmpty);

      // signOutThisSession does NOT make a ledger call either, but
      // the local sign-out (state cleared, storage cleared) still
      // succeeds — the security primitive is preserved.
      await notifier.signOutThisSession();
      expect(ledger.revokedSessions, isEmpty);
      expect(notifier.state, isA<AuthSessionUnauthenticated>());
      expect(await storage.readSessionJson(), isNull);
    });

    test('F2 reorder: ledger.recordLogin runs BEFORE storage.write — '
        'when the ledger rejects, storage.writeSessionJson is never '
        'called (no orphaned persisted session)', () async {
      final storage = _ObservableSecureSessionStorage();
      final notifier = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(
          signInResult: AuthLoginSuccess(buildSession()),
        ),
        storage: storage,
        ledgerWriter: const ScaffoldFailingAuthSessionLedgerWriter(),
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      await notifier.rehydrate();

      final result = await notifier.signInWithEmailPassword(
        email: 'a@b.c',
        password: 'pw',
      );

      // Ledger failure surfaces as ledger_unavailable (existing
      // fail-closed contract).
      expect(result, isA<AuthLoginFailure>());
      expect((result as AuthLoginFailure).code, equals('ledger_unavailable'));
      // Acceptance for F2: storage's writeSessionJson was NEVER
      // called during the failing sign-in. Without the reorder this
      // would be 1 (storage written first, then ledger failed, then
      // best-effort clear ran).
      expect(storage.writeJsonCalls, equals(0));
      // The defensive clear() still runs (belt + suspenders against
      // a stale legacy blob); fine because it's a no-op on empty.
      expect(storage.clearCalls, greaterThanOrEqualTo(1));
      expect(await storage.readSessionJson(), isNull);
    });

    test('F2 storage-fails-after-ledger: ledger row is written, '
        'in-memory session is authenticated, persistent login does '
        'not survive the next cold restart but UX stays low-friction '
        '(matches existing storage-error tolerance)', () async {
      final storage = _ObservableSecureSessionStorage()..throwOnWrite = true;
      final ledger = InMemoryAuthSessionLedgerWriter(
        sessionIdFactory: () => _validSessionId,
      );
      final notifier = AuthSessionNotifier(
        loginService: _FakeAuthLoginService(
          signInResult: AuthLoginSuccess(buildSession()),
        ),
        storage: storage,
        ledgerWriter: ledger,
        now: () => DateTime.utc(2026, 4, 26, 12),
      );
      await notifier.rehydrate();

      final result = await notifier.signInWithEmailPassword(
        email: 'a@b.c',
        password: 'pw',
      );

      // Acceptance: the result is success (not synthetic failure) —
      // the ledger row exists and the in-memory session is live so
      // the user can use the app for this launch.
      expect(result, isA<AuthLoginSuccess>());
      expect(notifier.state, isA<AuthSessionAuthenticated>());
      expect(notifier.activeSessionId, equals(_validSessionId));
      // Ledger received exactly one row.
      expect(ledger.logins, hasLength(1));
      expect(ledger.issuedSessionIds.single, equals(_validSessionId));
      // Storage write was attempted (post-ledger) and threw — backing
      // store stays empty, so a cold restart will land on the
      // unauthenticated screen and the user signs in again.
      expect(storage.writeJsonCalls, equals(1));
      expect(await storage.readSessionJson(), isNull);
    });
  });
}

// ─── Helpers ──────────────────────────────────────────────────────────────

AuthSessionLedgerLogin _loginFor({required String userId}) {
  return AuthSessionLedgerLogin(
    userId: userId,
    operatorId: _validOpId,
    locationId: _validLocId,
    tokenHash: 'h',
  );
}

class _FakeFirebaseAuthClient implements FirebaseAuthClient {
  _FakeFirebaseAuthClient({this.nextSignInOutcome, this.nextRefreshCredential});

  FirebaseAuthSignInOutcome? nextSignInOutcome;
  FirebaseAuthCredential? nextRefreshCredential;
  int signInCalls = 0;
  int completeTotpCalls = 0;
  int signOutCalls = 0;
  int revokeAllCalls = 0;

  @override
  Future<FirebaseAuthSignInOutcome> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    signInCalls += 1;
    return nextSignInOutcome ??
        const FirebaseAuthSignInFailed(
          code: 'unconfigured',
          message: 'fake client did not specify a result',
        );
  }

  @override
  Future<FirebaseAuthSignInOutcome> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async {
    completeTotpCalls += 1;
    return nextSignInOutcome ??
        const FirebaseAuthSignInFailed(
          code: 'unconfigured',
          message: 'fake client did not specify a result',
        );
  }

  @override
  Future<void> requestPasswordReset({required String email}) async {}

  @override
  Future<FirebaseAuthCredential?> refreshIdToken() async {
    return nextRefreshCredential;
  }

  /// Fake live-token getter — `currentIdToken` returns whatever the
  /// test pinned (defaults to a static placeholder so callers that
  /// don't care about the value still get a non-null token).
  String? nextIdToken = 'fake-id-token';
  int currentIdTokenCalls = 0;

  @override
  Future<String?> currentIdToken() async {
    currentIdTokenCalls += 1;
    return nextIdToken;
  }

  @override
  Future<void> signOut() async {
    signOutCalls += 1;
  }

  @override
  Future<void> revokeAllRefreshTokens() async {
    revokeAllCalls += 1;
  }
}

class _FakeAuthLoginService implements AuthLoginService {
  _FakeAuthLoginService({this.signInResult, this.refreshResult});

  AuthLoginResult? signInResult;
  AuthSession? refreshResult;
  int signInCalls = 0;
  int signOutThisSessionCalls = 0;
  int signOutAllSessionsCalls = 0;
  int refreshCalls = 0;

  @override
  Future<AuthLoginResult> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    signInCalls += 1;
    return signInResult ??
        const AuthLoginFailure(
          code: 'unconfigured',
          message: 'fake service did not specify a result',
        );
  }

  @override
  Future<AuthLoginResult> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async {
    return signInResult ??
        const AuthLoginFailure(
          code: 'unconfigured',
          message: 'fake service did not specify a result',
        );
  }

  @override
  Future<void> requestPasswordReset({required String email}) async {}

  @override
  Future<AuthSession?> refreshSession(AuthSession current) async {
    refreshCalls += 1;
    return refreshResult;
  }

  @override
  Future<void> signOutThisSession() async {
    signOutThisSessionCalls += 1;
  }

  @override
  Future<void> signOutAllSessions() async {
    signOutAllSessionsCalls += 1;
  }
}

// Fake PostgresPool that records SQL + parameters per transaction
// and returns a synthetic RETURNING session_id row.
class _AuthSessionsPool implements PostgresPool {
  _AuthSessionsPool({required this.returningSessionId});

  final String? returningSessionId;
  final List<_AuthSessionsTransaction> transactions =
      <_AuthSessionsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _AuthSessionsTransaction(returningSessionId: returningSessionId);
    transactions.add(tx);
    return tx;
  }
}

class _AuthSessionsTransaction extends PostgresTransaction {
  _AuthSessionsTransaction({required this.returningSessionId});

  final String? returningSessionId;
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
    if (sql.contains('insert into auth_sessions') &&
        sql.contains('returning')) {
      final id = returningSessionId;
      if (id == null) return <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'session_id': id},
      ];
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

// Make the `OperatorScopedRepository` import noisily-used for analyzer
// (the test file references the type indirectly through the repo
// subclass; an import-only reference quiets `unused_import`).
// ignore: unused_element
typedef _OsrAlias = OperatorScopedRepository;

// Ledger that accepts the initial recordLogin (so the sign-in path
// can complete) but throws on every subsequent recordRefresh. Lets
// the refresh log-and-continue audit-fix test target the exact seam.
class _SignInOkRefreshFailLedger implements AuthSessionLedgerWriter {
  int loginCalls = 0;
  int refreshCalls = 0;

  @override
  Future<String> recordLogin(AuthSessionLedgerLogin login) async {
    loginCalls += 1;
    return _validSessionId;
  }

  @override
  Future<void> recordRefresh({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
  }) async {
    refreshCalls += 1;
    throw StateError('synthetic refresh ledger failure');
  }

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {}

  @override
  Future<int> revokeAllSessionsForUser({
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async => 0;
}

// Ledger that accepts recordLogin but throws on revokeSession /
// revokeAllSessionsForUser. Lets the sign-out log-and-continue
// audit-fix test target the exact seam.
class _SignInOkRevokeFailLedger implements AuthSessionLedgerWriter {
  @override
  Future<String> recordLogin(AuthSessionLedgerLogin login) async {
    return _validSessionId;
  }

  @override
  Future<void> recordRefresh({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
  }) async {}

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    throw StateError('synthetic revoke ledger failure');
  }

  @override
  Future<int> revokeAllSessionsForUser({
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    throw StateError('synthetic revoke-all ledger failure');
  }
}

// Recording / failure-mode storage for the F2 audit-fix tests.
// Wraps an [InMemorySecureSessionStorage] but counts write/clear
// calls and can be flipped to throw on writeSessionJson so the test
// can isolate "storage write failed after ledger succeeded".
class _ObservableSecureSessionStorage extends SecureSessionStorage {
  _ObservableSecureSessionStorage();

  final InMemorySecureSessionStorage _inner = InMemorySecureSessionStorage();
  int writeJsonCalls = 0;
  int clearCalls = 0;
  bool throwOnWrite = false;

  @override
  Future<String?> readSessionJson() => _inner.readSessionJson();

  @override
  Future<void> writeSessionJson(String json) async {
    writeJsonCalls += 1;
    if (throwOnWrite) {
      throw StateError('synthetic storage write failure');
    }
    await _inner.writeSessionJson(json);
  }

  @override
  Future<void> clear() async {
    clearCalls += 1;
    await _inner.clear();
  }
}
