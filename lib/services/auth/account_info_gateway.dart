class AccountInfoRequest {
  const AccountInfoRequest({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
}

class AccountInfo {
  const AccountInfo({
    required this.displayName,
    required this.email,
    required this.statusLabel,
    required this.locationLabel,
    required this.roleLabels,
    required this.mfaEnabled,
    this.lastActiveAt,
    this.lastLoginAt,
    this.passwordUpdatedAt,
    this.logoUrl,
    this.subscriptionTier,
    this.trialMode = false,
    this.trialExpiresAt,
  });

  final String displayName;
  final String email;
  final String statusLabel;
  final String locationLabel;
  final List<String> roleLabels;
  final bool mfaEnabled;
  final DateTime? lastActiveAt;
  final DateTime? lastLoginAt;
  final DateTime? passwordUpdatedAt;

  /// Wave 2 W-5-mobile-FU — operator's uploaded brand-mark URL,
  /// projected from `public.operators.logo_url`. Null when the
  /// operator has not uploaded one; consumers render the F&F splash
  /// fallback.
  final String? logoUrl;

  /// Plans & Limits Phase 5b follow-up — the operator's subscription
  /// tier, projected from `public.operators.subscription_tier` (one of
  /// the six operator-approved keys). Null when the proxy does not
  /// carry a tier (older payloads). The operator-web live source maps
  /// this onto `OperatorWebSession.subscriptionTier` so the "Your plan"
  /// screen lights up on live; absence leaves the screen's honest
  /// "could not load your plan yet" state intact.
  final String? subscriptionTier;

  /// Plans & Limits Phase 5b follow-up — whether the operator is on a
  /// Pilot free preview (`public.operators.trial_mode`). Defaults false
  /// so an old/partial payload that omits the key reads as "not on a
  /// trial" rather than crashing.
  final bool trialMode;

  /// Plans & Limits Phase 5b follow-up — UTC instant the Pilot free
  /// preview ends (`public.operators.trial_expires_at`). Null when the
  /// operator is not on a trial or the payload does not carry it.
  final DateTime? trialExpiresAt;

  bool get hasAnyDisplayValue {
    return displayName.trim().isNotEmpty ||
        email.trim().isNotEmpty ||
        statusLabel.trim().isNotEmpty ||
        locationLabel.trim().isNotEmpty ||
        roleLabels.any((label) => label.trim().isNotEmpty) ||
        lastActiveAt != null ||
        lastLoginAt != null ||
        passwordUpdatedAt != null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'display_name': displayName,
    'email': email,
    'status_label': statusLabel,
    'location_label': locationLabel,
    'role_labels': roleLabels,
    'mfa_enabled': mfaEnabled,
    'last_active_at': lastActiveAt?.toUtc().toIso8601String(),
    'last_login_at': lastLoginAt?.toUtc().toIso8601String(),
    'password_updated_at': passwordUpdatedAt?.toUtc().toIso8601String(),
    'logo_url': logoUrl,
    // Plans & Limits Phase 5b follow-up — operator's own plan + trial.
    // Always serialized (null when unset) so the wire contract stays
    // explicit, matching the `logo_url` round-trip pattern.
    'subscription_tier': subscriptionTier,
    'trial_mode': trialMode,
    'trial_expires_at': trialExpiresAt?.toUtc().toIso8601String(),
  };

  static AccountInfo fromJson(Map<String, Object?> json) {
    final displayName = _readString(json['display_name']);
    final email = _readString(json['email']);
    final statusLabel = _readString(json['status_label']);
    final locationLabel = _readString(json['location_label']);
    final roleLabels = json['role_labels'];
    final mfaEnabled = json['mfa_enabled'];
    if (displayName == null ||
        email == null ||
        statusLabel == null ||
        locationLabel == null ||
        roleLabels is! List ||
        mfaEnabled is! bool) {
      throw const AccountInfoUnavailable(
        code: 'malformed_response',
        message: 'account info response was incomplete',
      );
    }
    return AccountInfo(
      displayName: displayName,
      email: email,
      statusLabel: statusLabel,
      locationLabel: locationLabel,
      roleLabels: List<String>.unmodifiable(
        roleLabels
            .whereType<String>()
            .map((label) => label.trim())
            .where((label) => label.isNotEmpty),
      ),
      mfaEnabled: mfaEnabled,
      lastActiveAt: _readDateTime(json['last_active_at']),
      lastLoginAt: _readDateTime(json['last_login_at']),
      passwordUpdatedAt: _readDateTime(json['password_updated_at']),
      logoUrl: _readString(json['logo_url']),
      // Plans & Limits Phase 5b follow-up — optional, null-safe. These
      // are intentionally NOT part of the required-field guard above so
      // a pre-follow-up proxy (which omits them) still parses. Absence
      // leaves the "Your plan" screen's honest empty state intact.
      subscriptionTier: _readString(json['subscription_tier']),
      trialMode: _readBool(json['trial_mode']),
      trialExpiresAt: _readDateTime(json['trial_expires_at']),
    );
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static bool _readBool(Object? value) {
    if (value is bool) return value;
    // Tolerate a stringy / missing value so an old or partial payload
    // never crashes; default to "not on a trial".
    if (value is String) return value.trim().toLowerCase() == 'true';
    return false;
  }

  static DateTime? _readDateTime(Object? value) {
    if (value is DateTime) return value.toUtc();
    final raw = _readString(value);
    if (raw == null) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }
}

class AccountInfoUnavailable implements Exception {
  const AccountInfoUnavailable({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String toString() => 'AccountInfoUnavailable(code: $code)';
}

abstract class AccountInfoGateway {
  Future<AccountInfo> load(AccountInfoRequest request);
}
