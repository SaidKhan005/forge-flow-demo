# Agendrix — Live Verification Checklist

**Vendor ID**: `agendrix`
**Engineering slice**: `8.S.AG`
**`*.live.sandbox` slice**: `8.S.AG.live.sandbox` — pending
**`*.live.prod` slice**: `8.S.AG.live.prod` — pending
**Lifecycle**: `documented` (will promote on first verification slice)

This checklist is filled in as the `8.S.AG.live.sandbox` and
`8.S.AG.live.prod` slices run. The engineering slice ships this file
with all checkboxes empty (with the single exception of the webhook
signature row, which is checked off N/A in advance because the
vendor does not document webhook delivery — see `api_consumed.md`
and `webhook_signature.md`). Per
`docs/contracts/per_vendor_doc_pack_contract.md`, every row below
MUST be present.

---

## Sandbox verification (`8.S.AG.live.sandbox`)

Cite the test that proved each check passed; cite the bounded fix
that resolved each check that failed.

- [ ] **Auth round-trip.** Public OAuth authorization-code → access
      token issued successfully against vendor sandbox.
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron re-mints a near-expiry access
      token against vendor sandbox; sliding rotation persists the new
      refresh token.
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull returns under 30s with
      `fieldMapping` populated (`shift_start`, `shift_end`,
      `role_name`, `employee_id`, `vendor_entity_id`).
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill writes ≥1
      canonical fact row from sandbox; watermark persists per batch.
      Test: `<test_path>:<line>`
- [ ] **Polling resume.** Worker restart resumes from persisted
      cursor (no rewind, no skip). Poll-only Agendrix makes this
      load-bearing.
      Test: `<test_path>:<line>`
- [x] **Webhook signature verification.** N/A — vendor does not
      support webhooks per `api_consumed.md`. Adapter's
      `handleWebhook` throws `UnsupportedError`; covered by
      `test/integrations/labor/agendrix_labor_adapter_test.dart`
      (`handleWebhook` test group).
- [ ] **Idempotency.** Same `time_entries[].id` + `updated_at` twice
      → single canonical write (UNIQUE).
      Test: `<test_path>:<line>`
- [ ] **Sanity hook.** Future-dated time entry from sandbox →
      sanity_log row + drop.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Observed sandbox response matches every
      `documented_per_agendrix_v2` constant in fixtures.
      Discrepancies (each as a bounded fix, not slice rebuild):
      - `<field>`: documented as X, observed Y. Fix: `<diff or PR ref>`
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
      Walkthrough: `docs/_walkthroughs/8.S.AG.live.sandbox.md`

**Sandbox verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `sandbox_verified` (when all rows ✅ — the
N/A webhook row counts as already passed)

---

## Production verification (`8.S.AG.live.prod`)

Re-run the same checklist against production credentials. Same table
shape; rows are independent (sandbox passing does not imply prod
passing — vendor sandboxes sometimes lie). The webhook signature row
stays N/A (the vendor still does not expose webhooks in production).

- [ ] **Auth round-trip.** Production OAuth authorization-code →
      access token issued successfully.
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron re-mints a near-expiry access
      token against production.
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull returns under 30s with
      `fieldMapping` populated.
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill writes ≥1
      canonical fact row from production; watermark persists per
      batch.
      Test: `<test_path>:<line>`
- [ ] **Polling resume.** Worker restart resumes from persisted
      cursor (no rewind, no skip).
      Test: `<test_path>:<line>`
- [x] **Webhook signature verification.** N/A — vendor does not
      support webhooks per `api_consumed.md`.
- [ ] **Idempotency.** Same vendor entry id twice → single canonical
      write.
      Test: `<test_path>:<line>`
- [ ] **Sanity hook.** Future-dated time entry from production →
      sanity_log row + drop.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Observed production response matches
      every `documented_per_agendrix_v2` constant in fixtures.
      Discrepancies: `<list>`
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
      Walkthrough: `docs/_walkthroughs/8.S.AG.live.prod.md`

**Production verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `production_credentialed` (when all rows ✅)
**Date partnership cleared**: n/a — public OAuth (cite `partnership_status.md`)
**Connect button live in admin widget**: YYYY-MM-DD

---

## First-operator-connect (automatic, no slice)

- [ ] First operator connect → lifecycle auto-promotes to
      `live_with_operators`.
- Date: YYYY-MM-DD
- Operator + location: `(<operator_id>, <location_id>)`
- Connected-operator chip in F&F Ops Console activated: YYYY-MM-DD
