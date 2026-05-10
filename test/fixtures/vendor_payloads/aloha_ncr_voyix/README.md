# Aloha (NCR Voyix) Pressure Fixtures

Sources:

- `docs/integrations/aloha_ncr_voyix/api_consumed.md`
- `docs/integrations/aloha_ncr_voyix/field_mapping.md`
- `docs/integrations/aloha_ncr_voyix/oauth_shape.md`
- `docs/integrations/aloha_ncr_voyix/webhook_signature.md`
- `docs/integrations/aloha_ncr_voyix/live_verification_checklist.md`
- `docs/integrations/aloha_ncr_voyix/partnership_status.md`
- NCR Voyix Developer Portal API Explorer:
  <https://developer.ncrvoyix.com/portals/dev-portal/api-explorer>

Adapter: `lib/integrations/pos/aloha_ncr_voyix_pos_adapter.dart`
Sink: `lib/integrations/pos/aloha_ncr_voyix_pos_postgres_sink.dart`
Webhook verifier: `lib/integrations/pos/aloha_ncr_voyix_webhook_signature_verifier.dart`
Credential bridge: `lib/integrations/pos/aloha_ncr_voyix_credential_bridge.dart`

API version pinned: `aloha-v1-2026-05`
Vendor doc retrieval date: 2026-05-04 (see `documentedPerAlohaNcrVoyixV1`).
Fixture corpus retrieval date: 2026-05-08.

## Vendor specifics

NCR Voyix Aloha is **partner-only**. The NCR Voyix Developer Program
intake (8-16 weeks) plus a per-API access request gate sandbox
credentials; production credentials require an additional commercial
conversation. The public developer portal landing
(`https://developer.ncrvoyix.com`) describes the API surfaces but
does not publish byte-level webhook examples without the per-API
access request approval.

For Phase 1 sourcing, fixtures are derived from:

1. The NCR Voyix Developer Portal landing pages (auth/scopes,
   events bus, Aloha module).
2. The F&F per-vendor doc pack
   (`docs/integrations/aloha_ncr_voyix/`) and its inline citations.
3. The adapter's `documentedPerAlohaNcrVoyixV1` constant
   (`lib/integrations/pos/aloha_ncr_voyix_pos_adapter.dart`) and the
   sibling test fixtures
   (`test/integrations/pos/fixtures/aloha_ncr_voyix_orders_fixture.dart`,
   `test/integrations/pos/fixtures/aloha_ncr_voyix_webhook_fixture.dart`).

Fixtures with non-trivial sourcing gaps carry `_sourcing_gap` at
the top of the JSON body. See "Sourcing gaps" section below.

## OAuth credential type for scenario D

OAuth 2.0 `client_credentials` (no refresh token; re-mints by
replaying client_id + client_secret). Aloha is therefore an OAuth
vendor for scenario-D purposes — see `oauth_shape.md`. Phase 2
harness asserts the framework's `oauth_refresh_cron` re-mints
ahead of expiry without holding a live refresh token.

## Scenarios

| File | Outcome | Adapter assertion | Sink assertion |
|---|---|---|---|
| `happy_path_order_closed.json` | accept | `_canonicalize` populates covers/openedAt/closedAt/actualSales; sanity hook passes | upsertCheckFact writes one canonical fact row |
| `happy_path_payment.json` | accept | adapter ignores `paymentStatus` and per-cardholder fields (forbidden); aggregates only | upsertCheckFact writes one canonical fact row |
| `happy_path_employee_punch.json` | N/A — `_sourcing_gap` set | Phase 2 harness skips; Aloha labor not in V1 scope | no DB write expected |
| `happy_path_void.json` | accept (with sourcing gap) | adapter writes a void-flagged fact at totalAmount = 0.00 | upsertCheckFact writes one canonical fact row with void marker |
| `sparse_no_covers.json` | accept | covers source flips to `forecast_fallback`; otherwise canonical | upsertCheckFact writes; fact carries covers_source = forecast_fallback |
| `sparse_minimal_required.json` | accept | absent `voided` defaults to false | upsertCheckFact writes one canonical fact row |
| `scenario_a_forged_signature.json` | reject | `AlohaNcrVoyixWebhookSignatureVerifier.verify` returns false; framework returns 403 | no DB write |
| `scenario_b_malformed_payload.json` | reject | parser throws PayloadParseError before signature path | no DB write |
| `scenario_c_future_dated_event.json` | reject | sanity hook fires; `sanity_log` row written | no canonical fact upsert |
| `scenario_d_oauth_near_expiry.json` | refresh path triggers | `oauth_refresh_cron` re-mints via client_credentials replay; `vendor_credentials.token_expires_at` advances | next fetchChecksPage uses fresh token |
| `scenario_e_ambiguous_timestamp.json` | reject | `iana_timezone_converter` refuses naked timestamps; `vendor_timestamp_policy.aloha_ncr_voyix.asUtc` violation | no DB write |
| `scenario_f_cross_vendor_id_collision.json` | accept (no clobber) | idempotency UNIQUE on `(vendor_id, operator_id, vendor_event_id)` namespaces by vendor; both rows persist | one new Aloha fact row written; prior Toast row unchanged |
| `scenario_dst_spring_forward.json` | accept | `iana_timezone_converter.toBusinessDate` resolves to 2026-03-08 in `America/New_York` despite local-clock gap | upsertCheckFact writes one canonical fact row with business_date = 2026-03-08 |
| `scenario_cross_timezone.json` | accept | resolver uses location IANA timezone `America/Toronto`, business_date = 2026-05-05 | upsertCheckFact writes one canonical fact row with business_date = 2026-05-05 |

## Sourcing gaps

Two fixtures carry an explicit `_sourcing_gap` field for partner-portal
escalation:

1. `happy_path_employee_punch.json` — Aloha employee labor is OUT of
   V1 adapter scope (no labor scopes requested per `oauth_shape.md`).
   Treated as not-applicable for Phase 2 assertions. Replace when
   Aloha Workforce API per-API access request is approved.
2. `happy_path_void.json` — sandbox does not currently document
   whether voided checks emit a separate event or arrive as
   `aloha.check.modified` with `voided: true`. The fixture follows
   the latter; bounded fix expected in `8.AL.live.sandbox`.

Indirect sourcing gaps (called out in source.md but not flagged on
the JSON):

- `scenario_d_oauth_near_expiry.json` — exact OAuth scope strings are
  documented in the F&F doc pack (`oauth_shape.md`) rather than on
  a public NCR Voyix portal page. The scope namespace `aloha:*` is
  documented at the portal landing; per-API exact strings are gated
  by the per-API access request.

## Notes

- Aloha emits ISO-8601 UTC timestamps with the trailing `Z` per
  `field_mapping.md`. Scenario E ("ambiguous timestamp") does not
  arise naturally for Aloha; the fixture forces the case anyway so
  the framework's refuse-by-default protection is exercised.
- Webhook signing: HMAC-SHA256 over raw body bytes, base64,
  `NCR-Webhook-Signature` header. Optional timestamp header is
  `NCR-Webhook-Timestamp` (Unix epoch seconds), 24h replay tolerance
  per V1 lean cut 2.
- Forbidden fields (guest PII, `payments[].cardholderName`,
  `payments[].cardLast4`, `tipAmount` per cardholder) are
  deliberately absent from every fixture body. The adapter must
  never reach for them; the fixture's silence is part of the
  protection.
- Fixture IDs use `chk-<date>-<seq>` and `evt-chk-<date>-<seq>`
  patterns. Operator ID `operator-pressure-001` and site IDs
  `site-aloha-001` / `site-aloha-NYC-001` / `site-aloha-TOR-001`
  are placeholder-only — no real operator can match.
