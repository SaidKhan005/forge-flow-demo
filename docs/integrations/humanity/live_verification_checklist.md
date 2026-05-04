# Humanity (TCP) — Live Verification Checklist

**Vendor ID**: `humanity`
**Engineering slice**: `8.S.HM`
**`*.live.sandbox` slice**: `8.S.HM.live.sandbox` — pending
**`*.live.prod` slice**: `8.S.HM.live.prod` — pending
**Lifecycle**: `documented` (will promote on first verification slice)

This checklist is filled in as the `*.live.sandbox` and
`*.live.prod` slices run. The engineering slice ships this file with
all checkboxes empty. Per
`docs/contracts/per_vendor_doc_pack_contract.md`, every row below
MUST be present.

---

## Sandbox verification (`8.S.HM.live.sandbox`)

Cite the test that proved each check passed; cite the bounded fix
that resolved each check that failed.

- [ ] **Auth round-trip.** `POST /oauth2/token` with
      `grant_type=password` + legacy username + legacy password
      against the F&F-owned demo Humanity account → bearer token
      issued; bearer stored in `vendor_credentials` (pgcrypto
      envelope); plaintext password never leaves the proxy memory
      hop. (Not OAuth — keyPaste auth path; the framework's OAuth
      `start → callback → token issued` row maps to "username +
      password POST → bearer issued" for Humanity.)
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Humanity v1's password-grant access tokens
      are long-lived; the framework's refresh cron is not exercised
      for this vendor at V1. Mark this row N/A and cite
      `api_consumed.md` for the long-lived-token note.
      Test: N/A — long-lived bearer per `api_consumed.md`.
- [ ] **Test connection.** Heavy sample-pull (`GET /shifts/sample`)
      returns under 30s with `fieldMapping` populated for
      `shift_start`, `shift_end`, `role_name`, `employee_id`,
      `vendor_entity_id`, `vendor_modified_at`.
      Test: `<test_path>:<line>`
- [ ] **Backfill 60-day window.** First-connect backfill against
      the demo Humanity account writes ≥1 canonical fact row;
      watermark persists per batch.
      Test: `<test_path>:<line>`
- [ ] **Polling resume.** Worker restart resumes from persisted
      cursor (no rewind, no skip). Load-bearing for Humanity since
      polling is the only live-update path (pollOnly).
      Test: `<test_path>:<line>`
- [ ] **Webhook signature verification.** N/A — Humanity does not
      support webhooks per `api_consumed.md`. The framework router
      consults `capabilityProfile.webhookSupport` before dispatch
      and never hands a webhook to the adapter; `handleWebhook`
      throws `UnsupportedError` as a defense-in-depth assertion.
      Test: N/A — see `webhook_signature.md`.
- [ ] **Idempotency.** Same Humanity `shifts.id` twice → single
      canonical write
      (`(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`).
      Test: `<test_path>:<line>`
- [ ] **Sanity hook.** Future-dated shift from sandbox → sanity_log
      row + drop.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Observed sandbox response matches
      every `documented_per_humanity_v1_0` constant in
      `humanityBackfillBatchPage1` / `Page2` /
      `humanitySampleShift` fixtures.
      Discrepancies (each as a bounded fix, not slice rebuild):
      - `<field>`: documented as X, observed Y. Fix: `<diff or PR ref>`
- [ ] **Disconnect → reconnect.** Watermark preserved; no data
      gap. Reconnect requires the operator to re-paste credentials
      (no refresh-token magic on legacy auth).
      Test: `<test_path>:<line>`
- [ ] **Permission gate.** `location_manager` 403;
      `operator_admin` 200.
      Test: `<test_path>:<line>`
- [ ] **Demo-mode flip.** First connect + first backfill commit
      flips `demo_mode_state.is_demo` to `false`.
      Test: `<test_path>:<line>`
- [ ] **Operator dashboard chrome.** `MetricCardNotYetAvailable`
      flips to live SPLH number; top-left pill drops the
      corresponding degradation line.
      Walkthrough: `docs/_walkthroughs/8.S.HM.live.sandbox.md`

**Sandbox verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `sandbox_verified` (when all
non-N/A rows ✅)

---

## Production verification (`8.S.HM.live.prod`)

Re-run the same checklist against a real operator's Humanity
credentials (provided once the operator opts in). Same table shape;
rows are independent (sandbox passing does not imply prod passing —
vendor sandboxes sometimes lie, though for Humanity sandbox and
prod share a hostname so behavior should match closely).

- [ ] (re-list every row from sandbox section above with ☐, with
      the same N/A marks for token-refresh and webhook-signature
      rows)

**Production verification verdict**: PENDING / PASS /
PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `production_credentialed` (when all
non-N/A rows ✅)
**Date partnership cleared**: N/A — Humanity has no partnership
program (cite `partnership_status.md`).
**Connect button live in admin widget**: YYYY-MM-DD

---

## First-operator-connect (automatic, no slice)

- [ ] First operator connect → lifecycle auto-promotes to
      `live_with_operators`.
- Date: YYYY-MM-DD
- Operator + location: `(<operator_id>, <location_id>)`
- Connected-operator chip in F&F Ops Console activated: YYYY-MM-DD
