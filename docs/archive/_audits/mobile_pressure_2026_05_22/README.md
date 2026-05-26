# Mobile Pressure Test — 2026-05-22

Full-surface functional pressure test of the Forge & Flow mobile flavor.
Demo-mode only (`--dart-define=kDemoMode=true`). No Firebase Auth, no real proxy.
Findings only — no fix PRs from these agents.

## Surface split

| Lane | Scope | Agent worktree |
|------|-------|----------------|
| A | Shell + cold-start + nav + notifications | claude/mobile-pressure-lane-a |
| B | Shift Dashboard + Variance (all 3 tabs) | claude/mobile-pressure-lane-b |
| C | Plan (ScheduleBuilder) + Benchmark (BaselineTracker + BaselineManagerScreen) | claude/mobile-pressure-lane-c |
| D | Settings (all tabs + all sub-sections) + Demo Live switch + Role editor | claude/mobile-pressure-lane-d |

## Findings files

- `lane_a_findings.md` — Shell / nav / notifications
- `lane_b_findings.md` — Shift / Variance
- `lane_c_findings.md` — Plan / Benchmark
- `lane_d_findings.md` — Settings / Demo
- `consolidated_findings.md` — merged by orchestrator after all 4 lanes close

## Severity legend

| Level | Meaning |
|-------|---------|
| P0 | Crash / freeze / data loss |
| P1 | Wrong result / broken interaction / dead tap |
| P2 | Degraded UX (spinner that never resolves, copy error, empty state where data expected) |
| P3 | Minor (cosmetic functional issue, edge-case) |

## Emulator

Device: `emulator-5554` (`forge_flow_test` AVD — Android)
Build: debug, flavor `forgeflow`, `--dart-define=kDemoMode=true`
Baseline scenarios: `integration_test/phase_4_emulator/` (5 scenarios, run first by Lane A)
