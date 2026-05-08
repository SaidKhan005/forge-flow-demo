# Source

- URL: https://developer.squareup.com/reference/square/objects/Order
- Retrieved: 2026-05-08
- API version: `2024-01-18`
- Webhook event: `order.updated`.

## Adversarial scenario

`order.created_at` and `order.updated_at` and `order.closed_at` are
all stamped `2026-05-09T...Z` — that is, **24 hours in the future**
relative to the test "now" of `2026-05-08T18:45:01Z` (the value the
Phase 2 harness pins via the adapter's injectable
`DateTime Function() now`).

Per Phase 8 contract, future-dated events MUST be rejected or
quarantined — the sanity hook (sanity rule #2 `opened_in_future`,
referenced from `square_orders_fixture.dart` `futureDatedOrder`
helper at lines 90–103) returns `false` and the adapter skips the
canonical write.

## Adapter assertions

1. `_orderToCanonicalFact` constructs a candidate fact (parse
   succeeds — the timestamps are syntactically valid ISO 8601).
2. `command.sanityHook(...)` is invoked with
   `payload['opened_at'] = '2026-05-09T17:30:00Z'`.
3. The sanity hook returns `false` (rule 2: `opened_in_future`).
4. Both `pollIncremental` and `handleWebhook` paths skip
   `factWriter.upsertSalesFact`.
5. The framework writes an audit row with
   `outcome = 'sanity_dropped_future_dated'`, per
   `phase_8_live_pos_labor_adapter_plan.md` walkthrough item 9
   ("Future-dated event (`opened_at = now() + 5 days`) → log row +
   dropped via timestamp sanity guard").
6. The webhook handler returns HTTP 200 (sanity drops are NOT
   retried — Square would replay forever otherwise).

## Field-level edits

- All three timestamp fields shifted forward 24h from the
  happy-path baseline.
- Currency: `CAD`.
- Identifiers are public-example placeholders.

Field paths verbatim per Square's published Order object reference.
