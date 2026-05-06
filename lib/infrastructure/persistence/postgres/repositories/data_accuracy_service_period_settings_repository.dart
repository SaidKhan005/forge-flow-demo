// Hardening Wave B1 — DataAccuracyServicePeriodSettingsRepository.
//
// Persistence layer for `public.data_accuracy_service_period_settings`.
// Every read / write goes through `OperatorScopedRepository.withTenant`
// so the per-tenant RLS policy admits the row (primary defense:
// repository pattern; backup: RLS).
//
// Authority:
//   * docs/contracts/data_accuracy_settings_contract.md
//     "Business timing compatibility amendment (2026-05-06)" + "Schema"
//     section. Replaces the hardcoded
//     `covers_source_lunch` / `covers_source_dinner` /
//     `covers_source_late_night` columns on `data_accuracy_settings`.
//   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
//     (every operator-scoped table goes through OperatorScopedRepository;
//     no raw `package:postgres` import outside this directory).
//
// Consumed by Lane 8.spine-bridge.2 (aggregator covers-source resolution
// — keyed lookup at-or-before the closed shift's business date) and a
// future Operator Web Console Data Accuracy slice (per-period editor).

import '../../../../domain/models/data_accuracy_service_period_setting.dart';
import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

class DataAccuracyServicePeriodSettingsRepository
    extends OperatorScopedRepository {
  DataAccuracyServicePeriodSettingsRepository(super.tenantWrapper);

  static const String _selectColumns =
      'id::text as id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'service_period_key, '
      'covers_source, '
      'wage_source, '
      'effective_at_business_date, '
      'created_at, '
      'updated_at, '
      'updated_by';

  /// Read the most-recent setting at-or-before [businessDateIso] for
  /// `(operatorId, locationId, servicePeriodKey)`. Returns null when
  /// no row exists for that period at-or-before the supplied date —
  /// callers (the closed-shift aggregator) fall back to the legacy
  /// hardcoded columns on `data_accuracy_settings` per the migration
  /// header.
  ///
  /// `effective_at_business_date` is a business-local DATE column;
  /// passing the closed shift's `business_date` directly resolves to
  /// the operator's intent on the day the shift closed. Forward-staged
  /// rows (effective dates AFTER the shift's business date) are not
  /// returned, so a 2026-06-01 manual-mode change does not retroactively
  /// gate a 2026-05-15 close.
  Future<DataAccuracyServicePeriodSetting?> readEffectiveAt({
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    required String businessDateIso,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<DataAccuracyServicePeriodSetting?>(ctx, (exec) async {
      final rows = await exec.query(
        'select $_selectColumns '
        'from public.data_accuracy_service_period_settings '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and service_period_key = @service_period_key '
        'and effective_at_business_date <= @business_date::date '
        'order by effective_at_business_date desc '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'service_period_key': servicePeriodKey,
          'business_date': businessDateIso,
        },
      );
      if (rows.isEmpty) return null;
      return DataAccuracyServicePeriodSetting.fromRow(rows.single);
    });
  }

  /// Upsert a row for `(operatorId, locationId, servicePeriodKey,
  /// effectiveAtBusinessDateIso)`. Conflict identity matches the
  /// migration's UNIQUE index. DO UPDATE rewrites the editable fields
  /// and bumps `updated_at` / `updated_by`.
  ///
  /// Used by the Operator Web Console Data Accuracy editor (future
  /// slice) and by tests; the aggregator never writes through this
  /// surface.
  Future<DataAccuracyServicePeriodSetting> upsert({
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    required ServicePeriodCoversSource coversSource,
    required ServicePeriodWageSource wageSource,
    required String effectiveAtBusinessDateIso,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<DataAccuracyServicePeriodSetting>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into public.data_accuracy_service_period_settings ('
        'operator_id, location_id, service_period_key, '
        'covers_source, wage_source, effective_at_business_date, '
        'updated_by) '
        'values ('
        '@operator_id::uuid, @location_id::uuid, @service_period_key, '
        '@covers_source, @wage_source, @effective_at::date, '
        '@updated_by) '
        'on conflict (operator_id, location_id, service_period_key, '
        'effective_at_business_date) do update set '
        'covers_source = excluded.covers_source, '
        'wage_source = excluded.wage_source, '
        'updated_at = now(), '
        'updated_by = excluded.updated_by '
        'returning $_selectColumns',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'service_period_key': servicePeriodKey,
          'covers_source': coversSource.wire,
          'wage_source': wageSource.wire,
          'effective_at': effectiveAtBusinessDateIso,
          'updated_by': actorUserId,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'data_accuracy_service_period_settings upsert returned no '
          'row — RLS policy likely rejected the write for this tenant',
        );
      }
      return DataAccuracyServicePeriodSetting.fromRow(rows.single);
    });
  }

  /// List every row for `(operatorId, locationId, servicePeriodKey)`
  /// in descending effective-date order. Used by the Operator Web
  /// Console editor history view (future slice).
  Future<List<DataAccuracyServicePeriodSetting>> listForServicePeriod({
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<List<DataAccuracyServicePeriodSetting>>(ctx,
        (exec) async {
      final rows = await exec.query(
        'select $_selectColumns '
        'from public.data_accuracy_service_period_settings '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and service_period_key = @service_period_key '
        'order by effective_at_business_date desc',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'service_period_key': servicePeriodKey,
        },
      );
      return <DataAccuracyServicePeriodSetting>[
        for (final row in rows) DataAccuracyServicePeriodSetting.fromRow(row),
      ];
    });
  }
}
