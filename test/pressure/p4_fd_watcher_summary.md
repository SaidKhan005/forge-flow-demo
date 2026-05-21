# p4_fd_watcher — FdWatcher soak gauge

**Runner:** `test/pressure/p4_fd_watcher_test.dart`
(unit tests for `tool/pressure/p4_fd_watcher.dart`)

**What it pressures:** the file-descriptor count gauge the p4 soak
orchestrator polls on Linux (`/proc/self/fd`) and the cross-platform
no-op path on Windows / macOS. Catches regressions where a soak run on
a non-Linux dev box would either crash, silently emit garbage values,
or schedule a timer that never fires.

**Status at f0bf2702:** PASS. Deterministic — uses an injected
synthetic FD directory + a fixed clock; no real `/proc` access.

## Inputs

- No env vars. Hermetic; uses `Directory.systemTemp` for synthetic
  FD entries.
- Constructor seams: `fdDirectory` (synthetic FD root), `platformOverride`
  (`'linux'` / `'windows'` / `'macos'`), `clock`, `threshold`,
  `pollInterval`.

## What it asserts

- Linux happy path: emits one structured JSON line with
  `metric: soak.fd_count`, `value: <count>`, `threshold_exceeded: false`,
  and a clock-pinned `ts`.
- Windows / macOS no-op: emits one explanatory line with `value: null`,
  the platform name, and a `note` containing "fd_watcher:
  /proc/self/fd not available"; `isPolling` stays `false` so no timer
  is scheduled.
- `threshold_exceeded` flips to true ONLY when observed count is
  strictly greater than the configured cap (==threshold stays false).
- `start()` after `stop()` throws `StateError`.
- Missing FD directory on Linux emits an `error` line instead of
  throwing.

## How to read the output

- Healthy run: 7 unit tests pass; emitted JSON lines decode cleanly
  with the documented `metric`, `value`, `ts`, `threshold_exceeded`
  shape.
- Regression: any shape drift (extra/missing keys) breaks the soak
  orchestrator's report aggregation; a Linux crash on a missing FD
  directory means the defensive `error` branch was removed.

## Related

- Authority: `docs/_audits/code_health/code_hardening_plan_2026_05_21.md`
  §2.4, backlog item #10
- Production code: `tool/pressure/p4_fd_watcher.dart`
- Consumer: `tool/pressure/p4_soak_orchestrator.dart` (Wave 2 Lane Q
  slice A11.2)
- Last touched: see `git log -- test/pressure/p4_fd_watcher_test.dart`
