# Source

- URL: https://developers.7shifts.com/reference/listtimepunches
- Retrieved: 2026-05-08
- API version: v2 (pinned `v2-2026-05-04`)
- Endpoint: documented `time_punch.edited` envelope, instants set in
  the future
- Notes: adversarial Scenario C. Mirrors the existing
  `sevenShiftsFutureDatedPunch` fixture in
  `test/integrations/labor/fixtures/seven_shifts_punches_fixture.dart`
  (id 799999, clocked_in 2026-07-15). The framework's inbound
  webhook sanity guard checks `opened_at` against `now` and rejects
  events more than `kInboundWebhookFutureToleranceSeconds` ahead.
  Because the harness pins `now` to 2026-05-08, the 2026-07-15
  instants exceed the tolerance and the inbound handler aborts
  before invoking `SevenShiftsLaborAdapter.handleWebhook`.
