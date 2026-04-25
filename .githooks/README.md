# `.githooks/`

Versioned git hooks for the Forge & Flow repo. Tracked in git so the
behavior is shared, not stuck in each user's local `.git/hooks/`.

## One-time setup per clone

Git does not look at `.githooks/` automatically. After cloning, run:

```bash
git config core.hooksPath .githooks
```

(One-time per clone; persists in the local `.git/config`.)

If a hook does not appear to fire, verify with:

```bash
git config core.hooksPath
# expected: .githooks
```

On Unix-like systems also confirm the hook is executable:

```bash
chmod +x .githooks/post-commit
```

On Windows / git-bash, executability is not enforced — the hook runs
regardless.

## Hooks in this directory

### `post-commit` — graphify integration

Two paths:

* **Code files** → AST-rebuild `graphify-out/graph.json` incrementally
  via `graphify.watch._rebuild_code`. No LLM, fast, runs every commit
  that touches code. Supported extensions list inline in the hook.
* **Markdown files** → write `graphify-out/needs_update` so the next
  Claude session runs `/graphify --update` (per the `Knowledge Graph
  Flag` rule in `CLAUDE.md`).

**Frozen-history paths** are excluded from the doc-flag entirely. The
graph grows forward with new content; it does not go back to
re-process retired material. Excluded prefixes are listed in the
`FROZEN_HISTORY_PATHS` tuple inside the hook:

* `docs/archive/` — retired phase docs, completed-and-archived material
* `graphify-out/` — graphify's own output cache (never an input)

Add new prefixes to that tuple when an active doc surface gets retired
into a frozen path.

The audio + visual notification fires only when an **active** doc
changed. Archive-only commits stay silent, since they produce no graph
work.
