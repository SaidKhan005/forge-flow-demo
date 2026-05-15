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
| Captured so far | `p1_00` through `p1_08` (9 captures + thumbs) covering surfaces 00, 01, 02, 03, 04, 05, 06, 07 (surface 01 ticked `[!]` — gap filed) |
| Pass | mid Pass 1 — resume at surface 08 (MO-H-1 live button explainer) next |
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
- [!] 01 — Drawer open (☰ → business scope picker: operator + location) — drawer titled "Locations" + empty in demo; filed `Mobile-FU-business-scope-drawer-empty-in-demo`; `p1_07_business_scope_picker.png`
- [x] 02 — Notifications screen (🔔 → fullscreen dialog) + mark-as-read tick — `p1_08_notifications_screen.png`
- [x] 03 — Sync state badge tap (if interactive) — non-interactive (read-only); parity with operator-web

### Shift tab
- [x] 04 — Whole Day (default, authoritative) — `p1_01_shift_whole_day_populated.png`
- [x] 05 — Lunch daypart (chip selected) + driver chip + lever card + time-into-service header — `p1_02_shift_lunch.png`
- [x] 06 — Dinner daypart (chip selected, the ACTIVE NOW one from boot capture) — `p1_03_shift_dinner.png`
- [x] 07 — Late Night daypart (chip selected, empty/idle expected) — `p1_04_shift_late_night.png`
- [ ] 08 — MO-H-1 live button explainer

### Variance tab
- [ ] 09 — This Week sub-tab (default)
- [ ] 10 — History sub-tab
- [ ] 11 — Learn sub-tab
- [ ] 12 — Variance row drill → WeekDetailScreen
- [ ] 13 — Daypart toggle within each variance tab (if present)

### Plan tab (ScheduleBuilder)
- [ ] 14 — Day rows collapsed (default week view)
- [ ] 15 — Day row expanded → per-daypart forecast rows
- [ ] 16 — Edit baseline path (drill or in-place)
- [ ] 17 — Publish path + conflict resolution dialog (if reachable)

### Benchmark tab (BaselineTracker)
- [ ] 18 — Default view (range graph + Baseline targets card)
- [ ] 19 — Manager override CTA → BaselineManagerScreen (calendar of shifts)
- [ ] 20 — Star a shift (tap one to add to selection) — Pass 1 happy path, single star
- [ ] 21 — Day detail drill
- [ ] 22 — Preview + actions
- [ ] 23 — Return to Benchmark with override banner "1 STAR SHIFT SELECTED" visible
- [ ] 24 — RP-15 cap state (only if reachable as Owner; otherwise code-anchor + file FU)

### Settings — Setup tab
- [ ] 25 — Setup tab landing (tab order verify: Setup / Integrations / Data / Account)
- [ ] 26 — Covers setup section + Add entry / per-shift override modal
- [ ] 27 — Business timing section (HP #11 triple: scope / inherited-from / effective)
- [ ] 28 — Wage authority section + per-position wage editor

### Settings — Integrations tab
- [ ] 29 — Integrations tab landing (vendor list, MP-1)
- [ ] 30 — Per-vendor row → detail (status, needs-reauth path if seeded)
- [ ] 31 — B11.1 handoff-code generator
- [ ] 32 — Demo→Live master switch row (observe presence + label; do not flip yet)

### Settings — Data tab (F&F-admin only — may be hidden in demo)
- [ ] 33 — Data tab landing + per-table freshness rows
- [ ] 34 — Account info row (verify "Two-factor sign-in: Off" canonical post-PR #753)
- [ ] 35 — Reset / refresh actions

### Settings — Account tab
- [ ] 36 — Account tab landing (Identity card)
- [ ] 37 — Change password drill
- [ ] 38 — MFA section "Two-factor sign-in" header (PR #753 canonical) + enroll CTA
- [ ] 39 — Active Sessions list
- [ ] 40 — Per-session remote sign-out confirm dialog
- [ ] 41 — U-FU-mobile-deeplink handoff-code generator

### Auth (Pass 2 covers cold-boot login flow; Pass 1 captures already-signed-in only)
- [ ] 42 — (deferred to Pass 2)

---

## Surface inventory (Pass 2 — cold boot)

- [ ] P2-01 — Splash (first paint after `adb install` + launch)
- [ ] P2-02 — Welcome / sign-in landing (demo build behavior TBD on uninstall+reinstall)
- [ ] P2-03 — Login screen
- [ ] P2-04 — MFA challenge (if demo seed pre-enrolls a factor)
- [ ] P2-05 — First-frame Shift dashboard (any empty-state copy bugs?)
- [ ] P2-06 — Pull-to-refresh on each tab (catches demo-seed-not-loaded state)
- [ ] P2-07 — Settings → Account empty state
- [ ] P2-08 — Settings → Integrations empty state (zero vendors connected)
- [ ] P2-09 — Settings → Setup empty state (no covers / timing / wage seeded)
- [ ] P2-10 — Notifications empty state (zero unread)

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
