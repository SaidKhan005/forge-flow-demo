# Source

- URL: https://developer.squareup.com/reference/square/objects/Order
- Retrieved: 2026-05-08
- API version: `2024-01-18`
- Webhook event: `order.updated`.

## Cross-timezone scenario

The operator's account `business_timezone` is `America/Toronto`
(Eastern). The Square location for this fixture is in Vancouver
(`America/Los_Angeles` per Square's location resource — Vancouver
shares the Pacific zone with LA in IANA terms).

The order:

- `created_at` = `2026-05-07T22:30:00Z`
- `closed_at`  = `2026-05-08T05:30:00Z`
- `updated_at` = `2026-05-08T05:30:00Z`

Local-time interpretation in `America/Los_Angeles`
(UTC–7 during PDT):

- opened: `2026-05-07T15:30:00 PDT`
- closed: `2026-05-07T22:30:00 PDT`

In `America/Toronto` (UTC–4 during EDT):

- opened: `2026-05-07T18:30:00 EDT`
- closed: `2026-05-08T01:30:00 EDT`

## Resolver decision (per phase_8 walkthrough Scenario D)

> Multi-location chain. Two locations on the same operator with
> different timezones. "Today's covers" for each resolves against
> the location's own timezone, not the operator's device clock.

The adapter MUST resolve `business_date` against the LOCATION's
timezone (`America/Los_Angeles`), not the operator account's
default (`America/Toronto`).

With the location's `business_day_start = 04:00` (Pacific local):

- The order opened at `15:30 PDT` and closed at `22:30 PDT` on
  `2026-05-07`. Both events belong to business date `2026-05-07`
  (the local clock did not cross the 04:00 cutoff).

If the resolver mistakenly uses the operator's `America/Toronto`
timezone, the close timestamp converts to `01:30 EDT` on
`2026-05-08` — which is BEFORE the 04:00 cutoff, so it would
bucket as business date `2026-05-07` anyway. This particular
fixture shape doesn't surface a numeric mismatch — it surfaces
the architectural question: did the adapter consult the LOCATION
timezone or the OPERATOR timezone?

## Adapter assertions

1. `_orderToCanonicalFact(...)` parses both UTC timestamps cleanly.
2. The downstream business-date resolver receives a tagged
   `(operator_id, location_id, utc_instant)` tuple and looks up
   the LOCATION's timezone (`America/Los_Angeles` for
   `L_RESTAURANT_VANCOUVER`).
3. Resolved `business_date = 2026-05-07`.
4. Phase 2 harness verifies a SECOND fixture in this corpus (or a
   harness-side parallel order targeting `L_RESTAURANT_NYC`)
   resolves with NY tz, NOT contaminated by Vancouver's lookup.

## Field-level edits

- Currency: `CAD` (Vancouver location).
- Location id `L_RESTAURANT_VANCOUVER` chosen so the harness can
  pin the location's timezone to `America/Los_Angeles` via the
  framework's locations resolver.
- All field paths verbatim per Square's published Order object
  reference.
