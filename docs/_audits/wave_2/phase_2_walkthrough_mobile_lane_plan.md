# Phase 2 walkthrough — mobile lane plan

> **Created 2026-05-14 night.** Owner: orchestrator (Main Claude).
> Purpose: persist the mobile-lane game plan across session boundaries
> so the operator can resume in any clone if context dies.
>
> Authority order: this doc is **sub-ordinate** to
> `docs/_audits/wave_2/phase_2_walkthrough_master_plan.md`. When
> conflicts arise, the master plan wins. This doc only refines mobile
> lane mechanics + adds the sub-click inventory the master plan
> deferred.

---

## Continuation prompt (paste into a fresh session to resume)

```
You are resuming the Phase 2 walkthrough MOBILE lane per
`docs/_audits/wave_2/phase_2_walkthrough_mobile_lane_plan.md`. Read
that file top to bottom before anything else. Also read
`docs/_audits/wave_2/phase_2_walkthrough_master_plan.md` for cross-
lane state. The rolling evidence matrix lives at
`docs/_audits/wave_2/phase_2_walkthrough_verification.md`.

Workflow:
 1. Confirm emulator state. The plan was authored against a Pixel_9
    AVD on `emulator-5554` (API 36) with `com.forgeflow.app` installed.
    If the emulator is gone, recreate: `emulator -avd Pixel_9 &` then
    `flutter run -d emulator-5554 -t lib/main_forgeflow.dart --flavor
    forgeflow --dart-define=kDemoMode=true` in a background task.
 2. Confirm live error monitor is streaming. The smart filter command
    is in the "Live monitor" section below. Restart if dead.
 3. Open the surface inventory below; resume at the first row whose
    `Captured` column is blank. Each surface = screenshot + matrix
    annotation + gap-file-if-needed.
 4. Drive PASS 1 (demo-seeded happy path) end to end, then PASS 2
    (uninstall + reinstall = cold boot empty states), then PASS 3
    (permission gating + state edges).
 5. Demo->Live master switch is parked for LAST (observe-plumbing-only,
    do not flip).
 6. Commit + push after every 4-6 surfaces. Use the operator-web
    commit cadence as the model.
 7. Audit + merge Claude 2's RP-15 + Support admin PRs when they
    land — those interrupts are parallel-safe.

Solo on the emulator (no Claude 2 collaboration on this lane — single
device, sequential state machine, single log channel). Claude 2 stays
on its admin V1.1 carry-overs. See parallelism notes at the bottom.

Worktree agents are NOT used for this lane — orchestrator drives
directly on `claude/mobile-lane-pass-1` (continuation from
`claude/blissful-roentgen-e365a2`, merged via PR #754) because the work
is screenshots + matrix annotations, not source edits. If a demo-
fidelity bug surfaces that needs a source edit > 20 LoC, then a
worktree agent gets spawned with the standard contract (branch → fix
→ self-audit → commit → push → open PR → STOP).
```

---

## Current state (refreshed when committing)

| Item | Value |
|---|---|
| Branch | `claude/mobile-lane-pass-1` (continuation; prior branch merged via PR #754) |
| Worktree | `C:/Git Local Repos/forge_flow_demo/.claude/worktrees/mobile-lane-pass-1` |
| Emulator | Pixel_9, `emulator-5554`, API 36, `com.forgeflow.app` (recreate if gone) |
| Flutter run task | recreate per resume prompt (prior `bam7vhie1` is dead) |
| Live monitor task | restart per "Live monitor" section below |
| Captured so far | `p1_00` through `p1_24` (25 captures + thumbs) covering surfaces 00, 01, 02, 03, 04, 05, 06, 07, 08, 09, 10, 11, 13, 14, 15, 17 (drawer post-PR-755), 18, 19, 20+21+22 (combined), 23. Surface 01 ticked `[!]` (gap re-opened post-PR-755 live re-drive). Surfaces 12, 16, 17, 24 are 🚧 STUB or cut-from-V1 — code-anchored, not driveable. |
| Pass | mid Pass 1 — Bottom-nav tabs (Shift / Variance / Plan / Benchmark) COMPLETE. Remaining: top-bar Settings drawer (`⚙` gear) → surfaces 25-41 across Setup / Integrations / Data / Account tabs. |
| Screenshot dimension cap | Pixel 9 emulator captures are 1080×2424 — exceeds Anthropic's 2000px many-image cap. Capture full-res to evidence dir, save a ≤1600px thumb for Claude. Do NOT bulk-attach; show Claude a thumbnail only when investigating an anomaly. The matrix annotation is the durable record. |

---

## Three-pass plan

### Pass 1 — demo-seeded happy path (Owner actor)
Drive every reachable surface with the demo seed loaded. Capture every
sub-click. Expected: ~60-80 distinct screens. Time budget: 2-3 hours.

### Pass 2 — cold boot + empty states
`adb uninstall com.forgeflow.app` → reinstall same APK (decision (a)
from operator: same build, just wipe SQLite). Watch splash → first
frame → demo seed reload. Walk every tab to verify empty states
render correctly. Catches HP #11 null-interpolation bugs (same class
as the operator-web `U-FU-hp11-account-demo-defaults` we fixed).

### Pass 3 — permission gating + state edges
- Data tab F&F-admin-only gating (visual + functional deep-link block)
- Account → 2FA sub-states (Off / Enrolling / Enrolled / View recovery /
  Request removal / Pending / Removable)
- Active Sessions multi-device + remote sign-out
- Integrations vendor "needs reauth" state
- **Demo→Live master switch (LAST)** — observe-plumbing-only; do not
  flip the operator. Tap the switch, watch the confirm dialog, watch
  the row state machine, dismiss without committing.

---

## Surface inventory (Pass 1)

Legend: `[ ]` = not captured, `[x]` = captured + annotated, `[!]` = gap filed.

### Top bar + drawer (every screen)
- [x] 00 — Boot baseline (Shift dashboard, demo-seeded) — `p1_00_baseline_post_v3.png` + `p1_05_resume_baseline.png`
- [x] 01 — Drawer open (☰ → business scope picker) — ✅ RESOLVED via [PR #756](https://github.com/SaidKhan005/forge-flow-demo/pull/756) salvage (master `2c54abfa`); live re-drive at `p1_28_drawer_post_pr756_salvage.png` confirms drawer populates with Barrio Legado + active-row check icon; salvage audit at [docs/_audits/wave_2/pr_drawer_seed_followup_salvage.md](docs/_audits/wave_2/pr_drawer_seed_followup_salvage.md)
- [x] 02 — Notifications screen (🔔 → fullscreen dialog) + mark-as-read tick — `p1_08_notifications_screen.png`
- [x] 03 — Sync state badge tap (if interactive) — non-interactive (read-only); parity with operator-web

### Shift tab
- [x] 04 — Whole Day (default, authoritative) — `p1_01_shift_whole_day_populated.png`
- [x] 05 — Lunch daypart (chip selected) + driver chip + lever card + time-into-service header — `p1_02_shift_lunch.png`
- [x] 06 — Dinner daypart (chip selected, the ACTIVE NOW one from boot capture) — `p1_03_shift_dinner.png`
- [x] 07 — Late Night daypart (chip selected, empty/idle expected) — `p1_04_shift_late_night.png`
- [x] 08 — MO-H-1 live button explainer — `p1_10_labor_not_connected_explainer.png` (Data sources bottom-sheet)

### Variance tab
- [x] 09 — This Week sub-tab (default) — `p1_11_variance_this_week.png` (🟡 possible CPLH color-polarity finding logged in matrix)
- [x] 10 — History sub-tab — `p1_12_variance_history.png`
- [x] 11 — Learn sub-tab — `p1_13_variance_learn.png`
- [🚧] 12 — Variance row drill → WeekDetailScreen — STUB per Agent B source-trace (onTap wired in `_VariancePill` but no detail route)
- [x] 13 — Daypart toggle — `p1_14_variance_thisweek_daypart.png` (reuses Shift's daypart chip-group pattern)

### Plan tab (ScheduleBuilder)
- [x] 14 — Day rows collapsed (default week view) — `p1_15_plan_week_collapsed.png`
- [🟢] 15 — Day row expanded → per-daypart forecast rows — `p1_16_plan_mon_expanded.png` (chevron toggle confirmed; expanded sub-rows below viewport, partial capture)
- [🚧] 16 — Edit baseline path (drill or in-place) — STUB per Agent B (permission key only, no mobile edit screen)
- [🚧] 17 — Publish path + conflict resolution dialog (if reachable) — STUB per Agent B (server state machine exists; UI not wired)

### Benchmark tab (BaselineTracker)
- [x] 18 — Default view (range graph + Baseline targets card) — `p1_18_benchmark_default.png`
- [x] 19 — Manager override CTA → BaselineManagerScreen (calendar of shifts) — `p1_19_baseline_manager_screen.png`
- [x] 20+21+22 — Star a shift + Day detail drill + Preview/actions (one screen, three inventory items) — `p1_21_star_lunch_selected.png` (LUNCH starred; PLAN IMPACT live-populated)
- [x] 23 — Return to Benchmark with override banner — `p1_24_benchmark_with_override.png` ("MANAGER OVERRIDE ACTIVE / 1 STAR SHIFTS SELECTED" banner + OPZ RANGE TOO NARROW + advisor prose)
- [🚧] 24 — RP-15 cap state — CUT FROM V1 per `project_v1_lean_cut_2026_05_03` memory

### Settings — Setup tab
- [x] 25 — Setup tab landing — `p1_25_settings_setup_tab.png`. **3 tabs only** (Setup/Integrations/Data) — Account tab absent on mobile; `FU-mobile-settings-account-tab-not-on-mobile` filed.
- [x] 26 — Covers setup section + Type-today's-covers card — same capture. `FU-mobile-covers-setup-hp11-triad-missing` filed (Applies to: scope visible but no inherited-from/effective).
- [🟢] 27 — Business timing section — partial below-fold capture (Timezone/Week starts/Business day visible); deferred to scroll-capture.
- [ ] 28 — Wage authority section + per-position wage editor — below fold, not captured this batch.

### Settings — Integrations tab
- [x] 29 — Integrations tab landing — `p1_26_settings_integrations.png`. 3 category cards (POS/Reservations/Labor) + delegate-to-operator-console row.
- [🟢] 30 — Per-vendor row → detail — GATED on location selection; not driveable from this surface.
- [🟢] 31 — B11.1 handoff-code generator — not on Integrations landing; deferred to source-trace.
- [x] 32 — Demo→Live master switch row — same capture. "Demo mode" card + "Live switch unavailable in this build" + disabled toggle. Matches `settings_demo_live_switch.dart` carve-out.

### Settings — Data tab (F&F-admin only — may be hidden in demo)
- [x] 33 — Data tab landing — `p1_27_settings_data.png`. **NOT hidden from demo operator** (inventory was wrong). DEMO pill + 8-row freshness table + Data reset section partial.
- [🟢] 34 — Account info row ("Two-factor sign-in: Off" canonical) — not visible on Data tab; mobile may not have a parallel surface. `Mobile-FU-account-info-row-on-data-tab` filed.
- [🟢] 35 — Reset / refresh actions — partial capture (Data reset section visible below fold).

### Settings — Account tab
- [🚧] 36-41 — ALL surfaces NOT ON MOBILE. Account tab is absent (`Tab N of 3` only). Filed as `FU-mobile-settings-account-tab-not-on-mobile`. Operator decision required: reconcile inventory or add the tab.

### Auth (Pass 2 covers cold-boot login flow; Pass 1 captures already-signed-in only)
- [ ] 42 — (deferred to Pass 2)

---

## Surface inventory (Pass 2 — cold boot)

> **Cold-boot method used**: `adb shell pm clear com.forgeflow.app` (wipes app data + SQLite, keeps APK). The standalone demo flavor never reaches a login/MFA flow (`requireAuth: false` builds skip the AuthGate per PR #756 root-cause), so P2-02 / P2-03 / P2-04 are STUB.

- [x] P2-01 — Splash / First-frame Shift dashboard — `p2_01_splash_first_paint.png`. EMPTY STATE: "LOCKED PLAN UNAVAILABLE" (clean copy, no null-interpolation bugs). Restaurant header missing on cold-boot — `FU-mobile-cold-boot-shift-header-missing` filed.
- [🚧] P2-02 — Welcome / sign-in landing — STUB: demo flavor builds with `requireAuth: false`, no welcome screen on cold boot
- [🚧] P2-03 — Login screen — STUB: same reason
- [🚧] P2-04 — MFA challenge — STUB: same reason
- [x] P2-05 — First-frame Shift dashboard — same as P2-01 (merged for capture efficiency)
- [x] (bonus) **Cold-boot drawer regression test** — `p2_02_drawer_cold_boot.png`. PR #756 verified live on cold boot — drawer renders Barrio Legado + check icon even when dashboard is empty.
- [x] P2-Variance — Variance tab cold-boot — `p2_03_variance_cold_boot.png`. FULLY POPULATED. Variance reads `shift_records` + `week_records` which ARE seeded by the cold-boot demo writer. Only `WeeklyPlanSnapshot` (the locked plan) is missing. `FU-mobile-notification-tray-inconsistent-with-locked-plan-state` filed (notification badge appeared on cold boot referencing a "Weekly Plan Locked" event while Shift says "no plan locked").
- [ ] P2-06 — Pull-to-refresh on each tab — deferred (could not reproduce a pull-to-refresh affordance reliably in this batch; the Integrations "Pull to refresh" hint copy was visible but no actual gesture-based refresh was exercised)
- [🚧] P2-07 — Settings → Account empty state — N/A (Account tab not on mobile per Pass 1 finding `FU-mobile-settings-account-tab-not-on-mobile`)
- [x] P2-Integrations — Settings → Integrations cold boot — `p2_07_settings_integrations_cold_boot.png`. Different copy than warm-boot; `FU-mobile-cold-boot-integrations-copy-divergence` filed.
- [x] P2-Setup — Settings → Setup cold boot — `p2_06_settings_setup_cold_boot.png`. Fully populated identical to warm-boot.
- [x] P2-10 — Notifications fullscreen cold boot — `p2_08_notifications_cold_boot.png`. 1 historical notification for 2026-03-23/29 plan lock — confirms my earlier "inconsistency" finding was a false positive; downgraded to UX nit.

---

## Surface inventory (Pass 3 — edges)

- [ ] P3-01 — Data tab gating (visual: tab absent for non-admin; functional: deep-link blocked)
- [ ] P3-02 — 2FA Off → Enrolling flow
- [ ] P3-03 — 2FA Enrolled → View recovery codes
- [ ] P3-04 — 2FA Request removal → Pending
- [ ] P3-05 — 2FA Removable → Disable
- [ ] P3-06 — Multi-device session in Active Sessions
- [ ] P3-07 — Integrations needs-reauth vendor state
- [ ] P3-08 — **Demo→Live master switch — observe-plumbing-only** (LAST)

---

## Validation criteria (per surface)

For every captured surface, the checklist is:

1. **Authority doc match** — does the rendered copy + behavior match the contract? Cite file:line.
2. **HP #11 triple** — settings surfaces render `scope / inherited-from / effective`. If missing, document why (backend-only / gated / incomplete).
3. **HP #2** — no `kDemoMode` reader branch beyond the 4 blessed carve-outs.
4. **HP #10** — UX is live, not just code-anchored. If a row in DEBUG_MD is marked DONE but isn't reachable on the device, downgrade with file:line evidence.
5. **MO-5b canonical** — every two-factor reference reads "Two-factor sign-in" (PR #753). If drift surfaces, file FU.
6. **Metric honesty** — every metric pill has state + provenance; no phantom zeroes.
7. **UX writing** — reads as training, plain English, no jargon.
8. **Tap target ≥ 48dp + no overflow + no `Bad state`** — from live monitor.

Demo-fidelity bugs caught LIVE:
- < 20 LoC mobile fix → inline edit + tests + commit
- ≥ 20 LoC OR cross-cutting → spawn worktree agent (standard contract)
- UX decision required → file as parked row in WAVE_2_LEDGER + escalate

---

## Live monitor (smart filter)

Old monitor `bfgrb9r2j` was firehose-grepping and got drowned by the
Crashlytics no-app loop. Replacement:

```bash
# Stop old monitor first via TaskStop.
# Then start the new one as a persistent Monitor task. Tail file:
#   C:\Users\saidu\AppData\Local\Temp\claude\<session>\tasks\bam7vhie1.output
# Filter EXCLUDES the Crashlytics loop, INCLUDES everything else
# actionable.
tail -f <flutter_run_log> \
  | grep -aE --line-buffered \
      "E/flutter|E/AndroidRuntime|FATAL EXCEPTION|Unhandled Exception|RenderFlex|overflowed by|RangeError|Null check|Bad state|late init|assertion failed|RenderObject|ANR in|FATAL:|StackOverflowError|OutOfMemoryError|Restarted application in" \
  | grep -v --line-buffered "Crashlytics\|crash_reporter\.dart\|\[core/no-app\]" \
  | tr -cd '\11\12\15\40-\176\n'
```

Description for the monitor: `"flutter errors (Crashlytics loop excluded)"`.

The Crashlytics loop is filed as a known gap (CrashReporter calls
`Firebase.initializeApp()`-dependent surface unconditionally on
non-web flavors — see [main_forgeflow.dart:23-25](lib/main_forgeflow.dart:23)).
Will be filed as `FU-mobile-crashlytics-init-loop` during mobile lane
closeout.

---

## Tooling refs

```bash
export PATH="$PATH:/c/Users/saidu/AppData/Local/Android/Sdk/platform-tools"
export MSYS_NO_PATHCONV=1   # stops Git Bash from rewriting /sdcard paths

# Screenshot
adb -s emulator-5554 shell "screencap -p /sdcard/screen.png"
adb -s emulator-5554 pull /sdcard/screen.png \
  "docs/_audits/wave_2/phase_2_walkthrough_evidence/mobile/NN_surface.png"

# Tap (x,y from screenshot — emulator is portrait)
adb -s emulator-5554 shell input tap X Y

# Swipe (for pull-to-refresh, drawer drag)
adb -s emulator-5554 shell input swipe X1 Y1 X2 Y2 DURATION_MS

# Back button
adb -s emulator-5554 shell input keyevent KEYCODE_BACK

# Uninstall (Pass 2)
adb -s emulator-5554 uninstall com.forgeflow.app

# Reinstall (Pass 2) — locate fresh APK first
find build/app/outputs -name "*.apk" -newer pubspec.yaml | head -5
adb -s emulator-5554 install -r <apk-path>
```

Screenshot filename convention: `NN_surface-shortname.png` (NN = the
inventory number above). Saved under
`docs/_audits/wave_2/phase_2_walkthrough_evidence/mobile/`. Pass 2 + 3
prefix with `p2_` / `p3_`.

---

## Parallelism notes (orchestra pattern)

Mobile lane is solo on the emulator (single device, sequential state
machine). But parallel work continues in the same repo:

1. **Claude 2** stays on its admin V1.1 carry-overs:
   `RP-15-FU-admin-demo-override-fixture` + `Support-FU-admin-walkthrough`.
   When their PRs land, orchestrator audits + merges inline between
   mobile screenshots — those are parallel-safe interrupts.

2. **Worktree fix agents** are dispatched the moment a demo-fidelity
   bug ≥ 20 LoC surfaces during mobile driving. Same contract as
   operator-web rounds: branch → fix → self-audit → commit → push →
   open PR → STOP. Orchestrator audits + merges. Mobile driving
   continues during the agent's work.

3. **Doc / matrix annotation batching** happens every 4-6 surfaces, not
   per surface — keeps git noise low.

4. **Parallel reads on the orchestrator side** — when the device is
   mid-tap or screenshot, the orchestrator may run code reads /
   contract loads / matrix queries concurrently. Sequential constraint
   is the device, not the orchestrator.

---

## Acceptance criteria (mobile lane done)

1. All ~22 top surfaces × sub-surfaces driven in Pass 1.
2. Cold-boot + empty states captured in Pass 2.
3. State edges + Demo→Live observation captured in Pass 3.
4. Every mobile-relevant row in DEBUG_MD_IMPLEMENTATION_STATUS +
   WAVE_2_LEDGER inline-annotated with this walkthrough's evidence.
5. Demo-fidelity bugs either fixed (PR merged) or filed with explicit
   defer note.
6. UX-decision gaps filed in WAVE_2_LEDGER + master plan Gaps register.
7. Master plan Status board "Mobile" lane flipped to ✅ DONE with
   final commit hash.
8. Live monitor stopped cleanly.
9. Tree clean.

---

## What this doc is NOT

- Not a substitute for the master plan. Read both.
- Not a contract — contracts live in `docs/contracts/**`.
- Not auto-updated. When state shifts (passes complete, gaps filed),
  edit the relevant section by hand and commit.
- Not a parking lot. Gaps go in WAVE_2_LEDGER + master plan Gaps
  register, not here. This doc only owns the mechanics + inventory.
