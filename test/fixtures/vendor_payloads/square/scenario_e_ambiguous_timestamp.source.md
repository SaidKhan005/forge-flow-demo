# Source

- URL: https://developer.squareup.com/reference/square/objects/Order#definition__property-created_at
- URL (timestamp policy): docs/integrations/square/field_mapping.md
  "Timestamp shapes" section
- Retrieved: 2026-05-08
- API version: `2024-01-18`
- Webhook event: `order.updated` with malformed timestamps.

## Adversarial scenario

Every timestamp in the body is missing the trailing `Z` and has no
explicit offset:

- `order.created_at` = `2026-05-08T14:30:00`
- `order.updated_at` = `2026-05-08T18:45:00`
- `order.closed_at`  = `2026-05-08T18:45:00`
- envelope `created_at` = `2026-05-08T18:45:00`

Per `field_mapping.md`:

> Square's order timestamps are always UTC instants with a trailing
> `Z`. The adapter does NOT need to consult an ambiguous-timestamp
> policy because Square never emits an offset-less timestamp for the
> endpoints above.

Per `vendor_capability_profile`'s `timestampPolicyDocId`:
`square.created_at_utc_iso8601_with_z`. This is a HARD policy —
Square's published contract is that `created_at` carries `Z`. An
offset-less timestamp from Square is NEVER expected and MUST be
rejected, not interpreted as either UTC or operator-local.

This is the explicit "Square Scenario E from binding A-F" call in
`field_mapping.md`: REJECT, do NOT best-effort.

## Adapter assertions

1. `_orderToCanonicalFact` calls `DateTime.tryParse('2026-05-08T14:30:00')`
   which returns a non-null `DateTime` BUT in Dart's local timezone
   (not UTC). `.toUtc()` then shifts by the test runner's machine
   offset — silently corrupt.
2. The Phase 2 harness MUST detect this. Required behavior: a
   pre-parse guard in the adapter (or an upstream verifier in
   `InboundWebhookHandler`) that rejects any `created_at` /
   `updated_at` / `closed_at` lacking either a trailing `Z` or an
   explicit `±HH:MM` offset.
3. Outcome: HTTP 200 (don't make Square retry forever) with audit
   row `outcome = 'rejected_ambiguous_timestamp'`.
4. `factWriter.upsertSalesFact` is NEVER called.

**Phase 1 finding**: the current adapter source
(`square_pos_adapter.dart` lines 753–759) does NOT implement the
explicit-Z guard — it relies on `DateTime.tryParse` then `.toUtc()`
which silently mis-buckets ambiguous timestamps. This is a
documented gap that Phase 2 should surface as a finding (not a fix
yet — Phase 1 is corpus, Phase 5 consolidates findings).

## Field-level edits

- All four ISO 8601 timestamps stripped of their `Z` suffix.
- All other field paths verbatim per Square's published Order
  object reference.
