# OpenTable Pressure Fixtures

Sources:
- `docs/integrations/opentable/` — full per-vendor doc pack (api_consumed,
  field_mapping, oauth_shape, webhook_signature, partnership_status).
- OpenTable Platform (operator-facing only):
  <https://restaurant.opentable.com/products/opentable-platform/>
- OAuth 2.0 RFC 6749 §5.1 (token-response shape used by scenario D):
  <https://datatracker.ietf.org/doc/html/rfc6749#section-5.1>
- OpenTable Partner API developer reference: gated behind partnership
  program (see `docs/integrations/opentable/partnership_status.md`).

Adapter: `lib/integrations/reservation/opentable_reservation_adapter.dart`
Webhook signature verifier:
`lib/integrations/reservation/opentable_webhook_signature_verifier.dart`
Production API client:
`lib/integrations/reservation/opentable_reservation_production_api_client.dart`
Credential bridge:
`lib/integrations/reservation/opentable_credential_bridge.dart`

Vendor lifecycle: `documented` (Phase 8R.OT). Every field-mapping row
in this fixture corpus is an **assumption** flagged
`verify_in_live_sandbox: true` in
`documentedPerOpentableV1FieldMapping`; the `8R.OT.live.sandbox` slice
will diff observed responses against the fixture shape and cut bounded
fixes for any drift. No live OpenTable Partner API payload has been
observed at fixture-authoring time.

## Vendor specifics

OpenTable does not maintain a public developer portal. The Partner API
reference (endpoints, OAuth shape, webhook signature envelope, exact
status enum vocabulary) is released to partners only after the
partnership program review clears (lead time 6-12 weeks per
`partnership_status.md`). Engineering bound the adapter to the
**industry-standard reservation envelope** shared by every reservation
vendor F&F has examined:

```
{
  "reservation": {
    "id": <string>,
    "restaurant_id": <string-or-int>,
    "reserved_at": <iso8601 UTC with explicit Z>,
    "modified_at": <iso8601 UTC with explicit Z>,
    "party_size": <int>,
    "status": <one of: booked | seated | completed | no_show | cancelled>
  }
}
```

Forbidden fields the adapter intentionally drops at canonicalization
(per `field_mapping.md` "Forbidden fields"): `reservation.guest.name`,
`reservation.guest.email`, `reservation.guest.phone`,
`reservation.notes`, `reservation.special_requests`, any payment /
card-on-file, any VIP / dietary tag.

## Scenarios

| File | Outcome | Adapter assertion | Sink assertion |
|---|---|---|---|
| `happy_path_reservation_booked.json` | accept | `_canonicalize` accepts; status=`booked`; UTC parse | row written; `business_date` resolves via per-location IANA |
| `happy_path_reservation_seated.json` | accept; drop guest PII | `_canonicalize` accepts; status=`seated`; guest.{name,email,phone} dropped | row written; persisted `rawPayload` excludes forbidden guest fields |
| `happy_path_reservation_completed.json` | accept | `_canonicalize` accepts; status=`completed`; `vendor_modified_at` strictly > `reservation_at` | row written; watermark advances on the post-meal `vendor_modified_at` |
| `happy_path_reservation_cancelled.json` | accept | `_canonicalize` accepts; status=`cancelled` (lower-cased); idempotency key includes `vendor_modified_at` so cancellation is a new row, not an in-place update | row written; prior `booked` row preserved |
| `sparse_path_no_modified_at.json` | accept | `_canonicalize` accepts; `vendor_modified_at` falls back to `reservation_at` per the assumed-shape contract (line 920-925 of adapter) | row written; watermark advances on fallback timestamp |
| `scenario_a_forged_signature.json` | reject | `OpenTableWebhookSignatureVerifier` returns mismatch (HMAC-SHA256 hex-lower over raw body fails) | no DB write to `reservation_facts` or `inbound_webhook_idempotency` |
| `scenario_b_malformed_payload.json` | reject | `_canonicalize` returns null on three simultaneous violations (`party_size` not int, `reserved_at` non-ISO, empty `status`) | no DB write; framework writes `connector_sync_log` |
| `scenario_c_future_dated_event.json` | reject | `command.sanityHook` returns false (rule `modified_in_future`) | no DB write; `sanity_log` + `connector_sync_log` rows written by framework |
| `scenario_d_oauth_near_expiry.json` | refresh path triggers (handled INTERNALLY by adapter transport, NOT the broker `oauth_refresh_cron`) | `OpenTableTransport.refresh` fires inline; new access+refresh pair persisted; inflight call retries once with `Bearer ot-access-token-rotated-v2` | `vendor_credentials` row updated atomically; audit `actor_kind = adapter_internal`; broker has no refresh closure registered for vendor `opentable` |
| `scenario_e_ambiguous_timestamp.json` | reject | `openTableTimestampPolicy.ambiguousConvention = AmbiguousTimestampConvention.refuse` blocks parse for offset-less ISO strings | no DB write; explicitly NOT silent fallback to "treat as UTC" |
| `scenario_f_cross_vendor_id_collision.json` | accept (no shadow-write) | `_canonicalize` accepts; OpenTable id may collide with a Libro id string but `vendor_id` segregates the namespace | sink upsert key `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)` writes a NEW row under `vendor_id = opentable` even when an `lbr-evt-7c2f-001` row exists under `vendor_id = libro` |
| `scenario_dst_spring_forward.json` | accept | UTC-Z parse trivially succeeds across the 2026-03-08 spring-forward window | row written; `business_date = 2026-03-08` for `America/New_York` |
| `scenario_cross_timezone.json` | accept | three rows under two locations parse cleanly | each row's `business_date` derived from the LOCATION's IANA tz, NOT host TZ or UTC date |

Total: 13 fixtures (4 happy + 1 sparse + 6 A-F + 2 time-edge).

## Notes

- **Credential type for scenario D:** OAuth (`authorization_code` flow,
  rotating refresh tokens). PER THE 2026-05-08 ADAPTER AUDIT
  (`docs/POST_HARDENING_FOLLOWUPS.md`, six non-broker-refresh vendors:
  ADP, Tock, Push Operations, **OpenTable**, SevenRooms, Agendrix),
  OpenTable's transport implementation handles refresh INTERNALLY
  rather than via the broker's `oauth_refresh_cron`. Phase 2 harness
  asserts no broker refresh closure is registered for vendor
  `opentable` and that rotation is observed via
  `OpenTableTransport.refresh` inside the adapter.

- **Timestamp resolver behavior:** OpenTable's documented timestamp
  policy is `AmbiguousTimestampConvention.refuse`
  (`openTableTimestampPolicy` in adapter, lines 160-170). Offset-less
  ISO strings MUST be rejected at the parse boundary, not silently
  treated as UTC. The live-sandbox slice may relax this to `asUtc`
  once observed payloads confirm the shape.

- **Idempotency-key shape:** Sink upsert key is the 4-tuple
  `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  per the vendor-adapter slice contract. The framework's inbound
  `inbound_webhook_idempotency` table uses
  `(vendor_id, operator_id, vendor_event_id)`. `vendor_id` segregation
  is non-negotiable across vendors per scenario F.

- **Status enum:** `{booked, seated, completed, no_show, cancelled}`
  (lower-case, assumed). The exact vocabulary is partnership-gated;
  the canonicalizer lower-cases whatever string lands. Live-sandbox
  slice fills in observed strings.

- **Forbidden guest fields are intentionally PRESENT in
  `happy_path_reservation_seated.json`** so Phase 2 harness can
  positively assert the canonicalizer drops them on persistence.
  Other happy-path fixtures omit the `guest` block to exercise the
  no-PII envelope.

- **Sourcing gaps (vendor doc partnership-gated):** every row marked
  "assumption" in `documentedPerOpentableV1FieldMapping` is sourced
  against the industry-standard reservation envelope, NOT against an
  observed OpenTable Partner API response. The exact endpoint paths,
  pagination shape, header names, OAuth scope strings, token
  lifetimes, signature header name, signature encoding, and webhook
  event vocabulary all carry `verify_in_live_sandbox: true`. The
  `8R.OT.live.sandbox` slice diffs each row against the first observed
  sandbox payload.
