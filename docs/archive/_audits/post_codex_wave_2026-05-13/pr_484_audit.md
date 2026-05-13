# PR #484 — Add admin audit log contract schema — Audit

Auditor: orchestrator on `claude/pr-484-audit-doc` (worktree `nifty-clarke-d3ec25`).
Audited branch: `codex/admin-audit-log-contract-schema` at tip `84de5449` (Draft PR).
Base: `c7bd0e7e` (master tip post-PR #480 merge — Codex correctly rebased).
Diff: 14 files, +880 / -467, 1 commit.
Audit date: 2026-05-13.
Audit shape: per `docs/_audits/audit_chunking_playbook.md`. 14 files crosses the >5-files multi-surface threshold; full chunking applied. Chunks 1, 2, 5, 6, 7 active. No proxy/admin-lib changes in scope.

This is **PR C in the 3-PR plan** Codex committed to after the orchestrator's gap-pushback on the migration-renumber + extract-110100 + proxy-rebase requirements. PR B (lifecycle-access-hardening) and PR A (audit-target-hardening) still pending.

---

## Verdict

**approve-for-merge** subject to operator approval gates.

All 6 active chunks audit CLEAN. No findings requiring orchestrator-fix. Two observations worth flagging but neither blocks merge. No send-back items.

PR #484 touches every gated surface (schema migrations, audit-log repositories, auth-critical surfaces, new contract doc). Operator approval required at merge regardless of audit verdict, per `docs/CODEX_PROMPT_GENERATION_STANDARD.md` "Agent-Led Slices".

---

## Per-chunk findings

### Chunk 1 — Schema migrations (2 new files)

**CLEAN.**

`db/migrations/202605131000_admin_audit_log_actor_reason_contract.sql` (95 lines):

- Widens `auth_events_audit.actor_kind` CHECK to `('user', 'team_member', 'forge_admin', 'service', 'service_principal', 'system')` ✓
- Widens `audit_logs.actor_kind` CHECK to `('user', 'team_member', 'forge_admin', 'service', 'service_principal')` (no `'system'` per contract — system events stay only in auth_events_audit) ✓
- Adds `audit_logs.admin_reason text` column ✓
- Rebuilds `audit_logs_actor_shape_check` to pair (user/team_member/forge_admin → actor_user_id required, actor_principal_id NULL) and (service/service_principal → actor_principal_id required, actor_user_id NULL) ✓
- New `audit_logs_admin_reason_check`: enforces `forge_admin` rows MUST carry non-blank `admin_reason`; everyone else MUST have NULL ✓
- Uses expand-contract pattern: `add constraint ... not valid` then `validate constraint` ✓ (matches CLAUDE.md workflow)
- Column comments document legacy alias intent ✓

`db/migrations/202605131010_admin_audit_logs_business_date.sql` (22 lines):

- Adds `audit_logs.business_date date null` ✓
- Backfills existing rows from `chain_date` (UTC) with documented honesty caveat — restaurant-local timing for OLD rows is approximated; new rows compute properly from location timing
- Sets NOT NULL after backfill ✓ (clean expand-contract)
- Creates operator-leading index `audit_logs_operator_business_date_idx (operator_id, business_date, occurred_at desc)` ✓ matches CLAUDE.md HP #4 leading-column rule
- Column comment documents `business_date` vs `chain_date` distinction ✓ matches `phase_7_55_time_boundary_contract.md`

**Observation #O1 (not a finding):** `admin_reason` is NOT included in the hash chain encoding. The migration deliberately does not modify the chain trigger. This is contract-aligned per `audit_attribution_contract.md` "When To Update This Contract" rule — adding to the chain encoding would break previously-anchored rows' `row_hash`. The trade-off: admin_reason is post-hash provenance metadata, not tamper-evident at the DB level. Tamper-resistance for admin_reason relies on application-layer audit + RLS. Worth noting for future operator decision; if stronger tamper-evidence on admin_reason is needed, a coordinated re-anchor plan would be required.

### Chunk 2 — Repository layer (2 files)

**CLEAN.**

`lib/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart` (+38/-10):

- `writeRow` signature gains optional `businessDate` (String) + `adminReason` (String) parameters ✓
- INSERT SQL extends column list with `business_date, admin_reason` ✓
- Smart business_date fallback chain: explicit `businessDate` arg → location lookup with `(occurred_at at time zone l.timezone) - business_day_rollover_hour interval` → any active location for operator → `chain_date` (UTC fallback) ✓ matches `phase_7_55_time_boundary_contract.md` business-date computation
- Doc comments updated to reflect new actor_kind canonical labels with legacy aliases noted ✓

`lib/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart` (+228/-50):

- `AuthEventListRow` model extended with 11 new nullable fields (actorUserId, targetUserId, actorKind, actorDisplayName, actorEmail, actorRoleLabel, targetKind, targetId, adminReason, rowHash, businessDate). Pure additive; no breaking changes ✓
- `insertEvent` signature adds `targetKind`, `targetId`, `adminReason` parameters ✓
- `_assertActorKindShape` allowed set expanded to `{'user', 'team_member', 'forge_admin', 'service_principal', 'service', 'system'}` matching migration's CHECK ✓
- **Hash chain fan-out mapping correctly normalizes legacy aliases:**
  - `'user' | 'team_member'` → chain writes `'team_member'`
  - `'forge_admin'` → chain writes `'forge_admin'`
  - `'service_principal' | 'service'` → chain writes `'service_principal'`
  - `'system'` → NOT chained (early return) — matches `audit_logs` CHECK that excludes `'system'`
- admin_reason validation at GATEWAY BOUNDARY: throws `ArgumentError` if `chainActorKind == 'forge_admin'` and adminReason missing — defense-in-depth before DB CHECK fires ✓
- admin_reason fallback: tries `adminReason` parameter, then `payload['admin_reason']` string extraction ✓ (flexible for callers that pre-populated payload)
- target inference: if `targetKind`/`targetId` not provided, infer from `targetUserId` (legacy caller path) ✓
- Existing RLS/`withTenant` patterns preserved ✓

**Observation #O2 (not a finding):** Hash chain coexists with mixed actor_kind labels during the transition. Old rows have `actor_kind = 'user'` / `'service'` chained as-is; new rows have `'team_member'` / `'forge_admin'` / `'service_principal'` chained. Both label sets remain valid per the widened CHECK constraint. Contract acknowledges this. Audit query consumers (e.g., dashboards, exports) must handle both label sets — Codex's `audit_attribution_contract.md` "When To Update This Contract" section pins this.

### Chunk 5 — Tests (4 files)

**CLEAN.**

- `test/auth_events_audit_repository_test.dart` (+108/-37): tests operator_id pinning ("primary defense") and miswired-admin behavior. Coverage for the new actor_kind shape assertions.
- `test/infrastructure/persistence/postgres/repositories/audit_logs_repository_test.dart` (+259/-242): comprehensive test rewrite covering:
  - **`admin contract fields bind business_date and admin_reason without [...]`** — direct coverage for the new bindings
  - actor_kind never-NULL enforcement
  - operator_id RLS predicate posture
  - 2026-05-08 P1 hardening defense-in-depth (mismatched tenant context detection)
  - `FixedAuditLogsCutoverFlag` + `FeatureFlagsTableAuditLogsCutoverFlag` cutover paths
- `test/repositories/audit_logs_repository_test.dart` (+95/-113): chain_date computation, user actor case, service actor case
- `test/user_lifecycle_live_binding_test.dart` (+8/-2): smaller binding update

Test coverage explicitly verifies the new contract surface (admin_reason + business_date binding + actor_kind discriminator + tenant-context defense). No coverage gaps detected.

### Chunk 6 — Docs + runbooks (5 files)

**CLEAN.** All 5 doc updates are consistent migration-cutoff tracking:

- `docs/POST_HARDENING_FOLLOWUPS.md`: adds 2 new rows for migrations 131000 + 131010 to pending-Production1-apply queue.
- `docs/contracts/audit_attribution_contract.md` (+8 lines): the 2026-05-13 contract extension note documenting widened actor_kind labels + legacy alias coexistence + admin_reason invariant. Authority-grade contract addition.
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`: migration cutoff bumped from 121200 to 131010.
- `docs/phases/phase_9/phase_9_execution_backlog.md`: same cutoff bump.
- `runbooks/phase_9_production1_migration_apply_runbook.md`: same cutoff bump.

No drift between code and docs. Catalog drift check (`team.hierarchy.*` permission keys from PR #481): N/A — this PR doesn't touch permission keys.

### Chunk 7 — Integration test harness + scripts (1 file)

**CLEAN.**

- `scripts/postgres_staging_setup.ps1`: 1-line cutoff string bump from 121200 to 131010. Trivial.

---

## Verification

- **Codex's local report:** targeted flutter tests passed; targeted flutter analyze passed; `migration_drift_scanner.dart --fix --strict-docs` passed; `migration_cutoff_lint.dart` passed; `git diff --check` passed; pre-push repo lints passed.
- **GitHub remote checks:** UNSTABLE (billing block, same as prior wave; not a code issue).
- **Independent orchestrator-side verification:** deferred. The audit is grounded in diff reading + contract cross-reference. Local re-run of `dart analyze` on the 2 repository files recommended before merge.

---

## Orchestrator-fix commits (Phase 5b)

| Finding § | Commit SHA | Files touched | Re-audit result |
|---|---|---|---|
| (none) | — | — | — |

PR #484 has no findings requiring orchestrator-fix. Both observations (#O1 admin_reason not chained, #O2 legacy alias coexistence) are contract-aligned trade-offs documented in `audit_attribution_contract.md`.

---

## Follow-up items (none require send-back)

Nothing to send back. The audit is clean.

Wave-level follow-ups not in this PR's scope:

- PR B `codex/admin-hierarchy-lifecycle-access-hardening` — still pending (per orchestrator's sequencing reply: PR C first, then PR B, then PR A).
- PR A `codex/admin-audit-target-hardening` — still pending. Will be most conflict-prone with PR #481's merged proxy diff; needs careful rebase + intent-preservation.
- Finding #M1 from PR #481 retroactive audit (migration 80800 in-place rewrite) — still pending operator-side staging migration_history check.

---

## Operator approval gates

PR #484 touches every gated surface:

- **Schema migrations** (2 new): operator-leading index + audit-log CHECK constraints
- **audit-log + auth-events repositories**: auth-critical surface (CLAUDE.md L83-84 hash-chained audit log + actor_kind never-NULL invariant)
- **New contract doc** `audit_attribution_contract.md`: authority-grade contract addition
- **Migration runbook + staging setup script**: deploy-path artifacts

Per `docs/CODEX_PROMPT_GENERATION_STANDARD.md` "Agent-Led Slices" doctrine, all four require explicit operator approval before merge regardless of audit verdict. PR #484 stays Draft until operator approves.

---

## Citations

All code citations are to the worktree at `C:/Git Local Repos/forge_flow_demo/` on `origin/codex/admin-audit-log-contract-schema` at tip `84de5449`.

Source documents:

- `CLAUDE.md` L73, L75-76, L82-84 (RLS, wrapper functions, audit_logs hash chain, actor_kind never-NULL).
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` — Chunk 2 anchor (RLS-ready repository pattern).
- `docs/contracts/team_roles_hierarchy_console_parity_contract.md` — admin_reason required for actor_kind=forge_admin (L69, L89).
- `docs/contracts/phase_7_55_time_boundary_contract.md` — business_date denormalized DATE column on operator-scoped tables.
- `docs/contracts/audit_attribution_contract.md` — NEW in this PR. Pins the two-table actor attribution model.
- `docs/_audits/audit_chunking_playbook.md` Phase 5b — orchestrator-fix-by-default + authority-anchor rule.
- `docs/_audits/post_codex_wave/pr_476_b1_b2_audit.md` — PR #476 invariants preserved by PR #481 retroactive audit (carry-over confirmation).
- `docs/_audits/post_codex_wave/pr_481_retroactive_audit.md` — Finding #M1 still pending operator-side resolution.

---

## Auditor's note

This is a clean, contract-grade PR. Codex's `audit_attribution_contract.md` addition is a substantial doc artifact — explicit safe coercion patterns, forbidden patterns, hash chain immutability rationale, when-to-update conditions. The migration shape uses the expand-contract pattern correctly. The repository changes thread admin_reason through with both gateway-boundary validation (ArgumentError) and DB CHECK enforcement (defense-in-depth). The fan-out alias normalization is precise.

The two observations (admin_reason not in hash chain; legacy alias coexistence) are not findings — both are documented trade-offs in the new contract doc, not contract violations.

PR C of the 3-PR plan is the contract-foundation slice. PR B (lifecycle access hardening) will sit on top of this; PR A (proxy audit-target hardening) will sit on top of PR B and will pick up the new admin_reason/business_date plumbing.

The wave continues: approve PR #484 → expect PR B next → audit PR B in chunking-playbook shape → then PR A which is most conflict-prone with PR #481's proxy diff.
