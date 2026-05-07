# Mobile Push Preflight Proof

Date: 2026-05-07
Branch: `codex/doc1-push-preflight-proof`
Worktree: `.codex_worktrees/doc1-push-preflight-proof`

Primary plan:
`docs/_execution/2026-05-06_mobile_push_notifications_plan.md`

## Scope Completed Now

- Reviewed the mobile push plan, Flutter mobile push runtime, token
  registration coordinator, proxy token routes, FCM sender, Postgres
  token/outbox repositories, migration guards, and existing focused tests.
- Confirmed the code-ready path remains bounded to non-live proof:
  - Flutter runtime creates a no-op service outside initialized mobile
    Firebase.
  - Mobile token registration/revoke goes through the authenticated proxy.
  - Flutter-facing mobile push code does not carry Firebase Admin or FCM
    server credentials.
  - Proxy token routes strip token material from responses.
  - Server token persistence hashes/encrypts token material.
  - FCM HTTP v1 payload construction keeps data flat and rejects
    secret-shaped data keys.
  - Durable `app_notifications` remains separate from push delivery.
- Extended the static credential guard so it also scans
  `lib/services/mobile_push/**`.

## Proof Boundaries

This preflight did not mutate Firebase, apply staging migrations, call live
FCM, or use a physical Android/iOS device.

## Remaining Gates

- Apply `db/migrations/202605060000_mobile_push_notifications.sql` to staging
  only through the approved migration runbook.
- Configure/verify staging Firebase FCM for the app package/bundle.
- Connected Android device proof:
  - install staging build
  - accept runtime notification permission
  - register token with staging proxy
  - receive foreground local notification
  - receive background system-tray notification
  - open terminated app to Notifications from push tap
- Verify failed/invalid token behavior against staging without mutating durable
  `app_notifications`.
- Repeat production Firebase proof only after staging evidence and explicit
  operator approval.
