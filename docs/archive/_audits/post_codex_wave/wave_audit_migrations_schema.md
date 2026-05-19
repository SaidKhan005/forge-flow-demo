# Wave Audit — Migrations + Schema

**Master tip:** `63b67753` (origin/master HEAD; worktree was one commit behind at `63ec00d6`, all wave analysis performed against `origin/master`).
**Auditor:** orchestrator-dispatched read-only agent (2 of 8) — Migrations + Schema dimension.
**Scope window:** every migration added to `db/migrations/` from `2026-04-28` onward (lex-prefix `>= 202604280000`).
**Wave-scope file count:** 111 top-level `db/migrations/*.sql` files + the `db/migrations/post_deploy/` directory (currently `README.md` + `.gitkeep` only; no contract-phase migrations have been moved there yet).

## Verdict

`clean-with-findings`

The wave-scope migrations are overwhelmingly well-formed:

- 100% of operator-scoped fact tables that were created in the wave carry `(operator_id, location_id)` or `(operator_id, …)` keys, RLS-enabled at creation, wrapper-only policies (`public.app_current_operator()`, `public.app_current_location()`), tenant-leading B-tree indexes, and explicit `REVOKE ALL FROM public` + `service_role` + `forge_admin` grants.
- Every timestamp column in wave-scope migrations is `timestamptz` (the bare string `timestamp` only ever appears inside comment lines or as part of `TIMESTAMP WITHOUT TIME ZONE` banned-token reminders).
- The hash-chained `audit_logs` UPDATE allowlist holds exactly one entry (`202605131010_admin_audit_logs_business_date.sql`) and exactly one matching UPDATE statement exists in the wave-scope migrations. Lint coherent.
- Cutoff monotonicity holds: the newest migration on master (`202605131900_c_2_d_vendor_sync_outage_state.sql`) is also the cutoff declared in `scripts/postgres_staging_setup.ps1` between the `MIGRATION_CUTOFF_BEGIN/END` sentinels, and that filename is mirrored verbatim across all 5 of the doc surfaces named in the prompt (`POST_HARDENING_FOLLOWUPS.md`, `phase_11A_operations_console_plan.md`, `phase_9_execution_backlog.md`, `runbooks/phase_9_production1_migration_apply_runbook.md`, `scripts/postgres_staging_setup.ps1`).

Findings that warrant action:

1. **Migration-queue narrative drift** between `runbooks/phase_9_production1_migration_apply_runbook.md` and `docs/POST_HARDENING_FOLLOWUPS.md`: the followups doc declares 46 pending migrations and lists 46 table rows; the runbook narrative says 45 in two places and is missing the `202605070400_phase_8_notification_preferences.sql` entry from its expanded `Pending follow-up scope` bullet list.
2. **One ALTER COLUMN TYPE migration in wave scope** (`202605020300_phase_9_firebase_uid_text.sql`) directly violates the prompt's banned-shape rule "No `ALTER COLUMN TYPE`". It was applied to staging + Production1 on 2026-04-29 as part of the first Phase 9 batch (per the runbook's apply history), so the operational impact is sunk — but the shape is a precedent record worth flagging.
3. **Lock + timeout guardrail adoption is partial.** Only 5 of the 111 wave-scope migrations include `set local statement_timeout = '30s'` + `set local lock_timeout = '5s'`. The convention only firmed up around the late-cohort C-lane slices (PR 599 / 626 / 631) — early migrations lacked the idiom entirely. Codifying this in `docs/CODEX_PROMPT_GENERATION_STANDARD.md` would close the consistency gap going forward.
4. **`202605131010_admin_audit_logs_business_date.sql` performs `ALTER COLUMN business_date SET NOT NULL` and `UPDATE public.audit_logs SET business_date = chain_date` inline (top-level, NOT in `db/migrations/post_deploy/`)** — both shapes are explicitly called out in `db/migrations/post_deploy/README.md` as belonging in post-deploy. The migration ships on the same day (2026-05-13) as the post-deploy convention itself (per PR #527 A5+A8), so it predates the convention or co-landed with it. The UPDATE is on the allowlist; the SET NOT NULL is not yet broken out.
5. **Advisory-lock seed rows in `202605070200_audit_anchor_advisory_lock_infra.sql` + `202605080900_oauth_refresh_advisory_lock.sql`.** The schema migrations themselves seed lock-id rows in `audit_anchor_advisory_locks` — no `pg_advisory_lock(...)` call in DDL/DML, so the prompt's banned-token rule for migrations is technically satisfied. But the underlying advisory-lock pattern conflicts with `~/.claude/projects/.../memory/project_v1_lean_cut_2_2026_05_03.md`, which lists "OAuth refresh advisory lock" under "What got pulled back" with the trim verdict "Drop. One cron instance + low frequency = zero contention at V1 scale." The migration was authored after that lean-cut decision and the matching code site (`lib/services/integration/oauth_refresh_cron.dart`) carries the comment `pg_advisory_lock is now RESTORED per J4 race fix`. Either the lean-cut memory needs to record the J4 restoration or the migration should be reverted.
6. **`202605080600_phase_8_demo_pending_counter_persisted.sql` adds a CHECK constraint without `NOT VALID` + `VALIDATE` and without an `IF NOT EXISTS` guard on the constraint itself.** Re-application will error on the second pass because `ADD CONSTRAINT … CHECK` is not idempotent when the constraint name already exists. Minor replayability concern.
7. **`202604290100_phase_11A_1_operators_suspended_at.sql` ships without a `begin;` / `commit;` wrapper.** Trivially correct given it's a single `ALTER TABLE … ADD COLUMN IF NOT EXISTS` statement, but inconsistent with the wave's prevailing idiom.

None of the findings represent a production-blocking integrity violation; per-tenant RLS posture, time guardrails, append-only audit_logs grant shape, hash-chain integrity, and the cutoff-lint mirror docs are all in good standing.

## New migrations in wave scope

Sourced from `git ls-tree origin/master db/migrations/` filtered to lex-prefix `>= 202604280000`. Apply-queue status comes from the `Staging` column of `docs/POST_HARDENING_FOLLOWUPS.md` rows 40-85 plus the in-scope+history sections of `runbooks/phase_9_production1_migration_apply_runbook.md`.

**Production1-applied (27 files, 2026-05-03 apply window):**

| # | Migration | Notes |
|---|---|---|
| 1 | `202604280014_phase_9_0sigma_h2_audit_privacy_role.sql` | applied + verified |
| 2 | `202604290000_phase_9_b41_service_principal_issue_permission.sql` | applied + verified |
| 3 | `202604290100_phase_11A_1_operators_suspended_at.sql` | applied + verified |
| 4 | `202604290101_phase_9_hierarchy_access_wiring.sql` | applied + verified |
| 5 | `202604300000_phase_9_mfa_factor_removal_requests.sql` | applied + verified |
| 6 | `202604300001_phase_9_mfa_recovery_request_attempts.sql` | applied + verified |
| 7 | `202604300002_phase_9_mfa_hardening_launch_roles.sql` | applied + verified |
| 8 | `202605010000_phase_11A_3a_corpus_versions_ledger.sql` | applied + verified |
| 9 | `202605010000_phase_11A_4_provider_credentials.sql` | applied + verified |
| 10 | `202605010001_phase_9_b4_role_audit_log_operator_id.sql` | applied + verified |
| 11 | `202605010100_phase_9_0sigma_f_audit_logs_cutover_flag.sql` | applied + verified |
| 12 | `202605020000_phase_11A_b42_proxy_migrations_applied.sql` | applied + verified |
| 13 | `202605020001_phase_11A_3b_graphify_review_audit.sql` | applied + verified |
| 14 | `202605020001_phase_11A_4b_gemini_provider_kind.sql` | applied + verified |
| 15 | `202605020100_phase_11A_b43_cache_telemetry_v2.sql` | applied + verified |
| 16 | `202605020200_phase_11A_4c_kms_rollout_flags.sql` | applied + verified |
| 17 | `202605020300_phase_9_firebase_uid_text.sql` | applied + verified — see Finding 2 |
| 18 | `202605020400_phase_11A_7_feature_flags_admin_columns.sql` | applied + verified |
| 19 | `202605020452_hardening_auth_login_attempts.sql` | applied + verified |
| 20 | `202605020500_hardening_auth_rls_to_wrappers.sql` | applied + verified |
| 21 | `202605021000_phase_hardh_admin_idempotency.sql` | applied + verified |
| 22 | `202605021500_phase_9_0sigma_l_rls_depth.sql` | applied + verified |
| 23 | `202605021600_phase_11A_7_feature_flags_forge_admin_grants.sql` | applied + verified |
| 24 | `202605021700_phase_11A_health_age_graph_bootstrap.sql` | applied + verified |
| 25 | `202605021710_phase_11A_health_age_runtime_grants.sql` | applied + verified |
| 26 | `202605021800_hardening_auth_login_attempts_index_rekey.sql` | applied + verified |
| 27 | `202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql` | applied + verified |

**Plus an earlier batch (15 files, 2026-04-29) covering Phase 9.0Σ.b-k + auth/recovery patches:**

`202604280000_phase_9_0sigma_b_rls_wrappers.sql` … `202604280013_phase_9_audit_actor_kind_live_repair.sql` (sigma slices b through h2 minus h2; recovery_code_attempts; auth_ops_cloud_foundation_grants; audit_actor_kind_live_repair).

**Pending Production1 apply (46 files; the table in `docs/POST_HARDENING_FOLLOWUPS.md:38-85`):**

Two rows applied to staging only (`202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql` + `202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql` — both verified via Browser Use on 2026-05-03/05-04 per the followups doc). The remaining 44 rows are code-ready, with `202605061800_phase_8_first_connection_backfill_jobs.sql` and `202605070000_phase_11W_7_operator_account_fields.sql` carrying an **operator decision pending** label.

Pending tail (newest 12):

| Migration | Status |
|---|---|
| `202605082200_admin_hierarchy_lifecycle.sql` | code-ready |
| `202605121200_admin_hierarchy_scoped_data_polling.sql` | code-ready |
| `202605131000_admin_audit_log_actor_reason_contract.sql` | code-ready |
| `202605131010_admin_audit_logs_business_date.sql` | code-ready — Finding 4 |
| `202605131020_admin_hierarchy_lifecycle_access_hardening.sql` | code-ready |
| `202605131030_b11_1_auth_handoff_codes.sql` | code-ready (B11.1 grandfather cutoff for expand-contract gate) |
| `202605131400_b11_2_auth_step_up_challenges.sql` | code-ready |
| `202605131500_b10_1_vendor_applicability.sql` | code-ready |
| `202605131500_b5_b_catalog_tri_mirror.sql` | code-ready |
| `202605131600_b2_1_default_role_catalog_versions.sql` | code-ready |
| `202605131700_c_1a_email_event_provider_id.sql` | code-ready (PR #599 audited) |
| `202605131800_c_7a_recovery_codes_viewed_at.sql` | code-ready (PR #626 audited) |
| `202605131900_c_2_d_vendor_sync_outage_state.sql` | code-ready (PR #631 audited) — current cutoff |

**Wave-scope file count reconciliation:**

- 27 (Production1 batch 2) + 15 (Production1 batch 1) = 42 applied
- 46 pending per `POST_HARDENING_FOLLOWUPS.md`
- Difference vs the 111 wave-scope SQL files = 23 files that are in the wave window but neither in batch 1/2 nor in the followups table. Spot-checking, these are migrations from `202604280000`-`202604280013` (the 15 batch-1 entries are listed by lex starting at `_b_rls_wrappers`; the missing ones are `_c_org_units`, `_e_event_outbox`, `_d_service_principals`, `_f_audit_logs`, `_g_*_a/b/c`, `_h_advisor_conversation_log`, `_i_graph_canonical`, `_j_diskann_install`, `_k_*_a/b/c`, `_recovery_code_attempts`, `_auth_ops_cloud_foundation_grants`, `_audit_actor_kind_live_repair`) — i.e., the batch-1 apply was completed before the followups table started tracking pending state, and those files were rolled into the Production1 baseline as a single chunk on 2026-04-29 (per `runbooks/phase_9_production1_migration_apply_runbook.md:12`).

## Findings

### Finding 1 — Migration-queue narrative drift (P2)

**Files / evidence:**

- `docs/POST_HARDENING_FOLLOWUPS.md:34` declares: `**46 migrations pending Production1 apply** (chronological).` The Markdown table (lines 38-85) contains 46 rows of pending migrations.
- `runbooks/phase_9_production1_migration_apply_runbook.md:52` declares: `Pending follow-up scope (45 migrations; staging status varies, Production1 pending):` The expanded bullet list (lines 54-98) contains exactly 45 bullet entries.
- Set diff between the two lists: `202605070400_phase_8_notification_preferences.sql` is present in the followups doc (row 54) but absent from the runbook bullet list.
- The runbook also has a `Current pending follow-up order:` numbered list (lines 277-295) listing only the first 19 of the 45/46 — this is documented as the next-apply batch, not the full pending queue, and is therefore not part of the drift.

**Impact:** The runbook is the operational reference for Production1 applies; the followups doc is the canonical pending ledger. They MUST agree on the file set. Today they agree on the cutoff filename (`202605131900_c_2_d_…`) but disagree on the file count by one. An operator following the runbook would skip the notification_preferences apply.

**Remedy:** Add the missing bullet to the runbook between lines 65 and 66 (after `…password_history_salt_pepper.sql`) and bump the narrative count from 45 to 46. Single-line patch.

### Finding 2 — ALTER COLUMN TYPE shape in wave scope (P3, historical record)

**File:** `db/migrations/202605020300_phase_9_firebase_uid_text.sql:9-19`

```sql
alter table public.users
  drop constraint if exists users_firebase_uid_key;
alter table public.users
  alter column firebase_uid type text using firebase_uid::text;
alter table public.users
  alter column firebase_uid set default gen_random_uuid()::text;
alter table public.users
  alter column firebase_uid set not null;
alter table public.users
  add constraint users_firebase_uid_key unique (firebase_uid);
```

**Why it matters:** The prompt's banned-token list explicitly names `ALTER COLUMN TYPE`. This migration's header (`Phase 9 MFA production hardening - Firebase UID text repair`) explains the rationale (live Firebase Identity Platform UIDs are arbitrary strings, not UUID-shaped), and the migration was applied to Production1 on 2026-04-29 as part of the first batch — so the operational footprint is fully realized. But the wave-scope rule requires this to be a noted finding.

**Additional shape issues on the same file:**

- No `begin;` / `commit;` wrapper. Each `ALTER TABLE` runs in its own implicit transaction, so a partial apply could leave the table half-converted.
- No `set local lock_timeout` / `statement_timeout` near the top. An `ALTER COLUMN TYPE` on a non-empty `users` table takes an ACCESS EXCLUSIVE lock for the duration of the rewrite — a stalled blocker would freeze every reader.
- `DROP CONSTRAINT … users_firebase_uid_key` followed by `ADD CONSTRAINT … UNIQUE (firebase_uid)` is the unique-index recreation idiom — defensible because `ALTER COLUMN TYPE` invalidates btree comparators that bind directly on uuid representation; but a `CREATE UNIQUE INDEX CONCURRENTLY` + `ALTER TABLE … ADD CONSTRAINT … USING INDEX` path would be the preferred shape on a non-empty table.

**Remedy:** Document this slice in `docs/POST_HARDENING_FOLLOWUPS.md` as the historical precedent for the banned shape so future migrations cite it when proposing a similar widening. No live-DB remediation needed — change is already applied.

### Finding 3 — Lock+timeout guardrail adoption is partial (P3, convention)

**Files / evidence:**

- 5 of the 111 wave-scope SQL files include both `set local statement_timeout = '30s'` and `set local lock_timeout = '5s'`: `202605080600_ops_debt_vendor_credentials_webhook_signing_secret.sql`, `202605131600_b2_1_default_role_catalog_versions.sql`, `202605131700_c_1a_email_event_provider_id.sql`, `202605131800_c_7a_recovery_codes_viewed_at.sql`, `202605131900_c_2_d_vendor_sync_outage_state.sql`.
- The remaining 106 do not. Existing audit docs `pr_599_*`, `pr_626_*`, `pr_631_*` cite the bound timeouts as a checked attribute — adoption appears to have firmed up only after PR #599 (C-1a). Earlier migrations are silent.

**Why it matters:** The prompt names this as a checked shape ("every migration should: `set local statement_timeout` + `set local lock_timeout` near the top"). The CLAUDE.md authority order does not currently bind this idiom anywhere I can find. So the prompt's "every migration should" is aspirational rather than contractually grounded.

**Remedy:** Either (a) record the convention in `docs/CODEX_PROMPT_GENERATION_STANDARD.md` so future slices carry it forward, or (b) loosen the wave audit rule to "every migration touching an existing non-empty table". Today the rule is enforced ad-hoc by reviewer judgment.

### Finding 4 — `audit_logs` migration uses inline UPDATE + SET NOT NULL outside `post_deploy/` (P3)

**File:** `db/migrations/202605131010_admin_audit_logs_business_date.sql:9-26`

```sql
begin;
alter table public.audit_logs
  add column if not exists business_date date null;
update public.audit_logs
   set business_date = chain_date
 where business_date is null;
alter table public.audit_logs
  alter column business_date set not null;
create index if not exists audit_logs_operator_business_date_idx
  on public.audit_logs (operator_id, business_date, occurred_at desc);
comment on column public.audit_logs.business_date is …;
commit;
```

Convention from `db/migrations/post_deploy/README.md:13-19`:

> Use `db/migrations/post_deploy/*.sql` for work that depends on the new writer or reader being deployed and observed first:
> - large or sensitive `UPDATE` backfills;
> - `ALTER COLUMN ... SET NOT NULL` after a verified backfill;
> - `DROP COLUMN`, `DROP TABLE`, or other contract-phase removals;
> - constraint tightening after production evidence says the data is ready.

The migration ships BOTH a sensitive UPDATE backfill (on the hash-chained audit_logs table, no less) AND a `SET NOT NULL` in the same expand-phase top-level file. By the README's own rules, this should split into:

- `db/migrations/202605131010_admin_audit_logs_business_date.sql` (expand-only: ADD COLUMN nullable + index)
- `db/migrations/post_deploy/202605131010_admin_audit_logs_business_date_backfill.sql` (UPDATE backfill)
- `db/migrations/post_deploy/202605131010_admin_audit_logs_business_date_contract.sql` (SET NOT NULL)

**Mitigations:** The UPDATE is the only audit_logs UPDATE in the entire wave, it is in the `tool/audit_logs_update_allowlist.txt` allowlist (operator-approved retroactively per the comment header), and the column was net-new (not part of any pre-existing row_hash payload). So the security impact is bounded.

**Remedy:** Either (a) accept the audit_logs business_date as a co-landed exception (the migration predates or co-lands with the post_deploy convention), or (b) split the migration into the 3-file shape on the next remediation pass. Operator decision.

### Finding 5 — Advisory-lock seed migrations conflict with V1 lean cut #2 record (P2, documentation drift)

**Files:**

- `db/migrations/202605070200_audit_anchor_advisory_lock_infra.sql` — creates `audit_anchor_advisory_locks` table and seeds `('audit_anchor_sweep', 8472001)`.
- `db/migrations/202605080900_oauth_refresh_advisory_lock.sql` — adds `('oauth_refresh_lock', 8472002)` row to the same table.

**Conflict:** `~/.claude/projects/.../memory/project_v1_lean_cut_2_2026_05_03.md` lists "OAuth refresh advisory lock — `pg_advisory_lock` per (operator, vendor)" under the **"What got pulled back"** table with the verdict: `Drop. One cron instance + low frequency = zero contention at V1 scale.` Walkthrough docs `docs/_walkthroughs/8.0.md:283`, `docs/_walkthroughs/8.AL.md:203`, `docs/_walkthroughs/8.TS.md:190` carry the same statement: `**No `pg_advisory_lock` involved at V1 (lean cut 2 trim).**`

The migrations were authored after the lean-cut decision (2026-05-07 + 2026-05-08 vs 2026-05-03), and `lib/services/integration/oauth_refresh_cron.dart` carries the comment `pg_advisory_lock is now RESTORED per J4 race fix`.

**Why it matters:** The schema migrations are technically banned-token-clean (they only seed lock-id rows, no `pg_advisory_lock(...)` call in DDL/DML). But the entire purpose of the rows is to support an application-layer pattern that the lean-cut memory says was pulled back. Either the memory + walkthrough docs are stale, or the migrations should be reverted.

**Audit-doc precedent:** `docs/archive/_audits/post_codex_wave_2026-05-13/pr_584_b2_1_default_role_catalog_audit.md:98` notes `No pg_advisory_lock, no pgmq, no banned items | ✓` — so the audit format DOES expect a pg_advisory_lock check, but the precedent docs only enforce it in NEW migrations, not retrospective ones.

**Remedy:** Operator decision — either (a) record the J4 race-fix restoration in `project_v1_lean_cut_2_2026_05_03.md` (memory + walkthrough docs), or (b) revert `202605080900_oauth_refresh_advisory_lock.sql` and the matching code in `oauth_refresh_cron.dart`. (a) appears to be the live truth.

### Finding 6 — Non-idempotent ADD CONSTRAINT in `phase_8_demo_pending_counter_persisted` (P3)

**File:** `db/migrations/202605080600_phase_8_demo_pending_counter_persisted.sql:23-26`

```sql
alter table public.demo_mode_state
  add column if not exists pending_inserts_count integer not null default 0,
  add constraint demo_mode_state_pending_inserts_count_non_negative
    check (pending_inserts_count >= 0);
```

The `add column if not exists` clause is idempotent; the `add constraint …` clause is NOT — re-running the migration on a host where the constraint already exists fails with `42710 duplicate_object`. The migration's header line 22 claims `Migration is replay-safe: ADD COLUMN IF NOT EXISTS is idempotent.` That claim is incomplete: the constraint piece can break re-application.

**Remedy:** Wrap the `add constraint` in a `DO` block with `EXCEPTION WHEN duplicate_object` (matches the idiom in `202605071800_actor_kind_constraint_consolidation.sql:65-67`), or split the constraint addition into a `NOT VALID` + `VALIDATE CONSTRAINT` pair guarded by `pg_constraint`/`information_schema.table_constraints` lookup. Minor — but the runbook's "Pre-Apply Snapshot → apply" loop assumes idempotency.

### Finding 7 — `202604290100_phase_11A_1_operators_suspended_at.sql` ships without `begin;` / `commit;` (P4)

**File:** `db/migrations/202604290100_phase_11A_1_operators_suspended_at.sql` — full file.

Single `ALTER TABLE … ADD COLUMN IF NOT EXISTS … timestamptz null` + `COMMENT ON COLUMN`. Both statements would normally run inside their own implicit transactions. No correctness problem, but inconsistent with the rest of the wave's `begin;` / `commit;` wrapping idiom.

**Remedy:** Cosmetic; can fold into a future hardening sweep. Not blocking.

## Aggregate observations

- **RLS-Ready Schema discipline is uniformly strong** in operator-scoped tables added during the wave. Sampled `vendor_sync_outage_state`, `leaderboard_scores`, `handoff_codes`, `auth_step_up_challenges`, `vendor_credentials`, `connector_connection`, `service_principals`, `event_outbox`, `audit_logs`, `feature_flags`, `vendor_applicability`, `team_audit_log_export_*`, `phase_8_*_settings`. Every operator-scoped fact table I read carries `(operator_id, location_id)` (or `(operator_id, …)`), composite FK to `public.locations(operator_id, location_id)` where the table needs location binding, wrapper-only policies, operator-leading B-tree indexes, and tight `REVOKE ALL FROM public` + `grant … to service_role, forge_admin` grants.

- **Non-RLS tables added during the wave are uniformly documented as intentional global / forge_admin-only / cluster-wide infra:** `aggregation_state` (forge_admin BYPASSRLS internal infra), `provider_credentials` (global F&F-wide credentials), `corpus_invalidation_events` (global telemetry), `admin_request_idempotency` (per-actor service_role-only), `event_outbox_publish_metrics` (forge_admin only cross-tenant bridge bookkeeping), `event_outbox_retention_sweep_log` (cross-operator sweep log), `audit_anchor_advisory_locks` (cluster-wide constants), `feature_flag_scope_sentinels` (sentinel registry), `default_role_catalog_versions` (F&F-wide global catalog). Each carries a header section justifying the non-RLS posture. Clean.

- **Time guardrails are universal.** Of 354 `timestamptz` occurrences across 60 wave-scope files, every column declaration uses `timestamptz`. The only bare `timestamp` strings appear inside comment text (e.g., `Vendor events that fail timestamp sanity rules…`) or in references to `TIMESTAMP WITHOUT TIME ZONE` as a banned token. Zero `TIMESTAMP WITHOUT TIME ZONE` column declarations.

- **Append-only audit_logs grant shape holds.** `audit_logs` grants in `202604280005_phase_9_0sigma_f_audit_logs.sql` and reaffirmed in `202604280014_phase_9_0sigma_h2_audit_privacy_role.sql` give SELECT + INSERT only; UPDATE and DELETE are explicitly REVOKEd. The one allowlisted UPDATE (`202605131010_admin_audit_logs_business_date.sql`) runs through forge_admin context (the migration runner's deployment role), not through the runtime grant.

- **Tenant-leading B-tree index discipline holds.** Sampled `vendor_sync_outage_state_operator_idx`, `service_principals_operator_id_idx`, `event_outbox_per_tenant_*`, `leaderboard_scores_operator_*_idx`, `handoff_codes_operator_*_idx`, `audit_logs` cluster of indexes — every index leads with `operator_id`. `tool/index_leading_column_lint.dart` exists and is referenced as the enforcer; the rekey migrations (`202605021800_hardening_auth_login_attempts_index_rekey.sql`, `202605061500_hardening_phase_8_email_index_leading_column_rekey.sql`) explicitly bring earlier non-compliant indexes into alignment via `DROP INDEX CONCURRENTLY` + `CREATE INDEX CONCURRENTLY` pairs.

- **Wrapper-only RLS posture is uniform.** Every wave-scope policy body I sampled uses the four `STABLE LEAKPROOF PARALLEL SAFE` wrappers (`public.app_current_operator()`, `public.app_current_location()`, `public.app_current_actor_user()`, plus one I noticed for the actor-kind discriminator). No bare `current_setting('app.*', true)::uuid` reads. `tool/rls_policy_lint.dart` enforces this.

- **CREATE INDEX CONCURRENTLY discipline is consistent on the rekey migrations** but inconsistently applied on initial-creation indexes. New-table `CREATE INDEX` calls inside a `begin;` / `commit;` block are correct for the empty-table case (you cannot use `CONCURRENTLY` inside a transaction block), but the few migrations that add indexes to pre-existing non-empty tables sometimes do NOT use `CONCURRENTLY`. The Phase 8 follow-up rekey migrations correctly use `CONCURRENTLY` and explicitly note in their header that CONCURRENTLY cannot run inside a BEGIN block.

- **post_deploy directory is set up but empty.** `db/migrations/post_deploy/README.md` declares the convention (expand top-level + contract post_deploy). No contract-phase migrations have been moved there yet. The `202605131010_admin_audit_logs_business_date.sql` migration's inline UPDATE + SET NOT NULL would, by the README's rules, belong split into the post_deploy directory — but the migration co-lands with the convention's introduction so this is a coincidence-of-timing issue (Finding 4 above).

- **Migration-cutoff lint is well-wired.** `tool/migration_cutoff_lint.dart` parses the `MIGRATION_CUTOFF_BEGIN` / `_END` sentinels in `scripts/postgres_staging_setup.ps1` and fails when any file in `db/migrations/*.sql` sorts strictly higher than the captured cutoff. Cutoff filename is `202605131900_c_2_d_vendor_sync_outage_state.sql` (script line 49), and the same filename is present verbatim in:
  - `docs/POST_HARDENING_FOLLOWUPS.md:35` + row 85
  - `runbooks/phase_9_production1_migration_apply_runbook.md:10` + lines 98, 108
  - `docs/phases/phase_9/phase_9_execution_backlog.md:149`, 179, 181
  - `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md:155`
  - `scripts/postgres_staging_setup.ps1:49`

  All 5 mirror docs agree. No drift.

- **Duplicate timestamp prefixes are documented and intentional.** Ten timestamp prefixes carry 2-3 files each (e.g. `202604280006_a/b/c` for the usage_caps two-slot triple; `202605060000_mobile_push_notifications.sql` + `…_phase_business_timing_live_schema.sql` for parallel V1 lanes). The runbook (line 303-308) calls out the two pairs that require strict lex ordering. The `202605061700`/`_61701` rename (per runbook narrative lines 144-154) deliberately broke a 3-way prefix collision. Apply ordering is sound.

## Migration queue count audit

**Source-of-truth tally:**

| Surface | Pending count claim | Pending file list size | Cutoff |
|---|---|---|---|
| `docs/POST_HARDENING_FOLLOWUPS.md:34` | 46 | 46 (table rows 40-85) | `202605131900_c_2_d_vendor_sync_outage_state.sql` |
| `runbooks/phase_9_production1_migration_apply_runbook.md:52` | 45 | 45 (bullet list lines 54-98) | `202605131900_c_2_d_vendor_sync_outage_state.sql` |
| `scripts/postgres_staging_setup.ps1:49` | n/a | n/a | `202605131900_c_2_d_vendor_sync_outage_state.sql` |
| `docs/phases/phase_9/phase_9_execution_backlog.md` | n/a | n/a | `202605131900_c_2_d_vendor_sync_outage_state.sql` |
| `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` | n/a | n/a | `202605131900_c_2_d_vendor_sync_outage_state.sql` |

**Set difference (followups − runbook):** `202605070400_phase_8_notification_preferences.sql`

**Verdict:** Cutoff filename agreement: ✓ (5 of 5 mirror docs). Pending count agreement: ✗ — Finding 1 above.

**Note on file `202605070400_phase_8_notification_preferences.sql`:** the migration exists on master, is referenced by `lib/operator_web/screens/settings_notifications_screen.dart`, `tool/advisor_proxy/notification_preferences_routes.dart`, `test/operator_web/screens/settings_notifications_screen_test.dart`, `test/proxy/operator_routes_notification_preferences_test.dart`. It is genuinely code-ready and pending; the runbook entry is the only missing piece.

## Cutoff-monotonicity verification

- Newest file on `origin/master` per `git ls-tree origin/master db/migrations/`: `db/migrations/202605131900_c_2_d_vendor_sync_outage_state.sql`.
- Cutoff line in `scripts/postgres_staging_setup.ps1:49`: `Write-Host '   through 202605131900_c_2_d_vendor_sync_outage_state.sql.'`
- Lex compare: equal. No migration on master sorts strictly higher than the cutoff.
- `tool/migration_cutoff_lint.dart` would pass against `origin/master`.

**Verdict:** ✓ cutoff is the newest by lex order on master.

## Authority anchors

- **CLAUDE.md (`Authority Order` item 6)** — Hard Promises HP #4 per-operator isolation; "RLS-Ready Schema" section (operator-scoped fact tables include `(operator_id, location_id)` + RLS policy from creation; tenant-leading B-tree indexes; `STABLE LEAKPROOF PARALLEL SAFE` wrapper functions); "Time Guardrails" section (TIMESTAMPTZ in operator-scoped tables; `TIMESTAMP WITHOUT TIME ZONE` banned); "Proxy & API Conventions" (extensions allowlist; pgcrypto, pg_partman, pg_cron, AGE, pgvector, pg_diskann, pg_stat_statements; pgmq NOT available; service principals `sp:`-prefixed; hash-chained audit log).
- **`docs/contracts/hardening_rls_and_repository_pattern_contract.md`** — `OperatorScopedRepository<T>` as primary defense; RLS as backup; wrapper-only policy bodies; `SET LOCAL` transaction-scoped tenant injection.
- **`docs/contracts/phase_7_55_time_boundary_contract.md`** Rule 11 — TIMESTAMPTZ source-truth + denormalized DATE business_date columns; write-once denormalization via IANA converter.
- **`db/migrations/post_deploy/README.md`** — Expand-top-level / contract-post-deploy convention; named operations that belong in post-deploy: large UPDATE backfills, ALTER COLUMN SET NOT NULL, DROP COLUMN / DROP TABLE, constraint tightening.
- **`tool/audit_logs_update_allowlist.txt`** — single allowlisted file (`db/migrations/202605131010_admin_audit_logs_business_date.sql`); allowlist matches exactly one UPDATE statement in the wave.
- **`tool/audit_logs_update_lint.dart`** — enforces audit_logs append-only via SQL grep + allowlist.
- **`tool/migration_cutoff_lint.dart`** — enforces script-cutoff = newest-migration via sentinel parse.
- **`tool/migration_drift_scanner.dart`** — sister tool covering the expand-contract gate (B11.1 grandfather cutoff at `202605131030_b11_1_auth_handoff_codes.sql`).
- **`tool/rls_policy_lint.dart`** — enforces wrapper-only RLS policy bodies (referenced in multiple migration headers; not separately exercised in this audit).
- **`tool/index_leading_column_lint.dart`** — enforces operator-leading B-tree index discipline (referenced in `202605061500_hardening_phase_8_email_index_leading_column_rekey.sql` rationale and in the migration headers of new operator-scoped tables).
- **`docs/POST_HARDENING_FOLLOWUPS.md:34-86`** — canonical pending-Production1-apply ledger.
- **`runbooks/phase_9_production1_migration_apply_runbook.md`** — operational runbook with apply history and dependency notes.
- **`scripts/postgres_staging_setup.ps1`** — staging setup script with the `MIGRATION_CUTOFF_BEGIN/END` sentinel.
- **Prior wave audits referencing these checks:**
  - `docs/archive/_audits/post_codex_wave_2026-05-13/pr_599_c_1a_email_event_provider_id_audit.md` (timeouts + audit_logs + pg_advisory_lock checks)
  - `docs/archive/_audits/post_codex_wave_2026-05-13/pr_626_c_7a_recovery_codes_viewed_at_prep_audit.md` (full new-table audit template)
  - `docs/archive/_audits/post_codex_wave_2026-05-13/pr_631_c_2_d_vendor_sync_outage_detector_wire_audit.md` (current-cutoff slice)
  - `docs/archive/_audits/post_codex_wave_2026-05-13/pr_584_b2_1_default_role_catalog_audit.md` and `pr_586_b11_2_b_step_up_wiring_audit.md` (B2.1 + B11.2 schema-touching slices)
- **Lean-cut memory** — `~/.claude/projects/C--Git-Local-Repos-forge-flow-demo/memory/project_v1_lean_cut_2_2026_05_03.md` (records the `pg_advisory_lock` drop verdict that Finding 5 cross-checks against).
