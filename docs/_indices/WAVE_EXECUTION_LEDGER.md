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
| A2.1 | Slice A2.1 | Codex | Small | Low | auto | A0 merged | assigned | — | Dead-code sweep (placeholder widgets) |
| A2.2 | Slice A2.2 | Codex | Medium | Medium | operator | A2.1 merged | assigned | — | Email pipeline wire-or-delete |
| A3.1 | Slice A3.1 | Claude | Medium | Medium | operator | A0 merged | assigned | — | Monolith seam-map + bleed-stop lint |
| A3.2 | Slice A3.2 | Claude | Medium | Medium | operator | A3.1 merged | assigned | — | Bare-catch tail chunk 1 of 3 |
| A4.1 | Slice A4.1 | Claude | Small | Low | auto | A0 merged | assigned | — | Performance audit pass |
| A4.2 | Slice A4.2 | Claude | Medium | Medium | operator | A4.1 merged | assigned | — | Perf fixes if found (incl. Postgres pool 4→20) |
| A5+A8 | Slice A5+A8 | Codex | Medium | Medium | operator | A0 merged | assigned | — | Schema versioning + `audit_logs` UPDATE lint |
| A6.1 | Slice A6.1 | Codex | Small | Low | auto | — | merged | #498 | Proxy health UI honesty pass |
| A7.1 | Slice A7.1 | Claude | Small | Low | auto | A4.1 merged | assigned | — | Frameworks cross-reference sweep |
| A9.1 | Slice A9.1 | Codex | Medium | Medium | operator | A0 merged | assigned | — | `lib/data` rehome |
| A10.1 | Slice A10.1 | Claude | Small | Low | auto | A0 merged | assigned | — | Test consolidation pass |
| A11.1 | Slice A11.1 | Claude | Small | Medium | operator | A0 merged | assigned | — | Production session-record gauge |
| A11.2 | Slice A11.2 | Claude | Medium | Medium | operator | A11.1 merged | assigned | — | Soak harness durable extensions |

### Lane B — Features

| Slice | Plan anchor | Owner | Size | Risk | Gate | Dependency | State | PR | Notes |
|---|---|---|---|---|---|---|---|---|---|
| B1.a | `lane_b_features/03_execution_slices.md` B1.a | Claude | Small | Low | auto | — | merged | #501 | Inheritance notice propagation; copy follow-up applied by orchestrator (Option 1 per audit) |
| B1.b | B1.b | Claude | Small | Medium | operator | — | merged | #500 | Admin audit actor fix — operator approved 2026-05-12 |
| B2.1 | B2.1 | Claude | Medium | Medium | operator | — | assigned | — | Default Role catalog schema + publish endpoint |
| B2.2 | B2.2 | Claude | Medium | Medium | operator | B2.1 merged | assigned | — | Default Role catalog admin editor |
| B3 | B3 | Codex | Medium | Medium | operator | — | merged | #502 | Role-key hybrid identifier sweep — operator approved 2026-05-12; unblocks B7.a |
| B4 | B4 | Codex | Small | Low | auto | B3 merged | assigned | — | Two-product taxonomy in role editor |
| B5 | B5 | Codex | Medium | Medium | operator | — | assigned | — | Admin access-control + permission-key completeness |
| B6 | B6 | Codex | Medium | Medium | operator | B10.1 merged | assigned | — | Benchmark override (hierarchy-inherited) |
| B7.a | B7.a | Codex | Small | Medium | operator | — | merged | #507 | Invite hierarchy-scope fix — operator approved 2026-05-12; Option A consumer-label follow-up applied by orchestrator |
| B8 | B8 | Claude | Medium | Medium | operator | — | assigned | — | Audit log hierarchy filter (ltree join) |
| B9.1 | B9.1 | Codex | Small | Low | auto | — | merged | #510 | `/sign-in-security` 301 redirect on both dockerfiles |
| B9.2 | B9.2 | Codex | Medium | Medium | operator | B9.1 merged | assigned | — | My Account consolidation + Active Sessions |
| B9.3 | B9.3 | Codex | Small | Low | auto | B9.2 merged | assigned | — | Adaptive 2FA button (4 states) |
| B10.1 | B10.1 | Codex | Medium | Medium | operator | — | assigned | — | `vendor_applicability` table + repository + routes |
| B10.2 | B10.2 | Codex | Medium | Medium | operator | B10.1 merged | assigned | — | Vendor applicability admin editor + wage authority binding |
| B11.1 | B11.1 | Claude | Medium | High | operator | — | assigned | — | `handoff_codes` table + endpoints |
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
