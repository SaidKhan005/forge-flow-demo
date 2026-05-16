# Audit — Release demo-flag lint: mobile auth-elevation parity

**Slice:** Extend `tool/release_build_demo_flag_lint.dart` (B1.A5) to also forbid
`kDemoMode=true` / `FORGE_FLOW_DEMO_MODE=true` on release artifacts.
**Branch:** `claude/fix-release-demo-flag-lint-parity` · **Base:** `master`
**Authority:** prompt; `CLAUDE.md` HP #2 / `docs/contracts/demo_mode_contract.md`;
PR #801 (mobile Forge&Flow flavor elevates `demo.operator@forgeflow.test` to
F&F admin, gated by `kDemoMode` / `FORGE_FLOW_DEMO_MODE` compile-time defines).

## What changed
- `tool/release_build_demo_flag_lint.dart:24-29` — `_forbiddenFlags` now lists
  all four flags: `ADMIN_DEMO_AUTH=true`, `OPERATOR_WEB_DEMO_AUTH=true`,
  `kDemoMode=true`, `FORGE_FLOW_DEMO_MODE=true`.
- Header comment (`:1-25`), clean-pass message (`:181-185`), Fix message
  (`:193-200`) re-enumerate all four flags; no stale "two-flag" copy remains.
- `test/services/auth/demo_auth_release_guard_test.dart` — header updated; 4 new
  cases (release+kDemoMode FAIL naming flag, release+FORGE_FLOW_DEMO_MODE FAIL
  naming flag, debug+kDemoMode PASS, profile+FORGE_FLOW_DEMO_MODE PASS).
- No `lib/` / seed / shift / benchmark files touched.

## Pattern B — 14-lens self-audit (file:line)

| # | Lens | Verdict | Evidence |
|---|------|---------|----------|
| 1 | Scope adherence | PASS | Only the lint tool + its test changed; `git diff --stat` = 3 files (incl. this audit doc). No `lib/` auth/demo/seed touched. |
| 2 | Contract fidelity (HP #2) | PASS | Demo defines remain valid for demo builds; lint only forbids them in **release** artifacts, consistent with `demo_mode_contract.md` writer-side switch — no reader/table change. |
| 3 | Release-detection unchanged | PASS | `_isReleaseBuild` (`tool/release_build_demo_flag_lint.dart:122-127`) byte-unchanged; only `_forbiddenFlags` list extended. Debug/profile/simulator carve-outs intact. |
| 4 | All 4 flags forbidden on release | PASS | `_forbiddenFlags:24-29` lists all four; tests `flags ADMIN_DEMO_AUTH`, `flags OPERATOR_WEB_DEMO_AUTH`, `flags kDemoMode=true`, `flags FORGE_FLOW_DEMO_MODE=true` all FAIL the build and assert `violations.first.flag` names the offending flag. |
| 5 | No debug/demo false-positives | PASS | New tests `does NOT flag --debug builds with kDemoMode flag` + `does NOT flag --profile builds with FORGE_FLOW_DEMO_MODE flag` both assert `isClean`; pre-existing debug/profile tests still green. |
| 6 | No regression to existing 2 flags | PASS | Pre-existing ADMIN_DEMO_AUTH / OPERATOR_WEB_DEMO_AUTH tests unmodified and green (12/12 suite). |
| 7 | Clean release still passes | PASS | `does NOT flag release builds without demo flags` green; `dart tool/release_build_demo_flag_lint.dart` against repo → "clean". |
| 8 | Message accuracy | PASS | Clean-pass (`:181-185`) + Fix (`:193-200`) + header (`:1-25`) enumerate exactly the four flags; no "ADMIN/OPERATOR only" copy remains (grep clean). |
| 9 | Static analysis | PASS | `dart analyze tool/release_build_demo_flag_lint.dart test/services/auth/demo_auth_release_guard_test.dart` → "No issues found!". |
| 10 | Tests run & green | PASS | `flutter test test/services/auth/demo_auth_release_guard_test.dart` → `+12: All tests passed!`. |
| 11 | Substring-match safety | PASS | Each forbidden token is `<NAME>=true`; `kDemoMode=true` / `FORGE_FLOW_DEMO_MODE=true` are distinct, non-overlapping substrings — no cross-flag false attribution in the `command.text.contains(flag)` loop (`:91-100`). |
| 12 | No tracker/ledger edits | PASS | Only audit doc under `docs/_audits/`; no `PROJECT_TRACKER.md` / ledger / followups touched. |
| 13 | Concurrency isolation | PASS | Confined to `tool/release_build_demo_flag_lint.dart` + its test; conflict-free per prompt. |
| 14 | CI-dark disclosure | PASS | CI gated `workflow_dispatch` (memory `ci_dark_until_2026_06_01`); exact local commands + results disclosed in PR body + lenses 9-10. |

## Local verification (CI dark)
- `dart analyze tool/release_build_demo_flag_lint.dart test/services/auth/demo_auth_release_guard_test.dart` → No issues found!
- `flutter test test/services/auth/demo_auth_release_guard_test.dart` → +12 All tests passed!
- `dart tool/release_build_demo_flag_lint.dart` → scanned 2 workflow file(s); clean.

**Verdict:** clean — parity gap closed within existing release scope; no
release-detection change, no false positives, no regression.
