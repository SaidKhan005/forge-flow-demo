# PR #501 Follow-Up — B1.a Copy Fix (Option 1)

**Slice:** B1.a follow-up (orchestrator-fix-by-default)
**Authority anchor:** `docs/_audits/post_codex_wave/pr_501_b1_a_inheritance_notice_propagation_audit.md` Option 1 recommendation; CLAUDE.md HP #11 (hierarchy-scoped settings honesty).
**Gate:** `auto` (UX copy only; no schema/proxy/auth touch)

## What changed

Worker's #501 implementation gated the notice on `coveredCount == 1` but carried PR #485's copy verbatim ("Other locations under this scope may have local overrides — review each location individually for accuracy"), which is nonsensical when there's only one location. Per the audit doc's Option 1 recommendation, rewrote the copy for both screens:

**Before:**

> Showing covers and wage data accuracy from $location. Other locations under this scope may have local overrides — review each location individually for accuracy.

**After:**

> This scope only covers $location. Adjusting data accuracy here is equivalent to a per-location change — there are no other locations under this scope to inherit from.

(Mirror copy applied to polling screen.)

## Files touched

| File | Change |
|---|---|
| `lib/admin/screens/per_location_data_accuracy_screen.dart` | one-string edit at notice body (~line 502) |
| `lib/admin/screens/polling_and_pricing_admin_screen.dart` | one-string edit at notice body (~line 669) |
| `test/admin/data_accuracy_polling_hierarchy_scope_screen_test.dart` | four `find.textContaining` substrings updated to match new copy |

## Verification

- `dart analyze lib/admin/screens/per_location_data_accuracy_screen.dart lib/admin/screens/polling_and_pricing_admin_screen.dart test/admin/data_accuracy_polling_hierarchy_scope_screen_test.dart` → No issues found.
- `flutter test test/admin/data_accuracy_polling_hierarchy_scope_screen_test.dart` → **14/14 pass** (6 pre-existing + 8 B1.a additions).

## Verdict

**approve-for-merge** (orchestrator self-merge per audit-first-then-pr-then-merge doctrine).

## Notes

- HP #11 honesty intent preserved: notice still fires at non-location scope covering one location, but now the wording matches the gate.
- PR #485's original Timing-tile copy (`admin_timing_setup_screen.dart:178`) is kept untouched because its gate is `scopeLocationCount > 1` — the original copy makes sense for that gate. The mismatch was specific to B1.a's `== 1` inversion.
- Codex's B7.a branch is now unblocked (B3 merged).
