# `.githooks/`

Versioned git hooks for the Forge & Flow repo. Tracked in git so hook
behavior can be shared when we intentionally enable it.

## One-time setup per clone

Git does not look at `.githooks/` automatically. After cloning, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install_git_hooks.ps1
```

Verify with:

```bash
git config core.hooksPath
# expected when hooks are active: .githooks
```

To disable the hooks for this clone:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install_git_hooks.ps1 -Disable
```

## Active Hooks

### `pre-commit`

- Blocks commits made from `.claude/worktrees/**` or `.codex_worktrees/**`.
- Runs migration guardrails when staged files include `db/migrations/*.sql`.
- Prints a tracker-truth reminder when code and `PROJECT_TRACKER.md` are
  staged together.

### `pre-push`

- Blocks pushes made from `.claude/worktrees/**` or `.codex_worktrees/**`.
- Runs cheap repo lints only when pushed files touch their relevant surfaces:
  `postgres_import_lint`, `index_leading_column_lint`,
  `permission_key_lint`, `migration_cutoff_lint`,
  `release_dart_defines_lint`, `actions_pinning_lint`, and
  `rls_policy_lint`.
- Does not run `flutter analyze`, full tests, browser QA, provider calls,
  cloud actions, or graph refreshes.

For an explicit operator-approved emergency only, set
`FORGE_FLOW_SKIP_PRE_PUSH_LINTS=1` to skip pre-push lints.

## Graphify

Graphify upkeep is manual-only for cost control. Do not re-add an automatic
graph rebuild, `graphify-out/needs_update` writer, or doc-change notification
without an explicit operator request.

When the graph is useful again, refresh it deliberately from an interactive
session, for example with `/graphify --update .` or
`scripts/refresh_graph.ps1 -RunGraph`.
