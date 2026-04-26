// Forge & Flow advisor proxy — Cloud Run entrypoint.
//
// 11a.10a scaffold. Reads server-side config (secrets by name only),
// installs the request guard backed by the hard-fail-closed scaffold
// JWT verifier, and listens on `PORT`. The actual route logic lives
// in `advisor_proxy.dart::routeRequest` so tests drive the same
// handler the production entrypoint installs.
//
// 11a.10a does not call Anthropic, Voyage, Postgres, or Firebase.
// 11a.11c.5 retarget: the Postgres host moved from Supabase to Azure
// Database for PostgreSQL Flexible Server; secret names are now
// `POSTGRES_URL` / `POSTGRES_ADMIN_URL`. Live provider / DB wiring
// lands in later proxy slices.

import 'dart:io';

import 'advisor_proxy.dart';

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

  final authGuard = ProxyRequestGuard(
    verifier: const ScaffoldRejectingJwtVerifier(),
  );

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

  // Diagnostics line — names only, never values.
  stdout.writeln(
    'advisor proxy listening on port ${config.port} '
    '(loaded secret names: ${config.loadedSecretNames.join(', ')})',
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
      );
    } catch (error, stack) {
      stderr.writeln('advisor proxy request handler error: $error\n$stack');
    }
  }
}
