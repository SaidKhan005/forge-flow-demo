# 05 - New Codex Execution Prompt (Lane A, Slice A0)

This file drafts the Codex prompt for the **first** execution slice
from `03_execution_slices.md`: **Slice A0 - Verification Probe For
B1+B2 Landed Work**. Subsequent slices get their own prompts later.

Format follows `docs/CODEX_PROMPT_GENERATION_STANDARD.md` -
three blocks: Human Context, Claude Paste (routing), Codex Action.

Paste the entire fenced block into a fresh Codex session.

```text
## Block 1 - Human Context

Plain English: B1+B2 hot-fix (proxy runZonedGuarded + sign-in
contract + soak harness skeleton) landed on master via PR #476
(commit c3f1ce0d, 2026-05-12) and follow-up e26e53af. Before any
Lane A downstream slice touches the same files, we need a clean
verification probe that the change is live, the test proves the
contract, and no rebase drift was introduced when subsequent
merges landed. This is a read-only verification slice - no code
changes.

Lane: Lane A code-health Slice A0 - worktree
`.claude/worktrees/lane-a-a0-b1-b2-verify` on branch
`claude/lane-a-a0-b1-b2-verify` off master @ (current HEAD).

Authority:
- docs/_execution/lane_a_code_health/01_product_rule_and_ia.md
- docs/_execution/lane_a_code_health/03_execution_slices.md
- docs/_audits/code_health/a1_proxy_bug_root_cause.md

Current issue:
- Slice A0 is the orchestrator pre-flight check for the rest of
  Lane A. Every other slice depends on confirming the master
  baseline before downstream agents touch the same files.

Human prerequisites:
- Setup/access needed: none (read-only).
- Decision needed: none. If verification finds drift, report
  FOLLOW-UP NEEDED with the drift detail; orchestrator decides
  whether to re-run B1 or proceed.

## Block 2 - Claude Paste

Task:
- Run a verification probe of the B1+B2 hot-fix on master.
  Produce a short audit doc with file fingerprints, test command
  output, and a plain-English status (live / drifted / broken).

Files to modify:
- docs/_audits/code_health/a0_b1_b2_post_merge_verification.md
  (NEW - create this audit doc).

Files to leave alone:
- everything else.

Hard constraints:
- Do not update trackers.
- Do not commit unless explicitly asked.
- Stay inside scope.
- Do not modify any source file. This is a read-only audit slice.
- Do not amend any contract doc.

Implementation tasks (read-only inspection + audit doc):

1. Confirm `tool/advisor_proxy/main.dart` wraps `main()` body in
   `runZonedGuarded` and that the wrapper emits a structured log
   on uncaught async error. Cite the line range.

2. Confirm `tool/advisor_proxy/advisor_proxy.dart`
   `requireOperatorContext` accepts scope-less claims for
   `super_admin` / `ff_support` (no longer returns 403 in that
   branch). Cite the line range.

3. Confirm `lib/services/auth/firebase_auth_login_service.dart`
   carries the post-`e26e53af` parser change (client tolerates the
   scope-less ff_support session record). Cite the line range.

4. Confirm the following pressure-test files exist and compile:
   - tool/pressure/p4_session_soak.dart
   - tool/pressure/p4_operator_day_soak.dart
   - tool/pressure/p4_session_record_predicate.dart
   - test/pressure/p4_session_record_predicate_test.dart

5. Confirm the production gauges from R3 §3 quick-win shipped:
   - Postgres pool gauge accessor on
     `lib/infrastructure/persistence/postgres/package_postgres_executor.dart`
     (per c3f1ce0d commit message).
   - `pubsub_subscriber.ring_buffer_keys` gauge surface on
     `lib/services/realtime/google_cloud_pubsub_subscriber.dart`.

6. Run `dart analyze` against the worktree and capture the exit
   code + summary line.

7. Run `dart test test/advisor_proxy_test.dart` and capture the
   pass/fail count. The B1 contract test in this file is the
   regression guard for the sign-in contract.

8. Run `dart test test/pressure/p4_session_record_predicate_test.dart`
   and capture pass/fail.

9. Optional smoke: `dart run tool/pressure/p4_session_soak.dart
   --dry-run` (if the harness supports a dry-run flag). Note pass
   or skip with reason.

10. Document the production gauge wiring gap explicitly: the R3
    §2 stretch goal `proxy.session_record.incomplete{route,
    missing_field}` is NOT yet wired in production (per c3f1ce0d
    commit message "Smoke runs of the new soak harnesses to be
    executed during PR audit"). This gap is the scope of Slice
    A11.1 and is expected; do not flag as drift.

11. Produce the audit doc at
    docs/_audits/code_health/a0_b1_b2_post_merge_verification.md
    with the lens table from
    docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md
    "Required Output" section:

       | Lens | Code or doc checked | Finding | Required action |
       |---|---|---|---|

    Cite file:line for every row. Use the lenses that apply
    (1, 4, 5, 6, 12, 13). Mark each row "LIVE" / "DRIFTED" /
    "EXPECTED GAP" (the last for the production gauge).

Required tests:
- dart analyze (whole repo).
- dart test test/advisor_proxy_test.dart.
- dart test test/pressure/p4_session_record_predicate_test.dart.

Acceptance criteria:
- [ ] Audit doc exists at
      docs/_audits/code_health/a0_b1_b2_post_merge_verification.md.
- [ ] Every claim in the doc cites file:line.
- [ ] `dart analyze` outcome captured.
- [ ] Both targeted tests captured with pass/fail counts.
- [ ] Production gauge wiring gap explicitly documented as expected
      (Slice A11.1 scope).
- [ ] No source files modified.
- [ ] Branch pushed and PR opened. Agent stops at PR.

Report using the standard execution report.
```

## Notes For The Orchestrator

This slice is the smallest possible Lane A move. It exists to
de-risk every other Lane A slice. Expected agent time: well under
half a day. The audit doc is the deliverable; if `dart analyze` is
clean and both tests pass, the orchestrator can dispatch the
parallel slices (A2.1, A3.1, A4.1, A6.1, A7.1, A10.1, A9.1) in the
same wave.

If the agent reports drift on master (e.g., the `runZonedGuarded`
wrap was reverted by a downstream merge, or the scope-less branch
was undone), the orchestrator pauses Lane A and re-dispatches a
B1-restore slice before any other Lane A work.

The audit doc is **not** a closure-evidence doc (those live at
`06_closure_evidence_*.md` in the lane directory after each slice
lands). The A0 audit doc is a pre-flight artifact that lives under
`docs/_audits/code_health/` alongside `a1_proxy_bug_root_cause.md`
and `c_email_notification_scenario_inventory.md`.

## Subsequent Slice Prompts

A0's prompt is the only one in this file. The orchestrator drafts
the remaining slice prompts (A2.1, A2.2, A3.1, A3.2-A3.4, A4.1,
A4.2, A5+A8, A6.1, A7.1, A9.1, A10.1, A11.1, A11.2) after A0
completes and parallelization can begin. Each follows the same
three-block shape per
`docs/CODEX_PROMPT_GENERATION_STANDARD.md`.
