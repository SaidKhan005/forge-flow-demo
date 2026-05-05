# Phase 8.live — Vendor Live Rollout

Updated: 2026-05-04
Status: Open — rolling. Closes when the last `production_credentialed` vendor reaches `live_with_operators` OR a vendor is permanently abandoned (e.g., partnership denial documented in `partnership_status.md`).
Owner: Phase 8 framework lane (engineering) + Ops (partnership lane)

> **Engineering closeout split.** Phase 8 / 8R / 8.S close as
> "engineering complete" when Wave B lands (all 17 adapters at
> lifecycle = `documented`). This phase tracks the rolling promotion
> from `documented` → `sandbox_verified` → `production_credentialed`
> → `live_with_operators`.
>
> Authority: `docs/contracts/vendor_adapter_slice_contract.md`
> (lifecycle promotion rules), `docs/contracts/per_vendor_doc_pack_contract.md`
> (per-vendor doc pack references below), `memory/project_phase_8_engineer_all_17_doctrine.md`.
>
> 2026-05-04 closeout clarification:
> `docs/_execution/2026-05-04_vendor_api_access_and_mobile_e2e_gap.md`
> is the current vendor API access / Oracle evidence memo. Wave B produces
> documented adapters; `8.integration-mobile-proof` must pass before Phase 8 /
> 8R / 8.S are accepted as product-complete engineering. `8.live` remains the
> lifecycle promotion lane once real credentials arrive.

## Goal

Promote each of the 17 INTEGRATE vendor adapters through the lifecycle
states as their sandbox / production credentials arrive. Each vendor
moves at its own pace; this phase never sprints.

## Pre-live Product Proof

`8.integration-mobile-proof` ran 2026-05-04 against master @ `07184d2` and
**FAILED** with bounded follow-up:
`docs/_execution/2026-05-04_8_integration_mobile_proof_execution.md`. Wave B
left half (vendor fixture → real adapter → canonical-fact `Map` + sanity hook
+ idempotency + watermark + signature reject + module disambiguation +
demo-mode flip policy + metric honesty plumbing) is fully proven by 279
fixture-based tests across 17 adapters + 51+ framework / dashboard / 11W
tests. Wave B right half (canonical-fact dict → `ClosedShiftInput` →
`ShiftFact` → Shift dashboard → benchmark / baseline / `DemandForecastContext`
/ `SchedulePlan` / Variance / History / Learn / mobile refresh) is
structurally absent: no concrete `OperatorScopedRepository`-backed
`*CanonicalSink` implementations, no canonical-fact-dict → `ClosedShiftInput`
aggregator service, no runtime adapter registry under `tool/advisor_proxy/`,
no `tool/integration_sync_worker/`.

Phase 8 / 8R / 8.S engineering-complete acceptance is now gated on a new
`8.spine-bridge` follow-up sprint (6 file-disjoint APP-LOGIC sub-lanes +
1 sequential proof re-run — see `PROJECT_TRACKER.md` "Active Lanes" and
the binding contract `docs/contracts/integration_spine_architecture_contract.md`)
followed by `8.integration-mobile-proof.v2` against the enriched surface.

Architecture target (from 2026-05-04 mobile drill-down): server pre-
aggregates per-vendor canonical-fact dicts into `ShiftRecord` rows on
operator-scoped Postgres; mobile SQLite is the read store; new sync
service pulls aggregated rows into mobile SQLite via the existing
`SqliteShiftRecordRepository.replaceShiftForSlot`. Existing
`ShiftFactBuilder` (pure) + `AppRuntimeInvalidationBus` (refresh signal)
+ dashboard read path stay unchanged.

The fixture-based gate's intent stays the same:

- Proof-only rule: do not change app logic, business logic, mobile UI, adapter
  behavior, schema, migrations, or cloud/runtime behavior. Allowed changes are
  limited to fixtures, test harnesses, and evidence/docs. If a product gap is
  found, record it and create a follow-up slice instead of fixing it here.
- Shift, baseline/benchmark, DemandForecastContext, SchedulePlan, Variance,
  History, and Learn respond to vendor facts.
- Missing fields produce honest fallback/unavailable states, not phantom zeros.
- Demo mode, refresh/invalidation, and local/offline cache behave correctly.

Wave D `*.live.sandbox` slices below MAY fire individual sandbox auth +
field-mapping diff portions in parallel with `8.integration-spine-bridge`,
but they cannot exercise the full mobile spine until that follow-up lands.

Evidence belongs under `docs/_execution/` and should reference the
2026-05-04 vendor API access memo.

## First Connected-Device Live Proof

After full setup is available, run `8.live.connected-device-smoke` before
trying to verify all 17 vendors live.

Preconditions:

- A connected physical device or approved emulator is available.
- The mobile app flavor/environment is known and points at the intended backend.
- Vendor credentials are present through the approved secret path.
- Vendor-location mapping is confirmed.
- At least one live-ready POS + reservation + labor/scheduling trio exists.

Scope:

- Proof-only rule: do not change app logic, business logic, mobile UI, adapter
  behavior, schema, migrations, or cloud/runtime behavior. Live findings become
  bounded follow-up slices, not same-prompt fixes.
- Start with the smallest complete trio, not all 17 vendors.
- Prove connect -> test connection -> bounded backfill -> poll/resume ->
  canonical facts -> mobile UI on the connected device.
- Do not post payments, tenders, orders, shifts, or reservations unless the
  operator explicitly approves that mutation.
- Convert findings into the rolling per-vendor `*.live.sandbox` /
  `*.live.prod` matrix.

## Per-vendor rollout shape

Two slices per vendor:

- **`<vendor_id>.live.sandbox`** (~200 LOC + walkthrough)
  - Trigger: vendor sandbox credentials in hand.
  - Runs the adapter against sandbox; fills sandbox section of
    `docs/integrations/<vendor_id>/live_verification_checklist.md`.
  - Promotes `VendorCapabilityProfile.lifecycle` to `sandbox_verified`.
  - Walkthrough at `docs/_walkthroughs/<vendor_id>.live.sandbox.md`
    shows operator-facing picker chrome change ("Coming soon" →
    "Coming soon — sandbox verified").

- **`<vendor_id>.live.prod`** (~200 LOC + walkthrough)
  - Trigger: production credentials issued by partnership +
    `partnership_status.md` shows "Production credentials issued: Y".
  - Runs the adapter against production; fills prod section of
    `live_verification_checklist.md`.
  - Promotes lifecycle to `production_credentialed`.
  - Activates Connect button in vendor picker.
  - Triggers the `vendor_now_available` email to operators who tapped
    "Notify me when ready" on this vendor's picker row (table:
    `vendor_lifecycle_notification`; email template lives in
    `tool/advisor_proxy/email_templates/`).
  - Walkthrough at `docs/_walkthroughs/<vendor_id>.live.prod.md`.

The fourth lifecycle state (`live_with_operators`) auto-promotes on
first operator connect — no slice required.

## 17 vendor rollout tracker

Single source of truth. Update each row as `*.live.*` slices land or
`partnership_status.md` changes. Engineering = `Wave B` row at slice
close (`documented`); subsequent columns flip as `*.live.*` slices fire.

| Vendor | Category | Doc pack | Source docs | Lifecycle | Sandbox slice | Prod slice | Partnership owner |
|---|---|---|---|---|---|---|---|
| Lightspeed K-Series | POS | `docs/integrations/lightspeed_lsk/` | https://api-docs.lsk.lightspeed.app/ | `documented` (post-Wave-B) | `8.LSK.live.sandbox` — pending | `8.LSK.live.prod` — pending | n/a (public OAuth) |
| Square | POS | `docs/integrations/square/` | https://developer.squareup.com/docs | `documented` | `8.SQ.live.sandbox` | `8.SQ.live.prod` | n/a (public OAuth) |
| Toast | POS | `docs/integrations/toast/` | https://doc.toasttab.com | `documented` | `8.TS.live.sandbox` | `8.TS.live.prod` | Toast Partner Program (~6-12wk) |
| Clover | POS | `docs/integrations/clover/` | https://docs.clover.com | `documented` | `8.CL.live.sandbox` | `8.CL.live.prod` | Clover App-Market (~1-3wk) |
| Revel | POS | `docs/integrations/revel/` | https://developer.revelsystems.com/ | `documented` | `8.RV.live.sandbox` | `8.RV.live.prod` | n/a (public OAuth) |
| Aloha (NCR Voyix) | POS | `docs/integrations/aloha_ncr_voyix/` | https://developer.ncrvoyix.com/ | `documented` | `8.AL.live.sandbox` | `8.AL.live.prod` | NCR Voyix Developer Program (~8-16wk) |
| Oracle MICROS Simphony | POS | `docs/integrations/oracle_micros_simphony/` | https://docs.oracle.com/en/industries/food-beverage/simphony/ | `documented` | `8.OR.live.sandbox` | `8.OR.live.prod` | Simphony Partner Integration Program (~8-16wk) |
| Libro | Reservations | `docs/integrations/libro/` | https://libroreserve.github.io/api-documentation/ | `documented` | `8R.LB.live.sandbox` | `8R.LB.live.prod` | n/a (public OAuth) |
| OpenTable | Reservations | `docs/integrations/opentable/` | partnership-only | `documented` | `8R.OT.live.sandbox` | `8R.OT.live.prod` | OpenTable Partner API (~6-12wk) |
| SevenRooms | Reservations | `docs/integrations/sevenrooms/` | https://sevenrooms.com/platform/integrations-apis/ | `documented` | `8R.SR.live.sandbox` | `8R.SR.live.prod` | SevenRooms account-rep onboarding (~4-8wk) |
| Tock | Reservations | `docs/integrations/tock/` | https://api.exploretock.com/docs/latest/reservation.html | `documented` | `8R.TC.live.sandbox` | `8R.TC.live.prod` | Tock Premium-tier negotiation (~4-8wk) |
| QuickBooks Time | Scheduling | `docs/integrations/quickbooks_time/` | https://tsheetsteam.github.io/api_docs/ | `documented` | `8.S.QBT.live.sandbox` | `8.S.QBT.live.prod` | n/a (public OAuth) |
| 7shifts | Scheduling | `docs/integrations/seven_shifts/` | https://developers.7shifts.com | `documented` | `8.S.7S.live.sandbox` | `8.S.7S.live.prod` | n/a (already onboarded) |
| ADP Workforce Now / Manager | Scheduling | `docs/integrations/adp/` | https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog | `documented` | `8.S.ADP.live.sandbox` | `8.S.ADP.live.prod` | ADP Marketplace DPA (~12-24wk) |
| Humanity (TCP) | Scheduling | `docs/integrations/humanity/` | https://platform.humanity.com/v1.0 | `documented` | `8.S.HM.live.sandbox` | `8.S.HM.live.prod` | n/a (legacy auth) |
| Agendrix | Scheduling | `docs/integrations/agendrix/` | https://developers.agendrix.com/en/documentation | `documented` | `8.S.AG.live.sandbox` | `8.S.AG.live.prod` | n/a (public OAuth) |
| Push Operations | Scheduling | `docs/integrations/push_operations/` | https://developers.pushoperations.com/ | `documented` | `8.S.PU.live.sandbox` | `8.S.PU.live.prod` | Push partner approval (~4-6wk) |

Lifecycle column flips as slices land:
- `documented` → `sandbox_verified` after `*.live.sandbox` ACCEPT.
- `sandbox_verified` → `production_credentialed` after `*.live.prod` ACCEPT.
- `production_credentialed` → `live_with_operators` auto on first operator connect.

## Slice prompt template (use for every `*.live.*` slice)

```text
## Block 1 - Human Context

Plain English: <one-line — sandbox or prod verification of vendor X>

Lane: <vendor_id>.live.<sandbox|prod> - worktree
.claude/worktrees/<lane> on branch claude/<lane> off master @ <sha>.

Authority:
- docs/contracts/vendor_adapter_slice_contract.md (lifecycle promotion rules)
- docs/integrations/<vendor_id>/ (the entire 6-file doc pack)
- docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md (this file)

Current issue:
- <vendor> credentials arrived; verify the documented adapter against
  live <sandbox/production> and promote lifecycle.

Human prerequisites:
- Setup/access needed: <vendor> <sandbox/production> credentials in
  Cloud Run secret env. If not yet provisioned: BLOCKED.
- Decision needed: none (engineering proceeds against credentials in
  hand).

## Block 2 - Claude Paste

Task:
- live verification

Files to modify:
- lib/integrations/<category>/<vendor>_<category>_adapter.dart
  (replace `// V1.live` stubs with live HTTP calls)
- docs/integrations/<vendor_id>/live_verification_checklist.md
  (fill in the <sandbox|prod> section row by row)
- docs/integrations/<vendor_id>/api_consumed.md (update retrieval
  date if any field-mapping diff was found)
- lib/services/integration/vendor_capability_registry.dart (promote
  lifecycle field for this vendor)
- docs/_walkthroughs/<vendor_id>.live.<sandbox|prod>.md NEW

Hard constraints:
- Do not update trackers.
- Do not commit unless explicitly asked.
- Stay inside scope (one vendor, one lifecycle promotion).
- Diff observed vendor responses against every
  `documented_per_<vendor>_*` constant in fixtures; flag discrepancies
  as bounded fixes; never rebuild the slice.
- Do NOT modify framework code (lib/services/integration/* core).

Implementation tasks:
1. Wire live HTTP for connect / testConnection / backfill /
   pollIncremental / handleWebhook / disconnect. Replace stubs.
2. Run the adapter against <sandbox | prod>:
   - OAuth round-trip
   - Test connection sample-pull
   - 60-day backfill
   - Polling tick (verify resume from cursor)
   - Webhook signature verification (live signature)
   - Idempotency (replay same vendor_event_id)
   - Sanity hook (try a future-dated event)
   - Disconnect → reconnect (verify watermark preserved)
3. Update each row in live_verification_checklist.md to ✅ or ❌
   with test path + line.
4. Promote lifecycle on VendorCapabilityProfile to
   <sandbox_verified | production_credentialed>.
5. (Prod only) Trigger `vendor_now_available` email to subscribers in
   `vendor_lifecycle_notification` for this vendor_id. Activate
   Connect button in vendor picker.
6. Walkthrough at docs/_walkthroughs/<vendor_id>.live.<sandbox|prod>.md
   shows the picker chrome change.

Required tests:
- Live integration test: at least one canonical fact written from
  the live <sandbox | prod> API.
- Lifecycle promotion test: VendorCapabilityProfile.lifecycle returns
  the new value.
- (Prod only) Notification fan-out test: enqueueing N rows in
  vendor_lifecycle_notification for this vendor_id triggers N
  email_outbox rows on slice land.

Acceptance criteria:
- [ ] Every checklist row in live_verification_checklist.md has ✅ or
      ❌ with cited test.
- [ ] Lifecycle promoted; capability profile updated.
- [ ] dart analyze + flutter test on touched seams → 0 issues, all green.
- [ ] Walkthrough at click-path bar.
- [ ] Discrepancies between documented vs observed are listed as
      bounded fixes in live_verification_checklist.md (PR ref each).

Report using the standard execution report.
```

## Closeout

Phase 8.live closes when EITHER:
- All 16 INTEGRATE vendors that have a path to production reach
  lifecycle = `production_credentialed` (Resy is permanently
  uncovered — does not gate closeout). Document each closure in
  `partnership_status.md` and the table above.
- Or a vendor is permanently abandoned (partnership denied AND F&F
  decides not to retry); document the abandonment in
  `partnership_status.md` and remove the vendor from the picker via a
  follow-up framework slice.

After closeout, the rolling lifecycle promotion to
`live_with_operators` (first operator connect) continues automatically
without slice work. This phase doc archives to `docs/archive/phases/`.

## Cross-references

- `docs/_execution/2026-05-04_vendor_api_access_and_mobile_e2e_gap.md` - vendor API access matrix, Oracle payment-orchestrator evidence, and product-proof gates.

- `docs/contracts/vendor_adapter_slice_contract.md` — lifecycle
  promotion rules + verdict table.
- `docs/contracts/per_vendor_doc_pack_contract.md` — the doc pack
  the `*.live.*` slices read + write.
- `docs/integrations/<vendor_id>/` — per-vendor doc pack (17
  folders).
- `docs/phases/phase_8/vendor_master_list.md` — Wave A / B / D plan.
- `docs/phases/phase_8/vendor_connections_admin_surface.md` — picker
  chrome that surfaces the lifecycle.
- `memory/project_phase_8_engineer_all_17_doctrine.md` — durable
  decision lock for engineer-all-17.
