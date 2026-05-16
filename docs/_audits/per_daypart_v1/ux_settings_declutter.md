# Audit — Settings UX declutter: strip section verbage + modernize Wage Setup + Data tab

Slice: Per-Daypart V1 UX worker — operator live-walkthrough findings **E / F / G**.
Branch: `claude/ux-settings-declutter` · Base: `master`.
Contract: branch → implement → self-audit → commit + push → open PR → STOP.

## What changed (file:line)

| Finding | Change | Site |
|---|---|---|
| E | Removed decorative sub-paragraph under **Covers setup** | `lib/screens/settings_screen.dart:324` (`_settingsSection(title:'Covers setup')` — `description:` arg deleted) |
| E | Removed decorative sub-paragraph under **Integrations** | `lib/screens/settings_screen.dart:~398` (`_settingsSection(title:'Integrations')`) |
| G | Removed sub-paragraph under **Sync status** | `lib/screens/settings_screen.dart:~410` |
| G | Removed sub-paragraph under **Latest updates** | `lib/screens/settings_screen.dart:~416` |
| G | Removed sub-paragraph under **Data reset** (demo-gated) | `lib/screens/settings_screen.dart:~424` |
| G | Removed sub-paragraph under **Demo date** (demo-gated) | `lib/screens/settings_screen.dart:~431` |
| G | Removed sub-paragraph under **Data alignment** | `lib/screens/settings_screen.dart:~439` |
| F | Restyled read-only mobile Wage Setup to mirror operator-web Wage Authority (flat cards, formula crumb, blended-mix summary) | `lib/screens/settings/settings_wage_authority_section.dart:115-184` (new `build()` view), `:~770-1010` (`_WageInfoCard` / `_WageBadge` / `_WageBucketCard` / `_WageRoleLine`) |
| F (test seam) | Added `initialWageContextForTest` / `initialRowsForTest` (mirrors `SettingsScreen.initialStatus`); production passes nothing | `settings_wage_authority_section.dart:27-45, 49-61` |
| Tests | New acceptance file | `test/screens/settings_ux_declutter_test.dart` |

Deletions: stale `_WageMixStatRow`, `_WageMixDivider`, `_WageMixBucketCard` (only the
old gradient/strip/count-pill read-only chrome; `_WageMixSectionCard`,
`_WageMixStat`, `_WageMixWarningBand`, `_WageMix*Button`, the whole-mix editor
screen + `_EditorRow` are untouched — still drive the editable path).

## HP #11 preservation (explicit)

- `settings_wage_authority_section.dart:~795` — `Key('settings_wage_setup_source')`
  renders **"Source: <provenance>"** (`w?.source.displayLabel`). The provenance
  affordance is preserved verbatim — only its container chrome changed.
- Effective values preserved: front/back wage badges (`fohWage` / `bohWage`) and
  the blended `referenceBlendedWage` headline, all from the same
  `WageStandardContext`. No value math changed.
- Covers "Applies to: <scope>" (`settings_covers_setup_section.dart:428`), the
  Timing Authority value rows, and the Integrations per-category status copy were
  **not** touched — those state a scope / value / state, not decorative prose.
- No HP #11 scope/inherited/effective rendering was removed anywhere.

## Pattern B — 14-lens self-audit

| # | Lens | Verdict | Evidence |
|---|---|---|---|
| 1 | Scope discipline | PASS | Only `settings_screen.dart`, `settings_wage_authority_section.dart`, new test. No parallel-worker files (`sqlite_database_seed`, `shift_dashboard`, `daypart_table`, etc.) touched (`git diff --stat`). |
| 2 | Authority order | PASS | Prompt → CLAUDE.md UX Writing Standard (concise plain English) + HP #2 + HP #11. All honored. |
| 3 | Finding E | PASS | 2 Setup/Integrations `description:` args removed; headers + controls (`SettingsCoversSetupSection`, `SettingsIntegrationsSection`) untouched. |
| 4 | Finding F | PASS | New `build()` mirrors operator-web `wage_authority_screen.dart` grammar: flat `cardGlow`/`backgroundSurface` cards, `borderRadius 8`, formula crumb `@ $/hr · hrs/wk = $` identical to `_WageRowDisplay` (`wage_authority_screen.dart:865-870`). |
| 5 | Finding G | PASS | 5 Data-tab `description:` args removed; freshness rows (`settings_data_freshness_card`) + `SettingsAuditSection`/`DataAlignmentAuditPanel` untouched (`settings_data_sections.dart:1518-1523`). |
| 6 | HP #2 (demo) | PASS | No `kDemoMode` reader branch added; no `demo_*` table; demo-gated Data sections still gated by the existing `_kDemoMode` const only. |
| 7 | HP #11 | PASS | See dedicated section above — Source provenance + effective wages + scope labels all retained. |
| 8 | No read-logic change | PASS | `_load()`, `summarizeMix`, `_applyMixEdit`, repository seam, editor screen unchanged. Only presentation + an additive test-only constructor seam (no production caller). |
| 9 | No functional regression | PASS | `_settingsSection` helper signature unchanged (still accepts optional `description`); editable wage path retains "Edit wage mix"; no control deleted (test `F — editable path …`). |
| 10 | Copy quality | PASS | Plain English, minimal. Bucket helpers shortened to operator-web grammar ("Service team" / "Kitchen team" / "Salaried + management hours"); verbose management sentence dropped. |
| 11 | Static analysis | PASS | `dart analyze` on all 3 touched files → "No issues found!". |
| 12 | Tests | PASS | `settings_ux_declutter_test.dart` (4) + nearest existing `settings_screen_collapse_test.dart` (16) + `settings_covers_setup_section_test.dart` (5) + adjacent integrations/demo-switch/freshness/pointer (13) → all green. |
| 13 | Test honesty | PASS | F mounts `WageAuthoritySection` directly with the prod-parity seam because the seeded-DB `_load()` is unreachable under `flutter test` (section stays in keyless "Loading…" via `SettingsScreen`); documented in the test header. |
| 14 | Commit hygiene | PASS | Single slice commit; hooks installed (step 0); no `--no-verify`; no tracker edits. |

## Local verification (CI dark — disclosed)

- `flutter pub get` → Got dependencies.
- `dart analyze lib/screens/settings_screen.dart lib/screens/settings/settings_wage_authority_section.dart test/screens/settings_ux_declutter_test.dart` → **No issues found!**
- `flutter test test/screens/settings_ux_declutter_test.dart test/screens/settings_screen_collapse_test.dart test/screens/settings_covers_setup_section_test.dart` → **+25 All tests passed**
- `flutter test test/widgets/settings_integrations_section_test.dart test/widgets/settings_demo_live_switch_test.dart test/widget/settings_data_freshness_test.dart test/screens/settings_pointer_row_test.dart` → **+13 All tests passed**

## Residual notes

- The optional `description` param on `_settingsSection` is now unused at every
  call site (kept intentionally — removing it would broaden the diff and the
  guard `if (description != null && description.trim().isNotEmpty)` already
  no-ops). Not an analyzer issue.
- Mobile Wage Setup stays read-mostly; the operator-web deep-link
  ("Manage Wage on Ops Web", `settings_screen.dart`) is unchanged.
