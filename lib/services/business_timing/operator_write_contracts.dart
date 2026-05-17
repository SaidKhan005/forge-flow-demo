// Phase 11W.7 / Wave A2 - shared contracts between the proxy router
// (tool/advisor_proxy/operator_routes.dart) and the production
// repository-backed gateways (lib/services/business_timing/...).
//
// Lives in lib/ so both the proxy (tool/) and the runtime gateway
// implementations can reference the same wire records and gateway
// interfaces without a cycle. The proxy router still owns the HTTP
// envelope shape; this file owns the value classes the router
// returns and the gateway interfaces it depends on.

import 'business_timing_profile_validator.dart';

/// Wire shape of the operator account record returned by GET / PATCH.
class OperatorAccountRecord {
  const OperatorAccountRecord({
    required this.operatorId,
    required this.businessName,
    required this.logoUrl,
    required this.currencyCode,
    required this.localeTag,
    required this.weekStartDay,
    required this.rolloverHour,
    required this.updatedAt,
  });

  final String operatorId;
  final String businessName;
  final String? logoUrl;
  final String currencyCode;
  final String localeTag;
  final String weekStartDay;
  final int rolloverHour;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'operatorId': operatorId,
        'businessName': businessName,
        'logoUrl': logoUrl,
        'currencyCode': currencyCode,
        'localeTag': localeTag,
        'weekStartDay': weekStartDay,
        'rolloverHour': rolloverHour,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };
}

class OperatorBusinessTimingServicePeriodRecord {
  const OperatorBusinessTimingServicePeriodRecord({
    required this.key,
    required this.label,
    required this.startLocal,
    required this.endLocal,
    required this.rollsPastMidnight,
    this.shortLabel = '',
    this.sortOrder = 0,
    this.applicableDays = const <int>[1, 2, 3, 4, 5, 6, 7],
  });

  final String key;
  final String label;
  final String startLocal;
  final String endLocal;
  final bool rollsPastMidnight;

  /// Fix #4 / S1 — previously dropped on the wire. The canonical
  /// `ServicePeriodDefinition` carries these three; the read surfaces
  /// need them so day-restricted periods (e.g. "Weekend Brunch") and
  /// the operator-chosen short label / display order round-trip back
  /// out instead of being faked client-side.
  final String shortLabel;
  final int sortOrder;

  /// ISO weekdays the period applies to (1 = Monday .. 7 = Sunday).
  /// A full Mon..Sun list means "every day".
  final List<int> applicableDays;

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key,
        'label': label,
        'startLocal': startLocal,
        'endLocal': endLocal,
        'rollsPastMidnight': rollsPastMidnight,
        'shortLabel': shortLabel,
        'sortOrder': sortOrder,
        'applicableDays': List<int>.unmodifiable(applicableDays),
      };
}

class OperatorBusinessTimingProfileRecord {
  const OperatorBusinessTimingProfileRecord({
    required this.profileId,
    required this.scopeKind,
    required this.scopeId,
    required this.effectiveAtBusinessDate,
    required this.ianaTimezone,
    required this.weekStartDay,
    required this.businessDayStartLocal,
    required this.servicePeriods,
    required this.createdAt,
    required this.updatedAt,
  });

  final String profileId;
  final String scopeKind;
  final String scopeId;
  final String effectiveAtBusinessDate;
  final String ianaTimezone;
  final String weekStartDay;
  final String businessDayStartLocal;
  final List<OperatorBusinessTimingServicePeriodRecord> servicePeriods;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'profileId': profileId,
        'versionId': profileId,
        'scopeKind': scopeKind,
        'scopeId': scopeId,
        'effectiveAtBusinessDate': effectiveAtBusinessDate,
        'ianaTimezone': ianaTimezone,
        'weekStartDay': weekStartDay,
        'businessDayStartLocal': businessDayStartLocal,
        'servicePeriods': <Map<String, Object?>>[
          for (final period in servicePeriods) period.toJson(),
        ],
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };
}

/// Fix #4 / S1 — one candidate in the location-scoped business-timing
/// resolution chain. The proxy returns the FULL ordered candidate list
/// (operator default -> org-unit ancestors -> location override) so
/// the Flutter client can run the one canonical pure resolver. The
/// server does NOT fork the resolver; this record only carries the
/// candidate's raw fields plus the scope ancestry the wire previously
/// dropped (`scopeType`, `scopeId`, a human scope label) and the
/// location timezone the resolver needs.
class OperatorBusinessTimingResolutionCandidate {
  const OperatorBusinessTimingResolutionCandidate({
    required this.profileId,
    required this.scopeType,
    required this.scopeId,
    required this.scopeLabel,
    required this.scopeDepthRank,
    required this.ianaTimezone,
    required this.effectiveAtBusinessDate,
    required this.weekStartDay,
    required this.businessDayStartLocal,
    required this.servicePeriods,
    required this.createdAt,
    required this.updatedAt,
  });

  final String profileId;

  /// `operator` | `org_unit` | `location` — the canonical
  /// `business_timing_profiles.scope_type`.
  final String scopeType;
  final String scopeId;

  /// Human label for the rung. The profile's own `display_name` when
  /// set, else a scope-kind fallback ("Operator default", "Org unit",
  /// "Location override"). Never blank so the UI can render the
  /// inheritance chain without faking strings.
  final String scopeLabel;

  /// Position in resolver precedence as returned by the canonical
  /// `listCandidateProfilesForLocation` CTE (`scope_depth asc`): 0 for
  /// the operator default, ascending through org-unit ancestors,
  /// largest for the location override. The list is already ordered;
  /// this is exposed only so a client can assert the order it relied
  /// on without re-deriving it.
  final int scopeDepthRank;

  final String ianaTimezone;
  final String effectiveAtBusinessDate;
  final String weekStartDay;
  final String businessDayStartLocal;
  final List<OperatorBusinessTimingServicePeriodRecord> servicePeriods;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'profileId': profileId,
        'versionId': profileId,
        'scopeType': scopeType,
        // Back-compat alias: existing operator-web records key on
        // `scopeKind`; emit both so the read gateway can consume this
        // record with the same field accessor as the list route.
        'scopeKind': scopeType,
        'scopeId': scopeId,
        'scopeLabel': scopeLabel,
        'scopeDepthRank': scopeDepthRank,
        'ianaTimezone': ianaTimezone,
        'effectiveAtBusinessDate': effectiveAtBusinessDate,
        'weekStartDay': weekStartDay,
        'businessDayStartLocal': businessDayStartLocal,
        'servicePeriods': <Map<String, Object?>>[
          for (final period in servicePeriods) period.toJson(),
        ],
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };
}

/// Wire response for
/// `GET /v1/operator/locations/:locationId/business-timing-resolution`.
/// The candidate list is in canonical resolver precedence order
/// (operator default first, location override last). `businessDate`
/// echoes the date the candidate window was evaluated against so the
/// client can prove which effective-dated rows it received.
class OperatorBusinessTimingResolutionResult {
  const OperatorBusinessTimingResolutionResult({
    required this.operatorId,
    required this.locationId,
    required this.businessDate,
    required this.ianaTimezone,
    required this.candidates,
  });

  final String operatorId;
  final String locationId;
  final String businessDate;

  /// `locations.timezone` for the resolved location, surfaced once at
  /// the top level (the resolver needs it even when no candidate
  /// overrides it). Null only when the location row is missing.
  final String? ianaTimezone;
  final List<OperatorBusinessTimingResolutionCandidate> candidates;

  Map<String, Object?> toJson() => <String, Object?>{
        'operatorId': operatorId,
        'locationId': locationId,
        'businessDate': businessDate,
        'ianaTimezone': ianaTimezone,
        'candidates': <Map<String, Object?>>[
          for (final candidate in candidates) candidate.toJson(),
        ],
      };
}

/// Repository-shaped exception the gateway throws to signal a typed
/// HTTP envelope. The proxy router catches this and writes the
/// matching JSON without leaking stack traces.
class OperatorWriteRejected implements Exception {
  const OperatorWriteRejected({
    required this.code,
    required this.message,
    required this.statusCode,
    this.extras = const <String, Object?>{},
  });

  final String code;
  final String message;
  final int statusCode;
  final Map<String, Object?> extras;
}

/// Gateway for PATCH /v1/operator/account and the 11W.7 ops-debt
/// GET companion.
abstract class OperatorAccountWriteGateway {
  Future<OperatorAccountRecord> patchAccount({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required ValidatedOperatorAccountPatch patch,
    required String adminReason,
  });

  /// 11W.7 ops-debt — returns the resolved account row for
  /// [operatorId]. Returns null when the row is missing (router maps
  /// to 404). Read-only; no audit, no idempotency.
  Future<OperatorAccountRecord?> loadAccount({
    required String operatorId,
  });
}

/// Gateway for the four business-timing-profile write routes plus
/// the 11W.7 ops-debt GET list companion.
abstract class OperatorBusinessTimingWriteGateway {
  Future<OperatorBusinessTimingProfileRecord> createProfile({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required ValidatedBusinessTimingProfile validated,
    required String adminReason,
  });

  Future<OperatorBusinessTimingProfileRecord?> loadProfile({
    required String operatorId,
    required String profileId,
  });

  /// Fix #4 / S1 — the location-scoped, org-unit-ancestor-resolved
  /// candidate chain for [locationId] on [businessDate], in canonical
  /// resolver precedence order. Delegates to the canonical
  /// `BusinessTimingProfilesRepository.listCandidateProfilesForLocation`
  /// (the ltree ancestor CTE, ordered `scope_depth asc`) — NO
  /// server-side resolver fork. The client runs the one pure
  /// `BusinessTimingProfileResolver` over these candidates. Read-only.
  Future<OperatorBusinessTimingResolutionResult> resolveForLocation({
    required String operatorId,
    required String locationId,
    required String businessDate,
    String? actorUserId,
  });

  /// Fix #4 / S2 — the admin/cross-tenant analogue of
  /// [resolveForLocation]. Returns the SAME shape
  /// ([OperatorBusinessTimingResolutionResult]) for an admin actor
  /// reading ANY operator's location chain, by delegating to the
  /// canonical
  /// `BusinessTimingProfilesRepository.listCandidateProfilesForSystemLocation`
  /// (the sanctioned `runAsSystem` admin cross-operator bypass). NO
  /// server-side resolver fork; the admin client runs the one pure
  /// `BusinessTimingProfileResolver` over these candidates exactly
  /// like S1. READ-ONLY. [reason] is the required audit-attribution
  /// string for the system-scope transaction. MUST only be reached
  /// from the admin/super_admin-gated proxy route.
  Future<OperatorBusinessTimingResolutionResult> resolveForLocationAsSystem({
    required String operatorId,
    required String locationId,
    required String businessDate,
    required String reason,
  });

  /// 11W.7 ops-debt — lists every business-timing profile owned by
  /// [operatorId] in resolver-precedence order (operator default, org
  /// units, locations) with full service-period sets so the operator-
  /// web Settings shell can render the editor without a second round
  /// trip. Read-only.
  Future<List<OperatorBusinessTimingProfileRecord>> listProfiles({
    required String operatorId,
  });

  Future<OperatorBusinessTimingProfileRecord> updateProfile({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required String profileId,
    required ValidatedBusinessTimingProfile validated,
    required String adminReason,
  });

  Future<OperatorBusinessTimingProfileRecord> replaceServicePeriodSet({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required String profileId,
    required List<ValidatedServicePeriod> mergedSet,
    required String eventKind,
    required Map<String, Object?> auditPayload,
    required String adminReason,
  });
}

/// Audit-event payload the router emits for every successful write.
abstract class OperatorWriteAuditSink {
  Future<void> record({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String eventKind,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
  });
}
