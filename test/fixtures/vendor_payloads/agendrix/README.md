# Agendrix Pressure Fixtures

Sources:
- <https://developers.agendrix.com/en/documentation> (Agendrix Public REST API; developer portal)
- `docs/integrations/agendrix/api_consumed.md`
- `docs/integrations/agendrix/field_mapping.md`
- `docs/integrations/agendrix/oauth_shape.md`
- `docs/integrations/agendrix/webhook_signature.md`
- `docs/integrations/agendrix/partnership_status.md`
- `test/integrations/labor/fixtures/agendrix_punches_fixture.dart` (`documented_per_agendrix_v2`)

Adapter:                 `lib/integrations/labor/agendrix_labor_adapter.dart`
Webhook verifier:        `lib/integrations/labor/agendrix_webhook_signature_verifier.dart`
Production API client:   `lib/integrations/labor/agendrix_labor_production_api_client.dart`
Credential bridge:       `lib/integrations/labor/agendrix_credential_bridge.dart`
Sink:                    framework-bound `OperatorScopedRepository<T>` (no per-vendor sink class — Agendrix uses the generic labor sink path; Hard Promise #7 boundary).

API version pinned: **v2**. Retrieval date: **2026-05-08** (this corpus); doc-pack retrieval **2026-05-04**.

Webhook delivery: **none** (pollOnly). The signature verifier exists for defense-in-depth + future webhook-go-live and is exercised by Scenario A.

Auth mode: **OAuth 2.0 authorization code** with sliding refresh per `oauth_shape.md`. (Scenario D source note flags a discrepancy with `vendor_payloads/README.md`'s "static key" line for Agendrix; this corpus honors the per-vendor doc pack.)

Cross-vendor reconciliation: **explicit non-goal at V1**. Agendrix `user_id` and `time_entries[].id` are within-vendor namespaces only.

## Scenarios

| File | Outcome | Adapter assertion | Sink assertion |
|---|---|---|---|
| `happy_path_time_entry_completed.json` | accept | `_mapTimeEntryToCanonical` produces `{shift_start, shift_end, role_name='Server', employee_id='usr_98231', vendor_modified_at, covers_source='not_applicable', wage_source='app_fallback'}` | one canonical labor-fact row written; UNIQUE on `(vendor_id='agendrix', operator_id, vendor_entity_id='te_412901', vendor_modified_at)` |
| `happy_path_shift_published.json` | tolerated (out-of-scope event) | adapter never sees this — V1 only consumes `time_entries`, not `shifts`; framework router drops the event before reaching the adapter | no DB write |
| `happy_path_time_entry_modified.json` | accept | same `id=te_412901` with strictly later `updated_at`; canonical row replaced via UPSERT path | one row updated, `recordsWritten` returns true (per adapter `wrote = ...; if (wrote) recordsWritten += 1`); prior `shift_end` superseded by the new value |
| `happy_path_break_added.json` | accept (break ignored) | adapter ignores `breaks[]` (out of scope at V1 per `field_mapping.md`); canonical row is identical to the no-break shape | one canonical row, no break-derived columns |
| `sparse_no_role.json` | accept (`role_name = null`) | `position` is null → `position is Map` check fails → `role_name = null` | one canonical row with `role_name IS NULL` |
| `sparse_minimal_required.json` | accept (`role_name = null`) | `position` key absent → same null role path | one canonical row with `role_name IS NULL` |
| `scenario_a_forged_signature.json` | reject | `AgendrixWebhookSignatureVerifier.verify` returns `valid: false`, `failureReason` contains "mismatch" | no DB write (router never dispatches to adapter) |
| `scenario_b_malformed_payload.json` | reject | `_mapTimeEntryToCanonical` raises `FormatException` on `DateTime.parse('not-a-date')`; framework parse boundary catches the throw | no DB write; `connector_sync_log` `eventKind=parse_error` |
| `scenario_c_future_dated_event.json` | reject | `command.sanityHook(...)` returns `false` (`shift_start > now() + 1h`) | no DB write; `connector_sync_log` `eventKind=sanity_drop` |
| `scenario_d_oauth_near_expiry.json` | refresh path triggers | proxy OAuth refresh closure on `POST /v2/oauth/token` with `grant_type=refresh_token`; new `access_token` + new `refresh_token` (sliding) land; prior refresh token invalidated server-side | `vendor_credentials` row updated; audit log `oauth_refresh_success` |
| `scenario_e_ambiguous_timestamp.json` | reject | `DateTime.parse` succeeds (Dart accepts naive ISO) → sanity hook rejects with reason `ambiguous_timestamp_no_offset` per the documented `agendrix.asUtc` policy | no DB write; `connector_sync_log` `eventKind=sanity_drop` |
| `scenario_f_cross_vendor_id_collision.json` | accept (no shadow-write) | canonical UNIQUE includes `vendor_id` → Agendrix row at `vendor_id='agendrix'` does not collide with the pre-loaded `vendor_id='seven_shifts'` row sharing `te_412901` as opaque string | both canonical rows coexist; no overwrite of the 7shifts row |
| `scenario_dst_spring_forward.json` | accept (both rows) | UTC `start_time`s parse cleanly via `DateTime.parse(...).toUtc()`; `iana_timezone_converter.toBusinessDate(..., 'America/Toronto')` resolves both to `2026-03-08` | two canonical rows, both with `business_date = 2026-03-08` |
| `scenario_cross_timezone.json` | accept | resolver picks `connector_location_binding.iana_timezone = 'America/Vancouver'` over the operator's company-bound `America/Toronto` zone; `business_date = 2026-04-14` | one canonical row with `business_date = 2026-04-14` (NOT `2026-04-15`) |

## Notes

- **Scenario D credential type.** OAuth 2.0 sliding-refresh per
  `oauth_shape.md`, NOT static API key. The Phase 1 README's
  non-OAuth list says Agendrix is "static key"; that line predates
  the per-vendor doc pack (`oauth_shape.md` retrieval 2026-05-04) and
  the production API client. Treating the doc pack as the binding
  source. If a future audit confirms static-key, Scenario D's
  `_credential_state` block (and the source note) need re-shooting
  toward an out-of-band rotation event.
- **Webhook surface for Scenario A.** Agendrix v2 documents no
  webhook delivery surface; the signature verifier
  (`agendrix_webhook_signature_verifier.dart`) ships at lifecycle =
  `documented` against the assumed industry-standard SaaS partner
  convention. Scenario A exercises the verifier directly; the
  framework router gate (`capabilityProfile.webhookSupport =
  pollOnly`) is the belt; the verifier's HMAC-mismatch rejection is
  the suspenders.
- **Cross-vendor namespace.** `field_mapping.md` is explicit:
  Agendrix `user_id` and `time_entries[].id` are within-vendor
  namespaces. Scenario F asserts the canonical UNIQUE key keeps
  vendors isolated even when their opaque-string ids collide.
- **NFC normalization.** Adapter `_normalizeToNfc` runs on
  `role_name` and `employee_id` to preserve French accents
  (Quebec/Montreal operator base). Dart strings are already Unicode;
  the method documents intent and is a no-op today. Phase 2 adapter
  harness can assert by building a fixture with `position.name =
  'Hôte'` if Agendrix accent-handling lands as a follow-up
  observation.
- **Polling cadence.** No vendor-published recommended cadence.
  Adapter assumes 5 minutes per organization; soft cap is confirmed
  on the live slice.

## Sourcing gaps

1. **Agendrix v2 dev portal docs require sign-in.** All public URLs
   in this corpus point at the same root
   (<https://developers.agendrix.com/en/documentation>) because the
   detailed endpoint pages are gated behind the developer portal
   login. The detailed shapes here are the engineering-slice
   contract from `field_mapping.md` + the `agendrix_punches_fixture`
   constants, which were captured by the Phase 8.S engineer who held
   a developer-portal account. The `8.S.AG.live.sandbox` rolling
   slice diffs observed responses against these documented
   assumptions and bumps any drift back into `field_mapping.md`.
2. **No webhook delivery doc.** Scenario A's headers + body shape are
   the **assumed** industry-standard SaaS partner convention captured
   in the verifier source (`agendrix_webhook_signature_verifier.dart`
   line 14-23). Phase 8.gap-1 lifecycle = `documented`; live
   verification waits for Agendrix to publish webhooks (or for a
   sandbox environment that accepts a self-test payload).
3. **OAuth scope vocabulary not externally documented.** Scopes in
   Scenario D (`time_entries.read`, `users.read`, etc.) come from
   `oauth_shape.md` which captured them from the developer portal
   consent screen at retrieval — they are NOT exposed in a public
   scope catalog page.
4. **No vendor-published rate-limit numbers.** The "~120 req/min/org"
   figure in `api_consumed.md` is documented as **vendor-soft**;
   production limits land at `8.S.AG.live.prod`.
