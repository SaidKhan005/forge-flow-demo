# 05 — New Codex Execution Prompt (First Slice: B1.a)

Status: planning draft, 2026-05-12.

This document holds the dispatch prompt for the first Lane B execution slice.
Slice B1.a — "Inheritance notice propagation to Data Accuracy + Polling" — is
the gate-1-independent, low-risk starter. It exercises the precedent set by
PR #485 (`a2766824`) and the inheritance-notice key
`admin_timing_scope_inheritance_notice`, reapplying the pattern to two more
admin tiles. It's the right shape for the first dispatch: small file
footprint, no schema, no auth-critical surface, immediate visible value,
operator-friendly UX win.

The prompt follows the three-block shape per
`docs/CODEX_PROMPT_GENERATION_STANDARD.md`: Block 1 human context, Block 2
the Codex/Claude paste, Block 3 the execution report template.

---

```text
## Block 1 — Human Context

Plain English: Propagate the admin scope-inheritance notice (already live for
the Timing tile per PR #485) onto the Data Accuracy and Polling tiles, so an
F&F admin viewing those tiles at business or org-unit scope with a single
covered location sees the same "Showing X from Y — review each location" notice
they already see on the Timing tile.

Lane: B1.a — worktree `.claude/worktrees/lane-b-b1a-inheritance-notice` on
branch `claude/lane-b-b1a-inheritance-notice` off master @ <short-sha>.

Authority:
- docs/_execution/lane_b_features/01_product_rule_and_ia.md
- docs/_execution/lane_b_features/03_execution_slices.md (Slice B1.a)
- docs/contracts/hardening_rls_and_repository_pattern_contract.md (read-only;
  reference for proxy reads that may surface inheritance state)

Current issue:
- The admin Data Accuracy tile and the Polling and Pricing tile both render at
  business/org-unit/location scope but do NOT show the "covered locations"
  inheritance notice when the scope contains only a single covered location.
  This silently misleads the F&F admin into thinking they're seeing
  aggregate-business state when the value shown is actually a single-location
  pull.
- The matching Timing tile fixed this in PR #485 by rendering a notice card
  keyed `admin_timing_scope_inheritance_notice`. Lane B's slice plan
  (`03_execution_slices.md`) targets B1.a to apply the same pattern to two
  more tiles. HP #11 (hierarchy everywhere) makes this an operator-trust
  requirement, not a polish.

Human prerequisites:
- Setup/access needed: standard admin demo flavour startup
  (`flutter run --release -t lib/main_admin.dart -d web-server
  --dart-define=ADMIN_DEMO_AUTH=true --web-port=8090`). Demo fixture
  `super.admin@forgeflow.test`.
- Decision needed: none — the inheritance-notice copy and key are already
  locked by PR #485. This slice reuses the same widget + key OR extracts a
  shared widget if the inlined copy diverges across the three tiles.

## Block 2 — Claude Paste

Task:
- Implementation. Apply the existing admin scope-inheritance notice pattern to
  Data Accuracy and Polling tiles. No schema, no proxy route change, no auth
  change. Read paths already exist; this slice only changes the rendered
  notice card behaviour at business/org-unit scopes.

Files to modify:
- lib/admin/screens/per_location_data_accuracy_screen.dart — region that
  renders the tile content at business and org-unit scopes; add the notice
  card immediately above the data-accuracy detail card when scope has exactly
  one covered location and is not itself a location.
- lib/admin/screens/polling_and_pricing_admin_screen.dart — same pattern for
  the polling tile.
- (optional) lib/admin/widgets/admin_scope_inheritance_notice.dart — new
  shared widget if the three tiles' notice content diverges only by the
  scope-name interpolation. If the existing inline notice in the Timing tile
  is already small enough, copy-paste with the same key prefix; extract only
  if the implementation becomes duplicative.
- test/admin/screens/per_location_data_accuracy_screen_test.dart — widget
  test asserting notice presence at single-covered-location business/org-unit
  scope and absence at location scope.
- test/admin/screens/polling_and_pricing_admin_screen_test.dart — same.

Files to leave alone:
- lib/admin/screens/admin_timing_setup_screen.dart — Timing tile is the
  precedent; do NOT touch its notice rendering. Reuse the widget or copy
  the structure; do not refactor the precedent.
- db/migrations/** — no schema changes in this slice.
- tool/advisor_proxy/** — no proxy changes in this slice.
- lib/auth/permission_keys.dart — frozen.

Hard constraints:
- Do not update PROJECT_TRACKER.md, MEMORY.md, or any contract.
- Do not commit unless explicitly asked.
- Stay inside scope; do not refactor unrelated tile content.
- Use the same notice key naming pattern (`admin_<tile>_scope_inheritance_notice`)
  for testability — `admin_data_accuracy_scope_inheritance_notice` and
  `admin_polling_scope_inheritance_notice`.
- Reuse PR #485's copy pattern verbatim where the scope shape matches; only
  change "timing" → "data accuracy" or "polling" in user-visible text.
- DO NOT auto-merge. Report and stop.

Implementation tasks:
1. Inspect the precedent in lib/admin/screens/admin_timing_setup_screen.dart
   to confirm the exact notice widget structure (card, header copy, body
   copy, scope-name interpolation) and the key name pattern from PR #485.
2. Add the equivalent notice to lib/admin/screens/per_location_data_accuracy_screen.dart
   gated on (a) selected scope is business or org_unit AND (b) covered
   locations under the scope == 1 AND (c) the rendered detail is pulled
   from that single location. Key: `admin_data_accuracy_scope_inheritance_notice`.
3. Add the equivalent notice to lib/admin/screens/polling_and_pricing_admin_screen.dart
   under the same conditions. Key: `admin_polling_scope_inheritance_notice`.
4. Author/update widget tests covering: (a) notice present at single-covered
   business scope, (b) notice present at single-covered org_unit scope,
   (c) notice suppressed at location scope, (d) notice suppressed at
   multi-covered scopes.
5. Run `dart analyze` clean. Run targeted widget tests.
6. Author the walkthrough doc at docs/_walkthroughs/lane_b_b1a.md following
   the click-path bar set by docs/_walkthroughs/7.58.UX.5.md.

Required tests:
- dart analyze (whole repo)
- dart test test/admin/screens/per_location_data_accuracy_screen_test.dart
- dart test test/admin/screens/polling_and_pricing_admin_screen_test.dart

Acceptance criteria:
- [ ] dart analyze passes with zero new diagnostics.
- [ ] Both new widget tests pass.
- [ ] Manual visual evidence via Claude Preview MCP captured for both tiles
      at single-covered business scope (notice visible) and location scope
      (notice suppressed).
- [ ] No changes outside the named files. No PROJECT_TRACKER.md mutation.
      No contract amendments.
- [ ] Walkthrough doc at docs/_walkthroughs/lane_b_b1a.md is at the
      click-path bar (numbered steps, named widgets, named values).

Report using the standard execution report template (Block 3 below).

## Block 3 — Execution Report Template

# Execution Report — Lane B B1.a

Slice: B1.a — Inheritance notice propagation to Data Accuracy + Polling
Worktree: .claude/worktrees/lane-b-b1a-inheritance-notice
Branch: claude/lane-b-b1a-inheritance-notice
Base commit: <short-sha of origin/master at start>
Final commit: <short-sha after push>
PR: <link>

## What shipped

- <file> — <one-line summary of change>
- <file> — <one-line summary>
- <test file> — <coverage delta>

## Tests run

| Command | Result | Notes |
|---|---|---|
| dart analyze | <pass/fail count> | |
| dart test test/admin/screens/per_location_data_accuracy_screen_test.dart | <pass count>/<total> | |
| dart test test/admin/screens/polling_and_pricing_admin_screen_test.dart | <pass count>/<total> | |

## Browser walkthrough (Claude Preview MCP)

Demo start condition: `flutter run --release -t lib/main_admin.dart ...`,
fixture admin `super.admin@forgeflow.test`, date 2026-05-12, business
"Demo Diner Co.".

| Step | Action | Expected | Observed | Verdict |
|---|---|---|---|---|
| 1 | Admin → Business accounts → Demo Diner Co. → Data Accuracy (business scope) | Notice card renders with key `admin_data_accuracy_scope_inheritance_notice` | | |
| 2 | Switch to a location-scope row in the scope pane | Notice suppressed | | |
| 3 | Admin → Polling tile (business scope, single covered location) | Notice card renders with key `admin_polling_scope_inheritance_notice` | | |
| 4 | Switch to a location-scope row | Notice suppressed | | |
| 5 | Browser console scrape (`error` + `warn`) | 0 logs | | |

Walkthrough doc: docs/_walkthroughs/lane_b_b1a.md

## Carve-outs and follow-ups

- <any unexpected discoveries, contract gaps surfaced, scope creep flagged>

## Blocked decisions

- <if any; otherwise "none">

## Closing

PR opened. Awaiting orchestrator audit. STOPPED per agent-led contract.
```

---

## Why B1.a is the right first slice

- **Zero schema change, zero proxy route change.** Lowest possible blast
  radius; no operator approval gate required (CLAUDE.md "agent-led slices").
- **Reuses an already-shipped pattern.** PR #485's
  `admin_timing_scope_inheritance_notice` is the precedent; copy-paste with a
  new scope-name interpolation is the entirety of the change.
- **Surfaces operator trust immediately.** HP #11 makes hierarchy honesty a
  product requirement, not a polish. Operators see the notice and instantly
  understand the displayed value is single-location.
- **Independent of Gates 1, 2, 3.** Lane A's Inheritance Tree component
  arrives later; this slice doesn't depend on it.
- **Sets the testing/walkthrough cadence for the lane.** Every subsequent
  slice cites this slice's walkthrough doc as the bar for click-path
  specificity.

## After B1.a lands

The next prompt covers B7.a (invite dialog hierarchy-scope bug fix) — also
gate-independent, also high operator-visible value, slightly larger surface
(member invite flow). Slice plans live in `03_execution_slices.md`. Lane B
runs in parallel worktrees once shared seams (Inheritance Tree component from
Lane A) land.
