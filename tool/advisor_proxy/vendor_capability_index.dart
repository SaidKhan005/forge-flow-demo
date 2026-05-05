// Phase 8 Wave B `8.spine-bridge.0.amendment` cross-category vendor
// capability index.
//
// Single source of truth for "which vendors are poll-only?" — Lane
// `8.spine-bridge.B`'s polling cadence picker reads
// [pollOnlyVendorIds] to decide which connections need a recurring
// poll tick versus an inbound webhook subscription.
//
// Derived live from the per-category capability mirrors in
// `pos_adapter_registry.dart`, `labor_adapter_registry.dart`, and
// `reservation_adapter_registry.dart`. Drift between the mirrors and
// the live adapter `capabilityProfile` is guarded by the per-registry
// drift test.
//
// V1 hardening alignment: per the lean-cut ledger, ADP carries
// `webhookSupport: VendorWebhookSupport.autoRegister` (architecture
// amendment captured during `8.spine-bridge.0` review). The cadence
// picker MUST treat ADP as auto-registered, NOT as poll-only.

import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import 'labor_adapter_registry.dart';
import 'pos_adapter_registry.dart';
import 'reservation_adapter_registry.dart';

/// Vendor ids whose [VendorCapabilityProfile.webhookSupport] is
/// [VendorWebhookSupport.pollOnly]. Lane `.B`'s cadence picker enrolls
/// every vendor in this list for the recurring poll loop; vendors NOT
/// in this list reach the canonical sink via inbound webhook +
/// adapter-side `handleWebhook`.
///
/// Computed live from the three per-category capability mirrors so a
/// future vendor flip (e.g., Humanity v2 ships a webhook surface) only
/// requires editing the registry mirror; the cadence picker picks up
/// the change automatically.
Iterable<String> get pollOnlyVendorIds sync* {
  for (final entry in kPosCapabilityProfiles.entries) {
    if (entry.value.webhookSupport == VendorWebhookSupport.pollOnly) {
      yield entry.key;
    }
  }
  for (final entry in kLaborCapabilityProfiles.entries) {
    if (entry.value.webhookSupport == VendorWebhookSupport.pollOnly) {
      yield entry.key;
    }
  }
  for (final entry in kReservationCapabilityProfiles.entries) {
    if (entry.value.webhookSupport == VendorWebhookSupport.pollOnly) {
      yield entry.key;
    }
  }
}

/// Capability profile for `vendorId` across every category, or `null`
/// when the vendor is not registered in any of the three category
/// registries. Convenience for callers that do not yet know the
/// `connector_connection.category` of the row they're inspecting.
VendorCapabilityProfile? lookupVendorCapability(String vendorId) {
  return kPosCapabilityProfiles[vendorId] ??
      kLaborCapabilityProfiles[vendorId] ??
      kReservationCapabilityProfiles[vendorId];
}
