# Integration Spine Architecture Contract

Status: Active
Updated: 2026-05-04
Owner: Phase 8 spine-bridge sprint
Authority: Tier-2 contract (binds every `8.spine-bridge.*` sub-lane and the
`8.integration-mobile-proof` re-run)
Companions:

- `docs/contracts/vendor_adapter_slice_contract.md` — adapter rules (left half)
- `docs/contracts/per_vendor_doc_pack_contract.md` — per-vendor doc folder
- `docs/contracts/metric_card_honesty_contract.md` — renderer chrome
- `docs/contracts/phase_7_55_time_boundary_contract.md` — UTC + business_date storage
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` — RLS + OperatorScopedRepository
- `docs/archive/_execution/2026-05-04_8_integration_mobile_proof_execution.md` — origin
- `docs/archive/_execution/2026-05-04_vendor_api_access_and_mobile_e2e_gap.md` — gap memo

This contract closes the gap between Wave B's "vendor adapter ships at
lifecycle = `documented`" and Phase 8 / 8R / 8.S engineering-complete
acceptance. It defines the spine — the run-time path that takes a
vendor payload, produces operator-scoped canonical facts, aggregates
them into `ClosedShiftInput`, builds `ShiftFact` via the existing
domain pipeline, lands the resulting `ShiftRecord` on operator-scoped
Postgres, and syncs it into mobile SQLite where the existing dashboard
read path consumes it.

When this contract and a slice doc conflict, this contract wins. When this
contract and `core_app_architecture.md` conflict, `core_app_architecture.md`
wins — this contract is the implementation layer that binds to the
core architecture's Layers 1–12.

## 2026-05-05 falsehood corrections (binding) — supersedes 2026-05-04

The 2026-05-04 corrections were partially wrong. Vendor-research pass
on 2026-05-05 produced these binding corrections:

1. **ADP is webhook-driven, not poll-only.** Wave B
   `adp_labor_adapter.dart` line 561 declares `autoRegister`. ADP does
   NOT appear in the polling cadence list. ✅ confirmed.

2. **Square `coversFieldExposed: false` is CORRECT — REVERSE the
   2026-05-04 "configurable" amendment.** Square Developer Relations
   confirmed (open feature request since Dec 2021, re-acknowledged May
   2024 + May 2025): cover count is NOT available through Square APIs.
   Square for Restaurants UI tracks covers, but the data does NOT
   surface through the Orders API. Wave B `coversFieldExposed: false`
   is the truth. The earlier "tri-state configurable" framing was
   built on a misread of operator-side UI evidence.

3. **Clover `coversFieldExposed: false` is CORRECT — REVERSE the
   2026-05-04 "configurable" amendment.** Clover Dining App displays
   guest count, but it lives in a private schema NOT reachable via
   `/v3/merchants/.../orders`. Clover docs explicitly state Dining-
   specific metadata is not recognized through external order
   creation. The public Orders REST API has no `numberOfGuests`,
   `guestCount`, `partySize`, or `coverCount` field. Wave B
   `coversFieldExposed: false` is the truth.

4. **Aloha NCR Voyix `coversFieldExposed: true` is RISKY — likely
   tri-state in reality.** Aloha is the strongest candidate for a
   genuine tri-state `configurable` enum. Aloha's QSR vs full-service
   tier split likely makes `numberOfGuests` exposure conditional. The
   developer portal is auth-gated; cannot verify. The Wave B doc-pack
   already hedges this in narrative; the boolean flag does not.
   **Recommended action:** flip to `false` until `8.AL.live.sandbox`
   verifies, OR adopt the tri-state enum (`always` / `configurable` /
   `never`) on `VendorCapabilityProfile`.

5. **Oracle Simphony covers field path is WRONG.** Doc pack says
   `guestChecks[].numOfGst`; adapter constant says `numberOfGuests`;
   Gen2 reality is `items[].header.guestCount`. **Three-way
   disagreement guaranteed to fail at first live payload.** This is
   the highest-risk falsehood in the audit. Must fix before
   `8.OR.live.sandbox`. Action: update
   `docs/integrations/oracle_micros_simphony/field_mapping.md` to
   `items[].header.guestCount` + audit other timestamp paths
   (`opnUTC` / `clsdUTC` likely also legacy Gen1 names).

6. **QuickBooks Time labor wage class WRONG.** Claimed
   `perEmployeeWithDollars`; actual is `perEmployeeWithRates`. QBT's
   Timesheets endpoint returns hours only; wage rate lives on
   `Users.pay_rate`. The aggregator must compute dollars via rate ×
   duration, NOT sum vendor-supplied dollars.

7. **7shifts labor wage class PARTIAL.** `perEmployeeWithDollars`
   is correct ONLY IF the adapter consumes `/reports/hours_and_wages`
   (which exposes `total_pay`). The current Wave B mapping does NOT
   include that endpoint. Today the lived classification is
   `perEmployeeWithRates` (`hourly_wage` on time-punches). Action:
   either downgrade classification OR add the report endpoint to the
   adapter as a follow-up.

8. **ADP labor wage class V1 = `hoursOnly`.** Wave B
   `adp/field_mapping.md` explicitly defers wage ingestion. Reclassify
   `perEmployeeWithDollars` → `hoursOnly` for V1; revisit
   post-partnership.

9. **Push Operations labor wage class WRONG.** Claimed
   `perEmployeeWithDollars`; the documented Wave B mapping has zero
   wage rows. Today's lived classification is `hoursOnly`. Push's
   primary docs are inaccessible (developer portal landing-page only),
   so higher capability cannot be verified. Reclassify to `hoursOnly`
   until primary doc confirms.

10. **Tock `seated_at` claim REFUTED.** Tock's public reference
    documents only `createdTimestamp`, `lastUpdatedTimestamp`,
    `serviceDateTimestamp`. There is NO seated_at timestamp. The
    Wave B doc-pack already correctly flags this gap. The
    "reservation + walk-in handling" path (`8.spine-bridge.2`
    aggregator) MUST handle Tock's missing seated_at gracefully —
    either fall through to "reservations as forecast lower bound
    only" or skip Tock from Pattern A's seated-time-based confirmation
    flow.

11. **`target_profile_version_id` preservation rule is NOT new.**
    Verified via grep: the rule already exists in
    `core_app_architecture.md` lines 192, 526 and
    `integration_spine_architecture_contract.md` lines 201, 560,
    571, 599-600. It was always there. Earlier drafts that called it
    "Concern A — proposed new rule" were wrong; the rule was already
    binding.

12. **Layer count is 13, not 12.** Phase 7.55 architecture contract
    has 5A as a distinct sub-layer (Benchmark range-state contract).
    Earlier framings of "Layers 1–12" undercount by one. Update to
    "Layers 1–13" or "Layers 1–12 plus Layer 5A."

13. **Oracle Simphony pricing class CANNOT VERIFY.** Reclassify from
    "per-call" to `pricing_unverified_partner_gated`. F&F's polling
    tier price estimate for Simphony is speculative until Wave D
    activates partner credentials. (This is moot if F&F adopts the
    tier-pricing model below — F&F absorbs vendor cost; operator
    sees tier price only.)

The actual Square Restaurants + Clover Dining truth is now confirmed:
**both vendors expose covers in operator UI but NOT through their
public REST APIs.** The earlier "configurable" hypothesis is dead.
Square + Clover stay `coversFieldExposed: false` per Wave B.

## Out of scope (binding)

The spine bridge wires the **closed-shift** truth path: vendor → adapter
→ canonical fact → aggregator → `ShiftRecord` → operator-scoped Postgres
`shift_records` → mobile SQLite → existing dashboard read path.

Explicitly **out of scope** for this sprint and the
`8.integration-mobile-proof.v2` proof gate:

- **`OpenShiftSnapshot` (Layer 2 + Layer 9 in-progress canonical fact).**
  The Shift dashboard's live in-progress card stays demo-seeded until
  `8.spine-bridge-live` (separate follow-up sprint) wires real-time vendor
  webhook + poll streams into `open_shift_snapshots` with current_covers /
  current_ppa / current_cplh / current_splh.
- **`ReservationBookSnapshot`** mid-service updates (handled by the same
  separate sprint).
- **Service-period live view** (Phase 10.5 additive surface) — wired
  alongside whole-day in `8.spine-bridge-live`, not here.

This sprint's proof gate (`8.integration-mobile-proof.v2`) verifies
closed-shift behavior only.

## Business Timing / Live Shift amendment (2026-05-06)

Parallel sink implementations must preserve the closed-spine boundary above.
They may write canonical facts and closed `ShiftRecord` outputs, but they must
not write `open_shift_snapshots` or introduce a second service-period resolver.

Live in-progress Shift is a follow-up lane with this required shape:

```text
canonical POS/labor/reservation facts
-> OpenShiftSnapshotProjector
-> public.open_shift_snapshots
-> event_outbox topic open_shift_snapshot_changed
-> proxy read endpoint
-> mobile SQLite mirror
-> Shift whole-day + service-period selectors
```

Business timing source of truth is server-side `business_timing_profiles` plus
`business_timing_service_periods`; mobile timing configs are resolved read
models only. Closed aggregation must use the timing profile/service-period key
in force at bucket time, and closed rows must not be silently re-bucketed after
timing edits.

## Why this exists

Wave B proved 17 vendor adapters in fixture isolation. The
`8.integration-mobile-proof` lane (FAIL 2026-05-04) showed the
right-half spine — adapter output → operator dashboard — is
structurally absent. Three concrete seams are missing, plus a sharper
architectural realisation that the mobile app reads SQLite, not
Postgres directly. This contract names the seams, the file boundaries,
and the per-sub-lane acceptance gates.

## The two-store architecture

| Store | Path | Job | Phase 8.0 status |
|---|---|---|---|
| Postgres (server-side) | `lib/infrastructure/persistence/postgres/**` | Canonical truth across an operator. Operator-scoped via RLS + `OperatorScopedRepository.withTenant`. Vendor adapter writes land here. | ✅ Migration `202605040000` added vendor columns to `shift_records` / `cover_facts` / `labor_punches` / `reservation_facts`. |
| SQLite (mobile-side) | `lib/infrastructure/persistence/sqlite/**` | Read store for the operator phone app. Holds aggregated `shift_records` / `week_records` / snapshots / locked targets. Demo seed lives here. | ❌ No vendor-column parity yet; vendor provenance threads via existing `source_system` until parity migration lands. |

**Hard rule.** Mobile SQLite never speaks to vendors and never speaks
to Postgres directly. All vendor → mobile flow goes through
server-side Postgres + the proxy. CLAUDE.md Hard Promise #4 +
`hardening_rls_and_repository_pattern_contract.md`.

## The canonical chain (binding)

The spine has exactly these stages, in this order. Every sub-lane
binds to this shape:

```text
─── server ─────────────────────────────────────────────────────────────
1. Vendor payload arrives at adapter
   - Webhook: InboundWebhookHandler dispatch (existing 8.0 framework)
   - Poll tick: integration sync worker dispatch (NEW — 8.spine-bridge.0)

2. Adapter produces canonical-fact Map<String, Object?> per vendor entity
   - One POS check / one labor punch / one reservation per Map
   - Schema captured per `documented_per_<vendor>_<api_version>` constants
   - Existing 17 Wave B adapters do this correctly today

3. Postgres-backed CanonicalSink writes canonical fact rows
   - lib/infrastructure/persistence/postgres/<vendor>_postgres_sink.dart (NEW per trio)
   - OperatorScopedRepository.withTenant(operatorId, locationId, ...)
   - Idempotency UNIQUE (vendor_id, operator_id, vendor_entity_id, vendor_modified_at)
   - business_date denormalized at write via IANA converter
   - raw_payload JSONB for forensic re-derivation

4. Watermark advance after each batch commit
   - connector_sync_watermark.cursor_token + last_modified_seen
   - Cloud Run Job restart resilience

5. DemoModeFlipPolicy.evaluateFlip invoked after first successful batch
   - Gates: connectionStatus=connected ∧ firstBackfillCommitted ∧ recordsWritten >= 1
   - Idempotent: subsequent flips are no-ops
   - Disconnect does NOT auto-revert

6. Service-period-complete signal triggers aggregator
   - Trigger: poll tick / webhook batch finalises a
     (business_date, service_period_key) bucket
   - Aggregator file: lib/services/integration/canonical_fact_to_closed_shift_input.dart (NEW — 8.spine-bridge.2)
   - Walks operator-scoped Postgres cover_facts + labor_punches + reservation_facts
   - Resolves covers source via 4-way decision per
     `data_accuracy_settings_contract.md` (Concern B — sanctioned
     concession to core_app_architecture.md Layer 2):
       1. operator manual entry for this
          (business_date, service_period_key) ->
          covers source = `operator_manual_entry_per_daypart`
       2. else, POS adapter declared coversFieldExposed=true AND vendor
          fact populated -> covers source = `vendor_<id>` (live truth)
       3. else, fall back to F&F-derived forecast covers from
          DemandForecastContext for that service period -> covers source =
          `vendor_<id>_covers_unavailable_app_forecast_substituted`.
          The forecast itself is F&F-computed (Layer 6), never vendor-
          supplied; the provenance string makes that explicit.
       4. else, no covers source available -> the aggregator returns
          null (no ShiftRecord written; dashboard renders
          MetricCardNotYetAvailable per metric_card_honesty_contract.md).
   - Resolves labor dollars source via 4-way decision (per the Jim
     Taylor wage-model amendment 2026-05-04 — per-position vendor data
     is closer to model truth than per-employee):
       1. operator wage source = manual mix (Data Accuracy override) ->
          dollars source = `target_wage_substituted` using the operator-
          set wage_role_rows mix unconditionally.
       2. else, vendor in `LaborWageSourceClass.perEmployeeWithDollars`
          (7shifts, QBT, ADP, Push Operations) AND adapter populated
          per-shift dollars -> aggregator sums to FOH/BOH dollars;
          provenance = `vendor_<id>_per_employee_actual_dollars`.
       3. else, vendor in `LaborWageSourceClass.perPositionWithRates`
          (Humanity, Agendrix) AND vendor exposed per-position pay
          rates + scheduled hours -> aggregator computes actual dollars
          via rate × scheduled_hours per role; provenance =
          `vendor_<id>_per_position_actual_dollars`. Per-position data
          maps 1:1 to `wage_role_rows` (the Jim Taylor model's
          weighted-up FOH/BOH input). Wage editor "review/override" UX
          is post-spine-bridge follow-up `8.wage-editor-seed`.
       4. else, vendor exposes neither dollars nor rates -> fall back
          to target wage × hours; provenance =
          `vendor_<id>_dollars_unavailable_target_wage_substituted`.
   - Resolves service_period_key per the server-side effective
     business_timing_profiles / business_timing_service_periods snapshot
     in force at bucket time. Mobile RestaurantTimingConfig rows are resolved
     read models only.

7. ShiftFactBuilder.fromClosedShiftInput runs (existing pure function; do not modify)
   - Pure, deterministic; no I/O

8. PostgresShiftRecordWriter persists ShiftRecord
   - lib/infrastructure/persistence/postgres/postgres_shift_record_writer.dart (NEW — 8.spine-bridge.2)
   - OperatorScopedRepository.withTenant
   - replace-for-slot semantics matching existing close-shift contract
   - sourceSystem = vendor_id (e.g. "oracle_micros_simphony"), NOT "demo"
   - **Binding rule (Concern A — protects core_app_architecture.md
     Layer 4 + Layer 11 + Layer 12 + the "What never rewrites" non-
     negotiables):** on re-aggregation (when a corrected vendor fact
     arrives and the aggregator overwrites a previously-written
     ShiftRecord for the same slot), the writer MUST read the existing
     row's `target_profile_version_id` and re-use it. Only a first-
     time aggregation for a brand-new service period mints a fresh
     `TargetProfileVersion` from the current `ActiveTargetProfile`.
     Vendor corrections never re-grade closed history under a newer
     cycle. The aggregator surfaces `priorTargetProfileVersionId` (or
     null for first-time) on its return value so the writer can apply
     this rule deterministically. The writer also persists the
     timing_profile_version_id and service_period_key used to bucket the row,
     so closed history remains unambiguous after timing edits or renames.

9. NOTIFY emits change row → Pub/Sub → WebSocket bridge
   - Existing Phase 10a infrastructure
   - Topic: shift_record_changed; payload: { operator_id, location_id,
     business_date, service_period_key }

─── mobile ─────────────────────────────────────────────────────────────
10. Mobile WebSocket consumer receives signal
    - Existing infrastructure

11. ServerToMobileShiftRecordSync pulls fresh row(s) via proxy
    - lib/services/sync/postgres_shift_record_to_mobile_sync.dart (NEW — 8.spine-bridge.3)
    - GET /v1/operators/<op>/locations/<loc>/shift_records?modified_since=<cursor>
    - Bounded pull (no whole-table sweeps)
    - Proxy enforces RLS via OperatorScopedRepository.withTenant

12. SqliteShiftRecordRepository.replaceShiftForSlot persists locally
    - Existing repository; row shape unchanged
    - sourceSystem column carries the vendor_id

13. AppRuntimeInvalidationBus.notifyRuntimeWriteCompleted fires
    - Existing signal

14. Dashboard / variance / history / learn / metric honesty pill refresh
    - Existing read path
    - MetricProvenance state derives from sourceSystem (live vs demo) + per-metric input availability (covers / labor dollars)
    - MetricCardNotYetAvailable renders when state == unavailable
```

## Sub-lane shape (binding)

The `8.spine-bridge` sprint ships **9 lanes file-disjoint** (was 6 before
the 2026-05-04 Data Accuracy + provenance + Concerns A/B/C amendments),
plus a sequential proof re-run. Codex grades each lane against this
contract plus the cited companions.

Wave layout:

- Lane 1 (`.0`) ships first as the seam. **Already running on a
  worktree as of 2026-05-04.** The 2026-05-04 amendments are additive
  for `.0` — see Lane `.0a` below.
- Lane `.0a` (NEW, sequential after `.0`) — small additive lane that
  gives the running sync worker a per-(operator, location, vendor)
  polling cadence resolver. Reads F&F-owned tier assignments from
  `forge_flow_polling_tier_assignment` (created by Lane `.A`). Operators
  never set cadence directly. File-disjoint with everything else.
- Lanes `.1.OR` / `.1.QBT` / `.1.LB` / `.2` / `.3` / `.A` / `.B` / `.C`
  run in parallel (file-disjoint) after `.0` lands.
- Lane `.4` (`8.integration-mobile-proof.v2`) runs sequentially after
  Lanes `.0` / `.0a` / `.1.*` / `.2` / `.3` / `.A` / `.B` / `.C` all
  land.

Sub-lanes `.A` / `.B` / `.C` add the Data Accuracy surface per
`docs/contracts/data_accuracy_settings_contract.md`.

### `8.spine-bridge.0` — Seam definition (ships first; consumes nothing)

Shared seam every later lane consumes. Must land before lanes 1.* /
2 / 3 start.

**Files NEW.**

- `tool/advisor_proxy/pos_adapter_registry.dart`
- `tool/advisor_proxy/labor_adapter_registry.dart`
- `tool/advisor_proxy/reservation_adapter_registry.dart`
- `tool/integration_sync_worker/main.dart`
- `tool/integration_sync_worker/dispatch.dart`
- `lib/services/integration/canonical_sink.dart` — the unified sink
  interface every `*_postgres_sink.dart` implements.

**Files MODIFY.**

- None. The Wave B adapters do not change. The bespoke per-vendor
  sink interfaces inside each adapter (e.g. `OracleMicrosSimphonyCanonicalSink`)
  stay; the new `CanonicalSink` wraps them via per-trio sub-lanes.

**Contract bindings.**

- Registry consumes every Wave B adapter's `vendorId` →
  `Adapter` mapping.
- Sync worker dispatch reads `connector_connection` rows for
  `status = connected`; calls `pollIncremental` per cadence
  (vendor-defined; default 60s); routes webhook events through the
  existing `InboundWebhookHandler` to the registered adapter.
- `CanonicalSink` interface declares: `Future<bool> upsertCoverFact(...)`,
  `Future<bool> upsertLaborPunch(...)`, `Future<bool> upsertReservationFact(...)`,
  `Future<void> advanceWatermark(...)`, `Future<void> appendSyncLog(...)`,
  `Future<void> evaluateDemoFlip(...)`. Per-vendor sinks compose on
  this.

**Tests required.**

- Registry binds 17 adapters by `vendorId`; missing adapter returns
  null + logs.
- Sync worker dispatches one tick per `connected` connection;
  watermark advances after each batch.
- Webhook router calls `handleWebhook` on the registered adapter,
  not on others.
- Banned-items grep: registry / worker source contains zero banned
  items per `project_v1_lean_cut_2_2026_05_03.md`.

### `8.spine-bridge.1.OR` — Oracle MICROS Simphony Postgres sink

**Files NEW.**

- `lib/infrastructure/persistence/postgres/oracle_micros_simphony_postgres_sink.dart`
- `test/infrastructure/persistence/postgres/oracle_micros_simphony_postgres_sink_test.dart`

**Contract bindings.**

- Implements `OracleMicrosSimphonyCanonicalSink` (existing) AND
  `CanonicalSink` (from `.0`).
- Writes canonical fact dicts to operator-scoped Postgres
  `cover_facts` rows via `OperatorScopedRepository.withTenant`.
- Idempotency UNIQUE on `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`
  per the framework migration.
- raw_payload column populated.
- DemoModeFlipPolicy.evaluateFlip invoked on first commit with
  records >= 1; Postgres `demo_mode_state` row updated.

**Tests required.**

- Round-trip canonical fact dict → Postgres row → re-read dict.
- Idempotency replay: same dict twice → 1 INSERT + 1 conflict-do-nothing.
- Watermark advance after batch.
- Demo-mode flip on first batch with records >= 1; idempotent on
  second flip.
- RLS enforcement: write under operator A's tenant cannot be read
  under operator B's tenant.

### `8.spine-bridge.1.QBT` — QuickBooks Time Postgres sink

Same shape as `.1.OR`. Files NEW:

- `lib/infrastructure/persistence/postgres/quickbooks_time_postgres_sink.dart`
- `test/infrastructure/persistence/postgres/quickbooks_time_postgres_sink_test.dart`

Writes to `labor_punches` instead of `cover_facts`. Module
disambiguation respected: only writes when adapter accepted module =
`time`.

### `8.spine-bridge.1.LB` — Libro Postgres sink

Same shape as `.1.OR`. Files NEW:

- `lib/infrastructure/persistence/postgres/libro_postgres_sink.dart`
- `test/infrastructure/persistence/postgres/libro_postgres_sink_test.dart`

Writes to `reservation_facts`. Webhook + poll inputs both supported
(Libro has autoRegister webhooks).

### `8.spine-bridge.A` — Data Accuracy schema + per-location settings repository

**Files NEW.**

- `db/migrations/<YYYYMMDD>_phase_8_data_accuracy_settings.sql` —
  creates `data_accuracy_settings`, `data_accuracy_service_period_settings`,
  and `forge_flow_polling_tier_assignment` tables per
  `data_accuracy_settings_contract.md` schema section.
- `lib/services/data_accuracy/data_accuracy_settings_repository.dart` —
  read/write seam over the new table. RLS-scoped via
  `OperatorScopedRepository.withTenant`.
- `lib/domain/models/data_accuracy_settings.dart` — typed shape.
- `test/services/data_accuracy/data_accuracy_settings_repository_test.dart`.
- `test/domain/models/data_accuracy_settings_test.dart`.

**Contract bindings.**

- Schema honors RLS-Ready Schema rules
  (`hardening_rls_and_repository_pattern_contract.md`): per-tenant on
  `(operator_id, location_id)`; B-tree index leads with `operator_id`;
  4 wrapper-only RLS policies.
- Schema columns per `data_accuracy_settings_contract.md` (REVERSED
  2026-05-05 and amended 2026-05-06 — operator-cadence-override columns
  NOT shipped; F&F controls cadence via
  `forge_flow_polling_tier_assignment`; covers source is keyed by
  service period):
    * `data_accuracy_settings`: wage_source (enum: vendor / manual_mix)
      plus audit metadata.
    * `data_accuracy_service_period_settings`: service_period_key,
      covers_source (enum: vendor / forecast / manual), and
      covers_manual_entries (jsonb: per-business-date sparse map).
    * `forge_flow_polling_tier_assignment` (NEW table):
      tier_key (enum: standard / premium / custom);
      polling_cadence_per_vendor_seconds (jsonb);
      monthly_price_cents; vendor_api_cost_estimate_cents_monthly;
      effective_at / effective_until / assigned_by_admin_user_id.
      One CURRENTLY-EFFECTIVE row per (operator, location) via
      partial unique index `WHERE effective_until IS NULL`. RLS
      policy admits `service_role` (read-only) +
      `forge_admin` (read/write).
- Repository: `DataAccuracySettingsRepository` — idempotent upsert
  on (operator_id, location_id); per-service-period partial updates
  supported. `ForgeFlowPollingTierRepository` — readCurrentAssignment
  / assignTier (closes prior current row + inserts new in single tx)
  / listAssignmentHistory / summarizeMargin.

**Tests required.**

- A. RLS round-trip: operator A write isolated from operator B reads.
- B. Per-service-period partial update: writing one `service_period_key`
  to manual does not affect another key.
- C. Polling tier assignment JSON validation: invalid vendor id ->
  rejection at repository boundary.
- D. Banned-items grep.

### `8.spine-bridge.B` — Operator Web Console: Data Accuracy tab

**Files NEW.**

- `lib/operator_web/screens/data_accuracy_screen.dart` — the new tab.
- `lib/operator_web/widgets/covers_source_toggle.dart` — per-service-period
  picker (vendor / forecast / manual).
- `lib/operator_web/widgets/covers_manual_entry_card.dart` —
  service-period-keyed manual entry per business date.
- `lib/operator_web/widgets/wage_source_toggle.dart` — surfaces the
  existing wage adjuster (currently in mobile Settings) on web.
- `lib/operator_web/widgets/polling_tier_request_card.dart` — display-only
  tier/cadence summary plus request-change flow.
- `lib/operator_web/widgets/vendor_relativity_label.dart` — labels each
  setting with the vendors it applies to (e.g., "covers manual entry
  applies to: Square, Clover").
- `test/operator_web/screens/data_accuracy_screen_test.dart`.
- `test/operator_web/widgets/covers_source_toggle_test.dart`.
- `test/operator_web/widgets/wage_source_toggle_test.dart`.
- `test/operator_web/widgets/polling_tier_request_card_test.dart`.

Files MODIFY:

- `lib/operator_web/router/operator_web_router.dart` — add the
  `/data-accuracy` nav id + route. (Single line addition; file-
  disjoint with all sibling lanes.)

**Contract bindings.**

- Reads/writes via the Lane `.A` repository.
- UX writing standard per `memory/project_ux_writing_standard.md` —
  every setting reads as if training the user.
- Vendor relativity labels per
  `data_accuracy_settings_contract.md` (covers settings apply to
  Square + Clover; wage settings apply to QBT + Humanity + Agendrix +
  any labor vendor not exposing dollars; polling cadence is display-only
  and applies only to poll-only vendors).
- No operator cadence picker. The polling card may request a tier change;
  actual cadence/cost/margin controls live in F&F Ops Console.

**Tests required.**

- A. Render with default settings (vendor source, no overrides).
- B. Toggle covers source from vendor -> manual; assert manual entry
  card appears for the configured service-period keys.
- C. Manual entry validates non-negative integers per service period.
- D. Wage source toggle round-trips with the repository.
- E. Polling tier card is display-only and surfaces request-change copy,
  not cadence controls or vendor cost projection.
- F. Vendor relativity label correctly names the affected vendors.
- G. Banned-items grep.

### `8.spine-bridge.C` — F&F Ops Console: per-location data accuracy admin surface

**Files NEW.**

- `lib/admin/screens/per_location_data_accuracy_screen.dart` — admin
  surface for support-driven adjustments + cross-operator visibility.
- `lib/admin/widgets/per_location_polling_cost_panel.dart` — cost
  rollup across all operator locations.
- `test/admin/screens/per_location_data_accuracy_screen_test.dart`.

Files MODIFY:

- `lib/admin/admin_router.dart` — add `/data-accuracy` admin route.
  (Single line addition; file-disjoint with all sibling lanes.)

**Contract bindings.**

- Admin surface per
  `data_accuracy_settings_contract.md` "F&F Ops Console" section.
- Reads via Lane `.A` repository under `forge_admin` role.
- Audit row written on every admin override per
  `auth_permission_key_catalog.md`.

**Tests required.**

- A. Render with multi-location operator.
- B. Admin override writes audit row.
- C. Cost panel rolls up across locations.
- D. Banned-items grep.

### `8.spine-bridge.0a` — Sync worker polling cadence resolver (additive after `.0` + `.A`)

**Files NEW.**

- `lib/services/integration/polling_cadence_resolver.dart` — pure
  logic that takes (vendor_id, ForgeFlowPollingTierAssignment?,
  vendor min, framework max, onSyncLog callback) and returns the
  resolved poll cadence in seconds.
- `lib/services/integration/polling_tier_presets.dart` —
  `kStandardTierPresets` + `kPremiumTierPresets` const maps + the
  `kFrameworkMaximumCadenceSeconds` constant.
- `db/migrations/202605050100_phase_8_0a_polling_event_kinds.sql` —
  extends `connector_sync_log.event_kind` CHECK constraint to admit
  the four resolver event kinds + closes a latent gap from `.0`
  (`vendor_not_registered` was emitted by the dispatcher but missing
  from the original CHECK).
- `test/services/integration/polling_cadence_resolver_test.dart`.
- `test/services/integration/polling_tier_presets_test.dart`.

Files MODIFY:

- `tool/integration_sync_worker/dispatch.dart` — adds two optional
  constructor lookups (`tierAssignmentLookup`,
  `vendorMinimumCadenceLookup`) + a single resolver call inside
  `dispatchPollTick` (placed in the trailing `finally` block so the
  resolver telemetry follows the poll outcome in the audit timeline).
  The call is gated three ways: both lookups must be wired, the
  vendor must be in `pollOnlyVendorIds` (webhook vendors get no
  cadence telemetry), and tier-lookup throws are caught + emit a
  `tier_assignment_lookup_failed` row instead of mis-tagging the
  failure as a `poll_error`. **No interface change to
  `dispatchPollTick`; default null lookups preserve Lane `.0`
  baseline.**

**Why this is additive (not stale-making for Lane `.0`):** Lane `.0`
ships with a hardcoded default cadence and no resolver wiring. Lane
`.0a` adds the resolver behind optional constructor lookups that
default to null. The running Lane `.0` worktree + tests do NOT need
to re-roll — they pass nothing and the resolver path stays inert.

**Tests required.**

- A. `tierAssignment == null` -> standard-tier presets used; resolver
  emits `tier_assignment_missing` sync_log row.
- B. JSONB override below vendor minimum -> clamped up; resolver
  emits `cadence_clamped` (`bound: vendor_minimum`).
- C. JSONB override within `[vendor_minimum, framework_maximum]` ->
  returned as-is; no log row.
- D. `tier_key='custom'` with vendor unset in JSONB -> vendor
  minimum returned; resolver emits `custom_tier_vendor_unset`.
- E. Oracle Simphony `vendor_minimum=300s`; assignment specifies 60s
  -> clamped to 300s (binding contract example).
- F. Banned-items grep across the two new lib files.

### `8.spine-bridge.2` — Server-side aggregator + ShiftRecord writer

**Files NEW.**

- `lib/services/integration/canonical_fact_to_closed_shift_input.dart`
- `lib/infrastructure/persistence/postgres/postgres_shift_record_writer.dart`
- `lib/services/integration/labor_wage_source_class.dart` — sidecar
  lookup keyed by `vendorId` returning the wage source class enum
  `{ perEmployeeWithDollars, perPositionWithRates, hoursOnly,
    noLaborData }`. NOT a modification to the frozen
  `integration_adapter_common.dart` capability profile; the lookup
  preserves Wave B file-disjoint guarantees.
- `lib/domain/models/aggregator_provenance_context.dart`
- `test/services/integration/canonical_fact_to_closed_shift_input_test.dart`
- `test/services/integration/labor_wage_source_class_test.dart`
- `test/infrastructure/persistence/postgres/postgres_shift_record_writer_test.dart`
- `test/domain/models/aggregator_provenance_context_test.dart`

**Contract bindings.**

- Aggregator walks operator-scoped Postgres `cover_facts` +
  `labor_punches` + `reservation_facts` for
  `(operator_id, location_id, business_date, service_period_key)`.
- Resolves `service_period_key` per the effective
  `business_timing_profiles` / `business_timing_service_periods` snapshot.
  `restaurant_timing_configs` is a mobile/read-model projection, not the
  server source of truth.
- **Reads `data_accuracy_settings` via Lane `.A` repository** for the
  (operator, location) and `data_accuracy_service_period_settings` for the
  stable service_period_key — covers source preference per service period
  and wage source preference. Polling cadence comes from the F&F tier
  resolver, not this row.
- Resolves covers source via 4-way decision (per Concern B + Layer 6
  in `core_app_architecture.md`):
    * `operator_manual_entry_per_daypart` -> use the manual value;
      provenance string = `operator_manual_entry_per_daypart`.
    * `vendor_<id>` -> use vendor canonical fact rows; provenance =
      `vendor_<id>` (live).
    * `vendor_<id>_covers_unavailable_app_forecast_substituted` ->
      use F&F-derived forecast covers from
      `DemandForecastContext.resolvedWeeklyForecastCovers` allocated
      to this service period per the business-timing split rule; provenance
      string makes vendor-unavailable + F&F-substituted explicit.
    * No source available -> aggregator returns null; no ShiftRecord
      written; dashboard renders MetricCardNotYetAvailable.
- Resolves labor dollars source via 3-way decision (per
  metric honesty contract):
    * `target_wage_substituted` (operator wage source = manual mix) ->
      use operator-set wage_role_rows mix.
    * `vendor_<id>` -> use vendor canonical fact rows.
    * `vendor_<id>_dollars_unavailable_target_wage_substituted` ->
      use target wage × hours from active TargetSnapshot.
- Emits `ClosedShiftInput` matching the existing typed shape, plus a
  sibling `ProvenanceContext` carrying the per-metric provenance
  strings the writer attaches to ShiftRecord. The emitted row must also
  carry the timing profile/version id and `service_period_key` used for
  bucketing, so closed history survives later timing label changes or
  overrides.
- Aggregator returns `priorTargetProfileVersionId`: the
  `target_profile_version_id` of the prior ShiftRecord at this slot if
  one exists; null if first-time aggregation.
- Calls existing `ShiftFactBuilder.fromClosedShiftInput` (pure).
- Persists `ShiftFact → ShiftRecord` row to operator-scoped Postgres
  `shift_records` via `OperatorScopedRepository.withTenant`.
- `sourceSystem` = vendor_id of the dominant POS source (one of the
  17 vendor ids), OR `operator_manual_entry` when covers source =
  manual.
- **Concern A (binding):** Replace-for-slot semantics — re-aggregation
  overwrites the prior `ShiftRecord` for the same
  `(operator_id, location_id, business_date, service_period_key)` AND
  **preserves the prior `target_profile_version_id` and timing provenance**
  when the aggregator's prior row is non-null. Only first-time aggregations
  mint a fresh `TargetProfileVersion`; timing labels may update in future
  rows but closed rows keep the profile/version/key captured at bucket time.
  This is a hard rule that protects `core_app_architecture.md` Layer 4 +
  Layer 11 + Layer 12 + the "What never rewrites" non-negotiables.

**Tests required.**

- A. Single-vendor trio (Oracle + QBT + Libro): canonical-fact dicts in
  → ShiftRecord written with correct numeric values.
- B. Multi-vendor merge: same service period fed by two POS adapters fails
  loudly (one POS source per service period per V1 contract).
- C. Covers source = vendor when POS adapter exposed covers (Toast).
- D. Covers source = forecast substitution when POS adapter declared
  `coversFieldExposed = false` (Square); provenance string =
  `vendor_square_covers_unavailable_app_forecast_substituted`.
- E. Covers source = manual entry when DataAccuracySettings has
  `service_period_key='dinner'` has covers_source == 'manual' AND
  `covers_manual_entries['2026-05-04'] == 187`; assert
  ShiftRecord.covers == 187; provenance = `operator_manual_entry_per_daypart`.
- F. Labor dollars source = vendor when labor adapter populated
  `actual_foh_labor_dollars` AND wage source preference = vendor.
- G. Labor dollars source = target wage substitution when adapter did
  not populate dollars; provenance =
  `vendor_<id>_dollars_unavailable_target_wage_substituted`.
- H. Labor dollars source = manual mix when wage source preference =
  manual_mix; provenance = `target_wage_substituted` using operator-
  set wage_role_rows mix.
- I. **Concern A test (target_profile_version_id preservation).**
  First-time aggregation writes ShiftRecord with target_profile_version_id="tpv_X".
  Re-aggregation after a timing label/profile edit preserves the prior
  target profile id plus the closed row's timing profile/version id and
  service_period_key.
  TargetCycle rolls; ActiveTargetProfile points at "tpv_Y". Corrected
  vendor fact arrives; aggregator re-runs; assert: aggregator returns
  `priorTargetProfileVersionId == "tpv_X"`; writer reuses "tpv_X" on
  the overwrite, NOT "tpv_Y"; re-read row carries "tpv_X".
- J. Re-aggregation idempotent: same input set twice → same output row.
- K. Banned-items grep.

### `8.spine-bridge.3` — Server→mobile ShiftRecord sync

**Files NEW.**

- `lib/services/sync/postgres_shift_record_to_mobile_sync.dart`
- `test/services/sync/postgres_shift_record_to_mobile_sync_test.dart`
- (Optional, defer if scope permits) `lib/infrastructure/persistence/sqlite/sqlite_database_migrations.dart`
  edit adding migration vN+1 for vendor provenance columns on mobile
  `shift_records`.

**Contract bindings.**

- Pulls `ShiftRecord` rows from server via proxy
  `GET /v1/operators/<op>/locations/<loc>/shift_records?modified_since=<cursor>`.
- Bounded pull (max N rows per page; cursor advance per page).
- Writes to mobile SQLite `shift_records` via existing
  `SqliteShiftRecordRepository.replaceShiftForSlot`.
- `sourceSystem` carries vendor_id (live) or `"demo"` (demo path).
- Fires `AppRuntimeInvalidationBus.notifyRuntimeWriteCompleted` per
  ShiftRecord write so dashboard / variance / history refresh.
- Idempotent on `(restaurant_id, week_id, day_label, daypart)` —
  matches existing replace-for-slot contract.
- Pulls `demo_mode_state` rows in the same sweep so the operator app
  sees the flip without redeploy.

**Tests required.**

- Server-side fixture rows pull → mobile SQLite row written → DAO
  read returns the row.
- Cursor advance: second pull only fetches rows modified after the
  cursor.
- Replace-for-slot: re-pulling the same `(week_id, day_label, daypart)`
  overwrites the prior row.
- Refresh signal: `AppRuntimeInvalidationBus` notification observed
  per write.
- Demo-mode flip propagation: server-side `demo_mode_state.is_demo = false`
  → mobile sees the flip on next sync sweep.

### `8.integration-mobile-proof.v2` — Re-run (sequential after 1-6 land)

Same lane shape as the 2026-05-04 proof. Now exercises the full
chain:

```
fixture vendor payload
  → Wave B adapter
  → Postgres-backed CanonicalSink (.1.*)
  → operator-scoped Postgres canonical fact rows
  → aggregator + PostgresShiftRecordWriter (.2)
  → operator-scoped Postgres shift_records
  → server→mobile sync (.3)
  → mobile SQLite shift_records
  → ShiftService.getShiftDashboard
  → dashboard / variance / history / learn / metric honesty pill
  → demo-mode banner clears
```

PASS criterion: every one of the 12 acceptance items in the original
mobile-proof prompt resolves to ✅. Below ✅: declare a follow-up.

## File-disjoint guarantee

| Lane | NEW files | MODIFY files |
|---|---|---|
| `.0` | 6 (registry × 3 + worker × 2 + sink interface × 1) | 0 |
| `.1.OR` | 2 (sink + test) | 0 |
| `.1.QBT` | 2 | 0 |
| `.1.LB` | 2 | 0 |
| `.2` | 4 (aggregator + writer + tests) | 0 |
| `.3` | 2-3 (sync service + test + optional SQLite migration) | 0-2 (DAO edits if vendor columns parity) |

`.3` is the only lane that may modify existing files
(`sqlite_database_migrations.dart` + DAO edits). The decision to
include or defer SQLite vendor-column parity is a sub-lane scope
question — the V1 spine does not require it. Default: defer; ship
parity in a follow-up if and when raw-fact drilldowns are needed on
mobile.

## Banned items (V1 lean cut 2 — REJECT if present)

Same banned list as `vendor_adapter_slice_contract.md` Section "Banned
items" applies to every spine-bridge file. In particular:

- No KMS / production-key rotation logic in any sink.
- No `parse_warnings` / `parse_partial` columns on canonical fact
  tables.
- No 5-minute strict replay window.
- OAuth advisory locks: SANCTIONED, narrowly, for the OAuth refresh
  cron only. The original V1-lean-cut-2 ban is superseded by the
  operator-approved J4 B2 race fix: two Cloud Run pods scanning the
  same near-expiry token window both call the vendor token endpoint,
  and some vendors auto-revoke the earlier token, 401-ing the first
  pod. The fix wraps the per-`(operator_id, vendor_id)` refresh in a
  transaction-scoped `pg_advisory_xact_lock` (lock id `8472002`,
  seeded by `db/migrations/202605080900_oauth_refresh_advisory_lock.sql`;
  acquired in `lib/services/integration/oauth_refresh_cron.dart`).
  Scope is strict: advisory locks remain REJECTED everywhere else in
  the spine-bridge sinks; only the OAuth refresh cron's per-vendor
  serialization is allowed, and only as a transaction-scoped lock
  (auto-released on commit or rollback, no explicit unlock).
- No SIGTERM graceful drain handler.
- No DLQ tile widget.
- No raw-payload sibling tables / pg_partman registration.
- No 5-second test-connection SLA.

## Acceptance verdicts

Same shape as `vendor_adapter_slice_contract.md`:

- **ACCEPT** — every sub-lane's `Tests required` section passes;
  zero banned items; file-disjoint guarantee honored; canonical
  chain stages bound exactly to this contract.
- **FOLLOW-UP NEEDED** — bounded miss (e.g. one test absent; one
  contract binding skipped).
- **REJECT** — sink bypasses `OperatorScopedRepository`; aggregator
  emits a `ShiftRecord` for an operator without their tenant context;
  mobile sync writes outside `replace-for-slot` semantics; demo-mode
  flip auto-reverts.

## Cross-references

- `docs/contracts/vendor_adapter_slice_contract.md` — left-half rules
- `docs/contracts/per_vendor_doc_pack_contract.md` — per-vendor folder
- `docs/contracts/metric_card_honesty_contract.md` — renderer chrome
- `docs/contracts/phase_7_55_time_boundary_contract.md` — UTC + business_date
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` — RLS pattern
- `docs/archive/_execution/2026-05-04_8_integration_mobile_proof_execution.md` — origin proof + SQLite addendum
- `docs/archive/_execution/2026-05-04_vendor_api_access_and_mobile_e2e_gap.md` — gap memo
- `memory/project_phase_8_engineer_all_17_doctrine.md` — Wave B doctrine
- `memory/project_v1_lean_cut_2_2026_05_03.md` — banned items list
