# Audit — Mobile Settings: clean deep-link buttons to operator-web

**Slice:** fix-settings-deeplink-buttons (Per-Daypart V1 fix worker)
**Branch:** `claude/fix-settings-deeplink-buttons`
**Base:** `master` @ `9adeea85`
**Date:** 2026-05-15

## Bug & root cause

Live walkthrough found mobile **Settings → Integrations** showed a button
"Manage integrations on operator console" with the raw URL
`https://app.forgeflow.app/vendor-connections` printed as visible `Text`
directly below it. The same pattern repeated on every other Settings tab
(Setup → "Manage Timing/Wage on Ops Web"; Account → security / account /
sessions) because **all** Settings deep-link pointers route through one
shared widget, `SettingsPointerRow`, whose `build()` rendered
`Text(_resolvedUrl)` under the button.

Root cause was therefore a single site, not N sites: the
`FU-mobile-settings-pointer-buttons` (Wave 2) iteration kept the bare URL
as a "subtle hint" line. Operator decision for this fix: remove the raw
URL entirely, keep only a polished primary button, deep-link via the
existing handoff seam.

## Change

`lib/screens/settings/settings_pointer_row.dart`
- Removed the `Text(_resolvedUrl)` branch — no bare
  `https://app.forgeflow.app/...` string is ever rendered to operators.
- Button restyled from a default `OutlinedButton.icon` to a polished
  primary `FilledButton.icon` (sunset fill / surface foreground / radius
  6 / mono12 w600) — the same primary-button system as the canonical
  action in `lib/screens/auth/login_screen.dart:457`. Same `SettingsCard`
  shell, so Settings visual cadence is unchanged.
- Coming-soon variant keeps a one-line plain-English reason for the
  disabled state ("This section will move to Operator Web in an upcoming
  release."). That is contextual copy, **not** a URL, so it does not
  violate the no-raw-URL rule. The live variant renders the button only.
- Deep-link behavior unchanged: still the existing C-5 /
  `U-FU-mobile-deeplink` `HandoffCodeGateway` opaque-code seam (no
  parallel mechanism invented), clipboard fallback on proxy-5xx, same
  snackbars. `_resolvedUrl` survives only as the clipboard-fallback /
  legacy `onLaunch` payload — never as visible UI.
- No hardcoded environment URL added to any widget; `_baseUrl` already
  lived in this single config seam and is unchanged.

`test/screens/settings_pointer_row_test.dart`
- Updated the two structural tests to assert `FilledButton`, and added
  explicit `findsNothing` assertions that no `Text` containing
  `app.forgeflow.app` / `forgeflow.app` is rendered (live + coming-soon).
- Behavioral tests (mint+launch, clipboard fallback) unchanged and green.

## Scope check

`rg "app.forgeflow.app|operator console|Manage .* on operator"` across
`lib/screens` confirms every Settings deep-link pointer (Setup ×2,
Integrations ×1, Account ×3) is a `SettingsPointerRow` instance; the
Data tab is status-only with no pointer. `settings_screen.dart` line 404
is a section *description* string ("…jump to the operator console to
connect vendors."), not a URL — left as-is per UX Writing Standard. One
central fix covers all tabs; no parallel raw-URL site remains.

## Pattern B — 14-lens self-audit

| # | Lens | Verdict | Evidence |
|---|------|---------|----------|
| 1 | Slice intent met | PASS | Raw URL removed; polished primary button; deep-link via existing seam — `settings_pointer_row.dart:93-160` |
| 2 | Authority docs honored | PASS | CLAUDE.md "mobile is read-mostly / operator-web is write authority" — button is the only sanctioned escape hatch; UX Writing Standard (plain-English, no URL jargon) honored |
| 3 | No scope creep | PASS | Only `settings_pointer_row.dart` + its test touched; section descriptions & other tabs untouched |
| 4 | Reused existing seam | PASS | `HandoffCodeGateway` C-5 / `U-FU-mobile-deeplink` flow reused verbatim (`_onTap`, `settings_pointer_row.dart:160-210`); no parallel deep-link |
| 5 | No hardcoded env URL in widget | PASS | `_baseUrl` const is the pre-existing single config seam; no new hardcoded URL; no URL rendered |
| 6 | No raw URL shown to user | PASS | `Text(_resolvedUrl)` deleted; test asserts `findsNothing` for any `forgeflow.app` Text (`settings_pointer_row_test.dart:33-41,67-74`) |
| 7 | Visual consistency | PASS | `FilledButton` mirrors `login_screen.dart:457-472` primary system; same `SettingsCard` shell & padding |
| 8 | Read-only invariant | PASS | Mobile Settings stays read-only; widget only deep-links out; no write path added |
| 9 | Demo-mode neutrality (HP #2) | PASS | No `kDemoMode` branch, no `demo_*` table, reader path unchanged |
| 10 | Tests prove the seam | PASS | 4 pointer-row tests + integrations suite green; new no-URL assertions added |
| 11 | dart analyze clean | PASS | `dart analyze` on all touched + dependent files → "No issues found!" |
| 12 | No banned ops | PASS | No `--no-verify`, no tracker edits, no merge |
| 13 | Concurrency respected | PASS | Did not touch seed/shift files reserved by parallel workers |
| 14 | Copy quality | PASS | Coming-soon line is plain-English training tone; button label states destination + action |

## Local verification (CI dark — disclosed)

- `flutter pub get` → `Got dependencies!` (fresh worktree)
- `dart analyze lib/screens/settings/settings_pointer_row.dart lib/screens/settings/settings_integrations_section.dart lib/screens/settings_screen.dart test/screens/settings_pointer_row_test.dart` → **No issues found!**
- `flutter test test/screens/settings_pointer_row_test.dart` → **+4 All tests passed!**
- `flutter test test/widgets/settings_integrations_section_test.dart` → all green (nearest existing settings widget suite)

## Verdict

Self-audit: **approve-for-merge**. Single-site centralized fix, no
scope creep, deep-link seam reused, no raw URL renders, tests prove
both structure and the no-URL invariant. Orchestrator independent audit
pending.
