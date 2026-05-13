# PR #609 Audit — B2.4 catalog_published_at Projection

**Slice:** B2.4 (Lane B — closes B2.2 Gap 2; ledger row 73)
**Owner:** Claude lane parallel executor
**Branch:** `claude/b2-4-catalog-published-at-projection`
**Base:** `master` @ `0a6311cb`
**Gate:** `auto` per ledger row 73 — pre-reconciled (operator-web read-only surface)
**Risk:** **Low** — additive LEFT JOIN + 2 nullable response keys; no migration; no auth/RLS/permission-key touch
**Size:** 993 additions / 37 deletions / 10 files (light variant audit — <20 files, <5K LoC)

## Verdict

**approve-for-merge** — auto-merging per operator's 2026-05-13 break-time expanded delegation. Pattern B exemplary (worker 14L + executor 14L with file:line citations and 3 executor-only lenses on B2.1 grant compatibility / multi-row JOIN safety / honest-gap discipline). Closes the second of two honest gaps disclosed by the B2.2 worker; mirrors B2.3 (PR #603) shape exactly — both Gap 1 (numeric counts) and Gap 2 (per-row date annotation) now closed.

## Pattern B compliance

**✓ EXEMPLARY** — both 14-lens tables present in PR body with file:line citations; executor adds 3 executor-only lenses (EXEC+1 B2.1 grant compatibility, EXEC+2 multi-row LEFT JOIN safety, EXEC+3 honest-gap discipline).

## What landed

- **Repository** (`roles_repository.dart`, +68 / -8) — `listVisibleRoles` extended with two LEFT JOINs (`public.operators` for pinned-version pointer + `public.default_role_catalog_versions` for metadata). Both joins gate on `r.is_seeded = true` so custom rows never inherit catalog metadata. Resolution rule mirrors existing `resolveDefaultRoleCatalogPayload` (pinned → unpinned `is_current = true` → genesis NULL).
- **Domain models** (`roles_screen.dart`, `web_team_roles_gateway.dart`, `auth_operations_gateway.dart`, `repository_auth_operations_gateway.dart`) — `RoleRecord`, `TeamRoleCatalogEntry`, `RoleEntry`, `_roleEntry` each gain two nullable fields (`catalogVersionId`, `catalogPublishedAt`).
- **Proxy** (`advisor_proxy.dart`, +7) — `_teamRoleToJson` adds 2 nullable response keys. Response-shape only; mobile + legacy clients tolerate the additive shape.
- **UI** (`roles_screen.dart`, +54 / -12) — seeded-row annotation calls new pure helper `defaultAnnotationCopyForCatalogPublishedAt(publishedAt)`. Non-null `DateTime` → "Updated by F&F on Mon D, YYYY"; null → fallback verbatim "Managed by Forge & Flow".
- **Defensive parsing** (`web_team_roles_gateway.dart`) — `_roleFromJson` surfaces `malformed_response` envelope on ISO-8601 parse failure.
- **Tests** (+792 LoC across 4 files) — 5 repo cases + 5 gateway cases + 3 screen cases + 1 regression pin updated; 31/31 pass; 57-test sweep across 7 touched files: 0 new failures.

## Critical safety guarantees (executor-verified)

| Guarantee | File:line | Verification |
|---|---|---|
| No migration | diff scope | Zero `db/migrations/**` files in `gh pr view --json files` — ledger row 73 explicitly says "no migration expected" |
| No new permission key | diff scope | Zero `lib/auth/**` files in diff — read path piggybacks on existing `team.roles.view` gate |
| No new RLS policy | diff scope | Zero `CREATE POLICY` in diff; catalog table is F&F-global with no RLS; `service_role` SELECT grant exists from B2.1 migration so cross-table read is admissible under tenant transaction |
| LEFT JOIN runs inside existing tenant transaction | `roles_repository.dart` extension | New SQL routes through `withTenant` — `app_current_operator()` wrapper still applies |
| Custom rows project NULL for both fields | `roles_repository.dart` JOIN clauses | Both LEFT JOINs gate on `r.is_seeded = true` — verified by worker + executor |
| Multi-row JOIN safety | B2.1 schema | Partial UNIQUE INDEX on `default_role_catalog_versions (is_current) WHERE is_current = true` from B2.1 guarantees at most one row matches unpinned-branch; pinned-branch is single-row by PK. No row-duplication risk |
| `_projectRow` tolerates missing keys | `roles_repository.dart` | Nullable casts (`row['catalog_version_id'] as String?`) — callsites using pre-B2.4 SELECT (e.g. `visibleRoleById`) still work, project NULL |
| Response shape additive | `advisor_proxy.dart:_teamRoleToJson` | +7 LoC — 5-line comment block + 2 new nullable JSON keys. Mobile + legacy clients tolerate |
| Bleed-stop lint clean | size lint | 19,805 → 19,812 (headroom 88) |
| Frozen `lib/auth/**` untouched | diff scope | Zero changes under `lib/auth/` |
| No `audit_logs` writes | diff scope | All new SQL is read-only LEFT JOIN; `audit_logs_update_lint` clean |
| Defensive ISO-8601 parsing | `web_team_roles_gateway.dart._roleFromJson` | `malformed_response` envelope surfaces parse failures with typed error code |
| Date format matches existing pattern | `defaultAnnotationCopyForCatalogPublishedAt` helper | "Mon D, YYYY" matches `audit_log_row.dart` pattern |

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master @ `0a6311cb` | ✓ — `baseRefOid` confirms; MERGEABLE CLEAN |
| Pattern B both tables present + 3 executor-only lenses | ✓ — worker 14L + executor 14L + 3 EXEC+ lenses |
| Pre-reconciled auto-gate posture | ✓ — ledger row 73 column says "Auto-gate (operator-web read-only surface)"; PR title has NO `[operator-approval-required]` prefix |
| Closes B2.2 Gap 2 | ✓ — B2.2 worker disclosed 2 gaps; B2.3 (PR #603) closed Gap 1 (numeric counts); B2.4 closes Gap 2 (date annotation) |
| 31/31 new tests pass | ✓ disclosed |
| 57-test regression sweep clean | ✓ disclosed |
| `dart analyze --fatal-infos` clean | ✓ disclosed |
| `postgres_import_lint` clean | ✓ disclosed |
| `audit_logs_update_lint` clean | ✓ disclosed |
| Bleed-stop lint clean | ✓ — 19,812 / 19,900 (headroom 88) |
| No tracker / ledger / lane-index touches | ✓ — diff scope confirms |
| No `--no-verify` traces | ✓ |
| No Codex-owned conflict | ✓ — Claude lane B2.x territory |

## Pattern B compliance

**✓ EXEMPLARY** — both 14-lens tables present with file:line citations; executor adds 3 executor-only lenses.

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied to staging/Production1 | ❌ — no migration |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — ledger row 73 says B2.4 auto-gate operator-web read-only surface; matches PR scope exactly |
| Worker disclosure operator should know | ❌ — clean; honest-gap discipline (closes B2.2 Gap 2 disclosed in #590) |
| Stacked PR | ❌ — base is master |

**Decision**: per expanded policy. Pure additive read-only projection; same operator-gate posture as B2.3 closing Gap 1; honest-gap discipline exemplary.

## Cross-lane notes

- **Closes B2.2 Gap 2** — disclosed by B2.2 worker (PR #590), pattern mirrors B2.3 (Gap 1) closure exactly
- **`advisor_proxy.dart` +7 LoC** is pre-reconciled to auto-gate by ledger row 73 (operator-web read-only surface; response-shape only)
- **No interaction with parallel L_A1 (#608)** — disjoint surfaces; L_A1 touches `lib/widgets/`, `lib/domain/models/`, `lib/infrastructure/persistence/postgres/repositories/org_units_repository.dart`; B2.4 touches roles repository + UI + gateway
- **No Codex-owned files touched**

## Findings

None. All checks green; honest-gap discipline closes the second of B2.2's two disclosed gaps.

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 73 — B2.4 ledger row (auto-gate operator-web read-only)
- PR #590 (B2.2) — gap disclosure source
- PR #603 (B2.3) — Gap 1 closure precedent (numeric counts)
- `db/migrations/202605131600_b2_1_default_role_catalog_versions.sql` — schema + grants this projection consumes
- CLAUDE.md "RLS-Ready Schema" — tenant-context read on F&F-global catalog table
- `project_ux_writing_standard.md` — plain English in annotation copy

## Status

**Auto-merging** per operator's 2026-05-13 break-time expanded delegation. B2.2 Gap 1 + Gap 2 both closed; B2.x slice family complete pending B2.5 if any.
