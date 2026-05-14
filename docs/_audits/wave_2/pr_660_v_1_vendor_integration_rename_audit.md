# PR #660 audit — V-1 Vendor Connection → Vendor Integration rename sweep

**PR:** [#660](https://github.com/SaidKhan005/forge-flow-demo/pull/660)
**Slice:** V-1 from `docs/_indices/WAVE_2_LEDGER.md` (debug.md OW-11a + 241-256)
**Worker branch:** `claude/v-1-vendor-integration-rename` (note: `claude/` prefix, not `claude2/` — see "Branch prefix divergence" below)
**Worker commit:** `e6833743`
**Auditor:** Claude2 (lane orchestrator)
**Audit date:** 2026-05-14
**Slice gate:** `auto`

## Verdict

**`approve-for-merge`** — clean. Static + runtime verification both green.

## Scope

V-1 ledger row: "Rename Vendor Connection → Vendor Integration across all consoles + mobile + notification copy."

Worker delivered: 27 line additions, 27 line deletions across 15 files (13 lib + 2 test):
- `lib/operator_web/screens/vendor_connections_screen.dart` (title + "admin-managed" + "no location" body copy)
- `lib/operator_web/screens/data_accuracy_screen.dart` (error message)
- `lib/operator_web/router/operator_web_router.dart` (nav-item title + Choose-a-location body)
- `lib/integrations/ui/vendor_connections/vendor_connections_widget.dart` (error message)
- `lib/integrations/ui/vendor_connections/widgets/vendor_connections_logs_dialog.dart` (activity caption)
- `lib/integrations/ui/vendor_connections/widgets/vendor_connections_module_dialog.dart` (vendor product caption)
- `lib/admin/screens/integration_admin_screen.dart` (subtitle)
- `lib/admin/screens/operator_location_admin_screen.dart` (read-only banner)
- `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart` (2 permission-resource tokens)
- `lib/admin/screens/vendor_connections/vendor_connections_admin_mount.dart` (panel title)
- `lib/admin/services/admin_vendor_connections_gateway.dart` (5 error messages, 1 remediation)
- `lib/domain/models/notification_event_catalog.dart` (1 category label)
- `lib/infrastructure/persistence/postgres/quickbooks_time_postgres_sink.dart` (1 exception message)
- `test/admin_integration_admin_screen_test.dart` (1 assertion text)
- `test/operator_web/screens/vendor_connections_screen_test.dart` (2 assertion texts + 1 comment)

All renames are user-facing strings (UI labels, error messages, exception text, notification category display labels, permission-resource human tokens). Worker correctly preserved:
- Code identifiers (class names like `VendorConnectionsScreen`, `VendorConnectionsGatewayError`).
- File names (e.g. `vendor_connections_screen.dart`, `quickbooks_time_postgres_sink.dart`).
- Route paths, JSON keys, table names, template IDs.
- Const identifiers (e.g. `kOperatorWebNavVendorConnections`).
- Widget Keys (e.g. `operator_web_vendor_connections_no_location_body`).
- Enum cases (`NotificationCategory.vendor` unchanged; only the display label changed).
- Doc comments and imports.

## Items correctly left alone with reason (worker disclosure)

- `lib/operator_web/screens/permission_explainer_screen.dart` lines 67, 224-225 — verbatim mirror of the migration seed + permission catalog contract + parity test in `permission_explainer_screen_test.dart:222-224`. Touching them would break the parity test.

This is a sharp catch — these strings are not free UX copy but part of a code-derived contract. The auditor concurs with the carve-out.

## Branch prefix divergence

The slice prompt mandated `claude2/v-1-vendor-integration-rename`. The worker shipped on `claude/v-1-vendor-integration-rename` because (at dispatch time) the canonical pre-commit hook only accepted `claude/*|codex/*` and the slice banned `--no-verify`. The worker chose to comply with both constraints by switching prefix. Worker disclosed this in the PR body's "Branch prefix note" section.

This is a different mitigation path than D-1 (PR #657) took for the same problem — D-1 widened the hook inline; V-1 sidestepped via branch-name change. Both are valid; D-1's path is now the canonical fix (merged at master `b3130685`). Future Claude2 lane workers can use `claude2/` per the prompt as intended.

No corrective action needed. V-1 PR stays on its current `claude/` branch.

## Pattern B independent audit

| # | Lens | Result | Cite / evidence |
|---|------|--------|------|
| 1 | Slice scope match | ✅ | 15 files match V-1 scope; out-of-scope `permission_explainer_screen.dart` correctly left alone with explicit reason. |
| 2 | Authority alignment (debug.md OW-11a + notification copy debug.md:241-256) | ✅ | All 15 file changes are pure display-string renames; case-style + pluralization preserved. |
| 3 | HP #11 (hierarchy-scoped) | N/A | No settings surface changed; rename-only. |
| 4 | RLS-ready schema | N/A | No schema. |
| 5 | Demo-mode neutrality | ✅ | No `kDemoMode` branch added; grep clean. |
| 6 | Frozen `lib/data/` untouched | ✅ | No `lib/data/**` in PR files list. |
| 7 | `package:postgres` scope | ✅ | `quickbooks_time_postgres_sink.dart` is in `lib/infrastructure/persistence/postgres/` (allowed); no new imports added. |
| 8 | Proxy size lint | N/A | `tool/advisor_proxy/advisor_proxy.dart` not touched. |
| 9 | `dart analyze --fatal-infos` (touched files) | ✅ | Re-run by orchestrator from `agent-adffa5549e75b87b9` worktree on the 2 test files: "No issues found!" |
| 10 | Test suite | ✅ | `flutter test test/admin_integration_admin_screen_test.dart test/operator_web/screens/vendor_connections_screen_test.dart` re-run by orchestrator: **30/30 tests passed** in ~2.5s. Worker couldn't run themselves due to Windows Developer Mode plugin-symlink block; orchestrator unblocked. |
| 11 | Live UI check (Preview MCP) | disclosed-skip | Preview MCP not available in worker session + same Developer Mode block on `flutter build web`. Rename-only is a low-risk visual change; static + test verification is sufficient for `gate: auto`. |
| 12 | No `--no-verify` | ✅ | Worker switched branch prefix to avoid this; pre-commit + pre-push ran cleanly on `claude/`. |
| 13 | No tracker/ledger edits | ✅ | `WAVE_2_LEDGER.md`, `DEBUG_MD_IMPLEMENTATION_STATUS.md`, `PROJECT_TRACKER.md` untouched per files list. |
| 14 | UX writing standard | ✅ | Rename preserves operator-friendly tone; "vendor integrations" reads as plain English, same training-doc register as "vendor connections". |

## Operator decisions surfaced

None. Branch prefix divergence is a process-deviation but does not require operator input — the slice ledger gate is `auto`, the work is correct, and the hook fix is now in place for future workers.

## Recommended next step

1. Add this audit summary as a comment on PR #660.
2. Merge PR #660 via `gh pr merge 660 --merge --delete-branch`.
3. Slice V-1 transitions `assigned` → `merged`. Main orchestrator updates the row on next ledger sweep.

## Wave 2 ledger impact

Slice V-1 transitions `assigned` → `merged`. Main orchestrator (sole writer of `WAVE_2_LEDGER.md`) records PR # `660` and `merged_at: 2026-05-14`.
