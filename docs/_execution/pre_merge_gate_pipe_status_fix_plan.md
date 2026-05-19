# Pre-Merge Gate Pipe Status Fix Plan

Date: 2026-05-19
Branch: codex/premerge-gate-pipe-status
Base: origin/master after PR #1025 landed

## Plain English Gap

- The pre-merge gate can print PASS even when `flutter test` fails.
- The reason is shell piping.
- The script runs `flutter test`, pipes output through `tee`, then pipes again through `tail`.
- Without preserving the first command's exit code, the script can read `tail` as successful and miss the failed tests.

## Fix Plan

1. Keep the same gate behavior and output.
2. Save the real `dart analyze` exit code before reading its output file.
3. Save the real `flutter test` exit code before printing the output tail.
4. Fail the gate when tests fail, even if `tee` and `tail` succeed.
5. Add a regression test that prevents the old unsafe pipeline shape from returning.

## Verification

- Run the new script regression test.
- Run `git diff --check`.
