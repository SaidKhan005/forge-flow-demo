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
    if (_sameDays(days, const [1, 2, 3, 4, 5])) return 'Mon-Fri';
    if (_sameDays(days, const [5, 6])) return 'Fri-Sat';
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
      future: RestaurantTimingConfigReadService.instance.getTimingConfig(
        restaurantId,
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return SettingsCard(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 16,
                ),
                child: Text(
                  'Loading timing settings...',
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 16,
                ),
                child: Text(
                  'Timing settings are not available yet for this restaurant.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ),
            ],
          );
        }

        final periods = config.servicePeriodDefinitions;
        // U-7 MO-3a/MO-3b (debug.md:264) — mobile is view-only.
        // Dropped: "Current timing" pill + "Restaurant-local timing
        // controls..." subtitle. Consolidated: "Business day starts" and
        // "Shift close rule" share a single bordered tile so the
        // business-day boundary reads as one piece of authority. The
        // tile groups the day-start time on top with the closeout rule
        // directly below.
        return SettingsCard(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TimingValueRow(
                    label: 'Timezone',
                    value: config.businessTimezone,
                  ),
                  const SettingsRowDivider(),
                  _TimingValueRow(
                    label: 'Week starts',
                    value: _formatWeekStart(config.weekStartDay),
                  ),
                  const SettingsRowDivider(),
                  _BusinessDayBoundaryTile(
                    dayStartLabel: _formatTime(
                      config.businessDayStartLocalTime,
                    ),
                    shiftCloseLabel: _formatShiftCloseRule(config),
                  ),
                  if (periods.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Service periods',
                      style: AppTextStyles.mono10(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 8),
                    for (var i = 0; i < periods.length; i++) ...[
                      if (i > 0) const SettingsRowDivider(),
                      _TimingValueRow(
                        label: periods[i].label,
                        value:
                            '${_formatApplicableDays(periods[i].applicableDays)} - ${_formatTime(periods[i].startLocalTime)} to ${_formatTime(periods[i].endLocalTime)}',
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

/// U-7 MO-3b — consolidated "Business day boundary" tile that pairs the
/// business-day-start time with the shift-close rule. Both pieces define
/// when a business day finishes, so the mobile mirror renders them as one
/// bordered block instead of two separate authority rows.
class _BusinessDayBoundaryTile extends StatelessWidget {
  final String dayStartLabel;
  final String shiftCloseLabel;
  const _BusinessDayBoundaryTile({
    required this.dayStartLabel,
    required this.shiftCloseLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(4),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Business day boundary',
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
            const SizedBox(height: 6),
            _TimingValueRow(
              label: 'Business day starts',
              value: dayStartLabel,
            ),
            const SettingsRowDivider(),
            _TimingValueRow(label: 'Shift close rule', value: shiftCloseLabel),
          ],
        ),
      ),
    );
  }
}
