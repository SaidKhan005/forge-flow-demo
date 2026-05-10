# ADP Pressure Fixtures

Vendor: ADP Workforce Now / Workforce Manager (vendor_id: `adp`)
Category: Labor

## Sources

- ADP developer-portal API catalog: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
  (publicly indexed; endpoint reference and sample payloads gated on
  the ADP Marketplace Developer Participation Agreement)
- ADP Marketplace partner page: <https://www.adp.com/marketplace>
- F&F doc pack: `docs/integrations/adp/api_consumed.md`,
  `field_mapping.md`, `webhook_signature.md`, `oauth_shape.md`,
  `partnership_status.md`, `live_verification_checklist.md`
- Adapter source: `lib/integrations/labor/adp_labor_adapter.dart`
  (`documentedPerAdpV1FieldMapping`, `_canonicalize`)
- Webhook verifier: `lib/integrations/labor/adp_webhook_signature_verifier.dart`
- Adapter test fixtures (cross-checked, not duplicated):
  `test/integrations/labor/fixtures/adp_punches_fixture.dart`,
  `test/integrations/labor/fixtures/adp_webhook_fixture.dart`

Adapter:    `lib/integrations/labor/adp_labor_adapter.dart`
Sink:       (proxy `OperatorScopedRepository<AdpCanonicalTimePunchFact>` — see `lib/infrastructure/persistence/postgres/`)
Verifier:   `lib/integrations/labor/adp_webhook_signature_verifier.dart`

## Sourcing posture — partner-only

ADP is partner-only. The developer-portal API catalog page (URL above)
is publicly indexed and lists the products, scopes, and event-
subscription mechanics, but the endpoint reference, sandbox, and
production credentials are released only to vendors that complete
the ADP Marketplace Developer Participation Agreement (12-24 weeks).
Every fixture in this directory is engineered against the published
shapes; every one carries a `verify_in_live_sandbox: true` analogue
through the doc pack and is flagged as a candidate for partner-portal
escalation.

## Scenarios

| File | Outcome | Adapter assertion | Sink assertion |
|---|---|---|---|
| `happy_path_time_card_submitted.json` | accept | `_canonicalize` returns a fact with `shift_start = 2026-05-04T15:00Z`, `shift_end = 2026-05-04T23:00Z`, `role_name = 'Server'`, `employee_id = 'G3WXX1Y2Z3A4B5C6'` | One row in `vendor_time_punch_facts` keyed by `(adp, operator, location, ADP-TE-20260504-000001, 2026-05-04T23:00:30Z)` |
| `happy_path_time_card_approved.json` | accept (replaces) | Same `vendor_entity_id`, newer `vendor_modified_at`; canonical fact projection wins on the newer row | New row in canonical table (idempotency UNIQUE on `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`) |
| `happy_path_time_card_modified.json` | accept (replaces) | Same `vendor_entity_id`, newer `vendor_modified_at`, `shift_end` adjusted to 22:45Z | New row; the read layer's projection picks the newest by `vendor_modified_at` |
| `happy_path_pay_data_event.json` | accept | WFM-shape worker — falls back to `worker.workAssignment.jobTitle`; `pay_data` block ignored (not in `documentedPerAdpV1FieldMapping`) | One row written; `wage_source = vendor` declaration only at V1 |
| `sparse_no_jobcode.json` | reject | `_canonicalize` returns null because neither `worker.position.position_title` nor `worker.workAssignment.jobTitle` is populated | No row written |
| `sparse_minimal_required.json` | accept | `_canonicalize` consumes the documented six rows of `documentedPerAdpV1FieldMapping` only — strips event metadata; field-mapping smoke test | One row written |
| `scenario_a_forged_signature.json` | reject | `AdpWebhookSignatureVerifier.verify` returns `valid: false, failureReason: 'ADP-Signature HMAC mismatch'` BEFORE dispatch | No row written |
| `scenario_b_malformed_payload.json` | reject | `_canonicalize` returns null on the type guards (`entry_date_time` is int; `worker` is string) | No row written; framework writes `connector_sync_log` row via dispatch unwind |
| `scenario_c_future_dated_event.json` | reject | Sanity hook (rule: `opened_in_future`) returns false; adapter drops the row | No row written; `sanity_log` row recorded |
| `scenario_d_oauth_near_expiry.json` | non-event | ADP runs `oauth_2.0_client_credentials + mutual_tls`. `oauth_refresh_cron` skips ADP rows (no `refresh_token` exists). mTLS cert rotation handled OUT-OF-BAND by ADP partner ops; F&F surfaces near-expiry as `connector_connection.status = 'error'` only | N/A — no fact write involved; assertion is on the absence of a refresh closure path |
| `scenario_e_ambiguous_timestamp.json` | reject | `adpTimestampPolicy.ambiguousConvention = AmbiguousTimestampConvention.refuse`; framework's `vendor_timestamp_sanity` rejects | No row written |
| `scenario_f_cross_vendor_id_collision.json` | accept (no shadow write) | Adapter writes one ADP row keyed by `(vendor_id='adp', vendor_entity_id='12345', vendor_modified_at)`; the colliding 7shifts row writes under `vendor_id='seven_shifts'` — disjoint slots | Two rows in canonical table — one per `vendor_id`; no merge |
| `scenario_dst_spring_forward.json` | accept | UTC wire shape resolves unambiguously across the 2026-03-08 America/Toronto skip; canonical fact stores UTC | One row; read-layer business_date deriver uses location's `restaurant_local_tz` |
| `scenario_cross_timezone.json` | accept | `business_date` derives from the location's `restaurant_local_tz` (America/Vancouver), not from the UTC wire shape's calendar day | One row; business_date = 2026-05-04 (Vancouver-local) even though UTC instant rolls into 2026-05-05 |

## Notes

### Scenario D — credential-rotation substitute

ADP is one of the six non-OAuth-refresh vendors listed in
`test/fixtures/vendor_payloads/README.md` ("Non-OAuth Vendor Note").
The substitute the Phase 2 harness asserts is:

1. `oauth_refresh_cron` (`lib/services/integration/oauth_refresh_cron.dart`)
   has zero ADP rows to refresh — `vendor_credentials.refresh_token`
   is null for `vendor_id='adp'`.
2. mTLS cert rotation is owned by ADP partner ops (out-of-band).
3. F&F surfaces cert near-expiry as `connector_connection.status =
   'error'` with the operator copy locked in
   `docs/integrations/adp/oauth_shape.md` "Edge cases".
4. There is no refresh-token closure to test; the binding-D harness
   asserts the *absence* of a refresh path for ADP, not a positive
   refresh outcome.

### Cross-vendor id collision — disjoint key slots

`vendor_entity_id` and `vendor_event_id` are namespaced by `vendor_id`
in every idempotency key the adapter touches:

- `vendor_time_punch_facts` UNIQUE = `(vendor_id, operator_id,
  vendor_entity_id, vendor_modified_at)`
- `inbound_webhook_idempotency` UNIQUE = `(vendor_id, operator_id,
  vendor_event_id)`

Cross-vendor employee identity is an explicit non-goal at V1 per
`docs/integrations/adp/field_mapping.md` and the Phase 8.S plan.

### Module disambiguation — out of scope here

ADP RUN refusal (`ModuleRefusalException` with `kAdpRunRefusalCopy`)
is a connect-time guard, not a payload-shape concern, so no fixture
is dedicated to it. The adapter unit tests pin the friendly-copy
constant against `docs/phases/phase_8/vendor_master_list.md`.

### Sourcing gaps for partner-portal escalation

When the ADP Marketplace DPA clears, the live sandbox slice will
diff each fixture against an observed sandbox response. Specific
items the partner doc must pin:

1. Exact `time_event.id` path (current assumption: `time_event.id`;
   alternates: `time_event.itemID` for some WFN endpoints,
   `timePunch.punchID` for WFM).
2. Whether `last_modified_date_time` carries an explicit `Z`
   universally or whether some endpoints emit naive ISO-8601 (drives
   the Scenario E refuse / accept policy).
3. Exact `ADP-Signature` header name + encoding + signing-secret
   round-trip mechanics.
4. Exact event-subscription event name (current assumption:
   `time.timeEvent.modify`).
5. mTLS cert rotation cadence + the operator-facing notice channel.
6. Whether the `pay_data` extension is present on the same event
   subscription or only on the pull endpoint.

Each of these is a candidate for the partner-portal escalation list
the operator-facing partnership lane owns
(`docs/integrations/adp/partnership_status.md`).
