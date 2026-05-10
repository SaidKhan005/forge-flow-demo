# Revel Pressure Fixtures

**Vendor ID**: `revel`
**Category**: POS
**Sources**:

- `docs/integrations/revel/api_consumed.md` (endpoints, OAuth shape, sandbox)
- `docs/integrations/revel/field_mapping.md` (canonical fact field paths + types)
- `docs/integrations/revel/webhook_signature.md` (HMAC-SHA1, header names, no signed timestamp)
- `docs/integrations/revel/oauth_shape.md` (`client_credentials`, 24h JWT, no refresh token)
- `docs/integrations/revel/partnership_status.md` (no commercial gating; self-serve)
- Vendor doc: <https://developer.revelsystems.com/revelsystems/docs/webhooks>
- Engineering-slice fixtures: `test/integrations/pos/fixtures/revel_webhook_fixture.dart`, `test/integrations/pos/fixtures/revel_orders_fixture.dart`

**Adapter**: `lib/integrations/pos/revel_pos_adapter.dart`
**Verifier**: `lib/integrations/pos/revel_webhook_signature_verifier.dart`
**Production API client**: `lib/integrations/pos/revel_pos_production_api_client.dart`
**Sink** (Phase 8 connector lane — same `DataSourceProvider<MockReplayOutput>` interface as the demo-mode writer): `lib/integrations/pos/` (sink filename TBD on `8.RV.live.sandbox`)

## Sourcing Posture

Revel is **partner-only** per `partnership_status.md` (the F&F-platform commercial lane is "no application required" but each operator issues their own credentials at the Revel admin portal; the developer portal `https://developer.revelsystems.com/` is partner-gated past the public webhooks page).

For Phase 1 fixture sourcing, primary input was the vendor's public webhooks documentation page; field shapes were cross-checked against:

1. The verbatim adapter test fixtures `revelOrderFinalizedPayload` and `revelSampleOrder` (sourced 2026-05-03 against the same vendor doc URL).
2. Adapter `documentedPerRevelV1` constant (the engineering slice's source-of-truth; mirrors the field-mapping doc).
3. Third-party Revel integration writeups for the `payments[]` and `dining_option` enum shapes (cited in per-fixture `.source.md` `"_sourcing_gap"` notes).

## Scenarios

| File | Outcome | Adapter assertion | Sink / framework assertion |
|---|---|---|---|
| `happy_path_order_finalized.json` | accept | `_canonicalize` returns a `RevelCanonicalOrderFact`; `handleWebhook` returns `recordsWritten: 1` | sink upserts on `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`; one canonical fact row |
| `happy_path_order_paid.json` | accept | `_canonicalize` returns fact; numeric `final_total` parses via `_parseSales`; per-payment `card_last4` / `tip_amount` ignored | sink writes one row; PCI-scoped fields not persisted |
| `happy_path_order_void.json` | accept | `_canonicalize` returns fact with `actual_sales = 0`, `voided` field present in `rawPayload` | sink writes one row; downstream variance honors `actual_sales = 0` |
| `sparse_path_zero_covers.json` | accept | `_canonicalize` returns fact with `covers = 0` | sink writes one row; metric honesty pill renders covers `state = live` (zero is a real value, not a phantom) |
| `scenario_a_forged_signature.json` | reject | `RevelWebhookSignatureVerifier.verify` returns `valid: false` (`HMAC mismatch`) | inbound handler returns 403; `audit_logs` row written; no idempotency row, no fact row |
| `scenario_b_malformed_payload.json` | reject | `_canonicalize` returns null (missing `id` / non-parseable timestamps / non-numeric total) | `handleWebhook` returns `recordsWritten: 0`; `connector_sync_log` records parse failure |
| `scenario_c_future_dated_event.json` | reject | `command.sanityHook` returns false on `opened_in_future` | adapter skips canonical write; `PollIncrementalResult.sanityDropped` increments; `connector_sync_log.event_kind = sanity_drop` |
| `scenario_d_oauth_near_expiry.json` | refresh-path triggers | `RevelOAuthRefresher.refresh` re-exchanges `client_credentials`; `VendorRefreshOutcome.success` returned | gateway re-encrypts new access token; `consecutive_refresh_failures = 0`; `audit_logs` row written |
| `scenario_e_ambiguous_timestamp.json` | reject | `_canonicalize` returns null because `_parseUtc` cannot resolve naive timestamp deterministically | `connector_sync_log.event_kind = parse_error`; no fact written; per `field_mapping.md` "must reject, not best-effort" |
| `scenario_f_cross_vendor_id_collision.json` | accept (in Revel namespace) | `_canonicalize` returns fact for Revel namespace | `inbound_webhook_idempotency` UNIQUE on `(vendor_id, operator_id, vendor_event_id)` is namespaced; canonical fact upsert key is namespaced; verify Revel row independent of any pre-existing Square row with the same numeric id |
| `scenario_dst_spring_forward.json` | accept | `_canonicalize` returns fact; UTC timestamps unambiguous | sink calls `iana_timezone_converter.toBusinessDate(location.timezone='America/Toronto')`; `business_date = '2026-03-07'`; one row, no double-bucket |
| `scenario_cross_timezone.json` | accept | `_canonicalize` returns fact; UTC timestamps unambiguous | sink uses Vancouver location's `timezone`, NOT operator HQ; `business_date = '2026-05-04'`; one row |

## Notes

### Auth + credential rotation

- Revel uses OAuth `client_credentials` with a 24h JWT bearer and **no refresh token**. Scenario D therefore exercises the `RevelOAuthRefresher` path that re-exchanges the same `client_id` / `client_secret` pair. The `pg_cron` refresh job picks up any token within 24h of expiry; with a 24h TTL that means hourly during normal operation.
- The OAuth refresh-closure audit row is wired per the 2026-05-08 audit-additions note in `docs/POST_HARDENING_FOLLOWUPS.md` (marked resolved).
- Three consecutive failures flip `connector_connection.status = 'error'`. Email auto-disable is deferred to `9.8.email`; advisory locks are banned per V1 lean cut 2.

### Webhook signing

- HMAC-SHA1 over the raw request body, hex-encoded (lowercase), in `X-Revel-Signature`. **No signed timestamp** — Revel does not bind a timestamp into the signature. Replay defense relies entirely on the idempotency UNIQUE on `(vendor_id, operator_id, vendor_event_id)` with the framework's 24h replay ceiling bypassed (`WebhookSignatureVerification.timestamp = null`).
- The verifier (`revel_webhook_signature_verifier.dart`) uses `constantTimeBytesEquals` to defend against timing oracles.

### Idempotency-key shape (Scenario F)

- Inbound webhook idempotency: `(vendor_id, operator_id, vendor_event_id)` UNIQUE in `inbound_webhook_idempotency` (`vendor_event_id` sourced from `X-Revel-Event-Id`).
- Canonical fact upsert: `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)` UNIQUE; out-of-order delivery is last-write-wins on `vendor_modified_at`.

### Timezone resolver behavior (Scenarios DST + cross-timezone)

- Revel emits ISO 8601 UTC unconditionally per `field_mapping.md`. The adapter rejects any naive / no-offset shape on parse (`_parseUtc` returns null) — Scenario E exercises the refusal path.
- `business_date` is resolved at canonical-fact write time by `iana_timezone_converter.toBusinessDate` using the per-location timezone (sourced from `connector_connection.metadata.timezone`). Operator-HQ timezone never substitutes.

### Forbidden fields surface area (happy_path_order_paid.json)

The adapter intentionally ignores at canonical-write time even when present in the payload:

- `order.customer.email` / `name` / `phone` (privacy)
- `order.payments[].card_last4` / `card_brand` / `cardholder_name` (PCI scope)
- `order.tip_amount` per-card breakdown (per-card attribution belongs to payroll)
- `order.history[]` state-transition log (out of scope at V1)

`happy_path_order_paid.json` includes the PCI-scoped fields so Phase 2 sink harness can verify the adapter does not persist them.

## Sourcing Gaps

Documented in per-fixture `.source.md` `"_sourcing_gap"` notes; aggregated here:

- `dining_option` integer→label mapping not pinned on the public webhooks page (third-party reconstruction in `sparse_path_zero_covers.json`).
- `payments[]` per-row field set is reconstructed from public Revel API references and the adapter's forbidden-fields list (`happy_path_order_paid.json`).
- `void_reason` enum values are illustrative; Revel does not pin a public enum (`happy_path_order_void.json`).
- Optional order-envelope `timezone` field is read opportunistically by `_timezoneFromOrders`; not officially documented (`scenario_cross_timezone.json`).
- Webhook auto-register endpoint exact path is "TBD at sandbox" per `field_mapping.md` ambiguity calls; this fixture corpus does not exercise the registration round-trip.

All sourcing gaps will be confirmed or corrected at `8.RV.live.sandbox` against the per-customer Revel sandbox; mismatches are treated as bounded fixes (not slice rebuilds) per `docs/contracts/vendor_adapter_slice_contract.md`.
