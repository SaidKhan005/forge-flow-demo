// Phase 8.0 — Vendor Connections gateway interface.
//
// The widget tree depends only on this gateway. Production wires the
// HTTP-backed gateway that talks to /v1/admin/integrations/* +
// /v1/admin/operators/:opid/locations/:locid/integrations. Demo mode
// + widget tests pass an in-memory gateway with seeded stub vendors.

import 'vendor_connections_models.dart';

abstract class VendorConnectionsGateway {
  /// Read the per-(operator, location) bundle. Hits
  /// `/v1/admin/operators/:operator_id/locations/:location_id/
  /// integrations`.
  Future<VendorConnectionsBundle> loadBundle({
    required String operatorId,
    required String locationId,
  });

  /// Vendor catalog for the picker dialog. Production reads the
  /// declared list from `vendor_capability_profile`; demo mode
  /// returns the three reference stubs (lightspeed_lsk, libro,
  /// quickbooks_time).
  Future<List<VendorPickerEntry>> listAvailableVendors({
    required VendorCategory category,
  });

  /// Begin a connect flow. For OAuth vendors, returns the redirect
  /// URL the operator's browser should follow. For key-paste vendors
  /// returns the URL of the key-paste form.
  Future<VendorConnectFlowStart> startConnect({
    required String operatorId,
    required String locationId,
    required String vendorId,
    String? module,
  });

  /// Heavy on-demand sample-pull diagnostic. Hits
  /// `/v1/admin/integrations/{vendor}/test-connection`.
  Future<VendorTestConnectionResult> testConnection({
    required String operatorId,
    required String locationId,
    required String vendorId,
  });

  /// Hits `/v1/admin/integrations/{vendor}/disconnect`.
  Future<void> disconnect({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String reason,
  });

  /// Hits `/v1/admin/integrations/{vendor}/logs`.
  Future<List<VendorSyncLogEntry>> loadLogs({
    required String operatorId,
    required String locationId,
    required String vendorId,
    int limit = 100,
  });

  /// Submit an api-key bundle for a key-paste vendor. Vendor-specific
  /// fields (some vendors require `apiSecret`, some accept a username
  /// or restaurant id surfaced through `apiSecret`) are passed through
  /// verbatim. The proxy validates the key with the vendor + persists
  /// the `connector_connection` + `vendor_credentials` rows + enqueues
  /// the first backfill, all in one round trip.
  ///
  /// Hits `POST /v1/integrations/api-key/{vendorId}/connect`.
  Future<VendorApiKeyConnectResult> connectWithApiKey({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String apiKey,
    String? apiSecret,
    String? module,
  });
}

class VendorConnectFlowStart {
  const VendorConnectFlowStart({required this.redirectUrl, required this.flowKind});

  final String redirectUrl;
  final VendorConnectFlowKind flowKind;
}

enum VendorConnectFlowKind { oauthRedirect, keyPasteForm }

/// Result of a successful key-paste connect. Mirrors the proxy's
/// `/v1/integrations/api-key/{vendor}/connect` 200 response, narrowed
/// to the fields the operator-facing widget cares about.
class VendorApiKeyConnectResult {
  const VendorApiKeyConnectResult({
    required this.connectionId,
    required this.connectedAt,
    required this.firstBackfillStarted,
  });

  final String connectionId;
  final DateTime connectedAt;
  final bool firstBackfillStarted;
}

/// Thrown by the gateway on operator-facing errors. The operator-
/// facing UX writing standard requires a remediation hint with each
/// error; the gateway provides it here.
class VendorConnectionsGatewayError implements Exception {
  VendorConnectionsGatewayError({
    required this.message,
    required this.remediation,
    this.statusCode,
  });

  final String message;
  final String remediation;
  final int? statusCode;

  @override
  String toString() => 'VendorConnectionsGatewayError($statusCode): $message';
}
