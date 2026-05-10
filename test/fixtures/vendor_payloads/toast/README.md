# Toast Pressure Fixtures

Sources:
- `docs/integrations/toast/api_consumed.md`
- `docs/integrations/toast/field_mapping.md`
- `docs/integrations/toast/oauth_shape.md`
- `docs/integrations/toast/webhook_signature.md`
- `docs/integrations/toast/partnership_status.md`
- Toast public developer docs:
  <https://doc.toasttab.com/openapi/orders/orders-bulk-v2>,
  <https://doc.toasttab.com/doc/devguide/apiAuthenticationOverview.html>,
  <https://doc.toasttab.com/doc/devguide/apiWebhooksOverview.html>

Adapter: `lib/integrations/pos/toast_pos_adapter.dart`
Production API client: `lib/integrations/pos/toast_pos_production_api_client.dart`
Webhook verifier: `lib/integrations/pos/toast_webhook_signature_verifier.dart`
Credential bridge: `lib/integrations/pos/toast_credential_bridge.dart`
Sink: production sink lives in the `lib/infrastructure/persistence/postgres/`
tree behind the `ToastFactSink` interface declared in the adapter.

Canonical fact name: Toast POS canonical order fact
(`vendor_id = 'toast'`, fields per `documentedPerToastV2`).

Webhook events parsed:
- `orders.opened` (full Order payload inline)
- `orders.modified` (full Order payload OR id-only; adapter calls
  `GET /orders/v2/orders/{guid}` to resolve when id-only)

Polling endpoints:
- `GET /orders/v2/ordersBulk` (60-day backfill + incremental
  polling, 1-hour window stitched by adapter)
- `GET /orders/v2/orders/{orderGuid}` (webhook id-only resolution)
- `GET /restaurants/v1/restaurants/{restaurantGuid}` (connect-time
  identity binding)

Auth endpoint:
- `POST /authentication/v1/authentication/login` (OAuth
  client_credentials grant, `userAccessType: TOAST_MACHINE_CLIENT`)

Webhook management:
- `POST /webhooks-config/v1/webhook` (auto-register)
- `DELETE /webhooks-config/v1/webhook/{subscriptionId}` (disconnect)

## Scenarios

| File | Expected outcome | What it asserts |
|---|---|---|
| `happy_path_order_closed.json` | accept, write 1 row | Full Order envelope with all six canonical-fact paths populated; signature verifies; sanity passes; `_canonicalize` produces correct mapping. |
| `happy_path_check_paid.json` | accept, write 1 row | Order with embedded `checks[]`, `selections[]`, `payments[]`; adapter consumes only top-level fields; nested structure preserved in raw_payload. |
| `happy_path_void.json` | accept, write 1 row (voided=true, actual_sales=0) | Voided Order envelope (`voided: true`, `voidDate`, `voidBusinessDate` populated); adapter remains agnostic to void semantics. |
| `sparse_no_covers.json` | accept, write 1 row (covers=null) | `numberOfGuests: null` (online ordering channel); covers stored as null without fabrication; `covers_source` remains `direct`. |
| `sparse_minimal_required.json` | accept, write 1 row | Only the six required canonical-fact paths plus the documented Order envelope wrappers; adapter does not crash on missing optional fields. |
| `scenario_a_forged_signature.json` | reject (no row) | `Toast-Signature` header is base64 of a non-matching value; framework's `constantTimeBytesEquals` returns false; `handleWebhook` never invoked. |
| `scenario_b_malformed_payload.json` | reject (no row) | Required field `guid` omitted; adapter's `_canonicalize` produces null `vendor_entity_id`; framework rejects at parse / idempotency layer. |
| `scenario_c_future_dated_event.json` | reject or quarantine (no canonical row) | `closedDate` ~24h after `_test_now_at_receive`; framework sanity rule rejects future-dated events on the webhook path (not deliberate backfill). |
| `scenario_d_oauth_near_expiry.json` | accept after refresh | Body is well-formed; assertion is that `oauth_refresh_cron.dart` re-mints token via `POST /authentication/v1/authentication/login` BEFORE the webhook is processed (proactive, 24h horizon per `oauth_shape.md`). |
| `scenario_e_ambiguous_timestamp.json` | reject (no row) | Timestamps stripped of `Z` suffix; per Toast's documented "always-Z" convention, framework MUST refuse. Synthetic adversarial — Toast does not document any wire shape that drops `Z`. |
| `scenario_f_cross_vendor_id_collision.json` | accept, write 1 Toast row WITHOUT touching pre-existing Square row | Toast Order `guid` set to a Square-shaped identifier (`VK0123ABCDEF`); idempotency key namespace by `vendor_id` prevents shadow-write. |
| `dst_spring_forward.json` | accept, write 1 row, business_date=2026-03-08 | Order at `07:30Z` on 2026-03-08 = `02:30 local` in spring-forward gap; IANA converter rounds forward to `03:30 EDT`; `business_date` resolves to 2026-03-08. |
| `cross_timezone_operator_toronto_vendor_pacific.json` | accept, write 1 row, business_date=2026-05-06 | Operator in `America/Toronto`, location in `America/Los_Angeles`; `business_date` resolves against location IANA (not operator device), giving 2026-05-06 even though Toronto local time is already 2026-05-07. |

## Sourcing notes

- Toast's `doc.toasttab.com` openapi pages and developer guide
  pages returned 403 / 404 for direct WebFetch on the 2026-05-08
  retrieval pass. The Toast Partner Program intake is gating the
  pages (see `partnership_status.md` — application status =
  `not_started`).
- The fixture set is therefore reconstructed from the in-repo
  curated mirror sources that captured the 2026-05-03 retrieval
  used by the engineering slice:
  1. `lib/integrations/pos/toast_pos_adapter.dart`
     (`documentedPerToastV2` constant — the canonical
     source-of-truth)
  2. `test/integrations/pos/fixtures/toast_orders_fixture.dart`
     (existing curated fixtures that fed the `documented`
     lifecycle slice)
  3. `test/integrations/pos/fixtures/toast_webhook_fixture.dart`
     (signing-mechanism fixture)
  4. `docs/integrations/toast/*` (5 doc-pack files)
- Per-fixture `.source.md` files cite the in-repo mirror sources
  in addition to the canonical Toast doc URL.
- No real PII. Names, emails, phones — none included. The
  adapter's forbidden-fields list (`customer.firstName`,
  `customer.lastName`, `customer.email`,
  `payments.cardholderName`, `payments.cardLast4`) is also
  excluded from every fixture so test runs cannot accidentally
  exercise PII paths.
- No real OAuth bearers, signing keys, or partner secrets.
  Placeholders used:
  - `<<TEST_BEARER>>`, `<<TEST_BEARER_NEAR_EXPIRY>>`,
    `<<TEST_BEARER_REFRESHED>>`
  - `<<TEST_HMAC_SECRET>>`,
    `<<HMAC_SHA256_BASE64_OF_BODY_USING_TEST_HMAC_SECRET>>`
  - `<<TEST_CLIENT_ID>>`, `<<TEST_CLIENT_SECRET>>`,
    `<<TEST_CLIENT_SECRET_KMS_REF>>`

## Vendor-doc gap notes (Phase 5 escalation)

| Gap | Detail | Phase 5 action |
|---|---|---|
| `doc.toasttab.com` openapi endpoints gated | All five WebFetch attempts on `doc.toasttab.com/openapi/orders/orders-bulk-v2` and `doc.toasttab.com/doc/devguide/api*` returned 403 / 404 on 2026-05-08. The pages are likely partner-portal-gated or behind a CDN that rejects automated WebFetch. | Escalate to ops to verify whether the public docs require a Toast Partner Program login. If yes, the partner portal will also expose schema enrichments not in the in-repo mirror. |
| `scenario_e_ambiguous_timestamp.json` is synthetic | Toast public docs explicitly declare every Order timestamp ISO-8601 UTC with `Z`. No documented wire shape drops the suffix. | Confirm via partner portal whether any niche endpoint or webhook variant ever omits the `Z`. If confirmed-never, this scenario remains a synthetic guardrail; otherwise the adapter's timestamp policy needs an explicit non-UTC treatment rule. |
| Employee clock-out (originally listed in prompt as optional) | Toast exposes a Labor API surface, but THIS adapter (`toast_pos_adapter.dart`) only consumes orders / restaurants / auth / webhooks-config endpoints per `api_consumed.md`. Labor data is out of scope for the POS adapter. | None — confirmed out-of-scope by adapter contract. If Toast labor ingest is ever added, a separate `toast_labor_adapter.dart` slice would carry its own pressure corpus. |
| Order schema field completeness | The fixture reconstruction draws on the adapter's six pinned canonical paths plus the wrapper fields (entityType, restaurant, server, revenueCenter, diningOption, table, paymentStatus, businessDate, totalTaxAmount, totalDiscountAmount, totalAmountWithoutTaxAndDiscounts, voided, deleted, source, duration). The full Toast Order schema may include additional fields (e.g. `appliedTaxes[]`, `requiredPrepBy`, `requiredAvailability[]`, `marketplaceFacilitatorTaxInfo`) that the adapter does not consume. | Phase 5: enumerate via partner portal; if any of those fields gain canonical-fact status, expand the fixture corpus. |

## Notes

- OAuth credential type for Scenario D = `oauth` (Toast
  client_credentials grant). No refresh-token rotation; every
  refresh re-mints via the documented login endpoint. Per
  `oauth_shape.md`, proactive refresh runs at the 24-hour horizon
  via `oauth_refresh_cron.dart`.
- Timestamp policy: `vendorTimestampPolicy['toast']` is registered
  but the registry's runtime `asUtc` wiring is deferred to the
  `8.TS.live.sandbox` slice (see `field_mapping.md` engineering-vs-
  framework boundary note). Phase 2 harnesses MUST pin
  `timestampPolicyDocId: 'toast'` when probing scenario E.
- Idempotency key shape:
  `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  per the framework. Scenario F leverages this shape directly.
- Replay window: 24h ceiling per V1 lean cut 2 (NOT the 5-minute
  Stripe-style window). Scenario tests should use the framework's
  `kInboundWebhookReplayCeiling` constant.
- `_event_envelope`, `_test_now_at_receive`, `_test_credential_state`,
  `_test_collision_partner`, `_test_location_iana`,
  `_test_operator_iana`, `_test_local_intent`, `_sourcing_gap`
  are TEST-SIDE keys (underscore-prefixed). They are not part of
  any Toast wire shape; the Phase 2 harness reads them and feeds
  them into fakes / fixtures.
