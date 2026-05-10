# Push Operations Pressure Fixtures

Sources:
- `docs/integrations/push_operations/api_consumed.md`
- `docs/integrations/push_operations/field_mapping.md`
- `docs/integrations/push_operations/oauth_shape.md`
- `docs/integrations/push_operations/webhook_signature.md`
- `docs/integrations/push_operations/partnership_status.md`
- `docs/integrations/push_operations/live_verification_checklist.md`
- Vendor public landing: <https://developers.pushoperations.com/>

Adapter: `lib/integrations/labor/push_operations_labor_adapter.dart`
Sink:    `OperatorScopedRepository`-backed canonical writer (no
         vendor-specific `*_pos_postgres_sink.dart` because Push
         Operations is a labor adapter — labor adapters use the
         shared canonical labor sink, not a per-vendor sink).

Vendor lifecycle at sprint start: `documented` (per `lifecycle:
VendorLifecycle.documented` on the adapter's
`@IntegrationAdapter()`-equivalent capability profile).

## Vendor specifics

- **Auth mode**: `keyPaste` — partner-issued static **bearer token**
  (`Authorization: Bearer <token>`). No OAuth flow, no end-user
  authorization hop, **no refresh-token rotation**. Bearer rotation
  is out-of-band via the Push Operations Partner Portal; operators
  re-paste the new bearer in the F&F admin connect dialog.
- **Webhook support**: `pollOnly`. Push Operations does not document
  webhook delivery; `webhook_signature.md` is a single-line N/A and
  `handleWebhook` throws `UnsupportedError`. The framework router
  consults `capabilityProfile.webhookSupport` before dispatch.
- **Grant scope**: `operatorWide`. One bearer token covers the
  operator's entire Push Operations company across all of their F&F
  locations.
- **Endpoints**: `/api/v1/company`, `/api/v1/employees`,
  `/api/v1/positions`, `/api/v1/shifts`, `/api/v1/labour`. The
  `documented` slice ships against `/shifts` only; `/labour` is
  documented for `8.S.PU.live.*` slices.
- **Pagination**: `page` + `limit` (default `limit=100`) on the
  standard list endpoints; `/labour` uses date-range pagination with
  a 2-day max window.
- **Refresh closure**: NONE. The proxy's
  `proxy.refresh_expiring_inbound_vendor_tokens()` cron is a no-op
  for `vendor_id = 'push_operations'` per
  `docs/POST_HARDENING_FOLLOWUPS.md` "Confirmed-clean" line 453.

## Scenarios

| File | Outcome | Adapter assertion | Sink assertion |
|---|---|---|---|
| `happy_path_punch_clock_out.json` | accept | `_mapShiftToCanonical`-equivalent labour mapping; `clocked_out_at` populated | one canonical fact row written |
| `happy_path_schedule_published.json` | accept | three rows mapped via `_mapShiftToCanonical`; field paths match `documented_per_push_operations_v1` | three canonical fact rows written |
| `happy_path_punch_modified.json` | accept (upsert) | same `vendor_entity_id = '700401'` but newer `vendor_modified_at` | upsert (UNIQUE on `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`) |
| `happy_path_break_event.json` | accept (partial) | in-progress shift with active break; `clocked_out_at = null` handled without crash | partial fact row OR deferred write (test asserts no crash) |
| `sparse_no_role.json` | accept | `position_name = null` AND `position_id = null`; adapter writes `role_name = null` (no synthesis) | one canonical fact row with `role_name IS NULL` |
| `sparse_minimal_required.json` | accept | only the six documented field paths present; canonical write succeeds | one canonical fact row written |
| `scenario_a_forged_signature.json` | reject | **Substitute path**: tampered bearer -> 401 -> connection-state machine flips to `error` after 3 consecutive failures (Push has no webhook signing per `webhook_signature.md`) | no DB write; `connector_sync_log` records the auth failure |
| `scenario_b_malformed_payload.json` | reject | `_parseUtcInstant` raises `FormatException`; type errors on `id` / `position_name`; missing-field guards | no DB write; `connector_sync_log` records `parse_error` |
| `scenario_c_future_dated_event.json` | reject (sanity drop) | `command.sanityHook(...)` returns `false` for `start_at > now() + 1h` | no DB write; `sanity_log` row + `connector_sync_log` `sanity_drop` |
| `scenario_d_oauth_near_expiry.json` | refresh = N/A; substitute = bearer rotation | NO refresh closure registered for `push_operations`; revoked bearer -> 401 -> `error` state; new bearer -> 200 -> `connected` | no spurious DB writes during rotation; watermark preserved |
| `scenario_e_ambiguous_timestamp.json` | reject | `start_at` / `end_at` / `updated_at` lack explicit `Z` and offset; `push_operations.asUtc` policy refuses (does NOT silently fall back) | no DB write; `connector_sync_log` records `timestamp_policy_violation` |
| `scenario_f_cross_vendor_id_collision.json` | accept (both rows persist) | proxy idempotency-key namespace is vendor-scoped; canonical UNIQUE leads with `vendor_id` | two distinct canonical rows persisted: `(push_operations, ..., '800101')` AND `(seven_shifts, ..., '800101')` — no shadow-write |
| `scenario_dst_spring_forward.json` | accept | UTC instants parse cleanly; `business_date` resolved through IANA tz converter; spring-forward gap handled via UTC durations | two canonical rows on `business_date = 2026-03-08` |
| `scenario_cross_timezone.json` | accept | resolver picks **location** timezone, not operator HQ; both shifts land on `business_date = 2026-05-02` via different IANA conversions | two canonical rows differing only on `(operator_id, location_id)` |

## Notes

- **Scenario A substitute**: Push Operations has no webhook surface,
  so a literal "forged HMAC signature" payload is not authorable.
  The fixture substitutes the analogous reject path: a tampered
  (non-partner-issued) bearer presented to `/api/v1/shifts` returns
  401 and the connection-state machine flips to `error` after 3
  consecutive failures. Phase 2A harness must recognise the
  substitute by reading the `_pressure_test_envelope.scenario` /
  `substitute_assertion` keys on the fixture.
- **Scenario D substitute**: Push Operations bearer is a
  **partner-issued static credential**. There is no programmatic
  refresh hop; the OAuth refresh worker has no closure registered
  for `push_operations`. Bearer rotation is **out-of-band** via the
  partner portal and operators re-paste the new bearer in the F&F
  admin connect dialog. The fixture documents the three-state
  transition (before / revoked-old / new) and the harness asserts
  no refresh closure runs for this vendor.
- **Webhook fixtures**: not authored. Webhook signature verification
  is N/A per `webhook_signature.md`; the engineering slice already
  covers `handleWebhook -> UnsupportedError` via
  `test/integrations/labor/push_operations_labor_adapter_test.dart`.
- **Labour endpoint pagination**: `/api/v1/labour` uses date-range
  pagination with a 2-day max window (distinct from the page+limit
  shape on the other list endpoints). The bridge worker batches the
  60-day backfill in 2-day chunks. Phase 2A harness should drive
  `pollIncremental` against a 2-day window to exercise this shape;
  the labour-side fixtures (`happy_path_punch_clock_out`,
  `happy_path_punch_modified`, `happy_path_break_event`) all carry
  the documented page+limit envelope so Phase 2A can validate both
  shapes.

## Sourcing gaps (escalate to partner-portal)

The Push Operations developer portal (developers.pushoperations.com)
is partner-gated. The following could not be verified from the
public surface and are reconstructed from the per-vendor doc pack
already retrieved 2026-05-04 + the adapter test fixture:

- Exact response envelope for `/api/v1/labour` (envelope shape
  `{ "labour": [...], "page": N, "limit": N, "total": N }` is
  inferred from the documented page+limit pattern shared with
  `/employees` / `/positions` / `/shifts`; the `total` count
  appears in published responses but could not be confirmed against
  a live `/labour` page).
- Exact `breaks[]` sub-record schema on labour entries (`type`
  field with values `meal` / `rest` is inferred from common Push
  Operations workforce-management terminology; not pinned to a
  numbered API doc URL).
- Exact 401 response body shape on revoked-bearer (the
  `{ "error": "unauthorized", "message": "..." }` shape is the
  documented vendor convention but not pinned to a numbered
  endpoint doc URL).

These gaps should be re-confirmed during the `8.S.PU.live.sandbox`
slice; bounded fixes (not slice rebuild) per
`live_verification_checklist.md` "Field-mapping diff" row.

## Cross-references

- Sprint plan: `docs/_execution/2026-05-08_pressure_preview_v1_plan.md`
- Format spec: `test/fixtures/vendor_payloads/README.md`
- Findings doc: `docs/_execution/2026-05-08_pressure_preview_findings.md`
- Adapter test fixtures (engineering slice):
  `test/integrations/labor/fixtures/push_operations_punches_fixture.dart`
- Adapter source:
  `lib/integrations/labor/push_operations_labor_adapter.dart`
