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
class WageRoleRow {
  final int? id;
  final String restaurantId;
  final String roleName;
  final String laborBucket; // 'foh', 'boh', 'manager'
  final double hourlyRate;
  final double weightedHours;

  const WageRoleRow({
    this.id,
    required this.restaurantId,
    required this.roleName,
    required this.laborBucket,
    required this.hourlyRate,
    required this.weightedHours,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'restaurant_id': restaurantId,
        'role_name': roleName,
        'labor_bucket': laborBucket,
        'hourly_rate': hourlyRate,
        'weighted_hours': weightedHours,
      };

  factory WageRoleRow.fromMap(Map<String, dynamic> m) => WageRoleRow(
        id: m['id'] as int?,
        restaurantId: m['restaurant_id'] as String,
        roleName: m['role_name'] as String,
        laborBucket: m['labor_bucket'] as String,
        hourlyRate: (m['hourly_rate'] as num).toDouble(),
        weightedHours: (m['weighted_hours'] as num).toDouble(),
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
    String? restaurantId,
    String? roleName,
    String? laborBucket,
    double? hourlyRate,
    double? weightedHours,
  }) =>
      WageRoleRow(
        id: id ?? this.id,
        restaurantId: restaurantId ?? this.restaurantId,
        roleName: roleName ?? this.roleName,
        laborBucket: laborBucket ?? this.laborBucket,
        hourlyRate: hourlyRate ?? this.hourlyRate,
        weightedHours: weightedHours ?? this.weightedHours,
      );
}
