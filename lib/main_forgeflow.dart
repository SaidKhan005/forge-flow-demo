import 'forge_flow_app.dart';
import 'forge_flow_bootstrap.dart';
import 'services/auth/firebase_auth_runtime_bindings.dart';
import 'services/mobile_push/firebase_mobile_push_runtime.dart';
import 'services/realtime/realtime_subscription.dart';
import 'services/realtime/web_socket_channel_realtime_transport.dart';

Future<void> main() async {
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
    final realtimeSubscription = proxyBaseUri == null
        ? null
        : RealtimeSubscription(
            proxyBaseUri: _toWebSocketUri(proxyBaseUri),
            transport: const WebSocketChannelRealtimeTransport(),
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
