// Phase 9 live-closeout B6 - Repository-backed AuthSessionLedgerWriter.
//
// Production binding for [AuthSessionLedgerWriter]. Wraps the Postgres
// [AuthSessionsRepository] so every ledger write flows through the
// `OperatorScopedRepository` + `TenantTransactionWrapper` path. Tests
// inject fakes via the in-memory writer; the live staging smoke (B8)
// uses this binding pointed at the real Postgres pool.

import '../../infrastructure/persistence/postgres/repositories/auth_sessions_repository.dart';
import 'auth_session_ledger_writer.dart';

class RepositoryAuthSessionLedgerWriter implements AuthSessionLedgerWriter {
  RepositoryAuthSessionLedgerWriter({
    required AuthSessionsRepository repository,
  }) : _repository = repository;

  final AuthSessionsRepository _repository;

  /// B1.A6 — Concurrent-session cap enforcement.
  ///
  /// Before inserting the new session, count active sessions for the user.
  /// When already at [AuthSessionsRepository.kMaxConcurrentSessions], evict
  /// the oldest active session (LRU eviction) to make room. This means a
  /// legitimate user on a new device automatically "pushes out" their oldest
  /// session, giving a clear UX signal via the Active Sessions viewer.
  ///
  /// Eviction is best-effort: a race between two concurrent logins may
  /// temporarily allow N+1 sessions. The cap is eventually enforced on
  /// the next login attempt.
  @override
  Future<String> recordLogin(AuthSessionLedgerLogin login) async {
    final activeCount = await _repository.countActiveSessions(
      userId: login.userId,
      adminReason: 'auth.session_cap_check',
    );
    if (activeCount >= AuthSessionsRepository.kMaxConcurrentSessions) {
      await _repository.evictOldestSession(
        userId: login.userId,
        adminReason: 'auth.session_cap_eviction',
      );
    }
    return _repository.insertLogin(
      operatorId: login.operatorId,
      locationId: login.locationId,
      userId: login.userId,
      tokenHash: login.tokenHash,
      ip: login.context.ip,
      userAgent: login.context.userAgent,
      deviceFingerprint: login.context.deviceFingerprint,
      geoCountry: login.context.geoCountry,
    );
  }

  @override
  Future<void> recordRefresh({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
  }) async {
    await _repository.markRefreshed(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
      sessionId: sessionId,
    );
  }

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    await _repository.revokeSession(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
      sessionId: sessionId,
      reason: reason,
    );
  }

  @override
  Future<int> revokeAllSessionsForUser({
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) {
    return _repository.revokeAllSessionsForUser(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
      reason: reason,
    );
  }
}
