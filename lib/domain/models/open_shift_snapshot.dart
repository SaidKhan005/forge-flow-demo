/// Open or projected current-week shift state.
///
/// Represents a shift slot that is not yet a closed historical ShiftRecord.
/// Used by the Shift screen, Zone status hero, and Variance Full Week.
library;

import 'dart:convert';

class OpenShiftSnapshot {
  final String restaurantId;
  final String weekId;
  final String dayLabel;
  final String daypart;
  final String status; // 'open' or 'projected'
  final String businessDate;
  final String? businessTimingProfileId;
  final String? businessTimingProfileVersionId;
  final String? servicePeriodKey;
  final int forecastCovers;
  final int currentCovers;
  final int scheduledFohHours;
  final int scheduledBohHours;
  final double currentPPA;
  final double currentCPLH;
  final double currentSPLH;
  final double blendedWage;
  final bool blendedWageAvailable;
  final String timeLabel;
  final String serviceElapsedLabel;
  final String? sourceSystem;
  final String? sourceShiftId;
  final Map<String, Object?> provenance;
  final String? lastEventAt;
  final String updatedAt;

  OpenShiftSnapshot({
    required this.restaurantId,
    required this.weekId,
    required this.dayLabel,
    required this.daypart,
    required this.status,
    required this.businessDate,
    this.businessTimingProfileId,
    this.businessTimingProfileVersionId,
    this.servicePeriodKey,
    required this.forecastCovers,
    required this.currentCovers,
    required this.scheduledFohHours,
    required this.scheduledBohHours,
    required this.currentPPA,
    required this.currentCPLH,
    required this.currentSPLH,
    required this.blendedWage,
    bool? blendedWageAvailable,
    this.timeLabel = '',
    this.serviceElapsedLabel = '',
    this.sourceSystem,
    this.sourceShiftId,
    this.provenance = const <String, Object?>{},
    this.lastEventAt,
    required this.updatedAt,
  }) : blendedWageAvailable =
           blendedWageAvailable ?? blendedWage.isFinite && blendedWage > 0;

  Map<String, dynamic> toMap() => {
    'restaurant_id': restaurantId,
    'week_id': weekId,
    'day_label': dayLabel,
    'daypart': daypart,
    'status': status,
    'business_date': businessDate,
    'business_timing_profile_id': businessTimingProfileId,
    'business_timing_profile_version_id': businessTimingProfileVersionId,
    'service_period_key': servicePeriodKey,
    'forecast_covers': forecastCovers,
    'current_covers': currentCovers,
    'scheduled_foh_hours': scheduledFohHours,
    'scheduled_boh_hours': scheduledBohHours,
    'current_ppa': currentPPA,
    'current_cplh': currentCPLH,
    'current_splh': currentSPLH,
    'blended_wage': blendedWage,
    'blended_wage_available': blendedWageAvailable ? 1 : 0,
    'time_label': timeLabel,
    'service_elapsed_label': serviceElapsedLabel,
    'source_system': sourceSystem,
    'source_shift_id': sourceShiftId,
    'provenance': jsonEncode(provenance),
    'last_event_at': lastEventAt,
    'updated_at': updatedAt,
  };

  factory OpenShiftSnapshot.fromMap(Map<String, dynamic> m) =>
      OpenShiftSnapshot(
        restaurantId: m['restaurant_id'] as String,
        weekId: m['week_id'] as String,
        dayLabel: m['day_label'] as String,
        daypart:
            (m['daypart'] ?? m['service_period_key'] ?? 'whole_day') as String,
        status: m['status'] as String,
        businessDate: m['business_date'] as String,
        businessTimingProfileId: m['business_timing_profile_id'] as String?,
        businessTimingProfileVersionId:
            (m['business_timing_profile_version_id'] ??
                    m['business_timing_profile_id'])
                as String?,
        servicePeriodKey: (m['service_period_key'] ?? m['daypart']) as String?,
        forecastCovers: m['forecast_covers'] as int,
        currentCovers: m['current_covers'] as int,
        scheduledFohHours: m['scheduled_foh_hours'] as int,
        scheduledBohHours: m['scheduled_boh_hours'] as int,
        currentPPA: (m['current_ppa'] as num).toDouble(),
        currentCPLH: (m['current_cplh'] as num).toDouble(),
        currentSPLH: (m['current_splh'] as num).toDouble(),
        blendedWage: (m['blended_wage'] as num).toDouble(),
        blendedWageAvailable: _boolValue(
          m['blended_wage_available'] ??
              _mapValue(m['provenance'])['blended_wage_available'],
          fallback: ((m['blended_wage'] as num).toDouble()) > 0,
        ),
        timeLabel: (m['time_label'] as String?) ?? '',
        serviceElapsedLabel: (m['service_elapsed_label'] as String?) ?? '',
        sourceSystem: m['source_system'] as String?,
        sourceShiftId: m['source_shift_id'] as String?,
        provenance: _mapValue(m['provenance']),
        lastEventAt: m['last_event_at'] as String?,
        updatedAt: m['updated_at'] as String,
      );
}

bool _boolValue(Object? value, {required bool fallback}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') return true;
    if (normalized == 'false' || normalized == '0') return false;
  }
  return fallback;
}

Map<String, Object?> _mapValue(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return Map<String, Object?>.from(value);
  if (value is String && value.trim().isNotEmpty) {
    final decoded = jsonDecode(value);
    if (decoded is Map) return Map<String, Object?>.from(decoded);
  }
  return const <String, Object?>{};
}
