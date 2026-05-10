# Source

- URL: <https://api-docs.lsk.lightspeed.app/operation/operation-financial-apigetbusinesslocationsales>
  (canonical sale shape — `accountFiscId` is the documented stable
  identifier; required by `LightspeedLskSaleFields.entityId` in the
  adapter)
- Retrieved: 2026-05-08
- API version: Financial API v2 (`f-v2`); adapter constant
  `kLightspeedLskApiVersion = 'f-v2-2026-05'`.
- Endpoint: inbound webhook delivery (`POST <fnf-webhook-url>`)
- Notes:
  - Body matches `standardLightspeedLskWebhookPayload(...)` in
    `lightspeed_lsk_webhook_fixture.dart`, MINUS the required
    `accountFiscId` field.
  - Adapter behavior in `_projectCanonicalRecord`:
    `if (entityId is! String || entityId.isEmpty) return null;`
    The caller (`handleWebhook`) drops the record at the boundary
    with one `connector_sync_log` row
    (`event_kind = 'parse_drop'`).
  - Signature in `_pressure_envelope` is a placeholder; Phase 2
    harness recomputes the real HMAC over the body bytes before
    invoking the verifier so we exercise the parse-drop path
    AFTER signature verification passes (otherwise the test only
    exercises scenario A). Idempotency UNIQUE
    `(vendor_id, operator_id, vendor_entity_id)` is unreachable
    because there is no entity id, so the drop happens before the
    idempotency check too.
- Expected outcome: signature verifier accepts; framework dispatch
  enters `handleWebhook`; adapter returns
  `HandleWebhookResult(recordsWritten: 0)`; one
  `connector_sync_log` row recording the parse drop.
