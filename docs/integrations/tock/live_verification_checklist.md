# Tock — Live Verification Checklist

**Vendor ID**: `tock`
**Engineering slice**: `8R.TC` (this slice)
**`*.live.sandbox` slice**: `8R.TC.live.sandbox` — pending (fires when
Tock issues sandbox credentials per
[partnership_status.md](partnership_status.md))
**`*.live.prod` slice**: `8R.TC.live.prod` — pending (fires when Tock
Premium-tier negotiation clears + production keys are issued)
**Lifecycle**: `documented` (will promote on first verification slice)

This checklist is filled in as the `*.live.sandbox` and `*.live.prod`
slices run. The engineering slice ships this file with all checkboxes
empty per
[docs/contracts/per_vendor_doc_pack_contract.md](../../contracts/per_vendor_doc_pack_contract.md).

---

## Sandbox verification (`8R.TC.live.sandbox`)

Cite the test that proved each check passed; cite the bounded fix
that resolved each check that failed.

- [ ] **Auth round-trip.** API key paste → `verifyApiKey` round-trip
      against Tock Premium-tier sandbox returns the expected
      `businessId` binding successfully.
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** N/A — Tock uses static API keys. Verify
      instead that a 401 response on a stale key flips
      `connector_connection.status = 'error'` and surfaces the
      operator-facing "re-paste your Tock API key" chrome.
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull from
      `reservations/search` returns under 30s with `fieldMapping`
      populated (`reservation_at`, `party_size`, `status`,
      `vendor_entity_id`, `vendor_modified_at`).
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill writes
      ≥1 canonical reservation row from sandbox; watermark persists
      per batch (Tock cursor-paginated `reservations/search`).
      Test: `<test_path>:<line>`
- [ ] **Polling resume.** Worker restart resumes from persisted
      cursor (no rewind, no skip).
      Test: `<test_path>:<line>`
- [ ] **Webhook signature verification.** Live `X-Tock-Signature`
      accepted; tampered signature rejected with 403.
      Test: `<test_path>:<line>`
- [ ] **Idempotency.** Same Tock `eventId` twice → single canonical
      write.
      Test: `<test_path>:<line>`
- [ ] **Sanity hook.** Future-dated reservation from sandbox →
      `sanity_log` row + drop. The test harness mocks the system
      clock to inject a future `serviceDateTimestamp`.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Observed sandbox response matches every
      `documentedPerTockReservation20260504` constant in
      [test/integrations/reservation/fixtures/tock_reservations_fixture.dart](../../../test/integrations/reservation/fixtures/tock_reservations_fixture.dart).
      Discrepancies (each as a bounded fix, not slice rebuild):
      - **Per-status transition timestamps** — engineering slice
        captured `Ambiguity: yes` on `arrived_at`, `seated_at`,
        `left_at`, `canceled_at`. If the sandbox payload includes any
        of these, adopt them as a bounded fix to the canonical fact
        map and update `field_mapping.md` + the
        `documentedPerTockReservation20260504` constant.
      - **Signature encoding** — engineering selected lowercase hex.
        If the sandbox emits base64, adopt as a bounded fix to the
        verifier and update `webhook_signature.md`.
      - **Status vocabulary** — verify every observed `status` string
        in the sandbox maps to one of the documented six (`EXPECTED`,
        `ARRIVED`, `SEATED`, `LEFT`, `NO_SHOW`, `CANCELLED`).
      - `<field>`: documented as X, observed Y. Fix: `<diff or PR ref>`
- [ ] **Disconnect → reconnect.** Watermark preserved; no data gap.
      Operator-facing copy on disconnect instructs the operator to
      remove the F&F webhook URL from the Tock dashboard manually
      (manualPaste vendor — adapter never auto-registered).
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** `location_manager` 403; `operator_owner`
      200.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First connect + first backfill commit
      flips `demo_mode_state.is_demo` to `false` for `(operator_id,
      location_id, reservation)`.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** `MetricCardNotYetAvailable`
      flips to live number; top-left pill drops the corresponding
      degradation line. The "In the Books" aggregate count on Shift
      gains a freshness indicator.
      Walkthrough: `docs/_walkthroughs/8R.TC.live.sandbox.md`

**Sandbox verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `sandbox_verified` (when all rows ✅)

---

## Production verification (`8R.TC.live.prod`)

Re-run the same checklist against production credentials. Same table
shape; rows are independent (sandbox passing does not imply prod
passing — Tock sandbox is known to omit some real fields per the
Premium-tier developer portal).

- [ ] **Auth round-trip.** Production API key paste → `verifyApiKey`
      against Tock production succeeds.
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** N/A — static API key; verify 401 → error
      chrome.
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
      Walkthrough: `docs/_walkthroughs/8R.TC.live.prod.md`

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
