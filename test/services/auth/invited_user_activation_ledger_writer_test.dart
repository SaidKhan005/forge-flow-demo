// G66 / server-slice S1 — InvitedUserActivationLedgerWriter decorator.
//
// Proves the cross-surface fix: the decorator runs the invite-acceptance
// transition before delegating the auth_sessions write so every live
// invitee (mobile AND operator-web hit the same proxy login binding)
// flips users.status invited->active + stamps auth_invites.accepted_at.
//
// Q3 failure policy (operator decision pending — RECOMMENDED default
// implemented per docs/_audits/cross_surface_parity_v1/
// onboarding_server_slice_spec.md):
//   * data-integrity StateError  => caught, observable log emitted,
//                                    login still succeeds (fail-open on
//                                    a data edge, never silent);
//   * genuine infra exception    => propagates, login fails closed.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/invited_user_activation_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/invited_user_activation_ledger_writer.dart';
import 'package:forge_and_flow/services/observability/log.dart';

void main() {
  const login = AuthSessionLedgerLogin(
    userId: 'user-1',
    operatorId: 'op-1',
    locationId: 'loc-1',
    tokenHash: 'hash-1',
  );

  group('InvitedUserActivationLedgerWriter.recordLogin', () {
    test(
      'invited first login activates BEFORE the session row is written',
      () async {
        final activation = _FakeActivationRepository(
          result: const InvitedUserActivationResult.accepted(
            inviteId: 'invite-1',
          ),
        );
        final delegate = _RecordingDelegate(sessionId: 'sess-1');
        final order = <String>[];
        activation.onCall = () => order.add('activation');
        delegate.onRecordLogin = () => order.add('delegate');

        final writer = InvitedUserActivationLedgerWriter(
          delegate: delegate,
          activationRepository: activation,
        );

        final sessionId = await writer.recordLogin(login);

        expect(sessionId, 'sess-1');
        expect(activation.calls, 1);
        expect(delegate.recordLoginCalls, 1);
        // Activation MUST run before the session-row write so users.status
        // / auth_invites.accepted_at never drift apart from a login.
        expect(order, <String>['activation', 'delegate']);
        expect(activation.lastUserId, 'user-1');
        expect(activation.lastOperatorId, 'op-1');
        expect(activation.lastLocationId, 'loc-1');
      },
    );

    test('second login is idempotent — skipped result, no error, '
        'session still written', () async {
      final activation = _FakeActivationRepository(
        // Repo returns `.skipped()` when the user is already active /
        // has no open invite-by-status; the decorator must treat that
        // as a normal no-op (no throw, no double-write).
        result: const InvitedUserActivationResult.skipped(),
      );
      final delegate = _RecordingDelegate(sessionId: 'sess-2');

      final writer = InvitedUserActivationLedgerWriter(
        delegate: delegate,
        activationRepository: activation,
      );

      final sessionId = await writer.recordLogin(login);

      expect(sessionId, 'sess-2');
      expect(activation.calls, 1);
      expect(delegate.recordLoginCalls, 1);
    });

    test('data-integrity StateError is caught — login still succeeds and '
        'an observable log line is emitted', () async {
      final activation = _FakeActivationRepository(
        error: StateError('invited user has no open invite to accept'),
      );
      final delegate = _RecordingDelegate(sessionId: 'sess-3');
      final logged = <_LogLine>[];

      final writer = InvitedUserActivationLedgerWriter(
        delegate: delegate,
        activationRepository: activation,
        logger: (severity, event, {fields = const <String, Object?>{}}) {
          logged.add(_LogLine(severity, event, fields));
        },
      );

      final sessionId = await writer.recordLogin(login);

      // Login fails OPEN on a data edge: the session row is still written.
      expect(sessionId, 'sess-3');
      expect(delegate.recordLoginCalls, 1);
      // The skipped activation is observable, not silent.
      expect(logged, hasLength(1));
      expect(logged.single.severity, LogSeverity.warning);
      expect(logged.single.event, 'auth.invite_activation.skipped');
      expect(logged.single.fields['reason'], 'data_integrity');
      expect(logged.single.fields['user_id'], 'user-1');
      expect(
        logged.single.fields['error_message'],
        'invited user has no open invite to accept',
      );
    });

    test('genuine infra exception propagates — login fails closed, '
        'session row NOT written', () async {
      final activation = _FakeActivationRepository(
        // A DB/connection failure is NOT a StateError, so the decorator
        // must let it propagate and never write a session row while the
        // activation outcome is unknown.
        error: const _FakeInfraException('connection refused'),
      );
      final delegate = _RecordingDelegate(sessionId: 'sess-4');

      final writer = InvitedUserActivationLedgerWriter(
        delegate: delegate,
        activationRepository: activation,
      );

      await expectLater(
        writer.recordLogin(login),
        throwsA(isA<_FakeInfraException>()),
      );
      expect(delegate.recordLoginCalls, 0);
    });

    test('recordRefresh / revokeSession / revokeAllSessionsForUser are '
        'pure pass-through (no activation side effects)', () async {
      final activation = _FakeActivationRepository(
        result: const InvitedUserActivationResult.skipped(),
      );
      final delegate = _RecordingDelegate(sessionId: 'sess-5');

      final writer = InvitedUserActivationLedgerWriter(
        delegate: delegate,
        activationRepository: activation,
      );

      await writer.recordRefresh(
        sessionId: 'sess-5',
        userId: 'user-1',
        operatorId: 'op-1',
        locationId: 'loc-1',
      );
      await writer.revokeSession(
        sessionId: 'sess-5',
        userId: 'user-1',
        operatorId: 'op-1',
        locationId: 'loc-1',
        reason: 'logout',
      );
      final revoked = await writer.revokeAllSessionsForUser(
        userId: 'user-1',
        operatorId: 'op-1',
        locationId: 'loc-1',
        reason: 'admin',
      );

      expect(activation.calls, 0);
      expect(delegate.recordRefreshCalls, 1);
      expect(delegate.revokeSessionCalls, 1);
      expect(delegate.revokeAllCalls, 1);
      expect(revoked, 7);
    });
  });
}

class _LogLine {
  _LogLine(this.severity, this.event, this.fields);
  final LogSeverity severity;
  final String event;
  final Map<String, Object?> fields;
}

class _FakeInfraException implements Exception {
  const _FakeInfraException(this.message);
  final String message;
  @override
  String toString() => '_FakeInfraException: $message';
}

/// Subclasses the real repository and overrides only the seam method.
/// The `withSystem` path (and therefore the pool) is never touched, so
/// the wrapper is built over an [_UnusedPool] that throws if reached.
class _FakeActivationRepository extends InvitedUserActivationRepository {
  _FakeActivationRepository({this.result, this.error})
    : super(TenantTransactionWrapper(_UnusedPool()));

  final InvitedUserActivationResult? result;
  final Object? error;

  int calls = 0;
  String? lastUserId;
  String? lastOperatorId;
  String? lastLocationId;
  void Function()? onCall;

  @override
  Future<InvitedUserActivationResult> acceptPendingInviteAfterLogin({
    required String operatorId,
    required String locationId,
    required String userId,
  }) async {
    calls += 1;
    lastUserId = userId;
    lastOperatorId = operatorId;
    lastLocationId = locationId;
    onCall?.call();
    if (error != null) throw error!;
    return result ?? const InvitedUserActivationResult.skipped();
  }
}

class _UnusedPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() async {
    throw StateError(
      'PostgresPool.beginTransaction must not be reached — the decorator '
      'test overrides acceptPendingInviteAfterLogin so withSystem never runs',
    );
  }
}

class _RecordingDelegate implements AuthSessionLedgerWriter {
  _RecordingDelegate({required this.sessionId});

  final String sessionId;
  int recordLoginCalls = 0;
  int recordRefreshCalls = 0;
  int revokeSessionCalls = 0;
  int revokeAllCalls = 0;
  void Function()? onRecordLogin;

  @override
  Future<String> recordLogin(AuthSessionLedgerLogin login) async {
    recordLoginCalls += 1;
    onRecordLogin?.call();
    return sessionId;
  }

  @override
  Future<void> recordRefresh({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
  }) async {
    recordRefreshCalls += 1;
  }

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    revokeSessionCalls += 1;
  }

  @override
  Future<int> revokeAllSessionsForUser({
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    revokeAllCalls += 1;
    return 7;
  }
}
