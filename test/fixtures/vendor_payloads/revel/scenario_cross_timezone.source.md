# Source

- URL: https://developer.revelsystems.com/revelsystems/docs/webhooks
- Retrieved: 2026-05-08
- API version: v1-2026-05-03
- Endpoint: webhook subscription `order.finalized` — cross-timezone edge.
- Notes:
  - Per `test/fixtures/vendor_payloads/README.md`: "payload that combines a Vancouver-local `business_date` with a UTC timestamp from a different region (forces the resolver to choose)". This fixture exercises a `America/Vancouver` location for an operator whose nominal HQ timezone is `America/Toronto`.
  - The wire-format timestamps are ISO 8601 UTC (Revel's convention per `docs/integrations/revel/field_mapping.md`). The risk is on the F&F resolver: a buggy resolver that uses operator-HQ timezone would split one local order across two business days.
  - Per Phase 7.55 Rule 11 ("Restaurant-local timing wins; business date is the anchor; closed truth is not rewritten by later cycles"), the resolver MUST use `location.timezone` (Vancouver), not operator-HQ timezone.
  - Phase 2 sink/spine harness assertion: canonical fact written with `business_date = '2026-05-04'` (Monday local in Vancouver); no second row at `'2026-05-05'`; the location-scoped read services bucket the order to Vancouver Monday.
  - The Revel adapter's `_timezoneFromOrders` helper reads a `timezone` field from the order payload as a hint; the optional `"timezone": "America/Vancouver"` value here is harmless if upstream sends it but the authoritative value comes from `location.timezone` in `connector_connection.metadata`.
  - "_sourcing_gap": Revel's webhook payload schema does not officially document a `timezone` field on the order envelope. The adapter's `_timezoneFromOrders` reads it opportunistically; live shape will be verified at `8.RV.live.sandbox`.
