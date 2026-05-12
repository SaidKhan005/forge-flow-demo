# Claude Lane Index

Single canonical entry point for every lane assigned to Claude (orchestrator + Claude lane agents).

Assignment locked: 2026-05-12 (parked-plan Step 6, unparked after Codex audits + visual sign-off).
Wave bundle: PR #497 (Step 3 lane plans + Step 4 code-health deep audits).

## Read this before dispatching any Claude lane work

1. **Open the wave execution ledger first**: `docs/_indices/WAVE_EXECUTION_LEDGER.md`. The ledger is the single source of truth for slice state across all 43 slices.
2. Find your owned slices in the ledger (filter by `Owner = Claude`).
3. Pick the first slice with `state = assigned` that has its dependency merged.
4. Then open this lane index for context: lane scope, audit anchor, decision authority.
5. Then open the lane's `03_execution_slices.md` for slice-level depth.

## Lane assignments (Claude)

### A — Code Health

| Lane | Scope | Plan | Audit | Authority | State |
|---|---|---|---|---|---|
| A1 | Proxy bug root-cause fixes (`runZonedGuarded` + sign-in scope + instrumentation) | `docs/_execution/lane_a_code_health/03_execution_slices.md` (slice A1) | `docs/_audits/code_health/a1_proxy_bug_root_cause.md` | Addendum B1 | **shipped** (PR #476) — verification probe pending |
| A3 | Proxy monolith decomposition (`tool/advisor_proxy/advisor_proxy.dart` 18,623 LoC → bounded `routes/<context>.dart` modules) | `docs/_execution/lane_a_code_health/03_execution_slices.md` (slice A3) | `docs/_audits/code_health/a3_proxy_monolith_decomposition.md` | CLAUDE.md "Proxy & API Conventions" | assigned |
| A4 | Performance audit + remediation (26 hotspots; Postgres pool 4→20 highest ROI) | `docs/_execution/lane_a_code_health/03_execution_slices.md` (slice A4) | `docs/_audits/code_health/a4_performance_audit.md` | `docs/frameworks/PERFORMANCE_FRAMEWORK.md` | assigned |
| A7 | Frameworks consolidation (`docs/frameworks/README.md` rewrite + rename `deployFramework.md` + new SCHEMA_CHANGE_FRAMEWORK) | `docs/_execution/lane_a_code_health/03_execution_slices.md` (slice A7) | `docs/_audits/code_health/a5_schema_versioning_and_a7_frameworks.md` (§4-5) | CLAUDE.md Authority Order #7 | assigned |
| A10 | Test consolidation (666 test files, KNOWN_FAILING_TESTS.md drift, pressure-test home unification) | `docs/_execution/lane_a_code_health/03_execution_slices.md` (slice A10) | `docs/_execution/lane_a_code_health/02_plumbing_audit_matrix.md` (Lens 12) | `docs/KNOWN_FAILING_TESTS.md` | assigned |

### B — Features

| Lane | Scope | Plan | Authority | State |
|---|---|---|---|---|
| B1 | Hierarchy refinement post-overhaul (additive polish on top of `admin_hierarchy_settings_overhaul` closure 2026-05-12; Inheritance Tree component) | `docs/_execution/lane_b_features/03_execution_slices.md` (B1.a, B1.b) | HP #11 + Addendum C2 | assigned |
| B2 | Default Roles catalog (admin-editable, pull-pattern; `default_role_catalog_versions` table + `operators.default_role_catalog_version_id` pointer) | `docs/_execution/lane_b_features/03_execution_slices.md` (B2.1, B2.2) | Decision #2 + Addendum A2 | assigned |
| B8 | Audit log hierarchy filter (read-side join + `ltree` cache; `org_unit_path` already in schema) | `docs/_execution/lane_b_features/03_execution_slices.md` (B8) | Decision #8 + Addendum A3 | assigned |
| B11 | JWT handoff replacement (redemption-code endpoint + RFC 9470 step-up; greenfield) | `docs/_execution/lane_b_features/03_execution_slices.md` (B11.1, B11.2) | Addendum A1 (supersedes Decision #5) | assigned — **auth-critical, operator approval required before merge** |

### C — Cross-Surface Parity

| Lane | Scope | Plan | Authority | State |
|---|---|---|---|---|
| C-EmailsNotifs | Email pipeline lane (SendGrid Event Webhook receiver, 3 silent failures already fixed via B3, dual invite path resolution, scenario inventory pressure-test) | `docs/_execution/lane_c_parity/03_execution_slices.md` (C-1, C-2, C-11) | Addendum C3 + B3 + B4 | assigned |

## Cross-references (lanes Claude does NOT own but consumes outputs from)

| Lane | Owner | What Claude consumes | When |
|---|---|---|---|
| A2 (scaffolds) | Codex | The `a2_scaffold_inventory.md` wire/delete decisions | Whenever a Claude slice touches a flagged surface |
| A5 (schema versioning) | Codex | The `post_deploy/` migration convention | Any Claude slice that ships a migration |
| A6 (proxy health UI) | Codex | Health/readiness gauge contract | When A4 perf slices need new gauges |
| B7 (invite flow) | Codex | Invite gateway shape | When B11 redemption-code overlaps with invite |
| B10 (vendor_applicability) | Codex | The new `vendor_applicability` table shape | When Claude touches wage/covers/polling settings |
| C-Admin / C-OpsWeb / C-Mobile | Codex | Parity decisions on cross-surface tile copy + deep-links | When Claude C-EmailsNotifs slices interact with admin/opsweb/mobile UI |

## Operator-approval gates (per CLAUDE.md)

Merge requires explicit operator approval, regardless of audit verdict:

- **Auth-critical**: B11 (redemption-code), any A1 verification slice that re-touches auth
- **RLS-touching**: any slice that adds/changes RLS policy
- **Schema-touching**: B2 (catalog versioning table), B8 (ltree descendant-set cache materialized view)
- **Proxy-touching**: A3 (monolith decomposition), B11 (new auth routes)

Non-gated slices follow the auto-merge-after-audit doctrine: orchestrator merges PRs with `approve-for-merge` verdict and no escalations.

## Workflow

Per CLAUDE.md "Agent-Led Slices": every agent commits + pushes + opens PR → STOPS. Orchestrator audits per `docs/_audits/audit_chunking_playbook.md` and merges per the operator-approval gates above.

Audit doc location: `docs/_audits/post_codex_wave/pr_<n>_<topic>_audit.md`.

## Change log

| Date | Change |
|---|---|
| 2026-05-12 | Initial assignment (parked-plan Step 6 unpark). |
