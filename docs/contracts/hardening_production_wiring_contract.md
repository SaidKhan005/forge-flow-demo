# Hardening — Production Wiring Contract

Updated: 2026-05-02
Owner: HARD-A (production wiring sprint)
Status: Closed (shipped commit `9936126`, PR #41) — retained as historical authority.

## Why This Exists

Three scaffold rejections still ship in `tool/advisor_proxy/main.dart` and
silently break production posture: `/health` always 503s, usage caps are
unenforceable, and Firebase verifier installs a scaffold instead of failing
closed when production credentials are missing. This contract fixes the
wire-shape so dependents (Cloud Run probes, [proxy_health_contract.md](proxy_health_contract.md)
consumers, advisor pipeline cap enforcement) can rely on it.

This is the handoff between:

- `tool/advisor_proxy/main.dart` — production startup, dependency assignment.
- `tool/advisor_proxy/proxy_bootstrap.dart` `buildProxyProductionBindings()`.
- `lib/infrastructure/persistence/postgres/` — new
  `advisor_proxy_usage_counter_store.dart`.
- `tool/advisor_proxy/advisor_proxy.dart` — already holds
  `RegistryProxyHealthCheckStore` (class at `:5339`) and
  `ProxyUsageGuard`.
- [proxy_health_contract.md](proxy_health_contract.md) — wire-shape authority for
  `/health` envelope.

Disagreement rule: when this contract and code conflict, `proxy_health_contract.md`
wins for `/health` envelope shape; this contract wins for *which store* is
wired and *when startup fails*.

## In Scope

| Item | Scope | Out of scope |
|------|-------|--------------|
| `/health` route returns real `dependencies` + `metrics` envelope | yes (wiring only) | producer values for B44/B45/B47 metrics — those stay `unknown` |
| Usage counter store reads/writes `public.advisor_proxy_usage_counters` | yes | new tier definitions or cost levers |
| Startup fails closed in `prod` when `FIREBASE_PROJECT_ID` is unset | yes | scaffold/dev mode behavior |
| Startup logs `gemini_slot_enabled: <bool>` clearly | yes | Gemini provider readiness — confirmed by-design real |
| Stale comment at `main.dart:14` updated or removed | yes | other comments |

Out of scope: response cache activation (Phase E.2b), precomputed summaries,
OpenTelemetry traces, alert rules, dashboards.

## Required Behavior — Health Wiring

`buildProxyProductionBindings()` must return a `RegistryProxyHealthCheckStore`
backed by:

- A `postgres_select_1` check (`green` on `SELECT 1` success, `red` on failure or timeout).
- An `age_cypher_match` check (cypher `MATCH (n) RETURN 1 LIMIT 1`).
- A `pgvector_similarity` check (`SELECT '[1,0,0]'::vector <-> '[0,1,0]'::vector`).
- The `metrics` and `surfaces` envelope from
  [proxy_health_contract.md](proxy_health_contract.md) with all reserved keys
  populated as `status: unknown` placeholders when their producer (B43, B44,
  B45, B47, etc.) has not landed.

`main.dart` must replace `const ScaffoldFailingProxyHealthCheckStore()` with
the registry store from production bindings.

Acceptance:

- `GET /healthz` → 200 `{"status":"ok"}` (no DB touch).
- `GET /readyz` → 200 `{"status":"ok"}` (no DB touch).
- `GET /health` returns 200 with `dependencies.{postgres,age,pgvector}.status = green`
  on a healthy box; HTTP 503 + `status: unavailable` only when one required
  dependency check returns red or throws.
- Reserved metric keys all present with `status: unknown` until producers
  populate them. Their presence does not flip the response to `degraded`.

## Required Behavior — Usage Counter Store

New file: `lib/infrastructure/persistence/postgres/advisor_proxy_usage_counter_store.dart`.

Implements `ProxyUsageCounterStore` (interface in `tool/advisor_proxy/`).
Reads/writes `public.advisor_proxy_usage_counters` (table seeded by
migration `202604250004`). All access must go through
`OperatorScopedRepository<T>` plus `TenantTransactionWrapper`. Direct
`package:postgres` import is allowed in this file (it lives under
`lib/infrastructure/persistence/postgres/`).

Required methods:

| Method | Behavior | Idempotent? |
|--------|----------|-------------|
| `currentUsage({operatorId, locationId, tier, now})` | Reads minute + month rows for the tenant; returns remaining budget per cap | yes (read-only) |
| `incrementOnAllow({operatorId, locationId, tier, cost, now})` | UPSERT minute bucket and increment month total atomically; returns `Allowed` or `CapReached` | yes (same `(operator_id, minute, request_id)` collapses into one row) |

SQL discipline:

- Minute bucket: `INSERT ... ON CONFLICT (operator_id, location_id, tier, bucket_minute) DO UPDATE SET request_count = request_count + EXCLUDED.request_count`.
- Month total denormalized via `business_date` window; recomputed only at write.
- Indexes lead with `operator_id` (locked 2026-04-26 RLS performance discipline).
- Tenant context injected via `SET LOCAL app.operator_id = $1` in transaction.

Production binding wires this store into `ProxyUsageGuard` in
`buildProxyProductionBindings()`; main.dart drops
`ScaffoldFailingUsageCounterStore`.

Acceptance:

- `GET /v1/usage-smoke` returns 200 with `{"minute_remaining":N, "month_remaining":M, "tier":"<tier>"}`.
- Advisor route returns 429 with `{"error":"usage_cap_reached","cap":"minute"|"month"}` when tenant exceeds cap.
- Concurrent increments collapse to one row per minute (verify by parallel POST).
- All reads/writes set `app.operator_id` and `app.location_id` session vars before SQL.

## Required Behavior — Firebase Fail-Closed

`main.dart` must read `PROXY_ENVIRONMENT` (canonical values `prod`, `staging`,
`dev`). When `PROXY_ENVIRONMENT == 'prod'` and `FIREBASE_PROJECT_ID` is unset:

- Print one line to stderr: `startup_failure: firebase_project_id_required_in_prod`.
- Exit with code `78` (matches existing `ProxyConfigError` exit code).

When environment is `staging` or `dev`, current scaffold-verifier fallback
behavior is retained.

Acceptance:

- Test: bootstrap with `PROXY_ENVIRONMENT=prod` and no `FIREBASE_PROJECT_ID` → exit 78.
- Test: bootstrap with `PROXY_ENVIRONMENT=dev` and no `FIREBASE_PROJECT_ID` → starts in degraded mode (current behavior preserved).

## Required Behavior — Gemini Slot Visibility

Startup diagnostics block (`main.dart:~1849`) must emit one line:

```
gemini_slot_enabled: <true|false>
```

`true` only when `GEMINI_API_KEY` secret is loaded into config. No additional
gating logic — current env-var gate is the documented design (see
`docs/phases/phase_11a/phase_11a_decision_register.md` Lock 7). This line is
purely an audit signal so deploy verification can confirm the slot state
matches the production decision.

## Required Behavior — Stale Comment Repair

`main.dart:14–19` block referencing `ScaffoldRejectingProxyLlmProvider` must
either be deleted or updated to: "Lock 7: per-instance circuit breaker over
real Anthropic primary plus optional real Gemini secondary; on breaker open
the pipeline serves graceful refusal."

## Out of Scope

- Producer values for `audit_chain_lag_seconds`, `event_outbox_*`,
  `graph_*`, `vector_*`, `rollup_freshness_per_grain` — owned by B43, Phase
  10a, B44, B47, B45 respectively. They stay `status: unknown`.
- Response cache activation, precomputed summaries — Phase E.2b.
- OpenTelemetry traces, dashboards, alerts — Phase E.2.
- Tier-cap definitions — owned by `pricingTierAdminGateway`; usage counter
  is *enforcement only*.

## Test Surface (for Codex verification)

A passing implementation must add or modify:

- Unit tests for `RegistryProxyHealthCheckStore` covering all three
  dependency checks (green / red / throw).
- Unit tests for `AdvisorProxyUsageCounterStore` covering read, single
  increment, concurrent increment race (collapse to one row), cap-reached
  rejection.
- Bootstrap test for `PROXY_ENVIRONMENT=prod` + missing `FIREBASE_PROJECT_ID` → exit 78.
- Update `tool/advisor_proxy/main_test.dart` (or equivalent) so wiring is
  exercised end-to-end via `buildProxyProductionBindings()`.
- All tests must pass under `dart test test/proxy/` plus
  `dart analyze --fatal-infos`.

Codex acceptance verifies:

- [ ] `main.dart` no longer references `ScaffoldFailingProxyHealthCheckStore` or `ScaffoldFailingUsageCounterStore`.
- [ ] `RegistryProxyHealthCheckStore` constructor receives real producer set (not empty).
- [ ] `AdvisorProxyUsageCounterStore` exists under `lib/infrastructure/persistence/postgres/`.
- [ ] `Grep "import 'package:postgres'" lib/services/` does not regress (HARD-F enforces).
- [ ] `proxy_health_contract.md` envelope shape unchanged.
- [ ] Production-mode startup fails closed without `FIREBASE_PROJECT_ID`.
- [ ] Stale `main.dart:14` comment repaired.
- [ ] All listed tests pass.
