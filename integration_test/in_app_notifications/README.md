# In-app notification Patrol harness (Wave 2 Q-2b)

This directory holds the per-path Patrol tests for the in-app
notification surface. Each file covers one notification path
end-to-end: seed -> bell badge updates -> notifications screen tile
renders with the expected operator-visible copy.

## Running the suite

Demo-mode is mandatory (HP #2). The harness refuses to run against a
non-demo binary so we never write through the demo seed path against
production data.

Single invocation against an attached emulator / device:

```powershell
flutter test integration_test/in_app_notifications/ `
  --flavor forgeflow `
  --dart-define=kDemoMode=true
```

Single path:

```powershell
flutter test integration_test/in_app_notifications/invite_claimed_transition_test.dart `
  --flavor forgeflow `
  --dart-define=kDemoMode=true
```

Patrol-native run (lockscreen-shade gestures, host-side push
delivery) requires the Patrol CLI and platform tooling:

```powershell
dart pub global activate patrol_cli
patrol test --target integration_test/in_app_notifications/
```

The Patrol CLI binds to the platform tooling (Android SDK + emulator,
or Xcode + simulator); the in-tree `flutter test` invocation falls
back to the stock `WidgetTester` and still asserts on the inbox
+ badge + screen surface.

## What each path covers

| File | Path |
|---|---|
| `invite_claimed_transition_test.dart` | invite-pending -> invite-claimed transition |
| `audit_anchor_failure_alert_test.dart` | `notif.audit.anchor_failure` (admin-only) |
| `first_connect_backfill_complete_test.dart` | `notif.backfill.complete` |
| `vendor_disconnect_warning_test.dart` | vendor disconnect warning tile |

## Orchestrator

`tool/in_app_notification_soak/in_app_notification_soak_orchestrator.dart`
fans the four paths out, captures pass / fail outcomes and per-path
latency, and emits a Markdown report shaped like
`tool/pressure/p4_soak_orchestrator.dart`'s output. Run it with:

```powershell
dart run tool/in_app_notification_soak/in_app_notification_soak_orchestrator.dart `
  --output-dir=test/in_app_notification_soak `
  --run-id=local
```

The orchestrator drives `flutter test` (or `patrol test` when
`--patrol-native=true`) and parses the reporter output.
