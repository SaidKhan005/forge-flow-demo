import 'forge_flow_app.dart';
import 'forge_flow_bootstrap.dart';
import 'services/auth/firebase_auth_runtime_bindings.dart';

Future<void> main() async {
  if (const bool.fromEnvironment('FORGE_FLOW_USE_FIREBASE_AUTH')) {
    final bindings = await createFirebaseAuthRuntimeBindings();
    await bootstrapAndRunApp(
      const ForgeFlowApp(),
      authLoginService: bindings.authLoginService,
      secureSessionStorage: bindings.secureSessionStorage,
    );
    return;
  }
  await bootstrapAndRunApp(const ForgeFlowApp());
}
