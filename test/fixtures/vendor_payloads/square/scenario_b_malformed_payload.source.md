# Source

- URL: https://developer.squareup.com/reference/square/objects/Order
- Retrieved: 2026-05-08
- API version: `2024-01-18`
- Webhook event: `order.updated` (malformed — required fields
  missing).

## Adversarial scenario

The Order body is missing two fields the adapter strictly requires
to construct a canonical fact:

1. `order.id` — used as `vendor_entity_id` (line 744 of
   `square_pos_adapter.dart` — `if (id == null || id.isEmpty)
   return null;`).
2. `order.created_at` — used as `opened_at` (line 751 — `if
   (createdAtRaw == null || updatedAtRaw == null) return null;`).

The envelope itself (`event_id`, `merchant_id`, `type`,
`created_at`, `data.id`) is well-formed so the framework's
signature + idempotency layers run normally; failure is at
adapter parse time.

## Adapter assertions

1. `_orderToCanonicalFact(...)` returns `null`.
2. `handleWebhook` returns `HandleWebhookResult(recordsWritten: 0)`.
3. The framework writes an audit row with
   `outcome = 'parse_failure'` per `phase_8_live_pos_labor_adapter_plan.md`
   walkthrough item 8 ("Malformed payload (unexpected field shape)
   → log row + dropped").
4. `factWriter.upsertSalesFact` is NEVER called.
5. The webhook handler returns HTTP 200 (signature was valid; the
   parse failure is logged as a soft drop, not a 4xx, to prevent
   Square from retrying indefinitely on a bug we can't reproduce).

## Field-level edits

The Order object intentionally omits `id` and `created_at`. All
other field paths are verbatim per Square's published Order object
reference.

Note: this is NOT how a healthy Square deployment behaves — Square
ALWAYS emits `id` and `created_at` on every Order webhook. The
fixture exists to prove the adapter degrades gracefully if a
future Square API change OR a network corruption produces a
malformed body.
