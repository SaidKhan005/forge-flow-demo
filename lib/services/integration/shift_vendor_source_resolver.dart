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
//
// PER-PERIOD GATE SCOPE (authority doc INVESTIGATION...
// §4.2 / §6.4): the per-period labor-connection suppression in
// `_ShiftSectionViewData.fromPeriod` applies ONLY to fixture-governed
// (demo) locations. The `ShiftVendorSource.fixtureGoverned` flag is
// `true` exclusively for locations resolved out of
// [DemoVendorIntegrationStateFixture]. For any unknown (production)
// location the resolver returns [ShiftVendorSource.none] with
// `fixtureGoverned == false`, so the per-period render falls back to
// the EXACT prior value-based gate the investigation §4.2 classifies
// as "correct" — byte-unchanged for real operators (no production
// rendering-semantics regression; §6.4 ESCALATE / do-not-regress).

import '../../dev/demo_vendor_integration_state_fixture.dart';
import 'integration_adapter_common.dart';

/// Immutable per-location Shift vendor-source provenance. Mirrors the
/// optional `posSourceVendorId` / `laborSourceVendorId` injection points
/// on `ShiftDashboardReadModel.buildWholeDay`.
class ShiftVendorSource {
  const ShiftVendorSource({
    this.posSourceVendorId,
    this.laborSourceVendorId,
    this.fixtureGoverned = false,
  });

  /// The connected POS vendor id (e.g. `'toast'`), or `null` when POS is
  /// disconnected / errored / unknown for this location.
  final String? posSourceVendorId;

  /// The connected labor vendor id (e.g. `'humanity'`), or `null` when
  /// Labor is disconnected / errored / unknown for this location.
  final String? laborSourceVendorId;

  /// True only when this provenance was resolved from the demo vendor
  /// fixture (a known demo location). The per-period labor-connection
  /// suppression in `_ShiftSectionViewData.fromPeriod` is applied ONLY
  /// when this is `true`; an unknown (production) location is NOT
  /// fixture-governed, so the per-period render keeps the prior
  /// value-based gate (authority doc §4.2 — no production regression).
  /// [none] MUST have `fixtureGoverned == false`.
  final bool fixtureGoverned;

  /// Neither category is connected — the honest "connect a vendor"
  /// state, and the resolution for any non-demo (production) location.
  /// Not fixture-governed (`fixtureGoverned == false`), so the
  /// per-period path falls back to the value-based gate.
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
      // Known demo location ⇒ the per-period labor-connection gate
      // applies here (and ONLY here).
      fixtureGoverned: true,
    );
  }
}
