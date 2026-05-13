# PR #599 Audit — C-1a Email Event Provider ID Prep Migration

**Slice:** C-1a (Lane C — prep migration; B8/C-1 Path A pick per operator 2026-05-13)
**Owner:** Claude
**Branch:** `claude/c-1a-email-event-provider-id`
**Base:** `master`
**Gate:** `operator` per ledger row 82 — title prefixed `[operator-approval-required]` (schema-touching)
**Risk:** **Low** — pure additive expand; idempotent DDL; zero existing rows (no live operators yet)
**Size:** 389 additions / 11 deletions / 7 files (light variant audit — <20 files, <5K LoC)

## Verdict

**approve-for-merge** — auto-merging per operator's 2026-05-13 break-time expanded delegation. Pattern B exemplary (worker 14L + executor 14L with file:line citations). Pure additive expand migration: `ADD COLUMN IF NOT EXISTS provider_event_id text` + partial `CREATE UNIQUE INDEX IF NOT EXISTS … WHERE provider_event_id IS NOT NULL` + `COMMENT ON COLUMN`. Zero destructive ops. Zero new RLS policies. Zero new grants. Unblocks C-1 (SendGrid Event Webhook receiver) per operator's Path A pick. Same operator-gate posture as B11.1 and B2.1 migrations.

## Pattern B compliance

**✓ EXEMPLARY** — worker self-audit (14 lenses with file:line citations) and executor independent audit (14 lenses with file:line citations) both present in PR body. Executor adds 3 executor-only lenses (12: additive-expand discipline; 13: partial UNIQUE predicate correctness; 14: RLS posture preservation).

## What landed

### 1. New migration (`db/migrations/202605131700_c_1a_email_event_provider_id.sql`, 141 LoC NEW)

- `ADD COLUMN IF NOT EXISTS email_event.provider_event_id text` (NULLABLE) at line 122
- `CREATE UNIQUE INDEX IF NOT EXISTS email_event_provider_event_id_unique ON public.email_event (provider_event_id) WHERE provider_event_id IS NOT NULL` at lines 137-139 — **load-bearing partial predicate** (without `WHERE`, multiple NULL rows would collide)
- `COMMENT ON COLUMN` documenting SendGrid origin + future-provider reuse
- Idempotent DDL — replays harmlessly via `IF NOT EXISTS` on both column and index
- Lock window: PG 11+ `ADD COLUMN NULLABLE` is metadata-only; `ACCESS EXCLUSIVE` held for microseconds
- Statement timeout + lock_timeout bounded inside `BEGIN/COMMIT`

### 2. New test (`test/db/migrations/c_1a_email_event_provider_id_migration_test.dart`, 230 LoC NEW)

- 14 test cases pin: column exists, column type is `text`, column is NULLABLE (back-compat), partial UNIQUE INDEX exists, `WHERE` predicate is load-bearing (test asserts predicate present and rejects full-UNIQUE variant), RLS posture unchanged (no new `CREATE POLICY`), no new `GRANT`
- All 14 pass

### 3. Cutoff-mirror doc bumps (per B2.1 / B11.1 precedent)

- `runbooks/phase_9_production1_migration_apply_runbook.md` — adds C-1a to pending list (line 96), bumps count `41 → 43` (recovers pre-existing B2.1 count drift; honest disclosure)
- `docs/POST_HARDENING_FOLLOWUPS.md` — adds new table row, bumps "42 pending" → "43 pending"
- `scripts/postgres_staging_setup.ps1` — MIGRATION_CUTOFF marker bumped to `202605131700_c_1a_email_event_provider_id`
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` — shared cutoff phrase
- `docs/phases/phase_9/phase_9_execution_backlog.md` — final cutoff line + rationale

## Critical safety guarantees (executor-verified)

| Guarantee | File:line | Verification |
|---|---|---|
| Pure additive expand — no destructive ops | migration grep | Zero `DROP`, `DELETE`, `ALTER COLUMN TYPE`, `UPDATE`, `TRUNCATE`. Only `ADD COLUMN IF NOT EXISTS` (line 122) + `CREATE UNIQUE INDEX IF NOT EXISTS` (line 137-139) + `COMMENT ON COLUMN`. Matches at lines 14, 95 are comment text saying "no DROP". |
| Partial UNIQUE predicate present and load-bearing | migration line 139 + test | `where provider_event_id is not null` clause verified by independent grep at line 139. Test asserts predicate is present (rejects a full-UNIQUE stripped variant). |
| RLS posture unchanged | migration grep | Zero `CREATE POLICY`, zero `ALTER TABLE … ENABLE/DISABLE ROW LEVEL SECURITY`, zero `GRANT`/`REVOKE`. Existing FK-join regime (`email_event_per_tenant_select` via EXISTS join through `email_outbox.operator_id`) stays. Matches at lines 86-89 are comment text confirming no policy change. |
| Idempotent DDL | migration line 122, 137 | Both `ADD COLUMN IF NOT EXISTS` and `CREATE UNIQUE INDEX IF NOT EXISTS` — safe to replay |
| No `pg_advisory_lock` | migration grep | Zero matches; banned-items list clean |
| Test-asserted partial UNIQUE shape | `c_1a_email_event_provider_id_migration_test.dart` (14/14 cases pass) | Pins the `WHERE` predicate; pins NULLABLE; pins RLS unchanged |
| Frozen `lib/auth/**` untouched | diff scope | No paths under `lib/auth/`, `lib/data/`, `tool/advisor_proxy/`, or `lib/infrastructure/persistence/postgres/repositories/` |

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master | ✓ — mergeable CLEAN |
| Pattern B both tables present | ✓ — worker 14L + executor 14L with file:line citations |
| Migration is pure additive expand | ✓ — independent grep confirms |
| Partial UNIQUE predicate present | ✓ — verified at line 139 |
| RLS posture preserved | ✓ — no `CREATE POLICY`, no `GRANT`/`REVOKE` |
| 14 test cases pass | ✓ — worker disclosure + executor verified per PR body |
| `migration_drift_scanner.dart --strict-docs --require-expand-contract` | ✓ disclosed clean |
| `migration_cutoff_lint.dart` | ✓ disclosed clean |
| `audit_logs_update_lint.dart` | ✓ disclosed clean |
| `postgres_import_lint.dart` | ✓ disclosed clean |
| `dart analyze --fatal-infos` | ✓ disclosed clean |
| All 5 cutoff-mirror docs bumped (B2.1 / B11.1 precedent) | ✓ — runbook + POST_HARDENING + staging script + 2 phase docs |
| No `pg_advisory_lock`, no banned items | ✓ |
| No `--no-verify` traces | ✓ |
| No ledger / lane-index touches | ✓ — diff scope confirms |
| Pre-existing runbook count drift (41 → 43) recovered as honest disclosure | ✓ — worker fully transparent, scope-adjacent doc hygiene |

## Pattern B compliance

**✓ EXEMPLARY** — both 14-lens tables present in PR body with file:line citations. Executor adds 3 executor-only lenses for migration-specific concerns.

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied to staging/Production1 | ❌ — new migration, queued in runbook (43 total pending now) |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — ledger row 82 says C-1a operator-gate schema-touching; matches PR scope exactly |
| Worker disclosure operator should know | ⚠ NON-BLOCKING — two honest disclosures: **(a)** pre-existing runbook count drift (41 → 43) recovered as scope-adjacent doc hygiene (B2.1 had missed the bump); **(b)** C-1's second flagged gap (`email_credentials.event_webhook_pubkey_pem` missing for ECDSA pubkey resolution) is NOT addressed in this slice — if C-1's worker hits that gap, operator may need to author a **C-1b** for the pubkey column. Both are forward-looking transparency, not blocking. |
| Stacked PR | ❌ — base is master |

**Decision**: per expanded policy. Pure additive expand; same operator-gate posture as B11.1 + B2.1 migrations; honest disclosures don't block this slice; "no business live yet" means zero existing rows + zero lock impact.

## Cross-lane notes

- **Unblocks C-1**: after this lands, C-1 can ship with `ON CONFLICT (provider_event_id) DO NOTHING` for replay rejection. C-1's original STOP-FLAG (the spec's `event_id` is a UUID surrogate, not a place for SendGrid's `sg_event_id`) is closed by adding the dedicated dedupe-key column.
- **Possible C-1b**: if C-1's worker hits the second gap (ECDSA pubkey column missing in `email_credentials`), a follow-up slice will be needed. Worker flagged this explicitly so it doesn't surprise the operator.
- **Pre-existing B2.1 runbook count drift recovered** — B2.1 added a migration to the pending list at line 52 without bumping the count from 41. C-1a's worker bumped 41 → 43 (recover +1, add C-1a +1). Now matches the actual list count.
- **Parallel slice B2.3** (blast-radius endpoint) also queued — disjoint files; no overlap.
- **No Codex-owned files touched.**

## Findings

None blocking. The two honest disclosures (runbook count drift + possible C-1b pubkey gap) are forward-looking transparency, not slice defects.

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 82 — C-1a ledger row (operator gate, schema-touching)
- `docs/_execution/lane_c_parity/03_execution_slices.md` C-1 — slice spec that this prep migration unblocks
- `db/migrations/202605131030_b11_1_auth_handoff_codes.sql` — additive-expand idiom precedent
- `db/migrations/202605131600_b2_1_default_role_catalog_versions.sql` — cutoff-mirror doc bump precedent
- CLAUDE.md "RLS-Ready Schema" — no RLS change; FK-join regime via `email_outbox.operator_id` stays
- Operator's 2026-05-13 Path A pick — ship now while there's zero SendGrid traffic

## Status

**Auto-merging** per operator's 2026-05-13 break-time expanded delegation. Migration joins staging + Production1 apply queue at slot 43.
