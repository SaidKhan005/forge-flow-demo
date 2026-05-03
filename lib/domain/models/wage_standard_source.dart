/// Provenance enum for the current wage-standard authority.
///
/// Ordered by integration-first precedence:
///   1. laborDerivedFromActualDollars — official labor dollars ÷ hours
///   2. laborDerivedFromRatesAndHours — official labor rates × hours
///   3. appConfiguredGenerator        — restaurant-scoped role/rate setup
///   4. configFallback                — MeridianConfig defaults
///   5. unavailable                   — no wage data at all
enum WageStandardSource {
  laborDerivedFromActualDollars,
  laborDerivedFromRatesAndHours,
  appConfiguredGenerator,
  configFallback,
  unavailable;

  String get displayLabel => switch (this) {
    laborDerivedFromActualDollars => 'Labor dollars and hours',
    laborDerivedFromRatesAndHours => 'Labor rates and hours',
    appConfiguredGenerator => 'Custom wage mix',
    configFallback => 'Default wages',
    unavailable => 'Not available',
  };
}
