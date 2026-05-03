# 10.5.2 Closeout - Per-period read service + Shift cards + Variance lens

Archived: 2026-05-03
Status: Resolved and accepted
Active authority: `docs/phases/phase_10_5/phase_10_5_shift_daypart_service_period_view_and_primary_driver.md`
Walkthrough: `docs/_walkthroughs/10.5.2.md`

## Archived Content

This closeout archives the accepted result material for slice `10.5.2` so the
active Phase 10.5 plan can stay focused on remaining work. The phase family is
not archived yet because `10.5.3+` daypart-live primary-driver teaching remains
queued.

## Completed Scope

- Added `ShiftServicePeriodReadService`, a pure accumulator over canonical POS
  lines and labor punches.
- Added `ShiftServicePeriodNotifier`, currently synthesizing canonical facts
  from demo `OpenShiftSnapshot` rows until Phase 8 canonical fact tables land.
- Replaced the Shift Daypart placeholder with service-period metric cards.
- Added active-period time-in-service copy above the Shift SERVICE PERIODS
  group.
- Added the Variance This Week `Whole Week | Daypart` lens consuming the same
  service-period notifier.
- Wired app-level and Shift pull-to-refresh paths so service-period buckets
  refresh with whole-day/current-state surfaces.

## Review Fixes Folded In

- Active service-period resolution now compares full time-of-day precision
  instead of whole minutes.
- Missing restaurant timezone now renders explicit unavailable/configuration
  copy on Shift and Variance daypart surfaces.
- Manual Shift pull-to-refresh awaits both whole-day Shift and per-period
  service-period refreshes.
- POS correction replay uses explicit check deltas so zero-cover/zero-sales
  checks do not drift.

## Verification

- `dart analyze` - no issues found.
- `flutter test test/services/shift_service_period_read_service_test.dart test/widget/shift_dashboard_daypart_test.dart`
  - 23/23 passed.
- `flutter test test/shift_dashboard_daypart_toggle_widget_test.dart test/variance_visual_widget_test.dart test/domain/services/daypart_bucketer_test.dart test/shift_visual_widget_test.dart test/shift_dashboard_empty_state_widget_test.dart test/shift_dashboard_notifier_test.dart`
  - 72/72 passed.

## Archive Verdict

- Archived here: completed slice closeout/result content for `10.5.2`.
- Kept live: Phase 10.5 planning doc, walkthrough index, and `10.5.0`-`10.5.2`
  walkthroughs.
- Not archived yet: the Phase 10.5 family, because `10.5.3+` primary-driver
  teaching and later Phase 8 canonical fact wiring are still active handoffs.
