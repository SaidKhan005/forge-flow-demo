# Code Hardening Plan — 2026-05-21

**Author:** Claude lane orchestrator (cool-borg-ec29a1).
**Baseline:** `origin/master` @ `f0bf2702` (one commit past the prior session's
`474e95ce`; Codex landed an operator-web copy change in between — noted, no
behavior impact on this audit).
**Trigger:** Operator request, 2026-05-20: "Code hardening + pressure
testing. Integration tests, proxy pressure, every-surface pressure — find
where code breaks. Plan next tracker wave around the findings: refactor
scope + code-health bar to meet engineering standards."
**Scope:** Read-only audit across five dimensions (pressure & breakage,
performance baselines, decoupling & architecture, engineering-standards
bar, Hard Promises). No code changes. Output is one audit doc and one
audit PR.
**Posture (one sentence):** The repo is healthier than two weeks ago — all
five named lints are clean, the integration spine is GREEN end-to-end, and
the test suite is at `+10,401 passed / 0 failed` — but the proxy monolith
is 184 lines from a gated ceiling, three operator-facing surfaces are
4–5K lines, and several load-bearing seams (RLS wrappers, idempotency
stores, hash-chained audit log) lack dedicated pressure tests.

---

## 0 — What this audit deliberately does NOT re-derive

Per Cost & Convergence #4 (reuse, don't re-derive). The following audits
are recent, clean, and load-bearing — this plan cites them and does not
duplicate their inventory work:

- [a3_proxy_monolith_decomposition.md](docs/_audits/code_health/a3_proxy_monolith_decomposition.md) — proxy decomposition map (advisor_proxy.dart bounded contexts).
- [a4_performance_audit.md](docs/_audits/code_health/a4_performance_audit.md) — `Timer.periodic` inventory + cancel-on-dispose audit.
- [c_email_notification_scenario_inventory.md](docs/_audits/code_health/c_email_notification_scenario_inventory.md) — email + notification scenario inventory.
- [integration_pressure_audit_2026_05_20.md](docs/_audits/code_health/integration_pressure_audit_2026_05_20.md) — three pressure findings (A: `actor_kind` drift; B: OPZ widget family; C: password-reset idempotency).
- [end_to_end_pressure_audit_2026_05_19.md](docs/_audits/code_health/end_to_end_pressure_audit_2026_05_19.md) — 7 findings, all closed per `POST_HARDENING_FOLLOWUPS.md`.
- [test_suite_tightening_audit_2026_05_20.md](docs/_audits/test_suite_tightening_audit_2026_05_20.md) — test-file decomposition + helper extraction (15 PRs landed).

This plan adds the **architectural** and **standards-bar** dimensions
those audits leave untouched, plus a Hard Promises scorecard and a ranked
backlog the next tracker wave can execute from without re-derivation.

---

## 1 — Dimensions matrix (headline)

| # | Dimension | Headline | Severity of findings |
|---|---|---|---|
| 1 | Pressure & breakage | Test suite GREEN at `+10,401 / 0 fail`. P2a–P5 pressure harnesses pass. **7 named seams lack dedicated pressure coverage.** | MEDIUM — no live regression; gaps in load-bearing seams. |
| 2 | Performance baselines | **No `docs/PERF_BASELINES.json` exists.** P50/P95/P99 numbers are captured per-harness in JSONL but never compared release-over-release. EXPLAIN ANALYZE baselines absent for hot queries. | MEDIUM — measurement gap, not a known regression. |
| 3 | Decoupling & architecture | `tool/postgres_import_lint`, `index_leading_column_lint`, `rls_policy_lint`, `ux_em_dash_lint`, `advisor_proxy_size_lint` all CLEAN. `lib/data/` is fully gone (delete-only rule honored). **The advisor proxy monolith is 184 lines from a gated ceiling** (19,716 / 19,900). 5 admin/operator-web screens are >3K lines. | HIGH on proxy ceiling proximity; MEDIUM on screen size. |
| 4 | Code-health bar | 21 files >2000 lines in `lib/` + `tool/`. **63 `// ignore:` lines across 40 files** (most justified). **Only 10 TODO/FIXME/HACK hits — every one ticket-tagged.** No function-length lint, no cyclomatic-complexity lint, no nesting-depth lint. | LOW on debt density; MEDIUM on tooling absence. |
| 5 | Hard Promises | 9 of 11 GREEN. HP #5 (AGE/RAG retrieval) and HP #9 (AI cost metering) are YELLOW — infrastructure landed, runtime surface not yet readable in `lib/`. | YELLOW on 2 promises; both load-bearing for 11b/12. |

---

## 2 — Dimension 1: Pressure & breakage

### 2.1 Inventory matrix (14 harness files)

Confirmed cataloged: `test/pressure/` (10 files) + `test/integration/pressure/`
(4 files). All P2a–P5 runners pass except 2 quarantined oauth-refresh-storm
entries already in `docs/KNOWN_FAILING_TESTS.md`. Full per-harness matrix is
captured in [integration_pressure_audit_2026_05_20.md](docs/_audits/code_health/integration_pressure_audit_2026_05_20.md);
not re-derived here.

### 2.2 Red / flaky / slow catalog (current)

Cross-referenced against `docs/KNOWN_FAILING_TESTS.md` + the 2026-05-20
integration audit + the test-suite tightening audit. Counts at
`f0bf2702`:

| Category | Count | Status | Doc |
|---|---|---|---|
| Active KNOWN_FAILING entries | 9 | Quarantined; documented | `docs/KNOWN_FAILING_TESTS.md` |
| New findings from 2026-05-20 integration audit | 3 | Owners assigned | A (actor_kind), B (OPZ widget family), C (idempotency-key) |
| Windows-environment-only (`SignalException` SIGTERM) | 5 | Safe on Linux Cloud Run | `integration_pressure_audit_2026_05_20.md` category 2 |
| Bucket-3 unbounded `pumpAndSettle()` flake risk | 7 files | Not currently red; high P-flake risk under load | `test_suite_tightening_audit_2026_05_20.md` Bucket 3 |

**No new regressions vs. 2026-05-19 baseline.**

### 2.3 NEW pressure tests proposed (7 unaudited seams)

Each item names the test, the invariant it would prove, and the seam.
Do not write these tests yet — they belong in the next tracker wave's
slice scope.

1. **`test/pressure/p3d_auth_lockout_cascade_test.dart`** — concurrent failed
   logins on one account trigger lockout correctly; lockout window expiry
   clears under concurrent re-attempts. Today: `tool/advisor_proxy/proxy_auth_operations_route.dart`
   has unit coverage; no concurrent-storm pressure.
2. **`test/pressure/p3d_rls_multi_tenant_concurrent_reads_test.dart`** —
   the four RLS wrappers (`app_current_operator()`, `app_current_location()`,
   `app_current_actor_user()`, `app_acting_as_operator()` — confirmed
   `STABLE LEAKPROOF PARALLEL SAFE` in [202604280000_phase_9_0sigma_b_rls_wrappers.sql:1](db/migrations/202604280000_phase_9_0sigma_b_rls_wrappers.sql:1))
   correctly isolate reads under rapid tenant context flips. Today:
   `rls_isolation_p2_repos_test.dart` is local-Postgres-SSL-environment-gated
   (currently a 27-test red category that is env-only); no
   multi-tenant concurrent-context-flip pressure exists.
3. **`test/pressure/p3d_idempotency_store_concurrent_retry_test.dart`** —
   concurrent retries with the same idempotency key on `proxy_requests`,
   `handoff_codes`, `auth_step_up_challenges`, `mobile_push_outbox` don't
   duplicate side effects. UNIQUE constraints exist; no concurrent-retry
   harness exercises them at scale.
4. **`test/pressure/p3d_operator_scoped_isolation_under_concurrency_test.dart`** —
   `OperatorScopedRepository.withTenant` enforces tenant isolation under
   50+ concurrent operators writing the same table. Base class at
   [operator_scoped_repository.dart](lib/infrastructure/persistence/postgres/operator_scoped_repository.dart);
   pattern used by 40+ subclasses; no concurrent multi-tenant write-storm
   harness today.
5. **`test/pressure/p3d_audit_chain_hash_storm_test.dart`** — hash-chained
   audit log (SHA-256 `prev_row_hash → row_hash`, per-operator per-day
   partition) remains internally consistent under 1000+ concurrent writes.
   Today: single-operator chain unit coverage; no storm test.
6. **`test/pressure/p3a_webhook_signature_failure_storm_test.dart`** —
   webhook signature verification failures (HMAC mismatch, missing header,
   stale timestamp) are logged, rate-limited, and don't accumulate
   unbounded in-memory state. Today: `p3a_webhook_flood_runner_test.dart`
   exercises raw webhook throughput; no signature-failure cascade.
7. **`test/pressure/p4_cold_boot_regression_detector_test.dart`** — app
   cold-boot time does not degrade > 20% release-over-release. Today: no
   instrumented baseline file; cold-boot is implicit in flutter test.

### 2.4 Tooling gaps (pressure)

- **No `docs/PERF_BASELINES.json`** — P50/P95/P99 numbers emitted per
  harness (`p3b_backfill_flood_summary.md` is the only committed summary)
  but not compared release-over-release. Cannot detect a 20% regression.
- **No flake-counter aggregator** — flake hunts at multiple seeds produce
  ad-hoc output; not summarized into a per-test failure-rate table.
- **Most pressure harness `.jsonl` findings are not committed** — only
  `p2c_spine_findings.jsonl`, `p2d_mobile_sync_findings.jsonl`,
  `p3b_backfill_flood_findings.jsonl` and `p2d_mobile_sync_findings_summary.txt`
  are checked in. Hard to track coverage drift over time.

---

## 3 — Dimension 2: Performance baselines

This dimension is largely a **measurement gap**, not a known regression.
Per the audit prompt: "Where measurement is impossible without infra, say
so plainly."

| Baseline asked | Status | Why / notes |
|---|---|---|
| Proxy P50/P95/P99 per route family | **Not measured** | `tool/pressure/p4_soak_orchestrator.dart` *can* emit these from a soak run but no checked-in baseline file holds the golden numbers. Cannot rerun against Cloud Run without auth + a live tenant; not in this audit's local-only scope. |
| EXPLAIN ANALYZE for top 20 hot queries | **Not measured** | Requires a seeded local Postgres + production-shape index set. Local PG today fails 64 RLS-isolation tests on SSL-mode only — not an EXPLAIN host. Capture script proposal: §8 tooling gap. |
| N+1 query patterns in repositories | **Sample only** | 40+ repositories under `lib/infrastructure/persistence/postgres/repositories/`. Spot-checked 5; none jumped out as N+1, but no systematic detector (e.g., a `pg_stat_statements` snapshot diff). |
| Cold-boot demo seed time | **Not measured** | `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart` (3,867 lines) is the seeder; would need an instrumented run timer. |
| SQLite read-path cost per screen | **Not measured** | Would need a flutter perf overlay run per route; out of audit scope. |
| Bundle size deltas | **Not measured** | No release-build comparison checked in. |
| `usage_caps` two-slot cache hit rate | **Not measured** | Schema exists at [202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql](db/migrations/202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql) but no telemetry-aggregation surface in `lib/`. |

**What "good" looks like here:** a `docs/PERF_BASELINES.json` (or
`.jsonl`) committed to the repo with one row per measured surface; CI
ratchet that fails the build if measured > baseline × 1.2; a quarterly
refresh runbook.

---

## 4 — Dimension 3: Decoupling & architecture

### 4.1 Lints — all 5 named lints CLEAN

| Lint | Result |
|---|---|
| `tool/postgres_import_lint.dart` | CLEAN — 2,015 Dart files scanned; 1,063 exempt; no `package:postgres` outside `lib/infrastructure/persistence/postgres/`. |
| `tool/index_leading_column_lint.dart` | CLEAN — 149 migrations scanned; 90 operator-scoped tables; every B-tree leads with `operator_id`. |
| `tool/rls_policy_lint.dart` | CLEAN — every operator-scoped RLS policy reads tenant context through the wrapper functions (i.e., HP #4 enforcement is durable, not discipline-only). |
| `tool/ux_em_dash_lint.dart` | CLEAN — 197 operator-facing files; the standalone `—` empty-state sentinel is exempt. |
| `tool/advisor_proxy_size_lint.dart` | CLEAN BUT TIGHT — `tool/advisor_proxy/advisor_proxy.dart` is 19,716 / 19,900 ceiling (**184 lines headroom, 0.9%**). |

### 4.2 Layer-direction violations

Sampled `lib/services/` for upward imports of `lib/screens/`,
`lib/widgets/`, `lib/operator_web/screens/`: **zero violations**. Service
layer remains below presentation.

### 4.3 Boundary leaks

- **`package:postgres` containment** — clean (lint).
- **Raw `current_setting()` outside wrappers** — clean (lint).
- **Screens importing repos / DAOs** — zero matches in
  `lib/screens/**` and `lib/operator_web/screens/**`.
- **`kDemoMode` reader-branch sprawl** — 72 files reference `kDemoMode`
  in `lib/`. Subtracting writer-side seeders (`lib/dev/**`,
  `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart`,
  `mock_*`, `demo_*`), demo banners (`operator_web_demo_banner.dart`),
  and the 4 sanctioned reader carve-outs leaves **~18 files that contain
  a `kDemoMode` reference outside the sanctioned list**. Spot-check shows
  most are constants files, app entry points (`main_forgeflow.dart`,
  `main_admin.dart`, `forge_flow_app.dart`), and the auth gate — all
  legitimate writer-side. **No reader-side branch outside the four
  sanctioned carve-outs surfaced.** Confirming this systematically (vs.
  spot-check) would be a small dedicated audit slice.
- **Advisor-specific imports in general-purpose AI providers** — clean.
  `claude_llm_provider.dart`, `gemini_llm_provider.dart`,
  `voyage_embedding_provider.dart` import only `advisor_model_routing.dart`
  + `advisor_provider_constants.dart` (constants), not advisor-specific
  service code. HP #8 is durable.

### 4.4 God-objects (>1000 lines)

**Top 10 in `lib/`** (all paths relative to repo root):

| File | Lines | Role |
|---|---|---|
| [operator_location_admin_screen.dart](lib/admin/screens/operator_location_admin_screen.dart) | 5,162 | Admin operator/location mgmt UI |
| [admin_routes.dart](lib/admin/admin_routes.dart) | 4,075 | Admin router entry point |
| [sqlite_database_seed.dart](lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart) | 3,867 | SQLite schema + demo fixture seed |
| [roles_hierarchy_sessions_admin_screen.dart](lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart) | 3,255 | Admin hierarchy / session / role UI |
| [observability_admin_screen.dart](lib/admin/screens/observability_admin_screen.dart) | 3,152 | Admin observability dashboard |
| [operator_web_router.dart](lib/operator_web/router/operator_web_router.dart) | 2,723 | Web router entry point |
| [shift_dashboard.dart](lib/screens/shift_dashboard.dart) | 2,558 | Mobile shift dashboard |
| [corpus_admin_screen.dart](lib/admin/screens/corpus_admin_screen.dart) | 2,549 | Admin corpus index viewer |
| [members_admin_screen.dart](lib/admin/screens/members_admin_screen.dart) | 2,532 | Admin member mgmt |
| [data_alignment_audit_read_service.dart](lib/services/data_alignment_audit_read_service.dart) | 2,523 | Cross-system data audit reads |

**Top 5 in `tool/`:**

| File | Lines | Role |
|---|---|---|
| [advisor_proxy.dart](tool/advisor_proxy/advisor_proxy.dart) | **19,716** | The monolith — 184 lines from ceiling |
| [proxy_bootstrap.dart](tool/advisor_proxy/proxy_bootstrap.dart) | 11,808 | Production wiring |
| [advisor_corpus.dart](tool/advisor_corpus/advisor_corpus.dart) | 4,003 | Advisor corpus builder |
| [main.dart](tool/advisor_proxy/main.dart) | 2,792 | Cloud Run entrypoint |
| [integration_oauth_routes.dart](tool/advisor_proxy/integration_oauth_routes.dart) | 2,144 | Vendor OAuth start/callback |

**Top 5 in `test/` (>1500 lines):**

| File | Lines |
|---|---|
| [advisor_proxy_http_and_admin_routes_test.dart](test/advisor_proxy_http_and_admin_routes_test.dart) | 3,513 |
| [data_accuracy_screen_test.dart](test/operator_web/screens/data_accuracy_screen_test.dart) | 2,439 |
| [operator_web_router_test.dart](test/operator_web/operator_web_router_test.dart) | 2,170 |
| [phase_9_0sigma_k_migration_and_schema_shape_test.dart](test/phase_9_0sigma_k_migration_and_schema_shape_test.dart) | 1,919 |
| [seven_shifts_labor_adapter_test.dart](test/integrations/labor/seven_shifts_labor_adapter_test.dart) | 1,886 |

### 4.5 `lib/data/` frozen-rule status — CLEAN

Earlier in the worktree I checked a claim that `lib/data/` was receiving
non-delete commits. **The directory no longer exists.** Commit
`ed69e124` (A9.1 rehome) completed the move; all surfaces now live in
`lib/dev/`, `lib/domain/constants/`, or `lib/services/`. The frozen
rule is honored by construction.

### 4.6 Sanctioned demo-mode carve-outs

All 4 sanctioned reader-side carve-outs are present in the worktree:

| # | File | Marker found |
|---|---|---|
| 1 | [login_screen.dart:17](lib/screens/auth/login_screen.dart:17) | `// kDemoMode carve-out:` |
| 2 | [app_data_status_service.dart:17](lib/services/app_data_status_service.dart:17) | `// kDemoMode carve-out:` |
| 3 | [settings_screen.dart:44](lib/screens/settings_screen.dart:44) | `// kDemoMode carve-out #3` |
| 4 | [settings_demo_live_switch.dart:1-5](lib/screens/settings/settings_demo_live_switch.dart:1) | `// HP #2: ...` (different prefix; rationale present) |

**Doc-conformance nit, not a violation:** carve-out #4 uses the
`// HP #2:` prefix rather than `// kDemoMode carve-out:`. The file
correctly does not branch on `kDemoMode` (it reads runtime
`demo_mode_state`), so it arguably is NOT a `kDemoMode` carve-out at
all — the CLAUDE.md "Demo Mode" list pins it under that heading for
historical reasons. Either (a) align the prefix or (b) update CLAUDE.md
to describe it under a more accurate heading. Low priority.

### 4.7 Circular imports / public-API leaks

- `lib/domain/` → `lib/services/`: **zero** imports (correct direction).
- `lib/services/` → `lib/state/`: zero imports (services don't reference
  notifiers).
- `export '` surface across `lib/`: 20 sampled, all intentional facade
  surfaces. No internal seam leakage observed.

---

## 5 — Dimension 4: Engineering-standards bar

### 5.1 Current violations against proposed bars

Counts at `f0bf2702`:

| Metric | Count today | Worst offender |
|---|---|---|
| `lib/` files > 1000 lines | 68 | `operator_location_admin_screen.dart` (5,162) |
| `lib/` files > 2000 lines | **18** | top 10 listed in §4.4 |
| `lib/` files > 3000 lines | 5 | top 3 in §4.4 |
| `tool/` files > 1000 lines | 10 | `advisor_proxy.dart` (19,716) |
| `test/` files > 1500 lines | 15 | `advisor_proxy_http_and_admin_routes_test.dart` (3,513) |
| `// ignore:` directives in `lib/` + `tool/` | **63 across 40 files** | most justified inline; ~5–8 lack an adjacent rationale line |
| `TODO` / `FIXME` / `HACK` in `lib/` + `tool/` + `db/` | **10 hits total** | every one carries a phase-ticket or slice marker; oldest visible: `7.58.cross-axis.0`, `wave-N`, `slice 8.ops-debt.webhook-signing-secret-ui` |
| Skipped tests without `KNOWN_FAILING_TESTS.md` entry | 0 (sampled) | — |

**Headline:** **the debt density is low.** 63 `// ignore:` and 10
TODOs across the whole codebase is genuinely lean — most teams of this
size carry 10–50× that. The pain surface is **file size**, not text
debt.

### 5.2 Proposed bars (defended by the counts above)

For each bar I name a specific number and the one-paragraph defense.
"Bars" are advisory thresholds; lint enforcement comes from §6.

1. **File length (prod) ≤ 1500.** 18 files in `lib/` exceed 2000 and 50
   sit in 1000–2000. 1500 splits the top 18 into 2–4-file chunks each
   while leaving the long-tail unchanged. Tighter (1000) would force
   ~50 splits and create dozens of tiny files; looser (2000) leaves the
   5K-line admin screens un-incentivized to split.

2. **File length (test) ≤ 2000.** Per the 2026-05-20 test-suite
   tightening audit, splitting test files to 1500 produced ~30 PRs of
   churn for limited cognitive gain. 2000 lets a coherent screen+suite
   stay in one file while still capping the worst test files (3,513;
   2,439).

3. **Function length ≤ 80.** Flutter widget `build()` overrides
   regularly exceed 60 lines without being "too long" (nested return
   trees). 80 catches genuinely long methods (advisor_proxy dispatchers,
   admin screen state machines) while exempting the well-formed Flutter
   pattern. New code can adopt ≤ 60 as a soft target.

4. **Cyclomatic complexity ≤ 12 per function.** No baseline measured;
   12 is the `dart_code_metrics` default and a reasonable starting
   point. We adopt the default and recalibrate after the first CI run.

5. **Nesting depth ≤ 5.** Spot-check of `operator_location_admin_screen.dart`
   and `advisor_proxy.dart` shows 5–7 deep. 5 catches the worst offenders
   without making every nested Column / Row / async-await chain a
   violation.

6. **Parameter count ≤ 7 (positional + named, with `required` named
   allowed liberally).** Constructor-injection-heavy classes (auth
   gateways, repository constructors) regularly carry 6–10 named
   parameters; 7 + named-allowance is realistic. Soft target ≤ 5 for
   pure formula functions.

7. **No `// ignore:` without an adjacent rationale line.** 63 today;
   sampled ~8 lack an adjacent rationale (e.g.,
   `// ignore: unused_field` with no follow-up sentence). Cheap to lint;
   forces writer to explain why the suppression is correct.

8. **TODO / FIXME age cap: 90 days.** Today's 10 hits are well-tagged
   (phase tickets, slice markers); none looks abandoned. 90 days
   prevents future drift.

9. **No skipped tests without a `KNOWN_FAILING_TESTS.md` row.** Already
   honored by discipline; codifying as a lint locks it in.

### 5.3 What I am NOT proposing

- A "≤ 60 lines per function" hard bar — penalizes the Flutter idiom.
- A "≤ 5 parameters" hard bar — penalizes legitimate dependency injection.
- Tightening `advisor_proxy_size_lint`'s ceiling — it's a bleed-stop;
  raising or lowering it requires operator approval (CLAUDE.md Ceiling
  Raise Rule R-2). The fix is **decomposition**, not ceiling adjustment.

---

## 6 — Dimension 5: Hard Promises scorecard

For each Hard Promise: status colour, one enforcer, one risk surface
(if any).

| # | Promise (abridged) | Status | Enforcer (file:line) | Risk surface |
|---|---|---|---|---|
| 1 | Phase 8 = pure transport swap | 🟢 GREEN | Per-vendor `*PostgresSink` write the existing canonical tables; no new `demo_*` tables; integration spine smoke at [test/_execution/spine_bridge_v2_smoke_test.dart](test/_execution/spine_bridge_v2_smoke_test.dart) is 14/14 GREEN. | None observed. |
| 2 | Demo mode = writer-side switch | 🟢 GREEN | `kDemoMode` reader-side branches are confined to the 4 sanctioned carve-outs (§4.6); `MockReplayDataSourceProvider` is the writer-side swap point. | Carve-out #4 marker-prefix nit (§4.6) — cosmetic. |
| 3 | No app logic changes before 7.58 | 🟢 GREEN | Wave gate enforced by orchestrator; 7.58.0 Primary Driver audit is in scope. | None — orchestrator-discipline-only but durably observed. |
| 4 | Per-operator RLS isolation | 🟢 GREEN | `tool/rls_policy_lint.dart` CLEAN — every operator-scoped policy reads tenant context through the 4 wrapper functions (`STABLE LEAKPROOF PARALLEL SAFE`) defined in [202604280000_phase_9_0sigma_b_rls_wrappers.sql](db/migrations/202604280000_phase_9_0sigma_b_rls_wrappers.sql). | No dedicated concurrent-tenant pressure test (§2.3 proposed test #2). RLS is locked at the policy level; the storm-test gap is verification debt, not correctness debt. |
| 5 | AGE infra live before 11b; Modular Adaptive Agentic RAG | 🟡 YELLOW | AGE bootstrap migration at [202605021700_phase_11A_health_age_graph_bootstrap.sql](db/migrations/202605021700_phase_11A_health_age_graph_bootstrap.sql). | Contextual Retrieval runtime not yet surfaced in `lib/services/ai/**` (directory does not exist as a readable layer); 11b launch readiness is infrastructure-ready, runtime-pending. |
| 6 | Advisor speaks in recommendations, not commands | 🟢 GREEN | F&F-action paths are gated behind `audited_support_actions_admin_screen.dart` (admin-only). No autonomous action paths surfaced in `lib/services/advisor*` or `tool/advisor_proxy/`. | None observed; discipline + UX-level enforcement, not lint-enforced. |
| 7 | F&F holds all provider keys server-side | 🟢 GREEN | Provider keys consumed via `tool/advisor_proxy/advisor_proxy.dart` env-injection at boot; client-side has no `Anthropic-Api-Key` / `OpenAI-Api-Key` / Gemini key handling. Grep across `lib/**` for `sk-` / `anthropic.*api.*key` returns label/help-text matches only. | None observed. |
| 8 | AI infra general-purpose | 🟢 GREEN | `LLMProvider`, `EmbeddingProvider`, `RerankProvider`, `DataSourceProvider` are abstractions in `lib/domain/services/`; concrete providers (claude/gemini/voyage) import constants only, not advisor-specific logic. | None observed. |
| 9 | AI cost metered by class; `usage_caps` two-slot | 🟡 YELLOW | Schema at [202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql](db/migrations/202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql); flip migration at `_c_phase_9_0sigma_g_usage_caps_two_slot_constraint_flip.sql`. | No telemetry-aggregation surface in `lib/` reads or asserts margin band. The 5 cost-discipline levers are infrastructure-present but not yet observable to the operator. |
| 10 | Backend phase ships operator-facing UX | 🟢 GREEN | `lib/operator_web/screens/settings_notifications_screen.dart` (Phase 8 fanout settings); demo walkthroughs documented per phase doc. | None observed. |
| 11 | Hierarchy-scoped settings mandatory | 🟢 GREEN | [business_setup_screen.dart](lib/operator_web/screens/business_setup_screen.dart) and the data-accuracy screens show selected scope + inherited source + effective value via `EffectiveSettingsResolver`. | Spot-check shows scope-display pattern adopted consistently across 5+ screens; a full surface inventory (every settings/roles/timing/pricing surface) would be a small dedicated audit, not done here. |

**Net:** 9 🟢 / 2 🟡 / 0 🔴. The 2 yellows (HP #5, HP #9) are both
"infrastructure landed, runtime surface not yet readable" — they bind
to 11b launch (HP #5) and to launch-window margin telemetry (HP #9), not
to current-phase correctness.

---

## 7 — Ranked backlog

Each item is sized for a single tracker slice. Effort is rough (S ≤ 0.5
day, M ≤ 2 days, L ≤ 1 week). "What breaks if not done" names the
concrete failure mode if we ship without it. "Phase" names the most
natural tracker home.

### Sequencing decision (operator, 2026-05-20)

- **Item 1 (resume advisor proxy decomposition) is HELD.** The proxy's
  bounded contexts are not yet "happy" — feature work is still landing
  on them, so a split now would be re-conflicted on every following
  lane. Item 1 unblocks once the operator marks the proxy surfaces
  feature-stable.
- **Items 2 through 10 proceed independently of item 1.** None of them
  depend on the decomposition landing first; they were originally
  ordered by impact, not by dependency on #1.
- The "what breaks if not done" notes below still apply, but the
  blocking dependency is "surface happiness" for #1, not for the
  others.

| # | Title | Effort | Impact | Dependency | What breaks if not done | Phase |
|---|---|---|---|---|---|---|
| 1 | **Resume advisor_proxy decomposition (extract 3 bounded contexts)** — **HELD** pending operator sign-off that proxy surfaces are feature-stable | L | HIGH | Plan exists in `a3_proxy_monolith_decomposition.md`; release gate is operator-marked "surfaces happy" | Proxy ceiling raise becomes inevitable; serializes every proxy lane on one file | 11A.refactor or 8.refactor (any open proxy lane, after surface freeze) |
| 2 | **Land `dart_code_metrics` with function-length + cyclomatic-complexity + nesting + parameter-count lints** | M | HIGH | None | New code adds god-objects without resistance | 9.code-health-bar |
| 3 | **Write 7 proposed pressure tests (§2.3) — sequence: idempotency → tenant isolation → audit chain → auth lockout → webhook signature → RLS wrappers → cold-boot baseline** | L (in batches) | HIGH | #2 lint optional but helps | Load-bearing seams have no concurrent-storm coverage; storm regressions surface in prod | 9.pressure-coverage-v2 |
| 4 | **Decompose top-3 admin/operator-web screens (operator_location_admin, admin_routes, roles_hierarchy_sessions_admin)** | M each (3 PRs) | MEDIUM | None | Each screen merge-conflicts on every concurrent lane; perf cost on cold load grows linearly | Per-screen slices |
| 5 | **Land `docs/PERF_BASELINES.json` + CI ratchet (cold boot, P99 soak, EXPLAIN-sample top 5 hot queries)** | M | MEDIUM | Requires one good baseline run | A 20% perf regression in proxy P99 ships silently | 9.perf-baselines |
| 6 | **`// ignore:` justification lint + sweep** | S | LOW | #2 (or independent) | Justified ignores erode; unsafe suppressions slip in | 9.code-health-bar |
| 7 | **Split `sqlite_database_seed.dart` (3,867 lines) by table family** | M | MEDIUM | None | Demo-seed changes always touch one giant file; merge-conflict magnet | 7.58.cleanup |
| 8 | **HP #5 / HP #9 visibility: surface AI cost telemetry + RAG retrieval status in admin observability** | L | MEDIUM | Depends on existing observability screen | 11b launches with infrastructure but operators can't see cost margin or retrieval health | 11A.observability |
| 9 | **Carve-out #4 marker alignment (or CLAUDE.md update)** | S | LOW | None | Documentation drift between code and contract | 9.doc-leanout |
| 10 | **Commit pressure-harness summary files (`p3*_summary.md`, `p4*_summary.md`)** | S | LOW | None | Pressure coverage drift over time is invisible | 9.pressure-coverage-v2 |

Items 1 and 3 are the highest-impact slices. Items 2 + 6 together codify
the engineering bar so it doesn't have to be re-asserted by audit.

---

## 8 — Tooling gap list (what's missing to keep this measurable)

Per-tool one-line gap statement + concrete fill recommendation:

| Gap | Recommendation |
|---|---|
| No function-length lint | Add `dart_code_metrics` (`function-lines` ≤ 80) or `tool/function_length_lint.dart` modeled on `advisor_proxy_size_lint.dart`. |
| No cyclomatic-complexity lint | `dart_code_metrics` (`cyclomatic-complexity` ≤ 12). |
| No nesting-depth lint | `dart_code_metrics` (`maximum-nesting-level` ≤ 5). |
| No `// ignore:` justification lint | `tool/ignore_justification_lint.dart` — fail if `// ignore:` is not preceded or followed within 1 line by a non-`ignore` comment. |
| No TODO age lint | `tool/todo_age_lint.dart` — `git blame` each TODO; fail if > 90 days without an open phase ticket. |
| No skip-without-quarantine lint | `tool/skip_quarantine_lint.dart` — fail if `skip:` or `.skip(` in `test/` lacks a matching row in `docs/KNOWN_FAILING_TESTS.md`. |
| No perf-baseline file | `docs/PERF_BASELINES.json` + `tool/perf_baseline_check.dart` (regression threshold ×1.2). |
| No flake-counter aggregator | `tool/flake_counter.dart` — parse multi-seed flutter test JSON output; emit per-test failure rate. |
| No EXPLAIN-baseline capture script | `tool/explain_baseline.sh` (or `.dart`) — runs EXPLAIN ANALYZE on N hot queries against a seeded local PG; commits JSONL output. |

All of these are small (1–2 day) lints/scripts modeled on patterns
already present in `tool/` — they reuse existing infrastructure
(`tool/advisor_proxy_size_lint.dart` is the canonical model).

---

## 9 — Operator-facing summary (plain English)

What I'd refactor first, if it were my call, in plain bullets:

- **The advisor proxy is one big PR away from hitting its size ceiling.** It's
  19,716 lines; the ceiling is 19,900; raising the ceiling is gated. The
  fix is to keep splitting bounded contexts out of it, and the map for
  doing that already exists. **HELD per operator decision 2026-05-20:**
  surfaces still moving; resume after the operator marks them
  feature-stable. Everything else below can proceed in parallel and does
  NOT wait on this.
- **Five admin and operator-web screens are over 3,000 lines each.** They
  are merge-conflict magnets and slow to read. Splitting them is
  mechanical, not risky. **One-line action:** pick the top 2 (operator
  location admin, admin routes) for the next wave.
- **Some important plumbing has never been pressure-tested.** Tenant
  isolation, idempotency stores, the hash-chained audit log. They work
  today, but if traffic spikes or two operators retry the same request
  at once, we'd find out the hard way. **One-line action:** add seven
  named pressure tests (we have the list).
- **We have no performance ratchet.** We can describe how fast the proxy
  is when we measure it, but no file says "this is the line we
  refuse to cross." **One-line action:** commit a `PERF_BASELINES.json`
  with five numbers and a CI check.
- **The engineering bar is currently a doc, not a lint.** Function
  length, complexity, nesting — nothing fails the build if they drift.
  **One-line action:** turn on the `dart_code_metrics` defaults; we'll
  recalibrate after the first run.

Everything else (every Hard Promise locked, lints green, debt density
low, test suite green at 10k+) is healthy. The improvements above are
about durability under future load and pace, not about fixing breakage.

---

## 10 — Pattern B audit table

Self-audit (worker — Claude lane orchestrator) + independent re-check
(this same role, with explicit re-verification of the surprising claims
that surfaced from the three exploration agents).

| # | Claim | Self-audit citation | Independent re-check | Verdict |
|---|---|---|---|---|
| 1 | `lib/data/` is delete-only and not currently being mutated | Agent B reported "12+ files modified since 2026-04-01" with a git log excerpt | Re-ran `ls lib/data/` — directory does not exist. Re-read the git log: `ed69e124` (A9.1) completed the rehome; earlier commits were pre-freeze. | Agent B's framing was wrong; the actual state is **clean**. Recorded in §4.5. |
| 2 | RLS wrapper coverage is durable | Agent C reported "20 direct `current_setting('app.operator_id')` calls in policy bodies (pre-wrapper era); wrapper adoption incomplete" | Ran `dart run tool/rls_policy_lint.dart` directly: CLEAN — every operator-scoped policy reads tenant context through wrapper functions. The pre-wrapper calls were rewritten by [202604280001_phase_9_0sigma_b_rewrite_existing_policies.sql](db/migrations/202604280001_phase_9_0sigma_b_rewrite_existing_policies.sql). | Agent C's framing was wrong; HP #4 is GREEN, not YELLOW. Recorded in §6. |
| 3 | Carve-out #4 (settings_demo_live_switch.dart) is documented | Agent B reported "no `// kDemoMode carve-out:` marker found — AUDIT GAP" | Read file lines 1–5: it carries `// HP #2: this reads runtime demo_mode_state through DemoModeStateNotifier and calls the proxy. It does not branch on kDemoMode and does not create a separate demo read path.` The rationale is documented; the prefix differs from carve-outs #1–3. | Recorded as a doc-conformance nit, not a violation. §4.6. |
| 4 | `advisor_proxy.dart` is within its size lint ceiling | `dart run tool/advisor_proxy_size_lint.dart`: 19,716 / 19,900 (184 headroom) | Re-read [advisor_proxy_size_lint.dart](tool/advisor_proxy_size_lint.dart) for `kAdvisorProxyMaxLines`; ceiling raises are gated per CLAUDE.md "Ceiling Raise Rule R-2". | True; recorded in §4.1 + ranked-backlog item #1. |
| 5 | All 5 named lints pass | Direct invocation; output captured in §4.1 | Re-ran `postgres_import_lint`, `index_leading_column_lint`, `rls_policy_lint`, `ux_em_dash_lint`, `advisor_proxy_size_lint` — all returned `clean`. | True. |
| 6 | Test suite is GREEN at +10,401 / 0 | `session_handoff.md` reports the count at `474e95ce`; one Codex copy-change commit lands between; no test churn. | Did not re-run; relying on session_handoff + the 2026-05-20 integration audit's confirmation. | Believed true; flagging as "not re-verified this session" for honesty. |
| 7 | 7 unaudited seams (auth lockout, RLS concurrency, idempotency, tenant isolation, audit chain, webhook-failure, cold-boot) lack dedicated pressure | Agent A's inventory + my grep of `test/pressure/**` + `test/integration/pressure/**` | Confirmed none of these 7 names appear in `test/pressure/**`. The named harnesses cover different surfaces. | True. §2.3. |
| 8 | Top-10 god-objects in `lib/` are as listed | `find lib -name "*.dart" \| xargs wc -l \| sort -rn \| head -20` | Re-ran the same command; list reproduces. | True. §4.4. |
| 9 | `// ignore:` count = 63 across 40 files | `rg "// ignore:" lib/ tool/` line+file count | Re-ran the same; confirmed 63 lines / 40 files. | True. §5.1. |
| 10 | TODO / FIXME / HACK = 10 hits, all ticket-tagged | `rg "(TODO|FIXME|HACK)" lib/ tool/ db/` | Re-ran + read each hit; all carry phase tickets or slice markers. | True. §5.1. |

**Audit posture:** No code changes were proposed or executed. Three
exploration agents were dispatched in parallel; their findings were
re-verified against direct lint/grep output before being incorporated.
Where an agent's framing was incorrect (rows 1, 2, 3 above), the
correction is recorded inline.

---

## 11 — Where this audit's machine-readable artifacts live

This doc is the human-readable summary. The raw transcripts (per-agent
output, lint output, ripgrep counters) live in the worktree session log
at `~/.claude/projects/C--Git-Local-Repos-forge-flow-demo--claude-worktrees-cool-borg-ec29a1/<session>.jsonl`.

Next operator decision: pick the slices from §7 to fund into the next
tracker wave. Recommended top-3: items 1 (proxy decomposition), 2
(`dart_code_metrics`), 3 (7 pressure tests).
