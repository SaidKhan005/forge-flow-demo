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
  final String? scopeLabel;
  final RestaurantTimingConfig? initialConfigForTest;
  const TimingAuthoritySection({
    super.key,
    required this.restaurantId,
    this.scopeLabel,
    this.initialConfigForTest,
  });

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

  static String? _sourceLine(RestaurantTimingConfig config) {
    final rawLabel = config.sourceScopeLabel?.trim();
    final label = rawLabel == null || rawLabel.isEmpty
        ? _fallbackSourceLabel(config.sourceScopeType)
        : rawLabel;
    if (label == null || label.isEmpty) return null;
    final prefix = config.inheritedFromAncestor == true
        ? 'Inherited from'
        : 'Source';
    return '$prefix: $label';
  }

  static String? _fallbackSourceLabel(String? sourceScopeType) {
    switch (sourceScopeType) {
      case 'operator':
      case 'business':
        return 'Business default';
      case 'org_unit':
        return 'Org unit override';
      case 'location':
        return 'Location override';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RestaurantTimingConfig?>(
      future: initialConfigForTest == null
          ? RestaurantTimingConfigReadService.instance.getTimingConfig(
              restaurantId,
            )
          : Future<RestaurantTimingConfig?>.value(initialConfigForTest),
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
        final sourceLine = _sourceLine(config);
        // U-7 MO-3a/MO-3b (debug.md:264) — mobile is view-only.
        //
        // Per-Daypart V1 Slice 1.5: the "Shift close rule" row was
        // removed (operator decision 2026-05-15 — close-authority is
        // auto-derived per shift from the per-vendor capability
        // lookup + business-day-start fallback). The mobile mirror now
        // shows "Business day starts" as a single row instead of the
        // pre-1.5 consolidated tile that paired day-start with close
        // rule.
        return SettingsCard(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_hasScopeLabel) ...[
                    _TimingScopeLabel(scopeLabel: scopeLabel!.trim()),
                    const SizedBox(height: 8),
                  ],
                  if (sourceLine != null) ...[
                    _TimingSourceLabel(sourceLine: sourceLine),
                    const SizedBox(height: 8),
                  ],
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
                  _TimingValueRow(
                    label: 'Business day starts',
                    value: _formatTime(config.businessDayStartLocalTime),
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

  bool get _hasScopeLabel =>
      scopeLabel != null && scopeLabel!.trim().isNotEmpty;
}

class _TimingScopeLabel extends StatelessWidget {
  const _TimingScopeLabel({required this.scopeLabel});

  final String scopeLabel;

  @override
  Widget build(BuildContext context) {
    return Text(
      'Applies to: $scopeLabel',
      key: const Key('settings_timing_authority_scope_label'),
      style: AppTextStyles.body12(color: AppColors.textMuted),
    );
  }
}

class _TimingSourceLabel extends StatelessWidget {
  const _TimingSourceLabel({required this.sourceLine});

  final String sourceLine;

  @override
  Widget build(BuildContext context) {
    return Text(
      sourceLine,
      key: const Key('settings_timing_authority_source_label'),
      style: AppTextStyles.body12(color: AppColors.textMuted),
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
