# Source

- URL: https://docs.clover.com/reference/orderget
- URL: https://docs.clover.com/reference/orders
- Retrieved: 2026-05-08
- API version: REST v3 / `v3_2026_05_03`
- Endpoint: `GET /v3/merchants/{mId}/orders` — three orders straddling
  the **2026-03-08 US spring-forward** boundary (02:00 local jumps to
  03:00 in `America/New_York`):
    - `CLV-ORDER-DST-PRE-001` — `createdTime = 1772953140000`
      (2026-03-08T06:59:00Z = **2026-03-08T01:59:00 EST**, last
      minute before the gap)
    - `CLV-ORDER-DST-DURING-001` — `createdTime = 1772955000000`
      (2026-03-08T07:30:00Z = **02:30 EST does not exist**; this
      maps to 03:30 EDT after the resolver runs — exercises the
      framework's IANA converter on a non-existent local time)
    - `CLV-ORDER-DST-POST-001` — `createdTime = 1772956800000`
      (2026-03-08T08:00:00Z = **2026-03-08T04:00:00 EDT**, first
      hour after spring-forward)
- Notes: alias filenames named in the calling Phase 1 prompt
  (`dst_spring_forward.json`) are normalized to the README binding
  filename `scenario_dst_spring_forward.json` for Phase 2 consumers.
- Adapter cite: Clover emits epoch millis UTC unconditionally
  (`vendor_timestamp_policy.clover.asUtc` per
  `docs/integrations/clover/field_mapping.md`); the per-fact
  `business_date` rollover happens at the worker layer via the
  framework's IANA converter (`iana_timezone_converter.toBusinessDate`).
- Outcome (Phase 2 harness):
  All three orders write canonical sales facts. Asserted
  `business_date` per fact (location TZ = `America/New_York`):
    - PRE: `business_date = 2026-03-07` (restaurant-day rollover —
      01:59 local on Mar 8 still falls in the Mar 7 service day if
      restaurant-day cutover is e.g. 04:00 local)
    - DURING: `business_date = 2026-03-07` (still pre-cutover after
      DST jump to 03:30 EDT)
    - POST: `business_date = 2026-03-08` (post-04:00 cutover —
      first row of the new restaurant day)
  The exact `business_date` boundaries depend on the location's
  configured restaurant-day cutover; the harness asserts that the
  IANA converter, not the adapter, is the only authority for this
  bucketing — adapter output is identical regardless of cutover.
