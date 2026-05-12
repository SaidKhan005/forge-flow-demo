# Rollup Audit — PR B + PR A code onto master

**Verdict: approve-for-merge**
**Light playbook** (26 files / 1348 LoC under heavy-playbook threshold).

**Rollup HEAD**: `51fc2767` (merge commit of `origin/codex/admin-audit-target-hardening` into a fresh branch off master).
**Master HEAD at audit time**: `d5cf12e1`.

## Why this rollup exists

PRs #488 (PR B — admin hierarchy lifecycle access hardening) and #490 (PR A — admin audit target attribution) both merged on GitHub but into the wrong base — PR B into PR C's stacked branch `codex/admin-audit-log-contract-schema`, PR A into PR B's stacked branch `codex/admin-hierarchy-lifecycle-access-hardening` — not master. Only PR C (#484) and the audit docs (PRs #486, #489, #491) actually landed on master.

This rollup is the recovery merge: it brings PR B + PR A code onto master in one merge commit. PR C content is already on master via `a410b5b5`, so the rollup diff is purely the PR B + PR A delta.

## Per-chunk findings

### Chunk 1 — migration

| Finding | file:line | Authority anchor | Status |
|---|---|---|---|
| `202605131020_*.sql` (195 LoC) matches PR #488 audit verbatim — operator-leading on all 9 indexes, `if not exists` / `if exists` idempotent, active-only partial unique replacing `org_units_operator_id_path_key`, `refresh_user_effective_locations` excludes deleted / suspended ancestors via ltree `<@`, triggers re-bound | `db/migrations/202605131020_admin_hierarchy_lifecycle_access_hardening.sql:1-195` | CLAUDE.md HP #4; `docs/contracts/hardening_rls_and_repository_pattern_contract.md`; `pr_488_audit.md` Chunk 1 | PASS |

### Chunk 2 — repositories

| Finding | file:line | Authority anchor | Status |
|---|---|---|---|
| `LocationsRepository` update path gains `deleted_at is null` guard + soft-delete active-targets guard with explicit `StateError` | `lib/infrastructure/persistence/postgres/repositories/locations_repository.dart:135,168-200` | `pr_488_audit.md` Chunk 2 | PASS |
| `org_units_repository.dart` — `listAllLocations` + `listAllLocationsAsAdmin` apply ltree `<@` cascade-hide; `moveLocation` / `setOrgUnitSuspended` / `deleteOrgUnit` / `setLocationSuspended` / `deleteLocation` all add `operator_id` to WHERE; both delete paths raise `OrgUnitMoveRejected` with codes `org_unit_has_active_access_targets` / `location_has_active_access_targets` (HTTP 409) | `lib/infrastructure/persistence/postgres/repositories/org_units_repository.dart:275-286,333-340,539-553,615-655,681-693,733-777,826-832` | `hardening_rls_and_repository_pattern_contract.md`; `team_roles_hierarchy_console_parity_contract.md`; `pr_488_audit.md` Chunk 2 | PASS |

### Chunk 3 — auth + MFA + proxy

| Finding | file:line | Authority anchor | Status |
|---|---|---|---|
| Auth gateway: 7 sites tagged with `targetKind` / `targetId` using stable labels (`role` ×3, `user_role` ×2, `org_unit` ×1, `location` ×1); `_audit` helper signature extended; `actorKind: 'user'` preserved (no auth-semantics change) | `lib/services/auth/repository_auth_operations_gateway.dart:225,278,328,669,703,864,1026,1736-1755` | parity contract `:67,:141`; `pr_490_audit.md` Chunk 2 | PASS |
| Proxy route entry HARD-H guard now requires `Idempotency-Key` + non-blank `admin_reason` on non-GET; returns 400 `missing_idempotency_key` / `missing_admin_reason`; `_routeOperatorLocationAdmin` accepts `String? adminReason`; 7 mutation sites replace `'$reasonPrefix:*'` synthesis with `adminReason!` (force-unwrap safe given guard) | `tool/advisor_proxy/advisor_proxy.dart:14086-14130,14697,14748,14782,14826,14831,14879,14922,14961` | parity contract `:55,:69,:234`; `pr_490_audit.md` Chunk 1 | PASS |
| `proxy_bootstrap.dart`: `_audit` helper threads `targetKind` / `targetId` into `insertSystemEvent`; 7 admin operator-location event types tagged (`operator` ×4, `location` ×3) | `tool/advisor_proxy/proxy_bootstrap.dart:3404,3448,3481,3505,3538,3573,3619,3633-3648` | parity contract `:67`; `pr_490_audit.md` Chunk 1 | PASS |
| MFA worker dead-letter outbox payload now carries `request_id` alongside `event_id` | `lib/services/mfa/mfa_removal_worker.dart:383` | `core_app_architecture.md` MFA worker outbox correlation; `pr_490_audit.md` Chunk 3 | PASS |

### Chunk 4 — tests

| Finding | file:line | Authority anchor | Status |
|---|---|---|---|
| New `phase_9_hierarchy_lifecycle_access_hardening_test.dart` (103 LoC) pins SQL shape (lifecycle stamps, partial unique, 4 active-target lookup indexes, scope_type predicates) — matches PR #488 audit | `test/phase_9_hierarchy_lifecycle_access_hardening_test.dart` | `pr_488_audit.md` Chunk 5 | PASS |
| New `advisor_proxy_bootstrap_test.dart` (208 LoC) — `patchOperator` / `addLocation` `targetKind` / `targetId` propagation — matches PR #490 audit | `test/advisor_proxy_bootstrap_test.dart` | `pr_490_audit.md` Chunk 4 | PASS |
| `advisor_proxy_test.dart` (+139): new 400-guard tests for `missing_idempotency_key` + `missing_admin_reason`; existing admin route tests updated to send `idempotencyKey` + `admin_reason` body across 7 mutation paths | `test/advisor_proxy_test.dart` | `pr_490_audit.md` Chunk 4 | PASS |
| 8 `_AuditFake` / `_RecordingAuthEventsAuditRepository` signature backfills (`mfa_removal_worker_test.dart`, `mfa_operations_gateway_test.dart`, `admin_audit_extensions_test.dart`, `feature_flags_concurrency_test.dart`, `feature_flags_idempotency_test.dart`, `integration_admin_proxy_gateway_kms_revision_test.dart`, `repository_graph_candidates_proxy_gateway_test.dart`, `role_admin_live_binding_test.dart`) — mechanical add-params for `targetKind` / `targetId` overrides | (multiple) | `pr_490_audit.md` Chunk 4 | PASS |
| Overlapped file `org_units_repository_live_binding_test.dart` (+244) is exactly PR B's +173 (lifecycle delete guards) plus PR A's +71 (`org_unit_created` / `location_org_unit_moved` target_kind assertions) | `test/org_units_repository_live_binding_test.dart` | `pr_488_audit.md` Chunk 5; `pr_490_audit.md` Chunk 4 | PASS |
| Cutover test asserts explicit `targetKind` / `targetId` flow into `audit_logs.target_kind` / `target_id` | `test/repositories/auth_events_audit_cutover_test.dart:58-82` | parity contract `:67`; `pr_490_audit.md` Chunk 4 | PASS |
| `locations_repository_test.dart` (+50/-3) extends soft-delete guard coverage | `test/infrastructure/persistence/postgres/repositories/locations_repository_test.dart` | `pr_488_audit.md` Chunk 5 | PASS |

### Chunk 5 — docs / runbooks / scripts

| Finding | file:line | Authority anchor | Status |
|---|---|---|---|
| All 5 housekeeping files consistently bump migration cutoff `131010` → `131020`, count `36` → `37`; new migration added to pending-apply queue and apply runbook scope list | `docs/POST_HARDENING_FOLLOWUPS.md`, `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`, `docs/phases/phase_9/phase_9_execution_backlog.md`, `runbooks/phase_9_production1_migration_apply_runbook.md`, `scripts/postgres_staging_setup.ps1` | `pr_488_audit.md` Chunks 6 + 7 | PASS |

### Chunk 6 — drift verification

| Finding | file:line | Authority anchor | Status |
|---|---|---|---|
| Commit chain is exactly 3 commits: `01c48921` (PR B), `b462798e` (PR A), `51fc2767` (merge). Merge parents are `d5cf12e1` (master HEAD) + `b462798e` | `git log origin/master..claude/rollup-pr-b-pr-a` | n/a | PASS |
| File union math: PR B (11) ∪ PR A (16) with 1 overlap = 26 files (exact match to rollup); LoC math: 671 + 677 = 1348 added; -26 + -27 = -53 removed (exact match) | n/a | n/a | PASS |
| 3-way merge correctly kept master's version of 6 files PR B / A didn't touch but their stale branch base differed on (`202605080800_auth_permission_version.sql` PR #487 comment, 4 audit docs, `admin_timing_setup_screen.dart` PR #485 inheritance notice) — matches `pr_488_audit.md` "Drift-from-master note". No master code regressed | n/a | `pr_488_audit.md` "Drift-from-master note" | PASS |

## Drift comparison summary

- Files matching PR #488 audit scope: **11 / 11**
- Files matching PR #490 audit scope: **16 / 16**
- Unexpected files: **0**

## Operator approval gates check

- **Auth**: PASS — frozen permission catalog untouched; auth gateway change is pure audit-attribution pass-through (`actorKind: 'user'` preserved); no role-grant semantics altered.
- **Audit log**: PASS — PR C contract preserved (canonical actor labels, `business_date` trigger-side denormalization, `admin_reason` required for `forge_admin`); new `targetKind` / `targetId` populates existing columns; hash chain field order untouched.
- **Proxy contract**: PASS — `Idempotency-Key` + `admin_reason` guards at route entry (`advisor_proxy.dart:14086-14130`) before mutation routing; idempotency store handoff unchanged; matches HARD-H precedent at `9226 / 9971 / 10065 / 10172 / 10624`.
- **Migration**: PASS — re-entrant (`if not exists` / `if exists`); all 9 indexes operator-leading; not yet applied (`POST_HARDENING_FOLLOWUPS.md` pending-apply queue bumped `36 → 37`); staging apply gated by `phase_9_production1_migration_apply_runbook.md` before any Production1 event.

## Final verdict + reasoning

**approve-for-merge.** The rollup is a clean union of two previously approve-for-merge'd PRs with zero drift:

1. Every file in the rollup is accounted for by either `pr_488_audit.md` or `pr_490_audit.md`.
2. Every byte of diff size matches: 26 files, +1348 / -53.
3. Every spot-checked diff (migration SQL, both repositories, auth gateway, MFA worker, both proxy files, key tests, all 5 housekeeping docs) matches its prior audit doc — same line ranges, same labels, same authority anchors.
4. Commit chain is exactly the expected 3 commits and the merge cleanly retained master's versions of the 6-file "drift-from-master" set noted in `pr_488_audit.md` — no master code regressed.
5. All four operator-approval gates (auth, audit log, proxy contract, migration) PASS — each was verified per surface against its anchor contract in the original audits, and the rollup carries those exact verified changes.

Per the 2026-05-13 auto-merge doctrine (`memory/feedback_orchestrator_auto_merge_after_audit.md`), the rollup is eligible for merge to master.
