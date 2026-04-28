// Forge & Flow advisor proxy — Cloud Run entrypoint.
//
// 11a.10a scaffold. Reads server-side config (secrets by name only),
// installs the request guard backed by the hard-fail-closed scaffold
// JWT verifier, and listens on `PORT`. The actual route logic lives
// in `advisor_proxy.dart::routeRequest` so tests drive the same
// handler the production entrypoint installs.
//
// 11a.10a did not call Anthropic, Voyage, Postgres, or Firebase.
// 11a.11c.5 retarget: the Postgres host moved from Supabase to Azure
// Database for PostgreSQL Flexible Server; secret names are now
// `POSTGRES_URL` / `POSTGRES_ADMIN_URL`.

import 'dart:io';

import 'advisor_proxy.dart';
import 'proxy_bootstrap.dart';

Future<void> main(List<String> args) async {
  ProxyConfig config;
  try {
    config = ProxyConfig.fromEnvironment(Platform.environment);
  } on ProxyConfigError catch (error) {
    // Names only — never values. EX_CONFIG (78) signals config error.
    stderr.writeln('advisor proxy startup failed: ${error.message}');
    exitCode = 78;
    return;
  }

  // 9.1 live-closeout: FIREBASE_PROJECT_ID selects the local Firebase
  // ID-token verifier with a pointycastle-backed RS256 validator.
  // Phase 9 production route bindings below also require it; missing
  // config exits before the proxy binds a port.
  final ProxyJwtVerifier verifier;
  final firebaseProjectId = config.firebaseProjectId;
  if (firebaseProjectId != null) {
    verifier = FirebaseProxyJwtVerifier(
      projectId: firebaseProjectId,
      keySource: FirebaseSecureTokenJwksSource(),
      signatureValidator: const PointyCastleRs256SignatureValidator(),
    );
  } else {
    verifier = const ScaffoldRejectingJwtVerifier();
  }
  final authGuard = ProxyRequestGuard(verifier: verifier);
  ProxyProductionBindings productionBindings;
  try {
    productionBindings = buildProxyProductionBindings(config);
  } on ProxyConfigError catch (error) {
    stderr.writeln('advisor proxy startup failed: ${error.message}');
    exitCode = 78;
    return;
  }

  // 11a.10b: usage guard installed at boot with the scaffold-failing
  // counter store + fixed launch-tier resolver. Real Postgres-backed
  // store and per-operator tier resolution wire in later proxy slices;
  // until then, usage-protected routes fail closed with 503.
  final usageGuard = ProxyUsageGuard(
    store: const ScaffoldFailingUsageCounterStore(),
    tierResolver: const FixedLaunchTierResolver(),
  );
  const accountingStore = ScaffoldFailingProxyAccountingStore();
  const healthCheckStore = ScaffoldFailingProxyHealthCheckStore();
  const llmProvider = ScaffoldRejectingProxyLlmProvider();
  final server = await HttpServer.bind(InternetAddress.anyIPv4, config.port);

  // Diagnostics line — names only, never values. Reports whether the
  // 9.1 Firebase verifier is wired (true when FIREBASE_PROJECT_ID is
  // set) so a startup grep can confirm the verifier path that is in
  // use without echoing the project ID.
  stdout.writeln(
    'advisor proxy listening on port ${config.port} '
    '(loaded secret names: ${config.loadedSecretNames.join(', ')}, '
    'firebase_verifier: ${firebaseProjectId == null ? 'scaffold' : 'firebase'}, '
    'auth_session_ledger: postgres, '
    'permission_snapshot: postgres, '
    'admin_permission_guard: postgres, '
    'auth_operations: postgres, '
    'password_change: postgres, '
    'mfa_operations: postgres_identitytoolkit_firebase_mfa)',
  );

  await for (final request in server) {
    // Each request is independent — failures in one must not crash
    // the listener loop.
    try {
      await routeRequest(
        request,
        authGuard,
        usageGuard: usageGuard,
        accountingStore: accountingStore,
        healthCheckStore: healthCheckStore,
        llmProvider: llmProvider,
        authSessionLedgerWriter: productionBindings.authSessionLedgerWriter,
        permissionSnapshotResolver:
            productionBindings.permissionSnapshotResolver,
        adminPermissionGuard: productionBindings.adminPermissionGuard,
        authOperationsGateway: productionBindings.authOperationsGateway,
        passwordChangeGateway: productionBindings.passwordChangeGateway,
        mfaOperationsGateway: productionBindings.mfaOperationsGateway,
      );
    } catch (error, stack) {
      stderr.writeln('advisor proxy request handler error: $error\n$stack');
    }
  }
}
