# Forge & Flow Project Tracker

Updated: 2026-04-25
Owner: You
Execution model: We think, Claude codes

## Active Authority

- `PROJECT_TRACKER.md`
- `docs/DATA_ALIGNMENT_TRACKER.md` when the slice is alignment-heavy
- explicitly referenced active phase docs

Archive:
- `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`
- `docs/archive/trackers/PROJECT_TRACKER_FULL_2026-04-12_PRE_TRIM.md`
- `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_FULL_2026-04-10.md`

## North Star

POS + Labor + Reservation Systems -> Canonical Operational Facts -> 60-Day Benchmark Snapshot -> TargetCycle + DemandForecastContext -> SchedulePlan -> WeeklyPlanSnapshot -> Shift -> Variance -> History -> Learn

## Active Focus

- Current phase: `7.57` Stabilization (paused 11a at `11a.7`). **Five
  slices** land before 11a resumes:
  - `7.57.0` rules
  - `7.57.1` legacy fixture extraction
  - `7.57.2` `lib/data/` consolidation sweep
  - `7.57.3` provider abstraction (Embedding + Rerank + Answer +
    DataSource; tiered Sonnet/Haiku locked into Answer interface)
  - `7.57.4` AGE graph projection
- Next slice prompt for Codex to generate: **`7.57.0`** per
  `docs/CODEX_PROMPT_GENERATION_STANDARD.md`. The original next 11a slice
  (vector search functions / indexes + smoke queries) is paused until
  all five `7.57` slices accept.
- Active planning input: `docs/phases/post_11a7_stabilization_plan.md`.
  Single source of truth for 26 concerns surfaced across the 2026-04-25
  planning rounds, each mapped to a slot. Includes the 5-slice `7.58`
  behavioral alignment lane (pre-11b) and the 4-slice `7.61` freshness
  audit lane (pre-Phase-8).
- Last accepted prompt: `11a.7` executed local Voyage `voyage-4-large`
  embeddings for all 233 advisor chunks and loaded them into the local
  Supabase/Postgres container.
- Build cadence: **sequential, not parallel.** Sequence is explicit in
  Current And Next.
- Prompt sequencing: automatic Codex loop per
  `docs/CODEX_PROMPT_GENERATION_STANDARD.md`; after an accepted slice,
  verify repo truth, update trackers, then generate the next prompt
  from the updated tracker state.
- Current UX / extraction state: the broad header / shell / Learn /
  Settings / Plan / Benchmark / Variance visual pass is landed, and
  `7.55o` structural extraction is complete through SQLite bootstrap
  breakup.
- Current live-integration scope: one restaurant/location, not
  multi-location org management.
- Naming guardrail: keep internal `Baseline` / `Schedule` names
  unchanged through `7.57` and Phase 8 itself.

## Phase Summary

| Phase | Status | Summary |
| --- | --- | --- |
| `7.55l` | complete | `TargetCycle` + `WeeklyPlanSnapshot` runtime architecture landed |
| `7.55m` | complete | runtime-truth cleanup landed |
| `7.55k` | complete | daypart / Variance / History / Learn plan landed through `7.55k.8a` |
| `7.55n` | complete | restaurant timing + service-period runtime foundation landed through `7.55n.6a`; freshness / live-data extension landed through `7.55n.13` |
| `7.55p.1` | complete | Shift driver trust audit landed against Chapter 10 |
| `7.55p.2` | complete | Variance WTD target alignment and Full Week target-package / carry-forward cleanup landed through `7.55p.2a` |
| `7.55p.3` | complete | Dollar Impact accumulation model landed through `7.55p.3a` |
| `7.55p.4a` | complete | app-owned refresh / invalidation policy landed through `7.55p.4a1` |
| `7.55p.4b` | complete | connector-fed live freshness propagation landed through `7.55p.4b1` |
| `7.55p.4c` | complete | replay integrity / mock-to-live transition audit landed through `7.55p.4c1` |
| `7.55p.4d` | complete | persisted passive notifications landed through `7.55p.4d1` |
| `7.55p.5` | complete | Benchmark OPZ / graph honesty audit, OPZ-width research, target-labor package contract, Variance theoretical-package verification, blended-wage audit, recommendation-statistics contract cleanup, wage-mix setup UX, the app-owned recommended benchmark selection service, its restaurant-scope runtime fix, the Benchmark graph fallback/explainer cleanup, and the scope-aware planned labor package contract + wiring landed through `7.55p.5j` |
| `7.55q` | complete | architecture-conformance lane landed through `7.55q.10`: single-plan / single-benchmark-target contract codified, non-closed Variance rewired 1:1, History restored to preserved locked-target truth, planned labor killed, whole-day Shift target alignment formalized, post-q authority/test hygiene synced, cycle-backed Benchmark override wiring landed, and Dollar Impact card unified with frozen-at-close parity between live Variance and Week Detail (SQLite v22 migration, `monthDollarImpact` / `sixtyDayDollarImpact` / `closedAt` on `WeekRecord`, shared `DollarImpactCard` widget) |
| `7.55o` | complete | shared-surface extraction / shell split lane completed through `7.55o.6`: shared comparison primitives, Variance shell split, Schedule planning separation, Settings surface split, Baseline Manager decomposition, and SQLite schema / seed / migration breakup accepted |
| `7.55r` | complete | bounded foundation closeout completed through `7.55r.2`: dev-only audit read service + drift flags + locked-week / target-cycle provenance readout landed, UTC metadata and non-locked WTD audits closed, and service-period runtime wiring verified with no production patch target |
| `7.56` | complete | reservation-book signal verified complete in `7.56a`; `7.56b` closed the pre-existing target-cycle `benchmark_selection_summaries` replay-stability failure; `7.56c.0` plus the projection-sales and target-hour field follow-ups aligned Full Week Plan / Benchmark authority, and `7.56c.1` expanded the dev-only audit into a full live / actual + Plan / Benchmark source-alignment monitor (grouped audit checks across 5 groups, 9 q-lane checks preserved) |
| `11a` | active (paused at `11a.7`) | advisor infrastructure landed through `11a.7`: active Markdown corpus location locked at `docs/Knowledge_graph_docs`, manifest authority added, `The Empty Apron` excluded, global/shared methodology scope recorded, local validator + chunk-plan dry run landed, deterministic build-only ingestion records now emit source document / source chunk / graph node seed / graph edge hint JSONL, Supabase/Postgres schema scaffold landed for those record families, deterministic build-only SQL load prep emits ordered upsert files plus a load manifest, the corpus loads into a local Supabase Postgres container with verified counts (8 docs / 233 chunks / 241 node seeds / 233 edge hints), the first retrieval contract is revised to the Claude-aligned lane: future Claude/Anthropic advisor answers plus Voyage `voyage-4-large` retrieval embeddings at `vector(1024)` and Voyage `rerank-2.5` post-vector candidate reranking with dry-run job artifacts, and local Voyage embeddings are now generated and loaded for all 233 chunks. **Paused for `7.57` stabilization phase**; resumes as `11a.8` (vector search functions / indexes + smoke queries) once `7.57.2` accepts. Rerank calls, MCP tools, and cloud DB apply remain future 11a slices after resume. |
| `7.57` | active (next prompt: `7.57.0`) | stabilization phase between `11a.7` and `11a.8`, addressing all 26 concerns from the 2026-04-25 planning rounds. **Five sub-slices, in order:** `7.57.0` codifies post-critique rules in `CLAUDE.md` (service-layer split, RLS-ready schema, phase doc hygiene) and the five hard architectural promises (Phase 8 = pure swap; demo mode persists forever; no app logic changes before `7.58`; per-operator isolation; AGE before 11b). `7.57.1` extracts `legacy_fixture_data.dart` from ~31 production importers (constants → `lib/data/app_defaults.dart`; sample data → SQLite seed pipeline driven by `mock_integration_replay_seed.dart` behind `kDemoMode`; misuse importers → real read service calls). `7.57.2` consolidates `lib/data/` per the layer-split rule. `7.57.3` introduces `EmbeddingProvider` / `RerankProvider` / `AdvisorAnswerProvider` (with tiered Sonnet/Haiku via `tier` param) / `DataSourceProvider` (covering 5 importers of `mock_integration_replay_seed.dart`). `7.57.4` implements Apache AGE graph projection in the local Supabase/Postgres container. Authoritative plan: `docs/phases/post_11a7_stabilization_plan.md`. |
| `7.58` | queued | pre-11b behavioral alignment lane. **Five sub-slices:** `7.58.0` Primary Driver decision logic audit (whole-day; 10.5 owns the daypart version separately); `7.58.1` Dollar Impact math + per-shift → per-year accumulation audit; `7.58.2` History/Learn identity decomposition (kill redundancy); `7.58.3` History coverage decision (8 weeks vs 60 days); `7.58.4` Fixture realism audit (wages, cover/sales/PPA consistency, weekday/weekend curves). **Gate:** opens after `9.5` closes; closes before `11b.0` opens. Output: behavior contracts grounded for the advisor. **First lane that explicitly decides on existing app logic** — every prior slice is structural-only or additive. |
| `7.61` | queued | pre-Phase-8 freshness audit. **Four sub-slices:** `7.61.0` per-screen freshness contract (Shift, Plan, Schedule, Variance, History, Learn, Settings); `7.61.1` Plan empties-then-populates investigation + fix (single-source-of-truth); `7.61.2` swipe-down refresh policy decision; `7.61.3` Day/date/shift truth display contract for Shift header. **Gate:** opens after `10b` closes; closes before Phase 8 opens. After `7.61` closes, freshness behavior is contract-stable; Phase 8 then adds vendor connector writers against the same SQLite tables — pure transport swap, no architectural cleanup, no freshness behavior change. |

## Current And Next

- Current:
  - `7.57` Stabilization is the active phase. The next slice prompt is
    `7.57.0`, generated by Codex from
    `docs/phases/post_11a7_stabilization_plan.md`.
  - `11a.7` is the last accepted advisor-infrastructure slice: corpus
    manifest, ingestion contract, validator, chunk planner, deterministic
    build-only materializer, Supabase/Postgres schema scaffold,
    deterministic build-only SQL load-prep artifacts, local Supabase
    Postgres load verification, dry-run Voyage embedding job preparation,
    guarded `execute-embeddings`, and local DB embedding load are landed;
    the planned retrieval path is pgvector cosine candidates → Voyage
    `rerank-2.5` → Claude answer runtime with citations.
  - 11a is paused; resumes as `11a.8` (vector search functions / indexes
    + smoke queries) once `7.57.2` accepts. Cloud DB apply, rerank
    calls, MCP tools, and UX were never started.
  - active corpus root is `docs/Knowledge_graph_docs`.
  - `docs/Knowledge_graph_docs/corpus_manifest.yaml` is the ingestion
    authority; directory scans alone are not permission to ingest.

- Pre-launch Sequence (sequential, not parallel):
  ```
  [7.57 NOW]  rules + fixture extraction + lib/data sweep
              + provider abstraction + AGE projection
     -> 11a (resume: 11a.8 vector search [HNSW] -> rerank -> MCP
             [token budget] -> cloud apply [embed regen policy])
     -> 9.8 -> 9 -> 10a -> 10.5 -> 9.5
     -> [7.58]  pre-11b behavioral alignment lane
                (Primary Driver / Dollar Impact / History+Learn
                identity / History coverage / Fixture realism)
     -> 11b (starts with 11b.0 advisor regression scaffold)
     -> 9.75 -> 11b.2 -> 10b
     -> [7.61]  pre-Phase-8 freshness audit
                (per-screen contract / Plan empties fix /
                swipe-down policy / day-date display)
     -> 8 (PURE transport swap, nothing else)
     -> 8R
  ```

- Hard Gates (enforced in this order):
  - `7.57.0` rules + five hard promises must accept before `7.57.1`.
  - `7.57.1` legacy fixture extraction must accept with **demo mode
    visually unchanged** before `7.57.2`.
  - `7.57.2` `lib/data/` sweep must accept before `7.57.3`.
  - `7.57.3` provider abstraction (with tiered Sonnet/Haiku) must
    accept before `7.57.4`.
  - `7.57.4` AGE graph projection must accept before `11a.8`
    resumes — and before `11b` ever starts.
  - `7.58` (all five sub-slices) must accept before `11b.0` opens.
    `7.58.0` is the first slice in the entire plan that decides on
    existing app logic; everything prior is structural-only or
    additive.
  - Phase 9 RLS must be real and tested before `11b` ships to
    multiple operators.
  - `7.61` (all four sub-slices) must accept before Phase 8 opens.
  - Phase 8 is a pure transport swap; if Phase 8 finds itself
    extracting a fixture, moving a service, or auditing freshness or
    behavior, that signals a `7.57` / `7.58` / `7.61` follow-up
    slice — not Phase 8 scope creep.

- Then (carry-forward truth and pre-launch context):
  - do not compare live operating results against targets as drift
    (`7.56c.1` design rule, retained going forward).
  - keep the landed UX shell pass recorded as done:
    - shared sticky/fading headers across core tabs
    - Shift header/live-time polish
    - Variance / History / Learn shell cleanup
    - Plan / Benchmark header-stat cleanup
    - Settings visual rework
  - revisit canonical live-facts contract planning after the bounded
    foundation closeout lane.
  - keep `7.55j.3` vendor endpoint checklist template and `7.55j.4` gap
    report as the active pre-Phase-8 vendor-readiness authority.
  - revisit `docs/internal/status_ledger_post_7_55p_deep_check.md`
    before any new pre-Phase-8 readiness answer.
  - keep pre-launch sequencing truth visible:
    - `Phase 10a` is pre-launch shared multi-device state and starts
      once `Phase 9` auth identity is usable.
    - `Phase 10.5` is additive whole-day + daypart Shift behavior and
      ships at or near launch.
    - `Phase 11a` + `11b` advisor work ships before `Phase 9.75`
      Barrio V1.1.
    - `Phase 10b` (full offline sync) sits between `11b.2` and Phase 8
      under the new sequential sequence.
  - keep the post-audit bounded cleanup list visible without reopening
    the landed q-lane contracts:
    - dev-only `DataAlignmentAuditPanel` cycle/week provenance readout
      landed in `7.55r.1`.
    - persisted timing/service-period wiring closeout verified / closed
      in `7.55r.2`.
    - UTC metadata timestamp normalization and non-locked WTD membership
      audit are already documented in `7.55r` as closed / no-patch
      findings.

## Active Guardrails

- **Build cadence is sequential, not parallel.** The remaining sequence
  is `[7.57] -> 11a (resume) -> 9.8 -> 9 -> 10a -> 10.5 -> 9.5 -> [7.58]
  -> 11b -> 9.75 -> 11b.2 -> 10b -> [7.61] -> 8 -> 8R`. Each phase lands
  on a stable predecessor.
- **Demo mode persists forever.** The `kDemoMode` flag stays available
  through every phase from `7.57` onward, **including post-launch**.
  `kDemoMode = true` → `mock_integration_replay_seed.dart` fills SQLite
  → screens render demo restaurant identical to today. `kDemoMode =
  false` → vendor connectors fill SQLite. Same tables, same read paths,
  same UI. The flag is a writer-side switch only.
- **Phase 8 is a pure transport swap.** All architectural cleanup
  lands in `7.57` (structural) and `7.61` (freshness) before Phase 8
  opens. Phase 8 only adds vendor connector writers implementing
  `DataSourceProvider` against existing SQLite tables. If Phase 8 finds
  itself extracting a fixture, moving a service, or auditing freshness
  or behavior, that signals a `7.57` / `7.58` / `7.61` follow-up slice.
- **No app logic changes before `7.58`.** Every slice from `7.57.0`
  through `9.5` close is one of: docs/governance, file moves,
  abstraction layers around existing behavior, or additive new
  capability. The first slice that decides on existing app logic is
  `7.58.0` (Primary Driver decision logic audit).
- **Per-operator data isolation is non-negotiable.** `11b` cannot ship
  to multiple operators until Phase 9 Row-Level Security is real and
  tested. RLS-ready schema (operator_id + policy stub) is required on
  every operator-scoped Postgres table from day one, not retrofitted in
  Phase 9.
- **11b cannot start until AGE graph projection (`7.57.4`) is verified
  green.** Vector-only retrieval is not the launch differentiator;
  graph traversal is.
- **Service-layer split:** `lib/data/` is legacy and frozen (only delete
  from here); `lib/services/` is runtime orchestration; `lib/domain/services/`
  is pure-formula domain logic with no I/O; new state holders go to
  `lib/state/`.
- **Locked tweaks (apply at the named slice):**
  - HNSW indexes default for pgvector (locked into `11a.8` acceptance).
  - Tiered Sonnet/Haiku in `AdvisorAnswerProvider` (locked into `7.57.3`
    interface signature; `tier="quick"` → Haiku, `tier="nuanced"` →
    Sonnet, default `quick`).
  - Per-operator token-budget enforcement (locked into `11a.10` MCP
    tool layer; Postgres counter table + refusal policy).
  - Embedding regeneration policy (locked into `11a.11` cloud DB
    apply; corpus content hash → detect → re-embed).
- standards lock on a 60-day `TargetCycle`
- demand can roll from level 1 baseline + fixed 3-week recent trend
- the operating week should auto-generate one locked `WeeklyPlanSnapshot`
- the locked weekly plan is the current-week plan authority; do not carry a second competing live plan for the in-force week
- Benchmark sets the standard, Plan decides the week, Shift manages right now, Variance compares plan vs actual, History preserves what closed, and Learn teaches from repeated closed results
- non-closed Variance rows should read one shared benchmark target object plus one shared locked-plan object 1:1, row by row, value by value
- non-closed Full Week daypart plan targets should come from the same shared daypart allocation used by Schedule; do not let `OpenShiftSnapshot` / `ShiftRecord` carry a competing projected plan target
- closed Full Week rows stay locked historical truth
- blended wage should be a shared benchmark target value, not recomputed separately by screen/model helpers
- whole-day Shift target alignment landed through `7.55q.7`; `10.5` still owns live service-period/daypart-aware Shift behavior and driver teaching
- no new manager workflow
- no draft/publish state in the UI
- widgets should not own source-truth decisions
- widgets should not own service-period bucketing rules
- Full Week projection semantics should come from a read service / read model, not mixed screen helpers
- we are not fully integration-ready yet; do not describe SQL-backed internal simulation as simple-swap readiness
- current runtime freshness is reload-driven today; `7.55p.4a` through `7.55p.4d` own the connector-fed live freshness / invalidation policy
- intended manager behavior is stronger than reload-driven freshness:
  - show live floor data when current-state is fresh enough to be treated as live
  - otherwise show explicit freshness age such as `Updated 7 min ago`
  - Shift is the highest-priority live surface
- stale current-state must not masquerade as live
- Learn benchmark-context and coaching-summary cleanup landed through
  `7.55l.8` + `7.55k`; active tracker truth no longer treats named Learn
  surface seams as open
- fixed `14 shifts` debt spans runtime, replay seeding, tests, UI copy, and active integration docs
- `7.55o` extraction is complete through SQLite bootstrap breakup; later naming/copy/refactor audits should be scoped separately rather than reopened as extraction acceptance work
- use `docs/internal/status_ledger_post_7_55p_deep_check.md` as the reference sheet for:
  - which older user asks are already done vs partial vs still open
  - post-`7.55o` naming / copy / refactor audit ideas after the landed shell pass
  - the later `7.55j.4` readiness-check conversation
- `10.5` still owns live Shift service-period behavior, live time-into-service, and daypart-live driver teaching

## Flagged For Future Decision (parked at natural phase homes)

These are pre-launch concerns that don't belong in `7.57` / `7.58` /
`7.61` but need a decision at the right moment. Visible here so they
don't get forgotten and don't bloat the current plan. Codex prompts
for them when their phase opens.

| Flag | Phase / slice for decision | Cheap path on current stack |
| --- | --- | --- |
| Production observability (errors + advisor traces) | `9.8` compliance lane | Sentry free tier + Postgres `advisor_answer_log` table |
| LLM cost observability (token spend per operator) | `11a.10` MCP tool layer | Helicone free tier OR same Postgres counter table as token budget |
| Production DB migration story (local container → cloud Supabase) | `11a.11` cloud DB apply | Supabase built-in (`db push`, `db diff`, point-in-time recovery) |
| Launch readiness checklist (Day-1 readiness pass) | New lane near `10b` close | Markdown doc, free |
| Advisor-specific observability (when an answer is wrong, how do we see it?) | `11b` runtime contract or `11b.2` polish | Postgres advisor_answer_log table; admin UI |
| Multi-tenant cost-cap policy (per-operator monthly budget enforcement) | `11a.10` MCP tool layer | Same Postgres counter table as token budget (refusal policy when budget hit) |
| Behavior-specific items folded into existing phases (no own-lane needed): item #5 open-shift-in-Full-Week-projection → 10.5 sub-slice; items #6, #7 timezone + daypart settings UX → Phase 9 / 10a / 10.5 inline | Per their phase | Inline, no extra infrastructure |

## Active Planning Docs

- `docs/phases/post_11a7_stabilization_plan.md` - sequence-aware plan
  resolving 26 concerns across `7.57` (5 sub-slices, NOW), `7.58`
  (5 sub-slices, pre-11b behavioral alignment), `7.61` (4 sub-slices,
  pre-Phase-8 freshness audit), `11b.0` (advisor regression scaffold),
  the locked tweaks, and the flagged-for-decision items. Codex consumes
  this as the planning input for `7.57.0` and onward.
- `docs/contracts/phase_7_55_architecture_contract.md`
- `docs/contracts/phase_7_55_current_state_freshness_contract.md`
- `docs/contracts/phase_7_55_plain_english_architecture.md`
- `docs/contracts/phase_7_55_time_boundary_contract.md`
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- `docs/phases/phase_9/phase_9_auth_plan.md`
- `docs/phases/phase_9_5/phase_9_5_el_podio_learning_identity_plan.md`
- `docs/phases/phase_9_75/phase_9_75_staff_daily_companion_plan.md`
- `docs/phases/phase_9_8/phase_9_8_compliance_and_legal_plan.md`
- `docs/phases/operations_el_podio/operations_el_podio_stub.md`
- `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md`
- `docs/phases/phase_10b/phase_10b_full_offline_sync_plan.md`
- `docs/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md`
- `docs/phases/phase_11b/phase_11b_advisor_ux_plan.md`
## Notes

- Detailed slice-by-slice history was archived to `docs/archive/trackers/PROJECT_TRACKER_FULL_2026-04-12_PRE_TRIM.md`.
- Completed `7.55l` and `7.55m` docs now live under `docs/archive/phases/7_55l/` and `docs/archive/phases/7_55m/`.
- Completed `7.55i`, `7.55k`, `7.55n`, `7.55p`, and the completed `7.55j.1` / `7.55j.2` / `7.55j.gate` docs now live under `docs/archive/phases/`.
- Completed `7.55j`, `7.55o`, `7.55q`, `7.55r`, `7.56`, and completed
  `11a.0` through `11a.7` slice docs now live under `docs/archive/phases/`.
- Active architecture authority docs now live under `docs/contracts/`.
