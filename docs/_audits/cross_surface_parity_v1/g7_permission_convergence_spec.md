# Spec — Permission Enforcement Convergence (G7 / G30 / G8 / G9 / G31 / G32)

> **STATUS 2026-05-16 — §0 HEADLINE IS INVALID (see register §0).** This spec reasoned off the **stale v1 seed (6 roles)**. The real current model is the **v2 default role catalog, 10 roles** (`db/migrations/202605150000_phase_r2l_default_role_catalog_v2.sql` — incl. `location_manager`, `team_admin`, `operator_general_manager`; `operator_admin` is NOT a role key). The "web-console roles are phantom fallbacks / catalog is authoritative-as-is" conclusion in §0 is **wrong**. **G7 must be RE-SPEC'd against the v2 catalog** before any G7 work. The **§3 G30** slice (bare permission-string → `PermissionKeys` constant aliasing) is **still valid, behavior-preserving, and safe** — it is unaffected by the v1/v2 role distinction (keys, not roles). Everything else here is PARKED pending re-spec.

## operator_admin VERDICT — resolved 2026-05-16 (independent trace)

`operator_admin` is a **phantom**: never seeded in v1 or v2; only the F&F-grant `operator_admins` *table* shares the name (unrelated — ignore). Sole producer is `_inferRoles` (`firebase_operator_web_auth_source.dart:732-735`) synthesizing it from free-text role labels; every consumer is a **fallback-only** admit/write set (read only when `session.permissions.isEmpty`). Live path always hydrates the permission snapshot ⇒ `PermissionKeys.*` per-screen gates win ⇒ synthesized `operator_admin` is **never read on a real decision**. No demo session produces it either.

**Decision:** fold into **`operator_owner`** (catalog intent always bundled them for the same surfaces — `auth_permission_key_catalog.md:208-210,242,258,304`, all hedged "(when seeded)"). Do **not** map to a v2 role; do **not** seed a 7th role. → G7c (doc-only, strike the "(when seeded)" clauses + fix stale `operator_web_auth_source.dart:356-359` comment) + G7d (delete `'operator_admin'` from `_inferRoles` synthesis + all ~16 fallback sets + the `web_app_shell.dart:536` pill).

**Prerequisite for G7d (newly surfaced):** `lib/auth/permission_keys.dart:379-394` role constants are still **v1-shaped (6 roles)** — `roleTeamAdmin`/`roleOperatorGeneralManager`/etc. do NOT exist. Refreshing that constant block to the v2 catalog is a **co-requisite** of G7d (can't replace bare strings with constants that don't exist yet).

**One operator confirm needed:** the only behavior change is demo/boot-window (empty snapshot): a `team_admin` user (whose display name "Team Admin" accidentally collides → currently synthesized to `operator_admin` ⇒ full owner-tier fallback) would, after removal, get **nothing until the real snapshot hydrates** (fail-closed tightening; zero live impact). Recommended: accept (fail-closed is safer; live path unaffected).

**Date:** 2026-05-16 · Read-only investigation · Auth-critical; §G7c is CONTRACT-TOUCHING (operator-gated).

## 0. Headline — the operator steer is partially REFUTED by proxy ground truth

Operator steer was: "web consoles are more recent/current; frozen catalog/mobile resolver may be stale; converge toward the web-console model, possibly updating the frozen catalog."

**Proxy ground truth disagrees.** The proxy server enforcement (`RepositoryProxyAdminPermissionGuard` + `RepositoryProxyPermissionSnapshotResolver`, `proxy_bootstrap.dart:9019,9052-9129`) runs `PermissionResolver` (`lib/auth/permission_resolution.dart:109-256`) over DB `user_roles ⋈ role_permissions`. The DB seeds **exactly 6 baseline roles** (`202604250008_auth_schema_foundation.sql:916-1075`): `super_admin, ff_support, operator_owner, operator_manager, operator_supervisor, operator_staff`. There is **no `operator_admin`, no `location_manager`** role row. `forge_admin` is a Postgres BYPASSRLS role, not an app role.

Therefore:
- The **frozen `PermissionKeys` catalog + proxy resolver + mobile resolver are the genuinely-current authoritative model** (all three share `lib/auth/permission_resolution.dart`; byte-consistent with the DB seed).
- The web-console `operator_admin`/`location_manager` strings are **phantom UI-side fallback heuristics**, only active when the server permission snapshot is empty (demo/boot). When the live snapshot is hydrated, the per-screen `PermissionKeys.*` gates (already catalog-aliased) are authoritative.
- The mobile resolver is **not stale** — same file as the proxy.

**Net:** G7 is overwhelmingly **behavior-preserving client cleanup, NOT a model migration.** The catalog should NOT be changed to match the web consoles — that would be the wrong direction. Operator must confirm this reframing (§6 Q3).

## 1. Authoritative model
Proxy guard is ground truth for every mutating call on every surface (HP #7). Admin client `roles.contains('super_admin')` is a UI affordance only — proxy re-checks server-side ⇒ G8 is a maintainability smell, not a security hole. Catalog (`permission_keys.dart`) already defines every needed key + the 6 `role*` constants + `baselineRoleKeys:379-394`. **No model/`lib/auth/**` change required for convergence.**

## 2. G30 — do-now slice (behavior-preserving)
File `lib/operator_web/auth/firebase_operator_web_auth_source.dart`. Replace bare strings with catalog constants (all textually equal today):
| Bare string | Sites | Replace with |
|---|---|---|
| `'integrations.configure'` | :746,:755,:770 | `PermissionKeys.integrationsConfigure` |
| `'team.users.view'` | :752,:767 | `PermissionKeys.teamUsersView` |
| `'admin.users.view'` | :753,:768 | `PermissionKeys.adminUsersView` |
| `'forgeflow.settings.view'` | :754,:769 | `PermissionKeys.forgeflowSettingsView` |
OUT of G30 scope (defer to G7d): removing phantom `operator_admin`/`location_manager` and the `integrations.configure→operator_owner` inflation (`:747`) — those change fallback-set contents (behavioral in demo/boot window). Tests: constant-equality assertions + grep-guard for bare literals. Ships AFTER Fix #1 merges (same file; rebase, line numbers will drift).

## 3. G7 phases
- **G7a** — shared admin helper `_isAdminSuperAdmin(session) ⇒ session.roles.contains(PermissionKeys.roleSuperAdmin)`; replace the 15 copy-pasted sites in `admin_routes.dart` (lines 689,998,1055,1100,1182,1234-1235,1255,1300,1371,1445,1506,1632,1861,2169,2478 — re-derive by pattern post-Fix#2). Byte-identical decisions. Ships AFTER Fix #2 merges.
- **G7b** — `kAdminConsoleRoles` & admin fixtures use `PermissionKeys.role*` constants. Do NOT thread `PermissionResolver` into the admin client (larger, deferred; proxy already enforces).
- **G7c** — CONTRACT-TOUCHING, operator-gated, doc-only: strike `operator_admin` "(when seeded)" clauses in `docs/contracts/auth_permission_key_catalog.md:209,242,258,304` (recommended: fold into `operator_owner`, do NOT seed a 7th role); fix stale comment `operator_web_auth_source.dart:356-359` to include `operator_manager`.
- **G7d** — operator-web fallback sets → `PermissionKeys.role*` constants, drop phantom `operator_admin`/`location_manager`, remove permission→role inflation/synthesis (`:747,:749-759`). Behavior-neutral in live path; fail-closed-tightening in fallback. After G30.

Merge order: **Fix #1 → G30 → Fix #2 → G7a → G7b → G7c (parallel, operator-gated) → G7d.**

## 4. Risk
Behavior-preserving: G30/G7a/G7b/G7d-live-path. CONTRACT-TOUCHING: G7c (operator approval, doc-only). `7.58`-adjacent: ONLY the NOT-recommended option of actually seeding `operator_admin` as a 7th role (rejected). Oracle: proxy `PermissionResolver` over the 6 seeded roles; constant-equality + cross-surface parity + fallback tests; extend the existing migration⊇`PermissionKeys.all` test harness with a no-bare-literal grep-guard.

## 5. Open questions for the operator
1. `operator_admin` real? Recommend strike refs (doc-only G7c), fold into `operator_owner`; or seed 7th role (NOT recommended, schema/`7.58`-adjacent)?
2. `location_manager` real? Recommend drop from fallback sets; confirm no live IdP/account source emits that label.
3. **Confirm the §0 reframing**: frozen catalog + proxy resolver remain authoritative; web-console role strings are phantom fallbacks, not a newer model to migrate toward.
4. Approve the contract-frozen doc edit (G7c)?
5. Does any live account/IdP source emit free-text `roleLabels` ("admin"/"manager"/"owner") that `_inferRoles:722-744` must keep mapping? If no → G7d-i safe; if yes → need a label→catalog-role table.
6. Mobile gaining web-console roles: none required (mobile already shares the authoritative resolver).

Source agent (read-only, resumable): `a4cfc26781d37abad`.
