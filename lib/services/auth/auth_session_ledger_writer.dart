// Phase 9 live-closeout B6 - AuthSessionLedgerWriter seam.
//
// The `auth_sessions` ledger writes (INSERT on login, UPDATE
// `last_seen_at` on refresh, SET `revoked_at` on logout) flow through
// this seam. The production binding wires
// `RepositoryAuthSessionLedgerWriter` over the `AuthSessionsRepository`
// (which uses the `OperatorScopedRepository` + `TenantTransactionWrapper`
// path so RLS / `forge_admin` audit gating stays consistent).
//
// Tests inject fakes that record calls without touching Postgres.
// The default binding is [ScaffoldFailingAuthSessionLedgerWriter] so a
// misconfigured deploy that wires the auth notifier but forgets the
// repository binding surfaces a "no auth ledger wired" error rather
// than silently dropping ledger rows.

/// Identifying + enrichment context the proxy collects per request:
/// IP, User-Agent, geo country, device fingerprint. Carried as a
/// value class so the writer signature stays narrow as we add fields.
class AuthSessionLedgerContext {
  const AuthSessionLedgerContext({
    this.ip,
    this.userAgent,
    this.geoCountry,
    this.deviceFingerprint,
  });

  final String? ip;
  final String? userAgent;

  /// ISO-3166 alpha-2 country code (e.g. `'CA'`, `'US'`). Validated
  /// at the schema layer; the writer passes through whatever the
  /// proxy resolved.
  final String? geoCountry;
  final String? deviceFingerprint;

  /// Empty context — used by tests + dev paths where no enrichment
  /// is available. Production paths SHOULD always carry IP + UA at a
  /// minimum.
  static const AuthSessionLedgerContext empty = AuthSessionLedgerContext();
}

/// Inputs for the INSERT-on-login write.
///
/// [tokenHash] is the SHA-256 hex digest of the credential token
/// associated with this session row. Today it is the live Firebase
/// **ID token** hash — the raw refresh token is held inside the
/// `firebase_auth` SDK and is not exposed to the proxy / client.
///
/// The hash:
///   * stably identifies the row across refreshes within an ID-token
///     lifetime;
///   * lets `auth_events_audit` joins reference the session without
///     leaking token material into logs.
///
/// The hash does NOT detect refresh-token reuse on its own — that
/// requires the actual refresh token, which Firebase does not surface
/// today. When a future slice does have access to the refresh token
/// (e.g. through a server-issued opaque session token), it can land
/// the real refresh-token hash in the same `token_hash` column
/// without changing the contract.
class AuthSessionLedgerLogin {
  const AuthSessionLedgerLogin({
    required this.userId,
    required this.operatorId,
    required this.locationId,
    required this.tokenHash,
    this.context = AuthSessionLedgerContext.empty,
  });

  final String userId;
  final String operatorId;
  final String locationId;
  final String tokenHash;
  final AuthSessionLedgerContext context;
}

/// Result of a successful login ledger write.
///
/// Most writers simply echo the local [AuthSessionLedgerLogin] scope,
/// but proxy-backed writers can return the canonical scope resolved
/// server-side from the verified Firebase bearer token. That matters
/// when the client only has the Firebase UID provisionally and the
/// proxy maps it to the production `users.user_id`.
class AuthSessionLedgerLoginRecord {
  const AuthSessionLedgerLoginRecord({
    required this.sessionId,
    required this.userId,
    required this.operatorId,
    required this.locationId,
  });

  final String sessionId;
  final String userId;
  final String operatorId;
  final String locationId;
}

/// What the production `AuthLoginService` (and tests) calls into.
abstract class AuthSessionLedgerWriter {
  /// INSERT a row into `auth_sessions` and return the freshly
  /// generated `session_id`. The caller stores the `session_id`
  /// alongside the `AuthSession` so subsequent
  /// [recordRefresh] / [revokeSession] calls can address the same row.
  Future<String> recordLogin(AuthSessionLedgerLogin login);

  /// UPDATE `last_seen_at = now()` for [sessionId] (no-op when the
  /// row is already revoked). Tracks the user's continued presence
  /// for dormancy sweeps (~30 day cutoff).
  Future<void> recordRefresh({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
  });

  /// SET `revoked_at = now()` and `revoked_reason = [reason]` for
  /// [sessionId]. Idempotent — a second call on an already-revoked
  /// row is a no-op. Used for single-session sign-out.
  Future<void> revokeSession({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  });

  /// SET `revoked_at = now()` for every active row whose `user_id`
  /// matches [userId]. Returns the number of rows newly revoked
  /// (0 means everything was already revoked or there were no
  /// active sessions). Used for "log out everywhere" + force-logout
  /// admin paths.
  Future<int> revokeAllSessionsForUser({
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  });
}

/// Optional capability for writers that can return a server-resolved
/// login scope in addition to the `auth_sessions.session_id`.
abstract class AuthSessionLedgerScopeResolvingWriter {
  Future<AuthSessionLedgerLoginRecord> recordLoginAndResolveScope(
    AuthSessionLedgerLogin login,
  );
}

extension AuthSessionLedgerWriterScopeResolution on AuthSessionLedgerWriter {
  /// Records login and returns the effective scope the app should
  /// persist. Non-proxy writers fall back to the caller-provided
  /// scope, preserving existing test/dev behavior.
  Future<AuthSessionLedgerLoginRecord> recordLoginAndResolveScope(
    AuthSessionLedgerLogin login,
  ) async {
    final writer = this;
    if (writer is AuthSessionLedgerScopeResolvingWriter) {
      return (writer as AuthSessionLedgerScopeResolvingWriter)
          .recordLoginAndResolveScope(login);
    }
    final sessionId = await recordLogin(login);
    return AuthSessionLedgerLoginRecord(
      sessionId: sessionId,
      userId: login.userId,
      operatorId: login.operatorId,
      locationId: login.locationId,
    );
  }
}

/// Hard-fail-closed default. Every method throws so a production
/// deploy that wires the auth notifier but forgets the real ledger
/// writer binding surfaces a "no auth ledger wired" error rather than
/// silently dropping `auth_sessions` rows.
class ScaffoldFailingAuthSessionLedgerWriter
    implements AuthSessionLedgerWriter {
  const ScaffoldFailingAuthSessionLedgerWriter();

  @override
  Future<String> recordLogin(AuthSessionLedgerLogin login) async {
    throw StateError(_message);
  }

  @override
  Future<void> recordRefresh({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
  }) async {
    throw StateError(_message);
  }

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    throw StateError(_message);
  }

  @override
  Future<int> revokeAllSessionsForUser({
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    throw StateError(_message);
  }

  static const String _message =
      'B6 scaffold: real AuthSessionLedgerWriter is not wired — bind '
      '`RepositoryAuthSessionLedgerWriter` (over `AuthSessionsRepository`) '
      'in the app bootstrap before serving authenticated traffic.';
}

/// In-memory recorder for tests + previewer harnesses. Stores the
/// last-known state per session_id so test assertions can verify
/// the write sequence.
class InMemoryAuthSessionLedgerWriter implements AuthSessionLedgerWriter {
  InMemoryAuthSessionLedgerWriter({String Function()? sessionIdFactory})
    : _nextSessionId = sessionIdFactory ?? _defaultIdFactory;

  final String Function() _nextSessionId;

  /// Recorded login rows in insertion order.
  final List<AuthSessionLedgerLogin> logins = <AuthSessionLedgerLogin>[];

  /// session_ids returned by recordLogin, in insertion order.
  final List<String> issuedSessionIds = <String>[];

  /// Per-session `last_seen_at` UPDATE call counts.
  final Map<String, int> refreshCalls = <String, int>{};

  /// Per-session revoke metadata: maps session_id → reason.
  final Map<String, String> revokedSessions = <String, String>{};

  /// All-sessions revokes per user_id, in insertion order.
  final List<({String userId, String reason})> revokedAllForUser =
      <({String userId, String reason})>[];

  static int _autoIncrement = 0;

  static String _defaultIdFactory() {
    _autoIncrement += 1;
    return 'session-${_autoIncrement.toString().padLeft(8, '0')}';
  }

  @override
  Future<String> recordLogin(AuthSessionLedgerLogin login) async {
    final id = _nextSessionId();
    logins.add(login);
    issuedSessionIds.add(id);
    return id;
  }

  @override
  Future<void> recordRefresh({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
  }) async {
    refreshCalls[sessionId] = (refreshCalls[sessionId] ?? 0) + 1;
  }

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    revokedSessions[sessionId] = reason;
  }

  @override
  Future<int> revokeAllSessionsForUser({
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    revokedAllForUser.add((userId: userId, reason: reason));
    // Mark every recorded login for this user as revoked too, so
    // tests asserting "are sessions revoked?" see consistent state.
    var revoked = 0;
    for (var i = 0; i < logins.length; i++) {
      if (logins[i].userId == userId) {
        final id = issuedSessionIds[i];
        if (!revokedSessions.containsKey(id)) {
          revokedSessions[id] = reason;
          revoked += 1;
        }
      }
    }
    return revoked;
  }
}
