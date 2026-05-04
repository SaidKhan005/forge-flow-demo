# Square — Live Verification Checklist

**Vendor ID**: `square`
**Engineering slice**: `8.SQ`
**`*.live.sandbox` slice**: `8.SQ.live.sandbox` — pending
**`*.live.prod` slice**: `8.SQ.live.prod` — pending
**Lifecycle**: `documented` (will promote on first verification slice)

This checklist is filled in as the `*.live.sandbox` and `*.live.prod`
slices run. The engineering slice ships this file with all checkboxes
empty. Per `docs/contracts/per_vendor_doc_pack_contract.md`, every row
below MUST be present.

---

## Sandbox verification (`8.SQ.live.sandbox`)

Cite the test that proved each check passed; cite the bounded fix
that resolved each check that failed.

- [ ] **Auth round-trip.** OAuth start → callback → token issued
      successfully against Square sandbox (`connect.squareupsandbox.com`).
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron extends a near-expiry token
      against Square sandbox. Verify rotating-refresh behavior — the
      old refresh token returns 401 after the new one is issued.
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull returns under 30s with
      `fieldMapping` populated; `covers_source` is
      `forecast_fallback` (NOT a number).
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill writes ≥1
      canonical fact row from sandbox; watermark persists per batch
      (assert `cursor_token` is non-null after each non-final page).
      Test: `<test_path>:<line>`
- [ ] **Polling resume.** Worker restart resumes from persisted
      cursor (no rewind, no skip).
      Test: `<test_path>:<line>`
- [ ] **Webhook signature verification.** Live signature accepted;
      tampered signature rejected with 403. Verify Square's signed
      payload is `notification_url + body` (not body alone).
      Test: `<test_path>:<line>`
- [ ] **Idempotency.** Same `event_id` twice → single canonical
      write.
      Test: `<test_path>:<line>`
- [ ] **Sanity hook.** Future-dated event from sandbox →
      `sanity_log` row + drop.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Observed sandbox response matches every
      `documented_per_square_2024_01_18` constant in fixtures.
      Discrepancies (each as a bounded fix, not slice rebuild):
      - `<field>`: documented as X, observed Y. Fix: `<diff or PR ref>`
- [ ] **Disconnect → reconnect.** Watermark preserved; no data gap;
      `revoke_oauth` 404 tolerated cleanly.
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** `location_manager` 403 on
      `integrations.configure`; `operator_admin` 200.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First connect + first backfill commit
      flips `demo_mode_state.is_demo` to `false`.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** `MetricCardNotYetAvailable`
      flips to live Sales number; top-left pill keeps the
      "Covers: forecast — Square does not expose guest count" line
      (because Square never exposes covers, the pill is permanent
      while Square is the only POS source).
      Walkthrough: `docs/_walkthroughs/8.SQ.live.sandbox.md`

**Sandbox verification verdict**: PENDING
**Lifecycle promoted to**: `sandbox_verified` (when all rows ✅)

---

## Production verification (`8.SQ.live.prod`)

Re-run the same checklist against production credentials. Same
table shape; rows are independent (sandbox passing does not imply
prod passing — vendor sandboxes sometimes lie).

- [ ] **Auth round-trip** (production).
- [ ] **Token refresh** (production rotating-refresh + 30-day TTL).
- [ ] **Test connection** (production).
- [ ] **Backfill 60-day window** (production).
- [ ] **Polling resume** (production).
- [ ] **Webhook signature verification** (production signing secret).
- [ ] **Idempotency** (production).
- [ ] **Sanity hook** (production).
- [ ] **Field-mapping diff** (production).
- [ ] **Disconnect → reconnect** (production).
- [ ] **Permission gate** (production).
- [ ] **Demo-mode flip** (production).
- [ ] **Operator dashboard chrome** (production).

**Production verification verdict**: PENDING
**Lifecycle promoted to**: `production_credentialed` (when all rows ✅)
**Date partnership cleared**: n/a (Square is public OAuth — see
`partnership_status.md`)
**Connect button live in admin widget**: YYYY-MM-DD

---

## First-operator-connect (automatic, no slice)

- [ ] First operator connect → lifecycle auto-promotes to
      `live_with_operators`.
- Date: YYYY-MM-DD
- Operator + location: `(<operator_id>, <location_id>)`
- Connected-operator chip in F&F Ops Console activated: YYYY-MM-DD
