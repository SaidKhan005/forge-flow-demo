# Next Wave Plan — Post-Codex Closeout → V1 Deploy

> **Created:** 2026-05-13. **Revised:** 2026-05-13 twice — first after
> the debug.md implementation-status audit (PR #646) surfaced 29 new
> slices, then again when the operator collapsed the pre-Wave-2
> "demo-validate walkthrough" into a single comprehensive post-Wave-2
> validation phase (cleaner sequencing, faster execution, no idle time
> for second-Claude lanes).
>
> **Operator-locked decisions 2026-05-13:**
> (a) **Roles are hierarchy-scoped**;
> (b) **Wave 2 keeps all 29 slices** plus 4 bug fixes (33 total);
> (c) **All bug fixes pull into Wave 2** (not deferred);
> (d) **Dual-Claude execution** — main orchestrator + second-Claude lane
> orchestrator running in parallel from Phase 0 close (Codex out of quota);
> (e) **Single comprehensive walkthrough post-Wave-2**, not split
> pre/post (validation, not scoping — scoping is what the debug.md audit
> already did).
>
> **Status:** Active. 6-phase pipeline.
> **Owner:** Operator drives sequencing; main orchestrator + second
> Claude lane execute.

Companion to `docs/_indices/WAVE_EXECUTION_LEDGER.md` (Wave 1's slice
ledger; CLOSED 2026-05-13) and `docs/_indices/WAVE_2_LEDGER.md` (Wave 2's
slice ledger; the canonical source for who-does-what across the 33 Wave 2
slices). Second-Claude handoff prompt persists at
`docs/_indices/WAVE_2_PARALLEL_LANE_HANDOFF.md`.

## The 6-phase pipeline

```
Phase 0   Local stack smoke test (against Wave 1's final state)
Phase 1   Execute Wave 2 (33 slices across 11 lanes — full dual-Claude parallel from Phase 0 close)
Phase 2   Comprehensive walkthrough (visual + functional, backend + frontend) → TAG HAPPY STATE
Phase 3   Refactor (R-1 + R-2 + R-3 — against the polished, operator-blessed surface)
Phase 4   Re-test against the happy-state tag (catch refactor regressions)
Phase 5   Mutate staging + Production1 (migrations + deploy)
Phase 6   Post-launch operational (SOPs, vendor outreach, soak completion)
```

Each phase is operator-gated. Orchestrator does not advance the pipeline
without explicit "go" — these are large changes whose sequencing has
business impact.

**Critical sequencing note (operator decision 2026-05-13, revised):**
**Walkthrough happens ONCE, after Wave 2 lands.** A pre-Wave-2 walkthrough
would be reactive scoping against an incomplete surface (UX polish + debug
fixes not yet in). The debug.md audit (PR #646) already did the scoping
work. The single post-Wave-2 walkthrough is comprehensive validation —
visual + functional, backend + frontend — and the happy-state tag drops
the moment that walkthrough passes. This anchors the refactor against the
operator-blessed surface and lets second-Claude lanes start immediately
at Phase 0 close (no idle time waiting for walkthrough).

---

## Phase 0 — Local stack smoke test

**Goal:** prove Wave 1's code (current master tip `ae4e7681`) actually
boots end-to-end against local Postgres before the operator-driven Phase 1
walkthrough. Cheap to run; catches gross breakage early.

**Tests against:** Wave 1 final state — post-Codex wave closeout
(PR #638) + 8 follow-up PRs landed 2026-05-13 (#639-#646).

**Stack:**
- Local Postgres: `forge-flow-pg16` Docker container on `localhost:5433` per
  `runbooks/local_full_stack_setup_runbook.md` (PG 16.10 + AGE 1.6.0 +
  pgvector + pg_partman + pg_cron + pg_stat_statements + pg_diskann stub,
  125 migrations applied).
- Proxy: `dart run tool/advisor_proxy/main.dart` against
  `POSTGRES_URL=postgresql://postgres:forge_flow_local@localhost:5433/forge_flow`.
- Flutter web: `flutter run -t lib/main_operator_web.dart -d chrome --dart-define=OPERATOR_WEB_PROXY_BASE_URI=http://localhost:8080`.
- Flutter mobile: `scripts\run_flutter_dev.ps1 -App forgeflow` against the connected Samsung device.

**Live testing tools (use these — they're available in main orchestrator session):**
- **Operator-web:** Claude Preview MCP server hosts the running operator-web
  build in an iframe Claude can click, screenshot, inspect, and read
  console/network logs from. Tools: `mcp__Claude_Preview__preview_start`,
  `_click`, `_screenshot`, `_eval`, `_console_logs`, `_network`, `_inspect`.
- **Mobile (Samsung device):** the connected Samsung is on. Main orchestrator
  exercises mobile UI directly via `adb shell input` + `adb exec-out
  screencap`, plus `flutter run` for hot-reload + log capture. Operator
  picks up the device when human intuition is needed.

**Exit criteria:**
- Proxy boots without crash.
- Operator-web shell renders (verified via Preview screenshot).
- Mobile shell renders (verified via adb screencap from Samsung device).
- One operator-web demo click-path completes without 500s (Preview server
  click + network log check).
- One mobile demo click-path completes (adb input + screencap verification).
- `dart analyze --fatal-infos` clean against current master.

**Operator gates:** none — orchestrator drives.

**Owner:** main orchestrator (this session).

**Hand-off on clean Phase 0:** the moment Phase 0 passes, second Claude
is cleared to start **all four assigned lanes (U, V, D, M-Poll)** in
parallel with main orchestrator's Wave 2 lanes. No idle time. Main
drops a "Phase 0 clean — Claude2 cleared for U/V/D/M-Poll" marker
commit on the ledger so second Claude can detect clearance on its first
action without a real-time channel.

---

## Phase 1 — Execute Wave 2 (33 slices across 11 lanes)

**Goal:** ship every actionable item from the debug.md brain dump that
Wave 1 didn't catch, plus close the 4 known bugs (W-1, W-2, BUG-1, BUG-2).

**Slice ledger:** `docs/_indices/WAVE_2_LEDGER.md` is canonical for
slice state, lane code, owner, gate, dependency. Every state change writes
there.

**Lane split (locked 2026-05-13):**

| Owner | Lanes | Count | Why |
|---|---|---|---|
| **Second Claude** | U, V, D, M-Poll | 4 lanes / ~8 slices | High-volume, low-architectural-risk, mostly mechanical work. Their lower caps stretch via worker-agent fan-out. |
| **Main orchestrator (me)** | W, H, R, S, B, Q, M-Other | 7 lanes / ~25 slices | Deep wave context, auth/RLS/schema/proxy-sensitive, complex coordination, longer-running quality work. |

Second-Claude lanes summary:
- **U** — UX polish bundle (14 Ops Console + 7 Mobile screens — subtitle/tile/copy/label hierarchy-sensitivity)
- **V** — Vendor Connection → Vendor Integration rename sweep
- **D** — Frameworks → runbooks conversion + agent-self-audit script
- **M-Poll** — Mobile Integrations tab (live status + demo-live switch + ops-portal deeplink)

Main orchestrator lanes summary:
- **W** — Write-path completeness (edit-user, cancel-invite, profile self-service, admin My Account)
- **H** — Hierarchy visualization + HP #11 sweep (schedule + wage_authority + top bar + inheritance tree)
- **R** — Roles hierarchy-scoped redesign + Default Role Catalog v2
- **S** — Wage Authority blended-mix UI + Roles screen UX simplification
- **B** — Bug fixes (W-1 legacy fact tables; W-2 partman dollar-quote; BUG-1 + BUG-2 triage)
- **Q** — Quality work (soak harness Azure swap + email harness + scaffold audit + custom role orphan lint)
- **M-Other** — Mobile covers manual entry + mobile Data tab role-gate

**Execution rules:**
- Worktrees prefixed by owner: `claude/<lane>-<slice>-<topic>` for main orchestrator agents; `claude2/<lane>-<slice>-<topic>` for second-Claude agents.
- Each slice gets a worker agent in a worktree following the same `commit + push + open PR → STOP` contract per CLAUDE.md "Workflow".
- Gate column on each slice (`auto` / `operator-gated`) determines merge path.
- Pattern B audit table (worker self-audit + executor independent audit, both with file:line citations) is non-negotiable in every PR.

**Wave 2 exit criteria:**
- All 33 slices `merged` in the ledger.
- All operator-gated slices have explicit operator approval logged.
- `dart analyze --fatal-infos` clean against post-Wave-2 master.
- All wave-touched test suites still green.

**Operator gates:** every slice marked `operator-gated` in the ledger.

---

## Phase 2 — Comprehensive walkthrough + TAG HAPPY STATE

**Goal:** the single comprehensive validation of the wave. **Main
orchestrator drives the walkthrough autonomously** against the audit
(`docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md`), fixes gaps surfaced,
then reports a plain-English verification list to the operator. Operator
verifies + signs off + tags happy state.

**Authority:** `docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md` is the
canonical authority for what "done" means. Every 🚧 IN PROGRESS / ❌ NOT
DONE / 🔍 NEEDS VERIFICATION row in that doc gets driven to ✅ DONE (or
back into the ledger as a Wave 2.5 slice if the gap survived Wave 2 and
needs operator decision before fix).

**Live testing tools:**
- **Operator-web:** Claude Preview MCP (click, screenshot, eval, console
  + network logs). Main exercises every Ops Console screen end-to-end.
- **Mobile:** connected Samsung device via `adb` + `flutter run` logs +
  screencaps. Main exercises every mobile screen end-to-end.
- **Backend:** `dart analyze --fatal-infos`, migration drift scanner,
  migration cutoff lint, advisor proxy size lint, wave-touched test
  suites — all run live against post-Wave-2 master.

**Workflow:**

### Step 2a — Main orchestrator walks the full surface

For each row in `DEBUG_MD_IMPLEMENTATION_STATUS.md` not currently ✅:
1. Identify the screen / API / capability under test.
2. Drive the live tool (Preview for operator-web; adb for mobile;
   shell for backend) through the click-path or invocation.
3. Capture evidence: screenshot, network log, console log, test output,
   or code-anchored prose.
4. Classify outcome:
   - **✅ Resolved live** — works correctly in current state. Flip row to DONE.
   - **🔧 Fixable inline** — small gap (≤5 file edit), main fixes via
     worker agent + standard PR. Re-test after merge. Flip row to DONE.
   - **🚧 Needs scope** — gap requires operator decision before fix.
     Add Wave 2.5 row to `WAVE_2_LEDGER.md` + leave row as 🚧 with the
     specific question captured.

Lane checks main runs in parallel with the row-by-row pass:
- **Lane U output quality:** subtitle/tile/copy/label hierarchy-sensitivity holds across all 14 Ops Console + 7 Mobile screens.
- **HP #11 sweep:** every settings surface shows scope / inherited-from / effective value triple, or documents why it's backend-only/gated.
- **Lane W:** vendor connector write-path → fact tables populated correctly.
- **Lane H:** hierarchy visualization renders + drills correctly.
- **Lane R + S:** hierarchy-scoped roles inherit + show up in the right places.
- **Lane B:** W-1 + W-2 fixes prove out under live apply; BUG-1 + BUG-2 reproductions confirmed closed.
- **Lane Q:** soak harness boots; email harness sends; scaffold-audit script runs clean; custom-role orphan lint catches a planted orphan.
- **Lane M-Poll:** mobile Integrations tab shows live status + demo-live switch works + ops-portal deeplink with JWT handoff lands authenticated.
- Operator read-back items get answered with code-anchored prose: locale, schedule timing, audit log explanation, sqlite refresh rate, realtime config, business setup field coverage.

### Step 2b — Backend cleanliness check

- `dart analyze --fatal-infos` clean against post-Wave-2 master.
- Migration drift scanner clean: `tool/migration_drift_scanner.dart --strict-docs`.
- Migration cutoff lint clean: `tool/migration_cutoff_lint.dart`.
- Advisor proxy size lint clean: `tool/advisor_proxy_size_lint.dart`.
- Wave-touched test suites all green; no new entries in `docs/KNOWN_FAILING_TESTS.md`.
- Audit log + hierarchy gateway end-to-end smoke (real Postgres, real RLS).

### Step 2c — Frontend cleanliness check

- Both flavors boot clean: `flutter run -t lib/main_forgeflow.dart` + `flutter run -t lib/main_barrio.dart` (Barrio remains paused but must still build).
- Operator-web builds + runs (Preview server confirms).
- No console errors or layout overflows surfaced via Preview console + network logs.
- Mobile Integrations tab renders correctly on Samsung device (screencap verified).

### Step 2d — Main produces plain-English verification list for operator

Single doc at `docs/_audits/wave_2/phase_2_walkthrough_verification.md`:
- Every audit row, its outcome (✅ resolved / 🔧 fixed in PR #X / 🚧 escalated to Wave 2.5).
- Plain-English summary of what main saw on each surface.
- List of fix PRs main shipped during the walkthrough.
- List of Wave 2.5 escalations (with proposed scope).
- Final state of all lane checks.
- Backend + frontend cleanliness check results.

### Step 2e — Operator verifies + signs off + tags happy state

Operator reads the verification doc, spot-checks any rows they want to
confirm directly (via the same live tools), signs off:

```bash
git tag happy-state-YYYY-MM-DD <commit-hash>
git push origin happy-state-YYYY-MM-DD
```

Plus snapshot any operator-edited demo SQLite state to a known path so
the same demo click-paths can replay identically after refactor.

**If operator rejects a row's verification:** main re-investigates that
specific row + amends the verification doc + re-presents.

**Operator gates:** operator approves the verification doc and decides
when to tag. Wave 2.5 escalations (if any) ship + walkthrough re-runs
on affected rows before tagging.

---

## Phase 2.5 — Per-Daypart Targets V1 (surfaced by Phase 2 mobile walkthrough)

**Goal:** ship per-service-period productivity targets end-to-end before
tagging happy state. The Phase 2 mobile walkthrough surfaced that the
recommendation engine already computes per-period targets cleanly but
pools them into whole-day scalars before persistence — every downstream
screen loses the daypart resolution, violating Promise 3 of
`core_app_architecture.md` ("Whole Day rolls up from service-period
buckets"). Tagging happy state on the current state would lock in a
dishonest architecture.

**Authority doc:** `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`
(self-contained, cold-readable; 14 architectural decisions locked; 44
gaps consolidated post-audit; reusable surface-coverage audit method
appended).

**Slice sequence:**

| Slice | Scope | Gate |
|---|---|---|
| 0 | Cycle rollover gates to operator's configured `week_start_day`. Amends `phase_7_55_time_boundary_contract.md` Rules 5+6, `phase_7_55_target_cycle_weekly_plan_rules.md` Rule E. No schema change. | operator-gated (contract amendment) |
| 1 | Per-period child tables under TargetCycle + WeeklyPlanSnapshot. Demo reseed populates per-period stamps on closed shifts. SQLite + Postgres migrations with RLS-ready scoping. | operator-gated (schema + RLS) |
| 1.5 | Closed-shift aggregator routes through canonical `DaypartBucketer` (replaces inline `_bucketsToDaypart` with boundary-inclusivity drift). Labor-punch interval split per Promise 3. Cross-(business-date) split. Retires `14 shifts/week` and `/3` divide hardcodes. Must land before Slice 6. | operator-gated (integration spine) |
| 2 | Benchmark tab redesign: Daypart Breakdown gains target columns (CPLH/SPLH/PPA + OPZ Range) + Whole Day rollup row; "Targets Derived from Benchmark" card cut + rehomed as Operating Wage Mix + Theoretical Labor %: The Floor strip; hardcoded `lunch/dinner/late_night` enum + 4 UI sites replaced with timing-config resolver. | auto-merge (audit clean) |
| 2.5 | Service period editor (operator-web) gains `applicableDays`, `shortLabel`, `sortOrder` fields. Allows day-restricted periods. | auto-merge |
| 3 | Plan tab persistence wiring. Sub-rows render locked values from new WeeklyPlanSnapshot child rows instead of regenerated allocator output. No UX change. | auto-merge |
| 4 | Shift daypart card full parity (Outputs + Inputs + FOH Productivity sections per period, mirroring whole-day card). | auto-merge |
| 5 | Variance read-seam swap. Non-closed daypart rows pull per-period theoretical % instead of whole-day flat. Wages stay whole-day. | auto-merge |
| 6 | Audit scorer extension. Per-period checks; pool-consistency check; wage-at-lock-time check. Audit denominator grows from 76 to ~155 at 4 periods. | auto-merge |

**Operator decisions queued before any slice dispatch:**

1. MeridianConfig insufficient-recommendation fallback shape (Gap 42)
2. `shift_close_authority` operator-editability vs documented carve-out (Gap 31)
3. Legacy `covers_source_*` vs keyed `data_accuracy_service_period_settings` precedence (Gap 36)
4. Operator-web Benchmarks override write-seam decision (Gap 35)

**Exit criteria:** all 9 slices merged; audit-pool-consistency check passes
end-to-end on demo data; Phase 2 mobile walkthrough re-runs cleanly with
per-period targets visible on Benchmark, Plan, Shift, Variance surfaces.

**Operator gates:** every slice marked operator-gated above. After exit,
proceed to Phase 2 walkthrough re-run, then to tagging happy state.

---

## Phase 3 — Refactor (R-1 + R-2)

**Goal:** structural extraction without behavior change. The refactor
scope is captured in `docs/POST_HARDENING_FOLLOWUPS.md` under "Refactor
phase scope".

### R-1 — Operator-web ceiling + `my_account_screen.dart` decomposition

- Codify operator-web ceiling in `tool/operator_web_size_lint.dart` mirroring `tool/advisor_proxy_size_lint.dart` shape.
- Decompose `my_account_screen.dart` into sibling panes (`my_account_security_pane.dart`, `my_account_mfa_pane.dart`, `my_account_sessions_pane.dart`, `my_account_profile_pane.dart`).
- Parent stays as a thin tab-host.

**Notable Phase 1 dependency:** OW-5a (move My Account under Access) and
OW-8d (consolidate Sign-in-Security into My Account) — both fold naturally
into R-1's decomposition. R-1 inherits whatever IA Wave 2 settled on.

### R-2 — Advisor proxy helper extraction + ceiling discipline

- Promote envelope helpers (`_readJsonBody`, `_writeJson`, `_resolveOperatorContextOrWrite`, etc.) to `tool/advisor_proxy/route_helpers.dart` sibling.
- Migrate B2.1 + B11.2 + C-4 hybrid dispatchers to Pattern A pre-check shape (`router.tryHandle(HttpRequest)` returning `Future<bool>`).
- Lower `kAdvisorProxyMaxLines` to match new (smaller) monolith size + ~200 lines of forward headroom.
- Codified rule (CLAUDE.md): **ceiling raises require operator approval** same gate as auth-critical / RLS-touching / schema-touching / proxy-touching slices.

**Operator gates:** each sub-slice opens its own operator-gated PR per
CLAUDE.md "Agent-led slices" (R-2 touches the proxy, R-1 touches
operator-web — both are governance-sensitive).

---

## Phase 4 — Re-test against happy state

**Goal:** catch any regression introduced by R-1 + R-2 before mutating
staging/Production1.

**Actions:**
- Re-run the same Phase 2 demo click-paths against the post-refactor build.
- Diff `dart analyze --fatal-infos` output against happy-state baseline — must still be 0 errors, no new wave-introduced regressions.
- Re-run wave-touched test suites — same green count as happy state.
- Spot-check the surfaces the refactor touched (panes of `my_account_screen`, the 3 hybrid dispatchers in `advisor_proxy`).

**Exit criteria:** zero behavior regressions vs happy state.

**Operator gates:** orchestrator runs the comparison; operator signs off
on "we are not worse than happy state."

---

## Phase 5 — Mutate staging + Production1

**Goal:** ship the post-Wave-2 + post-refactor code to real environments.

### 5a — Environment wires

- **SendGrid pubkey** — `SENDGRID_EVENT_WEBHOOK_PUBKEY_PEM` to Cloud Run env (production-only secret; wire on deploy day).
- **Live operator-web Firebase mixin** — ~10 LoC code change wiring `WebAuditLogHierarchyGatewayProvider` on the Firebase deploy source. (Pulled into Wave 2 Lane W if it ends up needing more than a 10-LoC patch.)
- Mailosaur preview-CI secrets already wired by Codex 2026-05-13 (✅ done pre-Phase-5).

### 5b — Production1 migration apply

- Follow `runbooks/phase_9_production1_migration_apply_runbook.md` end-to-end.
- W-1 + W-2 fixes (closed in Wave 2 Lane B) included in apply queue.
- 46 migrations pending (per `docs/POST_HARDENING_FOLLOWUPS.md` "P0 — Production1 Migration Apply Gap"; final count includes Wave 2 schema migrations).
- Cutoff file updated to whatever Wave 2 last-schema migration is.
- Operator-gated. Operator drives the apply.

### 5c — Deploy + verify

- Cloud Run deploy (proxy + operator-web + admin-console).
- Firebase hosting deploy (operator-web static + admin-console static).
- Mobile builds promoted (forgeflow + barrio APKs/AABs).
- Post-deploy smoke: SendGrid webhook receives + verifies, operator-web `/roles/explainer` renders complete catalog, admin Default Role Catalog publish idempotent, local-time on closed shift rows correct (Phase 7.55 time boundaries), every Wave 2 surface verified.

**Operator gates:** every sub-stage 5a / 5b / 5c.

---

## Phase 6 — Post-launch operational

Operator-owned work (engineering not required for these):

- **Operator SOP authoring** (tracked as Wave 2 slice QI-10 but executed post-launch).
- **Vendor outreach kickoff** (tracked as Wave 2 slice QI-11 but executed post-launch).
- **Soak harness completion + Azure Blob swap** (started in Wave 2 Lane Q; full operational run happens post-launch).
- **Email/notification pressure test full run** (harness built in Wave 2 Lane Q; pressure runs happen post-launch).
- **CI reactivation 2026-06-01** per `feedback_ci_dark_until_2026_06_01.md`.

---

## Cap discipline + parallelization rules (added 2026-05-13)

Both Claude accounts share the same risk: burn through caps in one
session and the wave stalls for hours/days. These rules apply to BOTH
the main orchestrator and second-Claude orchestrator across all phases.

### 1. Orchestrate-don't-implement

Every code change of meaningful size goes through a **worker agent
dispatched in a worktree** via the Agent tool. Worker agents run in
their OWN context window — their token usage does NOT hit the
orchestrator's session cap. The orchestrator spends tokens on:

- Writing the worker prompt.
- Auditing the resulting PR.
- Merging (or dispatching a follow-up agent for fixes).

That's it. No inline edits to slice work. Doc tweaks ≤10 lines are the
only carve-out.

### 1b. Parallel dispatch — fan out independent slices

**Default to maximum parallelism.** When two or more slices have no
file overlap and no contract dependency, dispatch their worker agents
in the **same Agent-tool message** (multiple `<invoke>` blocks in one
`<function_calls>` block). They run concurrently in separate worktrees;
their PRs land in any order; you audit + merge in any order.

Concrete examples:
- Lane B's 4 bug fixes (W-1, W-2, BUG-1, BUG-2) are independent files →
  dispatch all 4 at once.
- Lane Q's 4 quality slices are independent → all 4 at once.
- Lane W's 6 write-path slices: most are independent across vendor
  surfaces; check the slice rows for file overlap and group accordingly
  (e.g., 3 + 3, or 4 + 2 if two touch the same admin screen).
- Lane H's 3 hierarchy slices: HP #11 sweep + visualization + audit are
  independent → all 3 at once.

**Serialize only on:**
- File-level overlap (same file edited by 2+ slices).
- Contract dependency (slice B needs slice A's API or schema first;
  capture in the ledger's Dependency column).
- Operator-gated lane awaiting your approval (no point fanning out
  before the gate clears).

Orchestrator burns the same prompt-writing time per slice regardless of
parallelism; audit cost dominates and audits batch well. **Throughput
is the optimization target, not conservatism.**

### 2. 90% weekly cap throttle

When either session crosses ~90% **weekly** session usage, **stop
dispatching new workers**. Audit + merge what's already in flight. Then
compact and wait for the weekly reset before picking up new lanes.

The failure mode we're avoiding: orchestrator dispatches 4 workers,
audits 1, hits the cap mid-audit-2, leaves 2 PRs unaudited and the
operator stranded for days.

The 90% threshold (raised from an earlier 70% draft) reflects the
operator's preference: spend the cap on real shipping, not on
conservative buffer. Weekly is the relevant horizon — the per-session
throttle was over-conservative because workers run in separate context
windows and main spends most of its tokens on audits, which compress
well after compaction.

### 3. Compact between batches

Not just at phase boundaries — after every merged PR or every
audit-and-merge cycle, **compact**. Long contexts cost more per turn
(cache misses, more replay). Short context after compact is cheap.

### 4. Lane U bundling (second Claude specific)

The ledger explicitly permits second Claude to bundle Lane U (UX polish)
slices into 1-2 fat PRs instead of 7 thin ones. **Default to fat
bundles** under cap pressure:

- 7 thin PRs = 7 audits = 7× orchestrator cap spend.
- 2 fat PRs = 2 audits = 2× orchestrator cap spend.
- Workers don't care — fresh context per dispatch either way.

### 5. Audit by grep, not by re-reading

When auditing a PR diff, use `gh pr diff <n>` + targeted grep against
cited file:line ranges. Do NOT re-read whole files unless the audit
turns up a seam that needs broader inspection.

### 6. rg-first, offset reads, no double-reads

- `rg` (Grep tool) first when symbol/filename/literal is known.
- Offset reads on large docs — `offset` + `limit` parameters, not full reads.
- Don't re-read what you just read. Trust the prior read.

### 7. Tail tests

`flutter test test/<specific-dir>` not the whole suite. `dart analyze
lib/<specific-subtree>` not the whole tree, when scope is local.

### 8. Cross-session audit fallback

If main session caps out mid-audit on a Main-owned PR, second Claude
MAY pick it up as a one-off. Audits write to `docs/_audits/wave_2/`
which both sessions can write to (only `WAVE_2_LEDGER.md` itself is
main-only-writes). The audit doc carries the verdict; main session
merges when it's back. **Use sparingly** — safety valve, not habit.

---

## Cross-references

- Wave 1 closeout: `docs/_audits/post_codex_wave/c_12_lane_c_closeout_audit.md`
- Wave 1 ledger (closed): `docs/_indices/WAVE_EXECUTION_LEDGER.md`
- Wave 2 ledger: `docs/_indices/WAVE_2_LEDGER.md`
- Wave 2 parallel-lane handoff prompt: `docs/_indices/WAVE_2_PARALLEL_LANE_HANDOFF.md`
- debug.md implementation status: `docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md`
- Refactor scope (R-1 + R-2): `docs/POST_HARDENING_FOLLOWUPS.md` "Refactor phase scope"
- Bug ledger (W-1, W-2): `docs/POST_HARDENING_FOLLOWUPS.md` "Wave bugs surfaced 2026-05-13 by local apply"
- Advisory-lock posture: `docs/POST_HARDENING_FOLLOWUPS.md` "Advisory-lock posture — reconciled 2026-05-13"
- Local stack setup: `runbooks/local_full_stack_setup_runbook.md`
- Production1 migration apply: `runbooks/phase_9_production1_migration_apply_runbook.md`
- Workflow doctrine (executor-agnostic): `CLAUDE.md` "Workflow"
- CI status: `feedback_ci_dark_until_2026_06_01.md` (CI reactivates 2026-06-01)

## Wave 2 status snapshot

Updated as Phase 2 progresses. Detail: `docs/_indices/WAVE_2_LEDGER.md`.

**2026-05-14 closeout sweep:** the bulk of Wave 2 is merged. Items 4
(Roles screen UX), 6 (Cancel pending invite), 7 (Default Role Catalog
v2), and 8 (Profile self-service + mobile deep-link) from the
"New slices to add" list at `DEBUG_MD_IMPLEMENTATION_STATUS.md` lines
482-512 are now DONE — see `WAVE_2_LEDGER.md` "2026-05-14: Wave 2 closeout
sweep" for the per-slice PR map. Remaining open work is enumerated below.

| Lane | Owner | Slices | Merged | Open / Parked |
|---|---|---|---|---|
| U  | Second Claude  | 7 polish + 4 FU + 2 V1.1 FU (added 2026-05-14) | 11 | 2 (V1.1 schema FUs parked) |
| V  | Second Claude  | 1 | 1 | 0 |
| D  | Second Claude  | 2 | 2 | 0 |
| M-Poll | Second Claude | 1 | 1 | 0 |
| W  | Main orchestrator | 10 (6 main + 4 FU) | 8 | 2 (W-3 + W-5-mobile-FU still assigned) |
| H  | Main orchestrator | 3 | 2 | 1 (H-2 in-progress) |
| R  | Main orchestrator | 3 (2 main + 1 FU) | 2 | 1 (R-1L row stale-label; PR #699 merged on master, row not flipped — see operator-decision) |
| S  | Main orchestrator | 3 | 3 | 0 |
| B  | Main orchestrator | 6 (4 main + 2 FU) | 5 | 1 (R-1L-FU-pre-fail parked) |
| Q  | Main orchestrator | 7 (4 main + 2 Q-2 sub + 1 FU) | 5 | 2 (Q-1-FU parked; Q-2 parent assigned) |
| M-Other | Main orchestrator | 4 (3 main + 1 FU) | 3 | 1 (MO-2-FU parked) |
| **Total** | | **53** | **43** | **10** |

(Counts include follow-up rows added during Wave 2 execution + the
2 new V1.1 follow-up rows from the 2026-05-14 closeout sweep. Detail
per slice: `WAVE_2_LEDGER.md`.)
