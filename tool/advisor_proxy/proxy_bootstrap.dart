// Forge & Flow advisor proxy bootstrap helpers.
//
// Kept separate from `main.dart` so production wiring can be tested
// without binding a socket or opening a live database connection.

import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:google_generative_ai/google_generative_ai.dart' as gemini;
import 'package:path/path.dart' as p;

import 'package:forge_and_flow/infrastructure/persistence/postgres/advisor_proxy_usage_counter_store.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/active_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_invites_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_login_attempts_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_sessions_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/business_timing_profiles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/connector_backfill_job_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/forecast_context_repository.dart'
    as weekly_forecast;
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/operator_account_repository.dart';
import 'package:forge_and_flow/services/business_timing/production_operator_write_audit_sink.dart';
import 'package:forge_and_flow/services/business_timing/repository_operator_write_gateways.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/corpus_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/feature_flags_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/graph_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/locations_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_factor_removal_requests_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_recovery_request_attempts_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mobile_push_tokens_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/operator_admins_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/operators_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/org_units_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/password_history_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/provider_credentials_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/selected_star_shift_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/target_cycle_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/weekly_plan_snapshot_repository.dart'
    as weekly_snapshot;
import 'package:forge_and_flow/infrastructure/cloud_run/cloud_run_admin_client.dart';
import 'package:forge_and_flow/infrastructure/kms/gcp_secret_manager_kms_provider.dart';
import 'package:forge_and_flow/infrastructure/kms/kms_lane_router.dart';
import 'package:forge_and_flow/infrastructure/kms/kms_stub_provider.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/kms_rollout_flag.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/role_permissions_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/roles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/usage_caps_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/user_roles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/auth/permission_resolution.dart';
import 'package:forge_and_flow/domain/models/business_timing_profile.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/domain/models/forge_flow_polling_tier_assignment.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/business_timing_profile_resolver.dart';
import 'package:forge_and_flow/services/auth/account_info_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';
import 'package:forge_and_flow/services/auth/hibp_pwned_password_screener.dart';
import 'package:forge_and_flow/services/auth/password_change_gateway.dart';
import 'package:forge_and_flow/services/auth/password_reset_confirm_gateway.dart';
import 'package:forge_and_flow/services/auth/password_reset_request_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';
import 'package:forge_and_flow/services/auth/rate_limited_hibp_range_fetcher.dart';
import 'package:forge_and_flow/services/auth/repository_auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/repository_auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/repository_account_info_gateway.dart';
import 'package:forge_and_flow/services/auth/repository_password_change_gateway.dart';
import 'package:forge_and_flow/services/auth/repository_password_history_check.dart';
import 'package:forge_and_flow/services/mfa/firebase_mfa_enrollment_service.dart';
import 'package:forge_and_flow/services/mfa/identity_toolkit_firebase_mfa_client.dart';
import 'package:forge_and_flow/services/mfa/mfa_operations_gateway.dart';
import 'package:forge_and_flow/services/mfa/mfa_recovery_request_gateway.dart';
import 'package:forge_and_flow/services/mfa/mfa_removal_worker.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart'
    as integration;
import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/integration/polling_tier_presets.dart';

import '../advisor_corpus/advisor_corpus.dart'
    show
        CorpusManifest,
        defaultGraphifyCandidatesOutputDirectory,
        defaultManifestPath,
        graphifyCandidateManifestFileName,
        graphifyEdgeCandidatesFileName,
        graphifyNodeCandidatesFileName;
import 'advisor_proxy.dart';
import 'admin_integrations_routes.dart';
import 'anthropic_http_complete_fn.dart';
import 'health_producers/producer_registry.dart';
import 'log.dart';
import 'mobile_push_notifications.dart';
import 'vendor_admin_status_catalog.dart' as vendor_status;

typedef PostgresPoolFactory = PostgresPool Function(String connectionString);

/// HARD-A — early-exit decision for the proxy entrypoint.
///
/// When non-null, the entrypoint should write [message] to stderr and
/// exit with [exitCode]. The wrapper exists so the prod-required-
/// Firebase check is testable without binding a socket or invoking
/// `dart run` in a subprocess.
class ProxyStartupFailure {
  const ProxyStartupFailure({required this.message, required this.exitCode});

  final String message;
  final int exitCode;
}

/// HARD-A — `PROXY_ENVIRONMENT=prod` requires `FIREBASE_PROJECT_ID`.
///
/// Falling back to `ScaffoldRejectingJwtVerifier` in production would
/// mean every authenticated route returns 401 with the proxy still
/// bound and serving traffic — a worse failure mode than refusing to
/// start. Returns a [ProxyStartupFailure] with EX_CONFIG (78) so the
/// deploy surfaces the misconfiguration loudly. Returns `null` in
/// `staging` / `dev` (or any other value, including unset / blank) so
/// local boots still work without the Firebase project ID.
ProxyStartupFailure? evaluateProxyStartup({
  required ProxyConfig config,
  required Map<String, String> environment,
}) {
  final proxyEnvironment = (environment['PROXY_ENVIRONMENT'] ?? '')
      .trim()
      .toLowerCase();
  if (proxyEnvironment == 'prod' && config.firebaseProjectId == null) {
    return const ProxyStartupFailure(
      message: 'startup_failure: firebase_project_id_required_in_prod',
      exitCode: 78,
    );
  }
  return null;
}

class ProxyProductionBindings {
  const ProxyProductionBindings({
    required this.accountingStore,
    required this.authSessionLedgerWriter,
    required this.firebaseAdminAuthClient,
    required this.accountInfoGateway,
    required this.permissionSnapshotResolver,
    required this.adminPermissionGuard,
    required this.authOperationsGateway,
    required this.servicePrincipalJwtIssuanceGateway,
    required this.passwordChangeGateway,
    required this.passwordResetConfirmGateway,
    required this.passwordResetRequestGateway,
    required this.mfaOperationsGateway,
    required this.mfaRecoveryRequestGateway,
    required this.mfaRemovalWorker,
    required this.mobilePushTokenGateway,
    required this.mobilePushSelfTestGateway,
    required this.mobileOperationalSyncGateway,
    required this.businessScopeGateway,
    required this.operatorLocationAdminGateway,
    required this.pricingTierAdminGateway,
    required this.dataAccuracyAdminGateway,
    required this.corpusAdminGateway,
    required this.graphCandidatesGateway,
    required this.integrationAdminGateway,
    required this.integrationAdminActorResolver,
    required this.firstConnectionBackfillEnqueueGateway,
    required this.integrationCategoryResolver,
    required this.featureFlagsAdminGateway,
    required this.debugConsoleAdminGateway,
    required this.observabilityAdminGateway,
    required this.adminCorsOriginsExtraFlag,
    required this.adminRequestIdempotencyStore,
    required this.llmProvider,
    required this.secondaryLlmProvider,
    required this.geminiSlotEnabled,
    required this.usageCounterStore,
    required this.healthCheckStore,
    required this.tenantPool,
    required this.adminPool,
    required this.authLockoutEnforcer,
    required this.authLockoutAuditSink,
    required this.mfaTotpRetryCounter,
    required this.passwordResetThrottleCounter,
    required this.operatorWriteRouter,
  });

  /// HARD-G observability: tenant-scope pool exposed for the startup
  /// connectivity probe in `main.dart`. The probe opens + commits one
  /// trivial transaction so a slow / broken Postgres surfaces as
  /// `DependencyTimeoutException` and the proxy exits 78 instead of
  /// binding the listener and degrading every request.
  final PostgresPool tenantPool;

  /// Admin-scope pool, exposed for the same startup probe.
  final PostgresPool adminPool;

  final ProxyAccountingStore accountingStore;
  final AuthSessionLedgerWriter authSessionLedgerWriter;
  final FirebaseAdminAuthClient firebaseAdminAuthClient;
  final AccountInfoGateway accountInfoGateway;
  final ProxyPermissionSnapshotResolver permissionSnapshotResolver;
  final ProxyAdminPermissionGuard adminPermissionGuard;
  final AuthOperationsGateway authOperationsGateway;
  final ServicePrincipalJwtIssuanceGateway servicePrincipalJwtIssuanceGateway;
  final PasswordChangeGateway passwordChangeGateway;
  final PasswordResetConfirmGateway passwordResetConfirmGateway;
  final PasswordResetRequestGateway passwordResetRequestGateway;
  final MfaOperationsGateway mfaOperationsGateway;
  final MfaRecoveryRequestGateway mfaRecoveryRequestGateway;
  final MfaRemovalWorker mfaRemovalWorker;
  final MobilePushTokenGateway? mobilePushTokenGateway;
  final MobilePushSelfTestGateway? mobilePushSelfTestGateway;
  final MobileOperationalSyncProxyGateway mobileOperationalSyncGateway;
  final BusinessScopeProxyGateway businessScopeGateway;
  final OperatorLocationAdminProxyGateway operatorLocationAdminGateway;
  final PricingTierAdminProxyGateway pricingTierAdminGateway;
  final DataAccuracyAdminProxyGateway dataAccuracyAdminGateway;
  final CorpusAdminProxyGateway corpusAdminGateway;
  final GraphCandidatesProxyGateway graphCandidatesGateway;
  final IntegrationAdminProxyGateway integrationAdminGateway;
  final IntegrationAdminActorResolver integrationAdminActorResolver;
  final FirstConnectionBackfillEnqueueGateway
  firstConnectionBackfillEnqueueGateway;
  final IntegrationCategoryResolver integrationCategoryResolver;

  /// Phase 11A.7 — feature flags admin gateway. Backed by
  /// [FeatureFlagsRepository] (admin pool, system scope) plus the
  /// admin-pool [AuthEventsAuditRepository] for the toggle audit row
  /// (which fans out to `audit_logs` per the `audit_logs_cutover_enabled`
  /// flag).
  final FeatureFlagsAdminProxyGateway featureFlagsAdminGateway;
  final DebugConsoleAdminProxyGateway debugConsoleAdminGateway;
  final ObservabilityAdminProxyGateway observabilityAdminGateway;

  /// HARD-C — Postgres-backed gate for the supplemental admin CORS
  /// allow-list. `main.dart` awaits this flag at startup; when
  /// enabled, [resolveAdminCorsAllowList] merges
  /// [ProxyConfig.adminCorsAllowedOriginsExtraFromEnv] into the
  /// active list. Backed by [FeatureFlagsTableAdminCorsOriginsExtraFlag]
  /// against the admin pool.
  final AdminCorsOriginsExtraFlag adminCorsOriginsExtraFlag;

  /// HARD-H — admin idempotency cache backed by
  /// `public.admin_request_idempotency`. The router uses this to dedupe
  /// duplicate `Idempotency-Key` headers on admin POST routes (today:
  /// feature flags toggle), so a retry returns the cached response
  /// instead of re-executing the gateway.
  final AdminRequestIdempotencyStore adminRequestIdempotencyStore;

  /// Phase 11A.4b — primary LLM provider feeding the
  /// `AdvisorRequestPipeline`. Real Anthropic Messages API HTTP
  /// adapter; the breaker wraps this and trips on consecutive
  /// failures.
  final ProxyLlmProvider llmProvider;

  /// Phase 11A.4b — Gemini Flash secondary used by the pipeline when
  /// Anthropic fails or the breaker is open. Null when
  /// `GEMINI_API_KEY` is unset (pipeline reduces to anthropic →
  /// cache → refusal).
  final ProxyLlmProvider? secondaryLlmProvider;

  /// True when GEMINI_API_KEY was loaded at startup. Surfaces to the
  /// diagnostics line in main.dart so a startup grep can confirm
  /// which fallback slots are armed without echoing the key.
  final bool geminiSlotEnabled;

  /// HARD-A — Postgres-backed usage counter store reading + writing
  /// `public.advisor_proxy_usage_counters`. The launch tier's per-minute
  /// request and monthly cost caps fail closed against this store; a
  /// store-side failure surfaces as `usage_store_unavailable` (HTTP 503)
  /// from [ProxyUsageGuard].
  final ProxyUsageCounterStore usageCounterStore;

  /// HARD-A — registry-backed health check store driving `/health`.
  /// Producers run through a bounded concurrency lane; reserved
  /// metrics from `proxy_health_contract.md` whose producers have not
  /// landed yet (B43 / B44 / B45 / B47) project to `status: unknown`
  /// without making the response degraded.
  final ProxyHealthCheckStore healthCheckStore;

  /// HARD-B - lockout enforcer backed by `auth_login_attempts` (admin
  /// pool, system + tenant scopes). The proxy login route consults
  /// this on every credential attempt to enforce the 5/15min lockout.
  final AuthLockoutEnforcer authLockoutEnforcer;

  /// HARD-B - audit sink for the four new auth lockout events
  /// (`auth.login_failed`, `auth.account_locked`,
  /// `auth.mfa_retry_exceeded`, `auth.password_reset_throttled`).
  /// Production fans these into the hash-chained `audit_logs` table.
  final AuthLockoutAuditSink authLockoutAuditSink;

  /// HARD-B - in-memory rolling-window counter for the per-challenge
  /// MFA TOTP retry cap (3 / per-challenge). Volatile across proxy
  /// restarts; the in-memory shape matches the HARD-D feature-flag
  /// idempotency cache discipline.
  final RollingWindowAttemptCounter mfaTotpRetryCounter;

  /// HARD-B - in-memory rolling-window counter for the per-account
  /// password-reset 24h cap (10 / 24h). Volatile across proxy
  /// restarts.
  final RollingWindowAttemptCounter passwordResetThrottleCounter;

  /// Phase 11W.7 / Wave A2 - operator-scoped write router. Handles
  /// the five `/v1/operator/...` business-timing + account routes
  /// behind shared auth (operator owner / admin), Idempotency-Key
  /// enforcement, and audit-log fan-out. Wired through
  /// [RepositoryOperatorAccountWriteGateway] +
  /// [RepositoryOperatorBusinessTimingWriteGateway] +
  /// [ProductionOperatorWriteAuditSink].
  final OperatorWriteRouter operatorWriteRouter;
}

// ─── Phase 11A.4b — Production proxy LLM providers ──────────────────────────

/// Production callback that drives the `google_generative_ai` SDK.
/// Streams chunks via `generateContentStream` so [onChunk] fires once
/// per chunk; the returned future resolves to a
/// [ProxyLlmCompletePayload] carrying the concatenated text plus real
/// input/output token counts pulled from the SDK's `usageMetadata`.
///
/// Applies a [chunkTimeout] per stream chunk so a wedged Gemini stream
/// fails fast instead of blocking the request.
///
/// Server-side ONLY — every caller of this fn lives under
/// `tool/advisor_proxy/`. Hard Promise #7 in CLAUDE.md.
GeminiProxyCompleteFn buildGeminiSdkCompleteFn({
  required String apiKey,
  Duration chunkTimeout = const Duration(seconds: 30),
}) {
  return ({
    required String modelId,
    required String question,
    required String context,
    void Function(String chunk)? onChunk,
  }) async {
    final model = gemini.GenerativeModel(
      model: modelId,
      apiKey: apiKey,
      systemInstruction: context.isEmpty
          ? null
          : gemini.Content.system(context),
    );
    final stream = model
        .generateContentStream(<gemini.Content>[gemini.Content.text(question)])
        .timeout(chunkTimeout);
    final buffer = StringBuffer();
    // Usage metadata is typically only populated on the FINAL streamed
    // chunk. Track the most recent non-null reading and consume it
    // after the stream drains so partial-stream surfaces still report
    // whatever the SDK gave us last.
    gemini.UsageMetadata? lastUsage;
    await for (final response in stream) {
      if (response.usageMetadata != null) {
        lastUsage = response.usageMetadata;
      }
      final text = response.text;
      if (text != null && text.isNotEmpty) {
        buffer.write(text);
        onChunk?.call(text);
      }
    }
    return ProxyLlmCompletePayload(
      text: buffer.toString(),
      inputTokens: lastUsage?.promptTokenCount ?? 0,
      outputTokens: lastUsage?.candidatesTokenCount ?? 0,
    );
  };
}

/// Build the production LLM providers from [config]. Always wires the
/// Anthropic primary to the real Messages API HTTP adapter using
/// `ANTHROPIC_API_KEY`. When `GEMINI_API_KEY` is loaded, also wires
/// the live Gemini secondary; otherwise the secondary is null and
/// the pipeline reduces to anthropic → cache → refusal.
({
  ProxyLlmProvider primary,
  ProxyLlmProvider? secondary,
  bool geminiSlotEnabled,
})
buildProxyLlmProviders(ProxyConfig config) {
  final primary = AnthropicProxyLlmProvider(
    completeFn: buildAnthropicHttpCompleteFn(
      apiKey: config.secretFor(ProxySecretNames.anthropicApiKey),
    ),
  );
  ProxyLlmProvider? secondary;
  final hasGeminiKey = config.hasSecretFor(ProxySecretNames.geminiApiKey);
  if (hasGeminiKey) {
    secondary = GeminiProxyLlmProvider(
      completeFn: buildGeminiSdkCompleteFn(
        apiKey: config.secretFor(ProxySecretNames.geminiApiKey),
      ),
    );
  }
  return (
    primary: primary,
    secondary: secondary,
    geminiSlotEnabled: hasGeminiKey,
  );
}

/// Builds all Phase 9 production route bindings without opening network or
/// database connections. Live I/O begins only when a request invokes one of the
/// returned gateways.
///
/// HARD-A: [requireFirebase] gates whether the Firebase Identity Platform
/// admin client is mandatory. Default `true` matches the historical
/// production posture — every auth-required route surfaces 503 / cap-
/// reached without a real client. Pass `false` from the entrypoint when
/// running in `staging` / `dev` so the proxy still binds in degraded
/// mode (auth routes will refuse with `firebase_admin_not_configured`,
/// but unauthenticated probes like `/health` keep working).
ProxyProductionBindings buildProxyProductionBindings(
  ProxyConfig config, {
  PostgresPoolFactory postgresPoolFactory = PackagePostgresPool.fromUrl,
  bool requireFirebase = true,
  List<String> expectedMigrationFilenames = const <String>[],
}) {
  final firebaseAdmin = _buildFirebaseAdminAuthClient(
    config,
    requireFirebase: requireFirebase,
  );
  final tenantPool = postgresPoolFactory(
    config.secretFor(ProxySecretNames.postgresUrl),
  );
  final adminPool = postgresPoolFactory(
    config.secretFor(ProxySecretNames.postgresAdminUrl),
  );
  final healthPool = postgresPoolFactory(
    config.secretFor(ProxySecretNames.postgresAdminUrl),
  );
  final tenantWrapper = TenantTransactionWrapper(tenantPool);
  final adminWrapper = TenantTransactionWrapper(adminPool);
  final healthWrapper = TenantTransactionWrapper(healthPool);

  // Phase 9.0Σ.f B.2 — live-wired audit_logs cutover flag. Both the
  // tenant- and admin-pool `AuthEventsAuditRepository` instances and
  // the B41 issuance gateway read this resolver per write so flipping
  // the seeded `feature_flags.audit_logs_cutover_enabled` row to
  // `false` immediately routes new traffic back to the legacy
  // `auth_events_audit`-only path. The same const resolver is shared
  // across constructions because the impl is stateless.
  const auditLogsCutoverFlag = FeatureFlagsTableAuditLogsCutoverFlag();
  const auditLogsRepository = AuditLogsRepository();

  final tenantUserRoles = UserRolesRepository(tenantWrapper);
  final tenantRolePermissions = RolePermissionsRepository(tenantWrapper);
  final tenantAudit = AuthEventsAuditRepository(
    tenantWrapper,
    auditLogsRepository: auditLogsRepository,
    cutoverFlag: auditLogsCutoverFlag,
  );
  final tenantUsers = UsersRepository(tenantWrapper);
  final tenantMfaFactors = MfaFactorsRepository(tenantWrapper);
  final tenantMfaRemovalRequests = MfaFactorRemovalRequestsRepository(
    tenantWrapper,
  );
  final tenantEventOutbox = EventOutboxRepository(tenantWrapper);
  final adminMfaFactors = MfaFactorsRepository(adminWrapper);
  final adminMfaRemovalRequests = MfaFactorRemovalRequestsRepository(
    adminWrapper,
  );
  final adminEventOutbox = EventOutboxRepository(adminWrapper);
  final firebaseMfaClient = IdentityToolkitFirebaseMfaClient(
    apiKey: config.secretFor(ProxySecretNames.firebaseWebApiKey),
  );
  final adminAudit = AuthEventsAuditRepository(
    adminWrapper,
    auditLogsRepository: auditLogsRepository,
    cutoverFlag: auditLogsCutoverFlag,
  );
  final authOperationsGateway = RepositoryAuthOperationsGateway(
    firebaseAdmin: firebaseAdmin,
    usersRepository: UsersRepository(adminWrapper),
    rolesRepository: RolesRepository(adminWrapper),
    rolePermissionsRepository: RolePermissionsRepository(adminWrapper),
    userRolesRepository: UserRolesRepository(adminWrapper),
    authInvitesRepository: AuthInvitesRepository(adminWrapper),
    // Writer-side audit rows still flow through the admin wrapper —
    // append-only inserts must succeed even when an admin path runs
    // outside a tenant scope. The 9.UX.6 self-service read uses a
    // separate tenant-scoped repository binding (see
    // `auditReadRepository`) so the per-user WHERE + per-tenant RLS
    // policy gate the projection without disturbing the existing
    // writer.
    auditRepository: adminAudit,
    auditReadRepository: AuthEventsAuditRepository(
      tenantWrapper,
      auditLogsRepository: auditLogsRepository,
      cutoverFlag: auditLogsCutoverFlag,
    ),
    // Phase 9.UX.4: tenant-scoped reads/writes — per-operator RLS
    // policies on `org_units` + `locations` are the gate, so the
    // repo runs through the tenant pool, not the admin pool.
    orgUnitsRepository: OrgUnitsRepository(tenantWrapper),
    // Phase 9.UX.5: self-service Active Sessions reads / revokes
    // also go through the tenant pool — the per-user RLS policy on
    // `auth_sessions` is the gate, and admin-grade revoke-all paths
    // remain on the existing AuthSessionLedgerWriter binding.
    authSessionsRepository: AuthSessionsRepository(tenantWrapper),
  );

  final permissionSnapshotResolver = RepositoryProxyPermissionSnapshotResolver(
    userRolesRepository: tenantUserRoles,
    rolePermissionsRepository: tenantRolePermissions,
    requiresMfaKeys: PermissionKeys.requiresMfa,
  );

  // Phase 11A.4b — assemble the LLM providers (Anthropic primary +
  // optional Gemini secondary). Built once at startup so the
  // adapter instances are stable across requests.
  final llmProviders = buildProxyLlmProviders(config);

  // Phase 11A.4c — single OAuth token provider shared between the
  // GCP Secret Manager client and the Cloud Run admin client.
  // Constructed here (NOT inside the helpers) so the cache is
  // shared across both surfaces.
  final kmsTokenProvider = MetadataServerAccessTokenProvider();

  final MobilePushTokenGateway? mobilePushTokenGateway =
      config.hasSecretFor(ProxySecretNames.mobilePushTokenEnvelopeKey)
      ? RepositoryMobilePushTokenGateway(
          repository: MobilePushTokensRepository(tenantWrapper),
          tokenEnvelopeKey: config.secretFor(
            ProxySecretNames.mobilePushTokenEnvelopeKey,
          ),
        )
      : null;
  final MobilePushSelfTestGateway? mobilePushSelfTestGateway =
      config.hasSecretFor(ProxySecretNames.mobilePushTokenEnvelopeKey) &&
          config.firebaseProjectId != null
      ? RepositoryMobilePushSelfTestGateway(
          tokensRepository: MobilePushTokensRepository(tenantWrapper),
          sender: FcmHttpV1MobilePushSender(
            firebaseProjectId: config.firebaseProjectId!,
            accessTokenProvider: kmsTokenProvider,
          ),
          tokenEnvelopeKey: config.secretFor(
            ProxySecretNames.mobilePushTokenEnvelopeKey,
          ),
        )
      : null;

  // Phase 11W.7 / Wave A2 - operator-scoped write router. Wired
  // through tenant-pool repositories so RLS + per-operator isolation
  // hold; the audit sink fans out to the hash-chained audit_logs
  // table inside the same tenant pool.
  final operatorWriteRouter = OperatorWriteRouter(
    accountGateway: RepositoryOperatorAccountWriteGateway(
      repository: OperatorAccountRepository(tenantWrapper),
    ),
    businessTimingGateway: RepositoryOperatorBusinessTimingWriteGateway(
      repository: BusinessTimingProfilesRepository(tenantWrapper),
    ),
    auditSink: ProductionOperatorWriteAuditSink(
      tenantWrapper: tenantWrapper,
      onError: (error, stackTrace) {
        log(
          LogSeverity.error,
          'proxy.operator_write_audit_failed',
          fields: <String, Object?>{
            'error_type': error.runtimeType.toString(),
            'error_message': error.toString(),
            'stack_first_frame': firstStackFrame(stackTrace),
          },
        );
      },
    ),
  );
  SelectedStarTargetRouter.installGlobal(
    SelectedStarTargetRouter(
      gateway: RepositorySelectedStarTargetGateway(
        repository: SelectedStarShiftRepository(tenantWrapper),
        targetCycleRepository: TargetCycleRepository(tenantWrapper),
        activeTargetProfileRepository: ActiveTargetProfileRepository(
          tenantWrapper,
        ),
      ),
    ),
  );
  WeeklyPlanRouter.installGlobal(
    WeeklyPlanRouter(
      gateway: RepositoryWeeklyPlanGateway(
        snapshotRepository: weekly_snapshot.WeeklyPlanSnapshotRepository(
          tenantWrapper,
        ),
        forecastContextRepository: weekly_forecast.ForecastContextRepository(
          tenantWrapper,
        ),
      ),
    ),
  );
  final businessScopeGateway = RepositoryBusinessScopeProxyGateway(
    userRolesRepository: tenantUserRoles,
    orgUnitsRepository: OrgUnitsRepository(tenantWrapper),
  );

  return ProxyProductionBindings(
    accountingStore: PostgresProxyAccountingStore(wrapper: tenantWrapper),
    firebaseAdminAuthClient: firebaseAdmin,
    accountInfoGateway: RepositoryAccountInfoGateway(
      usersRepository: tenantUsers,
    ),
    authSessionLedgerWriter: RepositoryAuthSessionLedgerWriter(
      repository: AuthSessionsRepository(tenantWrapper),
    ),
    permissionSnapshotResolver: permissionSnapshotResolver,
    adminPermissionGuard: RepositoryProxyAdminPermissionGuard(
      userRolesRepository: tenantUserRoles,
      rolePermissionsRepository: tenantRolePermissions,
      requiresMfaKeys: PermissionKeys.requiresMfa,
    ),
    authOperationsGateway: authOperationsGateway,
    servicePrincipalJwtIssuanceGateway:
        PostgresServicePrincipalJwtIssuanceGateway(
          wrapper: tenantWrapper,
          issuer: ServicePrincipalJwtIssuer(
            sharedSecret: config.secretFor(
              ProxySecretNames.servicePrincipalJwtSecret,
            ),
          ),
          auditLogsRepository: auditLogsRepository,
          cutoverFlag: auditLogsCutoverFlag,
        ),
    passwordChangeGateway: RepositoryPasswordChangeGateway(
      firebaseAdmin: firebaseAdmin,
      usersRepository: tenantUsers,
      passwordHistoryRepository: PasswordHistoryRepository(tenantWrapper),
      auditRepository: tenantAudit,
      hibpScreener: HibpPwnedPasswordScreener(
        fetcher: RateLimitedHibpRangeFetcher(inner: HttpHibpRangeFetcher()),
      ),
      passwordHistoryHasher: const Sha256PasswordHistoryHasher(),
    ),
    passwordResetConfirmGateway: RepositoryPasswordResetConfirmGateway(
      firebaseAdmin: firebaseAdmin,
      usersRepository: UsersRepository(adminWrapper),
      passwordHistoryRepository: PasswordHistoryRepository(tenantWrapper),
      auditRepository: adminAudit,
      hibpScreener: HibpPwnedPasswordScreener(
        fetcher: RateLimitedHibpRangeFetcher(inner: HttpHibpRangeFetcher()),
      ),
      passwordHistoryHasher: const Sha256PasswordHistoryHasher(),
    ),
    // Phase 9.UX.7: self-serve password-reset request. The lookup
    // runs through the admin pool (we must find the user by email
    // even though the Flutter caller is unauthenticated), Firebase
    // Identity Platform issues the action link, and the audit row
    // lands on the resolved user's tenant scope.
    passwordResetRequestGateway: RepositoryPasswordResetRequestGateway(
      firebaseAdmin: firebaseAdmin,
      usersRepository: UsersRepository(adminWrapper),
      auditRepository: adminAudit,
    ),
    mfaOperationsGateway: RepositoryMfaOperationsGateway(
      enrollmentService: FirebaseMfaEnrollmentService(
        client: firebaseMfaClient,
      ),
      mfaFactorsRepository: tenantMfaFactors,
      auditRepository: tenantAudit,
      firebaseMfaClient: firebaseMfaClient,
      removalRequestsRepository: tenantMfaRemovalRequests,
    ),
    mfaRecoveryRequestGateway: RepositoryMfaRecoveryRequestGateway(
      usersRepository: UsersRepository(adminWrapper),
      eventOutboxRepository: tenantEventOutbox,
      rateLimiter: PostgresMfaRecoveryRequestRateLimiter(adminWrapper),
    ),
    mfaRemovalWorker: MfaRemovalWorker(
      removalRequestsRepository: adminMfaRemovalRequests,
      mfaFactorsRepository: adminMfaFactors,
      usersRepository: UsersRepository(adminWrapper),
      auditRepository: adminAudit,
      firebaseAdmin: firebaseAdmin,
      eventOutboxRepository: adminEventOutbox,
    ),
    mobilePushTokenGateway: mobilePushTokenGateway,
    mobilePushSelfTestGateway: mobilePushSelfTestGateway,
    mobileOperationalSyncGateway: RepositoryMobileOperationalSyncProxyGateway(
      tenantWrapper: tenantWrapper,
    ),
    businessScopeGateway: businessScopeGateway,
    // Phase 11A.1 — operator/location admin gateway. The repos run
    // through the admin pool (POSTGRES_ADMIN_URL) because the F&F
    // admin console scans / writes across operators; per-tenant RLS
    // would block cross-operator listings.
    operatorLocationAdminGateway: RepositoryOperatorLocationAdminProxyGateway(
      operatorsRepository: OperatorsRepository(adminWrapper),
      locationsRepository: LocationsRepository(adminWrapper),
      operatorAdminsRepository: OperatorAdminsRepository(adminWrapper),
      authOperationsGateway: authOperationsGateway,
      auditRepository: adminAudit,
    ),
    // Phase 11A.2 — pricing tier admin gateway. Same admin pool
    // rationale: the F&F admin browses caps across the fleet and
    // edits subscription tiers without any operator session in flight,
    // so per-tenant RLS would block reads. The OrgUnitsRepository
    // resolves each operator's root org_unit id to populate the
    // 9.0Σ.g `usage_caps.billing_owner_org_unit_id` /
    // `scoped_org_unit_id` NOT NULL columns.
    pricingTierAdminGateway: RepositoryPricingTierAdminProxyGateway(
      operatorsRepository: OperatorsRepository(adminWrapper),
      locationsRepository: LocationsRepository(adminWrapper),
      usageCapsRepository: UsageCapsRepository(adminWrapper),
      orgUnitsRepository: OrgUnitsRepository(adminWrapper),
      auditRepository: adminAudit,
    ),
    // Phase 11A.3a — corpus admin gateway. Same admin pool rationale
    // as pricing: the corpus is shared methodology across operators,
    // not tenant-scoped data. The repository runs through `withSystem`
    // (forge_admin BYPASSRLS) so the read/write covers every chunk +
    // version row.
    dataAccuracyAdminGateway: RepositoryDataAccuracyAdminProxyGateway(
      adminWrapper: adminWrapper,
      auditRepository: adminAudit,
    ),
    corpusAdminGateway: RepositoryCorpusAdminProxyGateway(
      corpusRepository: CorpusRepository(adminWrapper),
      auditRepository: adminAudit,
      // 11A.B43 — `cache_telemetry_v2` rollout flag. When true, every
      // commit/rollback writes one row into `corpus_invalidation_events`
      // so the F&F operations dashboard can correlate prompt-cache
      // hit-rate drops with corpus material changes. Sourced from the
      // CACHE_TELEMETRY_V2 env var; defaults off in [ProxyConfig].
      emitInvalidationEvent: config.cacheTelemetryV2,
    ),
    // Phase 11A.3b — Graphify candidate review gateway. The launch
    // posture mirrors `RepositoryCorpusAdminProxyGateway`: the route
    // contract exists with the right shape and role/idempotency
    // gates, but live read/commit lights up in a follow-up slice.
    // The production binding raises a typed
    // `graph_candidates_not_configured` 503 so the screen surfaces
    // the actionable banner instead of a generic 5xx, while the
    // demo gateway runs end-to-end via [InMemoryCorpusAdminGateway]
    // which is what the operator walkthrough uses.
    // Phase 11A.3b — Graphify candidate review gateway. Backed by the
    // `GraphRepository` (canonical `graph_nodes` / `graph_edges`
    // writes through the tenant pool so RLS stays engaged) and the
    // admin-pool audit repository (cross-tenant audit row, since the
    // F&F super_admin actor does not live inside the operator's
    // tenant scope). The repo root is `Directory.current`, which is
    // the proxy's CWD on Cloud Run; the gateway resolves the
    // `graphify-out/candidates/` JSONL artifacts under that root.
    graphCandidatesGateway: RepositoryGraphCandidatesProxyGateway(
      graphRepository: GraphRepository(tenantWrapper),
      auditRepository: adminAudit,
      repoRoot: Directory.current,
    ),
    // Phase 11A.4c — Integration management gateway with the GCP
    // Secret Manager rollout wired in. The KmsLaneRouter dispatches
    // each lane (anthropic, voyage, gemini, azure_db) to either the
    // stub or the real provider based on its
    // `kms_real_provider_<kind>_enabled` feature flag. All four
    // flags ship OFF — production stays on the stub until the
    // operator flips one. When the GCP config is missing (dev /
    // scaffold contexts), the router collapses to stub-everywhere
    // and the Cloud Run admin client becomes a no-op.
    //
    // The OAuth access-token provider is constructed once and shared
    // between Secret Manager and Cloud Run admin so the cached token
    // serves both surfaces.
    integrationAdminGateway: RepositoryIntegrationAdminProxyGateway(
      providerCredentialsRepository: ProviderCredentialsRepository(
        adminWrapper,
      ),
      kmsProvider: _buildKmsProvider(
        config: config,
        adminWrapper: adminWrapper,
        accessTokenProvider: kmsTokenProvider,
      ),
      auditRepository: adminAudit,
      cloudRunAdminClient: _buildCloudRunAdminClient(
        config: config,
        accessTokenProvider: kmsTokenProvider,
      ),
    ),
    // Phase 11A.4 — Resolves the verified Firebase UID into a
    // Postgres `users.user_id` (UUID) for audit attribution before
    // any integration write runs. Backed by the admin pool because
    // the lookup is cross-tenant (F&F admins live outside any
    // operator scope).
    integrationAdminActorResolver: RepositoryIntegrationAdminActorResolver(
      usersRepository: UsersRepository(adminWrapper),
    ),
    // Phase 11A.7 — feature flags admin gateway. Reads + writes go
    // through the admin pool; toggles emit a `admin.feature_flags.toggle`
    // event via the same `AuthEventsAuditRepository` the integrations
    // surface uses, so the cutover fan-out into hash-chained
    // `audit_logs` lights up automatically when the
    // `audit_logs_cutover_enabled` flag is on.
    firstConnectionBackfillEnqueueGateway:
        RepositoryFirstConnectionBackfillEnqueueGateway(
          repository: ConnectorBackfillJobRepository(tenantWrapper),
        ),
    integrationCategoryResolver: resolveAdminVisibleIntegrationCategory,
    featureFlagsAdminGateway: RepositoryFeatureFlagsAdminProxyGateway(
      featureFlagsRepository: FeatureFlagsRepository(adminWrapper),
      auditRepository: adminAudit,
    ),
    debugConsoleAdminGateway: RepositoryDebugConsoleAdminProxyGateway(
      adminWrapper: adminWrapper,
    ),
    observabilityAdminGateway: RepositoryObservabilityAdminProxyGateway(
      adminWrapper: adminWrapper,
      cloudRunServiceName: config.cloudRunServiceName,
      cloudRunRevision: Platform.environment['K_REVISION'],
    ),
    // HARD-C — Postgres-backed gate for the supplemental admin CORS
    // allow-list. main.dart awaits this once during bootstrap before
    // binding a port; flipping the row in `feature_flags` does not
    // take effect until the next deploy / restart.
    adminCorsOriginsExtraFlag: FeatureFlagsTableAdminCorsOriginsExtraFlag(
      adminPool,
    ),
    // HARD-H — admin idempotency cache for cross-tenant POST routes.
    // Uses the admin pool because `admin_request_idempotency` has no
    // operator_id column (admin actors live outside any tenant scope)
    // and the HARD-H migration grants `service_role` SELECT/INSERT/
    // UPDATE on the table.
    adminRequestIdempotencyStore: PostgresAdminRequestIdempotencyStore(
      pool: adminPool,
    ),
    // Phase 11A.4b — LLM providers feeding the AdvisorRequestPipeline.
    llmProvider: llmProviders.primary,
    secondaryLlmProvider: llmProviders.secondary,
    geminiSlotEnabled: llmProviders.geminiSlotEnabled,
    // HARD-A — usage counter store backed by `public.advisor_proxy_usage_counters`.
    // The lib-side data-access class lives in
    // `advisor_proxy_usage_counter_store.dart`; the adapter below
    // bridges it to the proxy's `ProxyUsageCounterStore` interface so
    // the lib/tool boundary stays one-way (tool/ depends on lib/, never
    // the reverse).
    usageCounterStore: _AdvisorProxyUsageCounterStoreAdapter(
      AdvisorProxyUsageCounterStore(tenantWrapper),
    ),
    // HARD-A — registry-backed `/health`. Runs the producer catalog
    // with bounded concurrency against a separate admin-role pool with `set local role
    // forge_admin` (BYPASSRLS) so platform-wide reads (graph_health,
    // event_outbox, audit_logs, vector indexes, etc.) succeed without
    // starving its own pool or the admin UX gateway pool.
    healthCheckStore: _buildRegistryProxyHealthCheckStore(
      healthWrapper,
      expectedMigrationFilenames: expectedMigrationFilenames,
    ),
    // HARD-G observability — pools exposed for the startup
    // connectivity probe in `main.dart`. The probe opens + commits
    // one `select 1` per pool so a slow / broken Postgres surfaces
    // as `DependencyTimeoutException` and the proxy exits 78
    // instead of binding the listener and degrading every request.
    tenantPool: tenantPool,
    adminPool: adminPool,
    // HARD-B - lockout enforcer + audit sink. Both ride the admin
    // pool because the anonymous-lookup path (pre-tenant resolution)
    // needs forge_admin BYPASSRLS to read/write rows whose
    // `operator_id` is intentionally null. The sink fans out into
    // the same `audit_logs` chain as every other auth event via the
    // existing AuthEventsAuditRepository fan-out.
    authLockoutEnforcer: PostgresAuthLockoutEnforcer(
      repository: AuthLoginAttemptsRepository(adminWrapper),
    ),
    authLockoutAuditSink: AuthEventsAuditAuthLockoutAuditSink(
      auditRepository: adminAudit,
    ),
    mfaTotpRetryCounter: RollingWindowAttemptCounter(
      window: kAuthMfaTotpRetryAfter * 10,
    ),
    passwordResetThrottleCounter: RollingWindowAttemptCounter(
      window: kAuthPasswordResetWindow,
    ),
    operatorWriteRouter: operatorWriteRouter,
  );
}

/// HARD-B - production [AuthLockoutEnforcer] backed by the
/// admin-pool [AuthLoginAttemptsRepository]. Anonymous attempts (no
/// resolved operator) ride the system path; tenant-bound writes ride
/// the per-operator path so the per-tenant RLS policy admits them.
class PostgresAuthLockoutEnforcer implements AuthLockoutEnforcer {
  PostgresAuthLockoutEnforcer({required AuthLoginAttemptsRepository repository})
    : _repository = repository;

  final AuthLoginAttemptsRepository _repository;

  @override
  Future<AuthLockoutEvaluation> evaluate({
    required String email,
    required String ip,
  }) async {
    final count = await _repository.countFailuresIn(
      userEmailHash: AuthLoginAttemptsRepository.hashEmail(email),
      ipHash: AuthLoginAttemptsRepository.hashIp(ip),
      window: kAuthLoginLockoutWindow,
      adminReason: 'auth.lockout_evaluate',
    );
    final locked =
        count.locked || count.failureCount >= kAuthLoginLockoutThreshold;
    return AuthLockoutEvaluation(
      locked: locked,
      failureCount: count.failureCount,
    );
  }

  @override
  Future<int> recordFailure({
    required String email,
    required String ip,
    String? userAgentClass,
    String? operatorId,
    String? locationId,
    String? actorUserId,
  }) async {
    final emailHash = AuthLoginAttemptsRepository.hashEmail(email);
    final ipHash = AuthLoginAttemptsRepository.hashIp(ip);
    if (operatorId != null && locationId != null) {
      await _repository.writeForTenant(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        userEmailHash: emailHash,
        ipHash: ipHash,
        outcome: AuthLoginAttemptOutcome.failure,
        userAgentClass: userAgentClass,
      );
    } else {
      await _repository.writeAnonymous(
        userEmailHash: emailHash,
        ipHash: ipHash,
        outcome: AuthLoginAttemptOutcome.failure,
        userAgentClass: userAgentClass,
        adminReason: 'auth.lockout_record_failure',
      );
    }
    final post = await _repository.countFailuresIn(
      userEmailHash: emailHash,
      ipHash: ipHash,
      window: kAuthLoginLockoutWindow,
      adminReason: 'auth.lockout_post_failure_count',
    );
    return post.failureCount;
  }

  @override
  Future<void> recordLocked({
    required String email,
    required String ip,
    String? userAgentClass,
  }) async {
    await _repository.writeAnonymous(
      userEmailHash: AuthLoginAttemptsRepository.hashEmail(email),
      ipHash: AuthLoginAttemptsRepository.hashIp(ip),
      outcome: AuthLoginAttemptOutcome.locked,
      userAgentClass: userAgentClass,
      adminReason: 'auth.lockout_record_locked',
    );
  }

  @override
  Future<void> recordSuccess({
    required String email,
    required String ip,
    required String operatorId,
    required String locationId,
    required String actorUserId,
    String? userAgentClass,
  }) async {
    await _repository.writeForTenant(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      userEmailHash: AuthLoginAttemptsRepository.hashEmail(email),
      ipHash: AuthLoginAttemptsRepository.hashIp(ip),
      outcome: AuthLoginAttemptOutcome.success,
      userAgentClass: userAgentClass,
    );
  }
}

/// HARD-B - production [AuthLockoutAuditSink] that writes through
/// the admin-pool [AuthEventsAuditRepository.insertSystemEvent]. The
/// existing fan-out into `audit_logs` (via the cutover flag) lights
/// up automatically when the row passes the actor-shape check.
///
/// Sensitive-field discipline: the contract pins that no raw email,
/// raw IP, password, or TOTP secret may appear in any audit row. This
/// sink only forwards the SHA-256 hex digests + non-sensitive
/// metadata that the route handler computed.
class AuthEventsAuditAuthLockoutAuditSink implements AuthLockoutAuditSink {
  AuthEventsAuditAuthLockoutAuditSink({
    required AuthEventsAuditRepository auditRepository,
  }) : _auditRepository = auditRepository;

  final AuthEventsAuditRepository _auditRepository;

  @override
  Future<void> recordLoginFailed({
    required String emailHashHex,
    required String ipHashHex,
    required String outcome,
    required int attemptCountInWindow,
    required bool locked,
    String? operatorId,
    String? locationId,
    String? actorUserId,
  }) async {
    await _auditRepository.insertSystemEvent(
      eventType: 'auth.login_failed',
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      payload: <String, Object?>{
        'email_hash': emailHashHex,
        'ip_hash': ipHashHex,
        'outcome': outcome,
        'attempt_count_in_window': attemptCountInWindow,
        'locked': locked,
      },
      adminReason: 'auth.login_failed:$outcome',
    );
  }

  @override
  Future<void> recordAccountLocked({
    required String emailHashHex,
    required String ipHashHex,
    required int attemptCount,
    required DateTime lockoutUntil,
    String? operatorId,
    String? locationId,
    String? actorUserId,
  }) async {
    // Plumb actorUserId through so the success-path lock (where the
    // bearer token already verified the user) lights up the
    // hash-chained `audit_logs` fan-out. The failure-report
    // anonymous path passes actorUserId=null and lands in
    // auth_events_audit only -- the contract documents that anonymous
    // events skip the per-tenant chain because audit_logs is per-
    // (operator_id, chain_date) and these events have no resolvable
    // operator at attempt time.
    await _auditRepository.insertSystemEvent(
      eventType: 'auth.account_locked',
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      payload: <String, Object?>{
        'email_hash': emailHashHex,
        'ip_hash': ipHashHex,
        'attempt_count': attemptCount,
        'lockout_until': lockoutUntil.toUtc().toIso8601String(),
      },
      adminReason: 'auth.account_locked',
    );
  }

  @override
  Future<void> recordMfaRetryExceeded({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String challengeIdHash,
    required int retryCount,
  }) async {
    await _auditRepository.insertSystemEvent(
      eventType: 'auth.mfa_retry_exceeded',
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      payload: <String, Object?>{
        'challenge_id_hash': challengeIdHash,
        'retry_count': retryCount,
      },
      adminReason: 'auth.mfa_retry_exceeded',
    );
  }

  @override
  Future<void> recordPasswordResetThrottled({
    required String emailHashHex,
    required int attemptCountIn24h,
    required Duration retryAfter,
  }) async {
    await _auditRepository.insertSystemEvent(
      eventType: 'auth.password_reset_throttled',
      payload: <String, Object?>{
        'email_hash': emailHashHex,
        'attempt_count_24h': attemptCountIn24h,
        'retry_after_seconds': retryAfter.inSeconds,
      },
      adminReason: 'auth.password_reset_throttled',
    );
  }
}

/// HARD-A — bridges the lib-side [AdvisorProxyUsageCounterStore]
/// (data-access class) to the proxy's [ProxyUsageCounterStore]
/// runtime interface. The adapter owns nothing beyond translation —
/// the SQL, the bucket math, and the concurrency guarantees all live
/// inside [AdvisorProxyUsageCounterStore].
class _AdvisorProxyUsageCounterStoreAdapter implements ProxyUsageCounterStore {
  _AdvisorProxyUsageCounterStoreAdapter(this._inner);

  final AdvisorProxyUsageCounterStore _inner;

  @override
  Future<UsageSnapshot> currentUsage({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
  }) async {
    final s = await _inner.readSnapshot(
      operatorId: operatorId,
      locationId: locationId,
      tierId: tierId,
      now: now,
    );
    return UsageSnapshot(
      requestsThisMinute: s.requestsThisMinute,
      costCentsThisMonth: s.costCentsThisMonth,
      minuteBucketStart: s.minuteBucketStart,
      monthBucketStart: s.monthBucketStart,
    );
  }

  @override
  Future<void> incrementOnAllow({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
    required int costCentsToAdd,
  }) {
    return _inner.upsertIncrement(
      operatorId: operatorId,
      locationId: locationId,
      tierId: tierId,
      now: now,
      costCentsToAdd: costCentsToAdd,
    );
  }
}

/// Constructs the [RegistryProxyHealthCheckStore] used in production.
///
/// The runner uses [TenantTransactionWrapper.runAsSystem] against the
/// admin pool so each producer query elevates to `forge_admin` for
/// the duration of one transaction. Producers do read-only system
/// queries; tenant SET LOCAL is intentionally bypassed because
/// reserved metrics aggregate platform-wide signals (event_outbox,
/// graph_health_metrics, audit chain anchors) that span operators.
RegistryProxyHealthCheckStore _buildRegistryProxyHealthCheckStore(
  TenantTransactionWrapper adminWrapper, {
  List<String> expectedMigrationFilenames = const <String>[],
}) {
  const healthStatementTimeout = Duration(milliseconds: 150);
  const healthProducerConcurrency = kPostgresDefaultMaxConnectionsPerPool;

  Future<List<Map<String, Object?>>> runnerFn(
    String sql, {
    Map<String, Object?> parameters = const <String, Object?>{},
  }) {
    return adminWrapper.runAsSystem<List<Map<String, Object?>>>((exec) async {
      await exec.execute(
        "select set_config('statement_timeout', @value, true)",
        parameters: <String, Object?>{
          'value': '${healthStatementTimeout.inMilliseconds}ms',
        },
      );
      return exec.query(sql, parameters: parameters);
    }, reason: 'proxy_health');
  }

  return RegistryProxyHealthCheckStore(
    runnerFn: runnerFn,
    // HARD-A: strict probe exercises cypher MATCH + vector distance,
    // not just extension presence, so a regressed AGE path or vector
    // operator surfaces as `red` instead of green.
    dependencyProbe: (fn, now) => strictProxyHealthDependencyProbe(
      fn,
      now,
      budget: kPostgresPerStatementTimeout,
    ),
    producers: buildProxyHealthRegistryProducers(
      expectedMigrationFilenames: expectedMigrationFilenames,
    ),
    producerBudget: const Duration(milliseconds: 300),
    outerProducerBudget: const Duration(milliseconds: 450),
    producerRouteBudget: const Duration(seconds: 3),
    producerConcurrency: healthProducerConcurrency,
  );
}

/// Records the runtime migration catalog in `proxy_migrations_applied`.
///
/// The writer runs through the admin pool with `runAsSystem`, matching
/// the health registry's platform-wide read posture and keeping the
/// startup registry write independent from any operator tenant scope.
Future<int> recordProxyStartupMigrations(
  ProxyProductionBindings bindings,
  List<String> migrationFilenames,
) {
  final adminWrapper = TenantTransactionWrapper(bindings.adminPool);
  Future<List<Map<String, Object?>>> runnerFn(
    String sql, {
    Map<String, Object?> parameters = const <String, Object?>{},
  }) {
    return adminWrapper.runAsSystem<List<Map<String, Object?>>>(
      (exec) => exec.query(sql, parameters: parameters),
      reason: 'proxy_migration_registry',
    );
  }

  return ProxyMigrationApplyRegistryWriter(
    runnerFn: runnerFn,
  ).recordAppliedMigrations(migrationFilenames);
}

/// Verifies the actual admin-console schema contract before the proxy
/// binds. This closes the gap where startup can observe migration files
/// in `db/migrations` while the target database has not run the SQL yet.
Future<void> verifyAdminProxySchemaContract(ProxyProductionBindings bindings) {
  final adminWrapper = TenantTransactionWrapper(bindings.adminPool);
  Future<List<Map<String, Object?>>> runnerFn(
    String sql, {
    Map<String, Object?> parameters = const <String, Object?>{},
  }) {
    return adminWrapper.runAsSystem<List<Map<String, Object?>>>(
      (exec) => exec.query(sql, parameters: parameters),
      reason: 'proxy_admin_schema_contract',
    );
  }

  return AdminProxySchemaContractVerifier(runnerFn: runnerFn).verify();
}

/// HARD-G observability — startup connectivity probe.
///
/// Opens one transaction on each Postgres pool, runs `SELECT 1`, and
/// commits. Surfaces a slow / broken Postgres as
/// [DependencyTimeoutException] (the executor logs
/// `request.dependency_timeout` at the wire boundary; this helper
/// translates the failure into a startup-level event). The main
/// entrypoint catches and exits 78.
///
/// Lives in the bootstrap (rather than inside
/// `buildProxyProductionBindings`) so the build remains synchronous
/// and the existing test that asserts "construction does not open
/// connections" still holds.
Future<void> probeProxyStartupConnectivity(
  ProxyProductionBindings bindings,
) async {
  for (final entry in <MapEntry<String, PostgresPool>>[
    MapEntry('tenant', bindings.tenantPool),
    MapEntry('admin', bindings.adminPool),
  ]) {
    final scope = entry.key;
    final pool = entry.value;
    PostgresTransaction? tx;
    try {
      // beginTransaction covers both the acquire and BEGIN timeout
      // paths — keep it inside the try so a timeout there still
      // emits startup.failed before main.dart exits 78.
      tx = await pool.beginTransaction();
      await tx.query('select 1');
      await tx.commit();
    } catch (error) {
      if (tx != null) {
        try {
          await tx.rollback();
        } catch (_) {
          // Already-finalized rollback is a no-op per the contract.
        }
      }
      if (error is DependencyTimeoutException) {
        log(
          LogSeverity.error,
          'startup.failed',
          fields: <String, Object?>{
            'phase': 'postgres_probe',
            'scope': scope,
            'surface': error.surface,
            'operation': error.operation,
            'elapsed_ms': error.elapsedMs,
            'exit_code': 78,
          },
        );
      }
      rethrow;
    }
  }
}

class RepositoryWeeklyPlanGateway implements WeeklyPlanGateway {
  RepositoryWeeklyPlanGateway({
    required weekly_snapshot.WeeklyPlanSnapshotRepository snapshotRepository,
    required weekly_forecast.ForecastContextRepository
    forecastContextRepository,
  }) : _snapshotRepository = snapshotRepository,
       _forecastContextRepository = forecastContextRepository;

  final weekly_snapshot.WeeklyPlanSnapshotRepository _snapshotRepository;
  final weekly_forecast.ForecastContextRepository _forecastContextRepository;

  @override
  Future<WeeklyPlanSnapshotRow> lockSnapshot({
    required WeeklyPlanLockRequest request,
  }) async {
    var forecastContextId = request.forecastContextId;
    final embeddedContext = request.embeddedForecastContext;
    if (embeddedContext != null) {
      final closedAt = DateTime.now().toUtc();
      final contextRow = await _forecastContextRepository.upsertContext(
        context: weekly_forecast.ForecastContextPostgresWrite(
          operatorId: request.operatorId,
          locationId: request.locationId,
          restaurantId: request.restaurantId,
          anchorBusinessDate:
              embeddedContext.anchorBusinessDate ?? request.weekStartDate,
          baselineTotalCovers: embeddedContext.baselineTotalCovers,
          baselineWeeklyAvgCovers: embeddedContext.baselineWeeklyAvgCovers,
          baselineWeeksRepresented: embeddedContext.baselineWeeksRepresented,
          recentThreeWeekTotalCovers:
              embeddedContext.recentThreeWeekTotalCovers,
          recentThreeWeekWeeklyAvgCovers:
              embeddedContext.recentThreeWeekWeeklyAvgCovers,
          recentTrendDeltaCovers: embeddedContext.recentTrendDeltaCovers,
          resolvedWeeklyForecastCovers:
              embeddedContext.resolvedWeeklyForecastCovers,
          targetPpa: request.forecastCovers == 0
              ? 0
              : request.forecastSales / request.forecastCovers,
          forecastSales: request.forecastSales,
          requiredFohHours: request.requiredFohHours.toDouble(),
          requiredBohHours: request.requiredBohHours.toDouble(),
          theoreticalLaborDollars:
              request.theoreticalFohLaborDollars +
              request.theoreticalBohLaborDollars,
          coversSource: embeddedContext.coversSource,
          salesSource: request.salesSource,
          targetCycleId: request.targetCycleId,
          targetProfileId: _optionalStringFromObject(
            request.metadata['target_profile_id'],
          ),
          contextStatus: 'closed',
          builtAt: embeddedContext.builtAt,
          closedAt: closedAt,
          idempotencyKey: request.idempotencyKey,
          requestHash: request.requestHash,
          metadata: <String, Object?>{
            ...request.metadata,
            'week_start_date': request.weekStartDate,
            'week_end_date': request.weekEndDate,
          },
          createdBy: request.actorUserId,
        ),
        actorKind: request.actorKind,
        reason: request.reason,
      );
      forecastContextId = contextRow.forecastContextId;
    }

    final lockedAt = DateTime.now().toUtc();
    final row = await _snapshotRepository.lockOrReplaceSnapshot(
      snapshot: weekly_snapshot.WeeklyPlanSnapshotPostgresWrite(
        operatorId: request.operatorId,
        locationId: request.locationId,
        restaurantId: request.restaurantId,
        weekStartDate: request.weekStartDate,
        weekEndDate: request.weekEndDate,
        weekKey: '${request.weekStartDate}_${request.weekEndDate}',
        targetCycleId: request.targetCycleId,
        forecastContextId: forecastContextId,
        forecastCovers: request.forecastCovers,
        forecastSales: request.forecastSales,
        requiredFohHours: request.requiredFohHours.toDouble(),
        requiredBohHours: request.requiredBohHours.toDouble(),
        theoreticalFohLaborDollars: request.theoreticalFohLaborDollars,
        theoreticalBohLaborDollars: request.theoreticalBohLaborDollars,
        coversSource: request.coversSource,
        salesSource: request.salesSource,
        generatedAt: lockedAt,
        lockedAt: lockedAt,
        replacementReason: request.reason,
        idempotencyKey: request.idempotencyKey,
        requestHash: request.requestHash,
        metadata: request.metadata,
        createdBy: request.actorUserId,
      ),
      days: <weekly_snapshot.WeeklyPlanSnapshotDayPostgresWrite>[
        for (var i = 0; i < request.dayRows.length; i++)
          weekly_snapshot.WeeklyPlanSnapshotDayPostgresWrite(
            operatorId: request.operatorId,
            locationId: request.locationId,
            restaurantId: request.restaurantId,
            dayIndex: i,
            dayLabel: request.dayRows[i].day,
            businessDate: request.dayRows[i].businessDate,
            forecastCovers: request.dayRows[i].forecastCovers,
            forecastSales: request.dayRows[i].forecastSales,
            requiredFohHours: request.dayRows[i].requiredFohHours.toDouble(),
            requiredBohHours: request.dayRows[i].requiredBohHours.toDouble(),
          ),
      ],
      actorKind: request.actorKind,
      reason: request.reason,
    );
    return _weeklyPlanSnapshotRouteRow(row, dayRows: request.dayRows);
  }

  @override
  Future<List<WeeklyPlanSnapshotRow>> listWeeklyPlanSnapshotsUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit = 250,
  }) async {
    final rows = await _snapshotRepository.listUpdatedSince(
      operatorId: operatorId,
      locationId: locationId,
      updatedAfter: updatedAfter,
      userId: userId,
      limit: limit,
    );
    return <WeeklyPlanSnapshotRow>[
      for (final row in rows)
        _weeklyPlanSnapshotRouteRow(
          row,
          dayRows: <WeeklyPlanDayPayload>[
            for (final day in await _snapshotRepository.listDaysForSnapshot(
              operatorId: operatorId,
              locationId: locationId,
              snapshotId: row.snapshotId,
              userId: userId,
            ))
              WeeklyPlanDayPayload(
                day: day.dayLabel,
                businessDate: day.businessDate,
                forecastCovers: day.forecastCovers,
                forecastSales: day.forecastSales,
                requiredFohHours: day.requiredFohHours.round(),
                requiredBohHours: day.requiredBohHours.round(),
              ),
          ],
        ),
    ];
  }

  @override
  Future<List<ForecastContextRow>> listForecastContextsUpdatedSince({
    required String operatorId,
    required String locationId,
    required DateTime updatedAfter,
    String? userId,
    int limit = 250,
  }) async {
    final rows = await _forecastContextRepository.listUpdatedSince(
      operatorId: operatorId,
      locationId: locationId,
      updatedAfter: updatedAfter,
      userId: userId,
      limit: limit,
    );
    return <ForecastContextRow>[
      for (final row in rows) _forecastContextRouteRow(row),
    ];
  }
}

WeeklyPlanSnapshotRow _weeklyPlanSnapshotRouteRow(
  weekly_snapshot.WeeklyPlanSnapshotPostgresRow row, {
  required List<WeeklyPlanDayPayload> dayRows,
}) {
  return WeeklyPlanSnapshotRow(
    snapshotId: row.snapshotId,
    operatorId: row.operatorId,
    locationId: row.locationId,
    restaurantId: row.restaurantId,
    weekStartDate: row.weekStartDate,
    weekEndDate: row.weekEndDate,
    targetCycleId: row.targetCycleId,
    forecastContextId: row.forecastContextId,
    forecastCovers: row.forecastCovers,
    forecastSales: row.forecastSales,
    requiredFohHours: row.requiredFohHours.round(),
    requiredBohHours: row.requiredBohHours.round(),
    theoreticalFohLaborDollars: row.theoreticalFohLaborDollars,
    theoreticalBohLaborDollars: row.theoreticalBohLaborDollars,
    coversSource: row.coversSource,
    salesSource: row.salesSource,
    dayRows: dayRows,
    lockedAt: row.lockedAt,
    lockedByUserId: row.createdBy ?? '',
    lockReason: row.replacementReason ?? row.source,
    isActive: row.snapshotStatus == 'active',
    supersedesSnapshotId: row.supersedesSnapshotId,
    idempotencyKey: row.idempotencyKey,
    requestHash: row.requestHash,
    metadata: row.metadata,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    supersededAt: row.supersededAt,
  );
}

ForecastContextRow _forecastContextRouteRow(
  weekly_forecast.ForecastContextPostgresRow row,
) {
  final weekStartDate = row.anchorBusinessDate;
  return ForecastContextRow(
    forecastContextId: row.forecastContextId,
    operatorId: row.operatorId,
    locationId: row.locationId,
    restaurantId: row.restaurantId,
    anchorBusinessDate: row.anchorBusinessDate,
    weekStartDate: weekStartDate,
    weekEndDate: _datePlusDays(weekStartDate, 6),
    baselineTotalCovers: row.baselineTotalCovers,
    baselineWeeklyAvgCovers: row.baselineWeeklyAvgCovers,
    baselineWeeksRepresented: row.baselineWeeksRepresented,
    recentThreeWeekTotalCovers: row.recentThreeWeekTotalCovers,
    recentThreeWeekWeeklyAvgCovers: row.recentThreeWeekWeeklyAvgCovers,
    recentTrendDeltaCovers: row.recentTrendDeltaCovers,
    resolvedWeeklyForecastCovers: row.resolvedWeeklyForecastCovers,
    targetPpa: row.targetPpa,
    forecastSales: row.forecastSales,
    requiredFohHours: row.requiredFohHours.round(),
    requiredBohHours: row.requiredBohHours.round(),
    theoreticalLaborDollars: row.theoreticalLaborDollars,
    coversSource: row.coversSource,
    builtAt: row.builtAt,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );
}

String _datePlusDays(String yyyyMmDd, int days) {
  final parsed = DateTime.tryParse('${yyyyMmDd}T00:00:00Z');
  if (parsed == null) return yyyyMmDd;
  return parsed.add(Duration(days: days)).toIso8601String().substring(0, 10);
}

String? _optionalStringFromObject(Object? value) {
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return null;
}

class RepositoryBusinessScopeProxyGateway implements BusinessScopeProxyGateway {
  RepositoryBusinessScopeProxyGateway({
    required UserRolesRepository userRolesRepository,
    required OrgUnitsRepository orgUnitsRepository,
  }) : _userRolesRepository = userRolesRepository,
       _orgUnitsRepository = orgUnitsRepository;

  final UserRolesRepository _userRolesRepository;
  final OrgUnitsRepository _orgUnitsRepository;

  @override
  Future<List<BusinessScopeProxyRow>> listAccessibleScopes({
    required String userId,
    required String operatorId,
    required String locationId,
  }) async {
    final grants = await _userRolesRepository.activeGrantsForUser(
      operatorId: operatorId,
      locationId: locationId,
      targetUserId: userId,
      actorUserId: userId,
    );
    if (grants.isEmpty) return const <BusinessScopeProxyRow>[];

    final orgUnits = await _orgUnitsRepository.listForTenant(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    final locations = await _orgUnitsRepository.listLocationsForTenant(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );

    final orgById = <String, OrgUnitRow>{
      for (final row in orgUnits) row.id: row,
    };
    final locationById = <String, OrgLocationRow>{
      for (final row in locations) row.locationId: row,
    };
    final rowsByKey = <String, BusinessScopeProxyRow>{};

    void add(BusinessScopeProxyRow row) {
      rowsByKey['${row.scopeType}:${row.scopeId}'] = row;
    }

    final hasOperatorWideGrant = grants.any(
      (grant) => grant.scopeType == UserRoleScope.operatorWide.sqlKey,
    );
    if (hasOperatorWideGrant) {
      final root = _firstRoot(orgUnits);
      add(
        BusinessScopeProxyRow(
          scopeId: operatorId,
          scopeType: 'operator',
          operatorId: operatorId,
          label: root?.name ?? 'Current business',
          sortPath: root?.path ?? '0',
        ),
      );
      for (final org in orgUnits) {
        add(_orgUnitScope(org));
      }
      for (final location in locations) {
        add(_locationScope(location));
      }
    }

    for (final grant in grants) {
      final orgUnitId = _nonBlank(grant.orgUnitId);
      if (grant.scopeType == UserRoleScope.orgUnit.sqlKey &&
          orgUnitId != null) {
        final org = orgById[orgUnitId];
        if (org != null) {
          add(_orgUnitScope(org));
        }
      }
      final effectiveLocationIds = grant.effectiveLocationIds.isNotEmpty
          ? grant.effectiveLocationIds
          : <String>[
              if (_nonBlank(grant.locationId) != null)
                _nonBlank(grant.locationId)!,
            ];
      for (final effectiveLocationId in effectiveLocationIds) {
        final location = locationById[effectiveLocationId];
        if (location != null) {
          add(_locationScope(location));
        } else {
          add(
            BusinessScopeProxyRow(
              scopeId: effectiveLocationId,
              scopeType: 'location',
              operatorId: operatorId,
              locationId: effectiveLocationId,
              label: 'Location',
              sortPath: 'z:$effectiveLocationId',
            ),
          );
        }
      }
    }

    final rows = rowsByKey.values.toList(growable: false);
    rows.sort(_compareBusinessScopes);
    return rows;
  }

  @override
  Future<bool> canAccessLocation({
    required String userId,
    required String operatorId,
    required String locationId,
  }) async {
    final scopes = await listAccessibleScopes(
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
    );
    return scopes.any(
      (scope) =>
          scope.scopeType == 'location' && scope.locationId == locationId,
    );
  }

  static BusinessScopeProxyRow _orgUnitScope(OrgUnitRow row) {
    return BusinessScopeProxyRow(
      scopeId: row.id,
      scopeType: 'org_unit',
      operatorId: row.operatorId,
      parentScopeId: row.parentId,
      label: row.name,
      sortPath: row.path,
    );
  }

  static BusinessScopeProxyRow _locationScope(OrgLocationRow row) {
    return BusinessScopeProxyRow(
      scopeId: row.locationId,
      scopeType: 'location',
      operatorId: row.operatorId,
      locationId: row.locationId,
      parentScopeId: row.parentOrgUnitId,
      label: row.name,
      sortPath: '${row.orgUnitPath}.${row.name}',
    );
  }

  static int _compareBusinessScopes(
    BusinessScopeProxyRow left,
    BusinessScopeProxyRow right,
  ) {
    final orderCompare = _scopeOrder(
      left.scopeType,
    ).compareTo(_scopeOrder(right.scopeType));
    if (orderCompare != 0) return orderCompare;
    final pathCompare = (left.sortPath ?? left.label).compareTo(
      right.sortPath ?? right.label,
    );
    if (pathCompare != 0) return pathCompare;
    return left.scopeId.compareTo(right.scopeId);
  }

  static int _scopeOrder(String scopeType) => switch (scopeType) {
    'operator' => 0,
    'org_unit' => 1,
    'location' => 2,
    _ => 3,
  };

  static String? _nonBlank(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static OrgUnitRow? _firstRoot(List<OrgUnitRow> rows) {
    for (final row in rows) {
      if (row.parentId == null) return row;
    }
    return null;
  }
}

class RepositoryMobileOperationalSyncProxyGateway
    implements MobileOperationalSyncProxyGateway {
  RepositoryMobileOperationalSyncProxyGateway({
    required TenantTransactionWrapper tenantWrapper,
  }) : _tenantWrapper = tenantWrapper,
       _timingProfilesRepository = BusinessTimingProfilesRepository(
         tenantWrapper,
       );

  final TenantTransactionWrapper _tenantWrapper;
  final BusinessTimingProfilesRepository _timingProfilesRepository;

  @override
  Future<Map<String, Object?>> fetchShiftRecords({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? modifiedSince,
    required int pageSize,
  }) {
    return _tenantRead(scope, operatorId, locationId, (exec) async {
      final params = <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'limit': pageSize + 1,
      };
      final cursorSql = _modifiedSinceSql(modifiedSince, params);
      final rows = await exec.query(
        'select '
        'restaurant_id, week_id, day_label, daypart, status, '
        'business_date::text as business_date, '
        'business_timing_profile_id::text as business_timing_profile_id, '
        'coalesce('
        '  business_timing_profile_version_id, '
        '  business_timing_profile_id'
        ')::text as business_timing_profile_version_id, '
        'service_period_key, '
        'covers, forecast_covers, ppa, cplh, splh, '
        'foh_hours, boh_hours, '
        'foh_labor_dollar, boh_labor_dollar, '
        'theoretical_labor_pct, primary_lever, '
        'target_profile_id::text as target_profile_id, '
        'target_profile_version_id::text as target_profile_version_id, '
        'target_source_type, target_cplh, target_splh, target_ppa, '
        'target_foh_wage, target_boh_wage, '
        'opz_floor_cplh, opz_ceiling_cplh, '
        'theoretical_foh_labor_pct, theoretical_boh_labor_pct, '
        'source_system, source_shift_id, updated_at '
        'from public.shift_records '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        '$cursorSql'
        'order by updated_at asc, business_date asc, daypart asc '
        'limit @limit',
        parameters: params,
      );
      return _pagePayload(
        key: 'shift_records',
        rows: rows,
        pageSize: pageSize,
        mapper: _shiftRecordJson,
      );
    });
  }

  @override
  Future<Map<String, Object?>> fetchOpenShiftSnapshots({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? modifiedSince,
    required int pageSize,
  }) {
    return _tenantRead(scope, operatorId, locationId, (exec) async {
      final params = <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'limit': pageSize + 1,
      };
      final cursorSql = _modifiedSinceSql(modifiedSince, params);
      final rows = await exec.query(
        'select '
        'location_id::text as restaurant_id, week_id, day_label, '
        'service_period_key as daypart, status, '
        'business_date::text as business_date, '
        'business_timing_profile_id::text as business_timing_profile_id, '
        'coalesce('
        '  business_timing_profile_version_id, '
        '  business_timing_profile_id'
        ')::text as business_timing_profile_version_id, '
        'service_period_key, '
        'forecast_covers, current_covers, scheduled_foh_hours, '
        'scheduled_boh_hours, current_ppa, current_cplh, current_splh, '
        'blended_wage, time_label, service_elapsed_label, source_system, '
        'source_shift_id, last_event_at, updated_at '
        'from public.open_shift_snapshots '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        '$cursorSql'
        'order by updated_at asc, business_date asc, snapshot_scope asc, '
        'service_period_key asc '
        'limit @limit',
        parameters: params,
      );
      return _pagePayload(
        key: 'open_shift_snapshots',
        rows: rows,
        pageSize: pageSize,
        mapper: _openShiftSnapshotJson,
      );
    });
  }

  @override
  Future<Map<String, Object?>> fetchResolvedTimingConfig({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? businessDate,
  }) async {
    final effectiveDate = businessDate ?? _todayUtcDate();
    final candidates = await _timingProfilesRepository
        .listCandidateProfilesForLocation(
          operatorId: operatorId,
          locationId: locationId,
          businessDate: effectiveDate,
          userId: _uuidOrNull(scope.userId),
        );
    if (candidates.isEmpty) {
      return const <String, Object?>{'timing_config': null};
    }

    try {
      final resolved = BusinessTimingProfileResolver.resolve(
        <BusinessTimingProfile>[
          for (final row in candidates) _timingProfile(row),
        ],
      );
      final newest = candidates
          .map((row) => row.updatedAt)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      final config = resolved.toRestaurantTimingConfig(
        restaurantId: locationId,
        createdAt: candidates.first.createdAt.toUtc().toIso8601String(),
        updatedAt: newest.toUtc().toIso8601String(),
      );
      return <String, Object?>{'timing_config': _timingConfigJson(config)};
    } on BusinessTimingProfileResolutionException {
      return const <String, Object?>{'timing_config': null};
    }
  }

  @override
  Future<Map<String, Object?>> fetchDemoModeStates({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) {
    return _tenantRead(scope, operatorId, locationId, (exec) async {
      final rows = await exec.query(
        'select operator_id::text as operator_id, '
        'location_id::text as location_id, category, is_demo, '
        'flipped_to_live_at, flipped_by_connection_id::text '
        'as flipped_by_connection_id '
        'from public.demo_mode_state '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'order by category asc',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      return <String, Object?>{
        'demo_mode_states': <Map<String, Object?>>[
          for (final row in rows) _demoModeJson(row),
        ],
      };
    });
  }

  @override
  Future<Map<String, Object?>> fetchDataAccuracySettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) {
    return _tenantRead(scope, operatorId, locationId, (exec) async {
      final rows = await exec.query(
        'select operator_id::text as operator_id, '
        'location_id::text as location_id, covers_source_lunch, '
        'covers_source_dinner, covers_source_late_night, '
        'covers_manual_entries, wage_source, '
        'walk_in_handling_mode, walk_in_manual_entries, updated_at '
        'from public.data_accuracy_settings '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      return <String, Object?>{
        'data': rows.isEmpty ? null : _dataAccuracyJson(rows.single),
      };
    });
  }

  @override
  Future<Map<String, Object?>> fetchDataAccuracyServicePeriodSettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) {
    return _tenantRead(scope, operatorId, locationId, (exec) async {
      final rows = await exec.query(
        'select id::text as id, '
        'operator_id::text as operator_id, '
        'location_id::text as location_id, '
        'service_period_key, covers_source, wage_source, '
        'effective_at_business_date::text as effective_at_business_date, '
        'created_at, updated_at, updated_by '
        'from public.data_accuracy_service_period_settings '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'order by service_period_key asc, '
        'effective_at_business_date desc',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      return <String, Object?>{
        'data_accuracy_service_period_settings': <Map<String, Object?>>[
          for (final row in rows) _dataAccuracyServicePeriodJson(row),
        ],
      };
    });
  }

  @override
  Future<Map<String, Object?>> fetchWageRoleRows({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? modifiedSince,
    required int pageSize,
  }) {
    return _tenantRead(scope, operatorId, locationId, (exec) async {
      final params = <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'limit': pageSize + 1,
      };
      final cursorSql = _modifiedSinceSql(modifiedSince, params);
      final rows = await exec.query(
        'select wage_role_row_id::text as server_id, '
        'operator_id::text as operator_id, '
        'location_id::text as location_id, restaurant_id, '
        'role_name, labor_bucket, hourly_rate, weighted_hours, '
        'job_code, vendor_id, vendor_role_id, source, is_active, '
        'effective_at, metadata, created_at, updated_at, updated_by '
        'from public.wage_role_rows '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and is_active is true '
        '$cursorSql'
        'order by updated_at asc, labor_bucket asc, role_name asc, '
        'wage_role_row_id asc '
        'limit @limit',
        parameters: params,
      );
      return _pagePayload(
        key: 'wage_role_rows',
        rows: rows,
        pageSize: pageSize,
        mapper: _wageRoleRowJson,
      );
    });
  }

  @override
  Future<Map<String, Object?>> fetchPollingTierAssignment({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) {
    return _tenantRead(scope, operatorId, locationId, (exec) async {
      final rows = await exec.query(
        'select operator_id::text as operator_id, '
        'location_id::text as location_id, tier_key, '
        'polling_cadence_per_vendor_seconds, monthly_price_cents, '
        'effective_at '
        'from public.forge_flow_polling_tier_assignment '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and effective_until is null '
        'order by effective_at desc '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      return <String, Object?>{
        'assignment': rows.isEmpty ? null : _pollingAssignmentJson(rows.single),
      };
    });
  }

  @override
  Future<Map<String, Object?>> fetchFirstBackfillStatus({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  }) {
    return _tenantRead(scope, operatorId, locationId, (exec) async {
      final rows = await exec.query(
        'select job_id::text as job_id, '
        'operator_id::text as operator_id, '
        'location_id::text as location_id, '
        'connection_id::text as connection_id, '
        'vendor_id, category, status, '
        'window_start, window_end, cursor_token, '
        'last_modified_seen, attempt_count, worker_id, '
        'claimed_at, completed_at, last_error, created_at, updated_at '
        'from public.connector_backfill_jobs '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        "and mode = 'first_backfill' "
        'order by case '
        "when status in ('pending', 'running') then 0 "
        "when status = 'failed' then 1 "
        'else 2 end, updated_at desc '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      return <String, Object?>{
        'first_backfill_status': rows.isEmpty
            ? null
            : _firstBackfillStatusJson(rows.single),
      };
    });
  }

  Future<T> _tenantRead<T>(
    OperatorContext scope,
    String operatorId,
    String locationId,
    Future<T> Function(PostgresExecutor exec) body,
  ) {
    return _tenantWrapper.runInTenantContext(
      TenantContext(
        operatorId: operatorId,
        locationId: locationId,
        userId: _uuidOrNull(scope.userId),
      ),
      body,
    );
  }

  static String _modifiedSinceSql(
    String? modifiedSince,
    Map<String, Object?> params,
  ) {
    if (modifiedSince == null) return '';
    params['modified_since'] = DateTime.parse(
      modifiedSince,
    ).toUtc().toIso8601String();
    return 'and updated_at > @modified_since::timestamptz ';
  }

  static Map<String, Object?> _pagePayload({
    required String key,
    required List<PostgresRow> rows,
    required int pageSize,
    required Map<String, Object?> Function(PostgresRow row) mapper,
  }) {
    final hasMore = rows.length > pageSize;
    final pageRows = hasMore ? rows.take(pageSize).toList() : rows;
    return <String, Object?>{
      key: <Map<String, Object?>>[for (final row in pageRows) mapper(row)],
      'next_cursor': hasMore ? _dateJson(pageRows.last['updated_at']) : null,
    };
  }

  static Map<String, Object?> _shiftRecordJson(PostgresRow row) {
    return <String, Object?>{
      'restaurant_id': row['restaurant_id'],
      'week_id': row['week_id'],
      'day_label': row['day_label'],
      'daypart': row['daypart'],
      'status': row['status'],
      'covers': _asInt(row['covers']),
      'forecast_covers': _asInt(row['forecast_covers']),
      'ppa': _asDouble(row['ppa']),
      'cplh': _asDouble(row['cplh']),
      'splh': _asDouble(row['splh']),
      'foh_hours': _asInt(row['foh_hours']),
      'boh_hours': _asInt(row['boh_hours']),
      'theoretical_labor_pct': _asDouble(row['theoretical_labor_pct']),
      'primary_lever': row['primary_lever'],
      'foh_labor_dollar': _nullableDouble(row['foh_labor_dollar']),
      'boh_labor_dollar': _nullableDouble(row['boh_labor_dollar']),
      'target_profile_id': row['target_profile_id'],
      'target_profile_version_id': row['target_profile_version_id'],
      'target_source_type': row['target_source_type'],
      'target_cplh': _nullableDouble(row['target_cplh']),
      'target_splh': _nullableDouble(row['target_splh']),
      'target_ppa': _nullableDouble(row['target_ppa']),
      'target_foh_wage': _nullableDouble(row['target_foh_wage']),
      'target_boh_wage': _nullableDouble(row['target_boh_wage']),
      'opz_floor_cplh': _nullableDouble(row['opz_floor_cplh']),
      'opz_ceiling_cplh': _nullableDouble(row['opz_ceiling_cplh']),
      'theoretical_foh_labor_pct': _nullableDouble(
        row['theoretical_foh_labor_pct'],
      ),
      'theoretical_boh_labor_pct': _nullableDouble(
        row['theoretical_boh_labor_pct'],
      ),
      'business_date': _dateOnly(row['business_date']),
      'business_timing_profile_id': row['business_timing_profile_id'],
      'business_timing_profile_version_id':
          row['business_timing_profile_version_id'],
      'service_period_key': row['service_period_key'],
      'source_system': row['source_system'],
      'source_shift_id': row['source_shift_id'],
    };
  }

  static Map<String, Object?> _openShiftSnapshotJson(PostgresRow row) {
    return <String, Object?>{
      'restaurant_id': row['restaurant_id'],
      'week_id': row['week_id'],
      'day_label': row['day_label'],
      'daypart': row['daypart'],
      'status': row['status'],
      'business_date': _dateOnly(row['business_date']),
      'business_timing_profile_id': row['business_timing_profile_id'],
      'business_timing_profile_version_id':
          row['business_timing_profile_version_id'],
      'service_period_key': row['service_period_key'],
      'forecast_covers': _asInt(row['forecast_covers']),
      'current_covers': _asInt(row['current_covers']),
      'scheduled_foh_hours': _asInt(row['scheduled_foh_hours']),
      'scheduled_boh_hours': _asInt(row['scheduled_boh_hours']),
      'current_ppa': _asDouble(row['current_ppa']),
      'current_cplh': _asDouble(row['current_cplh']),
      'current_splh': _asDouble(row['current_splh']),
      'blended_wage': _asDouble(row['blended_wage']),
      'time_label': row['time_label'] as String? ?? '',
      'service_elapsed_label': row['service_elapsed_label'] as String? ?? '',
      'source_system': row['source_system'],
      'source_shift_id': row['source_shift_id'],
      'last_event_at': _dateJson(row['last_event_at']),
      'updated_at': _dateJson(row['updated_at']) ?? _todayUtcInstant(),
    };
  }

  static BusinessTimingProfile _timingProfile(BusinessTimingProfileRow row) {
    return BusinessTimingProfile(
      profileId: row.profileId,
      scope: BusinessTimingScope.fromValue(row.scopeType),
      scopeId: row.scopeId,
      businessTimezone: row.locationTimezone,
      businessDayStartLocalTime: row.businessDayStartLocalTime,
      weekStartDay: row.weekStartDay,
      servicePeriodDefinitions: row.servicePeriods.isEmpty
          ? null
          : <ServicePeriodDefinition>[
              for (final period in row.servicePeriods)
                ServicePeriodDefinition(
                  id: period.servicePeriodKey,
                  label: period.label,
                  shortLabel: period.shortLabel,
                  sortOrder: period.sortOrder,
                  startLocalTime: period.startLocalTime,
                  endLocalTime: period.endLocalTime,
                  rollsPastMidnight: period.rollsPastMidnight,
                  applicableDays: period.applicableWeekdays,
                ),
            ],
      shiftCloseAuthority: ShiftCloseAuthority.fromValue(row.closeAuthority),
      localCloseFallback: row.localCloseFallbackTime,
    );
  }

  static Map<String, Object?> _timingConfigJson(RestaurantTimingConfig config) {
    return <String, Object?>{
      'restaurant_id': config.restaurantId,
      'business_timezone': config.businessTimezone,
      'business_day_start_local_time': config.businessDayStartLocalTime,
      'week_start_day': config.weekStartDay,
      'shift_close_authority': config.shiftCloseAuthority.value,
      'local_close_fallback': config.localCloseFallback,
      'created_at': config.createdAt,
      'updated_at': config.updatedAt,
      'service_period_definitions': <Map<String, Object?>>[
        for (final period in config.servicePeriodDefinitions) period.toMap(),
      ],
    };
  }

  static Map<String, Object?> _demoModeJson(PostgresRow row) {
    return <String, Object?>{
      'operator_id': row['operator_id'],
      'location_id': row['location_id'],
      'category': row['category'],
      'is_demo': row['is_demo'],
      'flipped_to_live_at': _dateJson(row['flipped_to_live_at']),
      'flipped_by_connection_id': row['flipped_by_connection_id'],
    };
  }

  static Map<String, Object?> _dataAccuracyJson(PostgresRow row) {
    return <String, Object?>{
      'operator_id': row['operator_id'],
      'location_id': row['location_id'],
      'covers_source_lunch': row['covers_source_lunch'] ?? 'vendor',
      'covers_source_dinner': row['covers_source_dinner'] ?? 'vendor',
      'covers_source_late_night': row['covers_source_late_night'] ?? 'vendor',
      'covers_manual_entries': _jsonMap(row['covers_manual_entries']),
      'wage_source': row['wage_source'] ?? 'vendor',
      'walk_in_handling_mode':
          row['walk_in_handling_mode'] ?? 'reservations_only',
      'walk_in_manual_entries': _jsonMap(row['walk_in_manual_entries']),
      'updated_at': _dateJson(row['updated_at']) ?? _todayUtcInstant(),
    };
  }

  static Map<String, Object?> _dataAccuracyServicePeriodJson(PostgresRow row) {
    return <String, Object?>{
      'id': row['id'],
      'operator_id': row['operator_id'],
      'location_id': row['location_id'],
      'service_period_key': row['service_period_key'],
      'effective_at_business_date': _dateOnly(
        row['effective_at_business_date'],
      ),
      'covers_source': row['covers_source'] ?? 'vendor',
      'wage_source': row['wage_source'] ?? 'vendor_per_employee',
      'created_at': _dateJson(row['created_at']) ?? _todayUtcInstant(),
      'updated_at': _dateJson(row['updated_at']) ?? _todayUtcInstant(),
      'updated_by': row['updated_by'],
    };
  }

  static Map<String, Object?> _wageRoleRowJson(PostgresRow row) {
    return <String, Object?>{
      'server_id': row['server_id'],
      'operator_id': row['operator_id'],
      'location_id': row['location_id'],
      'restaurant_id': row['restaurant_id'],
      'role_name': row['role_name'],
      'labor_bucket': row['labor_bucket'],
      'hourly_rate': _asDouble(row['hourly_rate']),
      'weighted_hours': _asDouble(row['weighted_hours']),
      'job_code': row['job_code'],
      'vendor_id': row['vendor_id'],
      'vendor_role_id': row['vendor_role_id'],
      'source': row['source'] ?? 'operator_manual',
      'is_active': row['is_active'] ?? true,
      'effective_at': _dateJson(row['effective_at']) ?? _todayUtcInstant(),
      'metadata': _jsonMap(row['metadata']),
      'created_at': _dateJson(row['created_at']) ?? _todayUtcInstant(),
      'updated_at': _dateJson(row['updated_at']) ?? _todayUtcInstant(),
      'updated_by': row['updated_by'],
    };
  }

  static Map<String, Object?> _pollingAssignmentJson(PostgresRow row) {
    return <String, Object?>{
      'operator_id': row['operator_id'],
      'location_id': row['location_id'],
      'tier_key': row['tier_key'],
      'polling_cadence_per_vendor_seconds': _intMap(
        _jsonMap(row['polling_cadence_per_vendor_seconds']),
      ),
      'monthly_price_cents': row['monthly_price_cents'],
      'effective_at': _dateJson(row['effective_at']) ?? _todayUtcInstant(),
    };
  }

  static Map<String, Object?> _firstBackfillStatusJson(PostgresRow row) {
    return <String, Object?>{
      'job_id': row['job_id'],
      'operator_id': row['operator_id'],
      'location_id': row['location_id'],
      'connection_id': row['connection_id'],
      'vendor_id': row['vendor_id'],
      'category': row['category'],
      'status': row['status'],
      'window_start': _dateJson(row['window_start']),
      'window_end': _dateJson(row['window_end']),
      'cursor_token': row['cursor_token'],
      'last_modified_seen': _dateJson(row['last_modified_seen']),
      'attempt_count': _asInt(row['attempt_count']),
      'worker_id': row['worker_id'],
      'claimed_at': _dateJson(row['claimed_at']),
      'completed_at': _dateJson(row['completed_at']),
      'last_error': row['last_error'],
      'created_at': _dateJson(row['created_at']) ?? _todayUtcInstant(),
      'updated_at': _dateJson(row['updated_at']) ?? _todayUtcInstant(),
    };
  }

  static Map<String, Object?> _jsonMap(Object? value) {
    if (value is Map<String, Object?>) return value;
    if (value is Map) return Map<String, Object?>.from(value);
    if (value is String && value.isNotEmpty) {
      final decoded = jsonDecode(value);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    }
    return const <String, Object?>{};
  }

  static Map<String, int> _intMap(Map<String, Object?> value) {
    return <String, int>{
      for (final entry in value.entries) entry.key: _asInt(entry.value),
    };
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static double _asDouble(Object? value) => _nullableDouble(value) ?? 0.0;

  static double? _nullableDouble(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }

  static String? _dateJson(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is String && value.isNotEmpty) {
      return DateTime.parse(value).toUtc().toIso8601String();
    }
    return null;
  }

  static String? _dateOnly(Object? value) {
    if (value == null) return null;
    if (value is DateTime) {
      return value.toUtc().toIso8601String().substring(0, 10);
    }
    if (value is String && value.isNotEmpty) {
      return value.length >= 10 ? value.substring(0, 10) : value;
    }
    return null;
  }

  static String _todayUtcDate() =>
      DateTime.now().toUtc().toIso8601String().substring(0, 10);

  static String _todayUtcInstant() => DateTime.now().toUtc().toIso8601String();

  static String? _uuidOrNull(String value) {
    return _uuidPattern.hasMatch(value) ? value : null;
  }

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
}

/// Production [OperatorLocationAdminProxyGateway] backed by
/// [OperatorsRepository] / [LocationsRepository] /
/// [OperatorAdminsRepository]. Translates the proxy's command shape
/// into repo calls and projects the row results into JSON-ready
/// maps the route handler can return as-is. Every UUID is generated
/// by Postgres (`default gen_random_uuid()`) and returned via
/// `RETURNING`, so multiple Cloud Run instances cannot collide on
/// IDs.
class RepositoryOperatorLocationAdminProxyGateway
    implements OperatorLocationAdminProxyGateway {
  RepositoryOperatorLocationAdminProxyGateway({
    required OperatorsRepository operatorsRepository,
    required LocationsRepository locationsRepository,
    required OperatorAdminsRepository operatorAdminsRepository,
    required AuthOperationsGateway authOperationsGateway,
    required AuthEventsAuditRepository auditRepository,
  }) : _operators = operatorsRepository,
       _locations = locationsRepository,
       _operatorAdmins = operatorAdminsRepository,
       _authOperationsGateway = authOperationsGateway,
       _auditRepository = auditRepository;

  final OperatorsRepository _operators;
  final LocationsRepository _locations;
  final OperatorAdminsRepository _operatorAdmins;
  final AuthOperationsGateway _authOperationsGateway;
  final AuthEventsAuditRepository _auditRepository;

  @override
  Future<List<Map<String, Object?>>> listOperatorsWithLocations({
    required String actorUserId,
    required String adminReason,
  }) async {
    final operators = await _operators.listOperators(adminReason: adminReason);
    final locationsByOperator = <String, List<LocationAdminRow>>{};
    final allLocations = await _locations.listAllLocations(
      adminReason: adminReason,
    );
    final adminGrantCounts = await _operatorAdmins.countByOperator(
      adminReason: '$adminReason:admin_grant_counts',
    );
    for (final loc in allLocations) {
      locationsByOperator
          .putIfAbsent(loc.operatorId, () => <LocationAdminRow>[])
          .add(loc);
    }
    final bundles = <Map<String, Object?>>[
      for (final op in operators)
        <String, Object?>{
          'operator': op.toJson(),
          'locations': <Map<String, Object?>>[
            for (final loc
                in locationsByOperator[op.operatorId] ??
                    const <LocationAdminRow>[])
              loc.toJson(),
          ],
          // Per-operator admin-grant count. The full list is loaded
          // on demand via the future per-operator detail endpoint
          // (Phase 11A.x). Surfacing the count here lets the admin
          // console flag operators without an admin attached.
          'admin_grant_count': adminGrantCounts[op.operatorId] ?? 0,
        },
    ];
    await _audit(
      actorUserId: actorUserId,
      eventType: 'admin.operator_location.list',
      adminReason: adminReason,
      payload: <String, Object?>{
        'operator_count': operators.length,
        'location_count': allLocations.length,
      },
    );
    return bundles;
  }

  @override
  Future<Map<String, Object?>> onboardOperator({
    required String actorUserId,
    required String businessName,
    required String ownerEmail,
    required String subscriptionTier,
    required String preferredCurrency,
    required String adminUserEmail,
    required String primaryLocationName,
    required String primaryLocationTimezone,
    required int primaryLocationRolloverHour,
    required String adminReason,
  }) async {
    final result = await _operators.onboardOperatorAtomically(
      businessName: businessName,
      ownerEmail: ownerEmail,
      subscriptionTier: subscriptionTier,
      preferredCurrency: preferredCurrency,
      locationName: primaryLocationName,
      locationAddress: '',
      locationTimezone: primaryLocationTimezone,
      locationRolloverHour: primaryLocationRolloverHour,
      adminReason: adminReason,
    );
    final invite = await _authOperationsGateway.createInvite(
      TeamInviteCreateCommand(
        actorUserId: actorUserId,
        operatorId: result.operator.operatorId,
        locationId: result.location.locationId,
        email: adminUserEmail,
        roleId: 'operator_owner',
        scopeType: 'operator_wide',
        operatorOwnerBootstrap: true,
      ),
    );
    final adminUserId = invite.userId;
    if (adminUserId == null || adminUserId.isEmpty) {
      throw StateError(
        'auth operations invite did not return the created user_id',
      );
    }
    await _operatorAdmins.upsertAdminGrant(
      userId: adminUserId,
      operatorId: result.operator.operatorId,
      isSuperAdmin: false,
      scopeType: 'operator_owner',
      adminReason: '$adminReason:operator_admins',
    );
    await _audit(
      actorUserId: actorUserId,
      targetUserId: adminUserId,
      operatorId: result.operator.operatorId,
      locationId: result.location.locationId,
      eventType: 'admin.operator_location.onboarded',
      adminReason: adminReason,
      payload: <String, Object?>{
        'business_name': businessName,
        'owner_email': ownerEmail,
        'admin_user_email': adminUserEmail,
        'invite_id': invite.inviteId,
      },
    );
    return <String, Object?>{
      'operator': result.operator.toJson(),
      'locations': <Map<String, Object?>>[result.location.toJson()],
      'admin_user_id': adminUserId,
      'admin_invite_id': invite.inviteId,
    };
  }

  @override
  Future<Map<String, Object?>?> patchOperator({
    required String actorUserId,
    required String operatorId,
    String? businessName,
    String? ownerEmail,
    String? subscriptionTier,
    String? preferredCurrency,
    String? primaryLocationId,
    required String adminReason,
  }) async {
    final updated = await _operators.updateOperator(
      operatorId: operatorId,
      businessName: businessName,
      ownerEmail: ownerEmail,
      subscriptionTier: subscriptionTier,
      preferredCurrency: preferredCurrency,
      primaryLocationId: primaryLocationId,
      adminReason: adminReason,
    );
    if (updated != null) {
      await _audit(
        actorUserId: actorUserId,
        operatorId: updated.operatorId,
        locationId: updated.primaryLocationId,
        eventType: 'admin.operator_location.operator_patched',
        adminReason: adminReason,
        payload: <String, Object?>{
          'changed_fields': <String>[
            if (businessName != null) 'business_name',
            if (ownerEmail != null) 'owner_email',
            if (subscriptionTier != null) 'subscription_tier',
            if (preferredCurrency != null) 'preferred_currency',
            if (primaryLocationId != null) 'primary_location_id',
          ],
        },
      );
    }
    return updated?.toJson();
  }

  @override
  Future<Map<String, Object?>?> suspendOperator({
    required String actorUserId,
    required String operatorId,
    required String adminReason,
  }) async {
    final updated = await _operators.suspendOperator(
      operatorId: operatorId,
      adminReason: adminReason,
    );
    if (updated != null) {
      await _audit(
        actorUserId: actorUserId,
        operatorId: updated.operatorId,
        locationId: updated.primaryLocationId,
        eventType: 'admin.operator_location.operator_suspended',
        adminReason: adminReason,
      );
    }
    return updated?.toJson();
  }

  @override
  Future<Map<String, Object?>?> reactivateOperator({
    required String actorUserId,
    required String operatorId,
    required String adminReason,
  }) async {
    final updated = await _operators.reactivateOperator(
      operatorId: operatorId,
      adminReason: adminReason,
    );
    if (updated != null) {
      await _audit(
        actorUserId: actorUserId,
        operatorId: updated.operatorId,
        locationId: updated.primaryLocationId,
        eventType: 'admin.operator_location.operator_reactivated',
        adminReason: adminReason,
      );
    }
    return updated?.toJson();
  }

  @override
  Future<Map<String, Object?>> addLocation({
    required String actorUserId,
    required String operatorId,
    required String name,
    required String address,
    required String timezone,
    required int businessDayRolloverHour,
    required String adminReason,
  }) async {
    final created = await _locations.insertLocation(
      operatorId: operatorId,
      name: name,
      address: address,
      timezone: timezone,
      businessDayRolloverHour: businessDayRolloverHour,
      adminReason: adminReason,
    );
    await _audit(
      actorUserId: actorUserId,
      operatorId: created.operatorId,
      locationId: created.locationId,
      eventType: 'admin.operator_location.location_added',
      adminReason: adminReason,
      payload: <String, Object?>{'name': name},
    );
    return created.toJson();
  }

  @override
  Future<Map<String, Object?>?> patchLocation({
    required String actorUserId,
    required String locationId,
    String? name,
    String? address,
    String? timezone,
    int? businessDayRolloverHour,
    required String adminReason,
  }) async {
    final patched = await _locations.updateLocation(
      locationId: locationId,
      name: name,
      address: address,
      timezone: timezone,
      businessDayRolloverHour: businessDayRolloverHour,
      adminReason: adminReason,
    );
    if (patched != null) {
      await _audit(
        actorUserId: actorUserId,
        operatorId: patched.operatorId,
        locationId: patched.locationId,
        eventType: 'admin.operator_location.location_patched',
        adminReason: adminReason,
        payload: <String, Object?>{
          'changed_fields': <String>[
            if (name != null) 'name',
            if (address != null) 'address',
            if (timezone != null) 'timezone',
            if (businessDayRolloverHour != null) 'business_day_rollover_hour',
          ],
        },
      );
    }
    return patched?.toJson();
  }

  @override
  Future<AdminLocationRemovalResult> removeLocation({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String adminReason,
  }) async {
    final operator = await _operators.findById(
      operatorId: operatorId,
      adminReason: '$adminReason:lookup',
    );
    if (operator == null) {
      return AdminLocationRemovalResult.notFound;
    }
    if (operator.primaryLocationId == locationId) {
      return AdminLocationRemovalResult.primaryLocationProtected;
    }
    final affected = await _locations.deleteLocation(
      locationId: locationId,
      operatorId: operatorId,
      adminReason: adminReason,
    );
    if (affected == 0) {
      return AdminLocationRemovalResult.notFound;
    }
    await _audit(
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      eventType: 'admin.operator_location.location_removed',
      adminReason: adminReason,
    );
    return AdminLocationRemovalResult.removed;
  }

  Future<void> _audit({
    required String actorUserId,
    required String eventType,
    required String adminReason,
    String? operatorId,
    String? locationId,
    String? targetUserId,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    return _auditRepository.insertSystemEvent(
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      targetUserId: targetUserId,
      eventType: eventType,
      adminReason: adminReason,
      payload: <String, Object?>{'admin_reason': adminReason, ...payload},
    );
  }
}

/// Locked tier-template caps the proxy seeds when the admin applies
/// a template. Mirrors the launch-time defaults in
/// `lib/admin/models/pricing_tier_admin_models.dart`. Keep in sync.
const Map<String, List<_PricingTierTemplateCap>> _kPricingTierTemplateCaps =
    <String, List<_PricingTierTemplateCap>>{
      'pilot': <_PricingTierTemplateCap>[
        _PricingTierTemplateCap(
          usageClass: 'advisor_qa',
          monthlyCapUsd: 50.0,
          perInvocationCapUsd: 0.10,
        ),
      ],
      'starter': <_PricingTierTemplateCap>[
        _PricingTierTemplateCap(
          usageClass: 'advisor_qa',
          monthlyCapUsd: 50.0,
          perInvocationCapUsd: 0.10,
        ),
      ],
      'premium': <_PricingTierTemplateCap>[
        _PricingTierTemplateCap(
          usageClass: 'advisor_qa',
          monthlyCapUsd: 200.0,
          perInvocationCapUsd: 0.20,
        ),
      ],
      'elite': <_PricingTierTemplateCap>[
        _PricingTierTemplateCap(
          usageClass: 'advisor_qa',
          monthlyCapUsd: 400.0,
          perInvocationCapUsd: 0.20,
        ),
        _PricingTierTemplateCap(
          usageClass: 'coach_qa',
          monthlyCapUsd: 300.0,
          perInvocationCapUsd: 0.20,
        ),
      ],
      'pro': <_PricingTierTemplateCap>[
        _PricingTierTemplateCap(
          usageClass: 'advisor_qa',
          monthlyCapUsd: 600.0,
          perInvocationCapUsd: 0.20,
        ),
        _PricingTierTemplateCap(
          usageClass: 'coach_qa',
          monthlyCapUsd: 400.0,
          perInvocationCapUsd: 0.20,
        ),
        _PricingTierTemplateCap(
          usageClass: 'workflow_pl',
          monthlyCapUsd: 500.0,
          perInvocationCapUsd: 5.0,
        ),
        _PricingTierTemplateCap(
          usageClass: 'workflow_schedule',
          monthlyCapUsd: 300.0,
          perInvocationCapUsd: 5.0,
        ),
      ],
      'enterprise': <_PricingTierTemplateCap>[],
    };

class _PricingTierTemplateCap {
  const _PricingTierTemplateCap({
    required this.usageClass,
    required this.monthlyCapUsd,
    required this.perInvocationCapUsd,
  });

  final String usageClass;
  final double monthlyCapUsd;
  final double perInvocationCapUsd;
}

/// Production [PricingTierAdminProxyGateway] backed by
/// [OperatorsRepository] + [UsageCapsRepository] +
/// [OrgUnitsRepository]. Translates the proxy's command shape into
/// repo calls and projects the row results into JSON-ready maps the
/// route handler can return as-is. Every edit threads `actorUserId`
/// into the repository's `created_by` / `updated_by` audit columns.
///
/// 9.0Σ.g `usage_caps` carries `billing_owner_org_unit_id` /
/// `scoped_org_unit_id` as NOT NULL columns on the post-flip schema.
/// For the launch admin pricing UX both axes resolve to the
/// operator's root `org_units` row (corp pays for corp scope); future
/// surfaces can pass distinct ids when corp / sub-brand billing
/// splits are wired.
class RepositoryPricingTierAdminProxyGateway
    implements PricingTierAdminProxyGateway {
  RepositoryPricingTierAdminProxyGateway({
    required OperatorsRepository operatorsRepository,
    required LocationsRepository locationsRepository,
    required UsageCapsRepository usageCapsRepository,
    required OrgUnitsRepository orgUnitsRepository,
    required AuthEventsAuditRepository auditRepository,
  }) : _operators = operatorsRepository,
       _locations = locationsRepository,
       _caps = usageCapsRepository,
       _orgUnits = orgUnitsRepository,
       _auditRepository = auditRepository;

  final OperatorsRepository _operators;
  final LocationsRepository _locations;
  final UsageCapsRepository _caps;
  final OrgUnitsRepository _orgUnits;
  final AuthEventsAuditRepository _auditRepository;

  /// Resolves the operator's root `org_units` id (the row with
  /// `parent_id IS NULL`). The 9.0Σ.g step-b backfill plus the
  /// `OrgUnitsRepository.createRoot` onboarding path guarantees one
  /// per operator. Throws [PricingTierAdminGatewayValidationError] if
  /// the operator has no root row (shouldn't happen post-backfill,
  /// but the admin path fails closed instead of letting the FK throw
  /// a 503).
  Future<String> _rootOrgUnitId({
    required String operatorId,
    required String adminReason,
  }) async {
    final roots = await _orgUnits.listAllRootsAsAdmin(
      adminReason: '$adminReason:org_units_root:$operatorId',
    );
    for (final row in roots) {
      if (row.operatorId == operatorId) return row.id;
    }
    throw const PricingTierAdminGatewayValidationError(
      statusCode: 400,
      code: 'no_org_unit_root',
      message:
          'operator has no root org_units row; run the 9.0Σ.g backfill before editing usage_caps',
    );
  }

  @override
  Future<List<Map<String, Object?>>> listOperatorsWithCaps({
    required String actorUserId,
    required String adminReason,
  }) async {
    final operators = await _operators.listOperators(adminReason: adminReason);
    final allLocations = await _locations.listAllLocations(
      adminReason: '$adminReason:locations',
    );
    final locationNamesById = <String, String>{
      for (final location in allLocations) location.locationId: location.name,
    };
    final allCaps = await _caps.listAllCaps(adminReason: adminReason);
    final capsByOperator = <String, List<UsageCapAdminRow>>{};
    for (final cap in allCaps) {
      capsByOperator
          .putIfAbsent(cap.operatorId, () => <UsageCapAdminRow>[])
          .add(cap);
    }
    final bundles = <Map<String, Object?>>[
      for (final op in operators)
        <String, Object?>{
          'operator': <String, Object?>{
            'operator_id': op.operatorId,
            'business_name': op.businessName,
            'subscription_tier': op.subscriptionTier,
            'preferred_currency': op.preferredCurrency,
            'primary_location_id': op.primaryLocationId,
            'primary_location_name': op.primaryLocationId == null
                ? null
                : locationNamesById[op.primaryLocationId],
            'suspended': op.suspendedAt != null,
          },
          'caps': <Map<String, Object?>>[
            for (final cap
                in capsByOperator[op.operatorId] ?? const <UsageCapAdminRow>[])
              cap.toJson(),
          ],
        },
    ];
    await _audit(
      actorUserId: actorUserId,
      eventType: 'admin.pricing.list',
      adminReason: adminReason,
      payload: <String, Object?>{
        'operator_count': operators.length,
        'cap_count': allCaps.length,
      },
    );
    return bundles;
  }

  @override
  Future<Map<String, Object?>?> updateOperatorTier({
    required String actorUserId,
    required String operatorId,
    required String subscriptionTier,
    required String adminReason,
  }) async {
    final updated = await _operators.updateOperator(
      operatorId: operatorId,
      subscriptionTier: subscriptionTier,
      adminReason: adminReason,
    );
    if (updated == null) return null;
    await _audit(
      actorUserId: actorUserId,
      operatorId: updated.operatorId,
      locationId: updated.primaryLocationId,
      eventType: 'admin.pricing.tier_patched',
      adminReason: adminReason,
      payload: <String, Object?>{'subscription_tier': subscriptionTier},
    );
    return _bundleFor(updated, adminReason: adminReason);
  }

  @override
  Future<Map<String, Object?>> upsertUsageCap({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String usageClass,
    required double monthlyCapUsd,
    required double perInvocationCapUsd,
    String? staffId,
    String? workflowId,
    required String adminReason,
  }) async {
    final orgUnitId = await _rootOrgUnitId(
      operatorId: operatorId,
      adminReason: adminReason,
    );
    final cap = await _caps.upsertCap(
      operatorId: operatorId,
      billingOwnerOrgUnitId: orgUnitId,
      scopedOrgUnitId: orgUnitId,
      locationId: locationId,
      usageClass: usageClass,
      monthlyCapUsd: monthlyCapUsd,
      perInvocationCapUsd: perInvocationCapUsd,
      staffId: staffId,
      workflowId: workflowId,
      actorUserId: actorUserId,
      adminReason: adminReason,
    );
    await _audit(
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      eventType: 'admin.pricing.cap_upserted',
      adminReason: adminReason,
      payload: <String, Object?>{
        'usage_class': usageClass,
        'monthly_cap_usd': monthlyCapUsd,
        'per_invocation_cap_usd': perInvocationCapUsd,
        if (staffId != null) 'staff_id': staffId,
        if (workflowId != null) 'workflow_id': workflowId,
      },
    );
    return cap.toJson();
  }

  @override
  Future<Map<String, Object?>?> applyTierTemplate({
    required String actorUserId,
    required String operatorId,
    required String tierKey,
    required String adminReason,
  }) async {
    final template = _kPricingTierTemplateCaps[tierKey];
    if (template == null) return null;
    // Validate every precondition BEFORE any write so a failure can
    // never leave the operator in a partial state (subscription_tier
    // updated but cap rows never seeded). Specifically: confirm the
    // operator exists, has a primary_location_id, and has a root
    // org_units row.
    final existing = await _operators.findById(
      operatorId: operatorId,
      adminReason: '$adminReason:lookup',
    );
    if (existing == null) return null;
    final primaryLocation = existing.primaryLocationId;
    if (primaryLocation == null) {
      throw const PricingTierAdminGatewayValidationError(
        statusCode: 400,
        code: 'no_primary_location',
        message:
            'operator must have a primary_location_id before a tier template can be applied',
      );
    }
    final orgUnitId = await _rootOrgUnitId(
      operatorId: operatorId,
      adminReason: adminReason,
    );
    final updatedOperator = await _operators.updateOperator(
      operatorId: operatorId,
      subscriptionTier: tierKey,
      adminReason: adminReason,
    );
    if (updatedOperator == null) return null;
    for (final cap in template) {
      await _caps.upsertCap(
        operatorId: operatorId,
        billingOwnerOrgUnitId: orgUnitId,
        scopedOrgUnitId: orgUnitId,
        locationId: primaryLocation,
        usageClass: cap.usageClass,
        monthlyCapUsd: cap.monthlyCapUsd,
        perInvocationCapUsd: cap.perInvocationCapUsd,
        actorUserId: actorUserId,
        adminReason: '$adminReason:${cap.usageClass}',
      );
    }
    await _audit(
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: primaryLocation,
      eventType: 'admin.pricing.template_applied',
      adminReason: adminReason,
      payload: <String, Object?>{
        'tier_key': tierKey,
        'cap_rows': template.length,
      },
    );
    return _bundleFor(updatedOperator, adminReason: adminReason);
  }

  Future<Map<String, Object?>> _bundleFor(
    OperatorAdminRow operator, {
    required String adminReason,
  }) async {
    final caps = await _caps.listForOperator(
      operatorId: operator.operatorId,
      adminReason: '$adminReason:bundle:${operator.operatorId}',
    );
    final locations = await _locations.listForOperator(
      operatorId: operator.operatorId,
      adminReason: '$adminReason:bundle_locations:${operator.operatorId}',
    );
    final locationNamesById = <String, String>{
      for (final location in locations) location.locationId: location.name,
    };
    return <String, Object?>{
      'operator': <String, Object?>{
        'operator_id': operator.operatorId,
        'business_name': operator.businessName,
        'subscription_tier': operator.subscriptionTier,
        'preferred_currency': operator.preferredCurrency,
        'primary_location_id': operator.primaryLocationId,
        'primary_location_name': operator.primaryLocationId == null
            ? null
            : locationNamesById[operator.primaryLocationId],
        'suspended': operator.suspendedAt != null,
      },
      'caps': <Map<String, Object?>>[for (final cap in caps) cap.toJson()],
    };
  }

  Future<void> _audit({
    required String actorUserId,
    required String eventType,
    required String adminReason,
    String? operatorId,
    String? locationId,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    return _auditRepository.insertSystemEvent(
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      eventType: eventType,
      adminReason: adminReason,
      payload: <String, Object?>{'admin_reason': adminReason, ...payload},
    );
  }
}

/// Production [CorpusAdminProxyGateway] backed by [CorpusRepository].
///
/// Live chunking, embedding generation, and Voyage / Anthropic calls
/// are out of scope for this slice — the production binding wires the
/// admin path against the repository's existing transactional commit
/// helper. The actual upload pipeline lights up in 11A.3b once the
/// markdown chunker is split out of `tool/advisor_corpus/main.dart`
/// into a server-side helper. The current binding rejects an upload
/// until that helper is wired so the route never silently writes an
/// empty version row in production.
class RepositoryDataAccuracyAdminProxyGateway
    implements DataAccuracyAdminProxyGateway {
  RepositoryDataAccuracyAdminProxyGateway({
    required TenantTransactionWrapper adminWrapper,
    required AuthEventsAuditRepository auditRepository,
  }) : _adminWrapper = adminWrapper,
       _auditRepository = auditRepository;

  final TenantTransactionWrapper _adminWrapper;
  final AuthEventsAuditRepository _auditRepository;

  static final DateTime _definitionEditedAt = DateTime.utc(2026, 5, 5);

  @override
  Future<List<Map<String, Object?>>> listDataAccuracyRows({
    required String actorUserId,
    required String adminReason,
  }) {
    return _adminWrapper.runAsSystem<List<Map<String, Object?>>>((exec) async {
      final rows = await exec.query(
        'select '
        'o.operator_id::text as operator_id, '
        'o.business_name, '
        'l.location_id::text as location_id, '
        'l.name as location_name, '
        's.setting_id::text as setting_id, '
        's.covers_source_lunch, s.covers_source_dinner, '
        's.covers_source_late_night, s.covers_manual_entries, '
        's.wage_source, s.walk_in_handling_mode, '
        's.walk_in_manual_entries, '
        's.created_at, s.updated_at, s.updated_by '
        'from operators o '
        'join locations l on l.operator_id = o.operator_id '
        'left join data_accuracy_settings s '
        'on s.operator_id = l.operator_id '
        'and s.location_id = l.location_id '
        'order by o.business_name asc, l.created_at asc',
      );
      await _auditOn(
        exec,
        actorUserId: actorUserId,
        eventType: 'admin.data_accuracy.list',
        adminReason: adminReason,
        payload: <String, Object?>{'row_count': rows.length},
      );
      return <Map<String, Object?>>[
        for (final row in rows) _dataAccuracyRowJson(row),
      ];
    }, reason: adminReason);
  }

  @override
  Future<List<Map<String, Object?>>> listAuditHistory({
    required String actorUserId,
    String? operatorId,
    String? locationId,
    required String adminReason,
  }) {
    return _adminWrapper.runAsSystem<List<Map<String, Object?>>>((exec) async {
      final params = <String, Object?>{};
      var filter =
          "where (event_type like 'admin.data_accuracy.%' "
          "or event_type like 'admin.polling_pricing.%') ";
      if (operatorId != null && operatorId.isNotEmpty) {
        filter += 'and operator_id = @operator_id::uuid ';
        params['operator_id'] = operatorId;
      }
      if (locationId != null && locationId.isNotEmpty) {
        filter += 'and location_id = @location_id::uuid ';
        params['location_id'] = locationId;
      }
      final rows = await exec.query(
        'select event_id::text as event_id, event_type, occurred_at, '
        'actor_user_id::text as actor_user_id, actor_kind, '
        'operator_id::text as operator_id, location_id::text as location_id, '
        'event_payload '
        'from auth_events_audit '
        '$filter'
        'order by occurred_at desc '
        'limit 100',
        parameters: params,
      );
      await _auditOn(
        exec,
        actorUserId: actorUserId,
        eventType: 'admin.data_accuracy.audit_history.list',
        operatorId: operatorId,
        locationId: locationId,
        adminReason: adminReason,
        payload: <String, Object?>{'event_count': rows.length},
      );
      return <Map<String, Object?>>[
        for (final row in rows) _auditEventJson(row),
      ];
    }, reason: adminReason);
  }

  @override
  Future<Map<String, Object?>?> overrideDataAccuracy({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    String? coversSourceLunch,
    String? coversSourceDinner,
    String? coversSourceLateNight,
    String? wageSource,
    String? walkInHandlingMode,
    String? reasonNote,
    required String adminReason,
  }) {
    _validateCoversSource(coversSourceLunch, 'covers_source_lunch');
    _validateCoversSource(coversSourceDinner, 'covers_source_dinner');
    _validateCoversSource(coversSourceLateNight, 'covers_source_late_night');
    _validateWageSource(wageSource);
    _validateWalkInHandlingMode(walkInHandlingMode);
    return _adminWrapper.runAsSystem<Map<String, Object?>?>((exec) async {
      final ref = await _operatorLocationRef(
        exec,
        operatorId: operatorId,
        locationId: locationId,
      );
      if (ref == null) return null;
      final before = await _currentDataAccuracySettings(
        exec,
        operatorId: operatorId,
        locationId: locationId,
      );
      final rows = await exec.query(
        'insert into data_accuracy_settings ('
        'operator_id, location_id, covers_source_lunch, '
        'covers_source_dinner, covers_source_late_night, wage_source, '
        'walk_in_handling_mode, updated_by) values ('
        '@operator_id::uuid, @location_id::uuid, '
        "coalesce(@covers_lunch, 'vendor'), "
        "coalesce(@covers_dinner, 'vendor'), "
        "coalesce(@covers_late_night, 'vendor'), "
        "coalesce(@wage_source, 'vendor'), "
        "coalesce(@walk_in_handling_mode, 'reservations_only'), "
        '@updated_by) '
        'on conflict (operator_id, location_id) do update set '
        'covers_source_lunch = coalesce('
        '@covers_lunch, data_accuracy_settings.covers_source_lunch), '
        'covers_source_dinner = coalesce('
        '@covers_dinner, data_accuracy_settings.covers_source_dinner), '
        'covers_source_late_night = coalesce('
        '@covers_late_night, '
        'data_accuracy_settings.covers_source_late_night), '
        'wage_source = coalesce('
        '@wage_source, data_accuracy_settings.wage_source), '
        'walk_in_handling_mode = coalesce('
        '@walk_in_handling_mode, '
        'data_accuracy_settings.walk_in_handling_mode), '
        'updated_at = now(), updated_by = @updated_by '
        'returning '
        'setting_id::text as setting_id, '
        'operator_id::text as operator_id, '
        'location_id::text as location_id, '
        'covers_source_lunch, covers_source_dinner, '
        'covers_source_late_night, covers_manual_entries, wage_source, '
        'walk_in_handling_mode, walk_in_manual_entries, '
        'created_at, updated_at, updated_by',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'covers_lunch': coversSourceLunch,
          'covers_dinner': coversSourceDinner,
          'covers_late_night': coversSourceLateNight,
          'wage_source': wageSource,
          'walk_in_handling_mode': walkInHandlingMode,
          'updated_by': actorUserId,
        },
      );
      if (rows.isEmpty) return null;
      final after = _settingsJson(rows.single);
      await _auditOn(
        exec,
        actorUserId: actorUserId,
        operatorId: operatorId,
        locationId: locationId,
        eventType: 'admin.data_accuracy.override',
        adminReason: adminReason,
        payload: <String, Object?>{
          'diff': _settingsDiff(before, after),
          if (reasonNote != null) 'reason_note': reasonNote,
          'admin_reason': adminReason,
        },
      );
      return <String, Object?>{'operator_ref': ref, 'settings': after};
    }, reason: adminReason);
  }

  @override
  Future<List<Map<String, Object?>>> listTierDefinitions({
    required String actorUserId,
    required String adminReason,
  }) {
    return _adminWrapper.runAsSystem<List<Map<String, Object?>>>((exec) async {
      final definitions = _tierDefinitions();
      await _auditOn(
        exec,
        actorUserId: actorUserId,
        eventType: 'admin.polling_pricing.tier_definitions.list',
        adminReason: adminReason,
        payload: <String, Object?>{'definition_count': definitions.length},
      );
      return definitions;
    }, reason: adminReason);
  }

  @override
  Future<Map<String, Object?>> updateTierDefinition({
    required String actorUserId,
    required String tierKey,
    String? descriptionMd,
    Map<String, int>? pollingCadencePerVendorSeconds,
    int? defaultMonthlyPriceCents,
    int? vendorApiCostEstimateCentsMonthly,
    String? reasonNote,
    required String adminReason,
  }) {
    _validateTierKey(tierKey);
    throw const DataAccuracyAdminGatewayValidationError(
      statusCode: 501,
      code: 'tier_definitions_read_only',
      message:
          'tier definition persistence is not configured; update per-location assignments instead',
    );
  }

  @override
  Future<List<Map<String, Object?>>> listTierAssignments({
    required String actorUserId,
    required String adminReason,
  }) {
    return _adminWrapper.runAsSystem<List<Map<String, Object?>>>((exec) async {
      final rows = await exec.query(
        'select '
        'o.operator_id::text as operator_id, '
        'o.business_name, '
        'l.location_id::text as location_id, '
        'l.name as location_name, '
        'a.assignment_id::text as assignment_id, '
        'a.tier_key, a.polling_cadence_per_vendor_seconds, '
        'a.monthly_price_cents, '
        'a.vendor_api_cost_estimate_cents_monthly, '
        'a.effective_at, a.effective_until, '
        'a.assigned_by_admin_user_id, a.created_at '
        'from operators o '
        'join locations l on l.operator_id = o.operator_id '
        'left join forge_flow_polling_tier_assignment a '
        'on a.operator_id = l.operator_id '
        'and a.location_id = l.location_id '
        'and a.effective_until is null '
        'order by o.business_name asc, l.created_at asc',
      );
      await _auditOn(
        exec,
        actorUserId: actorUserId,
        eventType: 'admin.polling_pricing.assignments.list',
        adminReason: adminReason,
        payload: <String, Object?>{'row_count': rows.length},
      );
      return <Map<String, Object?>>[
        for (final row in rows) _assignmentRowJson(row),
      ];
    }, reason: adminReason);
  }

  @override
  Future<Map<String, Object?>?> assignTier({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String tierKey,
    Map<String, int>? customCadencePerVendorSeconds,
    int? monthlyPriceCentsOverride,
    int? vendorApiCostEstimateCentsMonthlyOverride,
    String? adminNotes,
    String? reasonNote,
    required String adminReason,
  }) {
    final tier = _validateTierKey(tierKey);
    return _adminWrapper.runAsSystem<Map<String, Object?>?>((exec) async {
      final ref = await _operatorLocationRef(
        exec,
        operatorId: operatorId,
        locationId: locationId,
      );
      if (ref == null) return null;
      final before = await _currentTierAssignment(
        exec,
        operatorId: operatorId,
        locationId: locationId,
      );
      final definition = _definitionFor(tier);
      final cadence =
          customCadencePerVendorSeconds ??
          Map<String, int>.from(
            definition['polling_cadence_per_vendor_seconds'] as Map,
          );
      final price =
          monthlyPriceCentsOverride ??
          definition['default_monthly_price_cents'] as int?;
      final cost =
          vendorApiCostEstimateCentsMonthlyOverride ??
          definition['vendor_api_cost_estimate_cents_monthly'] as int?;
      await exec.execute(
        'update forge_flow_polling_tier_assignment '
        'set effective_until = now() '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and effective_until is null',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      final rows = await exec.query(
        'insert into forge_flow_polling_tier_assignment ('
        'operator_id, location_id, tier_key, '
        'polling_cadence_per_vendor_seconds, '
        'monthly_price_cents, vendor_api_cost_estimate_cents_monthly, '
        'assigned_by_admin_user_id) values ('
        '@operator_id::uuid, @location_id::uuid, @tier_key, '
        '@cadence::jsonb, @monthly_price_cents, '
        '@vendor_api_cost_estimate_cents_monthly, @admin_user_id) '
        'returning '
        'assignment_id::text as assignment_id, '
        'operator_id::text as operator_id, '
        'location_id::text as location_id, '
        'tier_key, polling_cadence_per_vendor_seconds, '
        'monthly_price_cents, vendor_api_cost_estimate_cents_monthly, '
        'effective_at, effective_until, '
        'assigned_by_admin_user_id, created_at',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'tier_key': tier.wire,
          'cadence': jsonEncode(cadence),
          'monthly_price_cents': price,
          'vendor_api_cost_estimate_cents_monthly': cost,
          'admin_user_id': actorUserId,
        },
      );
      if (rows.isEmpty) return null;
      final assignment = _assignmentJson(rows.single);
      await _auditOn(
        exec,
        actorUserId: actorUserId,
        operatorId: operatorId,
        locationId: locationId,
        eventType: 'admin.polling_pricing.assign_tier',
        adminReason: adminReason,
        payload: <String, Object?>{
          'diff': <String, Object?>{
            'tier_key': <String, Object?>{
              'from': before?['tier_key'],
              'to': tier.wire,
            },
            'polling_cadence_per_vendor_seconds': <String, Object?>{
              'from': before?['polling_cadence_per_vendor_seconds'],
              'to': cadence,
            },
            'monthly_price_cents': <String, Object?>{
              'from': before?['monthly_price_cents'],
              'to': price,
            },
            'vendor_api_cost_estimate_cents_monthly': <String, Object?>{
              'from': before?['vendor_api_cost_estimate_cents_monthly'],
              'to': cost,
            },
          },
          if (adminNotes != null) 'admin_notes': adminNotes,
          if (reasonNote != null) 'reason_note': reasonNote,
          'admin_reason': adminReason,
        },
      );
      return <String, Object?>{
        'operator_ref': ref,
        'assignment': assignment,
        if (adminNotes != null) 'admin_notes': adminNotes,
      };
    }, reason: adminReason);
  }

  @override
  Future<Map<String, Object?>> summarizeMargin({
    required String actorUserId,
    String? tierKey,
    required String adminReason,
  }) {
    if (tierKey != null) _validateTierKey(tierKey);
    return _adminWrapper.runAsSystem<Map<String, Object?>>((exec) async {
      final assignments = await _currentAssignments(exec, tierKey: tierKey);
      final rollup = _marginRollupJson(assignments);
      await _auditOn(
        exec,
        actorUserId: actorUserId,
        eventType: 'admin.polling_pricing.margin.summarize',
        adminReason: adminReason,
        payload: <String, Object?>{
          if (tierKey != null) 'tier_key': tierKey,
          'assignment_count': assignments.length,
        },
      );
      return rollup;
    }, reason: adminReason);
  }

  @override
  Future<String> exportMarginRollupCsv({
    required String actorUserId,
    required String adminReason,
  }) {
    return _adminWrapper.runAsSystem<String>((exec) async {
      final assignments = await _currentAssignments(exec);
      final rollup = _marginRollupJson(assignments);
      final csv = _marginRollupCsv(rollup);
      await _auditOn(
        exec,
        actorUserId: actorUserId,
        eventType: 'admin.polling_pricing.margin.export_csv',
        adminReason: adminReason,
        payload: <String, Object?>{
          'assignment_count': assignments.length,
          'admin_reason': adminReason,
        },
      );
      return csv;
    }, reason: adminReason);
  }

  @override
  Future<List<Map<String, Object?>>> listTierChangeRequests({
    required String actorUserId,
    required String adminReason,
  }) {
    return _adminWrapper.runAsSystem<List<Map<String, Object?>>>((exec) async {
      await _auditOn(
        exec,
        actorUserId: actorUserId,
        eventType: 'admin.polling_pricing.change_requests.list',
        adminReason: adminReason,
        payload: const <String, Object?>{'request_count': 0},
      );
      return const <Map<String, Object?>>[];
    }, reason: adminReason);
  }

  @override
  Future<Map<String, Object?>?> resolveTierChangeRequest({
    required String actorUserId,
    required String requestId,
    required String status,
    String? reasonNote,
    required String adminReason,
  }) {
    _validateTierChangeStatus(status);
    throw const DataAccuracyAdminGatewayValidationError(
      statusCode: 501,
      code: 'tier_change_requests_not_configured',
      message: 'tier change request persistence is not configured',
    );
  }

  Future<Map<String, Object?>?> _operatorLocationRef(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
  }) async {
    final rows = await exec.query(
      'select o.operator_id::text as operator_id, '
      'o.business_name, l.location_id::text as location_id, '
      'l.name as location_name '
      'from operators o '
      'join locations l on l.operator_id = o.operator_id '
      'where o.operator_id = @operator_id::uuid '
      'and l.location_id = @location_id::uuid '
      'limit 1',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
      },
    );
    if (rows.isEmpty) return null;
    return _operatorRefJson(rows.single);
  }

  Future<Map<String, Object?>?> _currentDataAccuracySettings(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
  }) async {
    final rows = await exec.query(
      'select setting_id::text as setting_id, '
      'operator_id::text as operator_id, location_id::text as location_id, '
      'covers_source_lunch, covers_source_dinner, covers_source_late_night, '
      'covers_manual_entries, wage_source, '
      'walk_in_handling_mode, walk_in_manual_entries, '
      'created_at, updated_at, updated_by '
      'from data_accuracy_settings '
      'where operator_id = @operator_id::uuid '
      'and location_id = @location_id::uuid',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
      },
    );
    if (rows.isEmpty) return null;
    return _settingsJson(rows.single);
  }

  Future<Map<String, Object?>?> _currentTierAssignment(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
  }) async {
    final rows = await exec.query(
      'select assignment_id::text as assignment_id, '
      'operator_id::text as operator_id, location_id::text as location_id, '
      'tier_key, polling_cadence_per_vendor_seconds, '
      'monthly_price_cents, vendor_api_cost_estimate_cents_monthly, '
      'effective_at, effective_until, assigned_by_admin_user_id, created_at '
      'from forge_flow_polling_tier_assignment '
      'where operator_id = @operator_id::uuid '
      'and location_id = @location_id::uuid '
      'and effective_until is null',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
      },
    );
    if (rows.isEmpty) return null;
    return _assignmentJson(rows.single);
  }

  Future<List<Map<String, Object?>>> _currentAssignments(
    PostgresExecutor exec, {
    String? tierKey,
  }) async {
    final params = <String, Object?>{};
    var sql =
        'select assignment_id::text as assignment_id, '
        'operator_id::text as operator_id, location_id::text as location_id, '
        'tier_key, polling_cadence_per_vendor_seconds, '
        'monthly_price_cents, vendor_api_cost_estimate_cents_monthly, '
        'effective_at, effective_until, assigned_by_admin_user_id, created_at '
        'from forge_flow_polling_tier_assignment '
        'where effective_until is null ';
    if (tierKey != null) {
      sql += 'and tier_key = @tier_key ';
      params['tier_key'] = tierKey;
    }
    sql += 'order by effective_at desc';
    final rows = await exec.query(sql, parameters: params);
    return <Map<String, Object?>>[for (final row in rows) _assignmentJson(row)];
  }

  Future<void> _auditOn(
    PostgresExecutor exec, {
    required String actorUserId,
    required String eventType,
    required String adminReason,
    String? operatorId,
    String? locationId,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    return _auditRepository.insertSystemEventOn(
      exec,
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      eventType: eventType,
      payload: <String, Object?>{'admin_reason': adminReason, ...payload},
    );
  }

  static Map<String, Object?> _dataAccuracyRowJson(Map<String, Object?> row) {
    return <String, Object?>{
      'operator_ref': _operatorRefJson(row),
      'settings': _settingsJson(row),
    };
  }

  static Map<String, Object?> _operatorRefJson(Map<String, Object?> row) {
    return <String, Object?>{
      'operator_id': row['operator_id'],
      'business_name': row['business_name'],
      'location_id': row['location_id'],
      'location_name': row['location_name'],
    };
  }

  static Map<String, Object?> _settingsJson(Map<String, Object?> row) {
    final operatorId = row['operator_id'] as String? ?? '';
    final locationId = row['location_id'] as String? ?? '';
    return <String, Object?>{
      'setting_id':
          row['setting_id'] as String? ?? 'default:$operatorId:$locationId',
      'operator_id': operatorId,
      'location_id': locationId,
      'covers_source_lunch': row['covers_source_lunch'] as String? ?? 'vendor',
      'covers_source_dinner':
          row['covers_source_dinner'] as String? ?? 'vendor',
      'covers_source_late_night':
          row['covers_source_late_night'] as String? ?? 'vendor',
      'covers_manual_entries': _jsonMap(row['covers_manual_entries']),
      'wage_source': row['wage_source'] as String? ?? 'vendor',
      'walk_in_handling_mode':
          row['walk_in_handling_mode'] as String? ?? 'reservations_only',
      'walk_in_manual_entries': _jsonMap(row['walk_in_manual_entries']),
      'created_at':
          _dateJson(row['created_at']) ?? DateTime.utc(1970).toIso8601String(),
      'updated_at':
          _dateJson(row['updated_at']) ?? DateTime.utc(1970).toIso8601String(),
      'updated_by': row['updated_by'],
    };
  }

  static Map<String, Object?> _assignmentRowJson(Map<String, Object?> row) {
    return <String, Object?>{
      'operator_ref': _operatorRefJson(row),
      'assignment': row['assignment_id'] == null ? null : _assignmentJson(row),
      'admin_notes': null,
    };
  }

  static Map<String, Object?> _assignmentJson(Map<String, Object?> row) {
    return <String, Object?>{
      'assignment_id': row['assignment_id'],
      'operator_id': row['operator_id'],
      'location_id': row['location_id'],
      'tier_key': row['tier_key'],
      'polling_cadence_per_vendor_seconds': _intMap(
        _jsonMap(row['polling_cadence_per_vendor_seconds']),
      ),
      'monthly_price_cents': row['monthly_price_cents'],
      'vendor_api_cost_estimate_cents_monthly':
          row['vendor_api_cost_estimate_cents_monthly'],
      'effective_at': _dateJson(row['effective_at']),
      'effective_until': _dateJson(row['effective_until']),
      'assigned_by_admin_user_id': row['assigned_by_admin_user_id'],
      'created_at': _dateJson(row['created_at']),
    };
  }

  static Map<String, Object?> _auditEventJson(Map<String, Object?> row) {
    final payload = _jsonMap(row['event_payload']);
    return <String, Object?>{
      'event_id': row['event_id'],
      'event_type': row['event_type'],
      'occurred_at': _dateJson(row['occurred_at']),
      'actor_user_id': row['actor_user_id'],
      'actor_kind': row['actor_kind'] as String? ?? 'user',
      'operator_id': row['operator_id'],
      'location_id': row['location_id'],
      'diff': _jsonMap(payload['diff']),
      'reason_note': payload['reason_note'],
    };
  }

  static List<Map<String, Object?>> _tierDefinitions() {
    return <Map<String, Object?>>[
      _tierDefinitionJson(
        tierKey: PollingTierKey.standard,
        description:
            'Standard polling cadence for launch operators. Poll-only vendors use five-minute cadence defaults.',
        cadence: kStandardTierPresets,
        defaultPriceCents: 9900,
        vendorCostCents: 1200,
      ),
      _tierDefinitionJson(
        tierKey: PollingTierKey.premium,
        description:
            'Premium cadence for high-touch operators. Vendors that allow 60s polling use 60s cadence; Oracle remains at its vendor minimum.',
        cadence: kPremiumTierPresets,
        defaultPriceCents: 19900,
        vendorCostCents: 4800,
      ),
      _tierDefinitionJson(
        tierKey: PollingTierKey.custom,
        description:
            'Custom operator/location cadence. Admins set per-vendor values on each assignment.',
        cadence: const <String, int>{},
        defaultPriceCents: 0,
        vendorCostCents: 0,
      ),
    ];
  }

  static Map<String, Object?> _definitionFor(PollingTierKey tier) {
    return _tierDefinitions().singleWhere(
      (definition) => definition['tier_key'] == tier.wire,
    );
  }

  static Map<String, Object?> _tierDefinitionJson({
    required PollingTierKey tierKey,
    required String description,
    required Map<String, int> cadence,
    required int defaultPriceCents,
    required int vendorCostCents,
  }) {
    return <String, Object?>{
      'tier_key': tierKey.wire,
      'description_md': description,
      'polling_cadence_per_vendor_seconds': Map<String, int>.from(cadence),
      'default_monthly_price_cents': defaultPriceCents,
      'vendor_api_cost_estimate_cents_monthly': vendorCostCents,
      'last_edited_at': _definitionEditedAt.toIso8601String(),
      'last_edited_by': 'system',
    };
  }

  static Map<String, Object?> _marginRollupJson(
    List<Map<String, Object?>> assignments,
  ) {
    var totalPrice = 0;
    var totalCost = 0;
    final perTier = <String, _DataAccuracyTierAccumulator>{};
    final perVendor = <String, int>{};
    for (final assignment in assignments) {
      final tier = assignment['tier_key'] as String? ?? 'custom';
      final price = _asInt(assignment['monthly_price_cents']);
      final cost = _asInt(assignment['vendor_api_cost_estimate_cents_monthly']);
      totalPrice += price;
      totalCost += cost;
      final tierAcc = perTier.putIfAbsent(
        tier,
        () => _DataAccuracyTierAccumulator(tier),
      );
      tierAcc.assignmentCount += 1;
      tierAcc.totalPriceCents += price;
      tierAcc.totalCostCents += cost;
      final vendorIds = _intMap(
        _jsonMap(assignment['polling_cadence_per_vendor_seconds']),
      ).keys.toList()..sort();
      if (vendorIds.isEmpty) {
        if (cost > 0) {
          perVendor['__unallocated__'] =
              (perVendor['__unallocated__'] ?? 0) + cost;
        }
        continue;
      }
      final base = cost ~/ vendorIds.length;
      var remainder = cost - base * vendorIds.length;
      for (final vendorId in vendorIds) {
        final share = base + (remainder > 0 ? 1 : 0);
        if (remainder > 0) remainder -= 1;
        perVendor[vendorId] = (perVendor[vendorId] ?? 0) + share;
      }
    }
    return <String, Object?>{
      'total_monthly_price_cents': totalPrice,
      'total_monthly_vendor_cost_cents': totalCost,
      'per_tier': <Map<String, Object?>>[
        for (final acc in perTier.values)
          <String, Object?>{
            'tier_key': acc.tierKey,
            'assignment_count': acc.assignmentCount,
            'total_monthly_price_cents': acc.totalPriceCents,
            'total_monthly_vendor_cost_cents': acc.totalCostCents,
          },
      ],
      'per_vendor': <Map<String, Object?>>[
        for (final entry in perVendor.entries)
          <String, Object?>{
            'vendor_id': entry.key,
            'total_monthly_vendor_cost_cents': entry.value,
          },
      ],
    };
  }

  static String _marginRollupCsv(Map<String, Object?> rollup) {
    final lines = <String>[
      'section,key,assignment_count,total_monthly_price_cents,total_monthly_vendor_cost_cents,total_monthly_margin_cents',
    ];
    final totalPrice = _asInt(rollup['total_monthly_price_cents']);
    final totalCost = _asInt(rollup['total_monthly_vendor_cost_cents']);
    lines.add('total,all,,$totalPrice,$totalCost,${totalPrice - totalCost}');
    for (final raw in (rollup['per_tier'] as List? ?? const [])) {
      final row = Map<String, Object?>.from(raw as Map);
      final price = _asInt(row['total_monthly_price_cents']);
      final cost = _asInt(row['total_monthly_vendor_cost_cents']);
      final tierKey = row['tier_key'];
      final assignmentCount = row['assignment_count'];
      lines.add(
        'per_tier,$tierKey,$assignmentCount,$price,$cost,${price - cost}',
      );
    }
    for (final raw in (rollup['per_vendor'] as List? ?? const [])) {
      final row = Map<String, Object?>.from(raw as Map);
      final vendorId = row['vendor_id'];
      final vendorCost = row['total_monthly_vendor_cost_cents'];
      lines.add('per_vendor,$vendorId,,,$vendorCost,');
    }
    return '${lines.join('\n')}\n';
  }

  static Map<String, Object?> _settingsDiff(
    Map<String, Object?>? before,
    Map<String, Object?> after,
  ) {
    final diff = <String, Object?>{};
    const fields = <String>[
      'covers_source_lunch',
      'covers_source_dinner',
      'covers_source_late_night',
      'wage_source',
      'walk_in_handling_mode',
    ];
    for (final field in fields) {
      final from =
          before?[field] ??
          (field == 'walk_in_handling_mode' ? 'reservations_only' : 'vendor');
      final to = after[field];
      if (from != to) {
        diff[field] = <String, Object?>{'from': from, 'to': to};
      }
    }
    return diff;
  }

  static Map<String, Object?> _jsonMap(Object? value) {
    if (value is Map<String, Object?>) return value;
    if (value is Map) return Map<String, Object?>.from(value);
    if (value is String && value.isNotEmpty) {
      final decoded = jsonDecode(value);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    }
    return const <String, Object?>{};
  }

  static Map<String, int> _intMap(Map<String, Object?> value) {
    return <String, int>{
      for (final entry in value.entries) entry.key: _asInt(entry.value),
    };
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static String? _dateJson(Object? value) {
    if (value is DateTime) return value.toUtc().toIso8601String();
    if (value is String && value.isNotEmpty) {
      return DateTime.parse(value).toUtc().toIso8601String();
    }
    return null;
  }

  static void _validateCoversSource(String? value, String field) {
    if (value == null) return;
    try {
      CoversSourceWire.fromWire(value);
    } on ArgumentError {
      throw DataAccuracyAdminGatewayValidationError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field must be vendor, forecast, or manual',
      );
    }
  }

  static void _validateWageSource(String? value) {
    if (value == null) return;
    try {
      WageSourceWire.fromWire(value);
    } on ArgumentError {
      throw const DataAccuracyAdminGatewayValidationError(
        statusCode: 400,
        code: 'invalid_wage_source',
        message: 'wage_source must be vendor or manual_mix',
      );
    }
  }

  static void _validateWalkInHandlingMode(String? value) {
    if (value == null) return;
    try {
      DataAccuracyWalkInHandlingModeWire.fromWire(value);
    } on ArgumentError {
      throw const DataAccuracyAdminGatewayValidationError(
        statusCode: 400,
        code: 'invalid_walk_in_handling_mode',
        message:
            'walk_in_handling_mode must be reservations_only, '
            'walk_ins_added_to_reservations, or '
            'walk_ins_tracked_separately',
      );
    }
  }

  static PollingTierKey _validateTierKey(String value) {
    try {
      return PollingTierKeyWire.fromWire(value);
    } on ArgumentError {
      throw const DataAccuracyAdminGatewayValidationError(
        statusCode: 400,
        code: 'invalid_tier_key',
        message: 'tier_key must be standard, premium, or custom',
      );
    }
  }

  static void _validateTierChangeStatus(String value) {
    if (const <String>{
      'pending',
      'approved',
      'denied',
      'negotiating',
    }.contains(value)) {
      return;
    }
    throw const DataAccuracyAdminGatewayValidationError(
      statusCode: 400,
      code: 'invalid_status',
      message: 'status must be pending, approved, denied, or negotiating',
    );
  }
}

class _DataAccuracyTierAccumulator {
  _DataAccuracyTierAccumulator(this.tierKey);

  final String tierKey;
  int assignmentCount = 0;
  int totalPriceCents = 0;
  int totalCostCents = 0;
}

class RepositoryCorpusAdminProxyGateway implements CorpusAdminProxyGateway {
  RepositoryCorpusAdminProxyGateway({
    required CorpusRepository corpusRepository,
    required AuthEventsAuditRepository auditRepository,
    bool emitInvalidationEvent = false,
  }) : _corpus = corpusRepository,
       _auditRepository = auditRepository,
       _emitInvalidationEvent = emitInvalidationEvent;

  final CorpusRepository _corpus;
  final AuthEventsAuditRepository _auditRepository;

  // 11A.B43 — `cache_telemetry_v2` rollout flag. When true, every
  // commit/rollback writes one row into `corpus_invalidation_events`
  // inside the same withSystem transaction. Wired from the proxy's
  // CACHE_TELEMETRY_V2 env var via [buildProxyProductionBindings].
  final bool _emitInvalidationEvent;

  @override
  Future<List<Map<String, Object?>>> listVersions({
    required String actorUserId,
    required String adminReason,
  }) async {
    final versions = await _corpus.listVersions(adminReason: adminReason);
    final payload = <Map<String, Object?>>[
      for (final v in versions) v.toJson(),
    ];
    await _audit(
      actorUserId: actorUserId,
      eventType: 'admin.corpus.list',
      adminReason: adminReason,
      payload: <String, Object?>{'version_count': versions.length},
    );
    return payload;
  }

  @override
  Future<Map<String, Object?>?> fetchVersion({
    required String actorUserId,
    required String versionId,
    required String adminReason,
  }) async {
    final all = await _corpus.listVersions(adminReason: adminReason);
    CorpusVersionRow? ref;
    for (final v in all) {
      if (v.versionId == versionId) {
        ref = v;
        break;
      }
    }
    if (ref == null) return null;
    final chunks = await _corpus.chunksForVersion(
      versionId: versionId,
      adminReason: '$adminReason:chunks:$versionId',
    );
    await _audit(
      actorUserId: actorUserId,
      eventType: 'admin.corpus.fetch',
      adminReason: adminReason,
      payload: <String, Object?>{
        'version_id': versionId,
        'chunk_count': chunks.length,
      },
    );
    return <String, Object?>{
      'version': <String, Object?>{
        ...ref.toJson(),
        'chunk_count': chunks.length,
      },
      'chunks': <Map<String, Object?>>[
        for (final c in chunks)
          <String, Object?>{
            ...c.toJson(),
            'snippet': c.text.length > 280
                ? '${c.text.substring(0, 280)}…'
                : c.text,
          },
      ],
    };
  }

  @override
  Future<Map<String, Object?>> previewDiff({
    required String actorUserId,
    required String fileName,
    required String contentType,
    required List<int> bytes,
    required String idempotencyKey,
    required String adminReason,
  }) {
    // 11A.3b owns the live chunker. Surface a typed validation error
    // so the screen renders the actionable banner instead of a 503.
    throw const CorpusAdminGatewayValidationError(
      statusCode: 503,
      code: 'corpus_pipeline_not_configured',
      message:
          'corpus upload pipeline ships in 11A.3b; '
          'demo mode runs the in-memory gateway end-to-end',
    );
  }

  @override
  Future<Map<String, Object?>> commitVersion({
    required String actorUserId,
    required String previewToken,
    required String summary,
    required String idempotencyKey,
    required String adminReason,
  }) {
    throw const CorpusAdminGatewayValidationError(
      statusCode: 503,
      code: 'corpus_pipeline_not_configured',
      message: 'corpus commit pipeline ships in 11A.3b',
    );
  }

  @override
  Future<Map<String, Object?>?> rollbackVersion({
    required String actorUserId,
    required String targetVersionId,
    required String summary,
    required String idempotencyKey,
    required String adminReason,
  }) async {
    // Forward the idempotency key into the repository so a retry
    // collapses to the same `corpus_versions` row. Without this, a
    // dropped response followed by a client retry would write a
    // second rollback ledger entry plus a second audit row, which
    // contradicts the slice's "same key → same response" promise.
    final result = await _corpus.rollbackToVersion(
      targetVersionId: targetVersionId,
      actorUserId: actorUserId,
      summary: summary.isEmpty ? 'Rolled back to $targetVersionId' : summary,
      adminReason: adminReason,
      idempotencyKey: idempotencyKey,
      emitInvalidationEvent: _emitInvalidationEvent,
    );
    // Skip the audit insert on a cache replay — the prior request
    // that filled the cache already wrote the audit row, and writing
    // again would leave two audit entries for one logical change.
    if (!result.replayed) {
      await _audit(
        actorUserId: actorUserId,
        eventType: 'admin.corpus.rollback',
        adminReason: adminReason,
        payload: <String, Object?>{
          'target_version_id': targetVersionId,
          'new_version_id': result.version.versionId,
          'idempotency_key': idempotencyKey,
        },
      );
    }
    return result.version.toJson();
  }

  Future<void> _audit({
    required String actorUserId,
    required String eventType,
    required String adminReason,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    return _auditRepository.insertSystemEvent(
      actorUserId: actorUserId,
      eventType: eventType,
      adminReason: adminReason,
      payload: <String, Object?>{'admin_reason': adminReason, ...payload},
    );
  }
}

/// Production [GraphCandidatesProxyGateway] backed by [GraphRepository].
///
/// `listCandidates` reads the deterministic JSONL artifacts written
/// by `tool/advisor_corpus prepare-graphify-candidates` under
/// `graphify-out/candidates/` and projects them into the
/// [GraphCandidateDiff] wire shape the screen consumes. When the
/// artifacts are missing (the operator has not run the build tool
/// yet), the gateway raises a typed
/// `graph_candidates_not_configured` 503 so the screen renders the
/// actionable banner.
///
/// `commitBatch` resolves each wire `ApprovalDecision` against the
/// candidate id index built from the JSONL, translates it into a
/// repository-shaped [GraphCommitDecision], opens a tenant-scoped
/// transaction via [GraphRepository.commitBatch], and projects the
/// returned [GraphCommitBatchResult] back to JSON. The whole batch
/// runs atomically inside one withTenant transaction (composite-FK
/// ordering and audit fan-out are the repository's job).
class RepositoryGraphCandidatesProxyGateway
    implements GraphCandidatesProxyGateway {
  RepositoryGraphCandidatesProxyGateway({
    required GraphRepository graphRepository,
    required AuthEventsAuditRepository auditRepository,
    required Directory repoRoot,
    String candidatesDirectory = defaultGraphifyCandidatesOutputDirectory,
  }) : _graph = graphRepository,
       _auditRepository = auditRepository,
       _repoRoot = repoRoot,
       _candidatesDirectory = candidatesDirectory;

  final GraphRepository _graph;
  final AuthEventsAuditRepository _auditRepository;
  final Directory _repoRoot;
  final String _candidatesDirectory;

  /// Phase 11A.3b — in-process idempotency-key dedup for
  /// `commit-batch` retries. A retry with the same key returns the
  /// cached result map instead of re-running the writes, which
  /// would otherwise cause duplicate audit rows and canonical
  /// uniqueness errors (the canonical inserts have a UNIQUE on
  /// `(operator_id, graph_scope, graph_version, node_key)`).
  ///
  /// **Launch posture:** in-process map. The 9.0Σ.f
  /// `proxy_requests` table-backed dedup (the same posture the
  /// 11A.3a corpus rollback path lights up via
  /// `CorpusRepository.rollbackToVersion(idempotencyKey: ...)`)
  /// is the production-grade path; the in-process map covers the
  /// single-Cloud-Run-instance launch shape and the F&F admin
  /// screen's retry behaviour. Multi-instance fan-out lands in a
  /// follow-up slice that promotes this to the table-backed path.
  ///
  /// **Concurrent-safe.** The cache stores the in-flight Future
  /// (not the resolved result), and [commitBatch] reserves the
  /// key SYNCHRONOUSLY — before any await — so two overlapping
  /// requests with the same key share the same Future and only
  /// one transaction opens. The earlier "cache the resolved
  /// result after the work completes" shape allowed two concurrent
  /// requests to both observe `cached == null`, both open
  /// transactions, and both trip the canonical UNIQUE on retry.
  ///
  /// On error the cache entry is removed so a fresh retry can
  /// succeed (matches Stripe-style idempotency semantics — a
  /// transient failure should not poison the key permanently).
  ///
  /// Keyed by `(idempotencyKey)` — the route handler already
  /// rejects POST requests without a key (400 missing_idempotency_key)
  /// so a non-empty key is guaranteed by the time we enter
  /// [commitBatch].
  final Map<String, Future<Map<String, Object?>>> _idempotentCommitResults =
      <String, Future<Map<String, Object?>>>{};

  @override
  Future<Map<String, Object?>> listGraphCandidates({
    required String actorUserId,
    required String adminReason,
  }) async {
    final bundle = await _loadCandidateBundle();
    // Spec line 195-196 + 264-265: graph_candidates.jsonl is NOT
    // production truth — the active corpus manifest is the
    // authority on which docs are in scope, and Graphify output
    // for files outside the manifest is ignored. Apply the same
    // fail-closed scope filter listGraphCandidates uses for the
    // commit path so a stale/tampered JSONL entry cannot render
    // in the diff and tempt an operator to queue a decision the
    // commit path will then reject anyway.
    final manifestScope = await _loadManifestScopeForFilter();
    if (manifestScope == null) {
      throw const GraphCandidatesGatewayValidationError(
        statusCode: 503,
        code: 'manifest_unavailable',
        message:
            'corpus_manifest.yaml could not be loaded; the diff '
            'cannot be rendered without the manifest scope filter '
            '(stale or tampered JSONL entries would otherwise reach '
            'the operator). Restore the manifest at '
            'docs/Knowledge_graph_docs/corpus_manifest.yaml and retry.',
      );
    }

    final extracted = <Map<String, Object?>>[];
    final inferred = <Map<String, Object?>>[];
    final ambiguous = <Map<String, Object?>>[];
    var droppedOutOfScope = 0;

    void route(Map<String, Object?> candidate) {
      // Drop candidates whose source_file is missing/blank or not
      // in the active manifest scope. Silent drop matches the
      // spec ("Graphify output outside the active manifest is
      // ignored") — the operator never queues an invalid row.
      final src = candidate['source_file'] as String?;
      if (src == null ||
          src.trim().isEmpty ||
          !_isManifestSourceInScope(src, manifestScope)) {
        droppedOutOfScope += 1;
        return;
      }
      final label = (candidate['label'] as String?) ?? 'EXTRACTED';
      switch (label) {
        case 'EXTRACTED':
          extracted.add(candidate);
          break;
        case 'INFERRED':
          inferred.add(candidate);
          break;
        case 'AMBIGUOUS':
          ambiguous.add(candidate);
          break;
        default:
          // Unknown label → safest bucket so the admin still sees it.
          ambiguous.add(candidate);
      }
    }

    for (final node in bundle.nodes) {
      route(node);
    }
    for (final edge in bundle.edges) {
      route(edge);
    }

    await _audit(
      actorUserId: actorUserId,
      eventType: 'admin.corpus.graph_candidates.list',
      adminReason: adminReason,
      payload: <String, Object?>{
        'graph_scope': bundle.graphScope,
        'graph_version': bundle.graphVersion,
        'graphify_version': bundle.graphifyVersion,
        'extracted_count': extracted.length,
        'inferred_count': inferred.length,
        'ambiguous_count': ambiguous.length,
        'dropped_out_of_scope_count': droppedOutOfScope,
      },
    );

    return <String, Object?>{
      'graph_scope': bundle.graphScope,
      'graph_version': bundle.graphVersion,
      'graphify_version': bundle.graphifyVersion,
      if (bundle.graphifySourceCommit != null)
        'graphify_source_commit': bundle.graphifySourceCommit,
      'extracted': extracted,
      'inferred': inferred,
      'ambiguous': ambiguous,
    };
  }

  @override
  Future<Map<String, Object?>> commitBatch({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required List<Map<String, Object?>> decisions,
    required String idempotencyKey,
    required String adminReason,
  }) {
    // Phase 11A.3b — idempotency-key dedup, concurrent-safe.
    //
    // Note: this method is intentionally NOT async. The
    // synchronous prefix runs to completion before returning,
    // which means two overlapping calls with the same key cannot
    // both observe `cached == null` and both open a write
    // transaction. The first arrival inserts the in-flight Future
    // into the cache synchronously; the second arrival reads the
    // same Future and awaits its result.
    //
    // The route handler already rejects POST requests without an
    // Idempotency-Key (400 missing_idempotency_key), so a
    // non-empty key is guaranteed here.
    final existing = _idempotentCommitResults[idempotencyKey];
    if (existing != null) {
      // Hot path: a prior call already started (and possibly
      // completed). Return its Future; replay either gets the
      // cached resolved value or awaits the in-flight result.
      // The first call's audit-events row already fired — we
      // never double-emit because the same Future is returned.
      return existing;
    }
    // Reserve the key by inserting the chained Future BEFORE any
    // await. The chained `.catchError` removes the entry on
    // failure so a retry after a transient error gets a fresh
    // attempt; on success the resolved Future stays cached.
    final pending =
        _commitBatchInternal(
          actorUserId: actorUserId,
          operatorId: operatorId,
          locationId: locationId,
          decisions: decisions,
          idempotencyKey: idempotencyKey,
          adminReason: adminReason,
        ).catchError((Object error, StackTrace stackTrace) {
          _idempotentCommitResults.remove(idempotencyKey);
          // Rethrow so awaiters see the original error. The catchError
          // handler completes the chained Future with the same error.
          // ignore: only_throw_errors
          throw error;
        });
    _idempotentCommitResults[idempotencyKey] = pending;
    return pending;
  }

  /// Body of [commitBatch]. Extracted so the public method can
  /// reserve the idempotency key synchronously before the first
  /// await, which is what makes concurrent retries with the same
  /// key share one Future instead of opening two transactions.
  Future<Map<String, Object?>> _commitBatchInternal({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required List<Map<String, Object?>> decisions,
    required String idempotencyKey,
    required String adminReason,
  }) async {
    if (decisions.isEmpty) {
      throw const GraphCandidatesGatewayValidationError(
        statusCode: 400,
        code: 'empty_batch',
        message: 'commit-batch requires at least one decision',
      );
    }
    final bundle = await _loadCandidateBundle();
    // Defense-in-depth manifest scope filter on the resolved
    // candidates' `source_file`. The route handler's filter only
    // sees `edited_payload.source_file`, but approve / reject
    // requests carry only `candidate_id` over the wire; this is
    // the only point where we know the producer-recorded source
    // for those decisions. Stale or tampered out-of-scope JSONL
    // entries are rejected here even if they passed the importer
    // (e.g. the manifest changed between importer time and commit).
    //
    // **Fail-closed:** when the manifest cannot be loaded
    // (missing, unreadable, or malformed) we abort the commit
    // with a typed 503 rather than silently skipping the check.
    // A missing manifest means the safety net is gone — the
    // alternative (fail-open) would let stale JSONL pass through
    // unchecked, which is exactly the hole the importer-time
    // primary filter cannot close. Production deployments always
    // ship the manifest as part of the artifact, so this case
    // means a configuration error worth halting on.
    final manifestScope = await _loadManifestScopeForFilter();
    if (manifestScope == null) {
      throw const GraphCandidatesGatewayValidationError(
        statusCode: 503,
        code: 'manifest_unavailable',
        message:
            'corpus_manifest.yaml could not be loaded; the '
            'defense-in-depth scope check on resolved candidates '
            'cannot run, so the commit is rejected to prevent stale '
            'or tampered out-of-scope JSONL entries from leaking. '
            'Restore the manifest at '
            'docs/Knowledge_graph_docs/corpus_manifest.yaml and retry.',
      );
    }
    final byId = <String, Map<String, Object?>>{};
    for (final node in bundle.nodes) {
      byId[node['candidate_id']! as String] = node;
    }
    for (final edge in bundle.edges) {
      byId[edge['candidate_id']! as String] = edge;
    }

    final repoDecisions = <GraphCommitDecision>[];
    for (var i = 0; i < decisions.length; i++) {
      final wire = decisions[i];
      final candidateIdRaw = wire['candidate_id'];
      if (candidateIdRaw is! String || candidateIdRaw.trim().isEmpty) {
        throw GraphCandidatesGatewayValidationError(
          statusCode: 400,
          code: 'missing_candidate_id',
          message: 'decisions[$i] is missing candidate_id',
        );
      }
      final candidate = byId[candidateIdRaw];
      if (candidate == null) {
        throw GraphCandidatesGatewayValidationError(
          statusCode: 404,
          code: 'unknown_candidate',
          message:
              'decisions[$i] references candidate_id "$candidateIdRaw" '
              'which is not in the current diff',
        );
      }
      final kindRaw = wire['kind'];
      if (kindRaw is! String) {
        throw GraphCandidatesGatewayValidationError(
          statusCode: 400,
          code: 'invalid_decision_kind',
          message: 'decisions[$i] is missing kind (approve/reject/edit)',
        );
      }
      final decisionKind = _parseDecisionKind(kindRaw, i);
      final candidateKindRaw = candidate['kind'] as String?;
      final candidateKind = candidateKindRaw == 'edge'
          ? GraphCandidateKind.edge
          : GraphCandidateKind.node;
      final candidatePayload =
          ((candidate['payload'] as Map?)?.cast<String, Object?>()) ??
          const <String, Object?>{};
      final editedPayloadRaw = wire['edited_payload'];
      final editedPayload = editedPayloadRaw is Map
          ? editedPayloadRaw.cast<String, Object?>()
          : null;
      if (decisionKind == GraphDecisionKind.edit && editedPayload == null) {
        throw GraphCandidatesGatewayValidationError(
          statusCode: 400,
          code: 'missing_edited_payload',
          message: 'decisions[$i] is an edit but does not carry edited_payload',
        );
      }
      // Spec line 249 (server-side guard): AMBIGUOUS relationships
      // are debug-only until edited into a clear approved
      // relationship. The screen hides the Approve button on
      // AMBIGUOUS rows and a programmatic guard exists in
      // `_toggleApprove`; this is the matching server-side check
      // so a direct or stale HTTP request cannot bypass the widget
      // and route an unedited ambiguous relationship into
      // canonical graph storage. `edit` (which carries
      // `edited_payload` + `edited_candidate_type`) is the only
      // way to land an AMBIGUOUS candidate in canonical storage.
      final candidateLabel = candidate['label'] as String?;
      if (candidateLabel == 'AMBIGUOUS' &&
          decisionKind == GraphDecisionKind.approve) {
        throw GraphCandidatesGatewayValidationError(
          statusCode: 400,
          code: 'ambiguous_requires_edit',
          message:
              'decisions[$i] is a bare approve on candidate '
              '"$candidateIdRaw" which the producer flagged AMBIGUOUS; '
              'AMBIGUOUS candidates must be edited into a clear '
              'approved relationship before they can land in canonical '
              'storage (spec line 249). Use kind="edit" with an '
              'edited_candidate_type and edited_payload instead.',
        );
      }
      // Defense-in-depth manifest scope check on the resolved
      // candidate's `source_file`. The route-handler filter only
      // sees `edited_payload.source_file`; approve / reject
      // requests carry only `candidate_id`, so this is the only
      // point that catches a stale or tampered out-of-scope JSONL
      // entry on those decisions. The scope set is fail-closed
      // (see `_loadManifestScopeForFilter`): a missing or
      // unreadable manifest aborts before this loop, so by the
      // time we reach this check the scope is authoritative.
      final candidateSourceFile = candidate['source_file'] as String?;
      // Spec line 253-255: every approved candidate records the
      // source document. The importer's primary filter treats
      // candidates with null/blank source_file as out-of-scope and
      // drops them; this server-side check rejects any stale or
      // tampered JSONL row that slipped through with a missing
      // source_file so a candidate cannot land in canonical
      // storage without provenance.
      if (candidateSourceFile == null || candidateSourceFile.trim().isEmpty) {
        throw GraphCandidatesGatewayValidationError(
          statusCode: 403,
          code: 'source_out_of_scope',
          message:
              'decisions[$i] resolved candidate "$candidateIdRaw" '
              'has no source_file; approved candidates must carry '
              'a source_file (spec line 253-255) and the importer '
              'treats null source paths as out-of-scope. Re-run '
              'prepare-graphify-candidates before retrying.',
        );
      }
      if (!_isManifestSourceInScope(candidateSourceFile, manifestScope)) {
        throw GraphCandidatesGatewayValidationError(
          statusCode: 403,
          code: 'source_out_of_scope',
          message:
              'decisions[$i] resolved candidate "$candidateIdRaw" '
              'whose source_file "$candidateSourceFile" is not in the '
              'corpus manifest; the candidate JSONL may be stale — '
              're-run prepare-graphify-candidates against the current '
              'manifest before retrying',
        );
      }
      final candidateType =
          (wire['edited_candidate_type'] as String?) ??
          (candidate['candidate_type']! as String);
      final confidenceLabel = GraphCandidateLabel.fromWire(
        candidate['label']! as String,
      );
      final confidenceScore = (candidate['confidence_score'] as num?)
          ?.toDouble();
      final reasonRaw = wire['reason'];
      final reason = reasonRaw is String && reasonRaw.trim().isNotEmpty
          ? reasonRaw.trim()
          : null;
      repoDecisions.add(
        GraphCommitDecision(
          kind: candidateKind,
          decision: decisionKind,
          candidateKey: candidate['candidate_key']! as String,
          candidateType: candidateType,
          payload: editedPayload ?? candidatePayload,
          confidenceLabel: confidenceLabel,
          confidenceScore: confidenceScore,
          sourceFile: candidate['source_file'] as String?,
          sourceRef: candidate['source_ref'] as String?,
          fromNodeKey: candidate['from_node_key'] as String?,
          toNodeKey: candidate['to_node_key'] as String?,
          reason: reason,
        ),
      );
    }

    final TenantContext tenantContext;
    try {
      tenantContext = TenantContext(
        operatorId: operatorId,
        locationId: locationId,
        userId: actorUserId,
      );
    } on TenantContextValidationError catch (error) {
      throw GraphCandidatesGatewayValidationError(
        statusCode: 400,
        code: 'invalid_${error.field}',
        message: error.message,
      );
    }

    final result = await _graph.commitBatch(
      tenantContext: tenantContext,
      graphScope: bundle.graphScope,
      graphVersion: bundle.graphVersion,
      graphifyVersion: bundle.graphifyVersion,
      graphifySourceCommit: bundle.graphifySourceCommit,
      idempotencyKey: idempotencyKey,
      decisions: repoDecisions,
    );

    // Graph side effects have committed. From this point on the
    // operation is a success from the operator's standpoint and
    // the response shape is fixed. The audit row below is
    // best-effort observability (auth_events_audit, written via
    // a separate `withSystem` transaction in
    // `AuthEventsAuditRepository.insertSystemEvent`); a failure
    // there must NOT propagate as an error to the caller because:
    //
    //   1. The wrapper's .catchError would clear the
    //      idempotency cache entry, and a retry with the same
    //      `Idempotency-Key` would re-run `_graph.commitBatch`
    //      and trip the canonical UNIQUE on
    //      `(operator_id, graph_scope, graph_version, node_key)`
    //      for the rows just written, surfacing as a 503 to the
    //      operator for an operation that actually succeeded.
    //
    //   2. The `graph_repository.dart` audit fan-out into
    //      `audit_logs` already ran inside the same tenant
    //      transaction as the graph writes (see
    //      `_fanOutToAuditLogs`), so the hash-chained system
    //      audit trail is intact even if the auth_events_audit
    //      row below is missed. Ops monitoring catches missed
    //      auth_events_audit rows via row-count drift.
    //
    // The `auth_events_audit` failure is logged for ops to
    // investigate; the operator-visible response is the success
    // shape, the cache entry stays populated, and a retry with
    // the same key returns the cached success.
    final response = result.toJson();
    try {
      await _audit(
        actorUserId: actorUserId,
        operatorId: operatorId,
        locationId: locationId,
        eventType: 'admin.corpus.graph_candidates.commit_batch',
        adminReason: adminReason,
        payload: <String, Object?>{
          'graph_scope': bundle.graphScope,
          'graph_version': bundle.graphVersion,
          'idempotency_key': idempotencyKey,
          'approved_node_count': result.approvedNodeCount,
          'approved_edge_count': result.approvedEdgeCount,
          'rejected_count': result.rejectedCount,
        },
      );
    } catch (auditError, auditStack) {
      // Best-effort: log and proceed. Re-throwing would clear
      // the idempotency cache and cause a retry to double-write.
      log(
        LogSeverity.warning,
        'admin.corpus.graph_candidates.commit_batch.audit_write_failed',
        fields: <String, Object?>{
          'idempotency_key': idempotencyKey,
          'operator_id': operatorId,
          'approved_node_count': result.approvedNodeCount,
          'approved_edge_count': result.approvedEdgeCount,
          'rejected_count': result.rejectedCount,
          'error_type': auditError.runtimeType.toString(),
          'error_message': auditError.toString(),
          'stack_first_frame': firstStackFrame(auditStack),
        },
      );
    }

    // Cache write happens in the [commitBatch] wrapper via the
    // chained Future inserted before the first await; the wrapper's
    // .catchError handles failure-removal for pre-graph-commit
    // errors only. Post-graph-commit (audit) failures are swallowed
    // above so the cache stays populated with the success
    // response.
    return response;
  }

  /// Loads the current corpus manifest scope set (source_path
  /// normalized to forward-slash form, plus bare file_name aliases)
  /// for the defense-in-depth check on resolved candidates. Returns
  /// `null` when the manifest cannot be read — the caller treats
  /// that as a typed 503 `manifest_unavailable` and rejects the
  /// commit. **Fail-closed:** without the safety net we cannot
  /// trust the importer's primary filter alone, so a missing or
  /// malformed manifest aborts the commit instead of silently
  /// allowing every decision through.
  ///
  /// An empty-but-loadable manifest (zero included documents) is
  /// still considered loaded — the caller treats every decision's
  /// `source_file` as out-of-scope in that case, which is the
  /// correct behaviour: no docs included → no candidates valid.
  Future<Set<String>?> _loadManifestScopeForFilter() async {
    try {
      final manifestFile = File(p.join(_repoRoot.path, defaultManifestPath));
      if (!manifestFile.existsSync()) return null;
      final manifest = await CorpusManifest.load(manifestFile);
      final scope = <String>{};
      for (final doc in manifest.documents) {
        if (doc.isIncluded) {
          scope.add(doc.sourcePath.replaceAll(r'\', '/'));
          scope.add(doc.fileName);
        }
      }
      return scope;
    } catch (_) {
      return null;
    }
  }

  bool _isManifestSourceInScope(String sourceFile, Set<String> scope) {
    final normalized = sourceFile.replaceAll(r'\', '/');
    if (scope.contains(normalized)) return true;
    final base = p.basename(normalized);
    return scope.contains(base);
  }

  GraphDecisionKind _parseDecisionKind(String wire, int index) {
    switch (wire) {
      case 'approve':
        return GraphDecisionKind.approve;
      case 'reject':
        return GraphDecisionKind.reject;
      case 'edit':
        return GraphDecisionKind.edit;
      default:
        throw GraphCandidatesGatewayValidationError(
          statusCode: 400,
          code: 'invalid_decision_kind',
          message: 'decisions[$index] kind "$wire" must be approve/reject/edit',
        );
    }
  }

  Future<_GraphCandidateBundle> _loadCandidateBundle() async {
    final dir = Directory(p.join(_repoRoot.path, _candidatesDirectory));
    final manifestFile = File(
      p.join(dir.path, graphifyCandidateManifestFileName),
    );
    final nodesFile = File(p.join(dir.path, graphifyNodeCandidatesFileName));
    final edgesFile = File(p.join(dir.path, graphifyEdgeCandidatesFileName));
    if (!manifestFile.existsSync() ||
        !nodesFile.existsSync() ||
        !edgesFile.existsSync()) {
      throw const GraphCandidatesGatewayValidationError(
        statusCode: 503,
        code: 'graph_candidates_not_configured',
        message:
            'graphify candidate artifacts are not on disk; run '
            '`dart run tool/advisor_corpus/main.dart prepare-graphify-candidates` '
            'to materialize them before opening the review screen',
      );
    }
    final manifestRaw = jsonDecode(await manifestFile.readAsString());
    final manifest = manifestRaw is Map<String, Object?>
        ? manifestRaw
        : const <String, Object?>{};
    final nodes = await _readJsonl(nodesFile);
    final edges = await _readJsonl(edgesFile);
    return _GraphCandidateBundle(
      graphScope: (manifest['graph_scope'] as String?) ?? 'methodology',
      graphVersion: (manifest['graph_version'] as String?) ?? '1',
      graphifyVersion: (manifest['graphify_version'] as String?) ?? 'unknown',
      graphifySourceCommit: manifest['graphify_source_commit'] as String?,
      nodes: nodes,
      edges: edges,
    );
  }

  Future<List<Map<String, Object?>>> _readJsonl(File file) async {
    final lines = await file.readAsLines();
    final out = <Map<String, Object?>>[];
    for (final raw in lines) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, Object?>) {
        out.add(decoded);
      } else if (decoded is Map) {
        out.add(decoded.cast<String, Object?>());
      }
    }
    return out;
  }

  Future<void> _audit({
    required String actorUserId,
    required String eventType,
    required String adminReason,
    String? operatorId,
    String? locationId,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    return _auditRepository.insertSystemEvent(
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      eventType: eventType,
      adminReason: adminReason,
      payload: <String, Object?>{'admin_reason': adminReason, ...payload},
    );
  }
}

/// In-memory snapshot of the candidate JSONL artifacts. Captures the
/// manifest header and the parsed node/edge maps so the gateway can
/// project both `listGraphCandidates` and `commitBatch` off the same
/// bundle without re-reading disk on each call.
class _GraphCandidateBundle {
  const _GraphCandidateBundle({
    required this.graphScope,
    required this.graphVersion,
    required this.graphifyVersion,
    required this.graphifySourceCommit,
    required this.nodes,
    required this.edges,
  });

  final String graphScope;
  final String graphVersion;
  final String graphifyVersion;
  final String? graphifySourceCommit;
  final List<Map<String, Object?>> nodes;
  final List<Map<String, Object?>> edges;
}

/// Adapter status rows rendered by the admin Connected services screen.
///
/// These are read-only projections from the implemented adapter
/// registries. They do not imply that connect, rotate, or disconnect
/// routes are live for a vendor; lifecycle and setup copy carry that
/// distinction.
List<Map<String, Object?>> _buildIntegrationVendorConnectorStatuses() {
  final profiles = <integration.VendorCapabilityProfile>[
    ...vendor_status.kAdminVisibleVendorCapabilityProfiles,
  ];
  return <Map<String, Object?>>[
    for (final profile in profiles)
      <String, Object?>{
        'id': profile.vendorId,
        'display_name': profile.displayName,
        'status_label': _lifecycleStatusLabel(profile.lifecycle),
        'detail_message': _vendorConnectorDetail(profile),
      },
  ];
}

String _vendorConnectorDetail(integration.VendorCapabilityProfile profile) {
  final pieces = <String>[
    '${_categoryLabel(profile.category)} adapter implemented.',
    'Setup state: ${_setupStateLabel(profile.lifecycle)}.',
    'Cadence: ${_webhookSupportLabel(profile.webhookSupport)}.',
  ];
  final covers = _coversLabel(profile);
  if (covers != null) pieces.add('Covers: $covers.');
  if (profile.modules.isNotEmpty) pieces.add('Product pick required.');
  return pieces.join(' ');
}

String _categoryLabel(integration.IntegrationCategory category) {
  switch (category) {
    case integration.IntegrationCategory.pos:
      return 'POS';
    case integration.IntegrationCategory.reservation:
      return 'Reservations';
    case integration.IntegrationCategory.labor:
      return 'Scheduling and labor';
  }
}

String _lifecycleStatusLabel(integration.VendorLifecycle lifecycle) {
  switch (lifecycle) {
    case integration.VendorLifecycle.documented:
      return 'Documented';
    case integration.VendorLifecycle.sandboxVerified:
      return 'Sandbox verified';
    case integration.VendorLifecycle.productionCredentialed:
      return 'Ready to connect';
    case integration.VendorLifecycle.liveWithOperators:
      return 'Live';
  }
}

String _setupStateLabel(integration.VendorLifecycle lifecycle) {
  switch (lifecycle) {
    case integration.VendorLifecycle.documented:
      return 'production credentials pending';
    case integration.VendorLifecycle.sandboxVerified:
      return 'sandbox verified, production credentials pending';
    case integration.VendorLifecycle.productionCredentialed:
      return 'production credentials available';
    case integration.VendorLifecycle.liveWithOperators:
      return 'connected by at least one operator';
  }
}

String _webhookSupportLabel(integration.VendorWebhookSupport support) {
  switch (support) {
    case integration.VendorWebhookSupport.autoRegister:
      return 'webhook auto-register';
    case integration.VendorWebhookSupport.manualPaste:
      return 'manual webhook paste';
    case integration.VendorWebhookSupport.pollOnly:
      return 'poll-only';
  }
}

String? _coversLabel(integration.VendorCapabilityProfile profile) {
  if (profile.category != integration.IntegrationCategory.pos) {
    return null;
  }
  return profile.coversFieldExposed
      ? 'vendor covers field'
      : 'forecast fallback';
}

const Map<String, Object?> _kIntegrationDefaultFxRateSource = <String, Object?>{
  'id': 'fx_rate',
  'display_name': 'FX-rate source',
  'status_label': 'green',
  'detail_message': 'ECB daily reference feed (fallback active).',
};

const Map<String, Object?> _kIntegrationDefaultEmailProvider =
    <String, Object?>{
      'id': 'email',
      'display_name': 'Email provider',
      'status_label': 'placeholder',
      'detail_message': 'Email provider lands in Phase 9.8.',
    };

integration.IntegrationCategory? resolveAdminVisibleIntegrationCategory(
  String vendorId,
  Map<String, Object?> connectResult,
) {
  for (final profile in vendor_status.kAdminVisibleVendorCapabilityProfiles) {
    if (profile.vendorId == vendorId) return profile.category;
  }
  return null;
}

class RepositoryFirstConnectionBackfillEnqueueGateway
    implements FirstConnectionBackfillEnqueueGateway {
  RepositoryFirstConnectionBackfillEnqueueGateway({required this.repository});

  final ConnectorBackfillJobRepository repository;

  @override
  Future<FirstConnectionBackfillJob> enqueueFirstBackfill({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String vendorId,
    required integration.IntegrationCategory category,
    required DateTime windowStart,
    required DateTime windowEnd,
    String? actorUserId,
  }) {
    return repository.enqueueFirstBackfill(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      vendorId: vendorId,
      category: category,
      windowStart: windowStart,
      windowEnd: windowEnd,
      actorUserId: actorUserId,
    );
  }
}

/// Production [IntegrationAdminProxyGateway] backed by
/// [ProviderCredentialsRepository] + [KmsProvider]. Translates the
/// proxy's command shape into repo + KMS calls and projects the
/// result into JSON-ready maps the route handler can return as-is.
///
/// Plaintext is held in memory only for the duration of a single
/// rotation call; it is handed to the KMS provider, then returned
/// once on the response. The repository receives only the masked
/// display string and the KMS pointer.
class RepositoryIntegrationAdminProxyGateway
    implements IntegrationAdminProxyGateway {
  RepositoryIntegrationAdminProxyGateway({
    required ProviderCredentialsRepository providerCredentialsRepository,
    required KmsProvider kmsProvider,
    required AuthEventsAuditRepository auditRepository,
    required CloudRunAdminClient cloudRunAdminClient,
  }) : _credentials = providerCredentialsRepository,
       _kmsProvider = kmsProvider,
       _auditRepository = auditRepository,
       _cloudRunAdminClient = cloudRunAdminClient;

  final ProviderCredentialsRepository _credentials;
  final KmsProvider _kmsProvider;
  final AuthEventsAuditRepository _auditRepository;
  final CloudRunAdminClient _cloudRunAdminClient;

  @override
  Future<Map<String, Object?>> listBundle({
    required String actorUserId,
    required String adminReason,
  }) async {
    final rows = await _credentials.listActive(adminReason: adminReason);
    final keysJson = <Map<String, Object?>>[
      for (final row in rows) row.toJson(),
    ];
    await _audit(
      actorUserId: actorUserId,
      eventType: 'admin.integrations.list',
      adminReason: adminReason,
      payload: <String, Object?>{'provider_key_count': rows.length},
    );
    return <String, Object?>{
      'provider_keys': keysJson,
      'vendor_connectors': _buildIntegrationVendorConnectorStatuses(),
      'fx_rate_source': _kIntegrationDefaultFxRateSource,
      'email_provider': _kIntegrationDefaultEmailProvider,
    };
  }

  @override
  Future<Map<String, Object?>> rotateProviderKey({
    required String actorUserId,
    required String keyKind,
    required String plaintextValue,
    required String adminReason,
  }) async {
    if (!kProviderCredentialKinds.contains(keyKind)) {
      throw IntegrationAdminGatewayValidationError(
        statusCode: 400,
        code: 'unknown_key_kind',
        message: 'key_kind "$keyKind" is not a known provider lane',
      );
    }
    KmsWriteResult writeResult;
    try {
      writeResult = await _kmsProvider.writeSecret(
        logicalKeyKind: keyKind,
        plaintext: plaintextValue,
      );
    } on KmsWriteFailure catch (error) {
      // KMS write failed → no audit-success row, prior key stays
      // active (the repository was never called), and we record the
      // rotation_failed audit row before raising. The proxy maps the
      // validation error onto a 503 response.
      await _audit(
        actorUserId: actorUserId,
        eventType: 'admin.integrations.rotation_failed',
        adminReason: adminReason,
        payload: <String, Object?>{
          'key_kind': keyKind,
          'failure_kind': 'kms_write_failed',
          'message': error.message,
        },
      );
      throw IntegrationAdminGatewayValidationError(
        statusCode: 503,
        code: 'kms_write_failed',
        message: error.message,
      );
    }
    final ProviderCredentialRow row;
    try {
      row = await _credentials.rotate(
        keyKind: keyKind,
        maskedValue: writeResult.maskedDisplay,
        kmsSecretName: writeResult.secretName,
        actorUserId: actorUserId,
        adminReason: adminReason,
      );
    } catch (error) {
      // Postgres write failed AFTER KMS succeeded — record the
      // failure so an operator can investigate the orphaned KMS
      // secret. Prior key stays active (the repository transaction
      // rolled back, so no `is_active` flip happened).
      await _audit(
        actorUserId: actorUserId,
        eventType: 'admin.integrations.rotation_failed',
        adminReason: adminReason,
        payload: <String, Object?>{
          'key_kind': keyKind,
          'failure_kind': 'persistence_failed',
          'kms_secret_name': writeResult.secretName,
          'message': error.toString(),
        },
      );
      rethrow;
    }
    await _audit(
      actorUserId: actorUserId,
      eventType: 'admin.integrations.rotation_success',
      adminReason: adminReason,
      payload: <String, Object?>{
        'key_kind': keyKind,
        'credential_id': row.credentialId,
        'kms_secret_name': row.kmsSecretName,
      },
    );
    // Phase 11A.4c — for runtime-read lanes (anthropic / voyage /
    // gemini), force a new Cloud Run revision so existing instances
    // restart and pick up the latest Secret Manager version. The
    // rotation itself has already succeeded; refresh failures are
    // best-effort and audit-only — a retried rotation or a manual
    // `gcloud run deploy --revision-suffix` recovers from a missed
    // refresh. `azure_db` is NOT in the runtime-read set so it
    // skips this step entirely.
    //
    // Two gates apply, BOTH must hold:
    //   1. The lane is one whose plaintext the proxy reads at runtime
    //      (`kRuntimeReadKeyKinds`). `azure_db` rotations skip Cloud
    //      Run entirely — its plaintext is consumed by ops scripts,
    //      not the proxy runtime.
    //   2. The persisted KMS pointer indicates a REAL Secret Manager
    //      write actually happened. During the staged rollout the
    //      `KmsLaneRouter` may be wired with the GCP provider AND
    //      Cloud Run admin client (because GCP env vars are set on
    //      the Cloud Run service), but the lane's
    //      `kms_real_provider_<kind>_enabled` flag is still OFF —
    //      so the router dispatches to `KmsStubProvider` and the
    //      pointer comes back as `kms://stub/<uuid>`. PATCHing Cloud
    //      Run in that scenario would trigger a pointless instance
    //      restart and an audit row that misleadingly suggests a
    //      Secret Manager version landed. Gate on the GCP pointer
    //      prefix so the restart only fires when the audit row is
    //      truthful.
    final landedInRealKms = row.kmsSecretName.startsWith(
      GcpSecretManagerKmsProvider.pointerPrefix,
    );
    if (kRuntimeReadKeyKinds.contains(keyKind) && landedInRealKms) {
      try {
        final operationName = await _cloudRunAdminClient.forceNewRevision(
          reason: 'kms_rotation:$keyKind:${row.credentialId}',
        );
        await _audit(
          actorUserId: actorUserId,
          eventType: 'admin.integrations.cloud_run_revision_forced',
          adminReason: adminReason,
          payload: <String, Object?>{
            'key_kind': keyKind,
            'credential_id': row.credentialId,
            // Long-running operation name (e.g.
            // `projects/<P>/locations/<R>/operations/<op-id>`). The
            // actual revision name is assigned asynchronously by
            // Cloud Run; resolve it via
            // `gcloud run operations describe <op>`.
            'operation_name': operationName,
          },
        );
      } catch (error) {
        // Cloud Run patch failed AFTER KMS + Postgres succeeded.
        // The rotation itself stands; the operator can retry the
        // restart manually. Audit so the discrepancy is visible.
        await _audit(
          actorUserId: actorUserId,
          eventType: 'admin.integrations.cloud_run_refresh_failed',
          adminReason: adminReason,
          payload: <String, Object?>{
            'key_kind': keyKind,
            'credential_id': row.credentialId,
            'message': error.toString(),
          },
        );
      }
    }
    return <String, Object?>{
      'row': row.toJson(),
      'plaintext_value': plaintextValue,
    };
  }

  Future<void> _audit({
    required String actorUserId,
    required String eventType,
    required String adminReason,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    return _auditRepository.insertSystemEvent(
      actorUserId: actorUserId,
      eventType: eventType,
      adminReason: adminReason,
      payload: <String, Object?>{'admin_reason': adminReason, ...payload},
    );
  }
}

/// Phase 11A.7 — production [FeatureFlagsAdminProxyGateway] backed by
/// [FeatureFlagsRepository] + admin-pool [AuthEventsAuditRepository].
/// The audit row writes through `insertSystemEvent`; the
/// `audit_logs_cutover_enabled` fan-out (B.2) carries it into the
/// hash-chained `audit_logs` table when the cutover flag is on.
///
/// Plaintext flag values are not secrets — the table holds gating
/// bits and operator-facing copy only — so the response payload
/// returns the row JSON as-is.
///
/// HARD-D — toggle idempotency. Per
/// `docs/contracts/hardening_feature_flag_idempotency_contract.md`,
/// retries with the same `Idempotency-Key` collapse to one DB
/// mutation + one audit row. The contract names `proxy_requests` as
/// the durable backstop, but that table is keyed on
/// `(operator_id, location_id, idempotency_key)` with NOT NULL FKs
/// to `locations` (see `db/migrations/202604250007_advisor_rls_index_hardening.sql`)
/// and the toggle route is cross-tenant (super_admin actor with no
/// operator/location scope). The 11A.3a comment in
/// `db/migrations/202605010000_phase_11A_3a_corpus_versions_ledger.sql`
/// already records this fit problem and points cross-tenant admin
/// dedup at a separate cache. Until that cache table grows the
/// `payload_hash` / `request_type` columns the contract needs, this
/// gateway runs the in-memory LRU posture only — same shape as the
/// graph-commit pattern at the top of this file. Loss of dedup on
/// proxy restart costs at most one duplicate audit row; the flag
/// state itself is naturally idempotent (`UPDATE feature_flags SET
/// enabled=...` is the same write whether run once or many).
class RepositoryFeatureFlagsAdminProxyGateway
    implements FeatureFlagsAdminProxyGateway {
  RepositoryFeatureFlagsAdminProxyGateway({
    required FeatureFlagsRepository featureFlagsRepository,
    required AuthEventsAuditRepository auditRepository,
    FeatureFlagToggleIdempotencyCache? idempotencyCache,
  }) : _flags = featureFlagsRepository,
       _auditRepository = auditRepository,
       _idempotencyCache =
           idempotencyCache ?? FeatureFlagToggleIdempotencyCache();

  final FeatureFlagsRepository _flags;
  final AuthEventsAuditRepository _auditRepository;
  final FeatureFlagToggleIdempotencyCache _idempotencyCache;

  /// `request_type` value the cache stores alongside each entry. The
  /// 409 `idempotency_request_in_flight` envelope fires when a
  /// future caller reuses the same key against a different
  /// `request_type`.
  static const String _toggleRequestType = 'admin.feature_flag_toggle';

  @override
  Future<List<Map<String, Object?>>> listFlags({
    required String actorUserId,
    required String adminReason,
  }) async {
    final rows = await _flags.listFlags(adminReason: adminReason);
    return <Map<String, Object?>>[for (final row in rows) row.toJson()];
  }

  @override
  Future<Map<String, Object?>?> toggleFlag({
    required String actorUserId,
    required String flagId,
    required bool enabled,
    required String idempotencyKey,
    required String adminReason,
    String? reason,
  }) {
    // SYNC prefix — no `await` before `runOrReplay` returns. Two
    // concurrent calls with the same key cannot both observe a cache
    // miss because the reservation runs in `runOrReplay`'s synchronous
    // prefix (mirrors the graph-commit pattern in this file).
    final payloadHash = _computePayloadHash(
      flagId: flagId,
      enabled: enabled,
      adminReason: adminReason,
      actorUserId: actorUserId,
      reason: reason,
    );
    try {
      return _idempotencyCache.runOrReplay(
        requestType: _toggleRequestType,
        idempotencyKey: idempotencyKey,
        payloadHash: payloadHash,
        compute: () => _toggleFlagInternal(
          actorUserId: actorUserId,
          flagId: flagId,
          enabled: enabled,
          idempotencyKey: idempotencyKey,
          adminReason: adminReason,
          reason: reason,
        ),
      );
    } on _IdempotencyRequestTypeMismatch {
      throw const FeatureFlagsAdminGatewayValidationError(
        statusCode: 409,
        code: 'idempotency_request_in_flight',
        message:
            'Idempotency-Key was already used by a request of a different '
            'type; pick a fresh key for this request',
      );
    } on _IdempotencyPayloadMismatch {
      throw const FeatureFlagsAdminGatewayValidationError(
        statusCode: 422,
        code: 'idempotency_payload_mismatch',
        message:
            'Idempotency-Key was already used with a different request '
            'payload; pick a fresh key or resubmit the original payload',
      );
    }
  }

  Future<Map<String, Object?>?> _toggleFlagInternal({
    required String actorUserId,
    required String flagId,
    required bool enabled,
    required String idempotencyKey,
    required String adminReason,
    String? reason,
  }) async {
    // Toggle + audit + audit_logs fan-out commit together. The audit
    // write rides the same `withSystem` transaction the UPDATE opens
    // (via the [onCommit] callback on the repository), so either
    // both rows land or both roll back. If we instead split them
    // into two transactions, an audit failure after a successful
    // toggle would (a) leave the state change unaudited and
    // (b) drop the cache slot via catchError, letting a retry
    // re-mutate (and emit a fresh audit row attributed to the
    // retry's transaction, with stale-vs-original timestamps).
    final row = await _flags.toggleFlag(
      flagId: flagId,
      enabled: enabled,
      actorUserId: actorUserId,
      adminReason: adminReason,
      onCommit: (exec, row) async {
        // HARD-H audit fan-out: pass the flag's operator_id +
        // location_id through to the audit boundary so the
        // audit_logs hash-chained mirror row lands when the flag is
        // operator-scoped. `_fanOutToAuditLogs` short-circuits on
        // `operatorId == null` (true global flags), and the
        // audit_logs schema cannot store those anyway because
        // `operator_id NOT NULL`.
        await _auditRepository.insertSystemEventOn(
          exec,
          actorUserId: actorUserId,
          operatorId: row.operatorId,
          locationId: row.locationId,
          eventType: 'admin.feature_flags.toggle',
          payload: <String, Object?>{
            'admin_reason': adminReason,
            'flag_id': row.flagId,
            'flag_name': row.flagName,
            'enabled': row.enabled,
            'kind': row.kind,
            'idempotency_key': idempotencyKey,
            // HARD-B - optional operator-supplied rationale. Omitted
            // entirely from the payload when null/empty so the
            // audit_logs canonical-encoding hash chain stays stable
            // for callers that did not opt in to the field.
            if (reason != null && reason.isNotEmpty) 'reason': reason,
          },
        );
      },
    );
    if (row == null) return null;
    return row.toJson();
  }

  /// SHA-256 of canonical (sorted-key, no-whitespace) JSON of the
  /// fields the contract names. Used to detect same-key + different-
  /// payload retries (the 422 `idempotency_payload_mismatch` case).
  /// Hand-built so a future change to `dart:convert`'s map-iteration
  /// order cannot silently shift the hash.
  ///
  /// HARD-B - `reason` participates in the hash so a retry that
  /// changes the rationale 422-conflicts (e.g. a typo correction
  /// midway through the retry).
  static String _computePayloadHash({
    required String flagId,
    required bool enabled,
    required String adminReason,
    required String actorUserId,
    String? reason,
  }) {
    final canonical =
        '{'
        '"actor_user_id":${jsonEncode(actorUserId)},'
        '"admin_reason":${jsonEncode(adminReason)},'
        '"enabled":$enabled,'
        '"flag_id":${jsonEncode(flagId)},'
        '"reason":${jsonEncode(reason ?? '')}'
        '}';
    return sha256.convert(utf8.encode(canonical)).toString();
  }
}

class RepositoryDebugConsoleAdminProxyGateway
    implements DebugConsoleAdminProxyGateway {
  RepositoryDebugConsoleAdminProxyGateway({
    required TenantTransactionWrapper adminWrapper,
  }) : _adminWrapper = adminWrapper;

  final TenantTransactionWrapper _adminWrapper;

  @override
  Future<List<Map<String, Object?>>> listRequests({
    required String actorUserId,
    required String adminReason,
    String? operatorId,
    String? locationId,
    String? usageClass,
    String? status,
    int? timeWindowSeconds,
    String? searchText,
    required int limit,
    required bool includeFullContent,
  }) {
    return _adminWrapper.runAsSystem<List<Map<String, Object?>>>((exec) async {
      final rows = await exec.query(
        _debugRequestProjectionSql,
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'usage_class': usageClass,
          'status': status,
          'time_window_seconds': timeWindowSeconds,
          'search_text': searchText,
          'search_like': searchText == null ? null : '$searchText%',
          'limit': limit,
          'include_full_content': includeFullContent,
        },
      );
      return <Map<String, Object?>>[
        for (final row in rows) _debugRequestRowJson(row),
      ];
    }, reason: adminReason);
  }

  @override
  Future<Map<String, Object?>?> getByRequestId({
    required String actorUserId,
    required String adminReason,
    required String requestId,
    required bool includeFullContent,
  }) {
    return _fetchOneDebugRequest(
      adminReason: adminReason,
      includeFullContent: includeFullContent,
      extraWhere: 'and pr.request_id = @request_id::uuid',
      parameters: <String, Object?>{'request_id': requestId},
    );
  }

  @override
  Future<Map<String, Object?>?> getByIdempotencyKey({
    required String actorUserId,
    required String adminReason,
    required String idempotencyKey,
    required bool includeFullContent,
  }) {
    return _fetchOneDebugRequest(
      adminReason: adminReason,
      includeFullContent: includeFullContent,
      extraWhere: 'and pr.idempotency_key = @idempotency_key',
      parameters: <String, Object?>{'idempotency_key': idempotencyKey},
    );
  }

  @override
  Future<List<Map<String, Object?>>> tailRecent({
    required String actorUserId,
    required String adminReason,
    required int limit,
    required bool includeFullContent,
  }) {
    return listRequests(
      actorUserId: actorUserId,
      adminReason: adminReason,
      limit: limit,
      includeFullContent: includeFullContent,
    );
  }

  @override
  Future<List<Map<String, Object?>>> listFullContentOptIns({
    required String actorUserId,
    required String adminReason,
  }) {
    return _adminWrapper.runAsSystem<List<Map<String, Object?>>>((exec) async {
      final rows = await exec.query('''
select
  flag_id::text as flag_id,
  operator_id::text as operator_id,
  flag_name,
  enabled,
  updated_at,
  updated_by
from public.feature_flags
where flag_name = 'debug_console_full_content_enabled'
  and operator_id is not null
  and location_id is null
order by operator_id::text
''');
      return <Map<String, Object?>>[
        for (final row in rows)
          <String, Object?>{
            'flag_id': row['flag_id']?.toString(),
            'operator_id': row['operator_id']?.toString() ?? '',
            'flag_name': row['flag_name']?.toString() ?? '',
            'enabled': row['enabled'] == true,
            'updated_at': _adminIso(row['updated_at']),
            'updated_by': row['updated_by']?.toString(),
          },
      ];
    }, reason: adminReason);
  }

  Future<Map<String, Object?>?> _fetchOneDebugRequest({
    required String adminReason,
    required bool includeFullContent,
    required String extraWhere,
    required Map<String, Object?> parameters,
  }) {
    return _adminWrapper.runAsSystem<Map<String, Object?>?>((exec) async {
      final rows = await exec.query(
        _debugRequestBaseSelect(extraWhere: extraWhere, limitClause: 'limit 1'),
        parameters: <String, Object?>{
          ...parameters,
          'include_full_content': includeFullContent,
        },
      );
      if (rows.isEmpty) return null;
      return _debugRequestRowJson(rows.single);
    }, reason: adminReason);
  }
}

class RepositoryObservabilityAdminProxyGateway
    implements ObservabilityAdminProxyGateway {
  RepositoryObservabilityAdminProxyGateway({
    required TenantTransactionWrapper adminWrapper,
    String? cloudRunServiceName,
    String? cloudRunRevision,
  }) : _adminWrapper = adminWrapper,
       _cloudRunServiceName = cloudRunServiceName,
       _cloudRunRevision = cloudRunRevision;

  final TenantTransactionWrapper _adminWrapper;
  final String? _cloudRunServiceName;
  final String? _cloudRunRevision;

  @override
  Future<Map<String, Object?>> fetch({
    required String actorUserId,
    required String adminReason,
    required int costTelemetryLimit,
    String? queryClassFilter,
  }) {
    return _adminWrapper.runAsSystem<Map<String, Object?>>((exec) async {
      final asOf = DateTime.now().toUtc();
      final costRows = await exec.query(
        _observabilityCostTelemetrySql,
        parameters: <String, Object?>{
          'query_class': queryClassFilter,
          'limit': costTelemetryLimit,
        },
      );
      final costTotal = costRows.isEmpty
          ? 0
          : _adminInt(costRows.first['total_count']);
      final cacheRows = await exec.query(_observabilityCacheHitSql);
      final modelRows = await exec.query(_observabilityModelMixSql);
      final batchRows = await exec.query(_observabilityBatchShareSql);
      final dormancyRows = await exec.query(
        _observabilityDormancySql,
        parameters: <String, Object?>{'as_of': asOf.toIso8601String()},
      );
      final graphRows = await exec.query(_observabilityGraphSql);
      final graphRow = graphRows.isEmpty
          ? const <String, Object?>{}
          : graphRows.single;

      return <String, Object?>{
        'as_of': asOf.toIso8601String(),
        'contract': 'admin_observability.v1',
        'schema_version': 1,
        'cost_telemetry': <Map<String, Object?>>[
          for (final row in costRows) _costTelemetryRowJson(row),
        ],
        'cost_telemetry_meta': <String, Object?>{
          'total_count': costTotal,
          'truncated': costTotal > costRows.length,
          if (queryClassFilter != null) 'query_class_filter': queryClassFilter,
        },
        'cache_hit_rates': <Map<String, Object?>>[
          for (final row in cacheRows)
            <String, Object?>{
              'query_class': row['query_class']?.toString() ?? '',
              'hit_rate': _adminDouble(row['hit_rate']),
              'yellow_threshold': 0.30,
              'red_threshold': 0.10,
            },
        ],
        'model_mix': <Map<String, Object?>>[
          for (final row in modelRows)
            <String, Object?>{
              'query_class': row['query_class']?.toString() ?? '',
              'haiku_share': _adminDouble(row['haiku_share']),
              'sonnet_share': _adminDouble(row['sonnet_share']),
              'sonnet_share_ceiling': 0.40,
            },
        ],
        'batch_mode_share': <Map<String, Object?>>[
          for (final row in batchRows)
            <String, Object?>{
              'query_class': row['query_class']?.toString() ?? '',
              'batch_share': _adminDouble(row['batch_share']),
              'target_share': 0.50,
            },
        ],
        // These surfaces intentionally stay empty until their durable
        // producers exist. Empty lists keep the dashboard neutral rather
        // than showing synthetic top-N, revenue, cap-event, route, or
        // Cloud Run instance confidence.
        'top_expensive': const <Map<String, Object?>>[],
        'dormancy': <Map<String, Object?>>[
          for (final row in dormancyRows)
            <String, Object?>{
              'operator_id': row['operator_id']?.toString() ?? '',
              'business_name': row['business_name']?.toString() ?? '',
              'last_active_at': _adminIsoOrNull(row['last_active_at']),
              'days_silent': row['days_silent'] == null
                  ? null
                  : _adminInt(row['days_silent']),
              'subscription_tier': row['subscription_tier']?.toString(),
            },
        ],
        'margins': const <Map<String, Object?>>[],
        'cap_events': const <Map<String, Object?>>[],
        'graph': <String, Object?>{
          'approved_node_count': _adminInt(graphRow['approved_node_count']),
          'approved_edge_count': _adminInt(graphRow['approved_edge_count']),
          'inferred_approved_count': _adminInt(
            graphRow['inferred_approved_count'],
          ),
          'rejected_candidate_count': _adminInt(
            graphRow['rejected_candidate_count'],
          ),
          'isolated_node_count': _adminInt(graphRow['isolated_node_count']),
          'projection_age_seconds': _adminInt(
            graphRow['projection_age_seconds'],
          ),
          'traversal_p95_ms': 0,
        },
        'route_latency': const <Map<String, Object?>>[],
        'cloud_run': const <Map<String, Object?>>[],
        'producer_notes': <String, Object?>{
          'cloud_run_service_name': _cloudRunServiceName,
          'cloud_run_revision': _cloudRunRevision,
          'neutral_empty_surfaces': const <String>[
            'top_expensive',
            'margins',
            'cap_events',
            'route_latency',
            'cloud_run',
          ],
        },
      };
    }, reason: adminReason);
  }
}

const String _debugRequestProjectionSql = '''
select *
from (
  select
    pr.request_id::text as request_id,
    pr.idempotency_key,
    pr.operator_id::text as operator_id,
    pr.location_id::text as location_id,
    pr.usage_class,
    case
      when pr.response_payload is null then 'unknown'
      else 'success'
    end as status,
    pr.created_at as started_at,
    greatest(
      0,
      floor(
        extract(epoch from (coalesce(pr.updated_at, pr.created_at) - pr.created_at))
        * 1000
      )
    )::int as latency_ms,
    jsonb_build_object(
      'request_type', pr.request_type,
      'response_recorded', pr.response_payload is not null,
      'content_logging', 'meta_only'
    ) as request_meta,
    coalesce(ff.enabled, false) as full_content_opt_in,
    case
      when @include_full_content::boolean
       and coalesce(ff.enabled, false)
       and pr.response_payload is not null
      then pr.response_payload
      else null
    end as full_content
  from public.proxy_requests pr
  left join public.feature_flags ff
    on ff.flag_name = 'debug_console_full_content_enabled'
   and ff.operator_id = pr.operator_id
   and ff.location_id is null
) projected
where (@operator_id::uuid is null or projected.operator_id::uuid = @operator_id::uuid)
  and (@location_id::uuid is null or projected.location_id::uuid = @location_id::uuid)
  and (@usage_class::text is null or projected.usage_class = @usage_class)
  and (@status::text is null or projected.status = @status)
  and (
    @time_window_seconds::int is null
    or projected.started_at >= now() - make_interval(secs => @time_window_seconds::int)
  )
  and (
    @search_text::text is null
    or projected.request_id ilike @search_like
    or projected.idempotency_key ilike @search_like
  )
order by projected.started_at desc
limit @limit::int
''';

String _debugRequestBaseSelect({
  required String extraWhere,
  required String limitClause,
}) =>
    '''
select
  pr.request_id::text as request_id,
  pr.idempotency_key,
  pr.operator_id::text as operator_id,
  pr.location_id::text as location_id,
  pr.usage_class,
  case
    when pr.response_payload is null then 'unknown'
    else 'success'
  end as status,
  pr.created_at as started_at,
  greatest(
    0,
    floor(
      extract(epoch from (coalesce(pr.updated_at, pr.created_at) - pr.created_at))
      * 1000
    )
  )::int as latency_ms,
  jsonb_build_object(
    'request_type', pr.request_type,
    'response_recorded', pr.response_payload is not null,
    'content_logging', 'meta_only'
  ) as request_meta,
  coalesce(ff.enabled, false) as full_content_opt_in,
  case
    when @include_full_content::boolean
     and coalesce(ff.enabled, false)
     and pr.response_payload is not null
    then pr.response_payload
    else null
  end as full_content
from public.proxy_requests pr
left join public.feature_flags ff
  on ff.flag_name = 'debug_console_full_content_enabled'
 and ff.operator_id = pr.operator_id
 and ff.location_id is null
where 1 = 1
$extraWhere
order by pr.created_at desc
$limitClause
''';

Map<String, Object?> _debugRequestRowJson(PostgresRow row) {
  return <String, Object?>{
    'request_id': row['request_id']?.toString() ?? '',
    'idempotency_key': row['idempotency_key']?.toString() ?? '',
    'operator_id': row['operator_id']?.toString() ?? '',
    'location_id': row['location_id']?.toString(),
    'usage_class': row['usage_class']?.toString() ?? '',
    'status': row['status']?.toString() ?? 'unknown',
    'started_at': _adminIso(row['started_at']),
    'latency_ms': _adminInt(row['latency_ms']),
    'request_meta': _adminJsonObject(row['request_meta']),
    'full_content_opt_in': row['full_content_opt_in'] == true,
    if (row['full_content'] != null)
      'full_content': _adminJsonObject(row['full_content']),
  };
}

const String _observabilityCostTelemetrySql = '''
with rows as (
  select
    l.operator_id::text as operator_id,
    l.location_id::text as location_id,
    l.staff_id::text as staff_id,
    l.workflow_id::text as workflow_id,
    l.usage_class,
    l.query_class,
    sum(l.cost_usd)::double precision as total_usd,
    sum(l.request_count)::bigint as request_count,
    max(o.business_name) as business_name
  from public.usage_logs l
  join public.operators o on o.operator_id = l.operator_id
  where l.period_start >= date_trunc('month', now() - interval '30 days')
    and (@query_class::text is null or l.query_class = @query_class)
  group by
    l.operator_id,
    l.location_id,
    l.staff_id,
    l.workflow_id,
    l.usage_class,
    l.query_class
),
counted as (
  select count(*)::int as total_count from rows
)
select rows.*, counted.total_count
from rows cross join counted
order by rows.total_usd desc, rows.request_count desc
limit @limit::int
''';

const String _observabilityCacheHitSql = '''
select
  query_class,
  coalesce(
    sum(case when cache_hit then request_count else 0 end)::double precision /
      nullif(sum(request_count), 0),
    0
  ) as hit_rate
from public.usage_logs
where period_start >= date_trunc('month', now() - interval '30 days')
group by query_class
having sum(request_count) > 0
order by query_class
''';

const String _observabilityModelMixSql = '''
select
  query_class,
  coalesce(
    sum(
      case
        when lower(llm_tier) like '%haiku%' or lower(model_used) like '%haiku%'
        then request_count
        else 0
      end
    )::double precision / nullif(sum(request_count), 0),
    0
  ) as haiku_share,
  coalesce(
    sum(
      case
        when lower(llm_tier) like '%sonnet%' or lower(model_used) like '%sonnet%'
        then request_count
        else 0
      end
    )::double precision / nullif(sum(request_count), 0),
    0
  ) as sonnet_share
from public.usage_logs
where period_start >= date_trunc('month', now() - interval '30 days')
group by query_class
having sum(request_count) > 0
order by query_class
''';

const String _observabilityBatchShareSql = '''
select
  query_class,
  coalesce(
    sum(case when batch_mode then request_count else 0 end)::double precision /
      nullif(sum(request_count), 0),
    0
  ) as batch_share
from public.usage_logs
where period_start >= date_trunc('month', now() - interval '30 days')
group by query_class
having sum(request_count) > 0
order by query_class
''';

const String _observabilityDormancySql = '''
select
  o.operator_id::text as operator_id,
  o.business_name,
  o.subscription_tier,
  max(l.updated_at) as last_active_at,
  case
    when max(l.updated_at) is null then null
    else greatest(
      0,
      floor(extract(epoch from (@as_of::timestamptz - max(l.updated_at))) / 86400)
    )::int
  end as days_silent
from public.operators o
left join public.usage_logs l on l.operator_id = o.operator_id
group by o.operator_id, o.business_name, o.subscription_tier
order by last_active_at asc nulls first, o.business_name asc
limit 200
''';

const String _observabilityGraphSql = '''
with active_nodes as (
  select *
  from public.graph_nodes
  where deleted_at is null
    and archived_at is null
    and active_from <= now()
    and (active_to is null or active_to > now())
),
active_edges as (
  select *
  from public.graph_edges
  where deleted_at is null
    and archived_at is null
    and active_from <= now()
    and (active_to is null or active_to > now())
),
latest_graph_update as (
  select max(updated_at) as updated_at
  from (
    select updated_at from public.graph_nodes
    union all
    select updated_at from public.graph_edges
  ) updates
)
select
  (select count(*)::int from active_nodes) as approved_node_count,
  (select count(*)::int from active_edges) as approved_edge_count,
  (
    select count(*)::int
    from active_edges
    where properties->>'confidence_label' = 'INFERRED'
  ) as inferred_approved_count,
  (
    select count(*)::int
    from public.graphify_review_audit
    where decision in ('rejected', 'edited_then_rejected')
  ) as rejected_candidate_count,
  (
    select count(*)::int
    from active_nodes n
    where not exists (
      select 1
      from active_edges e
      where e.operator_id = n.operator_id
        and e.graph_scope = n.graph_scope
        and e.graph_version = n.graph_version
        and (e.from_node_id = n.id or e.to_node_id = n.id)
    )
  ) as isolated_node_count,
  coalesce(
    floor(extract(epoch from (now() - (select updated_at from latest_graph_update))))::int,
    0
  ) as projection_age_seconds
''';

Map<String, Object?> _costTelemetryRowJson(PostgresRow row) {
  return <String, Object?>{
    'operator_id': row['operator_id']?.toString() ?? '',
    'location_id': row['location_id']?.toString(),
    'staff_id': row['staff_id']?.toString(),
    'workflow_id': row['workflow_id']?.toString(),
    'usage_class': row['usage_class']?.toString() ?? '',
    'query_class': row['query_class']?.toString() ?? '',
    'total_usd': _adminDouble(row['total_usd']),
    'request_count': _adminInt(row['request_count']),
    'business_name': row['business_name']?.toString(),
  };
}

String _adminIso(Object? value) {
  return _adminIsoOrNull(value) ?? DateTime.utc(1970).toIso8601String();
}

String? _adminIsoOrNull(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc().toIso8601String();
  final parsed = DateTime.tryParse(value.toString());
  return parsed?.toUtc().toIso8601String();
}

int _adminInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _adminDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0.0;
}

Map<String, Object?> _adminJsonObject(Object? value) {
  if (value is Map) return value.cast<String, Object?>();
  if (value is String && value.isNotEmpty) {
    final decoded = jsonDecode(value);
    if (decoded is Map) return decoded.cast<String, Object?>();
  }
  return const <String, Object?>{};
}

/// In-memory dedup for HARD-D. See the comment on
/// [RepositoryFeatureFlagsAdminProxyGateway] for why this cache lives
/// here instead of in `proxy_requests` / `admin_idempotency_cache`.
///
/// Concurrent-safe by construction: [runOrReplay] does its lookup +
/// reservation in its synchronous prefix (no `await` before it
/// returns), so two simultaneous calls with the same key cannot both
/// miss — the second arrival reads the first arrival's pending
/// Future and awaits the same compute.
class FeatureFlagToggleIdempotencyCache {
  FeatureFlagToggleIdempotencyCache({this.maxEntries = 1024})
    : assert(maxEntries > 0, 'maxEntries must be positive');

  /// Hard cap on cached entries. The toggle route is super-admin
  /// only so unique-key floods are extremely unlikely in practice;
  /// the bound is here so a long-running proxy cannot leak unbounded
  /// memory across months of operator activity.
  final int maxEntries;

  /// LinkedHashMap preserves insertion order, which doubles as LRU
  /// eviction order: cache hits re-insert the entry to promote it,
  /// pure misses pop the oldest insertion when the map exceeds
  /// [maxEntries].
  final LinkedHashMap<String, _FeatureFlagToggleCacheEntry> _store =
      LinkedHashMap<String, _FeatureFlagToggleCacheEntry>();

  /// Cached entry count — exposed so the LRU-eviction test can
  /// assert on the bound without poking at private fields.
  int get length => _store.length;

  /// Looks up [idempotencyKey]:
  ///   - cache miss → reserves the slot synchronously (before any
  ///     await happens inside [compute]) and returns the [compute]
  ///     Future. Two concurrent calls with the same key cannot both
  ///     observe a miss because the reservation runs in this
  ///     method's synchronous prefix.
  ///   - cache hit, [requestType] mismatch → throws
  ///     [_IdempotencyRequestTypeMismatch] (the contract's 409 case).
  ///   - cache hit, [payloadHash] mismatch → throws
  ///     [_IdempotencyPayloadMismatch] (the contract's 422 case).
  ///   - cache hit, both match → returns the prior Future without
  ///     re-running [compute] (the contract's "exactly one audit
  ///     row" guarantee).
  ///
  /// On compute failure the entry is removed so a fresh retry with
  /// the same key gets a clean attempt — Stripe-style: a transient
  /// failure does not poison the key permanently.
  ///
  /// **In-flight entries are pinned from eviction.** The contract's
  /// concurrent-collapse guarantee requires that two same-key calls
  /// in flight at the same time share one Future. If LRU eviction
  /// were allowed to drop a pending entry under burst pressure, a
  /// retry of the evicted-but-still-running key would be a cache
  /// miss and start a second compute — duplicate toggle, duplicate
  /// audit. So the eviction loop walks past entries whose Future
  /// has not settled and only removes settled entries. Under a
  /// burst of more than [maxEntries] simultaneous in-flight calls
  /// the cache temporarily exceeds [maxEntries]; pending entries
  /// drain naturally when their Futures complete and the cache
  /// returns to bound. Toggle compute is bounded by Postgres
  /// latency (sub-second), so this is self-limiting in practice.
  Future<Map<String, Object?>?> runOrReplay({
    required String requestType,
    required String idempotencyKey,
    required String payloadHash,
    required Future<Map<String, Object?>?> Function() compute,
  }) {
    final cached = _store.remove(idempotencyKey);
    if (cached != null) {
      // Re-insert at the tail so frequently-replayed entries survive
      // longer under LRU eviction than untouched ones.
      _store[idempotencyKey] = cached;
      if (cached.requestType != requestType) {
        throw const _IdempotencyRequestTypeMismatch();
      }
      if (cached.payloadHash != payloadHash) {
        throw const _IdempotencyPayloadMismatch();
      }
      return cached.future;
    }
    // Reserve the slot BEFORE the first await inside [compute].
    // Two equivalent shapes were considered:
    //   - `Future.sync(compute).catchError(handler)` — concise but
    //     `catchError` + `Error.throwWithStackTrace` surfaces the
    //     rethrown error as an unhandled-future-error in some test
    //     zones even when the caller does `await` and try/catch.
    //   - The async wrapper below — handles the same removal logic
    //     with a plain try/rethrow that the awaiting caller catches
    //     normally. We use this one.
    late Future<Map<String, Object?>?> pending;
    late _FeatureFlagToggleCacheEntry entry;
    pending = () async {
      try {
        return await compute();
      } catch (_) {
        // Drop the entry only if it still points at OUR future — a
        // later overwrite (e.g., key reuse after our removal)
        // shouldn't be evicted by our failure.
        final current = _store[idempotencyKey];
        if (current != null && identical(current.future, pending)) {
          _store.remove(idempotencyKey);
        }
        rethrow;
      }
    }();
    entry = _FeatureFlagToggleCacheEntry(
      requestType: requestType,
      payloadHash: payloadHash,
      future: pending,
    );
    _store[idempotencyKey] = entry;
    // Mark the entry settled when the Future resolves (success OR
    // failure) AND trim any settled overflow. The trim is what
    // brings the cache back to [maxEntries] after a burst of
    // pending entries drain — without it, a completed burst would
    // leave the cache above its bound until the next insert
    // happened to fire.
    //
    // For failures the entry is already removed from the map by
    // the catch block above; this whenComplete just flips the
    // in-flight flag on the orphaned entry (harmless) and re-runs
    // the trim against any other settled entries.
    //
    // The trailing `.catchError((_) {})` is load-bearing: a Future
    // can have multiple listeners, and each unhandled failure is
    // reported separately. The caller's `await pending` handles the
    // primary listener; this secondary listener (the whenComplete
    // chain) needs its own error sink, otherwise the test runner
    // and prod zones see a duplicate "unhandled async error" report
    // for every failed compute.
    // ignore: unawaited_futures
    pending
        .whenComplete(() {
          entry.isPending = false;
          // No `exceptKey`: the just-settled entry is now fair game
          // for eviction. Any awaiter holding the Future already has
          // it; removing the cache slot just means subsequent retries
          // are cache misses (which is the LRU contract).
          _trimSettledOverflow();
        })
        .catchError((Object _) {
          // Secondary listener — primary `await` consumer handles the
          // real error. Returning null aligns with the chain's
          // `Map<String, Object?>?` value type so the analyzer's
          // `body_might_complete_normally_catch_error` rule is satisfied.
          return null;
        });
    _trimSettledOverflow(exceptKey: idempotencyKey);
    return pending;
  }

  /// Drops settled entries (oldest first) until the cache is back
  /// to [maxEntries], skipping any entry that is still pending and
  /// optionally [exceptKey] (used by the insert path so an entry's
  /// own overflow trigger can never evict the entry it just
  /// inserted). When called from the post-settle whenComplete chain
  /// no [exceptKey] is supplied — the just-settled entry is
  /// evictable like any other settled one. In-flight entries stay
  /// pinned so the concurrent-collapse guarantee holds (see
  /// [runOrReplay] doc comment); the cache may legitimately exceed
  /// [maxEntries] until pending entries drain.
  void _trimSettledOverflow({String? exceptKey}) {
    if (_store.length <= maxEntries) return;
    final keys = _store.keys.toList(growable: false);
    var overflow = _store.length - maxEntries;
    for (final key in keys) {
      if (overflow == 0) return;
      if (exceptKey != null && key == exceptKey) continue;
      final entry = _store[key];
      if (entry == null || entry.isPending) continue;
      _store.remove(key);
      overflow -= 1;
    }
  }
}

class _FeatureFlagToggleCacheEntry {
  _FeatureFlagToggleCacheEntry({
    required this.requestType,
    required this.payloadHash,
    required this.future,
  });

  final String requestType;
  final String payloadHash;
  final Future<Map<String, Object?>?> future;

  /// Flipped to false by [FeatureFlagToggleIdempotencyCache.runOrReplay]
  /// once [future] settles. Used by `_evictOverflow` to skip
  /// in-flight entries — see the doc comment on `runOrReplay` for
  /// why pending entries cannot be evicted without breaking the
  /// concurrent-collapse guarantee.
  bool isPending = true;
}

/// Sentinel raised by [FeatureFlagToggleIdempotencyCache.runOrReplay]
/// when the cached entry's `request_type` differs from the caller's
/// — the contract's 409 envelope.
class _IdempotencyRequestTypeMismatch implements Exception {
  const _IdempotencyRequestTypeMismatch();
}

/// Sentinel raised by [FeatureFlagToggleIdempotencyCache.runOrReplay]
/// when the cached entry's `payload_hash` differs from the caller's
/// — the contract's 422 envelope. The cached row is preserved (no
/// mutation) so the original caller's response is still replayable.
class _IdempotencyPayloadMismatch implements Exception {
  const _IdempotencyPayloadMismatch();
}

/// HARD-H — production [AdminRequestIdempotencyStore] backed by
/// `public.admin_request_idempotency`. The store operates against the
/// admin pool because admin routes are cross-tenant and the table has
/// no operator_id column; `service_role` is granted SELECT/INSERT/
/// UPDATE on the table by the HARD-H migration.
class PostgresAdminRequestIdempotencyStore
    implements AdminRequestIdempotencyStore {
  PostgresAdminRequestIdempotencyStore({required PostgresPool pool})
    : _pool = pool;

  final PostgresPool _pool;

  @override
  Future<AdminRequestIdempotencyEntry?> lookup({
    required String idempotencyKey,
    required String requestType,
    required String requestBodyHash,
  }) async {
    final tx = await _pool.beginTransaction();
    try {
      final rows = await tx.query(
        'select idempotency_key, request_type, request_body_hash, '
        '       response_status, response_payload, completed_at '
        '  from public.admin_request_idempotency '
        ' where idempotency_key = @key '
        ' limit 1',
        parameters: <String, Object?>{'key': idempotencyKey},
      );
      await tx.commit();
      if (rows.isEmpty) return null;
      final row = rows.single;
      final storedRequestType = row['request_type']! as String;
      if (storedRequestType != requestType) {
        throw AdminIdempotencyKeyConflict(
          message:
              'Idempotency-Key was already used for a different request '
              'type ($storedRequestType)',
        );
      }
      final storedBodyHash = row['request_body_hash'] as String?;
      if (storedBodyHash != null && storedBodyHash != requestBodyHash) {
        throw AdminIdempotencyKeyConflict(
          message:
              'Idempotency-Key was already used with a different request '
              'body',
        );
      }
      final status = row['response_status'];
      final payloadRaw = row['response_payload'];
      Map<String, Object?>? payload;
      if (payloadRaw is Map) {
        payload = Map<String, Object?>.from(payloadRaw);
      } else if (payloadRaw is String && payloadRaw.isNotEmpty) {
        try {
          final decoded = jsonDecode(payloadRaw);
          if (decoded is Map) {
            payload = Map<String, Object?>.from(decoded);
          }
        } on FormatException {
          payload = null;
        }
      }
      return AdminRequestIdempotencyEntry(
        idempotencyKey: row['idempotency_key']! as String,
        requestType: storedRequestType,
        responseStatus: status is int ? status : null,
        responsePayload: payload,
        completedAt: row['completed_at'] as DateTime?,
      );
    } catch (_) {
      await tx.rollback();
      rethrow;
    }
  }

  @override
  Future<bool> reserve({
    required String idempotencyKey,
    required String requestType,
    required String? actorUserId,
    required String requestBodyHash,
  }) async {
    final tx = await _pool.beginTransaction();
    try {
      final rows = await tx.query(
        'insert into public.admin_request_idempotency '
        '(idempotency_key, request_type, actor_user_id, request_body_hash) '
        'values (@key, @kind, @actor::uuid, @hash) '
        'on conflict (idempotency_key) do nothing '
        'returning idempotency_key',
        parameters: <String, Object?>{
          'key': idempotencyKey,
          'kind': requestType,
          'actor': actorUserId,
          'hash': requestBodyHash,
        },
      );
      await tx.commit();
      return rows.isNotEmpty;
    } catch (_) {
      await tx.rollback();
      rethrow;
    }
  }

  @override
  Future<void> completeReservation({
    required String idempotencyKey,
    required int responseStatus,
    required Map<String, Object?> responsePayload,
  }) async {
    final tx = await _pool.beginTransaction();
    try {
      await tx.execute(
        'update public.admin_request_idempotency '
        'set response_status = @status, '
        '    response_payload = @payload::jsonb, '
        '    completed_at = now() '
        'where idempotency_key = @key',
        parameters: <String, Object?>{
          'key': idempotencyKey,
          'status': responseStatus,
          'payload': jsonEncode(responsePayload),
        },
      );
      await tx.commit();
    } catch (_) {
      await tx.rollback();
      rethrow;
    }
  }
}

/// Production [IntegrationAdminActorResolver] backed by
/// [UsersRepository.findActiveUserIdByFirebaseUidSystem]. The lookup
/// runs through the admin pool because F&F admin actors are not in
/// any single operator's tenant scope.
class RepositoryIntegrationAdminActorResolver
    implements IntegrationAdminActorResolver {
  RepositoryIntegrationAdminActorResolver({
    required UsersRepository usersRepository,
  }) : _users = usersRepository;

  final UsersRepository _users;

  @override
  Future<String?> resolveActorUserId({
    required String firebaseUid,
    required String adminReason,
  }) {
    return _users.findActiveUserIdByFirebaseUidSystem(
      firebaseUid: firebaseUid,
      adminReason: adminReason,
    );
  }
}

/// Builds the production auth-session ledger writer for the proxy.
///
/// Auth session writes are tenant-scoped user operations, so they use
/// [ProxySecretNames.postgresUrl] rather than the admin/deployment DSN.
/// The returned writer still fails closed at request time if the
/// database is unavailable; constructing it does not open a network
/// connection.
AuthSessionLedgerWriter buildAuthSessionLedgerWriter(
  ProxyConfig config, {
  PostgresPoolFactory postgresPoolFactory = PackagePostgresPool.fromUrl,
}) {
  final pool = postgresPoolFactory(
    config.secretFor(ProxySecretNames.postgresUrl),
  );
  return RepositoryAuthSessionLedgerWriter(
    repository: AuthSessionsRepository(TenantTransactionWrapper(pool)),
  );
}

FirebaseAdminAuthClient _buildFirebaseAdminAuthClient(
  ProxyConfig config, {
  required bool requireFirebase,
}) {
  final projectId = config.firebaseProjectId;
  if (projectId == null || projectId.isEmpty) {
    if (!requireFirebase) {
      // HARD-A staging/dev: scaffold the client so the proxy still
      // binds. Auth-required routes will refuse with
      // `firebase_admin_not_configured` at request time, matching the
      // pre-9.1 scaffold-fallback posture.
      return const ScaffoldFailingFirebaseAdminAuthClient();
    }
    throw ProxyConfigError(
      'advisor proxy missing required non-secret config by name: '
      '${ProxyConfigNames.firebaseProjectId}. Set it before exposing '
      'Phase 9 auth-operation routes.',
      missingSecretNames: const <String>[ProxyConfigNames.firebaseProjectId],
    );
  }
  return IdentityToolkitFirebaseAdminAuthClient(
    projectId: projectId,
    apiKey: config.secretFor(ProxySecretNames.firebaseWebApiKey),
    accessTokenProvider: MetadataServerAccessTokenProvider(),
    continueUrl: config.firebaseEmailActionContinueUrl,
  );
}

class RepositoryProxyPermissionSnapshotResolver
    implements ProxyPermissionSnapshotResolver {
  RepositoryProxyPermissionSnapshotResolver({
    required UserRolesRepository userRolesRepository,
    required RolePermissionsRepository rolePermissionsRepository,
    required Set<String> requiresMfaKeys,
    DateTime Function()? now,
  }) : _userRolesRepository = userRolesRepository,
       _rolePermissionsRepository = rolePermissionsRepository,
       _requiresMfaKeys = Set<String>.unmodifiable(requiresMfaKeys),
       _now = now ?? DateTime.now;

  final UserRolesRepository _userRolesRepository;
  final RolePermissionsRepository _rolePermissionsRepository;
  final Set<String> _requiresMfaKeys;
  final DateTime Function() _now;

  @override
  Future<ProxyPermissionSnapshot> load(OperatorContext scope) async {
    final bundle = await _loadPermissionBundle(
      userRolesRepository: _userRolesRepository,
      rolePermissionsRepository: _rolePermissionsRepository,
      operatorId: scope.operatorId,
      locationId: scope.locationId,
      userId: scope.userId,
    );
    final evaluatedAt = _now().toUtc();
    return ProxyPermissionSnapshot(
      userId: scope.userId,
      operatorId: scope.operatorId,
      locationId: scope.locationId,
      rolesVersion: scope.rolesVersion,
      evaluatedAt: evaluatedAt,
      permissions: PermissionResolver.resolveAll(
        grants: bundle.grants,
        rules: bundle.rules,
        operatorId: scope.operatorId,
        locationId: scope.locationId,
        now: evaluatedAt,
      ),
      requiresMfaKeys: _requiresMfaKeys,
    );
  }
}

class RepositoryProxyAdminPermissionGuard implements ProxyAdminPermissionGuard {
  RepositoryProxyAdminPermissionGuard({
    required UserRolesRepository userRolesRepository,
    required RolePermissionsRepository rolePermissionsRepository,
    required Set<String> requiresMfaKeys,
    Duration freshnessWindow = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _userRolesRepository = userRolesRepository,
       _rolePermissionsRepository = rolePermissionsRepository,
       _requiresMfaKeys = Set<String>.unmodifiable(requiresMfaKeys),
       _freshnessWindow = freshnessWindow,
       _now = now ?? DateTime.now;

  final UserRolesRepository _userRolesRepository;
  final RolePermissionsRepository _rolePermissionsRepository;
  final Set<String> _requiresMfaKeys;
  final Duration _freshnessWindow;
  final DateTime Function() _now;

  @override
  Future<ProxyAdminGuardDecision> evaluate(
    ProxyAdminGuardContext context,
  ) async {
    final requestedAt = (context.requestedAt ?? _now()).toUtc();
    final recaptcha = context.recaptchaOutcome;
    if (recaptcha == ProxyAdminGuardRecaptcha.reject) {
      return const ProxyAdminRejected(reasonCode: 'recaptcha_rejected');
    }
    if (recaptcha == ProxyAdminGuardRecaptcha.challenge) {
      return const ProxyAdminChallengeRequired();
    }

    if (_requiresMfaKeys.contains(context.requestedPermissionKey) &&
        requestedAt.difference(context.lastFreshAuthAt.toUtc()) >
            _freshnessWindow) {
      return ProxyAdminMfaStaleAuth(
        refreshAfter: context.lastFreshAuthAt.toUtc().add(_freshnessWindow),
      );
    }

    final bundle = await _loadPermissionBundle(
      userRolesRepository: _userRolesRepository,
      rolePermissionsRepository: _rolePermissionsRepository,
      operatorId: context.operatorId,
      locationId: context.locationId,
      userId: context.actorUserId,
    );
    final activeRoleIds = <String>{
      for (final grant in bundle.grants)
        if (grant.operatorId == context.operatorId &&
            grant.isActiveAt(requestedAt) &&
            grant.coversLocation(context.locationId))
          grant.roleId,
    };
    for (final rule in bundle.rules) {
      if (rule.permissionKey != context.requestedPermissionKey) continue;
      if (!activeRoleIds.contains(rule.roleId)) continue;
      if (rule.effect == PermissionEffect.deny) {
        return ProxyAdminDeniedExplicit(matchedRoleId: rule.roleId);
      }
    }
    final effect = PermissionResolver.resolve(
      permissionKey: context.requestedPermissionKey,
      grants: bundle.grants,
      rules: bundle.rules,
      operatorId: context.operatorId,
      locationId: context.locationId,
      now: requestedAt,
    );
    return effect == PermissionEffect.allow
        ? const ProxyAdminAllowed()
        : const ProxyAdminDeniedDefault();
  }
}

Future<_PermissionBundle> _loadPermissionBundle({
  required UserRolesRepository userRolesRepository,
  required RolePermissionsRepository rolePermissionsRepository,
  required String operatorId,
  required String locationId,
  required String userId,
}) async {
  final grantRows = await userRolesRepository.activeGrantsForUser(
    operatorId: operatorId,
    locationId: locationId,
    targetUserId: userId,
    actorUserId: userId,
  );
  final grants = <UserRoleGrant>[
    for (final row in grantRows)
      UserRoleGrant(
        userRoleId: row.userRoleId,
        userId: row.userId,
        roleId: row.roleId,
        operatorId: row.operatorId,
        scopeType: row.scopeType,
        locationId: row.locationId,
        orgUnitId: row.orgUnitId,
        effectiveLocationIds: row.effectiveLocationIds,
        validFrom: row.validFrom,
        validUntil: row.validUntil,
        revokedAt: row.revokedAt,
      ),
  ];
  final roleIds = grants.map((grant) => grant.roleId).toSet();
  final rules = <RolePermissionRule>[];
  for (final roleId in roleIds) {
    final rows = await rolePermissionsRepository.listForRole(
      operatorId: operatorId,
      locationId: locationId,
      roleId: roleId,
      actorUserId: userId,
    );
    rules.addAll(
      rows.map(
        (row) => RolePermissionRule(
          roleId: row.roleId,
          permissionKey: row.permissionKey,
          effect: _permissionEffectFromSql(row.effect),
        ),
      ),
    );
  }
  return _PermissionBundle(
    grants: List<UserRoleGrant>.unmodifiable(grants),
    rules: List<RolePermissionRule>.unmodifiable(rules),
  );
}

PermissionEffect _permissionEffectFromSql(String value) {
  return value == 'allow' ? PermissionEffect.allow : PermissionEffect.deny;
}

class _PermissionBundle {
  const _PermissionBundle({required this.grants, required this.rules});

  final List<UserRoleGrant> grants;
  final List<RolePermissionRule> rules;
}

// ─── Phase 11A.4c — KMS provider + Cloud Run admin wiring ────────────────────

/// Build the KMS provider for the integration admin gateway.
///
/// When [ProxyConfig.gcpProjectId] is set, returns a [KmsLaneRouter]
/// that dispatches per-lane to either the stub (flag OFF — default)
/// or [GcpSecretManagerKmsProvider] (flag ON). When the GCP project
/// id is missing, returns the stub directly so dev / scaffold
/// contexts still function without GCP credentials.
///
/// HARD-G observability fail-closed: when
/// `PROXY_ENVIRONMENT == 'prod'` AND `KMS_REAL_PROVIDER_ENABLED == true`
/// AND any of the three GCP env vars is unset, the build emits a
/// `startup.kms_misconfigured` log line and throws
/// [ProxyKmsMisconfiguredError] so the main entrypoint exits 78. In
/// staging / dev, the same missing-vars condition only emits
/// `startup.kms_stub_active` at WARN and continues with the stub
/// (current scaffold behavior preserved for non-prod).
KmsProvider _buildKmsProvider({
  required ProxyConfig config,
  required TenantTransactionWrapper adminWrapper,
  required OAuthAccessTokenProvider accessTokenProvider,
}) {
  final gcpProjectId = config.gcpProjectId;
  final cloudRunRegion = config.cloudRunRegion;
  final cloudRunServiceName = config.cloudRunServiceName;
  final missingGcpNames = <String>[
    if (gcpProjectId == null) ProxyConfigNames.gcpProjectId,
    if (cloudRunRegion == null) ProxyConfigNames.cloudRunRegion,
    if (cloudRunServiceName == null) ProxyConfigNames.cloudRunServiceName,
  ];
  final isProd = config.proxyEnvironment == 'prod';
  if (missingGcpNames.isNotEmpty) {
    if (isProd && config.kmsRealProviderEnabled) {
      log(
        LogSeverity.error,
        'startup.kms_misconfigured',
        fields: <String, Object?>{
          'missing': missingGcpNames,
          'environment': config.proxyEnvironment,
        },
      );
      throw ProxyKmsMisconfiguredError(missing: missingGcpNames);
    }
    log(
      LogSeverity.warning,
      'startup.kms_stub_active',
      fields: <String, Object?>{
        'missing': missingGcpNames,
        'environment': config.proxyEnvironment,
        'kms_real_provider_enabled': config.kmsRealProviderEnabled,
      },
    );
    return KmsStubProvider();
  }
  return KmsLaneRouter(
    stub: KmsStubProvider(),
    real: GcpSecretManagerKmsProvider(
      projectId: gcpProjectId!,
      accessTokenProvider: accessTokenProvider,
    ),
    flagLookup: (keyKind) async {
      return adminWrapper.runAsSystem<bool>((exec) async {
        return const FeatureFlagsTableKmsRolloutFlag().isEnabledFor(
          keyKind,
          exec,
        );
      }, reason: 'kms_rollout_flag_check:$keyKind');
    },
  );
}

/// HARD-C — known non-production deployment environments. Only
/// these values trigger the localhost CORS fallback in
/// [resolveAdminCorsAllowList]; an unset, misspelled, or unknown
/// `PROXY_ENVIRONMENT` is treated as production-equivalent so a
/// misconfigured deploy fails closed instead of silently allowing
/// `http://localhost:*` to call admin routes.
const Set<String> kAdminCorsDevStagingEnvironments = <String>{'dev', 'staging'};

/// HARD-C — name of the Postgres feature flag that supplies
/// supplemental admin CORS origins. Must match the `flag_name`
/// column on the `feature_flags` row at the global scope
/// (operator_id null, location_id null).
const String kAdminCorsOriginsExtraFlagName = 'admin_cors_origins_extra';

/// HARD-C — Postgres-backed source of supplemental CORS origins.
/// The contract names this row in `public.feature_flags` as the
/// authority for "ephemeral preview deploy" allow-list extras.
/// Production startup reads it once before binding a port; the
/// returned origins are merged into the active allow-list by
/// [resolveAdminCorsAllowList].
///
/// Schema overload: `feature_flags` rows carry `enabled` (bool) and
/// `description` (text). For `admin_cors_origins_extra`, the
/// description column doubles as the comma-separated origin payload
/// when the flag is enabled. This is documented behaviour for this
/// specific flag; other rows still treat description as
/// human-readable copy. Future schema work may move the payload to
/// a dedicated column without changing the contract surface
/// because callers only ever see [List<String>].
abstract class AdminCorsOriginsExtraFlag {
  /// Returns the supplemental origin list when the
  /// `admin_cors_origins_extra` flag row is enabled and its
  /// description column parses to a non-empty CSV. Returns the
  /// empty list when the flag is disabled, missing, or the
  /// description is blank.
  Future<List<String>> read();
}

/// Fixed-value implementation — used for tests / scaffolds and for
/// the rare production boot where the admin pool is unavailable
/// (e.g. a smoke run). Defaults to an empty list so a missing wire
/// silently emits no extras instead of opening up the allow-list.
class FixedAdminCorsOriginsExtraFlag implements AdminCorsOriginsExtraFlag {
  const FixedAdminCorsOriginsExtraFlag(this.origins);

  /// Convenience constructor for the most common test posture: the
  /// flag is disabled, so no extras are emitted.
  const FixedAdminCorsOriginsExtraFlag.empty() : origins = const <String>[];

  final List<String> origins;

  @override
  Future<List<String>> read() async => origins;
}

/// Production source — reads `enabled` + `description` from the
/// `admin_cors_origins_extra` row in `public.feature_flags` inside
/// a one-shot read transaction against the admin pool. Comma-splits
/// the description column when the flag is enabled. Default-off
/// when the row is missing so a fresh DB without the seed migration
/// silently emits no extras.
class FeatureFlagsTableAdminCorsOriginsExtraFlag
    implements AdminCorsOriginsExtraFlag {
  FeatureFlagsTableAdminCorsOriginsExtraFlag(PostgresPool pool) : _pool = pool;

  final PostgresPool _pool;

  @override
  Future<List<String>> read() async {
    final tx = await _pool.beginTransaction();
    try {
      final rows = await tx.query(
        'select enabled, description from public.feature_flags '
        "where flag_name = '$kAdminCorsOriginsExtraFlagName' "
        'and operator_id is null '
        'and location_id is null '
        'limit 1',
      );
      await tx.commit();
      if (rows.isEmpty) return const <String>[];
      final enabledValue = rows.single['enabled'];
      final enabled = _coerceBool(enabledValue);
      if (!enabled) return const <String>[];
      final description = rows.single['description']?.toString() ?? '';
      return _parseOriginCsv(description);
    } catch (_) {
      await tx.rollback();
      rethrow;
    }
  }

  static bool _coerceBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      return value.toLowerCase() == 'true' || value == 't';
    }
    return false;
  }
}

/// Comma-splits a CSV origin payload — used by the
/// `admin_cors_origins_extra` flag reader. Trims each entry, drops
/// empty results. Public for the test wiring; production callers
/// reach through [FeatureFlagsTableAdminCorsOriginsExtraFlag.read].
List<String> _parseOriginCsv(String raw) {
  final out = <String>[];
  for (final part in raw.split(',')) {
    final trimmed = part.trim();
    if (trimmed.isEmpty) continue;
    out.add(trimmed);
  }
  return List<String>.unmodifiable(out);
}

/// HARD-C — resolve the supplemental allow-list at startup. The
/// production main.dart awaits this once before binding a port;
/// callers pass the result as `featureFlagExtras` to
/// [resolveAdminCorsAllowList]. Read failures propagate so a flaky
/// DB at boot fails the bootstrap instead of silently turning the
/// flag off.
Future<List<String>> loadAdminCorsExtraOrigins({
  required AdminCorsOriginsExtraFlag flag,
}) async {
  return flag.read();
}

/// HARD-C — resolve the admin CORS allow-list at startup.
///
/// Layers (in order, all are unioned):
///   1. The env-var list parsed by [ProxyConfig.fromEnvironment] from
///      `ADMIN_CORS_ALLOWED_ORIGINS`.
///   2. `featureFlagExtras` — origins surfaced from the
///      `admin_cors_origins_extra` feature flag. The production
///      `main.dart` reads the flag via
///      [FeatureFlagsTableAdminCorsOriginsExtraFlag] before calling
///      this function; tests pass an inline list.
///   3. `http://localhost:*` and `http://127.0.0.1:*` when
///      [ProxyConfig.proxyEnvironment] is one of
///      [kAdminCorsDevStagingEnvironments] (`dev` or `staging`). Any
///      other value — including null, empty, or a misspelled
///      `production` / `PRD` — does NOT add local browser origins.
///
/// Fail-closed: when the resolved list is empty AND
/// [ProxyConfig.proxyEnvironment] is anything other than a known
/// dev/staging value, throws a [ProxyConfigError]. The startup
/// wrapper in `main.dart` translates that into `exit 78` with the
/// contract-required event token `admin_cors_allowlist_missing_in_prod`
/// in the message. Treating unknown values as prod-equivalent is
/// deliberate — a typo in `PROXY_ENVIRONMENT` (e.g. `production`,
/// `PRD`) must never silently bind without an explicit allow-list.
List<String> resolveAdminCorsAllowList(
  ProxyConfig config, {
  List<String> featureFlagExtras = const <String>[],
}) {
  final merged = <String>{};
  for (final entry in config.adminCorsAllowedOriginsFromEnv) {
    final trimmed = entry.trim();
    if (trimmed.isEmpty) continue;
    merged.add(trimmed);
  }
  for (final entry in featureFlagExtras) {
    final trimmed = entry.trim();
    if (trimmed.isEmpty) continue;
    merged.add(trimmed);
  }
  final environment = config.proxyEnvironment;
  final isKnownDevOrStaging =
      environment != null &&
      kAdminCorsDevStagingEnvironments.contains(environment);
  if (isKnownDevOrStaging) {
    merged.add('http://localhost:*');
    merged.add('http://127.0.0.1:*');
  }
  if (merged.isEmpty && !isKnownDevOrStaging) {
    throw ProxyConfigError(
      'advisor proxy startup failed: '
      'admin_cors_allowlist_missing_in_prod. '
      '${ProxyConfigNames.adminCorsAllowedOrigins} must be set to a '
      'non-empty comma-separated list of origins (e.g. '
      'https://admin.forgeandflow.app) unless '
      '${ProxyConfigNames.proxyEnvironment} is one of '
      '${kAdminCorsDevStagingEnvironments.join(", ")}. '
      'Current ${ProxyConfigNames.proxyEnvironment} value: '
      '${environment ?? "<unset>"}. '
      'Refusing to bind a port without an admin CORS allow-list.',
      missingSecretNames: const <String>[
        ProxyConfigNames.adminCorsAllowedOrigins,
      ],
    );
  }
  return List<String>.unmodifiable(merged);
}

/// Build the Cloud Run admin client for forced-revision restarts
/// after a runtime-read key rotation.
///
/// Production wires [HttpCloudRunAdminClient] when all three GCP
/// env vars are set. Dev / scaffold contexts get a [NoOpCloudRunAdminClient]
/// so the rotation handler still runs end-to-end without a live
/// Cloud Run service.
CloudRunAdminClient _buildCloudRunAdminClient({
  required ProxyConfig config,
  required OAuthAccessTokenProvider accessTokenProvider,
}) {
  final projectId = config.gcpProjectId;
  final region = config.cloudRunRegion;
  final serviceName = config.cloudRunServiceName;
  if (projectId == null || region == null || serviceName == null) {
    return const NoOpCloudRunAdminClient();
  }
  return HttpCloudRunAdminClient(
    projectId: projectId,
    region: region,
    serviceName: serviceName,
    accessTokenProvider: accessTokenProvider,
  );
}

// region: phase_10a_2_dlq_metric
//
// Phase 10a.2 — event_outbox dead-letter wiring.
//
// `EVENT_OUTBOX_DLQ_CAP` is the bridge worker's per-row attempt-count
// cap before a row MOVES to `event_outbox_dead_letter`. The contract
// (`docs/contracts/event_outbox_contract.md` "Worker Responsibilities"
// "Dead-letter rows whose attempt_count exceeds the tunable cap …
// expected ≥ 5") requires the cap be tunable and ≥ 5; the default
// (`defaultEventOutboxDlqCap`, declared in
// `tool/advisor_proxy/realtime_bridge.dart`) is 5 — sitting at the
// contract floor so the live `event_outbox` cannot recycle a
// permanently-failing row indefinitely.
//
// Operators tune the cap via the env var:
//
//   * Raise (e.g. EVENT_OUTBOX_DLQ_CAP=20) when triaging a vendor-
//     side outage that is expected to clear so genuinely retriable
//     failures stay in the live queue rather than landing in the DLQ.
//   * Lower (e.g. EVENT_OUTBOX_DLQ_CAP=3) when the live queue is
//     filling with the same handful of poison-pill rows and the
//     operator wants to clear them out faster.
//   * Non-numeric / blank values fall back to
//     `defaultEventOutboxDlqCap`. Caps below 1 are clamped back to
//     the default — a non-positive cap would auto-DLQ every row on
//     first failure, which destroys the bridge's retry semantics.
//
// The cap is read once at proxy startup and held on the worker; an
// env-var change only takes effect on the next deploy / process
// restart (Cloud Run discards the old revision when a new one rolls
// out, so the value is effectively immediate at the operator's
// timeline). Live tuning without restart is a post-V1 lane.
//
// `event_outbox_dlq_depth` (the new `/health` metric) reports the
// row count in `public.event_outbox_dead_letter`. The producer is
// registered in `tool/advisor_proxy/health_producers/outbox_producers.dart`
// alongside the existing `event_outbox_*` family so the
// `RegistryProxyHealthCheckStore` picks it up automatically through
// `proxyHealthProducerCatalog()` (no producer-registry mutation
// required). Thresholds: yellow at 1 (any DLQ depth needs operator
// triage), red at 100 (producer / consumer outage suspected).
//
// V1 surface posture (per `memory/project_v1_lean_cut_2_2026_05_03.md`):
// the `/health` envelope is an F&F-internal surface (Tier-1 ops
// console) — not operator-facing. Per lean cut 2 the 11A.6 DLQ tile
// is deferred; V1 ops triage flow is logs + admin SQL against
// `public.event_outbox_dead_letter`. The walkthrough at
// `docs/_walkthroughs/10a.2.md` documents the SQL queries and the
// `/health` JSON shape an F&F engineer reads during a DLQ event.
// `EventOutboxDeadLetterRepository.listByOperator` /
// `countByOperator` stay available for any future tile or replay
// flow once depth ever justifies the operator-facing investment.

/// Phase 10a.2 — public reference to the env var so deploy scripts
/// and tests can read the same constant without re-declaring the
/// literal. Mirrors `eventOutboxDlqCapEnvVar` in
/// `tool/advisor_proxy/realtime_bridge.dart`.
const String phase10a2DlqCapEnvVar = 'EVENT_OUTBOX_DLQ_CAP';

/// Phase 10a.2 — public reference to the metric key so tests can
/// look up the producer by name and the deploy verifier can grep the
/// `/health` envelope without re-declaring the literal.
const String phase10a2DlqDepthMetricKey = 'event_outbox_dlq_depth';

// endregion
