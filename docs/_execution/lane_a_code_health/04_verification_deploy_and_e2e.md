# 04 - Verification, Deploy, And E2E (Lane A)

Lane A's verification posture follows the advisory pattern at
`docs/contracts/slice_runtime_acceptance_contract.md` (advisory,
not CI-enforced - reviewer judgment per the operator's
2026-05-07 decision). The contract's checklist is reached for; any
gap is reported as `FOLLOW-UP NEEDED`, not auto-blocking.

This lane is code-health-shaped, not feature-shaped, so most
slices are verifiable with unit + integration tests + a static lint
pass. A handful (A6.1, A11.1) expose operator-visible behavior and
need preview-stage Browser-Use evidence.

## Test Gates By Slice

| Slice | `dart analyze` | Slice-scoped tests | Proxy tests | Migration drift | Browser-Use |
|---|---|---|---|---|---|
| A0 | yes | `test/advisor_proxy_test.dart` + `test/pressure/p4_session_record_predicate_test.dart` | yes | n/a | n/a |
| A2.1 | yes | grep for deleted-widget tests; remove any dead test files | n/a | n/a | n/a |
| A2.2 | yes | `test/services/email/email_template_renderer_test.dart` iteration over `EmailTemplateIds.all` | per template | n/a | per template if any UI surfaces a state |
| A3.1 | yes | new `tool/advisor_proxy_size_lint_test.dart` | n/a | n/a | n/a |
| A3.2-A3.4 | yes | targeted `test/advisor_proxy_test.dart` cases for each typed-catch site | yes | n/a | n/a |
| A4.1 | n/a (read-only) | n/a | n/a | n/a | optional perf probe with JSON evidence |
| A4.2 | yes | targeted widget/state tests for the changed Timer sites | n/a | n/a | perf probe with before+after JSON |
| A5+A8 | yes | new `tool/audit_logs_update_lint_test.dart` + `tool/migration_drift_scanner_test.dart` | n/a | yes (`tool/migration_drift_scanner.dart --fix --strict-docs`) | n/a |
| A6.1 | yes | health admin screen widget test + producer envelope contract test | yes (health route) | n/a | yes - admin health screen on preview |
| A7.1 | n/a (docs only) | n/a | n/a | n/a | n/a |
| A9.1 | yes | targeted widget tests for `lever_card` / `week_history_tile` import-path updates | n/a | n/a | n/a |
| A10.1 | yes | re-run `test/pressure/**/*_test.dart` after consolidation | n/a | n/a | n/a |
| A11.1 | yes | new `test/proxy/<session_record_gauge_test>.dart` | yes | n/a | optional - soak harness emits the gauge |
| A11.2 | yes | new tests for `p4_fd_watcher.dart` + storm-parameter sweeps | n/a | n/a | n/a |

## Soak Harness Assertions

For slices that touch the proxy listener-loop, the gauge, or the
session-record contract:

- Run `dart run tool/pressure/p4_session_soak.dart --dry-run` for a
  smoke pass.
- For A11.1 specifically, run with `--seconds=60` against a local
  preview proxy; assert no `proxy.session_record.incomplete` events
  during a clean run.
- For A11.2, run `dart run tool/pressure/p3c_oauth_refresh_storm.dart
  --vendor-mix=power-law --ttl-dist=bimodal --jitter=full --seconds=60`
  and verify no `request.dependency_timeout` rate climb beyond
  baseline.

The harnesses do not need a preview deploy; they run in-process
against a local proxy listener.

## Preview / Staging Plan

Most Lane A slices verify against local + test gates. The slices
that need a preview deploy:

- **A6.1** - operator-visible admin health screen. Preview must
  show producer states pulled from a real `/health` envelope, not
  a fixture.
- **A11.1** - the production gauge wiring needs a preview proxy
  that emits to the gauge sink; soak harness against preview is the
  validation.

For preview deployment, follow:

- `runbooks/preview_environment_runbook.md` (canonical).
- `docs/frameworks/deployFramework.md` for the runbook overlay.

For both A6.1 and A11.1, use:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy_preview_stack.ps1 `
  -PreviewName lane-a-<slice> `
  -DeferProxyStartupDatabase `
  -ProxyMaxInstances 1 `
  -SkipApiEnable `
  -SkipSecretManagerSync
```

Verify `/readyz` for startup liveness. `/health` returns the deep
envelope and may show yellow/red dependencies; that is **expected**
for A6.1 (the whole point is to render producer state honestly).
Do not use `/health` as the startup pass/fail signal.

## Runtime Acceptance Per `slice_runtime_acceptance_contract.md`

For runtime-exposed slices (A6.1, A11.1), the seven-step recommended
acceptance path applies:

1. Code exists on the branch (confirmed by PR diff).
2. Build context contains every runtime file (confirmed by
   `docker build` or `dart pub get && dart compile` against the
   preview image).
3. Deployed image contains those files (preview deploy log).
4. Live route works from real browser origin (preview URL +
   Browser-Use evidence for A6.1).
5. Health metrics represent real producer state (A6.1's whole
   deliverable).
6. Runbook explains recovery (link to existing runbook entries +
   any new entries the slice adds).
7. Migration drift scanner clean
   (`tool/migration_drift_scanner.dart`).

For non-runtime-exposed slices (A2.1, A3.*, A4.1, A5+A8, A7.1, A9.1,
A10.1, A11.2), steps 4-6 are N/A. Steps 1, 2, 3, 7 collapse to
"CI is green".

## Browser-Use Workflow Reference

Per `docs/runbooks/browser_use_codex_acceptance_workflow.md` (the
Codex-driven workflow; out-of-repo - no harness binary lives here),
A6.1's preview check captures:

- Page title and shell load for the admin health screen.
- Each producer state rendered with state + provenance + plain-English
  remediation copy.
- Console warning / error logs (browser dev tools).
- Disabled / forbidden states (sign in as a role without
  `support.observability.read`; confirm the screen is gated).

A11.1's preview check is harness-driven, not Browser-Use; the soak
harness is the verification surface.

## Performance Framework Application

A4.1 (audit) and A4.2 (fixes) follow
`docs/frameworks/PERFORMANCE_FRAMEWORK.md`:

1. Confirm branch and runtime being tested.
2. Run the existing app, not a replacement.
3. Capture baseline (before-measurement JSON path).
4. Identify hotspots with evidence (the 12 `Timer.periodic` sites
   are the starting candidate list).
5. Apply targeted performance-only fixes (A4.2).
6. Re-run measurements (after-measurement JSON path).
7. Verify the runtime (preview URL or local URL).
8. Report exact before/after numbers in the slice's final note.

Performance JSON paths land in `docs/_audits/code_health/perf_probes/`.

## Final Evidence Note (Per Slice)

Each slice agent produces a final execution note in
`docs/_execution/lane_a_code_health/` named
`06_closure_evidence_<slice>_<date>.md` (created after the slice
lands, not now). The note carries:

- Source commit + PR link + merge commit.
- Preview URL + database mode (if applicable).
- Test command list and outcomes.
- Browser-Use evidence (if applicable).
- Mutation evidence (none expected for Lane A; flag if otherwise).
- Performance JSON path (A4.* only).
- Bugs found / fixed during execution.
- Intentionally gated or unsurfaced items.
- Residual risks.

The orchestrator (main chat) audits each PR against the slice
contract + `02_plumbing_audit_matrix.md` findings + the
`slice_runtime_acceptance_contract.md` checklist.

## CI Pipeline Touch List

The following slices add CI gates and need workflow file edits:

- **A3.1** - `advisor_proxy_size_lint.dart` added to the lint job.
- **A5+A8** - `audit_logs_update_lint.dart` +
  `--require-expand-contract` flag on migration drift scanner
  added to the lint job.
- (No others.)

The new lints are zero-config: they need only to be added to the
existing lint job step in the GitHub Actions workflow.

## Hand-Off Posture

Every slice agent stops at PR (CLAUDE.md "Agent-Led Slices"). The
orchestrator audits + merges. Auth-critical / RLS-touching /
schema-touching / proxy-touching slices (A3.*, A5+A8, A6.1, A11.1)
need explicit operator approval before merge regardless of audit
verdict (CLAUDE.md Workflow).
