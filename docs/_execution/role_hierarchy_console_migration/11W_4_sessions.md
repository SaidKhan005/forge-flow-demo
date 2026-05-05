# Codex Execution Prompt — `11W.4` Sessions

## Block 1 — Human Context

Plain English: Migrate the mobile Settings → Active Sessions into the Operator Web Console at `/sessions`. The actor sees their own sessions plus, if they hold `team.session.force_logout`, every team-member session within scope. Revoking the current web session calls `signOut()`.

Lane: `11W.4` — worktree `.claude/worktrees/<assigned-by-runbook>` on branch `claude/11W-4-sessions` off master @ HEAD.

Authority:
- `docs/contracts/team_roles_hierarchy_console_parity_contract.md` (binding parity contract)
- `docs/phases/phase_11W/phase_11W_operator_web_console_plan.md` § `11W.4` Sessions

Current issue:
- Operators have no web surface for session management. Mobile Active Sessions exists. Web parity needed for desktop bulk session revoke.

Human prerequisites:
- Setup/access needed: none — Phase 9 backend routes (`/v1/auth/sessions`, `/v1/auth/session/revoke`) are live.
- Decision needed: none.

## Block 2 — Claude Paste

Task: Implementation slice. Build the `11W.4` Sessions surface end-to-end against existing Phase 9 routes.

Files to modify:
- `lib/operator_web/services/web_team_sessions_gateway.dart` — NEW. `package:http`-backed gateway. List own sessions (`GET /v1/auth/sessions`). Revoke session (`POST /v1/auth/session/revoke`). List team sessions (`GET /v1/auth/team/sessions`) gated server-side on `team.session.force_logout`.
- `lib/operator_web/services/demo_web_team_sessions_gateway.dart` — NEW. Backed by `demo_team_fixtures.dart` (4 active sessions per fixture spec).
- `lib/operator_web/screens/sessions_screen.dart` — NEW. Two-section layout: top = `Your sessions` (always visible), bottom = `Team sessions` (visible only if actor holds `team.session.force_logout`). Each row: device fingerprint (browser + OS), city-level geo hint, last_active_at humanized, `(this session)` chip on the matching row, `Revoke` action. Idempotency key per revoke.
- `lib/operator_web/router/operator_web_router.dart` — EDIT. Add `kOperatorWebNavSessions` constant + nav item.
- `lib/main_operator_web.dart` — EDIT. Add `_resolveTeamSessionsGateway` resolver.
- `test/operator_web/sessions_screen_test.dart` — NEW. Widget tests covering: own-only view for users without `team.session.force_logout`, two-section view for users with the key, `(this session)` chip on the matching row, revoking the current session triggers `signOut()`, idempotency key flows through, no raw IP in display.
- `test/operator_web/web_team_sessions_gateway_test.dart` — NEW. Unit tests covering HTTP shape + the `cannot_revoke_self` error mapping.
- `docs/_walkthroughs/11W.4.md` — NEW.

Files to leave alone:
- `lib/screens/settings/settings_active_sessions_section.dart` — mobile reference.
- `tool/advisor_proxy/advisor_proxy.dart` — backend route handlers exist.

Hard constraints:
- Standard set (no tracker / no commit / no scope drift / no `dart:io` / no new routes / preflight first).
- Display geo hint at city granularity only, never raw IP, per parity contract § Sessions.
- Revoking the current web session must call `signOut()` only after the proxy returns 2xx.

Implementation tasks:
1. Read `lib/screens/settings/settings_active_sessions_section.dart` mobile rendering.
2. Read backend `authSessionsListPath`, `authSessionRevokePath`, `authRefreshTokensRevokeAllPath` route shapes.
3. Identify how the auth source exposes `currentSession.sessionId` (or equivalent) so the screen can mark `(this session)` reliably. If the auth source needs an additive method, add it without breaking the existing onboarding state machine.
4. Build gateway + demo gateway.
5. Build screen.
6. Wire nav + resolver.
7. Tests + walkthrough.
8. Local web build.

Required tests:
- `flutter analyze --fatal-infos <touched paths>`
- `flutter test test/operator_web/sessions_screen_test.dart test/operator_web/web_team_sessions_gateway_test.dart`
- `flutter build web -t lib/main_operator_web.dart --dart-define=OPERATOR_WEB_DEMO_AUTH=true --pwa-strategy=none`

Acceptance criteria:
- [ ] Parity contract § Sessions: list shape, geo at city granularity, `(this session)` chip, revoke-self triggers signOut, team-section gated on `team.session.force_logout`.
- [ ] Idempotency keys minted in screen state.
- [ ] No `dart:io` / `sqflite`; web build succeeds.
- [ ] `11W.4` walkthrough at `docs/_walkthroughs/11W.4.md`.
- [ ] No tracker changes, no commits, no scope drift.
- [ ] Pair with `11A.13` Sessions tab — both must hit ACCEPT before either merges.

Report using the standard execution report.
