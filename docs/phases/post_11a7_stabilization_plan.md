# Post-11a.7 Stabilization Plan

Updated: 2026-04-25
Owner: Codex planning input
Status: Active until `7.57.4` accepts

Full pre-trim history:
`docs/archive/phases/post_11a7_stabilization_plan_full_2026-04-25_pre_trim.md`

## Why This Exists

After `11a.7` loaded local Voyage embeddings, we paused 11a to land the
structural stabilization that must exist before vector search, graph traversal,
advisor UX, and vendor transport work continue.

Plain English: this lane tightens the architecture before the advisor and live
vendor work depend on it. Example: mock replay, live vendors, and future
operator data sources should all enter through the same provider-style seam,
not through scattered fixture imports.

## Non-Negotiables

- Build is sequential, not parallel.
- Phase 8 is a pure transport swap.
- Demo mode persists forever.
- No existing app-logic decisions before `7.58`.
- Operator-scoped Postgres facts are `(operator_id, location_id)` scoped and
  RLS-ready from day one.
- Source-truth instants use `TIMESTAMPTZ` plus write-once `business_date`.
- Postgres access goes through operator-scoped repositories; raw
  `package:postgres` imports stay inside infrastructure.
- AGE graph projection ships before `11b` starts.
- Production Anthropic/Voyage/vendor keys stay server-side.
- AI infrastructure is general-purpose: `LLMProvider`, `EmbeddingProvider`,
  `RerankProvider`, and `DataSourceProvider`.
- Advisor is recommendation-only; F&F does not act for the operator at launch.

Detailed guardrails live in `PROJECT_TRACKER.md`; this file exists to keep the
slice order and prompt scope clear.

## Current State

Accepted:

- `7.57.0` rules and hard promises.
- `7.57.1` legacy fixture extraction.
- `7.57.2` `lib/data/` sweep; `lib/data/` now keeps only canonical runtime
  defaults and the mock replay writer.
- `7.57.3a` provider interfaces/adapters plus dev model-routing Settings.
- `7.57.3b` advisor corpus embedding execution through
  `VoyageEmbeddingProvider`.
- `7.57.3c` StaticShiftDataSource mock-replay reads through
  `MockReplayDataSourceProvider`.

Current next:

- `7.57.3d` rename the advisor-specific answer provider seam to a
  general-purpose `LLMProvider` and expose prompt-caching capability.

## Remaining 7.57 Queue

### `7.57.3d` - Provider naming/capability cleanup

Scope:

- Rename advisor-specific answer abstraction to `LLMProvider` where needed.
- Keep `quick -> Haiku`, `nuanced -> Sonnet`, default `quick`.
- Expose prompt-caching capability generically.

Acceptance:

- No `AdvisorAnswerProvider` symbols remain in live code/tests.
- Existing Claude answer provider behavior and dev Settings routing are
  unchanged.
- Provider capability exposes prompt-caching support without wiring live API
  calls.

### `7.57.4` - AGE graph projection

Scope:

- Enable AGE in the local Supabase/Postgres path or document the exact local
  container limitation.
- Project corpus graph nodes/edges from the 11a seed tables.
- Smoke traversal: CPLH metric -> teaching chapter -> formula context returns
  expected nodes.
- Keep vector-only mode available as fallback insurance, not as the primary
  launch differentiator.

Acceptance:

- Local graph projection or explicit blocker documented.
- Smoke traversal or blocker test evidence reported.
- `11b` gate updated only after graph projection is verified.

## After 7.57

Resume `11a`:

- `11a.8` vector search functions / indexes; default pgvector indexes to HNSW.
- `11a.9` Voyage rerank smoke tests through `RerankProvider`.
- `11a.10a` proxy infrastructure: server-side keys, JWT auth, operator scope.
- `11a.10b` token/rate/monthly cost caps with refusal policy.
- `11a.11` cloud DB apply and content-hash embedding regeneration.

Then continue:

```text
11a resume -> 9.8 -> 9 -> 10a -> 10.5 -> 9.5
-> 7.58 -> 11b -> 9.75 -> 11b.2 -> 10b
-> 7.61 -> 8 -> 8R
```

## Queued Lanes

### `7.58` - Pre-11b Behavioral Alignment

- `7.58.0` Primary Driver decision logic audit.
- `7.58.1` Dollar Impact math and accumulation audit.
- `7.58.2` History/Learn identity decomposition.
- `7.58.3` History coverage decision: 8 weeks vs 60 days.
- `7.58.4` Fixture realism audit.

### `7.61` - Pre-Phase-8 Freshness Audit

- `7.61.0` freshness behavior across all screens.
- `7.61.1` Plan empties-then-populates investigation/fix.
- `7.61.2` swipe-down refresh policy.
- `7.61.3` day/date/shift truth display contract.

### Phase 8

Phase 8 only adds vendor connector writers implementing `DataSourceProvider`
against existing tables/read paths. If Phase 8 needs fixture extraction,
service moves, freshness audits, or behavior decisions, open a `7.57`, `7.58`,
or `7.61` follow-up instead.

## Active References

- `PROJECT_TRACKER.md`
- `docs/CODEX_PROMPT_GENERATION_STANDARD.md`
- `docs/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md`
- `docs/phases/phase_8_gate/`
- `docs/contracts/phase_7_55_architecture_contract.md`
