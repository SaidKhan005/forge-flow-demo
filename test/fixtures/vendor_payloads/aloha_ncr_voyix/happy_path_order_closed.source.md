# Source

- URL: https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
- Retrieved: 2026-05-08
- API version: aloha-v1-2026-05
- Endpoint: events bus delivery, eventType `aloha.check.modified`
  (full body shape; `aloha.check.modified` may also arrive id-only —
  the adapter handles both via `fetchCheckById`).
- Notes: Mirrors `documentedPerAlohaNcrVoyixV1` and
  `test/integrations/pos/fixtures/aloha_ncr_voyix_webhook_fixture.dart`
  + `aloha_ncr_voyix_orders_fixture.dart`. Field set restricted to
  the canonical fields the adapter consumes (`numberOfGuests`,
  `openedAt`, `closedAt`, `totalAmount`, `checkId`, `modifiedAt`,
  `siteId`). Forbidden fields (guest PII, payments) deliberately
  omitted per `field_mapping.md`.
- Aloha is partner-gated; portal pages are reachable but the
  per-API access request is required for byte-level samples. Shape
  derived from public portal landing + adapter test fixtures
  (`test/integrations/pos/fixtures/aloha_ncr_voyix_*.dart`) + the
  `documentedPerAlohaNcrVoyixV1` constant in
  `lib/integrations/pos/aloha_ncr_voyix_pos_adapter.dart`.
