// Demo-data Slice E (part 1) — operator-web Vendor Connections demo
// fixture. Authority: docs/_audits/per_daypart_v1/full_demo_data_spec.md
// §1.7 (line 93), §2f/§2g (lines 167-175), Gap G6 (line 188).
//
// Builds the seeded `InMemoryVendorConnectionsGateway` the operator-web
// Vendor Connections screen falls back to in demo / no-live-gateway
// builds (resolver `demoFallback()`), so the screen renders mixed
// per-(operator, location, category) vendor state instead of an empty
// catalog (spec Gap G6).
//
// SINGLE SOURCE OF TRUTH: the per-(location, category) logical state
// and the `VendorConnectionsBundle`s come from
// `DemoVendorIntegrationStateFixture` (`lib/dev/`), the SAME fixture
// the mobile `DemoModeStateGateway` demo impl uses. This guarantees
// the operator-web `demoFlags` and the mobile `demo_mode_state`
// `is_demo` agree by construction — "same logical state both surfaces"
// (prompt requirement; spec §2f). A consistency test pins it.
//
// LAYERING NOTE: this is a `demo_*` gateway-fixture file, the demo
// fallback path blessed by `docs/contracts/demo_mode_contract.md`
// "Acceptable patterns" ("Demo gateway impls under
// lib/operator_web/services/demo_*"). It intentionally reuses the
// canonical demo fixture rather than duplicating the state table; the
// alternative (a second copy of the 4×3 table) is a drift hazard that
// would let the two consoles disagree. No `kDemoMode` reader branch,
// no new `demo_*` table.

import '../../dev/demo_vendor_integration_state_fixture.dart';
import '../../integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
import 'demo_team_fixtures.dart';

/// Demo Vendor Connections fixture for the operator-web console.
class OperatorWebDemoVendorConnectionsFixture {
  const OperatorWebDemoVendorConnectionsFixture._();

  /// Human labels keyed by operator-web `demo-loc-*` id, sourced from
  /// the same `kDemoTeamLocationsFixture` the hierarchy / scope drawer
  /// renders so the card header reads the operator's location name.
  static Map<String, String> get _locationNamesById => <String, String>{
        for (final loc in kDemoTeamLocationsFixture) loc.locationId: loc.name,
      };

  /// The seed map for `InMemoryVendorConnectionsGateway`, keyed
  /// `operatorId/locationId`, covering all four demo locations with
  /// the canonical mixed states (Downtown connected+error, North Loop
  /// partial, Riverside already-live, Harbour clean demo).
  static Map<String, VendorConnectionsBundle> seed({
    String operatorId = kDemoOperatorIdFixture,
  }) =>
      DemoVendorIntegrationStateFixture.vendorConnectionsSeed(
        operatorId: operatorId,
        locationNamesById: _locationNamesById,
      );

  /// A fresh seeded gateway for the resolver `demoFallback()` so the
  /// operator-web screen renders meaningful state without a Cloud Run
  /// dependency.
  static InMemoryVendorConnectionsGateway gateway({
    String operatorId = kDemoOperatorIdFixture,
  }) =>
      InMemoryVendorConnectionsGateway(seed: seed(operatorId: operatorId));
}
