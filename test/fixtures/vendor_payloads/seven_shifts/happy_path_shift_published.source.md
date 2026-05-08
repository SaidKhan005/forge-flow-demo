# Source

- URL: https://developers.7shifts.com/reference/listshifts
- URL (webhooks reference): https://developers.7shifts.com/reference/webhooks
- Retrieved: 2026-05-08
- API version: v2 (pinned `v2-2026-05-04`)
- Endpoint: `shift.created` webhook envelope (matches the shape of
  `GET /v2/company/{company_id}/shifts` rows)
- Notes: published planned shift at the documented v2 shape. `start`
  and `end` are explicit-Z UTC; `published=true` distinguishes a
  released schedule from a draft. `open=false`, `draft=false`,
  `deleted=false` exercise the documented boolean flag set. Adapter's
  capability profile subscribes to the full `shift.*` event family per
  `kSevenShiftsSubscribedWebhookEvents`; this fixture is the
  canonical published-shift payload.
