// Phase 11W.7 / Wave A2 - shared business-timing-profile validator.
//
// Pure Dart, no I/O. Validates the operator-web payload shapes for the
// /v1/operator/business-timing-profiles routes BEFORE any repository
// or proxy_requests write happens. Postgres triggers and CHECK
// constraints already enforce most of these rules at the database
// boundary; running them in Dart first lets the proxy emit precise
// named error codes (instead of opaque 23P01/23514 codes) and lets
// the frontend share the same validator if needed.
//
// Authority: docs/phases/phase_business_timing_live/business_timing_live_plan.md.

/// Allowed week-start day strings. Lowercase, English. The repository
/// stores week_start_day as an integer 1..7 (Mon=1) at the table level;
/// the proxy translates between the wire string and the column int.
const List<String> kBusinessTimingWeekStartDays = <String>[
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
];

/// Permitted IANA timezones. Using a curated allow-list keeps the
/// proxy from accepting bogus zones like "America/Atlantis" that
/// would only fail at projector time. Production deploys add to this
/// set as new operator regions come online; the migration's CHECK
/// constraint on locations.timezone already enforces a similar
/// shape, but we keep the validator pessimistic so the proxy can
/// reject invalid zones with a named code.
const Set<String> kBusinessTimingAllowedIanaTimezones = <String>{
  'America/Toronto',
  'America/New_York',
  'America/Chicago',
  'America/Denver',
  'America/Phoenix',
  'America/Los_Angeles',
  'America/Anchorage',
  'America/Halifax',
  'America/St_Johns',
  'America/Vancouver',
  'America/Edmonton',
  'America/Winnipeg',
  'America/Mexico_City',
  'America/Sao_Paulo',
  'Europe/London',
  'Europe/Dublin',
  'Europe/Paris',
  'Europe/Berlin',
  'Europe/Madrid',
  'Europe/Rome',
  'Europe/Amsterdam',
  'Europe/Stockholm',
  'Europe/Helsinki',
  'Europe/Athens',
  'Europe/Istanbul',
  'Europe/Moscow',
  'Africa/Johannesburg',
  'Asia/Dubai',
  'Asia/Kolkata',
  'Asia/Singapore',
  'Asia/Hong_Kong',
  'Asia/Shanghai',
  'Asia/Tokyo',
  'Asia/Seoul',
  'Australia/Sydney',
  'Australia/Melbourne',
  'Australia/Perth',
  'Pacific/Auckland',
  'UTC',
};

/// Single named validation failure. The proxy translates this into a
/// 400 JSON envelope with `{ "error": code, "message": message,
/// "path": path }`. `path` is JSON-pointer-ish so the frontend can
/// surface inline errors next to the right control.
class BusinessTimingValidationError implements Exception {
  const BusinessTimingValidationError({
    required this.code,
    required this.message,
    this.path,
    this.extras = const <String, Object?>{},
  });

  final String code;
  final String message;
  final String? path;
  final Map<String, Object?> extras;

  Map<String, Object?> toJson() => <String, Object?>{
        'error': code,
        'message': message,
        if (path != null) 'path': path,
        ...extras,
      };

  @override
  String toString() => 'BusinessTimingValidationError($code at ${path ?? '<root>'})';
}

/// Wire shape of one service period after parsing. All times are
/// minute-of-day integers (0..1439) for overlap math; the original
/// "HH:MM" strings are preserved on `startLocal` / `endLocal`.
class ValidatedServicePeriod {
  const ValidatedServicePeriod({
    required this.key,
    required this.label,
    required this.startLocal,
    required this.endLocal,
    required this.startMinute,
    required this.endMinute,
    required this.rollsPastMidnight,
  });

  final String key;
  final String label;
  final String startLocal;
  final String endLocal;
  final int startMinute;
  final int endMinute;
  final bool rollsPastMidnight;
}

/// Result of a successful POST/PATCH validation. The repository
/// adapter consumes this directly: every field is normalized and
/// every service-period set is overlap-free.
class ValidatedBusinessTimingProfile {
  const ValidatedBusinessTimingProfile({
    required this.scopeKind,
    required this.scopeId,
    required this.effectiveAtBusinessDate,
    required this.ianaTimezone,
    required this.weekStartDay,
    required this.weekStartDayInt,
    required this.businessDayStartLocal,
    required this.servicePeriods,
  });

  final String scopeKind;
  final String scopeId;
  final String effectiveAtBusinessDate;
  final String ianaTimezone;
  final String weekStartDay;
  final int weekStartDayInt;
  final String businessDayStartLocal;
  final List<ValidatedServicePeriod> servicePeriods;
}

/// Validates a complete profile payload (POST shape). Throws
/// [BusinessTimingValidationError] on the first violation. Field
/// presence is required; PATCH semantics live in [validateProfilePatch].
ValidatedBusinessTimingProfile validateNewBusinessTimingProfile(
  Map<String, Object?> body,
) {
  final scopeKind = _requireScopeKind(body, 'scopeKind');
  final scopeId = _requireUuid(body, 'scopeId');
  final effectiveAt = _requireBusinessDate(body, 'effectiveAtBusinessDate');
  final ianaTimezone = _requireTimezone(body, 'ianaTimezone');
  final weekStartDay = _requireWeekStartDay(body, 'weekStartDay');
  final weekStartInt = _weekStartDayToInt(weekStartDay);
  final businessDayStart =
      _requireQuarterHour(body, 'businessDayStartLocal');
  final servicePeriodsRaw = body['servicePeriods'];
  if (servicePeriodsRaw is! List) {
    throw const BusinessTimingValidationError(
      code: 'invalid_period_count',
      message: 'servicePeriods must be a non-empty array of 1..4 entries',
      path: '/servicePeriods',
    );
  }
  final servicePeriods = _validateServicePeriodSet(
    servicePeriodsRaw,
    businessDayStart: businessDayStart,
  );
  return ValidatedBusinessTimingProfile(
    scopeKind: scopeKind,
    scopeId: scopeId,
    effectiveAtBusinessDate: effectiveAt,
    ianaTimezone: ianaTimezone,
    weekStartDay: weekStartDay,
    weekStartDayInt: weekStartInt,
    businessDayStartLocal: businessDayStart,
    servicePeriods: servicePeriods,
  );
}

/// Validates a PATCH payload over an existing profile. Every top-level
/// field is optional; when servicePeriods is supplied, the entire set
/// replaces the existing one (whole-set semantics from the timing
/// plan). The caller passes the existing profile values via [existing]
/// so the merge can re-validate the whole resulting profile.
ValidatedBusinessTimingProfile validateProfilePatch({
  required Map<String, Object?> body,
  required ValidatedBusinessTimingProfile existing,
}) {
  final scopeKind = body.containsKey('scopeKind')
      ? _requireScopeKind(body, 'scopeKind')
      : existing.scopeKind;
  final scopeId = body.containsKey('scopeId')
      ? _requireUuid(body, 'scopeId')
      : existing.scopeId;
  final effectiveAt = body.containsKey('effectiveAtBusinessDate')
      ? _requireBusinessDate(body, 'effectiveAtBusinessDate')
      : existing.effectiveAtBusinessDate;
  final ianaTimezone = body.containsKey('ianaTimezone')
      ? _requireTimezone(body, 'ianaTimezone')
      : existing.ianaTimezone;
  final weekStartDay = body.containsKey('weekStartDay')
      ? _requireWeekStartDay(body, 'weekStartDay')
      : existing.weekStartDay;
  final weekStartInt = _weekStartDayToInt(weekStartDay);
  final businessDayStart = body.containsKey('businessDayStartLocal')
      ? _requireQuarterHour(body, 'businessDayStartLocal')
      : existing.businessDayStartLocal;
  final List<ValidatedServicePeriod> periods;
  if (body.containsKey('servicePeriods')) {
    final raw = body['servicePeriods'];
    if (raw is! List) {
      throw const BusinessTimingValidationError(
        code: 'invalid_period_count',
        message: 'servicePeriods must be an array of 1..4 entries',
        path: '/servicePeriods',
      );
    }
    periods = _validateServicePeriodSet(raw, businessDayStart: businessDayStart);
  } else {
    // No servicePeriods change: re-validate the existing set against
    // the (possibly new) business-day start so a partial PATCH that
    // moves the day boundary cannot leave the profile in an invalid
    // state.
    final raw = <Map<String, Object?>>[
      for (final p in existing.servicePeriods)
        <String, Object?>{
          'key': p.key,
          'label': p.label,
          'startLocal': p.startLocal,
          'endLocal': p.endLocal,
        },
    ];
    periods = _validateServicePeriodSet(raw, businessDayStart: businessDayStart);
  }
  return ValidatedBusinessTimingProfile(
    scopeKind: scopeKind,
    scopeId: scopeId,
    effectiveAtBusinessDate: effectiveAt,
    ianaTimezone: ianaTimezone,
    weekStartDay: weekStartDay,
    weekStartDayInt: weekStartInt,
    businessDayStartLocal: businessDayStart,
    servicePeriods: periods,
  );
}

/// Validates the body of a single-period add (POST .../service-periods).
/// The period is merged into [existing.servicePeriods] then the whole
/// profile is re-validated. Returns the new period plus the merged set
/// so the repository can write either the diff or the full set.
({ValidatedServicePeriod added, List<ValidatedServicePeriod> merged})
    validateAddServicePeriod({
  required Map<String, Object?> body,
  required ValidatedBusinessTimingProfile existing,
}) {
  final period = _validateServicePeriodEntry(body, index: existing.servicePeriods.length);
  if (existing.servicePeriods.any((p) => p.key == period.key)) {
    throw BusinessTimingValidationError(
      code: 'duplicate_service_period_key',
      message: 'service period key already exists on this profile',
      path: '/key',
      extras: <String, Object?>{'key': period.key},
    );
  }
  final merged = <Map<String, Object?>>[
    for (final p in existing.servicePeriods)
      <String, Object?>{
        'key': p.key,
        'label': p.label,
        'startLocal': p.startLocal,
        'endLocal': p.endLocal,
      },
    <String, Object?>{
      'key': period.key,
      'label': period.label,
      'startLocal': period.startLocal,
      'endLocal': period.endLocal,
    },
  ];
  final mergedValidated = _validateServicePeriodSet(
    merged,
    businessDayStart: existing.businessDayStartLocal,
  );
  return (added: period, merged: mergedValidated);
}

/// Validates a single-period PATCH body. The URL path key cannot be
/// renamed (the contract says any `key` field in the body is a 400
/// `invalid_field`). Returns the merged set so the caller can replace
/// the whole period set.
List<ValidatedServicePeriod> validateUpdateServicePeriod({
  required Map<String, Object?> body,
  required String urlKey,
  required ValidatedBusinessTimingProfile existing,
}) {
  if (body.containsKey('key')) {
    throw const BusinessTimingValidationError(
      code: 'invalid_field',
      message: 'service period key cannot be renamed via PATCH',
      path: '/key',
    );
  }
  ValidatedServicePeriod? target;
  for (final p in existing.servicePeriods) {
    if (p.key == urlKey) {
      target = p;
      break;
    }
  }
  if (target == null) {
    throw BusinessTimingValidationError(
      code: 'service_period_not_found',
      message: 'service period not found on this profile',
      path: '/key',
      extras: <String, Object?>{'key': urlKey},
    );
  }
  final mergedLabel = body.containsKey('label')
      ? _requireLabel(body, 'label')
      : target.label;
  final mergedStart = body.containsKey('startLocal')
      ? _requireQuarterHour(body, 'startLocal')
      : target.startLocal;
  final mergedEnd = body.containsKey('endLocal')
      ? _requireQuarterHour(body, 'endLocal')
      : target.endLocal;
  final raw = <Map<String, Object?>>[
    for (final p in existing.servicePeriods)
      if (p.key == urlKey)
        <String, Object?>{
          'key': p.key,
          'label': mergedLabel,
          'startLocal': mergedStart,
          'endLocal': mergedEnd,
        }
      else
        <String, Object?>{
          'key': p.key,
          'label': p.label,
          'startLocal': p.startLocal,
          'endLocal': p.endLocal,
        },
  ];
  return _validateServicePeriodSet(
    raw,
    businessDayStart: existing.businessDayStartLocal,
  );
}

// ─── Internals ─────────────────────────────────────────────────────

List<ValidatedServicePeriod> _validateServicePeriodSet(
  List<Object?> raw, {
  required String businessDayStart,
}) {
  if (raw.isEmpty || raw.length > 4) {
    throw BusinessTimingValidationError(
      code: 'invalid_period_count',
      message: 'service period count must be between 1 and 4 (got '
          '${raw.length})',
      path: '/servicePeriods',
    );
  }
  final periods = <ValidatedServicePeriod>[];
  final keys = <String>{};
  var rollingCount = 0;
  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    if (item is! Map) {
      throw BusinessTimingValidationError(
        code: 'invalid_service_period',
        message: 'servicePeriods entry must be an object',
        path: '/servicePeriods/$i',
      );
    }
    final period = _validateServicePeriodEntry(
      item.cast<String, Object?>(),
      index: i,
    );
    if (!keys.add(period.key)) {
      throw BusinessTimingValidationError(
        code: 'duplicate_service_period_key',
        message: 'service period keys must be unique within the profile',
        path: '/servicePeriods/$i/key',
        extras: <String, Object?>{'key': period.key},
      );
    }
    if (period.rollsPastMidnight) rollingCount += 1;
    periods.add(period);
  }
  if (rollingCount > 1) {
    throw const BusinessTimingValidationError(
      code: 'multiple_past_midnight_periods',
      message: 'at most one service period may roll past midnight',
      path: '/servicePeriods',
    );
  }
  // Pairwise overlap check.
  for (var i = 0; i < periods.length; i++) {
    for (var j = i + 1; j < periods.length; j++) {
      if (_periodsOverlap(periods[i], periods[j])) {
        throw BusinessTimingValidationError(
          code: 'service_period_overlap',
          message: 'service periods overlap',
          path: '/servicePeriods',
          extras: <String, Object?>{
            'left_index': i,
            'right_index': j,
            'left_key': periods[i].key,
            'right_key': periods[j].key,
          },
        );
      }
    }
  }
  // business-day-start cannot fall inside any period.
  final dayStartMinute = _quarterHourToMinute(businessDayStart);
  for (var i = 0; i < periods.length; i++) {
    final p = periods[i];
    if (_minuteIsInside(
      target: dayStartMinute,
      start: p.startMinute,
      end: p.endMinute,
      rolls: p.rollsPastMidnight,
    )) {
      throw BusinessTimingValidationError(
        code: 'business_day_start_inside_period',
        message: 'business day start time falls inside a service period',
        path: '/businessDayStartLocal',
        extras: <String, Object?>{
          'period_key': p.key,
          'period_index': i,
        },
      );
    }
  }
  return periods;
}

ValidatedServicePeriod _validateServicePeriodEntry(
  Map<String, Object?> body, {
  required int index,
}) {
  final key = _requirePeriodKey(body, 'key', index: index);
  final label = _requireLabel(body, 'label', index: index);
  final start = _requireQuarterHour(body, 'startLocal', index: index);
  final end = _requireQuarterHour(body, 'endLocal', index: index);
  final startMinute = _quarterHourToMinute(start);
  final endMinute = _quarterHourToMinute(end);
  final rolls = endMinute <= startMinute;
  return ValidatedServicePeriod(
    key: key,
    label: label,
    startLocal: start,
    endLocal: end,
    startMinute: startMinute,
    endMinute: endMinute,
    rollsPastMidnight: rolls,
  );
}

bool _periodsOverlap(ValidatedServicePeriod a, ValidatedServicePeriod b) {
  return _minuteIsInside(
        target: b.startMinute,
        start: a.startMinute,
        end: a.endMinute,
        rolls: a.rollsPastMidnight,
      ) ||
      _minuteIsInside(
        target: a.startMinute,
        start: b.startMinute,
        end: b.endMinute,
        rolls: b.rollsPastMidnight,
      );
}

bool _minuteIsInside({
  required int target,
  required int start,
  required int end,
  required bool rolls,
}) {
  if (rolls) {
    return target >= start || target < end;
  }
  return target >= start && target < end;
}

String _requireScopeKind(Map<String, Object?> body, String field) {
  final raw = body[field];
  if (raw is! String) {
    throw BusinessTimingValidationError(
      code: 'invalid_scope',
      message: 'scopeKind must be one of operator, org_unit, location',
      path: '/$field',
    );
  }
  if (raw == 'operator' || raw == 'org_unit' || raw == 'location') {
    return raw;
  }
  throw BusinessTimingValidationError(
    code: 'invalid_scope',
    message: 'scopeKind must be one of operator, org_unit, location',
    path: '/$field',
    extras: <String, Object?>{'value': raw},
  );
}

String _requireUuid(Map<String, Object?> body, String field) {
  final raw = body[field];
  if (raw is! String || !_isUuid(raw)) {
    throw BusinessTimingValidationError(
      code: 'invalid_scope',
      message: '$field must be a UUID',
      path: '/$field',
    );
  }
  return raw;
}

String _requireBusinessDate(Map<String, Object?> body, String field) {
  final raw = body[field];
  if (raw is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) {
    throw BusinessTimingValidationError(
      code: 'invalid_business_date',
      message: '$field must be YYYY-MM-DD',
      path: '/$field',
    );
  }
  return raw;
}

String _requireTimezone(Map<String, Object?> body, String field) {
  final raw = body[field];
  if (raw is! String || !kBusinessTimingAllowedIanaTimezones.contains(raw)) {
    throw BusinessTimingValidationError(
      code: 'invalid_iana_timezone',
      message: '$field must be a recognized IANA timezone',
      path: '/$field',
    );
  }
  return raw;
}

String _requireWeekStartDay(Map<String, Object?> body, String field) {
  final raw = body[field];
  if (raw is! String || !kBusinessTimingWeekStartDays.contains(raw)) {
    throw BusinessTimingValidationError(
      code: 'invalid_week_start_day',
      message: '$field must be one of monday, tuesday, ..., sunday',
      path: '/$field',
    );
  }
  return raw;
}

String _requireQuarterHour(
  Map<String, Object?> body,
  String field, {
  int? index,
}) {
  final raw = body[field];
  final path = index == null
      ? '/$field'
      : '/servicePeriods/$index/$field';
  if (raw is! String || !RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(raw)) {
    throw BusinessTimingValidationError(
      code: 'invalid_quarter_hour_boundary',
      message: '$field must be HH:MM in 24-hour format',
      path: path,
    );
  }
  final minute = int.parse(raw.substring(3, 5));
  if (minute % 15 != 0) {
    throw BusinessTimingValidationError(
      code: 'invalid_quarter_hour_boundary',
      message: '$field must align to a quarter-hour boundary (00, 15, 30, 45)',
      path: path,
    );
  }
  return raw;
}

String _requirePeriodKey(
  Map<String, Object?> body,
  String field, {
  required int index,
}) {
  final raw = body[field];
  if (raw is! String ||
      !RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(raw)) {
    throw BusinessTimingValidationError(
      code: 'invalid_service_period_key',
      message: 'service period key must match ^[a-z][a-z0-9_]{0,63}\$',
      path: '/servicePeriods/$index/$field',
    );
  }
  return raw;
}

String _requireLabel(
  Map<String, Object?> body,
  String field, {
  int? index,
}) {
  final raw = body[field];
  final path = index == null
      ? '/$field'
      : '/servicePeriods/$index/$field';
  if (raw is! String) {
    throw BusinessTimingValidationError(
      code: 'invalid_service_period_label',
      message: '$field must be a string of length 1..40',
      path: path,
    );
  }
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.length > 40) {
    throw BusinessTimingValidationError(
      code: 'invalid_service_period_label',
      message: '$field must be a non-empty string of at most 40 characters',
      path: path,
    );
  }
  return trimmed;
}

int _quarterHourToMinute(String hhmm) {
  final hour = int.parse(hhmm.substring(0, 2));
  final minute = int.parse(hhmm.substring(3, 5));
  return hour * 60 + minute;
}

int _weekStartDayToInt(String weekStartDay) {
  // Repository column stores 1..7 with Monday=1 to align with the
  // Postgres business_timing_profiles.week_start_day check (1..7).
  switch (weekStartDay) {
    case 'monday':
      return 1;
    case 'tuesday':
      return 2;
    case 'wednesday':
      return 3;
    case 'thursday':
      return 4;
    case 'friday':
      return 5;
    case 'saturday':
      return 6;
    case 'sunday':
      return 7;
  }
  throw StateError('weekStartDay was not validated: $weekStartDay');
}

bool _isUuid(String raw) {
  return RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(raw);
}

// ─── Account-payload validators (PATCH /v1/operator/account) ──────

class ValidatedOperatorAccountPatch {
  const ValidatedOperatorAccountPatch({
    required this.fields,
    required this.changedFieldNames,
  });

  /// Map of database-column-name to value. Null entries clear the
  /// column when the column is nullable.
  final Map<String, Object?> fields;

  /// Camel-cased field names from the request body the caller asked
  /// to change. Used by the audit-log payload so the audit row says
  /// `fields_changed: ['businessName', 'logoUrl']`.
  final List<String> changedFieldNames;
}

const Map<String, String> _accountFieldToColumn = <String, String>{
  'businessName': 'business_name',
  'logoUrl': 'logo_url',
  'currencyCode': 'preferred_currency',
  'localeTag': 'locale_tag',
  'weekStartDay': 'week_start_day',
  'rolloverHour': 'rollover_hour',
};

/// Validates a PATCH /v1/operator/account body. Every field is
/// optional. Returns the resolved column->value map for the repository
/// adapter. Throws BusinessTimingValidationError on the first
/// violation.
ValidatedOperatorAccountPatch validateOperatorAccountPatch(
  Map<String, Object?> body,
) {
  final fields = <String, Object?>{};
  final changed = <String>[];

  if (body.containsKey('businessName')) {
    final value = body['businessName'];
    if (value == null) {
      throw const BusinessTimingValidationError(
        code: 'invalid_business_name',
        message: 'businessName cannot be null',
        path: '/businessName',
      );
    }
    if (value is! String) {
      throw const BusinessTimingValidationError(
        code: 'invalid_business_name',
        message: 'businessName must be a string of length 1..120',
        path: '/businessName',
      );
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 120) {
      throw const BusinessTimingValidationError(
        code: 'invalid_business_name',
        message: 'businessName must be a non-empty string of at most 120 characters',
        path: '/businessName',
      );
    }
    fields['business_name'] = trimmed;
    changed.add('businessName');
  }

  if (body.containsKey('logoUrl')) {
    final value = body['logoUrl'];
    if (value == null) {
      fields['logo_url'] = null;
    } else if (value is String) {
      if (!value.startsWith('https://') || value.length > 2048) {
        throw const BusinessTimingValidationError(
          code: 'invalid_logo_url',
          message: 'logoUrl must be an https URL of at most 2048 characters',
          path: '/logoUrl',
        );
      }
      fields['logo_url'] = value;
    } else {
      throw const BusinessTimingValidationError(
        code: 'invalid_logo_url',
        message: 'logoUrl must be null or a string',
        path: '/logoUrl',
      );
    }
    changed.add('logoUrl');
  }

  if (body.containsKey('currencyCode')) {
    final value = body['currencyCode'];
    if (value is! String || !RegExp(r'^[A-Z]{3}$').hasMatch(value)) {
      throw const BusinessTimingValidationError(
        code: 'invalid_currency_code',
        message: 'currencyCode must be 3 uppercase letters (ISO 4217)',
        path: '/currencyCode',
      );
    }
    fields['preferred_currency'] = value;
    changed.add('currencyCode');
  }

  if (body.containsKey('localeTag')) {
    final value = body['localeTag'];
    if (value is! String ||
        !RegExp(r'^[a-z]{2,3}(-[A-Z]{2})?$').hasMatch(value)) {
      throw const BusinessTimingValidationError(
        code: 'invalid_locale_tag',
        message: 'localeTag must be a BCP 47 tag like en-US or fr-CA',
        path: '/localeTag',
      );
    }
    fields['locale_tag'] = value;
    changed.add('localeTag');
  }

  if (body.containsKey('weekStartDay')) {
    final value = body['weekStartDay'];
    if (value is! String || !kBusinessTimingWeekStartDays.contains(value)) {
      throw const BusinessTimingValidationError(
        code: 'invalid_week_start_day',
        message: 'weekStartDay must be one of monday, tuesday, ..., sunday',
        path: '/weekStartDay',
      );
    }
    fields['week_start_day'] = value;
    changed.add('weekStartDay');
  }

  if (body.containsKey('rolloverHour')) {
    final value = body['rolloverHour'];
    if (value is! int || value < 0 || value > 23) {
      throw const BusinessTimingValidationError(
        code: 'invalid_rollover_hour',
        message: 'rolloverHour must be an integer between 0 and 23',
        path: '/rolloverHour',
      );
    }
    fields['rollover_hour'] = value;
    changed.add('rolloverHour');
  }

  // Reject unknown fields so the frontend cannot smuggle column writes
  // by guessing names; this guards against schema drift between web
  // and proxy.
  for (final fieldName in body.keys) {
    if (!_accountFieldToColumn.containsKey(fieldName)) {
      throw BusinessTimingValidationError(
        code: 'invalid_field',
        message: 'unknown field: $fieldName',
        path: '/$fieldName',
      );
    }
  }

  return ValidatedOperatorAccountPatch(
    fields: fields,
    changedFieldNames: changed,
  );
}
