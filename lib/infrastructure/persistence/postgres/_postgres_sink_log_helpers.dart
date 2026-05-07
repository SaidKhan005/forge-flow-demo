// Code Health LB#2 — shared helpers used by every vendor Postgres sink
// to keep the `connector_sync_log.payload_preview` INSERT path
// consistent.
//
// Background: every vendor sink in this directory writes to
// `public.connector_sync_log` from its own `appendSyncLog`
// implementation. Before this helper landed, each sink JSON-encoded
// `payloadPreview` inline (`jsonEncode(payloadPreview)`) which bypassed
// the sensitive-field redactor that the inbound webhook gateway
// already runs at the receive boundary. The 17 vendor sinks therefore
// shipped vendor secrets / PII straight into Postgres in the clear.
//
// Authority: `lib/services/integration/repository_inbound_webhook_gateway.dart`
// owns the `redactWebhookPayload` redactor (see line 627). This helper
// re-uses that redactor; do NOT inline a second redactor here.
library;

import 'dart:convert';

import '../../../services/integration/repository_inbound_webhook_gateway.dart'
    show redactWebhookPayload;

/// Encode a payload preview for the `connector_sync_log.payload_preview`
/// column, applying [redactWebhookPayload] before JSON-encoding so
/// vendor secrets / PII never land in Postgres in the clear.
///
/// Returns `null` when [payloadPreview] is `null` (the sync-log column
/// is nullable and an absent preview must stay absent rather than
/// materialize as the JSON `"null"` literal).
String? encodePayloadPreviewForSyncLog(
  Map<String, Object?>? payloadPreview,
) {
  if (payloadPreview == null) return null;
  final redacted = redactWebhookPayload(payloadPreview);
  return jsonEncode(redacted);
}
