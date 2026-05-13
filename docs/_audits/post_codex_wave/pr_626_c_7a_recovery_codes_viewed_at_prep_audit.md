# PR #626 Audit — C-7a `mfa_factors.recovery_codes_viewed_at` Prep Migration (Claude)

**Slice:** C-7a (Lane C — Cross-Surface Parity; ledger row 94)
**Owner:** Claude (orchestrator-dispatched, isolated worktree agent)
**Branch:** `claude/c-7a-recovery-codes-viewed-at`
**Base:** `master` @ `c9266236`
**Gate:** **operator-approval-required** — schema-touching per CLAUDE.md "Agent-Led Slices"
**Risk:** **Low** — pure additive expand (`ADD COLUMN IF NOT EXISTS … timestamptz` NULL); no RLS change, no GRANT change, no new index; mirrors C-1a (PR #599) verbatim
**Size:** 373 additions / 11 deletions / 7 files (light variant audit — 1 SQL + 1 test + 5 cutoff-mirror doc bumps)

## Verdict

**approve pending operator OK** — audit clean. Per CLAUDE.md "Agent-Led Slices": *"Auth-critical, RLS-touching, schema-touching, and proxy-touching slices require explicit operator approval before merge regardless of audit verdict."* This PR is schema-touching → **NOT auto-merged**; held for operator sign-off.

Direct mirror of PR #599 (C-1a `email_event.provider_event_id` prep) which the operator approved 2026-05-13 with "yes to all" on the open-decisions slate. Same shape: additive expand, NULLABLE column, NULL = "never viewed" pre-launch default state, no RLS/GRANT/index touches.

## Pattern B compliance

**✓ EXEMPLARY** — worker shipped 14-case migration shape test pinning the persistence-shape contract; PR body includes Pattern B 8-lens table; file:line citations to C-1a precedent (PR #599 / #611) and the C-7 slice spec (`lane_c_parity/03_execution_slices.md:145`).

## What landed

| File | LoC | Kind |
|---|---|---|
| `db/migrations/202605131800_c_7a_recovery_codes_viewed_at.sql` | +124 / 0 | **NEW** — `ALTER TABLE public.mfa_factors ADD COLUMN IF NOT EXISTS recovery_codes_viewed_at timestamptz;` + `COMMENT ON COLUMN`; lock + statement timeouts; `begin/commit` wrap |
| `test/db/migrations/c_7a_recovery_codes_viewed_at_test.dart` | +232 / 0 | **NEW** — 14-case shape test pinning column, NULL, timestamptz, no-RLS, no-GRANT, no-index, no-DROP, no-`audit_logs` UPDATE, no `pg_advisory_lock` |
| `docs/POST_HARDENING_FOLLOWUPS.md` | +4 / -3 | Bump cutoff row + count: 43 → 45 pending (44 raw + 1 drift recovery — disclosed) |
| `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` | +1 / -1 | Mirror cutoff filename |
| `docs/phases/phase_9/phase_9_execution_backlog.md` | +7 / -3 | Mirror cutoff filename + add C-7a description paragraph |
| `runbooks/phase_9_production1_migration_apply_runbook.md` | +4 / -3 | Mirror cutoff filename + append to pending-scope list + bump pending count |
| `scripts/postgres_staging_setup.ps1` | +1 / -1 | `MIGRATION_CUTOFF_BEGIN`/`END` block updated |

**Net effect:** `mfa_factors` table gains `recovery_codes_viewed_at timestamptz` (NULL). C-7 ("Adaptive 2FA button") now has the data contract it needs: gateway will write `UPDATE mfa_factors SET recovery_codes_viewed_at = now() WHERE factor_id = $1` on the "View recovery codes" click; My Account button label compute reads `(session.mfaEnrolled, factor_count, recovery_codes_viewed_at)` to choose between "View recovery codes" (NULL) and "Manage two-factor sign-in" (NOT NULL).

## Critical safety guarantees (executor-verified)

| Guarantee | File:line | Verification |
|---|---|---|
| `tool/advisor_proxy/` untouched | `git diff origin/master -- tool/advisor_proxy/` returns 0 lines | Independent diff confirms |
| `lib/auth/` untouched | diff scope | 0 lines |
| `pubspec.yaml` untouched | diff scope | 0 lines |
| `docs/_indices/WAVE_EXECUTION_LEDGER.md` untouched | diff scope | 0 lines (orchestrator's job at merge) |
| No new RLS policy | migration SQL | `CREATE POLICY` / `ENABLE RLS` / `DISABLE RLS` absent; statement-only test view asserts this |
| No new GRANT/REVOKE | migration SQL | Test pins absence; postgres default column-grant semantics apply |
| No destructive ops | migration SQL | No `DROP`, `DELETE`, `TRUNCATE`, `ALTER COLUMN`; test pins all four |
| Idempotent | migration SQL line 117 | `ADD COLUMN IF NOT EXISTS` confirmed |
| NULLABLE (no NOT NULL, no DEFAULT) | migration SQL line 117 | Regex test pins ADD COLUMN terminates at `timestamptz` with no NOT NULL or DEFAULT clause |
| `timestamptz` type (not banned variant) | migration SQL line 117 | Test pins absence of `timestamp without time zone` |
| Lock + statement timeouts | migration SQL line 112-113 | `set local statement_timeout = '30s'` + `set local lock_timeout = '5s'` |
| Transaction-wrapped | migration SQL lines 110, 124 | `begin;` / `commit;` |
| No `audit_logs` UPDATE | migration SQL | Statement-only regex test confirms append-only invariant respected |
| No `pg_advisory_lock` | migration SQL | Test pins absence (V1 lean cut ban) |
| No new index | migration SQL | Test pins absence; existing `mfa_factors_user_active_idx (user_id, factor_type)` covers per-user point lookup |
| Migration filename matches cutoff lint pattern | `202605131800_c_7a_recovery_codes_viewed_at.sql` | Lexicographically after `202605131700_c_1a_…` (master cutoff); migration_cutoff_lint clean per worker disclosure |
| 5 cutoff-mirror docs synced | diff scope | All 5 known mirror sites bumped to new cutoff filename |
| 14/14 tests pass | disclosed | `flutter test test/db/migrations/c_7a_recovery_codes_viewed_at_test.dart` → all green |
| `dart analyze --fatal-infos` clean | disclosed | `No issues found!` on test file |
| `migration_drift_scanner --strict-docs --require-expand-contract` clean | disclosed | cutoff=202605131800, expand-contract clean |
| `migration_cutoff_lint` clean | disclosed | All 5 mirror sites match new cutoff |
| `audit_logs_update_lint` clean | disclosed | Existing allowlist preserved |
| `postgres_import_lint` clean | disclosed | Pre-push hook clean |
| `index_leading_column_lint` clean | disclosed | Pre-push hook auto-ran |
| `rls_policy_lint` clean | disclosed | Pre-push hook auto-ran |

## Executor 14-lens audit (re-verified)

| # | Lens | Verdict | Re-verification |
|---|---|---|---|
| L1 Product & Journey | OK | C-7 ("Adaptive 2FA button") is data-contract-blocked on master; this prep migration unblocks the read side per slice spec `lane_c_parity/03_execution_slices.md:145` |
| L2 IA & Navigation | OK | No screen/route change; column-only addition |
| L3 Data Model / Migration / RLS | OK | Pure additive expand; new column on existing `mfa_factors` table; no RLS regime change; column inherits existing per-user RLS policies |
| L4 Repository & Service | OK | No repository code change in this PR — C-7 (Codex slice) wires the gateway reader/writer after this lands |
| L5 Proxy / Route / Gateway | OK | No proxy file touched; C-7 will wire `/v1/auth/mfa/recovery-codes/view` (or equivalent) |
| L6 Auth / Roles / Permissions | OK | `lib/auth/` 0-line diff; no new permission key; existing MFA permission keys carry through |
| L7 Lifecycle | OK | Backfill posture: NULL = "never viewed" handles pre-existing + future rows safely; no enrollment-time writer required |
| L8 Workers / Deploy / Health | OK | No worker/runtime touched |
| L9 UI / UX / Accessibility | OK | UX surfaces in C-7 (Codex), not C-7a |
| L10 Performance | OK | Metadata-only ALTER on Postgres 11+ for NULLABLE add with no default — microsecond lock; lock/statement timeouts wrap belt-and-suspenders |
| L11 Parity | OK | Mirrors C-1a → C-1 prep-then-receiver cadence (PR #599 → #611); operator approved that pattern 2026-05-13 |
| L12 Tests / Builds / Evidence | OK | 14-case shape test; full lint suite clean; pre-push hooks auto-ran |
| L13 Observability / Audit | OK | Column carries audit semantics (last-view timestamp) but does not write to `audit_logs`; future viewer-action audit row remains C-7's responsibility |
| L14 Docs / Tracker / Hygiene | OK | All 5 cutoff-mirror docs synced; honest disclosure on POST_HARDENING_FOLLOWUPS pre-existing drift (44 rows / "43 pending" → recovered to "45 pending" matching actual count, same pattern as PR #599) |

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master @ `c9266236` | ✓ — `baseRefOid` confirms; MERGEABLE CLEAN |
| Pattern B both tables present | ✓ — worker self-audit 8-lens table + this 14-lens executor table |
| 7 files match PR body declaration | ✓ — `git diff --stat` confirms |
| `tool/advisor_proxy/` diff = 0 lines | ✓ |
| `lib/auth/` diff = 0 lines | ✓ |
| `pubspec.yaml` diff = 0 lines | ✓ |
| `WAVE_EXECUTION_LEDGER.md` diff = 0 lines | ✓ — orchestrator's job |
| Migration is pure additive expand | ✓ — independent re-read of SQL body confirms |
| Migration filename = `202605131800_c_7a_recovery_codes_viewed_at.sql` | ✓ — lex-after current cutoff |
| C-1a present on master (precedent intact) | ✓ — `git ls-tree origin/master` confirms `202605131700_c_1a_email_event_provider_id.sql` blob |
| C-7a NOT yet on master | ✓ — `git ls-tree origin/master db/migrations/` returns only C-1a |
| 14/14 shape tests pass | ✓ disclosed |
| `migration_drift_scanner` clean | ✓ disclosed |
| `migration_cutoff_lint` clean | ✓ disclosed |
| No `--no-verify` traces | ✓ |
| Mid-flight rebase clean | ✓ — worker disclosed rebase onto `c9266236` after PR #625 merged; no conflicts |

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied to staging/Production1 | ❌ — code-ready only; staging/Production1 apply remains operator-initiated per runbook |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — ledger row C-7a (line 94) names this exact migration; PR scope matches |
| Worker disclosure operator should know | ⚠ THREE non-blocking disclosures: <br>(a) `POST_HARDENING_FOLLOWUPS.md` had pre-existing +1 row drift (44 rows / "43 pending"); recovered to "45 pending" matching actual row count, same pattern as PR #599 — accepted on that PR. <br>(b) Stale numbered list in runbook line 274 not extended (would require enumerating 7+ unrelated slices); bullet-list scope + prose dependency notes are authoritative and updated. <br>(c) Mid-flight rebase onto `c9266236` (master moved 2 commits during work due to PR #625); clean rebase, no conflicts. |
| Stacked PR | ❌ — base is master |
| **Schema/RLS touch** | **✓ TRIGGERED** — operator approval gate per CLAUDE.md |

**Decision**: **HOLD for explicit operator approval**. Once approved, merge. Operator's 2026-05-13 "yes to all" on the open-decisions slate covers the slice-level decision to ship C-7a; the per-PR sign-off is the merge-time gate.

## Cross-lane notes

- **Unblocks C-7** — Codex's "Adaptive 2FA button" slice can spawn immediately after C-7a merges.
- **Mirrors C-1a → C-1 cadence** — operator approved that pattern 2026-05-13.
- **Production1 cutoff advances** — from `202605131700_c_1a_email_event_provider_id.sql` → `202605131800_c_7a_recovery_codes_viewed_at.sql`. Both migrations stay batched for the next Production1 apply event per runbook (not auto-applied).
- **No Codex-owned files touched** — pure Claude-territory prep migration.

## Findings

None blocking.

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 94 — C-7a ledger row
- `docs/_execution/lane_c_parity/03_execution_slices.md:145` — C-7 slice spec naming the column
- `db/migrations/202604250008_auth_schema_foundation.sql:243-255` — existing `mfa_factors` shape (timestamps it does and doesn't have)
- `db/migrations/202605131700_c_1a_email_event_provider_id.sql` — precedent prep migration (PR #599)
- `docs/_audits/post_codex_wave/pr_599_c_1a_email_event_provider_id_audit.md` — C-1a audit shape
- CLAUDE.md "RLS-Ready Schema" + "Time Guardrails" + "Agent-Led Slices"
- Operator's 2026-05-13 "yes to all" on open-decisions slate (covers slice-level approval; per-PR merge sign-off pending)

## Status

**HELD for operator approval.** Audit verdict: approve-on-sign-off.
