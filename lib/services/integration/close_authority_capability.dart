// Per-Daypart Targets V1 — Slice 1.5 — close authority capability sidecar.
//
// Authority:
//   * docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md
//     Slice 1.5 (binding) — "shift_close_authority becomes auto-derived
//     from per-vendor capability + business-day-start" (operator decision
//     2026-05-15).
//   * docs/contracts/core_app_architecture.md Layer 4 (close moment is a
//     property of the source system, not a hand-set operator switch).
//
// What this sidecar does:
//
//   Keys every Wave B inbound vendor by `vendorId` onto a coarse two-class
//   capability:
//
//     * vendorReliableFinalization
//         The vendor exposes a stable per-shift finalization signal (a
//         `closed_at` timestamp, an "ended" status, or equivalent). The
//         aggregator should use that timestamp as the close moment.
//     * unreliableFallbackToBusinessDayStart
//         The vendor does NOT expose a stable finalization signal. The
//         aggregator falls back to the operator's configured
//         business-day-start time as the close moment.
//
//   The classification mirrors the same disjoint-file shape used by
//   `labor_wage_source_class.dart` and `pos_covers_capability.dart`:
//   one sidecar map keyed by vendor id, no edits to the frozen adapter
//   capability profiles, one file to flip when a vendor's lived
//   capability changes.
//
// What "close moment" means in V1:
//
//   * vendorReliableFinalization → the canonical fact's vendor
//     finalization timestamp (POS `closed_at`) is the close moment.
//   * unreliableFallbackToBusinessDayStart → the operator's
//     `RestaurantTimingConfig.businessDayStartLocalTime` rollover is the
//     close moment for the row's business date.
//
// Why this replaces the `shift_close_authority` setting:
//
//   Until 2026-05-15 the operator could toggle "vendor finalization vs
//   app-local cutoff" on `restaurant_timing_configs.shift_close_authority`.
//   The operator decision (per the plan doc + the orchestrator brief)
//   collapses that to an auto-derived value: each vendor either does or
//   doesn't expose a reliable finalization signal, and the operator's
//   business-day-start is the universal fallback. There is no operator
//   choice in the middle.
//
// Vendor coverage:
//
//   POS vendors (Wave B inbound POS adapters):
//
//     * toast, aloha_ncr_voyix, oracle_micros_simphony, lightspeed_lsk,
//       revel, square, clover — all expose a `closed_at` or equivalent
//       per-check timestamp on their canonical sales rows. The
//       per-adapter `VendorCapabilityProfile.coversFieldExposed` flag
//       differs by vendor (see `pos_covers_capability.dart`) but the
//       per-check close timestamp is a separate signal: every Wave B
//       POS adapter populates `cover_facts.closed_at`. Therefore every
//       Wave B POS vendor classifies as `vendorReliableFinalization`.
//
//   Labor + reservation vendors:
//
//     * Labor vendors (7shifts, quickbooks_time, adp, humanity, agendrix,
//       push_operations) and reservation vendors (libro, opentable,
//       sevenrooms, tock) do NOT write `shift_records.source_system`
//       directly — the aggregator's POS vendor id is what stamps the
//       row. They are intentionally omitted from this map; the lookup
//       returns null and the caller falls back to
//       `unreliableFallbackToBusinessDayStart` (the safer assumption).

library;

import '../../integrations/pos/aloha_ncr_voyix_pos_adapter.dart';
import '../../integrations/pos/clover_credential_bridge.dart'
    show kCloverVendorId;
import '../../integrations/pos/lightspeed_lsk_pos_adapter.dart';
import '../../integrations/pos/oracle_micros_simphony_pos_adapter.dart';
import '../../integrations/pos/revel_pos_adapter.dart';
import '../../integrations/pos/square_pos_adapter.dart';
import '../../integrations/pos/toast_credential_bridge.dart'
    show kToastVendorId;

/// Per-vendor close-authority capability. Two values, no middle ground:
/// either the vendor's finalization signal is trustworthy enough to be
/// the close moment, or it is not and the operator's business-day-start
/// is the fallback.
enum CloseAuthorityCapability {
  /// Vendor exposes a reliable per-shift finalization signal (POS
  /// `closed_at`, or equivalent). Aggregator uses the vendor timestamp
  /// as the close moment.
  vendorReliableFinalization,

  /// Vendor does not expose a reliable finalization signal, or the
  /// vendor id is unknown to F&F. Aggregator falls back to the
  /// operator's `businessDayStartLocalTime` for the row's business date
  /// as the close moment.
  unreliableFallbackToBusinessDayStart,
}

/// Resolve the close-authority capability for [vendorId].
///
/// Returns null when [vendorId] is null, empty, or not a known Wave B
/// POS vendor. The caller (aggregator) treats null as
/// [CloseAuthorityCapability.unreliableFallbackToBusinessDayStart]:
/// when F&F cannot classify the vendor, the safer default is to fall
/// back to the operator's business-day-start time as the close moment.
CloseAuthorityCapability? closeAuthorityCapabilityFor(String? vendorId) {
  if (vendorId == null || vendorId.isEmpty) return null;
  return _closeAuthorityCapabilityByVendorId[vendorId];
}

/// Resolve the close-authority capability for [vendorId], applying the
/// null-as-unreliable fallback. Returns
/// [CloseAuthorityCapability.unreliableFallbackToBusinessDayStart] when
/// the vendor is unknown.
CloseAuthorityCapability resolveCloseAuthorityCapability(String? vendorId) {
  return closeAuthorityCapabilityFor(vendorId) ??
      CloseAuthorityCapability.unreliableFallbackToBusinessDayStart;
}

/// Sidecar map captured 2026-05-15 per the per-daypart V1 plan.
///
/// Every Wave B POS adapter writes `cover_facts.closed_at` for finalized
/// checks. None of the labor or reservation vendors set
/// `shift_records.source_system` directly — they are intentionally
/// omitted so the lookup falls back to
/// `unreliableFallbackToBusinessDayStart`.
const Map<String, CloseAuthorityCapability> _closeAuthorityCapabilityByVendorId =
    <String, CloseAuthorityCapability>{
  kToastVendorId: CloseAuthorityCapability.vendorReliableFinalization,
  kAlohaNcrVoyixVendorId: CloseAuthorityCapability.vendorReliableFinalization,
  oracleMicrosSimphonyVendorId:
      CloseAuthorityCapability.vendorReliableFinalization,
  kLightspeedLskVendorId: CloseAuthorityCapability.vendorReliableFinalization,
  kRevelVendorId: CloseAuthorityCapability.vendorReliableFinalization,
  kSquareVendorId: CloseAuthorityCapability.vendorReliableFinalization,
  kCloverVendorId: CloseAuthorityCapability.vendorReliableFinalization,
};
