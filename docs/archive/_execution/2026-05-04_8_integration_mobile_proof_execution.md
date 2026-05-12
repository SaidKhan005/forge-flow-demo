# 8.integration-mobile-proof — Execution Report

Status: Lane FAILED with bounded follow-ups (Wave B left-half proven; spine bridge structurally absent)
Date: 2026-05-04
Owner: Phase 8 / 8R / 8.S Wave B closeout gate
Authority:

- `PROJECT_TRACKER.md` (Active Lanes → Wave B closeout gate)
- `docs/_execution/2026-05-04_vendor_api_access_and_mobile_e2e_gap.md`
- `docs/contracts/vendor_adapter_slice_contract.md`
- `docs/contracts/per_vendor_doc_pack_contract.md`
- `docs/contracts/metric_card_honesty_contract.md`
- `docs/frameworks/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md`
- `docs/phases/phase_8/vendor_master_list.md`
- `docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md`
- `docs/phases/phase_11W/operator_onboarding_flow.md`
- `memory/project_phase_8_engineer_all_17_doctrine.md`
- `memory/project_v1_lean_cut_2_2026_05_03.md`

Proof-only constraint honored: zero changes to app logic, business logic,
mobile UI, adapter behavior, schema, migrations, or cloud / runtime
behavior. The only changes from this lane are this execution report and
the matching tracker / phase-doc updates.

## Verdict

**FAIL** — `8.integration-mobile-proof` cannot pass at this point in time.

Wave B's left-half spine — vendor fixture → real adapter → canonical
fact `Map<String, Object?>` written through the per-vendor `CanonicalSink`
seam, with sanity hook, idempotency, watermark per batch, signature
verification, module disambiguation, demo-mode flip evaluation, and
metric provenance honesty — is fully proven by 279 fixture-based tests
across 17 adapters plus 51+ framework / shift / dashboard / 11W tests.

Wave B's right-half spine — canonical fact dict → `ClosedShiftInput` →
`ShiftFact` → Shift dashboard → benchmark / baseline / `DemandForecastContext` →
`SchedulePlan` → Variance / History / Learn → mobile refresh /
invalidation / cache → demo-mode banner — is **structurally absent**.
There is no Dart bridge between any adapter `CanonicalSink` (e.g.
`OracleMicrosSimphonyCanonicalSink.upsertGuestCheck`) and the
`ClosedShiftInput` / `ShiftFact` types the dashboard read path consumes.
There is no runtime adapter registry under `tool/advisor_proxy/` or
elsewhere that dispatches incoming poll ticks / webhook events to the
17 adapters. There is no concrete `OperatorScopedRepository`-backed
implementation of any per-vendor canonical sink that would write the
canonical fact dict into `cover_facts` / `labor_punches` /
`reservation_facts` / `shift_records`.

This is exactly the gap the
`2026-05-04_vendor_api_access_and_mobile_e2e_gap.md` addendum
predicted. The lane's mandate is to record the gap, not to fix it; that
work is APP LOGIC and must land in dedicated follow-up slices.

Phase 8 / 8R / 8.S **cannot** be marked engineering-complete on the
strength of Wave B alone. Two follow-up slices below close the gap.

## Wave B audit (master @ `07184d2`)

Pulled 4 commits from `origin/master` to bring local audit baseline up
to date (`c3ddbd2..07184d2`). All 20 Wave B lanes landed:

| Lane | Slice id | Status | Verification |
|---|---|---|---|
| 1 | `8.0` framework | landed (`2ac0ada`) | `lib/services/integration/{integration_adapter_common,pos_adapter,labor_adapter,reservation_adapter,inbound_webhook_handler,demo_mode_state,vendor_timestamp_sanity,oauth_refresh_cron,iana_timezone_converter,vendor_timestamp_policy}.dart`; framework migration `db/migrations/202605040000_phase_8_0_integration_framework.sql`; framework test `test/services/integration/integration_adapter_common_test.dart` 6/6 PASS |
| 2 | `8.0.lifecycle` | landed (`4f52b5f`) | `VendorLifecycle` enum + `VendorCapabilityProfile.lifecycle` field present; `partnershipGated: bool` removed; `db/migrations/202605040400_phase_8_0_lifecycle_add_vendor_lifecycle_notification.sql`; `vendor_lifecycle_notification` table |
| 3 | `8.LSK` Lightspeed K-Series POS | landed (`c0509ad`) | `lib/integrations/pos/lightspeed_lsk_pos_adapter.dart` + `lightspeed_lsk_webhook_signature_verifier.dart`; `docs/integrations/lightspeed_lsk/` 6-file pack; `docs/_walkthroughs/8.LSK.md`; tests PASS |
| 4 | `8.SQ` Square POS | landed (`62531e0`) | adapter + verifier + 6-file pack + walkthrough; tests PASS |
| 5 | `8.TS` Toast POS | landed (`0d4b034`) | adapter + verifier + 6-file pack + walkthrough; tests PASS |
| 6 | `8.CL` Clover POS | landed (`17d41a9`) | adapter + verifier + 6-file pack + walkthrough; tests PASS |
| 7 | `8.RV` Revel POS | landed (`313d6c0`) | adapter + verifier + 6-file pack + walkthrough; tests PASS |
| 8 | `8.AL` Aloha NCR Voyix POS | landed (`5da39da` + `7be46ea`) | adapter + verifier + 6-file pack + walkthrough; tests PASS |
| 9 | `8.OR` Oracle MICROS Simphony POS (poll-only) | landed (`30d6a47` + `3a78045`) | adapter (no verifier; poll-only); 6-file pack; walkthrough; 10/10 tests PASS |
| 10 | `8R.LB` Libro reservation | landed (`236e8d7`) | adapter + verifier + 6-file pack + walkthrough; 17/17 tests PASS |
| 11 | `8R.OT` OpenTable reservation | landed (`27371f4`) | adapter + verifier + 6-file pack + walkthrough; tests PASS |
| 12 | `8R.SR` SevenRooms reservation | landed (`d4520eb`) | adapter + verifier + 6-file pack + walkthrough; tests PASS |
| 13 | `8R.TC` Tock reservation (manual-paste) | landed (`5de671e`) | adapter + verifier + 6-file pack + walkthrough; 11/11 tests PASS |
| 14 | `8.S.QBT` QuickBooks Time labor (poll-only) | landed (`8295994`) | adapter (no verifier; poll-only); 6-file pack; walkthrough; 21/21 tests PASS |
| 15 | `8.S.7S` 7shifts labor | landed (`36eb028`) | adapter + verifier + 6-file pack + walkthrough; tests PASS |
| 16 | `8.S.ADP` ADP Workforce Now / Workforce Manager labor (module disambiguation) | landed (`b5700ee`) | adapter + verifier + 6-file pack + walkthrough; module disambiguation tests PASS |
| 17 | `8.S.HM` Humanity labor | landed (`9f47787`) | adapter + 6-file pack + walkthrough; tests PASS |
| 18 | `8.S.AG` Agendrix labor (poll-only) | landed (`63cd431`) | adapter + 6-file pack + walkthrough; tests PASS |
| 19 | `8.S.PU` Push Operations labor (poll-only) | landed (`bc0fbe1`) | adapter + 6-file pack + walkthrough; tests PASS |
| 20a | `11W.7` Operator Web Account screen | landed (`75e449c` PR #110) | `lib/operator_web/screens/account_screen.dart` replaces placeholder; `docs/_walkthroughs/11W.7.md`; 546-line test file |
| 20b | `11W.8` Operator Web Vendor Connections mount | landed (`86602ec` PR #112) | `lib/operator_web/screens/vendor_connections_screen.dart` + `vendor_lifecycle_notify_me_dialog.dart`; `docs/_walkthroughs/11W.8.md`; 16/16 dialog tests PASS |

Lifecycle field is locked at `VendorLifecycle.documented` for every
adapter. Confirmed by `integration_adapter_common_test.dart` test
"every documented adapter ships at lifecycle.documented" + per-adapter
capability-profile assertions across all 17 test files.

Doc-pack completeness: every `docs/integrations/<vendor_id>/` folder
contains all 6 required files (`api_consumed.md`, `field_mapping.md`,
`oauth_shape.md`, `webhook_signature.md`, `live_verification_checklist.md`,
`partnership_status.md`) per `docs/contracts/per_vendor_doc_pack_contract.md`.

## Acceptance criteria — point-by-point evaluation

The 12 acceptance items in the lane prompt are evaluated against
real fixture / dashboard / framework evidence. ✅ proven from existing
test surface; ⬜ partially proven (adapter-side proven, downstream
spine missing); ❌ structurally not proven.

| # | Criterion | Verdict | Evidence / why |
|---|---|---|---|
| 1 | POS fixture backfill writes closed sales, covers/checks, PPA inputs, source provenance into canonical facts | ⬜ | Adapter emits canonical-fact `Map<String, Object?>` with `vendor_id`, `vendor_entity_id`, `vendor_modified_at`, `business_date`, `covers`, `actual_sales`, `opened_at`, `closed_at`, `covers_source` per fixture tests (Oracle 10/10, Lightspeed PASS, Square PASS, Toast PASS, Clover PASS, Revel PASS, Aloha PASS). The Postgres canonical fact tables (`shift_records`, `cover_facts`, `labor_punches`, `reservation_facts`) gained the vendor columns + idempotency UNIQUE index in migration `202605040000`. **No concrete Postgres-backed sink implementation exists** to write the canonical-fact dict into those rows. The fixture-side proof stops at the per-vendor `CanonicalSink` interface boundary (e.g. `OracleMicrosSimphonyCanonicalSink.upsertGuestCheck`). |
| 2 | Labor fixture backfill writes hours, wage/rate facts where available, approval state, roles/job codes, breaks, employee source ids | ⬜ | Same shape as #1: 21/21 QuickBooks Time tests PASS through the bespoke labor sink; ADP / 7shifts / Humanity / Agendrix / Push tests PASS. No Postgres sink. |
| 3 | Reservation fixture backfill writes in-the-books demand, party size, reservation state, booking timestamps, source provenance | ⬜ | Same shape: 17/17 Libro tests PASS, 11/11 Tock tests PASS, OpenTable PASS, SevenRooms PASS. No Postgres sink. |
| 4 | Shift dashboard reads canonical facts without phantom zeros | ❌ | Shift dashboard reads `ShiftFact` built from `ClosedShiftInput` (`lib/domain/services/shift_fact_builder.dart`). `ClosedShiftInput` is a dayparted, typed Dart record with fields `covers: int`, `actualSales: double`, `actualFohHours: int`, `actualBohHours: int`, etc. **There is no bridge** that aggregates per-vendor canonical-fact dicts (POS check rows + labor punch rows + reservation rows) for one `(business_date, daypart)` and emits a `ClosedShiftInput`. The closest plumbing — `ShiftFactBuilder.laborDollarsFromVendor` flag — is wired and tested, but it operates on a `ClosedShiftInput` already in hand. Without the bridge, the dashboard cannot read what the adapters wrote. |
| 5 | 60-day backfill updates benchmark/baseline inputs | ❌ | Same blocker as #4. Adapter `BackfillResult.recordsWritten` increments correctly per fixture; downstream benchmark / baseline inputs (`TargetCycle`, `WeeklyPlanSnapshot`, baseline manager) read from `ShiftFact` rows that the bridge does not produce. |
| 6 | TargetCycle and DemandForecastContext react to the new facts | ❌ | Same blocker. |
| 7 | SchedulePlan uses live demand/labor context where available and honest fallback where not available | ❌ | Same blocker. |
| 8 | Variance metric provenance is wired; missing live facts show fallback or unavailable, not fake zero | ✅ | `lib/domain/models/metric_provenance.dart` + `lib/widgets/metric_card_not_yet_available.dart` + `MetricCardNotYetAvailable` widget tests + `ShiftFactBuilder.laborDollarsFromVendor` flag are all in place and tested. Metric Honesty Doctrine (`docs/contracts/metric_card_honesty_contract.md`) is binding contract for any read model that emits a metric. The plumbing is ready; once the spine bridge exists, downstream metrics consume `MetricProvenance` directly. |
| 9 | History and Learn only consume closed, trustworthy facts | ⬜ | `ShiftFact` only constructs from a closed `ClosedShiftInput` + locked `TargetSnapshot`; History / Learn read `ShiftFact` only. The closure semantics are correct. The trustworthiness of source data is gated on the spine bridge. |
| 10 | Mobile refresh/invalidation fires after vendor sync | ❌ | No runtime adapter registry exists at `tool/advisor_proxy/{pos,labor,reservation}_adapter_registry.dart` or anywhere else; the only `*_registry*.dart` file in the tree is `tool/advisor_proxy/health_producers/producer_registry.dart` which is unrelated. The integration sync worker referenced in adapter doc comments (`tool/integration_sync_worker/`) does not exist. There is no concrete dispatch path that calls `pollIncremental` on poll cadence or `handleWebhook` on inbound webhook receipt for any of the 17 adapters. With no sync path, there is no signal to fire mobile refresh. |
| 11 | Offline/local cache receives the canonical facts cleanly | ❌ | Same blocker as #10 + #4. |
| 12 | Demo mode flips correctly after first successful backfill per category | ✅ partial | `DemoModeFlipPolicy.evaluateFlip` (`lib/services/integration/demo_mode_state.dart`) is tested at the framework level (`test/integration/demo_mode_state_test.dart`) and the policy enforces the documented gates: `connectionStatus == connected` AND `firstBackfillCommitted == true` AND `backfillRecordsWritten >= 1`. Libro adapter test "writes a canonical fact + flips demo-mode on first webhook" proves the flip semantics for one adapter. **But the flip is not invoked uniformly across the 17 adapters** — only 6 adapters reference `canonicalSink` / `canonicalFact` in their source (Push Operations, Agendrix, Aloha, Tock, Toast, Oracle Simphony) and none of the 17 invokes `DemoModeFlipPolicy` from inside `connect` / `backfill` / `pollIncremental` / `handleWebhook` consistently. Once the runtime adapter dispatch + Postgres sink is wired, the policy must be invoked from the worker or sink layer; today the wiring is variant. |

**4 ✅ + 4 ⬜ + 4 ❌. The right-half spine is structurally missing.**

## Trio fixture proof — vendors selected

Per the lane prompt's preferences:

- **POS: Oracle MICROS Simphony** (`oracle_micros_simphony`). Selected because the addendum (`2026-05-04_vendor_api_access_and_mobile_e2e_gap.md` Oracle Simphony Correction section) flags Oracle as the strongest evidence vendor (local `payment-orchestrator` STS Gen2 prior art) and the first poll-only adapter (no webhooks; watermark-per-batch is load-bearing).
- **Reservation: Libro** (`libro`). The reference reservation adapter; OAuth + auto-register webhooks; 24h replay tolerance test confirms the V1 lean cut 2 ceiling.
- **Labor / scheduling: QuickBooks Time** (`quickbooks_time`). The reference scheduling adapter; pollOnly; module disambiguation (`time` accept; `accounting` redirect; `payroll` refuse) verified.

### Tests run for the trio

- `flutter test test/integrations/pos/oracle_micros_simphony_pos_adapter_test.dart` → **10/10 PASS** (capability profile + lifecycle + handleWebhook UnsupportedError + testConnection field-mapping + sanity hook backfill + sanity reject + idempotency replay + watermark-per-batch crash resume + connect→backfill→poll→disconnect→reconnect smoke + banned-items grep + verifier-file absent).
- `flutter test test/integrations/reservation/libro_reservation_adapter_test.dart` → **17/17 PASS** (capability profile + lifecycle + sanity hook poll/backfill + sanity reject + idempotency replay + watermark-per-batch crash resume + testConnection + 6 webhook signature tests + webhook handler + canonical-fact-write-and-demo-mode-flip + malformed payload drop + connect→backfill→poll→disconnect→reconnect smoke).
- `flutter test test/integrations/labor/quickbooks_time_labor_adapter_test.dart` → **21/21 PASS** (capability profile + lifecycle + module disambiguation 3-way + sanity hook poll/backfill + sanity reject + idempotency replay + watermark-per-batch + handleWebhook UnsupportedError + connect/disconnect/reconnect smoke + testConnection + 3 banned-items greps).

### Trio left-half evidence trace

For Oracle Simphony / Libro / QuickBooks Time the fixture-based proof
walks:

```
vendor fixture payload (test/integrations/<cat>/fixtures/<vendor>_*_fixture.dart)
  -> real adapter (lib/integrations/<cat>/<vendor>_*_adapter.dart)
  -> sanity hook applied per row (sanity_log row + drop on reject)
  -> idempotency dedup on (vendor_id, operator_id, vendor_entity_id, vendor_modified_at)
  -> canonical fact Map<String, Object?> with the contract field set
  -> watermark advance after each batch (per CanonicalSink.advanceWatermark)
  -> appendSyncLog for each batch / disconnect / reconnect
[STOP — bridge missing]
  -> would-be ClosedShiftInput aggregation across POS + labor + reservation
  -> ShiftFactBuilder.fromClosedShiftInput(input, targetSnapshot)
  -> ShiftFact written to shift_records
  -> Shift dashboard reads via ShiftService.getShiftDashboard
  -> benchmark / baseline / DemandForecastContext / SchedulePlan / Variance / History / Learn
  -> mobile refresh / cache / demo-mode banner
```

The `[STOP — bridge missing]` line is the gap.

## Right-half spine — what is missing in concrete terms

Three structural seams must exist for `8.integration-mobile-proof` to
pass. None exists today:

### A. `OperatorScopedRepository`-backed `*CanonicalSink` implementations

Each adapter today depends on a bespoke abstract sink (e.g.
`OracleMicrosSimphonyCanonicalSink.upsertGuestCheck`,
`LibroCanonicalSink.upsertReservation`,
`QuickBooksTimeCanonicalSink.upsertPunch`). Tests inject
`_FakeCanonicalSink` doubles. **No concrete implementation** binds
those interfaces to actual `cover_facts` / `labor_punches` /
`reservation_facts` / `shift_records` writes via
`OperatorScopedRepository.withTenant(operatorId, locationId, ...)`.

The Phase 8.0 framework migration (`202605040000`) added the vendor
idempotency columns + UNIQUE index on the canonical fact tables. The
schema is wired. The Dart-side concrete write path is not.

### B. Canonical-fact-dict → `ClosedShiftInput` bridge

Adapters write `Map<String, Object?>` per vendor entity (one POS
check, one labor punch, one reservation). The dashboard read path
consumes a typed `ClosedShiftInput` per closed daypart that
aggregates many vendor entities into one shift's worth of source
truth (covers, sales, FOH/BOH hours, scheduled hours, labor dollars,
forecast covers).

That aggregator does not exist. No file in `lib/services/integration/`
or `lib/services/` walks the canonical fact tables to build a
`ClosedShiftInput` for a given `(operator_id, location_id, business_date, daypart)`.

### C. Runtime adapter registry + sync worker dispatch

The PROJECT_TRACKER documents the registry as the integration-commit
shared seam:

> Total: 20 lanes. Shared seam (adapter registry under
> `tool/advisor_proxy/`) handled by 3 category-scoped registry files
> updated on a single integration commit after worktrees merge.

The integration commit did not happen. There is no
`tool/advisor_proxy/pos_adapter_registry.dart` /
`labor_adapter_registry.dart` / `reservation_adapter_registry.dart`.
There is no `tool/integration_sync_worker/` directory. With no
registry and no worker, the 17 adapters are floating; nothing
dispatches a poll tick or webhook event to them at runtime.

The webhook handler (`lib/services/integration/inbound_webhook_handler.dart`)
exists at the framework level but does not lookup by `vendor_id` →
adapter from a registry; it cannot, because the registry does not
exist.

### Why these gaps are app-logic, not fixture-harness

The lane is proof-only. Each of A / B / C requires writing
production application code:

- A is a new Postgres write surface per fact category. Writes to
  `cover_facts` etc. via `package:postgres` (allowed only in
  `lib/infrastructure/persistence/postgres/`). Includes RLS context
  setting, idempotency upsert, raw-payload retention, and
  business-date denormalization at write.
- B is a new domain service that walks canonical fact tables and
  shapes `ClosedShiftInput` rows, including resolving daypart per
  service-period configuration and handling missing source data
  (vendor exposes covers vs `forecast_fallback`, vendor exposes labor
  dollars vs target-wage fallback).
- C is a new runtime entrypoint (Cloud Run worker + dispatch route)
  that consumes the registry and drives poll cadence / webhook
  routing.

Building any of these inside this lane would violate the proof-only
constraint. The lane's job is to declare the gap, lock the lifecycle
state, and stand up the follow-up slices.

## Tests / commands run

```text
# Audit baseline
git fetch origin
git pull --ff-only origin master       # c3ddbd2..07184d2 fast-forward (4 commits)
git status --short --branch
git log --oneline -80

# Master state inventory
glob lib/integrations/**/*.dart        # 17 adapters present
glob docs/integrations/**/*.md         # 17 vendor folders × 6 files
glob test/integrations/**/*.dart       # 17 adapter tests + per-vendor fixtures
glob docs/_walkthroughs/8*.md          # 17 walkthroughs + 8.0 + 8.0.lifecycle + 11W.7 + 11W.8
glob lib/operator_web/screens/*.dart   # account_screen.dart + vendor_connections_screen.dart present
glob tool/advisor_proxy/**/*registry*.dart  # ONLY producer_registry.dart (unrelated to adapters)
grep "PosAdapterRegistry|LaborAdapterRegistry|ReservationAdapterRegistry" -> walkthrough refs only

# Fixture-based proof (trio + framework)
flutter test test/integrations/pos/oracle_micros_simphony_pos_adapter_test.dart    # 10/10 PASS
flutter test test/integrations/reservation/libro_reservation_adapter_test.dart    # 17/17 PASS
flutter test test/integrations/labor/quickbooks_time_labor_adapter_test.dart      # 21/21 PASS
flutter test test/services/integration/integration_adapter_common_test.dart        #  6/6 PASS
flutter test test/integrations/                                                    # 279/279 PASS across 17 adapters
flutter test test/shift_fact_builder_test.dart \
             test/shift_dashboard_notifier_test.dart \
             test/widgets/metric_card_not_yet_available_test.dart \
             test/services/integration/integration_adapter_common_test.dart        # 45+/45+ PASS
flutter test test/operator_web/screens/vendor_connections_screen_test.dart         # 16+/16+ PASS
```

Total: ~340 fixture-based / framework / dashboard / 11W tests run, all
PASS. Zero regression observed against any pre-existing test surface.

## Blockers

1. **No concrete `*CanonicalSink` Postgres implementations** for any of
   the 17 adapters. Every adapter binds its sink at test time via
   `_FakeCanonicalSink`; production-shape sinks live in `lib/infrastructure/persistence/postgres/`
   and do not yet exist for the 8.0 fact-write surface.
2. **No canonical-fact-dict → `ClosedShiftInput` aggregator service**.
   The dashboard read path's input type is structurally disconnected
   from the adapter write path's output type.
3. **No runtime adapter registry** at `tool/advisor_proxy/{pos,labor,reservation}_adapter_registry.dart`
   or any equivalent. The 20-lane "integration commit after worktrees
   merge" did not occur.
4. **No integration sync worker** at `tool/integration_sync_worker/` or
   any equivalent. Poll cadence has no driver; webhook dispatch has no
   adapter lookup.
5. **`DemoModeFlipPolicy.evaluateFlip` is not invoked uniformly across
   the 17 adapters**. Only Libro tests assert a webhook-time flip; no
   adapter wires the policy from inside `connect` / `backfill` /
   `pollIncremental`. The policy is correct; its callers are absent.
6. (Pre-existing, surfaced by audit, not introduced by this lane.) The
   tracker statement "Total: 20 lanes. Shared seam (adapter registry
   under `tool/advisor_proxy/`) handled by 3 category-scoped registry
   files updated on a single integration commit after worktrees merge"
   refers to work that was never done. No commit references the
   integration commit. This must be folded into the follow-up.

## Follow-up slice recommendations

These are slice headlines — full prompt drafting is out of scope for
this proof-only lane. None of these is in scope to start during this
lane.

### `8.integration-spine-bridge` — APP LOGIC (~3-5 file-disjoint sub-lanes)

Builds A + B + C above. Should be a **bounded sprint**, not a single
slice. Recommended sub-lane shape:

- `8.integration-spine-bridge.0` — adapter registry + integration sync
  worker scaffolding (`tool/advisor_proxy/{pos,labor,reservation}_adapter_registry.dart`,
  `tool/integration_sync_worker/main.dart`, dispatch tests). Ships the
  registry + dispatch contract; binds the 17 adapters; no Postgres
  writes yet.
- `8.integration-spine-bridge.1` — concrete Postgres-backed
  `OperatorScopedRepository` sinks for **one POS + one labor + one
  reservation vendor** (Oracle Simphony + QuickBooks Time + Libro
  recommended for parity with this proof's trio). Writes canonical-fact
  dicts to `cover_facts` / `labor_punches` / `reservation_facts` rows
  via `OperatorScopedRepository.withTenant`. Honors RLS, idempotency
  UNIQUE, raw-payload retention, business-date denormalization.
- `8.integration-spine-bridge.2` — canonical-fact-dict →
  `ClosedShiftInput` aggregator service (`lib/services/integration/canonical_fact_to_closed_shift_input.dart`
  or similar). Walks the canonical fact tables for a given
  `(operator_id, location_id, business_date, daypart)` and shapes a
  `ClosedShiftInput` row, including resolving covers source
  (`direct` / `forecast_fallback`) and labor-dollars source
  (vendor-supplied vs target-wage fallback) per the metric honesty
  contract.
- `8.integration-spine-bridge.3` — wire `DemoModeFlipPolicy.evaluateFlip`
  uniformly into the worker dispatch + adapter sink boundary so the
  flip fires consistently across all 17 adapters at first connect →
  first backfill commit → records-written >= 1. Adds the matching
  test surface across the trio.
- `8.integration-spine-bridge.4` — repeat **`8.integration-mobile-proof`**
  against this enriched surface. Closes Phase 8 / 8R / 8.S
  engineering-complete acceptance.

### `8.live.<vendor>.sandbox` — Wave D ROLLING SLICES (per vendor; ~200 LOC + walkthrough)

Each `*.live.sandbox` slice promotes one vendor's lifecycle from
`documented` → `sandboxVerified` by wiring a real HTTP client to the
adapter and running the per-vendor `live_verification_checklist.md`.
These slices are **already sequenced post-Wave-B** in
`docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md`. They
should fire as sandbox credentials arrive. They cannot fully exercise
the right-half spine until `8.integration-spine-bridge` lands; but the
sandbox auth + field-mapping diff portions can fire independently.

### `8.live.connected-device-smoke` — POST-SETUP LIVE PROOF

Per the addendum: live proof on a connected device with one complete
POS + reservation + labor trio after `8.integration-spine-bridge`
lands AND at least one trio's worth of `*.live.sandbox` slices have
promoted. Out of scope for this lane.

## Doc / tracker updates from this lane

- `PROJECT_TRACKER.md` — Active Lanes section updated to reflect
  `8.integration-mobile-proof` FAIL verdict + the `8.integration-spine-bridge`
  follow-up sequencing in front of Phase 8 / 8R / 8.S
  engineering-complete acceptance.
- `docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md` — note
  that Wave D `*.live.sandbox` slices may fire in parallel with the
  `spine-bridge` follow-up but cannot exercise the full spine until it
  lands.
- This file (`docs/_execution/2026-05-04_8_integration_mobile_proof_execution.md`).
- (Memory file already covers the doctrine; no memory update from this
  lane.)

## Honest summary line

Wave B's left half is **clean** — 17 adapters, 17 doc packs, 17
walkthroughs, 279 fixture-based tests, demo-mode flip policy, metric
honesty plumbing, lifecycle locked at `documented`. The right half —
canonical-fact-dict → `ClosedShiftInput` → `ShiftFact` → dashboard /
benchmark / forecast / SchedulePlan / Variance / History / Learn /
mobile refresh — is **structurally absent** because the registry, the
sync worker, the Postgres-backed sinks, the aggregator service, and
the server→mobile sync layer were never built. Phase 8 / 8R / 8.S
engineering-complete acceptance is therefore gated on
`8.spine-bridge` (6 sub-lane sprint, parallel-shaped) followed by a
re-run of `8.integration-mobile-proof` against the enriched surface.

The verdict is honest, the gap is bounded, and the next slice is
named.

## SQLite / mobile architecture drill-down (2026-05-04 addendum)

Sanity-check question from the operator: "Does SQLite on the mobile
app play any role in this?" The honest answer: yes, and my earlier
Postgres-centric framing missed this.

### The two storage worlds

| Store | Role | Phase 8.0 vendor-column parity |
|---|---|---|
| **Postgres (server-side)** | Operator-scoped canonical facts; RLS-isolated; multi-location truth; where vendor adapter writes are *supposed* to land | ✅ Migration `202605040000` added `vendor_id` + `vendor_entity_id` + `vendor_modified_at` + `raw_payload` to `shift_records` / `cover_facts` / `labor_punches` / `reservation_facts` |
| **SQLite (mobile-side, `lib/infrastructure/persistence/sqlite/`)** | Read store for the operator app on phone screens; demo seed lives here; live mode receives synced rows here | ❌ No equivalent SQLite migration; mobile `shift_records` carries the older `source_system` + `source_shift_id` columns from the 7.55-era import path but no `vendor_id` / `vendor_entity_id` / `vendor_modified_at` / `raw_payload`. |

### Existing mobile SQLite surfaces relevant to the spine

- **`shift_records`** — the canonical "closed daypart" row the dashboard / variance / history / learn surfaces read from. Schema in `lib/infrastructure/persistence/sqlite/sqlite_database_schema.dart`. DAO + repository at `dao/shift_record_dao.dart` + `repositories/sqlite_shift_record_repository.dart`.
- **`week_records`**, **`weekly_plan_snapshots`**, **`baseline_selected_records`**, **`target_cycles`** — all derived/locked snapshots that drop out of `shift_records` plus the active target profile.
- **`open_shift_snapshots`** — live in-progress shift state (separate path; not in scope for this proof gate).
- **`reservation_book_snapshots`** — daypart-level reservation aggregate (the natural place a future reservation aggregator lands its rows).
- **`import_runs`** + **`raw_import_records`** + **`sync_watermarks`** — Phase 7.55-era import infrastructure (per-restaurant, source-typed). Not yet repurposed by Phase 8; design call still open.
- **`connector_configs`** — Phase 7.55-era connector config table; superseded by Phase 8's server-side `connector_connection` (different table, different scope, both still present).

### The proven mobile write path

`ShiftService.closeShift(ClosedShiftInput input)` (lib/services/shift_service.dart:248):

```text
ClosedShiftInput
  → ShiftFactBuilder.fromClosedShiftInput(input, targetSnapshot)
  → ShiftFact
  → _shiftRecordFromFact(fact)
  → SqliteShiftRecordRepository.replaceShiftForSlot(record)
  → AppRuntimeInvalidationBus.notifyRuntimeWriteCompleted()
  → dashboard / variance / history / learn refresh
```

This path is fully built, deterministic, well-tested, and is what the
demo flow uses today. **The natural integration point for the spine
bridge is to feed this same `ClosedShiftInput` shape from
vendor-derived canonical facts.**

### Sharper architecture target (the spine bridge must build)

```text
SERVER:
  vendor → Wave B adapter → canonical-fact dict
    → Postgres-backed *CanonicalSink (NEW; per-trio first)
    → operator-scoped Postgres cover_facts / labor_punches / reservation_facts
    → ON daypart-complete signal:
        canonical-fact aggregator (NEW)
          → ClosedShiftInput
          → ShiftFactBuilder (EXISTING; pure)
          → ShiftFact
          → operator-scoped Postgres shift_records (NEW writer)
    → DemoModeFlipPolicy.evaluateFlip on first batch with records >= 1 (EXISTING; not yet wired)
    → NOTIFY → Pub/Sub → WebSocket bridge (EXISTING Phase 10a)

MOBILE:
  WebSocket signal received
    → server→mobile ShiftRecord pull service (NEW)
    → SqliteShiftRecordRepository.replaceShiftForSlot(record) (EXISTING)
    → AppRuntimeInvalidationBus.notifyRuntimeWriteCompleted() (EXISTING)
    → dashboard / variance / history / learn refresh (EXISTING)
    → metric honesty pill recomputes from new MetricProvenance state (EXISTING)
    → demo_mode_state row reflects flipped state via the same pull (EXISTING table; flip needs server-side wiring)
```

### What this changes about the follow-up sprint

The follow-up sprint is no longer 4-5 sub-lanes; it's 6, and the
parallel topology is now explicit. See PROJECT_TRACKER.md "Active
Lanes" section for the canonical lane definitions. The new contract
binding the architecture is `docs/contracts/integration_spine_architecture_contract.md`.

### What this does NOT change

- The Wave B left-half evidence (279 fixture-based tests + 17 doc
  packs + 17 walkthroughs + lifecycle locked at `documented`) stays
  fully proven.
- The `MetricProvenance` + `MetricCardNotYetAvailable` widget plumbing
  stays in place — it consumes whatever ShiftFact's read model
  produces.
- The metric honesty contract still binds the renderer.
- Phase 8 / 8R / 8.S close as engineering-complete only after
  `8.spine-bridge` lands AND `8.integration-mobile-proof` re-run
  passes.
