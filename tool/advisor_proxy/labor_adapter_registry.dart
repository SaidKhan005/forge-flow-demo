// Phase 8 Wave B `8.spine-bridge.0` labor adapter registry.
//
// Spine reference: docs/contracts/integration_spine_architecture_contract.md
// (binding) section "Sub-lane shape -> .0".
//
// Maps `connector_connection.vendor_id` to builder closure for each of
// the 6 Wave B labor / scheduling adapters. Pure data + closures: no
// I/O, no live HTTP, no operator-scoped database writes. Mirrors the
// design of `pos_adapter_registry.dart`; the per-vendor deps records
// mirror each adapter constructor 1:1.
//
// V1 hardening alignment: the lean-cut ledger of removed items is
// enforced by the per-file source grep in
// test/services/integration/canonical_sink_contract_test.dart; this
// file's executable code holds none of those tokens.

import 'package:forge_and_flow/integrations/labor/adp_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/agendrix_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/humanity_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/push_operations_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/quickbooks_time_labor_adapter.dart';
import 'package:forge_and_flow/integrations/labor/seven_shifts_labor_adapter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/labor_adapter.dart';

// ─── Builder + deps marker ──────────────────────────────────────────

/// Closure shape for a labor adapter builder.
typedef LaborAdapterBuilder = LaborAdapter Function(LaborAdapterDeps deps);

/// Marker base for per-vendor labor adapter deps records.
abstract class LaborAdapterDeps {
  const LaborAdapterDeps();

  String get vendorId;
}

// ─── Per-vendor deps records ────────────────────────────────────────

/// ADP labor adapter deps. Mirrors [AdpLaborAdapter] required ctor
/// params.
class AdpLaborAdapterDeps extends LaborAdapterDeps {
  const AdpLaborAdapterDeps({
    required this.transport,
    required this.gateway,
  });

  final AdpTransport transport;
  final AdpGateway gateway;

  @override
  String get vendorId => kAdpVendorId;
}

/// Agendrix labor adapter deps. Mirrors [AgendrixLaborAdapter]
/// required ctor params.
class AgendrixLaborAdapterDeps extends LaborAdapterDeps {
  const AgendrixLaborAdapterDeps({
    required this.apiClient,
    required this.canonicalSink,
  });

  final AgendrixApiClient apiClient;
  final AgendrixCanonicalSink canonicalSink;

  @override
  String get vendorId => agendrixVendorId;
}

/// Humanity labor adapter deps. Mirrors [HumanityLaborAdapter]
/// required ctor params.
class HumanityLaborAdapterDeps extends LaborAdapterDeps {
  const HumanityLaborAdapterDeps({
    required this.httpClient,
    required this.gateway,
  });

  final HumanityHttpClient httpClient;
  final HumanityGateway gateway;

  @override
  String get vendorId => kHumanityVendorId;
}

/// Push Operations labor adapter deps. Mirrors
/// [PushOperationsLaborAdapter] required ctor params.
class PushOperationsLaborAdapterDeps extends LaborAdapterDeps {
  const PushOperationsLaborAdapterDeps({
    required this.apiClient,
    required this.canonicalSink,
  });

  final PushOperationsApiClient apiClient;
  final PushOperationsCanonicalSink canonicalSink;

  @override
  String get vendorId => pushOperationsVendorId;
}

/// QuickBooks Time labor adapter deps. Mirrors
/// [QuickBooksTimeLaborAdapter] required ctor params.
class QuickBooksTimeLaborAdapterDeps extends LaborAdapterDeps {
  const QuickBooksTimeLaborAdapterDeps({
    required this.transport,
    required this.gateway,
  });

  final QuickBooksTimeTransport transport;
  final QuickBooksTimeGateway gateway;

  @override
  String get vendorId => kQuickBooksTimeVendorId;
}

/// 7shifts labor adapter deps. Mirrors [SevenShiftsLaborAdapter]
/// required ctor params.
class SevenShiftsLaborAdapterDeps extends LaborAdapterDeps {
  const SevenShiftsLaborAdapterDeps({
    required this.transport,
    required this.gateway,
  });

  final SevenShiftsTransport transport;
  final SevenShiftsGateway gateway;

  @override
  String get vendorId => kSevenShiftsVendorId;
}

// ─── Registry table ─────────────────────────────────────────────────

/// All 6 Wave B labor adapter builders, keyed by `vendor_id`.
final Map<String, LaborAdapterBuilder> kLaborAdapters =
    <String, LaborAdapterBuilder>{
  kAdpVendorId: (deps) {
    final d = deps as AdpLaborAdapterDeps;
    return AdpLaborAdapter(
      transport: d.transport,
      gateway: d.gateway,
    );
  },
  agendrixVendorId: (deps) {
    final d = deps as AgendrixLaborAdapterDeps;
    return AgendrixLaborAdapter(
      apiClient: d.apiClient,
      canonicalSink: d.canonicalSink,
    );
  },
  kHumanityVendorId: (deps) {
    final d = deps as HumanityLaborAdapterDeps;
    return HumanityLaborAdapter(
      httpClient: d.httpClient,
      gateway: d.gateway,
    );
  },
  pushOperationsVendorId: (deps) {
    final d = deps as PushOperationsLaborAdapterDeps;
    return PushOperationsLaborAdapter(
      apiClient: d.apiClient,
      canonicalSink: d.canonicalSink,
    );
  },
  kQuickBooksTimeVendorId: (deps) {
    final d = deps as QuickBooksTimeLaborAdapterDeps;
    return QuickBooksTimeLaborAdapter(
      transport: d.transport,
      gateway: d.gateway,
    );
  },
  kSevenShiftsVendorId: (deps) {
    final d = deps as SevenShiftsLaborAdapterDeps;
    return SevenShiftsLaborAdapter(
      transport: d.transport,
      gateway: d.gateway,
    );
  },
};

/// All labor vendor ids registered in [kLaborAdapters].
Iterable<String> get registeredLaborVendorIds => kLaborAdapters.keys;

/// Builds the labor adapter for `vendorId` using the supplied
/// per-vendor deps record. Returns `null` for unknown vendors. Throws
/// `ArgumentError` when `deps.vendorId != vendorId`.
LaborAdapter? lookupLaborAdapter(
  String vendorId, {
  required LaborAdapterDeps deps,
}) {
  final builder = kLaborAdapters[vendorId];
  if (builder == null) return null;
  if (deps.vendorId != vendorId) {
    throw ArgumentError.value(
      deps.vendorId,
      'deps.vendorId',
      'expected $vendorId; cannot build labor adapter with mismatched deps',
    );
  }
  return builder(deps);
}

// ─── Capability mirror ──────────────────────────────────────────────
//
// Capability profiles for each registered labor vendor, mirroring the
// `const VendorCapabilityProfile` declared inside each adapter's
// `capabilityProfile` getter body. Dart canonicalises identical const
// expressions to the same instance, so each entry below is the same
// runtime object as the value returned by the live adapter (the
// drift test in
// `test/tool/advisor_proxy/labor_adapter_registry_test.dart`
// enforces this).
//
// ADP carries `webhookSupport: VendorWebhookSupport.autoRegister` per
// the architecture amendment captured during `8.spine-bridge.0`
// review; the cadence picker MUST treat ADP as auto-registered, NOT
// as poll-only.
final Map<String, VendorCapabilityProfile> kLaborCapabilityProfiles =
    <String, VendorCapabilityProfile>{
  kAdpVendorId: const VendorCapabilityProfile(
    vendorId: kAdpVendorId,
    displayName: kAdpDisplayName,
    category: IntegrationCategory.labor,
    authMode: VendorAuthMode.oauth,
    grantScope: VendorGrantScope.operatorWide,
    webhookSupport: VendorWebhookSupport.autoRegister,
    coversFieldExposed: false,
    lifecycle: VendorLifecycle.documented,
    modules: <String>[
      kAdpModuleWorkforceNow,
      kAdpModuleWorkforceManager,
      kAdpModuleRun,
    ],
    timestampPolicyDocId: 'docs/integrations/adp/field_mapping.md',
  ),
  agendrixVendorId: const VendorCapabilityProfile(
    vendorId: agendrixVendorId,
    displayName: 'Agendrix',
    category: IntegrationCategory.labor,
    authMode: VendorAuthMode.oauth,
    grantScope: VendorGrantScope.operatorWide,
    webhookSupport: VendorWebhookSupport.pollOnly,
    coversFieldExposed: false,
    lifecycle: VendorLifecycle.documented,
    modules: <String>[],
    timestampPolicyDocId: 'agendrix.asUtc',
  ),
  kHumanityVendorId: const VendorCapabilityProfile(
    vendorId: kHumanityVendorId,
    displayName: kHumanityDisplayName,
    category: IntegrationCategory.labor,
    authMode: VendorAuthMode.keyPaste,
    grantScope: VendorGrantScope.operatorWide,
    webhookSupport: VendorWebhookSupport.pollOnly,
    coversFieldExposed: false,
    lifecycle: VendorLifecycle.documented,
    modules: <String>[],
    timestampPolicyDocId: 'docs/integrations/humanity/field_mapping.md',
  ),
  pushOperationsVendorId: const VendorCapabilityProfile(
    vendorId: pushOperationsVendorId,
    displayName: 'Push Operations',
    category: IntegrationCategory.labor,
    authMode: VendorAuthMode.keyPaste,
    grantScope: VendorGrantScope.operatorWide,
    webhookSupport: VendorWebhookSupport.pollOnly,
    coversFieldExposed: false,
    lifecycle: VendorLifecycle.documented,
    modules: <String>[],
    timestampPolicyDocId: 'push_operations.asUtc',
  ),
  kQuickBooksTimeVendorId: const VendorCapabilityProfile(
    vendorId: kQuickBooksTimeVendorId,
    displayName: kQuickBooksTimeDisplayName,
    category: IntegrationCategory.labor,
    authMode: VendorAuthMode.oauth,
    grantScope: VendorGrantScope.operatorWide,
    webhookSupport: VendorWebhookSupport.pollOnly,
    coversFieldExposed: false,
    lifecycle: VendorLifecycle.documented,
    modules: <String>[kQuickBooksModuleTime],
    timestampPolicyDocId: 'quickbooks_time.asUtc',
  ),
  kSevenShiftsVendorId: const VendorCapabilityProfile(
    vendorId: kSevenShiftsVendorId,
    displayName: kSevenShiftsDisplayName,
    category: IntegrationCategory.labor,
    authMode: VendorAuthMode.oauth,
    grantScope: VendorGrantScope.operatorWide,
    webhookSupport: VendorWebhookSupport.autoRegister,
    coversFieldExposed: false,
    lifecycle: VendorLifecycle.documented,
    modules: <String>[],
    timestampPolicyDocId: 'docs/integrations/seven_shifts/field_mapping.md',
  ),
};

/// Capability profile for `vendorId`, or `null` when the vendor is not
/// registered. Reads `coversFieldExposed` + `webhookSupport` per vendor
/// without needing per-vendor deps records.
///
/// Drift between this mirror and the adapter's runtime
/// `capabilityProfile` is guarded by
/// `test/tool/advisor_proxy/labor_adapter_registry_test.dart`.
VendorCapabilityProfile? lookupLaborCapability(String vendorId) {
  return kLaborCapabilityProfiles[vendorId];
}
