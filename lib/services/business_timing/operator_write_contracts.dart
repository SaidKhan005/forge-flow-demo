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
  });

  final String key;
  final String label;
  final String startLocal;
  final String endLocal;
  final bool rollsPastMidnight;

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key,
        'label': label,
        'startLocal': startLocal,
        'endLocal': endLocal,
        'rollsPastMidnight': rollsPastMidnight,
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

/// Gateway for PATCH /v1/operator/account.
abstract class OperatorAccountWriteGateway {
  Future<OperatorAccountRecord> patchAccount({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required ValidatedOperatorAccountPatch patch,
    required String adminReason,
  });
}

/// Gateway for the four business-timing-profile routes.
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
