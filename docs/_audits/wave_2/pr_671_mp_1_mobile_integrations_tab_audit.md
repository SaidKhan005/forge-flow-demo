# PR #671 audit — MP-1 Mobile Integrations tab (operator-gated)

**PR:** [#671](https://github.com/SaidKhan005/forge-flow-demo/pull/671)
**Slice:** MP-1 from `docs/_indices/WAVE_2_LEDGER.md` (debug.md MO-7a + MO-7b)
**Worker branch:** `claude2/mp-1-mobile-integrations-tab`
**Worker commit:** `8e2afe4e`
**Auditor:** Claude2 (lane orchestrator)
**Audit date:** 2026-05-14
**Slice gate:** **`operator`** — Claude2 stops at audit verdict; main orchestrator forwards to operator for explicit approval before merge.

## Verdict

**`approve-for-merge — awaiting operator gate`**

Clean, well-disclosed, architecturally correct. No findings that would block operator approval. All slice constraints honored (HP #2 demo-mode reader-side neutrality, B11.1 handoff codes per addendum A1, no new vendor status providers, C-4 demo-live switch preserved verbatim).

## Scope

4 files (1 new section file + 1 new test file + 2 modifications), +821/-41.

### `lib/screens/settings/settings_integrations_section.dart` — NEW (400 lines)
- New `SettingsIntegrationsSection` widget — the Integrations tab body.
- Per-category status rows (POS, Reservation, Labor) — reads `DemoModeStateNotifier.snapshot` (the existing per-(operator, location, category) state surface).
- Mounted `SettingsDemoLiveSwitch` — C-4 master switch widget verbatim, just moved into this section.
- "Manage integrations on operator console" `SettingsPointerRow` — uses existing `HandoffCodeGateway` (same B11.1 short-opaque-code gateway used by other pointer rows like "Manage Account on Ops Web").
- Status pill colors per category state (demo / live / unscoped / unknown).
- Snapshot error handling: when `snapshot.errorMessage != null`, the row appends a "couldn't refresh status" hint rather than hiding the row — last-known good state stays visible.
- Test seams: `launchExternalUrl` + `copyToClipboard` optional parameters for clean test injection; production passes null and falls back to the real implementations.

### `lib/screens/settings_screen.dart` — MODIFIED
- Added the new tab spec + body (`_integrationsSettingsTab` between Setup and Data).
- **Removed the interim MO-1-FU "Demo vs live data" section from the Setup tab.** This is the deliberate canonical home migration: PR #667 (MO-1-FU) placed the demo-live switch in Setup tab as an interim; MP-1 is the slice that gives the switch its final home in the new Integrations tab. The C-4 switch widget itself is unchanged.
- Tab visibility: gated to `showAdminTabs` (all operator admins). Per the slice's read-only design + the existing tab gate pattern.

### `test/screens/settings_screen_collapse_test.dart` — MODIFIED
- Updated tab-count assertions to reflect the new IA (Setup → Integrations → Data → Account for admins; Account-only for non-admins).
- Updated MO-1-FU mount tests to reflect the demo-live switch's new home.

### `test/widgets/settings_integrations_section_test.dart` — NEW (4 widget tests)
- Renders per-category status rows when `DemoModeStateNotifier` is mounted.
- Collapses to neutral "status unavailable" when notifier is missing (unauth shells).
- "Manage integrations on operator console" button mints a handoff code via the gateway + launches the URL.
- Handoff URL assertion: contains no dots (asserting the redemption code is NOT a JWT — JWT property).

## Architecture quality notes

This is the right shape for a new operator-facing mobile surface:

1. **HP #2 reader-side neutrality (explicit comment in source):**
   > "this widget does NOT branch on the build-time `kDemoMode` flag. The per-category status pill is driven entirely by the runtime `demo_mode_state` rows surfaced via [DemoModeStateNotifier]. Demo and prod resolve through the same code path; the only difference is which writer populated the row."

   Compliant. No new reader-side carve-out introduced.

2. **B11.1 handoff codes per addendum A1:**
   - Reuses the existing `HandoffCodeGateway` (same gateway other pointer rows use).
   - In-code comment cites `docs/_execution/lane_b_features/01_product_rule_and_ia.md "Redemption-Code Handoff (B11)" + addendum A1 — short opaque codes only, no JWT in URL parameters`.
   - Test asserts the handoff code contains no dots (JWT property) — explicit anti-regression guard.

3. **Slice scope discipline (explicit comment in source):**
   > "the slice contract for MP-1 forbids adding new vendor status providers — the existing `DemoModeStateNotifier` is the only per-(operator, location, category) state surface the mobile shell currently subscribes to. The richer 'connected / polling-stale / error / no-vendor' matrix the eventual ops-portal screen renders is out of scope for this slice and lives on operator-web."

   This is the right call — defer the richer matrix to operator-web rather than bolt on a parallel provider on mobile.

4. **Stable tab order matches the operator-web Vendor Connections category cards** (POS / Reservation / Labor). Visual consistency across surfaces.

5. **C-4 demo-live switch widget is unchanged.** Only the mount point moved. The widget's auth-touching logic + state machine + operator-bless tests all remain bit-identical.

## Pattern B independent audit

| # | Lens | Result | Cite / evidence |
|---|------|--------|------|
| 1 | Slice scope match | ✅ | 4 files match MP-1 scope; no out-of-scope drift |
| 2 | Authority alignment (debug.md MO-7a + MO-7b + addendum A1) | ✅ | in-source comments cite the canonical authority docs |
| 3 | HP #11 (hierarchy-scoped) | N/A | per-category status is operator/location-scoped via `DemoModeStateSnapshot.operatorId/locationId`; no UI scope-selector surface introduced |
| 4 | RLS-ready schema | N/A | no schema; the existing `demo_mode_state` per-(O, L, C) table is read-only |
| 5 | Demo-mode neutrality (HP #2) | ✅ | explicit in-source comment; status driven entirely by runtime `DemoModeStateNotifier` snapshot; no `kDemoMode` branch added |
| 6 | Frozen `lib/data/` untouched | ✅ | files list shows only `lib/screens/**` paths |
| 7 | `package:postgres` scope | N/A | no postgres imports in mobile UI |
| 8 | Proxy size lint | N/A | `tool/advisor_proxy/advisor_proxy.dart` not touched |
| 9 | `dart analyze --fatal-infos` (touched files) | ✅ | worker reported "No issues found" on touched files; `agent_self_audit.dart` reports baseline pre-existing 49 issues (none in this slice) |
| 10 | Test suite | ⚠ unable to verify runtime locally — Developer Mode block | Worker reported `flutter test --no-pub` 19/19 pass (4 new + 13 collapse + 2 demo-live-switch). Orchestrator cannot re-run on the worker worktree due to the Flutter 3.35.4 + Windows Developer Mode plugin-symlink issue. Static review of test file confirms: per-category render, missing-notifier collapse, handoff-mint-and-launch flow, and JWT-in-URL anti-pattern guard are all covered. Test seam design is clean. |
| 11 | Live UI check (Samsung A54 via adb) | partial — disclosed | adb showed no attached device in the worker's environment. Release APK BUILT successfully (60.5 MB, kDemoMode=true) and disclosed for operator manual sideload + click-path verification — appropriate fallback for operator-gated slice. Operator should plug in the Samsung A54 and walk the click-path before approving. |
| 12 | No `--no-verify` | ✅ | claude2/* branch pushed via canonical hooks |
| 13 | No tracker/ledger edits | ✅ | files list clean |
| 14 | UX writing standard | ✅ | "Manage integrations on operator console" reads as plain English, training register; no abbreviations |

## Operator decisions surfaced

Things the operator should confirm before approving merge:

1. **Demo-live switch placement reversal:** PR #667 (MO-1-FU) placed the switch in Setup tab as an interim; this PR moves it to the new Integrations tab. Confirm the canonical placement is correct — both the original Wave 2 prompt and debug.md MO-7b call for the switch to live in the new Integrations tab. The C-4 widget itself is unchanged.

2. **Sideload click-path verification:** orchestrator could not run the on-device verification because adb showed no device attached during the worker's session. Operator should plug in the Samsung A54 + sideload the built APK + walk the click-path: Settings → Integrations tab → toggle demo-live switch → tap "Manage integrations on operator console" → verify handoff URL launches browser to operator-web with `?code=<22-char base64-url>&nav=vendor_connections` parameter (NO dots — not a JWT).

3. **Handoff `nav=vendor_connections` parameter:** the worker mirrored `kOperatorWebNavVendorConnections` from operator-web's router. Confirm this is the right landing surface (the recently-renamed "Vendor Integrations" surface — V-1 renamed the display string but kept the const identifier).

4. **Per-category richer status matrix deferred:** the slice intentionally does NOT show "connected / polling-stale / error / no-vendor" granularity; only demo/live/unscoped/unknown. Richer state lives on operator-web. Confirm this matches operator intent (the slice prompt confirms this is correct).

5. **MP-1's interaction with U-7 rebase (in flight):** U-7 rebase worker is also modifying `lib/screens/settings_screen.dart`. Whichever lands first, the other will need an additional rebase. This is mechanical (both PRs add/remove tabs in the same list) and would be handled by Claude2 as a follow-up rebase dispatch. Not blocking MP-1 audit verdict, but the operator should be aware.

## STOP at audit

Per the operator-gated discipline:

- Claude2 lane orchestrator does NOT auto-merge this PR.
- Main orchestrator picks up this audit doc + pings operator.
- Operator approval is required before merge.
- If approved, main orchestrator handles the merge (it lives on the same auth/demo-touching axis as B9.2, C-4, B11.x).

## Wave 2 ledger impact (after operator approval)

Slice MP-1 will transition `assigned` → `merged` after operator approval. PR # `671`. Main orchestrator records `merged_at` on next sweep.
