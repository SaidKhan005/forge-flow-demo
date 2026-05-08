# SevenRooms Pressure Fixtures

Sources:

- `docs/integrations/sevenrooms/api_consumed.md`
- `docs/integrations/sevenrooms/field_mapping.md`
- `docs/integrations/sevenrooms/webhook_signature.md`
- `docs/integrations/sevenrooms/oauth_shape.md`
- `docs/integrations/sevenrooms/partnership_status.md`
- Marketing overview: <https://sevenrooms.com/platform/integrations-apis/>
- Partner API portal (account-rep gated): <https://api-docs.sevenrooms.com/>
- Airship API credentials guide:
  <https://academy.airship.co.uk/en/articles/12277047-how-to-get-api-credentials-from-sevenrooms>
- Kleene SevenRooms connector: <https://docs.kleene.ai/docs/sevenrooms>
- Tenzo Reservations + Reviews guide:
  <https://tenzo.zendesk.com/hc/en-gb/articles/6117444553619>
- Redcat help center (webhook delivery confirmation):
  <https://www.redcatht.com/helpcentre/seven-rooms-integration>
- ApiTracker registry: <https://apitracker.io/a/sevenrooms>

Adapter: `lib/integrations/reservation/sevenrooms_reservation_adapter.dart`
Webhook verifier: `lib/integrations/reservation/sevenrooms_webhook_signature_verifier.dart`
Production API client: `lib/integrations/reservation/sevenrooms_reservation_production_api_client.dart`
Existing reference fixtures: `test/integrations/reservation/fixtures/sevenrooms_reservations_fixture.dart`, `test/integrations/reservation/fixtures/sevenrooms_webhook_fixture.dart`

API version pinned: `v2_2_2026_05`
Webhook delivery: `manualPaste` (operator pastes F&F URL into SevenRooms admin portal)
Auth: `oauthOrKeyPaste` — partner-issued client_id + client_secret + venue_id, exchanged at `POST /2_2/auth` for a bearer token

## Scenarios

| File | Outcome | Adapter assertion | Sink assertion |
|---|---|---|---|
| `happy_path_booked_confirmed.json` | accept | `_projectCanonicalRecord` returns `_CanonicalReservation` with `status = booked`, empty `statusTransitions` | one `connector_reservation_fact` row inserted |
| `happy_path_seated.json` | accept | canonical `status = seated`; `statusTransitions = {arrived, seated}` | one fact row inserted with both transition timestamps |
| `happy_path_completed.json` | accept | canonical `status = completed`; `statusTransitions = {arrived, seated, departed}` | one fact row with full transition triplet |
| `happy_path_cancelled.json` | accept | canonical `status = cancelled`; `statusTransitions = {cancelled}` | one fact row with cancellation transition |
| `sparse_path_minimal_required.json` | accept | canonical `status = booked`; `statusTransitions = {}` (empty); no `guest`, no `notes` in payload | one fact row inserted |
| `scenario_a_forged_signature.json` | reject | `SevenRoomsWebhookSignatureVerifier` returns `signatureMismatch`; `handleWebhook` never invoked | no DB write |
| `scenario_b_malformed_payload.json` | reject | `_projectCanonicalRecord` returns `null` (id missing AND party_size is string); `connector_sync_log` row with `event_kind = 'parse_drop'` | no `connector_reservation_fact` write |
| `scenario_c_future_dated_event.json` | reject | parses cleanly through `_projectCanonicalRecord`; framework `sanityHook` rule 2 (`reservation_in_future`) returns false; `pollIncremental` increments `sanityDropped` | no fact write |
| `scenario_d_oauth_near_expiry.json` | rotate (transport layer) | adapter not directly involved — transport-layer cron at hour:05 catches `token_expires_at < now() + 24h`; re-exchange POST `/2_2/auth`; new bearer credential id replaces old in `vendor_credentials` | rotation_inputs ciphertext unchanged; one `connector_sync_log` row with `event_kind = 'token_refresh'` |
| `scenario_e_ambiguous_timestamp.json` | reject | `DateTime.tryParse` returns null on naive `space`-separated wall-clock without offset; `_projectCanonicalRecord` returns null (line 822); compounded by DST fall-back ambiguous hour | no fact write |
| `scenario_f_cross_vendor_id_collision.json` | accept (disjoint namespaces) + reject on replay | both SevenRooms and OpenTable writes succeed because four-tuple UNIQUE includes `vendor_id`; replay of the SevenRooms payload short-circuits at `writeReservationFact` (returns `false`) | two `connector_reservation_fact` rows (one per vendor); replay → no new row, idempotency-hit counter increments |
| `scenario_dst_spring_forward.json` | accept | `arrival_time` parses to UTC = 2026-03-08T07:30:00Z; IANA business-date projection = 2026-03-08 | one fact row with `business_date = 2026-03-08` |
| `scenario_cross_timezone.json` | accept | Vancouver venue arrival = 2026-05-05T02:00:00Z; UTC `last_updated_at` 2026-05-04T20:00:00Z is preserved unchanged; `business_date = 2026-05-04` (Vancouver-local, 4 AM rollover) | one fact row; `vendor_modified_at_utc` matches input UTC verbatim |

## Notes

### Credential type for scenario D

SevenRooms is in the six-vendor non-OAuth set listed in
`test/fixtures/vendor_payloads/README.md` Non-OAuth Vendor Note. The
2026-05-08 confirmed-clean note in `docs/POST_HARDENING_FOLLOWUPS.md`
classifies SevenRooms credential rotation as `transport`-layer. Concretely:

- Tokens are minted by the transport (proxy) layer — not by a broker
  refresh closure.
- The persisted credential triple is `(client_id, client_secret, venue_id)`
  in `vendor_credentials` ciphertext (per `oauth_shape.md` Refresh
  semantics).
- "Refresh" = transport-layer re-exchange of the persisted triple at
  `POST /2_2/auth`. There is no rotating refresh token (client_credentials
  flow).
- Proactive refresh: cron at 5 minutes past every hour scans
  `token_expires_at < now() + 24h`.
- Reactive refresh on 401: adapter retries once after re-exchange.
- 3 consecutive failures: connection status flips to `error`.

### Timezone resolver behavior

Per `field_mapping.md` "Timestamp shapes":

- `arrival_time` — ISO 8601 with offset (venue-local with offset);
  `vendor_timestamp_policy.sevenrooms.asUtc` parses offset → UTC.
- `last_updated_at` — ISO 8601 UTC.
- `arrived_time` / `seated_time` / `departed_time` /
  `cancellation_time` — ISO 8601 with offset (optional); parse → UTC.
- `business_date` (computed) — DATE; `iana_timezone_converter.toBusinessDate`
  with the location's IANA timezone and rollover hour.

The framework's `AmbiguousTimestampConvention.asUtc` declaration for
SevenRooms means the adapter does NOT silently coerce ambiguous
timestamps to venue-local — the parse path returns null and the record
drops at the boundary (scenario E).

### Idempotency-key shape

UNIQUE on `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
per `SevenRoomsReservationGateway.writeReservationFact` doc comment in
`lib/integrations/reservation/sevenrooms_reservation_adapter.dart` lines
184-195. `vendor_id` in the key prevents cross-vendor shadow-writes
(scenario F). `vendor_modified_at` in the key allows the same
reservation id to be written again when the vendor reports a fresh
modification (e.g. status transition booked → seated).

### Webhook signature contract

Per `webhook_signature.md`:

- HMAC-SHA256 over the raw request body (verbatim bytes; no JSON
  re-serialization).
- Hex (lowercase) — uppercase hex is rejected.
- Header name: `X-SevenRooms-Signature` (lowercased on framework
  ingress).
- Timestamp header: `X-SevenRooms-Timestamp` (Unix epoch seconds);
  optional in spec.
- Replay tolerance: 24 hours per V1 lean cut 2.
- Constant-time compare via `constantTimeBytesEquals` from
  `lib/services/integration/inbound_webhook_handler.dart`.

The exact header name + encoding casing are flagged as ambiguity
calls in `webhook_signature.md` Ambiguity calls — `8R.SR.live.sandbox`
will verify and adjust if observed deliveries differ.

### Forbidden fields (kept as `IGNORED` in fixtures so parse path exercises ignored-field behavior)

Per `field_mapping.md` Forbidden fields, the adapter intentionally
ignores: `reservations[].guest.first_name` / `last_name` / `email` /
`phone`, `reservations[].client_id`, `reservations[].notes`,
`reservations[].internal_notes`, and `reservations[].payment.*`. The
happy-path fixtures retain these fields with the placeholder value
`IGNORED` so Phase 2 harnesses can assert the canonical record never
carries them downstream.

### Sourcing gaps

Per the four `docs/integrations/sevenrooms/` doc-pack files (Ambiguity
calls sections), the publicly-fetched portion of the SevenRooms partner
API docs does NOT enumerate:

- Exact webhook signature header name + encoding casing.
- Whether the timestamp is part of the signed payload (raw-body-only vs
  Stripe-style `<timestamp>.<body>` concatenation).
- Per-status transition timestamp presence (`arrived_time` /
  `seated_time` / `departed_time` / `cancellation_time` may be absent
  on legacy reservations).
- Sandbox base URL (assumed same as production with sandbox-scoped
  venue).
- Access-token TTL.
- Exhaustive `status` enum coverage (six values documented; sandbox may
  emit additional).

These gaps are preserved here as documented assumptions; the
`8R.SR.live.sandbox` slice will diff observed vs documented and patch
any mismatches.
