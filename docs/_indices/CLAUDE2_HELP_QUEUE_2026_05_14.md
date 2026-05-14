# Claude2 Help Queue — 2026-05-14

Main-lane orchestrator (Claude #1) saw that Claude #2 finished its Wave 2 queue. This doc hands two follow-up slices to Claude #2 so the parallel pipeline stays full while the main lane works through the auth-heavy W-2 + W-3.

Both slices below are fully self-contained briefs — Claude #2 reads each one cold, picks one, drops into a fresh worktree on `claude2/<slice-name>`, ships through the same `worker contract → PR → orchestrator merges` flow used through Wave 2.

## Status at handoff

- **Main lane: 20 of 18+follow-up slices merged.** Remaining queue: W-2 (cancel pending invite, in-flight), W-3 (profile self-service, in-flight), Q-2 (email/notification soak harness, parked — needs splitting), R-1L/R-2L/S-3 (held pending operator approval on Roles schema).
- **Second-Claude lane closed.** Merged: V-1, U-1, U-2, U-3, U-4, U-5, U-6, U-7, D-1, D-2, MP-1.
- **Master tip:** `dbadb05c` (Wave 2 W-1-FU: unlock role + hierarchy rotation in edit-member dialog).
- **Active main-lane workers as of 2026-05-14 03:24 UTC:** W-2 worker, W-3 worker.

## Workflow (same as Wave 2)

1. Branch: `claude2/<slice-name>` off current `origin/master`.
2. Step 0: `pwsh scripts/install_git_hooks.ps1` — fresh worktrees inherit a stale heavy hook that stalls `git push`. ALWAYS run this first.
3. Implement scope; no broadening.
4. Self-audit Pattern B (14 lenses, file:line citations).
5. Tests + `dart analyze --fatal-infos` clean.
6. Commit + push + open PR. Base = `master`. PR body MUST include the Pattern B self-audit table + an empty reviewer slot.
7. STOP. Do NOT merge. Do NOT update trackers / ledger / audit docs. Orchestrator audits and merges.
8. Operator-decision findings: escalate in the PR body; do not block on them.

## Slice 1 — W-5-mobile-FU: mobile dashboard header logo propagation

### Origin

`docs/_indices/WAVE_2_LEDGER.md` Lane W row W-5 ("logo propagation to mobile dashboard header"). W-5 (PR #686, merged) shipped the operator-web logo upload + operator-web shell header propagation. The mobile half was explicitly deferred because plumbing `logo_url` through the mobile session shape would touch ~30 test files.

### Authority anchors

- `lib/operator_web/auth/operator_web_auth_source.dart` — already exposes `session.logoUrl` (W-5).
- `lib/services/auth/auth_session.dart` (or wherever the mobile `AuthSession` lives) — does NOT yet carry `logoUrl`.
- `lib/services/auth/permission_context_loader.dart` — assembles the session payload from `findSelfProfile` SQL.
- `lib/infrastructure/persistence/postgres/repositories/users_repository.dart` — `findSelfProfile` reads from `users` joined with `operators`. The `operators.logo_url` column exists (`db/migrations/202605070000_phase_11W_7_operator_account_fields.sql`).
- Mobile dashboard header: `lib/screens/shift_dashboard.dart` or whichever Forge & Flow mobile screen renders the brand-mark. Search for `AppBar` or splash-icon references in `lib/screens/`.

### What ships

1. Extend the mobile `AuthSession` shape (`lib/services/auth/auth_session.dart` or equivalent) with an optional `String? logoUrl` field.
2. Update `PermissionContextLoader` to pluck `operators.logo_url` from the existing `findSelfProfile` join and project it onto the session.
3. Update `users_repository.dart`'s `findSelfProfile` SQL if the column is not already in the SELECT projection — confirm by reading the existing query.
4. Mobile dashboard header widget — replace the hard-coded splash-icon brand-mark with a `NetworkImage(session.logoUrl)` + splash-icon fallback. Reuse W-5's `_OperatorBrandMark` pattern from `lib/operator_web/widgets/web_app_shell.dart` (it's a private widget but the logic is portable).
5. Mirror across other mobile surfaces that carry the brand-mark (settings header, sign-in screen post-onboarding) — search `lib/screens/` for splash-icon / brand-mark renders.

### Constraints

- HP #2 — no `kDemoMode` reader-side branch. Demo sessions already seed a base64 `data:image/png;base64,...` placeholder for `session.logoUrl`; mirror that pattern on the mobile demo session factory.
- HP #4 — operator-scoped read. The session payload already enforces operator isolation; do not introduce a cross-operator read.
- DO NOT raise `kAdvisorProxyMaxLines`. No proxy edits expected.
- UX writing standard — plain English on any new copy.
- Test coverage: every `AuthSession` consumer test that pins a session shape needs the new optional field. Grep `AuthSession\(` to enumerate.

### Verification

- `dart analyze --fatal-infos lib/ test/` — clean for touched paths.
- `flutter test test/services/auth/` — full auth suite green.
- `flutter test test/screens/shift_dashboard_test.dart` (or whichever test mounts the dashboard header) — header renders logo when session carries one, falls back when null.
- `flutter test test/` — total pass count + any pre-existing failures (verify pre-existing via `git stash`).

### Pattern B audit

14-lens table with file:line citations. Empty reviewer slot.

### Commit + PR

- Commit: `Wave 2 W-5-mobile-FU: mobile dashboard header logo propagation`
- Branch: `claude2/w-5-mobile-fu-logo-propagation`
- PR title: `Wave 2 W-5-mobile-FU: mobile dashboard header logo propagation`
- Base: `master`.

---

## Slice 2 — Documentation pass: DEBUG_MD_IMPLEMENTATION_STATUS post-Wave-2 sync

### Origin

`docs/DEBUG_MD_IMPLEMENTATION_STATUS.md` was last refreshed before Wave 2 dispatched. Wave 2 has now closed ~20 main-lane slices + ~11 second-lane slices, each anchored to specific `debug.md` line ranges. The status tracker needs a sync so the operator can see at a glance what the brain-dump items have become.

### Authority anchors

- `docs/DEBUG_MD_IMPLEMENTATION_STATUS.md` — the tracker.
- `docs/_indices/WAVE_2_LEDGER.md` — current state of every Wave 2 slice (state column: assigned / in-progress / merged; PR column lists the closing PR).
- `debug.md` — the original brain-dump.
- Merged Wave 2 PRs reference `debug.md:<line-range>` in their body.

### What ships

1. Re-read `docs/_indices/WAVE_2_LEDGER.md` to enumerate every merged Wave 2 slice and its source `debug.md` anchor.
2. For each `debug.md` item that Wave 2 closed, flip its status in `docs/DEBUG_MD_IMPLEMENTATION_STATUS.md` to closed with a citation to the closing PR.
3. For `debug.md` items that Wave 2 partially closed (e.g. W-5's mobile half was deferred), mark partial + cite the follow-up slice name.
4. For items that Wave 2 did NOT touch, leave status as-is.
5. Append a brief 2026-05-14 changelog entry at the top of the doc explaining the sync.

### Constraints

- Read-only on `docs/_indices/WAVE_2_LEDGER.md` — do not edit the ledger.
- Read-only on `debug.md` — do not edit the brain-dump.
- DO NOT touch any other tracker (`PROJECT_TRACKER.md`, `POST_HARDENING_FOLLOWUPS.md`, `DATA_ALIGNMENT_TRACKER.md`).
- If you find ambiguity (e.g. a `debug.md` item that two Wave 2 slices appear to close partially), surface in the PR body's "Operator decision" section rather than guessing.
- UX writing standard — plain English on the status entries.
- No code changes, no tests.

### Verification

- `git diff` — only `docs/DEBUG_MD_IMPLEMENTATION_STATUS.md` modified.
- Read the doc end-to-end after edit. Every "merged" entry cites a PR number. Every "partial" entry names its follow-up.

### Commit + PR

- Commit: `DEBUG_MD_IMPLEMENTATION_STATUS post-Wave-2 sync`
- Branch: `claude2/debug-md-status-post-wave-2`
- PR title: `Docs: DEBUG_MD_IMPLEMENTATION_STATUS post-Wave-2 sync`
- Base: `master`.

---

## Worker contract (recap)

- Branch → implement → self-audit → commit + push → open PR → STOP.
- No merge. No amend. No `--no-verify`. No tracker edits.
- Pattern B audit table in every PR body, with file:line citations.
- Orchestrator audits + merges.
