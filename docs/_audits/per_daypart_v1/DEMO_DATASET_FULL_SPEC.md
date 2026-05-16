# Demo Dataset — Full End-to-End Specification

**Status:** Specification / research output. NO production code changed by this document.
**Created:** 2026-05-16
**Refresh 2026-05-16 (post symptom-B):** Re-baselined against `master` @ `5c3fc74c` (includes #822 cold-boot current-week-to-today, #824 per-location operational envelope, #826 cold-boot partial-seed fix, #827 per-location current-week open/projected shift for all 4 locations, #828 demo location switch re-scopes the data). Every "State" cell re-verified against code on master — the prior spec's cells were NOT trusted. **Two operator decisions are now LOCKED (§Phase 0). One OPEN, device-proven blocking defect was found and folded in (§G blocker, §F.4): the production cross-tenant wipe permanently wipes the 3 non-active demo locations on every scope switch.**
**Owner:** Operator (Vanessa). For operator approval before any further implementation.
**Authority position:** Below `CLAUDE.md` → Demo Mode (HP #2, HP #4, HP #11), `docs/contracts/demo_mode_contract.md`, `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`, and the predecessor `docs/_audits/per_daypart_v1/full_demo_data_spec.md`. Above any worker slice prompts emitted from it.

> This document **supersedes** the prior revision of itself (which was baselined at `50845999`) and `full_demo_data_spec.md` as the *current-state* reference. Stale parts of the prior revision are corrected inline and called out (most materially: the "Downtown-only single open shift" invariant is **obsolete** — #827 now seeds a current-week open/projected shift for **all 4 locations**). Plan/spec-only: no code is changed by this document.

---

## A. Executive summary

### A.1 Operator intent (restated faithfully, binding)

The demo dataset exists to make the mobile app behave **as if all 3 vendor types (POS + Labor + Reservation) are fully connected and backfilled for a location** — a **complete, nothing-missing** dataset that showcases the full, end-to-end intended functionality of the app through multiple realistic scenarios, **across the operator's full hierarchy of locations**.

- Every location across the hierarchy has a demo switch.
- **Demo switch ON** ⇒ the operator explores the *entire* app's functionality *across their whole hierarchy* with rich, realistic, all-vendors-connected data. Navigating the hierarchy (switching locations) must NOT degrade any location — every location stays fully populated as the operator moves between them.
- **Demo switch OFF / go-live** ⇒ the demo data is simply cleared/flipped and the app then *awaits the real integrations* to populate real data. This is HP #2: a writer-side switch — same tables, same readers, same UI; the demo writer just stops being the writer. Real data lands under a *different real operator/location scope*, so production is unaffected.

Demo data exists purely to demonstrate the full app end-to-end, then get out of the way for real data.

### A.2 Bottom line

The dataset is **substantially built**. The four-location fixture, the rich 12-week + current-week per-location cohorts, the per-period targets, the vendor-connection state fixture, the operational envelope (snapshots / reservations / locked plans / notifications), and the HP #11 scope overrides are all landed on `master`. **Both standing operator decisions are now LOCKED** (4 locations final; flip-flag-leave-rows is already the code's behavior). **The single remaining substantive item is an OPEN, device-proven defect** that directly defeats the "every location stays fully populated as I navigate my hierarchy" intent: the production multi-tenant cross-tenant wipe deletes the 3 non-active demo locations on **every** scope switch (§F.4, §G blocker). A demo-bootstrap-only fix is **in flight** on branch `claude/fix-qa-demo-scope-switch-cross-tenant-wipe` (currently 0 commits ahead of master — not yet landed). Everything else is verification-only. No rebuild, no schema change, no core-formula / integration / proxy / auth / RLS change.

### A.3 How it satisfies HP #2 (clear-on-go-live, writer-side switch)

The dataset writes only standard production tables, scoped by `restaurant_id`; there is no `demo_*` table and no `kDemoMode` reader branch on any operational path (only the four blessed carve-outs in `docs/contracts/demo_mode_contract.md`). The demo→live handoff is realized three ways, all already wired:

1. **Per-(operator, location, category) auto-flip** — `DemoModeFlipPolicy.evaluateFlip` (`lib/services/integration/demo_mode_state.dart:82`) calls `gateway.flipToLive(...)` (`:107`) to set `demo_mode_state.is_demo = false` once a vendor connection reaches `connected` AND first backfill commits ≥1 record. Disconnect does NOT auto-revert. Demo build gateway = read-fixture `DemoVendorIntegrationDemoModeStateGateway`; production = Postgres-backed. Same policy, same readers.
2. **Operator master Demo→Live switch** (carve-out #4, `lib/screens/settings/settings_demo_live_switch.dart`) — one-way; refuses Live→Demo with the operator-facing line "Live data has arrived. Demo mode cannot be restored." (`:140`, `:156`); reads `snapshot.hasDemoCategories` (`:47`, `:139`).
3. **Local demo data clear** — `SqliteDatabase.reseedDemo()` (`sqlite_database.dart:628`) / `reseedMockReplayForBusinessDate()` (`:644`) `DELETE`s the demo-scope tables and re-seeds. Demo-only "Data reset" / "Demo date" affordance (carve-out #3); production data clears go through the proxy + audit trail, never this button.

**The key HP #2 property:** demo rows are ordinary `restaurant_id`-scoped rows in production tables. When real integrations go live and backfill, the `is_demo` flag flips and the operator's master switch (or natural arrival of live rows for the real scope) takes over. No schema migration, no reader fork, no `demo_*` table to tear down. **Decision D-2 (§Phase 0) LOCKS this:** the flag flips, the demo rows are LEFT (no active purge) — production is unaffected because real data lands under a different real operator/location scope.

### A.4 How it satisfies HP #4 (per-(operator, location) isolation)

Every seeded row carries a concrete `restaurant_id` (one of the four `DemoScope` ids) and, for `demo_mode_state`, the demo operator id. The vendor fixture validates at seed time that every record carries only its own location + the demo operator (`DemoVendorIntegrationDemoModeSource.materializeAndValidate`). Per-location operational data is scaled and written under its own `restaurant_id` (`_seedAdditionalLocationsFromReplay`, `sqlite_database_seed.dart:1524`). RLS-ready schema unaffected (no schema change anywhere). **Caveat introduced by the symptom-B finding:** the *production* cross-tenant wipe (designed precisely to enforce HP #4 on a shared device when the *operator* flips) is, in demo, firing across the *one demo operator's own four locations* and wiping them — see §F.4. This is an HP #4 *control* misfiring against demo's single-tenant-many-locations shape, not an HP #4 isolation breach.

---

## B. Full app surface → data-requirements matrix

Legend: **Reads** = tables/fields the surface consumes. **"Complete" means** = what makes it fully populated AND true-to-logic (not merely non-empty). **State** (re-verified against `master` @ `5c3fc74c`): ✅ seeded & true-to-logic / 🟡 seeded, verify / ❌ gap (see §G).

### B.1 Mobile — Shift dashboard

| Surface | Reads | "Complete" means | State |
|---|---|---|---|
| Shift whole-day card (Outputs / Inputs / FOH Productivity) | `open_shift_snapshots` (current open + projected), `shift_records` (closed same-day), `active_target_profiles`, `target_cycles` | A `status='open'` + `status='projected'` snapshot for the scenario day+daypart **for every location** (#827: per-loc current-week, `_seedHistoricalOpenShiftSnapshotsFromReplay:2350`, non-Downtown via `_buildCurrentWeekOpenShiftSnapshots:2418`; Downtown owned by `_seedOpenShiftSnapshotsFromReplay`); whole-day = cover-weighted rollup of period buckets (Layer 9). | ✅ — **CORRECTION:** the prior spec's "Downtown only — pinned single-open invariant" is **obsolete**; #827 seeds current-week open/projected for all 4 locations. |
| Shift per-daypart cards (lunch/dinner/late_night) | per-period `shift_records`, `target_cycle_dayparts`, `weekly_plan_snapshot_day_dayparts` | Each card reads ITS period's target + locked plan row; lunch≠dinner≠late_night; ≥1 period a different primary driver. | ✅ |
| Primary Driver chip (whole-day + per-period) | `shift_records.primary_lever` via `LaborModel.determineLever` | Mix spans ≥6 lever families across the closed cohort; never a hardcoded constant; recurring per-(day,period) leak engineered. | ✅ |
| App data status badge | `open_shift_snapshots` presence | Carve-out #2 renders `DEMO`; freshness math identical to prod. | ✅ |

> **Symptom-B caveat for the whole row:** the ✅ states above hold **at cold boot only**. After one location switch, the production cross-tenant wipe deletes `open_shift_snapshots` + `shift_records` for the 3 non-active locations (§F.4). Device evidence: cold boot `open_shift_snapshots` = 684 (4 locs, open=1/projected=2 each); after one switch = 171 (only active kept); after switch + pull-refresh = 0. So "every location across the hierarchy stays fully populated" is **NOT currently true at runtime** — gated on the in-flight fix (§G blocker).

### B.2 Mobile — Variance tab

| Surface | Reads | "Complete" means | State |
|---|---|---|---|
| Variance "This Week" / WTD vs Plan | current-week `shift_records`, locked `weekly_plan_snapshots` + `weekly_plan_snapshot_day_dayparts` | Period-tagged actuals vs period-accurate targets rolled to the day; deltas non-zero, vary by day. | ✅ (cold boot; same symptom-B caveat for non-active locations) |
| Variance History (per-week list) | `week_records` (≥12 rows/loc) with `dollarGap`, `monthDollarImpact`, `sixtyDayDollarImpact`, `closedAt` | Each week graded vs the cycle in force; non-flat deltas; per-period grades differ. | ✅ (note: `week_records` is wiped by `reseedMockReplayForBusinessDate` but NOT by the cross-tenant wipe — see §F.4 table; History survives a switch, the open-shift card does not) |
| Variance Full Week Projection | non-closed daypart rows, per-period theoretical % | Projected rows differ per period; wages whole-day. | ✅ |
| Variance Learn tab | `week_records` history, `learn_*` models | Detectable recurring period leak, one benchmark pattern, one cross-axis pair. | ✅ |

### B.3 Mobile — Plan tab

| Surface | Reads | "Complete" means | State |
|---|---|---|---|
| Weekly Operating Plan — day rows | locked `weekly_plan_snapshots` (`day_rows_json`) | Day · Covers · Sales · FOH Hrs · BOH Hrs; locked, not regenerated on render. | ✅ (cold boot; **symptom-B: `weekly_plan_snapshots` IS in the cross-tenant wipe set → non-active locations lose their locked plan after a switch**) |
| Plan — expanded per-daypart sub-rows | `weekly_plan_snapshot_day_dayparts` | Sub-rows render persisted locked values; sum to the day row; periods differ. | ✅ (cold boot; same symptom-B caveat) |

### B.4 Mobile — Benchmark tab

| Surface | Reads | "Complete" means | State |
|---|---|---|---|
| CPLH Range & Target widget | active `target_cycles` (pooled scalars) | Pooled CPLH = cover-weighted Σ(period CPLH); pool-consistency by construction. | ✅ (cold boot; **`target_cycles` IS in the cross-tenant wipe set → non-active locations lose their cycle after a switch → Benchmark falls back to config default**) |
| Daypart Breakdown table | `target_cycle_dayparts` + Whole Day rollup | Period rows differ; Whole Day row = widget pooled value 1:1. | ✅ (cold boot; same symptom-B caveat) |
| Operating Wage Mix + Theoretical % strip | `target_cycles.foh_wage/boh_wage` from seeded `wage_role_rows` waterfall | Wages whole-day; FOH 16.50 / BOH 21.35 from the `_weightedAvgFromRows` waterfall. | ✅ (cold boot; **`wage_role_rows` IS in the cross-tenant wipe set**) |
| Baseline Manager — candidate cohort + star-shift selector | ≥60 days closed `shift_records`; `baseline_selected_records` empty initially | Cohort rich enough that picking stars in one period visibly moves that period's target + pooled rollup. | 🟡 verify the override cascade visibly moves the pooled value with the current deterministic cohort spread (and re-verify after the symptom-B fix lands, since cohort = `shift_records` which is wiped) |
| Baseline Manager preview (draft → confirm) | per-period preview math | Preview per-period numbers consistent with post-write cycle shape. | 🟡 verify |

### B.5 Mobile — Settings / Setup / Integrations / Data / Account

| Surface | Reads | "Complete" means | State |
|---|---|---|---|
| Settings → Setup (Covers / Timing / Wage authority) | `restaurant_timing_configs` (3 periods + `service_period_definitions_json`), `data_accuracy_service_period_settings*`, `wage_role_rows` | Timing seeded with lunch/dinner/late_night incl. `applicable_days`, `rolls_past_midnight`; covers-source keyed per period; wage rows drive blended wage. | ✅ timing/wage seeded; 🟡 verify keyed covers-source per period (N3). **symptom-B: `restaurant_timing_configs` + `wage_role_rows` are in the cross-tenant wipe set.** |
| Settings → Integrations (mobile fold) | `DemoModeStateNotifier` ← `DemoVendorIntegrationModeStateSyncProxyClient` | Per-(O,L,category) state renders; mixed connected/error/disconnected; master Demo→Live reads `hasDemoCategories`. | ✅ (read-fixture, not in the SQLite wipe set — Integrations fold survives a switch) |
| Settings → Data (Data reset / Demo date — carve-out #3) | `mock_replay_state` | Demo-date advance regenerates coherent data for any date via `generateForDate`. | ✅ |
| Settings → Account / MFA / Active Sessions | authenticated demo operator session | Render identically in demo/prod; demo operator minted F&F admin. | ✅ |
| Settings → Data freshness / Wage authority / Team / Permissions / FF Support | same reads as prod; HP #11 scope chip / inherited-from / effective value | Scope chip + inherited source + effective value render off seeded scope-level overrides. | 🟡 verify HP #11 pills render the seeded overrides on EACH mobile surface (N4; Gaps 29/30/32 are tracked-separately follow-ups) |

### B.6 Mobile — scope drawer & Notifications

| Surface | Reads | "Complete" means | State |
|---|---|---|---|
| Location / scope drawer | `restaurant_locations` (4 rows) → `RestaurantScopeNotifier.availableScopes` | >1 scope; switching changes the dashboard; **#828 wired the scope flip to `AppRefreshCoordinator.refreshAll`** so data surfaces re-scope on switch (was pinned to Downtown / no refresh before #828, `lib/forge_flow_app.dart`). | ✅ drawer + re-scope wired; ❌ **but the very switch that #828 makes refresh is the switch that triggers the cross-tenant wipe → the refreshed non-active locations are now empty (§F.4). #828 fixed "stale Downtown data on switch"; it did not fix "other locations wiped on switch".** |
| Notifications | `app_notifications` (sample inbox + variance-breach), scoped by `restaurant_id` | ≥1 variance-breach alert + small sample inbox per location; event keys → correct icon/accent/tone. | ✅ (`app_notifications` is NOT in the cross-tenant wipe set — Notifications survive a switch) |

### B.7 Operator-Web / Admin (only where it binds the mobile demo story)

Web consoles use in-memory demo gateways (allowed per contract). They matter here only because the **vendor-connection story and the org tree must agree across consoles**. Both derive from a single source of truth: `DemoVendorIntegrationStateFixture` (vendor state) and `demo_team_fixtures.dart` (org tree), with drift-failing tests asserting the mobile `DemoScope` ids equal the fixture's `_mobileLocationIds` and the operator-web `kDemoTeamLocationsFixture`. No additional web work is required for the mobile demo to be complete.

---

## C. Hierarchy + location scheme (derived from the repo — no live DB)

### C.1 Why derived

Migrations are NOT applied in staging/preview, so the canonical hierarchy is derived from repo design, not a live DB:

- **Mobile has NO SQLite `org_units` table.** `restaurant_locations` is a flat table (`restaurant_id`, `display_name`, `business_timezone`, timestamps) with no parent/hierarchy column. The production hierarchy table is Postgres-only (`db/migrations/202604280002_phase_9_0sigma_c_org_units.sql`). On mobile, multi-location scope is **multiple `restaurant_locations` rows + the `BusinessScope` list `RestaurantScopeNotifier` derives from them**.
- **The org tree lives in the operator-web fixture** `lib/operator_web/services/demo_team_fixtures.dart` (corp `demo-org-root` → East/West regions; Metro District under East; 4 `demo-loc-*` locations).
- **The two consoles are bound by a drift-failing test** asserting `DemoScope.{downtown,northLoop,riverside,harbour}RestaurantId` equal `DemoVendorIntegrationStateFixture._mobileLocationIds` and the operator-web `kDemoTeamLocationsFixture`.

### C.2 The structure (as implemented, `sqlite_database.dart:104-130` + `demo_team_fixtures.dart`)

```
Barrio Hospitality Group         corp     operator-web `demo-org-root` (id/name kept "Demo Bistro" — deviation 2)
├── East Region                  region   demo-org-east
│   ├── Downtown                  location demo-loc-downtown  → mobile demo_restaurant_001        ("Barrio Legado")
│   └── Metro District            district demo-org-metro (parent demo-org-east)
│       └── North Loop            location demo-loc-north-loop → mobile demo_restaurant_north_loop ("Barrio Legado — North Loop")
└── West Region                   region   demo-org-west
    ├── Riverside                 location demo-loc-riverside → mobile demo_restaurant_riverside  ("Barrio Legado — Riverside")
    └── Harbour                   location demo-loc-harbour   → mobile demo_restaurant_harbour    ("Barrio Legado — Harbour")
```

Verified against `sqlite_database.dart:104-130`: Downtown `region='East Region'`; North Loop `region='East Region', district='Metro District'`; Riverside `region='West Region'`; Harbour `region='West Region'`.

Deliberate backward-compat deviations (resolved by authority order: backward-compat > spec labels):
1. **Downtown** display name stays `'Barrio Legado'` (not `'… — Downtown'`) and id stays `demo_restaurant_001` — `persistence_scope_alignment_test.dart` + `getOrCreateActiveRestaurant` assert id → exactly `'Barrio Legado'`. (`DemoScope.restaurantId='demo_restaurant_001'`, `displayName='Barrio Legado'`, `sqlite_database.dart:80,88`.)
2. **Operator-web corp root** keeps id `demo-org-root` / name "Demo Bistro" — ~15 11W tests assert the current ids/names/paths. The *structure* (corp → 2 regions → 1 district → 4 locations) is met exactly.

### C.3 How it binds scope / notifier / demo-switch

- `_seedDemoRestaurant` (`sqlite_database_seed.dart:854`) loops `DemoScope.locations` and inserts each as a `restaurant_locations` row (idempotent — backfills missing locations on an upgraded demo DB).
- `RestaurantScopeNotifier` populates `availableScopes` from every `restaurant_locations` row via `_seedAvailableScopesFromBootIfEmpty` → unfiltered `SELECT *` (`restaurant_scope_notifier.dart:205,229`). Downtown is first → it is the default resolved active scope (`scopes.first` / `getOrCreateActiveRestaurant`, `:156,182`).
- The demo-switch / banner read `DemoModeStateNotifier.snapshot`, fed by the mobile sync proxy client, which delegates to `DemoVendorIntegrationStateFixture` keyed on the LOGICAL location → the same per-category state regardless of which console asks.
- **#828 (`lib/forge_flow_app.dart`)** binds a listener to `RestaurantScopeNotifier`; on a real `activeScope` flip it bridges to `AppRefreshCoordinator.refreshAll` (post-frame, `mounted`-guarded, deduped by `stableKey`) so the data notifiers re-scope on a location switch. Before #828, the header updated but the data surfaces stayed pinned to the boot scope until a manual pull-to-refresh.
- **Secondary observation (lower severity):** pull-to-refresh re-resolves the active scope back to Downtown. `RestaurantScopeNotifier` re-resolution prefers a persisted active scope, else `activeMatch`, else `scopes.first` (= Downtown, the first `restaurant_locations` row) (`restaurant_scope_notifier.dart:156`). So a pull-to-refresh while on a non-Downtown location can snap the active scope back to Downtown. Flagged as an observation, not the blocking defect; it compounds the symptom-B evidence (switch → wipe non-active; pull-refresh → re-resolve to Downtown and the just-wiped non-active locations show empty).

---

## D. Vendor-connection model

### D.1 The three categories and connection states

- **Categories:** `IntegrationCategory { pos, labor, reservation }` (POS = sales facts; Labor = punch/wage facts; Reservation = forward unseated-cover book).
- **Connection status:** `ConnectionStatus { connected, disconnected, error }` (`demo_vendor_integration_state_fixture.dart:74`).
- **Demo flag:** `demo_mode_state.is_demo` per (operator, location, category). Default `true`. Flips to `false` on `connected` + first backfill commit ≥1 record (`DemoModeFlipPolicy`, `demo_mode_state.dart:82,107`). Never auto-reverts.

Fixture semantics (`demo_vendor_integration_state_fixture.dart:69-95`):
- `connected` + `is_demo=true` → "connected but first backfill not yet committed" → master Demo→Live must NOT flip yet.
- `connected` + `is_demo=false` → "already flipped to live" → first-backfill succeeded, deterministic flip metadata.
- `disconnected` → no vendor row renders (clean demo — honest, not an error).
- `error` → needs-reauth; remediation message rendered.

### D.2 The 4-location vendor assignment (LOCKED — Decision D-1)

Verified against `demo_vendor_integration_state_fixture.dart:149-229`:

| Location | POS | Labor | Reservation | `is_demo` | Embodies |
|---|---|---|---|---|---|
| **Downtown** (`demo_restaurant_001`) | connected | connected | **error/needs-reauth** | all `true` | All-3 with one needs-reauth → master switch visible, banner renders, reservation honest-degrade on one category, rich 60+-day data, live open shift |
| **North Loop** (`demo_restaurant_north_loop`) | connected | disconnected | disconnected | all `true` | **POS-only** → labor/reservation honest-degrade; also carries the Region timing override + District data-accuracy override |
| **Riverside** (`demo_restaurant_riverside`) | connected | connected | connected | all `false` | **All-3 flipped-to-live** (vendor-just-backfilled) → switch shows already-live, Live→Demo refusal demonstrable; carries Location wage override |
| **Harbour** (`demo_restaurant_harbour`) | disconnected | disconnected | disconnected | all `true` | **None connected** (awaiting go-live) → clean demo, all honest-empty; inherits the business default (HP #11 "inherited" pill) |

A stray scope falls back to a safe default (all `is_demo=true`, all disconnected; `:242`).

### D.3 Per-state honest-degrade behavior (REQUIRED per Metric Honesty doctrine — not a bug)

| State | Shift card | Variance/History | Plan | Benchmark | Integrations fold / banner |
|---|---|---|---|---|---|
| All 3 connected (live/demo) | Full whole-day + per-period, primary driver, OPZ | Full WTD + history + Learn | Full locked plan + sub-rows | Full daypart table + wage strip | Connected rows; banner if any `is_demo=true` |
| POS only (North Loop) | POS-derived covers/sales populate Shift/Variance/Benchmark; **labor-derived metrics (CPLH/SPLH/wage levers) degrade honestly** (modeled, marked — not fabricated vendor punches) | History present; wage-axis levers absent | Plan covers/sales present; labor hours modeled | Targets present; wage strip from config default | POS connected; Labor/Reservation disconnected (no row) |
| All-3-live (Riverside) | Full; no banner; "CURRENT" semantics | Full | Full | Full | Connected; no banner |
| None connected (Harbour) | Honest "awaiting first connection" empty states everywhere — NO phantom zeros | Empty (honest) | Empty | Config-default targets | All disconnected; banner shows demo |
| Mixed w/ Reservation error (Downtown) | Full except reservation context honestly degrades for the needs-reauth category; remediation message visible | Full | Full | Full | POS/Labor connected; Reservation error + remediation |
| Sibling-location mix | Each location renders its own state independently (HP #4) | per-location | per-location | per-location | per-location |

The four locations cover {all-3-mixed, POS-only, all-3-live, none}. They do NOT distinctly embody "POS+Labor-no-Reservation", "Labor-missing", or "Reservation-only". **Decision D-1 LOCKS this as acceptable** — the 4 are the final representative sample; the remaining partial combos are better demonstrated via the operator-web vendor-connection fixture (per-category connect/disconnect transitions) than by inflating the mobile location count. **Phase 4 / location expansion is CANCELLED.**

---

## E. Scenario matrix (DATA axis × VENDOR-CONNECTION axis → 4 locations)

### E.1 DATA axis (what the numbers say)

| Data scenario | Where embodied | True-to-logic signal |
|---|---|---|
| Healthy week (on-model) | every location's on-trend weeks (`mock_integration_replay_seed.dart` `_weekVolume` trend) | dollar gap small, primary driver near-neutral |
| Labor-over-plan week | slots owning `foh_hours_over`/`boh_hours_over` (Sat dinner, Mon dinner) | scheduled hours > model by >10%; hours-flex lever fires |
| Understaffed daypart | `cplh_up`/`splh_up` owning slots (Wed dinner, Tue dinner) | productivity above target → understaffed signal |
| Soft sales | mid-history soft week + `ppa_down`/`covers_down` slots | week-over-week negative delta; Learn benchmark/leak |
| Strong sales | seasonal upward trend + `ppa_up`/`covers_up` slots (Tue lunch, Thu dinner) | positive delta; recurring benchmark pattern |
| Vendor-just-backfilled | Riverside (all 3 `is_demo=false`) | banner cleared; "CURRENT" not "DEMO" semantics |
| Mid-service open shift | **every location's** current open daypart (#827 per-loc current-week open/projected) | in-progress covers vs committed scheduled hours |

### E.2 VENDOR-CONNECTION axis × location (the §D.2 table) maps so a hierarchy walk (Downtown → North Loop → Riverside → Harbour) shows the full range: all-3-mixed → POS-only → all-3-live → none-connected. **This walk is exactly the operation that today triggers the symptom-B wipe; §H Phase 1 acceptance verifies the walk is non-destructive post-fix.**

---

## F. Demo-switch lifecycle

### F.1 How the full dataset is seeded per location

Single orchestration seam: `_seedDemoDataFromReplay` (`sqlite_database_seed.dart:1676`), invoked from BOTH cold-boot (`_onCreate`) and reseed/advance (`reseedMockReplayForBusinessDate`):

1. Wipe Downtown-scope `shift_records` (Decision 4 — pre-production reseed; no closed-truth concern for demo scope).
2. Insert Downtown current-week + historical shifts + `week_records`, `import_runs`, `raw_import_records`.
3. `_seedAdditionalLocationsFromReplay` (`:1524`) — for North Loop/Riverside/Harbour: scale the base replay by per-location profiles, build/preserve each location's active cycle via the production `TargetCycleDao` (parent + per-period child rows in one txn), project `active_target_profiles`, stamp whole-day locked targets onto scaled rows (preserving per-period daypart stamps).
4. `_seedOperationalEnvelopeFromReplay` (`:2303`) — per-location historical + **current-week (#827)** `open_shift_snapshots` (`_seedHistoricalOpenShiftSnapshotsFromReplay:2350`, non-Downtown current week via `_buildCurrentWeekOpenShiftSnapshots:2418`), forward `reservation_book_snapshots` (`_seedForwardReservationEnvelopeFromReplay:2449`), locked `weekly_plan_snapshots` + `weekly_plan_snapshot_day_dayparts` (`_seedHistoricalWeeklyPlanSnapshotsFromReplay:2525`), `app_notifications` (`_seedDemoSampleNotifications:2790`), one variance-breach notification (`_seedDemoVarianceBreachNotification:2152`).
5. `_seedDemoVendorIntegrationModeStateSource` (`:1799`) — arms the mobile `demo_mode_state` source (gated on the writer-side switch; no-op in production).
6. `_seedDemoWageRoleRows` (`:1175`), `_seedDemoScopeOverrideTimingConfig` (`:1966`), `_seedDemoScopeOverrideWageRows` (`:2004`), `_seedDemoScopeOverrideDataAccuracy` (`:2072`) — HP #11 overrides + the wage waterfall.

All seeding is deterministic (no RNG, no `DateTime.now()` in seeded values; timestamps derived from business dates) — two reseeds are byte-identical.

### F.2 How/when it is cleared on demo-off / first real backfill

| Mechanism | Deletes | Keeps | Trigger |
|---|---|---|---|
| `reseedMockReplayForBusinessDate(iso)` (`sqlite_database.dart:644`) | `shift_records`, `week_records`, `baseline_selected_records`, `import_runs`, `raw_import_records`, `sync_watermarks`, `target_profile_versions`, `open_shift_snapshots`, `reservation_book_snapshots` (`:650-658`) | `target_cycles`, `weekly_plan_snapshots`, `active_target_profiles`, `benchmark_selection_summaries` (locked week-in-force survives a same-week advance — Promise 2) | "Demo date" advance (carve-out #3) |
| `reseedDemo()` (`:628`) | the above + `weekly_plan_snapshots`, `benchmark_selection_summaries`, `target_cycles`, `app_notifications` (`:630-633`) then re-seeds | — | "Data reset" (carve-out #3) |
| Demo→Live flip (`DemoModeFlipPolicy` / master switch carve-out #4) | **nothing** — flips `is_demo=false` only | all SQLite demo rows | first real backfill / operator master switch |

### F.3 Tie to `demo_mode_state` + `DemoModeFlipPolicy` — Decision D-2 LOCKED

- Production: `demo_mode_state` is a Postgres table; `DemoModeFlipPolicy` (Postgres-backed gateway) flips it on first backfill commit.
- Demo build: gateway is `DemoVendorIntegrationDemoModeStateGateway` (read-fixture, no persistence); `flipToLive` honors one-way semantics.
- **Decision D-2 (LOCKED, §Phase 0):** on demo→live the `is_demo` flag flips and the demo `restaurant_id`-scoped rows are **LEFT** (no active purge). This is correct production behavior (live rows land under a *different real* operator/location scope; no collision) and is **already how the code works — no code change**. The mobile demo fixture has no live transport, so demo rows persist until an explicit `reseedDemo()`/master-switch reseed. The prior spec's "open question" on this is **CLOSED — DECIDED.**

### F.4 The cross-tenant-wipe dependency (OPEN, device-proven — folded in from symptom-B)

**Defect.** Switching the active location triggers `MobileOperationalSyncHost._handleBusinessScopeChanged` (`lib/services/sync/mobile_operational_sync_runtime.dart:434`) → `_wipeOtherTenantsThenSync` (`:422`) → `widget.crossTenantWipe(session.locationId)` (`:425`) → `defaultCrossTenantWipe(keepRestaurantId)` (`:190`) → per-repo `wipeForOtherScopes` across **8 tables**, each issuing `DELETE FROM <table> WHERE restaurant_id != ?` (verified: `target_cycle_dao.dart:86-92`):

| # | Repository (`:line` in `mobile_operational_sync_runtime.dart`) | Table |
|---|---|---|
| 1 | `SqliteShiftRecordRepository` (`:191`) | `shift_records` |
| 2 | `SqliteOpenShiftSnapshotRepository` (`:194`) | `open_shift_snapshots` |
| 3 | `SqliteRestaurantTimingConfigRepository` (`:197`) | `restaurant_timing_configs` |
| 4 | `SqliteBaselineSelectionRepository` (`:200`) | `baseline_selected_records` |
| 5 | `SqliteTargetCycleRepository` (`:203`) | `target_cycles` |
| 6 | `SqliteTargetProfileRepository` (`:206`) | `target_profiles` |
| 7 | `SqliteWeeklyPlanSnapshotRepository` (`:209`) | `weekly_plan_snapshots` |
| 8 | `SqliteWageRoleRowRepository` (`:212`) | `wage_role_rows` |

**Why it exists and why it is correct for production.** This is a deliberate multi-tenant security control (the `// BUG 1 (HIGH)` comment, `:409-415`): on a *shared device* where the *operator* (or location) flips, the prior tenant's mirrored rows must be purged before the next sync sweep so DAO reads that don't filter by `(operator_id, location_id)` cannot leak another tenant's data. In production the real proxy sync immediately re-materializes the *new* tenant's rows, so the wipe is invisible and the isolation guarantee is real. **This production behavior is correct and must NOT change.**

**Why it defeats the demo intent.** In demo, the 4 `DemoScope` locations are **one operator's tenancy** (one demo operator, four locations) and there is **no operational proxy sync** to re-materialize the just-wiped locations. So every location switch permanently DELETEs the 3 non-active locations across all 8 tables, and a subsequent pull-to-refresh (which also re-resolves the scope back to Downtown — §C.3 secondary observation) finds them empty. The operator's "every location stays fully populated as I navigate my hierarchy" intent is **defeated at runtime today**.

**Device evidence (symptom-B):** cold boot `open_shift_snapshots` = 684 (all 4 locations, open=1/projected=2 each); after **one** location switch = 171 (only the active location's rows kept); after switch + pull-to-refresh = **0**. Confirmed the 8-table `restaurant_id != keep` delete pattern matches the count collapse.

**In-flight fix.** Branch `claude/fix-qa-demo-scope-switch-cross-tenant-wipe` (exists locally; **0 commits ahead of master @ `5c3fc74c` — NOT yet landed**). Intended approach: inject a **DemoScope-preserving `CrossTenantWipe`** ONLY on the demo bootstrap path (via the existing override-able `MobileOperationalSyncHost.crossTenantWipe` hook, `mobile_operational_sync_runtime.dart:269,279` — a constructor seam already designed for test stubbing). Production `defaultCrossTenantWipe` stays **byte-unchanged**; the demo variant keeps all four `DemoScope` `restaurant_id`s instead of only the active one. **The spec does NOT propose changing the production wipe.** This is the single gating dependency for the "all locations across the hierarchy stay populated" requirement (§G blocker, §H Phase 1).

**Tables NOT in the wipe set** (survive a switch even today): `week_records` (Variance History), `app_notifications` (Notifications), `active_target_profiles`, `reservation_book_snapshots`, `weekly_plan_snapshot_day_dayparts`, `data_accuracy_*`, `demo_mode_state` (read-fixture). This is why History/Notifications look intact post-switch while the Shift open card / Plan / Benchmark / Setup-timing/wage collapse.

---

## G. Gap analysis vs current master (re-baselined @ `5c3fc74c`)

| # | Surface | Prior gap | Current state (evidence on `5c3fc74c`) | Remaining? |
|---|---|---|---|---|
| G1 | Hierarchy / scope drawer | One location, no tree | 4 locations + operator-web org tree; drift test binds consoles (`sqlite_database.dart:104-130`, `demo_team_fixtures.dart`) | ✅ Closed |
| G2 | Driver chip / History / Learn | "all covers" | 8 lever families; covers_down ≈7%; recurring leak+benchmark | ✅ Closed |
| G3 | Vendor-connection coverage | No `demo_mode_state` rows | Per-(O,L,cat) fixture for 4 locations (`demo_vendor_integration_state_fixture.dart:149-229`) | ✅ **Closed by DECISION D-1** — 4 locations is the final representative sample; remaining combos are operator-web's job. Phase 4 CANCELLED. |
| G4 | Variance flatness | 8-week low-amplitude | 12 weeks + trend + soft week + per-period volatility | ✅ Closed |
| G5 | Learn narration | No recurring pattern | Recurring period leak + benchmark + cross-axis pair | ✅ Closed |
| G6 | Integrations fold / banner | Nothing to render | Fold + banner render per-(O,L,cat) | ✅ Closed |
| G7 | Wage authority / wage levers | MeridianConfig fallback | `_seedDemoWageRoleRows` waterfall (`sqlite_database_seed.dart:1175`) | ✅ Closed |
| G8 | Per-location operational data | Empty shells | #824 + #827: scaled cohorts, cycles, snapshots (incl. **per-loc current-week open/projected**), plans, reservations for all 4 | ✅ Closed (data); see **BLOCKER** for runtime survival |
| G9 | Notifications | No alert rows | `_seedDemoSampleNotifications:2790` + `_seedDemoVarianceBreachNotification:2152` | ✅ Closed |
| G10 | HP #11 scope overrides | No override rows | Region (North Loop timing `:1966`), District (Metro data-accuracy `:2072`), Location (Riverside wage `:2004`), Harbour inherits | 🟡 Data seeded; **VERIFY pills render** (N4) — Gaps 29/30/32 separately-tracked UI follow-ups, not data gaps |
| **BLOCKER** | **Hierarchy walk keeps all locations populated** | n/a (new) | **Production cross-tenant wipe DELETEs 3 non-active demo locations on every switch (8 tables, `mobile_operational_sync_runtime.dart:190-215,434`); device-proven 684→171→0. Fix in flight (`claude/fix-qa-demo-scope-switch-cross-tenant-wipe`, 0 commits ahead — NOT landed).** | ❌ **OPEN — single gating item for the operator's core "every location stays full as I navigate" intent. Spec does NOT touch the production wipe.** |

Verification-only items (no rebuild, seed/walkthrough only):

| # | Item | Severity |
|---|---|---|
| N1 | Baseline Manager override cascade visibly moves the pooled value with the current deterministic cohort spread (re-verify after the symptom-B fix — cohort = `shift_records`, in the wipe set) | 🟡 Verify-only |
| N2 | Baseline Manager preview per-period math consistent post-Slice-2 | 🟡 Verify-only |
| N3 | Demo seed writes keyed `data_accuracy_service_period_settings` per configured period (legacy `covers_source_*` columns killed per Gap 36) | 🟡 Verify-only |
| N4 | HP #11 mobile pills (scope chip / inherited-from / effective value) on Settings → Wage authority / Timing / Data freshness actually render the seeded overrides | 🟡 Known follow-up (UI), not a data gap |
| N5 | Per-connection-state honest-degrade renders correctly per location (Harbour honest-empty not phantom-zero; North Loop labor-derived metrics degrade honestly; Riverside no banner; Downtown reservation remediation visible) | 🟡 **Highest-value verification — the core "honestly degrades per connection state" promise** |

**Net:** functionally built. The ONLY substantive open item is the cross-tenant-wipe BLOCKER (fix in flight, not landed). Everything else is verification (N1–N5) plus HP #11 pill rendering (N4). Both standing operator decisions are LOCKED. No rebuild, no schema, no core-formula/integration/proxy/auth/RLS change.

---

## H. Phased plan (PLAN ONLY — no code)

Every phase respects HP #2 (no `demo_*` tables, no `kDemoMode` reader fork, same tables/readers/UI; the four blessed carve-outs only), HP #4 (per-`restaurant_id`/operator scoping, RLS-ready schema untouched), Metric Honesty (honest-degrade is REQUIRED, not a bug to "fix" by fabricating a zero), and introduces **NO core-formula / integration / proxy / auth / RLS change**. Anything that would require such a change = explicit operator-decision callout (none anticipated; the in-flight fix is a demo-bootstrap-only injection, production byte-unchanged).

### Phase 0 — Operator decisions (DONE — both LOCKED 2026-05-16)

- **D-1 (G3 / §D.2): Vendor-combo coverage → LOCKED: "Keep the 4 locations as the representative sample."** {Downtown all-3-mixed, North Loop POS-only, Riverside all-3-live, Harbour none-connected}. Missing partial combos (POS+Labor-no-Reservation / Labor-missing / Reservation-only) are NOT added to mobile. **⇒ Phase 4 / location expansion is CANCELLED.**
- **D-2 (§F.3): Demo→Live semantics → LOCKED: "Flip `is_demo`, LEAVE the demo rows (no active purge)."** Already how the code works — **no code change.** Production unaffected (real data lands under a different real operator/location scope).

### Phase 1 — Land + verify the in-flight cross-tenant-wipe fix (GATING)

**Scope.** Land the in-flight `claude/fix-qa-demo-scope-switch-cross-tenant-wipe` fix: inject a **DemoScope-preserving `CrossTenantWipe`** ONLY on the demo bootstrap path via the existing `MobileOperationalSyncHost.crossTenantWipe` constructor seam (`mobile_operational_sync_runtime.dart:269,279`). The demo variant keeps **all four** `DemoScope` `restaurant_id`s (deletes only rows for `restaurant_id` not in `DemoScope.locations`); production `defaultCrossTenantWipe` (`:190-215`) stays **byte-unchanged**. **Do NOT modify the production wipe or any of the 8 `wipeForOtherScopes` repo methods.** This is the single gating item for the operator's "every location stays fully populated as I navigate my hierarchy" intent.

**Intended post-fix end-state.** Navigating the full hierarchy (any order, any number of switches, with pull-to-refresh on each) preserves **every** location's full dataset: `open_shift_snapshots`, `shift_records`, `target_cycles`, `target_profiles`, `weekly_plan_snapshots`, `restaurant_timing_configs`, `baseline_selected_records`, `wage_role_rows` for all 4 locations remain intact. (Secondary observation §C.3: pull-to-refresh re-resolving to Downtown is a separate, lower-severity scope-resolution behavior — note it during the walk; it is NOT in this phase's fix scope and does NOT require a production change.)

**On-device "hierarchy walk" acceptance script (must pass post-fix):**
1. Cold boot the demo build. Record per-table row counts grouped by `restaurant_id` (expect all 4 `DemoScope` ids present; `open_shift_snapshots` ≈ 684 total, each location open=1/projected=2 for the current week).
2. Switch Downtown → North Loop. Assert: Downtown's rows still present for all 8 tables (Downtown `open_shift_snapshots` open/projected current-week rows intact).
3. Switch North Loop → Riverside → Harbour → back to Downtown. After each switch, assert: the **other three** locations' rows are all still present across the 8 tables (no `restaurant_id != keep` collapse).
4. On each location, pull-to-refresh. Assert: every location's dataset still intact afterward; the Shift open card, Plan locked rows, Benchmark daypart table, and Setup timing/wage render fully (not honest-empty / not config-default-fallback) for each location whose vendor state warrants full data.
5. Assert the count never collapses to the active-only number (the 684→171→0 device signature must NOT reproduce).
6. Re-confirm production `defaultCrossTenantWipe` is byte-identical to `5c3fc74c` (diff the function; the only delta in the merged change is the demo-bootstrap injection of the preserving variant).

**Deliverable.** The landed fix + a device verification report proving the walk is non-destructive and production `defaultCrossTenantWipe` is unchanged. **Operator-decision callout:** the fix touches the sync-host wiring (a proxy-adjacent seam) — per CLAUDE.md, proxy-touching slices require explicit operator approval regardless of audit verdict. The fix is demo-bootstrap-only and leaves production byte-unchanged; flag for operator sign-off before merge.

### Phase 2 — Honest-degrade-per-connection-state verification (N5)

**Scope.** Runtime/walkthrough verification (per `runbooks/browser_use_codex_acceptance_workflow.md` shape) that each location renders correctly for its connection state, **after Phase 1 (so every location is actually populated to verify against):**
- Harbour (none connected): Shift/Variance/Benchmark/Plan show honest "awaiting first connection" empty states — NO phantom zeros. `DemoModeBanner` shows demo.
- North Loop (POS only): labor-derived metrics (CPLH/SPLH/wage levers, labor dollars) degrade honestly (modeled, marked) — not fabricated vendor values; forward reservation book honestly absent.
- Riverside (all live): no banner; "CURRENT" semantics; full surfaces.
- Downtown (mixed, Reservation error): reservation context honestly degrades for the needs-reauth category; remediation message visible; everything else full.

**Deliverable.** Verification report + (only if a defect) a minimal honest-degrade fix in the affected widget (fabricating a zero where data is absent is a Metric Honesty bug, not a demo-data change). **No core-formula change.** If a fix requires a reader to branch on connection state, that is the EXISTING honest-degrade (state/provenance) path, not a `kDemoMode` branch.

**Depends on:** Phase 1 (a location wiped by symptom-B would falsely read as "honest-empty"). **Blocks:** none.

### Phase 3 — HP #11 pill rendering verification (N4)

**Scope.** Verify the seeded scope-level overrides (G10) render as scope chip + inherited-from + effective value on each mobile + web surface: North Loop timing (Region), Metro District data-accuracy (District), Riverside wage (Location), Harbour inherits (Business). Where a mobile surface is backend-only/gated (Gaps 29/30/32 known follow-ups), document it explicitly per CLAUDE.md HP #11 ("…or document why the capability is backend-only/gated/incomplete").

**Deliverable.** Verification report + doc note for any genuinely backend-only mobile HP #11 surface. UI work to expose a gated pill is a SEPARATE slice (app UX, not demo data) — flag as follow-up, do not fold in.

**Depends on:** Phase 1 (timing/wage tables are in the wipe set; verify against a populated location). **Blocks:** none.

### Phase 4 — Baseline / keyed-data-accuracy verification (N1–N3)

**Scope.** Verify N1 (override cascade visibly moves the pooled value with the current deterministic cohort spread — if too tight, widen the per-period spread in the seed deterministically, no RNG, no formula change), N2 (preview per-period math consistent post-Slice-2), N3 (demo seed writes keyed `data_accuracy_service_period_settings` per configured period; legacy `covers_source_*` columns killed per Gap 36 — the column-drop migration itself is Slice 2's scope, coordinate, do not duplicate).

**Deliverable.** Verification report + (only if N1 fails) a deterministic widening of the seed's per-period candidate spread (seed-only, HP #2-safe, no `LaborModel`/recommendation change).

**Depends on:** Phase 1 (cohort = `shift_records`, in the wipe set). **Blocks:** none.

> **No location-expansion phase.** Decision D-1 CANCELLED it.

### Sequencing

```
Phase 0 (decisions: DONE) ──► Phase 1 (land+verify cross-tenant-wipe fix — GATING, operator sign-off)
                                  ├─► Phase 2 (honest-degrade per connection state — N5, highest value)
                                  ├─► Phase 3 (HP #11 pill verify — N4)
                                  └─► Phase 4 (baseline / keyed data-accuracy — N1–N3)
```

Phases 2–4 can run in parallel once Phase 1 has landed (all three need every location populated to verify against). Phase 1 is the bottleneck and requires explicit operator approval (proxy-adjacent seam).

### Hard constraints reaffirmed for every phase

- **HP #2:** zero `demo_*` tables; zero new `kDemoMode` reader branches; all writes through existing production tables/DAOs; only the four blessed carve-outs read-side.
- **HP #4:** every row carries a concrete `restaurant_id` (+ demo operator id for `demo_mode_state`); RLS-ready schema untouched. The Phase 1 fix preserves the *production* HP #4 control byte-for-byte; it only changes the *demo bootstrap* variant.
- **Metric Honesty:** an unconnected vendor MUST degrade honestly (absent/marked, never a phantom zero).
- **No architecture change:** no edits to `LaborModel`, the recommendation engine, vendor connectors/`IntegrationProvider`, the proxy, auth, or RLS. The Phase 1 fix is a demo-bootstrap-only injection through an existing constructor seam; production `defaultCrossTenantWipe` byte-unchanged. Any required change beyond that → STOP, escalate as an operator-decision item.
- **Determinism:** no RNG, no `DateTime.now()` in seeded values; two reseeds byte-identical.
- **Backward compat:** `DemoScope.restaurantId='demo_restaurant_001'` / `'Barrio Legado'` for Downtown stays frozen; operator-web corp root keeps `demo-org-root` / "Demo Bistro".

---

## Appendix — Key evidence file:line index (verified @ `5c3fc74c`)

- **Demo contract + carve-outs:** `docs/contracts/demo_mode_contract.md`; `CLAUDE.md` → Demo Mode (HP #2/#4/#11)
- **Cross-tenant wipe (symptom-B BLOCKER):** `lib/services/sync/mobile_operational_sync_runtime.dart` — `defaultCrossTenantWipe:190-215` (8 `wipeForOtherScopes` calls), `_handleBusinessScopeChanged:434`, `_wipeOtherTenantsThenSync:422-432`, `crossTenantWipe` hook `:269,279`, `_handleAuthChanged:397-420` (`// BUG 1 (HIGH)` `:409-415`); delete pattern exemplar `lib/infrastructure/persistence/sqlite/dao/target_cycle_dao.dart:86-92` (`DELETE … WHERE restaurant_id != ?`). In-flight fix branch: `claude/fix-qa-demo-scope-switch-cross-tenant-wipe` (0 commits ahead of master @ `5c3fc74c`).
- **DemoScope / hierarchy:** `lib/infrastructure/persistence/sqlite/sqlite_database.dart` — `DemoLocation:54`, `DemoScope:77`, ids `:80,95-97`, `displayName:88`, `locations:104-130`
- **Seed orchestration:** `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart` — `_seedDemoRestaurant:854`, `_seedDemoTimingConfig:892`, `_seedDemoWageRoleRows:1175`, `_seedAdditionalLocationsFromReplay:1524`, `_seedDemoDataFromReplay:1676`, `_seedDemoVendorIntegrationModeStateSource:1799`, `_seedDemoScopeOverrideTimingConfig:1966`, `_seedDemoScopeOverrideWageRows:2004`, `_seedDemoScopeOverrideDataAccuracy:2072`, `_seedDemoVarianceBreachNotification:2152`, `_seedOperationalEnvelopeFromReplay:2303`, `_seedHistoricalOpenShiftSnapshotsFromReplay:2350` (non-Downtown current week `_buildCurrentWeekOpenShiftSnapshots:2418`, `isDowntown` guard `:2412`), `_seedForwardReservationEnvelopeFromReplay:2449`, `_seedHistoricalWeeklyPlanSnapshotsFromReplay:2525`, `_seedDemoSampleNotifications:2790`
- **Reseed lifecycle:** `lib/infrastructure/persistence/sqlite/sqlite_database.dart` — `reseedDemo:628` (deletes `:630-633`), `reseedMockReplayForBusinessDate:644` (deletes `:650-658`)
- **Demo flip / master switch:** `lib/services/integration/demo_mode_state.dart` — `DemoModeStateGateway:40`, `flipToLive:52`, `DemoModeFlipPolicy:71`, `evaluateFlip:82`, flip call `:107`; `lib/screens/settings/settings_demo_live_switch.dart` — `hasDemoCategories:47,139`, Live→Demo refusal copy `:140,156`
- **Vendor state fixture:** `lib/dev/demo_vendor_integration_state_fixture.dart` — `DemoVendorIntegrationLocation:50`, `isDemo:66`, `connectionStatus:74`, `_mobileLocationIds:111-114`, `_webLocationIds:123-126`, per-location matrix `:149-229`, safe default `:242`
- **Scope notifier / #828 re-scope wiring:** `lib/state/restaurant_scope_notifier.dart` — resolution `:156`, `getOrCreateActiveRestaurant:182`, `_seedAvailableScopesFromBootIfEmpty:205,229`; `lib/forge_flow_app.dart` (#828 scope-flip → `AppRefreshCoordinator.refreshAll` listener, post-frame/`mounted`-guarded/`stableKey`-deduped)
- **Org tree (operator-web):** `lib/operator_web/services/demo_team_fixtures.dart`
- **Recent merges baselined here:** `5c3fc74c` (#828 demo location switch re-scopes data), `f9d1829e` (#827 per-loc current-week open/projected for all 4), `c3055425` (#826 cold-boot partial-seed fix), `50845999` (#824 per-loc operational envelope), `8421759a` (#822 cold-boot current week → today)
- **Predecessor spec + slice audits:** `docs/_audits/per_daypart_v1/full_demo_data_spec.md`, `demo_slice_{a,b,c,d,e,f}_*.md`, `architecture_verification_2026_05_15.md`, `fix_qa_perloc_current_week_open_shift.md`, `fix_qa_location_scope_not_propagated.md`
- **Active feature plan:** `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`
