// Per-location Shift vendor-source provenance resolver.
//
// WHY THIS EXISTS
// The whole-day Shift read model and the per-period (Variance) path
// gate labor metrics on whether a labor vendor is connected, but the
// two production `buildWholeDay(...)` callers never passed
// `posSourceVendorId` / `laborSourceVendorId`, so the EXISTING gate
// always saw `null` and every demo location showed "Connect a labor
// vendor" — even the ones whose fixture says Labor IS connected
// (Investigation: docs/_audits/per_daypart_v1/
// INVESTIGATION_labor_reservation_not_connected.md §2).
//
// HP #2 (CLAUDE.md → Demo Mode): this is NOT a `kDemoMode` reader fork
// and NOT a parallel connection signal. It resolves off the SAME
// per-(operator, location, category) [DemoVendorIntegrationStateFixture]
// the `DemoModeBanner` / `DemoModeStateNotifier` are already derived
// from (via `demoModeRecords`). One source of truth, consulted
// synchronously by the read-model callers that only have a
// `restaurantId` in scope. A real production location is unknown to the
// fixture, so it resolves to [ShiftVendorSource.none] — preserving the
// existing honest "connect a vendor" behavior with no production
// regression (no value-based gate collapse, no formula change).

import '../../dev/demo_vendor_integration_state_fixture.dart';
import 'integration_adapter_common.dart';

/// Immutable per-location Shift vendor-source provenance. Mirrors the
/// optional `posSourceVendorId` / `laborSourceVendorId` injection points
/// on `ShiftDashboardReadModel.buildWholeDay`.
class ShiftVendorSource {
  const ShiftVendorSource({
    this.posSourceVendorId,
    this.laborSourceVendorId,
  });

  /// The connected POS vendor id (e.g. `'toast'`), or `null` when POS is
  /// disconnected / errored / unknown for this location.
  final String? posSourceVendorId;

  /// The connected labor vendor id (e.g. `'humanity'`), or `null` when
  /// Labor is disconnected / errored / unknown for this location.
  final String? laborSourceVendorId;

  /// Neither category is connected — the honest "connect a vendor"
  /// state, and the resolution for any non-demo (production) location.
  static const ShiftVendorSource none = ShiftVendorSource();

  bool get posConnected => posSourceVendorId != null;
  bool get laborConnected => laborSourceVendorId != null;
}

/// Resolves [ShiftVendorSource] for an active `restaurantId` from the
/// canonical demo vendor fixture. Pure + deterministic (no I/O, no
/// `DateTime.now()`), so the same `restaurantId` always resolves to the
/// same provenance — the acceptance tests pin this per location.
class ShiftVendorSourceResolver {
  const ShiftVendorSourceResolver._();

  static ShiftVendorSource forLocation(String restaurantId) {
    // Unknown to the fixture ⇒ a real production location. Keep the
    // current honest-degrade (both ids null) — never invent a connected
    // vendor for production, never branch on `kDemoMode`.
    if (!DemoVendorIntegrationStateFixture.knowsLocation(restaurantId)) {
      return ShiftVendorSource.none;
    }
    final pos = DemoVendorIntegrationStateFixture.stateFor(
      locationId: restaurantId,
      category: IntegrationCategory.pos,
    );
    final labor = DemoVendorIntegrationStateFixture.stateFor(
      locationId: restaurantId,
      category: IntegrationCategory.labor,
    );
    return ShiftVendorSource(
      posSourceVendorId: pos.connectionStatus == ConnectionStatus.connected
          ? pos.vendorId
          : null,
      laborSourceVendorId: labor.connectionStatus == ConnectionStatus.connected
          ? labor.vendorId
          : null,
    );
  }
}
