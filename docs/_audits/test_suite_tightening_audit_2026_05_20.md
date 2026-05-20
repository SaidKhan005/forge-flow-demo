# Test Suite Tightening Audit — 2026-05-20

Read-only audit covering all 890 test files (~210k LOC) at master `7da0e461`.
Suite is fully green today (10,401 passed, 8 skipped, 0 failed). Goal: keep
it green AND reduce the rework tax going forward (fewer flakes, less
boilerplate, smaller files).

Operator-web UX surfaces were skipped (Codex is editing those concurrently).

## Headline

- **890 test files. Only 3 helper files.** That's the #1 finding — boilerplate
  duplication is the dominant rework tax.
- **Top 5 mega-files are 5,800–8,300 lines each.** Painful to read, slow to edit,
  merge-conflict magnets.
- **1,596 unbounded `pumpAndSettle()` calls across 103 files.** Already
  responsible for one quarantined flake. Will produce more.
- **Static-state hygiene is clean** — the PR #1091 bug shape (`debugColdBoot*`
  leak) does not recur anywhere else. Good.
- **Stale-content surface is small** — repo is already lean. Mostly cosmetic
  date refs from 2024/early-2025.

## Buckets, ranked by ROI

### Bucket 1 — Postgres tag hygiene (cheap, immediate green-keeper)
**Effort:** 5 minutes. **Risk:** none.
2 tests import `package:postgres` without `@Tags(['postgres'])` and so run
in the default suite, which has no localhost Postgres. They survive today
only because the suite was just green; they will fail the next CI dark/light
flip.

- `test/infrastructure/persistence/postgres/package_postgres_outbox_listener_channels_test.dart`
- `test/infrastructure/persistence/postgres/seven_shifts_postgres_sink_test.dart`

(`test/tool/postgres_import_lint_test.dart` is a synthetic linter; safe as-is.)

### Bucket 2 — Cosmetic staleness sweep (cheap, low-value)
**Effort:** 30 minutes. **Risk:** none.
Year-rotated date refs that are confusing, not broken:

- `test/integration/business_date_denorm_test.dart` — `2025-01-01` anchor
- `test/integration/iana_scenarios_test.dart` — multiple 2024–2025 anchors
- `test/app_data_status_test.dart` — `2025-W50` comment, `2026-03-27` anchor
- `test/baseline_range_logic_test.dart` — references closed `phase_7_55m_5`
  in comments (logic still valid)
- `test/contracts/phase_7_58_primary_driver_test.dart` + `phase_7_61_driver_key_test.dart`
  — verify contract docs are archived; repoint comments

### Bucket 3 — Flake-risk paydown (medium effort, prevents 2026 regressions)
**Effort:** 1–2 days, parallelizable. **Risk:** low if done file-at-a-time.

**P0 (already in `docs/KNOWN_FAILING_TESTS.md`):**
- `test/operator_web/operator_web_router_test.dart:616` — vendor-route
  never-settling timer. Quarantined. Skip per Codex-lane rule.

**P1–P4 (high-call-count widget tests):**
| Rank | File | Unbounded `pumpAndSettle()` count |
|------|------|------|
| P1 | `test/admin_operator_location_screen_test.dart` | 134 |
| P2 | `test/operator_web/screens/data_accuracy_screen_test.dart` | 88 (SKIP — Codex) |
| P3 | `test/admin/screens/roles_hierarchy_sessions_admin_screen_test.dart` | 79 |
| P4 | `test/admin/screens/members_admin_screen_test.dart` | 79 |
| P5 | `test/operator_web/operator_web_router_test.dart` | 57 (KNOWN_FAILING) |
| P6 | `test/admin/screens/audited_support_actions_admin_screen_test.dart` | 48 |
| P7 | `test/admin_shell_widget_test.dart` | 47 |
| P8 | `test/baseline_manager_screen_test.dart` | 39 (SPLIT — now `test/baseline_manager_screen_{core,preview_and_override,calendar_and_navigation,regression_suite}_test.dart` + `test/baseline_manager_screen_test_helpers.dart` per Bucket 5) |

**Fix shape (proven):** replace unbounded `pumpAndSettle()` with bounded
`for (int i = 0; i < N; i++) { await tester.pump(Duration(milliseconds: M)); }`
plus an explicit fail-fast when the expected condition isn't met.

**Bucket 3b — Narrow-viewport blind spots (low-priority):**
6 widget tests assert at narrow widths (372–520px) with no wide-viewport
companion — the same blind spot that caused PR #1092's feature-flags Column
overflow. Lower priority because no live regression.

### Bucket 4 — Helper extraction (high effort, high ROI)
**Effort:** 2–3 days. **Risk:** medium (touches many files, but each move is
mechanical).

The 3-helper-file situation is the dominant boilerplate driver. Top
extractions, ranked by LOC saved:

| Helper | Files affected | Est. LOC saved |
|---|---|---|
| `test/_test_helpers/http_stubs.dart` (consolidates `_StubHttp*`) | 5 | ~500 |
| `test/_test_helpers/sqlite_demo_helpers.dart` (`setUpSqliteDemo`, baseline reset) | 42 | ~1,000 |
| `test/_test_helpers/widget_test_providers.dart` (provider+MaterialApp wrap) | 16 | ~300 |
| `test/_test_helpers/cold_boot_helpers.dart` (`debugColdBoot*` set+reset) | 8 | ~60 |
| `test/_test_helpers/mock_http_helpers.dart` (`_FakeHttpClient`) | 3 | ~100 |
| `test/_test_helpers/postgres_test_helpers.dart` (tenant tx wrap) | 3 | ~90 |

**Total estimate: ~2,000 LOC of test boilerplate removed.** Plus future tests
get faster to write.

### Bucket 5 — Mega-file decomposition (high effort, high cognitive ROI)
**Effort:** 1–2 days per file. **Risk:** medium — mechanical but easy to
botch with poor commits. Each file goes in its own PR.

Top 3 highest-ROI splits (out of 10 reviewed):

1. **`test/advisor_proxy_test.dart` (8,328 → 5 files)** — LANDED (PR #1120).
   Split into `test/advisor_proxy_config_test.dart`,
   `test/advisor_proxy_token_and_guard_test.dart`,
   `test/advisor_proxy_usage_and_migrations_test.dart`,
   `test/advisor_proxy_jwt_verifier_test.dart`,
   `test/advisor_proxy_http_and_admin_routes_test.dart`, with shared
   helpers in `test/advisor_proxy_test_helpers.dart`.

2. **`test/baseline_manager_screen_test.dart` (3,608 → 4 files)** — LANDED.
   Split by existing A–U / R1–R10 group labels into
   `test/baseline_manager_screen_core_test.dart`,
   `test/baseline_manager_screen_preview_and_override_test.dart`,
   `test/baseline_manager_screen_calendar_and_navigation_test.dart`,
   `test/baseline_manager_screen_regression_suite_test.dart`, with the
   shared top-level `setUp()` extracted to
   `test/baseline_manager_screen_test_helpers.dart` (pairs naturally with
   Bucket 4).

3. **`test/services/integration/canonical_fact_to_closed_shift_input_test.dart` (3,981 → 3 files)** — LANDED.
   Split by Block 2 acceptance items A–P (already alphabet-labeled) into
   `test/services/integration/canonical_fact_covers_and_pos_aggregation_test.dart`,
   `test/services/integration/canonical_fact_wage_and_labor_sources_test.dart`,
   `test/services/integration/canonical_fact_rls_and_regression_checks_test.dart`,
   with shared fixtures in
   `test/services/integration/canonical_fact_test_fixtures.dart`. Pure
   const fixtures; no setUp; cleanest split of the three.

Together these three reduce ~16,000 lines into 13 focused files
(all 3 landed: PR #1117 baseline_manager, the canonical_fact split
landed pre-#1117, advisor_proxy #1120).

Lower-priority splits (do if Bucket 5 lands clean):
- `test/proxy_auth_operations_route_test.dart` (3,599 → 4) — LANDED (PR #1122)
- `test/target_cycle_service_test.dart` (2,365 → 3) — LANDED (PR #1123)
- `test/data_alignment_audit_read_service_test.dart` (2,161 → 3) — LANDED (PR #1121)
- `test/phase_9_0sigma_f_audit_logs_test.dart` (2,144 → 2) — LANDED (PR #1124)
- `test/admin_operator_location_screen_test.dart` (2,129 → 3) — LANDED (PR #1125); pairs with P1 flake-risk fix
- `test/proxy/mobile_operational_sync_routes_test.dart` (2,067 → 3) — LANDED (PR #1126)
- `test/phase_9_0sigma_k_rollups_test.dart` (2,012 → 2) — LANDED (PR #1127); split into `test/phase_9_0sigma_k_migration_and_schema_shape_test.dart` + `test/phase_9_0sigma_k_rls_and_rebuild_runbook_test.dart`

## What deliberately stays

- **`phase_9_0sigma_*_test.dart` filenames** — load-bearing per Authority
  Order. Comments inside may say "phase 9", that's correct.
- **30+ `demo_*_test.dart` / `per_daypart_v1_demo_*_test.dart`** — active
  Per-Daypart Targets V1 plan; load-bearing for Hard Promise #2.
- **Passively-skipped staging integration tests** (`LIVE_BINDING_*`,
  `FORGE_FLOW_RUN_STAGING_*`) — these are intentional safety guards; their
  structural-layer companions run on every CI pass.
- **Triple-file admin screen patterns** (`*_admin_screen_test.dart` +
  `*_identity_idempotency_test.dart` + `*_security_test.dart`) — intentional
  split by concern, not duplication.

## Recommended sequencing

If everything ships, do it in this order so each PR's baseline is the
previous one's tip:

1. Bucket 1 (postgres tags) — 1 PR
2. Bucket 3 helpers FIRST, then 3a flake fixes — 1 helper-extract PR per area,
   then 1 fix PR per top-10 file
3. Bucket 4 (helper extraction) — 1 PR per helper file
4. Bucket 5 (mega-file split) — 1 PR per file, advisor_proxy LAST since
   it's the biggest
5. Bucket 2 (cosmetic staleness) — 1 PR at any point, low risk

## Where the audit raw output lives

Full per-bucket findings (with every file:line and ranking) live in the
transcript at:
`C:\Users\saidu\.claude\projects\C--Git-Local-Repos-forge-flow-demo--claude-worktrees-bold-kirch-624d77\<session>.jsonl`

This doc is the ranked, actionable summary.
