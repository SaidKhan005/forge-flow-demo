# Claude Lane Index

Lane-level scope + cross-lane consumption matrix for every lane assigned to Claude (orchestrator + Claude lane executor). **Per-slice state lives in `WAVE_EXECUTION_LEDGER.md`, not here.**

Original assignment locked: 2026-05-12 (parked-plan Step 6, unparked after Codex audits + visual sign-off). Wave bundle origin: PR #497 (Step 3 lane plans + Step 4 code-health deep audits). Slice count, state, and dependencies have evolved per the wave's progression — consult the ledger for the current picture.

## Read order before dispatching any Claude lane work

1. **Open the wave execution ledger**: `docs/_indices/WAVE_EXECUTION_LEDGER.md`. The ledger is the single source of truth for slice state, dependencies, gate column, and counts.
2. Filter by `Owner = Claude`. Pick the first slice with `state = assigned` and all dependencies merged.
3. Open this lane index for the lane's higher-level scope, authority anchor, cross-lane consumption hooks.
4. Open the lane's `03_execution_slices.md` for slice-level depth.

## Lane scope (Claude-owned)

### A — Code Health

| Lane | Scope | Plan anchor | Audit anchor | Decision authority |
|---|---|---|---|---|
| A1 | Proxy bug root-cause fixes (`runZonedGuarded` + sign-in scope + instrumentation) — shipped pre-wave at PR #476; A0 verification probe added to the ledger 2026-05-12 | `docs/_execution/lane_a_code_health/03_execution_slices.md` slice A1 | `docs/_audits/code_health/a1_proxy_bug_root_cause.md` | Addendum B1 |
| A3 | Proxy monolith decomposition — read-only seam map (A3.1) + bleed-stop ceiling (`tool/advisor_proxy_size_lint.dart`) + bare-catch typing pass split across cluster-aligned chunks (A3.2/A3.3/A3.4) | `docs/_execution/lane_a_code_health/03_execution_slices.md` slices A3.1-A3.4 | `docs/_audits/code_health/a3_proxy_monolith_decomposition.md` + `a3_advisor_proxy_seam_map.md` | CLAUDE.md "Proxy & API Conventions" |
| A4 | Performance audit (A4.1) + remediation (A4.2) — Postgres pool default 4→20, `_ShiftDashboardTicker` ValueNotifier coalescing, `healthProducerConcurrency` env-resolved | `docs/_execution/lane_a_code_health/03_execution_slices.md` slices A4.1-A4.2 | `docs/_audits/code_health/a4_performance_audit.md` | `docs/frameworks/PERFORMANCE_FRAMEWORK.md` |
| A7 | Frameworks consolidation (cross-reference sweep + canonical path) | `docs/_execution/lane_a_code_health/03_execution_slices.md` slice A7.1 | `docs/_audits/code_health/a5_schema_versioning_and_a7_frameworks.md` (§4-5) | CLAUDE.md Authority Order |
| A10 | Test consolidation (pressure-test home + KNOWN_FAILING_TESTS drift) | `docs/_execution/lane_a_code_health/03_execution_slices.md` slice A10.1 | `docs/_execution/lane_a_code_health/02_plumbing_audit_matrix.md` (Lens 12) | `docs/KNOWN_FAILING_TESTS.md` |
| A11 | Observability + soak harness durable extensions — `SessionRecordIncompleteGauge` (A11.1) + fd watcher / heap-snapshot uploader / p3c CLI flags (A11.2) + gauge consumer wiring (A11.1.b — new from 2026-05-13 deep audit) | `docs/_execution/lane_a_code_health/03_execution_slices.md` slices A11.1-A11.2 | `docs/_audits/code_health/a11_soak_harness_durable_kit.md` | CLAUDE.md "Proxy & API Conventions" + R3 §2-4 |

### B — Features

| Lane | Scope | Plan anchor | Decision authority |
|---|---|---|---|
| B1 | Hierarchy refinement (Inheritance Tree component) + admin gateway actorKind sweep (B1.c — new from 2026-05-13 deep audit) | `docs/_execution/lane_b_features/03_execution_slices.md` slices B1.a/B1.b/B1.c | HP #11 + Addendum C2 + CLAUDE.md actor taxonomy |
| B2 | Default Roles catalog (admin-editable; `default_role_catalog_versions` + operator pointer) | `docs/_execution/lane_b_features/03_execution_slices.md` slices B2.1/B2.2 | Decision #2 + Addendum A2 |
| B8 | Audit log hierarchy filter (`ltree` cache + read-side join) | `docs/_execution/lane_b_features/03_execution_slices.md` B8 | Decision #8 + Addendum A3 |
| B11 | JWT handoff replacement — `handoff_codes` (B11.1) + RFC 9470 step-up scaffold (B11.2) + wiring + client adapters (B11.2.b) | `docs/_execution/lane_b_features/03_execution_slices.md` B11.1/B11.2 + ledger row B11.2.b | Addendum A1 (supersedes Decision #5) |

### C — Cross-Surface Parity

| Lane | Scope | Plan anchor | Decision authority |
|---|---|---|---|
| C-EmailsNotifs | Email pipeline lane (SendGrid Event Webhook + scenario inventory + notification catalog completeness) | `docs/_execution/lane_c_parity/03_execution_slices.md` C-1/C-2/C-8/C-11 | Addendum C3 + B3 + B4 |

## Cross-references (Codex-owned lanes Claude consumes from)

| Codex lane | What Claude consumes | When |
|---|---|---|
| A2 (scaffolds) | The `a2_scaffold_inventory.md` wire/delete decisions | Whenever a Claude slice touches a flagged surface |
| A5+A8 (schema versioning + lint) | The `post_deploy/` migration convention + `audit_logs` UPDATE allowlist lint | Any Claude slice that ships a migration |
| A6 (proxy health UI) | Health/readiness gauge contract | When A4 perf slices or A11 observability slices need new gauges |
| A9 (lib/data rehome) | The frozen-legacy delete-only doctrine + new homes under `lib/dev/` and `lib/domain/constants/` | Whenever a Claude slice imports from a former `lib/data/` path |
| B5 (admin access control) + B5.b (catalog amendment) | Admin role posture (`super_admin` writes vs `ff_support` reads) | When Claude slices add new admin routes or touch the catalog tri-mirror |
| B7 (invite flow) | Invite gateway shape | When B11 redemption-code overlaps with invite |
| B9 (My Account) | Active-sessions IA + `_requireFreshMfaToken` gate (client-side; B11.2.b adds server-side step-up) | When Claude touches MFA freshness flows |
| B10 (vendor_applicability) | The new `vendor_applicability` table shape | When Claude touches wage/covers/polling settings |
| C-3/C-4/C-5/C-6/C-7/C-9/C-10 (parity) | Parity decisions on cross-surface tile copy + deep-links | When Claude C-EmailsNotifs slices interact with admin/opsweb/mobile UI |

## Operator-approval gates (per CLAUDE.md)

Per-slice Gate column in `WAVE_EXECUTION_LEDGER.md` is canonical. The triggers (consult the ledger Gate column for the live picture):

- **Auth-critical**: B11.x, B1.c (audit-log actor labeling), any auth-flow change
- **RLS-touching**: any slice that adds/changes RLS policy
- **Schema-touching**: B2, B8, any new migration
- **Proxy-touching**: A3.x, A11.x, B11.x, any slice that edits `tool/advisor_proxy/**`
- **Frozen `lib/auth/**` touch**: B5.b (catalog tri-mirror amendment) and any future catalog edits

Non-gated slices follow the auto-merge-after-audit doctrine: orchestrator merges PRs with `approve-for-merge` verdict and no escalations.

## Workflow

Per CLAUDE.md "Agent-Led Slices": every executor (Claude lane / Codex lane) is a mini-orchestrator that spawns worker sub-agents in isolated worktrees. The executor reviews each worker's diff, writes its own audit table, then commits + pushes + opens PR → STOPS. The orchestrator (separate Claude session) audits the PR per `docs/_audits/audit_chunking_playbook.md`, writes the per-PR audit doc, and merges per the operator-approval gates.

Audit doc location: `docs/_audits/post_codex_wave/pr_<n>_<topic>_audit.md`. See the audit doc index at `docs/_audits/post_codex_wave/README.md`.

Master prompt for fresh sessions: `CLAUDE_HANDOFF_PROMPT.md` (Claude lane) / `CODEX_HANDOFF_PROMPT.md` (Codex lane).

## Change log

| Date | Change |
|---|---|
| 2026-05-12 | Initial assignment (parked-plan Step 6 unpark, 43 slices). |
| 2026-05-13 | Wave evolved to 49 slices via 6 deep-audit/operator-decision row additions (B5.b + B11.2.b + B1.c + A11.1.b + A3.3 + A3.4). Lane assignments table trimmed to lane-level scope; per-slice state defers to the ledger. Cross-references expanded for newly-merged Codex lanes (A9.1, A11, B5, B9). |
