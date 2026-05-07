# CODE_HEALTH Audit + Remediation — 2026-05-06

This is the archived historical record of the 2026-05-06 audit and its 2026-05-07 closeout. Active residuals — what's still open — live at `/CODE_HEALTH.md` at the repo root.

---

# Code Health Report

**Audit date:** 2026-05-06
**Branch reviewed:** `master` @ `02072b1`
**Method:** Nine parallel read-only review agents, line-by-line across the major surfaces. No code changes.

---

## Executive Summary

The codebase is **architecturally disciplined but operationally under-finished**. The Phase 9 hardening lane delivered real artifacts: tenant scoping via `OperatorScopedRepository`, RLS wrapper functions, hash-chained audit log, two-tier provider abstractions, idempotent proxy writes, and an 84-migration ledger that mostly honors the time-boundary and index-leading-column contracts. But across nine surfaces the same theme recurs: **fail-closed scaffolds and "land in a follow-up lane" comments are masking real gaps in production wiring** — the response cache is `AlwaysMiss`, the audit anchor's daily Azure Blob write is paused, the cost-discipline levers are unwired, the realtime-bridge DLQ counter never increments, the polling worker has no row-claim discipline, and the secondary LLM has no breaker.

The **single highest-leverage fix** is graceful shutdown on `tool/advisor_proxy/main.dart` — Cloud Run rollover currently severs in-flight idempotency reservations, which compounds with the admin idempotency store's missing TTL into a permanent `409 in_flight` failure mode.

---

## Critical findings (ship-blocker tier)

| # | Surface | File | Issue |
|---|---------|------|-------|
| C1 | Permissions | [role_management_policy.dart:181](lib/auth/role_management_policy.dart) | `operator_owner` can grant `super_admin` / `ff_support` within their tenant — privilege-escalation hole |
| C2 | Auth | [proxy_refresh_token_revoker.dart:62](lib/services/auth/proxy_refresh_token_revoker.dart) | Idempotency key built from `microsecondsSinceEpoch` instead of `Random.secure()` — predictable / collidable |
| C3 | Proxy | [main.dart:635](tool/advisor_proxy/main.dart) | No SIGTERM handler. Cloud Run rollover severs in-flight `commitUsageLog` + `completeRequest` writes |
| C4 | Proxy | [advisor_proxy.dart:12888](tool/advisor_proxy/advisor_proxy.dart) | Admin idempotency `_runAdminIdempotent` has no compute-failure cleanup or TTL — single transient failure pins key to `409 in_flight` forever |
| C5 | Persistence | [users_repository.dart:444,869,887,906](lib/infrastructure/persistence/postgres/repositories/users_repository.dart) | `updateStatus` / `softDelete` / `redactPii` / `bumpRolesVersion` UPDATE without `operator_id` predicate under `withSystem` (BYPASSRLS) |

---

## High-severity findings by surface

### Proxy (`tool/advisor_proxy/`)
- **`advisor_proxy.dart` is 14,500 lines** mixing routing, gateway plumbing, JWT crypto, SQL, CORS — every new slice extends the monolith.
- **`AlwaysMissAdvisorResponseCache`** still in production wiring (`main.dart:325`) — the documented fallback chain (LLM → secondary → **cache** → refusal) is collapsed to (LLM → secondary → refusal).
- **Secondary LLM has no breaker, no per-call timeout, bare-catch error classification** (`advisor_proxy.dart:5067`). A pathological Gemini hang consumes the full per-request budget on every request.
- **Body-size cap is global** (`advisor_proxy.dart:7177`) — graph candidate batch commit will silently 413 once it crosses 1MB.
- **Composite JWT verifier leaks "SP verifier installed" enumeration signal** through error text (`advisor_proxy.dart:869`).

### Auth / MFA / Permissions
- **C1 above** — operator_owner role escalation.
- **Permission cache invalidation is per-process only** (`permission_cache.dart:126`) — silent staleness on any horizontal scale-out.
- **Recovery code TOCTOU**: rate-limit `check` and `recordAttempt` are non-atomic (`recovery_code_attempt_limiter.dart:149`); two parallel attempts can both pass the limiter.
- **Recovery-code consumer linear scan with early break** leaks slot position via timing (`recovery_code_consumer.dart:108`).
- **Salt-less SHA-256 password-history hash** (`repository_password_history_check.dart:38`) — credential oracle on table leak.
- **HIBP roundtrip fires before shape validation** (`password_change_service.dart:80`) — invalid-input attacks starve the per-process budget.
- **reCAPTCHA policy ignores `challengeTs` freshness** (`recaptcha_v3_verifier.dart:116`) — token replay possible.
- **MFA enrollment finalize re-queries `accounts:lookup` for "newest" factor** (`identity_toolkit_firebase_mfa_client.dart:174`) instead of reading the response — race against parallel enrollment.
- **GDPR pending-erasure approvals have no expiry** (`gdpr_erasure_service.dart:96`) — 6-month-old approval pairs with fresh approval today.

### Domain services / scheduling
- **`BaselineData` (in `lib/dev/`) is mutated and read by canonical services** — `TargetCycleService`, `BaselineManagerService`, `BenchmarkTrackerReadService`, `LearnBenchmarkContextService`, `BaselineSelectionAnalyticsService` all import the demo fixture global. Layer 3 authority leaks through a dev-folder static.
- **`weekly_plan_snapshot_service.dart:215` day-row rotation assumes Mon-first** with no assertion. Drift in `SchedulePlanResolver._defaultDayWeights` would silently desync business dates from day labels.
- **`cycleId` collision** — `target_cycle_service.dart:283` uses `millisecondsSinceEpoch`, two replacement writes within one ms silently overwrite via upsert.
- **`labor_model.dart:266` decomposition rounds 5 intermediate model-hour values independently** then derives axis dollars — accumulated rounding can flip Primary Driver assignment. The 7.58 "honest dollar attribution" contract rests on this.
- **`schedule_plan_resolver.dart:1` (Layer 7 domain) imports `lib/services/labor_model.dart`** — domain depending on services.

### Integrations / outbox
- **Worker watermark is not transactional with adapter writes** (`dispatch.dart:236`). Vendor double-writes are absorbed only if every adapter implements idempotency correctly — unverifiable per-adapter discipline.
- **Sync worker has no row claim** (`integration_sync_worker.dart:296`) — multi-instance Cloud Run double-polls vendors, burns rate-limit budget, doubles `connector_sync_log` rows. Same loop also swallows every per-tick exception with `catch (_)`.
- **Cadence resolver's resolved value is discarded** (`dispatch.dart:373`) — tier assignments are observability-only today.
- **Webhook synthetic event-id grows attempts table unboundedly** (`inbound_webhook_handler.dart:565`) — random-payload spam never dead-letters.
- **`CanonicalSink.appendSyncLog` accepts arbitrary maps** (`canonical_sink.dart:120`) without redaction or schema; the stdout redactor doesn't run on Postgres-bound writes.

### Migrations / RLS
- **Audit-anchor cadence is paused** — `202605061700_hardening_audit_anchor_daily_schedule.sql` only NOTIFYs; Cloud Scheduler is paused per the migration's own header. The hash chain alone bounds tamper detection only after-the-fact.
- **`usage_logs` constraint flip in `202604280006_c`** is a full table rewrite (`ADD COLUMN ... NOT NULL DEFAULT gen_random_uuid()` is `ACCESS EXCLUSIVE`).
- **6 duplicate basename prefixes** (`202605010000`, `202605020001`, `202605040400`, `202605050400`, `202605060000`, `202605061700`) — apply order is fragile; the drift scanner doesn't reject duplicate prefixes.
- **Conflicting `actor_kind` definitions** — `202604280004:219` and `202604280013:10` define the constraint twice with different names; the later migration also adds `actor_service_principal_id` not in the canonical slice.
- **8 fact-table indexes shipped without `operator_id` leading** in `202605040000`; rekey landed 37 days later in `202605061500`.
- **`feature_flags` policy `OR (operator_id IS NULL …)`** can't fold into the tenant-leading index.
- **`phase_8_set_business_date()` is `SECURITY DEFINER` owned by forge_admin** and granted EXECUTE to `service_role` (`202605050400`) — a SQL-injection on the proxy that lands a row insert hits BYPASSRLS context as a side effect.

### Persistence
- **C5 above** — UsersRepository BYPASSRLS UPDATEs without `operator_id`.
- **Cross-tenant scans** — `firebaseUidForUserSystem`, `findActiveUserIdByFirebaseUidSystem`, `findMfaRecoveryTargetByEmail` walk every tenant's rows.
- **SQLite repos as process-global singletons keyed only by `restaurant_id`** (`sqlite_shift_record_repository.dart:6`). Operator switch on a shared device leaks until lazy `wipeForOtherScopes` runs.
- **`DatabaseHelper.instance` hardcoded to `DemoScope.restaurantId`** — non-demo callers silently hit the demo scope.
- **Pool sizing pinned at 4** (`postgres_executor.dart:34`) with no production-tuning surface; first real load incident will be a multi-day debug.

### AI providers / cache / caps
- **Two parallel LLM hierarchies** — `LLMProvider` (`lib/domain/services/llm_provider.dart:64`) vs `ProxyLlmProvider` (`advisor_proxy.dart:4823`) with overlapping but incompatible shapes. Phase 12 reuse is contingent on collapsing them.
- **Anthropic prompt caching is computed but never sent on the wire** — `advisor_proxy.dart:4800` emits the right shape, `anthropic_http_complete_fn.dart:98` sends `system: context` as a flat string. The `prompt_cache_hit_rate` metric will sit at 0%.
- **No cost-discipline levers wired** — caps fail hard at 402; no model downgrade, no compression, no context trim, no batching, no semantic-cache fallback.
- **Pre-flight token estimate is client-supplied via query string** (`advisor_proxy.dart:7446`), default `100`. The request-token cap is bypassable.
- **Two-slot key vs counter store granularity mismatch** — `usage_logs` keys on (operator, billing-org, scoped-org, location, staff, workflow, class, period); `ProxyUsageCounterStore` keys only on (operator, location, tier, minute_bucket).
- **Voyage embeddings have no chunking, no retry, no concurrency limit** (`voyage_embedding_provider.dart:46`).
- **No re-embed path on model change** — `vector_index_health` returns hard-coded `activeVectors: 0`.
- **`defaultAnthropicOnlineCheck` uses dart-defined API key** (`advisor_model_config_service.dart:159`) — violates Hard Promise #7 ("no BYO-key"); a stray `--dart-define` in a build ships the key in the client binary.

### UI / Flutter
- **`lib/widgets/daypart_table.dart:3` imports `lib/dev/demo_fixture_data.dart`** — prod widget pulling demo seed.
- **5 widgets import frozen `lib/data/`** — `data_alignment_audit_panel.dart`, `input_metric_card.dart`, `lever_card.dart`, `week_history_tile.dart`, blocking the "delete-only" promise.
- **`settings_wage_authority_section.dart:48,64,67`** calls `SqliteWageRoleRowRepository.instance` directly from a widget — bypasses the service layer.
- **`shift_dashboard.dart:36`** owns timezone init and service-period bucketing (contract-banned).
- **`ShiftDashboardNotifier._load`** (`lib/state/shift_dashboard_notifier.dart:69`) doesn't validate active restaurant id between fetch start and notify — operator switch can leak prior-restaurant data.
- **Permission keys hand-typed in widgets** instead of imported from `lib/auth/permission_keys.dart` — at least 12 sites in `lib/operator_web/screens/**` and `lib/forge_flow_app.dart`.
- **`forge_flow_app.dart` is 2,160 lines, `admin_routes.dart` 1,906 lines, 8 admin screens > 1,500 lines** — load-bearing files where every new surface forces a touch.

### Workers
- **OAuth refresh cron has no claim discipline** (`oauth_refresh_cron.dart:185`) — concurrent refreshes race on vendor refresh-token rotation; auto-disable triggers on healthy connections.
- **MFA removal worker has no retry cap, no DLQ** (`mfa_removal_worker.dart:123`). Poison-pill removals re-claim forever every 5–15 min.
- **MFA removal: audit-log + outbox enqueue happen AFTER `markCompleted`** (`mfa_removal_worker.dart:65`) outside the same transaction — partial completions silently drop audit/outbox events.
- **Realtime bridge DLQ is theatre** (`realtime_bridge.dart:425`) — `attempt_count` is never incremented; `_dlqCap` will never be reached. Poison-pills recycle until 7-day retention deletes them.
- **Audit anchor verify can't recover from crashed-write state** (`audit_anchor.dart:1101`).
- **Audit anchor sweep has no advisory-lock guard** — Cloud Scheduler retry storm produces a thundering herd.
- **Email outbox dispatcher reverse-engineers failure kind from string `.contains`** (`email_outbox_dispatcher.dart:381`).
- **No common worker base** — every worker re-implements claim loop, error catch, log, alert, metric. Adding a worker is ~200 LOC of boilerplate.

---

## Structural risks (the deepest concerns)

1. **Monolithic `advisor_proxy.dart`** (14.5k lines, growing). Every Codex review of this file pays a re-read tax; every new slice copies a 50-line route block.
2. **Duplicated abstractions** — two LLM hierarchies, three adapter interfaces with identical method shapes, ~12 proxy gateways re-implementing `_postJson + idempotency-key`, four trigger functions with the same body, three `bridgeFallback` patterns reading `BaselineData`. The system pays the cost of abstractions but keeps the duplication that forced them in.
3. **"Land in a follow-up lane" debt** — `AlwaysMissAdvisorResponseCache`, paused audit anchor, 5 unwired cost-discipline levers, no cron-tick observability, `consecutive_poll_failures` not tracked, missing retention sweeps for `proxy_requests` / `auth_login_attempts`, MFA gates pinned to `false` until session-claim resolver lands. Each is documented as v1 scaffold; cumulatively they erode the "ship-ready" claim.
4. **`lib/dev/` leaking into production paths** — `BaselineData` mutated by canonical services; `daypart_table.dart` importing demo fixtures; `DatabaseHelper.instance` baked to `DemoScope.restaurantId`. The demo-mode-is-writer-side promise is cosmetically true but operationally broken.
5. **No graceful shutdown story across the fleet** — proxy listener, sync worker, OAuth refresh, MFA worker, email dispatcher all bind a loop and never register SIGTERM handlers. Cloud Run revision rollover terminates work mid-tx, leaving orphan reservations, stuck-claim rows, and missing audit events.

---

# Plain-English Version

## What's the headline?

**The blueprint is solid. The wiring isn't done.**

The team built this app like a real piece of infrastructure — there's careful work to keep different restaurant operators' data isolated, an audit log that proves nothing was tampered with, and pluggable AI providers so swapping Claude for Gemini is one wire change. The architecture documents are taken seriously and most of the code follows them.

But underneath that, there are a lot of TODOs that are silently wired into production. Several big features look complete but are actually placeholders that fail safely. They don't crash — they just don't do what their names suggest.

## What's seriously broken

1. **A restaurant owner can promote themselves to "super admin."** The code that checks who can hand out admin powers has a missing line — when an owner tries to grant the highest-level role, nothing stops them.
2. **One internal "request id generator" uses the clock instead of randomness.** Two near-simultaneous requests can collide. Every other generator in the codebase uses real randomness; this one is the odd one out.
3. **The "I'm shutting down gracefully" handler doesn't exist on the main server.** When Google's hosting platform updates the server (which happens routinely), in-flight work gets cut off mid-sentence. Some of those cuts leave database rows in a weird stuck state that has to be manually fixed.
4. **The "if this fails, retry it" feature on admin actions doesn't clean up after itself.** A single network blip can permanently freeze an action with a "still in progress" message. No automatic recovery.
5. **A few database operations could affect the wrong restaurant.** The system has two layers of defense for keeping restaurants' data separate. Five specific operations skip the first layer and rely entirely on the second. If the second layer has any bug, restaurants leak into each other.

## What's quietly broken

- **The "AI response cache" is a fake.** It returns "miss" every time. The system was supposed to fall back to cached answers when both Claude and Gemini are down — that fallback doesn't exist. Operators just see an error.
- **Anthropic's prompt-caching feature is half-wired.** The code computes the right caching markers and tests them, but the actual network call sends the prompt without them. The cost-savings dashboard will read 0% forever.
- **The "cost discipline levers" on the spec sheet aren't built.** When an operator hits their monthly AI spend cap, the system fails hard with "402 Payment Required" instead of gracefully downgrading to a cheaper model.
- **The audit log's "tamper-proof" daily backup to Azure isn't running.** The hash chain part works — you can prove individual rows weren't changed — but the daily anchor that bounds *when* tampering could have happened is paused.
- **The integration sync worker silently swallows errors.** If something crashes in the polling loop, you'll see no log, no metric, no alert. The system reports "healthy" while doing nothing.
- **The OAuth refresh worker has a race condition.** If two copies run at the same time (which Google's platform can cause on retries), they'll both refresh the same token, and the vendor will invalidate one of them. After three races in a row, the connection is auto-disabled — for healthy users.
- **The "dead-letter queue" for the realtime publisher is theater.** A counter that's supposed to move messages to a dead-letter table after 5 failures never increments — so dead-lettering literally never happens.
- **The MFA removal worker has no retry cap.** A removal request that always fails will retry every 5–15 minutes forever, with no escalation, no alert, no manual triage path.

## What's just messy

- **The main proxy server file is 14,500 lines.** It mixes routes, security, database queries, and UI helpers. Every new feature pile-ons more code at the bottom. A targeted cleanup would unlock parallel work and reduce review time dramatically.
- **A handful of "demo mode" leftovers leaked into production code.** Demo seed data is read by real services; one production widget imports the demo fixtures file directly; the legacy database helper is hardcoded to the demo restaurant. The "demo mode is just a switch" promise isn't quite true in code.
- **Permission strings are hand-typed across the UI** instead of using the central catalog. Renaming a permission means editing dozens of files with no compiler help.
- **Six pairs of database migration files have identical timestamps.** They sort by filename, which is fragile. A rename can change apply order.
- **Most servers don't shut down cleanly.** They all loop forever, none of them respond to "please stop" signals from the platform. Whenever Google rolls out an update, in-progress work gets killed.

## What's actually good (don't lose this)

- The contract framework — the layer model, the time-boundary rules, the index-leading-column rule, the per-tenant repository pattern — is internally consistent and the team mostly follows it.
- Service principals and the JWT verifier composite are well-designed.
- The audit log's hash-chain implementation is correct (the anchor side is the gap).
- Idempotency keys are written to a UNIQUE table on the proxy — when the right caller is generating the key.
- RLS policies use `STABLE LEAKPROOF PARALLEL SAFE` wrapper functions — the right pattern.
- Tests around cache breakpoints, idempotency, and JWT verification exist and pass.
- Failure posture is mostly fail-closed (refuse rather than silently approve), which is the right default.

## What to do first (in order)

1. **Add SIGTERM handlers to every long-running process** — this fixes the largest class of "weird stuck state" bugs in one shot.
2. **Add `expires_at` to the admin idempotency table** — clears the permanent-`409` failure mode.
3. **Fix the `operator_owner` role grant escalation** — small code change, large security hole closed.
4. **Add `FOR UPDATE SKIP LOCKED` to the polling worker and OAuth refresh queries** — single-line fix that prevents double-polling and broken vendor connections at horizontal scale.
5. **Make the salt-less password-history hash salted-and-peppered** — credential-leak posture.
6. **Land the real response cache** before the next provider outage exposes the placeholder.
7. **Wire the audit anchor's daily Azure write** — without it, the tamper-evidence story has an unbounded gap.
8. **Stop importing `lib/dev/` from production code paths** — small refactor, restores the "demo is a switch" claim.

The code was built with good instincts. The next sprint of work isn't more architecture — it's finishing the wiring on what's already there.

---

# Resolution log — closed via Wave 0/1/2 remediation (2026-05-07)

The audit was remediated via 16 parallel-lane PRs across two waves of worktrees plus four follow-up PRs (M4 schema, L10/L12 test fixups, gateway-pepper threading, and the closeout doc). Two findings closed only partially with documented residuals; two more were silently closed by the parallel onboarding lane after the closeout was written.

Verified against `origin/master` 2026-05-07: every closed item below is present on master — zero regressions.

## Closed via remediation

| Finding | PR(s) | Lane |
|---|---|---|
| C1 — operator_owner role escalation | [#249](https://github.com/SaidKhan005/forge-flow-demo/pull/249) | L1 |
| C2 — Random.secure() idempotency in proxy_refresh_token_revoker | [#250](https://github.com/SaidKhan005/forge-flow-demo/pull/250) | L2 |
| C3 — proxy SIGTERM (and worker SIGTERMs across the fleet) | [#255](https://github.com/SaidKhan005/forge-flow-demo/pull/255), [#270](https://github.com/SaidKhan005/forge-flow-demo/pull/270), [#254](https://github.com/SaidKhan005/forge-flow-demo/pull/254), [#256](https://github.com/SaidKhan005/forge-flow-demo/pull/256) | L4 + L7 + L9 + L8 |
| C4 — admin idempotency `expires_at` + reclaim + sweep | [#207](https://github.com/SaidKhan005/forge-flow-demo/pull/207) (schema) + [#255](https://github.com/SaidKhan005/forge-flow-demo/pull/255) (code) | M1 + L4 |
| C5 — UsersRepository operator_id predicates + cross-tenant scan flag | [#251](https://github.com/SaidKhan005/forge-flow-demo/pull/251) | L3 |
| Secondary LLM circuit breaker + 8 s timeout + typed errors | [#255](https://github.com/SaidKhan005/forge-flow-demo/pull/255) | L4 |
| Body-size cap per route (16 MB graph batch, 1 MB everywhere else) | [#255](https://github.com/SaidKhan005/forge-flow-demo/pull/255) | L4 |
| Composite JWT verifier enumeration leak collapsed | [#255](https://github.com/SaidKhan005/forge-flow-demo/pull/255) | L4 |
| AlwaysMissAdvisorResponseCache → Postgres-backed cache + 24 h TTL | [#258](https://github.com/SaidKhan005/forge-flow-demo/pull/258) | L14 |
| Recovery code TOCTOU collapsed into atomic check+record | [#261](https://github.com/SaidKhan005/forge-flow-demo/pull/261) | L10 |
| Recovery-code consumer constant-time scan (no early break) | [#261](https://github.com/SaidKhan005/forge-flow-demo/pull/261) | L10 |
| reCAPTCHA `challengeTs` 60 s freshness gate | [#261](https://github.com/SaidKhan005/forge-flow-demo/pull/261) | L10 |
| HIBP roundtrip moved after shape validation | [#261](https://github.com/SaidKhan005/forge-flow-demo/pull/261) | L10 |
| Salt-less SHA-256 password-history hash → per-row salt + global pepper | [#206](https://github.com/SaidKhan005/forge-flow-demo/pull/206) (schema) + [#257](https://github.com/SaidKhan005/forge-flow-demo/pull/257) (code) + [#267](https://github.com/SaidKhan005/forge-flow-demo/pull/267) (gateway threading) | M2 + L12 + gateway-pepper |
| MFA enrollment finalize race (read factor from response, not lookup) | [#252](https://github.com/SaidKhan005/forge-flow-demo/pull/252) | L11 |
| GDPR pending-erasure approvals 14-day expiry | [#252](https://github.com/SaidKhan005/forge-flow-demo/pull/252) | L11 |
| Realtime bridge DLQ counter increments + row moves to dead-letter | [#256](https://github.com/SaidKhan005/forge-flow-demo/pull/256) | L8 |
| Email outbox dispatcher typed error union (no string `.contains`) | [#256](https://github.com/SaidKhan005/forge-flow-demo/pull/256) | L8 |
| MFA removal worker retry cap (10) + DLQ + `dead_lettered_at` | [#265](https://github.com/SaidKhan005/forge-flow-demo/pull/265) (schema) + [#270](https://github.com/SaidKhan005/forge-flow-demo/pull/270) (code) | M4 + L7 |
| Audit anchor crash-recovery roll-forward | [#210](https://github.com/SaidKhan005/forge-flow-demo/pull/210) (schema) + [#254](https://github.com/SaidKhan005/forge-flow-demo/pull/254) (code) | M3 + L9 |
| Audit anchor `pg_advisory_lock` sweep guard | [#210](https://github.com/SaidKhan005/forge-flow-demo/pull/210) (schema) + [#254](https://github.com/SaidKhan005/forge-flow-demo/pull/254) (code) | M3 + L9 |
| Audit anchor daily Azure Blob manifest write | [#210](https://github.com/SaidKhan005/forge-flow-demo/pull/210) (schema) + [#254](https://github.com/SaidKhan005/forge-flow-demo/pull/254) (code) | M3 + L9 |
| Anthropic prompt cache control on the wire (structured `system`) | [#253](https://github.com/SaidKhan005/forge-flow-demo/pull/253) | L13 |
| `defaultAnthropicOnlineCheck` dart-define API key removed (Hard Promise #7) | [#253](https://github.com/SaidKhan005/forge-flow-demo/pull/253) | L13 |
| `BaselineData` promoted out of `lib/dev/` to a Layer 3 service | [#276](https://github.com/SaidKhan005/forge-flow-demo/pull/276) | L15 |
| `schedule_plan_resolver` Layer 7 import of `labor_model` removed | [#276](https://github.com/SaidKhan005/forge-flow-demo/pull/276) | L15 |
| `target_cycle_service` `cycleId` is 128-bit hex (not `millisecondsSinceEpoch`) | [#276](https://github.com/SaidKhan005/forge-flow-demo/pull/276) | L15 |
| `weekly_plan_snapshot_service` Mon-first throw guard | [#276](https://github.com/SaidKhan005/forge-flow-demo/pull/276) | L15 |
| `daypart_table.dart` no longer imports `lib/dev/` | [#276](https://github.com/SaidKhan005/forge-flow-demo/pull/276) | L15 |
| Dependent test fixups (collateral from L10 + L12) | [#264](https://github.com/SaidKhan005/forge-flow-demo/pull/264) | follow-up |
| MFA test fake signature drift after L3 + L7 | [#280](https://github.com/SaidKhan005/forge-flow-demo/pull/280) | follow-up (Codex) |

## Closed silently by parallel work after the closeout

- **L6 OAuth refresh claim discipline** — closed by [#281](https://github.com/SaidKhan005/forge-flow-demo/pull/281) (parallel onboarding lane's Cloud Run refresh worker). `tool/oauth_refresh_worker/main.dart` uses `FOR UPDATE SKIP LOCKED` so concurrent refreshes never race on the same row.
- **Webhook synthetic event-id unbounded growth** — closed in `lib/services/integration/inbound_webhook_handler.dart`: `_vendorEventIdOrSynthetic()` now hashes the payload deterministically (no random UUID), framework dead-letters at attempt 3.
- **5 widgets importing frozen `lib/data/`** — closed; zero such imports remain on master. Resolved incidentally by other UI work.
- **6 duplicate `YYYYMMDDHHMM` migration prefixes** — not present on current master.
- **`ProxyLlmProvider`** — no longer exists as a separate abstract class, leaving `LLMProvider` as the single hierarchy. Phase 12 collapse work is reduced.

## Skipped (other Claude account owns these surfaces)

- **L5** — sync worker SIGTERM + `FOR UPDATE SKIP LOCKED` + claim discipline + bare-catch fix. Files: `lib/services/integration/integration_sync_worker.dart`, `tool/integration_sync_worker/**`. **Bare-catch + claim discipline still open** as of 2026-05-07; deferred to `.1.*` lanes.

## Closeout PRs

- [#278](https://github.com/SaidKhan005/forge-flow-demo/pull/278) Resolution table + PROJECT_TRACKER "Now" bullet (2026-05-07).
- [#284](https://github.com/SaidKhan005/forge-flow-demo/pull/284) Fact-check addendum vs current master (2026-05-07).
- [#285](https://github.com/SaidKhan005/forge-flow-demo/pull/285) Archive split — moved audit + closeout history here; trimmed `/CODE_HEALTH.md` to the open-residuals tracker.

---

# Wave 3 closures (2026-05-07)

A second remediation wave landed nine parallel lanes against the residuals from the original audit. Seven closed cleanly; two closed partially with documented gaps and one corrected an audit misdiagnosis.

## Closed via Wave 3

| Finding | PR | Lane |
|---|---|---|
| Launch Blocker #1 — Mobile per-operator isolation (`ShiftDashboardNotifier._load` TOCTTOU + `DatabaseHelper.instance` demo hardcoding) | [#294](https://github.com/SaidKhan005/forge-flow-demo/pull/294) | LB1 |
| Launch Blocker #2 — Vendor sync log redaction (all 17 vendor Postgres sinks now redact `payloadPreview` before INSERT via shared `encodePayloadPreviewForSyncLog` helper) | [#302](https://github.com/SaidKhan005/forge-flow-demo/pull/302) | LB2 (re-scoped) |
| Deferred #1 — MFA removal post-`markCompleted` atomicity (`EventOutboxRepository.enqueueInTransaction` + `markCompletedInTransaction`; MFA worker now atomic) | [#299](https://github.com/SaidKhan005/forge-flow-demo/pull/299) | OUTBOX-TX |
| Conflicting `actor_kind` constraint definitions (`202604280004` + `202604280013`) — predicates were semantically identical; consolidation migration drops both old names and re-creates a single canonical `auth_events_audit_actor_kind_check` | [#289](https://github.com/SaidKhan005/forge-flow-demo/pull/289) | ACTOR-KIND |
| `phase_8_set_business_date()` SECURITY DEFINER blast radius (REVOKE EXECUTE from `service_role`; added `tg_argv[0]` allowlist + explicit `timestamptz` cast; function only called by triggers, no app-code path) | [#291](https://github.com/SaidKhan005/forge-flow-demo/pull/291) | BIZ-DATE-SEC |
| Re-locate the six "moved" surfaces (5 STILL OPEN at new paths; 1 CHANGED; CODE_HEALTH.md "Surfaces moved" section rewritten with current evidence) | [#293](https://github.com/SaidKhan005/forge-flow-demo/pull/293) | RELOCATE |
| `cost_telemetry_limit` query param "bypassable token cap" — closed as audit misdiagnosis (it's a row-count `LIMIT` for the admin observability dashboard, server-clamped to `[1, 100]`); the actual no-token-cap gap on outbound LLM calls is recorded as a separate residual | [#300](https://github.com/SaidKhan005/forge-flow-demo/pull/300) | TOKEN-CAP doc |

## Closed partially in Wave 3 (mechanism in place, adoption / producer side pending)

| Finding | What landed in Wave 3 | What still needs to land | PR |
|---|---|---|---|
| Postgres pool size pinned at 4 with no env override | Top-level `resolvePostgresMaxConnectionsPerPool({Map<String, String>? environment})` resolver reading `POSTGRES_POOL_MAX_CONNECTIONS` env var with default fallback + sane upper bound (200) | Pool-factory call sites still use the const default; need to thread the resolver call through actual construction sites so deployments can tune the pool | [#290](https://github.com/SaidKhan005/forge-flow-demo/pull/290) |
| Permission cache invalidation per-process | LISTEN side: `PermissionCacheInvalidationListener` consumes the `permission_cache_invalidate` Postgres NOTIFY channel and calls `cache.invalidateUser(userId)` on each event; channel + payload contract documented in migration `202605080500_permission_cache_invalidation_channel.sql` | NOTIFY producers — every permission-write site (role grants/revokes, `roles_version` bumps in `users_repository.dart` / `user_roles_repository.dart`) needs to emit `pg_notify('permission_cache_invalidate', json_object(...))` after commit | [#292](https://github.com/SaidKhan005/forge-flow-demo/pull/292) |

## Wave 3 lane discoveries worth noting

- **LB2 surface area was wider than the audit cited.** The audit pointed at `toast_pos_postgres_sink.dart:139–158`. Investigation found the same bug pattern across **17 vendor Postgres sinks** (POS / Labor / Reservation), with `seven_shifts_postgres_sink.dart` carrying three insert sites. The first agent stopped at the threshold rule; the re-scoped lane fixed all 17 via a shared `_postgres_sink_log_helpers.dart` private helper to prevent drift on sink #18.
- **OUTBOX-TX needed one more file.** The lane prompt scoped `event_outbox_repository.dart` + `mfa_removal_worker.dart` + tests. The agent correctly added `markCompletedInTransaction` to `mfa_factor_removal_requests_repository.dart` as well, since true atomicity required the row-update + audit-insert + outbox-enqueue all on the same executor.
- **TOKEN-CAP misdiagnosis.** The original audit pointer (`advisor_proxy.dart:7446`, default `100`, "cap is bypassable") matched a row-count LIMIT for the admin observability dashboard, not a token cap. The actual concern (no per-request token cap exists at all on the proxy's outbound LLM call sites at `advisor_proxy.dart:8485-8700`) is a NEW residual.
- **`DatabaseHelper.instance` had zero production callers.** Only 6 test files referenced it. The wider call-site sweep the LB1 lane was prepared to handle wasn't needed — the deprecation can land at any time.

## Wave 3 closeout PR

- [#345](https://github.com/SaidKhan005/forge-flow-demo/pull/345) — archive PR that recorded the Wave 3 closures and trimmed `/CODE_HEALTH.md` to remove the now-closed items.

---

# Wave 4 closures (2026-05-07)

A fourth remediation wave landed four parallel lanes against the residuals from Wave 3 (the two partial-closures + two of the still-open structural concerns). All four closed cleanly.

## Closed via Wave 4

| Finding | PR | Lane |
|---|---|---|
| Postgres pool size env override **adoption gap** — `resolvePostgresMaxConnectionsPerPool()` resolver landed in [#290](https://github.com/SaidKhan005/forge-flow-demo/pull/290) but pool-factory call sites still hardcoded the const. Wave 4 wired the resolver into 5 production pool-factory call sites: `oauth_refresh_worker/main.dart`, `audit_anchor/main.dart`, `first_connect_backfill_worker/main.dart`, `proxy_bootstrap.dart` (two sites), `cutover/preflight_smoke.dart`. `POSTGRES_POOL_MAX_CONNECTIONS` env override now actually takes effect. | [#347](https://github.com/SaidKhan005/forge-flow-demo/pull/347) | POOL-ENV-ADOPT |
| Permission cache cross-instance invalidation **producer gap** — listener wired in [#292](https://github.com/SaidKhan005/forge-flow-demo/pull/292) but no production code published to the channel. Wave 4 emits `pg_notify('permission_cache_invalidate', @payload)` at all 4 permission-mutating write sites (`user_roles_repository.dart`: `insertGrant`, `revokeGrant`, `bumpActiveGrantHoldersForRole` — fans out one NOTIFY per affected user via `RETURNING user_id`; `users_repository.dart`: `bumpRolesVersion`). All emits inside the `withTenant`/`withSystem` transaction so NOTIFY is atomic with the write. Parameter-bound JSON, never concatenated. Cross-instance cache invalidation is now end-to-end. | [#349](https://github.com/SaidKhan005/forge-flow-demo/pull/349) | PCACHE-FANOUT-PRODUCERS |
| **No per-request token cap on outbound LLM calls** — recorded as a residual after Wave 3's TOKEN-CAP misdiagnosis correction. Wave 4 added a hard cap of 100k tokens (env-overridable via `MAX_TOKENS_PER_REQUEST`, upper bound 1M) on outbound LLM dispatch in `advisor_proxy.dart`. HTTP 413 + `request_too_large` error returns both the estimate and the cap so clients can shrink. Single insertion point covers both wired-pipeline and unwired-fallback paths; cap is independent of `PolicyTier.maxRequestTokens` so misconfigured deploys can't bypass. | [#348](https://github.com/SaidKhan005/forge-flow-demo/pull/348) | TOKEN-CAP-REAL |
| `feature_flags` policy `OR (operator_id IS NULL …)` can't fold into the tenant-leading index — Wave 4 introduced sentinel UUID `00000000-...` via `feature_flag_scope_sentinels` constants table + a `STABLE LEAKPROOF PARALLEL SAFE` reader function. RLS policy rewritten without `IS NULL` so the tenant-leading index folds. Existing system-wide rows backfilled; `operator_id NOT NULL` set via `NOT VALID` + `VALIDATE`. Four call-site swaps (one over the soft cap; agent flagged each was a mechanical one-line predicate change that couldn't be skipped). | [#350](https://github.com/SaidKhan005/forge-flow-demo/pull/350) | FF-POLICY-FOLD |

## Wave 4 lane discoveries worth noting

- **POOL-ENV adoption found a stragger.** The forbidden file `tool/integration_sync_worker/main.dart:1109` (owned by the parallel onboarding lane) still hardcodes `kPostgresDefaultMaxConnectionsPerPool`. Flagged in the lane's PR body for the parallel lane to pick up.
- **TOKEN-CAP-REAL found a second `UsageEstimate` site that doesn't dispatch.** Line 8773 (`/v1/usage/smoke`) is a usage-counter smoke test that doesn't dispatch LLM, so no cap needed. The cap insertion at line 8964 covers both real dispatch paths (wired pipeline + unwired fallback).
- **FF-POLICY-FOLD needed a synthetic operators row.** The existing `feature_flags.operator_id -> operators(operator_id)` FK forced the migration to seed an operators row at the sentinel UUID before the backfill, so the FK accepts the new value. Documented in the migration header.

## Wave 4 closeout PR

- [#354](https://github.com/SaidKhan005/forge-flow-demo/pull/354) — archive PR that recorded the Wave 4 closures and trimmed `/CODE_HEALTH.md`.

---

# Parallel-master delta recorded 2026-05-08

A 2026-05-08 fact-check against `origin/master` confirmed all 8 active CODE_HEALTH residuals are still open in the same shape, with two things shifting on master between the Wave 4 closeout and 2026-05-08 that are worth recording here for the historical record:

## Adjacent BYPASSRLS hardening (parallel work, not a CODE_HEALTH lane)

PR [#304](https://github.com/SaidKhan005/forge-flow-demo/pull/304) (`ops-debt.bypassrls-predicates`) applied the same `operator_id`-predicate-on-BYPASSRLS-UPDATE pattern that L3 ([#251](https://github.com/SaidKhan005/forge-flow-demo/pull/251)) introduced on `users_repository.dart` to three additional tables: `auth_sessions`, `password_history`, `auth_invites`. The pattern is now applied across seven BYPASSRLS UPDATE surfaces, not the four L3 covered. Defense-in-depth posture got broader without a CODE_HEALTH lane asking for it.

## Monolith refactor (parallel work, paid down significant debt)

Between 2026-05-07 and 2026-05-08, `lib/forge_flow_app.dart` shrunk from **2,482 → 1,431 lines** (−1,051 lines in one refactor). Net reduction from audit baseline (2,160 lines) is now **−729 lines**. This is the first time a monolith line count has gone *down* during the remediation period — worth recording because the structural-risk pattern up to this point has been the opposite (steady growth in `advisor_proxy.dart` and `admin_routes.dart`).

## Partial permission-key sweep

The permission-key import count on `lib/operator_web/screens/**` improved from **3 of 23 → 7 of 26** between Wave 4 close and 2026-05-08, without a dedicated CODE_HEALTH lane. New correctly-importing screens: `audit_log_screen.dart`, `hierarchy_screen.dart`, `members_screen.dart`, `sessions_screen.dart`. Original three were `custom_role_editor_screen.dart`, `roles_screen.dart`, `permission_explainer_screen.dart`. Nineteen screens still hand-type permission strings — a future sweep candidate.

## ProxyUsageCounterStore renamed/relocated

The class cited in the "two-slot key vs counter store granularity mismatch" residual was renamed or moved between Wave 4 and 2026-05-08. Repo-wide search no longer finds `ProxyUsageCounterStore`. The residual concern is real but the new file:line cite needs a re-locate before being re-pinned in `/CODE_HEALTH.md`.

## What grew on master between checks

- `tool/advisor_proxy/advisor_proxy.dart`: 15,863 → 16,949 lines (+1,086 in one day; PR [#342](https://github.com/SaidKhan005/forge-flow-demo/pull/342) `vendor-capability-polish` is the main contributor).
- `lib/admin/admin_routes.dart`: 1,953 → 2,204 lines (+251).

---

# Wave 5 closures (2026-05-08)

A fifth remediation wave landed four parallel lanes. Three closed cleanly; one closed partially with the watermark-tx half deferred; the doc-only re-locate corrected a stale cite.

## Closed via Wave 5

| Finding | PR | Lane |
|---|---|---|
| **Launch Blocker #3 — sync worker bare-catch + claim discipline + POOL-ENV stragger.** Replaced `catch (_)` at `integration_sync_worker.dart` with typed `on TimeoutException` / `on Exception` / `on Object` arms and structured-log reporter; added `FOR UPDATE OF cc SKIP LOCKED` to the `connector_connection` claim SELECT in `postgres_sync_worker_source.dart`; wired `resolvePostgresMaxConnectionsPerPool()` into `tool/integration_sync_worker/main.dart:1110` (the W4 stragger). | [#364](https://github.com/SaidKhan005/forge-flow-demo/pull/364) | W5-LB3 |
| `dispatch.dart:373` cadence resolver value discarded — `IntegrationSyncWorkerDispatch` now exposes a `ResolvedCadenceSink` typedef + `resolvedCadenceSink` field; `_resolveCadenceForRow` forwards the resolver's `int` return through the sink (default null preserves baseline). The audit-cited "value discarded" is no longer a discard. | [#363](https://github.com/SaidKhan005/forge-flow-demo/pull/363) | W5-DISPATCH (sub-task b only) |
| Permission-key sweep on operator-web screens — 3 screens (`my_account_screen.dart`, `schedule_screen.dart`, `vendor_connections_screen.dart`) had hand-typed permission strings matching catalog constants and were swept. Importer count 7/26 → 10/26. | [#362](https://github.com/SaidKhan005/forge-flow-demo/pull/362) | W5-PKEYS |
| `ProxyUsageCounterStore` re-locate — class wasn't renamed, it was SPLIT: runtime interface stays at `tool/advisor_proxy/advisor_proxy.dart:2418`; concrete Postgres seam extracted to `lib/infrastructure/persistence/postgres/advisor_proxy_usage_counter_store.dart:57` (with `proxy_bootstrap.dart:1396` as adapter). Unique key shape unchanged: `(operator_id, location_id, tier_id, minute_bucket)`. Concern still real; cite corrected. | [#359](https://github.com/SaidKhan005/forge-flow-demo/pull/359) | W5-CSTORE-RELOCATE |

## Closed partially in Wave 5 (deferred half logged in active CODE_HEALTH "Deferred" table)

| Finding | What landed in Wave 5 | What still needs to land | PR |
|---|---|---|---|
| Worker watermark not transactional with adapter writes (`dispatch.dart:268`) | (none — sub-task stopped) | Threading executor through `PollIncrementalCommand` → 17 vendor adapters → bespoke sinks → `CanonicalSink.advanceWatermark`. Goes well beyond a one-file diff. Needs its own phase doc. | n/a — deferred from [#363](https://github.com/SaidKhan005/forge-flow-demo/pull/363) |

## Wave 5 lane discoveries worth recording

- **W5-LB3 found another bare `catch (_)` at `tool/integration_sync_worker/backfill_dispatch.dart:368`** — same shape as the LB3 bug, outside the cite scope. Recorded as a small new residual in active CODE_HEALTH.md.
- **W5-PKEYS found the "19 hand-typing screens" framing was misleading.** Of the 19 screens that didn't import `permission_keys.dart`, only 3 actually used permission-string literals matching catalog constants. The remaining 16 didn't use permission keys at all — sign-in screens, onboarding flows, dialog scaffolds, and read-only surfaces. This is the kind of finding only an actual sweep surfaces.
- **W5-PKEYS surfaced 3 NEW screens with new-namespace strings:** `account_screen.dart`, `business_setup_screen.dart`, `business_timing_editor_screen.dart` hand-type `account.configure` and `business_timing.configure` permissions. These namespaces aren't in the frozen catalog — adding them needs catalog-sync work (the catalog mirrors a contract doc + a seed migration), which is a separate concern. Recorded as a small new residual.
- **W5-CSTORE-RELOCATE corrected a 2026-05-08 fact-check error.** The earlier check searched only `tool/` for `ProxyUsageCounterStore` and reported "renamed/relocated; can't determine". The class was actually still at the same `tool/` location; the agent missed the `lib/`-side concrete seam that was added during the broader Postgres-bootstrap work. The class shape didn't move; the concern shape didn't change.
- **W5-DISPATCH stopped honestly on sub-task (a)** rather than ship a half-baked watermark wiring. The agent's own assessment: "Per the prompt's 'two halves not entangled with each other' clause, the (b) fix shipped standalone."

## Wave 5 closeout PR

- This archive PR — records Wave 5 closures and trims `/CODE_HEALTH.md` to remove the now-closed items.

---

# Final closeout (2026-05-08)

The CODE_HEALTH chapter is closed. Total: **52 findings closed across 41 PRs** in Waves 0/1/2/3/4/5 (audit dated 2026-05-06; closeout 2026-05-08).

## Trajectory

- **Wave 0** — three Postgres schema migrations (admin idempotency TTL, password history salt+pepper, audit anchor advisory lock).
- **Waves 1+2** — 12 code lanes closing C1-C5 + ~22 high-severity findings, plus L15 domain cleanup.
- **Wave 3** — 9 lanes closing the lingering residuals (LB1 mobile isolation, LB2 redaction across 17 vendor sinks, OUTBOX-TX atomic completion, ACTOR-KIND, BIZ-DATE-SEC, RELOCATE, TOKEN-CAP misdiagnosis correction, plus partial closures POOL-ENV + PCACHE-FANOUT).
- **Wave 4** — 4 lanes closing the Wave 3 partial closures plus two structural items (POOL-ENV-ADOPT, PCACHE-FANOUT-PRODUCERS, TOKEN-CAP-REAL, FF-POLICY-FOLD).
- **Wave 5** — 4 lanes closing the launch-readiness item LB3 plus three smaller residuals (W5-LB3, W5-DISPATCH cadence half, W5-PKEYS, W5-CSTORE-RELOCATE).

## What carried forward

A handful of items did not close during the remediation. They were consolidated into the project's normal tracking surfaces on 2026-05-08 by the closeout PR:

- **`docs/POST_HARDENING_FOLLOWUPS.md`** — operational, small-bug, architectural-cleanup, latent-risk items.
- **`docs/phases/phase_11a/phase_11a_decision_register.md`** — AI-paused follow-ups (cost levers, Voyage hardening, `labor_model` rounding).
- **`docs/phases/phase_8/phase_8_spine_bridge_plan.md`** — watermark transactional discipline (deferred 17-adapter refactor).
- **`docs/contracts/auth_permission_key_catalog.md`** — pending namespace additions.

The active `/CODE_HEALTH.md` is now a small pointer to those destinations + this archive.

## What this closure means

The remediation effort hit its natural floor:
- Every original critical bug closed.
- Every cleanly-fixable contract violation closed.
- All three launch blockers on master.
- Remaining items are either paused (AI un-pause), refactor (need their own phase docs), or operational (button-presses outside the codebase).

Closeout PRs:
- Lane A — consolidate residuals into destination docs (PR opened in parallel).
- Lane B — replace `/CODE_HEALTH.md` with the closeout pointer + this final closeout entry (this PR).
