import 'dart:convert';

import 'package:forge_and_flow/services/business_timing/business_timing_starter_profile.dart';

import '../postgres_executor.dart';

const String kRestaurantLocalBusinessDateSql =
    "((now() at time zone @business_timezone)::date - "
    "(case when (now() at time zone @business_timezone)::time < "
    "@business_day_start_local_time::time then 1 else 0 end))";

Future<String> insertStarterBusinessTimingProfile(
  PostgresExecutor exec, {
  required String operatorId,
  required String businessTimezone,
  required String businessDayStartLocal,
  required String adminReason,
  required String metadataSource,
}) async {
  final profileRows = await exec.query(
    'insert into public.business_timing_profiles ('
    'operator_id, scope_type, scope_id, display_name, '
    'business_day_start_local_time, week_start_day, close_authority, '
    'effective_from_business_date, created_by, updated_by'
    ') values ('
    '@operator_id::uuid, '
    "'operator', "
    '@operator_id::uuid, '
    '@display_name, '
    '@business_day_start_local_time::time, '
    '@week_start_day, '
    '@close_authority, '
    '$kRestaurantLocalBusinessDateSql, '
    'null, '
    'null'
    ') returning profile_id::text as profile_id, '
    'effective_from_business_date::text as effective_from_business_date',
    parameters: <String, Object?>{
      'operator_id': operatorId,
      'display_name': kStarterBusinessTimingProfileDisplayName,
      'business_timezone': businessTimezone,
      'business_day_start_local_time': businessDayStartLocal,
      'week_start_day': kStarterBusinessTimingWeekStartDay,
      'close_authority': kStarterBusinessTimingCloseAuthority,
    },
  );
  if (profileRows.isEmpty) {
    throw StateError(
      'business_timing_profiles starter insert returned no rows',
    );
  }
  final profileId = profileRows.single['profile_id'];
  if (profileId is! String || profileId.isEmpty) {
    throw StateError('business_timing_profiles returned malformed id');
  }
  final effectiveFrom = _dateOnlyString(
    profileRows.single['effective_from_business_date'],
  );

  for (final period in kStarterBusinessTimingServicePeriods) {
    final periodRows = await exec.query(
      'insert into public.business_timing_service_periods ('
      'operator_id, profile_id, service_period_key, label, short_label, '
      'sort_order, start_local_time, end_local_time, rolls_past_midnight, '
      'applicable_weekdays'
      ') values ('
      '@operator_id::uuid, @profile_id::uuid, @service_period_key, '
      '@label, @short_label, @sort_order, @start_local_time::time, '
      '@end_local_time::time, @rolls_past_midnight, '
      '@applicable_weekdays::integer[]'
      ') returning service_period_id::text as service_period_id',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'profile_id': profileId,
        'service_period_key': period.key,
        'label': period.label,
        'short_label': period.shortLabel,
        'sort_order': period.sortOrder,
        'start_local_time': period.startLocal,
        'end_local_time': period.endLocal,
        'rolls_past_midnight': period.rollsPastMidnight,
        'applicable_weekdays': period.applicableDays,
      },
    );
    if (periodRows.isEmpty) {
      throw StateError(
        'business_timing_service_periods starter insert returned no rows',
      );
    }
  }

  await exec.query(
    'insert into public.business_timing_audit_events ('
    'operator_id, profile_id, scope_type, scope_id, event_type, '
    'actor_kind, actor_user_id, reason, idempotency_key, '
    'before_snapshot, after_snapshot, metadata'
    ') values ('
    '@operator_id::uuid, @profile_id::uuid, '
    "'operator', "
    '@operator_id::uuid, '
    "'profile_created', "
    "'forge_admin', "
    'null, '
    '@reason, '
    'null, '
    'null, '
    '@after_snapshot::jsonb, '
    '@metadata::jsonb'
    ') returning audit_event_id::text as audit_event_id',
    parameters: <String, Object?>{
      'operator_id': operatorId,
      'profile_id': profileId,
      'reason': adminReason,
      'after_snapshot': jsonEncode(<String, Object?>{
        'profile_id': profileId,
        'operator_id': operatorId,
        'scope_type': 'operator',
        'scope_id': operatorId,
        'display_name': kStarterBusinessTimingProfileDisplayName,
        'business_day_start_local_time': businessDayStartLocal,
        'week_start_day': kStarterBusinessTimingWeekStartDay,
        'close_authority': kStarterBusinessTimingCloseAuthority,
        'effective_from_business_date': effectiveFrom,
        'service_periods': <Map<String, Object?>>[
          for (final period in kStarterBusinessTimingServicePeriods)
            _starterServicePeriodSnapshot(period),
        ],
      }),
      'metadata': jsonEncode(<String, Object?>{'source': metadataSource}),
    },
  );

  return profileId;
}

Map<String, Object?> _starterServicePeriodSnapshot(
  StarterBusinessTimingServicePeriod period,
) {
  return <String, Object?>{
    'service_period_key': period.key,
    'label': period.label,
    'short_label': period.shortLabel,
    'sort_order': period.sortOrder,
    'start_local_time': period.startLocal,
    'end_local_time': period.endLocal,
    'rolls_past_midnight': period.rollsPastMidnight,
    'applicable_weekdays': period.applicableDays,
  };
}

String _dateOnlyString(Object? value) {
  if (value == null) return '';
  if (value is DateTime) {
    return value.toUtc().toIso8601String().substring(0, 10);
  }
  final text = value.toString();
  return text.length >= 10 ? text.substring(0, 10) : text;
}
