// Phase 8 Wave B `8.spine-bridge.0` POS adapter registry.
//
// Spine reference: docs/contracts/integration_spine_architecture_contract.md
// (binding) section "Sub-lane shape -> .0".
//
// Maps `connector_connection.vendor_id` to builder closure for each of
// the 7 Wave B POS adapters. Pure data + closures: no I/O, no live
// HTTP, no operator-scoped database writes. Every closure receives a
// per-vendor deps record (one of the `Xxx*PosAdapterDeps` classes
// below) supplied by the caller (sync worker / proxy route handler /
// tests). The registry never hard-wires gateway / API client
// implementations; it stays category-uniform across vendors and
// lifecycle stages.
//
// V1 hardening alignment (memory/project_v1_lean_cut_2_2026_05_03.md):
// the lean-cut ledger of removed items is enforced by the per-file
// source grep in test/services/integration/canonical_sink_contract_test.dart;
// this file's executable code holds none of those tokens.

import 'package:forge_and_flow/integrations/pos/aloha_ncr_voyix_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/clover_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/lightspeed_lsk_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/oracle_micros_simphony_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/revel_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/square_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/toast_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/toast_webhook_signature_verifier.dart'
    show kToastVendorId;
import 'package:forge_and_flow/services/integration/iana_timezone_converter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/pos_adapter.dart';

// ─── Builder + deps marker ──────────────────────────────────────────

/// Closure shape for a POS adapter builder. Each registered builder
/// expects a concrete `Xxx*PosAdapterDeps` instance and casts it
/// internally; passing the wrong deps type for a given `vendorId`
/// throws `ArgumentError`.
typedef PosAdapterBuilder = PosAdapter Function(PosAdapterDeps deps);

/// Marker base for per-vendor POS adapter deps records. Each vendor
/// declares its own subtype that mirrors the adapter constructor
/// parameter set 1:1.
abstract class PosAdapterDeps {
  const PosAdapterDeps();

  /// Stable vendor identifier this deps record was constructed for.
  /// Registry [lookupPosAdapter] cross-checks this against the
  /// `vendorId` argument so a caller cannot accidentally hand
  /// `LightspeedLskPosAdapterDeps` to the `'square'` lookup.
  String get vendorId;
}

// ─── Per-vendor deps records ────────────────────────────────────────

/// Aloha NCR Voyix POS adapter deps. Mirrors
/// [AlohaNcrVoyixPosAdapter] required ctor params.
class AlohaNcrVoyixPosAdapterDeps extends PosAdapterDeps {
  const AlohaNcrVoyixPosAdapterDeps({
    required this.transport,
    required this.factSink,
  });

  final AlohaNcrVoyixApiClient transport;
  final AlohaNcrVoyixFactSink factSink;

  @override
  String get vendorId => kAlohaNcrVoyixVendorId;
}

/// Clover POS adapter deps. Mirrors [CloverPosAdapter] required ctor
/// params.
class CloverPosAdapterDeps extends PosAdapterDeps {
  const CloverPosAdapterDeps({
    required this.api,
    required this.factWriter,
    required this.watermarkStore,
    required this.webhookRegistry,
    required this.credentials,
  });

  final CloverApiClient api;
  final CloverTenantFactWriter factWriter;
  final CloverWatermarkStore watermarkStore;
  final CloverWebhookRegistry webhookRegistry;
  final CloverCredentialStore credentials;

  @override
  String get vendorId => 'clover';
}

/// Lightspeed Restaurant K-Series POS adapter deps. Mirrors
/// [LightspeedLskPosAdapter] required ctor params.
class LightspeedLskPosAdapterDeps extends PosAdapterDeps {
  const LightspeedLskPosAdapterDeps({
    required this.gateway,
    required this.oauthClient,
    required this.webhookClient,
    required this.ordersClient,
    required this.restaurantTimezone,
    required this.businessDayRolloverHour,
    required this.webhookUrl,
    this.converter,
  });

  final LightspeedLskGateway gateway;
  final LightspeedLskOAuthClient oauthClient;
  final LightspeedLskWebhookClient webhookClient;
  final LightspeedLskOrdersClient ordersClient;
  final String restaurantTimezone;
  final int businessDayRolloverHour;
  final String webhookUrl;
  final IanaTimezoneConverter? converter;

  @override
  String get vendorId => kLightspeedLskVendorId;
}

/// Oracle MICROS Simphony POS adapter deps. Mirrors
/// [OracleMicrosSimphonyPosAdapter] required ctor params.
class OracleMicrosSimphonyPosAdapterDeps extends PosAdapterDeps {
  const OracleMicrosSimphonyPosAdapterDeps({
    required this.apiClient,
    required this.canonicalSink,
  });

  final OracleMicrosSimphonyApiClient apiClient;
  final OracleMicrosSimphonyCanonicalSink canonicalSink;

  @override
  String get vendorId => oracleMicrosSimphonyVendorId;
}

/// Revel POS adapter deps. Mirrors [RevelPosAdapter] required ctor
/// params.
class RevelPosAdapterDeps extends PosAdapterDeps {
  const RevelPosAdapterDeps({
    required this.transport,
    required this.gateway,
  });

  final RevelTransport transport;
  final RevelGateway gateway;

  @override
  String get vendorId => kRevelVendorId;
}

/// Square POS adapter deps. Mirrors [SquarePosAdapter] required ctor
/// params.
class SquarePosAdapterDeps extends PosAdapterDeps {
  const SquarePosAdapterDeps({
    required this.apiClient,
    required this.factWriter,
    required this.watermarkStore,
    required this.notificationUrlForConnection,
  });

  final SquareApiClient apiClient;
  final SquarePosFactWriter factWriter;
  final SquareWatermarkStore watermarkStore;
  final Future<String> Function({
    required String operatorId,
    required String locationId,
  }) notificationUrlForConnection;

  @override
  String get vendorId => kSquareVendorId;
}

/// Toast POS adapter deps. Mirrors [ToastPosAdapter] required ctor
/// params.
class ToastPosAdapterDeps extends PosAdapterDeps {
  const ToastPosAdapterDeps({
    required this.transport,
    required this.factSink,
  });

  final ToastApiClient transport;
  final ToastFactSink factSink;

  @override
  String get vendorId => kToastVendorId;
}

// ─── Registry table ─────────────────────────────────────────────────

/// All 7 Wave B POS adapter builders, keyed by `vendor_id`.
///
/// Closure body casts the deps record to the per-vendor subtype and
/// invokes the adapter constructor. Caller is responsible for handing
/// in the right deps subtype; mismatches throw `ArgumentError` from
/// [lookupPosAdapter] before reaching the closure.
final Map<String, PosAdapterBuilder> kPosAdapters = <String, PosAdapterBuilder>{
  kAlohaNcrVoyixVendorId: (deps) {
    final d = deps as AlohaNcrVoyixPosAdapterDeps;
    return AlohaNcrVoyixPosAdapter(
      transport: d.transport,
      factSink: d.factSink,
    );
  },
  'clover': (deps) {
    final d = deps as CloverPosAdapterDeps;
    return CloverPosAdapter(
      api: d.api,
      factWriter: d.factWriter,
      watermarkStore: d.watermarkStore,
      webhookRegistry: d.webhookRegistry,
      credentials: d.credentials,
    );
  },
  kLightspeedLskVendorId: (deps) {
    final d = deps as LightspeedLskPosAdapterDeps;
    return LightspeedLskPosAdapter(
      gateway: d.gateway,
      oauthClient: d.oauthClient,
      webhookClient: d.webhookClient,
      ordersClient: d.ordersClient,
      restaurantTimezone: d.restaurantTimezone,
      businessDayRolloverHour: d.businessDayRolloverHour,
      webhookUrl: d.webhookUrl,
      converter: d.converter,
    );
  },
  oracleMicrosSimphonyVendorId: (deps) {
    final d = deps as OracleMicrosSimphonyPosAdapterDeps;
    return OracleMicrosSimphonyPosAdapter(
      apiClient: d.apiClient,
      canonicalSink: d.canonicalSink,
    );
  },
  kRevelVendorId: (deps) {
    final d = deps as RevelPosAdapterDeps;
    return RevelPosAdapter(
      transport: d.transport,
      gateway: d.gateway,
    );
  },
  kSquareVendorId: (deps) {
    final d = deps as SquarePosAdapterDeps;
    return SquarePosAdapter(
      apiClient: d.apiClient,
      factWriter: d.factWriter,
      watermarkStore: d.watermarkStore,
      notificationUrlForConnection: d.notificationUrlForConnection,
    );
  },
  kToastVendorId: (deps) {
    final d = deps as ToastPosAdapterDeps;
    return ToastPosAdapter(
      transport: d.transport,
      factSink: d.factSink,
    );
  },
};

/// All POS vendor ids registered in [kPosAdapters].
Iterable<String> get registeredPosVendorIds => kPosAdapters.keys;

/// Builds the POS adapter for `vendorId` using the supplied per-vendor
/// deps record. Returns `null` when no adapter is registered for the
/// given vendor (caller maps to operator-facing 404). Throws
/// `ArgumentError` when `deps.vendorId != vendorId` so a caller cannot
/// accidentally hand the wrong deps record.
PosAdapter? lookupPosAdapter(
  String vendorId, {
  required PosAdapterDeps deps,
}) {
  final builder = kPosAdapters[vendorId];
  if (builder == null) return null;
  if (deps.vendorId != vendorId) {
    throw ArgumentError.value(
      deps.vendorId,
      'deps.vendorId',
      'expected $vendorId; cannot build POS adapter with mismatched deps',
    );
  }
  return builder(deps);
}

// ─── Capability mirror ──────────────────────────────────────────────
//
// Capability profiles for each registered POS vendor, mirroring the
// `const VendorCapabilityProfile` declared inside each adapter's
// `capabilityProfile` getter body. Dart canonicalises identical const
// expressions to the same instance, so each entry below is the same
// runtime object as the value returned by the live adapter (the
// drift test in
// `test/tool/advisor_proxy/pos_adapter_registry_test.dart` enforces
// this).
//
// Why mirror at all: Lanes `8.spine-bridge.B` (cadence picker) and
// `.C` (covers source classifier) need to read `webhookSupport` +
// `coversFieldExposed` per vendor at planner time, BEFORE any
// per-vendor deps record is materialised. Going through
// [lookupPosAdapter] would require fully wired deps; mirroring
// the const profiles here is additive and deps-free.
final Map<String, VendorCapabilityProfile> kPosCapabilityProfiles =
    <String, VendorCapabilityProfile>{
  kAlohaNcrVoyixVendorId: const VendorCapabilityProfile(
    vendorId: kAlohaNcrVoyixVendorId,
    displayName: kAlohaNcrVoyixDisplayName,
    category: IntegrationCategory.pos,
    authMode: VendorAuthMode.oauth,
    grantScope: VendorGrantScope.perLocation,
    webhookSupport: VendorWebhookSupport.autoRegister,
    coversFieldExposed: true,
    lifecycle: VendorLifecycle.documented,
    modules: <String>[],
    timestampPolicyDocId: 'aloha_ncr_voyix',
  ),
  'clover': const VendorCapabilityProfile(
    vendorId: 'clover',
    displayName: 'Clover',
    category: IntegrationCategory.pos,
    authMode: VendorAuthMode.oauth,
    grantScope: VendorGrantScope.perLocation,
    webhookSupport: VendorWebhookSupport.autoRegister,
    coversFieldExposed: false,
    lifecycle: VendorLifecycle.documented,
    timestampPolicyDocId: 'vendor_timestamp_policy.clover.asUtc',
  ),
  kLightspeedLskVendorId: const VendorCapabilityProfile(
    vendorId: kLightspeedLskVendorId,
    displayName: kLightspeedLskDisplayName,
    category: IntegrationCategory.pos,
    authMode: VendorAuthMode.oauth,
    grantScope: VendorGrantScope.perLocation,
    webhookSupport: VendorWebhookSupport.autoRegister,
    coversFieldExposed: true,
    lifecycle: VendorLifecycle.documented,
    modules: <String>[],
    timestampPolicyDocId: 'vendor_timestamp_policy.lightspeed_lsk',
  ),
  oracleMicrosSimphonyVendorId: const VendorCapabilityProfile(
    vendorId: oracleMicrosSimphonyVendorId,
    displayName: 'Oracle MICROS Simphony',
    category: IntegrationCategory.pos,
    authMode: VendorAuthMode.oauth,
    grantScope: VendorGrantScope.perLocation,
    webhookSupport: VendorWebhookSupport.pollOnly,
    coversFieldExposed: true,
    lifecycle: VendorLifecycle.documented,
    modules: <String>[],
    timestampPolicyDocId: 'oracle_micros_simphony.asUtc',
  ),
  kRevelVendorId: const VendorCapabilityProfile(
    vendorId: kRevelVendorId,
    displayName: kRevelDisplayName,
    category: IntegrationCategory.pos,
    authMode: VendorAuthMode.oauth,
    grantScope: VendorGrantScope.perLocation,
    webhookSupport: VendorWebhookSupport.autoRegister,
    coversFieldExposed: true,
    lifecycle: VendorLifecycle.documented,
    modules: <String>[],
    timestampPolicyDocId: 'docs/integrations/revel/field_mapping.md',
  ),
  kSquareVendorId: const VendorCapabilityProfile(
    vendorId: kSquareVendorId,
    displayName: kSquareDisplayName,
    category: IntegrationCategory.pos,
    authMode: VendorAuthMode.oauth,
    grantScope: VendorGrantScope.operatorWide,
    webhookSupport: VendorWebhookSupport.autoRegister,
    coversFieldExposed: false,
    lifecycle: VendorLifecycle.documented,
    modules: <String>[],
    timestampPolicyDocId: 'square.created_at_utc_iso8601_with_z',
  ),
  kToastVendorId: const VendorCapabilityProfile(
    vendorId: kToastVendorId,
    displayName: 'Toast',
    category: IntegrationCategory.pos,
    authMode: VendorAuthMode.oauth,
    grantScope: VendorGrantScope.perLocation,
    webhookSupport: VendorWebhookSupport.autoRegister,
    coversFieldExposed: true,
    lifecycle: VendorLifecycle.documented,
    modules: <String>[],
    timestampPolicyDocId: 'toast',
  ),
};

/// Capability profile for `vendorId`, or `null` when the vendor is not
/// registered. Reads `coversFieldExposed` + `webhookSupport` per vendor
/// without needing per-vendor deps records.
///
/// Drift between this mirror and the adapter's runtime
/// `capabilityProfile` is guarded by
/// `test/tool/advisor_proxy/pos_adapter_registry_test.dart`.
VendorCapabilityProfile? lookupPosCapability(String vendorId) {
  return kPosCapabilityProfiles[vendorId];
}
