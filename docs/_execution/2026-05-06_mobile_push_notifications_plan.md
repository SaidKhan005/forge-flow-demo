# Mobile Push Notifications Plan

Date: 2026-05-06
Branch: `codex/mobile-fcm-notifications`
Worktree: `.codex_worktrees/mobile-fcm-notifications`

## Scope

Add OS-level push notifications for Forge & Flow mobile app notifications.
The existing `app_notifications` table/service remains the durable in-app
record. Firebase Cloud Messaging is a delivery channel only.

## Architecture

```text
business event
  -> durable app notification row
  -> event_outbox topic app.notification.created
  -> proxy/worker claims the outbox row
  -> push delivery service loads active device tokens
  -> FCM sends notification/data payload
  -> app receives:
       foreground: local notification banner
       background/terminated: OS notification
       tap: app opens Notifications screen
```

## Non-Negotiables

- No Firebase service keys or FCM server credentials in Flutter.
- No live Firebase mutation until staging proof is ready and approved.
- Staging Firebase is exercised before production Firebase.
- iOS production banners require APNs key/cert configuration in Firebase.
- Android 13+ requires `POST_NOTIFICATIONS` permission and runtime opt-in.
- Push payloads must avoid secrets and sensitive lock-screen data.
- Push delivery failures do not delete or mutate durable app notification rows.

## Acceptance Proof

1. Unit tests pass for token registration request shape, notification routing,
   and server-side FCM payload mapping.
2. Migration scanner and cutoff lint pass if a database migration is added.
3. Connected Android device:
   - install staging build
   - accept notification permission
   - token registers with staging proxy
   - foreground notification shows via local notification
   - background notification appears in system tray
   - terminated notification opens the app to Notifications
4. Staging Firebase:
   - FCM enabled for the app bundle/package
   - test token receives a controlled test push
   - failed/invalid token path disables stale token without affecting other devices
5. Production Firebase:
   - repeat only after staging evidence is recorded and the operator approves
     the live mutation.

## Live Environment Gate

The implementation may land code, migrations, and scripts in this worktree.
Applying migrations or changing Firebase project settings for staging or
production is a separate operator-approved action.
