// Plans & Limits V1: scoped custom contract overrides.
//
// Operator-scoped custom contract persistence for the admin Plans and limits
// Businesses tab. The table itself is RLS-protected, but admin reads and
// writes use the existing admin-pool posture: every method below runs through
// withSystem so forge_admin BYPASSRLS is explicit and audited.

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';

enum PricingContractScopeType {
  business('business'),
  orgUnit('org_unit'),
  location('location');

  const PricingContractScopeType(this.wireName);

  final String wireName;

  static PricingContractScopeType fromWireName(String value) {
    switch (value) {
      case 'business':
        return PricingContractScopeType.business;
      case 'org_unit':
        return PricingContractScopeType.orgUnit;
      case 'location':
        return PricingContractScopeType.location;
      default:
        throw ArgumentError.value(value, 'value', 'unknown scope type');
    }
  }
}

enum PricingContractOverrideStatus {
  setHere('set_here'),
  inherited('inherited'),
  catalogDefault('catalog_default');

  const PricingContractOverrideStatus(this.wireName);

  final String wireName;

  static PricingContractOverrideStatus fromWireName(String value) {
    switch (value) {
      case 'set_here':
        return PricingContractOverrideStatus.setHere;
      case 'inherited':
        return PricingContractOverrideStatus.inherited;
      case 'catalog_default':
        return PricingContractOverrideStatus.catalogDefault;
      default:
        throw ArgumentError.value(value, 'value', 'unknown override status');
    }
  }
}

class PricingContractScopeTarget {
  const PricingContractScopeTarget.business()
    : scopeType = PricingContractScopeType.business,
      orgUnitId = null,
      locationId = null;

  const PricingContractScopeTarget.orgUnit({required this.orgUnitId})
    : scopeType = PricingContractScopeType.orgUnit,
      locationId = null;

  const PricingContractScopeTarget.location({required this.locationId})
    : scopeType = PricingContractScopeType.location,
      orgUnitId = null;

  final PricingContractScopeType scopeType;
  final String? orgUnitId;
  final String? locationId;

  String? get scopeId {
    switch (scopeType) {
      case PricingContractScopeType.business:
        return null;
      case PricingContractScopeType.orgUnit:
        return orgUnitId;
      case PricingContractScopeType.location:
        return locationId;
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'scope_type': scopeType.wireName,
    'org_unit_id': orgUnitId,
    'location_id': locationId,
  };
}

class PricingContractOverrideWrite {
  const PricingContractOverrideWrite({
    required this.operatorId,
    required this.target,
    required this.tierKey,
    required this.effectiveFromDate,
    required this.updatedBy,
    this.billingOwnerOrgUnitId,
    this.monthlyUsd,
    this.firstNSeats,
    this.firstSeatUsd,
    this.additionalSeatUsd,
    this.onboardingMinUsd,
    this.onboardingMaxUsd,
    this.advisorCapMonthlyUsd,
    this.effectiveUntilDate,
    this.contractLabel,
    this.internalNote,
  });

  final String operatorId;
  final PricingContractScopeTarget target;
  final String tierKey;
  final String? billingOwnerOrgUnitId;
  final double? monthlyUsd;
  final int? firstNSeats;
  final double? firstSeatUsd;
  final double? additionalSeatUsd;
  final double? onboardingMinUsd;
  final double? onboardingMaxUsd;
  final double? advisorCapMonthlyUsd;
  final String effectiveFromDate;
  final String? effectiveUntilDate;
  final String? contractLabel;
  final String? internalNote;
  final String updatedBy;
}

class PricingContractTerms {
  const PricingContractTerms({
    required this.tierKey,
    this.billingOwnerOrgUnitId,
    this.monthlyUsd,
    this.firstNSeats,
    this.firstSeatUsd,
    this.additionalSeatUsd,
    this.onboardingMinUsd,
    this.onboardingMaxUsd,
    this.advisorCapMonthlyUsd,
    this.effectiveFromDate,
    this.effectiveUntilDate,
    this.contractLabel,
    this.internalNote,
    this.updatedAt,
    this.updatedBy,
  });

  final String tierKey;
  final String? billingOwnerOrgUnitId;
  final double? monthlyUsd;
  final int? firstNSeats;
  final double? firstSeatUsd;
  final double? additionalSeatUsd;
  final double? onboardingMinUsd;
  final double? onboardingMaxUsd;
  final double? advisorCapMonthlyUsd;
  final String? effectiveFromDate;
  final String? effectiveUntilDate;
  final String? contractLabel;
  final String? internalNote;
  final DateTime? updatedAt;
  final String? updatedBy;

  Map<String, Object?> toJson() => <String, Object?>{
    'tier_key': tierKey,
    'billing_owner_org_unit_id': billingOwnerOrgUnitId,
    'monthly_usd': monthlyUsd,
    'first_n_seats': firstNSeats,
    'first_seat_usd': firstSeatUsd,
    'additional_seat_usd': additionalSeatUsd,
    'onboarding_min_usd': onboardingMinUsd,
    'onboarding_max_usd': onboardingMaxUsd,
    'advisor_cap_monthly_usd': advisorCapMonthlyUsd,
    'effective_from': effectiveFromDate,
    'effective_until': effectiveUntilDate,
    'contract_label': contractLabel,
    'internal_note': internalNote,
    'updated_at': updatedAt?.toUtc().toIso8601String(),
    'updated_by': updatedBy,
  };
}

class PricingContractOverrideRow {
  const PricingContractOverrideRow({
    required this.id,
    required this.operatorId,
    required this.target,
    required this.terms,
    required this.createdAt,
  });

  final String id;
  final String operatorId;
  final PricingContractScopeTarget target;
  final PricingContractTerms terms;
  final DateTime createdAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'operator_id': operatorId,
    ...target.toJson(),
    ...terms.toJson(),
    'created_at': createdAt.toUtc().toIso8601String(),
  };
}

class PricingContractResolvedScope {
  const PricingContractResolvedScope({
    required this.scopeType,
    required this.scopeId,
    required this.scopeLabel,
    this.orgUnitId,
    this.locationId,
  });

  final PricingContractScopeType scopeType;
  final String scopeId;
  final String scopeLabel;
  final String? orgUnitId;
  final String? locationId;

  Map<String, Object?> toJson() => <String, Object?>{
    'scope_type': scopeType.wireName,
    'scope_id': scopeId,
    'scope_label': scopeLabel,
    'org_unit_id': orgUnitId,
    'location_id': locationId,
  };
}

class PricingContractSource {
  const PricingContractSource({
    required this.sourceType,
    required this.sourceId,
    required this.sourceLabel,
    required this.setHere,
    this.overrideId,
  });

  final String sourceType;
  final String sourceId;
  final String sourceLabel;
  final bool setHere;
  final String? overrideId;

  Map<String, Object?> toJson() => <String, Object?>{
    'source_type': sourceType,
    'source_id': sourceId,
    'source_label': sourceLabel,
    'set_here': setHere,
    'override_id': overrideId,
  };
}

class PricingContractMutationTarget {
  const PricingContractMutationTarget({
    required this.operatorId,
    required this.scopeType,
    required this.canClear,
    this.orgUnitId,
    this.locationId,
    this.existingOverrideId,
  });

  final String operatorId;
  final PricingContractScopeType scopeType;
  final String? orgUnitId;
  final String? locationId;
  final bool canClear;
  final String? existingOverrideId;

  Map<String, Object?> toJson() => <String, Object?>{
    'operator_id': operatorId,
    'scope_type': scopeType.wireName,
    'org_unit_id': orgUnitId,
    'location_id': locationId,
    'can_clear': canClear,
    'existing_override_id': existingOverrideId,
  };
}

class PricingContractEffectiveResolution {
  const PricingContractEffectiveResolution({
    required this.operatorId,
    required this.selectedScope,
    required this.inheritedSource,
    required this.effective,
    required this.overrideStatus,
    required this.mutationTarget,
  });

  final String operatorId;
  final PricingContractResolvedScope selectedScope;
  final PricingContractSource inheritedSource;
  final PricingContractTerms effective;
  final PricingContractOverrideStatus overrideStatus;
  final PricingContractMutationTarget mutationTarget;

  Map<String, Object?> toJson() => <String, Object?>{
    'operator_id': operatorId,
    'selected_scope': selectedScope.toJson(),
    'inherited_source': inheritedSource.toJson(),
    'effective': effective.toJson(),
    'override_status': overrideStatus.wireName,
    'mutation_target': mutationTarget.toJson(),
  };
}

class PricingContractOverridesRepository extends OperatorScopedRepository {
  PricingContractOverridesRepository(super.tenantWrapper);

  Future<PricingContractEffectiveResolution?> resolveEffective({
    required String operatorId,
    required PricingContractScopeTarget selectedScope,
    String? effectiveDate,
    required String adminReason,
  }) {
    final asOfDate = effectiveDate ?? _todayUtcDate();
    return withSystem<PricingContractEffectiveResolution?>((exec) async {
      final rows = await exec.query(
        _resolveEffectiveSql,
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'scope_type': selectedScope.scopeType.wireName,
          'org_unit_id': selectedScope.orgUnitId,
          'location_id': selectedScope.locationId,
          'effective_date': asOfDate,
        },
      );
      if (rows.isEmpty) return null;
      return _resolutionFromMap(rows.single);
    }, reason: adminReason);
  }

  Future<PricingContractOverrideRow> upsertOverride({
    required PricingContractOverrideWrite override,
    required String adminReason,
  }) {
    return withSystem<PricingContractOverrideRow>((exec) async {
      final rows = await exec.query(
        'insert into public.pricing_contract_overrides ('
        'operator_id, scope_type, org_unit_id, location_id, tier_key, '
        'billing_owner_org_unit_id, monthly_usd, first_n_seats, '
        'first_seat_usd, additional_seat_usd, onboarding_min_usd, '
        'onboarding_max_usd, advisor_cap_monthly_usd, effective_from, '
        'effective_until, contract_label, internal_note, updated_by'
        ') values ('
        '@operator_id::uuid, @scope_type, @org_unit_id::uuid, '
        '@location_id::uuid, @tier_key, @billing_owner_org_unit_id::uuid, '
        '@monthly_usd, @first_n_seats, @first_seat_usd, '
        '@additional_seat_usd, @onboarding_min_usd, @onboarding_max_usd, '
        '@advisor_cap_monthly_usd, @effective_from::date, '
        '@effective_until::date, @contract_label, @internal_note, '
        '@updated_by'
        ') on conflict on constraint pricing_contract_overrides_target_uq '
        'do update set '
        'tier_key = excluded.tier_key, '
        'billing_owner_org_unit_id = excluded.billing_owner_org_unit_id, '
        'monthly_usd = excluded.monthly_usd, '
        'first_n_seats = excluded.first_n_seats, '
        'first_seat_usd = excluded.first_seat_usd, '
        'additional_seat_usd = excluded.additional_seat_usd, '
        'onboarding_min_usd = excluded.onboarding_min_usd, '
        'onboarding_max_usd = excluded.onboarding_max_usd, '
        'advisor_cap_monthly_usd = excluded.advisor_cap_monthly_usd, '
        'effective_from = excluded.effective_from, '
        'effective_until = excluded.effective_until, '
        'contract_label = excluded.contract_label, '
        'internal_note = excluded.internal_note, '
        'updated_at = now(), '
        'updated_by = excluded.updated_by '
        'returning $_overrideSelectColumns',
        parameters: <String, Object?>{
          'operator_id': override.operatorId,
          'scope_type': override.target.scopeType.wireName,
          'org_unit_id': override.target.orgUnitId,
          'location_id': override.target.locationId,
          'tier_key': override.tierKey,
          'billing_owner_org_unit_id': override.billingOwnerOrgUnitId,
          'monthly_usd': override.monthlyUsd,
          'first_n_seats': override.firstNSeats,
          'first_seat_usd': override.firstSeatUsd,
          'additional_seat_usd': override.additionalSeatUsd,
          'onboarding_min_usd': override.onboardingMinUsd,
          'onboarding_max_usd': override.onboardingMaxUsd,
          'advisor_cap_monthly_usd': override.advisorCapMonthlyUsd,
          'effective_from': override.effectiveFromDate,
          'effective_until': override.effectiveUntilDate,
          'contract_label': override.contractLabel,
          'internal_note': override.internalNote,
          'updated_by': override.updatedBy,
        },
      );
      if (rows.isEmpty) {
        throw StateError('pricing_contract_overrides upsert returned no row');
      }
      return _overrideRowFromMap(rows.single);
    }, reason: adminReason);
  }

  Future<bool> deleteOverrideById({
    required String operatorId,
    required String overrideId,
    required String adminReason,
  }) {
    return withSystem<bool>((exec) async {
      final rows = await exec.query(
        'delete from public.pricing_contract_overrides '
        'where operator_id = @operator_id::uuid '
        'and id = @id::uuid '
        'returning id::text as id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'id': overrideId,
        },
      );
      return rows.isNotEmpty;
    }, reason: adminReason);
  }

  Future<bool> deleteOverrideForScope({
    required String operatorId,
    required PricingContractScopeTarget target,
    required String adminReason,
  }) {
    return withSystem<bool>((exec) async {
      final rows = await exec.query(
        'delete from public.pricing_contract_overrides '
        'where operator_id = @operator_id::uuid '
        'and scope_type = @scope_type '
        'and org_unit_id is not distinct from @org_unit_id::uuid '
        'and location_id is not distinct from @location_id::uuid '
        'returning id::text as id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'scope_type': target.scopeType.wireName,
          'org_unit_id': target.orgUnitId,
          'location_id': target.locationId,
        },
      );
      return rows.isNotEmpty;
    }, reason: adminReason);
  }

  static const String _overrideSelectColumns =
      'id::text as id, '
      'operator_id::text as operator_id, '
      'scope_type, '
      'org_unit_id::text as org_unit_id, '
      'location_id::text as location_id, '
      'tier_key, '
      'billing_owner_org_unit_id::text as billing_owner_org_unit_id, '
      'monthly_usd, '
      'first_n_seats, '
      'first_seat_usd, '
      'additional_seat_usd, '
      'onboarding_min_usd, '
      'onboarding_max_usd, '
      'advisor_cap_monthly_usd, '
      'effective_from, '
      'effective_until, '
      'contract_label, '
      'internal_note, '
      'created_at, '
      'updated_at, '
      'updated_by';

  static const String _resolveEffectiveSql =
      'with operator_scope as ('
      '  select operator_id, operator_id::text as operator_id_text, '
      '         business_name, subscription_tier '
      '    from public.operators '
      '   where operator_id = @operator_id::uuid '
      '   limit 1'
      '), selected_business as ('
      "  select 'business' as selected_scope_type, "
      '         op.operator_id_text as selected_scope_id, '
      '         op.business_name as selected_scope_label, '
      '         null::uuid as selected_org_unit_id, '
      '         null::uuid as selected_location_id, '
      '         null::ltree as selected_org_unit_path, '
      '         op.operator_id, op.operator_id_text '
      '    from operator_scope op '
      "   where @scope_type = 'business'"
      '), selected_org_unit as ('
      "  select 'org_unit' as selected_scope_type, "
      '         ou.id::text as selected_scope_id, '
      '         ou.name as selected_scope_label, '
      '         ou.id as selected_org_unit_id, '
      '         null::uuid as selected_location_id, '
      '         ou.path as selected_org_unit_path, '
      '         op.operator_id, op.operator_id_text '
      '    from operator_scope op '
      '    join public.org_units ou '
      '      on ou.operator_id = op.operator_id '
      '     and ou.id = @org_unit_id::uuid '
      '     and ou.deleted_at is null '
      "   where @scope_type = 'org_unit'"
      '), selected_location as ('
      "  select 'location' as selected_scope_type, "
      '         loc.location_id::text as selected_scope_id, '
      '         loc.name as selected_scope_label, '
      '         loc.parent_org_unit_id as selected_org_unit_id, '
      '         loc.location_id as selected_location_id, '
      '         loc.org_unit_path as selected_org_unit_path, '
      '         op.operator_id, op.operator_id_text '
      '    from operator_scope op '
      '    join public.locations loc '
      '      on loc.operator_id = op.operator_id '
      '     and loc.location_id = @location_id::uuid '
      '     and loc.deleted_at is null '
      "   where @scope_type = 'location'"
      '), selected_scope as ('
      '  select * from selected_business '
      '  union all select * from selected_org_unit '
      '  union all select * from selected_location '
      '  limit 1'
      '), active_overrides as ('
      '  select * '
      '    from public.pricing_contract_overrides o '
      '   where o.operator_id = @operator_id::uuid '
      '     and o.effective_from <= @effective_date::date '
      '     and (o.effective_until is null '
      '          or @effective_date::date < o.effective_until)'
      '), candidate_overrides as ('
      '  select o.*, 300 as precedence, '
      '         o.location_id::text as source_scope_id, '
      '         loc.name as source_scope_label '
      '    from active_overrides o '
      '    join selected_scope s '
      "      on s.selected_scope_type = 'location' "
      "     and o.scope_type = 'location' "
      '     and o.location_id = s.selected_location_id '
      '    join public.locations loc '
      '      on loc.operator_id = o.operator_id '
      '     and loc.location_id = o.location_id '
      '     and loc.deleted_at is null '
      '  union all '
      '  select o.*, 200 + nlevel(ou.path) as precedence, '
      '         o.org_unit_id::text as source_scope_id, '
      '         ou.name as source_scope_label '
      '    from active_overrides o '
      '    join public.org_units ou '
      '      on ou.operator_id = o.operator_id '
      '     and ou.id = o.org_unit_id '
      '     and ou.deleted_at is null '
      '    join selected_scope s '
      "      on s.selected_scope_type in ('org_unit', 'location') "
      '     and ou.path @> s.selected_org_unit_path '
      "   where o.scope_type = 'org_unit' "
      '  union all '
      '  select o.*, 100 as precedence, '
      '         op.operator_id_text as source_scope_id, '
      '         op.business_name as source_scope_label '
      '    from active_overrides o '
      '    join operator_scope op on op.operator_id = o.operator_id '
      '    join selected_scope s on true '
      "   where o.scope_type = 'business'"
      '), winning_override as ('
      '  select * from candidate_overrides '
      '  order by precedence desc '
      '  limit 1'
      ') '
      'select '
      '  op.operator_id_text as operator_id, '
      '  s.selected_scope_type, '
      '  s.selected_scope_id, '
      '  s.selected_scope_label, '
      '  s.selected_org_unit_id::text as selected_org_unit_id, '
      '  s.selected_location_id::text as selected_location_id, '
      '  w.id::text as source_override_id, '
      "  coalesce(w.scope_type, 'catalog') as source_type, "
      '  case '
      '    when w.id is null then catalog.tier_key '
      '    else w.source_scope_id '
      '  end as source_id, '
      '  case '
      "    when w.id is null then 'Global plan catalog' "
      '    else w.source_scope_label '
      '  end as source_label, '
      '  case '
      "    when w.id is null then 'catalog_default' "
      '    when w.scope_type = s.selected_scope_type '
      '     and w.org_unit_id is not distinct from s.selected_org_unit_id '
      '     and w.location_id is not distinct from s.selected_location_id '
      "      then 'set_here' "
      "    else 'inherited' "
      '  end as override_status, '
      '  coalesce(w.tier_key, op.subscription_tier) as effective_tier_key, '
      '  w.billing_owner_org_unit_id::text as billing_owner_org_unit_id, '
      '  case when w.id is null then catalog.monthly_usd '
      '       else w.monthly_usd end as monthly_usd, '
      '  case when w.id is null then catalog.first_n_seats '
      '       else w.first_n_seats end as first_n_seats, '
      '  case when w.id is null then catalog.first_seat_usd '
      '       else w.first_seat_usd end as first_seat_usd, '
      '  case when w.id is null then catalog.additional_seat_usd '
      '       else w.additional_seat_usd end as additional_seat_usd, '
      '  case when w.id is null then catalog.onboarding_min_usd '
      '       else w.onboarding_min_usd end as onboarding_min_usd, '
      '  case when w.id is null then catalog.onboarding_max_usd '
      '       else w.onboarding_max_usd end as onboarding_max_usd, '
      '  w.advisor_cap_monthly_usd, '
      '  w.effective_from, '
      '  w.effective_until, '
      '  w.contract_label, '
      '  w.internal_note, '
      '  case when w.id is null then catalog.updated_at '
      '       else w.updated_at end as updated_at, '
      '  case when w.id is null then catalog.updated_by '
      '       else w.updated_by end as updated_by '
      'from selected_scope s '
      'join operator_scope op on true '
      'left join winning_override w on true '
      'join public.pricing_plan_catalog catalog '
      '  on catalog.tier_key = coalesce(w.tier_key, op.subscription_tier) '
      'limit 1';

  static PricingContractEffectiveResolution _resolutionFromMap(
    PostgresRow row,
  ) {
    final status = PricingContractOverrideStatus.fromWireName(
      _requiredString(row, 'override_status'),
    );
    final selectedScopeType = PricingContractScopeType.fromWireName(
      _requiredString(row, 'selected_scope_type'),
    );
    final sourceOverrideId = _optionalString(row, 'source_override_id');
    final setHere = status == PricingContractOverrideStatus.setHere;
    return PricingContractEffectiveResolution(
      operatorId: _requiredString(row, 'operator_id'),
      selectedScope: PricingContractResolvedScope(
        scopeType: selectedScopeType,
        scopeId: _requiredString(row, 'selected_scope_id'),
        scopeLabel: _requiredString(row, 'selected_scope_label'),
        orgUnitId: _optionalString(row, 'selected_org_unit_id'),
        locationId: _optionalString(row, 'selected_location_id'),
      ),
      inheritedSource: PricingContractSource(
        sourceType: _requiredString(row, 'source_type'),
        sourceId: _requiredString(row, 'source_id'),
        sourceLabel: _requiredString(row, 'source_label'),
        setHere: setHere,
        overrideId: sourceOverrideId,
      ),
      effective: PricingContractTerms(
        tierKey: _requiredString(row, 'effective_tier_key'),
        billingOwnerOrgUnitId: _optionalString(
          row,
          'billing_owner_org_unit_id',
        ),
        monthlyUsd: _asNullableDouble(row['monthly_usd']),
        firstNSeats: _asNullableInt(row['first_n_seats']),
        firstSeatUsd: _asNullableDouble(row['first_seat_usd']),
        additionalSeatUsd: _asNullableDouble(row['additional_seat_usd']),
        onboardingMinUsd: _asNullableDouble(row['onboarding_min_usd']),
        onboardingMaxUsd: _asNullableDouble(row['onboarding_max_usd']),
        advisorCapMonthlyUsd: _asNullableDouble(row['advisor_cap_monthly_usd']),
        effectiveFromDate: _dateString(row['effective_from']),
        effectiveUntilDate: _dateString(row['effective_until']),
        contractLabel: _optionalString(row, 'contract_label'),
        internalNote: _optionalString(row, 'internal_note'),
        updatedAt: _asNullableDateTime(row['updated_at']),
        updatedBy: _optionalString(row, 'updated_by'),
      ),
      overrideStatus: status,
      mutationTarget: PricingContractMutationTarget(
        operatorId: _requiredString(row, 'operator_id'),
        scopeType: selectedScopeType,
        orgUnitId: _optionalString(row, 'selected_org_unit_id'),
        locationId: _optionalString(row, 'selected_location_id'),
        canClear: setHere,
        existingOverrideId: setHere ? sourceOverrideId : null,
      ),
    );
  }

  static PricingContractOverrideRow _overrideRowFromMap(PostgresRow row) {
    final scopeType = PricingContractScopeType.fromWireName(
      _requiredString(row, 'scope_type'),
    );
    return PricingContractOverrideRow(
      id: _requiredString(row, 'id'),
      operatorId: _requiredString(row, 'operator_id'),
      target: _targetFromRow(scopeType, row),
      terms: PricingContractTerms(
        tierKey: _requiredString(row, 'tier_key'),
        billingOwnerOrgUnitId: _optionalString(
          row,
          'billing_owner_org_unit_id',
        ),
        monthlyUsd: _asNullableDouble(row['monthly_usd']),
        firstNSeats: _asNullableInt(row['first_n_seats']),
        firstSeatUsd: _asNullableDouble(row['first_seat_usd']),
        additionalSeatUsd: _asNullableDouble(row['additional_seat_usd']),
        onboardingMinUsd: _asNullableDouble(row['onboarding_min_usd']),
        onboardingMaxUsd: _asNullableDouble(row['onboarding_max_usd']),
        advisorCapMonthlyUsd: _asNullableDouble(row['advisor_cap_monthly_usd']),
        effectiveFromDate: _dateString(row['effective_from']),
        effectiveUntilDate: _dateString(row['effective_until']),
        contractLabel: _optionalString(row, 'contract_label'),
        internalNote: _optionalString(row, 'internal_note'),
        updatedAt: _asNullableDateTime(row['updated_at']),
        updatedBy: _optionalString(row, 'updated_by'),
      ),
      createdAt: _requiredDateTime(row['created_at']),
    );
  }

  static PricingContractScopeTarget _targetFromRow(
    PricingContractScopeType scopeType,
    PostgresRow row,
  ) {
    switch (scopeType) {
      case PricingContractScopeType.business:
        return const PricingContractScopeTarget.business();
      case PricingContractScopeType.orgUnit:
        return PricingContractScopeTarget.orgUnit(
          orgUnitId: _requiredString(row, 'org_unit_id'),
        );
      case PricingContractScopeType.location:
        return PricingContractScopeTarget.location(
          locationId: _requiredString(row, 'location_id'),
        );
    }
  }

  static String _todayUtcDate() {
    final now = DateTime.now().toUtc();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  static String _requiredString(PostgresRow row, String key) {
    final value = row[key];
    if (value is String && value.isNotEmpty) return value;
    throw StateError('pricing_contract_overrides row missing $key');
  }

  static String? _optionalString(PostgresRow row, String key) {
    final value = row[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return null;
  }

  static double? _asNullableDouble(Object? value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static int? _asNullableInt(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static DateTime _requiredDateTime(Object? value) {
    final parsed = _asNullableDateTime(value);
    if (parsed != null) return parsed;
    throw StateError('pricing_contract_overrides row missing timestamptz');
  }

  static DateTime? _asNullableDateTime(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value.toUtc();
    if (value is String && value.isNotEmpty) {
      return DateTime.parse(value).toUtc();
    }
    return null;
  }

  static String? _dateString(Object? value) {
    if (value == null) return null;
    if (value is DateTime) {
      final utc = value.toUtc();
      return '${utc.year.toString().padLeft(4, '0')}-'
          '${utc.month.toString().padLeft(2, '0')}-'
          '${utc.day.toString().padLeft(2, '0')}';
    }
    final text = value.toString();
    if (text.length >= 10) return text.substring(0, 10);
    return text.isEmpty ? null : text;
  }
}
