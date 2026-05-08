# QuickBooks Time Pressure Fixtures

**Vendor**: QuickBooks Time (formerly TSheets — Intuit-rebranded)
**Vendor ID**: `quickbooks_time`
**Category**: Labor
**Wave**: **Wave 1 launch vendor** (one of the trio with sandbox
credentials available; Phase 4 emulator E2E uses this vendor).

## Sources

- Vendor developer docs:
  <https://tsheetsteam.github.io/api_docs/>
- Intuit OAuth 2.0:
  <https://developer.intuit.com/app/developer/qbo/docs/develop/authentication-and-authorization/oauth-2.0>
- F&F integration doc pack: `docs/integrations/quickbooks_time/`
  (`api_consumed.md`, `field_mapping.md`, `oauth_shape.md`,
  `webhook_signature.md`, `partnership_status.md`,
  `live_verification_checklist.md`).

## Adapter / verifier

- Adapter:
  `lib/integrations/labor/quickbooks_time_labor_adapter.dart`
- Webhook signature verifier (defensive landing surface; QBT does not
  currently expose a webhook delivery surface — `webhookSupport =
  pollOnly`):
  `lib/integrations/labor/quickbooks_time_webhook_signature_verifier.dart`
- Production HTTP client:
  `lib/integrations/labor/quickbooks_time_labor_production_api_client.dart`
- Credential bridge:
  `lib/integrations/labor/quickbooks_time_credential_bridge.dart`

## Auth + transport

- Auth: OAuth 2.0 (`authorization_code` grant via Intuit OAuth, public
  self-serve at <https://developer.intuit.com> — no partnership gate).
  Access token TTL ~1h, refresh token TTL 100 days rotating.
- Transport: poll-only (vendor exposes no webhook surface for
  schedule/punch changes; F&F polls `GET /api/v1/timesheets` every
  5 minutes per `8.S` plan).
- Pagination: page-numbered (`?page=N`), `results.more` boolean flag.
- Rate limit: ~20 requests/sec per account (vendor-documented soft
  cap).

## Scenarios

| File | Outcome | Adapter / verifier assertion | Sink assertion |
|---|---|---|---|
| `happy_path_timesheet_clock_out.json` | accept | `mapTimesheetToCanonical` returns canonical fact with `shift_end != null`, `role_name = 'server'` (joined from supplemental jobcodes) | one canonical labor fact row written under `(operator_id, location_id, vendor_id='quickbooks_time', vendor_entity_id='901001')` |
| `happy_path_timesheet_modified.json` | accept (re-emit) | `last_modified` advances past prior watermark; `pollIncremental` re-emits row with new `vendor_modified_at` | upsert short-circuits the existing row's UNIQUE; new `vendor_modified_at` recorded |
| `happy_path_timesheet_approved.json` | accept | `locked = 1` + `approved = true` round-trip through `rawPayload`; canonical fields unchanged | one canonical labor fact row written; approval metadata not in canonical schema at V1 |
| `sparse_path_no_jobcode.json` | accept (sparse) | `mapTimesheetToCanonical` returns canonical fact with `role_name = ''` (jobcode-join lookup fails on `jobcode_id = 0`); `wage_source = app_fallback` because `users[].pay_rate = ''` | one canonical labor fact row written; `role_name` empty string |
| `scenario_a_forged_signature.json` | reject | `QuickBooksTimeWebhookSignatureVerifier.verify` returns `valid: false, failureReason: 'HMAC mismatch on intuit-signature header'` | no DB write |
| `scenario_b_malformed_payload.json` | reject | `mapTimesheetToCanonical` returns null (missing `id`); adapter drops at boundary | no DB write |
| `scenario_c_future_dated_event.json` | reject (sanity drop) | `command.sanityHook` returns `false` for `opened_in_future` (`shift_start > now() + 1h`); adapter skips canonical write | no DB write; `connector_sync_log 'sanity_drop'` |
| `scenario_d_oauth_near_expiry.json` | refresh path triggers | `oauth_refresh_cron` rotates the bearer token because `expires_in < 24h`; rotating refresh token issued | new credential persisted under `vendor_credentials`; old refresh token revoked |
| `scenario_e_ambiguous_timestamp.json` | reject | `_parseUtcInstant` policy `quickbooks_time.asUtc` refuses ambiguous shape (no `Z`, no `+/-HH:MM` offset); `mapTimesheetToCanonical` returns null | no DB write |
| `scenario_f_cross_vendor_id_collision.json` | accept (no shadow-write) | Idempotency UNIQUE `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)` partitions by `vendor_id`; QBT `id=901001` and a colliding 7shifts `id=901001` produce two distinct rows | two canonical labor fact rows written (one per `vendor_id`) |
| `scenario_dst_spring_forward.json` | accept | Vendor UTC instants unambiguous; `business_date` resolves via `iana_timezone_converter.toBusinessDate(zone: America/Vancouver)`; vendor `tz_str` is metadata, not authority | one canonical labor fact row written; `business_date = 2026-03-08` |
| `scenario_cross_timezone.json` | accept | Vendor `users[].tz_str = -04:00` (Toronto) but F&F location is Vancouver (`America/Vancouver`); resolver MUST use the location zone, not the vendor user zone | one canonical labor fact row written; `business_date = 2026-05-04` |

## Notes

- **Wave 1 launch vendor.** QuickBooks Time is one of three vendors
  with sandbox creds available at sprint start; Phase 4 emulator E2E
  exercises the full happy-path corpus end-to-end against a free
  Intuit developer trial company. The fixtures here are the verbatim
  documented shapes that drive that E2E.
- **Webhook surface absent.** Per `webhook_signature.md` (single-line
  N/A) and `api_consumed.md`, QBT does not document a webhook delivery
  surface usable for schedule/punch changes. Scenario A still lives
  here because the adapter ships
  `QuickBooksTimeWebhookSignatureVerifier` as a defense-in-depth
  surface against future router refactors and as the documented
  landing surface if Intuit ever releases QBT webhooks. The verifier
  uses `intuit-signature` (HMAC-SHA256, base64) with optional
  `intuit-t-hash` timestamp.
- **OAuth shape.** Scenario D models the substitute credential
  rotation path (Intuit's bearer-token response with low `expires_in`
  + `x_refresh_token_expires_in`) — not the analog substitution noted
  in the parent README's non-OAuth section, since QBT IS an OAuth
  vendor. Refresh token rotation: each refresh issues a NEW refresh
  token; the old one is revoked. Per `oauth_refresh_cron.dart`,
  proactive refresh fires when `token_expires_at < now() + 24h`.
- **Cross-vendor id collision.** QBT integer `id` values are small
  monotonic — collisions with 7shifts / ADP / Humanity / Agendrix /
  Push Operations integer ids are inevitable for any operator running
  two labor vendors during a migration window. Idempotency UNIQUE
  prefixes by `vendor_id`.
- **Module disambiguation.** This adapter only accepts the
  `time` QuickBooks module. The QBT-Accounting and QBT-Payroll modules
  surface `ModuleRefusalException` at connect time (no OAuth round-
  trip). The fixture corpus does not exercise this path because it is
  not a payload-shape concern; the adapter unit tests cover it.
