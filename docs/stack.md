# MCP Server Stack — Forge & Flow

Recommended MCP servers for Claude Code sessions in this repo. None were available as one-click connectors in the registry — all require manual setup via `settings.json` or `claude mcp add`.

## Quick Reference

| Server | Provider | Install | Auth | Priority |
|--------|----------|---------|------|----------|
| Firebase | Official (Google) | npx | Firebase CLI login | High — Phase 9 auth |
| Figma | Official (Figma) | Remote (hosted) | OAuth browser | High — design tokens |
| Linear | Official (Linear) | Remote (hosted) | OAuth browser | Medium — roadmap |
| Sentry | Official (Sentry) | Remote (hosted) | OAuth browser | Medium — post-launch |
| Slack | Official (Slack) | Remote (hosted) | OAuth browser | Medium — team context |
| SQLite | Anthropic reference | npx | None (file path) | High — dev debugging |
| Google Play | Community | npx | GCP service account | Low — post-release |

---

## Firebase

Phase 9 auth planning targets Firebase Auth + Firestore. This is the highest-priority addition.

**Setup:**
```bash
claude mcp add firebase npx -- -y firebase-tools@latest mcp
```

Or in `settings.json`:
```json
"firebase": {
  "command": "npx",
  "args": ["-y", "firebase-tools@latest", "mcp"]
}
```

**Pre-req:** `firebase login` (uses your existing CLI credentials).

**Capabilities:** Auth user management, Firestore CRUD, security rules inspection, Hosting deployment, Crashlytics.

**Docs:** https://firebase.google.com/docs/ai-assistance/mcp-server

---

## Figma

Useful for verifying AppColors/AppTextStyles implementation against design source.

**Setup:**
```bash
claude mcp add --transport http figma https://mcp.figma.com/mcp
```

Or in `settings.json`:
```json
"figma": {
  "type": "http",
  "url": "https://mcp.figma.com/mcp"
}
```

**Pre-req:** OAuth via browser on first connect. No API key needed.

**Capabilities:** Read file structure, extract component properties/styles, get design tokens (colors, typography, spacing), read annotations.

**Docs:** https://developers.figma.com/docs/figma-mcp-server/remote-server-installation/

---

## Linear

For reading tickets and roadmap context without pasting into chat.

**Setup:**
```bash
claude mcp add --transport http linear https://mcp.linear.app/mcp
```

Or in `settings.json`:
```json
"linear": {
  "type": "http",
  "url": "https://mcp.linear.app/mcp"
}
```

**Pre-req:** OAuth via browser on first connect.

**Capabilities:** Search/create/update issues, manage projects and milestones, comments, labels, priorities.

**Docs:** https://linear.app/docs/mcp

---

## Sentry

For pulling crash traces and error trends once the app is in production.

**Setup:**
```bash
claude mcp add --transport http sentry https://mcp.sentry.dev/mcp
```

Or in `settings.json`:
```json
"sentry": {
  "type": "http",
  "url": "https://mcp.sentry.dev/mcp"
}
```

**Pre-req:** OAuth via browser on first connect (device-code flow). Token cached at `~/.sentry/mcp.json`.

**Capabilities:** Search issues/events, full stack traces, tags, breadcrumbs, root cause analysis via Seer AI.

**Docs:** https://docs.sentry.io/product/sentry-mcp/

---

## Slack

For pulling team discussions about vendor selection (Phase 8 blocker), scope decisions, etc.

**Setup (remote, recommended):**
```bash
claude mcp add --transport http slack https://mcp.slack.com/mcp
```

Or in `settings.json`:
```json
"slack": {
  "type": "http",
  "url": "https://mcp.slack.com/mcp"
}
```

**Pre-req:** OAuth via browser on first connect.

**Setup (local alternative):**
```json
"slack": {
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-slack"],
  "env": {
    "SLACK_BOT_TOKEN": "xoxb-your-bot-token",
    "SLACK_TEAM_ID": "T01234567"
  }
}
```

Local requires a Slack App with bot scopes: `channels:history`, `channels:read`, `chat:write`, `reactions:write`, `users:read`, `search:read`. Create at https://api.slack.com/apps.

**Capabilities:** List/read channels, post messages, search messages, thread replies, reactions, user info.

**Docs:** https://docs.slack.dev/ai/slack-mcp-server/connect-to-claude/

---

## SQLite

For inspecting the local dev database during debugging without manual queries.

**Setup:**
```bash
claude mcp add sqlite npx -- -y @modelcontextprotocol/server-sqlite /path/to/your/dev.sqlite
```

Or in `settings.json`:
```json
"sqlite": {
  "command": "npx",
  "args": ["-y", "@modelcontextprotocol/server-sqlite", "/path/to/your/dev.sqlite"]
}
```

**Pre-req:** None. Just point it at your database file. The app uses sqflite, so the DB location depends on the platform (Android emulator path, desktop path, etc.).

**Capabilities:** Arbitrary SQL queries, automatic schema discovery, full read/write access.

**Warning:** Full read/write — point at dev databases only.

**Source:** https://github.com/modelcontextprotocol/servers

---

## Google Play Console

Smallest/least mature option. Community-maintained. Worth adding once you're actively publishing releases.

**Setup:**
```json
"google-play": {
  "command": "npx",
  "args": ["-y", "@blocktopus/mcp-google-play"],
  "env": {
    "GOOGLE_APPLICATION_CREDENTIALS": "/path/to/service-account-key.json"
  }
}
```

**Pre-req:** GCP service account JSON key with Play Developer API access. Create in Google Cloud Console > IAM > Service Accounts, then grant access in Play Console > Settings > API access.

**Capabilities:** List apps, view releases, manage store listings, read/reply to reviews, download stats.

**Source:** https://github.com/BlocktopusLtd/mcp-google-play

---

## Notes

- Remote servers (Figma, Linear, Sentry, Slack) are zero-install — just add the config and authenticate via browser on first use.
- Firebase and SQLite use the `npx` local pattern — Node.js required.
- Google Play is the only community (non-official) server in this list. Evaluate before relying on it for production workflows.
- All configs go in either project-level `.mcp.json` or user-level Claude Code settings depending on whether you want them scoped to this repo or global.
