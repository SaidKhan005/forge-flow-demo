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
//
// ops-debt.mobile-push-gating (P0 day-1 launch-blocker): the mobile push
// token gateway is now feature-flagged behind
// `MOBILE_PUSH_NOTIFICATIONS_ENABLED` (defaults to `false`). Until the
// `202605060000_mobile_push_notifications.sql` migration is staging-applied
// and the flag is flipped to `true` on the proxy + ForgeFlow Cloud Run
// revisions, mobile clients receive the [NoopMobilePushTokenGateway] and
// no token-register POSTs flow to the proxy (so the proxy cannot 500 on
// a missing `mobile_push_tokens` table). See
// `runbooks/phase_9_production1_migration_apply_runbook.md` for the
// post-apply flag-flip step.

import 'dart:developer' as developer;

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';

import '../auth_login_service.dart';
import '../mfa/mfa_operations_gateway.dart';
import '../mfa/proxy_mfa_operations_gateway.dart';
import '../mfa/mfa_recovery_request_gateway.dart';
import '../mfa/proxy_mfa_recovery_request_gateway.dart';
import '../mobile_push/mobile_push_notification_service.dart';
import '../secure_session_storage.dart';
import 'account_info_gateway.dart';
import 'auth_operations_gateway.dart';
import 'auth_session_ledger_writer.dart';
import 'firebase_auth_client.dart';
import 'firebase_auth_client_sdk.dart';
import 'firebase_auth_login_service.dart';
import 'flutter_secure_storage_backend.dart';
import 'handoff_code_client.dart';
import 'handoff_code_gateway.dart';
import 'password_change_gateway.dart';
import 'password_reset_deep_link_source.dart';
import 'password_reset_gateway.dart';
import 'platform_secure_session_storage.dart';
import 'proxy_account_info_gateway.dart';
import 'proxy_auth_session_ledger_writer.dart';
import 'proxy_auth_operations_gateway.dart';
import 'proxy_password_change_gateway.dart';
import 'proxy_password_reset_gateway.dart';
import 'proxy_permission_snapshot_loader.dart';
import 'proxy_refresh_token_revoker.dart';
import 'timeout_firebase_auth_client.dart';

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
    this.passwordResetGateway,
    this.passwordResetDeepLinkSource,
    this.mobilePushTokenGateway,
    this.handoffCodeGateway,
    this.idTokenProvider,
    this.forceRefreshIdToken,
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
  final PasswordResetGateway? passwordResetGateway;
  final MobilePushTokenGateway? mobilePushTokenGateway;
  final HandoffCodeGateway? handoffCodeGateway;
  final Future<String?> Function()? idTokenProvider;

  /// MOB-G70 — production force-refresh hook for the Firebase ID
  /// token. [idTokenProvider] returns the SDK's *cached* token (cheap
  /// hot path, auto-refreshed only when it nears expiry), which is the
  /// wrong thing to re-pull on a 401: a clock-skewed device or a
  /// mid-sweep token rotation surfaces as a 401 with a still-cached
  /// stale token, so reading the cache again would loop on the same
  /// stale value. This hook calls `FirebaseAuthClient.refreshIdToken`
  /// (SDK `getIdTokenResult(forceRefresh: true)`), so the bootstrap
  /// can hand the production [HttpSyncProxyClient] a real
  /// force-refresh path. The existing 401-refresh-and-retry in
  /// `http_sync_proxy_client.dart` was previously dead in the prod
  /// flavor because this argument was never wired. Null on the demo /
  /// no-Firebase path (there is no proxy there, so no refresher is
  /// needed).
  final Future<void> Function()? forceRefreshIdToken;

  /// 9.UX.7 — incoming-URI source forwarded to the unauthenticated
  /// shell so `forgeflow://reset-password?oobCode=...` reaches the
  /// in-app confirm screen. The bootstrap must call
  /// [WidgetsBindingPasswordResetDeepLinkSource.startListening]
  /// before binding so the platform navigation channel is observed.
  final PasswordResetDeepLinkSource? passwordResetDeepLinkSource;
}

/// ops-debt.mobile-push-gating — compile-time feature flag (via
/// `--dart-define=MOBILE_PUSH_NOTIFICATIONS_ENABLED=true`) that gates
/// the production [ProxyMobilePushTokenGateway] wiring.
///
/// Defaults to `false`. While `false`, [buildMobilePushTokenGateway]
/// returns a [NoopMobilePushTokenGateway] so mobile clients can keep
/// asking for FCM tokens without any POSTs flowing to the proxy
/// `/v1/auth/mobile/push-token/register` route. This protects the
/// production proxy from 500-ing on a missing `mobile_push_tokens`
/// table when the migration has not yet been staging-applied.
///
/// Ops flips this to `true` on the proxy + ForgeFlow Cloud Run
/// revisions (mobile builds re-cut with the dart-define) AFTER
/// `db/migrations/202605060000_mobile_push_notifications.sql` is
/// applied to staging and Production1.
const bool kMobilePushNotificationsEnabled = bool.fromEnvironment(
  'MOBILE_PUSH_NOTIFICATIONS_ENABLED',
);

/// Builds the [MobilePushTokenGateway] used by the mobile auth
/// bindings, gated by [kMobilePushNotificationsEnabled].
///
/// - When [enabled] is `false` (default), returns a
///   [NoopMobilePushTokenGateway] so the mobile client never POSTs to
///   the proxy and a single startup line is logged.
/// - When [enabled] is `true` and [proxyBaseUri] is non-null, returns
///   a [ProxyMobilePushTokenGateway] wired against the proxy.
/// - When [enabled] is `true` but [proxyBaseUri] is null (demo / no
///   proxy), returns `null` to match the pre-flag behavior of the
///   bindings — the coordinator simply has no gateway to call.
///
/// [logger] is injected for tests; production uses `dart:developer.log`.
MobilePushTokenGateway? buildMobilePushTokenGateway({
  required Uri? proxyBaseUri,
  required Future<String?> Function() idTokenProvider,
  bool enabled = kMobilePushNotificationsEnabled,
  void Function(String message)? logger,
}) {
  if (!enabled) {
    final emit =
        logger ??
        (String message) =>
            developer.log(message, name: 'forge_flow.mobile_push');
    emit('mobile_push: feature disabled, tokens not persisted');
    return const NoopMobilePushTokenGateway();
  }
  if (proxyBaseUri == null) {
    return null;
  }
  return ProxyMobilePushTokenGateway(
    proxyBaseUri: proxyBaseUri,
    idTokenProvider: idTokenProvider,
    httpClient: DartIoProxyHttpJsonClient(),
  );
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
  authClient = TimeoutFirebaseAuthClient(
    delegate: FirebaseAuthSdkClient(
      revokeAllRefreshTokens: effectiveRevokeAllRefreshTokens,
    ),
  );
  AuthSessionLedgerWriter? ledgerWriter;
  AccountInfoGateway? accountInfoGateway;
  PermissionContextLoader? permissionContextLoader;
  AuthOperationsGateway? authOperationsGateway;
  PasswordChangeGateway? passwordChangeGateway;
  MfaOperationsGateway? mfaOperationsGateway;
  MfaRecoveryRequestGateway? mfaRecoveryRequestGateway;
  PasswordResetGateway? passwordResetGateway;
  HandoffCodeGateway? handoffCodeGateway;
  // ops-debt.mobile-push-gating: build through the gated factory so a
  // production phone never POSTs to `/v1/auth/mobile/push-token/register`
  // until the migration is applied and `MOBILE_PUSH_NOTIFICATIONS_ENABLED`
  // is flipped to `true`.
  final MobilePushTokenGateway? mobilePushTokenGateway =
      buildMobilePushTokenGateway(
        proxyBaseUri: proxyBaseUri,
        idTokenProvider: authClient.currentIdToken,
      );
  if (proxyBaseUri != null) {
    handoffCodeGateway = ProxyHandoffCodeGateway(
      client: HandoffCodeClient(
        proxyBaseUri: proxyBaseUri,
        idTokenProvider: authClient.currentIdToken,
        httpClient: DartIoProxyAuthOperationsHttpClient(),
      ),
    );
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
    // Phase 9.UX.7: self-serve password-reset request + confirm.
    // Both routes are unauthenticated (the operator is not signed in
    // when they tap "Forgot password?" or open the action-link
    // deep-link), so the gateway does not take an idTokenProvider.
    passwordResetGateway = ProxyPasswordResetGateway(
      proxyBaseUri: proxyBaseUri,
      httpClient: DartIoProxyAuthOperationsHttpClient(),
    );
  }
  // Phase 9.UX.7: bind the deep-link source for both demo and live
  // builds so `forgeflow://reset-password?oobCode=...` lands on the
  // in-app confirm screen. The handler is inert (renders the login
  // shell as today) when the gateway is null, so demo builds don't
  // accidentally route into a scaffold-failing reset.
  final deepLinkSource = WidgetsBindingPasswordResetDeepLinkSource()
    ..startListening();
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
    passwordResetGateway: passwordResetGateway,
    passwordResetDeepLinkSource: deepLinkSource,
    mobilePushTokenGateway: mobilePushTokenGateway,
    handoffCodeGateway: handoffCodeGateway,
    idTokenProvider: authClient.currentIdToken,
    // MOB-G70 — force a real Firebase ID-token refresh (SDK
    // `getIdTokenResult(forceRefresh: true)` via
    // `FirebaseAuthSdkClient.refreshIdToken`). The proxy 401 retry
    // path only needs the side effect (cache now holds a fresh
    // token); the returned credential is discarded here so the hook
    // matches the `Future<void> Function()` the sync client expects.
    // The token NEVER leaves the SDK/header path.
    forceRefreshIdToken: () async {
      await authClient.refreshIdToken();
    },
  );
}
