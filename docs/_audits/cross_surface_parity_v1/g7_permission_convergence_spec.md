# Spec — Permission Enforcement Convergence (G7 / G30 / G8 / G9 / G31 / G32)

> **STATUS 2026-05-16 — v2 RE-SPEC BELOW IS AUTHORITATIVE.** The original stale §0..§5 (built on the v1 6-role seed) is REPLACED. Real model = v2 default role catalog (10 roles, `db/migrations/202605150000_phase_r2l_default_role_catalog_v2.sql`). `location_manager` is a REAL v2 role (keep); `operator_admin` is the only phantom. G30 has SHIPPED (#859).

## operator_admin VERDICT — resolved 2026-05-16 (independent trace)

`operator_admin` is a **phantom**: never seeded in v1 or v2; only the F&F-grant `operator_admins` *table* shares the name (unrelated — ignore). Sole producer is `_inferRoles` synthesizing it from free-text role labels; every consumer is a **fallback-only** admit/write set (read only when `session.permissions.isEmpty`). Live path always hydrates the permission snapshot ⇒ `PermissionKeys.*` per-screen gates win ⇒ synthesized `operator_admin` is **never read on a real decision**. No demo session produces it either.

**Decision:** fold into **`operator_owner`**. Do **not** map to a v2 role; do **not** seed a 7th role. → G7c (doc-only) + G7d (delete `'operator_admin'` synthesis + all fallback sets + the shell pill).

## OPERATOR DECISIONS — 2026-05-16 (binding; resolves §6 open questions)

- **GM Team-nav regression → FIX IN G7** (fold `team_scope_visibility_policy.dart` GM fix into G7d-mobile). It is a real post-v2 regression.
- **No live source emits raw v1 role-key labels** (operator confirmed). `_inferRoles` re-bases on **v2 display names only**; NO v1→v2 label translation table required.
- **Soft-deleted v1 role constants** (`roleOperatorManager/Supervisor/Staff`) → **KEEP as `@Deprecated` migration-history aliases** (do not hard-remove).
- **G7c contract-doc edit APPROVED** (strike never-real `operator_admin "(when seeded)"`; rewrite v1→v2 role names in `auth_permission_key_catalog.md`). Doc-only.
- **operator_admin removal demo/boot fail-closed → ACCEPTED** (zero live impact; fail-closed is safer).
- Q5 (demo fixtures) / Q6 (mobile scope): fold read-path-affecting fixture cleanup + the GM-nav mobile fix into G7d; defer pure display-only fixture hygiene.

---

## 0. Headline — corrected authoritative model (v2 catalog)

Proxy server enforcement (`RepositoryProxyAdminPermissionGuard` + `RepositoryProxyPermissionSnapshotResolver`) runs `PermissionResolver` (`lib/auth/permission_resolution.dart:130-256`) over DB `user_roles ⋈ role_permissions`. **`PermissionResolver` is role-string-agnostic** — pure `roleId` UUIDs + `(permissionKey, effect)` tuples; no role-key enumeration. Therefore the proxy already correctly enforces the v2 catalog the moment `202605150000` is applied — **no resolver change needed; none ever was.** Mobile resolver = same file = v2-correct automatically.

What is NOT v2-correct (the real G7 surface):
1. **`lib/auth/permission_keys.dart` role constants are still v1-shaped (6 roles)** — the 7 v2 roles have no constants; soft-deleted v1 strings still present. **Load-bearing prerequisite (G7-pre).**
2. **Per-surface role-string divergence** (admin copy-paste; operator-web phantom + inflation).
3. **`lib/services/team/team_scope_visibility_policy.dart:71`** gates Team nav on soft-deleted `'operator_manager'` ⇒ GMs lose Team nav post-v2. **Latent behavior regression — fix in G7d-mobile (operator-approved).**

Net: G7 is predominantly behavior-preserving client cleanup, but the framing inverts: the **catalog constants are the stale thing to refresh to v2**, not the convergence target. Proxy resolver is ground truth and already v2-correct.

## operator_admin / location_manager (re-confirmed on master)
- **`operator_admin`** — phantom. Fold into `operator_owner`; do NOT seed; do NOT map.
- **`location_manager`** — **REAL seeded v2 role** (`202605150000...v2.sql:298-304`). Keep its live-path usages; treat as first-class v2 role. (Biggest correction vs the stale spec, which wrongly lumped it as a phantom.)

## 1. Authoritative model
- Ground truth: proxy `PermissionResolver` over DB roles, post-`202605150000` = v2. Role-agnostic; no change.
- Admin client `roles.contains('super_admin')` (17 sites) = UI affordance; proxy re-checks ⇒ G8 = maintainability smell, not a hole.
- `permission_keys.dart` catalog is stale (v1 role constants) → G7-pre.
- `roleLabels` live provenance: `users_repository.dart:366,458` selects `roles.display_name` (NOT `role_key`). Post-v2 live labels = v2 display names (`'Owner'`,`'General Manager'`,`'Location Manager'`,`'Supervisor'`,`'Finance Analyst'`,`'Auditor / Compliance'`,`'Training Lead'`,`'Team Admin'`). Operator confirms no raw v1 key labels arrive live ⇒ re-base `_inferRoles` on v2 display names only.

## 2. Per-surface divergence vs v2 (re-derive line numbers by pattern — drift expected)

### 2.A Admin (`lib/admin/`)
- `admin_routes.dart` — **17** copy-pasted `session.roles.contains('super_admin')` sites (was 15; drifted): ~693, 807, 1002, 1059, 1104, 1186, 1259, 1304, 1375, 1449, 1510, 1636, 1865, 1956, 2191, 2319, 2529.
- `admin_auth_gate.dart:53` `kAdminConsoleRoles = {'super_admin','ff_support'}`; consumed `:92,:1345`, `admin_shell.dart:458,462-463`; fixtures `:217,231,262,268,324`. Claims map `:663-664`. Admin only ever uses the 2 carry-over roles — v2 changes NO admin behavior; pure literal→constant hygiene.

### 2.B Operator-web (`lib/operator_web/`)
- **G30 SHIPPED (#859):** `firebase_operator_web_auth_source.dart` `_inferRoles`/`_hasConsoleAccess` use `PermissionKeys.integrationsConfigure/teamUsersView/adminUsersView/forgeflowSettingsView`. No bare permission-key literals remain.
- `_inferRoles` still: synthesizes phantom `'operator_admin'` from `*_admin` labels; synthesizes `'location_manager'` (now a real role — keep, make a constant); `'operator_owner'`; soft-deleted `'operator_manager'`; **`integrations.configure → operator_owner` inflation** (remove in G7d, behavior-neutral live); empty-roles fallback ⇒ soft-deleted `'operator_manager'`.
- ~16 admit/write role sets across `operator_web_auth_source.dart:291-296` (`kOperatorWebAdmittedRoles`) + screens (account/audit_log/business_setup/business_timing_editor/data_accuracy/hierarchy/members/my_account/roles/schedule/sessions/vendor_connections/wage_authority) + `web_app_shell.dart` pill — all bare literals; several still carry dead soft-deleted v1 `operator_supervisor/operator_staff/operator_manager` branches.
- Demo: `kDemoOperatorWebLocationManagerSession` emits `['location_manager']` — correct v2, keep. `demo_team_fixtures.dart` mixes v2 + soft-deleted v1 keys (Q5).

### 2.C Mobile / services
- `permission_resolution.dart` — role-agnostic, v2-correct, no change.
- **`team_scope_visibility_policy.dart:71`** — `canSeeTeamNav` requires `actorRoles.contains('operator_manager')` (soft-deleted, auto-migrated to `operator_general_manager`). Post-v2 no live actor carries it ⇒ GMs lose the Team-nav entrypoint. **Behavior regression; G7d-mobile FIX (operator-approved).** Also audit `notification_event_catalog.dart:36` local `roleOperatorManager` const consumers.

## 3. v1→v2 mapping
`operator_owner/super_admin/ff_support` = carry-over. `operator_manager → operator_general_manager`. `operator_supervisor → supervisor`. `operator_staff → supervisor`. `operator_admin (phantom) → operator_owner` (fold). `location_manager → location_manager` (REAL v2 role, keep). New v2 with no v1 antecedent: `finance_analyst, auditor_compliance, training_lead, team_admin` (add constants; add to admit sets per intent). Operator confirms live labels are v2 display names ⇒ re-base `_inferRoles` on display names; no v1-key translation table needed.

## 4. Phased plan (v2-rebased)
Merge order: **G7-pre → G7a → G7b → G7c (parallel, operator-gated) → G7d (incl. G7d-mobile).** (G30 shipped — dropped from sequence.)

- **G7-pre — catalog-constant v2 refresh (PREREQUISITE; auth-critical, operator-approval-gated).** `permission_keys.dart`: add `roleOperatorGeneralManager/roleLocationManager/roleSupervisor/roleFinanceAnalyst/roleAuditorCompliance/roleTrainingLead/roleTeamAdmin`; mark `roleOperatorManager/Supervisor/Staff` `@Deprecated('Soft-deleted R-2L v2; maps to <v2>; migration-history only')` (KEEP — operator decision); redefine `baselineRoleKeys` = the 10 v2 keys (soft-deleted excluded); audit `baselineRoleKeys` consumers first. Additive; inert until consumers adopt. Tests: each new constant == migration `role_key`; `baselineRoleKeys` == 10 v2; extend migration⊇`PermissionKeys` harness.
- **G7a — shared admin super_admin helper (behavior-preserving).** `_isAdminSuperAdmin(session)` → replace the 17 copy-pasted `admin_routes.dart` sites + `kAdminConsoleRoles`/fixtures → `PermissionKeys.roleSuperAdmin/roleFfSupport`. Byte-identical. Grep-guard no bare `'super_admin'` in `lib/admin/`.
- **G7b — admin consumes catalog constants.** `kAdminConsoleRoles`, `admin_shell` switch, claims map → `PermissionKeys.role*`. No `PermissionResolver` threading into admin client (deferred; proxy enforces). Behavior-preserving.
- **G7c — CONTRACT-TOUCHING doc reconciliation (operator-APPROVED, doc-only).** `docs/contracts/auth_permission_key_catalog.md`: strike `operator_admin "(when seeded)"` (~:208,241,257,303-304 — re-derive), fold into `operator_owner` prose; rewrite v1→v2 role names (~:67,211-219,341-343) per the migration + `WAVE_2_R2L_DEFAULT_ROLE_CATALOG_V2_PROPOSAL.md`; mark v1 names retired. (Prior spec's `operator_web_auth_source.dart:356-359` stale-comment fix is VOID — drift; that range is now MFA-challenge code.) Parallel with G7a/G7b.
- **G7d — operator-web fallback sets → v2 constants + drop phantom + remove inflation + mobile fix.**
  - G7d-i (operator-web): delete `'operator_admin'` synthesis; remove `integrations.configure→operator_owner` inflation; re-base `_inferRoles` label normalization on v2 **display names** emitting `PermissionKeys.role*` v2 constants; keep `location_manager` (`roleLocationManager`); map dead soft-deleted v1 branches to v2 constants per §3 (map, don't drop, for migration-window robustness); shell pill v1→v2; demo location-manager session unchanged. Live-path neutral; demo/boot fail-closed tightening for the `operator_admin` collision (operator-accepted).
  - **G7d-mobile (operator-approved FIX):** `team_scope_visibility_policy.dart:71` → use `PermissionKeys.roleOperatorGeneralManager` (+ keep `operator_owner`/`_isAdminTier`). Behavior FIX (restores GM Team nav post-v2) — flag in PR as behavior-changing. Audit `notification_event_catalog.dart:36` consumers same slice.

## 5. Risk / oracle
- Behavior-preserving: G7a, G7b, G7d-i live-path.
- Behavior-changing (intended): G7-pre (additive constants + `baselineRoleKeys`), G7d-i demo/boot fail-closed (accepted), **G7d-mobile (GM Team-nav FIX)**.
- Contract-touching: G7c (operator-approved, doc-only). Auth-critical/operator-gated: G7-pre (`lib/auth/`), G7c (`docs/contracts/`).
- `7.58`-adjacent: none (seeding `operator_admin` rejected).
- Oracle: proxy `PermissionResolver` over the 10 v2 roles. Tests: constant==migration role_key; `baselineRoleKeys`==10; cross-surface admit-set parity vs v2 matrix; operator_admin-removal fallback/demo tests; **regression test: a GM (`operator_general_manager`, holds `team.users.view`, ≥1 location) passes `TeamScopeVisibilityPolicy.canSeeTeamNav`** (currently fails — proves G7d-mobile); no-bare-role-literal grep-guard scoped to `lib/admin/`+`lib/operator_web/`.
- Sequencing: G7-pre tiny/isolated (`permission_keys.dart` only) — low collision risk vs the Per-Daypart V1 wave. G7a/G7d touch large files — always re-derive sites by pattern.

## 6. Open questions — RESOLVED 2026-05-16 (see Operator Decisions block above)
All six prior open questions are resolved by the binding Operator Decisions block: (1) operator_admin fold + fail-closed accepted; (2) G7c approved; (3) no live v1-key labels; (4) keep deprecated v1 constants; (5) fold read-path fixture cleanup into G7d; (6) G7d-mobile in scope.

**Files cited (relative):** `db/migrations/202605150000_phase_r2l_default_role_catalog_v2.sql`; `lib/auth/permission_keys.dart` (G7-pre); `lib/auth/permission_resolution.dart` (no change); `lib/operator_web/auth/firebase_operator_web_auth_source.dart` (G30 done; phantom/inflation = G7d); `lib/operator_web/auth/operator_web_auth_source.dart`; `lib/admin/admin_routes.dart` (G7a); `lib/admin/admin_auth_gate.dart`; `lib/services/team/team_scope_visibility_policy.dart` (G7d-mobile FIX); `docs/contracts/auth_permission_key_catalog.md` (G7c); `lib/operator_web/services/demo_team_fixtures.dart` (Q5); operator-web screen admit-set files per §2.B.

**Key corrections vs the prior stale spec:** (1) authoritative model is the v2 catalog, not a frozen 6-role; (2) `permission_keys.dart` constants are the stale thing to refresh, not the convergence target; (3) `location_manager` is a REAL v2 role to keep, not a phantom; (4) G30 SHIPPED (#859); (5) NEW finding: `team_scope_visibility_policy.dart:71` GM Team-nav regression (fix approved); (6) 17 (not 15) admin super_admin sites; (7) the prior `:356-359` stale-comment fix is void (drift).

Source: G7 v2 re-spec investigation 2026-05-16 (orchestrator-persisted; delegation not possible — text orchestrator-only).
