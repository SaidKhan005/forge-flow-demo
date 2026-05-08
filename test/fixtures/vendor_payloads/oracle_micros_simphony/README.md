# Oracle MICROS Simphony Pressure Fixtures

Sources:

- Vendor public docs: <https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/>
  (Simphony Transaction Services Gen 2 — STSGen2 Cloud API)
- Per-vendor doc pack: `docs/integrations/oracle_micros_simphony/`
  (`api_consumed.md`, `field_mapping.md`, `oauth_shape.md`,
  `webhook_signature.md`, `partnership_status.md`,
  `live_verification_checklist.md`)
- Adapter: `lib/integrations/pos/oracle_micros_simphony_pos_adapter.dart`
- Existing test fixture (mirror): `test/integrations/pos/fixtures/oracle_micros_simphony_checks_fixture.dart`
- Sink: `lib/integrations/pos/` — sink class TBD; the adapter writes
  through `OracleMicrosSimphonyCanonicalSink` interface today.

## Partner-only vendor — sourcing posture

**Oracle MICROS Simphony is partner-only.** Sandbox + production
credentials are issued solely through the Simphony Partner Integration
Program (`partnership_status.md` — application `not_started` at slice
ship; 8-16 week lead time). The Gen2 STSGen2 Cloud API public docs
exist on `docs.oracle.com` but are sparse compared to self-serve POS
vendors. This corpus is built from:

1. The public Gen2 docs (docs.oracle.com/.../omsstsg2api/) — the
   primary source for envelope shape, field paths, auth flow.
2. The F&F adapter (`oracle_micros_simphony_pos_adapter.dart`) and the
   in-repo fixture constants
   (`documented_per_oracle_micros_simphony_v2`,
   `sampleSimphonyGuestCheck`, `secondSimphonyGuestCheck`,
   `futureDatedSimphonyGuestCheck`) — Wave B engineering captured
   these from the same vendor docs at 2026-05-05; mirrored here.
3. The doc pack at `docs/integrations/oracle_micros_simphony/` — every
   field, every assumption, every ambiguity call.

There are NO third-party SaaS-integration docs cited in this corpus —
the vendor doc + the adapter's already-vetted assumptions cover the
shape. **Phase 5 escalation:** when partner activation lands,
re-verify every fixture against a real sandbox response and bump the
fixture constants if shape drifts.

Sourcing gaps marked with top-level `"_sourcing_gap"` JSON key:

- `scenario_a_forged_signature.json` — Simphony has no webhook surface;
  the fixture documents the substitute (vendor 401 on poll, partner-
  portal credential revocation).

## Scenarios

| File | Outcome | Adapter assertion | Sink assertion |
|---|---|---|---|
| `happy_path_check_closed.json` | accept | `_mapGuestCheckToCanonical` produces canonical fact with `covers=5`, `actual_sales=124.85`, `covers_source="direct"` | UPSERT on `(vendor_id, operator_id, vendor_entity_id="412901", vendor_modified_at)` writes one row |
| `happy_path_payment.json` | accept | Canonical fact written from `header.*`; `payments[]` ignored at canonical level (PCI scope) | One canonical row; `raw_payload` JSONB carries `payments[]` |
| `happy_path_void.json` | accept | `actual_sales=0.00`, `voidFlag` ride on `raw_payload` | One canonical row; idempotent on later updates to `lastUpdatedUTC` |
| `sparse_no_covers.json` | accept | `covers=null`; metric pipeline marks provenance `vendor_omitted` | Canonical write succeeds with `covers IS NULL` |
| `sparse_minimal_required.json` | accept | Smallest-legal envelope writes successfully | Canonical write succeeds |
| `scenario_a_forged_signature.json` | reject (substitute path) | Adapter treats vendor 401 as auth failure; refresh once; 3-strike → connection.status=error | No DB write; audit row + `connector_sync_log` kind=`oauth_refresh_failed` |
| `scenario_b_malformed_payload.json` | reject | `header.lastUpdatedUTC` missing → `vendor_modified_at = null`; idempotency UNIQUE refuses | No DB write; `connector_sync_log` kind=`parse_drop` |
| `scenario_c_future_dated_event.json` | reject | `sanityHook` returns false (`opened_in_future`); adapter increments `sanityDropped` and skips canonical write | No DB write; `sanity_log` row written |
| `scenario_d_oauth_near_expiry.json` | refresh | `pg_cron` refreshes proactively (24h horizon) OR adapter retries once on reactive 401; canonical fact lands | One canonical row + `connector_sync_log` kind=`oauth_refresh` |
| `scenario_e_ambiguous_timestamp.json` | reject | Adapter refuses timestamps without explicit `Z` per `oracle_micros_simphony.asUtc` policy; `_parseUtcInstant` returns null/refuses | No DB write; `sanity_log` rule=`ambiguous_timestamp` |
| `scenario_f_cross_vendor_id_collision.json` | namespace_isolated | Same `chkNum=412901` collides with Toast `displayNumber`; canonical UNIQUE namespaces on `vendor_id` so both rows coexist | TWO canonical rows under different `vendor_id` |
| `dst_spring_forward.json` | accept_with_iana_resolution | Both timestamps parse cleanly (UTC explicit-Z); IANA-converter projects `cmplOrClsdUTC=2026-03-08T08:30:00Z` to `business_date=2026-03-07` (or 2026-03-08 per documented cutoff rule) | One canonical row; `business_date` matches IANA result |
| `cross_timezone_operator_toronto_vendor_pacific.json` | accept_with_iana_resolution | Framework uses `restaurant_locations.iana_zone="America/Vancouver"` (location), NOT operator HQ; `business_date=2026-05-02` | One canonical row; business_date computed from location's zone |

Total fixtures: 13 (3 happy + 2 sparse + 6 adversarial A-F + 2 time edges).

## Notes

### Webhook surface (none)

Simphony does not document webhook delivery. The adapter's
`webhookSupport = pollOnly` and `handleWebhook` throws `UnsupportedError`
at `oracle_micros_simphony_pos_adapter.dart:411-419`. Scenario A is a
sourcing gap — fixture documents the substitute auth-failure path
(vendor 401 / credential revocation). See `webhook_signature.md`
(single-line N/A).

### Auth (corrects the sprint prompt)

The Phase 1 prompt for this vendor said "Simphony uses static API key +
mTLS internally per audit". Per `oauth_shape.md` and the adapter source
(`capabilityProfile.authMode = VendorAuthMode.oauth`), **Simphony's
documented public Gen2 API uses OAuth 2.0 client_credentials grant, not
mTLS**. Bearer access token, ~1h TTL, refresh by re-running the token
endpoint with the durable client secret. The mTLS attribution likely
crossed wires with ADP (which IS mTLS per the audit). Scenario D is
therefore the standard OAuth near-expiry refresh path; this README and
the fixture's `.source.md` document the correction.

### Per-location grant

Simphony binds OAuth credentials per `locRef`. Each F&F location runs
its own OAuth flow; the bound `locRef` is stored in
`connector_connection.metadata.simphony_loc_ref`. The cross-timezone
fixture relies on this — the location's IANA zone (Vancouver) drives
business-date resolution, not the operator's HQ zone (Toronto).

### Partnership escalation list (for Phase 5)

These scenarios will need partner-portal verification once activation
clears:

- `scenario_a_forged_signature.json` — confirm whether a future Gen2
  revision adds webhook delivery; revisit if so.
- `scenario_d_oauth_near_expiry.json` — confirm production token TTL
  matches the documented sandbox value (~1h); confirm `expires_in`
  field is returned on token issuance.
- `scenario_e_ambiguous_timestamp.json` — confirm production never
  returns timestamps without explicit `Z` (the live slice
  `8.OR.live.sandbox` carries this assertion).
- `dst_spring_forward.json` / `cross_timezone_operator_toronto_vendor_pacific.json`
  — production multi-location partner test fixture to verify per-
  `locRef` zone binding works as documented.

### Field mapping (mirror)

Every canonical-fact field in this corpus maps as documented in
`docs/integrations/oracle_micros_simphony/field_mapping.md` and the
fixture constant
`documented_per_oracle_micros_simphony_v2` at
`test/integrations/pos/fixtures/oracle_micros_simphony_checks_fixture.dart`.
The 2026-05-05 falsehood correction (covers = `items[].header.guestCount`,
not `numOfGst` / `numberOfGuests`) is honored throughout.

### Fixtures NOT included

- **`happy_path_employee_clock.json`** — out of scope. POS adapter
  does not consume labor data per `field_mapping.md` "Forbidden
  fields" (`employeeId` excluded); labor lives in Phase 8.S
  (scheduling-vendor lane). The 6 labor vendors in the sprint roster
  cover this.
- **Webhook-driven happy paths** — Simphony does not webhook. All
  happy paths are poll-shape envelopes (`items[]` + `nextCursor`).
