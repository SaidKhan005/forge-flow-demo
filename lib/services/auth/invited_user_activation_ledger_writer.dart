// Phase 9 live-closeout - invited-user activation around session login.
//
// The mobile app already records a session row on every successful Firebase
// sign-in. For users created by Settings -> Team invite, that first sign-in is
// also the moment the invite is accepted: Firebase password reset completed,
// the user proved mailbox control, and the app is about to persist a session.

import '../../infrastructure/persistence/postgres/repositories/invited_user_activation_repository.dart';
import '../observability/log.dart';
import 'auth_session_ledger_writer.dart';

/// Signature of the structured logger this decorator emits through.
/// Defaults to the production [log]; tests inject a recorder so a
/// skipped-activation event can be asserted without touching stdout.
typedef ActivationSkipLogger =
    void Function(
      LogSeverity severity,
      String event, {
      Map<String, Object?> fields,
    });

void _defaultActivationSkipLogger(
  LogSeverity severity,
  String event, {
  Map<String, Object?> fields = const <String, Object?>{},
}) {
  log(severity, event, fields: fields);
}

class InvitedUserActivationLedgerWriter implements AuthSessionLedgerWriter {
  InvitedUserActivationLedgerWriter({
    required AuthSessionLedgerWriter delegate,
    required InvitedUserActivationRepository activationRepository,
    ActivationSkipLogger logger = _defaultActivationSkipLogger,
  }) : _delegate = delegate,
       _activationRepository = activationRepository,
       _logger = logger;

  final AuthSessionLedgerWriter _delegate;
  final InvitedUserActivationRepository _activationRepository;
  final ActivationSkipLogger _logger;

  @override
  Future<String> recordLogin(AuthSessionLedgerLogin login) async {
    // G66 / Q3: operator decision pending — see
    // docs/_audits/cross_surface_parity_v1/onboarding_server_slice_spec.md.
    //
    // The invite-acceptance transition runs BEFORE the session-row write so
    // `users.status` and `auth_invites.accepted_at` can never drift apart
    // from a recorded login. `acceptPendingInviteAfterLogin` throws a
    // `StateError` only for data-integrity edges (an invited user row with
    // no open/unexpired invite, a malformed invite_id, or a 0-row status
    // flip). Per the spec's RECOMMENDED default we treat those edges as
    // non-fatal: catch `StateError` specifically, emit an observable
    // structured log so a skipped activation is never silent, then continue
    // to the delegate so the operator can still sign in. Genuine
    // infrastructure failures (DB connection loss, query timeouts) are NOT
    // `StateError`s, so they propagate uncaught and fail the login closed —
    // we never write a session row while the activation transition's outcome
    // is unknown.
    try {
      await _activationRepository.acceptPendingInviteAfterLogin(
        userId: login.userId,
        operatorId: login.operatorId,
        locationId: login.locationId,
      );
    } on StateError catch (error) {
      _logger(
        LogSeverity.warning,
        'auth.invite_activation.skipped',
        fields: <String, Object?>{
          'user_id': login.userId,
          'operator_id': login.operatorId,
          'location_id': login.locationId,
          'reason': 'data_integrity',
          'error_message': error.message,
        },
      );
    }
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
