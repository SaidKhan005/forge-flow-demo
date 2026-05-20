// Wave 2 U-FU-hp11-account — operator-scoped per-location account
// override routes.
//
// Routes
// ------
//   GET   /v1/operator/location-account-overrides/<location_id>
//   PATCH /v1/operator/location-account-overrides/<location_id>
//
// Auth + role gate
// ----------------
// Both routes resolve the operator id from the verified bearer token
// and reuse the existing `operator_owner` role
// gate (`kOperatorWriteRoles` in `operator_routes.dart`). No new
// permission key is introduced — per the slice intent, this surface
// rides on the same gate the rest of the operator-write surface uses
// for location-scoped writes (notably W-6 location-timezone).
//
// Why a sibling file (not the monolith)
// -------------------------------------
// `tool/advisor_proxy/advisor_proxy.dart` is at the
// `kAdvisorProxyMaxLines` bleed-stop ceiling. Per CLAUDE.md "Ceiling-
// raise rule (R-2)" raising it requires explicit operator approval.
// This file ships as a sibling and slots into the existing
// [OperatorWriteRouter] dispatch path (the same approach W-5 and W-6
// backend used). The monolith dispatcher needs no new if-block; the
// router's `matches` + `_dispatch` already cover the new path.
//
// Wire shape
// ----------
//
//   GET /v1/operator/location-account-overrides/{location_id}
//
//   200 OK:
//     {
//       "operatorId": "<uuid>",
//       "locationId": "<uuid>",
//       "effective": {
//         "ianaTimezone": "America/Toronto",
//         "localeCode": "en-US",
//         "currencyCode": "USD",
//         "businessDayRolloverHour": 4,
//         "contactEmail": "ops@example.com",
//         "contactPhone": null,
//       },
//       "override": {
//         "ianaTimezone": "Europe/London",
//         "localeCode": null,
//         "currencyCode": null,
//         "businessDayRolloverHour": null,
//         "contactEmail": null,
//         "contactPhone": null,
//       },
//       "businessDefault": {
//         "ianaTimezone": "America/Toronto",
//         "localeCode": "en-US",
//         "currencyCode": "USD",
//         "businessDayRolloverHour": 4,
//         "contactEmail": "ops@example.com",
//         "contactPhone": null,
//       },
//       "updatedAt": "2026-05-14T12:34:56.000Z"
//     }
//
//   PATCH /v1/operator/location-account-overrides/{location_id}
//
//   Body (any subset; explicit null clears the override):
//     {
//       "ianaTimezone": "Europe/London",
//       "localeCode": null,            // clears the override
//       "currencyCode": "GBP",
//       "businessDayRolloverHour": 4,
//       "contactEmail": "ops@example.com",
//       "contactPhone": "+44 20 7000 0000",
//     }
//
//   400 invalid_location_id        — path segment is not a UUID
//   400 invalid_currency_code      — not 3 uppercase letters
//   400 invalid_locale_code        — not BCP-47 shape
//   400 invalid_iana_timezone      — not in IANA tz database
//   400 invalid_rollover_hour      — not 0..23
//   400 invalid_contact_email      — missing @, length > 320
//   400 invalid_contact_phone      — empty or length > 64
//   400 no_fields_to_update        — body carries zero changes
//   400 location_not_owned         — `(operator_id, location_id)` mismatch
//   404 location_not_found         — location row missing or soft-deleted
//
// HP #4 — every write goes through `OperatorScopedRepository.withTenant`
// via [LocationAccountOverridesWriteGateway]. The composite FK in the
// migration (`(operator_id, location_id) -> locations`) is the
// database-layer guarantee.
//
// Audit — the route handler does NOT emit an audit row itself; the
// monolith's `OperatorWriteRouter._handleLocationAccountOverridesPatch`
// emits `operator_location_account_overrides_updated` on success with
// the previous + new field values.

import 'package:forge_and_flow/utils/iana_timezones.dart';

/// Route path prefix. The path itself carries the location id, so
/// matching uses `startsWith` + parsing.
const String operatorLocationAccountOverridesPathPrefix =
    '/v1/operator/location-account-overrides/';

/// True when [path] is shaped like
/// `/v1/operator/location-account-overrides/<uuid>` (or any non-empty
/// suffix; the handler validates the UUID shape).
bool isOperatorLocationAccountOverridesPath(String path) {
  if (!path.startsWith(operatorLocationAccountOverridesPathPrefix)) {
    return false;
  }
  final suffix = path.substring(
    operatorLocationAccountOverridesPathPrefix.length,
  );
  if (suffix.isEmpty) return false;
  // Reject nested paths (only one path segment after the prefix).
  if (suffix.contains('/')) return false;
  return true;
}

/// Extract the location id from a path matched by
/// [isOperatorLocationAccountOverridesPath]. Returns null when the
/// suffix is missing or is shaped wrong.
String? operatorLocationAccountOverridesIdOf(String path) {
  if (!isOperatorLocationAccountOverridesPath(path)) return null;
  return Uri.decodeComponent(
    path.substring(operatorLocationAccountOverridesPathPrefix.length),
  );
}

/// Wire-shape value carried back to the client. The effective +
/// override + businessDefault triple powers the HP #11 notice line on
/// the AccountScreen.
class LocationAccountOverridesRecord {
  const LocationAccountOverridesRecord({
    required this.operatorId,
    required this.locationId,
    required this.effective,
    required this.override,
    required this.businessDefault,
    this.sources = const LocationAccountOverridesSourcesRecord(),
    required this.updatedAt,
  });

  final String operatorId;
  final String locationId;
  final LocationAccountOverridesFieldSet effective;
  final LocationAccountOverridesFieldSet override;
  final LocationAccountOverridesFieldSet businessDefault;
  final LocationAccountOverridesSourcesRecord sources;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'operatorId': operatorId,
    'locationId': locationId,
    'effective': effective.toJson(),
    'override': override.toJson(),
    'businessDefault': businessDefault.toJson(),
    'sources': sources.toJson(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

/// Wire-shape sub-object — one of `effective` / `override` /
/// `businessDefault` on the response envelope.
class LocationAccountOverridesFieldSet {
  const LocationAccountOverridesFieldSet({
    this.ianaTimezone,
    this.localeCode,
    this.currencyCode,
    this.businessDayRolloverHour,
    this.contactEmail,
    this.contactPhone,
  });

  final String? ianaTimezone;
  final String? localeCode;
  final String? currencyCode;
  final int? businessDayRolloverHour;
  final String? contactEmail;
  final String? contactPhone;

  Map<String, Object?> toJson() => <String, Object?>{
    'ianaTimezone': ianaTimezone,
    'localeCode': localeCode,
    'currencyCode': currencyCode,
    'businessDayRolloverHour': businessDayRolloverHour,
    'contactEmail': contactEmail,
    'contactPhone': contactPhone,
  };
}

class LocationAccountOverridesSourceRecord {
  const LocationAccountOverridesSourceRecord({
    required this.scopeType,
    required this.scopeId,
    required this.scopeLabel,
    required this.setHere,
  });

  final String scopeType;
  final String scopeId;
  final String scopeLabel;
  final bool setHere;

  Map<String, Object?> toJson() => <String, Object?>{
    'scopeType': scopeType,
    'scopeId': scopeId,
    'scopeLabel': scopeLabel,
    'setHere': setHere,
  };
}

class LocationAccountOverridesSourcesRecord {
  const LocationAccountOverridesSourcesRecord({
    this.ianaTimezone,
    this.localeCode,
    this.currencyCode,
    this.businessDayRolloverHour,
    this.contactEmail,
    this.contactPhone,
  });

  final LocationAccountOverridesSourceRecord? ianaTimezone;
  final LocationAccountOverridesSourceRecord? localeCode;
  final LocationAccountOverridesSourceRecord? currencyCode;
  final LocationAccountOverridesSourceRecord? businessDayRolloverHour;
  final LocationAccountOverridesSourceRecord? contactEmail;
  final LocationAccountOverridesSourceRecord? contactPhone;

  Map<String, Object?> toJson() => <String, Object?>{
    'ianaTimezone': ianaTimezone?.toJson(),
    'localeCode': localeCode?.toJson(),
    'currencyCode': currencyCode?.toJson(),
    'businessDayRolloverHour': businessDayRolloverHour?.toJson(),
    'contactEmail': contactEmail?.toJson(),
    'contactPhone': contactPhone?.toJson(),
  };
}

/// Validated patch the dispatcher hands to the gateway. Each field is
/// independently nullable + carries a "clear" flag the gateway uses
/// to distinguish "leave alone" from "reset to inherit".
class ValidatedLocationAccountOverridesPatch {
  const ValidatedLocationAccountOverridesPatch({
    this.ianaTimezone,
    this.localeCode,
    this.currencyCode,
    this.businessDayRolloverHour,
    this.contactEmail,
    this.contactPhone,
    this.clearIanaTimezone = false,
    this.clearLocaleCode = false,
    this.clearCurrencyCode = false,
    this.clearBusinessDayRolloverHour = false,
    this.clearContactEmail = false,
    this.clearContactPhone = false,
  });

  final String? ianaTimezone;
  final String? localeCode;
  final String? currencyCode;
  final int? businessDayRolloverHour;
  final String? contactEmail;
  final String? contactPhone;

  final bool clearIanaTimezone;
  final bool clearLocaleCode;
  final bool clearCurrencyCode;
  final bool clearBusinessDayRolloverHour;
  final bool clearContactEmail;
  final bool clearContactPhone;

  /// True when no field is being set or cleared. Maps to
  /// `400 no_fields_to_update`.
  bool get isEmpty =>
      ianaTimezone == null &&
      !clearIanaTimezone &&
      localeCode == null &&
      !clearLocaleCode &&
      currencyCode == null &&
      !clearCurrencyCode &&
      businessDayRolloverHour == null &&
      !clearBusinessDayRolloverHour &&
      contactEmail == null &&
      !clearContactEmail &&
      contactPhone == null &&
      !clearContactPhone;

  /// Field name list used by the audit row.
  List<String> get changedFieldNames {
    return <String>[
      if (ianaTimezone != null || clearIanaTimezone) 'ianaTimezone',
      if (localeCode != null || clearLocaleCode) 'localeCode',
      if (currencyCode != null || clearCurrencyCode) 'currencyCode',
      if (businessDayRolloverHour != null || clearBusinessDayRolloverHour)
        'businessDayRolloverHour',
      if (contactEmail != null || clearContactEmail) 'contactEmail',
      if (contactPhone != null || clearContactPhone) 'contactPhone',
    ];
  }
}

/// Decode envelope: either a validated patch, or a rejection ready to
/// surface verbatim.
class LocationAccountOverridesDecode {
  const LocationAccountOverridesDecode.success(this.patch)
    : status = 200,
      body = null;
  const LocationAccountOverridesDecode.failure({
    required this.status,
    required this.body,
  }) : patch = null;

  final int status;
  final Map<String, Object?>? body;
  final ValidatedLocationAccountOverridesPatch? patch;

  bool get ok => patch != null;
}

/// Pure-Dart validation of the PATCH body. Surfaces deterministic
/// 400-shaped rejections without standing up HTTP. Tested via
/// `test/proxy/operator_location_account_overrides_routes_test.dart`.
LocationAccountOverridesDecode decodeLocationAccountOverridesPatchBody(
  Map<String, Object?> body,
) {
  String? ianaTimezone;
  bool clearIanaTimezone = false;
  String? localeCode;
  bool clearLocaleCode = false;
  String? currencyCode;
  bool clearCurrencyCode = false;
  int? rolloverHour;
  bool clearRolloverHour = false;
  String? contactEmail;
  bool clearContactEmail = false;
  String? contactPhone;
  bool clearContactPhone = false;

  if (body.containsKey('ianaTimezone')) {
    final raw = body['ianaTimezone'];
    if (raw == null) {
      clearIanaTimezone = true;
    } else if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        return _failure(
          'invalid_iana_timezone',
          'ianaTimezone must be a non-empty IANA tz name, or null to '
              'clear the override (for example, America/Toronto).',
        );
      }
      if (!isValidIanaTimezoneName(trimmed)) {
        return _failure(
          'invalid_iana_timezone',
          'ianaTimezone "$trimmed" is not a recognised IANA tz '
              'database name. Pick a value from the shortlist or '
              'type a valid IANA name such as Europe/Paris.',
        );
      }
      ianaTimezone = trimmed;
    } else {
      return _failure(
        'invalid_iana_timezone',
        'ianaTimezone must be a string or null.',
      );
    }
  }

  if (body.containsKey('localeCode')) {
    final raw = body['localeCode'];
    if (raw == null) {
      clearLocaleCode = true;
    } else if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        return _failure(
          'invalid_locale_code',
          'localeCode must be a non-empty BCP-47 locale (for example, '
              'en-US), or null to clear the override.',
        );
      }
      if (!_localeCodePattern.hasMatch(trimmed)) {
        return _failure(
          'invalid_locale_code',
          'localeCode "$trimmed" is not a valid BCP-47 locale tag. '
              'Use a shape like en-US or fr-CA.',
        );
      }
      localeCode = trimmed;
    } else {
      return _failure(
        'invalid_locale_code',
        'localeCode must be a string or null.',
      );
    }
  }

  if (body.containsKey('currencyCode')) {
    final raw = body['currencyCode'];
    if (raw == null) {
      clearCurrencyCode = true;
    } else if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        return _failure(
          'invalid_currency_code',
          'currencyCode must be a three-letter ISO 4217 code (for '
              'example, USD), or null to clear the override.',
        );
      }
      if (!_currencyCodePattern.hasMatch(trimmed)) {
        return _failure(
          'invalid_currency_code',
          'currencyCode "$trimmed" is not a valid ISO 4217 code. '
              'Use three uppercase letters such as CAD or EUR.',
        );
      }
      currencyCode = trimmed;
    } else {
      return _failure(
        'invalid_currency_code',
        'currencyCode must be a string or null.',
      );
    }
  }

  if (body.containsKey('businessDayRolloverHour')) {
    final raw = body['businessDayRolloverHour'];
    if (raw == null) {
      clearRolloverHour = true;
    } else if (raw is int) {
      if (raw < 0 || raw > 23) {
        return _failure(
          'invalid_rollover_hour',
          'businessDayRolloverHour must be between 0 and 23.',
        );
      }
      rolloverHour = raw;
    } else if (raw is num) {
      final asInt = raw.toInt();
      if (asInt != raw || asInt < 0 || asInt > 23) {
        return _failure(
          'invalid_rollover_hour',
          'businessDayRolloverHour must be an integer between 0 and 23.',
        );
      }
      rolloverHour = asInt;
    } else {
      return _failure(
        'invalid_rollover_hour',
        'businessDayRolloverHour must be an integer or null.',
      );
    }
  }

  if (body.containsKey('contactEmail')) {
    final raw = body['contactEmail'];
    if (raw == null) {
      clearContactEmail = true;
    } else if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        return _failure(
          'invalid_contact_email',
          'contactEmail must be a non-empty address (for example, '
              'ops@example.com), or null to clear the override.',
        );
      }
      if (!trimmed.contains('@') || trimmed.length > 320) {
        return _failure(
          'invalid_contact_email',
          'contactEmail must be a syntactically valid address and '
              '320 characters or fewer.',
        );
      }
      contactEmail = trimmed;
    } else {
      return _failure(
        'invalid_contact_email',
        'contactEmail must be a string or null.',
      );
    }
  }

  if (body.containsKey('contactPhone')) {
    final raw = body['contactPhone'];
    if (raw == null) {
      clearContactPhone = true;
    } else if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        return _failure(
          'invalid_contact_phone',
          'contactPhone must be a non-empty phone string, or null to '
              'clear the override.',
        );
      }
      if (trimmed.length > 64) {
        return _failure(
          'invalid_contact_phone',
          'contactPhone must be 64 characters or fewer.',
        );
      }
      contactPhone = trimmed;
    } else {
      return _failure(
        'invalid_contact_phone',
        'contactPhone must be a string or null.',
      );
    }
  }

  final patch = ValidatedLocationAccountOverridesPatch(
    ianaTimezone: ianaTimezone,
    clearIanaTimezone: clearIanaTimezone,
    localeCode: localeCode,
    clearLocaleCode: clearLocaleCode,
    currencyCode: currencyCode,
    clearCurrencyCode: clearCurrencyCode,
    businessDayRolloverHour: rolloverHour,
    clearBusinessDayRolloverHour: clearRolloverHour,
    contactEmail: contactEmail,
    clearContactEmail: clearContactEmail,
    contactPhone: contactPhone,
    clearContactPhone: clearContactPhone,
  );
  if (patch.isEmpty) {
    return _failure(
      'no_fields_to_update',
      'request body must include at least one editable field '
          '(ianaTimezone, localeCode, currencyCode, '
          'businessDayRolloverHour, contactEmail, contactPhone).',
    );
  }
  return LocationAccountOverridesDecode.success(patch);
}

LocationAccountOverridesDecode _failure(String error, String message) {
  return LocationAccountOverridesDecode.failure(
    status: 400,
    body: <String, Object?>{'error': error, 'message': message},
  );
}

final RegExp _localeCodePattern = RegExp(r'^[a-z]{2,3}(-[A-Z]{2})?$');
final RegExp _currencyCodePattern = RegExp(r'^[A-Z]{3}$');
final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

/// True when [value] looks like a lowercase UUID. Path-segment guard
/// for the GET + PATCH routes.
bool isLocationAccountOverridesUuid(String value) =>
    _uuidPattern.hasMatch(value);

/// Reason codes the gateway returns when the write cannot proceed.
enum LocationAccountOverridesOutcomeKind {
  ok,

  /// `(operator_id, location_id)` mismatch — the location belongs to
  /// a different operator or is soft-deleted. 400.
  locationNotOwned,

  /// The location row was missing entirely (gateway looked it up to
  /// resolve the business defaults). 404.
  locationNotFound,
}

/// Outcome envelope returned by the gateway.
class LocationAccountOverridesOutcome {
  const LocationAccountOverridesOutcome.ok(this.record)
    : kind = LocationAccountOverridesOutcomeKind.ok;
  const LocationAccountOverridesOutcome.locationNotOwned()
    : kind = LocationAccountOverridesOutcomeKind.locationNotOwned,
      record = null;
  const LocationAccountOverridesOutcome.locationNotFound()
    : kind = LocationAccountOverridesOutcomeKind.locationNotFound,
      record = null;

  final LocationAccountOverridesOutcomeKind kind;
  final LocationAccountOverridesRecord? record;
}

/// Gateway abstraction. Production wires this to a
/// [LocationAccountOverridesRepository]-backed implementation; tests
/// pass a recording fake so the handler can be exercised without
/// standing up Postgres.
abstract class LocationAccountOverridesWriteGateway {
  /// GET — resolve the effective / override / businessDefault triple.
  Future<LocationAccountOverridesOutcome> loadOverrides({
    required String operatorId,
    required String actorUserId,
    required String locationId,
    required String adminReason,
  });

  /// PATCH — upsert the override row + return the new effective triple.
  Future<LocationAccountOverridesOutcome> patchOverrides({
    required String operatorId,
    required String actorUserId,
    required String locationId,
    required ValidatedLocationAccountOverridesPatch patch,
    required String adminReason,
  });
}

/// Route handler. The dispatcher hands the decoded body + the
/// resolved operator scope; the handler validates path + body and
/// delegates to the gateway. Mirrors
/// `OperatorLocationTimezoneHandler.handlePatch`.
class OperatorLocationAccountOverridesHandler {
  OperatorLocationAccountOverridesHandler({
    required LocationAccountOverridesWriteGateway gateway,
  }) : _gateway = gateway;

  final LocationAccountOverridesWriteGateway _gateway;

  /// PATCH /v1/operator/location-account-overrides/{location_id}.
  Future<({int statusCode, Map<String, Object?> body})> handlePatch({
    required String operatorId,
    required String actorUserId,
    required String locationId,
    required Map<String, Object?> body,
  }) async {
    if (!isLocationAccountOverridesUuid(locationId)) {
      return (
        statusCode: 400,
        body: const <String, Object?>{
          'error': 'invalid_location_id',
          'message': 'location_id path segment must be a lowercase UUID.',
        },
      );
    }
    final decode = decodeLocationAccountOverridesPatchBody(body);
    if (!decode.ok) {
      return (statusCode: decode.status, body: decode.body!);
    }
    final adminReason =
        'operator.location_account_overrides.patch:$actorUserId';
    final LocationAccountOverridesOutcome outcome;
    try {
      outcome = await _gateway.patchOverrides(
        operatorId: operatorId,
        actorUserId: actorUserId,
        locationId: locationId,
        patch: decode.patch!,
        adminReason: adminReason,
      );
    } on Exception catch (error) {
      return (
        statusCode: 503,
        body: <String, Object?>{
          'error': 'operator_location_account_overrides_unavailable',
          'message':
              'per-location account overrides are unavailable; '
              'please retry.',
          'detail': error.toString(),
        },
      );
    }
    return _writeOutcome(outcome);
  }

  /// GET /v1/operator/location-account-overrides/{location_id}.
  Future<({int statusCode, Map<String, Object?> body})> handleGet({
    required String operatorId,
    required String actorUserId,
    required String locationId,
  }) async {
    if (!isLocationAccountOverridesUuid(locationId)) {
      return (
        statusCode: 400,
        body: const <String, Object?>{
          'error': 'invalid_location_id',
          'message': 'location_id path segment must be a lowercase UUID.',
        },
      );
    }
    final adminReason = 'operator.location_account_overrides.load:$actorUserId';
    final LocationAccountOverridesOutcome outcome;
    try {
      outcome = await _gateway.loadOverrides(
        operatorId: operatorId,
        actorUserId: actorUserId,
        locationId: locationId,
        adminReason: adminReason,
      );
    } on Exception catch (error) {
      return (
        statusCode: 503,
        body: <String, Object?>{
          'error': 'operator_location_account_overrides_unavailable',
          'message':
              'per-location account overrides are unavailable; '
              'please retry.',
          'detail': error.toString(),
        },
      );
    }
    return _writeOutcome(outcome);
  }

  ({int statusCode, Map<String, Object?> body}) _writeOutcome(
    LocationAccountOverridesOutcome outcome,
  ) {
    switch (outcome.kind) {
      case LocationAccountOverridesOutcomeKind.ok:
        return (statusCode: 200, body: outcome.record!.toJson());
      case LocationAccountOverridesOutcomeKind.locationNotOwned:
        return (
          statusCode: 400,
          body: const <String, Object?>{
            'error': 'location_not_owned',
            'message':
                'The requested location does not belong to this account.',
          },
        );
      case LocationAccountOverridesOutcomeKind.locationNotFound:
        return (
          statusCode: 404,
          body: const <String, Object?>{
            'error': 'location_not_found',
            'message': 'The requested location was not found.',
          },
        );
    }
  }
}
