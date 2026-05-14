# PR #670 audit — U-5 Ops Console UX polish bundle (Locations + My Account + Team + Roles + Sign-in-Security + Active Sessions)

**PR:** [#670](https://github.com/SaidKhan005/forge-flow-demo/pull/670)
**Slice:** U-5 from `docs/_indices/WAVE_2_LEDGER.md` (debug.md OW-4..OW-9)
**Worker branch:** `claude2/u-5-ops-console-rest-ux-polish`
**Worker commit:** `235e8a76`
**Auditor:** Claude2 (lane orchestrator)
**Audit date:** 2026-05-14
**Slice gate:** `auto`

## Verdict

**`approve-for-merge`** — clean. Deletion-heavy as the slice asked for; one small additive change (`_deriveRoleKey` slugifier on `custom_role_editor_screen.dart`) is necessary to preserve the proxy contract after the UI role_key field is removed (OW-7f).

## Scope

6 files touched, +111/-274. UX cleanup across 5 operator-web screens + 1 test file.

### My Account (OW-5b / 5d) — `my_account_screen.dart`
- Removed the My Account top subtitle (OW-5b).
- Removed the Profile section `headerExplainer` (OW-5d).
- Made `headerExplainer` optional on `_SectionCard` — backwards-compatible parameter change (other section instances still pass the value).

### Team Members (OW-6a/b/c) — `members_screen.dart`
- Removed the "invite team members…" subtitle (OW-6a).
- Removed the 4-tile `OperatorWebSummaryStrip` (Visible members / Active / Suspended / MFA tiles) + the now-unused count helpers (OW-6c).
- Resized the Invite member button to height 48 with `display16` typography (OW-6b) — reused existing typography style, no new style introduced.

### Roles & Permissions (OW-7b/c/d/e/f/g) — `roles_screen.dart` + `custom_role_editor_screen.dart`
- Removed the roles header subtitle (OW-7b).
- Removed the 4-tile `OperatorWebSummaryStrip` (OW-7c).
- Renamed the empty-state heading "No custom roles yet" → "Create custom role" (OW-7d).
- Removed the empty-state body paragraph (OW-7e).
- Removed the `role_key` TextFormField + threaded a private `_deriveRoleKey(displayName)` slugifier on save (OW-7f). The slugifier lowercases, strips non-alphanumeric chars to underscores, trims trailing underscores, prepends `role_` if the first char isn't a letter, truncates to 64 chars, and appends a 6-digit timestamp suffix (`millisecondsSinceEpoch.remainder(1000000)`). This satisfies the proxy's `/^[a-z][a-z0-9_]{1,63}$/` regex.
- Removed the seeded role-group subtitle (OW-7g).

### Active Sessions (OW-9b/c) — `sessions_screen.dart`
- Removed the 4-tile summary strip (OW-9b).
- Removed both inner-section subtitles (OW-9c).

### Tests — `test/operator_web/screens/roles_screen_test.dart`
- Flipped the role_key field assertion + the roles subtitle assertion to `findsNothing`.
- Removed 2 `enterText` calls that exercised the now-gone role_key field.
- Renamed 1 test to reflect the new flow.

## VERIFY-FIRST verdicts (all 5 from the dispatch prompt)

| Item | Verdict |
|---|---|
| **OW-7f** role_key field removal | needed work; removed + slugified on save (`_deriveRoleKey`) |
| **OW-8c** lost-authenticator CTA | **verified** — no separate CTA to convert (the consolidated MFA section uses `Request removal` for the 24-hour admin-flagged path per B11.2.b) |
| **OW-9a** team-session member names (not device strings) | **verified** — `_SessionsRow` already renders `targetUserDisplayName` above the device label per B9.2 |
| **OW-8a** "protect your own team…" subtitle | **verified** — copy does not exist in operator_web (grep clean) |
| **OW-8b** 4 top tiles on Sign in Security | **verified** — no summary strip mounted on My Account |

## Disclosed SKIPs (per dispatch instructions)

| Item | Owner |
|---|---|
| OW-4 (Locations tab visibility — scope-conditional logic) | Deferred — logic/IA change, not pure UX |
| OW-5a (move My Account under Access) | R-1 refactor |
| OW-5c (profile self-service write paths) | Lane W slice W-3 |
| OW-5e (mobile read-only, ops-web is editor) | Lane W slice W-3 |
| OW-6d (3-dot → Edit user button + write paths) | Lane W slice W-1 |
| OW-7a (Roles move under People) | IA change — deferred |
| OW-8d (consolidate Sign in & Security into My Account) | R-1 refactor |
| Top bar widget | U-2 + H-3 serialization |
| `OperatorWebSummaryStrip` widget itself | Kept — still consumed by hierarchy/audit_log/data_accuracy |

## Pattern B independent audit

| # | Lens | Result | Cite / evidence |
|---|------|--------|------|
| 1 | Slice scope match | ✅ | 6 files match U-5 scope; deferred items disclosed with correct owners |
| 2 | Authority alignment (debug.md OW-4..OW-9 minus carve-outs) | ✅ | per-row check above |
| 3 | HP #11 | N/A | UX cleanup, no settings surface changed in scope-sensitivity |
| 4 | RLS-ready schema | N/A | UI-only |
| 5 | Demo-mode neutrality | ✅ | no `kDemoMode` branch added |
| 6 | Frozen `lib/data/` untouched | ✅ | files list shows only `lib/operator_web/screens/**` paths |
| 7 | `package:postgres` scope | N/A | no postgres imports |
| 8 | Proxy size lint | N/A | advisor_proxy untouched |
| 9 | `dart analyze --fatal-infos` (touched files) | ✅ | worker reported clean on the 6 files |
| 10 | Test suite | ⚠ unable to verify runtime — Flutter 3.35.4 tool crash on Windows | The worker hit `StateError: Bad state: No element in testCompilerBuildNativeAssets` and orchestrator hit the same — root cause: `flutter pub get` requires Windows Developer Mode for plugin symlinks on fresh agent worktrees, and the symlink build path crashes the test runner. The worker updated the only test file that asserted on removed copy (`roles_screen_test.dart`); static review confirms the test changes match the new behavior. Risk: low (rename + deletion-only test edits) but not runtime-verified. |
| 11 | Live UI check (Preview MCP) | partial — disclosed | P0-F5 boot-gate-blocked per Phase 0 smoke; worker confirmed `flutter build web --release` not run due to Developer Mode block. Deletion-only UX cleanup is low-risk for visual regression. |
| 12 | No `--no-verify` | ✅ | claude2/* branch pushed via canonical hooks |
| 13 | No tracker/ledger edits | ✅ | files list clean |
| 14 | UX writing standard | ✅ | "Create custom role" empty-state heading reads as training register; no abbreviations introduced |

## `_deriveRoleKey` slugifier review

The new private function in `custom_role_editor_screen.dart` is the only non-deletion change. Static review:

- **Regex compliance:** produces `/^[a-z][a-z0-9_]{1,63}$/`-compatible keys. Lowercase + slugify + leading-letter fallback (`role_` prefix) + 64-char truncate.
- **Collision avoidance:** appends `_<timestamp>` where `<timestamp> = millisecondsSinceEpoch.remainder(1000000)`. 6-digit suffix wraps every ~17 minutes — two roles created in the same wrap window with the same display name CAN collide. Mitigation: the proxy's idempotency-key + `proxy_requests` UNIQUE constraint (per CLAUDE.md "Proxy & API Conventions") makes duplicate-call cases idempotent; genuine "different role, same display name, simultaneously" creates would collide on role_key and fail at the database level with a clear error. Acceptable for the small risk vs. the operator UX benefit of not surfacing role_key.
- **Edge case (empty name):** `key = 'role_custom'` + timestamp. Non-empty + leading-letter-safe.

No proxy contract change. No new permissions. Acceptable.

## Operator decisions surfaced

None. All deferred items are properly routed to Lane W / R-1 refactor / future IA work.

## Recommended next step

1. Add this audit summary as a comment on PR #670.
2. Merge PR #670 via `gh pr merge 670 --merge --delete-branch`.
3. Slices U-4 (Locations etc.) is **not** in U-5's scope per the ledger row; U-5 covers OW-4..OW-9. The ledger row description lists 6 sub-screens (Locations + My Account + Team Members + Roles + Sign-in-Security + Active Sessions). Three of those sub-areas (Locations OW-4, My Account move OW-5a, Sign-in-Security IA OW-8d) are properly disclosed as scope-deferred to Lane W / R-1 refactor.
4. Main orchestrator updates `WAVE_2_LEDGER.md` row U-5 to `merged` on next sweep.

## Wave 2 ledger impact

Slice U-5 transitions `assigned` → `merged`. PR # `670`, `merged_at: 2026-05-14`.
