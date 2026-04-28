// Phase 9.3 - Secure session storage seam.
//
// Persists [AuthSession] across app restarts. The interface is the
// only contract callers know about; production binds
// `flutter_secure_storage` (Keychain on iOS / Android Keystore on
// Android), tests use [InMemorySecureSessionStorage], and the
// scaffold default fails closed so a misconfigured production deploy
// surfaces a "no session storage wired" error rather than silently
// dropping persistence.
//
// Audit-fix 2026-04-27 (Codex F1): the persisted shape is now an
// envelope ([StoredAuthSession]) that carries the `auth_sessions`
// row id alongside the [AuthSession]. Before this change the row id
// lived only in the notifier's in-memory `_activeSessionId`, so
// after a cold-start `rehydrate()` restored the session but the id
// was lost — `refreshSession` and `signOutThisSession` then silently
// skipped their ledger calls because they had no id to address.
// The envelope keeps the rehydrated notifier in sync with Postgres.

import 'dart:convert';

import '../auth/auth_session.dart';

/// Persisted session envelope: the [AuthSession] (identity / token /
/// expiry) plus the `auth_sessions.session_id` (Postgres ledger row
/// id) so cold-start rehydrate can address the same ledger row.
///
/// The two fields are intentionally separate value classes:
///   * [AuthSession] is the JWT-derived identity. It is shared with
///     the proxy verifier seam and other auth-aware components that
///     have no business knowing about the Postgres ledger row id.
///   * [authSessionId] is server-side bookkeeping. It is meaningful
///     to [AuthSessionLedgerWriter] and nothing else.
///
/// Mixing them in one value class would either leak the ledger id
/// into the proxy verifier path or force callers that only care about
/// identity to deal with an irrelevant nullable. Envelope keeps the
/// concerns separate while still being one round-trip through storage.
class StoredAuthSession {
  const StoredAuthSession({required this.session, this.authSessionId});

  /// JWT-derived identity (user / operator / location / roles / token).
  final AuthSession session;

  /// `auth_sessions.session_id` for this session. Null only when:
  ///   * the persisted blob predates the envelope (legacy bare-AuthSession
  ///     shape — see [SecureSessionStorage.readEnvelope] for the
  ///     backwards-compat fallback), or
  ///   * the test/dev caller wrote a session via [writeSession] without
  ///     an id (legacy convenience method).
  ///
  /// Production sign-in always writes a non-null id because the ledger
  /// `recordLogin` happens before persistence and the returned id
  /// rides through to [SecureSessionStorage.writeEnvelope].
  final String? authSessionId;

  static const String _envelopeShapeKey = 'session';
  static const String _ledgerIdKey = 'auth_session_id';

  /// JSON shape:
  /// `{ "auth_session_id": "<uuid|null>", "session": { ...AuthSession } }`.
  /// The inner `session` key is what [readEnvelope] looks for to
  /// distinguish envelope shape from legacy bare-AuthSession shape.
  Map<String, Object?> toJson() => <String, Object?>{
    _envelopeShapeKey: session.toJson(),
    _ledgerIdKey: authSessionId,
  };

  static StoredAuthSession fromJson(Map<String, Object?> json) {
    final inner = json[_envelopeShapeKey];
    if (inner is! Map) {
      throw const FormatException(
        'StoredAuthSession.session is missing or wrong type',
      );
    }
    return StoredAuthSession(
      session: AuthSession.fromJson(Map<String, Object?>.from(inner)),
      authSessionId: json[_ledgerIdKey] as String?,
    );
  }
}

/// Read/write/clear of the persisted session blob.
abstract class SecureSessionStorage {
  /// Returns the persisted session JSON, or null if none.
  Future<String?> readSessionJson();

  /// Writes the session JSON. Implementations MUST use platform
  /// secure storage (Keychain / Android Keystore) in production.
  Future<void> writeSessionJson(String json);

  /// Clears any persisted session.
  Future<void> clear();

  /// Reads the persisted session envelope (identity + ledger id).
  /// Returns null when nothing is persisted.
  ///
  /// Backwards compat: if the persisted JSON is the legacy bare-AuthSession
  /// shape (predates 2026-04-27 envelope), the session is loaded with
  /// `authSessionId: null`. The user stays signed in across the upgrade,
  /// but `refreshSession` / `signOutThisSession` skip their ledger calls
  /// until the next fresh sign-in re-establishes the row in the new
  /// envelope shape.
  Future<StoredAuthSession?> readEnvelope() async {
    final raw = await readSessionJson();
    if (raw == null || raw.isEmpty) return null;
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    final map = Map<String, Object?>.from(decoded);
    if (map.containsKey(StoredAuthSession._envelopeShapeKey)) {
      return StoredAuthSession.fromJson(map);
    }
    // Legacy bare-AuthSession shape — predates the envelope. Hydrate
    // without a ledger id; the next fresh sign-in re-establishes
    // persistence in the new shape. We deliberately do NOT clear the
    // legacy blob here so the user stays signed in across the upgrade.
    return StoredAuthSession(
      session: AuthSession.fromJson(map),
      authSessionId: null,
    );
  }

  /// Writes the session envelope. Use this whenever the
  /// `auth_sessions.session_id` is known (production sign-in /
  /// refresh paths) so cold-start rehydrate can address the same
  /// ledger row.
  Future<void> writeEnvelope(StoredAuthSession envelope) async {
    await writeSessionJson(jsonEncode(envelope.toJson()));
  }

  /// Convenience: load + decode just the [AuthSession] for callers
  /// that don't need the ledger id (legacy / test paths). Prefer
  /// [readEnvelope] in production code.
  Future<AuthSession?> readSession() async {
    final env = await readEnvelope();
    return env?.session;
  }

  /// Convenience: encode + store a bare session with no ledger id.
  /// Use [writeEnvelope] in production code so the ledger id persists
  /// across cold starts. This method is preserved for the existing
  /// test fixture surface (writes the new envelope shape with
  /// `authSessionId: null`).
  Future<void> writeSession(AuthSession session) async {
    await writeEnvelope(StoredAuthSession(session: session));
  }
}

/// In-memory storage for tests + previewer harnesses. Holds the
/// session blob in process memory only; cleared on construction.
class InMemorySecureSessionStorage extends SecureSessionStorage {
  String? _sessionJson;

  @override
  Future<String?> readSessionJson() async => _sessionJson;

  @override
  Future<void> writeSessionJson(String json) async {
    _sessionJson = json;
  }

  @override
  Future<void> clear() async {
    _sessionJson = null;
  }
}

/// Hard-fail-closed default. Every method throws so production
/// deploys that forget to wire the platform-secure backend get a
/// clear startup error instead of silently dropping persistence
/// (which would force the user to log in on every cold start).
class ScaffoldFailingSecureSessionStorage extends SecureSessionStorage {
  ScaffoldFailingSecureSessionStorage();

  @override
  Future<String?> readSessionJson() async {
    throw StateError(_message);
  }

  @override
  Future<void> writeSessionJson(String json) async {
    throw StateError(_message);
  }

  @override
  Future<void> clear() async {
    throw StateError(_message);
  }

  static const String _message =
      '9.3 scaffold: real SecureSessionStorage is not wired — bind '
      '`flutter_secure_storage` (Keychain / Android Keystore) in the '
      'app bootstrap before serving authenticated traffic.';
}
