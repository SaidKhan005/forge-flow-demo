# INVESTIGATION — Labor-derived Shift metrics render "not connected" for ALL demo locations

> ## ✅ RESOLVED in source — 2026-05-16, master `b7d53df5`
> Baselined at `e8601d5b`. The root cause (whole-day Shift labor provenance
> getters hard-gate on `laborSourceVendorId == null`; no production caller
> passed it) was fixed by PR #839 (`14b116cc` + `087ecfdb`) which wired
> `ShiftVendorSourceResolver` so both `buildWholeDay()` callers pass
> `posSourceVendorId`/`laborSourceVendorId`. PR #854 further made the
> none-connected location honest-EMPTY. Device-verified 2026-05-16: Riverside
> (all-live) shows no demo banner; Downtown/North Loop show demo banners
> correctly; Harbour honest-empty. **Closed.**

Status: COMPLETE — root cause definitively isolated. Read-only investigation, no code changes.
Repo root: `C:\Git Local Repos\forge_flow_demo`. Master baseline: `e8601d5b`.

---

## 1. Verdict (one-line)

**Classification: (b) — a WIRING/gating defect, NOT a seed gap (a) and NOT a fixture-vs-intent
mismatch (c).**

The whole-day Shift card suppresses every labor-derived metric (blended wage, CPLH, SPLH,
labor %) and the vendor-source line because the read-model's labor provenance getters
hard-gate on `laborSourceVendorId == null`, and **no production caller ever passes
`laborSourceVendorId` (or `posSourceVendorId`)**. The labor-shaped data IS present in the
table the Shift card reads, and the vendor-connection fixture IS faithful to the spec — the
metric is hidden purely by an unwired provenance argument that defaults to `null`.

A precise secondary note: the *banners* and the *Variance/per-period path* are governed by a
completely different (correct, per-location) mechanism, which is why they behave correctly
while the whole-day card does not. That asymmetry is the tell.

---

## 2. The exact root cause (file:line)

### 2.1 The gate

`lib/models/shift_dashboard_read_model.dart`:

- `cplhProvenance` — line **171**: `if (laborSourceVendorId == null || actualFohHours <= 0) { return const MetricProvenance.unavailable(); }`
- `splhProvenance` — line **188**: `if (laborSourceVendorId == null || actualBohHours <= 0) { return const MetricProvenance.unavailable(); }`
- `blendedWageProvenance` — line **206**: `if (laborSourceVendorId == null) { return const MetricProvenance.unavailable(); }`
- `laborSourceVendorId` getter — line **127**: returns the private `_laborSourceVendorId`, set only from the constructor arg (line **268**), which defaults to **`null`** (line **265**, `String? laborSourceVendorId`).

When `laborSourceVendorId` is `null`, all three getters return `MetricProvenance.unavailable()`
**regardless of the underlying numeric value**. The hours columns aside, every labor pill goes
to the `unavailable` branch.

By contrast, `coversProvenance` (line **139**) and `salesProvenance` (line **149**) only return
`unavailable` when the VALUE is also absent: `if (actualCovers <= 0 && posSourceVendorId == null)`.
Because the seed writes covers/sales > 0, POS metrics render `live` even with
`posSourceVendorId == null`. **This asymmetry is exactly why the device shows POS populated but
labor "not connected" — same null vendor id, different guard shape.**

### 2.2 The unwired argument — no caller passes it

`buildWholeDay` accepts `posSourceVendorId` / `laborSourceVendorId`
(`shift_dashboard_read_model.dart:323-324`) and forwards them (lines **511-513**), defaulting to
`null` / `null` / `laborDollarsFromVendor=true`.

Both production callers omit both arguments:

1. `lib/state/shift_dashboard_notifier.dart:153-161` — `ShiftDashboardReadModel.buildWholeDay(...)`
   is called with `snapshots / profile / forecastCovers / forecastSales / planFohHours /
   planBohHours / inTheBooksCovers` only. **No `laborSourceVendorId`, no `posSourceVendorId`.**
2. `lib/services/shift_service.dart:1023-1031` — `ShiftDashboardReadModel.buildWholeDay(...)`,
   same omission.

A repo-wide search for `laborSourceVendorId` / `posSourceVendorId` (lib/**/*.dart) confirms
**no other file passes a non-null value** into the Shift read model. The only related symbol
in a builder is `laborDollarsFromVendor` inside `lib/domain/services/shift_fact_builder.dart`
(the *variance ShiftFact* path, lines 30-113) — a different model (`ShiftFact`), not the Shift
dashboard read model.

### 2.3 The render chain that surfaces it

- `lib/screens/shift_dashboard.dart:771-784` — `_ShiftSectionViewData.fromWholeDay(rm)` maps
  `blendedWage: rm.blendedWageProvenance`, `cplh: rm.cplhProvenance`, `splh: rm.splhProvenance`
  **directly from the read-model getters**. No re-derivation, no fixture lookup.
- `shift_dashboard.dart:1014-1026` — the BLENDED WAGE `MetricPill` renders the `unavailable`
  state with tooltip `'Connect a labor vendor to see blended wage.'` (line **1020**).
- `shift_dashboard.dart:1078-1099` — CPLH/SPLH pills with
  `'Connect a labor vendor to see covers per labor hour.'` (**1083**) /
  `'... sales per labor hour.'` (**1094**).
- `shift_dashboard.dart:2027-2031` — `_ShiftDashboardHealthPill` maps
  `readModel.cplhProvenance` (unavailable) to the override summary
  `'Labor: not yet connected'` (line **2030**, sentence assembled at line **1996**).

All four observed labor symptoms ("Labor: not yet connected" pill, blended wage "—", CPLH "—",
labor % effectively unanchored) trace to the single null-`laborSourceVendorId` gate in §2.1,
fed by the omission in §2.2. **One root cause, four surfaces.**

---

## 3. Why this is NOT a seed gap (rules out (a))

The demo seed DOES write labor-shaped data into the exact table the Shift card reads
(`open_shift_snapshots`), for **all four** locations:

- `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart`:
  - `_buildCurrentWeekOpenShiftSnapshots` (line **162**) builds `OpenShiftSnapshot`s carrying
    `scheduledFohHours` (line **189/234/264**), `scheduledBohHours`, and `blendedWage`
    (line **194/239/269**).
  - `_seedOpenShiftSnapshotsFromReplay` (line **294**) inserts them into `open_shift_snapshots`
    (line **305**).
  - `_seedHistoricalOpenShiftSnapshotsFromReplay` (line **2350**) calls the SAME shared builder
    per location (line **2418**) and inserts closed + current-week rows (line **2404/2425**),
    explicitly per-location (the `isDowntown` guard only affects the historical envelope, not
    the current-week open shift every location gets).

`ShiftDashboardReadModel.buildWholeDay` then computes real labor numbers from those snapshots:
`actFoh`/`actBoh` (`shift_dashboard_read_model.dart:361-368`), `avgCPLH`/`avgSPLH`
(**375-376**), `avgBlendedWage` (**379-386**), `actualLaborPct` (**401-403**). These compute to
non-zero values for every demo location — which is precisely why the **Variance tab shows
fully populated ACTUAL/VAR labor numbers** (the user's own observation, and a direct
confirmation that the data exists). The seed is not the problem.

---

## 4. Why this is NOT a fixture-vs-intent mismatch (rules out (c))

`lib/dev/demo_vendor_integration_state_fixture.dart` `_states` (lines **145-234**) matches the
spec (`docs/_audits/per_daypart_v1/full_demo_data_spec.md` §1.5/§2f/§2g, lines 168-170) exactly.
Enumerated per (location, category) — `isDemo` / `connectionStatus`:

| Location | POS | Labor | Reservation |
|---|---|---|---|
| **Downtown** (`demo_restaurant_001`) — fixture L151-169 | demo=true, **connected** | demo=true, **connected** | demo=true, **error** (reauth msg) |
| **North Loop** (`demo_restaurant_north_loop`) — L171-191 | demo=true, **connected** | demo=true, **disconnected** | demo=true, **disconnected** |
| **Riverside** (`demo_restaurant_riverside`) — L192-212 | demo=**false**, **connected** | demo=**false**, **connected** | demo=**false**, **connected** |
| **Harbour** (`demo_restaurant_harbour`) — L213-233 | demo=true, **disconnected** | demo=true, **disconnected** | demo=true, **disconnected** |

This is faithful to the spec's intended matrix (Downtown all-3 with reservation in error;
North Loop POS-only; Riverside all-3 live; Harbour none). The fixture is correct.

Crucially, **the Shift labor metrics never consult this fixture, `demo_mode_state`, the
`DemoModeStateNotifier`, or any connected-categories signal.** They consult only
`ShiftDashboardReadModel.laborSourceVendorId`. So even a perfect fixture cannot turn the
labor pills on — the two systems are not connected to each other.

### 4.1 What each surface actually shows per location (and why)

The fixture-driven *banner* path IS wired and per-location-correct, via a different code path:

- `lib/dev/demo_vendor_integration_sync_proxy_client.dart:74-82` →
  `DemoVendorIntegrationStateFixture.demoModeRecords(...)` feeds
  `DemoModeStateNotifier` (`lib/state/demo_mode_state_notifier.dart:215`), which drives
  `DemoModeBanner` (`lib/widgets/demo_mode_banner.dart:44-48`,
  `hasDemoCategories` at `demo_mode_state_notifier.dart:83-86`).

Resulting per-location truth:

| Location | Vendor fixture says | Banners (fixture-driven, CORRECT) | Shift card labor pills (read-model gate, BROKEN) | Seed actually wrote |
|---|---|---|---|---|
| Downtown | POS+Labor connected, Reservation error; all `is_demo=true` | All 3 banners | "not connected" (gate, §2.1) | Full labor in `open_shift_snapshots` |
| North Loop | POS connected; Labor/Res disconnected; all `is_demo=true` | All 3 banners | "not connected" (gate) | Full labor |
| Riverside | All connected, all `is_demo=false` | **ZERO banners** (`hasDemoCategories=false`) | "not connected" (gate) | Full labor |
| Harbour | All disconnected, all `is_demo=true` | All 3 banners | "not connected" (gate) | Full labor |

So banners ARE per-location-distinct (Riverside should render no banners; the other three
render all three). The whole-day labor pills are uniformly broken across all four because
their gate is independent of the fixture. The device report of "all 3 banners always" is
consistent if Riverside was not inspected; the labor-pill uniformity is fully explained by
§2.

### 4.2 Why Variance / per-period is fine but whole-day is not

`lib/screens/shift_dashboard.dart`:

- `_ShiftSectionViewData.fromPeriod` (lines **814-959**): gates labor on
  `hasLabor = bucket.totalMinutes > 0` (line **850**) via
  `liveOr(hasLabor, ...)` (lines **846-848, 951-954**). It does **NOT** consult
  `laborSourceVendorId`. With seeded labor minutes present, CPLH/SPLH/blended wage render
  `live`. → per-period / Variance labor populated.
- `_ShiftSectionViewData.fromWholeDay` (lines **771-806**): delegates to the
  `laborSourceVendorId`-gated read-model getters. → whole-day labor blank.

Same underlying data, two different gates — one value-based (correct), one
vendor-id-based-and-unwired (broken). This asymmetry is the definitive fingerprint of a
wiring defect.

---

## 5. Definitive classification

**(b) WIRING/gating defect.** Exact gate:
`lib/models/shift_dashboard_read_model.dart:171, 188, 206` (`laborSourceVendorId == null`
short-circuits to `MetricProvenance.unavailable()`), fed by the omission of the
`laborSourceVendorId` argument at `lib/state/shift_dashboard_notifier.dart:153-161` and
`lib/services/shift_service.dart:1023-1031`. Not (a) (seed writes the labor data — §3).
Not (c) (fixture matches spec — §4).

---

## 6. PLAN-ONLY remediation (no code changes here)

Goal restated: the demo must behave as if all 3 vendor types are connected and backfilled —
a complete, nothing-missing dataset on the whole-day Shift card for every demo location.

### 6.1 Is "show all 3 vendors connected, full labor+reservation metrics" a seed-only change?

**No — it is not seed-only, and it is NOT core-logic either.** The labor data is already
seeded (§3); seeding more rows changes nothing because the gate never inspects rows. The fix
is a small **read-model-builder wiring change in the demo composition path**: cause the demo
Shift read model to carry a non-null `laborSourceVendorId` (and `posSourceVendorId`, for the
provenance vendor name) so the existing honest-degrade gate evaluates against the
data-that-already-exists instead of a perpetually-null sentinel.

This sits inside the **auto-fixable envelope** (demo-data/seed + UI rendering + lifecycle):
it is a demo read-model wiring change, not a formula change, not a service-seam change, not an
integration/connector/proxy/auth/RLS change, introduces no `demo_*` table, and adds no
`kDemoMode` reader fork. The provenance getters' honest-degrade contract is preserved
verbatim — they still degrade when the value is genuinely absent (e.g. zero hours); they
simply stop degrading on the wiring sentinel.

### 6.2 Recommended approach (lowest blast radius), in scope

Option A (preferred): in the demo composition, pass the demo vendor ids into the whole-day
builder. Concretely, have the demo-resolved Shift path supply
`posSourceVendorId: 'toast'` and `laborSourceVendorId: 'humanity'` (the fixture's own
`_posVendorId` / `_laborVendorId`, `demo_vendor_integration_state_fixture.dart:132-135`) to
`ShiftDashboardReadModel.buildWholeDay` at the two call sites
(`shift_dashboard_notifier.dart:153-161`, `shift_service.dart:1023-1031`). Source the ids
from the same per-(operator, location, category) fixture already wired into the demo proxy
client, keyed by the active `restaurantId` — so per-location fidelity is honored (e.g. a
location whose labor fixture is `disconnected` could legitimately pass `null` and keep the
honest "not connected" copy, if the operator wants the matrix to read true; or pass non-null
for all four if the binding goal of "everything connected" overrides the per-location story —
this is the one operator decision to confirm, see §6.3).

Option B (broader, flag if Option A is rejected): collapse the read-model gate so labor
provenance keys off the value (mirroring the covers/sales guard at lines 139/149:
`value <= 0 && laborSourceVendorId == null`) instead of `laborSourceVendorId == null` alone.
This changes the honest-degrade semantics for the *production* path too (labor would render
from `wage × hours` even with no labor vendor) — that is a Metric-Honesty-Doctrine /
`metric_card_honesty_contract.md` change touching app rendering semantics for all operators,
**ESCALATE** (architecture/contract-touching), do not auto-apply.

### 6.3 Operator decision required before implementation

The fixture intentionally encodes a *mixed* matrix (Riverside live, North Loop labor
disconnected, Harbour all disconnected). The binding goal "behave as if all 3 vendors
connected, nothing missing" **contradicts** that per-location story for North Loop / Harbour.
Confirm which the operator wants:

- (i) **Uniform "everything connected" across all 4 demo locations** — pass non-null
  `pos`/`labor` (and wire reservation context likewise) regardless of fixture status. Simplest;
  loses the mixed-state demo narrative the fixture/spec built.
- (ii) **Per-location fidelity** — derive the vendor ids from the fixture per `restaurantId`
  so Downtown/North-Loop(POS)/Riverside render connected where the fixture says connected,
  and the disconnected categories keep the honest "not connected" copy. Preserves the spec
  matrix; Harbour/North-Loop labor still reads "not connected" *by design*.

Either is seed/wiring-scoped (in scope). The reservation-context plumbing is analogous (the
read model carries `inTheBooksCovers` from `ReservationBookSnapshot`; a parallel
`reservationSourceVendorId`-style wiring may be needed if reservation has the same null-gate —
recommend a follow-up grep on the reservation render path before implementation, scoped the
same way).

### 6.4 Out of scope / ESCALATE (do not auto-fix)

- Any change to `MetricProvenance` semantics or `metric_card_honesty_contract.md` (Option B).
- Any change to `LaborModel` / `ShiftDashboardReadModel` *formulas* (the math is correct;
  only the provenance gate input is unwired).
- Any vendor connector / proxy / `demo_mode_state` Postgres / RLS change.
- Introducing a `demo_*` table or a `kDemoMode` reader branch (HP #2 violation).

---

## 7. Evidence index (file:line)

- Gate: `lib/models/shift_dashboard_read_model.dart:127, 171, 188, 206, 264-269, 511-513`
- Covers/sales asymmetric guard (why POS shows, labor doesn't):
  `lib/models/shift_dashboard_read_model.dart:139, 149`
- Unwired callers: `lib/state/shift_dashboard_notifier.dart:153-161`;
  `lib/services/shift_service.dart:1023-1031`
- Whole-day render mapping: `lib/screens/shift_dashboard.dart:771-784`
- "Connect a labor vendor" tooltips / "Labor: not yet connected":
  `lib/screens/shift_dashboard.dart:1020, 1083, 1094, 1996, 2030`
- Per-period (correct) path: `lib/screens/shift_dashboard.dart:814-959` (esp. 846-850, 951-954)
- Seed writes labor for all locations:
  `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart:162, 189-194, 294, 305,
  2350, 2404, 2418, 2425`
- Read-model labor computation from snapshots:
  `lib/models/shift_dashboard_read_model.dart:361-403`
- Fixture (spec-faithful): `lib/dev/demo_vendor_integration_state_fixture.dart:145-234`
- Banner path (fixture-driven, separate, correct):
  `lib/dev/demo_vendor_integration_sync_proxy_client.dart:74-82`;
  `lib/state/demo_mode_state_notifier.dart:83-86, 215`;
  `lib/widgets/demo_mode_banner.dart:44-48`
- Spec intent matrix: `docs/_audits/per_daypart_v1/full_demo_data_spec.md:168-170`
