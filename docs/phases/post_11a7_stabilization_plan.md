# Post-11a.7 Sequence-Aware Stabilization Plan

Updated: 2026-04-25
Owner: Codex planning input (not tracker truth yet)
Status: Planning input — Codex to convert into per-slice prompts

## Why This Exists

After `11a.7` (Voyage embeddings loaded into the local Supabase/Postgres
container), pause before resuming the next 11a slice. Insert structural
fixes from the 2026-04-25 architecture critique **at the right point in
the build sequence**, then run a behavioral alignment lane before 11b
opens, and a freshness audit before Phase 8 opens. Phase 8 is reframed
as a pure transport swap.

This is the planning input Codex uses to generate slice prompts in the
standard `docs/CODEX_PROMPT_GENERATION_STANDARD.md` format.

## Hard Architectural Promises (locked, do not break)

These are the contracts every subsequent slice must respect:

1. **Phase 8 is a pure transport swap.** All architectural cleanup
   lands in `7.57` or `7.61`. Phase 8 only adds vendor connector
   writers against existing SQLite tables.

2. **Demo mode persists forever.** The `kDemoMode` flag is available
   in every phase from `7.57` forward, **including post-launch**:
   - `kDemoMode = true` → `mock_integration_replay_seed.dart` fills
     SQLite tables → screens render demo data identical to today.
   - `kDemoMode = false` → vendor connectors fill SQLite → screens
     render real operator data.
   - Same SQLite tables, same read services, same UI, same advisor
     behavior. The flag is a writer-side switch only.
   - `legacy_fixture_data.dart` retires in `7.57.1`; the demo path
     itself does not retire.

3. **No app logic changes before `7.58`.** Every slice from `7.57`
   through `9.5` close is one of: docs/governance, file moves,
   abstraction layers, additive new capability. The first slice that
   decides on existing app logic is `7.58.0`.

4. **Per-operator data isolation is non-negotiable.** RLS-ready schema
   from day one (rule in `7.57.0`); Phase 9 turns enforcement on. 11b
   cannot ship to multiple operators until Phase 9 RLS is real and
   tested.

5. **AGE graph projection ships before 11b starts.** The "reasons over
   your knowledge graph" differentiator is real, not marketing. AGE
   lands in `7.57.4`.

## Build Order (sequential, not parallel)

```
[7.57 NOW]  structural cleanup — no app logic changes
   .0  rules
   .1  legacy_fixture_data extraction
   .2  lib/data sweep
   .3  provider abstraction (Embedding + Rerank + Answer + DataSource)
   .4  AGE graph projection

   -> 11a (resume: 11a.8 vector search → rerank → MCP → cloud apply)
   -> 9.8 (compliance — flag: production observability decision)
   -> 9 (auth + identity — RLS turns on)
   -> 10a (multi-device state — flag: time zone settings UX inline)
   -> 10.5 (daypart Shift — absorbs item 5: open shift in Full Week projection)
   -> 9.5 (El Podio learning identity)

[7.58]  Pre-11b Behavioral Alignment Lane
   .0  Primary Driver decision logic audit (whole-day)
   .1  Dollar Impact math + accumulation audit
   .2  History/Learn identity decomposition
   .3  History coverage decision (8 weeks vs 60 days)
   .4  Fixture realism audit

   -> 11b (starts with 11b.0 advisor regression scaffold)
   -> 9.75 -> 11b.2 -> 10b

[7.61]  Pre-Phase-8 Freshness Audit
   .0  Freshness behavior across all screens
   .1  Plan empties-then-populates fix (single-source-of-truth)
   .2  Swipe-down refresh policy
   .3  Day/date/shift truth display contract

   -> 8 (PURE transport swap)
   -> 8R
```

## Slice Sequence

### 7.57 Stabilization (NOW, before 11a resumes)

#### `7.57.0` — Codify post-critique rules (no code changes)

**Scope:**
- Update `CLAUDE.md` with three rules:
  1. **Service layer split:** `lib/data/` is legacy and frozen (only
     delete from here, never add); `lib/services/` is runtime
     orchestration; `lib/domain/services/` is pure-formula domain
     logic with no I/O; new state holders go to `lib/state/` (new
     folder).
  2. **RLS-ready schema:** any operator-scoped Postgres table includes
     `operator_id` and an RLS policy stub from day one.
  3. **Phase doc hygiene:** slices < 1 week of work AND < 5 files of
     impact go inline in the tracker; new own-phase docs only when
     larger or when they introduce a new contract; retire completed
     phase docs to `docs/archive/phases/` within one week of close.
- Update `PROJECT_TRACKER.md` with Phase 9 → 11b RLS hard-gate, AGE →
  11b hard-gate, the demo-mode-persists-forever promise, and the
  pure-transport-swap framing of Phase 8.

**Acceptance:**
- Three rules + five hard promises (above) present in `CLAUDE.md` and
  `PROJECT_TRACKER.md`.
- `dart analyze` clean (no code changes).

#### `7.57.1` — Legacy fixture extraction

**Scope:**
- Replace `legacy_fixture_data.dart` imports across ~31 production
  files:
  - **Constants** → `lib/data/app_defaults.dart` (new, legitimate
    config; real runtime values).
  - **Sample data** → fold into `sqlite_database_seed.dart` so the
    seed pipeline is the single demo-data writer. The actual data
    source becomes `mock_integration_replay_seed.dart` (which is
    already purpose-built for this — Phase 8 will swap its writer
    for vendor connectors later).
  - **Misuse importers** → real read service calls.
- Move `legacy_fixture_data.dart` to `lib/dev/` behind `kDemoMode` or
  delete if all consumers migrated.
- `kDemoMode = true` continues to render the same demo restaurant
  visually identical to today. The flag stays in place forever.

**Acceptance:**
- 0 imports of `legacy_fixture_data.dart` from `lib/screens/`,
  `lib/services/`, `lib/data/` (except possibly the file itself).
- Both flavors build cleanly.
- All tests pass (variance, schedule, settings, audit suites).
- **Demo mode visually unchanged** — explicit before/after screenshot
  comparison in the slice report.
- `kDemoMode = true` continues to produce a working demo restaurant.

**Realistic effort:** the largest slice in 7.57. May split into
`7.57.1a` (constants + misuse), `7.57.1b` (sample data → seed
pipeline), `7.57.1c` (relocate / delete).

#### `7.57.2` — `lib/data/` consolidation sweep

**Scope:**
- Move legacy code out of `lib/data/` per the rule from `7.57.0`.
- Behavior-preserving file moves only. No logic changes.
- Update imports across the codebase as files move.

**Acceptance:**
- `lib/data/` contains only files not yet migrated.
- All other services in correct directories per the rule.
- All tests pass; both flavors build cleanly.

#### `7.57.3` — Provider abstraction interfaces

**Scope:**
- Create four interfaces in `lib/domain/services/`:
  - `EmbeddingProvider` (`embed(text) -> vector`)
  - `RerankProvider` (`rerank(query, candidates) -> ranked`)
  - `AdvisorAnswerProvider` (`answer(question, context, tier) ->
    grounded response`) — **`tier` parameter locks in tiered
    Sonnet/Haiku selection**: `tier="quick"` routes to Haiku;
    `tier="nuanced"` routes to Sonnet. Default = `"quick"`.
  - `DataSourceProvider` — covers the 5 importers of
    `mock_integration_replay_seed.dart` so Phase 8 vendor connectors
    can implement the same interface without touching the importer
    code paths.
- Concrete classes: `VoyageEmbeddingProvider`, `VoyageRerankProvider`,
  `ClaudeAnswerProvider` (with tier dispatch),
  `MockReplayDataSourceProvider`.
- Wire `11a.7`'s embedding execution and the 5 mock-replay importers
  through the abstraction.

**Acceptance:**
- Four interfaces defined; concrete classes pass focused integration
  tests.
- `tier` dispatch verified with two test cases (quick → Haiku model
  ID, nuanced → Sonnet model ID).
- Mock-replay importers go through `DataSourceProvider`, not the
  concrete class.

#### `7.57.4` — AGE graph projection (implementation)

**Scope:**
- Confirm or draft AGE projection slice doc under
  `docs/phases/phase_11a/`.
- Implement Apache AGE projection in the local Supabase/Postgres
  container:
  - Enable AGE extension; create graph (e.g., `forge_advisor`).
  - Load nodes from `graph_node_seeds`; materialize edges from
    `graph_edge_hints`.
  - Smoke traversal query: "CPLH metric → Chapter 5 teaching →
    covers/hours formula" returns expected nodes.
- Update `PROJECT_TRACKER.md` to mark the 11b → AGE-shipped hard-gate
  as satisfied for the local container; remaining work is cloud DB
  apply (`11a.11`).

**Acceptance:**
- AGE extension enabled; graph created; nodes + edges projected.
- Smoke traversal returns expected node set.
- 11b implementation gate documented in tracker.

### After 7.57 — Resume 11a

11a resumes from where it paused, on top of the abstraction + AGE
foundation:

- `11a.8` — Vector search functions / indexes + smoke queries.
  **Default to HNSW indexes** (better recall vs IVFFlat for the
  small-corpus case). Lock this into the slice acceptance.
- `11a.9` — Voyage `rerank-2.5` smoke tests (calls go through
  `RerankProvider`).
- `11a.10` — MCP tool layer. **Includes per-operator token-budget
  enforcement** (Postgres counter table + refusal policy when budget
  hit; safeguards Anthropic spend).
- `11a.11` — Cloud DB apply (Supabase, not local container).
  **Includes embedding regeneration policy** (corpus content hash →
  detect → re-embed; flagged item handled).

### Original sequence continues

`11a (resumed) → 9.8 → 9 → 10a → 10.5 → 9.5 → [7.58] → 11b → 9.75 →
11b.2 → 10b → [7.61] → 8 → 8R`

### 7.58 Pre-11b Behavioral Alignment Lane (after 9.5 close, before 11b open)

#### `7.58.0` — Primary Driver decision logic audit (whole-day)

**Scope:**
- Audit the existing whole-day Primary Driver decision: how it gets
  picked / deduced / decided in code today.
- Document the decision logic explicitly so 11b's advisor can ground
  answers about "why is X my primary driver" against a stable contract.
- Decide: stays in Variance/Shift surface (short summary), deep
  explanation lives in Learn (item #2 from the behavior list folds
  in here naturally).
- 10.5's daypart Primary Driver is a separate concern — that ships in
  Phase 10.5; this slice is about the whole-day version that exists
  today.

**Acceptance:**
- Decision logic documented in `docs/contracts/` or a Learn-side doc.
- Identified gaps queued as `7.58.0a` follow-ups if any.

#### `7.58.1` — Dollar Impact math + accumulation audit

**Scope:**
- Audit Dollar Impact math: per-shift → per-day → per-week →
  per-month → per-year accumulation.
- Audit decision logic: when does a shift contribute, how is it
  summed, what's the rounding policy.
- 7.55q.10 unified the card; this slice goes deeper into the math
  and accumulation behavior the card surfaces.

**Acceptance:**
- Math documented per stack level.
- Any drift between displayed values and underlying truth identified
  and queued as `7.58.1a` follow-up if needed.

#### `7.58.2` — History/Learn identity decomposition

**Scope:**
- Step-by-step audit of History vs Learn surfaces. Identify
  redundancies in what each surface communicates.
- Decide: what is History uniquely for? What is Learn uniquely for?
- Result: contract for which surface owns which information.
- Folds in item #2 from the behavior list (Primary Driver short in
  week/history, deep in Learn).

**Acceptance:**
- Identity contract documented.
- Redundancies identified and queued for cleanup as separate
  follow-up slices (not in this slice).

#### `7.58.3` — History coverage decision (8 weeks vs 60 days)

**Scope:**
- Decide: does History show the last 8 weeks (current behavior) or
  the full 60 days that match the TargetCycle window?
- The 60-day TargetCycle is the standards-lock window. 8-week
  History creates an off-by-one inconsistency.
- This is a product + architecture decision; document the rationale.

**Acceptance:**
- Decision documented in `docs/contracts/` or History-side doc.
- If decision is "switch to 60 days", implementation slice queued.

#### `7.58.4` — Fixture realism audit

**Scope (informational, no code changes):**
- Read `lib/data/legacy_fixture_data.dart` (already retired by 7.57.1
  but the seed data lives in the SQLite seed pipeline now).
- Validate operational realism: wages, cover/sales/PPA consistency,
  weekday/weekend curves, daypart distribution.
- The advisor in 11b will be tested against this data; realism
  affects answer quality.

**Acceptance:**
- Audit doc lists realism findings (or confirms data is realistic).
- If unrealistic numbers found, separate cleanup slice queued before
  11b opens.

### 11b.0 — Advisor regression test scaffold (first slice of 11b)

**Scope:**
- Create `test/advisor/` with one example regression test against
  fixture-grounded answer expectations.
- Document the regression-test pattern in `test/advisor/README.md`.
- Reference the suite in 11b's main plan doc as the test cadence —
  and as the safety net for the eventual fixture → live data swap in
  Phase 8.

**Acceptance:**
- `test/advisor/` exists with scaffold + ≥ 1 passing example.
- Pattern documented and referenced.

### 7.61 Pre-Phase-8 Freshness Audit (after 10b close, before Phase 8 open)

#### `7.61.0` — Freshness behavior across all screens

**Scope:**
- Audit which screen reads what, when, with what staleness contract.
- Compare with `7.55p.4a` through `7.55p.4d` decisions to find any
  gaps that landed since.
- Document the freshness contract per screen: Shift, Plan, Schedule,
  Variance, History, Learn, Settings.

**Acceptance:**
- Per-screen freshness contract documented.

#### `7.61.1` — Plan empties-then-populates investigation + fix

**Scope:**
- Investigate the observed behavior of Plan showing empty before
  populating.
- If single-source-of-truth violation: fix.
- If race condition / load-order issue: fix.

**Acceptance:**
- Behavior identified and addressed.
- Plan renders consistently from first paint.

#### `7.61.2` — Swipe-down refresh policy

**Scope:**
- Audit what swipe-down refresh actually does today.
- Decide what it should do: query connectors? Re-read SQLite?
  Re-derive from canonical truth?
- Document the policy.
- Live dashboard best practices research feeds this decision.

**Acceptance:**
- Refresh policy documented.
- Implementation aligns with policy.

#### `7.61.3` — Day/date/shift truth display contract

**Scope:**
- Decide whether/where the Shift header shows today's date and day.
- Document the contract: Business date is the anchor (per existing
  Time Boundary Contract); display formatting decided here.

**Acceptance:**
- Display contract documented.
- Shift header implementation aligns.

### Phase 8 — Pure transport swap (after `7.61` closes)

Phase 8 contains zero architectural cleanup. Its scope:
- Implement vendor connectors (POS, labor) implementing
  `DataSourceProvider` (from `7.57.3`).
- Disable the demo seed pipeline when `kDemoMode = false`.
- `kDemoMode = true` continues to produce the demo restaurant.
- Vendor capability gates per existing Phase 8 readiness docs.

If Phase 8 finds itself extracting a fixture, moving a service, or
auditing freshness/behavior, that signals a `7.57` / `7.58` / `7.61`
follow-up slice — not Phase 8 scope creep.

`8R` (reservation connector) follows the same rule.

## Locked Tweaks (folded into specific slices)

| Tweak | Slice |
|---|---|
| HNSW indexes default for pgvector | `11a.8` slice acceptance |
| Tiered Sonnet/Haiku in `AdvisorAnswerProvider` | `7.57.3` interface signature |
| Per-operator token-budget enforcement | `11a.10` MCP tool layer |
| Embedding regeneration policy (corpus hash → re-embed) | `11a.11` cloud DB apply |

These are locked in at the slice level so Codex picks them up when
generating prompts for those slices. Not flagged for later decision.

## Flagged For Future Decision (parked at natural phase homes)

These are pre-launch concerns that don't belong in `7.57` / `7.58` /
`7.61` but need a decision at the right moment:

| Flag | Decision moment | Cheap path noted |
|---|---|---|
| Production observability (errors + advisor traces) | `9.8` compliance lane (audit logging is compliance territory) | Sentry free tier + Postgres `advisor_answer_log` table |
| LLM cost observability | `11a.10` MCP tool layer (log every API call with token counts) | Helicone free tier OR Postgres counter table — same place as token budget |
| Production DB migration story | `11a.11` cloud DB apply | Supabase built-in (`db push`, `db diff`, point-in-time recovery) |
| Launch readiness checklist | New `9.8` or `pre-launch` lane when 10b approaches close | Markdown doc, free |
| Production observability — advisor-specific (when an answer is wrong, how do we see it?) | `11b` runtime contract or `11b.2` polish | Postgres advisor_answer_log table; admin UI |
| Multi-tenant cost-cap policy (per-operator monthly budget) | `11a.10` MCP tool layer | Same Postgres counter table as token budget |

These items are visible in the tracker as "flagged for decision at
[phase]" — they don't get forgotten and they don't bloat the current
plan.

## Coverage Map (final)

26 distinct concerns surfaced across the planning rounds; every one
has a slot.

| Source | # | Concern | Slice / Slot |
|---|---|---|---|
| Original critique | 1 | Legacy fixture entanglement | `7.57.1` |
| Original critique | 2 | `lib/data/` rule | `7.57.0` |
| Original critique | 2 | `lib/data/` sweep | `7.57.2` |
| Original critique | 3 | Three parallel lanes | Dissolved |
| Original critique | 4 | Voyage / Claude lock-in | `7.57.3` |
| Original critique | 5 | AGE graph projection | `7.57.4` |
| Original critique | 6 | Phase doc proliferation | `7.57.0` rule + ongoing |
| Original critique | 7 | Auth → 11b dependency | `7.57.0` + Phase 9 |
| Sequential-build new | A | Fixture realism | `7.58.4` |
| Sequential-build new | B | RLS-ready schema | `7.57.0` rule |
| Sequential-build new | C | Cross-phase regression | `11b.0` |
| Deep graph | D | mock-replay abstraction | `7.57.3` (DataSourceProvider) |
| Behavior list | 1 | Primary Driver logic | `7.58.0` |
| Behavior list | 2 | Primary short / Learn deep | `7.58.0` + `7.58.2` |
| Behavior list | 3 | Dollar Impact math | `7.58.1` |
| Behavior list | 4 | History/Learn identity | `7.58.2` |
| Behavior list | 5 | Open shift in Full Week | Phase 10.5 sub-slice |
| Behavior list | 6 | Time zone settings UX | Phase 9 / 10a inline |
| Behavior list | 7 | Daypart open/close + TZ | Phase 10.5 + Phase 9 |
| Behavior list | 8 | Freshness audit (4 sub-questions) | `7.61.0–.3` |
| Behavior list | 9 | History 8 vs 60 | `7.58.3` |
| Tweak | T1 | HNSW default | `11a.8` |
| Tweak | T2 | Tiered Sonnet/Haiku | `7.57.3` |
| Tweak | T3 | Per-operator token budget | `11a.10` |
| Tweak | T4 | Embedding regeneration policy | `11a.11` |
| Flag | F1 | Production observability | `9.8` |
| Flag | F2 | LLM cost observability | `11a.10` |
| Flag | F3 | DB migration story | `11a.11` |
| Flag | F4 | Launch readiness | New lane near 10b close |
| Flag | F5 | Advisor-specific observability | `11b` / `11b.2` |
| Flag | F6 | Multi-tenant cost-cap | `11a.10` |

## How Codex Uses This

1. Codex reads this plan as the next planning input.
2. Codex generates the slice prompt for `7.57.0` first.
3. After acceptance, Codex updates trackers, then generates `7.57.1`,
   `7.57.2`, `7.57.3`, `7.57.4` in order.
4. After `7.57.4`, Codex resumes 11a as `11a.8` (vector search,
   defaulting to HNSW indexes per the locked tweak).
5. Sequence continues normally, with the queued lanes (`7.58`,
   `7.61`) opening at their named gates.
6. Tweaks are applied at the slice level (Codex includes them in
   the relevant slice prompts).
7. Flagged items surface as tracker-visible "flagged for decision at
   [phase]" entries — Codex prompts for them when their phase opens.
