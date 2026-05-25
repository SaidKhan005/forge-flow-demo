# Test Health Triage Report

**Tested SHA:** `04c68b66` (origin/master, hard-synced into isolated worktree)
**Toolchain:** Flutter 3.35.7 / Dart 3.9.2 (confirmed)
**Command:** `flutter test --reporter json` (ran to completion, exit code 0; reporter `done.success=false`)
**Run date:** 2026-05-16

## Headline Counts

| Metric | Count |
|--------|-------|
| Total tests executed (non-hidden) | 9880 |
| Passed | 9751 |
| Failed (assertion) | 33 |
| Errored (exception/compile/load) | 87 |
| Skipped | 9 |

Total distinct failing tests: **120** (33 failure + 87 error). Two test files also failed to *load* (compile errors) — counted as 1 error each here, but each masks an entire file's worth of tests.

## KNOWN vs UNKNOWN

The overwhelming majority of the 120 failures are **environmental, not code regressions** — this worktree has no live local Postgres, no SIGTERM support (Windows), and no Flutter plugin host. Classified by whether they map to a `docs/KNOWN_FAILING_TESTS.md` quarantine row:

- **KNOWN (explicitly quarantined):** ~8 tests across 4 quarantine rows.
- **ENVIRONMENT (not regressions, not in quarantine but expected off-CI):** ~58 tests (live-Postgres SSL: 46; SIGTERM CLI: 6; SQLite migration table: 16 — overlaps; plugin host: 1).
- **UNKNOWN code-level (priority — potential undocumented drift):** ~30 tests in ~10 clusters.

### KNOWN failures that reproduced (still valid quarantine)
| Quarantine row | Reproduced? | Evidence |
|----------------|-------------|----------|
| `weekly_plan_snapshot_repository_test.dart` — `PackagePostgresPool` compile error (rows 19 & 23) | YES | `test_stderr.txt:1`; file fails to load at `:1162`,`:1202`,`:1226`,`:1250` |
| `p3c_oauth_refresh_storm_runner_test.dart` — registry assertions drift (row 17) | YES | 2 failures: `containsAll([...])` got `['agendrix']`; `hasLength(10)` got 12 |
| `admin_integrations_response_sanitization_test.dart` — `_StubHttpHeaders` shape (row 18) | YES | `webhook 500 path` expected `adapterError`, got `null` |
| `shift_visual_widget_test.dart` — whole-day Shift assertions (row 25) | YES | both `ShiftDashboard smoke` + `COVERS card "In the books 72"` failed |
| `vendor_relativity_label_test.dart` — QBT copy (row 22) | YES | `composeVendorRelativityLines` poll-only copy mismatch |
| operator-web router `management picker drives location-scoped vendor route` (row 24) | YES | `operator_web_router_test.dart` errored, same test name |

**Two quarantine rows are now STALE (confirmed passing via targeted re-run):**
`flutter test test/operator_web/screens/roles_screen_test.dart test/operator_web/screens/permission_explainer_screen_test.dart` → **"All tests passed!" (35/35)**. Therefore:
- **Row 20** (`permission_explainer_screen.dart` via `permission_explainer_screen_test.dart` — missing `team.hierarchy.suspend` description) — **NO LONGER REPRODUCES. Remove from quarantine.**
- **Row 21** (`roles_screen_test.dart` — removed `operator_web_custom_role_editor_role_key` field) — **NO LONGER REPRODUCES. Remove from quarantine.**

## UNKNOWN Failure Clusters (prioritized)

| # | Cluster | Files (count) | Root cause | Fix size | ROI / why |
|---|---------|---------------|------------|----------|-----------|
| 1 | **Permission-key catalog count drift (103/99 → 106)** | `auth/permission_catalog_b5b_test.dart`, `phase_9_0a_scope_extensions_test.dart`, `phase_9_0sigma_h2_audit_privacy_role_test.dart`, `role_permissions_repository_test.dart` (4) | Intentional recent code change: PR #870/#871 (`G7c`/`G7-pre`, very recent — top of `git log` on `permission_keys.dart`) reconciled the catalog to v2 roles → 106 keys. 4 tests still hard-assert old counts (99/103); the b5b test also greps the now-rewritten catalog doc. **Assertion drift vs intentional change.** | small (re-pin 4 numeric/string asserts to 106 + updated doc anchor) | **HIGHEST code-level ROI.** One coherent root cause unblocks 4 tests in one focused PR; clearly an un-repinned consequence of an accepted slice, not a behavioural bug. Strong stale-quarantine-add candidate if not fixed immediately. |
| 2 | **`shift_service_close_shift_test.dart` — WeekRecord not created** | `shift_service_close_shift_test.dart` (6) | `closing all 14 shifts creates a WeekRecord` expects 1 got 0; siblings throw `Bad state: No element`. Looks like a real behavioural regression in the close-shift → WeekRecord path (or shared fixture seam). | investigate | High ROI if real: 6 tests, core close-shift/Promise-3 path. Needs code inspection of `ShiftService.closeShift` WeekRecord emission. |
| 3 | **`persistence_scope_alignment_test.dart` — missing `target_cycle_dayparts` table on v8-upgrade path** | `persistence_scope_alignment_test.dart` (8) | All 8 throw `no such table: target_cycle_dayparts` during pre-v8 upgrade / partial-migration repair. A migration or seed teardown issues `DELETE FROM target_cycle_dayparts` against a schema version that predates that table. **Real migration-path defect or test-fixture ordering bug.** | investigate (small if fixture; medium if migration guard) | High ROI: 8 tests, single shared root cause, touches migration safety (House rule: migration drift scanner territory). |
| 4 | **`current_state_alignment_test.dart` — dashboard read-model + daypart weights** | `current_state_alignment_test.dart` (2) | (a) `getShiftDashboard returns null when no locked weekly plan` now returns an instance; (b) `J1b` canonical-weight alignment expected 64 got 61. Behavioural drift vs locked-plan / daypart-allocation contract. | investigate | Medium — touches Layer 9 / Promise 3 daypart truth; 2 tests but architecturally load-bearing. |
| 5 | **`restaurant_scope_notifier_test.dart` — boot-time drawer seed** | `state/restaurant_scope_notifier_test.dart` (2) | Both expect `length 1` but get 2 `BusinessScope` instances — seed now emits multiple scopes. Likely intentional multi-location seed change without test re-pin (HP#11 mobile flat-hierarchy area). | small | Medium — 2 tests, likely simple re-pin once confirmed intentional. |
| 6 | **`advisor_model_config_service_test.dart` — proxy /healthz probe** | `services/advisor/advisor_model_config_service_test.dart` (3) | All 3 expect `reachable`/`503`/path-prefix but get a flat `HTTP 400 from /healthz`. The probe stub or URL composition changed; tests not re-pinned. | small | Medium — 3 tests, one root cause in `probeForgeFlowProxyHealth` stub wiring. |
| 7 | **`mfa_card_controller_test.dart` — copy "2FA" → "two-factor sign-in"** | `operator_web/account/mfa_card_controller_test.dart` (2) | Tests expect `'removing 2FA'` / `'cancelling 2FA removal'`; production copy is now `'two-factor sign-in'`. Pure UX-copy assertion drift vs an intentional UX-writing-standard change. | 1-line each | Medium — trivial re-pin; aligns with project UX writing standard (avoid jargon "2FA"). |
| 8 | **poll-only labor adapters — webhook signature verifier "exists"** | `agendrix`/`humanity`/`push_operations`/`quickbooks_time` `_labor_adapter_test.dart` (4) | All 4 "banned items grep" tests expect NO webhook signature verifier file for poll-only vendors, but a file now exists (`Actual: true`). Either a shared signature verifier was added that the grep over-matches, or a real banned-item leak. | investigate | Medium-High — 4 tests, identical root cause; could be a real architecture-guardrail breach (poll-only must not ship signature verifier) OR an over-broad test grep. Worth confirming which. |
| 9 | **`provider_credentials_repository_test.dart` — refresh-failure counter & no-closure set** | `provider_credentials_repository_test.dart` (2) | Counter contract expects increment to 1 got 0; no-closure vendor set expected 7 got 4 (`['agendrix','humanity','push_operations','tock']`). Same vendor-registry pare-down family as quarantine row 17 — likely an *extension* of that known drift to a sibling file. | small | Medium — pairs with KNOWN row 17; fold into the same registry-re-pin follow-up. |
| 10 | **`audit_log_hierarchy_filter_pane_test.dart` — compile error (missing `renameOrgUnit`)** | `operator_web/screens/audit_log_hierarchy_filter_pane_test.dart` (1, blocks file) | `_StaticWebTeamHierarchyGateway implements WebTeamHierarchyGateway` is missing `renameOrgUnit` (added to the interface in `web_team_hierarchy_gateway.dart:53` without updating this test double). **Compile error — UNKNOWN, not quarantined.** | 1-line (add stub method to the test double) | **High ROI per-effort:** 1-line fix unblocks the whole file's load; classic interface-drift-vs-test-double. NEW undocumented breakage. |
| — | Misc singletons | `phase_9_0sigma_f_audit_chain_e2e_test.dart` (3: `actor_kind` user→team_member), `restaurant_timing_config_repository_test.dart` (lunch weekdays 1-5 got 1-7), `phase_9_0sigma_e_event_outbox_test.dart` (Phase 10a plan doc missing), `shift_dashboard_notifier_test.dart` (inTheBooksCovers 72→144), `per_daypart_v1_demo_seed_..._open_shift_test.dart` (date off-by-one 05-17 vs 05-16, likely real-clock flake), `sevenrooms_credential_bridge_test.dart` (DateTime not encodable), several `*_visual_widget_test.dart` / `baseline_operating_strip_align_test.dart` / `shift_dashboard_daypart_parity_test.dart` (golden/layout `Test failed. See exception logs above.`) | mixed | mixed | Lower ROI — heterogeneous; triage individually. The `actor_kind user→team_member` trio and `lunch weekdays 1-5→1-7` and `inTheBooksCovers 72→144` each look like real behavioural drift worth a focused look. The date off-by-one is a real-device-clock flake (today=2026-05-16). |

### Environment clusters (NOT regressions — expected in this sandbox)
- **Live-Postgres SSL (46 tests):** `rls_isolation_p2_repos_test.dart` (27), `business_timing_profiles_repository_test.dart` (16), `forward_apply_populated_db_test.dart` (2), `demo_flip_race_test.dart` (1) — all error `Server does not support SSL, but it was required`. No local Postgres with SSL in this worktree. Not a code regression.
- **SIGTERM CLI (6 tests):** `phase_9_0sigma_f_audit_logs_test.dart` (5), `tool/audit_anchor/advisory_lock_test.dart` (1) — `SignalException: Failed to listen for SIGTERM ... not supported` (Windows). Environmental.
- **Plugin host (1):** `mobile_push_notification_service_test.dart` — `MissingPluginException ... shared_preferences`. Environmental.

## Single Highest-ROI Fix

**Two co-leading candidates — the quarantine-doc prediction is only partly accurate:**

1. **Quarantine-predicted `weekly_plan_snapshot_repository_test.dart` import fix — does NOT unblock 44 tests in this run.** The prediction assumes `flutter test` aborts the whole `postgres/repositories/` directory on the compile error. It did **not**: only that one file failed to load; the other 36 files in the directory ran (and then failed on the live-Postgres SSL environment cluster instead). So the 1-line import add (`package_postgres_pool.dart`) is still correct and cheap, but in a no-Postgres environment it converts a "load error" into "SSL errors," net-unblocking 0 *passing* tests here. In CI with a live Postgres it would matter — keep it as a cheap correctness fix, but the "unblocks 44" framing does not hold at SHA `04c68b66`.

2. **Actual highest code-level ROI: Cluster 1 (permission-key catalog 103/99 → 106).** One root cause (recent accepted PR #870/#871 v2-role catalog reconcile), four red tests, all simple numeric/string re-pins, zero behavioural risk, and it is a textbook un-repinned-after-intentional-change drift. Fixing it removes 4 failures and prevents 4 future false-regression reports.

3. **Best effort-to-unblock ratio: Cluster 10** — 1-line stub of `renameOrgUnit` on `_StaticWebTeamHierarchyGateway` unblocks an entire compile-failed file and is a brand-new undocumented breakage (interface grew, test double didn't).

**Recommendation:** land Cluster 1 + Cluster 10 + the cheap `weekly_plan_snapshot` import together (all assertion/compile drift from accepted changes), then investigate Clusters 2, 3, 8 as the genuine "is this a real behavioural/guardrail regression?" candidates.

## Stale-quarantine candidates (CONFIRMED)
- **Row 20** — `permission_explainer_screen_test.dart` — targeted re-run **passes**. Remove.
- **Row 21** — `roles_screen_test.dart` — targeted re-run **passes**. Remove.

(`docs/KNOWN_FAILING_TESTS.md` is Codex-maintained; this report only recommends. No edits made to the quarantine doc or any tracker.)
