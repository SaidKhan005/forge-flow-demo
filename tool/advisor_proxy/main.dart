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
import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_outbox_listener.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/realtime/realtime_event_publisher.dart';

import 'advisor_proxy.dart';
import 'log.dart';
import 'proxy_bootstrap.dart';
import 'realtime_bridge.dart';

Future<void> main(List<String> args) async {
  // Startup banner — plain text only, before the log module owns
  // stdout. Once `ProxyConfig.fromEnvironment` returns, every subsequent
  // event flows through `log()` as JSON (HARD-G observability baseline).
  stdout.writeln('advisor proxy starting up');
  ProxyConfig config;
  try {
    config = ProxyConfig.fromEnvironment(Platform.environment);
  } on ProxyKmsMisconfiguredError {
    // ProxyConfig.fromEnvironment already emitted
    // startup.kms_misconfigured. Exit with EX_CONFIG.
    exitCode = 78;
    return;
  } on ProxyConfigError catch (error) {
    // Names only — never values. EX_CONFIG (78) signals config error.
    log(
      LogSeverity.error,
      'startup.failed',
      fields: <String, Object?>{
        'phase': 'config',
        'message': error.message,
        'missing_secret_names': error.missingSecretNames,
        'exit_code': 78,
      },
    );
    exitCode = 78;
    return;
  }

  // HARD-A: prod requires FIREBASE_PROJECT_ID. The decision lives in
  // [evaluateProxyStartup] so it can be unit-tested without binding a
  // socket or invoking `dart run` in a subprocess.
  final firebaseProjectId = config.firebaseProjectId;
  final isProductionEnvironment =
      (Platform.environment['PROXY_ENVIRONMENT'] ?? '').trim().toLowerCase() ==
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

  // HARD-G observability: report the resolved config block so an
  // operator can grep startup logs for what was bound (names only,
  // never values). Runs after the HARD-A fail-closed gate so the
  // line only appears when the proxy will actually proceed to bind.
  log(
    LogSeverity.info,
    'startup.config_resolved',
    fields: <String, Object?>{
      'port': config.port,
      'environment': config.proxyEnvironment,
      'kms_real_provider_enabled': config.kmsRealProviderEnabled,
      'firebase_project_id_loaded': config.firebaseProjectId != null,
      'gcp_project_id_loaded': config.gcpProjectId != null,
      'cloud_run_region_loaded': config.cloudRunRegion != null,
      'cloud_run_service_name_loaded': config.cloudRunServiceName != null,
      'loaded_secret_names': config.loadedSecretNames,
    },
  );

  final migrationFilenames = loadProxyMigrationFilenames();
  if (migrationFilenames.isEmpty) {
    log(
      LogSeverity.error,
      'startup.failed',
      fields: <String, Object?>{
        'phase': 'migration_catalog',
        'message': 'db/migrations catalog is missing from proxy runtime',
        'exit_code': 78,
      },
    );
    exitCode = 78;
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
      expectedMigrationFilenames: migrationFilenames,
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
  } on ProxyKmsMisconfiguredError catch (error) {
    // HARD-G: _buildKmsProvider already emitted the structured
    // startup.kms_misconfigured event. Exit with EX_CONFIG.
    exitCode = 78;
    // Reference the error so the static analyzer does not flag the
    // local as unused; the operator-facing message is in the log.
    assert(error.missingSecretNames.isNotEmpty);
    return;
  } on ProxyConfigError catch (error) {
    log(
      LogSeverity.error,
      'startup.failed',
      fields: <String, Object?>{
        'phase': 'production_bindings',
        'message': error.message,
        'missing_secret_names': error.missingSecretNames,
        'exit_code': 78,
      },
    );
    exitCode = 78;
    return;
  }

  // HARD-G observability: probe Postgres connectivity before binding
  // the listener so a slow / broken pool fails the deploy with
  // exit 78 instead of degrading every request. The executor emits
  // `request.dependency_timeout` at the wire boundary; the probe
  // helper translates that into a startup-level log line.
  try {
    await probeProxyStartupConnectivity(productionBindings);
  } on DependencyTimeoutException {
    exitCode = 78;
    return;
  } catch (error, stack) {
    log(
      LogSeverity.error,
      'startup.failed',
      fields: <String, Object?>{
        'phase': 'postgres_probe',
        'error_type': error.runtimeType.toString(),
        'error_message': error.toString(),
        'stack_first_frame': firstStackFrame(stack),
        'exit_code': 78,
      },
    );
    exitCode = 78;
    return;
  }

  try {
    final insertedMigrationRows = await recordProxyStartupMigrations(
      productionBindings,
      migrationFilenames,
    );
    log(
      LogSeverity.info,
      'startup.migrations_recorded',
      fields: <String, Object?>{
        'migration_catalog_count': migrationFilenames.length,
        'inserted_migration_rows': insertedMigrationRows,
      },
    );
  } catch (error, stack) {
    log(
      LogSeverity.error,
      'startup.failed',
      fields: <String, Object?>{
        'phase': 'migration_registry',
        'error_type': error.runtimeType.toString(),
        'error_message': error.toString(),
        'stack_first_frame': firstStackFrame(stack),
        'exit_code': 78,
      },
    );
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

  // Phase 10a.0 — realtime push channel scaffold. Single-instance
  // fan-out via in-process publisher; multi-instance Cloud Pub/Sub
  // bridge is the documented Phase 10a follow-up. Bridge worker
  // claims durable rows from `event_outbox` (NEVER bypasses the
  // table; see `docs/contracts/event_outbox_contract.md`) and hands
  // them to the publisher for the WebSocket route to fan out.
  final realtimePublisher = InProcessRealtimePublisher();
  final realtimeOutboxListener = PackagePostgresOutboxListener.fromUrl(
    config.secretFor(ProxySecretNames.postgresUrl),
  );
  final realtimeOutboxRepository = EventOutboxRepository(
    TenantTransactionWrapper(productionBindings.tenantPool),
  );
  final realtimeAdminWrapper = TenantTransactionWrapper(
    productionBindings.adminPool,
  );
  final realtimeBridge = RealtimeBridgeWorker(
    listener: realtimeOutboxListener,
    outboxRepository: realtimeOutboxRepository,
    publisher: realtimePublisher,
    locationResolver: _BootstrapLocationResolver(
      adminWrapper: realtimeAdminWrapper,
    ).resolve,
    operatorDiscoverer: _PostgresOperatorDiscoverer(
      adminWrapper: realtimeAdminWrapper,
    ).discover,
    logger: _logRealtimeBridgeEvent,
  );
  try {
    await realtimeBridge.start();
  } catch (error, stack) {
    log(
      LogSeverity.error,
      'startup.failed',
      fields: <String, Object?>{
        'phase': 'realtime_bridge_start',
        'error_type': error.runtimeType.toString(),
        'error_message': error.toString(),
        'stack_first_frame': firstStackFrame(stack),
        'exit_code': 78,
      },
    );
    exitCode = 78;
    return;
  }

  final server = await HttpServer.bind(InternetAddress.anyIPv4, config.port);

  // HARD-A: own line for gemini_slot_enabled so deploy verification
  // can grep for the slot status without parsing the larger
  // diagnostics envelope below. `true` when GEMINI_API_KEY was loaded
  // at startup; `false` otherwise.
  stdout.writeln(
    'gemini_slot_enabled: ${productionBindings.geminiSlotEnabled}',
  );
  stdout.writeln('admin_cors_allow_list_count: ${adminCorsAllowList.length}');

  // Diagnostics line — names only, never values. Reports whether the
  // 9.1 Firebase verifier is wired (true when FIREBASE_PROJECT_ID is
  // set) so a startup grep can confirm the verifier path that is in
  // use without echoing the project ID.
  log(
    LogSeverity.info,
    'startup.complete',
    fields: <String, Object?>{
      'port': config.port,
      'loaded_secret_names': config.loadedSecretNames,
      'firebase_verifier': firebaseProjectId == null ? 'scaffold' : 'firebase',
      'auth_session_ledger': 'postgres',
      'accounting_store': 'postgres',
      'permission_snapshot': 'postgres',
      'account_info': 'postgres',
      'admin_permission_guard': 'postgres',
      'auth_operations': 'postgres',
      'service_principal_issuance': 'postgres',
      'password_change': 'postgres',
      'password_reset_confirm': 'postgres',
      'mfa_operations': 'postgres_identitytoolkit_firebase_mfa',
      'mfa_recovery_request': 'postgres_event_outbox',
      'operator_location_admin': 'postgres',
      'pricing_tier_admin': 'postgres',
      'corpus_admin': 'postgres',
      'integration_admin': 'postgres_kms_stub',
      'feature_flags_admin': 'postgres',
      // HARD-H — admin idempotency cache backed by
      // `public.admin_request_idempotency`. Surfacing the binding
      // here lets a deploy grep confirm dedup is wired before the
      // first toggle POST hits.
      'admin_request_idempotency': 'postgres',
      // HARD-C surfaces the admin CORS allow-list size so a deploy
      // grep can confirm the value without dumping origins to the log.
      'admin_cors_allow_list_count': adminCorsAllowList.length,
      'migration_catalog_count': migrationFilenames.length,
      'advisor_pipeline':
          'lock7_v1_per_instance_breaker_alwaysmiss_cache'
          '${productionBindings.geminiSlotEnabled ? '_with_gemini_secondary' : ''}',
    },
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
        featureFlagsAdminGateway: productionBindings.featureFlagsAdminGateway,
        // HARD-B - auth lockout / retry enforcement.
        authLockoutEnforcer: productionBindings.authLockoutEnforcer,
        authLockoutAuditSink: productionBindings.authLockoutAuditSink,
        mfaTotpRetryCounter: productionBindings.mfaTotpRetryCounter,
        passwordResetThrottleCounter:
            productionBindings.passwordResetThrottleCounter,
        adminCorsAllowList: adminCorsAllowList,
        // HARD-H — admin idempotency cache wired in so duplicate
        // POSTs (today: feature flags toggle) return the cached
        // response instead of re-running the gateway.
        adminRequestIdempotencyStore:
            productionBindings.adminRequestIdempotencyStore,
        // Phase 10a.0 — WebSocket route subscribes to this publisher
        // for the connected operator's events.
        realtimePublisher: realtimePublisher,
      );
    } catch (error, stack) {
      log(
        LogSeverity.error,
        'proxy.listener_loop_error',
        fields: <String, Object?>{
          'error_type': error.runtimeType.toString(),
          'error_message': error.toString(),
          'stack_first_frame': firstStackFrame(stack),
        },
      );
    }
  }
}

/// Phase 10a.0 — operator → location lookup the realtime bridge uses
/// when constructing a `TenantContext` for `claimBatch`. The claim
/// itself filters only on `operator_id` (the per-tenant index leads
/// with `operator_id`), but `TenantContext` requires both ids for the
/// SET LOCAL bookkeeping. Per-operator default location is the first
/// row in `public.locations`. Cached in-process so the bridge does
/// not query Postgres on every drain cycle.
class _BootstrapLocationResolver {
  _BootstrapLocationResolver({required TenantTransactionWrapper adminWrapper})
    : _adminWrapper = adminWrapper;

  final TenantTransactionWrapper _adminWrapper;
  final Map<String, String> _cache = <String, String>{};

  Future<String> resolve(String operatorId) async {
    final cached = _cache[operatorId];
    if (cached != null) return cached;
    final rows = await _adminWrapper.runAsSystem<List<Map<String, Object?>>>(
      (exec) => exec.query(
        'select location_id::text as location_id '
        'from public.locations '
        'where operator_id = @operator_id::uuid '
        'order by created_at asc '
        'limit 1',
        parameters: <String, Object?>{'operator_id': operatorId},
      ),
      reason: 'realtime_bridge_resolve_default_location',
    );
    if (rows.isEmpty) {
      throw StateError(
        'realtime bridge: operator $operatorId has no rows in public.locations',
      );
    }
    final id = rows.single['location_id'];
    if (id is! String || id.isEmpty) {
      throw StateError(
        'realtime bridge: locations row returned a malformed location_id',
      );
    }
    _cache[operatorId] = id;
    return id;
  }
}

/// Phase 10a.0 — operator discoverer for the bridge poll cycle.
/// Returns the distinct set of operator ids that have undelivered
/// `event_outbox` rows, capped so a runaway producer cannot make the
/// discovery query expensive. Production goes through the admin pool
/// + `runAsSystem` because cross-operator visibility is the whole
/// point of the discovery query — RLS would block it.
class _PostgresOperatorDiscoverer {
  _PostgresOperatorDiscoverer({
    required TenantTransactionWrapper adminWrapper,
    int limit = 1000,
  }) : _adminWrapper = adminWrapper,
       _limit = limit;

  final TenantTransactionWrapper _adminWrapper;
  final int _limit;

  Future<Set<String>> discover() async {
    final rows = await _adminWrapper.runAsSystem<List<Map<String, Object?>>>(
      (exec) => exec.query(
        'select distinct operator_id::text as operator_id '
        'from public.event_outbox '
        'where delivered_at is null '
        'limit @limit',
        parameters: <String, Object?>{'limit': _limit},
      ),
      reason: 'realtime_bridge_discover_operators_with_undelivered_rows',
    );
    final result = <String>{};
    for (final row in rows) {
      final id = row['operator_id'];
      if (id is String && id.isNotEmpty) {
        result.add(id);
      }
    }
    return result;
  }
}

/// Phase 10a.0 — funnel bridge worker log events into the structured
/// log() helper. Names only — the operator id is fine to log
/// (already in the request log context elsewhere); errors are
/// stringified.
void _logRealtimeBridgeEvent(RealtimeBridgeLogEvent event) {
  final fields = <String, Object?>{
    if (event.operatorId != null) 'operator_id': event.operatorId,
    if (event.outboxId != null) 'outbox_id': event.outboxId,
    if (event.topic != null) 'topic': event.topic,
    if (event.error != null) 'error_type': event.error.runtimeType.toString(),
    if (event.error != null) 'error_message': event.error.toString(),
    if (event.stack != null) 'stack_first_frame': firstStackFrame(event.stack!),
  };
  switch (event.kind) {
    case RealtimeBridgeLogKind.listenerError:
      log(LogSeverity.warning, 'realtime.bridge.listener_error', fields: fields);
    case RealtimeBridgeLogKind.discoveryFailed:
      log(LogSeverity.warning, 'realtime.bridge.discovery_failed',
          fields: fields);
    case RealtimeBridgeLogKind.locationResolveFailed:
      log(LogSeverity.warning, 'realtime.bridge.location_resolve_failed',
          fields: fields);
    case RealtimeBridgeLogKind.claimFailed:
      log(LogSeverity.warning, 'realtime.bridge.claim_failed', fields: fields);
    case RealtimeBridgeLogKind.publishFailed:
      log(LogSeverity.warning, 'realtime.bridge.publish_failed', fields: fields);
    case RealtimeBridgeLogKind.markDeliveredFailed:
      log(LogSeverity.warning, 'realtime.bridge.mark_delivered_failed',
          fields: fields);
  }
}

List<String> loadProxyMigrationFilenames({Directory? directory}) {
  final migrationsDirectory = directory ?? Directory('db/migrations');
  if (!migrationsDirectory.existsSync()) {
    return const <String>[];
  }
  final filenames =
      migrationsDirectory
          .listSync()
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .where((filename) => filename.endsWith('.sql'))
          .toList()
        ..sort();
  return List<String>.unmodifiable(filenames);
}
