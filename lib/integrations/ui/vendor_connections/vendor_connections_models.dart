// Phase 8.0 — Vendor Connections widget tree models.
//
// Pure data classes consumed by the dual-surface widget tree under
// `lib/integrations/ui/vendor_connections/`. Same models render in
// both:
//
//   * F&F Operations Console (Phase 11A) — `lib/admin/screens/...`
//   * Operator Web Console (Phase 11W) — `lib/operator_web/screens/...`
//
// The models intentionally include only the fields the operator-
// facing surface needs. Server-side rotation knobs live in the
// gateway / proxy and never reach this layer.

import '../../../services/integration/integration_adapter_common.dart'
    show VendorLifecycle;

export '../../../services/integration/integration_adapter_common.dart'
    show VendorLifecycle;

/// Stable category identifier matching `connector_connection.category`.
enum VendorCategory { pos, labor, reservation }

/// 3-state machine V1 cut. UI displays a fourth "demo" pseudo-state
/// when [VendorConnectionRow] is null AND `demo_mode_state.is_demo`
/// is true.
enum VendorConnectionStatus { connected, disconnected, error }

/// One vendor card row.
class VendorConnectionRow {
  const VendorConnectionRow({
    required this.connectionId,
    required this.vendorId,
    required this.displayName,
    required this.category,
    required this.status,
    required this.metadata,
    this.module,
    this.lastSyncAt,
    this.lastErrorMessage,
    this.disconnectReason,
    this.webhookUrl,
    this.recordsLast24h,
    this.errorsLast24h,
  });

  final String connectionId;
  final String vendorId;
  final String displayName;
  final VendorCategory category;
  final VendorConnectionStatus status;
  final Map<String, Object?> metadata;
  final String? module;
  final DateTime? lastSyncAt;
  final String? lastErrorMessage;
  final String? disconnectReason;
  final String? webhookUrl;
  final int? recordsLast24h;
  final int? errorsLast24h;
}

/// One vendor entry in the picker dialog. The picker renders ALL
/// vendors regardless of [lifecycle]; chrome and Connect-button
/// activation flow from the lifecycle stage per
/// `docs/phases/phase_8/vendor_connections_admin_surface.md`.
class VendorPickerEntry {
  const VendorPickerEntry({
    required this.vendorId,
    required this.displayName,
    required this.category,
    required this.authMode,
    required this.lifecycle,
    required this.coversFieldExposed,
    required this.requiresModule,
    this.modules = const <String>[],
    this.apiKeyFieldLabel,
    this.apiSecretFieldLabel,
    this.credentialsHelpText,
    this.credentialsPortalUrl,
  });

  final String vendorId;
  final String displayName;
  final VendorCategory category;
  final VendorAuthMode authMode;

  /// Vendor adapter lifecycle. Drives picker chrome
  /// ("Coming soon" pill) + Connect-button activation. Mirrors
  /// `VendorCapabilityProfile.lifecycle` from
  /// `lib/services/integration/integration_adapter_common.dart`.
  final VendorLifecycle lifecycle;

  final bool coversFieldExposed;
  final bool requiresModule;
  final List<String> modules;

  /// Label rendered above the primary api-key field in the key-paste
  /// dialog. Defaults to "API key" when null.
  final String? apiKeyFieldLabel;

  /// Label rendered above the optional secondary api-key field.
  /// `null` means the dialog renders only the primary field. Vendors
  /// that need a paired secret (Toast restaurant ID + auth token,
  /// Lightspeed LSK client ID + secret, etc.) populate this.
  final String? apiSecretFieldLabel;

  /// Vendor-specific guidance shown above the form fields, telling the
  /// operator where to find the credentials inside the vendor's portal.
  final String? credentialsHelpText;

  /// Optional deep link to the vendor admin / developer portal where
  /// the operator can locate or generate credentials.
  final Uri? credentialsPortalUrl;
}

enum VendorAuthMode { oauth, keyPaste, oauthOrKeyPaste }

/// One row in the test-connection sample-pull modal.
class VendorTestConnectionResult {
  const VendorTestConnectionResult({
    required this.authValid,
    required this.elapsedMs,
    required this.sampleSummary,
    required this.fieldMapping,
    this.note,
  });

  final bool authValid;
  final int elapsedMs;

  /// Human-readable summary line ("Order #12345 - 2026-05-02 - $42.50
  /// - covers: 3").
  final String sampleSummary;

  /// Map of canonical-field → vendor-shape value the adapter mapped.
  final Map<String, String> fieldMapping;

  final String? note;
}

/// One sync log entry surfaced in the "View logs" modal.
class VendorSyncLogEntry {
  const VendorSyncLogEntry({
    required this.occurredAt,
    required this.eventKind,
    this.recordsCount,
    this.errorMessage,
  });

  final DateTime occurredAt;
  final String eventKind;
  final int? recordsCount;
  final String? errorMessage;
}

/// Top-level bundle for the surface — one row per category.
class VendorConnectionsBundle {
  const VendorConnectionsBundle({
    required this.operatorId,
    required this.locationId,
    required this.locationName,
    required this.posConnection,
    required this.laborConnection,
    required this.reservationConnection,
    required this.demoFlags,
  });

  final String operatorId;
  final String locationId;
  final String locationName;

  /// Null when no vendor is connected for this category.
  final VendorConnectionRow? posConnection;
  final VendorConnectionRow? laborConnection;
  final VendorConnectionRow? reservationConnection;

  /// `is_demo` flags per category from `demo_mode_state`.
  final Map<VendorCategory, bool> demoFlags;
}
