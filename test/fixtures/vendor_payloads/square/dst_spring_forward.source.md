# Source

- URL: https://developer.squareup.com/reference/square/objects/Order
- Retrieved: 2026-05-08
- API version: `2024-01-18`
- Webhook event: `order.updated`.

## Time-edge scenario

DST spring-forward in `America/New_York` for 2026:

- 2026-03-08 02:00:00 EST jumps to 03:00:00 EDT
- The local wall-clock interval `02:00 → 03:00 EST` does NOT exist
  on this date.
- A naive parser asked to interpret `2026-03-08T02:30:00` in NY
  local time would either:
  - Throw, OR
  - Silently roll the time forward to `03:30 EDT`, OR
  - Silently roll the time back to `01:30 EST`.

Square's contract: timestamps are emitted as UTC instants with `Z`
(per `field_mapping.md`). The fixture's `created_at` is
`2026-03-08T07:30:00Z` — that is, `02:30 EST` (UTC–5) interpreted
as a UTC instant. There is NO ambiguity in UTC.

## Adapter assertions

1. `_orderToCanonicalFact(...)` parses
   `created_at` = `2026-03-08T07:30:00Z` cleanly to a UTC
   `DateTime`.
2. The downstream business-date resolver
   (`iana_timezone_converter.toBusinessDate`) consumes the UTC
   instant and converts via IANA `package:timezone` to
   `America/New_York` local. Since `02:30 EST` is "in the gap" but
   the UTC instant `07:30 UTC` is NOT — UTC has no DST — the
   resolver produces a deterministic local result: `02:30 EDT` (the
   IANA library rolls the local time forward to the post-jump
   side).
3. With the operator's `business_day_start = 04:00`, the resulting
   business date is `2026-03-07` (the prior business day, since the
   local time is before 04:00).

## Why this matters

Square doesn't emit local-time strings, so on Square specifically
the DST gap is a non-issue at the adapter parse boundary. The
fixture exists to:

- Prove the IANA-library conversion path (Phase 8 framework
  Scenario C — DST fall-back ambiguity in
  `phase_8_live_pos_labor_adapter_plan.md`) is exercised end-to-end
  for the Square adapter.
- Catch any regression where a Square-specific code path swaps in
  fixed-offset arithmetic (e.g. a developer using `Duration`
  subtraction instead of the IANA library).

## Field-level edits

- Location set to `L_RESTAURANT_NYC` to anchor the operator's
  configured timezone to `America/New_York`.
- Currency: `USD` (NY-anchored).
- All field paths verbatim per Square's published Order object
  reference.
