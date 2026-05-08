# Square POS — Payload Corpus

Source: Square Developer Docs (public).
Adapter: `lib/integrations/pos/square_pos_adapter.dart`
Webhook verifier: `lib/integrations/pos/square_webhook_signature_verifier.dart`
Production API client: `lib/integrations/pos/square_pos_production_api_client.dart`
Vendor doc pack: `docs/integrations/square/`

Canonical fact produced: `SquareCanonicalFact` (sales fact only —
covers always `null`, `coversSource = 'forecast_fallback'`; Square's
Order resource does not expose guest count).

Webhook events parsed: `order.created`, `order.updated`
(see `kSquareWebhookEvents` in the adapter).

Polling endpoints: `POST /v2/orders/search` (backfill +
incremental), `GET /v2/orders/{order_id}` (thin-payload
hydration), `GET /v2/locations` (connect-flow + test-connection),
`POST /oauth2/token` (refresh), `POST /v2/webhooks/subscriptions`
(auto-register).

API version pinned: `2024-01-18`.

## Scenarios

| Scenario | File | Expected outcome | Asserts |
|---|---|---|---|
| Happy: order completed | happy_path_order_completed.json | Adapter produces SquareCanonicalFact with all fields populated | mapping cardinality, time parse, cents→dollars |
| Happy: payment completed | happy_path_payment_completed.json | Out-of-scope event type; framework drops via allowlist | event-type allowlist, no-fact-write |
| Happy: refund | happy_path_refund.json | Out-of-scope event type; net sales decrement comes from paired order.updated | event-type allowlist, no-fact-write |
| Sparse: no covers | sparse_no_covers.json | Adapter produces fact with covers=null, covers_source=forecast_fallback | covers fallback path |
| A: forged signature | scenario_a_forged_signature.json | REJECT — HTTP 401, signature mismatch | webhook verifier (constant-time HMAC) |
| B: malformed | scenario_b_malformed_payload.json | REJECT — missing required fields (id, created_at) | adapter parse guard |
| C: future-dated | scenario_c_future_dated_event.json | REJECT — sanity rule 2 (opened_in_future) | sanity hook drop |
| D: OAuth near-expiry | scenario_d_oauth_near_expiry.json | OAuth refresh worker rotates token first; payload then succeeds | refresh cron + reactive 401 retry |
| E: ambiguous timestamp | scenario_e_ambiguous_timestamp.json | REJECT — explicit-Z policy per field_mapping.md | timestamp parser strict mode |
| F: cross-vendor id collision | scenario_f_cross_vendor_id_collision.json | Adapter namespaces id; no canonical-fact dedup with Toast | (vendor_id, operator_id, vendor_entity_id, vendor_modified_at) UNIQUE |
| DST: spring-forward | dst_spring_forward.json | Parses unambiguously to UTC; IANA resolver buckets local time | DST handling via `package:timezone` |
| Cross-tz: Toronto/Vancouver | cross_timezone_operator_toronto_vendor_pacific.json | Resolves business_date against LOCATION tz, not OPERATOR tz | location-scoped tz resolver |

Total: 12 scenarios (3 happy + 1 sparse + 6 adversarial A–F + 2
time edges). Within the 8–12 corpus size band per
`test/fixtures/vendor_payloads/README.md`.

## Phase 2 harness assertions (skeleton)

| File | Adapter assertion | Sink assertion |
|---|---|---|
| happy_path_order_completed.json | `_orderToCanonicalFact` returns non-null with `actualSales=35.03`, `coversSource='forecast_fallback'` | one row in operator-scoped sales fact table |
| happy_path_payment_completed.json | `kSquareWebhookEvents` does NOT include `payment.*`; framework drops | zero DB writes |
| happy_path_refund.json | `kSquareWebhookEvents` does NOT include `refund.*`; framework drops | zero DB writes |
| sparse_no_covers.json | fact's `covers=null`, `coversSource='forecast_fallback'` | one row; `covers_source` column = `forecast_fallback` |
| scenario_a_forged_signature.json | verifier returns `invalidSignature`; HTTP 401 | zero DB writes; audit row outcome=`rejected_signature_mismatch` |
| scenario_b_malformed_payload.json | `_orderToCanonicalFact` returns null | zero DB writes; audit row outcome=`parse_failure` |
| scenario_c_future_dated_event.json | sanity hook returns false | zero DB writes; audit row outcome=`sanity_dropped_future_dated` |
| scenario_d_oauth_near_expiry.json | refresh cron rotates first; or reactive 401-retry succeeds after refresh | one row written after refresh completes |
| scenario_e_ambiguous_timestamp.json | strict-Z guard rejects (Phase 1 finding: not yet implemented) | zero DB writes; audit row outcome=`rejected_ambiguous_timestamp` |
| scenario_f_cross_vendor_id_collision.json | UNIQUE on (vendor_id, operator_id, vendor_entity_id, vendor_modified_at) | Square row + Toast row coexist |
| dst_spring_forward.json | IANA resolver maps UTC instant to local time deterministically | one row; `business_date` resolves correctly |
| cross_timezone_operator_toronto_vendor_pacific.json | resolver consults LOCATION timezone, not operator account default | one row; `business_date=2026-05-07` |

## Sourcing notes

- All fixtures sourced from Square's public developer docs.
  Citations in each `<scenario>.source.md`. Retrieval date for
  every fixture: 2026-05-08.
- No payload contains real PII. Names ("Cheeseburger", "House
  Burger", "Late Night Burger") are public-example product
  strings; identifiers (`M_TEST_MERCHANT_001`,
  `L_RESTAURANT_A`/`B`/`NYC`/`VANCOUVER`, order ids prefixed with
  Square's documented `CAISEN`-style format) are fictional
  placeholders matching the format Square's docs use.
- No real OAuth tokens, signing keys, or API keys. The `D`
  scenario uses literal `<<TEST_BEARER>>` placeholders documented
  in its `.source.md`.
- All currency amounts are `CAD` (or `USD` for the NY DST fixture)
  and represent reasonable check totals (~$15–$35 CAD).

## Vendor-doc gaps encountered

1. **Square does not expose covers / guest count anywhere on the
   Order resource** (verified at the Order reference page). The
   `sparse_no_covers.json` fixture documents this as the BASELINE
   behavior, not an edge — every Square canonical fact records
   `covers=null`, `covers_source='forecast_fallback'`. The
   dashboard surfaces a top-left pill: "Covers: forecast — Square
   does not expose guest count" per
   `docs/contracts/metric_card_honesty_contract.md`.

2. **Square's webhook docs do not publish a single canonical
   "verbatim envelope example for order.updated"** — the webhook
   intro (`docs/webhooks/build-with-webhooks`) defines the
   envelope shape (`merchant_id`, `location_id`, `type`,
   `event_id`, `created_at`, `data.{type,id,object}`), and the
   Order reference defines the inner Order shape. The fixtures
   compose those two verbatim shapes — no fabrication of
   intermediate paths. Each `.source.md` cites both URLs.

3. **Refund and Payment events**: Square publishes shapes for
   these resources but the F&F adapter does NOT subscribe to
   them. The fixtures exist only to verify the framework's
   event-type allowlist correctly drops out-of-scope events
   without crashing.

4. **Phase 1 finding (deferred to Phase 5 consolidation)**: the
   current adapter's timestamp parsing
   (`_orderToCanonicalFact` lines 753–759 in
   `square_pos_adapter.dart`) does NOT enforce the explicit-Z
   policy declared in `field_mapping.md`. `DateTime.tryParse`
   followed by `.toUtc()` will silently mis-bucket
   offset-less timestamps. `scenario_e_ambiguous_timestamp.json`
   documents this gap; the fix belongs to Phase 5/6, not Phase 1.

## Cross-references

- Format spec: `test/fixtures/vendor_payloads/README.md`.
- Sprint plan: `docs/_execution/2026-05-08_pressure_preview_v1_plan.md`.
- Square vendor doc pack: `docs/integrations/square/`.
- Binding A-F adversarial set:
  `docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`
  (the adversarial A-F redefined here per the Phase 1 prompt is the
  framework-level set; the original IANA Scenarios A-F live in the
  same plan doc under "Timezone Acceptance Criteria").
