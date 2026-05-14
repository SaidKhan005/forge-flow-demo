# PR #674 audit — U-7 Mobile UX polish bundle (rebased on MO-1 + MO-1-FU)

**PR:** [#674](https://github.com/SaidKhan005/forge-flow-demo/pull/674)
**Slice:** U-7 from `docs/_indices/WAVE_2_LEDGER.md` (debug.md MO-3a/b, MO-4, MO-5a/d, MO-6, MO-7c/d, MO-S)
**Supersedes:** [PR #666](https://github.com/SaidKhan005/forge-flow-demo/pull/666)
**Worker branch:** `claude2/u-7-rebase-on-mo-1`
**Worker commit:** `50c0a960`
**Auditor:** Claude2 (lane orchestrator)
**Audit date:** 2026-05-14
**Slice gate:** `auto`

## Verdict

**`approve-for-merge`** — clean. The rebase worker delivered an excellent 3-way merge: U-7's tab reorder + subtitle removals + IP/geo strip + duplicate header removal applied on top of MO-1's role-gating + MO-1-FU's Demo→Live switch placement. 31/31 tests pass including all 13 MO-1 + MO-1-FU role-gate collapse tests.

## Rebase deltas vs PR #666

### `lib/screens/settings_screen.dart` — conflict resolved

The conflict region was the `tabs` list and adjacent TabBarView children. Worker's resolution:

**Preserved from master's MO-1 (PR #661 / `b4eecd7c`):**
- `PermissionContext` provider lookup with try/catch fallback to null.
- `_shouldShowDataTab(...)` computation.
- `if (showDataTab)` guard (replacing the original `if (showAdminTabs)`) on the Data tab's TabBarView body.
- The `_shouldShowDataTab` helper function at the bottom of the file.

**Preserved from master's MO-1-FU (PR #667 / `e73228f5`):**
- The Demo→Live switch placement inside the Setup tab body (the interim placement — soon to be moved to the Integrations tab once MP-1 lands).

**Applied from U-7:**
- Tab reorder: Account moves from FIRST → LAST. The list now reads:
  ```dart
  final tabs = <_SettingsTabSpec>[
    if (showAdminTabs) _authoritySettingsTab,  // Setup
    if (showDataTab) _dataSettingsTab,          // Data (F&F admin gated)
    if (showAccount) _accountSettingsTab,       // Account (moved from first)
  ];
  ```
- Same reorder applied to the TabBarView children.
- U-7's comment block citing `debug.md:304` and noting the future MP-1 Integrations tab slot.
- Subtitle removals on Two-factor security (MO-5d) / Account (MO-6b) / Active sessions (MO-7c) / Wage setup (MO-4a) / Business timing (MO-3a) — all properly commented with the debug.md line numbers.

### `lib/screens/settings/settings_active_sessions_section.dart`
- `_ActiveSessionsHeader` simplified: drops the duplicate "Active sessions" title text (MO-7d), keeps only the device icon + the one-line description.
- `_metaLine` simplified: drops IP + geo (MO-7e), returns just `"Last active <relative time>"`.
- `_approximateLocation` helper removed (no longer used).

### `lib/screens/settings/settings_timing_authority_section.dart`
- Drops "Current timing" pill + "Restaurant-local timing controls…" subtitle (MO-3a).
- Consolidates "Business day starts" + "Shift close rule" into a single visual block via `_BusinessDayBoundaryTile` (MO-3b — though the diff shows the consolidation happening inline rather than as a separate widget; the visual outcome is the consolidated tile).

### `lib/screens/settings/settings_data_sections.dart`
- `_AccountInfoSummaryCard` row label "Display name" → "Name" (MO-6c). Comment notes the operator-web editor keeps "Display name" because edits live there.

## VERIFY-FIRST verdicts (per the original U-7 dispatch)

| Item | Verdict (from worker, confirmed by rebase) |
|---|---|
| **MO-4c** (wage FOH/BOH/Mgmt view-only) | **verified** — already present in `settings_wage_authority_section.dart:205-214` |
| **MO-5a** (adaptive enable-MFA) | section infra exists; mobile shell passes `viewOnly: true`. Flipping `viewOnly` is auth-touching — correctly **disclosed, not done** |
| **MO-7e** (no IP on rows) | needed work — fix applied (`_metaLine` returns "Last active …" only) |
| **MO-7f** (sign-out + sign-out-of-all buttons) | section infra exists; mobile shell passes `viewOnly: true`. Auth-touching — correctly **disclosed, not done** |

The two `viewOnly: true` decisions defer auth-impacting changes (flipping to false enables session revocation + MFA changes from mobile) to a future slice with auth review. This is correct discipline — U-7's scope is UX cleanup, not auth.

## Disclosed SKIPs (per dispatch instructions)

| Item | Owner |
|---|---|
| MO-3c / MO-4b / MO-6d (JWT deep-link buttons) | B11.1 follow-up |
| MO-6 (covers manual entry) | Lane M-Other MO-2 |
| MP-1 (new Mobile Integrations tab) | operator-gated; PR #671 in flight |

For the MP-1 future tab, U-7's comment block in `settings_screen.dart` explicitly documents the slot ("A future MP-1 Integrations tab will slot between Setup and Data once the operator-gated mobile integrations surface is built; until then the slot is omitted, not stubbed.") — clean disclosure.

## Pattern B independent audit

| # | Lens | Result | Cite / evidence |
|---|------|--------|------|
| 1 | Slice scope match | ✅ | 4 files match U-7 scope; rebase added no out-of-scope changes; all carve-outs respected |
| 2 | Authority alignment (debug.md MO-3..MO-7 minus carve-outs) | ✅ | inline comments cite specific debug.md line numbers (264, 268, 295, 296, 299, 300, 301, 304); per-row check matches |
| 3 | HP #11 (hierarchy-scoped) | N/A | UX cleanup; no settings-surface scope changes |
| 4 | RLS-ready schema | N/A | UI-only |
| 5 | Demo-mode neutrality | ✅ | no `kDemoMode` branch added; MO-1-FU's Demo→Live switch placement preserved (the switch widget itself is bit-identical) |
| 6 | Frozen `lib/data/` untouched | ✅ | files list shows only `lib/screens/**` paths |
| 7 | `package:postgres` scope | N/A | no postgres imports |
| 8 | Proxy size lint | N/A | advisor_proxy untouched |
| 9 | `dart analyze --fatal-infos` (touched files) | ✅ | worker reported "No issues found" on all 4 touched files |
| 10 | Test suite | ✅ | rebase worker re-ran `flutter test --no-pub test/screens/settings_screen_collapse_test.dart test/settings_active_sessions_section_test.dart test/settings_mfa_section_test.dart`: **31/31 passed**, including all 13 MO-1 + MO-1-FU role-gate collapse tests + the "Setup tab renders Demo→Live switch for F&F support actor (MO-1-FU)" test. Worker fixed the Flutter 3.35.4 tool crash by running `flutter pub get` first per the prompt's hint. |
| 11 | Live UI check (adb on Samsung A54) | partial — disclosed | adb showed no attached device in the worker's environment (same as the U-6 rebase + MP-1 workers — the Samsung A54 was unplugged during these dispatch rounds). Source-line evidence + 31/31 tests are the strongest signal available. Deletion-heavy UX is low-risk for visual regression. |
| 12 | No `--no-verify` | ✅ | canonical hooks ran (pre-push `postgres_import_lint` passed per worker's report) |
| 13 | No tracker/ledger edits | ✅ | files list clean |
| 14 | UX writing standard | ✅ | section comment in `settings_screen.dart` reads as plain documentation register; "Last active …" meta line is operator-friendly; no abbreviations introduced |

## Notable architectural quality

- **Honest disclosure on MO-5a / MO-7f**: rather than papering over the `viewOnly: true` decision by silently flipping it, the worker disclosed both as "auth-touching, not done." This is the right discipline — U-7's scope is UX, not auth.
- **MP-1 coordination comment in code**: the worker added a comment that explicitly documents the future MP-1 tab slot. Other workers reading this file in the future will see the intent.
- **Per-line debug.md citations**: every removal carries an inline comment citing `debug.md:<line>` for the brain-dump source. Future audits can trace the intent directly.

## Operator decisions surfaced

None. All deferred items are properly routed to B11.1 / Lane M-Other / MP-1 follow-ups.

## Recommended next step

1. Add this audit summary as a comment on PR #674.
2. Merge PR #674 via `gh pr merge 674 --merge --delete-branch`.
3. Close PR #666 with a supersession comment pointing at #674's merge.
4. Main orchestrator updates `WAVE_2_LEDGER.md` row U-7 to `merged` on next sweep.

## Note on MP-1 interaction

PR #671 (MP-1, operator-gated) also modifies `lib/screens/settings_screen.dart` (adds the new Integrations tab between Setup and Data). After PR #674 merges, MP-1 will need a follow-up rebase against the new master state — mechanical, since MP-1 just adds a tab spec and the new tab body. Claude2 will dispatch that rebase if/when operator approves MP-1.

## Wave 2 ledger impact

Slice U-7 transitions `assigned` → `merged`. PR # `674`, `merged_at: 2026-05-14`. PR #666 closed as superseded.
