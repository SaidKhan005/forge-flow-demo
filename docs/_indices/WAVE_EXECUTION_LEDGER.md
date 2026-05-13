# Wave Execution Ledger

Single-source-of-truth tracker for every slice across the post-Codex wave.

Updated: 2026-05-12 (initial — all slices `assigned`).
Owner: orchestrator (this Claude session) is the only writer; executors read.

## How this works

- **Executors** (Codex session + Claude lane session) read this ledger before picking their next slice. Pick the first slice with `state = assigned` on your lane. Lock it by opening the PR (you don't edit this file).
- **Orchestrator** (the audit/merge Claude session) updates `state` and `pr` columns post-merge.
- **State machine**: `assigned` → `in-progress` (PR open) → `audit-pending` (PR approved by orchestrator audit but waiting on operator gate) → `merged` (on master). Reject path: `audit-pending` → `back-to-author` (executor reopens or follow-up PR).
- **Gate column**: `auto` (orchestrator merges after clean audit), `operator` (operator approves before merge; orchestrator pings).
- **Owner column**: `Claude` (Claude lane session) or `Codex` (Codex session) or `orchestrator` (this session — A0 verification probe + C-12 closeout).
- **Dependency column**: must be `merged` before the dependent slice opens.

## Concurrency rule

Two executors must not work the same slice. If your lane's first `assigned` slice is also another executor's lane (cross-lane dependency), wait until that one merges. The dependency column makes this explicit. If a dependency hasn't merged but the dependent slice is non-blocking, you can start in parallel — note that explicitly in your PR description.

## Operator-approval gates (recap)

Triggers the `operator` gate: auth-critical, RLS-touching, schema-touching (migration), proxy-touching, demo-mode reader carve-out, KMS, billing, vendor-live carve-out.

## Slice ledger

### Lane A — Code Health

| Slice | Plan anchor | Owner | Size | Risk | Gate | Dependency | State | PR | Notes |
|---|---|---|---|---|---|---|---|---|---|
| A0 | `lane_a_code_health/03_execution_slices.md` Slice A0 | orchestrator | Small | Low | auto | — | merged | — | Verification PASS 2026-05-12; doc: `docs/_audits/code_health/a0_b1_b2_post_merge_verification.md` |
| A2.1 | Slice A2.1 | Codex | Small | Low | auto | A0 merged | merged | #519 | Dead-code sweep — 2 placeholder widgets deleted (179 LoC removed); inventory updated |
| A2.2 | Slice A2.2 | Codex | Medium | Medium | operator | A2.1 merged | assigned | — | Email pipeline wire-or-delete |
| A3.1 | Slice A3.1 | Claude | Medium | Medium | operator | A0 merged | merged | #533 | Monolith seam-map (12 clusters with file:line ranges) + bleed-stop CI lint (`advisor_proxy_size_lint`) — read-only inspection of `advisor_proxy.dart`. Current 18,871 / ceiling 19,071 / 200-line headroom. Operator approved 2026-05-13. Unblocks A3.2 (bare-catch tail chunk 1 of 3). |
| A3.2 | Slice A3.2 | Claude | Medium | Medium | operator | A3.1 merged | assigned | — | Bare-catch tail chunk 1 of 3 |
| A4.1 | Slice A4.1 | Claude | Small | Low | auto | A0 merged | merged | #517 | Performance audit pass — 3 ranked recs delivered for A4.2 (Postgres pool 4→20, shift_dashboard ticker coalescing, healthProducerConcurrency wiring) |
| A4.2 | Slice A4.2 | Claude | Medium | Medium | operator | A4.1 merged | assigned | — | Perf fixes if found (incl. Postgres pool 4→20) |
| A5+A8 | Slice A5+A8 | Codex | Medium | Medium | operator | A0 merged | merged | #527 | Schema versioning post_deploy convention + `audit_logs` UPDATE allowlist lint + `--require-expand-contract` scanner mode; grandfathered to B11.1's migration; operator approved 2026-05-13 |
| A6.1 | Slice A6.1 | Codex | Small | Low | auto | — | merged | #498 | Proxy health UI honesty pass |
| A7.1 | Slice A7.1 | Claude | Small | Low | auto | A4.1 merged | merged | #526 | Frameworks cross-reference sweep — picked canonical `docs/frameworks/<NAME>.md` path; fixed 7 broken refs across 3 active docs; `docs/frameworks/README.md` rewritten with correct 5-framework index |
| A9.1 | Slice A9.1 | Codex | Medium | Medium | operator | A0 merged | merged | #530 | `lib/data` rehome — 3 frozen-legacy files moved (app_defaults + cross_axis_pair_catalog → `lib/domain/constants/`; mock_integration_replay_seed → `lib/dev/`). 72 files / +90/-90 (mostly import-path updates). 3 active contract docs updated. `lib/data/` empty on master post-merge (delete-only doctrine fully honored). Operator approved 2026-05-13. |
| A10.1 | Slice A10.1 | Claude | Small | Low | auto | A0 merged | merged | #523 | Test consolidation — 9 git mv `test/load/pressure/` → `test/pressure/`; closes 1 stale `KNOWN_FAILING_TESTS` entry + adds 1 for pre-existing closure-registry drift |
| A11.1 | Slice A11.1 | Claude | Small | Medium | operator | A0 merged | merged | #522 | Production `proxy.session_record.incomplete{route, missing_field}` gauge — observability-only at `POST /v1/auth/session/login`; operator approved 2026-05-13; unblocks A11.2 |
| A11.2 | Slice A11.2 | Claude | Medium | Medium | operator | A11.1 merged | audit-pending | #537 | Soak harness durable extensions — fd watcher (Linux-only, no-op elsewhere), heap-snapshot uploader (storage-agnostic interface, GCS impl, env-gated inert default), p3c CLI flags (`--ttl-dist`, `--vendor-mix`, `--jitter`). 6 files / +1876/-5. 31/31 new tests pass. Zero pubspec deps. **Operator decision flagged**: GCS vs Azure backend (worker built behind storage-agnostic interface for easy swap). Audit doc: `docs/_audits/post_codex_wave/pr_537_a11_2_soak_harness_extensions_audit.md`. |

### Lane B — Features

| Slice | Plan anchor | Owner | Size | Risk | Gate | Dependency | State | PR | Notes |
|---|---|---|---|---|---|---|---|---|---|
| B1.a | `lane_b_features/03_execution_slices.md` B1.a | Claude | Small | Low | auto | — | merged | #501 | Inheritance notice propagation; copy follow-up applied by orchestrator (Option 1 per audit) |
| B1.b | B1.b | Claude | Small | Medium | operator | — | merged | #500 | Admin audit actor fix — operator approved 2026-05-12 |
| B2.1 | B2.1 | Claude | Medium | Medium | operator | — | assigned | — | Default Role catalog schema + publish endpoint |
| B2.2 | B2.2 | Claude | Medium | Medium | operator | B2.1 merged | assigned | — | Default Role catalog admin editor |
| B3 | B3 | Codex | Medium | Medium | operator | — | merged | #502 | Role-key hybrid identifier sweep — operator approved 2026-05-12; unblocks B7.a |
| B4 | B4 | Codex | Small | Low | auto | B3 merged | merged | #513 | Two-product taxonomy in role editor + product-tagged audit payload |
| B5 | B5 | Codex | Medium | Medium | operator | — | assigned | — | Admin access-control + permission-key completeness |
| B6 | B6 | Codex | Medium | Medium | operator | B10.1 merged | assigned | — | Benchmark override (hierarchy-inherited) |
| B7.a | B7.a | Codex | Small | Medium | operator | — | merged | #507 | Invite hierarchy-scope fix — operator approved 2026-05-12; Option A consumer-label follow-up applied by orchestrator |
| B8 | B8 | Claude | Medium | Medium | operator | — | assigned | — | Audit log hierarchy filter (ltree join) |
| B9.1 | B9.1 | Codex | Small | Low | auto | — | merged | #510 | `/sign-in-security` 301 redirect on both dockerfiles |
| B9.2 | B9.2 | Codex | Medium | Medium | operator | B9.1 merged | assigned | — | My Account consolidation + Active Sessions |
| B9.3 | B9.3 | Codex | Small | Low | auto | B9.2 merged | assigned | — | Adaptive 2FA button (4 states) |
| B10.1 | B10.1 | Codex | Medium | Medium | operator | — | assigned | — | `vendor_applicability` table + repository + routes |
| B10.2 | B10.2 | Codex | Medium | Medium | operator | B10.1 merged | assigned | — | Vendor applicability admin editor + wage authority binding |
| B11.1 | B11.1 | Claude | Medium | High | operator | — | merged | #512 | `handoff_codes` table + endpoints — operator approved 2026-05-12; Production1 apply deferred to next scheduled event; unblocks B11.2 + C-5 |
| B11.2 | B11.2 | Claude | Medium | High | operator | B11.1 merged | assigned | — | RFC 9470 step-up challenge on sensitive routes |

### Lane C — Cross-Surface Parity

| Slice | Plan anchor | Owner | Size | Risk | Gate | Dependency | State | PR | Notes |
|---|---|---|---|---|---|---|---|---|---|
| C-1 | `lane_c_parity/03_execution_slices.md` C-1 | Claude | Small | Low | auto | — | assigned | — | SendGrid Event Webhook receiver |
| C-2 | C-2 | Claude | Medium | Medium | operator | C-1 merged | assigned | — | Wire-or-delete 6 template-only emails |
| C-3 | C-3 | Codex | Small | Low | auto | B9.1 merged | assigned | — | Sign-in-security → My Account redirect (decision #7) |
| C-4 | C-4 | Codex | Medium | Medium | operator | — | assigned | — | Master Demo→Live switch — needs 4th HP #2 reader-side carve-out |
| C-5 | C-5 | Codex | Medium | High | operator | B11.1 merged | assigned | — | Mobile pointer rows do deep-link redemption |
| C-6 | C-6 | Codex | Medium | Medium | auto | B1.a merged | assigned | — | Inheritance Tree shared component consumer |
| C-7 | C-7 | Codex | Small | Low | auto | B9.2 merged | assigned | — | Adaptive 2FA button (R1 pattern) |
| C-8 | C-8 | Claude | Medium | Medium | operator | — | merged | #499 | Notification preferences catalog completeness — operator approved 2026-05-12 |
| C-9 | C-9 | Codex | Medium | Medium | operator | C-8 merged | assigned | — | Mobile in-app inbox renders every catalog event |
| C-10 | C-10 | Codex | Small | Low | auto | — | assigned | — | Admin parity copy + read-only-mostly tile labels |
| C-11 | C-11 | Claude | Medium | Medium | operator | C-2 merged | assigned | — | Pressure-test inventory under preview |
| C-12 | C-12 | orchestrator | Small | Low | auto | all C-* merged | assigned | — | Final lane-C integration + audit |

## Counts

- Total slices: **43**
- Claude owner: **20** (A0/A3.1/A3.2/A4.1/A4.2/A7.1/A10.1/A11.1/A11.2 + B1.a/B1.b/B2.1/B2.2/B8/B11.1/B11.2 + C-1/C-2/C-8/C-11) — plus orchestrator A0/C-12
- Codex owner: **21** (A2.1/A2.2/A5+A8/A6.1/A9.1 + B3/B4/B5/B6/B7.a/B9.1/B9.2/B9.3/B10.1/B10.2 + C-3/C-4/C-5/C-6/C-7/C-9/C-10)
- Orchestrator owner: **2** (A0 verification probe, C-12 closeout)
- Auto-merge gate: **17** (no operator ping)
- Operator gate: **26** (operator approval required pre-merge)

## Update protocol

When the orchestrator merges a PR:
1. Find the slice's row.
2. Set `state` = `merged`.
3. Set `pr` = `#<number>`.
4. Move on.

When a PR opens:
1. Find the slice's row.
2. Set `state` = `in-progress`.
3. Set `pr` = `#<number>`.

When a PR's audit completes but operator approval is pending:
1. Set `state` = `audit-pending`.
2. Keep `pr` field.

When a PR is rejected/closed without merge:
1. Set `state` = `back-to-author` (or revert to `assigned` if the executor abandons).
2. Note the reason in a footnote at the bottom of the relevant lane section.

## Change log

| Date | Change |
|---|---|
| 2026-05-12 | Initial ledger — 43 slices, all `assigned`. |
| 2026-05-12 | First wave PRs land. **A6.1 merged** (PR #498 → master `9cdaee1e`). **B1.a / B1.b / C-8 → `audit-pending`** (orchestrator audit clean; awaiting operator approval — see `docs/_audits/post_codex_wave/pr_{499,500,501}_*_audit.md`). B1.a escalates despite `Gate=auto` due to slice-spec planning ambiguity worker correctly surfaced. |
| 2026-05-12 | **Operator approve-all 21:55Z.** Merged: B3 (#502 `fb806262`), B1.b (#500 `427a5510`), C-8 (#499 `5583d5b9`), B1.a (#501 `a6094e9b`). B1.a copy follow-up (Option 1 — rewrite "Other locations…" → "This scope only covers…") applied by orchestrator-fix-by-default in this same PR. Unblocks Codex's held B7.a branch. |
| 2026-05-12 | **A0 verification probe PASS** (orchestrator-owned). B1+B2 hot-fix live on master tip `f1034d0a`; runZonedGuarded + scope-less contract + soak harness all confirmed. Unblocks 9 Lane A slices (A2.1, A2.2, A3.1, A4.1, A5+A8, A7.1, A9.1, A10.1, A11.1). Evidence: `docs/_audits/code_health/a0_b1_b2_post_merge_verification.md`. |
| 2026-05-12 | **B7.a merged + Option A follow-up applied.** Operator approved PR #507 → `4da1a8ef` (Cancel CTA + idempotent revoke + permission narrow). Orchestrator-fix follow-up adds `case 'invite.cancel': return 'Invite cancelled';` to both consumer switches (`web_team_audit_log_gateway.dart`, `auth_operations_gateway.dart`) and updates the parity test mapping. `auth.invite_revoked` label changed to "Invite cancelled" for backwards-compatibility with historic rows. 12+1 tests pass. |
| 2026-05-13 | **A10.1 merged** (PR #523 → `d789c22c`). 9 `git mv` renames + 5 harness import-path updates + .gitignore retarget. Dropped stale `settings_permission_explainer_test.dart` entry from `KNOWN_FAILING_TESTS.md` (verified deleted in W3.A sweep commit `22db522a`). Added entry for 2 pre-existing p3c closure-registry assertion failures (NOT regressions). Audit doc: `docs/_audits/post_codex_wave/pr_523_a10_1_test_consolidation_audit.md`. |
| 2026-05-13 | **A11.1 → `audit-pending`** (PR #522). Production session-record incomplete gauge wired at `POST /v1/auth/session/login`. Observability-only (no PII labels, defensive try/catch, identical response bytes, optional back-compat param). B11.1 auth-handoff routes verified untouched. Proxy-touching → operator gate. Audit doc: `docs/_audits/post_codex_wave/pr_522_a11_1_session_record_gauge_audit.md`. |
| 2026-05-13 | **A11.1 merged** (PR #522 → `1ddce436`). Operator approved after plain-English summary. Gauge class `SessionRecordIncompleteGauge` confirmed live on master at `tool/advisor_proxy/advisor_proxy.dart:6969`. Unblocks A11.2 (soak harness durable extensions). |
| 2026-05-13 | **A10.1 doc-hygiene followup** (PR #528 → `fefa6e5b`). 15 forward-looking `test/load/pressure/` refs in `docs/_audits/code_health/a11_soak_harness_durable_kit.md` updated to `test/pressure/`; 1 historical state-comparison row on line 43 preserved. The other 5 docs the A10.1 worker flagged turned out to be historical "as-observed" records that should stay as-is — analyzed and left alone. |
| 2026-05-13 | **A7.1 merged** (PR #526 → `183ab38c`). Canonicalized framework path: chose `docs/frameworks/<NAME>.md` as the single canonical path (verified by Glob that all 5 framework files physically live there; ZERO copies at docs root means prior `docs/<NAME>FRAMEWORK.md` refs were broken links). Fixed 7 refs across 3 active docs; rewrote `docs/frameworks/README.md` as a correct 5-framework index. Worker disclosed canonical-hook installer fix + rebase note (positive honesty patterns). |
| 2026-05-13 | **A5+A8 → `audit-pending`** (PR #527). Tooling/lint/convention only — ZERO production migrations applied. Adds `db/migrations/post_deploy/` convention dir + README (expand-only top-level, contract-phase post-deploy), `tool/audit_logs_update_lint.dart` (UPDATE allowlist lint), `tool/audit_logs_update_allowlist.txt` (1 entry: historical `business_date` backfill, A5-approved retrospectively), `--require-expand-contract` mode on migration drift scanner (grandfathered to B11.1's migration `202605131030_b11_1_auth_handoff_codes.sql`). CI wired in `repo-lints` job. Schema-touching → operator gate. Audit doc: `docs/_audits/post_codex_wave/pr_527_a5_a8_audit_log_guardrails_audit.md`. |
| 2026-05-13 | **A9.1 → `audit-pending`** (PR #530). `lib/data/` rehome — 3 frozen-legacy files moved (app_defaults + cross_axis_pair_catalog → `lib/domain/constants/`; mock_integration_replay_seed → `lib/dev/`). 72 files / +90/-90 (mostly import-path updates). 3 active contract docs updated (demo_mode + phase_7_58_primary_driver + phase_7_61_driver_key). 198/198 targeted tests pass. `lib/data/` will be empty post-merge (delete-only doctrine fully honored). Worker disclosed internal A9-F1 send-back catch (positive). Frozen-surface + demo-mode-parity sensitivity → operator gate. Audit doc: `docs/_audits/post_codex_wave/pr_530_a9_1_lib_data_rehome_audit.md`. |
| 2026-05-13 | **A5+A8 merged** (PR #527 → `f597252a`). Operator approved after plain-English summary. `db/migrations/post_deploy/`, `tool/audit_logs_update_lint.dart`, `tool/audit_logs_update_allowlist.txt` all confirmed live on master. Grandfather cutoff anchored to B11.1's migration — existing history intact; new gate enforces starting with the next migration. |
| 2026-05-13 | **A9.1 merged** (PR #530 → `5330fcfd`). Operator approved after plain-English summary. `lib/data/` confirmed EMPTY on master post-merge (delete-only doctrine fully honored). 3 files at new homes verified: `lib/dev/mock_integration_replay_seed.dart`, `lib/domain/constants/app_defaults.dart`, `lib/domain/constants/cross_axis_pair_catalog.dart`. |
| 2026-05-13 | **A3.1 → `audit-pending`** (PR #533). Monolith seam-map + bleed-stop CI lint. `advisor_proxy.dart` inspected READ-ONLY (blob SHA verified unchanged). Adds `tool/advisor_proxy_size_lint.dart` (176 LoC, testable façade), 258-line seam map at `docs/_audits/code_health/a3_advisor_proxy_seam_map.md` (12 clusters with file:line ranges, all spot-checked correctly), +45 append to `proxy_split_plan.md`. CI lint runs cleanly: 18,871 / 19,071 / 200 headroom. **Orchestrator-applied conflict resolution**: rebased onto current master (A5+A8 had renamed lint-chain step name in ci.yml); pure mechanical resolution, no semantic change to worker intent. Force-pushed with `--force-with-lease`. Audit doc: `docs/_audits/post_codex_wave/pr_533_a3_1_monolith_seam_map_audit.md`. |
| 2026-05-13 | **A3.1 merged** (PR #533 → `80148903`). Operator approved after plain-English summary. `tool/advisor_proxy_size_lint.dart` + seam-map doc confirmed live on master. Bleed-stop ceiling 19,071 lines + ratchet rule now in force. Unblocks A3.2 (bare-catch tail chunk 1 of 3). |
| 2026-05-13 | **A11.2 → `audit-pending`** (PR #537). Soak harness durable extensions: fd watcher (Linux), heap-snapshot uploader (storage-agnostic, GCS impl, env-gated), p3c CLI flags. 6 files / +1876/-5. 31/31 new tests pass. Zero pubspec deps. **Operator-decision flagged**: GCS vs Azure backend (interface allows easy swap). Recommendation: defer backend choice; merge as-is. Audit doc: `docs/_audits/post_codex_wave/pr_537_a11_2_soak_harness_extensions_audit.md`. |
| 2026-05-13 | **Doc-hygiene PR #539 audit-pending**. Orchestrator-spawned sub-agent trimmed 41 archive files (3 in `archive/internal/`, 38 in `archive/_execution/` — all closed-PR proofs / one-off snapshots / "CLOSED" dispatch plans, all with zero references outside archive/audits per agent's per-file grep) + 1 CLAUDE.md edit (replaced dead `docs/BETWEEN_SPRINT_AUDIT_PROMPT.md` ref with prose). Agent restraint: 0 memory consolidations, 0 phase doc moves, 0 active-doc updates — all assessed correctly. Audit doc: `docs/_audits/post_codex_wave/pr_539_doc_hygiene_trim_audit.md`. |
