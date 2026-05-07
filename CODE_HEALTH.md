# Code Health — Open Residuals

The 2026-05-06 audit and its remediation across Waves 0/1/2/3/4 (48 closed findings across 36 PRs) are archived at [`docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`](docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md). This file tracks only what's still open.

Last verified against `origin/master`: 2026-05-07.

---

## Launch readiness — one launch blocker remaining

LB1 (mobile per-operator isolation) and LB2 (vendor sync log redaction) closed in Wave 3 ([#294](https://github.com/SaidKhan005/forge-flow-demo/pull/294), [#302](https://github.com/SaidKhan005/forge-flow-demo/pull/302)). One remains:

1. **Sync worker bare `catch (_)` + missing claim discipline.** `tool/integration_sync_worker/integration_sync_worker.dart:303` still swallows every per-tick exception. Multi-instance Cloud Run double-polls vendors; SQL claim moved behind `SyncWorkerSource` abstraction with no `FOR UPDATE SKIP LOCKED`. Owned by the parallel onboarding lane; deferred to their `.1.*` slices. Confirm with that lane before flipping the launch switch. (Wave 4 also flagged `tool/integration_sync_worker/main.dart:1109` still hardcodes `kPostgresDefaultMaxConnectionsPerPool` — same forbidden-file owner.)

---

## Deferred — partial closure with documented gap

| Finding | What landed | What remains | Why |
|---|---|---|---|
| `lib/services/labor_model.dart:266` decomposition rounding | (none) | Single-atomic-computation derivation of axis dollars; re-pin ~10 exact-equals assertions in `test/labor_model_dollar_attribution_test.dart` | Naive rewrite would have flipped Primary Driver assignments in pinned tests; needs a phase doc that re-pins together |

---

## Confirmed still open — stable shape

These remained open after Waves 0/1/2/3/4:

- **Cost-discipline levers unwired** — caps still 402-fail with no model-downgrade / compression / context-trim / batching / semantic-cache fallback chain.
- **Two-slot key vs `ProxyUsageCounterStore` granularity mismatch** — `usage_logs` keys broader than the counter store's (operator, location, tier, minute_bucket).
- **Audit anchor cron unpause** — operational change (Cloud Scheduler), not code. Worker code is ready.
- **Worker watermark not transactional with adapter writes** (`dispatch.dart:236`). Hot file (parallel onboarding lane).
- **Cadence resolver's resolved value discarded** (`dispatch.dart:373`) — tier assignments observability-only. Hot file (parallel onboarding lane).
- **No common worker base** — every worker re-implements claim loop, error catch, log, alert, metric.

---

## Surfaces moved — re-located 2026-05-07

The fact-check found six audit-cited surfaces had been renamed/restructured. Re-located on current `origin/master`; status updated with the new paths and concern shape:

- **Voyage embedding provider** — STILL OPEN at `lib/services/voyage_embedding_provider.dart` (path moved up one directory; no `embeddings/` folder). Has no chunking, retry, or concurrency cap. The class delegates straight to an injected callback: `VoyageEmbeddingProvider({required VoyageEmbedFn embedFn})` and calls `_embedFn([text], model: modelId)` / `_embedFn(texts, model: modelId)` with no batch-size guard, no retry, no semaphore. Doc at the top says "HTTP/SDK gateway wiring is out of scope here" — gateway hardening still owed.
- **`vector_index_health.activeVectors` re-embed path** — CHANGED. Helper at `tool/vector_index_health/vector_index_health.dart` now exposes `activeVectors` as a required snapshot field, and the production reader at `tool/advisor_proxy/health_producers/vector_producers.dart` (`vectorActiveCountPerCorpusProducer`) queries `select corpus_id::text, active_count::bigint from vector_index_health` against Postgres. The CLI placeholder at `tool/vector_index_health/main.dart:62` still passes `activeVectors: 0`, but it is documented as `'CLI placeholder snapshot — no live DB query was issued'`. The original "no re-embed path on model change" concern has not been re-cited at any callsite; no separate re-embed orchestrator was located.
- **Settings wage authority section** — STILL OPEN at `lib/screens/settings/settings_wage_authority_section.dart` (moved out of `lib/widgets/`). Widget still calls `SqliteWageRoleRowRepository.instance` directly: `_rows = await SqliteWageRoleRowRepository.instance.getRows(restaurantId);` (line 48), `await SqliteWageRoleRowRepository.instance.upsertRow(row);` (line 64), `await SqliteWageRoleRowRepository.instance.deleteRow(id);` (line 67). Recent reworks (`Sync wage role rows to mobile cache`, `Polish admin business team access flow`) did not move the widget off direct SQLite access.
- **Shift dashboard timezone init** — STILL OPEN at `lib/screens/shift_dashboard.dart` (moved from `lib/widgets/`). The widget still owns timezone bootstrap: `bool _tzInitialized = false; void _ensureTzInitialized() { if (_tzInitialized) return; tzdata.initializeTimeZones(); _tzInitialized = true; }` (lines 35-41), called from `_restaurantLocalNow` at line 1243. Service-period bucketing helper `_servicePeriodSlivers(...)` lives in the State class (lines 139, 210). Contract-banned widget responsibility carries forward.
- **Permission keys hand-typed in operator-web screens** — STILL OPEN at `lib/operator_web/screens/**` (the path DOES exist on current master; the fact-check note was incorrect). Sample of 5 screens: `members_screen.dart` declares 7 hand-typed `'team.users.*'` literals at lines 81–99 with no `permission_keys.dart` import; `sessions_screen.dart` (1 hand-typed key, no import); `hierarchy_screen.dart` (2 hand-typed, no import); `audit_log_screen.dart` (2 hand-typed, no import); `roles_screen.dart` (2 hand-typed, but DOES import `../../auth/permission_keys.dart` at line 32). Of 23 screen files, only 3 import `permission_keys.dart` (`custom_role_editor_screen.dart`, `roles_screen.dart`, `permission_explainer_screen.dart`). Concern shape unchanged.
- **`admin_routes.dart`** — STILL OPEN at `lib/admin/admin_routes.dart` (1,953 lines; audit cited ~1,906, +47). Load-bearing monolith concern carries forward.

---

## Structural risks — needs its own phase doc each

- **Monolithic `tool/advisor_proxy/advisor_proxy.dart` — now 15,863 lines** (up from audit's 14,500; +1,363 since 2026-05-06). The "land in a follow-up lane" debt is reaccumulating in the same file.
- **`lib/forge_flow_app.dart` — now 2,482 lines** (up from audit's 2,160; +322).
- **Duplicated abstractions** — three adapter interfaces with identical method shapes; ~12 proxy gateways re-implementing `_postJson + idempotency-key`; four trigger functions with the same body.
- **Two LLM hierarchies** — partially closed (`ProxyLlmProvider` no longer exists). Phase 12 reuse work is reduced but not zero; remaining shape-collapse work between domain `LLMProvider` and the proxy's call paths.
- **SQLite repos as process-global singletons** keyed only by `restaurant_id` — operator-switch leak partially closed by LB1's `DatabaseHelper.forScope` factory; full repo-level scope-keying is a follow-up if a future incident exposes the gap.

---

## Suggested next bites (by leverage)

1. **Verify Launch Blocker #3** — confirm with the parallel onboarding lane what their `.1.*` slices ship for `integration_sync_worker` claim discipline + bare-catch (also pick up the `main.dart:1109` POOL-ENV adoption stragger).
2. **Cost-discipline lever wiring** — model-downgrade / compression / context-trim / batching / semantic-cache fallback chain at the cap-fail path (replaces the hard 402).
3. **`labor_model.dart` rounding rewrite paired with the test re-pin** (deferred L15 sub-task c).
4. **Voyage embedding provider hardening** — chunking + retry + concurrency cap at the HTTP gateway layer.
5. **`shift_dashboard.dart` + `settings_wage_authority_section.dart`** — move timezone init / SQLite calls out of widgets per architecture contract.
6. **Permission-key import sweep across `lib/operator_web/screens/**`** — 20 of 23 screens still hand-type keys.
7. **`advisor_proxy.dart` monolith split** — biggest reviewer-time multiplier, but a project of its own.
