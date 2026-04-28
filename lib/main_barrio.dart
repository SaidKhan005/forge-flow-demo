import 'barrio_app.dart';
import 'forge_flow_bootstrap.dart';
import 'services/auth/firebase_auth_runtime_bindings.dart';

Future<void> main() async {
  if (const bool.fromEnvironment('FORGE_FLOW_USE_FIREBASE_AUTH')) {
    // Optional dart-define `FORGE_FLOW_PROXY_BASE_URI` (e.g.
    // `https://forge-flow-proxy.run.app`) wires the production
    // proxy session-ledger writer. When unset the bindings expose
    // `null` and the bootstrap falls back to the scaffold-failing
    // default — sign-in then fails closed with a calm
    // `ledger_unavailable` message instead of silently dropping
    // `auth_sessions` rows.
    const proxyUriRaw = String.fromEnvironment(
      'FORGE_FLOW_PROXY_BASE_URI',
    );
    final proxyBaseUri = proxyUriRaw.isEmpty ? null : Uri.parse(proxyUriRaw);
    final bindings = await createFirebaseAuthRuntimeBindings(
      proxyBaseUri: proxyBaseUri,
    );
    await bootstrapAndRunApp(
      const BarrioApp(),
      authLoginService: bindings.authLoginService,
      secureSessionStorage: bindings.secureSessionStorage,
      authSessionLedgerWriter: bindings.authSessionLedgerWriter,
    );
    return;
  }
  await bootstrapAndRunApp(const BarrioApp());
}
