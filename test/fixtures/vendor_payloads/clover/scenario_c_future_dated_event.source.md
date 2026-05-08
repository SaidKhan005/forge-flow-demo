# Source

- URL: https://docs.clover.com/reference/orderget
- Retrieved: 2026-05-08
- API version: REST v3 / `v3_2026_05_03`
- Endpoint: `GET /v3/merchants/{mId}/orders` — well-formed order shape
  with `createdTime = 1777834500000` (2026-05-03T18:55:00Z) and
  `modifiedTime = 1777920900000` (2026-05-04T18:55:00Z). Both
  timestamps are **>24h in the future** relative to the framework's
  reference clock anchored at 2026-05-02T18:45:00Z (the same hour as
  the `happy_path_order_paid.json` `createdTime`).
- Adapter cite: the framework's webhook timestamp guard lives in
  `lib/services/integration/inbound_webhook_handler.dart`
  (`kInboundWebhookReplayCeiling`); for backfill / poll the worker's
  `command.sanityHook` performs the equivalent guard before the row
  reaches `_project`.
- Outcome: **Reject (timestamp guard)**. `sanityHook` returns false;
  the adapter increments the `dropped` counter and continues. No
  canonical fact is written.
- Notes: a future-dated `modifiedTime` from a real Clover endpoint
  would indicate either clock skew in Clover's infrastructure or a
  malicious replay/forgery. The framework refuses to write either way
  — the canonical sales fact's `vendor_modified_at` is load-bearing
  for the watermark-resume contract, so accepting a future timestamp
  would corrupt the watermark and stall future polls.
