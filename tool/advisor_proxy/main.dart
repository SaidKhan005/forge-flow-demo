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

import 'dart:async';
import 'dart:io';

import 'package:forge_and_flow/domain/services/circuit_breaker.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_outbox_listener.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/connector_connection_list_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_dead_letter_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/realtime/pubsub_realtime_publisher.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/repository_integration_routes_gateway.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/services/realtime/realtime_event_publisher.dart';
import 'package:forge_and_flow/services/realtime/realtime_replay_resolver.dart';

import 'admin_email_routes.dart';
import 'admin_integrations_routes.dart';
import 'advisor_proxy.dart';
import 'advisor_response_cache.dart';
import 'integration_oauth_routes.dart';
import 'integration_oauth_state_store.dart';
import 'log.dart';
import 'phase_8_production_binder.dart';
import 'phase_8_test_connection_executor.dart';
import 'proxy_bootstrap.dart';
import 'realtime_bridge.dart';
import 'realtime_route.dart' show RealtimeReplayResult;
import 'realtime_tripwire_gateway.dart';

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
    await verifyAdminProxySchemaContract(productionBindings);
    log(
      LogSeverity.info,
      'startup.admin_schema_contract_verified',
      fields: <String, Object?>{
        'required_table_count':
            AdminProxySchemaContractVerifier.requiredTables.length,
        'required_column_count':
            AdminProxySchemaContractVerifier.requiredColumns.length,
        'required_feature_flag_count':
            AdminProxySchemaContractVerifier.requiredFeatureFlags.length,
      },
    );
  } on ProxySchemaContractException catch (error) {
    log(
      LogSeverity.error,
      'startup.failed',
      fields: <String, Object?>{
        'phase': 'admin_schema_contract',
        'missing_objects': error.missingObjects,
        'exit_code': 78,
      },
    );
    exitCode = 78;
    return;
  } catch (error, stack) {
    log(
      LogSeverity.error,
      'startup.failed',
      fields: <String, Object?>{
        'phase': 'admin_schema_contract',
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
  // code-health.L14: real Postgres-backed cache wired via the proxy
  // tenant pool so the breaker-open / primary-failure / secondary-
  // failure branch can replay a recent identical answer instead of
  // falling straight to graceful refusal. Backed by
  // public.advisor_response_cache (24h TTL, hourly pg_cron sweep).
  final anthropicBreaker = CircuitBreaker(providerId: 'anthropic');
  final advisorResponseCache = PostgresAdvisorResponseCache(
    tenantWrapper: TenantTransactionWrapper(productionBindings.tenantPool),
  );
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
  //
  // Phase 10a.1 — the bridge's outbound publisher is selected via
  // `selectRealtimePublisher` so flipping `PUBSUB_REALTIME_ENABLED`
  // swaps in the Cloud Pub/Sub adapter behind the same seam. The
  // WebSocket route still subscribes to the in-process publisher
  // (the multi-instance Pub/Sub → in-process consumer leg is a
  // downstream slice). The Pub/Sub message publisher callback is
  // the production-not-yet-wired stub below; the startup gate
  // immediately after the selector exits with 78 if the flag is on,
  // so production cannot accidentally route fan-out to a stub.
  final realtimeInProcessPublisher = InProcessRealtimePublisher();
  final realtimeOutboxListener = PackagePostgresOutboxListener.fromUrl(
    config.secretFor(ProxySecretNames.postgresUrl),
  );
  final realtimeOutboxRepository = EventOutboxRepository(
    TenantTransactionWrapper(productionBindings.tenantPool),
  );
  // Phase 10a.2 — dead-letter repository shares the tenant pool so
  // the MOVE CTE inherits the same `withTenant` boundary as the
  // claimBatch read; the per-tenant RLS policy admits both writes
  // inside the single transaction. Defaults to nullable on the
  // bridge worker so demo / scaffold callers without a dead-letter
  // table keep working.
  final realtimeDeadLetterRepository = EventOutboxDeadLetterRepository(
    TenantTransactionWrapper(productionBindings.tenantPool),
  );
  final realtimeAdminWrapper = TenantTransactionWrapper(
    productionBindings.adminPool,
  );
  // Phase 10a.4 — `/v1/realtime/tripwire-status` gateway. Reads the
  // four Q22 metrics through the admin pool's `runAsSystem` path
  // (platform-wide aggregate, no per-tenant filter). Threshold
  // overrides come from env vars; production runs the locked
  // Q22 numbers (overrides resolve to null and the evaluator falls
  // back to `kOutboxTripwireDefaultThresholds`).
  final realtimeTripwireGateway = PostgresRealtimeTripwireGateway(
    adminWrapper: realtimeAdminWrapper,
    now: DateTime.now,
    thresholdOverrides:
        resolveTripwireThresholdOverrides(Platform.environment),
  );
  // Phase 10a.5 — server-side replay seam. The route invokes this
  // closure when a client reconnects with `?last_event_id=<uuid>`.
  // The resolver delegates to the in-process publisher's per-(operator,
  // topic) ring buffer (default capacity 256) and the closure folds
  // its per-topic answers into the route's connection-wide
  // `RealtimeReplayResult`. If ANY topic returns the stale sentinel
  // the closure returns `truncated: true` so the route emits the
  // `replay_truncated` control envelope and the client refreshes
  // from Postgres on the affected tables.
  final realtimeReplayResolver = RealtimeReplayResolver(
    backlog: realtimeInProcessPublisher,
  );
  Future<RealtimeReplayResult> realtimeReplayFetcher({
    required OperatorContext scope,
    required String lastEventId,
    required Duration window,
  }) async {
    final topics = realtimeInProcessPublisher.topicsForOperator(
      scope.operatorId,
    );
    if (topics.isEmpty) {
      // Operator has no recent events in any topic ring. The cursor
      // is by definition unknown — fall through to the truncation
      // control envelope so the client refreshes instead of looping
      // on a stale id.
      return const RealtimeReplayResult(
        events: <RealtimeEvent>[],
        truncated: true,
      );
    }
    final merged = <RealtimeEvent>[];
    var truncated = false;
    for (final topic in topics) {
      final result = await realtimeReplayResolver.resolveMissedSince(
        operatorId: scope.operatorId,
        topic: topic,
        lastEventId: lastEventId,
        backlogWindow: window,
      );
      if (identical(result, RealtimeReplayStaleSentinel.instance)) {
        truncated = true;
        continue;
      }
      merged.addAll(result);
    }
    if (truncated) {
      // Route contract: when truncated, the events list is ignored.
      // We still drop it explicitly so a future refactor cannot leak
      // a partial replay into the wire path.
      return const RealtimeReplayResult(
        events: <RealtimeEvent>[],
        truncated: true,
      );
    }
    merged.sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
    return RealtimeReplayResult(
      events: List<RealtimeEvent>.unmodifiable(merged),
      truncated: false,
    );
  }

  final realtimeBridgePublisher = selectRealtimePublisher(
    environment: Platform.environment,
    inProcessPublisher: realtimeInProcessPublisher,
    pubsubMessagePublisher: _unwiredPubsubMessagePublisher,
    pubsubLogger: _logPubsubRealtimePublisherEvent,
  );
  if (realtimeBridgePublisher is PubsubRealtimePublisher) {
    // Fail-close startup gate: the locked-namespace check in the
    // PubsubRealtimePublisher constructor already passed (every
    // namespace resolves to a Pub/Sub topic name), but the message
    // publisher itself is still the unwired stub. Until the
    // production callback lands (Application Default Credentials,
    // GCP project + region, `gcloud_pubsub` SDK or REST), flipping
    // the flag in a real deploy must NOT silently route fan-out to
    // a stub. Operators remove the env flag, or land the production
    // adapter, then redeploy.
    log(
      LogSeverity.error,
      'startup.failed',
      fields: <String, Object?>{
        'phase': 'realtime_pubsub_message_publisher_unwired',
        'message':
            '$pubsubRealtimeEnabledEnvVar is set but the Pub/Sub '
            'message publisher adapter is not yet wired in this '
            'slice; remove the env flag for now or land the '
            'production Pub/Sub binding (Phase 10a follow-up).',
        'env_flag_name': pubsubRealtimeEnabledEnvVar,
        'resolved_topics': realtimeBridgePublisher.resolvedTopics,
        'exit_code': 78,
      },
    );
    exitCode = 78;
    return;
  }
  // Phase 10a.2 — resolve EVENT_OUTBOX_DLQ_CAP from env (default 5).
  // Operators raise this when triaging vendor-side outages and lower
  // it when the live queue is filling with poison-pill rows. The
  // bridge logs every dead-letter MOVE with attempt_count + cap so
  // log search can correlate cap changes with DLQ-rate changes.
  final realtimeDlqCap = resolveEventOutboxDlqCap(Platform.environment);
  // Phase 10a.4 — UPSERT writer for the publish-metrics minute
  // buckets. The bridge accumulates attempts/failures keyed by minute
  // and flushes deltas every 30s through the admin pool; the proxy
  // /health `event_outbox_publish_error_rate` producer reads the
  // rolling 5-minute sum from the table this writer populates.
  final realtimePublishMetricsWriter = _PostgresPublishMetricsWriter(
    adminWrapper: realtimeAdminWrapper,
  );
  final realtimeBridge = RealtimeBridgeWorker(
    listener: realtimeOutboxListener,
    outboxRepository: realtimeOutboxRepository,
    deadLetterRepository: realtimeDeadLetterRepository,
    publisher: realtimeBridgePublisher,
    locationResolver: _BootstrapLocationResolver(
      adminWrapper: realtimeAdminWrapper,
    ).resolve,
    operatorDiscoverer: _PostgresOperatorDiscoverer(
      adminWrapper: realtimeAdminWrapper,
    ).discover,
    dlqCap: realtimeDlqCap,
    publishMetricsWriter: realtimePublishMetricsWriter.write,
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

  // region: phase_9_8_email_routes
  // Phase 9.8 email-provider slice. Builds the SendGrid-backed
  // EmailProvider + 8 V1 templates + admin "Test connection"
  // route before the listener loop binds. The router pre-handles
  // POST /v1/admin/integrations/email/test inside the per-request
  // IIFE below; everything else falls through to routeRequest.
  //
  // Production secret names (server-side only per Hard Promise #7):
  //   * SENDGRID_API_KEY            — active SendGrid API key.
  //   * EMAIL_FROM_ADDRESS          — verified sender (defaults to
  //                                   noreply@mail.forgeflow.app).
  //   * EMAIL_FROM_DISPLAY_NAME     — sender display name (defaults
  //                                   to "Forge & Flow").
  //   * EMAIL_TEST_RECIPIENT        — fallback recipient for the
  //                                   admin Test Connection POST when
  //                                   the body omits recipient_email.
  //   * SENDGRID_SANDBOX_MODE       — when "true", every send sets
  //                                   mail_settings.sandbox_mode.enable
  //                                   so the staging key never burns
  //                                   real provider quota.
  //
  // The router is null when the email_templates directory is not
  // present in the deployed image. The listener loop treats null
  // as "no email surface installed" and falls through to
  // routeRequest, which today returns 404 for the email path. A
  // follow-up slice can extend this region to also wire the
  // email_outbox dispatcher (cron tick subscription) without
  // touching the rest of main.dart.
  final adminEmailRouter = buildProductionAdminEmailRouter(
    apiKey: Platform.environment['SENDGRID_API_KEY'] ?? '',
    fromAddress:
        Platform.environment['EMAIL_FROM_ADDRESS'] ??
        'noreply@mail.forgeflow.app',
    fromDisplayName:
        Platform.environment['EMAIL_FROM_DISPLAY_NAME'] ?? 'Forge & Flow',
    defaultRecipientEmail: Platform.environment['EMAIL_TEST_RECIPIENT'],
    sandboxMode:
        (Platform.environment['SENDGRID_SANDBOX_MODE'] ?? '')
            .trim()
            .toLowerCase() ==
        'true',
  );
  log(
    LogSeverity.info,
    'startup.email_router',
    fields: <String, Object?>{
      'mounted': adminEmailRouter != null,
      'sandbox_mode':
          (Platform.environment['SENDGRID_SANDBOX_MODE'] ?? '')
              .trim()
              .toLowerCase() ==
          'true',
      'sendgrid_api_key_loaded':
          (Platform.environment['SENDGRID_API_KEY'] ?? '').isNotEmpty,
    },
  );
  // endregion

  // Phase 8 — wire the inbound integration chain (vendor credential
  // broker, 17 per-tenant adapter factories, signature verifiers,
  // RepositoryInboundWebhookGateway, RepositoryIntegrationRoutesGateway)
  // before binding the listener. Demo mode (`--define=kDemoMode=true`)
  // makes this a no-op; otherwise the binder installs
  // `Phase80IntegrationRoutes.globalBindings` so the marked region in
  // the dispatch loop above lights up.
  await bindPhase8IntegrationsForProduction(
    productionBindings,
    config,
    proxyJwtVerifier: verifier,
  );

  // Phase 8 — operator-facing OAuth begin/callback + API-key connect.
  // Wires the per-vendor OAuth descriptors / token exchangers /
  // API-key validators built from the loaded ProxyConfig secret
  // bundle, plus a connection-writer adapter that funnels OAuth
  // bundles through `RepositoryIntegrationRoutesGateway.connect` and
  // first-backfill enqueues through
  // `productionBindings.firstConnectionBackfillEnqueueGateway`. Demo
  // mode skips this — the per-vendor adapter map is empty so the
  // dispatcher always returns 503 oauth_exchange_unconfigured.
  //
  // Boot order note (8.test-connection-executor-wire-in): the
  // production [VendorTestConnectionExecutor] needs the validator
  // map produced by [buildPhase8OperatorOAuthWiring], but the wiring
  // builder itself takes a `connectionWriter` that delegates to
  // `RepositoryIntegrationRoutesGateway.connect`. We break the cycle
  // by:
  //   1. Building the wiring against a writer that closes over a
  //      `late` gateway reference (resolved at call time, not at
  //      build time).
  //   2. Constructing the executor from the resulting validator map.
  //   3. Assigning the late `operatorOAuthGateway` with the executor
  //      threaded in. Subsequent calls to the writer closure resolve
  //      the now-final gateway instance.
  late final RepositoryIntegrationRoutesGateway operatorOAuthGateway;
  final operatorOAuthStateStore = PostgresIntegrationOAuthStateStore(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
    adminWrapper: TenantTransactionWrapper(productionBindings.adminPool),
  );
  Future<Map<String, Object?>> operatorOAuthConnectionWriter({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    required IntegrationCategory category,
    required String accessTokenPlaintext,
    String? refreshTokenPlaintext,
    DateTime? tokenExpiresAt,
    Map<String, Object?> metadata = const <String, Object?>{},
    String? webhookUrl,
    String? module,
    bool firstBackfillStarted = true,
  }) {
    return operatorOAuthGateway.connect(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      vendorId: vendorId,
      category: category,
      accessTokenPlaintext: accessTokenPlaintext,
      refreshTokenPlaintext: refreshTokenPlaintext,
      tokenExpiresAt: tokenExpiresAt,
      metadata: metadata,
      webhookUrl: webhookUrl,
      module: module,
      firstBackfillStarted: firstBackfillStarted,
    );
  }
  final operatorOAuthWiring = buildPhase8OperatorOAuthWiring(
    proxyConfig: config,
    connectionWriter: operatorOAuthConnectionWriter,
  );
  final operatorOAuthTestConnectionExecutor =
      Phase8IntegrationTestConnectionExecutor(
    apiKeyValidators: operatorOAuthWiring.apiKeyValidators,
  );
  operatorOAuthGateway = RepositoryIntegrationRoutesGateway(
    tenantWrapper: productionBindings.tenantTransactionWrapper,
    permissionGuard: productionBindings.adminPermissionGuard,
    credentialEnvelopeKey: productionBindings.pgcryptoEnvelopeKey,
    testConnectionExecutor: operatorOAuthTestConnectionExecutor,
  );
  IntegrationOAuthRoutes.globalBindings = _OperatorOAuthRoutesBindingsHolder(
    requestGuard: authGuard,
    stateStore: operatorOAuthStateStore,
    integrationRoutesGateway:
        wrapRepositoryGatewayForToolApi(operatorOAuthGateway),
    connectionWriter: operatorOAuthWiring.connectionWriter,
    oauthBeginDescriptors: operatorOAuthWiring.oauthBeginDescriptors,
    oauthExchangers: operatorOAuthWiring.oauthExchangers,
    apiKeyValidators: operatorOAuthWiring.apiKeyValidators,
    firstBackfillEnqueueGateway:
        productionBindings.firstConnectionBackfillEnqueueGateway,
    integrationCategoryResolver: productionBindings.integrationCategoryResolver,
    operatorUiBaseUri: config.publicBaseUri,
  );

  // Phase 8 — operator-self-service vendor connections list. The
  // projection runs inside the operator's tenant transaction (RLS +
  // SET LOCAL guarded) and emits the wire-shape JSON the operator-web
  // Connections screen expects. The route layer in `routeRequest`
  // gates on the operator's integration permissions BEFORE invoking
  // this closure, so the projection itself does not re-check.
  final connectorConnectionListRepository = ConnectorConnectionListRepository(
    productionBindings.tenantTransactionWrapper,
  );
  Future<Map<String, Object?>> operatorLocationIntegrationsProjection({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) async {
    final bundle = await connectorConnectionListRepository.listForLocation(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
    );
    return buildOperatorLocationIntegrationsBundleJson(bundle);
  }
  log(
    LogSeverity.info,
    'startup.operator_oauth_routes.installed',
    fields: <String, Object?>{
      'oauth_descriptors_wired': operatorOAuthWiring
          .oauthBeginDescriptors.keys
          .toList()
        ..sort(),
      'oauth_exchangers_wired': operatorOAuthWiring.oauthExchangers.keys
          .toList()
        ..sort(),
      'api_key_validators_wired': operatorOAuthWiring.apiKeyValidators.keys
          .toList()
        ..sort(),
      'disabled_vendors': operatorOAuthWiring.disabledVendors,
    },
  );

  final server = await HttpServer.bind(InternetAddress.anyIPv4, config.port);

  // CODE_HEALTH L4 — graceful shutdown.
  //
  // SIGTERM / SIGINT trigger an orderly drain instead of dropping
  // in-flight requests. The handler:
  //   1. Stops the every-5-minute admin-idempotency sweeper Timer.
  //   2. Closes the HTTP listener (force: false → no new connections,
  //      existing requests run to completion).
  //   3. Bounds the wait at 25 seconds so Cloud Run's 30s SIGKILL
  //      deadline still has slack for `exit(0)` to run.
  //   4. Notes that audit-log writes are committed synchronously per
  //      request (no async drain queue), and `ProxyUsageCounterStore`
  //      writes through `incrementOnAllow` are also synchronous —
  //      neither has a flush API to call. ProxyUsageCounterStore and
  //      audit-log queues drain as a no-op.
  //   5. exit(0).
  //
  // Wired BEFORE the listener loop so an in-flight signal during
  // bootstrap also lands a clean exit.
  final adminIdempotencySweepTimer = Timer.periodic(
    const Duration(minutes: 5),
    (_) async {
      try {
        await productionBindings.adminRequestIdempotencyStore
            .sweepExpiredOrphans();
      } catch (error, stack) {
        log(
          LogSeverity.warning,
          'admin_idempotency.sweep_failed',
          fields: <String, Object?>{
            'error_type': error.runtimeType.toString(),
            'error_message': error.toString(),
            'stack_first_frame': firstStackFrame(stack),
          },
        );
      }
    },
  );

  var shutdownInProgress = false;
  Future<void> handleShutdownSignal(String signalName) async {
    if (shutdownInProgress) return;
    shutdownInProgress = true;
    log(
      LogSeverity.info,
      'shutdown.signal_received',
      fields: <String, Object?>{'signal': signalName},
    );
    adminIdempotencySweepTimer.cancel();
    // Audit-log writes are committed synchronously inside each
    // request (see `AuditLogsRepository.append…` paths through the
    // tenant transaction wrapper); there is no async drain queue
    // that needs flushing. Same posture for ProxyUsageCounterStore
    // — `incrementOnAllow` is a synchronous Postgres UPSERT per
    // request, not a buffered batch. No flush API exists; nothing
    // to call here.
    await Future.any(<Future<void>>[
      server.close(force: false),
      Future<void>.delayed(const Duration(seconds: 25)),
    ]);
    log(
      LogSeverity.info,
      'shutdown.complete',
      fields: <String, Object?>{'signal': signalName},
    );
    exit(0);
  }

  ProcessSignal.sigterm.watch().listen(
    (_) => unawaited(handleShutdownSignal('SIGTERM')),
  );
  ProcessSignal.sigint.watch().listen(
    (_) => unawaited(handleShutdownSignal('SIGINT')),
  );

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
      'data_accuracy_admin': 'postgres',
      'corpus_admin': 'postgres',
      'integration_admin': 'postgres_kms_stub',
      'feature_flags_admin': 'postgres',
      'debug_console_admin': 'postgres',
      'observability_admin': 'postgres',
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
    // Each request is independent: failures in one must not crash
    // the listener loop, and long-lived WebSockets must not queue probes.
    unawaited(
      (() async {
        try {
          // region: phase_9_8_email_routes
          // Pre-check: email-provider routes (today: POST
          // /v1/admin/integrations/email/test) short-circuit the
          // monolithic dispatcher so the integrations seam stays
          // untouched. The router writes its own JSON response and
          // closes the HTTP response; we early-return so the rest
          // of routeRequest does not fire on the same request.
          if (adminEmailRouter != null &&
              await adminEmailRouter.tryHandle(request)) {
            return;
          }
          // endregion
          // region: phase_8_0_integration_routes
          // Phase 8.0 — Inbound integration framework router. Handles
          // /v1/admin/operators/:opid/locations/:locid/integrations,
          // /v1/admin/integrations/oauth|connect-key|test-connection|
          // disconnect|logs/{vendor}, and /v1/webhooks/{vendor}/...
          // paths. Returns true when the path matched and was handled;
          // returns false on non-Phase-8.0 paths so we fall through to
          // the existing dispatcher. The router lives outside
          // `routeRequest` so the existing dispatcher stays untouched
          // per the slice scope rule. The bindings holder is set
          // by a follow-up slice (real Postgres-backed gateway +
          // adapter map); until then `tryHandleStatic` is a noop
          // pass-through that returns false.
          if (await Phase80IntegrationRoutes.tryHandleStatic(request)) {
            return;
          }
          // endregion
          // region: phase_8_operator_oauth_routes
          // Phase 8 — operator-facing OAuth begin/callback +
          // API-key connect. Handles
          // /v1/integrations/oauth/{vendor}/begin,
          // /v1/integrations/oauth/{vendor}/callback,
          // /v1/integrations/api-key/{vendor}/connect.
          // Returns true when the path matched and was handled;
          // returns false on non-matching paths so we fall through
          // to the existing dispatcher. The bindings holder is set
          // by a follow-up slice that wires per-vendor OAuth
          // descriptors + token exchangers; until then
          // `tryHandleStatic` returns false on every request.
          if (await IntegrationOAuthRoutes.tryHandleStatic(request)) {
            return;
          }
          // endregion
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
            operatorLocationIntegrationsProjection:
                operatorLocationIntegrationsProjection,
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
            mfaRecoveryRequestGateway:
                productionBindings.mfaRecoveryRequestGateway,
            mobilePushTokenGateway: productionBindings.mobilePushTokenGateway,
            mobilePushSelfTestGateway:
                productionBindings.mobilePushSelfTestGateway,
            mobileOperationalSyncGateway:
                productionBindings.mobileOperationalSyncGateway,
            businessScopeGateway: productionBindings.businessScopeGateway,
            operatorLocationAdminGateway:
                productionBindings.operatorLocationAdminGateway,
            pricingTierAdminGateway: productionBindings.pricingTierAdminGateway,
            dataAccuracyAdminGateway:
                productionBindings.dataAccuracyAdminGateway,
            corpusAdminGateway: productionBindings.corpusAdminGateway,
            graphCandidatesGateway: productionBindings.graphCandidatesGateway,
            integrationAdminGateway: productionBindings.integrationAdminGateway,
            integrationAdminActorResolver:
                productionBindings.integrationAdminActorResolver,
            featureFlagsAdminGateway:
                productionBindings.featureFlagsAdminGateway,
            debugConsoleAdminGateway:
                productionBindings.debugConsoleAdminGateway,
            observabilityAdminGateway:
                productionBindings.observabilityAdminGateway,
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
            realtimePublisher: realtimeInProcessPublisher,
            // Phase 10a.5 — replay fetcher closure feeds missed events
            // BEFORE live frames when the client reconnects with
            // `?last_event_id=<uuid>`.
            realtimeReplayFetcher: realtimeReplayFetcher,
            // Phase 10a.4 — `/v1/realtime/tripwire-status` gateway.
            // Read-only platform-wide aggregate; the sync badge polls
            // this every ~60s so it can shift to "Degraded" when ANY
            // Q22 metric fires red even while the WebSocket itself is
            // alive. Threshold overrides come from env vars (demo
            // walkthrough only); production runs the locked Q22
            // numbers.
            realtimeTripwireGateway: realtimeTripwireGateway,
            // Phase 11W.7 / Wave A2 - operator-scoped write router
            // for the five `/v1/operator/...` business-timing +
            // account routes. Without this binding the routes return
            // 503 operator_write_router_not_configured.
            operatorWriteRouter: productionBindings.operatorWriteRouter,
            // Operator Web W4.B - per-tenant audit-chain-anchor read
            // gateway for the operator-web Audit Log integrity badge.
            // Without this binding the route returns 503
            // audit_chain_anchors_not_configured.
            auditChainAnchorsGateway:
                productionBindings.auditChainAnchorsGateway,
            // Wave W2.D - operator-scoped read of
            // `connector_backfill_jobs`. Without this binding the
            // route returns 503 connector_backfill_jobs_router_not_configured.
            connectorBackfillJobsRouter:
                productionBindings.connectorBackfillJobsRouter,
            // Phase 8 W2.B - per-actor notification preferences
            // router for the three `/v1/operator/notification-
            // preferences` routes. Without this binding the routes
            // return 503 notification_preferences_router_not_configured.
            notificationPreferencesRouter:
                productionBindings.notificationPreferencesRouter,
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
      })(),
    );
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

/// Phase 10a.4 — production writer for the bridge's publish-metrics
/// minute buckets. Runs through the admin pool (`runAsSystem`)
/// because `event_outbox_publish_metrics` is platform-wide
/// bookkeeping (no per-tenant row, no RLS); the producer that reads
/// it does the same.
///
/// The single-transaction batch UPSERT is intentional: a flush of N
/// buckets ships in one round-trip, with a `DO UPDATE SET ... =
/// table.col + EXCLUDED.col` so a slow flush followed by a fast
/// flush in the same minute bucket sums correctly. The
/// `failed_publish_count <= attempted_publish_count` CHECK at the
/// migration level holds because the bridge always increments
/// attempted before optionally incrementing failed.
class _PostgresPublishMetricsWriter {
  _PostgresPublishMetricsWriter({required TenantTransactionWrapper adminWrapper})
      : _adminWrapper = adminWrapper;

  final TenantTransactionWrapper _adminWrapper;

  Future<void> write(
    List<RealtimeBridgePublishMetricsBucket> buckets,
  ) async {
    if (buckets.isEmpty) return;
    await _adminWrapper.runAsSystem<void>(
      (exec) async {
        for (final bucket in buckets) {
          await exec.execute(
            'insert into event_outbox_publish_metrics ('
            '  window_start, attempted_publish_count, '
            '  failed_publish_count, updated_at'
            ') '
            'values ('
            '  @window_start::timestamptz, '
            '  @attempted::bigint, '
            '  @failed::bigint, '
            '  now()'
            ') '
            'on conflict (window_start) do update set '
            '  attempted_publish_count = '
            '    event_outbox_publish_metrics.attempted_publish_count '
            '    + excluded.attempted_publish_count, '
            '  failed_publish_count = '
            '    event_outbox_publish_metrics.failed_publish_count '
            '    + excluded.failed_publish_count, '
            '  updated_at = now()',
            parameters: <String, Object?>{
              'window_start': bucket.windowStart.toUtc().toIso8601String(),
              'attempted': bucket.attemptedDelta,
              'failed': bucket.failedDelta,
            },
          );
        }
      },
      reason: 'realtime_bridge_publish_metrics_flush',
    );
  }
}

/// Phase 10a.0 — funnel bridge worker log events into the structured
/// log() helper. Names only — the operator id is fine to log
/// (already in the request log context elsewhere); errors are
/// stringified.
///
/// Phase 10a.2 — `deadLettered` + `deadLetterMoveFailed` carry
/// attempt_count + cap so log search can spot rows that crossed the
/// cap and rows whose MOVE failed transiently.
///
/// Phase 10a.4 — `publishMetricsFlushFailed` surfaces writer-side
/// errors so log search can alarm when the
/// `event_outbox_publish_error_rate` producer is stale because the
/// writer (not the producer) is broken.
void _logRealtimeBridgeEvent(RealtimeBridgeLogEvent event) {
  final fields = <String, Object?>{
    if (event.operatorId != null) 'operator_id': event.operatorId,
    if (event.outboxId != null) 'outbox_id': event.outboxId,
    if (event.topic != null) 'topic': event.topic,
    if (event.attemptCount != null) 'attempt_count': event.attemptCount,
    if (event.cap != null) 'dlq_cap': event.cap,
    if (event.error != null) 'error_type': event.error.runtimeType.toString(),
    if (event.error != null) 'error_message': event.error.toString(),
    if (event.stack != null) 'stack_first_frame': firstStackFrame(event.stack!),
  };
  switch (event.kind) {
    case RealtimeBridgeLogKind.listenerError:
      log(
        LogSeverity.warning,
        'realtime.bridge.listener_error',
        fields: fields,
      );
    case RealtimeBridgeLogKind.discoveryFailed:
      log(
        LogSeverity.warning,
        'realtime.bridge.discovery_failed',
        fields: fields,
      );
    case RealtimeBridgeLogKind.locationResolveFailed:
      log(
        LogSeverity.warning,
        'realtime.bridge.location_resolve_failed',
        fields: fields,
      );
    case RealtimeBridgeLogKind.claimFailed:
      log(LogSeverity.warning, 'realtime.bridge.claim_failed', fields: fields);
    case RealtimeBridgeLogKind.publishFailed:
      log(
        LogSeverity.warning,
        'realtime.bridge.publish_failed',
        fields: fields,
      );
    case RealtimeBridgeLogKind.markDeliveredFailed:
      log(
        LogSeverity.warning,
        'realtime.bridge.mark_delivered_failed',
        fields: fields,
      );
    case RealtimeBridgeLogKind.deadLettered:
      log(LogSeverity.warning, 'realtime.bridge.dead_lettered', fields: fields);
    case RealtimeBridgeLogKind.deadLetterMoveFailed:
      log(
        LogSeverity.warning,
        'realtime.bridge.dead_letter_move_failed',
        fields: fields,
      );
    case RealtimeBridgeLogKind.publishMetricsFlushFailed:
      log(
        LogSeverity.warning,
        'realtime.bridge.publish_metrics_flush_failed',
        fields: fields,
      );
  }
}

/// Phase 10a.1 — funnel `PubsubRealtimePublisher` log events into the
/// canonical `log()` helper. Mirrors `_logRealtimeBridgeEvent` so the
/// existing realtime metric path absorbs the Pub/Sub publisher's
/// envelope without a new log shape (no new health producer).
void _logPubsubRealtimePublisherEvent(PubsubRealtimePublisherLogEvent event) {
  final fields = <String, Object?>{
    if (event.operatorId != null) 'operator_id': event.operatorId,
    if (event.eventId != null) 'event_id': event.eventId,
    if (event.topic != null) 'topic': event.topic,
    if (event.topicName != null) 'pubsub_topic_name': event.topicName,
    if (event.error != null) 'error_type': event.error.runtimeType.toString(),
    if (event.error != null) 'error_message': event.error.toString(),
    if (event.stack != null) 'stack_first_frame': firstStackFrame(event.stack!),
  };
  switch (event.kind) {
    case PubsubRealtimePublisherLogKind.published:
      log(LogSeverity.info, 'realtime.publisher.published', fields: fields);
    case PubsubRealtimePublisherLogKind.publishFailed:
      log(
        LogSeverity.warning,
        'realtime.publisher.publish_failed',
        fields: fields,
      );
  }
}

/// Phase 10a.1 — production-not-yet-wired Pub/Sub message publisher
/// stub. The `PUBSUB_REALTIME_ENABLED` startup gate exits 78 before
/// this is ever invoked, so it is defensive only. Once the production
/// adapter (Application Default Credentials, GCP project + region,
/// `gcloud_pubsub` SDK or REST) lands in a follow-up slice, this stub
/// is replaced with the real callback and the startup gate is removed.
Future<void> _unwiredPubsubMessagePublisher({
  required String topicName,
  required String body,
  required Map<String, String> attributes,
}) async {
  throw StateError(
    'PubsubMessagePublisher invoked before the production adapter '
    'is wired. The startup gate in tool/advisor_proxy/main.dart '
    'should have exited 78 before reaching this call. Either remove '
    'the env flag or land the production adapter.',
  );
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

/// Production [IntegrationOAuthRoutesBindingsHolder] backed by the
/// resolved per-vendor OAuth descriptors / exchangers / API-key
/// validators + the `RepositoryIntegrationRoutesGateway` connect
/// adapter. The proxy bootstrap installs a single instance once at
/// startup; the listener loop's marked region calls into
/// `IntegrationOAuthRoutes.tryHandleStatic` on every request.
class _OperatorOAuthRoutesBindingsHolder
    implements IntegrationOAuthRoutesBindingsHolder {
  _OperatorOAuthRoutesBindingsHolder({
    required this.requestGuard,
    required this.stateStore,
    required this.integrationRoutesGateway,
    required this.connectionWriter,
    required this.oauthBeginDescriptors,
    required this.oauthExchangers,
    required this.apiKeyValidators,
    required this.firstBackfillEnqueueGateway,
    required this.integrationCategoryResolver,
    required this.operatorUiBaseUri,
  }) : stateTokenTtl = const Duration(minutes: 10);

  @override
  final ProxyRequestGuard requestGuard;
  @override
  final IntegrationOAuthStateStore stateStore;
  @override
  final IntegrationRoutesGateway integrationRoutesGateway;
  @override
  final IntegrationOAuthConnectionWriter connectionWriter;
  @override
  final Map<String, VendorOAuthBeginDescriptor> oauthBeginDescriptors;
  @override
  final Map<String, VendorOAuthCodeExchanger> oauthExchangers;
  @override
  final Map<String, VendorApiKeyValidator> apiKeyValidators;
  @override
  final FirstConnectionBackfillEnqueueGateway? firstBackfillEnqueueGateway;
  @override
  final IntegrationCategoryResolver? integrationCategoryResolver;
  @override
  final Uri? operatorUiBaseUri;
  @override
  final Duration stateTokenTtl;
}
