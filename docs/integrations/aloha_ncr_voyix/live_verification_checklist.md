# Aloha (NCR Voyix) — Live Verification Checklist

**Vendor ID**: `aloha_ncr_voyix`
**Engineering slice**: `8.AL`
**`*.live.sandbox` slice**: `8.AL.live.sandbox` — pending
**`*.live.prod` slice**: `8.AL.live.prod` — pending
**Lifecycle**: `documented` (will promote on first verification slice)

This checklist is filled in as the `8.AL.live.sandbox` and
`8.AL.live.prod` slices run. The engineering slice ships this file
with all checkboxes empty. Per
`docs/contracts/per_vendor_doc_pack_contract.md`, every row below
MUST be present.

---

## Sandbox verification (`8.AL.live.sandbox`)

Cite the test that proved each check passed; cite the bounded fix
that resolved each check that failed.

- [ ] **Auth round-trip.** OAuth `client_credentials` exchange →
      access token issued successfully against the NCR Voyix Aloha
      sandbox.
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron re-mints a near-expiry access
      token against the sandbox (no refresh-token round trip — the
      `client_credentials` flow re-mints).
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull returns under 30s with
      `fieldMapping` populated (covers + opened_at + closed_at +
      actual_sales).
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
- [ ] **Sanity hook.** Future-dated event from sandbox → `sanity_log`
      row + drop.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Observed sandbox response matches every
      `documented_per_aloha_ncr_voyix_*` constant in fixtures.
      Discrepancies (each as a bounded fix, not slice rebuild):
      - `<field>`: documented as X, observed Y. Fix: `<diff or PR ref>`
- [ ] **Disconnect → reconnect.** Watermark preserved; no data gap.
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** `location_manager` 403; `operator_admin`
      200.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First connect + first backfill commit
      flips `demo_mode_state.is_demo` to `false`.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** `MetricCardNotYetAvailable`
      flips to live number; top-left pill drops the corresponding
      degradation line.
      Walkthrough: `docs/_walkthroughs/8.AL.live.sandbox.md`

**Sandbox verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `sandbox_verified` (when all rows ✅)

---

## Production verification (`8.AL.live.prod`)

Re-run the same checklist against production credentials. Same
table shape; rows are independent (sandbox passing does not imply
prod passing — vendor sandboxes sometimes lie).

- [ ] **Auth round-trip.** OAuth `client_credentials` exchange →
      access token issued against production.
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron re-mints near-expiry access
      token against production.
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
      every `documented_per_aloha_ncr_voyix_*` constant in fixtures.
      Discrepancies:
      - `<field>`: documented as X, observed Y. Fix: `<diff or PR ref>`
- [ ] **Disconnect → reconnect.** Watermark preserved; no data gap.
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** `location_manager` 403; `operator_admin`
      200.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First connect + first backfill commit
      flips `demo_mode_state.is_demo` to `false`.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** `MetricCardNotYetAvailable`
      flips to live number; top-left pill drops the corresponding
      degradation line.
      Walkthrough: `docs/_walkthroughs/8.AL.live.prod.md`

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
