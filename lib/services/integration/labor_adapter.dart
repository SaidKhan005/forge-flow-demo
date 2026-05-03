// Phase 8.0 — LaborAdapter abstraction.
//
// Sibling to [PosAdapter] for scheduling / labor vendors. Phase 8.S
// covers all 6 scheduling vendors; the reference adapter is
// `8.S.QBT` (QuickBooks Time). Other Wave 1-5 vendors include
// 7shifts, ADP Workforce Now, ADP Workforce Manager, Humanity v1,
// Agendrix, Push Operations.
//
// Same Hard Promises apply (CLAUDE.md): pure transport, no business
// logic; server-side credentials; general-purpose framework.

import 'integration_adapter_common.dart';

/// Vendor-agnostic labor / scheduling adapter contract.
abstract class LaborAdapter {
  /// Stable vendor identifier ("seven_shifts", "quickbooks_time",
  /// "adp_workforce_now", etc.).
  String get vendorId;

  /// Human-readable display name shown in the Vendor Connections
  /// admin surface.
  String get displayName;

  /// Vendor capability profile. Drives connect-flow UX, module
  /// disambiguation (ADP / QuickBooks), webhook support, role
  /// mapping, and wage-source declaration.
  VendorCapabilityProfile get capabilityProfile;

  /// Connect / reconnect flow.
  Future<ConnectResult> connect(ConnectCommand command);

  /// Heavy on-demand connection diagnostic that pulls a real sample
  /// punch + a vendor role list so the operator can verify role
  /// mapping before committing.
  Future<TestConnectionResult> testConnection(TestConnectionCommand command);

  /// 60-day backfill on first connect.
  Future<BackfillResult> backfill(BackfillCommand command);

  /// Incremental poll cycle.
  Future<PollIncrementalResult> pollIncremental(PollIncrementalCommand command);

  /// Webhook handler. Called after signature / replay / binding /
  /// idempotency framework checks pass.
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command);

  /// Disconnect tear-down. Preserves historical punches, wipes
  /// credentials, preserves watermark.
  Future<DisconnectResult> disconnect(DisconnectCommand command);
}
