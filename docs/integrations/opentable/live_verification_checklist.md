# OpenTable — Live Verification Checklist

**Vendor ID**: `opentable`
**Engineering slice**: `8R.OT`
**`*.live.sandbox` slice**: `8R.OT.live.sandbox` — pending
**`*.live.prod` slice**: `8R.OT.live.prod` — pending
**Lifecycle**: `documented` (will promote on first verification slice)

This checklist is filled in as the `*.live.sandbox` and `*.live.prod`
slices run. The engineering slice ships this file with all checkboxes
empty. Per `docs/contracts/per_vendor_doc_pack_contract.md`, every
row below MUST be present.

---

## Sandbox verification (`8R.OT.live.sandbox`)

Cite the test that proved each check passed; cite the bounded fix
that resolved each check that failed.

- [ ] **Auth round-trip.** OAuth start → callback → token issued
      successfully against vendor sandbox.
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron extends a near-expiry token
      against vendor sandbox.
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull returns under 30s with
      `fieldMapping` populated (`reservation_at`, `party_size`,
      `status`, `vendor_entity_id`, `vendor_modified_at` plus the
      `assumption: true` flag from this slice's offline path is
      cleared once observed values match).
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill writes ≥1
      canonical fact row from sandbox; watermark persists per batch.
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
- [ ] **Field-mapping diff.** Observed sandbox response matches every
      `documented_per_opentable_*` constant in fixtures
      (`documentedPerOpentableV1FieldMapping` and the fixture
      mirror). EVERY documented assumption is listed below for the
      `*.live.sandbox` slice to diff. Discrepancies (each as a
      bounded fix, not slice rebuild):
      - `reservation.id` type — documented `string`. Verify exact
        type. Fix: `<diff or PR ref>`
      - `reservation.reserved_at` shape — documented ISO-8601 with
        `Z`. Verify presence of `Z`. Fix: `<diff or PR ref>`
      - `reservation.modified_at` shape — documented ISO-8601 with
        `Z`. Verify presence + format. Fix: `<diff or PR ref>`
      - `reservation.party_size` key name — documented
        `party_size`. Verify exact key (some vendors use `covers`
        / `guests`). Fix: `<diff or PR ref>`
      - `reservation.status` enum vocabulary — documented lower-case
        `{booked, seated, completed, no_show, cancelled}`. Verify
        exact strings + completeness. Fix: `<diff or PR ref>`
      - `reservation.restaurant_id` (`rid`) shape — documented
        string-or-int. Verify type. Fix: `<diff or PR ref>`
      - OAuth flow — documented `authorization_code`. Verify exact
        grant type + scope strings. Fix: `<diff or PR ref>`
      - OAuth token TTLs — documented 1h access / 90d rotating
        refresh. Verify exact lifetimes. Fix: `<diff or PR ref>`
      - Webhook signature algorithm — documented HMAC-SHA256. Verify
        exact algorithm + signed-payload byte sequence. Fix: `<diff
        or PR ref>`
      - Webhook signature header — documented
        `X-OpenTable-Signature`, lowercase hex. Verify exact header
        + encoding. Fix: `<diff or PR ref>`
      - Webhook timestamp header — documented
        `X-OpenTable-Timestamp`, Unix epoch seconds. Verify presence
        + format. Fix: `<diff or PR ref>`
      - Webhook auto-register — documented
        `POST /v1/webhooks/subscriptions`. Verify endpoint + body
        shape. Fix: `<diff or PR ref>`
      - Webhook event — documented single roll-up
        `reservation.modified`. Verify event vocabulary; switch
        subscription if per-status events exist instead. Fix: `<diff
        or PR ref>`
      - Reservation list endpoint — documented
        `GET /v1/reservations/search` with cursor pagination.
        Verify path + pagination shape. Fix: `<diff or PR ref>`
      - Reservation detail endpoint — documented
        `GET /v1/reservations/{reservation_id}`. Verify path. Fix:
        `<diff or PR ref>`
      - Per-`rid` grant scope — documented
        `VendorGrantScope.perLocation`. Verify a single OAuth grant
        covers exactly one `rid`. Fix: `<diff or PR ref>`
      - Replay defense — documented 24h tolerance per V1 lean cut 2.
        Verify framework ceiling matches observed vendor retry
        window. Fix: `<diff or PR ref>`
- [ ] **Disconnect → reconnect.** Watermark preserved; no data gap.
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** `location_manager` 403; `operator_owner`
      200.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First connect + first backfill commit
      flips `demo_mode_state.is_demo` to `false`.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** `MetricCardNotYetAvailable`
      flips to live number; top-left pill drops the corresponding
      degradation line.
      Walkthrough: `docs/_walkthroughs/8R.OT.live.sandbox.md`

**Sandbox verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `sandbox_verified` (when all rows ✅)

---

## Production verification (`8R.OT.live.prod`)

Re-run the same checklist against production credentials issued by
partnership. Same table shape; rows are independent (sandbox passing
does not imply prod passing — vendor sandboxes sometimes lie).

- [ ] **Auth round-trip.** Production OAuth start → callback → token
      issued.
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron extends a near-expiry token
      against production.
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull returns under 30s.
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill writes ≥1
      canonical fact row from production.
      Test: `<test_path>:<line>`
- [ ] **Polling resume.** Worker restart resumes from persisted
      cursor.
      Test: `<test_path>:<line>`
- [ ] **Webhook signature verification.** Live signature accepted;
      tampered rejected with 403.
      Test: `<test_path>:<line>`
- [ ] **Idempotency.** Same vendor event ID twice → single canonical
      write.
      Test: `<test_path>:<line>`
- [ ] **Sanity hook.** Future-dated event → sanity_log + drop.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Production response matches every
      documented constant.
      Test: `<test_path>:<line>`
- [ ] **Disconnect → reconnect.** Watermark preserved.
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** `location_manager` 403;
      `operator_owner` 200.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First production connect flips
      `demo_mode_state.is_demo`.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** Live number on the COVERS card
      (paired with the connected POS adapter); pill drops the
      reservation-degradation line.
      Walkthrough: `docs/_walkthroughs/8R.OT.live.prod.md`

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
