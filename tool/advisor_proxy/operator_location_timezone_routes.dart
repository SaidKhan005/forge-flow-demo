// Wave 2 W-6 backend - PATCH /v1/operator/location-timezone.
//
// Closes the backend half of W-6 (PR #682). W-6 shipped the operator-
// web Account screen's "Location timezone" editor + the
// `WebAccountGateway.patchLocationTimezone` wire contract, but the
// matching proxy handler was parked as ops-debt with a known 404 from
// the proxy. This file ships the handler.
//
// Wire contract (pinned by `web_account_gateway.dart`):
//
//   PATCH /v1/operator/location-timezone
//   Authorization: Bearer <id token>
//   Idempotency-Key: <generated per request>
//   Body: { "ianaTimezone": "America/Toronto" }
//
//   200 OK:
//     {
//       "operatorId": "<uuid>",
//       "locationId": "<uuid>",
//       "ianaTimezone": "America/Toronto",
//       "previousIanaTimezone": "UTC",
//       "updatedAt": "2026-05-14T12:34:56.000Z"
//     }
//
//   400 invalid_timezone      - missing/blank/not in IANA tz database
//   400 no_primary_location   - operator has no primary_location_id
//   400 idempotency_key_*     - dispatcher-enforced
//   403 forbidden             - role gate (dispatcher-enforced)
//   404 location_not_found    - primary location row missing or deleted
//   409 idempotency_key_conflict - dispatcher-enforced
//
// Why a sibling file (not the monolith)
// -------------------------------------
// `tool/advisor_proxy/advisor_proxy.dart` is at the
// `kAdvisorProxyMaxLines` bleed-stop ceiling. Per CLAUDE.md "Ceiling-
// raise rule (R-2)" raising it requires explicit operator approval.
// We follow the W-5 (`business_logo_upload_routes.dart`) precedent:
// the new handler ships as a sibling file and slots into the existing
// [OperatorWriteRouter] dispatch path. The monolith's dispatcher
// already routes operator-write paths through
// `OperatorWriteRouter.matches(path, method)` + `.handle(...)`. We
// only extend `operator_routes.dart` to add this path to the matcher
// + dispatch table.
//
// Validation
// ----------
// IANA timezone is validated against the full IANA tz database via
// `package:timezone` (already in `pubspec.yaml`). The W-6 frontend's
// 14-option shortlist is just a UX affordance; the frontend's
// "Custom IANA timezone" text field accepts any IANA name and the
// backend is the source-of-truth validator. This mirrors the
// existing `lib/utils/iana_timezones.dart` helper.
//
// Primary-location resolution (HP #11 timezone is location-scoped)
// ----------------------------------------------------------------
// The wire contract does NOT carry a `location_id` field. The
// frontend `web_account_gateway.dart` resolves the primary location
// server-side; we look up the operator's `primary_location_id` from
// the operator row (the JWT carries the operator_id only). When the
// operator has no primary location, the route returns 400
// `no_primary_location` instead of writing.
//
// Operator-scoped writes (HP #4)
// -------------------------------
// The handler delegates to `LocationsRepository.updateLocationTimezone`,
// which adds `operator_id` to the WHERE clause of the UPDATE so a
// stale/malicious location_id cannot reach across tenants. RLS on
// `public.locations` is the backup defence.

import 'package:forge_and_flow/utils/iana_timezones.dart';

/// Operator-scoped path constant. The frontend gateway pins this
/// string in `web_account_gateway.dart` as
/// `operatorLocationTimezonePath`.
const String operatorLocationTimezonePath =
    '/v1/operator/location-timezone';

/// Resolved location-timezone row returned by the gateway after a
/// successful update.
class LocationTimezoneRecord {
  const LocationTimezoneRecord({
    required this.operatorId,
    required this.locationId,
    required this.ianaTimezone,
    required this.previousIanaTimezone,
    required this.updatedAt,
  });

  final String operatorId;
  final String locationId;
  final String ianaTimezone;

  /// The IANA tz string the location carried BEFORE this update. The
  /// audit row includes this so the operator's audit log captures
  /// the before/after pair. The W-6 frontend ignores this field; it
  /// is present in the response envelope for diagnostics + tests.
  final String previousIanaTimezone;

  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'operatorId': operatorId,
        'locationId': locationId,
        'ianaTimezone': ianaTimezone,
        'previousIanaTimezone': previousIanaTimezone,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };
}

/// Reason codes the gateway returns when the write cannot proceed.
/// Keeps the route handler decoupled from `dart:io`-style exceptions.
enum LocationTimezoneUpdateOutcomeKind {
  ok,

  /// Operator row has no `primary_location_id` (operator never
  /// completed onboarding to the cloud-foundation schema). 400.
  noPrimaryLocation,

  /// Location row was missing or soft-deleted. 404.
  locationNotFound,
}

/// Result envelope. Either `kind == ok` (carrying [record]) or a
/// failure reason the handler maps to an HTTP status.
class LocationTimezoneUpdateOutcome {
  const LocationTimezoneUpdateOutcome.ok(this.record)
      : kind = LocationTimezoneUpdateOutcomeKind.ok;
  const LocationTimezoneUpdateOutcome.noPrimaryLocation()
      : kind = LocationTimezoneUpdateOutcomeKind.noPrimaryLocation,
        record = null;
  const LocationTimezoneUpdateOutcome.locationNotFound()
      : kind = LocationTimezoneUpdateOutcomeKind.locationNotFound,
        record = null;

  final LocationTimezoneUpdateOutcomeKind kind;
  final LocationTimezoneRecord? record;
}

/// Gateway abstraction. Production wires this to a
/// `LocationsRepository`-backed implementation; tests pass a recording
/// fake so the handler can be exercised without standing up Postgres.
abstract class OperatorLocationTimezoneWriteGateway {
  /// Resolve the operator's primary location and write
  /// [ianaTimezone] onto the `locations.timezone` column. The
  /// implementation must enforce `(operator_id, location_id)` in the
  /// UPDATE's WHERE clause so the write cannot escape the operator's
  /// scope.
  Future<LocationTimezoneUpdateOutcome> updateLocationTimezone({
    required String operatorId,
    required String ianaTimezone,
    required String adminReason,
  });
}

/// Validation outcome. Either a sanitised `ianaTimezone` string ready
/// to write, or a JSON envelope the route should write straight back
/// to the client.
class LocationTimezoneDecode {
  const LocationTimezoneDecode.success(this.ianaTimezone)
      : status = 200,
        body = null;
  const LocationTimezoneDecode.failure({required this.status, required this.body})
      : ianaTimezone = null;

  final int status;
  final Map<String, Object?>? body;
  final String? ianaTimezone;

  bool get ok => ianaTimezone != null;
}

/// Validates the request body shape + IANA timezone value. Exposed
/// for direct unit testing of the validation rules without standing
/// up an HTTP server (mirrors `decodeBusinessLogoUploadBody` in
/// `business_logo_upload_routes.dart`).
LocationTimezoneDecode decodeLocationTimezoneBody(Map<String, Object?> body) {
  final raw = body['ianaTimezone'];
  if (raw is! String) {
    return const LocationTimezoneDecode.failure(
      status: 400,
      body: <String, Object?>{
        'error': 'invalid_timezone',
        'message':
            'ianaTimezone must be a non-empty string '
            '(for example, America/Toronto).',
      },
    );
  }
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return const LocationTimezoneDecode.failure(
      status: 400,
      body: <String, Object?>{
        'error': 'invalid_timezone',
        'message':
            'ianaTimezone must be a non-empty string '
            '(for example, America/Toronto).',
      },
    );
  }
  if (!isValidIanaTimezoneName(trimmed)) {
    return LocationTimezoneDecode.failure(
      status: 400,
      body: <String, Object?>{
        'error': 'invalid_timezone',
        'message':
            'ianaTimezone "$trimmed" is not a recognised IANA tz '
            'database name. Pick a value from the shortlist '
            '(for example, America/Toronto) or type a valid IANA '
            'name such as Europe/Paris.',
      },
    );
  }
  return LocationTimezoneDecode.success(trimmed);
}

/// Route handler. The caller (the [OperatorWriteRouter] extension)
/// supplies the validated JSON body + the operator id. Returns the
/// (statusCode, body) envelope the dispatcher writes back to the
/// client. Mirrors `BusinessLogoUploadHandler.handleUpload`.
class OperatorLocationTimezoneHandler {
  OperatorLocationTimezoneHandler({
    required OperatorLocationTimezoneWriteGateway gateway,
  }) : _gateway = gateway;

  final OperatorLocationTimezoneWriteGateway _gateway;

  Future<({int statusCode, Map<String, Object?> body})> handlePatch({
    required String operatorId,
    required String actorUserId,
    required Map<String, Object?> body,
  }) async {
    final decode = decodeLocationTimezoneBody(body);
    if (!decode.ok) {
      return (statusCode: decode.status, body: decode.body!);
    }
    final adminReason =
        'operator.location_timezone.patch:$actorUserId';
    final LocationTimezoneUpdateOutcome outcome;
    try {
      outcome = await _gateway.updateLocationTimezone(
        operatorId: operatorId,
        ianaTimezone: decode.ianaTimezone!,
        adminReason: adminReason,
      );
    } on Exception catch (error) {
      return (
        statusCode: 503,
        body: <String, Object?>{
          'error': 'operator_location_timezone_unavailable',
          'message':
              'location timezone update is unavailable; please retry.',
          'detail': error.toString(),
        },
      );
    }
    switch (outcome.kind) {
      case LocationTimezoneUpdateOutcomeKind.ok:
        return (statusCode: 200, body: outcome.record!.toJson());
      case LocationTimezoneUpdateOutcomeKind.noPrimaryLocation:
        return (
          statusCode: 400,
          body: const <String, Object?>{
            'error': 'no_primary_location',
            'message':
                'This account has no primary location set yet. Finish '
                'onboarding before setting a location timezone.',
          },
        );
      case LocationTimezoneUpdateOutcomeKind.locationNotFound:
        return (
          statusCode: 404,
          body: const <String, Object?>{
            'error': 'location_not_found',
            'message':
                'The primary location for this account was not found.',
          },
        );
    }
  }
}
