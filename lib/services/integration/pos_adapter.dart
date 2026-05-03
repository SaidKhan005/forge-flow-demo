// Phase 8.0 — PosAdapter abstraction.
//
// The shared, vendor-agnostic interface every Wave 1-5 POS integration
// must satisfy. The framework slice (`8.0`) ships only this abstraction
// plus the supporting infra (IANA converter, credential storage,
// webhook handler, sync worker, admin UX). The first concrete
// implementation lands in `8.LSK` (Lightspeed K-Series) and is the
// reference adapter against which the contract is re-verified.
//
// Per Hard Promise #1 (CLAUDE.md Authority Order), Phase 8 is a pure
// transport swap: adapters write the existing canonical Postgres
// fact tables (sales / covers / punches / reservations) and never
// modify `lib/services/*` business logic or `lib/domain/services/*`
// formulas.
//
// Per Hard Promise #7, vendor secrets are server-side only.
// Implementations consume an opaque [VendorCredentialHandle] minted
// by `vendor_credentials_repository.dart` (lands with the next
// Postgres-write slice); plaintext tokens never reach Flutter.
//
// Per Hard Promise #8, the framework is general-purpose. Adding a
// future POS vendor means adding one new file under
// `lib/integrations/pos/<vendor>_pos_adapter.dart`. The framework
// itself does not change.

import 'integration_adapter_common.dart';

/// Vendor-agnostic POS adapter contract.
///
/// Wave 1 reference adapter: `8.LSK` (Lightspeed K-Series).
/// Wave 2: `8.SQ` (Square).
/// Wave 3: `8.TS` (Toast — partnership-gated).
/// Wave 4: `8.RV` (Revel), `8.CL` (Clover).
/// Wave 5: `8.AL` (Aloha NCR Voyix), `8.OR` (Oracle MICROS Simphony).
///
/// All methods operate inside a tenant-scoped transaction created by
/// `OperatorScopedRepository.withTenant`. Implementations must NOT
/// open their own connections or bypass the repository pattern.
abstract class PosAdapter {
  /// Stable vendor identifier ("toast", "lightspeed_lsk", "square",
  /// etc.). Matches `connector_connection.vendor_id` and the
  /// `{vendor}` URL segment of the admin / webhook routes.
  String get vendorId;

  /// Human-readable display name shown in the Vendor Connections
  /// admin surface ("Lightspeed Restaurant K-Series").
  String get displayName;

  /// Vendor capability profile. Drives connect-flow UX (key-paste vs
  /// OAuth), webhook auto-registration, multi-location grant scope,
  /// covers-field availability, partnership gating, etc.
  VendorCapabilityProfile get capabilityProfile;

  /// Called when an operator clicks "Connect" or "Reconnect" from
  /// the admin surface. Returns the redirect URL for OAuth flows or
  /// confirms the key-paste credential write.
  Future<ConnectResult> connect(ConnectCommand command);

  /// Called when the operator clicks "Test connection". Implementations
  /// must return within 5 seconds (vendor-side rate limits permitting)
  /// and surface a real sample order with covers + open/close
  /// timestamps so the operator sees that field mapping is working,
  /// not just that auth is valid.
  Future<TestConnectionResult> testConnection(TestConnectionCommand command);

  /// 60-day backfill on first connect (or operator-configured custom
  /// window). Implementations MUST persist `connector_sync_watermark`
  /// after each batch commit so a Cloud Run job restart resumes from
  /// the last successful cursor instead of starting over.
  Future<BackfillResult> backfill(BackfillCommand command);

  /// Incremental polling loop. Cadence is owned by
  /// `tool/integration_sync_worker/`; this method is invoked once
  /// per tick and writes any new vendor entities visible since
  /// `watermark.lastModifiedSeen`.
  Future<PollIncrementalResult> pollIncremental(PollIncrementalCommand command);

  /// Webhook handler. Called by [InboundWebhookHandler] AFTER signature
  /// verification, replay defense, binding cross-check, and idempotency
  /// have all passed. Implementations must NOT re-verify the signature
  /// or re-check idempotency — that is the framework's responsibility.
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command);

  /// Disconnect tear-down. Wipes credentials, unregisters the webhook
  /// subscription via the vendor's API where supported, and writes a
  /// `connector_sync_log` row with `event_kind = 'disconnect'`.
  /// Historical canonical facts and `connector_sync_watermark` are
  /// preserved so reconnect resumes from the last cursor.
  Future<DisconnectResult> disconnect(DisconnectCommand command);
}
