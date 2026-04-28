// Phase 9 live-closeout - invited-user activation around session login.
//
// The mobile app already records a session row on every successful Firebase
// sign-in. For users created by Settings -> Team invite, that first sign-in is
// also the moment the invite is accepted: Firebase password reset completed,
// the user proved mailbox control, and the app is about to persist a session.

import '../../infrastructure/persistence/postgres/repositories/invited_user_activation_repository.dart';
import 'auth_session_ledger_writer.dart';

class InvitedUserActivationLedgerWriter implements AuthSessionLedgerWriter {
  InvitedUserActivationLedgerWriter({
    required AuthSessionLedgerWriter delegate,
    required InvitedUserActivationRepository activationRepository,
  }) : _delegate = delegate,
       _activationRepository = activationRepository;

  final AuthSessionLedgerWriter _delegate;
  final InvitedUserActivationRepository _activationRepository;

  @override
  Future<String> recordLogin(AuthSessionLedgerLogin login) async {
    await _activationRepository.acceptPendingInviteAfterLogin(
      userId: login.userId,
      operatorId: login.operatorId,
      locationId: login.locationId,
    );
    return _delegate.recordLogin(login);
  }

  @override
  Future<void> recordRefresh({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
  }) {
    return _delegate.recordRefresh(
      sessionId: sessionId,
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
    );
  }

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) {
    return _delegate.revokeSession(
      sessionId: sessionId,
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
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
    return _delegate.revokeAllSessionsForUser(
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
      reason: reason,
    );
  }
}
