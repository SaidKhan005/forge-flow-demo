# Code Health — Open Residuals

The 2026-05-06 audit and its 2026-05-07 closeout (37 closed findings across 22 PRs) are archived at [`docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`](docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md). This file tracks only what's still open.

Last verified against `origin/master`: 2026-05-07.

---

## Launch readiness — three real blockers

Triaged against the V1 launch posture (inbound integrations + two-console web plane; AI surfaces paused). Two of the original five launch-blockers were silently closed and are listed in the archive; these three remain real on current master.

1. **Mobile operator-switch data leak.** `lib/state/shift_dashboard_notifier.dart:74` reads `restaurantId` once at fetch-start and uses that captured value through to notify with no re-check. Combined with `DatabaseHelper.instance` being hardcoded to `DemoScope.restaurantId` (`lib/infrastructure/persistence/sqlite/database_helper.dart`) and the SQLite repos being process-global singletons keyed only on `restaurant_id`, an operator who switches restaurants on the same device sees stale data until lazy `wipeForOtherScopes` runs. Per CLAUDE.md, per-operator isolation is non-negotiable. Cleanest contract violation in the residual list.

2. **Vendor sync log redaction skipped on Postgres writes.** `lib/infrastructure/persistence/postgres/toast_pos_postgres_sink.dart:139–158` (`appendSyncLog`) writes `payloadPreview` straight into the INSERT with no redactor. The stdout redactor doesn't run on this path. Any vendor body containing PII / secrets persists unredacted to `connector_sync_log`. Compliance-audit risk.

3. **Sync worker bare `catch (_)` + missing claim discipline.** `tool/integration_sync_worker/integration_sync_worker.dart:303` still swallows every per-tick exception. Multi-instance Cloud Run double-polls vendors; SQL claim moved behind `SyncWorkerSource` abstraction with no `FOR UPDATE SKIP LOCKED`. Owned by the parallel onboarding lane; deferred to their `.1.*` slices. Confirm with that lane before flipping the launch switch.

---

## Deferred — partial closure with documented gap

| Finding | What landed | What remains | Why |
|---|---|---|---|
| MFA removal: audit + outbox enqueue post-`markCompleted` not transactional | Deterministic ordering + `markCompleted` row-count guard so re-attempts are idempotent ([#270](https://github.com/SaidKhan005/forge-flow-demo/pull/270)) | True single-tx atomicity needs `EventOutboxRepository.enqueue` to gain an on-executor variant | Outbox API change is its own surface contract — out of L7's three-file scope |
| `lib/services/labor_model.dart:266` decomposition rounding | (none) | Single-atomic-computation derivation of axis dollars; re-pin ~10 exact-equals assertions in `test/labor_model_dollar_attribution_test.dart` | Naive rewrite would have flipped Primary Driver assignments in pinned tests; needs a phase doc that re-pins together |

---

## Confirmed still open — stable shape

These were "out of scope" in the original remediation and remain real on current master:

- **Conflicting `actor_kind` constraint definitions** in migrations `202604280004` + `202604280013` (different constraint names; later migration adds `actor_service_principal_id` not in canonical slice).
- **`phase_8_set_business_date()` is `SECURITY DEFINER`** owned by `forge_admin`, granted EXECUTE to `service_role`. SQL-injection on the proxy that lands a row insert hits BYPASSRLS context as a side effect.
- **`DatabaseHelper.instance` hardcoded to `DemoScope.restaurantId`** (overlaps Launch Blocker #1).
- **Postgres pool size pinned at `kPostgresDefaultMaxConnectionsPerPool = 4`** with no env override (`lib/infrastructure/persistence/postgres/postgres_executor.dart`).
- **Pre-flight token estimate client-supplied** via `cost_telemetry_limit` query param, default 100 (`tool/advisor_proxy/advisor_proxy.dart` near line 13836). Cap is bypassable.
- **Cost-discipline levers unwired** — caps still 402-fail with no model-downgrade / compression / context-trim / batching / semantic-cache fallback.
- **Permission cache invalidation per-process** (`lib/auth/permission_cache.dart:126`) — no Pub/Sub or cross-instance fan-out → silent staleness on horizontal scale-out.
- **`feature_flags` policy `OR (operator_id IS NULL …)`** can't fold into the tenant-leading index (perf concern).
- **Two-slot key vs `ProxyUsageCounterStore` granularity mismatch** — `usage_logs` keys broader than the counter store's (operator, location, tier, minute_bucket).
- **Audit anchor cron unpause** — operational change (Cloud Scheduler), not code. Worker code is ready.
- **Worker watermark not transactional with adapter writes** (`dispatch.dart:236`).
- **Cadence resolver's resolved value discarded** (`dispatch.dart:373`) — tier assignments observability-only.
- **No common worker base** — every worker re-implements claim loop, error catch, log, alert, metric.

---

## Surfaces moved — re-located 2026-05-07

The fact-check noted six audit-cited surfaces had been renamed/restructured. Re-located on current `origin/master`; status updated with the new paths and concern shape:

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
- **SQLite repos as process-global singletons** keyed only by `restaurant_id` — operator-switch leak (overlaps Launch Blocker #1).

---

## Suggested next bites (by leverage)

1. **Launch Blocker #1** — fix the `ShiftDashboardNotifier._load` TOCTTOU + `DatabaseHelper.instance` demo hardcoding. Smallest diff, biggest contract win (per-operator isolation).
2. **Launch Blocker #2** — wire the redactor through `toast_pos_postgres_sink.appendSyncLog`. Compliance posture.
3. **Verify Launch Blocker #3** — confirm with the parallel onboarding lane what their `.1.*` slices ship for `integration_sync_worker` claim discipline + bare-catch.
4. **The `EventOutboxRepository.enqueue` on-executor variant** — closes the L7 deferred residual and unlocks atomic audit/outbox elsewhere.
5. **Re-locate the six "moved" surfaces** to determine true status (one short reading pass).
6. **`labor_model.dart` rounding rewrite paired with the test re-pin** (deferred L15 sub-task c).
7. **`advisor_proxy.dart` monolith split** — biggest reviewer-time multiplier, but a project of its own.
