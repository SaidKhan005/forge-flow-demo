# Business Timing Org Unit Authoring Plan

Status: planned
Branch: `codex/business-timing-org-unit-authoring`
Worktree: `C:\Git Local Repos\forge_flow_demo\.codex_worktrees\business-timing-org-unit-authoring`
Source: `origin/master` at `dc5b4e36`
Date: 2026-05-19

## Scope

Close the Operator Web Business Timing authoring gap for org-unit management
scope. Backend and gateway writes already accept `scopeKind: org_unit`; this
slice only wires the Operator Web route/editor state and focused tests.

## Plan

1. Keep the shared checkout on `master` and work only inside this Codex
   worktree.
2. Add an editor-local scope model so the router can pass business, selected
   org-unit, and selected location context without leaking raw scope jargon to
   the user.
3. Update `BusinessTimingEditorScreen` so scope selection can target:
   business-wide defaults, the selected org unit, or the selected location.
4. Update the router so a selected org unit can open the editor and so existing
   location/operator authoring keeps the same behavior.
5. Add focused widget/router tests proving:
   - org-unit selection writes `scopeKind: org_unit` with the org-unit id
   - existing operator create behavior still writes `operator`
   - existing location selection still writes `location`
6. Run focused widget/router tests, focused analyzer, UX em dash lint, and
   `git diff --check`.

## Lens Audit

| Lens | Code or doc checked | Finding | Required action |
|---|---|---|---|
| Branch and scope | `CLAUDE.md`, `PROJECT_TRACKER.md`, prompt, worktree status | Worktree is isolated; shared checkout remains on `master`. | Continue only in this worktree. |
| Product and route | `operator_web_router.dart`, `business_setup_screen.dart` | Business setup read view is location-scoped, but org-unit management needs an edit path. | Add a small org-unit scoped edit entry in the router. |
| Gateway contract | `web_business_timing_gateway.dart` | Create/patch payloads already carry `scopeKind` and `scopeId`; no backend change needed. | Keep writes on existing operator-scoped gateway. |
| UX and copy | `business_timing_editor_screen.dart`, hierarchy widgets | Editor labels currently show business + location only. | Add plain-English org-unit labels and tree context, no raw `scope_kind` copy. |
| Tests | Existing editor/router tests | Editor tests cover operator create only; router tests cover management scope picker but not org-unit timing authoring. | Add targeted tests and preserve existing assertions. |

## Out Of Scope

- Account, projection retry, admin visibility, migrations, backend routes, and
  proxy behavior.
- Full hierarchy read-surface replacement. Business setup remains
  location-resolved; org-unit work is focused on authoring.

## Residual Risks

- Org-unit editing will use the selected management scope context available in
  the shell. It will not add a new live read preview for org-unit effective
  timing in this slice.
