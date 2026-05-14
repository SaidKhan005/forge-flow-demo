// Wave 2 MO-2 — POS-vendor covers-capability lookup.
//
// Mobile cannot import the per-adapter `VendorCapabilityProfile`
// objects directly (each adapter brings a heavy connect/refresh
// surface), but the mobile Covers Setup section needs to know whether
// the active POS vendor exposes a covers field so it can frame the
// manual-entry form as the **primary path** (POS does NOT expose
// covers — Square, Clover) or as a **manual override** (POS DOES
// expose covers — Toast, Aloha, Lightspeed K-Series, Oracle MICROS
// Simphony, Revel).
//
// The truth source is the per-adapter `VendorCapabilityProfile`
// declared in `lib/integrations/pos/*_pos_adapter.dart`. This file is
// the canonical mirror for mobile lookups; the contract test below
// keeps the two in sync.
//
// Vendor coverage matches Wave B POS adapters (17 inbound vendors).
// New POS adapters MUST update this map; the contract test in
// `test/services/integration/pos_covers_capability_contract_test.dart`
// fails closed if a vendor with `coversFieldExposed: true/false` lacks
// a matching entry here.
//
// Authority anchors:
//   * docs/contracts/integration_spine_architecture_contract.md
//     "Canonical chain" — covers come from POS, never from
//     reservation systems.
//   * `lib/services/integration/integration_adapter_common.dart`
//     `VendorCapabilityProfile.coversFieldExposed`.
//   * Per-vendor field mapping docs cited in each adapter.

/// Per-POS-vendor covers-field exposure. Keys are the `vendor_id`
/// strings on `connector_connection.vendor_id` /
/// `connector_configs.source_type`. Mirrors
/// `VendorCapabilityProfile.coversFieldExposed` from each
/// `*_pos_adapter.dart`.
///
/// Citations (per-vendor field-mapping docs):
///   * `aloha`            -> true  (Aloha `numberOfGuests`;
///     docs/integrations/aloha_ncr_voyix/field_mapping.md)
///   * `clover`           -> false (no covers field on Clover orders)
///   * `lightspeed_lsk`   -> true  (`nbCovers` direct;
///     K-Series Restaurant API)
///   * `oracle_micros_simphony` -> true (POSAPI cover count)
///   * `revel`            -> true  (`order.number_of_people` direct)
///   * `square`           -> false (Square Orders has no
///     `number_of_guests` field; `covers_source = forecast_fallback`)
///   * `toast`            -> true  (Toast `numberOfGuests`;
///     docs/integrations/toast/field_mapping.md)
const Map<String, bool> kPosVendorCoversFieldExposed = <String, bool>{
  'aloha': true,
  'clover': false,
  'lightspeed_lsk': true,
  'oracle_micros_simphony': true,
  'revel': true,
  'square': false,
  'toast': true,
};

/// Resolve whether [posVendorId] is known to expose a covers field on
/// its canonical sales rows. Returns `null` when the vendor id is not
/// in the catalog — callers (the mobile Covers Setup section) should
/// treat null as "unknown" and surface the manual-entry primary-path
/// framing (safer fallback when the vendor cannot be classified).
bool? posVendorExposesCovers(String? posVendorId) {
  if (posVendorId == null) return null;
  return kPosVendorCoversFieldExposed[posVendorId];
}
