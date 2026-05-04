# ADP Workforce Now / Workforce Manager — Live Verification Checklist

**Vendor ID**: `adp`
**Engineering slice**: `8.S.ADP`
**`*.live.sandbox` slice**: `8.S.ADP.live.sandbox` — pending
**`*.live.prod` slice**: `8.S.ADP.live.prod` — pending
**Lifecycle**: `documented` (will promote on first verification slice)

This checklist is filled in as the `*.live.sandbox` and `*.live.prod`
slices run. The engineering slice ships this file with all checkboxes
empty. Per `docs/contracts/per_vendor_doc_pack_contract.md`, every
row below MUST be present.

---

## Sandbox verification (`8.S.ADP.live.sandbox`)

Cite the test that proved each check passed; cite the bounded fix
that resolved each check that failed.

- [ ] **Auth round-trip.** OAuth start → callback → token issued
      successfully against ADP Marketplace partner sandbox (per
      module — WFN and WFM tested independently).
      Test: `<test_path>:<line>`
- [ ] **Token refresh.** Refresh cron extends a near-expiry token
      against vendor sandbox.
      Test: `<test_path>:<line>`
- [ ] **Test connection.** Heavy sample-pull returns under 30s with
      `fieldMapping` populated (`shift_start`, `shift_end`,
      `role_name`, `employee_id`, `vendor_entity_id`,
      `vendor_modified_at`, `module` plus the `assumption: true`
      flag from this slice's offline path is cleared once observed
      values match).
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
- [ ] **Module disambiguation (3 modules).** Three independent
      connect rounds verify the load-bearing pattern:
      - WFN module connect succeeds against sandbox.
      - WFM module connect succeeds against sandbox.
      - RUN module refused at connect with the EXACT friendly copy
        from `vendor_master_list.md`. Refusal flow renders verbatim
        in the picker / connect modal; no token exchange occurs;
        no canonical-fact write.
      Test: `<test_path>:<line>`
- [ ] **Field-mapping diff.** Observed sandbox response matches every
      `documented_per_adp_*` constant in fixtures
      (`documentedPerAdpV1FieldMapping` and the fixture mirror).
      EVERY documented assumption is listed below for the
      `*.live.sandbox` slice to diff per module. Discrepancies (each
      as a bounded fix, not slice rebuild):
      - `time_event.id` exact path — documented `string`. Verify
        per module (some WFN endpoints use `time_event.itemID`,
        WFM uses `timePunch.punchID`). Fix: `<diff or PR ref>`
      - `time_event.entry_date_time` shape — documented ISO-8601
        with `Z`. Verify presence of `Z`. Fix: `<diff or PR ref>`
      - `time_event.exit_date_time` open-punch sentinel — documented
        `null`. Verify ADP emits null vs another sentinel. Fix:
        `<diff or PR ref>`
      - `time_event.last_modified_date_time` shape — documented
        ISO-8601 with `Z`. Verify presence + format. Fix:
        `<diff or PR ref>`
      - `worker.position.position_title` (WFN) vs
        `worker.workAssignment.jobTitle` (WFM) — verify which path
        each module returns; remove the dead branch in the
        canonicalizer fallback chain. Fix: `<diff or PR ref>`
      - `worker.associate_oid` shape — documented stable string
        across worker lifecycle. Verify cross-tenure stability via
        a re-hire scenario. Fix: `<diff or PR ref>`
      - OAuth flow — documented `authorization_code`. Verify exact
        grant type + scope strings + production mTLS layering.
        Fix: `<diff or PR ref>`
      - OAuth token TTLs — documented 1h access / 90d rotating
        refresh. Verify exact lifetimes per module. Fix: `<diff or
        PR ref>`
      - Webhook signature algorithm — documented HMAC-SHA256.
        Verify exact algorithm + signed-payload byte sequence.
        Fix: `<diff or PR ref>`
      - Webhook signature header — documented `ADP-Signature`,
        base64. Verify exact header + encoding. Fix: `<diff or
        PR ref>`
      - Webhook timestamp header — documented
        `ADP-Signature-Timestamp`, Unix epoch seconds. Verify
        presence + format. Fix: `<diff or PR ref>`
      - Event subscription auto-register — documented
        `POST /core/v1/event-subscriptions`. Verify endpoint + body
        shape. Fix: `<diff or PR ref>`
      - Event name — documented `time.timeEvent.modify`. Verify
        event vocabulary; switch subscription if per-status events
        exist instead. Fix: `<diff or PR ref>`
      - Time-events endpoint — documented `GET /time/v2/workers/
        {associate_oid}/team-time-cards` with cursor pagination.
        Verify path + pagination shape per module. Fix: `<diff or
        PR ref>`
      - Workers endpoint — documented `GET /hr/v2/workers`. Verify
        path. Fix: `<diff or PR ref>`
      - Operator-wide grant scope — documented
        `VendorGrantScope.operatorWide`. Verify a single OAuth
        grant covers all of the operator's ADP worksites. Fix:
        `<diff or PR ref>`
      - Replay defense — documented 24h tolerance per V1 lean cut
        2. Verify framework ceiling matches observed vendor retry
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
      flips to live number; top-left pill drops the corresponding
      degradation line.
      Walkthrough: `docs/_walkthroughs/8.S.ADP.live.sandbox.md`

**Sandbox verification verdict**: PENDING / PASS / PASS_WITH_BOUNDED_FIXES
**Lifecycle promoted to**: `sandbox_verified` (when all rows ✅)

---

## Production verification (`8.S.ADP.live.prod`)

Re-run the same checklist against production credentials issued by
the ADP Marketplace DPA. Same table shape; rows are independent
(sandbox passing does not imply prod passing — vendor sandboxes
sometimes lie). Production additionally requires mutual TLS — the
mTLS cert pair lands as part of the production credential issuance.

- [ ] **Auth round-trip.** Production OAuth start → callback → token
      issued (per module).
      Test: `<test_path>:<line>`
- [ ] **Mutual TLS handshake.** Adapter completes mTLS against
      production endpoints with partner-issued certs.
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
- [ ] **Module disambiguation (3 modules).** WFN + WFM succeed
      against production; RUN refused with verbatim friendly copy.
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
- [ ] **Operator dashboard chrome.** Live numbers on the SPLH /
      CPLH cards (paired with the connected ADP labor adapter);
      pill drops the labor-degradation line.
      Walkthrough: `docs/_walkthroughs/8.S.ADP.live.prod.md`

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
