// Phase 11W.7 / Wave A2 - repository-backed implementations of the
// operator-scoped write gateways the proxy router consumes.
//
// Production wiring:
//   * RepositoryOperatorAccountWriteGateway -> OperatorAccountRepository
//     -> public.operators
//   * RepositoryOperatorBusinessTimingWriteGateway ->
//     BusinessTimingProfilesRepository -> public.business_timing_*
//
// The proxy router (`OperatorWriteRouter` in
// tool/advisor_proxy/operator_routes.dart) keeps the HTTP envelope
// shape and the audit log; these gateways do the SQL and re-shape
// the resulting rows into the wire records the router writes.

import '../../infrastructure/persistence/postgres/repositories/business_timing_profiles_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/operator_account_repository.dart';
import 'business_timing_profile_validator.dart';
import 'operator_write_contracts.dart';

class RepositoryOperatorAccountWriteGateway
    implements OperatorAccountWriteGateway {
  RepositoryOperatorAccountWriteGateway({
    required OperatorAccountRepository repository,
  }) : _repository = repository;

  final OperatorAccountRepository _repository;

  @override
  Future<OperatorAccountRecord> patchAccount({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required ValidatedOperatorAccountPatch patch,
    required String adminReason,
  }) async {
    final row = await _repository.patch(
      operatorId: operatorId,
      // operators is identity-only; locationId is the SET LOCAL
      // sentinel and is not used by the operators table itself.
      locationId: operatorId,
      columnFields: patch.fields,
      userId: actorUserId,
    );
    if (row == null) {
      throw const OperatorWriteRejected(
        code: 'operator_not_found',
        message: 'operator row was not found',
        statusCode: 404,
      );
    }
    return _accountRecord(row);
  }

  @override
  Future<OperatorAccountRecord?> loadAccount({
    required String operatorId,
  }) async {
    final row = await _repository.load(
      operatorId: operatorId,
      // operators is identity-only; locationId is the SET LOCAL
      // sentinel that satisfies the UUID validator. Use operatorId.
      locationId: operatorId,
    );
    if (row == null) return null;
    return _accountRecord(row);
  }

  static OperatorAccountRecord _accountRecord(OperatorAccountRow row) {
    return OperatorAccountRecord(
      operatorId: row.operatorId,
      businessName: row.businessName,
      logoUrl: row.logoUrl,
      currencyCode: row.currencyCode,
      localeTag: row.localeTag,
      weekStartDay: row.weekStartDay,
      rolloverHour: row.rolloverHour,
      updatedAt: row.updatedAt,
    );
  }
}

class RepositoryOperatorBusinessTimingWriteGateway
    implements OperatorBusinessTimingWriteGateway {
  RepositoryOperatorBusinessTimingWriteGateway({
    required BusinessTimingProfilesRepository repository,
  }) : _repository = repository;

  final BusinessTimingProfilesRepository _repository;

  @override
  Future<OperatorBusinessTimingProfileRecord> createProfile({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required ValidatedBusinessTimingProfile validated,
    required String adminReason,
  }) async {
    // The repository requires a locationId for tenant context; for
    // operator-scope writes there is no location, so pass operatorId
    // as a sentinel that satisfies the SET LOCAL contract without
    // narrowing RLS for cross-location reads.
    final row = await _repository.createProfile(
      operatorId: operatorId,
      locationId: operatorId,
      scopeType: validated.scopeKind,
      scopeId: validated.scopeId,
      businessDayStartLocalTime: validated.businessDayStartLocal,
      weekStartDay: validated.weekStartDayInt,
      // Default close authority for operator-web first-time profile
      // creation. Future surfaces can extend the validator to accept
      // this on the wire.
      closeAuthority: 'vendor_finalization',
      effectiveFromBusinessDate: validated.effectiveAtBusinessDate,
      actorUserId: actorUserId,
      reason: adminReason,
      idempotencyKey: idempotencyKey,
      servicePeriods: <BusinessTimingServicePeriodWrite>[
        for (var i = 0; i < validated.servicePeriods.length; i++)
          _toServicePeriodWrite(validated.servicePeriods[i], i + 1),
      ],
    );
    return _toRecord(row);
  }

  @override
  Future<OperatorBusinessTimingProfileRecord?> loadProfile({
    required String operatorId,
    required String profileId,
  }) async {
    final row = await _repository.loadProfileById(
      operatorId: operatorId,
      locationId: operatorId,
      profileId: profileId,
    );
    if (row == null) return null;
    return _toRecord(row);
  }

  @override
  Future<OperatorBusinessTimingResolutionResult> resolveForLocation({
    required String operatorId,
    required String locationId,
    required String businessDate,
    String? actorUserId,
  }) async {
    // Canonical chain — do NOT fork. `listCandidateProfilesForLocation`
    // runs the ltree ancestor CTE and returns the candidates already
    // ordered `scope_depth asc` (operator default first, location
    // override last) with `locations.timezone` and the FULL service-
    // period fields (`short_label` / `sort_order` /
    // `applicable_weekdays`). The client runs the one pure
    // `BusinessTimingProfileResolver` over these rows.
    final rows = await _repository.listCandidateProfilesForLocation(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: businessDate,
    );
    final candidates = <OperatorBusinessTimingResolutionCandidate>[
      for (var i = 0; i < rows.length; i++)
        _toResolutionCandidate(rows[i], scopeDepthRank: i),
    ];
    // `locations.timezone` is denormalised onto every candidate row by
    // the CTE; surface it once at the top level too so the resolver
    // has a timezone even when zero candidates override it.
    final String? locationTimezone = rows.isEmpty
        ? null
        : rows.first.locationTimezone;
    return OperatorBusinessTimingResolutionResult(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: businessDate,
      ianaTimezone: locationTimezone,
      candidates: candidates,
    );
  }

  @override
  Future<OperatorBusinessTimingResolutionResult> resolveForLocationAsSystem({
    required String operatorId,
    required String locationId,
    required String businessDate,
    required String reason,
  }) async {
    // Fix #4 / S2 — admin/cross-tenant analogue of [resolveForLocation].
    // Same canonical chain, same candidate mapping, same response
    // shape; the ONLY difference is the repository entry point:
    // `listCandidateProfilesForSystemLocation` runs the byte-identical
    // canonical SQL over the sanctioned `runAsSystem` admin bypass so
    // an F&F admin can read another operator's chain. No resolver
    // fork — the admin client runs the one pure
    // `BusinessTimingProfileResolver` exactly like S1. Read-only.
    final rows = await _repository.listCandidateProfilesForSystemLocation(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: businessDate,
      reason: reason,
    );
    final candidates = <OperatorBusinessTimingResolutionCandidate>[
      for (var i = 0; i < rows.length; i++)
        _toResolutionCandidate(rows[i], scopeDepthRank: i),
    ];
    final String? locationTimezone = rows.isEmpty
        ? null
        : rows.first.locationTimezone;
    return OperatorBusinessTimingResolutionResult(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: businessDate,
      ianaTimezone: locationTimezone,
      candidates: candidates,
    );
  }

  OperatorBusinessTimingResolutionCandidate _toResolutionCandidate(
    BusinessTimingProfileRow row, {
    required int scopeDepthRank,
  }) {
    return OperatorBusinessTimingResolutionCandidate(
      profileId: row.profileId,
      scopeType: row.scopeType,
      scopeId: row.scopeId,
      scopeLabel: _scopeLabel(row),
      scopeDepthRank: scopeDepthRank,
      ianaTimezone: row.locationTimezone ?? 'UTC',
      effectiveAtBusinessDate: row.effectiveFromBusinessDate,
      weekStartDay: _weekStartIntToString(row.weekStartDay),
      businessDayStartLocal: row.businessDayStartLocalTime,
      servicePeriods: <OperatorBusinessTimingServicePeriodRecord>[
        for (final period in row.servicePeriods)
          _toServicePeriodRecord(period),
      ],
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  /// Human label for an inheritance rung. The profile's own
  /// `display_name` when the operator set one, else a stable
  /// scope-kind fallback. Never blank so the operator-web inheritance
  /// chrome (S3) can render real rungs instead of faking labels. The
  /// `org_units.name` / `locations.name` join is intentionally NOT
  /// added here: that would require touching the canonical repository
  /// CTE (out of S1 scope) — S3 already has the org-unit tree from
  /// its existing hierarchy bundle and only needs the scope id +
  /// kind + a non-blank label to bind the rung.
  static String _scopeLabel(BusinessTimingProfileRow row) {
    final displayName = row.displayName?.trim();
    if (displayName != null && displayName.isNotEmpty) return displayName;
    switch (row.scopeType) {
      case 'operator':
        return 'Operator default';
      case 'org_unit':
        return 'Org unit';
      case 'location':
        return 'Location override';
    }
    return row.scopeType;
  }

  @override
  Future<List<OperatorBusinessTimingProfileRecord>> listProfiles({
    required String operatorId,
  }) async {
    final rows = await _repository.listProfilesForOperator(
      operatorId: operatorId,
    );
    return <OperatorBusinessTimingProfileRecord>[
      for (final row in rows) _toRecord(row),
    ];
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
    final row = await _repository.updateProfile(
      operatorId: operatorId,
      locationId: operatorId,
      profileId: profileId,
      businessDayStartLocalTime: validated.businessDayStartLocal,
      weekStartDay: validated.weekStartDayInt,
      effectiveFromBusinessDate: validated.effectiveAtBusinessDate,
      actorUserId: actorUserId,
      reason: adminReason,
      idempotencyKey: idempotencyKey,
    );
    if (row == null) {
      throw const OperatorWriteRejected(
        code: 'profile_not_found',
        message: 'business timing profile was not found',
        statusCode: 404,
      );
    }
    // Replace the whole period set if the validator produced one.
    final replaced = await _repository.replaceServicePeriods(
      operatorId: operatorId,
      locationId: operatorId,
      profileId: profileId,
      servicePeriods: <BusinessTimingServicePeriodWrite>[
        for (var i = 0; i < validated.servicePeriods.length; i++)
          _toServicePeriodWrite(validated.servicePeriods[i], i + 1),
      ],
      actorUserId: actorUserId,
      reason: adminReason,
      idempotencyKey: idempotencyKey,
    );
    return _toRecord(replaced ?? row);
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
    final row = await _repository.replaceServicePeriods(
      operatorId: operatorId,
      locationId: operatorId,
      profileId: profileId,
      servicePeriods: <BusinessTimingServicePeriodWrite>[
        for (var i = 0; i < mergedSet.length; i++)
          _toServicePeriodWrite(mergedSet[i], i + 1),
      ],
      actorUserId: actorUserId,
      reason: adminReason,
      idempotencyKey: idempotencyKey,
      metadata: auditPayload,
    );
    if (row == null) {
      throw const OperatorWriteRejected(
        code: 'profile_not_found',
        message: 'business timing profile was not found',
        statusCode: 404,
      );
    }
    return _toRecord(row);
  }

  BusinessTimingServicePeriodWrite _toServicePeriodWrite(
    ValidatedServicePeriod period,
    int sortOrder,
  ) {
    // Fix #4 / S1 / G45: stop fabricating an empty short label. The
    // canonical column is NOT NULL-friendly but a blank string is
    // lossy — every read surface then has to invent one. Derive the
    // short label from the operator-supplied label so it round-trips
    // instead of vanishing.
    //
    // `applicableWeekdays` stays the all-days mask here on purpose:
    // the operator-web write *validator* (`ValidatedServicePeriod`)
    // does not yet carry a day restriction, so there is genuinely no
    // day data to persist on this write path. Per the Fix #4 spec
    // that day-restriction capture lands in per-daypart Slice 2.5
    // (the `ServicePeriodDraft` / editor change, Gap 28); forcing a
    // non-all-days value here without validator support would be
    // scope creep into S3/Slice 2.5 and could not be honestly
    // populated. The READ round-trip (the S1 deliverable) surfaces
    // whatever days are already stored via the resolution route.
    return BusinessTimingServicePeriodWrite(
      servicePeriodKey: period.key,
      label: period.label,
      shortLabel: period.label,
      sortOrder: sortOrder,
      startLocalTime: period.startLocal,
      endLocalTime: period.endLocal,
      rollsPastMidnight: period.rollsPastMidnight,
      applicableWeekdays: const <int>[1, 2, 3, 4, 5, 6, 7],
    );
  }

  OperatorBusinessTimingProfileRecord _toRecord(
    BusinessTimingProfileRow row,
  ) {
    return OperatorBusinessTimingProfileRecord(
      profileId: row.profileId,
      scopeKind: row.scopeType,
      scopeId: row.scopeId,
      effectiveAtBusinessDate: row.effectiveFromBusinessDate,
      ianaTimezone: row.locationTimezone ?? 'UTC',
      weekStartDay: _weekStartIntToString(row.weekStartDay),
      businessDayStartLocal: row.businessDayStartLocalTime,
      servicePeriods: <OperatorBusinessTimingServicePeriodRecord>[
        for (final period in row.servicePeriods)
          _toServicePeriodRecord(period),
      ],
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  /// Fix #4 / S1 — single mapper so the list route, the load route
  /// and the new resolution route all surface the previously-dropped
  /// `shortLabel` / `sortOrder` / `applicableDays` fields identically.
  static OperatorBusinessTimingServicePeriodRecord _toServicePeriodRecord(
    BusinessTimingServicePeriodRow period,
  ) {
    return OperatorBusinessTimingServicePeriodRecord(
      key: period.servicePeriodKey,
      label: period.label,
      startLocal: period.startLocalTime,
      endLocal: period.endLocalTime,
      rollsPastMidnight: period.rollsPastMidnight,
      shortLabel: period.shortLabel,
      sortOrder: period.sortOrder,
      applicableDays: List<int>.unmodifiable(period.applicableWeekdays),
    );
  }

  String _weekStartIntToString(int day) {
    switch (day) {
      case 1:
        return 'monday';
      case 2:
        return 'tuesday';
      case 3:
        return 'wednesday';
      case 4:
        return 'thursday';
      case 5:
        return 'friday';
      case 6:
        return 'saturday';
      case 7:
        return 'sunday';
    }
    return 'monday';
  }
}
