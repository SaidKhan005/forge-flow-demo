// Shared test helpers for the advisor_proxy_*_test.dart split.
//
// Bucket 5c of the 2026-05-20 test-suite tightening audit: extracted out of
// `test/advisor_proxy_test.dart` (8,328 lines) when the original monolith
// was split into five focused files:
//   - advisor_proxy_config_test.dart
//   - advisor_proxy_token_and_guard_test.dart
//   - advisor_proxy_usage_and_migrations_test.dart
//   - advisor_proxy_jwt_verifier_test.dart
//   - advisor_proxy_http_and_admin_routes_test.dart
//
// These helpers (verifier doubles, usage / accounting / cache fakes,
// admin-gateway fakes, HTTP helpers, RSA + JWT fixture builders, auth-session
// ledger doubles, Postgres pool/transaction recorders) were file-private in
// the original monolith. They are promoted to library-public (leading `_`
// dropped, with a handful of generic names like `claims` / `telemetry` /
// `operatorContext` renamed to `defaultProxyClaims` / `defaultProxyTelemetry`
// / `defaultOperatorContext` / `defaultUuidOperatorContext` to avoid
// collisions with the many local-variable usages of `claims` inside the
// migrated tests). Behaviour is byte-identical to the pre-split source.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/advisor_response_cache.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';
import 'package:forge_and_flow/services/business_timing/business_timing_profile_validator.dart';
import 'package:pointycastle/pointycastle.dart' as pc;

import '../tool/advisor_proxy/advisor_proxy.dart';

class FakePricingAdminGateway implements PricingTierAdminProxyGateway {
  List<Map<String, Object?>> listResult = const <Map<String, Object?>>[];
  Map<String, Object?>? tierUpdateResult = <String, Object?>{
    'operator': <String, Object?>{},
    'caps': <Map<String, Object?>>[],
  };
  Map<String, Object?> capUpsertResult = <String, Object?>{};
  Map<String, Object?>? applyTemplateResult = <String, Object?>{
    'operator': <String, Object?>{},
    'caps': <Map<String, Object?>>[],
  };

  bool deleteResult = true;
  List<Map<String, Object?>>? spendSummaryResult = const <Map<String, Object?>>[];

  List<Map<String, Object?>> planCatalogResult = const <Map<String, Object?>>[];
  Map<String, Object?>? planUpdateResult = <String, Object?>{
    'tier_key': 'premium',
    'monthly_usd': 300.0,
    'first_n_seats': 20,
    'first_seat_usd': 6.0,
    'additional_seat_usd': 4.0,
    'onboarding_min_usd': 750.0,
    'onboarding_max_usd': 2000.0,
    'updated_at': '2026-04-30T12:00:00.000Z',
    'updated_by': 'user_admin',
  };

  String? lastReason;
  String? lastActorUserId;
  String? lastTierUpdateOperatorId;
  String? lastTierUpdateValue;
  String? lastCapOperatorId;
  String? lastCapLocationId;
  String? lastCapUsageClass;
  double? lastCapMonthly;
  String? lastApplyTemplateOperatorId;
  String? lastApplyTemplateTierKey;
  Object? raiseOnApplyTemplate;
  String? lastDeleteOperatorId;
  String? lastDeleteCapId;
  String? lastDeleteUsageClass;
  String? lastSpendSummaryOperatorId;
  String? lastPlanUpdateTierKey;
  double? lastPlanUpdateMonthlyUsd;
  int? lastPlanUpdateFirstNSeats;

  @override
  Future<List<Map<String, Object?>>> listOperatorsWithCaps({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    return listResult;
  }

  @override
  Future<Map<String, Object?>?> updateOperatorTier({
    required String actorUserId,
    required String operatorId,
    required String subscriptionTier,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    lastTierUpdateOperatorId = operatorId;
    lastTierUpdateValue = subscriptionTier;
    return tierUpdateResult;
  }

  @override
  Future<Map<String, Object?>> upsertUsageCap({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String usageClass,
    required double monthlyCapUsd,
    required double perInvocationCapUsd,
    String? staffId,
    String? workflowId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    lastCapOperatorId = operatorId;
    lastCapLocationId = locationId;
    lastCapUsageClass = usageClass;
    lastCapMonthly = monthlyCapUsd;
    return capUpsertResult;
  }

  @override
  Future<Map<String, Object?>?> applyTierTemplate({
    required String actorUserId,
    required String operatorId,
    required String tierKey,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    lastApplyTemplateOperatorId = operatorId;
    lastApplyTemplateTierKey = tierKey;
    final raise = raiseOnApplyTemplate;
    if (raise != null) throw raise;
    return applyTemplateResult;
  }

  @override
  Future<bool> deleteUsageCap({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String usageClass,
    String? staffId,
    String? workflowId,
    String? capId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    lastDeleteOperatorId = operatorId;
    lastDeleteCapId = capId;
    lastDeleteUsageClass = usageClass;
    return deleteResult;
  }

  @override
  Future<List<Map<String, Object?>>?> monthToDateSpendSummary({
    required String actorUserId,
    required String operatorId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    lastSpendSummaryOperatorId = operatorId;
    return spendSummaryResult;
  }

  @override
  Future<List<Map<String, Object?>>> listPlanCatalog({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    return planCatalogResult;
  }

  @override
  Future<Map<String, Object?>?> updatePlanPricing({
    required String actorUserId,
    required String tierKey,
    required double? monthlyUsd,
    required int? firstNSeats,
    required double? firstSeatUsd,
    required double? additionalSeatUsd,
    required double? onboardingMinUsd,
    required double? onboardingMaxUsd,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    lastPlanUpdateTierKey = tierKey;
    lastPlanUpdateMonthlyUsd = monthlyUsd;
    lastPlanUpdateFirstNSeats = firstNSeats;
    return planUpdateResult;
  }
}

class FakeAdminGateway implements OperatorLocationAdminProxyGateway {
  List<Map<String, Object?>> listResult = const <Map<String, Object?>>[];
  Map<String, Object?> onboardResult = <String, Object?>{
    'operator': <String, Object?>{},
    'locations': <Map<String, Object?>>[],
  };
  Map<String, Object?>? patchResult = <String, Object?>{'operator_id': 'op'};
  Map<String, Object?>? suspendResult = <String, Object?>{};
  Map<String, Object?>? reactivateResult = <String, Object?>{};
  Map<String, Object?> addLocationResult = <String, Object?>{};
  Object? addLocationError;
  Map<String, Object?>? patchLocationResult = <String, Object?>{};
  AdminLocationRemovalResult removeLocationResult =
      AdminLocationRemovalResult.removed;

  String? lastReason;
  String? lastActorUserId;
  Map<String, Object?>? lastOnboardCommand;
  String? suspendOperatorId;
  String? reactivateOperatorId;
  String? lastAddLocationOperatorId;
  String? lastAddLocationParentOrgUnitId;
  String? lastAddLocationTimezone;
  String? lastPatchLocationId;
  String? lastPatchLocationName;
  String? lastPatchLocationTimezone;
  int? lastPatchLocationRolloverHour;
  String? removeLocationId;

  @override
  Future<List<Map<String, Object?>>> listOperatorsWithLocations({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    return listResult;
  }

  @override
  Future<Map<String, Object?>> onboardOperator({
    required String actorUserId,
    required String businessName,
    required String ownerEmail,
    required String subscriptionTier,
    required String preferredCurrency,
    required String adminUserEmail,
    required String primaryLocationName,
    required String primaryLocationTimezone,
    required int primaryLocationRolloverHour,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    lastOnboardCommand = <String, Object?>{
      'business_name': businessName,
      'owner_email': ownerEmail,
      'subscription_tier': subscriptionTier,
      'preferred_currency': preferredCurrency,
      'admin_user_email': adminUserEmail,
      'primary_location_name': primaryLocationName,
      'primary_location_timezone': primaryLocationTimezone,
      'primary_location_rollover_hour': primaryLocationRolloverHour,
    };
    return onboardResult;
  }

  @override
  Future<Map<String, Object?>?> patchOperator({
    required String actorUserId,
    required String operatorId,
    String? businessName,
    String? ownerEmail,
    String? subscriptionTier,
    String? preferredCurrency,
    String? primaryLocationId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    return patchResult;
  }

  @override
  Future<Map<String, Object?>?> suspendOperator({
    required String actorUserId,
    required String operatorId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    suspendOperatorId = operatorId;
    lastReason = adminReason;
    return suspendResult;
  }

  @override
  Future<Map<String, Object?>?> reactivateOperator({
    required String actorUserId,
    required String operatorId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    reactivateOperatorId = operatorId;
    lastReason = adminReason;
    return reactivateResult;
  }

  @override
  Future<Map<String, Object?>> addLocation({
    required String actorUserId,
    required String operatorId,
    required String parentOrgUnitId,
    required String name,
    required String address,
    required String timezone,
    required int businessDayRolloverHour,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastAddLocationOperatorId = operatorId;
    lastAddLocationParentOrgUnitId = parentOrgUnitId;
    lastAddLocationTimezone = timezone;
    lastReason = adminReason;
    final error = addLocationError;
    if (error != null) throw error;
    return addLocationResult;
  }

  @override
  Future<Map<String, Object?>?> patchLocation({
    required String actorUserId,
    required String locationId,
    String? name,
    String? address,
    String? timezone,
    int? businessDayRolloverHour,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastPatchLocationId = locationId;
    lastPatchLocationName = name;
    lastPatchLocationTimezone = timezone;
    lastPatchLocationRolloverHour = businessDayRolloverHour;
    lastReason = adminReason;
    return patchLocationResult;
  }

  @override
  Future<AdminLocationRemovalResult> removeLocation({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    removeLocationId = locationId;
    lastReason = adminReason;
    return removeLocationResult;
  }
}

// ─── Test helpers ────────────────────────────────────────────────────────────

Map<String, Object?> adminBusinessTimingBody({required String operatorId}) {
  return <String, Object?>{
    'admin_reason': 'B5 dispatcher regression',
    'scopeKind': 'operator',
    'scopeId': operatorId,
    'effectiveAtBusinessDate': '2026-06-01',
    'ianaTimezone': 'America/Toronto',
    'weekStartDay': 'monday',
    'businessDayStartLocal': '04:00',
    'servicePeriods': const <Map<String, Object?>>[
      <String, Object?>{
        'key': 'lunch',
        'label': 'Lunch',
        'startLocal': '11:00',
        'endLocal': '15:00',
      },
      <String, Object?>{
        'key': 'dinner',
        'label': 'Dinner',
        'startLocal': '17:00',
        'endLocal': '22:00',
      },
    ],
  };
}

class FakeAdminBusinessTimingGateway
    implements OperatorBusinessTimingWriteGateway {
  int createCalls = 0;
  int listCalls = 0;
  final Map<String, OperatorBusinessTimingProfileRecord> _records =
      <String, OperatorBusinessTimingProfileRecord>{};

  void seed(String operatorId, String profileId) {
    _records['$operatorId|$profileId'] = _record(
      profileId: profileId,
      scopeKind: 'operator',
      scopeId: operatorId,
    );
  }

  @override
  Future<OperatorBusinessTimingProfileRecord> createProfile({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required ValidatedBusinessTimingProfile validated,
    required String adminReason,
  }) async {
    createCalls += 1;
    final record = _record(
      profileId: 'profile-created',
      scopeKind: validated.scopeKind,
      scopeId: validated.scopeId,
    );
    _records['$operatorId|${record.profileId}'] = record;
    return record;
  }

  @override
  Future<OperatorBusinessTimingProfileRecord?> loadProfile({
    required String operatorId,
    required String profileId,
  }) async {
    return _records['$operatorId|$profileId'];
  }

  @override
  Future<OperatorBusinessTimingResolutionResult> resolveForLocation({
    required String operatorId,
    required String locationId,
    required String businessDate,
    String? actorUserId,
  }) async {
    return OperatorBusinessTimingResolutionResult(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: businessDate,
      ianaTimezone: null,
      candidates: const <OperatorBusinessTimingResolutionCandidate>[],
    );
  }

  @override
  Future<OperatorBusinessTimingResolutionResult> resolveForLocationAsSystem({
    required String operatorId,
    required String locationId,
    required String businessDate,
    required String reason,
  }) async {
    return OperatorBusinessTimingResolutionResult(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: businessDate,
      ianaTimezone: null,
      candidates: const <OperatorBusinessTimingResolutionCandidate>[],
    );
  }

  @override
  Future<List<OperatorBusinessTimingProfileRecord>> listProfiles({
    required String operatorId,
  }) async {
    listCalls += 1;
    return _records.entries
        .where((entry) => entry.key.startsWith('$operatorId|'))
        .map((entry) => entry.value)
        .toList(growable: false);
  }

  @override
  Future<OperatorBusinessTimingProfileRecord> updateProfile({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required String profileId,
    required ValidatedBusinessTimingProfile validated,
    required String adminReason,
  }) async {
    final record = _record(
      profileId: profileId,
      scopeKind: validated.scopeKind,
      scopeId: validated.scopeId,
    );
    _records['$operatorId|$profileId'] = record;
    return record;
  }

  @override
  Future<OperatorBusinessTimingProfileRecord> replaceServicePeriodSet({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required String profileId,
    required List<ValidatedServicePeriod> mergedSet,
    required String eventKind,
    required Map<String, Object?> auditPayload,
    required String adminReason,
  }) async {
    final record =
        _records['$operatorId|$profileId'] ??
        _record(
          profileId: profileId,
          scopeKind: 'operator',
          scopeId: operatorId,
        );
    _records['$operatorId|$profileId'] = record;
    return record;
  }

  OperatorBusinessTimingProfileRecord _record({
    required String profileId,
    required String scopeKind,
    required String scopeId,
  }) {
    return OperatorBusinessTimingProfileRecord(
      profileId: profileId,
      scopeKind: scopeKind,
      scopeId: scopeId,
      effectiveAtBusinessDate: '2026-06-01',
      ianaTimezone: 'America/Toronto',
      weekStartDay: 'monday',
      businessDayStartLocal: '04:00',
      servicePeriods: const <OperatorBusinessTimingServicePeriodRecord>[
        OperatorBusinessTimingServicePeriodRecord(
          key: 'lunch',
          label: 'Lunch',
          startLocal: '11:00',
          endLocal: '15:00',
          rollsPastMidnight: false,
        ),
      ],
      createdAt: DateTime.utc(2026, 5, 13),
      updatedAt: DateTime.utc(2026, 5, 13),
    );
  }
}

class RecordingAdminBusinessTimingAuditSink implements OperatorWriteAuditSink {
  final List<Map<String, Object?>> records = <Map<String, Object?>>[];

  @override
  Future<void> record({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String eventKind,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
  }) async {
    records.add(<String, Object?>{
      'operator_id': operatorId,
      'actor_user_id': actorUserId,
      'actor_kind': actorKind,
      'event_kind': eventKind,
      'admin_reason': payload['admin_reason'],
      'occurred_at': occurredAt.toUtc().toIso8601String(),
    });
  }
}

class AlwaysOkVerifier implements ProxyJwtVerifier {
  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    return const ProxyJwtClaims(
      userId: 'user_ok',
      operatorId: 'op_ok',
      locationId: 'loc_ok',
      roles: <String>[],
    );
  }
}

class RaisingVerifier implements ProxyJwtVerifier {
  RaisingVerifier(this.message);

  final String message;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    throw ProxyJwtVerificationError(message);
  }
}

class FixedClaimsVerifier implements ProxyJwtVerifier {
  FixedClaimsVerifier(this.claims);

  final ProxyJwtClaims claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async => claims;
}

/// Mutable verifier the HTTP scaffold tests reconfigure between calls.
class SettableVerifier implements ProxyJwtVerifier {
  ProxyJwtClaims? claims;
  String? errorMessage;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final error = errorMessage;
    if (error != null) {
      throw ProxyJwtVerificationError(error);
    }
    final value = claims;
    if (value != null) return value;
    throw ProxyJwtVerificationError('test verifier not configured');
  }
}

class RecordingFirebaseAdminAuthClient implements FirebaseAdminAuthClient {
  final List<String> revokedRefreshTokenUids = <String>[];
  final List<String> deletedUids = <String>[];

  @override
  Future<void> createUser({
    required String uid,
    required String email,
    required Map<String, Object?> customClaims,
  }) async {}

  @override
  Future<void> setCustomClaims({
    required String uid,
    required Map<String, Object?> customClaims,
  }) async {}

  @override
  Future<void> setDisabled({
    required String uid,
    required bool disabled,
  }) async {}

  @override
  Future<void> deleteUser({required String uid}) async {
    deletedUids.add(uid);
  }

  @override
  Future<void> updateUser({
    required String uid,
    String? email,
    String? displayName,
  }) async {}

  @override
  Future<void> sendPasswordResetEmail({
    required String email,
    String? continueUrl,
  }) async {}

  @override
  Future<bool> verifyPassword({
    required String email,
    required String password,
    required String expectedUid,
  }) async {
    return true;
  }

  @override
  Future<void> updatePassword({
    required String uid,
    required String password,
  }) async {}

  @override
  Future<FirebasePasswordResetCodeInfo> verifyPasswordResetCode({
    required String oobCode,
  }) async {
    return const FirebasePasswordResetCodeInfo(email: 'owner@example.com');
  }

  @override
  Future<void> confirmPasswordReset({
    required String oobCode,
    required String newPassword,
  }) async {}

  @override
  Future<void> revokeRefreshTokens({required String uid}) async {
    revokedRefreshTokenUids.add(uid);
  }

  @override
  Future<void> clearMfaEnrollments({required String uid}) async {}
}

/// Counter store fake that records read/write call counts so tests
/// can assert "refused before the store was queried."
class RecordingProxyUsageStore implements ProxyUsageCounterStore {
  int currentUsageCalls = 0;
  int incrementCalls = 0;

  @override
  Future<UsageSnapshot> currentUsage({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
  }) async {
    currentUsageCalls += 1;
    return UsageSnapshot(
      requestsThisMinute: 0,
      costCentsThisMonth: 0,
      minuteBucketStart: now,
      monthBucketStart: DateTime.utc(now.year, now.month),
    );
  }

  @override
  Future<void> incrementOnAllow({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
    required int costCentsToAdd,
  }) async {
    incrementCalls += 1;
  }
}

/// Counter store fake that throws a non-StateError exception on
/// every read. Models real-world failure modes (timeout, network,
/// postgres exception, parse error) where the raw payload may carry
/// secrets / connection strings / stack-trace fragments that the
/// proxy must not surface through the HTTP response.
class BoomProxyUsageStore implements ProxyUsageCounterStore {
  BoomProxyUsageStore({required this.error});

  final Object error;

  @override
  Future<UsageSnapshot> currentUsage({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
  }) async {
    throw error;
  }

  @override
  Future<void> incrementOnAllow({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
    required int costCentsToAdd,
  }) async {
    throw error;
  }
}

/// Counter store fake that returns a fixed snapshot so tests can
/// pin the per-minute / monthly cap edges.
class FixedSnapshotProxyUsageStore implements ProxyUsageCounterStore {
  FixedSnapshotProxyUsageStore({required this.snapshot});

  final UsageSnapshot snapshot;

  @override
  Future<UsageSnapshot> currentUsage({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
  }) async => snapshot;

  @override
  Future<void> incrementOnAllow({
    required String operatorId,
    required String locationId,
    required String tierId,
    required DateTime now,
    required int costCentsToAdd,
  }) async {
    /* no-op */
  }
}

class FixedHealthStore implements ProxyHealthCheckStore {
  const FixedHealthStore(this.status);

  final ProxyHealthStatus status;

  @override
  Future<ProxyHealthStatus> check() async => status;
}

class RecordingLlmProvider implements ProxyLlmProvider {
  int completeCalls = 0;
  ProxyLlmRequest? lastRequest;

  @override
  Future<ProxyLlmCompletion> complete(ProxyLlmRequest request) async {
    completeCalls += 1;
    lastRequest = request;
    return ProxyLlmCompletion(
      text: 'fake advisor answer',
      modelId: request.modelId,
      tier: request.tier,
      outputTokens: 12,
      costCents: 1,
    );
  }
}

class InMemoryAccountingStore implements ProxyAccountingStore {
  InMemoryAccountingStore({required ProxyCapStatus capStatus})
    : _monthlyCapCents = capStatus.monthlyCapCents,
      _monthlyUsedCents = capStatus.monthlyUsedCents,
      _perInvocationCapCents = capStatus.perInvocationCapCents;

  factory InMemoryAccountingStore.open() => InMemoryAccountingStore(
    capStatus: const ProxyCapStatus(
      usageClass: 'advisor_qa',
      monthlyCapCents: 5000,
      monthlyUsedCents: 0,
      perInvocationCapCents: 500,
      estimatedCostCents: 1,
    ),
  );

  final int _monthlyCapCents;
  int _monthlyUsedCents;
  final int _perInvocationCapCents;
  final Map<String, Map<String, Object?>> _responses =
      <String, Map<String, Object?>>{};

  int startCalls = 0;
  int completeCalls = 0;

  int get monthlyUsedCents => _monthlyUsedCents;

  @override
  Future<ProxyAccountingStartResult> startRequest({
    required String idempotencyKey,
    required String requestType,
    required OperatorContext operator,
    required String usageClass,
    required ProxyUsageTelemetry telemetry,
    required ProxyUsageChargeEstimate estimate,
    required DateTime now,
  }) async {
    startCalls += 1;
    final existing = _responses[idempotencyKey];
    if (existing != null) {
      return ProxyAccountingReplayed(responsePayload: existing);
    }

    final status = ProxyCapStatus(
      usageClass: usageClass,
      monthlyCapCents: _monthlyCapCents,
      monthlyUsedCents: _monthlyUsedCents,
      perInvocationCapCents: _perInvocationCapCents,
      estimatedCostCents: estimate.costCents,
    );
    if (!status.allowed) {
      return ProxyAccountingRefused(capStatus: status);
    }

    _monthlyUsedCents += estimate.costCents;
    // Mirror the real store: the reservation surfaces the proxy_requests
    // trace `request_id` so completeRequest can correlate the stats row.
    // Deterministic synthetic uuid keyed off the reservation order so
    // tests can assert the value flows through to ProxyRequestStats.
    final reservedRequestId = reservedRequestIds.putIfAbsent(
      idempotencyKey,
      () =>
          'aaaaaaaa-aaaa-4aaa-8aaa-'
          '${startCalls.toString().padLeft(12, '0')}',
    );
    return ProxyAccountingReserved(
      capStatus: status,
      requestId: reservedRequestId,
    );
  }

  /// Synthetic reservation request ids, keyed by idempotency key, so a
  /// retry resolves the same correlation id the first reservation minted.
  final Map<String, String> reservedRequestIds = <String, String>{};

  int commitCalls = 0;
  ProxyUsageTelemetry? lastCommittedTelemetry;
  int? lastCommittedTokenCount;
  int? lastCommittedCostCents;

  @override
  Future<void> commitUsageLog({
    required OperatorContext operator,
    required String usageClass,
    required ProxyUsageTelemetry telemetry,
    required ProxyUsageChargeEstimate estimate,
    required DateTime now,
  }) async {
    commitCalls += 1;
    lastCommittedTelemetry = telemetry;
    lastCommittedTokenCount = estimate.tokenCount;
    lastCommittedCostCents = estimate.costCents;
  }

  /// P1b — the last `proxy_request_stats` payload completeRequest was
  /// handed, so tests can assert the measured latency / real status /
  /// actor / model / token / cost without a live Postgres. Stays null
  /// when the route does not pass stats (e.g. an idempotency replay never
  /// reaches completeRequest).
  ProxyRequestStats? lastStats;
  final List<ProxyRequestStats> recordedStats = <ProxyRequestStats>[];

  @override
  Future<void> completeRequest({
    required OperatorContext operator,
    required String idempotencyKey,
    required Map<String, Object?> responsePayload,
    required DateTime now,
    ProxyRequestStats? stats,
  }) async {
    completeCalls += 1;
    _responses[idempotencyKey] = Map<String, Object?>.from(responsePayload);
    if (stats != null) {
      lastStats = stats;
      recordedStats.add(stats);
    }
  }
}

class StaticHitAdvisorCache implements AdvisorResponseCache {
  const StaticHitAdvisorCache(this.answer);
  final String answer;

  @override
  Future<String?> lookup({
    required String operatorId,
    required String locationId,
    required String queryClass,
    required String questionHash,
    required String corpusVersion,
  }) async => answer;
}

OperatorContext defaultOperatorContext() => const OperatorContext(
  userId: 'user_x',
  operatorId: 'op_777',
  locationId: 'loc_999',
  roles: <String>['advisor.read'],
);

OperatorContext defaultUuidOperatorContext() => const OperatorContext(
  userId: '11111111-1111-4111-8111-111111111111',
  operatorId: '22222222-2222-4222-8222-222222222222',
  locationId: '33333333-3333-4333-8333-333333333333',
  roles: <String>['advisor.read'],
);

ProxyJwtClaims defaultProxyClaims() => const ProxyJwtClaims(
  userId: 'user_x',
  operatorId: 'op_777',
  locationId: 'loc_999',
  roles: <String>['advisor.read'],
);

/// UUID-shaped variant of [defaultProxyClaims] for paths that assert the
/// scope flows into a uuid column (e.g. proxy_request_stats.actor_user_id).
ProxyJwtClaims defaultUuidProxyClaims() => const ProxyJwtClaims(
  userId: '11111111-1111-4111-8111-111111111111',
  operatorId: '22222222-2222-4222-8222-222222222222',
  locationId: '33333333-3333-4333-8333-333333333333',
  roles: <String>['advisor.read'],
);

ProxyUsageTelemetry defaultProxyTelemetry() => const ProxyUsageTelemetry(
  queryClass: 'methodology_lookup',
  cacheHit: false,
  llmTier: 'haiku',
  modelUsed: 'claude-haiku-4-5',
);

class PostgresSqlCall {
  const PostgresSqlCall(this.sql, this.parameters);

  final String sql;
  final PostgresParameters parameters;
}

class AccountingPostgresPool implements PostgresPool {
  final transactions = <AccountingPostgresTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = AccountingPostgresTransaction();
    transactions.add(tx);
    return tx;
  }
}

class AccountingPostgresTransaction implements PostgresTransaction {
  final executedSql = <String>[];
  final executeCalls = <PostgresSqlCall>[];
  final queryCalls = <PostgresSqlCall>[];
  var committed = false;
  var rolledBack = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    queryCalls.add(PostgresSqlCall(sql, parameters));
    if (sql.contains('select response_payload') &&
        sql.contains('from public.proxy_requests')) {
      return const <PostgresRow>[];
    }
    if (sql.contains('from public.usage_caps')) {
      return const <PostgresRow>[
        <String, Object?>{
          'monthly_cap_usd': '10.00',
          'monthly_used_usd': '1.25',
          'per_invocation_cap_usd': '2.00',
        },
      ];
    }
    if (sql.contains('insert into public.proxy_requests')) {
      return const <PostgresRow>[
        <String, Object?>{
          'request_id': '44444444-4444-4444-8444-444444444444',
          'response_payload': null,
        },
      ];
    }
    if (sql.contains('insert into public.usage_logs')) {
      return const <PostgresRow>[
        <String, Object?>{
          'token_count': 123,
          'cost_usd': '0.2500',
          'request_count': 1,
        },
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    executedSql.add(sql);
    executeCalls.add(PostgresSqlCall(sql, parameters));
    return 1;
  }

  @override
  Future<void> commit() async {
    committed = true;
  }

  @override
  Future<void> rollback() async {
    rolledBack = true;
  }
}

class HttpResponseSnapshot {
  HttpResponseSnapshot({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

Future<HttpResponseSnapshot> httpGet(
  HttpClient client,
  Uri uri, {
  String? authorization,
  Map<String, String>? headers,
}) async {
  final request = await client.getUrl(uri);
  // Disable connection reuse so a per-test HttpClient never picks up
  // a half-open connection targeting a previously-bound server port.
  request.persistentConnection = false;
  if (authorization != null) {
    request.headers.set(HttpHeaders.authorizationHeader, authorization);
  }
  headers?.forEach(request.headers.set);
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  return HttpResponseSnapshot(statusCode: response.statusCode, body: body);
}

/// POST helper for the Phase 9 B6 auth-session endpoint tests. Sends
/// [body] as JSON when supplied, or an empty body when [body] is null
/// (used by the /revoke-all "default reason" test).
Future<HttpResponseSnapshot> httpPost(
  HttpClient client,
  Uri uri, {
  String? authorization,
  Map<String, Object?>? body,
  Map<String, String>? headers,
}) async {
  final request = await client.postUrl(uri);
  request.persistentConnection = false;
  request.headers.contentType = ContentType.json;
  if (authorization != null) {
    request.headers.set(HttpHeaders.authorizationHeader, authorization);
  }
  headers?.forEach(request.headers.set);
  if (body != null) {
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
  } else {
    request.contentLength = 0;
  }
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}

/// Generic JSON helper used by the 11A.1 admin-route tests. Handles
/// arbitrary HTTP methods (POST / PATCH / DELETE) with an optional
/// JSON body.
Future<HttpResponseSnapshot> httpJson(
  HttpClient client,
  String method,
  Uri uri, {
  String? authorization,
  String? idempotencyKey,
  Map<String, Object?>? body,
}) async {
  final request = await client.openUrl(method, uri);
  request.persistentConnection = false;
  if (authorization != null) {
    request.headers.set(HttpHeaders.authorizationHeader, authorization);
  }
  if (idempotencyKey != null) {
    request.headers.set('Idempotency-Key', idempotencyKey);
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
  } else {
    request.contentLength = 0;
  }
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}

// ─── 9.1 — Firebase verifier test helpers ────────────────────────────────────

pc.RSAPublicKey rsaFixturePublicKey() => pc.RSAPublicKey(
  BigInt.parse(
    '20620915813302906913761247666337410938401372343750709187749515126790853245302593205328533062154315527282056175455193812046134139935830222032257750866653461677566720508752544506266533943725970345491747964654489405936145559121373664620352701801574863309087932865304205561439525871868738640172656811470047745445089832193075388387376667722031640892525639171016297098395245887609359882693921643396724693523583076582208970794545581164952427577506035951122669158313095779596666008591745562008787129160302313244329988240795948461701615228062848622019620094307696506764461083870202605984497833670577046553861732258592935325691',
  ),
  BigInt.parse('65537'),
);

pc.RSAPrivateKey rsaFixturePrivateKey() => pc.RSAPrivateKey(
  BigInt.parse(
    '20620915813302906913761247666337410938401372343750709187749515126790853245302593205328533062154315527282056175455193812046134139935830222032257750866653461677566720508752544506266533943725970345491747964654489405936145559121373664620352701801574863309087932865304205561439525871868738640172656811470047745445089832193075388387376667722031640892525639171016297098395245887609359882693921643396724693523583076582208970794545581164952427577506035951122669158313095779596666008591745562008787129160302313244329988240795948461701615228062848622019620094307696506764461083870202605984497833670577046553861732258592935325691',
  ),
  BigInt.parse(
    '11998058528661160053642124235359844880039079149364512302169225182946866898849176558365314596732660324493329967536772364327680348872134489319530228055102152992797567579226269544119435926913937183793755182388650533700918602627770886358900914370472445911502526145837923104029967812779021649252540542517598618021899291933220000807916271555680217608559770825469218984818060775562259820009637370696396889812317991880425127772801187664191059506258517954313903362361211485802288635947903604738301101038823790599295749578655834195416886345569976295245464597506584866355976650830539380175531900288933412328525689718517239330305',
  ),
  BigInt.parse(
    '144173682842817587002196172066264549138375068078359231382946906898412792452632726597279520229873489736777248181678202636100459215718497240474064366927544074501134727745837254834206456400508719134610847814227274992298238973375146473350157304285346424982280927848339601514720098577525635486320547905945936448443',
  ),
  BigInt.parse(
    '143028293421514654659358549214971921584534096938352096320458818956414890934365483375293202045679474764569937266017713262196941957149321696805368542065644090886347646782188634885321277533175667840285448510687854061424867903968633218073060468434469761149335255007464091258725753837522484082998329871306803923137',
  ),
);

Uint8List signRs256(Uint8List message, pc.RSAPrivateKey privateKey) {
  final random = pc.SecureRandom('Fortuna')
    ..seed(pc.KeyParameter(Uint8List.fromList(List<int>.filled(32, 7))));
  final signer = pc.Signer('SHA-256/RSA')
    ..init(
      true,
      pc.ParametersWithRandom(
        pc.PrivateKeyParameter<pc.RSAPrivateKey>(privateKey),
        random,
      ),
    );
  return (signer.generateSignature(message) as pc.RSASignature).bytes;
}

String rsaFixtureCertificatePem() {
  final publicKey = rsaFixturePublicKey();
  final rsaAlgorithm = pc.ASN1Sequence(
    elements: <pc.ASN1Object>[
      pc.ASN1ObjectIdentifier(<int>[1, 2, 840, 113549, 1, 1, 1]),
      pc.ASN1Null(),
    ],
  );
  final rsaPublicKey = pc.ASN1Sequence(
    elements: <pc.ASN1Object>[
      pc.ASN1Integer(publicKey.modulus),
      pc.ASN1Integer(publicKey.publicExponent),
    ],
  ).encode();
  final subjectPublicKeyInfo = pc.ASN1Sequence(
    elements: <pc.ASN1Object>[
      rsaAlgorithm,
      pc.ASN1BitString(stringValues: rsaPublicKey),
    ],
  );
  final tbsCertificate = pc.ASN1Sequence(
    elements: <pc.ASN1Object>[
      pc.ASN1Integer(BigInt.one),
      rsaAlgorithm,
      pc.ASN1Sequence(elements: <pc.ASN1Object>[]),
      pc.ASN1Sequence(elements: <pc.ASN1Object>[]),
      pc.ASN1Sequence(elements: <pc.ASN1Object>[]),
      subjectPublicKeyInfo,
    ],
  );
  final certificate = pc.ASN1Sequence(
    elements: <pc.ASN1Object>[
      tbsCertificate,
      rsaAlgorithm,
      pc.ASN1BitString(stringValues: <int>[0]),
    ],
  ).encode();
  return pemBlock('CERTIFICATE', certificate);
}

String pemBlock(String label, Uint8List bytes) {
  final encoded = base64Encode(bytes);
  final lines = <String>[];
  for (var i = 0; i < encoded.length; i += 64) {
    final end = i + 64 > encoded.length ? encoded.length : i + 64;
    lines.add(encoded.substring(i, end));
  }
  return '-----BEGIN $label-----\n'
      '${lines.join('\n')}\n'
      '-----END $label-----';
}

class FixedJwksKeySource implements JwksKeySource {
  FixedJwksKeySource(this._keys);

  final Map<String, JwtKeyMaterial> _keys;

  @override
  Future<JwtKeyMaterial?> publicKeyFor(String kid) async => _keys[kid];
}

class AlwaysAcceptRs256Validator implements JwtRs256SignatureValidator {
  const AlwaysAcceptRs256Validator();

  @override
  bool verify({
    required Uint8List signedInput,
    required Uint8List signature,
    required JwtKeyMaterial keyMaterial,
  }) {
    return true;
  }
}

class AlwaysRejectRs256Validator implements JwtRs256SignatureValidator {
  const AlwaysRejectRs256Validator();

  @override
  bool verify({
    required Uint8List signedInput,
    required Uint8List signature,
    required JwtKeyMaterial keyMaterial,
  }) {
    return false;
  }
}

class BoomRs256Validator implements JwtRs256SignatureValidator {
  const BoomRs256Validator();

  @override
  bool verify({
    required Uint8List signedInput,
    required Uint8List signature,
    required JwtKeyMaterial keyMaterial,
  }) {
    throw FormatException('placeholder format failure');
  }
}

/// Builds a test Firebase ID token (header.payload.signature) using
/// raw base64url encoding. The signature segment is a placeholder
/// non-empty value because tests inject a [JwtRs256SignatureValidator]
/// that does not actually inspect the bytes.
String firebaseTestToken({
  String kid = 'kid-good',
  String? algOverride,
  String projectId = 'forge-flow-staging',
  String? issuerOverride,
  Object? audienceOverride,
  String sub = 'user_abc',
  String? operatorId = 'op_777',
  String? locationId = 'loc_999',
  bool isSuperAdmin = false,
  bool isFfSupport = false,
  int? rolesVersion,
  required DateTime issuedAt,
  required DateTime expiresAt,
  DateTime? authTime,
}) {
  final headerJson = <String, Object?>{
    'alg': algOverride ?? 'RS256',
    if (kid.isNotEmpty) 'kid': kid,
    'typ': 'JWT',
  };
  final payloadJson = <String, Object?>{
    'iss': issuerOverride ?? 'https://securetoken.google.com/$projectId',
    'aud': audienceOverride ?? projectId,
    if (sub.isNotEmpty) 'sub': sub,
    'iat': issuedAt.toUtc().millisecondsSinceEpoch ~/ 1000,
    'exp': expiresAt.toUtc().millisecondsSinceEpoch ~/ 1000,
    if (authTime != null)
      'auth_time': authTime.toUtc().millisecondsSinceEpoch ~/ 1000,
    if (operatorId != null) 'operator_id': operatorId,
    if (locationId != null) 'location_id': locationId,
    if (isSuperAdmin) 'is_super_admin': true,
    if (isFfSupport) 'is_ff_support': true,
    if (rolesVersion != null) 'roles_version': rolesVersion,
  };
  final headerSegment = base64UrlEncodeJson(headerJson);
  final payloadSegment = base64UrlEncodeJson(payloadJson);
  // Signature segment: placeholder non-empty bytes — the test
  // signature validator never inspects them.
  final signatureSegment = base64Url
      .encode(<int>[0x01, 0x02, 0x03, 0x04])
      .replaceAll('=', '');
  return '$headerSegment.$payloadSegment.$signatureSegment';
}

String base64UrlEncodeJson(Map<String, Object?> data) {
  final bytes = utf8.encode(jsonEncode(data));
  return base64Url.encode(bytes).replaceAll('=', '');
}

Future<void> expectVerifierError(
  Future<ProxyJwtClaims> future,
  Matcher messageMatcher,
) async {
  ProxyJwtVerificationError? thrown;
  try {
    await future;
  } on ProxyJwtVerificationError catch (error) {
    thrown = error;
  }
  expect(
    thrown,
    isNotNull,
    reason: 'expected ProxyJwtVerificationError but verify() returned',
  );
  expect(thrown!.message, messageMatcher);
}

// ─── Phase 9 B6 — auth-session ledger test fakes ─────────────────────

/// Records every call into the writer so route tests can assert what
/// the proxy delegated. Login responses carry a queued list of
/// session_ids so a single fake can drive multiple sequential logins.
class RecordingAuthSessionLedger implements AuthSessionLedgerWriter {
  RecordingAuthSessionLedger({
    List<String>? loginSessionIds,
    int revokeAllReturnCount = 0,
  }) : _loginSessionIds = List<String>.from(
         loginSessionIds ?? const <String>['session-test-default'],
       ),
       _revokeAllReturnCount = revokeAllReturnCount;

  final List<String> _loginSessionIds;
  final int _revokeAllReturnCount;

  final List<AuthSessionLedgerLogin> logins = <AuthSessionLedgerLogin>[];
  final List<
    ({String sessionId, String userId, String operatorId, String locationId})
  >
  refreshes =
      <
        ({
          String sessionId,
          String userId,
          String operatorId,
          String locationId,
        })
      >[];
  final List<
    ({
      String sessionId,
      String userId,
      String operatorId,
      String locationId,
      String reason,
    })
  >
  revokes =
      <
        ({
          String sessionId,
          String userId,
          String operatorId,
          String locationId,
          String reason,
        })
      >[];
  final List<
    ({String userId, String operatorId, String locationId, String reason})
  >
  revokeAlls =
      <
        ({String userId, String operatorId, String locationId, String reason})
      >[];

  @override
  Future<String> recordLogin(AuthSessionLedgerLogin login) async {
    logins.add(login);
    if (_loginSessionIds.isEmpty) return 'session-test-default';
    return _loginSessionIds.removeAt(0);
  }

  @override
  Future<void> recordRefresh({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
  }) async {
    refreshes.add((
      sessionId: sessionId,
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
    ));
  }

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    revokes.add((
      sessionId: sessionId,
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
      reason: reason,
    ));
  }

  @override
  Future<int> revokeAllSessionsForUser({
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    revokeAlls.add((
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
      reason: reason,
    ));
    return _revokeAllReturnCount;
  }
}

/// Throws [error] from every method. Lets the route tests assert that
/// the proxy NEVER lets a writer's raw exception text leak into the
/// HTTP response (defense-in-depth for connection strings, secrets,
/// or stack-trace fragments that real Postgres errors can carry).
class ThrowingAuthSessionLedger implements AuthSessionLedgerWriter {
  ThrowingAuthSessionLedger({required this.error});

  final Object error;

  @override
  Future<String> recordLogin(AuthSessionLedgerLogin login) async {
    throw error;
  }

  @override
  Future<void> recordRefresh({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
  }) async {
    throw error;
  }

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    throw error;
  }

  @override
  Future<int> revokeAllSessionsForUser({
    required String userId,
    required String operatorId,
    required String locationId,
    required String reason,
  }) async {
    throw error;
  }
}
