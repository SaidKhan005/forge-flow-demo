// Phase 9 live-closeout - production Firebase auth bindings.
//
// Keeps SDK initialization and concrete adapters in one small module so app
// entrypoints can opt into real auth without importing Firebase packages
// throughout the UI.
//
// Phase 9 B6 (proxy session-ledger endpoint): when a [proxyBaseUri] is
// supplied to [createFirebaseAuthRuntimeBindings], the bindings build a
// [ProxyAuthSessionLedgerWriter] over `dart:io HttpClient` that the
// `AuthSessionNotifier` uses for `recordLogin` / `recordRefresh` /
// `revokeSession` / `revokeAllSessionsForUser`. Without [proxyBaseUri]
// the bindings expose `null` so the bootstrap can fall back to the
// scaffold-failing default (matches the pre-B6 behavior).

import 'package:firebase_core/firebase_core.dart';

import '../auth_login_service.dart';
import '../secure_session_storage.dart';
import 'auth_session_ledger_writer.dart';
import 'firebase_auth_client.dart';
import 'firebase_auth_client_sdk.dart';
import 'firebase_auth_login_service.dart';
import 'flutter_secure_storage_backend.dart';
import 'platform_secure_session_storage.dart';
import 'proxy_auth_session_ledger_writer.dart';

class FirebaseAuthRuntimeBindings {
  const FirebaseAuthRuntimeBindings({
    required this.authLoginService,
    required this.secureSessionStorage,
    this.authSessionLedgerWriter,
  });

  final AuthLoginService authLoginService;
  final SecureSessionStorage secureSessionStorage;

  /// Production [AuthSessionLedgerWriter] backed by the proxy
  /// `/v1/auth/session/*` endpoints. Null when the bootstrap did not
  /// supply a `proxyBaseUri`; the app falls back to the scaffold-failing
  /// default so a misconfigured deploy surfaces the gap.
  final AuthSessionLedgerWriter? authSessionLedgerWriter;
}

/// Initializes Firebase using the native Android/iOS config files and returns
/// the production auth + secure-storage bindings.
///
/// When [proxyBaseUri] is supplied, the bindings also build a
/// [ProxyAuthSessionLedgerWriter] that the bootstrap can pass into the
/// [AuthSessionNotifier] so in-app sign-in records `auth_sessions` rows
/// without direct Postgres access.
///
/// Web support will need a Dart `FirebaseOptions` binding before browser
/// launch; the current operator app closeout is mobile-first.
Future<FirebaseAuthRuntimeBindings> createFirebaseAuthRuntimeBindings({
  AuthLocationResolver locationResolver =
      const ScaffoldFailingAuthLocationResolver(),
  RevokeAllRefreshTokens? revokeAllRefreshTokens,
  Uri? proxyBaseUri,
}) async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }
  final FirebaseAuthClient authClient = FirebaseAuthSdkClient(
    revokeAllRefreshTokens: revokeAllRefreshTokens,
  );
  AuthSessionLedgerWriter? ledgerWriter;
  if (proxyBaseUri != null) {
    ledgerWriter = ProxyAuthSessionLedgerWriter(
      proxyBaseUri: proxyBaseUri,
      // The Firebase Auth SDK auto-refreshes the cached ID token when
      // it nears expiry, so reading it on every ledger call is cheap.
      // The token NEVER leaves the writer's request header path; it
      // is not echoed by `toString()` or any debug print.
      idTokenProvider: authClient.currentIdToken,
      httpClient: DartIoProxyHttpJsonClient(),
    );
  }
  return FirebaseAuthRuntimeBindings(
    authLoginService: FirebaseAuthLoginService(
      client: authClient,
      locationResolver: locationResolver,
    ),
    secureSessionStorage: PlatformSecureSessionStorage(
      backend: const FlutterSecureStorageBackend(),
    ),
    authSessionLedgerWriter: ledgerWriter,
  );
}
