// Phase 9.3 - Authenticated session value class.
//
// Holds the resolved identity + tenant context that the proxy and
// the Flutter app shells need after login. Built from the JWT
// claims projected by [FirebaseProxyJwtVerifier] (Phase 9.1) plus
// the tenant resolution that lands in 9.2/9.3.
//
// Persistence is delegated to [SecureSessionStorage] (defined in
// services/secure_session_storage.dart) so the auth notifier can
// rehydrate on app start without depending on a particular backing
// store. Production wires `flutter_secure_storage` (Keychain on iOS;
// Android Keystore on Android); tests use an in-memory fake.
//
// This file is pure data — no I/O, no widgets — so the pubspec stays
// lean and the value class is testable in isolation.

class AuthSession {
  AuthSession({
    required this.userId,
    required this.operatorId,
    required this.locationId,
    required this.firebaseIdToken,
    required this.issuedAt,
    required this.expiresAt,
    required this.lastFreshAuthAt,
    required this.roles,
    required this.mfaEnrolled,
    this.logoUrl,
  });

  /// App-scope user identifier (`users.user_id` / Firebase `sub`).
  final String userId;

  /// Operator scope resolved from JWT custom claim `operator_id`.
  final String operatorId;

  /// Location scope resolved from JWT custom claim `location_id`
  /// (single-location operators get a default; multi-location
  /// operators select before retrieval).
  final String locationId;

  /// Verified Firebase ID token. Stored so the proxy can re-verify
  /// (or surface to a step-up flow) without forcing another Firebase
  /// roundtrip per request.
  final String firebaseIdToken;

  /// Token `iat`. Drives the local idea of "when did I issue this?"
  /// for diagnostics; not used for security decisions.
  final DateTime issuedAt;

  /// Token `exp`. The session is treated as expired locally when
  /// [DateTime.now] passes this; the proxy still re-validates exp
  /// per request (defense in depth).
  final DateTime expiresAt;

  /// JWT `auth_time` (when the user actually authenticated, possibly
  /// via MFA). Drives [stepUpFreshness] checks for sensitive ops.
  final DateTime lastFreshAuthAt;

  /// Roles projected from JWT custom claims (`is_super_admin` →
  /// `super_admin`, `is_ff_support` → `ff_support`, plus
  /// `roles_version:<n>`). Phase 9.6 layers DB-backed RBAC on top.
  final List<String> roles;

  /// Whether the user has any MFA factor enrolled. Drives the 9.4
  /// enrollment gate when MFA is required for the user's tier.
  final bool mfaEnrolled;

  /// Wave 2 W-5-mobile-FU — optional https URL (or `data:` URI in
  /// demo mode) for the operator's uploaded brand-mark. Mirrors the
  /// operator-web [OperatorWebSession.logoUrl] field and powers the
  /// mobile shell header brand-mark + the post-login Notifications
  /// and Settings AppBar brand-marks. Null when the operator has not
  /// uploaded a logo; consumers render the F&F splash icon fallback.
  ///
  /// Surface comes from the JWT custom claim `logo_url` (projected
  /// on the proxy side from `public.operators.logo_url`). The mobile
  /// reader path is identical for demo and live (HP #2 — no
  /// `kDemoMode` reader-side branch).
  final String? logoUrl;

  /// True iff [lastFreshAuthAt] is within [window] of [now]. Used by
  /// sensitive-operation step-up checks (role changes, billing, MFA
  /// enrollment, GDPR erasure). The locked freshness window is
  /// 5 minutes (Phase 9 decision lock).
  bool isAuthFresh({
    required DateTime now,
    Duration window = const Duration(minutes: 5),
  }) {
    return now.difference(lastFreshAuthAt) <= window;
  }

  /// True iff the session has not yet hit [expiresAt] at [now].
  bool isLive({required DateTime now}) => now.isBefore(expiresAt);

  bool hasRole(String role) => roles.contains(role);

  AuthSession copyWith({
    String? userId,
    String? operatorId,
    String? locationId,
    String? firebaseIdToken,
    DateTime? issuedAt,
    DateTime? expiresAt,
    DateTime? lastFreshAuthAt,
    List<String>? roles,
    bool? mfaEnrolled,
    String? logoUrl,
  }) {
    return AuthSession(
      userId: userId ?? this.userId,
      operatorId: operatorId ?? this.operatorId,
      locationId: locationId ?? this.locationId,
      firebaseIdToken: firebaseIdToken ?? this.firebaseIdToken,
      issuedAt: issuedAt ?? this.issuedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      lastFreshAuthAt: lastFreshAuthAt ?? this.lastFreshAuthAt,
      roles: roles ?? this.roles,
      mfaEnrolled: mfaEnrolled ?? this.mfaEnrolled,
      logoUrl: logoUrl ?? this.logoUrl,
    );
  }

  /// Compact JSON for [SecureSessionStorage]. Excludes the
  /// `firebaseIdToken` from any toString / debug print path — the
  /// token is in the JSON because the storage backend is encrypted
  /// (Keychain / Android Keystore in production), but we never log
  /// or echo it from the value class itself.
  Map<String, Object?> toJson() => <String, Object?>{
    'user_id': userId,
    'operator_id': operatorId,
    'location_id': locationId,
    'firebase_id_token': firebaseIdToken,
    'issued_at': issuedAt.toIso8601String(),
    'expires_at': expiresAt.toIso8601String(),
    'last_fresh_auth_at': lastFreshAuthAt.toIso8601String(),
    'roles': roles,
    'mfa_enrolled': mfaEnrolled,
    // Wave 2 W-5-mobile-FU — persist `logo_url` so the brand-mark
    // appears on cold-start before the next refresh repopulates the
    // session from JWT claims.
    'logo_url': logoUrl,
  };

  static AuthSession fromJson(Map<String, Object?> json) {
    final rawLogoUrl = json['logo_url'];
    return AuthSession(
      userId: json['user_id'] as String,
      operatorId: json['operator_id'] as String,
      locationId: json['location_id'] as String,
      firebaseIdToken: json['firebase_id_token'] as String,
      issuedAt: DateTime.parse(json['issued_at'] as String),
      expiresAt: DateTime.parse(json['expires_at'] as String),
      lastFreshAuthAt: DateTime.parse(json['last_fresh_auth_at'] as String),
      roles: (json['roles'] as List<Object?>).cast<String>(),
      mfaEnrolled: json['mfa_enrolled'] as bool,
      // Older envelopes (predating the W-5-mobile-FU follow-up) do not
      // carry `logo_url`; treat as null so cold-start rehydrate stays
      // forward-compatible.
      logoUrl: rawLogoUrl is String && rawLogoUrl.isNotEmpty
          ? rawLogoUrl
          : null,
    );
  }

  /// Diagnostic-safe string. NEVER echoes the Firebase ID token.
  @override
  String toString() =>
      'AuthSession(userId: $userId, operator: $operatorId, '
      'location: $locationId, exp: ${expiresAt.toIso8601String()}, '
      'roles: ${roles.join(',')}, mfa: $mfaEnrolled)';
}
