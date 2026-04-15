# Phase 7.55p.4d — Persisted Passive Notifications

Status: Landed (7.55p.4d1 durability + entrypoint cleanup applied)

## Goal

Persist passive in-app notifications for two concrete runtime events:
- when the business week rolls and a new weekly snapshot is auto-generated
- when the 60-day target cycle expires and a new recommended cycle becomes
  active (auto-refresh rollover)

These notifications are durable, visible in-app, and do not imply
background delivery, push, polling, or a broader notification system.

## Scope

- In: one persisted notification model/repository/service; SQLite table
  with deterministic dedupe; emit points in weekly snapshot generation
  and cycle rollover; passive in-app notification screen with icon in
  the AppShell top bar
- Out: OS push; background delivery; polling/timers; badge/unread
  counts; manager-override or admin-replacement notifications;
  next-week forecast-delta notifications; notification scheduling

## Touched Seams

| File | What changed |
|---|---|
| `lib/domain/models/app_notification.dart` | New. Domain model with notificationId, restaurantId, type, eventKey, title, body, businessDate, createdAt |
| `lib/domain/repositories/app_notification_repository.dart` | New. Abstract interface: insertIfAbsent, getNotifications |
| `lib/infrastructure/persistence/sqlite/dao/app_notification_dao.dart` | New. DAO with ConflictAlgorithm.ignore for dedupe |
| `lib/infrastructure/persistence/sqlite/repositories/sqlite_app_notification_repository.dart` | New. Singleton SQLite repository |
| `lib/data/app_notification_service.dart` | New. Service: emitNewWeekSnapshot, emitCycleRollover, getNotifications |
| `lib/infrastructure/persistence/sqlite/sqlite_database.dart` | Schema v19: app_notifications table with UNIQUE(restaurant_id, event_key); migration; cleared on reseedDemo and clearAllData |
| `lib/data/weekly_plan_snapshot_service.dart` | _generateAndPersistSnapshot emits new-week notification after snapshot upsert |
| `lib/data/target_cycle_service.dart` | getOrCreateActiveCycle emits cycle-rollover notification on auto-refresh only (not initial bootstrap) |
| `lib/screens/notifications_screen.dart` | New. Lightweight read-only list of persisted notifications |
| `lib/forge_flow_app.dart` | Notification icon added to AppShell top bar (both embedded and standalone AppBars) |
| `test/app_notification_service_test.dart` | New. 7 tests: emit/read round-trip, dedupe, ordering, cross-type coexistence |

## 7.55p.4d1 — Durability + Entrypoint Cleanup

| File | What changed |
|---|---|
| `lib/data/weekly_plan_snapshot_service.dart` | `emitNewWeekSnapshot` call now awaited — notification durable before generation returns |
| `lib/data/target_cycle_service.dart` | `emitCycleRollover` call now awaited — notification durable before rollover returns |
| `lib/forge_flow_app.dart` | Standalone AppBar shown on all tabs (was null on Shift tab) — notification + settings icons always reachable |
| `test/notification_entrypoint_test.dart` | New. Widget test: notification icon visible on default Shift tab, taps to NotificationsScreen |

## How It Works

### Emit points

1. `WeeklyPlanSnapshotService._generateAndPersistSnapshot()` — after
   persisting the new weekly snapshot, awaits
   `AppNotificationService.instance.emitNewWeekSnapshot()`. Only
   reached when no existing snapshot for the week (structural dedupe).
   Notification row is durable before the generation path returns.

2. `TargetCycleService.getOrCreateActiveCycle()` — in the
   `needsAutoRefresh` branch only (expired cycle -> new cycle), awaits
   `AppNotificationService.instance.emitCycleRollover()`. NOT in the
   `existing == null` branch (initial bootstrap — nothing to roll over
   from). Notification row is durable before the rollover path returns.

### Dedupe

Deterministic at the persistence seam:
- `UNIQUE(restaurant_id, event_key)` constraint on the table
- `ConflictAlgorithm.ignore` on insert — duplicate event keys are
  silently dropped
- Event key format: `new_week_snapshot_{weekStart}_{weekEnd}` or
  `cycle_rollover_{effectiveStart}`

### No replay flood

`reseedDemo()` and `clearAllData()` both delete from
`app_notifications`. Historical replay seed data never backfills
notifications.

### In-app surface

Small notification icon (`notifications_none_outlined`) in the AppShell
top bar, next to the settings icon. Visible on all tabs in both
standalone and embedded modes. Taps to open `NotificationsScreen` as a
full-screen dialog showing a newest-first read-only list.

## Remaining Gaps

- Manager-override and admin-replacement notifications are documented
  in the time-boundary notification contract but deferred
- Next-week forecast-delta notifications are deferred
- No unread/badge tracking — plain passive list only
- Settings-change notifications (timezone, week-start, etc.) are deferred
