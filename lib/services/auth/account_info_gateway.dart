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
    );
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
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
