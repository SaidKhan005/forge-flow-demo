# Libro Reserve — Live Verification Checklist

**Vendor ID**: `libro`
**Engineering slice**: `8R.LB`
**`*.live.sandbox` slice**: `8R.LB.live.sandbox` — pending
**`*.live.prod` slice**: `8R.LB.live.prod` — pending
**Lifecycle**: `documented` (set by engineering slice; promotion
runs in the `*.live.*` slices).

This checklist is filled in as the `8R.LB.live.sandbox` and
`8R.LB.live.prod` slices run. The engineering slice ships this file
with all checkboxes empty. Per
`docs/contracts/per_vendor_doc_pack_contract.md`, every row below
MUST be present.

---

## Sandbox verification (`8R.LB.live.sandbox`)

Cite the test that proved each check passed; cite the bounded fix
that resolved each check that failed.

- [ ] **Auth round-trip.** OAuth start → callback → token issued
      successfully against Libro sandbox.
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** `oauth_refresh_cron.dart` extends a
      near-expiry sandbox token.
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull returns under 30s with
      `fieldMapping` populated (`party_size`, `reservation_at`,
      `status`, `status_transitions`).
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill writes ≥1
      reservation_facts row from sandbox; watermark persists per
      batch.
      Test: `<test_path>:<line>`
- [ ] **Polling resume.** Worker restart resumes from persisted
      cursor (no rewind, no skip).
      Test: `<test_path>:<line>`
- [ ] **Webhook signature verification.** Live signature accepted;
      tampered signature rejected with 403.
      Test: `<test_path>:<line>`
- [ ] **Idempotency.** Same vendor event ID twice → single canonical
      write.
      Test: `<test_path>:<line>`
- [ ] **Sanity hook.** Future-dated event from sandbox → sanity_log
      row + drop.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Observed sandbox response matches
      every row in
      `test/integrations/reservation/fixtures/libro_reservations_fixture.dart`
      `documented_per_libro_v1`.
      Discrepancies (each as a bounded fix, not slice rebuild):
      - `<field>`: documented as X, observed Y. Fix: `<diff or PR ref>`
- [ ] **Disconnect → reconnect.** Watermark preserved; no data gap.
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** `location_manager` 403; `operator_owner`
      200 on `integrations.configure` actions.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First connect + first backfill commit
      flips `demo_mode_state.is_demo` to `false` for the
      reservation channel.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** `MetricCardNotYetAvailable`
      flips to live aggregate; top-left pill drops the corresponding
      degradation line.
      Walkthrough: `docs/_walkthroughs/8R.LB.live.sandbox.md`

**Sandbox verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `sandbox_verified` (when all rows ✅)

---

## Production verification (`8R.LB.live.prod`)

Re-run the sandbox checklist against production credentials. Same
table shape; rows are independent (sandbox passing does not imply
prod passing — vendor sandboxes sometimes lie).

- [ ] **Auth round-trip.** Production OAuth.
- [ ] **Token refresh.** Production token.
- [ ] **Test connection.** Production sample.
- [ ] **Backfill 60-day window.** Production backfill.
- [ ] **Polling resume.** Production resume.
- [ ] **Webhook signature verification.** Production signature.
- [ ] **Idempotency.** Production idempotency.
- [ ] **Sanity hook.** Production sanity drop.
- [ ] **Field-mapping diff.** Production response vs documented.
- [ ] **Disconnect → reconnect.** Production cycle.
- [ ] **Permission gate.** Production permission.
- [ ] **Demo-mode flip.** Production flip.
- [ ] **Operator dashboard chrome.** Production chrome.

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
