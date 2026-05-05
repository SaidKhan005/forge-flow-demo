# Codex Execution Prompt — `11W.5` Audit Log

## Block 1 — Human Context

Plain English: Migrate the mobile Settings → Audit Log into the Operator Web Console at `/audit-log`. Operator senior roles can browse the operator's audit log with filters and pagination, and export to CSV if they hold the export key.

Lane: `11W.5` — worktree `.claude/worktrees/<assigned-by-runbook>` on branch `claude/11W-5-audit-log` off master @ HEAD.

Authority:
- `docs/contracts/team_roles_hierarchy_console_parity_contract.md` (binding parity contract)
- `docs/phases/phase_11W/phase_11W_operator_web_console_plan.md` § `11W.5` Audit Log
- `docs/PERFORMANCE_FRAMEWORK.md` (pagination cap rule, manual-refresh rule for expensive lists)

Current issue:
- Operators have no web surface for audit-log review. Mobile Audit Log exists. Web parity needed for desktop bulk filter + CSV export.

Human prerequisites:
- Setup/access needed: none — Phase 9 backend route `/v1/auth/audit-log` is live.
- Decision needed: none.

## Block 2 — Claude Paste

Task: Implementation slice. Build `11W.5` Audit Log surface end-to-end. Per the Performance Framework: cap pagination at 200 rows per page, no auto-polling, manual refresh only.

Files to modify:
- `lib/operator_web/services/web_team_audit_log_gateway.dart` — NEW. `package:http`-backed gateway. List audit log (`GET /v1/auth/audit-log` with cursor + filters). Request CSV export (admin-path `/v1/admin/auth/audit-log/export?operator_id=...` only if actor holds `admin.audit_log.export`; for operator self-service `team.audit_log.view`-only actors, the export button is hidden).
- `lib/operator_web/services/demo_web_team_audit_log_gateway.dart` — NEW. Backed by `demo_team_fixtures.dart` (~50 audit entries from fixture spec).
- `lib/operator_web/screens/audit_log_screen.dart` — NEW. Filter row (actor picker / action multi-select / target_kind / target_id / time_window). Table body with humanized action labels per parity contract. Cursor-based pagination, 200 rows/page cap. Manual refresh button (no auto-refresh).
- `lib/operator_web/widgets/audit_log_row.dart` — NEW. Single audit-log row with collapsible JSONB payload (`View payload` toggle), copyable target_id, humanized timestamp in operator-local timezone.
- `lib/operator_web/router/operator_web_router.dart` — EDIT. Add `kOperatorWebNavAuditLog` constant + nav item.
- `lib/main_operator_web.dart` — EDIT. Add `_resolveTeamAuditLogGateway` resolver.
- `test/operator_web/audit_log_screen_test.dart` — NEW. Widget tests covering: filter set renders complete (actor / action / target_kind / target_id / time_window), 200-row cap enforced, no auto-refresh wiring, action humanization (`team.users.invite` → "Invited team member"), payload toggle, export button gated on `admin.audit_log.export`.
- `test/operator_web/web_team_audit_log_gateway_test.dart` — NEW. Unit tests for cursor pagination, error mapping.
- `docs/_walkthroughs/11W.5.md` — NEW.

Files to leave alone:
- `lib/screens/settings/settings_audit_log_section.dart` — mobile reference.
- `tool/advisor_proxy/advisor_proxy.dart` — backend route handlers exist.
- `audit_logs` table schema — read-only from this slice.

Hard constraints:
- Standard set.
- No auto-polling (Performance Framework rule for expensive admin lists).
- 200 rows per page cap, no override.
- Render timestamps in operator-local timezone per `phase_7_55_time_boundary_contract.md`.
- For live work, name-only preflight first.

Implementation tasks:
1. Read `lib/screens/settings/settings_audit_log_section.dart` mobile rendering — extract filter shape, humanization rules, payload-toggle UX.
2. Read backend `authAuditLogPath` route handler. Confirm cursor + filter shape.
3. Build the action-humanization map. Source it from a single Dart constant in the gateway file (or a sibling models file). Tests assert every action enum from the parity contract has a humanized label.
4. Build gateway + demo gateway.
5. Build screen + row widget.
6. Wire nav + resolver.
7. Tests + walkthrough.
8. Local web build.

Required tests:
- `flutter analyze --fatal-infos <touched paths>`
- `flutter test test/operator_web/audit_log_screen_test.dart test/operator_web/web_team_audit_log_gateway_test.dart`
- `flutter build web -t lib/main_operator_web.dart --dart-define=OPERATOR_WEB_DEMO_AUTH=true --pwa-strategy=none`

Acceptance criteria:
- [ ] Parity contract § Audit Log: filter set, 200-row pagination cap, sort by `created_at DESC`, action humanization, operator-local timestamp, payload toggle, export button gated correctly.
- [ ] Performance Framework: no auto-refresh, manual refresh only.
- [ ] No `dart:io` / `sqflite`; web build succeeds.
- [ ] `11W.5` walkthrough at `docs/_walkthroughs/11W.5.md`.
- [ ] No tracker changes, no commits, no scope drift.
- [ ] Pair with `11A.14` Audit Log tab — both must hit ACCEPT before either merges.

Report using the standard execution report.
