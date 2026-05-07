import 'dart:convert';

/// A single role row in the app-configured fallback wage generator.
///
/// Each row represents one labor role with its classification, hourly rate,
/// and weighted hours used for computing FOH/BOH wage standards.
///
/// Labor bucket rules:
///   - 'foh' rows contribute to the FOH wage standard.
///   - 'boh' rows contribute to the BOH wage standard.
///   - 'manager' rows contribute to the reference blended wage only.
///   - Manager rows do not automatically become FOH or BOH standards.
///
/// Server-truth fields (Theme H#4 / H#5):
///   - [serverId] — the proxy-side `wage_role_row_id` (UUID) when the row
///     came from the server. Null for local-only seeded rows.
///   - [jobCode], [vendorId], [vendorRoleId] — vendor identifiers for the
///     role; used by the wage authority gateway to bind to vendor records.
///   - [source] — 'operator_manual' (default) or 'vendor_*' marker.
///   - [isActive] — soft-delete flag.
///   - [effectiveAt] — when this rate becomes effective (UTC ISO-8601).
///   - [metadata] — opaque JSON envelope for extensions.
///   - [updatedBy] — user id who last touched the row.
class WageRoleRow {
  final int? id;
  final String? serverId;
  final String restaurantId;
  final String roleName;
  final String laborBucket; // 'foh', 'boh', 'manager'
  final double hourlyRate;
  final double weightedHours;
  final String? jobCode;
  final String? vendorId;
  final String? vendorRoleId;
  final String? source;
  final bool? isActive;
  final String? effectiveAt;
  final Map<String, Object?>? metadata;
  final String? updatedBy;

  const WageRoleRow({
    this.id,
    this.serverId,
    required this.restaurantId,
    required this.roleName,
    required this.laborBucket,
    required this.hourlyRate,
    required this.weightedHours,
    this.jobCode,
    this.vendorId,
    this.vendorRoleId,
    this.source,
    this.isActive,
    this.effectiveAt,
    this.metadata,
    this.updatedBy,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        if (serverId != null) 'server_id': serverId,
        'restaurant_id': restaurantId,
        'role_name': roleName,
        'labor_bucket': laborBucket,
        'hourly_rate': hourlyRate,
        'weighted_hours': weightedHours,
        if (jobCode != null) 'job_code': jobCode,
        if (vendorId != null) 'vendor_id': vendorId,
        if (vendorRoleId != null) 'vendor_role_id': vendorRoleId,
        if (source != null) 'source': source,
        if (isActive != null) 'is_active': isActive! ? 1 : 0,
        if (effectiveAt != null) 'effective_at': effectiveAt,
        if (metadata != null) 'metadata': _encodeMetadata(metadata!),
        if (updatedBy != null) 'updated_by': updatedBy,
      };

  factory WageRoleRow.fromMap(Map<String, dynamic> m) => WageRoleRow(
        id: m['id'] as int?,
        serverId: m['server_id'] as String?,
        restaurantId: m['restaurant_id'] as String,
        roleName: m['role_name'] as String,
        laborBucket: m['labor_bucket'] as String,
        hourlyRate: (m['hourly_rate'] as num).toDouble(),
        weightedHours: (m['weighted_hours'] as num).toDouble(),
        jobCode: m['job_code'] as String?,
        vendorId: m['vendor_id'] as String?,
        vendorRoleId: m['vendor_role_id'] as String?,
        source: m['source'] as String?,
        isActive: _decodeBool(m['is_active']),
        effectiveAt: m['effective_at'] as String?,
        metadata: _decodeMetadata(m['metadata']),
        updatedBy: m['updated_by'] as String?,
      );

  /// Whether this row is a manager role.
  bool get isManager => laborBucket == 'manager';

  /// Display label for the labor bucket.
  String get bucketLabel => switch (laborBucket) {
        'foh' => 'FOH',
        'boh' => 'BOH',
        'manager' => 'MGR',
        _ => laborBucket.toUpperCase(),
      };

  WageRoleRow copyWith({
    int? id,
    String? serverId,
    String? restaurantId,
    String? roleName,
    String? laborBucket,
    double? hourlyRate,
    double? weightedHours,
    String? jobCode,
    String? vendorId,
    String? vendorRoleId,
    String? source,
    bool? isActive,
    String? effectiveAt,
    Map<String, Object?>? metadata,
    String? updatedBy,
  }) =>
      WageRoleRow(
        id: id ?? this.id,
        serverId: serverId ?? this.serverId,
        restaurantId: restaurantId ?? this.restaurantId,
        roleName: roleName ?? this.roleName,
        laborBucket: laborBucket ?? this.laborBucket,
        hourlyRate: hourlyRate ?? this.hourlyRate,
        weightedHours: weightedHours ?? this.weightedHours,
        jobCode: jobCode ?? this.jobCode,
        vendorId: vendorId ?? this.vendorId,
        vendorRoleId: vendorRoleId ?? this.vendorRoleId,
        source: source ?? this.source,
        isActive: isActive ?? this.isActive,
        effectiveAt: effectiveAt ?? this.effectiveAt,
        metadata: metadata ?? this.metadata,
        updatedBy: updatedBy ?? this.updatedBy,
      );

  static bool? _decodeBool(Object? raw) {
    if (raw == null) return null;
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    if (raw is String) {
      final lower = raw.toLowerCase();
      if (lower == 'true' || lower == '1') return true;
      if (lower == 'false' || lower == '0') return false;
    }
    return null;
  }

  static String? _encodeMetadata(Map<String, Object?> meta) {
    if (meta.isEmpty) return null;
    return jsonEncode(meta);
  }

  static Map<String, Object?>? _decodeMetadata(Object? raw) {
    if (raw == null) return null;
    if (raw is Map<String, Object?>) return raw;
    if (raw is Map) return Map<String, Object?>.from(raw);
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, Object?>.from(decoded);
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}
