// Phase 11W.8 / Wave A3 — Operator Web Vendor Connections gateway
// resolver.
//
// Lifts vendor-connections gateway resolution out of the router so
// the router stays render-only and the wiring is testable in
// isolation. The resolver inspects the active
// [OperatorWebAuthSource]; when the source mixes in
// [OperatorWebVendorConnectionsGatewayProvider] and yields a
// non-null gateway, that live HTTP gateway is returned. Otherwise
// the resolver returns null and the host shell mounts the shared
// [VendorConnectionsWidget] without a gateway override — the widget
// then uses its built-in [InMemoryVendorConnectionsGateway] demo
// fallback so the walkthrough renders the same vendor catalog
// without a Cloud Run dependency.
//
// Reuses the existing live gateway under
// `lib/operator_web/services/operator_web_vendor_connections_gateway.dart`.
// No refactor of the shared widget tree happens here — that is C1's
// territory, sequenced after this slice.

import '../../integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import '../auth/operator_web_auth_source.dart';
import 'demo_vendor_connections_fixtures.dart';
import 'operator_web_vendor_connections_gateway.dart';

/// Resolves the [VendorConnectionsGateway] used by the operator-web
/// Vendor connections screen. The router calls
/// [OperatorWebVendorConnectionsResolver.resolve] with the active
/// auth source; the resolver returns the source-owned live gateway
/// when the source mixes in
/// [OperatorWebVendorConnectionsGatewayProvider], and null otherwise
/// so the shared widget falls back to its built-in demo catalog.
class OperatorWebVendorConnectionsResolver {
  const OperatorWebVendorConnectionsResolver();

  /// Returns the live HTTP gateway when [source] mixes in
  /// [OperatorWebVendorConnectionsGatewayProvider] and surfaces a
  /// non-null gateway; otherwise returns null. The host shell maps
  /// null to "demo mode" and lets the shared widget mount its
  /// internal [InMemoryVendorConnectionsGateway].
  VendorConnectionsGateway? resolve(OperatorWebAuthSource source) {
    if (source is OperatorWebVendorConnectionsGatewayProvider) {
      return (source as OperatorWebVendorConnectionsGatewayProvider)
          .vendorConnectionsGateway;
    }
    return null;
  }

  /// True when [source] surfaces a non-null live gateway. Tests pin
  /// the live-vs-demo branch off this flag without inspecting the
  /// returned instance type. The router uses it to decide whether
  /// the screen should wire optional host hooks like the OAuth
  /// redirect launcher (which has no meaning in demo mode).
  bool isLive(OperatorWebAuthSource source) => resolve(source) != null;

  /// Demo fallback the host shell mounts when [resolve] returns null
  /// (no live HTTP gateway — i.e. the demo / walkthrough build). Demo
  /// data Slice E: this now returns a SEEDED
  /// [InMemoryVendorConnectionsGateway] carrying the canonical mixed
  /// per-(operator, location, category) vendor state
  /// (`OperatorWebDemoVendorConnectionsFixture`, sourced from the same
  /// `DemoVendorIntegrationStateFixture` the mobile
  /// `demo_mode_state` surface reads) so the Vendor Connections screen
  /// renders meaningful state instead of an empty catalog (spec Gap
  /// G6). Each call returns a fresh instance. Still an
  /// [InMemoryVendorConnectionsGateway] — only the seed changed; no
  /// `kDemoMode` reader branch, no production behavior change (live
  /// builds resolve the HTTP gateway and never reach this path).
  VendorConnectionsGateway demoFallback() =>
      OperatorWebDemoVendorConnectionsFixture.gateway();
}
