import 'forge_flow_app.dart';
import 'forge_flow_bootstrap.dart';
import 'services/auth/firebase_auth_runtime_bindings.dart';
import 'services/mobile_push/firebase_mobile_push_runtime.dart';

Future<void> main() async {
  if (const bool.fromEnvironment('FORGE_FLOW_USE_FIREBASE_AUTH')) {
    const proxyUriRaw = String.fromEnvironment('FORGE_FLOW_PROXY_BASE_URI');
    final proxyBaseUri = proxyUriRaw.isEmpty ? null : Uri.parse(proxyUriRaw);
    final bindings = await createFirebaseAuthRuntimeBindings(
      proxyBaseUri: proxyBaseUri,
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
      mobilePushNotifications: mobilePushNotifications,
    );
    return;
  }
  await bootstrapAndRunApp(const ForgeFlowApp());
}
