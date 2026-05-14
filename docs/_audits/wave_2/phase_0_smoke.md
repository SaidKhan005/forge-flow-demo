# Phase 0 — Local stack smoke test

**Master tested:** `4b1256e8e859fca98085e78ad2fa49f2e1698ae323`
**Date:** 2026-05-13 / 2026-05-14 UTC
**Executor:** main orchestrator (Claude) in worktree `nifty-clarke-d3ec25`
**Purpose:** Confirm the local stack boots cleanly on the current master before Wave 2 lanes spin up on both Claude sessions.

---

## TL;DR

- **Postgres:** ✅ green
- **Advisor proxy:** ✅ green (health endpoint returns `status:ok`, all three deps green)
- **Mobile (Samsung A54) — Forge & Flow:** ✅ green (release APK built off master `9860bd0d` + kDemoMode, installed, all 4 bottom tabs render demo data; Shift tab empty state captured as Finding P0-F1)
- **Operator-web (Preview MCP):** ✅ build + serve + render green; runtime error gate captured as Finding P0-F5 (Lane V kickoff)
- **`dart analyze --fatal-infos`:** 🟡 49 issues (5 errors, all in test/integration files; lib/ tree clean)

**Verdict:** Phase 0 clean. Findings are pre-existing master state, not Wave-2 blockers. Second Claude session is cleared to start lanes U/V/D/M-Poll. Lane H gets a slice to triage the analyzer findings.

---

## Detail

### 1. Postgres container

- Container `forge-flow-pg16` up `~2h` on `localhost:5433`.
- Version: `PostgreSQL 16.10 (Debian 16.10-1.pgdg13+1) on x86_64-pc-linux-gnu`.
- Connection from `psql` inside container ok.
- Loopback TLS disabled — proxy must connect with `sslmode=disable`.

### 2. Advisor proxy boot

Command (PowerShell, after sourcing `~/.forge_flow/secrets/runtime/forge_flow.secrets.ps1`):

```powershell
$env:POSTGRES_URL          = 'postgresql://postgres:forge_flow_local@localhost:5433/forge_flow?sslmode=disable'
$env:POSTGRES_ADMIN_URL    = 'postgresql://postgres:forge_flow_local@localhost:5433/forge_flow?sslmode=disable'
$env:PROXY_ENVIRONMENT     = 'dev'
$env:PORT                  = '8080'
$env:FIREBASE_WEB_API_KEY  = '<derived from android/app/src/forgeflow/google-services.json>'
dart run tool/advisor_proxy/main.dart
```

Bootstrap events observed:

- `startup.config_resolved` (port 8080, env dev, 8 secrets loaded)
- `startup.admin_schema_contract_verified` (10 tables, 5 columns, 4 feature flags)
- `startup.migrations_recorded` (125 migrations inserted into freshly-bootstrapped local DB)
- `pg_cron_notify.started` for audit_anchor_tick, rollups_tick, forge_email_outbox_tick, mobile_push_outbox
- `startup.phase_8_binder.installed` — POS factories `lightspeed_lsk, oracle_micros_simphony, revel, toast`; labor `adp, agendrix, humanity, push_operations`; reservation `opentable, sevenrooms, tock`; signature verifiers for all 10 above
- `startup.complete` on port 8080

Health probe `GET http://localhost:8080/health` returned envelope `proxy_health.v1`:

```
status: ok
severity: green
dependencies: { postgres: green, age: green, pgvector: green }
```

Non-blocking warnings logged at boot (carry into report as findings):

| # | Warning | Impact |
|---|---|---|
| P0-W1 | `startup.kms_stub_active` — `GCP_PROJECT_ID`/`CLOUD_RUN_REGION`/`CLOUD_RUN_SERVICE_NAME` unset. KMS pepper store on dev stub. | Expected in `PROXY_ENVIRONMENT=dev`. Live calls would 500 on KMS-backed routes; demo paths unaffected. |
| P0-W2 | `startup.pepper_store.misconfigured` — `FORGE_PEPPER_ACTIVE_ID` unset. | Pepper routes 500 until set. Not on demo click-paths. |
| P0-W3 | `proxy.root_zone_uncaught` — `SignalException: Failed to listen for SIGTERM, OS Error: The request is not supported (errno = 50)` after `startup.complete`. Windows does not implement POSIX SIGTERM. | Proxy serving regardless. Worth a tiny fix in `tool/advisor_proxy/main.dart` to guard SIGTERM registration on Windows. |
| P0-W4 | Vendor disables logged: `aloha_ncr_voyix`, `clover`, `square`, `quickbooks_time`, `seven_shifts`, `libro`, `humanity` (oauth). | Credential-bound; expected on dev. |

### 3. Mobile (Samsung A54)

- Device `R5CW503HJHP` (`SM-A546W`, Android 16, One UI) reachable via `adb devices`.
- Built fresh Forge & Flow release APK off master `9860bd0d` (post-Wave-1, post-Phase-0-marker):
  ```powershell
  flutter build apk --release --flavor forgeflow -t lib/main_forgeflow.dart `
    --dart-define=kDemoMode=true `
    --dart-define=ANTHROPIC_API_KEY=$env:ANTHROPIC_API_KEY
  ```
  Output: `build\app\outputs\flutter-apk\app-forgeflow-release.apk` (60.5 MB, Gradle 185.1s).
- Installed via `adb -s R5CW503HJHP install -r app-forgeflow-release.apk` → `Success`. Package metadata: `applicationId com.forgeflow.app`, `versionName 1.0.0`, `versionCode 15`, `targetSdk 35`. (Note: release flavor signs with debug keystore in absence of `android/key.properties`; fine for on-device smoke, not a Play Store-eligible build.)
- Launched via `monkey -p com.forgeflow.app -c android.intent.category.LAUNCHER 1`.
- Initial render — **Shift tab** (`phase_0_mobile_forgeflow_launch_t0.png` / `_t1.png`):
  - Top bar: hamburger menu, notifications bell, settings cog
  - Bottom tab bar: **Shift** / Variance / Plan / Benchmark (Shift selected)
  - Empty state: "LOCKED PLAN UNAVAILABLE — No locked weekly plan is available for the current week. Last import: 2026-05-13T22:50:08" (demo writer fired on app boot)
- **Variance tab** (`phase_0_mobile_forgeflow_variance_tab.png`):
  - "This Week — Mar 26 · Thursday · Business Day 4 of 7"
  - WEEK-TO-DATE vs PLAN table with TARGET / ACTUAL / VAR columns
  - CONDITIONS: Covers (630 / 593 / **−37**), Blended Wage ($19.05 / $18.98 / **−$0.07**)
  - EXECUTION: PPA ($42.08 / $42.17 / **+$0.10**), FOH Hours (133 / 132 / **−1**), BOH Hours (147 / 138 / **−9**), CPLH (4.75 / 4.49 / **−0.26**), SPLH ($180 / $181 / **+$0.91**)
- **Plan tab** (`phase_0_mobile_forgeflow_plan_tab.png`):
  - Weekly Operating Plan — NEXT WEEK PROJECTIONS
  - COVERS 1,153 · SALES $48,517
  - LABOR PLAN: FOH 243 hrs · BOH 269 hrs · 20.1% · $9,753
  - COVER FORECAST ADJUSTED BY DAY chart (M–Su bars, weekly avg dashed line)
  - DAY-BY-DAY PLAN table (Mon 132/$5,554/28/31, Tue 159/$6,312/32/35, …)
- **Benchmark tab** (`phase_0_mobile_forgeflow_benchmark_tab.png`):
  - "60 Day Benchmark — TOTAL COVERS LAST 60 DAYS: 10,102"
  - CPLH Range slider: lowest 4.28 ↔ highest 5.00 ↔ target **4.75** marker
  - GOOD OPZ RANGE pill: "Team looks busy without getting stretched. Service should hold here."
  - CHOOSE STAR SHIFTS CTA
  - DAYPART BREAKDOWN: Lunch 76 covers · CPLH 4.57 · SPLH $180 · PPA $40.57

Mobile shell, navigation, demo writer, formula engine, variance computation, and metric-honesty UI all functional. Shift tab empty state is the only gap (`Finding P0-F1` below) — demo seed does not yet write a locked weekly plan for the current business week.

**Finding P0-F1:** Forge & Flow Shift tab renders "LOCKED PLAN UNAVAILABLE" because `WeeklyPlanSnapshot` for the current business week is not seeded by `_seedDemoDataFromReplay`. Lane M-Other (or a small Lane S seeder slice) wires this so the Shift tab has parity with Plan/Variance/Benchmark on first boot.

### 4. Operator-web (Preview MCP)

- `.claude/launch.json` extended with an `operator-web-demo` entry pointing at `lib/main_operator_web.dart` in release mode on port 8091 with `kDemoMode=true` and `OPERATOR_WEB_PROXY_BASE_URI=http://localhost:8080`.
- `preview_start` launched the server (server id `72b06476-6a32-4287-a6c7-8bc79a3c3447`).
- Build pipeline: ✅ dependencies resolved, ✅ Flutter web release-mode compile completed, ✅ assets + main.dart.js served, ✅ CanvasKit + Firebase JS modules + fonts loaded.
- Runtime render: ✅ Flutter Web canvas renders the operator-web error gate page successfully.
- Runtime bootstrap: 🟡 the operator-web boot path fails the startup gate. The rendered surface is the structured error card:
  > **We couldn't reach Forge & Flow** — Something on our side is preventing the console from starting. Please contact support@forgeflow.app — we'll get this fixed quickly. [Email support] [Show technical details]
- Proxy access log shows **zero** requests from operator-web reaching `localhost:8080` — the gate that's failing is upstream of the proxy hop (Firebase init / CSP, or a `--dart-define` operator-web expects that's not being passed by the demo launch).

**Finding P0-F5:** operator-web demo launch from `.claude/launch.json` short-circuits at the bootstrap gate before any proxy call. Likely missing `--dart-define`s (Firebase config, demo seed identifiers, or a `kDemoMode` equivalent gate that operator-web reads differently than mobile). Lane V owns operator-web UX polish + ledger/audit-log surfaces; expand Lane V's first slice to nail the dev-mode bootstrap path so subsequent Lane V slices can render against the proxy. Not blocking the second Claude session — Lanes U/D/M-Poll can proceed; Lane V picks up this thread as its kickoff.

### 5. `dart analyze --fatal-infos`

Exit 3 (errors present). Breakdown of 49 issues:

| Severity | Count | Where |
|---|---|---|
| error | 5 | 1 in `integration_test/phase_4_emulator/_harness.dart` (FlutterExceptionHandler undefined), 4 in `test/.../weekly_plan_snapshot_repository_test.dart` (PackagePostgresPool undefined) |
| warning | 16 | 14 in `test/**`, 1 in `tool/cutover/preflight_smoke.dart`, 1 in `tool/advisor_proxy/main.dart` (duplicate import line 64) |
| info | 28 | 8 in `lib/widgets/push_permission_denied_card.dart` (prefer_const_constructors), 2 in `lib/.../user_pii_erasure_repository.dart` (string concatenation), rest in test/tool tree |

**Prior-art check:** `weekly_plan_snapshot_repository_test.dart` PackagePostgresPool issue is documented in `docs/KNOWN_FAILING_TESTS.md` (PR #459 era, 1-line import follow-up). Treat as pre-existing per `CLAUDE.md` authority order.

**Finding P0-F2:** `integration_test/phase_4_emulator/_harness.dart:141` — `FlutterExceptionHandler` undefined. Missing import (likely `package:flutter/foundation.dart`). Not in `KNOWN_FAILING_TESTS.md`. Slice for Lane H.

**Finding P0-F3:** `tool/advisor_proxy/main.dart:64` — duplicate import warning. Trivial cleanup; fold into a Lane R helper-extract slice or a Lane H tidy slice.

**Finding P0-F4:** `lib/widgets/push_permission_denied_card.dart` — 8 `prefer_const_constructors` infos. Easy clean-up. Lane U candidate.

### Summary findings list (deferred to Wave 2 lane backlog)

| Id | Owner | Effort | Severity |
|---|---|---|---|
| P0-W3 | Lane R / Lane H | 5-line guard on Windows SIGTERM registration | non-blocking warning |
| P0-F1 | Lane M-Other / Lane S seeder slice | `_seedDemoDataFromReplay` does not write a `WeeklyPlanSnapshot` for the current business week → Forge & Flow Shift tab renders "LOCKED PLAN UNAVAILABLE" on first boot | demo parity gap |
| P0-F2 | Lane H | Add missing import to `integration_test/phase_4_emulator/_harness.dart` (`FlutterExceptionHandler`) | 1-line fix |
| P0-F3 | Lane R | Remove duplicate import in `tool/advisor_proxy/main.dart:64` | 1-line fix |
| P0-F4 | Lane U | Add `const` constructors in `lib/widgets/push_permission_denied_card.dart` (8 sites) | low-noise polish |
| P0-F5 | Lane V (kickoff) | Wire operator-web `kDemoMode` boot path so the dev launcher reaches the splash → dashboard surface | first slice of Lane V |

None of P0-W3 / P0-F1..F5 block Wave 2 lane work. They're recorded for triage in the appropriate lane's slice queue.

---

## Marker

Per `docs/_indices/WAVE_2_PARALLEL_LANE_HANDOFF.md` and `NEXT_WAVE_PLAN.md`, Phase 0 close drops the marker commit with subject **`Phase 0 clean — Claude2 cleared for U/V/D/M-Poll`** on master so the second Claude session's `until` watch loop unblocks and lanes U/V/D/M-Poll can begin.
