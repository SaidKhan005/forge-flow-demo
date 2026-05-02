// Forge & Flow advisor proxy — Cloud Run entrypoint.
//
// Reads server-side config (secrets by name only), installs the request
// guard backed by the Firebase ID-token verifier (with the service-
// principal JWT verifier composited alongside), and listens on `PORT`.
// The actual route logic lives in `advisor_proxy.dart::routeRequest` so
// tests drive the same handler the production entrypoint installs.
//
// 11a.11c.5 retarget: Postgres host is Azure Database for PostgreSQL
// Flexible Server; secret names are `POSTGRES_URL` / `POSTGRES_ADMIN_URL`.
//
// HARD-A: the entrypoint wires the Postgres-backed
// `AdvisorProxyUsageCounterStore` and the registry-backed
// `RegistryProxyHealthCheckStore` from `buildProxyProductionBindings`
// so usage caps actually enforce and `/health` returns the contracted
// envelope. `PROXY_ENVIRONMENT=prod` with `FIREBASE_PROJECT_ID` unset
// exits 78 (EX_CONFIG) — production never falls back to the scaffold
// JWT verifier.
//
// Lock 7: per-instance circuit breaker over real Anthropic primary
// plus optional real Gemini secondary; on breaker open the pipeline
// serves graceful refusal. Anthropic is wired via the real Messages-
// API HTTP adapter (`productionBindings.llmProvider`); Gemini is wired
// via the real SDK adapter when `GEMINI_API_KEY` is loaded, otherwise
// the secondary slot is null and the pipeline reduces to anthropic →
// cache → graceful refusal.

import 'dart:io';

import 'package:forge_and_flow/domain/services/advisor_response_cache.dart';
import 'package:forge_and_flow/domain/services/circuit_breaker.dart';

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

  // HARD-A: prod requires FIREBASE_PROJECT_ID. The decision lives in
  // [evaluateProxyStartup] so it can be unit-tested without binding a
  // socket or invoking `dart run` in a subprocess.
  final firebaseProjectId = config.firebaseProjectId;
  final isProductionEnvironment =
      (Platform.environment['PROXY_ENVIRONMENT'] ?? '')
              .trim()
              .toLowerCase() ==
          'prod';
  final startupFailure = evaluateProxyStartup(
    config: config,
    environment: Platform.environment,
  );
  if (startupFailure != null) {
    stderr.writeln(startupFailure.message);
    exitCode = startupFailure.exitCode;
    return;
  }

  // 9.1 live-closeout: FIREBASE_PROJECT_ID selects the local Firebase
  // ID-token verifier with a pointycastle-backed RS256 validator.
  // Phase 9 production route bindings below also require it; missing
  // config exits before the proxy binds a port.
  final ProxyJwtVerifier verifier;
  if (firebaseProjectId != null) {
    verifier = CompositeProxyJwtVerifier(<ProxyJwtVerifier>[
      FirebaseProxyJwtVerifier(
        projectId: firebaseProjectId,
        keySource: FirebaseSecureTokenJwksSource(),
        signatureValidator: const PointyCastleRs256SignatureValidator(),
      ),
      ServicePrincipalJwtVerifier(
        sharedSecret: config.secretFor(
          ProxySecretNames.servicePrincipalJwtSecret,
        ),
      ),
    ]);
  } else {
    verifier = const ScaffoldRejectingJwtVerifier();
  }
  final authGuard = ProxyRequestGuard(verifier: verifier);
  ProxyProductionBindings productionBindings;
  List<String> adminCorsAllowList;
  try {
    productionBindings = buildProxyProductionBindings(
      config,
      // HARD-A: only `prod` requires the live Firebase admin client.
      // Dev/staging without FIREBASE_PROJECT_ID falls back to the
      // scaffold-failing client so the proxy still binds and unauth
      // probes (`/health`, `/healthz`, `/readyz`) keep working.
      requireFirebase: isProductionEnvironment,
    );
    // HARD-C — read supplemental CORS origins from the
    // `admin_cors_origins_extra` row in `public.feature_flags` once
    // at boot. When that row is enabled, its description column is
    // comma-split into the supplemental allow-list and merged below.
    // Read happens before binding the port so a flaky DB at startup
    // fails closed rather than silently dropping the extras.
    final adminCorsExtraOrigins = await loadAdminCorsExtraOrigins(
      flag: productionBindings.adminCorsOriginsExtraFlag,
    );
    // HARD-C — resolve the admin CORS allow-list at startup.
    // `resolveAdminCorsAllowList` fails closed when the merged list
    // is empty AND `PROXY_ENVIRONMENT` is not a known dev/staging
    // value (`dev` or `staging`); the surrounding catch translates
    // that into exit 78.
    adminCorsAllowList = resolveAdminCorsAllowList(
      config,
      featureFlagExtras: adminCorsExtraOrigins,
    );
  } on ProxyConfigError catch (error) {
    stderr.writeln('advisor proxy startup failed: ${error.message}');
    exitCode = 78;
    return;
  }

  // HARD-A: usage guard now installed with the Postgres-backed
  // counter store from productionBindings. Per-operator tier
  // resolution remains the launch-tier default until a later proxy
  // slice introduces tier-aware policy lookup.
  final usageGuard = ProxyUsageGuard(
    store: productionBindings.usageCounterStore,
    tierResolver: const FixedLaunchTierResolver(),
  );
  // HARD-A: registry-backed `/health` envelope. Reserved metrics from
  // `proxy_health_contract.md` whose producers have not landed yet
  // (B43 / B44 / B45 / B47) project to `status: unknown` without
  // turning the response degraded.
  final healthCheckStore = productionBindings.healthCheckStore;
  // Phase 11A.4b — primary is the real Anthropic Messages-API HTTP
  // adapter (via productionBindings). The breaker still owns failure
  // handling; the secondary slot is a real Gemini SDK adapter when
  // GEMINI_API_KEY is loaded, otherwise null.
  final llmProvider = productionBindings.llmProvider;

  // Lock 7 v1: per-instance breaker + always-miss cache stub.
  // Replace the cache with a real impl in E.2b.
  final anthropicBreaker = CircuitBreaker(providerId: 'anthropic');
  const advisorResponseCache = AlwaysMissAdvisorResponseCache();
  final advisorRequestPipeline = AdvisorRequestPipeline(
    breaker: anthropicBreaker,
    cache: advisorResponseCache,
    secondaryLlmProvider: productionBindings.secondaryLlmProvider,
  );

  final server = await HttpServer.bind(InternetAddress.anyIPv4, config.port);

  // HARD-A: own line for gemini_slot_enabled so deploy verification
  // can grep for the slot status without parsing the larger
  // diagnostics envelope below. `true` when GEMINI_API_KEY was loaded
  // at startup; `false` otherwise.
  stdout.writeln(
    'gemini_slot_enabled: ${productionBindings.geminiSlotEnabled}',
  );

  // Diagnostics line — names only, never values. Reports whether the
  // 9.1 Firebase verifier is wired (true when FIREBASE_PROJECT_ID is
  // set) so a startup grep can confirm the verifier path that is in
  // use without echoing the project ID.
  stdout.writeln(
    'advisor proxy listening on port ${config.port} '
    '(loaded secret names: ${config.loadedSecretNames.join(', ')}, '
    'firebase_verifier: ${firebaseProjectId == null ? 'scaffold' : 'firebase'}, '
    'auth_session_ledger: postgres, '
    'accounting_store: postgres, '
    'permission_snapshot: postgres, '
    'account_info: postgres, '
    'admin_permission_guard: postgres, '
    'auth_operations: postgres, '
    'service_principal_issuance: postgres, '
    'password_change: postgres, '
    'password_reset_confirm: postgres, '
    'mfa_operations: postgres_identitytoolkit_firebase_mfa, '
    'mfa_recovery_request: postgres_event_outbox, '
    'operator_location_admin: postgres, '
    'pricing_tier_admin: postgres, '
    'corpus_admin: postgres, '
    'integration_admin: postgres_kms_stub, '
    'feature_flags_admin: postgres, '
    'admin_cors_allow_list_count: ${adminCorsAllowList.length}, '
    'advisor_pipeline: lock7_v1_per_instance_breaker_alwaysmiss_cache'
    '${productionBindings.geminiSlotEnabled ? '_with_gemini_secondary' : ''})',
  );

  await for (final request in server) {
    // Each request is independent — failures in one must not crash
    // the listener loop.
    try {
      await routeRequest(
        request,
        authGuard,
        usageGuard: usageGuard,
        accountingStore: productionBindings.accountingStore,
        healthCheckStore: healthCheckStore,
        llmProvider: llmProvider,
        advisorRequestPipeline: advisorRequestPipeline,
        authSessionLedgerWriter: productionBindings.authSessionLedgerWriter,
        firebaseAdminAuthClient: productionBindings.firebaseAdminAuthClient,
        accountInfoGateway: productionBindings.accountInfoGateway,
        permissionSnapshotResolver:
            productionBindings.permissionSnapshotResolver,
        adminPermissionGuard: productionBindings.adminPermissionGuard,
        authOperationsGateway: productionBindings.authOperationsGateway,
        servicePrincipalJwtIssuanceGateway:
            productionBindings.servicePrincipalJwtIssuanceGateway,
        passwordChangeGateway: productionBindings.passwordChangeGateway,
        passwordResetConfirmGateway:
            productionBindings.passwordResetConfirmGateway,
        passwordResetRequestGateway:
            productionBindings.passwordResetRequestGateway,
        mfaOperationsGateway: productionBindings.mfaOperationsGateway,
        mfaRecoveryRequestGateway: productionBindings.mfaRecoveryRequestGateway,
        operatorLocationAdminGateway:
            productionBindings.operatorLocationAdminGateway,
        pricingTierAdminGateway: productionBindings.pricingTierAdminGateway,
        corpusAdminGateway: productionBindings.corpusAdminGateway,
        graphCandidatesGateway: productionBindings.graphCandidatesGateway,
        integrationAdminGateway: productionBindings.integrationAdminGateway,
        integrationAdminActorResolver:
            productionBindings.integrationAdminActorResolver,
        featureFlagsAdminGateway:
            productionBindings.featureFlagsAdminGateway,
        adminCorsAllowList: adminCorsAllowList,
      );
    } catch (error, stack) {
      stderr.writeln('advisor proxy request handler error: $error\n$stack');
    }
  }
}
