The state Claude needs to "fully contextualize" lives in three places. The repo only covers one of them:

1. The repo itself — git clone gets CLAUDE.md, docs/, PROJECT_TRACKER.md, .mcp.json, contracts, phase docs, runbooks.

2. User-level Claude config at ~/.claude/ — global CLAUDE.md, custom skills (graphify, etc.), settings.json, keybindings.

3. Project memory at ~/.claude/projects/<project-key>/memory/ — MEMORY.md plus every file it links (session_handoff, feedback_*, project_*). This is the single most important per-project state and it is not in the repo.

The project key is the absolute repo path with separators replaced by -. On this machine it's C--Git-Local-Repos-forge-flow-demo. If the new machine clones to the same path, the key matches automatically. Otherwise rename the folder to whatever the new path resolves to.

Sync script (PowerShell, via OneDrive/Dropbox/USB)
# On OLD machine — push everything except worktrees/logs
$src = "$env:USERPROFILE\.claude"
$dst = "$env:OneDrive\claude-config-backup"
robocopy $src $dst /MIR /XD worktrees node_modules /XF *.log

# On NEW machine — clone repo to SAME path, then pull config
git clone <repo-url> "C:\Git Local Repos\forge_flow_demo"
$src = "$env:OneDrive\claude-config-backup"
$dst = "$env:USERPROFILE\.claude"
robocopy $src $dst /E /XD worktrees node_modules /XF *.log
Things that won't transfer cleanly: .claude/worktrees/, graphify-out/ (regenerate with /graphify), and any settings.local.json with machine-specific paths — diff that one before copying.

Kickoff prompt (paste into a fresh Claude session on the new machine)
Bootstrap context for Forge & Flow on this machine. In order:
1. Read MEMORY.md in this project's memory dir, then every file it links.
2. Read CLAUDE.md (project) and PROJECT_TRACKER.md.
3. Read docs/contracts/core_app_architecture.md.
4. Read the most recent file under docs/_execution/ — that's the active sprint.
5. Read session_handoff.md last (it's the freshest pointer).
6. Run: git status, git log --oneline -15, git branch -a.
7. Check whether graphify-out/needs_update exists; if so, run /graphify --update.
8. Summarize in <200 words: where the project stands, what's in flight, what should land next, and any drift between memory claims and current code/git state.
Step 8 is the load-bearing part — it forces Claude to reconcile memory against reality before you start asking for work, which is the failure mode memory alone won't catch.