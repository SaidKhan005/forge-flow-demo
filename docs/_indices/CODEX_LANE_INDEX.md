# Codex Lane Index

Single canonical entry point for every lane assigned to Codex (Codex lane agents).

Assignment locked: 2026-05-12 (parked-plan Step 6, unparked after Codex audits + visual sign-off).
Wave bundle: PR #497 (Step 3 lane plans + Step 4 code-health deep audits).

## Read this before dispatching any Codex lane work

1. Confirm the lane is in the table below (otherwise it's Claude's — open `CLAUDE_LANE_INDEX.md`).
2. Follow the lane's **Plan** pointer to its 5-doc execution packet.
3. Follow the lane's **Audit** pointer (if present) for the deep code-health audit.
4. Follow the lane's **Authority** pointer for any decision-doc anchor.
5. Check **State** before queuing — don't double-assign.

## Lane assignments (Codex)

### A — Code Health

| Lane | Scope | Plan | Audit | Authority | State |
|---|---|---|---|---|---|
| A2 | Scaffold removal (wire-or-delete decisions across 20 entries: 3 P0 / 7 P1 / 10 P2) | `docs/_execution/lane_a_code_health/03_execution_slices.md` (slice A2) | `docs/_audits/code_health/a2_scaffold_inventory.md` | Addendum C4 + `feedback_production_not_backlog` | assigned |
| A5 | Schema versioning + expand-contract migration adoption (`post_deploy/` directory + `audit_logs` UPDATE lint) | `docs/_execution/lane_a_code_health/03_execution_slices.md` (slice A5) | `docs/_audits/code_health/a5_schema_versioning_and_a7_frameworks.md` (§2-3) | Addendum A7 + CLAUDE.md "RLS-Ready Schema" | assigned |
| A6 | Proxy health UI (operator-visible health/readiness state) | `docs/_execution/lane_a_code_health/03_execution_slices.md` (slice A6) | `docs/_execution/lane_a_code_health/02_plumbing_audit_matrix.md` (Lens 8) | CLAUDE.md "Proxy & API Conventions" | assigned |
| A8 | Automation (CI gates, lint rules — including A5's audit_logs UPDATE allowlist + expand-contract drift flag) | `docs/_execution/lane_a_code_health/03_execution_slices.md` (slice A8) | `docs/_execution/lane_a_code_health/02_plumbing_audit_matrix.md` (Lens 12) | CLAUDE.md "Architecture Guardrails" | assigned |
| A9 | SQLite cleanup (legacy `lib/data/` deletion candidates; demo SQLite parity per HP #2) | `docs/_execution/lane_a_code_health/03_execution_slices.md` (slice A9) | `docs/_execution/lane_a_code_health/02_plumbing_audit_matrix.md` (Lens 3-4) | HP #2 + `docs/contracts/demo_mode_contract.md` | assigned |

### B — Features

| Lane | Scope | Plan | Authority | State |
|---|---|---|---|---|
| B3 | Role-key hybrid identifier (immutable `role_<uuid>` + presentation slug; UUID backfill migration) | `docs/_execution/lane_b_features/03_execution_slices.md` (B3) | Decision #3 | assigned |
| B4 | Product categorization (two-product role editor: Forge & Flow + Barrio sibling tabs; Barrio dormant) | `docs/_execution/lane_b_features/03_execution_slices.md` (B4) | Decision #4 | assigned |
| B5 | Admin console access control (F&F support vs forge_admin vs operator-admin role gates; permission key catalog completeness) | `docs/_execution/lane_b_features/03_execution_slices.md` (B5) | `lib/auth/` frozen catalog + `docs/contracts/auth_permission_key_catalog.md` | assigned |
| B6 | Benchmark override (operator-level CPLH/SPLH/PPA overrides with hierarchy inheritance) | `docs/_execution/lane_b_features/03_execution_slices.md` (B6) | HP #11 + `LaborModel`/`TargetCycle` ownership | assigned |
| B7 | Invite flow audit (SendGrid delivery + resend + expiry; **active bug**: `InviteMemberAdminDraft.primaryLocationId` silently corrupts business/org-unit invites at `invite_member_admin_dialog.dart:217`) | `docs/_execution/lane_b_features/03_execution_slices.md` (B7.a) | Addendum B4 | assigned |
| B9 | My Account surface (per decision #7, `/sign-in-security` 301 to My Account; password change, MFA, sessions, recovery codes) | `docs/_execution/lane_b_features/03_execution_slices.md` (B9.1, B9.2, B9.3) | Decision #7 | assigned |
| B10 | Vendor-applicability table (greenfield: one `vendor_applicability` table + `setting_kind` discriminator + JSONB + temporal columns) | `docs/_execution/lane_b_features/03_execution_slices.md` (B10.1, B10.2) | Addendum A6 | assigned — **schema-touching, operator approval required before merge** |

### C — Cross-Surface Parity

| Lane | Scope | Plan | Authority | State |
|---|---|---|---|---|
| C-Admin | Admin console parity (tile copy fixes; "Work in progress" → "Read-only view"; Admin-only banner on F&F-only tiles) | `docs/_execution/lane_c_parity/03_execution_slices.md` (C-10) | HP #10 + HP #11 | assigned |
| C-OpsWeb | Operator web parity (`app.forgeflow.app` entry; sign-in-security → My Account 301; adaptive 2FA button; Inheritance Tree consumer) | `docs/_execution/lane_c_parity/03_execution_slices.md` (C-OpsWeb cluster) | Decision #7 + V1 launch decisions 2026-05-03 | assigned |
| C-Mobile | Mobile parity (mobile→ops-web deep-link via redemption code; one master demo→live switch fanning out to `demo_mode_state`) | `docs/_execution/lane_c_parity/03_execution_slices.md` (C-Mobile cluster) | Decision #5 + #6 + Addendum A1 | assigned — **demo master switch needs 4th HP #2 reader-side carve-out, operator approval required** |

## Cross-references (lanes Codex does NOT own but consumes outputs from)

| Lane | Owner | What Codex consumes | When |
|---|---|---|---|
| A1 (proxy bugs) | Claude (shipped) | The shipped `runZonedGuarded` wrap + sign-in contract alignment in PR #476 | Already on master; Codex extends, doesn't redo |
| A3 (monolith decomp) | Claude | The proposed `routes/<context>.dart` extraction sequence | When A5/A8/A9 slices touch proxy code that's mid-extraction |
| A4 (perf) | Claude | Perf budgets + Postgres pool sizing | When A5/A8 add new gauges or migrations |
| A7 (frameworks) | Claude | The new SCHEMA_CHANGE_FRAMEWORK | When A5 ships the `post_deploy/` convention |
| A10 (tests) | Claude | Test consolidation pattern | When any Codex slice adds tests |
| A11 (soak harness) | Claude | The durable kit extension contract | When any Codex slice adds new pressure scenarios |
| B1 (hierarchy refinement) | Claude | Inheritance Tree component | When B6/B7/B9 need scope inheritance UI |
| B2 (Default Roles catalog) | Claude | The `default_role_catalog_versions` table | When B3 (role-key) backfills UUIDs into seeded roles |
| B8 (audit hierarchy filter) | Claude | The `ltree` descendant-set cache | When B5/B9 need audit-log queries scoped by hierarchy |
| B11 (redemption-code handoff) | Claude | The redemption-code endpoint | When C-Mobile lights up deep-link buttons |
| C-EmailsNotifs | Claude | SendGrid webhook receiver + scenario inventory | When B7 (invite flow) or other B slices add email touchpoints |

## Operator-approval gates (per CLAUDE.md)

Merge requires explicit operator approval, regardless of audit verdict:

- **Auth-critical**: B7 (invite flow fix touches auth), B9 (My Account password/MFA/session surface)
- **RLS-touching**: any A5 slice that adds new RLS policies
- **Schema-touching**: A5 (`post_deploy/` introduction), A9 (legacy table deletes), B3 (UUID backfill), B6 (override schema), B10 (vendor_applicability table)
- **Proxy-touching**: A5 (audit_logs UPDATE lint), A6 (health UI route), A8 (lint runtime hooks), B5 (admin access proxy guards), B7 (invite proxy routes), B9 (My Account proxy routes), B10 (vendor_applicability admin/opsweb routes)
- **Demo-mode reader carve-out**: C-Mobile master switch (4th HP #2 carve-out — needs operator approval + contract update)

Non-gated slices follow the auto-merge-after-audit doctrine: orchestrator merges PRs with `approve-for-merge` verdict and no escalations.

## Workflow

Per CLAUDE.md "Agent-Led Slices": every Codex agent commits + pushes + opens PR → STOPS. Orchestrator (Claude main chat) audits per `docs/_audits/audit_chunking_playbook.md` and merges per the operator-approval gates above.

Audit doc location: `docs/_audits/post_codex_wave/pr_<n>_<topic>_audit.md`.

**Base-drift guard (per 2026-05-12 stacked-PR incident)**: every Codex PR must have `baseRefName=master`. If a stacked PR's parent is already merged, edit the base via `gh pr edit <n> --base master` before audit. If the parent is still open, merge the parent first. See `memory/feedback_stacked_pr_base_drift_check.md`.

## Change log

| Date | Change |
|---|---|
| 2026-05-12 | Initial assignment (parked-plan Step 6 unpark). |
