# Source

- URL: https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
- Retrieved: 2026-05-08
- API version: aloha-v1-2026-05
- Endpoint: events bus, eventType `aloha.check.modified` (quick-service site).
- Notes: Aloha quick-service sites are documented in `field_mapping.md`
  as a candidate for null `numberOfGuests`. Adapter classification
  flips from `direct` to `forecast_fallback` for the null subset
  per the bounded fix in `field_mapping.md` § "Covers source
  classification". This fixture exercises that path.
