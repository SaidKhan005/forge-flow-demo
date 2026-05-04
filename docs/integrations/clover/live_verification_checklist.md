# Clover — Live Verification Checklist

**Vendor ID**: `clover`
**Engineering slice**: `8.CL`
**`*.live.sandbox` slice**: `8.CL.live.sandbox` — pending
**`*.live.prod` slice**: `8.CL.live.prod` — pending
**Lifecycle**: `documented` (will promote on first verification slice)

This checklist is filled in as the `8.CL.live.sandbox` and
`8.CL.live.prod` slices run. The engineering slice (`8.CL`) ships
this file with all checkboxes empty.

---

## Sandbox verification (`8.CL.live.sandbox`)

Cite the test that proved each check passed; cite the bounded fix
that resolved each check that failed.

- [ ] **Auth round-trip.** OAuth start → callback → token issued
      successfully against `apisandbox.dev.clover.com`.
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron extends a near-expiry sandbox
      token via `POST /oauth/v2/token` with `grant_type=refresh_token`.
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull
      (`/v3/merchants/{mId}/orders?limit=1`) returns under 30s with
      `fieldMapping` populated (covers null + covers_source
      forecast_fallback).
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill against
      sandbox writes ≥1 canonical fact row; watermark persists per
      batch. Window stays inside Clover's 90-day filter cap (no
      clamp needed at 60d).
      Test: `<test_path>:<line>`
- [ ] **90-day filter cap clamp.** Backfill with
      `windowStart = now - 120d` clamps to `now - 90d` and proceeds
      without error.
      Test: `<test_path>:<line>`
- [ ] **Polling resume.** Worker restart resumes from persisted
      cursor (no rewind, no skip). Adapter encodes `offset:N` so the
      next page starts at the correct offset.
      Test: `<test_path>:<line>`
- [ ] **Webhook signature verification.** Live signature accepted;
      tampered signature rejected with 403; framework `_failed`
      records the audit row + dead-letters at attempt 3.
      Test: `<test_path>:<line>`
- [ ] **Idempotency.** Same Clover event ID delivered twice → single
      canonical write. Adapter does NOT short-circuit; framework
      idempotency UNIQUE collapses the duplicate.
      Test: `<test_path>:<line>`
- [ ] **Sanity hook.** Future-dated `createdTime` from sandbox →
      sanity_log row + drop. Adapter does NOT call `sanityHook` on
      the webhook path; framework step 4 is the only enforcer.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Observed sandbox response matches every
      `documented_per_clover_v3_2026_05_03` constant in fixtures.
      Discrepancies (each as a bounded fix, not slice rebuild):
      - `<field>`: documented as X, observed Y. Fix: `<diff or PR ref>`
- [ ] **Closed-state ambiguity.** Sandbox order in `state == 'paid'`
      writes `closed_at = modifiedTime`; same order in
      `state == 'open'` writes `closed_at = null`. The ambiguity
      call in `field_mapping.md` resolves correctly under live data.
      Test: `<test_path>:<line>`
- [ ] **Disconnect → reconnect.** Watermark preserved; no data gap.
      `DELETE /v3/apps/{aId}/webhooks/{subscriptionId}` returns 200
      or 404 (both treated as success).
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** `location_manager` 403; `operator_admin`
      200 on the connect / disconnect routes.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First connect + first backfill commit
      flips `demo_mode_state.is_demo` to `false` for the
      (operator_id, location_id) tuple.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** Top-left pill drops the
      "covers via forecast" line for this connection's location only
      when forecast confidence is high; the pill stays when forecast
      confidence is low. `MetricCardNotYetAvailable` flips to live
      number on revenue/wage cards.
      Walkthrough: `docs/_walkthroughs/8.CL.live.sandbox.md`

**Sandbox verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `sandbox_verified` (when all rows ✅)

---

## Production verification (`8.CL.live.prod`)

Re-run the same checklist against production credentials issued by
Clover App Market. Same table shape; rows are independent.

- [ ] Auth round-trip (production credentials).
- [ ] Token refresh.
- [ ] Test connection.
- [ ] Backfill 60-day window.
- [ ] 90-day filter cap clamp.
- [ ] Polling resume.
- [ ] Webhook signature verification.
- [ ] Idempotency.
- [ ] Sanity hook.
- [ ] Field-mapping diff.
- [ ] Closed-state ambiguity.
- [ ] Disconnect → reconnect.
- [ ] Permission gate.
- [ ] Demo-mode flip.
- [ ] Operator dashboard chrome.

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
