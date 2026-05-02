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

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/domain/services/advisor_provider_constants.dart';
import 'package:forge_and_flow/domain/services/advisor_response_cache.dart';
import 'package:forge_and_flow/domain/services/circuit_breaker.dart';
import 'package:forge_and_flow/domain/services/graceful_refusal_response.dart';
import 'package:forge_and_flow/domain/services/llm_provider.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/account_info_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';
import 'package:forge_and_flow/services/auth/password_change_gateway.dart';
import 'package:forge_and_flow/services/auth/password_reset_confirm_gateway.dart';
import 'package:forge_and_flow/services/auth/password_reset_request_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';
import 'package:forge_and_flow/services/mfa/identity_toolkit_firebase_mfa_client.dart';
import 'package:forge_and_flow/services/mfa/mfa_operations_gateway.dart';
import 'package:forge_and_flow/services/mfa/mfa_recovery_request_gateway.dart';
import 'package:forge_and_flow/utils/iana_timezones.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/pointycastle.dart' as pc;

import '../advisor_corpus/advisor_corpus.dart' show CorpusManifest, defaultManifestPath;
import 'proxy_idempotency_cache.dart';
export 'proxy_idempotency_cache.dart' show ProxyAuthIdempotencyCache;

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

  /// Required server-side secret names. The proxy refuses to start
  /// when any of these are missing or blank.
  static const List<String> required = <String>[
    anthropicApiKey,
    voyageApiKey,
    postgresUrl,
    postgresAdminUrl,
    firebaseWebApiKey,
    servicePrincipalJwtSecret,
  ];

  /// Optional server-side secret names. Loaded into [ProxyConfig] when
  /// present; absence is not a startup error. Callers gate behavior on
  /// [ProxyConfig.hasSecretFor].
  static const List<String> optional = <String>[
    geminiApiKey,
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
}

// ─── Config ──────────────────────────────────────────────────────────────────

class ProxyConfigError implements Exception {
  ProxyConfigError(this.message, {required this.missingSecretNames});

  final String message;
  final List<String> missingSecretNames;

  @override
  String toString() => message;
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
  }) : _secrets = Map<String, String>.unmodifiable(secrets);

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
    final gcpProjectIdValue =
        trimmedOrNull(environment[ProxyConfigNames.gcpProjectId]);
    final cloudRunRegionValue =
        trimmedOrNull(environment[ProxyConfigNames.cloudRunRegion]);
    final cloudRunServiceNameValue =
        trimmedOrNull(environment[ProxyConfigNames.cloudRunServiceName]);

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
    if (anyPresent && !allPresent) {
      final missingNames = <String>[];
      if (gcpProjectIdValue == null) {
        missingNames.add(ProxyConfigNames.gcpProjectId);
      }
      if (cloudRunRegionValue == null) {
        missingNames.add(ProxyConfigNames.cloudRunRegion);
      }
      if (cloudRunServiceNameValue == null) {
        missingNames.add(ProxyConfigNames.cloudRunServiceName);
      }
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

    return ProxyConfig._(
      port: port,
      secrets: loaded,
      firebaseProjectId: firebaseProjectId,
      firebaseEmailActionContinueUrl: firebaseEmailActionContinueUrl,
      cacheTelemetryV2: cacheTelemetryV2,
      gcpProjectId: gcpProjectIdValue,
      cloudRunRegion: cloudRunRegionValue,
      cloudRunServiceName: cloudRunServiceNameValue,
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

// ─── JWT verification interface ──────────────────────────────────────────────

/// Verified JWT claims relevant to the proxy. Production verifiers
/// (Firebase / Supabase) populate this; tests inject fakes.
class ProxyJwtClaims {
  const ProxyJwtClaims({
    required this.userId,
    required this.operatorId,
    required this.locationId,
    required this.roles,
    this.actorKind = 'user',
    this.servicePrincipalId,
    this.firebaseUid,
    this.rolesVersion,
    this.lastFreshAuthAt,
  });

  final String userId;

  /// Null when the token is authenticated but not yet operator-scoped
  /// (e.g. mid-onboarding). The request guard treats null/empty as a
  /// 403 — protected routes require resolved scope.
  final String? operatorId;

  /// Null when the token is authenticated but does not name a
  /// specific location. Multi-location operators must select a
  /// location before retrieval / provider calls run.
  final String? locationId;

  final List<String> roles;
  final String actorKind;
  final String? servicePrincipalId;
  final String? firebaseUid;

  final int? rolesVersion;

  /// Firebase `auth_time` projected to UTC. Admin routes use this for
  /// fresh-auth / MFA freshness checks.
  final DateTime? lastFreshAuthAt;
}

class ProxyJwtVerificationError implements Exception {
  ProxyJwtVerificationError(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract class ProxyJwtVerifier {
  /// Verifies [bearerToken] (without the `Bearer ` prefix). Returns
  /// resolved claims on success; throws [ProxyJwtVerificationError]
  /// on tampered / expired / malformed tokens. Production
  /// implementations call Firebase Auth or Supabase JWT verifiers.
  Future<ProxyJwtClaims> verify(String bearerToken);
}

/// Hard-fail-closed verifier shipped with the 11a.10a scaffold. Until
/// a real verifier wires in (later proxy slice), every token is
/// rejected so a misconfigured production deploy fails closed instead
/// of silently accepting unauthenticated traffic.
class ScaffoldRejectingJwtVerifier implements ProxyJwtVerifier {
  const ScaffoldRejectingJwtVerifier();

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    throw ProxyJwtVerificationError(
      '11a.10a scaffold: live JWT verifier is not wired yet — '
      'this verifier rejects all tokens to fail closed.',
    );
  }
}

// ─── 9.1 — Firebase ID token verifier ───────────────────────────────────────
//
// The 11a.10a scaffold ships [ScaffoldRejectingJwtVerifier] so a
// misconfigured production deploy fails closed. Phase 9.1 replaces it
// (when [ProxyConfig.firebaseProjectId] is set) with
// [FirebaseProxyJwtVerifier], which verifies Firebase Identity
// Platform ID tokens locally using injected key source +
// signature validator + clock — no live Firebase call per request.
//
// Tenant-context resolver (`firebase_uid → users → location/status`)
// lands in 9.2; until then, the verifier reads operator/location
// scope from the Firebase custom claims directly. Only the tiny
// custom-claim set locked for Phase 9 is honored here:
// `operator_id`, `location_id`, `is_super_admin`, `is_ff_support`,
// `roles_version` (under 200 bytes total per the decision lock).
//
// Production crypto wiring (the RSA primitive) is delegated to
// [JwtRs256SignatureValidator] so the verifier framework can be
// unit-tested with fakes today and the cryptographic backend
// (e.g. pointycastle) can be plugged in without changing the seam.
// The default [ScaffoldFailingRs256SignatureValidator] keeps
// production fail-closed if the backend is not yet wired.

/// Issues short-lived `sp:` JWTs for service-principal actors.
class ServicePrincipalJwtIssuer {
  const ServicePrincipalJwtIssuer({required this.sharedSecret});

  final String sharedSecret;

  String issue({
    required String servicePrincipalId,
    required String operatorId,
    required String locationId,
    required List<String> scopes,
    required DateTime issuedAt,
    Duration ttl = const Duration(minutes: 15),
  }) {
    final expiresAt = issuedAt.toUtc().add(ttl);
    final header = _base64UrlJson(const <String, Object?>{
      'alg': 'HS256',
      'typ': 'JWT',
    });
    final payload = _base64UrlJson(<String, Object?>{
      'sub': 'sp:$servicePrincipalId',
      'operator_id': operatorId,
      'location_id': locationId,
      'scopes': scopes,
      'iat': issuedAt.toUtc().millisecondsSinceEpoch ~/ 1000,
      'exp': expiresAt.millisecondsSinceEpoch ~/ 1000,
    });
    final signedInput = '$header.$payload';
    final signature = _base64UrlBytes(_hmac(signedInput, sharedSecret));
    return '$signedInput.$signature';
  }
}

class ServicePrincipalJwtVerifier implements ProxyJwtVerifier {
  ServicePrincipalJwtVerifier({
    required this.sharedSecret,
    DateTime Function()? now,
    Duration leeway = const Duration(seconds: 30),
  }) : _now = now ?? DateTime.now,
       _leeway = leeway;

  final String sharedSecret;
  final DateTime Function() _now;
  final Duration _leeway;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final parts = bearerToken.split('.');
    if (parts.length != 3) {
      throw ProxyJwtVerificationError(
        'malformed service principal JWT: expected 3 segments',
      );
    }
    final header = _decodeJwtSegment(parts[0], 'header');
    final payload = _decodeJwtSegment(parts[1], 'payload');
    if (header['alg'] != 'HS256') {
      throw ProxyJwtVerificationError('unsupported service principal JWT alg');
    }

    final expected = _hmac('${parts[0]}.${parts[1]}', sharedSecret);
    final actual = _base64UrlDecodeBytes(parts[2], 'signature');
    if (!_constantTimeEquals(expected, actual)) {
      throw ProxyJwtVerificationError(
        'service principal JWT signature did not verify',
      );
    }

    final sub = _readString(payload, 'sub');
    if (sub == null || !sub.startsWith('sp:')) {
      throw ProxyJwtVerificationError('service principal JWT sub missing sp:');
    }
    final servicePrincipalId = sub.substring(3);
    if (!_uuidPattern.hasMatch(servicePrincipalId)) {
      throw ProxyJwtVerificationError('service principal JWT sub malformed');
    }
    final operatorId = _readString(payload, 'operator_id');
    final locationId = _readString(payload, 'location_id');
    if (operatorId == null || locationId == null) {
      throw ProxyJwtVerificationError(
        'service principal JWT missing operator or location scope',
      );
    }

    final now = _now();
    final exp = _readEpochSeconds(payload, 'exp');
    final iat = _readEpochSeconds(payload, 'iat');
    if (exp == null || iat == null) {
      throw ProxyJwtVerificationError('service principal JWT missing exp/iat');
    }
    if (now.isAfter(exp.add(_leeway))) {
      throw ProxyJwtVerificationError('service principal JWT expired');
    }
    if (iat.isAfter(now.add(_leeway))) {
      throw ProxyJwtVerificationError(
        'service principal JWT iat is in the future',
      );
    }

    final scopes = payload['scopes'];
    return ProxyJwtClaims(
      userId: servicePrincipalId,
      operatorId: operatorId,
      locationId: locationId,
      roles: <String>[
        'service_principal',
        if (scopes is List)
          for (final scope in scopes.whereType<String>()) 'sp_scope:$scope',
      ],
      actorKind: 'service',
      servicePrincipalId: servicePrincipalId,
    );
  }

  static Map<String, Object?> _decodeJwtSegment(String segment, String name) {
    final bytes = _base64UrlDecodeBytes(segment, name);
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw ProxyJwtVerificationError(
        'service principal JWT $name is not valid JSON',
      );
    }
    if (decoded is! Map) {
      throw ProxyJwtVerificationError(
        'service principal JWT $name is not an object',
      );
    }
    return Map<String, Object?>.from(decoded);
  }

  static String? _readString(Map<String, Object?> payload, String key) {
    final raw = payload[key];
    if (raw is String && raw.isNotEmpty) return raw;
    return null;
  }

  static DateTime? _readEpochSeconds(Map<String, Object?> payload, String key) {
    final raw = payload[key];
    if (raw is int) {
      return DateTime.fromMillisecondsSinceEpoch(raw * 1000, isUtc: true);
    }
    return null;
  }

  static Uint8List _base64UrlDecodeBytes(String input, String name) {
    var padded = input;
    final remainder = padded.length % 4;
    if (remainder != 0) padded = padded + '=' * (4 - remainder);
    try {
      return Uint8List.fromList(base64Url.decode(padded));
    } catch (_) {
      throw ProxyJwtVerificationError(
        'service principal JWT $name is not valid base64url',
      );
    }
  }

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
}

class CompositeProxyJwtVerifier implements ProxyJwtVerifier {
  const CompositeProxyJwtVerifier(this.verifiers);

  final List<ProxyJwtVerifier> verifiers;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    ProxyJwtVerificationError? lastError;
    for (final verifier in verifiers) {
      try {
        return await verifier.verify(bearerToken);
      } on ProxyJwtVerificationError catch (error) {
        lastError = error;
      }
    }
    throw lastError ??
        ProxyJwtVerificationError('no proxy JWT verifier is configured');
  }
}

String _base64UrlJson(Map<String, Object?> data) {
  return _base64UrlBytes(Uint8List.fromList(utf8.encode(jsonEncode(data))));
}

String _base64UrlBytes(List<int> bytes) {
  return base64Url.encode(bytes).replaceAll('=', '');
}

Uint8List _hmac(String signedInput, String secret) {
  return Uint8List.fromList(
    Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(signedInput)).bytes,
  );
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

class JwtKeyMaterial {
  const JwtKeyMaterial({required this.pemX509Certificate, required this.kid});

  /// Firebase securetoken endpoint returns PEM-encoded x509
  /// certificates keyed by `kid`. Production validators parse this
  /// to extract the embedded RSA public key.
  final String pemX509Certificate;

  /// Key ID this material was published under. Carried alongside the
  /// material so audit / diagnostic code can correlate verification
  /// failures to the specific key without reaching back into the
  /// source map.
  final String kid;
}

/// RS256 signature primitive seam. Tests inject deterministic fakes
/// (always-accept, always-reject) so [FirebaseProxyJwtVerifier] can
/// be exercised without bringing in an RSA library. Production
/// wires a real implementation (e.g. backed by `pointycastle`).
abstract class JwtRs256SignatureValidator {
  /// Returns true iff the RSASSA-PKCS1-v1_5 signature over
  /// [signedInput] (raw bytes of `<header>.<payload>`) verifies
  /// against the public key embedded in [keyMaterial] using SHA-256.
  /// Implementations must never throw on a merely-invalid signature
  /// — return false instead. They may throw [StateError] when the
  /// validator itself is not configured / installed; the verifier
  /// catches that and surfaces it as a generic verification failure
  /// so production stays fail-closed when the RSA backend is
  /// missing.
  bool verify({
    required Uint8List signedInput,
    required Uint8List signature,
    required JwtKeyMaterial keyMaterial,
  });
}

/// Default fail-closed validator shipped with the 9.1 scaffold.
/// Throws [StateError] on every call so production deploys that
/// forget to wire a real RSA backend reject every Firebase token at
/// the verifier seam (visible to the guard as a 401, never as a
/// silent allow).
class ScaffoldFailingRs256SignatureValidator
    implements JwtRs256SignatureValidator {
  const ScaffoldFailingRs256SignatureValidator();

  @override
  bool verify({
    required Uint8List signedInput,
    required Uint8List signature,
    required JwtKeyMaterial keyMaterial,
  }) {
    throw StateError(
      '9.1 scaffold: real RSA signature validator is not wired — '
      'install a JwtRs256SignatureValidator implementation backed by '
      'a proven RSA library (e.g. pointycastle) before serving real '
      'Firebase tokens.',
    );
  }
}

/// Production RS256 validator for Firebase ID-token signatures.
///
/// Firebase publishes signing keys as PEM x509 certificates keyed by
/// JWT `kid`; this validator extracts the RSA public key from the
/// certificate's SubjectPublicKeyInfo and verifies
/// RSASSA-PKCS1-v1_5/SHA-256 via pointycastle. It also accepts a
/// PEM `PUBLIC KEY` block so tests and local diagnostics can pin a
/// bare SPKI without fabricating an entire certificate.
class PointyCastleRs256SignatureValidator
    implements JwtRs256SignatureValidator {
  const PointyCastleRs256SignatureValidator();

  @override
  bool verify({
    required Uint8List signedInput,
    required Uint8List signature,
    required JwtKeyMaterial keyMaterial,
  }) {
    final publicKey = _rsaPublicKeyFromPem(keyMaterial.pemX509Certificate);
    final signer = pc.Signer('SHA-256/RSA')
      ..init(false, pc.PublicKeyParameter<pc.RSAPublicKey>(publicKey));
    try {
      return signer.verifySignature(
        signedInput,
        pc.RSASignature(Uint8List.fromList(signature)),
      );
    } on ArgumentError {
      return false;
    }
  }

  static pc.RSAPublicKey _rsaPublicKeyFromPem(String pem) {
    final parsed = _decodePem(pem);
    if (parsed.label == 'CERTIFICATE') {
      return _rsaPublicKeyFromCertificateDer(parsed.bytes);
    }
    if (parsed.label == 'PUBLIC KEY') {
      return _rsaPublicKeyFromSubjectPublicKeyInfo(parsed.bytes);
    }
    throw FormatException('unsupported PEM block: ${parsed.label}');
  }

  static pc.RSAPublicKey _rsaPublicKeyFromCertificateDer(Uint8List der) {
    final certificate = _readAsn1Sequence(der, 'certificate');
    final elements = certificate.elements;
    if (elements == null || elements.isEmpty) {
      throw const FormatException('certificate has no tbsCertificate');
    }
    final tbsCertificate = elements.first;
    if (tbsCertificate is! pc.ASN1Sequence) {
      throw const FormatException(
        'certificate tbsCertificate is not a sequence',
      );
    }
    final subjectPublicKeyInfo = _findSubjectPublicKeyInfo(tbsCertificate);
    if (subjectPublicKeyInfo == null) {
      throw const FormatException(
        'certificate missing RSA SubjectPublicKeyInfo',
      );
    }
    return _rsaPublicKeyFromSubjectPublicKeyInfoSequence(subjectPublicKeyInfo);
  }

  static pc.RSAPublicKey _rsaPublicKeyFromSubjectPublicKeyInfo(Uint8List der) {
    return _rsaPublicKeyFromSubjectPublicKeyInfoSequence(
      _readAsn1Sequence(der, 'SubjectPublicKeyInfo'),
    );
  }

  static pc.ASN1Sequence? _findSubjectPublicKeyInfo(pc.ASN1Sequence sequence) {
    final elements = sequence.elements;
    if (elements == null) return null;
    for (final element in elements) {
      if (element is pc.ASN1Sequence && _looksLikeRsaSpki(element)) {
        return element;
      }
      if (element is pc.ASN1Sequence) {
        final nested = _findSubjectPublicKeyInfo(element);
        if (nested != null) return nested;
      }
    }
    return null;
  }

  static bool _looksLikeRsaSpki(pc.ASN1Sequence sequence) {
    final elements = sequence.elements;
    if (elements == null || elements.length != 2) return false;
    final algorithm = elements[0];
    final subjectPublicKey = elements[1];
    if (algorithm is! pc.ASN1Sequence ||
        subjectPublicKey is! pc.ASN1BitString) {
      return false;
    }
    final algorithmElements = algorithm.elements;
    if (algorithmElements == null || algorithmElements.isEmpty) return false;
    final oid = algorithmElements.first;
    return oid is pc.ASN1ObjectIdentifier &&
        oid.objectIdentifierAsString == '1.2.840.113549.1.1.1';
  }

  static pc.RSAPublicKey _rsaPublicKeyFromSubjectPublicKeyInfoSequence(
    pc.ASN1Sequence spki,
  ) {
    if (!_looksLikeRsaSpki(spki)) {
      throw const FormatException('SubjectPublicKeyInfo is not RSA');
    }
    final bitString = spki.elements![1] as pc.ASN1BitString;
    final keyBytes = bitString.stringValues;
    if (keyBytes == null || keyBytes.isEmpty) {
      throw const FormatException('RSA public key bit string is empty');
    }
    final keySequence = _readAsn1Sequence(
      Uint8List.fromList(keyBytes),
      'RSA public key',
    );
    final elements = keySequence.elements;
    if (elements == null ||
        elements.length < 2 ||
        elements[0] is! pc.ASN1Integer ||
        elements[1] is! pc.ASN1Integer) {
      throw const FormatException('RSA public key sequence is malformed');
    }
    final modulus = (elements[0] as pc.ASN1Integer).integer;
    final exponent = (elements[1] as pc.ASN1Integer).integer;
    if (modulus == null || exponent == null) {
      throw const FormatException('RSA public key values are missing');
    }
    return pc.RSAPublicKey(modulus, exponent);
  }

  static pc.ASN1Sequence _readAsn1Sequence(Uint8List bytes, String name) {
    final dynamic object;
    try {
      object = pc.ASN1Parser(bytes).nextObject();
    } catch (_) {
      throw FormatException('$name is not valid DER');
    }
    if (object is! pc.ASN1Sequence) {
      throw FormatException('$name is not an ASN.1 sequence');
    }
    return object;
  }

  static _PemBlock _decodePem(String pem) {
    final lines = LineSplitter.split(pem)
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    if (lines.length < 3 ||
        !lines.first.startsWith('-----BEGIN ') ||
        !lines.first.endsWith('-----') ||
        !lines.last.startsWith('-----END ') ||
        !lines.last.endsWith('-----')) {
      throw const FormatException('invalid PEM block');
    }
    final label = lines.first
        .substring('-----BEGIN '.length, lines.first.length - '-----'.length)
        .trim();
    final endLabel = lines.last
        .substring('-----END '.length, lines.last.length - '-----'.length)
        .trim();
    if (label != endLabel) {
      throw const FormatException('PEM begin/end labels do not match');
    }
    try {
      return _PemBlock(
        label: label,
        bytes: Uint8List.fromList(
          base64Decode(lines.sublist(1, lines.length - 1).join()),
        ),
      );
    } catch (_) {
      throw const FormatException('PEM body is not valid base64');
    }
  }
}

class _PemBlock {
  const _PemBlock({required this.label, required this.bytes});

  final String label;
  final Uint8List bytes;
}

/// Returns the public-key material a Firebase ID token was signed
/// under, looked up by the JWT header `kid`. Implementations cache
/// internally and honor upstream cache control where relevant; the
/// verifier delegates entirely so tests can pin the key map.
abstract class JwksKeySource {
  /// Returns the material for [kid] or null when no matching key
  /// exists in the upstream JWKS. Null means "unknown kid", which
  /// the verifier treats as a hard-reject (no retry).
  Future<JwtKeyMaterial?> publicKeyFor(String kid);
}

/// Production [JwksKeySource] that pulls Firebase ID-token signing
/// certificates from the documented securetoken endpoint and caches
/// the response in-memory. The cache TTL prefers the upstream
/// `Cache-Control: max-age=…` header and falls back to
/// [defaultTtl] when the header is missing or unparseable.
///
/// Endpoint: `https://www.googleapis.com/robot/v1/metadata/x509/`
/// `securetoken@system.gserviceaccount.com` (Firebase ID tokens).
/// Tests can pin a different URL + injected [HttpClient] + clock so
/// no real network call happens.
class FirebaseSecureTokenJwksSource implements JwksKeySource {
  FirebaseSecureTokenJwksSource({
    Uri? endpoint,
    HttpClient? httpClient,
    DateTime Function()? now,
    Duration defaultTtl = const Duration(hours: 6),
  }) : _endpoint = endpoint ?? Uri.parse(_defaultEndpoint),
       _httpClient = httpClient ?? HttpClient(),
       _now = now ?? DateTime.now,
       _defaultTtl = defaultTtl;

  static const String _defaultEndpoint =
      'https://www.googleapis.com/robot/v1/metadata/x509/'
      'securetoken@system.gserviceaccount.com';

  final Uri _endpoint;
  final HttpClient _httpClient;
  final DateTime Function() _now;
  final Duration _defaultTtl;

  Map<String, JwtKeyMaterial>? _cache;
  DateTime? _cacheExpiresAt;

  @override
  Future<JwtKeyMaterial?> publicKeyFor(String kid) async {
    final now = _now();
    final cache = _cache;
    final expiresAt = _cacheExpiresAt;
    if (cache != null && expiresAt != null && now.isBefore(expiresAt)) {
      return cache[kid];
    }
    await _refresh(now);
    return _cache?[kid];
  }

  Future<void> _refresh(DateTime now) async {
    final HttpClientResponse response;
    try {
      final request = await _httpClient.getUrl(_endpoint);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      response = await request.close();
    } catch (error) {
      throw ProxyJwtVerificationError(
        'JWKS fetch failed: ${error.runtimeType}',
      );
    }
    if (response.statusCode != 200) {
      // Drain so the underlying socket is reusable.
      await response.drain<void>();
      throw ProxyJwtVerificationError(
        'JWKS fetch failed: status ${response.statusCode}',
      );
    }
    final body = await response.transform(utf8.decoder).join();
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      throw ProxyJwtVerificationError('JWKS response is not valid JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw ProxyJwtVerificationError('JWKS response is not a JSON object');
    }
    final entries = <String, JwtKeyMaterial>{};
    decoded.forEach((kid, value) {
      if (value is String && value.isNotEmpty) {
        entries[kid] = JwtKeyMaterial(pemX509Certificate: value, kid: kid);
      }
    });
    _cache = entries;
    final maxAge = _maxAgeFromCacheControl(
      response.headers.value(HttpHeaders.cacheControlHeader),
    );
    _cacheExpiresAt = now.add(maxAge ?? _defaultTtl);
  }

  static Duration? _maxAgeFromCacheControl(String? header) {
    if (header == null || header.isEmpty) return null;
    for (final part in header.split(',')) {
      final trimmed = part.trim().toLowerCase();
      if (trimmed.startsWith('max-age=')) {
        final value = int.tryParse(trimmed.substring('max-age='.length).trim());
        if (value != null && value > 0) {
          return Duration(seconds: value);
        }
      }
    }
    return null;
  }
}

/// Local Firebase ID-token verifier. Replaces
/// [ScaffoldRejectingJwtVerifier] in production wiring when
/// [ProxyConfig.firebaseProjectId] is set. Validates:
///
///   - Header `alg = RS256` and `kid` is a non-empty string.
///   - `iss = https://securetoken.google.com/<projectId>`.
///   - `aud = <projectId>`.
///   - `exp > now - leeway` (token not expired).
///   - `iat <= now + leeway` (token not from the future).
///   - `auth_time <= now + leeway` when present.
///   - `sub` is a non-empty string (Firebase UID).
///   - JWKS lookup by `kid` succeeds (no unknown-kid silent allow).
///   - Injected RSA validator verifies the signature.
///
/// On success, projects the tiny Phase 9 custom-claim set onto
/// [ProxyJwtClaims]: `operator_id`, `location_id`, `is_super_admin`,
/// `is_ff_support`, `roles_version`. Tenant-context resolution to
/// Postgres (status check, default location lookup) lands in 9.2.
class FirebaseProxyJwtVerifier implements ProxyJwtVerifier {
  FirebaseProxyJwtVerifier({
    required this.projectId,
    required JwksKeySource keySource,
    required JwtRs256SignatureValidator signatureValidator,
    DateTime Function()? now,
    Duration leeway = const Duration(seconds: 30),
  }) : _keySource = keySource,
       _signatureValidator = signatureValidator,
       _now = now ?? DateTime.now,
       _leeway = leeway;

  final String projectId;
  final JwksKeySource _keySource;
  final JwtRs256SignatureValidator _signatureValidator;
  final DateTime Function() _now;
  final Duration _leeway;

  String get _expectedIssuer => 'https://securetoken.google.com/$projectId';

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final parts = bearerToken.split('.');
    if (parts.length != 3) {
      throw ProxyJwtVerificationError(
        'malformed JWT: expected 3 dot-separated segments',
      );
    }
    final headerJson = _decodeJwtSegment(parts[0], 'header');
    final payloadJson = _decodeJwtSegment(parts[1], 'payload');
    final signatureBytes = _base64UrlDecodeBytes(parts[2], 'signature');

    final alg = headerJson['alg'];
    if (alg != 'RS256') {
      throw ProxyJwtVerificationError(
        'unsupported JWT alg: ${alg is String ? alg : '(missing)'}',
      );
    }
    final dynamic kidRaw = headerJson['kid'];
    if (kidRaw is! String || kidRaw.isEmpty) {
      throw ProxyJwtVerificationError('JWT header missing kid');
    }
    final kid = kidRaw;

    final issuer = payloadJson['iss'];
    if (issuer != _expectedIssuer) {
      throw ProxyJwtVerificationError(
        'unexpected issuer (expected Firebase project issuer)',
      );
    }
    final audience = payloadJson['aud'];
    if (audience != projectId) {
      throw ProxyJwtVerificationError(
        'unexpected audience (expected Firebase project ID)',
      );
    }

    final now = _now();
    final exp = _readEpochSecondsClaim(payloadJson, 'exp');
    if (exp == null) {
      throw ProxyJwtVerificationError('JWT missing exp claim');
    }
    if (now.isAfter(exp.add(_leeway))) {
      throw ProxyJwtVerificationError('JWT expired');
    }
    final iat = _readEpochSecondsClaim(payloadJson, 'iat');
    if (iat == null) {
      throw ProxyJwtVerificationError('JWT missing iat claim');
    }
    if (iat.isAfter(now.add(_leeway))) {
      throw ProxyJwtVerificationError('JWT iat is in the future');
    }
    final authTime = _readEpochSecondsClaim(payloadJson, 'auth_time');
    if (authTime != null && authTime.isAfter(now.add(_leeway))) {
      throw ProxyJwtVerificationError('JWT auth_time is in the future');
    }

    final dynamic subRaw = payloadJson['sub'];
    if (subRaw is! String || subRaw.isEmpty) {
      throw ProxyJwtVerificationError('JWT sub missing or empty');
    }
    final sub = subRaw;

    final keyMaterial = await _keySource.publicKeyFor(kid);
    if (keyMaterial == null) {
      throw ProxyJwtVerificationError('no matching JWK for kid');
    }

    final signedInputBytes = Uint8List.fromList(
      utf8.encode('${parts[0]}.${parts[1]}'),
    );
    final bool signatureValid;
    try {
      signatureValid = _signatureValidator.verify(
        signedInput: signedInputBytes,
        signature: signatureBytes,
        keyMaterial: keyMaterial,
      );
    } on StateError catch (_) {
      // RSA backend not wired — fail closed at the verifier boundary
      // so the guard still returns 401, never a 500 leak. The
      // detailed StateError message stays in process logs.
      throw ProxyJwtVerificationError('signature verification unavailable');
    } catch (_) {
      throw ProxyJwtVerificationError('signature verification failed');
    }
    if (!signatureValid) {
      throw ProxyJwtVerificationError('JWT signature did not verify');
    }

    return ProxyJwtClaims(
      userId:
          _readOptionalString(payloadJson, 'postgres_user_id') ??
          _readOptionalString(payloadJson, 'user_id') ??
          sub,
      firebaseUid: sub,
      operatorId: _readOptionalString(payloadJson, 'operator_id'),
      locationId: _readOptionalString(payloadJson, 'location_id'),
      roles: _resolveRoles(payloadJson),
      actorKind: 'user',
      rolesVersion: _readOptionalInt(payloadJson, 'roles_version'),
      lastFreshAuthAt: authTime,
    );
  }

  static Map<String, Object?> _decodeJwtSegment(String segment, String name) {
    final bytes = _base64UrlDecodeBytes(segment, name);
    final String json;
    try {
      json = utf8.decode(bytes);
    } catch (_) {
      throw ProxyJwtVerificationError('JWT $name is not valid UTF-8');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      throw ProxyJwtVerificationError('JWT $name is not valid JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw ProxyJwtVerificationError('JWT $name is not a JSON object');
    }
    return Map<String, Object?>.from(decoded);
  }

  static Uint8List _base64UrlDecodeBytes(String input, String name) {
    var padded = input;
    final remainder = padded.length % 4;
    if (remainder != 0) {
      padded = padded + '=' * (4 - remainder);
    }
    try {
      return Uint8List.fromList(base64Url.decode(padded));
    } catch (_) {
      throw ProxyJwtVerificationError('JWT $name is not valid base64url');
    }
  }

  static DateTime? _readEpochSecondsClaim(
    Map<String, Object?> payload,
    String claim,
  ) {
    final raw = payload[claim];
    if (raw is int) {
      return DateTime.fromMillisecondsSinceEpoch(raw * 1000, isUtc: true);
    }
    if (raw is double) {
      return DateTime.fromMillisecondsSinceEpoch(
        (raw * 1000).round(),
        isUtc: true,
      );
    }
    return null;
  }

  static String? _readOptionalString(Map<String, Object?> payload, String key) {
    final raw = payload[key];
    if (raw is String && raw.isNotEmpty) return raw;
    return null;
  }

  static int? _readOptionalInt(Map<String, Object?> payload, String key) {
    final raw = payload[key];
    if (raw is int) return raw;
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  static List<String> _resolveRoles(Map<String, Object?> payload) {
    // Phase 9 custom-claim policy keeps the JWT under 200 bytes, so
    // the verifier projects only boolean role flags + roles_version
    // here. Full RBAC resolution (deny-wins, role bundles, custom
    // roles) lives in 9.6 and runs against Postgres after the guard
    // has resolved scope.
    final roles = <String>[];
    if (payload['is_super_admin'] == true) {
      roles.add('super_admin');
    }
    if (payload['is_ff_support'] == true) {
      roles.add('ff_support');
    }
    final rolesVersion = payload['roles_version'];
    if (rolesVersion is int) {
      roles.add('roles_version:$rolesVersion');
    }
    return roles;
  }
}

// ─── Bearer token extraction ─────────────────────────────────────────────────

/// Extracts the token portion of an `Authorization: Bearer <token>`
/// header. Returns null for missing / empty / non-bearer / blank-token
/// headers. Strict: the `Bearer ` prefix must be exact (case-sensitive
/// per RFC 6750 §2.1).
String? extractBearerToken(String? authorizationHeader) {
  if (authorizationHeader == null) return null;
  final value = authorizationHeader;
  const prefix = 'Bearer ';
  if (!value.startsWith(prefix)) return null;
  final token = value.substring(prefix.length).trim();
  return token.isEmpty ? null : token;
}

// ─── Operator scope + request guard ──────────────────────────────────────────

/// Scoped operator context derived from a verified JWT. Downstream
/// retrieval / provider code reads `operatorId` + `locationId` from
/// here; raw JWT claims do not flow past the guard.
class OperatorContext {
  const OperatorContext({
    required this.userId,
    required this.operatorId,
    required this.locationId,
    required this.roles,
    this.actorKind = 'user',
    this.servicePrincipalId,
    this.firebaseUid,
    this.rolesVersion = 0,
    this.lastFreshAuthAt,
  });

  final String userId;
  final String operatorId;
  final String locationId;
  final List<String> roles;
  final String actorKind;
  final String? servicePrincipalId;
  final String? firebaseUid;
  final int rolesVersion;
  final DateTime? lastFreshAuthAt;

  bool hasRole(String role) => roles.contains(role);
  bool get isServicePrincipal => actorKind == 'service';
}

class ProxyAuthError implements Exception {
  ProxyAuthError(this.message, {required this.statusCode});

  final String message;

  /// HTTP status the route handler should return.
  final int statusCode;

  @override
  String toString() => message;
}

class ProxyRequestGuard {
  ProxyRequestGuard({required ProxyJwtVerifier verifier})
    : _verifier = verifier;

  final ProxyJwtVerifier _verifier;

  /// Verifies the Authorization bearer token without requiring tenant scope.
  ///
  /// Global F&F admin surfaces such as 11A.1 operator/location management use
  /// this path because Phase 9 keeps admin custom claims tiny and does not
  /// require `operator_id` / `location_id` for global super-admin visibility.
  Future<ProxyJwtClaims> requireVerifiedClaims({
    required String? authorizationHeader,
  }) async {
    final token = extractBearerToken(authorizationHeader);
    if (token == null) {
      throw ProxyAuthError(
        'missing or malformed Authorization bearer token',
        statusCode: 401,
      );
    }

    try {
      return await _verifier.verify(token);
    } on ProxyJwtVerificationError catch (error) {
      throw ProxyAuthError(
        'token verification failed: ${error.message}',
        statusCode: 401,
      );
    }
  }

  /// Resolves a scoped [OperatorContext] from an Authorization header.
  ///
  ///   - Missing / malformed header -> 401.
  ///   - Token verification failure -> 401.
  ///   - Verified token without operator/location scope -> 403.
  ///
  /// Successful return implies (a) the JWT is verified and (b) the
  /// caller has both an `operatorId` and a `locationId`.
  Future<OperatorContext> requireOperatorContext({
    required String? authorizationHeader,
  }) async {
    final claims = await requireVerifiedClaims(
      authorizationHeader: authorizationHeader,
    );

    final operatorId = claims.operatorId;
    final locationId = claims.locationId;
    if (operatorId == null ||
        operatorId.isEmpty ||
        locationId == null ||
        locationId.isEmpty) {
      throw ProxyAuthError(
        'verified token is missing operator or location scope',
        statusCode: 403,
      );
    }

    return OperatorContext(
      userId: claims.userId,
      operatorId: operatorId,
      locationId: locationId,
      roles: claims.roles,
      actorKind: claims.actorKind,
      servicePrincipalId: claims.servicePrincipalId,
      firebaseUid: claims.firebaseUid,
      rolesVersion: claims.rolesVersion ?? _rolesVersionFromRoles(claims.roles),
      lastFreshAuthAt: claims.lastFreshAuthAt,
    );
  }

  static int _rolesVersionFromRoles(List<String> roles) {
    for (final role in roles) {
      if (!role.startsWith('roles_version:')) continue;
      final parsed = int.tryParse(role.substring('roles_version:'.length));
      if (parsed != null) return parsed;
    }
    return 0;
  }
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
    } catch (_) {
      // Any other store-side failure (timeout, network, parse, postgres
      // exception, etc.) also fails closed at 503. The reason is
      // intentionally generic — raw error contents may contain secrets,
      // connection strings, or stack-trace fragments and must not leak
      // through the HTTP response.
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
    } catch (_) {
      // Swallow — see method docs. The next minute bucket recovers.
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
    final payload = <String, Object?>{
      'issued_by_user_id': command.operator.userId,
      'service_principal_id': principal.id,
      'scopes': principal.scopes,
      'issued_at': issuedAt.toIso8601String(),
      'expires_at': expiresAt.toIso8601String(),
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

abstract class ProxyAccountingStartResult {
  const ProxyAccountingStartResult();
}

class ProxyAccountingReserved extends ProxyAccountingStartResult {
  const ProxyAccountingReserved({required this.capStatus});

  final ProxyCapStatus capStatus;
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

  Future<void> completeRequest({
    required OperatorContext operator,
    required String idempotencyKey,
    required Map<String, Object?> responsePayload,
    required DateTime now,
  });
}

class PostgresProxyAccountingStore implements ProxyAccountingStore {
  PostgresProxyAccountingStore({required TenantTransactionWrapper wrapper})
    : _wrapper = wrapper;

  final TenantTransactionWrapper _wrapper;

  @override
  Future<ProxyAccountingStartResult> startRequest({
    required String idempotencyKey,
    required String requestType,
    required OperatorContext operator,
    required String usageClass,
    required ProxyUsageTelemetry telemetry,
    required ProxyUsageChargeEstimate estimate,
    required DateTime now,
  }) {
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

    return _wrapper.runInTenantContext(ctx, (exec) async {
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

      return ProxyAccountingReserved(capStatus: capStatus);
    });
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
  }) async {
    final ctx = _tenantContextFor(operator);
    final affected = await _wrapper.runInTenantContext(ctx, (exec) {
      return exec.execute(
        ProxyUsageLogSql.completionUpdate,
        parameters: <String, Object?>{
          'operator_id': operator.operatorId,
          'location_id': operator.locationId,
          'idempotency_key': idempotencyKey,
          'response_payload': jsonEncode(responsePayload),
          'completed_at': now.toUtc().toIso8601String(),
        },
      );
    });
    if (affected == 0) {
      throw StateError('proxy accounting completion row was not found');
    }
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
  }) async {
    throw StateError(
      '11a.11d scaffold: real Postgres accounting store is not wired.',
    );
  }
}

abstract class ProxyHealthCheckStore {
  Future<ProxyHealthStatus> check();
}

class ProxyHealthStatus {
  const ProxyHealthStatus({
    required this.postgresOk,
    required this.ageOk,
    required this.pgvectorOk,
    this.metrics = const <String, ProxyHealthMetric>{},
    this.surfaces = const <String, ProxyHealthSurface>{},
    this.useFullEnvelope = true,
  });

  final bool postgresOk;
  final bool ageOk;
  final bool pgvectorOk;
  final Map<String, ProxyHealthMetric> metrics;
  final Map<String, ProxyHealthSurface> surfaces;

  /// When `false` (feature flag `health_envelope_full_v1` disabled),
  /// the response renders only the original B42 reserved 11 metrics
  /// + 6 surfaces — used as a rollback path if the expanded envelope
  /// regresses.
  final bool useFullEnvelope;

  bool get ok => postgresOk && ageOk && pgvectorOk;

  Map<String, Object?> toJson({required DateTime checkedAt}) {
    final reservedMetrics = useFullEnvelope
        ? proxyHealthReservedMetrics
        : _legacyReservedProxyHealthMetrics;
    final reservedSurfaces = useFullEnvelope
        ? proxyHealthReservedSurfaces
        : _legacyReservedProxyHealthSurfaces;

    final metricEnvelope = <String, ProxyHealthMetric>{
      ...reservedMetrics,
      ...<String, ProxyHealthMetric>{
        for (final entry in metrics.entries)
          entry.key: _enrichMetricWithReservedTier(
            entry.value,
            reservedMetrics[entry.key],
          ),
      },
    };
    // Surface envelope: start from reserved templates, then apply caller
    // overrides, then derive each surface's status from the rolled-up
    // status of its constituent metrics so the surfaces never drift
    // from the metrics.
    final mergedSurfaces = <String, ProxyHealthSurface>{
      ...reservedSurfaces,
      ...surfaces,
    };
    final surfaceEnvelope = <String, ProxyHealthSurface>{
      for (final entry in mergedSurfaces.entries)
        entry.key: entry.value.copyWith(
          status: _rollUpSurfaceStatus(entry.value, metricEnvelope),
        ),
    };

    final hasMetricProblem =
        _hasYellowOrRedMetric(metricEnvelope) ||
        _hasYellowOrRedSurface(surfaceEnvelope);
    final status = !ok
        ? 'unavailable'
        : hasMetricProblem
        ? 'degraded'
        : 'ok';
    final severity = _tieredOverallSeverity(
      dependenciesOk: ok,
      metrics: metricEnvelope,
    );

    final warnings = <Map<String, Object?>>[];
    for (final entry in metricEnvelope.entries) {
      final warning = entry.value.metadata['warning'];
      if (warning is String) {
        warnings.add(<String, Object?>{
          'metric': entry.key,
          'warning': warning,
          if (entry.value.metadata['budget_ms'] != null)
            'budget_ms': entry.value.metadata['budget_ms'],
        });
      }
    }

    return <String, Object?>{
      'status': status,
      'severity': severity,
      'contract': 'proxy_health.v1',
      'schema_version': 1,
      'checked_at': checkedAt.toUtc().toIso8601String(),
      'envelope_variant': useFullEnvelope ? 'full_v1' : 'legacy_b42',
      'dependencies': <String, Object?>{
        'postgres': _dependencyJson(
          ok: postgresOk,
          check: 'select_1',
          legacyKey: 'postgres_select_1',
        ),
        'age': _dependencyJson(
          ok: ageOk,
          check: 'cypher_match',
          legacyKey: 'age_cypher_match',
        ),
        'pgvector': _dependencyJson(
          ok: pgvectorOk,
          check: 'similarity',
          legacyKey: 'pgvector_similarity',
        ),
      },
      'surfaces': <String, Object?>{
        for (final entry in surfaceEnvelope.entries)
          entry.key: entry.value.toJson(),
      },
      'metrics': <String, Object?>{
        for (final entry in metricEnvelope.entries)
          entry.key: entry.value.toJson(),
      },
      'warnings': warnings,
      // Compatibility aliases for the first deep-health implementation.
      'postgres_select_1': postgresOk ? 'ok' : 'failed',
      'age_cypher_match': ageOk ? 'ok' : 'failed',
      'pgvector_similarity': pgvectorOk ? 'ok' : 'failed',
    };
  }
}

class ProxyHealthMetric {
  const ProxyHealthMetric({
    required this.status,
    required this.value,
    required this.unit,
    required this.description,
    required this.owner,
    this.source,
    this.observedAt,
    this.thresholds = const <String, Object?>{},
    this.metadata = const <String, Object?>{},
  });

  final String status;
  final Object? value;
  final String unit;
  final String description;
  final String owner;
  final String? source;
  final DateTime? observedAt;
  final Map<String, Object?> thresholds;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status,
    'value': value,
    'unit': unit,
    'description': description,
    'source': source,
    'owner': owner,
    'observed_at': observedAt?.toUtc().toIso8601String(),
    'thresholds': thresholds,
    'metadata': metadata,
  };
}

class ProxyHealthSurface {
  const ProxyHealthSurface({
    required this.status,
    required this.metrics,
    required this.owner,
  });

  final String status;
  final List<String> metrics;
  final String owner;

  ProxyHealthSurface copyWith({String? status}) => ProxyHealthSurface(
    status: status ?? this.status,
    metrics: metrics,
    owner: owner,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status,
    'metrics': metrics,
    'owner': owner,
  };
}

Map<String, Object?> _dependencyJson({
  required bool ok,
  required String check,
  required String legacyKey,
}) => <String, Object?>{
  'status': ok ? 'green' : 'red',
  'check': check,
  'legacy_key': legacyKey,
};

bool _hasYellowOrRedMetric(Map<String, ProxyHealthMetric> metrics) => metrics
    .values
    .any((metric) => metric.status == 'yellow' || metric.status == 'red');

bool _hasYellowOrRedSurface(Map<String, ProxyHealthSurface> surfaces) =>
    surfaces.values.any(
      (surface) => surface.status == 'yellow' || surface.status == 'red',
    );

/// Tier-aware overall severity computation per the B42 contract:
/// - Red:    any dependency probe is bad, OR any Tier-1 metric is non-green
/// - Yellow: any Tier-2 metric is non-green
/// - Green:  otherwise
///
/// Tier-3 metrics never bump severity. They drive Status: degraded only
/// when populated red/yellow (so the ops console can still see them) but
/// the [severity] flag stays green so operators are not paged for cost-
/// observability noise.
String _tieredOverallSeverity({
  required bool dependenciesOk,
  required Map<String, ProxyHealthMetric> metrics,
}) {
  if (!dependenciesOk) {
    return 'red';
  }
  for (final metric in metrics.values) {
    final tier = _metricTier(metric);
    if (tier == 1 &&
        (metric.status == 'red' || metric.status == 'yellow')) {
      return 'red';
    }
  }
  for (final metric in metrics.values) {
    final tier = _metricTier(metric);
    if (tier == 2 &&
        (metric.status == 'red' || metric.status == 'yellow')) {
      return 'yellow';
    }
  }
  return 'green';
}

int _metricTier(ProxyHealthMetric metric) {
  final raw = metric.metadata['tier'];
  if (raw is int) return raw;
  if (raw is String) return int.tryParse(raw) ?? 3;
  return 3;
}

/// When a caller passes a metric override for a reserved key without a
/// `tier` metadata entry, fold the reserved metric's tier in so severity
/// computation does not silently downgrade a Tier-1/Tier-2 producer to
/// Tier-3.
ProxyHealthMetric _enrichMetricWithReservedTier(
  ProxyHealthMetric metric,
  ProxyHealthMetric? reserved,
) {
  if (reserved == null) return metric;
  if (metric.metadata.containsKey('tier')) return metric;
  final reservedTier = reserved.metadata['tier'];
  if (reservedTier == null) return metric;
  return ProxyHealthMetric(
    status: metric.status,
    value: metric.value,
    unit: metric.unit,
    description: metric.description,
    source: metric.source,
    owner: metric.owner,
    observedAt: metric.observedAt,
    thresholds: metric.thresholds,
    metadata: <String, Object?>{
      ...metric.metadata,
      'tier': reservedTier,
    },
  );
}

String _rollUpSurfaceStatus(
  ProxyHealthSurface surface,
  Map<String, ProxyHealthMetric> metrics,
) {
  var hasRed = false;
  var hasYellow = false;
  var hasUnknown = false;
  var hasGreen = false;
  for (final key in surface.metrics) {
    final metric = metrics[key];
    if (metric == null) continue;
    switch (metric.status) {
      case 'red':
        hasRed = true;
        break;
      case 'yellow':
        hasYellow = true;
        break;
      case 'green':
        hasGreen = true;
        break;
      case 'unknown':
      default:
        hasUnknown = true;
        break;
    }
  }
  if (hasRed) return 'red';
  if (hasYellow) return 'yellow';
  if (hasGreen && !hasUnknown) return 'green';
  if (hasGreen) return 'green'; // some unknown but no red/yellow → green wins.
  return 'unknown';
}

/// The original B42 reserved-11 metric set. Used when the
/// `health_envelope_full_v1` feature flag is OFF as the rollback path.
const Map<String, ProxyHealthMetric> _legacyReservedProxyHealthMetrics =
    <String, ProxyHealthMetric>{
      'audit_chain_lag_seconds': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'seconds',
        description:
            'Lag between current audit chain head and latest durable audit anchor.',
        source: 'audit_chain_anchors',
        owner: 'B37/B43',
        metadata: <String, Object?>{'tier': 1},
      ),
      'event_outbox_undelivered_count': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: 'Undelivered event_outbox rows awaiting bridge delivery.',
        source: 'event_outbox',
        owner: 'Phase 10a',
        thresholds: <String, Object?>{'yellow': 10000, 'red': 100000},
        metadata: <String, Object?>{'tier': 2},
      ),
      'event_outbox_lag_seconds': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'seconds',
        description: 'Age of the oldest undelivered event_outbox row.',
        source: 'event_outbox',
        owner: 'Phase 10a',
        thresholds: <String, Object?>{'yellow': 60, 'red': 300},
        metadata: <String, Object?>{'tier': 2},
      ),
      'usage_caps_breach_count': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: 'Requests refused because usage caps were reached.',
        source: 'proxy usage accounting',
        owner: 'B33',
        metadata: <String, Object?>{'tier': 2},
      ),
      'graph_node_count': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: 'Canonical graph node count for operations health.',
        source: 'public.graph_health_metrics()',
        owner: 'B44',
        metadata: <String, Object?>{'tier': 2},
      ),
      'graph_edge_count': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: 'Canonical active graph edge count for operations health.',
        source: 'public.graph_health_metrics()',
        owner: 'B44',
        thresholds: <String, Object?>{'yellow': 3000000, 'red': 4000000},
        metadata: <String, Object?>{'tier': 2},
      ),
      'graph_traversal_latency_ms': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'milliseconds',
        description: 'Graph traversal latency from the graph benchmark slice.',
        source: 'graph benchmark',
        owner: 'B44',
        metadata: <String, Object?>{'tier': 2},
      ),
      'vector_index_size_per_corpus': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: 'Per-corpus vector index size.',
        source: 'vector index health helper',
        owner: 'B47',
        metadata: <String, Object?>{'tier': 2},
      ),
      'vector_query_latency_ms': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'milliseconds',
        description: 'Filtered vector search latency summary.',
        source: 'filtered-search benchmark',
        owner: 'B47',
        metadata: <String, Object?>{'tier': 2},
      ),
      'vector_recall': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'ratio',
        description: 'Filtered vector search benchmark recall.',
        source: 'filtered-search benchmark',
        owner: 'B47',
        metadata: <String, Object?>{'tier': 2},
      ),
      'rollup_freshness_per_grain': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'seconds',
        description: 'Rollup freshness lag grouped by grain.',
        source: 'RollupFreshnessReporter.snapshot()',
        owner: 'B45',
        metadata: <String, Object?>{'tier': 2},
      ),
    };

const Map<String, ProxyHealthSurface> _legacyReservedProxyHealthSurfaces =
    <String, ProxyHealthSurface>{
      'audit_chain': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>['audit_chain_lag_seconds'],
        owner: 'B37/B43',
      ),
      'event_outbox': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'event_outbox_undelivered_count',
          'event_outbox_lag_seconds',
        ],
        owner: 'Phase 10a',
      ),
      'usage_caps': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>['usage_caps_breach_count'],
        owner: 'B33',
      ),
      'graph': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'graph_node_count',
          'graph_edge_count',
          'graph_traversal_latency_ms',
        ],
        owner: 'B44',
      ),
      'vector': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'vector_index_size_per_corpus',
          'vector_query_latency_ms',
          'vector_recall',
        ],
        owner: 'B47',
      ),
      'rollups': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>['rollup_freshness_per_grain'],
        owner: 'B45',
      ),
    };

/// Full B42 producer catalog — 57 reserved metric slots covering every
/// signal the producer registry knows how to fill. Slots without a live
/// producer simply render with `status: 'unknown'`, `value: null`.
const Map<String, ProxyHealthMetric> proxyHealthReservedMetrics =
    <String, ProxyHealthMetric>{
      // ── Tier 1 — foundation/auth/audit ─────────────────────────────
      'audit_chain_lag_seconds': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'seconds',
        description:
            'Lag between current audit chain head and latest durable audit anchor.',
        source: 'audit_chain_anchors',
        owner: 'B37/B43',
        thresholds: <String, Object?>{'yellow': 1800, 'red': 21600},
        metadata: <String, Object?>{'tier': 1},
      ),
      'audit_chain_anchor_age_seconds': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'seconds',
        description:
            'Age of the most recent Azure Blob immutable audit anchor.',
        source: 'audit_chain_anchors',
        owner: 'B37/B43',
        thresholds: <String, Object?>{'yellow': 86400, 'red': 172800},
        metadata: <String, Object?>{'tier': 1},
      ),
      'migration_apply_drift_count': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description:
            'Migration files in db/migrations not yet recorded as applied '
            'in proxy_migrations_applied.',
        source: 'proxy_migrations_applied',
        owner: 'B42',
        thresholds: <String, Object?>{'red': 1},
        metadata: <String, Object?>{'tier': 1},
      ),
      'firebase_jwks_fetch_alive': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'boolean',
        description: 'Firebase JWKS fetch succeeded inside cache TTL window.',
        source: 'firebase_jwks_cache_status',
        owner: 'B42',
        metadata: <String, Object?>{'tier': 1},
      ),
      'service_principal_jwt_alive': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'boolean',
        description:
            'service-principal HMAC signer secret loaded and a recent sp: '
            'token verified successfully.',
        source: 'service_principals_signer_status',
        owner: 'B42',
        metadata: <String, Object?>{'tier': 1},
      ),
      'circuit_breaker_anthropic_state': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'state',
        description:
            'Lock 7 circuit breaker state for the Anthropic provider '
            '(closed/half_open/open).',
        source: 'circuit_breaker_state',
        owner: 'B42',
        metadata: <String, Object?>{'tier': 1},
      ),
      'circuit_breaker_voyage_state': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'state',
        description:
            'Lock 7 circuit breaker state for the Voyage provider '
            '(closed/half_open/open).',
        source: 'circuit_breaker_state',
        owner: 'B42',
        metadata: <String, Object?>{'tier': 1},
      ),
      'azure_extensions_present': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description:
            'Required Azure extensions installed (AGE, pgvector, pg_diskann, '
            'pg_cron, pg_partman, pg_stat_statements, pgcrypto).',
        source: 'pg_extension',
        owner: 'B42',
        metadata: <String, Object?>{'tier': 1},
      ),
      'pg_cron_scheduler_alive': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'boolean',
        description:
            'pg_cron scheduler reported a successful run inside the last '
            '5 minutes.',
        source: 'cron.job_run_details',
        owner: 'B42',
        thresholds: <String, Object?>{'red_seconds_since_last_run': 300},
        metadata: <String, Object?>{'tier': 1},
      ),
      'proxy_idempotency_cache_alive': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'boolean',
        description:
            'proxy_requests idempotency table reachable and accepting reads.',
        source: 'proxy_requests',
        owner: 'B42',
        metadata: <String, Object?>{'tier': 1},
      ),
      // ── Tier 2 — production hardening ──────────────────────────────
      'event_outbox_undelivered_count': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: 'Undelivered event_outbox rows awaiting bridge delivery.',
        source: 'event_outbox',
        owner: 'Phase 10a',
        thresholds: <String, Object?>{'yellow': 10000, 'red': 100000},
        metadata: <String, Object?>{'tier': 2},
      ),
      'event_outbox_lag_seconds': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'seconds',
        description: 'Age of the oldest undelivered event_outbox row.',
        source: 'event_outbox',
        owner: 'Phase 10a',
        thresholds: <String, Object?>{'yellow': 60, 'red': 300},
        metadata: <String, Object?>{'tier': 2},
      ),
      'event_outbox_publish_error_rate': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'ratio',
        description:
            'Rolling 5-minute event_outbox publish error rate (Decision 33).',
        source: 'event_outbox_publish_metrics',
        owner: 'Phase 10a',
        thresholds: <String, Object?>{'yellow': 0.01, 'red': 0.05},
        metadata: <String, Object?>{'tier': 2},
      ),
      'notify_queue_usage_ratio': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'ratio',
        description: 'pg_notification_queue_usage() (Decision 33).',
        source: 'pg_notification_queue_usage',
        owner: 'Phase 10a',
        thresholds: <String, Object?>{'yellow': 0.10, 'red': 0.25},
        metadata: <String, Object?>{'tier': 2},
      ),
      'graph_node_count': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: 'Canonical graph node count for operations health.',
        source: 'public.graph_health_metrics()',
        owner: 'B44',
        metadata: <String, Object?>{'tier': 2},
      ),
      'graph_edge_count': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description:
            'Canonical active graph edge count for operations health '
            '(Decision 30: yellow 3M, red 4M).',
        source: 'public.graph_health_metrics()',
        owner: 'B44',
        thresholds: <String, Object?>{'yellow': 3000000, 'red': 4000000},
        metadata: <String, Object?>{'tier': 2},
      ),
      'graph_traversal_latency_ms': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'milliseconds',
        description:
            'Graph traversal p95 latency from the latest benchmark. '
            'Lock 3 isolated-p95 gate: yellow 250ms, red 500ms.',
        source: 'graph_benchmark_runs',
        owner: 'B44',
        thresholds: <String, Object?>{'yellow': 250, 'red': 500},
        metadata: <String, Object?>{'tier': 2, 'percentile': 'p95'},
      ),
      'graph_traversal_p99_latency_ms': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'milliseconds',
        description: 'Graph traversal p99 latency from the latest benchmark.',
        source: 'graph_benchmark_runs',
        owner: 'B44',
        thresholds: <String, Object?>{'yellow': 750, 'red': 1500},
        metadata: <String, Object?>{'tier': 2},
      ),
      'graph_traversal_timeout_rate': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'ratio',
        description: 'Rolling 5-minute graph traversal timeout rate.',
        source: 'graph_traversal_metrics',
        owner: 'B44',
        thresholds: <String, Object?>{'yellow': 0.01, 'red': 0.05},
        metadata: <String, Object?>{'tier': 2},
      ),
      'graph_high_degree_node_count': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: 'Vertices with degree above the high-degree band.',
        source: 'public.graph_health_metrics()',
        owner: 'B44',
        thresholds: <String, Object?>{'yellow': 100, 'red': 1000},
        metadata: <String, Object?>{'tier': 2},
      ),
      'graph_failed_traversals_count': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: 'Graph traversal failure count over the last 5 minutes.',
        source: 'graph_traversal_metrics',
        owner: 'B44',
        thresholds: <String, Object?>{'yellow': 1, 'red': 100},
        metadata: <String, Object?>{'tier': 2},
      ),
      'graph_projection_age_seconds': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'seconds',
        description: 'Age of the most recent AGE projection rebuild.',
        source: 'graph_projection_runs',
        owner: 'B44',
        thresholds: <String, Object?>{'yellow': 86400, 'red': 604800},
        metadata: <String, Object?>{'tier': 2},
      ),
      'graph_growth_projection_90d_edges': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description:
            '90-day projected edge count (Decision 30: red ≥ 5M triggers '
            'projection rollover planning).',
        source: 'graph_growth_projection',
        owner: 'B44',
        thresholds: <String, Object?>{'red': 5000000},
        metadata: <String, Object?>{'tier': 2},
      ),
      'vector_index_size_per_corpus': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: 'Per-corpus vector index size.',
        source: 'vector_index_health',
        owner: 'B47',
        thresholds: <String, Object?>{'yellow': 5000000, 'red': 8000000},
        metadata: <String, Object?>{'tier': 2},
      ),
      'vector_query_latency_ms': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'milliseconds',
        description: 'Filtered vector search p50 latency.',
        source: 'vector_benchmark_runs',
        owner: 'B47',
        thresholds: <String, Object?>{'yellow': 200, 'red': 400},
        metadata: <String, Object?>{'tier': 2},
      ),
      'vector_recall': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'ratio',
        description: 'Filtered vector search recall@10.',
        source: 'vector_benchmark_runs',
        owner: 'B47',
        thresholds: <String, Object?>{'yellow': 0.85, 'red': 0.70},
        metadata: <String, Object?>{'tier': 2},
      ),
      'vector_query_p99_latency_ms': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'milliseconds',
        description: 'Filtered vector search p99 latency.',
        source: 'vector_benchmark_runs',
        owner: 'B47',
        thresholds: <String, Object?>{'yellow': 600, 'red': 1200},
        metadata: <String, Object?>{'tier': 2},
      ),
      'vector_query_timeout_rate': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'ratio',
        description: 'Rolling 5-minute filtered vector search timeout rate.',
        source: 'vector_query_metrics',
        owner: 'B47',
        thresholds: <String, Object?>{'yellow': 0.01, 'red': 0.05},
        metadata: <String, Object?>{'tier': 2},
      ),
      'vector_active_count_per_corpus': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description:
            'Active vector count per corpus (Decision 31: yellow 5M, red 8M).',
        source: 'vector_index_health',
        owner: 'B47',
        thresholds: <String, Object?>{'yellow': 5000000, 'red': 8000000},
        metadata: <String, Object?>{'tier': 2},
      ),
      'vector_index_build_age_seconds': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'seconds',
        description: 'Age of the most recent vector index build.',
        source: 'vector_index_health',
        owner: 'B47',
        thresholds: <String, Object?>{'yellow': 604800, 'red': 2592000},
        metadata: <String, Object?>{'tier': 2},
      ),
      'vector_growth_projection_90d_count': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description:
            '90-day projected vector count per corpus (Decision 31: red '
            '≥ 10M = DiskANN cutover trigger).',
        source: 'vector_growth_projection',
        owner: 'B47',
        thresholds: <String, Object?>{'red': 10000000},
        metadata: <String, Object?>{'tier': 2},
      ),
      'rollup_freshness_per_grain': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'seconds',
        description: 'Rollup freshness lag grouped by grain.',
        source: 'aggregation_state',
        owner: 'B45',
        thresholds: <String, Object?>{'yellow': 3600, 'red': 21600},
        metadata: <String, Object?>{'tier': 2},
      ),
      'rollup_refresh_lag_seconds': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'seconds',
        description: 'Time since the most recent rollup refresh job ran.',
        source: 'aggregation_state',
        owner: 'B45',
        thresholds: <String, Object?>{'yellow': 3600, 'red': 14400},
        metadata: <String, Object?>{'tier': 2},
      ),
      'rollup_failed_refreshes_count': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: 'pg_cron rollup refreshes that failed in last 24h.',
        source: 'cron.job_run_details',
        owner: 'B45',
        thresholds: <String, Object?>{'yellow': 1, 'red': 5},
        metadata: <String, Object?>{'tier': 2},
      ),
      'rollup_concurrent_refresh_status': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'boolean',
        description:
            'Whether a REFRESH MATERIALIZED VIEW CONCURRENTLY is currently '
            'running.',
        source: 'pg_stat_activity',
        owner: 'B45',
        metadata: <String, Object?>{'tier': 2},
      ),
      'partition_maintenance_last_run_age_seconds': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'seconds',
        description:
            'Age of the last successful pg_partman run_maintenance() (Lock 2).',
        source: 'cron.job_run_details',
        owner: 'B42',
        thresholds: <String, Object?>{'yellow': 7200, 'red': 14400},
        metadata: <String, Object?>{'tier': 2},
      ),
      'partition_default_row_count': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description:
            'Rows landed in the pg_partman default partition for usage_logs '
            '(Lock 2).',
        source: 'usage_logs_default',
        owner: 'B42',
        thresholds: <String, Object?>{'yellow': 1, 'red': 1000},
        metadata: <String, Object?>{'tier': 2},
      ),
      'partition_count_active': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description:
            'Active child partitions registered with pg_partman (Lock 2).',
        source: 'partman.part_config',
        owner: 'B42',
        metadata: <String, Object?>{'tier': 2},
      ),
      'pg_cron_jobs_failed_24h': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: 'pg_cron job runs failed in the last 24 hours.',
        source: 'cron.job_run_details',
        owner: 'B42',
        thresholds: <String, Object?>{'yellow': 1, 'red': 5},
        metadata: <String, Object?>{'tier': 2},
      ),
      'usage_caps_breach_count': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: 'Requests refused because usage caps were reached.',
        source: 'proxy usage accounting',
        owner: 'B33',
        thresholds: <String, Object?>{'yellow': 1, 'red': 100},
        metadata: <String, Object?>{'tier': 2},
      ),
      // ── Tier 3 — ops observability ─────────────────────────────────
      'circuit_breaker_open_count_total': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description:
            'Number of breakers currently in open or half_open state.',
        source: 'circuit_breaker_state',
        owner: 'B42',
        metadata: <String, Object?>{'tier': 3},
      ),
      'fallback_chain_usage_count_anthropic': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description:
            'Requests in last 5 minutes that traversed the Anthropic '
            'fallback chain.',
        source: 'usage_logs',
        owner: 'B42',
        metadata: <String, Object?>{'tier': 3},
      ),
      'fallback_chain_usage_count_voyage': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description:
            'Requests in last 5 minutes that traversed the Voyage '
            'fallback chain.',
        source: 'usage_logs',
        owner: 'B42',
        metadata: <String, Object?>{'tier': 3},
      ),
      'provider_5xx_rate_anthropic': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'ratio',
        description: 'Rolling 5-minute Anthropic 5xx rate.',
        source: 'provider_request_metrics',
        owner: 'B42',
        thresholds: <String, Object?>{'yellow': 0.05, 'red': 0.25},
        metadata: <String, Object?>{'tier': 3},
      ),
      'provider_5xx_rate_voyage': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'ratio',
        description: 'Rolling 5-minute Voyage 5xx rate.',
        source: 'provider_request_metrics',
        owner: 'B42',
        thresholds: <String, Object?>{'yellow': 0.05, 'red': 0.25},
        metadata: <String, Object?>{'tier': 3},
      ),
      'provider_429_rate_anthropic': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'ratio',
        description: 'Rolling 5-minute Anthropic 429 rate.',
        source: 'provider_request_metrics',
        owner: 'B42',
        thresholds: <String, Object?>{'yellow': 0.05, 'red': 0.25},
        metadata: <String, Object?>{'tier': 3},
      ),
      'provider_429_rate_voyage': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'ratio',
        description: 'Rolling 5-minute Voyage 429 rate.',
        source: 'provider_request_metrics',
        owner: 'B42',
        thresholds: <String, Object?>{'yellow': 0.05, 'red': 0.25},
        metadata: <String, Object?>{'tier': 3},
      ),
      'proxy_request_p99_latency_ms': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'milliseconds',
        description: 'Rolling 5-minute proxy request p99 latency.',
        source: 'proxy_request_metrics',
        owner: 'B42',
        thresholds: <String, Object?>{'yellow': 2000, 'red': 5000},
        metadata: <String, Object?>{'tier': 3},
      ),
      'proxy_request_5xx_rate': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'ratio',
        description: 'Rolling 5-minute proxy 5xx response rate.',
        source: 'proxy_request_metrics',
        owner: 'B42',
        thresholds: <String, Object?>{'yellow': 0.01, 'red': 0.05},
        metadata: <String, Object?>{'tier': 3},
      ),
      'prompt_cache_hit_rate': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'ratio',
        description:
            'Anthropic prompt cache hit rate (Hard Promise #9 lever 1).',
        source: 'cache_metrics',
        owner: 'B42',
        thresholds: <String, Object?>{'yellow': 0.30, 'red': 0.10},
        metadata: <String, Object?>{'tier': 3},
      ),
      'response_cache_hit_rate': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'ratio',
        description:
            'Memorystore response cache hit rate (Hard Promise #9 lever 3).',
        source: 'cache_metrics',
        owner: 'B42',
        thresholds: <String, Object?>{'yellow': 0.30, 'red': 0.10},
        metadata: <String, Object?>{'tier': 3},
      ),
      'semantic_cache_hit_rate': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'ratio',
        description:
            'Semantic cache hit rate (Hard Promise #9 lever 3).',
        source: 'cache_metrics',
        owner: 'B42',
        thresholds: <String, Object?>{'yellow': 0.30, 'red': 0.10},
        metadata: <String, Object?>{'tier': 3},
      ),
      'cost_per_query_class_haiku': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'usd',
        description: 'Rolling 1-hour mean cost per Haiku-routed request (USD).',
        source: 'usage_logs',
        owner: 'B42',
        thresholds: <String, Object?>{'yellow_factor': 2.0, 'red_factor': 5.0},
        metadata: <String, Object?>{'tier': 3},
      ),
      'cost_per_query_class_sonnet': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'usd',
        description:
            'Rolling 1-hour mean cost per Sonnet-routed request (USD).',
        source: 'usage_logs',
        owner: 'B42',
        thresholds: <String, Object?>{'yellow_factor': 2.0, 'red_factor': 5.0},
        metadata: <String, Object?>{'tier': 3},
      ),
      'cost_per_query_class_voyage': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'usd',
        description:
            'Rolling 1-hour mean cost per Voyage embedding request (USD).',
        source: 'usage_logs',
        owner: 'B42',
        thresholds: <String, Object?>{'yellow_factor': 2.0, 'red_factor': 5.0},
        metadata: <String, Object?>{'tier': 3},
      ),
      'batch_api_pending_count': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description:
            'Workflow runs in AWAITING_BATCH (Lock 8). Yellow at 100, '
            'red at 1,000.',
        source: 'workflow_runs',
        owner: 'Phase 12.0',
        thresholds: <String, Object?>{'yellow': 100, 'red': 1000},
        metadata: <String, Object?>{'tier': 3},
      ),
      'cloud_run_instance_count': ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'count',
        description: 'Active Cloud Run instance count for the proxy.',
        source: 'cloud_run.instance_metrics',
        owner: 'B42',
        metadata: <String, Object?>{'tier': 3},
      ),
    };

const Map<String, ProxyHealthSurface> proxyHealthReservedSurfaces =
    <String, ProxyHealthSurface>{
      'audit_chain': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'audit_chain_lag_seconds',
          'audit_chain_anchor_age_seconds',
          'migration_apply_drift_count',
        ],
        owner: 'B37/B43',
      ),
      'event_outbox': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'event_outbox_undelivered_count',
          'event_outbox_lag_seconds',
          'event_outbox_publish_error_rate',
          'notify_queue_usage_ratio',
        ],
        owner: 'Phase 10a',
      ),
      'usage_caps': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>['usage_caps_breach_count'],
        owner: 'B33',
      ),
      'graph': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'graph_node_count',
          'graph_edge_count',
          'graph_traversal_latency_ms',
          'graph_traversal_p99_latency_ms',
          'graph_traversal_timeout_rate',
          'graph_high_degree_node_count',
          'graph_failed_traversals_count',
          'graph_projection_age_seconds',
          'graph_growth_projection_90d_edges',
        ],
        owner: 'B44',
      ),
      'vector': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'vector_index_size_per_corpus',
          'vector_query_latency_ms',
          'vector_recall',
          'vector_query_p99_latency_ms',
          'vector_query_timeout_rate',
          'vector_active_count_per_corpus',
          'vector_index_build_age_seconds',
          'vector_growth_projection_90d_count',
        ],
        owner: 'B47',
      ),
      'rollups': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'rollup_freshness_per_grain',
          'rollup_refresh_lag_seconds',
          'rollup_failed_refreshes_count',
          'rollup_concurrent_refresh_status',
        ],
        owner: 'B45',
      ),
      'circuit_breakers': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'circuit_breaker_anthropic_state',
          'circuit_breaker_voyage_state',
          'circuit_breaker_open_count_total',
          'fallback_chain_usage_count_anthropic',
          'fallback_chain_usage_count_voyage',
          'provider_5xx_rate_anthropic',
          'provider_5xx_rate_voyage',
          'provider_429_rate_anthropic',
          'provider_429_rate_voyage',
        ],
        owner: 'B42',
      ),
      'infra': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'azure_extensions_present',
          'pg_cron_scheduler_alive',
          'proxy_idempotency_cache_alive',
          'partition_maintenance_last_run_age_seconds',
          'partition_default_row_count',
          'partition_count_active',
          'pg_cron_jobs_failed_24h',
          'cloud_run_instance_count',
        ],
        owner: 'B42',
      ),
      'auth': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'firebase_jwks_fetch_alive',
          'service_principal_jwt_alive',
        ],
        owner: 'B42',
      ),
      'proxy_traffic': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'proxy_request_p99_latency_ms',
          'proxy_request_5xx_rate',
        ],
        owner: 'B42',
      ),
      'cost': ProxyHealthSurface(
        status: 'unknown',
        metrics: <String>[
          'prompt_cache_hit_rate',
          'response_cache_hit_rate',
          'semantic_cache_hit_rate',
          'cost_per_query_class_haiku',
          'cost_per_query_class_sonnet',
          'cost_per_query_class_voyage',
          'batch_api_pending_count',
        ],
        owner: 'B42',
      ),
    };

class ScaffoldFailingProxyHealthCheckStore implements ProxyHealthCheckStore {
  const ScaffoldFailingProxyHealthCheckStore();

  @override
  Future<ProxyHealthStatus> check() async {
    throw StateError(
      '11a.11d scaffold: real Postgres health checks are not wired.',
    );
  }
}

/// Read-only function shape for the deep-health producer registry. The
/// runtime injects a Postgres-backed runner; tests inject a fake.
typedef ProxyHealthQueryRunnerFn =
    Future<List<Map<String, Object?>>> Function(
      String sql, {
      Map<String, Object?> parameters,
    });

/// Producer functions in `tool/advisor_proxy/health_producers/` use this
/// inputs envelope. Defined here to avoid pulling the family files into
/// the main proxy file. The shape mirrors
/// `health_producers/health_producer.dart::ProxyHealthProducerContext`.
class ProxyHealthRegistryContext {
  const ProxyHealthRegistryContext({
    required this.runnerFn,
    required this.now,
    this.budget = const Duration(milliseconds: 250),
    this.inMemoryBreakerStates,
  });

  final ProxyHealthQueryRunnerFn runnerFn;
  final DateTime now;
  final Duration budget;

  /// Block 2 (Lock 7 v1) — optional accessor into the per-instance
  /// circuit breakers held by `routeRequest`. When non-null, breaker
  /// producers use this snapshot instead of querying the
  /// `circuit_breaker_state` DB table.
  final Map<String, CircuitState> Function()? inMemoryBreakerStates;
}

typedef ProxyHealthRegistryProducer =
    Future<ProxyHealthMetric> Function(ProxyHealthRegistryContext context);

/// Deep-health feature flags. `health_envelope_full_v1` defaults to true
/// (Block 3, task 6); flipping to false reverts the route to the legacy
/// 11-metric envelope as a rollback path.
class ProxyHealthFeatureFlags {
  const ProxyHealthFeatureFlags({
    this.healthEnvelopeFullV1 = true,
  });

  final bool healthEnvelopeFullV1;
}

/// Result envelope for the dependency-probe + producer registry. Used
/// internally by [RegistryProxyHealthCheckStore] before being projected
/// into [ProxyHealthStatus].
class ProxyHealthRegistryResult {
  const ProxyHealthRegistryResult({
    required this.postgresOk,
    required this.ageOk,
    required this.pgvectorOk,
    required this.metrics,
  });

  final bool postgresOk;
  final bool ageOk;
  final bool pgvectorOk;
  final Map<String, ProxyHealthMetric> metrics;
}

/// Drives deep health from a producer catalog + dependency probes.
///
/// Producers receive a [ProxyHealthRegistryContext]; each producer is
/// individually budget-bounded by its body and again by an outer wall-
/// clock guard. A failing producer or timeout never crashes the route —
/// the projection downgrades to `status: 'unknown'`.
class RegistryProxyHealthCheckStore implements ProxyHealthCheckStore {
  RegistryProxyHealthCheckStore({
    required this.runnerFn,
    required this.dependencyProbe,
    required this.producers,
    this.featureFlags = const ProxyHealthFeatureFlags(),
    this.now,
    this.producerBudget = const Duration(milliseconds: 250),
    this.outerProducerBudget = const Duration(milliseconds: 750),
    this.inMemoryBreakerStates,
  });

  final ProxyHealthQueryRunnerFn runnerFn;
  final Future<ProxyHealthDependencyProbe> Function(
    ProxyHealthQueryRunnerFn runnerFn,
    DateTime now,
  )
  dependencyProbe;
  final Map<String, ProxyHealthRegistryProducer> producers;
  final ProxyHealthFeatureFlags featureFlags;
  final DateTime Function()? now;
  final Duration producerBudget;
  final Duration outerProducerBudget;
  final Map<String, CircuitState> Function()? inMemoryBreakerStates;

  @override
  Future<ProxyHealthStatus> check() async {
    final clock = now ?? DateTime.now;
    final asOf = clock();
    final probe = await dependencyProbe(runnerFn, asOf);

    final allowedKeys = featureFlags.healthEnvelopeFullV1
        ? proxyHealthReservedMetrics.keys.toSet()
        : _legacyReservedProxyHealthMetrics.keys.toSet();

    final selected = <String, ProxyHealthRegistryProducer>{
      for (final entry in producers.entries)
        if (allowedKeys.contains(entry.key)) entry.key: entry.value,
    };

    final context = ProxyHealthRegistryContext(
      runnerFn: runnerFn,
      now: asOf,
      budget: producerBudget,
      inMemoryBreakerStates: inMemoryBreakerStates,
    );

    final futures = <Future<MapEntry<String, ProxyHealthMetric>>>[
      for (final entry in selected.entries)
        _runOne(entry.key, entry.value, context),
    ];
    final results = await Future.wait(futures);
    final metrics = <String, ProxyHealthMetric>{
      for (final entry in results) entry.key: entry.value,
    };

    return ProxyHealthStatus(
      postgresOk: probe.postgresOk,
      ageOk: probe.ageOk,
      pgvectorOk: probe.pgvectorOk,
      metrics: metrics,
      useFullEnvelope: featureFlags.healthEnvelopeFullV1,
    );
  }

  Future<MapEntry<String, ProxyHealthMetric>> _runOne(
    String key,
    ProxyHealthRegistryProducer producer,
    ProxyHealthRegistryContext context,
  ) async {
    try {
      final metric = await producer(context).timeout(outerProducerBudget);
      return MapEntry(key, metric);
    } catch (_) {
      final reserved = proxyHealthReservedMetrics[key] ??
          _legacyReservedProxyHealthMetrics[key];
      return MapEntry(
        key,
        ProxyHealthMetric(
          status: 'unknown',
          value: null,
          unit: reserved?.unit ?? 'unknown',
          description:
              reserved?.description ?? 'Producer failed in registry runner.',
          source: reserved?.source,
          owner: reserved?.owner ?? 'B42',
          observedAt: context.now,
          thresholds: reserved?.thresholds ?? const <String, Object?>{},
          metadata: <String, Object?>{
            ...?reserved?.metadata,
            'warning': 'registry_outer_failure',
          },
        ),
      );
    }
  }
}

/// Result of a single dependency probe pass.
class ProxyHealthDependencyProbe {
  const ProxyHealthDependencyProbe({
    required this.postgresOk,
    required this.ageOk,
    required this.pgvectorOk,
  });

  final bool postgresOk;
  final bool ageOk;
  final bool pgvectorOk;
}

/// Default dependency probe — three small queries, each independently
/// budget-bounded.
///
/// Liveness is decoupled from data presence: AGE and pgvector probes
/// check that the *extension* is loaded and round-trip a tiny syntactic
/// value through it (cypher() returns a constant; `'[1,2,3]'::vector`
/// constructs a vector). An empty graph or empty embeddings table must
/// not flip these probes to false because that would tie HTTP 503 to
/// data presence rather than dependency liveness, which the contract
/// forbids.
///
/// Errors and timeouts project to `false` so a flaky extension never
/// crashes the deep-health route.
Future<ProxyHealthDependencyProbe> defaultProxyHealthDependencyProbe(
  ProxyHealthQueryRunnerFn runnerFn,
  DateTime now, {
  Duration budget = const Duration(milliseconds: 250),
}) async {
  Future<bool> probe(String sql) async {
    try {
      final rows = await runnerFn(sql).timeout(budget);
      return rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  final results = await Future.wait(<Future<bool>>[
    // Postgres liveness: server can answer `select 1`.
    probe('select 1 as ok'),
    // AGE liveness: extension is loaded. The contract is "AGE is
    // installed and reachable", not "the graph contains data".
    probe(
      "select 1 as ok from pg_extension where extname = 'age'",
    ),
    // pgvector liveness: extension is loaded AND the `vector` type
    // round-trips a literal value. Independent of any embedding row
    // existing in the database.
    probe(
      "select 1 as ok from pg_extension where extname = 'vector' "
      "and ('[1,2,3]'::vector) is not null",
    ),
  ]);

  return ProxyHealthDependencyProbe(
    postgresOk: results[0],
    ageOk: results[1],
    pgvectorOk: results[2],
  );
}

/// HARD-A — production-grade dependency probe.
///
/// `defaultProxyHealthDependencyProbe` (above) only verifies extension
/// presence. The hardening contract requires the AGE check to actually
/// invoke cypher `MATCH (n) RETURN 1 LIMIT 1` and the pgvector check
/// to compute a real distance, so a regression in either path surfaces
/// as `red` instead of green.
///
/// Each check passes when the SQL call returns without throwing. Row
/// count is not the success criterion — `MATCH (n)` against an empty
/// graph correctly returns zero rows, and an empty graph must not
/// flip the dependency to `red` (that would tie HTTP 503 to data
/// presence rather than dependency liveness).
///
/// Errors and timeouts project to `false` so a flaky extension never
/// crashes the deep-health route.
Future<ProxyHealthDependencyProbe> strictProxyHealthDependencyProbe(
  ProxyHealthQueryRunnerFn runnerFn,
  DateTime now, {
  Duration budget = const Duration(milliseconds: 250),
  String ageGraphName = 'forgeflow',
}) async {
  Future<bool> probe(String sql) async {
    try {
      await runnerFn(sql).timeout(budget);
      return true;
    } catch (_) {
      return false;
    }
  }

  // AGE cypher must be a SINGLE statement so it survives the proxy's
  // prepared-query runner (`package:postgres` `Sql.named(...)` rejects
  // multi-command strings). Fully qualify both the function
  // (`ag_catalog.cypher`) and the result type (`ag_catalog.agtype`)
  // instead of prefixing a `SET search_path` — same effect, one
  // statement. AGE returns zero rows on an empty graph, which still
  // succeeds because the probe's success criterion is "no throw".
  const String ageCypherProbeSql =
      "select * from ag_catalog.cypher('forgeflow', "
      "\$\$ MATCH (n) RETURN 1 LIMIT 1 \$\$) as (v ag_catalog.agtype)";

  final results = await Future.wait(<Future<bool>>[
    // Postgres: `select 1` round-trips through the driver.
    probe('select 1 as ok'),
    // AGE: real cypher MATCH against the canonical graph. Empty graph
    // returns zero rows but does not raise — still green.
    probe(ageCypherProbeSql),
    // pgvector: actual distance operator (`<->`) so a regressed
    // operator surfaces, not just extension presence.
    probe("select '[1,0,0]'::vector <-> '[0,1,0]'::vector as distance"),
  ]);

  return ProxyHealthDependencyProbe(
    postgresOk: results[0],
    ageOk: results[1],
    pgvectorOk: results[2],
  );
}

/// Cross-DB pg_cron via FDW bootstrap.
///
/// Azure Database for PostgreSQL Flexible Server installs `pg_cron` into a
/// single dedicated database (`postgres`). To schedule jobs against the
/// `forgeflow` business database from that scheduler, we expose the
/// business database through a `postgres_fdw` foreign server and a
/// foreign-table mapping. The proxy boots this once at startup if the
/// mapping is missing — idempotent, no-op when already configured.
Future<void> ensureProxyHealthCronFdwBootstrap({
  required ProxyHealthQueryRunnerFn runnerFn,
  String foreignServerName = 'forgeflow_app',
  String foreignDatabase = 'forgeflow',
  Duration budget = const Duration(seconds: 5),
}) async {
  Future<List<Map<String, Object?>>> run(String sql) =>
      runnerFn(sql).timeout(budget);

  // 1. Ensure postgres_fdw is loaded.
  await run('create extension if not exists postgres_fdw');

  // 2. Ensure the foreign server points at the business database. The
  //    server-name lookup is parameterized through a where-clause to
  //    avoid creating duplicates.
  final servers = await run(
    "select srvname from pg_foreign_server where srvname = '$foreignServerName'",
  );
  if (servers.isEmpty) {
    await run(
      "create server $foreignServerName foreign data wrapper postgres_fdw "
      "options (host 'localhost', dbname '$foreignDatabase')",
    );
  }

  // 3. Ensure user mapping for the cron-runner role.
  final mappings = await run(
    "select usename from pg_user_mappings "
    "where srvname = '$foreignServerName' and usename = current_user",
  );
  if (mappings.isEmpty) {
    await run(
      "create user mapping for current_user server $foreignServerName "
      "options (user current_user)",
    );
  }
}

/// Records on-disk migration filenames into `proxy_migrations_applied`
/// at proxy startup so the Tier-1 `migration_apply_drift_count`
/// producer has a registry to compare against. Idempotent — uses
/// `on conflict do nothing` against the unique filename index.
///
/// Returns the count of newly inserted rows; existing rows are not
/// re-touched. The proxy startup logs the count by name only.
class ProxyMigrationApplyRegistryWriter {
  ProxyMigrationApplyRegistryWriter({required this.runnerFn});

  final ProxyHealthQueryRunnerFn runnerFn;

  Future<int> recordAppliedMigrations(
    Iterable<String> migrationFilenames, {
    Duration budget = const Duration(seconds: 10),
  }) async {
    var inserted = 0;
    for (final filename in migrationFilenames) {
      // Defensive: refuse anything but a basename — the registry is
      // a public-schema artefact and must never store a filesystem
      // path.
      if (filename.contains('/') ||
          filename.contains('\\') ||
          filename.contains('..')) {
        throw ArgumentError.value(
          filename,
          'migrationFilenames',
          'must be a basename (no path separators)',
        );
      }
      final rows = await runnerFn(
        'insert into public.proxy_migrations_applied '
        '(migration_filename, observed_by) '
        "values (@filename, 'proxy_startup') "
        'on conflict (migration_filename) do nothing '
        'returning id',
        parameters: <String, Object?>{'filename': filename},
      ).timeout(budget);
      if (rows.isNotEmpty) inserted++;
    }
    return inserted;
  }

  /// Reads the drift function with the supplied expected list and
  /// returns the count + missing filenames. Used by tests and by the
  /// `migration_apply_drift_count` producer for cross-checks.
  Future<({int driftCount, List<String> missing})>
  computeDrift(List<String> expectedFilenames) async {
    final rows = await runnerFn(
      'select drift_count, missing_migrations '
      'from public.proxy_migration_apply_drift(@expected::text[])',
      parameters: <String, Object?>{'expected': expectedFilenames},
    );
    if (rows.isEmpty) {
      return (driftCount: 0, missing: const <String>[]);
    }
    final row = rows.first;
    final driftCount = (row['drift_count'] as num?)?.toInt() ?? 0;
    final missing = row['missing_migrations'];
    final missingList = missing is List
        ? List<String>.from(missing.map((e) => e.toString()))
        : <String>[];
    return (driftCount: driftCount, missing: missingList);
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

  ProxyLlmTier tierFor({
    required String subscriptionTier,
    required String queryClass,
  }) {
    final subscription = subscriptionTier.trim().toLowerCase();
    if (subscription == 'basic' ||
        subscription == 'starter' ||
        subscription == 'pilot' ||
        subscription == 'launch') {
      return ProxyLlmTier.haiku;
    }

    if (_requiresNuancedSynthesis(queryClass)) {
      return ProxyLlmTier.sonnet;
    }
    return ProxyLlmTier.haiku;
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
  return <String, Object?>{
    'type': 'ephemeral',
    'ttl': block.cacheTtl,
  };
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
typedef AnthropicProxyCompleteFn = Future<ProxyLlmCompletePayload> Function({
  required String modelId,
  required String question,
  required String context,
});

/// Adapter signature for a Gemini SDK call. The optional `onChunk`
/// hook lets callers observe streaming chunks; the public
/// [ProxyLlmProvider] surface stays non-streaming so the
/// AdvisorRequestPipeline doesn't need to special-case streamed
/// responses.
typedef GeminiProxyCompleteFn = Future<ProxyLlmCompletePayload> Function({
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

/// Block 2 (Lock 7 v1) — fallback chain executor.
///
/// Wraps the primary [ProxyLlmProvider] with a [CircuitBreaker], an
/// optional [secondaryLlmProvider] (Gemini Flash, Phase 11A.4b), an
/// [AdvisorResponseCache], and a graceful refusal tertiary. The
/// secondary slot was reserved as `// TODO(E.2b)` in v1; this graft
/// fills it with a real `GeminiProxyLlmProvider`. Tests assert that
/// `fallback_used` reports `'gemini'` when the secondary serves.
class AdvisorRequestPipeline {
  AdvisorRequestPipeline({
    required this.breaker,
    required this.cache,
    this.secondaryLlmProvider,
  });

  final CircuitBreaker breaker;
  final AdvisorResponseCache cache;

  /// Phase 11A.4b — optional Gemini Flash secondary. When non-null and
  /// the primary fails (or the breaker is open), the pipeline tries
  /// the secondary BEFORE falling through to the cache. A successful
  /// secondary call returns `fallbackUsed: 'gemini'`. The secondary
  /// is intentionally not protected by its own breaker in this slice
  /// — that is a follow-up.
  final ProxyLlmProvider? secondaryLlmProvider;

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
    final secondary = secondaryLlmProvider;
    if (secondary != null) {
      try {
        final completion = await secondary.complete(llmRequest);
        return AdvisorPipelineResult(
          completion: completion,
          cachedAnswer: null,
          refused: false,
          circuitStateAtStart: circuitStateAtStart,
          fallbackUsed: 'gemini',
          decision: decision,
        );
      } catch (_) {
        // Gemini also failed. Fall through to cache → refusal.
        // Intentionally NOT wired into the Anthropic breaker —
        // breaker tracks the primary only.
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

const String healthPath = '/healthz';
const String readinessPath = '/readyz';
const String deepHealthPath = '/health';
const String scopeSmokePath = '/v1/scope';
const String usageSmokePath = '/v1/usage-smoke';
const String advisorSmokePath = '/v1/advisor-smoke';

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
const String authMfaFactorsRemovalCancelPath =
    '/v1/auth/mfa/factors/removal/cancel';
const String adminAuthInvitesPath = '/v1/admin/auth/invites';
const String adminAuthInvitePrefix = '$adminAuthInvitesPath/';
const String adminAuthUsersPath = '/v1/admin/auth/users';
const String adminAuthUsersPrefix = '/v1/admin/auth/users/';
const String adminAuthRolesPath = '/v1/admin/auth/roles';
const String adminAuthRolePrefix = '$adminAuthRolesPath/';
const String adminAuthRoleGrantsPath = '/v1/admin/auth/role-grants';
const String adminAuthRoleGrantPrefix = '$adminAuthRoleGrantsPath/';
// Phase 9.UX.4 — org hierarchy admin routes. Reads gate on
// `team.users.view`, mutations on `team.roles.assign` (per the
// hierarchy-touches-grants posture from `phase_9_auth_plan.md`).
const String adminAuthOrgUnitsPath = '/v1/admin/auth/org-units';
const String adminAuthLocationsPrefix = '/v1/admin/auth/locations/';
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
}

// Phase 11A.3a — Corpus admin routes. F&F internal-only with the same
// method-scoped split the pricing surface uses: GET admits
// `super_admin` + `ff_support` so support users can browse the
// corpus ledger; POST stays strictly `super_admin` because uploads,
// commits, and rollbacks rewrite the advisor source corpus.
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
const String adminFeatureFlagsTogglePath =
    '/v1/admin/feature-flags/toggle';

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
  });

  /// Toggle one flag's `enabled` bit by `flagId`. Returns the
  /// post-toggle row JSON. Returns null when no row matches; the
  /// route handler maps that into 404 `unknown_flag`.
  Future<Map<String, Object?>?> toggleFlag({
    required String actorUserId,
    required String flagId,
    required bool enabled,
    required String idempotencyKey,
    required String adminReason,
  });
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

// Phase 9.UX.6 — self-service Audit Log read projection. Auth-gated;
// the proxy resolves user_id from the verified Firebase bearer token
// and ignores any client-supplied user_id. The WHERE clause pins
// user_id (actor or target) so RLS plus the WHERE form a defense in
// depth.
const String authAuditLogPath = '/v1/auth/audit-log';

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
  AuthOperationsGateway? authOperationsGateway,
  ProxyAdminPermissionGuard? adminPermissionGuard,
  ServicePrincipalJwtIssuanceGateway? servicePrincipalJwtIssuanceGateway,
  PasswordChangeGateway? passwordChangeGateway,
  PasswordResetConfirmGateway? passwordResetConfirmGateway,
  PasswordResetRequestGateway? passwordResetRequestGateway,
  ProxyAuthIdempotencyCache? authIdempotencyCache,
  MfaOperationsGateway? mfaOperationsGateway,
  MfaRecoveryRequestGateway? mfaRecoveryRequestGateway,
  OperatorLocationAdminProxyGateway? operatorLocationAdminGateway,
  PricingTierAdminProxyGateway? pricingTierAdminGateway,
  CorpusAdminProxyGateway? corpusAdminGateway,
  GraphCandidatesProxyGateway? graphCandidatesGateway,
  IntegrationAdminProxyGateway? integrationAdminGateway,
  IntegrationAdminActorResolver? integrationAdminActorResolver,
  FeatureFlagsAdminProxyGateway? featureFlagsAdminGateway,
  bool trustProxyAuditHeaders = false,
  ProxyRequestLogPolicy requestLogPolicy =
      const ProxyRequestLogPolicy.metaOnly(),
  DateTime Function()? now,
}) async {
  final response = request.response;
  final clock = now ?? DateTime.now;
  try {
    final path = request.uri.path;
    final isAdminOperatorLocationPath = _isAdminOperatorOrLocationPath(path);
    if (isAdminOperatorLocationPath) {
      _setAdminOperatorLocationCorsHeaders(response);
      if (request.method == 'OPTIONS') {
        response.statusCode = HttpStatus.noContent;
        response.contentLength = 0;
        return;
      }
    }
    final isAdminPricingPath = _isAdminPricingPath(path);
    if (isAdminPricingPath) {
      _setAdminPricingCorsHeaders(response);
      if (request.method == 'OPTIONS') {
        response.statusCode = HttpStatus.noContent;
        response.contentLength = 0;
        return;
      }
    }
    final isAdminCorpusPath = _isAdminCorpusPath(path);
    if (isAdminCorpusPath) {
      _setAdminCorpusCorsHeaders(response);
      if (request.method == 'OPTIONS') {
        response.statusCode = HttpStatus.noContent;
        response.contentLength = 0;
        return;
      }
    }
    final isAdminIntegrationsPath = _isAdminIntegrationsPath(path);
    if (isAdminIntegrationsPath) {
      _setAdminIntegrationsCorsHeaders(response);
      if (request.method == 'OPTIONS') {
        response.statusCode = HttpStatus.noContent;
        response.contentLength = 0;
        return;
      }
    }
    final isAdminFeatureFlagsPath = _isAdminFeatureFlagsPath(path);
    if (isAdminFeatureFlagsPath) {
      _setAdminFeatureFlagsCorsHeaders(response);
      if (request.method == 'OPTIONS') {
        response.statusCode = HttpStatus.noContent;
        response.contentLength = 0;
        return;
      }
    }

    if (request.method == 'GET' &&
        (path == healthPath || path == readinessPath)) {
      _writeJson(response, 200, <String, Object?>{'status': 'ok'});
      return;
    }

    if (request.method == 'GET' && path == deepHealthPath) {
      if (healthCheckStore == null) {
        _writeJson(response, 503, <String, Object?>{
          ...const ProxyHealthStatus(
            postgresOk: false,
            ageOk: false,
            pgvectorOk: false,
          ).toJson(checkedAt: clock().toUtc()),
          'error': 'health_check_not_configured',
          'message': 'route requires a ProxyHealthCheckStore to be installed',
        });
        return;
      }

      ProxyHealthStatus status;
      try {
        status = await healthCheckStore.check();
      } catch (_) {
        _writeJson(response, 503, <String, Object?>{
          ...const ProxyHealthStatus(
            postgresOk: false,
            ageOk: false,
            pgvectorOk: false,
          ).toJson(checkedAt: clock().toUtc()),
          'error': 'health_check_failed',
          'message': 'proxy dependency health check failed',
        });
        return;
      }

      _writeJson(
        response,
        status.ok ? 200 : 503,
        status.toJson(checkedAt: clock().toUtc()),
      );
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
          'message': 'route requires ProxyAccountingStore and ProxyLlmProvider',
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

      final idempotencyKey = request.headers.value('Idempotency-Key')?.trim();
      if (idempotencyKey == null || idempotencyKey.isEmpty) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'missing_idempotency_key',
          'message': 'Idempotency-Key header is required',
        });
        return;
      }

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
      final corpusVersion = _nonBlankOr(params['corpus_version'], 'launch_v1');
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
      } catch (_) {
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
      final questionHash =
          sha256.convert(utf8.encode(question)).toString();

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
        } catch (_) {
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
      final fallbackServedFromCache = pipelineResult.fallbackUsed == 'cache';
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
        circuitState:
            circuitStateToWireString(pipelineResult.circuitStateAtStart),
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
          'cache_key': promptBuilder.cacheKeyForCorpusVersion(corpusVersion),
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
      } catch (_) {
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

      try {
        await accountingStore.completeRequest(
          operator: scope,
          idempotencyKey: idempotencyKey,
          responsePayload: responsePayload,
          now: clock().toUtc(),
        );
      } catch (_) {
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
      } catch (_) {
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
      } catch (_) {
        _writeJson(response, 503, <String, Object?>{
          'error': 'permission_snapshot_unavailable',
          'message': 'permission snapshot is unavailable; please retry',
        });
      }
      return;
    }

    if (request.method == 'POST' && path == authPasswordChangePath) {
      if (passwordChangeGateway == null) {
        _writeJson(response, 503, <String, Object?>{
          'error': 'password_change_not_configured',
          'message': 'route requires a PasswordChangeGateway to be installed',
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
      } catch (_) {
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
      // Idempotency-Key dedupe: a second tap on "Send reset link"
      // (or a network-retry that double-fires the request) must not
      // issue a second Firebase email. The cache replays the prior
      // {200, ok:true} body for the same key inside [ttl].
      final idempotencyKey = request.headers.value('Idempotency-Key')?.trim();
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
          } catch (_) {
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
      final idempotencyKey = request.headers.value('Idempotency-Key')?.trim();
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
          } catch (_) {
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
      } catch (_) {
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
          'message': 'route requires an MfaOperationsGateway to be installed',
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
          final completed = await mfaOperationsGateway.confirmTotpEnrollment(
            MfaTotpConfirmCommand(
              actorUserId: scope.userId,
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              authorizationIdToken: authorizationIdToken,
              factorId: factorId,
              oneTimeCode: oneTimeCode,
              issuerName:
                  _nonBlankString(body['issuer_name']) ?? 'Forge & Flow',
            ),
          );
          _writeJson(response, 200, <String, Object?>{
            'factor_id': completed.factorId,
          });
          return;
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
                  'enrolled_at': factor.enrolledAt.toUtc().toIso8601String(),
                  'last_used_at': factor.lastUsedAt?.toUtc().toIso8601String(),
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
            if (completed.requestId != null) 'request_id': completed.requestId,
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
        stderr.writeln(
          'advisor proxy MFA Identity Toolkit error: '
          'code=${error.code} status=${error.statusCode ?? 'n/a'}',
        );
        _writeJson(response, 503, <String, Object?>{
          'error': error.code,
          'message': 'MFA operation is unavailable; please retry',
        });
        return;
      } catch (error, stackTrace) {
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

      final idempotencyKey = request.headers.value('Idempotency-Key')?.trim();
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
      } catch (_) {
        _writeJson(response, 503, <String, Object?>{
          'error': 'service_principal_issuance_unavailable',
          'message':
              'service principal JWT issuance is unavailable; please retry',
        });
      }
      return;
    }

    if (_isAdminAuthOperation(path, request.method)) {
      if (authOperationsGateway == null) {
        _writeJson(response, 503, <String, Object?>{
          'error': 'auth_operations_not_configured',
          'message': 'route requires an AuthOperationsGateway to be installed',
        });
        return;
      }

      final scope = await _resolveOperatorContextOrWrite(
        request,
        response,
        authGuard,
      );
      if (scope == null) return;

      Future<bool> requirePermission(String permissionKey) {
        return _requireAdminPermissionOrWrite(
          response: response,
          guard: adminPermissionGuard,
          scope: scope,
          permissionKey: permissionKey,
          requestedAt: clock().toUtc(),
        );
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
        if (request.method == 'GET' && path == adminAuthRolesPath) {
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

        if (request.method == 'GET' && path == adminAuthUsersPath) {
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

        if (request.method == 'POST' && path == adminAuthRolesPath) {
          if (!await requirePermission('team.roles.create_custom')) return;
          final roleKey = _nonBlankString(body['role_key']);
          final displayName = _nonBlankString(body['display_name']);
          if (roleKey == null || displayName == null) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_role_fields',
              'message': 'role_key and display_name are required',
            });
            return;
          }
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
          _writeJson(response, 201, <String, Object?>{
            'role': _teamRoleToJson(created.role),
          });
          return;
        }

        if (request.method == 'PATCH' && path.startsWith(adminAuthRolePrefix)) {
          if (!await requirePermission('team.roles.create_custom')) return;
          final roleId = _pathSuffix(path, adminAuthRolePrefix);
          if (roleId == null) {
            _writeJson(response, 404, <String, Object?>{
              'error': 'not found',
              'method': request.method,
              'path': path,
            });
            return;
          }
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
          _writeJson(response, 200, <String, Object?>{
            'role': _teamRoleToJson(patched.role),
            'bumped_users': patched.bumpedUsers,
          });
          return;
        }

        if (request.method == 'DELETE' &&
            path.startsWith(adminAuthRolePrefix)) {
          if (!await requirePermission('team.roles.create_custom')) return;
          final roleId = _pathSuffix(path, adminAuthRolePrefix);
          if (roleId == null) {
            _writeJson(response, 404, <String, Object?>{
              'error': 'not found',
              'method': request.method,
              'path': path,
            });
            return;
          }
          final deleted = await authOperationsGateway.deleteRole(
            TeamRoleDeleteCommand(
              actorUserId: scope.userId,
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              roleId: roleId,
              reason: _nonBlankString(body['reason']),
            ),
          );
          _writeJson(response, 200, <String, Object?>{
            'ok': true,
            'deleted': deleted.deleted,
          });
          return;
        }

        if (request.method == 'POST' && path == adminAuthInvitesPath) {
          if (!await requirePermission('team.users.invite')) return;
          final email = _nonBlankString(body['email']);
          final roleId = _nonBlankString(body['role_id']);
          final scopeType = _nonBlankString(body['scope_type']);
          if (email == null || roleId == null || scopeType == null) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_invite_fields',
              'message': 'email, role_id, and scope_type are required',
            });
            return;
          }
          final created = await authOperationsGateway.createInvite(
            TeamInviteCreateCommand(
              actorUserId: scope.userId,
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              email: email,
              roleId: roleId,
              scopeType: scopeType,
              targetLocationId: _nonBlankString(body['location_id']),
              targetOrgUnitId: _nonBlankString(body['org_unit_id']),
            ),
          );
          _writeJson(response, 201, <String, Object?>{
            'invite_id': created.inviteId,
            'expires_at': created.expiresAt.toUtc().toIso8601String(),
            if (created.userId != null) 'user_id': created.userId,
          });
          return;
        }

        if (request.method == 'GET' && path == adminAuthInvitesPath) {
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
            path.startsWith(adminAuthInvitePrefix)) {
          if (!await requirePermission('team.users.invite')) return;
          final inviteId = _pathSuffix(path, adminAuthInvitePrefix);
          if (inviteId == null) {
            _writeJson(response, 404, <String, Object?>{
              'error': 'not found',
              'method': request.method,
              'path': path,
            });
            return;
          }
          final revoked = await authOperationsGateway.revokeInvite(
            TeamInviteRevokeCommand(
              actorUserId: scope.userId,
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              inviteId: inviteId,
            ),
          );
          _writeJson(response, 200, <String, Object?>{
            'ok': true,
            'revoked': revoked.revoked,
          });
          return;
        }

        if (request.method == 'POST' && path.startsWith(adminAuthUsersPrefix)) {
          final action = _userActionFromPath(path);
          if (action == null) {
            _writeJson(response, 404, <String, Object?>{
              'error': 'not found',
              'method': request.method,
              'path': path,
            });
            return;
          }
          final permissionKey = switch (action.action) {
            'suspend' => 'team.users.deactivate',
            'reactivate' => 'team.users.reactivate',
            'soft-delete' => 'team.users.soft_delete',
            'reset-password' => 'team.users.reset_password',
            'reset-mfa' => PermissionKeys.teamUsersResetMfa,
            'cancel-mfa-removal' => PermissionKeys.teamUsersResetMfa,
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
          if (action.action == 'reset-password') {
            await authOperationsGateway.requestPasswordReset(
              TeamPasswordResetCommand(
                actorUserId: scope.userId,
                operatorId: scope.operatorId,
                locationId: scope.locationId,
                targetUserId: action.userId,
              ),
            );
            _writeJson(response, 200, <String, Object?>{'ok': true});
            return;
          }
          if (action.action == 'reset-mfa') {
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
            _writeJson(response, 200, <String, Object?>{
              'ok': true,
              'requested_count': queued.requestedCount,
              'request_ids': queued.requestIds,
              if (queued.executeAfter != null)
                'execute_after': queued.executeAfter!.toUtc().toIso8601String(),
            });
            return;
          }
          if (action.action == 'cancel-mfa-removal') {
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
            final completed = await mfaOperationsGateway.cancelFactorRemoval(
              MfaCancelFactorRemovalCommand(
                actorUserId: scope.userId,
                operatorId: scope.operatorId,
                locationId: scope.locationId,
                targetUserId: action.userId,
                requestId: requestId,
              ),
            );
            _writeJson(response, 200, <String, Object?>{
              'ok': true,
              'cancelled': completed.cancelled,
            });
            return;
          }

          final command = TeamUserStatusCommand(
            actorUserId: scope.userId,
            operatorId: scope.operatorId,
            locationId: scope.locationId,
            targetUserId: action.userId,
            reason: _nonBlankString(body['reason']) ?? action.action,
          );
          final updated = switch (action.action) {
            'suspend' => await authOperationsGateway.suspendUser(command),
            'reactivate' => await authOperationsGateway.reactivateUser(command),
            'soft-delete' => await authOperationsGateway.softDeleteUser(
              command,
            ),
            _ => throw StateError('unreachable action'),
          };
          _writeJson(response, 200, <String, Object?>{
            'ok': true,
            'updated': updated.updated,
          });
          return;
        }

        if (request.method == 'POST' && path == adminAuthRoleGrantsPath) {
          if (!await requirePermission('team.roles.assign')) return;
          final targetUserId = _nonBlankString(body['user_id']);
          final roleId = _nonBlankString(body['role_id']);
          final scopeType = _nonBlankString(body['scope_type']);
          if (targetUserId == null || roleId == null || scopeType == null) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_role_grant_fields',
              'message': 'user_id, role_id, and scope_type are required',
            });
            return;
          }
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
          _writeJson(response, 201, <String, Object?>{
            'user_role_id': created.userRoleId,
          });
          return;
        }

        if (request.method == 'DELETE' &&
            path.startsWith(adminAuthRoleGrantPrefix)) {
          if (!await requirePermission('team.roles.revoke')) return;
          final userRoleId = _pathSuffix(path, adminAuthRoleGrantPrefix);
          final targetUserId = _nonBlankString(body['user_id']);
          if (userRoleId == null || targetUserId == null) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_role_grant_revoke_fields',
              'message': 'role grant id in path and user_id body are required',
            });
            return;
          }
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
          _writeJson(response, 200, <String, Object?>{
            'ok': true,
            'revoked': revoked.revoked,
          });
          return;
        }

        if (request.method == 'GET' && path == adminAuthOrgUnitsPath) {
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

        if (request.method == 'POST' && path == adminAuthOrgUnitsPath) {
          if (!await requirePermission('team.roles.assign')) return;
          final parentOrgUnitId = _nonBlankString(body['parent_org_unit_id']);
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
          final created = await authOperationsGateway.createOrgUnit(
            TeamOrgUnitCreateCommand(
              actorUserId: scope.userId,
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              parentOrgUnitId: parentOrgUnitId,
              unitType: unitType,
              label: label,
              name: name,
            ),
          );
          _writeJson(response, 201, <String, Object?>{
            'org_unit_id': created.orgUnitId,
          });
          return;
        }

        if (request.method == 'PATCH' &&
            path.startsWith(adminAuthLocationsPrefix) &&
            path.endsWith('/org-unit')) {
          if (!await requirePermission('team.roles.assign')) return;
          final targetLocationId = _orgUnitLocationIdFromPath(path);
          final parentOrgUnitId = _nonBlankString(body['parent_org_unit_id']);
          if (targetLocationId == null || parentOrgUnitId == null) {
            _writeJson(response, 400, <String, Object?>{
              'error': 'missing_location_org_unit_fields',
              'message':
                  'location id in path and parent_org_unit_id body are required',
            });
            return;
          }
          final moved = await authOperationsGateway.moveLocationToOrgUnit(
            TeamLocationOrgUnitMoveCommand(
              actorUserId: scope.userId,
              operatorId: scope.operatorId,
              locationId: scope.locationId,
              targetLocationId: targetLocationId,
              parentOrgUnitId: parentOrgUnitId,
            ),
          );
          _writeJson(response, 200, <String, Object?>{
            'ok': true,
            'moved': moved.moved,
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
      } on AuthOperationRejected catch (error) {
        _writeJson(response, error.statusCode, <String, Object?>{
          'error': error.code,
          'message': error.message,
        });
        return;
      } catch (error, stackTrace) {
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

    if (request.method == 'POST' && path == authRefreshTokensRevokeAllPath) {
      if (firebaseAdminAuthClient == null) {
        _writeJson(response, 503, <String, Object?>{
          'error': 'refresh_token_revoke_not_configured',
          'message': 'route requires a FirebaseAdminAuthClient to be installed',
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
      } catch (_) {
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
          'message': 'route requires an AuthOperationsGateway to be installed',
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
      } catch (_) {
        _writeJson(response, 503, <String, Object?>{
          'error': 'auth_sessions_unavailable',
          'message': 'active sessions are unavailable; please retry',
        });
      }
      return;
    }

    if (request.method == 'GET' && path == authAuditLogPath) {
      if (authOperationsGateway == null) {
        _writeJson(response, 503, <String, Object?>{
          'error': 'auth_operations_not_configured',
          'message': 'route requires an AuthOperationsGateway to be installed',
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
          : (rawLimit < 1
                ? 1
                : (rawLimit > 100 ? 100 : rawLimit));
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
      } catch (_) {
        _writeJson(response, 503, <String, Object?>{
          'error': 'auth_audit_log_unavailable',
          'message': 'audit log is unavailable; please retry',
        });
      }
      return;
    }

    if (request.method == 'POST' && path == authSessionLoginPath) {
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

      final tokenHash = _nonBlankString(body['token_hash']);
      if (tokenHash == null) {
        _writeJson(response, 400, <String, Object?>{
          'error': 'missing_token_hash',
          'message': 'request body must include a non-empty token_hash field',
        });
        return;
      }

      final ledgerContext = _resolveLedgerContextFromHeaders(
        request,
        trustProxyAuditHeaders: trustProxyAuditHeaders,
      );

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
      } catch (_) {
        // Fail closed with a calm message — no error stack leaks past
        // this boundary. The client surfaces this to the user as a
        // "try again in a moment" banner via
        // `AuthLoginFailure(code: 'ledger_unavailable')`.
        _writeJson(response, 503, <String, Object?>{
          'error': 'auth_session_ledger_unavailable',
          'message': 'auth session ledger is unavailable; please retry',
        });
        return;
      }

      _writeJson(response, 200, <String, Object?>{
        'session_id': sessionId,
        // Echo the resolved scope so the client can sanity-check it
        // matches the local AuthSession before persisting the envelope.
        'user_id': scope.userId,
        'operator_id': scope.operatorId,
        'location_id': scope.locationId,
      });
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
          'message': 'request body must include a non-empty session_id field',
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
      } catch (_) {
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
          'message': 'request body must include a non-empty session_id field',
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
      } catch (_) {
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
      } catch (_) {
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
          message:
              'Sign in again before rotating provider keys.',
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
        resolvedActorUserId =
            await integrationAdminActorResolver.resolveActorUserId(
          firebaseUid: firebaseUidLookup,
          adminReason: 'admin.integrations.${request.method}:'
              '$firebaseUidLookup:resolve_actor',
        );
      } catch (_) {
        _writeJson(response, 503, <String, Object?>{
          'error': 'integration_admin_actor_resolve_failed',
          'message':
              'actor resolution is unavailable; please retry',
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

      try {
        await _routeIntegrationsAdmin(
          request: request,
          response: response,
          path: path,
          gateway: integrationAdminGateway,
          actorUserId: resolvedActorUserId,
          actorLogId: firebaseUidLookup,
          body: body,
        );
      } catch (error) {
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

      try {
        await _routePricingAdmin(
          request: request,
          response: response,
          path: path,
          gateway: pricingTierAdminGateway,
          actorUserId: actor.userId,
          body: body,
        );
      } catch (error) {
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
        _writeJson(response, 503, <String, Object?>{
          'error': 'pricing_tier_admin_unavailable',
          'message':
              'pricing tier admin operation is unavailable; please retry',
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
        idempotencyKey =
            request.headers.value('Idempotency-Key')?.trim();
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
      } catch (error) {
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
        _writeJson(response, 503, <String, Object?>{
          'error': 'corpus_admin_unavailable',
          'message':
              'corpus admin operation is unavailable; please retry',
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
              'route requires a GraphCandidatesProxyGateway to be installed',
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
        idempotencyKey =
            request.headers.value('Idempotency-Key')?.trim();
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
              'graph candidates operation is unavailable; please retry',
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

      final idempotencyKey =
          request.headers.value('Idempotency-Key')?.trim();
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
        idempotencyKey =
            request.headers.value('Idempotency-Key')?.trim();
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
          resolvedActorUserId =
              await integrationAdminActorResolver.resolveActorUserId(
            firebaseUid: firebaseUidLookup,
            adminReason: 'admin.feature_flags.${request.method}:'
                '$firebaseUidLookup:resolve_actor',
          );
        } catch (_) {
          _writeJson(response, 503, <String, Object?>{
            'error': 'feature_flags_actor_resolve_failed',
            'message':
                'actor resolution is unavailable; please retry',
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
        );
      } catch (error) {
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
        _writeJson(response, 503, <String, Object?>{
          'error': 'feature_flags_admin_unavailable',
          'message':
              'feature flags admin operation is unavailable; please retry',
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

      try {
        await _routeOperatorLocationAdmin(
          request: request,
          response: response,
          path: path,
          gateway: operatorLocationAdminGateway,
          actorUserId: actor.userId,
          body: body,
        );
      } catch (error) {
        if (error is _AdminInputError) {
          _writeJson(response, error.statusCode, <String, Object?>{
            'error': error.code,
            'message': error.message,
          });
          return;
        }
        _writeJson(response, 503, <String, Object?>{
          'error': 'operator_location_admin_unavailable',
          'message':
              'operator/location admin operation is unavailable; please retry',
        });
      }
      return;
    }

    _writeJson(response, 404, <String, Object?>{
      'error': 'not found',
      'method': request.method,
      'path': path,
    });
  } finally {
    await response.close();
  }
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
      adminReason: '$reasonPrefix:onboard',
    );
    _writeJson(response, 201, bundle);
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
    final patched = await gateway.patchOperator(
      actorUserId: actorUserId,
      operatorId: operatorId,
      businessName: _optionalBodyString(body, 'business_name'),
      ownerEmail: _optionalBodyString(body, 'owner_email'),
      subscriptionTier: _optionalBodyString(body, 'subscription_tier'),
      preferredCurrency: preferredCurrency,
      primaryLocationId: _optionalBodyString(body, 'primary_location_id'),
      adminReason: '$reasonPrefix:patch:$operatorId',
    );
    if (patched == null) {
      _writeJson(response, 404, <String, Object?>{
        'error': 'unknown_operator',
        'message': 'operator not found',
      });
      return;
    }
    _writeJson(response, 200, <String, Object?>{'operator': patched});
    return;
  }

  if (method == 'POST' && path.startsWith(adminOperatorsPrefix)) {
    final action = _operatorActionFromPath(path);
    if (action == null) {
      _writeNotFound(response, request);
      return;
    }
    Map<String, Object?>? updated;
    if (action.action == 'suspend') {
      updated = await gateway.suspendOperator(
        actorUserId: actorUserId,
        operatorId: action.operatorId,
        adminReason: '$reasonPrefix:suspend:${action.operatorId}',
      );
    } else if (action.action == 'reactivate') {
      updated = await gateway.reactivateOperator(
        actorUserId: actorUserId,
        operatorId: action.operatorId,
        adminReason: '$reasonPrefix:reactivate:${action.operatorId}',
      );
    } else {
      _writeNotFound(response, request);
      return;
    }
    if (updated == null) {
      _writeJson(response, 404, <String, Object?>{
        'error': 'unknown_operator',
        'message': 'operator not found',
      });
      return;
    }
    _writeJson(response, 200, <String, Object?>{'operator': updated});
    return;
  }

  if (method == 'POST' && path == adminLocationsPath) {
    final operatorId = _requireBodyString(body, 'operator_id');
    final name = _requireBodyString(body, 'name');
    final timezone = _requireBodyTimezone(body, 'timezone');
    final rolloverHour = _requireBodyRolloverHour(
      body,
      'business_day_rollover_hour',
    );
    final address = _optionalBodyString(body, 'address') ?? '';
    final created = await gateway.addLocation(
      actorUserId: actorUserId,
      operatorId: operatorId,
      name: name,
      address: address,
      timezone: timezone,
      businessDayRolloverHour: rolloverHour,
      adminReason: '$reasonPrefix:add_location:$operatorId',
    );
    _writeJson(response, 201, <String, Object?>{'location': created});
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
    int? rolloverHour;
    if (body.containsKey('business_day_rollover_hour')) {
      rolloverHour = _requireBodyRolloverHour(
        body,
        'business_day_rollover_hour',
      );
    }
    final patched = await gateway.patchLocation(
      actorUserId: actorUserId,
      locationId: locationId,
      name: _optionalBodyString(body, 'name'),
      address: _optionalBodyString(body, 'address'),
      timezone: timezone,
      businessDayRolloverHour: rolloverHour,
      adminReason: '$reasonPrefix:patch_location:$locationId',
    );
    if (patched == null) {
      _writeJson(response, 404, <String, Object?>{
        'error': 'unknown_location',
        'message': 'location not found',
      });
      return;
    }
    _writeJson(response, 200, <String, Object?>{'location': patched});
    return;
  }

  if (method == 'DELETE' && path.startsWith(adminLocationsPrefix)) {
    final locationId = _pathSuffix(path, adminLocationsPrefix);
    if (locationId == null) {
      _writeNotFound(response, request);
      return;
    }
    final operatorId = _requireBodyString(body, 'operator_id');
    final result = await gateway.removeLocation(
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      adminReason: '$reasonPrefix:remove_location:$locationId',
    );
    switch (result) {
      case AdminLocationRemovalResult.removed:
        _writeJson(response, 200, <String, Object?>{
          'ok': true,
          'removed': true,
        });
        return;
      case AdminLocationRemovalResult.notFound:
        _writeJson(response, 404, <String, Object?>{
          'error': 'unknown_location',
          'message': 'location not found',
        });
        return;
      case AdminLocationRemovalResult.primaryLocationProtected:
        _writeJson(response, 400, <String, Object?>{
          'error': 'cannot_remove_primary_location',
          'message':
              "reassign the operator's primary_location_id before removing this location",
        });
        return;
    }
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
  return false;
}

bool _isAdminIntegrationsPath(String path) {
  return path == adminIntegrationsListPath ||
      path == adminIntegrationsRotateAnthropicPath ||
      path == adminIntegrationsRotateVoyagePath ||
      path == adminIntegrationsRotateAzureDbPath ||
      path == adminIntegrationsRotateGeminiPath ||
      path == adminIntegrationsStatusPath;
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
          path == adminIntegrationsRotateGeminiPath)) {
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
}) async {
  final method = request.method;
  // [actorLogId] is the original verified Firebase UID (the value the
  // resolver looked up). It is embedded in the admin reason string
  // alongside the resolved Postgres user UUID so the audit trail
  // captures both identifiers without relying on a join.
  final reasonPrefix = 'admin.integrations.$method:$actorLogId';

  if (method == 'GET' && path == adminIntegrationsListPath) {
    final bundle = await gateway.listBundle(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:list',
    );
    _writeJson(response, 200, bundle);
    return;
  }

  if (method == 'GET' && path == adminIntegrationsStatusPath) {
    final bundle = await gateway.listBundle(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:status',
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
    final result = await gateway.rotateProviderKey(
      actorUserId: actorUserId,
      keyKind: keyKind,
      plaintextValue: plaintext,
      adminReason: '$reasonPrefix:rotate:$keyKind',
    );
    _writeJson(response, 200, result);
    return;
  }

  _writeNotFound(response, request);
}

String? _integrationKeyKindForRoute(String path) {
  if (path == adminIntegrationsRotateAnthropicPath) return 'anthropic';
  if (path == adminIntegrationsRotateVoyagePath) return 'voyage';
  if (path == adminIntegrationsRotateAzureDbPath) return 'azure_db';
  if (path == adminIntegrationsRotateGeminiPath) return 'gemini';
  return null;
}

bool _isAdminPricingOperation(String path, String method) {
  if (method == 'GET' && path == adminPricingOperatorsPath) return true;
  if (method == 'PATCH' && path.startsWith(adminPricingOperatorsPrefix)) {
    return true;
  }
  if (method == 'POST' && path.startsWith(adminPricingOperatorsPrefix)) {
    // /apply-template suffix
    return true;
  }
  if (method == 'PUT' && path == adminPricingUsageCapsPath) return true;
  return false;
}

Future<void> _routePricingAdmin({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required PricingTierAdminProxyGateway gateway,
  required String actorUserId,
  required Map<String, Object?> body,
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
    final updated = await gateway.updateOperatorTier(
      actorUserId: actorUserId,
      operatorId: operatorId,
      subscriptionTier: subscriptionTier,
      adminReason: '$reasonPrefix:tier:$operatorId',
    );
    if (updated == null) {
      _writeJson(response, 404, <String, Object?>{
        'error': 'unknown_operator',
        'message': 'operator not found',
      });
      return;
    }
    _writeJson(response, 200, updated);
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
    final result = await gateway.applyTierTemplate(
      actorUserId: actorUserId,
      operatorId: operatorId,
      tierKey: tierKey,
      adminReason: '$reasonPrefix:apply_template:$operatorId:$tierKey',
    );
    if (result == null) {
      _writeJson(response, 404, <String, Object?>{
        'error': 'unknown_operator',
        'message': 'operator not found',
      });
      return;
    }
    _writeJson(response, 200, result);
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
    _writeJson(response, 200, <String, Object?>{'cap': cap});
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

Future<void> _routeCorpusAdmin({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required CorpusAdminProxyGateway gateway,
  required String actorUserId,
  required String idempotencyKey,
  required Map<String, Object?> body,
}) async {
  final method = request.method;
  final reasonPrefix = 'admin.corpus.$method:$actorUserId';

  if (method == 'GET' && path == adminCorpusVersionsPath) {
    final versions = await gateway.listVersions(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:list',
    );
    _writeJson(response, 200, <String, Object?>{'versions': versions});
    return;
  }

  if (method == 'GET' && path.startsWith(adminCorpusVersionsPrefix)) {
    final tail = _pathSuffix(path, adminCorpusVersionsPrefix);
    if (tail == null || tail.contains('/')) {
      _writeNotFound(response, request);
      return;
    }
    final bundle = await gateway.fetchVersion(
      actorUserId: actorUserId,
      versionId: tail,
      adminReason: '$reasonPrefix:fetch:$tail',
    );
    if (bundle == null) {
      _writeJson(response, 404, <String, Object?>{
        'error': 'unknown_version',
        'message': 'corpus version not found',
      });
      return;
    }
    _writeJson(response, 200, bundle);
    return;
  }

  if (method == 'POST' &&
      (path == adminCorpusPreviewDiffPath || path == adminCorpusUploadPath)) {
    final fileName = _requireBodyString(body, 'file_name');
    final contentType = _requireBodyString(body, 'content_type');
    final base64 = _requireBodyString(body, 'content_base64');
    List<int> bytes;
    try {
      bytes = const Base64Decoder().convert(base64);
    } catch (_) {
      throw const _AdminInputError(
        statusCode: 400,
        code: 'invalid_content_base64',
        message: 'content_base64 is not a valid base64 payload',
      );
    }
    final result = await gateway.previewDiff(
      actorUserId: actorUserId,
      fileName: fileName,
      contentType: contentType,
      bytes: bytes,
      idempotencyKey: idempotencyKey,
      adminReason: '$reasonPrefix:preview_diff:$fileName',
    );
    _writeJson(response, 200, result);
    return;
  }

  if (method == 'POST' && path == adminCorpusCommitPath) {
    final previewToken = _requireBodyString(body, 'preview_token');
    final summary = _optionalBodyString(body, 'summary') ?? '';
    final result = await gateway.commitVersion(
      actorUserId: actorUserId,
      previewToken: previewToken,
      summary: summary,
      idempotencyKey: idempotencyKey,
      adminReason: '$reasonPrefix:commit:$previewToken',
    );
    _writeJson(response, 200, <String, Object?>{'version': result});
    return;
  }

  if (method == 'POST' && path == adminCorpusRollbackPath) {
    final targetVersionId = _requireBodyString(body, 'target_version_id');
    final summary = _optionalBodyString(body, 'summary') ?? '';
    final result = await gateway.rollbackVersion(
      actorUserId: actorUserId,
      targetVersionId: targetVersionId,
      summary: summary,
      idempotencyKey: idempotencyKey,
      adminReason: '$reasonPrefix:rollback:$targetVersionId',
    );
    if (result == null) {
      _writeJson(response, 404, <String, Object?>{
        'error': 'unknown_version',
        'message': 'rollback target version not found',
      });
      return;
    }
    _writeJson(response, 200, <String, Object?>{'version': result});
    return;
  }

  _writeNotFound(response, request);
}

bool _isAdminFeatureFlagsPath(String path) {
  return path == adminFeatureFlagsListPath ||
      path == adminFeatureFlagsTogglePath;
}

bool _isAdminFeatureFlagsOperation(String path, String method) {
  if (method == 'GET' && path == adminFeatureFlagsListPath) return true;
  if (method == 'POST' && path == adminFeatureFlagsTogglePath) return true;
  return false;
}

Future<void> _routeFeatureFlagsAdmin({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required FeatureFlagsAdminProxyGateway gateway,
  required String actorUserId,
  required String idempotencyKey,
  required Map<String, Object?> body,
}) async {
  final method = request.method;
  final reasonPrefix = 'admin.feature_flags.$method:$actorUserId';

  if (method == 'GET' && path == adminFeatureFlagsListPath) {
    final flags = await gateway.listFlags(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:list',
    );
    _writeJson(response, 200, <String, Object?>{'flags': flags});
    return;
  }

  if (method == 'POST' && path == adminFeatureFlagsTogglePath) {
    final flagId = _requireBodyString(body, 'flag_id');
    final enabledRaw = body['enabled'];
    if (enabledRaw is! bool) {
      throw const _AdminInputError(
        statusCode: 400,
        code: 'missing_enabled',
        message: 'enabled boolean is required',
      );
    }
    final result = await gateway.toggleFlag(
      actorUserId: actorUserId,
      flagId: flagId,
      enabled: enabledRaw,
      idempotencyKey: idempotencyKey,
      adminReason: '$reasonPrefix:toggle:$flagId:$enabledRaw',
    );
    if (result == null) {
      _writeJson(response, 404, <String, Object?>{
        'error': 'unknown_flag',
        'message': 'feature flag not found',
      });
      return;
    }
    _writeJson(response, 200, <String, Object?>{'flag': result});
    return;
  }

  _writeNotFound(response, request);
}

/// Phase 11A.3b — Graphify candidate review route handler. Same shape
/// as [_routeCorpusAdmin]: GET → list, POST → commit-batch. The
/// commit-batch arm reads the operator/location target from the
/// request body (super_admin actors are cross-tenant, so the operator
/// the candidates land in is an explicit per-request choice) and
/// applies the corpus-manifest scope filter as defense-in-depth
/// before handing the decisions off to the
/// [GraphCandidatesProxyGateway] for repository persistence.
Future<void> _routeGraphCandidates({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required GraphCandidatesProxyGateway gateway,
  required String actorUserId,
  required String idempotencyKey,
  required Map<String, Object?> body,
}) async {
  final method = request.method;
  final reasonPrefix = 'admin.corpus.graph_candidates.$method:$actorUserId';

  if (method == 'GET' && path == adminCorpusGraphCandidatesPath) {
    final diff = await gateway.listGraphCandidates(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:list',
    );
    _writeJson(response, 200, diff);
    return;
  }

  if (method == 'POST' && path == adminCorpusGraphCandidatesCommitPath) {
    final rawDecisions = body['decisions'];
    if (rawDecisions is! List) {
      throw const _AdminInputError(
        statusCode: 400,
        code: 'missing_decisions',
        message: 'decisions array is required',
      );
    }
    // F&F super_admin actors are cross-tenant — they don't carry an
    // operator_id in their JWT. The body must name the operator the
    // candidates land in so the gateway can build the [TenantContext]
    // for the [GraphRepository.commitBatch] call.
    final operatorId = _requireBodyString(body, 'target_operator_id');
    final locationId = _requireBodyString(body, 'target_location_id');
    final castDecisions = <Map<String, Object?>>[];
    for (var i = 0; i < rawDecisions.length; i++) {
      final entry = rawDecisions[i];
      if (entry is! Map) {
        throw _AdminInputError(
          statusCode: 400,
          code: 'invalid_decision_entry',
          message: 'decisions[$i] must be a JSON object',
        );
      }
      castDecisions.add(entry.cast<String, Object?>());
    }
    // Manifest scope filter (defense in depth). The importer already
    // dropped out-of-scope candidates when it wrote the JSONL, but the
    // wire body could carry a hand-crafted decision whose payload
    // points at a markdown source the manifest does not cover. Reject
    // before the gateway gets near the canonical-graph tables.
    await _enforceGraphCandidateSourceScope(castDecisions);
    final result = await gateway.commitBatch(
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      decisions: castDecisions,
      idempotencyKey: idempotencyKey,
      adminReason: '$reasonPrefix:commit_batch',
    );
    _writeJson(response, 200, result);
    return;
  }

  _writeNotFound(response, request);
}

/// Lazy cache of in-scope source-file identifiers (both `source_path`
/// and bare `file_name`) loaded from the corpus manifest. Populated on
/// first commit-batch call so the manifest YAML parse cost is paid
/// once per process instead of per request. Reset via
/// [resetGraphCandidatesManifestCache] from tests that need to swap
/// the manifest mid-process.
Set<String>? _graphCandidatesManifestCache;

/// Resets the lazy [CorpusManifest] cache used by the graph-candidate
/// commit-batch handler. Tests that swap the manifest YAML mid-process
/// (e.g. by writing a fixture file under a temp dir) call this between
/// scenarios so the next request re-reads the fresh manifest.
void resetGraphCandidatesManifestCache() {
  _graphCandidatesManifestCache = null;
}

/// Defense-in-depth manifest filter for graph-candidate commit
/// batches. The wire `ApprovalDecision` only carries an opaque
/// `candidate_id` (the server resolves the canonical payload from
/// the JSONL artifacts), so for `approve` / `reject` decisions there
/// is nothing for the route handler to filter — the importer already
/// dropped out-of-scope candidates when it wrote the JSONL.
///
/// The filter still has work to do on `edit` decisions: the admin
/// can swap in an `edited_payload` that names a `source_file` the
/// manifest does not cover, which would smuggle out-of-scope content
/// into canonical storage. Reject those with a typed
/// `source_out_of_scope` 403 before the gateway gets near
/// `graph_nodes` / `graph_edges`. Decisions without an
/// `edited_payload.source_file` are passed through.
Future<void> _enforceGraphCandidateSourceScope(
  List<Map<String, Object?>> decisions,
) async {
  Set<String>? scope;
  for (var i = 0; i < decisions.length; i++) {
    final decision = decisions[i];
    // Inspect both `edited_payload.source_file` (the edit-swap case)
    // and a top-level `payload.source_file` (defensive: if a future
    // wire shape inlines the candidate payload onto the decision,
    // we want the same filter to catch it).
    final candidateSources = <String>[];
    final editedPayload = decision['edited_payload'];
    if (editedPayload is Map) {
      final raw = editedPayload['source_file'];
      if (raw is String) candidateSources.add(raw);
    }
    final inlinedPayload = decision['payload'];
    if (inlinedPayload is Map) {
      final raw = inlinedPayload['source_file'];
      if (raw is String) candidateSources.add(raw);
    }
    for (final rawSource in candidateSources) {
      final trimmed = rawSource.trim();
      if (trimmed.isEmpty) continue;
      scope ??= _graphCandidatesManifestCache ??
          await _loadGraphCandidatesManifestScope();
      final normalized = trimmed.replaceAll(r'\', '/');
      if (scope.contains(normalized)) continue;
      final base = p.basename(normalized);
      if (scope.contains(base)) continue;
      throw _AdminInputError(
        statusCode: 403,
        code: 'source_out_of_scope',
        message:
            'decision $i references source_file "$rawSource" which is '
            'not in the corpus manifest',
      );
    }
  }
}

Future<Set<String>> _loadGraphCandidatesManifestScope() async {
  final manifestFile = File(defaultManifestPath);
  if (!manifestFile.existsSync()) {
    // No manifest on disk — fall through with an empty scope. The
    // route handler will reject EVERY decision that names a
    // source_file, which is the safe default for a misconfigured
    // deployment.
    final empty = <String>{};
    _graphCandidatesManifestCache = empty;
    return empty;
  }
  final manifest = await CorpusManifest.load(manifestFile);
  final scope = <String>{};
  for (final document in manifest.documents) {
    if (!document.isIncluded) continue;
    scope.add(document.sourcePath.replaceAll(r'\', '/'));
    scope.add(document.fileName);
  }
  _graphCandidatesManifestCache = scope;
  return scope;
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
  if (method == 'GET' && path == adminAuthRolesPath) return true;
  if (method == 'POST' && path == adminAuthRolesPath) return true;
  if (method == 'PATCH' && path.startsWith(adminAuthRolePrefix)) return true;
  if (method == 'DELETE' && path.startsWith(adminAuthRolePrefix)) return true;
  if (method == 'GET' && path == adminAuthUsersPath) return true;
  if (method == 'GET' && path == adminAuthInvitesPath) return true;
  if (method == 'POST' && path == adminAuthInvitesPath) return true;
  if (method == 'DELETE' && path.startsWith(adminAuthInvitePrefix)) {
    return true;
  }
  if (method == 'POST' && path.startsWith(adminAuthUsersPrefix)) return true;
  if (method == 'POST' && path == adminAuthRoleGrantsPath) return true;
  if (method == 'DELETE' && path.startsWith(adminAuthRoleGrantPrefix)) {
    return true;
  }
  if (method == 'GET' && path == adminAuthOrgUnitsPath) return true;
  if (method == 'POST' && path == adminAuthOrgUnitsPath) return true;
  if (method == 'PATCH' &&
      path.startsWith(adminAuthLocationsPrefix) &&
      path.endsWith('/org-unit')) {
    return true;
  }
  return false;
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
      _writeJson(response, 403, <String, Object?>{
        'error': 'mfa_freshness_required',
        'message': 'fresh authentication is required',
        'refresh_after': refreshAfter.toUtc().toIso8601String(),
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

Map<String, Object?> _teamRoleToJson(TeamRoleCatalogEntry role) {
  return <String, Object?>{
    'role_id': role.roleId,
    'role_key': role.roleKey,
    'display_name': role.displayName,
    'description': role.description,
    'is_seeded': role.isSeeded,
    'is_editable': role.isEditable,
    'operator_id': role.operatorId,
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
  };
}

Map<String, Object?> _teamOrgLocationToJson(TeamOrgLocationEntry entry) {
  return <String, Object?>{
    'location_id': entry.locationId,
    'parent_org_unit_id': entry.parentOrgUnitId,
    'org_unit_path': entry.orgUnitPath,
    'label': entry.label,
  };
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

class _MalformedJsonBodyError implements Exception {
  _MalformedJsonBodyError(this.message);

  final String message;
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
  stderr.writeln(
    'advisor proxy unhandled $surface error: '
    'method=$method path=$path type=${error.runtimeType} '
    'error=$clipped stack=$firstFrame',
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

void _setAdminOperatorLocationCorsHeaders(HttpResponse response) {
  response.headers.set('Access-Control-Allow-Origin', '*');
  response.headers.set(
    'Access-Control-Allow-Methods',
    'GET,POST,PATCH,DELETE,OPTIONS',
  );
  response.headers.set(
    'Access-Control-Allow-Headers',
    'Authorization,Content-Type,Accept',
  );
  response.headers.set('Access-Control-Max-Age', '3600');
}

// Phase 11A.4 — Integration management CORS. Mirrors the pricing
// helper shape; rotation routes are POST-only so the allowed-methods
// list excludes PUT.
void _setAdminIntegrationsCorsHeaders(HttpResponse response) {
  response.headers.set('Access-Control-Allow-Origin', '*');
  response.headers.set(
    'Access-Control-Allow-Methods',
    'GET,POST,OPTIONS',
  );
  response.headers.set(
    'Access-Control-Allow-Headers',
    'Authorization,Content-Type,Accept',
  );
  response.headers.set('Access-Control-Max-Age', '3600');
}

// Phase 11A.2 — pricing routes use PUT for `/v1/admin/pricing/usage-caps`
// upserts. Browser preflight refuses any method missing from
// Access-Control-Allow-Methods, so the pricing surface gets its own
// header set with PUT included; the 11A.1 operator/location helper
// stays unchanged.
void _setAdminPricingCorsHeaders(HttpResponse response) {
  response.headers.set('Access-Control-Allow-Origin', '*');
  response.headers.set(
    'Access-Control-Allow-Methods',
    'GET,POST,PUT,PATCH,DELETE,OPTIONS',
  );
  response.headers.set(
    'Access-Control-Allow-Headers',
    'Authorization,Content-Type,Accept',
  );
  response.headers.set('Access-Control-Max-Age', '3600');
}

// Phase 11A.3a — corpus admin routes accept POST + GET only. The
// commit / rollback / preview-diff routes also need the
// `Idempotency-Key` request header in CORS preflight, otherwise the
// browser strips it before the proxy ever sees it.
void _setAdminCorpusCorsHeaders(HttpResponse response) {
  response.headers.set('Access-Control-Allow-Origin', '*');
  response.headers.set(
    'Access-Control-Allow-Methods',
    'GET,POST,OPTIONS',
  );
  response.headers.set(
    'Access-Control-Allow-Headers',
    'Authorization,Content-Type,Accept,Idempotency-Key',
  );
  response.headers.set('Access-Control-Max-Age', '3600');
}

// Phase 11A.7 — feature flags admin routes accept GET (list) + POST
// (toggle). The toggle POST carries `Idempotency-Key` so the browser
// preflight needs that header in the allow-list mirror of the corpus
// helper.
void _setAdminFeatureFlagsCorsHeaders(HttpResponse response) {
  response.headers.set('Access-Control-Allow-Origin', '*');
  response.headers.set(
    'Access-Control-Allow-Methods',
    'GET,POST,OPTIONS',
  );
  response.headers.set(
    'Access-Control-Allow-Headers',
    'Authorization,Content-Type,Accept,Idempotency-Key',
  );
  response.headers.set('Access-Control-Max-Age', '3600');
}

String _nonBlankOr(String? raw, String fallback) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return fallback;
  return value;
}
