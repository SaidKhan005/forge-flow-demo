// Phase 8 spine-bridge Lane .2 — aggregator-emitted provenance context.
//
// Authority:
//   * docs/contracts/integration_spine_architecture_contract.md
//     "Sub-lane shape -> .2" (binding) — provenance strings the writer
//     attaches to ShiftRecord.
//   * docs/contracts/metric_card_honesty_contract.md naming rule
//     (vendor_<id> / vendor_<id>_covers_unavailable_app_forecast_substituted /
//     operator_manual_entry_per_daypart / target_wage_substituted /
//     vendor_<id>_dollars_unavailable_target_wage_substituted /
//     vendor_<id>_per_employee_actual_dollars /
//     vendor_<id>_per_position_actual_dollars).
//
// The aggregator emits a [ClosedShiftInput] (the existing typed input
// to `ShiftFactBuilder.fromClosedShiftInput`) plus this sibling
// [AggregatorProvenanceContext] which carries:
//
//   * `coversProvenance` — naming the covers source class (vendor /
//     forecast / operator manual / vendor+walk-in pattern).
//   * `laborDollarsProvenance` — naming the labor dollars source class
//     (vendor per-employee / vendor per-position / target-wage
//     substitution / manual mix substitution).
//   * `priorTargetProfileVersionId` — the existing
//     `shift_records.target_profile_version_id` at the slot, when
//     present. The writer reuses this verbatim on overwrite per
//     `core_app_architecture.md` "What never rewrites" rule.
//
// I/O free; no Postgres / SQLite imports; no widget code.

/// Sibling value object the spine-bridge aggregator emits alongside
/// `ClosedShiftInput`. The writer consumes both to land a `ShiftRecord`
/// row whose provenance strings honor the metric card honesty contract.
class AggregatorProvenanceContext {
  const AggregatorProvenanceContext({
    required this.coversProvenance,
    required this.laborDollarsProvenance,
    required this.priorTargetProfileVersionId,
    this.hasPriorShiftRecord = false,
    this.priorBusinessTimingProfileId,
    this.priorBusinessTimingProfileVersionId,
    this.priorServicePeriodKey,
  });

  /// Provenance string for the covers value attached to the emitted
  /// `ClosedShiftInput`. Allowed shapes (see contract):
  ///
  ///   * `vendor_<id>` — POS adapter exposed `coversFieldExposed=true`
  ///     and the vendor canonical fact carried `covers`.
  ///   * `vendor_<id>_covers_unavailable_app_forecast_substituted` —
  ///     POS adapter declared `coversFieldExposed=false` (Square,
  ///     Clover) AND the operator's covers source preference resolved
  ///     to `forecast`; aggregator filled covers from
  ///     `DemandForecastContext.resolvedWeeklyForecastCovers` allocated
  ///     to this daypart.
  ///   * `operator_manual_entry_per_daypart` — operator typed a value
  ///     into `data_accuracy_settings.covers_manual_entries` for this
  ///     `(business_date, daypart)`.
  ///   * `vendor_<id>_seated_plus_operator_walk_in_count` — Pattern A
  ///     reservation+walk-in resolution (Libro / OpenTable / SevenRooms
  ///     seated party_size summed with operator-supplied walk-in
  ///     count); the qualifier suffix preserves vendor identity.
  final String coversProvenance;

  /// Provenance string for the labor dollars value attached to the
  /// emitted `ClosedShiftInput`. Allowed shapes (see contract):
  ///
  ///   * `vendor_<id>_per_employee_actual_dollars` — labor adapter in
  ///     `LaborWageSourceClass.perEmployeeWithDollars` populated dollar
  ///     totals on each punch; aggregator summed to FOH/BOH dollars.
  ///   * `vendor_<id>_per_employee_actual_dollars_per_employee_rates`
  ///     — labor adapter in `perEmployeeWithRates` populated rate +
  ///     duration; aggregator computed dollars = rate × duration. The
  ///     `_per_employee_rates` qualifier preserves the distinction so
  ///     the renderer can disambiguate the two paths.
  ///   * `vendor_<id>_per_position_actual_dollars` — labor adapter in
  ///     `LaborWageSourceClass.perPositionWithRates` populated
  ///     per-position pay rates + scheduled hours; aggregator computed
  ///     dollars per role.
  ///   * `target_wage_substituted` — operator's `wage_source =
  ///     manual_mix` override forced the operator-typed wage mix
  ///     unconditionally regardless of vendor capability class.
  ///   * `vendor_<id>_dollars_unavailable_target_wage_substituted` —
  ///     vendor exposed neither dollars nor rates (or no labor adapter
  ///     connected); aggregator fell back to target wage × hours.
  final String laborDollarsProvenance;

  /// The `target_profile_version_id` the writer must reuse on
  /// re-aggregation. Non-null when a prior `shift_records` row exists
  /// at this `(operator_id, location_id, business_date, daypart)`
  /// slot. Null when this is the first-time aggregation, in which
  /// case the writer mints a fresh version from the current
  /// `ActiveTargetProfile`.
  ///
  /// Concern A binding (per
  /// `docs/contracts/core_app_architecture.md` Layer 4 + Layer 11 +
  /// Layer 12 + the "What never rewrites" non-negotiables): the
  /// writer NEVER overwrites a closed shift's locked target profile
  /// version under a newer cycle. Vendor corrections never re-grade
  /// closed history.
  final String? priorTargetProfileVersionId;

  /// True when the aggregator found an existing closed row for the
  /// slot. The writer uses this to distinguish a brand-new row from a
  /// legacy prior row whose timing provenance columns are null.
  final bool hasPriorShiftRecord;

  /// Timing provenance already stored on the prior closed row. When
  /// [hasPriorShiftRecord] is true, the writer reuses these values
  /// verbatim, including nulls for legacy rows, so replay never
  /// rewrites closed timing truth.
  final String? priorBusinessTimingProfileId;
  final String? priorBusinessTimingProfileVersionId;
  final String? priorServicePeriodKey;
}
