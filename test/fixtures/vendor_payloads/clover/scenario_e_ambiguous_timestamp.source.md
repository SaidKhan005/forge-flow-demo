# Source

- URL: https://docs.clover.com/reference/orderget
- URL: https://docs.clover.com/dev/docs/webhooks
- Retrieved: 2026-05-08
- API version: REST v3 / `v3_2026_05_03`
- Endpoint: `GET /v3/merchants/{mId}/orders` — same envelope as
  `happy_path_order_paid.json`, but with both `createdTime` and
  `modifiedTime` rendered as **ISO-8601 strings without `Z` suffix
  and without an offset** (`"2026-05-02T18:45:00"`).
- Adapter cite: `lib/integrations/pos/clover_pos_adapter.dart`
  `_project()`:
  ```
  if (created is! int) return null;
  if (modified is! int) return null;
  ```
  Per Clover's **documented vendor-timestamp policy** (`v3` REST
  emits `epoch_millis_utc` ints — see
  `docs/integrations/clover/field_mapping.md` "Timestamp shapes" and
  `cloverApiVersion = 'v3_2026_05_03'`'s `opened_at_type =
  epoch_millis_utc` constant), a timezone-naive ISO string is
  ambiguous and not a documented Clover shape.
- Outcome: **Reject (timezone resolution fails — must reject, not
  best-effort)**. `_project` returns null; the fact is dropped at
  the boundary. The adapter does NOT attempt to interpret the
  string as UTC, restaurant-local, or merchant-local — silent
  defaulting would corrupt the `business_date` rollover and the
  watermark.
- Notes: aligns with the `phase_7_55_time_boundary_contract.md`
  rule — "operator-scoped Postgres fact tables store TIMESTAMPTZ
  (UTC); TIMESTAMP WITHOUT TIME ZONE banned in operator-scoped
  tables." Accepting an ambiguous timestamp at the adapter would let
  one upstream into the operator-scoped fact table.
