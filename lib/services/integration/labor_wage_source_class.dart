// Phase 8 spine-bridge Lane .2 — labor wage source class sidecar.
//
// Authority:
//   * docs/contracts/integration_spine_architecture_contract.md
//     "2026-05-05 falsehood corrections" (binding) items 6-9 +
//     "Sub-lane shape -> .2" (4-way wage resolution).
//   * docs/contracts/core_app_architecture.md Layer 4 (wage authority is
//     a sanctioned companion seam, four source classes).
//
// This sidecar lookup keys every Wave B labor vendor by `vendorId`
// onto its 2026-05-05-confirmed wage source class. The aggregator
// (`canonical_fact_to_closed_shift_input.dart`) consults this sidecar
// to decide which of the four resolution paths to take when computing
// labor dollars from canonical labor punches.
//
// NOT a modification of the frozen Wave B
// `integration_adapter_common.dart` capability profile — keeping this
// sidecar separate preserves the file-disjoint guarantee on the 17
// shipped adapters. When a vendor's classification changes (e.g.
// `7shifts` upgrades to `perEmployeeWithDollars` after the
// `/reports/hours_and_wages` follow-up), only this file edits.

import '../../integrations/labor/adp_labor_adapter.dart';
import '../../integrations/labor/agendrix_labor_adapter.dart';
import '../../integrations/labor/humanity_labor_adapter.dart';
import '../../integrations/labor/push_operations_labor_adapter.dart';
import '../../integrations/labor/quickbooks_time_labor_adapter.dart';
import '../../integrations/labor/seven_shifts_labor_adapter.dart';

/// The four wage source classes a labor vendor can fall into.
///
/// Per 2026-05-05 corrections, no Wave B vendor presently qualifies as
/// [perEmployeeWithDollars]. 7shifts qualifies IFF the adapter consumes
/// `/reports/hours_and_wages` (deferred to the
/// `8.7S.upgrade.hours_and_wages` follow-up); until then it sits in
/// [perEmployeeWithRates].
enum LaborWageSourceClass {
  /// Vendor exposes per-shift dollar totals directly. Aggregator sums
  /// to FOH/BOH dollars.
  perEmployeeWithDollars,

  /// Vendor exposes per-employee hourly rate; aggregator computes
  /// dollars = rate × duration per punch.
  perEmployeeWithRates,

  /// Vendor exposes per-position pay rate + scheduled hours;
  /// aggregator computes dollars via rate × hours per role. Maps 1:1
  /// to `wage_role_rows` (the Jim Taylor model's weighted-up FOH/BOH
  /// input).
  perPositionWithRates,

  /// Vendor exposes hours but no rates or dollars. Aggregator falls
  /// back to target wage × hours (the operator-set wage mix from
  /// Settings is the sanctioned fallback when wage_source = manual_mix).
  hoursOnly,
}

/// Resolve the wage source class for a labor vendor by its `vendorId`.
///
/// Returns null when the [vendorId] is not a known Wave B labor vendor.
/// The caller (aggregator) treats null the same as [hoursOnly] and falls
/// to the target-wage substitution path with provenance string
/// `vendor_<id>_dollars_unavailable_target_wage_substituted`.
LaborWageSourceClass? laborWageSourceClassFor(String vendorId) {
  return _laborWageSourceClassByVendorId[vendorId];
}

/// Sidecar map captured per the 2026-05-05 binding corrections.
///
///   * `seven_shifts` — moved out of `perEmployeeWithDollars`
///     (`hours_and_wages` endpoint not yet wired). Today's lived
///     classification is `perEmployeeWithRates` via
///     `time_punches.hourly_wage`.
///   * `quickbooks_time` — moved out of `perEmployeeWithDollars`
///     (Timesheets endpoint returns hours only; rates live on
///     `Users.pay_rate`). Aggregator computes dollars via rate ×
///     duration.
///   * `humanity` + `agendrix` — `perPositionWithRates`. Closer to model
///     truth because the per-position shape maps 1:1 to
///     `wage_role_rows`.
///   * `adp` + `push_operations` — `hoursOnly` for V1. ADP wage
///     ingestion explicitly deferred per Wave B doc pack; Push primary
///     docs inaccessible (developer-portal landing page only).
const Map<String, LaborWageSourceClass> _laborWageSourceClassByVendorId =
    <String, LaborWageSourceClass>{
  // perEmployeeWithDollars — 7shifts joined here when the
  // `8.spine-bridge.7S.upgrade` lane wired the
  // `/reports/hours_and_wages` endpoint (per-shift `total_pay`).
  kSevenShiftsVendorId: LaborWageSourceClass.perEmployeeWithDollars,

  kQuickBooksTimeVendorId: LaborWageSourceClass.perEmployeeWithRates,

  kHumanityVendorId: LaborWageSourceClass.perPositionWithRates,
  agendrixVendorId: LaborWageSourceClass.perPositionWithRates,

  kAdpVendorId: LaborWageSourceClass.hoursOnly,
  pushOperationsVendorId: LaborWageSourceClass.hoursOnly,
};
