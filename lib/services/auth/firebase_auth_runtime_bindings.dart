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
import 'package:flutter/widgets.dart';

import '../auth_login_service.dart';
import '../mfa/mfa_operations_gateway.dart';
import '../mfa/proxy_mfa_operations_gateway.dart';
import '../mfa/mfa_recovery_request_gateway.dart';
import '../mfa/proxy_mfa_recovery_request_gateway.dart';
import '../secure_session_storage.dart';
import 'account_info_gateway.dart';
import 'auth_operations_gateway.dart';
import 'auth_session_ledger_writer.dart';
import 'firebase_auth_client.dart';
import 'firebase_auth_client_sdk.dart';
import 'firebase_auth_login_service.dart';
import 'flutter_secure_storage_backend.dart';
import 'password_change_gateway.dart';
import 'platform_secure_session_storage.dart';
import 'proxy_account_info_gateway.dart';
import 'proxy_auth_session_ledger_writer.dart';
import 'proxy_auth_operations_gateway.dart';
import 'proxy_password_change_gateway.dart';
import 'proxy_permission_snapshot_loader.dart';
import 'proxy_refresh_token_revoker.dart';

class FirebaseAuthRuntimeBindings {
  const FirebaseAuthRuntimeBindings({
    required this.authLoginService,
    required this.secureSessionStorage,
    this.authSessionLedgerWriter,
    this.accountInfoGateway,
    this.permissionContextLoader,
    this.authOperationsGateway,
    this.passwordChangeGateway,
    this.mfaOperationsGateway,
    this.mfaRecoveryRequestGateway,
  });

  final AuthLoginService authLoginService;
  final SecureSessionStorage secureSessionStorage;

  /// Production [AuthSessionLedgerWriter] backed by the proxy
  /// `/v1/auth/session/*` endpoints. Null when the bootstrap did not
  /// supply a `proxyBaseUri`; the app falls back to the scaffold-failing
  /// default so a misconfigured deploy surfaces the gap.
  final AuthSessionLedgerWriter? authSessionLedgerWriter;

  final AccountInfoGateway? accountInfoGateway;
  final PermissionContextLoader? permissionContextLoader;
  final AuthOperationsGateway? authOperationsGateway;
  final PasswordChangeGateway? passwordChangeGateway;
  final MfaOperationsGateway? mfaOperationsGateway;
  final MfaRecoveryRequestGateway? mfaRecoveryRequestGateway;
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
  WidgetsFlutterBinding.ensureInitialized();
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }
  late final FirebaseAuthClient authClient;
  final RevokeAllRefreshTokens? effectiveRevokeAllRefreshTokens =
      revokeAllRefreshTokens ??
      (proxyBaseUri == null
          ? null
          : () {
              final revoker = ProxyRefreshTokenRevoker(
                proxyBaseUri: proxyBaseUri,
                idTokenProvider: authClient.currentIdToken,
                httpClient: DartIoProxyHttpJsonClient(),
              );
              return revoker.revokeAllRefreshTokens();
            });
  authClient = FirebaseAuthSdkClient(
    revokeAllRefreshTokens: effectiveRevokeAllRefreshTokens,
  );
  AuthSessionLedgerWriter? ledgerWriter;
  AccountInfoGateway? accountInfoGateway;
  PermissionContextLoader? permissionContextLoader;
  AuthOperationsGateway? authOperationsGateway;
  PasswordChangeGateway? passwordChangeGateway;
  MfaOperationsGateway? mfaOperationsGateway;
  MfaRecoveryRequestGateway? mfaRecoveryRequestGateway;
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
    permissionContextLoader = ProxyPermissionContextLoader(
      proxyBaseUri: proxyBaseUri,
      idTokenProvider: authClient.currentIdToken,
      httpClient: DartIoProxyPermissionSnapshotHttpClient(),
    );
    accountInfoGateway = ProxyAccountInfoGateway(
      proxyBaseUri: proxyBaseUri,
      idTokenProvider: authClient.currentIdToken,
      httpClient: DartIoProxyAuthOperationsHttpClient(),
    );
    authOperationsGateway = ProxyAuthOperationsGateway(
      proxyBaseUri: proxyBaseUri,
      idTokenProvider: authClient.currentIdToken,
      httpClient: DartIoProxyAuthOperationsHttpClient(),
    );
    passwordChangeGateway = ProxyPasswordChangeGateway(
      proxyBaseUri: proxyBaseUri,
      idTokenProvider: authClient.currentIdToken,
      httpClient: DartIoProxyAuthOperationsHttpClient(),
    );
    mfaOperationsGateway = ProxyMfaOperationsGateway(
      proxyBaseUri: proxyBaseUri,
      idTokenProvider: authClient.currentIdToken,
      httpClient: DartIoProxyAuthOperationsHttpClient(),
    );
    mfaRecoveryRequestGateway = ProxyMfaRecoveryRequestGateway(
      proxyBaseUri: proxyBaseUri,
      httpClient: DartIoProxyAuthOperationsHttpClient(),
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
    accountInfoGateway: accountInfoGateway,
    permissionContextLoader: permissionContextLoader,
    authOperationsGateway: authOperationsGateway,
    passwordChangeGateway: passwordChangeGateway,
    mfaOperationsGateway: mfaOperationsGateway,
    mfaRecoveryRequestGateway: mfaRecoveryRequestGateway,
  );
}
