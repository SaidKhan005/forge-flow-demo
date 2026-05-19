## RISK FLAG — SCHEMA-TOUCHING (operator approval required before merge)

Per CLAUDE.md, schema-touching slices require **explicit operator approval before merge regardless of audit verdict**. The orchestrator must NOT auto-merge this.

- **Migration file:** `db/migrations/202605161800_gap_b2_wage_role_rows_hierarchy_scope.sql`
- **Columns added (ADDITIVE `ALTER TABLE public.wage_role_rows`):** `scope_type text NOT NULL DEFAULT 'location'`, `org_unit_id uuid NULL`, `inherited_from_scope_id uuid NULL`. Plus: `wage_role_rows_scope_type_ck`, `wage_role_rows_scope_payload_ck`, `wage_role_rows_org_unit_fk` (composite FK to `org_units(operator_id, id)`), `wage_role_rows_operator_scope_idx` (operator_id-leading).
- **RLS policy change:** `wage_role_rows_per_tenant` relaxed from `operator AND location` to `operator-only` — mirrors the operator-endorsed `benchmark_overrides` posture exactly (operator_wide/org_unit rows have NULL location_id and must be visible to the owner/admin inheritance editor; location authority stays enforced at the proxy by `operator_owner`/`operator_admin`). HP #4 per-operator isolation preserved (still `app_current_operator()`).
- **Proxy route changed:** NO. The proxy reads body fields by name and does not strict-reject unknown keys (verified `tool/advisor_proxy/wage_role_rows_routes.dart`); the server repo INSERT omits the new columns so they take the DB default `scope_type='location'`. Existing proxy/mobile writes are byte-unchanged and stay Location-scoped. The hierarchy-aware proxy read/write (persisting + returning the new columns) is the documented out-of-scope follow-up.

## What this closes

GAP B2 — Web Wage Authority was hardcoded to Location scope (`wage_authority_screen.dart` rendered a screen-level `HierarchyScopeNotice` with `selectedScope=location`, `inheritedFromLabel=null`, "Region/brand wage floors coming in a later wave"). Root cause: `wage_role_rows` carried only `(operator_id, location_id)`. This ships the wage slice of HP #11 per-field inheritance (`wage_role_rows` ONLY; the other 4 HP #11 tables are the broader B1 follow-up).

## Salvage check (done first)

`gh pr list --state all --limit 80` + `git branch -a` + grep. PR #659 (`claude/wave-2-h-1-hp-11-schedule-wage-authority`, MERGED) shipped the screen-level notice this slice replaces — it did NOT add scope columns. PR #813 (Demo Slice F, MERGED) is a demo-DATA slice that explicitly states the wage inherited-source pill / resolver is "Gap 32 gated UI ... feature work outside a demo-DATA slice" — not covered. PR #679 is the blended-mix formula UI (unrelated). Confirmed `202605080200_phase_8_wage_role_rows_server_truth.sql` carries no scope columns. Genuinely not covered, proceeded.

## Approach

- Resolver `lib/services/wage/wage_role_row_scope_resolver.dart` mirrors `BenchmarkOverrideResolver` exactly (same class shape, same order: location, nearest-first org-unit ancestors, operator-wide, fallback; returns value + sourceScopeType + sourceLabel + inherited).
- Gateway projects scope through `WageRoleRowUpsert.toJson` (always sends `scope_type`; legacy proxy ignores it) + a `listEffective` extension (not an interface member, so every impl gets it free without reimplementation) backed by pure `resolveEffectiveWageRows`. Demo gateway round-trips scope on upsert/delete.
- Domain model `WageRoleRowRecord` gains `scopeType` (default `'location'`), `orgUnitId`, `inheritedFromScopeId`; `fromRow`/`toJson` carry them; absent columns default to Location (legacy-safe).
- Screen replaces the hardcoded notice with `_ScopeEditorBar` (reuses the existing `HierarchyTreePicker` — no new picker invented) + per-row `_ScopeBadge` ("Set at this location" / "Inherited from the whole business" / "Inherited from <org unit>"). With no hierarchy supplied it degrades to a plain Location notice (no regression; the misleading "coming in a later wave" copy is gone). Reuses `inheritance_descendant_cache.dart` ancestry via the caller-supplied `ancestorOrgUnitIdsNearestFirst` (traversal not re-implemented).

## Local verification (CI dark — disclosed)

- `powershell scripts/install_git_hooks.ps1` -> hooks enabled (step 0).
- `dart tool/migration_drift_scanner.dart --fix --strict-docs` -> exit 0 (after factual migration-ledger references added to `POST_HARDENING_FOLLOWUPS.md`, `phase_9_execution_backlog.md`, `phase_11A_operations_console_plan.md`, the apply runbook + `--fix` script-cutoff bump; `PROJECT_TRACKER.md` intentionally untouched — it carries no migration refs, status `noMigrationReferences`, not stale).
- `dart tool/migration_cutoff_lint.dart` -> clean, runbook cutoff is current.
- `dart tool/index_leading_column_lint.dart` -> clean (scope index leads with operator_id).
- `dart tool/rls_policy_lint.dart` -> clean (policy uses `app_current_operator()` wrapper).
- `dart tool/postgres_import_lint.dart` -> clean.
- `dart analyze lib/` -> 0 errors, 0 warnings (16 pre-existing info lints in untouched files; none in wage files). operator_web touched files: no `dart:io`/`sqflite`.
- `flutter test` resolver(8) + gateway/projection(10) + screen scope(3) + existing wage_authority_screen(25, incl. 1 rewritten) + http gateway + 4 server-side wage suites (repo/proxy/migration smoke, 30) -> all passed.

## Pattern B audit

**Worker self-audit**

| # | Claim | Evidence (file:line) | Verdict |
|---|---|---|---|
| 1 | Migration is additive + mirrors benchmark_overrides | `db/migrations/202605161800_gap_b2_wage_role_rows_hierarchy_scope.sql:62-130` (scope_type default 'location', payload CHECK 1:1 with `202605131550...:32-45`, composite FK :110-117, operator-leading index :120-129) | PASS |
| 2 | RLS relaxation = benchmark_overrides posture, HP #4 intact | `...hierarchy_scope.sql:139-160` vs `202605131550_benchmark_overrides_hierarchy.sql:96-112` (both `operator_id = public.app_current_operator()`) | PASS |
| 3 | Resolver mirrors BenchmarkOverrideResolver shape/order | `lib/services/wage/wage_role_row_scope_resolver.dart:200-260` vs `lib/services/baseline/benchmark_override_resolver.dart:11-72` (location->ancestors->operatorWide->fallback, latest-effective tiebreak) | PASS |
| 4 | No proxy route changed; legacy writes stay Location-scoped | `tool/advisor_proxy/wage_role_rows_routes.dart:481-520` (reads by name, no strict-reject); `lib/infrastructure/persistence/postgres/repositories/wage_role_rows_repository.dart:34-45,81-110` (INSERT omits new cols, DB default) | PASS |
| 5 | Screen replaces hardcoded notice w/ selector + per-row badges | `lib/operator_web/screens/wage_authority_screen.dart:582-601` (`_ScopeEditorBar`), `:973-1001` (`_ScopeBadge`), widgets reuse `HierarchyTreePicker` | PASS |
| 6 | No regression with no hierarchy (degrades to Location) | `wage_authority_screen.dart` `_ScopeEditorBar` (`hierarchyNodes.length < 2` -> location-only notice); rewritten case in `test/operator_web/screens/wage_authority_screen_test.dart` | PASS |
| 7 | Backward-compatible domain model | `lib/domain/models/wage_role_row_record.dart:93-96,164-189` (`scopeType` default 'location', absent cols -> default); `..._gateway_effective_test.dart` fromRow-default case | PASS |
| 8 | No NUL bytes / binary artifacts | `git diff --cached --numstat` (no `-`/Bin); perl `\0` scan all 14 files = clean (one stray NUL found in gateway key + fixed pre-commit) | PASS |
| 9 | Tests prove inherited vs set-at-scope rendering | `test/operator_web/screens/wage_authority_scope_test.dart` (3: inherited-Business badge, set-at-location badge, no-hierarchy degrade) | PASS |
| 10 | Migration guardrails green; trackers respected | scanner+cutoff exit 0; only factual migration-ledger refs added; `PROJECT_TRACKER.md` untouched | PASS |

**Independent re-audit pass**

| # | Re-check | Evidence (file:line) | Verdict |
|---|---|---|---|
| R1 | scope_payload CHECK byte-equivalent to exemplar | `...hierarchy_scope.sql:82-98` vs `202605131550...:32-45` — same 3-branch logic | PASS |
| R2 | Resolver `inherited` semantics match benchmark | `wage_role_row_scope_resolver.dart:121-128` (`inherited = scopeType != location`) equiv `benchmark_override_resolver.dart:180` | PASS |
| R3 | `listEffective` extension doesn't break `implements` impls | `operator_web_wage_authority_gateway.dart:283-308` (extension, not interface member); `dart analyze` 0 errors; existing test `_FakeGateway` compiles + passes | PASS |
| R4 | Screen key (space) vs gateway internal dedup key (pipe) — independent keyspaces | `wage_authority_screen.dart` (`'<bucket> <role>'` both build+lookup); gateway `:123` (`'<bucket>|<role>'` internal-only Set) | PASS |
| R5 | Org-unit node id prefix stripped before column write | `wage_authority_screen.dart` `_ScopeEditorBar.onSelected` (`org_unit:` stripped -> `wage_role_rows.org_unit_id`) | PASS |
| R6 | Server-side wage tests unaffected (assert original 202605080200 text) | `flutter test` 4 suites (30 tests) green; original migration file unmodified | PASS |
| R7 | RLS relaxation safe: repo still SQL-clamps location_id | `wage_role_rows_repository.dart:81-163` (`location_id = @location_id` in INSERT conflict + DELETE WHERE) — primary defense intact, RLS backup | PASS |
| R8 | UX copy plain-English / trains operator | `_ScopeEditorBar`/`_ScopeBadge` strings (no scope_id/jargon) | PASS |

## Open questions for orchestrator (documented, not guessed)

1. Hierarchy-aware proxy read/write is the explicit out-of-scope follow-up: the proxy currently ignores `scope_type`/`org_unit_id` on write and the server repo doesn't SELECT/return them. Until that lands, a Business-scoped wage saved via the live proxy persists as Location-scoped (DB default). The demo gateway round-trips scope fully (walkthrough-correct). Recommend sequencing the proxy slice next.
2. B1 broader follow-up: the other 4 HP #11 tables still lack per-field inheritance — unchanged by this slice, noted as the broader B1 item.
3. Does Business-scope wage need an audited reason / corp-root behavior? Left to product — the resolver + schema support it; the editor writes at the selected scope without a reason prompt (parity with the existing wage editor, which has none). Flagged rather than guessed.

`Links updated: yes` — factual migration-ledger references only (`POST_HARDENING_FOLLOWUPS.md`, `phase_9_execution_backlog.md`, `phase_11A_operations_console_plan.md`, apply runbook) + tooling `--fix` script-cutoff bump. No status/scope/decision edits. `PROJECT_TRACKER.md` untouched. These doc touches were required to pass the mandatory pre-commit migration guardrail (`--strict-docs`) without `--no-verify`; orchestrator should review and fold into proper tracker wording at merge.

STOP — no merge, no further tracker edits.

Generated with Claude Code
