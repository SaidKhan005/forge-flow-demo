# Forge & Flow Project Tracker

Updated: 2026-04-25
Owner: You
Execution model: We think, Claude codes

## Active Authority

- `PROJECT_TRACKER.md`
- `docs/phases/post_11a7_stabilization_plan.md`
- `docs/CODEX_PROMPT_GENERATION_STANDARD.md`
- `docs/DATA_ALIGNMENT_TRACKER.md` only when the slice is alignment-heavy
- `docs/KNOWN_FAILING_TESTS.md` when a slice runs broad suites or hits a known red test

Archive:

- `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`
- `docs/archive/trackers/PROJECT_TRACKER_FULL_2026-04-12_PRE_TRIM.md`
- `docs/archive/trackers/DATA_ALIGNMENT_TRACKER_FULL_2026-04-10.md`

## North Star

POS + Labor + Reservation Systems -> Canonical Operational Facts -> 60-Day Benchmark Snapshot -> TargetCycle + DemandForecastContext -> SchedulePlan -> WeeklyPlanSnapshot -> Shift -> Variance -> History -> Learn

## Now

- Current phase: `7.57` Stabilization, paused `11a` after `11a.7`.
- Last accepted prompt: `7.57.3c` routed `StaticShiftDataSource` through
  `MockReplayDataSourceProvider`.
- Next slice prompt for Codex to generate: **`7.57.3d`**.
- Active planning input: `docs/phases/post_11a7_stabilization_plan.md`.
- Prompt loop: after each Claude report, Codex verifies repo truth, updates
  trackers, then generates the next prompt from updated tracker truth.
- Current live-integration scope: one restaurant/location at launch, but
  the schema is multi-location-ready (`(operator_id, location_id)` on
  every fact table) so org-level operators with multiple locations can
  onboard without a data migration.
- Naming guardrail: keep internal `Baseline` / `Schedule` names unchanged
  through `7.57` and Phase 8.

## Phase Board

| Phase | Status | Current truth |
| --- | --- | --- |
| `7.57` | active | Structural stabilization. `7.57.0`, `7.57.1`, `7.57.2`, `7.57.3a`, `7.57.3b`, and `7.57.3c` accepted. Next: `7.57.3d`. |
| `11a` | paused at `11a.7` | Corpus, chunking, local Supabase load, Voyage embeddings, and embedding load are landed. Resumes as `11a.8` after `7.57.4` accepts. |
| `7.58` | queued | Pre-11b behavioral alignment lane. Opens after `9.5`; closes before `11b.0`. |
| `7.61` | queued | Pre-Phase-8 freshness audit. Opens after `10b`; closes before Phase 8. |

Completed phase history was moved to
`docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`.

## Current Slice Queue

`7.57` remaining sequence:

1. `7.57.3d` - rename advisor-specific answer provider seam to
   general-purpose `LLMProvider` and expose prompt-caching capability.
2. `7.57.4` - Apache AGE graph projection in the local Supabase/Postgres
   container.
3. Resume `11a.8` - vector search functions / indexes + smoke queries.

## Hard Gates

- `7.57.0` rules + five hard promises accepted.
- `7.57.1` legacy fixture extraction accepted with demo mode visually
  unchanged.
- `7.57.2a` state-holder / refresh-coordinator move accepted.
- `7.57.2b` demo fixture / DB helper move accepted.
- `7.57.2c` runtime read-service move accepted.
- `7.57.2d` baseline / benchmark service cluster move accepted.
- `7.57.2e` TargetCycleService move accepted.
- `7.57.2f` ShiftService move accepted.
- `7.57.2g` ShiftDataSource move accepted; `7.57.2` parent sweep closed.
- `7.57.3a` provider interfaces/adapters accepted; dev advisor model routing
  is configurable, visible in Settings, and update-aware.
- `7.57.3b` advisor corpus embedding execution now routes through
  `VoyageEmbeddingProvider`.
- `7.57.3c` StaticShiftDataSource mock-replay reads now route through
  `MockReplayDataSourceProvider`.
- `7.57.3` provider abstraction must accept before `7.57.4`.
- `7.57.4` AGE graph projection must accept before `11a.8` resumes and before
  `11b` starts.
- All five `7.58` sub-slices must accept before `11b.0` opens.
- Phase 9 RLS must be real and tested before `11b` ships to multiple
  operators.
- All four `7.61` sub-slices must accept before Phase 8 opens.

## Active Guardrails

- Build cadence is sequential, not parallel:
  `[7.57] -> 11a resume -> 9.8 -> 9 -> 10a -> 10.5 -> 9.5 -> [7.58] -> 11b -> 9.75 -> 11b.2 -> 10b -> [7.61] -> 8 -> 8R`.
- Demo mode persists forever. `kDemoMode = true` fills SQLite from
  `mock_integration_replay_seed.dart`; `kDemoMode = false` fills the same
  tables from vendor connectors. Same tables, read paths, UI, and advisor
  behavior.
- Phase 8 is a pure transport swap. If Phase 8 discovers fixture extraction,
  service moves, freshness audits, or behavior decisions, that work belongs in
  `7.57`, `7.58`, or `7.61`.
- No app logic changes before `7.58`. `7.57` through `9.5` close is docs,
  file moves, abstractions around existing behavior, or additive capability.
- Per-operator isolation is non-negotiable, and the schema is
  multi-location-ready from day one. Operator-scoped Postgres fact
  tables (shifts, cycles, plans, weekly snapshots, variance, history)
  carry `(operator_id, location_id)` plus RLS policy stubs from
  creation. Single-location operators run with a default
  `location_id`. Corpus / methodology stays `operator_id`-scoped. RLS
  enforcement turns on in Phase 9; retrofit is not an option once
  facts exist. Decided 2026-04-25.
- Time-storage rule for operator-scoped Postgres fact tables:
  `TIMESTAMPTZ` (UTC) for source-truth instants plus a denormalized
  `business_date` `DATE` column computed at write using
  `location.timezone` (IANA, per-location) +
  `business_day_rollover_hour`. `TIMESTAMP WITHOUT TIME ZONE` is
  banned in operator-scoped tables — silent DST corruption is
  unrecoverable. `business_date` is write-once, never recomputed at
  read. Decided 2026-04-25.
- Repository-pattern enforcement: app code reads/writes
  operator-scoped Postgres tables only through
  `OperatorScopedRepository<T>` (or equivalent), which injects
  `(operator_id, location_id)` from the current `OperatorContext`.
  Raw `package:postgres` imports are forbidden outside
  `lib/infrastructure/persistence/postgres/`; CI lint enforces.
  Postgres RLS stays enabled on every operator-scoped table as the
  safety net underneath. Two-layer defense — repository wrapper is
  the primary protection, RLS is the backup. Decided 2026-04-25.
- AGE graph projection must be verified before `11b` starts.
- Production Anthropic/Voyage/vendor keys must stay server-side. Flutter
  release/App Store/Play Store builds must not receive real API keys via
  `--dart-define`; 11b/Phase 8 must use a backend gateway for production
  provider calls.
- Advisor posture is recommendation-only, not action. Decided 2026-04-25:
  the advisor surfaces grounded recommendations with provenance and
  confidence ("I recommend X because Y"); operators decide whether to act.
  F&F never acts on the operator's behalf in the launch product.
  Liability: F&F provides advisory information; operator decisions and
  outcomes are the operator's sole responsibility, codified in Phase 9.8
  T&Cs. Workflow automation (Phase 12 post-launch) extends this with
  per-action consent — same posture, just covering automated actions.
- Service-layer split: `lib/data/` is legacy and frozen; `lib/services/` is
  runtime orchestration; `lib/domain/services/` is pure formula/domain logic
  with no I/O; state holders live in `lib/state/`.

## Locked Future Tweaks

- `11a.8`: default pgvector indexes to HNSW.
- `11a.8`: vector versioning schema columns on the embeddings table.
  Every embedded chunk row carries `embedding_provider_id` (e.g.
  `voyage`), `embedding_model_id` (e.g. `voyage-4-large`), and
  `embedding_dimension` (e.g. `1024`) from day one. Lands in `11a.8`
  schema scope alongside vector-search functions and HNSW indexes.
  Without these columns, mixed-provider retrieval breaks silently
  during a future provider transition; with them, retrieval queries
  scope by provider/model and provider swaps trigger a clean
  re-embed of affected rows only. Decided 2026-04-25.
- `7.57.3`: `LLMProvider.answer(..., tier)` routes `quick` -> Haiku
  and `nuanced` -> Sonnet; default `quick`. Renamed from
  `AdvisorAnswerProvider` per hard promise #8 (general-purpose AI
  infrastructure); rename folds into `7.57.3c` or a small `7.57.3d`.
- `7.57.3` / `11a.10`: Anthropic prompt caching exposed via
  `Capability.promptCaching` — ~10x reduction on repeated context
  (system prompt, methodology). Generic capability flag so the
  abstraction stays portable across providers.
- `11a.10` is the proxy backend (formerly framed as MCP tool layer).
  Two launch-blocking sub-slices:
  - `11a.10a` proxy infrastructure — Cloud Run service, key vault,
    JWT-auth, operator scoping. F&F's master Anthropic + Voyage
    keys live here; client app never holds them.
  - `11a.10b` per-operator enforcement — token budget, rate limit,
    monthly cost cap with refusal policy, all configurable per
    pricing tier. Includes a per-operator counter table for cap
    enforcement; admin dashboards on top of it are flagged
    (`11a.10c`, post-100-locations).
- `11a.10d` provider fallback chains (capability, off by default) —
  Anthropic primary → secondary → OpenAI `gpt-4o-mini` fallback.
  Architecture supports it; implementation deferred until production
  data shows it's needed. Lighting it up requires a multi-week
  investment to integrate the second provider and prompt-tune. Q7
  default at launch is hard-fail with a clear error message.
- `11a.11`: corpus chunks are content-addressed — chunk ID is a hash
  of the chunk content. Any content change produces a new chunk ID;
  old chunks stay in the corpus (marked inactive in the search
  index, not deleted) so old advisor recommendations remain
  replayable against the exact chunks they cited. Embedding regen
  runs on chunks with new hashes only. Decided 2026-04-25.
- `11a.12`: **Corpus admin UX in app settings.** Vanessa drops a
  markdown file in a Settings page; the app ingests it, chunks it,
  content-hashes the chunks, embeds new/changed chunks via Voyage,
  writes to Postgres. Markdown only at MVP. Default scope is
  operator-scoped corpus (hard promise #4); global F&F-shipped
  corpus vs operator extensions is a separate decision when multi-
  operator goes live. Slot locked 2026-04-25 (was previously `11a.x`
  tbd); queued after `11a.11` cloud DB apply so the corpus pipeline
  writes to production Postgres.
- Post-launch caching layer for repeat advisor questions (Q7 option
  B, deferred). When production data shows specific question
  classes recurring, add a cache so an Anthropic blip surfaces
  "from N minutes ago" instead of an error. Off until evidence
  justifies.
- `LLMProvider.complete(...)` is non-streaming at launch (returns
  full response). Streaming arrives post-launch as a non-breaking
  additive method `completeStream(...)` returning a stream of
  events; existing `complete()` callers unaffected. Decided
  2026-04-25 (Q8 option A): pre-launch validation is about answer
  substance, not UX feel; SSE / mid-stream cost-cap edges add
  1–2 weeks of proxy work that doesn't change correctness.
- Prompt-injection defense at launch (decided 2026-04-25, Q9
  updated post-research). The actual defense at MVP is
  architectural — RLS + repository pattern + read-only + single-
  shot RAG + F&F-controlled corpus. The prompt-stack is hygiene on
  top, not the primary defense. MVP stack:
  1. **Base64-encode operator free-text fields** when injecting
     them into context (Microsoft Spotlighting "encoding" variant —
     ~2% attack success vs ~50% baseline in published tests).
     Replaces naive XML delimiter wrapping; system prompt
     instructs Claude to decode mentally and treat as data.
  2. **System-prompt scoping** — explicit instruction: "you only
     answer questions about restaurant operations using the
     provided context; decline anything off-topic." OWASP #1
     mitigation; free.
  3. **Output sanitization for markdown links and images** —
     strip / rewrite any URL or image in the model's response
     unless it points to an F&F-internal allowlist domain. This is
     the defense that would have prevented Slack AI (Aug 2024) and
     Microsoft EchoLeak (June 2025) exfiltration incidents. Cheap,
     high-impact.
  4. **Length caps on operator free-text fields** when injected
     into context (e.g., 500 chars on shift notes — separate from
     storage limits). Large injected blobs are an attack vector.
  5. Anthropic role separation (system vs user) used for
     structural clarity. Published 480-test study showed
     negligible security impact alone — kept as hygiene, not
     counted as a defense layer.
  Folds into `7.57.3c`/`3d` prompt-construction work; not a new
  slice. The actual link/image allowlist for output sanitization
  is flagged for Phase 9.8 commercial scope.
- **Multi-operator launch prompt-injection adds** (locked, lights
  up when 11b ships to multiple operators): (a) input-side
  classifier on operator queries — Meta's Llama Prompt Guard 2
  (free, fast, multilingual) is the default choice; (b) provenance
  markers in every context block (`<source operator="..."
  trust="...">`) so retrieval scoping is reviewable; (c) retrieval-
  scope audit — filter by `operator_id` BEFORE embedding similarity,
  not after (Slack AI Aug 2024 root cause); (d) adversarial test
  suite in CI, seeded from `tldrsec/prompt-injection-defenses`.
- **Phase 12 (write-tools / agent loops) prompt-injection adds** —
  this is where architecture changes, not just heavier filtering.
  Lights up when write-tools land:
  (a) Plan-Then-Execute or Action-Selector pattern (Simon Willison
      design patterns paper, June 2025) — tool calls are decided
      before the model sees retrieved or operator-supplied content;
  (b) Two-LLM separation (CaMeL-style) for any write path that
      touches operator-supplied content — quarantined LLM extracts,
      privileged LLM acts, symbolic variables only between them;
  (c) Human-in-the-loop **mandatory** for irreversible actions
      (schedule changes, comms, financial);
  (d) Tool-output classifier (Anthropic's auto-mode pattern) over
      every tool result before it re-enters agent context;
  (e) Egress allowlist — closed list of where automated workflows
      can reach;
  (f) Per-operator audit log of every tool call.
- **Cloud Run cold-start strategy** (decided 2026-04-25, Q11). At
  MVP: `min-instances=0` (accept ~5–15s cold-start latency on first
  request after ~15 min idle). Cost: $0 baseline; acceptable for
  single-operator beta. At multi-operator launch: flip to
  `min-instances=1` (always-warm proxy). Cost: ~$15–30/month per
  warm instance. Configurable at deploy time — no code change. Per-
  operator cost negligible at scale (one warm instance serves many
  operators). Avoids the "natural usage gap → 20s wait" UX hit
  once usage spreads across operators through the day. Skipped
  warmup pings (option C) — fragile, silent failure mode, no
  benefit over `min-instances=1`.
- **Graph backend fallback architecture** (decided 2026-04-25,
  Q12). The retrieval layer in `11a.8` / `11a.9` ships with a
  `mode: graph-first | vector-only` flag. AGE is the default at
  launch (hard promise #5); the vector-only mode is dormant
  insurance. Activates only if AGE benchmarks fail at production
  scale. Integration cost: ~half a day in `11a.8` / `11a.9` —
  vector-only path already exists alongside AGE; just exposing the
  mode selector through the retrieval API.
  **AGE benchmark gate**: before AGE is trusted for production,
  run it at simulated 1K and 10K operator-scale synthetic data; if
  graph-traversal queries hit p95 > 500ms, the fallback flag is
  the launch posture, not the contingency posture.
  **What "fallback activated" means**: advisor degrades to vector-
  only RAG (the same retrieval pattern every other AI advisor
  uses) — functional, just less differentiated. Hard promise #5
  remains met (AGE projection ships in 7.57.4); the differentiator
  is paused while Neo4j migration plans on a normal 6–9 week
  timeline if AGE truly cannot scale. Without this fallback, an
  AGE production failure forces a launch delay or a broken-advisor
  ship.
- **Agent runaway bounds** (decided 2026-04-25, Q10).
  At launch (extends `11a.10b`): per-request `max_tokens` enforced
  via `LLMProvider`; per-request HTTP wallclock timeout in the
  proxy (default 30s for the advisor); per-operator monthly cost
  cap (already locked). Catches single-request runaway with cheap,
  native API features.
  For Phase 12 (when write-tools land): per-task tool-call cap
  (default 20, tunable per pricing tier); per-task token cap
  (default $1.00 / 100K tokens, tunable); per-task wallclock cap
  (default 60s, tunable); per-operator parallel-task cap (default
  3, tunable). Enforcement is server-side in the proxy (extension
  of `11a.10b` counter table — per-task tracking alongside per-
  operator-monthly tracking). Client-side counters in the agent
  runtime as defense-in-depth.
  **Failure mode is graceful summary, not hard cut-off**: when a
  limit hits ~80%, agent runtime injects "summarize what you've
  found so far and conclude" instruction. Operator sees a partial
  result with a "task was cut short" badge — not an error wall.

## Flagged For Future Decision (parked at natural phase homes)

Pre-launch concerns that don't belong in `7.57` / `7.58` / `7.61` but need
a decision at the right moment. Codex prompts for them when their phase
opens.

- **Phase 9.8 (compliance) — Advisor T&Cs + liability disclaimer codification.**
  Operator-facing T&Cs that explicitly state F&F provides advisory
  information; operator decisions and outcomes are the operator's sole
  responsibility. Plus E&O insurance evaluation for AI advisory output.
  (Posture locked 2026-04-25 as recommendation-only; this flag tracks the
  legal/insurance work.)
- **Phase 9.8 (compliance) — Production observability (errors).**
  General application error tracking. Cheap path: Sentry free tier.
  (Advisor-answer audit log is a separate flag — see 11b.2 below.)
- **Phase 9.8 (commercial) — Output sanitization allowlist.**
  What URL domains are permitted in advisor responses? At minimum:
  an F&F-internal allowlist of allowed link / image hosts. Anything
  else gets stripped or rewritten. Pairs with the MVP prompt-
  injection stack above. Decision: write the allowlist before
  multi-operator launch.
- **Phase 9.8 (commercial) — F&F pricing tier model.** What
  subscription tiers exist, what cost cap each tier gets, which tier
  gets which model (Haiku-only vs Sonnet-on-demand). **Cost reality
  at Haiku-first tiered routing + prompt caching:** heavy operator
  (~100 questions/month) ≈ $0.10–$0.30/month; light operator (~20
  questions/month) ≈ $0.02–$0.06/month; embedding (one-time + on
  corpus update) ≈ $0.05 total at 233 chunks. A $5/operator/month
  cap leaves healthy margin on a typical SaaS subscription. Real
  cost risk is uncapped agentic loops in Phase 12 — cost cap +
  Haiku-default must be on before any write-tool ships.
- **`11a.10c` (post-100-locations) — Cost observability + admin
  dashboards.** Per-operator dashboards, daily / monthly aggregates,
  alert thresholds. Deferred 2026-04-25: too much overhead before
  100 locations. The counter table from `11a.10b` is enough for
  cost-cap enforcement until volume justifies the dashboard build.
- **`11a.10d` (when production data justifies) — Provider fallback
  strategy.** Strategy specifics — Anthropic → OpenAI gpt-4o-mini,
  or Anthropic → Google Gemini Flash, or three-deep? Cost vs
  reliability trade-off. The capability is locked above; the
  strategy choice is the flag.
- **`11a.11` (cloud DB apply) — Production DB migration story.**
  Local Supabase container -> cloud Supabase. Built-in via Supabase
  `db push`, `db diff`, point-in-time recovery.
- **`11b` runtime / `11b.2` polish — Advisor audit log (light).**
  Decided 2026-04-25: light audit only — question, answer, timestamp,
  `operator_id`, cost. No implementation now; parked for the 11b.2
  conversation. Pairs with the Phase 9.8 T&Cs flag above —
  recommendation posture is the legal shield, audit log is operational
  hygiene. Heavier schema (corpus version, retrieved chunks, prompt
  hash, replay tool) is a post-launch decision if a dispute ever
  surfaces.
- **New lane near `10b` close — Launch readiness checklist.** Day-1
  readiness pass. Markdown doc.
- **Post-launch (Phase 12 candidate) — Workflow automation lane.**
  Builds on the same provider abstraction + MCP tool layer; extends
  read-only tools to write-tools (schedule edits, notifications,
  plan adjustments). Per-workflow cost caps + agentic loop limits
  required before any write-tool ships. Demand signal: operator asks
  for "AI runs operations," or 10+ operators asking for the same
  workflow.

## Active Planning Docs

- `docs/phases/post_11a7_stabilization_plan.md`
- `docs/contracts/phase_7_55_architecture_contract.md`
- `docs/contracts/phase_7_55_current_state_freshness_contract.md`
- `docs/contracts/phase_7_55_time_boundary_contract.md`
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`
- Phase docs for queued lanes remain under `docs/phases/`.

## Notes

- Detailed completed history now lives in
  `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`.
- Active architecture authority docs live under `docs/contracts/`.
- Completed phase docs live under `docs/archive/phases/`.
