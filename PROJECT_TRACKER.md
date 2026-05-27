# Forge & Flow Project Tracker

Updated: 2026-05-27. Routing map only: shows **only what is left**.
Completed phases/slices: `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`.
Stale sprint-execution docs: `docs/archive/_execution/`. `docs/archive/**`
is history; ignore unless explicitly named.

**Active work:** Per-Daypart Targets V1 (forward plan
`docs/_indices/NEXT_WAVE_PLAN.md`; plan
`docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`).
Workflow is executor-agnostic per CLAUDE.md "Workflow". CI is intentionally
dark until 2026-06-01 (workflow_dispatch only) — verify high-risk slices
with disclosed local `dart analyze`/`flutter test`.

Owner: You · Execution: We think, agents code (orchestrator-audited).

**Index:** Authority Order · Indices · Hard Product Rule
(Hierarchy-Scoped Settings) · Open Work (operator-blocked · cutover ·
engineering) · Vendor live rollout · Paused · Prompt Fetch Map ·
North Star · Active Lanes · Hard Gates · Notes ·
Recently landed · Recently archived.

Phases retired to `docs/archive/phases/` 2026-05-13: `phase_10b`,
`phase_11b`, `phase_12_workflow_platform`, `phase_8_5_external_integrations`
(paused per V1 lean cut — no V1 launch dependency).

## Authority Order (Active Read Order)

1. `PROJECT_TRACKER.md` (this file) — routing.
2. `docs/contracts/**` — durable rules.
3. `docs/POST_HARDENING_FOLLOWUPS.md` — open P0–P3 items.
4. The active phase doc named for the slice (Prompt Fetch Map below).
5. Decision registers when the slice needs arch/cost/security rationale:
   `docs/phases/phase_11a/phase_11a_decision_register.md`,
   `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`,
   `docs/phases/phase_9/phase_9_decision_lock_2026-04-26.md`.
6. `docs/CODEX_PROMPT_GENERATION_STANDARD.md` — prompt shape, parallel-lane rules.
7. `runbooks/deploy_runbook.md` ·
   `runbooks/performance_audit_runbook.md` ·
   `runbooks/ux_adjustment_runbook.md` ·
   `runbooks/mobile_web_console_e2e_runbook.md` — applied per slice when relevant.

Feature implementation work also uses
`runbooks/feature_implementation_lens_audit_runbook.md` whenever a
slice edits or adds product functionality, route/schema behavior, runtime
behavior, settings, permissions, or any feature with hidden plumbing risk.

`docs/archive/**` is history; ignore unless explicitly named. Authority is
normative in `CLAUDE.md`.

Prefer `.mcp.json` servers for orientation: `forgeflow_docs`,
`forgeflow_sqlite_schema`, `graphify`.

## Indices (current state)

| Index | Audience | Purpose |
| --- | --- | --- |
| `docs/_indices/NEXT_WAVE_PLAN.md` | All | Forward 6-phase pipeline. **Phase 2.5 — Per-Daypart Targets V1 is the active feature work** (output of Phase 2 mobile walkthrough). |
| `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` | All | **Active feature plan.** Self-contained; 14 decisions locked; 9 slices; 44 gaps consolidated; reusable audit method. |
| `docs/phases/plans_and_limits_v1/plans_and_limits_v1_plan.md` | Reference | Plans & Limits V1 closeout. Six plans, admin Plans and limits, pricing catalog, entitlements matrix, model routing, Operator Web "Your plan", and scoped custom contracts are shipped; real feature gates and billing remain future/deferred. |
| `docs/phases/plans_and_limits_v1/scoped_custom_contracts_plan.md` | Reference | Scoped Enterprise/custom-contract closeout: business/org-unit/location overrides, inheritance resolver, admin edit/clear/inherit flow, Operator Web display-only behavior, and non-goals. |
| `docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md` | All | Source-of-truth on every brain-dump ask from `debug.md` mapped to ✅/🚧/❌/🔍 with citations. |
| `docs/_indices/INFRA_DEFERRALS_INVENTORY.md` | All | Discovery index for ~20+ deliberate "we'll finish this later" infrastructure deferrals scattered across per-file code comments. Not authority; points back to governing phase/contract docs. |
| `docs/_indices/README.md` | All | Explains the index pattern + when to read which doc. |
| `docs/_indices/WAVE_2_LEDGER.md` | Frozen reference | **CLOSED 2026-05-15** (header marker). Operator-web + admin lanes closed 2026-05-14; mobile lane transitioned to Per-Daypart Targets V1 2026-05-15. Frozen for history; not an active routing target. |
| `docs/_indices/VARIANCE_COACHING_V2_LEDGER.md` | Frozen reference | **CLOSED** — Lanes A to G all merged (Lane G PR #915, 2026-05-17). Two Lane-G follow-ups remain open in that doc; the ledger itself is frozen reference, not an active routing target. |

**Archived indices** (closed-wave artifacts retired 2026-05-15):
`docs/archive/_indices/wave_1_closed_2026_05_13/WAVE_EXECUTION_LEDGER.md`
(Wave 1 ledger),
`docs/archive/_indices/wave_2_closeout_2026_05_15/` (Claude2-lane
handoffs + R-2L proposal + help queues — Wave 2 operator-web + admin
lanes closed),
`docs/archive/_indices/CLAUDE_LANE_INDEX_2026-05-13.md` +
`CODEX_LANE_INDEX_2026-05-13.md` (post-Codex wave lane indices).

## Hard Product Rule - Hierarchy-Scoped Settings

Every setting that can affect a business account resolves through the operator
hierarchy. A value may be set at the business/operator level and inherited by
all descendants. The same setting may also be set at any org-unit or location
level. The lowest configured scope wins; missing lower scopes inherit from the
nearest ancestor.

All admin, operator web, proxy, migration, and mobile surfaces that expose
settings must support that rule or explicitly document why a capability is
backend-only, gated, incomplete, or intentionally unsurfaced. The UI must show
the selected scope, the inherited source, and the effective value before any
mutation. Integrations are the known exception: they still prompt for hierarchy
context, but edits are location-level because vendor connections are bound to a
specific location.

## Open Work — V1 launch path

Three workstreams remain before V1 declaration. Two are operator-blocked,
one is engineering-blocked.

### 1. Operator-blocked (no engineering)

Detail + resume guide: `docs/archive/_execution/2026-05-06_v1_operator_punchlist_execution.md`.

| Item | Owner | Blocks |
|---|---|---|
| Firebase Auth action-domain switch (`auth.feflow.org` → `forge-flow-production1.web.app`, set `callbackUri`, run 4 validation checks) | You / Cloud | `cutover.0` preflight |
| Decide + apply the authoritative Production1 pending-migration queue in `docs/POST_HARDENING_FOLLOWUPS.md` P0. Two rows in that queue remain specifically operator-decision-sensitive (first-connect-backfill jobs + 11W.7 operator account fields); the full queue is 77 files through `202605270000_phase_11A_age_rebuild_runtime_dml_grants.sql` (per `POST_HARDENING_FOLLOWUPS.md` L34). | You + runbook | First-connect on prod, operator-web Account writes on prod, all staging-ready schema-backed features |
| Seed operator-authored T&C content into `tos_versions` (universal + per-vendor scopes) at deploy time. Operator self-authors per `docs/contracts/operator_self_served_tos_contract.md`; no external legal-review gate. | You / Eng | `cutover.2` |
| Sandbox creds for trio: Lightspeed K-Series · Libro · QuickBooks Time | You / Vendors | `*.live.sandbox` slices for trio |

### 2. Cutover sequence (gate-driven, not date-driven)

Plan: `docs/phases/phase_production_cutover/phase_production_cutover_plan.md`.

| Gate | Status | Notes |
|---|---|---|
| `cutover.0` preflight | not started | Read-only smoke on Production1; harness ready (V1.G). Needs Firebase Auth switch + authoritative Production1 migration queue applied and verified |
| `cutover.1` corpus load | not started | Voyage embeddings + Anthropic Contextual Retrieval; cost approval gate |
| `cutover.0b` Tier-M perf gate | not started | Launch-blocking; needs `cutover.1` corpus first |
| `cutover.2` first operator onboarding | not started | Vanessa on production1; needs operator-authored T&C content seeded in `tos_versions` |
| `cutover.3` traffic switch | not started | DNS / env-var flip |
| `cutover.4` 7-day stability watch | not started | Non-negotiable before V1 declaration |
| `cutover.5` post-launch hardening | not started | After V1 declaration |

### 3. Engineering still in scope

| Slice | Status | Plan |
|---|---|---|
| **Per-Daypart Targets V1** (Phase 2 mobile walkthrough output) | **code-complete (verified on `origin/master` 2026-05-27); all slices (0, 1, 1.5, 2, 2.5, 3, 4, 5, 6) + vendor-date 7a/7b + benchmark-rework follow-ups (SA to SF) landed; all 4 operator decisions (Gaps 42/31/36/35) resolved 2026-05-15; zero open PRs, no per-daypart code touched since ~2026-05-20. Only remaining exit gate = Phase 2 mobile walkthrough re-run (per-period targets visible on Benchmark/Plan/Shift/Variance) then tag happy state — shared step with NEXT_WAVE_PLAN Phase 2; no happy-state tag exists yet (verified 2026-05-27)** | **`docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`**: 9 slices (0 to 1 to 1.5 to 2 to 2.5 to 3 to 4 to 5 to 6); 44 gaps consolidated post-audit; removes recommendation engine's pooling kludge so per-period targets flow end-to-end; restores Promise 3 / Layer 9. Slice 0 amends `phase_7_55_time_boundary_contract.md` Rules 5+6 and `phase_7_55_target_cycle_weekly_plan_rules.md` Rule E for Option 2 cycle gating. Landed covers-source de-hardcode R5/R7a to R7d (#943/#972/#975 to #977; **#977 schema-destructive: drops legacy whole-day columns + trims view scalars**); run `migration_drift_scanner` + `migration_cutoff_lint` after any further `db/migrations` change. |
| **Refactor phase** (R-1 / R-2 / R-3 per `POST_HARDENING_FOLLOWUPS.md`) | Phase A guardrails landed (#1162, #1163, #1165); Phase B gated on happy-state tag, which is gated on Per-Daypart V1 exit + walkthrough re-run. | `docs/phases/refactor_phase/refactor_phase_plan.md` (created 2026-05-22; refreshed 2026-05-27 via #1424). Sequences `NEXT_WAVE_PLAN` Phase 3 (R-1 + R-2) + Phase 4 (re-test) with zero-behavior-change refactor doctrine. |
| `11A.8` API version management | not started | `phase_11A_operations_console/*` |
| `11A.9` Audit log review | not started | `phase_11A_operations_console/*` |
| `11A.10` Status page management | not started | `phase_11A_operations_console/*` |
| `9.8` inbound vendor T&Cs (code lane) | code-ready; operator-self-served content seeding pending | `phase_9_8/*` |
| `business-timing-live` full hierarchy + settings lanes | future | `phase_business_timing_live/*` |
| `admin-hierarchy-settings-overhaul` | complete (2026-05-12; evidence: `docs/archive/_execution/admin_hierarchy_settings_overhaul/06_closure_evidence_2026-05-12.md`) | `docs/archive/_execution/admin_hierarchy_settings_overhaul/` (plan archived to `docs/archive/_execution/admin_hierarchy_settings_overhaul_plan_2026-05-08.md`) |
| HP#11 cross-surface parity (admin DI wiring) | complete (closed 2026-05-16; real admin timing-surface effective-value resolution + My Account / business-timing-resolution production DI hops landed #906/#923/#925) | cross-surface-parity backlog wave closed |
| Doc 1 item 7 — physical connected-device E2E | simulated proof documented; physical/emulator proof pending | new sprint `8.connected-device-e2e-smoke`; needs physical device |
| Doc 1 item 9 — push delivery proof | preflight documented; needs staging apply + device | `8.push-notification-connected-device-proof` |
| Group / region / company rollup truth | future | follows server rollup snapshots |

## Vendor live rollout (rolling, parallel — does NOT block V1 launch)

All 17 INTEGRATE adapters are at lifecycle = `documented`. Each `*.live.sandbox`
and `*.live.prod` slice fires only when vendor credentials arrive. Tracker:
`phase_8_live_rollout/phase_8_live_rollout_plan.md`. Soft-blocked on V1.E
`vendor-now-available` email fan-out being already merged (it is).

| Wave | Vendors | Lane id |
|---|---|---|
| Wave 1 — needed for launch UX | Lightspeed K-Series · Libro · QuickBooks Time | `8.LSK.live.{sandbox,prod}` · `8R.LB.live.{sandbox,prod}` · `8.S.QBT.live.{sandbox,prod}` |
| Wave D — partnership-paced | Toast · Clover · Oracle Simphony · ADP · Aloha · NCR · Square · 7shifts · Revel · Tock · OpenTable · SevenRooms · Humanity · Agendrix · Push Operations | matching `8*.<vendor>.live.{sandbox,prod}` |

## Paused

| Phase | Reason |
|---|---|
| `12.0`–`12.5`, `11A.11`, `9.8` advisor portion, `10b` | AI freeze (persistent) |
| `11b` / `.1` / `.2`, `11A.3` + `11A.3.x` | AI freeze with active carve-outs — see Advisor Knowledge + Graph Activation block below (`11b/.1/.2` paused 2026-05-27 after build; `11A.3.x` resolved per the 2026-05-27 audit, deploy-time only). |
| `8.5`, `11W.9` | Outward-vendor freeze |
| `9.5.UX.*`, `9.75`, `lib/internal/barrio/**`, `lib/main_barrio.dart` | Barrio freeze |

**Advisor Knowledge + Graph Activation — PAUSED 2026-05-27** (was the
2026-05-25 active carve-out). The advisor "brain" (Workstream A), the
operator-facing chat UI (D web + mobile), the admin Knowledge +
Connections tabs (B + C2), and the knowledge-graph activation
(G1/G2/G4/G4b/G5a) plus the follow-ups F1/F2/F3 (#1429, #1430, #1428;
merged 2026-05-27) are all built and on `master`, inert until deploy.
The full phased resume sequence, remaining engineering (G5b
advisor-reads-graph + the other HP#7 re-points), open decisions, the
documented-gaps reference, and the go-live action list are in
`docs/phases/advisor_knowledge_activation/advisor_graph_activation_resume_plan.md`.
**Resume AFTER** the refactor lane (NEXT_WAVE_PLAN Phase 3: R-1/R-2/R-3)
and Per-Daypart Targets V1 (Phase 2.5). The rest of the AI-freeze set
(`12.0`–`12.5`, `11A.11`, `10b`, `9.8` advisor portion) stays paused.

**`11A.3.x` graphify-candidates — status (updated 2026-05-27):** governed
by the Advisor Knowledge Activation plan (Workstream C); C1 is
code-complete and the Connections-tab redesign (C2 + map) is DONE +
merged. The candidate-content decision is RESOLVED: BOTH brands (Forge &
Flow + Barrio data only; Barrio app code stays paused), regenerated +
staged by G1 (#1420). What remains is deploy-time only (confirm the
deployed image ships the candidate JSONL + `corpus_manifest.yaml`; the
un-pause call; runtime `commit-batch` verify), tracked as phase R2 in
`advisor_graph_activation_resume_plan.md`. The canonical-graph write path
stays op-gated.

**AI/advisor deferred gap pickup (2026-05-27 audit):** keep the remaining
AI/advisor fixes in their lane. Concrete references live in
`docs/_audits/deep_unrun_lane_audit_2026_05_27_report.md`: live/demo Advisor
gateway binding, client `prior_turns`, Advisor CMK deploy-secret mapping,
Advisor/Tier-M cutover wording alignment, graph candidate artifact/content
cleanup, and the AI/corpus/pricing/observability admin-pressure placeholders.

## Prompt Fetch Map

| Slice prefix | Read |
| --- | --- |
| `11A.*` | `phase_11A_operations_console/phase_11A_operations_console_plan.md` |
| `cutover.*` | `phase_production_cutover/phase_production_cutover_plan.md` |
| `9.8` | `phase_9_8/*` |
| `*.live.*` | `phase_8_live_rollout/phase_8_live_rollout_plan.md` |
| `8.5`, `9.5`/`9.75`, `11b*`, `11W.9`, `12.*` | matching `docs/phases/**` doc |
| Advisor knowledge / chat UI / graph candidates | `advisor_knowledge_activation/advisor_knowledge_activation_plan.md` |

## North Star

POS + Labor + Reservation → Canonical Operational Facts → 60-Day Benchmark
Snapshot → TargetCycle + DemandForecastContext → SchedulePlan →
WeeklyPlanSnapshot → Shift → Variance → History → Learn.

## Active Lanes

Codex on master; Claude in `.claude/worktrees/<lane>`. Multiple phases may
run in parallel. Rules: `docs/CODEX_PROMPT_GENERATION_STANDARD.md`
"Parallel Worktrees".

**Currently running**: nothing engineering-blocked. The remaining engineering
slices (11A.8/.9/.10, business-timing-live extensions, Doc 1 items 7/9)
are queued behind operator-blocked items above and have no active worktree.

**Wave D — rolling `*.live.*` slices** fire individually as credentials
arrive.

**Skip until unfreeze**: see Paused list above.

## Hard Gates

- `cutover.0b` Tier-M perf gate is launch-blocking; needs `cutover.1`
  corpus seed first.
- Production migrations use online-migration patterns once real operator
  data exists; transition at `cutover.4`.
- Migration changes: `dart run tool/migration_drift_scanner.dart --fix
  --strict-docs`, then `dart run tool/migration_cutoff_lint.dart`.
- Runtime-exposed slices should follow
  `docs/contracts/slice_runtime_acceptance_contract.md` (advisory pattern,
  not CI-enforced — reviewer judgment, not auto-blocking). Browser-exposed
  slices use Codex-driven Browser Use evidence per
  `runbooks/browser_use_codex_acceptance_workflow.md` (out-of-repo automation,
  not a binary in this tree) and full E2E uses
  `runbooks/mobile_web_console_e2e_runbook.md`.
- Before staging console perf claims:
  `dart run tool/perf_gate/staging_console_probe.dart --run
  --admin-url=<url> --proxy-url=<url>` and attach JSON.
  `--enforce-budgets` for PR/release gates; `--include-health` only for
  bounded health probes.
- 35 scalability locks
  (`phase_9_scalability_decisions_2026-04-27.md`) authoritative; 10 Hard
  Promises in `CLAUDE.md` durable.

## Notes

- CI is intentionally dark until 2026-06-01 (see header). Verify
  high-risk slices with disclosed local `dart analyze` / `flutter test`;
  use `tool/pre_merge_gate.sh` and `tool/verify_pr_landed.sh`.
- Plans & Limits V1 plus scoped Enterprise/custom contracts are shipped
  through final QA (2026-05-26). Remaining Plans/Limits work is not an
  active V1 launch slice: real feature gates wait until LMS / scoreboard /
  SOPs / workflows (or another gateable surface) exist; billing checkout,
  invoices, payment methods, and payment collection are future; production
  application of the code-ready Plans/Limits migrations stays in the normal
  operator-approved migration queue.
- Mobile architecture (canonical-fact dicts → operator-scoped Postgres
  `shift_records` → mobile SQLite via proxy sync) bound by
  `integration_spine_architecture_contract.md`.
- 2026-05-05 vendor-research falsehoods captured in
  `integration_spine_architecture_contract.md` "2026-05-05 falsehood
  corrections" section.
- `$HOME/.forge_flow/secrets/runtime/forge_flow.secrets.ps1` is the
  canonical private env loader (outside repo).
- Closed-phase audits/closeouts live in `docs/_execution/`; follow
  CLAUDE.md "Phase Doc Hygiene" and retire to `docs/archive/phases/`
  within a week.
- If a prompt requires a key, account, cloud project, billing setup, or
  infrastructure choice, surface it in Block 1.
- **Notify before** any live Firebase mutation, key/account request,
  billing setup, provider call, or product decision.

## Recently landed (through 2026-05-27)

Themed digest of what landed since the last tracker refresh (commit
`54dbd2f5`). None of this changes the V1 launch path above; it is
feature build-out, doc alignment, and repo hygiene.

**2026-05-16 to 2026-05-18:** retired to `docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md` 2026-05-27 (49 entries covering Per-Daypart Slices 0 to 5, doc-alignment audit Phases 1 to 4, Choose Star Shifts R1 to R10, Variance Coaching V2 Lanes A to G, mobile UX polish, advisor-proxy size discipline, repo hygiene, misc fixes).

### 2026-05-19 to 2026-05-22 (199 non-merge commits)

- **Operator Web UX consistency wave (foundation through header
  unification):** shared `OperatorWebScreenHeader` extracted and rolled
  across ~14 screens (#1102/#1183/#1185/#1186/#1187); UX foundation +
  execution plan (#1141); polish across My Account / Team Members
  (#1151), Audit log (#1150), Business timing (#1145), Notifications
  (#1146), Locations hierarchy (#1153/#1182), Business setup (#1097),
  Plan help (#1095); Roles made scope-aware (#1152); my_account dialog
  decomposition (#1180); hierarchy-scoped account settings (#1130).
- **Data Accuracy operator surface (Wave 6 + hardening):** labor-grouping
  polish (#1148), purpose / app-dashboard copy clarified (#1181), vendor
  truth / applicability / source defaults hardened, reads from the
  effective view, service-period reset paths (#1065), business date now
  required and Business-Timing-anchored, parity gaps closed, legacy
  wire-key aliases retired, InMemory admin gateway parity (#1086).
- **Business Timing authoring + onboarding:** org-unit Business Timing
  authoring, onboarding profile seed (#1052), timezone + starter
  bootstrap fixes, route-truth + retry labels, service-period metadata
  preserved.
- **Test-suite tightening audit (2026-05-20):** largest test files split
  into focused files (advisor_proxy 8,328 lines into 5 (#1120);
  canonical_fact 3,981 into 3 (#1110); baseline_manager 3,608 into 4
  (#1117); proxy_auth 3,599 into 4 (#1122); plus target_cycle /
  data_alignment_audit / phase_9_0sigma / admin_operator_location /
  mobile_operational_sync splits, #1121 to #1132); shared SQLite /
  Postgres / HTTP / pump test helpers (#1100/#1107/#1111/#1113/#1114/#1119);
  ~600 unbounded `pumpAndSettle()` calls converted to bounded pump loops
  (Bucket 3 PRs); postgres-tagged tests gated out of the default suite
  (#1089/#1098); doc refs repointed to the new split filenames
  (#1129/#1131/#1132).
- **Code-hardening guardrails (Phase A):** operator-web size lint +
  metrics ratchet (#1162), skip-quarantine lint + flake counter + test
  baseline (#1163), `dart_code_metrics` integration (#1142),
  `PERF_BASELINES.json` ratchet skeleton (#1140), ignore-justification
  lint (#1137); Phase A lints wired into the pre-push hook and ratcheted
  into the pre-merge gate (#1165).
- **Pressure + regression test waves:** in-memory pressure for audit
  chain / webhook signature / cold boot (#1144) and for auth lockout /
  RLS / idempotency / tenant isolation (#1143); mobile-pressure Lanes A
  to D (boot/auth/shell/nav, shift+variance, plan/benchmark/baseline,
  settings/demo); cross-surface mismatch + end-to-end vendor-spine audits
  (#1060/#1061); ~9 pre-existing operator-web/admin failures fixed
  (#1059); baseline-failure triage (#1090).
- **Projection retry + vendor-spine hardening:** durable projection retry
  ledger + drain worker + admin read-only visibility + evidence +
  pre-input failure recording (#1050), runOnce default, orphan-scope
  skip; direct-adapter and worker projection taps wired (#1027/#1028);
  SendGrid `email_outbox` flips on terminal bounce/complaint events
  (#1016/#1083); star-shift idempotency keys stabilized.
- **Deep parity / gap-audit cascade:** cross-surface and graph-audit gap
  closures (#1015 to #1024), role-gate alignment (#1018/#1019),
  data-accuracy provenance + idempotency gaps; follow-up findings flipped
  RESOLVED (#1067/#1070/#1077).
- **Docs consolidation (Waves 2 to 8) + architecture-book rebuild:**
  `docs/frameworks/` folded into `runbooks/` (#1000/#1002), personal
  `ARCHITECTURE.md` de-authoritied with refs redirected to the canonical
  contract (#1001), closed walkthroughs / execution packets / audits
  archived (#997 to #1008, #1082), `NEXT_WAVE_PLAN` snapshot refreshed
  (#1004); CLAUDE.md workflow-hardening + Doc Lean-Out codification
  (#1005/#1014); architecture-book rebuilt as prose + printable PDF with
  diagrams and factual-drift fixes (#1006/#1011); em/en dashes purged
  (#1017/#1169).
- **In-browser QA harness:** operator-web QA harness (#1172) +
  admin-console QA runbook coverage; headless-Electron polyfill fixes;
  stale operator-web tests quarantined pending surface-freeze (#1167).

### 2026-05-23 to 2026-05-27

- **Plans & Limits V1 shipped:** six real plans including Elite and
  Enterprise; admin Plans and limits rebuilt; live spend/caps and delete
  limit support; editable `pricing_plan_catalog`; Pilot trial flag and
  conversion path; feature-entitlements matrix; model routing by plan;
  Operator Web display-only "Your plan" surface.
- **Scoped Enterprise/custom contracts shipped:** business, org-unit, and
  location terms persist in `pricing_contract_overrides`; the effective
  resolver applies lower-scope overrides over higher-scope terms; admin
  Businesses tab supports edit/save/clear/inherit; Business Accounts stale
  launch wording was removed; Operator Web stays display-only with no billing
  checkout.
- **Plans & Limits final QA polish:** Businesses tab, edit custom contract
  popup, clear/inherit behavior, Enterprise/custom copy, Operator Web "Your
  plan", and Business Accounts copy were browser-checked and cleaned up
  through PR #1388.
- **Advisor D1 + D2 (chat surfaces):** Slice D1 Advisor Answer client
  (#1392); Advisor Chat operator-web D2 (#1414); mobile chat (#1418).
  Followed by the 2026-05-27 Advisor Knowledge + Graph Activation pause
  (see Paused section above).
- **Knowledge-graph activation lane:** G1 candidate bundle regenerated for
  both brands (#1420); C3 typed-vocabulary migration (#1421); C3
  semantic-extraction tooling (#1422); proxy semantic-extraction endpoint
  (#1423); AGE rebuild G5a (#1427); follow-ups F1/F2/F3 (#1428, #1429,
  #1430).
- **Admin pressure suite scaffold + runner:** scaffold (#1407) + runner
  (#1415; 124/124 PASSED).
- **Admin Knowledge base C2 redesign:** Connections-tab redesign + map
  through PRs #1389, #1390, #1400, #1416.
- **Data Accuracy tabbed redesign:** #1399, #1402, #1403.
- **Vendor applicability end-to-end:** #1387, #1395.
- **Refactor phase plan creation + refresh:** added 2026-05-22 at
  `docs/phases/refactor_phase/refactor_phase_plan.md`; refreshed 2026-05-27
  via #1424.
- **Operator Web shared body refactor:** PR #1198 routed every screen
  body through the shared `OperatorWebScreenBody`.
- **Mobile pressure Wave 2 (Lanes E to H, 20 scenarios):** harness +
  notifier fixes landed on master commit `e700cecb`.
- **Archive sweeps:** mobile pressure 2026-05-22 (#1408); operator-web UX
  consistency (#1409); 6 shipped 2026-05-20 execution plans (#1410);
  test-suite tightening audit (#1411); admin_support_logs_redesign
  (#1413); citation repoints (#1431); 5 stale doc refs (#1425);
  CLAUDE.md Session Handoff section removed (#1426); `.gitignore` A6
  (#1432).
- **Still not active:** real feature gates wait until gateable product
  surfaces exist; Stripe, invoices, payment methods, checkout, and operator
  self-serve plan changes remain future work.

## Recently archived

Full closed-phase / closed-wave history (2026-05-07 closeout pass,
2026-05-08 post-audit remediation wave PRs #417–#426, Phase 8/9/10a/11A/11W
accepts, CODE_HEALTH remediation, Production1 go-live) lives verbatim in
`docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`. Not duplicated here —
this file shows only what is left.
