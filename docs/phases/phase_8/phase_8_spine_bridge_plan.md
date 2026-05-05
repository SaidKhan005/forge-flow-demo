# Phase 8 — Spine Bridge Plan

Status: Active
Updated: 2026-05-04
Owner: Phase 8 / 8R / 8.S spine-bridge sprint

Authority (read in this order):

1. `docs/contracts/core_app_architecture.md` — Layer 1–12 binding rules
2. `docs/contracts/integration_spine_architecture_contract.md` — sprint binding
3. `docs/contracts/data_accuracy_settings_contract.md` — operator-controlled accuracy seams
4. `docs/contracts/metric_card_honesty_contract.md` — metric state + provenance
5. `docs/contracts/vendor_adapter_slice_contract.md` — Wave B left-half rules
6. `docs/_execution/2026-05-04_8_integration_mobile_proof_execution.md` — origin proof + SQLite addendum
7. `memory/handoff_prompt_next_wave_sprint.md` — reusable sprint generator

## Sprint shape

**10 file-disjoint sub-lanes + 1 sequential proof** (was 9 before
the 2026-05-05 7shifts-upgrade addition).

Lane `.0` ships first. Lanes `.0a` / `.1.OR` / `.1.QBT` / `.1.LB` /
`.2` / `.3` / `.A` / `.B` / `.C` / `.7S.upgrade` run in parallel after
`.0` lands. Lane `.4` proof runs sequentially after all 10 land.

Plus an immediate follow-up wave:

**`8.spine-bridge-sink-fanout`** — 14 file-disjoint Postgres-backed
sink lanes for the remaining vendors (every Wave B vendor not in the
trio). Mirrors Wave B's engineer-all-17 shape. Lands right after
`mobile-proof.v2` passes; doesn't grow the proof gate.

## Sub-lanes

| Lane | Status | Files NEW | Owns |
|---|---|---|---|
| `.0` Seam definition | RUNNING (worktree); awaiting amendment | `tool/advisor_proxy/{pos,labor,reservation}_adapter_registry.dart`, `tool/integration_sync_worker/{main,dispatch}.dart`, `lib/services/integration/canonical_sink.dart` | Adapter registry binding 17 Wave B adapters; sync worker dispatch; unified CanonicalSink interface |
| `.0a` Polling cadence resolver (additive) | Queued | `lib/services/integration/polling_cadence_resolver.dart` + test | Per-(operator, location, vendor) cadence override read from `.A`; clamp to vendor min/max; default 60s when no override; sync log on clamp/unack |
| `.1.OR` Oracle Simphony Postgres sink | Queued | `lib/infrastructure/persistence/postgres/oracle_micros_simphony_postgres_sink.dart` + test | Writes canonical-fact dict to `cover_facts` via `OperatorScopedRepository.withTenant`; idempotency UNIQUE; raw_payload; demo-flip on first batch |
| `.1.QBT` QuickBooks Time Postgres sink | Queued | `lib/infrastructure/persistence/postgres/quickbooks_time_postgres_sink.dart` + test | Writes to `labor_punches`; module disambiguation respected |
| `.1.LB` Libro Postgres sink | Queued | `lib/infrastructure/persistence/postgres/libro_postgres_sink.dart` + test | Writes to `reservation_facts`; webhook + poll inputs |
| `.2` Aggregator + ShiftRecord writer | Queued | `lib/services/integration/canonical_fact_to_closed_shift_input.dart`, `lib/infrastructure/persistence/postgres/postgres_shift_record_writer.dart`, `lib/services/integration/labor_wage_source_class.dart` (sidecar lookup), `lib/domain/models/aggregator_provenance_context.dart` + tests | 5-way covers resolution (manual / vendor / reservation+walk-in / forecast / unavailable); 4-way wage resolution (vendor per-employee / vendor per-position / target wage substitution / manual mix); `target_profile_version_id` preservation on re-aggregation |
| `.3` Server→mobile sync | Queued | `lib/services/sync/postgres_shift_record_to_mobile_sync.dart`, `lib/services/sync/sync_proxy_client.dart` + test | Pull `ShiftRecord` rows via proxy; write via existing `SqliteShiftRecordRepository.replaceShiftForSlot`; fire `AppRuntimeInvalidationBus.notifyRuntimeWriteCompleted`; pull `demo_mode_state` + `data_accuracy_settings` in same sweep |
| `.A` Data Accuracy schema + repository | Queued | Migration + `lib/services/data_accuracy/data_accuracy_settings_repository.dart` + `lib/domain/models/data_accuracy_settings.dart` + tests | Schema per `data_accuracy_settings_contract.md`; RLS-scoped repository; consumed by `.0a` / `.2` / `.B` / `.C` |
| `.B` Operator Web Data Accuracy tab | Queued | `lib/operator_web/screens/data_accuracy_screen.dart` + 7 widgets + tests + walkthrough | Wage source toggle (vendor / manual_mix); covers source toggle per daypart (vendor / forecast / manual / reservation+walk-in); polling cadence picker with cost projection; 60-day historical seed; walk-in handling card; vendor relativity labels |
| `.C` F&F Ops Console per-location data accuracy + Polling & Pricing | Queued; **scope expanded 2026-05-05** | `lib/admin/screens/per_location_data_accuracy_screen.dart` + `lib/admin/screens/polling_and_pricing_admin_screen.dart` + 8 widgets + tests + walkthrough | Two-tab admin: Data Accuracy (per-location overrides) + Polling & Pricing (tier definitions / per-assignment / margin rollup / change requests / audit). All forge_admin-gated. Plain-English explainer card per `data_accuracy_settings_contract.md` "Polling & Pricing tab" section. Audit row on every change. |
| `.7S.upgrade` (NEW 2026-05-05; per-vendor adapter capability extension) | Queued | edits to `lib/integrations/labor/seven_shifts_labor_adapter.dart` + new tests + `docs/integrations/seven_shifts/{api_consumed,field_mapping}.md` updates | Adds `/reports/hours_and_wages` endpoint consumption to the 7shifts adapter so it qualifies as `perEmployeeWithDollars` (vendor exposes `total_pay` per shift via this report). Enables the highest-fidelity wage class for 7shifts operators. File-scope: only seven_shifts adapter + its doc pack + its tests. |
| `.4` Proof v2 (sequential) | Queued | `docs/_execution/<date>_8_integration_mobile_proof_v2_execution.md` + E2E harness | Re-run mobile-proof against complete spine; verify all 22 acceptance items (12 v1 + 10 added by spine-bridge concerns) |

## 2026-05-05 falsehood corrections (binding) — supersedes 2026-05-04

Vendor research completed 2026-05-05. Authority:
`integration_spine_architecture_contract.md` "2026-05-05 falsehood
corrections" section. Summary:

- ADP webhook (autoRegister, not pollOnly) ✅
- Square `coversFieldExposed: false` ✅ CORRECT — UI tracks; API does not expose
- Clover `coversFieldExposed: false` ✅ CORRECT — Dining App private schema not reachable via public REST API
- Aloha `coversFieldExposed: true` ⚠️ likely tri-state in reality; flip to false until live verifies OR adopt enum
- **Oracle Simphony field path WRONG** — `items[].header.guestCount` (Gen2), not `numOfGst` (Gen1) or `numberOfGuests` (adapter constant guess)
- QuickBooks Time wage class → `perEmployeeWithRates` (not `perEmployeeWithDollars`)
- 7shifts wage class → `perEmployeeWithRates` today; `perEmployeeWithDollars` only IFF `/reports/hours_and_wages` adopted
- ADP wage class V1 → `hoursOnly` (Wave B explicitly defers wage ingestion)
- Push Operations wage class → `hoursOnly` (zero wage rows in current Wave B mapping)
- Tock seated_at REFUTED — only 3 reservation timestamps documented; aggregator must handle Tock without Pattern A's seated-time confirmation
- `target_profile_version_id` preservation rule was already in contracts; not a new rule
- Layer count is 13 (5A is its own sub-layer)

The earlier "tri-state configurable" framing for Square + Clover is
DEAD. Both vendors are firmly `never` per their public APIs.

## Polling cadence is F&F-controlled (REVERSED 2026-05-05)

Earlier drafts framed polling as a pure cost pass-through with
operator-controlled cadence per vendor. That framing is REPLACED.

**F&F controls polling cadence per (operator, location) via tier
assignment.** F&F absorbs vendor API costs into its own tier pricing.
Operators see tier names + tier prices, not vendor per-call costs.

Lane `.A` schema gains a new
`forge_flow_polling_tier_assignment` table (per-(operator, location)
tier row + per-vendor cadence JSONB + F&F price + internal cost
basis). Lane `.B` polling card becomes display-only +
request-tier-change ticket flow. Lane `.C` admin surface gains
tier-assignment + cost-rollup with margin view. Lane `.0a` resolver
reads from the tier assignment table, NOT operator overrides.

## Out of scope (binding)

- `OpenShiftSnapshot` / live in-progress canonical fact wiring →
  follow-up sprint `8.spine-bridge-live`
- `ReservationBookSnapshot` mid-service updates → same follow-up
- Wage editor "review/override" UX for per-position vendors →
  follow-up sprint `8.wage-editor-seed`
- Walk-in model calibration from operator confirmations →
  follow-up sprint `8.walk-in-model-calibration` (Phase 8R territory)
- Mobile SQLite vendor-column parity → defer unless raw-fact
  drilldowns are needed on mobile

## Cross-references

- Adapter registry merge → Lane `.0`
- Sub-lane prompts → memory/handoff_prompt_next_wave_sprint.md
- Wave B doctrine → memory/project_phase_8_engineer_all_17_doctrine.md
- V1 lean cut 2 banned items → memory/project_v1_lean_cut_2_2026_05_03.md
