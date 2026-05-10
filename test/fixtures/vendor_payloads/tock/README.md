# Tock Pressure Fixtures

Sources:

- `docs/integrations/tock/api_consumed.md` (consumed endpoints,
  pinned API version `reservation_2026_05_03`)
- `docs/integrations/tock/field_mapping.md` (vendor → canonical map)
- `docs/integrations/tock/webhook_signature.md` (HMAC-SHA256, hex,
  `X-Tock-Signature` header)
- `docs/integrations/tock/oauth_shape.md` (`keyPaste` — no OAuth)
- `docs/integrations/tock/partnership_status.md` (Premium-tier gate)
- Vendor public docs: <https://api.exploretock.com/docs/latest/reservation.html>
  (retrieved 2026-05-04 by the engineering slice; re-verified
  2026-05-08 for the Phase 1 fixture corpus)

Adapter:
`lib/integrations/reservation/tock_reservation_adapter.dart`

Verifier:
`lib/integrations/reservation/tock_webhook_signature_verifier.dart`

Production API client:
`lib/integrations/reservation/tock_reservation_production_api_client.dart`

Sink: not yet wired (`8R.TC` ships at lifecycle = `documented`; the
production sink lands with `8R.TC.live.sandbox`). The Phase 2 harness
binds an in-memory `TockFactSink` fake.

## Vendor specifics (carried from `docs/integrations/tock/`)

- **Auth mode:** `keyPaste`. Tock issues per-`businessId` API keys via
  `integrate@tockhq.com` to **Premium / Premium Unlimited** tier
  customers. There is no OAuth flow on the public reservation
  reference. Engineering does not own the commercial lane.
- **Webhook support:** `manualPaste`. Operators copy F&F's webhook URL
  + per-connection signing secret from the F&F admin and paste both
  into the Tock Premium-tier dashboard. The adapter does NOT call any
  auto-register endpoint.
- **Webhook signature:** HMAC-SHA256 over the raw HTTP body bytes,
  encoded as lowercase hex, on the `X-Tock-Signature` header.
  Optional `X-Tock-Webhook-Timestamp` header carrying Unix epoch
  seconds; replay tolerance is the framework's 24h ceiling
  (`kInboundWebhookReplayCeiling`), not a strict 5-minute window.
- **Covers field:** not applicable. Tock emits `partySize` (int) as
  the reservation analog; the canonical fact captures `party_size`.
  `VendorCapabilityProfile.coversFieldExposed = false`.
- **Per-status transition timestamps** (`arrived_at`, `seated_at`,
  `left_at`, `canceled_at`): NOT documented on the public reference.
  Adapter captures only the documented `createdTimestamp` /
  `lastUpdatedTimestamp` / `serviceDateTimestamp`. The
  `8R.TC.live.sandbox` slice diffs observed payloads and adopts any
  per-transition timestamps as a bounded fix.
- **Forbidden fields** (privacy / PCI scope): `guest.firstName`,
  `guest.lastName`, `guest.email`, `guest.phone`,
  `paymentInstrument`. Excluded from every fixture.
- **Sourcing situation (partner-only):** Tock's full Premium-tier
  developer surface is gated to credentialed accounts. The Phase 1
  fixture corpus is shaped from the **public** reservation reference
  + the engineering-slice fixture mirror at
  `test/integrations/reservation/fixtures/tock_reservations_fixture.dart`
  (which Codex graded against the public doc on 2026-05-04). No live
  HTTP calls; no sandbox credentials consumed.

## Scenarios

| File | Outcome | Adapter assertion | Sink assertion |
|---|---|---|---|
| `happy_path_reservation_confirmed.json` | accept | `_canonicalize` produces `status: 'expected'`, `party_size: 2`, `vendor_entity_id: 'res_…'`, ISO-8601 UTC timestamps | one canonical fact upsert; `wrote == true` |
| `happy_path_reservation_seated.json` | accept | `_canonicalize` produces `status: 'seated'`, `party_size: 4`; no per-transition timestamps assumed | one canonical fact upsert |
| `happy_path_reservation_completed.json` | accept | `_canonicalize` produces `status: 'left'`, `party_size: 6` | one canonical fact upsert |
| `sparse_path_minimal_reservation.json` | accept | `_canonicalize` succeeds with `businessId` absent (resolved upstream); `party_size: 1`; no PII fields present | one canonical fact upsert |
| `scenario_a_forged_signature.json` | reject | `TockWebhookSignatureVerifier.verify` returns `valid: false`, `failureReason: 'HMAC mismatch on X-Tock-Signature header'` | no DB write |
| `scenario_b_malformed_payload.json` | reject | `_canonicalize` raises (or sink rejects) on `lastUpdatedTimestamp` non-ISO and `partySize` String-vs-int | no DB write |
| `scenario_c_future_dated_event.json` | reject | sanity hook returns false (future ceiling); `sanity_log` row + `connector_sync_log` drop | no DB write |
| `scenario_d_oauth_near_expiry.json` | no_refresh_path_credential_rotation | OAuth not applicable to Tock (keyPaste); analog is 401 → `connector_connection.status = 'error'`, operator re-paste chrome surfaces. The framework's `oauth_refresh_cron` has NO closure for Tock. | no DB write (operational state change only) |
| `scenario_e_ambiguous_timestamp.json` | reject | timestamp parser rejects (`lastUpdatedTimestamp` / `serviceDateTimestamp` lack `Z`); 01:30 wall time is the US/Eastern fall-back ambiguous hour; refuse-by-default | no DB write |
| `scenario_f_cross_vendor_id_collision.json` | accept (with namespace isolation) | Tock fact written with `vendor_id = 'tock'`; pre-seeded Libro fact with same `vendor_entity_id` is NOT shadow-written | one new canonical fact upsert at the `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)` UNIQUE namespace |
| `scenario_dst_spring_forward.json` | accept | `reservation_at` round-trips losslessly via TIMESTAMPTZ; `business_date` reflects location-local cutover (per `iana_timezone_converter.toBusinessDate`) | one canonical fact upsert |
| `scenario_cross_timezone.json` | accept (3 sub-runs) | `business_date` follows location-local zone (Vancouver 2026-05-08; Toronto 2026-05-08; misconfigured `UTC` MUST refuse rather than silently produce 2026-05-09) | one canonical fact upsert per accepted sub-run |

Total: 12 fixtures (3 happy + 1 sparse + 6 binding adversarial A–F +
2 time edges) — within the 8–12 fixture target band.

## Notes — non-OAuth scenario D substitution

Per `test/fixtures/vendor_payloads/README.md` "Non-OAuth Vendor
Note", Tock is one of six non-OAuth vendors. Scenario D (file
`scenario_d_oauth_near_expiry.json`) is structured as a
**credential-rotation event description**, not a Tock reservation
payload — the JSON wrapper carries `transport:
"credential_rotation_event"` and a `_meta` block describing the 401
substitution path:

- `auth_mode: "keyPaste"`, `oauth_applicable: false`
- vendor 401 response shape (engineering's documented expectation;
  the precise body shape verifies in `8R.TC.live.sandbox`)
- expected state change: `connector_connection.status` flips
  `connected → error`
- operator-facing chrome: "re-paste your Tock API key"
- explicit assertion that the framework's `oauth_refresh_cron` has
  NO closure for Tock — the Phase 3 OAuth-refresh storm load lane
  (3C) confirms by introspecting the worker's per-vendor closure
  registry and asserting Tock NOT IN registry.

The Phase 2 adapter harness drives this scenario by configuring the
`TockApiClient` fake to throw a typed `UnauthorizedException` and
asserting the framework + adapter respond per the `_meta` block.

## Notes — sourcing gaps

- **Vendor 401 response body shape** (scenario D): not documented on
  the public reservation reference. Engineering selected a generic
  `{"error": "unauthorized", "message": "API key invalid or
  revoked"}`. The `8R.TC.live.sandbox` slice will diff observed
  shape and adopt as a bounded fix.
- **Hex vs base64 signature encoding** (scenario A): not documented
  on the public reference. Engineering selected lowercase hex per
  industry convention; `8R.TC.live.sandbox` confirms or adopts
  base64 as a bounded fix.
- **Per-status transition timestamps**: not documented; sandbox
  diff lands them if present. Phase 1 fixture corpus does NOT
  include them; Phase 2 harness asserts only the documented three
  timestamps.
- **`reservation.updated` payload completeness**: assumed full
  reservation shape per the engineering slice. If Tock emits id-only
  events, `8R.TC.live.sandbox` will land the round-trip to
  `fetchReservationById` as a bounded fix.

## Cross-references

- `test/integrations/reservation/fixtures/tock_reservations_fixture.dart`
  — engineering-slice fixture mirror; the Phase 1 happy-path
  reservations match this file's shape.
- `lib/integrations/reservation/tock_reservation_adapter.dart` — the
  `documentedPerTockReservation20260504` constant is the
  machine-readable mirror of `field_mapping.md`. Diff-on-merge keeps
  the two in sync.
