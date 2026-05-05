// Phase 8 Wave B `8.spine-bridge.0` reservation adapter registry.
//
// Spine reference: docs/contracts/integration_spine_architecture_contract.md
// (binding) section "Sub-lane shape -> .0".
//
// Maps `connector_connection.vendor_id` to builder closure for each of
// the 4 Wave B reservation adapters. Pure data + closures: no I/O, no
// live HTTP, no operator-scoped database writes. Mirrors the design of
// `pos_adapter_registry.dart` and `labor_adapter_registry.dart`.
//
// V1 hardening alignment: the lean-cut ledger of removed items is
// enforced by the per-file source grep in
// test/services/integration/canonical_sink_contract_test.dart; this
// file's executable code holds none of those tokens.

import 'package:forge_and_flow/integrations/reservation/libro_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/opentable_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/sevenrooms_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/tock_reservation_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/tock_webhook_signature_verifier.dart'
    show kTockVendorId;
import 'package:forge_and_flow/services/integration/iana_timezone_converter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/reservation_adapter.dart';

// ─── Builder + deps marker ──────────────────────────────────────────

/// Closure shape for a reservation adapter builder.
typedef ReservationAdapterBuilder =
    ReservationAdapter Function(ReservationAdapterDeps deps);

/// Marker base for per-vendor reservation adapter deps records.
abstract class ReservationAdapterDeps {
  const ReservationAdapterDeps();

  String get vendorId;
}

// ─── Per-vendor deps records ────────────────────────────────────────

/// Libro Reserve adapter deps. Mirrors [LibroReservationAdapter]
/// required ctor params.
class LibroReservationAdapterDeps extends ReservationAdapterDeps {
  const LibroReservationAdapterDeps({
    required this.gateway,
    required this.httpClient,
    required this.timezoneConverter,
  });

  final LibroReservationGateway gateway;
  final LibroHttpClient httpClient;
  final LibroTimezoneConverter timezoneConverter;

  @override
  String get vendorId => kLibroVendorId;
}

/// OpenTable adapter deps. Mirrors [OpenTableReservationAdapter]
/// required ctor params.
class OpenTableReservationAdapterDeps extends ReservationAdapterDeps {
  const OpenTableReservationAdapterDeps({
    required this.transport,
    required this.gateway,
  });

  final OpenTableTransport transport;
  final OpenTableGateway gateway;

  @override
  String get vendorId => kOpenTableVendorId;
}

/// SevenRooms adapter deps. Mirrors [SevenRoomsReservationAdapter]
/// required ctor params.
class SevenRoomsReservationAdapterDeps extends ReservationAdapterDeps {
  const SevenRoomsReservationAdapterDeps({
    required this.gateway,
    required this.authClient,
    required this.webhookClient,
    required this.reservationsClient,
    required this.restaurantTimezone,
    required this.businessDayRolloverHour,
    required this.webhookUrl,
    this.converter,
  });

  final SevenRoomsReservationGateway gateway;
  final SevenRoomsAuthClient authClient;
  final SevenRoomsWebhookClient webhookClient;
  final SevenRoomsReservationsClient reservationsClient;
  final String restaurantTimezone;
  final int businessDayRolloverHour;
  final String webhookUrl;
  final IanaTimezoneConverter? converter;

  @override
  String get vendorId => kSevenRoomsVendorId;
}

/// Tock adapter deps. Mirrors [TockReservationAdapter] required ctor
/// params.
class TockReservationAdapterDeps extends ReservationAdapterDeps {
  const TockReservationAdapterDeps({
    required this.transport,
    required this.factSink,
  });

  final TockApiClient transport;
  final TockFactSink factSink;

  @override
  String get vendorId => kTockVendorId;
}

// ─── Registry table ─────────────────────────────────────────────────

/// All 4 Wave B reservation adapter builders, keyed by `vendor_id`.
final Map<String, ReservationAdapterBuilder> kReservationAdapters =
    <String, ReservationAdapterBuilder>{
  kLibroVendorId: (deps) {
    final d = deps as LibroReservationAdapterDeps;
    return LibroReservationAdapter(
      gateway: d.gateway,
      httpClient: d.httpClient,
      timezoneConverter: d.timezoneConverter,
    );
  },
  kOpenTableVendorId: (deps) {
    final d = deps as OpenTableReservationAdapterDeps;
    return OpenTableReservationAdapter(
      transport: d.transport,
      gateway: d.gateway,
    );
  },
  kSevenRoomsVendorId: (deps) {
    final d = deps as SevenRoomsReservationAdapterDeps;
    return SevenRoomsReservationAdapter(
      gateway: d.gateway,
      authClient: d.authClient,
      webhookClient: d.webhookClient,
      reservationsClient: d.reservationsClient,
      restaurantTimezone: d.restaurantTimezone,
      businessDayRolloverHour: d.businessDayRolloverHour,
      webhookUrl: d.webhookUrl,
      converter: d.converter,
    );
  },
  kTockVendorId: (deps) {
    final d = deps as TockReservationAdapterDeps;
    return TockReservationAdapter(
      transport: d.transport,
      factSink: d.factSink,
    );
  },
};

/// All reservation vendor ids registered in [kReservationAdapters].
Iterable<String> get registeredReservationVendorIds =>
    kReservationAdapters.keys;

/// Builds the reservation adapter for `vendorId` using the supplied
/// per-vendor deps record. Returns `null` for unknown vendors. Throws
/// `ArgumentError` when `deps.vendorId != vendorId`.
ReservationAdapter? lookupReservationAdapter(
  String vendorId, {
  required ReservationAdapterDeps deps,
}) {
  final builder = kReservationAdapters[vendorId];
  if (builder == null) return null;
  if (deps.vendorId != vendorId) {
    throw ArgumentError.value(
      deps.vendorId,
      'deps.vendorId',
      'expected $vendorId; cannot build reservation adapter with mismatched deps',
    );
  }
  return builder(deps);
}

// ─── Capability mirror ──────────────────────────────────────────────
//
// Capability profiles for each registered reservation vendor,
// mirroring the `const VendorCapabilityProfile` declared inside each
// adapter's `capabilityProfile` getter body. Dart canonicalises
// identical const expressions to the same instance, so each entry
// below is the same runtime object as the value returned by the live
// adapter (the drift test in
// `test/tool/advisor_proxy/reservation_adapter_registry_test.dart`
// enforces this).
final Map<String, VendorCapabilityProfile> kReservationCapabilityProfiles =
    <String, VendorCapabilityProfile>{
  kLibroVendorId: const VendorCapabilityProfile(
    vendorId: kLibroVendorId,
    displayName: 'Libro Reserve',
    category: IntegrationCategory.reservation,
    authMode: VendorAuthMode.oauth,
    grantScope: VendorGrantScope.perLocation,
    webhookSupport: VendorWebhookSupport.autoRegister,
    coversFieldExposed: false,
    lifecycle: kLibroLifecycleAtShip,
    timestampPolicyDocId: kLibroTimestampPolicyDocId,
  ),
  kOpenTableVendorId: const VendorCapabilityProfile(
    vendorId: kOpenTableVendorId,
    displayName: kOpenTableDisplayName,
    category: IntegrationCategory.reservation,
    authMode: VendorAuthMode.oauth,
    grantScope: VendorGrantScope.perLocation,
    webhookSupport: VendorWebhookSupport.autoRegister,
    coversFieldExposed: false,
    lifecycle: VendorLifecycle.documented,
    modules: <String>[],
    timestampPolicyDocId: 'docs/integrations/opentable/field_mapping.md',
  ),
  kSevenRoomsVendorId: const VendorCapabilityProfile(
    vendorId: kSevenRoomsVendorId,
    displayName: kSevenRoomsDisplayName,
    category: IntegrationCategory.reservation,
    authMode: VendorAuthMode.oauthOrKeyPaste,
    grantScope: VendorGrantScope.perLocation,
    webhookSupport: VendorWebhookSupport.manualPaste,
    coversFieldExposed: false,
    lifecycle: VendorLifecycle.documented,
    modules: <String>[],
    timestampPolicyDocId: 'vendor_timestamp_policy.sevenrooms',
  ),
  kTockVendorId: const VendorCapabilityProfile(
    vendorId: kTockVendorId,
    displayName: kTockDisplayName,
    category: IntegrationCategory.reservation,
    authMode: VendorAuthMode.keyPaste,
    grantScope: VendorGrantScope.perLocation,
    webhookSupport: VendorWebhookSupport.manualPaste,
    coversFieldExposed: false,
    lifecycle: VendorLifecycle.documented,
    modules: <String>[],
    timestampPolicyDocId: 'tock',
  ),
};

/// Capability profile for `vendorId`, or `null` when the vendor is not
/// registered. Reads `coversFieldExposed` + `webhookSupport` per vendor
/// without needing per-vendor deps records.
///
/// Drift between this mirror and the adapter's runtime
/// `capabilityProfile` is guarded by
/// `test/tool/advisor_proxy/reservation_adapter_registry_test.dart`.
VendorCapabilityProfile? lookupReservationCapability(String vendorId) {
  return kReservationCapabilityProfiles[vendorId];
}
