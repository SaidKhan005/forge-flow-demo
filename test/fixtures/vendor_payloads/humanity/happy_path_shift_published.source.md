# Source

- URL: https://platform.humanity.com/v1.0/shifts (documented in `docs/integrations/humanity/api_consumed.md`)
- Retrieved: 2026-05-08
- API version: v1.0
- Endpoint: GET /v1.0/shifts (paged listing; cursor `next_cursor` continues to next page)
- Notes:
  - Captures a 2-row page mid-pagination — `next_cursor` is non-null so adapter loops back to `_httpClient.listShifts` with the new cursor; `lib/integrations/labor/humanity_labor_adapter.dart` lines 660-676 walks this loop.
  - `status=published` is documented as a valid Humanity shift state alongside `approved`, `pending`, `unapproved`, `unpublished`; adapter does not branch on `status`.
  - Crosses midnight (in_time 17:00 UTC, out_time next-day 01:00 UTC) — exercises the closes-after-open invariant the framework sanity hook checks.
  - Sourced verbatim against the `humanityBackfillBatchPage1` `Page2` reference fixture shape; `position_name` (not `position`) is used per `tryFromMap` accepting both keys (lib/integrations/labor/humanity_labor_adapter.dart line 215).
- Outcome: adapter writes 2 canonical facts (vendorEntityIds "9100", "9101"); pagination loop continues against `eyJpZCI6OTEwMn0`.
