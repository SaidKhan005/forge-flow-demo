# Humanity (TCP) Pressure Fixtures

Sources:
- `docs/integrations/humanity/api_consumed.md` (v1.0, retrieved 2026-05-04)
- `docs/integrations/humanity/field_mapping.md`
- `docs/integrations/humanity/webhook_signature.md` (N/A — no webhooks)
- `docs/integrations/humanity/oauth_shape.md` (N/A — auth shape in `api_consumed.md`)
- `docs/integrations/humanity/partnership_status.md`
- Vendor docs index: <https://platform.humanity.com/v1.0>
- Public dev docs: <https://developers.humanity.com/>

Adapter: `lib/integrations/labor/humanity_labor_adapter.dart`
Production HTTP client: `lib/integrations/labor/humanity_labor_production_api_client.dart`
Credential bridge: `lib/integrations/labor/humanity_credential_bridge.dart`
Reference fixtures (Dart): `test/integrations/labor/fixtures/humanity_punches_fixture.dart`

## Vendor specifics

- **Category**: Labor.
- **Auth mode**: `keyPaste` — Humanity v1 uses OAuth 2.0 Resource Owner Password Credentials grant (legacy username/password). Bearer token is stashed in `vendor_credentials` (pgcrypto envelope); plaintext password never reaches the adapter at runtime.
- **Webhook support**: `pollOnly` — Humanity v1 exposes NO webhook delivery surface. `handleWebhook` throws `UnsupportedError`. Operator-facing copy: "Humanity does not support webhooks; we sync every 5 minutes."
- **OAuth refresh closure**: wired per the post-wave audit (`humanity_credential_bridge.dart`). Tokens are documented as long-lived but the framework still consumes `expires_in` and triggers refresh on the next call when below the 300s threshold.
- **Wage source**: `wage_source = app_fallback` — Humanity exposes only role-level wage rates (`positions.pay_rate`), not per-employee. The adapter does NOT read `pay_rate` (it's in the forbidden list per `field_mapping.md`); the wage path falls back to the F&F wage generator.
- **Idempotency UNIQUE**: `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)` — `vendor_id="humanity"` namespaces every row.

## Scenarios

| File | Outcome | Adapter assertion | Sink assertion |
|---|---|---|---|
| `happy_path_shift_completed.json` | accept | `tryFromMap` returns DTO; `writeShiftFact` returns true | 1 canonical row with `vendor_id="humanity"`, `vendor_entity_id="9001"` |
| `happy_path_shift_published.json` | accept | 2 DTOs parsed; pagination loop consumes `next_cursor` | 2 canonical rows; watermark advances per-page |
| `happy_path_break_taken.json` | accept | parent shift row writes; `breaks[]` preserved on `rawPayload` only | 1 canonical row; `raw_payload` contains the breaks array verbatim |
| `happy_path_time_off_request.json` | accept (with known divergence) | both rows parse; `type=time_off` not filtered | 2 canonical rows; PHASE 2 FLAG: time-off row treated as 24h shift, recommend future filter on `type != "time_off"` |
| `sparse_no_role.json` | drop | `tryFromMap` returns null on missing `position_name` | no canonical row; malformed-payload counter advances |
| `scenario_a_forged_signature.json` | reject | `HumanityAuthException(401)` thrown by HTTP client | no canonical write; connection state → `reconnect_required` |
| `scenario_b_malformed_payload.json` | drop | `tryFromMap` returns null for both rows | no canonical write; malformed counter +2; watermark still advances |
| `scenario_c_future_dated_event.json` | reject | DTO parses cleanly; `command.sanityHook` returns false | no canonical write; sanity_log row recorded |
| `scenario_d_oauth_near_expiry.json` | accept (refresh triggers) | proxy detects `expires_in < 300s`; refresh closure fires before next poll | no canonical write directly; subsequent poll succeeds with refreshed bearer |
| `scenario_e_ambiguous_timestamp.json` | reject | naive timestamps parse local; downstream invariant catches drift | no canonical write for either row; field-mapping diff flags vendor regression |
| `scenario_f_cross_vendor_id_collision.json` | accept (no shadow-write) | DTO parses; `writeShiftFact` returns true on Humanity row | 2 canonical rows total (1 humanity + 1 pre-seeded seven_shifts); namespace isolation enforced |
| `scenario_dst_spring_forward.json` | accept | 3 DTOs parse; UTC durations preserved across DST jump | 3 canonical rows; downstream business_date bucketing uses local in_time date per row |
| `scenario_cross_timezone.json` | accept (operator zone wins) | 3 DTOs parse | 3 canonical rows; row 9702's downstream business_date = `2026-05-05` (Toronto), NOT 2026-05-04 (Vancouver) |

## Notes

- **Scenario D mapping for keyPaste vendors**: Humanity uses OAuth password-grant, so scenario D maps to a near-expiry access token + refresh closure (NOT mTLS / static-key rotation as for the 6 non-OAuth vendors per the README's "Non-OAuth Vendor Note").
- **Scenario A mapping for pollOnly vendors**: Humanity has NO webhook signature surface. Scenario A "forged signature" is therefore re-mapped to "invalid OAuth bearer presented on a poll request" — adapter rejects with `HumanityAuthException(401)`. This re-mapping is documented in `scenario_a_forged_signature.source.md`.
- **No PII in fixtures**: per `field_mapping.md` "Forbidden fields", `employees.email`, `employees.phone`, and `employees.name` (full name) are forbidden. `humanitySampleShift` in the Dart fixture file demonstrates the canonicalizer dropping those fields; this corpus does NOT include them so there's no risk of accidental persistence.
- **Operator-id placeholders**: `EMP-100`, `EMP-101`, etc. are placeholder employee ids that no real operator could match; numeric ids (`9001`, `9100`, etc.) sit well below any production id range.
- **Cursor token shape**: `eyJpZCI6OTAwMn0` etc. are documented as opaque server-issued cursors per `api_consumed.md`. The values used here are base64-encoded JSON for transparency; the adapter treats them as opaque strings.
