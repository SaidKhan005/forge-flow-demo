# Toast — Live Verification Checklist

**Vendor ID**: `toast`
**Engineering slice**: `8.TS` (this slice)
**`*.live.sandbox` slice**: `8.TS.live.sandbox` — pending (fires when
Toast issues sandbox credentials per
[partnership_status.md](partnership_status.md))
**`*.live.prod` slice**: `8.TS.live.prod` — pending (fires when
Toast Partner program clears + production keys are issued)
**Lifecycle**: `documented` (will promote on first verification slice)

This checklist is filled in as the `*.live.sandbox` and `*.live.prod`
slices run. The engineering slice ships this file with all checkboxes
empty per
[docs/contracts/per_vendor_doc_pack_contract.md](../../contracts/per_vendor_doc_pack_contract.md).

---

## Sandbox verification (`8.TS.live.sandbox`)

Cite the test that proved each check passed; cite the bounded fix
that resolved each check that failed.

- [ ] **Auth round-trip.** OAuth client_credentials login →
      access token issued successfully against Toast Standard
      sandbox.
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron extends a near-expiry token
      against Toast sandbox (effectively re-mints via
      client_credentials login).
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull from `ordersBulk`
      returns under 30s with `fieldMapping` populated.
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill writes
      ≥1 canonical fact row from sandbox; watermark persists per
      batch (Toast `ordersBulk` 1-hour windows stitched).
      Test: `<test_path>:<line>`
- [ ] **Polling resume.** Worker restart resumes from persisted
      cursor (no rewind, no skip).
      Test: `<test_path>:<line>`
- [ ] **Webhook signature verification.** Live `Toast-Signature`
      accepted; tampered signature rejected with 403.
      Test: `<test_path>:<line>`
- [ ] **Idempotency.** Same `eventGuid` twice → single canonical
      write.
      Test: `<test_path>:<line>`
- [ ] **Sanity hook.** Future-dated event from sandbox →
      `sanity_log` row + drop. Toast sandbox accepts injected
      future timestamps when the test harness mocks the system
      clock.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Observed sandbox response matches every
      `documentedPerToastV2` constant in
      [test/integrations/pos/fixtures/toast_orders_fixture.dart](../../../test/integrations/pos/fixtures/toast_orders_fixture.dart).
      Discrepancies (each as a bounded fix, not slice rebuild):
      - `<field>`: documented as X, observed Y. Fix: `<diff or PR ref>`
- [ ] **Disconnect → reconnect.** Watermark preserved; no data gap.
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** `location_manager` 403; `operator_admin`
      200.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First connect + first backfill commit
      flips `demo_mode_state.is_demo` to `false` for `(operator_id,
      location_id, pos)`.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** `MetricCardNotYetAvailable`
      flips to live number; top-left pill drops the corresponding
      degradation line.
      Walkthrough: `docs/_walkthroughs/8.TS.live.sandbox.md`

**Sandbox verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `sandbox_verified` (when all rows ✅)

---

## Production verification (`8.TS.live.prod`)

Re-run the same checklist against production credentials. Same
table shape; rows are independent (sandbox passing does not imply
prod passing — Toast sandbox is known to omit some real fields).

- [ ] **Auth round-trip.** Production client_credentials login →
      access token issued.
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
      Walkthrough: `docs/_walkthroughs/8.TS.live.prod.md`

**Production verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `production_credentialed` (when all rows ✅)
**Date partnership cleared**: YYYY-MM-DD (cite
[partnership_status.md](partnership_status.md))
**Connect button live in admin widget**: YYYY-MM-DD

---

## First-operator-connect (automatic, no slice)

- [ ] First operator connect → lifecycle auto-promotes to
      `live_with_operators`.
- Date: YYYY-MM-DD
- Operator + location: `(<operator_id>, <location_id>)`
- Connected-operator chip in F&F Ops Console activated: YYYY-MM-DD
