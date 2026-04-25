// Phase 7.55o.4 — Settings Timing Authority section.
//
// Read-only display of the restaurant timing + service-period
// authority. Editable timing settings belong to Phase 10a and stay
// out of this slice. Behaviour, fallback copy, and loading text are
// unchanged from the pre-split implementation.

import 'package:flutter/material.dart';

import '../../services/restaurant_timing_config_read_service.dart';
import '../../domain/models/restaurant_timing_config.dart';
import '../../theme/app_theme.dart';
import 'settings_shared_widgets.dart';

class TimingAuthoritySection extends StatelessWidget {
  final String restaurantId;
  const TimingAuthoritySection({super.key, required this.restaurantId});

  static String _formatTime(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length != 2) return hhmm;
    final hour24 = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour24 == null || minute == null) return hhmm;
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final amPm = hour24 >= 12 ? 'PM' : 'AM';
    return '$hour12:${minute.toString().padLeft(2, '0')} $amPm';
  }

  static String _formatWeekStart(int weekStartDay) {
    const names = {
      DateTime.monday: 'Monday',
      DateTime.tuesday: 'Tuesday',
      DateTime.wednesday: 'Wednesday',
      DateTime.thursday: 'Thursday',
      DateTime.friday: 'Friday',
      DateTime.saturday: 'Saturday',
      DateTime.sunday: 'Sunday',
    };
    return names[weekStartDay] ?? 'Day $weekStartDay';
  }

  static String _formatApplicableDays(List<int> days) {
    const shortNames = {
      1: 'Mon',
      2: 'Tue',
      3: 'Wed',
      4: 'Thu',
      5: 'Fri',
      6: 'Sat',
      7: 'Sun',
    };
    if (days.length == 7) return 'Daily';
    if (_sameDays(days, const [1, 2, 3, 4, 5])) return 'Mon–Fri';
    if (_sameDays(days, const [5, 6])) return 'Fri–Sat';
    return days.map((d) => shortNames[d] ?? '$d').join(', ');
  }

  static bool _sameDays(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _formatShiftCloseRule(RestaurantTimingConfig config) {
    switch (config.shiftCloseAuthority) {
      case ShiftCloseAuthority.vendorFinalization:
        return 'Vendor finalization';
      case ShiftCloseAuthority.appLocalCutoffFallback:
        final cutoff =
            config.localCloseFallback ?? config.businessDayStartLocalTime;
        return 'Local cutoff fallback (${_formatTime(cutoff)})';
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RestaurantTimingConfig?>(
      future:
          RestaurantTimingConfigReadService.instance.getTimingConfig(restaurantId),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return SettingsCard(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                child: Text(
                  'Loading timing settings…',
                  style: AppTextStyles.body13(color: AppColors.textMuted),
                ),
              ),
            ],
          );
        }

        final config = snapshot.data;
        if (config == null) {
          return SettingsCard(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                child: Text(
                  'Timing settings are not available yet for this restaurant.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ),
            ],
          );
        }

        final periods = config.servicePeriodDefinitions;
        return SettingsCard(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppColors.sunset.withValues(alpha: 0.12),
                          border: Border.all(
                            color: AppColors.sunset.withValues(alpha: 0.45),
                            width: 1,
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'ACTIVE TIMING',
                          style:
                              AppTextStyles.mono10(color: AppColors.sunsetDark),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Restaurant-local timing controls the business date, week start, and service buckets. Timezone is visible here now; full timezone editing stays in the deeper time-boundary lane.',
                    style: AppTextStyles.body13(
                        color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  _TimingValueRow(
                    label: 'Timezone',
                    value: config.businessTimezone,
                  ),
                  const SettingsRowDivider(),
                  _TimingValueRow(
                    label: 'Business Day Starts',
                    value: _formatTime(config.businessDayStartLocalTime),
                  ),
                  const SettingsRowDivider(),
                  _TimingValueRow(
                    label: 'Week Starts',
                    value: _formatWeekStart(config.weekStartDay),
                  ),
                  const SettingsRowDivider(),
                  _TimingValueRow(
                    label: 'Shift Close Rule',
                    value: _formatShiftCloseRule(config),
                  ),
                  if (periods.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'SERVICE PERIODS',
                      style: AppTextStyles.mono10(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 8),
                    for (var i = 0; i < periods.length; i++) ...[
                      if (i > 0) const SettingsRowDivider(),
                      _TimingValueRow(
                        label: periods[i].label,
                        value:
                            '${_formatApplicableDays(periods[i].applicableDays)} · ${_formatTime(periods[i].startLocalTime)}–${_formatTime(periods[i].endLocalTime)}',
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TimingValueRow extends StatelessWidget {
  final String label;
  final String value;
  const _TimingValueRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 128,
            child: Text(
              label,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
