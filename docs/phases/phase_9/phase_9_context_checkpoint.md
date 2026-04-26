# Phase 9 Context Checkpoint

Updated: 2026-04-26.

Use this as the compact handoff state for Codex/Claude prompt cycles. It is
not a decision source; decisions live in `phase_9_decision_lock_2026-04-26.md`
and architecture lives in `phase_9_auth_plan.md`.

## Current State

- Phase 11a is accepted and production-ready enough for Phase 9 to proceed.
- Phase 9 is active.
- `9.0` auth schema foundation is implemented, review-fixed, applied to
  staging and Production1, and locally verified.
- `9.1` Firebase Identity Platform setup + JWT verifier wiring is next.
- Production1 intentionally has schema only; no operator data is loaded.
- Unified local secrets loader: `$HOME/.forge_flow/forge_flow.secrets.ps1`.
- Firebase Admin SDK JSON remains outside the repo:
  `$HOME/.forge_flow/firebase-staging-adminsdk.json`.

## Stale Findings Already Cleared

- 11a staging report now records the 7-day staging backup gap and B1ms
  PgBouncer limitation; Production1 closes the production-only requirements.
- `scripts/use_postgres_staging_env.ps1` failure paths use `return`, not
  `exit`, so dot-sourcing cannot close the caller shell.
- `scripts/postgres_staging_setup.ps1` lists the expanded Azure extension and
  `shared_preload_libraries` requirements.
- `user_roles_active_grant_idx` is tenant-leading on
  `(operator_id, user_id, role_id, coalesce(location_id, ...))`.
- `auth_events_audit` actor and target lookup indexes lead with
  `operator_id`.

## Locked Phase 9 Decisions

Summary only; see `phase_9_decision_lock_2026-04-26.md` for the full lock.

- Launch with email/password + TOTP.
- Passkeys are a future follow-up, not a Phase 9 launch gate unless official
  Firebase / Identity Platform support appears before cutover.
- Use Firebase action links with Forge & Flow branded web pages.
- Normal proxy requests verify Firebase ID tokens locally via public keys/JWKS.
- Sensitive operations may use live revoked-token checks.
- MFA, recovery-code, invite, audit-retention, custom-role, support-scope,
  CSV-export, and GDPR behavior decisions are already locked.

## Prompt Loop

For each remaining Phase 9 slice:

1. Codex reads tracker truth plus the active Phase 9 section.
2. Codex produces Block 1 separately and Blocks 2/3 in one paste block.
3. Claude implements one slice only.
4. Claude runs required tests and reports.
5. Codex verifies repo truth directly.
6. Codex updates trackers only after acceptance.
7. Codex generates the next slice prompt.

Do not let Claude update trackers, broaden scope, or commit.

## Next Slice

`9.1` should start with local, testable Firebase JWT verifier wiring. It should
not build passkeys, branded action pages, full login UI, RLS runtime, role
permission runtime, or live Firebase smoke unless explicitly scoped.
