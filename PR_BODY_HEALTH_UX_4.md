## What & why

The **System health** screen's right pane rendered a verbose hierarchy **scope notice** titled "Where this applies" (a Location-group pill, a "Section details" expander, "Source / Set here / Does not inherit", "Effective value", and an explainer). This was clutter that was not in the approved design, **and** it was misleading: System health is **platform-wide** — the proxy `/health` envelope carries **no operator/tenant/scope identifiers** (`docs/contracts/proxy_health_contract.md`), so a per-scope "selected scope / source / effective value" block does not belong on this screen.

This slice (Slice 4 of the System health redesign) **removes** that block and **replaces it with one short muted line**, rendered only when a hierarchy scope is selected, so HP#11 stays honest that health is not scoped:

> These checks are platform-wide. The selected scope does not change them.

**Pure presentation.** No gateway, model, contract, route, fetch-logic, auth/RLS/schema, or dependency changes.

## Scope still flows to the gateway (load-bearing)

The hierarchy scope is **still sent to the fetch** unchanged — only the on-screen per-scope *display* block is gone. The fetch in `lib/admin/screens/health_admin_screen.dart:277-283` still passes:

```dart
final envelope = await widget.gateway.fetch(
  HealthAdminFetchRequest(
    operatorId: widget.hierarchyScope?.operatorId,
    locationId: widget.hierarchyScope?.locationId,
    locationIds: widget.scopeLocationIds,
  ),
);
```

The updated test asserts `gateway.requests.single.operatorId == 'op-a'`, `locationId` is null, and `locationIds == {'loc-a','loc-b'}` — proving scope still reaches the gateway. `AdminHierarchyScopeIntent` (from `admin_route_handoff.dart`) is therefore retained.

## Pattern B self-audit

| # | Step (from task) | Verdict | Evidence (file:line) |
|---|---|---|---|
| 1 | Remove the entire `if (widget.hierarchyScope != null) HierarchyScopeNotice(...)` block from `build()` | PASS | `lib/admin/screens/health_admin_screen.dart` — block gone; replaced at `:340-356` (the prior `SizedBox(height: 12)` after `_Header` at `:339` is kept; the note carries its own `bottom: 12` padding so spacing is preserved, no double gap) |
| 2 | Replace with ONE short muted line, key `admin_health_platform_note`, exact text, only when `hierarchyScope != null`, same position (after `_Header`, before error banner), outside the envelope body | PASS | `lib/admin/screens/health_admin_screen.dart:347-355` — `Text('These checks are platform-wide. The selected scope does not change them.', key: Key('admin_health_platform_note'), style: AppTextStyles.body12(color: AppColors.textMuted))`; sits in the same `children` list, before `_ErrorBanner` (`:357`) and `_envelopeBody` (`:362`) |
| 3 | Remove now-unused imports (`hierarchy_scope_notice.dart`, `admin_scope_notice_adapter.dart`) only if no longer referenced; keep `admin_route_handoff.dart` | PASS | Both imports removed (`lib/admin/screens/health_admin_screen.dart` import block `:45-51`). `adminScopeLevel` / `HierarchyScopeNotice` had no other reference in the file (grep: only the removed block). `admin_route_handoff.dart` kept (AdminHierarchyScopeIntent used by fetch). `dart analyze` clean → no unused-import / undefined-name. |
| 4 | Update test: drop the on-screen `Demo Diner / Downtown` assertion; keep gateway-scope assertions; add `findsNothing` for `admin_health_scope_notice` + `findsOneWidget` for `admin_health_platform_note` | PASS | `test/admin/health_admin_screen_test.dart:181-189` (new key assertions), `:194-200` (kept gateway-scope assertions). Old `find.textContaining('Demo Diner / Downtown')` removed. |
| 5 | No other test references the health scope notice / old text | PASS | Grep across `test/admin/`: the only other `Demo Diner / Downtown` hit is `observability_admin_screen_test.dart:111` (a *different* screen) and the other `*_scope_notice` keys belong to data-accuracy / default-role-catalog screens. None touch the health screen. `health_admin_no_tenant_identifier_test.dart` has no scope-notice reference. |
| 6 | Copy law: plain English, no em dash | PASS | `dart run tool/ux_em_dash_lint.dart` clean (see below); the new line uses a full stop, not an em dash. |

## Verify output

**1. `dart run tool/ux_em_dash_lint.dart`**
```
ux_em_dash_lint: scanned 211 operator-facing file(s) across 13 scoped root(s).
ux_em_dash_lint: clean — no operator-facing string uses an em dash. (The standalone '—' empty-state sentinel is exempt.)
```

**2. `dart analyze lib/admin/screens/health_admin_screen.dart test/admin/health_admin_screen_test.dart`**
```
Analyzing health_admin_screen.dart, health_admin_screen_test.dart...
No issues found!
```
(Confirms no unused imports and no undefined names after the import removal.)

**3. `flutter test test/admin/health_admin_screen_test.dart test/admin/health_admin_no_tenant_identifier_test.dart test/admin_shell_widget_test.dart`**
```
00:09 +41: All tests passed!
```
(41/41 — includes the updated `manual check carries selected hierarchy scope to gateway`, the no-tenant-identifier test, and all admin shell tests.)

Pre-push hook lints also passed: `postgres_import_lint`, `ux_em_dash_lint`, `ignore_justification_lint`, `operator_web_size_lint`, `skip_quarantine_lint` — all clean.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
