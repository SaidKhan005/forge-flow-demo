# Source

- URL: https://developers.7shifts.com/reference/listshifts
- URL (webhooks reference): https://developers.7shifts.com/reference/webhooks
- URL (trades reference): https://developers.7shifts.com/reference/listtrades
- Retrieved: 2026-05-08
- API version: v2 (pinned `v2-2026-05-04`)
- Endpoint: `shift.updated` webhook envelope (the documented event
  fired when a shift's user_id is reassigned via a trade)
- Notes: swap = the same `shift.id` (887801) with a new `user_id`
  (99003) and the documented `trade_request_id` / `trade_status`
  fields. Mirrors the published shift fixture's schedule slot so a
  test can assert "schedule slot is stable, only assignee changed."
  The adapter currently subscribes to `shift.updated`; trades are
  surfaced as a shift mutation rather than a separate event family.
