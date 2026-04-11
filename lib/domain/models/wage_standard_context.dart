/// Resolved wage-standard authority for a restaurant.
///
/// Contains the FOH and BOH wage standards currently in force, plus
/// a reference blended wage and explicit source provenance.
///
/// Rules:
///   - FOH wage and BOH wage are source-backed standards.
///   - Blended wage is always derived, never stored as canonical source truth.
///   - Manager rows contribute to reference blended wage only.
library;

import 'wage_standard_source.dart';

class WageStandardContext {
  final String restaurantId;
  final double? fohWage;
  final double? bohWage;
  final double? referenceBlendedWage;
  final WageStandardSource source;
  final String builtAt;

  const WageStandardContext({
    required this.restaurantId,
    required this.fohWage,
    required this.bohWage,
    required this.referenceBlendedWage,
    required this.source,
    required this.builtAt,
  });

  /// Whether this context has resolved wage values.
  bool get isAvailable => source != WageStandardSource.unavailable;

  /// Whether the source is integration-derived (labor system).
  bool get isLaborDerived =>
      source == WageStandardSource.laborDerivedFromActualDollars ||
      source == WageStandardSource.laborDerivedFromRatesAndHours;
}
