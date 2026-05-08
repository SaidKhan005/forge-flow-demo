# 7shifts Pressure Fixtures

Sources:
- Per-vendor doc pack: `docs/integrations/seven_shifts/`
  (`api_consumed.md`, `field_mapping.md`, `oauth_shape.md`,
  `webhook_signature.md`, `partnership_status.md`)
- Vendor public docs (developer portal):
  <https://developers.7shifts.com>
- Pricing tier reference: <https://www.7shifts.com/pricing>

Adapter: `lib/integrations/labor/seven_shifts_labor_adapter.dart`
Verifier: `lib/integrations/labor/seven_shifts_webhook_signature_verifier.dart`
Sink (Phase 8R): TBD — labor sink pending Wave G

Vendor ID: `seven_shifts`
Category: `labor`
Auth mode: `oauth` (authorization_code, rotating refresh)
Webhook support: `autoRegister` (Gourmet plan only — fallback to
polling on lower tiers)
API version pinned: `v2-2026-05-04`

## Scenarios

| File | Outcome | Adapter assertion | Sink / framework assertion |
|---|---|---|---|
| `happy_path_time_punch_clock_out.json` | accept | `_canonicalizePunch` populates `vendor_entity_id`, `employee_id`, `shift_start`, `shift_end`, `is_approved=true`, `role_name='server'`, `shift_id`, `vendor_modified_at` | canonical fact upserted under `(seven_shifts, op, 712001, 2026-05-04T00:05:00Z)` |
| `happy_path_shift_published.json` | accept | `shift.created` event surfaces published planned shift; canonical fact for shift slot recorded by Lane B's schedule sink (post-V1) | sink records planned shift and indexes by `shift_id=887801` |
| `happy_path_shift_swap.json` | accept | `shift.updated` event with same `shift.id` but new `user_id` mutates the schedule slot's assignee; canonical fact upserts on `(seven_shifts, op, 887801, modified)` | sink replaces the assignee for shift slot 887801 (no duplicate slot) |
| `happy_path_break_event.json` | accept | breaks array tolerated; canonical fact emits `is_approved=true` per usual; break boundaries are documented but not yet persisted into the canonical fact (Phase 8 V1 scope) | upsert succeeds; break-aware aggregation deferred |
| `sparse_no_role.json` | accept (degraded) | `role` is null → `roleName` defaults to `''`; `shift_id` null → `wage_provenance = vendor_seven_shifts_dollars_unavailable_target_wage_substituted`; open punch (`clocked_out: null`) → canonical `shift_end` is null | upsert succeeds with degraded provenance; next poll re-emits when role + clock-out land |
| `sparse_minimal_required.json` | accept (degraded) | only required fields present; canonicalizer produces a complete fact with `role_name=''`, `shift_id=null`, `is_approved=false` | upsert succeeds; substituted-wage provenance |
| `scenario_a_forged_signature.json` | reject | `SevenShiftsWebhookSignatureVerifier.verify` returns `valid=false`, `failureReason="X-7Shifts-Hmac-SHA256 HMAC mismatch"` (constant-time compare) | inbound handler aborts before adapter; no DB write |
| `scenario_b_malformed_payload.json` | reject | `_canonicalizePunch` returns null (missing `id`, unparseable `clocked_in`); framework drops at parse boundary | no canonical fact written |
| `scenario_c_future_dated_event.json` | reject | framework `opened_in_future` sanity guard fires; adapter `handleWebhook` is not invoked | no canonical fact written |
| `scenario_d_oauth_near_expiry.json` | refresh path triggers | `oauth_refresh_cron` scans `vendor_credentials WHERE token_expires_at < now() + 24h`, calls `POST /v2/oauth/token` with `grant_type=refresh_token`, rotates ciphertext atomically | new access + rotating refresh token persisted under same `connector_connection.id`; old refresh revoked |
| `scenario_e_ambiguous_timestamp.json` | reject | `sevenShiftsTimestampPolicy` binds `AmbiguousTimestampConvention.refuse` — timestamps without `Z`/offset are dropped at parse boundary | no canonical fact written; protects against silent UTC fallback |
| `scenario_f_cross_vendor_id_collision.json` | accept (namespace-isolated) | adapter writes a NEW canonical fact under `vendor_id='seven_shifts'`; idempotency UNIQUE includes `vendor_id` so the existing QuickBooks Time row (also `entity_id=712001`) is NOT shadow-written | sink stores both rows, keyed by `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)` |
| `scenario_dst_spring_forward.json` | accept | UTC instants parsed verbatim (`DateTime.tryParse(...).toUtc()`); 4h 30m UTC delta is the truth, not the wall-clock subtraction | downstream `iana_timezone_converter.toBusinessDate` computes business_date in `America/Toronto` correctly across the 02:00→03:00 jump |
| `scenario_cross_timezone.json` | accept | adapter ignores nested `time_punch.location.timezone` and persists UTC instants verbatim | downstream resolver uses F&F location-bound IANA (`America/Vancouver`) for business_date, NOT the vendor-supplied `America/Toronto`; resolver-bug test |

## Notes

### Scenario D — credential rotation

7shifts uses OAuth 2.0 `authorization_code` with rotating refresh
tokens per the developer reference. The Scenario D fixture is the
**OAuth near-expiry refresh** path (not a static-key rotation), per
the 2026-05-08 confirmed-clean OAuth refresh closure in
`docs/POST_HARDENING_FOLLOWUPS.md`. The fixture body is the documented
`POST /v2/oauth/token` response shape; the `_fixture_envelope` block
describes the existing-credential state that triggers the cron at
`token_expires_at < now() + 24h`.

### Scenario A — signature shape

Header: `X-7Shifts-Hmac-SHA256` (lower-cased per framework header
normalization to `x-7shifts-hmac-sha256`). Encoding: base64.
Algorithm: HMAC-SHA256 over the raw request body bytes. The
verifier is in
`lib/integrations/labor/seven_shifts_webhook_signature_verifier.dart`
and uses `constantTimeBytesEquals` to avoid timing oracles. The
fixture's `_fixture_envelope` carries `raw_body` (verbatim string),
`signing_secret`, and the forged base64 signature; Phase 2 harness
calls `verify(rawBody: utf8.encode(raw_body), headers, signing_secret, now)`
and asserts `valid=false`.

### Scenario E — ambiguous timestamp

The 7shifts v2 reference documents every timestamp as ISO 8601 with
explicit `Z`. `sevenShiftsTimestampPolicy` binds
`AmbiguousTimestampConvention.refuse` so that a vendor-side
regression (timestamps without `Z`/offset) drops at the parse
boundary instead of being silently treated as UTC. Once
`8.S.7S.live.sandbox` confirms observed sandbox payloads always
carry `Z`, the policy may re-bind to `asUtc` — but Scenario E's
expected outcome stays "reject" because the test is about refusing
ambiguity, not about the runtime convention.

### Scenario F — namespace isolation

The framework's idempotency UNIQUE is
`(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`.
Numeric id collisions across vendors are plausible (both 7shifts
and QuickBooks Time use integer ids). The sink test pre-loads a
QuickBooks Time row at `(quickbooks_time, op, 712001, ...)` and
asserts the 7shifts payload inserts as a new row at
`(seven_shifts, op, 712001, ...)` rather than shadow-writing.

### Identifiers

All operator/location/employee/role/shift/company ids are placeholder
integers (e.g., 4242, 5501, 99001, 712001) chosen to be obviously
fictional — no real 7shifts customer ids could match. Per fixture
sourcing rule 4, where vendor docs use placeholder numerics
(99001-style), this corpus follows the same convention.

### Forbidden fields

The adapter MUST NOT persist `user.email`, `user.phone`, `user.dob`,
`user.ssn`, `user.payroll_id`, or any payment / direct-deposit
field per `docs/integrations/seven_shifts/field_mapping.md`
"Forbidden fields". The happy-path fixtures intentionally OMIT a
nested `user` block so the canonicalizer's positive sample stays
clean; the existing
`test/integrations/labor/fixtures/seven_shifts_punches_fixture.dart`
`sevenShiftsSamplePunch` fixture carries the forbidden block to
verify the drop-on-persist behavior — the corpus here does not
duplicate that role.
