# A5 — Schema Versioning + A7 — Frameworks Consolidation Audit

Status: planning audit (no code, no doc edits, no commits).
Branch/worktree: `claude/nifty-clarke-d3ec25`
Source commit: `4033f1bb` (master HEAD at audit start).
Date: 2026-05-12.

Authority read for this audit:

- `CLAUDE.md` (RLS-Ready Schema; Proxy & API Conventions — hash-chained audit_logs rule).
- `docs/archive/_decisions/post_codex_wave_decisions_2026-05-12.md` (8 locks; lock #8 = read-side join only on audit_logs; open item: "schema versioning + migration system shape — pending Wave A5").
- `docs/archive/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md` (addendum A7 — expand-contract migration convention + `UPDATE audit_logs` allowlist guardrail).
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` (closed, retained as historical authority).
- `docs/archive/_research/post_codex/r2_engineering_patterns.md` §80-103 (the originating rationale for the three additions: `post_deploy/` dir, `--require-expand-contract` flag, `UPDATE audit_logs` lint).
- `docs/_audits/code_health/a1_proxy_bug_root_cause.md` (shape precedent for this doc).
- `docs/POST_HARDENING_FOLLOWUPS.md` (37-migration Production1 apply queue; one row pending CI).
- `PROJECT_TRACKER.md` (frameworks listed at Authority Order item 7).
- `db/migrations/` listing (116 SQL files; cutoff currently at `202605131020_admin_hierarchy_lifecycle_access_hardening.sql`).
- `docs/frameworks/{README,FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK,UX_ADJUSTMENT_FRAMEWORK,PERFORMANCE_FRAMEWORK,MOBILE_WEB_CONSOLE_E2E_FRAMEWORK,deployFramework}.md`.

---

## Section 1 — Methodology

This audit pairs two seemingly unrelated post-Codex-wave items because the addendum (`post_codex_wave_decisions_addendum_2026-05-12.md`) groups them: both are "the rules of engineering exist; codify how they're enforced and discovered." A5 is the database-side instance (write the expand-contract rule into a directory layout + lint), A7 is the prose-side instance (write the workflow rules into a discoverable framework index).

Scope:

- **In:** current migration directory + lint state; existing destructive-migration patterns; `UPDATE audit_logs` audit; framework inventory; cross-reference + adoption signal; consolidation plan.
- **Out:** writing any of the linter rules, drafting any of the framework READMEs, editing CLAUDE.md, drafting Lane B feature migrations (B8 ltree, B10 vendor_applicability). Out also: testing strategy, contract-doc-maintenance doctrine, prompt generation hygiene — those are *gaps* this audit names but does not fill.

Output: a single planning artifact (this file). Execution slices for the actual work are sketched in Section 6.

---

## Section 2 — A5: Schema versioning, current state

### 2.1 Migration directory inventory

`db/migrations/` contains **116 SQL files** at audit time, all flat-file, naming convention `YYYYMMDDHHMM_descriptive.sql` (12-digit timestamp prefix, lexicographic order = chronological order). The cutoff lint (`tool/migration_cutoff_lint.dart:23`) treats this as a single sorted sequence.

`db/migrations/post_deploy/` **does not exist** (verified via `ls db/migrations/post_deploy/` → "No such file or directory"). This matches the addendum A7 expectation — the directory is about to be introduced, not already present.

`db/` siblings:

- `db/migrations/` — 116 sequential migrations (current pattern).
- `db/dev/` — `Dockerfile` + `README.md` (local container fixtures).
- `db/verification/` — one verification SQL file: `202604250006_advisor_schema_hardening_audits.sql`. Pattern is "verification SQL that mirrors a migration", not a migration substitute.

**Already-applied expand-contract precedent.** Three multi-step series under flat `db/migrations/` already implement expand-contract by splitting one logical change across `_a_` / `_b_` / `_c_` files:

| Series | Files | Pattern |
|---|---|---|
| 9.0Σ.g usage_caps two-slot key | `202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql` (ADD nullable cols), `..._b_..._backfill.sql` (UPDATE existing rows), `..._c_..._constraint_flip.sql` (SET NOT NULL + swap PK + add FKs + indexes) | Add → Backfill → Constraint flip. Header comment at `..._a_...sql:22-41` documents the three-step plan in prose. |
| 9.0Σ.k rollups | `202604280010_a_..._aggregation_state.sql`, `..._b_..._rollup_tables.sql`, `..._c_..._pg_cron_jobs.sql` | State first → tables next → cron last. |
| 9.0Σ.b RLS wrappers | `202604280000_..._b_rls_wrappers.sql`, `202604280001_..._b_rewrite_existing_policies.sql` | Wrappers first → policy rewrites second. |

These exist as ad-hoc convention but are **not enforced** anywhere. A new migration that conflates add+backfill+constraint into a single file would pass current CI.

### 2.2 Destructive migration patterns found

`rg -i "DROP COLUMN|DROP TABLE|RENAME COLUMN"` against `db/migrations/`:

| File | Line | Operation | Safety posture |
|---|---|---|---|
| `db/migrations/202604250008_auth_schema_foundation.sql:1085-1125` | `1125` | `alter table public.users drop column role` | Preceded by full backfill (`1094-1128` is one DO block); guarded by `information_schema.columns` exists check so re-runs are no-ops. Pre-9.0 foundation table; no live data at apply time. |
| `db/migrations/202604270100_auth_sessions_token_hash_rename.sql:34-35` | `34-35` | `alter table public.auth_sessions rename column refresh_token_hash to token_hash` | Idempotent via `information_schema.columns` exists checks for both old and new name. Production1 empty at apply (`:11`); staging applied. No row migration cost. |
| `db/migrations/202604290100_phase_11A_1_operators_suspended_at.sql:16` | comment only | "Forward-only: no DROP COLUMN escape hatch on rollback." | Adds nullable `suspended_at`; the DROP COLUMN reference is a comment about the *absence* of a contract phase. No destructive op in this file. |

**Other destructive-shaped operations** (`DELETE FROM`, `TRUNCATE`, `DROP TABLE`):

- `rg "drop table"` → no matches in `db/migrations/`.
- `rg "TRUNCATE TABLE"` → no matches. (`truncated` appears only in column-purpose comments.)
- `rg "DELETE FROM"` → 14 matches across 12 files. Every one of them is either:
  - **Retention / sweep** of a non-fact-source table (`event_outbox`, `advisor_response_cache`, `admin_request_idempotency`, `event_outbox_publish_metrics`) running inside a pg_cron job body, NOT a one-shot migration mutation. Example: `202605050200_phase_10a_3_event_outbox_retention.sql:157`, `202605071400_advisor_response_cache_table.sql:295`.
  - **Cron job cleanup** (`delete from cron.job where jobname = ...`) — pure pg_cron registry hygiene, no user data. Examples: `202605082100_phase_10a_3_retention_sweep_in_db_followup.sql:116, 135`; `202605081100_partman_maintenance_hourly_cron.sql:81`.
  - **Cache rebuild on definition change.** `202604290101_phase_9_hierarchy_access_wiring.sql:268`, `202605131020_admin_hierarchy_lifecycle_access_hardening.sql:118` — both delete from `public.user_effective_locations` (a denormalized cache) immediately before rebuilding it. Safe because the cache is owned and refreshed by the same triggers in the same migration.
  - **One-time tenancy guard.** `202604300002_phase_9_mfa_hardening_launch_roles.sql:201` — `delete from public.operator_admins` legacy rows during the MFA-hardening seed.
  - **One-time legacy trim.** `202604280007_phase_9_0sigma_h_advisor_conversation_log.sql:337` — clears the prior conversation-log shape during the new-table replacement.

**`SET NOT NULL` / `NOT NULL` adds with potential live-data risk.** The 40-line grep is misleading because most matches are CREATE TABLE column defs. Real `ALTER ... SET NOT NULL` callsites against existing populated columns:

| File | Pattern | Mitigation |
|---|---|---|
| `db/migrations/202604280006_c_phase_9_0sigma_g_usage_caps_two_slot_constraint_flip.sql:92, 100` | `SET NOT NULL on usage_caps / usage_logs org-unit cols` | Step c of an explicit three-step series. Backfill in step b (`202604280006_b_...sql`) confirmed no NULLs before this lands. |
| `db/migrations/202605050400_phase_8_business_date_denorm.sql:33, 70` | denormalized `business_date` column SET NOT NULL across `connector_sync_log`, `inbound_webhook_dead_letter`, `sanity_log` | Backfill loop with `LIMIT 50000 per pass` (`:34`); SET NOT NULL only fires once `business_date IS NULL` is empty (header `:69-71`). |
| `db/migrations/202605131010_admin_audit_logs_business_date.sql:14-19` | `audit_logs.business_date` ADD nullable → UPDATE backfill → SET NOT NULL | **Single migration combines all three phases.** See §2.4 — this is the one `UPDATE audit_logs` in the codebase, and the lack of expand-contract phasing here is the reason A5 exists. |
| `db/migrations/202605070100_password_history_salt_pepper.sql:62` | `password_hash_algo TEXT NOT NULL DEFAULT 'sha256'` on existing rows | DEFAULT means PG synthesizes the value at backfill, no row-rewrite needed. |

**Findings summary, §2.2:**

- 2 historical DROP COLUMN / RENAME sites, both with idempotent guards and zero-row contexts at the time of apply.
- 0 DROP TABLE migrations.
- 14 `DELETE FROM` callsites, all benign (sweep cron, cache rebuild, one-time legacy trim).
- 3 migrations doing add → backfill → SET NOT NULL in a single file; one is on `audit_logs` itself.

### 2.3 CI lint state + gaps

Existing migration-related lints in `tool/`:

| Lint | Path | What it enforces | Gap vs A5/A7 |
|---|---|---|---|
| `migration_cutoff_lint.dart` | `tool/migration_cutoff_lint.dart` | The staging-setup script `scripts/postgres_staging_setup.ps1` cutoff filename must equal the lexicographically-latest migration in `db/migrations/`. Sentinel markers `# MIGRATION_CUTOFF_BEGIN` / `# MIGRATION_CUTOFF_END`. | Knows nothing about destructive operations, expand-contract phasing, or `audit_logs` mutations. Treats `db/migrations/` as a flat directory. |
| `migration_drift_scanner.dart` | `tool/migration_drift_scanner.dart` | Companion helper: calls the cutoff lint, can `--fix` the script, scans watched docs (`PROJECT_TRACKER.md`, `docs/POST_HARDENING_FOLLOWUPS.md`, runbook, phase docs) for stale migration references, emits `build/reports/migration_drift_report.md`. | Same gap. Watched docs list (`tool/migration_drift_scanner.dart:16-23`) does not include the new addendum docs (`post_codex_wave_decisions*.md`). |
| `postgres_import_lint.dart` | `tool/postgres_import_lint.dart` | Forbids `package:postgres` imports outside `lib/infrastructure/persistence/postgres/`. | Orthogonal to A5 — code-layer discipline, not migration discipline. |
| `rls_policy_lint.dart` | `tool/rls_policy_lint.dart` + `tool/rls_policy_lint_allowlist.txt` | Forbids bare `current_setting('app.*')` in `CREATE POLICY` bodies; uses the superseded-migration allowlist. | Orthogonal to A5 (policy-body discipline). The **allowlist file pattern** is the precedent A7 wants to copy for `UPDATE audit_logs`. |
| `index_leading_column_lint.dart` | `tool/index_leading_column_lint.dart` | Every B-tree index on operator-scoped fact tables must lead with `operator_id` (or `(operator_id, location_id)`). | Orthogonal. Already enforces a hard rule from CLAUDE.md. |
| `permission_key_lint.dart` | `tool/permission_key_lint.dart` | Permission-key catalog freeze enforcement. | Orthogonal. |

**A5/A7 gaps in current lint posture:**

1. **No `post_deploy/` awareness.** No lint knows about a contract-phase directory or refuses to combine destructive operations with feature deploy gates.
2. **No `UPDATE audit_logs` guardrail.** Hash chain integrity is a hard rule in CLAUDE.md (line 84) and the audit_logs table grants explicitly revoke UPDATE/DELETE from runtime roles (see `202604280005_phase_9_0sigma_f_audit_logs.sql:59-65` header rule 5 + `:204-206` table comment). But no lint catches a future migration that does `update public.audit_logs SET ...`. The R2 brief calls for this at `r2_engineering_patterns.md:98`.
3. **No expand-contract enforcement.** Nothing prevents a single migration from doing `ADD COLUMN NOT NULL DEFAULT 'x'` on a partitioned table with billions of rows.
4. **No append-only check for the chain hash columns.** `row_hash` and `prev_row_hash` columns are sacred (header rule 6 of `202604280005...sql:67-73`); no lint forbids an `ALTER TABLE audit_logs DROP COLUMN row_hash`.

### 2.4 audit_logs UPDATE audit

This was the most important grep in the audit. Per CLAUDE.md "Proxy & API Conventions" (`CLAUDE.md:84`): *"Hash-chained audit log: SHA-256 via `pgcrypto`, `pg_partman` per-operator/day, daily Azure Blob anchor."* Per the audit_logs migration header (`202604280005_phase_9_0sigma_f_audit_logs.sql:59-65`): *"Append-only by grant shape. Runtime roles get INSERT and SELECT only; UPDATE and DELETE are revoked."*

`rg -i "update public\.audit_logs|update audit_logs"`:

| Path | File | Count | Verdict |
|---|---|---|---|
| `db/` (migrations + verification) | `db/migrations/202605131010_admin_audit_logs_business_date.sql:14` | **1** | One `update public.audit_logs set business_date = chain_date where business_date is null;` This is the **only** UPDATE audit_logs in the entire repo. |
| `lib/` (all service / repository / state code) | — | **0** | Clean. |
| `tool/` (proxy, workers, harnesses) | — | **0** | Clean. |
| `docs/` (decisions, research, audits) | `docs/archive/_research/post_codex/r2_engineering_patterns.md:98`, `docs/archive/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md:27` | 2 | Both are prose references to the *future* lint guardrail, not SQL. |

**Detailed read of the single UPDATE site.** `db/migrations/202605131010_admin_audit_logs_business_date.sql:9-19`:

```sql
begin;

alter table public.audit_logs
  add column if not exists business_date date null;

update public.audit_logs
   set business_date = chain_date
 where business_date is null;

alter table public.audit_logs
  alter column business_date set not null;
```

**Hash chain safety analysis:**

- The trigger that computes `row_hash` (`202604280005_phase_9_0sigma_f_audit_logs.sql:225+`) hashes a `canonical_payload_bytes` built from the row's identifying columns + `jsonb_typeof(payload) = 'object'` payload text. Per header rules 1 + 6, the canonical encoding is fixed at the schema in force when the row was inserted.
- `business_date` was added 2026-05-13. The hash already-computed-and-stored on every existing row was over the pre-`business_date` canonical payload. The UPDATE adds a value to a new column the canonical formula does not yet reference; the stored `row_hash` remains correct for the *original* canonical formula.
- **The verifier (`tool/audit_anchor/`) walks the chain using the formula in force when the row was inserted.** If the verifier is taught to hash `business_date` for rows after the migration's cutoff, the pre-migration backfilled rows would re-hash with an empty payload position for `business_date` (or with the backfilled value, depending on the formula version) and break the chain. The migration must be paired with a verifier-formula-version bump that says "rows with `id < N` hash with the pre-business_date formula".
- **Per the addendum A7 expand-contract requirement, the right shape would have been:**
  1. `db/migrations/<ts>_..._add.sql` — `ADD COLUMN business_date date NULL`. Deploy. Writer code starts populating new rows.
  2. `db/migrations/post_deploy/<ts>_..._backfill.sql` — the `UPDATE public.audit_logs SET business_date = chain_date WHERE business_date IS NULL;` runs only after the writer is shipped, ideally chunked with `LIMIT N` per pass like `202605050400_phase_8_business_date_denorm.sql:30-34` does.
  3. `db/migrations/post_deploy/<ts>_..._constraint.sql` — `SET NOT NULL` once the backfill is verified complete.

The current single-file shape (`202605131010_admin_audit_logs_business_date.sql`) skipped that phasing. It worked because Production1 is empty of operator data, but the same migration applied to a populated chain would have:
- Acquired ACCESS EXCLUSIVE on the partitioned parent for the SET NOT NULL (worst case; minor for the UPDATE since it's per-partition).
- Run an unbounded UPDATE that the runtime UPDATE/DELETE revoke grants does not block, because migrations apply as `forge_admin` (BYPASSRLS, full DML grants by definition).

**Verdict:** the single UPDATE is justified by the column being net-new and uninvolved in the hash formula at the time of apply. It is **not a chain integrity violation today**. But it is exactly the shape A7 must henceforth refuse: a single migration combining add + backfill + tighten on the most sensitive table in the schema. Add this site to the lint's initial allowlist with an explicit "approved by A7 retrospectively; do not extend" comment.

**Count finding: 1 `UPDATE audit_logs` in the codebase. Expected allowlist size at A7 ship: 1.**

### 2.5 Versioning of seed / config catalogs

Addendum A2 (Default Roles catalog) introduces a per-business pinned catalog version pointer. Other places in the codebase where versioned references already exist or are needed:

| Versioned surface | Where | Pattern |
|---|---|---|
| Corpus versions | `db/migrations/202605010000_phase_11A_3a_corpus_versions_ledger.sql:21-29` + `202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql` + `advisor_source_chunks.version_id` | Full ledger table `corpus_versions` + many-to-many `corpus_version_chunks` join; `superseded_at` flag + `rollback_of` pointer. Mature shape; the model A2 should mirror. |
| T&Cs (Phase 9.8) | `db/migrations/202605040100_phase_9_8_tos_versions.sql` | `tos_versions` (corpus-scoped, no operator_id) + `tos_acceptances` (operator+user+version triple, append-only with IP+UA). Acceptance ledger is operator-scoped; version table is global. |
| Permission keys | `db/migrations/202604250008_auth_schema_foundation.sql` `permission_keys` table (frozen catalog) | Single source of truth mirrored in `lib/auth/permission_keys.dart` + `docs/contracts/auth_permission_key_catalog.md`. No version pointer — the catalog itself is the version. |
| Feature flags | `db/migrations/202605020400_phase_11A_7_feature_flags_admin_columns.sql` + `202605072000_feature_flags_sentinel_operator.sql` + `202605081300_seed_kms_rollout_flags_default_disabled.sql` | Per-flag rows; no catalog version pointer per operator. Operator picks a value; no pinned reference shape. |
| KMS rollout | `202605020200_phase_11A_4c_kms_rollout_flags.sql` + `202605081300_seed_kms_rollout_flags_default_disabled.sql` | Feature-flag based, not catalog-pinned. |
| Demo mode state | `demo_mode_state` table per (operator, location, category) | Per-tuple boolean, not versioned. Auto-flip on first connector backfill (`DemoModeFlipPolicy`). |
| Vendor applicability (Lane B10 / addendum A6) | not yet built | Single table `vendor_applicability` with `setting_kind` discriminator + JSONB + `effective_from` / `effective_until`. Temporal columns are the addendum's mechanism for versioning. |

**Findings:**

- Two mature versioning patterns already exist (`corpus_versions`, `tos_versions`). Default Roles (A2) should mirror `corpus_versions`'s ledger + many-to-many shape.
- Vendor applicability (A6) uses temporal columns instead of an explicit ledger, which is a different versioning model. Both patterns are valid; the choice should be documented in a single "versioning patterns" appendix to the migration convention doc.
- Feature flags + KMS rollout + demo mode state are **mutable singletons**, not versioned catalogs. They are appropriate as-is; the A5 convention does not need to retrofit version pointers on them.

### 2.6 Backfill scripts — current pattern

There is no dedicated `db/backfills/` directory. Backfill SQL lives inline in migration files. Two shapes appear:

1. **Inline DO block** (`202604250008_auth_schema_foundation.sql:1094-1128`). One transaction, no chunking. Safe for small / empty target tables.
2. **Chunked loop with documented LIMIT** (`202605050400_phase_8_business_date_denorm.sql:33-34, 70`). Header explicitly states the loop body and rationale.

Out-of-band repair: `tool/cutover/` holds the manual-cutover-tool harness (not a SQL backfill, a Dart-driven data-repair shell). Not a backfill in the migration sense.

**Gap:** no shared backfill template or runbook. Each migration author re-invents the chunked-update DO block. The expand-contract template in §3.3 below proposes a canonical chunked-backfill snippet.

---

## Section 3 — A5: Expand-contract adoption plan

### 3.1 `post_deploy/` directory introduction

Proposed shape:

```
db/migrations/
├── 202605131010_..._add.sql        ← runs at deploy
├── 202605131010_..._backfill.sql   ← optional, runs at deploy (small data only)
└── post_deploy/
    ├── 202605131010_..._contract.sql   ← runs after the feature is live + verified
    └── 202605131010_..._drop.sql       ← runs after ≥1 release gap
```

Rules:

- `db/migrations/*.sql` runs in the standard deploy pipeline before service rollout. Operations allowed: `CREATE TABLE`, `CREATE INDEX CONCURRENTLY`, `ADD COLUMN NULL`, small inline backfills bounded by row count, additive comments, `CREATE EXTENSION`, trigger / function definitions, additive grants.
- `db/migrations/post_deploy/*.sql` runs only after the corresponding feature is shipped, observed, and pinned. Operations allowed: large `UPDATE`-style backfills (chunked, `FOR UPDATE SKIP LOCKED` where appropriate), `SET NOT NULL` once the backfill is verified, `DROP COLUMN`, `DROP TABLE`, constraint tightening.
- A single logical change spans both directories with a shared timestamp prefix so the pairing is grep-discoverable.

Naming convention: `db/migrations/post_deploy/<timestamp>_<descriptive>.sql` where `<timestamp>` matches the originating expand-phase file. The lexicographic ordering inside `post_deploy/` is independent of `db/migrations/`'s ordering.

**Migration runbook impact.** `runbooks/phase_9_production1_migration_apply_runbook.md` and `scripts/postgres_staging_setup.ps1` currently treat `db/migrations/` as a single sequence. The cutoff lint sentinel (`# MIGRATION_CUTOFF_BEGIN`) must grow a second sentinel for the post-deploy directory. Detail in §3.3.

### 3.2 New CI lint additions

Three new lint rules, scoped tightly to avoid scope creep:

#### 3.2.1 `audit_logs` UPDATE / DELETE allowlist

New file `tool/audit_logs_mutation_lint.dart` (sibling to `rls_policy_lint.dart`). Allowlist file `tool/audit_logs_mutation_lint_allowlist.txt` lists the explicit migration filenames where `UPDATE audit_logs SET ...` or `DELETE FROM audit_logs WHERE ...` is approved.

Initial allowlist:

```
# Approved sites where UPDATE / DELETE on public.audit_logs is permitted.
# Each entry must point at a migration file and carry a rationale comment.
# Adding to this file requires explicit operator approval (auth-critical surface).

# A7 retrospective grandfather: business_date backfill is hash-chain-safe
# because business_date is not part of the canonical payload formula at
# the time of apply. Do not extend.
db/migrations/202605131010_admin_audit_logs_business_date.sql
```

Lint reads every `*.sql` file under `db/migrations/**` and `tool/**` and `lib/**`, parses for the regex `(?i)(update|delete\s+from)\s+(public\.)?audit_logs\b`, and:

- If the match is inside a `CREATE OR REPLACE FUNCTION` body that is *not* a runtime trigger (i.e., the function is owned by `forge_admin` and called from a migration-time DO block), and the function body documents the rationale, pass.
- Otherwise the match must originate from a file listed in the allowlist; if not, fail with the exact line and a remediation pointer to this audit doc.

Edge cases to handle in the lint:

- Allow `delete from cron.job` — fully-qualified path differs.
- Allow comments mentioning `update audit_logs` (string-match must require SQL context, not comment context). Pragmatic approach: strip `--`-comments and `/* */` blocks before matching, like `rls_policy_lint.dart` already does.
- Allow `audit_chain_anchors` (`audit_logs` substring guard must require word boundary).

Cost estimate: ~150 LOC Dart + ~30 LOC tests, mirroring `rls_policy_lint.dart` structure.

#### 3.2.2 `--require-expand-contract` on migration drift scanner

Extend `tool/migration_drift_scanner.dart` with a new flag. When set, the scanner reads every `*.sql` file under `db/migrations/` (not `post_deploy/`) and flags any file that contains **both** of:

- An `ALTER TABLE ... ADD COLUMN ... NOT NULL` (with or without `DEFAULT`), AND
- An `UPDATE ... SET ...` against the same table, AND/OR
- An `ALTER TABLE ... ALTER COLUMN ... SET NOT NULL` after an `ADD COLUMN ... NULL`.

Failure message: *"file <X> combines schema expand + backfill + contract in one migration. Split into `<file>_add.sql` (in `db/migrations/`), `<file>_backfill.sql` and/or `<file>_contract.sql` (in `db/migrations/post_deploy/`)."*

The lint should NOT fire when:

- The whole migration is a `CREATE TABLE` (no pre-existing data).
- The UPDATE is against a table also created in the same file (no pre-existing data).
- The file matches an `--allow-monolithic` allowlist (the same retrospective grandfather pattern as 3.2.1; expected to be small).

Cost estimate: ~80 LOC Dart on top of the existing scanner.

#### 3.2.3 audit_logs DDL guardrail (chain hash columns)

Smaller, narrower lint: any `*.sql` file containing the regex `alter\s+table\s+(public\.)?audit_logs\s+drop\s+column\s+(row_hash|prev_row_hash|chain_date|operator_id)` fails unconditionally. No allowlist. Rationale: the chain is mathematically broken by removing these columns; there is no scenario where this is the right call. If the chain itself needs to retire, that's a `tool/cutover/`-driven schema replacement, not a migration.

Cost estimate: ~30 LOC Dart.

### 3.3 Migration template / runbook updates

The R2 brief calls for a canonical chunked-backfill snippet. Proposed contents (to live in a new `db/migrations/post_deploy/TEMPLATE.sql.example` or in `runbooks/expand_contract_migration_runbook.md`):

```sql
-- Post-deploy contract phase for <ticket>.
-- Mirror file: db/migrations/<timestamp>_<name>_add.sql.
--
-- Pre-conditions before apply:
--   * The corresponding feature deploy is live on the target environment.
--   * `<column>` is populated for every new row by the writer code.
--   * Backfill verifier confirmed `select count(*) from <table> where <column> is null = 0`.
--
-- Rollback posture:
--   * Forward-only. To revert, write a new migration that reverses the change.

begin;

-- Chunked backfill template (skip if backfill ran inline in the expand phase).
do $$
declare
  v_rows int := 1;
begin
  while v_rows > 0 loop
    with batch as (
      select <pk_columns>
        from <schema>.<table>
       where <column> is null
       limit 50000
       for update skip locked
    )
    update <schema>.<table> t
       set <column> = <derivation>
      from batch
     where t.<pk_columns> = batch.<pk_columns>;
    get diagnostics v_rows = row_count;
    raise notice 'backfill <table>.<column>: % rows', v_rows;
    commit;
    perform pg_sleep(0.05);  -- pacing, avoids replica lag spikes
  end loop;
end;
$$;

-- Contract phase. Only safe once the backfill is verified complete.
alter table <schema>.<table>
  alter column <column> set not null;

commit;
```

Runbook updates needed:

- `runbooks/phase_9_production1_migration_apply_runbook.md` — add a "Post-deploy migrations" section. Production1 apply gate: standard migrations apply at deploy time; post-deploy migrations apply via a separate operator-triggered runbook step after the feature is verified in production.
- `scripts/postgres_staging_setup.ps1` — second sentinel block `# MIGRATION_CUTOFF_POST_DEPLOY_BEGIN` / `_END` for the latest `post_deploy/` filename. The cutoff lint extends to enforce both sentinels.
- `tool/migration_drift_scanner.dart:16-23` watched-docs list — add `docs/archive/_decisions/post_codex_wave_decisions_2026-05-12.md` + `docs/archive/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md`.

### 3.4 Migration sequencing for in-flight schema changes

The addendum identifies two Lane B feature lanes that will hit the new convention immediately:

- **B8 ltree on hierarchy tables** — adds an `ltree` column on `org_units` (and possibly `locations`) for fast descendant-set joins. Schema change posture: add nullable `ltree` column → backfill from existing parent pointers in chunks → add `gist` index `CONCURRENTLY` (not allowed inside a transaction). This already splits naturally into expand (CREATE INDEX CONCURRENTLY does not need `post_deploy/`; `ADD COLUMN ltree NULL` + the GiST index are both expand-phase) + post-deploy (the backfill loop, then the NOT NULL flip if the column is required).
- **B10 vendor_applicability** (addendum A6) — single new table with discriminator + JSONB + temporal columns. Posture: pure expand (`CREATE TABLE`). No `post_deploy/` content unless a follow-up slice retires the three legacy lists (`docs/_execution/...` calls them out).

Lane B drafts the migration SQL for both. This audit only commits Lane B to the new convention; it does not draft the actual SQL.

**A2 Default Roles catalog versioning** (addendum A2):

- Expand phase: new table `default_role_catalog_versions` (mirror `corpus_versions` shape) + `business_default_role_catalog_pin` (per-business pinned version pointer).
- No post-deploy phase needed for the initial cutover (table is empty at apply).
- Subsequent catalog edits: each edit creates a new `default_role_catalog_versions` row; per-business pin is operator-driven (read-time join), not migration-driven.

---

## Section 4 — A7: Frameworks current state

### 4.1 Framework inventory table

| File | Path | Lines | Last updated | Stated purpose |
|---|---|---|---|---|
| README | `docs/frameworks/README.md` | 20 | 2026-05-11 (or earlier) | Index; one paragraph + lists. |
| Feature Implementation Lens Audit | `docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` | 520 | 2026-05-08 | 14-lens checklist for any meaningful change. Most polished + most recent. |
| UX Adjustment | `docs/frameworks/UX_ADJUSTMENT_FRAMEWORK.md` | 529 | 2026-05-05 | Repeatable prompt + execution guide for UX copy / layout / nav / button polish. |
| Performance | `docs/frameworks/PERFORMANCE_FRAMEWORK.md` | 464 | 2026-05-03 | Performance audits + perf-only optimization passes. |
| Mobile + Web Console E2E | `docs/frameworks/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md` | 498 | 2026-05-03 | Live acceptance / Browser Use / mobile device QA. |
| Deploy | `docs/frameworks/deployFramework.md` | 332 | 2026-05-08 | Deploy / redeploy / preview / staging / production / Cloud Run / CORS / rollback. |

**Naming inconsistency.** Five files use `SCREAMING_SNAKE_CASE_FRAMEWORK.md`; `deployFramework.md` uses `camelCase`. Cosmetic but the README references the inconsistency (see §4.4).

### 4.2 Cross-reference graph

Edges where one framework explicitly cites another (extracted by reading section headings):

| From | To | Where |
|---|---|---|
| `FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` Lens 9 | `UX_ADJUSTMENT_FRAMEWORK.md` | `:307-322` "Apply the UX Adjustment Framework for visible changes." |
| `FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` Lens 10 | `PERFORMANCE_FRAMEWORK.md` | `:323-349` "Apply the Performance Framework when user-facing or runtime-sensitive." |
| `MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md` "Relationship To Other Docs" | `PERFORMANCE_FRAMEWORK.md`, `slice_runtime_acceptance_contract.md`, `runbooks/browser_use_codex_acceptance_workflow.md`, `runbooks/admin_console_browser_qa_runbook.md` | `:33-44`. |
| `deployFramework.md` | (no explicit framework→framework citation found) | — |
| `UX_ADJUSTMENT_FRAMEWORK.md` | (no explicit framework→framework citation found) | — |
| `PERFORMANCE_FRAMEWORK.md` | (no explicit framework→framework citation found) | — |

**Graph shape:** the Lens framework is the hub (cites UX + Perf). E2E cites Perf. Deploy / UX / Perf are leaves with no outbound citations. README is the discovery index but only names two frameworks explicitly (Feature Implementation Lens) and tags the other three as "legacy framework docs currently live at the docs root and remain authoritative until moved by an explicit doc-hygiene slice" — which is *stale* because all three are already in `docs/frameworks/` (the README was written before the move completed, see `docs/frameworks/README.md:14-21`).

### 4.3 Adoption signal

Reference count outside the frameworks/ directory itself (filename grep, MD files only):

| Framework | Total refs (`-c`) | Files referencing | Adoption pattern |
|---|---|---|---|
| `FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` | 7 refs / 6 files | `CLAUDE.md`, `PROJECT_TRACKER.md`, `docs/README.md`, `docs/CODEX_PROMPT_GENERATION_STANDARD.md`, `docs/archive/_execution/admin_hierarchy_ux_cleanup/README.md`, plus its own README. | Most adopted. Quoted from CLAUDE.md (`:39`) as the canonical pre-feature check. |
| `UX_ADJUSTMENT_FRAMEWORK.md` | 16 refs / 14 files | PROJECT_TRACKER, README, CODEX_PROMPT_GENERATION_STANDARD, 3 walkthroughs (`11A.12/13/14`), 4 execution docs, parity contract. | Well-adopted in execution docs + walkthroughs. |
| `PERFORMANCE_FRAMEWORK.md` | 15 refs / 11 files | PROJECT_TRACKER, README, CODEX_PROMPT_GENERATION_STANDARD (`x3`), 2 execution docs, plus 2 references from inside other frameworks (E2E + deploy). | Well-adopted. |
| `MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md` | 13 refs / 11 files | PROJECT_TRACKER (`x2`), README, 4 execution docs, plus 2 self-refs. | Well-adopted in 2026-05 execution docs. |
| `deployFramework.md` | 4 refs / 4 files | PROJECT_TRACKER, README, CODEX_PROMPT_GENERATION_STANDARD, 1 execution doc. | Least-adopted. Likely under-cited rather than under-used. |

**Reference from CLAUDE.md (the single document at Authority Order item 6):** `CLAUDE.md:39` cites only `FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md`. The other four are not referenced from CLAUDE.md at all. PROJECT_TRACKER.md:33-36 cites all four (deploy / perf / UX / E2E) as "applied per slice when relevant"; CODEX_PROMPT_GENERATION_STANDARD.md:31-42 cites all five.

### 4.4 Duplication risks

**Single-source-of-truth violations found:**

1. **`docs/PERFORMANCE_FRAMEWORK.md` vs `docs/frameworks/PERFORMANCE_FRAMEWORK.md`.** `CODEX_PROMPT_GENERATION_STANDARD.md:33-37` lists both as separate authorities ("for performance, scale, mobile slices..." and again "for performance, scale, mobile responsiveness..."). The top-level `docs/PERFORMANCE_FRAMEWORK.md` does NOT exist as a file (verified by Glob — only the `docs/frameworks/` copy exists). This is a **broken reference in the prompt-generation standard**.
2. **Carve-out language in `FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` Lens 6 vs CLAUDE.md "RLS-Ready Schema".** Lens 6 talks about operator owner / location manager / F&F support / forge admin role taxonomy; CLAUDE.md does not enumerate the roles but binds the operator-scoped repository pattern + RLS posture. Not duplication — Lens 6 is procedural ("what to check"), CLAUDE.md is doctrinal ("what is true"). Boundary is clean.
3. **Demo-mode carve-out enumeration.** CLAUDE.md "Demo Mode" section (`:121-141`) lists the three reader-side carve-outs explicitly. No framework duplicates this list. Clean.
4. **`UX_ADJUSTMENT_FRAMEWORK.md` "Backend Bug Rule" (`:379-398`) vs `FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` Lens 9 (`:307-322`).** Lens 9 says "apply the UX Adjustment Framework", UX framework says "fix a backend wiring bug discovered during UX testing when the bug is named, scoped, and covered by focused tests." Compatible — Lens 9 calls forward; UX framework defines the rule. No duplication.
5. **`deployFramework.md` "Database And Startup Rule" (`:121-165`) vs `FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` Lens 8 "Background Workers, Deploy, Startup, And Health" (`:277-301`).** Two views of the same surface; the deploy framework is operational ("how to deploy without breaking the DB pool"), Lens 8 is review ("did the change move startup costs around correctly"). Compatible.
6. **`MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md` "Browser Use Rule" (`:72-91`) vs `runbooks/browser_use_codex_acceptance_workflow.md`.** E2E framework cites the runbook (`:39`). Runbook is the action manual; framework is the doctrine. Clean.

**Single bona-fide duplication / drift risk:**

- `docs/frameworks/README.md:14-21` says the other four frameworks "legacy framework docs currently live at the docs root and remain authoritative until moved by an explicit doc-hygiene slice." This is **stale**. The move already happened. The README needs updating.

### 4.5 Gaps — doctrines with no framework doc

Concerns that have implicit doctrine spread across CLAUDE.md / contracts / runbooks but no consolidated framework doc:

| Gap | Where doctrine currently lives | Why it deserves a framework |
|---|---|---|
| **Migration / schema-change framework** | CLAUDE.md "Workflow" (`:37`) cites `tool/migration_drift_scanner.dart`; `runbooks/phase_9_production1_migration_apply_runbook.md`; the addendum A7 expand-contract rule. | A5 is *exactly* this gap. Schema-change discipline is currently 6 lines in CLAUDE.md + tooling + a planned addendum. Worth a framework. |
| **Testing framework** | CLAUDE.md "Testing" (`:87-91`) — 4 lines: "Smallest set that proves the seam." `docs/KNOWN_FAILING_TESTS.md` for the failure registry. | Each slice author makes ad-hoc decisions. Codified rules would reduce reviewer ping-pong. Not urgent. |
| **Contract-doc maintenance** | CLAUDE.md "Phase Doc Hygiene" (`:93-97`) — 3 bullets. `docs/CODEX_PROMPT_GENERATION_STANDARD.md`. | The audit-acceptance flip rule (`docs/_audits/code_health/...`) is enforced via memory but not framework. Worth pulling into the framework folder if scope warrants. |
| **Prompt-generation hygiene** | `docs/CODEX_PROMPT_GENERATION_STANDARD.md` lives at docs root, not under `docs/frameworks/`. It is in spirit a framework. | The two-block prompt shape, the authority-read order, the agent-led slice contract, the audit doc spawn rules — all framework material. Naming inconsistent. |
| **Audit chunking / multi-agent investigation** | `docs/_audits/audit_chunking_playbook.md` (referenced from memory). | The 7-chunks-sub-agents-no-big-bang-merges pattern is doctrine. Worth co-locating with frameworks. |
| **Observability / audit-log writing** | CLAUDE.md "Proxy & API Conventions" + audit_logs migrations + `docs/_audits/code_health/c_email_notification_scenario_inventory.md`. | Not yet framework-ready; doctrine is still settling. Skip for now. |

The two clearest gap-fills if A7 ships a fuller index:

1. **Schema change framework** (this audit's A5 work → produces the doc).
2. **Prompt generation moves into `docs/frameworks/`**: rename `docs/CODEX_PROMPT_GENERATION_STANDARD.md` → `docs/frameworks/PROMPT_GENERATION_FRAMEWORK.md`. The standard is already framework-shaped (sections + checklists + prompt template).

---

## Section 5 — A7: Consolidation plan

### 5.1 Proposed consolidated `docs/frameworks/README.md` shape

Current README is 20 lines, ~half stale. Proposed shape (~80 lines):

```markdown
# Forge & Flow Frameworks

Status: Active
Updated: <date of A7 ship>

Repeatable execution frameworks. Apply per slice based on the kind of change.
Frameworks are NOT contracts — they are procedural guides. When a framework
contradicts a contract or CLAUDE.md, the contract / CLAUDE.md wins (Authority
Order #2-3 over #6).

## Discovery — pick by question

| If your slice is about… | Apply this framework |
|---|---|
| Any non-trivial code/UX/runtime change | `FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` — 14-lens deep audit (hub) |
| Visible labels, layout, nav, copy | `UX_ADJUSTMENT_FRAMEWORK.md` |
| Latency, polling, large lists, bundle size | `PERFORMANCE_FRAMEWORK.md` |
| Browser Use / device QA / live acceptance | `MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md` |
| Cloud Run, preview, staging, production rollout | `deployFramework.md` |
| Schema change, migration, backfill, RLS | `SCHEMA_CHANGE_FRAMEWORK.md` (new — ships with A5) |
| Writing a Codex / Claude execution prompt | `PROMPT_GENERATION_FRAMEWORK.md` (renamed from `docs/CODEX_PROMPT_GENERATION_STANDARD.md`) |

The Feature Implementation Lens framework cites UX, Performance, and the new
Schema Change framework at the relevant lenses. Use Lens framework first for
multi-surface work; drill into the others as Lens 9 / 10 / 3 / 8 directs.

## Cross-reference graph (high-level)

- Lens framework → UX (Lens 9), Performance (Lens 10), Schema Change (Lens 3),
  Deploy (Lens 8), E2E (Lens 12).
- E2E framework → Performance, `slice_runtime_acceptance_contract.md`, Browser
  Use runbook, admin console QA runbook.
- Schema Change framework → CLAUDE.md "RLS-Ready Schema", hardening contract,
  audit_logs hash-chain rule.

## Frameworks index

(One-paragraph summary per framework, lifted from each file's header.
~5 lines each.)

## Relationship to CLAUDE.md and contracts

Frameworks codify "how we do it". Contracts codify "what's true". CLAUDE.md
binds both. If a framework references a doctrine, the doctrine source wins.

Frameworks do NOT replace:
- `CLAUDE.md` (durable repo rules).
- `docs/contracts/**` (Tier-2 contracts).
- Authority Order docs the active prompt names.

## Versioning

Frameworks update in place; each carries a `Last updated:` line. Major
restructures (renumbered sections, reordered lenses) get a brief change-log
entry at the top of the file.
```

### 5.2 Per-framework recommendations

| File | Action | Rationale |
|---|---|---|
| `FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` | **Keep + add Lens 3 cross-ref to new Schema Change framework.** | Current Lens 3 ("Data Model, Migration, And RLS", `:129-156`) is procedural ("check the migration order"). Adding "Apply the Schema Change framework for schema-bearing slices" alongside `:307-322`/`:323-349`'s pattern would complete the hub-spoke shape. |
| `UX_ADJUSTMENT_FRAMEWORK.md` | **Keep as-is.** | 529 lines, well-structured, well-adopted. Optionally trim §"Carry-Forward Lessons" (`:514-529`) which is anecdotal. |
| `PERFORMANCE_FRAMEWORK.md` | **Keep as-is.** | 464 lines, well-structured, well-adopted. |
| `MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md` | **Keep as-is.** | 498 lines. Browser Use rule (`:72-91`) is operationally important. |
| `deployFramework.md` | **Rename to `DEPLOY_FRAMEWORK.md`** for naming parity. | Cosmetic. Bumps reference count across PROJECT_TRACKER + CODEX_PROMPT_GENERATION_STANDARD. |
| `README.md` | **Replace with §5.1 shape.** | Current 20-line README has stale "legacy framework docs currently live at the docs root" line. |

### 5.3 New framework docs to create

| New framework | Source material | Estimated size |
|---|---|---|
| `SCHEMA_CHANGE_FRAMEWORK.md` | A5 deliverables; absorbs the expand-contract template (§3.3); names the three new lints (§3.2); cites CLAUDE.md "RLS-Ready Schema" and the audit_logs hash chain rule. | ~250 lines |
| `PROMPT_GENERATION_FRAMEWORK.md` | Move from `docs/CODEX_PROMPT_GENERATION_STANDARD.md` to `docs/frameworks/PROMPT_GENERATION_FRAMEWORK.md`. Content already framework-shaped. | (already exists — 0 new content; the move is the work) |

Optional follow-ups (NOT in initial A7 scope; named for tracking):

- `TESTING_FRAMEWORK.md` — codify the "smallest set that proves the seam" rule with examples. Defer until a concrete pain point surfaces.
- `AUDIT_CHUNKING_FRAMEWORK.md` — co-locate the 7-chunks / sub-agents / no-big-bang-merges playbook. Defer; the playbook works as-is from memory.

### 5.4 CLAUDE.md cross-reference cleanup

CLAUDE.md currently cites only the Lens framework (`:39`) and the prompt-generation standard (`:35`). The other four frameworks are cited from PROJECT_TRACKER and CODEX_PROMPT_GENERATION_STANDARD but not from CLAUDE.md. Two ways to fix:

- **Option A (minimal):** add a single line under "Workflow" pointing to `docs/frameworks/README.md` as the single discovery surface. CLAUDE.md stays under 150 lines.
- **Option B (explicit):** add a "Frameworks" sub-section listing each by name. CLAUDE.md grows ~10 lines.

Recommend Option A. CLAUDE.md is already at Authority Order item 6; adding framework-specific links here would invert the doctrinal weight. The README is the right discovery layer.

Broken-link cleanup needed in `docs/CODEX_PROMPT_GENERATION_STANDARD.md:33-37` — the two entries pointing at `docs/frameworks/PERFORMANCE_FRAMEWORK.md` and `docs/PERFORMANCE_FRAMEWORK.md` are redundant; the latter file does not exist. Fix in the same slice that renames CODEX_PROMPT_GENERATION_STANDARD.md → `PROMPT_GENERATION_FRAMEWORK.md`.

---

## Section 6 — Execution slices

Five slices, sequenceable. A5 and A7 work can run in parallel after slice A5/A7-0.

| Slice | Scope | Files | Dep | Size |
|---|---|---|---|---|
| **A5/A7-0** | Land this audit doc + addendum cross-refs. No code. | `docs/_audits/code_health/a5_schema_versioning_and_a7_frameworks.md` (this file). | none | XS (1 file) |
| **A5-1** | Create `db/migrations/post_deploy/` directory (empty + `.gitkeep` + `README.md`). Extend `scripts/postgres_staging_setup.ps1` with the second `MIGRATION_CUTOFF_POST_DEPLOY_*` sentinel block. Extend `tool/migration_cutoff_lint.dart` to enforce both sentinels. | `db/migrations/post_deploy/` (new), `scripts/postgres_staging_setup.ps1`, `tool/migration_cutoff_lint.dart`, `test/migration_cutoff_lint_test.dart` (extend). | A5/A7-0 | M (5 files, ~200 LoC) |
| **A5-2** | Implement `tool/audit_logs_mutation_lint.dart` + allowlist file (§3.2.1) + DDL guardrail (§3.2.3). Add to CI workflow. | `tool/audit_logs_mutation_lint.dart` (new), `tool/audit_logs_mutation_lint_allowlist.txt` (new), `.github/workflows/*.yml` (CI wire), `test/audit_logs_mutation_lint_test.dart`. | A5-1 | M (4 files, ~250 LoC) |
| **A5-3** | Extend `tool/migration_drift_scanner.dart` with `--require-expand-contract` (§3.2.2). Update `docs/POST_HARDENING_FOLLOWUPS.md` watched-docs list. Author `docs/frameworks/SCHEMA_CHANGE_FRAMEWORK.md` + expand-contract template + runbook update. | `tool/migration_drift_scanner.dart`, `runbooks/expand_contract_migration_runbook.md` (new), `docs/frameworks/SCHEMA_CHANGE_FRAMEWORK.md` (new), `test/migration_drift_scanner_test.dart`. | A5-1 | L (4 files, ~400 LoC + ~300 lines of prose) |
| **A7-1** | Rename `docs/frameworks/deployFramework.md` → `DEPLOY_FRAMEWORK.md`. Replace `docs/frameworks/README.md` with §5.1 shape. Move `docs/CODEX_PROMPT_GENERATION_STANDARD.md` → `docs/frameworks/PROMPT_GENERATION_FRAMEWORK.md`. Fix the duplicated reference in the moved file (`:33-37`). Add Lens 3 cross-ref in `FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` to the new Schema Change framework. Update CLAUDE.md "Workflow" with single discovery-surface pointer (Option A from §5.4). | 5-6 files. | A5/A7-0; references A5-3 if Schema Change framework is in the same wave. | M (5-6 files, mostly prose + path-rewrites) |

Sequencing recommendation: ship A5/A7-0 (this doc) first as a Codex-reviewable plan. Then run A5-1 + A7-1 in parallel worktrees (no overlap — one is `db/` + `tool/` + `scripts/`, the other is `docs/`). Then A5-2 and A5-3 sequentially (A5-3 cross-references A5-2's lint surface).

Auth-critical / RLS-touching / schema-touching gate: per CLAUDE.md "Agent-Led Slices" rule, **A5-2 and A5-3 both require explicit operator approval before merge** because they touch the audit_logs mutation surface and the migration apply pipeline.

---

## Section 7 — What was NOT audited

Explicit boundary against scope drift:

- **Not audited: scaffold patterns** — that's A2 (Wave A2 expanded scope per addendum C4). This audit assumes scaffolds elsewhere are A2's problem.
- **Not audited: performance** — that's A4 (per addendum) / and the Performance Framework itself. No performance-of-migrations analysis here.
- **Not audited: Lane B feature migrations.** Lane B drafts the SQL for B8 ltree + B10 vendor_applicability. This audit provides the convention they must follow (§3.4), nothing more.
- **Not audited: the Codex active-wave admin hierarchy slices.** Per `PROJECT_TRACKER.md:1-17`, admin hierarchy lane is excluded from the audit wave.
- **Not audited: the actual Default Roles catalog membership (A2 sub-decision).** Out-of-scope per `post_codex_wave_decisions_2026-05-12.md:39`.
- **Not audited: contract-doc maintenance, testing strategy, audit-log writing.** Named as A7 gaps in §4.5 but not filled here. Each is a candidate framework if pain warrants.
- **Not modified: any code, migration, framework doc, contract, or tracker.** This is a planning artifact only.
- **Not run: dart analyze, tests, or migrations.** Per the audit prompt, no verification work.

---

## Appendix — Findings summary (for quick reference)

| Metric | Value |
|---|---|
| Total migrations | 116 (flat `db/migrations/`) |
| `post_deploy/` directory exists | **No** |
| Destructive migrations (DROP COLUMN / RENAME COLUMN / DROP TABLE) | 2 (both with idempotent guards + zero-row context at apply) |
| Single-file expand+backfill+contract violations | 3 (usage_caps `_c_`, business_date denorm, audit_logs business_date) |
| `UPDATE audit_logs` callsites | **1** (`db/migrations/202605131010_admin_audit_logs_business_date.sql:14`) |
| `DELETE FROM audit_logs` callsites | 0 |
| `DROP COLUMN audit_logs.<chain_hash_col>` callsites | 0 |
| Frameworks under `docs/frameworks/` | 5 (+ README, 6 total) |
| Frameworks referenced from CLAUDE.md | 1 (Feature Implementation Lens) |
| Stale lines in `docs/frameworks/README.md` | `:14-21` (claims four frameworks "live at the docs root") |
| Broken framework reference in `docs/CODEX_PROMPT_GENERATION_STANDARD.md` | 1 (`docs/PERFORMANCE_FRAMEWORK.md` — file does not exist) |
| Doctrine gaps with no framework | 5-6 (schema change, prompt generation, testing, contract maintenance, audit chunking, observability) |
| New framework docs A7 should add | 2 (Schema Change; Prompt Generation rename) |
| Proposed execution slices | 5 (A5/A7-0, A5-1, A5-2, A5-3, A7-1) |
