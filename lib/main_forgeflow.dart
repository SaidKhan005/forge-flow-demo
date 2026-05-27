import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'forge_flow_app.dart';
import 'forge_flow_bootstrap.dart';
import 'infrastructure/persistence/sqlite/repositories/sqlite_realtime_subscription_watermark_store.dart';
import 'services/auth/auth_session_ledger_writer.dart';
import 'services/auth/demo_auth_login_service.dart';
import 'services/auth/firebase_auth_runtime_bindings.dart';
import 'services/secure_session_storage.dart';
import 'services/mobile_push/firebase_mobile_push_runtime.dart';
import 'services/mobile_push/mobile_push_notification_service.dart';
import 'services/observability/crash_reporter.dart';
import 'services/realtime/realtime_subscription.dart';
import 'services/realtime/web_socket_channel_realtime_transport.dart';
import 'services/sync/http_sync_proxy_client.dart';
import 'services/sync/mobile_operational_sync_runtime.dart';

Future<void> main() async {
  // MP1 — Crashlytics: initialize PII-scrubbing crash reporter once
  // WidgetsFlutterBinding is ready. Gated on the same flag that
  // gates Firebase.initializeApp itself — in demo / kDemoMode builds
  // there is no Firebase app, so wiring FlutterError.onError to
  // FirebaseCrashlytics would recurse the first error back through
  // the same handler and freeze the engine. The actual Firebase init
  // happens inside createFirebaseAuthRuntimeBindings below, so the
  // initialize() call moves there.
  if (const bool.fromEnvironment('FORGE_FLOW_USE_FIREBASE_AUTH')) {
    // Optional dart-define `FORGE_FLOW_PROXY_BASE_URI` (e.g.
    // `https://forge-flow-proxy.run.app`) wires the production
    // proxy session-ledger writer. When unset the bindings expose
    // `null` and the bootstrap falls back to the scaffold-failing
    // default — sign-in then fails closed with a calm
    // `ledger_unavailable` message instead of silently dropping
    // `auth_sessions` rows.
    const proxyUriRaw = String.fromEnvironment('FORGE_FLOW_PROXY_BASE_URI');
    final proxyBaseUri = proxyUriRaw.isEmpty ? null : Uri.parse(proxyUriRaw);
    final bindings = await createFirebaseAuthRuntimeBindings(
      proxyBaseUri: proxyBaseUri,
    );
    // MP1 — Crashlytics wiring is gated on Firebase having been
    // initialized (which createFirebaseAuthRuntimeBindings did just
    // above). Skipped on web; skipped in demo/kDemoMode builds.
    if (!kIsWeb) {
      CrashReporter.instance.initialize();
    }
    // Phase 10a.UX.0 — when the proxy URI is wired, construct the
    // realtime subscription against `wss://<proxy>/v1/realtime` so
    // the operator-facing [SyncStateBadge] renders Live /
    // Reconnecting chrome. The shell's auth bridge calls
    // `setTenantContext` on the active session.
    //
    // Phase 10a.5 — pass the durable per-(operator, topic) watermark
    // store so the very first connect after a process restart resumes
    // against any events the operator missed during the cold-start
    // window (capped by the route's 5-minute replay floor; older
    // cursors trip a `replay_truncated` control envelope and a full
    // refresh).
    final realtimeSubscription = proxyBaseUri == null
        ? null
        : RealtimeSubscription(
            proxyBaseUri: _toWebSocketUri(proxyBaseUri),
            transport: const WebSocketChannelRealtimeTransport(),
            watermarkStore: SqliteRealtimeSubscriptionWatermarkStore.instance,
          );
    final syncProxyClient =
        proxyBaseUri == null || bindings.idTokenProvider == null
        ? null
        : HttpSyncProxyClient(
            proxyBaseUri: proxyBaseUri,
            idTokenProvider: bindings.idTokenProvider!,
          );
    final mobilePushNotifications = createFirebaseMobilePushNotificationService(
      tokenGateway: bindings.mobilePushTokenGateway,
      appVariant: const String.fromEnvironment(
        'FORGE_FLOW_APP_VARIANT',
        defaultValue: 'forgeflow',
      ),
      appEnvironment: const String.fromEnvironment(
        'FORGE_FLOW_APP_ENVIRONMENT',
        defaultValue: 'staging',
      ),
    );
    if (!kIsWeb) {
      WidgetsBinding.instance.addObserver(
        FcmTokenRevalidationObserver(
          mobilePushService: mobilePushNotifications,
        ),
      );
    }
    // Hard Rule #1 (mobile_core_star_target_truth_contract.md) — the
    // server owns which star shifts the manager picked. The
    // `HttpSyncProxyClient` we just constructed already implements
    // `StarTargetSelectionWriteClient`, so we pass the same reference
    // through `starTargetSelectionWriteClient` to make
    // `BaselineManagerService.serverSelectionWriter` non-null in the
    // production ForgeFlow flavor. Without this wiring, the manager-
    // override path silently writes to local SQLite via
    // `TargetCycleService.applyManagerOverrideCycle` instead of
    // round-tripping through the proxy.
    await bootstrapAndRunApp(
      ForgeFlowApp(
        requireAuth: true,
        permissionContextLoader: bindings.permissionContextLoader,
        authOperationsGateway: bindings.authOperationsGateway,
        accountInfoGateway: bindings.accountInfoGateway,
        passwordChangeGateway: bindings.passwordChangeGateway,
        mfaOperationsGateway: bindings.mfaOperationsGateway,
        mfaRecoveryRequestGateway: bindings.mfaRecoveryRequestGateway,
        passwordResetGateway: bindings.passwordResetGateway,
        passwordResetDeepLinkSource: bindings.passwordResetDeepLinkSource,
        handoffCodeGateway: bindings.handoffCodeGateway,
      ),
      authLoginService: bindings.authLoginService,
      secureSessionStorage: bindings.secureSessionStorage,
      authSessionLedgerWriter: bindings.authSessionLedgerWriter,
      realtimeSubscription: realtimeSubscription,
      syncProxyClient: syncProxyClient,
      starTargetSelectionWriteClient: syncProxyClient,
      mobilePushNotifications: mobilePushNotifications,
    );
    return;
  }
  if (_demoAuthEnabled) {
    // Demo Forge & Flow flavor (`--dart-define=kDemoMode=true` or
    // `FORGE_FLOW_DEMO_MODE=true`), WITHOUT real Firebase auth. Mount
    // the AuthGate (`requireAuth: true`) so the branded login screen +
    // its `kDemoMode` "Use demo operator" one-tap carve-out drive the
    // SAME `AuthSessionNotifier.signInWithEmailPassword` path
    // production uses — only the SOURCE swaps to the writer-side
    // [DemoAuthLoginService]. HP #2: this is a bootstrap source-swap,
    // not a `kDemoMode` reader branch — every reader (SettingsScreen,
    // role/permission gates) consumes the resulting `AuthSession`
    // identically in demo and prod. Mirrors the demo contract's
    // endorsed Operator Web / Admin `*_DEMO_AUTH` source-swap pattern.
    //
    // In-memory storage + ledger so demo sign-in does NOT fail closed
    // against the scaffold-failing bootstrap defaults; neither touches
    // a backend.
    await bootstrapAndRunApp(
      const ForgeFlowApp(requireAuth: true),
      authLoginService: const DemoAuthLoginService(),
      secureSessionStorage: InMemorySecureSessionStorage(),
      authSessionLedgerWriter: InMemoryAuthSessionLedgerWriter(),
      // HP #2 bootstrap source-swap: the 4 DemoScope locations are one
      // demo operator's tenancy and there is no operational proxy sync
      // to re-materialize a wiped location, so the production
      // cross-tenant wipe would destroy the 3 non-active demo
      // locations' cold-boot envelope on every location switch
      // (HISTORICAL ONLY defect). The demo-preserving strategy keeps
      // all 4 demo locations while still purging a genuinely-foreign
      // tenant. Same place this branch already swaps
      // DemoAuthLoginService / InMemorySecureSessionStorage. No
      // production path passes this -> defaultCrossTenantWipe stays in
      // force, byte-unchanged, for prod.
      crossTenantWipe: demoScopePreservingCrossTenantWipe,
    );
    return;
  }
  await bootstrapAndRunApp(const ForgeFlowApp());
}

/// Compile-time gate for the demo auth source-swap. Matches the
/// `_demoOperatorSignInEnabled` carve-out in
/// `lib/screens/auth/login_screen.dart` so the demo flavor that shows
/// the "Use demo operator" button is the same flavor that wires the
/// [DemoAuthLoginService] behind it. Unset in production builds, so
/// the production no-Firebase path falls through byte-unchanged to the
/// final `bootstrapAndRunApp(const ForgeFlowApp())`.
const bool _demoAuthEnabled =
    bool.fromEnvironment('kDemoMode') ||
    bool.fromEnvironment('FORGE_FLOW_DEMO_MODE');

/// Maps the HTTP/HTTPS proxy URI to its WebSocket counterpart so
/// [RealtimeSubscription] can append `/v1/realtime` and connect.
Uri _toWebSocketUri(Uri httpUri) {
  final scheme = switch (httpUri.scheme.toLowerCase()) {
    'https' => 'wss',
    'http' => 'ws',
    _ => httpUri.scheme,
  };
  return httpUri.replace(scheme: scheme);
}

/// Observer that re-validates the FCM token when the app resumes from
/// background. Ensures the push token is fresh and registered with the
/// backend after the app becomes active again.
class FcmTokenRevalidationObserver extends WidgetsBindingObserver {
  FcmTokenRevalidationObserver({
    required MobilePushNotificationService mobilePushService,
  }) : _mobilePushService = mobilePushService;

  final MobilePushNotificationService _mobilePushService;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Re-validate the FCM token on app resume to ensure the token is
      // still valid and synchronized with the backend.
      unawaited(_reValidateToken());
    }
  }

  Future<void> _reValidateToken() async {
    await _mobilePushService.reValidateToken();
  }
}
