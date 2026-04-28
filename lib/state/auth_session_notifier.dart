// Phase 9.3 - Auth session notifier.
//
// Holds the current [AuthSession] for both Forge & Flow and Barrio
// shells. Backed by:
//   - [AuthLoginService]   — performs sign-in / sign-out / refresh.
//   - [SecureSessionStorage] — persists the session across cold
//                              starts (Keychain / Android Keystore
//                              in production; in-memory in tests).
//   - [AuthSessionLedgerWriter] — writes to the Postgres
//                                 `auth_sessions` ledger so login /
//                                 refresh / logout activity is
//                                 auditable per the 9.0 schema.
//   - clock injection      — every freshness / expiry decision
//                              reads through `now()` so tests can
//                              pin time.
//
// The notifier is intentionally narrow:
//
//   - `state` exposes the current authentication phase (loading /
//     unauthenticated / mfa-challenge / authenticated / error).
//   - `requireFreshAuth` returns the current session when step-up
//     freshness still holds; otherwise asks the caller to re-prompt.
//   - `signIn` / `completeMfa` / `signOut` flow through the service
//     and trigger persistence + ledger writes.
//
// Permission resolution against the role catalog (Phase 9.6) is
// not part of this notifier — it lives in 9.6/9.7 once the runtime
// resolver lands. 9.3 only carries the role list straight from the
// JWT claims.

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import '../auth/auth_session.dart';
import '../services/auth_login_service.dart';
import '../services/auth/auth_session_ledger_writer.dart';
import '../services/secure_session_storage.dart';

/// High-level state of the auth flow. The UI selects the shell
/// (login screen vs. authenticated app) by switching on this value.
sealed class AuthSessionState {
  const AuthSessionState();
}

class AuthSessionLoading extends AuthSessionState {
  const AuthSessionLoading();
}

class AuthSessionUnauthenticated extends AuthSessionState {
  const AuthSessionUnauthenticated({this.lastErrorCode, this.lastErrorMessage});

  final String? lastErrorCode;
  final String? lastErrorMessage;
}

class AuthSessionMfaChallenge extends AuthSessionState {
  const AuthSessionMfaChallenge({
    required this.email,
    required this.mfaSessionToken,
    required this.factorIds,
  });

  final String email;
  final String mfaSessionToken;
  final List<String> factorIds;
}

class AuthSessionAuthenticated extends AuthSessionState {
  const AuthSessionAuthenticated(this.session);

  final AuthSession session;
}

class AuthSessionNotifier extends ChangeNotifier {
  AuthSessionNotifier({
    required AuthLoginService loginService,
    required SecureSessionStorage storage,
    AuthSessionLedgerWriter? ledgerWriter,
    DateTime Function()? now,
    Duration freshnessWindow = const Duration(minutes: 5),
    AuthSessionLedgerContext Function()? ledgerContextFactory,
  }) : _loginService = loginService,
       _storage = storage,
       // 9.3 backwards-compatibility: the ledger writer is optional
       // so existing tests that build the notifier with the two
       // required args keep working. Production bootstrap injects
       // either the scaffold-failing default (fail-closed) or the
       // RepositoryAuthSessionLedgerWriter once the Postgres pool
       // is wired.
       _ledgerWriter =
           ledgerWriter ?? InMemoryAuthSessionLedgerWriter(),
       _now = now ?? DateTime.now,
       _freshnessWindow = freshnessWindow,
       _ledgerContextFactory =
           ledgerContextFactory ?? _defaultLedgerContextFactory,
       _state = const AuthSessionLoading();

  final AuthLoginService _loginService;
  final SecureSessionStorage _storage;
  final AuthSessionLedgerWriter _ledgerWriter;
  final DateTime Function() _now;
  final Duration _freshnessWindow;
  final AuthSessionLedgerContext Function() _ledgerContextFactory;

  AuthSessionState _state;
  AuthSessionState get state => _state;

  /// `auth_sessions.session_id` for the active session, set after
  /// [recordLogin] succeeds and cleared on sign-out. Null when no
  /// session is active OR when the ledger writer rejected the row
  /// (in which case sign-out cannot revoke a row that was never
  /// written).
  ///
  /// Audit-fix 2026-04-27 (Codex F1): also restored from storage on
  /// [rehydrate] via the [StoredAuthSession] envelope, so cold-start
  /// refresh / sign-out address the original `auth_sessions` row
  /// instead of silently skipping the ledger call.
  String? _activeSessionId;

  /// Public accessor for diagnostics + tests. The session_id stays
  /// out of any debug print path; only callers that explicitly
  /// reference it see the value.
  String? get activeSessionId => _activeSessionId;

  /// Convenience: returns the live session, or null when the state
  /// is anything other than [AuthSessionAuthenticated].
  AuthSession? get session {
    final s = _state;
    if (s is AuthSessionAuthenticated) return s.session;
    return null;
  }

  /// Loads the persisted session (if any) and transitions to the
  /// matching state. Call this from the app bootstrap before
  /// rendering the first frame.
  ///
  /// Audit-fix 2026-04-27 (Codex F1): reads the persisted envelope
  /// via [SecureSessionStorage.readEnvelope] so the
  /// `auth_sessions.session_id` is restored alongside the
  /// [AuthSession]. Without this, post-rehydrate `refreshSession`
  /// and `signOutThisSession` had no id to forward to the ledger
  /// writer and silently skipped their writes.
  Future<void> rehydrate() async {
    StoredAuthSession? loaded;
    try {
      loaded = await _storage.readEnvelope();
    } on StateError catch (error) {
      // Scaffold storage is wired; treat as "no persistence" for now.
      // The error message stays in process logs, never in the UI.
      debugPrint('AuthSessionNotifier.rehydrate storage error: ${error.message}');
      loaded = null;
    } catch (_) {
      loaded = null;
    }
    if (loaded == null) {
      _activeSessionId = null;
      _setState(const AuthSessionUnauthenticated());
      return;
    }
    if (!loaded.session.isLive(now: _now())) {
      try {
        await _storage.clear();
      } catch (_) {
        /* ignore */
      }
      _activeSessionId = null;
      _setState(const AuthSessionUnauthenticated());
      return;
    }
    // Restore both the in-memory ledger id (may be null for legacy
    // bare-AuthSession blobs predating the envelope) and the
    // authenticated state. With the id restored, refresh / sign-out
    // can address the original `auth_sessions` row.
    _activeSessionId = loaded.authSessionId;
    _setState(AuthSessionAuthenticated(loaded.session));
  }

  /// Drives the email/password login flow. On success transitions
  /// to authenticated; on MFA required transitions to mfa-challenge;
  /// on failure transitions to unauthenticated with error metadata.
  ///
  /// Audit-fix 2026-04-27: the returned [AuthLoginResult] is the
  /// **effective** result after side-effects, not the raw value
  /// from the login service. If the auth_sessions ledger write
  /// fails-closed (see [_applyResult]), this returns
  /// `AuthLoginFailure(code: 'ledger_unavailable', ...)` so the UI
  /// stays consistent with the notifier state.
  Future<AuthLoginResult> signInWithEmailPassword({
    required String email,
    required String password,
  }) async {
    final result = await _loginService.signInWithEmailPassword(
      email: email,
      password: password,
    );
    return _applyResult(result, emailForMfa: email);
  }

  /// Completes a TOTP challenge from the [AuthSessionMfaChallenge]
  /// state. Same outcome semantics as [signInWithEmailPassword],
  /// including the audit-fix fail-closed behavior on ledger errors.
  Future<AuthLoginResult> completeTotpChallenge({
    required String factorId,
    required String oneTimeCode,
  }) async {
    final s = _state;
    if (s is! AuthSessionMfaChallenge) {
      throw StateError(
        'completeTotpChallenge requires AuthSessionMfaChallenge state',
      );
    }
    final result = await _loginService.completeTotpChallenge(
      mfaSessionToken: s.mfaSessionToken,
      factorId: factorId,
      oneTimeCode: oneTimeCode,
    );
    return _applyResult(result, emailForMfa: s.email);
  }

  Future<AuthLoginResult> _applyResult(
    AuthLoginResult result, {
    required String emailForMfa,
  }) async {
    if (result is AuthLoginSuccess) {
      // Audit-fix 2026-04-27 (Codex F1+F2): side-effect order is
      //   1. ledger.recordLogin → returns auth_sessions.session_id
      //   2. storage.writeEnvelope(session, session_id) → persisted
      //      shape carries the id so cold-start rehydrate restores it
      //   3. enter AuthSessionAuthenticated
      //
      // F2 (reorder): persistence MUST come after the ledger so a
      // ledger failure can never leave a persisted session orphaned
      // from its `auth_sessions` row. Before this change, storage was
      // written first and a ledger failure relied on a best-effort
      // `storage.clear()` that could itself fail — leaving a
      // persisted session with no ledger row.
      //
      // F1 (envelope): persistence MUST carry the issued session_id
      // so rehydrate can restore `_activeSessionId`. Otherwise refresh
      // / sign-out post-cold-start silently skip their ledger writes.
      //
      // Failure posture:
      //   * Ledger fails → fail closed; storage is never written;
      //     UI gets a calm `ledger_unavailable` failure.
      //   * Storage fails AFTER ledger succeeds → in-memory
      //     authenticated, log + continue. Persistent login won't
      //     survive this one cold restart, but the user can use the
      //     app for now (matches existing storage-error tolerance in
      //     [rehydrate] and [refreshSession]). The orphan window is
      //     bounded by the user re-signing-in; the dormancy sweep
      //     (~30 day cutoff) reaps the row if they don't.
      //   * Low-friction UX is preserved on the success path: when
      //     ledger + storage are both wired correctly, neither
      //     failure branch fires and the user sees no extra prompt.
      String issuedSessionId;
      try {
        final hash = _idTokenHashOf(result.session);
        issuedSessionId = await _ledgerWriter.recordLogin(
          AuthSessionLedgerLogin(
            userId: result.session.userId,
            operatorId: result.session.operatorId,
            locationId: result.session.locationId,
            tokenHash: hash,
            context: _ledgerContextFactory(),
          ),
        );
      } catch (error) {
        debugPrint('AuthSessionNotifier.signIn ledger error: $error');
        _activeSessionId = null;
        // Defensive: a stale legacy blob from a prior install could
        // still sit in storage even though F2 means we never wrote
        // one this turn. Clear it so a relaunch doesn't resurrect a
        // session that has no ledger row.
        try {
          await _storage.clear();
        } catch (_) {
          /* ignore — best-effort cleanup */
        }
        const String ledgerFailureCode = 'ledger_unavailable';
        const String ledgerFailureMessage =
            'Sign-in could not be recorded. Please try again in a '
            'moment.';
        _setState(
          const AuthSessionUnauthenticated(
            lastErrorCode: ledgerFailureCode,
            lastErrorMessage: ledgerFailureMessage,
          ),
        );
        return const AuthLoginFailure(
          code: ledgerFailureCode,
          message: ledgerFailureMessage,
        );
      }
      // Ledger row is written; remember the id and persist the
      // envelope. From here on, storage failures are non-fatal — the
      // ledger row already exists and the in-memory session keeps the
      // user productive for this launch.
      _activeSessionId = issuedSessionId;
      try {
        await _storage.writeEnvelope(
          StoredAuthSession(
            session: result.session,
            authSessionId: issuedSessionId,
          ),
        );
      } catch (error) {
        debugPrint('AuthSessionNotifier.signIn storage error: $error');
      }
      _setState(AuthSessionAuthenticated(result.session));
      return result;
    } else if (result is AuthLoginMfaRequired) {
      _setState(
        AuthSessionMfaChallenge(
          email: emailForMfa,
          mfaSessionToken: result.mfaSessionToken,
          factorIds: result.factorIds,
        ),
      );
      return result;
    } else if (result is AuthLoginFailure) {
      _setState(
        AuthSessionUnauthenticated(
          lastErrorCode: result.code,
          lastErrorMessage: result.message,
        ),
      );
      return result;
    }
    return result;
  }

  /// Returns the live session iff it is authenticated AND the
  /// [auth_time]-derived freshness is still within the configured
  /// window. Otherwise returns null and the caller must re-prompt
  /// (sensitive ops gate). Does NOT mutate state — the prompt UI
  /// itself decides whether to call [signInWithEmailPassword] again.
  AuthSession? requireFreshAuth() {
    final live = session;
    if (live == null) return null;
    if (!live.isAuthFresh(now: _now(), window: _freshnessWindow)) {
      return null;
    }
    return live;
  }

  /// True iff the session is authenticated and the configured
  /// freshness window still holds.
  bool get isAuthFresh => requireFreshAuth() != null;

  /// Refreshes the live session via the login service and, on
  /// success, updates `auth_sessions.last_seen_at` for the active
  /// session_id. No-op when the notifier is not in the authenticated
  /// state. Returns the updated session, or null when the refresh
  /// failed (caller should trigger a sign-out flow).
  ///
  /// Audit-fix 2026-04-27 — refresh ledger posture: ledger errors on
  /// refresh are intentionally **logged but not fatal**. `last_seen_at`
  /// is a freshness-tracking field used by dormancy sweeps; a
  /// transient ledger blip on refresh shouldn't punish the user with
  /// a forced sign-out. The next refresh (or login) will re-establish
  /// a row. Sign-in fail-closed is enough to guarantee no row goes
  /// missing in the absorbing direction.
  Future<AuthSession?> refreshSession() async {
    final live = session;
    if (live == null) return null;
    final refreshed = await _loginService.refreshSession(live);
    if (refreshed == null) return null;
    final activeId = _activeSessionId;
    // Audit-fix 2026-04-27 (Codex F1): write the envelope (not a bare
    // session) so the persisted shape keeps the ledger id across
    // refreshes. `activeId` may be null only on the legacy bare-blob
    // upgrade path — `writeEnvelope` accepts null and the envelope
    // stays self-consistent (no ledger calls fire below either).
    try {
      await _storage.writeEnvelope(
        StoredAuthSession(session: refreshed, authSessionId: activeId),
      );
    } catch (error) {
      debugPrint('AuthSessionNotifier.refresh storage error: $error');
    }
    if (activeId != null) {
      try {
        await _ledgerWriter.recordRefresh(
          sessionId: activeId,
          userId: refreshed.userId,
          operatorId: refreshed.operatorId,
          locationId: refreshed.locationId,
        );
      } catch (error) {
        // Intentional log-and-continue per audit-fix decision above.
        debugPrint('AuthSessionNotifier.refresh ledger error: $error');
      }
    }
    _setState(AuthSessionAuthenticated(refreshed));
    return refreshed;
  }

  /// Signs out the current device only. Other sessions persist.
  ///
  /// Audit-fix 2026-04-27 — logout ledger posture: ledger errors on
  /// sign-out are intentionally **logged but not fatal** so the local
  /// security primitive (clearing the session) always succeeds. The
  /// admin "force-logout-all" path is the audit-grade fallback when
  /// a user-driven logout cannot reach the ledger.
  Future<void> signOutThisSession() async {
    final live = session;
    final activeId = _activeSessionId;
    try {
      await _loginService.signOutThisSession();
    } catch (error) {
      debugPrint('AuthSessionNotifier.signOutThisSession error: $error');
    }
    if (live != null && activeId != null) {
      try {
        await _ledgerWriter.revokeSession(
          sessionId: activeId,
          userId: live.userId,
          operatorId: live.operatorId,
          locationId: live.locationId,
          reason: 'user_signed_out_this_session',
        );
      } catch (error) {
        debugPrint('AuthSessionNotifier.signOutThisSession ledger error: $error');
      }
    }
    _activeSessionId = null;
    try {
      await _storage.clear();
    } catch (_) {
      /* ignore */
    }
    _setState(const AuthSessionUnauthenticated());
  }

  /// Server-side revoke of every refresh token for the user; this
  /// device is signed out as a side effect.
  Future<void> signOutAllSessions() async {
    final live = session;
    try {
      await _loginService.signOutAllSessions();
    } catch (error) {
      debugPrint('AuthSessionNotifier.signOutAllSessions error: $error');
    }
    if (live != null) {
      try {
        await _ledgerWriter.revokeAllSessionsForUser(
          userId: live.userId,
          operatorId: live.operatorId,
          locationId: live.locationId,
          reason: 'user_signed_out_all_sessions',
        );
      } catch (error) {
        debugPrint('AuthSessionNotifier.signOutAllSessions ledger error: $error');
      }
    }
    _activeSessionId = null;
    try {
      await _storage.clear();
    } catch (_) {
      /* ignore */
    }
    _setState(const AuthSessionUnauthenticated());
  }

  void _setState(AuthSessionState next) {
    if (identical(next, _state)) return;
    _state = next;
    notifyListeners();
  }

  /// SHA-256 hex digest of [session.firebaseIdToken]. Used as the
  /// `auth_sessions.token_hash` value at login time. The raw token
  /// NEVER leaves the value class; the hash identifies the row in
  /// audit views and lets refresh / revoke calls address the same
  /// session.
  ///
  /// Honest contract: this is the **ID-token** hash. The `firebase_auth`
  /// SDK does not expose the underlying refresh token, so the writer
  /// cannot detect refresh-token reuse on its own today. A future
  /// slice can land a true refresh-token hash in the same column
  /// without breaking this seam.
  static String _idTokenHashOf(AuthSession session) {
    final bytes = utf8.encode(session.firebaseIdToken);
    return crypto.sha256.convert(bytes).toString();
  }

  static AuthSessionLedgerContext _defaultLedgerContextFactory() {
    // The client cannot see its own egress IP / geo without a
    // server round-trip. Production bootstrap overrides this
    // factory once the proxy / observability stack is wired (the
    // proxy injects the resolved values via response header so the
    // notifier can carry them on the next ledger call). Defaulting
    // to empty keeps the rows clean rather than carrying spoofable
    // client-side guesses.
    return AuthSessionLedgerContext.empty;
  }

  @visibleForTesting
  void debugSetSession(AuthSession session) {
    _setState(AuthSessionAuthenticated(session));
  }

  @visibleForTesting
  void debugSetState(AuthSessionState state) {
    _setState(state);
  }

  @visibleForTesting
  void debugSetActiveSessionId(String? sessionId) {
    _activeSessionId = sessionId;
  }
}
