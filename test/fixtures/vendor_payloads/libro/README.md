# Libro Reserve Pressure Fixtures

Vendor: Libro Reserve (`libro`)
Category: Reservation
Wave: **Wave 1 launch vendor — trio with sandbox creds.** Phase 4
emulator E2E will exercise this corpus first.

Sources:

- Public vendor docs: <https://libroreserve.github.io/api-documentation/>
- Vendor doc pack: `docs/integrations/libro/`
  - `api_consumed.md`
  - `field_mapping.md`
  - `oauth_shape.md`
  - `webhook_signature.md`
  - `live_verification_checklist.md`
  - `partnership_status.md`
- Engineering fixtures (Dart):
  - `test/integrations/reservation/fixtures/libro_reservations_fixture.dart`
  - `test/integrations/reservation/fixtures/libro_webhook_fixture.dart`

Adapter: `lib/integrations/reservation/libro_reservation_adapter.dart`
Verifier: `lib/integrations/reservation/libro_webhook_signature_verifier.dart`
Production API client: `lib/integrations/reservation/libro_reservation_production_api_client.dart`
Credential bridge: `lib/integrations/reservation/libro_credential_bridge.dart`

Sink (Phase 8 vendor connector — same `DataSourceProvider<MockReplayOutput>`
contract as the demo seeder): wired through the framework's reservation
gateway → `OperatorScopedRepository.withTenant(...)` → partial UNIQUE on
`(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)` in
`reservation_facts`.

## Scenarios

| File | Outcome | Adapter assertion | Sink assertion |
|---|---|---|---|
| `happy_path_reservation_confirmed.json` | accept | parse OK; `_normalizeStatus('confirmed')` → `confirmed`; status_transitions has `expected` + `confirmed` | one row written, `wrote: true` |
| `happy_path_reservation_seated.json` | accept | full transition timeline materializes (`expected`/`confirmed`/`arrived`/`seated`) | one row, `party_size = 6` |
| `happy_path_reservation_completed.json` | accept | `_normalizeStatus('completed')` → `completed`; same `vendor_entity_id` as seated fixture but newer `updated_at` | second row written; partial UNIQUE keyed on `(updated_at)` so it does not collide |
| `sparse_no_phone.json` | accept | adapter ignores all `guest_*` per forbidden-fields rule; no parse failure | one row, `party_size = 3` |
| `scenario_a_forged_signature.json` | reject | `LibroWebhookSignatureVerifier.verify` returns `valid: false, failureReason: 'signature mismatch'` | no DB write |
| `scenario_b_malformed_payload.json` | reject | `LibroReservationDto.fromMap` throws (missing `venue_id`/`size`/`reservation_at`/`updated_at`) | no DB write; `connector_sync_log.parse_error` |
| `scenario_c_future_dated_event.json` | reject | sanityHook returns false (event timestamps `created_at`/`updated_at` 2 days in the future); `reservation_at` itself is allowed to be future | no DB write; `sanity_log` row |
| `scenario_d_oauth_near_expiry.json` | refresh path triggers | `oauth_refresh_cron.dart` calls `POST /v1/oauth/token`; rotated refresh token persisted; `consecutive_refresh_failures` reset to 0 | no row mutated by this scenario itself; subsequent poll uses refreshed bearer |
| `scenario_e_ambiguous_timestamp.json` | reject | `LibroIanaConverter.wallClockToUtc` refuses the DST fall-back ambiguous instant `2026-11-01T01:30:00` in `America/Toronto` | no DB write; parse_error logged |
| `scenario_f_cross_vendor_id_collision.json` | accept (no shadow write) | adapter writes `vendor_id = 'libro'` against `vendor_entity_id = OT-CONF-9876` | second row distinct from OpenTable's row with the same string id; `idempotency_keys` namespaces by `vendor_id` |
| `scenario_dst_spring_forward.json` | reject OR documented projection | non-existent wall-clock `2026-03-08T02:30:00` America/Toronto; converter must surface gap or document deterministic projection | matches the documented choice — never silent best-effort |
| `cross_timezone_operator_toronto_vendor_pacific.json` | accept | adapter uses per-location `restaurantTimezone = America/Vancouver` (not operator default); `business_date` projects in Vancouver frame | one row, `business_date` per Vancouver + rollover hour, `reservation_at` in UTC |

## Notes

- **Vendor ID:** `libro` (matches `kLibroVendorId` in the adapter and
  `connector_connection.vendor_id`).
- **Auth mode:** OAuth 2.0 authorization code with refresh tokens.
  Scenario D exercises the proactive refresh closure
  (`oauth_refresh_cron.dart`) — Libro is one of 11 OAuth-bearing
  vendors, NOT one of the 6 non-OAuth vendors in
  `docs/POST_HARDENING_FOLLOWUPS.md` 2026-05-08 confirmed-clean note.
- **Webhook signature:** HMAC-SHA256, hex lowercase, signed payload
  is `<unix_seconds>.<raw_body>` UTF-8. Header `X-Libro-Signature`,
  value `t=<seconds>,v1=<hex>`. Replay tolerance 24h per V1 lean cut 2.
- **Timestamp policy:** `vendor_timestamp_policy['libro'] = asLocationLocal`.
  Libro emits restaurant-local wall-clock with no tz hint; adapter
  projects via `LibroIanaConverter` per-location.
- **Idempotency-key shape:** partial UNIQUE on `reservation_facts`
  `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`.
  Scenario F validates the `vendor_id` namespace.
- **Subscribed events** (per `kLibroSubscribedEvents`):
  `reservation.created`, `reservation.updated`,
  `reservation.confirmed`, `reservation.seated`,
  `reservation.completed`, `reservation.canceled`. Every scenario
  uses one of these.
- **Domain nuance for scenario C:** unlike POS / Labor, the
  reservation domain has a legitimate "future-dated" field
  (`reservation_at`). The pressure-test guard bounds on the
  EVENT-creation timestamp (`created_at`/`updated_at`/`occurred_at`),
  not the booking time. The fixture sets the event timestamps in the
  future while leaving `reservation_at` valid; sanity hook fires on
  the event timestamp.
- **Forbidden fields** (adapter drops, harness MUST verify they do
  NOT appear in canonical fact `raw_payload` columns or anywhere
  downstream): `notes`, `guest_first_name`, `guest_last_name`,
  `guest_email`, `guest_phone`, `card_holder_*`. Several fixtures
  include these to verify the drop path.
