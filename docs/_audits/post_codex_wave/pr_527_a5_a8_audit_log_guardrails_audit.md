# PR #527 Audit — A5+A8 Schema Versioning + audit_logs UPDATE Lint

**Slice:** A5+A8 (Lane A — code health)
**Owner:** Codex executor
**Branch:** `codex/a5-a8-schema-audit-lints`
**Base:** `master`
**Gate:** `operator` per ledger + explicit `[operator-approval-required]` prefix in PR title (schema/audit-chain guardrail)
**Size:** 799 additions / 5 deletions / 8 files
**Chunking:** light variant (medium PR, scope is tooling/CI only — no production migrations applied, no runtime code paths)
**Dependency:** A0 merged ✓

## Pattern B compliance

PR body contains **BOTH** required audit tables (Sub-Agent Self-Audit + Executor Audit). Lens entries are substantive (file:line citations on most rows) and consistent between the two tables. Acceptable Pattern B compliance.

## Verdict

**approve-pending-operator** — escalating to operator per Gate=operator + explicit title prefix. Audit itself is clean; the gate is schema-touching policy + audit-chain integrity sensitivity, not a finding.

## Executor spot-checks

| Check | Outcome |
|---|---|
| **No production migrations applied** — PR is pure tooling/lint/convention | ✓ — diff scope: `.github/workflows/ci.yml` (2-line wiring), `db/migrations/post_deploy/.gitkeep` + `README.md` (net-new dir + docs), 2 `tool/*.dart` files (lint runner + scanner addition), 1 `.txt` allowlist (1 entry), 2 test files. ZERO new `.sql` migrations. ZERO touch to existing `.sql` files. |
| **Grandfather cutoff anchors to the most recent existing migration** so no current history breaks | ✓ — `defaultExpandContractGrandfatherCutoff = '202605131030_b11_1_auth_handoff_codes.sql'`. `ls db/migrations/` confirms this file exists. Cutoff comparison uses `fileName.compareTo(cutoff) <= 0`, so B11.1 and all earlier are grandfathered; the new gate enforces starting with the next migration. |
| **Audit-logs UPDATE lint allowlist is minimal + operator-review-shaped** | ✓ — 1 entry: `db/migrations/202605131010_admin_audit_logs_business_date.sql`. Comment block in allowlist file: *"This list is intentionally narrow … New entries require operator review because audit_logs is the hash-chain evidence table."* Rationale documented: *"Approved retrospectively by the A5 schema-versioning audit: the column was net-new and not part of the row_hash payload at apply time."* — i.e. the historical UPDATE was safe because it didn't break the chain. |
| **Lint regex is sound** — handles `[only]`, `[public.]`, `[quoted "audit_logs"]` variants | ✓ — `RegExp(r'\bupdate\s+(?:only\s+)?(?:(?:"public"\|public)\s*\.\s*)?(?:"audit_logs"\|audit_logs)\b', caseSensitive: false)` covers Postgres-quoted identifiers, optional `only`, optional `public.` prefix |
| **Comment stripping preserves offsets** so line numbers in violations point at real SQL | ✓ — `stripSqlCommentsPreservingOffsets()` replaces `--` and `/* */` comments with spaces/newlines (same line count), and is quote-aware (won't strip `--` inside a string literal) |
| **Test coverage** | ✓ — `audit_logs_update_lint_test.dart`: 4 cases (flag UPDATE outside allowlist, allow allowlisted file, ignore comments mentioning the pattern, no false-match on `audit_chain_anchors`). `migration_drift_scanner_test.dart`: 4 new cases (expand-contract anti-pattern detected, ADD NOT NULL + UPDATE anti-pattern, CREATE-then-seed in same file is fine, grandfather cutoff works). |
| **CI wiring is additive** — adds two new lint commands to the existing `repo-lints` job | ✓ — `.github/workflows/ci.yml` adds `dart run tool/audit_logs_update_lint.dart` and `dart run tool/migration_drift_scanner.dart --require-expand-contract` to the chained step. Renames step title to drop "migration-cutoff" + add "migration" generically. |
| **post_deploy convention README is clear** about expand vs contract phase, naming, and operator-gating | ✓ — `db/migrations/post_deploy/README.md` documents (a) what belongs in top-level `db/migrations/*.sql` (expand-only), (b) what belongs in `post_deploy/` (backfills, `SET NOT NULL`, contract removals), (c) shared-timestamp naming convention, (d) explicit operator-gate: *"Post-deploy SQL is operator-gated. Do not apply these files as part of routine staging setup, CI, or a feature deploy unless the matching runbook explicitly calls for the post-deploy phase."* |
| **Expand-contract detection ignores CREATE TABLE + seed in same file** (avoiding false positives on fresh tables) | ✓ — `_createdTables()` collects all `CREATE TABLE` declarations in the file; `_scanFile()` skips ADD COLUMN / UPDATE / SET NOT NULL on those tables. Test case `expand-contract flag ignores tables created in the same file` confirms |
| **Worker disclosed `dart analyze` clean + 14/14 focused tests pass + scanner clean against current tree + diff clean** | ✓ — verification block in PR body |
| **No production code touched** (`lib/**`, runtime, proxy, RLS) | ✓ — diff scope confirms |

## Operator-decision rationale (why this needs operator sign-off)

Per CLAUDE.md "Agent-Led Slices" durable rule:
> *"Auth-critical, RLS-touching, schema-touching, and proxy-touching slices require explicit operator approval before merge regardless of audit verdict."*

A5+A8 codifies repo-wide **enforcement** of:
1. The expand/contract migration phase boundary (new gate on every future migration).
2. The audit_logs UPDATE allowlist (locks in the precedent that hash-chain mutations are operator-reviewed).

Both are schema-discipline guardrails. Even though no production SQL is applied by this PR, it establishes durable convention that future schema work must follow. The PR title explicitly carries `[operator-approval-required]`.

## Recommendation

**approve-for-merge.** The technical execution is excellent:
- Grandfather cutoff means zero immediate breakage on existing history
- Test coverage proves both detection modes + false-positive avoidance
- Operator-review-shaped allowlist matches the project's audit-chain integrity doctrine
- post_deploy convention is a clean two-phase deployment discipline
- Pattern B both-tables compliance is substantive (not just rubber-stamping)
- The single existing audit_logs UPDATE (PR #324 W3.A from 2026-05-07's admin hierarchy work) is correctly allowlisted with documented rationale

If approved, I will merge + update the ledger (A5+A8 → merged).

## Authority anchors verified

- `docs/_execution/lane_a_code_health/03_execution_slices.md:234-260` (slice scope)
- `docs/_audits/code_health/a5_schema_versioning_and_a7_frameworks.md:113-162` (audit that prescribed this work)
- `CLAUDE.md:84` (hash-chained audit log doctrine)

## Findings

None blocking. Two operator-decision items (schema-touching policy + audit-chain integrity policy) — both expected given the slice scope.

## Status

Awaiting operator approval. Will merge + update ledger on go-ahead.
