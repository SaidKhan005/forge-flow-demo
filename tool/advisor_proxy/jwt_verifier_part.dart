// Forge & Flow advisor proxy — JWT verification + Operator scope + Request guard
// (part of advisor_proxy.dart).
//
// chore(advisor-proxy): pure size refactor. This part file holds the JWT
// verifier interface hierarchy (ProxyJwtClaims, ProxyJwtVerificationError,
// ScaffoldRejectingJwtVerifier, ServicePrincipalJwtVerifier,
// CompositeProxyJwtVerifier, JwtKeyMaterial, PointyCastleRs256SignatureValidator,
// FirebaseProxyJwtVerifier), the bearer-token extraction helper, and the
// Operator scope + request guard (OperatorContext, ProxyAuthError,
// ProxyRequestGuard). Mechanically lifted from advisor_proxy.dart so the
// monolith stays under the kAdvisorProxyMaxLines bleed-stop ceiling enforced
// by tool/advisor_proxy_size_lint.dart. As a Dart `part` it shares the
// library's imports and private scope verbatim — routing, shapes, status
// codes, RLS, auth, and SQL are all unchanged. No symbol was renamed.

part of 'advisor_proxy.dart';

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
    this.permissionVersion,
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

  /// B1.A3 — monotonically increasing stamp embedded in the JWT on token
  /// issuance. The proxy auth-middleware compares this against the DB
  /// value on every request; a mismatch means a permission was granted or
  /// revoked after the token was issued and forces a 401.
  final int? permissionVersion;
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
    } on FormatException catch (_) {
      // utf8.decode + jsonDecode both surface FormatException for malformed
      // input; convert to the verifier-typed error so callers see a stable
      // 401 rejection.
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
    } on FormatException catch (_) {
      // base64Url.decode throws FormatException for malformed input; convert
      // to the verifier-typed error so the composite returns a 401.
      throw ProxyJwtVerificationError(
        'service principal JWT $name is not valid base64url',
      );
    }
  }

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
}

/// CODE_HEALTH L4 — generic, verifier-agnostic rejection used by the
/// composite when every verifier fails. The pre-L4 composite leaked
/// "service principal JWT …" wording from the SP verifier when the SP
/// arm ran last, which let an attacker enumerate which verifiers are
/// installed by probing tokens of different shapes and reading the
/// distinct error strings. The hardened composite always returns this
/// single, neutral error.
const String _kCompositeJwtRejectionMessage = 'invalid bearer token';

class CompositeProxyJwtVerifier implements ProxyJwtVerifier {
  const CompositeProxyJwtVerifier(this.verifiers);

  final List<ProxyJwtVerifier> verifiers;

  /// Probe every configured verifier in parallel before deciding the
  /// outcome. Two reasons:
  ///
  ///   1. Constant error message — the rejection path always throws
  ///      [_kCompositeJwtRejectionMessage] regardless of which
  ///      verifiers are installed or which one happened to run last.
  ///      The pre-L4 implementation surfaced the LAST verifier's
  ///      error verbatim, which leaked verifier-installed enumeration
  ///      signal (e.g. "service principal JWT …" when the SP verifier
  ///      was wired vs. "firebase id token …" when only Firebase
  ///      ran).
  ///
  ///   2. Constant timing — every verifier runs every time, so the
  ///      observable wall-clock latency does not depend on which arm
  ///      accepted or rejected. The pre-L4 implementation
  ///      short-circuited on the first success, leaking which
  ///      verifier accepted via timing differences between the
  ///      Firebase RS256 path (slower) and the SP HS256 path (faster).
  ///
  /// We also drain all futures even after we have a winner so that no
  /// pending verification leaks an `unhandled exception` warning.
  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    if (verifiers.isEmpty) {
      throw ProxyJwtVerificationError(_kCompositeJwtRejectionMessage);
    }
    final futures = <Future<_VerifierProbe>>[];
    for (final verifier in verifiers) {
      futures.add(_probeVerifier(verifier, bearerToken));
    }
    final results = await Future.wait(futures);
    ProxyJwtClaims? winner;
    for (final result in results) {
      if (result.claims != null) {
        // Constant-time chooser: keep the first claims we encounter
        // (deterministic over the configured verifier order) without
        // short-circuiting the loop.
        winner ??= result.claims;
      }
    }
    if (winner != null) return winner;
    throw ProxyJwtVerificationError(_kCompositeJwtRejectionMessage);
  }

  static Future<_VerifierProbe> _probeVerifier(
    ProxyJwtVerifier verifier,
    String bearerToken,
  ) async {
    try {
      final claims = await verifier.verify(bearerToken);
      return _VerifierProbe.success(claims);
    } on Exception catch (_) {
      // Swallow the verifier-specific error string here; the composite
      // surfaces a single neutral message at the top of [verify]. Narrowed
      // to Exception so genuine `Error`s (assertion failures, OOM, etc.)
      // continue to propagate instead of being silently masked.
      return const _VerifierProbe.failure();
    }
  }
}

class _VerifierProbe {
  const _VerifierProbe.success(this.claims);
  const _VerifierProbe.failure() : claims = null;

  final ProxyJwtClaims? claims;
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
    } on Exception catch (_) {
      // pointycastle's ASN1Parser throws a variety of internal Exception
      // subtypes (ASN1Exception, RangeError-wrapping cases, etc.); collapse
      // them all into a typed FormatException so the verifier surface stays
      // uniform. `Error`s such as RangeError continue to propagate.
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
    } on FormatException catch (_) {
      // base64Decode raises FormatException for malformed input; surface a
      // friendlier message so the verifier surface stays uniform.
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
    } on FormatException catch (_) {
      // jsonDecode throws FormatException for malformed input; convert to
      // the verifier-typed error so the verifier returns a 401.
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
    } on Exception catch (_) {
      // Cryptography backends throw a variety of Exception subtypes
      // (FormatException, ArgumentError-like wrapped exceptions, opaque
      // pointycastle failures, etc.). Collapse them into the verifier-typed
      // rejection. `Error`s remain unmasked so test failures still surface.
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
      // B1.A3 — carry the permission_version claim so the middleware can
      // compare it against the DB value without an extra network round-trip.
      permissionVersion: _readOptionalInt(payloadJson, 'permission_version'),
    );
  }

  static Map<String, Object?> _decodeJwtSegment(String segment, String name) {
    final bytes = _base64UrlDecodeBytes(segment, name);
    final String json;
    try {
      json = utf8.decode(bytes);
    } on FormatException catch (_) {
      // utf8.decode raises FormatException on invalid byte sequences.
      throw ProxyJwtVerificationError('JWT $name is not valid UTF-8');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (_) {
      // jsonDecode raises FormatException on malformed JSON.
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
    } on FormatException catch (_) {
      // base64Url.decode raises FormatException on malformed input.
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
    this.permissionVersion,
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

  /// B1.A3 — JWT claim value at request time. Null for tokens issued
  /// before the migration lands (treated as "unchecked").
  final int? permissionVersion;

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
  ///   - Verified token without operator/location scope -> 403,
  ///     UNLESS the verified roles include `ff_support` or
  ///     `super_admin`. Those are inherently multi-operator identities
  ///     (B1 of the post-Codex addendum); the proxy returns an
  ///     [OperatorContext] with empty operator/location strings and
  ///     downstream routes that need a concrete tenant must call the
  ///     impersonation flow (`/v1/admin/auth/sessions`) to pick one
  ///     before they execute writes.
  ///
  /// Successful return implies (a) the JWT is verified and (b) either
  /// the caller has both an `operatorId` and a `locationId`, OR the
  /// caller is a global admin (`ff_support` / `super_admin`) and both
  /// scope fields are empty strings.
  Future<OperatorContext> requireOperatorContext({
    required String? authorizationHeader,
  }) async {
    final claims = await requireVerifiedClaims(
      authorizationHeader: authorizationHeader,
    );

    final operatorId = claims.operatorId;
    final locationId = claims.locationId;
    final hasOperatorScope = operatorId != null && operatorId.isNotEmpty;
    final hasLocationScope = locationId != null && locationId.isNotEmpty;
    final isGlobalAdmin = _hasGlobalAdminRole(claims.roles);
    if (!hasOperatorScope || !hasLocationScope) {
      // B1 sign-in contract alignment: scope-less ff_support /
      // super_admin tokens are accepted because their inherent
      // identity is "platform-wide, no single tenant". Log every
      // accept + reject branch with `user_id` + `roles` + claim
      // presence so production traffic surfaces the path in use.
      if (!isGlobalAdmin) {
        log(
          LogSeverity.warning,
          'proxy.auth.scope_missing_rejected',
          fields: <String, Object?>{
            'user_id': claims.userId,
            'roles': claims.roles,
            'has_operator_id': hasOperatorScope,
            'has_location_id': hasLocationScope,
            'claim_shape': 'tenant_scoped',
            'status_code': 403,
          },
        );
        throw ProxyAuthError(
          'verified token is missing operator or location scope',
          statusCode: 403,
        );
      }
      log(
        LogSeverity.info,
        'proxy.auth.scope_missing_accepted_global_admin',
        fields: <String, Object?>{
          'user_id': claims.userId,
          'roles': claims.roles,
          'has_operator_id': hasOperatorScope,
          'has_location_id': hasLocationScope,
          'claim_shape': 'global_admin',
        },
      );
      // Bind a sentinel so log-context filters can still group lines by
      // user even though no operator was picked yet. Pass null when the
      // operator id is absent so the context filter is not confused by
      // an empty-string tenant id.
      bindOperatorIdToLogContext(hasOperatorScope ? operatorId : null);
      return OperatorContext(
        userId: claims.userId,
        operatorId: hasOperatorScope ? operatorId : '',
        locationId: hasLocationScope ? locationId : '',
        roles: claims.roles,
        actorKind: claims.actorKind,
        servicePrincipalId: claims.servicePrincipalId,
        firebaseUid: claims.firebaseUid,
        rolesVersion:
            claims.rolesVersion ?? _rolesVersionFromRoles(claims.roles),
        lastFreshAuthAt: claims.lastFreshAuthAt,
        permissionVersion: claims.permissionVersion,
      );
    }

    // HARD-G observability: bind the operator id onto the active log
    // context so every subsequent log line in this request inherits
    // it. Safe to call when no zone is active (no-op).
    bindOperatorIdToLogContext(operatorId);

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
      permissionVersion: claims.permissionVersion,
    );
  }

  /// True when the verified roles list includes a global admin role
  /// (`ff_support` or `super_admin`). These identities are platform-
  /// wide; they do not require per-tenant scope on the JWT and pick
  /// the active operator via impersonation downstream.
  static bool _hasGlobalAdminRole(List<String> roles) {
    for (final role in roles) {
      if (role == 'ff_support' || role == 'super_admin') return true;
    }
    return false;
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
