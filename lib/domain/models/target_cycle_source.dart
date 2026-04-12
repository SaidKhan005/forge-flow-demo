/// How a [TargetCycle] was created.
///
/// Ordered by precedence: recommended is the automatic default,
/// managerOverride is the once-per-cycle manual adjustment,
/// adminReplacement is the escape hatch before cycle expiry.
enum TargetCycleSource {
  recommended,
  managerOverride,
  adminReplacement;

  String get label => switch (this) {
        recommended => 'recommended',
        managerOverride => 'manager_override',
        adminReplacement => 'admin_replacement',
      };

  static TargetCycleSource fromLabel(String label) => switch (label) {
        'recommended' => recommended,
        'manager_override' => managerOverride,
        'admin_replacement' => adminReplacement,
        _ => throw ArgumentError('Unknown TargetCycleSource label: $label'),
      };
}
