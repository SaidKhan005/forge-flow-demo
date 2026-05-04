# Revel Systems — Live Verification Checklist

**Vendor ID**: `revel`
**Engineering slice**: `8.RV` (lifecycle = `documented`)
**`*.live.sandbox` slice**: `8.RV.live.sandbox` — pending
**`*.live.prod` slice**: `8.RV.live.prod` — pending
**Lifecycle**: `documented` (will promote on first verification slice)

This checklist is filled in as the `*.live.sandbox` and `*.live.prod`
slices run. The engineering slice ships this file with all checkboxes
empty per `docs/contracts/per_vendor_doc_pack_contract.md`.

---

## Sandbox verification (`8.RV.live.sandbox`)

Cite the test that proved each check passed; cite the bounded fix
that resolved each check that failed.

- [ ] **Auth round-trip.** `client_credentials` exchange against
      `https://authentication.revelup.com/oauth/token` returns a
      JWT bearer for the QA-issued `client_id` / `client_secret`
      pair. Verify the access-token TTL matches the documented 24h.
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron picks up a token with
      `token_expires_at < now + 24h` and re-exchanges the credential
      pair. Verify `consecutive_refresh_failures` resets to 0 on
      success.
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull from
      `/external/integrations` returns under 30s with `fieldMapping`
      populated (`covers`, `opened_at`, `closed_at`, `actual_sales`,
      `vendor_entity_id`).
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill walks the
      paginated integrations list and writes ≥1 canonical fact row;
      `connector_sync_watermark.cursor_token` and
      `last_modified_seen` persist after each batch commit.
      Test: `<test_path>:<line>`
- [ ] **Polling resume.** Worker restart resumes from persisted
      cursor; observed `lastModifiedSeen` matches the row before
      the restart (no rewind, no skip).
      Test: `<test_path>:<line>`
- [ ] **Webhook signature verification.** Live `X-Revel-Signature`
      (HMAC-SHA1 hex over raw body) accepted; tampered signature
      rejected with 403. Confirm `WebhookSignatureVerification.timestamp`
      is null (Revel does not sign a timestamp).
      Test: `<test_path>:<line>`
- [ ] **Idempotency.** Same `order.id` + `updated_date` arriving
      twice (once via webhook, once via polling) → single canonical
      fact row.
      Test: `<test_path>:<line>`
- [ ] **Sanity hook.** Future-dated `created_date` from sandbox
      payload → `sanity_log` row + drop; no canonical fact written.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Observed sandbox response matches
      every entry in `documentedPerRevelV1` (in
      `lib/integrations/pos/revel_pos_adapter.dart`) and
      `documentedPerRevelV1FieldMapping` (in
      `test/integrations/pos/fixtures/revel_orders_fixture.dart`).
      Discrepancies (each as a bounded fix, not slice rebuild):
      - `<field>`: documented as X, observed Y. Fix: `<diff or PR ref>`
- [ ] **Disconnect → reconnect.** Watermark preserved across the
      cycle; no data gap on reconnect; re-issued JWT bearer scoped
      to the same establishment.
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** Admin route returns 200 for `operator_admin`,
      403 for `location_manager`. Verifies the
      `integrations.configure` permission key per
      `docs/contracts/auth_permission_key_catalog.md`.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First connect + first backfill commit
      flips `demo_mode_state.is_demo` to `false` per the demo-mode
      doctrine.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** `MetricCardNotYetAvailable`
      flips to live number; top-left honesty pill drops the
      corresponding degradation line per
      `docs/contracts/metric_card_honesty_contract.md`.
      Walkthrough: `docs/_walkthroughs/8.RV.live.sandbox.md`

**Sandbox verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `sandbox_verified` (when all rows ✅)

---

## Production verification (`8.RV.live.prod`)

Re-run the same checklist against operator-issued production
credentials. Same row shape; rows are independent (sandbox passing
does not imply prod passing).

- [ ] **Auth round-trip.** (re-run against production credential
      pair issued from operator's Revel admin portal)
      Test: `<test_path>:<line>`
- [ ] **Token refresh.**
      Test: `<test_path>:<line>`
- [ ] **Test connection.**
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.**
      Test: `<test_path>:<line>`
- [ ] **Polling resume.**
      Test: `<test_path>:<line>`
- [ ] **Webhook signature verification.**
      Test: `<test_path>:<line>`
- [ ] **Idempotency.**
      Test: `<test_path>:<line>`
- [ ] **Sanity hook.**
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.**
      Test: `<test_path>:<line>`
- [ ] **Disconnect → reconnect.**
      Test: `<test_path>:<line>`
- [ ] **Permission gate.**
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.**
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.**
      Walkthrough: `docs/_walkthroughs/8.RV.live.prod.md`

**Production verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `production_credentialed` (when all rows ✅)
**Date partnership cleared**: n/a (Revel is self-serve OAuth — see
`partnership_status.md`)
**Connect button live in admin widget**: YYYY-MM-DD

---

## First-operator-connect (automatic, no slice)

- [ ] First operator connect → lifecycle auto-promotes to
      `live_with_operators`.
- Date: YYYY-MM-DD
- Operator + location: `(<operator_id>, <location_id>)`
- Connected-operator chip in F&F Ops Console activated: YYYY-MM-DD
