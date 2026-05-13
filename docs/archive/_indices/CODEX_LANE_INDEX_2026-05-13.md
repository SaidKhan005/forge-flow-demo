# Codex Lane Index

Lane-level scope + cross-lane consumption matrix for every lane assigned to Codex. **Per-slice state lives in `WAVE_EXECUTION_LEDGER.md`, not here.**

Original assignment locked: 2026-05-12 (parked-plan Step 6, unparked after Codex audits + visual sign-off). Wave bundle origin: PR #497. Slice count, state, and dependencies have evolved per the wave's progression — consult the ledger for the current picture.

## Read order before dispatching any Codex lane work

1. **Open the wave execution ledger**: `docs/_indices/WAVE_EXECUTION_LEDGER.md`. Filter `Owner = Codex`. Pick the first slice with `state = assigned` and all dependencies merged.
2. Open this lane index for the lane's higher-level scope, authority anchor, cross-lane consumption hooks.
3. Open the lane's `03_execution_slices.md` for slice-level depth.

## Lane scope (Codex-owned)

### A — Code Health

| Lane | Scope | Plan anchor | Audit anchor | Decision authority |
|---|---|---|---|---|
| A2 | Scaffold removal (wire-or-delete decisions) + email pipeline wire-or-delete | `docs/_execution/lane_a_code_health/03_execution_slices.md` slices A2.1/A2.2 | `docs/_audits/code_health/a2_scaffold_inventory.md` | Addendum C4 + `feedback_production_not_backlog` |
| A5+A8 | Schema versioning + expand-contract migration adoption (`post_deploy/` directory + `audit_logs` UPDATE lint + CI gates) | `docs/_execution/lane_a_code_health/03_execution_slices.md` slice A5+A8 | `docs/_audits/code_health/a5_schema_versioning_and_a7_frameworks.md` (§2-3) | Addendum A7 + CLAUDE.md "RLS-Ready Schema" |
| A6 | Proxy health UI (operator-visible health/readiness state) | `docs/_execution/lane_a_code_health/03_execution_slices.md` slice A6.1 | `docs/_execution/lane_a_code_health/02_plumbing_audit_matrix.md` (Lens 8) | CLAUDE.md "Proxy & API Conventions" |
| A9 | `lib/data/` rehome (frozen-legacy files moved to `lib/dev/` + `lib/domain/constants/`; delete-only doctrine) | `docs/_execution/lane_a_code_health/03_execution_slices.md` slice A9.1 | `docs/_execution/lane_a_code_health/02_plumbing_audit_matrix.md` (Lens 3-4) | HP #2 + `docs/contracts/demo_mode_contract.md` |

### B — Features

| Lane | Scope | Plan anchor | Decision authority |
|---|---|---|---|
| B3+B4 | Role-key hybrid identifier (immutable `role_<uuid>` + presentation slug) + two-product taxonomy (Forge & Flow + Barrio sibling tabs) | `docs/_execution/lane_b_features/03_execution_slices.md` slices B3/B4 | Decisions #3 + #4 |
| B5+B5.b | Admin console access control (super_admin / ff_support / operator-admin role gates) + catalog tri-mirror amendment for account + timing keys (B5.b — new from operator decision 2026-05-13) | `docs/_execution/lane_b_features/03_execution_slices.md` B5 + `lane_b_features/05.5_catalog_followup.md` | `lib/auth/` frozen catalog + `docs/contracts/auth_permission_key_catalog.md` |
| B6 | Benchmark override (operator-level CPLH/SPLH/PPA overrides with hierarchy inheritance) | `docs/_execution/lane_b_features/03_execution_slices.md` B6 | HP #11 + `LaborModel`/`TargetCycle` ownership |
| B7 | Invite flow scope fix (`InviteMemberAdminDraft` hierarchy-scope) | `docs/_execution/lane_b_features/03_execution_slices.md` B7.a | Addendum B4 |
| B9 | My Account surface — `/sign-in-security` 301 (B9.1) + My Account consolidation + Active Sessions (B9.2) + adaptive 2FA button (B9.3) | `docs/_execution/lane_b_features/03_execution_slices.md` B9.1/B9.2/B9.3 | Decision #7 |
| B10 | Vendor-applicability table — `vendor_applicability` table + repository + routes (B10.1) + admin editor + wage authority binding (B10.2) | `docs/_execution/lane_b_features/03_execution_slices.md` B10.1/B10.2 | Addendum A6 |

### C — Cross-Surface Parity

| Lane | Scope | Plan anchor | Decision authority |
|---|---|---|---|
| C-Admin | Admin console parity (tile copy fixes; "Admin only" badge; "Read-only view" framing; Operator Web ownership notes) | `docs/_execution/lane_c_parity/03_execution_slices.md` C-10 | HP #10 + HP #11 |
| C-OpsWeb | Operator web parity — `/sign-in-security` → My Account 301 (C-3); adaptive 2FA button (C-7); Inheritance Tree consumer (C-6) | `docs/_execution/lane_c_parity/03_execution_slices.md` C-3/C-6/C-7 | Decision #7 + V1 launch decisions 2026-05-03 |
| C-Mobile | Mobile parity — mobile→ops-web deep-link via redemption code (C-5); master demo→live switch fanning out to `demo_mode_state` (C-4); in-app inbox renders catalog events (C-9) | `docs/_execution/lane_c_parity/03_execution_slices.md` C-4/C-5/C-9 | Decision #5 + #6 + Addendum A1 |

## Cross-references (Claude-owned lanes Codex consumes from)

| Claude lane | What Codex consumes | When |
|---|---|---|
| A0 (verification probe) | The shipped `runZonedGuarded` wrap + sign-in contract alignment (PR #476) | Already on master; Codex extends, doesn't redo |
| A3.1-A3.4 (monolith decomp + typed catches) | The seam map + cluster-aligned chunk boundaries | When Codex slices touch proxy code that's mid-extraction |
| A4.1-A4.2 (perf) | Postgres pool 4→20 default + `_ShiftDashboardTicker` pattern | When Codex slices add gauges or migrations |
| A7.1 (frameworks) | Canonical `docs/frameworks/<NAME>.md` path | When Codex docs reference frameworks |
| A10.1 (tests) | `test/pressure/` home unification | When Codex slices add pressure tests |
| A11.1+A11.2+A11.1.b (observability) | `SessionRecordIncompleteGauge` + soak harness durable kit | When Codex slices add observability hooks |
| B1.a/B1.b/B1.c (hierarchy + admin gateway honesty) | Inheritance Tree + `actor_kind = 'forge_admin'` idiom | When B5/B9 need scope inheritance UI or admin gateway audit log |
| B2.1/B2.2 (Default Roles catalog) | The `default_role_catalog_versions` table | When B3 backfills UUIDs into seeded roles |
| B8 (audit hierarchy filter) | The `ltree` descendant-set cache | When B5/B9 need audit-log queries scoped by hierarchy |
| B11.1/B11.2/B11.2.b (redemption code + step-up) | The `handoff_codes` table + RFC 9470 step-up challenge router | When C-Mobile (C-5) lights up deep-link redemption |
| C-1/C-2/C-8/C-11 (email pipeline + notifications catalog) | SendGrid webhook receiver + notification catalog completeness | When B7 or B9 add email touchpoints |

## Operator-approval gates (per CLAUDE.md)

Per-slice Gate column in `WAVE_EXECUTION_LEDGER.md` is canonical. The triggers (consult the ledger Gate column for the live picture):

- **Auth-critical**: B7.a (invite flow), B9.2 (My Account active sessions)
- **RLS-touching**: any A5+A8 slice that adds new RLS policies
- **Schema-touching**: A5+A8 (`post_deploy/`), B5.b (catalog tri-mirror migration), B6 (override schema), B10.1 (vendor_applicability table)
- **Proxy-touching**: A5+A8 (audit_logs UPDATE lint), A6.1 (health UI route), B5 (admin access proxy guards), B7.a (invite proxy routes), B9.x (My Account proxy routes), B10.x (vendor_applicability routes)
- **Frozen `lib/auth/**` touch**: B5.b (catalog amendment)
- **Demo-mode reader carve-out**: C-4 (master switch — needs 4th HP #2 carve-out + contract update)

Non-gated slices follow the auto-merge-after-audit doctrine: orchestrator merges PRs with `approve-for-merge` verdict and no escalations.

## Workflow

Per CLAUDE.md "Agent-Led Slices": Codex is an executor that spawns worker sub-agents in worktrees, reviews each worker's diff, writes its own audit table, then commits + pushes + opens PR → STOPS. The orchestrator (Claude main chat) audits the PR per `docs/_audits/audit_chunking_playbook.md`, writes the per-PR audit doc, and merges per the operator-approval gates.

Audit doc location: `docs/_audits/post_codex_wave/pr_<n>_<topic>_audit.md`. See the audit doc index at `docs/_audits/post_codex_wave/README.md`.

Master prompt for fresh Codex sessions: `CODEX_HANDOFF_PROMPT.md`.

**Base-drift guard (per 2026-05-12 stacked-PR incident)**: every Codex PR must have `baseRefName=master`. If a stacked PR's parent is already merged, edit the base via `gh pr edit <n> --base master` before audit. If the parent is still open, merge the parent first. See `memory/feedback_stacked_pr_base_drift_check.md`.

## Change log

| Date | Change |
|---|---|
| 2026-05-12 | Initial assignment (parked-plan Step 6 unpark, 43 slices). |
| 2026-05-13 | Wave evolved to 49 slices via 6 deep-audit/operator-decision row additions (B5.b + B11.2.b + B1.c + A11.1.b + A3.3 + A3.4 — only B5.b is Codex-owned). Lane assignments table trimmed to lane-level scope; per-slice state defers to the ledger. Cross-references expanded for newly-merged Claude lanes (A3.x, A4.x, A11.x, B1.x, B11.x). |
