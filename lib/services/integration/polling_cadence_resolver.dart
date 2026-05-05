// Phase 8 Wave B `8.spine-bridge.0a` polling cadence resolver.
//
// Pure-logic resolver: (vendor, operator, location) +
// ForgeFlowPollingTierAssignment + framework constants -> resolved
// cadence in seconds, clamped to vendor min/max, with tier-fallback
// presets when no per-vendor override is set.
//
// Authority:
//   * docs/contracts/data_accuracy_settings_contract.md "Polling
//     cadence — F&F-controlled tier model" (binding) — F&F controls
//     polling cadence per (operator, location) via tier assignment;
//     operators do NOT pick cadences. Operators see tier name + tier
//     price. Cadence comes from the tier-assignment row, NOT from a
//     `data_accuracy_settings` field.
//   * docs/contracts/integration_spine_architecture_contract.md
//     (sprint binding) — sub-lane `.0a` shape.
//   * docs/phases/phase_8/phase_8_spine_bridge_plan.md "F&F-controlled
//     polling cadence (REVERSED 2026-05-05)" — supersedes earlier
//     pass-through cost framing.
//
// What this lane does NOT do:
//   * Schema migration + repository for `forge_flow_polling_tier_assignment`
//     -> Lane `.A` (already landed: `lib/domain/models/
//     forge_flow_polling_tier_assignment.dart` + `lib/services/
//     data_accuracy/forge_flow_polling_tier_repository.dart`).
//   * Operator Web `/data-accuracy` polling card -> Lane `.B`.
//   * F&F Ops Console Polling & Pricing tab -> Lane `.C`.
//   * Sync worker scheduling cadence wiring (tick frequency) -> Lane
//     `.3`. The resolver is the source of truth that scheduling /
//     admin / cost-rollup surfaces consume.

import '../../domain/models/forge_flow_polling_tier_assignment.dart';
import 'polling_tier_presets.dart';

/// Pure-logic resolver returning the cadence in seconds for one
/// `(operator, location, vendor)` triple.
///
/// Resolution rules (binding per `data_accuracy_settings_contract.md`
/// "Polling cadence resolution" + the sprint plan "F&F controls
/// cadence" reversal):
///
/// 1. `tierAssignment == null`  -> emit `tier_assignment_missing`,
///    fall back to [kStandardTierPresets] for [vendorId]. If the
///    vendor is also absent from the standard presets, return the
///    vendor minimum.
/// 2. `pollingCadencePerVendorSeconds[vendorId]` present
///    -> clamp to `[vendorMinimumCadenceSeconds,
///       frameworkMaximumCadenceSeconds]`. Emit `cadence_clamped`
///       on a clamp; otherwise no log.
/// 3. `pollingCadencePerVendorSeconds[vendorId]` absent and
///    `tierKey == standard` or `premium` -> read from the matching
///    presets map. Vendor not in presets -> vendor minimum.
/// 4. `tierKey == custom` and vendor absent from JSONB -> emit
///    `custom_tier_vendor_unset`, return vendor minimum.
///
/// The [onSyncLog] callback is the resolver's only side-effect surface.
/// Production callers wire it to `CanonicalSink.appendSyncLog`; tests
/// pass an in-memory recorder.
class PollingCadenceResolver {
  const PollingCadenceResolver();

  /// Returns the resolved cadence in seconds. Never throws on policy
  /// inputs (missing assignment, out-of-bounds override); every
  /// degraded path emits a log row + falls back deterministically.
  static int resolve({
    required String vendorId,
    required ForgeFlowPollingTierAssignment? tierAssignment,
    required int vendorMinimumCadenceSeconds,
    required int frameworkMaximumCadenceSeconds,
    required void Function(String eventKind, Map<String, Object?> payload)
        onSyncLog,
  }) {
    // Rule 1: tier assignment missing.
    if (tierAssignment == null) {
      onSyncLog(_eventTierAssignmentMissing, <String, Object?>{
        'vendor_id': vendorId,
        'fallback_tier_key': PollingTierKey.standard.wire,
      });
      return _fromPresetOrVendorMin(
        kStandardTierPresets,
        vendorId,
        vendorMinimumCadenceSeconds,
      );
    }

    // Rule 2: per-vendor override present in the assignment's JSONB.
    final override = tierAssignment.pollingCadencePerVendorSeconds[vendorId];
    if (override != null) {
      return _clampOrLog(
        requestedSeconds: override,
        vendorMinimumCadenceSeconds: vendorMinimumCadenceSeconds,
        frameworkMaximumCadenceSeconds: frameworkMaximumCadenceSeconds,
        vendorId: vendorId,
        tierKey: tierAssignment.tierKey,
        onSyncLog: onSyncLog,
      );
    }

    // Rules 3 / 4: vendor absent from JSONB; choose by tier_key.
    switch (tierAssignment.tierKey) {
      case PollingTierKey.standard:
        return _fromPresetOrVendorMin(
          kStandardTierPresets,
          vendorId,
          vendorMinimumCadenceSeconds,
        );
      case PollingTierKey.premium:
        return _fromPresetOrVendorMin(
          kPremiumTierPresets,
          vendorId,
          vendorMinimumCadenceSeconds,
        );
      case PollingTierKey.custom:
        onSyncLog(_eventCustomTierVendorUnset, <String, Object?>{
          'vendor_id': vendorId,
          'fallback_seconds': vendorMinimumCadenceSeconds,
        });
        return vendorMinimumCadenceSeconds;
    }
  }

  static int _fromPresetOrVendorMin(
    Map<String, int> presets,
    String vendorId,
    int vendorMinimumCadenceSeconds,
  ) {
    final preset = presets[vendorId];
    if (preset == null) return vendorMinimumCadenceSeconds;
    // Presets are F&F-engineering-controlled and assumed valid by
    // construction, so they bypass the clamp-with-log path. A clamp
    // here would indicate a presets-table bug, not an operator action,
    // and the right place to catch that is in
    // `polling_tier_presets_test.dart` (test F).
    return preset;
  }

  static int _clampOrLog({
    required int requestedSeconds,
    required int vendorMinimumCadenceSeconds,
    required int frameworkMaximumCadenceSeconds,
    required String vendorId,
    required PollingTierKey tierKey,
    required void Function(String, Map<String, Object?>) onSyncLog,
  }) {
    if (requestedSeconds < vendorMinimumCadenceSeconds) {
      onSyncLog(_eventCadenceClamped, <String, Object?>{
        'vendor_id': vendorId,
        'tier_key': tierKey.wire,
        'requested_seconds': requestedSeconds,
        'clamped_seconds': vendorMinimumCadenceSeconds,
        'bound': 'vendor_minimum',
      });
      return vendorMinimumCadenceSeconds;
    }
    if (requestedSeconds > frameworkMaximumCadenceSeconds) {
      onSyncLog(_eventCadenceClamped, <String, Object?>{
        'vendor_id': vendorId,
        'tier_key': tierKey.wire,
        'requested_seconds': requestedSeconds,
        'clamped_seconds': frameworkMaximumCadenceSeconds,
        'bound': 'framework_maximum',
      });
      return frameworkMaximumCadenceSeconds;
    }
    return requestedSeconds;
  }
}

/// Sync-log `event_kind` constants the resolver emits. Stable strings
/// per `appendSyncLog` contract; consumed by the F&F Ops Console
/// observability surface (Lane `.C`) + per-tenant audit timeline.
const String _eventTierAssignmentMissing = 'tier_assignment_missing';
const String _eventCadenceClamped = 'cadence_clamped';
const String _eventCustomTierVendorUnset = 'custom_tier_vendor_unset';
