// Forge & Flow advisor proxy — pure scaffold.
//
// 11a.10a. The proxy is the trusted backend boundary where production
// Anthropic / Voyage / Supabase keys live and where operator/location
// scope is resolved from the caller's JWT before any retrieval or
// provider call is made. Flutter clients never hold production keys —
// they call this proxy with a user token, and the proxy fans out to
// providers / Postgres on their behalf.
//
// This file is pure logic only:
//   - secret-name registry + config loader (values never logged)
//   - JWT verifier interface + operator context value class
//   - request guard that returns a scoped operator context
//   - testable HTTP route handler
//
// 11a.10a does NOT:
//   - call Anthropic, Voyage, Supabase, Firebase, or any live service
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

  /// Supabase project URL the proxy reads/writes against.
  static const String supabaseUrl = 'SUPABASE_URL';

  /// Supabase service-role key used by the proxy to bypass RLS for
  /// admin-scoped writes. Per-operator reads still go through RLS.
  static const String supabaseServiceRoleKey = 'SUPABASE_SERVICE_ROLE_KEY';

  /// Required server-side secret names. The proxy refuses to start
  /// when any of these are missing or blank.
  static const List<String> required = <String>[
    anthropicApiKey,
    voyageApiKey,
    supabaseUrl,
    supabaseServiceRoleKey,
  ];
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
  ProxyConfig._({required this.port, required Map<String, String> secrets})
    : _secrets = Map<String, String>.unmodifiable(secrets);

  /// HTTP listen port. Cloud Run injects `PORT`; defaults to 8080.
  final int port;

  /// Loaded secret values keyed by [ProxySecretNames] entries. Stored
  /// privately so external code can only retrieve a value via the
  /// explicit [secretFor] accessor — no `toString`, no JSON, no
  /// iteration over values.
  final Map<String, String> _secrets;

  /// Loads config from a server environment map. Returns when every
  /// name in [ProxySecretNames.required] resolves to a non-blank value.
  /// Throws [ProxyConfigError] otherwise — the exception carries the
  /// missing names but never any captured values.
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
    final port = _parsePort(environment['PORT']);
    return ProxyConfig._(port: port, secrets: loaded);
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
  /// loaded secrets. Never includes any secret value.
  @override
  String toString() =>
      'ProxyConfig(port: $port, '
      'loaded_secret_names: ${loadedSecretNames.join(', ')})';
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
  });

  final String userId;
  final String operatorId;
  final String locationId;
  final List<String> roles;

  bool hasRole(String role) => roles.contains(role);
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
    final token = extractBearerToken(authorizationHeader);
    if (token == null) {
      throw ProxyAuthError(
        'missing or malformed Authorization bearer token',
        statusCode: 401,
      );
    }

    ProxyJwtClaims claims;
    try {
      claims = await _verifier.verify(token);
    } on ProxyJwtVerificationError catch (error) {
      throw ProxyAuthError(
        'token verification failed: ${error.message}',
        statusCode: 401,
      );
    }

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
    );
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
        details: <String, Object?>{
          'tier_id': tier.id,
          'reason': error.message,
        },
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
}

// ─── HTTP scaffold ───────────────────────────────────────────────────────────
//
// The router lives here (not in main.dart) so tests can drive it
// directly by binding an HttpServer to a random port and calling the
// same handler the production entrypoint installs.

const String healthPath = '/healthz';
const String scopeSmokePath = '/v1/scope';
const String usageSmokePath = '/v1/usage-smoke';

/// Minimal request router. Routes:
///
///   - GET /healthz         -> 200 (unauthenticated)
///   - GET /v1/scope        -> 200 with operator/location scope (auth-gated)
///   - GET /v1/usage-smoke  -> auth + scope + usage guard, returns tier
///                             policy + remaining budget metadata
///
/// Anything else -> 404. No live external calls — the smoke routes
/// only echo back resolved scope and budget metadata.
Future<void> routeRequest(
  HttpRequest request,
  ProxyRequestGuard authGuard, {
  ProxyUsageGuard? usageGuard,
}) async {
  final response = request.response;
  try {
    final path = request.uri.path;

    if (request.method == 'GET' && path == healthPath) {
      _writeJson(response, 200, <String, Object?>{'status': 'ok'});
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

      _writeJson(response, 200, <String, Object?>{
        'user_id': scope.userId,
        'operator_id': scope.operatorId,
        'location_id': scope.locationId,
        'policy_tier': decision.tier.id,
        'request_timeout_seconds': decision.tier.requestTimeoutSeconds,
        'max_output_tokens': decision.tier.maxOutputTokens,
        'cap_request_tokens': decision.tier.maxRequestTokens,
        'cap_requests_per_minute': decision.tier.maxRequestsPerMinute,
        'cap_monthly_cost_cents': decision.tier.maxMonthlyCostCents,
        'remaining_requests_this_minute':
            decision.remainingRequestsThisMinute,
        'remaining_cost_cents_this_month':
            decision.remainingCostCentsThisMonth,
        'estimate_request_tokens': estimate.requestTokens,
        'note':
            '11a.10b smoke. No provider call performed. Counter store '
            'increment runs in a later slice once a real backend is wired.',
      });
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

void _writeJson(
  HttpResponse response,
  int statusCode,
  Map<String, Object?> body,
) {
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
}
