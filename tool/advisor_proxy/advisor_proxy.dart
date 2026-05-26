// Forge & Flow advisor proxy — pure scaffold.
//
// 11a.10a. The proxy is the trusted backend boundary where production
// Anthropic / Voyage / Postgres credentials live and where
// operator/location scope is resolved from the caller's JWT before
// any retrieval or provider call is made. Flutter clients never hold
// production keys — they call this proxy with a user token, and the
// proxy fans out to providers / Postgres on their behalf.
//
// 11a.11c.5 retarget: the production Postgres host moved from Supabase
// to Azure Database for PostgreSQL Flexible Server (see
// `docs/phases/phase_11a/phase_11a_decision_register.md`). The secret
// names this file declares are now generic Postgres connection
// strings (`POSTGRES_URL`, `POSTGRES_ADMIN_URL`) so the same scaffold
// runs against Azure, a local Docker dev container
// (`docker-compose.dev.yml`), or any other PG host. Historical
// references to Supabase in this codebase are preserved in archived
// reports for traceability; the active host is generic Postgres.
//
// This file is pure logic only:
//   - secret-name registry + config loader (values never logged)
//   - JWT verifier interface + operator context value class
//   - request guard that returns a scoped operator context
//   - testable HTTP route handler
//
// 11a.10a does NOT:
//   - call Anthropic, Voyage, Postgres, Firebase, or any live service
//   - enforce token / rate / monthly cost budgets (that is 11a.10b)
//   - wire the Flutter app runtime
//
// Routing rules carried by this scaffold:
//   - Production provider keys stay server-side; release builds never
//     receive them.
//   - Operator scope is resolved server-side from the JWT before any
//     downstream retrieval or provider call.
//   - The proxy is recommendation/read-only infrastructure — write /
//     action paths are not part of the launch product.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/integrations/pos/aloha_ncr_voyix_pos_production_api_client.dart'
    show AlohaNcrVoyixOauthClientCredentials;
import 'package:forge_and_flow/domain/services/advisor_provider_constants.dart';
import 'package:forge_and_flow/domain/services/advisor_response_cache.dart';
import 'package:forge_and_flow/domain/services/circuit_breaker.dart';
import 'package:forge_and_flow/domain/services/graceful_refusal_response.dart';
import 'package:forge_and_flow/domain/services/llm_provider.dart';
// Slice A3 ? `RerankCandidate` (build the candidate pool from chunks) and
// `RetrievedChunk` (reorder the pool by rerank rank) are used in the
// monolith's library scope by the retrieve route part. The rerank gateway
// itself owns the provider/result plumbing.
import 'package:forge_and_flow/domain/models/retrieved_chunk.dart'
    show RetrievedChunk;
import 'package:forge_and_flow/domain/services/rerank_provider.dart'
    show RerankCandidate;
import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart'
    show PostgresPoolGaugeSnapshot;
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/connector_connection_list_repository.dart';
// Advisor Knowledge Activation — Slice A4.6 operational read tools.
// These three repository imports back the `advisor_operational_tools_part.dart`
// tool handlers (get_active_targets / get_week_plan / get_shift_variance).
// INERT: nothing in the monolith's `routeRequest` references them yet — the
// A4.2 answer route wires them in. shift_records_read_repository.dart is new
// in this slice (the Phase 8 writer had no read companion).
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/target_cycle_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/weekly_plan_snapshot_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/shift_records_read_repository.dart';
// Advisor Knowledge Activation — Slice A4.2b answer route. The encrypted
// advisor-conversation sink + the in-process AEAD encryptor + the (abstract)
// CMK resolver back the POST /v1/advisor/answer handler in
// `advisor_answer_route_group_part.dart`. The envelope file lives in `lib/`
// and has NO proxy dependency, so importing it here introduces no cycle (the
// concrete proxy-side resolver in `advisor_conversation_cmk_resolver.dart`
// imports this monolith and is wired in `proxy_bootstrap.dart` / `main.dart`,
// never imported here).
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/advisor_conversation_log_repository.dart'
    show AdvisorConversationLogRepository;
import 'package:forge_and_flow/infrastructure/crypto/advisor_conversation_envelope.dart'
    show
        AdvisorConversationCmkResolver,
        AdvisorConversationEnvelope,
        AdvisorConversationKeyLengthError;
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/observability/dependency_timeout_exception.dart';
import 'package:forge_and_flow/services/auth/account_info_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';
import 'package:forge_and_flow/services/auth/password_change_gateway.dart';
import 'package:forge_and_flow/services/auth/password_reset_confirm_gateway.dart';
import 'package:forge_and_flow/services/auth/password_reset_request_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';
import 'package:forge_and_flow/services/auth/user_pii_erasure_service.dart';
import 'package:forge_and_flow/services/mfa/identity_toolkit_firebase_mfa_client.dart';
import 'package:forge_and_flow/services/mfa/mfa_operations_gateway.dart';
import 'package:forge_and_flow/services/mfa/mfa_recovery_request_gateway.dart';
// Slice A2 — corpus retrieval service (A1 domain service called from the
// new /v1/advisor/retrieve route; handler lives in the part file).
import 'package:forge_and_flow/services/corpus_retrieval_service.dart';
import 'package:forge_and_flow/utils/iana_timezones.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/pointycastle.dart' as pc;

import 'package:forge_and_flow/services/realtime/realtime_event_publisher.dart';

import '../advisor_corpus/advisor_corpus.dart'
    show CorpusManifest, defaultManifestPath;
import 'audit_chain_anchors_routes.dart';
import 'admin_default_role_catalog_routes.dart';
import 'auth_handoff_routes.dart';
import 'auth_step_up_gate.dart';
import 'auth_step_up_routes.dart';
import 'health_operation_budget.dart';
import 'log.dart';
import 'business_scope_routes.dart';
// AI Metrics — append-only cap-refusal event recorder (write path for
// `public.usage_cap_events`; SQL + business_date derivation live here so
// the monolith only carries the minimal best-effort call at the refusal
// site). See `cap_event_recorder_part.dart`.
import 'cap_event_recorder_part.dart' show CapEventRecorder;
import 'connector_backfill_jobs_routes.dart';
import 'demo_mode_master_switch_routes.dart';
import 'mobile_push_notifications.dart';
import 'notification_preferences_routes.dart';
import 'admin_business_timing_routes.dart';
import 'operator_routes.dart';
import 'wage_role_rows_routes.dart';
import 'proxy_idempotency_cache.dart';
import 'realtime_route.dart'
    show handleRealtimeUpgrade, RealtimeReplayFetcher, realtimeSubscribePath;
// Slice A11.1 — proxy-side import path for the SessionRecord
// completeness predicate. The re-export keeps the proxy hot path from
// reaching into `tool/pressure/` directly.
import 'session_record_predicate.dart';
import 'star_target_routes.dart';
import 'team_users_edit_member_validation.dart'
    show validateEditMemberRouteBody;
import 'auth_self_profile_routes.dart'
    show SelfProfileRouter, authSelfProfilePath, authSelfProfilePermissionKey;
import 'org_unit_rename_route.dart' show OrgUnitRenameRouter;
import 'auth_operations_route_paths.dart'
    show canonicalAuthOperationPath, AuthOperationPathTranslationEntry;
import 'vendor_lifecycle_recently_available_routes.dart';
import 'weekly_plan_routes.dart';
// Slice A4.1 — tool-use Anthropic gateway types for the agentic answer
// engine (advisor_agentic_answer_part.dart). Standalone, import-
// independent file; this single import is the only monolith growth A4.1
// adds besides the `part` declaration below.
import 'anthropic_tool_use_complete_fn.dart';
export 'package:forge_and_flow/services/observability/dependency_timeout_exception.dart'
    show DependencyTimeoutException;
// Slice A2b — server-side query embedding gateway types exported so
// proxy_bootstrap.dart and main.dart can construct the production gateway
// by importing advisor_proxy.dart only (no extra import of the sibling file).
export 'advisor_query_embedding_gateway_part.dart'
    show
        AdvisorQueryEmbeddingGateway,
        AdvisorQueryEmbeddingException,
        AdvisorQueryEmbeddingResult,
        VoyageHttpQueryEmbeddingGateway;
// Slice A3 ? server-side Voyage rerank gateway types exported so
// proxy_bootstrap.dart and main.dart can construct the production gateway
// by importing advisor_proxy.dart only (no extra import of the sibling file).
export 'advisor_rerank_gateway_part.dart'
    show
        AdvisorRerankGateway,
        AdvisorRerankException,
        AdvisorRerankResult,
        VoyageHttpRerankGateway;
// Slice A4.2b — the abstract advisor-conversation CMK resolver type, exported
// so proxy_bootstrap.dart + main.dart can type the field / param that carries
// the concrete ProxyAdvisorConversationCmkResolver by importing
// advisor_proxy.dart only (mirrors the A2b/A3 gateway re-export above). The
// encryptor + key-length error stay encapsulated in the part file.
export 'package:forge_and_flow/infrastructure/crypto/advisor_conversation_envelope.dart'
    show AdvisorConversationCmkResolver;
export 'log.dart'
    show
        LogSeverity,
        ProxyLogContext,
        correlationIdHeaderName,
        currentProxyLogContext,
        generateUuidV4,
        isValidUuidV4,
        log,
        withProxyLogContext;
export 'proxy_idempotency_cache.dart' show ProxyAuthIdempotencyCache;
export 'operator_routes.dart'
    show
        OperatorWriteRouter,
        OperatorBusinessTimingMutationListener,
        OperatorAccountWriteGateway,
        OperatorBusinessTimingWriteGateway,
        OperatorWriteAuditSink,
        OperatorWriteIdempotencyCache,
        OperatorAccountRecord,
        OperatorBusinessTimingProfileRecord,
        OperatorBusinessTimingServicePeriodRecord,
        OperatorBusinessTimingResolutionCandidate,
        OperatorBusinessTimingResolutionResult,
        OperatorWriteRejected,
        kOperatorWriteRoles,
        operatorAccountPatchPath,
        operatorBusinessTimingProfilesPath,
        operatorBusinessTimingProfilePrefix,
        operatorLocationBusinessTimingResolutionPrefix,
        operatorLocationBusinessTimingResolutionSuffix,
        operatorLocationBusinessTimingResolutionIdOf,
        isOperatorLocationBusinessTimingResolutionPath,
        hashOperatorRequestBody,
        readOperatorJsonBody;
export 'admin_business_timing_routes.dart'
    show
        AdminBusinessTimingRouter,
        adminBusinessTimingProfilesPathPrefix,
        adminBusinessTimingResolutionScopeOf,
        isAdminBusinessTimingResolutionPath,
        kAdminBusinessTimingRoles;
export 'notification_preferences_routes.dart'
    show
        NotificationPreferencesRouter,
        NotificationPreferencesGateway,
        NotificationPreferencesIdempotencyCache,
        NotificationPreferenceRouteRejected,
        RepositoryNotificationPreferencesGateway,
        notificationPreferencesPath,
        notificationPreferencesPrefix,
        hashNotificationPreferencesRequest;
export 'demo_mode_master_switch_routes.dart'
    show
        DemoModeMasterSwitchGateway,
        DemoModeMasterSwitchMatch,
        DemoModeMasterSwitchRejected,
        DemoModeMasterSwitchRouter,
        RepositoryDemoModeMasterSwitchGateway;
export 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/demo_mode_state_repository.dart'
    show DemoModeMasterSwitchResult;
export 'wage_role_rows_routes.dart'
    show
        WageRoleRowsRouter,
        WageRoleRowsGateway,
        RepositoryWageRoleRowsGateway,
        WageRoleRowsIdempotencyCache,
        WageRoleRowsRouteRejected,
        WageRoleRowsAuditSink,
        NoopWageRoleRowsAuditSink,
        wageRoleRowsPath,
        wageRoleRowsPrefix,
        hashWageRoleRowsRequest;
export 'business_scope_routes.dart'
    show
        BusinessScopeProxyGateway,
        BusinessScopeProxyRow,
        BusinessScopeRouteMatch,
        BusinessScopeRouteResult,
        BusinessScopeRouter,
        businessScopesOperatorsPrefix,
        businessScopesResource,
        businessScopesUsersPrefix;
export 'audit_chain_anchors_routes.dart'
    show
        AdminAuditChainAnchorsGateway,
        AdminAuditChainAnchorsRouter,
        AuditChainAnchorRow,
        AuditChainAnchorStatus,
        AuditChainAnchorsGateway,
        AuditChainAnchorsRouteMatch,
        AuditChainAnchorsRouteResult,
        AuditChainAnchorsRouter,
        adminAuditChainAnchorsOperatorIdOf,
        adminAuditChainAnchorsPathPrefix,
        auditChainAnchorStatusWire,
        classifyAnchorStatus,
        isAdminAuditChainAnchorsPath,
        kAdminAuditChainAnchorRoles,
        operatorAuditChainAnchorsLatestPath;
export 'star_target_routes.dart'
    show
        RepositorySelectedStarTargetGateway,
        SelectedStarTargetGateway,
        SelectedStarTargetRouteAction,
        SelectedStarTargetRouteMatch,
        SelectedStarTargetRouteResult,
        SelectedStarTargetRouteResource,
        SelectedStarTargetRouter,
        activeTargetProfilesResource,
        selectedStarShiftDecisionsResource,
        selectedStarWritePermissionKey,
        targetCyclesResource,
        targetProfileVersionsResource;
export 'vendor_lifecycle_recently_available_routes.dart'
    show
        OperatorRecentlyAvailableVendor,
        OperatorRecentlyAvailableVendorDisplayNameResolver,
        OperatorRecentlyAvailableVendorRow,
        OperatorRecentlyAvailableVendorsGateway,
        OperatorVendorLifecycleRecentlyAvailableRouteResult,
        OperatorVendorLifecycleRecentlyAvailableRouter,
        kOperatorVendorLifecycleRecentlyAvailableDefaultWindow,
        kOperatorVendorLifecycleRecentlyAvailableMaxWindow,
        kOperatorVendorLifecycleRecentlyAvailableReadRoles,
        operatorVendorLifecycleRecentlyAvailablePath;
export 'weekly_plan_routes.dart'
    show
        ForecastContextPayload,
        ForecastContextRow,
        WeeklyPlanDayDaypartPayload,
        WeeklyPlanDayPayload,
        WeeklyPlanGateway,
        WeeklyPlanLockRequest,
        WeeklyPlanRouteAction,
        WeeklyPlanRouteMatch,
        WeeklyPlanRouteResource,
        WeeklyPlanRouteResult,
        WeeklyPlanRouter,
        WeeklyPlanSnapshotRow,
        forecastContextsResource,
        weeklyPlanLockPermissionKey,
        weeklyPlanSnapshotsResource;
// Lane B B11.1 — auth handoff (mobile→web) mint + redeem routes.
// The opaque code travels in the response body of the mint endpoint
// and the request body of the redeem endpoint — never as a URL
// parameter to the proxy. See addendum A1 in
// `docs/archive/_execution/lane_b_features/01_product_rule_and_ia.md`.
export 'auth_handoff_routes.dart'
    show
        AuthHandoffRouteRejected,
        AuthHandoffRouter,
        HandoffAuditSink,
        HandoffCodesGateway,
        HandoffMintIdempotencyCache,
        NoopHandoffAuditSink,
        ProductionHandoffAuditSink,
        RepositoryHandoffCodesGateway,
        authHandoffCodesMintPath,
        authHandoffRedeemPath,
        hashAuthHandoffRequest;
// Lane B B11.2.b — RFC 9470 step-up challenge wiring + production
// binding. Re-export the surface the proxy bootstrap + tests need to
// reference. The router lookup (`StepUpChallengeRouter.dispatch`) is
// called once per request inside `routeRequest` BEFORE any sensitive
// handler runs (see the step-up gate just below the scope-resolution
// helper). The `Step-Up-Challenge-Id` header is the ONLY token-bearing
// path; the value is NEVER read from URL parameters per addendum A1.
export 'auth_step_up_routes.dart'
    show
        NoopStepUpAuditSink,
        ProductionStepUpAuditSink,
        RepositoryStepUpChallengesGateway,
        StepUpAuditSink,
        StepUpChallengeRouter,
        StepUpChallengesGateway,
        StepUpDispatchAdmit,
        StepUpDispatchChallenge,
        StepUpDispatchReject,
        StepUpDispatchResult,
        StepUpPolicy,
        StepUpRouteSpec,
        buildWwwAuthenticateHeader,
        hashStepUpChallengeIdForAudit,
        kStepUpChallengeIdHeader,
        kStepUpErrorCode,
        kStepUpSensitiveRoutes,
        kStepUpWwwAuthenticateHeader,
        lookupStepUpRoute;
// Lane B B2.1 — default role catalog admin routes. The catalog is a
// global F&F-wide table (no operator_id); the publish route gates on
// super_admin only and emits a hash-chained audit row with the
// blast-radius operator count.
export 'admin_default_role_catalog_routes.dart'
    show
        DefaultRoleCatalogAdminRouter,
        DefaultRoleCatalogAuditSink,
        DefaultRoleCatalogRouteResult,
        NoopDefaultRoleCatalogAuditSink,
        ProductionDefaultRoleCatalogAuditSink,
        RecordingDefaultRoleCatalogAuditSink,
        canonicalRoleCatalogJson,
        computeRoleCatalogPayloadSha256,
        kAdminDefaultRoleCatalogsPath,
        kAdminDefaultRoleCatalogPublishPath,
        kDefaultRoleCatalogAdminReadRoles,
        kDefaultRoleCatalogAdminWriteRoles;

// Advisor Knowledge Activation — Slice A2b: server-side query embedding
// gateway. Standalone file (not a `part`) so its own imports (dart:io,
// dart:convert, package:http) do not land in the monolith's import space.
// Import precedes `part` directives as required by Dart spec.
// `VoyageHttpQueryEmbeddingGateway` is re-exported below (for
// proxy_bootstrap / main.dart) but NOT imported here — it is not used
// inside the monolith or its `part` files; the abstract interface and
// exception are the only types needed by the part.
import 'advisor_query_embedding_gateway_part.dart'
    show
        AdvisorQueryEmbeddingGateway,
        AdvisorQueryEmbeddingException,
        AdvisorQueryEmbeddingResult;

// Advisor Knowledge Activation ? Slice A3: server-side Voyage rerank
// gateway. Standalone file (not a `part`) so its own imports (dart:io,
// dart:convert, package:http, the rerank domain types) do not land in the
// monolith's import space. `VoyageHttpRerankGateway` is re-exported above
// (for proxy_bootstrap / main.dart) but NOT imported here ? it is not used
// inside the monolith or its `part` files; the abstract interface,
// exception, and result type are the only types the retrieve route needs,
// plus `RerankCandidate` to build the candidate pool from chunks.
import 'advisor_rerank_gateway_part.dart'
    show AdvisorRerankGateway, AdvisorRerankException, AdvisorRerankResult;

// chore(advisor-proxy) size refactor: cohesive admin route group
// (corpus / debug-console / observability / feature-flags /
// graph-candidates) lives in this part file. `part` shares this
// library's imports + private scope verbatim, so the move is
// behavior byte-identical (no routing/shape/status/idempotency/RLS/
// auth/SQL change). See `tool/advisor_proxy_size_lint.dart`.
part 'admin_route_group_part.dart';
// Advisor Knowledge Activation — Slice A2: POST /v1/advisor/retrieve.
// All handler logic lives in this sibling part file; monolith gets only
// this declaration + a minimal path-match dispatch in routeRequest.
part 'advisor_retrieve_route_group_part.dart';

// chore(advisor-proxy) size refactor: JWT verification interface + operator
// scope + request guard live in this part file. `part` shares this
// library's imports + private scope verbatim, so the move is
// behavior byte-identical (no routing/shape/status/idempotency/RLS/
// auth/SQL change). See `tool/advisor_proxy_size_lint.dart`.
part 'jwt_verifier_part.dart';

// chore(advisor-proxy) size refactor: health check infrastructure +
// migration apply registry writer live in this part file. `part` shares
// this library's imports + private scope verbatim, so the move is
// behavior byte-identical. See `tool/advisor_proxy_size_lint.dart`.
part 'health_registry_part.dart';

// Advisor Knowledge Activation — Slice A4.1: AdvisorAgenticAnswerEngine.
// All engine logic lives in this sibling part file; the monolith adds
// only this declaration + the `anthropic_tool_use_complete_fn.dart`
// import above. NO route, NO routeRequest dispatch, NO bootstrap wiring
// (all A4.2). No `kAdvisorProxyMaxLines` raise.
part 'advisor_agentic_answer_part.dart';

// Advisor Knowledge Activation — Slice A4.6: operational read tools
// (get_active_targets / get_week_plan / get_shift_variance). All tool
// definitions + handlers + the OperatorContext-bound factory live in
// this sibling part file. INERT: NO route, NO routeRequest dispatch, NO
// bootstrap wiring (all A4.2). The monolith gains only this declaration
// + the three repository imports above. No `kAdvisorProxyMaxLines` raise.
part 'advisor_operational_tools_part.dart';

// Advisor Knowledge Activation — Slice A4.2a: the `retrieve_methodology`
// answer tool + the shared embed→search→rerank pipeline helper it wraps
// (the helper itself lives in advisor_retrieve_route_group_part.dart,
// factored out of the retrieve route behavior-preservingly). The tool
// definition + its OperatorContext/gateway-bound factory live in this
// sibling part file. INERT: NO route, NO routeRequest dispatch, NO
// bootstrap wiring (all A4.2b). The monolith gains only this declaration.
// No `kAdvisorProxyMaxLines` raise.
part 'advisor_answer_tools_part.dart';

// Advisor Knowledge Activation — Slice A4.2b: the ACTIVATING POST
// /v1/advisor/answer route. All handler logic (body parse, fail-closed
// encryption gate, cap-check, tier→model, tool catalog assembly, engine run,
// encrypted user+assistant writes, HP #9 metering, success envelope) lives in
// this sibling part file. The monolith gains only this declaration, one
// `routeRequest` dispatch block, and a few optional `routeRequest` params.
// No `kAdvisorProxyMaxLines` raise.
part 'advisor_answer_route_group_part.dart';

/// Default in-memory idempotency cache shared by the password
/// change / reset request / reset confirm routes when the route
/// caller does not inject one. Production bootstrap can override
/// via the `authIdempotencyCache` parameter.
final ProxyAuthIdempotencyCache _defaultAuthIdempotencyCache =
    ProxyAuthIdempotencyCache();

// ─── Secret name registry ────────────────────────────────────────────────────
//
// Names only. Values live in Cloud Run env / Secret Manager and are
// loaded at process start by [ProxyConfig.fromEnvironment]. Nothing in
// the scaffold prints, returns, or echoes the values themselves.

abstract class ProxySecretNames {
  ProxySecretNames._();

  /// Anthropic API key for Claude tier dispatch (quick / nuanced).
  static const String anthropicApiKey = 'ANTHROPIC_API_KEY';

  /// Voyage API key for embeddings + rerank.
  static const String voyageApiKey = 'VOYAGE_API_KEY';

  /// Application-role Postgres connection string. The proxy uses this
  /// for per-operator reads / writes that must respect RLS once Phase
  /// 9 enforcement turns on. Generic libpq-format URI; works against
  /// Azure Database for PostgreSQL Flexible Server, a local
  /// Docker-Compose dev container, or any other PG host.
  static const String postgresUrl = 'POSTGRES_URL';

  /// Admin / deployment-role Postgres connection string. Used by the
  /// proxy to bypass RLS for admin-scoped writes (counter increments,
  /// idempotency upserts, cap reads) and by deployment runners to
  /// apply migrations. Per-operator reads still go through
  /// `postgresUrl` so RLS protects them.
  static const String postgresAdminUrl = 'POSTGRES_ADMIN_URL';

  /// Firebase Web API key used by Identity Toolkit password
  /// verification and account sign-up endpoints. This is server-side
  /// config for the proxy; clients continue to talk only to Firebase
  /// SDK / proxy surfaces, never to the Admin choreography directly.
  static const String firebaseWebApiKey = 'FIREBASE_WEB_API_KEY';

  /// HMAC signing secret for short-lived `sp:` service-principal JWTs.
  /// Only the proxy holds this value; Flutter clients receive issued
  /// tokens, never the signing key.
  static const String servicePrincipalJwtSecret =
      'SERVICE_PRINCIPAL_JWT_SECRET';

  /// Phase 11A.4b — Gemini API key for the fallback LLM lane. Server-side
  /// only (Hard Promise #7). Optional: when absent, the AdvisorRequestPipeline's
  /// secondary slot is null and the pipeline falls through directly to
  /// cache → refusal on Anthropic failure.
  static const String geminiApiKey = 'GEMINI_API_KEY';

  /// Server-side envelope key for encrypting mobile FCM/APNs device
  /// tokens before persistence. Optional at boot; routes fail closed
  /// with a 503 when the production binding cannot install the gateway.
  static const String mobilePushTokenEnvelopeKey =
      'MOBILE_PUSH_TOKEN_ENVELOPE_KEY';

  /// Slice A4-ENC — server-side AES-256 data key (base64-encoded
  /// 32 bytes) used to encrypt advisor conversation turns IN-PROCESS
  /// before they are persisted, so the database never sees plaintext
  /// (Hard Promise #7). OPTIONAL at boot: the proxy keeps starting
  /// without it. Gated-inert until the advisor answer endpoint (A4.2)
  /// constructs the `AdvisorConversationEnvelope` encryptor; that
  /// endpoint fails closed (no key → no answer) when this secret is
  /// absent. Resolved through
  /// [ProxyAdvisorConversationCmkResolver.tryCreate] to the stable
  /// `kv://forge-flow/cmk/v1` content_key_ref.
  static const String advisorConversationCmk = 'ADVISOR_CONVERSATION_CMK';

  /// Phase 8 framework — pgcrypto symmetric envelope key used by
  /// `pgp_sym_encrypt` / `pgp_sym_decrypt` calls in the
  /// `vendor_credentials` table and the inbound webhook gateway. The
  /// key never leaves the proxy process; ciphertext at rest is the
  /// stored form. Required by every vendor adapter / connector binder
  /// that reads or writes a vendor OAuth handle.
  static const String pgcryptoEnvelopeKey = 'PGCRYPTO_ENVELOPE_KEY';

  /// Phase 8 framework — Aloha NCR Voyix OAuth `client_id` for the
  /// app-wide `client_credentials` registration. Static across
  /// operators; per-(operator, location) refresh handles still resolve
  /// through the vendor-credentials repository.
  static const String alohaNcrVoyixClientId = 'ALOHA_NCR_VOYIX_CLIENT_ID';

  /// Phase 8 framework — Aloha NCR Voyix OAuth `client_secret`
  /// matching [alohaNcrVoyixClientId].
  static const String alohaNcrVoyixClientSecret =
      'ALOHA_NCR_VOYIX_CLIENT_SECRET';

  /// Phase 8 framework — NCR Voyix application key
  /// (`nep-application-key` header). Static per F&F developer
  /// registration.
  static const String alohaNcrVoyixApplicationKey =
      'ALOHA_NCR_VOYIX_APPLICATION_KEY';

  /// Phase 8 framework — NCR Voyix organization id
  /// (`nep-organization` header). Static per F&F developer
  /// registration.
  static const String alohaNcrVoyixOrganizationId =
      'ALOHA_NCR_VOYIX_ORGANIZATION_ID';

  /// Phase 8 framework — Square OAuth `client_id` (Square Application
  /// ID) for the F&F application registration. Required by the
  /// `/oauth2/token` refresh + `/oauth2/revoke` paths.
  static const String squareClientId = 'SQUARE_CLIENT_ID';

  /// Phase 8 framework — Square OAuth `client_secret` matching
  /// [squareClientId].
  static const String squareClientSecret = 'SQUARE_CLIENT_SECRET';

  /// Phase 8 framework — Square notification URL host the proxy
  /// stamps onto inbound webhook requests via the
  /// `x-ff-notification-url` header. Square signs webhook bodies
  /// against the registered URL; the verifier rejects mismatches.
  static const String squareNotificationUrlHost =
      'SQUARE_NOTIFICATION_URL_HOST';

  /// Phase 8 framework — Clover app-level OAuth bearer used to manage
  /// app-scoped resources (the webhook subscription endpoint sits
  /// under `/v3/apps/{aId}/webhooks`). Static; tenant-scoped merchant
  /// tokens still resolve through `vendor_credentials`.
  static const String cloverAppToken = 'CLOVER_APP_TOKEN';

  /// Phase 8 framework — Clover app id used in
  /// `/v3/apps/{aId}/webhooks` paths. Static across operators.
  static const String cloverAppId = 'CLOVER_APP_ID';

  /// Phase 8 framework — Humanity OAuth `client_id` for the app-wide
  /// registration. Static across operators; per-(operator, location)
  /// refresh handles still resolve through `vendor_credentials`.
  static const String humanityClientId = 'HUMANITY_CLIENT_ID';

  /// Phase 8 framework — Humanity OAuth `client_secret` matching
  /// [humanityClientId].
  static const String humanityClientSecret = 'HUMANITY_CLIENT_SECRET';

  /// Phase 8 framework — QuickBooks Time (Intuit) OAuth `client_id`
  /// for the app-wide registration. Static across operators;
  /// per-(operator, location) refresh handles still resolve through
  /// `vendor_credentials`.
  static const String quickBooksTimeClientId = 'QUICKBOOKS_TIME_CLIENT_ID';

  /// Phase 8 framework — QuickBooks Time (Intuit) OAuth `client_secret`
  /// matching [quickBooksTimeClientId].
  static const String quickBooksTimeClientSecret =
      'QUICKBOOKS_TIME_CLIENT_SECRET';

  /// Phase 8 framework — 7shifts OAuth `client_id` for the app-wide
  /// partner registration.
  static const String sevenShiftsClientId = 'SEVEN_SHIFTS_CLIENT_ID';

  /// Phase 8 framework — 7shifts OAuth `client_secret` matching
  /// [sevenShiftsClientId].
  static const String sevenShiftsClientSecret = 'SEVEN_SHIFTS_CLIENT_SECRET';

  /// Phase 8 framework — Libro OAuth `client_id` for the app-wide
  /// registration.
  static const String libroClientId = 'LIBRO_CLIENT_ID';

  /// Phase 8 framework — Libro OAuth `client_secret` matching
  /// [libroClientId].
  static const String libroClientSecret = 'LIBRO_CLIENT_SECRET';

  /// Phase 8 framework — public base URI the proxy presents to
  /// inbound vendor webhooks (per-tenant location config resolver
  /// builds operator-scoped paths under this host). Required at boot
  /// to force operators to declare their externally-reachable host
  /// rather than silently fall through to a baked-in default; the
  /// staging deploy and the canonical production deploy both set
  /// this to their own URL. Stored as a string secret name and
  /// surfaced through the typed [ProxyConfig.publicBaseUri] getter
  /// which parses + validates the URI shape.
  static const String publicBaseUri = 'PUBLIC_BASE_URI';

  /// Required server-side secret names. The proxy refuses to start
  /// when any of these are missing or blank.
  static const List<String> required = <String>[
    anthropicApiKey,
    voyageApiKey,
    postgresUrl,
    postgresAdminUrl,
    firebaseWebApiKey,
    servicePrincipalJwtSecret,
    pgcryptoEnvelopeKey,
    publicBaseUri,
  ];

  /// Optional server-side secret names. Loaded into [ProxyConfig] when
  /// present; absence is not a startup error. Callers gate behavior on
  /// [ProxyConfig.hasSecretFor].
  ///
  /// Phase 8 framework — vendor app credentials (Aloha / Square /
  /// Clover / Humanity / QuickBooks Time / 7shifts / Libro) are loaded
  /// as optional. Each connector binder fails its own activation when
  /// the bundle is missing; the proxy still boots without them so
  /// non-POS routes (advisor, auth, weekly plan) keep working in dev /
  /// staging where a vendor isn't configured.
  static const List<String> optional = <String>[
    geminiApiKey,
    mobilePushTokenEnvelopeKey,
    advisorConversationCmk,
    alohaNcrVoyixClientId,
    alohaNcrVoyixClientSecret,
    alohaNcrVoyixApplicationKey,
    alohaNcrVoyixOrganizationId,
    squareClientId,
    squareClientSecret,
    squareNotificationUrlHost,
    cloverAppToken,
    cloverAppId,
    humanityClientId,
    humanityClientSecret,
    quickBooksTimeClientId,
    quickBooksTimeClientSecret,
    sevenShiftsClientId,
    sevenShiftsClientSecret,
    libroClientId,
    libroClientSecret,
  ];
}

// ─── Non-secret config name registry (9.1) ───────────────────────────────────
//
// Public, non-secret config values that are still loaded from env at
// process start. Kept separate from [ProxySecretNames] because these
// are safe to log by name + value (project IDs, region names, etc.).

abstract class ProxyConfigNames {
  ProxyConfigNames._();

  /// Firebase project ID for Identity Platform JWT verification (9.1).
  /// Optional at raw config-parse time so unit/scaffold contexts can still
  /// construct [ProxyConfig]. The production Phase 9 bootstrap requires this
  /// before binding a port because the live auth routes need the Firebase
  /// Admin / Identity Toolkit client.
  static const String firebaseProjectId = 'FIREBASE_PROJECT_ID';

  /// Optional Firebase Auth action continue URL. Used by the server-side
  /// password-reset sender when present.
  static const String firebaseEmailActionContinueUrl =
      'FIREBASE_EMAIL_ACTION_CONTINUE_URL';

  /// 11A.B43 — `cache_telemetry_v2` rollout flag. When `true`, the
  /// `RepositoryCorpusAdminProxyGateway` writes one row into
  /// `corpus_invalidation_events` per `commitVersion`/`rollbackToVersion`
  /// call. Default `false` for staged rollout: the migration that
  /// creates the table is unconditional, but writes only fire after the
  /// table has been observed for one drift cycle in staging.
  /// Accepted values (case-insensitive): `true`/`1`/`on` enable;
  /// anything else (including unset) keeps the flag off.
  static const String cacheTelemetryV2 = 'CACHE_TELEMETRY_V2';

  /// Phase 11A.4c — GCP project hosting the proxy + Secret Manager.
  /// Required when any `kms_real_provider_<kind>_enabled` flag is ON;
  /// optional at config-parse time so dev / test contexts that run
  /// against the stub can still boot.
  static const String gcpProjectId = 'GCP_PROJECT_ID';

  /// Phase 11A.4c — Cloud Run region (e.g. `northamerica-northeast2`).
  /// Required for the Cloud Run Admin API call that forces a new
  /// revision after a runtime-read key rotates.
  static const String cloudRunRegion = 'CLOUD_RUN_REGION';

  /// Phase 11A.4c — Cloud Run service name (e.g.
  /// `forge-flow-advisor-proxy`). The same service that's running
  /// the proxy — `CloudRunAdminClient` patches this service to bump
  /// its revision when a runtime-read API key rotates.
  static const String cloudRunServiceName = 'CLOUD_RUN_SERVICE_NAME';

  /// HARD-C — comma-split list of origins allowed to call the admin
  /// CORS-protected routes. Required in production; staged values
  /// land in Cloud Run env per the contract. Values are exact-string
  /// matches (e.g. `https://admin.forgeandflow.app`). Empty / missing
  /// in prod fails the bootstrap closed (exit 78).
  ///
  /// The supplemental "extras" allow-list is NOT an env var — it is
  /// the comma-separated description column on the
  /// `admin_cors_origins_extra` row in `public.feature_flags`,
  /// read at startup via
  /// `FeatureFlagsTableAdminCorsOriginsExtraFlag`.
  static const String adminCorsAllowedOrigins = 'ADMIN_CORS_ALLOWED_ORIGINS';

  /// Declared deployment environment. Two consumers:
  ///
  /// - HARD-C: only `dev` and `staging` (case-sensitive) trigger the
  ///   localhost CORS fallback. Any other value, including `prod`,
  ///   an empty string, or a misspelled `production` / `PRD`, fails
  ///   closed when no explicit allow-list is configured.
  /// - HARD-G observability: lower-cased value drives the startup
  ///   KMS fail-closed check (`prod` arms the gate; any other value,
  ///   including unset, is treated as non-prod).
  static const String proxyEnvironment = 'PROXY_ENVIRONMENT';

  /// HARD-G observability — startup KMS rollout master switch. When
  /// `true`/`1`/`on` (case-insensitive), the proxy expects the GCP
  /// env vars to be set so the KMS lane router can dispatch to the
  /// real provider. In prod with this flag on and any GCP var
  /// missing, the proxy fails closed at startup (exit 78). The
  /// per-lane `kms_real_provider_<kind>_enabled` feature-flag rows
  /// in Postgres still gate per-lane rollout independently; this
  /// env var is the safety interlock that prevents prod ever booting
  /// against the stub when the rollout is supposed to be live.
  static const String kmsRealProviderEnabled = 'KMS_REAL_PROVIDER_ENABLED';
}

// ─── Config ──────────────────────────────────────────────────────────────────

class ProxyConfigError implements Exception {
  ProxyConfigError(this.message, {required this.missingSecretNames});

  final String message;
  final List<String> missingSecretNames;

  @override
  String toString() => message;
}

/// HARD-G observability — startup KMS misconfiguration. Thrown when
/// `PROXY_ENVIRONMENT=prod` and `KMS_REAL_PROVIDER_ENABLED=true` but
/// any of `GCP_PROJECT_ID`, `CLOUD_RUN_REGION`, `CLOUD_RUN_SERVICE_NAME`
/// is unset. The main entry point catches this distinctly so the log
/// emits `startup.kms_misconfigured` instead of the generic
/// `startup.production_bindings_invalid` event.
class ProxyKmsMisconfiguredError extends ProxyConfigError {
  ProxyKmsMisconfiguredError({required List<String> missing})
    : super(
        'advisor proxy KMS misconfigured: PROXY_ENVIRONMENT=prod and '
        'KMS_REAL_PROVIDER_ENABLED=true but ${missing.length} GCP '
        'env var(s) are unset: ${missing.join(', ')}. Set them or '
        'flip KMS_REAL_PROVIDER_ENABLED off and redeploy.',
        missingSecretNames: List<String>.unmodifiable(missing),
      );
}

// ─── Vendor app-credential typed records (Phase 8 framework) ────────────────
//
// Static, app-wide credentials the Phase 8 connector binders read at
// startup to instantiate vendor production transports. Per-(operator,
// location) OAuth handles still resolve through `vendor_credentials`
// at request time; these records carry only the registration-level
// material the binder cannot conjure on its own.
//
// Square / Clover / Humanity / QuickBooks Time / 7shifts / Libro do
// not have transport-defined typed record classes today, so the
// records live here next to [ProxySecretNames]. Aloha reuses
// [AlohaNcrVoyixOauthClientCredentials] from the production
// transport file (binder calls [ProxyConfig.alohaNcrVoyixCredentials]
// to materialize it).

/// Phase 8 framework — Square static app credentials. The OAuth
/// client_id / client_secret are the F&F Application's registration;
/// [notificationUrlHost] is the registered webhook host the
/// Square webhook signature verifier checks against.
class SquareAppCredentials {
  const SquareAppCredentials({
    required this.clientId,
    required this.clientSecret,
    required this.notificationUrlHost,
  });

  /// OAuth `client_id` (Square Application ID).
  final String clientId;

  /// OAuth `client_secret`. Server-side only.
  final String clientSecret;

  /// Registered notification URL host. The proxy stamps this onto
  /// inbound Square webhook requests so the signature verifier can
  /// reject mismatched URLs.
  final String notificationUrlHost;
}

/// Phase 8 framework — Clover static app credentials. The
/// app-level token + app id authorize webhook subscription writes
/// under `/v3/apps/{aId}/webhooks`; tenant-scoped merchant tokens
/// still resolve through `vendor_credentials`.
class CloverAppCredentials {
  const CloverAppCredentials({required this.appToken, required this.appId});

  /// App-level OAuth bearer.
  final String appToken;

  /// Clover app id used in `/v3/apps/{aId}/webhooks` paths.
  final String appId;
}

/// Phase 8 framework — Humanity static app credentials. The OAuth
/// `client_id` / `client_secret` are the F&F application's
/// registration; per-(operator, location) refresh handles still
/// resolve through `vendor_credentials`.
class HumanityAppCredentials {
  const HumanityAppCredentials({
    required this.clientId,
    required this.clientSecret,
  });

  /// OAuth `client_id`.
  final String clientId;

  /// OAuth `client_secret`. Server-side only.
  final String clientSecret;
}

/// Phase 8 framework — QuickBooks Time (Intuit) static app
/// credentials. The OAuth `client_id` / `client_secret` are the F&F
/// application's Intuit Developer registration; per-(operator,
/// location) refresh handles still resolve through
/// `vendor_credentials`.
class QuickBooksTimeAppCredentials {
  const QuickBooksTimeAppCredentials({
    required this.clientId,
    required this.clientSecret,
  });

  /// OAuth `client_id` (Intuit Application ID).
  final String clientId;

  /// OAuth `client_secret`. Server-side only.
  final String clientSecret;
}

/// Phase 8 framework — 7shifts static app credentials. The OAuth
/// `client_id` / `client_secret` are the F&F partner registration;
/// per-(operator, location) refresh handles still resolve through
/// `vendor_credentials`.
class SevenShiftsAppCredentials {
  const SevenShiftsAppCredentials({
    required this.clientId,
    required this.clientSecret,
  });

  /// OAuth `client_id`.
  final String clientId;

  /// OAuth `client_secret`. Server-side only.
  final String clientSecret;
}

/// Phase 8 framework — Libro static app credentials. The OAuth
/// `client_id` / `client_secret` are the F&F application's
/// registration; per-(operator, location) bearer tokens still
/// resolve through `vendor_credentials`.
class LibroAppCredentials {
  const LibroAppCredentials({
    required this.clientId,
    required this.clientSecret,
  });

  /// OAuth `client_id`.
  final String clientId;

  /// OAuth `client_secret`. Server-side only.
  final String clientSecret;
}

class ProxyConfig {
  ProxyConfig._({
    required this.port,
    required Map<String, String> secrets,
    required this.firebaseProjectId,
    required this.firebaseEmailActionContinueUrl,
    required this.cacheTelemetryV2,
    required this.gcpProjectId,
    required this.cloudRunRegion,
    required this.cloudRunServiceName,
    required List<String> adminCorsAllowedOriginsFromEnv,
    required this.proxyEnvironment,
    required this.kmsRealProviderEnabled,
  }) : _secrets = Map<String, String>.unmodifiable(secrets),
       adminCorsAllowedOriginsFromEnv = List<String>.unmodifiable(
         adminCorsAllowedOriginsFromEnv,
       );

  /// HTTP listen port. Cloud Run injects `PORT`; defaults to 8080.
  final int port;

  /// Firebase Identity Platform project ID (9.1). Optional at config-load
  /// time for tests and scaffold-only callers. The production proxy bootstrap
  /// rejects null / blank before exposing Phase 9 auth routes; non-null lets
  /// [FirebaseProxyJwtVerifier] validate the `iss`
  /// (`https://securetoken.google.com/<id>`) and `aud` (`<id>`) claims on
  /// every Firebase ID token.
  final String? firebaseProjectId;

  /// Optional action URL used by Identity Toolkit email actions.
  final String? firebaseEmailActionContinueUrl;

  /// 11A.B43 — staged rollout flag for `corpus_invalidation_events`
  /// telemetry writes. Wired from [ProxyConfigNames.cacheTelemetryV2].
  /// `false` until the table is observed for one drift cycle in staging.
  final bool cacheTelemetryV2;

  /// Phase 11A.4c — GCP project hosting Cloud Run + Secret Manager.
  /// Optional at parse time so dev contexts boot; production bootstrap
  /// requires it when any `kms_real_provider_*_enabled` flag is ON.
  final String? gcpProjectId;

  /// Phase 11A.4c — Cloud Run region (e.g. `northamerica-northeast2`).
  final String? cloudRunRegion;

  /// Phase 11A.4c — Cloud Run service name. The same service that's
  /// running this proxy.
  final String? cloudRunServiceName;

  /// HARD-C — admin CORS allow-list parsed from
  /// [ProxyConfigNames.adminCorsAllowedOrigins] (comma-split, trimmed,
  /// empty entries dropped). The bootstrap-time resolver
  /// (`resolveAdminCorsAllowList`) layers feature-flag extras
  /// (sourced from the `admin_cors_origins_extra` row in
  /// `public.feature_flags`) and a dev/staging localhost fallback on
  /// top; this field is the env-only slice. Empty list when the env
  /// var is unset or blank.
  final List<String> adminCorsAllowedOriginsFromEnv;

  /// Declared deployment environment. Trimmed lowercase string from
  /// [ProxyConfigNames.proxyEnvironment], or null when unset.
  ///
  /// - HARD-C resolver: `prod` is production (fail-closed on empty
  ///   admin CORS allow-list); any other value is non-prod
  ///   (localhost is added to the allow-list for ergonomic dev /
  ///   staging access).
  /// - HARD-G observability: `prod` arms the startup KMS
  ///   fail-closed gate; any other value (including unset) is
  ///   treated as non-prod.
  final String? proxyEnvironment;

  /// HARD-G observability — `KMS_REAL_PROVIDER_ENABLED` env-var flag.
  /// `true` arms the prod fail-closed gate; combined with
  /// [proxyEnvironment] == `prod` and any unset GCP var, the proxy
  /// exits 78 at startup.
  final bool kmsRealProviderEnabled;

  /// Loaded secret values keyed by [ProxySecretNames] entries. Stored
  /// privately so external code can only retrieve a value via the
  /// explicit [secretFor] accessor — no `toString`, no JSON, no
  /// iteration over values.
  final Map<String, String> _secrets;

  /// Loads config from a server environment map. Returns when every
  /// name in [ProxySecretNames.required] resolves to a non-blank value.
  /// Throws [ProxyConfigError] otherwise — the exception carries the
  /// missing names but never any captured values.
  ///
  /// `FIREBASE_PROJECT_ID` is loaded as an optional non-secret config
  /// value here. Production route binding validation happens in
  /// `buildProxyProductionBindings`, which requires it before live auth
  /// routes are exposed.
  factory ProxyConfig.fromEnvironment(Map<String, String> environment) {
    final missing = <String>[];
    final loaded = <String, String>{};
    for (final name in ProxySecretNames.required) {
      final value = environment[name];
      if (value == null || value.trim().isEmpty) {
        missing.add(name);
      } else {
        loaded[name] = value;
      }
    }
    if (missing.isNotEmpty) {
      throw ProxyConfigError(
        'advisor proxy missing ${missing.length} required server '
        'secret(s) by name: ${missing.join(', ')}. '
        'Set the values in Cloud Run env / Secret Manager and redeploy.',
        missingSecretNames: List<String>.unmodifiable(missing),
      );
    }
    // Phase 11A.4b — optional secrets: load when present, never raise on
    // absence. GEMINI_API_KEY enables the fallback Gemini secondary in
    // the AdvisorRequestPipeline; without it the secondary slot is null
    // and the pipeline falls through directly to cache → refusal.
    for (final name in ProxySecretNames.optional) {
      final value = environment[name];
      if (value != null && value.trim().isNotEmpty) {
        loaded[name] = value;
      }
    }
    final port = _parsePort(environment['PORT']);
    final firebaseProjectIdRaw =
        environment[ProxyConfigNames.firebaseProjectId];
    final firebaseProjectId =
        (firebaseProjectIdRaw == null || firebaseProjectIdRaw.trim().isEmpty)
        ? null
        : firebaseProjectIdRaw.trim();
    final firebaseActionUrlRaw =
        environment[ProxyConfigNames.firebaseEmailActionContinueUrl];
    final firebaseEmailActionContinueUrl =
        (firebaseActionUrlRaw == null || firebaseActionUrlRaw.trim().isEmpty)
        ? null
        : firebaseActionUrlRaw.trim();
    final cacheTelemetryV2 = _parseBoolFlag(
      environment[ProxyConfigNames.cacheTelemetryV2],
    );
    String? trimmedOrNull(String? raw) =>
        (raw == null || raw.trim().isEmpty) ? null : raw.trim();
    final gcpProjectIdValue = trimmedOrNull(
      environment[ProxyConfigNames.gcpProjectId],
    );
    final cloudRunRegionValue = trimmedOrNull(
      environment[ProxyConfigNames.cloudRunRegion],
    );
    final cloudRunServiceNameValue = trimmedOrNull(
      environment[ProxyConfigNames.cloudRunServiceName],
    );

    final proxyEnvironmentValue = trimmedOrNull(
      environment[ProxyConfigNames.proxyEnvironment],
    )?.toLowerCase();
    final kmsRealProviderEnabled = _parseBoolFlag(
      environment[ProxyConfigNames.kmsRealProviderEnabled],
    );

    // Phase 11A.4c — GCP / Cloud Run config is all-or-nothing.
    // Setting `GCP_PROJECT_ID` alone would enable real Secret Manager
    // writes via the KMS lane router while leaving the Cloud Run
    // admin client as a no-op — runtime-read rotations (anthropic /
    // voyage / gemini) would land in Secret Manager but never trigger
    // an instance restart, and the audit row would carry a synthetic
    // `no-op-cloud-run:...` operation name. Fail closed at startup
    // instead.
    final gcpVarsPresent = <bool>[
      gcpProjectIdValue != null,
      cloudRunRegionValue != null,
      cloudRunServiceNameValue != null,
    ];
    final anyPresent = gcpVarsPresent.contains(true);
    final allPresent = !gcpVarsPresent.contains(false);
    final missingNames = <String>[
      if (gcpProjectIdValue == null) ProxyConfigNames.gcpProjectId,
      if (cloudRunRegionValue == null) ProxyConfigNames.cloudRunRegion,
      if (cloudRunServiceNameValue == null)
        ProxyConfigNames.cloudRunServiceName,
    ];
    final isProd = proxyEnvironmentValue == 'prod';
    // HARD-G observability: prod + flag-on with ANY missing GCP var
    // (partial OR all-missing) maps to startup.kms_misconfigured. The
    // contract requires this distinct event whenever the rollout is
    // armed in prod but the GCP wiring is incomplete.
    if (isProd && kmsRealProviderEnabled && !allPresent) {
      log(
        LogSeverity.error,
        'startup.kms_misconfigured',
        fields: <String, Object?>{
          'missing': missingNames,
          'environment': proxyEnvironmentValue,
        },
      );
      throw ProxyKmsMisconfiguredError(missing: missingNames);
    }
    if (anyPresent && !allPresent) {
      throw ProxyConfigError(
        'advisor proxy GCP / Cloud Run config is partial: '
        '${missingNames.length} missing name(s): ${missingNames.join(', ')}. '
        'All three of ${ProxyConfigNames.gcpProjectId}, '
        '${ProxyConfigNames.cloudRunRegion}, and '
        '${ProxyConfigNames.cloudRunServiceName} must be set together '
        '(real Phase 11A.4c KMS rollout) or all unset (dev / scaffold). '
        'Setting only a subset would cause runtime-read key rotations '
        'to land in Secret Manager without restarting Cloud Run '
        'instances, and the audit log would record synthetic '
        'no-op operation names instead of real ones.',
        missingSecretNames: List<String>.unmodifiable(missingNames),
      );
    }

    final adminCorsRaw = environment[ProxyConfigNames.adminCorsAllowedOrigins];
    final adminCorsList = _parseCsvOrigins(adminCorsRaw);
    // `proxyEnvironmentValue` was resolved earlier (above) for the
    // HARD-G KMS gate; it is reused here so HARD-C and HARD-G see the
    // same lower-cased environment tag.

    return ProxyConfig._(
      port: port,
      secrets: loaded,
      firebaseProjectId: firebaseProjectId,
      firebaseEmailActionContinueUrl: firebaseEmailActionContinueUrl,
      cacheTelemetryV2: cacheTelemetryV2,
      gcpProjectId: gcpProjectIdValue,
      cloudRunRegion: cloudRunRegionValue,
      cloudRunServiceName: cloudRunServiceNameValue,
      adminCorsAllowedOriginsFromEnv: adminCorsList,
      proxyEnvironment: proxyEnvironmentValue,
      kmsRealProviderEnabled: kmsRealProviderEnabled,
    );
  }

  // Permissive boolean parser for env-var rollout flags. `true`/`1`/`on`
  // (case-insensitive) enable; anything else — including null, blank,
  // or unrecognised — keeps the flag off. Mirrors the staged-rollout
  // posture from scalability decisions: a flag must default off until a
  // human flips it.
  static bool _parseBoolFlag(String? raw) {
    if (raw == null) return false;
    final trimmed = raw.trim().toLowerCase();
    return trimmed == 'true' || trimmed == '1' || trimmed == 'on';
  }

  /// HARD-C — parse a comma-separated CORS origin list from an env
  /// var. Trims each entry; drops empty results. Returns an empty
  /// list when [raw] is null or contains only whitespace / commas.
  static List<String> _parseCsvOrigins(String? raw) {
    if (raw == null) return const <String>[];
    final out = <String>[];
    for (final part in raw.split(',')) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      out.add(trimmed);
    }
    return out;
  }

  static int _parsePort(String? raw) {
    if (raw == null || raw.trim().isEmpty) return 8080;
    final value = int.tryParse(raw.trim());
    if (value == null || value <= 0 || value > 65535) {
      return 8080;
    }
    return value;
  }

  /// Returns the secret value for [name]. Callers must NEVER log,
  /// echo, or otherwise leak the returned value. Used by future
  /// provider-call slices to attach the right key to outbound HTTPS
  /// requests; the value never leaves this process.
  String secretFor(String name) {
    final value = _secrets[name];
    if (value == null) {
      throw StateError(
        'advisor proxy: secret "$name" is not loaded. '
        'Add it to ProxySecretNames.required and the Cloud Run env.',
      );
    }
    return value;
  }

  /// True when the named secret is loaded. Does not return the value.
  bool hasSecretFor(String name) => _secrets.containsKey(name);

  /// Phase 8 framework — pgcrypto symmetric envelope key used for
  /// `pgp_sym_encrypt` / `pgp_sym_decrypt` calls against the
  /// `vendor_credentials` table. Throws [StateError] when
  /// [ProxySecretNames.pgcryptoEnvelopeKey] is not loaded; the proxy
  /// boot now requires the key, so this only fires from tests that
  /// build a partial environment.
  String get pgcryptoEnvelopeKey =>
      secretFor(ProxySecretNames.pgcryptoEnvelopeKey);

  /// Phase 8 framework — Aloha NCR Voyix static app credentials,
  /// reusing the transport-defined record so the binder can pass the
  /// result straight into [AlohaNcrVoyixPosProductionApiClient]. Throws
  /// [StateError] when any of the four secret names is unloaded.
  ///
  /// `scope` and `baseUriOverride` are intentionally null here — the
  /// production transport falls back to its baked-in default OAuth
  /// scope and base URI; per-connection on-prem relay overrides ride
  /// through `vendor_credentials` per request, not through this static
  /// bundle.
  AlohaNcrVoyixOauthClientCredentials get alohaNcrVoyixCredentials =>
      AlohaNcrVoyixOauthClientCredentials(
        clientId: secretFor(ProxySecretNames.alohaNcrVoyixClientId),
        clientSecret: secretFor(ProxySecretNames.alohaNcrVoyixClientSecret),
        applicationKey: secretFor(ProxySecretNames.alohaNcrVoyixApplicationKey),
        organizationId: secretFor(ProxySecretNames.alohaNcrVoyixOrganizationId),
      );

  /// Phase 8 framework — Square static app credentials. Throws
  /// [StateError] when any of the three secret names is unloaded.
  SquareAppCredentials get squareAppCredentials => SquareAppCredentials(
    clientId: secretFor(ProxySecretNames.squareClientId),
    clientSecret: secretFor(ProxySecretNames.squareClientSecret),
    notificationUrlHost: secretFor(ProxySecretNames.squareNotificationUrlHost),
  );

  /// Phase 8 framework — Clover static app credentials. Throws
  /// [StateError] when either secret name is unloaded.
  CloverAppCredentials get cloverAppCredentials => CloverAppCredentials(
    appToken: secretFor(ProxySecretNames.cloverAppToken),
    appId: secretFor(ProxySecretNames.cloverAppId),
  );

  /// Phase 8 framework — Humanity static app credentials. Throws
  /// [StateError] when either secret name is unloaded.
  HumanityAppCredentials get humanityAppCredentials => HumanityAppCredentials(
    clientId: secretFor(ProxySecretNames.humanityClientId),
    clientSecret: secretFor(ProxySecretNames.humanityClientSecret),
  );

  /// Phase 8 framework — QuickBooks Time (Intuit) static app
  /// credentials. Throws [StateError] when either secret name is
  /// unloaded.
  QuickBooksTimeAppCredentials get quickBooksTimeAppCredentials =>
      QuickBooksTimeAppCredentials(
        clientId: secretFor(ProxySecretNames.quickBooksTimeClientId),
        clientSecret: secretFor(ProxySecretNames.quickBooksTimeClientSecret),
      );

  /// Phase 8 framework — 7shifts static app credentials. Throws
  /// [StateError] when either secret name is unloaded.
  SevenShiftsAppCredentials get sevenShiftsAppCredentials =>
      SevenShiftsAppCredentials(
        clientId: secretFor(ProxySecretNames.sevenShiftsClientId),
        clientSecret: secretFor(ProxySecretNames.sevenShiftsClientSecret),
      );

  /// Phase 8 framework — Libro static app credentials. Throws
  /// [StateError] when either secret name is unloaded.
  LibroAppCredentials get libroAppCredentials => LibroAppCredentials(
    clientId: secretFor(ProxySecretNames.libroClientId),
    clientSecret: secretFor(ProxySecretNames.libroClientSecret),
  );

  /// Phase 8 framework — public base URI the binder presents to
  /// vendors when constructing the per-tenant location config
  /// resolver. Sourced from the required
  /// [ProxySecretNames.publicBaseUri] env var. Throws [StateError]
  /// when the value is unparseable as a URI; the secret loader
  /// guarantees the name is set (it would have failed boot otherwise),
  /// so the only way to land here is a malformed value.
  Uri get publicBaseUri {
    final raw = secretFor(ProxySecretNames.publicBaseUri);
    final parsed = Uri.tryParse(raw);
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      throw StateError(
        'advisor proxy: ${ProxySecretNames.publicBaseUri} is set but '
        'does not parse as an absolute URI with scheme + host. '
        'Expected something like "https://api.forgeflow.app".',
      );
    }
    return parsed;
  }

  /// True when every Aloha NCR Voyix app credential secret is loaded.
  bool get hasAlohaNcrVoyixCredentials =>
      hasSecretFor(ProxySecretNames.alohaNcrVoyixClientId) &&
      hasSecretFor(ProxySecretNames.alohaNcrVoyixClientSecret) &&
      hasSecretFor(ProxySecretNames.alohaNcrVoyixApplicationKey) &&
      hasSecretFor(ProxySecretNames.alohaNcrVoyixOrganizationId);

  /// True when every Square app credential secret is loaded.
  bool get hasSquareAppCredentials =>
      hasSecretFor(ProxySecretNames.squareClientId) &&
      hasSecretFor(ProxySecretNames.squareClientSecret) &&
      hasSecretFor(ProxySecretNames.squareNotificationUrlHost);

  /// True when every Clover app credential secret is loaded.
  bool get hasCloverAppCredentials =>
      hasSecretFor(ProxySecretNames.cloverAppToken) &&
      hasSecretFor(ProxySecretNames.cloverAppId);

  /// True when every Humanity app credential secret is loaded.
  bool get hasHumanityAppCredentials =>
      hasSecretFor(ProxySecretNames.humanityClientId) &&
      hasSecretFor(ProxySecretNames.humanityClientSecret);

  /// True when every QuickBooks Time app credential secret is loaded.
  bool get hasQuickBooksTimeAppCredentials =>
      hasSecretFor(ProxySecretNames.quickBooksTimeClientId) &&
      hasSecretFor(ProxySecretNames.quickBooksTimeClientSecret);

  /// True when every 7shifts app credential secret is loaded.
  bool get hasSevenShiftsAppCredentials =>
      hasSecretFor(ProxySecretNames.sevenShiftsClientId) &&
      hasSecretFor(ProxySecretNames.sevenShiftsClientSecret);

  /// True when every Libro app credential secret is loaded.
  bool get hasLibroAppCredentials =>
      hasSecretFor(ProxySecretNames.libroClientId) &&
      hasSecretFor(ProxySecretNames.libroClientSecret);

  /// Names of loaded secrets, for diagnostics / startup logs. Never
  /// returns or includes the values.
  List<String> get loadedSecretNames =>
      List<String>.unmodifiable(_secrets.keys);

  /// Diagnostics-only string. Includes the port and the *names* of
  /// loaded secrets. Never includes any secret value. Also reports
  /// whether `FIREBASE_PROJECT_ID` is loaded by name only — the
  /// project ID itself is a public identifier so it is safe to log,
  /// but [toString] keeps to the same name-only convention as the
  /// secrets to make accidental log-leakage audits trivial.
  @override
  String toString() =>
      'ProxyConfig(port: $port, '
      'loaded_secret_names: ${loadedSecretNames.join(', ')}, '
      'firebase_project_id: '
      '${firebaseProjectId == null ? 'unset' : 'set'}, '
      'firebase_email_action_continue_url: '
      '${firebaseEmailActionContinueUrl == null ? 'unset' : 'set'})';
}

// ─── 11a.10b — Usage policy / counter / guard ────────────────────────────────
//
// The usage layer enforces per-tier budgets before any provider call:
//   - request token cap (input size guard, refuses BEFORE store work)
//   - per-minute request cap (sliding minute bucket)
//   - monthly cost cap (calendar-month UTC bucket)
// Tier policy also carries timeout + max-output-token guidance so the
// downstream provider call wraps with the right deadlines.
//
// The counter store is an interface. The default
// `ScaffoldFailingUsageCounterStore` throws on every call so a
// misconfigured production deploy fails closed (503) on usage-protected
// routes instead of waving requests through.

class PolicyTier {
  const PolicyTier({
    required this.id,
    required this.maxRequestTokens,
    required this.maxRequestsPerMinute,
    required this.maxMonthlyCostCents,
    required this.requestTimeoutSeconds,
    required this.maxOutputTokens,
  });

  final String id;
  final int maxRequestTokens;
  final int maxRequestsPerMinute;
  final int maxMonthlyCostCents;
  final int requestTimeoutSeconds;
  final int maxOutputTokens;

  /// Launch-tier defaults. Real per-operator tier policy lands in a
  /// later proxy slice once the operator-tier table is in place; for
  /// now every operator resolves to this single tier.
  static const PolicyTier launch = PolicyTier(
    id: 'launch',
    maxRequestTokens: 8000,
    maxRequestsPerMinute: 30,
    maxMonthlyCostCents: 5000,
    requestTimeoutSeconds: 30,
    maxOutputTokens: 1024,
  );
}

class UsageEstimate {
  const UsageEstimate({required this.requestTokens});

  final int requestTokens;
}

// ─── CODE_HEALTH TOKEN-CAP-REAL — global per-request token cap ───────────────
//
// CODE_HEALTH residual: "No per-request token cap on outbound LLM calls. Repo-
// wide search for `MAX_TOKENS_PER_REQUEST`, `requestTokenCap`, etc. returns
// zero matches. The proxy's outbound LLM call sites (`tool/advisor_proxy/
// advisor_proxy.dart:8485-8700`) have no enforced cap." (archived at
// `docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`).
//
// This is a hard, dispatch-site cap independent of [PolicyTier.maxRequestTokens]:
//   - The tier cap (8000) only applies when [ProxyUsageGuard] is wired AND the
//     route checks it. The advisor smoke route ducks the guard when
//     `usageGuard == null` (tests / staging without HARD-A wired).
//   - This global cap fires at the dispatch site regardless of guard wiring,
//     so an unauthenticated test, a misconfigured deploy, or a route that
//     forgot to wire the guard cannot bypass the cap.
//   - Default 100,000 covers Claude Opus's 200k window with margin while
//     still rejecting pathological requests (giant context dumps, accidental
//     megabyte payloads). Operators with a real need can raise via env up
//     to [kMaxTokensPerRequestUpperBound].
//   - Hard-cap behavior — exceeding the cap returns HTTP 413
//     (`request_too_large`). No silent trim / downgrade.

const int kMaxTokensPerRequestDefault = 100000;

/// Sanity ceiling for the env-driven override. A misconfigured env value
/// (e.g. `9999999`) would otherwise let the proxy ship arbitrarily large
/// payloads downstream regardless of the operator's actual tier.
const int kMaxTokensPerRequestUpperBound = 1000000;

/// Env var name for the per-deployment token cap override. When set to a
/// positive integer at or below [kMaxTokensPerRequestUpperBound],
/// [resolveMaxTokensPerRequest] returns that value; in every other case it
/// falls back to [kMaxTokensPerRequestDefault].
const String kMaxTokensPerRequestEnvVar = 'MAX_TOKENS_PER_REQUEST';

/// Returns the effective per-request token cap for outbound LLM dispatch.
///
/// Resolution order:
///   1. Read [kMaxTokensPerRequestEnvVar] from [environment]
///      (defaults to [Platform.environment]).
///   2. Trim and parse as `int`. Reject parse failures, non-positive
///      values, and values above [kMaxTokensPerRequestUpperBound] with a
///      warning log; fall back to [kMaxTokensPerRequestDefault].
///   3. Otherwise return the parsed value.
///
/// [environment] exists purely for unit tests — production callers pass
/// nothing and read the real process env.
int resolveMaxTokensPerRequest({Map<String, String>? environment}) {
  String? raw;
  // A3.2: bare catch retained — `Platform.environment` raises
  // `UnsupportedError` (an `Error` subclass, not `Exception`) on
  // stripped runtimes such as web/Flutter where the host platform
  // does not expose process env. Narrowing to `on Exception` would
  // re-throw the very failure mode this fallback exists to absorb.
  try {
    raw = (environment ?? Platform.environment)[kMaxTokensPerRequestEnvVar];
  } catch (_) {
    return kMaxTokensPerRequestDefault;
  }
  if (raw == null) return kMaxTokensPerRequestDefault;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return kMaxTokensPerRequestDefault;
  final parsed = int.tryParse(trimmed);
  if (parsed == null) {
    log(
      LogSeverity.warning,
      'advisor_proxy.max_tokens_per_request.invalid',
      fields: <String, Object?>{
        'env_var': kMaxTokensPerRequestEnvVar,
        'raw': trimmed,
        'reason': 'unparsable',
        'fallback': kMaxTokensPerRequestDefault,
      },
    );
    return kMaxTokensPerRequestDefault;
  }
  if (parsed <= 0) {
    log(
      LogSeverity.warning,
      'advisor_proxy.max_tokens_per_request.invalid',
      fields: <String, Object?>{
        'env_var': kMaxTokensPerRequestEnvVar,
        'raw': trimmed,
        'reason': 'non_positive',
        'fallback': kMaxTokensPerRequestDefault,
      },
    );
    return kMaxTokensPerRequestDefault;
  }
  if (parsed > kMaxTokensPerRequestUpperBound) {
    log(
      LogSeverity.warning,
      'advisor_proxy.max_tokens_per_request.invalid',
      fields: <String, Object?>{
        'env_var': kMaxTokensPerRequestEnvVar,
        'raw': trimmed,
        'reason': 'above_upper_bound',
        'upper_bound': kMaxTokensPerRequestUpperBound,
        'fallback': kMaxTokensPerRequestDefault,
      },
    );
    return kMaxTokensPerRequestDefault;
  }
  return parsed;
}

class UsageSnapshot {
  const UsageSnapshot({
    required this.requestsThisMinute,
    required this.costCentsThisMonth,
    required this.minuteBucketStart,
    required this.monthBucketStart,
  });

  final int requestsThisMinute;
  final int costCentsThisMonth;
  final DateTime minuteBucketStart;
  final DateTime monthBucketStart;
}

class UsageDecisionAllowed {
  const UsageDecisionAllowed({
    required this.tier,
    required this.remainingRequestsThisMinute,
    required this.remainingCostCentsThisMonth,
  });

  final PolicyTier tier;
  final int remainingRequestsThisMinute;
  final int remainingCostCentsThisMonth;
}

/// Machine-readable refusal raised by [ProxyUsageGuard]. The route
/// handler turns this into a JSON response with [statusCode] +
/// `{error: code, message, ...details}`.
class UsageRefusal implements Exception {
  UsageRefusal({
    required this.code,
    required this.message,
    required this.statusCode,
    required this.details,
  });

  final String code;
  final String message;
  final int statusCode;
  final Map<String, Object?> details;

  /// JSON body for the refusal response.
  Map<String, Object?> toJson() => <String, Object?>{
    'error': code,
    'message': message,
    ...details,
  };

  @override
  String toString() => '$code: $message';
}

/// Resolves the policy tier that applies to a given operator. Real
/// tier resolution (operator->tier table lookup) lands in a later
/// proxy slice; the scaffold ships a fixed launch-tier resolver.
abstract class PolicyTierResolver {
  PolicyTier resolveFor(OperatorContext operator);
}

class FixedLaunchTierResolver implements PolicyTierResolver {
  const FixedLaunchTierResolver();

  @override
  PolicyTier resolveFor(OperatorContext operator) => PolicyTier.launch;
}

/// Read/write seam over `public.advisor_proxy_usage_counters`. The
/// usage guard reads the current minute/month snapshot before each
/// request and (in a later slice) increments the counters once the
/// downstream provider call returns.
abstract class ProxyUsageCounterStore {
  Future<UsageSnapshot> currentUsage({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
  });

  Future<void> incrementOnAllow({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
    required int costCentsToAdd,
  });
}

/// Hard-fail-closed counter store shipped with the 11a.10b scaffold.
/// Until a real Postgres-backed store wires in, every read/write
/// throws so usage-protected routes refuse with 503 rather than wave
/// traffic through unbounded.
class ScaffoldFailingUsageCounterStore implements ProxyUsageCounterStore {
  const ScaffoldFailingUsageCounterStore();

  @override
  Future<UsageSnapshot> currentUsage({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
  }) async {
    throw StateError(
      '11a.10b scaffold: real usage counter store is not wired '
      '(connect to public.advisor_proxy_usage_counters before serving '
      'usage-protected routes).',
    );
  }

  @override
  Future<void> incrementOnAllow({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
    required int costCentsToAdd,
  }) async {
    throw StateError(
      '11a.10b scaffold: real usage counter store is not wired.',
    );
  }
}

class ProxyUsageGuard {
  ProxyUsageGuard({
    required ProxyUsageCounterStore store,
    required PolicyTierResolver tierResolver,
    DateTime Function()? now,
  }) : _store = store,
       _tierResolver = tierResolver,
       _now = now ?? DateTime.now;

  final ProxyUsageCounterStore _store;
  final PolicyTierResolver _tierResolver;
  final DateTime Function() _now;

  /// Order of checks (matches the acceptance criteria):
  ///   1. Request-token cap — refused BEFORE any store/provider work.
  ///   2. Counter snapshot read; store-failure surfaces as 503
  ///      (`usage_store_unavailable`) so misconfigured prod fails closed.
  ///   3. Per-minute request cap (`rate_limited`, 429).
  ///   4. Monthly cost cap (`monthly_cap_reached`, 402).
  /// On allow, returns the [PolicyTier] plus remaining budget metadata
  /// so the route can surface timeout / max-token guidance.
  Future<UsageDecisionAllowed> requireAllowed({
    required OperatorContext operator,
    required UsageEstimate estimate,
  }) async {
    final tier = _tierResolver.resolveFor(operator);

    if (estimate.requestTokens > tier.maxRequestTokens) {
      throw UsageRefusal(
        code: 'request_too_large',
        statusCode: 413,
        message: 'estimated request tokens exceed tier cap',
        details: <String, Object?>{
          'estimate_request_tokens': estimate.requestTokens,
          'cap_request_tokens': tier.maxRequestTokens,
          'tier_id': tier.id,
        },
      );
    }

    UsageSnapshot snapshot;
    try {
      snapshot = await _store.currentUsage(
        operatorId: operator.operatorId,
        locationId: operator.locationId,
        tierId: tier.id,
        now: _now(),
      );
    } on StateError catch (error) {
      // Scaffold default and other configuration failures: surface the
      // StateError message as the reason. StateError is what the
      // scaffold throws on purpose, so its message is curated and safe
      // to echo (no secrets, no stack-trace fragments).
      throw UsageRefusal(
        code: 'usage_store_unavailable',
        statusCode: 503,
        message: 'usage counter store unavailable',
        details: <String, Object?>{'tier_id': tier.id, 'reason': error.message},
      );
    } on Exception catch (_) {
      // Any other store-side failure (timeout, network, parse, postgres
      // exception, etc.) also fails closed at 503. The reason is
      // intentionally generic — raw error contents may contain secrets,
      // connection strings, or stack-trace fragments and must not leak
      // through the HTTP response. Narrowed to `Exception` so genuine
      // `Error`s (assertion failures, OOM, type errors) continue to
      // propagate instead of being silently masked behind a 503.
      throw UsageRefusal(
        code: 'usage_store_unavailable',
        statusCode: 503,
        message: 'usage counter store unavailable',
        details: <String, Object?>{
          'tier_id': tier.id,
          'reason': 'unexpected store failure',
        },
      );
    }

    if (snapshot.requestsThisMinute >= tier.maxRequestsPerMinute) {
      throw UsageRefusal(
        code: 'rate_limited',
        statusCode: 429,
        message: 'per-minute request cap reached',
        details: <String, Object?>{
          'requests_this_minute': snapshot.requestsThisMinute,
          'cap_requests_per_minute': tier.maxRequestsPerMinute,
          'tier_id': tier.id,
        },
      );
    }

    if (snapshot.costCentsThisMonth >= tier.maxMonthlyCostCents) {
      throw UsageRefusal(
        code: 'monthly_cap_reached',
        statusCode: 402,
        message: 'monthly cost cap reached',
        details: <String, Object?>{
          'cost_cents_this_month': snapshot.costCentsThisMonth,
          'cap_monthly_cost_cents': tier.maxMonthlyCostCents,
          'tier_id': tier.id,
        },
      );
    }

    return UsageDecisionAllowed(
      tier: tier,
      remainingRequestsThisMinute:
          tier.maxRequestsPerMinute - snapshot.requestsThisMinute,
      remainingCostCentsThisMonth:
          tier.maxMonthlyCostCents - snapshot.costCentsThisMonth,
    );
  }

  /// HARD-A: Records that an allowed request landed by upserting the
  /// minute bucket in `public.advisor_proxy_usage_counters` (request
  /// count +1, cost_cents += [costCentsToAdd]). Without this call the
  /// counters never advance and per-minute / monthly caps are
  /// unenforceable. Routes must call this after `requireAllowed`
  /// succeeds — once for usage-smoke (cost 0), once per advisor
  /// pipeline run with the actual cost.
  ///
  /// Failures are intentionally non-fatal: a transient store outage on
  /// the post-allow write would otherwise make a successfully-served
  /// response return 503. The guard's read path already projects store
  /// failures into `usage_store_unavailable`, so a write-side failure
  /// only loses one minute of bucket fidelity.
  Future<void> recordAllowed({
    required OperatorContext operator,
    required UsageDecisionAllowed decision,
    required int costCentsToAdd,
  }) async {
    try {
      await _store.incrementOnAllow(
        operatorId: operator.operatorId,
        locationId: operator.locationId,
        tierId: decision.tier.id,
        now: _now(),
        costCentsToAdd: costCentsToAdd,
      );
    } on Exception catch (_) {
      // Swallow — see method docs. The next minute bucket recovers.
      // Narrowed to `Exception` so genuine `Error`s continue to propagate.
    }
  }
}

// ─── HTTP scaffold ───────────────────────────────────────────────────────────
//
// The router lives here (not in main.dart) so tests can drive it
// directly by binding an HttpServer to a random port and calling the
// same handler the production entrypoint installs.

// --- 11a.11d - accounting, idempotency, health, and LLM cost levers -------
//
// This layer is still local/fake-testable: it defines the contracts the real
// Postgres + Anthropic wiring must satisfy without opening network sockets or
// importing a DB driver. The default implementations fail closed.

class ServicePrincipalJwtIssueCommand {
  const ServicePrincipalJwtIssueCommand({
    required this.servicePrincipalId,
    required this.operator,
    required this.idempotencyKey,
    required this.issuedAt,
  });

  final String servicePrincipalId;
  final OperatorContext operator;
  final String idempotencyKey;
  final DateTime issuedAt;
}

class ServicePrincipalJwtIssued {
  const ServicePrincipalJwtIssued({
    required this.jwt,
    required this.expiresAt,
    this.idempotentReplay = false,
  });

  final String jwt;
  final DateTime expiresAt;
  final bool idempotentReplay;

  Map<String, Object?> toJson() => <String, Object?>{
    'jwt': jwt,
    'expires_at': expiresAt.toUtc().toIso8601String(),
    'idempotent_replay': idempotentReplay,
  };
}

class ServicePrincipalJwtIssueRejected implements Exception {
  const ServicePrincipalJwtIssueRejected({
    required this.code,
    required this.message,
    required this.statusCode,
    this.retryAfter,
  });

  final String code;
  final String message;
  final int statusCode;
  final DateTime? retryAfter;

  Map<String, Object?> toJson() => <String, Object?>{
    'error': code,
    'message': message,
    if (retryAfter != null)
      'retry_after': retryAfter!.toUtc().toIso8601String(),
  };
}

abstract class ServicePrincipalJwtIssuanceGateway {
  Future<ServicePrincipalJwtIssued> issue(
    ServicePrincipalJwtIssueCommand command,
  );
}

class PostgresServicePrincipalJwtIssuanceGateway
    implements ServicePrincipalJwtIssuanceGateway {
  PostgresServicePrincipalJwtIssuanceGateway({
    required TenantTransactionWrapper wrapper,
    required ServicePrincipalJwtIssuer issuer,
    this.ttl = const Duration(minutes: 15),
    this.rateLimitPerHour = 100,
    AuditLogsRepository auditLogsRepository = const AuditLogsRepository(),
    AuditLogsCutoverFlag cutoverFlag = const FixedAuditLogsCutoverFlag(true),
  }) : _wrapper = wrapper,
       _issuer = issuer,
       _auditLogsRepository = auditLogsRepository,
       _cutoverFlag = cutoverFlag;

  final TenantTransactionWrapper _wrapper;
  final ServicePrincipalJwtIssuer _issuer;
  final Duration ttl;
  final int rateLimitPerHour;

  /// Phase 9.0Σ.f B.2 — fan-out target for the hash-chained
  /// `public.audit_logs` table. The B41 issuance gateway writes its
  /// audit row directly via raw SQL (NOT through
  /// `AuthEventsAuditRepository`), so the fan-out lives here at the
  /// gateway boundary too.
  final AuditLogsRepository _auditLogsRepository;

  /// Phase 9.0Σ.f B.2 — resolver for the `audit_logs_cutover_enabled`
  /// feature flag. Production wires
  /// `FeatureFlagsTableAuditLogsCutoverFlag` so flipping the seeded
  /// row to `false` immediately routes new writes back to the legacy
  /// `auth_events_audit`-only path.
  final AuditLogsCutoverFlag _cutoverFlag;

  @override
  Future<ServicePrincipalJwtIssued> issue(
    ServicePrincipalJwtIssueCommand command,
  ) {
    final servicePrincipalId = command.servicePrincipalId.toLowerCase();
    if (!_servicePrincipalUuidPattern.hasMatch(servicePrincipalId)) {
      throw const ServicePrincipalJwtIssueRejected(
        code: 'invalid_service_principal_id',
        message: 'service principal id must be a UUID',
        statusCode: 400,
      );
    }

    final ctx = TenantContext(
      operatorId: command.operator.operatorId,
      locationId: command.operator.locationId,
      userId: command.operator.userId,
    );
    return _wrapper.runInTenantContext(ctx, (exec) async {
      final issuedAt = command.issuedAt.toUtc();
      final requestType = _requestTypeFor(servicePrincipalId);
      final existing = await _lookupIdempotency(exec, command, requestType);
      if (existing != null) return existing;

      await exec.execute(
        'select pg_advisory_xact_lock(hashtext(@service_principal_id))',
        parameters: <String, Object?>{
          'service_principal_id': servicePrincipalId,
        },
      );

      final principal = await _loadServicePrincipal(
        exec,
        operatorId: command.operator.operatorId,
        servicePrincipalId: servicePrincipalId,
      );
      if (principal == null) {
        throw const ServicePrincipalJwtIssueRejected(
          code: 'service_principal_not_found',
          message: 'service principal was not found for this operator',
          statusCode: 404,
        );
      }
      if (principal.revokedAt != null) {
        throw const ServicePrincipalJwtIssueRejected(
          code: 'service_principal_revoked',
          message: 'service principal is revoked',
          statusCode: 409,
        );
      }

      final recentCount = await _recentIssuanceCount(
        exec,
        operatorId: command.operator.operatorId,
        servicePrincipalId: servicePrincipalId,
        issuedAt: issuedAt,
      );
      if (recentCount >= rateLimitPerHour) {
        throw ServicePrincipalJwtIssueRejected(
          code: 'service_principal_rate_limited',
          message: 'service principal JWT issuance rate limit reached',
          statusCode: 429,
          retryAfter: issuedAt.add(const Duration(hours: 1)),
        );
      }

      final reserved = await _reserveIdempotency(exec, command, requestType);
      if (!reserved) {
        final raced = await _lookupIdempotency(exec, command, requestType);
        if (raced != null) return raced;
        throw const ServicePrincipalJwtIssueRejected(
          code: 'idempotency_request_in_flight',
          message: 'idempotent request is already in flight',
          statusCode: 409,
        );
      }

      final jwt = _issuer.issue(
        servicePrincipalId: principal.id,
        operatorId: command.operator.operatorId,
        locationId: command.operator.locationId,
        scopes: principal.scopes,
        issuedAt: issuedAt,
        ttl: ttl,
      );
      final expiresAt = issuedAt.add(ttl);
      final payload = <String, Object?>{
        'jwt': jwt,
        'expires_at': expiresAt.toIso8601String(),
      };

      await _insertAuditRow(
        exec,
        command: command,
        principal: principal,
        issuedAt: issuedAt,
        expiresAt: expiresAt,
      );
      await _completeIdempotency(exec, command, payload);

      return ServicePrincipalJwtIssued(jwt: jwt, expiresAt: expiresAt);
    });
  }

  Future<ServicePrincipalJwtIssued?> _lookupIdempotency(
    PostgresExecutor exec,
    ServicePrincipalJwtIssueCommand command,
    String requestType,
  ) async {
    final rows = await exec.query(
      '''
select request_type, response_payload
  from public.proxy_requests
 where operator_id = @operator_id
   and location_id = @location_id
   and idempotency_key = @idempotency_key
 limit 1
''',
      parameters: <String, Object?>{
        'operator_id': command.operator.operatorId,
        'location_id': command.operator.locationId,
        'idempotency_key': command.idempotencyKey,
      },
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    if (row['request_type'] != requestType) {
      throw const ServicePrincipalJwtIssueRejected(
        code: 'idempotency_key_conflict',
        message: 'Idempotency-Key was already used for another request',
        statusCode: 409,
      );
    }
    final payload = _jsonObjectOrNull(row['response_payload']);
    if (payload == null) {
      throw const ServicePrincipalJwtIssueRejected(
        code: 'idempotency_request_in_flight',
        message: 'idempotent request is already in flight',
        statusCode: 409,
      );
    }
    final jwt = payload['jwt'];
    final expiresAt = DateTime.tryParse(
      payload['expires_at']?.toString() ?? '',
    );
    if (jwt is! String || jwt.isEmpty || expiresAt == null) {
      throw const ServicePrincipalJwtIssueRejected(
        code: 'idempotency_payload_malformed',
        message: 'stored idempotency response is malformed',
        statusCode: 503,
      );
    }
    return ServicePrincipalJwtIssued(
      jwt: jwt,
      expiresAt: expiresAt.toUtc(),
      idempotentReplay: true,
    );
  }

  Future<bool> _reserveIdempotency(
    PostgresExecutor exec,
    ServicePrincipalJwtIssueCommand command,
    String requestType,
  ) async {
    final rows = await exec.query(
      '''
insert into public.proxy_requests (
  idempotency_key,
  request_type,
  operator_id,
  location_id,
  usage_class,
  response_payload
) values (
  @idempotency_key,
  @request_type,
  @operator_id,
  @location_id,
  'auth_service_principal',
  null
)
on conflict (operator_id, location_id, idempotency_key) do nothing
returning request_id
''',
      parameters: <String, Object?>{
        'idempotency_key': command.idempotencyKey,
        'request_type': requestType,
        'operator_id': command.operator.operatorId,
        'location_id': command.operator.locationId,
      },
    );
    return rows.isNotEmpty;
  }

  Future<_ServicePrincipalIssueRow?> _loadServicePrincipal(
    PostgresExecutor exec, {
    required String operatorId,
    required String servicePrincipalId,
  }) async {
    final rows = await exec.query(
      '''
select id::text as id, scopes, revoked_at
  from public.service_principals
 where operator_id = @operator_id::uuid
   and id = @service_principal_id::uuid
 limit 1
''',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'service_principal_id': servicePrincipalId,
      },
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final id = row['id'];
    final revokedAt = row['revoked_at'];
    if (id is! String || (revokedAt != null && revokedAt is! DateTime)) {
      throw const ServicePrincipalJwtIssueRejected(
        code: 'service_principal_malformed',
        message: 'service principal row was malformed',
        statusCode: 503,
      );
    }
    return _ServicePrincipalIssueRow(
      id: id,
      scopes: _decodeServicePrincipalScopes(row['scopes']),
      revokedAt: revokedAt as DateTime?,
    );
  }

  Future<int> _recentIssuanceCount(
    PostgresExecutor exec, {
    required String operatorId,
    required String servicePrincipalId,
    required DateTime issuedAt,
  }) async {
    final rows = await exec.query(
      '''
select count(*)::int as issuance_count
  from public.auth_events_audit
 where operator_id = @operator_id::uuid
   and actor_kind = 'service'
   and actor_service_principal_id = @service_principal_id::uuid
   and event_type = @event_type
   and occurred_at >= @window_start::timestamptz
''',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'service_principal_id': servicePrincipalId,
        'event_type': PermissionKeys.adminServicePrincipalIssueToken,
        'window_start': issuedAt
            .subtract(const Duration(hours: 1))
            .toIso8601String(),
      },
    );
    if (rows.isEmpty) return 0;
    final count = rows.single['issuance_count'];
    if (count is int) return count;
    return int.tryParse(count.toString()) ?? 0;
  }

  Future<void> _insertAuditRow(
    PostgresExecutor exec, {
    required ServicePrincipalJwtIssueCommand command,
    required _ServicePrincipalIssueRow principal,
    required DateTime issuedAt,
    required DateTime expiresAt,
  }) async {
    // HARD-B - claims_hash binds the audit row to the exact JWT
    // payload that was issued. Sorted-key canonical JSON so the
    // hash is stable across Dart map-iteration changes; no signature
    // / shared-secret bytes flow into the hash, so the audit row
    // never carries material that would let a leaker reconstruct
    // the JWT itself.
    final claimsHash = _computeServicePrincipalClaimsHash(
      servicePrincipalId: principal.id,
      operatorId: command.operator.operatorId,
      locationId: command.operator.locationId,
      scopes: principal.scopes,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
    );
    final payload = <String, Object?>{
      'issued_by_user_id': command.operator.userId,
      'service_principal_id': principal.id,
      'scopes': principal.scopes,
      'issued_at': issuedAt.toIso8601String(),
      'expires_at': expiresAt.toIso8601String(),
      'claims_hash': claimsHash,
    };
    await exec.query(
      '''
insert into public.auth_events_audit (
  actor_user_id,
  actor_kind,
  actor_service_principal_id,
  target_user_id,
  operator_id,
  location_id,
  event_type,
  event_payload
) values (
  null,
  'service',
  @service_principal_id::uuid,
  null,
  @operator_id::uuid,
  @location_id::uuid,
  @event_type,
  @payload::jsonb
)
returning event_id::text as event_id
''',
      parameters: <String, Object?>{
        'service_principal_id': principal.id,
        'operator_id': command.operator.operatorId,
        'location_id': command.operator.locationId,
        'event_type': PermissionKeys.adminServicePrincipalIssueToken,
        'payload': jsonEncode(payload),
      },
    );
    if (await _cutoverFlag.isEnabled(exec)) {
      // CLAUDE.md "Service principals" + 9.0Σ.f migration column comment:
      // audit_logs.actor_principal_id holds the canonical `sp:<uuid>`
      // JWT subject, not the bare uuid; the audit_logs_actor_shape_check
      // rejects rows that set both actor slots.
      await _auditLogsRepository.writeRow(
        exec,
        operatorId: command.operator.operatorId,
        locationId: command.operator.locationId,
        occurredAt: issuedAt,
        actorKind: 'service',
        actorPrincipalId: 'sp:${principal.id}',
        action: PermissionKeys.adminServicePrincipalIssueToken,
        payload: payload,
      );
    }
  }

  Future<void> _completeIdempotency(
    PostgresExecutor exec,
    ServicePrincipalJwtIssueCommand command,
    Map<String, Object?> payload,
  ) async {
    final affected = await exec.execute(
      '''
update public.proxy_requests
   set response_payload = @response_payload::jsonb,
       updated_at = @completed_at::timestamptz
 where operator_id = @operator_id
   and location_id = @location_id
   and idempotency_key = @idempotency_key
''',
      parameters: <String, Object?>{
        'response_payload': jsonEncode(payload),
        'completed_at': command.issuedAt.toUtc().toIso8601String(),
        'operator_id': command.operator.operatorId,
        'location_id': command.operator.locationId,
        'idempotency_key': command.idempotencyKey,
      },
    );
    if (affected == 0) {
      throw const ServicePrincipalJwtIssueRejected(
        code: 'idempotency_completion_missing',
        message: 'idempotency reservation was not found',
        statusCode: 503,
      );
    }
  }

  static String _requestTypeFor(String servicePrincipalId) =>
      'service_principal_jwt_issue:$servicePrincipalId';
}

class _ServicePrincipalIssueRow {
  const _ServicePrincipalIssueRow({
    required this.id,
    required this.scopes,
    required this.revokedAt,
  });

  final String id;
  final List<String> scopes;
  final DateTime? revokedAt;
}

List<String> _decodeServicePrincipalScopes(Object? raw) {
  if (raw == null) return const <String>[];
  final decoded = raw is String && raw.isNotEmpty ? jsonDecode(raw) : raw;
  if (decoded is List) {
    return decoded.map((scope) => scope.toString()).toList(growable: false);
  }
  if (decoded is String && decoded.isEmpty) return const <String>[];
  throw const ServicePrincipalJwtIssueRejected(
    code: 'service_principal_scopes_malformed',
    message: 'service principal scopes were malformed',
    statusCode: 503,
  );
}

Map<String, Object?>? _jsonObjectOrNull(Object? value) {
  if (value == null) return null;
  if (value is Map<String, Object?>) return value;
  if (value is Map) return Map<String, Object?>.from(value);
  if (value is String && value.trim().isNotEmpty) {
    final decoded = jsonDecode(value);
    if (decoded is Map) return Map<String, Object?>.from(decoded);
  }
  return null;
}

final RegExp _servicePrincipalUuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// HARD-B - SHA-256 of the canonical JWT payload for the
/// service-principal issuance audit row's `claims_hash` field. The
/// canonical JSON is sorted-key with no whitespace so the hash is
/// stable across Dart map-iteration changes; the hash never includes
/// the signature bytes or the shared secret. Mirrors the JWT issuer's
/// payload claim shape exactly so future refactors stay tight: any
/// change to the JWT payload MUST update this helper at the same time
/// or the audit row's hash drifts from the issued token.
String _computeServicePrincipalClaimsHash({
  required String servicePrincipalId,
  required String operatorId,
  required String locationId,
  required List<String> scopes,
  required DateTime issuedAt,
  required DateTime expiresAt,
}) {
  final iat = issuedAt.toUtc().millisecondsSinceEpoch ~/ 1000;
  final exp = expiresAt.toUtc().millisecondsSinceEpoch ~/ 1000;
  // Sorted-key canonical JSON. Keys: exp, iat, location_id,
  // operator_id, scopes, sub. Hand-built (not jsonEncode of a Map)
  // because Dart map iteration is insertion-ordered and the JWT
  // issuer constructs the payload in a different order; building the
  // canonical string here avoids coupling this helper to whatever
  // order the issuer happens to use.
  final canonical = <String>[
    '"exp":$exp',
    '"iat":$iat',
    '"location_id":${jsonEncode(locationId)}',
    '"operator_id":${jsonEncode(operatorId)}',
    '"scopes":${jsonEncode(scopes)}',
    '"sub":${jsonEncode('sp:$servicePrincipalId')}',
  ].join(',');
  return sha256.convert(utf8.encode('{$canonical}')).toString();
}

class ProxyUsageChargeEstimate {
  const ProxyUsageChargeEstimate({
    required this.tokenCount,
    required this.costCents,
  });

  final int tokenCount;
  final int costCents;
}

class ProxyUsageTelemetry {
  const ProxyUsageTelemetry({
    required this.queryClass,
    required this.cacheHit,
    required this.llmTier,
    required this.modelUsed,
    this.billingOwnerOrgUnitId,
    this.scopedOrgUnitId,
    this.staffId,
    this.workflowId,
    this.batchMode = false,
    this.circuitState = 'closed',
    this.fallbackUsed = 'none',
  });

  final String queryClass;
  final bool cacheHit;
  final String llmTier;
  final String modelUsed;
  final String? billingOwnerOrgUnitId;
  final String? scopedOrgUnitId;
  final String? staffId;
  final String? workflowId;
  final bool batchMode;
  final String circuitState;
  final String fallbackUsed;

  Map<String, Object?> toJson() => <String, Object?>{
    'query_class': queryClass,
    'cache_hit': cacheHit,
    'llm_tier': llmTier,
    'model_used': modelUsed,
    'billing_owner_org_unit_id': billingOwnerOrgUnitId,
    'scoped_org_unit_id': scopedOrgUnitId,
    'staff_id': staffId,
    'workflow_id': workflowId,
    'batch_mode': batchMode,
    'circuit_state': circuitState,
    'fallback_used': fallbackUsed,
  };
}

class ProxyCapStatus {
  const ProxyCapStatus({
    required this.usageClass,
    required this.monthlyCapCents,
    required this.monthlyUsedCents,
    required this.perInvocationCapCents,
    required this.estimatedCostCents,
  });

  final String usageClass;
  final int monthlyCapCents;
  final int monthlyUsedCents;
  final int perInvocationCapCents;
  final int estimatedCostCents;

  bool get perInvocationExceeded =>
      perInvocationCapCents > 0 && estimatedCostCents > perInvocationCapCents;

  bool get monthlyExceeded =>
      monthlyCapCents > 0 &&
      monthlyUsedCents + estimatedCostCents > monthlyCapCents;

  bool get allowed => !perInvocationExceeded && !monthlyExceeded;

  int get remainingMonthlyCents {
    final remaining = monthlyCapCents - monthlyUsedCents;
    return remaining < 0 ? 0 : remaining;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'usage_class': usageClass,
    'monthly_cap_cents': monthlyCapCents,
    'monthly_used_cents': monthlyUsedCents,
    'remaining_monthly_cents': remainingMonthlyCents,
    'per_invocation_cap_cents': perInvocationCapCents,
    'estimated_cost_cents': estimatedCostCents,
    'per_invocation_exceeded': perInvocationExceeded,
    'monthly_exceeded': monthlyExceeded,
  };
}

/// Stats-only per-request telemetry the completion step writes into
/// `public.proxy_request_stats` (Support logs redesign, plan §12 phase
/// P1b). STATS ONLY — carries NO message content. All fields except
/// [usageClass] and [resultStatus] are nullable to match the migration
/// (a request may complete before a model/token count resolves, or be a
/// system/scheduled turn with no acting user). The completion step folds
/// the INSERT into the same transaction as the idempotency-row update so
/// no extra DB round-trip is added.
class ProxyRequestStats {
  const ProxyRequestStats({
    required this.usageClass,
    required this.resultStatus,
    this.requestId,
    this.actorUserId,
    this.provider,
    this.modelId,
    this.modelVersion,
    this.promptTokenCount,
    this.completionTokenCount,
    this.costUsd,
    this.latencyMs,
  });

  /// AI cost class (mirrors `proxy_requests.usage_class`). NOT NULL on the
  /// table — every metered request carries a class.
  final String usageClass;

  /// Terminal outcome — one of `success` / `error` / `timeout` (the
  /// table CHECK-constrains the set).
  final String resultStatus;

  /// `proxy_requests.request_id` correlation key (advisory join, not FK).
  final String? requestId;

  /// Acting user's UUID only (never name/email — resolved at render time
  /// per audit_attribution_contract.md). Null for system/scheduled turns
  /// and for service-principal actors with no human user.
  final String? actorUserId;

  /// Provider identifier (e.g. `anthropic`). Derived from the model id.
  final String? provider;

  /// Resolved model id — the versioned model identifier (e.g.
  /// `claude-haiku-4-5`).
  final String? modelId;

  /// Distinct model version, if any. The proxy's model id is already the
  /// versioned identifier, so this is normally null at launch.
  final String? modelVersion;

  /// Measured input/output token counts and cost. Non-negative where
  /// present (the table CHECK-constrains this).
  final int? promptTokenCount;
  final int? completionTokenCount;
  final num? costUsd;

  /// MEASURED wall-clock latency from request start to completion, in
  /// milliseconds.
  final int? latencyMs;

  Map<String, Object?> toParameters({
    required String operatorId,
    required String locationId,
  }) {
    return <String, Object?>{
      'operator_id': operatorId,
      'location_id': locationId,
      'request_id': requestId,
      'usage_class': usageClass,
      'actor_user_id': actorUserId,
      'provider': provider,
      'model_id': modelId,
      'model_version': modelVersion,
      'prompt_token_count': promptTokenCount,
      'completion_token_count': completionTokenCount,
      // numeric column — pass a string so package:postgres binds it as a
      // numeric literal exactly like the usage_logs cost_usd write.
      'cost_usd': costUsd?.toString(),
      'latency_ms': latencyMs,
      'result_status': resultStatus,
    };
  }
}

abstract class ProxyAccountingStartResult {
  const ProxyAccountingStartResult();
}

class ProxyAccountingReserved extends ProxyAccountingStartResult {
  const ProxyAccountingReserved({required this.capStatus, this.requestId});

  final ProxyCapStatus capStatus;

  /// The `public.proxy_requests.request_id` trace uuid the reservation
  /// INSERT returned, surfaced so the completion step can correlate the
  /// `proxy_request_stats` row to the same `(operator_id, location_id,
  /// request_id)` tenant key. Null when the store does not (or cannot)
  /// surface it — the stats row is then written with a null correlation
  /// key rather than being dropped.
  final String? requestId;
}

class ProxyAccountingReplayed extends ProxyAccountingStartResult {
  const ProxyAccountingReplayed({required this.responsePayload});

  final Map<String, Object?> responsePayload;
}

class ProxyAccountingRefused extends ProxyAccountingStartResult {
  const ProxyAccountingRefused({required this.capStatus});

  final ProxyCapStatus capStatus;
}

abstract class ProxyAccountingStore {
  /// Pre-flight: replay lookup, cap-check, and idempotency reservation.
  /// As of Block 2 (Lock 7 v1), `usage_logs` is NOT written here so that
  /// the row's `(circuit_state, fallback_used)` reflects the post-chain
  /// outcome via [commitUsageLog]. The `telemetry` argument's
  /// `circuit_state` / `fallback_used` are ignored at this stage; pass
  /// the snapshot you'd write if the chain happened to short-circuit.
  Future<ProxyAccountingStartResult> startRequest({
    required String idempotencyKey,
    required String requestType,
    required OperatorContext operator,
    required String usageClass,
    required ProxyUsageTelemetry telemetry,
    required ProxyUsageChargeEstimate estimate,
    required DateTime now,
  });

  /// Post-chain: writes the `usage_logs` rollup row with the final
  /// telemetry (including resolved `circuit_state` and `fallback_used`).
  /// Called once per reserved request, after the LLM/cache/refusal chain
  /// has decided what served the response. Called with `tokenCount` and
  /// `costCents` updated to the actual usage.
  Future<void> commitUsageLog({
    required OperatorContext operator,
    required String usageClass,
    required ProxyUsageTelemetry telemetry,
    required ProxyUsageChargeEstimate estimate,
    required DateTime now,
  });

  /// Post-chain: marks the reserved idempotency row complete with the
  /// served [responsePayload] AND, when [stats] is provided, writes the
  /// matching `public.proxy_request_stats` telemetry row in the SAME
  /// tenant transaction (no extra round-trip). Called exactly once per
  /// REAL request; the route early-returns on an idempotency replay, so a
  /// replay never reaches here and cannot write a duplicate stats row.
  Future<void> completeRequest({
    required OperatorContext operator,
    required String idempotencyKey,
    required Map<String, Object?> responsePayload,
    required DateTime now,
    ProxyRequestStats? stats,
  });

  /// P1b.2 — Support logs failure/timeout telemetry (plan §12). Writes a
  /// standalone `public.proxy_request_stats` row for a request that bailed
  /// BEFORE [completeRequest] on a provider failure or timeout (the 503
  /// `llm_provider_unavailable` early-return). Unlike the success path —
  /// which folds the stats INSERT into [completeRequest]'s completion
  /// transaction so no extra round-trip is added — a failed request never
  /// reaches that completion update, so this writes the stats row in its
  /// OWN tenant transaction. Called at most once per REAL failed attempt
  /// (an idempotency replay early-returns at the route before a reservation
  /// exists, so it never reaches this path) — no duplicate row on replay.
  /// STATS ONLY — no message content.
  Future<void> recordRequestStats({
    required OperatorContext operator,
    required ProxyRequestStats stats,
  });
}

class PostgresProxyAccountingStore implements ProxyAccountingStore {
  PostgresProxyAccountingStore({
    required TenantTransactionWrapper wrapper,
    CapEventRecorder? capEventRecorder,
  }) : _wrapper = wrapper,
       // Best-effort recorder for the "Limit hits" panel. Defaults to one
       // built from the same tenant wrapper; tests inject a fake to assert
       // the refusal-only insert + the non-blocking guarantee.
       _capEventRecorder =
           capEventRecorder ?? CapEventRecorder(wrapper: wrapper);

  final TenantTransactionWrapper _wrapper;
  final CapEventRecorder _capEventRecorder;

  @override
  Future<ProxyAccountingStartResult> startRequest({
    required String idempotencyKey,
    required String requestType,
    required OperatorContext operator,
    required String usageClass,
    required ProxyUsageTelemetry telemetry,
    required ProxyUsageChargeEstimate estimate,
    required DateTime now,
  }) async {
    final ctx = _tenantContextFor(operator);
    final params = _usageParameters(
      idempotencyKey: idempotencyKey,
      requestType: requestType,
      operator: operator,
      usageClass: usageClass,
      telemetry: telemetry,
      estimate: estimate,
      now: now,
    );

    final result = await _wrapper.runInTenantContext(ctx, (exec) async {
      final existingReplay = await _lookupReplay(exec, params);
      if (existingReplay != null) return existingReplay;

      final capStatus = await _loadCapStatus(
        exec,
        params,
        usageClass,
        estimate,
      );
      if (!capStatus.allowed) {
        return ProxyAccountingRefused(capStatus: capStatus);
      }

      final reservationRows = await exec.query(
        ProxyUsageLogSql.idempotencyInsert,
        parameters: params,
      );
      if (reservationRows.isEmpty) {
        final racedReplay = await _lookupReplay(exec, params);
        if (racedReplay != null) return racedReplay;
        throw StateError(
          'proxy accounting idempotency reservation is already in flight',
        );
      }

      // The reservation INSERT returns the trace `request_id` the DB
      // generated; surface it so completeRequest can correlate the
      // proxy_request_stats row to this proxy_requests row.
      final reservedRequestId = _stringOrNull(
        reservationRows.first['request_id'],
      );
      return ProxyAccountingReserved(
        capStatus: capStatus,
        requestId: reservedRequestId,
      );
    });

    // AI Metrics "Limit hits": record the refusal into the append-only
    // `public.usage_cap_events` ledger AFTER the decision is made and the
    // cap-check transaction has committed (its own transaction, so no
    // nesting). `recordRefusal` is best-effort and NEVER throws, so this
    // cannot change the refusal, the response, or the allow/replay
    // latency. Only the refusal branch records; allow/replay return above.
    if (result is ProxyAccountingRefused) {
      final cap = result.capStatus;
      await _capEventRecorder.recordRefusal(
        operatorId: operator.operatorId,
        locationId: operator.locationId,
        userId: operator.userId,
        usageClass: usageClass,
        queryClass: telemetry.queryClass,
        perInvocationExceeded: cap.perInvocationExceeded,
        perInvocationCapCents: cap.perInvocationCapCents,
        monthlyCapCents: cap.monthlyCapCents,
        monthlyUsedCents: cap.monthlyUsedCents,
        estimatedCostCents: cap.estimatedCostCents,
        occurredAt: now,
      );
    }
    return result;
  }

  @override
  Future<void> commitUsageLog({
    required OperatorContext operator,
    required String usageClass,
    required ProxyUsageTelemetry telemetry,
    required ProxyUsageChargeEstimate estimate,
    required DateTime now,
  }) {
    final ctx = _tenantContextFor(operator);
    final params = _usageParameters(
      idempotencyKey: '',
      requestType: '',
      operator: operator,
      usageClass: usageClass,
      telemetry: telemetry,
      estimate: estimate,
      now: now,
    );
    return _wrapper.runInTenantContext(ctx, (exec) async {
      await exec.query(ProxyUsageLogSql.atomicUpsert, parameters: params);
    });
  }

  @override
  Future<void> completeRequest({
    required OperatorContext operator,
    required String idempotencyKey,
    required Map<String, Object?> responsePayload,
    required DateTime now,
    ProxyRequestStats? stats,
  }) async {
    final ctx = _tenantContextFor(operator);
    final affected = await _wrapper.runInTenantContext(ctx, (exec) async {
      final rows = await exec.execute(
        ProxyUsageLogSql.completionUpdate,
        parameters: <String, Object?>{
          'operator_id': operator.operatorId,
          'location_id': operator.locationId,
          'idempotency_key': idempotencyKey,
          'response_payload': jsonEncode(responsePayload),
          'completed_at': now.toUtc().toIso8601String(),
        },
      );
      // P1b — Support logs telemetry. Fold the stats-only INSERT into the
      // SAME tenant transaction as the completion update so no extra
      // per-request DB round-trip is added (CLAUDE.md Cost & Convergence).
      // STATS ONLY — no message content is written here. Runs under the
      // identical `SET LOCAL` tenant context as the sibling write. Guarded
      // on `rows > 0` so a completion that matched no proxy_requests row
      // (the "should never happen" case the StateError below catches)
      // never leaves an orphan stats row behind.
      if (stats != null && rows > 0) {
        await exec.execute(
          ProxyRequestStatsSql.insert,
          parameters: stats.toParameters(
            operatorId: operator.operatorId,
            locationId: operator.locationId,
          ),
        );
      }
      return rows;
    });
    if (affected == 0) {
      throw StateError('proxy accounting completion row was not found');
    }
  }

  @override
  Future<void> recordRequestStats({
    required OperatorContext operator,
    required ProxyRequestStats stats,
  }) {
    // P1b.2 — failure/timeout telemetry. A failed request never reaches the
    // completion update, so the stats row cannot ride that transaction;
    // write it in its own tenant transaction under the same `SET LOCAL`
    // context the sibling writes use. One INSERT only on the FAILURE path
    // (the success path stays a single folded write — no extra round-trip
    // there). STATS ONLY — no message content.
    final ctx = _tenantContextFor(operator);
    return _wrapper.runInTenantContext(ctx, (exec) async {
      await exec.execute(
        ProxyRequestStatsSql.insert,
        parameters: stats.toParameters(
          operatorId: operator.operatorId,
          locationId: operator.locationId,
        ),
      );
    });
  }

  static TenantContext _tenantContextFor(OperatorContext operator) {
    return TenantContext(
      operatorId: operator.operatorId,
      locationId: operator.locationId,
      userId: operator.userId,
    );
  }

  static PostgresParameters _usageParameters({
    required String idempotencyKey,
    required String requestType,
    required OperatorContext operator,
    required String usageClass,
    required ProxyUsageTelemetry telemetry,
    required ProxyUsageChargeEstimate estimate,
    required DateTime now,
  }) {
    return <String, Object?>{
      'idempotency_key': idempotencyKey,
      'request_type': requestType,
      'operator_id': operator.operatorId,
      'location_id': operator.locationId,
      'usage_class': usageClass,
      'request_time': now.toUtc().toIso8601String(),
      'token_count': estimate.tokenCount,
      'cost_usd': (estimate.costCents / 100).toStringAsFixed(4),
      'billing_owner_org_unit_id': telemetry.billingOwnerOrgUnitId,
      'scoped_org_unit_id': telemetry.scopedOrgUnitId,
      'staff_id': telemetry.staffId,
      'workflow_id': telemetry.workflowId,
      'query_class': telemetry.queryClass,
      'cache_hit': telemetry.cacheHit,
      'llm_tier': telemetry.llmTier,
      'model_used': telemetry.modelUsed,
      'batch_mode': telemetry.batchMode,
      'circuit_state': telemetry.circuitState,
      'fallback_used': telemetry.fallbackUsed,
    };
  }

  static Future<ProxyAccountingReplayed?> _lookupReplay(
    PostgresExecutor exec,
    PostgresParameters params,
  ) async {
    final rows = await exec.query(
      ProxyUsageLogSql.idempotencyLookup,
      parameters: params,
    );
    if (rows.isEmpty) return null;
    final payload = _jsonObjectOrNull(rows.first['response_payload']);
    if (payload != null) {
      return ProxyAccountingReplayed(responsePayload: payload);
    }
    throw StateError(
      'proxy accounting idempotency reservation is already in flight',
    );
  }

  static Future<ProxyCapStatus> _loadCapStatus(
    PostgresExecutor exec,
    PostgresParameters params,
    String usageClass,
    ProxyUsageChargeEstimate estimate,
  ) async {
    final rows = await exec.query(
      ProxyUsageLogSql.capStatusSelect,
      parameters: params,
    );
    final row = rows.isEmpty ? const <String, Object?>{} : rows.first;
    return ProxyCapStatus(
      usageClass: usageClass,
      monthlyCapCents: _usdToCents(row['monthly_cap_usd']),
      monthlyUsedCents: _usdToCents(row['monthly_used_usd']),
      perInvocationCapCents: _usdToCents(row['per_invocation_cap_usd']),
      estimatedCostCents: estimate.costCents,
    );
  }

  static String? _stringOrNull(Object? value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static Map<String, Object?>? _jsonObjectOrNull(Object? value) {
    if (value == null) return null;
    if (value is Map<String, Object?>) return value;
    if (value is Map) return Map<String, Object?>.from(value);
    if (value is String && value.trim().isNotEmpty) {
      final decoded = jsonDecode(value);
      if (decoded is Map) return Map<String, Object?>.from(decoded);
    }
    return null;
  }

  static int _usdToCents(Object? value) {
    if (value == null) return 0;
    final amount = value is num
        ? value.toDouble()
        : double.tryParse(value.toString());
    if (amount == null) return 0;
    return (amount * 100).round();
  }
}

class ScaffoldFailingProxyAccountingStore implements ProxyAccountingStore {
  const ScaffoldFailingProxyAccountingStore();

  @override
  Future<ProxyAccountingStartResult> startRequest({
    required String idempotencyKey,
    required String requestType,
    required OperatorContext operator,
    required String usageClass,
    required ProxyUsageTelemetry telemetry,
    required ProxyUsageChargeEstimate estimate,
    required DateTime now,
  }) async {
    throw StateError(
      '11a.11d scaffold: real Postgres accounting store is not wired.',
    );
  }

  @override
  Future<void> commitUsageLog({
    required OperatorContext operator,
    required String usageClass,
    required ProxyUsageTelemetry telemetry,
    required ProxyUsageChargeEstimate estimate,
    required DateTime now,
  }) async {
    throw StateError(
      '11a.11d scaffold: real Postgres accounting store is not wired.',
    );
  }

  @override
  Future<void> completeRequest({
    required OperatorContext operator,
    required String idempotencyKey,
    required Map<String, Object?> responsePayload,
    required DateTime now,
    ProxyRequestStats? stats,
  }) async {
    throw StateError(
      '11a.11d scaffold: real Postgres accounting store is not wired.',
    );
  }

  @override
  Future<void> recordRequestStats({
    required OperatorContext operator,
    required ProxyRequestStats stats,
  }) async {
    throw StateError(
      '11a.11d scaffold: real Postgres accounting store is not wired.',
    );
  }
}

enum ProxyLlmTier {
  haiku('haiku'),
  sonnet('sonnet');

  const ProxyLlmTier(this.id);

  final String id;
}

class ProxyLlmModelRouting {
  const ProxyLlmModelRouting({
    this.haikuModelId = 'claude-haiku-4-5',
    this.sonnetModelId = 'claude-sonnet-4-6',
  });

  final String haikuModelId;
  final String sonnetModelId;

  String modelIdFor(ProxyLlmTier tier) =>
      tier == ProxyLlmTier.haiku ? haikuModelId : sonnetModelId;
}

class SubscriptionLlmTierRouter {
  const SubscriptionLlmTierRouter();

  /// Resolves the served [ProxyLlmTier] from the operator's plan and the
  /// per-call query class.
  ///
  /// Precedence (Plans & Limits V1, slice 5c):
  ///   1. The operator's plan sets the CEILING / baseline model via
  ///      [_modelTierForPlan] (pilot/starter cap at Haiku; premium / elite /
  ///      pro / enterprise are allowed up to Sonnet).
  ///   2. The query class is a cost lever that may DOWNGRADE a Sonnet-capable
  ///      plan to Haiku for cheap, non-nuanced calls. It can NEVER upgrade a
  ///      Haiku-capped plan to Sonnet.
  ///
  /// Net: plan = the most expensive model this operator can ever reach;
  /// cost levers only ever spend less, never more.
  ProxyLlmTier tierFor({
    required String subscriptionTier,
    required String queryClass,
  }) {
    final planCeiling = _modelTierForPlan(subscriptionTier);

    // Plan caps at Haiku (pilot / starter / unknown): the query class cannot
    // upgrade past the plan, so we always serve Haiku.
    if (planCeiling == ProxyLlmTier.haiku) {
      return ProxyLlmTier.haiku;
    }

    // Plan allows Sonnet: existing cost-lever behavior is preserved — cheap,
    // non-nuanced query classes are downgraded to Haiku; nuanced synthesis
    // gets the plan's full Sonnet ceiling.
    if (_requiresNuancedSynthesis(queryClass)) {
      return ProxyLlmTier.sonnet;
    }
    return ProxyLlmTier.haiku;
  }

  /// Maps an operator's `operators.subscription_tier` to the richest model
  /// the plan is entitled to (its CEILING). Drives Haiku vs Sonnet straight
  /// from the plan, per the `kPricingTierTemplates` summaries
  /// (`lib/admin/models/pricing_tier_admin_models.dart`):
  ///   - Pilot   = free preview, cheapest metering             -> Haiku
  ///   - Starter = "$250/mo. ...; Haiku for advisor."          -> Haiku
  ///   - Premium = "...; Sonnet for advisor."                  -> Sonnet
  ///   - Elite   = "...; Adds staff coach + SOPs." (richer)    -> Sonnet
  ///   - Pro     = "...; Adds workflow catalog..." (richer)    -> Sonnet
  ///   - Enterprise = "Custom contract." (top tier)            -> Sonnet
  ///
  /// Legacy keys (`basic`, `launch`) and any unknown / missing tier fall back
  /// to the existing safe default (Haiku, the cheapest model) so a token
  /// issued before Phase 0 or a typo never crashes and never over-spends.
  static ProxyLlmTier _modelTierForPlan(String subscriptionTier) {
    final subscription = subscriptionTier.trim().toLowerCase();
    switch (subscription) {
      case 'premium':
      case 'elite':
      case 'pro':
      case 'enterprise':
        return ProxyLlmTier.sonnet;
      case 'pilot':
      case 'starter':
      // Legacy pre-Phase-0 keys retained for back-compat.
      case 'basic':
      case 'launch':
        return ProxyLlmTier.haiku;
      default:
        // Unknown / missing tier -> safe default (cheapest model).
        return ProxyLlmTier.haiku;
    }
  }

  static bool _requiresNuancedSynthesis(String queryClass) {
    final normalized = queryClass.trim().toLowerCase();
    return normalized == 'causal_chain' ||
        normalized == 'recommendation' ||
        normalized == 'advisor_synthesis' ||
        normalized == 'workflow_action' ||
        normalized == 'pnl_narrative';
  }
}

class ProxyPromptBlock {
  const ProxyPromptBlock({
    required this.id,
    required this.text,
    required this.cacheBreakpoint,
    this.cacheTtl = '1h',
  });

  final String id;
  final String text;
  final bool cacheBreakpoint;

  // Item 12 / Lever 1 — Anthropic prompt-cache TTL pin. Every breakpoint
  // block emits "ttl":"1h" so vendor-default changes cannot silently break
  // cost math. Non-breakpoint blocks carry the field but do not surface it
  // through `proxyPromptBlockToCacheControl` (which returns null for them).
  final String cacheTtl;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'text': text,
    'cache_breakpoint': cacheBreakpoint,
    'cache_ttl': cacheTtl,
  };
}

/// Anthropic Messages-API `cache_control` shape for one prompt block.
///
/// Returns `{"type":"ephemeral","ttl":"1h"}` for breakpoint blocks and
/// `null` otherwise. The real Anthropic provider (lands in 11a.11d)
/// attaches this map to each block whose `cacheBreakpoint == true`. The
/// helper exists today so unit tests can assert the contract before the
/// provider is wired (scalability-decisions item 12).
Map<String, Object?>? proxyPromptBlockToCacheControl(ProxyPromptBlock block) {
  if (!block.cacheBreakpoint) {
    return null;
  }
  return <String, Object?>{'type': 'ephemeral', 'ttl': block.cacheTtl};
}

class ProxyLlmRequest {
  const ProxyLlmRequest({
    required this.question,
    required this.promptBlocks,
    required this.tier,
    required this.modelId,
    required this.cacheKey,
    required this.maxOutputTokens,
  });

  final String question;
  final List<ProxyPromptBlock> promptBlocks;
  final ProxyLlmTier tier;
  final String modelId;
  final String cacheKey;
  final int maxOutputTokens;
}

class ProxyLlmCompletion {
  const ProxyLlmCompletion({
    required this.text,
    required this.modelId,
    required this.tier,
    required this.outputTokens,
    required this.costCents,
  });

  final String text;
  final String modelId;
  final ProxyLlmTier tier;
  final int outputTokens;
  final int costCents;
}

abstract class ProxyLlmProvider {
  Future<ProxyLlmCompletion> complete(ProxyLlmRequest request);
}

class ScaffoldRejectingProxyLlmProvider implements ProxyLlmProvider {
  const ScaffoldRejectingProxyLlmProvider();

  @override
  Future<ProxyLlmCompletion> complete(ProxyLlmRequest request) async {
    throw StateError('11a.11d scaffold: real Anthropic provider is not wired.');
  }
}

// ─── Phase 11A.4b — Production proxy LLM providers ──────────────────────────
//
// Two thin proxy adapters wrap the real Anthropic Messages-API HTTP
// client and the real google_generative_ai SDK. Production callbacks
// live in proxy_bootstrap.dart so the SDK imports stay server-side
// (Hard Promise #7 — keys never leave the proxy). Both adapters
// return [ProxyLlmCompletePayload] so the wrapper class can compute
// real cost via [LlmCostRateRegistry].
//
// Failure handling is the AdvisorRequestPipeline's job — these
// adapters just call the SDK and surface results or rethrow.

/// Token-and-text payload returned by a real LLM SDK call. Lifts the
/// usage metadata from the response so the proxy adapter can compute
/// cost from real token counts (not heuristics) and surface it into
/// `usage_logs.cost_usd` for cap enforcement.
class ProxyLlmCompletePayload {
  const ProxyLlmCompletePayload({
    required this.text,
    required this.inputTokens,
    required this.outputTokens,
  });

  final String text;
  final int inputTokens;
  final int outputTokens;
}

/// Adapter signature for an Anthropic Messages-API call. The
/// production implementation lives in
/// `tool/advisor_proxy/anthropic_http_complete_fn.dart` and uses
/// `package:http`; tests pin a closure that captures inputs and
/// returns a fixed payload.
typedef AnthropicProxyCompleteFn =
    Future<ProxyLlmCompletePayload> Function({
      required String modelId,
      required String question,
      required String context,
    });

/// Adapter signature for a Gemini SDK call. The optional `onChunk`
/// hook lets callers observe streaming chunks; the public
/// [ProxyLlmProvider] surface stays non-streaming so the
/// AdvisorRequestPipeline doesn't need to special-case streamed
/// responses.
typedef GeminiProxyCompleteFn =
    Future<ProxyLlmCompletePayload> Function({
      required String modelId,
      required String question,
      required String context,
      void Function(String chunk)? onChunk,
    });

ProxyLlmCompletion _buildCompletionFromPayload({
  required ProxyLlmCompletePayload payload,
  required String modelId,
  required ProxyLlmTier tier,
}) {
  // Real cost computed from real token counts via the per-model
  // rate registry. Unknown models charge zero (the registry returns
  // null) so cap enforcement is preserved for known models without
  // breaking unrecognized-model paths during rollouts.
  final rate = LlmCostRateRegistry.rateFor(modelId);
  final costCents = rate == null
      ? 0
      : rate.costCentsFor(
          inputTokens: payload.inputTokens,
          outputTokens: payload.outputTokens,
        );
  return ProxyLlmCompletion(
    text: payload.text,
    modelId: modelId,
    tier: tier,
    outputTokens: payload.outputTokens,
    costCents: costCents,
  );
}

String _flattenPromptBlocks(List<ProxyPromptBlock> blocks) {
  final buffer = StringBuffer();
  for (var i = 0; i < blocks.length; i++) {
    if (i > 0) buffer.write('\n\n');
    buffer.write(blocks[i].text);
  }
  return buffer.toString();
}

class AnthropicProxyLlmProvider implements ProxyLlmProvider {
  AnthropicProxyLlmProvider({required AnthropicProxyCompleteFn completeFn})
    : _completeFn = completeFn;

  final AnthropicProxyCompleteFn _completeFn;

  @override
  Future<ProxyLlmCompletion> complete(ProxyLlmRequest request) async {
    final payload = await _completeFn(
      modelId: request.modelId,
      question: request.question,
      context: _flattenPromptBlocks(request.promptBlocks),
    );
    return _buildCompletionFromPayload(
      payload: payload,
      modelId: request.modelId,
      tier: request.tier,
    );
  }
}

class GeminiProxyLlmProvider implements ProxyLlmProvider {
  GeminiProxyLlmProvider({
    required GeminiProxyCompleteFn completeFn,
    void Function(String chunk)? onChunkObserver,
  }) : _completeFn = completeFn,
       _onChunkObserver = onChunkObserver;

  final GeminiProxyCompleteFn _completeFn;
  final void Function(String chunk)? _onChunkObserver;

  /// Resolves the Gemini model id for the requested tier. The proxy
  /// passes its own `request.modelId` (Anthropic-shaped: `claude-*`);
  /// we override with the Gemini-equivalent so `usage_logs.model_used`
  /// reports `gemini-*` when the secondary serves.
  String _modelIdFor(ProxyLlmTier tier) {
    switch (tier) {
      case ProxyLlmTier.haiku:
        return AdvisorProviderConstants.geminiFlashModelId;
      case ProxyLlmTier.sonnet:
        return AdvisorProviderConstants.geminiProModelId;
    }
  }

  @override
  Future<ProxyLlmCompletion> complete(ProxyLlmRequest request) async {
    final modelId = _modelIdFor(request.tier);
    final payload = await _completeFn(
      modelId: modelId,
      question: request.question,
      context: _flattenPromptBlocks(request.promptBlocks),
      onChunk: _onChunkObserver,
    );
    return _buildCompletionFromPayload(
      payload: payload,
      modelId: modelId,
      tier: request.tier,
    );
  }
}

/// CODE_HEALTH L4 — secondary-LLM HTTP/runtime failure classification.
///
/// The pre-L4 pipeline used a bare `catch (_)` around the secondary
/// (Gemini) call, which counted RateLimitErrors, AuthErrors, transient
/// 5xx, permanent 4xx, and timeouts identically. The breaker uses this
/// taxonomy to decide retry vs fail-fast and to distinguish "service
/// degraded" from "credentials broken".
enum SecondaryLlmFailureKind {
  /// Secondary call did not complete inside the per-call deadline.
  timeout,

  /// HTTP 429.
  rateLimit,

  /// HTTP 401 / 403 — credentials or scope problem; never retry.
  auth,

  /// HTTP 5xx — transient server-side failure; safe to retry.
  transient,

  /// HTTP 4xx other than 429/401/403 — permanent client error; never retry.
  permanent,

  /// Anything we cannot classify (DNS, socket, parse). Treated as transient
  /// for breaker accounting (false positives are safer than false
  /// negatives for breakers).
  unknown,
}

/// CODE_HEALTH L4 — typed classification of secondary-LLM failures.
///
/// Branches on:
///   1. [TimeoutException] → [SecondaryLlmFailureKind.timeout].
///   2. [LLMProviderException] → its declared [FailureKind] +
///      [statusCode] map directly; HTTP status drives the AuthError /
///      RateLimitError / PermanentError split.
///   3. Anything else (`SocketException`, `HttpException`,
///      `FormatException`, …) → [SecondaryLlmFailureKind.unknown].
SecondaryLlmFailureKind classifySecondaryLlmFailure(Object error) {
  if (error is TimeoutException) return SecondaryLlmFailureKind.timeout;
  if (error is LLMProviderException) {
    final status = error.statusCode;
    if (status != null) {
      if (status == 429) return SecondaryLlmFailureKind.rateLimit;
      if (status == 401 || status == 403) return SecondaryLlmFailureKind.auth;
      if (status >= 500 && status < 600) {
        return SecondaryLlmFailureKind.transient;
      }
      if (status >= 400 && status < 500) {
        return SecondaryLlmFailureKind.permanent;
      }
    }
    switch (error.kind) {
      case FailureKind.timeout:
        return SecondaryLlmFailureKind.timeout;
      case FailureKind.http429:
        return SecondaryLlmFailureKind.rateLimit;
      case FailureKind.http5xx:
        return SecondaryLlmFailureKind.transient;
      case FailureKind.costBreach:
        return SecondaryLlmFailureKind.permanent;
      case FailureKind.unknown:
        return SecondaryLlmFailureKind.unknown;
    }
  }
  return SecondaryLlmFailureKind.unknown;
}

/// CODE_HEALTH L4 — circuit breaker for the secondary (Gemini) LLM.
///
/// The pre-L4 pipeline trusted the secondary unconditionally: every
/// fallback attempt waited up to whatever the underlying HTTP client
/// chose, and a slow / down Gemini propagated that latency to every
/// caller while the primary breaker was open. This breaker rolls a
/// 60-second sliding window of failures; after [maxFailures] failures
/// the breaker opens for [openDuration]. While open, [tryAcquire]
/// returns false instantly and callers fall through to the cache /
/// refusal branches WITHOUT invoking the underlying gateway.
///
/// Auth failures are excluded from the failure window because credential
/// breakage is not transient — letting an AuthError trip the breaker
/// would mask the real problem and delay recovery once credentials are
/// fixed. Permanent 4xx errors are likewise excluded.
///
/// Sliding-window semantics: only failures whose timestamp is within
/// the last [windowDuration] count toward the threshold; older
/// timestamps are pruned on every [recordFailure] / [tryAcquire] call.
class SecondaryLlmBreaker {
  SecondaryLlmBreaker({
    this.maxFailures = 5,
    this.windowDuration = const Duration(seconds: 60),
    this.openDuration = const Duration(seconds: 30),
    DateTime Function() clock = _defaultClock,
  }) : _clock = clock;

  static DateTime _defaultClock() => DateTime.now().toUtc();

  final int maxFailures;
  final Duration windowDuration;
  final Duration openDuration;
  final DateTime Function() _clock;

  final List<DateTime> _failureTimestamps = <DateTime>[];
  DateTime? _openedAt;

  /// True when the breaker is closed (or has cooled down past
  /// [openDuration]); callers should invoke the secondary. False when
  /// the breaker is open; callers should skip to the cache / refusal
  /// branches.
  bool tryAcquire() {
    final now = _clock();
    if (_openedAt != null) {
      if (now.difference(_openedAt!) >= openDuration) {
        // Half-open: clear the window so a fresh failure does not
        // immediately re-open the breaker.
        _openedAt = null;
        _failureTimestamps.clear();
        return true;
      }
      return false;
    }
    return true;
  }

  /// Records a successful secondary call. Closes the breaker (if it
  /// was half-open) and clears the failure window.
  void recordSuccess() {
    _openedAt = null;
    _failureTimestamps.clear();
  }

  /// Records a failed secondary call. Auth and permanent 4xx errors
  /// are NOT counted toward the breaker (credential / contract
  /// failures are not transient). Timeouts, 5xx, 429, and unknown
  /// failures count.
  void recordFailure(SecondaryLlmFailureKind kind) {
    if (kind == SecondaryLlmFailureKind.auth ||
        kind == SecondaryLlmFailureKind.permanent) {
      return;
    }
    final now = _clock();
    final cutoff = now.subtract(windowDuration);
    _failureTimestamps.removeWhere((ts) => ts.isBefore(cutoff));
    _failureTimestamps.add(now);
    if (_failureTimestamps.length >= maxFailures) {
      _openedAt = now;
      _failureTimestamps.clear();
    }
  }

  /// Test-only inspector: true when the breaker is currently open.
  bool get isOpen => _openedAt != null;
}

/// Block 2 (Lock 7 v1) — fallback chain executor.
///
/// Wraps the primary [ProxyLlmProvider] with a [CircuitBreaker], an
/// optional [secondaryLlmProvider] (Gemini Flash, Phase 11A.4b), an
/// [AdvisorResponseCache], and a graceful refusal tertiary. The
/// secondary slot was reserved as `// TODO(E.2b)` in v1; this graft
/// fills it with a real `GeminiProxyLlmProvider`. Tests assert that
/// `fallback_used` reports `'gemini'` when the secondary serves.
///
/// CODE_HEALTH L4 — the secondary call is now wrapped in a per-call
/// 8s timeout, a sliding-window circuit breaker, and typed failure
/// classification. The breaker is exposed via [secondaryBreaker] so
/// tests can drive the state transitions without standing up the
/// full pipeline.
class AdvisorRequestPipeline {
  AdvisorRequestPipeline({
    required this.breaker,
    required this.cache,
    this.secondaryLlmProvider,
    Duration secondaryTimeout = const Duration(seconds: 8),
    int secondaryBreakerMaxFailures = 5,
    Duration secondaryBreakerWindow = const Duration(seconds: 60),
    Duration secondaryBreakerOpenDuration = const Duration(seconds: 30),
    DateTime Function() secondaryBreakerClock =
        SecondaryLlmBreaker._defaultClock,
  }) : _secondaryTimeout = secondaryTimeout,
       secondaryBreaker = SecondaryLlmBreaker(
         maxFailures: secondaryBreakerMaxFailures,
         windowDuration: secondaryBreakerWindow,
         openDuration: secondaryBreakerOpenDuration,
         clock: secondaryBreakerClock,
       );

  final CircuitBreaker breaker;
  final AdvisorResponseCache cache;

  /// Phase 11A.4b — optional Gemini Flash secondary. When non-null and
  /// the primary fails (or the breaker is open), the pipeline tries
  /// the secondary BEFORE falling through to the cache. A successful
  /// secondary call returns `fallbackUsed: 'gemini'`. The secondary
  /// is intentionally not protected by its own breaker in this slice
  /// — that is a follow-up.
  final ProxyLlmProvider? secondaryLlmProvider;

  /// CODE_HEALTH L4 — sliding-window breaker scoped to this proxy
  /// instance. Exposed (test seam) so failure / open / half-open /
  /// close transitions can be asserted without round-tripping HTTP.
  final SecondaryLlmBreaker secondaryBreaker;

  final Duration _secondaryTimeout;

  Future<AdvisorPipelineResult> execute({
    required ProxyLlmProvider llmProvider,
    required ProxyLlmRequest llmRequest,
    required String operatorId,
    required String locationId,
    required String queryClass,
    required String questionHash,
    required String corpusVersion,
  }) async {
    final decision = breaker.tryAcquire();
    // Snapshot AFTER tryAcquire so the open→halfOpen promotion that
    // accompanies a canary probe is reflected in the telemetry. The
    // recordSuccess/recordFailure mutations below do not retroactively
    // change this snapshot.
    final circuitStateAtStart = breaker.state;

    if (decision == AcquireDecision.allow ||
        decision == AcquireDecision.allowProbe) {
      try {
        final completion = await llmProvider.complete(llmRequest);
        breaker.recordSuccess();
        return AdvisorPipelineResult(
          completion: completion,
          cachedAnswer: null,
          refused: false,
          circuitStateAtStart: circuitStateAtStart,
          fallbackUsed: 'none',
          decision: decision,
        );
      } catch (error) {
        breaker.recordFailure(classifyLlmFailure(error));
        // Fall through to secondary → cache → refusal.
      }
    }

    // Phase 11A.4b — Gemini Flash secondary fills the slot reserved
    // for E.2b. When the secondary serves successfully, return as a
    // normal HTTP 200 with the Gemini answer — the request did NOT
    // fall to the degraded envelope, so don't flag it as `refused`.
    //
    // CODE_HEALTH L4 — the secondary call is now bounded by an 8s
    // per-call timeout, a sliding-window circuit breaker, and typed
    // exception classification. AuthError / PermanentError do NOT
    // trip the breaker; TimeoutException / RateLimitError /
    // TransientError do. When the breaker is open, we do NOT invoke
    // the underlying gateway at all — the request short-circuits to
    // cache → refusal.
    final secondary = secondaryLlmProvider;
    if (secondary != null && secondaryBreaker.tryAcquire()) {
      try {
        final completion = await secondary
            .complete(llmRequest)
            .timeout(_secondaryTimeout);
        secondaryBreaker.recordSuccess();
        return AdvisorPipelineResult(
          completion: completion,
          cachedAnswer: null,
          refused: false,
          circuitStateAtStart: circuitStateAtStart,
          fallbackUsed: 'gemini',
          decision: decision,
        );
      } on TimeoutException {
        secondaryBreaker.recordFailure(SecondaryLlmFailureKind.timeout);
        // Fall through to cache → refusal.
      } on LLMProviderException catch (error) {
        secondaryBreaker.recordFailure(classifySecondaryLlmFailure(error));
        // Fall through. Auth/Permanent failures still drop us into
        // the degraded envelope; they just don't trip the breaker.
      } catch (error) {
        secondaryBreaker.recordFailure(classifySecondaryLlmFailure(error));
        // Fall through. Intentionally NOT wired into the Anthropic
        // breaker — that breaker tracks the primary only.
      }
    }

    final cachedAnswer = await cache.lookup(
      operatorId: operatorId,
      locationId: locationId,
      queryClass: queryClass,
      questionHash: questionHash,
      corpusVersion: corpusVersion,
    );
    if (cachedAnswer != null) {
      return AdvisorPipelineResult(
        completion: null,
        cachedAnswer: cachedAnswer,
        refused: true,
        circuitStateAtStart: circuitStateAtStart,
        fallbackUsed: 'cache',
        decision: decision,
      );
    }

    return AdvisorPipelineResult(
      completion: null,
      cachedAnswer: null,
      refused: true,
      circuitStateAtStart: circuitStateAtStart,
      fallbackUsed: 'refusal',
      decision: decision,
    );
  }
}

class AdvisorPipelineResult {
  const AdvisorPipelineResult({
    required this.completion,
    required this.cachedAnswer,
    required this.refused,
    required this.circuitStateAtStart,
    required this.fallbackUsed,
    required this.decision,
  });

  /// Non-null when the primary provider served the response.
  final ProxyLlmCompletion? completion;

  /// Non-null when the cache served a previously stored answer.
  final String? cachedAnswer;

  /// True when the breaker decision led to the cache or graceful refusal
  /// branches (i.e. primary did not serve).
  final bool refused;

  final CircuitState circuitStateAtStart;
  final String fallbackUsed;
  final AcquireDecision decision;
}

class AdvisorPromptCacheBuilder {
  const AdvisorPromptCacheBuilder();

  List<ProxyPromptBlock> build({
    required String corpusVersion,
    required String methodologyContext,
    required String toolDefinitions,
    required String operatorContext,
  }) {
    return <ProxyPromptBlock>[
      const ProxyPromptBlock(
        id: 'system_prompt',
        text:
            'You are the Forge & Flow advisor. Ground answers in provided '
            'context and stay recommendation-only.',
        cacheBreakpoint: true,
      ),
      ProxyPromptBlock(
        id: 'tool_definitions',
        text: toolDefinitions,
        cacheBreakpoint: true,
      ),
      ProxyPromptBlock(
        id: 'corpus_context:$corpusVersion',
        text: methodologyContext,
        cacheBreakpoint: true,
      ),
      ProxyPromptBlock(
        id: 'operator_context',
        text: operatorContext,
        cacheBreakpoint: false,
      ),
    ];
  }

  String cacheKeyForCorpusVersion(String corpusVersion) =>
      'advisor-corpus:$corpusVersion';
}

/// Feature flags governing prompt-cache + corpus-invalidation telemetry.
///
/// `cacheTelemetryV2` gates writes to `corpus_invalidation_events` from
/// `OperatorScopedCorpusRepository.commitVersion`. Default `false`; flipped
/// to `true` once the migration has run in staging and the table is
/// observed for one drift cycle.
class ProxyCacheFeatureFlags {
  const ProxyCacheFeatureFlags({this.cacheTelemetryV2 = false});

  final bool cacheTelemetryV2;
}

class ProxyRequestLogPolicy {
  const ProxyRequestLogPolicy({required this.fullContentLoggingEnabled});

  const ProxyRequestLogPolicy.metaOnly() : fullContentLoggingEnabled = false;

  final bool fullContentLoggingEnabled;

  Map<String, Object?> buildEntry({
    required OperatorContext operator,
    required String usageClass,
    required String queryClass,
    required int tokenCount,
    required int costCents,
    required int statusCode,
    String? question,
    String? answer,
  }) {
    final entry = <String, Object?>{
      'operator_id': operator.operatorId,
      'location_id': operator.locationId,
      'usage_class': usageClass,
      'query_class': queryClass,
      'token_count': tokenCount,
      'cost_cents': costCents,
      'status_code': statusCode,
      'content_logging': fullContentLoggingEnabled ? 'full' : 'meta_only',
    };
    if (fullContentLoggingEnabled) {
      entry['question'] = question;
      entry['answer'] = answer;
    }
    return entry;
  }
}

abstract class ProxyUsageLogSql {
  ProxyUsageLogSql._();

  // Phase 9.0Σ.g2 / B33 — usage_logs two-slot writer follow-up to the
  // 202604280006_a/b/c schema flip. The legacy 11-column ON CONFLICT
  // tuple is gone; the locked rollup identity is the named constraint
  // `usage_logs_two_slot_rollup_uq`
  // (operator_id, billing_owner_org_unit_id, scoped_org_unit_id,
  //  location_id, staff_id, workflow_id, usage_class, period_start,
  //  + seven telemetry dims) declared with NULLS NOT DISTINCT.
  //
  // We target the constraint by name rather than inferring from a
  // column list because PG's ON CONFLICT inference assumes
  // NULLS DISTINCT; staff_id / workflow_id stay nullable forever and
  // two NULL-staff rows must collapse onto the same counter, so the
  // named-constraint form is the only correct match.
  //
  // Cap-shape defaulting: when the caller has no narrower org-unit
  // scope (the launch state — operator_id maps 1:1 to a single
  // org_units root row created by 202604280002), billing_owner /
  // scoped fall back via COALESCE to that operator-root. This keeps
  // cap-vs-actual reconciliation joining on the shared cap-shape
  // prefix shared with `usage_caps_two_slot_uq`. staff_id /
  // workflow_id pass through nullable; callers without per-staff or
  // per-workflow attribution send NULL and NULLS NOT DISTINCT folds
  // them onto a single "covers all staff" / "covers all workflows"
  // counter.
  static const String atomicUpsert = '''
insert into public.usage_logs (
  operator_id,
  billing_owner_org_unit_id,
  scoped_org_unit_id,
  location_id,
  staff_id,
  workflow_id,
  usage_class,
  period_start,
  token_count,
  cost_usd,
  request_count,
  query_class,
  cache_hit,
  llm_tier,
  model_used,
  batch_mode,
  circuit_state,
  fallback_used
) values (
  @operator_id,
  coalesce(
    @billing_owner_org_unit_id::uuid,
    (select id
       from public.org_units
      where operator_id = @operator_id
        and parent_id is null
      limit 1)
  ),
  coalesce(
    @scoped_org_unit_id::uuid,
    (select id
       from public.org_units
      where operator_id = @operator_id
        and parent_id is null
      limit 1)
  ),
  @location_id,
  @staff_id::uuid,
  @workflow_id::uuid,
  @usage_class,
  date_trunc('month', @request_time::timestamptz),
  @token_count,
  @cost_usd,
  1,
  @query_class,
  @cache_hit,
  @llm_tier,
  @model_used,
  @batch_mode,
  @circuit_state,
  @fallback_used
)
on conflict on constraint usage_logs_two_slot_rollup_uq do update set
  token_count = public.usage_logs.token_count + excluded.token_count,
  cost_usd = public.usage_logs.cost_usd + excluded.cost_usd,
  request_count = public.usage_logs.request_count + 1,
  updated_at = now()
returning token_count, cost_usd, request_count;
''';

  static const String capStatusSelect = '''
with cap_scope as (
  select
    coalesce(
      @billing_owner_org_unit_id::uuid,
      (select id
         from public.org_units
        where operator_id = @operator_id
          and parent_id is null
        limit 1)
    ) as billing_owner_org_unit_id,
    coalesce(
      @scoped_org_unit_id::uuid,
      (select id
         from public.org_units
        where operator_id = @operator_id
          and parent_id is null
        limit 1)
    ) as scoped_org_unit_id
),
cap as (
  select c.monthly_cap_usd, c.per_invocation_cap_usd
    from public.usage_caps c, cap_scope s
   where c.operator_id = @operator_id
     and c.billing_owner_org_unit_id = s.billing_owner_org_unit_id
     and c.scoped_org_unit_id = s.scoped_org_unit_id
     and c.location_id = @location_id
     and c.staff_id is not distinct from @staff_id::uuid
     and c.workflow_id is not distinct from @workflow_id::uuid
     and c.usage_class = @usage_class
   limit 1
),
actuals as (
  select coalesce(sum(cost_usd), 0) as monthly_used_usd
    from public.usage_logs l, cap_scope s
   where l.operator_id = @operator_id
     and l.billing_owner_org_unit_id = s.billing_owner_org_unit_id
     and l.scoped_org_unit_id = s.scoped_org_unit_id
     and l.location_id = @location_id
     and l.staff_id is not distinct from @staff_id::uuid
     and l.workflow_id is not distinct from @workflow_id::uuid
     and l.usage_class = @usage_class
     and l.period_start = date_trunc('month', @request_time::timestamptz)
)
select
  coalesce((select monthly_cap_usd from cap), 0) as monthly_cap_usd,
  coalesce(
    (select per_invocation_cap_usd from cap),
    0
  ) as per_invocation_cap_usd,
  (select monthly_used_usd from actuals) as monthly_used_usd;
''';

  static const String idempotencyInsert = '''
insert into public.proxy_requests (
  idempotency_key,
  request_type,
  operator_id,
  location_id,
  usage_class,
  response_payload
) values (
  @idempotency_key,
  @request_type,
  @operator_id,
  @location_id,
  @usage_class,
  null
)
on conflict (operator_id, location_id, idempotency_key) do nothing
returning request_id, response_payload;
''';

  static const String idempotencyLookup = '''
select response_payload
  from public.proxy_requests
 where operator_id = @operator_id
   and location_id = @location_id
   and idempotency_key = @idempotency_key
 limit 1;
''';

  static const String completionUpdate = '''
update public.proxy_requests
   set response_payload = @response_payload::jsonb,
       updated_at = @completed_at::timestamptz
 where operator_id = @operator_id
   and location_id = @location_id
   and idempotency_key = @idempotency_key;
''';
}

/// SQL for the Support-logs stats-only telemetry table
/// `public.proxy_request_stats`
/// (202605241500_create_proxy_request_stats.sql; plan §12 phase P1b).
///
/// One row per REAL (non-replayed) LLM request, written from
/// [PostgresProxyAccountingStore.completeRequest] inside the SAME tenant
/// transaction as [ProxyUsageLogSql.completionUpdate] so the stats write
/// adds no extra per-request DB round-trip (CLAUDE.md Cost & Convergence
/// "keep proxy per-request cost low"). STATS ONLY — no message content
/// (the no-content choice is enforced at the schema layer: the table has
/// no content/encrypted columns). `created_at` defaults `now()` and is
/// not written here.
///
/// `request_id` carries the trace uuid the [ProxyUsageLogSql.idempotencyInsert]
/// reservation returned, so each stats row correlates to the same
/// `(operator_id, location_id, request_id)` tenant-leading key on
/// `public.proxy_requests` (an advisory join, not an FK — see the
/// migration header). Idempotency-replay never reaches `completeRequest`
/// (the route early-returns on [ProxyAccountingReplayed]), so no replay
/// can write a duplicate stats row.
abstract class ProxyRequestStatsSql {
  ProxyRequestStatsSql._();

  static const String insert = '''
insert into public.proxy_request_stats (
  operator_id,
  location_id,
  request_id,
  usage_class,
  actor_user_id,
  provider,
  model_id,
  model_version,
  prompt_token_count,
  completion_token_count,
  cost_usd,
  latency_ms,
  result_status
) values (
  @operator_id,
  @location_id,
  @request_id::uuid,
  @usage_class,
  @actor_user_id::uuid,
  @provider,
  @model_id,
  @model_version,
  @prompt_token_count,
  @completion_token_count,
  @cost_usd,
  @latency_ms,
  @result_status
);
''';
}

/// Maps a resolved LLM model identifier to its provider for the
/// `proxy_request_stats.provider` column. The proxy is Anthropic-only at
/// launch; the model id IS the versioned identifier (e.g.
/// `claude-haiku-4-5`), so `model_version` is left null and the version
/// lives in `model_id`. Recognises the `claude-*` (Anthropic) and
/// `gemini-*` / `models/*` (Google) families the proxy LLM routing emits;
/// anything else returns null rather than fabricate a provider.
String? providerFromModelId(String? modelId) {
  if (modelId == null) return null;
  final id = modelId.trim().toLowerCase();
  if (id.isEmpty) return null;
  if (id.startsWith('claude')) return 'anthropic';
  if (id.startsWith('gemini') || id.startsWith('models/')) return 'google';
  return null;
}

// ─── HARD-B — Auth lockout / retry enforcement ──────────────────────────────
//
// Three surfaces share one shape: a rolling-window counter that the
// route handler consults BEFORE the gateway call, and that records
// every attempt the route observes. The contract pins the thresholds:
//
//   * Login (5 failures / 15 minutes per (email_hash, ip_hash))
//     fans out through [AuthLockoutEnforcer] backed by Postgres
//     `auth_login_attempts`. The repo lives in
//     `lib/infrastructure/persistence/postgres/repositories/`.
//
//   * MFA TOTP confirm (3 failures per challenge_id) and password
//     reset request (10 requests / 24h per email_hash) ride
//     in-memory rolling-window counters defined here. Same shape as
//     the HARD-D feature-flag idempotency cache: bounded LRU,
//     volatile across proxy restarts, traded against the cost of a
//     paired Postgres table that this slice does not need.
//
// All three audit-emit through the same `AuthLockoutAuditSink` so a
// fake recorder in tests can assert payload shape without touching
// the production audit fan-out.

const Duration kAuthLoginLockoutWindow = Duration(minutes: 15);
const int kAuthLoginLockoutThreshold = 5;
const Duration kAuthLoginLockoutRetryAfter = Duration(seconds: 900);
const int kAuthMfaTotpRetryThreshold = 3;
const Duration kAuthMfaTotpRetryAfter = Duration(seconds: 30);
const Duration kAuthPasswordResetWindow = Duration(hours: 24);
const int kAuthPasswordResetThreshold = 10;
// B1.S8 — password-reset request rate limits.
// Per-email short window: 1 request per 5 minutes.
const Duration kAuthPasswordResetEmailShortWindow = Duration(minutes: 5);
const int kAuthPasswordResetEmailShortThreshold = 1;
// Per-IP: 50 requests per 24 hours.
const Duration kAuthPasswordResetIpWindow = Duration(hours: 24);
const int kAuthPasswordResetIpThreshold = 50;

class AuthLockoutEvaluation {
  const AuthLockoutEvaluation({
    required this.locked,
    required this.failureCount,
  });

  /// True when the rolling window already contains a `locked` row OR
  /// the failure count meets/exceeds [kAuthLoginLockoutThreshold].
  /// The route returns 423 in this case.
  final bool locked;

  /// Number of `(failure, locked)` rows in the window. Audit rows
  /// carry this so investigators can correlate the count at trip-time
  /// without re-querying.
  final int failureCount;
}

/// Outcome of a credential attempt the route reports. The contract
/// pins the value set:
///
///   * `bad_password`   — Firebase rejected the password.
///   * `unknown_user`   — Firebase reported the email is not enrolled.
///   * `mfa_required`   — Firebase issued an MFA challenge.
///   * `mfa_failed`     — Firebase rejected the MFA proof.
///
/// The set is closed: any other value is rejected at the route
/// boundary (400 `invalid_failure_outcome`).
abstract class AuthLoginFailureOutcomes {
  AuthLoginFailureOutcomes._();

  static const String badPassword = 'bad_password';
  static const String unknownUser = 'unknown_user';
  static const String mfaRequired = 'mfa_required';
  static const String mfaFailed = 'mfa_failed';

  static const Set<String> all = <String>{
    badPassword,
    unknownUser,
    mfaRequired,
    mfaFailed,
  };
}

/// Audit sink the lockout enforcer + retry counters write through.
/// The production binding fans out into the hash-chained `audit_logs`
/// table (`auth.login_failed`, `auth.account_locked`,
/// `auth.mfa_retry_exceeded`, `auth.password_reset_throttled`); tests
/// inject [InMemoryAuthLockoutAuditSink] to assert payload shape +
/// sensitive-field redaction.
abstract class AuthLockoutAuditSink {
  Future<void> recordLoginFailed({
    required String emailHashHex,
    required String ipHashHex,
    required String outcome,
    required int attemptCountInWindow,
    required bool locked,
    String? operatorId,
    String? locationId,
    String? actorUserId,
  });

  /// Records an `auth.account_locked` event. When the success-path
  /// pre-check trips a lock, the route knows the verified
  /// `actorUserId`; passing it through here lets the production sink
  /// fan the row out into the per-tenant `audit_logs` chain. Anonymous
  /// failure-report locks pass `actorUserId = null` and stay in
  /// `auth_events_audit` only (audit_logs is per-(operator_id,
  /// chain_date), so events with no resolvable operator have no chain
  /// to land in -- documented in
  /// `docs/contracts/hardening_auth_protection_contract.md`).
  Future<void> recordAccountLocked({
    required String emailHashHex,
    required String ipHashHex,
    required int attemptCount,
    required DateTime lockoutUntil,
    String? operatorId,
    String? locationId,
    String? actorUserId,
  });

  Future<void> recordMfaRetryExceeded({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String challengeIdHash,
    required int retryCount,
  });

  Future<void> recordPasswordResetThrottled({
    required String emailHashHex,
    required int attemptCountIn24h,
    required Duration retryAfter,
  });
}

class InMemoryAuthLockoutAuditSink implements AuthLockoutAuditSink {
  final List<Map<String, Object?>> events = <Map<String, Object?>>[];

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
    events.add(<String, Object?>{
      'event_type': 'auth.login_failed',
      'email_hash': emailHashHex,
      'ip_hash': ipHashHex,
      'outcome': outcome,
      'attempt_count_in_window': attemptCountInWindow,
      'locked': locked,
      if (operatorId != null) 'operator_id': operatorId,
      if (locationId != null) 'location_id': locationId,
      if (actorUserId != null) 'actor_user_id': actorUserId,
    });
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
    events.add(<String, Object?>{
      'event_type': 'auth.account_locked',
      'email_hash': emailHashHex,
      'ip_hash': ipHashHex,
      'attempt_count': attemptCount,
      'lockout_until': lockoutUntil.toUtc().toIso8601String(),
      if (operatorId != null) 'operator_id': operatorId,
      if (locationId != null) 'location_id': locationId,
      if (actorUserId != null) 'actor_user_id': actorUserId,
    });
  }

  @override
  Future<void> recordMfaRetryExceeded({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String challengeIdHash,
    required int retryCount,
  }) async {
    events.add(<String, Object?>{
      'event_type': 'auth.mfa_retry_exceeded',
      'operator_id': operatorId,
      'location_id': locationId,
      'actor_user_id': actorUserId,
      'challenge_id_hash': challengeIdHash,
      'retry_count': retryCount,
    });
  }

  @override
  Future<void> recordPasswordResetThrottled({
    required String emailHashHex,
    required int attemptCountIn24h,
    required Duration retryAfter,
  }) async {
    events.add(<String, Object?>{
      'event_type': 'auth.password_reset_throttled',
      'email_hash': emailHashHex,
      'attempt_count_24h': attemptCountIn24h,
      'retry_after_seconds': retryAfter.inSeconds,
    });
  }
}

/// HARD-B abstraction over the Postgres `auth_login_attempts` table.
/// One implementation lives in `proxy_bootstrap.dart`
/// (`PostgresAuthLockoutEnforcer`); tests inject
/// [InMemoryAuthLockoutEnforcer]. The route handler depends on this
/// surface only — no `package:postgres` import on the proxy boundary.
abstract class AuthLockoutEnforcer {
  /// Reads the rolling-window failure count for the (email, ip) pair
  /// and returns the lockout decision.
  Future<AuthLockoutEvaluation> evaluate({
    required String email,
    required String ip,
  });

  /// Records one `outcome: failure` row (anonymous scope when
  /// [operatorId] is null; tenant scope otherwise) and returns the
  /// post-write count.
  Future<int> recordFailure({
    required String email,
    required String ip,
    String? userAgentClass,
    String? operatorId,
    String? locationId,
    String? actorUserId,
  });

  /// Records one `outcome: locked` row at the threshold trip.
  Future<void> recordLocked({
    required String email,
    required String ip,
    String? userAgentClass,
  });

  /// Records one `outcome: success` row attributed to the resolved
  /// tenant. Used after a verified Firebase login completes
  /// successfully so the audit trail carries both successes + failures.
  Future<void> recordSuccess({
    required String email,
    required String ip,
    required String operatorId,
    required String locationId,
    required String actorUserId,
    String? userAgentClass,
  });
}

/// Test-only enforcer. Tracks failures in a Map keyed by the same
/// SHA-256(email):SHA-256(ip) shape the production path uses so tests
/// can assert hash collisions / window boundaries deterministically.
class InMemoryAuthLockoutEnforcer implements AuthLockoutEnforcer {
  InMemoryAuthLockoutEnforcer({
    this.window = kAuthLoginLockoutWindow,
    this.threshold = kAuthLoginLockoutThreshold,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration window;
  final int threshold;
  final DateTime Function() _now;

  /// All recorded attempts in insertion order. Tests assert on length
  /// + outcome distribution.
  final List<InMemoryAuthAttempt> attempts = <InMemoryAuthAttempt>[];

  String _emailKey(String email) {
    final normalized = email.trim().toLowerCase();
    return sha256.convert(utf8.encode(normalized)).toString();
  }

  String _ipKey(String ip) => sha256.convert(utf8.encode(ip.trim())).toString();

  Iterable<InMemoryAuthAttempt> _failuresInWindow(String email, String ip) {
    final cutoff = _now().toUtc().subtract(window);
    final emailKey = _emailKey(email);
    final ipKey = _ipKey(ip);
    // Per the contract reset semantics: a successful login inside the
    // window resets the failure count for that (email, ip) pair, so
    // only failures attempted *after* the most recent success in the
    // window participate in the lockout count.
    DateTime? latestSuccessAt;
    for (final attempt in attempts) {
      if (attempt.emailHashHex == emailKey &&
          attempt.ipHashHex == ipKey &&
          attempt.attemptedAt.isAfter(cutoff) &&
          attempt.outcome == 'success' &&
          (latestSuccessAt == null ||
              attempt.attemptedAt.isAfter(latestSuccessAt))) {
        latestSuccessAt = attempt.attemptedAt;
      }
    }
    final effectiveCutoff = latestSuccessAt ?? cutoff;
    return attempts.where(
      (attempt) =>
          attempt.emailHashHex == emailKey &&
          attempt.ipHashHex == ipKey &&
          attempt.attemptedAt.isAfter(effectiveCutoff) &&
          (attempt.outcome == 'failure' || attempt.outcome == 'locked'),
    );
  }

  @override
  Future<AuthLockoutEvaluation> evaluate({
    required String email,
    required String ip,
  }) async {
    final failures = _failuresInWindow(email, ip).toList();
    final locked =
        failures.any((attempt) => attempt.outcome == 'locked') ||
        failures.length >= threshold;
    return AuthLockoutEvaluation(locked: locked, failureCount: failures.length);
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
    attempts.add(
      InMemoryAuthAttempt(
        emailHashHex: _emailKey(email),
        ipHashHex: _ipKey(ip),
        outcome: 'failure',
        attemptedAt: _now().toUtc(),
        operatorId: operatorId,
        locationId: locationId,
      ),
    );
    return _failuresInWindow(email, ip).length;
  }

  @override
  Future<void> recordLocked({
    required String email,
    required String ip,
    String? userAgentClass,
  }) async {
    attempts.add(
      InMemoryAuthAttempt(
        emailHashHex: _emailKey(email),
        ipHashHex: _ipKey(ip),
        outcome: 'locked',
        attemptedAt: _now().toUtc(),
      ),
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
    attempts.add(
      InMemoryAuthAttempt(
        emailHashHex: _emailKey(email),
        ipHashHex: _ipKey(ip),
        outcome: 'success',
        attemptedAt: _now().toUtc(),
        operatorId: operatorId,
        locationId: locationId,
      ),
    );
  }
}

class InMemoryAuthAttempt {
  InMemoryAuthAttempt({
    required this.emailHashHex,
    required this.ipHashHex,
    required this.outcome,
    required this.attemptedAt,
    this.operatorId,
    this.locationId,
  });

  final String emailHashHex;
  final String ipHashHex;
  final String outcome;
  final DateTime attemptedAt;
  final String? operatorId;
  final String? locationId;
}

/// In-memory rolling-window counter. Used for the MFA TOTP retry cap
/// (3 / per-challenge) and the password-reset 24h cap (10 / per-email).
/// Bounded LRU so a long-running proxy cannot leak unbounded memory
/// across an attacker-controlled key flood.
class RollingWindowAttemptCounter {
  RollingWindowAttemptCounter({
    required this.window,
    this.maxEntries = 4096,
    DateTime Function()? now,
  }) : assert(maxEntries > 0, 'maxEntries must be positive'),
       _now = now ?? DateTime.now;

  final Duration window;
  final int maxEntries;
  final DateTime Function() _now;

  /// Insertion-ordered map so the oldest entry is the first key. Two
  /// concurrent paths share the map under the assumption that Dart's
  /// single-threaded event loop serializes the synchronous prefix of
  /// each method (no `await` between mutations of `_attempts`).
  final Map<String, List<DateTime>> _attempts = <String, List<DateTime>>{};

  /// Increments the counter for [key] and returns the post-write
  /// count of attempts inside the rolling window.
  int incrementAndCount(String key) {
    final now = _now().toUtc();
    final cutoff = now.subtract(window);
    _evictExpired(cutoff);
    if (!_attempts.containsKey(key) && _attempts.length >= maxEntries) {
      _attempts.remove(_attempts.keys.first);
    }
    final entries = _attempts.putIfAbsent(key, () => <DateTime>[]);
    entries.add(now);
    return entries.length;
  }

  /// Resets the counter for [key]. Called on a successful confirm
  /// (MFA) or successful reset.
  void reset(String key) {
    _attempts.remove(key);
  }

  /// Counts the existing attempts in the window WITHOUT incrementing.
  int countInWindow(String key) {
    final cutoff = _now().toUtc().subtract(window);
    final entries = _attempts[key];
    if (entries == null) return 0;
    entries.removeWhere((t) => !t.isAfter(cutoff));
    if (entries.isEmpty) {
      _attempts.remove(key);
      return 0;
    }
    return entries.length;
  }

  void _evictExpired(DateTime cutoff) {
    _attempts.removeWhere((_, entries) {
      entries.removeWhere((t) => !t.isAfter(cutoff));
      return entries.isEmpty;
    });
  }
}

/// Slice A11.1 — production session-record completeness gauge.
///
/// In-process counter that observes 2xx responses from session-finalizing
/// proxy routes (today: `POST /v1/auth/session/login`) and increments
/// `proxy.session_record.incomplete{route, missing_field}` whenever the
/// response body fails [SessionRecordCompleteness.assertComplete].
///
/// Authority: addendum B2 / R3 §2 stretch goal — "promote the predicate
/// to a production gauge" (per
/// `docs/archive/_execution/lane_a_code_health/01_product_rule_and_ia.md` and
/// `docs/archive/_execution/lane_a_code_health/03_execution_slices.md` Slice
/// A11.1).
///
/// Discipline:
///   - **Observability-only.** [observe] never throws and never alters
///     the response. The 2xx ships either way; the gauge surfaces the
///     bug for the ops console + soak harnesses.
///   - **No tenant identifiers.** Labels carry only `route` (proxy path
///     constant) and `missing_field` (predicate-defined field name). The
///     gauge is global-cardinality across operators, mirroring the rest
///     of `health_producers/infra_producers.dart`.
///   - **No PII.** No email, IP, user_id, operator_id, location_id, or
///     session_id ever enters the counter map. Predicate output names
///     fields, not values.
class SessionRecordIncompleteGauge {
  SessionRecordIncompleteGauge();

  /// route -> {missing_field -> count}. Insertion-ordered so a snapshot
  /// reads stably for tests + the deep-health envelope.
  final Map<String, Map<String, int>> _counts = <String, Map<String, int>>{};

  /// Run the predicate against [body] and increment the per-(route,
  /// missing_field) counter for every field the predicate flagged. Pass
  /// the JWT roles set the route resolved so the predicate can pick the
  /// tenant-scoped vs global-admin shape (see
  /// [SessionRecordCompleteness.assertComplete]).
  ///
  /// Returns the [SessionRecordAssertion] for callers that want to log
  /// the result alongside their existing diagnostic line; the assertion
  /// is informational — the route MUST NOT branch on it (the 2xx already
  /// shipped). Returns a `complete: true` assertion on any predicate
  /// throw so a malformed body or unexpected predicate failure cannot
  /// crash the response path.
  SessionRecordAssertion observe({
    required String route,
    required Map<String, Object?> body,
    required Set<String> roles,
  }) {
    SessionRecordAssertion assertion;
    try {
      assertion = SessionRecordCompleteness.assertComplete(body, roles: roles);
    } catch (_) {
      // Defensive: a predicate throw must never alter the 2xx. Treat as
      // "complete" for observability purposes; the soak harness covers
      // the structural correctness of the predicate itself.
      return const SessionRecordAssertion(
        complete: true,
        missingFields: <String>[],
        unexpectedFields: <String>[],
      );
    }
    if (assertion.complete) return assertion;
    final routeBucket = _counts.putIfAbsent(route, () => <String, int>{});
    for (final field in assertion.missingFields) {
      routeBucket[field] = (routeBucket[field] ?? 0) + 1;
    }
    for (final field in assertion.unexpectedFields) {
      // Unexpected (global-admin contract violation: scope was non-empty
      // when it should have been empty) is a separate failure mode but
      // shares the same gauge — the label encodes the kind via prefix.
      final key = 'unexpected_$field';
      routeBucket[key] = (routeBucket[key] ?? 0) + 1;
    }
    return assertion;
  }

  /// Snapshot the per-route, per-missing-field counts for the deep-health
  /// envelope or the soak harness assertion. The returned map is a deep
  /// copy so the caller cannot mutate the gauge state.
  Map<String, Map<String, int>> snapshot() {
    return <String, Map<String, int>>{
      for (final entry in _counts.entries)
        entry.key: Map<String, int>.from(entry.value),
    };
  }

  /// Total increment count across every route + missing_field. Used by
  /// the deep-health producer for a single coarse gauge value.
  int totalIncrements() {
    var total = 0;
    for (final routeBucket in _counts.values) {
      for (final count in routeBucket.values) {
        total += count;
      }
    }
    return total;
  }

  /// Test-only / startup hook for resetting state between scenarios.
  void reset() {
    _counts.clear();
  }
}

/// Centralised hashing helpers shared between [InMemoryAuthLockoutEnforcer]
/// and the route handler so audit payloads carry the same hex digest
/// the lockout query keyed against.
String hashAuthEmailHex(String email) {
  final normalized = email.trim().toLowerCase();
  return sha256.convert(utf8.encode(normalized)).toString();
}

String hashAuthIpHex(String ip) {
  return sha256.convert(utf8.encode(ip.trim())).toString();
}

const String healthPath = '/healthz';
const String readinessPath = '/readyz';
const String deepHealthPath = '/health';
const String scopeSmokePath = '/v1/scope';
const String usageSmokePath = '/v1/usage-smoke';
const String advisorSmokePath = '/v1/advisor-smoke';

// Phase 10a.4 — bridge tripwire status route. Read-only, platform-wide
// aggregate (no tenant identifiers in payload), polled by the sync
// badge every ~60s so the badge can shift to "Degraded" when ANY of
// the four Q22 metrics fires red even while the WebSocket connection
// is alive. Production wiring in `main.dart` runs the four producers
// through the admin pool's `runAsSystem` (same pattern as
// `_PostgresOperatorDiscoverer`) and packs them into the evaluator.
const String realtimeTripwireStatusPath = '/v1/realtime/tripwire-status';

// Phase 9 live-closeout - auth operations / permission snapshot routes.
const String authAccountInfoPath = '/v1/auth/account';
const String authPermissionsSnapshotPath = '/v1/auth/permissions/snapshot';
const String authPasswordChangePath = '/v1/auth/password/change';
const String authPasswordResetRequestPath = '/v1/auth/password/reset/request';
const String authPasswordResetConfirmPath = '/v1/auth/password/reset/confirm';
const String authMfaTotpBeginPath = '/v1/auth/mfa/totp/begin';
const String authMfaTotpConfirmPath = '/v1/auth/mfa/totp/confirm';
const String authMfaRecoveryRequestPath = '/v1/auth/mfa/recovery/request';
const String authMfaFactorsListPath = '/v1/auth/mfa/factors/list';
const String authMfaFactorsRevokePath = '/v1/auth/mfa/factors/revoke';
const String authMfaRecoveryCodesViewedPath =
    '/v1/auth/mfa/recovery-codes/viewed';
const String authMfaFactorsRemovalCancelPath =
    '/v1/auth/mfa/factors/removal/cancel';
const String authMobilePushTokenRegisterPath =
    '/v1/auth/mobile/push-token/register';
const String authMobilePushTokenRevokePath =
    '/v1/auth/mobile/push-token/revoke';
const String authMobilePushTestPath = '/v1/auth/mobile/push/test';
const String mobileOperatorsPrefix = '/v1/operators/';
const String adminAuthInvitesPath = '/v1/admin/auth/invites';
const String adminAuthInvitePrefix = '$adminAuthInvitesPath/';
const String adminAuthUsersPath = '/v1/admin/auth/users';
const String adminAuthUsersPrefix = '/v1/admin/auth/users/';
const String adminAuthRolesPath = '/v1/admin/auth/roles';
const String adminAuthRolePrefix = '$adminAuthRolesPath/';
const String adminAuthRoleGrantsPath = '/v1/admin/auth/role-grants';
const String adminAuthRoleGrantPrefix = '$adminAuthRoleGrantsPath/';
const String adminAuthSessionsPath = '/v1/admin/auth/sessions';
const String adminAuthSessionsPrefix = '$adminAuthSessionsPath/';
const String adminAuthAuditLogPath = '/v1/admin/auth/audit-log';
const String authTeamInvitesPath = '/v1/auth/team/invites';
const String authTeamInvitePrefix = '$authTeamInvitesPath/';
const String authTeamUsersPath = '/v1/auth/team/users';
const String authTeamUsersPrefix = '/v1/auth/team/users/';
const String authTeamRolesPath = '/v1/auth/team/roles';
const String authTeamRolePrefix = '$authTeamRolesPath/';
const String authTeamRoleGrantsPath = '/v1/auth/team/role-grants';
const String authTeamRoleGrantPrefix = '$authTeamRoleGrantsPath/';
// Phase 9.UX.4 — org hierarchy admin routes. Reads gate on
// `team.users.view`, mutations on `team.roles.assign` (per the
// hierarchy-touches-grants posture from `phase_9_auth_plan.md`).
const String adminAuthOrgUnitsPath = '/v1/admin/auth/org-units';
const String adminAuthOrgUnitPrefix = '$adminAuthOrgUnitsPath/';
const String adminAuthLocationsPrefix = '/v1/admin/auth/locations/';
const String authTeamOrgUnitsPath = '/v1/auth/team/org-units';
const String authTeamOrgUnitPrefix = '$authTeamOrgUnitsPath/';
const String authTeamLocationsPrefix = '/v1/auth/team/locations/';
const String adminServicePrincipalsPath = '/v1/admin/service-principals';
const String adminServicePrincipalsPrefix = '$adminServicePrincipalsPath/';

// Phase 11A.1 — Operator + location admin routes. F&F internal-only;
// caller must be a `super_admin` Firebase user. The
// admin Flutter client never touches Postgres directly; every
// operator/location write fans through these routes which delegate
// to an injected [OperatorLocationAdminProxyGateway].
const String adminOperatorsPath = '/v1/admin/operators';
const String adminOperatorsPrefix = '$adminOperatorsPath/';
const String adminLocationsPath = '/v1/admin/locations';
const String adminLocationsPrefix = '$adminLocationsPath/';

// Phase 11A.2 — Pricing tier admin routes. F&F internal-only with a
// method-scoped role split: GET admits `super_admin` and `ff_support`
// so support users can load the read-only pricing view in live mode;
// PATCH / PUT / POST stay strictly `super_admin` because pricing
// changes affect billing posture. Operator-side roles are rejected
// at the proxy layer for every method. See [kFfPricingAdminReadRoles]
// and [kFfPricingAdminWriteRoles].
const String adminPricingOperatorsPath = '/v1/admin/pricing/operators';
const String adminPricingOperatorsPrefix = '$adminPricingOperatorsPath/';
const String adminPricingUsageCapsPath = '/v1/admin/pricing/usage-caps';

// Plans & Limits V1 Phase 3 — editable plan-pricing catalog. GET lists
// every plan's pricing (gated by the read role set); PATCH on
// `/plans/{tier_key}` edits one plan's pricing (write role set, MFA,
// idempotent + audited). Backed by the GLOBAL `pricing_plan_catalog`
// table (no operator_id, no RLS — admin-pool BYPASSRLS posture).
const String adminPricingPlansPath = '/v1/admin/pricing/plans';
const String adminPricingPlansPrefix = '$adminPricingPlansPath/';

// Plans & Limits V1 Phase 5a — editable feature-entitlements matrix. GET
// lists every (plan, feature) row (gated by the read role set); PATCH on
// `/entitlements/{tier_key}/{feature_slug}` toggles one pair (write role
// set, MFA, idempotent + audited). Backed by the GLOBAL
// `feature_entitlements` table (no operator_id, no RLS — admin-pool
// BYPASSRLS posture, exactly like `pricing_plan_catalog`). FOUNDATION
// ONLY: records the matrix; does not gate the app (deferred Phase 5d).
const String adminPricingEntitlementsPath = '/v1/admin/pricing/entitlements';
const String adminPricingEntitlementsPrefix = '$adminPricingEntitlementsPath/';
const String adminPricingScopedContractsPath =
    '/v1/admin/pricing/scoped-contracts';
const String adminPricingScopedContractsPrefix =
    '$adminPricingScopedContractsPath/';
const String adminPricingScopedContractsEffectivePath =
    '$adminPricingScopedContractsPath/effective';

/// Locked feature slugs the proxy accepts on the entitlements PATCH.
/// Mirrors `kFeatureSlugCatalog` in
/// `lib/admin/models/pricing_tier_admin_models.dart`. Keep in sync.
/// `advisor` covers the AI advisor / manager chatbot — there is no
/// separate "chatbots" product concept.
const Set<String> kProxyFeatureSlugKeys = <String>{
  'advisor',
  'lms',
  'scoreboard',
  'staff_coach',
  'sops',
  'workflows',
};

// Phase 8 spine-bridge .C -- Data Accuracy + Polling & Pricing admin
// routes. This surface is separate from 11A.2 pricing caps: it exposes
// per-location data accuracy settings, polling tier assignments, and
// internal margin rollups for F&F operators.
const String adminDataAccuracyRowsPath = '/v1/admin/data-accuracy/rows';
const String adminDataAccuracySettingsPath = '/v1/admin/data-accuracy/settings';
const String adminDataAccuracySettingsPrefix =
    '$adminDataAccuracySettingsPath/';
const String adminDataAccuracyServicePeriodSettingsPath =
    '/v1/admin/data-accuracy/service-period-settings';
const String adminDataAccuracyServicePeriodSettingsPrefix =
    '$adminDataAccuracyServicePeriodSettingsPath/';
const String adminDataAccuracyScopedSettingsPath =
    '/v1/admin/data-accuracy/scoped-settings';
const String adminDataAccuracyAuditHistoryPath =
    '/v1/admin/data-accuracy/audit-history';
const String adminPollingPricingTierDefinitionsPath =
    '/v1/admin/polling-pricing/tier-definitions';
const String adminPollingPricingTierDefinitionsPrefix =
    '$adminPollingPricingTierDefinitionsPath/';
const String adminPollingPricingAssignmentsPath =
    '/v1/admin/polling-pricing/assignments';
const String adminPollingPricingAssignmentsPrefix =
    '$adminPollingPricingAssignmentsPath/';
const String adminPollingPricingScopedAssignmentsPath =
    '/v1/admin/polling-pricing/scoped-assignments';
const String adminPollingPricingMarginPath = '/v1/admin/polling-pricing/margin';
const String adminPollingPricingMarginExportPath =
    '/v1/admin/polling-pricing/margin/export-csv';
const String adminPollingPricingChangeRequestsPath =
    '/v1/admin/polling-pricing/change-requests';
const String adminPollingPricingChangeRequestsPrefix =
    '$adminPollingPricingChangeRequestsPath/';
const String adminVendorApplicabilityPath = '/v1/admin/vendor-applicability';
const String operatorVendorApplicabilityPath =
    '/v1/operator/vendor-applicability';

const Set<String> kFfDataAccuracyAdminWriteRoles = <String>{'super_admin'};
const Set<String> kFfDataAccuracyAdminReadRoles = <String>{
  'super_admin',
  'ff_support',
};
const Set<String> kFfVendorApplicabilityAdminRoles = <String>{'super_admin'};

/// Roles that admit a caller to the pricing admin **write** surface
/// (PATCH / PUT / POST). Super-admin-only by design; pricing
/// decisions sit on the billing posture so support roles do not get
/// a write path here.
const Set<String> kFfPricingAdminWriteRoles = <String>{'super_admin'};

/// Roles that admit a caller to the pricing admin **read** surface
/// (GET). `ff_support` joins `super_admin` here so the read-only
/// pricing view actually loads for support users — without this the
/// initial GET 403s before the client can render the read-only
/// banner. Mirrors the read/write split asserted by the screen
/// shell tests in `test/admin_pricing_tier_screen_test.dart`.
const Set<String> kFfPricingAdminReadRoles = <String>{
  'super_admin',
  'ff_support',
};

/// Backwards-compatible alias for the write-only set. Existing call
/// sites that read this name now get the strict super_admin-only set.
const Set<String> kFfPricingAdminRoles = kFfPricingAdminWriteRoles;

/// Locked tier-template keys the proxy accepts on `apply-template`.
/// Mirrors `kPricingTierTemplates` in
/// `lib/admin/models/pricing_tier_admin_models.dart`. Keep in sync.
const Set<String> kProxyPricingTierTemplateKeys = <String>{
  'pilot',
  'starter',
  'premium',
  'elite',
  'pro',
  'enterprise',
};

/// Plans & Limits V1 Phase 4a — default Pilot free-trial window in days.
/// The start-pilot route sets `operators.trial_expires_at = now() + this
/// many days` when the request omits an explicit `trial_days`. 30 days is
/// the standard free-preview window from the reconciled pricing model
/// (`docs/phases/phase_11a/phase_11a_decision_register.md`).
const int kPilotTrialDefaultDays = 30;

/// Plans & Limits V1 Phase 4a — upper bound on an explicitly-requested
/// Pilot trial window so a caller cannot provision an unbounded trial.
/// One year is generous for a free preview; anything longer should be a
/// deliberate plan/pricing decision, not a trial flag.
const int kPilotTrialMaxDays = 365;

/// Validation error raised by [PricingTierAdminProxyGateway]
/// implementations when a request is rejected for business reasons
/// (e.g. operator missing a primary_location_id). The proxy
/// route handler maps it back to a structured 4xx response.
class PricingTierAdminGatewayValidationError implements Exception {
  const PricingTierAdminGatewayValidationError({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() =>
      'PricingTierAdminGatewayValidationError($statusCode/$code): $message';
}

/// Gateway the proxy delegates to for `/v1/admin/pricing/*` route
/// handling. Returns JSON-ready maps so the proxy handler can wrap
/// them in a 200/201 response without translating shapes a second
/// time.
abstract class PricingTierAdminProxyGateway {
  /// Returns `[{'operator': {...}, 'caps': [{...}, ...]}]` across
  /// every operator. Sorted by `business_name` so the admin console
  /// renders deterministically.
  Future<List<Map<String, Object?>>> listOperatorsWithCaps({
    required String actorUserId,
    required String adminReason,
  });

  /// PATCH `operators.subscription_tier`. Returns the bundle for the
  /// operator post-update, or null when the operator was not found.
  Future<Map<String, Object?>?> updateOperatorTier({
    required String actorUserId,
    required String operatorId,
    required String subscriptionTier,
    required String adminReason,
  });

  /// UPSERT one cap row keyed on the post-9.0Σ.g logical key
  /// `(operator_id, billing_owner_org_unit_id, scoped_org_unit_id,
  /// location_id, staff_id, workflow_id, usage_class)` enforced by
  /// the `usage_caps_two_slot_uq` UNIQUE NULLS NOT DISTINCT
  /// constraint. NULL `staff_id` / `workflow_id` rows still collide
  /// on the cap identity. The production gateway resolves the
  /// operator's root `org_units` row and passes its id for both
  /// org-unit axes (corp pays for corp scope). Returns the upserted
  /// cap row JSON.
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
  });

  /// Apply a tier template: update `operators.subscription_tier` and
  /// upsert each cap row from the template under one admin reason.
  /// Returns the bundle for the operator post-application, or null
  /// when the operator was not found.
  Future<Map<String, Object?>?> applyTierTemplate({
    required String actorUserId,
    required String operatorId,
    required String tierKey,
    required String adminReason,
  });

  /// DELETE one cap row. Identified by [capId] when provided, else by
  /// the logical key `(operator_id, location_id, usage_class, staff_id,
  /// workflow_id)`. Returns `true` when a row was deleted, `false` when
  /// no matching cap existed so the route can answer 404 honestly.
  Future<bool> deleteUsageCap({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String usageClass,
    String? staffId,
    String? workflowId,
    String? capId,
    required String adminReason,
  });

  /// Month-to-date spend per `(location_id, usage_class)` for one
  /// operator alongside the cap, reusing the cap-enforcement
  /// `usage_logs` SUM(cost_usd)-for-period grain. Returns
  /// `[{'location_id': ..., 'usage_class': ..., 'spend_usd': ...}]`, or
  /// null when the operator was not found.
  Future<List<Map<String, Object?>>?> monthToDateSpendSummary({
    required String actorUserId,
    required String operatorId,
    required String adminReason,
  });

  /// Phase 3 — list the editable plan-pricing catalog. Returns one map
  /// per plan (`tier_key` + pricing fields + `updated_at` / `updated_by`),
  /// in the canonical ladder order so the admin console renders
  /// deterministically.
  Future<List<Map<String, Object?>>> listPlanCatalog({
    required String actorUserId,
    required String adminReason,
  });

  /// Phase 3 — edit one plan's pricing. Returns the updated catalog row
  /// JSON, or null when [tierKey] is not a known plan so the route can
  /// answer 404 honestly. Money / band fields are nullable (genuine SQL
  /// NULL: Enterprise has no monthly price; no-seat plans have null seat
  /// fees).
  Future<Map<String, Object?>?> updatePlanPricing({
    required String actorUserId,
    required String tierKey,
    required double? monthlyUsd,
    required int? firstNSeats,
    required double? firstSeatUsd,
    required double? additionalSeatUsd,
    required double? onboardingMinUsd,
    required double? onboardingMaxUsd,
    required String adminReason,
  });

  /// Phase 5a — list the editable feature-entitlements matrix. Returns one
  /// map per (plan, feature) pair (`tier_key` + `feature_slug` + `enabled`
  /// + `updated_at` / `updated_by`), ordered so the admin matrix renders
  /// deterministically.
  Future<List<Map<String, Object?>>> listEntitlements({
    required String actorUserId,
    required String adminReason,
  });

  /// Phase 5a — toggle one plan/feature pair's `enabled` flag. Returns the
  /// resulting entitlement row JSON. The route validates `tierKey` (six
  /// keys) + `featureSlug` (known catalog) before this call, so this never
  /// sees an unknown pair; the gateway UPSERTs so a known-but-unseeded
  /// pair is created on first toggle.
  Future<Map<String, Object?>> setEntitlement({
    required String actorUserId,
    required String tierKey,
    required String featureSlug,
    required bool enabled,
    required String adminReason,
  });

  /// Plans & Limits V1 Phase 4a — start a Pilot free trial on a real
  Future<Map<String, Object?>?> resolveScopedContract({
    required String actorUserId,
    required String operatorId,
    required String scopeType,
    String? orgUnitId,
    String? locationId,
    required String adminReason,
  });

  Future<Map<String, Object?>?> saveScopedContract({
    required String actorUserId,
    required String operatorId,
    required String scopeType,
    String? orgUnitId,
    String? locationId,
    required String tierKey,
    String? billingOwnerOrgUnitId,
    double? monthlyUsd,
    int? firstNSeats,
    double? firstSeatUsd,
    double? additionalSeatUsd,
    double? onboardingMinUsd,
    double? onboardingMaxUsd,
    double? advisorCapMonthlyUsd,
    String? effectiveFrom,
    String? effectiveUntil,
    String? contractLabel,
    String? internalNote,
    String? contractOverrideId,
    required String adminReason,
  });

  Future<Map<String, Object?>?> deleteScopedContract({
    required String actorUserId,
    required String operatorId,
    required String scopeType,
    String? orgUnitId,
    String? locationId,
    required String contractOverrideId,
    required String adminReason,
  });

  /// operator. Sets `subscription_tier = 'pilot'`, `trial_mode = true`,
  /// and `trial_expires_at = now() + [trialDays] days`. Returns the
  /// post-update operator bundle (same shape as [updateOperatorTier]),
  /// or null when the operator was not found so the route answers 404.
  ///
  /// HP #2: this only flips the trial FLAG + tier on a REAL operator. It
  /// does NOT seed sample data and does NOT create any `demo_*` table —
  /// Pilot is a trial flag on a real operator, not a second demo mode.
  /// Sample-data seeding for the preview is a writer-side (client
  /// SQLite) concern handled separately (see the route handler note).
  Future<Map<String, Object?>?> startPilotTrial({
    required String actorUserId,
    required String operatorId,
    required int trialDays,
    required String adminReason,
  });

  /// Plans & Limits V1 Phase 4a — convert a Pilot trial to Starter (the
  /// "real POS / labor connector succeeded" conversion). Clears the
  /// trial flag (`trial_mode = false`, `trial_expires_at = null`) and
  /// moves `subscription_tier` from `'pilot'` to `'starter'`. Idempotent:
  /// only an operator currently on the Pilot trial is promoted; a
  /// non-trial / already-converted operator is a no-op.
  ///
  /// Returns a [TrialConversionOutcome] discriminating three cases so
  /// the route answers honestly: operator missing (404), converted
  /// (200), or already-converted / not-on-trial (200, no-op).
  Future<TrialConversionOutcome> convertTrialToStarter({
    required String actorUserId,
    required String operatorId,
    required String adminReason,
  });
}

/// Wire-level outcome of [PricingTierAdminProxyGateway.convertTrialToStarter].
/// Decouples the proxy abstraction from the repository's
/// `TrialConversionResult` so test fakes do not need to import the
/// persistence layer. [bundle] is the post-update operator bundle when
/// [converted] is true OR when the operator already off-trial (no-op);
/// null only when the operator was not found.
class TrialConversionOutcome {
  const TrialConversionOutcome({
    required this.operatorFound,
    required this.converted,
    required this.bundle,
  });

  /// Convenience constructor: operator not found (route → 404).
  const TrialConversionOutcome.notFound()
    : operatorFound = false,
      converted = false,
      bundle = null;

  final bool operatorFound;
  final bool converted;
  final Map<String, Object?>? bundle;
}

/// Mobile operational sync gateway.
///
/// Native operator apps call `/v1/operators/:operatorId/locations/:locationId/*`
/// with a Firebase bearer token. The route layer verifies that the URL scope
/// exactly matches the token scope before delegating here; implementations must
/// still run through tenant-scoped Postgres transactions so RLS remains the
/// backup defense.
///
/// Mobile mostly reads from this surface. The data-accuracy write endpoints are
/// narrow canonical-write seams for operator-owned clients so server truth
/// remains authoritative.
abstract class MobileOperationalSyncProxyGateway {
  Future<Map<String, Object?>> fetchShiftRecords({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? modifiedSince,
    required int pageSize,
  });

  Future<Map<String, Object?>> fetchOpenShiftSnapshots({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? modifiedSince,
    required int pageSize,
  });

  Future<Map<String, Object?>> fetchResolvedTimingConfig({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? businessDate,
  });

  Future<Map<String, Object?>> fetchDemoModeStates({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  });

  Future<Map<String, Object?>> fetchDataAccuracySettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  });

  Future<Map<String, Object?>> upsertDataAccuracySettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  });

  Future<Map<String, Object?>> upsertDataAccuracyManualCovers({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  });

  Future<Map<String, Object?>> upsertDataAccuracyServicePeriodSettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  });

  Future<Map<String, Object?>> clearDataAccuracyServicePeriodSettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  });

  Future<Map<String, Object?>> fetchDataAccuracyServicePeriodSettings({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  });

  Future<Map<String, Object?>> fetchWageRoleRows({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? modifiedSince,
    required int pageSize,
    required bool includeHierarchy,
  });

  Future<Map<String, Object?>> fetchPollingTierAssignment({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  });

  Future<Map<String, Object?>> fetchFirstBackfillStatus({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
  });
}

class MobileOperationalSyncProxyGatewayException implements Exception {
  const MobileOperationalSyncProxyGatewayException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() =>
      'MobileOperationalSyncProxyGatewayException($statusCode/$code)';
}

class DataAccuracyAdminGatewayValidationError implements Exception {
  const DataAccuracyAdminGatewayValidationError({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() =>
      'DataAccuracyAdminGatewayValidationError($statusCode/$code): $message';
}

abstract class DataAccuracyAdminProxyGateway {
  Future<List<Map<String, Object?>>> listDataAccuracyRows({
    required String actorUserId,
    required String adminReason,
  });

  Future<Map<String, Object?>?> loadDataAccuracyRow({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String adminReason,
  });

  Future<List<Map<String, Object?>>> listAuditHistory({
    required String actorUserId,
    String? operatorId,
    String? locationId,
    required String adminReason,
  });

  Future<Map<String, Object?>?> overrideDataAccuracy({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    Map<String, String>? coversSourcePerServicePeriod,
    String? wageSource,
    String? walkInHandlingMode,
    String? reasonNote,
    required String adminReason,
  });

  Future<Map<String, Object?>?> saveDataAccuracySettings({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    Map<String, String>? coversSourcePerServicePeriod,
    Map<String, Map<String, int>> coversManualEntries =
        const <String, Map<String, int>>{},
    String? wageSource,
    String? walkInHandlingMode,
    Map<String, int> walkInManualEntries = const <String, int>{},
    String? reasonNote,
    required String adminReason,
  });

  Future<Map<String, Object?>?> saveDataAccuracyManualCovers({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String businessDate,
    required String servicePeriodKey,
    required int covers,
    String? reasonNote,
    required String adminReason,
  });

  Future<Map<String, Object?>?> clearDataAccuracyManualCovers({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String businessDate,
    required String servicePeriodKey,
    String? reasonNote,
    required String adminReason,
  });

  Future<Map<String, Object?>> overrideDataAccuracyScope({
    required String actorUserId,
    required String operatorId,
    required String scopeType,
    String? orgUnitId,
    String? locationId,
    Map<String, String>? coversSourcePerServicePeriod,
    List<String>? clearCoversSourcePerServicePeriod,
    bool clearWageSource = false,
    bool clearWalkInHandlingMode = false,
    String? wageSource,
    String? walkInHandlingMode,
    String? reasonNote,
    required String adminReason,
  });

  Future<List<Map<String, Object?>>> listDataAccuracyServicePeriodRows({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String adminReason,
  });

  Future<Map<String, Object?>> overrideDataAccuracyServicePeriod({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    required String coversSource,
    required String wageSource,
    required String effectiveAtBusinessDate,
    required String reasonNote,
    required String adminReason,
  });

  Future<Map<String, Object?>> clearDataAccuracyServicePeriod({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    required String reasonNote,
    required String adminReason,
  });

  Future<List<Map<String, Object?>>> listTierDefinitions({
    required String actorUserId,
    required String adminReason,
  });

  Future<Map<String, Object?>> updateTierDefinition({
    required String actorUserId,
    required String tierKey,
    String? descriptionMd,
    Map<String, int>? pollingCadencePerVendorSeconds,
    int? defaultMonthlyPriceCents,
    int? vendorApiCostEstimateCentsMonthly,
    String? reasonNote,
    required String adminReason,
  });

  Future<List<Map<String, Object?>>> listTierAssignments({
    required String actorUserId,
    required String adminReason,
  });

  Future<Map<String, Object?>?> loadTierAssignment({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String adminReason,
  });

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
  });

  Future<Map<String, Object?>> assignTierScope({
    required String actorUserId,
    required String operatorId,
    required String scopeType,
    String? orgUnitId,
    String? locationId,
    required String tierKey,
    Map<String, int>? customCadencePerVendorSeconds,
    int? monthlyPriceCentsOverride,
    int? vendorApiCostEstimateCentsMonthlyOverride,
    String? adminNotes,
    String? reasonNote,
    required String adminReason,
  });

  Future<Map<String, Object?>> summarizeMargin({
    required String actorUserId,
    String? tierKey,
    required String adminReason,
  });

  Future<String> exportMarginRollupCsv({
    required String actorUserId,
    required String adminReason,
  });

  Future<List<Map<String, Object?>>> listTierChangeRequests({
    required String actorUserId,
    required String adminReason,
  });

  Future<Map<String, Object?>?> resolveTierChangeRequest({
    required String actorUserId,
    required String requestId,
    required String status,
    String? reasonNote,
    required String adminReason,
  });
}

// Phase 11A.3a — Corpus admin routes. F&F internal-only with the same
// method-scoped split the pricing surface uses: GET admits
// `super_admin` + `ff_support` so support users can browse the
// corpus ledger; POST stays strictly `super_admin` because uploads,
// commits, and rollbacks rewrite the advisor source corpus.
class VendorApplicabilityGatewayValidationError implements Exception {
  const VendorApplicabilityGatewayValidationError({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() =>
      'VendorApplicabilityGatewayValidationError($statusCode/$code): $message';
}

abstract class VendorApplicabilityProxyGateway {
  Future<List<Map<String, Object?>>> listAdmin({
    required String actorUserId,
    String? operatorId,
    String? locationId,
    String? settingKind,
    String? settingKey,
    String? vendorSlug,
    required bool currentOnly,
    required String adminReason,
  });

  Future<Map<String, Object?>> upsert({
    required String actorUserId,
    String? operatorId,
    String? locationId,
    required String settingKind,
    required String settingKey,
    required String vendorSlug,
    required bool enabled,
    required Map<String, Object?> metadata,
    DateTime? effectiveFrom,
    String? reasonNote,
    required String adminReason,
  });

  Future<Map<String, Object?>?> end({
    required String actorUserId,
    String? operatorId,
    String? locationId,
    required String settingKind,
    required String settingKey,
    required String vendorSlug,
    DateTime? effectiveUntil,
    String? reasonNote,
    required String adminReason,
  });

  Future<List<Map<String, Object?>>> listForOperator({
    required OperatorContext scope,
    required String settingKind,
    String? settingKey,
  });
}

const String adminCorpusVersionsPath = '/v1/admin/corpus/versions';
const String adminCorpusVersionsPrefix = '$adminCorpusVersionsPath/';
const String adminCorpusUploadPath = '/v1/admin/corpus/upload';
const String adminCorpusPreviewDiffPath = '/v1/admin/corpus/preview-diff';
const String adminCorpusCommitPath = '/v1/admin/corpus/commit';
const String adminCorpusRollbackPath = '/v1/admin/corpus/rollback';

// Phase 11A.3b — Graphify candidate review routes. Same role-gate
// posture as the rest of `/v1/admin/corpus/*`: GET admits
// `super_admin` + `ff_support` so support can browse the diff;
// POST stays strictly `super_admin`. The AGE rebuild route is a
// stub for the launch slice — role gate + Idempotency-Key still
// fire, then the handler returns 501 because the rebuild
// infrastructure ships in 11A.3c.
const String adminCorpusGraphCandidatesPath =
    '/v1/admin/corpus/graph-candidates';
const String adminCorpusGraphCandidatesCommitPath =
    '/v1/admin/corpus/graph-candidates/commit-batch';
const String adminAgeRebuildPath = '/v1/admin/age/rebuild';

const Set<String> kFfCorpusAdminWriteRoles = <String>{'super_admin'};
const Set<String> kFfCorpusAdminReadRoles = <String>{
  'super_admin',
  'ff_support',
};

/// Validation error raised by [CorpusAdminProxyGateway] implementations
/// when a request is rejected for business reasons (e.g. binary
/// upload, unknown preview token). The proxy route handler maps it
/// back to a structured 4xx response.
class CorpusAdminGatewayValidationError implements Exception {
  const CorpusAdminGatewayValidationError({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() =>
      'CorpusAdminGatewayValidationError($statusCode/$code): $message';
}

/// Gateway the proxy delegates to for `/v1/admin/corpus/*` route
/// handling. Returns JSON-ready maps so the proxy handler can wrap
/// them in a 200 response without translating shapes a second time.
abstract class CorpusAdminProxyGateway {
  /// Returns `{'versions': [{'version_id': ...}, ...]}` shape
  /// payloads for the ledger listing surface.
  Future<List<Map<String, Object?>>> listVersions({
    required String actorUserId,
    required String adminReason,
  });

  /// Returns `{'version': {...}, 'chunks': [{...}]}` for one
  /// corpus_versions row.
  Future<Map<String, Object?>?> fetchVersion({
    required String actorUserId,
    required String versionId,
    required String adminReason,
  });

  /// Stages an upload. Returns the diff payload + a preview token the
  /// commit step quotes back to resolve the staged set.
  Future<Map<String, Object?>> previewDiff({
    required String actorUserId,
    required String fileName,
    required String contentType,
    required List<int> bytes,
    required String idempotencyKey,
    required String adminReason,
  });

  /// Commits the staged upload. Returns the inserted version row.
  Future<Map<String, Object?>> commitVersion({
    required String actorUserId,
    required String previewToken,
    required String summary,
    required String idempotencyKey,
    required String adminReason,
  });

  /// Rolls back to a prior version. Returns the new version row whose
  /// `rollback_of` carries the target id.
  Future<Map<String, Object?>?> rollbackVersion({
    required String actorUserId,
    required String targetVersionId,
    required String summary,
    required String idempotencyKey,
    required String adminReason,
  });
}

/// Validation error raised by [GraphCandidatesProxyGateway]
/// implementations when a request is rejected for business reasons
/// (e.g. candidates pipeline not yet wired, source out of manifest
/// scope). The proxy route handler maps it back to a structured
/// 4xx / 5xx response with the carried `code` and `message`.
class GraphCandidatesGatewayValidationError implements Exception {
  const GraphCandidatesGatewayValidationError({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() =>
      'GraphCandidatesGatewayValidationError($statusCode/$code): $message';
}

/// Gateway the proxy delegates to for `/v1/admin/corpus/graph-
/// candidates*` route handling. Mirrors the [CorpusAdminProxyGateway]
/// shape — one method per route, returning JSON-ready maps so the
/// route handler can wrap them in a 200 response without translating
/// shapes a second time.
abstract class GraphCandidatesProxyGateway {
  /// Returns the JSON payload `GraphCandidateDiff.fromJson` reads:
  ///
  ///   {
  ///     'graph_scope': '...',
  ///     'graph_version': '...',
  ///     'graphify_version': '...',
  ///     'graphify_source_commit': '...',
  ///     'extracted': [...],
  ///     'inferred': [...],
  ///     'ambiguous': [...],
  ///   }
  Future<Map<String, Object?>> listGraphCandidates({
    required String actorUserId,
    required String adminReason,
  });

  /// Commits a batch of approve/reject/edit decisions. Returns the
  /// JSON payload `BatchCommitResult.fromJson` reads:
  ///
  ///   {
  ///     'approved_node_count': int,
  ///     'approved_edge_count': int,
  ///     'rejected_count': int,
  ///     'outcomes': [...],
  ///   }
  ///
  /// `decisions` is the raw client list from the request body (each
  /// entry already cast to `Map<String, Object?>`). The route handler
  /// has already enforced the manifest defense-in-depth filter against
  /// every decision's `source_file` payload before dispatching here;
  /// the gateway is responsible for translating into the repository's
  /// [GraphCommitDecision] shape and writing through the
  /// [GraphRepository] under the supplied tenant scope.
  ///
  /// `operatorId` and `locationId` come from the request body
  /// (`target_operator_id` / `target_location_id`) — F&F admin actors
  /// are cross-tenant, so the operator the candidates land in is an
  /// explicit per-request choice, not a JWT claim.
  Future<Map<String, Object?>> commitBatch({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required List<Map<String, Object?>> decisions,
    required String idempotencyKey,
    required String adminReason,
  });
}

/// Roles that admit a caller to `/v1/admin/operators` and
/// `/v1/admin/locations`. This 11A.1 surface is intentionally
/// super-admin-only because it exposes unscoped cross-operator reads
/// and writes; `ff_support` stays out until support-scoped reads land.
const Set<String> kFfOperatorLocationAdminRoles = <String>{'super_admin'};

// Phase 11A.4 — Integration management admin routes. F&F internal
// only with a method-scoped role split mirroring the 11A.2 pricing
// posture: GET admits `super_admin` and `ff_support` so support
// users can load the read-only Integrations view in live mode;
// POST stays strictly `super_admin` because rotating a provider
// key flips the production credential. Plaintext is NEVER persisted
// — the proxy hands plaintext to the [KmsProvider], persists only
// the masked-display + KMS pointer, and surfaces plaintext ONCE on
// the rotation response.
const String adminIntegrationsListPath = '/v1/admin/integrations';
const String adminIntegrationsRotateAnthropicPath =
    '/v1/admin/integrations/rotate-anthropic';
const String adminIntegrationsRotateVoyagePath =
    '/v1/admin/integrations/rotate-voyage';
const String adminIntegrationsRotateAzureDbPath =
    '/v1/admin/integrations/rotate-azure-db';
const String adminIntegrationsRotateGeminiPath =
    '/v1/admin/integrations/rotate-gemini';
const String adminIntegrationsRotateSendgridPath =
    '/v1/admin/integrations/rotate-sendgrid';
const String adminIntegrationsStatusPath = '/v1/admin/integrations/status';

/// Read-side role admit set for `/v1/admin/integrations*`. Mirrors
/// the 11A.2 pricing read split so `ff_support` can render the
/// read-only Integrations grid in live mode.
const Set<String> kFfIntegrationAdminReadRoles = <String>{
  'super_admin',
  'ff_support',
};

/// Write-side role admit set for `/v1/admin/integrations*`. Strictly
/// `super_admin`: rotating a provider key affects production
/// credentials, so support cannot bypass even for "verified"
/// rotations.
const Set<String> kFfIntegrationAdminWriteRoles = <String>{'super_admin'};

/// Validation error raised by [IntegrationAdminProxyGateway]
/// implementations when a request is rejected for business reasons
/// (e.g. KMS write failure). The proxy route handler maps it back to
/// a structured 4xx / 5xx response.
class IntegrationAdminGatewayValidationError implements Exception {
  const IntegrationAdminGatewayValidationError({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() =>
      'IntegrationAdminGatewayValidationError($statusCode/$code): $message';
}

/// Locked `key_kind` set the proxy accepts on rotation routes.
/// Mirrors the database CHECK constraint on `provider_credentials`.
const Set<String> kProxyIntegrationKeyKinds = <String>{
  'anthropic',
  'voyage',
  'azure_db',
  'gemini',
  'sendgrid',
};

/// Gateway the proxy delegates to for `/v1/admin/integrations/*`
/// route handling. Returns JSON-ready maps so the proxy handler can
/// wrap them in a 200/201 response without translating shapes a
/// second time.
///
/// `actorUserId` is REQUIRED and must be a UUID-shaped Postgres
/// `users.user_id`. The proxy resolves the verified Firebase UID into
/// a Postgres user UUID via [IntegrationAdminActorResolver] before
/// dispatch and rejects with 403 `actor_user_not_resolvable` when no
/// active `users` row matches. This keeps the audit attribution
/// contract intact (`auth_events_audit.actor_user_id` is never null
/// when `actor_kind = 'user'`).
abstract class IntegrationAdminProxyGateway {
  /// Returns `{provider_keys: [...], vendor_connectors: [...],
  /// fx_rate_source: {...}, email_provider: {...}}`. Plaintext is
  /// NEVER present in this response shape.
  Future<Map<String, Object?>> listBundle({
    required String actorUserId,
    required String adminReason,
    String? operatorId,
    String? locationId,
    List<String>? locationIds,
  });

  /// Rotate one provider key. The gateway hands the plaintext to its
  /// configured KMS provider, persists only the masked-display +
  /// KMS pointer, writes an audit row, and returns
  /// `{row: {...}, plaintext_value: "<plaintext>"}`. Plaintext is
  /// surfaced ONCE; subsequent calls to [listBundle] return only
  /// the masked row.
  Future<Map<String, Object?>> rotateProviderKey({
    required String actorUserId,
    required String keyKind,
    required String plaintextValue,
    required String adminReason,
  });
}

/// Resolves a verified Firebase UID into the local Postgres `user_id`
/// (UUID) used for audit attribution and `provider_credentials`
/// `created_by` / `updated_by` writes.
///
/// Returns null when no active `users` row matches the Firebase UID
/// (e.g. a Firebase admin who has not been onboarded into the
/// Postgres `users` table). The integrations dispatcher rejects with
/// 403 `actor_user_not_resolvable` in that case so an audit row is
/// never written without an attributable actor.
abstract class IntegrationAdminActorResolver {
  Future<String?> resolveActorUserId({
    required String firebaseUid,
    required String adminReason,
  });
}

// Phase 11A.7 — Feature flags admin routes. F&F internal-only with
// the same method-scoped role split as 11A.2 / 11A.3a / 11A.4: GET
// admits `super_admin` + `ff_support` so support users can browse
// the flag list; POST is strictly `super_admin` because flipping a
// destructive flag (audit_logs cutover, KMS rollout lanes) directly
// changes production runtime behaviour. The toggle POST also requires
// an `Idempotency-Key` so a retried request collapses to one toggle
// + one audit row, not two.
const String adminFeatureFlagsListPath = '/v1/admin/feature-flags';
const String adminFeatureFlagsTogglePath = '/v1/admin/feature-flags/toggle';

const Set<String> kFfFeatureFlagsAdminReadRoles = <String>{
  'super_admin',
  'ff_support',
};
const Set<String> kFfFeatureFlagsAdminWriteRoles = <String>{'super_admin'};

/// Validation error raised by [FeatureFlagsAdminProxyGateway]
/// implementations when a request is rejected for business reasons
/// (e.g. unknown flag_id, invalid kind). The proxy route handler maps
/// it back to a structured 4xx / 5xx response with the carried `code`
/// and `message`.
class FeatureFlagsAdminGatewayValidationError implements Exception {
  const FeatureFlagsAdminGatewayValidationError({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() =>
      'FeatureFlagsAdminGatewayValidationError($statusCode/$code): $message';
}

/// Gateway the proxy delegates to for `/v1/admin/feature-flags/*`
/// route handling. Returns JSON-ready maps so the proxy handler can
/// wrap them in a 200 response without translating shapes a second
/// time.
///
/// `actorUserId` is REQUIRED on toggle and must be a UUID-shaped
/// Postgres `users.user_id`. The proxy resolves the verified Firebase
/// UID into a Postgres user UUID via [IntegrationAdminActorResolver]
/// (shared with the 11A.4 surface) and rejects with 403
/// `actor_user_not_resolvable` when no active users row matches.
abstract class FeatureFlagsAdminProxyGateway {
  /// Returns `{flags: [{flag_id: ..., flag_name: ..., enabled: ...,
  /// kind: ..., ...}, ...]}`. Ordered destructive-first then
  /// alphabetical so kill switches surface at the top of the grid.
  Future<List<Map<String, Object?>>> listFlags({
    required String actorUserId,
    required String adminReason,
    String? operatorId,
    String? locationId,
    List<String>? locationIds,
  });

  /// Toggle one flag's `enabled` bit by `flagId`. Returns the
  /// post-toggle row JSON. Returns null when no row matches; the
  /// route handler maps that into 404 `unknown_flag`.
  ///
  /// HARD-B - `reason` is an optional free-text rationale supplied by
  /// the operator (max 500 chars). When present it is written to the
  /// audit row's `reason` field so reviewers can correlate the toggle
  /// with an incident ticket / change-management note. The
  /// `idempotency_key` already binds to the rationale via the payload
  /// hash, so two retries that disagree on the reason 422-conflict.
  Future<Map<String, Object?>?> toggleFlag({
    required String actorUserId,
    required String flagId,
    required bool enabled,
    required String idempotencyKey,
    required String adminReason,
    String? reason,
  });
}

// Phase 11A.5 / 11A.6 — Debug console and observability admin
// routes. Both are read-only, F&F internal-only surfaces. GET admits
// `super_admin` and `ff_support`; raw full-content debug payloads are
// additionally limited to `super_admin` and only when the per-operator
// opt-in flag is enabled by the producer.
const String adminDebugRequestsPath = '/v1/admin/debug/requests';
const String adminDebugRequestByIdPath = '/v1/admin/debug/requests/by-id';
const String adminDebugRequestByKeyPath = '/v1/admin/debug/requests/by-key';
const String adminDebugRequestsTailPath = '/v1/admin/debug/requests/tail';
const String adminDebugFullContentOptInsPath =
    '/v1/admin/debug/full-content-opt-ins';
const String adminDebugRelationshipHelpPath =
    '/v1/admin/debug/relationship-help';
const String adminDebugAccountHelpPath = '/v1/admin/debug/account-help';
const String adminObservabilityPath = '/v1/admin/observability';

const Set<String> kFfDebugConsoleAdminReadRoles = <String>{
  'super_admin',
  'ff_support',
};
const Set<String> kFfDebugConsoleFullContentRoles = <String>{'super_admin'};
const Set<String> kFfObservabilityAdminReadRoles = <String>{
  'super_admin',
  'ff_support',
};
const Set<String> kDebugRelationshipHelpUsageClasses = <String>{
  'relationship_review',
  'knowledge_relationship',
  'corpus_relationship_review',
};
const Set<String> kDebugAccountHelpUsageClasses = <String>{
  'account_help',
  'auth_support',
  'mfa_diagnostics',
  'session_support',
  'notification_support',
  'user_removal',
};

abstract class DebugConsoleAdminProxyGateway {
  Future<List<Map<String, Object?>>> listRequests({
    required String actorUserId,
    required String adminReason,
    String? operatorId,
    String? locationId,
    List<String>? locationIds,
    String? usageClass,
    String? status,
    int? timeWindowSeconds,
    String? searchText,
    required int limit,
    required bool includeFullContent,
  });

  Future<Map<String, Object?>?> getByRequestId({
    required String actorUserId,
    required String adminReason,
    required String requestId,
    required bool includeFullContent,
  });

  Future<Map<String, Object?>?> getByIdempotencyKey({
    required String actorUserId,
    required String adminReason,
    required String idempotencyKey,
    required bool includeFullContent,
  });

  Future<List<Map<String, Object?>>> tailRecent({
    required String actorUserId,
    required String adminReason,
    required int limit,
    required bool includeFullContent,
  });

  Future<List<Map<String, Object?>>> listFullContentOptIns({
    required String actorUserId,
    required String adminReason,
  });
}

/// The calendar-month bucket the `usage_logs`-backed cost surfaces
/// aggregate over.
///
/// `public.usage_logs` is a MONTHLY rollup — every row's `period_start`
/// is `date_trunc('month', ...)`, so the finest honest cost grain is one
/// whole calendar month. The only meaningful selections are therefore
/// the current month or the immediately preceding one; 24h / 7d /
/// arbitrary-date windows would have to fabricate daily data and are
/// intentionally NOT offered (Metric Honesty Doctrine). [offsetMonths]
/// is the number of whole months to subtract from the current
/// `date_trunc('month', now())` lower bound (0 = current, 1 = previous).
enum ObservabilityMonth {
  current(0),
  previous(1);

  const ObservabilityMonth(this.offsetMonths);

  /// Whole months to subtract from `date_trunc('month', now())` to reach
  /// this bucket's lower bound.
  final int offsetMonths;
}

/// Parses the `month=` query value into an [ObservabilityMonth].
///
/// `current` and `previous` map to their enum cases; ANY other value —
/// missing, blank, or garbage — clamps to [ObservabilityMonth.current].
/// The cost surfaces are never silently left unfiltered, and an unknown
/// value can never widen the window beyond a single honest month.
ObservabilityMonth parseObservabilityMonth(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'previous':
      return ObservabilityMonth.previous;
    case 'current':
    default:
      return ObservabilityMonth.current;
  }
}

abstract class ObservabilityAdminProxyGateway {
  Future<Map<String, Object?>> fetch({
    required String actorUserId,
    required String adminReason,
    required int costTelemetryLimit,
    String? queryClassFilter,
    String? operatorId,
    String? locationId,
    List<String>? locationIds,
    ObservabilityMonth month,
  });
}

/// Phase 10a.4 — gateway for `/v1/realtime/tripwire-status`. The route
/// is read-only, runs through `runAsSystem` because the four Q22
/// metrics are platform-wide aggregates with no tenant identifiers,
/// and is polled by the sync badge so the badge can shift to
/// "Degraded" when ANY metric fires red even while the WebSocket
/// connection itself is alive. Production wiring lives in
/// `tool/advisor_proxy/main.dart`; tests inject a fake.
abstract class RealtimeTripwireProxyGateway {
  /// Returns the JSON envelope the route writes back. The shape is
  /// stable wire contract:
  ///
  /// ```json
  /// {
  ///   "status": "green|yellow|red",
  ///   "metrics": {
  ///     "<metric_key>": {
  ///       "value": <num|null>,
  ///       "status": "green|yellow|red|unknown",
  ///       "thresholds": {"yellow": <num>, "red": <num>}
  ///     },
  ///     ...
  ///   },
  ///   "breaches": [
  ///     {"metric": "<key>", "value": <num>, "status": "yellow|red"},
  ///     ...
  ///   ],
  ///   "checked_at": "<iso8601 utc>"
  /// }
  /// ```
  ///
  /// Sync badge consumers only need `status` to drive degraded; admin
  /// observability consumers walk `metrics` to render one row per
  /// metric. No tenant identifiers ever appear in the payload.
  Future<Map<String, Object?>> fetch();
}

/// HARD-H — idempotency ledger for cross-tenant F&F admin routes.
/// The Phase 9 `proxy_requests` table is per-tenant; admin routes
/// driven by super_admin / ff_support actors have no operator scope
/// so they need a separate ledger keyed on idempotency_key alone.
/// Backed by `public.admin_request_idempotency` (HARD-H migration).
abstract class AdminRequestIdempotencyStore {
  /// Look up a prior response for [idempotencyKey] + [requestType].
  /// Returns null when the key has never been used. Throws
  /// [AdminIdempotencyKeyConflict] when the key was used for a
  /// different [requestType] or with a different request body.
  Future<AdminRequestIdempotencyEntry?> lookup({
    required String idempotencyKey,
    required String requestType,
    required String requestBodyHash,
  });

  /// Reserve [idempotencyKey] for [requestType]. Returns true when the
  /// reserve succeeded (caller should run the work and then call
  /// [completeReservation]); returns false when another caller raced
  /// and reserved the key first (caller should re-run [lookup] to
  /// fetch the in-flight or completed result).
  Future<bool> reserve({
    required String idempotencyKey,
    required String requestType,
    required String? actorUserId,
    required String requestBodyHash,
  });

  /// Stamp [responseStatus] + [responsePayload] on a previously
  /// reserved row so subsequent [lookup] calls return the cached
  /// response.
  Future<void> completeReservation({
    required String idempotencyKey,
    required int responseStatus,
    required Map<String, Object?> responsePayload,
  });

  /// CODE_HEALTH L4 — reclaim a single in-flight reservation whose
  /// `expires_at` has passed.
  ///
  /// Predicate (matches the M1 migration —
  /// `db/migrations/202605080100_admin_idempotency_expires_at.sql` —
  /// and the `admin_idempotency_sweep` pg_cron job exactly):
  ///   `response_status IS NULL AND completed_at IS NULL AND
  ///    expires_at < now()`
  ///
  /// The HARD-H table has NO `status` column; "in-flight" is the
  /// pair `(response_status IS NULL AND completed_at IS NULL)`. Do
  /// NOT introduce a `status='in_flight'` predicate — it does not
  /// exist.
  ///
  /// Returns true when the row was reclaimed (deleted) and the caller
  /// should retry [reserve]. Returns false when the row is still in
  /// its TTL window, has already completed, or does not exist.
  ///
  /// Default implementation is a no-op so production wiring lives in
  /// `proxy_bootstrap.dart::PostgresAdminRequestIdempotencyStore` (out
  /// of scope for L4) and pg_cron is the live backstop. Tests that
  /// drive the reclaim flow override this to flip the in-flight row
  /// in their fake.
  Future<bool> tryReclaimOrphan({required String idempotencyKey}) async {
    return false;
  }

  /// CODE_HEALTH L4 — sweep every in-flight reservation whose
  /// `expires_at` has passed.
  ///
  /// Same predicate as [tryReclaimOrphan] but unkeyed; returns the
  /// number of rows deleted. Backs the in-process every-5-minute
  /// sweeper [main.dart] starts at boot. Default no-op so the
  /// pg_cron sweep registered by the M1 migration is the live
  /// backstop until the Postgres-backed store overrides this method.
  Future<int> sweepExpiredOrphans() async {
    return 0;
  }
}

class AdminRequestIdempotencyEntry {
  const AdminRequestIdempotencyEntry({
    required this.idempotencyKey,
    required this.requestType,
    required this.responseStatus,
    required this.responsePayload,
    required this.completedAt,
    this.expiresAt,
  });

  final String idempotencyKey;
  final String requestType;

  /// Null when the row is reserved but the work has not completed
  /// yet — the route handler returns a 409 `idempotency_request_in_flight`
  /// in that case (matching the service-principal contract).
  final int? responseStatus;
  final Map<String, Object?>? responsePayload;
  final DateTime? completedAt;

  /// CODE_HEALTH L4 — TTL for the reservation. Mirrors the
  /// `expires_at` column added by M1
  /// (`db/migrations/202605080100_admin_idempotency_expires_at.sql`).
  /// Null when the underlying store does not yet expose the column;
  /// `_runAdminIdempotent` only attempts the orphan-reclaim path when
  /// this field is non-null AND has elapsed.
  final DateTime? expiresAt;
}

class AdminIdempotencyKeyConflict implements Exception {
  const AdminIdempotencyKeyConflict({required this.message});
  final String message;
  @override
  String toString() => 'AdminIdempotencyKeyConflict: $message';
}

/// Gateway the proxy delegates to for `/v1/admin/operators` and
/// `/v1/admin/locations` route handling. The gateway returns
/// JSON-ready maps so the proxy handler can wrap them in a 200/201
/// response without translating shapes a second time.
abstract class OperatorLocationAdminProxyGateway {
  /// Returns `[{'operator': {...}, 'locations': [{...}, ...]}]`
  /// across every operator. The list is sorted by operator
  /// `business_name` so the admin console renders deterministically.
  Future<List<Map<String, Object?>>> listOperatorsWithLocations({
    required String actorUserId,
    required String adminReason,
  });

  /// Inserts the operator + primary location, then uses the Phase 9 auth
  /// gateway to create the owner invite/user/custom claims/user_roles grant
  /// before attaching the `operator_admins` row. Returns the same
  /// `{'operator': ..., 'locations': [...]}` bundle shape as
  /// [listOperatorsWithLocations] for the new operator.
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
  });

  /// PATCH-style update of one operator. Each field is optional; only
  /// the supplied columns are rewritten. Returns the operator JSON
  /// when the row exists, or null when the operator was not found.
  Future<Map<String, Object?>?> patchOperator({
    required String actorUserId,
    required String operatorId,
    String? businessName,
    String? ownerEmail,
    String? subscriptionTier,
    String? preferredCurrency,
    String? primaryLocationId,
    required String adminReason,
  });

  Future<Map<String, Object?>?> suspendOperator({
    required String actorUserId,
    required String operatorId,
    required String adminReason,
  });

  Future<Map<String, Object?>?> reactivateOperator({
    required String actorUserId,
    required String operatorId,
    required String adminReason,
  });

  Future<Map<String, Object?>> addLocation({
    required String actorUserId,
    required String operatorId,
    required String parentOrgUnitId,
    required String name,
    required String address,
    required String timezone,
    required int businessDayRolloverHour,
    required String adminReason,
  });

  Future<Map<String, Object?>?> patchLocation({
    required String actorUserId,
    required String locationId,
    String? name,
    String? address,
    String? timezone,
    int? businessDayRolloverHour,
    required String adminReason,
  });

  /// Returns the result of removing a location:
  /// [AdminLocationRemovalResult.removed] (200), `notFound` (404), or
  /// `primaryLocationProtected` (400) when the caller tried to
  /// delete the operator's `primary_location_id` (the schema's
  /// `ON DELETE SET NULL` would silently null the pointer if we let
  /// the delete proceed; the proxy refuses the call up-front
  /// instead).
  Future<AdminLocationRemovalResult> removeLocation({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String adminReason,
  });
}

class OperatorLocationAdminRejected implements Exception {
  const OperatorLocationAdminRejected({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;

  @override
  String toString() =>
      'OperatorLocationAdminRejected($statusCode/$code): $message';
}

enum AdminLocationRemovalResult { removed, notFound, primaryLocationProtected }

// Phase 9 live-closeout B6 — auth-session ledger endpoints. The Flutter
// app holds no Postgres credentials; every `auth_sessions` mutation
// flows through these routes. The proxy verifies the Firebase ID token
// (server-side, via [ProxyRequestGuard.requireOperatorContext]),
// extracts operator/location/user from the verified claims, and
// delegates to an injected [AuthSessionLedgerWriter] (production
// binding wraps `AuthSessionsRepository` over the tenant transaction
// wrapper).
const String authSessionLoginPath = '/v1/auth/session/login';
const String authSessionRefreshPath = '/v1/auth/session/refresh';
const String authSessionRevokePath = '/v1/auth/session/revoke';
const String authSessionRevokeAllPath = '/v1/auth/session/revoke-all';
const String authRefreshTokensRevokeAllPath =
    '/v1/auth/refresh-tokens/revoke-all';

// Phase 9.UX.5 — self-service Active Sessions read projection. Auth-
// gated; reads only the verified caller's own auth_sessions rows.
// The single / all revoke paths above already exist for B6; the new
// surface adds a list endpoint plus reuses those routes for revokes.
const String authSessionsListPath = '/v1/auth/sessions';

// 11W.4 ops-debt — team-wide Active Sessions read projection. Auth-
// gated; lists every active `auth_sessions` row whose `user_id`
// belongs to the caller's operator. Joined to `users` for identity
// (display name / email) so the operator-web Sessions screen can
// render which member each row belongs to. Gated on
// `team.session.force_logout`.
const String authTeamSessionsListPath = '/v1/auth/team/sessions';

// Phase 11W.8 live-closeout — operator self-service vendor connections
// read projection. Operator web must use `/v1/auth/*`, not admin-only
// `/v1/admin/*`, for authenticated operator surfaces. V1 exposes the
// implemented vendor catalog and current connection/demo state; when
// live credentials are not promoted, connect buttons remain disabled by
// adapter lifecycle in the Flutter widget.
const String authLocationIntegrationsPrefix = '/v1/auth/locations/';
final RegExp authLocationIntegrationsPattern = RegExp(
  r'^/v1/auth/locations/([^/]+)/integrations$',
);

/// Phase 8 — operator-self-service projection over
/// `public.connector_connection`. The proxy bootstrap binds a real
/// projection that runs `ConnectorConnectionListRepository.listForLocation`
/// inside the operator's tenant transaction; tests inject a fixture
/// closure. When unbound the route falls back to the V1 stub bundle
/// (no connections, demo flags all true) so existing tests do not
/// regress.
///
/// The projection returns the wire JSON ready to write to the client
/// — the route layer only stamps `operator_id` / `location_id` from
/// the verified scope and enforces the location_scope_mismatch /
/// permission gates before invoking it.
typedef OperatorLocationIntegrationsProjection =
    Future<Map<String, Object?>> Function({
      required String operatorId,
      required String locationId,
      required String actorUserId,
    });

/// Phase 8 — wire-shape encoder for the
/// `GET /v1/auth/locations/{location_id}/integrations` response.
///
/// Reusable so the production projection (Postgres-backed) and any
/// test fixture (in-memory) emit identical JSON shapes. Returns:
///   - `connections`: list of vendor rows
///   - `demo_flags`: per-category flag (`true` when no connected row
///     exists in that category, `false` once an operator has at least
///     one connected vendor — drives the demo bundle picker on the
///     operator-web Connections screen).
///
/// The route layer always stamps `operator_id` / `location_id` after
/// this builder runs so the projection cannot accidentally leak a
/// different operator's identifiers.
Map<String, Object?> buildOperatorLocationIntegrationsBundleJson(
  ConnectorConnectionListBundle bundle,
) {
  return <String, Object?>{
    'operator_id': bundle.operatorId,
    'location_id': bundle.locationId,
    'connections': bundle.rows
        .map(_connectorConnectionRowToWireJson)
        .toList(growable: false),
    'demo_flags': <String, Object?>{
      'pos': bundle.noConnectedRowForCategory(IntegrationCategory.pos),
      'labor': bundle.noConnectedRowForCategory(IntegrationCategory.labor),
      'reservation': bundle.noConnectedRowForCategory(
        IntegrationCategory.reservation,
      ),
    },
  };
}

Map<String, Object?> _connectorConnectionRowToWireJson(
  ConnectorConnectionListRow row,
) {
  return <String, Object?>{
    'connection_id': row.connectionId,
    'vendor_id': row.vendorId,
    'category': _integrationCategoryWireKey(row.category),
    'status': row.status,
    if (row.module != null) 'module': row.module,
    'metadata': row.metadata,
    if (row.lastSyncAt != null)
      'last_sync_at': row.lastSyncAt!.toIso8601String(),
    if (row.lastErrorAt != null)
      'last_error_at': row.lastErrorAt!.toIso8601String(),
    if (row.lastErrorMessage != null)
      'last_error_message': row.lastErrorMessage,
    if (row.disconnectReason != null) 'disconnect_reason': row.disconnectReason,
    'webhook_url_provisioned': row.webhookUrlProvisioned,
    if (row.createdAt != null) 'created_at': row.createdAt!.toIso8601String(),
    if (row.updatedAt != null) 'updated_at': row.updatedAt!.toIso8601String(),
    if (row.firstBackfillStatus != null)
      'first_backfill': _firstBackfillToWireJson(row),
  };
}

Map<String, Object?> _firstBackfillToWireJson(ConnectorConnectionListRow row) {
  return <String, Object?>{
    'status': row.firstBackfillStatus!.wire,
    'started_at': row.firstBackfillStartedAt?.toIso8601String(),
    'completed_at': row.firstBackfillCompletedAt?.toIso8601String(),
    'failure_reason': row.firstBackfillFailureReason,
    'processed_days': row.firstBackfillProcessedDays,
    'total_days': row.firstBackfillTotalDays,
  };
}

String _integrationCategoryWireKey(IntegrationCategory category) {
  switch (category) {
    case IntegrationCategory.pos:
      return 'pos';
    case IntegrationCategory.labor:
      return 'labor';
    case IntegrationCategory.reservation:
      return 'reservation';
  }
}

// Phase 9.UX.6 — self-service Audit Log read projection. Auth-gated;
// the proxy resolves user_id from the verified Firebase bearer token
// and ignores any client-supplied user_id. The WHERE clause pins
// user_id (actor or target) so RLS plus the WHERE form a defense in
// depth.
const String authAuditLogPath = '/v1/auth/audit-log';

// Audit-log server-side CSV export. Reuses the read route's filter
// shape (from / to / event_kind / action / actor_user_id / target_kind
// / target_id / actor_kind) and streams RFC 4180 rows back as a chunked
// `text/csv` attachment. Gated on `team.audit_log.export` via the
// permission snapshot resolver — the read route is open to any verified
// caller, but pulling the full ledger to a CSV is a senior-role action
// per the parity contract.
const String authAuditLogExportPath = '/v1/auth/audit-log/export.csv';

/// Per-page size used by the streamed CSV exporter when paging the
/// underlying repo. Bounded so the proxy memory footprint stays
/// constant regardless of the operator's audit-log row count.
const int kAuthAuditLogExportPageSize = 500;

/// Hard cap on the total rows the streamed exporter will emit before
/// it stops and finishes the response. Defends against a runaway
/// filter that selects tens of millions of rows. Operators that need
/// more rows must narrow their filter window.
const int kAuthAuditLogExportRowCap = 1000000;

class ProxyPermissionSnapshot {
  const ProxyPermissionSnapshot({
    required this.userId,
    required this.operatorId,
    required this.locationId,
    required this.rolesVersion,
    required this.evaluatedAt,
    required this.permissions,
    this.requiresMfaKeys = const <String>{},
  });

  final String userId;
  final String operatorId;
  final String locationId;
  final int rolesVersion;
  final DateTime evaluatedAt;
  final Map<String, PermissionEffect> permissions;
  final Set<String> requiresMfaKeys;

  Map<String, Object?> toJson() => <String, Object?>{
    'user_id': userId,
    'operator_id': operatorId,
    'location_id': locationId,
    'roles_version': rolesVersion,
    'evaluated_at': evaluatedAt.toUtc().toIso8601String(),
    'permissions': permissions.map(
      (key, value) =>
          MapEntry(key, value == PermissionEffect.allow ? 'allow' : 'deny'),
    ),
    'requires_mfa': requiresMfaKeys.toList(growable: false)..sort(),
  };
}

abstract class ProxyPermissionSnapshotResolver {
  Future<ProxyPermissionSnapshot> load(OperatorContext scope);
}

class ScaffoldFailingProxyPermissionSnapshotResolver
    implements ProxyPermissionSnapshotResolver {
  const ScaffoldFailingProxyPermissionSnapshotResolver();

  @override
  Future<ProxyPermissionSnapshot> load(OperatorContext scope) {
    throw StateError(
      'Phase 9 permission snapshot resolver is not wired; bind the '
      'repository-backed resolver before exposing live Team actions.',
    );
  }
}

// ─── B1.A3 — Permission-version revoke-forces-logout ─────────────────────────
//
// Abstract checker injected into [routeRequest]. Production binding hits
// `UsersRepository.fetchPermissionVersion` via the admin pool; tests inject
// [InMemoryPermissionVersionChecker]. When null (back-compat / scaffold) the
// check is skipped for that request.

abstract class PermissionVersionChecker {
  /// Returns the stored DB value for [userId]. Returns null when the user
  /// is not found (treat as "pass" so deletions don't block last requests).
  Future<int?> fetch(String userId);
}

class InMemoryPermissionVersionChecker implements PermissionVersionChecker {
  InMemoryPermissionVersionChecker(this._versions);

  final Map<String, int> _versions;

  @override
  Future<int?> fetch(String userId) async => _versions[userId];
}

/// Minimal request router. Routes:
///
///   - GET /healthz         -> 200 (unauthenticated, local compatibility)
///   - GET /readyz          -> 200 (unauthenticated, Cloud Run public check)
///   - GET /v1/scope        -> 200 with operator/location scope (auth-gated)
///   - GET /v1/usage-smoke  -> auth + scope + usage guard, returns tier
///                             policy + remaining budget metadata
///   - POST /v1/auth/session/login       -> auth-gated. Records an
///                              `auth_sessions` row via the injected
///                              [AuthSessionLedgerWriter] and returns
///                              the issued session_id. Body:
///                              `{token_hash}`. User-Agent is stored
///                              as soft metadata; forwarded IP/geo
///                              headers are ignored unless trusted
///                              ingress mode is explicitly enabled.
///   - POST /v1/auth/session/refresh     -> auth-gated. Updates
///                              `last_seen_at`. Body: `{session_id}`.
///   - POST /v1/auth/session/revoke      -> auth-gated. Sets
///                              `revoked_at` for one row. Body:
///                              `{session_id, reason}`.
///   - POST /v1/auth/session/revoke-all  -> auth-gated. Sets
///                              `revoked_at` for every active session
///                              owned by the verified user. Body:
///                              `{reason}`. Returns `{revoked_count}`.
///
/// Anything else -> 404. No live external calls — the smoke routes
/// only echo back resolved scope and budget metadata.
Future<void> routeRequest(
  HttpRequest request,
  ProxyRequestGuard authGuard, {
  ProxyUsageGuard? usageGuard,
  ProxyAccountingStore? accountingStore,
  ProxyHealthCheckStore? healthCheckStore,
  ProxyLlmProvider? llmProvider,
  AdvisorRequestPipeline? advisorRequestPipeline,
  AuthSessionLedgerWriter? authSessionLedgerWriter,
  FirebaseAdminAuthClient? firebaseAdminAuthClient,
  AccountInfoGateway? accountInfoGateway,
  ProxyPermissionSnapshotResolver? permissionSnapshotResolver,
  // Phase 8 — operator-self-service vendor connections list. When
  // null the route returns the legacy V1 stub bundle (empty list,
  // demo flags true) so existing scaffolds + tests do not regress;
  // production binds the [ConnectorConnectionListRepository]-backed
  // projection in the proxy bootstrap.
  OperatorLocationIntegrationsProjection?
  operatorLocationIntegrationsProjection,
  AuthOperationsGateway? authOperationsGateway,
  ProxyAdminPermissionGuard? adminPermissionGuard,
  ServicePrincipalJwtIssuanceGateway? servicePrincipalJwtIssuanceGateway,
  PasswordChangeGateway? passwordChangeGateway,
  PasswordResetConfirmGateway? passwordResetConfirmGateway,
  PasswordResetRequestGateway? passwordResetRequestGateway,
  ProxyAuthIdempotencyCache? authIdempotencyCache,
  MfaOperationsGateway? mfaOperationsGateway,
  // CODE_OPS_DEBT Theme B#1 — single-admin PII erasure with 24h
  // grace-window reverse. Optional: when null, the new `/erase-pii*`
  // routes return 503 so existing tests do not need to plumb the
  // service through every routeRequest call site.
  UserPiiErasureService? userPiiErasureService,
  MfaRecoveryRequestGateway? mfaRecoveryRequestGateway,
  MobilePushTokenGateway? mobilePushTokenGateway,
  MobilePushSelfTestGateway? mobilePushSelfTestGateway,
  MobileOperationalSyncProxyGateway? mobileOperationalSyncGateway,
  BusinessScopeProxyGateway? businessScopeGateway,
  OperatorLocationAdminProxyGateway? operatorLocationAdminGateway,
  PricingTierAdminProxyGateway? pricingTierAdminGateway,
  DataAccuracyAdminProxyGateway? dataAccuracyAdminGateway,
  VendorApplicabilityProxyGateway? vendorApplicabilityGateway,
  CorpusAdminProxyGateway? corpusAdminGateway,
  GraphCandidatesProxyGateway? graphCandidatesGateway,
  IntegrationAdminProxyGateway? integrationAdminGateway,
  IntegrationAdminActorResolver? integrationAdminActorResolver,
  FeatureFlagsAdminProxyGateway? featureFlagsAdminGateway,
  DebugConsoleAdminProxyGateway? debugConsoleAdminGateway,
  ObservabilityAdminProxyGateway? observabilityAdminGateway,
  // HARD-B — auth lockout / retry enforcement. All four are optional
  // for back-compat with existing tests + scaffolds. When null the
  // route runs in legacy "no enforcement" mode.
  AuthLockoutEnforcer? authLockoutEnforcer,
  AuthLockoutAuditSink? authLockoutAuditSink,
  RollingWindowAttemptCounter? mfaTotpRetryCounter,
  RollingWindowAttemptCounter? passwordResetThrottleCounter,
  // B1.S8 — per-email short-window (1 per 5 min) + per-IP (50 per 24h)
  // rate limits on password-reset and MFA-recovery-request endpoints.
  // Optional for back-compat; when null the short-window + IP limits are
  // skipped (legacy behaviour: only the 10/24h in-memory per-email check
  // from [passwordResetThrottleCounter] applies).
  RollingWindowAttemptCounter? passwordResetEmailShortCounter,
  RollingWindowAttemptCounter? passwordResetIpCounter,
  // Slice A11.1 — production session-record gauge. In-process counter
  // that observes 2xx responses from session-finalizing routes (today:
  // POST /v1/auth/session/login) and increments
  // proxy.session_record.incomplete{route, missing_field} when the
  // response body fails SessionRecordCompleteness.assertComplete.
  // Optional for back-compat; when null the route ships the 2xx without
  // the observability hop (legacy "no gauge" mode).
  // Authority: docs/archive/_execution/lane_a_code_health/03_execution_slices.md
  // "Slice A11.1 — Production Session-Record Gauge" + R3 §2.
  SessionRecordIncompleteGauge? sessionRecordIncompleteGauge,
  // HARD-H — admin idempotency cache for cross-tenant POST routes
  // (today: feature flags toggle). Optional: when null, the route
  // runs without route-level dedup and the gateway-side cache
  // (today: `FeatureFlagToggleIdempotencyCache`) is the only
  // protection against duplicate POST execution.
  AdminRequestIdempotencyStore? adminRequestIdempotencyStore,
  // Phase 10a.0 — realtime publisher the WebSocket route subscribes
  // to. Optional: when null, `/v1/realtime` returns 503 so unauth
  // probes still work and existing tests do not need to plumb a
  // publisher through every routeRequest call site.
  InProcessRealtimePublisher? realtimePublisher,
  // Phase 10a.5 — server-side replay fetcher invoked when a client
  // reconnects with `?last_event_id=<uuid>`. Optional: when null,
  // the route falls back to live frames only and existing tests stay
  // green. Production binds this to a `RealtimeReplayResolver` over
  // the publisher's recent-events ring buffer.
  RealtimeReplayFetcher? realtimeReplayFetcher,
  // Phase 10a.4 — yellow/red tripwire status. Optional: when null,
  // `/v1/realtime/tripwire-status` returns 503 so unauth probes still
  // work and existing tests do not need to plumb a gateway through
  // every call site.
  RealtimeTripwireProxyGateway? realtimeTripwireGateway,
  // Phase 11W.7 / Wave A2 - operator-scoped account + business-timing
  // write router. Optional: when null, the five new routes return 503
  // so existing tests do not need to plumb the router through every
  // call site.
  OperatorWriteRouter? operatorWriteRouter,
  AdminBusinessTimingRouter? adminBusinessTimingRouter,
  // Wave W2.D - operator-scoped read of connector_backfill_jobs.
  // Optional: when null the read route returns 503 so existing tests
  // do not need to plumb the router through every call site.
  ConnectorBackfillJobsRouter? connectorBackfillJobsRouter,
  // Phase 11W.8 follow-up - operator-scoped read of recently-available
  // vendors (vendor_lifecycle_notification fan-out mirror). Optional:
  // when null the read route returns 503 so existing tests do not need
  // to plumb the router through every call site.
  OperatorVendorLifecycleRecentlyAvailableRouter?
  vendorLifecycleRecentlyAvailableRouter,
  // Phase 8 W2.B - operator-scoped notification preferences router.
  // Optional: when null the three routes return 503 so existing tests
  // do not need to plumb the router through every call site.
  NotificationPreferencesRouter? notificationPreferencesRouter,
  // Phase 8 W5.A.1 - operator-scoped wage role rows write router.
  // Optional: when null, the POST/DELETE routes return 503 so existing
  // tests do not need to plumb the router through every call site.
  WageRoleRowsRouter? wageRoleRowsRouter,
  // Slice C-4 - operator-scoped Demo -> Live master switch. Optional:
  // when null the route returns 503 so existing tests do not need to
  // plumb the router through every call site.
  DemoModeMasterSwitchRouter? demoModeMasterSwitchRouter,
  // Phase 8 star/target truth - selected-star read/write router. Optional
  // for existing tests; production installs a global router from bootstrap.
  SelectedStarTargetRouter? selectedStarTargetRouter,
  // Phase 8 weekly-plan truth - snapshot/context read/write router. Optional
  // until Lane 0 repository bindings are available in production bootstrap.
  WeeklyPlanRouter? weeklyPlanRouter,
  // Mobile core business-scope truth. Optional for tests and scaffold
  // environments; when null the route returns a typed 503 and existing
  // token-exact sync behavior is preserved.
  BusinessScopeRouter? businessScopeRouter,
  // Operator Web W4.B - per-tenant audit-chain-anchor read gateway.
  // Optional for tests and scaffold environments; when null the route
  // returns a typed 503 so the Audit Log screen renders the unknown
  // badge state without crashing.
  AuditChainAnchorsGateway? auditChainAnchorsGateway,
  // Admin audit-integrity badge — admin/cross-tenant anchor read
  // gateway. Optional for tests and scaffold environments; when null
  // the admin route returns a typed 503 so the admin Audit screen
  // renders the unknown badge state without crashing. Reads ANOTHER
  // tenant's anchor through the sanctioned `runAsSystem` admin bypass;
  // the dispatcher gates the route to super_admin / ff_support first.
  AdminAuditChainAnchorsGateway? adminAuditChainAnchorsGateway,
  // Lane B B11.1 - mobile→web auth handoff (mint + redeem) router.
  // Optional: when null the two routes return 503 so existing tests
  // do not need to plumb the router through every call site.
  AuthHandoffRouter? authHandoffRouter,
  // Lane B B11.2.b - RFC 9470 step-up challenge router. Optional:
  // when null the step-up gate short-circuits to pass-through (legacy
  // "no step-up" mode) so existing tests stay green. Production wires
  // the router and every route in `kStepUpSensitiveRoutes` is gated
  // BEFORE the underlying business handler runs. Step-Up-Challenge-Id
  // flows through the HEADER ONLY (addendum A1).
  StepUpChallengeRouter? stepUpChallengeRouter,
  // Lane B B2.1 - default Role catalog admin routes (publish + list).
  // Optional: when null the two routes return 503 so existing tests
  // do not need to plumb the router through every call site.
  DefaultRoleCatalogAdminRouter? defaultRoleCatalogAdminRouter,
  // B1.A3 — permission_version revoke-forces-logout. Optional for
  // back-compat with existing tests + scaffolds. When null the per-request
  // DB check is skipped and only the JWT claim version gate applies.
  PermissionVersionChecker? permissionVersionChecker,
  // Slice A2 — corpus vector retrieval service. Optional: when null the
  // POST /v1/advisor/retrieve route returns 503 so existing tests do not
  // need to plumb the service through every call site.
  CorpusRetrievalService? corpusRetrievalService,
  // Slice A2b — server-side query embedding gateway. Optional: when null
  // the text-query path of POST /v1/advisor/retrieve returns 503 and
  // callers must supply a pre-computed query_embedding instead.
  // HP #7: [voyageApiKeyForRetrieval] is a server-side secret — NEVER
  // logged, NEVER returned to the client.
  AdvisorQueryEmbeddingGateway? corpusQueryEmbeddingGateway,
  String? voyageApiKeyForRetrieval,
  // Slice A3 ? server-side Voyage rerank gateway. Optional: when null the
  // text-query path returns the A2b vector-only order unchanged (full
  // back-compat). When wired (production), the route fetches a larger
  // candidate pool, reranks it against the query text, and returns the
  // top max_results reordered by rerank score. HP #7:
  // [voyageRerankApiKeyForRetrieval] is a server-side secret ? NEVER
  // logged, NEVER returned to the client. Reuses the SAME VOYAGE_API_KEY
  // secret as the embedding gateway (one Voyage account, two endpoints).
  AdvisorRerankGateway? corpusRerankGateway,
  String? voyageRerankApiKeyForRetrieval,
  // ── Slice A4.2b — POST /v1/advisor/answer dependencies ──────────────────
  // The ACTIVATING agentic answer route. Every binding is OPTIONAL so the
  // many existing routeRequest call sites (and their tests) stay
  // byte-compatible; when a required one is absent the route fails closed
  // (503) rather than crashing.
  //
  // Provider seam (A4.1): the tool-use Anthropic gateway, pre-built in
  // main.dart from ONE shared http.Client + the server-side Anthropic key, so
  // the monolith never imports package:http and one client is reused. Null →
  // 503 advisor_answer_not_configured.
  AnthropicToolUseCompleteFn? anthropicToolUseCompleteFnForAnswer,
  // Encryption-first seam (A4-ENC): the abstract CMK resolver (the concrete
  // proxy resolver is built only when ADVISOR_CONVERSATION_CMK is provisioned)
  // + the encrypted-history sink. Either null → 503
  // advisor_answer_encryption_unavailable (fail closed; no answer without a
  // persisted encrypted record). HP #7.
  AdvisorConversationCmkResolver? advisorConversationCmkResolver,
  AdvisorConversationLogRepository? advisorConversationLogRepository,
  // Operational read tools (A4.6): the three tenant-pool-backed repos. Null →
  // the operational tools are omitted from the catalog (the engine can still
  // answer from methodology). HP #4: scope is the verified caller's only.
  TargetCycleRepository? advisorAnswerTargetCycleRepository,
  WeeklyPlanSnapshotRepository? advisorAnswerWeeklyPlanSnapshotRepository,
  ShiftRecordsReadRepository? advisorAnswerShiftRecordsReadRepository,
  // The answer route REUSES the existing retrieval bindings
  // (corpusRetrievalService / corpusQueryEmbeddingGateway /
  // voyageApiKeyForRetrieval / corpusRerankGateway /
  // voyageRerankApiKeyForRetrieval) for its retrieve_methodology tool, and the
  // existing metering bindings (usageGuard / accountingStore / now). No new
  // duplicate params for those.
  bool trustProxyAuditHeaders = false,
  ProxyRequestLogPolicy requestLogPolicy =
      const ProxyRequestLogPolicy.metaOnly(),
  DateTime Function()? now,
  List<String> adminCorsAllowList = const <String>[],
}) async {
  final response = request.response;
  final clock = now ?? DateTime.now;

  // B1.A3 — permission_version check helper. Resolves the operator scope and
  // then, when [permissionVersionChecker] is wired, compares the JWT claim
  // `permission_version` against the DB value. On mismatch the helper writes
  // a 401 and returns null so the caller can early-return.
  //
  // Usage:
  //   final scope = await requireScopeChecked(...);
  //   if (scope == null) return;
  //
  // The helper is declared here so it can capture [permissionVersionChecker]
  // from the enclosing scope; per-route callers adopt it incrementally.
  // ignore: unused_element
  Future<OperatorContext?> requireScopeChecked({
    required ProxyRequestGuard guard,
    required String? authorizationHeader,
    required HttpResponse resp,
  }) async {
    OperatorContext scope;
    try {
      scope = await guard.requireOperatorContext(
        authorizationHeader: authorizationHeader,
      );
    } on ProxyAuthError catch (error) {
      _writeJson(resp, error.statusCode, <String, Object?>{
        'error': error.message,
      });
      return null;
    }
    if (permissionVersionChecker != null && scope.permissionVersion != null) {
      final dbVersion = await permissionVersionChecker.fetch(scope.userId);
      if (dbVersion != null && dbVersion != scope.permissionVersion) {
        _writeJson(resp, 401, <String, Object?>{
          'error': 'permission_version_mismatch',
          'message':
              'your permissions have changed; please sign out and sign back in',
        });
        return null;
      }
    }
    return scope;
  }

  // HARD-G observability: read X-Correlation-Id (UUID v4 only),
  // generate one when absent or malformed, mint a per-request
  // request_id, set the response header, and run the body in a zone
  // so nested log() calls inherit the IDs.
  final inboundCorrelationId = request.headers.value(correlationIdHeaderName);
  final correlationId =
      (inboundCorrelationId != null && isValidUuidV4(inboundCorrelationId))
      ? inboundCorrelationId
      : generateUuidV4();
  final requestId = generateUuidV4();
  response.headers.set(correlationIdHeaderName, correlationId);
  await withProxyLogContext(ProxyLogContext(correlationId: correlationId, requestId: requestId), () async {
    try {
      try {
        final path = request.uri.path;
        // HARD-C — admin CORS dispatch. Each admin path family resolves
        // to a single methods list; preflight + non-preflight responses
        // both flow through the central helpers (respondAdminCorsPreflight
        // / _applyAdminCorsHeaders) so the origin allow-list lives in
        // exactly one place.
        final isAdminOperatorLocationPath = _isAdminOperatorOrLocationPath(
          path,
        );
        final isAdminPricingPath = _isAdminPricingPath(path);
        final isAdminDataAccuracyPath = _isAdminDataAccuracyPath(path);
        final isAdminVendorApplicabilityPath = _isAdminVendorApplicabilityPath(
          path,
        );
        final isAdminCorpusPath = _isAdminCorpusPath(path);
        final isAdminIntegrationsPath = _isAdminIntegrationsPath(path);
        final isAdminFeatureFlagsPath = _isAdminFeatureFlagsPath(path);
        final isAdminDebugPath = _isAdminDebugPath(path);
        final isAdminObservabilityPath = _isAdminObservabilityPath(path);
        final isDeepHealthPath = path == deepHealthPath;
        final isAuthPath = _isAuthCorsPath(path);
        final List<String>? adminCorsMethods = isAdminOperatorLocationPath
            ? kAdminOperatorLocationCorsMethods
            : isAdminPricingPath
            ? kAdminPricingCorsMethods
            : isAdminDataAccuracyPath
            ? kAdminDataAccuracyCorsMethods
            : isAdminVendorApplicabilityPath
            ? kAdminVendorApplicabilityCorsMethods
            : isAdminCorpusPath
            ? kAdminCorpusCorsMethods
            : isAdminIntegrationsPath
            ? kAdminIntegrationsCorsMethods
            : isAdminFeatureFlagsPath
            ? kAdminFeatureFlagsCorsMethods
            : isAdminDebugPath
            ? kAdminDebugConsoleCorsMethods
            : isAdminObservabilityPath
            ? kAdminObservabilityCorsMethods
            : isDeepHealthPath
            ? kAdminHealthCorsMethods
            : isAuthPath
            ? kAuthCorsMethods
            : null;
        if (adminCorsMethods != null) {
          if (request.method == 'OPTIONS') {
            respondAdminCorsPreflight(
              request,
              adminCorsAllowList,
              allowedMethods: adminCorsMethods,
            );
            return;
          }
          _applyAdminCorsHeaders(request, adminCorsAllowList);
        }

        // HARD-C — request body cap. POST/PATCH/PUT must declare a
        // Content-Length and stay under the per-route ceiling. Missing
        // or oversized bodies short-circuit with 413 before any
        // handler runs. CORS headers were already applied above for
        // admin paths, so the browser still sees the echo on the 413
        // response.
        //
        // CODE_HEALTH L4 — the cap is now per-route. The graph-
        // candidate batch endpoint admits 16 MB; everything else stays
        // at the 1 MB default. See [resolveRequestBodyLimitBytes].
        if (_isBodyMethod(request.method)) {
          final declaredLength = request.contentLength;
          final routeLimit = resolveRequestBodyLimitBytes(path);
          if (declaredLength < 0 || declaredLength > routeLimit) {
            _writeJson(response, 413, <String, Object?>{
              'error': 'request_too_large',
              'limit_bytes': routeLimit,
            });
            return;
          }
        }

        if (request.method == 'GET' &&
            (path == healthPath || path == readinessPath)) {
          _writeJson(response, 200, <String, Object?>{'status': 'ok'});
          return;
        }

        // Lane B B11.2.b — RFC 9470 step-up challenge gate. Runs BEFORE
        // every sensitive route handler. See
        // `auth_step_up_routes.dart::runStepUpGate` for the full
        // contract; in short the gate intercepts when the route is in
        // `kStepUpSensitiveRoutes`, resolves operator scope, and
        // dispatches the router. Step-Up-Challenge-Id flows through
        // the HEADER ONLY (addendum A1). When `stepUpChallengeRouter`
        // is null the gate skips entirely (legacy "no step-up" mode).
        if (stepUpChallengeRouter != null &&
            stepUpChallengeRouter.isSensitive(
              method: request.method,
              path: path,
            ) &&
            await runStepUpGate(
              request: request,
              path: path,
              authGuard: authGuard,
              router: stepUpChallengeRouter,
              now: clock,
            )) {
          return;
        }

        if (request.method == 'GET' && path == deepHealthPath) {
          // Collect in-process runtime gauges (Postgres pool, pubsub
          // ring buffer) at request time. The gauges are O(1) reads of
          // live counters; when the holder is null (tests / dev
          // scaffolds without production wiring) the envelope omits
          // the `runtime_gauges` field so existing assertions stay
          // green (A1 §2.4 instrumentation items #3 + #4).
          final runtimeGaugesSnapshot = proxyRuntimeGauges?.snapshotJson();
          if (healthCheckStore == null) {
            _writeJson(response, 503, <String, Object?>{
              ...const ProxyHealthStatus(
                postgresOk: false,
                ageOk: false,
                pgvectorOk: false,
              ).toJson(checkedAt: clock().toUtc()),
              if (runtimeGaugesSnapshot != null &&
                  runtimeGaugesSnapshot.isNotEmpty)
                'runtime_gauges': runtimeGaugesSnapshot,
              'error': 'health_check_not_configured',
              'message':
                  'route requires a ProxyHealthCheckStore to be installed',
            });
            return;
          }

          ProxyHealthStatus status;
          try {
            status = await healthCheckStore.check();
          } on Exception catch (_) {
            // A3.4: `healthCheckStore.check()` wraps arbitrary registry
            // producers + dep probes (PgException / TimeoutException /
            // IOException / FormatException / any Exception). Narrow to
            // `Exception` so `Error`s keep propagating per C4.
            _writeJson(response, 503, <String, Object?>{
              ...const ProxyHealthStatus(
                postgresOk: false,
                ageOk: false,
                pgvectorOk: false,
              ).toJson(checkedAt: clock().toUtc()),
              if (runtimeGaugesSnapshot != null &&
                  runtimeGaugesSnapshot.isNotEmpty)
                'runtime_gauges': runtimeGaugesSnapshot,
              'error': 'health_check_failed',
              'message': 'proxy dependency health check failed',
            });
            return;
          }

          final envelope = <String, Object?>{
            ...status.toJson(checkedAt: clock().toUtc()),
            if (runtimeGaugesSnapshot != null &&
                runtimeGaugesSnapshot.isNotEmpty)
              'runtime_gauges': runtimeGaugesSnapshot,
          };
          _writeJson(response, status.ok ? 200 : 503, envelope);
          return;
        }

        if (request.method == 'GET' && path == scopeSmokePath) {
          OperatorContext scope;
          try {
            scope = await authGuard.requireOperatorContext(
              authorizationHeader: request.headers.value(
                HttpHeaders.authorizationHeader,
              ),
            );
          } on ProxyAuthError catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.message,
            });
            return;
          }

          _writeJson(response, 200, <String, Object?>{
            'user_id': scope.userId,
            'operator_id': scope.operatorId,
            'location_id': scope.locationId,
            'roles': scope.roles,
            'note':
                '11a.10a scaffold smoke. No provider call performed. '
                'Budgets and rate limits land in 11a.10b.',
          });
          return;
        }

        // Phase 10a.0 — realtime push WebSocket. Authenticates via the
        // standard `requireOperatorContext` path (operator_id from JWT,
        // never from URL). Returns 503 when the publisher is not
        // installed so unauth probes (`/health`, `/healthz`, `/readyz`)
        // do not regress on environments that ship without the bridge.
        if (path == realtimeSubscribePath) {
          if (realtimePublisher == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'realtime_publisher_not_configured',
              'message':
                  'route requires an InProcessRealtimePublisher to be installed',
            });
            return;
          }
          await handleRealtimeUpgrade(
            request: request,
            authGuard: authGuard,
            publisher: realtimePublisher,
            replayFetcher: realtimeReplayFetcher,
          );
          return;
        }

        // Phase 10a.4 — bridge tripwire status. Read-only,
        // platform-wide aggregate over the four Q22 metrics. The sync
        // badge polls this every ~60s so it can shift to "Degraded"
        // when ANY metric fires red while the WebSocket itself is
        // still alive. No tenant identifiers in the response payload.
        if (request.method == 'GET' && path == realtimeTripwireStatusPath) {
          if (realtimeTripwireGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'realtime_tripwire_gateway_not_configured',
              'message':
                  'route requires a RealtimeTripwireProxyGateway to be installed',
            });
            return;
          }
          try {
            final body = await realtimeTripwireGateway.fetch();
            _writeJson(response, 200, body);
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'realtime_tripwire_status',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'realtime_tripwire_unavailable',
              'message': 'tripwire status is unavailable; please retry',
            });
          }
          return;
        }

        final weeklyPlanMatch = WeeklyPlanRouter.match(path, request.method);
        if (weeklyPlanMatch != null) {
          final router = weeklyPlanRouter ?? WeeklyPlanRouter.global;
          if (router == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'weekly_plan_router_not_configured',
              'message': 'route requires a WeeklyPlanRouter to be installed',
            });
            return;
          }
          final scope = weeklyPlanMatch.action == WeeklyPlanRouteAction.read
              ? await _resolveLocationReadContextOrWrite(
                  request: request,
                  response: response,
                  authGuard: authGuard,
                  operatorId: weeklyPlanMatch.operatorId,
                  locationId: weeklyPlanMatch.locationId,
                )
              : await _resolveOperatorContextOrWrite(
                  request,
                  response,
                  authGuard,
                );
          if (scope == null) return;
          final weeklyScopeAllowed =
              weeklyPlanMatch.action == WeeklyPlanRouteAction.read
              ? await _operatorLocationScopeAllowed(
                  scope: scope,
                  operatorId: weeklyPlanMatch.operatorId,
                  locationId: weeklyPlanMatch.locationId,
                  businessScopeGateway: businessScopeGateway,
                )
              : scope.operatorId == weeklyPlanMatch.operatorId &&
                    scope.locationId == weeklyPlanMatch.locationId;
          if (!weeklyScopeAllowed) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message':
                  'requested weekly-plan scope does not match caller scope',
            });
            return;
          }
          Map<String, Object?> body = const <String, Object?>{};
          String? idempotencyKey;
          if (weeklyPlanMatch.action != WeeklyPlanRouteAction.read) {
            final permitted = await _requireAdminPermissionOrWrite(
              response: response,
              guard: adminPermissionGuard,
              scope: scope,
              permissionKey: weeklyPlanLockPermissionKey,
              requestedAt: clock().toUtc(),
            );
            if (!permitted) return;
            idempotencyKey = request.headers.value('Idempotency-Key')?.trim();
            final bodyResult = await readOperatorJsonBody(request);
            if (bodyResult.errorStatus != null) {
              _writeJson(
                response,
                bodyResult.errorStatus!,
                bodyResult.errorBody!,
              );
              return;
            }
            body = bodyResult.body!;
          }
          try {
            final result = await router.handle(
              match: weeklyPlanMatch,
              method: request.method,
              path: path,
              queryParameters: request.uri.queryParameters,
              actorUserId: scope.userId,
              actorKind: scope.actorKind,
              idempotencyKey: idempotencyKey,
              body: body,
            );
            _writeJson(response, result.statusCode, result.body);
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'weekly_plan',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'weekly_plan_unavailable',
              'message': 'weekly-plan truth is unavailable; please retry',
            });
          }
          return;
        }

        final selectedStarMatch = SelectedStarTargetRouter.match(
          path,
          request.method,
        );
        if (selectedStarMatch != null) {
          final router =
              selectedStarTargetRouter ?? SelectedStarTargetRouter.global;
          if (router == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'selected_star_router_not_configured',
              'message':
                  'route requires a SelectedStarTargetRouter to be installed',
            });
            return;
          }
          final scope =
              selectedStarMatch.action == SelectedStarTargetRouteAction.read
              ? await _resolveLocationReadContextOrWrite(
                  request: request,
                  response: response,
                  authGuard: authGuard,
                  operatorId: selectedStarMatch.operatorId,
                  locationId: selectedStarMatch.locationId,
                )
              : await _resolveOperatorContextOrWrite(
                  request,
                  response,
                  authGuard,
                );
          if (scope == null) return;
          final selectedStarScopeAllowed =
              selectedStarMatch.action == SelectedStarTargetRouteAction.read
              ? await _operatorLocationScopeAllowed(
                  scope: scope,
                  operatorId: selectedStarMatch.operatorId,
                  locationId: selectedStarMatch.locationId,
                  businessScopeGateway: businessScopeGateway,
                )
              : scope.operatorId == selectedStarMatch.operatorId &&
                    scope.locationId == selectedStarMatch.locationId;
          if (!selectedStarScopeAllowed) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message':
                  'requested selected-star scope does not match caller scope',
            });
            return;
          }
          Map<String, Object?> body = const <String, Object?>{};
          String? idempotencyKey;
          if (selectedStarMatch.action != SelectedStarTargetRouteAction.read) {
            final permitted = await _requireAdminPermissionOrWrite(
              response: response,
              guard: adminPermissionGuard,
              scope: scope,
              permissionKey: selectedStarWritePermissionKey,
              requestedAt: clock().toUtc(),
            );
            if (!permitted) return;
            idempotencyKey = request.headers.value('Idempotency-Key')?.trim();
            final bodyResult = await readOperatorJsonBody(request);
            if (bodyResult.errorStatus != null) {
              _writeJson(
                response,
                bodyResult.errorStatus!,
                bodyResult.errorBody!,
              );
              return;
            }
            body = bodyResult.body!;
          }
          try {
            final result = await router.handle(
              match: selectedStarMatch,
              method: request.method,
              path: path,
              queryParameters: request.uri.queryParameters,
              actorUserId: scope.userId,
              actorKind: scope.actorKind,
              idempotencyKey: idempotencyKey,
              body: body,
            );
            _writeJson(response, result.statusCode, result.body);
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'selected_star_target',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'selected_star_target_unavailable',
              'message': 'selected-star truth is unavailable; please retry',
            });
          }
          return;
        }

        final businessScopeMatch = BusinessScopeRouter.match(
          path,
          request.method,
        );
        if (businessScopeMatch != null) {
          final gateway = businessScopeGateway;
          final router =
              businessScopeRouter ??
              (gateway == null ? null : BusinessScopeRouter(gateway: gateway));
          if (router == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'business_scope_router_not_configured',
              'message': 'route requires a BusinessScopeRouter to be installed',
            });
            return;
          }
          final claims = await _resolveVerifiedClaimsOrWrite(
            request,
            response,
            authGuard,
          );
          if (claims == null) return;
          final operatorId = claims.operatorId;
          final locationId = claims.locationId;
          if (operatorId != null && operatorId.isNotEmpty) {
            bindOperatorIdToLogContext(operatorId);
          }
          try {
            final result = await router.handle(
              match: businessScopeMatch,
              actorUserId: claims.userId,
              actorRoles: claims.roles,
              actorOperatorId: operatorId,
              actorLocationId: locationId,
            );
            _writeJson(response, result.statusCode, result.body);
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'business_scopes',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'business_scopes_unavailable',
              'message': 'business scopes are unavailable; please retry',
            });
          }
          return;
        }

        // Operator Web W4.B - per-tenant audit-chain-anchor read.
        // Operator-scoped: operatorId resolved from the JWT, never
        // from the URL or body. RLS clamps the read inside the
        // gateway via the tenant transaction wrapper.
        final auditChainAnchorMatch = AuditChainAnchorsRouter.match(
          path,
          request.method,
        );
        if (auditChainAnchorMatch != null) {
          if (auditChainAnchorsGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'audit_chain_anchors_not_configured',
              'message':
                  'audit chain anchors gateway is not installed; please retry',
            });
            return;
          }
          OperatorContext scope;
          try {
            scope = await authGuard.requireOperatorContext(
              authorizationHeader: request.headers.value(
                HttpHeaders.authorizationHeader,
              ),
            );
          } on ProxyAuthError catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.message,
            });
            return;
          }
          try {
            final router = AuditChainAnchorsRouter(
              gateway: auditChainAnchorsGateway,
              now: clock,
            );
            final result = await router.handle(
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              userId: scope.userId,
            );
            _writeJson(response, result.statusCode, result.body);
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'audit_chain_anchors',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'audit_chain_anchors_unavailable',
              'message':
                  'audit chain anchor lookup is unavailable; please retry',
            });
          }
          return;
        }

        final demoModeMasterSwitchMatch = DemoModeMasterSwitchRouter.match(
          path,
          request.method,
        );
        if (demoModeMasterSwitchMatch != null) {
          if (demoModeMasterSwitchRouter == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'demo_mode_master_switch_not_configured',
              'message':
                  'route requires a DemoModeMasterSwitchRouter to be installed',
            });
            return;
          }
          final scope = await _resolveLocationReadContextOrWrite(
            request: request,
            response: response,
            authGuard: authGuard,
            operatorId: demoModeMasterSwitchMatch.operatorId,
            locationId: demoModeMasterSwitchMatch.locationId,
          );
          if (scope == null) return;
          if (!scope.roles.any(kOperatorWriteRoles.contains)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'forbidden',
              'message': 'operator owner role is required',
              'required_roles': kOperatorWriteRoles.toList(),
            });
            return;
          }
          if (!await _operatorLocationScopeAllowed(
            scope: scope,
            operatorId: demoModeMasterSwitchMatch.operatorId,
            locationId: demoModeMasterSwitchMatch.locationId,
            businessScopeGateway: businessScopeGateway,
          )) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message':
                  'requested demo-mode scope does not match caller scope',
            });
            return;
          }
          final headerKey = request.headers.value('Idempotency-Key')?.trim();
          if (headerKey == null || headerKey.isEmpty) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'idempotency_key_missing',
              'message': 'Idempotency-Key header is required',
            });
            return;
          }
          if (headerKey.length > 200) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'idempotency_key_too_long',
              'message':
                  'Idempotency-Key header must be 200 characters or fewer',
            });
            return;
          }
          final bodyResult = await readOperatorJsonBody(request);
          if (bodyResult.errorStatus != null) {
            _writeJson(
              response,
              bodyResult.errorStatus!,
              bodyResult.errorBody!,
            );
            return;
          }
          try {
            final result = await demoModeMasterSwitchRouter.handle(
              operatorId: demoModeMasterSwitchMatch.operatorId,
              locationId: demoModeMasterSwitchMatch.locationId,
              actorUserId: scope.userId,
              idempotencyKey: headerKey,
              body: bodyResult.body!,
            );
            _writeJson(response, result.statusCode, result.body);
          } on DemoModeMasterSwitchRejected catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.code,
              'message': error.message,
            });
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'demo_mode_master_switch',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'demo_mode_master_switch_unavailable',
              'message': 'demo-mode switch is unavailable; please retry',
            });
          }
          return;
        }

        final mobileOperationalPath = _mobileOperationalPath(path);
        if (request.method == 'PATCH' &&
            mobileOperationalPath != null &&
            (mobileOperationalPath.resource == 'data_accuracy_settings' ||
                mobileOperationalPath.resource ==
                    'data_accuracy_settings/manual_covers' ||
                mobileOperationalPath.resource ==
                    'data_accuracy_service_period_settings')) {
          await _routeOperatorDataAccuracySettingsWrite(
            request: request,
            response: response,
            authGuard: authGuard,
            gateway: mobileOperationalSyncGateway,
            businessScopeGateway: businessScopeGateway,
            idempotencyStore: adminRequestIdempotencyStore,
            target: mobileOperationalPath,
          );
          return;
        }
        if (request.method == 'GET' && mobileOperationalPath != null) {
          await _routeMobileOperationalSync(
            request: request,
            response: response,
            authGuard: authGuard,
            gateway: mobileOperationalSyncGateway,
            businessScopeGateway: businessScopeGateway,
            target: mobileOperationalPath,
          );
          return;
        }

        if (request.method == 'GET' && path == usageSmokePath) {
          if (usageGuard == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'usage_guard_not_configured',
              'message': 'route requires a ProxyUsageGuard to be installed',
            });
            return;
          }

          OperatorContext scope;
          try {
            scope = await authGuard.requireOperatorContext(
              authorizationHeader: request.headers.value(
                HttpHeaders.authorizationHeader,
              ),
            );
          } on ProxyAuthError catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.message,
            });
            return;
          }

          final estTokensRaw = request.uri.queryParameters['est_tokens'];
          final estTokens = int.tryParse(estTokensRaw ?? '') ?? 100;
          final estimate = UsageEstimate(requestTokens: estTokens);

          UsageDecisionAllowed decision;
          try {
            decision = await usageGuard.requireAllowed(
              operator: scope,
              estimate: estimate,
            );
          } on UsageRefusal catch (refusal) {
            _writeJson(response, refusal.statusCode, refusal.toJson());
            return;
          }

          // HARD-A: advance the per-minute bucket so caps actually
          // enforce on subsequent requests. Smoke calls carry cost 0 —
          // the request count is what matters here.
          await usageGuard.recordAllowed(
            operator: scope,
            decision: decision,
            costCentsToAdd: 0,
          );

          // HARD-A wire shape per `hardening_production_wiring_contract.md`:
          // `{minute_remaining, month_remaining, tier}` with no tenant
          // identifiers. Tier limits / timeout / max-output are still
          // returned alongside so the smoke caller can confirm the active
          // tier policy without a separate call.
          _writeJson(response, 200, <String, Object?>{
            'tier': decision.tier.id,
            'minute_remaining': decision.remainingRequestsThisMinute,
            'month_remaining': decision.remainingCostCentsThisMonth,
            'request_timeout_seconds': decision.tier.requestTimeoutSeconds,
            'max_output_tokens': decision.tier.maxOutputTokens,
            'cap_request_tokens': decision.tier.maxRequestTokens,
            'cap_requests_per_minute': decision.tier.maxRequestsPerMinute,
            'cap_monthly_cost_cents': decision.tier.maxMonthlyCostCents,
            'estimate_request_tokens': estimate.requestTokens,
          });
          return;
        }

        if (request.method == 'GET' && path == advisorSmokePath) {
          if (accountingStore == null || llmProvider == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'advisor_smoke_not_configured',
              'message':
                  'route requires ProxyAccountingStore and ProxyLlmProvider',
            });
            return;
          }

          OperatorContext scope;
          try {
            scope = await authGuard.requireOperatorContext(
              authorizationHeader: request.headers.value(
                HttpHeaders.authorizationHeader,
              ),
            );
          } on ProxyAuthError catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.message,
            });
            return;
          }

          final idempotencyKey = request.headers
              .value('Idempotency-Key')
              ?.trim();
          if (idempotencyKey == null || idempotencyKey.isEmpty) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_idempotency_key',
              'message': 'Idempotency-Key header is required',
            });
            return;
          }

          // P1b — wall-clock anchor for the measured `latency_ms` written
          // into proxy_request_stats at completion. Captured after auth +
          // idempotency-key validation so it spans the metered work (cap
          // check, prompt build, provider call, accounting writes) rather
          // than client-header parsing.
          final requestStartedAt = clock();

          final params = request.uri.queryParameters;
          final usageClass = _nonBlankOr(params['usage_class'], 'advisor_qa');
          final queryClass = _nonBlankOr(
            params['query_class'],
            'methodology_lookup',
          );
          final subscriptionTier = _nonBlankOr(
            params['subscription_tier'],
            'basic',
          );
          final corpusVersion = _nonBlankOr(
            params['corpus_version'],
            'launch_v1',
          );
          final question = _nonBlankOr(params['q'], 'advisor smoke question');
          final estimate = ProxyUsageChargeEstimate(
            tokenCount: int.tryParse(params['tokens'] ?? '') ?? 100,
            costCents: int.tryParse(params['cost_cents'] ?? '') ?? 1,
          );

          // HARD-A: per-minute / monthly cap pre-check via the proxy
          // usage guard. The accounting store's tier-cap check (below)
          // gates per-tier monthly spend; this guard gates per-minute
          // request rate + monthly cost in `advisor_proxy_usage_counters`.
          // Both must pass before the pipeline runs. The guard is
          // optional — only checked when wired (production main.dart wires
          // it; some tests pass null).
          UsageDecisionAllowed? usageDecision;
          if (usageGuard != null) {
            try {
              usageDecision = await usageGuard.requireAllowed(
                operator: scope,
                estimate: UsageEstimate(requestTokens: estimate.tokenCount),
              );
            } on UsageRefusal catch (refusal) {
              _writeJson(response, refusal.statusCode, refusal.toJson());
              return;
            }
          }

          const tierRouter = SubscriptionLlmTierRouter();
          const modelRouting = ProxyLlmModelRouting();
          const promptBuilder = AdvisorPromptCacheBuilder();
          // Plans & Limits V1 (5c): the operator's plan sets the model
          // ceiling (Haiku vs Sonnet); the query class may downgrade a
          // Sonnet-capable plan to Haiku but never upgrade past the plan.
          // See SubscriptionLlmTierRouter.tierFor / _modelTierForPlan.
          final llmTier = tierRouter.tierFor(
            subscriptionTier: subscriptionTier,
            queryClass: queryClass,
          );
          final modelId = modelRouting.modelIdFor(llmTier);
          final telemetry = ProxyUsageTelemetry(
            queryClass: queryClass,
            cacheHit: false,
            llmTier: llmTier.id,
            modelUsed: modelId,
          );

          ProxyAccountingStartResult start;
          try {
            start = await accountingStore.startRequest(
              idempotencyKey: idempotencyKey,
              requestType: 'advisor_smoke',
              operator: scope,
              usageClass: usageClass,
              telemetry: telemetry,
              estimate: estimate,
              now: clock().toUtc(),
            );
          } on Exception catch (_) {
            // A3.4: `accountingStore.startRequest` surfaces PgException,
            // TimeoutException, IOException, closed-pool wraps. Narrow to
            // `Exception` so `Error`s keep propagating per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'accounting_store_unavailable',
              'message': 'proxy accounting store unavailable',
            });
            return;
          }

          if (start is ProxyAccountingReplayed) {
            _writeJson(response, 200, <String, Object?>{
              ...start.responsePayload,
              'idempotent_replay': true,
            });
            return;
          }

          if (start is ProxyAccountingRefused) {
            _writeJson(response, 402, <String, Object?>{
              'error': 'usage_cap_reached',
              'message': 'usage cap reached before provider call',
              'cap_status': start.capStatus.toJson(),
            });
            return;
          }

          final reserved = start as ProxyAccountingReserved;
          final promptBlocks = promptBuilder.build(
            corpusVersion: corpusVersion,
            methodologyContext: 'launch methodology context placeholder',
            toolDefinitions: 'advisor tool definitions placeholder',
            operatorContext:
                'operator=${scope.operatorId};location=${scope.locationId}',
          );
          final llmRequest = ProxyLlmRequest(
            question: question,
            promptBlocks: promptBlocks,
            tier: llmTier,
            modelId: modelId,
            cacheKey: promptBuilder.cacheKeyForCorpusVersion(corpusVersion),
            maxOutputTokens: PolicyTier.launch.maxOutputTokens,
          );

          // CODE_HEALTH TOKEN-CAP-REAL — global per-request token cap on
          // outbound LLM dispatch. Independent of the per-tier
          // `PolicyTier.maxRequestTokens` cap above (which only fires when
          // [ProxyUsageGuard] is wired). This cap fires regardless of guard
          // wiring so a misconfigured deploy or test that ducks the guard
          // cannot ship an unbounded payload to the provider. Hard cap —
          // rejects with HTTP 413 (`request_too_large`); no silent trim.
          final maxTokensPerRequest = resolveMaxTokensPerRequest();
          if (estimate.tokenCount > maxTokensPerRequest) {
            _writeJson(response, 413, <String, Object?>{
              'error': 'request_too_large',
              'message': 'estimated request tokens exceed the per-request cap',
              'estimate_request_tokens': estimate.tokenCount,
              'cap_request_tokens': maxTokensPerRequest,
            });
            return;
          }

          final questionHash = sha256.convert(utf8.encode(question)).toString();

          AdvisorPipelineResult pipelineResult;
          if (advisorRequestPipeline != null) {
            pipelineResult = await advisorRequestPipeline.execute(
              llmProvider: llmProvider,
              llmRequest: llmRequest,
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              queryClass: queryClass,
              questionHash: questionHash,
              corpusVersion: corpusVersion,
            );
          } else {
            try {
              final completion = await llmProvider.complete(llmRequest);
              pipelineResult = AdvisorPipelineResult(
                completion: completion,
                cachedAnswer: null,
                refused: false,
                circuitStateAtStart: CircuitState.closed,
                fallbackUsed: 'none',
                decision: AcquireDecision.allow,
              );
            } on Exception catch (error) {
              // A3.4: `llmProvider.complete` surfaces TimeoutException,
              // IOException, HttpException, FormatException, provider-
              // specific Exception subtypes. Narrow so `Error`s propagate.
              //
              // P1b.2 — Support logs failure/timeout telemetry (plan §12).
              // This is the one post-reservation, pre-completeRequest bail
              // path that represents a FAILED LLM request: the provider call
              // threw, so the request early-returns 503 here and never
              // reaches completeRequest's `result_status='success'` write.
              // Record a real failure row so Support logs shows it as an
              // honest error/timeout instead of a derived `unknown`.
              //
              // Idempotent: this point is reached only on a REAL attempt — an
              // idempotency replay early-returns at `ProxyAccountingReplayed`
              // above, before `reserved` exists — so exactly one row is
              // written per failed attempt and a replay never duplicates it.
              // Correlation: we have `reserved.requestId` (the reservation
              // minted upstream) so the row joins back to the proxy_requests
              // row. If the reservation could not surface a request_id we
              // still record the failure (the table allows a null request_id;
              // the row is honest, just uncorrelated) — but a failure BEFORE
              // any reservation (e.g. startRequest itself failing) returns a
              // different 503 upstream and writes nothing, as intended.
              //
              // Honest nulls: the provider returned nothing, so token counts
              // and cost are genuinely UNKNOWN -> null (NOT zero, which would
              // imply a measured no-op). `model_id` is the model the proxy
              // ROUTED to and attempted (deterministic from tier routing, not
              // fabricated); `provider` derives from it. Latency is the
              // measured wall-clock to the point of failure, clamped >= 0.
              final isTimeout =
                  error is TimeoutException ||
                  error is DependencyTimeoutException;
              final failureLatencyMs = clock()
                  .difference(requestStartedAt)
                  .inMilliseconds;
              final failureStats = ProxyRequestStats(
                usageClass: usageClass,
                resultStatus: isTimeout ? 'timeout' : 'error',
                requestId: reserved.requestId,
                actorUserId: scope.isServicePrincipal ? null : scope.userId,
                provider: providerFromModelId(modelId),
                modelId: modelId,
                modelVersion: null,
                promptTokenCount: null,
                completionTokenCount: null,
                costUsd: null,
                latencyMs: failureLatencyMs < 0 ? 0 : failureLatencyMs,
              );
              try {
                await accountingStore.recordRequestStats(
                  operator: scope,
                  stats: failureStats,
                );
              } on Exception catch (_) {
                // Best-effort telemetry: a stats-write failure must NOT
                // change the client outcome or leak store internals. The
                // 503 below is written regardless. `Error`s still propagate
                // per C4.
              }
              _writeJson(response, 503, <String, Object?>{
                'error': 'llm_provider_unavailable',
                'message': 'LLM provider unavailable',
              });
              return;
            }
          }

          // Final telemetry written post-chain. `cache_hit` flips to true
          // when the fallback cache served the response so the existing
          // `usage_logs.cache_hit` contract stays consistent with
          // `fallback_used='cache'`. `circuit_state` and `fallback_used` come
          // from the pipeline; everything else carries from the pre-flight
          // telemetry built at line 5362-5367.
          final fallbackServedFromCache =
              pipelineResult.fallbackUsed == 'cache';
          final finalTelemetry = ProxyUsageTelemetry(
            queryClass: telemetry.queryClass,
            cacheHit: telemetry.cacheHit || fallbackServedFromCache,
            llmTier: telemetry.llmTier,
            modelUsed: telemetry.modelUsed,
            billingOwnerOrgUnitId: telemetry.billingOwnerOrgUnitId,
            scopedOrgUnitId: telemetry.scopedOrgUnitId,
            staffId: telemetry.staffId,
            workflowId: telemetry.workflowId,
            batchMode: telemetry.batchMode,
            circuitState: circuitStateToWireString(
              pipelineResult.circuitStateAtStart,
            ),
            fallbackUsed: pipelineResult.fallbackUsed,
          );

          // Final estimate written to `usage_logs` reflects ACTUAL usage,
          // not the pre-flight estimate used for the cap-check. Primary
          // success rolls up input estimate + provider output; cache hits
          // and graceful refusals consumed no provider tokens.
          final ProxyUsageChargeEstimate finalEstimate;
          if (pipelineResult.completion != null) {
            final completion = pipelineResult.completion!;
            finalEstimate = ProxyUsageChargeEstimate(
              tokenCount: estimate.tokenCount + completion.outputTokens,
              costCents: estimate.costCents + completion.costCents,
            );
          } else {
            finalEstimate = const ProxyUsageChargeEstimate(
              tokenCount: 0,
              costCents: 0,
            );
          }

          Map<String, Object?> responsePayload;
          if (pipelineResult.completion != null) {
            final completion = pipelineResult.completion!;
            responsePayload = <String, Object?>{
              'status': 'ok',
              'operator_id': scope.operatorId,
              'location_id': scope.locationId,
              'usage_class': usageClass,
              'query_class': queryClass,
              'llm_tier': completion.tier.id,
              'model_used': completion.modelId,
              'cache_key': promptBuilder.cacheKeyForCorpusVersion(
                corpusVersion,
              ),
              'prompt_cache_breakpoints': <String>[
                for (final block in promptBlocks)
                  if (block.cacheBreakpoint) block.id,
              ],
              'cap_status': reserved.capStatus.toJson(),
              'answer': completion.text,
              'idempotent_replay': false,
              'request_log_preview': requestLogPolicy.buildEntry(
                operator: scope,
                usageClass: usageClass,
                queryClass: queryClass,
                tokenCount: estimate.tokenCount + completion.outputTokens,
                costCents: estimate.costCents + completion.costCents,
                statusCode: 200,
                question: question,
                answer: completion.text,
              ),
            };
          } else {
            final refusal = GracefulRefusalResponse(
              cachedAnswer: pipelineResult.cachedAnswer,
              providerId: 'anthropic',
              circuitState: finalTelemetry.circuitState,
            );
            responsePayload = <String, Object?>{
              ...refusal.toJson(),
              'cap_status': reserved.capStatus.toJson(),
              'idempotent_replay': false,
            };
          }

          try {
            await accountingStore.commitUsageLog(
              operator: scope,
              usageClass: usageClass,
              telemetry: finalTelemetry,
              estimate: finalEstimate,
              now: clock().toUtc(),
            );
          } on Exception catch (_) {
            // A3.4: same accounting-store surface as startRequest (see
            // above); `Error`s propagate per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'accounting_store_unavailable',
              'message': 'proxy accounting store unavailable',
            });
            return;
          }

          // HARD-A: advance `advisor_proxy_usage_counters` so per-minute
          // and monthly caps actually enforce on the next request. Cost
          // carries the final post-pipeline value, not the pre-call
          // estimate.
          if (usageGuard != null && usageDecision != null) {
            await usageGuard.recordAllowed(
              operator: scope,
              decision: usageDecision,
              costCentsToAdd: finalEstimate.costCents,
            );
          }

          // P1b — Support logs stats-only telemetry (plan §12). One row
          // per REAL request, written inside completeRequest's transaction
          // (no extra round-trip). MEASURED latency = wall-clock from the
          // post-validation anchor to now; clamped to >= 0 so a backwards
          // test clock cannot violate the table CHECK. result_status is
          // 'success': completeRequest is reached only on a normal proxy
          // completion (a graceful cache/refusal degradation still completed
          // the request); provider failures + timeouts early-return 503/504
          // upstream and never reach here. actor_user_id = the acting human
          // user's UUID; null for service-principal actors (no human user)
          // per audit_attribution_contract.md. Token/cost/model mirror the
          // same final telemetry the usage-log write used. The completion's
          // model id (the versioned identifier) is authoritative when a
          // provider call served the response; model_version stays null
          // because the proxy's model id already carries the version.
          final completed = pipelineResult.completion;
          final statsModelId = completed?.modelId ?? finalTelemetry.modelUsed;
          final latencyMs = clock().difference(requestStartedAt).inMilliseconds;
          final requestStats = ProxyRequestStats(
            usageClass: usageClass,
            resultStatus: 'success',
            requestId: reserved.requestId,
            actorUserId: scope.isServicePrincipal ? null : scope.userId,
            provider: providerFromModelId(statsModelId),
            modelId: statsModelId,
            modelVersion: null,
            promptTokenCount: completed != null ? estimate.tokenCount : 0,
            completionTokenCount: completed?.outputTokens ?? 0,
            costUsd: finalEstimate.costCents / 100,
            latencyMs: latencyMs < 0 ? 0 : latencyMs,
          );

          try {
            await accountingStore.completeRequest(
              operator: scope,
              idempotencyKey: idempotencyKey,
              responsePayload: responsePayload,
              now: clock().toUtc(),
              stats: requestStats,
            );
          } on Exception catch (_) {
            // A3.4: same accounting-store surface (completeRequest variant);
            // `Error`s propagate per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'accounting_store_unavailable',
              'message': 'proxy accounting store unavailable',
            });
            return;
          }

          _writeJson(response, 200, responsePayload);
          return;
        }

        // ─── Phase 9 B6 — auth-session ledger endpoints ─────────────────────
        //
        // Every endpoint below:
        //   1. Verifies the Firebase ID token via the existing auth guard
        //      (operator + location scope must resolve).
        //   2. Reads the JSON body (tolerating a missing/empty body for
        //      revoke-all where only `reason` is required).
        //   3. Resolves enrichment context. User-Agent is soft client
        //      metadata; forwarded IP/geo are used only when trusted
        //      ingress mode is explicitly enabled.
        //   4. Calls the injected [AuthSessionLedgerWriter]. The
        //      production binding is `RepositoryAuthSessionLedgerWriter`
        //      over `AuthSessionsRepository`; the scaffold default fails
        //      closed with a 503 so a misconfigured deploy surfaces the
        //      gap instead of silently dropping ledger rows.
        //   5. Returns narrow JSON: `session_id` (login),
        //      `{ok: true}` (refresh / revoke), `{revoked_count}`
        //      (revoke-all). NEVER echoes the bearer token, the
        //      `token_hash`, or any error stack.

        if (request.method == 'GET' && path == authAccountInfoPath) {
          if (accountInfoGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'account_info_not_configured',
              'message': 'route requires an AccountInfoGateway to be installed',
            });
            return;
          }

          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;

          try {
            final info = await accountInfoGateway.load(
              AccountInfoRequest(
                actorUserId: scope.userId,
                operatorId: scope.operatorId,
                locationId: scope.locationId,
              ),
            );
            _writeJson(response, 200, info.toJson());
          } on AccountInfoUnavailable {
            _writeJson(response, 404, <String, Object?>{
              'error': 'account_info_unavailable',
              'message': 'account info is unavailable; please retry',
            });
          } on Exception catch (_) {
            // A3.4: typed `AccountInfoUnavailable` caught above (→ 404). This
            // catches gateway transport/storage Exceptions (PgException /
            // TimeoutException / IOException); `Error`s propagate per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'account_info_unavailable',
              'message': 'account info is unavailable; please retry',
            });
          }
          return;
        }

        if (request.method == 'GET' && path == authPermissionsSnapshotPath) {
          if (permissionSnapshotResolver == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'permission_snapshot_not_configured',
              'message':
                  'route requires a ProxyPermissionSnapshotResolver to be installed',
            });
            return;
          }

          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;

          try {
            final snapshot = await permissionSnapshotResolver.load(scope);
            _writeJson(response, 200, snapshot.toJson());
          } on Exception catch (_) {
            // A3.4: permission-snapshot Postgres surface (PgException /
            // TimeoutException / IOException / closed-pool wraps); `Error`s
            // propagate per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'permission_snapshot_unavailable',
              'message': 'permission snapshot is unavailable; please retry',
            });
          }
          return;
        }

        if (request.method == 'POST' &&
            path == authMobilePushTokenRegisterPath) {
          if (mobilePushTokenGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'mobile_push_token_gateway_not_configured',
              'message':
                  'route requires a MobilePushTokenGateway to be installed',
            });
            return;
          }

          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          try {
            final registered = await mobilePushTokenGateway.register(
              actorUserId: scope.userId,
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              body: body,
            );
            registered
              ..remove('token')
              ..remove('token_hash')
              ..remove('token_ciphertext')
              ..remove('token_plaintext');
            _writeJson(response, 200, <String, Object?>{
              'ok': true,
              ...registered,
            });
          } on MobilePushGatewayException catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.code,
              'message': error.message,
            });
          } catch (error) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _writeJson(response, 503, <String, Object?>{
              'error': 'mobile_push_token_registration_unavailable',
              'message':
                  'mobile push token registration is unavailable; please retry',
            });
          }
          return;
        }

        if (request.method == 'POST' && path == authMobilePushTokenRevokePath) {
          if (mobilePushTokenGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'mobile_push_token_gateway_not_configured',
              'message':
                  'route requires a MobilePushTokenGateway to be installed',
            });
            return;
          }

          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          try {
            final revokedCount = await mobilePushTokenGateway.revoke(
              actorUserId: scope.userId,
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              body: body,
            );
            _writeJson(response, 200, <String, Object?>{
              'ok': true,
              'revoked_count': revokedCount,
            });
          } on MobilePushGatewayException catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.code,
              'message': error.message,
            });
          } catch (error) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _writeJson(response, 503, <String, Object?>{
              'error': 'mobile_push_token_revoke_unavailable',
              'message':
                  'mobile push token revoke is unavailable; please retry',
            });
          }
          return;
        }

        if (request.method == 'POST' && path == authMobilePushTestPath) {
          if (mobilePushSelfTestGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'mobile_push_self_test_not_configured',
              'message':
                  'route requires a MobilePushSelfTestGateway to be installed',
            });
            return;
          }

          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          try {
            final summary = await mobilePushSelfTestGateway.sendSelfTest(
              actorUserId: scope.userId,
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              body: body,
            );
            _writeJson(response, 202, <String, Object?>{
              'ok': true,
              ...summary.toJson(),
            });
          } on MobilePushGatewayException catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.code,
              'message': error.message,
            });
          } catch (error) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _writeJson(response, 503, <String, Object?>{
              'error': 'mobile_push_self_test_unavailable',
              'message': 'mobile push self-test is unavailable; please retry',
            });
          }
          return;
        }

        // Lane B B11.1 — auth handoff (mobile→web) mint + redeem.
        // Mobile mints a code via POST /v1/auth/handoff/codes; web
        // redeems atomically via POST /v1/auth/handoff/redeem. The
        // opaque code travels in the response body of the mint
        // endpoint and the request body of the redeem endpoint —
        // never as a URL parameter to the proxy (addendum A1 in
        // `docs/archive/_execution/lane_b_features/01_product_rule_and_ia.md`).
        // Mint requires an Idempotency-Key header per CLAUDE.md
        // "Proxy & API Conventions"; redeem does not (a redeem is a
        // single side-effect that the predicate naturally idempotents
        // in the negative direction).
        if (AuthHandoffRouter.matches(path, request.method)) {
          if (authHandoffRouter == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_handoff_router_not_configured',
              'message': 'route requires an AuthHandoffRouter to be installed',
            });
            return;
          }
          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;
          String? handoffIdemKey;
          if (path == authHandoffCodesMintPath) {
            handoffIdemKey = request.headers.value('Idempotency-Key')?.trim();
            if (handoffIdemKey == null || handoffIdemKey.isEmpty) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'idempotency_key_missing',
                'message': 'Idempotency-Key header is required',
              });
              return;
            }
            if (handoffIdemKey.length > 200) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'idempotency_key_too_long',
                'message':
                    'Idempotency-Key header must be 200 characters or fewer',
              });
              return;
            }
          }
          Map<String, Object?> handoffBody;
          try {
            handoffBody = await _readJsonBody(request);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }
          try {
            final result = await authHandoffRouter.handle(
              method: request.method,
              path: path,
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              actorUserId: scope.userId,
              idempotencyKey: handoffIdemKey,
              body: handoffBody,
              now: clock,
            );
            _writeJson(response, result.statusCode, result.body);
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'auth_handoff',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_handoff_unavailable',
              'message': 'handoff code service is unavailable; please retry',
            });
          }
          return;
        }

        if (request.method == 'POST' && path == authPasswordChangePath) {
          if (passwordChangeGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'password_change_not_configured',
              'message':
                  'route requires a PasswordChangeGateway to be installed',
            });
            return;
          }

          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          final currentPassword = _nonBlankString(body['current_password']);
          final newPassword = _nonBlankString(body['new_password']);
          if (currentPassword == null || newPassword == null) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_password_fields',
              'message':
                  'request body must include current_password and new_password',
            });
            return;
          }

          try {
            final result = await passwordChangeGateway.changePassword(
              PasswordChangeCommand(
                actorUserId: scope.userId,
                operatorId: scope.operatorId,
                locationId: scope.locationId,
                currentPassword: currentPassword,
                newPassword: newPassword,
                firebaseUid: scope.firebaseUid,
              ),
            );
            _writeJson(response, 200, <String, Object?>{
              'ok': true,
              'hibp_unavailable': result.hibpUnavailable,
            });
          } on PasswordChangeRejected catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.code,
              'message': error.message,
              'rejections': error.rejections,
            });
          } catch (error) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _writeJson(response, 503, <String, Object?>{
              'error': 'password_change_unavailable',
              'message': 'password change is unavailable; please retry',
            });
          }
          return;
        }

        if (request.method == 'POST' && path == authPasswordResetRequestPath) {
          if (passwordResetRequestGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'password_reset_request_not_configured',
              'message':
                  'route requires a PasswordResetRequestGateway to be installed',
            });
            return;
          }

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }
          final email = _nonBlankString(body['email']);
          if (email == null) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_email',
              'message': 'request body must include email',
            });
            return;
          }
          // HARD-B — per-account 24h cap. Counts requests against the
          // SHA-256(normalized email) so the contract's "10 reset
          // requests within 24h" applies regardless of whether the
          // attacker varies the source IP. Existing PasswordResetRequestThrottled
          // (Firebase-side rate limit) still rides the gateway.
          final emailHashHex = hashAuthEmailHex(email);

          // B1.S8 — per-email 5-min short window (1 request per 5 min).
          // Prevents rapid-fire spam even within the 10/24h envelope.
          if (passwordResetEmailShortCounter != null) {
            final recentCount = passwordResetEmailShortCounter.countInWindow(
              emailHashHex,
            );
            if (recentCount >= kAuthPasswordResetEmailShortThreshold) {
              response.headers.add(
                HttpHeaders.retryAfterHeader,
                kAuthPasswordResetEmailShortWindow.inSeconds.toString(),
              );
              _writeJson(response, 429, <String, Object?>{
                'error': 'reset_request_too_soon',
                'message':
                    'please wait at least '
                    '${kAuthPasswordResetEmailShortWindow.inMinutes} minutes '
                    'before requesting another reset link',
                'retry_after_seconds':
                    kAuthPasswordResetEmailShortWindow.inSeconds,
              });
              return;
            }
          }

          // B1.S8 — per-IP 24h cap (50 requests).
          // Prevents a single IP from flooding arbitrary victim inboxes.
          final clientIpForReset =
              _resolveLedgerContextFromHeaders(
                request,
                trustProxyAuditHeaders: trustProxyAuditHeaders,
              ).ip ??
              'unknown';
          if (passwordResetIpCounter != null) {
            final ipHashHex = hashAuthIpHex(clientIpForReset);
            final ipCount = passwordResetIpCounter.countInWindow(ipHashHex);
            if (ipCount >= kAuthPasswordResetIpThreshold) {
              response.headers.add(
                HttpHeaders.retryAfterHeader,
                kAuthPasswordResetIpWindow.inSeconds.toString(),
              );
              _writeJson(response, 429, <String, Object?>{
                'error': 'reset_request_ip_throttled',
                'message':
                    'too many reset requests from this network; '
                    'please try again later',
                'retry_after_seconds': kAuthPasswordResetIpWindow.inSeconds,
              });
              return;
            }
          }

          if (passwordResetThrottleCounter != null) {
            final priorCount = passwordResetThrottleCounter.countInWindow(
              emailHashHex,
            );
            if (priorCount >= kAuthPasswordResetThreshold) {
              if (authLockoutAuditSink != null) {
                await authLockoutAuditSink.recordPasswordResetThrottled(
                  emailHashHex: emailHashHex,
                  attemptCountIn24h: priorCount,
                  retryAfter: kAuthPasswordResetWindow,
                );
              }
              response.headers.add(
                HttpHeaders.retryAfterHeader,
                kAuthPasswordResetWindow.inSeconds.toString(),
              );
              _writeJson(response, 429, <String, Object?>{
                'error': 'reset_request_throttled',
                'retry_after_seconds': kAuthPasswordResetWindow.inSeconds,
              });
              return;
            }
          }
          // Idempotency-Key dedupe: a second tap on "Send reset link"
          // (or a network-retry that double-fires the request) must not
          // issue a second Firebase email. The cache replays the prior
          // {200, ok:true} body for the same key inside [ttl].
          final idempotencyKey = request.headers
              .value('Idempotency-Key')
              ?.trim();
          if (idempotencyKey == null || idempotencyKey.isEmpty) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_idempotency_key',
              'message': 'Idempotency-Key header is required',
            });
            return;
          }
          final cache = authIdempotencyCache ?? _defaultAuthIdempotencyCache;
          final cached = await cache.runOrReplay(
            route: authPasswordResetRequestPath,
            key: idempotencyKey,
            compute: () async {
              try {
                await passwordResetRequestGateway.requestReset(
                  PasswordResetRequestCommand(email: email),
                );
                // Increment the per-account 24h counter only after a real
                // request flows through the gateway (the idempotent replay
                // path sees a cache hit and returns BEFORE this compute
                // body runs, so retries do not inflate the count).
                passwordResetThrottleCounter?.incrementAndCount(emailHashHex);
                // B1.S8 — also increment the short-window and IP counters.
                passwordResetEmailShortCounter?.incrementAndCount(emailHashHex);
                passwordResetIpCounter?.incrementAndCount(
                  hashAuthIpHex(clientIpForReset),
                );
                // Privacy-preserving: always return 200 with the same body so
                // the client can show a uniform "if an account exists..."
                // confirmation regardless of whether the email matched a
                // real user.
                return CachedProxyResponse(
                  statusCode: 200,
                  body: const <String, Object?>{'ok': true},
                );
              } on PasswordResetRequestThrottled {
                return CachedProxyResponse(
                  statusCode: 429,
                  body: const <String, Object?>{
                    'error': 'rate_limited',
                    'message':
                        'too many password-reset requests; please wait before retrying',
                  },
                );
              } on Exception catch (_) {
                // A3.4: typed throttle caught above. Password-reset gateway
                // transport/storage Exceptions (PgException / TimeoutException
                // / IOException / SendGrid HttpException) land here; cache the
                // 503 so idempotent retries replay; `Error`s propagate per C4.
                return CachedProxyResponse(
                  statusCode: 503,
                  body: const <String, Object?>{
                    'error': 'password_reset_request_unavailable',
                    'message': 'password reset is unavailable; please retry',
                  },
                );
              }
            },
          );
          _writeJson(response, cached.statusCode, cached.body);
          return;
        }

        if (request.method == 'POST' && path == authPasswordResetConfirmPath) {
          if (passwordResetConfirmGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'password_reset_confirm_not_configured',
              'message':
                  'route requires a PasswordResetConfirmGateway to be installed',
            });
            return;
          }

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }
          final oobCode = _nonBlankString(body['oob_code']);
          final newPassword = _nonBlankString(body['new_password']);
          if (oobCode == null || newPassword == null) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_password_reset_fields',
              'message': 'oob_code and new_password are required',
            });
            return;
          }
          // Idempotency-Key dedupe: a confirm retry after a successful
          // but lost response replays the original {200, ok:true} body
          // instead of trying the now-burned oobCode against Firebase
          // again (which would surface as `password_reset_expired`).
          final idempotencyKey = request.headers
              .value('Idempotency-Key')
              ?.trim();
          if (idempotencyKey == null || idempotencyKey.isEmpty) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_idempotency_key',
              'message': 'Idempotency-Key header is required',
            });
            return;
          }
          final cache = authIdempotencyCache ?? _defaultAuthIdempotencyCache;
          final cached = await cache.runOrReplay(
            route: authPasswordResetConfirmPath,
            key: idempotencyKey,
            compute: () async {
              try {
                final completed = await passwordResetConfirmGateway
                    .confirmPasswordReset(
                      PasswordResetConfirmCommand(
                        oobCode: oobCode,
                        newPassword: newPassword,
                      ),
                    );
                return CachedProxyResponse(
                  statusCode: 200,
                  body: <String, Object?>{
                    'ok': true,
                    'hibp_unavailable': completed.hibpUnavailable,
                  },
                );
              } on PasswordChangeRejected catch (error) {
                return CachedProxyResponse(
                  statusCode: error.statusCode,
                  body: <String, Object?>{
                    'error': error.code,
                    'message': error.message,
                    'rejections': error.rejections,
                  },
                );
              } on DependencyTimeoutException catch (error) {
                // HARD-G observability: surface as the contract-pinned
                // dependency_timeout envelope. Idempotency cache stores
                // the result so retries with the same key replay the
                // same response.
                return CachedProxyResponse(
                  statusCode: 503,
                  body: <String, Object?>{
                    'error': 'dependency_timeout',
                    'surface': error.surface,
                    'operation': error.operation,
                    'message': 'Upstream dependency timed out; please retry',
                  },
                );
              } on Exception catch (_) {
                // A3.4: typed rejection + DependencyTimeoutException caught
                // above. Remaining gateway transport/storage Exceptions
                // (PgException / IOException / FormatException / crypto)
                // cached as 503; `Error`s propagate per C4.
                return CachedProxyResponse(
                  statusCode: 503,
                  body: const <String, Object?>{
                    'error': 'password_reset_confirm_unavailable',
                    'message': 'password reset is unavailable; please retry',
                  },
                );
              }
            },
          );
          _writeJson(response, cached.statusCode, cached.body);
          return;
        }

        if (request.method == 'POST' && path == authMfaRecoveryRequestPath) {
          if (mfaRecoveryRequestGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'mfa_recovery_request_not_configured',
              'message':
                  'route requires an MfaRecoveryRequestGateway to be installed',
            });
            return;
          }

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          final email = _nonBlankString(body['email']);
          if (email == null) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_email',
              'message': 'request body must include email',
            });
            return;
          }
          try {
            final accepted = await mfaRecoveryRequestGateway.requestRecovery(
              MfaRecoveryRequestCommand(
                email: email,
                clientIp:
                    _resolveLedgerContextFromHeaders(
                      request,
                      trustProxyAuditHeaders: trustProxyAuditHeaders,
                    ).ip ??
                    'unknown',
                reason:
                    _nonBlankString(body['reason']) ??
                    'mfa_challenge_no_factor_access',
              ),
            );
            _writeJson(response, 202, <String, Object?>{
              'ok': true,
              'queued': accepted.queued,
              if (accepted.requestId != null) 'request_id': accepted.requestId,
            });
          } on MfaRecoveryRequestRejected catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.code,
              'message': error.message,
              if (error.retryAfter != null)
                'retry_after': error.retryAfter!.toUtc().toIso8601String(),
            });
          } on Exception catch (_) {
            // A3.4: typed `MfaRecoveryRequestRejected` caught above. Gateway
            // transport/storage Exceptions (PgException / TimeoutException /
            // IOException / SendGrid HttpException) land here; `Error`s
            // propagate per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'mfa_recovery_request_unavailable',
              'message': 'MFA recovery request is unavailable; please retry',
            });
          }
          return;
        }

        if (_isMfaOperation(path, request.method)) {
          if (mfaOperationsGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'mfa_operations_not_configured',
              'message':
                  'route requires an MfaOperationsGateway to be installed',
            });
            return;
          }

          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;
          final authorizationIdToken = extractBearerToken(
            request.headers.value(HttpHeaders.authorizationHeader),
          );
          if (authorizationIdToken == null) {
            _writeJson(response, 401, <String, Object?>{
              'error': 'missing_or_malformed_authorization',
              'message': 'MFA routes require a Firebase ID token',
            });
            return;
          }

          if (request.method == 'POST' && path == authMfaFactorsRevokePath) {
            final freshEnough = _requireFreshAuthenticationOrWrite(
              response: response,
              scope: scope,
              requestedAt: clock().toUtc(),
            );
            if (!freshEnough) return;
          }

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          try {
            if (request.method == 'POST' && path == authMfaTotpBeginPath) {
              final userEmail = _nonBlankString(body['user_email']);
              if (userEmail == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_user_email',
                  'message': 'request body must include user_email',
                });
                return;
              }
              final setup = await mfaOperationsGateway.beginTotpEnrollment(
                MfaTotpBeginCommand(
                  actorUserId: scope.userId,
                  operatorId: scope.operatorId,
                  locationId: scope.locationId,
                  authorizationIdToken: authorizationIdToken,
                  userEmail: userEmail,
                  issuerName:
                      _nonBlankString(body['issuer_name']) ?? 'Forge & Flow',
                ),
              );
              _writeJson(response, 200, <String, Object?>{
                'factor_id': setup.factorId,
                'secret_base32': setup.secretBase32,
                'otp_auth_url': setup.otpAuthUrl,
              });
              return;
            }

            if (request.method == 'POST' && path == authMfaTotpConfirmPath) {
              final factorId = _nonBlankString(body['factor_id']);
              final oneTimeCode = _nonBlankString(body['one_time_code']);
              if (factorId == null || oneTimeCode == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_totp_confirm_fields',
                  'message': 'factor_id and one_time_code are required',
                });
                return;
              }
              // HARD-B - per-challenge retry cap. Counter key is
              // SHA-256(factor_id + actor) so two users sharing a factor
              // surface (impossible in practice but cheap to enforce) do
              // not share a counter slot. 4th attempt within the window
              // returns 429; success resets the slot via try/finally.
              final challengeKey = sha256
                  .convert(utf8.encode('${scope.userId}:$factorId'))
                  .toString();
              if (mfaTotpRetryCounter != null) {
                final priorRetries = mfaTotpRetryCounter.countInWindow(
                  challengeKey,
                );
                if (priorRetries >= kAuthMfaTotpRetryThreshold) {
                  if (authLockoutAuditSink != null) {
                    await authLockoutAuditSink.recordMfaRetryExceeded(
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                      actorUserId: scope.userId,
                      challengeIdHash: challengeKey,
                      retryCount: priorRetries,
                    );
                  }
                  response.headers.add(
                    HttpHeaders.retryAfterHeader,
                    kAuthMfaTotpRetryAfter.inSeconds.toString(),
                  );
                  _writeJson(response, 429, <String, Object?>{
                    'error': 'mfa_retry_limit',
                    'retry_after_seconds': kAuthMfaTotpRetryAfter.inSeconds,
                  });
                  return;
                }
              }
              try {
                final completed = await mfaOperationsGateway
                    .confirmTotpEnrollment(
                      MfaTotpConfirmCommand(
                        actorUserId: scope.userId,
                        operatorId: scope.operatorId,
                        locationId: scope.locationId,
                        authorizationIdToken: authorizationIdToken,
                        factorId: factorId,
                        oneTimeCode: oneTimeCode,
                        issuerName:
                            _nonBlankString(body['issuer_name']) ??
                            'Forge & Flow',
                      ),
                    );
                // Successful confirm resets the retry slot so the next
                // challenge starts fresh (the contract: "Each new
                // challenge resets retry counter").
                mfaTotpRetryCounter?.reset(challengeKey);
                _writeJson(response, 200, <String, Object?>{
                  'factor_id': completed.factorId,
                });
                return;
              } on MfaOperationRejected {
                // Rejected attempts increment the per-challenge counter.
                // The threshold check above sees the post-increment value
                // on the next request, so the 4th failure trips the 429.
                mfaTotpRetryCounter?.incrementAndCount(challengeKey);
                rethrow;
              }
            }

            if (request.method == 'POST' && path == authMfaFactorsListPath) {
              final listed = await mfaOperationsGateway.listFactors(
                MfaListFactorsCommand(
                  actorUserId: scope.userId,
                  operatorId: scope.operatorId,
                  locationId: scope.locationId,
                  authorizationIdToken: authorizationIdToken,
                ),
              );
              _writeJson(response, 200, <String, Object?>{
                'factors': <Map<String, Object?>>[
                  for (final factor in listed.factors)
                    <String, Object?>{
                      'factor_id': factor.factorId,
                      'factor_type': factor.factorType,
                      'enrolled_at': factor.enrolledAt
                          .toUtc()
                          .toIso8601String(),
                      'last_used_at': factor.lastUsedAt
                          ?.toUtc()
                          .toIso8601String(),
                      'recovery_codes_viewed_at': factor.recoveryCodesViewedAt
                          ?.toUtc()
                          .toIso8601String(),
                      'issuer_label': factor.issuerLabel,
                      'can_revoke': factor.canRevoke,
                    },
                ],
                'removal_requests': <Map<String, Object?>>[
                  for (final removal in listed.removalRequests)
                    <String, Object?>{
                      'request_id': removal.requestId,
                      'factor_id': removal.factorId,
                      'status': removal.status,
                      'execute_after': removal.executeAfter
                          .toUtc()
                          .toIso8601String(),
                      if (removal.completedAt != null)
                        'completed_at': removal.completedAt!
                            .toUtc()
                            .toIso8601String(),
                    },
                ],
              });
              return;
            }

            if (request.method == 'POST' &&
                path == authMfaRecoveryCodesViewedPath) {
              final idempotencyKey = request.headers
                  .value('Idempotency-Key')
                  ?.trim();
              if (idempotencyKey == null || idempotencyKey.isEmpty) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_idempotency_key',
                  'message': 'Idempotency-Key header is required',
                });
                return;
              }
              if (idempotencyKey.length > 200) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'idempotency_key_too_long',
                  'message':
                      'Idempotency-Key header must be 200 characters or fewer',
                });
                return;
              }
              final factorId = _nonBlankString(body['factor_id']);
              if (factorId == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_factor_id',
                  'message': 'request body must include factor_id',
                });
                return;
              }
              final cached =
                  await (authIdempotencyCache ?? _defaultAuthIdempotencyCache)
                      .runOrReplay(
                        route: authMfaRecoveryCodesViewedPath,
                        key: idempotencyKey,
                        compute: () async {
                          final completed = await mfaOperationsGateway
                              .markRecoveryCodesViewed(
                                MfaMarkRecoveryCodesViewedCommand(
                                  actorUserId: scope.userId,
                                  operatorId: scope.operatorId,
                                  locationId: scope.locationId,
                                  authorizationIdToken: authorizationIdToken,
                                  factorId: factorId,
                                  idempotencyKey: idempotencyKey,
                                ),
                              );
                          return CachedProxyResponse(
                            statusCode: 200,
                            body: <String, Object?>{
                              'ok': true,
                              'recovery_codes_viewed_at': completed.viewedAt
                                  .toUtc()
                                  .toIso8601String(),
                            },
                          );
                        },
                      );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'POST' && path == authMfaFactorsRevokePath) {
              final factorId = _nonBlankString(body['factor_id']);
              if (factorId == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_factor_id',
                  'message': 'request body must include factor_id',
                });
                return;
              }
              final completed = await mfaOperationsGateway.revokeFactor(
                MfaRevokeFactorCommand(
                  actorUserId: scope.userId,
                  operatorId: scope.operatorId,
                  locationId: scope.locationId,
                  authorizationIdToken: authorizationIdToken,
                  factorId: factorId,
                  stepUpProofId: _freshAuthProofId(
                    scope: scope,
                    path: path,
                    requestedAt: clock().toUtc(),
                  ),
                ),
              );
              _writeJson(response, 200, <String, Object?>{
                'ok': true,
                'revoked': completed.revoked,
                if (completed.requestId != null)
                  'request_id': completed.requestId,
                if (completed.executeAfter != null)
                  'execute_after': completed.executeAfter!
                      .toUtc()
                      .toIso8601String(),
              });
              return;
            }

            if (request.method == 'POST' &&
                path == authMfaFactorsRemovalCancelPath) {
              final requestId = _nonBlankString(body['request_id']);
              if (requestId == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_removal_request_id',
                  'message': 'request body must include request_id',
                });
                return;
              }
              final completed = await mfaOperationsGateway.cancelFactorRemoval(
                MfaCancelFactorRemovalCommand(
                  actorUserId: scope.userId,
                  operatorId: scope.operatorId,
                  locationId: scope.locationId,
                  authorizationIdToken: authorizationIdToken,
                  requestId: requestId,
                ),
              );
              _writeJson(response, 200, <String, Object?>{
                'ok': true,
                'cancelled': completed.cancelled,
              });
              return;
            }
          } on MfaOperationRejected catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.code,
              'message': error.message,
              if (error.retryAfter != null)
                'retry_after': error.retryAfter!.toUtc().toIso8601String(),
              if (error.resetsAt != null)
                'resets_at': error.resetsAt!.toUtc().toIso8601String(),
            });
            return;
          } on IdentityToolkitFirebaseMfaError catch (error) {
            log(
              LogSeverity.error,
              'mfa.identity_toolkit_error',
              fields: <String, Object?>{
                'code': error.code,
                'status_code': error.statusCode,
              },
            );
            _writeJson(response, 503, <String, Object?>{
              'error': error.code,
              'message': 'MFA operation is unavailable; please retry',
            });
            return;
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'mfa',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'mfa_operations_unavailable',
              'message': 'MFA operation is unavailable; please retry',
            });
            return;
          }
        }

        final servicePrincipalJwtIssueId = _servicePrincipalJwtIssueId(
          path,
          request.method,
        );
        if (servicePrincipalJwtIssueId != null) {
          if (servicePrincipalJwtIssuanceGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'service_principal_issuance_not_configured',
              'message':
                  'route requires a ServicePrincipalJwtIssuanceGateway to be installed',
            });
            return;
          }

          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;

          final allowed = await _requireAdminPermissionOrWrite(
            response: response,
            guard: adminPermissionGuard,
            scope: scope,
            permissionKey: PermissionKeys.adminServicePrincipalIssueToken,
            requestedAt: clock().toUtc(),
          );
          if (!allowed) return;

          final idempotencyKey = request.headers
              .value('Idempotency-Key')
              ?.trim();
          if (idempotencyKey == null || idempotencyKey.isEmpty) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_idempotency_key',
              'message': 'Idempotency-Key header is required',
            });
            return;
          }

          try {
            final issued = await servicePrincipalJwtIssuanceGateway.issue(
              ServicePrincipalJwtIssueCommand(
                servicePrincipalId: servicePrincipalJwtIssueId,
                operator: scope,
                idempotencyKey: idempotencyKey,
                issuedAt: clock().toUtc(),
              ),
            );
            _writeJson(response, 200, issued.toJson());
          } on ServicePrincipalJwtIssueRejected catch (error) {
            _writeJson(response, error.statusCode, error.toJson());
          } on Exception catch (_) {
            // A3.4: typed `ServicePrincipalJwtIssueRejected` caught above.
            // Issuance-gateway transport/signer Exceptions (PgException /
            // TimeoutException / IOException / FormatException / crypto)
            // land here; `Error`s propagate per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'service_principal_issuance_unavailable',
              'message':
                  'service principal JWT issuance is unavailable; please retry',
            });
          }
          return;
        }

        // Lane B B2.1 — default role catalog admin routes. Dispatched
        // ahead of the generic admin-auth block because the catalog
        // paths share the `/v1/admin/auth/` prefix but are not in the
        // _isAdminAuthOperation allowlist (catalogs are global,
        // super_admin only writes, no permission key — gated by role).
        // The router (`admin_default_role_catalog_routes.dart`) owns
        // the role gate, idempotency-key validation, actor resolution,
        // and history-limit parsing so this dispatcher stays minimal.
        if (DefaultRoleCatalogAdminRouter.matches(path, request.method)) {
          if (defaultRoleCatalogAdminRouter == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'default_role_catalog_admin_not_configured',
              'message':
                  'route requires a DefaultRoleCatalogAdminRouter to be installed',
            });
            return;
          }
          final actor = await _resolveVerifiedClaimsOrWrite(
            request,
            response,
            authGuard,
          );
          if (actor == null) return;
          Map<String, Object?> catalogBody;
          try {
            catalogBody = await _readJsonBody(request, allowEmpty: true);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }
          try {
            // Phase 11A.10 / HP #7 — wrap publish in the shared auth
            // idempotency cache so retries replay the prior 201/400
            // instead of creating a second catalog version (B-1 from
            // c_12_lane_c_closeout_audit.md). Router-side header
            // validation still runs inside dispatch; GET skips caching.
            final idempotencyKey =
                request.headers.value('Idempotency-Key')?.trim() ?? '';
            Future<CachedProxyResponse> runDispatch() async {
              final r = await defaultRoleCatalogAdminRouter.dispatch(
                method: request.method,
                path: path,
                actorRoles: actor.roles.toSet(),
                actorFirebaseUid: actor.firebaseUid ?? actor.userId,
                actorResolver:
                    integrationAdminActorResolver?.resolveActorUserId,
                idempotencyKeyHeader: idempotencyKey.isEmpty
                    ? null
                    : idempotencyKey,
                limitQueryParam: request.uri.queryParameters['limit'],
                versionIdQueryParam: request.uri.queryParameters['version_id'],
                body: catalogBody,
              );
              return CachedProxyResponse(
                statusCode: r.statusCode,
                body: r.body,
              );
            }

            final result = request.method == 'POST' && idempotencyKey.isNotEmpty
                ? await (authIdempotencyCache ?? _defaultAuthIdempotencyCache)
                      .runOrReplay(
                        route: path,
                        key: idempotencyKey,
                        compute: runDispatch,
                      )
                : await runDispatch();
            _writeJson(response, result.statusCode, result.body);
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'default_role_catalog_admin',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'default_role_catalog_admin_unavailable',
              'message':
                  'default role catalog admin is unavailable; please retry',
            });
          }
          return;
        }

        if (_isAdminAuthOperation(path, request.method)) {
          final authOperationPath = _canonicalAuthOperationPath(path);
          if (authOperationsGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_operations_not_configured',
              'message':
                  'route requires an AuthOperationsGateway to be installed',
            });
            return;
          }

          final callerScope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (callerScope == null) return;

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request, allowEmpty: true);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          // Phase 11A.10 / Hard Promise #7 — every proxy write is
          // idempotent. Self-service Team write branches (role
          // create/patch/delete, invite create/revoke, role-grant
          // create/delete, org-unit create, location move) all
          // require an `Idempotency-Key` header so a retry collapses
          // to a single back-end mutation. Reads (`GET`) skip this
          // check.
          final scope = _effectiveAdminAuthScope(
            request: request,
            body: body,
            callerScope: callerScope,
          );
          final crossOperatorScope = scope.operatorId != callerScope.operatorId;

          Future<bool> requirePermission(String permissionKey) {
            if (crossOperatorScope) {
              final requiredRoles = request.method == 'GET'
                  ? const <String>{'super_admin', 'ff_support'}
                  : const <String>{'super_admin'};
              if (_operatorContextHasAnyRole(callerScope, requiredRoles)) {
                return Future<bool>.value(true);
              }
              _writeJson(response, 403, <String, Object?>{
                'error': 'permission_denied',
                'message': 'admin role claim required for requested operator',
                'required_roles': requiredRoles.toList(),
              });
              return Future<bool>.value(false);
            }
            return _requireAdminPermissionOrWrite(
              response: response,
              guard: adminPermissionGuard,
              scope: scope,
              permissionKey: permissionKey,
              requestedAt: clock().toUtc(),
            );
          }

          final authOpsCache =
              authIdempotencyCache ?? _defaultAuthIdempotencyCache;
          String? readIdempotencyKeyOrFail() {
            final key = request.headers.value('Idempotency-Key')?.trim();
            if (key == null || key.isEmpty) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'missing_idempotency_key',
                'message': 'Idempotency-Key header is required',
              });
              return null;
            }
            return key;
          }

          Future<Map<String, Object?>?> loadTeamUserJson(
            String targetUserId,
          ) async {
            final listed = await authOperationsGateway.listUsers(
              TeamUserListCommand(
                actorUserId: scope.userId,
                operatorId: scope.operatorId,
                locationId: scope.locationId,
              ),
            );
            for (final user in listed.users) {
              if (user.userId == targetUserId) {
                return _teamUserToJson(user);
              }
            }
            return null;
          }

          try {
            if (request.method == 'GET' &&
                authOperationPath == adminAuthRolesPath) {
              if (!await requirePermission('team.roles.view')) return;
              final listed = await authOperationsGateway.listRoles(
                TeamRoleCatalogListCommand(
                  actorUserId: scope.userId,
                  operatorId: scope.operatorId,
                  locationId: scope.locationId,
                  scope: request.uri.queryParameters['scope'],
                ),
              );
              _writeJson(response, 200, <String, Object?>{
                'roles': listed.roles.map(_teamRoleToJson).toList(),
              });
              return;
            }

            if (request.method == 'GET' &&
                authOperationPath == adminAuthUsersPath) {
              if (!await requirePermission('team.users.view')) return;
              final listed = await authOperationsGateway.listUsers(
                TeamUserListCommand(
                  actorUserId: scope.userId,
                  operatorId: scope.operatorId,
                  locationId: scope.locationId,
                ),
              );
              _writeJson(response, 200, <String, Object?>{
                'users': listed.users.map(_teamUserToJson).toList(),
              });
              return;
            }

            if (request.method == 'PATCH' &&
                authOperationPath.startsWith(adminAuthUsersPrefix)) {
              if (!await requirePermission('team.users.invite')) return;
              // W-1 — Members edit-user write path. Pre-flight + body shaping live in `team_users_edit_member_validation.dart`.
              final inputs = validateEditMemberRouteBody(
                targetUserId: _pathSuffix(
                  authOperationPath,
                  adminAuthUsersPrefix,
                ),
                nonBlankString: _nonBlankString,
                rawDisplayName: body['display_name'],
                rawEmail: body['email'],
                rawReason: body['reason'],
                rawAdminReason: body['admin_reason'],
              );
              if (inputs.rejection != null) {
                _writeJson(
                  response,
                  inputs.rejection!.statusCode,
                  <String, Object?>{
                    'error': inputs.rejection!.error,
                    'message': inputs.rejection!.message,
                  },
                );
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final targetUserId = _pathSuffix(
                authOperationPath,
                adminAuthUsersPrefix,
              )!;
              final cached = await authOpsCache.runOrReplay(
                route: '$adminAuthUsersPrefix$targetUserId',
                key: idempotencyKey,
                compute: () async {
                  final patched = await authOperationsGateway.patchUserProfile(
                    TeamUserProfilePatchCommand(
                      actorUserId: scope.userId,
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                      targetUserId: targetUserId,
                      displayName: inputs.displayName,
                      email: inputs.email,
                      reason: inputs.reason!,
                    ),
                  );
                  return CachedProxyResponse(
                    statusCode: 200,
                    body: <String, Object?>{
                      'ok': true,
                      'user': _teamUserToJson(patched.user),
                    },
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'PATCH' &&
                authOperationPath == authSelfProfilePath) {
              // W-3 — self-service profile editor. Validation + dispatch
              // live in `auth_self_profile_routes.dart`.
              if (!await requirePermission(authSelfProfilePermissionKey)) {
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: authSelfProfilePath,
                key: idempotencyKey,
                compute: () async {
                  final r =
                      await SelfProfileRouter(
                        authOperationsGateway: authOperationsGateway,
                      ).handleRequest(
                        actorUserId: scope.userId,
                        operatorId: scope.operatorId,
                        locationId: scope.locationId,
                        body: body,
                        nonBlankString: _nonBlankString,
                      );
                  return CachedProxyResponse(
                    statusCode: r.statusCode,
                    body: r.body,
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'GET' &&
                authOperationPath == adminAuthSessionsPath) {
              if (!await requirePermission('team.users.view')) return;
              final listed = await authOperationsGateway.listActiveSessions(
                AuthActiveSessionsListCommand(
                  actorUserId: scope.userId,
                  operatorId: scope.operatorId,
                  locationId: scope.locationId,
                ),
              );
              _writeJson(response, 200, <String, Object?>{
                'sessions': listed.sessions
                    .map(
                      (session) =>
                          _authSessionSummaryToAdminJson(session, scope),
                    )
                    .toList(growable: false),
              });
              return;
            }

            if (request.method == 'GET' &&
                authOperationPath == adminAuthAuditLogPath) {
              if (!await requirePermission('admin.audit_log.view')) return;
              final params = request.uri.queryParameters;
              final rawLimit = int.tryParse(params['limit'] ?? '');
              final rawCursor = int.tryParse(params['cursor'] ?? '');
              final rawOffset = int.tryParse(params['offset'] ?? '');
              final limit = rawLimit == null
                  ? 200
                  : (rawLimit < 1 ? 1 : (rawLimit > 200 ? 200 : rawLimit));
              final offset = rawCursor ?? rawOffset ?? 0;
              DateTime? parseUtc(String? raw) {
                if (raw == null || raw.isEmpty) return null;
                return DateTime.tryParse(raw)?.toUtc();
              }

              final listed = await authOperationsGateway.listAuthEventsForActor(
                AuthEventListCommand(
                  actorUserId: scope.userId,
                  operatorId: scope.operatorId,
                  locationId: scope.locationId,
                  limit: limit,
                  offset: offset < 0 ? 0 : offset,
                  eventKind: _authEventKindFromAdminAuditActions(
                    params['actions'],
                  ),
                  from: parseUtc(params['from']),
                  to: parseUtc(params['to']),
                ),
              );
              _writeJson(response, 200, <String, Object?>{
                'rows': listed.entries
                    .map(
                      (entry) => _authEventEntryToAdminAuditRow(entry, scope),
                    )
                    .toList(growable: false),
                'next_cursor': listed.hasMore ? '${offset + limit}' : null,
              });
              return;
            }

            if (request.method == 'POST' &&
                authOperationPath == adminAuthRolesPath) {
              final permissionKey = path == adminAuthRolesPath
                  ? 'admin.roles.create_custom'
                  : 'team.roles.create_custom';
              if (!await requirePermission(permissionKey)) return;
              final roleKey = _nonBlankString(body['role_key']);
              final displayName = _nonBlankString(body['display_name']);
              if (roleKey == null || displayName == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_role_fields',
                  'message': 'role_key and display_name are required',
                });
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: adminAuthRolesPath,
                key: idempotencyKey,
                compute: () async {
                  final created = await authOperationsGateway.createRole(
                    TeamRoleCreateCommand(
                      actorUserId: scope.userId,
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                      roleKey: roleKey,
                      displayName: displayName,
                      description: _stringValue(body['description']) ?? '',
                      permissions: _rolePermissionUpdates(body['permissions']),
                      reason: _nonBlankString(body['reason']),
                    ),
                  );
                  return CachedProxyResponse(
                    statusCode: 201,
                    body: <String, Object?>{
                      'role': _teamRoleToJson(created.role),
                    },
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'POST' &&
                path.startsWith(adminAuthRolePrefix) &&
                path.endsWith('/permissions')) {
              if (!await requirePermission('admin.roles.edit_seeded')) return;
              final roleId = _seededRolePermissionsRoleId(path);
              if (roleId == null) {
                _writeJson(response, 404, <String, Object?>{
                  'error': 'not found',
                  'method': request.method,
                  'path': path,
                });
                return;
              }
              final reason =
                  _nonBlankString(body['admin_reason']) ??
                  _nonBlankString(body['reason']);
              if (reason == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_admin_reason',
                  'message': 'admin_reason is required',
                });
                return;
              }
              final permissionKeys = _permissionKeyList(
                body['permission_keys'],
              );
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: '$adminAuthRolePrefix$roleId/permissions',
                key: idempotencyKey,
                compute: () async {
                  final listed = await authOperationsGateway.listRoles(
                    TeamRoleCatalogListCommand(
                      actorUserId: scope.userId,
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                    ),
                  );
                  TeamRoleCatalogEntry? targetRole;
                  for (final role in listed.roles) {
                    if (role.roleId == roleId) {
                      targetRole = role;
                      break;
                    }
                  }
                  if (targetRole?.roleKey == PermissionKeys.roleSuperAdmin) {
                    final requested = permissionKeys.toSet();
                    final locked = <String>{
                      PermissionKeys.adminRolesView,
                      PermissionKeys.adminRolesEditSeeded,
                      PermissionKeys.teamRolesView,
                      PermissionKeys.teamRolesDefaultCatalogView,
                      PermissionKeys.teamRolesDefaultCatalogEdit,
                    };
                    final missing =
                        locked.where((key) => !requested.contains(key)).toList()
                          ..sort();
                    if (missing.isNotEmpty) {
                      return CachedProxyResponse(
                        statusCode: 400,
                        body: <String, Object?>{
                          'error': 'platform_role_locked_permission',
                          'message':
                              'Ecosystem admin keeps required safety '
                              'permissions.',
                          'missing_permission_keys': missing,
                        },
                      );
                    }
                  }
                  final patched = await authOperationsGateway
                      .editSeededRolePermissions(
                        TeamSeededRolePermissionsEditCommand(
                          actorUserId: scope.userId,
                          operatorId: scope.operatorId,
                          locationId: scope.locationId,
                          roleId: roleId,
                          permissionKeys: permissionKeys,
                          reason: reason,
                        ),
                      );
                  return CachedProxyResponse(
                    statusCode: 200,
                    body: <String, Object?>{
                      'role': _teamRoleToJson(patched.role),
                      'bumped_users': patched.bumpedUsers,
                    },
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'PATCH' &&
                authOperationPath.startsWith(adminAuthRolePrefix)) {
              final permissionKey = path.startsWith(adminAuthRolePrefix)
                  ? 'admin.roles.create_custom'
                  : 'team.roles.create_custom';
              if (!await requirePermission(permissionKey)) return;
              final roleId = _pathSuffix(
                authOperationPath,
                adminAuthRolePrefix,
              );
              if (roleId == null) {
                _writeJson(response, 404, <String, Object?>{
                  'error': 'not found',
                  'method': request.method,
                  'path': path,
                });
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: '$adminAuthRolePrefix$roleId',
                key: idempotencyKey,
                compute: () async {
                  final patched = await authOperationsGateway.patchRole(
                    TeamRolePatchCommand(
                      actorUserId: scope.userId,
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                      roleId: roleId,
                      displayName: _stringValue(body['display_name']),
                      description: _stringValue(body['description']),
                      permissions: _rolePermissionUpdates(body['permissions']),
                      reason: _nonBlankString(body['reason']),
                    ),
                  );
                  return CachedProxyResponse(
                    statusCode: 200,
                    body: <String, Object?>{
                      'role': _teamRoleToJson(patched.role),
                      'bumped_users': patched.bumpedUsers,
                    },
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'DELETE' &&
                authOperationPath.startsWith(adminAuthRolePrefix)) {
              final permissionKey = path.startsWith(adminAuthRolePrefix)
                  ? 'admin.roles.delete_custom'
                  : 'team.roles.create_custom';
              if (!await requirePermission(permissionKey)) return;
              final roleId = _pathSuffix(
                authOperationPath,
                adminAuthRolePrefix,
              );
              if (roleId == null) {
                _writeJson(response, 404, <String, Object?>{
                  'error': 'not found',
                  'method': request.method,
                  'path': path,
                });
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: 'DELETE $adminAuthRolePrefix$roleId',
                key: idempotencyKey,
                compute: () async {
                  final deleted = await authOperationsGateway.deleteRole(
                    TeamRoleDeleteCommand(
                      actorUserId: scope.userId,
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                      roleId: roleId,
                      reason: _nonBlankString(body['reason']),
                    ),
                  );
                  return CachedProxyResponse(
                    statusCode: 200,
                    body: <String, Object?>{
                      'ok': true,
                      'deleted': deleted.deleted,
                    },
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'POST' &&
                authOperationPath == adminAuthInvitesPath) {
              if (!await requirePermission('team.users.invite')) return;
              final email = _nonBlankString(body['email']);
              final displayName = _nonBlankString(body['display_name']);
              final roleId =
                  _nonBlankString(body['role_id']) ??
                  _nonBlankString(body['role_key']);
              final targetLocationId =
                  _nonBlankString(body['location_id']) ??
                  _nonBlankString(body['primary_location_id']);
              final targetOrgUnitId = _nonBlankString(body['org_unit_id']);
              final scopeType =
                  _nonBlankString(body['scope_type']) ??
                  (targetOrgUnitId != null
                      ? 'org_unit'
                      : targetLocationId != null
                      ? 'location'
                      : null);
              if (email == null || roleId == null || scopeType == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_invite_fields',
                  'message': 'email, role_id, and scope_type are required',
                });
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: adminAuthInvitesPath,
                key: idempotencyKey,
                compute: () async {
                  final created = await authOperationsGateway.createInvite(
                    TeamInviteCreateCommand(
                      actorUserId: scope.userId,
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                      email: email,
                      roleId: roleId,
                      scopeType: scopeType,
                      targetLocationId: targetLocationId,
                      targetOrgUnitId: targetOrgUnitId,
                    ),
                  );
                  final createdAt = clock().toUtc().toIso8601String();
                  final invite = <String, Object?>{
                    'invite_id': created.inviteId,
                    'email': email,
                    if (displayName != null) 'display_name': displayName,
                    'role_id': roleId,
                    if (_nonBlankString(body['role_key']) != null)
                      'role_key': _nonBlankString(body['role_key']),
                    'scope_type': scopeType,
                    if (targetLocationId != null) ...<String, Object?>{
                      'location_id': targetLocationId,
                      'primary_location_id': targetLocationId,
                    },
                    if (targetOrgUnitId != null) 'org_unit_id': targetOrgUnitId,
                    'expires_at': created.expiresAt.toUtc().toIso8601String(),
                    'created_at': createdAt,
                  };
                  return CachedProxyResponse(
                    statusCode: 201,
                    body: <String, Object?>{
                      'invite_id': created.inviteId,
                      'expires_at': created.expiresAt.toUtc().toIso8601String(),
                      if (created.userId != null) 'user_id': created.userId,
                      'invite': invite,
                    },
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'GET' &&
                authOperationPath == adminAuthInvitesPath) {
              if (!await requirePermission('team.users.view')) return;
              final listed = await authOperationsGateway.listInvites(
                TeamInviteListCommand(
                  actorUserId: scope.userId,
                  operatorId: scope.operatorId,
                  locationId: scope.locationId,
                ),
              );
              _writeJson(response, 200, <String, Object?>{
                'invites': listed.invites.map(_teamInviteToJson).toList(),
              });
              return;
            }

            if (request.method == 'DELETE' &&
                authOperationPath.startsWith(adminAuthInvitePrefix)) {
              if (!await requirePermission('team.users.invite')) return;
              final inviteId = _pathSuffix(
                authOperationPath,
                adminAuthInvitePrefix,
              );
              if (inviteId == null) {
                _writeJson(response, 404, <String, Object?>{
                  'error': 'not found',
                  'method': request.method,
                  'path': path,
                });
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: 'DELETE $adminAuthInvitePrefix$inviteId',
                key: idempotencyKey,
                compute: () async {
                  final revoked = await authOperationsGateway.revokeInvite(
                    TeamInviteRevokeCommand(
                      actorUserId: scope.userId,
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                      inviteId: inviteId,
                      reason: _nonBlankString(body['reason']),
                    ),
                  );
                  return CachedProxyResponse(
                    statusCode: 200,
                    body: <String, Object?>{
                      'ok': true,
                      'revoked': revoked.revoked,
                    },
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'POST' &&
                authOperationPath.startsWith(adminAuthSessionsPrefix)) {
              if (!await requirePermission('team.session.force_logout')) return;
              final sessionId = _sessionRevokeIdFromPath(authOperationPath);
              if (sessionId == null) {
                _writeJson(response, 404, <String, Object?>{
                  'error': 'not found',
                  'method': request.method,
                  'path': path,
                });
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final targetUserId = _nonBlankString(body['user_id']);
              final cached = await authOpsCache.runOrReplay(
                route: '$adminAuthSessionsPrefix$sessionId/revoke',
                key: idempotencyKey,
                compute: () async {
                  final revoked = await authOperationsGateway.revokeSession(
                    AuthSessionRevokeCommand(
                      actorUserId: targetUserId ?? scope.userId,
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                      sessionId: sessionId,
                      reason:
                          _nonBlankString(body['admin_reason']) ??
                          _nonBlankString(body['reason']) ??
                          'admin.session.force_logout',
                    ),
                  );
                  return CachedProxyResponse(
                    statusCode: 200,
                    body: <String, Object?>{
                      'ok': true,
                      'revoked': revoked.revoked,
                    },
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            // CODE_OPS_DEBT Theme B#1 — single-admin PII erasure
            // routes. Three shapes (POST request, POST reverse, GET
            // status) all live under the user-action prefix; we
            // dispatch them BEFORE _userActionFromPath so the
            // 3-segment path (`<id>/erase-pii/reverse`) does not
            // false-404 against the standard 2-segment parser.
            final piiErasurePath = _piiErasurePathFromAdminAuthUsersPrefix(
              authOperationPath,
            );
            if (piiErasurePath != null) {
              final piiService = userPiiErasureService;
              if (piiService == null) {
                _writeJson(response, 503, <String, Object?>{
                  'error': 'pii_erasure_not_configured',
                  'message':
                      'route requires a UserPiiErasureService to be installed',
                });
                return;
              }
              if (!await requirePermission(PermissionKeys.adminUsersErasePii)) {
                return;
              }
              if (request.method == 'GET') {
                final status = await piiService.statusFor(
                  operatorId: scope.operatorId,
                  locationId: scope.locationId,
                  targetUserId: piiErasurePath.userId,
                );
                if (status == null) {
                  _writeJson(response, 200, <String, Object?>{'erasure': null});
                  return;
                }
                _writeJson(response, 200, <String, Object?>{
                  'erasure': <String, Object?>{
                    'erasure_id': status.erasureId,
                    'requested_at': status.requestedAt
                        .toUtc()
                        .toIso8601String(),
                    'requested_by_user_id': status.requestedByUserId,
                    'grace_period_ends_at': status.gracePeriodEndsAt
                        .toUtc()
                        .toIso8601String(),
                    'applied_at': status.appliedAt?.toUtc().toIso8601String(),
                    'reversed_at': status.reversedAt?.toUtc().toIso8601String(),
                    'reversed_by_user_id': status.reversedByUserId,
                    'reversal_reason': status.reversalReason,
                    'state': status.isApplied
                        ? 'applied'
                        : status.isReversed
                        ? 'reversed'
                        : 'pending',
                  },
                });
                return;
              }
              if (request.method == 'POST' &&
                  piiErasurePath.action == 'request') {
                final idempotencyKey = readIdempotencyKeyOrFail();
                if (idempotencyKey == null) return;
                final routeKey =
                    '$adminAuthUsersPrefix${piiErasurePath.userId}/erase-pii';
                final cached = await authOpsCache.runOrReplay(
                  route: routeKey,
                  key: idempotencyKey,
                  compute: () async {
                    // Carry-over follow-up #3 (2026-05-08): the
                    // service now derives `business_date` from the
                    // restaurant's IANA tz when a resolver is bound at
                    // construction (proxy bootstrap injects an
                    // IanaTimezoneConverter-backed closure). The
                    // service falls back to UTC truncation when no
                    // resolver is bound, preserving the legacy
                    // behaviour for callers that have not been wired
                    // yet. The column drives partition routing only.
                    final result = await piiService.requestErasure(
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                      targetUserId: piiErasurePath.userId,
                      requestedByUserId: scope.userId,
                    );
                    if (result == null) {
                      return CachedProxyResponse(
                        statusCode: 404,
                        body: <String, Object?>{
                          'error': 'user_not_found',
                          'message':
                              'no user with the requested id in this operator',
                        },
                      );
                    }
                    return CachedProxyResponse(
                      statusCode: 202,
                      body: <String, Object?>{
                        'erasure_id': result.erasureId,
                        'grace_period_ends_at': result.gracePeriodEndsAt
                            .toUtc()
                            .toIso8601String(),
                      },
                    );
                  },
                );
                _writeJson(response, cached.statusCode, cached.body);
                return;
              }
              if (request.method == 'POST' &&
                  piiErasurePath.action == 'reverse') {
                final idempotencyKey = readIdempotencyKeyOrFail();
                if (idempotencyKey == null) return;
                final erasureId = _nonBlankString(body['erasure_id']);
                if (erasureId == null) {
                  _writeJson(response, 400, <String, Object?>{
                    'error': 'missing_erasure_id',
                    'message': 'request body must include erasure_id',
                  });
                  return;
                }
                final routeKey =
                    '$adminAuthUsersPrefix'
                    '${piiErasurePath.userId}/erase-pii/reverse';
                final cached = await authOpsCache.runOrReplay(
                  route: routeKey,
                  key: idempotencyKey,
                  compute: () async {
                    final result = await piiService.reverseErasure(
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                      targetUserId: piiErasurePath.userId,
                      erasureId: erasureId,
                      reversedByUserId: scope.userId,
                      reversalReason:
                          _nonBlankString(body['reversal_reason']) ??
                          _nonBlankString(body['admin_reason']),
                    );
                    if (result.notFound) {
                      return CachedProxyResponse(
                        statusCode: 404,
                        body: <String, Object?>{
                          'error': 'erasure_not_found',
                          'message': 'no erasure row with the requested id',
                        },
                      );
                    }
                    if (result.graceExpired) {
                      return CachedProxyResponse(
                        statusCode: 410,
                        body: <String, Object?>{
                          'error': 'grace_window_expired',
                          'message':
                              'erasure grace window has expired or row '
                              'is already terminal',
                        },
                      );
                    }
                    return CachedProxyResponse(
                      statusCode: 200,
                      body: <String, Object?>{'reversed': true},
                    );
                  },
                );
                _writeJson(response, cached.statusCode, cached.body);
                return;
              }
              _writeJson(response, 405, <String, Object?>{
                'error': 'method_not_allowed',
                'method': request.method,
                'path': path,
              });
              return;
            }

            if (request.method == 'POST' &&
                authOperationPath.startsWith(adminAuthUsersPrefix)) {
              final action = _userActionFromPath(authOperationPath);
              if (action == null) {
                _writeJson(response, 404, <String, Object?>{
                  'error': 'not found',
                  'method': request.method,
                  'path': path,
                });
                return;
              }
              final canonicalAction = switch (action.action) {
                'deactivate' => 'suspend',
                'reset-mfa-factors' => 'reset-mfa',
                _ => action.action,
              };
              // 11A.14 ops-debt fix: the F&F admin support path
              // (`/v1/admin/auth/users/:id/reset-mfa-factors`) gates on
              // the new `admin.users.reset_mfa_factors` permission key
              // (added by migration `202605061100_phase_11A_14_…`). The
              // operator self-service team path
              // (`/v1/auth/team/users/:id/reset-mfa`) keeps the existing
              // `team.users.reset_mfa` posture for delayed authenticator
              // removal. Both URL families canonicalize to the admin
              // shape via `_canonicalAuthOperationPath`, so we use the
              // original `path` here to choose the gate.
              final isAdminCallerPath = path.startsWith(adminAuthUsersPrefix);
              final permissionKey = switch (canonicalAction) {
                'suspend' => 'team.users.deactivate',
                'reactivate' => 'team.users.reactivate',
                'soft-delete' => 'team.users.soft_delete',
                'reset-password' => 'team.users.reset_password',
                'reset-mfa' =>
                  isAdminCallerPath
                      ? PermissionKeys.adminUsersResetMfaFactors
                      : PermissionKeys.teamUsersResetMfa,
                'cancel-mfa-removal' =>
                  isAdminCallerPath
                      ? PermissionKeys.adminUsersResetMfaFactors
                      : PermissionKeys.teamUsersResetMfa,
                'force-logout' => 'team.session.force_logout',
                _ => null,
              };
              if (permissionKey == null) {
                _writeJson(response, 404, <String, Object?>{
                  'error': 'not found',
                  'method': request.method,
                  'path': path,
                });
                return;
              }
              if (!await requirePermission(permissionKey)) return;
              final userActionRouteKey =
                  '$adminAuthUsersPrefix${action.userId}/$canonicalAction';
              if (canonicalAction == 'reset-password') {
                final idempotencyKey = readIdempotencyKeyOrFail();
                if (idempotencyKey == null) return;
                final cached = await authOpsCache.runOrReplay(
                  route: userActionRouteKey,
                  key: idempotencyKey,
                  compute: () async {
                    await authOperationsGateway.requestPasswordReset(
                      TeamPasswordResetCommand(
                        actorUserId: scope.userId,
                        operatorId: scope.operatorId,
                        locationId: scope.locationId,
                        targetUserId: action.userId,
                      ),
                    );
                    return CachedProxyResponse(
                      statusCode: 200,
                      body: <String, Object?>{'ok': true},
                    );
                  },
                );
                _writeJson(response, cached.statusCode, cached.body);
                return;
              }
              if (canonicalAction == 'reset-mfa') {
                if (mfaOperationsGateway == null) {
                  _writeJson(response, 503, <String, Object?>{
                    'error': 'mfa_operations_not_configured',
                    'message':
                        'route requires an MfaOperationsGateway to be installed',
                  });
                  return;
                }
                final freshEnough = _requireFreshAuthenticationOrWrite(
                  response: response,
                  scope: scope,
                  requestedAt: clock().toUtc(),
                );
                if (!freshEnough) return;
                final idempotencyKey = readIdempotencyKeyOrFail();
                if (idempotencyKey == null) return;
                final cached = await authOpsCache.runOrReplay(
                  route: userActionRouteKey,
                  key: idempotencyKey,
                  compute: () async {
                    final queued = await mfaOperationsGateway.revokeUserFactors(
                      MfaRevokeUserFactorsCommand(
                        actorUserId: scope.userId,
                        operatorId: scope.operatorId,
                        locationId: scope.locationId,
                        targetUserId: action.userId,
                        stepUpProofId: _freshAuthProofId(
                          scope: scope,
                          path: path,
                          requestedAt: clock().toUtc(),
                        ),
                      ),
                    );
                    return CachedProxyResponse(
                      statusCode: 200,
                      body: <String, Object?>{
                        'ok': true,
                        'requested_count': queued.requestedCount,
                        'request_ids': queued.requestIds,
                        if (queued.executeAfter != null)
                          'execute_after': queued.executeAfter!
                              .toUtc()
                              .toIso8601String(),
                      },
                    );
                  },
                );
                _writeJson(response, cached.statusCode, cached.body);
                return;
              }
              if (canonicalAction == 'cancel-mfa-removal') {
                if (mfaOperationsGateway == null) {
                  _writeJson(response, 503, <String, Object?>{
                    'error': 'mfa_operations_not_configured',
                    'message':
                        'route requires an MfaOperationsGateway to be installed',
                  });
                  return;
                }
                final requestId = _nonBlankString(body['request_id']);
                if (requestId == null) {
                  _writeJson(response, 400, <String, Object?>{
                    'error': 'missing_removal_request_id',
                    'message': 'request body must include request_id',
                  });
                  return;
                }
                final idempotencyKey = readIdempotencyKeyOrFail();
                if (idempotencyKey == null) return;
                final cached = await authOpsCache.runOrReplay(
                  route: userActionRouteKey,
                  key: idempotencyKey,
                  compute: () async {
                    final completed = await mfaOperationsGateway
                        .cancelFactorRemoval(
                          MfaCancelFactorRemovalCommand(
                            actorUserId: scope.userId,
                            operatorId: scope.operatorId,
                            locationId: scope.locationId,
                            targetUserId: action.userId,
                            requestId: requestId,
                          ),
                        );
                    return CachedProxyResponse(
                      statusCode: 200,
                      body: <String, Object?>{
                        'ok': true,
                        'cancelled': completed.cancelled,
                      },
                    );
                  },
                );
                _writeJson(response, cached.statusCode, cached.body);
                return;
              }
              if (canonicalAction == 'force-logout') {
                final idempotencyKey = readIdempotencyKeyOrFail();
                if (idempotencyKey == null) return;
                final cached = await authOpsCache.runOrReplay(
                  route: userActionRouteKey,
                  key: idempotencyKey,
                  compute: () async {
                    final revoked = await authOperationsGateway.signOutAll(
                      AuthAllSessionsRevokeCommand(
                        actorUserId: scope.userId,
                        operatorId: scope.operatorId,
                        locationId: scope.locationId,
                        targetUserId: action.userId,
                        reason:
                            _nonBlankString(body['admin_reason']) ??
                            _nonBlankString(body['reason']) ??
                            'admin.session.force_logout',
                      ),
                    );
                    return CachedProxyResponse(
                      statusCode: 200,
                      body: <String, Object?>{
                        'ok': true,
                        'revoked_count': revoked.revokedCount,
                      },
                    );
                  },
                );
                _writeJson(response, cached.statusCode, cached.body);
                return;
              }

              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: userActionRouteKey,
                key: idempotencyKey,
                compute: () async {
                  final command = TeamUserStatusCommand(
                    actorUserId: scope.userId,
                    operatorId: scope.operatorId,
                    locationId: scope.locationId,
                    targetUserId: action.userId,
                    reason:
                        _nonBlankString(body['admin_reason']) ??
                        _nonBlankString(body['reason']) ??
                        canonicalAction,
                  );
                  final updated = switch (canonicalAction) {
                    'suspend' => await authOperationsGateway.suspendUser(
                      command,
                    ),
                    'reactivate' => await authOperationsGateway.reactivateUser(
                      command,
                    ),
                    'soft-delete' => await authOperationsGateway.softDeleteUser(
                      command,
                    ),
                    _ => throw StateError('unreachable action'),
                  };
                  final user = await loadTeamUserJson(action.userId);
                  return CachedProxyResponse(
                    statusCode: 200,
                    body: <String, Object?>{
                      'ok': true,
                      'updated': updated.updated,
                      if (user != null) 'user': user,
                    },
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'POST' &&
                authOperationPath == adminAuthRoleGrantsPath) {
              if (!await requirePermission('team.roles.assign')) return;
              final targetUserId = _nonBlankString(body['user_id']);
              final roleId = _nonBlankString(body['role_id']);
              final scopeType = _nonBlankString(body['scope_type']);
              if (_nonBlankString(body['role_key']) != null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'role_id_required',
                  'message':
                      'role grants must use role_id; role_key is read-only',
                });
                return;
              }
              if (targetUserId == null || roleId == null || scopeType == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_role_grant_fields',
                  'message': 'user_id, role_id, and scope_type are required',
                });
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: adminAuthRoleGrantsPath,
                key: idempotencyKey,
                compute: () async {
                  final created = await authOperationsGateway.createRoleGrant(
                    TeamRoleGrantCreateCommand(
                      actorUserId: scope.userId,
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                      targetUserId: targetUserId,
                      roleId: roleId,
                      scopeType: scopeType,
                      targetLocationId: _nonBlankString(body['location_id']),
                      targetOrgUnitId: _nonBlankString(body['org_unit_id']),
                      reason: _nonBlankString(body['reason']),
                    ),
                  );
                  return CachedProxyResponse(
                    statusCode: 201,
                    body: <String, Object?>{'user_role_id': created.userRoleId},
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'DELETE' &&
                authOperationPath.startsWith(adminAuthRoleGrantPrefix)) {
              if (!await requirePermission('team.roles.revoke')) return;
              final userRoleId = _pathSuffix(
                authOperationPath,
                adminAuthRoleGrantPrefix,
              );
              final targetUserId = _nonBlankString(body['user_id']);
              if (userRoleId == null || targetUserId == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_role_grant_revoke_fields',
                  'message':
                      'role grant id in path and user_id body are required',
                });
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: 'DELETE $adminAuthRoleGrantPrefix$userRoleId',
                key: idempotencyKey,
                compute: () async {
                  final revoked = await authOperationsGateway.revokeRoleGrant(
                    TeamRoleGrantRevokeCommand(
                      actorUserId: scope.userId,
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                      userRoleId: userRoleId,
                      targetUserId: targetUserId,
                      reason: _nonBlankString(body['reason']),
                    ),
                  );
                  return CachedProxyResponse(
                    statusCode: 200,
                    body: <String, Object?>{
                      'ok': true,
                      'revoked': revoked.revoked,
                    },
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'GET' &&
                authOperationPath == adminAuthOrgUnitsPath) {
              if (!await requirePermission('team.users.view')) return;
              final listed = await authOperationsGateway.listOrgHierarchy(
                TeamOrgHierarchyListCommand(
                  actorUserId: scope.userId,
                  operatorId: scope.operatorId,
                  locationId: scope.locationId,
                ),
              );
              _writeJson(response, 200, <String, Object?>{
                'org_units': listed.orgUnits
                    .map(_teamOrgUnitToJson)
                    .toList(growable: false),
                'locations': listed.locations
                    .map(_teamOrgLocationToJson)
                    .toList(growable: false),
              });
              return;
            }

            if (request.method == 'POST' &&
                authOperationPath == adminAuthOrgUnitsPath) {
              if (!await requirePermission('team.roles.assign')) return;
              final parentOrgUnitId = _nonBlankString(
                body['parent_org_unit_id'],
              );
              final unitType = _nonBlankString(body['unit_type']);
              final label = _nonBlankString(body['label']);
              final name = _nonBlankString(body['name']);
              if (parentOrgUnitId == null ||
                  unitType == null ||
                  label == null ||
                  name == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_org_unit_fields',
                  'message':
                      'parent_org_unit_id, unit_type, label, and name are required',
                });
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: adminAuthOrgUnitsPath,
                key: idempotencyKey,
                compute: () async {
                  final created = await authOperationsGateway.createOrgUnit(
                    TeamOrgUnitCreateCommand(
                      actorUserId: scope.userId,
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                      parentOrgUnitId: parentOrgUnitId,
                      unitType: unitType,
                      label: label,
                      name: name,
                      adminReason:
                          _nonBlankString(body['admin_reason']) ??
                          _nonBlankString(body['adminReason']),
                    ),
                  );
                  return CachedProxyResponse(
                    statusCode: 201,
                    body: <String, Object?>{'org_unit_id': created.orgUnitId},
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'PATCH' &&
                authOperationPath.startsWith(adminAuthOrgUnitPrefix) &&
                authOperationPath.endsWith('/parent')) {
              if (!await requirePermission('team.roles.assign')) return;
              final targetOrgUnitId = _orgUnitIdFromParentPath(
                authOperationPath,
              );
              final parentOrgUnitId = _nonBlankString(
                body['parent_org_unit_id'],
              );
              final adminReason =
                  _nonBlankString(body['admin_reason']) ??
                  _nonBlankString(body['adminReason']);
              if (targetOrgUnitId == null ||
                  parentOrgUnitId == null ||
                  adminReason == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_org_unit_move_fields',
                  'message':
                      'org unit id in path, parent_org_unit_id, and admin_reason body are required',
                });
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: '$adminAuthOrgUnitPrefix$targetOrgUnitId/parent',
                key: idempotencyKey,
                compute: () async {
                  final moved = await authOperationsGateway.moveOrgUnit(
                    TeamOrgUnitMoveCommand(
                      actorUserId: scope.userId,
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                      orgUnitId: targetOrgUnitId,
                      parentOrgUnitId: parentOrgUnitId,
                      adminReason: adminReason,
                    ),
                  );
                  return CachedProxyResponse(
                    statusCode: 200,
                    body: <String, Object?>{
                      'ok': true,
                      'org_unit': _teamOrgUnitToJson(moved.orgUnit),
                    },
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            // GAP A1 rename — logic in `org_unit_rename_route.dart`.
            if (request.method == 'PATCH' &&
                authOperationPath.startsWith(adminAuthOrgUnitPrefix) &&
                authOperationPath.endsWith('/name')) {
              if (!await requirePermission('team.roles.assign')) return;
              final renameId = OrgUnitRenameRouter.orgUnitIdFromNamePath(
                authOperationPath,
                adminAuthOrgUnitPrefix,
              );
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached =
                  await OrgUnitRenameRouter(
                    authOperationsGateway: authOperationsGateway,
                    orgUnitToJson: _teamOrgUnitToJson,
                  ).dispatch(
                    targetOrgUnitId: renameId,
                    isSelfService: path.startsWith(authTeamOrgUnitPrefix),
                    scopeUserId: scope.userId,
                    operatorId: scope.operatorId,
                    locationId: scope.locationId,
                    body: body,
                    nonBlankString: _nonBlankString,
                    cache: authOpsCache,
                    idempotencyKey: idempotencyKey,
                    route: '$adminAuthOrgUnitPrefix$renameId/name',
                  );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'PATCH' &&
                authOperationPath.startsWith(adminAuthOrgUnitPrefix) &&
                (authOperationPath.endsWith('/suspend') ||
                    authOperationPath.endsWith('/reactivate'))) {
              if (!await requirePermission('team.hierarchy.suspend')) return;
              final action = authOperationPath.endsWith('/suspend')
                  ? 'suspend'
                  : 'reactivate';
              final orgUnitId = _idFromAdminAuthActionPath(
                authOperationPath,
                adminAuthOrgUnitPrefix,
                action,
              );
              final adminReason =
                  _nonBlankString(body['admin_reason']) ??
                  _nonBlankString(body['adminReason']);
              if (orgUnitId == null || adminReason == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_org_unit_lifecycle_fields',
                  'message':
                      'org unit id in path and admin_reason body are required',
                });
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: '$adminAuthOrgUnitPrefix$orgUnitId/$action',
                key: idempotencyKey,
                compute: () async {
                  final command = TeamOrgUnitLifecycleCommand(
                    actorUserId: scope.userId,
                    operatorId: scope.operatorId,
                    locationId: scope.locationId,
                    orgUnitId: orgUnitId,
                    adminReason: adminReason,
                  );
                  final result = action == 'suspend'
                      ? await authOperationsGateway.suspendOrgUnit(command)
                      : await authOperationsGateway.reactivateOrgUnit(command);
                  return CachedProxyResponse(
                    statusCode: 200,
                    body: <String, Object?>{
                      'ok': true,
                      'org_unit': _teamOrgUnitToJson(result.orgUnit),
                    },
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'POST' &&
                authOperationPath.startsWith(adminAuthOrgUnitPrefix) &&
                authOperationPath.endsWith('/delete')) {
              if (!await requirePermission('team.hierarchy.delete')) return;
              final orgUnitId = _idFromAdminAuthActionPath(
                authOperationPath,
                adminAuthOrgUnitPrefix,
                'delete',
              );
              final adminReason =
                  _nonBlankString(body['admin_reason']) ??
                  _nonBlankString(body['adminReason']);
              if (orgUnitId == null || adminReason == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_org_unit_delete_fields',
                  'message':
                      'org unit id in path and admin_reason body are required',
                });
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: '$adminAuthOrgUnitPrefix$orgUnitId/delete',
                key: idempotencyKey,
                compute: () async {
                  final deleted = await authOperationsGateway.deleteOrgUnit(
                    TeamOrgUnitLifecycleCommand(
                      actorUserId: scope.userId,
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                      orgUnitId: orgUnitId,
                      adminReason: adminReason,
                    ),
                  );
                  return CachedProxyResponse(
                    statusCode: 200,
                    body: <String, Object?>{
                      'ok': true,
                      'deleted': deleted.deleted,
                    },
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'PATCH' &&
                authOperationPath.startsWith(adminAuthLocationsPrefix) &&
                authOperationPath.endsWith('/org-unit')) {
              if (!await requirePermission('team.roles.assign')) return;
              final targetLocationId = _orgUnitLocationIdFromPath(
                authOperationPath,
              );
              final parentOrgUnitId = _nonBlankString(
                body['parent_org_unit_id'],
              );
              final adminReason =
                  _nonBlankString(body['admin_reason']) ??
                  _nonBlankString(body['adminReason']);
              if (targetLocationId == null ||
                  parentOrgUnitId == null ||
                  adminReason == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_location_org_unit_fields',
                  'message':
                      'location id in path, parent_org_unit_id, and admin_reason body are required',
                });
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: '$adminAuthLocationsPrefix$targetLocationId/org-unit',
                key: idempotencyKey,
                compute: () async {
                  final moved = await authOperationsGateway
                      .moveLocationToOrgUnit(
                        TeamLocationOrgUnitMoveCommand(
                          actorUserId: scope.userId,
                          operatorId: scope.operatorId,
                          locationId: scope.locationId,
                          targetLocationId: targetLocationId,
                          parentOrgUnitId: parentOrgUnitId,
                          adminReason: adminReason,
                        ),
                      );
                  return CachedProxyResponse(
                    statusCode: 200,
                    body: <String, Object?>{'ok': true, 'moved': moved.moved},
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'PATCH' &&
                authOperationPath.startsWith(adminAuthLocationsPrefix) &&
                (authOperationPath.endsWith('/suspend') ||
                    authOperationPath.endsWith('/reactivate'))) {
              if (!await requirePermission('team.hierarchy.suspend')) return;
              final action = authOperationPath.endsWith('/suspend')
                  ? 'suspend'
                  : 'reactivate';
              final targetLocationId = _idFromAdminAuthActionPath(
                authOperationPath,
                adminAuthLocationsPrefix,
                action,
              );
              final adminReason =
                  _nonBlankString(body['admin_reason']) ??
                  _nonBlankString(body['adminReason']);
              if (targetLocationId == null || adminReason == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_location_lifecycle_fields',
                  'message':
                      'location id in path and admin_reason body are required',
                });
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: '$adminAuthLocationsPrefix$targetLocationId/$action',
                key: idempotencyKey,
                compute: () async {
                  final command = TeamLocationLifecycleCommand(
                    actorUserId: scope.userId,
                    operatorId: scope.operatorId,
                    locationId: scope.locationId,
                    targetLocationId: targetLocationId,
                    adminReason: adminReason,
                  );
                  final result = action == 'suspend'
                      ? await authOperationsGateway.suspendLocation(command)
                      : await authOperationsGateway.reactivateLocation(command);
                  return CachedProxyResponse(
                    statusCode: 200,
                    body: <String, Object?>{
                      'ok': true,
                      'location': _teamOrgLocationToJson(result.location),
                    },
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }

            if (request.method == 'POST' &&
                authOperationPath.startsWith(adminAuthLocationsPrefix) &&
                authOperationPath.endsWith('/delete')) {
              if (!await requirePermission('team.hierarchy.delete')) return;
              final targetLocationId = _idFromAdminAuthActionPath(
                authOperationPath,
                adminAuthLocationsPrefix,
                'delete',
              );
              final adminReason =
                  _nonBlankString(body['admin_reason']) ??
                  _nonBlankString(body['adminReason']);
              if (targetLocationId == null || adminReason == null) {
                _writeJson(response, 400, <String, Object?>{
                  'error': 'missing_location_delete_fields',
                  'message':
                      'location id in path and admin_reason body are required',
                });
                return;
              }
              final idempotencyKey = readIdempotencyKeyOrFail();
              if (idempotencyKey == null) return;
              final cached = await authOpsCache.runOrReplay(
                route: '$adminAuthLocationsPrefix$targetLocationId/delete',
                key: idempotencyKey,
                compute: () async {
                  final deleted = await authOperationsGateway.deleteLocation(
                    TeamLocationLifecycleCommand(
                      actorUserId: scope.userId,
                      operatorId: scope.operatorId,
                      locationId: scope.locationId,
                      targetLocationId: targetLocationId,
                      adminReason: adminReason,
                    ),
                  );
                  return CachedProxyResponse(
                    statusCode: 200,
                    body: <String, Object?>{
                      'ok': true,
                      'deleted': deleted.deleted,
                    },
                  );
                },
              );
              _writeJson(response, cached.statusCode, cached.body);
              return;
            }
          } on MfaOperationRejected catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.code,
              'message': error.message,
              if (error.retryAfter != null)
                'retry_after': error.retryAfter!.toUtc().toIso8601String(),
              if (error.resetsAt != null)
                'resets_at': error.resetsAt!.toUtc().toIso8601String(),
            });
            return;
          } on AuthOperationRejected catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.code,
              'message': error.message,
              if (error.details.isNotEmpty) ...error.details,
            });
            return;
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'auth_operations',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_operations_unavailable',
              'message': 'auth operation is unavailable; please retry',
            });
            return;
          }
        }

        if (request.method == 'POST' &&
            path == authRefreshTokensRevokeAllPath) {
          if (firebaseAdminAuthClient == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'refresh_token_revoke_not_configured',
              'message':
                  'route requires a FirebaseAdminAuthClient to be installed',
            });
            return;
          }

          OperatorContext scope;
          try {
            scope = await authGuard.requireOperatorContext(
              authorizationHeader: request.headers.value(
                HttpHeaders.authorizationHeader,
              ),
            );
          } on ProxyAuthError catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.message,
            });
            return;
          }

          try {
            await firebaseAdminAuthClient.revokeRefreshTokens(
              uid: scope.firebaseUid ?? scope.userId,
            );
          } on FirebaseAdminAuthError catch (error) {
            _writeJson(response, 503, <String, Object?>{
              'error': error.code,
              'message': 'refresh-token revoke is unavailable; please retry',
            });
            return;
          } on Exception catch (_) {
            // A3.4: typed `FirebaseAdminAuthError` caught above. Firebase REST
            // transport/parse Exceptions (IOException / TimeoutException /
            // FormatException / HttpException) land here; `Error`s propagate
            // per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'refresh_token_revoke_unavailable',
              'message': 'refresh-token revoke is unavailable; please retry',
            });
            return;
          }

          _writeJson(response, 200, <String, Object?>{'ok': true});
          return;
        }

        if (request.method == 'GET' && path == authSessionsListPath) {
          if (authOperationsGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_operations_not_configured',
              'message':
                  'route requires an AuthOperationsGateway to be installed',
            });
            return;
          }

          OperatorContext scope;
          try {
            scope = await authGuard.requireOperatorContext(
              authorizationHeader: request.headers.value(
                HttpHeaders.authorizationHeader,
              ),
            );
          } on ProxyAuthError catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.message,
            });
            return;
          }

          try {
            final listed = await authOperationsGateway.listActiveSessions(
              AuthActiveSessionsListCommand(
                actorUserId: scope.userId,
                operatorId: scope.operatorId,
                locationId: scope.locationId,
              ),
            );
            _writeJson(response, 200, <String, Object?>{
              'sessions': listed.sessions
                  .map(_authSessionSummaryToJson)
                  .toList(growable: false),
            });
          } on AuthOperationRejected catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.code,
              'message': error.message,
            });
          } on Exception catch (_) {
            // A3.4: typed `AuthOperationRejected` caught above; gateway
            // Postgres surface (PgException / TimeoutException / IOException
            // / closed-pool wraps) lands here; `Error`s propagate per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_sessions_unavailable',
              'message': 'active sessions are unavailable; please retry',
            });
          }
          return;
        }

        // 11W.4 ops-debt — GET /v1/auth/team/sessions. Lists every
        // active `auth_sessions` row whose `user_id` belongs to the
        // caller's operator (joined to `users` for display name and
        // email). Gated on `team.session.force_logout`. Per-tenant
        // isolation is enforced by the join through
        // `users.operator_id = scope.operatorId`.
        if (request.method == 'GET' && path == authTeamSessionsListPath) {
          if (authOperationsGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_operations_not_configured',
              'message':
                  'route requires an AuthOperationsGateway to be installed',
            });
            return;
          }
          if (permissionSnapshotResolver == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'permission_snapshot_not_configured',
              'message':
                  'route requires a ProxyPermissionSnapshotResolver to be '
                  'installed',
            });
            return;
          }
          OperatorContext scope;
          try {
            scope = await authGuard.requireOperatorContext(
              authorizationHeader: request.headers.value(
                HttpHeaders.authorizationHeader,
              ),
            );
          } on ProxyAuthError catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.message,
            });
            return;
          }
          ProxyPermissionSnapshot snapshot;
          try {
            snapshot = await permissionSnapshotResolver.load(scope);
          } on Exception catch (_) {
            // A3.4: permission-snapshot Postgres surface (PgException /
            // TimeoutException / IOException / closed-pool wraps); `Error`s
            // propagate per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'permission_snapshot_unavailable',
              'message': 'permissions are unavailable; please retry',
            });
            return;
          }
          final effect =
              snapshot.permissions[PermissionKeys.teamSessionForceLogout];
          if (effect != PermissionEffect.allow) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'forbidden',
              'message':
                  'team.session.force_logout permission is required to list '
                  'team sessions',
            });
            return;
          }
          try {
            final listed = await authOperationsGateway.listTeamActiveSessions(
              AuthTeamActiveSessionsListCommand(
                actorUserId: scope.userId,
                operatorId: scope.operatorId,
                locationId: scope.locationId,
              ),
            );
            _writeJson(response, 200, <String, Object?>{
              'sessions': <Map<String, Object?>>[
                for (final entry in listed.sessions)
                  <String, Object?>{
                    ..._authSessionSummaryToJson(entry.session),
                    'user_id': entry.targetUserId,
                    if (entry.targetDisplayName != null)
                      'display_name': entry.targetDisplayName,
                    if (entry.targetEmail != null) 'email': entry.targetEmail,
                  },
              ],
            });
          } on AuthOperationRejected catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.code,
              'message': error.message,
            });
          } on Exception catch (_) {
            // A3.4: typed `AuthOperationRejected` caught above; gateway
            // Postgres surface (PgException / TimeoutException / IOException
            // / closed-pool wraps); `Error`s propagate per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'team_sessions_unavailable',
              'message': 'team active sessions are unavailable; please retry',
            });
          }
          return;
        }

        final authLocationIntegrationsMatch = authLocationIntegrationsPattern
            .firstMatch(path);
        if (request.method == 'GET' && authLocationIntegrationsMatch != null) {
          if (permissionSnapshotResolver == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'permission_snapshot_not_configured',
              'message':
                  'route requires a ProxyPermissionSnapshotResolver to be installed',
            });
            return;
          }

          OperatorContext scope;
          try {
            scope = await authGuard.requireOperatorContext(
              authorizationHeader: request.headers.value(
                HttpHeaders.authorizationHeader,
              ),
            );
          } on ProxyAuthError catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.message,
            });
            return;
          }

          final locationId = Uri.decodeComponent(
            authLocationIntegrationsMatch.group(1)!,
          );
          if (locationId != scope.locationId) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'location_scope_mismatch',
              'message':
                  'integration status can only be read for the signed-in location',
            });
            return;
          }

          ProxyPermissionSnapshot snapshot;
          try {
            snapshot = await permissionSnapshotResolver.load(scope);
          } on Exception catch (_) {
            // A3.4: same permission-snapshot surface (see above); `Error`s
            // propagate per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'permission_snapshot_unavailable',
              'message': 'permissions are unavailable; please retry',
            });
            return;
          }
          final canReadIntegrations = snapshot.permissions.entries.any(
            (entry) =>
                entry.value == PermissionEffect.allow &&
                (entry.key == PermissionKeys.integrationsConfigure ||
                    entry.key.startsWith('integration.')),
          );
          if (!canReadIntegrations) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message':
                  'an integration permission is required to view vendor connections',
            });
            return;
          }

          if (operatorLocationIntegrationsProjection != null) {
            try {
              final body = await operatorLocationIntegrationsProjection(
                operatorId: scope.operatorId,
                locationId: locationId,
                actorUserId: scope.userId,
              );
              // Always stamp the verified scope on the response so the
              // projection cannot accidentally leak another operator's
              // identifiers to the wire (defense in depth alongside RLS
              // and the `withTenant` set_local).
              final outgoing = <String, Object?>{
                ...body,
                'operator_id': scope.operatorId,
                'location_id': locationId,
              };
              _writeJson(response, 200, outgoing);
            } on Exception catch (_) {
              // A3.4: integrations-projection Postgres surface (PgException /
              // TimeoutException / IOException / closed-pool wraps); `Error`s
              // propagate per C4.
              _writeJson(response, 503, <String, Object?>{
                'error': 'integrations_projection_unavailable',
                'message': 'vendor connections are unavailable; please retry',
              });
            }
            return;
          }
          // Legacy V1 stub — kept so existing test scaffolds that do
          // not bind a projection continue to receive a 200 with the
          // demo-mode-friendly empty bundle.
          _writeJson(response, 200, <String, Object?>{
            'operator_id': scope.operatorId,
            'location_id': locationId,
            'connections': const <Object?>[],
            'demo_flags': const <String, Object?>{
              'pos': true,
              'labor': true,
              'reservation': true,
            },
          });
          return;
        }

        // Audit-log server-side CSV export. Same filter shape as the
        // read route below; gated on `team.audit_log.export` via the
        // permission snapshot. Streams RFC 4180 rows back as a chunked
        // `text/csv` attachment, paging the underlying repo so the
        // proxy's memory footprint stays bounded regardless of how many
        // rows the operator's filter selects.
        if (request.method == 'GET' && path == authAuditLogExportPath) {
          if (authOperationsGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_operations_not_configured',
              'message':
                  'route requires an AuthOperationsGateway to be installed',
            });
            return;
          }
          if (permissionSnapshotResolver == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'permission_snapshot_not_configured',
              'message':
                  'route requires a ProxyPermissionSnapshotResolver to be '
                  'installed',
            });
            return;
          }

          OperatorContext scope;
          try {
            scope = await authGuard.requireOperatorContext(
              authorizationHeader: request.headers.value(
                HttpHeaders.authorizationHeader,
              ),
            );
          } on ProxyAuthError catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.message,
            });
            return;
          }

          ProxyPermissionSnapshot exportSnapshot;
          try {
            exportSnapshot = await permissionSnapshotResolver.load(scope);
          } on Exception catch (_) {
            // A3.4: same permission-snapshot surface (see above); `Error`s
            // propagate per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'permission_snapshot_unavailable',
              'message': 'permissions are unavailable; please retry',
            });
            return;
          }
          final exportEffect =
              exportSnapshot.permissions[PermissionKeys.teamAuditLogExport];
          if (exportEffect != PermissionEffect.allow) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message':
                  'team.audit_log.export permission is required to export '
                  'the audit log',
              'permission_key': PermissionKeys.teamAuditLogExport,
            });
            return;
          }

          final exportParams = request.uri.queryParameters;
          DateTime? parseExportUtc(String? raw) {
            if (raw == null || raw.isEmpty) return null;
            return DateTime.tryParse(raw)?.toUtc();
          }

          final exportFrom = parseExportUtc(exportParams['from']);
          final exportTo = parseExportUtc(exportParams['to']);
          // Coarse server-side bucket; if the screen sent a single
          // action the live read route also light it up via event_kind.
          final exportEventKind = AuthEventLabels.fromWireKey(
            exportParams['event_kind'],
          );

          // Derive a filename stamp so two exports in the same minute
          // do not collide. The operator's restaurant-local TZ is not
          // available proxy-side, so UTC is used (matches the demo
          // gateway and the existing client-side renderer).
          final exportNow = clock().toUtc();
          final stampY = exportNow.year.toString().padLeft(4, '0');
          final stampM = exportNow.month.toString().padLeft(2, '0');
          final stampD = exportNow.day.toString().padLeft(2, '0');
          final stampHh = exportNow.hour.toString().padLeft(2, '0');
          final stampMm = exportNow.minute.toString().padLeft(2, '0');
          final exportFilename =
              'forge_flow_audit_log_$stampY$stampM${stampD}_$stampHh${stampMm}_utc.csv';

          // Headers must be set BEFORE any bytes are written. Once the
          // first chunk lands we cannot switch to a JSON error response,
          // so any failure past this point ends the stream early.
          response.statusCode = 200;
          response.headers.contentType = ContentType('text', 'csv');
          response.headers.set(
            'Content-Disposition',
            'attachment; filename="$exportFilename"',
          );
          response.headers.chunkedTransferEncoding = true;
          response.headers.set('Cache-Control', 'no-store');

          // RFC 4180 column order is the same shape as the client-side
          // renderer the operator-web gateway used to emit. Keeping the
          // column set identical means the CSV body downstream tools
          // ingest doesn't shift when the export hops from client- to
          // server-side rendering.
          response.write(
            'created_at,action,actor_user_id,actor_display_name,'
            'actor_email,actor_kind,target_kind,target_id,admin_reason,'
            'payload\r\n',
          );

          var emittedRows = 0;
          var nextOffset = 0;
          var capped = false;
          try {
            while (true) {
              final pageLimit = (kAuthAuditLogExportRowCap - emittedRows).clamp(
                1,
                kAuthAuditLogExportPageSize,
              );
              final listed = await authOperationsGateway.listAuthEventsForActor(
                AuthEventListCommand(
                  // RLS-authoritative gate: pin user_id to the verified
                  // bearer-token scope. Any client-supplied user_id
                  // query param is ignored (matches the read route).
                  actorUserId: scope.userId,
                  operatorId: scope.operatorId,
                  locationId: scope.locationId,
                  limit: pageLimit,
                  offset: nextOffset,
                  eventKind: exportEventKind,
                  from: exportFrom,
                  to: exportTo,
                ),
              );
              if (listed.entries.isEmpty) break;
              for (final entry in listed.entries) {
                response.write(_renderAuthEventCsvRow(entry, scope));
                emittedRows += 1;
                if (emittedRows >= kAuthAuditLogExportRowCap) {
                  capped = true;
                  break;
                }
              }
              if (capped) break;
              if (!listed.hasMore) break;
              nextOffset += listed.entries.length;
              // Flush so chunks land on the wire as they're ready
              // rather than buffering the whole response.
              await response.flush();
            }
          } on Exception catch (_) {
            // A3.4: paged CSV export streaming loop. Surface: gateway
            // (PgException / TimeoutException / IOException) + response.flush
            // (HttpException / SocketException on client disconnect) +
            // row-render FormatException. Best-effort close — CSV truncates
            // but headers already shipped; `Error`s propagate per C4.
          }
          await response.close();
          return;
        }

        if (request.method == 'GET' && path == authAuditLogPath) {
          if (authOperationsGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_operations_not_configured',
              'message':
                  'route requires an AuthOperationsGateway to be installed',
            });
            return;
          }

          OperatorContext scope;
          try {
            scope = await authGuard.requireOperatorContext(
              authorizationHeader: request.headers.value(
                HttpHeaders.authorizationHeader,
              ),
            );
          } on ProxyAuthError catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.message,
            });
            return;
          }

          // Pagination: clamp to a per-request ceiling so a chatty client
          // can't ask for the whole ledger in one shot. Default 50 rows.
          final params = request.uri.queryParameters;
          final rawLimit = int.tryParse(params['limit'] ?? '');
          final limit = rawLimit == null
              ? 50
              : (rawLimit < 1 ? 1 : (rawLimit > 100 ? 100 : rawLimit));
          final rawOffset = int.tryParse(params['offset'] ?? '');
          final offset = rawOffset == null || rawOffset < 0 ? 0 : rawOffset;
          final eventKind = AuthEventLabels.fromWireKey(params['event_kind']);
          DateTime? parseUtc(String? raw) {
            if (raw == null || raw.isEmpty) return null;
            return DateTime.tryParse(raw)?.toUtc();
          }

          final from = parseUtc(params['from']);
          final to = parseUtc(params['to']);

          try {
            final listed = await authOperationsGateway.listAuthEventsForActor(
              AuthEventListCommand(
                // RLS-authoritative gate: pin user_id to the verified
                // bearer-token scope. Any client-supplied user_id query
                // param is ignored.
                actorUserId: scope.userId,
                operatorId: scope.operatorId,
                locationId: scope.locationId,
                limit: limit,
                offset: offset,
                eventKind: eventKind,
                from: from,
                to: to,
              ),
            );
            _writeJson(response, 200, <String, Object?>{
              'entries': listed.entries
                  .map(_authEventEntryToJson)
                  .toList(growable: false),
              'has_more': listed.hasMore,
              'limit': limit,
              'offset': offset,
            });
          } on AuthOperationRejected catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.code,
              'message': error.message,
            });
          } on Exception catch (_) {
            // A3.4: typed `AuthOperationRejected` caught above; gateway
            // Postgres surface (PgException / TimeoutException / IOException
            // / closed-pool wraps); `Error`s propagate per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_audit_log_unavailable',
              'message': 'audit log is unavailable; please retry',
            });
          }
          return;
        }

        if (request.method == 'POST' && path == authSessionLoginPath) {
          // HARD-B - the login route serves two shapes:
          //   * Success path: `{token_hash, email?}` plus a verified
          //     Bearer token. Records the session ledger row + (if
          //     `email` present + enforcer wired) an `outcome: success`
          //     attempts row.
          //   * Failure-report path: `{email, failure_outcome}` with no
          //     bearer token. Records an `outcome: failure` attempts row,
          //     emits `auth.login_failed`, and returns 401 -- or 423
          //     when the count trips the threshold + an
          //     `auth.account_locked` row.
          //
          // Body parse runs first so the failure-report branch can skip
          // the auth check; the existing success path's writer/auth/
          // token_hash checks still happen in their original order
          // afterwards so previously-written tests keep their expected
          // status codes.
          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          final email = _nonBlankString(body['email']);
          final failureOutcome = _nonBlankString(body['failure_outcome']);
          final tokenHash = _nonBlankString(body['token_hash']);
          final ledgerContext = _resolveLedgerContextFromHeaders(
            request,
            trustProxyAuditHeaders: trustProxyAuditHeaders,
          );
          final clientIpForLockout = ledgerContext.ip ?? '';

          // ---- Failure-report path ----
          if (failureOutcome != null) {
            if (!AuthLoginFailureOutcomes.all.contains(failureOutcome)) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'invalid_failure_outcome',
                'message':
                    'failure_outcome must be one of: '
                    '${AuthLoginFailureOutcomes.all.join(', ')}',
              });
              return;
            }
            if (email == null) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'missing_email',
                'message':
                    'failure_outcome requires an email field for lockout '
                    'attribution',
              });
              return;
            }
            if (clientIpForLockout.isEmpty) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'missing_client_ip',
                'message':
                    'failure-report path requires a resolvable client ip; '
                    'enable trustProxyAuditHeaders or send the request from '
                    'a peer the proxy can resolve directly',
              });
              return;
            }
            if (authLockoutEnforcer != null) {
              final emailHashHex = hashAuthEmailHex(email);
              final ipHashHex = hashAuthIpHex(clientIpForLockout);
              final now = clock().toUtc();
              final priorEval = await authLockoutEnforcer.evaluate(
                email: email,
                ip: clientIpForLockout,
              );
              // Already-locked: do not re-record a fresh failure; just
              // emit the locked outcome + audit row + 423 response.
              if (priorEval.locked) {
                await authLockoutEnforcer.recordLocked(
                  email: email,
                  ip: clientIpForLockout,
                );
                await authLockoutAuditSink?.recordAccountLocked(
                  emailHashHex: emailHashHex,
                  ipHashHex: ipHashHex,
                  attemptCount: priorEval.failureCount,
                  lockoutUntil: now.add(kAuthLoginLockoutRetryAfter),
                );
                response.headers.add(
                  HttpHeaders.retryAfterHeader,
                  kAuthLoginLockoutRetryAfter.inSeconds.toString(),
                );
                _writeJson(response, 423, <String, Object?>{
                  'error': 'account_locked',
                  'retry_after_seconds': kAuthLoginLockoutRetryAfter.inSeconds,
                });
                return;
              }
              // Below threshold: insert the failure row + emit
              // auth.login_failed. The lockout trip happens at the NEXT
              // attempt because the contract reads "after 5 failed
              // attempts ... the next failure inserts an outcome: locked
              // row" -- the 5th failure is the last regular 401, and
              // attempt #6 lands in the priorEval.locked branch above.
              final newCount = await authLockoutEnforcer.recordFailure(
                email: email,
                ip: clientIpForLockout,
              );
              // `locked: true` here means "this failure brought the count
              // up to the threshold; the next attempt will trip the
              // lock." The audit row carries the hint so investigators
              // see the count progression without joining tables, but
              // the response stays 401 (the contract's lock trips at the
              // *next* attempt).
              final atThreshold = newCount >= kAuthLoginLockoutThreshold;
              await authLockoutAuditSink?.recordLoginFailed(
                emailHashHex: emailHashHex,
                ipHashHex: ipHashHex,
                outcome: failureOutcome,
                attemptCountInWindow: newCount,
                locked: atThreshold,
              );
            }
            _writeJson(response, 401, <String, Object?>{
              'error': 'login_failed',
              'outcome': failureOutcome,
            });
            return;
          }

          // ---- Success path ----
          if (authSessionLedgerWriter == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_session_ledger_not_configured',
              'message':
                  'route requires an AuthSessionLedgerWriter to be installed',
            });
            return;
          }

          OperatorContext scope;
          try {
            scope = await authGuard.requireOperatorContext(
              authorizationHeader: request.headers.value(
                HttpHeaders.authorizationHeader,
              ),
            );
          } on ProxyAuthError catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.message,
            });
            return;
          }

          if (tokenHash == null) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_token_hash',
              'message':
                  'request body must include a non-empty token_hash field',
            });
            return;
          }

          // Pre-success lockout check: if the email is locked, the
          // success path must be refused even though the bearer token is
          // valid (e.g., a concurrent attacker trips the threshold while
          // a legitimate session-ledger write is in flight).
          if (email != null &&
              authLockoutEnforcer != null &&
              clientIpForLockout.isNotEmpty) {
            final priorEval = await authLockoutEnforcer.evaluate(
              email: email,
              ip: clientIpForLockout,
            );
            if (priorEval.locked) {
              final emailHashHex = hashAuthEmailHex(email);
              final ipHashHex = hashAuthIpHex(clientIpForLockout);
              final now = clock().toUtc();
              await authLockoutEnforcer.recordLocked(
                email: email,
                ip: clientIpForLockout,
              );
              await authLockoutAuditSink?.recordAccountLocked(
                emailHashHex: emailHashHex,
                ipHashHex: ipHashHex,
                attemptCount: priorEval.failureCount,
                lockoutUntil: now.add(kAuthLoginLockoutRetryAfter),
                operatorId: scope.operatorId,
                locationId: scope.locationId,
                // Bearer token already verified -- pass scope.userId so
                // the production sink can fan the audit row out into the
                // hash-chained `audit_logs` chain (operator + actor both
                // resolved is the contract-valid attribution shape).
                actorUserId: scope.userId,
              );
              response.headers.add(
                HttpHeaders.retryAfterHeader,
                kAuthLoginLockoutRetryAfter.inSeconds.toString(),
              );
              _writeJson(response, 423, <String, Object?>{
                'error': 'account_locked',
                'retry_after_seconds': kAuthLoginLockoutRetryAfter.inSeconds,
              });
              return;
            }
          }

          String sessionId;
          try {
            sessionId = await authSessionLedgerWriter.recordLogin(
              AuthSessionLedgerLogin(
                userId: scope.userId,
                operatorId: scope.operatorId,
                locationId: scope.locationId,
                tokenHash: tokenHash,
                context: ledgerContext,
              ),
            );
          } catch (error, stack) {
            // Fail closed with a calm message — no error stack leaks
            // past this boundary. The client surfaces this to the user
            // as a "try again in a moment" banner via
            // `AuthLoginFailure(code: 'ledger_unavailable')`. The
            // diagnostic log line carries the typed runtime class +
            // first stack frame so the originating failure mode is
            // never silently dropped (A1 instrumentation item #5).
            log(
              LogSeverity.error,
              'proxy.auth.session_ledger_record_login_failed',
              fields: <String, Object?>{
                'error_type': error.runtimeType.toString(),
                'stack_first_frame': firstStackFrame(stack),
                'user_id': scope.userId,
                'operator_id_present': scope.operatorId.isNotEmpty,
                'location_id_present': scope.locationId.isNotEmpty,
              },
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_session_ledger_unavailable',
              'message': 'auth session ledger is unavailable; please retry',
            });
            return;
          }

          // Record success in the lockout ledger so the per-tenant audit
          // surface carries the success row alongside any prior failures.
          // Per the contract, "Successful login within window resets
          // failure count" - the count query filters on outcome IN
          // (failure, locked), so a success row does not contribute to
          // the count at the next read.
          if (email != null &&
              authLockoutEnforcer != null &&
              clientIpForLockout.isNotEmpty) {
            try {
              await authLockoutEnforcer.recordSuccess(
                email: email,
                ip: clientIpForLockout,
                operatorId: scope.operatorId,
                locationId: scope.locationId,
                actorUserId: scope.userId,
              );
            } catch (error, stack) {
              // Lockout-ledger write failure must not block a
              // successful login. The session is already recorded;
              // missing the success row in the lockout ledger only
              // affects the audit surface and is recoverable from the
              // auth_events_audit success row. The diagnostic log line
              // surfaces the failure class so we can spot recurring
              // breakage (A1 instrumentation item #6).
              log(
                LogSeverity.warning,
                'proxy.auth.lockout_record_success_failed',
                fields: <String, Object?>{
                  'error_type': error.runtimeType.toString(),
                  'stack_first_frame': firstStackFrame(stack),
                  'user_id': scope.userId,
                  'operator_id_present': scope.operatorId.isNotEmpty,
                  'location_id_present': scope.locationId.isNotEmpty,
                },
              );
            }
          }

          // Slice A11.1 — build the body once so the production
          // session-record gauge can run the predicate against the
          // exact bytes we ship. The gauge is observability-only: a
          // missing-field finding NEVER blocks the 2xx (the response is
          // already committed by the time the harness reads the gauge).
          // Authority: docs/archive/_execution/lane_a_code_health/03_execution_slices.md
          // Slice A11.1 + R3 §2 stretch goal.
          final loginResponseBody = <String, Object?>{
            'session_id': sessionId,
            // Echo the resolved scope so the client can sanity-check it
            // matches the local AuthSession before persisting the envelope.
            'user_id': scope.userId,
            'operator_id': scope.operatorId,
            'location_id': scope.locationId,
          };
          sessionRecordIncompleteGauge?.observe(
            route: authSessionLoginPath,
            body: loginResponseBody,
            roles: scope.roles.toSet(),
          );
          _writeJson(response, 200, loginResponseBody);
          return;
        }

        if (request.method == 'POST' && path == authSessionRefreshPath) {
          if (authSessionLedgerWriter == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_session_ledger_not_configured',
              'message':
                  'route requires an AuthSessionLedgerWriter to be installed',
            });
            return;
          }

          OperatorContext scope;
          try {
            scope = await authGuard.requireOperatorContext(
              authorizationHeader: request.headers.value(
                HttpHeaders.authorizationHeader,
              ),
            );
          } on ProxyAuthError catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.message,
            });
            return;
          }

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          final sessionId = _nonBlankString(body['session_id']);
          if (sessionId == null) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_session_id',
              'message':
                  'request body must include a non-empty session_id field',
            });
            return;
          }

          try {
            await authSessionLedgerWriter.recordRefresh(
              sessionId: sessionId,
              userId: scope.userId,
              operatorId: scope.operatorId,
              locationId: scope.locationId,
            );
          } on Exception catch (_) {
            // A3.4: `authSessionLedgerWriter.recordRefresh` Postgres write
            // surface (PgException / TimeoutException / IOException /
            // closed-pool wraps); `Error`s propagate per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_session_ledger_unavailable',
              'message': 'auth session ledger is unavailable; please retry',
            });
            return;
          }

          _writeJson(response, 200, <String, Object?>{'ok': true});
          return;
        }

        if (request.method == 'POST' && path == authSessionRevokePath) {
          if (authSessionLedgerWriter == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_session_ledger_not_configured',
              'message':
                  'route requires an AuthSessionLedgerWriter to be installed',
            });
            return;
          }

          OperatorContext scope;
          try {
            scope = await authGuard.requireOperatorContext(
              authorizationHeader: request.headers.value(
                HttpHeaders.authorizationHeader,
              ),
            );
          } on ProxyAuthError catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.message,
            });
            return;
          }

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          final sessionId = _nonBlankString(body['session_id']);
          if (sessionId == null) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_session_id',
              'message':
                  'request body must include a non-empty session_id field',
            });
            return;
          }
          // Reason defaults to user_signed_out_this_session so a client
          // that omits it (e.g. early integration) still produces an
          // auditable revoke row instead of an empty `revoked_reason`.
          final reason =
              _nonBlankString(body['reason']) ?? 'user_signed_out_this_session';

          try {
            await authSessionLedgerWriter.revokeSession(
              sessionId: sessionId,
              userId: scope.userId,
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              reason: reason,
            );
          } on Exception catch (_) {
            // A3.4: `authSessionLedgerWriter.revokeSession` Postgres write +
            // optional Firebase admin call (PgException / TimeoutException /
            // IOException / FirebaseAdminAuthError); `Error`s propagate per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_session_ledger_unavailable',
              'message': 'auth session ledger is unavailable; please retry',
            });
            return;
          }

          _writeJson(response, 200, <String, Object?>{'ok': true});
          return;
        }

        if (request.method == 'POST' && path == authSessionRevokeAllPath) {
          if (authSessionLedgerWriter == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_session_ledger_not_configured',
              'message':
                  'route requires an AuthSessionLedgerWriter to be installed',
            });
            return;
          }

          OperatorContext scope;
          try {
            scope = await authGuard.requireOperatorContext(
              authorizationHeader: request.headers.value(
                HttpHeaders.authorizationHeader,
              ),
            );
          } on ProxyAuthError catch (error) {
            _writeJson(response, error.statusCode, <String, Object?>{
              'error': error.message,
            });
            return;
          }

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request, allowEmpty: true);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          final reason =
              _nonBlankString(body['reason']) ?? 'user_signed_out_all_sessions';

          int revoked;
          try {
            revoked = await authSessionLedgerWriter.revokeAllSessionsForUser(
              userId: scope.userId,
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              reason: reason,
            );
          } on Exception catch (_) {
            // A3.4: `authSessionLedgerWriter.revokeAllSessionsForUser` multi-
            // row transaction (PgException / TimeoutException / IOException /
            // closed-pool wraps); `Error`s propagate per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'auth_session_ledger_unavailable',
              'message': 'auth session ledger is unavailable; please retry',
            });
            return;
          }

          _writeJson(response, 200, <String, Object?>{
            'ok': true,
            'revoked_count': revoked,
          });
          return;
        }

        if (_isAdminIntegrationsOperation(path, request.method)) {
          if (integrationAdminGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'integration_admin_not_configured',
              'message':
                  'route requires an IntegrationAdminProxyGateway to be installed',
            });
            return;
          }

          final actor = await _resolveVerifiedClaimsOrWrite(
            request,
            response,
            authGuard,
          );
          if (actor == null) return;

          final integrationsMethod = request.method;
          final integrationsRoles = integrationsMethod == 'GET'
              ? kFfIntegrationAdminReadRoles
              : kFfIntegrationAdminWriteRoles;
          if (!_callerHasAnyRole(actor, integrationsRoles)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message': 'admin role claim required',
              'required_roles': integrationsRoles.toList(),
            });
            return;
          }

          // The auth permission catalog tags `integration.key_rotate` as
          // MFA-required (Phase 9 fresh-auth list). The role gate above
          // is necessary but not sufficient — a stale super_admin token
          // must NOT be allowed to rotate a production credential. Gate
          // every write method on `lastFreshAuthAt` falling inside the
          // 5-minute freshness window. GET reads are catalog-marked
          // non-MFA, so the gate is write-only.
          if (integrationsMethod != 'GET') {
            if (!_requireFreshClaimsOrWrite(
              response: response,
              claims: actor,
              requestedAt: clock().toUtc(),
              message: 'Sign in again before rotating provider keys.',
            )) {
              return;
            }
          }

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request, allowEmpty: true);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          // Audit attribution gate. `auth_events_audit.actor_user_id`
          // must be set whenever `actor_kind = 'user'`; the Phase 9
          // admin Firebase claim shape only guarantees role flags, so
          // we must explicitly resolve the verified Firebase UID into a
          // Postgres `users.user_id` (UUID) before any audit row is
          // written. If no active `users` row matches the Firebase UID
          // (Firebase admin without a Postgres onboard row), reject
          // with 403 — no audit row, no provider_credentials write.
          if (integrationAdminActorResolver == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'integration_admin_actor_resolver_not_configured',
              'message':
                  'route requires an IntegrationAdminActorResolver to be installed',
            });
            return;
          }
          final firebaseUidLookup = actor.firebaseUid ?? actor.userId;
          String? resolvedActorUserId;
          try {
            resolvedActorUserId = await integrationAdminActorResolver
                .resolveActorUserId(
                  firebaseUid: firebaseUidLookup,
                  adminReason:
                      'admin.integrations.${request.method}:'
                      '$firebaseUidLookup:resolve_actor',
                );
          } on Exception catch (_) {
            // A3.4: `integrationAdminActorResolver.resolveActorUserId`
            // Postgres lookup surface (PgException / TimeoutException /
            // IOException / closed-pool wraps); `Error`s propagate per C4.
            _writeJson(response, 503, <String, Object?>{
              'error': 'integration_admin_actor_resolve_failed',
              'message': 'actor resolution is unavailable; please retry',
            });
            return;
          }
          if (resolvedActorUserId == null) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'actor_user_not_resolvable',
              'message':
                  'verified Firebase user has no matching Postgres users row '
                  '(audit attribution requires a UUID-shaped actor)',
            });
            return;
          }

          // HARD-H — optional Idempotency-Key on rotation POST so retries
          // collapse to one KMS write + one audit row at the proxy. The
          // header is OPTIONAL for back-compat with older callers and the
          // existing test surface; when present and the store is wired,
          // `_runAdminIdempotent` handles reserve→complete against
          // `admin_request_idempotency`.
          final integrationsIdempotencyKey =
              (request.headers.value('Idempotency-Key') ?? '').trim();
          if (integrationsIdempotencyKey.length > 200) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'idempotency_key_too_long',
              'message':
                  'Idempotency-Key header must be 200 characters or fewer',
            });
            return;
          }
          try {
            await _routeIntegrationsAdmin(
              request: request,
              response: response,
              path: path,
              gateway: integrationAdminGateway,
              actorUserId: resolvedActorUserId,
              actorLogId: firebaseUidLookup,
              body: body,
              idempotencyKey: integrationsIdempotencyKey,
              idempotencyStore: adminRequestIdempotencyStore,
            );
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            if (error is _AdminInputError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            if (error is IntegrationAdminGatewayValidationError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            if (error is AdminIdempotencyKeyConflict) {
              _writeJson(response, 409, <String, Object?>{
                'error': 'idempotency_key_conflict',
                'message': error.message,
              });
              return;
            }
            _logProxyUnhandled(
              surface: 'integration_admin',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'integration_admin_unavailable',
              'message':
                  'integration admin operation is unavailable; please retry',
            });
          }
          return;
        }

        if (_isAdminPricingOperation(path, request.method)) {
          if (pricingTierAdminGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'pricing_tier_admin_not_configured',
              'message':
                  'route requires a PricingTierAdminProxyGateway to be installed',
            });
            return;
          }

          final actor = await _resolveVerifiedClaimsOrWrite(
            request,
            response,
            authGuard,
          );
          if (actor == null) return;

          // Method-scoped gate: GET admits `super_admin` + `ff_support` so
          // support users can load the read-only pricing view; PATCH /
          // PUT / POST stay strictly `super_admin`. The screen renders
          // mutate affordances based on the same role list, but the proxy
          // is the source of truth.
          final pricingMethod = request.method;
          final pricingRoles = pricingMethod == 'GET'
              ? kFfPricingAdminReadRoles
              : kFfPricingAdminWriteRoles;
          if (!_callerHasAnyRole(actor, pricingRoles)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message': 'admin role claim required',
              'required_roles': pricingRoles.toList(),
            });
            return;
          }

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request, allowEmpty: true);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          // HARD-H — optional Idempotency-Key on PATCH/PUT/POST so retries
          // collapse to one tier mutation + one audit row at the proxy.
          // Header is OPTIONAL for back-compat (existing tests don't send
          // it). When present + store is wired, `_runAdminIdempotent`
          // handles reserve→complete against `admin_request_idempotency`.
          final pricingIdempotencyKey =
              (request.headers.value('Idempotency-Key') ?? '').trim();
          if (pricingIdempotencyKey.length > 200) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'idempotency_key_too_long',
              'message':
                  'Idempotency-Key header must be 200 characters or fewer',
            });
            return;
          }
          final isScopedContractWrite =
              (pricingMethod == 'PUT' &&
                  path == adminPricingScopedContractsPath) ||
              (pricingMethod == 'DELETE' &&
                  path.startsWith(adminPricingScopedContractsPrefix));
          if (isScopedContractWrite && pricingIdempotencyKey.isEmpty) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'idempotency_key_missing',
              'message': 'Idempotency-Key header is required',
            });
            return;
          }
          try {
            await _routePricingAdmin(
              request: request,
              response: response,
              path: path,
              gateway: pricingTierAdminGateway,
              actorUserId: actor.userId,
              body: body,
              idempotencyKey: pricingIdempotencyKey,
              idempotencyStore: adminRequestIdempotencyStore,
            );
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            if (error is _AdminInputError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            if (error is PricingTierAdminGatewayValidationError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            if (error is AdminIdempotencyKeyConflict) {
              _writeJson(response, 409, <String, Object?>{
                'error': 'idempotency_key_conflict',
                'message': error.message,
              });
              return;
            }
            _logProxyUnhandled(
              surface: 'pricing_tier_admin',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'pricing_tier_admin_unavailable',
              'message':
                  'pricing tier admin operation is unavailable; please retry',
            });
          }
          return;
        }

        if (_isAdminDataAccuracyOperation(path, request.method)) {
          if (dataAccuracyAdminGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'data_accuracy_admin_not_configured',
              'message':
                  'route requires a DataAccuracyAdminProxyGateway to be installed',
            });
            return;
          }

          final actor = await _resolveVerifiedClaimsOrWrite(
            request,
            response,
            authGuard,
          );
          if (actor == null) return;

          final dataAccuracyMethod = request.method;
          final dataAccuracyRoles = dataAccuracyMethod == 'GET'
              ? kFfDataAccuracyAdminReadRoles
              : kFfDataAccuracyAdminWriteRoles;
          if (!_callerHasAnyRole(actor, dataAccuracyRoles)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message': 'admin role claim required',
              'required_roles': dataAccuracyRoles.toList(),
            });
            return;
          }

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request, allowEmpty: true);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          final idempotencyKey =
              (request.headers.value('Idempotency-Key') ?? '').trim();
          if (dataAccuracyMethod != 'GET' && idempotencyKey.isEmpty) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'idempotency_key_missing',
              'message': 'Idempotency-Key header is required',
            });
            return;
          }
          if (idempotencyKey.length > 200) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'idempotency_key_too_long',
              'message':
                  'Idempotency-Key header must be 200 characters or fewer',
            });
            return;
          }

          try {
            await _routeDataAccuracyAdmin(
              request: request,
              response: response,
              path: path,
              gateway: dataAccuracyAdminGateway,
              actorUserId: actor.userId,
              body: body,
              idempotencyKey: idempotencyKey,
              idempotencyStore: adminRequestIdempotencyStore,
            );
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            if (error is _AdminInputError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            if (error is DataAccuracyAdminGatewayValidationError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            if (error is AdminIdempotencyKeyConflict) {
              _writeJson(response, 409, <String, Object?>{
                'error': 'idempotency_key_conflict',
                'message': error.message,
              });
              return;
            }
            _logProxyUnhandled(
              surface: 'data_accuracy_admin',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'data_accuracy_admin_unavailable',
              'message':
                  'data accuracy admin operation is unavailable; please retry',
            });
          }
          return;
        }

        if (_isAdminVendorApplicabilityOperation(path, request.method)) {
          if (vendorApplicabilityGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'vendor_applicability_not_configured',
              'message':
                  'route requires a VendorApplicabilityProxyGateway to be installed',
            });
            return;
          }

          final actor = await _resolveVerifiedClaimsOrWrite(
            request,
            response,
            authGuard,
          );
          if (actor == null) return;
          if (!_callerHasAnyRole(actor, kFfVendorApplicabilityAdminRoles)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message': 'admin vendor-applicability requires super_admin role',
              'required_roles': kFfVendorApplicabilityAdminRoles.toList(),
            });
            return;
          }

          final method = request.method;
          String? idempotencyKey;
          if (method != 'GET') {
            idempotencyKey = request.headers.value('Idempotency-Key')?.trim();
            if (idempotencyKey == null || idempotencyKey.isEmpty) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'idempotency_key_missing',
                'message': 'Idempotency-Key header is required',
              });
              return;
            }
            if (idempotencyKey.length > 200) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'idempotency_key_too_long',
                'message':
                    'Idempotency-Key header must be 200 characters or fewer',
              });
              return;
            }
          }

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request, allowEmpty: true);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          String resolvedActorUserId = actor.userId;
          if (method != 'GET') {
            if (integrationAdminActorResolver == null) {
              _writeJson(response, 503, <String, Object?>{
                'error': 'vendor_applicability_actor_resolver_not_configured',
                'message':
                    'route requires an IntegrationAdminActorResolver to be installed',
              });
              return;
            }
            final firebaseUidLookup = actor.firebaseUid ?? actor.userId;
            try {
              final resolved = await integrationAdminActorResolver
                  .resolveActorUserId(
                    firebaseUid: firebaseUidLookup,
                    adminReason:
                        'admin.vendor_applicability.${request.method}:'
                        '$firebaseUidLookup:resolve_actor',
                  );
              if (resolved == null) {
                _writeJson(response, 403, <String, Object?>{
                  'error': 'actor_user_not_resolvable',
                  'message':
                      'verified Firebase user has no matching Postgres users row '
                      '(audit attribution requires a UUID-shaped actor)',
                });
                return;
              }
              resolvedActorUserId = resolved;
            } on Exception catch (_) {
              // B10.1 carry-forward typed per A3.4 audit (was bare catch at
              // master line 14109 post-A3.4). Actor resolver round-trips
              // through Postgres + auth claim verification; throw surface
              // is `PgException` / `TimeoutException` / `IOException` /
              // JWT/claim Exception subtypes. Narrowed to `Exception` so
              // genuine `Error`s (assertion failures, OOM, type errors)
              // keep propagating to `runZonedGuarded` per addendum C4.
              _writeJson(response, 503, <String, Object?>{
                'error': 'vendor_applicability_actor_resolve_failed',
                'message': 'actor resolution is unavailable; please retry',
              });
              return;
            }
          }

          try {
            await _routeVendorApplicabilityAdmin(
              request: request,
              response: response,
              path: path,
              gateway: vendorApplicabilityGateway,
              actorUserId: resolvedActorUserId,
              body: body,
              idempotencyKey: idempotencyKey ?? '',
              idempotencyStore: adminRequestIdempotencyStore,
            );
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            if (error is _AdminInputError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            if (error is VendorApplicabilityGatewayValidationError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            if (error is AdminIdempotencyKeyConflict) {
              _writeJson(response, 409, <String, Object?>{
                'error': 'idempotency_key_conflict',
                'message': error.message,
              });
              return;
            }
            _logProxyUnhandled(
              surface: 'vendor_applicability_admin',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'vendor_applicability_unavailable',
              'message':
                  'vendor applicability operation is unavailable; please retry',
            });
          }
          return;
        }

        if (_isAdminCorpusOperation(path, request.method)) {
          if (corpusAdminGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'corpus_admin_not_configured',
              'message':
                  'route requires a CorpusAdminProxyGateway to be installed',
            });
            return;
          }

          final actor = await _resolveVerifiedClaimsOrWrite(
            request,
            response,
            authGuard,
          );
          if (actor == null) return;

          final corpusMethod = request.method;
          final corpusRoles = corpusMethod == 'GET'
              ? kFfCorpusAdminReadRoles
              : kFfCorpusAdminWriteRoles;
          if (!_callerHasAnyRole(actor, corpusRoles)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message': 'admin role claim required',
              'required_roles': corpusRoles.toList(),
            });
            return;
          }

          // Mutating routes require an Idempotency-Key header so retries
          // collapse to one ledger row instead of stamping a duplicate.
          // GETs are pure reads; the header is optional there.
          String? idempotencyKey;
          if (corpusMethod != 'GET') {
            idempotencyKey = request.headers.value('Idempotency-Key')?.trim();
            if (idempotencyKey == null || idempotencyKey.isEmpty) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'missing_idempotency_key',
                'message': 'Idempotency-Key header is required',
              });
              return;
            }
          }

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request, allowEmpty: true);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          try {
            await _routeCorpusAdmin(
              request: request,
              response: response,
              path: path,
              gateway: corpusAdminGateway,
              actorUserId: actor.userId,
              idempotencyKey: idempotencyKey ?? '',
              body: body,
            );
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            if (error is _AdminInputError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            if (error is CorpusAdminGatewayValidationError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            _logProxyUnhandled(
              surface: 'corpus_admin',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'corpus_admin_unavailable',
              'message': 'corpus admin operation is unavailable; please retry',
            });
          }
          return;
        }

        // Phase 11A.3b — Graphify candidate review routes. Same role-gate
        // posture as the corpus admin block above (GET admits read roles,
        // POST stays super_admin only) and the same Idempotency-Key dance
        // on writes so retries collapse to a single ledger row.
        if (_isGraphCandidatesOperation(path, request.method)) {
          if (graphCandidatesGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'graph_candidates_not_configured',
              'message':
                  'Graphify candidates feature is paused during the AI freeze. Will return when phases 11b / 11A.3.x are unpaused. See PROJECT_TRACKER.md.',
            });
            return;
          }

          final actor = await _resolveVerifiedClaimsOrWrite(
            request,
            response,
            authGuard,
          );
          if (actor == null) return;

          final graphMethod = request.method;
          final graphRoles = graphMethod == 'GET'
              ? kFfCorpusAdminReadRoles
              : kFfCorpusAdminWriteRoles;
          if (!_callerHasAnyRole(actor, graphRoles)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message': 'admin role claim required',
              'required_roles': graphRoles.toList(),
            });
            return;
          }

          String? idempotencyKey;
          if (graphMethod != 'GET') {
            idempotencyKey = request.headers.value('Idempotency-Key')?.trim();
            if (idempotencyKey == null || idempotencyKey.isEmpty) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'missing_idempotency_key',
                'message': 'Idempotency-Key header is required',
              });
              return;
            }
          }

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request, allowEmpty: true);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          try {
            await _routeGraphCandidates(
              request: request,
              response: response,
              path: path,
              gateway: graphCandidatesGateway,
              actorUserId: actor.userId,
              idempotencyKey: idempotencyKey ?? '',
              body: body,
            );
          } catch (error) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            if (error is _AdminInputError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            if (error is GraphCandidatesGatewayValidationError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            _writeJson(response, 503, <String, Object?>{
              'error': 'graph_candidates_unavailable',
              'message':
                  'Graphify candidates feature is paused during the AI freeze. Will return when phases 11b / 11A.3.x are unpaused. See PROJECT_TRACKER.md.',
            });
          }
          return;
        }

        // Phase 11A.3b — AGE rebuild route. Role gate + Idempotency-Key
        // are still enforced so the test contract can verify the gating
        // is wired even though the actual rebuild infrastructure ships
        // in 11A.3c. Returns 501 with a typed `not_implemented` error so
        // the screen surfaces the actionable banner instead of a 5xx.
        if (_isAgeRebuildOperation(path, request.method)) {
          final actor = await _resolveVerifiedClaimsOrWrite(
            request,
            response,
            authGuard,
          );
          if (actor == null) return;

          if (!_callerHasAnyRole(actor, kFfCorpusAdminWriteRoles)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message': 'admin role claim required',
              'required_roles': kFfCorpusAdminWriteRoles.toList(),
            });
            return;
          }

          final idempotencyKey = request.headers
              .value('Idempotency-Key')
              ?.trim();
          if (idempotencyKey == null || idempotencyKey.isEmpty) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_idempotency_key',
              'message': 'Idempotency-Key header is required',
            });
            return;
          }

          _writeJson(response, 501, <String, Object?>{
            'error': 'not_implemented',
            'message':
                'AGE rebuild ships in slice 11A.3c — '
                'corpus_pipeline_not_configured',
          });
          return;
        }

        // Phase 11A.7 — feature flags admin. Method-scoped role split:
        // GET admits `super_admin` + `ff_support`; POST is strictly
        // `super_admin`. Toggle POST requires an Idempotency-Key. Audit
        // attribution reuses the integrations actor resolver — F&F admins
        // live outside any operator's tenant scope, so the verified
        // Firebase UID resolves to a Postgres `users.user_id` UUID before
        // the gateway is touched.
        if (_isAdminFeatureFlagsOperation(path, request.method)) {
          if (featureFlagsAdminGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'feature_flags_admin_not_configured',
              'message':
                  'route requires a FeatureFlagsAdminProxyGateway to be installed',
            });
            return;
          }

          final actor = await _resolveVerifiedClaimsOrWrite(
            request,
            response,
            authGuard,
          );
          if (actor == null) return;

          final flagsMethod = request.method;
          final flagsRoles = flagsMethod == 'GET'
              ? kFfFeatureFlagsAdminReadRoles
              : kFfFeatureFlagsAdminWriteRoles;
          if (!_callerHasAnyRole(actor, flagsRoles)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message': 'admin role claim required',
              'required_roles': flagsRoles.toList(),
            });
            return;
          }

          String? idempotencyKey;
          if (flagsMethod != 'GET') {
            idempotencyKey = request.headers.value('Idempotency-Key')?.trim();
            if (idempotencyKey == null || idempotencyKey.isEmpty) {
              // HARD-D — error code matches
              // `docs/contracts/hardening_feature_flag_idempotency_contract.md`.
              // Other admin POST handlers in this file still emit
              // `missing_idempotency_key` for backward compatibility with
              // their own tests; aligning them is out of scope here.
              _writeJson(response, 400, <String, Object?>{
                'error': 'idempotency_key_missing',
                'message': 'Idempotency-Key header is required',
              });
              return;
            }
            if (idempotencyKey.length > 200) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'idempotency_key_too_long',
                'message':
                    'Idempotency-Key header must be 200 characters or fewer',
              });
              return;
            }
          }

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request, allowEmpty: true);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          // Audit attribution gate. The same Firebase UID → users.user_id
          // resolver from the 11A.4 integrations dispatch backs the
          // 11A.7 toggle audit row. Reads (GET) skip resolver lookup —
          // listing flags is non-mutating.
          String? resolvedActorUserId;
          if (flagsMethod != 'GET') {
            if (integrationAdminActorResolver == null) {
              _writeJson(response, 503, <String, Object?>{
                'error': 'feature_flags_actor_resolver_not_configured',
                'message':
                    'route requires an IntegrationAdminActorResolver to be installed',
              });
              return;
            }
            final firebaseUidLookup = actor.firebaseUid ?? actor.userId;
            try {
              resolvedActorUserId = await integrationAdminActorResolver
                  .resolveActorUserId(
                    firebaseUid: firebaseUidLookup,
                    adminReason:
                        'admin.feature_flags.${request.method}:'
                        '$firebaseUidLookup:resolve_actor',
                  );
            } on Exception catch (_) {
              // A3.4: same `integrationAdminActorResolver` surface (see
              // above); `Error`s propagate per C4.
              _writeJson(response, 503, <String, Object?>{
                'error': 'feature_flags_actor_resolve_failed',
                'message': 'actor resolution is unavailable; please retry',
              });
              return;
            }
            if (resolvedActorUserId == null) {
              _writeJson(response, 403, <String, Object?>{
                'error': 'actor_user_not_resolvable',
                'message':
                    'verified Firebase user has no matching Postgres users row '
                    '(audit attribution requires a UUID-shaped actor)',
              });
              return;
            }
          }

          try {
            await _routeFeatureFlagsAdmin(
              request: request,
              response: response,
              path: path,
              gateway: featureFlagsAdminGateway,
              actorUserId: resolvedActorUserId ?? actor.userId,
              idempotencyKey: idempotencyKey ?? '',
              body: body,
              idempotencyStore: adminRequestIdempotencyStore,
            );
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            if (error is _AdminInputError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            if (error is FeatureFlagsAdminGatewayValidationError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            if (error is AdminIdempotencyKeyConflict) {
              _writeJson(response, 409, <String, Object?>{
                'error': 'idempotency_key_conflict',
                'message': error.message,
              });
              return;
            }
            _logProxyUnhandled(
              surface: 'feature_flags_admin',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'feature_flags_admin_unavailable',
              'message':
                  'feature flags admin operation is unavailable; please retry',
            });
          }
          return;
        }

        // Phase 11A.5 — debug console request-log routes. Read-only
        // support/admin surface; `ff_support` can inspect sanitized
        // request metadata, while full content only leaves the proxy
        // for a super_admin caller and an opted-in operator.
        if (_isAdminDebugOperation(path, request.method)) {
          if (debugConsoleAdminGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'debug_console_admin_not_configured',
              'message':
                  'route requires a DebugConsoleAdminProxyGateway to be installed',
            });
            return;
          }

          final actor = await _resolveVerifiedClaimsOrWrite(
            request,
            response,
            authGuard,
          );
          if (actor == null) return;

          if (!_callerHasAnyRole(actor, kFfDebugConsoleAdminReadRoles)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message': 'admin role claim required',
              'required_roles': kFfDebugConsoleAdminReadRoles.toList(),
            });
            return;
          }

          try {
            await _routeDebugConsoleAdmin(
              request: request,
              response: response,
              path: path,
              gateway: debugConsoleAdminGateway,
              actorUserId: actor.userId,
              includeFullContent: _callerHasAnyRole(
                actor,
                kFfDebugConsoleFullContentRoles,
              ),
            );
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            if (error is _AdminInputError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            _logProxyUnhandled(
              surface: 'debug_console_admin',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'debug_console_admin_unavailable',
              'message': 'debug console operation is unavailable; please retry',
            });
          }
          return;
        }

        // Phase 11A.6 — observability aggregate route. The dashboard is
        // manual-run in the client; the proxy still clamps the expensive
        // cost rows and exposes empty lists for producers that have not
        // emitted rows yet.
        if (_isAdminObservabilityOperation(path, request.method)) {
          if (observabilityAdminGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'observability_admin_not_configured',
              'message':
                  'route requires an ObservabilityAdminProxyGateway to be installed',
            });
            return;
          }

          final actor = await _resolveVerifiedClaimsOrWrite(
            request,
            response,
            authGuard,
          );
          if (actor == null) return;

          if (!_callerHasAnyRole(actor, kFfObservabilityAdminReadRoles)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message': 'admin role claim required',
              'required_roles': kFfObservabilityAdminReadRoles.toList(),
            });
            return;
          }

          try {
            await _routeObservabilityAdmin(
              request: request,
              response: response,
              path: path,
              gateway: observabilityAdminGateway,
              actorUserId: actor.userId,
            );
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            if (error is _AdminInputError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            _logProxyUnhandled(
              surface: 'observability_admin',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'observability_admin_unavailable',
              'message': 'observability operation is unavailable; please retry',
            });
          }
          return;
        }

        if (_isAdminOperatorOrLocationOperation(path, request.method)) {
          if (operatorLocationAdminGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'operator_location_admin_not_configured',
              'message':
                  'route requires an OperatorLocationAdminProxyGateway to be installed',
            });
            return;
          }

          final actor = await _resolveVerifiedClaimsOrWrite(
            request,
            response,
            authGuard,
          );
          if (actor == null) return;

          if (!_isFfOperatorLocationAdminCaller(actor)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message': 'admin role claim required',
              'required_roles': kFfOperatorLocationAdminRoles.toList(),
            });
            return;
          }

          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request, allowEmpty: true);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }

          // HARD-H — required Idempotency-Key on POST/PATCH/DELETE so
          // retries collapse to one mutation + one audit row at the proxy.
          // The caller-supplied `admin_reason` is the audit rationale; when a
          // store is wired, `_runAdminIdempotent` handles reserve→complete
          // against `admin_request_idempotency`.
          String operatorLocationIdempotencyKey = '';
          String? operatorLocationAdminReason;
          if (request.method != 'GET') {
            operatorLocationIdempotencyKey =
                (request.headers.value('Idempotency-Key') ?? '').trim();
            if (operatorLocationIdempotencyKey.isEmpty) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'missing_idempotency_key',
                'message': 'Idempotency-Key header is required',
              });
              return;
            }
            if (operatorLocationIdempotencyKey.length > 200) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'idempotency_key_too_long',
                'message':
                    'Idempotency-Key header must be 200 characters or fewer',
              });
              return;
            }
            operatorLocationAdminReason = _nonBlankString(body['admin_reason']);
            if (operatorLocationAdminReason == null) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'missing_admin_reason',
                'message':
                    'admin_reason is required on every admin operator/location write',
              });
              return;
            }
          }
          try {
            await _routeOperatorLocationAdmin(
              request: request,
              response: response,
              path: path,
              gateway: operatorLocationAdminGateway,
              actorUserId: actor.userId,
              body: body,
              idempotencyKey: operatorLocationIdempotencyKey,
              adminReason: operatorLocationAdminReason,
              idempotencyStore: adminRequestIdempotencyStore,
            );
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            if (error is _AdminInputError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            if (error is AuthOperationRejected) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
                if (error.details.isNotEmpty) ...error.details,
              });
              return;
            }
            if (error is OperatorLocationAdminRejected) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            if (error is AdminIdempotencyKeyConflict) {
              _writeJson(response, 409, <String, Object?>{
                'error': 'idempotency_key_conflict',
                'message': error.message,
              });
              return;
            }
            _logProxyUnhandled(
              surface: 'operator_location_admin',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'operator_location_admin_unavailable',
              'message':
                  'operator/location admin operation is unavailable; please retry',
            });
          }
          return;
        }

        if (path == operatorVendorApplicabilityPath &&
            request.method == 'GET') {
          if (vendorApplicabilityGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'vendor_applicability_not_configured',
              'message':
                  'route requires a VendorApplicabilityProxyGateway to be installed',
            });
            return;
          }
          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;
          if (scope.operatorId.isEmpty || scope.locationId.isEmpty) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message':
                  'operator vendor-applicability read requires tenant scope',
            });
            return;
          }
          final settingKind = _nonBlankString(
            request.uri.queryParameters['setting_kind'],
          );
          if (settingKind == null) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_setting_kind',
              'message': 'setting_kind query parameter is required',
            });
            return;
          }
          try {
            final rows = await vendorApplicabilityGateway.listForOperator(
              scope: scope,
              settingKind: settingKind,
              settingKey: _nonBlankString(
                request.uri.queryParameters['setting_key'],
              ),
            );
            _writeJson(response, 200, <String, Object?>{'rows': rows});
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            if (error is VendorApplicabilityGatewayValidationError) {
              _writeJson(response, error.statusCode, <String, Object?>{
                'error': error.code,
                'message': error.message,
              });
              return;
            }
            _logProxyUnhandled(
              surface: 'vendor_applicability_operator',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'vendor_applicability_unavailable',
              'message':
                  'vendor applicability lookup is unavailable; please retry',
            });
          }
          return;
        }

        // Fix #4 / S1 — operator-web location-scoped business-timing
        // resolution route. GET only, read-only, no Idempotency-Key.
        // Same operator owner role gate as the write router,
        // plus an explicit tenant scope-mismatch reject (mirrors the
        // auth-location-integrations route): the path locationId must
        // equal the signed-in location scope. operatorId is ALWAYS the
        // JWT operator — never the URL.
        if (request.method == 'GET' &&
            isOperatorLocationBusinessTimingResolutionPath(path)) {
          if (operatorWriteRouter == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'operator_write_router_not_configured',
              'message':
                  'route requires an OperatorWriteRouter to be installed',
            });
            return;
          }
          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;
          if (!scope.roles.any(kOperatorWriteRoles.contains)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'forbidden',
              'message': 'operator owner role is required',
              'required_roles': kOperatorWriteRoles.toList(),
            });
            return;
          }
          final locationId = operatorLocationBusinessTimingResolutionIdOf(
            path,
          )!;
          if (scope.operatorId.isEmpty || scope.locationId.isEmpty) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message':
                  'business-timing resolution requires a tenant-scoped token',
            });
            return;
          }
          if (locationId != scope.locationId) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'location_scope_mismatch',
              'message':
                  'business-timing resolution can only be read for the '
                  'signed-in location',
            });
            return;
          }
          final businessDateParam = _nonBlankString(
            request.uri.queryParameters['business_date'],
          );
          if (businessDateParam != null &&
              !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(businessDateParam)) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'invalid_business_date',
              'message':
                  'business_date must be an ISO calendar date (YYYY-MM-DD)',
            });
            return;
          }
          try {
            final result = await operatorWriteRouter
                .handleBusinessTimingResolution(
                  operatorId: scope.operatorId,
                  locationId: locationId,
                  businessDate: businessDateParam,
                );
            // Stamp the verified scope on the response so the gateway
            // cannot leak another tenant's identifiers (defense in
            // depth alongside RLS + the repository SET LOCAL).
            final outgoing = <String, Object?>{
              ...result.body,
              if (result.statusCode == 200) ...<String, Object?>{
                'operatorId': scope.operatorId,
                'locationId': locationId,
              },
            };
            _writeJson(response, result.statusCode, outgoing);
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'operator_business_timing_resolution',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'operator_business_timing_resolution_unavailable',
              'message':
                  'business-timing resolution is unavailable; please retry',
            });
          }
          return;
        }

        // Phase 11W.7 / Wave A2 - operator-scoped account + business-
        // timing write router. Five operator-write routes that all
        // share auth (operator owner) + Idempotency-Key.
        if (OperatorWriteRouter.matches(path, request.method)) {
          if (operatorWriteRouter == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'operator_write_router_not_configured',
              'message':
                  'route requires an OperatorWriteRouter to be installed',
            });
            return;
          }
          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;
          if (!scope.roles.any(kOperatorWriteRoles.contains)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'forbidden',
              'message': 'operator owner role is required',
              'required_roles': kOperatorWriteRoles.toList(),
            });
            return;
          }
          // 11W.7 ops-debt - GET routes are read-only. Skip the
          // Idempotency-Key check + body parse so the GET surface
          // does not require a synthetic header from clients.
          final isReadOnly = OperatorWriteRouter.isReadOnly(
            path,
            request.method,
          );
          String operatorIdemKey;
          Map<String, Object?> requestBody;
          if (isReadOnly) {
            operatorIdemKey = '';
            requestBody = const <String, Object?>{};
          } else {
            final headerKey = request.headers.value('Idempotency-Key')?.trim();
            if (headerKey == null || headerKey.isEmpty) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'idempotency_key_missing',
                'message': 'Idempotency-Key header is required',
              });
              return;
            }
            if (headerKey.length > 200) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'idempotency_key_too_long',
                'message':
                    'Idempotency-Key header must be 200 characters or fewer',
              });
              return;
            }
            final bodyResult = await readOperatorJsonBody(request);
            if (bodyResult.errorStatus != null) {
              _writeJson(
                response,
                bodyResult.errorStatus!,
                bodyResult.errorBody!,
              );
              return;
            }
            operatorIdemKey = headerKey;
            requestBody = bodyResult.body!;
          }
          try {
            final result = await operatorWriteRouter.handle(
              method: request.method,
              path: path,
              operatorId: scope.operatorId,
              actorUserId: scope.userId,
              actorKind: scope.actorKind,
              idempotencyKey: operatorIdemKey,
              body: requestBody,
            );
            _writeJson(response, result.statusCode, result.body);
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'operator_write_router',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'operator_write_unavailable',
              'message': 'operator write is unavailable; please retry',
            });
          }
          return;
        }

        // Admin audit-integrity badge — admin/cross-tenant
        // audit-chain-anchor read route. GET only, read-only, no
        // Idempotency-Key. operatorId comes from the URL (the
        // established admin cross-tenant convention) — gated to
        // super_admin / ff_support ONLY, the SAME read gate as the
        // admin business-timing routes (`kAdminAuditChainAnchorRoles`
        // mirrors `kAdminBusinessTimingRoles`). The gateway reaches
        // the sanctioned `runAsSystem` admin bypass server-side; an
        // operator-scoped token can NEVER reach this branch (operator
        // routes never match `/v1/admin/*`). The body shape +
        // classifier are the SAME as the operator route so the admin
        // badge cannot drift from the operator-web badge.
        if (AdminAuditChainAnchorsRouter.matches(path, request.method)) {
          if (adminAuditChainAnchorsGateway == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'admin_audit_chain_anchors_not_configured',
              'message':
                  'admin audit chain anchors gateway is not installed; '
                  'please retry',
            });
            return;
          }
          final actor = await _resolveVerifiedClaimsOrWrite(
            request,
            response,
            authGuard,
          );
          if (actor == null) return;
          if (!actor.roles.any(kAdminAuditChainAnchorRoles.contains)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message':
                  'admin audit chain anchor read requires super_admin or '
                  'ff_support role',
              'required_roles': kAdminAuditChainAnchorRoles.toList(),
            });
            return;
          }
          final operatorId = adminAuditChainAnchorsOperatorIdOf(path)!;
          try {
            final router = AdminAuditChainAnchorsRouter(
              gateway: adminAuditChainAnchorsGateway,
              now: clock,
            );
            final result = await router.handle(operatorId: operatorId);
            _writeJson(response, result.statusCode, result.body);
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'admin_audit_chain_anchors',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'admin_audit_chain_anchors_unavailable',
              'message':
                  'admin audit chain anchor lookup is unavailable; '
                  'please retry',
            });
          }
          return;
        }

        // Fix #4 / S2 — admin/cross-tenant business-timing resolution
        // route (the admin analogue of S1's operator-web
        // `/v1/operator/locations/:locationId/business-timing-resolution`).
        // GET only, read-only, no Idempotency-Key. operatorId AND
        // locationId come from the URL (the established admin
        // cross-tenant convention) — gated to super_admin / ff_support
        // ONLY, the same read gate as the existing admin
        // business-timing list route. The gateway reaches the
        // sanctioned `runAsSystem` admin bypass; an operator-scoped
        // token can NEVER reach this branch (operator routes never
        // match `/v1/admin/*`). Checked before the admin profile
        // router so the disjoint `/locations/.../resolution` path is
        // never mis-parsed as a profile path.
        if (request.method == 'GET' &&
            isAdminBusinessTimingResolutionPath(path)) {
          if (adminBusinessTimingRouter == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'admin_business_timing_router_not_configured',
              'message':
                  'route requires an AdminBusinessTimingRouter to be installed',
            });
            return;
          }
          final actor = await _resolveVerifiedClaimsOrWrite(
            request,
            response,
            authGuard,
          );
          if (actor == null) return;
          if (!actor.roles.any(kAdminBusinessTimingRoles.contains)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message':
                  'admin business-timing read requires super_admin or '
                  'ff_support role',
              'required_roles': kAdminBusinessTimingRoles.toList(),
            });
            return;
          }
          final scope = adminBusinessTimingResolutionScopeOf(path)!;
          final businessDateParam = _nonBlankString(
            request.uri.queryParameters['business_date'],
          );
          if (businessDateParam != null &&
              !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(businessDateParam)) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'invalid_business_date',
              'message':
                  'business_date must be an ISO calendar date (YYYY-MM-DD)',
            });
            return;
          }
          try {
            final result = await adminBusinessTimingRouter.handleResolution(
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              businessDate: businessDateParam,
            );
            // Stamp the URL-derived scope on a 200 so the response
            // cannot be confused with another operator's chain
            // (defense in depth alongside the operator filter baked
            // into the canonical SQL itself).
            final outgoing = <String, Object?>{
              ...result.body,
              if (result.statusCode == 200) ...<String, Object?>{
                'operatorId': scope.operatorId,
                'locationId': scope.locationId,
              },
            };
            _writeJson(response, result.statusCode, outgoing);
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'admin_business_timing_resolution',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'admin_business_timing_resolution_unavailable',
              'message':
                  'admin business-timing resolution is unavailable; '
                  'please retry',
            });
          }
          return;
        }

        // Doc 1 timing web/admin live parity (2026-05-08) - admin-side
        // override routes for business-timing profiles. GET admits
        // super_admin + ff_support; writes are super_admin-only and
        // require `admin_reason` in the body.
        if (AdminBusinessTimingRouter.matches(path, request.method)) {
          if (adminBusinessTimingRouter == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'admin_business_timing_router_not_configured',
              'message':
                  'route requires an AdminBusinessTimingRouter to be installed',
            });
            return;
          }
          final actor = await _resolveVerifiedClaimsOrWrite(
            request,
            response,
            authGuard,
          );
          if (actor == null) return;
          final isReadOnly = AdminBusinessTimingRouter.isReadOnly(
            path,
            request.method,
          );
          final adminBusinessTimingRoles = isReadOnly
              ? kAdminBusinessTimingRoles
              : const <String>{'super_admin'};
          if (!actor.roles.any(adminBusinessTimingRoles.contains)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'permission_denied',
              'message': isReadOnly
                  ? 'admin business-timing read requires super_admin or '
                        'ff_support role'
                  : 'admin business-timing write requires super_admin role',
              'required_roles': adminBusinessTimingRoles.toList(),
            });
            return;
          }
          String adminIdempotencyKey;
          Map<String, Object?> requestBody;
          if (isReadOnly) {
            adminIdempotencyKey = '';
            requestBody = const <String, Object?>{};
          } else {
            final headerKey = request.headers.value('Idempotency-Key')?.trim();
            if (headerKey == null || headerKey.isEmpty) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'idempotency_key_missing',
                'message': 'Idempotency-Key header is required',
              });
              return;
            }
            if (headerKey.length > 200) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'idempotency_key_too_long',
                'message':
                    'Idempotency-Key header must be 200 characters or fewer',
              });
              return;
            }
            final bodyResult = await readOperatorJsonBody(request);
            if (bodyResult.errorStatus != null) {
              _writeJson(
                response,
                bodyResult.errorStatus!,
                bodyResult.errorBody!,
              );
              return;
            }
            adminIdempotencyKey = headerKey;
            requestBody = bodyResult.body!;
          }
          try {
            final result = await adminBusinessTimingRouter.handle(
              method: request.method,
              path: path,
              actorUserId: actor.userId,
              actorKind: actor.actorKind,
              idempotencyKey: adminIdempotencyKey,
              body: requestBody,
            );
            _writeJson(response, result.statusCode, result.body);
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'admin_business_timing_router',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'admin_business_timing_unavailable',
              'message':
                  'admin business-timing override is unavailable; please retry',
            });
          }
          return;
        }

        // Wave W2.D - operator-scoped read of `connector_backfill_jobs`.
        // Mirrors the operator-web Vendor Connections progress widget.
        // Open to any operator-web role; per-tenant RLS is enforced by
        // the gateway via SET LOCAL.
        if (ConnectorBackfillJobsRouter.matches(path, request.method)) {
          if (connectorBackfillJobsRouter == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'connector_backfill_jobs_router_not_configured',
              'message':
                  'route requires a ConnectorBackfillJobsRouter to be installed',
            });
            return;
          }
          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;
          if (!scope.roles.any(
            kOperatorConnectorBackfillJobsReadRoles.contains,
          )) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'forbidden',
              'message':
                  'an operator role with vendor-connections access is required',
              'required_roles': kOperatorConnectorBackfillJobsReadRoles
                  .toList(),
            });
            return;
          }
          try {
            final result = await connectorBackfillJobsRouter.handle(
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              actorUserId: scope.userId,
              queryParameters: request.uri.queryParameters,
            );
            _writeJson(response, result.statusCode, result.body);
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'connector_backfill_jobs',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'connector_backfill_jobs_unavailable',
              'message':
                  'connector backfill progress is unavailable; please retry',
            });
          }
          return;
        }

        // Phase 11W.8 follow-up - operator-scoped read of recently-
        // available vendors (mirrors the vendor_now_available email
        // fan-out). Open to any operator-web role; per-tenant RLS is
        // enforced by the gateway via SET LOCAL.
        if (OperatorVendorLifecycleRecentlyAvailableRouter.matches(
          path,
          request.method,
        )) {
          if (vendorLifecycleRecentlyAvailableRouter == null) {
            _writeJson(response, 503, <String, Object?>{
              'error':
                  'vendor_lifecycle_recently_available_router_not_configured',
              'message':
                  'route requires a OperatorVendorLifecycleRecentlyAvailableRouter to be installed',
            });
            return;
          }
          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;
          if (!scope.roles.any(
            kOperatorVendorLifecycleRecentlyAvailableReadRoles.contains,
          )) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'forbidden',
              'message':
                  'an operator role with vendor-connections access is required',
              'required_roles':
                  kOperatorVendorLifecycleRecentlyAvailableReadRoles.toList(),
            });
            return;
          }
          try {
            final result = await vendorLifecycleRecentlyAvailableRouter.handle(
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              actorUserId: scope.userId,
              queryParameters: request.uri.queryParameters,
            );
            _writeJson(response, result.statusCode, result.body);
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'vendor_lifecycle_recently_available',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'vendor_lifecycle_recently_available_unavailable',
              'message':
                  'recently available vendors are unavailable; please retry',
            });
          }
          return;
        }

        // Phase 8 W2.B - operator-scoped notification preferences
        // routes. Per-actor (the JWT subject's own preferences). PUT /
        // DELETE require Idempotency-Key. GET requires no key.
        if (NotificationPreferencesRouter.matches(path, request.method)) {
          if (notificationPreferencesRouter == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'notification_preferences_router_not_configured',
              'message':
                  'route requires a NotificationPreferencesRouter to be installed',
            });
            return;
          }
          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;
          String? notifIdemKey;
          if (request.method == 'PUT' || request.method == 'DELETE') {
            notifIdemKey = request.headers.value('Idempotency-Key')?.trim();
            if (notifIdemKey == null || notifIdemKey.isEmpty) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'idempotency_key_missing',
                'message': 'Idempotency-Key header is required',
              });
              return;
            }
            if (notifIdemKey.length > 200) {
              _writeJson(response, 400, <String, Object?>{
                'error': 'idempotency_key_too_long',
                'message':
                    'Idempotency-Key header must be 200 characters or fewer',
              });
              return;
            }
          }
          Map<String, Object?>? notifBody;
          if (request.method == 'PUT') {
            final bodyResult = await readOperatorJsonBody(request);
            if (bodyResult.errorStatus != null) {
              _writeJson(
                response,
                bodyResult.errorStatus!,
                bodyResult.errorBody!,
              );
              return;
            }
            notifBody = bodyResult.body;
          }
          try {
            final result = await notificationPreferencesRouter.handle(
              method: request.method,
              path: path,
              query: request.uri.queryParameters,
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              actorUserId: scope.userId,
              idempotencyKey: notifIdemKey,
              body: notifBody,
            );
            _writeJson(response, result.statusCode, result.body);
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'notification_preferences_router',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'notification_preferences_unavailable',
              'message':
                  'notification preferences write is unavailable; please retry',
            });
          }
          return;
        }

        // Phase 8 W5.A.1 - operator-scoped wage role rows write router.
        // Dedicated POST/DELETE seam that mirrors the OperatorWriteRouter
        // discipline (operator owner role, Idempotency-Key, body
        // validation) but lives in its own router so the wage editor's
        // proxy contract stays narrow and op-web W3.D parity can call it
        // directly.
        if (WageRoleRowsRouter.matches(path, request.method)) {
          if (wageRoleRowsRouter == null) {
            _writeJson(response, 503, <String, Object?>{
              'error': 'wage_role_rows_router_not_configured',
              'message': 'route requires a WageRoleRowsRouter to be installed',
            });
            return;
          }
          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;
          if (!scope.roles.any(kOperatorWriteRoles.contains)) {
            _writeJson(response, 403, <String, Object?>{
              'error': 'forbidden',
              'message': 'operator owner role is required',
              'required_roles': kOperatorWriteRoles.toList(),
            });
            return;
          }
          final wageIdemKey = request.headers.value('Idempotency-Key')?.trim();
          if (wageIdemKey == null || wageIdemKey.isEmpty) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'idempotency_key_missing',
              'message': 'Idempotency-Key header is required',
            });
            return;
          }
          if (wageIdemKey.length > 200) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'idempotency_key_too_long',
              'message':
                  'Idempotency-Key header must be 200 characters or fewer',
            });
            return;
          }
          Map<String, Object?> wageBody = const <String, Object?>{};
          if (request.method == 'POST') {
            final bodyResult = await readOperatorJsonBody(request);
            if (bodyResult.errorStatus != null) {
              _writeJson(
                response,
                bodyResult.errorStatus!,
                bodyResult.errorBody!,
              );
              return;
            }
            wageBody = bodyResult.body!;
          }
          try {
            final result = await wageRoleRowsRouter.handle(
              method: request.method,
              path: path,
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              actorUserId: scope.userId,
              actorKind: scope.actorKind,
              idempotencyKey: wageIdemKey,
              body: wageBody,
            );
            _writeJson(response, result.statusCode, result.body);
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'wage_role_rows_router',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, <String, Object?>{
              'error': 'wage_role_rows_unavailable',
              'message': 'wage row write is unavailable; please retry',
            });
          }
          return;
        }

        // Slice A2 — POST /v1/advisor/retrieve. Corpus vector search for a
        // pre-computed 1024-dim query embedding. Read-only; no rerank (A3),
        // no answer generation (A4), no text→embedding (A2b). Handler lives
        // entirely in advisor_retrieve_route_group_part.dart.
        if (request.method == 'POST' && path == advisorRetrievePath) {
          if (corpusRetrievalService == null) {
            _writeJson(response, 503, const <String, Object?>{
              'error': 'corpus_retrieval_not_configured',
              'message':
                  'route requires a CorpusRetrievalService to be installed',
            });
            return;
          }
          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;
          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }
          try {
            await _handleAdvisorRetrieve(
              request: request,
              response: response,
              body: body,
              retrievalService: corpusRetrievalService,
              embeddingGateway: corpusQueryEmbeddingGateway,
              // HP #7: key stays in the call stack; never logged or returned.
              voyageApiKey: voyageApiKeyForRetrieval,
              // Slice A3 ? optional server-side rerank gateway + its key.
              // Null in tests/scaffolds ? vector-only order unchanged. HP #7:
              // the rerank key stays in the call stack, never logged/returned.
              rerankGateway: corpusRerankGateway,
              voyageRerankApiKey: voyageRerankApiKeyForRetrieval,
              // HP #9: meter the Voyage embedding spend by class. `scope` is
              // the resolved operator JWT (operator_id/location_id). The
              // guard + accounting store are the SAME handles the metered
              // LLM route uses (HP #8: no parallel stack); both are optional,
              // so tests/scaffolds that pass neither stay unmetered.
              operator: scope,
              usageGuard: usageGuard,
              accountingStore: accountingStore,
              clock: clock,
            );
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'advisor_retrieve',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, const <String, Object?>{
              'error': 'corpus_retrieval_unavailable',
              'message': 'corpus retrieval is unavailable; please retry',
            });
          }
          return;
        }

        // Slice A4.2b — POST /v1/advisor/answer. The ACTIVATING agentic answer
        // route: encryption-first (fail-closed) + recommendation-only engine +
        // encrypted conversation history + HP #9 metering. The handler lives
        // entirely in advisor_answer_route_group_part.dart; it resolves the
        // operator scope + reads the body here (mirroring the retrieve block)
        // and is then handed every optional binding (any missing one fails the
        // route closed inside the handler).
        if (request.method == 'POST' && path == advisorAnswerPath) {
          final scope = await _resolveOperatorContextOrWrite(
            request,
            response,
            authGuard,
          );
          if (scope == null) return;
          Map<String, Object?> body;
          try {
            body = await _readJsonBody(request);
          } on _MalformedJsonBodyError catch (error) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'malformed_json_body',
              'message': error.message,
            });
            return;
          }
          try {
            await _handleAdvisorAnswer(
              request: request,
              response: response,
              body: body,
              operator: scope,
              // Provider seam (A4.1) — pre-built tool-use gateway over the
              // shared http.Client + Anthropic key. HP #7: the key lives only
              // inside this fn, never logged or returned.
              completeFn: anthropicToolUseCompleteFnForAnswer,
              // Encryption-first seam (A4-ENC). HP #7: the CMK is resolved only
              // inside one encrypt call; absent either → fail closed.
              conversationCmkResolver: advisorConversationCmkResolver,
              conversationLogRepository: advisorConversationLogRepository,
              // retrieve_methodology dependencies (A4.2a) — REUSE the retrieve
              // route's bindings. Absent → the methodology tool is omitted and
              // the engine runs operational tools only (graceful degrade).
              retrievalService: corpusRetrievalService,
              embeddingGateway: corpusQueryEmbeddingGateway,
              voyageApiKey: voyageApiKeyForRetrieval,
              rerankGateway: corpusRerankGateway,
              voyageRerankApiKey: voyageRerankApiKeyForRetrieval,
              // Operational tools (A4.6). HP #4: bound to the verified caller
              // scope only.
              targetCycleRepository: advisorAnswerTargetCycleRepository,
              weeklyPlanSnapshotRepository:
                  advisorAnswerWeeklyPlanSnapshotRepository,
              shiftRecordsReadRepository:
                  advisorAnswerShiftRecordsReadRepository,
              // Metering (HP #9) — the SAME handles the smoke + retrieve routes
              // use (HP #8: no parallel stack); optional, so unmetered when
              // unwired.
              usageGuard: usageGuard,
              accountingStore: accountingStore,
              clock: clock,
            );
          } catch (error, stackTrace) {
            if (_maybeWriteDependencyTimeout(response, error)) return;
            _logProxyUnhandled(
              surface: 'advisor_answer',
              method: request.method,
              path: path,
              error: error,
              stackTrace: stackTrace,
            );
            _writeJson(response, 503, const <String, Object?>{
              'error': 'advisor_answer_unavailable',
              'message': 'advisor answer is unavailable; please retry',
            });
          }
          return;
        }

        _writeJson(response, 404, <String, Object?>{
          'error': 'not found',
          'method': request.method,
          'path': path,
        });
      } on DependencyTimeoutException catch (error) {
        // HARD-G observability: any inner catch that did NOT rewrite
        // the response with the timeout envelope rethrows so this
        // outer handler can write the contract-pinned shape.
        _writeDependencyTimeoutEnvelope(response, error);
      }
    } finally {
      await response.close();
    }
  });
}

bool _isFfOperatorLocationAdminCaller(ProxyJwtClaims actor) {
  return actor.roles.any(kFfOperatorLocationAdminRoles.contains);
}

bool _isAdminOperatorOrLocationPath(String path) {
  if (path == adminOperatorsPath || path.startsWith(adminOperatorsPrefix)) {
    return true;
  }
  if (path == adminLocationsPath || path.startsWith(adminLocationsPrefix)) {
    return true;
  }
  return false;
}

bool _isAdminOperatorOrLocationOperation(String path, String method) {
  if (AdminBusinessTimingRouter.matches(path, method)) return false;
  if (method == 'GET' && path == adminOperatorsPath) return true;
  if (method == 'POST' && path == adminOperatorsPath) return true;
  if (method == 'PATCH' && path.startsWith(adminOperatorsPrefix)) return true;
  if (method == 'POST' && path.startsWith(adminOperatorsPrefix)) return true;
  if (method == 'POST' && path == adminLocationsPath) return true;
  if (method == 'PATCH' && path.startsWith(adminLocationsPrefix)) return true;
  if (method == 'DELETE' && path.startsWith(adminLocationsPrefix)) return true;
  return false;
}

Future<void> _routeOperatorLocationAdmin({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required OperatorLocationAdminProxyGateway gateway,
  required String actorUserId,
  required Map<String, Object?> body,
  String idempotencyKey = '',
  String? adminReason,
  AdminRequestIdempotencyStore? idempotencyStore,
}) async {
  final method = request.method;
  final reasonPrefix = 'admin.operator_location.$method:$actorUserId';

  if (method == 'GET' && path == adminOperatorsPath) {
    final operators = await gateway.listOperatorsWithLocations(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:list',
    );
    _writeJson(response, 200, <String, Object?>{'operators': operators});
    return;
  }

  if (method == 'POST' && path == adminOperatorsPath) {
    final businessName = _requireBodyString(body, 'business_name');
    final ownerEmail = _requireBodyString(body, 'owner_email');
    final subscriptionTier = _requireBodyString(body, 'subscription_tier');
    final preferredCurrency = _requireBodyCurrency(body, 'preferred_currency');
    final adminEmail = _requireBodyString(body, 'admin_user_email');
    final primary = body['primary_location'];
    if (primary is! Map) {
      throw const _AdminInputError(
        statusCode: 400,
        code: 'missing_primary_location',
        message: 'primary_location object is required',
      );
    }
    final primaryMap = primary.cast<String, Object?>();
    final locationName = _requireBodyString(primaryMap, 'name');
    final locationTimezone = _requireBodyTimezone(primaryMap, 'timezone');
    final rolloverHour = _requireBodyRolloverHour(
      primaryMap,
      'business_day_rollover_hour',
    );
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.operator_location.onboard',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final bundle = await gateway.onboardOperator(
          actorUserId: actorUserId,
          businessName: businessName,
          ownerEmail: ownerEmail,
          subscriptionTier: subscriptionTier,
          preferredCurrency: preferredCurrency,
          adminUserEmail: adminEmail,
          primaryLocationName: locationName,
          primaryLocationTimezone: locationTimezone,
          primaryLocationRolloverHour: rolloverHour,
          adminReason: adminReason!,
        );
        return (statusCode: 201, payload: bundle);
      },
    );
    return;
  }

  if (method == 'PATCH' && path.startsWith(adminOperatorsPrefix)) {
    final operatorId = _pathSuffix(path, adminOperatorsPrefix);
    if (operatorId == null) {
      _writeNotFound(response, request);
      return;
    }
    String? preferredCurrency;
    if (body.containsKey('preferred_currency')) {
      preferredCurrency = _requireBodyCurrency(body, 'preferred_currency');
    }
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.operator_location.patch_operator',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final patched = await gateway.patchOperator(
          actorUserId: actorUserId,
          operatorId: operatorId,
          businessName: _optionalBodyString(body, 'business_name'),
          ownerEmail: _optionalBodyString(body, 'owner_email'),
          subscriptionTier: _optionalBodyString(body, 'subscription_tier'),
          preferredCurrency: preferredCurrency,
          primaryLocationId: _optionalBodyString(body, 'primary_location_id'),
          adminReason: adminReason!,
        );
        if (patched == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_operator',
              'message': 'operator not found',
            },
          );
        }
        return (
          statusCode: 200,
          payload: <String, Object?>{'operator': patched},
        );
      },
    );
    return;
  }

  if (method == 'POST' && path.startsWith(adminOperatorsPrefix)) {
    final action = _operatorActionFromPath(path);
    if (action == null) {
      _writeNotFound(response, request);
      return;
    }
    final actionKind = action.action;
    if (actionKind != 'suspend' && actionKind != 'reactivate') {
      _writeNotFound(response, request);
      return;
    }
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.operator_location.$actionKind',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        Map<String, Object?>? updated;
        if (actionKind == 'suspend') {
          updated = await gateway.suspendOperator(
            actorUserId: actorUserId,
            operatorId: action.operatorId,
            adminReason: adminReason!,
          );
        } else {
          updated = await gateway.reactivateOperator(
            actorUserId: actorUserId,
            operatorId: action.operatorId,
            adminReason: adminReason!,
          );
        }
        if (updated == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_operator',
              'message': 'operator not found',
            },
          );
        }
        return (
          statusCode: 200,
          payload: <String, Object?>{'operator': updated},
        );
      },
    );
    return;
  }

  if (method == 'POST' && path == adminLocationsPath) {
    final operatorId = _requireBodyString(body, 'operator_id');
    final parentOrgUnitId = _requireBodyString(body, 'parent_org_unit_id');
    final name = _requireBodyString(body, 'name');
    final timezone = _requireBodyTimezone(body, 'timezone');
    final rolloverHour = _requireBodyRolloverHour(
      body,
      'business_day_rollover_hour',
    );
    final address = _optionalBodyString(body, 'address') ?? '';
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.operator_location.add_location',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final created = await gateway.addLocation(
          actorUserId: actorUserId,
          operatorId: operatorId,
          parentOrgUnitId: parentOrgUnitId,
          name: name,
          address: address,
          timezone: timezone,
          businessDayRolloverHour: rolloverHour,
          adminReason: adminReason!,
        );
        return (
          statusCode: 201,
          payload: <String, Object?>{'location': created},
        );
      },
    );
    return;
  }

  if (method == 'PATCH' && path.startsWith(adminLocationsPrefix)) {
    final locationId = _pathSuffix(path, adminLocationsPrefix);
    if (locationId == null) {
      _writeNotFound(response, request);
      return;
    }
    String? timezone;
    if (body.containsKey('timezone')) {
      timezone = _requireBodyTimezone(body, 'timezone');
    }
    if (body.containsKey('business_day_rollover_hour')) {
      _writeJson(response, 410, <String, Object?>{
        'error': 'legacy_location_rollover_writes_disabled',
        'message':
            'Business Timing owns business-day start. Edit timing profiles '
            'instead of the legacy location rollover field.',
      });
      return;
    }
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.operator_location.patch_location',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final patched = await gateway.patchLocation(
          actorUserId: actorUserId,
          locationId: locationId,
          name: _optionalBodyString(body, 'name'),
          address: _optionalBodyString(body, 'address'),
          timezone: timezone,
          businessDayRolloverHour: null,
          adminReason: adminReason!,
        );
        if (patched == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_location',
              'message': 'location not found',
            },
          );
        }
        return (
          statusCode: 200,
          payload: <String, Object?>{'location': patched},
        );
      },
    );
    return;
  }

  if (method == 'DELETE' && path.startsWith(adminLocationsPrefix)) {
    final locationId = _pathSuffix(path, adminLocationsPrefix);
    if (locationId == null) {
      _writeNotFound(response, request);
      return;
    }
    final operatorId = _requireBodyString(body, 'operator_id');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.operator_location.remove_location',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final result = await gateway.removeLocation(
          actorUserId: actorUserId,
          operatorId: operatorId,
          locationId: locationId,
          adminReason: adminReason!,
        );
        switch (result) {
          case AdminLocationRemovalResult.removed:
            return (
              statusCode: 200,
              payload: <String, Object?>{'ok': true, 'removed': true},
            );
          case AdminLocationRemovalResult.notFound:
            return (
              statusCode: 404,
              payload: <String, Object?>{
                'error': 'unknown_location',
                'message': 'location not found',
              },
            );
          case AdminLocationRemovalResult.primaryLocationProtected:
            return (
              statusCode: 400,
              payload: <String, Object?>{
                'error': 'cannot_remove_primary_location',
                'message':
                    "reassign the operator's primary_location_id before removing this location",
              },
            );
        }
      },
    );
    return;
  }

  _writeNotFound(response, request);
}

void _writeNotFound(HttpResponse response, HttpRequest request) {
  _writeJson(response, 404, <String, Object?>{
    'error': 'not found',
    'method': request.method,
    'path': request.uri.path,
  });
}

bool _callerHasAnyRole(ProxyJwtClaims actor, Set<String> allowed) {
  return actor.roles.any(allowed.contains);
}

bool _isAdminPricingPath(String path) {
  if (path == adminPricingOperatorsPath ||
      path.startsWith(adminPricingOperatorsPrefix)) {
    return true;
  }
  if (path == adminPricingUsageCapsPath) return true;
  // Phase 3 — plan-pricing catalog GET (collection) + PATCH (single plan).
  if (path == adminPricingPlansPath ||
      path.startsWith(adminPricingPlansPrefix)) {
    return true;
  }
  // Phase 5a — feature-entitlements matrix GET (collection) + PATCH
  // (single pair). Shares the pricing CORS + role gate.
  if (path == adminPricingEntitlementsPath ||
      path.startsWith(adminPricingEntitlementsPrefix)) {
    return true;
  }
  if (path == adminPricingScopedContractsPath ||
      path == adminPricingScopedContractsEffectivePath ||
      path.startsWith(adminPricingScopedContractsPrefix)) {
    return true;
  }
  return false;
}

bool _isAdminDataAccuracyPath(String path) {
  if (path == adminDataAccuracyRowsPath) return true;
  if (path == adminDataAccuracyAuditHistoryPath) return true;
  if (path.startsWith(adminDataAccuracySettingsPrefix)) return true;
  if (path.startsWith(adminDataAccuracyServicePeriodSettingsPrefix)) {
    return true;
  }
  if (path == adminDataAccuracyScopedSettingsPath) return true;
  if (path == adminPollingPricingTierDefinitionsPath ||
      path.startsWith(adminPollingPricingTierDefinitionsPrefix)) {
    return true;
  }
  if (path == adminPollingPricingAssignmentsPath ||
      path.startsWith(adminPollingPricingAssignmentsPrefix)) {
    return true;
  }
  if (path == adminPollingPricingScopedAssignmentsPath) return true;
  if (path == adminPollingPricingMarginPath ||
      path == adminPollingPricingMarginExportPath) {
    return true;
  }
  if (path == adminPollingPricingChangeRequestsPath ||
      path.startsWith(adminPollingPricingChangeRequestsPrefix)) {
    return true;
  }
  return false;
}

bool _isAdminVendorApplicabilityPath(String path) {
  return path == adminVendorApplicabilityPath;
}

bool _isAdminIntegrationsPath(String path) {
  return path == adminIntegrationsListPath ||
      path == adminIntegrationsRotateAnthropicPath ||
      path == adminIntegrationsRotateVoyagePath ||
      path == adminIntegrationsRotateAzureDbPath ||
      path == adminIntegrationsRotateGeminiPath ||
      path == adminIntegrationsRotateSendgridPath ||
      path == adminIntegrationsStatusPath;
}

bool _isAuthCorsPath(String path) {
  return path.startsWith('/v1/auth/') ||
      path.startsWith('/v1/operator/') ||
      path.startsWith('/v1/operators/') ||
      path.startsWith('/v1/admin/auth/') ||
      BusinessScopeRouter.match(path, 'GET') != null ||
      AuditChainAnchorsRouter.match(path, 'GET') != null;
}

bool _isAdminIntegrationsOperation(String path, String method) {
  if (method == 'GET' &&
      (path == adminIntegrationsListPath ||
          path == adminIntegrationsStatusPath)) {
    return true;
  }
  if (method == 'POST' &&
      (path == adminIntegrationsRotateAnthropicPath ||
          path == adminIntegrationsRotateVoyagePath ||
          path == adminIntegrationsRotateAzureDbPath ||
          path == adminIntegrationsRotateGeminiPath ||
          path == adminIntegrationsRotateSendgridPath)) {
    return true;
  }
  return false;
}

Future<void> _routeIntegrationsAdmin({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required IntegrationAdminProxyGateway gateway,
  required String actorUserId,
  required String actorLogId,
  required Map<String, Object?> body,
  String idempotencyKey = '',
  AdminRequestIdempotencyStore? idempotencyStore,
}) async {
  final method = request.method;
  // [actorLogId] is the original verified Firebase UID (the value the
  // resolver looked up). It is embedded in the admin reason string
  // alongside the resolved Postgres user UUID so the audit trail
  // captures both identifiers without relying on a join.
  final reasonPrefix = 'admin.integrations.$method:$actorLogId';

  if (method == 'GET' && path == adminIntegrationsListPath) {
    final params = request.uri.queryParameters;
    final bundle = await gateway.listBundle(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:list',
      operatorId: _nonBlankString(params['operator_id']),
      locationId: _nonBlankString(params['location_id']),
      locationIds: _commaSeparatedQueryList(params['location_ids']),
    );
    _writeJson(response, 200, bundle);
    return;
  }

  if (method == 'GET' && path == adminIntegrationsStatusPath) {
    final params = request.uri.queryParameters;
    final bundle = await gateway.listBundle(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:status',
      operatorId: _nonBlankString(params['operator_id']),
      locationId: _nonBlankString(params['location_id']),
      locationIds: _commaSeparatedQueryList(params['location_ids']),
    );
    _writeJson(response, 200, <String, Object?>{
      'vendor_connectors': bundle['vendor_connectors'],
      'fx_rate_source': bundle['fx_rate_source'],
      'email_provider': bundle['email_provider'],
    });
    return;
  }

  if (method == 'POST') {
    final keyKind = _integrationKeyKindForRoute(path);
    if (keyKind == null) {
      _writeNotFound(response, request);
      return;
    }
    final plaintext = _requireBodyString(body, 'plaintext_value');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.integrations.rotate_$keyKind',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final result = await gateway.rotateProviderKey(
          actorUserId: actorUserId,
          keyKind: keyKind,
          plaintextValue: plaintext,
          adminReason: '$reasonPrefix:rotate:$keyKind',
        );
        return (statusCode: 200, payload: result);
      },
    );
    return;
  }

  _writeNotFound(response, request);
}

String? _integrationKeyKindForRoute(String path) {
  if (path == adminIntegrationsRotateAnthropicPath) return 'anthropic';
  if (path == adminIntegrationsRotateVoyagePath) return 'voyage';
  if (path == adminIntegrationsRotateAzureDbPath) return 'azure_db';
  if (path == adminIntegrationsRotateGeminiPath) return 'gemini';
  if (path == adminIntegrationsRotateSendgridPath) return 'sendgrid';
  return null;
}

bool _isAdminPricingOperation(String path, String method) {
  if (method == 'GET' && path == adminPricingOperatorsPath) return true;
  if (method == 'GET' && path.startsWith(adminPricingOperatorsPrefix)) {
    // /operators/{id}/spend-summary — Phase 2 live spend-vs-cap read.
    return path.endsWith('/spend-summary');
  }
  if (method == 'PATCH' && path.startsWith(adminPricingOperatorsPrefix)) {
    return true;
  }
  if (method == 'POST' && path.startsWith(adminPricingOperatorsPrefix)) {
    // /apply-template suffix
    return true;
  }
  if (method == 'PUT' && path == adminPricingUsageCapsPath) return true;
  // Phase 2 — delete-a-limit. DELETE is gated by the write-method role
  // set (`kFfPricingAdminWriteRoles`) the same way PUT/PATCH/POST are.
  if (method == 'DELETE' && path == adminPricingUsageCapsPath) return true;
  // Phase 3 — plan-pricing catalog. GET lists the catalog (read role set);
  // PATCH on `/plans/{tier_key}` edits one plan (write role set). Both
  // flow through the same method-scoped gate as the routes above.
  if (method == 'GET' && path == adminPricingPlansPath) return true;
  if (method == 'PATCH' && path.startsWith(adminPricingPlansPrefix)) {
    return true;
  }
  // Phase 5a — feature-entitlements matrix. GET lists the matrix (read
  // role set); PATCH on `/entitlements/{tier_key}/{feature_slug}` toggles
  // one pair (write role set). Both flow through the same method-scoped
  // gate as the routes above.
  if (method == 'GET' && path == adminPricingEntitlementsPath) return true;
  if (method == 'PATCH' && path.startsWith(adminPricingEntitlementsPrefix)) {
    return true;
  }
  if (method == 'GET' && path == adminPricingScopedContractsEffectivePath) {
    return true;
  }
  if (method == 'PUT' && path == adminPricingScopedContractsPath) {
    return true;
  }
  if (method == 'DELETE' &&
      path.startsWith(adminPricingScopedContractsPrefix)) {
    return true;
  }
  return false;
}

bool _isAdminDataAccuracyOperation(String path, String method) {
  if (method == 'GET' &&
      (path == adminDataAccuracyRowsPath ||
          path == adminDataAccuracyAuditHistoryPath ||
          path.startsWith(adminDataAccuracySettingsPrefix) ||
          path.startsWith(adminDataAccuracyServicePeriodSettingsPrefix) ||
          path == adminPollingPricingTierDefinitionsPath ||
          path == adminPollingPricingAssignmentsPath ||
          path.startsWith(adminPollingPricingAssignmentsPrefix) ||
          path == adminPollingPricingMarginPath ||
          path == adminPollingPricingChangeRequestsPath)) {
    return true;
  }
  if (method == 'PATCH' &&
      (path.startsWith(adminDataAccuracySettingsPrefix) ||
          path.startsWith(adminDataAccuracyServicePeriodSettingsPrefix) ||
          path.startsWith(adminPollingPricingTierDefinitionsPrefix) ||
          path.startsWith(adminPollingPricingChangeRequestsPrefix))) {
    return true;
  }
  if (method == 'PUT' &&
      path.startsWith(adminPollingPricingAssignmentsPrefix)) {
    return true;
  }
  if (method == 'PUT' &&
      (path == adminDataAccuracyScopedSettingsPath ||
          path == adminPollingPricingScopedAssignmentsPath)) {
    return true;
  }
  if (method == 'POST' && path == adminPollingPricingMarginExportPath) {
    return true;
  }
  return false;
}

bool _isAdminVendorApplicabilityOperation(String path, String method) {
  return path == adminVendorApplicabilityPath &&
      (method == 'GET' || method == 'POST' || method == 'PATCH');
}

Future<void> _routeDataAccuracyAdmin({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required DataAccuracyAdminProxyGateway gateway,
  required String actorUserId,
  required Map<String, Object?> body,
  String idempotencyKey = '',
  AdminRequestIdempotencyStore? idempotencyStore,
}) async {
  final method = request.method;
  final reasonPrefix = 'admin.data_accuracy.$method:$actorUserId';
  final params = request.uri.queryParameters;

  if (method == 'GET' && path == adminDataAccuracyRowsPath) {
    final rows = await gateway.listDataAccuracyRows(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:rows',
    );
    _writeJson(response, 200, <String, Object?>{'rows': rows});
    return;
  }

  if (method == 'GET' && path.startsWith(adminDataAccuracySettingsPrefix)) {
    final pair = _pathPairSuffix(path, adminDataAccuracySettingsPrefix);
    if (pair == null) {
      _writeNotFound(response, request);
      return;
    }
    final row = await gateway.loadDataAccuracyRow(
      actorUserId: actorUserId,
      operatorId: pair.operatorId,
      locationId: pair.locationId,
      adminReason:
          '$reasonPrefix:settings:${pair.operatorId}:${pair.locationId}',
    );
    _writeJson(response, 200, <String, Object?>{'row': row});
    return;
  }

  if (method == 'GET' && path == adminDataAccuracyAuditHistoryPath) {
    final events = await gateway.listAuditHistory(
      actorUserId: actorUserId,
      operatorId: _nonBlankString(params['operator_id']),
      locationId: _nonBlankString(params['location_id']),
      adminReason: '$reasonPrefix:audit_history',
    );
    _writeJson(response, 200, <String, Object?>{'events': events});
    return;
  }

  if (method == 'GET' &&
      path.startsWith(adminDataAccuracyServicePeriodSettingsPrefix)) {
    final pair = _pathPairSuffix(
      path,
      adminDataAccuracyServicePeriodSettingsPrefix,
    );
    if (pair == null) {
      _writeNotFound(response, request);
      return;
    }
    final rows = await gateway.listDataAccuracyServicePeriodRows(
      actorUserId: actorUserId,
      operatorId: pair.operatorId,
      locationId: pair.locationId,
      adminReason:
          '$reasonPrefix:service_period_settings:${pair.operatorId}:${pair.locationId}',
    );
    _writeJson(response, 200, <String, Object?>{
      'data_accuracy_service_period_settings': rows,
    });
    return;
  }

  if (method == 'PATCH' &&
      path.startsWith(adminDataAccuracyServicePeriodSettingsPrefix)) {
    final pair = _pathPairSuffix(
      path,
      adminDataAccuracyServicePeriodSettingsPrefix,
    );
    if (pair == null) {
      _writeNotFound(response, request);
      return;
    }
    final servicePeriodKey = _requireBodyString(body, 'service_period_key');
    final clearServicePeriod = _optionalBodyBool(body, 'clear');
    if (clearServicePeriod) {
      final reasonNote = _requireBodyString(body, 'reason_note');
      await _runAdminIdempotent(
        response: response,
        store: idempotencyStore,
        idempotencyKey: idempotencyKey,
        requestType: 'admin.data_accuracy.service_period_clear',
        actorUserId: actorUserId,
        requestBody: body,
        compute: () async {
          final result = await gateway.clearDataAccuracyServicePeriod(
            actorUserId: actorUserId,
            operatorId: pair.operatorId,
            locationId: pair.locationId,
            servicePeriodKey: servicePeriodKey,
            reasonNote: reasonNote,
            adminReason:
                '$reasonPrefix:service_period_clear:${pair.operatorId}:${pair.locationId}:$servicePeriodKey',
          );
          return (statusCode: 200, payload: result);
        },
      );
      return;
    }
    final coversSource = _requireBodyString(body, 'covers_source');
    final wageSource = _requireBodyString(body, 'wage_source');
    final effectiveAtBusinessDate = _requireBodyString(
      body,
      'effective_at_business_date',
    );
    final reasonNote = _requireBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.data_accuracy.service_period_override',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final row = await gateway.overrideDataAccuracyServicePeriod(
          actorUserId: actorUserId,
          operatorId: pair.operatorId,
          locationId: pair.locationId,
          servicePeriodKey: servicePeriodKey,
          coversSource: coversSource,
          wageSource: wageSource,
          effectiveAtBusinessDate: effectiveAtBusinessDate,
          reasonNote: reasonNote,
          adminReason:
              '$reasonPrefix:service_period_settings:${pair.operatorId}:${pair.locationId}:$servicePeriodKey',
        );
        return (statusCode: 200, payload: <String, Object?>{'data': row});
      },
    );
    return;
  }

  if (method == 'PATCH' && path.startsWith(adminDataAccuracySettingsPrefix)) {
    final manualPair = _dataAccuracyManualCoversPathPair(path);
    if (manualPair != null) {
      final bodyError = _validateManualCoversWriteBody(body);
      if (bodyError != null) {
        _writeJson(response, bodyError.$1, bodyError.$2);
        return;
      }
      final businessDate = _requireBodyString(body, 'business_date');
      final servicePeriodKey = _requireBodyString(body, 'service_period_key');
      final clearManualCovers = _optionalBodyBool(body, 'clear');
      final reasonNote = _optionalBodyString(body, 'reason_note');
      await _runAdminIdempotent(
        response: response,
        store: idempotencyStore,
        idempotencyKey: idempotencyKey,
        requestType: clearManualCovers
            ? 'admin.data_accuracy.manual_covers_clear'
            : 'admin.data_accuracy.manual_covers_save',
        actorUserId: actorUserId,
        requestBody: body,
        compute: () async {
          final result = clearManualCovers
              ? await gateway.clearDataAccuracyManualCovers(
                  actorUserId: actorUserId,
                  operatorId: manualPair.operatorId,
                  locationId: manualPair.locationId,
                  businessDate: businessDate,
                  servicePeriodKey: servicePeriodKey,
                  reasonNote: reasonNote,
                  adminReason:
                      '$reasonPrefix:manual_covers_clear:${manualPair.operatorId}:${manualPair.locationId}:$businessDate:$servicePeriodKey',
                )
              : await gateway.saveDataAccuracyManualCovers(
                  actorUserId: actorUserId,
                  operatorId: manualPair.operatorId,
                  locationId: manualPair.locationId,
                  businessDate: businessDate,
                  servicePeriodKey: servicePeriodKey,
                  covers: _optionalBodyInt(body, 'covers')!,
                  reasonNote: reasonNote,
                  adminReason:
                      '$reasonPrefix:manual_covers_save:${manualPair.operatorId}:${manualPair.locationId}:$businessDate:$servicePeriodKey',
                );
          if (result == null) {
            return (
              statusCode: 404,
              payload: <String, Object?>{
                'error': 'unknown_operator_location',
                'message': 'operator/location pair not found',
              },
            );
          }
          return (statusCode: 200, payload: result);
        },
      );
      return;
    }
  }

  if (method == 'PATCH' && path.startsWith(adminDataAccuracySettingsPrefix)) {
    final pair = _pathPairSuffix(path, adminDataAccuracySettingsPrefix);
    if (pair == null) {
      _writeNotFound(response, request);
      return;
    }
    if (_rejectLegacyCoversSourceWriteKeys(response, body)) return;
    final coversPerServicePeriod = _optionalBodyStringMap(
      body,
      'covers_source_per_service_period',
    );
    final wageSource = _optionalBodyString(body, 'wage_source');
    final walkInHandlingMode = _optionalBodyString(
      body,
      'walk_in_handling_mode',
    );
    final reasonNote = _optionalBodyString(body, 'reason_note');
    if (body.containsKey('covers_manual_entries') ||
        body.containsKey('walk_in_manual_entries')) {
      final coversManualEntries =
          _optionalBodyNestedNonNegativeIntMap(body, 'covers_manual_entries') ??
          const <String, Map<String, int>>{};
      final walkInManualEntries =
          _optionalBodyNonNegativeIntMap(body, 'walk_in_manual_entries') ??
          const <String, int>{};
      await _runAdminIdempotent(
        response: response,
        store: idempotencyStore,
        idempotencyKey: idempotencyKey,
        requestType: 'admin.data_accuracy.settings_save',
        actorUserId: actorUserId,
        requestBody: body,
        compute: () async {
          final result = await gateway.saveDataAccuracySettings(
            actorUserId: actorUserId,
            operatorId: pair.operatorId,
            locationId: pair.locationId,
            coversSourcePerServicePeriod: coversPerServicePeriod,
            coversManualEntries: coversManualEntries,
            wageSource: wageSource,
            walkInHandlingMode: walkInHandlingMode,
            walkInManualEntries: walkInManualEntries,
            reasonNote: reasonNote,
            adminReason:
                '$reasonPrefix:settings_save:${pair.operatorId}:${pair.locationId}',
          );
          if (result == null) {
            return (
              statusCode: 404,
              payload: <String, Object?>{
                'error': 'unknown_operator_location',
                'message': 'operator/location pair not found',
              },
            );
          }
          return (statusCode: 200, payload: result);
        },
      );
      return;
    }
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.data_accuracy.override',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final row = await gateway.overrideDataAccuracy(
          actorUserId: actorUserId,
          operatorId: pair.operatorId,
          locationId: pair.locationId,
          coversSourcePerServicePeriod: coversPerServicePeriod,
          wageSource: wageSource,
          walkInHandlingMode: walkInHandlingMode,
          reasonNote: reasonNote,
          adminReason:
              '$reasonPrefix:settings:${pair.operatorId}:${pair.locationId}',
        );
        if (row == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_operator_location',
              'message': 'operator/location pair not found',
            },
          );
        }
        return (statusCode: 200, payload: <String, Object?>{'row': row});
      },
    );
    return;
  }

  if (method == 'PUT' && path == adminDataAccuracyScopedSettingsPath) {
    final operatorId = _requireBodyString(body, 'operator_id');
    final scopeType = _requireBodyString(body, 'scope_type');
    final orgUnitId = _optionalBodyString(body, 'org_unit_id');
    final locationId = _optionalBodyString(body, 'location_id');
    if (_rejectLegacyCoversSourceWriteKeys(response, body)) return;
    final coversPerServicePeriod = _optionalBodyStringMap(
      body,
      'covers_source_per_service_period',
    );
    final clearCoversPerServicePeriod = _optionalBodyStringList(
      body,
      'clear_covers_source_per_service_period',
    );
    final clearWageSource = _optionalBodyBool(body, 'clear_wage_source');
    final clearWalkInHandlingMode = _optionalBodyBool(
      body,
      'clear_walk_in_handling_mode',
    );
    final wageSource = _optionalBodyString(body, 'wage_source');
    final walkInHandlingMode = _optionalBodyString(
      body,
      'walk_in_handling_mode',
    );
    final reasonNote = _optionalBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.data_accuracy.scope_override',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final result = await gateway.overrideDataAccuracyScope(
          actorUserId: actorUserId,
          operatorId: operatorId,
          scopeType: scopeType,
          orgUnitId: orgUnitId,
          locationId: locationId,
          coversSourcePerServicePeriod: coversPerServicePeriod,
          clearCoversSourcePerServicePeriod: clearCoversPerServicePeriod,
          clearWageSource: clearWageSource,
          clearWalkInHandlingMode: clearWalkInHandlingMode,
          wageSource: wageSource,
          walkInHandlingMode: walkInHandlingMode,
          reasonNote: reasonNote,
          adminReason: '$reasonPrefix:scoped_settings:$operatorId:$scopeType',
        );
        return (statusCode: 200, payload: result);
      },
    );
    return;
  }

  if (method == 'GET' && path == adminPollingPricingTierDefinitionsPath) {
    final definitions = await gateway.listTierDefinitions(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:tier_definitions',
    );
    _writeJson(response, 200, <String, Object?>{'definitions': definitions});
    return;
  }

  if (method == 'PATCH' &&
      path.startsWith(adminPollingPricingTierDefinitionsPrefix)) {
    final tierKey = _pathSuffix(path, adminPollingPricingTierDefinitionsPrefix);
    if (tierKey == null) {
      _writeNotFound(response, request);
      return;
    }
    final cadence = _optionalBodyPositiveIntMap(
      body,
      'polling_cadence_per_vendor_seconds',
    );
    final descriptionMd = _optionalBodyString(body, 'description_md');
    final price = _optionalBodyNonNegativeInt(
      body,
      'default_monthly_price_cents',
    );
    final cost = _optionalBodyNonNegativeInt(
      body,
      'vendor_api_cost_estimate_cents_monthly',
    );
    final reasonNote = _optionalBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.polling_pricing.update_tier_definition',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final definition = await gateway.updateTierDefinition(
          actorUserId: actorUserId,
          tierKey: tierKey,
          descriptionMd: descriptionMd,
          pollingCadencePerVendorSeconds: cadence,
          defaultMonthlyPriceCents: price,
          vendorApiCostEstimateCentsMonthly: cost,
          reasonNote: reasonNote,
          adminReason: '$reasonPrefix:tier_definition:$tierKey',
        );
        return (
          statusCode: 200,
          payload: <String, Object?>{'definition': definition},
        );
      },
    );
    return;
  }

  if (method == 'GET' && path == adminPollingPricingAssignmentsPath) {
    final assignments = await gateway.listTierAssignments(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:tier_assignments',
    );
    _writeJson(response, 200, <String, Object?>{'assignments': assignments});
    return;
  }

  if (method == 'GET' &&
      path.startsWith(adminPollingPricingAssignmentsPrefix)) {
    final pair = _pathPairSuffix(path, adminPollingPricingAssignmentsPrefix);
    if (pair == null) {
      _writeNotFound(response, request);
      return;
    }
    final assignment = await gateway.loadTierAssignment(
      actorUserId: actorUserId,
      operatorId: pair.operatorId,
      locationId: pair.locationId,
      adminReason:
          '$reasonPrefix:assignment:${pair.operatorId}:${pair.locationId}',
    );
    _writeJson(response, 200, <String, Object?>{'assignment': assignment});
    return;
  }

  if (method == 'PUT' &&
      path.startsWith(adminPollingPricingAssignmentsPrefix)) {
    final pair = _pathPairSuffix(path, adminPollingPricingAssignmentsPrefix);
    if (pair == null) {
      _writeNotFound(response, request);
      return;
    }
    final tierKey = _requireBodyString(body, 'tier_key');
    final cadence = _optionalBodyPositiveIntMap(
      body,
      'custom_cadence_per_vendor_seconds',
    );
    final price = _optionalBodyNonNegativeInt(
      body,
      'monthly_price_cents_override',
    );
    final cost = _optionalBodyNonNegativeInt(
      body,
      'vendor_api_cost_estimate_cents_monthly_override',
    );
    final adminNotes = _optionalBodyString(body, 'admin_notes');
    final reasonNote = _optionalBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.polling_pricing.assign_tier',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final assignment = await gateway.assignTier(
          actorUserId: actorUserId,
          operatorId: pair.operatorId,
          locationId: pair.locationId,
          tierKey: tierKey,
          customCadencePerVendorSeconds: cadence,
          monthlyPriceCentsOverride: price,
          vendorApiCostEstimateCentsMonthlyOverride: cost,
          adminNotes: adminNotes,
          reasonNote: reasonNote,
          adminReason:
              '$reasonPrefix:assignment:${pair.operatorId}:${pair.locationId}',
        );
        if (assignment == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_operator_location',
              'message': 'operator/location pair not found',
            },
          );
        }
        return (
          statusCode: 200,
          payload: <String, Object?>{'assignment': assignment},
        );
      },
    );
    return;
  }

  if (method == 'PUT' && path == adminPollingPricingScopedAssignmentsPath) {
    final operatorId = _requireBodyString(body, 'operator_id');
    final scopeType = _requireBodyString(body, 'scope_type');
    final orgUnitId = _optionalBodyString(body, 'org_unit_id');
    final locationId = _optionalBodyString(body, 'location_id');
    final tierKey = _requireBodyString(body, 'tier_key');
    final cadence = _optionalBodyPositiveIntMap(
      body,
      'custom_cadence_per_vendor_seconds',
    );
    final price = _optionalBodyNonNegativeInt(
      body,
      'monthly_price_cents_override',
    );
    final cost = _optionalBodyNonNegativeInt(
      body,
      'vendor_api_cost_estimate_cents_monthly_override',
    );
    final adminNotes = _optionalBodyString(body, 'admin_notes');
    final reasonNote = _optionalBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.polling_pricing.scope_assign_tier',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final result = await gateway.assignTierScope(
          actorUserId: actorUserId,
          operatorId: operatorId,
          scopeType: scopeType,
          orgUnitId: orgUnitId,
          locationId: locationId,
          tierKey: tierKey,
          customCadencePerVendorSeconds: cadence,
          monthlyPriceCentsOverride: price,
          vendorApiCostEstimateCentsMonthlyOverride: cost,
          adminNotes: adminNotes,
          reasonNote: reasonNote,
          adminReason: '$reasonPrefix:scope_assignment:$operatorId:$scopeType',
        );
        return (statusCode: 200, payload: result);
      },
    );
    return;
  }

  if (method == 'GET' && path == adminPollingPricingMarginPath) {
    final rollup = await gateway.summarizeMargin(
      actorUserId: actorUserId,
      tierKey: _nonBlankString(params['tier_key']),
      adminReason: '$reasonPrefix:margin',
    );
    _writeJson(response, 200, <String, Object?>{'rollup': rollup});
    return;
  }

  if (method == 'POST' && path == adminPollingPricingMarginExportPath) {
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.polling_pricing.export_margin_csv',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final csv = await gateway.exportMarginRollupCsv(
          actorUserId: actorUserId,
          adminReason: '$reasonPrefix:margin_export_csv',
        );
        return (statusCode: 200, payload: <String, Object?>{'csv': csv});
      },
    );
    return;
  }

  if (method == 'GET' && path == adminPollingPricingChangeRequestsPath) {
    final requests = await gateway.listTierChangeRequests(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:change_requests',
    );
    _writeJson(response, 200, <String, Object?>{'requests': requests});
    return;
  }

  if (method == 'PATCH' &&
      path.startsWith(adminPollingPricingChangeRequestsPrefix)) {
    final requestId = _pathSuffix(
      path,
      adminPollingPricingChangeRequestsPrefix,
    );
    if (requestId == null) {
      _writeNotFound(response, request);
      return;
    }
    final status = _requireBodyString(body, 'status');
    final reasonNote = _optionalBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.polling_pricing.resolve_change_request',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final resolved = await gateway.resolveTierChangeRequest(
          actorUserId: actorUserId,
          requestId: requestId,
          status: status,
          reasonNote: reasonNote,
          adminReason: '$reasonPrefix:change_request:$requestId',
        );
        if (resolved == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_change_request',
              'message': 'tier change request not found',
            },
          );
        }
        return (
          statusCode: 200,
          payload: <String, Object?>{'request': resolved},
        );
      },
    );
    return;
  }

  _writeNotFound(response, request);
}

Future<void> _routeVendorApplicabilityAdmin({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required VendorApplicabilityProxyGateway gateway,
  required String actorUserId,
  required Map<String, Object?> body,
  required String idempotencyKey,
  AdminRequestIdempotencyStore? idempotencyStore,
}) async {
  if (path != adminVendorApplicabilityPath) {
    _writeNotFound(response, request);
    return;
  }
  final method = request.method;
  final reasonPrefix = 'admin.vendor_applicability.$method:$actorUserId';
  final params = request.uri.queryParameters;

  if (method == 'GET') {
    final operatorId = _nonBlankString(params['operator_id']);
    final locationId = _nonBlankString(params['location_id']);
    _assertVendorApplicabilityLocationHasOperator(
      operatorId: operatorId,
      locationId: locationId,
    );
    final rows = await gateway.listAdmin(
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      settingKind: _nonBlankString(params['setting_kind']),
      settingKey: _nonBlankString(params['setting_key']),
      vendorSlug: _nonBlankString(params['vendor_slug']),
      currentOnly: _optionalQueryBool(
        params['current_only'],
        defaultValue: true,
      ),
      adminReason: '$reasonPrefix:list',
    );
    _writeJson(response, 200, <String, Object?>{'rows': rows});
    return;
  }

  if (method == 'POST') {
    final settingKind = _requireBodyString(body, 'setting_kind');
    final settingKey = _requireBodyString(body, 'setting_key');
    final vendorSlug = _requireBodyString(body, 'vendor_slug');
    final enabled = _requireBodyBool(body, 'enabled');
    final metadata = _optionalBodyObject(body, 'metadata');
    final operatorId = _optionalBodyString(body, 'operator_id');
    final locationId = _optionalBodyString(body, 'location_id');
    _assertVendorApplicabilityLocationHasOperator(
      operatorId: operatorId,
      locationId: locationId,
    );
    final effectiveFrom = _optionalBodyDateTime(body, 'effective_from');
    final adminReason = _requireBodyString(body, 'admin_reason');
    final reasonNote = _optionalBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.vendor_applicability.upsert',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final row = await gateway.upsert(
          actorUserId: actorUserId,
          operatorId: operatorId,
          locationId: locationId,
          settingKind: settingKind,
          settingKey: settingKey,
          vendorSlug: vendorSlug,
          enabled: enabled,
          metadata: metadata,
          effectiveFrom: effectiveFrom,
          reasonNote: reasonNote,
          adminReason: adminReason,
        );
        return (statusCode: 200, payload: <String, Object?>{'row': row});
      },
    );
    return;
  }

  if (method == 'PATCH') {
    final action = _optionalBodyString(body, 'action') ?? 'end';
    if (action != 'end') {
      throw const _AdminInputError(
        statusCode: 400,
        code: 'invalid_action',
        message: 'PATCH action must be "end"',
      );
    }
    final settingKind = _requireBodyString(body, 'setting_kind');
    final settingKey = _requireBodyString(body, 'setting_key');
    final vendorSlug = _requireBodyString(body, 'vendor_slug');
    final operatorId = _optionalBodyString(body, 'operator_id');
    final locationId = _optionalBodyString(body, 'location_id');
    _assertVendorApplicabilityLocationHasOperator(
      operatorId: operatorId,
      locationId: locationId,
    );
    final effectiveUntil = _optionalBodyDateTime(body, 'effective_until');
    final adminReason = _requireBodyString(body, 'admin_reason');
    final reasonNote = _optionalBodyString(body, 'reason_note');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.vendor_applicability.end',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final row = await gateway.end(
          actorUserId: actorUserId,
          operatorId: operatorId,
          locationId: locationId,
          settingKind: settingKind,
          settingKey: settingKey,
          vendorSlug: vendorSlug,
          effectiveUntil: effectiveUntil,
          reasonNote: reasonNote,
          adminReason: adminReason,
        );
        if (row == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_vendor_applicability',
              'message': 'current vendor applicability row not found',
            },
          );
        }
        return (statusCode: 200, payload: <String, Object?>{'row': row});
      },
    );
    return;
  }

  _writeNotFound(response, request);
}

/// Enforces the `vendor_applicability` rule (and DB CHECK) that any
/// location-scoped row must also carry an operator: a location belongs
/// to exactly one operator, so a location filter / write without an
/// operator is meaningless. Rejected with 400 before the gateway runs.
/// UUID shape itself is validated downstream by the repository.
void _assertVendorApplicabilityLocationHasOperator({
  required String? operatorId,
  required String? locationId,
}) {
  if (locationId != null && operatorId == null) {
    throw const _AdminInputError(
      statusCode: 400,
      code: 'location_requires_operator',
      message:
          'location_id requires operator_id (a location belongs to one '
          'operator)',
    );
  }
}

Future<void> _routePricingAdmin({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required PricingTierAdminProxyGateway gateway,
  required String actorUserId,
  required Map<String, Object?> body,
  String idempotencyKey = '',
  AdminRequestIdempotencyStore? idempotencyStore,
}) async {
  final method = request.method;
  final reasonPrefix = 'admin.pricing.$method:$actorUserId';

  if (method == 'GET' && path == adminPricingOperatorsPath) {
    final operators = await gateway.listOperatorsWithCaps(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:list',
    );
    _writeJson(response, 200, <String, Object?>{'operators': operators});
    return;
  }

  // Phase 2 — GET /v1/admin/pricing/operators/{id}/spend-summary.
  // Month-to-date spend per (location, usage_class) so the screen's
  // spend-vs-cap bars show live figures. Read-only: no idempotency key
  // (a GET is naturally idempotent).
  if (method == 'GET' && path.startsWith(adminPricingOperatorsPrefix)) {
    final tail = path.substring(adminPricingOperatorsPrefix.length);
    final parts = tail.split('/');
    if (parts.length != 2 ||
        parts.any((p) => p.isEmpty) ||
        parts[1] != 'spend-summary') {
      _writeNotFound(response, request);
      return;
    }
    final operatorId = Uri.decodeComponent(parts[0]);
    final summary = await gateway.monthToDateSpendSummary(
      actorUserId: actorUserId,
      operatorId: operatorId,
      adminReason: '$reasonPrefix:spend_summary:$operatorId',
    );
    if (summary == null) {
      _writeJson(response, 404, <String, Object?>{
        'error': 'unknown_operator',
        'message': 'operator not found',
      });
      return;
    }
    _writeJson(response, 200, <String, Object?>{
      'operator_id': operatorId,
      'spend': summary,
    });
    return;
  }

  if (method == 'PATCH' && path.startsWith(adminPricingOperatorsPrefix)) {
    final tail = _pathSuffix(path, adminPricingOperatorsPrefix);
    if (tail == null || tail.contains('/')) {
      _writeNotFound(response, request);
      return;
    }
    final operatorId = tail;
    final subscriptionTier = _requireBodyString(body, 'subscription_tier');
    if (!kProxyPricingTierTemplateKeys.contains(subscriptionTier)) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_subscription_tier',
        message:
            'subscription_tier must be one of: '
            '${kProxyPricingTierTemplateKeys.join(', ')}',
      );
    }
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.pricing.update_operator_tier',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final updated = await gateway.updateOperatorTier(
          actorUserId: actorUserId,
          operatorId: operatorId,
          subscriptionTier: subscriptionTier,
          adminReason: '$reasonPrefix:tier:$operatorId',
        );
        if (updated == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_operator',
              'message': 'operator not found',
            },
          );
        }
        return (statusCode: 200, payload: updated);
      },
    );
    return;
  }

  if (method == 'POST' && path.startsWith(adminPricingOperatorsPrefix)) {
    final tail = path.substring(adminPricingOperatorsPrefix.length);
    if (tail.isEmpty) {
      _writeNotFound(response, request);
      return;
    }
    final parts = tail.split('/');
    if (parts.length != 2 || parts.any((p) => p.isEmpty)) {
      _writeNotFound(response, request);
      return;
    }
    final operatorId = Uri.decodeComponent(parts[0]);
    final action = Uri.decodeComponent(parts[1]);

    // Plans & Limits V1 Phase 4a — start a Pilot free trial on a real
    // operator. Sets subscription_tier='pilot', trial_mode=true,
    // trial_expires_at=now()+trial_days. Idempotent (Idempotency-Key) +
    // audited (operator.trial.pilot_started). Write-gated (super_admin)
    // by the same method-scoped gate as apply-template above.
    //
    // HP #2: this route only flips the trial FLAG + tier on a REAL
    // operator. It deliberately does NOT seed sample preview data. The
    // existing demo seeders (`_seedDemoDataFromReplay`) are client-side
    // SQLite, hardcoded to `DemoScope.restaurantId`, and unreachable
    // from this Postgres proxy; seeding sample data under a real
    // operator from the proxy would require either a forbidden parallel
    // server-side seeder or a large client-seeder refactor + a
    // proxy->client trigger. Per the HP #2 doctrine (demo is a
    // writer-side switch, same tables/reads/UI) the preview sample-data
    // seeding belongs on the client/writer side and is wired in a
    // follow-up slice; this route provisions the trial flag only.
    if (action == 'start-pilot') {
      final trialDays =
          _optionalBodyInt(body, 'trial_days') ?? kPilotTrialDefaultDays;
      if (trialDays < 1 || trialDays > kPilotTrialMaxDays) {
        throw _AdminInputError(
          statusCode: 400,
          code: 'invalid_trial_days',
          message:
              'trial_days must be an integer between 1 and '
              '$kPilotTrialMaxDays',
        );
      }
      await _runAdminIdempotent(
        response: response,
        store: idempotencyStore,
        idempotencyKey: idempotencyKey,
        requestType: 'admin.pricing.start_pilot',
        actorUserId: actorUserId,
        requestBody: body,
        compute: () async {
          final result = await gateway.startPilotTrial(
            actorUserId: actorUserId,
            operatorId: operatorId,
            trialDays: trialDays,
            adminReason: '$reasonPrefix:start_pilot:$operatorId',
          );
          if (result == null) {
            return (
              statusCode: 404,
              payload: <String, Object?>{
                'error': 'unknown_operator',
                'message': 'operator not found',
              },
            );
          }
          return (statusCode: 200, payload: result);
        },
      );
      return;
    }

    // Plans & Limits V1 Phase 4a — convert a Pilot trial to Starter (the
    // "real POS / labor connector succeeded" conversion). Clears the
    // trial flag + moves pilot->starter. Idempotent + audited
    // (operator.trial.converted). An operator not on the trial is a 200
    // no-op (already converted / never a trial); a missing operator is
    // a 404. If a connector-success hook is added later it can call the
    // same gateway method directly; this explicit endpoint is the V1
    // conversion seam.
    if (action == 'convert-trial') {
      await _runAdminIdempotent(
        response: response,
        store: idempotencyStore,
        idempotencyKey: idempotencyKey,
        requestType: 'admin.pricing.convert_trial',
        actorUserId: actorUserId,
        requestBody: body,
        compute: () async {
          final outcome = await gateway.convertTrialToStarter(
            actorUserId: actorUserId,
            operatorId: operatorId,
            adminReason: '$reasonPrefix:convert_trial:$operatorId',
          );
          if (!outcome.operatorFound) {
            return (
              statusCode: 404,
              payload: <String, Object?>{
                'error': 'unknown_operator',
                'message': 'operator not found',
              },
            );
          }
          return (
            statusCode: 200,
            payload: <String, Object?>{
              'converted': outcome.converted,
              if (outcome.bundle != null) ...outcome.bundle!,
            },
          );
        },
      );
      return;
    }

    if (action != 'apply-template') {
      _writeNotFound(response, request);
      return;
    }
    final tierKey = _requireBodyString(body, 'tier_key');
    if (!kProxyPricingTierTemplateKeys.contains(tierKey)) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'unknown_tier_template',
        message: 'tier_key "$tierKey" is not a known pricing template',
      );
    }
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.pricing.apply_template',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final result = await gateway.applyTierTemplate(
          actorUserId: actorUserId,
          operatorId: operatorId,
          tierKey: tierKey,
          adminReason: '$reasonPrefix:apply_template:$operatorId:$tierKey',
        );
        if (result == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_operator',
              'message': 'operator not found',
            },
          );
        }
        return (statusCode: 200, payload: result);
      },
    );
    return;
  }

  if (method == 'PUT' && path == adminPricingUsageCapsPath) {
    final operatorId = _requireBodyString(body, 'operator_id');
    final locationId = _requireBodyString(body, 'location_id');
    final usageClass = _requireBodyString(body, 'usage_class');
    final monthlyCap = _requireBodyMoney(body, 'monthly_cap_usd');
    final perInvocation = _requireBodyMoney(body, 'per_invocation_cap_usd');
    final staffId = _optionalBodyString(body, 'staff_id');
    final workflowId = _optionalBodyString(body, 'workflow_id');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.pricing.upsert_usage_cap',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final cap = await gateway.upsertUsageCap(
          actorUserId: actorUserId,
          operatorId: operatorId,
          locationId: locationId,
          usageClass: usageClass,
          monthlyCapUsd: monthlyCap,
          perInvocationCapUsd: perInvocation,
          staffId: staffId,
          workflowId: workflowId,
          adminReason:
              '$reasonPrefix:usage_caps:$operatorId:$locationId:$usageClass',
        );
        return (statusCode: 200, payload: <String, Object?>{'cap': cap});
      },
    );
    return;
  }

  // Phase 2 — DELETE /v1/admin/pricing/usage-caps. Delete one cap by
  // its surrogate cap_id when supplied, else by the logical key
  // `(operator_id, location_id, usage_class, staff_id, workflow_id)`.
  // Idempotent + audited like the upsert: a retried DELETE under the
  // same Idempotency-Key collapses to one mutation + one audit row,
  // and deleting an already-deleted cap answers 404 honestly.
  if (method == 'DELETE' && path == adminPricingUsageCapsPath) {
    final operatorId = _requireBodyString(body, 'operator_id');
    final capId = _optionalBodyString(body, 'cap_id');
    // The logical key is required only when no cap_id is given.
    final locationId = capId != null
        ? _optionalBodyString(body, 'location_id')
        : _requireBodyString(body, 'location_id');
    final usageClass = capId != null
        ? _optionalBodyString(body, 'usage_class')
        : _requireBodyString(body, 'usage_class');
    final staffId = _optionalBodyString(body, 'staff_id');
    final workflowId = _optionalBodyString(body, 'workflow_id');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.pricing.delete_usage_cap',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final deleted = await gateway.deleteUsageCap(
          actorUserId: actorUserId,
          operatorId: operatorId,
          locationId: locationId ?? '',
          usageClass: usageClass ?? '',
          staffId: staffId,
          workflowId: workflowId,
          capId: capId,
          adminReason:
              '$reasonPrefix:usage_caps_delete:$operatorId:'
              '${capId ?? '$locationId:$usageClass'}',
        );
        if (!deleted) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_usage_cap',
              'message': 'no matching usage limit to delete',
            },
          );
        }
        return (statusCode: 200, payload: <String, Object?>{'deleted': true});
      },
    );
    return;
  }

  // Phase 3 — GET /v1/admin/pricing/plans. Lists the editable plan-pricing
  // catalog (one row per plan). Read-only: no idempotency key (a GET is
  // naturally idempotent). Gated by the read role set in the dispatch
  // layer (super_admin + ff_support).
  if (method == 'GET' && path == adminPricingScopedContractsEffectivePath) {
    final params = request.uri.queryParameters;
    final operatorId = _requireQueryString(params, 'operator_id');
    final scopeType = _requireQueryString(params, 'scope_type');
    final orgUnitId = _optionalQueryString(params, 'org_unit_id');
    final locationId = _optionalQueryString(params, 'location_id');
    _validateScopedPricingContractScope(
      scopeType: scopeType,
      orgUnitId: orgUnitId,
      locationId: locationId,
    );
    final resolved = await gateway.resolveScopedContract(
      actorUserId: actorUserId,
      operatorId: operatorId,
      scopeType: scopeType,
      orgUnitId: orgUnitId,
      locationId: locationId,
      adminReason: '$reasonPrefix:scoped_contracts_effective:$operatorId',
    );
    if (resolved == null) {
      _writeJson(response, 404, <String, Object?>{
        'error': 'unknown_pricing_scope',
        'message': 'operator or pricing scope not found',
      });
      return;
    }
    _writeJson(response, 200, <String, Object?>{
      'effective_contract': resolved,
    });
    return;
  }

  if (method == 'PUT' && path == adminPricingScopedContractsPath) {
    final operatorId = _requireBodyString(body, 'operator_id');
    final scopeType = _requireBodyString(body, 'scope_type');
    final orgUnitId = _optionalBodyString(body, 'org_unit_id');
    final locationId = _optionalBodyString(body, 'location_id');
    _validateScopedPricingContractScope(
      scopeType: scopeType,
      orgUnitId: orgUnitId,
      locationId: locationId,
    );
    final tierKey = _requireBodyString(body, 'tier_key');
    if (!kProxyPricingTierTemplateKeys.contains(tierKey)) {
      throw _AdminInputError(
        statusCode: 404,
        code: 'unknown_plan',
        message: 'tier_key "$tierKey" is not a known plan',
      );
    }
    final adminReason = _requireBodyString(body, 'admin_reason');
    final contractOverrideId =
        _optionalBodyString(body, 'id') ??
        _optionalBodyString(body, 'contract_override_id');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.pricing.scoped_contract_saved',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final resolved = await gateway.saveScopedContract(
          actorUserId: actorUserId,
          operatorId: operatorId,
          scopeType: scopeType,
          orgUnitId: orgUnitId,
          locationId: locationId,
          tierKey: tierKey,
          billingOwnerOrgUnitId: _optionalBodyString(
            body,
            'billing_owner_org_unit_id',
          ),
          monthlyUsd: _optionalBodyMoney(body, 'monthly_usd'),
          firstNSeats: _optionalBodyInt(body, 'first_n_seats'),
          firstSeatUsd: _optionalBodyMoney(body, 'first_seat_usd'),
          additionalSeatUsd: _optionalBodyMoney(body, 'additional_seat_usd'),
          onboardingMinUsd: _optionalBodyMoney(body, 'onboarding_min_usd'),
          onboardingMaxUsd: _optionalBodyMoney(body, 'onboarding_max_usd'),
          advisorCapMonthlyUsd: _optionalBodyMoney(
            body,
            'advisor_cap_monthly_usd',
          ),
          effectiveFrom: _optionalBodyString(body, 'effective_from'),
          effectiveUntil: _optionalBodyString(body, 'effective_until'),
          contractLabel: _optionalBodyString(body, 'contract_label'),
          internalNote: _optionalBodyString(body, 'internal_note'),
          contractOverrideId: contractOverrideId,
          adminReason:
              '$reasonPrefix:scoped_contract_saved:$operatorId:$adminReason',
        );
        if (resolved == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_pricing_scope',
              'message': 'operator or pricing scope not found',
            },
          );
        }
        return (
          statusCode: 200,
          payload: <String, Object?>{'effective_contract': resolved},
        );
      },
    );
    return;
  }

  if (method == 'DELETE' &&
      path.startsWith(adminPricingScopedContractsPrefix)) {
    final tail = _pathSuffix(path, adminPricingScopedContractsPrefix);
    if (tail == null || tail.contains('/')) {
      _writeNotFound(response, request);
      return;
    }
    final contractOverrideId = Uri.decodeComponent(tail);
    final operatorId = _requireBodyString(body, 'operator_id');
    final scopeType = _requireBodyString(body, 'scope_type');
    final orgUnitId = _optionalBodyString(body, 'org_unit_id');
    final locationId = _optionalBodyString(body, 'location_id');
    _validateScopedPricingContractScope(
      scopeType: scopeType,
      orgUnitId: orgUnitId,
      locationId: locationId,
    );
    final adminReason = _requireBodyString(body, 'admin_reason');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.pricing.scoped_contract_deleted',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final resolved = await gateway.deleteScopedContract(
          actorUserId: actorUserId,
          operatorId: operatorId,
          scopeType: scopeType,
          orgUnitId: orgUnitId,
          locationId: locationId,
          contractOverrideId: contractOverrideId,
          adminReason:
              '$reasonPrefix:scoped_contract_deleted:$operatorId:$adminReason',
        );
        if (resolved == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_scoped_contract',
              'message': 'scoped contract override not found',
            },
          );
        }
        return (
          statusCode: 200,
          payload: <String, Object?>{'effective_contract': resolved},
        );
      },
    );
    return;
  }

  if (method == 'GET' && path == adminPricingPlansPath) {
    final plans = await gateway.listPlanCatalog(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:plans_list',
    );
    _writeJson(response, 200, <String, Object?>{'plans': plans});
    return;
  }

  // Phase 3 — PATCH /v1/admin/pricing/plans/{tier_key}. Edits one plan's
  // pricing. Write role set (super_admin only), idempotent + audited like
  // the operator-tier PATCH: a retried PATCH under the same Idempotency-Key
  // collapses to one pricing mutation + one audit row. Unknown tier_key
  // answers 404; out-of-range fields answer 400 via the body parsers.
  if (method == 'PATCH' && path.startsWith(adminPricingPlansPrefix)) {
    final tail = _pathSuffix(path, adminPricingPlansPrefix);
    if (tail == null || tail.contains('/')) {
      _writeNotFound(response, request);
      return;
    }
    final tierKey = Uri.decodeComponent(tail);
    if (!kProxyPricingTierTemplateKeys.contains(tierKey)) {
      throw _AdminInputError(
        statusCode: 404,
        code: 'unknown_plan',
        message: 'tier_key "$tierKey" is not a known plan',
      );
    }
    final monthlyUsd = _optionalBodyMoney(body, 'monthly_usd');
    final firstNSeats = _optionalBodyInt(body, 'first_n_seats');
    final firstSeatUsd = _optionalBodyMoney(body, 'first_seat_usd');
    final additionalSeatUsd = _optionalBodyMoney(body, 'additional_seat_usd');
    final onboardingMinUsd = _optionalBodyMoney(body, 'onboarding_min_usd');
    final onboardingMaxUsd = _optionalBodyMoney(body, 'onboarding_max_usd');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.pricing.update_plan_pricing',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final updated = await gateway.updatePlanPricing(
          actorUserId: actorUserId,
          tierKey: tierKey,
          monthlyUsd: monthlyUsd,
          firstNSeats: firstNSeats,
          firstSeatUsd: firstSeatUsd,
          additionalSeatUsd: additionalSeatUsd,
          onboardingMinUsd: onboardingMinUsd,
          onboardingMaxUsd: onboardingMaxUsd,
          adminReason: '$reasonPrefix:plan_pricing:$tierKey',
        );
        if (updated == null) {
          return (
            statusCode: 404,
            payload: <String, Object?>{
              'error': 'unknown_plan',
              'message': 'plan not found',
            },
          );
        }
        return (statusCode: 200, payload: <String, Object?>{'plan': updated});
      },
    );
    return;
  }

  // Phase 5a — GET /v1/admin/pricing/entitlements. Lists the editable
  // feature-entitlements matrix (one row per plan/feature pair). Read-only:
  // no idempotency key (a GET is naturally idempotent). Gated by the read
  // role set in the dispatch layer (super_admin + ff_support).
  if (method == 'GET' && path == adminPricingEntitlementsPath) {
    final entitlements = await gateway.listEntitlements(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:entitlements_list',
    );
    _writeJson(response, 200, <String, Object?>{'entitlements': entitlements});
    return;
  }

  // Phase 5a — PATCH /v1/admin/pricing/entitlements/{tier_key}/{feature_slug}.
  // Toggles one plan/feature pair. Write role set (super_admin only),
  // idempotent + audited like the plan-pricing PATCH: a retried PATCH under
  // the same Idempotency-Key collapses to one toggle + one audit row.
  // Unknown tier_key or feature_slug answers 404; a missing/non-boolean
  // `enabled` answers 400.
  if (method == 'PATCH' && path.startsWith(adminPricingEntitlementsPrefix)) {
    // Two path segments: {tier_key}/{feature_slug}. (_pathSuffix rejects a
    // multi-segment tail, so split the remainder directly like the
    // spend-summary handler.)
    final tail = path.substring(adminPricingEntitlementsPrefix.length);
    final parts = tail.split('/');
    if (parts.length != 2 || parts.any((p) => p.isEmpty)) {
      _writeNotFound(response, request);
      return;
    }
    final tierKey = Uri.decodeComponent(parts[0]);
    final featureSlug = Uri.decodeComponent(parts[1]);
    if (!kProxyPricingTierTemplateKeys.contains(tierKey)) {
      throw _AdminInputError(
        statusCode: 404,
        code: 'unknown_plan',
        message: 'tier_key "$tierKey" is not a known plan',
      );
    }
    if (!kProxyFeatureSlugKeys.contains(featureSlug)) {
      throw _AdminInputError(
        statusCode: 404,
        code: 'unknown_feature',
        message: 'feature_slug "$featureSlug" is not a known feature',
      );
    }
    final enabled = _requireBodyBool(body, 'enabled');
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: idempotencyKey,
      requestType: 'admin.pricing.entitlement_updated',
      actorUserId: actorUserId,
      requestBody: body,
      compute: () async {
        final updated = await gateway.setEntitlement(
          actorUserId: actorUserId,
          tierKey: tierKey,
          featureSlug: featureSlug,
          enabled: enabled,
          adminReason: '$reasonPrefix:entitlement:$tierKey:$featureSlug',
        );
        return (
          statusCode: 200,
          payload: <String, Object?>{'entitlement': updated},
        );
      },
    );
    return;
  }

  _writeNotFound(response, request);
}

bool _isAdminCorpusPath(String path) {
  if (path == adminCorpusVersionsPath ||
      path.startsWith(adminCorpusVersionsPrefix)) {
    return true;
  }
  if (path == adminCorpusUploadPath) return true;
  if (path == adminCorpusPreviewDiffPath) return true;
  if (path == adminCorpusCommitPath) return true;
  if (path == adminCorpusRollbackPath) return true;
  // Phase 11A.3b — graph-candidate review + AGE rebuild stub share
  // the corpus admin CORS preflight (Idempotency-Key allow-listed,
  // GET/POST methods admitted) so the browser preflight succeeds
  // for the new routes too.
  if (_isGraphCandidatesPath(path)) return true;
  if (path == adminAgeRebuildPath) return true;
  return false;
}

bool _isGraphCandidatesPath(String path) =>
    path == adminCorpusGraphCandidatesPath ||
    path == adminCorpusGraphCandidatesCommitPath;

bool _isGraphCandidatesOperation(String path, String method) {
  if (method == 'GET' && path == adminCorpusGraphCandidatesPath) return true;
  if (method == 'POST' && path == adminCorpusGraphCandidatesCommitPath) {
    return true;
  }
  return false;
}

bool _isAgeRebuildOperation(String path, String method) =>
    method == 'POST' && path == adminAgeRebuildPath;

bool _isAdminCorpusOperation(String path, String method) {
  if (method == 'GET' && path == adminCorpusVersionsPath) return true;
  if (method == 'GET' && path.startsWith(adminCorpusVersionsPrefix)) {
    return true;
  }
  if (method == 'POST' && path == adminCorpusUploadPath) return true;
  if (method == 'POST' && path == adminCorpusPreviewDiffPath) return true;
  if (method == 'POST' && path == adminCorpusCommitPath) return true;
  if (method == 'POST' && path == adminCorpusRollbackPath) return true;
  return false;
}

double _requireBodyMoney(Map<String, Object?> body, String field) {
  final raw = body[field];
  if (raw is num) {
    final value = raw.toDouble();
    if (value < 0 || value.isNaN || value.isInfinite) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field must be a finite number >= 0',
      );
    }
    return value;
  }
  if (raw is String) {
    final parsed = double.tryParse(raw);
    if (parsed == null || parsed < 0 || parsed.isNaN || parsed.isInfinite) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field must be a finite number >= 0',
      );
    }
    return parsed;
  }
  throw _AdminInputError(
    statusCode: 400,
    code: 'missing_$field',
    message: '$field is required',
  );
}

/// Phase 3 — parse an OPTIONAL money field that may be a genuine SQL
/// NULL. A missing key or an explicit JSON `null` returns null (e.g.
/// Enterprise has no monthly price; no-seat plans have null seat fees);
/// a present value must be a finite number >= 0. Rejects a wrong type so
/// a malformed body never silently coerces to 0.
double? _optionalBodyMoney(Map<String, Object?> body, String field) {
  final raw = body[field];
  if (raw == null) return null;
  if (raw is num) {
    final value = raw.toDouble();
    if (value < 0 || value.isNaN || value.isInfinite) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field must be a finite number >= 0 or null',
      );
    }
    return value;
  }
  if (raw is String) {
    if (raw.isEmpty) return null;
    final parsed = double.tryParse(raw);
    if (parsed == null || parsed < 0 || parsed.isNaN || parsed.isInfinite) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field must be a finite number >= 0 or null',
      );
    }
    return parsed;
  }
  throw _AdminInputError(
    statusCode: 400,
    code: 'invalid_$field',
    message: '$field must be a number or null',
  );
}

/// Phase 3 — parse an OPTIONAL non-negative integer field that may be a
/// genuine SQL NULL (e.g. the first-seat band size is null for no-seat
/// plans). Rejects negatives, non-integers, and wrong types.
int? _optionalBodyInt(Map<String, Object?> body, String field) {
  final raw = body[field];
  if (raw == null) return null;
  if (raw is int) {
    if (raw < 0) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field must be a non-negative integer or null',
      );
    }
    return raw;
  }
  if (raw is num && raw == raw.roundToDouble()) {
    final value = raw.toInt();
    if (value < 0) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field must be a non-negative integer or null',
      );
    }
    return value;
  }
  if (raw is String) {
    if (raw.isEmpty) return null;
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 0) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field must be a non-negative integer or null',
      );
    }
    return parsed;
  }
  throw _AdminInputError(
    statusCode: 400,
    code: 'invalid_$field',
    message: '$field must be an integer or null',
  );
}

class _AdminInputError implements Exception {
  const _AdminInputError({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;
}

class _OperatorAction {
  const _OperatorAction({required this.operatorId, required this.action});

  final String operatorId;
  final String action;
}

_OperatorAction? _operatorActionFromPath(String path) {
  if (!path.startsWith(adminOperatorsPrefix)) return null;
  final rest = path.substring(adminOperatorsPrefix.length);
  final parts = rest.split('/');
  if (parts.length != 2 || parts.any((part) => part.isEmpty)) return null;
  return _OperatorAction(
    operatorId: Uri.decodeComponent(parts[0]),
    action: Uri.decodeComponent(parts[1]),
  );
}

String _requireBodyString(Map<String, Object?> body, String field) {
  final raw = body[field];
  if (raw is! String || raw.trim().isEmpty) {
    throw _AdminInputError(
      statusCode: 400,
      code: 'missing_$field',
      message: '$field is required',
    );
  }
  return raw.trim();
}

String _requireQueryString(Map<String, String> query, String field) {
  final raw = query[field];
  if (raw == null || raw.trim().isEmpty) {
    throw _AdminInputError(
      statusCode: 400,
      code: 'missing_$field',
      message: '$field is required',
    );
  }
  return raw.trim();
}

String? _optionalQueryString(Map<String, String> query, String field) {
  final raw = query[field];
  if (raw == null || raw.trim().isEmpty) return null;
  return raw.trim();
}

void _validateScopedPricingContractScope({
  required String scopeType,
  String? orgUnitId,
  String? locationId,
}) {
  switch (scopeType) {
    case 'business':
      if (orgUnitId != null || locationId != null) {
        throw const _AdminInputError(
          statusCode: 400,
          code: 'invalid_scope_payload',
          message: 'business scope must not include org_unit_id or location_id',
        );
      }
      return;
    case 'org_unit':
      if (orgUnitId == null || locationId != null) {
        throw const _AdminInputError(
          statusCode: 400,
          code: 'invalid_scope_payload',
          message: 'org_unit scope requires org_unit_id only',
        );
      }
      return;
    case 'location':
      if (locationId == null) {
        throw const _AdminInputError(
          statusCode: 400,
          code: 'invalid_scope_payload',
          message: 'location scope requires location_id',
        );
      }
      return;
    default:
      throw const _AdminInputError(
        statusCode: 400,
        code: 'invalid_scope_type',
        message: 'scope_type must be one of: business, org_unit, location',
      );
  }
}

bool _rejectLegacyCoversSourceWriteKeys(
  HttpResponse response,
  Map<String, Object?> body,
) {
  const legacyFields = <String>{
    'covers_source_lunch',
    'covers_source_dinner',
    'covers_source_late_night',
  };
  if (!legacyFields.any(body.containsKey)) return false;
  _writeJson(response, 410, const <String, Object?>{
    'error': 'legacy_covers_source_write_keys_disabled',
    'message':
        'legacy covers_source_lunch, covers_source_dinner, and '
        'covers_source_late_night write keys are disabled; use '
        'covers_source_per_service_period',
  });
  return true;
}

String? _optionalBodyString(Map<String, Object?> body, String field) {
  if (!body.containsKey(field)) return null;
  final raw = body[field];
  if (raw == null) return null;
  if (raw is! String) {
    throw _AdminInputError(
      statusCode: 400,
      code: 'invalid_$field',
      message: '$field must be a string',
    );
  }
  if (raw.trim().isEmpty) return null;
  return raw.trim();
}

bool _requireBodyBool(Map<String, Object?> body, String field) {
  final raw = body[field];
  if (raw is bool) return raw;
  throw _AdminInputError(
    statusCode: 400,
    code: 'missing_$field',
    message: '$field is required and must be a boolean',
  );
}

bool _optionalBodyBool(Map<String, Object?> body, String field) {
  if (!body.containsKey(field) || body[field] == null) return false;
  final raw = body[field];
  if (raw is bool) return raw;
  throw _AdminInputError(
    statusCode: 400,
    code: 'invalid_$field',
    message: '$field must be a boolean',
  );
}

Map<String, Object?> _optionalBodyObject(
  Map<String, Object?> body,
  String field,
) {
  if (!body.containsKey(field) || body[field] == null) {
    return const <String, Object?>{};
  }
  final raw = body[field];
  if (raw is Map) return raw.cast<String, Object?>();
  throw _AdminInputError(
    statusCode: 400,
    code: 'invalid_$field',
    message: '$field must be a JSON object',
  );
}

DateTime? _optionalBodyDateTime(Map<String, Object?> body, String field) {
  if (!body.containsKey(field) || body[field] == null) return null;
  final raw = body[field];
  if (raw is! String || raw.trim().isEmpty) {
    throw _AdminInputError(
      statusCode: 400,
      code: 'invalid_$field',
      message: '$field must be an ISO-8601 timestamp string',
    );
  }
  try {
    return DateTime.parse(raw.trim()).toUtc();
  } on FormatException {
    throw _AdminInputError(
      statusCode: 400,
      code: 'invalid_$field',
      message: '$field must be an ISO-8601 timestamp string',
    );
  }
}

bool _optionalQueryBool(String? raw, {required bool defaultValue}) {
  if (raw == null || raw.trim().isEmpty) return defaultValue;
  final normalized = raw.trim().toLowerCase();
  if (normalized == 'true' || normalized == '1') return true;
  if (normalized == 'false' || normalized == '0') return false;
  return defaultValue;
}

int? _optionalBodyNonNegativeInt(Map<String, Object?> body, String field) {
  if (!body.containsKey(field)) return null;
  final raw = body[field];
  if (raw == null) return null;
  int? parsed;
  if (raw is int) {
    parsed = raw;
  } else if (raw is num && raw == raw.roundToDouble()) {
    parsed = raw.toInt();
  } else if (raw is String && raw.trim().isNotEmpty) {
    parsed = int.tryParse(raw.trim());
  }
  if (parsed == null || parsed < 0) {
    throw _AdminInputError(
      statusCode: 400,
      code: 'invalid_$field',
      message: '$field must be an integer >= 0',
    );
  }
  return parsed;
}

Map<String, int>? _optionalBodyPositiveIntMap(
  Map<String, Object?> body,
  String field,
) {
  if (!body.containsKey(field)) return null;
  final raw = body[field];
  if (raw == null) return null;
  if (raw is! Map) {
    throw _AdminInputError(
      statusCode: 400,
      code: 'invalid_$field',
      message: '$field must be an object of positive integer values',
    );
  }
  final out = <String, int>{};
  raw.forEach((key, value) {
    if (key is! String || key.trim().isEmpty) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field keys must be non-empty strings',
      );
    }
    int? parsed;
    if (value is int) {
      parsed = value;
    } else if (value is num && value == value.roundToDouble()) {
      parsed = value.toInt();
    } else if (value is String && value.trim().isNotEmpty) {
      parsed = int.tryParse(value.trim());
    }
    if (parsed == null || parsed <= 0) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field values must be positive integers',
      );
    }
    out[key.trim()] = parsed;
  });
  return out;
}

Map<String, int>? _optionalBodyNonNegativeIntMap(
  Map<String, Object?> body,
  String field,
) {
  if (!body.containsKey(field)) return null;
  final raw = body[field];
  if (raw == null) return null;
  if (raw is! Map) {
    throw _AdminInputError(
      statusCode: 400,
      code: 'invalid_$field',
      message: '$field must be an object of non-negative integer values',
    );
  }
  final out = <String, int>{};
  raw.forEach((key, value) {
    if (key is! String || key.trim().isEmpty) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field keys must be non-empty strings',
      );
    }
    int? parsed;
    if (value is int) {
      parsed = value;
    } else if (value is num && value == value.roundToDouble()) {
      parsed = value.toInt();
    } else if (value is String && value.trim().isNotEmpty) {
      parsed = int.tryParse(value.trim());
    }
    if (parsed == null || parsed < 0) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field values must be non-negative integers',
      );
    }
    out[key.trim()] = parsed;
  });
  return out;
}

Map<String, Map<String, int>>? _optionalBodyNestedNonNegativeIntMap(
  Map<String, Object?> body,
  String field,
) {
  if (!body.containsKey(field)) return null;
  final raw = body[field];
  if (raw == null) return null;
  if (raw is! Map) {
    throw _AdminInputError(
      statusCode: 400,
      code: 'invalid_$field',
      message:
          '$field must be an object of objects with non-negative integer values',
    );
  }
  final out = <String, Map<String, int>>{};
  raw.forEach((key, value) {
    if (key is! String || key.trim().isEmpty) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field keys must be non-empty strings',
      );
    }
    if (value is! Map) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field values must be objects',
      );
    }
    out[key.trim()] = _requiredNonNegativeIntMap(value, field);
  });
  return out;
}

Map<String, int> _requiredNonNegativeIntMap(
  Map<dynamic, dynamic> raw,
  String field,
) {
  final out = <String, int>{};
  raw.forEach((key, value) {
    if (key is! String || key.trim().isEmpty) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field nested keys must be non-empty strings',
      );
    }
    int? parsed;
    if (value is int) {
      parsed = value;
    } else if (value is num && value == value.roundToDouble()) {
      parsed = value.toInt();
    } else if (value is String && value.trim().isNotEmpty) {
      parsed = int.tryParse(value.trim());
    }
    if (parsed == null || parsed < 0) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field nested values must be non-negative integers',
      );
    }
    out[key.trim()] = parsed;
  });
  return out;
}

Map<String, String>? _optionalBodyStringMap(
  Map<String, Object?> body,
  String field,
) {
  if (!body.containsKey(field)) return null;
  final raw = body[field];
  if (raw == null) return null;
  if (raw is! Map) {
    throw _AdminInputError(
      statusCode: 400,
      code: 'invalid_$field',
      message: '$field must be an object of string values',
    );
  }
  final out = <String, String>{};
  raw.forEach((key, value) {
    if (key is! String || key.trim().isEmpty) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field keys must be non-empty strings',
      );
    }
    if (value is! String || value.trim().isEmpty) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field values must be non-empty strings',
      );
    }
    out[key.trim()] = value.trim();
  });
  return out;
}

List<String>? _optionalBodyStringList(Map<String, Object?> body, String field) {
  if (!body.containsKey(field)) return null;
  final raw = body[field];
  if (raw == null) return null;
  if (raw is! List) {
    throw _AdminInputError(
      statusCode: 400,
      code: 'invalid_$field',
      message: '$field must be an array of strings',
    );
  }
  final out = <String>[];
  for (final value in raw) {
    if (value is! String || value.trim().isEmpty) {
      throw _AdminInputError(
        statusCode: 400,
        code: 'invalid_$field',
        message: '$field entries must be non-empty strings',
      );
    }
    out.add(value.trim());
  }
  return out;
}

String _requireBodyCurrency(Map<String, Object?> body, String field) {
  final raw = _requireBodyString(body, field).toUpperCase();
  if (!RegExp(r'^[A-Z]{3}$').hasMatch(raw)) {
    throw _AdminInputError(
      statusCode: 400,
      code: 'invalid_$field',
      message: '$field must be a 3-letter ISO currency code',
    );
  }
  return raw;
}

String _requireBodyTimezone(Map<String, Object?> body, String field) {
  final raw = _requireBodyString(body, field);
  if (!_isLikelyIanaTimezoneInternal(raw)) {
    throw _AdminInputError(
      statusCode: 400,
      code: 'invalid_$field',
      message: '$field must be an IANA timezone (e.g. America/Toronto)',
    );
  }
  return raw;
}

int _requireBodyRolloverHour(Map<String, Object?> body, String field) {
  final raw = body[field];
  if (raw is! int) {
    throw _AdminInputError(
      statusCode: 400,
      code: 'invalid_$field',
      message: '$field must be an integer between 0 and 23',
    );
  }
  if (raw < 0 || raw > 23) {
    throw _AdminInputError(
      statusCode: 400,
      code: 'invalid_$field',
      message: '$field must be between 0 and 23',
    );
  }
  return raw;
}

/// Same catalog-backed validation as the admin client.
bool _isLikelyIanaTimezoneInternal(String value) {
  return isValidIanaTimezoneName(value);
}

Future<ProxyJwtClaims?> _resolveVerifiedClaimsOrWrite(
  HttpRequest request,
  HttpResponse response,
  ProxyRequestGuard authGuard,
) async {
  try {
    return await authGuard.requireVerifiedClaims(
      authorizationHeader: request.headers.value(
        HttpHeaders.authorizationHeader,
      ),
    );
  } on ProxyAuthError catch (error) {
    _writeJson(response, error.statusCode, <String, Object?>{
      'error': error.message,
    });
    return null;
  }
}

Future<void> _routeMobileOperationalSync({
  required HttpRequest request,
  required HttpResponse response,
  required ProxyRequestGuard authGuard,
  required MobileOperationalSyncProxyGateway? gateway,
  required BusinessScopeProxyGateway? businessScopeGateway,
  required _MobileOperationalPath target,
}) async {
  if (gateway == null) {
    _writeJson(response, 503, <String, Object?>{
      'error': 'mobile_operational_sync_not_configured',
      'message':
          'route requires a MobileOperationalSyncProxyGateway to be installed',
    });
    return;
  }

  final scope = await _resolveLocationReadContextOrWrite(
    request: request,
    response: response,
    authGuard: authGuard,
    operatorId: target.operatorId,
    locationId: target.locationId,
  );
  if (scope == null) return;

  if (!await _operatorLocationScopeAllowed(
    scope: scope,
    operatorId: target.operatorId,
    locationId: target.locationId,
    businessScopeGateway: businessScopeGateway,
  )) {
    _writeJson(response, 403, <String, Object?>{
      'error': 'permission_denied',
      'message': 'requested mobile sync scope does not match caller scope',
    });
    return;
  }

  final params = request.uri.queryParameters;
  final pageSize = _mobileSyncPageSizeOrWrite(response, params['page_size']);
  if (pageSize == null) return;
  final modifiedSince =
      _nonBlankString(params['modified_since']) ??
      _nonBlankString(params['cursor']);
  if (!_mobileSyncCursorValidOrWrite(response, modifiedSince)) return;
  final includeHierarchy = _optionalQueryBool(
    params['include_hierarchy'],
    defaultValue: false,
  );
  final businessDate = _nonBlankString(params['business_date']);
  if (target.resource == 'timing/resolved' &&
      businessDate != null &&
      !_isYyyyMmDdCalendarDate(businessDate)) {
    _writeJson(response, 400, <String, Object?>{
      'error': 'invalid_business_date',
      'message': 'business_date must be an ISO calendar date (YYYY-MM-DD)',
    });
    return;
  }

  try {
    final payload = switch (target.resource) {
      'shift_records' => await gateway.fetchShiftRecords(
        scope: scope,
        operatorId: target.operatorId,
        locationId: target.locationId,
        modifiedSince: modifiedSince,
        pageSize: pageSize,
      ),
      'open_shift_snapshots' => await gateway.fetchOpenShiftSnapshots(
        scope: scope,
        operatorId: target.operatorId,
        locationId: target.locationId,
        modifiedSince: modifiedSince,
        pageSize: pageSize,
      ),
      'timing/resolved' => await gateway.fetchResolvedTimingConfig(
        scope: scope,
        operatorId: target.operatorId,
        locationId: target.locationId,
        businessDate: businessDate,
      ),
      'demo_mode_states' => await gateway.fetchDemoModeStates(
        scope: scope,
        operatorId: target.operatorId,
        locationId: target.locationId,
      ),
      'data_accuracy_settings' => await gateway.fetchDataAccuracySettings(
        scope: scope,
        operatorId: target.operatorId,
        locationId: target.locationId,
      ),
      'data_accuracy_service_period_settings' =>
        await gateway.fetchDataAccuracyServicePeriodSettings(
          scope: scope,
          operatorId: target.operatorId,
          locationId: target.locationId,
        ),
      'wage_role_rows' => await gateway.fetchWageRoleRows(
        scope: scope,
        operatorId: target.operatorId,
        locationId: target.locationId,
        modifiedSince: modifiedSince,
        pageSize: pageSize,
        includeHierarchy: includeHierarchy,
      ),
      'polling_tier_assignment' => await gateway.fetchPollingTierAssignment(
        scope: scope,
        operatorId: target.operatorId,
        locationId: target.locationId,
      ),
      'first_backfill_status' => await gateway.fetchFirstBackfillStatus(
        scope: scope,
        operatorId: target.operatorId,
        locationId: target.locationId,
      ),
      _ => throw const MobileOperationalSyncProxyGatewayException(
        statusCode: 404,
        code: 'mobile_sync_route_not_found',
        message: 'mobile sync route not found',
      ),
    };
    _writeJson(response, 200, payload);
  } on MobileOperationalSyncProxyGatewayException catch (error) {
    _writeJson(response, error.statusCode, <String, Object?>{
      'error': error.code,
      'message': error.message,
    });
  } catch (error, stackTrace) {
    if (_maybeWriteDependencyTimeout(response, error)) return;
    _logProxyUnhandled(
      surface: 'mobile_operational_sync',
      method: request.method,
      path: request.uri.path,
      error: error,
      stackTrace: stackTrace,
    );
    _writeJson(response, 503, <String, Object?>{
      'error': 'mobile_operational_sync_unavailable',
      'message': 'mobile operational sync is unavailable; please retry',
    });
  }
}

const Set<String> _operatorDataAccuracyWriteRoles = <String>{'operator_owner'};

Future<void> _routeOperatorDataAccuracySettingsWrite({
  required HttpRequest request,
  required HttpResponse response,
  required ProxyRequestGuard authGuard,
  required MobileOperationalSyncProxyGateway? gateway,
  required BusinessScopeProxyGateway? businessScopeGateway,
  required AdminRequestIdempotencyStore? idempotencyStore,
  required _MobileOperationalPath target,
}) async {
  if (gateway == null) {
    _writeJson(response, 503, <String, Object?>{
      'error': 'mobile_operational_sync_not_configured',
      'message':
          'route requires a MobileOperationalSyncProxyGateway to be installed',
    });
    return;
  }

  final claims = await _resolveVerifiedClaimsOrWrite(
    request,
    response,
    authGuard,
  );
  if (claims == null) return;
  if (!_rolesIntersect(claims.roles, _operatorDataAccuracyWriteRoles)) {
    _writeJson(response, 403, <String, Object?>{
      'error': 'permission_denied',
      'message': 'operator data accuracy writes require owner role',
    });
    return;
  }

  final actorOperatorId = _nonBlankString(claims.operatorId);
  final actorLocationId = _nonBlankString(claims.locationId);
  if (actorOperatorId == null ||
      actorLocationId == null ||
      actorOperatorId != target.operatorId) {
    _writeJson(response, 403, <String, Object?>{
      'error': 'permission_denied',
      'message': 'verified token scope does not match requested operator',
    });
    return;
  }

  final actorScope = _operatorContextFromClaims(
    claims,
    operatorId: actorOperatorId,
    locationId: actorLocationId,
  );
  if (!await _operatorLocationScopeAllowed(
    scope: actorScope,
    operatorId: target.operatorId,
    locationId: target.locationId,
    businessScopeGateway: businessScopeGateway,
  )) {
    _writeJson(response, 403, <String, Object?>{
      'error': 'permission_denied',
      'message': 'requested data accuracy scope does not match caller access',
    });
    return;
  }

  final bodyResult = await readOperatorJsonBody(request);
  if (bodyResult.errorStatus != null) {
    _writeJson(response, bodyResult.errorStatus!, bodyResult.errorBody!);
    return;
  }

  // Doc 1 keyed-data-accuracy-write — defence-in-depth body validation
  // for the keyed service-period write surface. The production gateway
  // also validates inside `upsertDataAccuracyServicePeriodSettings`
  // (proxy_bootstrap.dart `_bodyServicePeriodKey` /
  // `_bodyBusinessDate`); validating here too means alternate gateway
  // impls (test fakes, future per-tenant routers) cannot accept a
  // malformed key or business date, and the operator-web client gets a
  // 400 envelope back before any gateway work.
  if (target.resource == 'data_accuracy_service_period_settings') {
    final clearRaw = bodyResult.body!['clear'];
    final keyError = clearRaw == true
        ? _validateServicePeriodClearBody(bodyResult.body!)
        : _validateServicePeriodWriteBody(bodyResult.body!);
    if (keyError != null) {
      _writeJson(response, keyError.$1, keyError.$2);
      return;
    }
  } else if (target.resource == 'data_accuracy_settings/manual_covers') {
    final keyError = _validateManualCoversWriteBody(bodyResult.body!);
    if (keyError != null) {
      _writeJson(response, keyError.$1, keyError.$2);
      return;
    }
  }
  if (target.resource == 'data_accuracy_settings' &&
      _rejectLegacyCoversSourceWriteKeys(response, bodyResult.body!)) {
    return;
  }

  try {
    final writeScope = _operatorContextFromClaims(
      claims,
      operatorId: target.operatorId,
      locationId: target.locationId,
    );
    final idempotencyKey = request.headers.value('Idempotency-Key')?.trim();
    if (idempotencyKey == null || idempotencyKey.isEmpty) {
      _writeJson(response, 400, <String, Object?>{
        'error': 'idempotency_key_missing',
        'message': 'Idempotency-Key header is required',
      });
      return;
    }
    if (idempotencyKey.length > 200) {
      _writeJson(response, 400, <String, Object?>{
        'error': 'idempotency_key_too_long',
        'message': 'Idempotency-Key header must be 200 characters or fewer',
      });
      return;
    }
    final clearServicePeriod =
        target.resource == 'data_accuracy_service_period_settings' &&
        bodyResult.body!['clear'] == true;
    final requestType = switch (target.resource) {
      'data_accuracy_service_period_settings' =>
        clearServicePeriod
            ? 'operator.data_accuracy.service_period.clear'
            : 'operator.data_accuracy.service_period.patch',
      'data_accuracy_settings/manual_covers' =>
        'operator.data_accuracy.manual_covers.patch',
      _ => 'operator.data_accuracy.settings.patch',
    };
    final scopedIdempotencyKey =
        'operator:${target.operatorId}:location:${target.locationId}:'
        '$idempotencyKey';
    await _runAdminIdempotent(
      response: response,
      store: idempotencyStore,
      idempotencyKey: scopedIdempotencyKey,
      requestType: requestType,
      actorUserId: claims.userId,
      requestBody: bodyResult.body!,
      compute: () async {
        final result = switch (target.resource) {
          'data_accuracy_service_period_settings' =>
            clearServicePeriod
                ? await gateway.clearDataAccuracyServicePeriodSettings(
                    scope: writeScope,
                    operatorId: target.operatorId,
                    locationId: target.locationId,
                    body: bodyResult.body!,
                  )
                : await gateway.upsertDataAccuracyServicePeriodSettings(
                    scope: writeScope,
                    operatorId: target.operatorId,
                    locationId: target.locationId,
                    body: bodyResult.body!,
                  ),
          'data_accuracy_settings/manual_covers' =>
            await gateway.upsertDataAccuracyManualCovers(
              scope: writeScope,
              operatorId: target.operatorId,
              locationId: target.locationId,
              body: bodyResult.body!,
            ),
          _ => await gateway.upsertDataAccuracySettings(
            scope: writeScope,
            operatorId: target.operatorId,
            locationId: target.locationId,
            body: bodyResult.body!,
          ),
        };
        return (statusCode: 200, payload: result);
      },
    );
  } on AdminIdempotencyKeyConflict catch (error) {
    _writeJson(response, 409, <String, Object?>{
      'error': 'idempotency_key_conflict',
      'message': error.message,
    });
  } on MobileOperationalSyncProxyGatewayException catch (error) {
    _writeJson(response, error.statusCode, <String, Object?>{
      'error': error.code,
      'message': error.message,
    });
  } catch (error, stackTrace) {
    if (_maybeWriteDependencyTimeout(response, error)) return;
    _logProxyUnhandled(
      surface: 'operator_data_accuracy',
      method: request.method,
      path: request.uri.path,
      error: error,
      stackTrace: stackTrace,
    );
    _writeJson(response, 503, <String, Object?>{
      'error': 'operator_data_accuracy_unavailable',
      'message': 'data accuracy settings are unavailable; please retry',
    });
  }
}

/// Doc 1 keyed-data-accuracy-write — body validator for the keyed
/// service-period PATCH route. Returns `null` when the body is valid;
/// otherwise returns `(statusCode, jsonEnvelope)` ready to write back.
///
/// Validates the same shape the production gateway enforces (mirrors
/// `proxy_bootstrap.dart::_bodyServicePeriodKey` /
/// `_bodyBusinessDate` /
/// `_bodyServicePeriodCoversSource` / `_bodyServicePeriodWageSource`)
/// so test fakes cannot drift from the production envelope.
(int, Map<String, Object?>)? _validateServicePeriodWriteBody(
  Map<String, Object?> body,
) {
  final clearRaw = body['clear'];
  if (clearRaw != null && clearRaw is! bool) {
    return (
      400,
      <String, Object?>{
        'error': 'invalid_clear',
        'message': 'clear must be true or false',
      },
    );
  }
  if (clearRaw == true) return _validateServicePeriodClearBody(body);
  final keyRaw = body['service_period_key'];
  if (keyRaw is! String ||
      !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(keyRaw)) {
    return (
      400,
      <String, Object?>{
        'error': 'invalid_service_period_key',
        'message':
            'service_period_key must start with a lowercase letter and contain '
            'only lowercase letters, numbers, or underscores',
      },
    );
  }
  final dateRaw = body['effective_at_business_date'];
  if (dateRaw is! String || !_isYyyyMmDdCalendarDate(dateRaw)) {
    return (
      400,
      <String, Object?>{
        'error': 'invalid_effective_at_business_date',
        'message':
            'effective_at_business_date must be a YYYY-MM-DD business date',
      },
    );
  }
  final coversRaw = body['covers_source'];
  if (coversRaw != null) {
    const allowed = <String>{
      'vendor',
      'forecast',
      'manual',
      'reservation_plus_walkin',
    };
    if (coversRaw is! String || !allowed.contains(coversRaw)) {
      return (
        400,
        <String, Object?>{
          'error': 'invalid_covers_source',
          'message':
              'covers_source must be vendor, forecast, manual, or '
              'reservation_plus_walkin',
        },
      );
    }
  }
  final wageRaw = body['wage_source'];
  if (wageRaw != null) {
    const allowed = <String>{
      'vendor_per_employee',
      'vendor_per_position',
      'target_substitution',
      'manual_mix',
    };
    if (wageRaw is! String || !allowed.contains(wageRaw)) {
      return (
        400,
        <String, Object?>{
          'error': 'invalid_wage_source',
          'message':
              'wage_source must be vendor_per_employee, vendor_per_position, '
              'target_substitution, or manual_mix',
        },
      );
    }
  }
  return null;
}

(int, Map<String, Object?>)? _validateServicePeriodClearBody(
  Map<String, Object?> body,
) {
  final keyRaw = body['service_period_key'];
  if (keyRaw is! String ||
      !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(keyRaw)) {
    return (
      400,
      <String, Object?>{
        'error': 'invalid_service_period_key',
        'message':
            'service_period_key must start with a lowercase letter and contain '
            'only lowercase letters, numbers, or underscores',
      },
    );
  }
  final clearRaw = body['clear'];
  if (clearRaw is! bool) {
    return (
      400,
      <String, Object?>{
        'error': 'invalid_clear',
        'message': 'clear must be true or false',
      },
    );
  }
  if (clearRaw != true) {
    return (
      400,
      <String, Object?>{
        'error': 'invalid_clear',
        'message': 'clear must be true for reset requests',
      },
    );
  }
  const forbidden = <String>{
    'covers_source',
    'wage_source',
    'effective_at_business_date',
  };
  final present = forbidden.where(body.containsKey).toList(growable: false);
  if (present.isNotEmpty) {
    return (
      400,
      <String, Object?>{
        'error': 'invalid_service_period_clear',
        'message':
            'clear service-period requests must not include ${present.join(', ')}',
      },
    );
  }
  return null;
}

(int, Map<String, Object?>)? _validateManualCoversWriteBody(
  Map<String, Object?> body,
) {
  final keyRaw = body['service_period_key'];
  if (keyRaw is! String ||
      !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(keyRaw)) {
    return (
      400,
      <String, Object?>{
        'error': 'invalid_service_period_key',
        'message':
            'service_period_key must start with a lowercase letter and contain '
            'only lowercase letters, numbers, or underscores',
      },
    );
  }
  final dateRaw = body['business_date'];
  if (dateRaw is! String || !_isYyyyMmDdCalendarDate(dateRaw)) {
    return (
      400,
      <String, Object?>{
        'error': 'invalid_business_date',
        'message': 'business_date must be a YYYY-MM-DD business date',
      },
    );
  }
  final clearRaw = body['clear'];
  if (clearRaw != null && clearRaw is! bool) {
    return (
      400,
      <String, Object?>{
        'error': 'invalid_clear',
        'message': 'clear must be true or false',
      },
    );
  }
  if (clearRaw == true) {
    if (body.containsKey('covers')) {
      return (
        400,
        <String, Object?>{
          'error': 'invalid_manual_covers_clear',
          'message': 'clear manual covers requests must not include covers',
        },
      );
    }
    return null;
  }
  final coversRaw = body['covers'];
  final covers = coversRaw is int
      ? coversRaw
      : coversRaw is num && coversRaw == coversRaw.roundToDouble()
      ? coversRaw.toInt()
      : coversRaw is String
      ? int.tryParse(coversRaw.trim())
      : null;
  if (covers == null || covers < 0) {
    return (
      400,
      <String, Object?>{
        'error': 'invalid_covers',
        'message': 'covers must be a non-negative integer',
      },
    );
  }
  return null;
}

bool _isYyyyMmDdCalendarDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final parsed = DateTime.tryParse('${value}T00:00:00Z');
  if (parsed == null) return false;
  final year = int.parse(value.substring(0, 4));
  final month = int.parse(value.substring(5, 7));
  final day = int.parse(value.substring(8, 10));
  return parsed.year == year && parsed.month == month && parsed.day == day;
}

Future<bool> _operatorLocationScopeAllowed({
  required OperatorContext scope,
  required String operatorId,
  required String locationId,
  required BusinessScopeProxyGateway? businessScopeGateway,
}) async {
  if (scope.operatorId == operatorId && scope.locationId == locationId) {
    return true;
  }
  if (scope.operatorId != operatorId || businessScopeGateway == null) {
    return false;
  }
  return businessScopeGateway.canAccessLocation(
    userId: scope.userId,
    operatorId: operatorId,
    locationId: locationId,
  );
}

int? _mobileSyncPageSizeOrWrite(HttpResponse response, String? raw) {
  if (raw == null || raw.trim().isEmpty) return 200;
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed <= 0 || parsed > 500) {
    _writeJson(response, 400, <String, Object?>{
      'error': 'invalid_page_size',
      'message': 'page_size must be a positive integer no greater than 500',
    });
    return null;
  }
  return parsed;
}

bool _mobileSyncCursorValidOrWrite(HttpResponse response, String? cursor) {
  if (cursor == null) return true;
  if (DateTime.tryParse(cursor) != null) return true;
  _writeJson(response, 400, <String, Object?>{
    'error': 'invalid_modified_since',
    'message': 'modified_since must be an ISO-8601 timestamp',
  });
  return false;
}

_MobileOperationalPath? _mobileOperationalPath(String path) {
  if (!path.startsWith(mobileOperatorsPrefix)) return null;
  final tail = path.substring(mobileOperatorsPrefix.length);
  final parts = tail.split('/');
  if (parts.length < 4 || parts[1] != 'locations') return null;
  final resource = parts.sublist(3).join('/');
  if (resource.isEmpty) return null;
  switch (resource) {
    case 'shift_records':
    case 'open_shift_snapshots':
    case 'timing/resolved':
    case 'demo_mode_states':
    case 'data_accuracy_settings':
    case 'data_accuracy_settings/manual_covers':
    case 'data_accuracy_service_period_settings':
    case 'wage_role_rows':
    case 'polling_tier_assignment':
    case 'first_backfill_status':
      return _MobileOperationalPath(
        operatorId: Uri.decodeComponent(parts[0]),
        locationId: Uri.decodeComponent(parts[2]),
        resource: resource,
      );
  }
  return null;
}

class _MobileOperationalPath {
  const _MobileOperationalPath({
    required this.operatorId,
    required this.locationId,
    required this.resource,
  });

  final String operatorId;
  final String locationId;
  final String resource;
}

const Set<String> _globalMobileLocationReadRoles = <String>{
  'super_admin',
  'ff_support',
};

Future<OperatorContext?> _resolveLocationReadContextOrWrite({
  required HttpRequest request,
  required HttpResponse response,
  required ProxyRequestGuard authGuard,
  required String operatorId,
  required String locationId,
}) async {
  final claims = await _resolveVerifiedClaimsOrWrite(
    request,
    response,
    authGuard,
  );
  if (claims == null) return null;

  if (_rolesIntersect(claims.roles, _globalMobileLocationReadRoles)) {
    bindOperatorIdToLogContext(operatorId);
    return _operatorContextFromClaims(
      claims,
      operatorId: operatorId,
      locationId: locationId,
    );
  }

  final scopedOperatorId = _nonBlankString(claims.operatorId);
  final scopedLocationId = _nonBlankString(claims.locationId);
  if (scopedOperatorId == null || scopedLocationId == null) {
    _writeJson(response, 403, <String, Object?>{
      'error': 'permission_denied',
      'message': 'verified token is missing operator or location scope',
    });
    return null;
  }
  bindOperatorIdToLogContext(scopedOperatorId);
  return _operatorContextFromClaims(
    claims,
    operatorId: scopedOperatorId,
    locationId: scopedLocationId,
  );
}

OperatorContext _operatorContextFromClaims(
  ProxyJwtClaims claims, {
  required String operatorId,
  required String locationId,
}) {
  return OperatorContext(
    userId: claims.userId,
    operatorId: operatorId,
    locationId: locationId,
    roles: claims.roles,
    actorKind: claims.actorKind,
    servicePrincipalId: claims.servicePrincipalId,
    firebaseUid: claims.firebaseUid,
    rolesVersion:
        claims.rolesVersion ??
        ProxyRequestGuard._rolesVersionFromRoles(claims.roles),
    lastFreshAuthAt: claims.lastFreshAuthAt,
  );
}

bool _rolesIntersect(List<String> roles, Set<String> allowedRoles) {
  for (final role in roles) {
    if (allowedRoles.contains(role)) return true;
  }
  return false;
}

Future<OperatorContext?> _resolveOperatorContextOrWrite(
  HttpRequest request,
  HttpResponse response,
  ProxyRequestGuard authGuard,
) async {
  try {
    return await authGuard.requireOperatorContext(
      authorizationHeader: request.headers.value(
        HttpHeaders.authorizationHeader,
      ),
    );
  } on ProxyAuthError catch (error) {
    _writeJson(response, error.statusCode, <String, Object?>{
      'error': error.message,
    });
    return null;
  }
}

OperatorContext _effectiveAdminAuthScope({
  required HttpRequest request,
  required Map<String, Object?> body,
  required OperatorContext callerScope,
}) {
  final params = request.uri.queryParameters;
  final operatorId =
      _nonBlankString(body['operator_id']) ??
      _nonBlankString(params['operator_id']) ??
      callerScope.operatorId;
  final locationId =
      _nonBlankString(body['location_id']) ??
      _nonBlankString(body['primary_location_id']) ??
      _nonBlankString(body['target_location_id']) ??
      _nonBlankString(params['location_id']) ??
      callerScope.locationId;
  if (operatorId == callerScope.operatorId &&
      locationId == callerScope.locationId) {
    return callerScope;
  }
  bindOperatorIdToLogContext(operatorId);
  return OperatorContext(
    userId: callerScope.userId,
    operatorId: operatorId,
    locationId: locationId,
    roles: callerScope.roles,
    actorKind: callerScope.actorKind,
    servicePrincipalId: callerScope.servicePrincipalId,
    firebaseUid: callerScope.firebaseUid,
    rolesVersion: callerScope.rolesVersion,
    lastFreshAuthAt: callerScope.lastFreshAuthAt,
  );
}

bool _operatorContextHasAnyRole(
  OperatorContext scope,
  Set<String> allowedRoles,
) {
  for (final role in scope.roles) {
    if (allowedRoles.contains(role)) return true;
  }
  return false;
}

bool _requireFreshAuthenticationOrWrite({
  required HttpResponse response,
  required OperatorContext scope,
  required DateTime requestedAt,
}) {
  const freshnessWindow = Duration(minutes: 5);
  final lastFreshAuthAt = scope.lastFreshAuthAt;
  if (lastFreshAuthAt != null &&
      requestedAt.difference(lastFreshAuthAt.toUtc()) <= freshnessWindow) {
    return true;
  }
  _writeJson(response, 403, <String, Object?>{
    'error': 'mfa_freshness_required',
    'message': 'Sign in again before removing MFA.',
    if (lastFreshAuthAt != null)
      'refresh_after': lastFreshAuthAt
          .toUtc()
          .add(freshnessWindow)
          .toIso8601String(),
  });
  return false;
}

/// Claims-shaped variant of [_requireFreshAuthenticationOrWrite] used
/// by global admin surfaces (no operator context). Same contract:
/// returns true iff the caller's `lastFreshAuthAt` falls inside the
/// 5-minute freshness window; otherwise writes a 403 and returns
/// false. The caller passes a [message] so the response can name the
/// specific MFA-required action (e.g. rotating a provider key).
bool _requireFreshClaimsOrWrite({
  required HttpResponse response,
  required ProxyJwtClaims claims,
  required DateTime requestedAt,
  required String message,
}) {
  const freshnessWindow = Duration(minutes: 5);
  final lastFreshAuthAt = claims.lastFreshAuthAt;
  if (lastFreshAuthAt != null &&
      requestedAt.difference(lastFreshAuthAt.toUtc()) <= freshnessWindow) {
    return true;
  }
  _writeJson(response, 403, <String, Object?>{
    'error': 'mfa_freshness_required',
    'message': message,
    if (lastFreshAuthAt != null)
      'refresh_after': lastFreshAuthAt
          .toUtc()
          .add(freshnessWindow)
          .toIso8601String(),
  });
  return false;
}

String _freshAuthProofId({
  required OperatorContext scope,
  required String path,
  required DateTime requestedAt,
}) {
  final freshAt = scope.lastFreshAuthAt?.toUtc();
  if (freshAt == null) return '';
  final raw = utf8.encode(
    [
      'fresh-auth-v1',
      scope.userId,
      scope.operatorId,
      scope.locationId,
      path,
      freshAt.toIso8601String(),
      requestedAt.toUtc().toIso8601String(),
    ].join('|'),
  );
  return 'fresh-auth:${sha256.convert(raw)}';
}

bool _isAdminAuthOperation(String path, String method) {
  // Wave 2 W-3 — self-service profile editor. Same dispatch as the
  // admin auth-ops routes; permission gate is `team.users.self_update`.
  if (method == 'PATCH' && path == authSelfProfilePath) {
    return true;
  }
  final p = _canonicalAuthOperationPath(path);
  if (method == 'GET' && p == adminAuthRolesPath) {
    return true;
  }
  if (method == 'POST' && p == adminAuthRolesPath) {
    return true;
  }
  if (method == 'POST' &&
      path.startsWith(adminAuthRolePrefix) &&
      path.endsWith('/permissions')) {
    return true;
  }
  if (method == 'PATCH' && p.startsWith(adminAuthRolePrefix)) {
    return true;
  }
  if (method == 'DELETE' && p.startsWith(adminAuthRolePrefix)) {
    return true;
  }
  if (method == 'GET' && p == adminAuthUsersPath) {
    return true;
  }
  if (method == 'PATCH' && p.startsWith(adminAuthUsersPrefix)) {
    return true;
  }
  // CODE_OPS_DEBT Theme B#1 — GET .../erase-pii for status read.
  if (method == 'GET' &&
      p.startsWith(adminAuthUsersPrefix) &&
      _piiErasurePathFromAdminAuthUsersPrefix(p) != null) {
    return true;
  }
  if (method == 'GET' && p == adminAuthSessionsPath) {
    return true;
  }
  if (method == 'GET' && p == adminAuthAuditLogPath) {
    return true;
  }
  if (method == 'GET' && p == adminAuthInvitesPath) {
    return true;
  }
  if (method == 'POST' && p == adminAuthInvitesPath) {
    return true;
  }
  if (method == 'DELETE' && p.startsWith(adminAuthInvitePrefix)) {
    return true;
  }
  if (method == 'POST' && p.startsWith(adminAuthUsersPrefix)) {
    return true;
  }
  if (method == 'POST' && p.startsWith(adminAuthSessionsPrefix)) {
    return true;
  }
  if (method == 'POST' && p == adminAuthRoleGrantsPath) {
    return true;
  }
  if (method == 'DELETE' && p.startsWith(adminAuthRoleGrantPrefix)) {
    return true;
  }
  if (method == 'GET' && p == adminAuthOrgUnitsPath) {
    return true;
  }
  if (method == 'POST' && p == adminAuthOrgUnitsPath) {
    return true;
  }
  // `/parent` = move, `/name` = GAP A1 rename (both PATCH).
  if (method == 'PATCH' &&
      p.startsWith(adminAuthOrgUnitPrefix) &&
      (p.endsWith('/parent') || p.endsWith('/name'))) {
    return true;
  }
  if (p.startsWith(adminAuthOrgUnitPrefix) &&
      ((method == 'PATCH' &&
              (p.endsWith('/suspend') || p.endsWith('/reactivate'))) ||
          (method == 'POST' && p.endsWith('/delete')))) {
    return true;
  }
  if (method == 'PATCH' &&
      p.startsWith(adminAuthLocationsPrefix) &&
      p.endsWith('/org-unit')) {
    return true;
  }
  if (p.startsWith(adminAuthLocationsPrefix) &&
      ((method == 'PATCH' &&
              (p.endsWith('/suspend') || p.endsWith('/reactivate'))) ||
          (method == 'POST' && p.endsWith('/delete')))) {
    return true;
  }
  return false;
}

final List<AuthOperationPathTranslationEntry>
_authOpsPathTable = <AuthOperationPathTranslationEntry>[
  (teamPath: authTeamRolesPath, adminPath: adminAuthRolesPath, isPrefix: false),
  (
    teamPath: authTeamRolePrefix,
    adminPath: adminAuthRolePrefix,
    isPrefix: true,
  ),
  (
    teamPath: authTeamRoleGrantsPath,
    adminPath: adminAuthRoleGrantsPath,
    isPrefix: false,
  ),
  (
    teamPath: authTeamRoleGrantPrefix,
    adminPath: adminAuthRoleGrantPrefix,
    isPrefix: true,
  ),
  (teamPath: authTeamUsersPath, adminPath: adminAuthUsersPath, isPrefix: false),
  (
    teamPath: authTeamUsersPrefix,
    adminPath: adminAuthUsersPrefix,
    isPrefix: true,
  ),
  (
    teamPath: authTeamInvitesPath,
    adminPath: adminAuthInvitesPath,
    isPrefix: false,
  ),
  (
    teamPath: authTeamInvitePrefix,
    adminPath: adminAuthInvitePrefix,
    isPrefix: true,
  ),
  (
    teamPath: authTeamOrgUnitsPath,
    adminPath: adminAuthOrgUnitsPath,
    isPrefix: false,
  ),
  (
    teamPath: authTeamOrgUnitPrefix,
    adminPath: adminAuthOrgUnitPrefix,
    isPrefix: true,
  ),
  (
    teamPath: authTeamLocationsPrefix,
    adminPath: adminAuthLocationsPrefix,
    isPrefix: true,
  ),
];

String _canonicalAuthOperationPath(String path) =>
    canonicalAuthOperationPath(path, _authOpsPathTable);

String? _orgUnitIdFromParentPath(String path) {
  if (!path.startsWith(adminAuthOrgUnitPrefix)) return null;
  final rest = path.substring(adminAuthOrgUnitPrefix.length);
  final parts = rest.split('/');
  if (parts.length != 2 || parts[0].isEmpty || parts[1] != 'parent') {
    return null;
  }
  return Uri.decodeComponent(parts[0]);
}

String? _idFromAdminAuthActionPath(String path, String prefix, String action) {
  if (!path.startsWith(prefix)) return null;
  final rest = path.substring(prefix.length);
  final parts = rest.split('/');
  if (parts.length != 2 || parts[0].isEmpty || parts[1] != action) {
    return null;
  }
  return Uri.decodeComponent(parts[0]);
}

String? _orgUnitLocationIdFromPath(String path) {
  if (!path.startsWith(adminAuthLocationsPrefix)) return null;
  final rest = path.substring(adminAuthLocationsPrefix.length);
  final parts = rest.split('/');
  if (parts.length != 2 || parts[0].isEmpty || parts[1] != 'org-unit') {
    return null;
  }
  return Uri.decodeComponent(parts[0]);
}

String? _servicePrincipalJwtIssueId(String path, String method) {
  if (method != 'POST') return null;
  if (!path.startsWith(adminServicePrincipalsPrefix)) return null;
  final rest = path.substring(adminServicePrincipalsPrefix.length);
  final parts = rest.split('/');
  if (parts.length != 2 || parts[0].isEmpty || parts[1] != 'jwt') {
    return null;
  }
  return Uri.decodeComponent(parts[0]);
}

bool _isMfaOperation(String path, String method) {
  if (method != 'POST') return false;
  return path == authMfaTotpBeginPath ||
      path == authMfaTotpConfirmPath ||
      path == authMfaFactorsListPath ||
      path == authMfaRecoveryCodesViewedPath ||
      path == authMfaFactorsRevokePath ||
      path == authMfaFactorsRemovalCancelPath;
}

Future<bool> _requireAdminPermissionOrWrite({
  required HttpResponse response,
  required ProxyAdminPermissionGuard? guard,
  required OperatorContext scope,
  required String permissionKey,
  required DateTime requestedAt,
}) async {
  if (guard == null) {
    _writeJson(response, 503, <String, Object?>{
      'error': 'admin_permission_guard_not_configured',
      'message': 'route requires a ProxyAdminPermissionGuard to be installed',
    });
    return false;
  }

  final decision = await guard.evaluate(
    ProxyAdminGuardContext(
      actorUserId: scope.userId,
      operatorId: scope.operatorId,
      locationId: scope.locationId,
      lastFreshAuthAt:
          scope.lastFreshAuthAt ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      requestedPermissionKey: permissionKey,
      requestedAt: requestedAt,
    ),
  );

  switch (decision) {
    case ProxyAdminAllowed():
      return true;
    case ProxyAdminDeniedDefault():
      _writeJson(response, 403, <String, Object?>{
        'error': 'permission_denied',
        'message': 'permission denied',
        'permission_key': permissionKey,
      });
      return false;
    case ProxyAdminDeniedExplicit(:final matchedRoleId):
      _writeJson(response, 403, <String, Object?>{
        'error': 'permission_denied',
        'message': 'permission denied',
        'permission_key': permissionKey,
        'matched_role_id': matchedRoleId,
      });
      return false;
    case ProxyAdminMfaStaleAuth(:final refreshAfter):
      // CODE_OPS_DEBT Theme A item 1 — operator decision is "full
      // re-auth" (sign-out → login → MFA → return) rather than a
      // step-up modal. We carry a `redirect_uri` hint here so the
      // admin shell + operator web client can branch on it without
      // hard-coding the route. Keep the existing 403 status +
      // `mfa_freshness_required` error code so the existing test
      // suite stays green; the 401 + `fresh_mfa_required` shape
      // documented in the lane prompt is reserved for the
      // future per-route `requiresFreshMfa` decoration (out of
      // scope here — this slice un-pins the four UI affordances
      // and leaves the proxy verifier stable).
      _writeJson(response, 403, <String, Object?>{
        'error': 'mfa_freshness_required',
        'message': 'fresh authentication is required',
        'refresh_after': refreshAfter.toUtc().toIso8601String(),
        'redirect_uri':
            '/auth/login?reason=fresh_mfa_required&permission_key='
            '${Uri.encodeQueryComponent(permissionKey)}',
      });
      return false;
    case ProxyAdminChallengeRequired():
      _writeJson(response, 403, <String, Object?>{
        'error': 'recaptcha_challenge_required',
        'message': 'additional verification is required',
      });
      return false;
    case ProxyAdminRejected(:final reasonCode):
      _writeJson(response, 403, <String, Object?>{
        'error': reasonCode,
        'message': 'request rejected by admin guard',
      });
      return false;
  }
}

String? _pathSuffix(String path, String prefix) {
  if (!path.startsWith(prefix)) return null;
  final suffix = path.substring(prefix.length);
  if (suffix.isEmpty || suffix.contains('/')) return null;
  return Uri.decodeComponent(suffix);
}

String? _seededRolePermissionsRoleId(String path) {
  if (!path.startsWith(adminAuthRolePrefix) || !path.endsWith('/permissions')) {
    return null;
  }
  final suffix = path.substring(adminAuthRolePrefix.length);
  final parts = suffix.split('/');
  if (parts.length != 2 || parts[0].isEmpty || parts[1] != 'permissions') {
    return null;
  }
  return Uri.decodeComponent(parts[0]);
}

({String operatorId, String locationId})? _pathPairSuffix(
  String path,
  String prefix,
) {
  if (!path.startsWith(prefix)) return null;
  final suffix = path.substring(prefix.length);
  final parts = suffix.split('/');
  if (parts.length != 2 || parts.any((part) => part.isEmpty)) {
    return null;
  }
  return (
    operatorId: Uri.decodeComponent(parts[0]),
    locationId: Uri.decodeComponent(parts[1]),
  );
}

({String operatorId, String locationId})? _dataAccuracyManualCoversPathPair(
  String path,
) {
  if (!path.startsWith(adminDataAccuracySettingsPrefix)) return null;
  final suffix = path.substring(adminDataAccuracySettingsPrefix.length);
  final parts = suffix.split('/');
  if (parts.length != 3 ||
      parts[0].isEmpty ||
      parts[1].isEmpty ||
      parts[2] != 'manual-covers') {
    return null;
  }
  return (
    operatorId: Uri.decodeComponent(parts[0]),
    locationId: Uri.decodeComponent(parts[1]),
  );
}

Map<String, Object?> _teamRoleToJson(TeamRoleCatalogEntry role) {
  // Lane B B2.4 — `catalog_version_id` + `catalog_published_at` are
  // additive nullable fields. Operator-web parses them when present
  // and renders "Updated by F&F on <date>" on seeded rows; mobile +
  // legacy clients tolerate the extra keys (or the fields are null
  // for custom rows / genesis-state seeded rows).
  return <String, Object?>{
    'role_id': role.roleId,
    'role_key': role.roleKey,
    'display_name': role.displayName,
    'description': role.description,
    'is_seeded': role.isSeeded,
    'is_editable': role.isEditable,
    'operator_id': role.operatorId,
    'catalog_version_id': role.catalogVersionId,
    'catalog_published_at': role.catalogPublishedAt?.toUtc().toIso8601String(),
    'permissions': role.permissions
        .map(
          (permission) => <String, Object?>{
            'permission_key': permission.permissionKey,
            'effect': permission.effect,
          },
        )
        .toList(growable: false),
  };
}

Map<String, Object?> _teamUserToJson(TeamUserListEntry user) {
  return <String, Object?>{
    'user_id': user.userId,
    'email': user.email,
    'display_name': user.displayName,
    'role_id': user.roleId,
    'role_label': user.roleLabel,
    'status': user.status,
    'location_id': user.locationId,
    'location_label': user.locationLabel,
    'mfa_enrolled': user.mfaEnrolled,
    'mfa_removal_pending': user.mfaRemovalPending,
    'mfa_removal_request_id': user.mfaRemovalRequestId,
    'user_role_id': user.userRoleId,
    'last_active_at': user.lastActiveAt?.toUtc().toIso8601String(),
    'grants': user.grants.map(_teamGrantSnapshotToJson).toList(),
  };
}

Map<String, Object?> _teamGrantSnapshotToJson(TeamGrantSnapshot grant) {
  return <String, Object?>{
    'user_role_id': grant.userRoleId,
    'role_id': grant.roleId,
    if (grant.roleLabel != null) 'role_label': grant.roleLabel,
    'scope_type': grant.scopeType,
    'org_unit_id': grant.orgUnitId,
    'location_id': grant.locationId,
    'source_org_unit_id': grant.sourceOrgUnitId,
    'effective_location_ids': grant.effectiveLocationIds,
    if (grant.validFrom != null)
      'valid_from': grant.validFrom!.toUtc().toIso8601String(),
    if (grant.validUntil != null)
      'valid_until': grant.validUntil!.toUtc().toIso8601String(),
    if (grant.revokedAt != null)
      'revoked_at': grant.revokedAt!.toUtc().toIso8601String(),
  };
}

Map<String, Object?> _teamOrgUnitToJson(TeamOrgUnitEntry entry) {
  return <String, Object?>{
    'org_unit_id': entry.orgUnitId,
    'parent_org_unit_id': entry.parentOrgUnitId,
    'unit_type': entry.unitType,
    'path': entry.path,
    'label': entry.label,
    if (entry.suspendedAt != null)
      'suspended_at': entry.suspendedAt!.toUtc().toIso8601String(),
    if (entry.deletedAt != null)
      'deleted_at': entry.deletedAt!.toUtc().toIso8601String(),
  };
}

Map<String, Object?> _teamOrgLocationToJson(TeamOrgLocationEntry entry) {
  return <String, Object?>{
    'location_id': entry.locationId,
    'parent_org_unit_id': entry.parentOrgUnitId,
    'org_unit_path': entry.orgUnitPath,
    'label': entry.label,
    if (entry.suspendedAt != null)
      'suspended_at': entry.suspendedAt!.toUtc().toIso8601String(),
    if (entry.deletedAt != null)
      'deleted_at': entry.deletedAt!.toUtc().toIso8601String(),
  };
}

int _clampedQueryInt(
  String? raw, {
  int? defaultValue,
  required int min,
  required int max,
}) {
  final parsed = int.tryParse(raw ?? '');
  final value = parsed ?? defaultValue;
  if (value == null) return min;
  if (value < min) return min;
  if (value > max) return max;
  return value;
}

int? _optionalClampedQueryInt(
  String? raw, {
  required int min,
  required int max,
}) {
  if (raw == null || raw.trim().isEmpty) return null;
  return _clampedQueryInt(raw, min: min, max: max);
}

Map<String, Object?> _authEventEntryToJson(AuthEventListEntry entry) {
  return <String, Object?>{
    'event_id': entry.eventId,
    'event_kind': AuthEventLabels.wireKey(entry.eventKind),
    'event_type': entry.eventType,
    'friendly_label': entry.friendlyLabel,
    'occurred_at': entry.occurredAt.toUtc().toIso8601String(),
    if (entry.subType != null) 'sub_type': entry.subType,
    if (entry.ip != null) 'ip': entry.ip,
    if (entry.userAgent != null) 'user_agent': entry.userAgent,
    if (entry.geoCountry != null) 'geo_country': entry.geoCountry,
    if (entry.scope != null) 'scope': entry.scope,
    'payload': entry.payload,
  };
}

/// Renders one [AuthEventListEntry] as an RFC 4180 CSV row terminated
/// with `\r\n`. The column order matches the header emitted by the
/// audit-log CSV export route + the legacy `renderAuditLogCsv` shape
/// in `web_team_audit_log_gateway.dart` so downstream tools that
/// already ingested the client-rendered CSV keep working when the
/// operator-web build flips to the streaming server-side path.
///
/// Columns (in order):
///   1. created_at   - `occurred_at` in UTC ISO-8601.
///   2. action       - raw `event_type` (e.g. `auth.user.signed_in`).
///   3. actor_user_id   - the verified bearer-token scope's user id.
///                        Pinned by the proxy; never the request param.
///   4. actor_display_name - rendered hint ("F&F admin" or
///                            "Team member"); the underlying ledger
///                            does not denormalize the display name.
///   5. actor_email   - intentionally blank (auth_events_audit does
///                       not denormalize email; the read route does
///                       the same).
///   6. actor_kind    - `forge_admin` if the row carries an
///                       `admin_reason` payload key OR the event_type
///                       is in the `admin.*` namespace; `team_member`
///                       otherwise. Mirrors
///                       `_authEventEntryToAdminAuditRow` so the
///                       self-service + admin CSV exports agree on
///                       the actor classification.
///   7. target_kind   - left blank for now (auth_events_audit rows
///                       do not carry a target column; the F&F admin
///                       audit_logs ledger does, that surface lights
///                       up later).
///   8. target_id     - `event_id` so the row is still uniquely
///                       referenceable in a spreadsheet.
///   9. admin_reason  - `payload['admin_reason']` if present, blank
///                       otherwise.
///  10. payload       - JSON-encoded payload (RFC 4180 escaped).
String _renderAuthEventCsvRow(AuthEventListEntry entry, OperatorContext scope) {
  final payload = entry.payload;
  final adminReason = payload['admin_reason'];
  final adminReasonText = adminReason is String && adminReason.trim().isNotEmpty
      ? adminReason
      : '';
  final isAdminEvent =
      entry.eventType.startsWith('admin.') || adminReasonText.isNotEmpty;
  final actorKind = isAdminEvent ? 'forge_admin' : 'team_member';
  final actorDisplayName = isAdminEvent ? 'F&F admin' : 'Team member';
  final payloadJson = payload.isEmpty ? '' : jsonEncode(payload);
  final cells = <String>[
    _csvEscape(entry.occurredAt.toUtc().toIso8601String()),
    _csvEscape(entry.eventType),
    _csvEscape(scope.userId),
    _csvEscape(actorDisplayName),
    _csvEscape(''),
    _csvEscape(actorKind),
    _csvEscape(''),
    _csvEscape(entry.eventId),
    _csvEscape(adminReasonText),
    _csvEscape(payloadJson),
  ];
  return '${cells.join(',')}\r\n';
}

/// RFC 4180 cell escaping. Wraps in double quotes when the cell
/// contains a comma, double quote, CR, or LF; doubles internal
/// double quotes. Empty input renders as an empty string (no quotes).
String _csvEscape(String raw) {
  if (raw.isEmpty) return '';
  final needsQuoting =
      raw.contains(',') ||
      raw.contains('"') ||
      raw.contains('\n') ||
      raw.contains('\r');
  if (!needsQuoting) return raw;
  return '"${raw.replaceAll('"', '""')}"';
}

Map<String, Object?> _authEventEntryToAdminAuditRow(
  AuthEventListEntry entry,
  OperatorContext scope,
) {
  final occurredAt = entry.occurredAt.toUtc();
  final adminReason = _nonBlankString(entry.payload['admin_reason']);
  final actorKind = entry.eventType.startsWith('admin.') || adminReason != null
      ? 'forge_admin'
      : 'team_member';
  return <String, Object?>{
    'event_id': entry.eventId,
    'action': entry.eventType,
    'occurred_at': occurredAt.toIso8601String(),
    'actor_user_id': scope.userId,
    'actor_display_name': actorKind == 'forge_admin'
        ? 'F&F admin'
        : 'Team member',
    'actor_email': '',
    'actor_kind': actorKind,
    'operator_id': scope.operatorId,
    'target_kind': 'auth_event',
    'target_id': entry.eventId,
    'payload': <String, Object?>{
      'event_kind': AuthEventLabels.wireKey(entry.eventKind),
      'friendly_label': entry.friendlyLabel,
      if (entry.subType != null) 'sub_type': entry.subType,
      if (entry.ip != null) 'ip': entry.ip,
      if (entry.userAgent != null) 'user_agent': entry.userAgent,
      if (entry.geoCountry != null) 'geo_country': entry.geoCountry,
      if (entry.scope != null) 'scope': entry.scope,
      ...entry.payload,
    },
    'business_date': DateTime.utc(
      occurredAt.year,
      occurredAt.month,
      occurredAt.day,
    ).toIso8601String(),
    'admin_reason': adminReason,
    'row_hash': null,
  };
}

AuthEventKind? _authEventKindFromAdminAuditActions(String? raw) {
  final actions = (raw ?? '')
      .split(',')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .map(AuthEventLabels.fromWireKey)
      .whereType<AuthEventKind>()
      .toSet();
  return actions.length == 1 ? actions.single : null;
}

Map<String, Object?> _authSessionSummaryToAdminJson(
  AuthSessionSummary session,
  OperatorContext scope,
) {
  final userLabel = scope.firebaseUid ?? scope.userId;
  return <String, Object?>{
    ..._authSessionSummaryToJson(session),
    'user_id': scope.userId,
    'user_display_name': userLabel,
    'user_email': userLabel,
    'last_active_at': session.lastSeenAt.toUtc().toIso8601String(),
    'device_fingerprint':
        session.deviceFingerprint ??
        session.deviceLabel ??
        session.userAgent ??
        'Unknown device',
    'ip_geo_city': session.geoCountry ?? session.ip ?? 'Unknown location',
  };
}

Map<String, Object?> _authSessionSummaryToJson(AuthSessionSummary session) {
  return <String, Object?>{
    'session_id': session.sessionId,
    'created_at': session.createdAt.toUtc().toIso8601String(),
    'last_seen_at': session.lastSeenAt.toUtc().toIso8601String(),
    if (session.deviceLabel != null) 'device_label': session.deviceLabel,
    if (session.userAgent != null) 'user_agent': session.userAgent,
    if (session.ip != null) 'ip': session.ip,
    if (session.geoCountry != null) 'geo_country': session.geoCountry,
    if (session.deviceFingerprint != null)
      'device_fingerprint': session.deviceFingerprint,
    if (session.revokedAt != null)
      'revoked_at': session.revokedAt!.toUtc().toIso8601String(),
    if (session.revokedReason != null) 'revoked_reason': session.revokedReason,
  };
}

Map<String, Object?> _teamInviteToJson(TeamInviteListEntry invite) {
  return <String, Object?>{
    'invite_id': invite.inviteId,
    'email': invite.email,
    'role_id': invite.roleId,
    'role_label': invite.roleLabel,
    'scope_type': invite.scopeType,
    'location_id': invite.locationId,
    'location_label': invite.locationLabel,
    'org_unit_id': invite.orgUnitId,
    'org_unit_label': invite.orgUnitLabel,
    'expires_at': invite.expiresAt.toUtc().toIso8601String(),
    'created_at': invite.createdAt.toUtc().toIso8601String(),
  };
}

List<TeamRolePermissionUpdate> _rolePermissionUpdates(Object? raw) {
  if (raw == null) return const <TeamRolePermissionUpdate>[];
  if (raw is! List) {
    throw const AuthOperationRejected(
      code: 'invalid_role_permissions',
      message: 'permissions must be a list',
      statusCode: 400,
    );
  }
  final updates = <TeamRolePermissionUpdate>[];
  for (final item in raw) {
    if (item is! Map) {
      throw const AuthOperationRejected(
        code: 'invalid_role_permissions',
        message: 'each permission update must be an object',
        statusCode: 400,
      );
    }
    final map = Map<String, Object?>.from(item);
    final permissionKey = _nonBlankString(map['permission_key']);
    final effect = _nonBlankString(map['effect']);
    if (permissionKey == null || effect == null) {
      throw const AuthOperationRejected(
        code: 'invalid_role_permissions',
        message: 'permission_key and effect are required',
        statusCode: 400,
      );
    }
    if (effect != 'allow' && effect != 'deny' && effect != 'inherit') {
      throw const AuthOperationRejected(
        code: 'invalid_permission_effect',
        message: "permission effect must be 'allow', 'deny', or 'inherit'",
        statusCode: 400,
      );
    }
    updates.add(
      TeamRolePermissionUpdate(
        permissionKey: permissionKey,
        effect: effect == 'inherit' ? null : effect,
      ),
    );
  }
  return List<TeamRolePermissionUpdate>.unmodifiable(updates);
}

List<String> _permissionKeyList(Object? raw) {
  if (raw is! List) {
    throw const AuthOperationRejected(
      code: 'invalid_role_permissions',
      message: 'permission_keys must be a list',
      statusCode: 400,
    );
  }
  final keys = <String>[];
  for (final item in raw) {
    final key = _nonBlankString(item);
    if (key == null) {
      throw const AuthOperationRejected(
        code: 'invalid_role_permissions',
        message: 'each permission key must be a non-empty string',
        statusCode: 400,
      );
    }
    keys.add(key);
  }
  return List<String>.unmodifiable(keys);
}

String? _stringValue(Object? value) {
  return value is String ? value : null;
}

_UserAction? _userActionFromPath(String path) {
  if (!path.startsWith(adminAuthUsersPrefix)) return null;
  final rest = path.substring(adminAuthUsersPrefix.length);
  final parts = rest.split('/');
  if (parts.length != 2 || parts.any((part) => part.isEmpty)) return null;
  return _UserAction(
    userId: Uri.decodeComponent(parts[0]),
    action: Uri.decodeComponent(parts[1]),
  );
}

/// CODE_OPS_DEBT Theme B#1 — splits the `/v1/admin/auth/users/{id}/
/// erase-pii[/reverse]` path families. Returns null when the path is
/// not one of the three erase-pii shapes; otherwise returns the user
/// id + the sub-action (`'request'` for the bare `/erase-pii`,
/// `'reverse'` for `/erase-pii/reverse`).
_PiiErasurePath? _piiErasurePathFromAdminAuthUsersPrefix(String path) {
  if (!path.startsWith(adminAuthUsersPrefix)) return null;
  final rest = path.substring(adminAuthUsersPrefix.length);
  final parts = rest.split('/');
  if (parts.length == 2 && parts[0].isNotEmpty && parts[1] == 'erase-pii') {
    return _PiiErasurePath(
      userId: Uri.decodeComponent(parts[0]),
      action: 'request',
    );
  }
  if (parts.length == 3 &&
      parts[0].isNotEmpty &&
      parts[1] == 'erase-pii' &&
      parts[2] == 'reverse') {
    return _PiiErasurePath(
      userId: Uri.decodeComponent(parts[0]),
      action: 'reverse',
    );
  }
  return null;
}

class _PiiErasurePath {
  const _PiiErasurePath({required this.userId, required this.action});

  final String userId;
  final String action;
}

String? _sessionRevokeIdFromPath(String path) {
  if (!path.startsWith(adminAuthSessionsPrefix)) return null;
  final rest = path.substring(adminAuthSessionsPrefix.length);
  final parts = rest.split('/');
  if (parts.length != 2 || parts[0].isEmpty || parts[1] != 'revoke') {
    return null;
  }
  return Uri.decodeComponent(parts[0]);
}

class _UserAction {
  const _UserAction({required this.userId, required this.action});

  final String userId;
  final String action;
}

/// Resolves [AuthSessionLedgerContext] enrichment fields.
///
/// By default the proxy ignores forwarded IP / country headers because
/// direct clients can spoof them. The deployment may opt into trusting
/// those headers only after ingress is configured to strip and overwrite
/// them before traffic reaches this process.
///
/// `User-Agent` is always client-supplied soft metadata; it is useful
/// for support/debugging but must not be treated as a trusted security
/// signal.
AuthSessionLedgerContext _resolveLedgerContextFromHeaders(
  HttpRequest request, {
  required bool trustProxyAuditHeaders,
}) {
  String? ip = request.connectionInfo?.remoteAddress.address;
  String? geoCountry;

  if (trustProxyAuditHeaders) {
    final xff = request.headers.value('X-Forwarded-For');
    if (xff != null) {
      final first = xff.split(',').first.trim();
      if (first.isNotEmpty) ip = first;
    }

    geoCountry = request.headers.value('X-Country');
    geoCountry ??= request.headers.value('X-AppEngine-Country');
    if (geoCountry != null) {
      final trimmed = geoCountry.trim().toUpperCase();
      geoCountry = trimmed.length == 2 ? trimmed : null;
    }
  }

  return AuthSessionLedgerContext(
    ip: ip,
    userAgent: request.headers.value(HttpHeaders.userAgentHeader),
    geoCountry: geoCountry,
  );
}

/// Reads + decodes a JSON object body. Returns `{}` when [allowEmpty]
/// is true and the body is empty (used by /revoke-all where the body
/// is optional). Throws [_MalformedJsonBodyError] otherwise.
Future<Map<String, Object?>> _readJsonBody(
  HttpRequest request, {
  bool allowEmpty = false,
}) async {
  // `utf8.decodeStream` accepts `Stream<List<int>>` directly so we
  // don't fight type inference between Utf8Decoder and StreamTransformer
  // on the typed Uint8List stream the dart:io request exposes.
  final raw = await utf8.decodeStream(request);
  if (raw.isEmpty) {
    if (allowEmpty) return <String, Object?>{};
    throw _MalformedJsonBodyError('request body is empty');
  }
  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (error) {
    throw _MalformedJsonBodyError('JSON parse failed: ${error.message}');
  }
  if (decoded is! Map) {
    throw _MalformedJsonBodyError('JSON body must be an object');
  }
  return Map<String, Object?>.from(decoded);
}

/// Returns [value] cast to a non-empty trimmed string, or null when
/// the input is missing, the wrong type, or a blank string. Used by
/// the auth-session endpoints to validate body fields without leaking
/// the actual value into log paths.
String? _nonBlankString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return trimmed;
}

List<String> _nonBlankStrings(Iterable<String>? values) {
  if (values == null) return const <String>[];
  final result = <String>[];
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || result.contains(trimmed)) continue;
    result.add(trimmed);
  }
  return List<String>.unmodifiable(result);
}

List<String> _commaSeparatedQueryList(Object? value) {
  if (value is! String) return const <String>[];
  return _nonBlankStrings(value.split(','));
}

class _MalformedJsonBodyError implements Exception {
  _MalformedJsonBodyError(this.message);

  final String message;
}

/// HARD-G observability — write the contract-pinned envelope for a
/// dependency timeout. The Postgres / HIBP / Voyage / Firebase
/// adapters already emitted `request.dependency_timeout` at the wire
/// boundary; this helper just translates the typed exception into the
/// 503 response shape clients see.
void _writeDependencyTimeoutEnvelope(
  HttpResponse response,
  DependencyTimeoutException error,
) {
  _writeJson(response, 503, <String, Object?>{
    'error': 'dependency_timeout',
    'surface': error.surface,
    'operation': error.operation,
    'message': 'Upstream dependency timed out; please retry',
  });
}

/// HARD-G observability — call inside any inner catch that writes a
/// 503 response with a surface-specific code. When [error] is a
/// [DependencyTimeoutException], writes the standardized timeout
/// envelope and returns true. Otherwise returns false and the caller
/// continues with its existing fallback path.
bool _maybeWriteDependencyTimeout(HttpResponse response, Object error) {
  if (error is! DependencyTimeoutException) return false;
  _writeDependencyTimeoutEnvelope(response, error);
  return true;
}

void _logProxyUnhandled({
  required String surface,
  required String method,
  required String path,
  required Object error,
  required StackTrace stackTrace,
}) {
  final errorText = error.toString().replaceAll(RegExp(r'\s+'), ' ');
  final clipped = errorText.length > 500
      ? '${errorText.substring(0, 500)}...'
      : errorText;
  final stackText = stackTrace.toString();
  final firstNewline = stackText.indexOf('\n');
  final firstFrame = firstNewline == -1
      ? stackText
      : stackText.substring(0, firstNewline);
  log(
    LogSeverity.error,
    'proxy.unhandled_error',
    fields: <String, Object?>{
      'surface': surface,
      'method': method,
      'path': path,
      'error_type': error.runtimeType.toString(),
      'error_message': clipped,
      'stack_first_frame': firstFrame,
    },
  );
}

void _writeJson(
  HttpResponse response,
  int statusCode,
  Map<String, Object?> body,
) {
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
}

/// HARD-C — request methods that are required to declare a body.
/// Used by the routeRequest body-cap pre-handler to reject oversized
/// or unannounced (Content-Length: -1) mutations before any handler
/// reads the stream.
bool _isBodyMethod(String method) {
  return method == 'POST' || method == 'PATCH' || method == 'PUT';
}

/// HARD-C — admin CORS request body cap. Hard limit on every
/// admin-route mutation; oversized requests get 413 before any
/// gateway runs.
const int kAdminCorsRequestBodyLimitBytes = 1000000;

/// CODE_HEALTH L4 — graph-candidate batch endpoint body cap.
///
/// The graph-candidate commit-batch route (`POST
/// /v1/admin/corpus/graph-candidates/commit-batch`) accepts the full
/// batch decision payload from the Graphify reviewer. A 1 MB cap was
/// silently rejecting batches above ~3k candidate decisions; raise to
/// 16 MB exclusively for this surface so review-and-commit continues
/// to work without re-introducing the global cap (which would expand
/// the attack surface for every other admin POST). Every other route,
/// admin or otherwise, stays on [kAdminCorsRequestBodyLimitBytes].
const int kGraphCandidateBatchRequestBodyLimitBytes = 16 * 1024 * 1024;

/// CODE_HEALTH L4 — per-route body cap selector. Returns the
/// per-route cap when the path matches a known oversized surface;
/// otherwise returns the global default
/// [kAdminCorsRequestBodyLimitBytes].
int resolveRequestBodyLimitBytes(String path) {
  if (path == adminCorpusGraphCandidatesCommitPath) {
    return kGraphCandidateBatchRequestBodyLimitBytes;
  }
  return kAdminCorsRequestBodyLimitBytes;
}

/// HARD-C — admin CORS preflight cache duration. Browsers may keep
/// the preflight response for this many seconds before re-issuing
/// the OPTIONS request.
const int kAdminCorsPreflightMaxAgeSeconds = 600;

/// HARD-C — Allow-Headers value used for every admin CORS surface.
/// Matches the contract's required value exactly:
/// `Authorization, Content-Type, Idempotency-Key`. Idempotency-Key
/// is included so the corpus / feature-flags / future idempotent
/// admin routes can carry it past the browser preflight.
const String kAdminCorsAllowedRequestHeaders =
    'Authorization, Content-Type, Idempotency-Key';

/// HARD-C — Allowed methods list per admin CORS surface, threaded
/// through the centralized [respondAdminCorsPreflight] helper. Each
/// list MUST contain `OPTIONS`; CORS preflight refuses methods that
/// aren't echoed in `Access-Control-Allow-Methods`.
const List<String> kAdminOperatorLocationCorsMethods = <String>[
  'GET',
  'POST',
  'PATCH',
  'DELETE',
  'OPTIONS',
];
const List<String> kAdminPricingCorsMethods = <String>[
  'GET',
  'POST',
  'PUT',
  'PATCH',
  'DELETE',
  'OPTIONS',
];
const List<String> kAdminDataAccuracyCorsMethods = <String>[
  'GET',
  'POST',
  'PUT',
  'PATCH',
  'OPTIONS',
];
const List<String> kAdminVendorApplicabilityCorsMethods = <String>[
  'GET',
  'POST',
  'PATCH',
  'OPTIONS',
];
const List<String> kAdminCorpusCorsMethods = <String>['GET', 'POST', 'OPTIONS'];
const List<String> kAdminIntegrationsCorsMethods = <String>[
  'GET',
  'POST',
  'OPTIONS',
];
const List<String> kAdminFeatureFlagsCorsMethods = <String>[
  'GET',
  'POST',
  'OPTIONS',
];
const List<String> kAdminDebugConsoleCorsMethods = <String>['GET', 'OPTIONS'];
const List<String> kAdminObservabilityCorsMethods = <String>['GET', 'OPTIONS'];
const List<String> kAdminHealthCorsMethods = <String>['GET', 'OPTIONS'];
const List<String> kAuthCorsMethods = <String>[
  'GET',
  'POST',
  'PUT',
  'PATCH',
  'DELETE',
  'OPTIONS',
];

/// HARD-C — sole origin-decision site for admin CORS.
///
/// Returns the matched origin (the literal value to echo back) when
/// [requestOrigin] is permitted by [allowList]. Returns null when:
/// the request carries no `Origin` header, the header is blank, or
/// none of the allow-list entries match.
///
/// Allow-list semantics:
///   * exact strings are case-sensitive equality matches;
///   * an entry ending in `:*` (e.g. `http://localhost:*`) matches
///     any numeric port on the same scheme + host. Used for the
///     dev / staging local-browser fallback the bootstrap resolver
///     adds so consoles served from `localhost:*` or `127.0.0.1:*`
///     both round-trip.
///
/// Wildcard `*` is intentionally not supported. The HARD-C contract
/// bans wildcard origin echoes on admin routes because admin JWTs
/// are sensitive and must not be redeemable from any origin.
String? _matchAdminCorsOrigin(String? requestOrigin, List<String> allowList) {
  if (requestOrigin == null) return null;
  final origin = requestOrigin.trim();
  if (origin.isEmpty) return null;
  for (final allowed in allowList) {
    if (allowed == origin) return origin;
    if (allowed.endsWith(':*')) {
      final prefix = allowed.substring(0, allowed.length - 2);
      if (prefix.isEmpty) continue;
      if (!origin.startsWith('$prefix:')) continue;
      final port = origin.substring(prefix.length + 1);
      if (port.isEmpty) continue;
      if (int.tryParse(port) == null) continue;
      return origin;
    }
  }
  return null;
}

/// HARD-C — admin CORS preflight handler.
///
/// Writes a complete response and returns. On match: 204, exact
/// origin echoed in `Access-Control-Allow-Origin`, `Vary: Origin`,
/// the [allowedMethods] list, [kAdminCorsAllowedRequestHeaders], and
/// `Access-Control-Max-Age: 600`. On disallowed / missing origin:
/// 403 with `Vary: Origin` set but NO `Access-Control-Allow-Origin`
/// header echoed, so a browser refuses to attach credentials on the
/// follow-up request.
///
/// Routed admin paths must pass through this single helper so the
/// origin allow-list lives in one place. The previous slice exposed
/// five `_setAdmin*CorsHeaders` helpers that all hard-coded a
/// wildcard origin echo; HARD-C deletes those and replaces them
/// with this one decision site.
void respondAdminCorsPreflight(
  HttpRequest request,
  List<String> allowList, {
  required List<String> allowedMethods,
}) {
  final originHeader = request.headers.value('origin');
  final matched = _matchAdminCorsOrigin(originHeader, allowList);
  request.response.headers.set('Vary', 'Origin');
  if (matched == null) {
    _writeJson(request.response, HttpStatus.forbidden, const <String, Object?>{
      'error': 'cors_origin_not_allowed',
    });
    return;
  }
  request.response.statusCode = HttpStatus.noContent;
  request.response.headers.set('Access-Control-Allow-Origin', matched);
  request.response.headers.set(
    'Access-Control-Allow-Methods',
    allowedMethods.join(', '),
  );
  request.response.headers.set(
    'Access-Control-Allow-Headers',
    kAdminCorsAllowedRequestHeaders,
  );
  request.response.headers.set(
    'Access-Control-Max-Age',
    '$kAdminCorsPreflightMaxAgeSeconds',
  );
  request.response.contentLength = 0;
}

/// HARD-C — apply admin CORS headers to a non-preflight admin
/// response. Always sets `Vary: Origin`. When the request origin
/// matches [allowList], also sets `Access-Control-Allow-Origin` to
/// the literal matched origin string. Returns whether the origin
/// matched.
///
/// Preflight responses use [respondAdminCorsPreflight] instead;
/// this is the helper for the regular admin handler responses
/// (200 / 4xx / 5xx) so the browser receives the echo on every
/// admin response, not just OPTIONS.
bool _applyAdminCorsHeaders(HttpRequest request, List<String> allowList) {
  request.response.headers.set('Vary', 'Origin');
  final originHeader = request.headers.value('origin');
  final matched = _matchAdminCorsOrigin(originHeader, allowList);
  if (matched == null) return false;
  request.response.headers.set('Access-Control-Allow-Origin', matched);
  return true;
}

String _nonBlankOr(String? raw, String fallback) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return fallback;
  return value;
}
