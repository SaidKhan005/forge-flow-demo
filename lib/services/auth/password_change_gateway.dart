// Phase 9 live-closeout - signed-in password-change gateway.
//
// Flutter calls this seam; the proxy implementation owns the trusted
// choreography: verify the current Firebase password, evaluate policy/HIBP/
// password-history rules, update Firebase, record password_history, and append
// audit rows. Raw passwords must never be logged or included in toString().

class PasswordChangeCommand {
  const PasswordChangeCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.currentPassword,
    required this.newPassword,
    this.firebaseUid,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String currentPassword;
  final String newPassword;

  /// Verified Firebase Auth subject for the currently signed-in account.
  ///
  /// Self-service password changes must update the account represented by the
  /// bearer token. Some legacy staging rows predate the "Firebase UID equals
  /// app user UUID" convention, so the database mapping is only a fallback.
  final String? firebaseUid;
}

class PasswordChangeCompleted {
  const PasswordChangeCompleted({this.hibpUnavailable = false});

  final bool hibpUnavailable;
}

class PasswordChangeRejected implements Exception {
  const PasswordChangeRejected({
    required this.code,
    required this.message,
    this.statusCode = 422,
    this.rejections = const <String>[],
  });

  final String code;
  final String message;
  final int statusCode;
  final List<String> rejections;

  @override
  String toString() =>
      'PasswordChangeRejected(code: $code, status: $statusCode)';
}

abstract class PasswordChangeGateway {
  Future<PasswordChangeCompleted> changePassword(PasswordChangeCommand command);
}

class ScaffoldFailingPasswordChangeGateway implements PasswordChangeGateway {
  const ScaffoldFailingPasswordChangeGateway();

  @override
  Future<PasswordChangeCompleted> changePassword(
    PasswordChangeCommand command,
  ) {
    throw StateError(
      'Phase 9 password-change gateway is not wired; bind the proxy-backed '
      'gateway before exposing signed-in password changes.',
    );
  }
}
