# 7shifts — Live Verification Checklist

**Vendor ID**: `seven_shifts`
**Engineering slice**: `8.S.7S`
**`*.live.sandbox` slice**: `8.S.7S.live.sandbox` — pending
**`*.live.prod` slice**: `8.S.7S.live.prod` — pending
**Lifecycle**: `documented` (will promote on first verification slice)

This checklist is filled in as the `*.live.sandbox` and `*.live.prod`
slices run. The engineering slice ships this file with all checkboxes
empty. Per `docs/contracts/per_vendor_doc_pack_contract.md`, every
row below MUST be present.

---

## Sandbox verification (`8.S.7S.live.sandbox`)

Cite the test that proved each check passed; cite the bounded fix
that resolved each check that failed.

- [ ] **Auth round-trip.** OAuth start → callback → token issued
      successfully against developer-portal sandbox account.
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron extends a near-expiry token
      against the sandbox account.
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull returns under 30s with
      `fieldMapping` populated (`shift_start`, `shift_end`,
      `role_name`, `is_approved`, `employee_id`, `vendor_entity_id`,
      `vendor_modified_at`).
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill writes ≥1
      canonical time-punch fact row from sandbox; watermark persists
      per batch.
      Test: `<test_path>:<line>`
- [ ] **Polling resume.** Worker restart resumes from persisted
      cursor (no rewind, no skip).
      Test: `<test_path>:<line>`
- [ ] **Webhook signature verification.** Live signature accepted
      (Gourmet sandbox account); tampered signature rejected with
      403.
      Test: `<test_path>:<line>`
- [ ] **Idempotency.** Same vendor event ID twice → single canonical
      write.
      Test: `<test_path>:<line>`
- [ ] **Sanity hook.** Future-dated event from sandbox → sanity_log
      row + drop.
      Test: `<test_path>:<line>`
- [ ] **`payroll_period.closed` webhook.** Inbound event lands in
      canonical `payroll_period_closed_at` row (Phase 7.58 Primary
      Driver binding).
      Test: `<test_path>:<line>`
- [ ] **`payroll_period.closed` poll.** Lower-tier sandbox connection
      lands the same canonical row via the polling path
      (`fetchLatestPayrollPeriodClosedAt`).
      Test: `<test_path>:<line>`
- [ ] **Plan-tier fallback.** Toggle the sandbox dev account from
      Gourmet to The Works → reconnect skips webhook registration,
      surfaces `kSevenShiftsNonGourmetNote` in
      `TestConnectionResult.note`, polling-only sync continues to
      land canonical facts.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Observed sandbox response matches
      every `documented_per_seven_shifts_*` constant in fixtures
      (`documentedPerSevenShiftsV2FieldMapping` and the fixture
      mirror). Discrepancies (each as a bounded fix, not slice
      rebuild):
      - `time_punch.id` type — documented `int → to_string`. Verify
        exact type. Fix: `<diff or PR ref>`
      - `time_punch.clocked_in` shape — documented ISO-8601 with
        `Z`. Verify presence of `Z`. Fix: `<diff or PR ref>`
      - `time_punch.clocked_out` shape — documented ISO-8601 with
        `Z` or null. Verify nullability. Fix: `<diff or PR ref>`
      - `time_punch.modified` shape — documented ISO-8601 with `Z`.
        Verify presence + format. Fix: `<diff or PR ref>`
      - `time_punch.role.name` — documented nested object with
        `name`. Verify path. Fix: `<diff or PR ref>`
      - `time_punch.user_id` — documented int → to_string. Verify
        type. Fix: `<diff or PR ref>`
      - `time_punch.approved` — documented bool. Verify exact
        type + presence on every punch envelope. Fix: `<diff or PR
        ref>`
      - `payroll_period.closed_at` — documented ISO-8601 with `Z` on
        both poll endpoint and webhook. Verify presence + key name.
        Fix: `<diff or PR ref>`
      - OAuth flow — documented `authorization_code`. Verify exact
        grant type + scope strings. Fix: `<diff or PR ref>`
      - OAuth token TTLs — documented 1h access / 30-90d rotating
        refresh. Verify exact lifetimes. Fix: `<diff or PR ref>`
      - Webhook signature algorithm — documented HMAC-SHA256. Verify
        exact algorithm + signed-payload byte sequence. Fix: `<diff
        or PR ref>`
      - Webhook signature header — documented
        `X-7Shifts-Hmac-SHA256`, base64. Verify exact header +
        encoding. Fix: `<diff or PR ref>`
      - Webhook timestamp header — documented `X-7Shifts-Timestamp`,
        Unix epoch seconds. Verify presence + format. Fix: `<diff or
        PR ref>`
      - Webhook auto-register — documented `POST /v2/company/{id}/
        webhooks`. Verify endpoint + body shape. Fix: `<diff or PR
        ref>`
      - Webhook events — documented
        `time_punch.*`, `shift.*`, `payroll_period.closed`. Verify
        event vocabulary. Fix: `<diff or PR ref>`
      - Time-punch list endpoint — documented `GET /v2/company/{id}/
        time_punches` with cursor pagination. Verify path + pagination
        shape. Fix: `<diff or PR ref>`
      - Payroll-period list endpoint — documented `GET /v2/company/
        {id}/payroll_periods?status=closed`. Verify path + filter
        param. Fix: `<diff or PR ref>`
      - Company info endpoint — documented `GET /v2/company/{id}`
        returns `plan_tier`. Verify field path for plan tier
        detection. Fix: `<diff or PR ref>`
      - OperatorWide grant scope — documented one OAuth grant covers
        all locations. Verify by enumerating `/v2/company/{id}/
        locations`. Fix: `<diff or PR ref>`
      - Replay defense — documented 24h tolerance per V1 lean cut 2.
        Verify framework ceiling matches observed vendor retry
        window. Fix: `<diff or PR ref>`
- [ ] **Disconnect → reconnect.** Watermark preserved; no data gap.
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** `location_manager` 403; `operator_admin`
      200.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First connect + first backfill commit
      flips `demo_mode_state.is_demo` to `false`.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** `MetricCardNotYetAvailable`
      flips to live number on the SPLH / wage-derived cards;
      top-left pill drops the corresponding degradation line.
      Walkthrough: `docs/_walkthroughs/8.S.7S.live.sandbox.md`

**Sandbox verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `sandbox_verified` (when all rows ✅)

---

## Production verification (`8.S.7S.live.prod`)

Re-run the same checklist against production credentials issued by a
real Gourmet-tier 7shifts customer. Same table shape; rows are
independent (sandbox passing does not imply prod passing — vendor
sandboxes sometimes lie).

- [ ] **Auth round-trip.** Production OAuth start → callback → token
      issued.
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron extends a near-expiry token
      against production.
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull returns under 30s.
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill writes ≥1
      canonical time-punch fact row from production.
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
- [ ] **`payroll_period.closed` webhook.** Inbound event lands in
      canonical `payroll_period_closed_at` row.
      Test: `<test_path>:<line>`
- [ ] **`payroll_period.closed` poll fallback.** Verified on a
      lower-tier production tenant.
      Test: `<test_path>:<line>`
- [ ] **Plan-tier fallback.** Lower-tier production tenant connects;
      polling-only path runs end-to-end.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Production response matches every
      documented constant.
      Test: `<test_path>:<line>`
- [ ] **Disconnect → reconnect.** Watermark preserved.
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** `location_manager` 403;
      `operator_admin` 200.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First production connect flips
      `demo_mode_state.is_demo`.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** Live number on the SPLH card
      (Primary Driver finalization landed); pill drops the
      labor-degradation line.
      Walkthrough: `docs/_walkthroughs/8.S.7S.live.prod.md`

**Production verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `production_credentialed` (when all rows ✅)
**Date partnership cleared**: n/a — public OAuth, no partnership review
**Connect button live in admin widget**: YYYY-MM-DD

---

## First-operator-connect (automatic, no slice)

- [ ] First operator connect → lifecycle auto-promotes to
      `live_with_operators`.
- Date: YYYY-MM-DD
- Operator + location: `(<operator_id>, <location_id>)`
- Connected-operator chip in F&F Ops Console activated: YYYY-MM-DD
