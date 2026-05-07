import 'dart:async';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'forge_flow_app.dart';
import 'forge_flow_bootstrap.dart';
import 'infrastructure/persistence/sqlite/repositories/sqlite_realtime_subscription_watermark_store.dart';
import 'services/auth/firebase_auth_runtime_bindings.dart';
import 'services/mobile_push/firebase_mobile_push_runtime.dart';
import 'services/mobile_push/mobile_push_notification_service.dart';
import 'services/observability/crash_reporter.dart';
import 'services/realtime/realtime_subscription.dart';
import 'services/realtime/web_socket_channel_realtime_transport.dart';
import 'services/sync/http_sync_proxy_client.dart';

Future<void> main() async {
  // MP1 — Crashlytics: initialize PII-scrubbing crash reporter once
  // WidgetsFlutterBinding is ready (Firebase.initializeApp is called
  // inside createFirebaseAuthRuntimeBindings / bootstrapAndRunApp).
  // The recorder is a no-op on web and in environments where Firebase
  // is not initialised.
  if (!kIsWeb) {
    CrashReporter.instance.initialize();
  }

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
      ),
      authLoginService: bindings.authLoginService,
      secureSessionStorage: bindings.secureSessionStorage,
      authSessionLedgerWriter: bindings.authSessionLedgerWriter,
      realtimeSubscription: realtimeSubscription,
      syncProxyClient: syncProxyClient,
      mobilePushNotifications: mobilePushNotifications,
    );
    return;
  }
  await bootstrapAndRunApp(const ForgeFlowApp());
}

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
    // Invoke reValidateToken if the implementation has it, otherwise
    // this is a graceful no-op for the noop service.
    if (_mobilePushService case MobilePushNotificationCoordinator coordinator) {
      await coordinator.reValidateToken();
    }
  }
}
