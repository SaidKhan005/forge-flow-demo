# 04 - Verification, Deploy, And E2E (Lane C - Parity)

## Test gates (per slice)

Minimum gates per slice before commit:

- `dart analyze` against every touched file
- `flutter test` against every touched test file (per CLAUDE.md "tail tests" rule — no full-suite runs from worktree agents)
- Proxy route tests for every new route (idempotency, auth, signature verify for the SendGrid webhook)
- Repository tests for the master-switch flip
- Widget tests for adaptive-button states, redirect handler, deep-link landing
- Operator-web router redirect test for `/security` → `/my-account`
- HP #2 compliance test for the master switch (no `kDemoMode` branch added)

Lane-wide gates before C-12 closes:

- `dart analyze` clean across `lib/operator_web/**`, `lib/admin/**`, `lib/screens/settings/**`, `tool/advisor_proxy/**`, `tool/pressure/**`.
- `flutter test test/operator_web/`, `flutter test test/proxy/`, `flutter test test/screens/settings/`.
- Pressure-test outputs captured (see "Pressure-test the inventory" below).

## Pressure-test the inventory (per slice C-11)

The c_email_notification_scenario_inventory.md is the source of truth. Pressure-test every Wired or Hook-only entry. Reference R4 patterns:

| Inventory section | Wire status | R4 pattern | Tool | Expected evidence |
|---|---|---|---|---|
| §1 Password reset (self-serve) | Wired | 2A + 7A | Admin SDK + Mailosaur + Playwright | Action-link generates, landing page renders, new password works, audit row lands. |
| §1.b Email verification | Firebase-only | 2A | Admin SDK + emulator | applyActionCode succeeds; web action page handles `mode=verifyEmail`. |
| §2 Invite (operator-admin / first-admin) | Wired | 2A + 7A | Admin SDK + Mailosaur + Playwright | Invite email arrives, action-link sets first password, `users.status = active`, `auth_invites.accepted_at` stamped. |
| §3.b MFA authenticator removed (in-app inbox) | Wired | 3B | Patrol two-device | Inbox row + bell badge increment within 5s of the removal. |
| §4.a Vendor now-available | Wired | 5A + 5B + 7C | Mailosaur + SendGrid event webhook + Patrol | Email arrives, push banner arrives, notification preferences row controls fanout, idempotent on re-dispatch. |
| §5 Backfill complete / failed | Wired (post-B3) | 5B + 7C | Mailosaur + Patrol | Both terminal states arrive; idempotent on retry; failure case carries operator-readable `errorCategory`. |
| §6 Audit anchor failure | Wired (post-B3) | 5B + 4B | Mailosaur + ack route | Operator-admin email arrives, push banner arrives for admins only, `audit_anchor_failure` row in inbox. |
| §7.a Admin "Test connection" SendGrid send | Wired | 5A | SendGrid event webhook | Synchronous 2xx, `super_admin` gate enforced, idempotency respected. |
| §7.b Admin-initiated password reset | Wired | 2A + 7A | Admin SDK + Mailosaur | Action-link arrives at target's mailbox, audit row in `admin_action_log`. |
| §9.a New weekly plan snapshot | Wired (inbox only — push fanout not yet wired) | (none) | Widget test | Bell badge increments; push channel left as catalog-only until snapshot service emits via `NotificationEventFanout.fanOut`. |
| §10 Mobile push runtime (FCM tokens, self-test, outbox dispatch, foreground/background/terminated) | Wired (flag-gated) | 1A + 4A + 4B | Patrol + FTL + ack route | Token register/refresh/revoke round-trips, self-test arrives, cold-start deep-link routing works. |

For Template-only entries (E3 in `02_plumbing_audit_matrix.md`), pressure-test only the renderer + sample data path (`test/services/email/email_template_renderer_test.dart` already covers this; extend if wire-or-delete decisions add new fields).

## Mutation E2E policy

Per `docs/contracts/slice_runtime_acceptance_contract.md`, mutation E2E uses preview / staging mode. The wave plan's runtime acceptance is Codex-driven and out-of-repo; Lane C's PRs link the matching runtime acceptance evidence in their PR comments.

For Lane C, mutating actions to test under preview:
- Master Demo→Live switch flip (C-4) — flips real `demo_mode_state` rows in a preview operator.
- Mobile pointer → redemption-code redeem → operator-web session creation (C-5).
- Sign-in-security route → My Account redirect (C-3) — no DB writes, browser-only.
- SendGrid event webhook insert into `email_event` (C-1) — preview DB only.

Every mutation proves:
- correct enabled / disabled state
- correct role / freshness gate (RFC 9470 step-up for sensitive deep-link targets)
- confirmation copy
- audit reason where required
- idempotency key on write
- success state
- refresh / reload persistence
- audit row evidence

## Browser Use checklist

Use fresh cache-bust preview URLs (`?codexQa=<timestamp>` per the E2E framework). Capture:

**Operator Web (`app.forgeflow.app`)**:
- shell loads, every nav item renders the right body
- sign-in flow (`SignInScreen` → MFA challenge → completed onboarding stage → shell)
- My Account page (Profile read-only, MFA section + adaptive button, Password section, T&Cs)
- Sign-in security redirect: `/security` and `/sign-in-security` both land on My Account
- Deep-link `/handoff?code=...&nav=my_account` landing (post-Lane-B B11)
- Members, Roles, Hierarchy, Sessions, Audit log, Security, Vendor connections, Data accuracy, Wage authority, Notifications, Schedule
- Inheritance Tree component renders the same on every consumer (post-Lane-A)
- Notification preferences screen renders every catalog event
- TOS acceptance gate

**Admin Console**:
- Business accounts → location hierarchy → tile selection (Account / Data accuracy / Polling / People / Security / Support / Integrations / Timing)
- Read-only banners on cross-surface tiles ("Operator edits live on Operator Web") per C-10
- Admin-only banners on F&F-only tiles ("This surface is for F&F admins only") per C-10
- Audited support actions: Reset MFA, password reset, paired-approval flows render their gates

**Mobile**:
- Shell, Shift, Variance, Plan, Settings tabs
- Settings → Account (read-only with adaptive "Manage Account on Ops Web" deep-link button — post-C-5)
- Settings → Integrations → master Demo→Live switch — post-C-4
- Settings → Data → Timing pointer / Wage authority pointer (deep-link buttons — post-C-5)
- Notifications screen renders inbox rows for every catalog event the fanout writes
- Bell badge increments on push delivery + decrements on mark-read
- Push permission denied card renders correctly

## Health contract

For C-1 (SendGrid event webhook): the route is **not** part of `/readyz`. Healthcheck remains cheap. The webhook is allowed to be unhealthy (e.g., signature key rotation in progress) without taking down the proxy.

For C-4 (master switch route): the route IS NOT counted against `/readyz`. If the route 5xx's, the mobile UI falls back to per-row visibility from the existing `demo_mode_state` notifier.

## Preview deploy notes

Follow `runbooks/preview_environment_runbook.md` and `docs/frameworks/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md`. Lane C-specific:

- Use a **data-isolated preview** for the master Demo→Live switch test. Flipping every `demo_mode_state` row for a preview operator is destructive in staging.
- Use a **runtime-isolated preview sharing staging secrets** is OK for the sign-in-security redirect test (browser-only, no DB writes).
- The SendGrid event webhook test fires from SendGrid's "Test Your Integration" UI against the preview proxy. Capture the resulting `email_event` row insert evidence.

## Final evidence note

Create or update `docs/_execution/lane_c_parity/lane_c_evidence_<date>.md` (NOT a `06_closure_*.md` file per the instructions) with:

- source commit(s)
- PR links + merge commits for slices C-1 through C-12
- admin / operator-web / proxy / mobile preview URLs
- database mode (data-isolated vs runtime-isolated)
- route-by-route Browser Use evidence
- mutation evidence + approval notes (esp. for C-3, C-4, C-5 — auth-touching)
- framework checklist results
- pressure-test evidence per the R4 matrix above
- bugs found + fixed
- intentionally gated or unsurfaced items (e.g., `notif.shift.stale` future event)
- residual risks

## Decision-stop checklist before merge

For every Lane C slice, before requesting orchestrator merge:

- [ ] Slice's audit table from FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK Lens 11 (parity) attached to PR
- [ ] Demo-mode contract update drafted (C-4 only) — not committed until operator approves
- [ ] If the slice touches auth (C-3, C-5): explicit operator approval recorded
- [ ] If the slice touches RLS (C-4): explicit operator approval recorded
- [ ] If the slice depends on Lane A or Lane B output: cross-lane PR link cited
- [ ] Pressure-test evidence attached for any slice claiming a Wired status
- [ ] No tracker writes (per "Agent-Led Slices" rule)

## Carry-forward lessons for future waves

- The c_email_notification_scenario_inventory shows the wire-or-delete pattern works: B3's silent-failure fix landed cleanly because the inventory pre-existed.
- Every shared seam (Inheritance Tree, redemption code, SendGrid event webhook) should ship its consumer's contract first, then the producer, then the consumer. Lane C waits for Lane A's tree and Lane B's redemption endpoint, then sweeps consumers.
- The HP #2 demo-mode pattern works: a UX fold (master switch) over a runtime table beats a build-flag branch every time. New demo-aware code defaults to NO branch.
