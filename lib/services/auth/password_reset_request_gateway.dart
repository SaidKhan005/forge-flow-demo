// Phase 9.UX.7 - server-side password-reset request gateway.
//
// Sits behind the proxy `POST /v1/auth/password/reset/request` route.
// The gateway is responsible for issuing the Firebase action link
// email; the route is privacy-preserving by contract — the client
// always sees a uniform success response regardless of whether the
// email matches an active account, so we never leak presence
// through either the response body OR wall-clock latency.

import '../../infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'firebase_admin_auth_client.dart';

/// Looks up a user by email. Implementations may return null when
/// the email does not match an active account; throws are treated
/// as "unknown" by the gateway to keep the API surface uniform.
typedef PasswordResetUserLookup =
    Future<UserAuthLookupRow?> Function(String email);

/// Writes the `auth.password_reset_requested` audit row for a known
/// user. Only invoked when the lookup matched.
typedef PasswordResetAuditWriter =
    Future<void> Function(UserAuthLookupRow user);

class PasswordResetRequestCommand {
  const PasswordResetRequestCommand({required this.email, this.continueUrl});

  final String email;
  final String? continueUrl;
}

class PasswordResetRequestAccepted {
  const PasswordResetRequestAccepted();
}

class PasswordResetRequestThrottled implements Exception {
  const PasswordResetRequestThrottled({this.retryAfterSeconds});

  final int? retryAfterSeconds;
}

abstract class PasswordResetRequestGateway {
  /// Asks Firebase Identity Platform to send a password-reset action
  /// link to [command.email]. Returns success even when the email
  /// does not match an active account so the proxy can render
  /// privacy-preserving copy. Throws
  /// [PasswordResetRequestThrottled] when the operator is rate-
  /// limited.
  Future<PasswordResetRequestAccepted> requestReset(
    PasswordResetRequestCommand command,
  );
}

class RepositoryPasswordResetRequestGateway
    implements PasswordResetRequestGateway {
  RepositoryPasswordResetRequestGateway({
    required FirebaseAdminAuthClient firebaseAdmin,
    required UsersRepository usersRepository,
    required AuthEventsAuditRepository auditRepository,
    String? continueUrl,
    Duration latencyFloor = const Duration(milliseconds: 350),
    Future<void> Function(Duration)? sleep,
    Stopwatch Function()? stopwatchFactory,
  }) : this.fromDependencies(
         firebaseAdmin: firebaseAdmin,
         lookup: (email) => usersRepository.findActiveAuthUserByEmail(
           email: email,
           adminReason: 'auth.password_reset_request_lookup',
         ),
         auditWriter: (user) => auditRepository
             .insertSystemEvent(
               operatorId: user.operatorId,
               locationId: user.locationId,
               actorKind: 'system',
               targetUserId: user.userId,
               eventType: 'auth.password_reset_requested',
               payload: const <String, Object?>{},
               adminReason: 'auth.password_reset_request',
             )
             .then((_) {}),
         continueUrl: continueUrl,
         latencyFloor: latencyFloor,
         sleep: sleep,
         stopwatchFactory: stopwatchFactory,
       );

  /// Test-friendly constructor that takes typedef dependencies
  /// directly, so unit tests can inject fakes without standing up
  /// the full Postgres + Firebase Admin stack.
  RepositoryPasswordResetRequestGateway.fromDependencies({
    required this.firebaseAdmin,
    required PasswordResetUserLookup lookup,
    required PasswordResetAuditWriter auditWriter,
    this.continueUrl,
    this.latencyFloor = const Duration(milliseconds: 350),
    Future<void> Function(Duration)? sleep,
    Stopwatch Function()? stopwatchFactory,
  }) : _lookup = lookup,
       _auditWriter = auditWriter,
       _sleep = sleep ?? _defaultSleep,
       _stopwatchFactory = stopwatchFactory ?? Stopwatch.new;

  final FirebaseAdminAuthClient firebaseAdmin;
  final PasswordResetUserLookup _lookup;
  final PasswordResetAuditWriter _auditWriter;
  final String? continueUrl;

  /// Both the unknown-email and known-email branches pad to at
  /// least this duration so wall-clock latency does not leak
  /// account presence to a client that times the response.
  /// Set generously enough to cover the slowest of:
  ///   * Firebase Identity Toolkit `sendOobCode` issuance
  ///   * the audit insert on the known branch
  /// without dragging the legitimate path down. 350ms balances
  /// "feels instant" with "absorbs the audit-insert tail."
  final Duration latencyFloor;

  final Future<void> Function(Duration) _sleep;
  final Stopwatch Function() _stopwatchFactory;

  @override
  Future<PasswordResetRequestAccepted> requestReset(
    PasswordResetRequestCommand command,
  ) async {
    final stopwatch = _stopwatchFactory()..start();
    try {
      // Privacy contract: do the same work whether the email matches
      // a real user or not. A response-latency oracle would otherwise
      // let a client distinguish (wall-clock between known + unknown
      // is the cleanest leak channel — we close it here, not at the
      // route layer where the response payloads are already uniform).
      //
      // Lookup errors propagate intentionally. Swallowing them as
      // "unknown" would let a transient Postgres blip send a
      // reset email to a real account WITHOUT the corresponding
      // `auth.password_reset_requested` audit row (since we couldn't
      // resolve the user_id). That gap matters more than the small
      // presence-via-503 channel: the proxy returns a generic
      // `password_reset_request_unavailable` 503, which is a
      // service-level signal ("infrastructure issue, retry") rather
      // than per-account. The operator retries and the next attempt
      // fully audits.
      final user = await _lookup(command.email);
      // Always call Firebase. For unknown emails, Identity Platform
      // returns EMAIL_NOT_FOUND and we swallow it; the round-trip
      // latency stays comparable to the known-email path.
      try {
        await firebaseAdmin.sendPasswordResetEmail(
          email: command.email,
          continueUrl: command.continueUrl ?? continueUrl,
        );
      } on FirebaseAdminAuthError catch (error) {
        if (error.code == 'TOO_MANY_ATTEMPTS_TRY_LATER' ||
            error.statusCode == 429) {
          throw const PasswordResetRequestThrottled();
        }
        if (error.code == 'EMAIL_NOT_FOUND' || error.statusCode == 404) {
          // Privacy-preserving silent succeed. Do NOT audit the
          // unknown email — auditing it would just move the presence
          // oracle into the audit log instead of the response body.
        } else {
          rethrow;
        }
      }
      // Audit lands only when the email matched a real user. We
      // pad the unknown branch with a comparable wait below so the
      // audit-insert latency on the known branch does not leak.
      if (user != null) {
        await _auditWriter(user);
      }
      return const PasswordResetRequestAccepted();
    } finally {
      // Latency floor: always wait until at least [latencyFloor]
      // has elapsed before returning. Closes the wall-clock oracle
      // both for happy-path requests and for the throttled rethrow
      // (Firebase 429s are rare enough that aligning their latency
      // with the success path is not worth a separate code path).
      final remaining = latencyFloor - stopwatch.elapsed;
      if (remaining > Duration.zero) {
        await _sleep(remaining);
      }
    }
  }

  static Future<void> _defaultSleep(Duration duration) =>
      Future<void>.delayed(duration);
}
