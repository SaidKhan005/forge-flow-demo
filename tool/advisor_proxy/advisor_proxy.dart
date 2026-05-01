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
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
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
import 'package:pointycastle/pointycastle.dart' as pc;

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
    return ProxyConfig._(
      port: port,
      secrets: loaded,
      firebaseProjectId: firebaseProjectId,
      firebaseEmailActionContinueUrl: firebaseEmailActionContinueUrl,
    );
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
  }) : _wrapper = wrapper,
       _issuer = issuer;

  final TenantTransactionWrapper _wrapper;
  final ServicePrincipalJwtIssuer _issuer;
  final Duration ttl;
  final int rateLimitPerHour;

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
        'payload': jsonEncode(<String, Object?>{
          'issued_by_user_id': command.operator.userId,
          'service_principal_id': principal.id,
          'scopes': principal.scopes,
          'issued_at': issuedAt.toIso8601String(),
          'expires_at': expiresAt.toIso8601String(),
        }),
      },
    );
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
  Future<ProxyAccountingStartResult> startRequest({
    required String idempotencyKey,
    required String requestType,
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

      await exec.query(ProxyUsageLogSql.atomicUpsert, parameters: params);
      return ProxyAccountingReserved(capStatus: capStatus);
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
  });

  final bool postgresOk;
  final bool ageOk;
  final bool pgvectorOk;
  final Map<String, ProxyHealthMetric> metrics;
  final Map<String, ProxyHealthSurface> surfaces;

  bool get ok => postgresOk && ageOk && pgvectorOk;

  Map<String, Object?> toJson({required DateTime checkedAt}) {
    final metricEnvelope = <String, ProxyHealthMetric>{
      ..._reservedProxyHealthMetrics,
      ...metrics,
    };
    final surfaceEnvelope = <String, ProxyHealthSurface>{
      ..._reservedProxyHealthSurfaces,
      ...surfaces,
    };
    final hasMetricProblem =
        _hasYellowOrRedMetric(metricEnvelope) ||
        _hasYellowOrRedSurface(surfaceEnvelope);
    final status = !ok
        ? 'unavailable'
        : hasMetricProblem
        ? 'degraded'
        : 'ok';
    final severity = _overallSeverity(
      dependenciesOk: ok,
      metrics: metricEnvelope,
      surfaces: surfaceEnvelope,
    );

    return <String, Object?>{
      'status': status,
      'severity': severity,
      'contract': 'proxy_health.v1',
      'schema_version': 1,
      'checked_at': checkedAt.toUtc().toIso8601String(),
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

String _overallSeverity({
  required bool dependenciesOk,
  required Map<String, ProxyHealthMetric> metrics,
  required Map<String, ProxyHealthSurface> surfaces,
}) {
  if (!dependenciesOk ||
      metrics.values.any((metric) => metric.status == 'red') ||
      surfaces.values.any((surface) => surface.status == 'red')) {
    return 'red';
  }
  if (metrics.values.any((metric) => metric.status == 'yellow') ||
      surfaces.values.any((surface) => surface.status == 'yellow')) {
    return 'yellow';
  }
  return 'green';
}

const Map<String, ProxyHealthMetric>
_reservedProxyHealthMetrics = <String, ProxyHealthMetric>{
  'audit_chain_lag_seconds': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'seconds',
    description:
        'Lag between current audit chain head and latest durable audit anchor.',
    source: 'audit_chain_anchors',
    owner: 'B37/B43',
  ),
  'event_outbox_undelivered_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Undelivered event_outbox rows awaiting bridge delivery.',
    source: 'event_outbox',
    owner: 'Phase 10a',
    thresholds: <String, Object?>{'yellow': 10000, 'red': 100000},
  ),
  'event_outbox_lag_seconds': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'seconds',
    description: 'Age of the oldest undelivered event_outbox row.',
    source: 'event_outbox',
    owner: 'Phase 10a',
    thresholds: <String, Object?>{'yellow': 60, 'red': 300},
  ),
  'usage_caps_breach_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Requests refused because usage caps were reached.',
    source: 'proxy usage accounting',
    owner: 'B33',
  ),
  'graph_node_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Canonical graph node count for operations health.',
    source: 'public.graph_health_metrics()',
    owner: 'B44',
  ),
  'graph_edge_count': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Canonical active graph edge count for operations health.',
    source: 'public.graph_health_metrics()',
    owner: 'B44',
    thresholds: <String, Object?>{'yellow': 3000000, 'red': 4000000},
  ),
  'graph_traversal_latency_ms': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'milliseconds',
    description: 'Graph traversal latency from the graph benchmark slice.',
    source: 'graph benchmark',
    owner: 'B44',
  ),
  'vector_index_size_per_corpus': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'count',
    description: 'Per-corpus vector index size.',
    source: 'vector index health helper',
    owner: 'B47',
  ),
  'vector_query_latency_ms': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'milliseconds',
    description: 'Filtered vector search latency summary.',
    source: 'filtered-search benchmark',
    owner: 'B47',
  ),
  'vector_recall': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'ratio',
    description: 'Filtered vector search benchmark recall.',
    source: 'filtered-search benchmark',
    owner: 'B47',
  ),
  'rollup_freshness_per_grain': ProxyHealthMetric(
    status: 'unknown',
    value: null,
    unit: 'seconds',
    description: 'Rollup freshness lag grouped by grain.',
    source: 'RollupFreshnessReporter.snapshot()',
    owner: 'B45',
  ),
};

const Map<String, ProxyHealthSurface> _reservedProxyHealthSurfaces =
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

class ScaffoldFailingProxyHealthCheckStore implements ProxyHealthCheckStore {
  const ScaffoldFailingProxyHealthCheckStore();

  @override
  Future<ProxyHealthStatus> check() async {
    throw StateError(
      '11a.11d scaffold: real Postgres health checks are not wired.',
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
  });

  final String id;
  final String text;
  final bool cacheBreakpoint;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'text': text,
    'cache_breakpoint': cacheBreakpoint,
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

/// Roles that admit a caller to `/v1/admin/operators` and
/// `/v1/admin/locations`. This 11A.1 surface is intentionally
/// super-admin-only because it exposes unscoped cross-operator reads
/// and writes; `ff_support` stays out until support-scoped reads land.
const Set<String> kFfOperatorLocationAdminRoles = <String>{'super_admin'};

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
        'remaining_requests_this_minute': decision.remainingRequestsThisMinute,
        'remaining_cost_cents_this_month': decision.remainingCostCentsThisMonth,
        'estimate_request_tokens': estimate.requestTokens,
        'note':
            '11a.10b smoke. No provider call performed. Counter store '
            'increment runs in a later slice once a real backend is wired.',
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
      ProxyLlmCompletion completion;
      try {
        completion = await llmProvider.complete(
          ProxyLlmRequest(
            question: question,
            promptBlocks: promptBlocks,
            tier: llmTier,
            modelId: modelId,
            cacheKey: promptBuilder.cacheKeyForCorpusVersion(corpusVersion),
            maxOutputTokens: PolicyTier.launch.maxOutputTokens,
          ),
        );
      } catch (_) {
        _writeJson(response, 503, <String, Object?>{
          'error': 'llm_provider_unavailable',
          'message': 'LLM provider unavailable',
        });
        return;
      }

      final responsePayload = <String, Object?>{
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

String _nonBlankOr(String? raw, String fallback) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return fallback;
  return value;
}
