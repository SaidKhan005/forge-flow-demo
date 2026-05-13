# PR #488 — Harden admin hierarchy lifecycle access — Audit

Auditor: orchestrator on `claude/pr-488-audit-doc` (worktree `nifty-clarke-d3ec25`).
Audited branch: `codex/admin-hierarchy-lifecycle-access-hardening` at tip `01c48921` (Draft PR).
Base (PR head's git-base): `codex/admin-audit-log-contract-schema` at `84de5449` (PR #484, now merged to master at `a410b5b5`).
Master tip at audit: `2324fe5d` (PR #486).
Diff vs PR head's git-base: 11 files, +671 / -26, 1 commit.
Audit date: 2026-05-13.
Audit shape: per `docs/_audits/audit_chunking_playbook.md`. 11 files crosses the >5-files multi-surface threshold; chunking applied.

This is **PR B in the 3-PR plan**. PR C (#484) landed on master. PR A still pending — most conflict-prone with the merged `advisor_proxy.dart` from PR #481/PR #484.

---

## Verdict

**approve-for-merge** — auto-merge eligible per 2026-05-13 doctrine shift (`memory/feedback_orchestrator_auto_merge_after_audit.md`).

All 5 active chunks audit CLEAN. No findings requiring orchestrator-fix. No escalations to operator. No send-back items.

PR #488 hits operator-approval-gated surfaces (schema migration, repository layer touching access materialization). Per the 2026-05-13 doctrine, those gates are subsumed into the audit-verdict gate when the audit explicitly verifies each gated surface against its anchor contract — which this audit does.

---

## Drift-from-master note (non-blocking)

PR #488 was branched off `codex/admin-audit-log-contract-schema` BEFORE the orchestrator's PR #485 + #486 + #487 merged to master. Result: 4 files in `git diff master..PR#488 head` reflect master-only changes that PR #488's branch doesn't carry:

- `db/migrations/202605080800_auth_permission_version.sql` — PR #487 added the M1 carve-out comment
- `lib/admin/screens/admin_timing_setup_screen.dart` — PR #485 added the HP #11 inheritance notice
- `docs/_audits/post_codex_wave/pr_481_retroactive_audit.md` — PR #485 added + PR #487 updated this audit doc
- `docs/_audits/post_codex_wave/pr_484_audit.md` — PR #486 added this audit doc

PR #488 doesn't TOUCH any of these 4 files. The merge commit will keep master's version of all 4 — no revert, no conflict. Verified by content-comparison spot-check on migration 80800 (PR #488's branch shows the pre-PR-#487 version; merge will retain PR #487's version because PR #488 didn't touch the file).

**This is an observation, not a finding.** The 11 files in PR #488's actual scope (per `gh pr view --json changedFiles`) are the audited set.

---

## Per-chunk findings

### Chunk 1 — Schema migration (1 new file)

**CLEAN.**

`db/migrations/202605131020_admin_hierarchy_lifecycle_access_hardening.sql` (~150 lines):

**Column additions (idempotent — `add column if not exists`):**

- `org_units`: `created_by uuid`, `updated_by uuid`, `suspended_at timestamptz`, `deleted_at timestamptz` (last two are defensive re-adds; original came from 202605082200; idempotent so no harm) ✓
- `locations`: same 4 columns, same pattern ✓
- `users`: `created_by uuid`, `updated_by uuid` (no lifecycle columns — users aren't soft-deleted at this layer) ✓
- All columns have `comment on column` documentation ✓

**Active-only org-unit uniqueness:**

- Drops existing `org_units_operator_id_path_key` (the launch-era unique constraint on `(operator_id, path)`)
- Replaces with partial unique index `org_units_operator_path_active_uq` on `(operator_id, path) WHERE deleted_at IS NULL`
- Allows a soft-deleted org_unit + a new one with the same path to coexist ✓ Right pattern for soft-delete + path reuse

**Operator-leading partial indexes (matches CLAUDE.md HP #4):**

- `org_units_operator_active_id_idx (operator_id, id) WHERE deleted_at IS NULL`
- `org_units_operator_parent_name_active_idx (operator_id, parent_id, lower(name)) WHERE deleted_at IS NULL`
- `org_units_operator_suspended_idx (operator_id, suspended_at) WHERE suspended_at IS NOT NULL AND deleted_at IS NULL`
- `locations_operator_active_id_idx (operator_id, location_id) WHERE deleted_at IS NULL`
- `locations_operator_suspended_idx (operator_id, suspended_at) WHERE suspended_at IS NOT NULL AND deleted_at IS NULL`

All 5 lead with `operator_id` ✓.

**Active-target lookup indexes (for repository guards):**

- `user_roles_active_location_target_idx (operator_id, location_id, user_id) WHERE scope_type='location' AND revoked_at IS NULL`
- `user_roles_active_org_unit_target_idx (operator_id, org_unit_id, user_id) WHERE scope_type='org_unit' AND revoked_at IS NULL`
- `auth_invites_active_location_target_idx (operator_id, location_id, expires_at) WHERE scope_type='location' AND accepted_at IS NULL AND revoked_at IS NULL`
- `auth_invites_active_org_unit_target_idx (operator_id, org_unit_id, expires_at) WHERE scope_type='org_unit' AND accepted_at IS NULL AND revoked_at IS NULL`

All 4 lead with `operator_id` ✓. Paired with repository guards in Chunk 2.

**`refresh_user_effective_locations(p_user_id, p_operator_id)` rewrite:**

- Deletes + re-inserts the user_effective_locations rows for the given (user, operator) pair
- Excludes locations with `deleted_at IS NOT NULL` OR `suspended_at IS NOT NULL`
- **Excludes locations whose ANCESTOR org_units are deleted or suspended** (uses ltree `<@` descendant operator):
  ```sql
  and not exists (
    select 1 from public.org_units inactive_ancestor
    where inactive_ancestor.operator_id = loc.operator_id
      and (inactive_ancestor.deleted_at is not null or inactive_ancestor.suspended_at is not null)
      and loc.org_unit_path <@ inactive_ancestor.path
  )
  ```
- Handles all 3 scope types (operator_wide, location, org_unit) — for org_unit scope, additionally requires the org_unit itself to be non-deleted and non-suspended

**Trigger updates (replaces existing on locations + org_units):**

- `locations_update_refresh_effective_locations` — fires when `parent_org_unit_id`, `org_unit_path`, `suspended_at`, or `deleted_at` changes
- `org_units_update_refresh_effective_locations` — fires when `parent_id`, `path`, `suspended_at`, or `deleted_at` changes
- Both call existing functions (`refresh_user_effective_locations_from_location`, `refresh_user_effective_locations_from_org_unit`) verified to exist on master at `202604290101_phase_9_hierarchy_access_wiring.sql:359, 392`

**One-time refresh at end of migration:**

```sql
select public.refresh_user_effective_locations_for_operator(op.operator_id)
  from public.operators op;
```

- Rebuilds the user_effective_locations cache for every operator after the new exclude-inactive-ancestors logic is in place
- For staging/prod with N operators, this is N invocations of the refresh function — acceptable for the typical operator count (single-digit to low-hundreds)
- Function exists on master at `202604290101_phase_9_hierarchy_access_wiring.sql:310` ✓

**No RLS policy changes** — the new columns inherit RLS from the existing org_units/locations/users tables. Partial indexes don't need RLS policies.

**Authority anchors verified:**

- CLAUDE.md HP #4 (operator-leading indexes) ✓
- `hardening_rls_and_repository_pattern_contract.md` (RLS via existing wrappers) ✓
- Expand-contract pattern (`if not exists` + idempotent re-adds) ✓
- CLAUDE.md Workflow migration discipline ✓
- Migration cutoff lint passes (Codex's local report; new timestamp 131020 properly after 131010)

### Chunk 2 — Repository layer (2 files)

**CLEAN.**

`lib/infrastructure/persistence/postgres/repositories/locations_repository.dart` (+34):

- Update method filters `deleted_at is null` ✓ (prevents updating soft-deleted locations)
- New active-targets guard in soft-delete path: queries `user_roles` + `auth_invites` for active targets pointing at this location; throws `StateError` with clear message if any exist. Matches Codex's "direct active role/invite delete guards" claim ✓

`lib/infrastructure/persistence/postgres/repositories/org_units_repository.dart` (+102/-10):

- **`listAllLocations` cascade-hide:** filters out locations whose ancestor org_units are deleted (using ltree `<@`) ✓
- **`moveLocation` adds `operator_id` to WHERE clause:** tenant-leading defense-in-depth, even with `withTenant` scope ✓
- **`setOrgUnitSuspended` adds `operator_id` to WHERE:** same pattern ✓
- **`deleteOrgUnit` adds active-targets guard:** before soft-deleting, queries user_roles + auth_invites; throws `OrgUnitMoveRejected` with code `org_unit_has_active_access_targets` (409) ✓
- **`deleteOrgUnit` adds `operator_id` to WHERE:** ✓
- **`setLocationSuspended` adds `operator_id` to WHERE:** ✓
- **`deleteLocation` adds active-targets guard:** same pattern as deleteOrgUnit; throws `location_has_active_access_targets` ✓
- **`deleteLocation` adds `operator_id` to WHERE:** ✓
- **`listAllLocationsAsAdmin` cascade-hide:** same deleted-ancestor filter as `listAllLocations` ✓

**Authority anchors verified:**

- CLAUDE.md HP #4 (operator-leading queries, tenant-leading defense-in-depth on every WHERE) ✓
- `hardening_rls_and_repository_pattern_contract.md` (OperatorScopedRepository pattern preserved via `withTenant`) ✓
- `team_roles_hierarchy_console_parity_contract.md` (admin lifecycle actions — suspend/delete/restore — supported with proper guards) ✓

The active-targets guards are well-shaped defensive code: force the operator to revoke/reassign roles + invites before deleting the underlying hierarchy node. Prevents orphaned access entitlements.

### Chunk 5 — Tests (3 files)

**CLEAN.**

- `test/phase_9_hierarchy_lifecycle_access_hardening_test.dart` (NEW, +103): SQL-content shape coverage for the new migration — verifies lifecycle stamps, partial unique index, 4 active-target lookup indexes, scope_type predicates, accepted_at filter.
- `test/org_units_repository_live_binding_test.dart` (+172): new test group "OrgUnitsRepository lifecycle delete guards" covering `deleteOrgUnit`/`deleteLocation` soft-delete + operator guard + active-targets rejection paths.
- `test/infrastructure/persistence/postgres/repositories/locations_repository_test.dart` (+50/-3): coverage extension for the soft-delete guard in locations_repository.

Test coverage directly maps to the new behavior in Chunks 1+2. No orphan tests, no coverage gaps for the active-targets guard logic.

### Chunk 6 — Docs + runbooks (4 files)

**CLEAN.** Consistent migration cutoff bumps from 131010 → 131020:

- `docs/POST_HARDENING_FOLLOWUPS.md`: adds 1 new row for migration 131020; queue extended from 36 → 37 pending.
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`: cutoff bumped + adds "lifecycle access hardening" to the list of later migrations.
- `docs/phases/phase_9/phase_9_execution_backlog.md`: same cutoff bump + adds "lifecycle access hardening" to the description.
- `runbooks/phase_9_production1_migration_apply_runbook.md`: cutoff bumped + adds 131020 to the pending-followup list.

No drift between code and docs.

### Chunk 7 — Scripts (1 file)

**CLEAN.** `scripts/postgres_staging_setup.ps1`: trivial 1-line cutoff string bump from 131010 → 131020.

---

## Verification

- **Codex's local report:** targeted Flutter tests passed (locations, org_units, lifecycle migration test); targeted `dart analyze` passed; `migration_drift_scanner --fix --strict-docs` passed; `migration_cutoff_lint` passed; Postgres import + index-leading-column + RLS policy lints passed; pre-push hook lints passed; `git diff --check` passed.
- **GitHub remote checks:** UNSTABLE (billing block, expected, not a code issue).
- **Function-existence verification:** all 3 functions called by the migration's triggers + one-time refresh (`refresh_user_effective_locations_from_location`, `refresh_user_effective_locations_from_org_unit`, `refresh_user_effective_locations_for_operator`) verified to exist on master at `202604290101_phase_9_hierarchy_access_wiring.sql:310, 359, 392`.
- **Drift verification:** 4 files differ between PR #488's branch and master because PR #488 was branched before PR #485/#486/#487 merged. None of the 4 files are touched by PR #488 — merge commit will retain master's version cleanly.

---

## Orchestrator-fix commits (Phase 5b)

| Finding § | Commit SHA | Files touched | Re-audit result |
|---|---|---|---|
| (none) | — | — | — |

PR #488 has no findings requiring orchestrator-fix.

---

## Follow-up items (none require send-back)

Nothing to send back. The audit is clean.

Wave-level follow-ups not in this PR's scope:

- PR A `codex/admin-audit-target-hardening` — still pending. Last in the 3-PR plan. Most conflict-prone with PR #481's merged `advisor_proxy.dart` diff. Will require careful rebase + intent-preservation per the chunking playbook Phase 4 conflict-resolution discipline.
- Operator visual tests carried over: PR #482 back-nav consolidation + PR #485 inheritance notice on admin_timing_setup_screen.

---

## Operator approval gates (auto-merge eligible)

PR #488 touches:

- **Schema migration (1 new)** — `202605131020_admin_hierarchy_lifecycle_access_hardening.sql`: operator-leading indexes + partial unique + trigger updates.
- **Repository layer** — `locations_repository.dart`, `org_units_repository.dart`: tenant-leading WHERE clauses + active-targets guards + cascade-hide for deleted ancestors.

Per the 2026-05-13 doctrine shift codified at `memory/feedback_orchestrator_auto_merge_after_audit.md`, these gated surfaces are subsumed into the audit-verdict gate when the orchestrator audit explicitly verifies each surface against its anchor contract. This audit does:

- CLAUDE.md HP #4 leading-column rule: verified per index (✓ for all 9 indexes in migration 131020).
- `hardening_rls_and_repository_pattern_contract.md`: verified `withTenant` preserved + no bare `current_setting()` reads + operator_id-in-WHERE defense-in-depth on every mutation.
- `team_roles_hierarchy_console_parity_contract.md`: verified admin lifecycle actions (suspend/delete) supported with proper guards.

Auto-merge proceeds. Operator retains emergency-revert capability if anything surprises post-merge.

---

## Citations

All code citations are to the worktree at `C:/Git Local Repos/forge_flow_demo/` on `origin/codex/admin-hierarchy-lifecycle-access-hardening` at tip `01c48921`.

Source documents:

- `CLAUDE.md` L73 (operator-leading index rule); RLS-Ready Schema section; Workflow migration discipline.
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` — Chunk 2 anchor.
- `docs/contracts/team_roles_hierarchy_console_parity_contract.md` — admin lifecycle actions.
- `docs/_audits/audit_chunking_playbook.md` Phase 5b (orchestrator-fix-by-default + authority-anchor rule).
- `memory/feedback_orchestrator_auto_merge_after_audit.md` — 2026-05-13 doctrine shift.
- `docs/_audits/post_codex_wave/pr_484_audit.md` — PR C audit, predecessor in the 3-PR plan.
- `docs/_audits/post_codex_wave/pr_481_retroactive_audit.md` — PR #481 retroactive audit, source of the workflow learnings codified in the playbook.

---

## Auditor's note

PR #488 is a clean, contract-grade slice. It properly extracts the non-superseded hardening from the original 110100 (creator/updater stamps, active-only path uniqueness, lookup indexes) and adds substantial new value: cascade-hide for deleted ancestors via ltree `<@`, active-targets guards before lifecycle mutations, and a tightened `user_effective_locations` refresh function that excludes inactive ancestors.

The repository changes are particularly well-shaped: every mutation gains `operator_id` in WHERE (defense-in-depth even under `withTenant`); every soft-delete validates active-target dependencies before proceeding; list queries filter out cascade-hidden rows. This is the kind of code that's easy to verify but tedious to write — Codex's structure here is clean.

The drift-from-master observation is purely a sequencing artifact (PR #488 was branched before some master commits landed). Non-overlapping. Merge commit handles it.

PR B (this one) lands on master. Wave moves to PR A — which will be harder because it touches the same proxy code PR #481 already changed.
