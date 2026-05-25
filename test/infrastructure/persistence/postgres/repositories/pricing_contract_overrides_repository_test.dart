import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/pricing_contract_overrides_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _operatorId = '11111111-1111-1111-1111-111111111111';
const String _locationId = '22222222-2222-2222-2222-222222222222';
const String _orgUnitId = '33333333-3333-3333-3333-333333333333';
const String _billingOwnerId = '44444444-4444-4444-4444-444444444444';
const String _overrideId = '55555555-5555-5555-5555-555555555555';
const String _actor = 'admin-user-1';

PostgresRow _resolutionRow({
  String selectedScopeType = 'location',
  String selectedScopeId = _locationId,
  String selectedScopeLabel = 'Yorkville',
  String? selectedOrgUnitId = _orgUnitId,
  String? selectedLocationId = _locationId,
  String? sourceOverrideId = _overrideId,
  String sourceType = 'location',
  String sourceId = _locationId,
  String sourceLabel = 'Yorkville',
  String overrideStatus = 'set_here',
  String tierKey = 'enterprise',
  String? billingOwnerOrgUnitId = _billingOwnerId,
  num? monthlyUsd = 2500,
  int? firstNSeats = 20,
  num? firstSeatUsd = 12,
  num? additionalSeatUsd = 8,
  num? onboardingMinUsd = 2500,
  num? onboardingMaxUsd = 5000,
  num? advisorCapMonthlyUsd = 300,
  Object? effectiveFrom = '2026-06-01',
  Object? effectiveUntil,
  String? contractLabel = 'Yorkville custom',
  String? internalNote = 'Signed MSA',
  String? updatedBy = _actor,
}) {
  return <String, Object?>{
    'operator_id': _operatorId,
    'selected_scope_type': selectedScopeType,
    'selected_scope_id': selectedScopeId,
    'selected_scope_label': selectedScopeLabel,
    'selected_org_unit_id': selectedOrgUnitId,
    'selected_location_id': selectedLocationId,
    'source_override_id': sourceOverrideId,
    'source_type': sourceType,
    'source_id': sourceId,
    'source_label': sourceLabel,
    'override_status': overrideStatus,
    'effective_tier_key': tierKey,
    'billing_owner_org_unit_id': billingOwnerOrgUnitId,
    'monthly_usd': monthlyUsd,
    'first_n_seats': firstNSeats,
    'first_seat_usd': firstSeatUsd,
    'additional_seat_usd': additionalSeatUsd,
    'onboarding_min_usd': onboardingMinUsd,
    'onboarding_max_usd': onboardingMaxUsd,
    'advisor_cap_monthly_usd': advisorCapMonthlyUsd,
    'effective_from': effectiveFrom,
    'effective_until': effectiveUntil,
    'contract_label': contractLabel,
    'internal_note': internalNote,
    'updated_at': DateTime.utc(2026, 5, 25, 12),
    'updated_by': updatedBy,
  };
}

PostgresRow _catalogResolutionRow() {
  return _resolutionRow(
    sourceOverrideId: null,
    sourceType: 'catalog',
    sourceId: 'starter',
    sourceLabel: 'Global plan catalog',
    overrideStatus: 'catalog_default',
    tierKey: 'starter',
    billingOwnerOrgUnitId: null,
    monthlyUsd: 250,
    firstNSeats: null,
    firstSeatUsd: null,
    additionalSeatUsd: null,
    onboardingMinUsd: 500,
    onboardingMaxUsd: 1000,
    advisorCapMonthlyUsd: null,
    effectiveFrom: null,
    effectiveUntil: null,
    contractLabel: null,
    internalNote: null,
    updatedBy: null,
  );
}

PostgresRow _overrideRow() {
  return <String, Object?>{
    'id': _overrideId,
    'operator_id': _operatorId,
    'scope_type': 'location',
    'org_unit_id': null,
    'location_id': _locationId,
    'tier_key': 'enterprise',
    'billing_owner_org_unit_id': _billingOwnerId,
    'monthly_usd': 2500,
    'first_n_seats': 20,
    'first_seat_usd': 12,
    'additional_seat_usd': 8,
    'onboarding_min_usd': 2500,
    'onboarding_max_usd': 5000,
    'advisor_cap_monthly_usd': 300,
    'effective_from': '2026-06-01',
    'effective_until': null,
    'contract_label': 'Yorkville custom',
    'internal_note': 'Signed MSA',
    'created_at': DateTime.utc(2026, 5, 25, 11),
    'updated_at': DateTime.utc(2026, 5, 25, 12),
    'updated_by': _actor,
  };
}

void main() {
  group('PricingContractOverridesRepository.upsertOverride', () {
    test('persists all custom contract fields on the scoped target', () async {
      final pool = _PricingContractsPool(
        upsertRows: <PostgresRow>[_overrideRow()],
      );
      final repo = PricingContractOverridesRepository(
        TenantTransactionWrapper(pool),
      );

      final row = await repo.upsertOverride(
        override: const PricingContractOverrideWrite(
          operatorId: _operatorId,
          target: PricingContractScopeTarget.location(locationId: _locationId),
          tierKey: 'enterprise',
          billingOwnerOrgUnitId: _billingOwnerId,
          monthlyUsd: 2500,
          firstNSeats: 20,
          firstSeatUsd: 12,
          additionalSeatUsd: 8,
          onboardingMinUsd: 2500,
          onboardingMaxUsd: 5000,
          advisorCapMonthlyUsd: 300,
          effectiveFromDate: '2026-06-01',
          contractLabel: 'Yorkville custom',
          internalNote: 'Signed MSA',
          updatedBy: _actor,
        ),
        adminReason: 'admin.pricing.scoped_contracts.set',
      );

      expect(row.id, equals(_overrideId));
      expect(row.target.scopeType, equals(PricingContractScopeType.location));
      expect(row.target.locationId, equals(_locationId));
      expect(row.terms.tierKey, equals('enterprise'));
      expect(row.terms.billingOwnerOrgUnitId, equals(_billingOwnerId));
      expect(row.terms.monthlyUsd, equals(2500));
      expect(row.terms.firstNSeats, equals(20));
      expect(row.terms.firstSeatUsd, equals(12));
      expect(row.terms.additionalSeatUsd, equals(8));
      expect(row.terms.onboardingMinUsd, equals(2500));
      expect(row.terms.onboardingMaxUsd, equals(5000));
      expect(row.terms.advisorCapMonthlyUsd, equals(300));
      expect(row.terms.effectiveFromDate, equals('2026-06-01'));
      expect(row.terms.contractLabel, equals('Yorkville custom'));
      expect(row.terms.internalNote, equals('Signed MSA'));

      final tx = pool.transactions.single;
      final upsertSql = tx.executedSql.firstWhere(
        (sql) => sql.contains('insert into public.pricing_contract_overrides'),
      );
      expect(
        upsertSql,
        contains(
          'on conflict on constraint pricing_contract_overrides_target_uq',
        ),
      );
      expect(upsertSql, contains('advisor_cap_monthly_usd'));
      expect(upsertSql, contains('effective_from = excluded.effective_from'));
      expect(upsertSql, isNot(contains('created_at = excluded.created_at')));

      final params = tx.parameters.firstWhere(
        (p) => p['scope_type'] == 'location',
      );
      expect(params['operator_id'], equals(_operatorId));
      expect(params['location_id'], equals(_locationId));
      expect(params['billing_owner_org_unit_id'], equals(_billingOwnerId));
      expect(params['advisor_cap_monthly_usd'], equals(300));
      expect(params['effective_from'], equals('2026-06-01'));
      expect(params['updated_by'], equals(_actor));
    });
  });

  group('PricingContractOverridesRepository.resolveEffective', () {
    test(
      'returns set-here metadata when the selected location has an override',
      () async {
        final pool = _PricingContractsPool(
          resolveRows: <PostgresRow>[_resolutionRow()],
        );
        final repo = PricingContractOverridesRepository(
          TenantTransactionWrapper(pool),
        );

        final result = await repo.resolveEffective(
          operatorId: _operatorId,
          selectedScope: const PricingContractScopeTarget.location(
            locationId: _locationId,
          ),
          effectiveDate: '2026-06-15',
          adminReason: 'admin.pricing.scoped_contracts.resolve',
        );

        expect(result, isNotNull);
        expect(
          result!.selectedScope.scopeType,
          PricingContractScopeType.location,
        );
        expect(result.selectedScope.scopeId, equals(_locationId));
        expect(result.inheritedSource.sourceType, equals('location'));
        expect(result.inheritedSource.sourceId, equals(_locationId));
        expect(result.inheritedSource.setHere, isTrue);
        expect(result.overrideStatus, PricingContractOverrideStatus.setHere);
        expect(result.effective.tierKey, equals('enterprise'));
        expect(result.effective.monthlyUsd, equals(2500));
        expect(result.effective.advisorCapMonthlyUsd, equals(300));
        expect(
          result.mutationTarget.scopeType,
          PricingContractScopeType.location,
        );
        expect(result.mutationTarget.canClear, isTrue);
        expect(result.mutationTarget.existingOverrideId, equals(_overrideId));

        final tx = pool.transactions.single;
        expect(tx.executedSql[0], contains("'app.bypass_rls_audit'"));
        expect(tx.parameters[0]['value'], contains('system:admin.pricing'));
        expect(tx.executedSql[1], contains('set local role forge_admin'));
        expect(
          tx.executedSql.where((sql) => sql.contains("'app.operator_id'")),
          isEmpty,
        );
      },
    );

    test(
      'returns inherited source when a location inherits org-unit terms',
      () async {
        final pool = _PricingContractsPool(
          resolveRows: <PostgresRow>[
            _resolutionRow(
              sourceOverrideId: '66666666-6666-6666-6666-666666666666',
              sourceType: 'org_unit',
              sourceId: _orgUnitId,
              sourceLabel: 'East region',
              overrideStatus: 'inherited',
              monthlyUsd: 1800,
              advisorCapMonthlyUsd: 450,
            ),
          ],
        );
        final repo = PricingContractOverridesRepository(
          TenantTransactionWrapper(pool),
        );

        final result = await repo.resolveEffective(
          operatorId: _operatorId,
          selectedScope: const PricingContractScopeTarget.location(
            locationId: _locationId,
          ),
          effectiveDate: '2026-06-15',
          adminReason: 'admin.pricing.scoped_contracts.resolve',
        );

        expect(result, isNotNull);
        expect(result!.overrideStatus, PricingContractOverrideStatus.inherited);
        expect(result.inheritedSource.sourceType, equals('org_unit'));
        expect(result.inheritedSource.sourceId, equals(_orgUnitId));
        expect(result.inheritedSource.sourceLabel, equals('East region'));
        expect(result.inheritedSource.setHere, isFalse);
        expect(result.effective.monthlyUsd, equals(1800));
        expect(result.effective.advisorCapMonthlyUsd, equals(450));
        expect(
          result.mutationTarget.scopeType,
          PricingContractScopeType.location,
        );
        expect(result.mutationTarget.canClear, isFalse);
        expect(result.mutationTarget.existingOverrideId, isNull);
      },
    );

    test(
      'clear by scope plus no override falls back to the global catalog',
      () async {
        final pool = _PricingContractsPool(
          deleteRows: <PostgresRow>[
            <String, Object?>{'id': _overrideId},
          ],
          resolveRows: <PostgresRow>[_catalogResolutionRow()],
        );
        final repo = PricingContractOverridesRepository(
          TenantTransactionWrapper(pool),
        );

        final deleted = await repo.deleteOverrideForScope(
          operatorId: _operatorId,
          target: const PricingContractScopeTarget.location(
            locationId: _locationId,
          ),
          adminReason: 'admin.pricing.scoped_contracts.clear',
        );
        expect(deleted, isTrue);

        final result = await repo.resolveEffective(
          operatorId: _operatorId,
          selectedScope: const PricingContractScopeTarget.location(
            locationId: _locationId,
          ),
          effectiveDate: '2026-06-15',
          adminReason: 'admin.pricing.scoped_contracts.resolve',
        );

        expect(result, isNotNull);
        expect(
          result!.overrideStatus,
          PricingContractOverrideStatus.catalogDefault,
        );
        expect(result.inheritedSource.sourceType, equals('catalog'));
        expect(result.inheritedSource.sourceId, equals('starter'));
        expect(result.effective.tierKey, equals('starter'));
        expect(result.effective.monthlyUsd, equals(250));
        expect(result.effective.advisorCapMonthlyUsd, isNull);
        expect(result.mutationTarget.canClear, isFalse);

        final deleteTx = pool.transactions.first;
        final deleteSql = deleteTx.executedSql.firstWhere(
          (sql) =>
              sql.contains('delete from public.pricing_contract_overrides'),
        );
        expect(
          deleteSql,
          contains('org_unit_id is not distinct from @org_unit_id::uuid'),
        );
        expect(
          deleteSql,
          contains('location_id is not distinct from @location_id::uuid'),
        );
        final deleteParams = deleteTx.parameters.firstWhere(
          (p) => p['scope_type'] == 'location',
        );
        expect(deleteParams['org_unit_id'], isNull);
        expect(deleteParams['location_id'], equals(_locationId));
      },
    );

    test('resolver SQL ranks location over org-unit over business', () async {
      final pool = _PricingContractsPool(
        resolveRows: <PostgresRow>[_resolutionRow()],
      );
      final repo = PricingContractOverridesRepository(
        TenantTransactionWrapper(pool),
      );

      final result = await repo.resolveEffective(
        operatorId: _operatorId,
        selectedScope: const PricingContractScopeTarget.location(
          locationId: _locationId,
        ),
        effectiveDate: '2026-06-15',
        adminReason: 'admin.pricing.scoped_contracts.resolve',
      );
      expect(result, isNotNull);
      expect(result!.inheritedSource.sourceType, equals('location'));

      final resolveTx = pool.transactions.single;
      final resolveSql = resolveTx.executedSql.firstWhere(
        (sql) => sql.contains('with operator_scope as'),
      );
      expect(resolveSql, contains('300 as precedence'));
      expect(resolveSql, contains('200 + nlevel(ou.path) as precedence'));
      expect(resolveSql, contains('100 as precedence'));
      expect(resolveSql, contains('order by precedence desc'));
      expect(resolveSql, contains("s.selected_scope_type = 'location'"));
      expect(
        resolveSql,
        contains("s.selected_scope_type in ('org_unit', 'location')"),
      );
    });
  });
}

class _PricingContractsPool implements PostgresPool {
  _PricingContractsPool({
    this.resolveRows = const <PostgresRow>[],
    this.upsertRows = const <PostgresRow>[],
    this.deleteRows = const <PostgresRow>[],
  });

  final List<PostgresRow> resolveRows;
  final List<PostgresRow> upsertRows;
  final List<PostgresRow> deleteRows;
  final List<_PricingContractsTransaction> transactions =
      <_PricingContractsTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _PricingContractsTransaction(
      resolveRows: resolveRows,
      upsertRows: upsertRows,
      deleteRows: deleteRows,
    );
    transactions.add(tx);
    return tx;
  }
}

class _PricingContractsTransaction extends PostgresTransaction {
  _PricingContractsTransaction({
    required this.resolveRows,
    required this.upsertRows,
    required this.deleteRows,
  });

  final List<PostgresRow> resolveRows;
  final List<PostgresRow> upsertRows;
  final List<PostgresRow> deleteRows;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  int commitCount = 0;
  int rollbackCount = 0;
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('insert into public.pricing_contract_overrides')) {
      return upsertRows;
    }
    if (sql.contains('delete from public.pricing_contract_overrides')) {
      return deleteRows;
    }
    if (sql.contains('with operator_scope as')) {
      return resolveRows;
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
    rollbackCount += 1;
  }
}
