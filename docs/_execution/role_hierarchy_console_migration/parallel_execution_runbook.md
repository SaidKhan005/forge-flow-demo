# Parallel Execution Runbook — Role / Hierarchy Console Migration

**Created:** 2026-05-05
**Trigger:** Phase 7 + Phase 10 close (both marked complete in `PROJECT_TRACKER.md`)
**Block:** 9 slices total, 3 waves, 3 paired-merge gates
**Owner:** Vanessa runs the kickoff; Codex reviews; Claude executes in worktrees

This runbook is what you read when you're ready to fire the slice prompts. It tells you exactly which worktrees to spin, in what order, with which branch names, what each one owns, where the serialization rules apply, and how to land each pair safely.

## TL;DR

```
Wave 1 (start day 1):
  - 11W.1 Members            (worktree: claude/11W-1-members)
  - 11A.12 Members admin     (worktree: claude/11A-12-members-admin)
  ─ both ACCEPT → integration lane lands nav + resolver wiring → both merge ─

Wave 2 (start after Wave 1 integration lands):
  - 11W.2 Roles              (worktree: claude/11W-2-roles)
  - 11W.3 Hierarchy          (worktree: claude/11W-3-hierarchy)
  - 11W.4 Sessions           (worktree: claude/11W-4-sessions)
  - 11A.13 Roles+Hier+Sess   (worktree: claude/11A-13-roles-hierarchy-sessions)
  ─ all 4 ACCEPT → integration lane → all 4 merge ─

Wave 3 (start after Wave 2 integration lands):
  - 11W.5 Audit Log          (worktree: claude/11W-5-audit-log)
  - 11W.6 Security           (worktree: claude/11W-6-security)
  - 11A.14 Audited Support   (worktree: claude/11A-14-audited-support-actions)
  ─ all 3 ACCEPT → integration lane → all 3 merge ─
```

Each wave runs lanes fully in parallel. Across waves, integration lanes serialize.

## Pre-flight (do once before Wave 1)

1. Verify Phase 7 + Phase 10 close — both phases marked complete in `PROJECT_TRACKER.md`. If either is `in_progress`, STOP and finish them first per the user's stated sequencing decision (`memory/project_role_hierarchy_web_migration_sequencing.md`).
2. Confirm master is green: `flutter analyze --fatal-infos lib/ test/` and `flutter test test/operator_web/ test/admin/` (touch tests, not the full suite).
3. Confirm staging proxy is on a revision that includes Phase 9 + 11A.1 routes. If `forge-flow-staging-proxy` is older, deploy first.
4. Confirm the parity contract exists at `docs/contracts/team_roles_hierarchy_console_parity_contract.md`. If missing or stale, STOP and update first.
5. Confirm operator-picker fixture data on the admin side covers at least 3 demo operators. If only 1, expand `lib/admin/services/operator_location_admin_gateway.dart` demo set first (that's an inline tweak, not a slice).
6. Capture master commit SHA — every worktree branches off this exact commit. Record it in the kickoff note for Codex.

## Wave 1 — Members pair (2 lanes, ~3-5 days each)

### Worktrees to create

```powershell
# Run from repo root in PowerShell:
git worktree add .claude/worktrees/<auto-name-1> -b claude/11W-1-members master
git worktree add .claude/worktrees/<auto-name-2> -b claude/11A-12-members-admin master
```

`<auto-name-1>` / `<auto-name-2>` follow the existing worktree naming convention (random adjective+name pairs — see existing worktrees in `.claude/worktrees/` for examples). The harness picks names automatically.

### Slice prompts

| Lane | Prompt file | Branch |
|---|---|---|
| Wave 1A | `docs/_execution/role_hierarchy_console_migration/11W_1_members.md` | `claude/11W-1-members` |
| Wave 1B | `docs/_execution/role_hierarchy_console_migration/11A_12_members_admin.md` | `claude/11A-12-members-admin` |

### File ownership map (Wave 1)

Each lane owns its files exclusively. No two lanes write to the same file in this wave.

| File | Owner |
|---|---|
| `lib/operator_web/services/web_team_users_gateway.dart` | 11W.1 |
| `lib/operator_web/services/demo_web_team_users_gateway.dart` | 11W.1 |
| `lib/operator_web/services/demo_team_fixtures.dart` | 11W.1 (creates; later waves extend) |
| `lib/operator_web/screens/members_screen.dart` | 11W.1 |
| `lib/operator_web/screens/invite_member_dialog.dart` | 11W.1 |
| `test/operator_web/members_screen_test.dart` | 11W.1 |
| `test/operator_web/web_team_users_gateway_test.dart` | 11W.1 |
| `docs/_walkthroughs/11W.1.md` | 11W.1 |
| `lib/admin/services/members_admin_gateway.dart` | 11A.12 |
| `lib/admin/services/demo_members_admin_gateway.dart` | 11A.12 |
| `lib/admin/screens/members_admin_screen.dart` | 11A.12 |
| `lib/admin/screens/invite_member_admin_dialog.dart` | 11A.12 |
| `test/admin/members_admin_screen_test.dart` | 11A.12 |
| `test/admin/members_admin_gateway_test.dart` | 11A.12 |
| `docs/_walkthroughs/11A.12.md` | 11A.12 |

### Shared seams (deferred to integration lane)

These files MUST NOT be touched by either Wave 1 lane directly. Both lanes leave their wiring as a TODO for the integration lane:

- `lib/operator_web/router/operator_web_router.dart` (nav-item registration for `/members`)
- `lib/main_operator_web.dart` (gateway resolver wiring for the new gateway)
- `lib/admin/admin_routes.dart` (route registration for Members admin)
- `lib/main_admin.dart` (admin gateway resolver wiring)

### Integration lane (Wave 1)

After both 11W.1 and 11A.12 hit `ACCEPT` from Codex:

1. New worktree: `git worktree add .claude/worktrees/<auto-name-int1> -b claude/11W-1-11A-12-integration master`
2. Cherry-pick (or rebase merge) both slice branches into the integration branch.
3. Land the four shared-seam edits (router nav, web entry resolver, admin routes, admin entry resolver). Single coherent commit per file.
4. Run full web builds:
   - `flutter build web -t lib/main_operator_web.dart --dart-define=OPERATOR_WEB_DEMO_AUTH=true --pwa-strategy=none`
   - `flutter build web -t lib/main_admin.dart --dart-define=ADMIN_DEMO_AUTH=true --pwa-strategy=none`
5. End-to-end demo walkthrough on both consoles. If the wave's pair walkthroughs both green, push to staging.
6. Codex final review of the integration branch + tracker update.
7. Merge integration branch to master. Both slice branches merge transitively.

## Wave 2 — Roles + Hierarchy + Sessions inspect (4 lanes, ~3-5 days each)

### Worktrees to create

```powershell
git worktree add .claude/worktrees/<auto-name-3> -b claude/11W-2-roles master
git worktree add .claude/worktrees/<auto-name-4> -b claude/11W-3-hierarchy master
git worktree add .claude/worktrees/<auto-name-5> -b claude/11W-4-sessions master
git worktree add .claude/worktrees/<auto-name-6> -b claude/11A-13-roles-hierarchy-sessions master
```

Branch off master AFTER Wave 1 integration merges, so Wave 2 starts from a tree that already has `11W.1` + `11A.12` landed. This avoids a 4-way rebase later.

### Slice prompts

| Lane | Prompt file | Branch |
|---|---|---|
| Wave 2A | `docs/_execution/role_hierarchy_console_migration/11W_2_roles.md` | `claude/11W-2-roles` |
| Wave 2B | `docs/_execution/role_hierarchy_console_migration/11W_3_hierarchy.md` | `claude/11W-3-hierarchy` |
| Wave 2C | `docs/_execution/role_hierarchy_console_migration/11W_4_sessions.md` | `claude/11W-4-sessions` |
| Wave 2D | `docs/_execution/role_hierarchy_console_migration/11A_13_roles_hierarchy_sessions_admin.md` | `claude/11A-13-roles-hierarchy-sessions` |

### File ownership map (Wave 2)

Each lane owns its own gateway + screens + tests + walkthrough. No cross-lane file writes. The shared `lib/operator_web/services/demo_team_fixtures.dart` is touched by 11W.2/3/4 — each lane extends it additively (new top-level constants), not in-place. The integration lane resolves any add-add conflicts by merging the additions.

| File | Owner |
|---|---|
| `lib/operator_web/services/web_team_roles_gateway.dart` + demo + tests | 11W.2 |
| `lib/operator_web/screens/roles_screen.dart` + custom_role_editor + permission_explainer + permission_picker_tree | 11W.2 |
| `docs/_walkthroughs/11W.2.md` | 11W.2 |
| `lib/operator_web/services/web_team_hierarchy_gateway.dart` + demo + tests | 11W.3 |
| `lib/operator_web/screens/hierarchy_screen.dart` + create_org_unit_dialog + edit_location_dialog | 11W.3 |
| `lib/operator_web/widgets/org_unit_tree_view.dart` + location_card.dart | 11W.3 |
| `docs/_walkthroughs/11W.3.md` | 11W.3 |
| `lib/operator_web/services/web_team_sessions_gateway.dart` + demo + tests | 11W.4 |
| `lib/operator_web/screens/sessions_screen.dart` | 11W.4 |
| `docs/_walkthroughs/11W.4.md` | 11W.4 |
| `lib/admin/services/roles_hierarchy_sessions_admin_gateway.dart` + demo + tests | 11A.13 |
| `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart` | 11A.13 |
| `docs/_walkthroughs/11A.13.md` | 11A.13 |
| `lib/operator_web/services/demo_team_fixtures.dart` | 11W.2/3/4 (additive only; conflicts resolved by integration lane) |

### Shared seams (deferred to integration lane)

- `lib/operator_web/router/operator_web_router.dart` (3 new nav items: roles / locations / sessions)
- `lib/main_operator_web.dart` (3 new gateway resolvers)
- `lib/admin/admin_routes.dart` (1 new route)
- `lib/main_admin.dart` (1 new admin gateway resolver)

### Integration lane (Wave 2)

Same pattern as Wave 1 but resolves 4 lanes' fixtures-additions into a coherent `demo_team_fixtures.dart`. Run both web builds + walkthroughs end-to-end across all 4 surfaces.

## Wave 3 — Audit Log + Security + Audited Support Actions (3 lanes, ~5-7 days for 11A.14 due to migration)

### Worktrees to create

```powershell
git worktree add .claude/worktrees/<auto-name-7> -b claude/11W-5-audit-log master
git worktree add .claude/worktrees/<auto-name-8> -b claude/11W-6-security master
git worktree add .claude/worktrees/<auto-name-9> -b claude/11A-14-audited-support-actions master
```

### Slice prompts

| Lane | Prompt file | Branch |
|---|---|---|
| Wave 3A | `docs/_execution/role_hierarchy_console_migration/11W_5_audit_log.md` | `claude/11W-5-audit-log` |
| Wave 3B | `docs/_execution/role_hierarchy_console_migration/11W_6_security.md` | `claude/11W-6-security` |
| Wave 3C | `docs/_execution/role_hierarchy_console_migration/11A_14_audited_support_actions.md` | `claude/11A-14-audited-support-actions` |

### File ownership map (Wave 3)

| File | Owner |
|---|---|
| `lib/operator_web/services/web_team_audit_log_gateway.dart` + demo + tests | 11W.5 |
| `lib/operator_web/screens/audit_log_screen.dart` + audit_log_row.dart | 11W.5 |
| `docs/_walkthroughs/11W.5.md` | 11W.5 |
| `lib/operator_web/services/web_security_gateway.dart` + demo + tests | 11W.6 |
| `lib/operator_web/screens/security_screen.dart` + mfa_factor_dialog.dart + change_password_dialog.dart | 11W.6 |
| `docs/_walkthroughs/11W.6.md` | 11W.6 |
| `lib/admin/services/audited_support_actions_admin_gateway.dart` + demo + tests | 11A.14 |
| `lib/admin/screens/audited_support_actions_admin_screen.dart` + paired_approval_erasure_dialog.dart | 11A.14 |
| `db/migrations/<timestamp>_phase_11A_14_admin_users_reset_mfa_factors_key.sql` | 11A.14 |
| `lib/auth/permission_keys.dart` (additive constant) | 11A.14 |
| `docs/contracts/auth_permission_key_catalog.md` (additive row) | 11A.14 |
| `docs/contracts/team_roles_hierarchy_console_parity_contract.md` (Surface map update) | 11A.14 |
| `test/advisor_proxy_test.dart` (Phase 9.0 foundation test stays green after catalog addition) | 11A.14 |
| `docs/_walkthroughs/11A.14.md` | 11A.14 |

### Shared seams (deferred to integration lane)

- `lib/operator_web/router/operator_web_router.dart` (2 new nav items: audit-log / security)
- `lib/main_operator_web.dart` (2 new gateway resolvers)
- `lib/admin/admin_routes.dart` (1 new route)
- `lib/main_admin.dart` (1 new admin gateway resolver)

### Wave 3 special handling

- `11A.14` ships a migration. Other Wave 3 lanes (`11W.5`, `11W.6`) MUST branch off master BEFORE `11A.14` merges, OR rebase on `11A.14`'s migration commit before integration. Recommend: spin all three Wave 3 worktrees off the same master commit at the same time, and let the integration lane handle the rebase if `11A.14` finishes first.
- After `11A.14` migration drift scanner runs in its worktree, the integration lane re-runs the scanner on the integrated branch to confirm no drift.
- The Phase 9.0 foundation test in `test/advisor_proxy_test.dart` is the gate: if it fails after the catalog addition, `11A.14` did not seed the new key in the migration. STOP and fix.

## Cross-wave rules

### Wave-to-wave serialization

Waves run sequentially. The reasons:

1. The integration lane in each wave touches `lib/main_operator_web.dart` and `lib/main_admin.dart`. Two waves modifying the same entry points concurrently creates merge hell.
2. Wave 2 lanes branch off the post-Wave-1-integration commit so they pick up the `11W.1` + `11A.12` files for cross-reference (e.g., `11W.2` reuses `demo_team_fixtures.dart` shipped in `11W.1`).
3. The pair-merge gate (parity contract) requires both sides of a pair to ACCEPT before either merges — running waves serially makes the pairing obvious; running them concurrently risks a `11W.2` merging before `11A.13` if the integration lanes overlap.

### Within-wave parallelism

Lanes within a wave run fully in parallel. The harness supports this — see existing worktrees in `.claude/worktrees/` for the count of concurrent worktrees the team has run before. The only contention is on `demo_team_fixtures.dart` in Wave 2, resolved by additive-only edits.

### Pair-merge gate enforcement

The parity contract says: a `11W.x` slice cannot merge without its `11A.y` partner reaching ACCEPT, and vice-versa. The integration lane enforces this — it does not start until every member of the wave's pair-set hits ACCEPT.

| Wave | Pair / set | Merge gate |
|---|---|---|
| 1 | `11W.1` ↔ `11A.12` | Both ACCEPT |
| 2 | `11W.2` + `11W.3` + `11W.4` ↔ `11A.13` | All 4 ACCEPT |
| 3 | `11W.5` + `11W.6` ↔ `11A.14` | All 3 ACCEPT |

If one slice in a set is `FOLLOW-UP NEEDED`, no slice in the set merges. The blocking slice gets a fix-pass; other slices wait at ACCEPT.

### Codex review queue

With 3-4 slices in flight per wave plus an integration lane, Codex review queue depth peaks at 4-5 active reviews. The standard prompt format `docs/CODEX_PROMPT_GENERATION_STANDARD.md` § Codex Review applies per slice. Recommended cadence: Codex reviews the first slice to report ACCEPT-quality immediately; subsequent slices queue.

### Backend route safety

The parity contract says no slice introduces new backend routes EXCEPT `11A.14` (one new permission key + possibly one new route for MFA-factors-reset if not already shipped). If any other slice's prompt asks for a new route, STOP and update the parity contract first. Do NOT silently add routes.

### Demo-mode fixture safety

`lib/operator_web/services/demo_team_fixtures.dart` is shared. The rule is: any slice may ADD a new top-level constant (a new `kDemo<X>` symbol). No slice may MODIFY an existing top-level constant. The integration lane resolves any add-add conflicts trivially.

For the admin side, each admin slice ships its own fixture file (e.g., `lib/admin/services/demo_members_admin_fixtures.dart`) so cross-operator demo data stays isolated per slice.

## Browser QA per wave

After each wave's integration lane lands, run end-to-end browser QA:

### Operator Web Console QA

```powershell
flutter build web -t lib/main_operator_web.dart --dart-define=OPERATOR_WEB_DEMO_AUTH=true --pwa-strategy=none
Set-Location build/web
python -m http.server 8081 --bind 127.0.0.1
```

Open `http://127.0.0.1:8081/` → land on welcome → enter demo magic-link token (per `docs/_walkthroughs/11W.0.md`) → walk every nav item shipped so far. Capture screenshots per slice walkthrough.

### Admin Console QA

```powershell
flutter build web -t lib/main_admin.dart --dart-define=ADMIN_DEMO_AUTH=true --pwa-strategy=none
Set-Location build/web
python -m http.server 8082 --bind 127.0.0.1
```

Open `http://127.0.0.1:8082/` → log in as `super.admin@forgeflow.test` → pick a fixture operator → walk every admin tab shipped so far.

Use port 8081 for operator-web and 8082 for admin so both can run concurrently without conflict.

### Live staging QA (after wave merges to master)

Per `docs/UX_ADJUSTMENT_FRAMEWORK.md` § Browser And Runtime Loop and `docs/contracts/slice_runtime_acceptance_contract.md` § Live Staging Proof:

```powershell
scripts/deploy_operator_web.ps1 -OperatorWebProxyBaseUri https://staging-api.feflow.org
scripts/deploy_admin_console.ps1 -AdminProxyBaseUri https://staging-api.feflow.org
```

Then exercise both consoles against staging proxy from a fresh browser. Capture revision IDs in the wave's execution report.

Live staging QA is read-mostly. Live writes require user action-time approval per the safety rules — Codex flags any slice that submits a live write during QA without explicit approval.

## What can break and how to recover

### A slice rebases mid-wave

If `11A.14` migration lands while `11W.5` / `11W.6` are mid-flight, the others rebase. Run:

```powershell
git fetch origin master
git rebase master
dart run tool/migration_drift_scanner.dart --strict-docs
```

If drift scanner is dirty, a docs/tracker line in the slice's worktree references stale migration counts. Update locally — do NOT change the migration itself.

### Codex returns FOLLOW-UP NEEDED on one slice in a set

The other slice(s) in the set sit at ACCEPT and wait. The blocked slice fixes the finding. The integration lane does not start until every slice ACCEPTS.

### Two slices touch the same file (rare; should not happen given the ownership map)

If the ownership map missed a file, the lane that wrote first wins. The second lane rebases onto the first slice's commit. Update this runbook's File ownership map for next wave so the omission doesn't recur.

### Codex flags "new backend route added without parity contract update"

The slice prompt was wrong. STOP, update the parity contract first to document the new route + its rationale, then update the slice prompt to cite the contract update, then re-run.

### `dart run tool/migration_drift_scanner.dart --strict-docs` fails after Wave 3

`11A.14` migration didn't update the watched docs/tracker counts. Run `--fix` to auto-update, then re-verify. If `--fix` doesn't resolve, check whether new migrations landed on master in parallel that the scanner needs to know about.

## Reporting

After each wave's integration lane merges:

1. Update `PROJECT_TRACKER.md` lines 66-67 (`11W` Operator Web Console + `11A` foundation rows) with the new accepted slices.
2. Update `memory/session_handoff.md` per the 40-line cap rule.
3. Mark the wave complete in this runbook (add a `## Wave N closed YYYY-MM-DD` section at the bottom with merged commits).
4. Update `memory/project_role_hierarchy_web_migration_sequencing.md` to reflect partial-block progress.

After Wave 3 closes:

1. Mark the entire migration block complete in this runbook.
2. Update `memory/MEMORY.md` to reflect that the role/hierarchy console migration is done.
3. The parity contract stays Active — future slices that touch any of these surfaces still bind to it.

## Wave-close log (filled in as waves close)

(empty — populate as waves complete)
