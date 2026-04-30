import 'forge_flow_app.dart';
import 'forge_flow_bootstrap.dart';
import 'services/auth/firebase_auth_runtime_bindings.dart';

Future<void> main() async {
  if (const bool.fromEnvironment('FORGE_FLOW_USE_FIREBASE_AUTH')) {
    const proxyUriRaw = String.fromEnvironment('FORGE_FLOW_PROXY_BASE_URI');
    final proxyBaseUri = proxyUriRaw.isEmpty ? null : Uri.parse(proxyUriRaw);
    final bindings = await createFirebaseAuthRuntimeBindings(
      proxyBaseUri: proxyBaseUri,
    );
    await bootstrapAndRunApp(
      ForgeFlowApp(
        requireAuth: true,
        permissionContextLoader: bindings.permissionContextLoader,
        authOperationsGateway: bindings.authOperationsGateway,
        passwordChangeGateway: bindings.passwordChangeGateway,
        mfaOperationsGateway: bindings.mfaOperationsGateway,
        mfaRecoveryRequestGateway: bindings.mfaRecoveryRequestGateway,
      ),
      authLoginService: bindings.authLoginService,
      secureSessionStorage: bindings.secureSessionStorage,
    );
    return;
  }
  await bootstrapAndRunApp(const ForgeFlowApp());
}
