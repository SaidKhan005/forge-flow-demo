# Lightspeed Restaurant K-Series — Live Verification Checklist

**Vendor ID**: `lightspeed_lsk`
**Engineering slice**: `8.LSK`
**`*.live.sandbox` slice**: `8.LSK.live.sandbox` — pending
**`*.live.prod` slice**: `8.LSK.live.prod` — pending
**Lifecycle**: `documented` (will promote on first verification slice)

This checklist is filled in as the `8.LSK.live.sandbox` and
`8.LSK.live.prod` slices run. The engineering slice (`8.LSK`) ships
this file with all checkboxes empty. Per
`docs/contracts/per_vendor_doc_pack_contract.md`, every row below is
present.

---

## Sandbox verification (`8.LSK.live.sandbox`)

Cite the test that proved each check passed; cite the bounded fix
that resolved each check that failed.

- [ ] **Auth round-trip.** OAuth start → callback → token issued
      successfully against the trial environment
      (`https://api.trial.lsk.lightspeed.app/oauth/token`).
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron extends a near-expiry access
      token (25-minute TTL) by exchanging the rotating refresh token.
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull from
      `GET /f/v2/business-location/{id}/sales` returns under 30s with
      `fieldMapping` populated (covers, opened_at, closed_at,
      actual_sales).
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill writes ≥1
      canonical fact row from the trial sandbox; watermark persists
      per batch.
      Test: `<test_path>:<line>`
- [ ] **Polling resume.** Worker restart resumes from the persisted
      `connector_sync_watermark.cursor_token` with no rewind, no
      skip.
      Test: `<test_path>:<line>`
- [ ] **Webhook signature verification.** Live signature on a
      `PUT /o/wh/1/webhook`-registered endpoint accepted; tampered
      signature rejected with 403.
      Test: `<test_path>:<line>`
- [ ] **Idempotency.** Same vendor `event_id` arriving twice → single
      canonical write; idempotency UNIQUE conflict observed.
      Test: `<test_path>:<line>`
- [ ] **Sanity hook.** Future-dated event from sandbox → `sanity_log`
      row + drop, no canonical fact write.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Observed sandbox response matches
      every `documented_per_lightspeed_lsk_f_v2_2026_05` constant in
      `test/integrations/pos/fixtures/lightspeed_lsk_orders_fixture.dart`.
      Discrepancies (each as a bounded fix, not slice rebuild):
      - `<field>`: documented as X, observed Y. Fix: `<diff or PR ref>`
- [ ] **Disconnect → reconnect.** Watermark preserved across cycle;
      no data gap on reconnect; webhook re-registers cleanly.
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** `location_manager` 403; `operator_owner`
      200 on the connect / disconnect routes.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First connect + first backfill commit
      flips `demo_mode_state.is_demo` to `false` for the
      (operator, location) pair.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** `MetricCardNotYetAvailable`
      flips to live number for Sales / Covers / PPA cards on the
      Shift dashboard; the top-left honesty pill drops the
      "Sales: not yet connected" / "Covers: not yet connected"
      lines.
      Walkthrough: `docs/_walkthroughs/8.LSK.live.sandbox.md`

**Sandbox verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `sandbox_verified` (when all rows ✅)

---

## Production verification (`8.LSK.live.prod`)

Re-run the same checklist against production credentials. Same
table shape; rows are independent (sandbox passing does not imply
prod passing — vendor sandboxes sometimes lie).

- [ ] **Auth round-trip.** OAuth start → callback → token issued
      successfully against production
      (`https://api.lsk.lightspeed.app/oauth/token`).
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron extends a near-expiry token
      against production.
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull returns under 30s with
      `fieldMapping` populated.
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill writes ≥1
      canonical fact row; watermark persists per batch.
      Test: `<test_path>:<line>`
- [ ] **Polling resume.** Worker restart resumes from persisted
      cursor.
      Test: `<test_path>:<line>`
- [ ] **Webhook signature verification.** Live signature accepted;
      tampered signature rejected with 403.
      Test: `<test_path>:<line>`
- [ ] **Idempotency.** Same vendor event ID twice → single canonical
      write.
      Test: `<test_path>:<line>`
- [ ] **Sanity hook.** Future-dated event from production →
      `sanity_log` row + drop.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Observed production response matches
      every `documented_per_lightspeed_lsk_f_v2_2026_05` constant.
      Test: `<test_path>:<line>`
- [ ] **Disconnect → reconnect.** Watermark preserved; no data gap.
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** `location_manager` 403; `operator_owner`
      200.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First connect + first backfill commit
      flips `demo_mode_state.is_demo` to `false`.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** `MetricCardNotYetAvailable`
      flips to live number; honesty pill drops the corresponding
      degradation lines.
      Walkthrough: `docs/_walkthroughs/8.LSK.live.prod.md`

**Production verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `production_credentialed` (when all rows ✅)
**Date partnership cleared**: YYYY-MM-DD (cite `partnership_status.md`)
**Connect button live in admin widget**: YYYY-MM-DD

---

## First-operator-connect (automatic, no slice)

- [ ] First operator connect → lifecycle auto-promotes to
      `live_with_operators`.
- Date: YYYY-MM-DD
- Operator + location: `(<operator_id>, <location_id>)`
- Connected-operator chip in F&F Ops Console activated: YYYY-MM-DD
