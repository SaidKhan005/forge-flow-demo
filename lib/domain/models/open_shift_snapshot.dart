/// Open or projected current-week shift state.
///
/// Represents a shift slot that is not yet a closed historical ShiftRecord.
/// Used by the Shift screen, Zone status hero, and Variance Full Week.
library;

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
  final String timeLabel;
  final String serviceElapsedLabel;
  final String? sourceSystem;
  final String? sourceShiftId;
  final String? lastEventAt;
  final String updatedAt;

  const OpenShiftSnapshot({
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
    this.timeLabel = '',
    this.serviceElapsedLabel = '',
    this.sourceSystem,
    this.sourceShiftId,
    this.lastEventAt,
    required this.updatedAt,
  });

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
    'time_label': timeLabel,
    'service_elapsed_label': serviceElapsedLabel,
    'source_system': sourceSystem,
    'source_shift_id': sourceShiftId,
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
        timeLabel: (m['time_label'] as String?) ?? '',
        serviceElapsedLabel: (m['service_elapsed_label'] as String?) ?? '',
        sourceSystem: m['source_system'] as String?,
        sourceShiftId: m['source_shift_id'] as String?,
        lastEventAt: m['last_event_at'] as String?,
        updatedAt: m['updated_at'] as String,
      );
}
