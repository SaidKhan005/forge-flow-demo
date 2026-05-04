# QuickBooks Time — Live Verification Checklist

**Vendor ID**: `quickbooks_time`
**Engineering slice**: `8.S.QBT`
**`*.live.sandbox` slice**: `8.S.QBT.live.sandbox` — pending
**`*.live.prod` slice**: `8.S.QBT.live.prod` — pending
**Lifecycle**: `documented` (will promote on first verification slice)

This checklist is filled in as the `*.live.sandbox` and `*.live.prod`
slices run. The engineering slice ships this file with all checkboxes
empty (or pre-marked N/A where pollOnly applies). Per
`docs/contracts/per_vendor_doc_pack_contract.md`, every row below is
present.

---

## Sandbox verification (`8.S.QBT.live.sandbox`)

Cite the test that proved each check passed; cite the bounded fix
that resolved each check that failed.

- [ ] **Auth round-trip.** OAuth start → callback → token issued
      successfully against an Intuit developer-app + free-trial QBT
      sandbox.
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron extends a near-expiry token
      against the QBT sandbox.
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull returns under 30s with
      `fieldMapping` populated (`shift_start`, `shift_end`,
      `role_name`, `vendor_entity_id`).
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill writes ≥1
      canonical punch row from the sandbox; watermark persists per
      batch.
      Test: `<test_path>:<line>`
- [ ] **Polling resume.** Worker restart resumes from persisted
      cursor (no rewind, no skip).
      Test: `<test_path>:<line>`
- [x] **Webhook signature verification.** N/A — pollOnly; vendor
      does not support webhooks per `api_consumed.md`. The adapter's
      `handleWebhook` throws `UnsupportedError` as defense-in-depth.
- [ ] **Idempotency.** Same vendor event ID twice → single canonical
      write.
      Test: `<test_path>:<line>`
- [ ] **Sanity hook.** Future-dated punch from sandbox → sanity_log
      row + drop.
      Test: `<test_path>:<line>`
- [ ] **Module disambiguation.** Connect with `module = 'accounting'`
      → `ModuleRefusalException` surfaced as a friendly redirect
      dialog; connect with `module = 'payroll'` →
      `ModuleRefusalException` surfaced as a friendly refusal dialog;
      connect with `module = 'time'` proceeds end-to-end. (Required
      by `docs/contracts/vendor_adapter_slice_contract.md` for
      ADP / QuickBooks adapters.)
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Observed sandbox response matches every
      `documented_per_quickbooks_time_v1` constant in fixtures.
      Discrepancies (each as a bounded fix, not slice rebuild):
      - `<field>`: documented as X, observed Y. Fix: `<diff or PR ref>`
- [ ] **Disconnect → reconnect.** Watermark preserved; no data gap.
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** `location_manager` 403; `operator_admin`
      200.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First connect + first backfill commit
      flips `demo_mode_state.is_demo` to `false` for the labor
      surface.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** `MetricCardNotYetAvailable`
      flips to live SPLH number; top-left pill drops the "Labor:
      not yet connected" line per
      `docs/contracts/metric_card_honesty_contract.md`.
      Walkthrough: `docs/_walkthroughs/8.S.QBT.live.sandbox.md`

**Sandbox verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `sandbox_verified` (when all rows ✅ or N/A)

---

## Production verification (`8.S.QBT.live.prod`)

Re-run the same checklist against production credentials. Same table
shape; rows are independent (sandbox passing does not imply prod
passing — vendor sandboxes sometimes lie).

- [ ] **Auth round-trip.** OAuth start → callback → token issued
      successfully against a production Intuit OAuth realm.
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron extends a near-expiry token
      against production.
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull returns under 30s with
      `fieldMapping` populated.
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill writes ≥1
      canonical punch row; watermark persists per batch.
      Test: `<test_path>:<line>`
- [ ] **Polling resume.** Worker restart resumes from persisted
      cursor.
      Test: `<test_path>:<line>`
- [x] **Webhook signature verification.** N/A — pollOnly.
- [ ] **Idempotency.** Same vendor event ID twice → single canonical
      write.
      Test: `<test_path>:<line>`
- [ ] **Sanity hook.** Future-dated punch from prod → sanity_log row
      + drop.
      Test: `<test_path>:<line>`
- [ ] **Module disambiguation.** Connect-flow refusal copy verified
      against operator-facing dialog renderer in production admin
      surface for both `accounting` and `payroll` modules.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Observed prod response matches every
      `documented_per_quickbooks_time_v1` constant in fixtures.
- [ ] **Disconnect → reconnect.** Watermark preserved.
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** `location_manager` 403; `operator_admin`
      200.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First connect + first backfill commit
      flips `demo_mode_state.is_demo` to `false`.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** `MetricCardNotYetAvailable`
      flips to live SPLH; top-left pill drops the labor degradation
      line.

**Production verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `production_credentialed` (when all rows
✅ or N/A)
**Date partnership cleared**: n/a — public OAuth (cite
`partnership_status.md`)
**Connect button live in admin widget**: YYYY-MM-DD

---

## First-operator-connect (automatic, no slice)

- [ ] First operator connect → lifecycle auto-promotes to
      `live_with_operators`.
- Date: YYYY-MM-DD
- Operator + location: `(<operator_id>, <location_id>)`
- Connected-operator chip in F&F Ops Console activated: YYYY-MM-DD
