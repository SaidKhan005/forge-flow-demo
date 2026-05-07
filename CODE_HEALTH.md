# Code Health — Open Residuals

The 2026-05-06 audit and its remediation across Waves 0/1/2/3/4/5 (52 closed findings across 41 PRs) are archived at [`docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`](docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md). This file tracks only what's still open.

Last verified against `origin/master`: 2026-05-08.

---

## Launch readiness — no remaining blockers

LB1 (mobile per-operator isolation) closed Wave 3 ([#294](https://github.com/SaidKhan005/forge-flow-demo/pull/294)). LB2 (vendor sync log redaction across 17 sinks) closed Wave 3 ([#302](https://github.com/SaidKhan005/forge-flow-demo/pull/302)). **LB3 (sync worker bare-catch + claim discipline + POOL-ENV stragger) closed Wave 5** ([#364](https://github.com/SaidKhan005/forge-flow-demo/pull/364)). All three original launch-blocker items are on master. No CODE_HEALTH-tracked launch blockers remain.

---

## Deferred — partial closure with documented gap

| Finding | What landed | What remains | Why |
|---|---|---|---|
| `lib/services/labor_model.dart:266` decomposition rounding | (none) | Single-atomic-computation derivation of axis dollars; re-pin ~10 exact-equals assertions in `test/labor_model_dollar_attribution_test.dart` | Naive rewrite would have flipped Primary Driver assignments in pinned tests; needs a phase doc that re-pins together |
| Worker watermark not transactional with adapter writes (`tool/integration_sync_worker/dispatch.dart:268`) | (none) | Watermark advance must join the same transaction as the adapter write so a crash between the two doesn't redo work | Wave 5 W5-DISPATCH ([#363](https://github.com/SaidKhan005/forge-flow-demo/pull/363)) STOPPED on this sub-task because executor threading would need to flow through `PollIncrementalCommand` → 17 vendor adapters → bespoke sinks. Goes well beyond a one-file diff; needs its own phase doc |

---

## Confirmed still open — stable shape

These remain open after Waves 0/1/2/3/4/5:

- **Cost-discipline levers unwired** — caps still 402-fail with no model-downgrade / compression / context-trim / batching / semantic-cache fallback chain. (AI-paused; activates when AI surfaces un-pause for V1.)
- **Two-slot key vs counter-store granularity mismatch** — `usage_logs` keys broader than the counter store, which keys only on (operator, location, tier, minute_bucket). The runtime interface `ProxyUsageCounterStore` still lives at `tool/advisor_proxy/advisor_proxy.dart:2418`; the concrete Postgres-backed seam was extracted to `AdvisorProxyUsageCounterStore` at `lib/infrastructure/persistence/postgres/advisor_proxy_usage_counter_store.dart:57` (with `proxy_bootstrap.dart:1396` adapting it to the runtime interface). The unique constraint is `(operator_id, location_id, tier_id, minute_bucket)` — same shape, finer billing rows in `usage_logs` aggregate beyond it, so two restaurants on the same operator can still fight over the same rate-limit bucket.
- **Audit anchor cron unpause** — operational change (Cloud Scheduler), not code. Worker code is ready; just needs the cron flipped to active.
- **No common worker base** — every worker re-implements claim loop, error catch, log, alert, metric. Refactor opportunity.
- **Bare `catch (_)` at `tool/integration_sync_worker/backfill_dispatch.dart:368`** — flagged by Wave 5 W5-LB3 ([#364](https://github.com/SaidKhan005/forge-flow-demo/pull/364)) but outside that lane's audit-cite scope. Same shape as the LB3 bug; same fix pattern (`on TimeoutException` / `on Exception` / `on Object` arms with structured logging).

---

## Surfaces moved — re-located 2026-05-07

The fact-check found six audit-cited surfaces had been renamed/restructured. Re-located on current `origin/master`; status updated with the new paths and concern shape:

- **Voyage embedding provider** — STILL OPEN at `lib/services/voyage_embedding_provider.dart` (path moved up one directory; no `embeddings/` folder). Has no chunking, retry, or concurrency cap. The class delegates straight to an injected callback: `VoyageEmbeddingProvider({required VoyageEmbedFn embedFn})` and calls `_embedFn([text], model: modelId)` / `_embedFn(texts, model: modelId)` with no batch-size guard, no retry, no semaphore. Doc at the top says "HTTP/SDK gateway wiring is out of scope here" — gateway hardening still owed. (AI-paused.)
- **`vector_index_health.activeVectors` re-embed path** — CHANGED. Helper at `tool/vector_index_health/vector_index_health.dart` now exposes `activeVectors` as a required snapshot field, and the production reader at `tool/advisor_proxy/health_producers/vector_producers.dart` (`vectorActiveCountPerCorpusProducer`) queries `select corpus_id::text, active_count::bigint from vector_index_health` against Postgres. The CLI placeholder at `tool/vector_index_health/main.dart:62` still passes `activeVectors: 0`, but it is documented as `'CLI placeholder snapshot — no live DB query was issued'`. The original "no re-embed path on model change" concern has not been re-cited at any callsite; no separate re-embed orchestrator was located.
- **Settings wage authority section** — STILL OPEN at `lib/screens/settings/settings_wage_authority_section.dart` (moved out of `lib/widgets/`). Widget still calls `SqliteWageRoleRowRepository.instance` directly. Architecture-contract violation; refactor work.
- **Shift dashboard timezone init** — STILL OPEN at `lib/screens/shift_dashboard.dart` (moved from `lib/widgets/`). Widget still owns timezone bootstrap (`_ensureTzInitialized`) + service-period bucketing (`_servicePeriodSlivers`). Architecture-contract violation; refactor work.
- **Permission keys hand-typed in operator-web screens** — STILL OPEN, partial progress. As of post-Wave 5 the import-sweep count is **10 of 26** screens (up from 3/23 → 7/26 → 10/26 across Waves 4/parallel/5). Wave 5 W5-PKEYS ([#362](https://github.com/SaidKhan005/forge-flow-demo/pull/362)) found that of the originally-counted "19 hand-typing screens", only 3 actually had hand-typed permission-string literals matching catalog constants (`my_account_screen.dart`, `schedule_screen.dart`, `vendor_connections_screen.dart`) — those are now swept. The remaining 16 didn't use permission keys at all (sign-in / onboarding / dialogs / read-only surfaces). **New finding flagged:** 3 screens (`account_screen.dart`, `business_setup_screen.dart`, `business_timing_editor_screen.dart`) hand-type strings in **new namespaces** (`account.configure`, `business_timing.configure`) that aren't in the frozen `lib/auth/permission_keys.dart` catalog. Adding them needs catalog-sync work (the catalog mirrors a contract doc + a seed migration); this is a separate residual, not a sweep.
- **`admin_routes.dart`** — STILL OPEN at `lib/admin/admin_routes.dart` (2,204 lines as of 2026-05-08; audit cited ~1,906, +298 net). Load-bearing monolith; refactor work.

---

## Structural risks — needs its own phase doc each

- **Monolithic `tool/advisor_proxy/advisor_proxy.dart` — 16,949 lines** (up from audit's 14,500; +2,449 net since 2026-05-06). The "land in a follow-up lane" debt is reaccumulating faster than remediation can clean it up.
- **`lib/forge_flow_app.dart` — 1,431 lines** (down from audit's 2,160; −729 net thanks to a parallel refactor between checks). A meaningful chunk of monolith debt was paid down on master without a CODE_HEALTH lane.
- **Duplicated abstractions** — three adapter interfaces with identical method shapes; ~12 proxy gateways re-implementing `_postJson + idempotency-key`; four trigger functions with the same body.
- **Two LLM hierarchies** — partially closed (`ProxyLlmProvider` no longer exists). Phase 12 reuse work is reduced but not zero.
- **SQLite repos as process-global singletons** keyed only by `restaurant_id` — operator-switch leak partially closed by LB1's `DatabaseHelper.forScope` factory; full repo-level scope-keying is a follow-up if a future incident exposes the gap.

---

## Suggested next bites (by leverage)

1. **Audit anchor cron unpause** — flip the Cloud Scheduler switch. Not code; ops work. Highest-leverage zero-code item left.
2. **`backfill_dispatch.dart:368` bare-catch fix** — same pattern as the LB3 fix in Wave 5; small lane.
3. **Catalog additions for `account.configure` + `business_timing.configure` namespaces** — three operator-web screens hand-type strings in new namespaces; adding them to the frozen permission-key catalog (mirroring contract doc + seed migration) finishes the operator-web sweep.
4. **Watermark transactional discipline** — phase doc that threads executor through `PollIncrementalCommand` → 17 vendor adapters → bespoke sinks (deferred from Wave 5).
5. **`labor_model.dart` rounding rewrite** paired with the test re-pin (deferred L15 sub-task c). AI-paused.
6. **Voyage embedding provider hardening** — chunking + retry + concurrency cap. AI-paused.
7. **`shift_dashboard.dart` + `settings_wage_authority_section.dart`** — move timezone init / SQLite calls out of widgets per architecture contract. Refactor.
8. **Cost-discipline lever wiring** — model-downgrade / compression / context-trim / batching / semantic-cache fallback chain. AI-paused.
9. **`advisor_proxy.dart` monolith split** — biggest reviewer-time multiplier; needs its own phase doc.
