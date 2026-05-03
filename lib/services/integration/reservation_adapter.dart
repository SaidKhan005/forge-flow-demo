// Phase 8.0 — ReservationAdapter abstraction.
//
// Sibling to [PosAdapter] for reservation vendors. Phase 8R covers
// all 4 reservation vendors. The reference adapter is `8R.LB`
// (Libro). Other vendors: OpenTable, SevenRooms, Tock.
//
// Same Hard Promises apply (CLAUDE.md): pure transport, no business
// logic; server-side credentials; general-purpose framework.

import 'integration_adapter_common.dart';

/// Vendor-agnostic reservation adapter contract.
abstract class ReservationAdapter {
  /// Stable vendor identifier ("libro", "opentable", "sevenrooms",
  /// "tock").
  String get vendorId;

  /// Human-readable display name shown in the Vendor Connections
  /// admin surface.
  String get displayName;

  /// Vendor capability profile.
  VendorCapabilityProfile get capabilityProfile;

  /// Connect / reconnect flow.
  Future<ConnectResult> connect(ConnectCommand command);

  /// Heavy on-demand connection diagnostic that pulls a real sample
  /// reservation so the operator can verify field mapping. Should aim
  /// to return well under 30 seconds; the route timeout is ~30s.
  Future<TestConnectionResult> testConnection(TestConnectionCommand command);

  /// 60-day backfill on first connect. Implementations MUST call
  /// `command.sanityHook(...)` BEFORE each canonical fact write and
  /// skip the write when it returns `false`.
  Future<BackfillResult> backfill(BackfillCommand command);

  /// Incremental poll cycle. Implementations MUST call
  /// `command.sanityHook(...)` BEFORE each canonical fact write and
  /// skip the write when it returns `false`. The hook is the only
  /// enforcement point for timestamp sanity on the polling path.
  Future<PollIncrementalResult> pollIncremental(PollIncrementalCommand command);

  /// Webhook handler. Called after signature / replay / binding /
  /// idempotency framework checks pass.
  Future<HandleWebhookResult> handleWebhook(HandleWebhookCommand command);

  /// Disconnect tear-down. Preserves historical reservations, wipes
  /// credentials, preserves watermark.
  Future<DisconnectResult> disconnect(DisconnectCommand command);
}
